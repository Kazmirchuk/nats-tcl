# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package require uri
package require struct::list
package require json::write

# rename server_pool ""
namespace eval ::nats {
oo::class create server_pool {
    variable servers ;# list of dicts working as FIFO queue
    # each dict contains: host port scheme discovered reconnects last_attempt (mandatory), user password auth_token (optional)
    constructor {} {
        puts "pool created"
    }
    
    destructor {
        puts "pool destroyed"   
    }
    
    method add {url {discovered false}} {
        # replace nats/tls scheme with http and delegate parsing to the uri package
        set scheme nats
        if {[string equal -length 7 $url "nats://"]} {
            set dummy_url [string range $url 7 end]
        } elseif {[string equal -length 6 $url "tls://"]} {
            set dummy_url [string range $url 6 end]
            set scheme tls
        } else {
            set dummy_url $url
        }
        
        #uri::split will return a dict with these keys: scheme, host, port, user, pwd (and others)
        # note that these keys will always be present even if empty
        array set parsed [uri::split "http://$dummy_url"]
        if {$parsed(host) eq ""} {
            throw {NATS INVALID_ARG} "Invalid URL $url"
        }
        if {$parsed(port) eq ""} {
            set parsed(port) 4222
        }
        #check for duplicates!
        
        set newServer [dict create scheme $scheme host $parsed(host) port $parsed(port) discovered $discovered reconnects 0 last_attempt 0]
        if {$parsed(user) ne ""} {
            if {$parsed(pwd) ne ""} {
                dict set newServer user $parsed(user)
                dict set newServer password $parsed(pwd)
            } else {
                dict set newServer auth_token $parsed(user)
            }
        }
        lappend servers $newServer
        return $newServer
    }
    
    method next_server {conf_arr} {
        upvar $conf_arr config
        
        while {1} {
            if { [llength $servers] == 0 } {
                throw {NATS NO_SERVERS} "No servers available for connection"
            }
            set now [clock seconds]
            #"pop" a server; using struct::queue seems like an overkill for such a small list
            set s [lindex $servers 0]
            set servers [lreplace $servers 0 0]
            if {$config(max_reconnect_attempts) > 0 && [dict get $s reconnects] > $config(max_reconnect_attempts)} {
                continue ;# remove the server from the pool
            }
            
            if {$now < [expr {[dict get $s last_attempt] + $config(reconnect_time_wait)}]} {
                coroutine::util after $config(reconnect_time_wait)
            }
            dict set s last_attempt [clock seconds]
            lappend servers $s
            break
        }
        return [dict get $s host] [dict get $s port]
    }
    
    method current_server_connected {ok} {
        set s [my current_server]
        dict set s last_attempt [clock seconds]
        if {$ok} {
            dict set s reconnects 0
        } else {
            dict incr s reconnects
        }
        lset servers end $s
    }
    
    method format_credentials {conf_arr} {
        upvar $conf_arr config
        set s [my current_server]
        set result [list]
        
        if {[dict exists $s user] && [dict exists $s password]} {
            return [list user [json::write::string [dict get $s user]] pass [json::write::string [dict get $s password]]]
        }
        if {[dict exists $s auth_token]} {
            return [list auth_token [json::write::string [dict get $s auth_token]]]
        }
        if {$config(user) ne "" && $config(password) ne ""} {
            return [list user [json::write::string $config(user)] pass [json::write::string $config(password)]]
        }
        if {$config(token) ne ""} {
            return [list auth_token [json::write::string $config(token)]]
        }
        throw {NATS NO_CREDS} "No credentials known for NATS server at [dict get $s host]:[dict get $s port]"
    }
    
    method shuffle {} {
        set servers [::struct::list shuffle $servers]
    }
    
    method current_server {} {
        return [lindex $servers end]
    }
    
    method all_servers {} {
        return $servers
    }
    
    method discovered_servers {} {
        set result [list]
        foreach s $servers {
            if {[dict get $s discovered]} {
                lappend result $s
            }
        }
        return $result
    }
} ;# end of class server_pool
} ;# end of namespace
