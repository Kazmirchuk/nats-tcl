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
[*objectName* **logger**](#objectName-logger) <br/>
[*objectName* **destroy**](#objectName-destroy)

## Callbacks
All callbacks are treated as command prefixes (like [trace](https://www.tcl.tk/man/tcl8.6/TclCmd/trace.htm) callbacks), so in addition to a command itself they may include user-supplied arguments. They are invoked as follows:

**subscriptionCallback** *subject message replyTo* (invoked from the event loop)<br/>
**asyncRequestCallback** *timedOut message* (invoked from the event loop)<br/>

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
| max_reconnect_attempts | integer | 60 | Maximum number of reconnect attempts per server |
| ping_interval | integer | 120000 | Interval (ms) to send PING messages to a NATS server|
| max_outstanding_pings | integer | 2 | Max number of PINGs without a reply from a NATS server before closing the connection |
| flush_interval | integer | 500 | Interval (ms) to flush sent messages. Synchronous requests are always flushed immediately. If the interval is set to 0, all messages will be flushed immediately, similar to `natsOptions_SetSendAsap(true)` in the NATS C client. |
| echo | boolean | true | If true, messages from this connection will be echoed back by the server if the connection has matching subscriptions|
| tls_opts | list | | Options for tls::import |
| user | string | | Default username|
| password | string |   | Default password|
| token | string | | Default authentication token|
| secure | boolean | false | Indicate to the server if the client wants a TLS connection or not|
| -? | | | Provides interactive help with all options|

## Description

### constructor ?conn_name?
Creates a new instance of `nats::connection` with default options and initialises a [logger](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md) instance with the severity level set to `warn`. If you pass in a connection name, it will be sent to NATS in a `CONNECT` message, and will be indicated in the logger name.

### objectName cget option
Returns the current value of an option as described above. 

### objectName configure ?option? ?value option value...?
When given no arguments, returns a dict of all options with their current values. When given one option, returns its current value (same as `cget`). When given more arguments, assigns each value to an option. The only mandatory option is `servers`, and others have reasonable defaults. Under the hood it is implemented using the [cmdline::getoptions](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/cmdline/cmdline.md#3) command, so it understands the special `-?` option for interactive help.

### objectName reset option
Resets the option to a default value.

### objectName connect ?-async? 
Opens a TCP connection to one of the NATS servers specified in the `servers` list. Unless the `-async` option is given, this call blocks in a `vwait` loop until the connection is completed, including a TLS handshake if needed.

### objectName disconnect 
Flushes all outgoing data, closes the TCP connection and sets the `status` to "closed".

### objectName publish subject msg ?replySubj? 
Publishes a message to the specified subject. See the NATS [documentation](https://docs.nats.io/nats-concepts/subjects) for more details about subjects and wildcards. The client will check subject's validity before sending. Allowed characters are Latin-1 characters, digits, dot, dash and underscore. <br/>
`msg` is sent as is, it can be a binary string. If you specify `replySubj`, a responder will know where to send a reply. You can use the `inbox` method to generate a transient [subject name](https://docs.nats.io/developing-with-nats/sending/replyto) starting with _INBOX. However, using asynchronous requests might accomplish the same task in an easier manner - see below.<br/>
Note that for higher throughput the message is only added to a buffer, and will be flushed to the TCP socket not later than after `flush_interval` ms.

### objectName subscribe subject ?-queue queueGroup? ?-callback cmdPrefix? ?-max_msgs maxMsgs?
Subscribes to a subject (possibly with wildcards) and returns a subscription ID. Whenever a message arrives, the command prefix will be invoked from the event loop with 3 additional arguments: `subject`, `message` and `replyTo` (might be empty). If you use the [-queue option](https://docs.nats.io/developing-with-nats/receiving/queues), only one subscriber in a given queueGroup will receive each message (useful for load balancing). When given `-max_msgs`, the client will automatically unsubscribe after `maxMsgs` messages have been received.

### objectName unsubscribe subID ?-max_msgs maxMsgs? 
Unsubscribes from a subscription with a given `subID` immediately. If `-max_msgs` is given, unsubscribes after this number of messages has been received **on this `subID`**. In other words, if you have already received 10 messages, and then you call `unsubscribe $subID -max_msgs 10`, you will be unsubscribed immediately.

### objectName request subject message ?-timeout ms? ?-callback cmdPrefix? 
Sends a message to the specified subject using an automatically generated transient `replyTo` subject (inbox). 
- If no callback is given, the request is synchronous, is flushed to the socket immediately, and blocks in (possibly, coroutine-aware) `vwait` until a reply is received. The reply is the return value. If no reply arrives within `timeout`, it raises an error "TIMEOUT".
- If a callback is given, the call returns immediately, and when a reply is received or a timeout fires, the command prefix will be invoked from the event loop with 2 additional arguments: `timedOut` (equal to 1, if the request timed out) and a `reply`.

### objectName ping ?-timeout ms?
A blocking call that triggers a ping-pong exchange with the NATS server and returns true upon success. If the server does not reply within the specified timeout (ms), it raises `TIMEOUT` error. Default timeout is 10s. You can use this method to check if the server is alive or to force flush outgoing data.

### objectName inbox 
Returns a new inbox - random subject starting with _INBOX.

### objectName current_server 
Returns a 2-element list with host and port of the current NATS server.

### objectName logger 
Returns a logger instance.

### objectName destroy
TclOO destructor. Flushes pending data and closes the TCP socket.

## Error handling
All synchronous errors are raised using `throw {NATS <error_type>} human-readable message`. 

| Error type        | Reason   | 
| ------------- |--------|
| NO_CONNECTION | Attempt to subscribe or send a message before calling `connect` |
| NO_SERVERS | No NATS servers available|
| NO_CREDS | NATS server requires authentication, but no credentials are known for it |
| INVALID_ARG | Invalid argument |
| CONNECT_FAILED | Raised by `connect` if it failed to connect to all servers |
| TIMEOUT | Timeout of a synchronous request or ping |

Asynchronous errors are sent to the logger and can also be queried/traced using 
`set ${obj}::last_error`.
| Error type        | Reason   | 
| ------------- |--------|
| BROKEN_SOCKET | TCP socket failed |
| TLS_FAILED | TLS handshake failed |
| PROTOCOL_ERR | A protocol error from the server side, e.g. maximum control line exceeded |
| STALE_CONNECTION | NATS server closed the connection, because the client did not respond to PING on time |
| CONNECT_FAILED | Failed to connect to a NATS server; the client will try the next server from the pool |
