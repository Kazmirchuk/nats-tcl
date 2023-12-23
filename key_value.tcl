# Copyright (c) 2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2023 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# based on https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md
oo::class create ::nats::key_value {
    variable Conn Js Bucket Stream ReadPrefix WritePrefix UseJsPrefix UseDirect ;# mirrored_bucket

    constructor {connection jet_stream domain bucket_name stream_config} {
        set Conn $connection
        set Js $jet_stream
        set Bucket $bucket_name
        set Stream "KV_$Bucket"
        # since keys work on top of subjects, using mirrors, JS domains or API import prefixes affects ReadPrefix and WritePrefix
        # see also nats.go, func mapStreamToKVS
        # ADR-19 https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-19.md
        # https://github.com/nats-io/nats-architecture-and-design/issues/167
        # however, ADR-8 v1.1 deprecates this approach and uses subject transforms instead
        
        set ReadPrefix "\$KV.$Bucket"
        set WritePrefix $ReadPrefix
        set UseJsPrefix false
        
        if { [$Js api_prefix] ne "\$JS.API"} {
            set UseJsPrefix true
        }
        set UseDirect [dict get $stream_config allow_direct]

        if {[dict exists $stream_config mirror name]} {
            set originStream [dict get $stream_config mirror name]
            set originBucket [string range $originStream 3 end] ;# remove "KV_" from "KV_bucket_name"
            set WritePrefix "\$KV.$originBucket"
            if {[dict exists $stream_config mirror external api]} {
                set UseJsPrefix false
                set ReadPrefix "\$KV.$originBucket"
                set externalApi [dict get $stream_config mirror external api]
                set WritePrefix "$externalApi.\$KV.$originBucket"
            }
        }
    }
    destructor {
        $Js releaseRef [self]
    }
    method PublishToStream {key {value ""} {hdrs ""}} {
        my CheckKeyName $key
        if {$UseJsPrefix} {
            append subject "[$Js api_prefix]."
        }
        append subject "$WritePrefix.$key"
        set msg [nats::msg create $subject -data $value]
        if {$hdrs ne ""} {
            dict set msg header $hdrs
        }
        try {
            return [$Js publish_msg $msg]
        } trap {NATS ErrNoResponders} err {
            throw {NATS ErrBucketNotFound} "Bucket $Bucket not found"
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
        dict get [my get $key {*}$args] value
    }
    
    method Get {key {revision ""}} {
        set subject "$ReadPrefix.$key"
        if {$UseDirect} {
            set methodName stream_direct_get
        } else {
            set methodName stream_msg_get
        }
        try {
            if {$revision ne ""} {
                set msg [$Js $methodName $Stream -seq $revision]
                # not sure under what conditions this may happen, but nats.go does this check
                if {$subject ne [nats::msg subject $msg]} {
                    throw {NATS ErrKeyNotFound} "Expected $subject, got [nats::msg subject $msg]"
                }
            } else {
                set msg [$Js $methodName $Stream -last_by_subj $subject]
            }
        } trap {NATS ErrMsgNotFound} err {
            throw {NATS ErrKeyNotFound} "Key $key not found in bucket $Bucket"
        } trap {NATS ErrStreamNotFound} err {
            # looks like a bug or design flaw in nats-server that only STREAM.MSG.GET can reply with ErrStreamNotFound; requests to DIRECT.GET simply time out
            # which is not a real problem because we get here only if somebody else deletes the bucket *after* we've bound to it
            throw {NATS ErrBucketNotFound} "Bucket $Bucket not found"
        }
        # we know the delta only when using the KV watcher; same in nats.go
        set entry [dict create \
            bucket $Bucket \
            key $key \
            value [nats::msg data $msg] \
            revision [nats::msg seq $msg] \
            created [nats::isotime_to_msec [nats::msg timestamp $msg]] \
            operation [nats::header lookup $msg KV-Operation PUT]]
        
        if {[dict get $entry operation] in {DEL PURGE}} {
            throw [list NATS ErrKeyDeleted [dict get $entry revision]] "Key $key was deleted or purged"
        }
        return $entry
    }

    method put {key value} {
        try {
            return [dict get [my PublishToStream $key $value] seq]
        } trap {NATS ErrNoResponders} err {
            throw {NATS ErrBucketNotFound} "Bucket $Bucket not found"
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
        # nats.go Update doesn't use WritePrefix - seems like their bug
        set header [dict create Nats-Expected-Last-Subject-Sequence $revision]
        set resp [my PublishToStream $key $value $header] ;# throws ErrWrongLastSequence in case of mismatch
        return [dict get $resp seq]
    }

    method delete {key {revision ""}} {
        set header [dict create KV-Operation DEL]
        if {$revision ne "" && $revision > 0} {
            dict set header Nats-Expected-Last-Subject-Sequence $revision
        }
        my PublishToStream $key "" $header
        return
    }
    
    method purge {key} {
        my PublishToStream $key "" [dict create KV-Operation PURGE Nats-Rollup sub]
        return
    }

    method revert {key revision} {
        set entry [my get $key -revision $revision]
        return [my put $key [dict get $entry value]]
    }

    method status {} {
        try {
            set stream_info [$Js stream_info $Stream]
        } trap {NATS ErrStreamNotFound} err {
            throw {NATS BucketNotFound} "Bucket $Bucket not found"
        }
        return [my StreamInfoToKvInfo $stream_info]
    }

    method watch {key_pattern args} {
        
        set spec {callback        str  ""
                  include_history bool false
                  meta_only       bool false
                  ignore_deletes  bool false
                  updates_only    bool false
                  values_array    str  ""
                  idle_heartbeat  str  null}
        
        nats::_parse_args $args $spec
        if {$include_history && $updates_only} {
            throw {NATS ErrInvalidArg} "-include_history conflicts with -updates_only"
        }
        set deliver_policy [expr {$include_history ? "all" : "last_per_subject"}]
        if {$updates_only} {
            set deliver_policy "new"
        }

        set filter_subject "$ReadPrefix.$key_pattern"
        set consumerOpts [list -description "KV watcher" -headers_only $meta_only -deliver_policy $deliver_policy -filter_subject $filter_subject]
        if [info exists idle_heartbeat] {
            lappend consumerOpts -idle_heartbeat $idle_heartbeat
        }
        set watcher [nats::kv_watcher new [self] $consumerOpts $callback $ignore_deletes $values_array]
        $Js addRef $watcher
        return $watcher
    }

    method keys {} {
        set w [my watch > -ignore_deletes 1 -meta_only 1]
        set ns [info object namespace $w]
        set result [${ns}::my Gather keys]
        $w destroy
        if {[llength $result] == 0} {
            throw {NATS ErrKeyNotFound} "No keys found in bucket $Bucket"  ;# nats.go raises ErrNoKeysFound instead
        }
        return $result
    }
    
    method history {key} {
        set w [my watch $key -include_history 1]
        set ns [info object namespace $w]
        set result [${ns}::my Gather history]
        $w destroy
        if {[llength $result] == 0} {
            throw {NATS ErrKeyNotFound} "Key $key not found in bucket $Bucket"
        }
        return $result
    }

    method StreamInfoToKvInfo {stream_info} {
        set config [dict get $stream_info config]
        set isCompressed [expr {[dict lookup $config compression none] ne "none"}]
        
        set kv_info [dict create \
            bucket $Bucket \
            bytes [dict get $stream_info state bytes] \
            history [dict get $config max_msgs_per_subject] \
            ttl [dict get $config max_age] \
            values [dict get $stream_info state messages] \
            is_compressed $isCompressed]

        if {[dict exists $config mirror name]} {
            # strip the leading "KV_"
            dict set kv_info mirror_name [string range [dict get $config mirror name] 3 end]
            if {[dict exists $config mirror external api]} {
                # in format "$JS.some-domain.API" unless it is imported from another account
                set externalApi [split [dict get $config mirror external api] .]
                if {[llength $externalApi] == 3 && [lindex $externalApi 2] eq "API"} {
                    dict set kv_info mirror_domain [lindex $externalApi 1]
                }
            }
        }
        # do it here so that underlying stream config will be at the end
        dict set kv_info stream_config [dict get $stream_info config]
        dict set kv_info stream_state [dict get $stream_info state]
        return $kv_info
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

oo::class create ::nats::kv_watcher {
    # watcher options/vars
    variable SubID UserCb InitDone IgnoreDeletes Gathering ResultList ValuesArray Consumer
    # copied from the parent KV bucket, so that the user can destroy it while the watcher is living
    variable Conn Bucket PrefixLen Js
    
    constructor {kv consumer_opts cb ignore_del arr} {
        set InitDone false  ;# becomes true after the current/historical data has been received
        set Gathering ""
        set kvNS [info object namespace $kv]
        set Conn [set ${kvNS}::Conn]
        set Bucket [set ${kvNS}::Bucket]
        set stream [set ${kvNS}::Stream]
        set Js [set ${kvNS}::Js]
        set PrefixLen [string length [set ${kvNS}::ReadPrefix]]
        set UserCb $cb
        set IgnoreDeletes $ignore_del
        if {$arr ne ""} {
            upvar 2 $arr [self namespace]::ValuesArray
        }
        try {
            set Consumer [$Js ordered_consumer $stream -callback [nats::mymethod OnMsg] -post false {*}$consumer_opts]
        } trap {NATS ErrStreamNotFound} err {
            throw {NATS BucketNotFound} "Bucket $Bucket not found"
        }
        if {[dict get [$Consumer info] num_pending] == 0} {
            after 0 [nats::mymethod InitStageDone] ;# NB do not call it directly, because the user should be able to call e.g. "history" right after "watch"
        }
    }
    
    destructor {
        if {[info exists Consumer]} {
            $Consumer destroy ;# account for the case when ordered_consumer throws, like in test key_value_watchers-watch-5
        }
        $Js releaseRef [self]
    }
    
    method InitStageDone {} {
        set InitDone true
        if {$UserCb ne ""} {
            after 0 [list {*}$UserCb ""]
        }
    }
    
    method OnMsg {msg} {
        set meta [::nats::metadata $msg]
        set delta [dict get $meta num_pending]
        set op [nats::header lookup $msg KV-Operation PUT] ;# note that normal PUT entries are delivered using MSG, so they can't have headers
        if {$IgnoreDeletes} {
            if {$op in {PURGE DEL}} {
                if {$delta == 0 && !$InitDone} {
                    my InitStageDone
                }
                return
            }
        }
        set key [string range [nats::msg subject $msg] $PrefixLen+1 end]
        set entry [dict create \
            bucket $Bucket \
            key $key \
            value [nats::msg data $msg] \
            revision [dict get $meta stream_seq] \
            created [dict get $meta timestamp] \
            delta $delta \
            operation $op]
        
        switch -- $Gathering {
            keys {
                lappend ResultList $key
            }
            history {
                lappend ResultList $entry
            }
            default {
                if {$UserCb ne ""} {
                    after 0 [list {*}$UserCb $entry]
                }
                if {[info exists ValuesArray]} {
                    if {$op eq "PUT"} {
                        set ValuesArray($key) [dict get $entry value]
                    } else {
                        unset ValuesArray($key)
                    }
                }
            }
        }
        
        if {$delta == 0 && !$InitDone} {
            my InitStageDone
        }
    }
    
    method Gather {what} {
        set Gathering $what ;# keys or history
        set ResultList [list]
        set timerID [after [$Js timeout] [list set [self namespace]::InitDone "timeout"]]
        nats::_coroVwait [self namespace]::InitDone
        if {$InitDone eq "timeout"} {
            throw {NATS ErrTimeout} "Timeout while gathering $what in bucket $Bucket"
        }
        after cancel $timerID
        return $ResultList
    }
    method consumer {} {
        return $Consumer
    }
}
proc ::nats::make_kv_origin {args} {
    set spec {
        stream  valid_str null
        bucket  valid_str NATS_TCL_REQUIRED
        keys    str null
        api     valid_str null
        deliver valid_str null
        domain  valid_str null}

    nats::_parse_args $args $spec
    if {[info exists domain]} {
        if {[info exists api]} {
            throw {NATS ErrInvalidArg} "-domain and -api are mutually exclusive"
        }
        set api "\$JS.$domain.API"
        unset domain
    }
    return [nats::_local2dict $spec]
}
