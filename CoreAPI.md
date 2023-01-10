# Core NATS API
`package require nats`

All commands are defined in and exported from the `::nats` namespace.

## Synopsis
[nats::connection new ?*conn_name*? ?-logger *logger*? ?-log_chan *channel*? ?-log_level *level*?](#constructor-conn_name--logger-logger--log_chan-channel--log_level-level) <br/>
[*objectName* cget *option*](#objectName-cget-option) <br/>
[*objectName* configure *?option? ?value option value ...?*](#objectName-configure-option-value-option-value) <br/>
[*objectName* reset *option*](#objectname-reset-option--) <br/>
[*objectName* connect ?*-async*?](#objectName-connect--async) <br/>
[*objectName* disconnect](#objectName-disconnect) <br/>
[*objectName* publish *subject message* ?-reply *replyTo*?](#objectname-publish-subject-message--reply-replyto) <br/>
[*objectName* publish_msg *msg*](#objectname-publish_msg-msg) <br/>
[*objectName* subscribe *subject ?-queue queueGroup? ?-callback cmdPrefix? ?-max_msgs maxMsgs? ?-dictmsg dictmsg?*](#objectName-subscribe-subject--queue-queueGroup--callback-cmdPrefix--max_msgs-maxMsgs--dictmsg-dictmsg) <br/>
[*objectName* unsubscribe *subID ?-max_msgs maxMsgs?*](#objectName-unsubscribe-subID--max_msgs-maxMsgs) <br/>
[*objectName* request *subject message ?args?*](#objectName-request-subject-message-args) <br/>
[*objectName* request_msg msg ?-timeout *ms* -callback *cmdPrefix* -dictmsg *dictmsg*?](#objectname-request_msg-msg--timeout-ms--callback-cmdprefix--dictmsg-dictmsg)<br/>
[*objectName* ping *?-timeout ms?*](#objectName-ping--timeout-ms) <br/>
[*objectName* inbox](#objectName-inbox) <br/>
[*objectName* current_server](#objectName-current_server) <br/>
[*objectName* all_servers](#objectName-all_servers) <br/>
[*objectName* server_info](#objectName-server_info) <br/>
[*objectName* destroy](#objectName-destroy) <br/>
[*objectName* jet_stream](#objectname-jet_stream--timeout-ms) <br/>

[nats::msg](#natsmsg) <br/>
[msg create *subject* ?-data *payload*? ?-reply *replyTo*?](#msg-create-subject--data-payload--reply-replysubj)<br/>
[msg set *msgVariable option value*](#msg-set-msgvariable-option-value)<br/>
[msg subject *msgValue*](#msg-subject-msgvalue)<br/>
[msg data *msgValue*](#msg-data-msgvalue)<br/>
[msg reply *msgValue*](#msg-reply-msgvalue)<br/>
[msg no_responders *msgValue*](#msg-no_responders-msgvalue)<br/>
[msg seq *msgValue*](#msg-seq-msgvalue)<br/>
[msg timestamp *msgValue*](#msg-timestamp-msgvalue)<br/>

[nats::header](#natsheader)<br/>
[header add *msgVariable key value*](#header-add-msgvariable-key-value)<br/>
[header set *msgVariable key value ?key value?..*](#header-set-msgvariable-key-value-key-value)<br/>
[header delete *msgVariable key*](#header-delete-msgvariable-key)<br/>
[header values *msgValue key*](#header-values-msgvalue-key)<br/>
[header get *msgValue key*](#header-get-msgvalue-key)<br/>
[header keys *msgValue ?globPattern?*](#header-keys-msgvalue-globpattern)<br/>

[nats::timestamp](#natstimestamp)

## Description
The client relies on a running event loop to send and deliver messages and uses only non-blocking sockets. Everything works in your Tcl interpreter and no background Tcl threads or interpreters are created under the hood. So, if your application might leave the event loop for a long time (e.g. a long computation without event processing), the NATS client should be created in a separate thread.

Calls to blocking API (synchronous versions of `connect`, `request`, `ping`) involve `vwait` under the hood, so that other event processing can continue. If the API is called from a coroutine, `coroutine::util vwait` is used instead of a plain `vwait` to avoid nested event loops.

## Message headers
When using NATS server version 2.2 and later, you can publish and receive messages with [headers](https://pkg.go.dev/github.com/nats-io/nats.go?utm_source=godoc#Header). Please, keep in mind that:
- keys are case-sensitive (unlike standard HTTP headers)
- duplicate keys are allowed (just like standard HTTP headers). In Tcl this is represented as a key pointing to a *list* of values, mimicking the same API as in nats.go and nats.java.
- `Status` and `Description` keys are reserved by the NATS protocol, in particular for implementation of the [no-responders](https://docs.nats.io/whats_new_22#react-quicker-with-no-responder-notifications) feature.


## Receiving a message as a Tcl dict
For simplicity, an incoming message is returned by `request` or a subscription callback as a string. This is only the payload. If you need more advanced access, e.g. to get message headers, you can pass the `-dictmsg true` argument to indicate that the package should deliver `message` as a dict. Then you can work with this variable using the [nats::msg ensemble](#natsmsg).

Also, instead of passing `-dictmsg true` to every call, you can `configure` your connection to return messages always as dicts.

Note that the JetStream API **always** returns messages as dicts.

## Public variables
The connection object exposes 3 "public" read-only variables:
- `last_error` - used to deliver asynchronous errors, e.g. if the network fails. It is a dict with 2 keys similar to the arguments for `throw`:
  - code: error code, e.g. {NATS ErrAuthorization}
  - errorMessage: human-readable error message
- `status` - connection status, one of `$nats::status_closed`, `$nats::status_connecting`, `$nats::status_connected` or `$nats::status_reconnecting`.
- `serverInfo` - array with INFO from the current server. Intended only for tracing. Note there is `server_info` method that returns a dict with the same data.

You can set up traces on these variables to get notified e.g. when a connection status changes or NATS server enters `ldm` - lame duck mode. 
## Options

The **configure** method accepts the following options. Make sure to set them *before* calling **connect**.

| Option        | Type   | Default | Comment |
| ------------- |--------|---------|---------|
| -servers      | list   | (mandatory) | URLs of NATS servers|
| -name          | string |         | Client name sent to NATS server when connecting|
| -pedantic      | boolean |false   | Pedantic protocol mode. If true some extra checks will be performed by NATS server|
| -verbose       | boolean | false | If true, every protocol message is echoed by the server with +OK. Has no effect on functioning of the client itself |
| -randomize | boolean | true | Shuffle server addresses passed to `configure`| 
| -connect_timeout | integer | 2000 | Connection timeout (ms) |
| -reconnect_time_wait | integer | 2000 | How long to wait between two reconnect attempts to the same server (ms)|
| -max_reconnect_attempts | integer | 60 | Maximum number of reconnect attempts per server. Set it to -1 for infinite attempts. |
| -ping_interval | integer | 120000 | Interval (ms) to send PING messages to a NATS server|
| -max_outstanding_pings | integer | 2 | Max number of PINGs without a reply from a NATS server before closing the connection |
| -echo | boolean | true | If true, messages from this connection will be echoed back by the server, if the connection has matching subscriptions|
| -tls_opts | list | | Additional options for `tls::import` - here you can provide `-cafile` etc |
| -user | string | | Default username|
| -password | string |   | Default password|
| -token | string | | Default authentication token|
| -secure | boolean | false | If secure=true, connection will fail if a server can't provide a TLS connection |
| -check_subjects | boolean | true | Enable client-side checking of subjects when publishing or subscribing |
| -dictmsg | boolean | false | Return messages from `subscribe` and `request` as dicts by default |
| -utf8_convert | boolean | false | By default, the client does not change a message body when it is sent or received. Setting this option to `true` will encode outgoing messages to UTF-8 and decode incoming messages from UTF-8 |

## Commands

### constructor ?*conn_name*? ?-logger *logger*? ?-log_chan *channel*? ?-log_level *level*?
Creates a new instance of the TclOO object `nats::connection` with default options. If you provide a connection name (recommended!), it is sent to NATS in the `CONNECT` message.<br/>
The constructor also initializes the logging functionality. With no arguments, the default severity level is `warn` and destination is `stdout`. You can configure logging in 2 ways:
- either create and configure your own [logger](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md) object and pass it with `-logger` option
- or set severity with `-log_level` and output channel with `-log_chan`. The class uses only 4 levels: debug, info, warn, error

See also the [examples](examples) folder.

### objectName cget *option*
Returns the current value of an option as described above. 

### objectName configure *?option? ?value option value...?*
When given no arguments, returns a dict of all options with their current values. When given one option, returns its current value (same as `cget`). When given more arguments, assigns each value to an option. The only mandatory option is `servers`, and others have reasonable defaults.

### objectName reset ?*option* ... ?
Resets the option(s) to default values.

### objectName connect ?-async? 
Opens a TCP connection to one of the NATS servers specified in the `servers` list. 

Without the `-async` option, this call blocks in a (coroutine-aware) `vwait` loop until the connection is completed, including a TLS handshake if needed. 

With `-async` the call does not block. `status` becomes `$status_connecting` and you can call `publish` & `subscribe` straightaway - they will be flushed once the connection succeeds. You can `vwait` or setup a trace on the `status` variable to get notified when the connection succeeds or fails.

### objectName disconnect 
Flushes all outgoing data, closes the TCP connection and sets `status` to `$nats::status_closed`. Pending asynchronous requests are cancelled.

### objectName publish *subject message* ?-reply *replyTo*?
Publishes a message to the specified subject. See the NATS [documentation](https://docs.nats.io/nats-concepts/subjects) for more details about subjects and wildcards. The client will check subject's validity before sending according to [NATS Naming Rules](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md). <br/>
`message` is the payload (can be a binary string). If you specify a `replyTo` subject, a responder will know where to send a reply. You can use the [inbox](#objectname-inbox) method to generate a transient [subject name](https://docs.nats.io/developing-with-nats/sending/replyto) starting with _INBOX. However, using asynchronous requests might accomplish the same task in an easier manner - see below.

### objectName publish_msg *msg*
Publishes a message created using [nats::msg](#natsmsg) commands. This method is especially useful if you need to send a message with headers.

### objectName subscribe *subject* ?-queue *queueGroup*? ?-callback *cmdPrefix*? ?-max_msgs *maxMsgs*? ?-dictmsg *dictmsg*?
Subscribes to a subject (possibly with wildcards) and returns a subscription ID. Whenever a message arrives, the command prefix will be invoked from the event loop. It must have the following signature:<br/>
**subscriptionCallback** *subject message replyTo*<br/>

If you use the [-queue option](https://docs.nats.io/developing-with-nats/receiving/queues), only one subscriber in a given queueGroup will receive each message (useful for load balancing). When given `-max_msgs`, the client will automatically unsubscribe after `maxMsgs` messages have been received.<br />
By default, only a payload is delivered in `message`. Use `-dictmsg true` to receive `message` as a dict, e.g. to access headers. You can also `configure` the connection to have `-dictmsg` as true by default.

### objectName unsubscribe *subID* ?-max_msgs *maxMsgs*? 
Unsubscribes from a subscription with a given `subID` immediately. If `-max_msgs` is given, unsubscribes after this number of messages has been received **on this `subID`**. In other words, if you have already received 10 messages, and then you call `unsubscribe $subID -max_msgs 10`, you will be unsubscribed immediately.

### objectName request *subject message* ?*args*?
Sends `message` (payload) to the specified `subject` with an automatically generated transient reply-to (inbox).

You can provide the following options:
- `-timeout ms` - expire the request after X ms (recommended!). Default timeout is infinite.
- `-callback cmdPrefix` - do not block and deliver the reply to this callback
- `-dictmsg dictmsg` - return the reply as a dict accessible to [nats::msg](#natsmsg).
- `-max_msgs maxMsgs` - gather multiple replies. If this option is not used, the 'new-style' request is triggered under the hood (uses a shared subscription for all requests), and only the first reply is returned. If this option is used (even with `maxMsgs`=1), it triggers the 'old-style' request that creates its own subscription. `-dictmsg` is always true in this case.

Depending if there's a callback, the method works in a sync or async manner.

If no callback is given, the request is synchronous and blocks in a (coroutine-aware) `vwait` and then returns a reply. If `-max_msgs` >1, the returned value is a list of message dicts. If no response arrives within `timeout`, it raises the error `ErrTimeout`. When using NATS server version 2.2+, `ErrNoResponders` is raised if nobody is subscribed to `subject`.

If a callback is given, the call returns immediately, and when a reply is received or a timeout fires, the callback will be invoked from the event loop. It must have the following signature:<br/>
**asyncRequestCallback** *timedOut message*<br/>
`timedOut` is a boolean equal to 1, if the request timed out or no responders are available.<br/>
`response` is the received message. If `-max_msgs` >1, the callback is invoked for each message. If the timeout fires before `-max_msgs` are received, the callback is invoked with `timedOut`=1.

### objectName request_msg *msg* ?-timeout *ms* -callback *cmdPrefix* -dictmsg *dictmsg*?
Sends a request with a message created using [nats::msg](#natsmsg).

### objectName ping ?-timeout *ms*?
Triggers a ping-pong exchange with the NATS server, enters (coroutine-aware) `vwait` and returns true upon success. If the server does not reply within the specified timeout (ms), it raises `ErrTimeout`. Default timeout is 10s. You can use this method to check if the server is alive or ensure all prior calls to `publish` and `subscribe` are flushed to NATS. Note that in other NATS clients this function is usually called "flush".

### objectName inbox 
Returns a new inbox - random subject starting with _INBOX.

### objectName current_server
Returns a 2-element list with host and port of the current NATS server.

### objectName all_servers
Returns a list with all servers in the pool.

### objectName server_info
Returns a dict with the INFO message from the current server.

### objectName destroy
TclOO destructor. It calls `disconnect` and then destroys the object.

### objectName jet_stream ?-timeout *ms*?
This 'factory' method creates [jetStreamObject](JsAPI.md) to work with [JetStream](https://docs.nats.io/jetstream/jetstream). `-timeout` (default 5s) is applied for all requests to JetStream NATS API.

Remember to destroy this object when it is no longer needed - there's no built-in garbage collection in `connection`.

## nats::msg
This ensemble encapsulates all commands to work with a NATS message. Accessing it as a dict is deprecated. 
### msg create *subject* ?-data *payload*? ?-reply *replySubj*?
Returns a new message with the specified subject, payload and reply subject.
### msg set *msgVariable option value*
Updates the message. Possible `options` are `-subject`, `-data` and `-reply`.
### msg subject *msgValue*
Returns the message subject.
### msg data *msgValue*
Returns the message payload.
### msg reply *msgValue*
Returns the message reply-to subject.
### msg no_responders *msgValue*
Returns true if this is a no-responders message (status 503).
### msg seq *msgValue*
Returns the message sequence number (only for messages returned by `stream_msg_get`).
### msg timestamp *msgValue*
Returns the message timestamp in the ISO format, e.g. 2022-11-22T13:31:35.4514983Z (only for messages returned by `stream_msg_get`).
## nats::header
This ensemble encapsulates all commands to work with message headers. Accessing them as a dict is deprecated. 
### header add *msgVariable key value*
Appends a new value to the `key` header in the message. If this header does not exist yet, it is created.
### header set *msgVariable key value ?key value?..*
Sets the `key` header to `value`. Multiple headers can be set at once by repeating key-value arguments (like in `dict create`).
### header delete *msgVariable key*
Deletes the `key` header from the message.
### header values *msgValue key*
Gets a list of all values of the `key` header.
### header get *msgValue key*
Gets the first value of the `key` header. This is a convenient shortcut for the `values` command, since usually each header has only one value.
### header keys *msgValue ?globPattern?*
Gets a list of all header keys in the message. With `globPattern`, only matching keys are returned (like in `dict keys`)
### nats::timestamp
Returns current local time in the ISO format, including milliseconds. Useful for logging.

## Error handling
Error codes are similar to those from the nats.go client as much as possible. A few additional error codes provide more information about failed connection attempts to the NATS server: ErrBrokenSocket, ErrTLS, ErrConnectionRefused.

All synchronous errors are raised using `throw {NATS <error_code>} human-readable message`, so you can handle them using try&trap, for example: 
```Tcl
try {
  ...
} trap {NATS ErrTimeout} {err opts} {
 # handle a request timeout  
} trap NATS {err opts} {
  # handle other NATS errors
} trap {} {err opts} {
  # handle other (non-NATS) errors
}
```
| Synchronous errors     | Reason   | 
| ------------- |--------|
| ErrConnectionClosed | Attempt to subscribe or publish a message before calling `connect` |
| ErrNoServers | No NATS servers available|
| ErrInvalidArg | Invalid argument |
| ErrBadSubject | Invalid subject for publishing or subscribing |
| ErrBadQueueName | Invalid queue name |
| ErrBadTimeout | Invalid timeout argument |
| ErrMaxPayload | Message size is more than allowed by the server |
| ErrBadSubscription | Invalid subscription ID |
| ErrTimeout | Timeout of a synchronous request or ping |
| ErrNoResponders | No responders are available for request |
| ErrHeadersNotSupported| Headers are not supported by this server |

Asynchronous errors are sent to the logger and can also be queried/traced using 
`$last_error`, for example:
```Tcl
set err [set ${conn}::last_error]
puts "Error code: [dict get $err code]"
puts "Error text: [dict get $err errorMessage]"
```
| Async errors     | Reason   | Terminates connection |
| ------------- |--------|----|
| ErrBrokenSocket | TCP socket failed | yes |
| ErrTLS | TLS handshake failed | yes |
| ErrStaleConnection | The client or server closed the connection, because the other party did not respond to PING on time | yes |
| ErrConnectionRefused | TCP connection to the server was refused, possibly due to a wrong port, DNS resolution failure, or the server was not running | yes |
| ErrSecureConnWanted | Client requires TLS, but the server does not provide TLS | yes |
| ErrConnectionTimeout | Connection to a server could not be established within `-connect_timeout` ms | yes| 
| ErrBadHeaderMsg | The client failed to parse message headers. Nevertheless, the message body is delivered | no |
| ErrServer | Generic error reported by NATS | yes |
| ErrBadSubject | Message had an invalid subject | no |
| ErrPermissions | Subject authorization has failed | no |
| ErrAuthorization | User authorization has failed or no credentials are known for this server | yes |
| ErrAuthExpired | User authorization has expired | yes |
| ErrAuthRevoked | User authorization has been revoked | yes |
| ErrAccountAuthExpired | NATS server account authorization has expired| yes |
