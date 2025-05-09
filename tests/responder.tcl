# Copyright (c) 2021-2023 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# a dummy service that listens to a subject, default "service"
# after receiving a message it waits for the specified time (ms) and then replies with the same message
# all these procs are run in a background thread, invoked by the responder object in test_utils
# tcltest implicitly redirects stdout from the responder to outputChannel

package require nats
package require lambda

namespace eval ::responder {
    variable conn ""
}

proc ::responder::echo {subj msg reply} {
    set data [nats::msg data $msg]
    # the first token is a delay
    set pos [string first " " $data]
    set delay [string range $data 0 [expr {$pos - 1}]]
    set payload [string range $data [expr {$pos + 1}] end]
    # preserve headers if any
    nats::msg set msg -subject $reply
    nats::msg set msg -data $payload
    nats::msg set msg -reply ""
    after $delay [lambda {conn msg} {
        set s [$conn cget -status]
        if {$s ne "connected"} {
            # avoid that a message is buffered while the responder is reconnecting; if we get here, test timings are wrong
            puts "\[[nats::timestamp] [$conn cget -name] error\] Trying to send [nats::msg data $msg] while $s"
            return
        }
        $conn publish_msg $msg
    } $::responder::conn $msg]
}

proc ::responder::init {id subj queue servers} {
    variable conn
    set conn [nats::connection new "responder $id"]
    # don't try to reconnect if the connection is lost
    $conn configure -max_reconnect_attempts 1 -connect_timeout 500 -dictmsg true
    if {$servers eq ""} {
        $conn configure -servers nats://localhost:4222
    } else {
        $conn configure -servers $servers
    }
    $conn connect
    if {$queue eq "" } {
        $conn subscribe $subj -callback responder::echo
    } else {
        $conn subscribe $subj -callback responder::echo -queue $queue
    }
    $conn ping ;# ensure the subscriptions are ready before returning
    # no need to trace the connection status
    # if the connection is lost, it will be logged; let the thread live until it is released by the main thread
}

proc ::responder::shutdown {} {
    $::responder::conn destroy
}
