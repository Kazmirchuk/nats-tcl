# Copyright (c) 2020-2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# all *.test files source this file first

package require nats  ;# if not found, add it to TCLLIBPATH
package require tcltest 2.5
package require tcl::transform::observe
package require tcl::chan::variable
package require Thread
package require comm
package require lambda

if {$tcl_platform(platform) eq "windows"} {
    package require twapi_process
}

set ::inMsg ""

namespace eval test_utils {
    variable sleepVar 0    
    variable commPort 4221
    variable responderReady 0
    variable natsPid

    # sleep $delay ms in the event loop
    proc sleep {delay} {
        after $delay [list set ::test_utils::sleepVar 1]
        vwait ::test_utils::sleepVar
    }

    proc wait_for {var {timeout 300}} {
        set timer [after $timeout [list set $var "test_utils_timeout"]]
        vwait $var
        if {[set $var] eq "test_utils_timeout"} {
            return -code error "Timeout on $var"
        } else {
            after cancel $timer
        }
        return [set $var]
    }
    
    proc wait_flush {conn} {
        vwait ${conn}::timers(flush) ;# wait until Flusher executes
    }
    
    # [time] returns microseconds, while I need milliseconds
    proc duration {script varName} {
        upvar 1 $varName elapsed
        set now [clock millis]
        # trying to manipulate the error stack to hide duration+uplevel is too much hassle, so just let it propagate
        uplevel 1 $script
        set elapsed [expr {[clock millis] - $now}]
    }
    
    proc sniffer {connection script readVar writtenVar args} {
        nats::_parse_args $args {
            all_lines bool false
            filter_ping bool true
        }
        
        upvar 1 $readVar r_link
        upvar 1 $writtenVar w_link
        upvar 1 ${connection}::sock chanHandle
        
        # tcl::chan::variable can't work with local variables
        # and it requires explicit namespace qualifiers
        set readChan [tcl::chan::variable ::test_utils::readData]
        chan configure $readChan -translation binary
        set writeChan [tcl::chan::variable ::test_utils::writtenData]
        chan configure $writeChan -translation binary
        
        if {$chanHandle eq ""} {
            # the socket hasn't been created yet
            trace add variable ${connection}::sock write [lambda { writeChan readChan var idx op} {
                upvar 1 $var chanHandle
                if {$chanHandle ne ""} {
                    tcl::transform::observe $chanHandle $writeChan $readChan
                }
            } $writeChan $readChan]
        } else {
            tcl::transform::observe $chanHandle $writeChan $readChan
        }
        try {
            uplevel 1 $script
        } finally {
            if {[chan names $chanHandle] ne ""} {
                # if the socket hasn't been closed yet, remove the transformation
                chan pop $chanHandle
            }
            close $writeChan
            close $readChan
            foreach traceInfo [trace info variable ${connection}::sock] {
                # remove our trace, if any
                lassign $traceInfo op cmd
                if {$op eq "write"} {
                    trace remove variable ${connection}::sock write $cmd
                }
            }
            set r_link $::test_utils::readData
            set w_link $::test_utils::writtenData
            unset ::test_utils::readData
            unset ::test_utils::writtenData
        }
        set r_link [snifferBinToList $r_link $all_lines $filter_ping]
        set w_link [snifferBinToList $w_link $all_lines $filter_ping]
        return
    }
        
    # private proc: convert raw data sent through socket into a list of NATS protocol tokens
    proc snifferBinToList {binData all_lines filter_ping} {
        # NATS uses \r\n as a protocol delimiter
        # [split] supports splitting only by a single character, so at first replace \r\n with plain \n
        # and since binData ends with \r\n, resulting list will have 1 empty element in the end - discard it
        set result [lrange [split [string map {\r\n \n} $binData] \n] 0 end-1]
        #set result [string map {\r\n \n} $binData]
        if {$filter_ping} {
            # usually we are not interested in PING/PONG
            set result [lmap e $result {
                if {$e eq "PING" || $e eq "PONG"} {
                    continue
                }
                set e
            }]
        }
        if {$all_lines} {
            return $result
        }
        # usually we are interested only in the first line of sniffed data
        return [lindex $result 0]
    }
    proc getConnectOpts {data} {
        set pos [string first " " $data] ;# skip CONNECT straight to the beginning of JSON
        return [json::json2dict [string range $data $pos+1 end]]
    }
    # WARNING: debug logging must be off when running under Tcl debugger, otherwise the debugger bugs out
    proc debugLogging {conn} {
        # available logger severity levels: debug info notice warn error critical alert emergency
        # default is "warn"
        [$conn logger]::setlevel debug
        trace add variable ${conn}::status write [lambda {var idx op } {
            upvar 1 $var s
            puts "[nats::_timestamp] New status: $s"
        }]
        trace add variable ${conn}::subscriptions write [lambda {var idx op } {
            upvar 1 ${var}($idx) s
            puts "[nats::_timestamp] sub($idx): $s"
        }]
        trace add variable ${conn}::subscriptions unset [lambda {var idx op } {
            puts "[nats::_timestamp] sub($idx) unset"
        }]
        trace add variable ${conn}::requests write [lambda {var idx op } {
            upvar 1 ${var}($idx) r
            puts "[nats::_timestamp] req($idx): $r"
        }]
        trace add variable ${conn}::requests unset [lambda {var idx op } {
            puts "[nats::_timestamp] req($idx) unset"
        }]
    }
    
