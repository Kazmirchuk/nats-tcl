# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require json

namespace eval ::nats {}


oo::class create ::nats::consumer {
    variable conn stream_name consumer_name consumer_info
    
    constructor {c stream consumer args} {
        set conn $c
        set stream_name $stream
        set consumer_name $consumer

        if {![${conn}::my CheckSubject $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        if {![${conn}::my CheckSubject $consumer]} {
            throw {NATS ErrInvalidArg} "Invalid consumer name $consumer"
        }

        set subject "\$JS.API.CONSUMER.DURABLE.CREATE.$stream.$consumer"
        set batch_size 1
        set timeout -1 ;# ms
        set callback ""
        set config_dict [dict create] ;# variable with formatted arguments

        # supported arguments
        set arguments_list [list mode description deliver_group deliver_policy opt_start_seq \
            opt_start_time ack_policy ack_wait max_deliver filter_subject replay_policy \
            rate_limit_bps sample_freq max_waiting max_ack_pending idle_heartbeat flow_control \
            deliver_subject durable_name]

        # check required args        
        foreach req_arg [list -deliver_policy -ack_policy -replay_policy -mode -callback] {
            if {![dict exists $args $req_arg]} {
                throw {NATS ErrInvalidArg} "Argument: $req_arg is required"
            }
        }

        set mode [dict get $args -mode]

        foreach {opt val} $args {
            switch -- $opt {
                -mode {
                    # only pull/push value is supported
                    if {$val ni [list pull push]} {
                        throw {NATS ErrInvalidArg} "Wrong mode value, must be: pull or push"
                    }

                    if {$val eq "push"} {
                        # deliver subject is required if you want to create push consumer
                        # if you select mode push and don't provide deliver_subject it will be set equal to consumer name
                        if {![dict exists $args deliver_subject]} {
                            dict set config_dict deliver_subject $consumer
                        }                 
                    }
                }
                -flow_control {
                    # argument flow_control in pull mode is forbidden
                    if {$mode eq "pull"} {
                        throw {NATS ErrInvalidArg} "Argument flow_control is forbbiden for mode pull"
                    }          
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
                    set callback $val
                }
                -timeout {
                    nats::check_timeout $val
                    set timeout $val
                }
                default {
                    set opt_raw [string range $opt 1 end] ;# remove flag

                    # pull validation
                    if {$opt_raw in [list "idle_heartbeat" "deliver_subject"] && $mode eq "pull"} {
                        throw {NATS ErrInvalidArg} "Argument $opt_raw is forbbiden for mode pull"
                    }

                    # push validation
                    if {$opt_raw in [list "max_waiting"] && $mode eq "push"} {
                        throw {NATS ErrInvalidArg} "Argument $opt_raw is forbbiden for mode push"
                    }                    

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

        # durable name is required to create durable consumer
        # if it is not provided then it is setted as consumer name
        if {![dict exists config_dict durable_name]} {
            dict set config_dict durable_name $consumer
        }

        # string arguments need to be within quotation marks ""
        dict for {key value} $config_dict {
            if {![string is boolean -strict $value] && ![string is double -strict $value]} {
                dict set config_dict $key \"$value\"
            }            
        }
        # only for information about consumer        
        set consumer_info [dict create stream_name $stream consumer_name $consumer config [dict merge [dict create mode $mode] $config_dict]]

        # creating arguments dictionary and converting it to json 
        set settings_dict [dict create stream_name \"$stream\"  name \"$consumer\" config [::json::dict2json $config_dict]]
        set settings_json [::json::dict2json $settings_dict]

        try {
            $conn request $subject $settings_json -dictmsg true -timeout $timeout -callback $callback -max_msgs $batch_size
        } trap {NATS ErrTimeout} err {
            throw {NATS ErrTimeout} "Creating consumer $stream $consumer timed out"
        }
    }

    method remove {args} {
        set subject "\$JS.API.CONSUMER.DELETE.$stream_name.$consumer_name"
        set batch_size 1
        set timeout -1 ;# ms
        set callback ""
        # check required args        
        foreach req_arg [list -callback] {
            if {![dict exists $args $req_arg]} {
                throw {NATS ErrInvalidArg} "Argument: $req_arg is required"
            }
        }
        foreach {opt val} $args {
            switch -- $opt {
                -callback {
                    # receive status of adding consumer on callback proc
                    set callback $val
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
            $conn request $subject "" -dictmsg true -timeout $timeout -callback $callback -max_msgs $batch_size
        } trap {NATS ErrTimeout} err {
            throw {NATS ErrTimeout} "Deleting consumer $stream_name $consumer_name timed out"
        }

        $conn removeConsumer $stream_name $consumer_name; # remove consumer data from nats object     
    }

    method info {} {
        return $consumer_info
    }
}