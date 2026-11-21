# Daemon protocol

`0ndb daemon` owns one data directory: the engine (spaces, conversations, maps,
texts, trees, catalog, search), the runtime (runs, runners, queueing, steering)
and the relay links. Every other process (the CLI, a UI, an editor, a host
that supplies plugs) talks to it over one local stream socket. The socket
carries the same op table as the C ABI (`include/0ndb.h`, `ondb_call`), plus
subscriptions, engine events, cancellation, host plugs and two hand-offs (MCP
and the local relay). This document is complete for writing a client in any
language; `bindings/rust/ondb` is the reference client.

## 1. Where the socket is, and who may use it

The socket is `daemon.sock` in the runtime directory:

| OS | runtime directory, first match wins |
|---|---|
| all | `$ONDB_RUNTIME_DIR` |
| all | `$ONDB_HOME/run` |
| Linux | `$XDG_RUNTIME_DIR/0ndb` |
| Linux | `$XDG_DATA_HOME/0ndb/run`, else `~/.local/share/0ndb/run` |
| macOS | `~/Library/Application Support/0ndb/run` |
| Windows | `%LOCALAPPDATA%\0ndb\run` (else `%USERPROFILE%\AppData\Local\0ndb\run`), an AF_UNIX socket |

The data directory (engine, logs, daemon state) is `$ONDB_HOME`, else the
platform data directory above without `run`. Socket paths are limited to 107
bytes (103 on macOS); set `ONDB_RUNTIME_DIR` when the data directory is deep.

Ownership. The directory is created `0700` and the socket is bound under a
`077` umask. Every accepted connection is checked against the daemon's own
user before a byte is read: `SO_PEERCRED` uid on Linux, `getpeereid` on macOS,
`SIO_AF_UNIX_GETPEERPID` plus a token-SID comparison on Windows. Connections
from another user are closed. There is no further authentication: any process
of the same user is trusted with the whole op table, including host plug
registration.

One daemon per data directory. A second `0ndb daemon` on the same directory
exits with `busy`; a daemon that finds a live socket refuses to listen.

Starting. `0ndb daemon [flags]` runs in the foreground (headless servers, a
service manager). `0ndb daemon start [flags]` starts it detached (own session,
stdin and stdout on the null device, log in `daemon.log` of the data
directory), waits until it accepts connections, prints the status (`--json`
for the `daemon.status` object) and exits 0; it passes its flags through and
exits 0 without starting a second one when a daemon already answers. Clients
that autostart should run `0ndb daemon start ...` and then connect. Flags:
`--host-plugs LIST`, `--no-runner`, `--no-full-index`,
`--storage auto|stored|until-run|device`, `--capacity N`, `--provider P`,
`--model M`, `--pool-host`. `0ndb daemon stop` (or the `daemon.stop` op)
stops it after the current loop step.

## 2. Connection and framing

A client opens the socket and writes the 5-byte hello `"0NDB"` followed by the
protocol version byte `1`. The daemon sends nothing back. If the version is
not one it speaks it answers with one `Result` frame (tag 0, status
`unsupported`, JSON payload `{"error":"unsupported","proto":1}`) and closes.
A connection whose first four bytes are not `0NDB` is handed to the local
relay (the relay protocol, `docs/relay-protocol.md`); that is how two
devices on one machine sync without a server.

After the hello, both directions are a sequence of frames:

```
frame := u32le length, u8 kind, payload[length]
```

`length` excludes the 5-byte header and is at most 64 MiB; a longer frame or
an unknown kind closes the connection. All integers inside payloads are
little endian unless the field says uvarint.

| kind | name | direction | payload |
|---|---|---|---|
| 1 | Call | client to daemon | `u64 tag, u8 flags, u64 timeout_ms, request` |
| 2 | Result | daemon to client | `u64 tag, u8 status, result` |
| 3 | Subscribe | client to daemon | `u64 tag, u8 flags, request` |
| 4 | Deltas | daemon to client | `u64 tag, Deltas` |
| 5 | Unsubscribe | client to daemon | `u64 tag` |
| 6 | Mcp | client to daemon | `id space, id object` (32 bytes) |
| 7 | Events | client to daemon | `u8 flags [, u64 mask]` |
| 8 | Event | daemon to client | `Event` |
| 9 | Cancel | client to daemon | `u64 tag` |
| 10 | Plug | daemon to host | `u64 tag, plug request` |
| 11 | Plug_Reply | host to daemon | `u64 tag, u8 status, plug result` |
| 12 | Plug_Cancel | daemon to host | `u64 tag` |
| 13 | Gap | daemon to client | `u64 tag, Gap` |

