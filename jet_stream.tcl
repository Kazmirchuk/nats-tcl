# Copyright (c) 2021-2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# JetStream wire API Reference https://docs.nats.io/reference/reference-protocols/nats_api_reference
# JetStream JSON API Design https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-1.md

oo::class create ::nats::SyncPullRequest {
    variable Conn MsgList Status ID
    
    constructor {} {
        set MsgList [list]
        set Status running ;# one of: running, done, timeout
    }
    method run {conn subject msg timeout batch } {
        set Conn $conn
        set ID [$conn request $subject $msg -dictmsg true -timeout $timeout -max_msgs $batch -callback [mymethod OnMsg]]
        try {
            while {1} {
                nats::_coroVwait [self namespace]::Status ;# wait for 1 message
                set msgCount [llength $MsgList]
                switch -- $Status {
                    timeout {
                        if {$msgCount > 0} {
                            break ;# we've received at least some messages - return them
                        }
                        # it might seem strange to throw ErrTimeout only in this case
                        # but it is consistent with nats.go, see func TestPullSubscribeFetchWithHeartbeat
                        throw {NATS ErrTimeout} "Sync pull request timeout, subject=$subject"
                    }
                    done {
                        # we've received a status message, which means that the pull request is done
                        if {$batch - $msgCount > 1} {
                            # no need to cancel the request if this was the last expected message
                            $Conn cancel_request $ID
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
            return $MsgList
        } finally {
            my destroy
        }
    }
    method OnMsg {timedOut msg} {
        if {$timedOut} {
            # client-side timeout or connection lost; we may have received some messages before
            [info object namespace $Conn]::log::debug "Sync pull request $ID timed out"
            set Status timeout
            return
        }
        set msgStatus [nats::header lookup $msg Status ""]
        switch -- $msgStatus {
            100 {
                return ;# TODO support HB/FC per ADR-9.md ?
            }
            404 - 408 - 409 {
                [info object namespace $Conn]::log::debug "Sync pull request $ID got status message $msgStatus"
                set Status done
            }
            default {
                lappend MsgList $msg
                set Status running
            }
        }
    }
}

oo::class create ::nats::AsyncPullRequest {
    variable Conn Batch UserCb MsgCount ID
    
    constructor {cb} {
        set UserCb $cb
        set MsgCount 0  ;# only user's messages
        set ID 0
    }
    method run {conn subject msg timeout batch} {
        set Conn $conn
        set Batch $batch
        set ID [$conn request $subject $msg -dictmsg true -timeout $timeout -max_msgs $batch -callback [mymethod OnMsg]]
        return [self]
    }
    method OnMsg {timedOut msg} {
        if {$timedOut} {
            # client-side timeout or connection lost; we may have received some messages before
            [info object namespace $Conn]::log::debug "Async pull request $ID timed out"
            after 0 [list {*}$UserCb 1 ""]
            set ID 0 ;# the request has been already cancelled by OldStyleRequest
            my destroy
            return
        }
        set msgStatus [nats::header lookup $msg Status ""]
        switch -- $msgStatus {
            100 {
                return
            }
            404 - 408 - 409 {
                [info object namespace $Conn]::log::debug "Async pull request $ID got status message $msgStatus"
                after 0 [list {*}$UserCb 1 $msg] ;# just like with old-style requests, inform the user that the pull request timed out
                my destroy
            }
            default {
                incr MsgCount
                after 0 [list {*}$UserCb 0 $msg]
                if {$MsgCount == $Batch} {
                    my destroy
                }
            }
        }
    }
    destructor {
        if {$Batch - $MsgCount <= 1 || $ID == 0} {
            return
        }
        # there's a small chance of race here:
        # if the fetch is cancelled after "mymethod OnMsg" has been scheduled in the event loop, it will trigger a background error
        # because the object doesn't exist anymore. But it doesn't lead to any data loss, because the NATS message won't be ACK'ed
        $Conn cancel_request $ID
    }
}

oo::class create ::nats::jet_stream {
    variable Conn Timeout ApiPrefix Domain Trace

    constructor {conn timeout api_prefix domain trace} {
        set Conn $conn
        set Timeout $timeout
        set Trace $trace
        if {$api_prefix ne ""} {
            set ApiPrefix $api_prefix
            return
        }
        set Domain $domain
        if {$domain eq ""} {
            set ApiPrefix "\$JS.API"
        } else {
            set ApiPrefix "\$JS.$domain.API"
        }
    }
    
    method api_prefix {} {
        return $ApiPrefix
    }
    
    # JetStream Direct Get https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-31.md
    method stream_direct_get {stream args} {
        set spec {last_by_subj valid_str null
                  next_by_subj valid_str null
                  seq          int null}
        nats::_parse_args $args $spec

        if [info exists last_by_subj] {
            set reqSubj "$ApiPrefix.DIRECT.GET.$stream.$last_by_subj"
            set reqMsg ""
        } else {
            set reqSubj "$ApiPrefix.DIRECT.GET.$stream"
            set reqMsg [nats::_local2json $spec]
        }
        # ApiRequest assumes that the reply is always JSON which is not the case for DIRECT.GET
        if {$Trace} {
            [info object namespace $Conn]::log::debug ">>> $reqSubj $reqMsg"
        }
        set msg [$Conn request $reqSubj $reqMsg -timeout $Timeout -dictmsg 1]
        if {$Trace} {
            [info object namespace $Conn]::log::debug "<<< $reqSubj $msg"
        }
        set status [nats::header lookup $msg Status 0]
        switch -- $status {
            404 {
                throw {NATS ErrMsgNotFound} "no message found"
            }
            408 {
                throw {NATS ErrInvalidArg} "Invalid request"
            }
        }
        dict set msg seq [nats::header get $msg Nats-Sequence]
        dict set msg time [nats::header get $msg Nats-Time-Stamp]
        dict set msg subject [nats::header get $msg Nats-Subject]
        foreach h {Nats-Sequence Nats-Time-Stamp Nats-Subject Nats-Stream} {
            nats::header delete msg $h
        }
        return $msg
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_get_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_get_response
    # https://docs.nats.io/reference/reference-protocols/nats_api_reference#fetching-from-a-stream-by-sequence
    method stream_msg_get {stream args} {
        set spec {last_by_subj valid_str null
                  next_by_subj valid_str null
                  seq          int null}
        
        set response [my ApiRequest "STREAM.MSG.GET.$stream" [nats::_dict2json $spec $args]]
        set encoded_msg [dict get $response message]
        set data [binary decode base64 [dict lookup $encoded_msg data]]
        if {[$Conn cget -utf8_convert]} {
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

        set subject "$ApiPrefix.CONSUMER.MSG.NEXT.$stream.$consumer"
        
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
                set expires [expr {$timeout >= 20 ? $timeout - 10 : $timeout}] ;# same as in nats.go v1, see func (sub *Subscription) Fetch
                # but in JS v2 they've changed default expires to 30s
            }
        } else {
            if {[info exists expires]} {
                throw {NATS ErrInvalidArg} "-expires requires -timeout"
            }
            set no_wait true
            set timeout $Timeout
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
        
        # both classes self-destruct, when the pull request is done
        if {$callback eq ""} {
            set req [nats::SyncPullRequest new]
        } else {
            set req [nats::AsyncPullRequest new $callback]
        }
        set msg [nats::_local2json $json_spec]
        if {$Trace} {
            [info object namespace $Conn]::log::debug ">>> $subject $msg"
        }
        try {
            return [$req run $Conn $subject $msg $timeout $batch]
        } trap {NATS ErrTimeout} {err errOpts} {
            # only for sync fetches:
            # probably wrong stream/consumer - see also https://github.com/nats-io/nats-server/issues/2107
            # raise a more meaningful ErrConsumerNotFound/ErrStreamNotFound
            my consumer_info $stream $consumer
            # if consumer_info doesn't throw, rethrow the original error
            return -options $errOpts $err
        }
    }
    
    method cancel_pull_request {fetchID} {
        if {![info object isa object $fetchID]} {
            throw {NATS ErrInvalidArg} "Invalid fetch ID $fetchID"
        }
        $fetchID destroy
    }
    
    # different types of ACKs: https://docs.nats.io/using-nats/developer/develop_jetstream/consumers#delivery-reliability
    method ack {message} {
        $Conn publish [nats::msg reply $message] ""
    }

    method ack_sync {message} {
       $Conn request [nats::msg reply $message] "" -timeout $Timeout
    }
    
    method nak {message args} {
        nats::_parse_args $args {
            delay timeout null
        }
        set nack_msg "-NAK"
        if {[info exists delay]} {
            append nack_msg " [nats::_local2json {delay ns null}]"
        }
        $Conn publish [nats::msg reply $message] $nack_msg
    }

    method term {message} {
        $Conn publish [nats::msg reply $message] "+TERM"
    }

    method in_progress {message} {
        $Conn publish [nats::msg reply $message] "+WPI"
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
            set timeout $Timeout
        }
        if {$stream ne ""} {
            nats::header set msg Nats-Expected-Stream $stream
        }
        if {$callback ne ""} {
            return [$Conn request_msg $msg -callback [mymethod PublishCallback $callback] -timeout $timeout -dictmsg false]
        }
        set response [json::json2dict [$Conn request_msg $msg -timeout $timeout -dictmsg false]]
        nats::_checkJsError $response
        return $response ;# fields: stream,seq,duplicate
    }

    method add_consumer {stream args} {
        my AddUpdateConsumer $stream create {*}$args
    }
    method update_consumer {stream args} {
        my AddUpdateConsumer $stream update {*}$args
    }
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_create_request
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_create_response
    method AddUpdateConsumer {stream action args} {
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
                  mem_storage      bool null
                  metadata         metadata null}
                  
        nats::_parse_args $args $spec
        if {[info exists name]} {
            if {![my CheckFilenameSafe $name]} {
                throw {NATS ErrInvalidArg} "Invalid consumer name $name"
            }
            if {[info exists durable_name]} {
                throw {NATS ErrInvalidArg} "-name conflicts with -durable_name"
            }
        }
        # see JetStreamManager.add_consumer in nats.py
        set version_cmp [package vcompare 2.9 [dict get [$Conn server_info] version]]
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

        set jsonDict [dict create stream_name [json::write string $stream] config [nats::_local2json $spec]]
        set version_cmp [package vcompare 2.10 [dict get [$Conn server_info] version]]
        if {$version_cmp < 1} {
            # seems like older NATS servers ignore "action", but let's be safe and send it only if NATS version >= 2.10
            dict set jsonDict action [json::write string $action]
        }
        set response [my ApiRequest $subject [json::write object {*}$jsonDict] $check_subj]
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
        set json_response [$Conn request "$ApiPrefix.CONSUMER.DURABLE.CREATE.$stream.$consumer" $msg -timeout $Timeout -dictmsg false]
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
        return [nats::ordered_consumer new $Conn [self] $stream $consumerConfig $callback $post]
    }
    method add_stream {stream args} {
        return [my AddUpdateStream $stream CREATE {*}$args]
    }
    method update_stream {stream args} {
        return [my AddUpdateStream $stream UPDATE {*}$args]
    }
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_create_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_create_response
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_update_response
    method AddUpdateStream {stream action args} {
        if {![my CheckFilenameSafe $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        # follow the same order of fields as in nats.go/jetstream/stream_config.go
        set spec {
            name                    valid_str null
            description             valid_str null
            subjects                list null
            retention               {enum limits interest workqueue} limits
            max_consumers           int null
            max_msgs                int null
            max_bytes               int null
            discard                 {enum new old} null
            max_age                 ns null
            max_msgs_per_subject    int null
            max_msg_size            int null
            storage                 {enum memory file} file
            num_replicas            int null
            no_ack                  bool null
            duplicate_window        ns null
            mirror                  json null
            sources                 json_list null
            sealed                  bool null
            deny_delete             bool null
            deny_purge              bool null
            allow_rollup_hdrs       bool null
            compression             {enum none s2} null
            first_seq               int null
            subject_transform       json null
            republish               json null
            allow_direct            bool null
            mirror_direct           bool null
            metadata                metadata null}
            
        dict set args name $stream  ;# required by NATS despite having it already in the subject
        # -subjects is normally also required unless we have -mirror or -sources
        # rely on NATS server to check it
        set response [my ApiRequest "STREAM.$action.$stream" [nats::_dict2json $spec $args]]
        # response fields: config, created (timestamp), state, did_create
        set result_config [dict get $response config]
        nats::_ns2ms result_config duplicate_window max_age
        dict set response config $result_config
        return $response
    }
    
    method add_stream_from_json {json_config} {
        set stream_name [dict get [json::json2dict $json_config] name]
        set json_response [$Conn request "$ApiPrefix.STREAM.CREATE.$stream_name" $json_config -timeout $Timeout -dictmsg false]
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
        return [nats::key_value new $Conn [self] $Domain $bucket [dict get $stream_info config]]
    }

    method create_kv_bucket {bucket args} {
        return [my CreateBucket $bucket "" "" false {*}$args]
    }
    method create_kv_aggregate {bucket writable origins args} {
        if {[llength $origins] == 0} {
            throw {NATS ErrInvalidArg} "List of KV origins is required"
        }
        if {![string is boolean -strict $writable]} {
            throw {NATS ErrInvalidArg} "writable = $writable is not a boolean"
        }
        if {"-mirror_name" in $args || "-mirror_domain" in $args} {
            throw {NATS ErrInvalidArg} "-mirror_name and -mirror_domain are not allowed"
        }
        return [my CreateBucket $bucket $writable $origins false {*}$args]
    }
    method create_kv_mirror {name origin args} {
        if {"-mirror_name" in $args || "-mirror_domain" in $args} {
            throw {NATS ErrInvalidArg} "-mirror_name and -mirror_domain are not allowed"
        }
        my CreateBucket $name false $origin true {*}$args
        return
    }
    method CreateBucket {bucket writable origins is_mirror args} {
        my CheckBucketName $bucket
        set streamName "KV_$bucket"
        
        nats::_parse_args $args {
            description     valid_str null
            max_value_size  int null
            history         pos_int 1
            ttl             pos_int null
            max_bucket_size pos_int null
            storage         {enum memory file} file
            num_replicas    int 1
            compression     {enum none s2} null
            mirror_name     valid_str null
            mirror_domain   valid_str null
            metadata        metadata null
        }
        if {$history < 1 || $history > 64} {
            throw {NATS ErrInvalidArg} "History must be between 1 and 64"
        }
        set duplicate_window 120000 ;# 2 min
        if {[info exists ttl] && $ttl < $duplicate_window} {
            set duplicate_window $ttl
        }
        set stream_config [dict create \
            allow_rollup_hdrs true \
            deny_delete true \
            discard new \
            duplicate_window $duplicate_window \
            deny_purge false \
            max_msgs_per_subject $history \
            allow_direct true]
        
        if {[info exists ttl]} {
            dict set stream_config max_age $ttl
        }
        if {[info exists max_value_size]} {
            dict set stream_config max_msg_size $max_value_size
        }
        if {[info exists max_bucket_size]} {
            dict set stream_config max_bytes $max_bucket_size
        }
        foreach opt {description storage num_replicas compression metadata} {
            if {[info exists $opt]} {
                dict set stream_config $opt [set $opt]
            }
        }
        # -mirror_name and -mirror_domain are deprecated; use create_kv_mirror instead
        if {[info exists mirror_name]} {
            set srcArgs [list -name "KV_$mirror_name"]
            if {[info exists mirror_domain]} {
                lappend srcArgs -api "\$JS.$mirror_domain.API"
            }
            dict set stream_config mirror [nats::make_stream_source {*}$srcArgs]
            dict set stream_config mirror_direct true
        } else {
            dict set stream_config subjects "\$KV.$bucket.>"
        }
        
        if {$is_mirror} {
            # this is a KV mirror, it can have only one origin, and you can't bind to it
            # can't check for [llength $origins] != 1 because it's a dict
            dict set stream_config mirror_direct true
            dict unset stream_config subjects
            if [string match "KV_*" $bucket] {
                throw {NATS ErrInvalidArg} "Mirror name must not be KV" ;# ensure users can't bind to it
            }
            set streamName $bucket
            dict set stream_config mirror [my OriginToMirror $origins]
        } else {
            if [llength $origins] {
                # this is a KV aggregate, it can have one or more origins, and you can bind to it
                foreach origin $origins {
                    lappend streamSources [my OriginToSource $origin $bucket]
                }
                dict set stream_config sources $streamSources
                if {$writable} {
                    dict set stream_config deny_delete false
                } else {
                    dict unset stream_config subjects
                }
            }
        }
        set stream_info [my add_stream $streamName {*}$stream_config]
        return [::nats::key_value new $Conn [self] $Domain $bucket [dict get $stream_info config]]
    }

    method OriginToSource {origin new_bucket} {
        dict with origin {
            if {![info exists stream]} {
                set stream "KV_$bucket"
            }
            if {![info exists keys] || [llength $keys] == 0} {
                lappend keys >
            }
            foreach key $keys {
                lappend transforms [nats::make_subject_transform -src "\$KV.$bucket.$key" -dest "\$KV.$new_bucket.$key"]
            }
            set srcArgs [list -name $stream -subject_transforms $transforms]
            if [info exists api] {
                lappend srcArgs -api $api
                if [info exists deliver] {
                    lappend srcArgs -deliver $deliver
                }
            }
            nats::make_stream_source {*}$srcArgs ;# implicit return
        }
    }
    method OriginToMirror {origin} {
        dict with origin {
            set srcArgs [list -name "KV_$bucket"]
            if {[info exists keys] && [llength $keys]} {
                foreach key $keys {
                    lappend transforms [nats::make_subject_transform -src "\$KV.$bucket.$key" -dest "\$KV.$bucket.$key"]
                }
                lappend srcArgs -subject_transforms $transforms
            }
            if [info exists api] {
                lappend srcArgs -api $api
                if [info exists deliver] {
                    lappend srcArgs -deliver $deliver
                }
            }
            nats::make_stream_source {*}$srcArgs ;# implicit return
        }
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
    # nats schema info --yaml io.nats.jetstream.api.v1.account_info_response
    method account_info {} {
        return [my ApiRequest "INFO" ""]
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
            if {$Trace} {
                [info object namespace $Conn]::log::debug ">>> $ApiPrefix.$subj $msg"
            }
            set replyJson [$Conn request "$ApiPrefix.$subj" $msg -timeout $Timeout -dictmsg false -check_subj $checkSubj]
            if {$Trace} {
                [info object namespace $Conn]::log::debug "<<< $ApiPrefix.$subj $replyJson"
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
    if {[dict get $errDict code] == 503} {
        switch -- [dict get $errDict err_code] {
            10039 {
                throw {NATS ErrJetStreamNotEnabledForAccount} $errDescr
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
        metadata {
            # see ADR-33
            if {[dict size $val] == 0} {
                throw {NATS ErrInvalidArg} $errMsg
            }
            set formattedDict [dict map {k v} $val {
                if [string match "_nats*" $k] {
                    throw {NATS ErrInvalidArg} "_nats is a reserved prefix"
                }
                json::write string $v
            }]
            return [json::write object {*}$formattedDict]
        }
        ns {
            # val must be in milliseconds
            return [expr {entier($val*1000*1000)}]
        }
        json {
            return $val
        }
        json_list {
            if {[llength $val] == 0} {
                throw {NATS ErrInvalidArg} $errMsg
            }
            return [json::write array {*}$val]
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
proc ::nats::make_stream_source {args} {
    # the top-level JSON object StreamSource may have a nested ExternalStream object, so the easiest way is to break down the spec into 2
    set streamSourceSpec {
        name           valid_str NATS_TCL_REQUIRED
        opt_start_seq  pos_int   null
        opt_start_time valid_str null
        filter_subject valid_str null
        external       json      null
        subject_transforms json_list null}
        
    set externalStreamSpec {
        api            valid_str null
        deliver        valid_str null}
        
    nats::_parse_args $args [list {*}$streamSourceSpec {*}$externalStreamSpec]
    if [info exists api] {
        set external [nats::_local2json $externalStreamSpec]
    }
    return [nats::_local2json $streamSourceSpec]
}
proc ::nats::make_subject_transform {args} {
    set spec {
        src   valid_str NATS_TCL_REQUIRED
        dest  valid_str NATS_TCL_REQUIRED}
    return [nats::_dict2json $spec $args]
}
proc ::nats::make_republish {args} {
    set spec {
        src   valid_str NATS_TCL_REQUIRED
        dest  valid_str NATS_TCL_REQUIRED
        headers_only bool false}
    return [nats::_dict2json $spec $args]
}
proc ::nats::make_kv_origin {args} {
    set spec {
        stream  valid_str null
        bucket  valid_str NATS_TCL_REQUIRED
        keys    str null
        api     valid_str null
        deliver valid_str null}

    nats::_parse_args $args $spec
    return [nats::_local2dict $spec]
}
