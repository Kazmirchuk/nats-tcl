# Copyright (c) 2020-2021 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require cmdline
package require json
package require json::write
package require oo::util
package require tcl::chan::random
package require tcl::randomseed
package require coroutine
package require logger
package require textutil::split

namespace eval ::nats {
    # improvised enum
    variable status_closed 0
    variable status_connecting 1
    variable status_connected 2
    variable status_reconnecting 3
}
# all options for "configure"
set ::nats::option_syntax {
    { servers.list ""                   "URLs of NATS servers"}
    { name.arg ""                       "Client name sent to NATS server when connecting"}
    { pedantic.boolean false            "Pedantic protocol mode. If true some extra checks will be performed by the server"}
    { verbose.boolean false             "If true, every protocol message is echoed by the server with +OK" }
    { randomize.boolean true            "Shuffle server addresses passed to 'configure'" }
    { connect_timeout.integer 2000      "Connection timeout (ms)"}
    { reconnect_time_wait.integer 2000  "How long to wait between two reconnect attempts to the same server (ms)"}
    { max_reconnect_attempts.integer 60 "Maximum number of reconnect attempts per server"}
    { ping_interval.integer 120000      "Interval (ms) to send PING messages to a NATS server"}
    { max_outstanding_pings.integer 2   "Max number of PINGs without a reply from a NATS server before closing the connection"}
    { echo.boolean true                 "If true, messages from this connection will be echoed back by the server if the connection has matching subscriptions"}
    { tls_opts.list ""                  "Additional options for tls::import"}
    { default_tls_opts.list {-require 1 -command ::nats::tls_callback} "Default options for tls::import"}
    { user.list ""                      "Default username"}
    { password.list ""                  "Default password"}
    { token.arg ""                      "Default authentication token"}
    { secure.boolean false              "If secure=true, connection will fail if a server can't provide a TLS connection"}
    { check_subjects.boolean true       "Enable client-side checking of subjects when publishing or subscribing"}
    { dictmsg.boolean false             "Return messages from subscribe&request as dicts by default" }
}

