# Copyright (c) 2020 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package require struct::list
package require cmdline
package require uri
package require json
package require json::write
package require oo::util
package require tcl::chan::random
package require tcl::randomseed
package require coroutine
package require logger

namespace eval ::nats {
    
    # all options for "configure"
    set option_syntax {
        { servers.list ""                   "URLs of NATS servers"}
        { connection_cb.arg ""              "Callback invoked when the connection is lost, restored or closed"}
        { name.arg ""                       "Client name sent to NATS server when connecting"}
        { pedantic.boolean false            "Pedantic protocol mode. If true some extra checks will be performed by the server"}
        { verbose.boolean false             "If true, every protocol message is echoed by the server with +OK" }
        { connect_timeout.integer 2000      "Connection timeout (ms)"}
        { reconnect_time_wait.integer 2000  "How long to wait between two reconnect attempts to the same server (ms)"}
        { ping_interval.integer 120000      "Interval (ms) to send PING messages to NATS server"}
        { max_outstanding_pings.integer 2   "Max number of PINGs without a reply from NATS before closing the connection"}
        { flush_interval.integer 500        "Interval (ms) to flush sent messages"}
        { randomize.boolean true            "Shuffle the list of NATS servers before connecting"}
        { echo.boolean true                 "If true, messages from this connection will be sent by the server back if the connection has matching subscriptions"}
        { tls_opts.list ""                  "Options for tls::import"}
        { user.arg ""                       "Default username"}
        { password.arg ""                   "Default password"}
        { token.arg ""                      "Default authentication token"}
        { error.arg ""                      "Last socket error (read-only)" }
        { logger.arg ""                     "Logger instance (read-only)" }
        { status.arg ""                     "Connection status: closed, connecting or connected (read-only)" }
    }
    
