# EXAMPLE #7: Key-Value Store usage and management
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
set conn [nats::connection new "KV"]
$conn configure -servers nats://localhost:4222
$conn connect
set js [$conn jet_stream]

set bucket MY_BUCKET

puts "Creating a new bucket $bucket with history of 10 entries per key..."
set kv [$js create_kv_bucket $bucket -history 10]
# or use bind_kv_bucket to connect to a bucket that already exists in NATS

puts "Add a few values to the bucket..."
$kv put key1 "hi, it's my FIRST message"
$kv put city Warsaw
$kv delete key1 ;# inserts an entry with operation=DEL
set revision [$kv put key1 "hi, it's my SECOND message"]
$kv put key1 "hi, it's my THIRD message"

puts "Current value of 'key1' is: [$kv get_value key1]"
set entry [$kv get key1]

puts "A full entry contains:"
puts "bucket = [dict get $entry bucket]"
puts "key = [dict get $entry key]"
puts "value = [dict get $entry value]"
puts "revision = [dict get $entry revision]"  ;# one counter for the whole bucket
puts "timestamp = [nats::msec_to_isotime [dict get $entry created] :localtime]"
puts "operation = [dict get $entry operation]"

set firstEntry [lindex [$kv history key1] 0]
puts "The first value for 'key1' was: [dict get $firstEntry value]"

puts "Entry $revision has value: [$kv get_value key1 -revision $revision]"

puts "All KV buckets: [$js kv_buckets]"

puts "All keys in $bucket: [$kv keys]"

set status [$kv status]
puts "Bucket status contains:"
puts "name = [dict get $status bucket]"
puts "size (bytes) = [dict get $status bytes]"
puts "history per key = [dict get $status history]"
puts "total # of entries = [dict get $status values]"
puts "compression = [dict get $status is_compressed]"
# .. and some other low-level info too

puts "Start watching key 'city' ..."
proc onUpdate {entry} {
    if {$entry eq ""} {
        puts "end of current data"
        return
    }
    puts "Got an update: [dict get $entry value]"
}

# by default, the watcher delivers a current value, then a special empty entry and then further updates as they happen
# but it can be tweaked with options
set watcher [$kv watch city -callback onUpdate]
after 100 [list $kv put city Krakow]
after 200 [list $kv put city Gdansk]

# sleep for 1s
after 1000 [list set untilDone 1]
vwait untilDone

$kv destroy ;# disconnects from the bucket, but it stays in NATS

puts "Deleting $bucket ..."
$js delete_kv_bucket $bucket

$js destroy
$conn destroy
puts "Done"
