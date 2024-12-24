# Copyright (c) 2021-2025 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require uri
package require struct::list

oo::class create ::nats::server_pool {
    variable Servers Conn
    
    constructor {c} {
        set Servers [list] ;# list of dicts working as FIFO queue
        # each dict contains: host port scheme discovered reconnects last_attempt (ms, mandatory), user password auth_token (optional)
        set Conn $c
    }
    
    # used only for URL discovered from the INFO message
    # remember that it carries only IP:port, so no scheme etc
    method add {url} {
        set ns [info object namespace $Conn]
        try {
            set newServer [my parse $url]
        } trap {NATS INVALID_ARG} err {
            ${ns}::log::warn $err ;# very unlikely
            return
        }
        foreach s $Servers {
            if {[dict get $s host] eq [dict get $newServer host] && [dict get $s port] == [dict get $newServer port]} {
                return ;# we already know this server
            }
        }
        dict set newServer discovered true
        set Servers [linsert $Servers 0 $newServer] ;# the current server is always at the end of the list
        ${ns}::log::debug "Added $url to the server pool"
    }
    
    # used by "configure". All or nothing: if at least one URL is invalid, the old configuration stays intact
    method set_servers {urls} {
        set result [list]
        foreach url $urls {
            lappend result [my parse $url] ;# will throw ErrInvalidArg in case of invalid URL - let it propagate
        }
        if {[$Conn cget randomize]} {
            # ofc lsort will mess up the URL list if randomize=false
            # interestingly, it seems that official NATS clients don't check the server list for duplicates
            set result [lsort -unique $result]
            # IMHO official clients do shuffling too often, at least in 3 places! I do it only once 
            set result [struct::list shuffle $result]
        }
        set Servers $result
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
        set ns [info object namespace $Conn]
        while {1} {
            if { [llength $Servers] == 0 } {
                throw {NATS ErrNoServers} "Server pool is empty"
            }
            set attempts [$Conn cget max_reconnect_attempts]
            set wait [$Conn cget reconnect_time_wait]
            #"pop" a server; using struct::queue seems like an overkill for such a small list
            set s [lindex $Servers 0]
            # during initial connecting process we go through the pool only once
            if {[$Conn cget -status] eq $::nats::status_connecting && [dict get $s reconnects]}  {
                throw {NATS ErrNoServers} "No servers available for connection"
            }
            set Servers [lreplace $Servers 0 0]
            # max_reconnect_attempts == -1 means "unlimited". See also selectNextServer in nats.go
            if {$attempts >= 0 && [dict get $s reconnects] >= $attempts} {
                ${ns}::log::debug "Removed [dict get $s host]:[dict get $s port] from the server pool"
                continue
            }
            
            set now [clock milliseconds]
            set last_attempt [dict get $s last_attempt]
            if {$now < $last_attempt + $wait} {
                # other clients simply wait for reconnect_time_wait, but this approach is more precise
                set waiting_time [expr {$wait - ($now - $last_attempt)}]
                ${ns}::log::debug "Waiting for $waiting_time ms before connecting to the next server"
                set timer [after $waiting_time [info coroutine]]
                set reason [yield]
                if {$reason eq "stop" } {
                    # user called "disconnect"
                    after cancel $timer
                    dict set s last_attempt [clock milliseconds]
                    lappend Servers $s
                    throw {NATS STOP_CORO} "Stop coroutine" ;# break from the main loop
                }
            }
            lappend Servers $s
            break
        }
        return [my current_server]
    }
    
    method current_server_connected {ok} {
        set ns [info object namespace $Conn]
        ${ns}::my CancelConnectTimer
        set s [lindex $Servers end]
        if {$ok} {
            dict set s reconnects 0
            dict set s last_attempt 0
        } else {
            dict incr s reconnects
            dict set s last_attempt [clock milliseconds]
        }
        lset Servers end $s
        ${ns}::log::debug "Current server ok=$ok: [dict get $s host]:[dict get $s port] [dict get $s reconnects] reconnects"
    }
    
    method format_credentials {} {
        set s [lindex $Servers end]
        
        set def_user [$Conn cget user]
        set def_pass [$Conn cget password]
        set def_token [$Conn cget token]
        
        if {[dict exists $s user] && [dict exists $s password]} {
            return [list user [json::write string [dict get $s user]] pass [json::write string [dict get $s password]]]
        }
        if {[dict exists $s auth_token]} {
            return [list auth_token [json::write string [dict get $s auth_token]]]
        }
        if {$def_user ne "" && $def_pass ne ""} {
            return [list user [json::write string $def_user] pass [json::write string $def_pass]]
        }
        if {$def_token ne ""} {
            return [list auth_token [json::write string $def_token]]
        }
        throw {NATS ErrAuthorization} "No credentials known for NATS server at [dict get $s host]:[dict get $s port]"
    }
    
    method current_server {} {
        set s [lindex $Servers end]
        return [list [dict get $s host] [dict get $s port] [dict get $s scheme]]
    }
    
    method all_servers {} {
        return $Servers
    }
    
    method clear {} {
        set Servers [list]
    }
    
    method reset_counters {} {
        set new_list [list]
        foreach s $Servers {
            dict set s last_attempt 0
            dict set s reconnects 0
            lappend new_list $s
        }
        set Servers $new_list
    }
}
