# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require json

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
                    nats::check_timeout $val
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
        $conn subscribe "$consumerInboxPrefix.$reqID" -callback [mymethod ConsumeCallback $reqID] -max_msgs $batch -dictmsg true
        
        set timerID ""
        $conn publish $subject $batch -reply "$consumerInboxPrefix.$reqID"
        if {$callback eq ""} {
            # sync request
            if {$timeout != -1} {
                 set timerID [after $timeout [list set [self object]::consumes($reqID) [list 0 1 ""]]]
            }
            set consumes($reqID) 0
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

    method ack {message} {
        $conn publish [dict get $message reply] ""
    }

    method publish {subject message args} {
        set opts [dict create {*}$args]
        set userCallback ""
        if {[dict exists $opts "-callback"]} {
            # we need to pass our own callback to "request"; other options are passed untouched
            set userCallback [dict get $opts "-callback"]
            dict set opts -callback [mymethod PublishCallback $userCallback]
        }
        
        # note: nats.go replaces ErrNoResponders with ErrNoStreamResponse, but I don't see much value in it
        set result [$conn request $subject $message {*}$opts -dictmsg true]

        if {$userCallback ne ""} {
            return
        }
        
        # can throw nats server error
        return [my ParsePublishResponse $result]
    }

    method ConsumeCallback {reqID subj msg reply {reqID_timeout 0}} {
        if {$reqID_timeout != 0} {
            #async request timed out
            lassign $consumes($reqID_timeout) ignored timerID callback
            after 0 [list {*}$callback 1 ""]
            unset consumes($reqID_timeout)
            return
        }
        # we received a NATS message
        if {![info exists consumes($reqID)]} {
            #${logger}::debug "ConsumeCallback got [string range $msg 0 15] on reqID $reqID - discarded"
            return
        }
        lassign $consumes($reqID) reqType timer callback
        if {$reqType == 0} {
            # resume from vwait in "method consume"; "consumes" array will be cleaned up there
            set consumes($reqID) [list 0 0 $msg]
            return
        }
        after cancel $timer
        after 0 [list {*}$callback 0 $msg]
        unset consumes($reqID)
    }
    
    method PublishCallback {userCallback timedOut result} {
        if {$timedOut} {
            after 0 [list {*}$userCallback 1 "" ""]
            return
        }

        try {
            set pubAckResponse [my ParsePublishResponse $result]
            after 0 [list {*}$userCallback 0 $pubAckResponse ""]
        } trap {NATS ErrResponse} {msg opt} {
            set errorCode [lindex [dict get $opt -errorcode] end]
            # make a dict with the same structure as AsyncError
            after 0 [list {*}$userCallback 0 "" [dict create code $errorCode message $msg]]
        } on error {msg opt} {
            ${logger}::error "Error while parsing jet stream publish callback: $msg"
        }
    }

    method ParsePublishResponse {response} {
        # $response is a dict here
        try {
            set responseDict [::json::json2dict [dict get $response data]]
        } trap JSON err {
            throw {NATS ErrInvalidJSAck} "JSON parsing error $err\n while parsing the stream response: $response"
        }
        # https://docs.nats.io/jetstream/nats_api_reference#error-handling
        # looks like nats.go doesn't have a specific error type for this? see func (js *js) PublishMsg
        # should I do anything with err_code?
        if {[dict exists $responseDict error]} {
            set errDict [dict get $responseDict error]
            throw [list NATS ErrResponse [dict get $errDict code]] [dict get $errDict description]
        }
        return $responseDict
    }
}
