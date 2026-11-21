# 0ndb design

0ndb is an engine. It records everything that happens in a worktree and in
the agent sessions that work on it, keeps that history forever at near-zero
cost, and replicates it between devices, runners and people through relays
that do nothing but store and forward opaque bytes.

It provides mechanisms, never policies. Who a user is, how they sign in,
where bytes are hosted, which machine runs a turn, how keys are custodied
and how agent processes are sandboxed all belong to whoever embeds 0ndb.
Every such decision is a plug point with a reference implementation, and the
`0ndb` binary is just one consumer assembled from those defaults.

The design is built around five ideas:

1. **Everything is a single-writer append-only stream.** Each participant
   (device, runner, teammate, external harness) appends only to its own
   streams. There is never a write conflict to resolve at storage, relay or
   replica level. Merging happens only where meaning lives: the message tree
   only grows, registers are last-writer-wins by hybrid logical clock, and
   files are CRDTs. Nothing is ever rejected for arriving late.
2. **A record's identity is its position.** A message id is
   `(segment, offset)`. Offsets are identical on the writer, the relay and
   every replica, so a remote device can page a transcript by fetching byte
   ranges from the end of a stream and following references. No index is
   needed anywhere for the common path.
3. **Every byte has an identity and an author, at the cost of plain text.**
   Worktrees are a causal graph of index-based edits (Eg-walker) ordered by
   Fugue, with an inode tree CRDT using the replicated-tree move operation.
   With linear history a file in memory is just its text plus run-length
   origin spans; CRDT state exists only transiently while merging concurrent
   branches. Any number of devices and forks edit one history concurrently
   and converge. Writes are credited to the actor and scope that made them
   at write time, down to the writing process where the OS allows.
   Git is the storage substrate, not the model: text checkpoints are git
   blobs, content git already holds is referenced and never copied, and each
   scope boundary also emits a real git tree/commit so every version is
   inspectable with plain `git`.
4. **Sans-IO cores, one event loop.** Provider drivers, the thread writer,
   the sync client and the relay are pure state machines fed bytes and
   returning bytes. The engine runs on one epoll/kqueue loop (its own thread,
   or the embedder's loop through an fd and a step call) and is asleep (zero
   wakeups, no timers armed) whenever nothing is happening.
5. **Assume nothing about the embedder.** Identity, credentials, transport,
   relay storage, key custody, encryption mode, turn scheduling, process
   spawning, secret handling and provider registration are interfaces. The
   engine is usable as an Odin package, a C library (`lib0ndb`), and its
   read side as WebAssembly for browsers.

## Targets

- Idle daemon: 0 wakeups/s, RSS under 4 MiB with any number of threads and
  worktrees. Nothing per thread or per file stays in memory between events.
- Opening a thread with 100k messages: O(page) reads.
- Remote first paint of a thread: one round trip to the relay for the tail
  of the stream.
- Ingesting an agent tool call in a 1M-file repository: O(changed bytes),
  driven by the watcher; no full walk.
- Integrating a remote batch: O(ops) when it does not overlap concurrent
  work, O(concurrent region) otherwise; never O(document) or O(history).
- Memory per loaded file: text + O(runs of authorship); per unloaded file:
  nothing.
- Relay: one handshake per connection, then zero-copy `sendfile` through
  kernel TLS; it never parses or decrypts records.

## Layout

```
src/
  prim/      ids, hybrid logical clock, binary codec, file helpers, event loop, child processes, paths
  journal/   the record log format (local, replica and wire), group commit, sparse replicas
  odb/       git object database: read loose/packed objects, write loose/packs, trees, commits
  textdiff/  line and byte diff, three-way merge
  crdt/      causal graph, Eg-walker text with Fugue ordering, authorship spans (pure, no I/O)
  fstree/    inode tree CRDT with the replicated-tree move operation (pure, no I/O)
  fs/        worktree mounts: scanning, ignore rules, watching, ingestion, materialization, git awareness, fork, land
  thread/    multi-writer thread segments: messages, blocks, branches, queue, claims, pagination
  index/     index and command streams, merged session table
  search/    local full-text index over transcripts and the code-to-thread lookup
  agent/     provider drivers (sans-IO), the normalized event model, native session portability
  sync/      keys, encryption, relay protocol and relay core, replicator client
  engine/    the embeddable engine: plug points, commands, runs, attribution, recording, events
  capi/      the C ABI over engine (`lib0ndb`, `0ndb.h`)
  cli/       the reference consumer: `0ndb` daemon, relay, runner, record and commands
tests/       only: convergence (text), fstree (tree), sim (deterministic whole-system simulator)
```

