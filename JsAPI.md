# JetStream API

JetStream functionality of NATS can be accessed by creating the `nats::jet_stream` TclOO object. Do not create it directly - instead, call the [jet_stream](CoreAPI.md#objectname-jet_stream--timeout-ms--domain-domain) method of your `nats::connection`. You can have multiple JS objects created from the same connection, each having its own timeout and domain.

## Synopsis

[*js* publish *subject message ?args?*](#js-publish-subject-message-args)<br/>
[*js* publish_msg *message ?args?*](#js-publish_msg-message-args)<br/>
[*js* consume *stream consumer ?args?*](#js-consume-stream-consumer-args)<br/>
[*js* ack *message*](#js-ack-message)<br/>
[*js* ack_sync *message*](#js-ack_sync-message)<br/>
[*js* nak *message* ?-delay *ms*?](#js-nak-message--delay-ms)<br/>
[*js* in_progress *message*](#js-in_progress-message)<br/>
[*js* term *message*](#js-term-message)<br/>
[*js* metadata *message*](#js-metadata-message)<br/>
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

[*js* stream_msg_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?](#js-stream_msg_get-stream--last_by_subj-subj--next_by_subj-subj--seq-int)<br/>
[*js* stream_msg_delete *stream* -seq *sequence* ?-no_erase *no_erase*?](#js-stream_msg_delete-stream--seq-sequence--no_erase-no_erase)<br/>

[*js* key_value ?-timeout *ms*? ?-check_bucket *enabled*? ?-read_only *enabled*?](#js-key_value--timeout-ms--check_bucket-enabled--read_only-enabled) <br/>

[*js* destroy](#js-destroy)<br/>

## Description
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

The Tcl client does not provide a dedicated method to subscribe to push consumers. The core NATS subscription is perfectly adequate for the task. If your push consumer is configured with idle heartbeats, you will need to filter them out based on the status header = 100. You can find an example of such subscription in [js_msg.tcl](examples/js_msg.tcl).

## JetStream wire format
The JetStream wire format uses nanoseconds for timestamps and durations in all requests and replies. To be consistent with the rest of the Tcl API, the client converts them to milliseconds before returning to a user. And vice versa: all function arguments are accepted as ms and converted to ns before sending.

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

## Commands
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
### js consume *stream consumer ?args?*
Consumes a number of messages from a [pull consumer](https://docs.nats.io/jetstream/concepts/consumers) defined on a [stream](https://docs.nats.io/jetstream/concepts/streams). This is the analogue of `PullSubscribe` + `fetch` in official NATS clients.

You can provide the following options:
- `-batch_size int` - number of messages to consume. Default batch is 1.
- `-timeout ms` - pull request timeout - see below.
- `-callback cmdPrefix` - do not block and deliver messages to this callback.

The underlying JetStream API is rather intricate, so I recommend reading [ARD-13](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-13.md) for better understanding.

Pulled messages are always returned as Tcl dicts irrespectively of the `-dictmsg` option.

If `-timeout` is omitted, the client sends a `no_wait` request, asking NATS to deliver only currently pending messages. If there are no pending messages, the method returns an empty list.

If `-timeout` is given, it defines both the client-side and server-side timeouts for the pull request:
- the client-side timeout is the timeout for the underlying `request`
- the server-side timeout is 10ms shorter than `timeout`, and it is sent in the `expires` JSON field. This behaviour is consistent with `nats.go`.

*Note:* you can specify the `-expires` option explicitly (ms), but this is an advanced use case and normally should not be needed.

If a callback is not given, the request is synchronous and blocks in a (coroutine-aware) `vwait` until all expected messages are received or the pull request expires. If the client-side timeout fires before the server-side timeout, and no messages have been received, the method raises `ErrTimeout`. In all other cases the method returns a list with as many messages as currently avaiable, but not more than `batch_size`.

If a callback is given, the call returns immediately. Return value is a unique ID that can be used to cancel the pull request. When a message is pulled or a timeout fires, the callback will be invoked from the event loop. It must have the following signature:

**cmdPrefix** *timedOut message*

If less than `batch_size` messages are pulled before the pull request times out, the callback is invoked one last time with `timedOut=1`.

The client handles status messages 404, 408 and 409 transparently. You can see them in the debug log, if needed. Also, they are passed to the callback, in case you need to distinguish between a client-side and server-side timeout.

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
### js cancel_pull_request *reqID*
Cancels the asynchronous pull request with the given `reqID`.
### js add_stream *stream* ?-option *value*?..
Create or update a `stream` with configuration specified as option-value pairs. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/streams#configuration) for explanation of these options.
| Option        | Type   | Default | Info |
| ------------- |--------|---------|------|
| -description  | string |         |      |
| -subjects     | list of strings  | (required)| Is not required if `-mirror` or `-subject` options are present.   |
| -retention    | one of: limits, interest,<br/> workqueue |limits |    |
| -max_consumers  | int |         |   |
| -max_msgs  | int |         |    |
| -max_bytes  | int |         |   |
| -discard  | one of: new, old | old |    |
| -max_age  | ms |         |    |
| -max_msgs_per_subject  | int |         |    |
| -max_msg_size  | int |         |    |
| -storage  | one of: memory, file | file |   |
| -num_replicas  | int |         |    |
| -no_ack  | boolean |         |    |
| -duplicate_window  | ms |         |   |
| -sealed  | boolean |         |    |
| -deny_delete  | boolean |         |   |
| -deny_purge  | boolean |         |    |
| -allow_rollup_hdrs  | boolean |         |   |
| -allow_direct  | boolean |         |    |
| -mirror_direct  | boolean |         |   |
| -mirror  | dict |         | Should have `name` key (which JetStream to copy from) and can also have `external` key as another dict with `api` key (in order to copy from another domain). For example: `{name js_to_mirror external {api $JS.other_domain.API}}` (`\$JS` is special api prefix).   |
| -sources  | list of dicts |         | Dicts should be the same as with `-mirror` option.   |


Returns a JetStream response as a dict.
### js add_stream_from_json *json_config*
Create or update a stream with configuration specified as JSON. The stream name is taken from the JSON.
### js delete_stream *stream*
Deletes the stream.
### js purge_stream *stream* ?-filter *subject*? ?-keep *int*? ?-seq *int*?
Purges the stream, deleting all messages or a subset based on filtering criteria. See also [ADR-10](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-10.md).
### js stream_info *stream*
Returns stream information as a dict.
### js stream_names ?-subject *subject*?
Returns a list of all streams or the streams matching the filter.
### js add_consumer *stream* ?-option *value*?..
Create or update a pull or push consumer defined on `stream`. See the [official docs](https://docs.nats.io/nats-concepts/jetstream/consumers#configuration) for explanation of these options.
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

Note that starting from NATS 2.9.0, there is a new option `-name` that is not fully equivalent to `-durable_name`. If you provide `-durable_name`, the consumer's default `InactiveThreshold` is unlimited. But if you provide `-name`, the default `InactiveThreshold` is only 5s.<br/>
Returns a JetStream response as a dict.
### js add_pull_consumer *stream consumer ?args?*
A shortcut for `add_consumer` to create a durable pull consumer. Rest of `args` are the same as above.
### js add_push_consumer *stream consumer deliver_subject ?args?*
A shortcut for `add_consumer` to create a durable push consumer. Rest of `args` are the same as above.
### js add_consumer_from_json *stream consumer json_config*
Create or update a `consumer` defined on a `stream` with configuration specified as JSON.
### js delete_consumer *stream consumer*
Deletes the consumer.
### js consumer_info *stream consumer*
Returns consumer information as a dict.
### js consumer_names *stream*
Returns a list of all consumers defined on this stream.
### js stream_msg_get *stream* ?-last_by_subj *subj*? ?-next_by_subj *subj*? ?-seq *int*?
'Direct Get' a message from stream `stream` by given `subject` or `sequence`. See also [ADR-31](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-31.md).
### js stream_msg_delete *stream* -seq *int* ?-no_erase *no_erase*?
Delete message from `stream` with the given `sequence` number.
### *js* key_value ?-timeout *ms*? ?-check_bucket *enabled*? ?-read_only *enabled*?
This 'factory' method creates [keyValueObject](KvAPI.md) to work with Key-Value stores. `-timeout` (default value is get from JS object) is applied to `history` and `keys` requests to Key-Value NATS API. For the rest of requests `timeout` from JS and basic nats connection is used. `-check_bucket` (default true) takes care of checking if bucket exists or is mirror of another bucket, before sending requests to one. If it is disabled and given bucket does not exists than timeout will be fired (or `NoResponders`) instead of throwing a `BucketNotFound` error (check [KvAPI](KvAPI.md#implementation-information) for more information). `-timeout` and `-check_bucket` can be overridden for some functions. `-read_only` (default false) can disable ability to modify buckets and keys.
### js destroy
TclOO destructor. Remember to call it before destroying the parent `nats::connection`.

## Error handling
In addition to all core NATS errors, the `jet_stream` methods may throw `ErrJSResponse` if JetStream API has returned an error. The Tcl error code will contain also JetStream `code` and `err_code`. JetStream `description` will be used for the error message. See also [ADR-1](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-1.md#error-response).

Note that if JetStream is not enabled in the NATS server, all requests to JetStream API will throw `ErrNoResponders`. This is different from official NATS clients that replace it with `ErrJetStreamNotEnabled`. I don't see much value in doing this in the Tcl client.