    oo::class create connection {
        variable config sock coro timers counters subscriptions requests serverInfo serverPool \
                 subjectRegex outBuffer randomChan requestsInboxPrefix pong

        # improvised enum
        variable status_closed status_connecting status_connected
        constructor {} {
            puts "self object: [self object]"
            puts "self namespace: [self namespace]"
            puts "tail: [namespace tail [self object]]"
            set status_closed 0
            set status_connecting 1
            set status_connected 2
        
            # initialise default configuration
            # we need it because untyped options with default value "" are not returned by cmdline::typedGetoptions at all
            foreach option $nats::option_syntax {
                lassign $option name defValue comment
                #drop everything after dot
                set name [lindex [split $name .] 0]
                set config($name) $defValue
            }
            #set config(logger) [logger::init [self object]]
            #$config(logger)::setlevel info
            set config(status) $status_closed
            set sock "" ;# the TCP socket
            set coro "" ;# the coroutine handling readable and writeable events on the socket
            array set timers {ping {} flush {} connect {} }
            array set counters {subscription 0 request 0 curServer "" reconnect 0}
            array set subscriptions {} ;# subID -> dict (cmd , remMsg)
            # async reqs: reqID -> {1 timer callback} ; sync requests: reqID -> {0 timedOut response}
            # RequestCallback needs to distinguish between sync and async, so we need 0/1 in front
            array set requests {} 
            array set serverInfo {} ;# INFO from a current NATS server
            set serverPool [list] ;# list of dicts with parsed nats:// URLs, possibly augmented with extra ones received from a NATS server
            #consider replacing with string is alnum? does this allow Unicode?
            set subjectRegex {^[[:alnum:]_-]+$}
            # all outgoing messages are put in this list before being flushed to the socket,
            # so that even when we are reconnecting, messages can still be sent
            set outBuffer [list]
            set randomChan [tcl::chan::random [tcl::randomseed]] ;# generate inboxes
            set requestsInboxPrefix ""
            set pong 1 ;# sync variable for vwait in "ping". Set to 1 to avoid a check for existing timer in "ping"
            #log trace set config(status)
        }
        
        destructor {
            my disconnect
            close $randomChan
            #log subscriptions requests
            #$config(logger)::delete
        }
        
        method cget {option} {
            set opt [string trimleft $option -]
            if {$opt eq "status"} {
                return [string map [list $status_closed "closed" $status_connecting "connecting" $status_connected "connected"] $config(status)]
            }
            if {[info exists config($opt)]} {
                return $config($opt)
            }
            throw {NATS INVALID_ARG} "Invalid option $option"
        }
        
        method configure {args} {
            if {[llength $args] == 0} {
                return [array get config]
            } 
            if {[llength $args] == 1} {
                if {$args ni {-help -?}} {
                    # let cmdline handle -help
                    return [my cget $args]
                }
            } 
                
            set usage "Usage: configure ?-option value?...\nValid options:"
            try {
                array set options [::cmdline::typedGetoptions args $nats::option_syntax $usage]
            } trap {CMDLINE USAGE} msg {
                # -help also leads here
                throw {NATS INVALID_ARG} $msg
            }
            # avoid re-parsing servers if they were not in $args
            array set config [array get options]
            if {[info exists options(servers)]} {
                set serverPool [list]
                set counters(curServer) ""
                # typedGetoptions wraps lists in extra braces
                foreach url [lindex $options(servers) 0] {
                    lappend serverPool [my ParseServerUrl]
                }
                if {$config(randomize)} {
                    set serverPool [::struct::list shuffle $serverPool]
                }
            }
        }

        method ParseServerUrl {url} {
            # replace nats/tls scheme with http and delegate parsing to the uri package
            set scheme nats
            if {[string equal -length 7 $url "nats://"]} {
                set url [string range $url 7 end]
            } elseif {[string equal -length 6 $url "tls://"]} {
                set url [string range $url 6 end]
                set scheme tls
            }
            
            #uri::split will return a dict with these keys: host, port, user, pwd
            array set srv [uri::split "http://$url"]
            # not interested in these
            foreach k {fragment path query} {
                unset srv($k)
            }
            set srv(scheme) $scheme
            if {[info exists srv(user)] && ![info exists srv(pwd)]} {
                set srv(token) $srv(user)
                unset srv(user)
            }
            return [array get srv]
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
                    throw {NATS INVALID_ARG} "Unknown option $args"
                }
            }
            if {$config(status) != $status_closed} {
                return
            }
            # this coroutine will handle all work to connect and read from the socket
            coroutine coro {*}[mymethod CoroMain]
            # now try connecting to the first server
            $coro connect
            if {!$async} {
                #log config(status)
                vwait [self object]::config(status)
                if {$config(status) != $status_connected} {
                    #TODO: handle TLS error
                    throw {NATS CONNECT_FAIL} "No NATS servers are reachable"
                }
            }
        }
        
        method disconnect {} {
            if {$config(status) == $status_closed} {
                return
            }
            my CloseSocket
            set config(status) $status_closed
        }
        
        method publish {subject msg {replySubj ""}} {
            my CheckConnection
            set msgLen [string length $msg]
            if {$msgLen > $serverInfo(max_payload)} {
                throw {NATS INVALID_ARG} "Maximum size of NATS message is $serverInfo(max_payload)"
            }
            
            if {![my CheckSubject $subject]} {
                throw {NATS INVALID_ARG} "Invalid subject $subject"
            }
            
            set data "PUB $subject $replySubj $msgLen"
            lappend outBuffer $data
            lappend outBuffer $msg
        }
        
        method subscribe {subject args } { 
            my CheckConnection
            set queue ""
            set callback ""
            foreach {opt val} $args {
                switch -- $opt {
                    -queue {
                        set queue $val
                    }
                    -callback {
                        set callback $val
                    }
                    default {
                        throw {NATS INVALID_ARG} "Unknown option $args"
                    }
                }
            }
            
            if {![my CheckWildcard $subject]} {
                throw {NATS INVALID_ARG} "Invalid subject $subject"
            }
            
            if {[string length $callback] == 0} {
                throw {NATS INVALID_ARG} "Invalid callback"
            }
            #rules for queue names are more relaxed than for subjects
            if {$queue ne "" && ![string is graph $queue]} {
                throw {NATS INVALID_ARG} "Invalid queue group $queue"
            }
                                       
            set subID [incr counters(subscription)]
            #remMsg -1 means "unlimited"
            set subscriptions($subID) [dict create cmd $callback remMsg -1]
            
            #the format is SUB <subject> [queue group] <sid>
            set data "SUB $subject $queue $subID"
            lappend outBuffer $data
            return $subID
        }
        
        method unsubscribe {subID {maxMessages 0}} {
            my CheckConnection
            
            if {![info exists subscriptions($subID)]} {
                throw {NATS INVALID_ARG} "Invalid subscription ID $subID"
            }
            
            if {! ([string is integer -strict $maxMessages] && $maxMessages >= 0)} {
                throw {NATS INVALID_ARG} "Invalid maxMessages $maxMessages"
            }
            
            #the format is UNSUB <sid> [max_msgs]
            if {$maxMessages == 0} {
                unset subscriptions($subID)
                set data "UNSUB $subID"
            } else {
                dict update subscriptions($subID) remMsg v {set v $maxMessages}
                set data "UNSUB $subID $maxMessages"
            }
            lappend outBuffer $data
        }
        
        method request {subject message args} {
            set timeout -1 ;# ms
            set callback ""
            
            foreach {opt val} $args {
                switch -- $opt {
                    -timeout {
                        set timeout $val
                    }
                    -callback {
                        set callback $val
                    }
                }
            }
            my CheckTimeout $timeout
            my InitReqSubscription
            set timerID ""
            set reqID [incr counters(request)]
            my publish $subject $message "$requestsInboxPrefix.$reqID"
            if {$callback eq ""} {
                # sync request
                # remember that we can get a reply after timeout, so vwait must wait on a specific reqID
                if {$timeout != -1} {
                     set timerID [after $timeout [list set [self object]::requests($reqID) [list 0 1 ""]]]
                }
                # we don't want to wait for the flusher here, call it now, but don't schedule one more
                my Flusher 0
                set requests($reqID) [list 0]
                vwait [self object]::requests($reqID)
                lassign requests($reqID) ignored timedOut response
                unset requests($reqID)
                if {$timedOut} {
                    throw {NATS TIMEOUT} "Request timeout"
                }
                after cancel $timerID
                return $response
            }
            # async request
            if {$timeout != -1} {  
                set timerID [after $timeout [mymethod RequestCallback "" "" "" $reqID]]
            }
            set requests($reqID) [list 1 $timerID $callback]
        }
        
        method ping { {timeout -1} } {
            my CheckTimeout $timeout
            if {$config(status) != $status_connected} {
                return 0
            }
            lappend outBuffer "PING"
            set timerID ""
            if {$timeout != -1} {
                set timerID [after $timeout [list set [self object]::pong 0]]
            }
            my Flusher 0
            vwait [self object]::pong
            if {$pong} {
                after cancel $timerID
                return 1
            }
            return 0
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
                return
            }
            lassign $requests($reqID) reqType timer callback
            if {$reqType == 0} {
                # resume from vwait in "method request"; "requests" array will be cleaned up there
                set $requests($reqID) [list 0 0 $msg]
                return
            }
            after cancel $timer
            after 0 [list {*}$callback 0 $msg]
            unset requests($reqID)
        }
        
        method CloseSocket { {broken 0} } {
            chan event $sock readable {}
            # make sure we wait until successful flush, if connection was not broken
            if {!$broken} {
                chan configure $sock -blocking 1
            }
            # note: all buffered input is discarded, all buffered output is flushed
            #log
            close $sock
            set sock ""
            unset serverInfo ;# when the variable is re-created, Tcl will remember that this is a data member, not just a local variable
            after cancel $timers(ping)
            after cancel $timers(flush)
            
            if {[info coroutine] eq ""} {
                if {!$broken} {
                    $coro stop
                }
            }
            # note that we don't set config(status) here, because it can be "closed" or "connecting" depending on a caller
        }
        
        method Pinger {} {
            set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
            lappend outBuffer "PING"
            #log
        }
        
        method Flusher { {scheduleNext 1} } {
            if {$scheduleNext} {
                # when this method is called manually, scheduleNext == 0
                set timers(flush) [after $config(flush_interval) [mymethod Flusher]]
            }
            foreach msg $outBuffer {
                puts $sock $msg
            }
            try {
                chan flush $sock
            } on error err {
                my CloseSocket 1
                $coro connect
            }
            # do NOT clear the buffer unless we had a successful flush!
            set outBuffer [list]
        }
        
        # --------- these procs execute in the coroutine ---------------
        # connect to Nth server in the pool
        method ConnectNextServer {} {
            set config(status) $status_connecting
            if {$counters(curServer) eq ""} {
                set counters(curServer) 0
            } else {
                incr counters(curServer)
            }
            if {$counters(curServer) >= [llength $serverPool]} {
                set counters(curServer) 0
                # in case none of the servers are available, avoid running in a tight loop
                coroutine::util after $config(reconnect_time_wait)
            }
            set serverDict [lindex $serverPool $counters(curServer)]
            #log "Connecting to server $currentServerIdx: $serverDict"
            set sock [socket -async [dict get $serverDict host] [dict get $serverDict port]]
            chan event $sock writable [list $coro connected]
            set timers(connect) [after $config(connect_timeout) [list $coro connect_timeout]]
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
            
            my GetCredentials connectParams
            set jsonMsg [json::write::object {*}$connectParams]
            json::write::indented $ind
            lappend outBuffer "CONNECT $jsonMsg"
            set config(currentServer) [lindex $serverPool $currentServerIdx]
            # exit from vwait in "connect"
            set config(status) $status_connected
            my Flusher
            set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
        }
        
        method GetCredentials {varName} {
            upvar $varName connectParams
            if {![info exists serverInfo(auth_required)]} {
                return
            } 
            if {!$serverInfo(auth_required)} {
                return
            }
            set serverDict [lindex $serverPool $counters(curServer)]
            if {[dict exists $serverDict user] && [dict exists $serverDict pwd]} {
                lappend connectParams user [json::write::string [dict get $serverDict user]] pass [json::write::string [dict get $serverDict pwd]]
                return
            }
            if {[dict exists $serverDict token]} {
                lappend connectParams auth_token [json::write::string [dict get $serverDict token]]
                return
            }
            if {$config(user) ne "" && $config(password) ne ""} {
                lappend connectParams user [json::write::string $config(user)] pass [json::write::string $config(password)]
                return
            }
            if {$config(token) ne ""} {
                lappend connectParams auth_token [json::write::string $config(token)]]
                return
            }
            #TODO throw
        }
        
        method INFO {cmd} {
            # example info
            #{"server_id":"kfNjUNirYU3tRVC7akGOcS","version":"1.4.1","proto":1,"go":"go1.11.5","host":"0.0.0.0","port":4222,"max_payload":1048576,"client_id":3}
            array set serverInfo [json::json2dict $cmd]
            if {[info exists serverInfo(tls_required)] && $serverInfo(tls_required)} {
                #NB! NATS server will never accept a TLS connection. Always start connecting with plain TCP,
                # and only after receiving INFO upgrade to TLS if needed
                package require tls
                # I couldn't figure out how to use tls::import with non-blocking sockets
                chan configure $sock -blocking 1
                set serverDict [lindex $serverPool $counters(curServer)]
                tls::import $sock -require 1 -servername [dict get $serverDict host] {*}$config(tls_opts)
                try {
                    tls::handshake $sock
                } on error err {
                    #log
                    set config(error) "TLS handshake failed: $err"
                    #my CloseSocket 1 ???
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
                set actualLength [string length $messageBody]
                # probably == should work ok, but just for safety let's use >=
                if {$actualLength >= $expMsgLength} {
                    break
                }
                set remainingBytes [expr {$expMsgLength - $actualLength}]
                # wait for the remainder of the message; we may need multiple reads to receive all of it
                # it's cleaner to have a second "yield" here than putting this logic in CoroMain
                yield
                #TODO: handle broken socket
                #TODO: will I receive readable event if I don't read all bytes here? chan pending? chan eof? how to notify the coroutine?
            }
            chan configure $sock -translation crlf
            # remove the trailing crlf; is it efficient on large messages?
            set messageBody [string range $messageBody 0 end-2]
            if {[info exists subscriptions($subID)]} {
                # post the event
                set cmdPrefix [dict get $subscriptions($subID) cmd]
                after 0 [list {*}$cmdPrefix $subject $messageBody $replyTo]
                set remainingMsg [dict get $subscriptions($subID) remMsg]
                if {$remainingMsg == 1} {
                    unset subscriptions($subID)
                } elseif {$remainingMsg > 1} {
                    dict update subscriptions($subID) remMsg v {incr v -1}
                }
            } else {
                #log "unexpected message with subID $subID"
            }
            
            # now we return back to CoroMain and enter "yield" there
        }
        
        method PING {cmd} {
            lappend outBuffer "PONG"
        }
        
        method PONG {cmd} {
            set pong 1
        }
        
        method OK {cmd} {
            
        }
        
        method ERR {cmd} {
            
        }
        
        method CoroMain {} {
            set coro [info coroutine]
            while {1} {
                set reason [yield]
                switch -- $reason {
                    connect {
                        my ConnectNextServer
                    }
                    connected - connect_timeout {
                        # this event will arrive again and again if we don't disable it
                        chan event $sock writable {}
                        if { $reason eq "connected"} {
                            after cancel $timers(connect)
                            # the socket either connected or failed to connect
                            set errorMsg [chan configure $sock -error]
                            if { $errorMsg ne "" } {
                                #log "Failed to connect to server $currentServerIdx socket error: $errorMsg"
                                chan close $sock
                                my ConnectNextServer
                                continue
                            }
                            # connection succeeded
                            # we want to call "flush" ourselves, so use -buffering full
                            # NATS protocol uses crlf as a delimiter
                            chan configure $sock -translation crlf -blocking 0 -buffering full
                            chan event $sock readable [list $coro readable]
                        } else {
                            chan close $sock
                            #log "Server $currentServerIdx timed out"
                            my ConnectNextServer
                        }
                    }
                    readable {
                        set readCount [chan gets $sock line]
                        #MAX_CONTROL_LINE_SIZE = 1024
                        if {$readCount < 0} {
                            if {[eof $sock]} { ;# what if server wrote crlf and closed the socket? should I move eof before if?
                                # server closed the socket
                                my CloseSocket 1
                                my ConnectNextServer
                            }
                            # else - we don't have a full line yet - wait for next chan event
                            continue
                        }
                        # extract the first word from the line (INFO, MSG etc)
                        # protocol_arg will be empty in case of PING/PONG/OK
                        set protocol_arg [lassign $line protocol_op]
                        # in case of -ERR or +OK
                        set protocol_op [string trimleft $protocol_op -+]
                        my $protocol_op $protocol_arg
                        #TODO: handle protocol violation
                        # TODO: what if more bytes available to read?
                    }
                    stop {
                        set config(status) $status_closed
                        break
                    }
                    default {
                        #log "Unknown reason"
                    }
                }
            }
            #log "finished coroutine"
        }
        
        # ------------ coroutine end -----------------------------------------
        
        method InitReqSubscription {} {
            if {$requestsInboxPrefix ne {}} {
                # we already subscribed
                return
            }
            set requestsInboxPrefix [my inbox]
            my subscribe "$requestsInboxPrefix.*" [mymethod RequestCallback]
        }
        
        method CheckSubject {subj} {            
            if {[string length $subj] == 0} {
                return false
            }
            foreach token [split $subj .] {
                if {![regexp -- $subjectRegex $token]} {
                    return false
                }
            }
            return true
        }
        
        method CheckWildcard {subj} {            
            if {[string length $subj] == 0} {
                return false
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
            if {$config(status) == $status_closed} {
                throw {NATS NO_CONNECTION} "No connection to NATS server"
            }
        }
        
        method CheckTimeout {timeout} {
            if {$timeout != -1} {
                if {! ([string is integer -strict $timeout] && $timeout > 0)} {
                    throw {NATS INVALID_ARG} "Invalid timeout $timeout"
                }
            }
        }
    } ;# end of class connection
} ;# end of namespace

package provide nats 0.9
