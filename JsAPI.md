# JetStream API

JetStream functionality of NATS can be accessed by creating the `nats::jet_stream` TclOO object. Do not create it directly - instead, call the [jet_stream](CoreAPI.md#objectname-jet_stream--timeout-ms--domain-domain) method of your `nats::connection`. You can have multiple JS objects created from the same connection, each having its own timeout and domain.

Key/value-related functions of `nats::jet_stream` are documented [here](KvAPI.md).

# Synopsis
## Class `nats::jet_stream`
[*js* publish *subject message ?args?*](#js-publish-subject-message-args)<br/>
[*js* publish_msg *message ?args?*](#js-publish_msg-message-args)<br/>
[*js* fetch *stream consumer ?args?*](#js-fetch-stream-consumer-args)<br/>
[*js* ack *message*](#js-ack-message)<br/>
[*js* ack_sync *message*](#js-ack_sync-message)<br/>
[*js* nak *message* ?-delay *ms*?](#js-nak-message--delay-ms)<br/>
[*js* in_progress *message*](#js-in_progress-message)<br/>
[*js* term *message*](#js-term-message)<br/>
[*js* cancel_pull_request *reqID*](#js-cancel_pull_request-reqID)<br/>

[*js* add_stream *stream* ?-option *value*?..](#js-add_stream-stream--option-value)<br/>
[*js* update_stream *stream* ?-option *value*?..](#js-update_stream-stream--option-value)<br/>
[*js* add_stream_from_json *json_config*](#js-add_stream_from_json-json_config)<br/>
[*js* delete_stream *stream*](#js-delete_stream-stream)<br/>
[*js* purge_stream *stream* ?-filter *subject*? ?-keep *int*? ?-seq *int*?](#js-purge_stream-stream--filter-subject--keep-int--seq-int)<br/>
[*js* stream_info *stream*](#js-stream_info-stream)<br/>
[*js* stream_names ?-subject *subject*?](#js-stream_names--subject-subject)<br/>

[*js* add_consumer *stream* ?-option *value*?..](#js-add_consumer-stream--option-value)<br/>
[*js* update_consumer *stream* ?-option *value*?..](#js-update_consumer-stream--option-value)<br/>
[*js* add_pull_consumer *stream consumer ?args?*](#js-add_pull_consumer-stream-consumer-args)<br/>
[*js* add_push_consumer *stream consumer deliver_subject ?args?*](#js-add_push_consumer-stream-consumer-deliver_subject-args)<br/>
[*js* add_consumer_from_json *stream consumer json_config*](#js-add_consumer_from_json-stream-consumer-json_config)<br/>
[*js* delete_consumer *stream consumer*](#js-delete_consumer-stream-consumer)<br/>
[*js* consumer_info *stream consumer*](#js-consumer_info-stream-consumer)<br/>
[*js* consumer_names *stream*](#js-consumer_names-stream)<br/>
[*js* ordered_consumer *stream ?args?*](#js-ordered_consumer-stream-args)<br/>

[*js* stream_msg_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?](#js-stream_msg_get-stream--last_by_subj-subj--next_by_subj-subj--seq-int)<br/>
[*js* stream_direct_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?](#js-stream_direct_get-stream--last_by_subj-subj--next_by_subj-subj--seq-int)<br/>
[*js* stream_msg_delete *stream* -seq *int* ?-no_erase *bool*?](#js-stream_msg_delete-stream--seq-int--no_erase-bool)<br/>

[*js* account_info](#js-account_info)<br/>
[*js* api_prefix](#js-api_prefix)<br/>

[*js* destroy](#js-destroy)<br/>

## Class `nats::ordered_consumer`
[*consumer* info](#consumer-info)<br/>
[*consumer* name](#consumer-name)<br/>
[*consumer* destroy](#consumer-destroy)<br/>

## Namespace Commands
[nats::metadata *message*](#natsmetadata-message)<br/>
[nats::make_stream_source ?-option *value*?..](#natsmake_stream_source--option-value)<br/>
[nats::make_subject_transform ?-option *value*?..](#natsmake_subject_transform--option-value)<br/>
[nats::make_republish ?-option *value*?..](#natsmake_republish--option-value)

# Description
The [Core NATS](CoreAPI.md) pub/sub functionality offers the at-most-once delivery guarantee based on TCP. This is sufficient for many applications, where an individual message doesn't have much value. In case of a transient network disconnection, a subscriber simply waits until the connection is restored and a new message is delivered. 

In some applications, however, each message has a real business value and must not be lost in transit. These applications should use [JetStream](https://docs.nats.io/nats-concepts/jetstream) that offers at-least-once and exactly-once delivery guarantees despite network disruptions or software crashes. Also, JetStream provides temporal decoupling of publishers and subscribers (consumers), i.e. each published message is persisted on disk and delivered to a consumer when it is ready.

JetStream introduces no new elements in the NATS protocol, but builds on top of it: primarily the request-reply function, with special JSON messages and status headers.

Unlike the core NATS server functionality that is simple, stable and well-documented, JetStream is quite large and under active development by Synadia. Not all aspects of JetStream are consistently documented. I've used these sources for development of nats-tcl:
- [docs.nats.io](https://docs.nats.io/nats-concepts/jetstream)
- [ADRs](https://github.com/nats-io/nats-architecture-and-design)
- [nats CLI](https://github.com/nats-io/natscli) subcommand `schema`
- `nats-server` in tracing mode (-DV)
- and of course studying source code of nats.go, nats.c and nats.py

Unfortunately, I don't have enough capacity to cover the whole JetStream functionality or keep up with Synadia's development. So, I've decided to focus on the most useful functions:
- publishing messages to streams with confirmations
- fetching messages from pull consumers
- support for all kinds of message acknowledgement
- JetStream asset management (streams and pull/push consumers)
- [Key/Value store](KvAPI.md)

The implementation can tolerate minor changes in JetStream API. E.g. a publish acknowledgment is returned just as a dict parsed from JSON. So, if in future the JSON schema gets a new field, it will be automatically available in this dict.

If you need other JetStream functions, e.g. Object Store, you can easily implement them yourself using core NATS requests. No need to interact directly with the TCP socket. Of course, PRs are always welcome.

## Notes on the JetStream Client API v2
In June 2023 Synadia has [announced](https://nats.io/blog/preview-release-new-jetstream-client-api/) some major changes to the JetStream Client API. You can find more details in [ADR-37](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-37.md), [nats.go](https://pkg.go.dev/github.com/nats-io/nats.go/jetstream) docs and the [migration guide](https://natsbyexample.com/examples/jetstream/api-migration/go). Note that these changes are purely client-side, and there are no new server-side concepts.

Of course, this announcement affects development of the Tcl client as well. A lot of effort has been invested in the design following JetStream API v1. I need to balance my workload vs keeping in line (more or less) with other client libraries. So, in this library there is no clear distinction between v1 and v2, but rather a pragmatic middle ground. Here is a list of most important design changes by Synadia together with my responses:

1. Streams and Consumers have their own classes now. So, e.g. to query the `CONSUMER.INFO` NATS API using JetStream v1 you call:
```go
info, err := js.ConsumerInfo(streamName, consumerName)
```
While with JetStream v2 you call:
```go
stream, err := js.Stream(ctx, streamName)
consumer, err := stream.Consumer(ctx, consumerName)
info, err := consumer.Info(ctx)
```
The benefit is clear for all programming languages having proper autocompletion support, because you get a comprehensible list of all functions related to a stream or consumer, instead of one huge list of functions in `JetStreamContext`. Unfortunately, Tcl doesn't have such autocompletion, so introduction of new TclOO classes for streams and consumers would only complicate the library. However, there is `nats::ordered_consumer` that is similar to [OrderedConsumer](https://pkg.go.dev/github.com/nats-io/nats.go/jetstream#readme-ordered-consumers) in JetStream v2. 

2. Removal of the overly complex `JetStream.Subscribe` function. This is achieved by breaking it down to smaller specialized functions and by deprecating push consumers. <br/>
This change does not affect the Tcl client. Pull and push consumers are always created explicitly by calling `add_consumer`. There is no dedicated method to subscribe to push consumers. The core NATS subscription is perfectly adequate for durable push consumers. If it is configured with idle heartbeats, you will need to filter them out by checking `nats::msg idle_heartbeat`. And for ephemeral consumers you can use `nats::ordered_consumer`.

3. Removal of `JetStream.PullSubscribe` function. `Fetch` is now a function of `Consumer` interface that performs both subscribing and receiving messages. This change actually brings nats.go closer to nats-tcl, where `fetch` (aka `consume`) has always been working like this.

4. Introduction of the new way to pull messages from a consumer using continuous polling. This API is designed to combine the best of pull and push consumers, thus helping users to move away from push consumers. The new function is called `Consume`, while the old method is called `Fetch`. <br/>
Unfortunately, the Tcl client already has `$js consume` method that actually performs fetching and should have been called `fetch` from the beginning. So, to avoid future confusion, I've added a new method [fetch](#js-fetch-stream-consumer-args) that works exactly like `consume`. The old `consume` stays in place for backwards compatibility. If in future I decide to implement the real `consume` (continuous polling), it will be done in another TclOO class.

5. Having a dedicated Stream class allows the implementation to choose between `STREAM.MSG.GET` and `DIRECT.GET` API depending on the stream configuration, i.e. if it has AllowDirect=true. This is done transparently for the user - compare e.g. `Stream.GetMsg` in JetStream v2 with `JetStreamManager.GetMsg` in JetStream v1 that has an option `DirectGet`.<br/>The Tcl client provides separate methods for these APIs: `stream_msg_get` and `stream_direct_get` respectively. However, [key_value](KvAPI.md) class knows the stream configuration and chooses between these 2 methods automatically.

## JetStream wire format
The JetStream wire format uses nanoseconds for timestamps and durations in all requests and replies. To be consistent with the rest of the Tcl API, the client converts them to milliseconds before returning to a user. And vice versa: all function arguments are accepted as ms and converted to ns before sending.

Streams and consumers are checked according to the naming rules described in [ADR-6](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md).

Paging with total/offset/limit is not supported.

## Streams and consumers configuration in JSON format
This client library has a unique feature compared to official NATS clients: streams and consumers can be created directly from JSON configuration rather than a long list of arguments passed to a client. It is possible with 
[add_stream_from_json](#js-add_stream_from_json-json_config) and 
[add_consumer_from_json](#js-add_consumer_from_json-stream-consumer-json_config) methods.

This JSON is sent to NATS as-is. Also a JSON response is returned from the method unchanged (unless it was an error, in which case `ErrJSResponse` is raised as usual). You can obtain such JSON configuration using NATS CLI, e.g.:
```bash
nats consumer info MY_STREAM PULL_CONSUMER --json
```
Then you can save the `config` object to a JSON file.

This approach has 2 benefits:
- Configuration of streams and consumers is kept separately from Tcl source code. It can be saved in VCS or generated on the fly, and shared with NATS CLI or other NATS clients.
- It is future-proof: if the Tcl client lags behind JetStream development, you still have access to the latest JetStream features, and the library still takes care of error checking.

You can find an example in [js_mgmt.tcl](examples/js_mgmt.tcl).

# Commands
## `nats::jet_stream`
### js publish *subject message ?args?*
Publishes `message` (payload) to a [stream](https://docs.nats.io/jetstream/concepts/streams) on the specified `subject` and returns an acknowledgement (`pubAck`) from the NATS server. The method uses [request](CoreAPI.md#objectName-request-subject-message-args) under the hood.

You can provide the following options:
- `-timeout ms` - timeout for the underlying NATS request. Default timeout is taken from the `jet_stream` object.
- `-callback cmdPrefix` - do not block and deliver the acknowledgement to this callback.
- `-stream stream` - set the expected target stream (recommended!). If the subject does not match the stream, NATS will return an error.

If no callback is given, the returned `pubAck` is a dict with following fields:
- stream - stream name where the message has been saved
- seq - sequence number
- duplicate - optional boolean indicating that this message is a duplicate

If no stream exists on the specified `subject`, the call will raise `ErrNoResponders`. If JetStream reported an error, it will raise `ErrJSResponse`.

If a callback is given, the call returns immediately. When a reply from JetStream is received or the timeout fires, the callback will be invoked from the event loop. It must have the following signature:<br/>
**cmdPrefix** *timedOut pubAck pubError*<br/>

- `timedOut` is a boolean equal to 1, if the request timed out or this was `ErrNoResponders`.<br/>
- `pubAck` is a dict as described above (empty if JetStream reported an error)
- `pubError` is a non-empty dict if JetStream reported an error, with following fields:
  - code: high-level HTTP-like code e.g. 404 if a stream wasn't found
  - err_code: more specific JetStream code, e.g. 10060
  - errorMessage: human-readable error message, e.g. "expected stream does not match"

Note that you can publish messages to a stream using [nats::connection publish](CoreAPI.md#objectname-publish-subject-message--reply-replyto) as well. But in this case you have no confirmation that the message has reached the NATS server, so it misses the whole point of using JetStream.
### js publish_msg *message ?args?*
Publishes `message` (created with [nats::msg create](CoreAPI.md#msg-create-subject--data-payload--reply-replysubj)) to a stream. Other options are the same as above. Use this method to publish a message with headers.
### js fetch *stream consumer ?args?*
Consumes a number of messages from a [pull consumer](https://docs.nats.io/jetstream/concepts/consumers) defined on a [stream](https://docs.nats.io/jetstream/concepts/streams). This is the analogue of `PullSubscribe` + `fetch` in official NATS clients.

You can provide the following options:
- `-batch_size int` - number of messages to consume. Default batch is 1.
- `-timeout ms` - pull request timeout - see below.
- `-callback cmdPrefix` - do not block and deliver messages to this callback.

The underlying JetStream API is rather intricate, so I recommend reading [ARD-13](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-13.md) for better understanding.

Pulled messages are always returned as Tcl dicts irrespectively of the `-dictmsg` option. They contain metadata that can be accessed using [nats::metadata](#natsmetadata-message).

If `-timeout` is omitted, the client sends a `no_wait` request, asking NATS to deliver only currently pending messages. If there are no pending messages, the method returns an empty list.

If `-timeout` is given, it defines both the client-side and server-side timeouts for the pull request:
- the client-side timeout is the timeout for the underlying `request`
- the server-side timeout is 10ms shorter than `timeout`, and it is sent in the `expires` JSON field[^1]. This behaviour is consistent with `nats.go`.

If a callback is not given, the request is synchronous and blocks in a (coroutine-aware) `vwait` until all expected messages are received or the pull request expires. If the client-side timeout fires *before* the server-side timeout, and no messages have been received, the method raises `ErrTimeout`[^2]. In all other cases it returns a list with as many messages as currently avaiable, but not more than `batch_size`.

If a callback is given, the call returns immediately. Return value is a unique ID that can be used to cancel the pull request. When a message is pulled or a timeout fires, the callback will be invoked from the event loop. It must have the following signature:

**cmdPrefix** *timedOut message*

The client handles status messages 404 (no messages), 408 (request expired) and 409 (consumer deleted) appropriately. You can see them in the debug log, if needed. Also, they are passed to the callback together with `timedOut=1`.

Overall, the synchronous form of `fetch` has clearer error reporting, because it can throw `ErrConsumerNotFound`, `ErrStreamNotFound`, `ErrJetStreamNotEnabled` etc that are not available to the asynchronous callback.

Depending on the consumer's [AckPolicy](https://docs.nats.io/nats-concepts/jetstream/consumers#ackpolicy), you might need to acknowledge the received messages with one of the methods below. [This page](https://docs.nats.io/using-nats/developer/develop_jetstream/consumers#delivery-reliability) explains all different kinds of ACKs.

**NB!** This method used to be called `consume`. However, [JetStream Client API V2](https://nats.io/blog/preview-release-new-jetstream-client-api/) has introduced a new way for continuously fetching messages using a self-refilling buffer, called "consume". This method is not supported yet by this library. So, to avoid confusion for new users of the library, `consume` is now deprecated, and new Tcl code should use `fetch`.

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
### js cancel_pull_request *reqID*
Cancels the asynchronous pull request with the given `reqID`.
### js add_stream *stream* ?-option *value*?..
Creates a new `stream` with configuration specified as option-value pairs. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/streams#configuration) for explanation of these options.
| Option        | Type   | Default | Comment |
| ------------- |--------|---------|---------|
| -description  | string |         | |
| -subjects     | list of strings  | (required)| |
| -retention    | one of: limits, interest,<br/> workqueue |limits | |
| -max_consumers  | int |         | |
| -max_msgs  | int |         | |
| -max_bytes  | int |         | |
| -discard  | one of: new, old | | |
| -max_age  | ms |         | |
| -max_msgs_per_subject  | int |         | |
| -max_msg_size  | int |         | |
| -storage  | one of: memory, file | file | |
| -num_replicas  | int |         | |
| -no_ack  | boolean |         | |
| -duplicate_window  | ms |         | |
| -mirror | JSON | |use [nats::make_stream_source](#natsmake_stream_source--option-value)|
| -sources | list of JSON | |use [nats::make_stream_source](#natsmake_stream_source--option-value)|
| -sealed  | boolean |         | |
| -deny_delete  | boolean |         | |
| -deny_purge  | boolean |         | |
| -allow_rollup_hdrs  | boolean |         | |
| -compression  | one of: none, s2 | none | |
| -first_seq | int | | |
| -subject_transform | JSON | |use [nats::make_subject_transform](#natsmake_subject_transform--option-value)|
| -republish | JSON | |use [nats::make_republish](#natsmake_republish--option-value)|
| -allow_direct  | boolean |         | |
| -mirror_direct  | boolean |         | |
| -metadata  | dict | | |

Returns a JetStream reply (same as `stream_info`).
### js update_stream *stream* ?-option *value*?..
Updates the `stream` configuration with new options. Arguments and the return value are the same as in `add_stream`.[^3]
### js add_stream_from_json *json_config*
Creates a stream with configuration specified as JSON. The stream name is taken from the JSON.
### js delete_stream *stream*
Deletes the stream.
### js purge_stream *stream* ?-filter *subject*? ?-keep *int*? ?-seq *int*?
Purges the stream, deleting all messages or a subset based on filtering criteria. See also [ADR-10](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-10.md).
### js stream_info *stream*
Returns stream information as a dict.
### js stream_names ?-subject *subject*?
Returns a list of all streams or the streams matching the filter.
### js add_consumer *stream* ?-option *value*?..
Creates or updates a pull or push consumer defined on `stream`. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/consumers#configuration) for explanation of these options.
| Option        | Type   | Default |
| ------------- |--------|---------|
| -name[^4] | string | |
| -durable_name | string | |
| -description | string | |
| -deliver_policy | one of: all, last, new, by_start_sequence<br/> by_start_time last_per_subject | all|
| -opt_start_seq | int | |
| -opt_start_time | string | |
| -ack_policy |one of: none, all, explicit, | explicit |
| -ack_wait | ms | |
| -max_deliver | int | |
| -filter_subject | string | |
| -replay_policy | one of: instant, original | instant|
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
| -metadata  | dict |         |

Returns a JetStream reply (same as `consumer_info`).
### js update_consumer *stream* ?-option *value*?..
Updates the consumer configuration with new options[^5]. Arguments and the return value are the same as in `add_consumer`.
### js add_pull_consumer *stream consumer ?args?*
A shortcut for `add_consumer` to create a durable pull consumer. Rest of `args` are the same as above.
### js add_push_consumer *stream consumer deliver_subject ?args?*
A shortcut for `add_consumer` to create a durable push consumer. Rest of `args` are the same as above.
### js add_consumer_from_json *stream consumer json_config*
Creates or updates a `consumer` defined on a `stream` with configuration specified as JSON.
### js delete_consumer *stream consumer*
Deletes the consumer.
### js consumer_info *stream consumer*
Returns consumer information as a dict.
### js consumer_names *stream*
Returns a list of all consumers defined on this stream.
### js ordered_consumer *stream ?args?*
Creates an [ordered](https://docs.nats.io/using-nats/developer/develop_jetstream/consumers#python) ephemeral push consumer on a `stream` and returns a new object [nats::ordered_consumer](#natsordered_consumer).
You can provide the following options that have the same meaning as in `add_consumer`:
- `-description string`
- `-headers_only bool` default false
- `-deliver_policy policy` default `all`
- `-idle_heartbeat ms` default 5000
- `-filter_subject subject`
- `-callback cmdPrefix` (mandatory)

Whenever a message arrives, the command prefix `cmdPrefix` will be invoked from the event loop. It must have the following signature:<br/>
**cmdPrefix** *message*<br/>
`message` is delivered as a dict to be used with the `nats::msg` ensemble. Since ordered consumers always have `-ack_policy none`, you don't need to `ack` the message.

### js stream_msg_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?
Returns a message from `stream` using the [STREAM.MSG.GET](https://docs.nats.io/reference/reference-protocols/nats_api_reference#fetching-from-a-stream-by-sequence) JS API. 

The following combinations of options are possible:
- sequence number
- last by subject
- next by subject (assumes sequence = 0)
- next by subject + sequence

This API guarantees read-after-write coherency but may be slower than "Direct Get" in a clustered setup.
### js stream_direct_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?
Returns a message from `stream` using the [DIRECT.GET](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-31.md) JS API. All options have the same meaning as for [stream_msg_get](#js-stream_msg_get-stream--last_by_subj-subj--next_by_subj-subj--seq-int). This method performs better than `stream_msg_get` if the stream has replicas or mirrors, but does not guarantee read-after-write coherency. The stream must be configured with `-allow_direct true` and/or `-mirror_direct true` respectively.

### js stream_msg_delete *stream* -seq *int* ?-no_erase *bool*?
Deletes a message from `stream` with the given `sequence` number. `-no_erase` is true by default. Set it to false if NATS should overwrite the message with random data, like `SecureDeleteMsg` in nats.go.
### js account_info
Returns a dict with information about the current account, e.g. used storage, number of streams, consumers, various limits etc.
### js api_prefix
Returns the API prefix used for requests to JetStream API. It is based on the `-domain` and `-api_prefix` options passed to [$connection jet_stream](CoreAPI.md#objectname-jet_stream-args). Default is "$JS.API".
### js destroy
TclOO destructor. Remember to call it before destroying the parent `nats::connection`.
## `nats::ordered_consumer`
Implements Ordered Consumer. Do not create it directly - instead, call the [ordered_consumer](JsAPI.md#js-ordered_consumer-stream-args) method of your `nats::jet_stream`.

The ordered consumer handles idle heartbeats and flow control, and guarantees to deliver messages in the order of `consumer_seq` with no gaps. If any problem happens e.g.:
- the push consumer is deleted or lost due to NATS restart
- the connection to NATS is lost and the client reconnects to another server in the cluster
- a message is lost
- no idle heartbeats arrive for longer than 3*idle_heartbeat ms

the consumer object will reset and recreate the push consumer requesting messages starting from the last known message using the `-opt_start_seq` option. Such events are logged as warnings to the connection's logger and also signalled using the "public" variable `last_error`.

Ordered consumers are explained in detail in [ADR-17](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-17.md).

### Error handling
`nats::ordered_consumer` reports asynchronous errors via `last_error` member variable, just like `nats::connection`:

| Async Errors | Reason | Retry |
| ------------- |--------|------|
| ErrConsumerNotActive | Consumer received no heartbeats|yes|
| ErrConsumerSequenceMismatch | Consumer received a message with unexpected `consumer_seq`|yes|
|ErrTimeout| Request to recreate the push consumer timed out|yes|
| ErrStreamNotFound | The stream was deleted |no|
| ErrConnectionClosed| Connection to NATS was closed or lost |no|

Most errors are considered transient and lead to the consumer reset, starting from the last known message. It happens automatically in background. However, it is not possible to recover from `ErrStreamNotFound` and `ErrConnectionClosed`, so in case of these errors the consumer will stop.
### consumer info
Returns the cached consumer info, same as `$js consumer_info`.
### consumer name
Returns the auto-generated consumer name, like `QWGBg8xp`. It is a shortcut for `dict get [$consumer info] name`. While consumer reset is in progress, `name` is an empty string.
### consumer destroy
Unsubscribes from messages and destroys the object. NATS server will delete the push consumer after InactiveThreshold=2s.

## Namespace Commands
### nats::metadata *message*
Returns a dict with metadata of the message that is extracted from the reply-to field. The dict has these fields:
- stream
- consumer
- num_delivered
- stream_seq
- consumer_seq
- timestamp (ms)
- num_pending

Note that when a message is received using `stream_msg_get`, this metadata is not available. Instead, you can get the stream sequence number and the timestamp using the `nats::msg` ensemble.
### nats::make_stream_source ?-option *value*?..
Returns a stream source configuration formatted as JSON to be used with `-mirror` and `-sources` arguments to [add_stream](#js-add_stream-stream--option-value). You can provide the following options:
- `-name originStreamName` (required)
- `-opt_start_seq int`
- `-opt_start_time string` formatted as ISO time
- `-filter_subject subject`
- `-subject_transforms` - list of subject transforms

If the source stream is in another JetStream domain or account, you need two more options:
- `-api APIPrefix` (required) - the subject prefix that imports the other account/domain
- `-deliver deliverySubject` (optional) - the delivery subject to use for the push consumer

Example of creating a stream sourcing messages from 2 other streams `SOURCE_STREAM_1` and `SOURCE_STREAM_1` that are located in the `hub` domain:
```Tcl
set source1 [nats::make_stream_source -name SOURCE_STREAM_1 -api "\$JS.hub.API"]
set source2 [nats::make_stream_source -name SOURCE_STREAM_2 -api "\$JS.hub.API"]
$js add_stream AGGREGATE_STREAM -sources [list $source1 $source2]
```
More details can be found in the official docs about [NATS replication](https://docs.nats.io/running-a-nats-service/nats_admin/jetstream_admin/replication).

### nats::make_subject_transform ?-option *value*?..
Returns a [subject transform](https://docs.nats.io/nats-concepts/subject_mapping) configuration formatted as JSON to be used with `-subject_transform` option in `add_stream` and `nats::make_stream_source`. You *must* provide the following options:
- `-src string`
- `-dest string`

Example:
```Tcl
set t1 [nats::make_subject_transform -src foo.* -dest "foo2.{{wildcard(1)}}"]
set t2 [nats::make_subject_transform -src bar.* -dest "bar2.{{wildcard(1)}}"]
set sourceConfig [nats::make_stream_source -name SOURCE_STREAM -subject_transforms [list $t1 $t2]]
$js add_stream AGGREGATE -sources [list $sourceConfig]
```
Note that for plural options like `-subject_transforms` and `-sources` you *need* to use `[list]` even if it has only one element.
See also [ADR-36](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-36.md).
### nats::make_republish ?-option *value*?..
Returns a [RePublish](https://docs.nats.io/nats-concepts/jetstream/streams#republish) configuration formatted as JSON to be used with `-republish` option in [add_stream](#js-add_stream-stream--option-value). You can provide the following options:
- `-src string` (required)
- `-dest string` (required)
- `-headers_only bool` default false

# Error handling in JetStream and Key/Value Store
In addition to all [core NATS errors](CoreAPI.md#error-handling), the `jet_stream` and `key_value` classes may throw these errors:

| Error     | JS Error Code | Reason   | 
| ------------- |--------|--------|
| ErrJetStreamNotEnabled | | JetStream is not enabled in the NATS server |
| ErrJetStreamNotEnabledForAccount | 503/10039 | JetStream is not enabled for this account |
| ErrWrongLastSequence | 400/10071 | <ul><li>JS publish with the header Nats-Expected-Last-Subject-Sequence failed</li><li>KV `update` failed due to revision mismatch</li></ul> |
| ErrStreamNotFound | 404/10059 | Stream does not exist |
| ErrConsumerNotFound | 404/10014| Consumer does not exist |
| ErrBucketNotFound | from ErrStreamNotFound | Bucket does not exist |
| ErrMsgNotFound | 404/10037 | Message not found in a stream |
| ErrKeyNotFound | from ErrMsgNotFound | Key not found in a bucket |
| ErrJSResponse | | Other JetStream error. `code` and `err_code` is passed in the Tcl error code and `description` is used for the error message. |
 
 See also "Error Response" in [ADR-1](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-1.md#error-response).

[^1]: You can specify the `-expires` option explicitly (ms), but this is an advanced use case and normally should not be needed.

[^2]: Throwing `ErrTimeout` might seem counter-intuitive and inconvenient, since users need to check for an empty list *and* a timeout. However, this is consistent with nats.go JS API v1.

[^3]: In principle, it is enough to pass only the new option-values, and the rest of configuration is left untouched. However, if your stream is configured with an option which is non-editable and not default (e.g. storage=memory), calling `update_stream` will result in a NATS error "stream configuration update can not change ... ". In such cases you need to get the current configuration first using [stream_info](#js-stream_info-stream), update the options and pass it to `update_stream`.

[^4]: `-name` and `-durable_name` are mutually exclusive. Depending on this choice, the library will invoke either `$JS.API.CONSUMER.CREATE` (default `InactiveThreshold` is 5s) or `$JS.API.CONSUMER.DURABLE.CREATE` (default `InactiveThreshold` is unlimited). `-name` is supported only by NATS>=2.9. `CONSUMER.DURABLE.CREATE` is considered [legacy API](https://github.com/nats-io/nats.go/blob/main/js.go).

[^5]: Prior to NATS 2.10, the same request could create a new consumer or update its configuration. This behaviour leads to potential race conditions and has been [fixed](https://github.com/nats-io/nats.go/pull/1379) in NATS 2.10 by adding a new field "action" to the JSON request. The Tcl library detects the server version and includes this field automatically.
