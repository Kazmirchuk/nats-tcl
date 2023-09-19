# Copyright (c) 2023 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2023 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

# based on https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md
oo::class create ::nats::key_value {
    variable conn js bucket stream kv_read_prefix kv_write_prefix

    constructor {connection jet_stream domain bucket_name stream_config} {
        set conn $connection
        set status_var "[info object namespace $conn]::status"
        set js $jet_stream
        set bucket $bucket_name
        set stream "KV_$bucket_name"
        set kv_read_prefix [expr {$domain eq "" ? "\$KV.$bucket" : "\$JS.$domain.API.\$KV.$bucket"}]
        set kv_write_prefix $kv_read_prefix
        if {[dict exists $stream_config mirror name]} {
            set mirrored_stream_name [dict get $stream_config mirror name]
            set mirrored_bucket_name [string range $mirrored_stream_name 3 end] ;# remove "KV_" from "KV_bucket_name"
            set kv_write_prefix "\$KV.${mirrored_bucket_name}"

            if {[dict exists $stream_config mirror external api]} {
                set external_api [dict get $stream_config mirror external api]
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
        dict get [my get $key {*}$args] value
    }
    
    method Get {key {revision ""}} {
        #set subject "$kv_read_prefix.$key"
        # TODO test key_value-domain-1
        # nats --trace --js-domain=hub --user acc --password acc --server localhost:4111 stream get KV_MY_HUB_BUCKET -S $KV.MY_HUB_BUCKET.key1
        # Subject $KV.MY_HUB_BUCKET.key1
        #set subject "\$KV.*.$key"
        set subject "\$KV.$bucket.$key"
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
                  updates_only    bool false}
        
        nats::_parse_args $args $spec
        set deliver_policy [expr {$include_history ? "all" : "last_per_subject"}]
        # TODO why use $kv_write_prefix here?
        return [nats::kv_watcher new [self] "$kv_write_prefix.$key_pattern" $stream $deliver_policy $meta_only $callback $ignore_deletes $updates_only]
    }

    method keys {} {
        set w [my watch > -ignore_deletes 1 -meta_only 1]
        set result [${w}::my Gather keys]
        $w destroy
        if {[llength $result] == 0} {
            throw {NATS ErrKeyNotFound} "No keys found in bucket $bucket"  ;# nats.go raises ErrNoKeysFound instead
        }
        return $result
    }
    
    method history {key} {
        set w [my watch $key -include_history 1]
        set result [${w}::my Gather history]
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
    variable subID userCb initDone ignore_deletes updates_only gathering resultList
    # copied from the parent KV bucket, so that the user can destroy it while the watcher is living
    variable conn kv_read_prefix bucket
    
    constructor {kv filter_subject stream deliver_policy meta_only cb ignore_del upd_only} {
        set initDone false  ;# becomes true after the current/historical data has been received
        set gathering ""
        set conn [set ${kv}::conn]
        set kv_read_prefix [set ${kv}::kv_read_prefix]
        set bucket [set ${kv}::bucket]
        set userCb $cb
        set ignore_deletes $ignore_del
        set updates_only $upd_only  ;# TODO
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
        set consumer_info [[set ${kv}::js] add_consumer $stream {*}$consumer_opts]
        if {[dict get $consumer_info num_pending] == 0} {
            after 0 [mymethod InitDone] ;# NB do not call it directly, because the user should be able to call e.g. "history" right after "watch"
        }
        set subID [$conn subscribe $inbox -callback [mymethod SubscriberCb] -dictmsg true -post false]
    }
    destructor {
        $conn unsubscribe $subID
    }
    method InitDone {} {
        set initDone true
        if {$userCb ne ""} {
            after 0 [list {*}$userCb ""]
        }
    }
    method SubscriberCb {subj msg reply} {
        if {[nats::msg idle_heartbeat $msg]} {
            return  ;# not sure yet what to do with idle HBs
        }
        set meta [::nats::_metadata $msg]
        set delta [dict get $meta num_pending]
        set op [nats::header lookup $msg KV-Operation PUT] ;# note that normal PUT entries are delivered using MSG, so they can't have headers
        if {$ignore_deletes} {
            if {$op in {PURGE DEL}} {
                if {$delta == 0 && !$initDone} {
                    
                }
                return
            }
        }
        set key [string range $subj [string length $kv_read_prefix]+1 end]
        set entry [dict create \
            bucket $bucket \
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
                lappend resultList $entry
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
    method Gather {what} {
        set gathering $what ;# keys or history
        set resultList [list]
        nats::_coroVwait [self]::initDone
        return $resultList
    }
}
