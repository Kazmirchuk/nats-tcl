# Key-Value API

Key-Value functionality of NATS can be accessed by creating the `nats::key_value` TclOO object. Do not create it directly - instead, call the [bind_kv_bucket](JsAPI.md#js-bind_kv_bucket-bucket) or [create_kv_bucket](JsAPI.md#js-create_kv_bucket-bucket--option-value) method of your `nats::jet_stream`. Please refer to the [official documentation](https://docs.nats.io/nats-concepts/jetstream/key-value-store) for the description of general concepts.

## Synopsis

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
[*kv* watch *key args*](#kv-watch-key-args)<br/>
[*kv* destroy](#kv-destroy)<br/>

## Description
The `key_value` object provides access to a specific KV bucket. A bucket is merely a JS `stream` that has some default options, and its name always starts with "KV_". And a key is, in fact, a (portion of) subject that this stream listens to. Therefore, all KV operations are implemented in terms of standard JetStream operations such as  `publish`, `stream_msg_get` etc. They all block in a (coroutine-aware) `vwait` with the same timeout as in the parent `jet_stream`.

The [naming rules](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-6.md) of NATS subjects apply to keys as well, and keys can't start with "_kv".

- `cross-domain` requests are supported (`domain` is copied from `jet_stream` object) so acting on kv from another domain is possible (see examples),
- `mirroring` (as well as `cross-domain` mirroring) is supported.

## Entry
A KV entry is a dict with the following fields:
- `bucket`
- `key`
- `value` - a value or an empty string if it is a DEL or PURGE entry
- `revision` - revision number, starting with 1 (`seq` of the message in the underlying stream)
- `created` - creation timestamp as milliseconds since the epoch
- `delta`
- `operation` - one of `PUT`, `DEL` or `PURGE`

## Bucket status
A bucket status is a dict with the following fields:
- `bucket` - name
- `bytes` - size of the bucket
- `history` - number of history entries per key
- `ttl` - for how long (ms) the bucket keeps values or 0 for unlimited time
- `values` - total number of entries in the bucket including historical ones
- `mirror_name` - optional
- `mirror_domain` - optional
- `stream_config` - configuration of the backing stream
- `stream_state` - state of the backing stream

## Commands
### kv get *key* ?-revision *int*?
Returns the latest entry for the `key` or the entry with the specified `revision`. Throws `ErrKeyNotFound` if the key doesn't exist or was deleted.

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

### kv watch *key args*
Starts watching the `key` (that can be a NATS wildcard) and returns a new `watcher` TclOO object. Destroy this object to stop watching.

KV entries can be delivered to a callback or to an array (or both):
- `-callback cmdPrefix` - deliver entries to this callback.
- `-values_array varName` - deliver values to this array. `varName` must be a fully qualified name.

At least, one of `-callback` or `-values_array` must be provided.

You can further refine what is delivered using these options:
- `-include_history bool` - deliver historical entries as well (default false).
- `-meta_only bool` - deliver entries without values (default false). E.g. to watch for available keys.
- `-ignore_deletes bool` - do not deliver DELETE and PURGE entries (default false).
- `-updates_only bool` - deliver only updates (default false).

If you opt for the **callback** option, it will be invoked from the event loop with the following signature:

**cmdPrefix** *entry*

The callback is invoked in the following order, once for each entry:
1. Historical entries for all matching keys (only with `-include_history=true`).
1. Current entries for all matching keys (if `-updates_only=false`).
2. Then it is invoked once again with an empty `entry` to signal "end of current data".
3. When a key is updated, it is invoked with a new entry.

If you opt for the **array** option:
1. Current keys and values from the bucket are inserted into this array.
2. Afterwards, updates in KV are delivered as they happen.

If a key is deleted or purged from the KV, and `-ignore_deletes=false`, the corresponding key will be removed from the array as well.

Thus, you effectively have a local cache of a whole KV bucket or its portion that is always up-to-date. Depending on your use case, this might be more efficient than querying the bucket with `[$kv get]`.

The array can't be a local variable.

### kv destroy
TclOO destructor. Remember to call it before destroying the parent `nats::jet_stream`.

## Error handling
KV-specific errors are listed in JsAPI.md
