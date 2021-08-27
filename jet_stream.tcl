namespace eval ::nats {}

oo::class create ::nats::jet_stream {
    variable conn consumerInboxPrefix logger consumes counters
    
    constructor {c} {
        set conn $c
        array set consumes {} 
        array set counters {consumes 10} 
        set consumerInboxPrefix ""
        set logger [$conn logger]
    }

    destructor {
    }

    method disconnect {} {
        array unset consumes
        set consumerInboxPrefix ""
    }
    
    method consume {stream consumer args} {
        if {![${conn}::my CheckSubject $stream]} {
            throw {NATS INVALID_ARG} "Invalid stream name $stream"
        }
        if {![${conn}::my CheckSubject $consumer]} {
            throw {NATS INVALID_ARG} "Invalid consumer name $consumer"
        }

        set subject "\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer"
        set batch 1 ;# get only one message at time from consumer
        set timeout -1 ;# ms
        set callback ""
        
        foreach {opt val} $args {
            switch -- $opt {
                -timeout {
                    ${conn}::my CheckTimeout $val
                    set timeout $val
                }
                -callback {
                    set callback $val
                }
                default {
                    throw {NATS INVALID_ARG} "Unknown option $opt"
                }
            }
        }
        
        if {$callback ne "" && $timeout != -1} {
            if {[$conn cget flush_interval] >= $timeout} {
                throw {NATS INVALID_ARG} "Wrong timeout: async requests need at least flush_interval ms to complete"
            }
        }
        
        set reqID [incr counters(consumes)]
        if {$consumerInboxPrefix eq ""} {
            set consumerInboxPrefix [$conn inbox]
        }
        $conn subscribe "$consumerInboxPrefix.$reqID" -callback [mymethod ConsumeCallback $reqID] -max_msgs $batch
        
        set timerID ""
        $conn publish $subject $batch "$consumerInboxPrefix.$reqID"
        if {$callback eq ""} {
            # sync request
            if {$timeout != -1} {
                 set timerID [after $timeout [list set [self object]::consumes($reqID) [list 0 1 ""]]]
            }

            ${conn}::my Flusher 0
            set consumes($reqID) [list 0]
            ${conn}::my CoroVwait [self object]::consumes($reqID)
            lassign $consumes($reqID) ignored timedOut response
            unset consumes($reqID)
            if {$timedOut} {
                throw {NATS TIMEOUT} "Consume $stream.$consumer timed out"
            }
            after cancel $timerID
            return $response
        }
        # async request
        if {$timeout != -1} {
            set timerID [after $timeout [mymethod ConsumeCallback $reqID "" "" "" $reqID]]
        }
        set consumes($reqID) [list 1 $timerID $callback]
        return
    }

    method ack {ackAddr} {
        $conn publish $ackAddr {}
    }

    method ConsumeCallback {reqID subj msg reply {reqID_timeout 0}} {
        if {$reqID_timeout != 0} {
            #async request timed out
            lassign $consumes($reqID_timeout) ignored timerID callback
            after 0 [list {*}$callback 1 "" ""]
            unset consumes($reqID_timeout)
            return
        }
        # we received a NATS message
        if {![info exists consumes($reqID)]} {
            ${logger}::debug "ConsumeCallback got [string range $msg 0 15] on reqID $reqID - discarded"
            return
        }
        lassign $consumes($reqID) reqType timer callback
        if {$reqType == 0} {
            # resume from vwait in "method consume"; "consumes" array will be cleaned up there
            set consumes($reqID) [list 0 0 [list $msg $reply]]
            return
        }
        after cancel $timer
        after 0 [list {*}$callback 0 $msg $reply]
        unset consumes($reqID)
    }
}
