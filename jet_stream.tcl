# Copyright (c) 2021-2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

oo::class create ::nats::SyncPullRequest {
    variable conn inMsgs reqStatus reqID
    
    constructor {} {
        set inMsgs [list]
        set reqStatus running ;# one of: running, done, timeout
    }
    method run {c subject msg timeout batch } {
        set conn $c
        set reqID [$conn request $subject $msg -dictmsg true -timeout $timeout -max_msgs $batch -callback [mymethod OnMsg]]
        try {
            while {1} {
                nats::_coroVwait [self namespace]::reqStatus ;# wait for 1 message
                set msgCount [llength $inMsgs]
                switch -- $reqStatus {
                    timeout {
                        if {$msgCount > 0} {
                            break ;# we've received at least some messages - return them
                        }
                        # probably wrong stream/consumer - see also https://github.com/nats-io/nats-server/issues/2107
                        throw {NATS ErrTimeout} "Sync pull request timeout, subject=$subject"
                    }
                    done {
                        # we've received a status message, which means that the pull request is done
                        if {$batch - $msgCount > 1} {
                            # no need to cancel the request if this was the last expected message
                            $conn cancel_request $reqID
                        }
                        break
                    }
                    default {
                        if {$msgCount == $batch} {
                            break
                        }
                    }
                }
            }
            return $inMsgs
        } finally {
            my destroy
        }
    }
    method OnMsg {timedOut msg} {
        if {$timedOut} {
            # client-side timeout or connection lost; we may have received some messages before
            [info object namespace $conn]::log::debug "Sync pull request $reqID timed out"
            set reqStatus timeout
            return
        }
        set msgStatus [nats::header lookup $msg Status ""]
        switch -- $msgStatus {
            404 - 408 - 409 {
                [info object namespace $conn]::log::debug "Sync pull request $reqID got status message $msgStatus"
                set reqStatus done
            }
            default {
                lappend inMsgs $msg
                set reqStatus running
            }
        }
    }
}

oo::class create ::nats::AsyncPullRequest {
    variable conn batch_size userCb msgCount reqID
    
    constructor {cb} {
        set userCb $cb
        set msgCount 0  ;# only user's messages
        set reqID 0
    }
    method run {c subject msg timeout batch} {
        set conn $c
        set batch_size $batch
        set reqID [$conn request $subject $msg -dictmsg true -timeout $timeout -max_msgs $batch -callback [mymethod OnMsg]]
        return [self]
    }
    method OnMsg {timedOut msg} {
        if {$timedOut} {
            # client-side timeout or connection lost; we may have received some messages before
            [info object namespace $conn]::log::debug "Async pull request $reqID timed out"
            after 0 [list {*}$userCb 1 ""]
            set reqID 0 ;# the request has been already cancelled by OldStyleRequest
            my destroy
            return
        }
        set msgStatus [nats::header lookup $msg Status ""]
        switch -- $msgStatus {
            404 - 408 - 409 {
                [info object namespace $conn]::log::debug "Async pull request $reqID got status message $msgStatus"
                after 0 [list {*}$userCb 1 $msg] ;# just like with old-style requests, inform the user that the pull request timed out
                my destroy
            }
            default {
                incr msgCount
                after 0 [list {*}$userCb 0 $msg]
                if {$msgCount == $batch_size} {
                    my destroy
                }
            }
        }
    }
    destructor {
        if {$batch_size - $msgCount <= 1 || $reqID == 0} {
            return
        }
        $conn cancel_request $reqID
    }
}

