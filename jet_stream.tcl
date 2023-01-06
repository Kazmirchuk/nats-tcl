# Copyright (c) 2021-2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2021 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

oo::class create ::nats::jet_stream {
    variable conn _timeout
    
    # do NOT call directly! instead use connection::jet_stream
    constructor {c t} {
        set conn $c
        set _timeout $t ;# avoid clash with -timeout option when using _parse_args
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

        set response [json::json2dict [$conn request "\$JS.API.STREAM.MSG.GET.$stream" [nats::_dict2json $spec $args] -timeout $_timeout]]
        nats::_checkJsError $response
        set encoded_msg [dict get $response message] ;# it is encoded in base64
        set data [binary decode base64 [dict lookup $encoded_msg data ""]]
        set msg [nats::msg create -subject [dict get $encoded_msg subject] -data $data]
        dict set msg seq [dict get $encoded_msg seq]
        dict set msg time [dict get $encoded_msg time]
        set header [binary decode base64 [dict lookup $encoded_msg hdrs ""]]
        if {$header ne ""} {
            set hdr_dict [nats::_parse_header $header]
            dict set msg header $hdr_dict
        }
        return $msg
    }
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_delete_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_msg_delete_response
    method stream_msg_delete {stream args} {
        set spec {no_erase bool null
                  seq      int NATS_TCL_REQUIRED}

        set response [json::json2dict [$conn request "\$JS.API.STREAM.MSG.DELETE.$stream" [nats::_dict2json $spec $args] -timeout $_timeout]]
        nats::_checkJsError $response
        return [dict get $response success]
    }

    # equivalent to "fetch" in other NATS clients
    # Pull Subscribe internals https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-13.md
    # JetStream Subscribe Workflow https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-15.md
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_getnext_request
    method consume {stream consumer args} {
        if {![${conn}::my CheckSubject $stream]} {
            throw {NATS ErrInvalidArg} "Invalid stream name $stream"
        }
        if {![${conn}::my CheckSubject $consumer]} {
            throw {NATS ErrInvalidArg} "Invalid consumer name $consumer"
        }

        set subject "\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer"

        nats::_parse_args $args {
            timeout timeout null
            callback str ""
            batch_size pos_int 1
            no_wait bool false
        }
        set batch $batch_size

        if {![info exists timeout]} {
            set timeout $_timeout
        }
        if {!$no_wait} {
            # no_wait conflicts with expires
            set expires [expr {$timeout >= 20 ? $timeout - 10 : $timeout}]  ;# same as in nats.go
        }
        
        set message [nats::_local2json {
                    expires ns null
                    batch   int null
                    no_wait bool null}]
        
        set req_opts [list -dictmsg true -timeout $timeout -max_msgs $batch_size]
        if {$callback ne ""} {
            $conn request $subject $message -callback [mymethod ConsumeCb $callback] {*}$req_opts
            return
        }
        set result [$conn request $subject $message {*}$req_opts]
        if {[dict lookup [dict get $result header] Status] == 408} {
            throw {NATS ErrTimeout} [nats::header get $result Description] ;# Request Timeout
        }
        return $result
    }

    method ConsumeCb {userCb timedOut msg} {
        if {!$timedOut} {
            if {[dict lookup [dict get $msg header] Status] == 408} {
                set timedOut 1 ;# Request Timeout
            }
        }
        {*}$userCb $timedOut $msg
    }
    
    # metadata is encoded in the reply field:
    # $JS.ACK.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<time>.<pending>
    method metadata {msg} {
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
    
    # TODO?
    # JetStream Publish Retries on No Responders https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-22.md
    # nats schema info --yaml io.nats.jetstream.api.v1.pub_ack_response
    method publish {subject message args} {
        set msg [nats::msg create -subject $subject -data $message]
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
            $conn request_msg $msg -callback [mymethod PublishCallback $callback] -timeout $timeout
            return
        }
        set response [json::json2dict [$conn request_msg $msg -timeout $timeout]]
        nats::_checkJsError $response
        return $response ;# fields: stream,seq,duplicate
    }

    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_create_request
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_create_response
    method add_consumer {stream args} {
        # what is opt_start_time??
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
        set consumer_config [nats::_local2json $spec]
        set msg [json::write::object stream_name [json::write string $stream] config $consumer_config]
        
        set version_cmp [package vcompare 2.9.0 [dict get [$conn server_info] version]]
        if {($version_cmp < 1) && [info exists name]} {
            ;# starting from NATS 2.9.0, all consumers should have a name
            if {[info exists filter_subject] && $filter_subject ne ">"} {
                set subject "\$JS.API.CONSUMER.CREATE.$stream.$name.$filter_subject"
            } else {
                set subject "\$JS.API.CONSUMER.CREATE.$stream.$name"
            }
        } elseif {[info exists durable_name]} {
            set subject "\$JS.API.CONSUMER.DURABLE.CREATE.$stream.$durable_name"
        } elseif {[info exists name]} {
            # I think, nats.py should do it too
            set subject "\$JS.API.CONSUMER.DURABLE.CREATE.$stream.$name"
        } else {
            set subject "\$JS.API.CONSUMER.CREATE.$stream"  ;# ephemeral consumer
        }
        
        set response [json::json2dict [$conn request $subject $msg -timeout $_timeout]]
        nats::_checkJsError $response
        dict unset response type
        set result_config [dict get $response config]
        nats::_ns2ms result_config ack_wait idle_heartbeat inactive_threshold
        dict set response config $result_config
        return $response
    }
    
    method add_pull_consumer {stream name args} {
        set config $args
        dict set config name $name
        return [my add_consumer $stream {*}$config]
    }
    
    method add_push_consumer {stream name deliver_subject args} {
        dict set args name $name 
        dict set args deliver_subject $deliver_subject
        return [my add_consumer $stream {*}$args]
    }
    
    # no request body
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_delete_response
    method delete_consumer {stream consumer} {
        set response [json::json2dict [$conn request "\$JS.API.CONSUMER.DELETE.$stream.$consumer" "" -timeout $_timeout]]
        nats::_checkJsError $response
        return [dict get $response success]  ;# probably will always be true
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_info_response
    method consumer_info {stream consumer} {
        set response [json::json2dict [$conn request "\$JS.API.CONSUMER.INFO.$stream.$consumer" "" -timeout $_timeout]]
        nats::_checkJsError $response
        dict unset response type
        # remaining fields: name, stream_name, created, config and some others
        set result_config [dict get $response config]
        nats::_ns2ms result_config ack_wait idle_heartbeat inactive_threshold
        dict set response config $result_config
        return $response
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_names_request
    # the schema suggests possibility to filter by subject, but it doesn't work!
    # nats schema info --yaml io.nats.jetstream.api.v1.consumer_names_response
    # TODO: check subject filter not working?
    method consumer_names {stream} {        
        set response [json::json2dict [$conn request "\$JS.API.CONSUMER.NAMES.$stream" "" -timeout $_timeout]]
        nats::_checkJsError $response
        return [dict get $response consumers]
    }

    # nats schema info --yaml io.nats.jetstream.api.v1.stream_create_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_create_response
    # TODO update_stream?
    method add_stream {stream args} {
        # follow the same order of fields as in https://github.com/nats-io/nats.py/blob/main/nats/js/api.py
        set spec {name             valid_str NATS_TCL_REQUIRED
                  description      valid_str null
                  subjects         list NATS_TCL_REQUIRED
                  retention        {enum limits interest workqueue} limits
                  max_consumers    int null
                  max_msgs         int null
                  max_bytes        int null
                  discard          {enum new old} old
                  max_age          ns null
              max_msgs_per_subject int null
                  max_msg_size     int null
                  storage          {enum memory file} file
                  num_replicas     int null
                  no_ack           bool null
                  duplicate_window ns null
                  sealed           bool null
                  deny_delete      bool null
                  deny_purge       bool null
                 allow_rollup_hdrs bool null
                  allow_direct     bool null
                  mirror_direct    bool null}
        
        dict set args name $stream
        set msg [nats::_dict2json $spec $args]
        set response [json::json2dict [$conn request "\$JS.API.STREAM.CREATE.$stream" $msg -timeout $_timeout]]
        nats::_checkJsError $response
        dict unset response type ;# remaining fields: config, created (timestamp), state, did_create
        set result_config [dict get $response config]
        nats::_ns2ms result_config duplicate_window max_age
        dict set response config $result_config
        return $response
    }
    # no request body
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_delete_response
    method delete_stream {stream} {
        set response [json::json2dict [$conn request "\$JS.API.STREAM.DELETE.$stream" "" -timeout $_timeout]]
        nats::_checkJsError $response
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
        set msg [nats::_local2json $spec]
        set response [json::json2dict [$conn request "\$JS.API.STREAM.PURGE.$stream" $msg -timeout $_timeout]]
        nats::_checkJsError $response
        return [dict get $response purged]
    }
    
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_info_request
    # nats schema info --yaml io.nats.jetstream.api.v1.stream_info_response
    method stream_info {stream} {
        set response [json::json2dict [$conn request "\$JS.API.STREAM.INFO.$stream" "" -timeout $_timeout]]
        nats::_checkJsError $response
        dict unset response type
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
        set msg [nats::_local2json $spec]
        set response [json::json2dict [$conn request "\$JS.API.STREAM.NAMES" $msg -timeout $_timeout]]
        nats::_checkJsError $response
        if {[dict get $response total] == 0} {
            # in this case "streams" contains JSON null instead of an empty list; this is a bug in NATS server
            return [list]
        }
        return [dict get $response streams]
    }
    
    # userCallback args: timedOut pubAck error
    method PublishCallback {userCallback timedOut msg} {
        if {$timedOut} {
            # also in case of no-responders
            after 0 [list {*}$userCallback 1 "" ""]
            return
        }
        set response [json::json2dict $msg]
        if {[dict exists $response error]} {
            # make the same dict as in AsyncError, with extra field err_code
            set js_error [dict get $response error]
            dict set js_error errorMessage [dict get $js_error description]
            dict unset js_error description
            after 0 [list {*}$userCallback 0 "" $js_error]
            return
        }
        after 0 [list {*}$userCallback 0 $response ""]
    }
}

# these clients have more specific JS errors
# https://github.com/nats-io/nats.go/blob/main/jserrors.go
# https://github.com/nats-io/nats.py/blob/main/nats/js/errors.py
# for the Tcl client it's enough to throw ErrJSResponse for all errors from the JS server-side API
proc ::nats::_checkJsError {msg} {
    if {[dict exists $msg error]} {
        set errDict [dict get $msg error]
        throw [list NATS ErrJSResponse [dict get $errDict code] [dict get $errDict err_code]] [dict get $errDict description]
    }
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
            return [expr $val? "true" : "false"]
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
        json::write::indented false
        json::write::aligned false
        return [json::write::object {*}$json_dict]
    } else {
        return ""
    }
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
        json::write::indented false
        json::write::aligned false
        return [json::write::object {*}$json_dict]
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
