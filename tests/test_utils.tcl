# Copyright (c) 2020 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require tcl::transform::observe
package require tcl::chan::variable
package require processman
package require oo::util
package require control

namespace eval test_utils {
    variable sleepVar 0
    
    variable simpleMsg ""
    
    # sleep $delay ms in the event loop
    proc sleep {delay} {
        after $delay [list set ::test_utils::sleepVar 1]
        vwait ::test_utils::sleepVar
    }
    
    proc wait_flush {conn} {
        # wait until Flusher executes
        vwait ${conn}::timers(flush)
    }
    
    # I don't like that [time] ignores the result of $body, and I need milliseconds rather than microseconds
    proc duration {body var} {
        upvar 1 $var elapsed
        set now [clock millis]
        set code [catch {uplevel 1 $body} result]
        set elapsed [expr {[clock millis] - $now}]
        if {$code == 1} {
            return -errorinfo [::control::ErrorInfoAsCaller uplevel duration] -errorcode $::errorCode -code error $result
        } else {
            return -code $code $result
        }
    }
    
    oo::class create chanObserver {
        variable writingObs readingObs obsMode readChan writeChan observedSock
        # $mode can be r (read), w (write), b (both)
        constructor {nats_conn mode} {
            set writingObs ""
            set readingObs ""
            set obsMode $mode
            set readChan ""
            set writeChan ""
            set observedSock [set ${nats_conn}::sock]
            
            switch -- $obsMode {
                r {
                    set readChan [tcl::chan::variable [self object]::readingObs]
                    tcl::transform::observe $observedSock {} $readChan
                }
                w {
                    set writeChan [tcl::chan::variable [self object]::writingObs]
                    tcl::transform::observe $observedSock $writeChan {}
                }
                b {
                    set readChan [tcl::chan::variable [self object]::readingObs]
                    set writeChan [tcl::chan::variable [self object]::writingObs]
                    tcl::transform::observe $observedSock $writeChan $readChan
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
            set writingObs [split $writingObs \n]
            set readingObs [split $readingObs \n]
            if {$firstLine} {
                set writingObs [lindex $writingObs 0]
                set readingObs [lindex $readingObs 0]
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
    proc startResponder { {subj "service"} {queue ""}} {
        set scriptPath [file join [file dirname [info script]] responder.tcl]
        exec [info nameofexecutable] $scriptPath $subj $queue &
        sleep 500
    }
    
    proc stopResponder {conn {subj "service"}} {
        $conn publish $subj [list 0 exit]
        wait_flush $conn
    }
    
    # control:assert is garbage and doesn't perform substitution on failed expressions, so I can't even know a value of offending variable etc
    # also tried to do this
    #control::control assert callback [lambda {msg} {
    #    return -code error [uplevel 1 [list subst $msg]]
    #}]
    # but it doesn't work when assert is in a proc
    proc assert {expression} {
        set code [catch {uplevel 1 [list expr $expression]} res]
        if {$code} {
            return -code $code $res
        }
        if {![string is boolean -strict $res]} {
            return -code error "invalid boolean expression: $expression"
        }
        if {$res} {return}
        set msg "assertion failed: [uplevel 1 [list subst $expression]]"
        return -code error $msg
    }
    
    namespace export sleep wait_flush chanObserver duration startNats stopNats startResponder stopResponder assert
}
