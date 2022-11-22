# Copyright (c) 2020-2022 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# References:
# NATS protocol: https://docs.nats.io/reference/reference-protocols/nats-protocol
# Tcllib: https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/toc.md

package require json
package require json::write
package require oo::util
package require coroutine
package require logger
package require textutil::split

namespace eval ::nats {
    # improvised enum
    variable status_closed "closed"
    variable status_connecting "connecting"
    variable status_connected "connected"
    variable status_reconnecting "reconnecting"
    
    # optional packages
    catch {package require tls}
    if {$::tcl_platform(platform) eq "windows"} {
        catch {package require iocp_inet}
    }
}
# all options for "configure"
set ::nats::_option_spec {
    servers valid_str ""
    name valid_str ""
    pedantic bool false
    verbose bool false
    randomize bool true
    connect_timeout timeout 2000
    reconnect_time_wait timeout 2000
    max_reconnect_attempts pos_int 60
    ping_interval timeout 120000
    max_outstanding_pings pos_int 2
    echo bool true
    tls_opts str ""
    user str ""
    password str ""
    token str ""
    secure bool false
    check_subjects bool true
    check_connection bool true
    dictmsg bool false
    utf8_convert bool false
}

oo::class create ::nats::connection {
    # "private" variables
    variable config sock coro timers counters subscriptions requests serverPool \
             subjectRegex outBuffer requestsInboxPrefix jetStream pong logger
    
    # "public" variables, so that users can set up traces if needed
    variable status last_error serverInfo

    constructor { { conn_name "" } } {
        set status $nats::status_closed
        set last_error ""

        # initialise default configuration
        foreach {name type def} $nats::_option_spec {
            set config($name) $def
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
            interp alias {} ::nats::_log_stdout_$lvl {} ::nats::_log_stdout $loggerName $lvl
            ${logger}::logproc $lvl ::nats::_log_stdout_$lvl
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
        set requestsInboxPrefix ""
        set jetStream ""
        set pong 1 ;# sync variable for vwait in "ping". Set to 1 to avoid a check for existing timer in "ping"
    }
    
    destructor {
        my disconnect
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
            return [my cget $args]
        } 
        
        # cmdline::typedGetoptions is garbage
        nats::_parse_args $args $nats::_option_spec 1

        set servers_opt [lsearch -exact $args "-servers"]
        if {$servers_opt == -1} {
            return
        }
        incr servers_opt
        if {$status != $nats::status_closed} {
            # in principle, most other config options can be changed on the fly
            # allowing this to be changed when connected is possible, but a bit tricky
            throw {NATS ErrInvalidArg} "Cannot configure servers when already connected"
        }
        # if any URL is invalid, this function will throw an error - let it propagate
        $serverPool set_servers [lindex $args $servers_opt]
        return
    }

    method reset {args} {
        foreach option $args {
            set opt [string trimleft $option -]
            set pos [lsearch -exact $nats::_option_spec $opt]
            if {$pos != -1} {
                incr pos 2
                set config($opt) [lindex $nats::_option_spec $pos]
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
        return [lrange [$serverPool current_server] 0 1]  ;# drop the last element - schema (nats/tls)
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
        
        set status $nats::status_connecting
        # this coroutine will handle all work to connect and read from the socket
        coroutine coro {*}[mymethod CoroMain]
        
        if {!$async} {
            # $status will become "closed" straightaway
            # in case all calls to [socket] fail immediately and we exhaust the server pool
            # so we shouldn't vwait in this case
            if {$status == $nats::status_connecting} {
                ${logger}::debug "Waiting for connection status"
                my CoroVwait [self object]::status
                ${logger}::debug "Finished waiting for connection status"
            }
            if {$status != $nats::status_connected} {
                # if there's only one server in the pool, it's more user-friendly to report the actual error
                if {[dict exists $last_error code] && [llength [$serverPool all_servers]] == 1} {
                    throw [dict get $last_error code] [dict get $last_error errorMessage]
                }
                throw {NATS ErrNoServers} "No servers available for connection"
            }
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
            after cancel [dict lookup $requests($reqID) timer]
        }
        array unset requests
        set requestsInboxPrefix ""
        my CancelConnectTimer
        #CoroMain will set status to "closed"
        return
    }
    
    method publish_msg {msg} {
        my publish [dict get $msg subject] [dict get $msg data] \
                   -header [dict get $msg header] -reply [dict get $msg reply]
    }
    
    method publish {subject message args} {
        if {[llength $args] == 1} {
            set reply [lindex $args 0]
            set header ""
        } else {
            nats::_parse_args $args {
                header dict ""
                reply str ""
            }
        }

        my CheckConnection
        
        if {$config(utf8_convert)} {
            set message [encoding convertto utf-8 $message]
        }        
        
        set msgLen [string length $message]
        if {[array size serverInfo]} {
            if {$msgLen > $serverInfo(max_payload)} {
                throw {NATS ErrMaxPayload} "Maximum size of NATS message is $serverInfo(max_payload)"
            }
            if {$header ne "" && ![info exists serverInfo(headers)]} {
                throw {NATS ErrHeadersNotSupported} "Headers are not supported by this server"
            }
        }
        
        if {![my CheckSubject $subject]} {
            throw {NATS ErrBadSubject} "Invalid subject $subject"
        }
        if {$reply ne "" && ![my CheckSubject $reply]} {
            throw {NATS ErrBadSubject} "Invalid reply $reply"
        }
        
        if {$header eq ""} {
            set ctrl_line "PUB $subject $reply $msgLen"
            lappend outBuffer $ctrl_line $message
        } else {
            set hdr [nats::_format_header $header]
            set hdr_len [expr {[string length $hdr] + 2}] ;# account for one more crlf that will be added when flushing
            set ctrl_line "HPUB $subject $reply $hdr_len [expr {$msgLen+$hdr_len}]"
            lappend outBuffer $ctrl_line $hdr $message
        }
        
        my ScheduleFlush
        return
    }
    
    method subscribe {subject args} {
        my CheckConnection
        set dictmsg $config(dictmsg)
        
        nats::_parse_args $args {
            queue queue_group ""
            callback valid_str ""
            dictmsg bool null
            max_msgs pos_int 0
        }

        if {![my CheckWildcard $subject]} {
            throw {NATS ErrBadSubject} "Invalid subject $subject"
        }

        set subID [incr counters(subscription)]
        set subscriptions($subID) [dict create subj $subject queue $queue cmd $callback maxMsgs $max_msgs recMsgs 0 dictmsg $dictmsg]
        
        if {$status == $nats::status_connected} {
            # it will be sent anyway when we reconnect
            lappend outBuffer "SUB $subject $queue $subID"
            if {$max_msgs > 0} {
                lappend outBuffer "UNSUB $subID $max_msgs"
            }
            my ScheduleFlush
        }
        return $subID
    }
    
    method unsubscribe {subID args} {
        my CheckConnection
        nats::_parse_args $args {
            queue queue_group ""
            callback valid_str ""
            dictmsg bool null
            max_msgs pos_int 0
        }

        if {![info exists subscriptions($subID)]} {
            throw {NATS ErrBadSubscription} "Invalid subscription ID $subID"
        }
        
        #the format is UNSUB <sid> [max_msgs]
        if {$max_msgs == 0 || [dict get $subscriptions($subID) recMsgs] >= $max_msgs} {
            unset subscriptions($subID)
            set data "UNSUB $subID"
        } else {
            dict set subscriptions($subID) maxMsgs $max_msgs
            set data "UNSUB $subID $max_msgs"
        }
        if {$status == $nats::status_connected} {
            # it will be sent anyway when we reconnect
            lappend outBuffer $data
            my ScheduleFlush
        }
        return
    }
    
    method request_msg {msg args} {
        nats::_parse_args $args {
            timeout timeout 0
            callback str ""
            dictmsg bool true
        }
        set reply [dict get $msg reply]
        if {$reply ne ""} {
            ${logger}::warn "request_msg: the reply $reply will be ignored"
        }
        return [my request [dict get $msg subject] [dict get $msg data] \
                   -header [dict get $msg header] \
                   -timeout $timeout -callback $callback -dictmsg $dictmsg]
    }
    
    method request {subject message args} {
        set dictmsg $config(dictmsg)
        nats::_parse_args $args {
            timeout timeout 0
            callback str ""
            dictmsg bool null
            header dict ""
            max_msgs pos_int 0
            _custom_reqID valid_str ""
        }

        if {$max_msgs > 1 && $callback eq ""} {
            throw {NATS ErrInvalidArg} "-max_msgs>1 can be used only in async request"
        }
        
        if {$_custom_reqID ne ""} {
            set reqID $custom_reqID
        } else {
            set reqID [incr counters(request)]
        }
        set subID ""
        if {$requestsInboxPrefix eq ""} {
            set requestsInboxPrefix [my inbox]
            my subscribe "$requestsInboxPrefix.*" -dictmsg 1 -callback [mymethod RequestCallback -1]
        }
        if {$max_msgs == 0} {
            # "new-style" request with one wildcard subscription
            # only the first response is delivered
            # will perform more argument checking, so it may raise an error
            my publish $subject $message -reply "$requestsInboxPrefix.$reqID" -header $header
        } else {
            # "old-style" request with a SUB per each request is needed for JetStream,
            # because messages received from a stream have a subject that differs from our reply-to
            # $max_msgs is always 1 for sync requests
            set subID [my subscribe "$requestsInboxPrefix.JS.$reqID" -dictmsg 1 -callback [mymethod RequestCallback $reqID] -max_msgs $max_msgs]
            my publish $subject $message -reply "$requestsInboxPrefix.JS.$reqID" -header $header
        }
        
        set timerID ""
        if {$timeout != 0} {
            # RequestCallback is called in all cases: timeout/no timeout, sync/async request
            set timerID [after $timeout [mymethod RequestCallback $reqID]]
        }
        if {$callback ne ""} {
            # async request
            set requests($reqID) [dict create timer $timerID callback $callback isDictMsg $dictmsg subID $subID maxMsgs $max_msgs recMsgs 0]
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
                unset -nocomplain subscriptions($subID)
            }
            throw {NATS ErrTimeout} "Request to $subject timed out"
        }
        after cancel $timerID
        set response [dict get $sync_req response]
        set in_hdr [dict get $response header]
        if {[dict lookup $in_hdr Status 0] == 503} {
            # TODO throw ErrJetStreamNotEnabled if subject starts with $JS.API
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
        nats::_parse_args $args {
            timeout timeout 10000
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

    method jet_stream {args} {
        nats::_parse_args $args {
            timeout timeout 5000
        }
        return [nats::jet_stream new [self] $timeout]
    }
    
    method inbox {} {
        # resulting inboxes look the same as in official NATS clients, but use a much simpler RNG
        return "_INBOX.[nats::_random_string]"
    }
    
    method RequestCallback { reqID {subj ""} {msg ""} {reply ""} } {
        if {$subj eq "" && $reqID != -1} {
            # request timed out
            set callback [dict lookup $requests($reqID) callback]
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
        set callback [dict lookup $requests($reqID) callback]
        if {$callback eq ""} {
            # resume from vwait in "method request"; "requests" array will be cleaned up there
            set requests($reqID) [dict create timedOut 0 response $msg]
            return
        }
        # handle the async request
        set timedOut 0
        set in_hdr [dict get $msg header]
        if {[dict lookup $in_hdr Status 0] == 503} {
            # no-responders is equivalent to timedOut=1
            set timedOut 1
        }

        # handle the nats timeout e.q. for pull consumers
        if {[dict lookup $in_hdr Status 0] == 408} {
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
        
        if {[info coroutine] ne $coro} {
            if {!$broken} {
                $coro stop
            }
        }
    }
    
    method Pinger {} {
        set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
        
        if {$counters(pendingPings) >= $config(max_outstanding_pings)} {
            my AsyncError ErrStaleConnection "The server did not respond to $counters(pendingPings) PINGs" 1
            set counters(pendingPings) 0
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
            set outBuffer [list] ;# do NOT clear the buffer unless we had a successful flush!
        } on error err {
            lassign [my current_server] host port
            my AsyncError ErrBrokenSocket "Failed to send data to $host:$port: $err" 1
        }
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
        while {1} {
            # if it throws ErrNoServers, we have exhausted all servers in the pool
            # we must stop the coroutine, so let the error propagate
            lassign [$serverPool next_server] host port ;# it may wait for reconnect_time_wait ms!
            ${logger}::info "Connecting to the server at $host:$port"
            try {
                # socket -async can throw e.g. in case of a DNS resolution failure
                if {![catch {package present iocp_inet}]} {
                    set sock [iocp::inet::socket -async $host $port]
                    ${logger}::debug "Created IOCP socket"
                } else {
                    set sock [socket -async $host $port]
                }
                chan event $sock writable [list $coro connected]
                return
            } on error {msg opt} {
                $serverPool current_server_connected false
                my AsyncError ErrConnectionRefused "Failed to connect to $host:$port: $msg"
            }
        }
    }
    
    method SendConnect {tls_done} {
        try {
            # tls_required=true in CONNECT seems unnecessary to me, because TLS handshake has already happened
            # but nats.go does this
            set connectParams [list verbose $config(verbose) \
                                    pedantic $config(pedantic) \
                                    tls_required $tls_done \
                                    name [json::write::string $config(name)] \
                                    lang [json::write::string Tcl] \
                                    version [json::write::string 1.0] \
                                    protocol 1 \
                                    echo $config(echo)]
            
            if {[info exists serverInfo(headers)] && $serverInfo(headers)} {
                lappend connectParams headers true no_responders true
            }
            if {[info exists serverInfo(auth_required)] && $serverInfo(auth_required)} {
                lappend connectParams {*}[$serverPool format_credentials]
            } 
            set jsonMsg [::nats::_json_write_object {*}$connectParams]
        } trap {NATS ErrAuthorization} err {
            # no credentials could be found for this server, try next one
            my AsyncError ErrAuthorization $err 1
            return
        }
        
        # do NOT use outBuffer here! it may have pending messages from a previous connection
        # we can flush them only after authentication is confirmed
        puts -nonewline $sock "CONNECT $jsonMsg\r\n"
        puts -nonewline $sock "PING\r\n"
        flush $sock
        # rest of the handshake is done in method PONG 
    }
    
    method RestoreSubs {} {
        set subsBuffer [list]
        foreach subID [array names subscriptions] {
            set subject [dict get $subscriptions($subID) subj]
            set queue [dict get $subscriptions($subID) queue]
            set maxMsgs [dict get $subscriptions($subID) maxMsgs]
            set recMsgs [dict get $subscriptions($subID) recMsgs]
            lappend subsBuffer "SUB $subject $queue $subID"
            if {$maxMsgs > 0} {
                set remainingMsgs [expr {$maxMsgs - $recMsgs}]
                lappend subsBuffer "UNSUB $subID $remainingMsgs"
            }
        }
        # ensure SUBs are sent before any pending PUBs
        set outBuffer [linsert $outBuffer 0 {*}$subsBuffer]
    }
    
    method INFO {cmd} {
        if {$status == $nats::status_connected} {
            # when we say "proto":1 in CONNECT, we may receive information about other servers in the cluster - add them to serverPool
            # and mark as discovered=true
            # example connect_urls : ["192.168.2.5:4222", "192.168.91.1:4222", "192.168.157.1:4223", "192.168.2.5:4223"]
            # by default each server will advertise IPs of all network interfaces, so the server pool may seem bigger than it really is
            # --client_advertise NATS option can be used to make it clearer
            #TODO invoke callback - discovered servers/LDM
            array set serverInfo [json::json2dict $cmd]
            if {[info exists serverInfo(connect_urls)]} {
                set urls $serverInfo(connect_urls)
                ${logger}::debug "Got connect_urls: $urls"
                foreach url $urls {
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
        set tls_done false
        lassign [$serverPool current_server] host port scheme
        if {[info exists serverInfo(tls_required)] && $serverInfo(tls_required)} {
            #NB! NATS server will never accept a TLS connection. Always start connecting with plain TCP,
            # and only after receiving INFO, we can upgrade to TLS if needed
            if {[catch {package present tls}]} {
                my AsyncError ErrTLS "TLS package is not available" 1
                return
            }
            # there's no need to check for tls_verify in INFO
            # a user needs to provide -certfile and -keyfile options to tls::import anyway
            # and if they are not needed, NATS server will ignore them
            
            # for simplicity, let's switch to the blocking mode just for the handshake
            chan configure $sock -blocking 1
            try {
                tls::import $sock -require 1 -command ::nats::tls_callback {*}$config(tls_opts)
                tls::handshake $sock
                set tls_done true
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
                    set header [nats::_parse_header [string range $payload 0 $expHdrLength-1]]
                } trap {NATS ErrBadHeaderMsg} err {
                    # invalid header causes an async error, nevertheless the message is delivered, see nats.go, func processMsg
                    my AsyncError ErrBadHeaderMsg $err
                }
            }
            set body [string range $payload $expHdrLength end-2] ;# discard \r\n at the end

            #convert from utf-8
            if {$config(utf8_convert)} {
                set body [encoding convertfrom utf-8 $body]
            }

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
    
    method +OK {cmd} {
        # nothing to do
    }
    
    method -ERR {cmd} {
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
            my ConnectNextServer
            while {1} {
                set reason [yield]
                if {$reason eq "stop"} {
                    break
                }
                my ProcessEvent $reason
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
                # even though [socket] already had -async, I have to repeat -blocking 0 anyway =\
                # NATS protocol uses crlf as a delimiter
                # when reading from the socket, it's easier to let Tcl do EOL translation, unless we are in method MSG
                # when writing to the socket, we need to turn off the translation when sending a message payload
                # but outBuffer doesn't know which element is a message, so it's easier to write CR+LF ourselves
                # TODO: configure -buffersize?
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
                if {$protocol_op eq "HMSG"} {
                    my MSG $protocol_arg 1
                    return
                }
                if {$protocol_op in {MSG INFO -ERR +OK PING PONG}} {
                    my $protocol_op $protocol_arg
                } else {
                    ${logger}::warn "Invalid protocol $protocol_op $protocol_arg"
                }
            }
            default {
                ${logger}::error "CoroMain: unknown reason $reason"
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
        if {!$config(check_connection)} {
            return  ;# allow to buffer PUB/SUB/UNSUB even before the first connection to NATS
        }
        # allow PUB/SUB/UNSUB when connected or reconnecting, throw an error otherwise
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
    
    method StartConnectTimer {} {
        set timers(connect) [after $config(connect_timeout) [list [info coroutine] connect_timeout]]
        ${logger}::debug "Started connection timer $timers(connect)"
    }
    
    method CancelConnectTimer {} {
        if {$timers(connect) eq ""} {
            return
        }
        after cancel $timers(connect)
        ${logger}::debug "Cancelled connection timer $timers(connect)"
        set timers(connect) ""
    }
}

# by default, when a handshake fails, the TLS library reports it to stderr AND raises an error - see tls.c, function Tls_Error
# so I end up with the same message logged twice. Let's suppress stderr altogether
# keep this proc "public" in case a user needs to override it
proc ::nats::tls_callback {args} { }

namespace eval ::nats::msg {
    proc create {args} {
        nats::_parse_args $args {
            subject valid_str null
            data str ""
            reply str ""
        }
        return [dict create header "" data $data subject $subject reply $reply sub_id ""]
    }
    proc set {msgVar field value} {
        switch -- $field {
            -data - -subject - -reply {
                upvar 1 $msgVar msg
                dict set msg [string trimleft $field -] $value
                return
            }
            default {
                # do not allow changing the header or sub_id
                throw {NATS ErrInvalidArg} "Invalid field $field"
            }
        }
    }
    proc subject {msg} {
        return [dict get $msg subject]
    }
    proc data {msg} {
        return [dict get $msg data]
    }
    proc reply {msg} {
        return [dict get $msg reply]
    }
    proc no_responders {msg} {
        return [expr {[dict lookup [dict get $msg header] Status 0] == 503}]
    }
    # only messages fetched using STREAM.MSG.GET will have it
    proc seq {msg} {
        if {[dict exists $msg seq]} {
            return [dict get $msg seq]
        } else {
            throw {NATS ErrInvalidArg} "Invalid field 'seq'"
        }
    }
    proc timestamp {msg} {
        if {[dict exists $msg time]} {
            return [dict get $msg time] ;# ISO timestamp like 2022-11-22T13:31:35.4514983Z ; [clock scan] doesn't understand it
        } else {
            throw {NATS ErrInvalidArg} "Invalid field 'timestamp'"
        }
    }
    
    namespace export *
    namespace ensemble create
}
namespace eval ::nats::header {
    proc add {msgVar key value} {
        upvar $msgVar msg
        if {[dict exists $msg header $key]} {
            dict with msg header {
                lappend $key $value
            }
        } else {
            dict set msg header $key [list $value]
        }
        return
    }
    # args may give more key-value pairs
    proc set {msgVar key value args} {
        upvar $msgVar msg
        dict set msg header $key [list $value]
        if {[llength $args]} {
            if {[llength $args] % 2} {
                throw {NATS ErrInvalidArg} "Missing a value for a key"
            }
            foreach {k v} $args {
                dict set msg header $k [list $v]
            }
        }
        return
    }
    proc delete {msgVar key} {
        upvar $msgVar msg
        dict unset msg header $key
        return
    }
    # get only the first value
    proc get {msg key} {
        ::set all_values [dict get [dict get $msg header] $key]
        return [lindex $all_values 0]
    }
    # get all values for a key
    proc values {msg key} {
        return [dict get [dict get $msg header] $key]
    }
    # get all keys
    proc keys {msg {pattern ""} } {
        if {$pattern eq ""} {
            return [dict keys [dict get $msg header]]
        } else {
            return [dict keys [dict get $msg header] $pattern]
        }
    }
    namespace export *
    namespace ensemble create
}

# ------------------------ all following procs are private! --------------------------------------
proc ::nats::_timestamp {} {
    # workaround for not being able to format current time with millisecond precision
    # should not be needed in Tcl 8.7, see https://core.tcl-lang.org/tips/doc/trunk/tip/423.md
    set t [clock milliseconds]
    set timeStamp [format "%s.%03d" \
                      [clock format [expr {$t / 1000}] -format %T] \
                      [expr {$t % 1000}] ]
    return $timeStamp
}

proc ::nats::_log_stdout {service level text} {
    puts "\[[nats::_timestamp] $service $level\] $text"
}
# returns a dict, where each key points to a list of values
# NB! unlike HTTP headers, in NATS headers keys are case-sensitive
proc ::nats::_parse_header {header} {
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
proc ::nats::_format_header { header } {
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

# preserve json::write variables
proc ::nats::_json_write_object {args} {
    if {[llength $args] %2 == 1} {
	    return -code error {wrong # args, expected an even number of arguments}
    }
    
    set ind [json::write::indented]
    set ali [json::write::aligned]

    json::write::indented false
    json::write::aligned false
    set result [json::write::object {*}$args]

    json::write::indented $ind
    json::write::aligned $ali

    return $result
}

# pending TIP 342 in Tcl 8.7
proc ::nats::_dict_get_default {dict_val key {def ""}} {
    if {[dict exists $dict_val $key]} {
        return [dict get $dict_val $key]
    } else {
        return $def
    }
}

namespace eval ::nats {
    # now add it to the standard "dict" ensemble under the name "lookup"; no support needed for nested dicts
    variable map [namespace ensemble configure ::dict -map]
    dict set map lookup ::nats::_dict_get_default
    namespace ensemble configure ::dict -map $map
    unset map
}

# official NATS clients use the sophisticated NUID algorithm, but this should be enough for the Tcl client
# characters allowed in a NATS subject:
# Naming Rules https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md
proc ::nats::_random_string {} {
    set allowed_chars "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    set range [string length $allowed_chars]
    set result ""
    for {set i 0} {$i < 22} {incr i} {
        set pos [expr {int(rand() * $range)}]
        append result [string index $allowed_chars $pos]
    }
    return $result
}

proc ::nats::_validate {name val type} {
    if {[lindex $type 0] eq "enum"} {
        return true
    }
    switch -- $type {
        str - ns - int {
            # some types used only in JetStream JSON generation don't need to be validated here
        }
        valid_str {
            if {[string length $val] == 0} {
                return false
            }
        }
        pos_int - timeout {
            if {![string is entier -strict $val]} {
                return false
            }
            # 0 is reserved for "N/A" or "unlimited"
            if { $val < 0 } {
                return false
            }
        }
        bool {
            if {![string is boolean -strict $val]} {
                return false
            }
        }
        dict {
            if {[catch {dict size $val}]} {
                return false
            }
        }
        queue_group {
            #rules for queue names are more relaxed than for subjects
            # badQueue in nats.go checks for whitespace
            if {![string is graph $val]} {
                return false
            }
        }
        default {
            throw {NATS ErrInvalidArg} "Wrong type $type"  ;# should not happen
        }
    }
    return true
}

# args_list is always a list of option-value pairs; there are no "flag" options
# $spec contains rows of: option-name option-type default-value
# this proc initializes local vars in the upper stack (unless its default value is "null" in the spec)
# or elements in the configure array
proc ::nats::_parse_args {args_list spec {doConfig 0}} {
    if {[llength $args_list] % 2} {
        throw {NATS ErrInvalidArg} "Missing value for option [lindex $args_list end]"
    }
    foreach {k v} $args_list {
        set args_arr([string trimleft $k -]) $v
    }
    if {$doConfig} {
        upvar config config
    }
    # validate only those arguments that were received from the user
    foreach {name type def} $spec {
        if {[info exists args_arr($name)]} {
            set val $args_arr($name)
            if {![_validate $name $val $type]} {
                set errCode [expr {$type eq "timeout" ? "ErrBadTimeout" : "ErrInvalidArg"}]
                throw "NATS $errCode" "Invalid value for the $type option $name : $val"
            }
            if {$type eq "bool"} {
                # normalized bools can be written directly to JSON
                set val [expr $val? "true" : "false"]
            }
            # use explicit ::set to avoid clashing with [nats::msg set]
            if {$doConfig} {
                uplevel 1 [list ::set config($name) $val]
            } else {
                uplevel 1 [list ::set $name $val]
            }
            unset args_arr($name)
        } else {
            if {$doConfig} {
                # do NOT initialise defaults when in "configure"
                continue
            }
            if {$def ne "null"} {
                uplevel 1 [list ::set $name $def]
            }
        }
    }
    if {[array size args_arr]} {
        throw {NATS ErrInvalidArg} "Unknown option [lindex [array names args_arr] 0]"
    }
}

package provide nats 1.0

# Let me respectfully remind you:
# Birth and death are of supreme importance.
# Time swiftly passes and opportunity is lost.
# Do not squander your life!