oo::class create ::nats::connection {
    # "private" variables
    variable config sock coro timers counters subscriptions requests serverInfo serverPool \
             subjectRegex outBuffer randomChan requestsInboxPrefix jetStream pong logger
    
    # "public" variables, so that users can set up traces if needed
    variable status last_error

    constructor { { conn_name "" } } {
        set status $nats::status_closed
        set last_error ""

        # initialise default configuration
        foreach option $nats::option_syntax {
            lassign $option optName defValue comment
            #drop everything after dot
            set optName [lindex [split $optName .] 0]
            set config($optName) $defValue
        }
        set config(name) $conn_name
        # create a logger with a unique name, smth like Obj58
        set loggerName [namespace tail [self object]]
        if {$conn_name ne ""} {
            append loggerName "_$conn_name"
        }
        set logger [logger::init $loggerName]
        # default timestamp of the logger looks like Tue Jul 13 15:16:58 CEST 2021, which is not very useful
        foreach lvl [logger::levels] {
            interp alias {} ::nats::log_stdout_$lvl {} ::nats::log_stdout $loggerName $lvl
            ${logger}::logproc $lvl ::nats::log_stdout_$lvl
        }
        
        # default level in the logger is debug, it's too verbose
        ${logger}::setlevel warn
        
        set sock "" ;# the TCP socket
        set coro "" ;# the coroutine handling readable and writeable events on the socket
        array set timers {ping {} flush {} connect {} }
        array set counters {subscription 0 request 0 pendingPings 0}
        array set subscriptions {} ;# subID -> dict (subj, queue, cmd, maxMsgs, recMsgs)
        array set requests {} ;# reqID -> dict
        # for sync reqs the dict has: (timedOut, response)
        # for async reqs the dict has: (timer, callback, isDictMsg, subID, maxMsgs, recMsgs)
        array set serverInfo {} ;# INFO from a current NATS server
        set serverPool [nats::server_pool new [self object]] 
        # JetStream uses subjects with $
        set subjectRegex {^[[:alnum:]$_-]+$}
        # all outgoing messages are put in this list before being flushed to the socket,
        # so that even when we are reconnecting, messages can still be sent
        set outBuffer [list]
        set randomChan [tcl::chan::random [tcl::randomseed]] ;# generate inboxes
        set requestsInboxPrefix ""
        set jetStream ""
        set pong 1 ;# sync variable for vwait in "ping". Set to 1 to avoid a check for existing timer in "ping"
    }
    
    destructor {
        my disconnect
        close $randomChan
        $serverPool destroy
        ${logger}::delete
        if {$jetStream ne ""} {
            $jetStream destroy
        }
    }
    
    method cget {option} {
        set opt [string trimleft $option -]
        if {[info exists config($opt)]} {
            return $config($opt)
        }
        throw {NATS ErrInvalidArg} "Invalid option $option"
    }
    
    method configure {args} {
        if {[llength $args] == 0} {
            return [array get config]
        } 
        if {[llength $args] == 1} {
            if {$args ni {-help -?}} {
                return [my cget $args]
            }
        } 
        set args_copy $args ;# typedGetoptions will remove all known options from $args
        set usage "Usage: configure ?-option value?...\nValid options:"
        try {
            # basically I'm using cmdline only for argument validation and built-in help
            cmdline::typedGetoptions args $nats::option_syntax $usage
        } trap {CMDLINE USAGE} msg {
            # -help also leads here
            throw {NATS ErrInvalidArg} $msg
            # could be a bit nicer to check for $tcl_interactive, but in Komodo's shell it's 0 anyway :(
        }
        # -randomize may be one of the options, so process them *before* -servers
        foreach {opt val} $args_copy {
            set opt [string trimleft $opt -]
            set config($opt) $val
        }
        if {[dict exists $args_copy -servers]} {
            if {$status != $nats::status_closed} {
                # in principle, most other config options can be changed on the fly
                # allowing this to be changed when connected is possible, but a bit tricky
                throw {NATS ErrInvalidArg} "Cannot configure servers when already connected"
            }
            # if any URL is invalid, this function will throw an error - let it propagate
            $serverPool set_servers [dict get $args_copy -servers]
        }
        return
    }

    method reset {args} {
        foreach option $args {
            set opt [string trimleft $option -]
            set pos [lsearch -glob -index 0 $nats::option_syntax "$opt.*"]
            if {$pos != -1} {
                set config($opt) [lindex $nats::option_syntax $pos 1]
                if {$opt eq "servers"} {
                    $serverPool clear
                }
            } else {
                throw {NATS ErrInvalidArg} "Invalid option $option"
            }
        }
    }
    
    method logger {} {
        return $logger
    }
    
    method current_server {} {
        return [$serverPool current_server]
    }
    
    method all_servers {} {
        return [$serverPool all_servers]
    }
    
    method server_info {} {
        return [array get serverInfo]
    }
    
    method connect { args } {
        switch -- $args {
            -async {
                set async 1
            }
            "" {
                set async 0
            }
            default {
                throw {NATS ErrInvalidArg} "Unknown option $args"
            }
        }
        if {$status != $nats::status_closed} {
            return
        }
        
        if {[llength [$serverPool all_servers]] == 0} {
            throw {NATS ErrNoServers} "Server pool is empty"
        }
        set last_error ""
        # "reconnects" counter should be reset only once here rather than on every reconnect
        # e.g. if a server is in the pool, but it is down, we want to keep track of its "reconnects" counter
        # until the NATS connection is completely closed
        $serverPool reset_counters
        
        # this coroutine will handle all work to connect and read from the socket
        coroutine coro {*}[mymethod CoroMain]
        # now try connecting to the first server
        set status $nats::status_connecting
        $coro connect
        if {!$async} {
            ${logger}::debug "Waiting for connection"
            my CoroVwait [self object]::status
            if {$status != $nats::status_connected} {
                throw {NATS ErrNoServers} "No servers available for connection"
            }
            ${logger}::debug "Finished waiting for connection"
        }
        return
    }
    
    method disconnect {} {
        if {$status == $nats::status_closed} {
            return
        }
        
        if {$sock eq ""} {
            # if a user calls disconnect while we are waiting for reconnect_time_wait, we only need to stop the coroutine
            $coro stop
        } else {
            my CloseSocket
        }
        array unset subscriptions ;# make sure we don't try to "restore" subscriptions when we connect next time
        foreach reqID [array names requests] {
            # cancel pending async timers
            after cancel [nats::get_default $requests($reqID) timer ""]
        }
        array unset requests
        set requestsInboxPrefix ""
        if {$timers(connect) ne ""} {
            after cancel $timers(connect)
            ${logger}::debug "Cancelled connection timer $timers(connect)"
        }
        set timers(connect) ""
        #CoroMain will set status to "closed"
        return
    }
    
    method publish {subject message args} {
        set replySubj ""
        set header ""
        if {[llength $args] == 1} {
            set replySubj $args
        } else {
            foreach {opt val} $args {
                switch -- $opt {
                    -header {
                        set header $val
                    }
                    -reply {
                        set replySubj $val
                    }
                    default {
                        throw {NATS ErrInvalidArg} "Unknown option $opt"
                    }
                }
            }
        }
        my CheckConnection
        set msgLen [string length $message]
        if {$msgLen > $serverInfo(max_payload)} {
            throw {NATS ErrMaxPayload} "Maximum size of NATS message is $serverInfo(max_payload)"
        }
        if {$header ne "" && ![info exists serverInfo(headers)]} {
            throw {NATS ErrHeadersNotSupported} "Headers are not supported by this server"
        }
        
        if {![my CheckSubject $subject]} {
            throw {NATS ErrBadSubject} "Invalid subject $subject"
        }
        if {$replySubj ne "" && ![my CheckSubject $replySubj]} {
            throw {NATS ErrBadSubject} "Invalid reply $replySubj"
        }
        
        if {$header eq ""} {
            set ctrl_line "PUB $subject $replySubj $msgLen"
            lappend outBuffer $ctrl_line $message
        } else {
            try {
                set hdr [nats::format_header $header]
            } trap {TCL VALUE DICTIONARY} err {
                throw {NATS ErrInvalidArg} "header is not a valid dict"
            }
            set hdr_len [expr {[string length $hdr] + 2}] ;# account for one more crlf that will be added when flushing
            set ctrl_line "HPUB $subject $replySubj $hdr_len [expr {$msgLen+$hdr_len}]"
            lappend outBuffer $ctrl_line $hdr $message
        }
        
        my ScheduleFlush
        return
    }
    
    method subscribe {subject args } {
        my CheckConnection
        set queue ""
        set callback ""
        set maxMsgs 0 ;# unlimited by default
        set dictmsg $config(dictmsg)
        
        foreach {opt val} $args {
            switch -- $opt {
                -queue {
                    set queue $val
                }
                -callback {
                    set callback $val
                }
                -max_msgs {
                    set maxMsgs $val
                }
                -dictmsg {
                    set dictmsg $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {![my CheckWildcard $subject]} {
            throw {NATS ErrBadSubject} "Invalid subject $subject"
        }
        
        if {[string length $callback] == 0} {
            throw {NATS ErrInvalidArg} "Invalid callback"
        }
        
        if {! ([string is integer -strict $maxMsgs] && $maxMsgs >= 0)} {
            throw {NATS ErrInvalidArg} "Invalid max_msgs $maxMsgs"
        }
        
        if {![string is boolean -strict $dictmsg]} {
            throw {NATS ErrInvalidArg} "Invalid dictmsg $dictmsg"
        }
        
        #rules for queue names are more relaxed than for subjects
        # badQueue in nats.go checks for whitespace
        if {$queue ne "" && ![string is graph $queue]} {
            throw {NATS ErrInvalidArg} "Invalid queue group $queue"
        }
                                   
        set subID [incr counters(subscription)]
        set subscriptions($subID) [dict create subj $subject queue $queue cmd $callback maxMsgs $maxMsgs recMsgs 0 dictmsg $dictmsg]
        
        #the format is SUB <subject> [queue group] <sid>
        if {$status != $nats::status_reconnecting} {
            # it will be sent anyway when we reconnect
            lappend outBuffer "SUB $subject $queue $subID"
            if {$maxMsgs > 0} {
                lappend outBuffer "UNSUB $subID $maxMsgs"
            }
            my ScheduleFlush
        }
        return $subID
    }
    
    method unsubscribe {subID args} {
        my CheckConnection
        set maxMsgs 0 ;# unlimited by default
        foreach {opt val} $args {
            switch -- $opt {
                -max_msgs {
                    set maxMsgs $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {! ([string is integer -strict $maxMsgs] && $maxMsgs >= 0)} {
            throw {NATS ErrInvalidArg} "Invalid max_msgs $maxMsgs"
        }
        
        if {![info exists subscriptions($subID)]} {
            throw {NATS ErrBadSubscription} "Invalid subscription ID $subID"
        }
        
        #the format is UNSUB <sid> [max_msgs]
        if {$maxMsgs == 0 || [dict get $subscriptions($subID) recMsgs] >= $maxMsgs} {
            unset subscriptions($subID)
            set data "UNSUB $subID"
        } else {
            dict set subscriptions($subID) maxMsgs $maxMsgs
            set data "UNSUB $subID $maxMsgs"
        }
        if {$status != $nats::status_reconnecting} {
            # it will be sent anyway when we reconnect
            lappend outBuffer $data
            my ScheduleFlush
        }
        return
    }
    
    method request {subject message args} {
        set timeout -1 ;# ms
        set callback ""
        set dictmsg $config(dictmsg)
        set header ""
        set maxMsgs -1
        
        foreach {opt val} $args {
            switch -- $opt {
                -timeout {
                    nats::check_timeout $val
                    set timeout $val
                }
                -callback {
                    set callback $val
                }
                -dictmsg {
                    set dictmsg $val
                }
                -header {
                    set header $val
                }
                -max_msgs {
                    set maxMsgs $val
                    if {! ([string is integer -strict $maxMsgs] && $maxMsgs > 0)} {
                        throw {NATS ErrInvalidArg} "Invalid max_msgs $maxMsgs"
                    }
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {$maxMsgs > 1 && $callback eq ""} {
            throw {NATS ErrInvalidArg} "-max_msgs>1 can be used only in async request"
        }
        
        set reqID [incr counters(request)]
        
        if {$requestsInboxPrefix eq ""} {
            set requestsInboxPrefix [my inbox]
            my subscribe "$requestsInboxPrefix.*" -dictmsg 1 -callback [mymethod RequestCallback -1]
        }
        
        set subID ""
        
        if {$maxMsgs == -1} {
            # "new-style" request with one wildcard subscription
            # only the first response is delivered
            # will perform more argument checking, so it may raise an error
            my publish $subject $message -reply "$requestsInboxPrefix.$reqID" -header $header
        } else {
            # "old-style" request with a SUB per each request is needed for JetStream,
            # because messages received from a stream have a subject that differs from our reply-to
            # $maxMsgs is always 1 for sync requests
            set subID [my subscribe "$requestsInboxPrefix.JS.$reqID" -dictmsg 1 -callback [mymethod RequestCallback $reqID] -max_msgs $maxMsgs]
            my publish $subject $message -reply "$requestsInboxPrefix.JS.$reqID" -header $header
        }
        
        set timerID ""
        if {$timeout != -1} {
            # RequestCallback is called in all cases: timeout/no timeout, sync/async request
            set timerID [after $timeout [mymethod RequestCallback $reqID]]
        }
        if {$callback ne ""} {
            # async request
            set requests($reqID) [dict create timer $timerID callback $callback isDictMsg $dictmsg subID $subID maxMsgs $maxMsgs recMsgs 0]
            return
        }
        # sync request
        # remember that we can get a reply after timeout, so vwait must wait on a specific reqID
        set requests($reqID) 0
        my CoroVwait [self object]::requests($reqID)
        set sync_req $requests($reqID)
        unset requests($reqID)
        if {[dict get $sync_req timedOut]} {
            if {$subID ne ""} {
                unset subscriptions($subID)
            }
            throw {NATS ErrTimeout} "Request to $subject timed out"
        }
        after cancel $timerID
        set response [dict get $sync_req response]
        set in_hdr [dict get $response header]
        if {[nats::get_default $in_hdr Status 0] == 503} {
            throw {NATS ErrNoResponders} "No responders available for request"
        }
        if {$dictmsg} {
            return $response
        } else {
            return [dict get $response data]
        }
    }
    
    #this function is called "flush" in all other NATS clients, but I find it confusing
    # default timeout in nats.go is 10s
    method ping { args } {
        set timeout 10000
        foreach {opt val} $args {
            switch -- $opt {
                -timeout {
                    nats::check_timeout $val
                    set timeout $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {$status != $nats::status_connected} {
            # unlike CheckConnection, here we want to raise the error also if the client is reconnecting, in line with cnats
            throw {NATS ErrConnectionClosed} "No connection to NATS server"
        }

        set timerID [after $timeout [list set [self object]::pong 0]]

        lappend outBuffer "PING"
        ${logger}::debug "sending PING"
        my ScheduleFlush
        my CoroVwait [self object]::pong
        if {$pong} {
            after cancel $timerID
            return true
        }
        throw {NATS ErrTimeout} "PING timeout"
    }

    # get jet stream object
    method jet_stream {} {
        if {$jetStream eq ""} {
            set jetStream [::nats::jet_stream new [self]]
        }
        return $jetStream
    }
    
    method inbox {} {
        # very quick and dirty!
        return "_INBOX.[binary encode hex [read $randomChan 10]]"
    }
    
    method RequestCallback { reqID {subj ""} {msg ""} {reply ""} } {
        if {$subj eq "" && $reqID != -1} {
            # request timed out
            set callback [nats::get_default $requests($reqID) callback ""]
            if {$callback ne ""} {
                after 0 [list {*}$callback 1 ""]
                unset requests($reqID)
            } else {
                #sync request - exit from vwait in "method request"
                set requests($reqID) [dict create timedOut 1 response ""]
            }
            return
        }
        # we received a NATS message
        # $msg is always a dict in this method, and it already contains (optional) $reply in it, so we just pass it over to users
        if {$reqID == -1} {
            # new-style request
            set reqID [lindex [split $subj .] 2]
        }
        if {![info exists requests($reqID)]} {
            # ignore all further responses, if >1 arrives; or it could be an overdue message
            # ${logger}::debug "RequestCallback got [string range $msg 0 15] on reqID $reqID - discarded"
            return
        }
        # most of these variables will be empty in case of a sync request
        set callback [nats::get_default $requests($reqID) callback ""]
        if {$callback eq ""} {
            # resume from vwait in "method request"; "requests" array will be cleaned up there
            set requests($reqID) [dict create timedOut 0 response $msg]
            return
        }
        # handle the async request
        set timedOut 0
        set in_hdr [dict get $msg header]
        if {[nats::get_default $in_hdr Status 0] == 503} {
            # no-responders is equivalent to timedOut=1
            set timedOut 1
        }
        if {![dict get $requests($reqID) isDictMsg]} {
            set msg [dict get $msg data]
        }

        after 0 [list {*}$callback $timedOut $msg]
        set subID [dict get $requests($reqID) subID]
        if {$subID eq ""} {
            # new-style request - we expect only one message
            after cancel [dict get $requests($reqID) timer]
            unset requests($reqID)
        } else {
            # important! I can't simply check for [info exists subscriptions] here, because the subscription might have already been deleted,
            # while RequestCallback events are still in the event queue
            # so I need separate counters of maxMsgs, recMsgs for requests
            set maxMsgs [dict get $requests($reqID) maxMsgs]
            set recMsgs [dict get $requests($reqID) recMsgs]
            incr recMsgs
            if {$maxMsgs > 0 && $maxMsgs == $recMsgs} {
                after cancel [dict get $requests($reqID) timer] ;# in this case the timer applies to all $maxMsgs messages
                unset requests($reqID)
            } else {
                dict set requests($reqID) recMsgs $recMsgs
            }
        }
    }
    
    method CloseSocket { {broken 0} } {
        # this method is only for closing an established TCP connection
        # it is not convenient to re-use it for all cases of close $sock (timeout or rejected connection)
        # because it does a lot of other work
        
        chan event $sock readable {}
        if {$broken} {
            if {$status != $nats::status_connected} {
                # whether we are connecting or reconnecting, increment reconnect count for this server
                $serverPool current_server_connected false
            }
            if {$status == $nats::status_connected} {
                # recall that during initial connection round we try all servers only once
                # method next_server relies on this status to know that
                set status $nats::status_reconnecting
            }
        } else {
            # we get here only from method disconnect
            lassign [my current_server] host port
            ${logger}::info "Closing connection to $host:$port" ;# in case of broken socket, the error will be logged elsewhere
            # make sure we wait until successful flush, if connection was not broken
            chan configure $sock -blocking 1
            foreach msg $outBuffer {
                append msg "\r\n"
                puts -nonewline $sock $msg
            }
            set outBuffer [list]
        }
        close $sock ;# all buffered input is discarded, all buffered output is flushed
        set sock ""
        after cancel $timers(ping)
        after cancel $timers(flush)
        set timers(flush) ""
        
        if {[info coroutine] eq ""} {
            if {!$broken} {
                $coro stop
            }
        }
    }
    
    method Pinger {} {
        set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
        
        if {$counters(pendingPings) >= $config(max_outstanding_pings)} {
            my AsyncError ErrStaleConnection "The server did not respond on $counters(pendingPings) PINGs"
            my CloseSocket 1
            set counters(pendingPings) 0
            $coro connect
            return
        }
        
        lappend outBuffer "PING"
        ${logger}::debug "Sending PING"
        incr counters(pendingPings)
        my ScheduleFlush
    }
    
    method ScheduleFlush {} {
        if {$timers(flush) eq "" && $status == $nats::status_connected} {
            set timers(flush) [after 0 [mymethod Flusher]]
        }
    }
    
    method Flusher { } {
        set timers(flush) ""
        try {
            foreach msg $outBuffer {
                append msg "\r\n"
                puts -nonewline $sock $msg
            }
            flush $sock
        } on error err {
            lassign [my current_server] host port
            my AsyncError ErrBrokenSocket "Failed to send data to $host:$port: $err"
            my CloseSocket 1
            $coro connect
            return
        }
        # do NOT clear the buffer unless we had a successful flush!
        set outBuffer [list]
    }
    
    method CoroVwait {var} {
        if {[info coroutine] eq ""} {
            vwait $var
        } else {
            coroutine::util vwait $var
        }
    }
    
    # --------- these procs execute in the coroutine ---------------
    # connect to Nth server in the pool
    method ConnectNextServer {} {
        # if it throws ErrNoServers, we have exhausted all servers in the pool
        # we must stop the coroutine, so let the error propagate
        lassign [$serverPool next_server] host port ;# it may wait for reconnect_time_wait ms!
        ${logger}::info "Connecting to the server at $host:$port"
        set sock [socket -async $host $port]
        chan event $sock writable [list $coro connected]
    }
    
    method SendConnect {tls_done} {
        try {
            # I guess I should preserve this stupid global variable
            set ind [json::write::indented]
            json::write::indented false
            
            # tls_required=true in CONNECT seems unnecessary to me, because TLS handshake has already happened
            # but nats.go does this
            set connectParams [list verbose [nats::bool2json $config(verbose)] \
                                    pedantic [nats::bool2json $config(pedantic)] \
                                    tls_required [nats::bool2json $tls_done] \
                                    name [json::write::string $config(name)] \
                                    lang [json::write::string Tcl] \
                                    version [json::write::string 1.0] \
                                    protocol 1 \
                                    echo [nats::bool2json $config(echo)] ] 
            
            if {[info exists serverInfo(headers)] && $serverInfo(headers)} {
                lappend connectParams headers true no_responders true
            }
            if {[info exists serverInfo(auth_required)] && $serverInfo(auth_required)} {
                lappend connectParams {*}[$serverPool format_credentials]
            } 
            set jsonMsg [json::write::object {*}$connectParams]
        } trap {NATS ErrAuthorization} err {
            # no credentials could be found for this server, try next one
            my AsyncError ErrAuthorization $err 1
            return
        } finally {
            json::write::indented $ind
        }
        
        # do NOT use outBuffer here! it may have pending messages from a previous connection
        # we can flush them only after authentication is confirmed
        puts -nonewline $sock "CONNECT $jsonMsg\r\n"
        puts -nonewline $sock "PING\r\n"
        flush $sock
        # rest of the handshake is done in method PONG 
    }
    
    method RestoreSubs {} {
        foreach subID [array names subscriptions] {
            set subject [dict get $subscriptions($subID) subj]
            set queue [dict get $subscriptions($subID) queue]
            set maxMsgs [dict get $subscriptions($subID) maxMsgs]
            set recMsgs [dict get $subscriptions($subID) recMsgs]
            lappend outBuffer "SUB $subject $queue $subID"
            if {$maxMsgs > 0} {
                set remainingMsgs [expr {$maxMsgs - $recMsgs}]
                lappend outBuffer "UNSUB $subID $remainingMsgs"
            }
        }
    }
    
    method INFO {cmd} {
        if {$status == $nats::status_connected} {
            # when we say "proto":1 in CONNECT, we may receive information about other servers in the cluster - add them to serverPool
            # and mark as discovered=true
            # example connect_urls : ["192.168.2.5:4222", "192.168.91.1:4222", "192.168.157.1:4223", "192.168.2.5:4223"]
            # by default each server will advertise IPs of all network interfaces, so the server pool may seem bigger than it really is
            # --client_advertise NATS option can be used to make it clearer
            set infoDict [json::json2dict $cmd]
            if {[dict exists $infoDict connect_urls]} {
                ${logger}::debug "Got connect_urls: [dict get $infoDict connect_urls]"
                foreach url [dict get $infoDict connect_urls] {
                    $serverPool add $url
                }
            }
            return
        }
        # we are establishing a new connection...
        # example info
        #{"server_id":"kfNjUNirYU3tRVC7akGOcS","version":"1.4.1","proto":1,"go":"go1.11.5","host":"0.0.0.0","port":4222,"max_payload":1048576,"client_id":3,"client_ip":"::1"}
        # optional: auth_required, tls_required, tls_verify
        array unset serverInfo ;# do not unset it in CloseSocket!
        # otherwise publishing messages while reconnecting does not work, due to the check for max_payload
        array set serverInfo [json::json2dict $cmd]
        set tls_done 0
        lassign [my current_server] host port
        set scheme [dict get [lindex [$serverPool all_servers] end] scheme]
        if {[info exists serverInfo(tls_required)] && $serverInfo(tls_required)} {
            #NB! NATS server will never accept a TLS connection. Always start connecting with plain TCP,
            # and only after receiving INFO, we can upgrade to TLS if needed
            package require tls
            # for simplicity, let's switch to the blocking mode just for the handshake
            chan configure $sock -blocking 1
            try {
                tls::import $sock {*}$config(default_tls_opts) {*}$config(tls_opts)
                tls::handshake $sock
                set tls_done 1
                # -errorcode will be NONE
            } on error err {
                my AsyncError ErrTLS "TLS handshake with server $host:$port failed: $err" 1
                return
            }
            chan configure $sock -blocking 0
        } elseif {$config(secure) || $scheme eq "tls"} {
            # the client requires TLS, but the server doesn't provide it
            my AsyncError ErrSecureConnWanted "Server $host:$port does not provide TLS" 1
            return
        }
        my SendConnect $tls_done
    }
    
    method MSG {cmd {with_headers 0}} {
        # HMSG is also handled here
        set replyTo ""
        set expHdrLength 0
        if {$with_headers} {
            # the format is HMSG <subject> <sid> [reply-to] <#hdr bytes> <#total bytes>
            if {[llength $cmd] == 5} {
                lassign $cmd subject subID replyTo expHdrLength expMsgLength
            } else {
                lassign $cmd subject subID expHdrLength expMsgLength
            }
        } else {
            # the format is MSG <subject> <sid> [reply-to] <#bytes>
            if {[llength $cmd] == 4} {
                lassign $cmd subject subID replyTo expMsgLength
            } else {
                lassign $cmd subject subID expMsgLength
            }
        }
        # easier to read both headers and the body together as binary data; also fewer calls to chan read
        # turn off crlf translation while we read the message body
        chan configure $sock -translation binary
        # account for these crlf bytes that follow the message
        incr expMsgLength 2
        set remainingBytes $expMsgLength ;# how many bytes left to read until the message is complete
        set payload "" ;# both header (if any) and body
        while {1} {
            append payload [chan read $sock $remainingBytes]
            if {[eof $sock]} {
                # server closed the socket - Tcl will invoke "CoroMain readable" again and close the socket
                # so no need to do anything here
                return
            }
            set actualLength [string length $payload]
            # probably == should work ok, but just for safety let's use >=
            if {$actualLength >= $expMsgLength} {
                break
            }
            set remainingBytes [expr {$expMsgLength - $actualLength}]
            # wait for the remainder of the message; we may need multiple reads to receive all of it
            # it's cleaner to have a second "yield" here than putting this logic in CoroMain
            set reason [yield]
            switch -- $reason {
                readable {
                    continue
                }
                stop {
                    throw {NATS STOP_CORO} "Stop coroutine" ;# break from the main loop
                }
                default {
                    ${logger}::error "MSG: unknown reason $reason"
                }
            }
        }
        # revert to our default translation
        chan configure $sock -translation {crlf binary}
        
        if {[info exists subscriptions($subID)]} {
            set maxMsgs [dict get $subscriptions($subID) maxMsgs]
            set recMsgs [dict get $subscriptions($subID) recMsgs]
            set cmdPrefix [dict get $subscriptions($subID) cmd]
            set header ""
            if {$expHdrLength > 0} {
                try {
                    set header [nats::parse_header [string range $payload 0 $expHdrLength-1]]
                } trap {NATS ErrBadHeaderMsg} err {
                    # invalid header causes an async error, nevertheless the message is delivered, see nats.go, func processMsg
                    my AsyncError ErrBadHeaderMsg $err
                }
            }
            set body [string range $payload $expHdrLength end-2] ;# discard \r\n at the end
            if {[dict get $subscriptions($subID) dictmsg]} {
                # deliver the message as a dict, including headers, if any
                # even though replyTo is passed to the callback, let's include it in the dict too
                # so that we don't need do to it in RequestCallback
                set msg [dict create header $header data $body subject $subject reply $replyTo sub_id $subID]
            } else {
                # deliver the message as an opaque string
                set msg $body 
            }
            
            after 0 [list {*}$cmdPrefix $subject $msg $replyTo]
            # interesting: if I try calling RequestCallback directly instead of "after 0", it crashes tclsh
            
            incr recMsgs
            if {$maxMsgs > 0 && $maxMsgs == $recMsgs} {
                unset subscriptions($subID) ;# UNSUB has already been sent, no need to do it here
            } else {
                dict set subscriptions($subID) recMsgs $recMsgs
            }
        } else {
            # if we unsubscribe while there are pending incoming messages, we may get here - nothing to do
            #${logger}::debug "Got [string range $messageBody 0 15] on subID $subID - discarded"
        }
        # now we return back to CoroMain and enter "yield" there
    }
    
    method PING {cmd} {
        lappend outBuffer "PONG"
        ${logger}::debug "received PING, sending PONG"
        my ScheduleFlush
    }
    
    method PONG {cmd} {
        set pong 1
        set counters(pendingPings) 0
        ${logger}::debug "received PONG"
        if {$status != $nats::status_connected} {
            # auth OK: finalise the connection process
            $serverPool current_server_connected true
            lassign [my current_server] host port
            ${logger}::info "Connected to the server at $host:$port"
            # exit from vwait in "connect"
            set status $nats::status_connected
            my RestoreSubs
            my ScheduleFlush
            set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
        }
    }
    
    method OK {cmd} {
        # nothing to do
    }
    
    method ERR {cmd} {
        set errMsg [string tolower [string trim $cmd " '"]] ;# remove blanks and single quotes around the message
        if [string match "stale connection*" $errMsg] {
            my AsyncError ErrStaleConnection $errMsg 1
            return
        }
        
        if [string match "authorization violation*" $errMsg] {
            my AsyncError ErrAuthorization $errMsg 1
            return
        }
        if [string match "user authentication expired*" $errMsg] {
            my AsyncError ErrAuthExpired $errMsg 1
            return
        }
        if [string match "user authentication revoked*" $errMsg] {
            my AsyncError ErrAuthRevoked $errMsg 1
            return
        }
        if [string match "account authentication expired*" $errMsg] {
            #nats server account authorization has expired
            my AsyncError ErrAccountAuthExpired $errMsg 1
            return
        }
        # non-critical errors that do not close the connection
        if [string match "permissions violation*" $errMsg] {
            my AsyncError ErrPermissions $errMsg
            return
        }
        if [string match "invalid *subject*" $errMsg] {
            #only in the pedantic mode; even nats.go doesn't recognise properly this error
            # server will respond "invalid subject" to SUB and "invalid publish subject"
            my AsyncError ErrBadSubject $errMsg
            return
        }
        # some other errors that don't have an associated error code
        my AsyncError ErrServer $errMsg 1
    }
    
    method CoroMain {} {
        set coro [info coroutine]
        ${logger}::debug "Started coroutine $coro"
        try {
            while {1} {
                set reason [yield]
                if {$reason eq "stop"} {
                    break
                }
                if {$reason in [list connect connected connect_timeout readable]} {
                    my ProcessEvent $reason
                } else {
                    ${logger}::error "CoroMain: unknown reason $reason"
                }
            }
        } trap {NATS STOP_CORO} {msg opts} {
            # we get here after call to "disconnect" during MSG or next_server; the socket has been already closed,
            # so we only need to update the status
        } trap {NATS} {msg opts} {
            # ErrNoServers error from next_server leads here; don't overwrite the real last_error
            # need to log this in case user called "connect -async"
            ${logger}::error $msg
        } trap {} {msg opts} {
            ${logger}::error "Unexpected error: $msg $opts"
        }
        set status $nats::status_closed
        ${logger}::debug "Finished coroutine $coro"
    }
    
    method ProcessEvent {reason} {
        switch -- $reason {
            connect {
                my ConnectNextServer
            }
            connected {
                # this event will arrive again and again if we don't disable it
                chan event $sock writable {}
                lassign [my current_server] host port
                # the socket either connected or failed to connect
                set errorMsg [chan configure $sock -error]
                if { $errorMsg ne "" } {
                    close $sock
                    $serverPool current_server_connected false
                    my AsyncError ErrConnectionRefused "Failed to connect to $host:$port: $errorMsg"
                    my ConnectNextServer
                    return
                }
                # connection succeeded
                # we want to call "flush" ourselves, so use -buffering full
                # NATS protocol uses crlf as a delimiter
                # when reading from the socket, it's easier to let Tcl do EOL translation, unless we are in method MSG
                # when writing to the socket, we need to turn off the translation when sending a message payload
                # but outBuffer doesn't know which element is a message, so it's easier to write CR+LF ourselves
                chan configure $sock -translation {crlf binary} -blocking 0 -buffering full -encoding binary
                chan event $sock readable [list $coro readable]
            }
            connect_timeout {
                # we get here both in case of TCP-level timeout and if the server does not reply to the initial PING/PONG on time
                lassign [my current_server] host port
                close $sock
                my AsyncError ErrConnectionTimeout "Connection timeout for $host:$port"
                $serverPool current_server_connected false
                my ConnectNextServer
            }
            readable {
                # the chan readable event will be sent again and again for as long as there's pending data
                # so I don't need a loop around [chan gets] to read all lines, even if they arrive together
                try {
                    set readCount [chan gets $sock line]
                } trap {POSIX ECONNABORTED} {err errOpts} {
                    # can happen only on Linux
                    lassign [my current_server] host port
                    my AsyncError ErrBrokenSocket "Server $host:$port [lindex [dict get $errOpts -errorcode] end]" 1
                    return
                }
                if {$readCount < 0} {
                    if {[eof $sock]} { 
                        #set err [chan configure $sock -error] - no point in this, $err will be blank
                        lassign [my current_server] host port
                        my AsyncError ErrBrokenSocket "Server $host:$port closed the connection" 1
                        return
                    }
                    if {[chan pending input $sock] > 1024} {
                        # do not let the buffer grow forever if \r\n never arrives
                        # max length of control line in the NATS protocol is 1024 (see MAX_CONTROL_LINE_SIZE in nats.py)
                        # this should not happen unless the NATS server is malfunctioning
                        my AsyncError ErrServer "Maximum control line exceeded" 1
                        return
                    }
                    # else - we don't have a full line yet - wait for next chan event
                    return
                }
                # extract the first word from the line (INFO, MSG etc)
                # protocol_arg will be empty in case of PING/PONG/OK
                set protocol_arg [lassign $line protocol_op]
                # in case of -ERR or +OK
                set protocol_op [string trimleft $protocol_op -+]
                if {$protocol_op eq "HMSG"} {
                    my MSG $protocol_arg 1
                    return
                }
                if {$protocol_op in {MSG INFO ERR OK PING PONG}} {
                    my $protocol_op $protocol_arg
                } else {
                    ${logger}::warn "Invalid protocol $protocol_op $protocol_arg"
                }
            }
        }
    }
    
    # ------------ coroutine end -----------------------------------------
    
    method CheckSubject {subj} {
        if {[string length $subj] == 0} {
            return false
        }
        if {!$config(check_subjects)} {
            return true
        }
        foreach token [split $subj .] {
            if {[regexp -- $subjectRegex $token]} {
                continue
            }
            return false
        }
        return true
    }
    
    method CheckWildcard {subj} {            
        if {[string length $subj] == 0} {
            return false
        }
        if {!$config(check_subjects)} {
            return true
        }
        foreach token [split $subj .] {
            if {[regexp -- $subjectRegex $token] || $token == "*" || $token == ">" } {
                continue
            }
            return false
        }
        return true
    }
    
    method CheckConnection {} {
        # allow PUB & SUB when connected or reconnecting, throw an error otherwise
        if {$status in [list $nats::status_closed $nats::status_connecting] } {
            throw {NATS ErrConnectionClosed} "No connection to NATS server"
        }
    }
    
    method AsyncError {code msg { doReconnect 0 }} {
        ${logger}::error $msg
        # errorMessage used to be just "message", but I already have many other messages in the code
        set last_error [dict create code "NATS $code" errorMessage $msg]
        if {$doReconnect} {
            my CloseSocket 1
            my ConnectNextServer ;# can be done only in the coro
        }
    }
}

# all following procs are private!
proc ::nats::check_timeout {timeout} {
    if {! ([string is integer -strict $timeout] && $timeout >= -1)} {
        throw {NATS ErrBadTimeout} "Invalid timeout $timeout"
    }
}
proc ::nats::timestamp {} {
    # workaround for not being able to format current time with millisecond precision
    # should not be needed in Tcl 8.7, see https://core.tcl-lang.org/tips/doc/trunk/tip/423.md
    set t [clock milliseconds]
    set timeStamp [format "%s.%03d" \
                      [clock format [expr {$t / 1000}] -format %T] \
                      [expr {$t % 1000}] ]
    return $timeStamp
}
proc ::nats::log_stdout {service level text} {
    puts "\[[nats::timestamp] $service $level\] $text"
}
# returns a dict, where each key points to a list of values
# NB! unlike HTTP headers, in NATS headers keys are case-sensitive
proc ::nats::parse_header {header} {
    set result [dict create]
    set i 0
    foreach line [textutil::split::splitx $header {\r\n}] {
        if {$line eq ""} {
            # the header finishes with \r\n\r\n, so splitx will return a list with an empty element in the end
            continue
        }
        if {$i == 0} {
            set descr [lassign $line protocol status]
            if {$protocol ne "NATS/1.0"} {
                throw {NATS ErrBadHeaderMsg} "Unknown protocol $protocol"
            }
            if {$status ne ""} {
                if {! ([string is integer $status] && $status > 0)} {
                    throw {NATS ErrBadHeaderMsg} "Invalid status $status"
                }
                dict set result Status $status
            }
            if {$descr ne ""} {
                dict set result Description $descr
            }
        } else {
            lassign [split $line :] k v
            set k [string trim $k]
            set v [string trim $v]
            if {$k ne "" && $v ne ""} {
                dict lappend result $k $v
            }
            # strictly speaking, I should raise an error if k or v are empty
        }
        incr i
    }
    return $result
}
proc ::nats::format_header { header } {
    # other official clients accept inline status & description in the first line when *parsing* headers
    # but when serializing headers, status & description are treated just like usual headers
    # so I will do the same, and it simplifies my job here
    set result "NATS/1.0\r\n"
    dict for {k v} $header {
        foreach el $v {
            append result "$k: $el\r\n"
        }
    }
    # don't append one more \r\n here! the header is put into outBuffer as a separate element
    # so \r\n will be added when flushing
    return $result
}

# because there's no json::write::boolean
proc ::nats::bool2json {val} {
    if {[string is true -strict $val]} {
        return true
    } else {
        return false
    }
}

# pending TIP 342 in Tcl 8.7
proc ::nats::get_default {dict_val key def} {
    if {[dict exists $dict_val $key]} {
        return [dict get $dict_val $key]
    } else {
        return $def
    }
}

# by default, when a handshake fails, the TLS library reports it to stderr AND raises an error - see tls.c, function Tls_Error
# so I end up with the same message logged twice. Let's suppress stderr altogether
proc ::nats::tls_callback {args} { }

package provide nats 1.0

# Let me respectfully remind you:
# Birth and death are of supreme importance.
# Time swiftly passes and opportunity is lost.
# Do not squander your life!
