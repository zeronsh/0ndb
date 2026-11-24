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
A longer path is refused with an error that names the path and the limit;
`daemon start` exits with it, so an autostarting client reports it.

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
section 12 is that table.

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
| | | | | 27 | newer |

`pending` never appears on the wire. `bad_request` is a malformed request,
`unknown_op` an op the daemon does not have (check `describe`).

## 4. Cancellation

`Cancel(tag)` cancels the outstanding call with that tag: the daemon answers
`Result(tag, cancelled)` and the call never produces another result. A
cancel for a tag that already completed is ignored, so a client can always
send one when it stops caring (the Rust client does so when a pending future
is dropped). Cancellation does not roll back effects the op already made
durable. Closing the connection cancels every outstanding call and drops
every subscription of that connection. A call whose flow is waiting on a host
plug is cancelled at once and the host receives `Plug_Cancel` for the request
(section 8).

## 5. Subscriptions

`Subscribe(tag, flags, request)` takes one of three requests:

- `{"op":"subscribe","object":O,"kind":"conversation"|"map"|"text"|"tree"}`:
  changes to one object.
- `{"op":"subscribe.catalog","space":S}`: changes to the catalog of a space
  (the session list: every conversation, map, text and tree, with titles,
  status, activity, archived and pinned flags). Each `catalog` delta's
  `object` is the row that changed; read its fields with `catalog.get`.
