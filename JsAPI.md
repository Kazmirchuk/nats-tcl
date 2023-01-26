# JetStream API

JetStream functionality of NATS can be accessed by creating the `nats::jet_stream` TclOO object. Do not create it directly - instead, call the [jet_stream](CoreAPI.md#objectname-jet_stream--timeout-ms--domain-domain) method of your `nats::connection`. You can have multiple jet_stream objects created from the same connection, each having its own timeout and domain.

## Synopsis

[*js* publish *subject message ?args?*]()<br/>
[*js* publish_msg *message ?args?*]()<br/>
[*js* consume *stream consumer* ?-timeout *ms*? ?-batch_size *batch_size*?]()<br/>
[*js* ack *message*]()<br/>
[*js* ack_sync *message*]()<br/>
[*js* nak *message* ?-delay *ms*?]()<br/>
[*js* in_progress *message*]()<br/>
[*js* term *message*]()<br/>
[*js* metadata *message*]()<br/>

[*js* add_stream *stream* ?-option *value*?..]()<br/>
[*js* delete_stream *stream*]()<br/>
[*js* purge_stream *stream* ?-filter *subject*? ?-keep *int*? ?-seq *int*?]()<br/>
[*js* stream_info *stream*]()<br/>
[*js* stream_names ?-subject *subject*?]()<br/>

[*js* add_consumer *stream ?args?*]()<br/>
[*js* add_pull_consumer *stream consumer ?args?*]()<br/>
[*js* add_push_consumer *stream consumer deliver_subject ?args?*]()<br/>
[*js* delete_consumer *stream consumer*]()<br/>
[*js* consumer_info *stream consumer*]()<br/>
[*js* consumer_names *stream*]()<br/>

[*js* stream_msg_get *stream ?args?*]()<br/>
[*js* stream_msg_delete *stream* -seq *sequence* ?-no_erase *no_erase*?]()<br/>

[*js* destroy]()<br/>

## Description
The [Core NATS](CoreAPI.md) pub/sub functionality offers the at-most-once delivery guarantee based on TCP. This is sufficient for many applications, where an individual message doesn't have much value. In case of a transient network disconnection, a subscriber simply waits until the connection is restored and a new message is delivered. 

In some applications, however, each message have a real business value and must not be lost in transit. These applications should use [JetStream](https://docs.nats.io/nats-concepts/jetstream) that offers at-least-once and exactly-once delivery guarantees despite network disruptions or software crashes. Also, JetStream provides temporal decoupling of publishers and subscribers (consumers), i.e. each published message is persisted on disk and delivered to a consumer when it is ready.

JetStream introduces no new elements in the NATS protocol, but builds on top of it: primarily the request-reply function, with special JSON messages and status headers.

Unlike the core NATS server functionality that is simple, stable and well-documented, JetStream is quite large and under active development by Synadia. Not all aspects of JetStream are consistently documented. I've used these sources for development of nats-tcl:
- [docs.nats.io](https://docs.nats.io/nats-concepts/jetstream)
- [ADRs](https://github.com/nats-io/nats-architecture-and-design)
- [nats CLI](https://github.com/nats-io/natscli) subcommand `schema`
- `nats-server` in tracing mode (-DV)
- and of course studying source code of nats.go, nats.c and nats.py

Note that API of the official NATS clients (`JetStreamContext`) is designed in a way that allows to create a consumer implicitly with a subscription (e.g. `JetStreamContext.pull_subscribe` in nats.py). I find such design somewhat confusing, so the Tcl API clearly distinguishes between creating a consumer and a subscription.

Unfortunately, I don't have enough capacity to cover the whole JetStream functionality or keep up with Synadia's development. So, I've decided to focus on the most useful functions:
- publishing messages to streams with confirmations
- fetching messages from pull consumers
- support for all kinds of message acknowledgement
- JetStream asset management (streams and pull/push consumers)

The implementation can tolerate minor changes in JetStream API. E.g. if a publish acknowledgment is returned just as a dict parsed from JSON. So, if in future the JSON schema gets a new field, it will be automatically available in this dict.

If you need other JetStream functions, e.g. the Key/Value Store or Object Store, you can easily implement them yourself using core NATS requests. No need to interact directly with the TCP socket. Of course, PRs are always welcome.

## JetStream Wire Format
The JetStream wire format uses nanoseconds for timestamps and durations in all requests and replies. To be consistent with the rest of the Tcl API, the client converts them to milliseconds before returning to a user. And vice versa: all function arguments are accepted as ms and converted to ns before sending.

Paging with total/offset/limit is not supported.
## Commands
### js publish *subject message ?args?*
Publishes `message` (payload) to a [stream](https://docs.nats.io/jetstream/concepts/streams) on the specified `subject` and returns an acknowledgement (`pubAck`) from the NATS server. The method works based on the [request](CoreAPI.md#objectName-request-subject-message-args) method.

You can provide the following options:
- `-timeout ms` - timeout for the underlying NATS request. Default timeout is taken from the `jet_stream` object.
- `-callback cmdPrefix` - do not block and deliver the acknowledgement to this callback.
- `-stream stream` - set the expected target stream (recommended!). If the subject does not match the stream, NATS will return an error.

If no callback is given, the returned value is a dict with following fields:
- stream - stream name where the message was saved
- seq - sequence number
- duplicate - optional boolean indicating that this message is a duplicate

If no stream exists on specified `subject`, the call will raise `ErrNoResponders`. If JetStream reported an error, it raises `ErrJSResponse`.

If a callback is given, the call returns immediately. When a reply from JetStream is received or a timeout fires, the callback will be invoked from the event loop. It must have the following signature:<br/>
**cmdPrefix** *timedOut pubAck pubError*<br/>

- `timedOut` is a boolean equal to 1, if the request timed out or this was `ErrNoResponders`.<br/>
- `pubAck` is a dict as described above (empty if JetStream reported an error)
- `pubError` is a non-empty dict if JetStream reported an error, with following fields:
  - code: high-level HTTP-like code e.g. 404 if a stream wasn't found
  - err_code: more specific JetStream code, e.g. 10060
  - errorMessage: human-readable error message, e.g. "expected stream does not match"
### js publish_msg *message ?args?*
Publishes `message` (created with [nats::msg create](CoreAPI.md#msg-create-subject--data-payload--reply-replysubj)) to a stream. Other options are the same as above. Use this method to publish a message with headers.
### js consume *stream consumer* ?-timeout *ms*? ?-batch_size *batch_size*?
Consumes `batch_size` number of messages (default 1) from a [pull consumer](https://docs.nats.io/jetstream/concepts/consumers) defined on a [stream](https://docs.nats.io/jetstream/concepts/streams) and returns a list of messages (could be empty). This is the analogue of PullSubscribe + [fetch](https://pkg.go.dev/github.com/nats-io/nats.go#Subscription.Fetch) in official NATS clients.

The underlying JetStream API is rather intricate, so I recommend reading [ARD-13](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-13.md) for better understanding.

If `-timeout` is omitted, the client sends a `no_wait` request, asking NATS to deliver only currently pending messages. If there are no pending messages, the method returns an empty list.

If `-timeout` is given, it defines both the client-side and server-side timeouts for the pull request:
- the client-side timeout is the timeout for the underlying `request`
- the server-side timeout is 10ms shorter than `timeout`, and it is sent in the `expires` JSON field. This behaviour is consistent with nats.go

In either case, the request is synchronous and blocks in a (coroutine-aware) `vwait` until all expected messages are received or the pull request expires. If the client-side timeout fires before the server-side timeout, and no messages have been received, the method raises `ErrTimeout`. In all other cases the method returns a list with as many messages as currently avaiable, but not more than `batch_size`.

There is no asynchronous version of this method with `-callback`. If you do need multiple open pull requests at the same time, you can issue them in separate coroutines.

The client handles status messages 404, 408 and 409 transparently. You can see them in the debug log, if needed.

Depending on the consumer's [AckPolicy](https://docs.nats.io/nats-concepts/jetstream/consumers#ackpolicy), you might need to acknowledge the received messages with one of the methods below. [This](https://docs.nats.io/using-nats/developer/develop_jetstream/consumers#delivery-reliability) official doc explains all different kinds of ACKs.

### js ack *message*
Sends a positive ACK to NATS. This method is implemented using [publish](CoreAPI.md#objectname-publish-subject-message--reply-replyto) and returns immediately. Using `ack_sync` is more reliable.
### js ack_sync *message*
Sends a positive ACK to NATS and waits for a confirmation (recommended).
### js nak *message* ?-delay *ms*?
Negatively acknowledges a message. This tells the server to redeliver the message either immediately or after `delay` ms.
### js in_progress *message*
Sends "work in progress" ACK to NATS and resets the redelivery timer on the server
### js term *message*
Sends "terminate" ACK to NATS. The message will not be redelivered.
### js metadata *message*
Returns a dict with metadata of the message. It is extracted from the reply-to field.
### js add_stream *stream* ?-option *value*?..
Adds a new `stream` with configuration specified as option-value pairs. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/streams#configuration) for explanation of these options.
| Option        | Type   | Default |
| ------------- |--------|---------|
| -description  | string |         |
| -subjects     | list of strings  | required|
| -retention    | one of: limits, interest,<br/> workqueue |limits |
| -max_consumers  | int |         |
| -max_msgs  | int |         |
| -max_bytes  | int |         |
| -discard  | one of: new, old | old |
| -max_age  | ms |         |
| -max_msgs_per_subject  | int |         |
| -max_msg_size  | int |         |
| -storage  | one of: memory, file | file |
| -num_replicas  | int |         |
| -no_ack  | boolean |         |
| -duplicate_window  | ms |         |
| -sealed  | boolean |         |
| -deny_delete  | boolean |         |
| -deny_purge  | boolean |         |
| -allow_rollup_hdrs  | boolean |         |
| -allow_direct  | boolean |         |
| -mirror_direct  | boolean |         |


Returns a JetStream response as a dict.
### js delete_stream *stream*
Deletes the stream.
### js purge_stream *stream* ?-filter *subject*? ?-keep *int*? ?-seq *int*?
Purges the stream, deleting all messages or a subset based on filtering criteria. See also [ADR-10](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-10.md).
### js stream_info *stream*
Returns stream information as a dict.
### js stream_names ?-subject *subject*?
Returns a list of all streams or the streams matching the filter.
### js add_consumer *stream* ?-option *value*?..
Adds a new pull or push consumer on the stream. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/consumers#configuration) for explanation of these options.
| Option        | Type   | Default |
| ------------- |--------|---------|
| -name | string | |
| -durable_name | string | |
| -description | string | |
| -deliver_policy | one of: all last new by_start_sequence<br/> by_start_time last_per_subject | all|
| -opt_start_seq | int | |
| -opt_start_time | string | |
| -ack_policy |one of: none all explicit | explicit |
| -ack_wait | ms | |
| -max_deliver | int | |
| -filter_subject | string | |
| -replay_policy | one of: instant original | instant|
| -rate_limit_bps | int | |
| -sample_freq | string | |
| -max_waiting | int | |
| -max_ack_pending | int | |
| -flow_control | boolean | |
| -idle_heartbeat | ms | |
| -headers_only | boolean | |
| -deliver_subject | string | |
| -deliver_group | string | |
| -inactive_threshold | ms | |
| -num_replicas | int | |
| -mem_storage | boolean | |


Note that starting from NATS 2.9.0, `durable_name` is deprecated. `name` should be used instead.<br/>
Returns a JetStream response as a dict.
### js add_pull_consumer *stream consumer ?args?*
A shortcut for `add_consumer` to create a durable pull consumer. Rest of `args` are the same as above.
### js add_push_consumer *stream consumer deliver_subject ?args?*
A shortcut for `add_consumer` to create a durable push consumer. Rest of `args` are the same as above.
### js delete_consumer *stream consumer*
Deletes the consumer.
### js consumer_info *stream consumer*
Returns consumer information as a dict.
### js consumer_names *stream*
Returns a list of all consumers defined on this stream.
### js stream_msg_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?
'Direct Get' a message from stream `stream` by given `subject` or `sequence`. See also [ADR-31](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-31.md).
### js stream_msg_delete *stream* -seq *sequence* ?-no_erase *no_erase*?
Delete message from stream `stream` with given `sequence`.
### js destroy
TclOO destructor. Remember to call it before destroying the parent `nats::connection`.

## Error handling
In addition to all core NATS errors, the `jet_stream` methods may throw `ErrJSResponse` if JetStream API has returned an error. The Tcl error code will contain also JetStream `code` and `err_code`. JetStream `description` will be used for the error message. See also [ADR-1](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-1.md#error-response).

Note that if JetStream is not enabled in the NATS server, all requests to JetStream API will throw `ErrNoResponders`. This is different from official NATS clients that replace it with `ErrJetStreamNotEnabled`. I don't see much value in doing this in the Tcl client.
