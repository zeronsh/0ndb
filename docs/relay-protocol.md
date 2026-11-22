# 0ndb relay protocol

Version 3 (`PROTOCOL_VERSION`). This document specifies the relay so that it
can be implemented anywhere: our own `0ndb relay`, a Cloudflare Durable
Object per space speaking WebSocket, a few hundred lines of TypeScript, or an
embedder's own service. `DESIGN.md` explains why the system is shaped this
way; this document says exactly what goes over the wire, what a relay must do
with it, and what it must never do. The reference implementation is the
sans-IO core in `src/sync/relay_core.odin` (with `relay_feed.odin`,
`relay_hollow.odin`, `relay_direct.odin`, `relay_revoke.odin`), and
`docs/relay-vectors/` holds byte-exact transcripts any implementation can be
checked against.

All integers are little endian. `id` is a 32-byte stream id, `key` a 32-byte
object key, `dev` a 16-byte device id, `space` a 16-byte space id. `u64`
offsets and lengths are byte counts and never exceed `2^62` unless a frame
says otherwise.

## 1. What a relay is

A relay stores and forwards opaque bytes for spaces. Per space it keeps:

- **segments**: single-writer, append-only byte streams named by `id`. The
  first 16 bytes of an id are the writer's device id; the rest is a keyed hash
  the relay cannot invert. A segment has a `length` and a `base`; the relay
  holds content for exactly `[base, length)` (a fully *hollow* segment has
  `base == length` and stores only its length);
- **objects**: immutable content-addressed blobs named by `key`;
- the **announce feed**: an append-only log of `(id, word)` entries, one per
  change, which is how participants learn what changed;
- the **redaction log**: every redaction ever applied, so feed compaction can
  carry them forward;
- per connection, live state only: follows, feed position, presence, pipes.

A relay **never** holds a key, never decrypts, never alters a stored byte
other than by the redaction zero-fill below, never invents bytes, never
reorders bytes inside a segment, and never interprets record bodies. The
only structure it reads inside stored bytes is the record framing needed to
redact (section 8.4) and the membership records it must verify to authorize
(section 6), which are transparent signed records, not content. A relay can
withhold bytes; readers verify everything (AEAD per record, hash chains,
signatures) and detect a relay that lies.

## 2. Layers

```
WebSocket (optional)  ->  secure channel (or a trusted local stream)  ->  frames
```

### 2.1 Local streams

A Unix socket whose peer has the relay's own uid is a *local* connection:
there is no handshake, the binding is empty and Hello signatures are not
checked (credentials are still parsed and authorized). Embedders may treat
any channel they already trust the same way.

### 2.2 Secure channel

`Noise_IK_25519_ChaChaPoly_BLAKE2b`, prologue `"0ndb relay 1"`. The relay's
static X25519 key is its identity (`relay key`, printed by `0ndb relay key`);
clients pin it.

- The client sends `u16 n | msg1` with `n = 96`; the relay answers
  `u16 n | msg2` with `n = 48`. Any other length closes the connection.
- The **binding** is the 64-byte Noise handshake hash. Hello signatures are
  made over it, so a credential cannot be replayed on another connection.
- After the handshake both directions use TLS 1.3-shaped records protected
  with AES-256-GCM (so Linux kernel TLS can carry them):
  `23 | 3 | 3 | u16 len | ciphertext | tag[16]`, where the plaintext is the
  payload followed by the content type byte 23 and optional zero padding,
  at most 16384 payload bytes per record, `len <= 16384 + 256`. The nonce is
  the 12-byte IV with the big-endian record sequence number XORed into its
  last 8 bytes. Sequence numbers start at 0 per direction.
- Traffic secrets: after `Split()` each Noise cipher state `c` encrypts 44
  zero bytes with nonce `00000000 ffffffffffffffff` and no associated data;
  bytes `[0,32)` are the AES key, `[32,36)` the IV salt and `[36,44)` the IV
  tail (IV = salt ‖ tail). `c1` protects client to relay, `c2` relay to
  client.

### 2.3 WebSocket

A host may accept `ws://` (or terminate `wss://` itself). After the HTTP
Upgrade, binary messages carry the byte stream of 2.2 (handshake, then
records); message boundaries carry no meaning. A host that terminates TLS
itself still runs the Noise handshake inside the WebSocket so the binding
exists; a Hello without a binding is only accepted on a local stream.

## 3. Frames

```
frame := len u32 | kind u8 | payload[len]
```

`len` counts the payload only. Control frames carry at most 65536 payload
bytes (`CONTROL_MAX`). Bulk frames have a fixed part followed by content:

| kind | fixed | content limit |
|---|---|---|
| Append (client) | 40 | `APPEND_MAX` = 64 MiB + 24 |
| Fill (client) | 40 | `APPEND_MAX` |
| Put (client) | 32 | `OBJECT_MAX` = 2^32 - 65 |
| Serve (client) | 64 | `SERVE_MAX` = 256 KiB |
| Live (client) | 48 | `LIVE_MAX` = 256 KiB |
| Data (relay) | 48 | `OBJECT_MAX` (a relay sends at most `DATA_MAX` = 4 MiB) |
| Object (relay) | 32 | `OBJECT_MAX` |
| Served (relay) | 64 | `SERVE_MAX` |
| Lived (relay) | 48 | `LIVE_MAX` |

