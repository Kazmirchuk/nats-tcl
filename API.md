# Name
nats - a client library for the NATS message broker.

## Synopsis

package require nats ?0.9?

[**::nats::connection new** *?conn_name?*](#constructor) <br/>
[*objectName* **cget** *option*](#objectName-cget-option) <br/>
[*objectName* **configure** *?option? ?value option value ...?*](#objectName-configure-option-value-option-value) <br/>
[*objectName* **reset** *option*](#objectName-reset-option) <br/>
[*objectName* **connect** *?-async?*](#objectName-connect--async) <br/>
[*objectName* **disconnect**](#objectName-disconnect) <br/>
[*objectName* **publish** *subject msg ?replySubj?*](#objectName-publish-subject-msg-replySubj) <br/>
[*objectName* **subscribe** *subject ?-queue queueGroup? ?-callback cmdPrefix? ?-max_msgs maxMsgs?*](#objectName-subscribe-subject--queue-queueGroup--callback-cmdPrefix--max_msgs-maxMsgs) <br/>
[*objectName* **unsubscribe** *subID ?-max_msgs maxMsgs?*](#objectName-unsubscribe-subID--max_msgs-maxMsgs) <br/>
[*objectName* **request** *subject message ?-timeout ms? ?-callback cmdPrefix?*](#objectName-request-subject-message--timeout-ms--callback-cmdPrefix) <br/>
[*objectName* **ping** *?-timeout ms?*](#objectName-ping--timeout-ms) <br/>
[*objectName* **inbox**](#objectName-inbox) <br/>
[*objectName* **current_server**](#objectName-current_server) <br/>
[*objectName* **all_servers**](#objectName-all_servers) <br/>
[*objectName* **server_info**](#objectName-server_info) <br/>
[*objectName* **logger**](#objectName-logger) <br/>
[*objectName* **destroy**](#objectName-destroy)

[*objectName* **jet_stream**](#objectName-jet_stream) <br/>
[*jetStreamObject* **consume** stream consumer ?-timeout ms? ?-callback cmdPrefix?](#jetStreamObject-consume-stream-consumer--timeout-ms--callback-cmdPrefix) <br/>
[*jetStreamObject* **ack** ackAddr](#jetStreamObject-ack-ackAddr) <br/>
[*jetStreamObject* **publish** subject message ?-timeout ms? ?-callback cmdPrefix?](#jetStreamObject-publish-subject-message--timeout-ms--callback-cmdPrefix) <br/>


## Callbacks
All callbacks are treated as command prefixes (like [trace](https://www.tcl.tk/man/tcl8.6/TclCmd/trace.htm) callbacks), so in addition to a command itself they may include user-supplied arguments. They are invoked from the event loop as follows:
### Core NATS: <br/>
**subscriptionCallback** *subject message replyTo*<br/>
**asyncRequestCallback** *timedOut message* <br/>
### JetStream: <br/>
**consumeCallback** *timedOut message ackAddr* <br/>
**publishCallback** *timedOut info error* <br/>

## Message headers
When using NATS server version 2.2 and later, you can publish and receive messages with [headers](https://pkg.go.dev/github.com/nats-io/nats.go?utm_source=godoc#Header). Please, keep in mind that:
- keys are case-sensitive (unlike with standard HTTP headers)
- duplicate keys are allowed (just like with standard HTTP headers). In Tcl this is represented as a key pointing to a *list* of values, mimicking the same API as in nats.go and nats.java.
- `Status` and `Description` keys are reserved by the NATS protocol, in particular for implementation of the [no-responders](https://docs.nats.io/whats_new_22#react-quicker-with-no-responder-notifications) feature.

Examples of valid headers:
```Tcl
set h [dict create hdr1 val1 hdr2 val2]
# values must be wrapped using `list` if they have spaces
set h [dict create hdr1 [list "val 1"] hdr2 val2]
# multiple values for the same key
set h [dict create hdr1 [list val1 val2] hdr2 val3]
```

## Receiving a message as a Tcl dict
Typically the package delivers a message as a string, be it the `message` argument to the above callbacks or a return value from `request`. <br />  When publishing a message, its body and header are specified as separate arguments to `publish` or `request`. And when subscribing, you can pass `-dictmsg true` to indicate that the package should deliver `message` as a dict. Besides access to the headers, this approach also provides for better API extensibility in future.<br/>
The dict has 2 keys:
- header - a dict as shown above
- data - a message body (string)
  
If you have received a message with a header, but have *not* used `-dictmsg true`, this is not an error: the header is discarded, and you get back only the message body as a string, as usual.

## Public variables
The connection object exposes 2 "public" read-only variables:
- `last_error` - used to deliver asynchronous errors, e.g. if the network fails. It is a dict with 2 keys similar to the arguments for `throw`:
  - code: error code 
  - message: error message
- `status` - connection status, one of `$nats::status_closed`, `$nats::status_connecting`, `$nats::status_connected` or `$nats::status_reconnecting`.

You can set up traces on these variables to get notified e.g. when a connection status changes.

## Options

The **configure** method accepts the following options. Make sure to set them *before* calling **connect**.

| Option        | Type   | Default | Comment |
| ------------- |--------|---------|---------|
| servers (mandatory)      | list   |         | URLs of NATS servers|
| name          | string |         | Client name sent to NATS server when connecting|
| pedantic      | boolean |false   | Pedantic protocol mode. If true some extra checks will be performed by NATS server|
| verbose       | boolean | false | If true, every protocol message is echoed by the server with +OK. Has no effect on functioning of the client itself |
|connect_timeout | integer | 2000 | Connection timeout (ms) |
| reconnect_time_wait | integer | 2000 | How long to wait between two reconnect attempts to the same server (ms)|
| max_reconnect_attempts | integer | 60 | Maximum number of reconnect attempts per server. Set it to -1 for infinite attempts. |
| ping_interval | integer | 120000 | Interval (ms) to send PING messages to a NATS server|
| max_outstanding_pings | integer | 2 | Max number of PINGs without a reply from a NATS server before closing the connection |
| echo | boolean | true | If true, messages from this connection will be echoed back by the server if the connection has matching subscriptions|
| tls_opts | list | | Options for tls::import |
| user | string | | Default username|
| password | string |   | Default password|
| token | string | | Default authentication token|
| secure | boolean | false | Indicate to the server if the client wants a TLS connection or not|
| check_subjects | boolean | true | Enable client-side checking of subjects when publishing or subscribing |
| dictmsg | boolean | false | Return messages from `subscribe` and `request` as dicts by default |
| -? | | | Provides interactive help with all options|

## Description

### constructor ?conn_name?
Creates a new instance of `nats::connection` with default options and initialises a [logger](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md) instance with the severity level set to `warn`. If you pass in a connection name, it will be sent to NATS in a `CONNECT` message, and will be indicated in the logger name.

### objectName cget option
Returns the current value of an option as described above. 

### objectName configure ?option? ?value option value...?
When given no arguments, returns a dict of all options with their current values. When given one option, returns its current value (same as `cget`). When given more arguments, assigns each value to an option. The only mandatory option is `servers`, and others have reasonable defaults. Under the hood it is implemented using the [cmdline::getoptions](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/cmdline/cmdline.md#3) command, so it understands the special `-?` option for interactive help.

### objectName reset ?option ... ?
Resets the option(s) to the default value.

### objectName connect ?-async? 
Opens a TCP connection to one of the NATS servers specified in the `servers` list. Unless the `-async` option is given, this call blocks in a `vwait` loop until the connection is completed, including a TLS handshake if needed.

### objectName disconnect 
Flushes all outgoing data, closes the TCP connection and sets the `status` to "closed".

### objectName publish subject message ?args?
This method can be used in 2 way. The simple way:
```Tcl
objectName publish subject message ?reply?
```
and if you need extra options:
```Tcl
objectName publish subject message ?-header header? ?-reply reply?
```
Publishes a message to the specified subject. See the NATS [documentation](https://docs.nats.io/nats-concepts/subjects) for more details about subjects and wildcards. The client will check subject's validity before sending. Allowed characters are Latin-1 characters, digits, dot, dash and underscore. <br/>
`message` is sent as is, it can be a binary string. If you specify `reply`, a responder will know where to send a reply. You can use the `inbox` method to generate a transient [subject name](https://docs.nats.io/developing-with-nats/sending/replyto) starting with _INBOX. However, using asynchronous requests might accomplish the same task in an easier manner - see below.<br/>
When using NATS server version 2.2 and later, you can provide a `header` with the message. 

### objectName subscribe subject ?-queue queueGroup? ?-callback cmdPrefix? ?-max_msgs maxMsgs? ?-dictmsg dictmsg?
Subscribes to a subject (possibly with wildcards) and returns a subscription ID. Whenever a message arrives, the command prefix will be invoked from the event loop with 3 additional arguments: `subject`, `message` and `replyTo` (might be empty). If you use the [-queue option](https://docs.nats.io/developing-with-nats/receiving/queues), only one subscriber in a given queueGroup will receive each message (useful for load balancing). When given `-max_msgs`, the client will automatically unsubscribe after `maxMsgs` messages have been received.<br />
By default, `message` is delivered as a string. Use `-dictmsg true` to receive `message` as a dict, e.g. to access headers. You can also `configure` the connection to have `-dictmsg` as true by default for all calls.

### objectName unsubscribe subID ?-max_msgs maxMsgs? 
Unsubscribes from a subscription with a given `subID` immediately. If `-max_msgs` is given, unsubscribes after this number of messages has been received **on this `subID`**. In other words, if you have already received 10 messages, and then you call `unsubscribe $subID -max_msgs 10`, you will be unsubscribed immediately.

### objectName request subject message ?-timeout ms? ?-callback cmdPrefix? ?-dictmsg dictmsg? ?-header header?
Sends a message with an optional `-header` to the specified subject using an automatically generated transient `replyTo` subject (inbox). 
- If no callback is given, the request is synchronous and blocks in (possibly, coroutine-aware) `vwait` until a response is received. The response is the return value. If no response arrives within `timeout`, it raises the error `ErrTimeout`. When using NATS server version 2.2 and later,  `ErrNoResponders` is raised if nobody is subscribed to `subject`.
- If a callback is given, the call returns immediately, and when a response is received or a timeout fires, the command prefix will be invoked from the event loop with 2 additional arguments: `timedOut` (equal to 1, if the request timed out or no responders are available) and a `response`.<br />

By default, `response` is delivered as a string. Use `-dictmsg true` to receive `response` as a dict, e.g. to access headers. You can also `configure` the connection to have `-dictmsg` as true by default for all calls.<br />

### objectName ping ?-timeout ms?
A blocking call that triggers a ping-pong exchange with the NATS server and returns true upon success. If the server does not reply within the specified timeout (ms), it raises `TIMEOUT` error. Default timeout is 10s. You can use this method to check if the server is alive.

### objectName inbox 
Returns a new inbox - random subject starting with _INBOX.

### objectName current_server 
Returns a 2-element list with host and port of the current NATS server.

### objectName all_servers
Returns a list with all servers in the pool

### objectName server_info
Returns a dict with the INFO message from the current server

### objectName logger 
Returns a logger instance.

### objectName destroy
TclOO destructor. Flushes pending data and closes the TCP socket.

### objectName jet_stream
Returns `jetStreamObject` object to work with [JetStreams](https://docs.nats.io/jetstream/jetstream).

### jetStreamObject consume stream consumer ?-timeout ms? ?-callback cmdPrefix?
Consume a message from a [consumer](https://docs.nats.io/jetstream/concepts/consumers) defined on a [stream](https://docs.nats.io/jetstream/concepts/streams) `stream`. Similarly to the `request` method:
- If no callback is given, the request is synchronous and blocks in `vwait` until a reply is received. The reply is a list containing the return value and address to acknowledge the received message. If no reply arrives within `timeout`, it raises `ErrTimeout`.
- If a callback is given, the call returns immediately, and when a reply is received or a timeout fires, the command prefix will be invoked from the event loop with 3 additional arguments: `timedOut` (equal to 1, if the request timed out), `message` and `ackAddr`, which is used to acknowledge received message in a way shown below.

### jetStreamObject ack ackAddr
Acknowledge the received message using `ackAddr` from [*jetStreamObject* **consume**](#jetStreamObjectName-consume) method. If the message is not acknowledged, it is redelivered on next `consume` (depending on NATS server settings).

### jetStreamObject publish subject message ?-timeout ms? ?-callback cmdPrefix?
Publish `message` to a [stream](https://docs.nats.io/jetstream/concepts/streams) on the specified `subject` and wait for acknowledgement. `timeout` and `cmdPrefix` have similar meaning as in `request` method. If no stream exists on specified `subject`, the call will be blocked waiting.
- In synchronous version the method returns a response from server as a dict containing `stream`, `seq` and optionally `duplicate` keys. If NATS server returned an error response, it raises `ErrResponse`.
- In asynchronous version `cmdPrefix` callback is called with 3 additional arguments: `timedOut` (equal to 1, if the request timed out), `info` and `error`. If `error` is not empty, it is a dict containing `type` and `error` keys sent by NATS server, otherwise `info` contains information passed from NATS server as a dict with keys: `stream`, `seq` and optionally `duplicate`.

## Error handling
Error codes are similar to those from the nats.go client as much as possible. A few additional error codes provide more information about failed connection attempts to the NATS server: ErrBrokenSocket, ErrTLS, ErrConnectionRefused.

All synchronous errors are raised using `throw {NATS <error_code>} human-readable message`, so you can handle them using try&trap, for example: 
```Tcl
try {
  ...
} trap {NATS ErrTimeout} {msg opts} {
 # handle a request timeout  
} trap {NATS} {msg opts} {
  # handle other NATS errors
}
```
| Error code        | Reason   | 
| ------------- |--------|
| ErrConnectionClosed | Attempt to subscribe or send a message before calling `connect` |
| ErrNoServers | No NATS servers available|
| ErrInvalidArg | Invalid argument |
| ErrBadSubject | Invalid subject for publishing or subscribing |
| ErrBadTimeout | Invalid timeout argument |
| ErrMaxPayload | Message size is more than allowed by the server |
| ErrBadSubscription | Invalid subscription ID |
| ErrTimeout | Timeout of a synchronous request, ping or JetStream's `consume` |
| ErrNoResponders | No responders are available for request |
| ErrHeadersNotSupported| Headers are not supported by this server |

Asynchronous errors are sent to the logger and can also be queried/traced using 
`$last_error`, for example:
```Tcl
set err [set ${conn}::last_error]
puts "Error code: [dict get $err code]"
puts "Error text: [dict get $err message]"
```
| Error type        | Reason   | 
| ------------- |--------|
| ErrBrokenSocket | TCP socket failed |
| ErrTLS | TLS handshake failed |
| ErrStaleConnection | The client or server closed the connection, because the other party did not respond to PING on time |
| ErrConnectionRefused | TCP connection to a NATS server was refused, possibly due to wrong port, or the server was not running; the client will try the next server from the pool |
| ErrConnectionTimeout | Connection to a server could not be established within connect_timeout ms |
| ErrServer | Generic error reported by NATS server |
| ErrPermissions | subject authorization has failed |
| ErrAuthorization | user authorization has failed or no credentials are known for this server |
| ErrAuthExpired | user authorization has expired |
| ErrAuthRevoked | user authorization has been revoked |
| ErrAccountAuthExpired | nats server account authorization has expired |