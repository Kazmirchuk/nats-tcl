# Copyright (c) 2020-2023 Petro Kazmirchuk https://github.com/Kazmirchuk
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
    max_reconnect_attempts int 60
    ping_interval timeout 120000
    max_outstanding_pings pos_int 2
    echo bool true
    tls_opts str ""
    user str ""
    password str ""
    token str ""
    secure bool false
    check_subjects bool true
    dictmsg bool false
    utf8_convert bool false
}

oo::class create ::nats::connection {
    # "private" variables
    variable config sock coro timers counters subscriptions requests serverPool \
             outBuffer requestsInboxPrefix pong
    
    # "public" variables, so that users can set up traces if needed
    variable status last_error serverInfo

    constructor { { conn_name "" } args } {
        nats::_parse_args $args {
            logger valid_str ""
            log_chan valid_str stdout
            log_level valid_str warn
        }
        
        set status $nats::status_closed
        set last_error ""

        # initialise default configuration
        foreach {name type def} $nats::_option_spec {
            set config($name) $def
        }
        set config(name) $conn_name
        set sock "" ;# the TCP socket
        set coro "" ;# the coroutine handling readable and writeable events on the socket
        array set timers {ping {} flush {} connect {} }
        array set counters {subscription 0 request 0 pendingPings 0}
        array set subscriptions {} ;# subID -> dict (subj, queue, callback, maxMsgs: int, recMsgs: int, isDictMsg: bool, post: bool)
        array set requests {} ;# reqID -> dict; keys in the dict depend:
        # new-style sync requests: timer, timedOut: bool, response: dictMsg
        # new-style async requests: timer, callback, isDictMsg: bool
        # old-style sync requests: timer, timedOut: bool, inMsgs: list
        # old-style async requests: timer, callback, subID
        array set serverInfo {} ;# INFO from a current NATS server
        # all outgoing messages are put in this list before being flushed to the socket,
        # so that even when we are reconnecting, messages can still be sent
        set outBuffer [list]
        set requestsInboxPrefix ""
        set pong 0
        my InitLogger $logger $log_chan $log_level
        set serverPool [nats::server_pool new [self object]] 
    }
    
    destructor {
        my disconnect
        $serverPool destroy
    }
    
    method InitLogger {logger log_chan log_level} {
        if {$logger ne ""} {
            # user has provided a pre-configured logger object
            logger::import -namespace log [${logger}::servicename]
            # log_chan and log_level have no effect in this case
            return
        }
        if {$log_level ni {error warn info debug}} {
            throw {NATS ErrInvalidArg} "Invalid -log_level $log_level"
        }
        
        # the logger package in Tcllib is crap, so make my own by default
        # default output is stdout; default level is warn
        set loggerName $config(name)
        if {$loggerName eq ""} {
            set loggerName [namespace tail [self object]]
        }
        
        namespace eval log "variable logChannel $log_chan; \
                            variable loggerName $loggerName;"
        
        proc log::log {level msg} {
            variable logChannel
            variable loggerName
            puts $logChannel "\[[nats::timestamp] $loggerName $level\] $msg"
        }
        
        proc log::suppressed {level msg} {}
        
        set belowLogLevel 0
        # provide the same interface as Tcllib's logger; we use only these 4 logging levels
        foreach level {error warn info debug} {
            if {$belowLogLevel} {
                interp alias {} [self object]::log::${level} {} [self object]::log::suppressed $level
            } else {
                interp alias {} [self object]::log::${level} {} [self object]::log::log $level
            }
            if {$log_level eq $level} {
                set belowLogLevel 1
            }
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
        if {$status != $nats::status_closed} {
            # in principle, most other config options can be changed on the fly
            # allowing -servers to be changed when connected is possible, but a bit tricky
            throw {NATS ErrInvalidArg} "Cannot configure servers when already connected"
        }
        # if any URL is invalid, this function will throw an error - let it propagate
        $serverPool set_servers [lindex $args $servers_opt+1]
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
    
    method current_server {} {
        my CheckConnection
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
        $serverPool reset_counters
        
        set status $nats::status_connecting
        # this coroutine will handle all work to connect and read from the socket
        # current namespace is prepended to the coroutine name, so it's unique
        coroutine coro {*}[mymethod CoroMain]
        
        if {!$async} {
            # $status will become "closed" straightaway
            # in case all calls to [socket] fail immediately and we exhaust the server pool
            # so we shouldn't vwait in this case
            if {$status == $nats::status_connecting} {
                log::debug "Waiting for connection status"
                nats::_coroVwait [self object]::status
                log::debug "Finished waiting for connection status"
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
        foreach reqID [array names requests] {
            after cancel [dict lookup $requests($reqID) timer]
        }
        if {$sock eq ""} {
            # if a user calls disconnect while we are waiting for reconnect_time_wait, we only need to stop the coroutine
            $coro stop
        } else {
            my CloseSocket
        }
        # rest of cleanup is done in CoroMain
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
            set check_subj true
        } else {
            nats::_parse_args $args {
                header dict ""
                reply str ""
                check_subj bool true
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
        
        if {$check_subj} {
            # workaround for one specific case in JS mgmt when this check must be disabled
            if {![my CheckSubject $subject]} {
                throw {NATS ErrBadSubject} "Invalid subject $subject"
            }
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
            queue valid_str ""
            callback valid_str ""
            dictmsg bool null
            max_msgs pos_int 0
            post bool true
        }

        if {![my CheckSubject $subject -wildcard]} {
            throw {NATS ErrBadSubject} "Invalid subject $subject"
        }

        if {$queue ne "" && ![my CheckSubject $queue -queue]} {
            throw {NATS ErrBadQueueName} "Invalid queue $queue"
        }
        
        set subID [incr counters(subscription)]
        set subscriptions($subID) [dict create subj $subject queue $queue callback $callback maxMsgs $max_msgs recMsgs 0 isDictMsg $dictmsg post $post]
        
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
            max_msgs pos_int 0
        }

        if {![info exists subscriptions($subID)]} {
            throw {NATS ErrBadSubscription} "Invalid subscription ID $subID"
        }
        
        #the format is UNSUB <sid> [max_msgs]
        if {$max_msgs == 0 || [dict get $subscriptions($subID) recMsgs] >= $max_msgs} {
            unset -nocomplain subscriptions($subID)  ;# not sure if -nocomplain is really needed, but it was contributed by ANT
            set data "UNSUB $subID"
        } else {
            dict set subscriptions($subID) maxMsgs $max_msgs
            set data "UNSUB $subID $max_msgs"
        }
        if {$status == $nats::status_connected} {
            lappend outBuffer $data
            my ScheduleFlush
        }
        return
    }
    
    method request_msg {msg args} {
        set dictmsg $config(dictmsg)
        nats::_parse_args $args {
            timeout timeout 0
            callback str ""
            dictmsg bool null
        }
        set reply [dict get $msg reply]
        if {$reply ne ""} {
            log::warn "request_msg: the reply $reply will be ignored"
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
            max_msgs pos_int null
            check_subj bool true
        }

        if {[info exists max_msgs]} {
            return [my OldStyleRequest $subject $message $header $timeout $callback $max_msgs] ;# isDictMsg always true
        } else {
            return [my NewStyleRequest $subject $message $header $timeout $callback $dictmsg $check_subj]
        }
    }
    
    method NewStyleRequest {subject message header timeout callback dictmsg check_subj} {
        # "new-style" request with one wildcard subscription
        # only the first response is delivered
        if {$requestsInboxPrefix eq ""} {
            set requestsInboxPrefix [my inbox]
            my subscribe "$requestsInboxPrefix.*" -dictmsg 1 -callback [mymethod NewStyleRequestCb -1] -post false
        }
        set reqID [incr counters(request)]
        # will perform more argument checking, so it may raise an error
        my publish $subject $message -reply "$requestsInboxPrefix.$reqID" -header $header -check_subj $check_subj
        
        set timerID ""
        if {$callback ne ""} {
            if {$timeout != 0} {
                set timerID [after $timeout [mymethod NewStyleRequestCb $reqID "" "" ""]]
            }
            set requests($reqID) [dict create timer $timerID callback $callback isDictMsg $dictmsg]
            return $reqID
        }
        # sync request
        # remember that we can get a reply after timeout, so vwait must wait on a specific reqID
        if {$timeout != 0} {
            set timerID [after $timeout [list dict set [self object]::requests($reqID) timedOut 1]]
        }
        # if connection is lost, we need to cancel this timer, see also CoroMain
        set requests($reqID) [dict create timer $timerID]
        nats::_coroVwait [self object]::requests($reqID)
        if {![info exists requests($reqID)]} {
            throw {NATS ErrTimeout} "Connection lost"
        }
        set sync_req $requests($reqID)
        unset requests($reqID)
        if {[dict lookup $sync_req timedOut 0]} {
            throw {NATS ErrTimeout} "Request to $subject timed out"
        }
        after cancel $timerID
        set response [dict get $sync_req response]
        if {[nats::msg no_responders $response]} {
            throw {NATS ErrNoResponders} "No responders available for request"
        }
        if {$dictmsg} {
            return $response
        } else {
            return [nats::msg data $response]
        }
    }
    
    method OldStyleRequest {subject message header timeout callback max_msgs} {
        # "old-style" request with a SUB per each request is needed for JetStream,
        # because messages received from a stream have a subject that differs from our reply-to
        # we still use the same requests array to vwait on
        set reply [my inbox]
        set reqID [incr counters(request)]
        set subID [my subscribe $reply -dictmsg 1 -callback [mymethod OldStyleRequestCb $reqID] -max_msgs $max_msgs -post false]
        my publish $subject $message -reply $reply -header $header
        set timerID ""
        if {$callback ne ""} {
            if {$timeout != 0} {
                set timerID [after $timeout [mymethod OldStyleRequestCb $reqID "" "" ""]]
            }
            set requests($reqID) [dict create timer $timerID callback $callback subID $subID]
            return $reqID
        }
        #sync request
        if {$timeout != 0} {
            set timerID [after $timeout [list dict set [self object]::requests($reqID) timedOut 1]]
        }
        set requests($reqID) [dict create timer $timerID]
        while {1} {
            nats::_coroVwait [self object]::requests($reqID)
            if {![info exists requests($reqID)]} {
                throw {NATS ErrTimeout} "Connection lost"
            }
            set sync_req $requests($reqID)
            if {[dict lookup $sync_req timedOut 0]} {
                break
            }
            if {[llength [dict lookup $sync_req inMsgs]] == $max_msgs} {
                break
            }
        }
        unset requests($reqID)
        set inMsgs [dict lookup $sync_req inMsgs]
        if {[dict lookup $sync_req timedOut 0]} {
            my unsubscribe $subID
            if {[llength $inMsgs] == 0} {
                throw {NATS ErrTimeout} "Request to $subject timed out"
            }
        } else {
            after cancel $timerID
        }
        set firstMsg [lindex $inMsgs 0]
        if {[nats::msg no_responders $firstMsg]} {
            throw {NATS ErrNoResponders} "No responders available for request to $subject"
        }
        return $inMsgs ;# this could be fewer than $max_msgs in case the timeout fired
    }
    
    method cancel_request {reqID} {
        if {![info exists requests($reqID)]} {
            throw {NATS ErrInvalidArg} "Invalid request ID $reqID"
        }
        after cancel [dict get $requests($reqID) timer]
        set subID [dict lookup $requests($reqID) subID]
        if {$subID ne ""} {
            my unsubscribe $subID
        }
        unset requests($reqID)
        log::debug "Cancelled request $reqID"
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
        log::debug "sending PING"
        my ScheduleFlush
        nats::_coroVwait [self object]::pong
        after cancel $timerID
        if {$pong} {
            return true
        }
        throw {NATS ErrTimeout} "PING timeout"
    }

    method jet_stream {args} {
        nats::_parse_args $args {
            timeout timeout 5000
            domain valid_str ""
        }
        return [nats::jet_stream new [self] $timeout $domain]
    }
    
    method inbox {} {
        # resulting inboxes look the same as in official NATS clients, but use a much simpler RNG
        return "_INBOX.[nats::_random_string]"
    }
    
    # we received a message for a sync or async request
    # or we got a timeout for async request
    method NewStyleRequestCb {reqID subj msg reply} {
        if {$subj eq ""} {
            set callback [dict get $requests($reqID) callback]
            after 0 [list {*}$callback 1 ""]
            unset requests($reqID)
            return
        }
        # we've got a message
        # $msg is always a dict in this method, and it already contains (optional) $reply in it, so we just pass it over to users
        set reqID [lindex [split $subj .] 2]
        
        if {![info exists requests($reqID)]} {
            # ignore all further responses, if >1 arrives; or it could be an overdue message
            #log::debug "NewStyleRequestCb got [string range $msg 0 15] on reqID $reqID - discarded"
            return
        }
        set callback [dict lookup $requests($reqID) callback]
        if {$callback eq ""} {
            # resume from vwait in NewStyleRequest; the "requests" array will be cleaned up there
            dict set requests($reqID) response $msg
            return
        }
        # invoke callback for an async request
        # in case of sync request, checking for no-responders and isDictMsg is done in NewStyleRequest
        set timedOut [nats::msg no_responders $msg]
        if {![dict get $requests($reqID) isDictMsg]} {
            set msg [nats::msg data $msg]
        }
        after 0 [list {*}$callback $timedOut $msg]
        after cancel [dict get $requests($reqID) timer]
        unset requests($reqID)
    }
    
    # we received a message for a sync or async request
    # or we got a timeout for async request
    method OldStyleRequestCb {reqID subj msg reply} {
        if {![info exists requests($reqID)]} {
            return
        }
        if {$subj eq ""} {
            set subID [dict get $requests($reqID) subID]
            set callback [dict get $requests($reqID) callback]
            unset requests($reqID)
            my unsubscribe $subID
            # invoke the callback even if it received some messages before
            after 0 [list {*}$callback 1 ""]
            return
        }
        # we've got a message
        set callback [dict lookup $requests($reqID) callback]
        if {$callback eq ""} {
            # resume from vwait in OldStyleRequest
            dict lappend requests($reqID) inMsgs $msg
            return
        }
        set timedOut [nats::msg no_responders $msg]
        
        after 0 [list {*}$callback $timedOut $msg]

        set subID [dict get $requests($reqID) subID]
        # if we don't expect any more messages, the subscriptions array has been already cleaned up
        if {![info exists subscriptions($subID)]} {
            after cancel [dict get $requests($reqID) timer]
            unset requests($reqID) ;# we've received all expected messages
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
            log::info "Closing connection to $host:$port" ;# in case of broken socket, the error will be logged in AsyncError
            # make sure we wait until successful flush, if connection was not broken
            chan configure $sock -blocking 1
            foreach msg $outBuffer {
                append msg "\r\n"
                puts -nonewline $sock $msg
            }
            set outBuffer [list]
        }
        try {
            close $sock ;# all buffered input is discarded, all buffered output is flushed
        } on error err {
            log::error "Failed to close the socket: $err"
        }
        set sock ""
        after cancel $timers(ping)
        after cancel $timers(flush)
        set timers(ping) ""
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
        log::debug "Sending PING"
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
            my AsyncError ErrBrokenSocket "Failed to send data to $host:$port: $err" 1
        }
        # in any case the buffer must be cleared to guarantee at-most-once delivery
        set outBuffer [list]
    }
    
    # --------- these procs execute in the coroutine ---------------
    # connect to Nth server in the pool
    method ConnectNextServer {} {
        while {1} {
            # if it throws ErrNoServers, we have exhausted all servers in the pool
            # we must stop the coroutine, so let the error propagate
            lassign [$serverPool next_server] host port ;# it may wait for reconnect_time_wait ms!
            log::info "Connecting to the server at $host:$port"
            try {
                # socket -async can throw e.g. in case of a DNS resolution failure
                if {![catch {package present iocp_inet}]} {
                    set sock [iocp::inet::socket -async $host $port]
                    log::debug "Created IOCP socket"
                } else {
                    set sock [socket -async $host $port]
                }
                chan event $sock writable [list $coro connected]
                return
            } on error err {
                $serverPool current_server_connected false
                my AsyncError ErrConnectionRefused "Failed to connect to $host:$port: $err"
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
                                    version [json::write::string 2.0.1] \
                                    protocol 1 \
                                    echo $config(echo)]
            
            if {[info exists serverInfo(headers)] && $serverInfo(headers)} {
                lappend connectParams headers true no_responders true
            }
            if {[info exists serverInfo(auth_required)] && $serverInfo(auth_required)} {
                lappend connectParams {*}[$serverPool format_credentials]
            }
            json::write::indented false
            json::write::aligned false
            set jsonMsg [json::write::object {*}$connectParams]
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
        if {[llength $subsBuffer] > 0} {
            # ensure SUBs are sent before any pending PUBs
            set outBuffer [linsert $outBuffer 0 {*}$subsBuffer]
            my ScheduleFlush
        }
    }
    
    method INFO {cmd} {
        if {$status == $nats::status_connected} {
            # when we say "proto":1 in CONNECT, we may receive information about other servers in the cluster - add them to serverPool
            # and mark as discovered=true
            # example connect_urls : ["192.168.2.5:4222", "192.168.91.1:4222", "192.168.157.1:4223", "192.168.2.5:4223"]
            # by default each server will advertise IPs of all network interfaces, so the server pool may seem bigger than it really is
            # --client_advertise NATS option can be used to make it clearer
            array set serverInfo [json::json2dict $cmd]
            if {[info exists serverInfo(connect_urls)]} {
                set urls $serverInfo(connect_urls)
                log::debug "Got connect_urls: $urls"
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
                log::debug "Performing TLS handshake..."
                tls::import $sock {*}[dict merge {-require 1 -command ::nats::tls_callback} $config(tls_opts)]
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
    method HMSG {cmd} {
        my MSG $cmd 1
    }
    method MSG {cmd {with_headers 0}} {
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
                    log::error "MSG: unknown reason $reason"
                }
            }
        }
        # revert to our default translation
        chan configure $sock -translation {crlf binary}
        
        if {![info exists subscriptions($subID)]} {
            # if we unsubscribe while there are pending incoming messages, we may get here - nothing to do
            #log::debug "Got [string range $payload 0 15] on subID $subID - discarded"
            return
        }
        set maxMsgs [dict get $subscriptions($subID) maxMsgs]
        set recMsgs [dict get $subscriptions($subID) recMsgs]
        set callback [dict get $subscriptions($subID) callback]
        set postEvent [dict get $subscriptions($subID) post]
        if {$expHdrLength > 0} {
            try {
                # the header ends with \r\n\r\n that we can drop before parsing
                set header [nats::_parse_header [string range $payload 0 $expHdrLength-5]]
            } trap {NATS ErrBadHeaderMsg} err {
                # invalid header causes an async error, nevertheless the message is delivered, see nats.go, func processMsg
                my AsyncError ErrBadHeaderMsg $err
            }
        }
        set body [string range $payload $expHdrLength end-2] ;# discard \r\n at the end

        if {$config(utf8_convert)} {
            set body [encoding convertfrom utf-8 $body]
        }

        if {[dict get $subscriptions($subID) isDictMsg]} {
            set msg [nats::msg create $subject -data $body -reply $replyTo]
            dict set msg sub_id $subID
            if {[info exists header]} {
                dict set msg header $header
            }
        } else {
            set msg $body ;# deliver only the payload
        }
        incr recMsgs
        if {$maxMsgs > 0 && $maxMsgs == $recMsgs} {
            unset subscriptions($subID) ;# UNSUB has already been sent, no need to do it here
        } else {
            dict set subscriptions($subID) recMsgs $recMsgs
        }
        if {$postEvent} {
            after 0 [list {*}$callback $subject $msg $replyTo]
        } else {
            # request callbacks
            {*}$callback $subject $msg $replyTo
        }
        # now we return back to CoroMain and enter "yield" there
    }
    
    method PING {cmd} {
        lappend outBuffer "PONG"
        log::debug "received PING, sending PONG"
        my ScheduleFlush
    }
    
    method PONG {cmd} {
        set pong 1
        set counters(pendingPings) 0
        log::debug "received PONG, status: $status"
        if {$status != $nats::status_connected} {
            # auth OK: finalise the connection process
            $serverPool current_server_connected true
            lassign [my current_server] host port
            log::info "Connected to the server at $host:$port"
            set last_error "" ;# cleanup possible error messages about prior connection attempts
            set status $nats::status_connected ;# exit from vwait in "connect"
            my RestoreSubs
            set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
        }
    }
    
    method +OK {cmd} {
        log::debug "+OK" ;# cmd is blank
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
        log::debug "Started coroutine $coro"
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
            # we get here after call to "disconnect"; the socket has been already closed
        } trap {NATS ErrNoServers} {msg opts} {
            # don't overwrite the real last_error; need to log this in case of "connect -async"
            log::error $msg
            # mark all pending requests as timed out
            foreach reqID [array names requests] {
                log::debug "Force timeout of request $reqID"
                after cancel [dict lookup $requests($reqID) timer]
                set callback [dict lookup $requests($reqID) callback]
                if {$callback eq ""} {
                    # leave vwait in all sync requests
                    set requests($reqID) 1 ;# strangely, without this line vwait's don't return
                    unset requests($reqID)
                } else {
                    after 0 [list {*}$callback 1 ""]
                }
            }
        } trap {} {msg opts} {
            log::error "Unexpected error: $msg $opts"
        }
        array unset subscriptions ;# make sure we don't try to restore subscriptions, when we connect next time
        array unset requests
        set requestsInboxPrefix ""
        my CancelConnectTimer
        set status $nats::status_closed
        log::debug "Finished coroutine $coro"
        set coro ""
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
                    set sock ""
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
                # -buffersize is probably not needed, because we call flush regularly anyway
                chan configure $sock -translation {crlf binary} -blocking 0 -buffering full -encoding binary
                chan event $sock readable [list $coro readable]
            }
            connect_timeout {
                set timers(connect) ""
                # we get here both in case of TCP-level timeout and if the server does not reply to the initial PING/PONG on time
                lassign [my current_server] host port
                close $sock
                set sock ""
                $serverPool current_server_connected false
                my AsyncError ErrConnectionTimeout "Connection timeout for $host:$port"
                my ConnectNextServer
            }
            readable {
                # the chan readable event will be sent again and again for as long as there's pending data
                # so I don't need a loop around [chan gets] to read all lines, even if they arrive together
                try {
                    set readCount [chan gets $sock line]
                } trap {POSIX} {err errOpts} {
                    # can be ECONNABORTED or ECONNRESET
                    lassign [my current_server] host port
                    my AsyncError ErrBrokenSocket "Server $host:$port [lindex [dict get $errOpts -errorcode] end]" 1
                    return
                }
                # Tcl documentation for non-blocking gets is very misleading
                # checking for $readCount <= 0 is NOT enough to ensure that I never get an incomplete line
                # so checking for EOF must PRECEDE checking for $readCount
                if {[eof $sock]} {
                    #set err [chan configure $sock -error] - no point in this, $err will be blank
                    lassign [my current_server] host port
                    my AsyncError ErrBrokenSocket "Server $host:$port closed the connection" 1
                    return
                }
                if {$readCount <= 0} {
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
                if {$protocol_op in {MSG HMSG INFO -ERR +OK PING PONG}} {
                    my $protocol_op $protocol_arg
                } else {
                    log::error "Invalid protocol $protocol_op $protocol_arg"
                }
            }
            default {
                log::error "CoroMain: unknown reason $reason"
            }
        }
    }
    
    # ------------ coroutine end -----------------------------------------
    # check if subject/subject with wildcard/queue group is valid
    # Tcl caches the compiled regexp in the thread-local storage, so no need to save it myself
    # per https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md :
    # with no extra args, it checks "reply-to"
    # with -wildcard, it checks "message-subject"
    # with -queue, it checks queue-name
    method CheckSubject {subj args} {
        if {[string length $subj] == 0} {
            return false
        }
        if {!$config(check_subjects)} {
            return true
        }
        set wildcard [expr {"-wildcard" in $args}]
        set queue [expr {"-queue" in $args}]
        # "term" except \ " [] {}
        # this also checks that the string is not empty
        # dash in front of a char set means a literal dash
        set term {^[-[:alnum:]!#$%&'()+,/:;<=?@^_`|~]+$}
        if {$queue} {
            return [regexp -- $term $subj]
        }
        foreach token [split $subj .] {
            if {[regexp -- $term $token]} {
                continue
            }
            if {$wildcard && ($token eq "*" || $token eq ">")} {
                continue
            }
            return false
        }
        return true
    }
    
    method CheckConnection {} {
        # allow to buffer PUB/SUB/UNSUB even before the connection to NATS is finalized
        if {$status eq $nats::status_closed} {
            throw {NATS ErrConnectionClosed} "No connection to NATS server"
        }
    }
    
    method AsyncError {code msg { doReconnect 0 }} {
        # lower severity than "error", because the client can recover and connect to another NATS
        log::warn $msg
        set last_error [dict create code "NATS $code" errorMessage $msg]
        if {$doReconnect} {
            my CloseSocket 1
            my ConnectNextServer ;# can be done only in the coro
        }
    }
    
    method StartConnectTimer {} {
        set timers(connect) [after $config(connect_timeout) [list $coro connect_timeout]]
        log::debug "Started connection timer $timers(connect)"
    }
    
    method CancelConnectTimer {} {
        if {$timers(connect) eq ""} {
            return
        }
        after cancel $timers(connect)
        log::debug "Cancelled connection timer $timers(connect)"
        set timers(connect) ""
    }
}

# by default, when a handshake fails, the TLS library reports it to stderr AND raises an error - see tls.c, function Tls_Error
# so I end up with the same message logged twice. Let's suppress stderr altogether
proc ::nats::tls_callback {args} { }

namespace eval ::nats::msg {
    proc create {subject args} {
        nats::_parse_args $args {
            data str ""
            reply str ""
        }
        return [dict create header "" data $data subject $subject reply $reply sub_id ""]
    }
    proc set {msgVar opt value} {
        switch -- $opt {
            -data - -subject - -reply {
                upvar 1 $msgVar msg
                dict set msg [string trimleft $opt -] $value
                return
            }
            default {
                # do not allow changing the header or sub_id
                throw {NATS ErrInvalidArg} "Invalid field $opt"
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
        upvar 1 $msgVar msg
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
        upvar 1 $msgVar msg
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
        upvar 1 $msgVar msg
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
    # get the first value or default
    proc lookup {msg key def} {
        ::set h [dict get $msg header]
        if {![dict exists $h $key]} {
            return $def
        }
        return [lindex [dict get $h $key] 0]
    }
    namespace export *
    namespace ensemble create
}

# returns ISO 8601 date-time with milliseconds in a local timezone
proc ::nats::timestamp {} {
    # workaround for not being able to format current time with millisecond precision
    # should not be needed in Tcl 8.7, see https://core.tcl-lang.org/tips/doc/trunk/tip/423.md
    set t [clock milliseconds]
    return [format "%s.%03d" \
                [clock format [expr {$t / 1000}] -format "%Y-%m-%dT%H:%M:%S"] \
                [expr {$t % 1000}] ]
}

# 2023-05-30T07:06:22.864305Z to milliseconds
proc ::nats::time_to_millis {time} {
  set seconds 0
  if {[regexp -all {^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2}).(\d+)Z$} $time -> year month day hour minute second micro]} {
    scan [string range $micro 0 2] %d millis ;# could be "081" that would be treated as octal number
    set seconds [clock scan "${year}-${month}-${day} ${hour}:${minute}:${second}" -format "%Y-%m-%d %T" -gmt 1]
    return  [expr {$seconds *  1000 + $millis}]
  }

  throw {NATS InvalidTime} "Invalid time format ${time}"
}

# ------------------------ all following procs are private! --------------------------------------
proc ::nats::_coroVwait {var} {
    if {[info coroutine] eq ""} {
        vwait $var
    } else {
        coroutine::util vwait $var
    }
}
# returns a dict, where each key points to a list of values
# NB! unlike HTTP headers, in NATS headers keys are case-sensitive
proc ::nats::_parse_header {header} {
    set result [dict create]
    # textutil::split::splitx is slower than [string map]+split and RFC 5322 doesn't allow LF in a field body
    set split_headers [split [string map {\r\n \n} $header] \n]
    # the first line is always NATS status like NATS/1.0 404 No Messages
    set split_headers [lassign $split_headers first_line]
    # the code and description are optional
    set descr [lassign $first_line protocol status_code]
    if {![string match "NATS/*" $protocol]} {
        throw {NATS ErrBadHeaderMsg} "Unknown protocol $protocol"
    }
    if {[string is integer -strict $status_code]} {
        dict set result Status $status_code ;# non-int status is allowed but ignored
    }
    if {$descr ne ""} {
        dict set result Description $descr
    }
    # process remaining fields
    foreach line $split_headers {
        lassign [split $line :] k v
        set k [string trim $k]
        set v [string trim $v]
        if {$k ne ""} {
            # empty keys are ignored, but empty values are allowed, see func readMIMEHeader in nats.go
            dict lappend result $k $v
        }
    }
    return $result
}
proc ::nats::_format_header { header } {
    # other official clients accept inline status & description in the first line when *parsing* headers
    # but when serializing headers, status & description are treated just like usual headers
    set result "NATS/1.0\r\n"
    dict for {k v} $header {
        set k [string trim $k]
        if {$k eq ""} {
            continue
        }
        # each key points to a list of values (normally - just one)
        foreach el $v {
            append result "$k: [string trim $el]\r\n"
        }
    }
    # don't append one more \r\n here! the header is put into outBuffer as a separate element
    # so \r\n will be added when flushing
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
# note that NUID chars are only a subset of what is allowed in a subject name
proc ::nats::_random_string {} {
    set allowed_chars "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    set range [string length $allowed_chars]
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
        upvar 1 config config
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
                set val [expr {$val? "true" : "false"}]
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
namespace eval ::nats {
    namespace export connection msg header timestamp
}

# Let me respectfully remind you:
# Birth and death are of supreme importance.
# Time swiftly passes and opportunity is lost.
# Do not squander your life!