A relay rejects a client frame whose kind is not a client kind, whose `len`
is smaller than its fixed part (`Protocol`) or whose content exceeds the
limit (`Too_Large`). Frames are never interleaved: a relay writes each frame
contiguously, and a client writes each request contiguously. A frame may be
split across any number of transport reads.

### 3.1 Kinds

| kind | code | | kind | code |
|---|---|---|---|---|
| Hello | 0x01 | | Welcome | 0x81 |
| List | 0x02 | | Listing | 0x82 |
| Append | 0x03 | | Appended | 0x83 |
| Read | 0x04 | | Conflict | 0x84 |
| Tail | 0x05 | | Data | 0x85 |
| Follow | 0x06 | | Stored | 0x86 |
| Unfollow | 0x07 | | Object | 0x87 |
| Put | 0x08 | | Missing | 0x88 |
| Get | 0x09 | | Length | 0x89 |
| Drop | 0x0a | | Created | 0x8a |
| Redact | 0x0b | | Dropped | 0x8b |
| Feed | 0x0c | | Refused | 0x8c |
| Forget | 0x0d | | Error | 0x8d |
| Probe | 0x0e | | Redacted | 0x8e |
| Direct | 0x10 | | Announce | 0x8f |
| Note | 0x11 | | Forgotten | 0x90 |
| Fill | 0x12 | | Probed | 0x91 |
| Pull | 0x13 | | Presence | 0x92 |
| Serve | 0x14 | | Directed | 0x93 |
| Account | 0x15 | | Undelivered | 0x94 |
| Live | 0x17 | | Noted | 0x95 |
| | | | Hollow | 0x96 |
| | | | Pulled | 0x97 |
| | | | Served | 0x98 |
| | | | Unserved | 0x99 |
| | | | Accounted | 0x9a |
| | | | Lived | 0x9b |

### 3.2 Codes

`Refused` (per request, connection stays) and `Error` (fatal) carry a code:

| code | name | meaning |
|---|---|---|
| 1 | Protocol | malformed frame, frame in the wrong state |
| 2 | Auth | credential rejected, or the principal stopped being active |
| 3 | Version | Hello version is not 3 |
| 4 | Quota | the space's quota would be exceeded |
| 5 | Not_Owner | the principal lacks the access the request needs |
| 6 | Too_Large | a frame's content exceeds its limit |
| 7 | Io | storage failed, or a redaction range is misaligned |
| 8 | Busy | the segment has a write in flight |
| 9 | Limit | a connection, follow or pipe limit |
| 10 | Not_Found | Fill on a segment the relay does not have |

```
Refused := code u8 | id[32]       (the stream id, object key, or a reserved id)
Error   := code u8
```

After sending `Error` the relay closes the connection and ignores every byte
the client sent after the offending frame, including the rest of the same
delivery.

## 4. Connection

```
            Hello ok                 Error (any cause)
  [Hello] -----------> [Ready] ---------------------> [Closed]
     |  anything else: Error Protocol
     |  no Hello within the host's timeout (reference: 10 s): closed
```

### 4.1 Hello

```
Hello   := version u8 (= 3) | credential[<= 8192]
Welcome := version u8 | wall_ns u64 | usage u64 | quota u64 | features u64
```

`usage` is the bytes the relay stores for the space, `quota` its quota (0 =
unlimited), `wall_ns` the relay's clock. `features` is a bit set of optional
frames this relay supports; clients must ignore unknown bits and may ignore
trailing bytes after the fields they know (a version-3 Welcome from an older
relay is 25 bytes and has no `features`).

| bit | feature |
|---|---|
| 0 | `Account` / `Accounted` (section 8.13) |
| 1 | `Trim` (section 8.14) |
| 2 | reads below a trimmed `base`: `Trimmed` (section 8.14) |
| 3 | live drafts: `Live` / `Lived`, `Follow` flag LIVE, draft pulls (section 8.16) |

The signature in every built-in credential is Ed25519 over the **hello
message** `"0ndb hello 1" ‖ 00 00 00 00 ‖ B`, where `B` is the 64-byte binding,
or BLAKE2b-512 of the binding if it is not 64 bytes.

### 4.2 Credentials

The first byte selects the type.

```
member  := 4 | space[16] | sign[32] | sig[64] | uvarint n (<= 8) | (uvarint len | proof)*
request := 5 | account[32] | sign[32] | sig[64]
account := 6 | account[32] | cert[64] | sign[32] | sig[64]
cert    = Ed25519(account, "0ndb device cert\0" ‖ sign)
```

Any other type goes to the embedder authorizer (section 6.3). The reference
consumer uses type 2 for third-party capability tokens. The device id of a
principal is `BLAKE2b-512(sign)[:16]`.

A relay answers a rejected Hello with `Error Auth`, a wrong version with
`Error Version`, an empty or oversized Hello with `Error Protocol`, and a
principal over its connection limit with `Error Limit`.

## 5. The principal

A successful Hello binds the connection to a principal: a namespace (space
id), a participant (device id), a quota, and an access predicate checked live
on every request. Access kinds: `List` (the feed, listings, presence, direct
messages), `Read`, `Append` and `Drop` (own segments only: the id's first 16
bytes equal the participant), `Fill`, `Redact`, `Put`, `Get`, `Forget`.

Ids whose first 16 bytes are all `0xff` are **reserved** for the relay's own
streams (feed, feed meta, redaction log, host-private streams). No access
predicate ever grants them; requests naming them are refused with
`Not_Owner`.

## 6. Authorization

Authorization derives only from the space's signed membership log, which the
relay verifies itself, plus an optional embedder authorizer. It never trusts
an unsigned claim.

