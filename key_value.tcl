# Copyright (c) 2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2023 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# based on https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md
oo::class create ::nats::key_value {
    variable conn js bucket stream kv_read_prefix kv_write_prefix mirrored_bucket

    constructor {connection jet_stream domain bucket_name stream_config} {
        set conn $connection
        set js $jet_stream
        set bucket $bucket_name
        set stream "KV_$bucket_name"
        set kv_read_prefix [expr {$domain eq "" ? "\$KV.$bucket" : "\$JS.$domain.API.\$KV.$bucket"}]
        set kv_write_prefix $kv_read_prefix
        set mirrored_bucket ""
        if {[dict exists $stream_config mirror name]} {
            set mirrored_stream_name [dict get $stream_config mirror name]
            set mirrored_bucket [string range $mirrored_stream_name 3 end] ;# remove "KV_" from "KV_bucket_name"
            set kv_write_prefix "\$KV.${mirrored_bucket}"

            if {[dict exists $stream_config mirror external api]} {
                set external_api [dict get $stream_config mirror external api]
                set kv_write_prefix "${external_api}.\$KV.${mirrored_bucket}"
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
        dict get [my get $key {*}$args] value
    }
    
    method Get {key {revision ""}} {
        #set subject "$kv_read_prefix.$key"
        # TODO test key_value-domain-1
        # nats --trace --js-domain=hub --user acc --password acc --server localhost:4111 stream get KV_MY_HUB_BUCKET -S $KV.MY_HUB_BUCKET.key1
        # Subject $KV.MY_HUB_BUCKET.key1
        #set subject "\$KV.*.$key"
        
        set subject "\$KV.$bucket.$key"
        if {$mirrored_bucket ne ""} {
            set subject "\$KV.$mirrored_bucket.$key"
        }
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
            throw {NATS ErrBucketNotFound} "Bucket $bucket not found"
        }
        # TODO delta
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
    # TODO add revision
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
            throw {NATS BucketNotFound} "Bucket $bucket not found"
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
        
        # TODO why use $kv_write_prefix here? filter_subject = "$kv_write_prefix.$key_pattern" ??
        set filter_subject "\$KV.$bucket.$key_pattern"
        if {$mirrored_bucket ne ""} {
            set filter_subject "\$KV.$mirrored_bucket.$key_pattern"
        }
        set consumerOpts [list -description "KV watcher" -headers_only $meta_only -deliver_policy $deliver_policy -filter_subject $filter_subject]
        if [info exists idle_heartbeat] {
            lappend consumerOpts -idle_heartbeat $idle_heartbeat
        }
        return [nats::kv_watcher new [self] $consumerOpts $callback $ignore_deletes $values_array]
    }

    method keys {} {
        set w [my watch > -ignore_deletes 1 -meta_only 1]
        set ns [info object namespace $w]
        set result [${ns}::my Gather keys]
        $w destroy
        if {[llength $result] == 0} {
            throw {NATS ErrKeyNotFound} "No keys found in bucket $bucket"  ;# nats.go raises ErrNoKeysFound instead
        }
        return $result
    }
    
    method history {key} {
        set w [my watch $key -include_history 1]
        set ns [info object namespace $w]
        set result [${ns}::my Gather history]
        $w destroy
        if {[llength $result] == 0} {
            throw {NATS ErrKeyNotFound} "Key $key not found in bucket $bucket"
        }
        return $result
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
    variable Conn Bucket kv_write_prefix
    
    constructor {kv consumer_opts cb ignore_del arr} {
        set InitDone false  ;# becomes true after the current/historical data has been received
        set Gathering ""
        set kvNS [info object namespace $kv]
        set Conn [set ${kvNS}::conn]
        set Bucket [set ${kvNS}::bucket]
        set stream [set ${kvNS}::stream]
        set js [set ${kvNS}::js]
        set kv_write_prefix [set ${kvNS}::kv_write_prefix]
        set UserCb $cb
        set IgnoreDeletes $ignore_del
        if {$arr ne ""} {
            upvar 2 $arr [self namespace]::ValuesArray
        }
        set Consumer [$js ordered_consumer $stream -callback [mymethod OnMsg] -post false {*}$consumer_opts]
        if {[dict get [$Consumer info] num_pending] == 0} {
            after 0 [mymethod InitStageDone] ;# NB do not call it directly, because the user should be able to call e.g. "history" right after "watch"
        }
    }
    
    destructor {
        $Consumer destroy
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
        #set key [lindex [split $subj .] end] - this would be simple, but keys can have dots!
        set b [lindex [split $kv_write_prefix .] end]
        regexp ".*$b\.(.*)" [nats::msg subject $msg] -> key ;# TODO simplify
        #set key [string range $subj [string length $kv_write_prefix]+1 end]
        #puts "SUBJ: $subj kv_write_prefix: $kv_write_prefix KEY: $key"
        # TODO delta
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
        nats::_coroVwait [self]::InitDone ;# TODO handle if the ordered consumer stops
        return $ResultList
    }
    method consumer {} {
        return $Consumer
    }
}