Packages import each other with relative paths (`import "../journal"`).
Build: `odin build src/cli -out:bin/0ndb -o:speed`. Every package must pass
`odin check src/<pkg> -vet -strict-style` and also
`odin check src/<pkg> -target:darwin_arm64` (Linux is primary; macOS must
compile, with platform code in `_linux.odin` / `_darwin.odin` files).

Code style: idiomatic Odin, no comments, explicit allocators where lifetimes
matter, `context.temp_allocator` for per-event scratch freed by the loop,
errors as enums/unions returned as the last value, no global mutable state
anywhere (the engine is a value; several may live in one process). No panics on bad input from disk, network or child processes.

## Guarantees

The engine is designed so that none of these has an exception:

- **Agents never silently merge each other's code.** Worktree histories have
  *lines* (named frontiers). Every run writes on its own run line forked from
  its message's version; when its claim wins, the thread's line fast-forwards
  to it. Conversation branches are worktree lines, so sibling turns never
  share files. Two lines only ever combine through an explicit land that
  reports every overlapping concurrent region and never auto-resolves one.
  Live editing by people on one line from several devices merges
  character-wise, as collaborative editors do.
- **Anything can be deleted, everywhere, without changing an id.** Record
  bodies and op contents are encrypted with per-message keys drawn from a
  puncturable key tree (a GGM tree of seeds per segment epoch). Deleting a
  message, block, object or inserted text range punctures the tree (its key
  becomes underivable on every replica, the relay never had it), appends a
  `Redact{ref}` record, zero-fills the bytes in place on every replica and on
  the relay (offsets and lengths unchanged, so every id and CRDT position
  stays valid), purges derived indexes, drops objects, rewrites the scope
  commit pins without the redacted blobs, and asks the provider driver to
  purge its native session state. Secrets are also redacted before anything
  is recorded.
- **Each participant has its own view.** The leaf is per participant (in its
  own segment); the thread's shared head is the newest sent message. Browsing
  an old branch on one device never moves anyone else.
- **Every write is attributed to whoever made it.** A `Write_Observer` plug
  point reports (process, path, operation) for writes: on Linux, unprivileged
  `seccomp` user notification installed in every process the engine spawns
  (only write-intent `open`/`openat2`/`creat`/`rename`/`unlink`/`link`/
  `truncate` reach the supervisor; `io_uring_setup` is refused in agent
  trees), or fanotify when privileged; on macOS, Endpoint Security when the
  embedder is entitled, otherwise open-file correlation through `libproc` on
  every change event. Writes by the agent process itself are matched to the
  tool call whose input names the path, so parallel tool calls are separated.
  Any change not produced by an observed agent process belongs to the other
  actors on that machine, never to a tool.
- **Nobody can forge or fork another participant's history.** Every segment
  is hash-chained (each record's links prefix carries the running chain
  hash) and each commit appends a signature of the chain head by the
  writer's key. Readers verify before integrating; two different chains for
  one segment are proof of equivocation and the segment is quarantined. The
  relay can withhold bytes but cannot alter or invent them.
- **Metadata is minimal.** Stream and object names are keyed hashes; an
  optional padding policy rounds appends and objects to size buckets.
- **The whole system is tested as a whole.** The single end-to-end test is a
  deterministic simulator: every engine runs against simulated disk (a `Vfs`
  that models write ordering, `fsync`, torn and lost writes), network
  (delays, reordering, partitions, duplicate delivery), clock and provider
  processes, under seeded randomness, with crashes at any instruction
  boundary. It checks convergence, durability, attribution and deletion
  across thousands of runs. Any failure replays exactly from its seed.
- **Every platform claim is verified on that platform.** CI runs the
  simulator and real-process checks on Linux and macOS hardware.

## prim

- `Id :: distinct [16]u8`. `id_new()` is UUIDv7-shaped (48-bit ms time then
  random) so ids sort by creation. Hex encode/decode.