### 6.1 The membership log

Each member writes a transparent single-writer segment `members`:

```
members id = device ‖ BLAKE2b-MAC(key = BLAKE2b-256("0ndb members name" ‖ space),
                                  msg = u64 0 ‖ "members")[:16]
```

Its bytes are journal records (section 8.4 framing) whose bodies are member
records:

```
MEMBER_RECORD(0x4d) | version 1 | op u8 | space[16] | author sign[32]
| lamport uvarint | nparents uvarint (<= 64) | parents[32]* | time_ms u64
| payload bytes | sig[64]
id  = BLAKE2b-256("0ndb member id" ‖ whole record)
sig = Ed25519(author, "0ndb member v1\0" ‖ record without sig)
space id = BLAKE2b-128("0ndb space" ‖ genesis id) with id[6] = id[6] & 0x0f | 0x80
```

`DESIGN.md` (Membership and key epochs) defines the ops, the bodies and the
resolution function; it is a pure function of the record set, so the relay
computes exactly the roster every device computes. In summary: records apply
in topological order once all parents are present; an author must be active
at the record's position; owners add and remove anyone, admins anything but
owners, members add devices and guests, pools add lease-bound runners; a
record by X is void unless it is in the causal past of X's removal (removal
wins); expiry and leases are wall-clock checks.

### 6.2 Member principals

On a `member` Hello the relay:

1. verifies the signature over the binding (skipped on a local stream);
2. checks the space is admitted (open mode, or listed in the allow list with
   an optional quota);
3. ingests each proof that is admissible: the space's genesis if the relay has
   no record yet for the space (its id must derive the space id), or a record
   for this space whose author is an active member. Inadmissible proofs are
   ignored, not fatal;
4. accepts if the signing key belongs to an active member of the resolved
   roster.

It then grants: `List`, `Read`, `Get` to every active member; `Append`,
`Drop` on own segments, and `Put`, `Forget`, `Fill`, `Redact`, to every
active member whose role is not `reader`.

When an `Append` to any members segment becomes durable, the relay ingests
the new records (at most 1 MiB per append is inspected) and resolves again.
Every connection whose principal is no longer active receives `Error Auth`
and is closed. A later Hello by that principal is refused. Because the access
predicate is evaluated live, a principal that lapses by expiry is refused at
its next request even before any record arrives.

The relay keeps the record set per space as a derived cache and reconciles it
against the members segments in its storage when the space is loaded, so the
log in storage is the source of truth; an implementation without a cache
(for example a Durable Object) simply reconciles from storage.

### 6.3 Account namespace

`request` and `account` principals live in the namespace
`BLAKE2b-128("0ndb account namespace" ‖ account)` with `id[6] = id[6] & 0x0f
| 0x80`. They may only use `List` with the zero id: follow presence and send
and receive direct messages; every other request is refused `Not_Owner`. A
`request` principal (a device asking to be approved) may hold at most 2
connections. `account` principals must present a valid device cert.

### 6.4 Embedder authorizer

An embedder may supply an authorizer for credential types the relay does not
know. It maps `(credential, binding, local)` to a principal or a code. The
relay enforces whatever access the principal carries and nothing more. The
vector `embedder.json` uses a stub type `0x7e | space | dev | flags` (bit 0
read, bit 1 own appends, bit 2 objects) to pin down this contract.

## 7. Storage model and durability

### 7.1 What an acknowledgement means

`Appended`, `Noted` (for a Note or a successful Fill), `Stored`, `Dropped`,
`Redacted` and `Forgotten` are sent only after the change is **durable in the
host's durable buffer**: it survives a crash of the relay process and of the
machine. For the reference relay that is a group-committed pack fsync; for a
Durable Object it is Durable Object storage; for a relay that tiers to an
object store it is still the local buffer, and the object-store flush happens
later, coalesced, invisible to the protocol (section 11). An implementation
must never acknowledge a write that can be lost.

For appends, drops, notes and redactions the feed entry is part of the
change: the acknowledgement is sent only after both the change and its feed
entry are durable.

### 7.2 Ordering

- Per segment, appends are applied strictly at `length`; one write per
  segment is in flight at a time (another write meanwhile is `Busy` or a
  `Conflict`). Acknowledgements for one segment arrive in order.
- Bytes of a segment reach followers in offset order, only once durable.
- On one connection, replies that need no storage (`Conflict`, `Refused`,
  `Data` for reads, `Length`, `Probed`, `Listing`, `Object`/`Missing`,
  `Undelivered`, `Noted` for no-op notes) are sent in request order.
  Acknowledgements of durable writes are sent when each write completes, so
  they may overtake or trail other replies; clients match them by id.
- `Hollow` for a segment always precedes the `Probed`, `Length` or `Data`
  that mentions it.
- A Feed reply sends the presence snapshot (if requested) before its first
  `Announce`.

### 7.3 Segments, base and hollow storage

A segment is created by an `Append` at offset 0 or by a `Note`. Its content
is the suffix `[base, length)`. `Note` advances a fully hollow segment's
length without content; `Fill` stores content backward ending exactly at
`base`; `Append` extends at `length`. Offsets are the writer's, so a record
id `(segment, offset)` is identical everywhere. The relay never serves bytes
below `base`.

## 8. Requests

Each subsection gives the request, the checks in order, and the replies.

### 8.1 Append (0x03, bulk)

