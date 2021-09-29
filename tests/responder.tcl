# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# a dummy service that listens on the subject "service"
# after receiving a message it waits for the specified time (ms) and then replies with the same message
package require lambda

proc echo {subj msg reply} {
    set hdr ""
    if {$::dictMsg} {
        set hdr [dict get $msg header]
        set msg [dict get $msg data]
    }
    #lassign $msg delay payload - doesn't work with binary payload
    set pos [string first " " $msg]
    set delay [string range $msg 0 [expr {$pos - 1}]]
    set payload [string range $msg [expr {$pos + 1}] end]
    
    if {$payload eq "exit"} {
        puts "Responder $subj exiting..."
        exit
    }
    after $delay [lambda {reply payload hdr} {
        if {$::dictMsg} {
            $::conn publish $reply $payload -header $hdr
        } else {
            $::conn publish $reply $payload
        }
    } $reply $payload $hdr]
}

set thisDir [file dirname [info script]]
lappend auto_path [file normalize [file join $thisDir ..]]
package require nats

lassign $argv subj queue dictMsg

set conn [nats::connection new "Responder $subj"]
$conn configure -servers nats://localhost:4222
$conn connect
if {$queue eq "" } {
    $conn subscribe $subj -dictmsg $dictMsg -callback echo
} else {
    $conn subscribe $subj -dictmsg $dictMsg -callback echo -queue $queue
}

puts "Responder listening on $subj : $queue"
$conn publish "$subj.ready" {} ;# test_utils::startResponder is waiting for this message
vwait forever