- `Hlc :: distinct u64` (48-bit ms physical, 16-bit logical). `hlc_now`,
  `hlc_observe`.
- Codec: `Writer` (appends to a `[dynamic]u8`) and `Reader` (over `[]u8`,
  sticky error flag) with `u8`, `u16le`, `u32le`, `u64le`, `uvarint`,
  `ivarint`, `bytes` (uvarint length prefix), `str`, `id`, fixed arrays.
- All file and directory operations go through a `Vfs` value (direct
  syscalls by default; the simulator substitutes its modelled disk).
- Files: `read_at`, `write_at` (full, EINTR-safe), `datasync`,
  `replace_atomic(path, data)` (temp + fsync + rename + fsync dir),
  `lock_file` (flock, non-blocking, held for process lifetime),
  `mkdir_all`, `data_dir()` (`$ONDB_HOME` or XDG data dir), `runtime_dir()`.
- Loop: single-threaded readiness loop. Linux: epoll (edge-triggered) plus
  pidfd for child exit and one timerfd driving a min-heap of timers. Darwin:
  kqueue with `EVFILT_READ/WRITE/TIMER/PROC`. API: `loop_init`,
  `loop_run(l) ` (returns when `loop_stop`), `watch(l, fd, events, data, cb)`,
  `unwatch`, `timer(l, ms, data, cb) -> Timer`, `timer_cancel`,
  `wake(l)` (eventfd/pipe, thread-safe), `child_watch(l, pid, data, cb)`.
  No allocation per event. A loop with nothing armed sleeps forever.
- Processes: `spawn(argv, cwd, env, new_process_group) -> (Child, Error)`
  with non-blocking stdin/stdout/stderr pipes, `kill_group`, `Line_Buffer`
  (accumulates bytes from a non-blocking fd and yields complete lines without
  copying when a line is contained in the read buffer).

## journal

One format for every stream, used verbatim locally, on the relay and on
replicas, so offsets agree everywhere.

```
record := len:u32le  tag:[16]u8  body:[len]u8  len:u32le
```

- Total size is `len + 24`. The trailing length makes the log walkable
  backwards from any record boundary, so tail pagination needs no index.
- Local form: `tag` is a keyed 128-bit checksum (XXH3-128 seeded with the
  record offset) of `body`. Recovery scans forward from the last checkpoint and
  truncates a torn tail.
- Wire form: `body` is ChaCha20 ciphertext and `tag` the Poly1305 tag, key
  derived per stream and epoch, nonce = record offset. The same lengths and
  offsets as the local form. A record is encrypted only after it is durable
  locally, and a durable record is never truncated, so a nonce is never reused
  with different plaintext.
- `body[0]` is the record kind, owned by the stream's schema (thread, index,
  commands). Bodies use the `prim` codec.
- `Journal` (writer): `open(path)`, `append(body) -> offset` (buffered),
  `commit()` (one write + `fdatasync`), `durable_len`, group commit driven by
  the owner (the engine commits at most every 50 ms while streaming and
  immediately at message boundaries). Reads go through the same `Reader`.
- `Reader`: `pread`-based (no mmap: works on sparse files and keeps RSS
  flat), `record_at(off) -> (body, next)`, `record_before(end) -> (body, off)`,
  iteration both ways, small reusable buffer.
- Replica: the same file, sparse. Ranges fetched from the relay are written at
  their offsets; a sidecar `.have` file keeps the sorted list of present
  ranges. Reads of missing ranges return `.Missing` with the range, which the
  caller fetches and retries.
- Redaction is the one in-place change: a `Redact` record names a range,
  and every holder (writer, replicas, relay) zero-fills that body and marks
  the record redacted in its tag slot, keeping lengths and offsets. The
  record's plaintext key was already destroyed by puncturing the key tree,
  so zero-filling removes the only remaining ciphertext.
- Epochs: a writer may start a new epoch of a stream (compaction) beginning
  with a snapshot record; the old epoch file is deleted after the new one is
  uploaded.

## odb

A git object database in git's formats.

- `Oid :: distinct [20]u8` (SHA-1 of `"<type> <len>\0" + content`).
- `Odb` is a list of object directories: the repository's
  `objects/` (resolving `commondir` for linked worktrees and
  `objects/info/alternates`), plus the device store `$DATA/objects` (a bare
  object directory). Writes go to the first.