```
Append   := id | at u64 | bytes
Appended := id | length u64
Conflict := id | length u64
Created  := id | length u64        (to watchers)
```

1. `Append` access on `id`, else `Refused Not_Owner`.
2. If quota > 0 and `usage + in-flight + n > quota`: `Refused Quota`.
3. If the segment does not exist and `at > 0`, or the segment is busy,
   dropped, or `at != length`: `Conflict(id, length)`. If `at < length` the
   relay also appends the feed entry `(id, length)` again, so a client that
   lost track re-learns the length through the feed.
4. `n == 0` and `at == length`: `Appended(id, length)` at once.
5. Otherwise the bytes are written; once durable and logged in the feed:
   `Appended(id, new length)` to the writer, `Data` to every follower, and
   `Created(id, length)` to every watcher with `Read` access if the segment was
   empty.

The bulk content is always consumed, even when the request is refused; the
reply follows the end of the frame.

### 8.2 Read (0x04), Tail (0x05)

```
Read := id | from u64 | to u64
Tail := id | n u64
Data := id | at u64 | word u64 | bytes      word = length | FINAL (bit 63)
```

`Read` access, else `Refused Not_Owner`. `Tail` reads `[max(length - n, 0),
length)`. `Read` clamps `to` to `max(length, from)`; `to < from` reads
nothing. For a based segment the relay first sends `Hollow` (`Trimmed` if the
base is a trim, section 8.14) and raises `from` to `base`. The answer is one or more `Data` frames of at most 4 MiB
covering the range in order; the last carries `FINAL`. A read entirely past
the end answers one empty `Data` at `from` with `FINAL`. `length` in each
frame is the segment's current length, or the end of the frame's bytes if
that is larger (a segment dropped while being read). A segment that does not
exist reads as empty with length 0.

### 8.3 Follow (0x06), Unfollow (0x07)

```
Follow   := flags u8 | count u16 (<= 1024) | (id | offset u64)*     flags bit 0: watch, bit 1: LIVE
Length   := count u16 | (id | length u64)*
Unfollow := count u16 | id*
```

Per entry: `Read` access (else `Refused Not_Owner`), follow limit (16384 per
connection, else `Refused Limit`), `Hollow` (or `Trimmed`) if based. `offset = 2^64 - 1`
means "from the current end". Following an already-followed segment moves its
offset. The relay then sends one `Length` for the accepted entries and pushes
`Data` (without `FINAL`) from each offset as bytes become durable, round
robin across segments in chunks of at most 4 MiB. With the watch flag the
connection also receives `Created` for every new segment it can read.
`Unfollow` stops pushes; it has no reply and leaves live interest (section
8.16) alone. A count that does not match the payload is `Error Protocol`.
A Follow with the LIVE flag (feature bit 3) is handled entirely by section
8.16 and reads no storage.

### 8.4 Redact (0x0b)

```
Redact   := id | from u64 | to u64            from <= to <= 2^62
Redacted := id | from u64 | to u64
```

`Redact` access, else `Refused Not_Owner` (reserved ids are always refused).
If the segment does not exist or the range is empty: `Redacted` at once.
Otherwise the relay clamps the range to `[base, length)` and redacts every
record inside it. Records are framed as

```
record := len u32 | tag[16] | body[len] | len u32
```

Every record in the clamped range must start and end inside it with matching
lengths; if not, nothing changes and the answer is `Refused Io`. Each record's
body is zero-filled and its tag replaced by

```
tag = "0ndb-rdx" ‖ u64(XXH3_64(u32 len ‖ "0ndb-rdx", seed = offset XOR 0x726564616374))
```

Lengths and offsets do not change. Once durable, the range (as requested) is
appended to the redaction log and to the feed as two entries `(id, REDACT |
from)` and `(id, REDACT | REDACT_END | to)`, then the writer gets `Redacted`.
Redaction is idempotent.

### 8.5 Drop (0x0a)

`Drop := id`, `Dropped := id`. `Drop` access, else `Refused Not_Owner`;
`Refused Busy` while a write is in flight. Once the segment is removed and the
feed entry `(id, 2^64 - 1)` is durable, the writer gets `Dropped`; every
follower and every watcher with `Read` access gets one `Dropped` each (a
follower that also watches gets one), and follows of it end.

### 8.6 Objects: Put (0x08), Get (0x09), Forget (0x0d)

```
Put       := key | bytes                     Stored    := key
Get       := count u16 (<= 1024) | key*      Object    := key | bytes   Missing := key
Forget    := count u16 (<= 1024) | key*      Forgotten := key
```

`Put` needs `Put` access and quota; an existing key answers `Stored` at once
(dedup); otherwise `Stored` once durable. `Get` answers each key in order
with `Object` or `Missing` (or `Refused Not_Owner`). `Forget` answers each
key with `Forgotten` once removed.

### 8.7 The announce feed: Feed (0x0c)

```
Feed     := from u64 [ | flags u8 [ | count u16 | pattern* ] ]
pattern  := 1 prefix[16] | 2 suffix[16] | 3 exact[32]
Announce := from u64 | next u64 | count u16 (<= 1500) | (id | word u64)*
flags: 1 FILTERED, 2 ADD, 4 PRESENCE
word:  length, or length | HOLLOW (bit 61), or REDACT (bit 63) | from,
       or REDACT | REDACT_END (bit 62) | to, or 2^64 - 1 (dropped)
```

