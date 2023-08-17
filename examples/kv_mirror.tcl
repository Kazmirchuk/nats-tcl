# EXAMPLE #9: Key-Value Store mirroring and domains

#### FIRST SETUP TWO SERVERS #####
# they use different domains in order to show how to use mirroring between domains
# 1. nats-server -c ./conf/hub.conf
# 2. nats-server -c ./conf/leaf.conf

package require nats

# connect to hub server
set conn_hub [nats::connection new "MyNatsToHub"]
$conn_hub configure -servers nats://localhost:4222 -user acc -password acc
$conn_hub connect
set js_hub [$conn_hub jet_stream]

# connect to leaf server
set conn_leaf [nats::connection new "MyNatsToLeaf"]
$conn_leaf configure -servers nats://localhost:4111 -user acc -password acc
$conn_leaf connect
set js_leaf [$conn_leaf jet_stream]

# connect to leaf server but use "hub" domain
set js_leaf_to_hub [$conn_leaf jet_stream -domain hub]

puts \n
puts "Creating bucket 'kv_hub' in hub server..."
set kv_hub [$js_hub create_kv_bucket kv_hub]

puts "Setting value 'value1' for key 'key1' in 'kv_hub'..."
$kv_hub put key1 value1

set kv_leaf_to_hub [$js_leaf_to_hub bind_kv_bucket kv_hub]
set val [$kv_leaf_to_hub get key1]
puts "Value '[dict get $val value]' was read from 'kv_hub' using leaf connection with specified 'hub' domain..."
puts \n

puts "Creating bucket 'kv_leaf_mirror' (using leaf connection) which mirrors 'kv_hub' from 'hub' domain..."
set kv_leaf [$js_leaf create_kv_bucket kv_leaf_mirror -mirror_name kv_hub -mirror_domain hub]
puts "All messages in 'kv_leaf_mirror' are mirrored from 'kv_hub'"

set history [$kv_leaf history]
puts "Using 'kv_leaf_mirror' we can do all operations e.g. load history: $history"
puts "Reads from 'kv_leaf_mirror' will be direct, but direct write to 'kv_leaf_mirror' is disabled"
puts "All write messages (put, del...) will be send to original 'kv_hub'"
puts "TCL client takes care of that under the hood"
puts \n

puts "Leaf connection and 'kv_leaf_mirror' are used to set value 'val_from_leaf' on key 'key2' on 'kv_hub'"
$kv_leaf put key2 "val_from_leaf"
puts "This value was first set on 'kv_hub' and then propagated to 'kv_leaf_mirror'"

puts "We can check if 'key2' exists on 'kv_hub' and is the same as we set it"
set key2_on_hub [$kv_hub get_value key2]
puts "Value read from 'kv_hub': $key2_on_hub"

# CLEAN UP

$kv_leaf_to_hub destroy
$js_leaf_to_hub destroy

puts "Deleting \"kv_leaf_mirror\" in leaf domain"
$kv_leaf destroy
$js_leaf delete_kv_bucket kv_leaf_mirror
$js_leaf destroy
$conn_leaf destroy

puts "Deleting \"kv_hub\" in hub domain"
$kv_hub destroy
$js_hub delete_kv_bucket kv_hub
$js_hub destroy
$conn_hub destroy

puts \n