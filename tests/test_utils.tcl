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
package require lambda
package require logger::utils

if {$tcl_platform(platform) eq "windows"} {
    package require twapi_process
}

set ::inMsg ""

namespace eval test_utils {
    variable sleepVar 0
    variable natsPid
    
    logger::initNamespace [namespace current] info
    set appenderArgs [list -outputChannel [tcltest::outputChannel]]
    # format the messages in the same manner as nats::connection
    lappend appenderArgs -conversionPattern {\[[nats::timestamp] %c %p\] %m}
    logger::utils::applyAppender -appender fileAppend -service test_utils -appenderArgs $appenderArgs
    unset appenderArgs
    
    # sleep $delay ms in the event loop
    proc sleep {delay} {
        after $delay {set ::test_utils::sleepVar 1}
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
                # workaround for this bug https://core.tcl-lang.org/tcl/tktview/ea69b0258a9833cb61ada42d1fc742d90aec04d0
                update
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
        set r_link [SnifferBinToList $r_link $all_lines $filter_ping]
        set w_link [SnifferBinToList $w_link $all_lines $filter_ping]
        return
    }
        
    # private proc: convert raw data sent through socket into a list of NATS protocol tokens
    proc SnifferBinToList {binData all_lines filter_ping} {
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
        if {$id eq "NATS"} {
            if {![NeedStartNats $args]} {
                return
            }
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
        log::info "Started $id"
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
        after 500 ;# deliberately don't process events
        log::info "Stopped $id"
    }
    # suitable only for tests that start only one NATS instance
    proc NeedStartNats {natsArgs} {
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
        # turn off logging - key-value tests use it heavily
        # log::info "Executed: nats $args"
        return $output
    }
    
    oo::class create responder {
        variable responderThread
        variable id
        
        constructor {args} {
            nats::_parse_args $args {
                id valid_str ""
                subject valid_str service
                queue valid_str ""
                servers valid_str ""
            }
            if {$id eq ""} {
                set id [namespace tail [self object]]
            }

            set thread_script {
                source responder.tcl
                thread::wait
                responder::shutdown
            }
            
            set responderThread [thread::create -joinable -preserved $thread_script]
            # return value of thread::send is the same as [catch]
            if {[thread::send $responderThread [list responder::init $id $subject $queue $servers] result] == 1} {
                error "Failed to initialise responder $id: $result"
            }
            set log_msg "Responder $id listening on $subject"
            if {$queue ne ""} {
                append log_msg " queue: $queue"
            }
            [logger::servicecmd test_utils]::info $log_msg
            # no need in thread::errorproc - if there's an unexpected error in the thread, it will be logged to stderr by itself
        }
        
        destructor {
            thread::release $responderThread ;# makes the thread return from thread::wait
            thread::join $responderThread
            [logger::servicecmd test_utils]::info "Responder $id finished"
        }
    }
    
    proc stopAllResponders {} {
        foreach r [info class instances ::test_utils::responder] {
            $r destroy
        }
    }

    # control::assert is garbage and doesn't perform substitution on failed expressions, so I can't even know a value of offending variable etc
    # if assert is used in a callback and fails, it will not be reported as a failed test, because it runs in the global scope
    # so it must always be followed by a change to a variable that is then checked/vwaited in the test itself
    proc assert {expression { subst_commands 0} } {
        set res [uplevel 1 [list expr $expression]]
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
    
    namespace export {[a-z]*}
}

namespace import ::tcltest::test
namespace import test_utils::*

# execution continues in a *.test file... no need to call tcltest::configure there again
