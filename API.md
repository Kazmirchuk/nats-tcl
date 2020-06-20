# Name
nats - a client library for the NATS message broker.

## Synopsis

package require nats ?0.9?

[**::nats::connection new** *?conn_name?*](#constructor) <br/>
[*objectName* **cget** *option*](#objectName-cget-option) <br/>
[*objectName* **configure** *?option? ?value option value ...?*](#objectName-configure-option-value-option-value) <br/>
[*objectName* **connect** *?-async?*](#objectName-connect-?-async?) <br/>
[*objectName* **disconnect**](#objectName-disconnect) <br/>
[*objectName* **publish** *subject msg ?replySubj?*](#objectName-publish-subject-msg-?replySubj?) <br/>
[*objectName* **subscribe** *subject ?-queue queueName? ?-callback cmdPrefix?*](#objectName-subscribe-subject-?-queue-queueName?-?-callback-cmdPrefix?) <br/>
[*objectName* **unsubscribe** *subID ?maxMessages?*](#objectName-unsubscribe-subID-?maxMessages?) <br/>
[*objectName* **request** *subject message ?-timeout ms? ?-callback cmdPrefix?*](#objectName-request-subject-message-?-timeout-ms?-?-callback-cmdPrefix?) <br/>
[*objectName* **ping** *?timeout?*](#objectName-ping-?timeout?) <br/>
[*objectName* **inbox**](#objectName-inbox) <br/>
[*objectName* **destroy**](#objectName-destroy)

## Callbacks
All callbacks are treated as command prefixes (like [trace](https://www.tcl.tk/man/tcl8.6/TclCmd/trace.htm) callbacks), so in addition to a command itself they may include user-supplied arguments. They are invoked as follows:

**connectionCallback** *status* (invoked at the moment the status changes) <br/>
**subscriptionCallback** *subject message replyTo* (invoked from the event loop)<br/>
**asyncRequestCallback** *timedOut message* (invoked from the event loop)<br/>
## Options

The **configure** method accepts the following options. Make sure to set them *before* calling **connect**.

| Option        | Type   | Default | Comment |
| ------------- |--------|---------|---------|
| servers (mandatory)      | list   |         | URLs of NATS servers|
| connection_cb | list   |         | Command prefix to be invoked when the connection is lost, restored or closed |
| name          | string |         | Client name sent to NATS server when connecting|
| pedantic      | boolean |false   | Pedantic protocol mode. If true some extra checks will be performed by NATS server|
| verbose       | boolean | false | If true, every protocol message is echoed by the server with +OK. Has no effect on functioning of the client itself |
|connect_timeout | integer | 2000 | Connection timeout (ms) |
| reconnect_time_wait | integer | 2000 | How long to wait between two reconnect attempts to the same server (ms)|
| ping_interval | integer | 120000 | Interval (ms) to send PING messages to NATS server|
| max_outstanding_pings | integer | 2 | Max number of PINGs without a reply from NATS before closing the connection |
| flush_interval | integer | 500 | Interval (ms) to flush sent messages. Synchronous requests are always flushed immediately. |
| randomize | boolean | true | Shuffle the list of NATS servers before connecting|
| echo | boolean | true | If true, messages from this connection will be sent by the server back if the connection has matching subscriptions|
| tls_opts | list | | Options for tls::import |
| user | string | | Default username|
| password | string |   | Default password|
| token | string | | Default authentication token|
| error | string | | Last socket error (read-only) |
| logger | command | | Logger instance (read-only) |
| status | string | | Connection status: closed, connecting or connected (read-only) |
| -? | | | Provides interactive help with all options

## Description

### constructor
construct
### objectName cget option
get options
### objectName configure ?option? ?value option value...?
configure
### objectName connect ?-async? 
connect
### objectName disconnect 
disconnect
### objectName publish subject msg ?replySubj? 
publish
### objectName subscribe subject ?-queue queueName? ?-callback cmdPrefix? 
subscribe
### objectName unsubscribe subID ?maxMessages? 
unsubscribe
### objectName request subject message ?-timeout ms? ?-callback cmdPrefix? 
request
### objectName ping ?timeout? 
ping
### objectName inbox 
inbox
### objectName destroy
destructor