Tags are chosen by the client, are per connection, and should be unique among
the client's outstanding calls and subscriptions; tag 0 is reserved for
daemon-initiated frames (the version reply, the MCP acknowledgement, plug
notifications). Frames of one connection are processed in order; results of
calls that finish later (a read waiting for remote data) arrive whenever they
finish, so match them by tag.

Flags byte of Call and Subscribe: bit 0 = JSON form (otherwise binary),
bit 1 = compact deltas (Subscribe only, JSON only, see 5). Other bits are
reserved and must be zero.

## 3. Requests and results

The request inside a Call is either form:

- JSON: `{"op":"<name>","<arg>":value,...}`. Absent and null arguments take
  their zero value. Unknown keys are ignored.
- Binary: `u8 version (=1), uvarint op code, arguments in table order`, each
  encoded by its type. Trailing arguments may be omitted (zero value); bytes
  after the last argument are an error.

The result payload of a successful call is the op's result in the same form:
a JSON object, or the result fields in order. A failed call carries status
`!= ok` and the payload `{"error":"<status name>"}` (JSON) or
`uvarint status` (binary). Encodings (the prim codec), enumerations and every
shared structure (`Message`, `Page`, `Window`, `CatalogRow`, `Delta`, `Event`,
`Space`, `Status`, ...) are specified once, in the header comment of
`include/0ndb.h`; this protocol uses them unchanged. In JSON: ids are 32
lowercase hex chars (null when zero), rids `"<seg hex>:<offset>"`, objects
`"<space hex>/<id hex>"`, bytes lowercase hex, enums by name (numbers are
accepted on input). Binary results only append fields at the end, and
optional fields are always present (empty), so a reader can parse any layout
in the header; readers must ignore trailing bytes.

The `describe` op returns the full table (codes, names, argument names and
types, enum value names, result layouts) for mechanical binding generation;
section 11 is that table.

Timeouts. `timeout_ms` 0 means none. A read that waits for remote data
(a page of a conversation that lives on another device) completes when the
data arrives; at the deadline it completes with what is available locally,
and a write completes with `timeout`. The daemon arms a timer only for calls
that are actually waiting.

Status codes (the same in Result frames, plug replies and error payloads):

| code | name | code | name | code | name |
|---|---|---|---|---|---|
| 0 | ok | 9 | forged | 18 | no_memory |
| 1 | pending | 10 | quarantined | 19 | io |
| 2 | not_found | 11 | missing | 20 | bad_request |
| 3 | exists | 12 | corrupt | 21 | unknown_op |
| 4 | invalid | 13 | limit | 22 | conflict |
| 5 | busy | 14 | too_large | 23 | cancelled |
| 6 | closed | 15 | unsupported | 24 | budget |
| 7 | offline | 16 | not_assigned | 25 | spawn |
| 8 | permission | 17 | no_space | 26 | timeout |

`pending` never appears on the wire. `bad_request` is a malformed request,
`unknown_op` an op the daemon does not have (check `describe`).

## 4. Cancellation

`Cancel(tag)` cancels the outstanding call with that tag: the daemon answers
`Result(tag, cancelled)` and the call never produces another result. A
cancel for a tag that already completed is ignored, so a client can always
send one when it stops caring (the Rust client does so when a pending future
is dropped). Cancellation does not roll back effects the op already made
durable. Closing the connection cancels every outstanding call and drops
every subscription of that connection. A call that is waiting on a host plug
when its cancel arrives is cancelled at once and the host receives
`Plug_Cancel` for the request (section 8).

## 5. Subscriptions

`Subscribe(tag, flags, request)` takes one of two requests:

- `{"op":"subscribe","object":O,"kind":"conversation"|"map"|"text"|"tree"}`:
  changes to one object.
- `{"op":"subscribe.catalog","space":S}`: changes to the catalog of a space
  (the session list: every conversation, map, text and tree, with titles,
  status, activity, archived and pinned flags).

The daemon answers `Result(tag, ok)` (or an error with the usual payload),
then sends `Deltas(tag, Deltas)` frames until `Unsubscribe(tag)`, which it
acknowledges with `Result(tag, ok | not_found)`; no Deltas frame for the tag
follows the acknowledgement. Subscribing does not replay history: read the
current state with a call (`convo.window`, `convo.page`, `catalog.list`) after
the subscription is acknowledged, and apply deltas on top (section 7).

Coalescing. The engine delivers deltas once per tick, after the tick's
records are committed: one Deltas frame per subscription per tick, never a
frame per record. Consecutive text of one block within a tick is already
joined into one `chunk` delta. All frames pushed in one daemon loop step
(Deltas, Event, Gap) are flushed together in one write. Nothing is sent while
nothing changes; there is no heartbeat on local sockets.

