# JetStream API

JetStream functionality of NATS can be accessed by creating the `nats::jet_stream` TclOO object. Do not create it directly - instead, call the [jet_stream](CoreAPI.md#objectname-jet_stream--timeout-ms--domain-domain) method of your `nats::connection`. You can have multiple JS objects created from the same connection, each having its own timeout and domain.

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
[*js* add_stream_from_json *json_config*](#js-add_stream_from_json-json_config)<br/>
[*js* delete_stream *stream*](#js-delete_stream-stream)<br/>
[*js* purge_stream *stream* ?-filter *subject*? ?-keep *int*? ?-seq *int*?](#js-purge_stream-stream--filter-subject--keep-int--seq-int)<br/>
[*js* stream_info *stream*](#js-stream_info-stream)<br/>
[*js* stream_names ?-subject *subject*?](#js-stream_names--subject-subject)<br/>

[*js* add_consumer *stream* ?-option *value*?..](#js-add_consumer-stream--option-value)<br/>
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

[*js* bind_kv_bucket *bucket*](#js-bind_kv_bucket-bucket)<br/>
[*js* create_kv_bucket *bucket* ?-option *value*?..](#js-create_kv_bucket-bucket--option-value)<br/>
[*js* delete_kv_bucket *bucket*](#js-delete_kv_bucket-bucket)<br/>
[*js* kv_buckets *bucket*](#js-kv_buckets)<br/>
[*js* empty_kv_bucket *bucket*](#js-empty_kv_bucket-bucket)<br/>

[*js* account_info](#js-account_info)<br/>

[*js* destroy](#js-destroy)<br/>

## Class `nats::ordered_consumer`
[*consumer* info](#consumer-info)<br/>
[*consumer* name](#consumer-name)<br/>
[*consumer* destroy](#consumer-destroy)<br/>

## Namespace Commands
[nats::metadata *message*](#natsmetadata-message)<br/>
[nats::make_stream_source ?-option *value*?..](#natsmake_stream_source--option-value)

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

The implementation can tolerate minor changes in JetStream API. E.g. a publish acknowledgment is returned just as a dict parsed from JSON. So, if in future the JSON schema gets a new field, it will be automatically available in this dict.

If you need other JetStream functions, e.g. Object Store, you can easily implement them yourself using core NATS requests. No need to interact directly with the TCP socket. Of course, PRs are always welcome.

## Notable differences from official NATS clients
Note that API of official NATS clients (`JetStreamContext`) is designed in a way that allows to create a consumer implicitly with a subscription (e.g. `JetStreamContext.pull_subscribe` in nats.py). I find such design somewhat confusing, so the Tcl API clearly distinguishes between creating a consumer and a subscription.

Also, official NATS clients often provide an auto-acknowledgment option (and sometimes even default to it!) - I find it potentially harmful, so it's missing from this client. Always remember to acknoledge JetStream messages according to your policy.

The Tcl client does not provide a dedicated method to subscribe to push consumers. The core NATS subscription is perfectly adequate for the task. If your push consumer is configured with idle heartbeats, you will need to filter them out by checking `nats::msg idle_heartbeat`. You can find an example of such subscription in [js_msg.tcl](examples/js_msg.tcl).

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

Pulled messages are always returned as Tcl dicts irrespectively of the `-dictmsg` option. They contain metadata that can be accessed using [nats::metadata](CoreAPI.md#natsmetadata-message).

If `-timeout` is omitted, the client sends a `no_wait` request, asking NATS to deliver only currently pending messages. If there are no pending messages, the method returns an empty list.

If `-timeout` is given, it defines both the client-side and server-side timeouts for the pull request:
- the client-side timeout is the timeout for the underlying `request`
- the server-side timeout is 10ms shorter than `timeout`, and it is sent in the `expires` JSON field. This behaviour is consistent with `nats.go`.

*Note:* you can specify the `-expires` option explicitly (ms), but this is an advanced use case and normally should not be needed.

If a callback is not given, the request is synchronous and blocks in a (coroutine-aware) `vwait` until all expected messages are received or the pull request expires. If the client-side timeout fires before the server-side timeout, and no messages have been received, the method raises `ErrTimeout`. In all other cases the method returns a list with as many messages as currently avaiable, but not more than `batch_size`.

If a callback is given, the call returns immediately. Return value is a unique ID that can be used to cancel the pull request. When a message is pulled or a timeout fires, the callback will be invoked from the event loop. It must have the following signature:

**cmdPrefix** *timedOut message*

If less than `batch_size` messages are pulled before the pull request times out, the callback is invoked one last time with `timedOut=1`.

The client handles status messages 404, 408 and 409 transparently. You can see them in the debug log, if needed. Also, they are passed to the callback together with `timedOut=1`.

Depending on the consumer's [AckPolicy](https://docs.nats.io/nats-concepts/jetstream/consumers#ackpolicy), you might need to acknowledge the received messages with one of the methods below. [This](https://docs.nats.io/using-nats/developer/develop_jetstream/consumers#delivery-reliability) official doc explains all different kinds of ACKs.

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
Creates or updates a `stream` with configuration specified as option-value pairs. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/streams#configuration) for explanation of these options.
| Option        | Type   | Default |
| ------------- |--------|---------|
| -description  | string |         |
| -subjects     | list of strings  | (required)|
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
| -mirror | JSON | |
| -sources | list of JSON | |

For `-mirror` and `-sources` options, use the [nats::make_stream_source](#natsmake_stream_source--option-value) command to create a stream source configuration. <br/>
Returns a JetStream response as a dict.
### js add_stream_from_json *json_config*
Creates or updates a stream with configuration specified as JSON. The stream name is taken from the JSON.
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
| -name | string | |
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

Note that starting from NATS 2.9.0, there is a new option `-name` that is not the same as `-durable_name`. If you provide `-durable_name`, the consumer's default `InactiveThreshold` is unlimited. But if you provide `-name`, the default `InactiveThreshold` is only 5s.<br/>
Returns a JetStream response as a dict.
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
- `-description`
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
### js bind_kv_bucket *bucket*
This 'factory' method creates [KeyValueObject](KvAPI.md) to access the `bucket`.
### js create_kv_bucket *bucket* ?-option *value*?..
Creates or updates a Key-Value `bucket` with configuration specified as option-value pairs. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/key-value-store) and [ADR-8](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md) for explanation of these options.
| Option        | Type   | Default |
| ------------- |--------|---------|
| -description | string | |
| -max_value_size | int | |
| -history | int | 1 |
| -ttl | ms | |
| -max_bucket_size | int | |
| -storage | one of: memory, file | file |
| -num_replicas | int | 1 |
| -mirror_name | string | |
| -mirror_domain | string| |

To create a mirror of a different bucket, use `-mirror_name`. If this bucket is in another domain, use `-mirror_domain` as well.

Returns [KeyValueObject](KvAPI.md).
### js delete_kv_bucket *bucket*
Deletes the bucket.
### js kv_buckets
Returns a list of all Key-Value buckets.
### js empty_kv_bucket *bucket*
Deletes all entries and history from the bucket without destroying the bucket itself. Note that it does **not** reset the bucket's revision counter.
### js account_info
Returns a dict with information about the current account, e.g. used storage, number of streams, consumers, various limits etc.
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

If the source stream is in another JetStream domain, you will need two more options:
- `-api domain` (required)
- `-deliver deliverySubject`

Example of creating a stream sourcing messages from 2 other streams SOURCE_STREAM_1 and SOURCE_STREAM_1 that are located in the "hub" domain:
```Tcl
set source1 [nats::make_stream_source -name SOURCE_STREAM_1 -api hub]
set source2 [nats::make_stream_source -name SOURCE_STREAM_2 -api hub]
$js add_stream AGGREGATE_STREAM -sources [list $source1 $source2]
```
More details can be found in the official docs about [NATS replication](https://docs.nats.io/running-a-nats-service/nats_admin/jetstream_admin/replication).

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