Feed offsets are byte offsets into a virtual log of 40-byte entries that only
grows (compaction moves its start, section 8.8). `from` is rounded down to an
entry boundary, raised to the current start, and `from = 2^64 - 1` or any
value past the end means "the end". The relay registers the connection as a
feed follower, sends the presence snapshot if PRESENCE is set and the
principal has `List`, then `Announce(off, off, 0)`, then the entries from
`off` in batches of at most 1500. It keeps pushing new entries as they become
durable.

The connection only sees entries for segments it may `Read`, never reserved
ids, and, if FILTERED, only ids matching one of its patterns (redaction
entries pass the pattern filter but still need `Read`). `from` and `next` of
each Announce are the feed positions it covers, so a client resumes from the
last `next`; after skipping more than 960000 bytes of entries it cannot see,
the relay sends an empty Announce to advance the client. A redaction start
entry is never sent without its end entry.

FILTERED without ADD replaces the pattern set and restarts at `from`;
FILTERED with ADD adds patterns to a running feed without restarting (at
most 16384 patterns per connection, 1900 per frame).

### 8.8 Feed compaction

The relay may fold the feed at any time. The reference relay folds when the
feed reaches twice its size right after the previous fold, and at least
64 KiB (`feed_compact`), so the feed stays proportional to the live segment
set and each entry is copied a bounded number of times. To fold, it writes a new
feed holding one entry per live segment (with HOLLOW for hollow ones), then
every redaction log entry as a pair, then the tail written meanwhile, and
switches. The new start is the old end, so offsets keep growing. Followers
that were at the old end continue at the new end (the snapshot holds nothing
they lack); followers behind continue at the new start; a later `Feed` with a
`from` before the start begins at the start. The next Announce's `from` may
therefore exceed the client's last `next`; clients must accept that.

### 8.9 List (0x02)

```
List    := since u64
Listing := cursor u64 | more u8 | count u16 | (id | length u64)*
```

Needs `List` (else `Refused Not_Owner` with reserved id tag 3). Scans the feed
from `since` (rounded and clamped as for Feed) to the current end, newest
first, and returns each readable, non-empty segment once with its current
length, in frames of at most 1500 entries; the last has `more = 0`. `cursor`
is the feed end at the time of the request; a client lists again from it.
While a listing is being sent the relay reads no further requests from that
connection.

### 8.10 Probe (0x0e)

```
Probe  := count u16 (<= 1024) | id*
Probed := count u16 | (id | length u64)*
```

Per id: the feed id `ffff..ff 01 00..00` answers the feed end (needs `List`);
an id without `Read` access answers length 0; otherwise the current length,
preceded by `Hollow(id, base, length)` if `base > 0` (`Trimmed` with the same
fields if the base is a trim). A storage error for one
id answers `Refused Io` for it and omits it.

### 8.11 Device-only segments: Note (0x11), Fill (0x12), Hollow

```
Note   := id | length u64            (length <= 2^62)
Fill   := id | at u64 | bytes        (bulk)
Noted  := id | base u64 | length u64
Hollow := id | base u64 | length u64
```

`Note` needs `Append`. If the segment is new or fully hollow and `length`
exceeds its length, the relay persists `base = length = length`, appends the
feed entry `(id, length | HOLLOW)`, then answers `Noted` and sends `Hollow` to
the other followers. Otherwise nothing changes and `Noted` shows the current
`base` and `length` (so a writer whose segment was filled learns
`base < length` and switches to appends). `Busy` while a write is in flight.

`Fill` needs `Fill` and quota. A segment the relay does not have is `Refused
Not_Found`; `Busy` while a write is in flight. If `at + n != base`, or the
base is a trim (section 8.14), the relay stores nothing and answers `Noted` with the current `base` so the uploader
resumes from there. Otherwise, once durable, `base = at` and the filler gets
`Noted`.

### 8.12 Peer pipes: Pull (0x13), Serve (0x14)

```
Pull     := holder dev | tag u64 | id | from u64 | to u64
Pulled   := requester dev | tag u64 | id | from u64 | to u64
Serve    := requester dev | tag u64 | id | at u64 | word u64 | bytes (<= 256 KiB)
Served   := holder dev | tag u64 | id | at u64 | word u64 | bytes
Unserved := holder dev | tag u64 | id
word: bit 63 FINAL, bit 62 NONE (no bytes), low 62 bits the holder's length
```

A reader that needs bytes below `base` pulls them from a device that holds
them. `Pull` needs `Read` on `id`. The relay answers `Unserved` at once if
the holder has no ready connection in the space, the holder is the requester,
the requester already has 64 open pipes, or the tag is already open for this
requester. Otherwise it records the pipe `(requester connection, tag,
holder connection, id)` and sends `Pulled` to one ready connection of the
holder.

A `Serve` is forwarded unchanged as `Served` only if it matches an open pipe
from this holder connection (requester, tag and id); unmatched frames are
dropped silently. FINAL closes the pipe after forwarding; NONE closes it and
answers `Unserved` instead (NONE with bytes is `Error Protocol`). If the holder
disconnects, every pipe it serves answers `Unserved`; if the requester
disconnects its pipes close silently. The relay buffers at most one frame per
pipe and stops reading a holder while its requester has more than 1 MiB of
served bytes queued. The relay never stores piped bytes.

