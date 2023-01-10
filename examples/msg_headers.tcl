# EXAMPLE #4: sending and receiving messages with headers; using nats::msg and nats::header ensembles

package require nats
set conn [nats::connection new "MyNats"]
# note the -dictmsg true option that allows the callback to receive messages with all data, not just payload
$conn configure -servers nats://localhost:4222 -dictmsg true

$conn connect

# define a callback for incoming messages
proc onMessage {subject message replyTo} {
    puts "Received a message on subject: $subject"
    puts "Headers:"
    foreach key [nats::header keys $message] {
        # in a general case a message may have headers with duplicate keys - use [nats::header values] to handle this
        # here we know apriori there's only one value per key
        puts "$key: [nats::header get $message $key]"
    }
    set encoding_name [nats::header get $message encoding]
    set encoded_payload [nats::msg data $message]
    puts "Payload: [encoding convertfrom $encoding_name $encoded_payload]"
}

$conn subscribe hdr_demo -callback onMessage

# create a message to be sent out; only a subject is mandatory. NATS messages may have empty payload
set msg [nats::msg create hdr_demo]
# add a couple of header fields and a payload. A realistic use case could be specifying the payload's encoding in a header, like in HTTP
nats::header set msg counter 1 encoding ascii
nats::msg set msg -data "Hello $tcl_platform(user)"
# and publish it
$conn publish_msg $msg 

# now send a message with UTF-8 encoding
nats::header set msg counter 2 encoding utf-8
nats::msg set msg -data [encoding convertto utf-8 "Hello $tcl_platform(user)"]
$conn publish_msg $msg

# let the event loop process all of the above
after 1000 [list set untilDone 1]
vwait untilDone

$conn destroy
puts "Done"
