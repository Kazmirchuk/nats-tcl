# Copyright (c) 2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2023 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# based on https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md
oo::class create ::nats::key_value {
    variable conn js bucket stream kv_read_prefix kv_write_prefix
    
    variable status_var


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
            set kv_read_prefix "\$KV.$bucket"
        } else {
            set kv_read_prefix "\$JS.$domain_name.API.\$KV.$bucket"
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
    
    method PublishStream {msg} {
        try {
            return [$js publish_msg $msg]
        } trap {NATS ErrNoResponders} err {
            throw {NATS ErrBucketNotFound} "Bucket $bucket not found"
        }
    }
    
    method get {key args} {
        my CheckKeyName $key
        nats::_parse_args $args {
            revision pos_int ""
        }
        try {
            return [my Get $key $revision]
        } trap {NATS ErrKeyDeleted} err {
            # ErrKeyDeleted is an internal error, see also 'method create'
            throw {NATS ErrKeyNotFound} $err
        }
    }
    
    method get_value {key args} {
        return [dict get [my get $key {*}$args] value]
    }
    
    method Get {key {revision ""}} {
        set subject "$kv_read_prefix.$key"
        try {
            if {$revision ne ""} {
                set msg [$js stream_msg_get $stream -seq $revision]
                # not sure under what conditions this may happen, but nats.go does this check
                if {$subject ne [nats::msg subject $msg]} {
                    throw {NATS ErrKeyNotFound} "Expected $subject, got [nats::msg subject $msg]"
                }
            } else {
                set msg [$js stream_msg_get $stream -last_by_subj $subject]
            }
        } trap {NATS ErrMsgNotFound} err {
            throw {NATS ErrKeyNotFound} "Key $key not found in bucket $bucket"
        } trap {NATS ErrStreamNotFound} err {
            throw {NATS ErrBucketNotFound} "Bucket ${bucket} not found"
        }
        
        set entry [dict create \
            bucket $bucket \
            key $key \
            value [nats::msg data $msg] \
            revision [nats::msg seq $msg] \
            created [nats::isotime_to_msec [nats::msg timestamp $msg]] \
            delta "" \
            operation [nats::header lookup $msg KV-Operation PUT]]
        
        if {[dict get $entry operation] in {DEL PURGE}} {
            throw [list NATS ErrKeyDeleted [dict get $entry revision]] "Key $key was deleted or purged"
        }
        return $entry
    }

    method put {key value} {
        my CheckKeyName $key
        try {
            set resp [my PublishStream [nats::msg create "$kv_write_prefix.$key" -data $value]]
            return [dict get $resp seq]
        } trap {NATS ErrNoResponders} err {
            throw {NATS ErrBucketNotFound} "Bucket $bucket not found"
        }
    }

    method create {key value} {
        try {
            return [my update $key $value 0]
        } trap {NATS ErrWrongLastSequence} err {
            # was the key deleted?
            try {
                my Get $key
                # not deleted - rethrow the first error
                throw {NATS ErrWrongLastSequence} $err
            } trap {NATS ErrKeyDeleted} {err errOpts} {
                # unlike Python, Tcl doesn't allow to pass my own data with an error
                # luckily ErrKeyDeleted is internal, and all I need is a revision number
                set revision [lindex [dict get $errOpts -errorcode] end]
                # retry with a proper revision
                return [my update $key $value $revision]
            }
        }
    }

    method update {key value revision} {
        my CheckKeyName $key
        set msg [nats::msg create "$kv_write_prefix.$key" -data $value]
        nats::header set msg Nats-Expected-Last-Subject-Sequence $revision
        set resp [my PublishStream $msg]  ;# throws ErrWrongLastSequence in case of mismatch
        return [dict get $resp seq]
    }

    method delete {key {revision ""}} {
        my CheckKeyName $key
        set msg [nats::msg create "$kv_write_prefix.$key"]
        nats::header set msg KV-Operation DEL
        if {$revision ne "" && $revision > 0} {
            nats::header set msg Nats-Expected-Last-Subject-Sequence $revision
        }
        my PublishStream $msg
        return
    }

    method purge {key} {
        my CheckKeyName $key
        set msg [nats::msg create "$kv_write_prefix.$key"]
        nats::header set msg KV-Operation PURGE Nats-Rollup sub
        my PublishStream $msg
        return
    }

    method revert {key revision} {
        set entry [my get $key -revision $revision]
        return [my put $key [dict get $entry value]]
    }

    method status {} {
        try {
            set stream_info [$js stream_info $stream]
        } trap {NATS ErrStreamNotFound} err {
            throw {NATS BucketNotFound} "Bucket ${bucket} not found"
        }
        return [my StreamInfoToKvInfo $stream_info]
    }

    method watch {key_pattern args} {
        
        set spec {callback        str  ""
                  include_history bool false
                  meta_only       bool false
                  ignore_deletes  bool false}
        
        #updates_only    bool false ??
        nats::_parse_args $args $spec
        set deliver_policy [expr {$include_history ? "all" : "last_per_subject"}]
        # TODO use mirrored_bucket_name ?
        return [nats::kv_watcher new [self] "$kv_read_prefix.$key_pattern" $stream $deliver_policy $meta_only $callback $ignore_deletes]
    }
    
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

    method keys {} {
        set w [my watch > -ignore_deletes 1 -meta_only 1]
        set result [${w}::my Keys]
        $w destroy
        return $result
    }
    method _keys {args} {
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

    method _watch {args} {
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
        set config [dict get $stream_info config]
        
        set kv_info [dict create \
            bucket $bucket \
            bytes [dict get $stream_info state bytes] \
            history [dict get $config max_msgs_per_subject] \
            ttl [dict get $config max_age] \
            values [dict get $stream_info state messages]]

        if {[dict exists $config mirror name]} {
            # in format "KV_some-name"
            dict set kv_info mirror_name [string range [dict get $config mirror name] 3 end]
            if {[dict exists $config mirror external api]} {
                # in format "$JS.some-domain.API"
                set external_api [dict get $config mirror external api]
                dict set kv_info mirror_domain [lindex [split $external_api "."] 1]
            }
        }
        # do it here so that underlying stream config will be at the end
        dict set kv_info stream_config [dict get $stream_info config]
        dict set kv_info stream_state [dict get $stream_info state]
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


    method CheckKeyName {key} {
        if {[string index $key 0] eq "." || \
            [string index $key end] eq "." || \
            [string range $key 0 2] eq "_kv" || \
           ![regexp {^[-/_=\.a-zA-Z0-9]+$} $key]} {
                throw {NATS ErrInvalidArg} "Invalid key name $key"
        }
    }
}
# 2023-05-30T07:06:22.864305Z to milliseconds
proc ::nats::time_to_millis {time} {
  set seconds 0
  if {[regexp -all {^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2}).(\d+)Z$} $time -> year month day hour minute second micro]} {
    scan [string range $micro 0 2] %d millis ;# could be "081" that would be treated as octal number
    set seconds [clock scan "${year}-${month}-${day} ${hour}:${minute}:${second}" -format "%Y-%m-%d %T" -gmt 1]
    return  [expr {$seconds *  1000 + $millis}]
  }

  throw {NATS InvalidTime} "Invalid time format ${time}"
}

