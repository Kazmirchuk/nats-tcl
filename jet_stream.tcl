namespace eval ::nats {}
package require json

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
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        if {![${conn}::my CheckSubject $consumer]} {
            throw {NATS ErrInvalidArg} "Invalid consumer name $consumer"
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
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
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

            set consumes($reqID) [list 0]
            ${conn}::my CoroVwait [self object]::consumes($reqID)
            lassign $consumes($reqID) ignored timedOut response
            unset consumes($reqID)
            if {$timedOut} {
                throw {NATS ErrTimeout} "Consume $stream.$consumer timed out"
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

    method publish {subject message args} {
        set newOpts [dict create]
        foreach {opt val} $args {
            switch -- $opt {
                -callback {
                    dict set newOpts -callback [mymethod PublishCallback $val]
                }
                default {
                    dict set newOpts $opt $val
                }
            }
        }

        set result [$conn request $subject $message {*}$newOpts]
        if {[dict exists $newOpts -callback]} {
            return
        }
        
        # can throw nats server error
        set dictResponse [my ParsePublishResponse $result]
        return $dictResponse
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

    method PublishCallback {originalCallback timedOut result} {
        if {$timedOut} {
            after 0 [list {*}$originalCallback 1 {} {}]
            return
        }

        try {
            set dictResponse [my ParsePublishResponse $result]
        } trap {NATS ErrResponse} {msg opt} {
            set errorCode [lindex [dict get $opt -errorcode] end]
            after 0 [list {*}$originalCallback 0 {} [dict create type $errorCode error $msg]]
            return
        } on error {msg opt} {
            ${logger}::error "Error while parsing jet stream publish callback: $msg"
            return
        }
        after 0 [list {*}$originalCallback 0 $dictResponse {}]
    }

    method ParsePublishResponse {response} {
        if {[catch {
            set responseDict [::json::json2dict $response]
        } err]} {
            throw [list NATS ErrResponse ErrParsing] "Cannot parse server response ($response): $err"
            return
        }
        if {[dict exists $responseDict error] && [dict exists $responseDict type]} {
            throw [list NATS ErrResponse [dict get $responseDict type]] [dict get $responseDict error]
            return
        }

        return $responseDict
    }
}
