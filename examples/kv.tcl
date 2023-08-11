# EXAMPLE #7: Key-Value Store usage and management
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
set conn [nats::connection new "MyNats"]
$conn configure -servers nats://localhost:4222
$conn connect
set js [$conn jet_stream -timeout 2000]
set kv [$js key_value]

set bucket MY_KEY_VALUE

##### BASIC OPERATIONS #####

# create a new key-value store named "MY_KEY_VALUE" with history of 10 messages per key
puts "Creating new bucket named \"$bucket\"..."
$kv add $bucket -history 10

# put (and delete) some values to "key1" key
puts "Setting some history of updates on \"key1\" key..."
$kv put $bucket key1 "hi, it's my FIRST message"
$kv del $bucket key1 ;# delete last value (only to see it in history) - operation of this entry would be "DEL"
$kv put $bucket key1 "hi, it's my SECOND message"
$kv put $bucket key1 "hi, it's my THIRD message"

set current_val [$kv get $bucket key1]
puts "\nCurrent value for \"key1\" is: \"[dict get $current_val value]\""
puts "Current entry for \"key1\" is: \"$current_val\""

set history [$kv history $bucket key1]
puts "\nHistory of \"key1\" is: \"$history\""

try {
    $kv create $bucket key1 "it won't be set"
} trap {NATS WrongLastSequence} {} {
    puts "\n\"create\" will only work if given key does not exists (or last operation was DEL/PURGE)"
}

try {
    $kv update $bucket key1 2 "it won't be set"
} trap {NATS WrongLastSequence} {} {
    puts "\"update\" will only work if last revision is matching revision passed as argument (last revision is \"4\" but we gave \"2\", so it won't update)"
}

##### KV INFO #####

set ls [$kv ls]
puts "\nAvailable buckets are: $ls"

set keys [$kv keys $bucket]
puts "\nAvailable bucket \"$bucket\" keys are: $keys"

set info [$kv info $bucket]
puts "\nBucket \"$bucket\" info looks like this: $info"

##### CLEANUP #####

puts "\nRemoving \"$bucket\" bucket and ending program..."
$kv del $bucket

$kv destroy
$js destroy
$conn destroy
