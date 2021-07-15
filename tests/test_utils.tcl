# Copyright (c) 2020 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require tcl::transform::observe
package require tcl::chan::variable
package require processman
package require oo::util

namespace eval test_utils {
    variable sleepVar 0
    
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
    
    proc new_sleep {delay} {
        set varName "::[incr ::test_utils::sleepVar]"
        set $varName 0
        after $delay [list set $varName 1]
        vwait $varName
        unset $varName
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
    
    proc simpleCallback {subj msg reply} {
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
        puts stderr "[nats::timestamp] Started $id"
    }
    
    proc stopNats {id} {
        # processman::kill on Linux relies on odielib or Tclx packages that might not be available
        if {$::tcl_platform(platform) eq "unix"} {
            foreach pid [dict get $processman::process_list $id] {
                catch {exec kill $pid}
            }
            after 500
            return
        }
        processman::kill $id
        puts stderr "[nats::timestamp] Stopped $id"
    }
    
    # processman::kill doesn't work reliably with tclsh, so instead we send a NATS message to stop the responder gracefully
    proc startResponder {} {
        set scriptPath [file join [file dirname [info script]] responder.tcl]
        exec [info nameofexecutable] $scriptPath &
        sleep 1000
    }
    
    proc stopResponder {conn} {
        $conn publish service [list 0 exit]
    }
}