`Deltas := deltas: [Delta]` (the `Delta` structure of the header): `kind`
(message, block, chunk, seal, leaf, intent, run, mount, record, status,
field, element, counter, catalog, text, files, redacted, members,
quarantined), `object`, `rid` (the record), `msg`, `record`, `by`, `local`,
`hlc`, `role`, `index`, `block`, `seal`, `status`, `usage`, `text`, `key`,
`tag`, `removed`, `length`.

Compact deltas (flags bit 1, JSON only): fields equal to their zero value
(0, false, empty, null, the first enum name) are omitted, and `object` is
omitted when it equals the subscribed object. A client fills omitted fields
with zero values. A streamed chunk costs about 150 bytes instead of 450.

Backpressure. The daemon never buffers without bound for a slow reader. When
more than 1 MiB is queued for a connection it stops queueing deltas and
events for it and keeps only what lets the client catch up:

- a conversation, map, text or tree subscription is marked as having a gap;
- a catalog subscription keeps the set of objects whose rows changed (up to
  4096, after that it is marked as a full gap);
- events keep only the latest per key (kind, space, object, device), so the
  client sees the newest placement, presence and connectivity, not every
  intermediate one.

When the queue drains below 64 KiB the daemon sends, per affected
subscription, `Gap(tag, {full: bool, objects: [object]})`, then the retained
events. On a Gap the client re-reads: `catalog.get` for each listed object
(or `catalog.list` when `full`), and for a conversation the current window
from its last position (`convo.page` newer from its cursor, plus
`convo.status`). Deltas after the Gap frame apply on top of what it re-reads.
Results of calls are never dropped; a connection with more than 128 MiB of
unread results is closed.

Applying deltas idempotently. A delta delivered after a Gap or right after a
subscribe can describe a record the client already read through a call.
`message`, `seal`, `leaf`, `status`, `catalog` and `intent` deltas are
idempotent by their keys (`msg`, `object`, `rid`). Streamed text (`block`,
`chunk`) is provisional: treat it as display state and replace the message
with `convo.message` when its `seal` delta arrives.

## 6. Events

`Events(flags [, mask])` turns engine and placement events on for the
connection: flags bit 0 = JSON, bit 1 = off. `mask` (u64le) selects event
kinds by code, bit i for code i; absent means all. Each event is one
`Event` frame:

```
Event := kind: enum event, space: id, object: id, device: id, tick: uvarint,
         length: ivarint, status: enum status, detail: str,
         state: enum placement, msg: rid, runner: id, provider: str,
         since_ms: ivarint
```

