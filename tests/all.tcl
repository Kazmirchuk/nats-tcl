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

package require tcltest
package require tcl::transform::observe
package require tcl::chan::variable

namespace eval test_utils {
    variable sleepVar ""
    
    variable writingObs
    variable readingObs
    variable obsMode
    variable readChan
    variable writeChan
    variable observedSock
    
    variable natsConn ""
    
    # sleep $delay ms in the event loop
    proc sleep {delay} {
        after $delay [list set ::test_utils::sleepVar 1]
        vwait ::test_utils::sleepVar
    }
    
    # $mode can be r (read), w (write), b (both)
    proc setupChanObserver { sock mode } {
        variable writingObs ""
        variable readingObs ""
        variable obsMode $mode
        variable readChan ""
        variable writeChan ""
        variable observedSock $sock
        
        switch -- $obsMode {
            r {
                set readChan [tcl::chan::variable ::test_utils::readingObs]
                tcl::transform::observe $sock {} $readChan
            }
            w {
                set writeChan [tcl::chan::variable ::test_utils::writingObs]
                tcl::transform::observe $sock $writeChan {}
            }
            b {
                set readChan [tcl::chan::variable ::test_utils::readingObs]
                set writeChan [tcl::chan::variable ::test_utils::writingObs]
                tcl::transform::observe $sock $writeChan $readChan
            }
        }
    }
    
    proc getChanData { {firstLine 1} } {
        variable writingObs
        variable readingObs
        variable obsMode
        variable readChan
        variable writeChan
        variable observedSock
        
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
        set writingObs [string map {\r {}} $writingObs]
        set readingObs [string map {\r {}} $readingObs]
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
    
    # a dummy service that after receiving a message waits for the specified time (ms) and then replies "42"
    proc startResponder {subject} {
        variable natsConn
        set natsConn [nats::connection new]
        $natsConn configure -servers nats://localhost:4222
        $natsConn connect
        $natsConn subscribe $subject [namespace current]::respond
    }
    proc respond {subj msg reply sid} {
        variable natsConn
        if {$msg != 0} {
            sleep $msg
        }
        $natsConn publish $reply 42
    }
    proc stopResponder {} {
        variable natsConn
        $natsConn destroy
    }
}

# by default tcltest will exit with 0 even if some tests failed
proc tcltest::cleanupTestsHook {} {
    variable numTests
    set ::exitCode [expr {$numTests(Failed) > 0}]
}

tcltest::configure -testdir [file dirname [file normalize [info script]]] -singleproc 1
tcltest::configure {*}$argv
tcltest::runAllTests

exit $exitCode
