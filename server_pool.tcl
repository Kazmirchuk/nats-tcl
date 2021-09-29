# Copyright (c) 2021 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require uri
package require json::write
package require struct::list

namespace eval ::nats {}

oo::class create ::nats::server_pool {
    variable servers conn
    
    constructor {c} {
        set servers [list] ;# list of dicts working as FIFO queue
        # each dict contains: host port scheme discovered reconnects last_attempt (ms, mandatory), user password auth_token (optional)
        set conn $c
    }
    destructor {
    }
    
    # used only for URL discovered from the INFO message
    # remember that it carries only IP:port, so no scheme etc
    method add {url} {
        try {
            set result [my parse $url]
        } trap {NATS INVALID_ARG} err {
            [$conn logger]::warn $err ;# very unlikely
            return
        }
        foreach s $servers {
            if {[dict get $s host] eq [dict get $result host] && [dict get $s port] == [dict get $result port]} {
                return ;# we already know this server
            }
        }
        dict set result discovered true
        set servers [linsert $servers 0 $result] ;# recall that current server is always at the end of the list
        [$conn logger]::debug "Added $result to the server pool"
    }
    
    # used by "configure". All or nothing: if at least one URL is invalid, the old configuration stays intact
    method set_servers {urls} {
        set result [list]
        foreach url $urls {
            lappend result [my parse $url] ;# will throw INVALID_ARG in case of invalid URL - let it propagate
        }
        # interestingly, it seems that official NATS clients don't check the server list for duplicates
        set result [lsort -unique $result]
        upvar #0 ${conn}::config config
        if {$config(randomize)} {
            # IMHO official clients do shuffling too often, at least in 3 places! I do it only once 
            set result [struct::list shuffle $result]
        }
        set servers $result
    }
    
    method parse {url} {
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
        # NB! starting from version 1.2.7, uri::split throws an error in case of invalid URI
        try {
            array set parsed [uri::split "http://$dummy_url"]
        } on error err {
            throw {NATS ErrInvalidArg} "Invalid URL $url"
        }
        # if the port is not a number, it will end up in "path", e.g. http://foo:202a => path=a
        # so check that the path is empty 
        if {$parsed(host) eq "" || $parsed(path) ne ""} {
            throw {NATS ErrInvalidArg} "Invalid URL $url"
        }
        if {$parsed(port) eq ""} {
            set parsed(port) 4222
        }
        set newServer [dict create scheme $scheme host $parsed(host) port $parsed(port) discovered false reconnects 0 last_attempt 0]
        if {$parsed(user) ne ""} {
            if {$parsed(pwd) ne ""} {
                dict set newServer user $parsed(user)
                dict set newServer password $parsed(pwd)
            } else {
                dict set newServer auth_token $parsed(user)
            }
        }
        return $newServer
    }
    
    method next_server {} {
        upvar #0 ${conn}::config config
        upvar #0 ${conn}::status status
        upvar #0 ${conn}::timers timers
        
        while {1} {
            if { [llength $servers] == 0 } {
                throw {NATS ErrNoServers} "Server pool is empty"
            }
            
            #"pop" a server; using struct::queue seems like an overkill for such a small list
            set s [lindex $servers 0]
            # during initial connecting process we go through the pool only once
            if {$status == $nats::status_connecting && [dict get $s reconnects]}  {
                throw {NATS ErrNoServers} "No servers available for connection"
            }
            set servers [lreplace $servers 0 0]
            # max_reconnect_attempts == -1 means "unlimited". See also selectNextServer in nats.go
            if {$config(max_reconnect_attempts) >= 0 && [dict get $s reconnects] >= $config(max_reconnect_attempts)} {
                [$conn logger]::debug "Removed [dict get $s host]:[dict get $s port] from the server pool"
                continue
            }
            
            set now [clock milliseconds]
            set last_attempt [dict get $s last_attempt]
            if {$now < $last_attempt + $config(reconnect_time_wait)} {
                # other clients simply wait for reconnect_time_wait, but this approach is more precise
                set waiting_time [expr {$config(reconnect_time_wait) - ($now - $last_attempt)}]
                [$conn logger]::debug "Waiting for $waiting_time before connecting to the next server"
                set timer [after $waiting_time [info coroutine]]
                set reason [yield] ;# may be interrupted by a user calling disconnect
                if {$reason eq "stop" } {
                    after cancel $timer
                    dict set s last_attempt [clock milliseconds]
                    lappend servers $s
                    throw {NATS STOP_CORO} "Stop coroutine" ;# break from the main loop
                }
            }
            lappend servers $s
            break
        }
        
        # connect_timeout applies to a connect attempt to one server and includes not only TCP handshake, but also NATS-level handshake
        # and the first PING/PONG exchange to ensure successful authentication
        set timers(connect) [after $config(connect_timeout) [list [info coroutine] connect_timeout]]
        [$conn logger]::debug "Started connection timer $timers(connect)"
        return [my current_server]
    }
    
    method current_server_connected {ok} {
        upvar #0 ${conn}::timers timers
        after cancel $timers(connect)
        [$conn logger]::debug "Cancelled connection timer $timers(connect)"
        set timers(connect) ""
        
        set s [lindex $servers end]
        dict set s last_attempt [clock milliseconds]
        if {$ok} {
            dict set s reconnects 0
        } else {
            dict incr s reconnects
        }
        lset servers end $s
    }
    
    method format_credentials {} {
        upvar #0 ${conn}::config config
        
        set s [lindex $servers end]
        
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
        throw {NATS ErrAuthorization} "No credentials known for NATS server at [dict get $s host]:[dict get $s port]"
    }
    
    method current_server {} {
        set s [lindex $servers end]
        return [list [dict get $s host] [dict get $s port]]
    }
    
    method all_servers {} {
        return $servers
    }
    
    method clear {} {
        set servers [list]
    }
    
    method reset_counters {} {
        set new_list [list]
        foreach s $servers {
            dict set s last_attempt 0
            dict set s reconnects 0
            lappend new_list $s
        }
        set servers $new_list
    }
}