    proc subCallback {subj msg reply} {
        set ::inMsg $msg
    }

    proc asyncReqCallback {timedOut msg} {
        if {$timedOut} {
            set ::inMsg "timeout"
        } else {
            set ::inMsg $msg
        }
    }

    # start NATS server in the background unless it is already running; it must be available in $PATH
    proc startNats {id args} {
        if {![needStartNats $args]} {
            return
        }
        variable natsPid
        # tcltest -singleproc 0 considers stderr from NATS as a test failure; we don't need these logs, so just send them to /dev/null
        # Tcllib's processman package doesn't offer much value
        if {$::tcl_platform(platform) eq "windows"} {
            set natsPid($id) [exec nats-server.exe {*}$args 2> NUL &]
        } else {
            set natsPid($id) [exec nats-server {*}$args 2> /dev/null &]
        }
        sleep 500 
        puts "[nats::_timestamp] Started $id"
    }
    
    proc stopNats {id} {
        variable natsPid
        if {![info exists natsPid($id)]} {
            return
        }
        if {$::tcl_platform(platform) eq "windows"} {
            # Note: this is NOT a graceful shutdown - that is possible with Ctrl+C in the NATS console
            # I tried nats-server.exe --signal stop=PID, but it requires NATS to run as a Windows service
            twapi::end_process $natsPid($id)
        } else {
            exec kill $natsPid($id)
            
        }
        unset natsPid($id)
        after 500
        puts "[nats::_timestamp] Stopped $id"
    }

    proc needStartNats {natsArgs} {
        if {[llength $natsArgs]} {
            return 1;# always start a "custom" NATS
        }
        if {$::tcl_platform(platform) eq "windows"} {
            set count [llength [twapi::get_process_ids -name nats-server.exe]]
        } else {
            try {
                set count [exec pgrep --exact --count nats-server]
            } trap {CHILDSTATUS} {err opts} {
                set count 0 ;# somewhat inconvenient that pgrep exits with $?=1 when nothing matched
            }
        }
        return [expr {!$count}] ;# useful for troubleshooting: allow manually started nats-server -DV
    }
    
    proc execNatsCmd {args} {
        set output [exec -ignorestderr nats {*}$args]
        puts "[nats::_timestamp] Executed: nats $args"
        return $output
    }
    
    proc startResponder {conn {subj "service"} {queue ""} {dictMsg 0}} {
        $conn subscribe "$subj.ready" -max_msgs 1 -callback [lambda {subject message replyTo} {
            set test_utils::responderReady 1
        }]
        exec [info nameofexecutable] responder.tcl $subj $queue $dictMsg &
        wait_for test_utils::responderReady 1000
    }
    
    # send a NATS message to stop the responder gracefully; remember to "sleep" a bit after calling this function!
    proc stopResponder {conn {subj "service"}} {
        $conn publish $subj [list 0 exit]
        wait_flush $conn
    }
    
    # comm ID (port) is hard-coded to 4223
    proc startFakeServer {} {
        set scriptPath [file join [file dirname [info script]] fake_server.tcl]
        exec [info nameofexecutable] $scriptPath &
        sleep 500
    }
    
    proc stopFakeServer {} {
        variable commPort
        comm::comm send -async $commPort quit
        sleep 500 ;# make sure it exits before starting a new fake or real NATS server
    }
    
    proc sendFakeServer {data} {
        variable commPort
        comm::comm send $commPort $data
    }
    
    # control:assert is garbage and doesn't perform substitution on failed expressions, so I can't even know a value of offending variable etc
    # if assert is used in a callback and fails, it will not be reported as a failed test, because it runs in the global scope
    # so it must always be followed by a change to a variable that is then checked/vwaited in the test itself
    proc assert {expression { subst_commands 0} } {
        set code [catch {uplevel 1 [list expr $expression]} res]
        if {$code} {
            return -code $code $res
        }
        if {![string is boolean -strict $res]} {
            return -code error "invalid boolean expression: $expression"
        }
        if {$res} return
        if {$subst_commands} {
            # useful for [binary encode hex] or [string length] etc
            set msg "assertion failed: [uplevel 1 [list subst $expression]]"
        } else {
            # -nocommands is useful when using [approx]
            set msg "assertion failed: [uplevel 1 [list subst -nocommands $expression]]"
        }
        return -code error $msg
    }
    
    #check that actual == ref within certain tolerance - useful for timers/duration
    proc approx {actual ref {tolerance 50}} {
        return [expr {$actual > ($ref - $tolerance) && $actual < ($ref + $tolerance)}]
    }
    
    # check that dict1 is a subset of dict2, with the same values
    proc dict_in {dict1 dict2} {
        dict for {k v} $dict1 {
            if {[dict exists $dict2 $k] && [dict get $dict2 $k] == $v} {
                continue
            } else {
                return false
            }
        }
        return true
    }
    
    namespace export sleep wait_for wait_flush sniffer duration startNats stopNats startResponder stopResponder startFakeServer stopFakeServer sendFakeServer \
                     assert approx getConnectOpts debugLogging subCallback asyncReqCallback execNatsCmd dict_in
}

namespace import ::tcltest::test
namespace import test_utils::*

# execution continues in a *.test file... no need to call tcltest::configure there again
