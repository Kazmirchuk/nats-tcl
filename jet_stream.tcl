# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require json

namespace eval ::nats {}

oo::class create ::nats::jet_stream {
    variable conn
    
    constructor {c} {
        set conn $c
    }

    method consume {stream consumer args} {
        if {![${conn}::my CheckSubject $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        if {![${conn}::my CheckSubject $consumer]} {
            throw {NATS ErrInvalidArg} "Invalid consumer name $consumer"
        }

        set subject "\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer"
        set batch_size 1 ;# by default, get only one message at a time from a consumer
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
                -batch_size {
                    set batch_size $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {$batch_size > 1 && $callback eq ""} {
            throw {NATS ErrInvalidArg} "batch_size > 1 can be done only with an async consumer"
        }
        try {
            return [$conn request $subject $batch_size -dictmsg true -timeout $timeout -callback $callback -max_msgs $batch_size]
        } trap {NATS ErrTimeout} err {
            throw {NATS ErrTimeout} "Consume $stream.$consumer timed out"
        }
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

    method PublishCallback {userCallback timedOut result} {
        if {$timedOut} {
            after 0 [list {*}$userCallback 1 "" ""]
            return
        }

        try {
            set pubAckResponse [my ParsePublishResponse $result]
            after 0 [list {*}$userCallback 0 $pubAckResponse ""]
        } trap {NATS ErrJSResponse} {msg opt} {
            # make a dict with the same structure as AsyncError
            # but the error code should be the same as reported in JSON, so remove "NATS ErrJSResponse" from it
            set errorCode [lindex [dict get $opt -errorcode] end]
            after 0 [list {*}$userCallback 0 "" [dict create code $errorCode errorMessage $msg]]
        } on error {msg opt} {
            [$conn logger]::error "Error while parsing JetStream response: $msg"
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
            throw [list NATS ErrJSResponse [dict get $errDict code]] [dict get $errDict description]
        }
        return $responseDict
    }
}
