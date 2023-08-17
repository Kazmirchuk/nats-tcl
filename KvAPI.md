# Key-Value API

Key-Value functionality of NATS can be accessed by creating the `nats::key_value` TclOO object (using jet_stream object). Do not create it directly - instead, call the [bind_kv_bucket](JsAPI.md#js-bind_kv_bucket-bucket) or [create_kv_bucket](JsAPI.md#js-create_kv_bucket-bucket--history-history--storage-storage--ttl-ttl--max_value_size-max_value_size--max_bucket_size-max_bucket_size--mirror_name-mirror_name--mirror_domain-mirror_domain) method of your `nats::jet_stream`. You can have multiple KV objects created from the same JetStream, each having its own settings.

## Synopsis

[*kv* get *key* ?-revision *revision*?](#kv-get-key--revision-revision)<br/>
[*kv* put *key value*](#kv-put-key-value)<br/>
[*kv* create *key value*](#kv-create-key-value)<br/>
[*kv* update *key value revision*](#kv-update-key-value-revision)<br/>
[*kv* delete *key* ?-revision *revision*?](#kv-delete-key--revision-revision)<br/>
[*kv* purge *key*](#kv-purge-key)<br/>
[*kv* revert *key revision*](#kv-revert-key-revision)<br/>
[*kv* status](#kv-status)<br/>
[*kv* history ?*key*? ?-timeout *timeout*?](#kv-history-key--timeout-timeout)<br/>
[*kv* keys ?-timeout *timeout*?](#kv-keys-bucket--timeout-timeout)<br/>
[*kv* watch ?*key*? ?-callback *callback*? ?-include_history *include_history*? ?-updates_only *updates_only*? ?-meta_only *meta_only*? ?-ignore_deletes *ignore_deletes*? ?-idle_heartbeat *idle_heartbeat*?](#kv-watch-key--callback-callback--include_history-include_history--updates_only-updates_only--meta_only-meta_only--ignore_deletes-ignore_deletes--idle_heartbeat-idle_heartbeat)<br/>
[*kv* unwatch *watchId*](#kv-unwatch-watchid)<br/>
[*kv* destroy](#kv-destroy)<br/>

## Description (from [official documentation](https://docs.nats.io/nats-concepts/jetstream/key-value-store))

JetSteam, the persistence layer of NATS, doesn't just allow for higher qualities of service and features associated with 'streaming', but it also enables some functionalities not found in messaging systems.
One such feature is the Key/Value store functionality, which allows client applications to create `buckets` and use them as immediately consistent, persistent associative arrays.
You can use KV buckets to perform the typical operations you would expect from an immediately consistent key/value store:
- put: associate a value with a key
- get: retrieve the value associated with a key
- delete: clear any value associated with a key
- purge: clear all the values associated with all keys
- create: associate the value with a key only if there is currently no value associated with that key (i.e. compare to null and set)
- update: compare and set (aka compare and swap) the value for a key
- keys: get a copy of all the keys (with a value or operation associated to it)

You can set limits for your buckets, such as:
- the maximum size of the bucket
- the maximum size for any single value
- a TTL: how long the store will keep values for

Finally, you can even do things that typically can not be done with a Key/Value Store:
- watch: watch for changes happening for a key, which is similar to subscribing (in the publish/subscribe sense) to the key: the watcher receives updates due to put or delete operations on the key pushed to it in real-time as they happen
- watch all: watch for all the changes happening on all the keys in the bucket
- history: retrieve a history of the values (and delete operations) associated with each key over time (by default the history of buckets is set to 1, meaning that only the latest value/operation is stored)

## Implementation information

Implementation is based mainly on official [guidelines](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md) and `nats-cli` client. It supports all main methods and work comparably to other clients. It is worth noticing that:
- `-utf8_convert` option on core nats client is also applicable to all KV operations, so when it is `true` than all incoming/outgoing messages are automatically converted. 
- most of methods checks if `bucket` and `key` names are valid. `bucket` could only contain letters, numbers, `_` and `-`. `key` could also contain `/`, `=` and `.` (but it cannot start or end with `.` and cannot start with `_kv`).
- in addition to all core NATS and JetStream errors, the `key_value` methods may throw `KeyNotFound`, `BucketNotFound`, `WrongLastSequence` and `KvReadOnly` errors based on situation,
- `cross-domain` requests are supported (`domain` is copied from `jet_stream` object) so acting on kv from another domain is possible (see examples),
- `mirroring` (as well as `cross-domain` mirroring) is supported.

## Entry

Methods returning messages kept under the `key` are returning `entry`, which is a dict consisting of:
- `value` - value of key,
- `bucket` - bucket on which this `entry` exists,
- `key` - key on which this `entry` exists,
- `operation` - `PUT`, `DEL` or `PURGE`,
- `revision` - unique number in given `bucket` (`seq` of message in stream),
- `created` - time when this `entry` has been uploaded (milliseconds).

## Commands

### kv get *key* ?-revision *revision*?

Gets an entry for a `key` from the store `bucket` (see [Entry](#entry)). Optionally it can retrieve specified revision of given key. `KeyNotFound` can be raised if `key` does not exists or revision does not belong to `key`.

### kv get_value *key* ?-revision *revision*?

Gets value for a `key` from the store `bucket` (similarly to `dict get [$kv get $key] value`). Optionally it can retrieve specified revision of given key. `KeyNotFound` can be raised if `key` does not exists, revision does not belong to `key` or when `key` has been deleted or purged.

### kv put *key value*

Puts a `value` into a `key`. Returns newly created `revision`.

### kv create *key value*

Puts a `value` into a `key` only if the `key` does not exists or it's last operation was delete/purge. If `key` already exists than `WrongLastSequence` will be thrown. Returns newly created `revision`.

### kv update *key value revision*

Updates a `key` with a new `value` only if the previous `entry` matches the given `revision`. If `revision` does not match than `WrongLastSequence` will be thrown. Useful when updates on key are based on previous values - using `update` (instead of `put`) will make sure no other values were set to key between read and write. Returns newly created `revision`.

### kv delete *key* ?-revision *revision*?

Deletes a `key` from bucket (preserves history). Optionally `revision` can be given that should match last `key` value in bucket - otherwise delete won't happen (to make sure no values has been set meantime).

### kv purge *key*

Deletes a `key` from the bucket, clearing history before creating a delete marker.

### kv revert *key revision*

Reverts a value to a previous `revision` using put. It simply gets `revision` of `key` and puts it again. Returns newly created `revision`.

### kv status

View the status and information of a KV store.
Returns dict containing `bucket`, `stream`, `storage`, `history`, `ttl`, `max_value_size`, `max_bucket_size` (and optionally `mirror_name` and `mirror_domain`) as well as other information: `created` (in milliseconds), `values_stored`, `bytes_stored`, `backing_store` and `store_config`, `store_state` - last two of them contains full configuration of underlying JetStream.

### kv history ?*key*? ?-timeout *timeout*?

Gets the full history for a `key` or entire bucket. In order to do that, under the hood ephemeral consumer is created that gets necessary messages and returns when all required entries has been gathered. 
`-timeout` can override default configuration.

### kv keys ?-timeout *timeout*?

List available keys in a bucket. Similarly to [history](#kv-history-bucket-key--timeout-timeout) it creates ephemeral consumer to achieve that.

### kv watch ?*key*? ?-callback *callback*? ?-include_history *include_history*? ?-updates_only *updates_only*? ?-meta_only *meta_only*? ?-ignore_deletes *ignore_deletes*? ?-idle_heartbeat *idle_heartbeat*?

Watch whole `bucket` or a specific `key` for updates.
It takes care of receiving healthcheck (`idle_heartbeat`) from server and re-create consumer if necessary.
By default current state of keys are being passed to `callback` as well as updates.
Returns `watchId` which can be used to stop watching for changes.

`watch` can start with following parameters:
- `callback` - required, callback to be called with new entries/errors,
- `include_history` - callback will receive all available history (instead of only last entry),
- `updates_only` - callback will receive only updates, without current state of keys,
- `meta_only` - entries passed to `callback` will not contain `value`, only headers - it can be useful e.g. to watch for available keys,
- `ignore_deletes` - `callback` will not be called with `delete` and `purge` operations,
- `idle_heartbeat` - default 5000 (5s) - specifies healthcheck time for consumer,

`callback` is called with two arguments: `status` and `msg`, where `status` can be one of:
- `error` - means that there is some problem with watcher - probably server is disconnected or consumer was deleted. More information will be in `msg`,
- `ok` - previously delivered error no longer exists - healthcheck is passing (instead of `ok` new message can be received - it also means that everything is fine),
- `end_of_initial_data` - means that initial data (e.g. history) has been delivered and from now on new messages will contain update.
- empty - new message is being delivered. `msg` will contain new entry.

### kv unwatch *watchId*

Stop watching previously started `watch`.

### kv destroy
TclOO destructor. Remember to call it before destroying the parent `nats::jet_stream`.