With feature bit 3, a `Pull` whose `from` has bit 63 (`DRAFT`) set is a
**draft pull**: `from = DRAFT | msg` with `msg < 2^62` names the live draft
of the message record at offset `msg` of segment `id`, and `to < 2^62` is
the first draft offset the requester lacks. The relay applies exactly the
checks above (Read on `id`, holder, pipe limits, tags) and never interprets
the range; the holder answers with `Serve` frames whose `at` is a draft
offset (at or after `to`) and whose length word is the holder's draft
length, or with NONE when it holds no draft for the message. Any other
`from` above `2^63 - 1`, or a draft pull with `msg` or `to` at or past
`2^62`, is `Error Protocol`.

### 8.13 Account (0x15, feature bit 0)

```
Account   := (empty)
Accounted := stored u64 | quota u64 | appends u64 | bytes_in u64 | notes u64
           | fills u64 | pulls u64 | piped u64 | store_writes u64
           | store_bytes u64 | pending u64 | day u64 | day_bytes u64 | total_bytes u64
```

Needs `List` (else `Refused Not_Owner` with reserved id tag 5); a payload is
`Error Protocol`. `stored` and `quota` are as in Welcome; `appends` through
`piped` count since the relay loaded the space; `store_*` count the host's
object-store tier (zero without one): writes, bytes written, and bytes
accepted but not yet flushed; `day` is UTC days since 1970 and `day_bytes`
the client bytes accepted that day; `total_bytes` all client bytes accepted.
Clients send it only on demand (the C API's `space.relay_account`).

### 8.14 Trim (0x16, feature bit 1) and Trimmed (feature bit 2)

```
Trim    := id | base u64            (base <= 2^62)
Trimmed := id | base u64 | length u64
```

A writer that has archived a prefix `[0, base)` of its segment into its own
archive stream (`DESIGN.md`, Segment archives) drops the stored copy of that
prefix with `Trim`. Checks in order: `Append` access on `id` (own segments
only), else `Refused Not_Owner`; a segment the relay does not have, or a
dropped one, is `Refused Not_Found`; `Busy` while a write is in flight; a
`base` at or past the length is `Refused Protocol` (a trim always leaves at
least one byte stored, so a trimmed segment never looks device-only); a
`base` at or below the current base changes nothing and answers `Noted` at
once (trim never lowers `base`, and repeating one is harmless). Otherwise the
relay raises `base`, marks the base as a trim, frees `[old base, base)` and,
once durable, answers `Noted(id, base, length)`. Usage drops by the freed
bytes. Trim appends no feed entry: no follower holds less afterwards, and a
new feed word would be read as a length by version-3 clients.

The relay never reads the trimmed bytes again. Wherever it would send `Hollow`
for a segment whose base is a trim (before `Data`, `Length` and `Probed`), it
sends `Trimmed` with the same fields instead, telling the reader that an
archive covers `[0, base)` and that it reads those offsets from the writer's
archive stream rather than from peers. `Fill` below a trim stores nothing and
answers `Noted` with the current base. Redaction clamps to the stored suffix
as before; the redactor removes archived copies itself (`DESIGN.md`,
Restore).

### 8.15 Presence and direct messages

```
Presence    := flags u8 (bit 0 snapshot) | count u16 | (dev | up u8 | since u64)*
Direct      := to dev | tag u64 | payload (<= 65507)
Directed    := from dev | tag u64 | payload
Undelivered := to dev | tag u64
```

A device is present while it has at least one ready connection in the space.
Feed followers with the PRESENCE flag and `List` access get a snapshot (all
present devices, sorted by device id, `up = 1`) and then one entry whenever a
device's first connection opens or last connection closes. `since` is the
relay's monotonic clock in nanoseconds when the device came up or went down.

`Direct` needs `List`. The relay delivers it as `Directed` to one connection
of `to` that follows the feed with PRESENCE, or answers `Undelivered` at once.
It keeps no state and never reads the payload, which endpoints encrypt end to
end (sign-in approvals and cross-device search use it).

### 8.16 Live drafts: Live (0x17), Lived (0x9b), feature bit 3

```
Follow (LIVE) := 2 | count u16 (<= 1024) | (id | offset u64)*     offset 2^64 - 1 removes
Live          := id | msg u64 | at u64 | bytes (<= 256 KiB)       (bulk)
Lived         := id | msg u64 | at u64 | bytes                    (bulk)
```

A draft is the live preview of a message that a segment's writer is still
streaming. It is never stored: the relay forwards it, keeps no copy, writes
nothing, appends no feed entry and acknowledges nothing.

- `Follow` with flag LIVE registers *live interest* in each id whose offset
  is not `2^64 - 1`: `Read` access, else `Refused Not_Owner`; the follow
  limit counts live interests together with follows, else `Refused Limit`.
  A repeated id is registered once. An entry with offset `2^64 - 1` removes
  the live interest instead. There is no `Length` reply and no storage
  read; the watch flag is ignored. Live interest ends only through such an
  entry or when the connection closes: `Unfollow` concerns read follows,
  which a client manages independently (a reader's replicator unfollows a
  segment it no longer reads while a live view of it stays open).
- `Live` needs `Append` access on `id` (the writer's own segment), else the
  content is consumed and the answer is `Refused Not_Owner`. `msg` and `at`
  must be below `2^62`, else `Error Protocol`. The relay sends `Lived` with
  the identical payload, at once, to every other ready connection with live
  interest in `id` that still has `Read` access, skipping any connection
  with 128 or more queued outputs (a dropped `Lived` is recovered by the
  reader with a draft pull). Nothing else happens: `Live` with no live
  followers is a no-op.

The bytes are journal records (section 8.4 framing) of the writer's draft
for message `msg`, starting at draft offset `at`, sealed end to end exactly
like segment records but under a per-message draft key, with nonce = draft
offset. A writer sends only bytes that are durable in its local draft, so a
draft offset never carries two different ciphertexts. Readers detect a gap
(`at` beyond what they hold) and fetch it with a draft pull (section 8.12)
from the segment's writer, the device in the first 16 bytes of `id`.

## 9. Flow control

A relay stops reading a connection while it has 32 durable writes in flight,
256 queued outputs, a listing in progress, or a pipe over its high-water
mark, and resumes when that clears. Clients must keep reading replies while
they write. Followed data is produced only when the output queue is empty,
so a slow reader slows only itself.

## 10. Limits

| limit | value |
|---|---|
| control payload | 65536 |
| credential | 8192 bytes, 8 proofs |
| append / fill content | 64 MiB + 24 |
| object | 2^32 - 65 |
| Data frame from the relay | 4 MiB |
| ids per Follow, Probe, Unfollow, Get, Forget | 1024 |
| entries per Announce, Listing | 1500 |
| feed patterns | 16384 per connection, 1900 per frame |
| follows per connection | 16384 (reference default) |
| connections per principal | 1024 (reference default), 2 for request principals |
| connections per space | 4096 (reference default) |
| pipes per requester | 64 |
| serve frame | 256 KiB; requester high water 1 MiB |
| live frame | 256 KiB; skipped for a follower with 128 queued outputs |
| direct payload | 65507 |
| membership bytes inspected per append | 1 MiB |
| Hello timeout | host-defined, reference 10 s |

Hosts may lower the reference defaults; vectors state the values they use.

## 11. Hosts and the sans-IO core

The reference relay is a pure state machine, `Relay_Core`
(`src/sync/relay_core.odin`). It builds for every native target and for
`js_wasm32`. Its inputs are:

- `relay_core_attach(link, local, binding)`: a connection whose transport and
  handshake the host already ran;
- `relay_core_input(ref, bytes)` (push) or `relay_core_readable(ref)` (the core
  pulls through `link.recv`), `relay_core_writable(ref)`,
  `relay_core_detach(ref)`;
- storage completions (`Storage_Done` callbacks);
- `relay_core_resume()`, after the core asked for a wake to continue
  feed compaction in slices;
- the `Clock` plug.

Its outputs are bytes through `link.send`, `link.close`, `link.pause`, storage
calls through `Relay_Storage`, and `wake`. It opens no socket, owns no loop
and arms no timer. `link.sendfile` and `Relay_Storage.stream_extent` are an
optional zero-copy path used only when both exist; the correctness path is
`stream_read` into `link.send`. Hosts call the core from one thread and free
`context.temp_allocator` after each call.

`Relay_Storage` reads (`stream_open`, `stream_read`, `stream_probe`,
`object_open`, `list_*`) are synchronous; writes (`append_commit`, `note`,
`fill`, `redact`, `trim`, `drop`, `put_commit`, `object_remove`) complete through a
callback that may run later, and the core acknowledges only then. A Durable
Object implements reads with its synchronous SQLite storage and completes
writes when the storage transaction commits; `Mem_Store`
(`src/sync/store_mem.odin`) is the in-memory reference.

Hosts own: transports, the Noise handshake, WebSocket upgrade, the Hello
timeout, per-source rate limits, the allow list, storage, and any object-store
tiering. `0ndb relay` (`src/sync/relay.odin`) is the socket host: epoll or
kqueue, kernel TLS where available, `sendfile` from the pack, group commit.
With `--objects DIR` it puts the tiered store (`store_tiered.odin`) between the
core and the pack: acknowledgements still mean durable in the local pack,
and each space's changes go to the object store as one batch object per
`--flush-ms` window (default 2000) or every `--flush-mb` MiB (default 8),
whichever comes first. A per-space manifest in the pack records a `DIRTY`
mark in the same group commit as the first change of a window and what each
batch flushed, so a crash never loses an acknowledged change from the object
tier (a dirty space is rescanned on start); a redaction rewrites the earlier
batch objects that hold the range. Idle, nothing is armed.

## 12. Conformance vectors

`docs/relay-vectors/*.json` are produced by `tools/relayvec` (`relayvec
write DIR`) and checked by `relayvec check DIR` natively, or under wasm
(`odin build tools/relayvec -target:js_wasm32`, then
`node tools/relayvec/run_wasm.mjs relayvec.wasm`). Each vector is:

```
{ "format": "0ndb relay vectors 1", "name", "summary",
  "config": { wall_ms, mono_ms, open, quota, feed_compact, max_follows,
              principal_conns, max_space_conns },
  "steps": [ { "step": "connect" | "send" | "durable" | "close" | "clock",
               "conn", "local", "binding", "bytes", "wall_ms", "mono_ms",
               "out":    { conn: [ { "kind", "frame" } ] },
               "closed": [ conn ],
               "store":  [ { op, space, id, at, len, result } ] } ],
  "state": { space: { "streams": { id: { base, length, sha256 } },
                      "objects": { key: { size, sha256 } } } } }
```

The harness model: `connect` attaches a connection with the given binding;
`send` delivers bytes; `durable` completes every outstanding storage write
in issue order until none remain (so acknowledgements appear only in
`durable` steps); `close` is a client disconnect; `clock` sets both clocks.
After each step the implementation must have emitted exactly the listed
frames per connection, byte for byte and in order, and closed exactly the
listed connections. `store` lists the logical storage effects on segments
and objects (not the relay's own reserved streams) completed in that step,
and `state` the final content. Member credentials are built from fixed seeds,
so signatures are deterministic. A conforming implementation exposes its
storage completion as an input, which every sans-IO relay does.

| vector | covers |
|---|---|
| hello | Welcome; Error Version, Auth (binding, unknown type, non-member, inadmissible proof), Protocol (frame before Hello, empty Hello); local streams skip signatures |
| append | ack only after durable; Conflict and feed re-announce; zero-length append; Not_Owner; Read, Tail, read past the end, missing segment; frames split across deliveries; two requests in one delivery |
| quota | Refused Quota counting in-flight reservations; Put within and over quota; Account and Accounted; Account with a payload |
| follow | Follow with watch, Length, live Data, Created, FOLLOW_END, Unfollow, reserved ids |
| feed | Feed from 0, live Announce, aligned and unaligned resume, past the end, exact filter, additive prefix filter |
| list | Listing newest first, once per segment, from 0 and from a later position |
| probe | Probed for a segment, an unknown id, a hollow segment (with Hollow) and the feed |
| objects | Put, dedup Put, Get with Object and Missing, reader refusals, Forget |
| drop | Busy while writing, Not_Owner, Dropped to the owner after the feed entry, once to a follower that also watches, FEED_DROPPED in the feed |
| redact | reader refusal, misaligned range refused with no change, zero-fill with tag, redaction pair in the feed, missing segment |
| hollow | Note, Noted, Hollow to followers and readers, Fill by a member, mismatched Fill, reader refusal, Append after the stored suffix, Note on stored content, Fill on a missing segment |
| trim | Trim by the owner acknowledged once durable, member and reader refusals, repeated and lower bases, base at the length refused, Trimmed before Data, Probed and Length, Fill below a trim, appends after a trim, redaction clamped to the stored suffix, missing segment |
| pipe | Pull, Pulled, Serve, Served, FINAL, NONE, closed pipe, absent and self holders, duplicate tag, wrong requester, holder disconnect |
| presence | snapshot, up and down per device across connections, Direct, Undelivered |
| membership | Add appended to a members segment admits; a non-member's proof is ignored; a Remove revokes the live connection and later Hellos |
| account | request and account principals: no reads, presence, direct messages both ways, 2-connection limit, broken cert |
| embedder | embedder authorizer principals with read-only and own-append access |
| malformed | oversize control frame, unknown kind, relay kind from a client, short payload, count mismatches, inverted Redact, short bulk header, NONE with bytes, oversize Direct, second Hello, Note beyond 2^62; bytes after the Error ignored; Read with to < from |
| compaction | feed folding with a redaction, followers jumping to the new end, a late reader starting at the new start, Listing after compaction |
| limits | per-principal connection limit, per-connection follow limit |
| live | LIVE follows without Length or storage, Live forwarded unstored to live followers only, a repeated id registered once, Refused for a non-owner, Unfollow leaving live interest, removal by a LIVE entry with offset 2^64 - 1, draft pulls answered through the pipe and with NONE, live interest dropped on close, Error for `msg >= 2^62` |

## 13. Extensions

New frames are additive and gated by a Welcome feature bit; a client never
sends a frame the relay did not advertise, and a relay answers an unknown
kind with `Error Protocol`. A relay sends a new relay kind only about state a
client of that feature created (a `Trimmed` only for segments a writer
trimmed). Assigned so far:

| bit | client kinds | relay kinds | other |
|---|---|---|---|
| 1 | `Trim` 0x16 | | |
| 2 | | `Trimmed` 0x9c | |
| 3 (live drafts) | `Live` 0x17 | `Lived` 0x9b | Follow flag bit 1 `LIVE`, Pull `from` bit 63 `DRAFT` |

Reads below a trimmed base are not served by the relay: the archive is the
writer's own stream, so a relay needs no archive tier and never holds plain
or rearranged bytes. `Trimmed` only tells the reader where to look.

## 14. Changes in this revision

- `Trim` (bit 1) and `Trimmed` (bit 2) were added (section 8.14); the
  reserved design changed in three places: only the owner trims (a member's
  `Fill` access does not let it trim someone else's segment), Trim appends no
  feed entry, and reads below base go to the writer's archive stream rather
  than to a relay archive tier. Welcome `features` is 7.

Found while specifying and while running the vectors natively and under
wasm, and fixed in the reference core:

- A `Read` past the end reported `length = from` instead of the segment's
  length, which made clients believe the relay held bytes it did not.
- A follower that also watched received `Dropped` twice.
- Connection lookup compared `int(slot)`; on 32-bit targets (wasm) the
  compaction sentinel slot became -1 and indexed out of range.
- Redaction validated and zero-filled record by record, so a range with a bad
  record left earlier records zero-filled while answering `Refused Io`; it now
  validates the whole range first and changes nothing on failure.
- Welcome gained `features`, and `Account`/`Accounted` were added behind it.
- Live drafts (feature bit 3): `Live`/`Lived`, the LIVE follow flag and
  draft pulls, so streaming text reaches other devices without the relay
  storing a byte of it. `Pull` previously rejected any `from` above
  `2^63 - 1`; with bit 3 it accepts draft pulls. Welcome `features` is 15.
  Live interest first ended with `Unfollow`; a reader's replicator unfollows
  segments it stops reading while its live view stays open, which silently
  cut readers off, so removal is now an explicit LIVE entry with offset
  `2^64 - 1`.
