# EXAMPLE #8: Key-Value Store usage of watch
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
set conn [nats::connection new "MyNats"]
$conn configure -servers nats://localhost:4222
$conn connect
set js [$conn jet_stream -timeout 2000]
set kv [$js key_value]

set bucket MY_KEY_VALUE

##### WATCH #####

puts "This program will show usage of \"watch\" method.\
\"watch\" is called here with \"-include_history\" flag that will cause all available messages for key \"key1\" to be delivered.\
After that \"end_of_initial_data\" marker will be delivered to distinguish between data that already existed in bucket and new updates.\
There are two more updates made after \"watch\" has started - both will be delivered to \"callback\" method and the seconds one will end this showcase."

# create a new key-value store named "MY_KEY_VALUE" with history of 10 messages per key
puts "\nCreating new bucket named \"$bucket\"..."
$kv add $bucket -history 10

# put (and delete) some values to "key1" key
puts "Setting some history of updates on \"key1\" key..."
$kv put $bucket key1 "hi, it's my FIRST message"
$kv del $bucket key1 ;# delete last value (only to see it in history) - operation of this entry would be "DEL"
$kv put $bucket key1 "hi, it's my SECOND message"

proc callback {status msg} {
    switch -- $status {
        ok {
            puts "There were some errors, but now everything is fine."
        }
        error {
            puts "Got some error: $msg"
        }
        end_of_initial_data {
            puts "\nAll historic data has been received. From now on updates will be displayed."
        }
        "" {
            if {[dict get $msg operation] eq "PUT"} {
                puts "\nGot new value: [dict get $msg value]"
            }
            if {[dict get $msg operation] eq "DEL"} {
                puts "\nGot delete marker"
            }
            if {[dict get $msg value] eq "End program"} {
                set ::end_program true
            }
        }
        default {
            throw error "This should never happen"
        }
    }
}

set watch_id [$kv watch $bucket key1 -callback callback -include_history true]

after 2000 [list $kv put $bucket key1 "Some update for \"key1\""]
after 5000 [list $kv put $bucket key1 "End program"]

vwait ::end_program

##### CLEANUP #####

puts "\nRemoving \"$bucket\" bucket and ending program..."
$kv unwatch $watch_id
$kv del $bucket

$kv destroy
$js destroy
$conn destroy
