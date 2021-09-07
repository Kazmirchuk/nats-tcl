# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require comm

set commPort 4221

comm::comm config -port $commPort

proc Server {channel clientaddr clientport} {
    set ::sock $channel 
    chan configure $channel -blocking 0 -buffering line -translation crlf
    puts $channel { INFO {"host":"0.0.0.0","port":4222,"max_payload":1048576,"client_id":1,"client_ip":"::1"}}
    chan event $channel readable [list readSocket $channel]
}

proc readSocket {channel} {
    set readCount [chan gets $channel line]
    if {$readCount < 0} {
        if {[eof $channel]} {
            close $channel
        }
        return ;# wait for a full line
    }
    handler $channel $line
}

proc handler {channel line} {
    puts "Got from client: $line"    
}

proc quit {} {
    catch {close $::sock}
    puts "Fake NATS server exiting..."
    exit
}

socket -server Server 4222
puts "Fake NATS server listening on 4222..."
vwait forever
