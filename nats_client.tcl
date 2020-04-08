# Copyright 2020 Petro Kazmirchuk https://github.com/Kazmirchuk
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
package require uri
package require json
package require coroutine

namespace eval ::nats {
    namespace export connect disconnect publish subscribe unsubscribe
    variable debug false
    
    namespace eval private {
        variable connected false
        variable sock ""
        variable subscriptionCounter 0
        array set subscriptions {}
        variable serverInfo
        variable maxMessageLen
        # having this regex as namespace variable should ensure that it is compiled once and then reused
        variable subjectRegex {^[[:alnum:]_-]+$}
    }
}

proc ::nats::connect {url {options ""}} {
    variable ::nats::private::sock
    variable ::nats::private::connected

    if {$connected} {
        return
    }
    
    if { $::nats::debug } {
        package require debug
        interp bgerror "" ::nats::private::backgroundError
    }
    
    # replace nats scheme with http and delegate parsing to the uri package
    if {[string equal -length 7 $url "nats://"]} {
        set url [string range $url 7 end]
    }
    array set parsed_url [uri::split "http://$url"]
    set sock [socket $parsed_url(host) $parsed_url(port)]
    set user $parsed_url(user)
    set password $parsed_url(pwd)
    
    # create a coroutine to read data from NATS server and configure the socket
    # we want to call "flush" ourselves, so use -buffering full
    chan configure $sock -translation crlf -blocking 0 -buffering full
    coroutine ::nats::private::reading_coro ::nats::private::readSocket
    # wake up the coroutine with 1 when there is incoming data, and with 0 if the server closed the socket
    chan event $sock readable [list ::nats::private::reading_coro 1]

    # the "cron" package from Tcllib would be a bit more convenient
    # but it supports millisecond resolution only in Tcllib 1.19
    # we will cancel these timers when the socket is closed
    #set ::nats::private::flusherTimer [after 500 ::nats::private::flusher]
    #set ::nats::private::pingerTimer [after 120000 ::nats::private::pinger]
    after 500 ::nats::private::flusher
    after 120000 ::nats::private::pinger
    
    #there is a chance that at this point $connected is already true
    if {!$connected} {
        nats::private::debugLog "waiting for connected"
        # gotcha: [namespace -which] doesn't work for $connected here
        vwait ::nats::private::connected
        nats::private::debugLog "finished waiting"
    }
}

proc ::nats::disconnect {} {
    variable ::nats::private::connected
    
    if {!$connected} {
        return
    }
    ::nats::private::cleanup
}

proc ::nats::publish {subject msg {reply_subj ""}} {
    variable ::nats::private::sock
    variable ::nats::private::connected
    variable ::nats::private::maxMessageLen
    
    if {!$connected} {
        return -code error -errorcode {NATS NO_CONNECTION} "No connection to NATS server"
    }
    set msgLen [string length $msg]
    if {$msgLen > $maxMessageLen} {
        return -code error -errorcode {NATS INVALID_ARG} "Maximum size of NATS message is $maxMessageLen"
    }
    
    if {![nats::private::checkSubject $subject]} {
        return -code error -errorcode {NATS INVALID_ARG} "Invalid subject $subject"
    }
    
    set data "PUB $subject $reply_subj $msgLen"
    nats::private::debugLog "Sending $data\n $msg"
    puts $sock $data
    puts $sock $msg
}

proc ::nats::subscribe {subject commandPrefix} {
    variable ::nats::private::sock
    variable ::nats::private::connected
    variable ::nats::private::subscriptionCounter
    variable ::nats::private::subscriptions
    
    if {!$connected} {
        return -code error -errorcode {NATS NO_CONNECTION} "No connection to NATS server"
    }
    
    if {![nats::private::checkWildcard $subject]} {
        return -code error -errorcode {NATS INVALID_ARG} "Invalid subject $subject"
    }
    
    incr subscriptionCounter
    set subscriptions($subscriptionCounter) $commandPrefix
    set data "SUB $subject $subscriptionCounter"
    nats::private::debugLog "Sending $data"
    puts $sock $data
}

proc ::nats::unsubscribe {subID {maxMessages ""}} {
    variable ::nats::private::subscriptions
    variable ::nats::private::sock
    variable ::nats::private::connected
    
    if {!$connected} {
        return -code error -errorcode {NATS NO_CONNECTION} "No connection to NATS server"
    }
    
    if {![info exists subscriptions($subID)]} {
        return -code error -errorcode {NATS INVALID_ARG} "Invalid subscription ID $subID"
    }
    
    if {[string length $maxMessages]} {
        if {! ([string is integer -strict $maxMessages] && $maxMessages > 0)} {
            return -code error -errorcode {NATS INVALID_ARG} "Invalid maxMessages $maxMessages"
        }
    }
    set data "UNSUB $subID $maxMessages"
    nats::private::debugLog "Sending $data"
    puts $sock $data
    if {$maxMessages == ""} {
        # TODO: cleanup the array when $maxMessages > 0 too
        unset subscriptions($subID)
    }
}

