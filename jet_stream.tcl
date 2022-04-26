# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

namespace eval ::nats {}

oo::class create ::nats::jet_stream {
    variable conn
    
    constructor {c} {
        set conn $c
    }

    ### MESSAGES ###

    method stream_msg_get {stream args} {
        set subject "\$JS.API.STREAM.MSG.GET.$stream"

        set containSeq [dict exists $args "-seq"]
        set containLastBySubj [dict exists $args "-last_by_subj"]
        if {($containSeq && $containLastBySubj) || (!$containSeq && !$containLastBySubj)} {
            # XOR: exacly one of this option should be provided
            throw {NATS ErrInvalidArg} "Options should contain -seq or -last_by_subj"
        }

        set msg {}
        set common_arguments [dict create]
        
        foreach {opt val} $args {
            switch -- $opt {
                -last_by_subj {
                    set msg [::nats::json_write_object "last_by_subj" [json::write::string $val]]
                }
                -seq {
                    set msg [::nats::json_write_object "seq" $val]
                }
                default {
                    if {$opt ni [list -timeout -callback]} {
                        throw {NATS ErrInvalidArg} "Unknown option $opt"
                    }
                    dict set common_arguments $opt $val
                }
            }
        }

        return [my SimpleRequest $subject $common_arguments "Getting message from stream $stream timed out" $msg]
    }

    method stream_msg_delete {stream args} {
        set subject "\$JS.API.STREAM.MSG.DELETE.$stream"

        if {![dict exists $args "-seq"]} {
            throw {NATS ErrInvalidArg} "Options should contain -seq"
        }

        set msg {}
        set common_arguments [dict create]
        
        foreach {opt val} $args {
            switch -- $opt {
                -seq {
                    set msg [::nats::json_write_object "seq" $val]
                }
                default {
                    if {$opt ni [list -timeout -callback]} {
                        throw {NATS ErrInvalidArg} "Unknown option $opt"
                    }
                    dict set common_arguments $opt $val
                }
            }
        }

        return [my SimpleRequest $subject $common_arguments "Deleting message from stream $stream timed out" $msg]
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
        set config_dict [dict create]
        set additonal_args [list]
        
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
                    dict set config_dict batch $batch_size
                }
                -expires -
                -idle_heartbeat {
                    set opt_raw [string range $opt 1 end] ;# remove flag
                    # duration args - provided in milliseconds should be formatted to nanoseconds 
                    if {![string is double -strict $val]} {
                        throw {NATS ErrInvalidArg} "Wrong duration value for argument $opt_raw it must be in milliseconds"
                    }
                    set val [expr {entier($val*1000*1000)}] ;#conversion milliseconds to nanoseconds

                    dict set config_dict $opt_raw $val
                }
                -no_wait {
                    if {![string is boolean $val]} {
                        throw {NATS ErrInvalidArg} "Argument no_wait should be boolean"
                    }
                    if {$val} {
                        dict set config_dict no_wait true
                    } else {
                        dict set config_dict no_wait false
                    }
                }
                -custom_reqID {
                    lappend additonal_args -custom_reqID $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"
                }
            }
        }
        
        if {$batch_size > 1 && $callback eq ""} {
            throw {NATS ErrInvalidArg} "batch_size > 1 can be done only with an async consumer"
        }

        if {[dict size $config_dict] == 0} {
            set message $batch_size
        } else {
            set message [::nats::json_write_object {*}$config_dict]
        }

        try {
            return [$conn request $subject $message -dictmsg true -timeout $timeout -callback $callback -max_msgs $batch_size {*}$additonal_args]
        } trap {NATS ErrTimeout} err {
            throw {NATS ErrTimeout} "Consume $stream.$consumer timed out"
        }
    }

    # Ack acknowledges a message. This tells the server that the message was
    # successfully processed and it can move on to the next message.
    method ack {message} {
        $conn publish [dict get $message reply] ""
    }

    # Nak negatively acknowledges a message. This tells the server to redeliver
    # the message. You can configure the number of redeliveries by passing
    # nats.MaxDeliver when you Subscribe. The default is infinite redeliveries.
    method nak {message} {
        $conn publish [dict get $message reply] "-NAK"
    }

    # Term tells the server to not redeliver this message, regardless of the value
    # of nats.MaxDeliver.
    method term {message} {
        $conn publish [dict get $message reply] "+TERM"
    }

    # InProgress tells the server that this message is being worked on. It resets
    # the redelivery timer on the server.
    method in_progress {message} {
        $conn publish [dict get $message reply] "+WPI"
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

    ### CONSUMERS ###

    method add_consumer {stream args} {
        if {![${conn}::my CheckSubject $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }

        set common_arguments [dict create]
        set config_dict [dict create] ;# variable with formatted arguments

        # supported arguments
        set arguments_list [list description deliver_group deliver_policy opt_start_seq \
            opt_start_time ack_policy ack_wait max_deliver filter_subject replay_policy \
            rate_limit_bps sample_freq max_waiting max_ack_pending idle_heartbeat flow_control \
            deliver_subject durable_name]


        foreach {opt val} $args {
            switch -- $opt {
                -durable_name {
                    if {![${conn}::my CheckSubject $val]} {
                        throw {NATS ErrInvalidArg} "Invalid durable consumer name $val"
                    }

                    dict set config_dict durable_name $val
                    set durable_consumer_name $val
                }
                -flow_control {       
                    # flow control must be boolean          
                    if {![string is boolean $val]} {
                        throw {NATS ErrInvalidArg} "Argument flow_control should be boolean"
                    }
                    if {$val} {
                        dict set config_dict flow_control true
                    } else {
                        dict set config_dict flow_control false
                    }
                }
                -replay_policy {
                    # only values: instant/original are supported
                    if {$val ni [list instant original]} {
                        throw {NATS ErrInvalidArg} "Wrong replay_policy value, must be: instant or original"
                    }
                    dict set config_dict replay_policy $val
                }
                -ack_policy {
                    # only values: none/all/explicit are supported
                    if {$val ni [list none all explicit]} {
                        throw {NATS ErrInvalidArg} "Wrong ack_policy value, must be: none, all or explicit"
                    }
                    dict set config_dict ack_policy $val
                }                
                -callback {
                    # receive status of adding consumer on callback proc
                    set callback [mymethod PublishCallback $val]
                }
                -timeout {
                    nats::check_timeout $val
                    set timeout $val
                }
                default {
                    if {$opt in [list -callback -timeout]} {
                        dict set common_arguments $opt $val
                        continue
                    }
                    set opt_raw [string range $opt 1 end] ;# remove flag
                    # duration args - provided in milliseconds should be formatted to nanoseconds 
                    if {$opt_raw in [list "idle_heartbeat" "ack_wait"]} {
                        if {![string is double -strict $val]} {
                            throw {NATS ErrInvalidArg} "Wrong duration value for argument $opt_raw it must be in milliseconds"
                        }
                        set val [expr {entier($val*1000*1000)}] ;#conversion milliseconds to nanoseconds
                    }
                    
                    # checking if all provided arguments are valid
                    if {$opt_raw ni $arguments_list} {
                        throw {NATS ErrInvalidArg} "Unknown option $opt"
                    } else {
                        dict set config_dict $opt_raw $val
                    }                    
                }
            }
        }

        # pull/push consumers validation
        if {[dict exists $config_dict deliver_subject]} {
            # push consumer
            foreach forbidden_arg [list max_waiting] {
                if {[dict exists $config_dict $forbidden_arg]} {
                    throw {NATS ErrInvalidArg} "Argument $forbidden_arg is forbbiden for push consumer"
                }
            }
        } else {
            # pull consumer
            foreach forbidden_arg [list idle_heartbeat flow_control] {
                if {[dict exists $config_dict $forbidden_arg]} {
                    throw {NATS ErrInvalidArg} "Argument $forbidden_arg is forbbiden for pull consumer"
                }
            }            
        }

        # string arguments need to be within quotation marks ""
        dict for {key value} $config_dict {
            if {![string is boolean -strict $value] && ![string is double -strict $value]} {
                dict set config_dict $key [json::write::string $value]
            }            
        }
        
        # create durable or ephemeral consumers
        if {[info exists durable_consumer_name]} {
            set subject "\$JS.API.CONSUMER.DURABLE.CREATE.$stream.$durable_consumer_name"
            set settings_json [::nats::json_write_object \
                stream_name [json::write::string $stream] \
                name [json::write::string $durable_consumer_name] \
                config [::nats::json_write_object {*}$config_dict] \
            ]
        } else {
            set subject "\$JS.API.CONSUMER.CREATE.$stream"
            set settings_json [::nats::json_write_object \
                stream_name [json::write::string $stream] \
                config [::nats::json_write_object {*}$config_dict] \
            ]
        }

        return [my SimpleRequest $subject $common_arguments "Creating consumer for $stream timed out" $settings_json]                
    }

    method delete_consumer {stream consumer args} {
        set subject "\$JS.API.CONSUMER.DELETE.$stream.$consumer"
        return [my SimpleRequest $subject $args "Deleting consumer $stream $consumer timed out"]         
    }

    method consumer_info {stream {consumer ""} args} {
        if {$consumer eq ""} {
            set subject "\$JS.API.CONSUMER.LIST.$stream"
            set timeout_message "Getting consumer list from $stream timed out"
        } else {
            set subject "\$JS.API.CONSUMER.INFO.$stream.$consumer"
            set timeout_message "Getting consumer info from $stream named $consumer timed out"
        }
        return [my SimpleRequest $subject $args $timeout_message]               
    }

    method consumer_names {stream args} {
        set subject "\$JS.API.CONSUMER.NAMES.$stream"
        return [my SimpleRequest $subject $args "Getting consumer names from $stream timed out"]    
    }

    ### STREAMS ###

    method add_stream {stream args} {
        if {![${conn}::my CheckSubject $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }

        set common_arguments [dict create]
        set config_dict [dict create] ;# variable with formatted arguments

        # supported arguments
        set arguments_list [list subjects retention max_consumers max_msgs max_bytes \
            max_age max_msgs_per_subject max_msg_size discard storage num_replicas duplicate_window \
            sealed deny_delete deny_purge allow_rollup_hdrs]


        foreach {opt val} $args {
            switch -- $opt {
                -subjects {
                    dict set config_dict subjects [::json::write array {*}[lmap subject $val {::json::write string $subject}]]
                }
                default {
                    if {$opt in [list -callback -timeout]} {
                        dict set common_arguments $opt $val
                        continue
                    }
                    set opt_raw [string range $opt 1 end] ;# remove flag
                    # duration args - provided in milliseconds should be formatted to nanoseconds 
                    if {$opt_raw in [list "duplicate_window" "max_age"]} {
                        if {![string is double -strict $val]} {
                            throw {NATS ErrInvalidArg} "Wrong duration value for argument $opt_raw it must be in milliseconds"
                        }
                        set val [expr {entier($val*1000*1000)}] ;#conversion milliseconds to nanoseconds
                    }
                    
                    # checking if all provided arguments are valid
                    if {$opt_raw ni $arguments_list} {
                        throw {NATS ErrInvalidArg} "Unknown option $opt"
                    }

                    if {![string is boolean -strict $val] && ![string is double -strict $val]} {
                        dict set config_dict $opt_raw [::json::write string $val]
                    } else {
                        dict set config_dict $opt_raw $val
                    }                 
                }
            }
        }
        
        set subject "\$JS.API.STREAM.CREATE.$stream"
        dict set config_dict name [::json::write string $stream]
        set settings_json [::nats::json_write_object {*}$config_dict]

        return [my SimpleRequest $subject $common_arguments "Creating stream $stream timed out" $settings_json]
    }

    method delete_stream {stream args} {
        set subject "\$JS.API.STREAM.DELETE.$stream"
        return [my SimpleRequest $subject $args "Deleting stream $stream timed out"]         
    }

    method purge_stream {stream args} {
        set subject "\$JS.API.STREAM.PURGE.$stream"
        return [my SimpleRequest $subject $args "Purging stream $stream timed out"]         
    }

    method stream_info {{stream ""} args} {
        if {$stream eq ""} {
            set subject "\$JS.API.STREAM.LIST"
            set timeout_message "Getting stream list timed out"
        } else {
            set subject "\$JS.API.STREAM.INFO.$stream"
            set timeout_message "Getting stream info for $stream timed out"
        }
        return [my SimpleRequest $subject $args $timeout_message]                
    }

    method stream_names {args} {
        set subject "\$JS.API.STREAM.NAMES"
        return [my SimpleRequest $subject $args "Getting stream names timed out"]
    }

    ### UTILS ###

    method SimpleRequest {subject common_arguments timeout_message {msg {}}} {
        if {![${conn}::my CheckSubject $subject]} {
            throw {NATS ErrInvalidArg} "Invalid stream or consumer name (target subject: $subject)"
        }

        set timeout -1 ;# ms
        set callback ""
        foreach {opt val} $common_arguments {
            switch -- $opt {
                -callback {
                    # receive status of adding consumer on callback proc
                    set callback [mymethod PublishCallback $val]
                }
                -timeout {
                    nats::check_timeout $val
                    set timeout $val
                }
                default {
                    throw {NATS ErrInvalidArg} "Unknown option $opt"        
                }
            }
        }

        try {
            set result [$conn request $subject $msg -dictmsg true -timeout $timeout -callback $callback -max_msgs 1]
        } trap {NATS ErrTimeout} err {
            throw {NATS ErrTimeout} $timeout_message
        }
        if {$callback ne ""} {
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

            if {[dict exists $responseDict type] && [string match "*stream_msg_get_response" [dict get $responseDict type]]} {
                if {[dict exists $responseDict message data]} {
                    dict set responseDict message data [binary decode base64 [dict get $responseDict message data]]
                }
            }
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