oo::class create ::nats::kv_watcher {
    variable subID kv userCb initDone ignore_deletes gathering resultList
    
    constructor {kv_bucket filter_subject stream deliver_policy meta_only cb ignore_del} {
        set initDone false  ;# becomes true after the current/historical data has been received
        set gathering ""
        set kv $kv_bucket
        set conn [set ${kv}::conn]
        set userCb $cb
        set ignore_deletes $ignore_del
        set inbox [$conn inbox]
        # ordered_consumer is a shorthand for several options - taken from nats.py
        # ack_wait is 22h
        set consumer_opts [dict create \
                           -flow_control true \
                           -ack_policy none \
                           -max_deliver 1 \
                           -ack_wait [expr {22*3600*1000}] \
                           -idle_heartbeat 5000 \
                           -num_replicas 1 \
                           -mem_storage true \
                           -deliver_policy $deliver_policy \
                           -deliver_subject $inbox \
                           -filter_subject $filter_subject \
                           -headers_only $meta_only]
        # create an ephemeral push consumer
        [set ${kv}::js] add_consumer $stream {*}$consumer_opts
        set subID [$conn subscribe $inbox -callback [mymethod SubscriberCb] -dictmsg true -post false]
    }
    destructor {
        [set ${kv}::conn] unsubscribe $subID
    }
    method SubscriberCb {subj msg reply} {
        if {[nats::msg idle_heartbeat $msg]} {
            return  ;# not sure yet what to do with idle HBs
        }
        set prefix_len [string length [set ${kv}::kv_read_prefix]]
        set js [set ${kv}::js]
        set meta [$js metadata $msg]
        set delta [dict get $meta num_pending]
        set op [nats::header lookup $msg KV-Operation PUT] ;# note that normal PUT entries are delivered using MSG, so they can't have headers
        
        if {$ignore_deletes} {
            if {$op in {PURGE DEL}} {
                if {$delta == 0 && !$initDone} {
                    set initDone true
                    if {$userCb ne ""} {
                        after 0 [list {*}$userCb ""]
                    }
                }
                return
            }
        }
        set key [string range $subj $prefix_len+1 end]
        set entry [dict create \
            bucket [set ${kv}::bucket] \
            key $key \
            value [nats::msg data $msg] \
            revision [dict get $meta stream_seq] \
            created [dict get $meta timestamp] \
            delta $delta \
            operation $op]
        
        switch -- $gathering {
            keys {
                lappend resultList $key
            }
            history {
                
            }
            default {
                after 0 [list {*}$userCb $entry]
            }
        }
        
        if {$delta == 0 && !$initDone} {
            set initDone true
            if {$userCb ne ""} {
                after 0 [list {*}$userCb ""]
            }
        }
    }
    method Keys {} {
        set gathering keys
        set resultList [list]
        nats::_coroVwait [self object]::initDone
        return $resultList
    }
}