- `{"op":"subscribe.runners","space":S[,"object":C]}`: the runner directory
  of a space (or of conversation `C`, which adds `current` and `last`). Each
  frame carries the whole `Runners` payload (the `runners` op's result), not
  deltas, and is pushed when a runner's advert or presence changes, or when
  `C`'s placement changes. Read the first state with `runners`.
- `{"op":"subscribe.fork_diff","object":T[,"caller":C,"diff":bool,"max_chars":N]}`:
  the live diff of task `T`'s forked lines against its parent's (or `C`'s)
  lines. The fork side is the task's open run line while it runs, so edits
  show as the agent makes them. Each frame carries the whole `task.changes`
  payload (`changes`, and `diff` when asked). A frame is pushed once per
  tick, and only when that payload changed. Read the first state with
  `task.changes`.

The daemon answers `Result(tag, ok)` (or an error with the usual payload),
then sends `Deltas(tag, Deltas)` frames until `Unsubscribe(tag)`, which it
acknowledges with `Result(tag, ok | not_found)`; no Deltas frame for the tag
follows the acknowledgement. Subscribing does not replay history: read the
current state with a call (`convo.window`, `convo.page`, `catalog.list`) after
the subscription is acknowledged, and apply deltas on top (section 7).

Coalescing. The engine delivers deltas once per tick, after the tick's
records are committed: one Deltas frame per subscription per tick, never a
frame per record. Consecutive text of one block within a tick is already
joined into one `chunk` delta. Live-buffer frames are written as soon as
the tick has advanced its buffers, and the subscription frames of a tick in
one write as soon as their delivery ends, both before the tick goes on to
its durability work. Other frames pushed in a daemon loop
step (Event, Gap) are flushed together at the end of the step. Nothing is sent while
nothing changes; there is no heartbeat on local sockets.

`Deltas := deltas: [Delta]` (the `Delta` structure of the header): `kind`
(message, block, chunk, seal, leaf, intent, run, mount, record, status,
field, element, counter, catalog, text, files, reserved, members,
quarantined), `object`, `rid` (the record), `msg`, `record`, `by`, `local`,
`hlc`, `role`, `index`, `block`, `seal`, `status`, `usage`, `text`, `key`,
`tag`, `removed`, `length`, and in JSON `draft: true` on `block` and `chunk`
deltas whose text came from a live draft rather than the segment (no `rid`).
Each byte of a block is delivered once, whichever source brings it first; the
sealed block holds exactly the concatenated text.

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
         since_ms: ivarint, last_runner: id
```

Event codes: 0 connected, 1 disconnected, 2 durable, 3 uploaded,
4 quarantined, 5 refused, 6 fatal, 7 space_joined, 8 object_seen, 9 failure,
10 placement, 11 relay_misbehaving, 12 presence, 13 caught_up,
14 indexer_wanted, 15 unavailable, 16 available, 17 promoted,
18 peer_misbehaving, 19 members_changed, 20 epoch_changed,
21 access_revoked, 22 runner_enrolled, 23 runner_anomaly,
24 approval_requested, 25 login_done, 26 login_failed, 27 lease_lapsed, 28 space_left,
29 line_switched (a mount's tree moved lines on a branch switch: `object` is the
tree, `detail` is `<from line>\n<to line>`),
30 reserved,
31 rename_offered (edits made to a file after another device renamed it onto
an existing name are offered on the destination: `object` is the tree,
`detail` is `<source path>\n<destination path>`),
32 reserved, 33 models_changed,
34 authors_resolved (an author a `tree.blame` span of `object` showed as
`unresolved` became known: blame it again for its owner). The meaning of each
field per kind is in the header (`Event`). For a UI: `placement` (where a
conversation's next run is; see "Placement" below), `presence`
(device up or down, `tick` 1 or 0), `connected`/`disconnected` (relay link of
a space), `approval_requested`, `login_done` and `login_failed` (sign-in),
`access_revoked`, `space_left` (a left space is erased). `durable` and `uploaded` fire once per committed tick and
per upload; a UI should leave them out of its mask (the Rust client does).
Conversation status (idle, running, queued, awaiting_permission, ..., held)
arrives as `status` deltas of the conversation subscription and as the row
status in catalog deltas, not as events.

Placement. `state` is one of `none` (the conversation never ran),
`assigned` (`runner` will run `msg`), `running` (`runner` runs it), `idle`
(nothing will move on its own: at rest, or `msg` was cut off because
`last_runner` stopped and the takeover policy keeps the work there),
`waiting_runner` (a placement request: `msg` waits for `runner`, a pool
runner the host may wake or a pool, or for any runner when `runner` is
null) and `placing` (the host's scheduler plug has not answered yet). An
idle conversation continues on its last runner when that runner returns
(the same runner revives its own cut-off turn after a restart) or wherever
`assign(object, runner)` sends it.

When placement events fire. For every conversation a client of this daemon
observes (a conversation subscription, or a `subscribe.runners` naming it),
each change of its placement is reported once, whichever device caused it:
`assigned`, `running` with the runner that runs it, `idle` with
`last_runner`, `waiting_runner` and `placing`. The same change pushes a
runners frame to subscriptions naming the conversation. Changes are found
from the conversation's catalog row changes and runner presence, never by
polling. For conversations nobody observes, only this device's own
placement decisions are reported.

Takeover policy. `takeover.set(object, level, policy)` stores `default`,
`auto` or `never` on a conversation (in its catalog row), an agent or a
workspace; the most specific setting wins and `takeover.get` returns the
stored and the effective value. Under `default` a device runner that goes
away leaves its work idle; a pool runner that goes away leaves a placement
request naming it (`waiting_runner`), which the scheduler answers (the
reference answer is the same runner, for the host to wake; a host may name
another). `auto` continues on another runner; `never` waits for the same
runner. Revival on the same runner after a restart always proceeds, and
scheduled runs fire on the runner that created them under the policy of
their conversation. Placement prefers the conversation's last runner, and a
child conversation's parent's runner when it has none of its own.

Runner directory. `runners(space[, object])` lists every runner of the
space for a device switcher: devices one per entry, each pool once (its
`device` is the pool's member id and `name` its label). A device's `name`
is the daemon's `--name`, else the `label` it signed in with, else its host
name; it is advertised again when sign-in completes. `Runner := device:
id, name: str, kind: enum{device,pool}, state: enum{offline,online,wakeable},
providers: strs, signed_in: strs, current: bool, last: bool`. A pool is
`online` while any of its runners is, else `wakeable` while the pool is a
member. `providers` lists the harnesses installed (a pool: offered by any of
its runners) and `signed_in` those with credentials present. Resuming is
`assign(object, runner)` without `msg`: a turn cut off mid-flight continues
on `runner` with its full context, otherwise the next turn runs there, and
the conversation's schedules whose creator is gone move with it. Assigning
a pool records a placement request: the pool's runner that last ran the
conversation takes it, any other needs the host to assign a concrete runner.

## 7. Recipes for a live UI

Session list. `catalog.list(space, archived, after, limit)` pages rows
(`rows`, `more`, `next`; pass `next` as `after`). A row's `object` is the
full object (`space/id` in JSON), as in deltas and every op argument; so is
the `object` of `catalog.find`, `task.children` and `catalog.get` results. Subscribe to
`subscribe.catalog(space)` first, then list. A `catalog` delta names the row
that changed in `object` (an object of the space; one delta per row per
frame) and carries no field values: call `catalog.get(object)` and replace
the row. On a Gap re-get the listed objects.

Resolving a short id or title. `catalog.find(space, text)` returns every row
whose hex object id starts or ends with `text` (case-insensitive) or whose
title equals it. When nothing matches it waits only while the space's catalog
is behind the relay (a catalog segment the relay holds more of than is
applied, or the feed not yet caught up since connecting); once caught up it
answers with whatever matches, possibly nothing. Without a relay connection it
answers at once.

Waiting for the relay. Calls return once a write is durable on this device;
the relay's acknowledgement arrives later as an `Uploaded` event. A client
that must know other devices can see an object (the CLI's `new` does) calls
`object.uploaded(object)`: it answers `uploaded` once the relay has
acknowledged everything this device has committed to the object and to its
space's catalog; while connected it waits for that, without a connection it
answers at once with `uploaded` false, and if the connection drops while it
waits it answers `uploaded` false with `dropped`.

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

| plug | requests | role |
|---|---|---|
| `sealed_store` | get, put, add | the account server keyed by login subject |
| `unlock` | unlock, register | the platform passkey (WebAuthn PRF) |
| `credentials` | produce | relay credentials for the spaces the host lists |
| `runner_pool` | verify, attest, renew | this daemon is a cloud pool host |
| `scheduler` | place | run placement (the runtime's `Scheduler`) |
| `pool_user` | joined (notification) | this device's account includes a cloud pool |

(`runner_pool` and `pool_user` exclude each other.) Plugs not listed keep the
daemon's built-in reference implementations. A listed plug is strictly
host-backed: with no host registered its requests wait for one until their
deadline and then fail; they never fall back to a local store.

Registering. The host sends a normal call
`host.register(plugs: [str], replace: bool, identity: bytes, spaces: ids)`
and gets back the plugs it now serves. The form of that call (JSON or binary)
is the form of every plug request and reply on the connection. `identity` is
required with `runner_pool` or `pool_user`: the pool's public keys, 64 bytes
(`sign` then `box`), which the daemon answers the engine's identity queries
with. `spaces` lists the spaces the `credentials` host supplies relay
credentials for; other spaces use the device's member credentials. Errors:
`invalid` (unknown plug name, missing identity), `unsupported` (the daemon was
not started with that plug), `busy` (another live connection serves it; pass
`replace: true` to take over). Registering again replaces the connection's
set; closing the connection unregisters it. A host connection is otherwise an
ordinary client: it can call any op. Requests that were waiting for a host are
sent right after the registration's Result.

Requests. The daemon sends `Plug(tag, request)` and the host answers
`Plug_Reply(tag, status, result)`, in any order: several requests can be
outstanding at once and a host may answer them as they finish. Binary
request: `u8 version (=1), uvarint function code, fields in order`; JSON
request: `{"plug":"<name>", fields...}`. The result has the reply fields
(binary in order, or a JSON object). Status is a status code from section 3;
for replies that mean "no", use `not_found`, `conflict`, `permission` or
`unsupported` as listed. A notification has tag 0 and takes no reply.

| code | function | request fields | reply fields | deadline |
|---|---|---|---|---|
| 1 | `sealed_store.get` | subject: bytes | record: bytes, entries: [bytes]; `not_found` when no account | 15 s |
| 2 | `sealed_store.put` | subject: bytes, record: bytes, prev_seq: uvarint, seq: uvarint | {}; `conflict` unless the stored seq is prev_seq (0 = none stored) | 15 s |
| 3 | `sealed_store.add` | subject: bytes, entry: bytes | {} | 15 s |
| 4 | `unlock.unlock` | rp_user: bytes, credentials: [bytes], salts: [bytes], mode: enum{local, cross_device} | credential: bytes, prf: bytes (32); `not_found` when none of the credentials is available | 120 s |
| 5 | `unlock.register` | rp_user: bytes, label: str, salt: bytes (32) | credential: bytes, prf: bytes (32), ecosystem: enum | 120 s |
| 7 | `runner_pool.verify` | token: bytes, sign: bytes, box: bytes | lease_ms: uvarint; `permission` for a bad token | 15 s |
| 8 | `runner_pool.attest` | evidence: bytes, sign: bytes, box: bytes | {}; `permission` to refuse | 15 s |
| 15 | `runner_pool.renew` | sign: bytes, box: bytes | lease_ms: uvarint; `permission` when the machine is gone | 15 s |
| 10 | `pool_user.joined` | space: id, name: str, relay: str, relay_key: bytes, proof: bytes | notification | – |
| 12 | `credentials.produce` | space: id, binding: bytes | credential: bytes | 5 s |
| 14 | `scheduler.place` | kind: enum{message, takeover, intent, revive, schedule, channel}, object: object, msg: rid, sender: id, agent: id, provider: str, policy: bytes, exclude: id, prefer: id | runner: id, reference: bool | 30 s |

(Codes 6, 9 and 11 are retired: identities and credential spaces come with the
registration.) `[bytes]` is `uvarint count` then each `bytes` in binary, an
array of hex strings in JSON. `ecosystem`: unknown, apple, google, microsoft,
1password, bitwarden, security_key, recovery, test. In `unlock.unlock` the
i-th salt belongs to the i-th credential; evaluate the PRF of the chosen
credential with its salt (WebAuthn `prf.evalByCredential`), always with user
verification. `register` creates a passkey for `rp_user`, evaluates its PRF
with `salt` and reports the ecosystem it was saved in. The sealed record and
entries are opaque ciphertext and signatures: the store keeps them, enforces
the compare-and-swap on `seq`, and returns the newest record (at most
64 KiB) and every entry (at most 4 MiB in all) in the order they were added.
A put that repeats the stored record exactly must answer `ok` (a flow may be
retried after a restart). `credentials.produce` returns the credential for
one relay connection, bound to `binding` (the relay's challenge); it is never
held for a host to register: with none, the space connects with member
credentials or not at all.

`runner_pool.renew` readmits a runner whose lease lapsed while it slept:
answer the lease to grant (the pool caps it at the runner's enrolled lease)
when the machine is still valid, `permission` otherwise. The runner's side:
on `lease_lapsed` (its lease nears expiry or has lapsed; a runner never renews by itself) it
calls `runner.renewal_request`, passes the request to the pool host's
`pool.renew`, and applies the answer with `runner.renew`; `0ndb runner`
does this through `ONDB_POOL_HOST_SOCK`. The renewal is a pool-signed
lease per space that the relay checks at hello and never stores.

`scheduler.place` asks where a run goes. Answer `runner` (any device or
pool runner), a null `runner` to keep it waiting, or `reference: true` for
the built-in policy. `prefer` is the runner the work last ran on (or the
parent conversation's), and `exclude` a runner it must leave. The runtime
caches the answer per placement and asks again when a runner's presence or
advert changes; the conversation shows `placing` meanwhile. With no host
registered, a failure or the deadline, the built-in policy decides. The
request never blocks the daemon loop, and each device asks its own host, so
a host serving several devices should answer consistently.

Asynchronous end to end. A plug request suspends only the engine flow that
made it (a sign-in, a passkey change, a pool enrollment, one relay
connection's hello); the daemon keeps serving every other client, call,
subscription and link while it is outstanding. Measured with a host that
answers each request after 1.5 s: 300 calls plus a space, a conversation and a
recorded message on another connection completed with p50 0.06 ms and
p99 0.3 to 0.7 ms while the sign-in waited, and the sign-in finished after the
host's three answers (get, register, put) at 4.5 s.

Deadlines, cancellation and reconnect. Each request has the deadline in the
table, counted from when the daemon issues it and covering both waiting for
a host and waiting for its answer. When it passes the daemon sends
`Plug_Cancel(tag)` (if a host has the request) and the flow sees the plug fail:
the client call fails `offline`. A client `Cancel` of the call (or the call's
own timeout, or the daemon stopping) cancels the flow, and the host receives
`Plug_Cancel` at once; a host should abort the work (dismiss the passkey
sheet) and may drop its reply. If the host's connection closes while a request
is outstanding and another host registers before the deadline, the daemon
sends the request to it; `pool_user.joined` notifications made while no host
is registered are queued (the newest 256) and delivered when one registers. A
reply for a tag that is no longer outstanding is ignored. `daemon.status`
reports `host_pending`, the number of outstanding requests.

Restarts. Sign-in flows are idempotent, so a flow cut by a daemon crash is
retried by calling the op again: a record that was stored is found by `get`
and unlocked, one that was not is created anew. Account manifest entries (one
per space the account gains) are kept with the space's own records until the
store confirms them and are offered again on every start and every
`sealed_store` registration, so a space created while the account server is
unreachable reaches the account once it is back, also across crashes.

Identity-provider PRF path. A UI that runs WebAuthn itself (or whose identity
provider evaluates the passkey PRF) does not need the `unlock` plug: it reads
`account.idp_salt(subject)`, evaluates the PRF with that salt, and calls
`account.login_prf(subject, credential, prf, label, relay, relay_key)`;
`account.passkey_add(label, credential, prf)` adds such a passkey to a
signed-in account.

## 9. Live buffers

A live buffer is an editor's view of one text object, or of one file of a
mounted tree, with surgical deltas. Ops are named (their codes come from
`describe`):

| op | arguments | result |
|---|---|---|
| `buffer.open` (a subscription) | object, path: str, line: str, units: enum{bytes, utf16}, actor: id, page: uvarint | the subscription's Result payload is the open BufferEvent |
| `buffer.read` | buffer, rev, from, len | rev, ack, from, length, text |
| `buffer.edit` | buffer, rev, pos: uvarints, del: uvarints, ins: strs, group | ack |
| `buffer.ack` | buffer, rev | {} |
| `buffer.undo`, `buffer.redo` | buffer | done: bool |
| `buffer.anchors` | buffer, rev, positions: uvarints, bias: enum{before, after} | anchors: strs |
| `buffer.resolve` | buffer, anchors: strs, rev | positions: [ivarint] (-1 unknown), rev, ack |
| `buffer.cursors` | buffer, rev, ranges: uvarints (anchor, head pairs) | {} (ephemeral) |
| `buffer.text` | buffer | rev, text |

`BufferEvent := kind: enum{open, delta, cursors, closed}, buffer: uvarint,
rev, ack, length, text, more, actor: id, line: str, ops: [{kind:
enum{retain, delete, insert}, n, text, author: id}], cursors: [{device,
actor, ranges: [{anchor: ivarint, head: ivarint}]}], status`. Every Deltas
frame of the subscription carries one BufferEvent (not a Deltas list).
Unsubscribing closes the buffer.

Positions count `units` (bytes, or UTF-16 code units); text is always valid
UTF-8 widened to whole code points, and an insert's `n` counts units. `open`
returns the first `page` units of text, the full `length`, and `more` when
the rest must be fetched with `buffer.read`.

`buffer.open` waits like a read: when the object's history is not on this
device yet, the Result is sent once it has been fetched, and while the
space's catalog is still catching up it waits for the catalog, so an object
another device just created opens instead of answering `missing`. It answers
`missing` only once the catalog is caught up and nothing is being fetched.

Client rule (Jupiter). Number your edits 1, 2, ... and keep the
unacknowledged ones as deltas. Send each `buffer.edit` with the `rev` of the
last delta you applied; its edits are sorted, non-overlapping, and refer to
your text at that rev plus your earlier edits, so several can be in flight.
On each delta event, drop your edits with seq <= the event's `ack`;
transform the incoming delta over the remaining ones with your edit as the
first argument (your insert goes first at equal positions; deletes of the
same range cancel), apply it, and set `rev`. Positions in cursors events and in
`read`'s `from` are as of the event's or reply's `rev` and `ack`: map them
through your edits with seq > ack. `resolve` takes the `rev` you have
applied and answers in your coordinates at that rev plus every edit you sent
before it, so map its positions through what you applied since you sent it
(later edits and deltas). An edit's result can arrive before delta events the
daemon produced before applying that edit (results are written at once,
buffer events as the connection drains): the result carries `ack` and the
`rev` it reflects, so drop edits with seq <= that ack once you have applied
the delta numbered `rev` (at once if you already have). Without that, a
buffer nobody else edits would keep every edit unacknowledged. A `conflict`
status means reopen. Anchors are strings:
`s`, `e`, or `<actor hex>.<seq>[.<offset>].<b|a>`. Another device's edit can reach the buffer
ahead of its durability (live edits); while one is shown, `buffer.edit`,
`buffer.undo` and `buffer.redo` stay pending until its durable record
arrives (a few milliseconds) and then answer in order, so keep pipelining.
The reference clients are
`LiveBuffer` in `web/0ndb.js` and `ondb::LiveBuffer` in the Rust crate.

## 10. MCP hand-off

`Mcp(space, object)` turns the connection into a stdio MCP session for the
orchestration catalog with the given conversation as the caller: the daemon
answers `Result(0, ok)` with an empty payload, and from then on the bytes in
both directions are MCP JSON-RPC lines, not frames. `0ndb mcp` bridges this
to a harness's stdio.

## 11. Versioning

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
(-1 when no timer is armed), host_plugs: [str] (enabled), host_pending, hosts: [str]
(currently registered), links: [{space, error, reason}]`.

## 12. Op reference

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
| 163 | `subscribe.runners` | space: id, object: object | Runners (whole payload per frame) |
| 143 | `subscribe.fork_diff` | object: object, caller: object, diff: bool, max_chars: uvarint | changes:[Change] diff:str (whole payload per frame) |

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
| 170 | `space.leave` | space: id, device_only: bool | removed:uvarint skipped:uvarint |
| 26 | `space.pool` | space: id, on: bool | {} |
| 27 | `space.join_enrollment` | space: id, proof: bytes, name: str, relay: str, relay_key: bytes | space:id |
| 28 | `account.join_space` | space: id | {} |
| 29 | `pool.enroll` | token: bytes, card: bytes, evidence: bytes | enrollment:bytes |
| 30 | `runner.enroll` | enrollment: bytes | spaces:uvarint |
| 164 | `runner.renewal_request` | – | request:bytes |
| 165 | `pool.renew` | request: bytes | renewal:bytes |
| 166 | `runner.renew` | renewal: bytes | spaces:uvarint |
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
| 60 | `send` | object: object, text: str, parent: rid, role: enum user|assistant|system|tool, provider: str, model: str, attachments: attachments, root: bool | Result |
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
| 73 | `assign` | object: object, msg: rid, runner: id | Result (without `msg`: resume the conversation on `runner`, empty result) |
| 74 | removed (redaction) | | unsupported |
| 124 | `record` | object: object, source: str, external_id: str, sequence: uvarint, role: enum user|assistant|system|tool, parent: rid, blocks: blocks, status: enum open|done|interrupted|failed|cancelled, input: uvarint, output: uvarint, cache_read: uvarint, cache_write: uvarint, provider: str, model: str, native: str | receipt:enum msg:rid |
| 131 | `land` | tree: object, from: str, into: str, dry: bool | landed:bool files:uvarint conflicts:strs |
| 171 | `line.hold` | tree: object, line: str, reason: enum branch_changed|branch_deleted|undo | held:uvarint |
| 172 | `line.resume` | tree: object, line: str | resumed:uvarint |
| 173 | `line.switch` | tree: object, line: str, root: str | line:str held:uvarint |
| 174 | `undo` | object: object, msg: rid | undo:id done:bool (undoes turn `msg` and every task its tree spawned; `done` false while runs are still being held, the runtime finishes it) |
| 175 | `redo` | object: object, undo: id | undo:id done:bool (switches back to the timeline the undo left) |
| 176 | `undo.resume` | object: object | resumed:uvarint (continues the tasks an undo or redo paused; sending in the conversation does the same) |
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
| 82 | removed (redaction) | | unsupported |
| 83 | `text.create` | space: id, title: str, initial: str | object:object |
| 84 | `text.read` | object: object | text:str |
| 85 | `text.spans` | object: object | spans:[Span] |
| 86 | `text.edit` | object: object, pos: uvarint, remove: uvarint, insert: str | Result |
| 87 | removed (redaction) | | unsupported |
| 88 | `tree.create` | space: id, title: str | object:object |
| 89 | `tree.read` | object: object, path: str, line: str, version: bytes | text:str line:str base:bytes |
| 90 | `tree.list` | object: object, path: str, line: str, version: bytes | names:[str] line:str entries:[TreeEntry] base:bytes |
| 91 | `tree.write` | object: object, path: str, text: str, line: str, base: bytes | line:str |
| 92 | `tree.remove` | object: object, path: str, line: str | line:str |
| 93 | `tree.mount` | object: object, root: str | {} |
| 94 | `tree.unmount` | object: object, root: str | {} |
| 95 | `tree.mounts` | – | mounts:[Mounted], refused:[Refused] |
| 96 | `tree.blame` | object: object, path: str, line: str | line:str text:str spans:[BlameSpan] |
| 97 | `tree.sync` | object: object, root: str | {} |
| 98 | `tree.find` | path: str | object:object root:str rel:str |

`tree.read` and `tree.list` read the line's current tree, or with `version`
(the `version` of a `File` from `convo.files_at`) the tree at that version;
a version this device's history does not hold answers `missing`, and bytes
that are not a version answer `invalid`.
`tree.read` and `tree.list` also return `base`, the version they read.
`tree.write` requires a `base` from one of them: the write is the diff from
the file's text at that version to `text`, merged with everything since, so
it never removes what its reader did not see. A path absent at `base` is
created, with any missing parent directories. `tree.write` without a `base`,
or with bytes that are not a version, answers `invalid`; a version this
device's history does not hold answers `invalid` too.
`tree.list` names each child's kind (`file`, `dir`, `symlink`), size in
bytes (a symlink's target length, 0 for a directory) and mode. Listing a
file or reading a directory answers `invalid`.

`send` appends after the read position, or under `parent`; with `root` the
message starts a new root, a sibling of the conversation's first message
(so the first message can be branched). `root` with a `parent` is
`bad_request`.

### Catalog (the session list)

| code | op | arguments | result |
|---|---|---|---|
| 99 | `catalog.get` | object: object | found:bool entry:CatalogEntry |
| 100 | `catalog.list` | space: id, archived: bool, after: bytes, limit: uvarint | rows:[CatalogRow] more:bool next:bytes |
| 141 | `catalog.find` | space: id, text: str | rows:[CatalogRow] |
| 142 | `object.uploaded` | object: object | uploaded:bool dropped:bool |
| 101 | `catalog.usage` | object: object | Usage |
| 102 | `catalog.set` | object: object, set: uvarint, title: str, archived: bool, pinned: bool, parent: object, parent_msg: rid, workspace: id, agent: id, takeover: enum{default,auto,never} | Result |

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
| 160 | `takeover.get` | object: object, level: enum{conversation,agent,workspace} | policy: enum takeover, effective: enum takeover |
| 161 | `takeover.set` | object: object, level: enum{conversation,agent,workspace}, policy: enum{default,auto,never} | {} |

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
| 162 | `runners` | space: id, object: object | runners:[Runner] |

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
| 1009 | `host.register` | plugs: strs, replace: bool, identity: bytes, spaces: ids | plugs:[str] |