- Reading: loose objects (zlib inflate), pack `.idx` v2 binary search with
  fanout, OFS/REF delta resolution with a small bounded delta-base cache.
  Pack and idx files are opened lazily and mapped read-only.
- Writing: loose objects and packs, deflated with stored (uncompressed)
  blocks plus Adler-32, so no compressor is needed and CPU is minimal; git's
  own `gc`/`maintenance` recompresses later. Bulk writes (first mount of a
  large folder) go to one pack with its `.idx`; small writes go loose.
- Streaming: blobs larger than a threshold are hashed and written by streaming
  from the file and read by streaming, never held in memory.
- Trees: encode/decode git tree entries (mode, name, oid) with git's sort
  order. Commits: encode/decode tree, parents, author/committer, message.
- `exists(oid)`, `read(oid) -> (type, bytes)`, `stream(oid, writer)`,
  `write(type, bytes) -> oid`, `hash_file(path) -> oid`, `write_file(path)`.
- Refs: `update_ref(name, new, old)` via lockfile + rename, used to pin
  scope commit chains so git's gc keeps them.

## textdiff

Histogram diff over lines (with Myers fallback), unified-diff rendering,
three-way merge (diff3 with conflict markers), and a blame walker that maps
lines through a chain of revisions. Pure functions over byte slices.

## crdt

Pure data structures; no I/O, no clocks, no randomness. Determinism is
tested by a convergence fuzz (`tests/convergence`): random concurrent edits
over many replicas, delivered in random orders and batch splits, must
produce byte-identical files, trees and authorship everywhere.

Identity and the graph:

- An actor is an `Id` (one per device role: disk ingestion, each agent, the
  recorder). An op id is `(actor, seq)`; each actor's seqs are contiguous.
  Ops also carry a Lamport time for ordering.
- Ops are stored and transmitted run-length encoded: a batch is
  `(actor, seq range, lamport start, parents frontier, ops)` where
  consecutive typing/deleting collapses into one run.
- A version is a frontier. The graph answers `contains`, `diff(a, b)` (ops in
  b not in a) and `common ancestor`, walking in descending Lamport order so
  cost scales with divergence, not history length. The graph is kept as
  run-length spans with parent edges only at run boundaries.
- Admission: parents known, actor seqs contiguous, lamport > parents'.
  Integration is idempotent and independent of delivery order.

Text (Eg-walker with Fugue):

- Ops are `insert(pos, bytes)` and `delete(pos, len)` in the coordinates of
  their parent version, exactly what a diff of disk produces.
- A loaded file is a rope of its current text plus authorship spans
  (op id runs per byte range). Applying ops that extend the current version
  linearly touches only the rope and spans.
- Merging concurrent ops: find the critical version (the latest point every
  branch has seen), build transient Fugue item state for just the ops since
  then (unseen prior content is a single placeholder run), retreat/advance
  to replay each op, transform it to current coordinates, apply to the rope,
  and discard the item state. Concurrent inserts at one position never
  interleave (Fugue-max).
- Anchors `(op id, offset, bias)` resolve to positions through the spans or,
  for deleted text, through the transient state.
- Conflict detection: concurrent ops whose ranges overlap in the merged
  result are reported as regions (for review and land), while the merge
  itself still converges.

Tree:

- Inodes are named by the op that created them. Placement
  `(parent inode, name)`, mode, kind, symlink target and liveness are
  registers resolved by Lamport order with full history retained in the
  graph.
- Moves use the replicated-tree move operation (Kleppmann et al.): moves are
  applied in timestamp order with undo/redo, and a move that would create a
  cycle is skipped. All replicas agree.
- Concurrent same-name entries get deterministic conflict names. Deleting a
  directory removes what its author saw; entries created concurrently inside
  it survive and keep it alive.

Persistence form (used by `fs` and `sync`):

- Batches are journal records in the device's per-history stream
  `fs/<history>` (single-writer, append-only, synced like every stream).
