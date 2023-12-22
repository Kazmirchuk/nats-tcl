# EXAMPLE #5: publishing and consuming messages from JetStream
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
set conn [nats::connection new "JS_consumers"]
$conn configure -servers nats://localhost:4222
$conn connect
# apply 2s timeout to all JS requests
set js [$conn jet_stream -timeout 2000]

# create a stream collecting messages sent to the foo.* and bar.* subjects
$js add_stream MY_STREAM -subjects [list foo.* bar.*]

# messages can be published to the stream using the core "publish" function: 
$conn publish foo.1 "unconfirmed message on foo.1 - 1"
# but better use the JS "publish" function that receives a confirmation from NATS that the message has been received and saved to the disk
set confirm [$js publish foo.1 "confirmed message on foo.1 - 2"]
puts "Published a message to JetStream with sequence # [dict get $confirm seq]"

# it has an async version too:
proc jsPublishCallback {timedOut pubAck pubError} {
    set ::cbInvoked 1
    
    if {$timedOut} {
        puts "JS publish timed out"
        return
    }
    if {[dict size $pubAck]} {
        puts "Published a message to JetStream with sequence # [dict get $pubAck seq]"
        return
    }
    puts "JS publish error: $pubError"
}

$js publish bar.1 "confirmed message on bar.1 - 1" -callback jsPublishCallback
vwait ::cbInvoked

# publish_msg is more flexible: you can add message headers and specify the expected stream, if you know it
set msg [nats::msg create foo.1 -data "confirmed message on foo.1 - 3"]
set confirm [$js publish_msg $msg -stream MY_STREAM]
puts "Confirmed sequence # [dict get $confirm seq]"

# It is possible to get a message directly from a stream, e.g.:
set msg [$js stream_msg_get MY_STREAM -last_by_subj foo.1]
puts "Message # [nats::msg seq $msg] was published on [nats::msg timestamp $msg]"
# but this is a backdoor reserved only for niche use cases and implementation of Key/Value storage. The standard approach is to create a pull or a push consumer.
# Let's create a pull consumer that receives only messages sent to foo.* :
set consumer_info [$js add_pull_consumer MY_STREAM PULL_CONSUMER -filter_subject foo.* -ack_policy all]
puts "Number of pending messages for PULL_CONSUMER: [dict get $consumer_info num_pending]" ;# prints "3", because one message was published on bar.1

# Having created a durable consumer, you can now consume messages.
puts "Fetching messages:"
# Fetch just one message:
set msg [lindex [$js fetch MY_STREAM PULL_CONSUMER] 0]
# They are always returned as dicts regardless of -dictmsg config option.
puts [nats::msg data $msg]
# or a batch of messages:
foreach msg [$js fetch MY_STREAM PULL_CONSUMER -batch_size 2] {
    puts [nats::msg data $msg]
}
# remember to acknowledge the consumed message, otherwise NATS will try to redeliver it.
# in this case it's enough to ack just the last message, because we've specified -ack_policy all
$js ack_sync $msg

puts "Number of pending messages for PULL_CONSUMER: [dict get [$js consumer_info MY_STREAM PULL_CONSUMER] num_pending]" ;# prints "0"
# the library provides all possible types of NATS ACKs: ack, nak, in_progress, term

# Synadia has deprecated push consumers in JetStream API v2.
# If you need to push-subscribe to a stream nevertheless, the recommended way is to use Ordered Consumers that can handle intermittent failures/disconnections
set orderedConsumer [$js ordered_consumer MY_STREAM -filter_subject bar.* -callback [list pushed_msgs $js]]

proc pushed_msgs {js msg} {
    puts "Got from ordered consumer: [nats::msg data $msg]"
    # no need to ACK, because ordered consumers always have ack_policy=none
}

# sleep for 2s
after 2000 [list set untilDone 1]
vwait untilDone

$orderedConsumer destroy ;# unsubscribe from the stream
$js delete_stream MY_STREAM
# $js destroy - optional - will be destroyed together with the connection object
$conn destroy
