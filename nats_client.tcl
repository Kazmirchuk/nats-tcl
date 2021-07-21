# Copyright (c) 2020 Petro Kazmirchuk https://github.com/Kazmirchuk

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
package require control

namespace eval ::nats {
    # improvised enum
    variable status_closed 0
    variable status_connecting 1
    variable status_connected 2
    variable status_reconnecting 3
}
# all options for "configure"
# due to a bug, when I pass a list to cmdline::typedGetoptions, it is returned wrapped in extra braces
# so all options that may be lists or may contain spaces are marked with .list here
# and then in "configure" I have special treatment to unpack them with [lindex $val 0]
# note that this bug does not occur with cmdline::getoptions
set ::nats::option_syntax {
    { servers.list ""                   "URLs of NATS servers"}
    { name.arg ""                       "Client name sent to NATS server when connecting"}
    { pedantic.boolean false            "Pedantic protocol mode. If true some extra checks will be performed by the server"}
    { verbose.boolean false             "If true, every protocol message is echoed by the server with +OK" }
    { connect_timeout.integer 2000      "Connection timeout (ms)"}
    { reconnect_time_wait.integer 2000  "How long to wait between two reconnect attempts to the same server (ms)"}
    { max_reconnect_attempts.integer 60 "Maximum number of reconnect attempts per server"}
    { ping_interval.integer 120000      "Interval (ms) to send PING messages to NATS server"}
    { max_outstanding_pings.integer 2   "Max number of PINGs without a reply from NATS before closing the connection"}
    { flush_interval.integer 500        "Interval (ms) to flush sent messages"}
    { echo.boolean true                 "If true, messages from this connection will be sent by the server back if the connection has matching subscriptions"}
    { tls_opts.list ""                  "Options for tls::import"}
    { user.list ""                      "Default username"}
    { password.list ""                  "Default password"}
    { token.arg ""                      "Default authentication token"}
    { secure.boolean false              "Indicate to the server if the client wants a TLS connection"}
    { send_asap.boolean false           "Make publish calls send the data immediately, reducing latency, but also throughput"}
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
        # we need it because untyped options with default value "" are not returned by cmdline::typedGetoptions at all
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
        # and there's no documented way to customize it
        proc ${logger}::stdoutcmd {level text} {
            variable service
            puts "\[[nats::timestamp] $service $level\] $text"
        }
        
        # default level in the logger is debug, it's too verbose
        ${logger}::setlevel warn
        
        set sock "" ;# the TCP socket
        set coro "" ;# the coroutine handling readable and writeable events on the socket
        array set timers {ping {} flush {} connect {} }
        array set counters {subscription 0 request 0}
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
        #if {[array size subscriptions]} {
        #    $logger::debug "Remaining subscriptions: [array get subscriptions]"
        #}
        if {[array size requests]} {
            ${logger}::debug "Remaining requests: [array get requests]"
        }
        ${logger}::delete
    }
    
    method cget {option} {
        set opt [string trimleft $option -]
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
        foreach {opt val} [array get options] {
            # workaround for a bug in cmdline::typedGetoptions as explained above
            if {[lsearch -index 0 $nats::option_syntax "$opt.list"] != -1} {
                set config($opt) [lindex $val 0]
            } else {
                set config($opt) $val
            }
        }
        # avoid re-parsing servers if they were not in $args
        if {[info exists options(servers)]} {
            $serverPool clear
            foreach url $config(servers) {
                $serverPool add $url
            }
        }
    }

    method logger {} {
        return $logger
    }
    
    method current_server {} {
        return [$serverPool current_server]
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
        if {$status != $nats::status_closed} {
            return
        }
        
        if {[llength [$serverPool all_servers]] == 0} {
            throw {NATS NO_SERVERS} "Server pool is empty"
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
                throw {NATS CONNECT_FAILED} "No NATS servers available"
            }
            ${logger}::debug "Finished waiting for connection"
        }
    }
    
    method disconnect {} {
        if {$status == $nats::status_closed} {
            return
        }
        my Flusher 0
        my CloseSocket
        #CoroMain will set status to "closed"
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
                    throw {NATS INVALID_ARG} "Unknown option $opt"
                }
            }
        }
        
        if {![my CheckWildcard $subject]} {
            throw {NATS INVALID_ARG} "Invalid subject $subject"
        }
        
        if {[string length $callback] == 0} {
            throw {NATS INVALID_ARG} "Invalid callback"
        }
        
        if {! ([string is integer -strict $maxMsgs] && $maxMsgs >= 0)} {
            throw {NATS INVALID_ARG} "Invalid max_msgs $maxMsgs"
        }
        
        #rules for queue names are more relaxed than for subjects
        if {$queue ne "" && ![string is graph $queue]} {
            throw {NATS INVALID_ARG} "Invalid queue group $queue"
        }
                                   
        set subID [incr counters(subscription)]
        set subscriptions($subID) [dict create subj $subject queue $queue cmd $callback maxMsgs $maxMsgs recMsgs 0]
        
        #the format is SUB <subject> [queue group] <sid>
        if {$status != $nats::status_reconnecting} {
            # it will be sent anyway when we reconnect
            lappend outBuffer "SUB $subject $queue $subID"
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
                    throw {NATS INVALID_ARG} "Unknown option $opt"
                }
            }
        }
        
        if {! ([string is integer -strict $maxMsgs] && $maxMsgs >= 0)} {
            throw {NATS INVALID_ARG} "Invalid max_msgs $maxMsgs"
        }
        
        if {![info exists subscriptions($subID)]} {
            throw {NATS INVALID_ARG} "Invalid subscription ID $subID"
        }
        
        #the format is UNSUB <sid> [max_msgs]
        if {$maxMsgs == 0} {
            unset subscriptions($subID)
            set data "UNSUB $subID"
        } else {
            #TODO: should i set rec other clients don't
            dict set subscriptions($subID) maxMsgs $maxMsgs
            set data "UNSUB $subID $maxMsgs"
        }
        if {$status != $nats::status_reconnecting} {
            # it will be sent anyway when we reconnect
            lappend outBuffer $data
        }
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
                    throw {NATS INVALID_ARG} "Unknown option $opt"
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
            # we don't want to wait for the flusher here, call it now, but don't schedule one more
            my Flusher 0
            set requests($reqID) [list 0]
            my CoroVwait [self object]::requests($reqID)
            lassign $requests($reqID) ignored timedOut response
            unset requests($reqID)
            if {$timedOut} {
                throw {NATS TIMEOUT} "Request to $subject timed out"
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
        if {$status != $nats::status_connected} {
            return false
        }
        set timerID ""
        if {$timeout != -1} {
            my CheckTimeout $timeout
            set timerID [after $timeout [list set [self object]::pong 0]]
        }
        lappend outBuffer "PING"
        my Flusher 0
        my CoroVwait [self object]::pong
        if {$pong} {
            after cancel $timerID
            return true
        }
        return false
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
            set requests($reqID) [list 0 0 $msg]
            return
        }
        after cancel $timer
        after 0 [list {*}$callback 0 $msg]
        unset requests($reqID)
    }
    
    method CloseSocket { {broken 0} } {
        chan event $sock readable {}
        # this method is only for closing an established connection
        # it is not convenient to re-use it for all cases of close $sock
        # because it does a lot of other work
        control::assert {$status == $nats::status_connected}
        if {$broken} {
            $serverPool current_server_connected false
            set status $nats::status_reconnecting
        } else {
            # make sure we wait until successful flush, if connection was not broken
            # TODO do it only for destructor? before exiting process
            chan configure $sock -blocking 1
            lassign [$serverPool current_server] host port
            ${logger}::info "Closing connection to $host:$port" ;# in case of broken socket, the error will be logged elsewhere
        }
        close $sock ;# all buffered input is discarded, all buffered output is flushed
        set sock ""
        array unset serverInfo
        after cancel $timers(ping)
        after cancel $timers(flush)
        
        if {[info coroutine] eq ""} {
            if {!$broken} {
                $coro stop
            }
        }
    }
    
    method Pinger {} {
        set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
        lappend outBuffer "PING"
        ${logger}::debug "Sending PING"
    }
    
    method Flusher { {scheduleNext 1} } {
        if {$scheduleNext} {
            # when this method is called manually, scheduleNext == 0
            set timers(flush) [after $config(flush_interval) [mymethod Flusher]]
        }
        try {
            foreach msg $outBuffer {
                append msg "\r\n"
                puts -nonewline $sock $msg
            }
            chan flush $sock
        } on error err {
            lassign [$serverPool current_server] host port
            ${logger}::error "Failed to send data to $host:$port: $err"
            my AsyncError BROKEN_SOCKET $err
            my CloseSocket 1
            $coro connect
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
        # if it throws NO_SERVERS, we have exhausted all servers in the pool
        # we must stop the coroutine, so let the error propagate
        lassign [$serverPool next_server] host port
        ${logger}::info "Connecting to the server at $host:$port"
        set sock [socket -async $host $port]
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
        #TODO check for ok auth before declaring success
        $serverPool current_server_connected true
        lassign [$serverPool current_server] host port
        ${logger}::info "Connected to the server at $host:$port"
        # exit from vwait in "connect"
        set status $nats::status_connected
        my RestoreSubs
        my Flusher ;# flush the buffer now if it has any data
        set timers(ping) [after $config(ping_interval) [mymethod Pinger]]
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
                ${logger}::error "TLS handshake with server $host:$port failed: $err"
                my AsyncError TLS_FAILED $err
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
        # nothing to do
    }
    
    method ERR {cmd} {
        ${logger}::error $cmd
        my AsyncError SERVER_ERR $cmd
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
                if {$reason ni [list connect connected connect_timeout readable]} {
                    ${logger}::error "CoroMain: unknown reason $reason"
                }
                my ProcessEvent $reason
            }
        } trap {NATS STOP_CORO} {msg opts} {
            # we get here after call to "disconnect" during MSG; the socket has been already closed,
            # so we only need to update the status
        } trap {NATS} {msg opts} {
            #todo: try yieldto? 
            #my AsyncError [lindex [dict get $opts -errorcode] 1] $msg
            #NO_SERVERS error from next_server leads here; don't overwrite the real last_error
            ${logger}::error $msg
        } trap {} {msg opts} {
            ${logger}::error "Unexpected error: $msg $opts"
        } finally {}
        set status $nats::status_closed
        ${logger}::debug "Finished coroutine $coro"
    }
    
    method ProcessEvent {reason} {
        switch -- $reason {
            connect {
                my ConnectNextServer
            }
            connected - connect_timeout {
                # this event will arrive again and again if we don't disable it
                chan event $sock writable {}
                lassign [$serverPool current_server] host port
                if { $reason eq "connected"} {
                    after cancel $timers(connect)
                    # the socket either connected or failed to connect
                    set errorMsg [chan configure $sock -error]
                    if { $errorMsg ne "" } {
                        ${logger}::error "Failed to connect to server $host:$port: $errorMsg"
                        my AsyncError CONNECT_FAILED $errorMsg
                        close $sock
                        $serverPool current_server_connected false
                        my ConnectNextServer
                        return
                    }
                    # connection succeeded
                    # we want to call "flush" ourselves, so use -buffering full
                    # NATS protocol uses crlf as a delimiter
                    # when reading from socket, it's easier to let Tcl do EOL translation, unless we are in method MSG
                    # when writing to socket, we need to turn off the translation when sending a message payload
                    # but outBuffer doesn't know which element is a message, so it's easier to write CR+LF ourselves
                    chan configure $sock -translation {crlf binary} -blocking 0 -buffering full -encoding binary
                    chan event $sock readable [list $coro readable]
                } else {
                    close $sock
                    ${logger}::error "Connection timeout for $host:$port"
                    my AsyncError CONNECT_TIMEOUT "Connection timeout for $host:$port"
                    $serverPool current_server_connected false
                    my ConnectNextServer
                }
            }
            readable {
                # confirmed by testing: apparently the Tcl TCP is implemented like:
                # 1. send "readable" event
                # 2. any bytes left in the input buffer? send the event again
                # so, it simplifies my work here - even if I don't read all available bytes with this "chan gets",
                # the coroutine will be invoked again as soon as a complete line is available
                #TODO do i need catch around gets? if remote end aborts network connection
                set readCount [chan gets $sock line]
                if {[chan pending input $sock] > 1024} {
                    # max length of control line in the NATS protocol is 1024 (see MAX_CONTROL_LINE_SIZE in nats.py)
                    # this should not happen unless the NATS server is malfunctioning
                    ${logger}::error "Maximum control line exceeded"
                    my AsyncError SERVER_ERR "Maximum control line exceeded"
                    my CloseSocket 1
                    my ConnectNextServer
                    return
                }
                if {$readCount < 0} {
                    if {[eof $sock]} { 
                        # server closed the socket
                        #set err [chan configure $sock -error] - no point in this, $err will be blank
                        lassign [$serverPool current_server] host port
                        ${logger}::error "Failed to read data from $host:$port"
                        my AsyncError BROKEN_SOCKET "Failed to read from socket"
                        my CloseSocket 1
                        my ConnectNextServer
                    }
                    # else - we don't have a full line yet - wait for next chan event
                    return
                }
                # extract the first word from the line (INFO, MSG etc)
                # protocol_arg will be empty in case of PING/PONG/OK
                set protocol_arg [lassign $line protocol_op]
                # in case of -ERR or +OK
                set protocol_op [string trimleft $protocol_op -+]
                if {$protocol_op in [list MSG INFO ERR OK PING PONG]} {
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
        if {$status == $nats::status_closed} {
            throw {NATS NO_CONNECTION} "No connection to NATS server"
        }
    }
    
    method CheckTimeout {timeout} {
        if {! ([string is integer -strict $timeout] && $timeout > 0)} {
            throw {NATS INVALID_ARG} "Invalid timeout $timeout"
        }
    }
    
    method AsyncError {code msg} {
        set last_error [dict create code "NATS $code" message $msg]
    }
}

namespace eval ::nats {
    proc timestamp {} {
        # workaround for not being able to format current time with millisecond precision
        # should not be needed in Tcl 8.7, see https://core.tcl-lang.org/tips/doc/trunk/tip/423.md
        set t [clock milliseconds]
        set timeStamp [format "%s.%03d" \
                          [clock format [expr {$t / 1000}] -format %T] \
                          [expr {$t % 1000}] \
                      ]
        return $timeStamp
    }
}

package provide nats 0.9