Event codes: 0 connected, 1 disconnected, 2 durable, 3 uploaded,
4 quarantined, 5 refused, 6 fatal, 7 space_joined, 8 object_seen, 9 failure,
10 placement, 11 relay_misbehaving, 12 presence, 13 caught_up,
14 indexer_wanted, 15 unavailable, 16 available, 17 promoted,
18 peer_misbehaving, 19 members_changed, 20 epoch_changed,
21 access_revoked, 22 runner_enrolled, 23 runner_anomaly,
24 approval_requested, 25 login_done, 26 login_failed. The meaning of each
field per kind is in the header (`Event`). For a UI: `placement` (where a
conversation's next run is, or that it waits for a runner), `presence`
(device up or down, `tick` 1 or 0), `connected`/`disconnected` (relay link of
a space), `approval_requested`, `login_done` and `login_failed` (sign-in),
`access_revoked`. `durable` and `uploaded` fire once per committed tick and
per upload; a UI should leave them out of its mask (the Rust client does).
Conversation status (idle, running, queued, awaiting_permission, ...)
arrives as `status` deltas of the conversation subscription and as the row
status in catalog deltas, not as events.

## 7. Recipes for a live UI

Session list. `catalog.list(space, archived, after, limit)` pages rows
(`rows`, `more`, `next`; pass `next` as `after`). Subscribe to
`subscribe.catalog(space)` first, then list; on a `catalog` delta for object
X call `catalog.get(X)` (or apply the delta's fields); on a Gap re-get the
listed objects.

Open a conversation at the bottom. Subscribe to the conversation, read
`convo.status` and take `position` (the reader's message; `head` when it is
null), then `convo.window(object, anchor: position, before: N)`: the
newest N + 1 messages oldest first, `older_cursor`, `more_older`, `leaf`
(`convo.window` requires an anchor). `convo.page(object, limit: N)` with no
`from` is the one-call alternative: newest first from the reader's position,
with its `cursor`. Scroll up with `convo.page(object, cursor: older_cursor,
limit: N)` (newest first); each page returns the next `cursor` and `more`.

Open at a message (search hit, deep link). `convo.window(object, anchor: M,
before: B, after: A)` returns the messages around M, the index of M, and both
cursors. Page up with `older_cursor` and down with `newer_cursor` through
`convo.page`. A cursor carries direction, position, leaf and an end mark: it
overrides `from`, `dir` and `leaf`; an exhausted cursor returns an empty page
with `more: false`. `from` alone is exclusive (the page starts after it);
to read forward from the root, take a window anchored at the root.

Branches. `convo.siblings(msg)` lists the alternatives of a message;
`convo.peek_switch` previews one; `switch` makes it current, `back` returns
to an earlier message, `follow` follows the newest leaf again.

Typing. `send` starts a turn (or records the message when nothing runs it),
`queue` adds a message for after the current turn, `steer` adds input to the
running turn, `edit` changes a queued message, `cancel` drops one,
`interrupt` stops the running turn, `answer` replies to a permission or
question block. `record` writes a message produced elsewhere (a harness the
host runs itself) idempotently by `(source, external_id, sequence)`.

## 8. Host plugs

Some engine plug points belong to the embedding application rather than to
0ndb: the account server, the platform passkey, the cloud runner pool, relay
credentials. In a process that links lib0ndb they are C function tables
(`ondb_sealed_store`, `ondb_unlock`, `ondb_runner_pool`, `ondb_credentials`).
Over the daemon they are served by a host: any connection that registers for
them and answers the daemon's plug requests.

Enabling. The daemon decides at start which plugs a host supplies:
`--host-plugs` takes a comma-separated subset of

| plug | functions | role |
|---|---|---|
| `sealed_store` | get, put, add | the account server keyed by login subject |
| `unlock` | unlock, register | the platform passkey (WebAuthn PRF) |
| `credentials` | available, produce | relay credentials per space |
| `runner_pool` | identity, verify, attest | this daemon is a cloud pool host |
| `pool_user` | identity, joined | this device's account includes a cloud pool |

(`runner_pool` and `pool_user` exclude each other.) Plugs not listed keep the
daemon's built-in reference implementations. A listed plug is strictly
host-backed: with no host registered its requests wait for one until their
deadline and then fail `offline`; they never fall back to a local store.

Registering. The host sends a normal call
`host.register(plugs: [str], replace: bool)` and gets back the plugs it now
serves. The form of that call (JSON or binary) is the form of every plug
request and reply on the connection. Errors: `invalid` (unknown plug name),
`unsupported` (the daemon was not started with that plug), `busy` (another
live connection serves it; pass `replace: true` to take over). Registering
again replaces the connection's set; closing the connection unregisters it.
A host connection is otherwise an ordinary client: it can call any op.

Requests. The daemon sends `Plug(tag, request)` and the host answers
`Plug_Reply(tag, status, result)`. Binary request:
`u8 version (=1), uvarint function code, fields in order`; JSON request:
`{"plug":"<name>", fields...}`. The result has the reply fields (binary in
order, or a JSON object). Status is a status code from section 3; for
replies that mean "no", use `not_found`, `conflict`, `permission` or
`unsupported` as listed. A notification has tag 0 and takes no reply.

| code | function | request fields | reply fields | deadline |
|---|---|---|---|---|
| 1 | `sealed_store.get` | subject: bytes | record: bytes, entries: [bytes]; `not_found` when no account | 15 s |
| 2 | `sealed_store.put` | subject: bytes, record: bytes, prev_seq: uvarint, seq: uvarint | {}; `conflict` unless the stored seq is prev_seq (0 = none stored) | 15 s |
| 3 | `sealed_store.add` | subject: bytes, entry: bytes | {} | 15 s |
| 4 | `unlock.unlock` | rp_user: bytes, credentials: [bytes], salts: [bytes], mode: enum{local, cross_device} | credential: bytes, prf: bytes (32); `not_found` when none of the credentials is available | 120 s |
| 5 | `unlock.register` | rp_user: bytes, label: str, salt: bytes (32) | credential: bytes, prf: bytes (32), ecosystem: enum | 120 s |
| 6 | `runner_pool.identity` | – | sign: bytes (32), box: bytes (32) | 15 s |
| 7 | `runner_pool.verify` | token: bytes, sign: bytes, box: bytes | lease_ms: uvarint; `permission` for a bad token | 15 s |
| 8 | `runner_pool.attest` | evidence: bytes, sign: bytes, box: bytes | {}; `permission` to refuse | 15 s |
| 9 | `pool_user.identity` | – | sign: bytes (32), box: bytes (32) | 15 s |
| 10 | `pool_user.joined` | space: id, name: str, relay: str, relay_key: bytes, proof: bytes | notification | – |
| 11 | `credentials.available` | space: id | available: bool | 5 s |
| 12 | `credentials.produce` | space: id, binding: bytes | credential: bytes | 5 s |

`[bytes]` is `uvarint count` then each `bytes` in binary, an array of hex
strings in JSON. `ecosystem`: unknown, apple, google, microsoft, 1password,
bitwarden, security_key, recovery, test. In `unlock.unlock` the i-th salt
belongs to the i-th credential; evaluate the PRF of the chosen credential
with its salt (WebAuthn `prf.evalByCredential`), always with user
verification. `register` creates a passkey for `rp_user`, evaluates its PRF
with `salt` and reports the ecosystem it was saved in. The sealed record and
entries are opaque ciphertext and signatures: the store keeps them, enforces
the compare-and-swap on `seq`, and returns the newest record (at most
64 KiB) and every entry (at most 4 MiB in all) in the order they were added.
A put that repeats the stored record exactly must answer `ok` (the daemon
resends a request to a host that reconnects). `credentials.produce` returns
the credential for one relay connection, bound to `binding` (the relay's
challenge); `available` says whether the host supplies credentials for the
space at all (otherwise the device's member credentials are used). Requests
for `credentials` never wait for a host to register: with none, `available`
is false.

Deadlines, cancellation and reconnect. Each request has the deadline in the
table, counted from when the daemon issues it and covering both waiting for
a host and waiting for its answer. When it passes the daemon sends
`Plug_Cancel(tag)` and the engine sees the plug fail; the client call that
caused it fails `timeout` (host registered but silent) or `offline` (no
host). A client `Cancel` of that call, or the daemon stopping, also sends
`Plug_Cancel`; a host should abort the work (dismiss the passkey sheet) and
may drop its reply. If the host's connection closes while a request is
outstanding and another host registers before the deadline, the daemon
resends the request to it; `pool_user.joined` notifications made while no
host is registered are queued (the newest 256) and delivered when one
registers. A reply for a tag that is no longer outstanding is ignored.

Waiting. In this version a plug request is synchronous inside the engine:
while one is outstanding the daemon reads only host registrations, plug
replies and Cancel frames (from every connection, so a host on its own
connection, a reconnecting host and a cancelling client all work) and serves
every other frame as soon as the plug returns. A host should answer store
and credential requests promptly; a slow or hung host delays other clients
until the deadline. Asynchronous plugs, which remove this, are in progress.

Identity-provider PRF path. A UI that runs WebAuthn itself (or whose identity
provider evaluates the passkey PRF) does not need the `unlock` plug: it reads
`account.idp_salt(subject)`, evaluates the PRF with that salt, and calls
`account.login_prf(subject, credential, prf, label, relay, relay_key)`;
`account.passkey_add(label, credential, prf)` adds such a passkey to a
signed-in account.

## 9. MCP hand-off

`Mcp(space, object)` turns the connection into a stdio MCP session for the
orchestration catalog with the given conversation as the caller: the daemon
answers `Result(0, ok)` with an empty payload, and from then on the bytes in
both directions are MCP JSON-RPC lines, not frames. `0ndb mcp` bridges this
to a harness's stdio.

## 10. Versioning

- Protocol version (the hello byte, `proto` in `daemon.status`): changes only
  when the framing changes incompatibly. New frame kinds are added only in
  ways an older peer never receives unasked (a client gets Gap frames only if
  it subscribes, Plug frames only if it registers).
- Request version (the first byte of a binary request, `api` in
  `daemon.status`): changes when binary argument encoding changes.
- Op table: ops and arguments are only appended; an argument is never
  reordered or retyped. `describe` is authoritative; `unknown_op` means the
  daemon predates the op.
- Results: fields are only appended. JSON clients ignore unknown fields and
  default missing ones; binary clients ignore trailing bytes.
- `version` in `daemon.status` is the build.

`daemon.status` result: `version, proto, api, pid, home, socket, uptime_ms,
rss, runner, connections, local_relay, mcp_sessions, wakeups, timeout_ms
(-1 when no timer is armed), host_plugs: [str] (enabled), hosts: [str]
(currently registered), links: [{space, error, reason}]`.

## 11. Op reference

Generated from `describe`. Argument types: `str`, `bytes`, `bool`, `uvarint`,
`ivarint`, `f64`, `id`, `rid`, `object`, `enum` (accepted names listed),
`ids`, `strs`, `uvarints`, `fields`, `attachments`, `blocks`. Result layouts
are `name:type` lists or structure names from `include/0ndb.h`. Ops 1000 and
up exist only over the socket.

### Engine and introspection

| code | op | arguments | result |
|---|---|---|---|
| 1 | `identity` | – | Identity |
| 2 | `stats` | – | Stats |
| 3 | `flush` | – | {} |
| 6 | `describe` | – | Description |
| 109 | `card` | – | card:bytes |

### Subscriptions (send with a Subscribe frame, never a Call)

| code | op | arguments | result |
|---|---|---|---|
| 4 | `subscribe` | object: object, kind: enum conversation|map|text|tree | Deltas |
| 5 | `subscribe.catalog` | space: id | Deltas |

### Accounts, devices, members and runner pools

| code | op | arguments | result |
|---|---|---|---|
| 8 | `account.login` | subject: str, label: str, relay: str, relay_key: bytes | path:enum login_path status:enum login_status code:str spaces:uvarint |
| 9 | `account.login_cross_device` | subject: str | path:enum login_path status:enum login_status code:str spaces:uvarint |
| 10 | `account.login_recovery` | subject: str, key: str | path:enum login_path status:enum login_status code:str spaces:uvarint |
| 11 | `account.state` | – | AccountState |
| 12 | `account.listen` | – | {} |
| 13 | `approval.list` | – | approvals:[Approval] |
| 14 | `approval.respond` | code: str, approve: bool | {} |
| 15 | `account.passkeys` | – | passkeys:[Passkey] |
| 16 | `account.passkey_remove` | credential: bytes | {} |
| 17 | `account.recovery_key` | – | key:str |
| 18 | `account.devices` | – | devices:[Device] |
| 19 | `account.pool` | access: enum off|everything|workspace|only_sent | {} |
| 20 | `device.remove` | device: id | spaces:uvarint |
| 21 | `space.members` | space: id | members:[Member] |
| 22 | `space.members_status` | space: id | MembersStatus |
| 23 | `member.remove` | space: id, device: id | {} |
| 24 | `member.add` | space: id, card: bytes, kind: enum device|account|recovery|custodian|pool|runner|guest|directory, role: enum owner|admin|member|reader, lease_ms: uvarint | proof:bytes |
| 25 | `space.rotate` | space: id | {} |
| 26 | `space.pool` | space: id, on: bool | {} |
| 27 | `space.join_enrollment` | space: id, proof: bytes, name: str, relay: str, relay_key: bytes | space:id |
| 28 | `account.join_space` | space: id | {} |
| 29 | `pool.enroll` | token: bytes, card: bytes, evidence: bytes | enrollment:bytes |
| 30 | `runner.enroll` | enrollment: bytes | spaces:uvarint |
| 31 | `lease.renew` | – | renewed:uvarint |
| 32 | `account.login_prf` | subject: str, credential: bytes, prf: bytes, label: str, relay: str, relay_key: bytes | path:enum login_path status:enum login_status code:str spaces:uvarint |
| 33 | `account.passkey_add` | label: str, credential: bytes, prf: bytes | {} |
| 34 | `account.idp_salt` | subject: str | salt:bytes |
| 35 | `directory.add` | space: id, person: bytes, role: enum owner|admin|member|reader, devices: strs | {} |
| 36 | `directory.remove` | space: id, person: bytes | {} |
| 37 | `account.sign_out` | keep_relay: bool | spaces:uvarint |
| 1008 | `pool.token` | – | token:str |

### Spaces

| code | op | arguments | result |
|---|---|---|---|
| 7 | `space.create` | name: str, relay: str, relay_key: bytes, mode: enum end_to_end|transparent | space:id |
| 41 | `space.list` | – | spaces:[Space] |
| 42 | `space.info` | space: id | space:Space |
| 43 | `space.set_relay` | space: id, relay: str, relay_key: bytes | {} |
| 44 | `space.open` | space: id | {} |
| 45 | `space.close` | space: id | {} |
| 46 | `space.join_shared` | space: id, name: str, relay: str, relay_key: bytes | {} |

### Storage

| code | op | arguments | result |
|---|---|---|---|
| 38 | `storage.availability` | object: object | unavailable:bool holders:[id] class:uvarint |
| 39 | `storage.stats` | – | promotions:uvarint promoted:uvarint served:uvarint unavailable:uvarint |
| 40 | `object.promote` | object: object, from: uvarint | {} |

### Conversations: reads

| code | op | arguments | result |
|---|---|---|---|
| 47 | `convo.create` | space: id, title: str, agent: id, workspace: id, parent: object, parent_msg: rid, provider: str, model: str | object:object |
| 48 | `convo.status` | object: object | Status |
| 49 | `convo.page` | object: object, from: rid, from_seal: rid, from_known: bool, limit: uvarint, dir: enum older|newer, leaf: rid, cursor: bytes | Page |
| 50 | `convo.message` | object: object, msg: rid | message:Message |
| 51 | `convo.siblings` | object: object, msg: rid | siblings:[rid] at:uvarint |
| 52 | `convo.intents` | object: object | intents:[Intent] |
| 53 | `convo.mounts` | object: object | mounts:[Mount] |
| 54 | `convo.settings` | object: object | Settings |
| 55 | `convo.files_at` | object: object, msg: rid | files:[File] |
| 56 | `convo.compactions` | object: object, floor: uvarint | compactions:[Compaction] |
| 57 | `convo.unsealed` | object: object | unsealed:[Unsealed] |
| 58 | `convo.window` | object: object, anchor: rid, before: uvarint, after: uvarint, leaf: rid | Window |
| 59 | `convo.peek_switch` | object: object, sibling: rid, before: uvarint, after: uvarint | Window |

### Conversations: writes and control

| code | op | arguments | result |
|---|---|---|---|
| 60 | `send` | object: object, text: str, parent: rid, role: enum user|assistant|system|tool, provider: str, model: str, attachments: attachments | Result |
| 61 | `queue` | object: object, text: str, attachments: attachments | Result |
| 62 | `steer` | object: object, text: str, msg: rid, attachments: attachments | Result |
| 63 | `edit` | object: object, item: rid, text: str, attachments: attachments | Result |
| 64 | `cancel` | object: object, item: rid | Result |
| 65 | `interrupt` | object: object, msg: rid | Result |
| 66 | `answer` | object: object, request: rid, allow: bool, text: str | Result |
| 67 | `switch` | object: object, sibling: rid | Result |
| 68 | `back` | object: object, msg: rid | Result |
| 69 | `follow` | object: object | Result |
| 70 | `mount` | object: object, name: str, tree: id, line: id, path: str | Result |
| 71 | `unmount` | object: object, name: str | Result |
| 72 | `await` | object: object, tasks: ids, condition: enum any|all, deadline: uvarint, expr: str | Result |
| 73 | `assign` | object: object, msg: rid, runner: id | Result |
| 74 | `redact` | object: object, msg: rid | Result |
| 124 | `record` | object: object, source: str, external_id: str, sequence: uvarint, role: enum user|assistant|system|tool, parent: rid, blocks: blocks, status: enum open|done|interrupted|failed|cancelled, input: uvarint, output: uvarint, cache_read: uvarint, cache_write: uvarint, provider: str, model: str, native: str | receipt:enum msg:rid |
| 131 | `land` | tree: object, from: str, into: str, dry: bool | landed:bool files:uvarint conflicts:strs |
| 132 | `go_back` | object: object, msg: rid | {} |
| 133 | `revert` | object: object, msg: rid | reverted:[str] |
| 138 | `wake` | object: object | {} |

### Maps, texts and trees

| code | op | arguments | result |
|---|---|---|---|
| 75 | `map.create` | space: id, title: str, settings: bytes | object:object |
| 76 | `map.get` | object: object, key: bytes | found:bool entry:Entry |
| 77 | `map.scan` | object: object, prefix: bytes, after: bytes, limit: uvarint | rows:[Entry] more:bool next:bytes |
| 78 | `map.set` | object: object, key: bytes, fields: fields | Result |
| 79 | `map.delete` | object: object, key: bytes, tags: uvarints | Result |
| 80 | `map.add` | object: object, key: bytes, tag: uvarint, element: bytes | Result |
| 81 | `map.remove` | object: object, key: bytes, tag: uvarint, element: bytes | Result |
| 82 | `map.redact` | object: object, key: bytes | {} |
| 83 | `text.create` | space: id, title: str, initial: str | object:object |
| 84 | `text.read` | object: object | text:str |
| 85 | `text.spans` | object: object | spans:[Span] |
| 86 | `text.edit` | object: object, pos: uvarint, remove: uvarint, insert: str | Result |
| 87 | `text.redact` | object: object, pos: uvarint, len: uvarint | {} |
| 88 | `tree.create` | space: id, title: str | object:object |
| 89 | `tree.read` | object: object, path: str | text:str |
| 90 | `tree.list` | object: object, path: str | names:[str] |
| 91 | `tree.write` | object: object, path: str, text: str | {} |
| 92 | `tree.remove` | object: object, path: str | {} |
| 93 | `tree.mount` | object: object, root: str | {} |
| 94 | `tree.unmount` | object: object, root: str | {} |
| 95 | `tree.mounts` | – | mounts:[Mounted] |
| 96 | `tree.blame` | object: object, path: str | text:str spans:[Span] |
| 97 | `tree.sync` | object: object, root: str | {} |
| 98 | `tree.find` | path: str | object:object root:str rel:str |

### Catalog (the session list)

| code | op | arguments | result |
|---|---|---|---|
| 99 | `catalog.get` | object: object | found:bool entry:CatalogEntry |
| 100 | `catalog.list` | space: id, archived: bool, after: bytes, limit: uvarint | rows:[CatalogRow] more:bool next:bytes |
| 101 | `catalog.usage` | object: object | Usage |
| 102 | `catalog.set` | object: object, set: uvarint, title: str, archived: bool, pinned: bool, parent: object, parent_msg: rid, workspace: id, agent: id | Result |

### Search

| code | op | arguments | result |
|---|---|---|---|
| 103 | `search` | query: str, limit: uvarint, cursor: bytes, sort: enum relevance|newest, semantic: bool, collapse: bool, space: id, scope: enum auto|local|everywhere | Results |
| 104 | `search.mode` | space: id, mode: enum default|full|local | mode:enum |
| 105 | `search.wrote` | tree: id, path: str, unit: enum lines|bytes, lo: uvarint, hi: uvarint | hits:[Wrote] |

### Sharing

| code | op | arguments | result |
|---|---|---|---|
| 106 | `share.object` | object: object, card: bytes | share:bytes |
| 107 | `share.accept` | share: bytes | object:object |
| 108 | `capability.issue` | object: object, grantee: id, access: uvarint, expires: ivarint | token:bytes |

### Workspaces and agents

| code | op | arguments | result |
|---|---|---|---|
| 110 | `workspace.create` | space: id, name: str, agent: id, provider: str, model: str, setup: str | object:object |
| 111 | `workspace.get` | object: object | Workspace |
| 112 | `workspace.add_member` | object: object, member: id, kind: enum conversation|map|text|tree, role: enum tree|document|memory, mount: str, path: str | {} |
| 113 | `workspace.remove_member` | object: object, member: id, kind: enum conversation|map|text|tree, role: enum tree|document|memory, mount: str, path: str | {} |
| 114 | `agent.create` | space: id, name: str, instructions: str, driver: str, provider: str, model: str, workspace: id, options: bytes, budget: bytes | object:object |
| 115 | `agent.get` | object: object | Agent |
| 116 | `agent.set` | object: object, name: str, instructions: str, driver: str, provider: str, model: str, workspace: id, options: bytes, budget: bytes | {} |
| 117 | `agent.add` | object: object, tag: uvarint, element: bytes | {} |
| 118 | `agent.remove` | object: object, tag: uvarint, element: bytes | {} |
| 123 | `agent.resolve` | object: object, provider: str, model: str | AgentInfo |
| 137 | `agent.actor` | agent: id | actor:id |

### Runtime

| code | op | arguments | result |
|---|---|---|---|
| 119 | `runtime.attach` | space: id | {} |
| 120 | `runtime.detach` | space: id | {} |
| 121 | `runtime.stats` | – | RuntimeStats |
| 122 | `models` | live: bool, refresh: bool | Models |
| 125 | `task.status` | object: object | TaskStatus |
| 126 | `task.children` | object: object, limit: uvarint | children:[CatalogRow] |
| 127 | `task.changes` | object: object, caller: object, diff: bool, max_chars: uvarint | changes:[Change] diff:str |
| 128 | `schedule.create` | owner: object, id: str, prompt: str, cron: str, at: ivarint, tz: str, conversation: object, fresh: bool | {} |
| 129 | `schedule.list` | space: id | schedules:[Schedule] |
| 130 | `schedule.remove` | owner: object, id: str | found:bool |
| 134 | `channel.deliver` | space: id, channel: str, key: str, text: str, sender: str, title: str, agent: id, workspace: id | object:object |
| 135 | `event.deliver` | space: id, agent: id, name: str, payload: str | {} |
| 136 | `trigger.watch` | object: object | {} |
| 139 | `placement` | object: object | Placement |

### Daemon host ops (only over the socket)

| code | op | arguments | result |
|---|---|---|---|
| 1000 | `daemon.status` | – | DaemonStatus |
| 1001 | `daemon.stop` | – | {} |
| 1002 | `state.get` | – | default_space:id current:object |
| 1003 | `state.set` | default_space: id, current: object | {} |
| 1004 | `mount.add` | object: object, root: str | {} |
| 1005 | `mount.remove` | root: str | {} |
| 1006 | `credentials.add` | space: id, token: bytes | {} |
| 1007 | `verify` | root: str | files:uvarint mismatches:[str] |
| 1009 | `host.register` | plugs: strs, replace: bool | plugs:[str] |
