# Tcl client library for the NATS message broker

[![License Apache 2.0](https://img.shields.io/badge/License-Apache2-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

Learn more about NATS [here](https://nats.io) and Tcl/Tk [here](https://www.tcl.tk/).

Feature-wise, the package is comparable to other NATS clients and is inspired by the official [nats.py](https://github.com/nats-io/nats.py) and [nats.go](https://github.com/nats-io/nats.go).

With this package you can bring the power of the publish/subscribe mechanism to your Tcl and significantly simplify development of distributed applications.

## Supported platforms

The package is written in pure Tcl, without any C code, and so will work anywhere with `Tcl 8.6` and `Tcllib`. If you need to connect to a NATS server using TLS, of course you will need the `tls` package too.

It has been tested on Windows 10 using the latest pre-built Tcl available from ActiveState (Tcl 8.6.9, Tcllib 1.18) and on openSUSE Leap 15.1 using self-built Tcl of the same version. It might work on earlier versions too.

Regarding the NATS server version, I tested against v2.1.7, and the package should work with all previous releases of NATS, because the protocol remained very stable over years.

## Installing
Simply clone the repository in some place where Tcl will be able to find it, e.g. in `$auto_path` or `$tcl_library`. No need to compile anything!

## Supported features
- Publish and subscribe to messages, also with headers (NATS version 2.2)
- Synchronous and asynchronous requests (optimized: under the hood a single wildcard subscription is used for all requests)
- Basic JetStream support: publish and consume messages from a stream in sync and async manners
- Queue groups
- Client-side validation of subjects
- Standard `configure` interface with many options
- Automatic reconnection in case of network or server failure
- While the client is trying to reconnect, outgoing messages are buffered in memory and will be flushed as soon as the connection is restored
- Authentication with NATS server using a login+password, an authentication token or a TLS certificate
- Protected connections using TLS
- Cluster support (including receiving additional server addresses from INFO messages)
- Logging using the standard Tcl [logger](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md) package
- Extensive test suite with 80+ unit tests, checking nominal use cases, error handling, timings and the wire protocol ensures that the Tcl client behaves in line with official NATS clients

## Usage

Note that the client relies on a running event loop to send and deliver messages and uses only non-blocking sockets. Everything works in your Tcl interpreter and no background Tcl threads or interpreters are created under the hood. So, if your application might leave the event loop for a long time (e.g. a long computation without event processing), the NATS client should be created in a separate thread.

Calls to blocking API (synchronous versions of `connect`, `request`, `ping`) involve `vwait` under the hood, so that other event processing can continue. If the API is used from a coroutine, `coroutine::util vwait` is used instead of a plain `vwait` to avoid nested event loops.

Find the detailed API reference [here](API.md).

```Tcl
package require nats
# All API is enclosed into a TclOO object called nats::connection
# Giving a name to a connection is optional. 
# It will be displayed in logs and sent to the NATS server
# You can create as many connections as needed, they all will work independently. 
# Although typically one connection per application is enough.
set conn [nats::connection new "MyNats"]
# default severity level is "warn", but you can lower it to see what happens under the hood
[$conn logger]::setlevel info
# the "configure" command is implemented using the "cmdline" package, 
# so you can find out all available options in an interactive shell using -?
# as a minimum you need to specify the URL of your NATS server, or a list of URLs
$conn configure -servers nats://localhost:4222 
# Now we can connect. By default this call will block unless you pass -async option.
$conn connect

# define a callback for incoming messages
set msg ""
proc onMessage {subject message replyTo} {
    puts "Received $message on subject $subject"
    set ::msg $message
    # if it is a request, $replyTo will contain the subject to reply
}
# you can design an hierarchical subject space using tokens and dots
# and then you can use wildcars for subscriptions
$conn subscribe "sample_subject.*" -callback onMessage

# now whenever somebody sends a message to a matching subject, it will be delivered from the event loop,
#  i.e. using "after 0"
# let's publish a message ourselves
$conn publish sample_subject.foo hello
# and wait for the message to arrive
vwait ::msg

# you can perform synchronous requests; timeout is specified in ms
set result [$conn request service "I need help" -timeout 1000]
# and asynchronous too
proc asyncReqCallback {timedOut msg} {
    # $timedOut will be true if nobody replied within the specified timeout
}
$conn request service "I need help" -timeout 1000 -callback asyncReqCallback

# Finally don't forget to delete our object. Again, this is standard TclOO.
# All pending outgoing messages will be flushed, and the TCP socket will be closed.
$conn destroy

###  JetStream support  ###
# get jet_stream object to use jet stream api
set jet_stream [$conn jet_stream]

# to consume messages use "consume" method (pull consumer) in sync or async form
# its arguments are stream name and consumer name, optional: -timeout, -callback as in original request method
set result [$jet_stream consume my_stream my_consumer]

# received result contains one additional variable "ackAddr" (so response is list in form {message ackAddr})
# ackAddr is used to acknowlege consumed (received) message to server
lassign $result msg ackAddr
$jet_stream ack $ackAddr

# consume can also be used in asynchronous manner
proc consumeAsyncCallback {timedOut msg ackAddr} {
    # do sth...
    $jet_stream ack $ackAddr
}

$jet_stream consume my_stream my_consumer -callback consumeAsyncCallback -timeout 1000

# publishing to jet stream can be done using publish on jet_stream object
# synchronous varsion
$jet_stream publish "test.1" "msg 1"

# asynchronous version
proc pubAsyncCallback {timedOut info error} {
    # if "error" is not empty it is dict containing "type" and "error" keys sended from NATS server
    # if "error" is empty, publish was successfull and "info" is dict containing "stream", "seq" and optionally "duplicate"
    ...
}

$jet_stream publish "test.1" "msg 1" -callback pubAsyncCallback -timeout 1000
```

## Missing features (in comparison to official NATS clients)
- The new authentication mechanism using NKey & [JWT](https://docs.nats.io/developing-with-nats/security/creds). This one will be difficult to do, because it requires support for _ed25519_ cryptography that is missing in Tcl AFAIK. Please let me know if you need it.

## Running tests
The tests are based on the standard Tcl unit testing framework, [tcltest](https://www.tcl.tk/man/tcl8.6/TclCmd/tcltest.htm). Simply run `tclsh tests/all.tcl` and the tests will be executed one after another. They assume that `nats-server` is available in your `$PATH`, but it should **not** be already running. 

And this is how you can run just one test script: `tclsh tests/all.tcl -file basic.test`

To run the TLS tests, you will need to provide certificates yourself in `cert` subfolder. E.g. you can generate them using [mkcert](https://docs.nats.io/nats-server/configuration/securing_nats/tls#self-signed-certificates-for-testing).

To run Jet Stream tests `nats` command from [nats-cli](https://github.com/nats-io/natscli) needs to be available in you `$PATH` (it is additional tool for NATS server configuration - creating streams, consumers etc. which is not supported by this library yet).

Tests are numbered to reflect their dependency, i.e. tests from the same group (e.g. basic-2.1, basic-2.2 and basic-2.3) are dependent on each other. Tests from different groups should be independent, except basic assumptions about a NATS connection and e.g. a running Responder.

While most of the tests stick to the public API, some of them need to hack into package's internals to verify some behavioural aspects. This is *not* an invitation for users to do the same! If you are missing a function in API, please let me know.
