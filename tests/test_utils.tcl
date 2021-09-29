# Copyright (c) 2020-2021 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require tcl::transform::observe
package require tcl::chan::variable
package require processman
package require oo::util
package require control
package require comm
package require lambda

namespace eval test_utils {
    variable sleepVar 0
    variable simpleMsg ""
    variable commPort 4221
    variable responderReady 0
    
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
        variable writeChan readChan ;# channels for sniffed data
        variable writingObs readingObs ;# variables backing the channels - reset when a socket is re-created
        variable writtenData readData ;# all data is accumulated here
        variable obsMode conn sock
        # $mode can be r (read), w (write), b (both)
        constructor {nats_conn mode} {
            set conn $nats_conn
            set obsMode $mode
            set readChan ""
            set writeChan ""
            set sock [set ${conn}::sock]
            if { $sock ne ""} {
                # the socket already exists - start monitoring it now
                my TraceCmd ${conn}::sock ignored ignored
            }
            trace add variable ${conn}::sock write [mymethod TraceCmd]
        }
        
        destructor {
            trace remove variable ${conn}::sock write [mymethod TraceCmd]
        }
        
        method TraceCmd  {var idx op } {
            upvar $var s
            if {$s ne ""} {
                # new socket was created - start monitoring it
                set sock $s
                set readingObs ""
                set writingObs ""
                switch -- $obsMode {
                    r {
                        set readChan [tcl::chan::variable [self object]::readingObs]
                        tcl::transform::observe $s {} $readChan
                    }
                    w {
                        set writeChan [tcl::chan::variable [self object]::writingObs]
                        tcl::transform::observe $s $writeChan {}
                    }
                    b {
                        set readChan [tcl::chan::variable [self object]::readingObs]
                        set writeChan [tcl::chan::variable [self object]::writingObs]
                        tcl::transform::observe $s $writeChan $readChan
                    }
                }
            } else {
                # the socket was closed - copy the sniffed data
                my Finalize
            }
        }

        method Finalize {} {
            # really important! remove the transformation
            if {$sock ne ""} {
                catch {chan pop $sock}
                set sock ""
            }
            if {$readChan ne ""} {
                close $readChan
                set readChan ""
                append readData $readingObs
                set readingObs ""
            }
            if {$writeChan ne ""} {
                close $writeChan
                set writeChan ""
                append writtenData $writingObs
                set writingObs ""
            }
        }
        
        method getChanData { {firstLine 1} {filterPing 1}} {
            # in case the socket is still open
            my Finalize
            switch -- $obsMode {
                r {
                    set varList "readData"
                }
                w {
                    set varList "writtenData"
                }
                b {
                    set varList [list readData writtenData]
                }
            }
            foreach v $varList {
                upvar 0 $v chanData
                # these variables contain \r\r\n in each line, and I couldn't get rid of them with chan configure -translation
                set chanData [string map {\r {} } $chanData]
                if {$filterPing} {
                    # usually we are not interested in PING/PONG
                    set chanData [string map {PING\n {} PONG\n {} } $chanData]
                }
                set chanData [split $chanData \n]
                if {$firstLine} {
                    # we are interested only in the first line of sniffed data
                    set chanData [lindex $chanData 0]
                }
            }
            switch -- $obsMode {
                r {
                    return $readData
                }
                w {
                    return $writtenData
                }
                b {
                    return [list $readData $writtenData]
                }
            }
        }
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
            upvar $var s
            puts "[nats::timestamp] New status: $s"
        }]
        trace add variable ${conn}::last_error write [lambda {var idx op } {
            upvar $var e
            if {$e ne ""} {
                puts "[nats::timestamp] Async error: $e"
            }
        }]
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
        puts "[nats::timestamp] Started $id"
    }
    
    proc stopNats {id} {
        if {$::tcl_platform(platform) eq "windows"} {
            processman::kill $id
        } else {
            # processman::kill on Linux relies on odielib or Tclx packages that might not be available
            set pid [processman::running $id]
            if {$pid == 0} {
                return
            }
            catch {exec kill $pid}
            after 500
        }
        puts "[nats::timestamp] Stopped $id"
    }

    proc execNatsCmd {args} {
        exec -ignorestderr nats {*}$args
        puts "[nats::timestamp] Executed: nats $args"
    }
    
    proc startResponder {conn {subj "service"} {queue ""} {dictMsg 0}} {
        variable responderReady
        $conn subscribe "$subj.ready" -max_msgs 1 -callback [lambda {subject message replyTo} {
            set test_utils::responderReady 1
        }]
        set scriptPath [file join [file dirname [info script]] responder.tcl]
        exec [info nameofexecutable] $scriptPath $subj $queue $dictMsg &
        wait_for test_utils::responderReady 1000
    }
    
    # processman::kill doesn't work reliably with tclsh, so instead we send a NATS message to stop the responder gracefully
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
    proc assert {expression { subst_commands 0} } {
        set code [catch {uplevel 1 [list expr $expression]} res]
        if {$code} {
            return -code $code $res
        }
        if {![string is boolean -strict $res]} {
            return -code error "invalid boolean expression: $expression"
        }
        if {$res} {return}
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
    
    namespace export sleep wait_for wait_flush chanObserver duration startNats stopNats startResponder stopResponder startFakeServer stopFakeServer sendFakeServer \
                     assert approx getConnectOpts debugLogging execNatsCmd
}
