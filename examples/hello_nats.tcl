# EXAMPLE #1: basic publishing and subscribing
# Remember to start nats-server before running this example; you can add -DV option to see data sent and received on the wire

package require nats
# TCP connection to a NATS server is represented as a TclOO class called nats::connection.
# If you're not familiar with TclOO, don't worry - usage is limited to constructing, calling methods and destroying it in the end.
# If you'd like to learn more about TclOO, here's an extensive tutorial:
# https://www.magicsplat.com/articles/oo.html
# When creating a connection, you can give it a name - "MyNats" in this case. It will be displayed in logs and sent to the NATS server.
# You can create as many connections as needed - they all work independently. Although typically one connection per application is enough.

set conn [nats::connection new "MyNats"]

# as a minimum configuration, you need to specify the URL of your NATS server. Here we assume it runs on the same host and on the default port TCP/4222
# if NATS is configured with TLS, use tls:// instead of nats://
# if you need to authenticate with NATS, you can provide a username and password in the URL or using 'configure'
# in the latter case, the credentials will apply to all servers in the pool that don't have them in URL
$conn configure -servers nats://localhost:4222

# now we can connect. By default this call will block unless you pass the -async option. If the connection fails, an error is thrown.
$conn connect

# define a callback for incoming messages
proc onMessage {subject message replyTo} {
    # this callback is invoked in the global scope from the Tcl event loop
    puts "Received '$message' on subject $subject"
    # if this is a request, $replyTo will contain the subject to reply to
}
# you can design an hierarchical subject space using tokens and dots; also you can use wildcards * and > for subscriptions
# learn more at https://docs.nats.io/nats-concepts/subjects
$conn subscribe sample_subject.* -callback onMessage

# now whenever some other NATS client sends a message e.g. to "sample_subject.1", it will be delivered to our event queue, i.e. using "after 0"
# for the sake of example, let's send a few messages ourselves
# remember that NATS subjects are case-sensitive
for {set i 0} { $i<10 } {incr i} {
    $conn publish sample_subject.$i "Hello $tcl_platform(user)"
}
# make the app leave the event loop by itself after 1s
after 1000 [list set untilDone 1]
# now enter the event loop; no messages can be sent or received without it!
vwait untilDone

# Finally, don't forget to delete our object. All pending outgoing messages will be flushed, and the TCP socket will be closed.
$conn destroy
puts "Done"
