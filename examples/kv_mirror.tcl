# EXAMPLE #8: Key-Value Store in a hub/leaf setup
# NATS deployments in edge computing scenarios are usually performed in the hub/leaf setup with different JetStream domains for the 'hub' NATS and 'leaf' NATS
# Required reading:
# https://docs.nats.io/running-a-nats-service/configuration/leafnodes/jetstream_leafnodes
# https://docs.nats.io/running-a-nats-service/nats_admin/jetstream_admin/replication
# ADR-8, especially the chapter "Multi-Cluster and Leafnode topologies"
# https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md#multi-cluster-and-leafnode-topologies

# Before running the example, start 2 NATS servers on localhost:
# 1. nats-server -c ../tests/hub.conf -sd <Hub storage directory>
# 2. nats-server -c ../tests/leaf.conf -sd <Leaf storage directory>

package require nats
package require defer

proc sleep {delay} {
    after $delay {set ::sleepVar 1}
    vwait ::sleepVar
}

puts "Connecting to the 'hub' NATS..."
set conn_hub [nats::connection new "HUB"]
$conn_hub configure -servers nats://localhost:4222 -user acc -password acc
$conn_hub connect
set js_hub [$conn_hub jet_stream -timeout 1000]
puts "Check JS domain: [dict get [$js_hub account_info] domain]"

puts "Connecting to the 'leaf' NATS..."
set conn_leaf [nats::connection new "LEAF"]
$conn_leaf configure -servers nats://localhost:4111 -user acc -password acc
$conn_leaf connect
set js_leaf [$conn_leaf jet_stream -timeout 1000]
puts "Check JS domain: [dict get [$js_leaf account_info] domain]"

puts "Create a KV bucket in the hub..."
set kv_hub [$js_hub create_kv_bucket HUB_BUCKET -history 64]

puts "Populate the bucket wih random values 0-100..."
foreach system {SystemA SystemB} {
    for {set i 0} {$i < 10} {incr i} {
        $kv_hub put "$system.Param-$i" [expr {int(rand()*100)}]
    }
}

puts "Bind to the hub JetStream using the leaf connection..."
set js_leaf_to_hub [$conn_leaf jet_stream -domain hub]
set kv_leaf_to_hub [$js_leaf_to_hub bind_kv_bucket HUB_BUCKET]

set key "SystemA.Param-2"
set value [$kv_leaf_to_hub get_value $key]
puts "$key = $value"

puts "Create a 'leaf' KV bucket that sources a subset of data from HUB_BUCKET - only for SystemB"
set origin [nats::make_kv_origin -bucket HUB_BUCKET -keys SystemB.> -domain hub]
set leaf_kv [$js_leaf create_kv_aggregate SYSTEM_B true [list $origin] -description "Writable filtered KV aggregate"]
puts "Waiting for the 2 NATS servers to sync..."
sleep 1000

puts "Now stop the hub NATS with \[Ctrl+c\]; then press \[Enter\] to continue with the example..."
gets stdin

while {[$conn_hub cget status] ne $nats::status_reconnecting} {
    puts "Waiting for the hub connection to break..."
    sleep 1000
}
$conn_hub destroy
puts "Connection to the hub is lost, but we can still work with the leaf JetStream:"

# the 'defer' package from Tcllib is very useful when you need to release any resources automatically
# it works similarly to the 'defer' keyword in Go
# but we need a proc to demonstrate it
proc dumpBucket {bucket} {
    puts "Get all keys/values from the leaf bucket..."
    # the naive way would be to call [$leaf_kv keys] followed by get_value in a loop
    # but there's another way that generates much less traffic
    array set ::KV_cache {}  ;# it can't be a local array
    set watcher [$bucket watch > -values_array ::KV_cache]
    defer::defer $watcher destroy  ;# stop watching when we leave the proc
    sleep 500
}

dumpBucket $leaf_kv

foreach key [lsort [array names KV_cache]] {
    puts "$key = $KV_cache($key)"
}

puts "Disconnecting..."
$conn_leaf destroy
# JetStream and KV objects created from a connection are destroyed together with the connection
puts "Done! Remember to delete the NATS storage before running the example again"
