# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

namespace eval ::nats {}

# based on https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md
oo::class create ::nats::key_value {
    variable conn
    variable status_var
    variable js
    variable kv_prefix
    variable check_bucket_default
    variable read_only

    variable _timeout
    variable requests
    variable watch

    constructor {connection jet_stream domain_name timeout check_bucket rd_only} {
        set conn $connection
        set status_var [${connection}::my varname status]
        set js $jet_stream
        if {$domain_name eq ""} {
            set kv_prefix "\$KV"
        } else {
            set kv_prefix "\$JS.${domain_name}.API.\$KV"
        }
        set check_bucket_default $check_bucket
        set read_only $rd_only

        set _timeout $timeout ;# avoid clash with -timeout option when using _parse_args
        array set requests {} ;# reqID -> dict
        array set watch {} ;# watchID -> dict
    }

    method get {bucket key args} {
        my CheckBucketName $bucket
        my CheckKeyName $key

        nats::_parse_args $args {
            revision pos_int null
        }

        set stream "KV_${bucket}"
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
        
        set msg $resp

        # handle case when key value has been deleted or purged
        if {[dict exists $msg header]} {
            set operation [nats::header lookup $msg KV-Operation ""]
            if {$operation in [list "DEL" "PURGE"]} {
                throw {NATS KeyNotFound} "Key ${key} not found"
            }
        }

        return [my MessageToEntry $msg]
    }

    method put {bucket key value args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        my CheckKeyName $key

        nats::_parse_args $args [list \
            check_bucket bool $check_bucket_default \
        ]

        set subject "${kv_prefix}.${bucket}.${key}"

        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "[dict get $config mirror bucket_subject].${key}"
            }
        }

        set resp [$js publish $subject $value]
        return [dict get $resp seq]
    }

    method create {bucket key value args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        my CheckKeyName $key

        nats::_parse_args $args [list \
            check_bucket bool $check_bucket_default \
        ]

        set subject "${kv_prefix}.${bucket}.${key}"

        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "[dict get $config mirror bucket_subject].${key}"
            }
        }

        set msg [nats::msg create $subject -data $value]
        nats::header set msg Nats-Expected-Last-Subject-Sequence 0
        
        try {
            set resp [$js publish_msg $msg]
        } trap {NATS ErrJSResponse 400 10071} {msg} {
            throw {NATS WrongLastSequence} $msg
        }

        return [dict get $resp seq]
    }

    method update {bucket key revision value args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        my CheckKeyName $key

        nats::_parse_args $args [list \
            check_bucket bool $check_bucket_default \
        ]

        set subject "${kv_prefix}.${bucket}.${key}"

        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "[dict get $config mirror bucket_subject].${key}"
            }
        }

        set msg [nats::msg create $subject -data $value]
        nats::header set msg Nats-Expected-Last-Subject-Sequence $revision

        try {
            set resp [$js publish_msg $msg]
        } trap {NATS ErrJSResponse 400 10071} {msg} {
            throw {NATS WrongLastSequence} $msg
        }

        return [dict get $resp seq]
    }

    method del {bucket args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        set key ""

        # first argument is not a flag - it is key name
        if {[lindex $args 0] ne "" && [string index [lindex $args 0] 0] ne "-"} {
            set key [lindex $args 0]
            my CheckKeyName $key
            set args [lrange $args 1 end]
        }

        nats::_parse_args $args [list \
            check_bucket bool $check_bucket_default \
        ]

        if {$check_bucket} {
            set config [my _checkBucket $bucket]
        }

        if {$key ne ""} {
            set subject "${kv_prefix}.${bucket}.${key}"
            if {[info exists config] && [dict exists $config mirror]} {
                set subject "[dict get $config mirror bucket_subject].${key}"
            }
            set msg [nats::msg create $subject]
            nats::header set msg KV-Operation DEL
            set resp [$js publish_msg $msg]
            return
        }

        set stream "KV_${bucket}"
        try {
            $js delete_stream $stream
        } trap {NATS ErrJSResponse 404 10059} {} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        return
    }

    method purge {bucket key args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        my CheckKeyName $key

        nats::_parse_args $args [list \
            check_bucket bool $check_bucket_default \
        ]

        set subject "${kv_prefix}.${bucket}.${key}"

        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "[dict get $config mirror bucket_subject].${key}"
            }
        }

        set msg [nats::msg create $subject]
        nats::header set msg KV-Operation PURGE Nats-Rollup sub
        set resp [$js publish_msg $msg]

        return $resp
    }

    method revert {bucket key revision args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        my CheckKeyName $key

        nats::_parse_args $args [list \
            check_bucket bool $check_bucket_default \
        ]

        set subject "${kv_prefix}.${bucket}.${key}"
        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "[dict get $config mirror bucket_subject].${key}"
            }
        }

        set entry [my get $bucket $key -revision $revision]

        set resp [$js publish $subject [dict get $entry value]]
        return [dict get $resp seq]
    }

    # check stream info to know if given stream even exists (or is mirror of another stream), in order to not wait for timeout if it doesn't
    method _checkBucket {bucket} {
        set stream "KV_${bucket}"
        try {
            set stream_info [$js stream_info $stream]
        } trap {NATS ErrJSResponse 404 10059} {} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        if {[dict exists $stream_info mirror name]} {
            # kv is mirrored
            set mirrored_stream_name [dict get $stream_info mirror name]
            set mirrored_kv_name [string range $mirrored_stream_name 3 end] ;# remove "KV_" from "KV_bucket_name"
            
            set config [dict create \
                mirror [dict create \
                    bucket_name $mirrored_kv_name \
                    bucket_subject "\$KV.${mirrored_kv_name}" \
                ] \
            ]

            if {[dict exists $stream_info mirror external api] && [dict get $stream_info mirror external api] ne ""} {
                set external_api [dict get $stream_info mirror external api]
                dict set config mirror external_api $external_api
                dict set config mirror bucket_subject "${external_api}.\$KV.${mirrored_kv_name}"
            }

            return $config
        }

        return [dict create]
    }

    ########## ADVANCED ##########

    method history {bucket args} {
        my CheckBucketName $bucket
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
            check_bucket bool $check_bucket_default \
        ]
        nats::_parse_args $args $spec

        set stream "KV_${bucket}"
        set subject "\$KV.${bucket}.${key}"

        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "\$KV.[dict get $config mirror bucket_name].${key}"
            }
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
                -filter_subject $subject \
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

    method watch {bucket args} {
        my CheckBucketName $bucket
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
            headers_only bool false \
            ignore_deletes bool false \
            idle_heartbeat pos_int 5000 \
            check_bucket bool $check_bucket_default \
        ]

        nats::_parse_args $args $spec

        if {![info exists callback]} {
            throw {NATS ErrInvalidArg} "Callback option should be specified"
        }

        return [my WatchImpl $bucket $key \
            -callback $callback \
            -include_history $include_history \
            -updates_only $updates_only \
            -headers_only $headers_only \
            -ignore_deletes $ignore_deletes\
            -idle_heartbeat $idle_heartbeat \
            -check_bucket $check_bucket \
        ]
    }

    # based on Ordered Consumer (but without flow control) - message gaps and idle heartbeats are taken care of: 
    # https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-17.md
    # https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-15.md
    method WatchImpl {bucket key args} {
        set spec [list \
            callback valid_str null \
            include_history bool false \
            updates_only bool false \
            headers_only bool false \
            ignore_deletes bool false \
            idle_heartbeat pos_int 5000 \
            check_bucket bool $check_bucket_default \
            \
            stream_seq pos_int null \
            watch_id pos_int null \
            initial_data bool true \
            last_error str "" \
        ]
                
        nats::_parse_args $args $spec

        set stream "KV_${bucket}"
        set subject "\$KV.${bucket}.${key}"
        if {$check_bucket} {
            set config [my _checkBucket $bucket]
            if {[dict exists $config mirror]} {
                set subject "\$KV.[dict get $config mirror bucket_name].${key}"
            }
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
            bucket $bucket \
            key $key \
            consumer_seq 0 \
            include_history $include_history \
            updates_only $updates_only \
            headers_only $headers_only \
            ignore_deletes $ignore_deletes \
            idle_heartbeat $idle_heartbeat \
            check_bucket $check_bucket \
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
            -filter_subject $subject \
            -replay_policy "instant" \
            -deliver_subject $deliver_subject \
            -idle_heartbeat $idle_heartbeat \
            -mem_storage true \
            -num_replicas 1 \
        ]

        lappend options -headers_only $headers_only

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

        set bucket [dict get $watch($watchID) bucket]
        set stream "KV_${bucket}"
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

    ########## MANAGING ##########

    method add {bucket args} {
        if {$read_only} {
            throw {NATS KvReadOnly} "KV has been created in read-only mode"
        }
        my CheckBucketName $bucket
        set stream "KV_${bucket}"

        set options {
            -storage file
            -retention limits
            -discard new
            -max_msgs_per_subject 1
            -num_replicas 1
            -max_msgs -1
            -max_msg_size -1
            -max_bytes -1
            -max_age 0
            -duplicate_window 120000000000
            -deny_delete 1
            -deny_purge 0
            -allow_rollup_hdrs 1
        }

        set argsMap {
            -history            -max_msgs_per_subject
            -storage            -storage
            -ttl                -max_age
            -max_value_size     -max_msg_size
            -max_bucket_size    -max_bytes
            -mirror_name        -mirror
            -mirror_domain      -mirror
        }

        if {[llength $args] % 2} {
            throw {NATS ErrInvalidArg} "Missing value for option [lindex $args end]"
        }

        dict for {key value} $args {
            if {![dict exists $argsMap $key]} {
                throw {NATS ErrInvalidArg} "Unknown option ${key}. Should be one of [dict keys $argsMap]"
            }
            switch -- $key {
                -history {
                    if {$value < 1} {
                        throw {NATS ErrInvalidArg} "history must be greater than 0"
                    }
                    if {$value > 64} {
                        throw {NATS ErrInvalidArg} "history must be less than 64"
                    }

                    dict set options [dict get $argsMap $key] $value
                }
                -mirror_domain {
                    # mirror_domain is taken care of in "mirror_name"
                }
                -mirror_name {
                    set mirror_info [dict create name "KV_${value}"]
                    if {[dict exists $args "-mirror_domain"]} {
                        dict set mirror_info external api "\$JS.[dict get $args "-mirror_domain"].API"
                    }
                    dict set options [dict get $argsMap $key] $mirror_info
                }
                default {
                    dict set options [dict get $argsMap $key] $value
                }
            }
        }

        if {![dict exists $args -mirror_name]} {
            # when kv is mirroring it does not listen on normal subjects
            set subject "\$KV.${bucket}.>"
            lappend options -subjects $subject
        }

        return [$js add_stream $stream {*}$options]
    }

    method info {bucket} {
        my CheckBucketName $bucket
        set stream "KV_${bucket}"
        try {
            set stream_info [$js stream_info $stream]

            set kv_info [dict create]
            dict set kv_info bucket $bucket
            dict set kv_info stream $stream
            dict set kv_info storage [dict get $stream_info config storage]
            dict set kv_info history [dict get $stream_info config max_msgs_per_subject]
            dict set kv_info ttl [dict get $stream_info config max_age]
            dict set kv_info max_value_size [dict get $stream_info config max_msg_size]
            dict set kv_info max_bucket_size [dict get $stream_info config max_bytes]

            if {[dict exists $stream_info mirror]} {
                dict set kv_info mirror [dict get $stream_info mirror]
            }

            dict set kv_info created [nats::time_to_millis [dict get $stream_info created]]
            dict set kv_info values_stored [dict get $stream_info state messages]
            dict set kv_info bytes_stored [dict get $stream_info state bytes]

            dict set kv_info backing_store JetStream
            dict set kv_info store_config [dict get $stream_info config]
            dict set kv_info store_state [dict get $stream_info state]
        } trap {NATS ErrJSResponse 404 10059} {} {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }

        return $kv_info
    }

    method ls {} {
        set streams [$js stream_names]
        set kv_list [list]
        foreach stream $streams {
            if {[string range $stream 0 2] eq "KV_"} {
                lappend kv_list [string range $stream 3 end]
            }
        }

        return $kv_list
    }

    method keys {bucket args} {
        my CheckBucketName $bucket
        set spec [list \
            timeout pos_int $_timeout \
        ]

        nats::_parse_args $args $spec

        set stream "KV_${bucket}"
        set subject "\$KV.*.>" ;# bucket is not set in case it comes from a different domain
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
                -headers_only [dict get $watch($watchID) headers_only] \
                -ignore_deletes [dict get $watch($watchID) ignore_deletes] \
                -check_bucket [dict get $watch($watchID) check_bucket] \
                -idle_heartbeat [dict get $watch($watchID) idle_heartbeat] \
                -watch_id $watchID \
                -initial_data [dict get $watch($watchID) initial_data] \
                -last_error [dict get $watch($watchID) last_error] \
            ]

            if {[dict exists $watch($watchID) stream_seq]} {
                dict set options -stream_seq [dict get $watch($watchID) stream_seq]
            }

            set bucket [dict get $watch($watchID) bucket]
            set key [dict get $watch($watchID) key]

            my WatchImpl $bucket $key {*}$options
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

    method CheckBucketName {bucket} {
        if {![regexp {^[a-zA-Z0-9_-]+$} $bucket]} {
            throw {NATS ErrInvalidArg} "Bucket \"$bucket\" is not valid bucket name"
        }
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