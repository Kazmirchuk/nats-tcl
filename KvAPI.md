# Key-Value API

NATS server implements a Key-Value storage on top of JetStream streams. A specific KV bucket is accessed using the `nats::key_value` TclOO object. Do not create it directly - instead, call the [bind_kv_bucket](JsAPI.md#js-bind_kv_bucket-bucket) or [create_kv_bucket](JsAPI.md#js-create_kv_bucket-bucket--option-value) method of your `nats::jet_stream`. KV management functions to create & delete buckets are available in `nats::jet_stream`, but documented here for cohesion.

Please refer to the [official documentation](https://docs.nats.io/nats-concepts/jetstream/key-value-store) for the description of general concepts and to [ADR-8](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md) for implementation details.

# Synopsis
## Class `nats::jet_stream`
[*js* bind_kv_bucket *bucket*](#js-bind_kv_bucket-bucket)<br/>
[*js* create_kv_bucket *bucket* ?-option *value*?..](#js-create_kv_bucket-bucket--option-value)<br/>
[*js* create_kv_aggregate *bucket writable origins* ?-option *value*?..](#js-create_kv_aggregate-bucket-writable-origins--option-value)<br/>
[*js* create_kv_mirror *name origin* ?-option *value*?..](#js-create_kv_mirror-name-origin--option-value)<br/>
[*js* delete_kv_bucket *bucket*](#js-delete_kv_bucket-bucket)<br/>
[*js* kv_buckets *bucket*](#js-kv_buckets)<br/>
[*js* empty_kv_bucket *bucket*](#js-empty_kv_bucket-bucket)<br/>

## Class `nats::key_value`
[*kv* get *key* ?-revision *int*?](#kv-get-key--revision-int)<br/>
[*kv* get_value *key* ?-revision *int*?](#kv-get_value-key--revision-int)<br/>
[*kv* put *key value*](#kv-put-key-value)<br/>
[*kv* create *key value*](#kv-create-key-value)<br/>
[*kv* update *key value revision*](#kv-update-key-value-revision)<br/>
[*kv* delete *key ?revision?*](#kv-delete-key-revision)<br/>
[*kv* purge *key*](#kv-purge-key)<br/>
[*kv* revert *key revision*](#kv-revert-key-revision)<br/>
[*kv* status](#kv-status)<br/>
[*kv* history *key*](#kv-history-key)<br/>
[*kv* keys](#kv-keys)<br/>
[*kv* watch *key* ?-option *value*...?](#kv-watch-key--option-value)<br/>
[*kv* destroy](#kv-destroy)<br/>
## Class `nats::kv_watcher`
[*watcher* consumer](#watcher-consumer)<br/>
[*watcher* destroy](#watcher-destroy)<br/>
## Namespace Commands
[nats::make_kv_origin ?-option *value*?..](#natsmake_kv_origin--option-value)

# Description
The `key_value` object provides access to a specific KV bucket. A bucket is merely a JS `stream` that has some default options, and its name always starts with "KV_". And a key is, in fact, a (portion of) a subject that this stream listens to. Therefore, all KV operations are implemented in terms of standard JetStream operations such as  `publish`, `stream_msg_get` etc. They all block in a (coroutine-aware) `vwait` with the same timeout as in the parent `jet_stream`.

[NATS by Example](https://natsbyexample.com/examples/kv/intro/go) provides a good overview of how KV buckets work on top of streams.

The [naming rules](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md) of NATS subjects apply to keys as well, and keys can't start with "_kv". Keys *may* contain dots.

You can access a KV bucket across JetStream domains and create KV mirrors as well. These concepts are explained in the chapters about [NATS Leaf Nodes](https://docs.nats.io/running-a-nats-service/configuration/leafnodes/jetstream_leafnodes) and [Stream Replication](https://docs.nats.io/running-a-nats-service/nats_admin/jetstream_admin/replication).

## Entry
A KV entry is a dict with the following fields:
- `bucket` - a bucket name
- `key` - a key
- `value` - a value or an empty string if it is a DEL or PURGE entry
- `revision` - revision number, starting with 1 (`seq` of the message in the underlying stream)
- `created` - creation timestamp as milliseconds since the epoch
- `delta` - distance from the latest revision, starting with 0. It is available only when using [watch](#kv-watch-key-args).
- `operation` - one of `PUT`, `DEL` or `PURGE`

## Bucket status
A bucket status is a dict with the following fields:
- `bucket` - name
- `bytes` - size of the bucket
- `history` - number of history entries per key
- `ttl` - for how long (ms) the bucket keeps values or 0 for unlimited time
- `values` - total number of entries in the bucket including historical ones
- `is_compressed` - if data is compressed on disk
- `mirror_name` - name of the origin bucket (optional)
- `mirror_domain` - JetStream domain of the origin bucket (optional)
- `stream_config` - configuration of the backing stream
- `stream_state` - state of the backing stream

# Commands
## `nats::jet_stream`
### js bind_kv_bucket *bucket*
This 'factory' method creates `nats::key_value` to access the `bucket`.
### js create_kv_bucket *bucket* ?-option *value*?..
Creates a Key-Value `bucket` with configuration specified as option-value pairs.
| Option        | Type   | Default |
| ------------- |--------|---------|
| -description | string | |
| -max_value_size | int | |
| -history | int | 1 |
| -ttl | ms | |
| -max_bucket_size | int | |
| -storage | one of: memory, file | file |
| -num_replicas | int | 1 |
| -compression | one of:  none, s2 |  |
| -mirror_name[^1] | string | |
| -mirror_domain | string| |
| -metadata  | dict |  |

Returns `nats::key_value` object.
### js create_kv_aggregate *bucket writable origins* ?-option *value*?..
Creates a KV aggregate that collects data from one or more origin buckets (possibly across JetStream domains). The data can be filtered based on keys. You *must* provide the following arguments:
- `bucket string` - name of the aggregate
- `writable bool` - if it is writable or read-only. A read-only aggregate has no ingest subject.
- `origins list` - list of origins created with [make_kv_origin](#natsmake_kv_origin--option-value). Note that you need to use `[list]` even if you have only one origin.

You can use all other options for a normal bucket as well, except `-mirror_name` and `-mirror_domain`.

Returns `nats::key_value` object.
### js create_kv_mirror *name origin* ?-option *value*?..
Creates a read-only KV mirror of another bucket. Unlike a normal bucket or an aggregate, you can't bind to a mirror. Their main purpose is to scale `get` operations by replying to `DIRECT.GET` requests. You *must* provide the following arguments:
- `name string` - name of the mirror[^2]
- `origin dict` - a *single* origin created with [make_kv_origin](#natsmake_kv_origin--option-value). 

You can use all other options for a normal bucket as well, except `-mirror_name` and `-mirror_domain`.

In order to delete a KV mirror, you need to use [delete_stream](JsAPI.md#js-delete_stream-stream) instead of `delete_kv_bucket`.
### js delete_kv_bucket *bucket*
Deletes the bucket.
### js kv_buckets
Returns a list of all Key-Value buckets.
### js empty_kv_bucket *bucket*
Deletes all entries and history from the bucket without destroying the bucket itself. Note that it does **not** reset the bucket's revision counter.
## `nats::key_value`
### kv get *key* ?-revision *int*?
Returns the latest entry for the `key` or the entry with the specified `revision`. Throws `ErrKeyNotFound` if the key doesn't exist or was deleted. `DIRECT.GET` request is used under the hood, if available.

### kv get_value *key* ?-revision *int*?
A shorthand for `kv get` that returns only the value from the entry.

### kv put *key value*
Puts the new `value` for the `key`. Returns the new revision number.

### kv create *key value*
Creates a new key-value pair only if the key doesn't exist. Otherwise it throws `ErrWrongLastSequence`. Returns the new revision number.

### kv update *key value revision*
Updates the `key` with the new `value` only if the latest revision matches. In case of mismatch it throws `ErrWrongLastSequence`. Returns the new revision number.

### kv delete *key* ?*revision*?
Deletes the `key`, while preserving the history. If specified, the `revision` must match the latest revision number.

### kv purge *key*
Deletes the `key`, removing all previous revisions.

### kv revert *key revision*
Reverts a value to a previous `revision` using `kv put`. Returns the new revision number.

### kv status
Returns the status of the KV bucket as described above.

### kv history *key*
Returns all historical entries for the `key`. A NATS wildcard pattern can be used as well, e.g. ">" to get all entries in the bucket.

### kv keys
Returns all keys in the bucket. Throws `ErrKeyNotFound` if the bucket is empty.

### kv watch *key* ?-option *value*...?
Starts watching the `key` (that can be a NATS wildcard) and returns a new object [nats::kv_watcher](#natskv_watcher). To watch the whole bucket, use:
```Tcl
kv watch >
```

[Ordered consumer](JsAPI.md#js-ordered_consumer-stream-args) is used under the hood.

KV entries can be delivered to a callback or to an array (or both):
- `-callback cmdPrefix` - deliver **entries** to this callback.
- `-values_array varName` - deliver **values** to this array. `varName` must be a namespace or global array variable. Usual namespace resolution rules apply, like for `trace`.

At least one of `-callback` or `-values_array` must be provided.

You can refine what is delivered using these options:
- `-include_history bool` - deliver historical entries as well (default false).
- `-meta_only bool` - deliver entries without values (default false). E.g. to watch for available keys.
- `-ignore_deletes bool` - do not deliver DELETE and PURGE entries (default false).
- `-updates_only bool` - deliver only updates (default false).

The underlying `nats::ordered_consumer` can be configured with these options:
- `-idle_heartbeat ms`

If you opt for the **callback** option, it will be invoked from the event loop with the following signature:

**cmdPrefix** *entry*

The callback is invoked in the following order, once for each entry:
1. Historical entries for all matching keys (only with `-include_history true`).
2. Current entries for all matching keys.
3. Then it is invoked once again with an empty `entry` to signal "end of current data".
4. When a key is updated, it is invoked with a new entry.

With `-updates_only true`, the watcher starts with step #3. [^3]

If you opt for the **array** option:
1. Current keys and values from the bucket are inserted into this array.
2. Afterwards, updates in the bucket are delivered as they happen.
3. If a key is deleted or purged from the bucket, and `-ignore_deletes false`, the corresponding key will be removed from the array as well.

Thus, you effectively have a local cache of a whole KV bucket or its portion that is always up-to-date. Depending on your use case, this might be more efficient than querying the bucket with `$kv get`.

The array can't be a local variable.

### kv destroy
TclOO destructor. Remember to call it before destroying the parent `nats::jet_stream`.

## `nats::kv_watcher`
### watcher consumer
Returns the internal `nats::ordered_consumer` object (for advanced use cases). 
### watcher destroy
Stops watching and destroys the object.

## Namespace Commands
### nats::make_kv_origin ?-option *value*?..
Returns a KV origin configuration to be used with [create_kv_aggregate](#js-create_kv_aggregate-bucket-writable-origins--option-value) and 
[create_kv_mirror](#js-create_kv_mirror-name-origin--option-value). You can provide the following options:
- `-bucket str` (required) - the origin bucket
- `-stream str` - in case the origin is not an actual bucket, but a mirror, you need to pass the stream/mirror name as well [^4]
- `-keys list` - optional filter

If the origin bucket is in another JetStream domain or account, you need two more options:
- `-api APIPrefix` (required) - the subject prefix that imports the other account/domain
- `-deliver deliverySubject` (optional) - the delivery subject to use for the push consumer

Example of creating a writable KV aggregate sourcing a subset `new.>` of keys/values from another bucket `HUB_BUCKET` located in the `hub` domain:
```Tcl
set origin [nats::make_kv_origin -bucket HUB_BUCKET -keys new.> -api "\$JS.hub.API"]
set kv [$js create_kv_aggregate LEAF_KV true [list $origin] -description "writable filtered KV aggregate"]
```
See also [nats::make_stream_source](JsApi.md#natsmake_stream_source--option-value).
# Error handling
KV-specific errors are listed in JsAPI.md

[^1]: `-mirror_name` and `-mirror_domain` are deprecated per ADR-8 API v1.1 in favour of KV aggregates and mirrors based on subject transforms.

[^2]: while for normal KV buckets and aggregates the name of the underlying stream always starts with "KV_", this is not the case for KV mirrors.

[^3]: nats.go deviates from ADR-8 and does *not* send the End Of Initial Data marker.

[^4]: I think, `type KVAggregateOrigin` in ADR-8 is a bit confusing in specifying `Stream` as required and `Bucket` as optional. So, users always need to pass the underlying stream name starting with "KV_", which is not very convenient. So, in the Tcl client it is other way round: `Bucket` is required and `Stream` is optional.