proc ::nats::private::flusher {} {
    after 500 ::nats::private::flusher
    variable sock
    debugLog "Flushing"
    chan flush $sock
}

proc ::nats::private::pinger {} {
    after 120000 ::nats::private::pinger
    variable sock
    debugLog "Sending PING"
    puts $sock "PING"
}

# --------- these procs execute in the coroutine reading_coro ---------------

proc ::nats::private::sendConnect {} {
    variable sock
    variable connected
    
    set data {CONNECT {"verbose":false,"pedantic":false,"tls_required":false,"name":"nats-tcl","lang":"Tcl","version":"0.9","protocol":1,"echo":true}}
    debugLog "Sending $data"
    puts $sock $data
    flush $sock
    # exit from vwait in "connect"
    set connected true
}

proc ::nats::private::INFO {cmd} {
    variable serverInfo
    variable maxMessageLen
    
    # example info
    #{"server_id":"kfNjUNirYU3tRVC7akGOcS","version":"1.4.1","proto":1,"go":"go1.11.5","host":"0.0.0.0","port":4222,"max_payload":1048576,"client_id":3}
    
    set serverInfo [json::json2dict $cmd]
    set maxMessageLen [dict get $serverInfo max_payload]
    sendConnect
}

proc ::nats::private::MSG {cmd} {
    variable sock
    variable subscriptions
    
    # the format is <subject> <sid> [reply-to] <#bytes>
    set replyTo ""
    if {[llength $cmd] == 4} {
        lassign $cmd subject subscriptionID replyTo expMsgLength
    } else {
        lassign $cmd subject subscriptionID expMsgLength
    }
    # turn off crlf translation while we read the message body
    chan configure $sock -translation binary
    # account for these crlf bytes that follow the message
    incr expMsgLength 2
    set messageBody ""
    while {[string length $messageBody] != $expMsgLength} {
        # wait for the message; we may need multiple reads to receive all of it
        # it's cleaner to have a second "yield" here then putting this logic in readSocket
        yield
        append messageBody [coroutine::util read $sock $expMsgLength]
    }
    chan configure $sock -translation crlf
    # remove the trailing crlf
    set messageBody [string range $messageBody 0 end-2]
    debugLog "Received msg $messageBody length [string length $messageBody]"
    if {[info exists subscriptions($subscriptionID)]} {
        # I don't want any possible error in user code to mess up with my implementation, so let's schedule the execution in future
        after idle [list {*}$subscriptions($subscriptionID) $subject $messageBody $replyTo $subscriptionID]
    } else {
        debugLog "unexpected message with subID $subscriptionID"
    }
    # now we return back to readSocket and enter "yield" there
}

proc ::nats::private::PING {cmd} {
    variable sock
    debugLog "Sending PONG"
    puts $sock "PONG"
}

proc ::nats::private::PONG {cmd} {
    debugLog "received PONG"
}

proc ::nats::private::+OK {cmd} {
    
}

proc ::nats::private::-ERR {cmd} {
    
}

proc ::nats::private::readSocket {} {
    variable sock
    variable connected
    
    while {[yield]} {
        # the coroutine will be resumed at this point each time we receive data on the socket
        # we break the loop only when the socket is closed
        debugLog "coro woke up"

        # note: [coroutine::util gets] will not work here (coroutine will not wake up) if it can't read the whole line at once!
        set readCount [chan gets $sock line]
        if {$readCount < 0} {
            if {[eof $sock]} {
                # server closed the socket
                break
            } else {
                # we don't have a full line yet - wait for next fileevent
                debugLog "no full line yet"
                continue
            }
        }
        debugLog "Received $readCount bytes:\n$line"
        # extract the first word from the line (INFO, MSG etc)
        # protocol_arg will be empty in case of PING/PONG
        set protocol_arg [lassign $line protocol_op]
        nats::private::$protocol_op $protocol_arg
    }
    
    after cancel ::nats::private::flusher
    after cancel ::nats::private::pinger
    set connected false
    close $sock
    set sock ""
    debugLog "finished coroutine"
}

# ------------ coroutine end -----------------------------------------

proc ::nats::private::backgroundError {args} {
    debugLog "Background error: $args"
}

proc ::nats::private::debugLog {msg} {
    if { !$::nats::debug } {
        return
    }
    # workaround for not being able to format current time with millisecond precision
    # should not be needed in Tcl 8.7, see https://core.tcl-lang.org/tips/doc/trunk/tip/423.md
    set t [clock milliseconds]
    set timestamp [format "%s.%03d" \
                      [clock format [expr {$t / 1000}] -format %T] \
                      [expr {$t % 1000}] \
                  ]
    
    puts stderr "$timestamp: $msg"
}

proc ::nats::private::checkSubject {subj} {
    variable ::nats::private::subjectRegex
    
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

proc ::nats::private::checkWildcard {subj} {
    variable ::nats::private::subjectRegex
    
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

package provide nats 0.9
