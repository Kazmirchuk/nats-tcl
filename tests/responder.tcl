# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# a dummy service that listens on the subject "service"
# after receiving a message it waits for the specified time (ms) and then replies with the same message
package require lambda

proc echo {subj msg reply} {
    lassign $msg delay payload
    if {$payload eq "exit"} {
        exit
    }
    after $delay [lambda {reply payload} {
        $::conn publish $reply $payload
        $::conn ping
    } $reply $payload]
}

set thisDir [file dirname [info script]]
lappend auto_path [file normalize [file join $thisDir ..]]
package require nats

set conn [nats::connection new]
$conn configure -servers nats://localhost:4222
$conn connect
$conn subscribe service -callback echo
$conn ping

vwait forever