- Each loaded file's state can be checkpointed as `(version, text blob oid,
  spans blob)`; text blobs are git blobs. Loading a file reads the latest
  checkpoint and replays only later ops.

## fs

A worktree mount binds a directory to a history and keeps disk and history
equal in both directions.

- **Shadow** (per mount, under `$DATA/worktrees/<id>/`): for each path the
  inode, stat signature `(mtime_ns, ctime_ns, size, ino, mode)`, content oid
  and version it was last synced at. An on-disk table (append-only records
  plus an open-addressing hash file), compacted when garbage exceeds half.
  Only unpersisted changes live in memory.
- **First mount** walks with parallel `getdents64`/`statx` workers that exist
  only for the scan. In a git checkout the index is read once: entries whose
  stat matches take the index oid (the file text is then referenced from
  git's objects, never copied or hashed), and the cache-tree extension
  supplies tree oids for clean directories.
- **Watching**: Linux shares one inotify instance across all mounts;
  fanotify (`FAN_REPORT_DFID_NAME`, `FAN_MODIFY`, with the writing pid) is
  used when permitted, which lets ingestion credit each write to the process
  tree that made it (a tool call's subprocess vs. an editor). Darwin uses
  FSEvents/kqueue. Events mark paths dirty; overflow triggers a
  shadow-guided rescan.
- **Ingestion**: for each dirty path compare the stat signature, read only
  changed files, diff against the shadow text (line histogram diff refined
  to bytes inside changed lines) and append the resulting ops as one batch
  parented on the mount's synced version, credited to the actor/scope active
  at the time of the write (or the writer pid's scope). Background passes
  defer files younger than a settle delay; scope ends, fences and shutdown
  ingest everything.
- **Materialization**: remote or merged ops are written to disk only for
  inodes touched since the synced version; content that differs from the
  shadow is ingested first, never overwritten. Writes are temp + rename,
  with modes and symlinks.
- **Large files** (over a size limit) are opaque content referenced by git
  oid, hashed and written by streaming, never read into memory.
- **Ignore**: full `.gitignore` semantics (negation, anchoring, `**`,
  directory-only), `info/exclude`, `core.excludesFile`; folders outside git
  also ignore a fixed list of unambiguous dependency/cache/OS directories.
  `.git` is never tracked.
- **Git awareness**: files git writes (checkout, reset, merge, stash),
  decided from HEAD's reflog and the index, go into one batch carrying a git
  op and are never credited to scopes. HEAD branch/commit is recorded with
  each scope boundary. Each scope boundary also writes a git tree/commit
  chain pinned at `refs/0ndb/<history>` (git checkouts) or in the device
  store, so content stays reachable and inspectable.
- **Going back** to a message produces new ops that turn the files into the
  message's version (history is never rewritten, every line keeps its
  author), and restores git as described in Threads.
- **Fork**: same history id cut at the fork version. Git checkouts get a
  separate clone whose `objects/info/alternates` points at the source
  repository (no object copies, any number of forks on one branch, unlike
  git worktrees) with reflink-copied working files (`FICLONE`/`clonefile`,
  else copy); plain folders get a reflink clone. Only paths that can differ
  are rewritten. **Land**: sync both ways, CRDT merge; overlapping concurrent
  regions are stored as conflicts in the fork and shown with markers there
  only; land refuses while any remain.
- **Blame** is a span lookup. **Revert** of a scope creates ops that undo
  exactly that scope's ops, transformed through everything since.
- One live mount per (history, directory) via a lock file. Hibernation drops
  everything per file; any entry point wakes the mount first.

## thread

A thread is a set of **segments**. A segment is one single-writer journal
stream owned by one participant (a device, a runner, a teammate's device, an
external harness recording through the engine). Any participant may append
to a thread by writing its own segment; nobody else's bytes ever change.
The message tree only grows, so segments merge without any authority:
concurrent turns become sibling branches, never rejections.

References: `Ref{seg, off}` where `seg` is a small index into the writing
segment's own table of segment ids (`Seg{index, id}` records declared on
first use) and `off` the offset in that segment. A message id is the `Ref` of
its `Msg` record; globally it is `(segment id, offset)`.

Records (kind byte, a common links prefix, then fields; every record format
uses tagged fields so records written today decode forever):

- `Head{thread, created, format}` first record of every segment; the thread's
  first segment also carries the creating settings.
- `Seg{index, id}` segment table entries.
- `Msg{role, parent: Ref, depth, jump: Ref, runner, cmd, hlc, version,
  git_branch, git_commit, provider, model, provider_session, provider_msg}`.
  `jump` is a skew-binary jump pointer (O(log depth) ancestry and level
  ancestors across segments). `runner` names the participant that should
  answer a user message (decided by the embedder's scheduler).
- `Block{msg, index, kind, ...}` and streaming chunks, as before; payloads
  over 4 KiB are objects referenced by oid with a preview.
- `Seal{msg, status, usage, provider_msg}`.
- `Fork{parent, child, prev_fork}` written when a message is created as a
  non-first child of `parent`; `Remember{parent, child, leaf, hlc}` written
  whenever the leaf leaves the subtree of `child` at fork point `parent`
  (edit, regenerate, switch, going back). Every segment chains its fork
  events, and a periodic `Forks` digest record summarises all fork events
  seen so far, so the full branch structure of a thread loads in O(1) reads
  plus the events since the last digest.
- `Leaf{msg, hlc}`: each participant's own current leaf, written only in its
  own segment. The thread's shared head is the newest `Msg` across segments
  (by hlc, then participant id); a participant without a leaf of its own,
  and every runner, follows the head.
- `Assign{msg, runner, hlc}` reassigns who answers a message (LWW).
  `Claim{msg, lease}` is written by a runner when it starts; a runner only
  starts messages assigned to it. If two runners ever answer the same message
  (an assignment changed while one was offline), both replies are kept as
  siblings and the one whose claim lost the assignment is marked superseded.
- `Queue{item, mode, text, attachments}` from any participant;
  `Unqueue{item, outcome, msg}` from the runner that consumed it (started,
  steered into a running turn, cancelled, edited). Pending items are the
  queue records with no unqueue, carried in the links prefix.
- `Scope{msg, kind, id, actor, before, after}`, `Interrupted`, `Revived` as
  before.
- `Recorded{source, external_id, sequence}` idempotency keys for turns
  recorded from harnesses the engine did not start.

Semantics:

- Pages follow `parent` refs from the leaf (or any message) across segments;
  every read path reports missing byte ranges per segment so a remote client
  batches its fetches; the first page needs one round trip.
- Siblings and switching come from the fork structure: switching to sibling
  `s` at fork point `p` goes to the latest `Remember{p, s}` leaf, or to the
  newest descendant chain of `s` if it was never left. O(1) after the fork
  structure is loaded; nothing scans history.
- Editing, regenerating, going back, queue, steer, crash recovery and git
  restoration behave as before. One thread never rewinds another's files.
- A participant can join any thread at any time: it reads the other segments,
  starts its own, and is immediately a full peer.

Native session portability: when a turn moves to a runner that lacks the
provider's own session state, the previous runner's native session files
(exported by the driver, paths rewritten) travel as encrypted objects so the
new runner resumes natively; the seeded transcript is only the fallback.

## index

Per-participant `index` stream (session list, statuses, worktrees,
participants; per-field LWW by `(hlc, participant)`), and the derived on-disk
session table (copy-on-write B+ tree, paged listing). Commands addressed to
other participants travel in each participant's `cmd` stream and are applied
by their target; `Cursor` and `Rejected` records close the optimistic loop.

## search

A derived, rebuildable local index per participant over the transcripts it
holds: an on-disk inverted index (trigram postings for substring search,
compressed, appended incrementally as segments grow) with title, body, tool,
path and time filters. `wrote:PATH#Lx-Ly` resolves lines to the scopes that
wrote them through authorship spans, and scopes to the messages and threads
that opened them. Results page; nothing is held in memory between queries.

