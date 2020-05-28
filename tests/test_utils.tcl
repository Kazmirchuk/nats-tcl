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

package require tcl::transform::observe
package require tcl::chan::variable
package require processman
package require oo::util

namespace eval test_utils {
    variable sleepVar ""
    
    variable writingObs
    variable readingObs
    variable obsMode
    variable readChan
    variable writeChan
    variable observedSock
    
    variable natsConn ""
    variable simpleMsg ""
    
    # sleep $delay ms in the event loop
    proc sleep {delay} {
        after $delay [list set ::test_utils::sleepVar 1]
        vwait ::test_utils::sleepVar
    }
    
    oo::class create chanObserver {
        variable writingObs readingObs obsMode readChan writeChan observedSock
        # $mode can be r (read), w (write), b (both)
        constructor {sock mode} {
            set writingObs ""
            set readingObs ""
            set obsMode $mode
            set readChan ""
            set writeChan ""
            set observedSock $sock
            
            switch -- $obsMode {
                r {
                    set readChan [tcl::chan::variable [self object]::readingObs]
                    tcl::transform::observe $sock {} $readChan
                }
                w {
                    set writeChan [tcl::chan::variable [self object]::writingObs]
                    tcl::transform::observe $sock $writeChan {}
                }
                b {
                    set readChan [tcl::chan::variable [self object]::readingObs]
                    set writeChan [tcl::chan::variable [self object]::writingObs]
                    tcl::transform::observe $sock $writeChan $readChan
                }
            }
        }
        method getChanData { {firstLine 1} } {
            # remove the transformation
            chan pop $observedSock
            
            if {$readChan ne ""} {
                close $readChan
            }
            if {$writeChan ne ""} {
                close $writeChan
            }
            # these variables contain \r\r\n in each line, and I couldn't get rid of them with chan configure -translation
            # so just remove \r here
            # also we are not interested in PING/PONG, but we need a separate call to "string map" to clean them up *after* removing \r
            set writingObs [string map {\r {} } $writingObs]
            set writingObs [string map {PING\n {} PONG\n {} } $writingObs]
            set readingObs [string map {\r {} } $readingObs]
            set readingObs [string map {PING\n {} PONG\n {}} $readingObs]
            if {$firstLine} {
                set writingObs [lindex [split $writingObs \n] 0]
                set readingObs [lindex [split $readingObs \n] 0]
            }
            switch -- $obsMode {
                r {
                    return $readingObs
                }
                w {
                    return $writingObs
                }
                b {
                    return [list $readingObs $writingObs]
                }
            }
        }
    }
    # a dummy service that after receiving a message waits for the specified time (ms) and then replies with the same message
    oo::class create responder {
        variable natsConn
        constructor {subject} {
            set natsConn [nats::connection new]
            $natsConn configure -servers nats://localhost:4222
            $natsConn connect
            $natsConn subscribe $subject [mymethod echo]
            # force flush
            $natsConn ping
        }
        method echo {subj msg reply sid} {
            lassign $msg delay payload
            if {$delay != 0} {
                test_utils::sleep $delay
            }
            $natsConn publish $reply $payload
            # force flush
            if {![$natsConn ping]} {
                # if this ping didn't succeed, smth went really wrong
                error "responder's ping failed"
            }
        }
        destructor {
            $natsConn destroy
        }
    }
    
    proc simpleCallback {subj msg reply sid} {
        variable simpleMsg
        set simpleMsg $msg
    }

    proc asyncReqCallback {timedOut msg} {
        variable simpleMsg
        if {$timedOut} {
            set simpleMsg "timeout"
        } else {
            set simpleMsg $msg
        }
    }
    
    proc startNats {id args} {
        processman::spawn $id nats-server {*}$args
        sleep 500
    }
    proc stopNats {id} {
        processman::kill $id
    }
}
