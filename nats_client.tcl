# Copyright (c) 2020-2021 Petro Kazmirchuk https://github.com/Kazmirchuk

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
    { tls_opts.list ""                  "Options for tls::import"}
    { user.list ""                      "Default username"}
    { password.list ""                  "Default password"}
    { token.arg ""                      "Default authentication token"}
    { secure.boolean false              "Indicate to the server if the client wants a TLS connection"}
    { check_subjects.boolean true       "Enable client-side checking of subjects when publishing or subscribing"}
}

oo::class create ::nats::connection {
    # "private" variables
    variable config sock coro timers counters subscriptions requests serverInfo serverPool \
             subjectRegex outBuffer randomChan requestsInboxPrefix pong logger
    
    # "public" variables, so that users can set up traces if needed
    variable status last_error

    constructor { { conn_name "" } } {
        set status $nats::status_closed
        set last_error ""
        
        # initialise default configuration
        foreach option $nats::option_syntax {
            lassign $option name defValue comment
            #drop everything after dot
            set name [lindex [split $name .] 0]
            set config($name) $defValue
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
        # async reqs: reqID -> {1 timer callback} ; sync requests: reqID -> {0 timedOut response}
        # RequestCallback needs to distinguish between sync and async, so we need 0/1 in front
        array set requests {} 
        array set serverInfo {} ;# INFO from a current NATS server
        set serverPool [nats::server_pool new [self object]] 
        #consider replacing with string is alnum? does this allow Unicode?
        set subjectRegex {^[[:alnum:]_-]+$}
        # all outgoing messages are put in this list before being flushed to the socket,
        # so that even when we are reconnecting, messages can still be sent
        set outBuffer [list]
        set randomChan [tcl::chan::random [tcl::randomseed]] ;# generate inboxes
        set requestsInboxPrefix ""
        set pong 1 ;# sync variable for vwait in "ping". Set to 1 to avoid a check for existing timer in "ping"
    }
    
    destructor {
        my disconnect
        close $randomChan
        $serverPool destroy
        ${logger}::delete
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
            puts $msg
            return
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
        foreach {opt val} $args_copy {
            set opt [string trimleft $opt -]
            set config($opt) $val
        }
        return
    }

    method reset {option} {
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
    
    method logger {} {
        return $logger
    }
    
    method current_server {} {
        return [$serverPool current_server]
    }
    
    method all_servers {} {
        return [$serverPool all_servers]
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
        $serverPool reset_counters
        set last_error ""
        
        # this coroutine will handle all work to connect and read from the socket
        coroutine coro {*}[mymethod CoroMain]
        # now try connecting to the first server
        set status $nats::status_connecting
        $coro connect
        if {!$async} {
            ${logger}::debug "Waiting for connection"
            my CoroVwait [self object]::status
            if {$status != $nats::status_connected} {
                #NTH: report a more specific error like AUTH_FAILED,TLS_FAILED if server pool=1? check with other NATS clients
                throw {NATS ErrNoServers} "No NATS servers available"
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
        array unset requests
        set requestsInboxPrefix ""
        after cancel $timers(connect)
        ${logger}::debug "Cancelled connection timer $timers(connect)"
        set timers(connect) ""
        #CoroMain will set status to "closed"
        return
    }
    
    method publish {subject msg {replySubj ""}} {
        my CheckConnection
        set msgLen [string length $msg]
        if {$msgLen > $serverInfo(max_payload)} {
            throw {NATS ErrMaxPayload} "Maximum size of NATS message is $serverInfo(max_payload)"
        }
        
        if {![my CheckSubject $subject]} {
            throw {NATS ErrBadSubject} "Invalid subject $subject"
        }
        
        set data "PUB $subject $replySubj $msgLen"
        lappend outBuffer $data $msg
        my ScheduleFlush
        return
    }
    
    method subscribe {subject args } { 
        my CheckConnection
        set queue ""
        set callback ""
        set maxMsgs 0
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
        
        #rules for queue names are more relaxed than for subjects
        # badQueue in nats.go checks for whitespace
        if {$queue ne "" && ![string is graph $queue]} {
            throw {NATS ErrInvalidArg} "Invalid queue group $queue"
        }
                                   
        set subID [incr counters(subscription)]
        set subscriptions($subID) [dict create subj $subject queue $queue cmd $callback maxMsgs $maxMsgs recMsgs 0]
        
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
        set maxMsgs 0
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
        
        foreach {opt val} $args {
            switch -- $opt {
                -timeout {
                    my CheckTimeout $val
                    set timeout $val
                }
                -callback {
                    set callback $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {$requestsInboxPrefix eq ""} {
            set requestsInboxPrefix [my inbox]
            my subscribe "$requestsInboxPrefix.*" -callback [mymethod RequestCallback]
        }
        
        set timerID ""
        set reqID [incr counters(request)]
        my publish $subject $message "$requestsInboxPrefix.$reqID"
        if {$callback eq ""} {
            # sync request
            # remember that we can get a reply after timeout, so vwait must wait on a specific reqID
            if {$timeout != -1} {
                 set timerID [after $timeout [list set [self object]::requests($reqID) [list 0 1 ""]]]
            }
            set requests($reqID) [list 0]
            my CoroVwait [self object]::requests($reqID)
            lassign $requests($reqID) ignored timedOut response
            unset requests($reqID)
            if {$timedOut} {
                throw {NATS ErrTimeout} "Request to $subject timed out"
            }
            after cancel $timerID
            return $response
        }
        # async request
        if {$timeout != -1} {  
            set timerID [after $timeout [mymethod RequestCallback "" "" "" $reqID]]
        }
        set requests($reqID) [list 1 $timerID $callback]
        return
    }
    
    #this function is called "flush" in all other NATS clients, but I find it confusing
    # default timeout in nats.go is 10s
    method ping { args } {
        set timeout 10000
        foreach {opt val} $args {
            switch -- $opt {
                -timeout {
                    my CheckTimeout $val
                    set timeout $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        my CheckTimeout $timeout
        
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
    
    method inbox {} {
        # very quick and dirty!
        return "_INBOX.[binary encode hex [read $randomChan 10]]"
    }
    
    method RequestCallback {subj msg reply {reqID_timeout 0}} {
        if {$reqID_timeout != 0} {
            #async request timed out
            lassign $requests($reqID_timeout) ignored timerID callback
            after 0 [list {*}$callback 1 ""]
            unset requests($reqID_timeout)
            return
        }
        # we received a NATS message
        set reqID [lindex [split $subj .] 2]
        if {![info exists requests($reqID)]} {
            # ignore all further responses, if >1 arrives; or it could be an overdue message
            ${logger}::debug "RequestCallback got [string range $msg 0 15] on reqID $reqID - discarded"
            return
        }
        lassign $requests($reqID) reqType timer callback
        if {$reqType == 0} {
            # resume from vwait in "method request"; "requests" array will be cleaned up there
            set requests($reqID) [list 0 0 $msg]
            return
        }
        after cancel $timer
        after 0 [list {*}$callback 0 $msg]
        unset requests($reqID)
    }
    
    method CloseSocket { {broken 0} } {
        # this method is only for closing an established connection
        # it is not convenient to re-use it for all cases of close $sock
        # because it does a lot of other work
        
        chan event $sock readable {}
        if {$broken} {
            $serverPool current_server_connected false
            if {$status != $nats::status_connecting} {
                # recall that during initial connection round we try all servers only once
                # method next_server relies on this status to know that
                set status $nats::status_reconnecting
            }
        } else {
            # we get here only from method disconnect
            lassign [$serverPool current_server] host port
            ${logger}::info "Closing connection to $host:$port" ;# in case of broken socket, the error will be logged elsewhere
            # make sure we wait until successful flush, if connection was not broken
            # TODO do it only for destructor? before exiting process
            chan configure $sock -blocking 1
            foreach msg $outBuffer {
                append msg "\r\n"
                puts -nonewline $sock $msg
            }
            set outBuffer [list]
        }
        close $sock ;# all buffered input is discarded, all buffered output is flushed
        set sock ""
        array unset serverInfo
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
            chan flush $sock
        } on error err {
            lassign [$serverPool current_server] host port
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
    
    method SendConnect {} {
        # I guess I should preserve this stupid global variable
        set ind [json::write::indented]
        json::write::indented false
        set connectParams [list verbose $config(verbose) \
                                pedantic $config(pedantic) \
                                tls_required false \
                                name [json::write::string $config(name)] \
                                lang [json::write::string Tcl] \
                                version [json::write::string 0.9] \
                                protocol 1 \
                                echo $config(echo)]
        
        if {[info exists serverInfo(auth_required)] && $serverInfo(auth_required)} {
            try {
                lappend connectParams {*}[$serverPool format_credentials]
            } trap {NATS NO_CREDS} err {
                #TODO: try another server
            }
        } 

        set jsonMsg [json::write::object {*}$connectParams]
        json::write::indented $ind
        lappend outBuffer "CONNECT $jsonMsg"
        lappend outBuffer "PING"
        my Flusher
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
        # SendConnect will flush
    }
    
    method INFO {cmd} {
        if {$status == $nats::status_connected} {
            # when we say "proto":1 in CONNECT, we may receive information about other servers in the cluster - add them to serverPool
            #example info:
            # server_id NDHBLLCIGK3PQKD5RUAUPCZAO6HCLQC4MNHQYRF22T32X2I2DHKEUGGQ server_name NDHBLLCIGK3PQKD5RUAUPCZAO6HCLQC4MNHQYRF22T32X2I2DHKEUGGQ version 2.1.7 proto 1 git_commit bf0930e
            # go go1.13.10 host 0.0.0.0 port 4222 max_payload 1048576 client_id 1 client_ip ::1 connect_urls
            # {192.168.2.5:4222 192.168.91.1:4222 192.168.157.1:4222 192.168.157.1:4223 192.168.2.5:4223 192.168.91.1:4223}
            set infoDict [json::json2dict $cmd]
            if {[dict exists $infoDict connect_urls]} {
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
        array set serverInfo [json::json2dict $cmd]
        if {[info exists serverInfo(tls_required)] && $serverInfo(tls_required)} {
            #NB! NATS server will never accept a TLS connection. Always start connecting with plain TCP,
            # and only after receiving INFO upgrade to TLS if needed
            package require tls
            # I couldn't figure out how to use tls::import with non-blocking sockets
            chan configure $sock -blocking 1
            lassign [$serverPool current_server] host port
            # TODO: move -require 1 to tls_opts to make it optional
            tls::import $sock -require 1 -servername $host {*}$config(tls_opts)
            try {
                tls::handshake $sock
            } on error err {
                my AsyncError ErrTLS "TLS handshake with server $host:$port failed: $err"
                close $sock
                # TODO no point in trying to reconnect to it, so remove it from the pool
                # set serverPool [lreplace serverPool $counters(curServer) $counters(curServer)]
                # nats.py doesn't do it?
                $serverPool current_server_connected false
                my ConnectNextServer ;#TODO replace
                return
            }
            chan configure $sock -blocking 0
        }
        my SendConnect
    }
    
    method MSG {cmd} {
        # the format is <subject> <sid> [reply-to] <#bytes>
        set replyTo ""
        if {[llength $cmd] == 4} {
            lassign $cmd subject subID replyTo expMsgLength
        } else {
            lassign $cmd subject subID expMsgLength
        }
        # turn off crlf translation while we read the message body
        chan configure $sock -translation binary
        # account for these crlf bytes that follow the message
        incr expMsgLength 2
        set remainingBytes $expMsgLength ;# how many bytes left to read until the message is complete
        set messageBody "" 
        while {1} {
            append messageBody [chan read $sock $remainingBytes]
            if {[eof $sock]} {
                # server closed the socket - Tcl will invoke "CoroMain readable" again and close the socket
                # so no need to do anything here
                return
            }
            set actualLength [string length $messageBody]
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
            # remove the trailing crlf; is it efficient on large messages?
            set messageBody [string range $messageBody 0 end-2]
            
            set maxMsgs [dict get $subscriptions($subID) maxMsgs]
            set recMsgs [dict get $subscriptions($subID) recMsgs]
            
            set cmdPrefix [dict get $subscriptions($subID) cmd]
            after 0 [list {*}$cmdPrefix $subject $messageBody $replyTo]
            
            incr recMsgs
            if {$maxMsgs > 0 && $maxMsgs == $recMsgs} {
                unset subscriptions($subID) ;# UNSUB has already been sent, no need to do it here
            } else {
                dict set subscriptions($subID) recMsgs $recMsgs
            }
        } else {
            # if we unsubscribe while there are pending incoming messages, we may get here - nothing to do
            ${logger}::debug "Got [string range $messageBody 0 15] on subID $subID - discarded"
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
            lassign [$serverPool current_server] host port
            ${logger}::info "Connected to the server at $host:$port"
            # exit from vwait in "connect"
            set status $nats::status_connected
            my RestoreSubs
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
        if [string match "permissions violation*" $errMsg] {
            # not fatal for the connection
            my AsyncError ErrPermissions $errMsg
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
        if [string match "invalid *subject*" $errMsg] {
            #only in the pedantic mode; even nats.go doesn't recognise properly this error
            # server will respond "invalid subject" to SUB and "invalid publish subject"
            my AsyncError ErrBadSubject $errMsg
            return
        }
        
        my AsyncError ErrServer $errMsg
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
                lassign [$serverPool current_server] host port
                # the socket either connected or failed to connect
                set errorMsg [chan configure $sock -error]
                if { $errorMsg ne "" } {
                    my AsyncError ErrConnectionRefused "Failed to connect to server $host:$port: $errorMsg"
                    close $sock
                    $serverPool current_server_connected false
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
                lassign [$serverPool current_server] host port
                close $sock
                my AsyncError ErrConnectionTimeout "Connection timeout for $host:$port"
                $serverPool current_server_connected false
                my ConnectNextServer
            }
            readable {
                # confirmed by testing: apparently the Tcl TCP is implemented like:
                # 1. send "readable" event
                # 2. any bytes left in the input buffer? send the event again
                # so, it simplifies my work here - even if I don't read all available bytes with this "chan gets",
                # the coroutine will be invoked again as soon as a complete line is available
                #TODO do i need catch around gets? if remote end aborts network connection
                set readCount [chan gets $sock line]
                # FIXME chan pending should be before chan gets  ?
                if {[chan pending input $sock] > 1024} {
                    # max length of control line in the NATS protocol is 1024 (see MAX_CONTROL_LINE_SIZE in nats.py)
                    # this should not happen unless the NATS server is malfunctioning
                    my AsyncError PROTOCOL_ERR "Maximum control line exceeded"
                    my CloseSocket 1
                    my ConnectNextServer
                    return
                }
                if {$readCount < 0} {
                    if {[eof $sock]} { 
                        # server closed the socket
                        #set err [chan configure $sock -error] - no point in this, $err will be blank
                        lassign [$serverPool current_server] host port
                        my AsyncError ErrBrokenSocket "Failed to read data from $host:$port" 1
                    }
                    # else - we don't have a full line yet - wait for next chan event
                    return
                }
                # extract the first word from the line (INFO, MSG etc)
                # protocol_arg will be empty in case of PING/PONG/OK
                set protocol_arg [lassign $line protocol_op]
                # in case of -ERR or +OK
                set protocol_op [string trimleft $protocol_op -+]
                if {$protocol_op in {MSG INFO ERR OK PING PONG}} {
                    my $protocol_op $protocol_arg
                } else {
                    ${logger}::warn "Invalid protocol $protocol_op"
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
        if {$status == $nats::status_closed} {
            throw {NATS ErrConnectionClosed} "No connection to NATS server"
        }
    }
    
    method CheckTimeout {timeout} {
        if {! ([string is integer -strict $timeout] && $timeout > 0)} {
            throw {NATS ErrBadTimeout} "Invalid timeout $timeout"
        }
    }
    
    method AsyncError {code msg { doReconnect 0 }} {
        ${logger}::error $msg
        set last_error [dict create code "NATS $code" message $msg]
        if {$doReconnect} {
            my CloseSocket 1
            my ConnectNextServer
        }
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

package provide nats 0.9
