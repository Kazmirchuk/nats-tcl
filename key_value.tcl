# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

namespace eval ::nats {}

# based on https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md
oo::class create ::nats::key_value {
    variable conn
    variable status_var
    variable js
    variable bucket
    variable stream
    variable kv_read_prefix
    variable kv_write_prefix
    variable mirrored_bucket_name

    variable _timeout
    variable requests
    variable watch

    constructor {connection jet_stream domain_name bucket_name stream_info timeout} {
        set conn $connection
        set status_var [${connection}::my varname status]
        set js $jet_stream
        set bucket $bucket_name
        set stream "KV_${bucket_name}"
        set _timeout $timeout ;# avoid clash with -timeout option when using _parse_args
        array set requests {} ;# reqID -> dict
        array set watch {} ;# watchID -> dict
        set mirrored_bucket_name ""

        if {$domain_name eq ""} {
            set kv_read_prefix "\$KV.${bucket}"
        } else {
            set kv_read_prefix "\$JS.${domain_name}.API.\$KV.${bucket}"
        }

        set kv_write_prefix $kv_read_prefix

        if {[dict exists $stream_info config mirror name]} {
            # kv is mirrored
            set mirrored_stream_name [dict get $stream_info config mirror name]
            set mirrored_bucket_name [string range $mirrored_stream_name 3 end] ;# remove "KV_" from "KV_bucket_name"
            
            set kv_write_prefix "\$KV.${mirrored_bucket_name}"

            if {[dict exists $stream_info config mirror external api] && [dict get $stream_info config mirror external api] ne ""} {
                set external_api [dict get $stream_info config mirror external api]
                set kv_write_prefix "${external_api}.\$KV.${mirrored_bucket_name}"
            }
        }
    }

    method get {key args} {
        my CheckKeyName $key

        nats::_parse_args $args {
            revision pos_int null
        }

        set subject "\$KV.*.${key}"

        try {
            if {[info exists revision]} {
                set resp [$js stream_msg_get $stream -seq $revision]

                if {[dict exists $resp subject] && [lindex [my SubjectToBucketKey [dict get $resp subject]] 1] ne $key} {
                    throw {NATS KeyNotFound} "Key ${key} not found"
                }
            } else {
                set resp [$js stream_msg_get $stream -last_by_subj $subject]
            }
        } trap {NATS ErrJSResponse 404 10037} {} {
            throw {NATS KeyNotFound} "Key ${key} not found"
        } trap {NATS ErrJSResponse 404 10059} {} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        return [my MessageToEntry $resp]
    }

    method get_value {key args} {
        set entry [my get $key {*}$args]

        # handle case when key value has been deleted or purged
        if {[dict get $entry operation] eq "DEL"} {
            throw {NATS KeyNotFound} "Key ${key} was deleted"
        }
        if {[dict get $entry operation] eq "PURGE"} {
            throw {NATS KeyNotFound} "Key ${key} was purged"
        }

        return [dict get $entry value]
    }

    method put {key value} {
        my CheckKeyName $key
        set subject "${kv_write_prefix}.${key}"

        set resp [$js publish $subject $value]
        return [dict get $resp seq]
    }

    method create {key value} {
        my CheckKeyName $key

        set subject "${kv_write_prefix}.${key}"

        set msg [nats::msg create $subject -data $value]
        nats::header set msg Nats-Expected-Last-Subject-Sequence 0
        
        try {
            set resp [$js publish_msg $msg]
        } trap {NATS ErrJSResponse 400 10071} {msg} {
            throw {NATS WrongLastSequence} $msg
        }

        return [dict get $resp seq]
    }

    method update {key value revision} {
        my CheckKeyName $key

        set subject "${kv_write_prefix}.${key}"

        set msg [nats::msg create $subject -data $value]
        nats::header set msg Nats-Expected-Last-Subject-Sequence $revision

        try {
            set resp [$js publish_msg $msg]
        } trap {NATS ErrJSResponse 400 10071} {msg} {
            throw {NATS WrongLastSequence} $msg
        }

        return [dict get $resp seq]
    }

    method delete {key args} {
        my CheckKeyName $key

        nats::_parse_args $args {
            revision pos_int null
        }

        set subject "${kv_write_prefix}.${key}"
        set msg [nats::msg create $subject]
        nats::header set msg KV-Operation DEL
        if {[info exists revision]} {
            nats::header set msg Nats-Expected-Last-Subject-Sequence $revision
        }

        try {
            set resp [$js publish_msg $msg]
        } trap {NATS ErrJSResponse 400 10071} {msg} {
            throw {NATS WrongLastSequence} $msg
        }

        return
    }

    method purge {key} {
        my CheckKeyName $key

        set subject "${kv_write_prefix}.${key}"

        set msg [nats::msg create $subject]
        nats::header set msg KV-Operation PURGE Nats-Rollup sub
        set resp [$js publish_msg $msg]

        return
    }

    method revert {key revision args} {
        my CheckKeyName $key

        set subject "${kv_write_prefix}.${key}"

        set entry [my get $key -revision $revision]

        set resp [$js publish $subject [dict get $entry value]]
        return [dict get $resp seq]
    }

    method status {} {
        try {
            set stream_info [$js stream_info $stream]
        } trap {NATS ErrJSResponse 404 10059} {} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        return [my StreamInfoToKvInfo $stream_info]
    }

    ########## ADVANCED ##########

    method history {args} {
        set key ""

        # first argument is not a flag - it is key name
        if {[lindex $args 0] ne "" && [string index [lindex $args 0] 0] ne "-"} {
            set key [lindex $args 0]
            my CheckKeyName $key
            set args [lrange $args 1 end]
        }

        if {$key eq ""} {
            set key ">"
        }

        set spec [list \
            timeout pos_int $_timeout \
        ]
        nats::_parse_args $args $spec

        set filter_subject "\$KV.${bucket}.${key}"

        if {$mirrored_bucket_name ne ""} {
            set filter_subject "\$KV.${mirrored_bucket_name}.${key}"
        }

        set deliver_subject [$conn inbox]

        # get unique ID that will be used to send "add_consumer" request
        set reqID [set ${conn}::counters(request)]
        incr reqID

        set requests($reqID) [dict create bucket $bucket timeout false num_received 0]
        set subscription [$conn subscribe $deliver_subject -dictmsg true -callback [mymethod MessageReceived $reqID]]
        
        # make sure it will return someday
        after $timeout [mymethod MessageReceived $reqID "" "" "" 1]
        
        try {
            set consumer [$js add_consumer $stream \
                -deliver_policy "all" \
                -ack_policy "none" \
                -max_deliver 1 \
                -filter_subject $filter_subject \
                -replay_policy "instant" \
                -deliver_subject $deliver_subject \
                -num_replicas 1 \
                -mem_storage 1 \
            ]
        } trap {NATS ErrJSResponse 404 10059} {msg} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        set consumer_name [dict get $consumer name]
        set num_pending [dict get $consumer num_pending]

        # go further if num_pending = 0 (no keys found)
        while {$num_pending > [dict get $requests($reqID) num_received] && ![dict get $requests($reqID) timeout]} {
            # next message (key) or timeout was received
            nats::_coroVwait [self object]::requests($reqID)
        }

        $js delete_consumer $stream $consumer_name
        $conn unsubscribe $subscription
        set msgs [dict lookup $requests($reqID) msgs]
        set timeout_fired [dict get $requests($reqID) timeout]
        set num_received [dict get $requests($reqID) num_received]
        unset requests($reqID)

        if {$timeout_fired && $num_pending > $num_received} {
            throw {NATS ErrTimeout} "timeout"
        }

        set history [list]
        foreach msg $msgs {
            lappend history [my MessageToEntry $msg]
        }

        return $history
    }

    method keys {args} {
        set spec [list \
            timeout pos_int $_timeout \
        ]

        nats::_parse_args $args $spec

        set subject "\$KV.*.>" ;# bucket is not set in case it comes from a different domain
        set deliver_subject [$conn inbox]

        # get unique ID that will be used to send "add_consumer" request
        set reqID [set ${conn}::counters(request)]
        incr reqID

        set requests($reqID) [dict create timeout false num_received 0]
        set subscription [$conn subscribe $deliver_subject -dictmsg true -callback [mymethod MessageReceived $reqID]]

        # make sure it will return someday
        after $timeout [mymethod MessageReceived $reqID "" "" "" 1]

        try {
            set consumer [$js add_consumer $stream \
                -deliver_policy "last_per_subject" \
                -ack_policy "none" \
                -max_deliver 1 \
                -filter_subject $subject \
                -replay_policy "instant" \
                -headers_only 1 \
                -deliver_subject $deliver_subject \
                -num_replicas 1 \
            ]
        } trap {NATS ErrJSResponse 404 10059} {msg} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        set consumer_name [dict get $consumer name]
        set num_pending [dict get $consumer num_pending]

        # go further if num_pending = 0 (no keys found)
        while {$num_pending > [dict get $requests($reqID) num_received] && ![dict get $requests($reqID) timeout]} {
            # next message (key) or timeout was received
            nats::_coroVwait [self object]::requests($reqID)
        }

        $js delete_consumer $stream $consumer_name
        $conn unsubscribe $subscription
        set msgs [dict lookup $requests($reqID) msgs]
        set timeout_fired [dict get $requests($reqID) timeout]
        set num_received [dict get $requests($reqID) num_received]
        unset requests($reqID)

        if {$timeout_fired && $num_pending > $num_received} {
            throw {NATS ErrTimeout} "timeout"
        }

        set keys [list]
        foreach msg $msgs {
            if {[dict exists $msg header]} {
                set operation [nats::header lookup $msg KV-Operation ""]
                if {$operation in [list "DEL" "PURGE"]} {
                    # key was deleted - do not add it
                    continue;
                }
            }

            set subject [dict get $msg subject]
            lappend keys [join [lrange [split $subject "."] 2 end] "."]
        }

        return $keys
    }

    method watch {args} {
        set key ""

        # first argument is not a flag - it is key name
        if {[lindex $args 0] ne "" && [string index [lindex $args 0] 0] ne "-"} {
            set key [lindex $args 0]

            if {[string range $key end-1 end] eq ".>"} {
                # can watch sub-keys
                my CheckKeyName [string range $key 0 end-2]
            } elseif {$key eq ">"} {
                # watch all keys
            } else {
                my CheckKeyName $key
            }
            set args [lrange $args 1 end]
        }

        if {$key eq ""} {
            set key ">"
        }

        set spec [list \
            callback valid_str null \
            include_history bool false \
            updates_only bool false \
            meta_only bool false \
            ignore_deletes bool false \
            idle_heartbeat pos_int 5000 \
        ]

        nats::_parse_args $args $spec

        if {![info exists callback]} {
            throw {NATS ErrInvalidArg} "Callback option should be specified"
        }

        return [my WatchImpl $key \
            -callback $callback \
            -include_history $include_history \
            -updates_only $updates_only \
            -meta_only $meta_only \
            -ignore_deletes $ignore_deletes\
            -idle_heartbeat $idle_heartbeat \
        ]
    }

    # based on Ordered Consumer (but without flow control) - message gaps and idle heartbeats are taken care of: 
    # https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-17.md
    # https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-15.md
    method WatchImpl {key args} {
        set spec [list \
            callback valid_str null \
            include_history bool false \
            updates_only bool false \
            meta_only bool false \
            ignore_deletes bool false \
            idle_heartbeat pos_int 5000 \
            \
            stream_seq pos_int null \
            watch_id pos_int null \
            initial_data bool true \
            last_error str "" \
        ]
                
        nats::_parse_args $args $spec

        set filter_subject "\$KV.${bucket}.${key}"
        if {$mirrored_bucket_name ne ""} {
            set filter_subject "\$KV.${mirrored_bucket_name}.${key}"
        }

        set deliver_subject [$conn inbox]

        if {[info exists watch_id]} {
            # preserve old id
            set watchID $watch_id
        } else {
            # get unique ID that will be used to send "add_consumer" request and return it to user
            set watchID [set ${conn}::counters(request)]
            incr watchID
        }

        set watch($watchID) [dict create \
            key $key \
            consumer_seq 0 \
            include_history $include_history \
            updates_only $updates_only \
            meta_only $meta_only \
            ignore_deletes $ignore_deletes \
            idle_heartbeat $idle_heartbeat \
            deliver_subject $deliver_subject \
            initial_data $initial_data \
            last_error $last_error \
            callback $callback \
        ]

        if {[info exists stream_seq]} {
            dict set watch($watchID) stream_seq $stream_seq
        }
        set subscription [$conn subscribe $deliver_subject -dictmsg true -callback [mymethod WatchMessageReceived $deliver_subject $watchID]]

        set options [list \
            -ack_policy "none" \
            -max_deliver 1 \
            -filter_subject $filter_subject \
            -replay_policy "instant" \
            -deliver_subject $deliver_subject \
            -idle_heartbeat $idle_heartbeat \
            -mem_storage true \
            -num_replicas 1 \
        ]

        lappend options -headers_only $meta_only

        if {[info exists stream_seq]} {
            lappend options -opt_start_seq [expr {$stream_seq + 1}]
            lappend options -deliver_policy "by_start_sequence"
        } elseif {$include_history} {
            lappend options -deliver_policy "all"

            if {$updates_only} {
                throw {NATS ErrInvalidArg} "Options -include_history and -updates_only cannot be true at the same time"
            }
        } elseif {$updates_only} {
            lappend options -deliver_policy "new"
        } else {
            lappend options -deliver_policy "last_per_subject"
        }

        try {
            set consumer [$js add_consumer $stream {*}$options]
        } trap {NATS ErrJSResponse 404 10059} {msg} {
            if {[info exists watch_id]} {
                # trying to reset consumer - do not remove it completely
                dict set watch($watchID) removed true
            } else {
                unset watch($watchID)
            }
            $conn unsubscribe $subscription
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        } trap {} {msg opts} {
            if {[info exists watch_id]} {
                # trying to reset consumer - do not remove it completely
                dict set watch($watchID) removed true
            } else {
                unset watch($watchID)
            }
            $conn unsubscribe $subscription
            throw $opts $msg
        }

        dict set watch($watchID) consumer_name [dict get $consumer name]
        dict set watch($watchID) subscription $subscription

        return $watchID
    }

    method unwatch {watchID} {
        return [my UnwatchImpl $watchID]
    }

    method UnwatchImpl {watchID args} {
        if {![info exists watch($watchID)]} {
            throw {NATS ErrInvalidArg} "There is no watch with that id"
        }

        set spec [list \
            remove_completely bool true
        ]
                
        nats::_parse_args $args $spec

        set consumer_name [dict lookup $watch($watchID) consumer_name ""]
        set subscription [dict lookup $watch($watchID) subscription ""]

        try {
            if {$consumer_name ne ""} {
                $js delete_consumer $stream $consumer_name
                $conn unsubscribe $subscription
            }
        } trap {NATS ErrJSResponse 404 10014} {} {
            # consumer not found - ignore it and ignore unsubscribe - it probably does not exists too
        }

        if {$remove_completely} {
            unset watch($watchID)
            # if there was restart planned than make sure it won't happen
            after cancel [mymethod ResetWatch $watchID]
        }

        return
    }

    ########## HELPERS ##########

    method MessageReceived {reqID subject msg reply {timeout 0}} {
        if {![info exists requests($reqID)]} {
            return
        }

        if {$timeout} {
            dict set requests($reqID) timeout true
            return
        }

        dict incr requests($reqID) num_received
        dict lappend requests($reqID) msgs $msg
    }

    method WatchMessageReceived {deliver_subject watchID subject msg reply} {
        if {![info exists watch($watchID)] || [dict lookup $watch($watchID) removed false]} {
            return
        }
        if {[dict get $watch($watchID) deliver_subject] ne $deliver_subject} {
            # should never happen, but if consumer has been recreated and old one somehow is still active,
            # then make sure the old one won't work
            return
        }

        # after 3 missed heartbeats reset consumer
        after cancel [mymethod ResetWatch $watchID]
        after [expr {[dict get $watch($watchID) idle_heartbeat] * 3}] [mymethod ResetWatch $watchID]

        set last_consumer_seq [dict get $watch($watchID) consumer_seq]
        set last_stream_seq [dict lookup $watch($watchID) stream_seq ""]

        if {[nats::header lookup $msg Status 0] == 100} {
            # idle heartbeat
            set num_pending 0
            set stream_seq [nats::header lookup $msg Nats-Last-Stream ""]
            set consumer_seq [nats::header lookup $msg Nats-Last-Consumer ""]
        } else {
            set num_pending [lindex [split $reply "."] end]
            set stream_seq [lindex [split $reply "."] end-3]
            set consumer_seq [lindex [split $reply "."] end-2]
        }

        if {$last_consumer_seq + 1 < $consumer_seq} {
            # difference between current message seq and last delivered is more than 1
            # there has been a Message Gap - restart consumer using last stream seq
            after cancel [mymethod ResetWatch $watchID]
            my ResetWatch $watchID
            return
        }

        dict set watch($watchID) consumer_seq $consumer_seq

        set last_error [dict get $watch($watchID) last_error]
        dict set watch($watchID) last_error ""

        if {$last_stream_seq ne "" && $stream_seq <= $last_stream_seq} {
            # already delivered - do not change current stream seq and do not redeliver to user
            if {$last_error ne ""} {
                # there were errors before, but connection has been reestablished - notify user
                set callback [dict get $watch($watchID) callback]
                after 0 [list $callback ok {}]
            }
            return
        }

        dict set watch($watchID) stream_seq $stream_seq

        if {[nats::header lookup $msg Status 0] == 100} {
            # idle heartbeat
            if {$num_pending == 0 && [dict get $watch($watchID) initial_data]} {
                # send End Of Initial Data signal
                dict set watch($watchID) initial_data false
                set callback [dict get $watch($watchID) callback]
                after 0 [list $callback end_of_initial_data {}]
            }
            if {$last_error ne ""} {
                # there were errors before, but connection has been reestablished - notify user
                set callback [dict get $watch($watchID) callback]
                after 0 [list $callback ok {}]
            }
            return
        }

        set entry [my MessageToEntry $msg]
        if {[dict get $entry operation] ne "PUT" && [dict get $watch($watchID) ignore_deletes]} {
            if {$last_error ne ""} {
                # there were errors before, but connection has been reestablished - notify user
                set callback [dict get $watch($watchID) callback]
                after 0 [list $callback ok {}]
            }
            return
        }

        set callback [dict get $watch($watchID) callback]
        after 0 [list $callback {} $entry]

        if {$num_pending == 0 && [dict get $watch($watchID) initial_data]} {
            # send End Of Initial Data signal
            dict set watch($watchID) initial_data false
            set callback [dict get $watch($watchID) callback]
            after 0 [list $callback end_of_initial_data {}]
        }
    }

    method ResetWatch {watchID} {
        if {![info exists watch($watchID)]} {
            return
        }

        if {[set $status_var] != $::nats::status_connected} {
            # nats-server is disconnected - after it connects it will probably restore consumer
            # if it happens we will receive some messages and this reset will be canceled
            set new_error "Server disconnected"
            if {$new_error ne [dict get $watch($watchID) last_error]} {
                dict set watch($watchID) last_error $new_error
                set callback [dict get $watch($watchID) callback]
                after 0 [list $callback error $new_error]
            }
            after [dict get $watch($watchID) idle_heartbeat] [mymethod ResetWatch $watchID]
            return;
        }

        dict set watch($watchID) deliver_subject "" ;# make sure no further messages will be processed from this subscription

        try {
            # make sure watch($watchID) is not completely removed
            if {![dict lookup $watch($watchID) removed false]} {
                # subscriptions etc were not removed yet
                my UnwatchImpl $watchID -remove_completely false
                dict set watch($watchID) removed true
            }

            set options [dict create \
                -callback [dict get $watch($watchID) callback] \
                -include_history [dict get $watch($watchID) include_history] \
                -updates_only [dict get $watch($watchID) updates_only] \
                -meta_only [dict get $watch($watchID) meta_only] \
                -ignore_deletes [dict get $watch($watchID) ignore_deletes] \
                -idle_heartbeat [dict get $watch($watchID) idle_heartbeat] \
                -watch_id $watchID \
                -initial_data [dict get $watch($watchID) initial_data] \
                -last_error [dict get $watch($watchID) last_error] \
            ]

            if {[dict exists $watch($watchID) stream_seq]} {
                dict set options -stream_seq [dict get $watch($watchID) stream_seq]
            }

            set key [dict get $watch($watchID) key]

            my WatchImpl $key {*}$options
        } trap {} {msg opts} {
            # probably consumer cannot be removed or created again - try again in few seconds
            set new_error "Error resetting consumer: $msg"
            if {$new_error ne [dict get $watch($watchID) last_error]} {
                dict set watch($watchID) last_error $new_error
                set callback [dict get $watch($watchID) callback]
                after 0 [list $callback error $new_error]
            }
            after [dict get $watch($watchID) idle_heartbeat] [mymethod ResetWatch $watchID]
        }
    }

    method StreamInfoToKvInfo {stream_info} {
        set kv_info [dict create \
            bucket [string range [dict get $stream_info config name] 3 end] \
            stream [dict get $stream_info config name] \
            storage [dict get $stream_info config storage] \
            history [dict get $stream_info config max_msgs_per_subject] \
            ttl [dict get $stream_info config max_age] \
            max_value_size [dict get $stream_info config max_msg_size] \
            max_bucket_size [dict get $stream_info config max_bytes] \
            created [nats::time_to_millis [dict get $stream_info created]] \
            values_stored [dict get $stream_info state messages] \
            bytes_stored [dict get $stream_info state bytes] \
            backing_store JetStream \
        ]

        if {[dict exists $stream_info config mirror name]} {
            # in format "KV_some-name"
            dict set kv_info mirror_name [string range [dict get $stream_info config mirror name] 3 end]
        }
        if {[dict exists $stream_info config mirror external api]} {
            # in format "$JS.some-domain.API"
            set external_api [dict get $stream_info config mirror external api]
            dict set kv_info mirror_domain [lindex [split $external_api "."] 1]
        }

        # do it here so that underlying stream config will be at the end
        dict set kv_info store_config [dict get $stream_info config]
        dict set kv_info store_state [dict get $stream_info state]

        return $kv_info
    }

    method MessageToEntry {msg} {
        # return dict representation of Entry https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md#entry
        # reply will be in format:  $JS.ACK.<domain>.<account hash>.<stream name>.<consumer name>.<num delivered>.<stream sequence>.<consumer sequence>.<timestamp>.<num pending>
        # or                        $JS.ACK.<stream name>.<consumer name>.<num delivered>.<stream sequence>.<consumer sequence>.<timestamp>.<num pending>

        lassign [my SubjectToBucketKey [dict get $msg subject]] bucket key
        set value ""
        if {[dict exists $msg data]} {
            set value [dict get $msg data]
        }
        set header [dict create]
        if {[dict exist $msg header]} {
            set header [dict get $msg header]
        }
        set operation [my HeadersToOperation $header]
        set entry [dict create \
            value $value \
            bucket $bucket \
            key $key \
            operation $operation \
        ]

        if {[dict exists $msg seq]} {
            dict set entry revision [dict get $msg seq]
        } elseif {[dict exists $msg reply]} {
            # get seq from reply subject (stream sequence)
            dict set entry revision [lindex [split [dict get $msg reply] "."] end-3]
        }

        if {[dict exists $msg time]} {
            dict set entry created [::nats::time_to_millis [dict get $msg time]]
        } elseif {[dict exists $msg reply]} {
            # get time from reply subject (timestamp)
            set ns [lindex [split [dict get $msg reply] "."] end-1]
            dict set entry created $ns
            ::nats::_ns2ms entry created
        }

        return $entry
    }

    method SubjectToBucketKey {subject} {
        # return list of bucket and key from subject
        set parts [split $subject "."]
        set bucket [lindex $parts 1]
        set key [join [lindex $parts 2 end] "."]
        return [list $bucket $key]
    }

    method HeadersToOperation {headers} {
        # return operation from headers
        if {[dict exists $headers KV-Operation]} {
            return [dict get $headers KV-Operation]
        }
        return "PUT"
    }

    method CheckKeyName {key} {
        if {[string index $key 0] eq "."} {
            throw {NATS ErrInvalidArg} "Keys cannot start with \".\""
        }
        if {[string index $key end] eq "."} {
            throw {NATS ErrInvalidArg} "Keys cannot end with \".\""
        }
        if {[string range $key 0 2] eq "_kv"} {
            throw {NATS ErrInvalidArg} "Keys cannot start with \"_kv\", which is reserved for internal use"
        }
        if {![regexp {^[-/_=\.a-zA-Z0-9]+$} $key]} {
            throw {NATS ErrInvalidArg} "Key \"$key\" is not valid key name"
        }
    }
}