oo::class create ::nats::jet_stream {
    variable conn _timeout api_prefix domain doTrace

    # do NOT call directly! instead use [$connection jet_stream]
    constructor {c t d do_trace} {
        set conn $c
        set _timeout $t ;# avoid clash with -timeout option when using _parse_args
        set domain $d
        if {$d eq ""} {
            set api_prefix \$JS.API
        } else {
            set api_prefix \$JS.$d.API
        }
        set doTrace $do_trace
    }

    # JetStream wire API Reference https://docs.nats.io/reference/reference-protocols/nats_api_reference
    # JetStream JSON API Design https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-1.md

    # JetStream Direct Get https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-31.md
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_get_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_get_response
    method stream_msg_get {stream args} {
        set spec {last_by_subj valid_str null
                  next_by_subj valid_str null
                  seq          int null}

        set response [my ApiRequest "STREAM.MSG.GET.$stream" [nats::_dict2json $spec $args]]
        set encoded_msg [dict get $response message] ;# it is encoded in base64
        set data [binary decode base64 [dict lookup $encoded_msg data]]
        if {[$conn cget -utf8_convert]} {
            # ofc method MSG has "convertfrom" as well, but it has no effect on base64 data, so we need to call "convertfrom" again
            set data [encoding convertfrom utf-8 $data]
        }
        set msg [nats::msg create [dict get $encoded_msg subject] -data $data]
        
        dict set msg seq [dict get $encoded_msg seq]
        dict set msg time [dict get $encoded_msg time]
        set header [binary decode base64 [dict lookup $encoded_msg hdrs]]
        if {$header ne ""} {
            dict set msg header [nats::_parse_header $header]
        }
        return $msg
    }
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_delete_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_delete_response
    method stream_msg_delete {stream args} {
        set spec {no_erase bool true
                  seq      int  NATS_TCL_REQUIRED}
        set response [my ApiRequest "STREAM.MSG.DELETE.$stream" [nats::_dict2json $spec $args]]
        return [dict get $response success]
    }

    # for backwards compatibility; do not confuse with the new "consume" algorithm from JetStream client API 2.0
    method consume {args} {
        return [my fetch {*}$args]
    }
    # Pull Subscribe internals https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-13.md
    # JetStream Subscribe Workflow https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-15.md
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_getnext_request
    method fetch {stream consumer args} {
        if {![my CheckFilenameSafe $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        if {![my CheckFilenameSafe $consumer]} {
            throw {NATS ErrInvalidArg} "Invalid consumer name $consumer"
        }

        set subject "$api_prefix.CONSUMER.MSG.NEXT.$stream.$consumer"
        # TODO add idle_heartbeat
        nats::_parse_args $args {
            timeout timeout null
            batch_size pos_int 1
            expires timeout null
            callback valid_str ""
        }
        # timeout specifies the client-side timeout; if not given, this is a no_wait fetch
        # expires specifies the server-side timeout (undocumented option only for testing)
        if {[info exists timeout]} {
            set no_wait false
            if {![info exists expires]} {
                set expires [expr {$timeout >= 20 ? $timeout - 10 : $timeout}] ;# same as in nats.go
            }
        } else {
            if {[info exists expires]} {
                throw {NATS ErrInvalidArg} "-expires requires -timeout"
            }
            set no_wait true
            set timeout $_timeout
        }
        # implementation in official clients is overly complex and is done in 2 steps:
        # 1. a no_wait fetch
        # 2. followed by a long fetch
        # and they have a special optimized case for batch=1.
        # I don't see a need for such intricacies in this client
        set json_spec {
            expires ns null
            batch   int null
            no_wait bool null
        }
        set batch $batch_size
        # if there are no messages at all, and I send a no_wait request, I get back 404
        # if there are no messages, and I send no_wait=false, I get 408 after the request expires
        # if there are some messages, I get them followed by 408
        # if there are all needed messages, there's no additional status message
        # if we've got no messages:
        # - server-side timeout raises no error, and we return an empty list
        # - client-side timeout raises ErrTimeout - this is consistent with nats.py
        # TODO check on Slack if this is canonical? doesn't look logical
        
        # both classes self-destruct, when the pull request is done
        if {$callback eq ""} {
            set req [nats::SyncPullRequest new]
        } else {
            set req [nats::AsyncPullRequest new $callback]
        }
        return [$req run $conn $subject [nats::_local2json $json_spec] $timeout $batch]
    }
    
    method cancel_pull_request {reqID} {
        $reqID destroy
    }
    
    # different types of ACKs: https://docs.nats.io/using-nats/developer/develop_jetstream/consumers#delivery-reliability
    method ack {message} {
        $conn publish [nats::msg reply $message] ""
    }

    method ack_sync {message} {
       $conn request [nats::msg reply $message] "" -timeout $_timeout
    }
    
    method nak {message args} {
        nats::_parse_args $args {
            delay timeout null
        }
        set nack_msg "-NAK"
        if {[info exists delay]} {
            append nack_msg " [nats::_local2json {delay ns null}]"
        }
        $conn publish [nats::msg reply $message] $nack_msg
    }

    method term {message} {
        $conn publish [nats::msg reply $message] "+TERM"
    }

    method in_progress {message} {
        $conn publish [nats::msg reply $message] "+WPI"
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.pub_ack_response
    method publish {subject message args} {
        set msg [nats::msg create $subject -data $message]
        return [my publish_msg $msg {*}$args]
    }
    method publish_msg {msg args} {
        nats::_parse_args $args {
            timeout timeout null
            callback valid_str ""
            stream valid_str ""
        }
        if {![info exists timeout]} {
            set timeout $_timeout
        }
        if {$stream ne ""} {
            nats::header set msg Nats-Expected-Stream $stream
        }
        if {$callback ne ""} {
            return [$conn request_msg $msg -callback [mymethod PublishCallback $callback] -timeout $timeout -dictmsg false]
        }
        set response [json::json2dict [$conn request_msg $msg -timeout $timeout -dictmsg false]]
        nats::_checkJsError $response
        return $response ;# fields: stream,seq,duplicate
    }

    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_create_request
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_create_response
    method add_consumer {stream args} {
        set spec {name             valid_str null
                  durable_name     valid_str null
                  description      valid_str null
                  deliver_policy   {enum all last new by_start_sequence by_start_time last_per_subject} all
                  opt_start_seq    int null
                  opt_start_time   valid_str null
                  ack_policy       {enum none all explicit} explicit
                  ack_wait         ns null
                  max_deliver      int null
                  filter_subject   valid_str null
                  replay_policy    {enum instant original} instant
                  rate_limit_bps   int null
                  sample_freq      valid_str null
                  max_waiting      int null
                  max_ack_pending  int null
                  flow_control     bool null
                  idle_heartbeat   ns null
                  headers_only     bool null
                  deliver_subject  valid_str null
                  deliver_group    valid_str null
                inactive_threshold ns null
                  num_replicas     int null
                  mem_storage      bool null}
                  
        nats::_parse_args $args $spec
        if {[info exists name]} {
            if {![my CheckFilenameSafe $name]} {
                throw {NATS ErrInvalidArg} "Invalid consumer name $name"
            }
        }
        # see JetStreamManager.add_consumer in nats.py
        set version_cmp [package vcompare 2.9.0 [dict get [$conn server_info] version]]
        set check_subj true
        if {($version_cmp < 1) && [info exists name]} {
            if {[info exists filter_subject] && $filter_subject ne ">"} {
                set subject "CONSUMER.CREATE.$stream.$name.$filter_subject"
                set check_subj false ;# if filter_subject has * or >, it can't pass the check in CheckSubject
            } else {
                set subject "CONSUMER.CREATE.$stream.$name"
            }
        } elseif {[info exists durable_name]} {
            set subject "CONSUMER.DURABLE.CREATE.$stream.$durable_name"
        } else {
            set subject "CONSUMER.CREATE.$stream"
        }

        set msg [json::write object stream_name [json::write string $stream] config [nats::_local2json $spec]]
        set response [my ApiRequest $subject $msg $check_subj]
        set result_config [dict get $response config]
        nats::_ns2ms result_config ack_wait idle_heartbeat inactive_threshold
        dict set response config $result_config
        return $response
    }
    
    method add_pull_consumer {stream consumer args} {
        set config $args
        dict set config durable_name $consumer
        return [my add_consumer $stream {*}$config]
    }
    
    method add_push_consumer {stream consumer deliver_subject args} {
        dict set args durable_name $consumer
        dict set args deliver_subject $deliver_subject
        return [my add_consumer $stream {*}$args]
    }
    
    method add_consumer_from_json {stream consumer json_config} {
        set msg [json::write object stream_name [json::write string $stream] config $json_config]
        set json_response [$conn request "$api_prefix.CONSUMER.DURABLE.CREATE.$stream.$consumer" $msg -timeout $_timeout -dictmsg false]
        set dict_response [json::json2dict $json_response]
        nats::_checkJsError $dict_response
        return $json_response
    }
    
    # no request body
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_delete_response
    method delete_consumer {stream consumer} {
        set response [my ApiRequest "CONSUMER.DELETE.$stream.$consumer" ""]
        return [dict get $response success]  ;# probably will always be true
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_info_response
    method consumer_info {stream consumer} {
        set response [my ApiRequest "CONSUMER.INFO.$stream.$consumer" ""]
        # response fields: name, stream_name, created, config and some others
        set result_config [dict get $response config]
        nats::_ns2ms result_config ack_wait idle_heartbeat inactive_threshold
        dict set response config $result_config
        return $response
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_names_request
    # the schema suggests possibility to filter by subject, but it doesn't work!
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_names_response
    method consumer_names {stream} {
        set response [my ApiRequest "CONSUMER.NAMES.$stream" ""]
        return [dict get $response consumers]
    }
    
    method ordered_consumer {stream args} {
        if {![my CheckFilenameSafe $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        # TODO add max_msgs ?
        set spec {callback       valid_str ""
                  description    valid_str null
                  headers_only   bool null
                  deliver_policy str null
                  idle_heartbeat ns 5000
                  filter_subject valid_str null
                  post           bool true}
        nats::_parse_args $args $spec
        set consumerConfig [nats::_local2dict $spec]
        # remove the args that do not belong to a consumer configuration
        dict unset consumerConfig callback
        dict unset consumerConfig post
        return [nats::ordered_consumer new $conn [self] $stream $consumerConfig $callback $post]
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_create_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_create_response
    method add_stream {stream args} {
        # follow the same order of fields as in https://github.com/nats-io/nats.py/blob/main/nats/js/api.py
        set spec {
            name                    valid_str NATS_TCL_REQUIRED
            description             valid_str null
            subjects                list null
            retention               {enum limits interest workqueue} limits
            max_consumers           int null
            max_msgs                int null
            max_bytes               int null
            discard                 {enum new old} old
            max_age                 ns null
            max_msgs_per_subject    int null
            max_msg_size            int null
            storage                 {enum memory file} file
            num_replicas            int null
            no_ack                  bool null
            duplicate_window        ns null
            sealed                  bool null
            deny_delete             bool null
            deny_purge              bool null
            allow_rollup_hdrs       bool null
            allow_direct            bool null
            mirror                  json null
        }

        if {![my CheckFilenameSafe $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        dict set args name $stream
        # -subjects is normally also required unless we have -mirror or -sources
        # rely on NATS server to check it
        set response [my ApiRequest "STREAM.CREATE.$stream" [nats::_dict2json $spec $args]]
        # response fields: config, created (timestamp), state, did_create
        set result_config [dict get $response config]
        nats::_ns2ms result_config duplicate_window max_age
        dict set response config $result_config
        return $response
    }
    
    method add_stream_from_json {json_config} {
        set stream_name [dict get [json::json2dict $json_config] name]
        set json_response [$conn request "$api_prefix.STREAM.CREATE.$stream_name" $json_config -timeout $_timeout -dictmsg false]
        set dict_response [json::json2dict $json_response]
        nats::_checkJsError $dict_response
        return $json_response
    }
    
    # no request body
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_delete_response
    method delete_stream {stream} {
        set response [my ApiRequest "STREAM.DELETE.$stream" ""]
        return [dict get $response success]  ;# probably will always be true
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_purge_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_purge_response
    # https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-10.md
    method purge_stream {stream args} {
        set spec {filter valid_str null
                  keep   pos_int   null
                  seq    pos_int   null }
        nats::_parse_args $args $spec
        set response [my ApiRequest "STREAM.PURGE.$stream" [nats::_local2json $spec]]
        return [dict get $response purged]
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_info_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_info_response
    method stream_info {stream} {
        set response [my ApiRequest "STREAM.INFO.$stream" ""]
        dict unset response total
        dict unset response offset
        dict unset response limit
        # remaining fields: config, created (timestamp), state
        set result_config [dict get $response config]
        nats::_ns2ms result_config duplicate_window max_age
        dict set response config $result_config
        return $response
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_names_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_names_response
    method stream_names {args} {
        set spec {subject valid_str null}
        nats::_parse_args $args $spec
        set response [my ApiRequest "STREAM.NAMES" [nats::_local2json $spec]]
        if {[dict get $response total] == 0} {
            # in this case "streams" contains JSON null instead of an empty list; this is a bug in NATS server
            return [list]
        }
        return [dict get $response streams]
    }

    method bind_kv_bucket {bucket} {
        my CheckBucketName $bucket
        set stream "KV_$bucket"
        try {
            set stream_info [my stream_info $stream]
        } trap {NATS ErrStreamNotFound} err {
            throw {NATS ErrBucketNotFound} "Bucket $bucket not found"
        }
        if {[dict get $stream_info config max_msgs_per_subject] < 1} {
            throw {NATS ErrBucketNotFound} "Bucket $bucket not found"
        }
        return [nats::key_value new $conn [self] $domain $bucket [dict get $stream_info config]]
    }

    method create_kv_bucket {bucket args} {
        my CheckBucketName $bucket

        nats::_parse_args $args {
            description valid_str null
            max_value_size int null
            history pos_int 1
            ttl pos_int null
            max_bucket_size pos_int null
            storage {enum memory file} file
            num_replicas int 1
            mirror_name valid_str null
            mirror_domain valid_str null
        }
        set duplicate_window 120000 ;# 2 min
        if {[info exists ttl] && $ttl < $duplicate_window} {
            set duplicate_window $ttl
        }
        if {$history < 1 || $history > 64} {
            throw {NATS ErrInvalidArg} "History must be between 1 and 64"
        }
        # TODO allow_direct=true
        set stream_config [dict create \
            allow_rollup_hdrs true \
            deny_delete true \
            discard new \
            duplicate_window $duplicate_window \
            deny_purge false \
            max_msgs_per_subject $history \
            num_replicas $num_replicas \
            storage $storage]
        
        if {[info exists description]} {
            dict set stream_config description $description
        }
        if {[info exists ttl]} {
            dict set stream_config max_age $ttl
        }
        if {[info exists max_value_size]} {
            dict set stream_config max_msg_size $max_value_size
        }
        if {[info exists max_bucket_size]} {
            dict set stream_config max_bytes $max_bucket_size
        }

        if {[info exists mirror_name]} {
            set mirror_info [dict create name [json::write string "KV_$mirror_name"]]
            if {[info exists mirror_domain]} {
                dict set mirror_info external [json::write object api [json::write string "\$JS.$mirror_domain.API"]]
            }
            dict set stream_config mirror [json::write object {*}$mirror_info]
        } else {
            dict set stream_config subjects "\$KV.$bucket.>"
        }

        set stream_info [my add_stream "KV_$bucket" {*}$stream_config]
        return [::nats::key_value new $conn [self] $domain $bucket [dict get $stream_info config]]
    }

    method delete_kv_bucket {bucket} {
        my CheckBucketName $bucket
        set stream "KV_$bucket"
        try {
            return [my delete_stream $stream]
        } trap {NATS ErrStreamNotFound} err {
            throw {NATS ErrBucketNotFound} "Bucket $bucket not found"
        }
    }

    method kv_buckets {} {
        set kv_list [list]
        foreach stream [my stream_names] {
            if {[string range $stream 0 2] eq "KV_"} {
                lappend kv_list [string range $stream 3 end]
            }
        }
        return $kv_list
    }
    
    method empty_kv_bucket {bucket} {
        return [my purge_stream "KV_$bucket"]
    }

    method CheckBucketName {bucket} {
        if {![regexp {^[a-zA-Z0-9_-]+$} $bucket]} {
            throw {NATS ErrInvalidArg} "Invalid bucket name $bucket"
        }
    }
    
    # userCallback args: timedOut pubAck error
    method PublishCallback {userCallback timedOut msg} {
        if {$timedOut} {
            # also in case of no-responders
            after 0 [list {*}$userCallback 1 "" ""]
            return
        }
        set response [json::json2dict $msg]
        if {![dict exists $response error]} {
            after 0 [list {*}$userCallback 0 $response ""]
            return
        }
        # make the same dict as in AsyncError, with extra field err_code
        set js_error [dict get $response error]
        dict set js_error errorMessage [dict get $js_error description]
        dict unset js_error description
        after 0 [list {*}$userCallback 0 "" $js_error]
    }
    # https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md
    # only the Unix variant, also no " [] {}
    method CheckFilenameSafe {str} {
        return [regexp -- {^[-[:alnum:]!#$%&()+,:;<=?@^_`|~]+$} $str]
    }
    method ApiRequest {subj msg {checkSubj true}} {
        try {
            if {$doTrace} {
                [info object namespace $conn]::log::debug ">>> $api_prefix.$subj $msg"
            }
            set replyJson [$conn request "$api_prefix.$subj" $msg -timeout $_timeout -dictmsg false -check_subj $checkSubj]
            if {$doTrace} {
                [info object namespace $conn]::log::debug "<<< $api_prefix.$subj $replyJson"
            }
            set response [json::json2dict $replyJson]
        } trap {NATS ErrNoResponders} err {
            throw {NATS ErrJetStreamNotEnabled} "JetStream is not enabled in the server"
        }
        nats::_checkJsError $response
        dict unset response type ;# no-op if the key doesn't exist
        return $response
    }
}
# see ADR-15 and ADR-17
oo::class create ::nats::ordered_consumer {
    variable Conn Js Stream Config StreamSeq ConsumerSeq Name SubID UserCb Timer PostEvent RetryInterval ConsumerInfo
    # "public" variable
    variable last_error
    
    constructor {connection jet_stream streamName conf cb post} {
        set Conn $connection
        set Js $jet_stream
        set Stream $streamName
        set UserCb $cb
        set StreamSeq 0
        set ConsumerSeq 0
        set Name ""
        set SubID ""
        set Timer "" ;# used both for HB and reset retries
        set RetryInterval 10000 ;# same as in nats.go/jetstream/ordered.go
        set PostEvent $post
        set Config [dict replace $conf \
                    flow_control true \
                    ack_policy none \
                    max_deliver 1 \
                    ack_wait [expr {22 * 3600 * 1000}] \
                    num_replicas 1 \
                    mem_storage true \
                    inactive_threshold 2000]
        set last_error ""
        my Reset
    }
    destructor {
        after cancel $Timer
        if {$SubID eq ""} {
            return
        }
        $Conn unsubscribe $SubID ;# NATS will delete the ephemeral consumer
    }
    method Reset {{errCode ""}} {
        set inbox "_INBOX.[nats::_random_string]"
        dict set Config deliver_subject $inbox
        if {$errCode ne ""} {
            dict set Config deliver_policy by_start_sequence
            set startSeq [expr {$StreamSeq + 1}]
            dict set Config opt_start_seq $startSeq
            my AsyncError $errCode "reset with opt_start_seq = $startSeq due to $errCode"
        }
        if {$errCode eq ""} {
            set ConsumerInfo [$Js add_consumer $Stream {*}$Config] ;# let any error propagate to the caller
        } else {
            # we are working in the background, so all errors must be reported via AsyncError
            try {
                set ConsumerInfo [$Js add_consumer $Stream {*}$Config]
            } trap {NATS ErrStreamNotFound} {err opts} {
                my AsyncError ErrStreamNotFound "stopped due to $err"
                return ;# can't recover from this
            } trap {NATS} {err opts} {
                # most likely ErrTimeout if we're reconnecting to NATS or ErrJetStreamNotEnabled if a JetStream cluster is electing a new leader
                my AsyncError [lindex [dict get $opts -errorcode] 1] "failed to reset: $err"
                if {[$Conn cget status] == $nats::status_closed} {
                    my AsyncError ErrConnectionClosed "stopped"
                    return
                }
                # default delay is 10s to avoid spamming the log with warnings
                my ScheduleReset $errCode $RetryInterval
                return
            }
        }
        
        set Config [dict get $ConsumerInfo config]
        set Name [dict get $ConsumerInfo name]
        set StreamSeq [dict get $ConsumerInfo delivered stream_seq]
        set ConsumerSeq [dict get $ConsumerInfo delivered consumer_seq]
        set SubID [$Conn subscribe $inbox -dictmsg true -callback [mymethod OnMsg] -post false]
        my RestartHbTimer
        [info object namespace $Conn]::log::debug "Ordered consumer $Name subscribed to $Stream, stream_seq = $StreamSeq, filter = [dict get $Config filter_subject]"
    }
    method RestartHbTimer {} {
        after cancel $Timer
        # reset if we don't receive any message within interval*3 ms; works also if somebody deletes the consumer in NATS
        set Timer [after [expr {[dict get $Config idle_heartbeat] * 3}] [mymethod OnMissingHb]]
    }
    method ScheduleReset {errCode {delay 0}} {
        set Name "" ;# make the name blank while reset in is progress
        after cancel $Timer ;# stop the HB timer
        if {$SubID ne ""} {
            $Conn unsubscribe $SubID ;# unsub immediately to avoid OnMsg being called again while reset is in progress
            set SubID ""
        }
        set Timer [after $delay [mymethod Reset $errCode]] ;# due to -post=false we are inside the coroutine, so can't call reset directly
    }
    method OnMsg {subj msg reply} {
        my RestartHbTimer
        if {[nats::msg idle_heartbeat $msg]} {
            set flowControlReply [nats::header lookup $msg Nats-Consumer-Stalled ""]
            if {$flowControlReply ne ""} {
                $Conn publish $flowControlReply ""
            }
            set cseq [nats::header get $msg Nats-Last-Consumer]
            if {$cseq == $ConsumerSeq} {
                return
            }
            my ScheduleReset ErrConsumerSequenceMismatch
            return
        } elseif {[nats::msg flow_control $msg]} {
            $Js ack $msg
            return
        }
        set meta [nats::metadata $msg]
        set cseq [dict get $meta consumer_seq]
        if {$cseq != $ConsumerSeq + 1} {
            my ScheduleReset ErrConsumerSequenceMismatch
            return
        }
        incr ConsumerSeq
        set StreamSeq [dict get $meta stream_seq]
        if {$PostEvent} {
            after 0 [list {*}$UserCb $msg]
        } else {
            {*}$UserCb $msg  ;# only for KV watchers
        }
    }
    method OnMissingHb {} {
        $Conn unsubscribe $SubID
        set SubID ""
        set Name ""
        my Reset ErrConsumerNotActive
    }
    method info {} {
        return $ConsumerInfo
    }
    method name {} {
        return $Name
    }
    method AsyncError {code msg} {
        set logMsg "Ordered consumer [self]: $msg"
        [info object namespace $Conn]::log::warn $logMsg
        set last_error [dict create code [list NATS $code] errorMessage $msg]
    }
}

# these clients have more specific JS errors
# https://github.com/nats-io/nats.go/blob/main/jserrors.go
# https://github.com/nats-io/nats.py/blob/main/nats/js/errors.py
proc ::nats::_checkJsError {msg} {
    if {![dict exists $msg error]} {
        return
    }
    set errDict [dict get $msg error]
    set errDescr [dict get $errDict description]
    
    if {[dict get $errDict code] == 400} {
        switch -- [dict get $errDict err_code] {
            10071 {
                throw {NATS ErrWrongLastSequence} $errDescr
            }
        }
    }
    if {[dict get $errDict code] == 404} {
        switch -- [dict get $errDict err_code] {
            10014 {
                throw {NATS ErrConsumerNotFound} $errDescr
            }
            10037 {
                throw {NATS ErrMsgNotFound} $errDescr
            }
            10059 {
                throw {NATS ErrStreamNotFound} $errDescr
            }
            
        }
    }
    throw [list NATS ErrJSResponse [dict get $errDict code] [dict get $errDict err_code]] $errDescr
}

proc ::nats::_format_json {name val type} {
    set errMsg "Invalid value for the $type option $name : $val"
    switch -- $type {
        valid_str {
            if {[string length $val] == 0} {
                throw {NATS ErrInvalidArg} $errMsg
            }
            return [json::write string $val]
        }
        int - pos_int {
            if {![string is entier -strict $val]} {
                throw {NATS ErrInvalidArg} $errMsg
            }
            return $val
        }
        bool {
            if {![string is boolean -strict $val]} {
                throw {NATS ErrInvalidArg} $errMsg
            }
            return [expr {$val? "true" : "false"}]
        }
        list {
            if {[llength $val] == 0} {
                throw {NATS ErrInvalidArg} $errMsg
            }
            # assume list of strings
            return [json::write array {*}[lmap element $val {
                        json::write string $element
                    }]]
        }
        ns {
            # val must be in milliseconds
            return [expr {entier($val*1000*1000)}]
        }
        json {
            return $val
        }
        default {
            throw {NATS ErrInvalidArg} "Wrong type $type"  ;# should not happen
        }
    }
}

proc ::nats::_format_enum {name val type} {
    set allowed_vals [lrange $type 1 end] ;# drop the 1st element "enum"
    if {$val ni $allowed_vals} {
        throw {NATS ErrInvalidArg} "Invalid value for the enum $name : $val; allowed values: $allowed_vals"
    }
    return [json::write string $val]
}

proc ::nats::_choose_format {name val type} {
    if {[lindex $type 0] eq "enum"} {
        return [_format_enum $name $val $type]
    } else {
        return [_format_json $name $val $type]
    }
}

proc ::nats::_local2json {spec} {
    set json_dict [dict create]
    foreach {name type def} $spec {
        try {
            # is there a local variable with this name in the calling proc?
            set val [uplevel 1 [list set $name]]
            dict set json_dict $name [_choose_format $name $val $type]
            # when the option is called "name", I get TCL READ VARNAME
            # in other cases I get TCL LOOKUP VARNAME
        } trap {TCL READ VARNAME} {err errOpts} - \
          trap {TCL LOOKUP VARNAME} {err errOpts} {
            # no local variable exists, so take a default value from the spec, unless it's required
            if {$def eq "NATS_TCL_REQUIRED"} {
                throw {NATS ErrInvalidArg} "Option $name is required"
            }
            if {$def ne "null"} {
                dict set json_dict $name [_choose_format $name $def $type]
            }
        }
    }
    if {[dict size $json_dict]} {
        json::write indented false
        json::write aligned false
        return [json::write object {*}$json_dict]
    } else {
        return ""
    }
}
proc ::nats::_local2dict {spec} {
    set result [dict create]
    foreach {name type def} $spec {
        try {
            set val [uplevel 1 [list set $name]]
            dict set result $name $val
        } trap {TCL READ VARNAME} {err errOpts} - \
          trap {TCL LOOKUP VARNAME} {err errOpts} {
            # nothing to do
        }
    }
    return $result
}
proc ::nats::_dict2json {spec src} {
    if {[llength $src] % 2} {
        throw {NATS ErrInvalidArg} "Missing value for option [lindex $src end]"
    }
    if {[dict size $src] == 0} {
        return ""
    }
    set json_dict [dict create]
    foreach {k v} $src {
        dict set src_dict [string trimleft $k -] $v
    }
    foreach {name type def} $spec {
        set val [dict lookup $src_dict $name $def]
        if {$val eq "NATS_TCL_REQUIRED"} {
            throw {NATS ErrInvalidArg} "Option $name is required"
        }
        if {$val ne "null"} {
            dict set json_dict $name [_choose_format $name $val $type]
        }
    }
    if {[dict size $json_dict]} {
        json::write indented false
        json::write aligned false
        return [json::write object {*}$json_dict]
    } else {
        return ""
    }
}

# JetStream JSON API returns timestamps/duration in ns; convert them to ms before returning to a user
proc ::nats::_ns2ms {dict_name args} {
    upvar 1 $dict_name d
    foreach k $args {
        if {![dict exists $d $k]} {
            continue
        }
        set val [dict get $d $k]
        if {$val > 0} {
            dict set d $k [expr {entier($val/1000000)}]
        }
    }
}

# metadata is encoded in the reply field:
# V1: $JS.ACK.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<time>.<pending>
# V2: $JS.ACK.<domain>.<account hash>.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<time>.<pending>.<random token>
# NB! I've got confirmation in Slack that as of Feb 2023, V2 metadata is not implemented yet in NATS
proc ::nats::metadata {msg} {
    set mlist [split [dict get $msg reply] .]
    set mdict [dict create \
            stream [lindex $mlist 2] \
            consumer [lindex $mlist 3] \
            num_delivered [lindex $mlist 4] \
            stream_seq [lindex $mlist 5] \
            consumer_seq [lindex $mlist 6] \
            timestamp [lindex $mlist 7] \
            num_pending [lindex $mlist 8]]
    nats::_ns2ms mdict timestamp
    return $mdict
}
