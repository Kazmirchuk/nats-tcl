# EXAMPLE #5: publishing and consuming messages from JetStream
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
set conn [nats::connection new "MyNats"]
$conn configure -servers nats://localhost:4222
$conn connect
# apply 2s timeout to all JS requests
set js [$conn jet_stream -timeout 2000]

# create a stream collecting messages sent to the foo.* and bar.* subjects
$js add_stream MY_STREAM -subjects [list foo.* bar.*]

# messages can be published to the stream using the core "publish" function: 
$conn publish foo.1 "unconfirmed message"
# but better use the JS "publish" function that receives a confirmation from NATS that the message has been received and saved to the disk
set confirm [$js publish foo.1 "confirmed message 1"]
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

$js publish foo.1 "confirmed message 2" -callback jsPublishCallback
vwait ::cbInvoked

# publish_msg is more flexible: you can add message headers and specify the expected stream, if you know it
set msg [nats::msg create foo.1 -data "confirmed message 3"]
set confirm [$js publish_msg $msg -stream MY_STREAM]
puts "Confirmed sequence # [dict get $confirm seq]"

# It is possible to get a message directly from a stream, e.g.:
set msg [$js stream_msg_get MY_STREAM -last_by_subj foo.1]
puts "Message # [nats::msg seq $msg] was published on [nats::msg timestamp $msg]"
# but this is a backdoor reserved only for niche use cases. The standard approach is to create a pull or a push consumer.
# Let's create a pull consumer that receives only messages sent to foo.1 :
set consumer_info [$js add_pull_consumer MY_STREAM PULL_CONSUMER -filter_subject foo.1 -ack_policy all]
puts "Number of pending messages for PULL_CONSUMER: [dict get $consumer_info num_pending]" ;# prints "4"

# Having created a durable consumer, you can now consume messages.
puts "Fetching messages:"
# Fetch just one message:
set msg [$js consume MY_STREAM PULL_CONSUMER]
# They are always returned as dicts regardless of -dictmsg config option.
puts [nats::msg data $msg]
# or a batch of messages:
foreach msg [$js consume MY_STREAM PULL_CONSUMER -batch_size 3] {
    puts [nats::msg data $msg]
}
# remember to acknowledge the consumed message
$js ack $msg
# otherwise NATS will try to redeliver it. In this case it's enough to ack just the last message, because we've specified -ack_policy all
puts "Number of pending messages for PULL_CONSUMER: [dict get [$js consumer_info MY_STREAM PULL_CONSUMER] num_pending]" ;# prints "0"
# the library provides all possible types of NATS ACKs: nak, in_progress, term

# cleanup, so that the example prints reproducible output
$js delete_stream MY_STREAM
$js destroy
$conn destroy
