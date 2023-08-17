# EXAMPLE #7: Key-Value Store usage and management
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
set conn [nats::connection new "MyNats"]
$conn configure -servers nats://localhost:4222
$conn connect
set js [$conn jet_stream -timeout 2000]

set bucket MY_KEY_VALUE

##### BASIC OPERATIONS #####

# create a new key-value store named "MY_KEY_VALUE" with history of 10 messages per key
puts "Creating new bucket named \"$bucket\"..."
set kv [$js create_kv_bucket $bucket -history 10]

# put (and delete) some values to "key1" key
puts "Setting some history of updates on \"key1\" key..."
$kv put key1 "hi, it's my FIRST message"
$kv delete key1 ;# delete last value (only to see it in history) - operation of this entry would be "DEL"
$kv put key1 "hi, it's my SECOND message"
$kv put key1 "hi, it's my THIRD message"

set current_entry [$kv get_value key1]
set current_val [$kv get key1]
puts "\nCurrent value for \"key1\" is: \"$current_entry\""
puts "Current entry for \"key1\" is: \"$current_val\""

set history [$kv history key1]
puts "\nHistory of \"key1\" is: \"$history\""

try {
    $kv create key1 "it won't be set"
} trap {NATS WrongLastSequence} {} {
    puts "\n\"create\" will only work if given key does not exists (or last operation was DEL/PURGE)"
}

try {
    $kv update key1 "it won't be set" 2
} trap {NATS WrongLastSequence} {} {
    puts "\"update\" will only work if last revision is matching revision passed as argument (last revision is \"4\" but we gave \"2\", so it won't update)"
}

##### KV INFO #####

set kv_buckets [$js kv_buckets]
puts "\nAvailable buckets are: $kv_buckets"

set keys [$kv keys]
puts "\nAvailable bucket \"$bucket\" keys are: $keys"

set status [$kv status]
puts "\nBucket \"$bucket\" status like this: $status"

##### CLEANUP #####

puts "\nRemoving \"$bucket\" bucket and ending program..."
$kv destroy
$js delete_kv_bucket $bucket

$js destroy
$conn destroy
