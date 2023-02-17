# EXAMPLE #6: JetStream management: streams and consumers
# remember to start nats-server with -js to enable JetStream and -sd to set the storage directory

package require nats
package require fileutil

set conn [nats::connection new "MyNats"]
$conn configure -servers nats://localhost:4222
$conn connect
set js [$conn jet_stream]

# Create a new stream:
$js add_stream MY_STREAM -subjects [list subject1.* subject2.*] -retention limits -max_msgs 100 -discard old
# Create a stream with a configuration from a JSON file (compatible with NATS CLI)
#set config_dict [json::json2dict [fileutil::cat [file join [file dirname [info script]] stream_config.json]]]
#$js add_stream MY_STREAM2 {*}$config_dict

#$js delete_stream my_stream

# Purge stream (delete all messages) can be done by calling method purge_stream:
#$jet_stream purge_stream my_stream


puts "List all streams: [$js stream_names]"
puts "Find the stream that listens to subject1.* : [$js stream_names -subject subject1.*]"
puts "Info about MY_STREAM: [$js stream_info MY_STREAM]"



# Adding a consumer can be done by calling the add_consumer method.
# Adding a pull consumer requires durable_name argument.
#$jet_stream add_consumer my_stream -durable_name my_consumer_pull -ack_policy explicit 
#
## It is possible to provide all agruments supported by NATS.
## By method add_consumer you can also add a push consumers durable and ephemeral.
## To add a push consumer you need to provide deliver_subject.
## Adding a durable push consumer:
#$jet_stream add_consumer my_stream -deliver_subject my_consumer_push_durable -durable_name my_consumer_push_durable
#
## Adding an ephemeral push consumer:
#$jet_stream add_consumer my_stream -deliver_subject ephemeral_consumer
#
## Deleting a consumer can be done by calling method delete_consumer:
#$jet_stream delete_consumer my_stream my_consumer_push_durable
#
## Checking all exisiting consumer names for stream can be done by method consumer_names:
#$jet_stream consumer_names my_stream
#
## Checking consumer info for all stream consumers or selected one can be done by method consumer_info:
#$jet_stream consumer_info my_stream my_consumer_push_durable
#
## All above stream and consumer methods can have timeout defined (-timeout argument) and can be used in the asynchronous manner by providing argument -callback:
#proc addConsumerCallback {timedOut msg error} {
#    # if "error" is not empty it is a dict containing decoded JSON from NATS server
#    # if "error" is empty, publish was successfull and "pubAck" is a dict containing action result e.g. added consumer configuration
#}

$js delete_stream MY_STREAM
#$js delete_stream MY_STREAM2

$js destroy
$conn destroy
