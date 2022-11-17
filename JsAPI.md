# JetStream

JetStream functionality of NATS can be accessed using the `nats` package by creating a `jetStream` TclOO object. Do not create it directly - instead, call the `jet_stream` method of your `nats::connection` after you've connected to a NATS server.

## Synopsis

[*objectName* **jet_stream**](#objectName-jet_stream) <br/>
[*jetStreamObject* **add_stream** *stream ?-timeout ms? ?-callback cmdPrefix? ?-subjects subjects? ?-retention retention? ?-max_consumers max_consumers? ?-max_msgs max_msgs? ?-max_bytes max_bytes? ?-max_age max_age? ?-max_msgs_per_subject max_msgs_per_subject? ?-max_msg_size max_msg_size? ?-discard discard? ?-storage storage? ?-num_replicas num_replicas? ?-duplicate_window duplicate_window? ?-sealed sealed? ?-deny_delete deny_delete? ?-deny_purge deny_purge? ?-allow_rollup_hdrs allow_rollup_hdrs?*](#jetstreamobject-add_stream-stream--timeout-ms--callback-cmdprefix--subjects-subjects--retention-retention--max_consumers-max_consumers--max_msgs-max_msgs--max_bytes-max_bytes--max_age-max_age--max_msgs_per_subject-max_msgs_per_subject--max_msg_size-max_msg_size--discard-discard--storage-storage--num_replicas-num_replicas--duplicate_window-duplicate_window--sealed-sealed--deny_delete-deny_delete--deny_purge-deny_purge--allow_rollup_hdrs-allow_rollup_hdrs) <br/>
[*jetStreamObject* **delete_stream** *stream ?-timeout ms? ?-callback cmdPrefix?*](#jetstreamobject-delete_stream-stream--timeout-ms--callback-cmdprefix) <br/>
[*jetStreamObject* **purge_stream** *stream ?-timeout ms? ?-callback cmdPrefix?*](#jetstreamobject-purge_stream-stream--timeout-ms--callback-cmdprefix) <br/>
[*jetStreamObject* **stream_names** *?-timeout ms? ?-callback cmdPrefix?*](#jetstreamobject-stream_names--timeout-ms--callback-cmdprefix) <br/>
[*jetStreamObject* **stream_info** *?stream? ?-timeout ms? ?-callback cmdPrefix?*](#jetstreamobject-stream_info-stream--timeout-ms--callback-cmdprefix) <br/>
[*jetStreamObject* **stream_msg_get** *stream ?-last_by_subj subject? ?-seq sequence? ?-timeout ms? ?-callback cmdPrefix?*](#jetstreamobject-stream_msg_get-stream--last_by_subj-subject--seq-sequence--timeout-ms--callback-cmdprefix) <br/>
[*jetStreamObject* **stream_msg_delete** *stream -seq sequence ?-timeout ms? ?-callback cmdPrefix?*](#jetstreamobject-stream_msg_delete-stream--seq-sequence--timeout-ms--callback-cmdprefix) <br/>
[*jetStreamObject* **consume** *stream consumer ?-timeout ms? ?-callback cmdPrefix? ?-batch_size batch_size?*](#jetStreamObject-consume-stream-consumer--timeout-ms--callback-cmdPrefix--batch_size-batch_size) <br/>
[*jetStreamObject* **ack** *message*](#jetStreamObject-ack-message) <br/>
[*jetStreamObject* **publish** *subject message ?-timeout ms? ?-callback cmdPrefix? ?-header header?*](#jetStreamObject-publish-subject-message--timeout-ms--callback-cmdPrefix--header-header) <br/>

## Callbacks
All callbacks are treated as command prefixes (like [trace](https://www.tcl.tk/man/tcl8.6/TclCmd/trace.htm) callbacks), so in addition to a command itself they may include user-supplied arguments. They are invoked from the event loop as follows:

### JetStream: <br/>
**publishCallback** *timedOut pubAck error* <br/>

## Description

### objectName jet_stream
Returns `jetStreamObject` TclOO object to work with [JetStream](https://docs.nats.io/jetstream/jetstream).

### jetStreamObject add_stream stream ?-timeout ms? ?-callback cmdPrefix? ?-subjects subjects? ?-retention retention? ?-max_consumers max_consumers? ?-max_msgs max_msgs? ?-max_bytes max_bytes? ?-max_age max_age? ?-max_msgs_per_subject max_msgs_per_subject? ?-max_msg_size max_msg_size? ?-discard discard? ?-storage storage? ?-num_replicas num_replicas? ?-duplicate_window duplicate_window? ?-sealed sealed? ?-deny_delete deny_delete? ?-deny_purge deny_purge? ?-allow_rollup_hdrs allow_rollup_hdrs?
Add stream `stream` with spedified properties. `subjects` properties is a list of subjects, `duplicate_window` and `max_age` are duration which should be given in milliseconds unit.

### jetStreamObject delete_stream stream ?-timeout ms? ?-callback cmdPrefix?
Delete stream `stream`.

### jetStreamObject purge_stream stream ?-timeout ms? ?-callback cmdPrefix?
Purge stream `stream`.

### jetStreamObject stream_names ?-timeout ms? ?-callback cmdPrefix?
Get available stream names existing on server.

### jetStreamObject stream_info ?stream? ?-timeout ms? ?-callback cmdPrefix?
Get info about stream `stream` or if `stream` is empty - get information about all streams.

### jetStreamObject stream_msg_get stream ?-last_by_subj subject? ?-seq sequence? ?-timeout ms? ?-callback cmdPrefix?
Get message from stream `stream` by given `subject` or `sequence`.

### jetStreamObject stream_msg_delete stream -seq sequence ?-timeout ms? ?-callback cmdPrefix?
Delete message from stream `stream` with given `sequence`.

### jetStreamObject consume stream consumer ?-timeout ms? ?-callback cmdPrefix? ?-batch_size batch_size?
Consume a message or `batch_size` number of messages from a [consumer](https://docs.nats.io/jetstream/concepts/consumers) defined on a [stream](https://docs.nats.io/jetstream/concepts/streams). Similarly to the `request` method:
- If no callback is given, the request is synchronous and blocks in a (coroutine-aware) `vwait` until a response is received. The response message is always returned as a dict. If no response arrives within `timeout`, it raises `ErrTimeout`.
- If a callback is given, the call returns immediately, and when a reply is received or a timeout fires, the command prefix will be invoked from the event loop with 2 additional arguments: `timedOut` (true, if the request timed out) and `message` as a dict (same as for `asyncRequestCallback`). If your consumer is configured for explicit acknowledgement, pass the received `message` to the `ack` method as shown below.

Default `batch_size` is 1. `batch_size`>1 is possible only in the async version, i.e. `cmdPrefix` becomes mandatory.

### jetStreamObject ack message
Acknowledge the received `message` from the *jetStreamObject* **consume** method. If the message is not acknowledged, it is redelivered on next `consume` (depending on NATS server settings).

### jetStreamObject publish subject message ?-timeout ms? ?-callback cmdPrefix? ?-header header?
Publish `message` to a [stream](https://docs.nats.io/jetstream/concepts/streams) on the specified `subject`. `timeout` and `cmdPrefix` have similar meaning as in `request` method. If no stream exists on specified `subject`, the call will raise `ErrNoResponders`.
- In synchronous version the method waits for acknowledgement and returns a response from server as a dict containing `stream`, `seq` and optionally `duplicate` keys. If NATS server returned an error, it raises `ErrJSResponse`.
- In asynchronous version `cmdPrefix` callback is called with 3 additional arguments: `timedOut` (true, if the request timed out), `pubAck` and `error`. If `error` is not empty, it is a dict containing `code` and `description` JSON keys sent by NATS server, otherwise `pubAck` contains information passed from NATS server as a dict with keys: `stream`, `seq` and optionally `duplicate`.

## Error handling
TBW