## agent

Each driver is a sans-IO state machine (launch, feed, send, steer,
interrupt, rewind with native fork/undo/seed paths, permissions, models,
attachments). Every raw provider line is recorded before it is interpreted.
Drivers: Claude Code, Codex, Pi, Muse, and one ACP driver for Antigravity,
Cursor, Devin, Hermes and OpenCode. Embedders register further providers
from descriptors (argv, protocol family, capabilities) without changing the
engine. Drivers also export and import their provider's native session state
for portability. Provider wire formats are known only to their driver file;
`docs/providers.md` records each protocol.

## sync

Mechanisms, each behind a plug point:

- **Identity.** A participant has a signing key (Ed25519) held by the
  embedder's `Keyring`; its id is derived from the public key. What a
  participant *is* (a person's device, a runner, a service) is the embedder's
  business.
- **Content keys.** Every thread, worktree history and space-level stream has
  its own random content key. Keys are wrapped for recipients by the
  `Keyring` (reference: X25519 sealed boxes to participant keys; embedders may
  use a KMS). Sharing a thread with someone means wrapping its key for them
  and granting relay capabilities; revoking rotates to a new epoch key.
  Encryption mode is per space: end-to-end (default, the relay never sees
  plaintext) or transparent (the embedder's servers may index content).
- **Transport.** The sync core is sans-IO; the embedder supplies byte
  transport (reference: Noise `IK` then kernel TLS over TCP with zero-copy
  `sendfile`, userspace AEAD fallback; Unix sockets locally; embedders may use
  WebSockets, HTTP/2, QUIC or an in-process pipe).
- **Credentials and authorization.** The client asks the embedder's
  `Credentials` for whatever its transport needs; the relay core asks the
  embedder's `Authorizer` to turn a connection's credential into a principal
  and a capability set (which streams it may read, which it may append to,
  quotas). The relay core enforces only that.
- **Relay core** as a library over a `Relay_Storage` interface (append at
  offset, read range, follow, put/get object, drop), so an embedder can host
  it on files (reference), object storage, or a database. It never parses or
  decrypts records.
- Protocol: `Hello`, `List`, `Append(stream, at, bytes)`, `Read`, `Follow`,
  `Put`, `Get`, `Drop`, framed with hard caps and backpressure.
- **Replicator**: uploads own durable bytes (journal floor = uploaded
  length), follows index/cmd streams fully, fetches thread segments tail-first
  into sparse replicas on demand, fetches objects lazily.
- **Checkpoint bundles**: a participant joining a worktree history fetches the
  newest published checkpoint (fstree records, text checkpoints, git base
  references) plus the ops after it, never the whole history.

## engine

The embeddable engine owns the loop, journals, worktrees, provider
processes and replication, and exposes commands and change events.
Plug points (all optional, reference implementations provided):

- `Keyring` (identity keys, content-key wrapping), `Write_Observer`, `Vfs`,
  `Credentials`,
  `Transport`, `Authorizer` and `Relay_Storage` (for embedders that host a
  relay), `Scheduler` (which runner answers a message; reassignment),
  `Spawner` (how provider processes start: direct, sandboxed, container,
  remote exec), `Secrets` (redaction rules applied before anything is
  recorded, secret environment injection), `Providers` (registry), `Clock`,
  `Log`.
- Runners: any engine instance can be a runner; the embedder provisions it
  (cloud sandbox, VM, a laptop) and starts the engine with credentials. A
  runner joins histories through checkpoint bundles, materializes a
  worktree (clone with alternates or from the git remote, reflink copies),
  runs `.agents/setup` once per environment and links `.agents/linked`
  ignored files, then answers the messages assigned to it.
- Recording API: harnesses the engine did not start append turns through
  `record(source, external_id, sequence, update)` with idempotent receipts
  (recorded, duplicate, superseded); recorded turns get scopes and
  attribution like driven ones.
- Text identity across git rewrites: alias records map text through
  rebase, squash, cherry-pick and moved code so blame survives commits.
- Seals: a history's writers may publish seal records that bound transient
  merge state and let checkpoints drop deleted text, without rejecting any
  late work.
- Events: a subscription API for UIs (sessions, thread pages, statuses,
  worktree changes) with optimistic command overlays.
- The engine is a value: several may live in one process; it can run on its
  own thread or inside the embedder's loop (`engine_fd`, `engine_step`).

## capi

`lib0ndb` (shared and static) with `0ndb.h`: opaque handles, plug points as
C function-pointer tables, binary or JSON payloads, no global state, no
callbacks on foreign threads except through the embedder's loop. The read
side (journal, thread, index, crdt, sync client) also builds for
`js_wasm32` so browsers read and decrypt streams directly.

## cli

The reference consumer, assembled from the default plug implementations:
`0ndb daemon | relay | runner | record | pair | join | status | ls | new |
send | queue | steer | edit | switch | back | log | show | search |
interrupt | models | worktree | blame | revert | land | share | verify`.
