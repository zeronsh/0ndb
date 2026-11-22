# 0ndb design

0ndb is an engine for durable, replicated agent state. It holds everything an
agent system produces (conversations, task graphs, memory, documents,
workspaces spanning any number of repositories, every byte any agent or
person wrote into them) forever at near-zero cost, runs agents against it,
and replicates it between devices, runners and people through relays that
only store and forward opaque bytes.

It serves a coding agent in one repository, a project-wide workspace across
fifty repositories, a persistent assistant answering millions of people on a
chat platform, a captain agent driving a thousand subordinate tasks, and a
plain conversation with no files at all, with one model and no special cases.
A capability that a use case does not touch costs it nothing.

It provides mechanisms, never policies. Who a user is, how they sign in,
where bytes are hosted, which machine runs an agent, how keys are custodied,
how processes are sandboxed, which channels an assistant listens on and which
models it calls all belong to whoever embeds 0ndb. Every such decision is a
plug point with a reference implementation; the `0ndb` binary is one consumer
assembled from those defaults.

The design rests on six ideas:

1. **Everything is an object.** A space holds objects of four kinds:
   *conversations* (growing message trees), *maps* (keyed registers and
   sets), *texts* (sequence CRDTs) and *file trees* (inode trees whose files
   are texts). Agents, tasks, workspaces, memory, session lists, routes,
   schedules and settings are all objects of those kinds that reference each
   other by id. There are no other storage concepts.
2. **Every object is a set of single-writer segments.** Each participant
   (device, runner, teammate, external harness, service) appends only to its
   own segment of an object. Nothing is ever a write conflict at storage,
   relay or replica level, and nothing is ever rejected for arriving late;
   merging happens only where meaning lives, inside the object kind. An
   intent from another device is not a command routed through a server: it
   is a record the device writes into the object itself, durable and real the
   moment it is written. Local-first is literal.
3. **A record's identity is its position.** A record id is
   `(segment, offset)`, identical on the writer, the relay and every replica,
   so any device pages any object by fetching byte ranges from a segment's
   tail and following references. No index is needed for the common path.
4. **Every byte has an identity and an author, at the cost of plain text.**
   Texts are Eg-walker with Fugue ordering; file trees use the
   replicated-tree move operation. With linear history a text in memory is
   its bytes plus run-length authorship spans; CRDT state exists only while
   merging concurrent work. Git is the storage substrate for file contents,
   never the model.
5. **Sans-IO cores, one event loop, zero idle cost.** Drivers, object
   writers, the model loop, the sync client and the relay are pure state
   machines. An engine runs on one epoll/kqueue loop (its own thread or the
   embedder's) and sleeps with no wakeups and at most one armed timer (the
   next due schedule) when nothing is happening. Nothing per object stays in
   memory between events, so a space with ten million objects idles like one
   with ten.
6. **Assume nothing about the embedder.** Identity, credentials, transport,
   relay storage, key custody, encryption mode, scheduling, process spawning,
   write observation, secrets, model access, tools, channels and disk are
   interfaces. The engine is an Odin package, a C library (`lib0ndb`), and its
   read side runs as WebAssembly in browsers.

## Targets

- Idle engine: 0 wakeups/s beyond the next due schedule; RSS under 4 MiB
  regardless of how many objects, conversations, agents or worktrees exist.
- Opening any conversation, map or text: O(page) reads; remote first paint
  in one round trip.
- Creating an object: one appended record, no file creation (segments of
  small objects share a container; see Storage).
- One fdatasync per loop tick for all objects written in that tick.
- Ingesting a tool call in a 1M-file repository: O(changed bytes).
- Integrating remote work: O(ops) linear, O(concurrent region) otherwise.
- A conversation with no files, or an assistant with no schedules, performs
  no file-tree or timer work at all.
- A captain fanning out to N tasks: O(N) records, no processes beyond the
  runs actually executing, no polling.
- Relay: one handshake per connection, then zero-copy `sendfile`; it never
  parses or decrypts records.

## Layout

```
src/
  prim/      ids, hlc, codec, Vfs, event loop, processes
  pack/      container Vfs: millions of small streams in shared files, one fsync per tick
  journal/   the record log format (local, replica, wire), recovery, redaction, signed chains
  arc/       segment archives: grouped, compressed, sealed groups of records, seals, verification
  obj/       objects and segments: refs, segment tables, links, missing ranges, keys, redaction
  convo/     the conversation kind: message trees, blocks, branches, runs, intents, compaction
  map/       the map kind: registers, sets, materialized ordered views
  crdt/      causal graph, Eg-walker text, authorship spans (pure)
  fstree/    inode tree CRDT with the move operation (pure)
  odb/       git object database
  textdiff/  line and byte diff, three-way merge
  fs/        file-tree objects on disk: mounts, scanning, ignore, watching, ingestion, materialization, git, lines, land
  search/    full-text and vector indexes over any objects, code-to-conversation lookup
  agent/     harness drivers (Claude Code, Codex, Pi, Muse, ACP agents), session portability, purge
  model/     the native agent loop over model APIs (streaming, tools, caching, compaction)
  mcp/       MCP client (tools for the native loop) and server (0ndb tools for any harness)
  sync/      keys, encryption, relay core and protocol, announce feeds, replicator
  engine/    runtime: spaces, runs, runners, scheduling, triggers, channels, orchestration, plug points, events
  capi/      the C ABI (`lib0ndb`, `0ndb.h`)
  cli/       the reference consumer
tests/       convergence, fstree, sim
tools/       relayvec: relay conformance vectors (docs/relay-vectors) and their checker
```

Packages import each other with relative paths. Build:
`odin build src/cli -out:bin/0ndb -o:speed`. Platforms: Linux, macOS and
Windows, each first-class, with platform code in `_linux.odin`,
`_darwin.odin` and `_windows.odin` files; the browser read side targets
`js_wasm32`. Every package passes
`odin check src/<pkg> -vet -strict-style -no-entry-point` for every target it
supports, and platform behaviour is verified on real machines (no CI).

Code style: idiomatic Odin, no comments, explicit allocators where lifetimes
matter, `context.temp_allocator` for per-event scratch, errors as values, no
global mutable state anywhere (an engine is a value; many may share a
process, e.g. one per core). No panics on bad input from disk, network,
models or child processes.

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
- The rope keeps two summed metrics per node: bytes and UTF-16 code units
  (continuation bytes count 0, four-byte leads 2, every other byte 1), so
  byte and UTF-16 offsets convert in O(log n) at any char boundary.
- A merge can report every step it applies through a `Text_Sink`:
  `insert(pos, bytes, author)` and `delete(pos, bytes)` in the coordinates of
  the text at that moment, in order. Replayed in order they turn the old text
  into the new one exactly; nothing compares texts.
- `Delta` (pure): a `Delta_Builder` composes sink steps into one canonical
  retain/delete/insert list against the old text (a gap buffer at the last
  step, so ascending or descending runs cost O(1) per step), regions are
  widened to whole UTF-8 code points on both sides (at most three bytes per
  side, reading retained bytes from the new text), and emitted in bytes or
  UTF-16 units with the author of every inserted run. `delta_transform` is
  the inclusion transform for two concurrent deltas over the same text (the
  first argument's inserts win ties), `delta_transform_pos` maps a position,
  `delta_apply` replays one.
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
  ingest everything. Changes no scope claims belong to the mount's ingestion
  actor, `blake2b-128("0ndb ingestion actor" || device || mount id)`, never
  to the device's own API writes, so disk changes concurrent with them stay
  representable. Opening a mount appends one `REC_ACTOR` record (tag 9:
  kind, actor, mount id) to the device's stream; every replica checks the
  actor against that stream's device and presents the actor's edits in blame
  and conflict regions as that device.
- **Commit protocol**: each batch a mount commits carries one opaque
  mount-mark op (tag 18 plus a random per-mount nonce) and, unless the line
  is held, the mount's line record, in the same journal commit. Nothing is
  written before the commit; the mount state records the journal position
  it reflects, and after a crash the mount finds its own committed batches
  by scanning its stream from there for its mark. The mount state alternates
  between two checksummed in-place slots carrying a sequence number. A pass
  costs four flushes: journal, store, shadow and mount state. The history
  journal is durable only when the pack batch carrying it completes, so the
  shadow, the mount state (synced frontier, journal position), staged blobs
  and materialization wait for that batch in every durability mode: a pass
  records an image under the history's mark and writes it when the mark is
  acknowledged.
- **Materialization**: remote or merged ops are written to disk only for
  inodes touched since the synced version; content that differs from the
  shadow, or untracked content where an inode must land, is ingested first,
  never overwritten, and the plan is rebuilt from the new synced version.
  If ingesting changes nothing (an ignored file in the way), nothing is
  written and the path is reported as a collision. The synced version never
  claims anything the disk does not hold. Only durable history is
  materialized, so a crash never leaves disk content the history lacks.
  Writes are temp + rename, with modes and symlinks.
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
- **Text views**: `history_view_open(inode, version)` gives a caller its own
  text state (rope, spans, op log) at a version, cloned from the loaded file
  when the versions match, else checkpoint plus replay. Every batch the
  history applies to that inode is also appended to each open view's log, so
  `history_view_advance(view, target, sink)` is a plain forward merge that
  reports its steps. A view goes stale when its history sleeps (lvs are
  rebuilt), on redaction and on import of its inode; a stale view's next
  advance reloads at the target and reports a byte diff of its old bytes
  against the new text through the same sink, so callers have one path.

## Live buffers

A buffer is an editor's live window onto one text: a text object, or a file
in a tree addressed by `(tree, path)`. Editors (a gpui editor talking to the
daemon, a browser, an in-process embedder) apply surgical deltas to their own
buffer; nothing ever reloads a whole file, cursors stay put, and the person's
concurrent typing is never lost or reverted.

- **Open.** `buffer_open(object, path, line, units, actor)` follows a
  version: a text object follows its heads; a tree file follows a line
  (the line of the mount on that tree if one is live, else `main`). Units are
  `Bytes` (UTF-8 offsets, gpui/Zed ropes) or `Utf16` (code units, web and
  LSP), fixed per buffer. The engine keeps a text view of the file at the
  buffer's version and returns `rev` 0, the total length in units and the
  first page of the snapshot; `buffer_read(buffer, rev, from, len)` serves
  any range at the current rev, so a 50 MB file opens on its first screen.
  Open costs one clone of the loaded rope or one checkpoint read plus the
  ops after it; nothing is diffed.
- **Revisions.** `rev` counts deltas the engine has sent; the client counts
  edits it has sent. Each delta carries `rev` and `ack` (client edits the
  engine had applied when it was made); each edit carries the `rev` the
  client had seen when it made it. This is Jupiter's two-sided protocol: each
  side keeps its unacknowledged messages, and transforms an incoming message
  over them with `delta_transform` (the client's edit is always the first
  argument, so a client insert precedes an engine insert at the same
  position on both sides). Clients pipeline any number of edits; nothing
  stalls on a slow link. The engine keeps unacknowledged deltas only (an edit
  or `buffer_ack` acknowledges); past 4096 of them or 8 MiB the oldest are
  dropped and an edit made against a dropped rev is refused with
  `Conflict`, after which the client reopens.
- **Deltas.** Changes from anywhere (other devices, agent runs landing on
  the line, disk edits ingested from a mounted worktree, tree writes, branch
  switches, rewinds, redaction) mark the object changed; at the end of the
  tick each buffer whose object changed advances its view to its target
  version through the sink and emits one canonical delta (minimal ordered
  retain/delete/insert, widened to code points, every insert carrying its
  author). Delivery is event driven only. A sink that is not ready (a daemon
  connection with unsent bytes) leaves the buffer unadvanced; when it drains
  the buffer advances once to the newest version, so a lagging client gets
  one combined delta and nothing queues. The delta is computed from the
  merge itself: O(ops since the last delta), never O(file).
- **Local edits.** `buffer_edit(buffer, rev, edits, group)` takes ordered
  `(pos, del, ins)` edits in the client's coordinates at `rev` plus its
  earlier edits. The engine transforms them over its unacknowledged deltas,
  converts units at the view, and commits one batch whose author is the
  buffer's actor (the person; default an editor actor derived from the
  device), parented on the view's version, so anything the engine has not
  yet delivered is merged by the CRDT character-wise. The batch is
  journaled and committed with the normal cadence, moves the followed line
  (`line_after`, so concurrent line heads stay), and wakes the mounts of the
  tree; materialization writes the file only after ingesting disk content
  that differs from the shadow. The view applies the batch linearly, so the
  edit never comes back to its author as a delta.
- **Anchors.** An anchor is `(op id, bias)` of a character, plus two
  sentinels for start and end. `buffer_anchors(buffer, rev, positions,
  bias)` creates them in bulk (positions are mapped from `rev` through the
  unacknowledged deltas first, then one span lookup each, O(log n));
  `buffer_resolve(buffer, anchors)` returns positions at the current rev and
  the `ack` they include. A deleted character resolves through the transient
  merge state to where it was. Anchors are values: they live in the client,
  in diagnostics or in comments, and resolve on any device holding the ops.
- **Remote cursors.** `buffer_cursors(buffer, ranges)` publishes the
  person's cursors and selections as anchors through the relay's direct
  messages to the other online participants of the object, sealed with a key
  derived from the object key (only members read them). They are never
  written to history. Received ones are resolved locally and arrive as a
  `Cursors` delta per buffer of that object; the newest set per
  (device, actor) replaces the previous one, and leaving drops it.
- **Undo.** Each buffer keeps an undo stack of its own edits only: inserts
  as op-id runs, deletes as the deleted op-id runs plus an anchor. Undo of a
  group deletes whatever of its inserted characters still exist (wherever
  concurrent work moved them) and re-inserts its deleted characters as
  `Insert_Copy` of the original ops at their anchors, so authorship of
  restored text is kept; redo is the inverse. It never touches characters
  another author inserted, so an agent's or another device's concurrent work
  survives undo. Groups are the client's `group` ids (equal ids merge).
- **Large files.** Open is one rope clone or checkpoint read and a first
  page; deltas, edits and anchors cost O(changes · log n). A file the tree
  keeps as opaque large content cannot be opened as a buffer (`Too_Large`).
- **Idle.** Open buffers arm nothing and wake nothing; they cost the view's
  memory and run only when their object changes.

## Storage

- Every segment is a logical journal stream. Physically, an engine stores its
  segments through `pack`, a `Vfs` that keeps small streams as extents inside
  shared append-only container files (an on-disk B+ tree maps stream ->
  extents) and promotes a stream to its own file once it grows past a
  threshold. Creating an object costs one record, not a file; ten million
  objects cost ten million small extents, not inodes.
- Durability is batched across objects: every journal written in a loop
  tick is committed with one container fdatasync. `Async` (the C API
  default) runs the commit on a worker thread and completes it on a later
  loop wake; `Deferred` runs it on the loop. Nothing derived depends on the
  mode, and the simulator picks the mode per seed, modelling the worker as a
  commit job that runs at a scheduled later time. Compaction rewrites cold
  containers so each stream's extents stay contiguous, keeping page reads to
  one or two preads.
- Derived structures are never durable ahead of their source. A derived file
  past the promotion size lives in its own file, and its in-place writes and
  syncs can reach disk before the pack commit that holds its source, so
  ordering alone does not hold. Each derived structure therefore commits
  atomically and records the source positions it reflects (its stamp), and
  the stamp is checked eagerly at open, before the session's first append to
  that own stream; a stamp past the recovered stream means rebuild or drop.
  Positions into replicas need no check: replica offsets are global and
  chain-verified, so bytes fetched again are identical. Keeping derived files
  inside containers was measured and rejected (an omap table under random
  puts wrote 1.7-2x the bytes with 2-2.4x the p99 batch latency, and inside
  files cap near 16 MB).
  - Registry: on an unclean open, before spaces load, `own` and the owned
    entry of an object whose own segment is absent or empty are cleared (not
    created yet), content and promotion marks are clamped to the recovered
    own stream, and a checkpoint length past it is dropped. Legacy registry
    rows migrated into the redaction log are deleted only after the batch
    holding their replacement records is durable.
  - Map tables: `ROOT_CONSUMED[self]` rides the same copy-on-write commit as
    the entries; it is checked when the table opens (and the writer opens the
    table before its first append) against the recovered own stream, and a
    table ahead of it is reset.
  - `.children` slots: before the first slot write after a sync the header is
    rewritten as dirty and synced; a clean header means the slots reflect
    exactly `covered`, a dirty one is rebuilt at open.
  - fs history: the state kv commits atomically (each commit ends with a
    marker record; recovery keeps whole commits only) and every commit
    carries the own journal length as its stamp; `lv.idx` must cover exactly
    the graph's lv range. At wake, a stamp past the recovered journal or an
    `lv.idx` that is short is a rebuild (an `lv.idx` that is long is cut back
    to the graph): derived keys are dropped, keys that no record carries
    (sources, pins, blob versions, mount aliases and conflicts) are kept, and
    the history replays its journal and streams. Replay applies a redacted
    batch's replacement in its place, and pauses at an own batch whose
    parents are remote until those arrive instead of dropping it.
  The simulator checks all of this after every engine open: registry facts
  against the own streams, and every map table, `.children` file and fs
  history against a rebuild of its sources cut at the positions it consumed. `SIM_PROMOTE`
  shrinks the promotion size so derived files are promoted.
- Redaction punches holes in extents; the simulator substitutes its own disk
  beneath `pack` exactly as beneath plain files.
- A small stream whose extent count passes 32 is defragmented by merging,
  repeatedly, the window of adjacent extents with the fewest bytes rewritten
  per extent freed, until 24 remain. Merging a fixed window of 16 instead
  always swallowed the previous merge once fewer than 16 fresh extents
  existed, copying the stream once per 15 appends (quadratic): the relay
  feed's 40-byte appends wrote 57 times its size into the container before
  promotion. The ratio policy is tiered: 7 times for 40-byte appends (of
  which 2.2 is the data and its length slot), 2.9 for 300-byte, 1.9 for
  1.5 KB appends.

## Objects

- An object is `(id, kind, key)`. Its history is the set of its segments,
  one per participant that ever wrote it. Segment records share one
  envelope: kind byte, links prefix (segment table refs, chain state,
  per-kind tail summary), fields with tagged encoding so records written
  today decode forever. The head record carries the format version
  (`obj.FORMAT_VERSION`, 2 since records may carry compressed fields, 3
  since records carry their writer's generation); a
  head with a newer version, or a links tag below the kind range that the
  reader does not know, is rejected as Unsupported rather than Corrupt, so
  newer data is never mistaken for tampering.
- Records compress one at a time. When a record's fields reach 128 bytes,
  `obj.finish` keeps the leading fields raw while each encodes in under 64
  bytes and replaces the rest with one zstd frame (the pinned static
  zstd, level 3, no dictionary, content size in the frame header), kept only
  if the record shrinks by at least 1/8 of the compressed part. Links tag 5
  carries the raw length of the compressed tail, tag 6 the length of the raw
  head. This happens before `journal_end`, so the compressed body is the
  only form: the local journal, the wire (ChaCha20 over the same bytes), the
  relay and every replica hold the same lengths at the same offsets, and
  chain links, signatures, local tags, replica fetch and redaction work on
  stored bytes and never inflate. Redaction zero-fills the whole stored body
  as before. Decoders (`convo.decode_env`, `map.decode_body`) inflate into
  the caller's arena: the frame's declared size must equal tag 5, head plus
  tail must fit `journal.MAX_BODY`, and the output must be exactly that
  size, or the record is Corrupt. The kind byte, links and raw head stay
  readable without inflating, so scans that need only a block's message
  ref skip decompression. Compression and decompression contexts are created
  per record, so nothing stays in memory between records. Dictionaries and
  cross-record grouping are not used: a trained dictionary holds verbatim
  content that would outlive a redaction. The browser build links
  `src/zstd/lib/zstd_wasm32.o` (zstd.c without the dictionary builder, built
  by `build.sh wasm32`, allocating through Odin's default allocator).
  Recording a 4.4 MB, 2769-message agent transcript: Block records
  4.68 -> 2.59 MB, the conversation segment 6.53 -> 4.42 MB, relay bytes
  8.28 -> 6.18 MB (-25%). Compression costs 7.6 ms per MB of fields on
  append, inflation 2.6 ms per MB on read; level 1 is 1% larger, levels
  5-9 are 2% smaller at 2-4x the compression time.
- References: `Ref{seg, off}` within an object; `(object id, Rid)` across
  objects. Objects reference each other freely (a conversation names its
  agent, workspace, parent task and mounted file trees).
- Generations. A crash discards a segment's non-durable suffix and the next
  writer session appends new records at the same offsets, so an offset alone
  can name different records over time. Every writer session takes a fresh
  generation from the engine's counter (`<dir>/gen` on the base Vfs,
  reserved in blocks: the block ceiling is written with `replace_atomic`
  before any generation in it is used, so a generation is never handed out
  twice and no append or writer open pays an fsync), and every record
  carries its writer's generation in the links prefix (tag 7, absent means
  0 for records written before generations). Being inside the record body,
  it is identical locally, on the relay and on replicas.
- A `Rid` handed to any caller is `{seg, off, gen}` with the target record's
  generation, the same on every device; text form `<seg>:<off>:<gen>`, wire
  form `id, ivarint, uvarint`. Producing one costs nothing for the writer's
  current session and otherwise reads the target's links (a page reads only
  its last message's parent; every other generation comes from bodies it
  decodes anyway). Resolving one (`obj.vref`) checks that a record of
  exactly that generation starts at that offset and answers `Not_Found`
  otherwise, so a reference to a record that never became durable can never
  name another record. Redaction zero-fills the generation with the body; a
  redacted record matches only generation 0. Rids the engine produced from
  a view and converts back within that view use `obj.vref_pos`.
- Every stored reference is safe by one of these rules:
  - *Same segment, backward* (links `event/segs/prev`; convo `Msg.parent,
    jump, intent, parent_seal, files_prev, claim`, `Block.msg/prev`, `Seal`,
    `Leaf`, `Fork`, `Remember`, `Spine`, `Files.next`, intent and run
    targets, `Compact`, `Scope.msg`, `Interrupted`, `Revived`, `Recorded`;
    `Redact.from/target` in the writer's own segment; map `Del` dots naming
    own `Add`s): refs only point to earlier offsets and journals are
    prefix-durable, so if the referencing record survives so does its target.
  - *Other participants' segments* (seg table index ≠ 0, map dots naming
    remote `Add`s, remote redaction intents): a device holds another
    device's records only after the relay served them, and a writer uploads
    only records that are durable, so those offsets are never reused.
  - *Carries the generation* (every caller Rid; convo settings `parent`
    (tag 24); catalog `Parent` (trailing uvarint); runtime state values
    (32-byte rids; map keys keep 24-byte positions); run raw journal
    `RAW_META`, `RAW_OWNER`, `RAW_LINK`): resolution checks it.
  - *Ordered durability* (own-device redaction intents): the target's journal
    is committed before the intent is appended; pack commit groups land in
    `journal_commit` order and promoted streams fsync on commit, so an intent
    never survives its target.
  - *Derived from durable sources only* (search index positions, which hits
    turn into Rids by reading the record at query time; the map table; fs
    history KV and `lv.idx`; `.children` slots): a derived structure never
    records a position past its source's durable end, and is rebuilt when it
    is found ahead of it.
  - *Op ids, not offsets* (crdt `(actor, seq)` and frontiers in convo
    `Msg.files`, `Landed.files`, `Scope` versions and mount state): the
    history they name is durable before the record that names it.
- Every kind supports: paging from any tail with batched missing-range
  reporting, per-participant signed hash chains, per-record keys from the
  object's puncturable key tree, and redaction.
- A space is a membership log, a sequence of key epochs and a relay
  namespace (see Membership and key epochs). Its catalog is a map
  object with one entry per object (kind, title, parent, workspace, agent,
  participants, status, activity, usage, archived, pinned), materialized
  locally into ordered views so any listing is a paged range read.

## Conversations (`convo`)

A conversation is a message tree that only grows. Everything about agents
running on it is a record in it.

- `Msg{role, author, parent, depth, jump, hlc, files, provider, model,
  native}` with blocks, chunks and seals as before. `files` is the delta of
  the conversation's mount set since its parent: for each mounted file tree
  that changed, `(mount name, tree id, line, version)`; a message with no
  mounts carries nothing.
- Branches: `Fork`/`Remember` with digests (O(1) sibling switch), a
  per-participant `Leaf`, and the shared head (newest message).
- Intents written by any participant: `Queue`, `Steer`, `Edit_Queued`,
  `Cancel`, `Interrupt`, `Answer` (permissions and questions), `Assign`.
  There is no command stream; another device's intent is a record in the
  conversation it targets.
- Runs: `Claim{msg, runner, lease, lines}` when a runner starts, `Unqueue`
  for what it consumed, `Seal` when done, `Superseded` when a reassignment
  made a duplicate. Each run writes its own lines of every mounted tree and
  fast-forwards the conversation's lines on success (`Landed{run}`), all
  mounts together.
- Mounts: `Mount{name, tree, line, path}` and `Unmount{name}` change which
  file trees a conversation works on; zero, one or many, from any
  workspace. Going back to a message restores every mounted tree (and each
  repository's git state) to that message's versions together.
- `Compact{from, to, summary}` records a context summary for long or
  infinite conversations; history is never dropped, the summary is what a
  model sees in place of the range. Harness-side compactions are recorded
  the same way.
- `Scope` attribution, `Recorded` idempotency for external harnesses,
  `Interrupted`/`Revived` crash recovery, `Redact`, as before.

## Maps (`map`)

A map holds keyed last-writer-wins registers (by `(hlc, participant)`),
add-wins sets and counters, per field. Materialized views (copy-on-write B+
trees, rebuildable) give any secondary ordering as a paged range read.
Applying a record to a view is idempotent by construction: registers are
last-writer-wins, set elements carry their record ids, and a counter keeps one
contribution per source device (its running sum and the offset of the last
record folded in), so a record at or below that offset changes nothing and the
value is the sum over sources. A view may re-read any stream from any offset,
from the local journal or a replica, any number of times. Maps are the
catalog, workspaces, agent definitions, memory facts, routes, schedules,
runner capacity and settings.

## Workspaces

A workspace is a map: name, members (file trees with default mount names
and paths, documents, memory objects), defaults (agent, provider, model,
runner policy), setup (`.agents/setup`, linked ignored files) and access.
Conversations may belong to a workspace or not, and mount any subset of its
file trees (or trees from elsewhere). A runner materializes a conversation's
mounts side by side under one root it gives the agent as its working
directory, each a clone with alternates or a reflink copy, so a turn that
spans many repositories sees them all and every write is attributed to the
right tree.

## Agents

An agent is a map: instructions, driver (a harness provider or the native
model loop) with model and options, tools (built-ins, MCP servers), memory
(objects it reads and writes), triggers, budgets, default workspace and
runner policy. Conversations name the agent that answers them.

- **Persistent assistants.** Triggers start runs without a person present:
  `Channel` messages (the embedder's ingress adapters deliver inbound
  messages; a routes map binds `(channel, key)` to a conversation, creating
  one on first contact), `Schedule` entries (cron or one-shot, durable in the
  agent map; the engine arms a single timer for the earliest due entry across
  all agents) and `Event` hooks (object changes, webhooks via the embedder).
  Replies leave through the same channel plug. Memory is ordinary objects
  (texts for notes, maps for facts) indexed by `search`, including vectors.
- **Native model loop** (`model`). For agents that need no CLI harness, the
  engine runs the agent loop itself: streaming model calls through the
  `Model` plug (reference adapters: Anthropic Messages, OpenAI Responses and
  compatible APIs, over an `Http` plug whose reference implementation is
  libcurl's multi interface driven by the engine loop), tool calls, prompt
  caching, compaction. No process per conversation: one assistant serves
  any number of concurrent conversations from one loop.
- **Harness drivers** (`agent`). Claude Code, Codex, Pi, Muse and ACP agents
  as before, with steering, rewind, attachments, portability and purge.
- **External harnesses** record through `record(...)` with idempotent
  receipts.

## Orchestration

A task is a conversation with a parent. A captain agent creates tasks
(child conversations with a goal, agent, mounts forked from its own lines,
budget and runner policy), writes into them, and waits on them; children
report by sealing results that the captain's runs see.

- Tools: `spawn`, `send`, `wait` (any/all/condition, with timeout), `list`,
  `cancel`, `result`, `merge` (land a child's lines). The native loop has
  them built in; harnesses get them through the 0ndb MCP server (`mcp`), so a
  Claude Code captain orchestrates exactly like a native one.
- Waiting is a record (`Await{tasks, condition, deadline}`), so a captain
  resumes after a crash or on another runner without losing its place.
  Wake-ups come from object change events, never polling.
- Budgets and cancellation flow down the task tree; usage and status roll up
  through the catalog. Agent-to-agent messages are records written into the
  recipient's conversation by the sender.
- Placement of every run is the embedder's `Scheduler`; runners advertise
  capacity in a map.

## Moving between devices and runners

Everything a run needs is objects: the conversation, its agent, its
workspace, its mounted trees (checkpoint plus tail), its memory, and the
provider's native session (exported into an object after each turn, imported
by the next runner). A run moves by assignment; the new runner fetches only
what it touches, tail first.

## search

Derived, rebuildable local indexes over any objects: trigram full text,
token queries with filters, vectors (an `Embedder` plug; an on-disk
quantized index), and `wrote:PATH#Lx-Ly` through authorship spans. Redacted
content is purged from every index.

Indexes are never durable ahead of their sources: a flush that would persist
a source position past that source's durable end is deferred, and on open an
index whose recorded position is beyond a source's durable end is rebuilt.
Dictionaries and codebooks record the documents they were trained on and
retrain when any of them is deleted. Stored text frames are zstd level 6,
with trained dictionaries, through one pinned zstd (`src/zstd`, 1.5.7)
linked statically on every platform, so index bytes are identical across
hosts.

**Cross-device search.** Partial replication means a device can only index
what it holds, so search reaches across devices:

- *Full indexers.* A device can keep a full index of a space (opt-in per
  device and per space; on by default for CLI daemons and runners, off for
  embedders). It walks the space catalog and every catalog change, keeps a
  persistent queue of objects to index, and fetches their segments through
  the ordinary replicator, conversations and titles first, file trees only
  when configured. Nothing per object stays in memory between events and
  nothing wakes it at rest. It advertises itself in the space's
  `0ndb:indexers` map: its card (for encryption) and its coverage. A
  device that leaves full mode retracts the entry, and until the retraction
  reaches a requester it answers queries with `Denied`, so the requester
  moves to the next indexer instead of waiting. An object counts as indexed
  only against the relay's length learned after the indexer started
  following it, and the check repeats at settle, so the last messages of a
  burst are never missed.
- *Peer query.* A requester sends one end-to-end encrypted query (an
  ephemeral X25519 key against the indexer's card, so only that device can
  read it) through the relay's direct-message path to an online indexer and
  gets one reply: refs only, `(object, record ref, part, score, hlc, match
  spans)`, a cursor, and a freshness vector, never content. The request
  carries the requester's card and a signature, plus a proof derived from
  the current epoch's content key when the requester is a member; a non-member is answered
  only from objects it participates in.
- *Verification.* The requester fetches every hit itself through normal
  paged reads, verifying chains and decrypting with its own keys, re-checks
  that the record matches the query, and builds snippets locally. An indexer
  can hide results; it cannot inject, alter or leak them.
- *Freshness and merge.* The reply carries, per hit source, the indexer's
  indexed high-water mark and the number of objects it has queued. Local and
  peer results merge deterministically (score, then recency, then object
  and ref), deduplicated by `(object, ref)`, and every result says which
  sources answered, which were partial, and by how much.
- *Availability.* Indexers come and go. A query in flight is re-sent to
  another indexer the moment presence reports its indexer down or the relay
  reports it undeliverable, and hedged to a second indexer after a short
  deadline; the first answer wins. With no indexer online the local results
  return at once, marked partial, and the engine emits `Indexer_Wanted` so a
  host can start one. Timers exist only while a query is in flight.
- *Snapshots.* An indexer checkpoints its index through the checkpoint
  machinery (`ckpt/0ndb:search`, one stream per indexer, newest record
  wins). Each record lists a chain of deltas; each delta is a bare search
  segment (stored text and document metadata, no postings) holding the
  conversation documents and titles of one document-id range, plus
  `(object, device, position)` coverage entries for the sources it
  advanced. Blobs are content-addressed and sealed with a key tree derived
  from the space's object key, so only space members can read them.
  Snapshots are taken only at settle, once the indexer has caught up and
  the new text exceeds max(16 KiB, 1/8 of the chain); a new delta merges
  with the newest ones while they are no more than twice its size (and
  under 32 MiB), so each byte is rewritten O(log n) times and the chain is
  never rewritten whole. A fresh or wiped full indexer holds its indexing
  until it has decided to restore: it fetches the newest record and its
  deltas and imports them (re-tokenized, raising each source's position),
  adopts the chain, then catches up from the announce feed. The import is
  crash-safe: a registry marker lets a restart undo a partial import. A
  restored device also replays redaction ranges it has seen in the feed
  over the imported documents. Redaction marks the chain dirty; at the next
  settle every delta whose live document count dropped is rebuilt from the
  local index, published, and the old blob is shredded (deleted on the
  relay, its key cell punctured) and the superseded records zero-filled.
- *Plug.* `Search_Remote` routes peer queries to an embedder's own hosted
  indexer instead of the relay path; its answers are verified the same way.

## agent

Harness drivers are sans-IO state machines with steering, rewind, attachments,
portability, purge and a provider registry. Provider wire formats live only
in their driver file; `docs/providers.md` records each protocol.

## sync

Mechanisms behind plug points (`Keyring`, `Credentials`, `Transport`,
`Authorizer`, `Relay_Storage`), per-object keys from puncturable key trees
with sharing by wrapping, relay redaction, signed chains, padding and
checkpoint bundles, as before, plus:

- **The relay is a sans-IO core with thin hosts.** `Relay_Core`
  (`relay_core.odin`, `relay_feed.odin`, `relay_hollow.odin`,
  `relay_direct.odin`, `relay_revoke.odin`) takes connections, bytes, storage
  completions and a clock, and emits bytes and `Relay_Storage` calls; it owns
  no socket, loop or timer and builds for `js_wasm32`. `0ndb relay`
  (`relay.odin`) is the socket host (Noise, WebSocket, kernel TLS, `sendfile`,
  rate limits, the pack); the simulator drives the core directly, so every
  host gets the same guarantees. The socket host arms no timer of its own:
  when its loop has nothing armed or pending and `relay_quiet` holds (no
  handshake, partial frame, queued output, storage job or yielded work), it
  releases memory once (heap trim, and on Linux `MADV_DONTNEED` on clean
  file mappings, so code comes back as minor faults from the page cache) and
  sleeps until the next event. `docs/relay-protocol.md` is the normative
  protocol, so a relay can be implemented anywhere (a Durable Object per
  space, a small TypeScript server), and `docs/relay-vectors/` holds
  byte-exact transcripts produced and checked by `tools/relayvec`, natively
  and under wasm.

- **Announce feeds.** For each space the relay core keeps an append-only feed
  of `(segment, new length)` entries, one per append, filtered per principal
  by its capabilities when served. A participant follows one feed per space
  instead of one subscription per segment, and fetches only the segments it
  cares about; ten million objects cost nothing until touched.
- Partial replication is the default: a participant holds exactly the
  objects (and ranges) it has used.
- **Direct messages.** A participant can send an opaque frame to another
  participant of the same space by device id. The relay delivers it to one
  live connection of that device or answers `Undelivered` at once; it keeps
  no state beyond delivery and cannot read the payload, which the endpoints
  encrypt end to end. Cross-device search and sign-in approvals use it.

### Membership and key epochs

No device holds a permanent space root. A space is a signed membership log
plus a sequence of key epochs sealed to the current members; the relay
enforces the log, holds no keys, and stays dumb.

**Membership log** (`sync/members.odin`, `roster.odin`). Every member keeps a
transparent (unencrypted, signed) single-writer stream `members` whose stream
id is `device ‖ BLAKE2b-MAC(BLAKE2b("0ndb members name" ‖ space), epoch 0 ‖
"members")[:16]`, computable by the relay. A record is

```
MEMBER_RECORD(0x4d) | version 1 | op u8 | space [16] | author sign pub [32]
| lamport uvarint | nparents uvarint (<= 64) | parents [32]* | time_ms u64le
| payload bytes | sig [64]
id  = BLAKE2b-256("0ndb member id" ‖ whole record)
sig = Ed25519(author, "0ndb member v1\0" ‖ record without sig)
space id = BLAKE2b-128("0ndb space" ‖ genesis id), UUID-v8 nibble set
```

Ops: `Genesis` (founder's `Add` body, no parents, space field is a nonce),
`Add{sign, box, kind, role, method, person, expires, lease_ms, history,
scope[], label, attestation, seal}`, `Remove{subject}`, `Commit` (below),
`Update{box}` (own leaf key rotation), `Renew{expires}` (runner lease),
`Seal{subject, epoch, wrap}` (epoch keys for a non-leaf runner), `Revoke{grant}`.
Kinds: device, account, recovery, custodian, pool, runner, guest, directory. Roles: owner,
admin, member, reader. Methods: genesis, approval, recovery, account,
custodian, pool, grant, directory. Records are carried by any member's stream (a device
appends the Add that enrolled it), deduplicated by id.

Resolution is a pure function of the record set, so every holder (devices,
relay) computes the same roster:

- Records whose parents are not all present are held, not applied.
- Records apply in a topological order; among ready records the order is
  (author role rank, author seniority = position of its Add, lamport, id).
- An author must be an active member at the record's position. Owners add
  and remove anyone; admins anything but owners; members add devices and
  guests; pools add only `runner` members with `method pool` and a lease, and
  remove their own runners; anyone removes itself.
- **Removal wins.** Given the applied removals R, a record by X is void
  unless it is in the causal past of X's removal. The pass repeats with the
  new R until it is stable (at most `#removals + 2` passes; if a cycle
  persists the union of all removals seen is applied, which only removes
  more). So an add, commit or removal made by a party concurrently with its
  own removal never takes effect, and its descendants (a device it added)
  fall with it. Of two mutually concurrent removals the one ordered first
  (higher role, then senior) applies and voids the other.
- Expiry and leases are wall-clock checks against `expires`; a runner's
  `Renew` extends to at most `record time + lease_ms`.

**Ratchet tree** (`sync/ratchet.odin`). Epoch keys use a TreeKEM-style
left-balanced binary tree (RFC 9420 array indexing, width a power of two)
whose leaves are the leaf-capable members (device, account, recovery,
custodian, pool) and whose leaf keys are the members' own X25519 identity
keys. Why this and not the alternatives: pairwise sealing costs O(n)
ciphertexts per change (84 KB and ~80 ms at 1000 members); LKH needs a
central key server; MLS proper needs a total order of commits, which a
relay that only forwards bytes cannot provide. TreeKEM gives O(log n) per
change on a filled tree and works with concurrent commits once leaf keys are
fixed identity keys: a commit never invalidates anyone's ability to open a
sibling commit, so concurrency only produces sibling epochs, never lockout.
Leaf keys rotate only through `Update` followed by a commit.

```
Commit := base epoch id [32] (zero for epoch 0) | number u32 | history bool
        | width u32 | nblanks uvarint, leaf uvarint* | nsets uvarint,
          (leaf uvarint, sign [32], box [32])* | committer leaf uvarint
        | npath uvarint, (node uvarint, pub [32], ncts uvarint,
          (target node uvarint, wrap [84])*)*
        | naming [48] | nbacks uvarint, (epoch id [32], sealed [48])*
```

- The committer applies the delta (blank leaves of removed, expired or
  rekeyed members, set leaves of new members, which enter the unmerged lists
  of their non-blank ancestors), then walks its direct path: `ps_0` random,
  `ps_{i+1} = HKDF(ps_i, "0ndb path")`, node key = X25519 of
  `HKDF(ps_i, "0ndb node")`, and `ps_i` sealed (`seal_key_to`, ephemeral
  X25519 + ChaCha20-Poly1305, epoch field = node index) to every key in the
  resolution of the copath child. A leaf ciphertext is opened through the
  `Keyring` plug, so HSM and enclave keyrings work unchanged.
- `epoch_secret = HKDF(ps_root, "0ndb epoch" ‖ space ‖ base ‖ number)`;
  content key `HKDF(epoch_secret, "0ndb epoch content" ‖ number)`; object
  epoch key `HKDF(content, "0ndb object epoch" ‖ object id)`.
- `naming` seals the space's stable naming secret N (32 random bytes made at
  genesis) under the epoch; `backs` seal the base and other head epochs'
  secrets (history access; `history = false` breaks it), so a member holding
  the newest epoch walks back to every older one.
- Epoch number is base + 1. The **effective epoch** is the highest number,
  ties to the latest in resolution order. It is *eligible* when every leaf in
  its tree is still an active member. A member writes only under an eligible
  epoch it holds; if the newest epoch is ineligible (a pending removal) or
  the member's own leaf is missing, it commits, but only once its membership
  log has caught up (relay caught-up and every announced members stream read)
  so joiners do not fork the epoch chain needlessly. Members keep path
  secrets for the newest 64 epoch numbers so late concurrent commits still
  open; older ones are reached through back links.
- Remove is always followed by a commit by the remover, so the new epoch is
  sealed only to the remaining members. `0ndb rotate` / `space_rotate`
  commits with no membership change (suspected compromise).

**What is encrypted under what.** N derives the space's stream naming scope
(`HKDF(N, "0ndb space names")`) and, through it, every object's naming and
static stream keys, so stream ids never change across epochs. N reveals only
stream names; a removed member that kept N learns no content and the relay
refuses it anyway. Content keys come from epochs:

- Segment records keep per-record keys from the writer's GGM key tree. The
  tree record a writer publishes in `keys/<seg>` is
  `KEYS_SEALED(4) | epoch tag [12] | ChaCha20-Poly1305(HKDF(object epoch
  key, "0ndb keys record" ‖ stream id ‖ version), tree)`, with tag =
  `number u32le ‖ epoch id[:8]`. The key tree encoding (version 3) carries the
  tag of its last reseed.
- **Reseed.** When a writer first appends in a new epoch (writer open, or an
  epoch change while open), it punctures its tree from the current write end
  to the last cell and fills that range with fresh random aligned subtrees
  (at most 44 seeds), tags it with the epoch and republishes it under the new
  object epoch key. Records below the boundary keep their keys, so every
  existing id, offset and redaction is untouched, and puncturing for
  redaction works the same across epochs. A removed member holds only the
  old seeds, which give wrong keys for every record past the boundary.
- A reader whose copy of a writer's tree is tagged with an older epoch than
  the newest it knows treats a failed record or chain tag as "keys needed",
  refreshes the writer's keys head, and holds; it never reports tampering
  from a tree that may be stale. Data that arrives before the epoch secret it
  needs (any author, any partition) leaves that tree locked and the data held;
  every new epoch secret unlocks locked trees and releases held data.

**Relay authorizer** (`sync/member_auth.odin`, default in `relay_init`).
Credentials:

```
member  := 4 | space [16] | device sign [32] | hello sig [64]
           | nproofs uvarint (<= 8) | proof bytes*
request := 5 | account sign [32] | device sign [32] | hello sig [64]
account := 6 | account sign [32] | device cert [64] | device sign [32]
           | hello sig [64]
device cert = Ed25519(account, "0ndb device cert\0" ‖ device sign)
```

A member hello carries the records that admit it (the genesis for a founder;
the `Add` that enrolled it), so a joiner never races its approver's upload. A
proof is ingested only if it is the space's genesis or its author is an
active member. The authorizer keeps, per space, the record set (a derived
file of records under the relay dir, reconciled against the members streams
in relay storage when the space is loaded) and the resolved roster. Every
access (`List`, `Read`, `Append` own streams, `Redact`, `Put`, `Get`,
`Fill`, presence, follow, direct messages) checks the roster live, so a
removed or expired principal is refused at its next request. When an append
to a members stream lands, the relay hands the bytes to the authorizer
(`Authorizer.observe`); principals that stop being active are failed with
`Auth` on every connection (`relay_revoke`). The engine marks the space
revoked on an `Auth` failure, fails pending reads with `Permission`, stops
reconnecting and emits `Access_Revoked`. Request principals may only send
direct messages and see presence in the account namespace
`BLAKE2b-128("0ndb account namespace" ‖ account sign)`; account principals
(devices with a cert) likewise. Third-party capability tokens are signed by
an active member device (`issuer_ok` checks the roster), not by a space key.

### Accounts, sign-in and devices

The product is always end to end encrypted. A user has one **account key**
(an Ed25519 + X25519 identity from a 32-byte seed), which is a leaf member
(owner) of every space of the account. Devices never keep it: it is held in
memory only while enrolling or approving and is cleared afterwards.

- **Account record** (`sync/account.odin`), stored through the
  `Sealed_Store` plug (`get/put/add`; the embedder's account server, keyed by
  its login subject; `File_Sealed_Store` is the reference):

  ```
  0x41 | version 1 | account sign [32] | account box [32] | seq u64
  | home relay str | relay pub [32] | pool access u8 | pool sign [32]
  | pool box [32] | nwrappers uvarint (<= 64),
    (credential bytes | label str | ecosystem u8 | salt [32]
     | sealed seed [48] | added_by [32] | added_at u64)*
  | Ed25519(account, "0ndb account v1\0" ‖ all of the above)
  ```

  Each registered passkey is a **wrapper**: the account seed sealed with
  `HKDF(PRF output, "0ndb account wrap" ‖ credential ‖ salt)`. Any wrapper
  unlocks the key, so passkeys from different ecosystems coexist. Adding or
  removing a wrapper is a new signed record (CAS on `seq`); removing one never
  rotates the account key; at least one non-recovery wrapper must remain.
- **Recovery key** (settings only): 20 random bytes, base32 with a 16-bit
  check, shown in groups of four. Its wrapper uses
  `Argon2id(m = 64 MiB, t = 3, p = 1, salt)` before the same HKDF; with 160
  bits of entropy offline guessing is infeasible regardless of stretching.
- **Manifest.** When a device creates or joins a space for the account it
  appends a manifest entry through `Sealed_Store.add`: `device sign | device
  cert | sealed bundle | device sig`, the bundle sealed to the account box and
  holding `(space id, name, relay, relay pub, anchor id, anchor lamport)`,
  where the anchor is the account's own `Add` in that space.
- **Sign-in, chosen automatically in this order** (`account_login`):
  1. a registered passkey on this device unlocks the account through the
     `Unlock` plug (PRF over a per-wrapper salt; `Local`);
  2. else **approve on another device**: the new device connects to the
     account namespace as a requester and sends
     `REQUEST | card | nonce [16] | label` to every present device; both
     screens show the 8-character code `base32(BLAKE2b-64("0ndb approval
     code" ‖ card ‖ nonce))` (a relay that substitutes the card must find a
     40-bit second preimage within the request's lifetime). The approver
     unlocks with one biometric and answers `GRANT | seal(account seed →
     requester box, ctx = "0ndb approval" ‖ nonce)` or `DENY`. If presence
     shows no approver online, `Login_Failed("no approver online")` is
     emitted at once;
  3. else WebAuthn cross-device (hybrid/QR), which is the same `Unlock` call
     with `Cross_Device` and needs nothing else from the engine.

  With the account key in hand the device appends, for every manifest space,
  `Add{device, admin, method account, person = account}` signed by the
  account with parents `[anchor]`, presents it as its hello proof, reads the
  log, opens every epoch as the account leaf (replaying commits from the
  account's leaf), commits itself into the tree once caught up, drops the
  account key, and, after paths 2 and 3, registers this device's platform
  passkey as another wrapper so the next sign-in is path 1. One account-key
  holder enrolls a device into any number of spaces in one step. `0ndb
  login` is the CLI device-code flow (approval code, or a browser passkey
  acting as approver).
- **Devices** keep their own device key behind a `Keystore` plug
  (`src/keystore`: Secure Enclave on macOS, TPM via the Platform Crypto
  Provider on Windows, TPM 2.0 via `/dev/tpmrm0` on Linux, a 0600 file
  otherwise) and never need the passkey again. A lost device is
  `device_remove`: every space removes it and starts a new epoch.
- **Fallbacks** (settings only): `0ndb join` prints the device's card;
  `0ndb pair CARD` on a member adds it (`Add` with a seal of the current
  epoch) and prints a ticket; `0ndb join TICKET` enrolls with that proof.
- **Custodian** remains a mechanism, not a default: a custodian is a leaf
  member whose key lives in the embedder's service (KMS, HSM, enclave) and
  which signs `Add`s for devices it authenticates. Switching a space between
  custodian and pure E2EE is adding or removing that member, which is a new
  epoch sealed or not sealed to it; no data moves.

- **Identity providers are the embedder's.** Subjects are opaque bytes; the
  engine has no org or user model, and which spaces belong to which subject
  is whatever the embedder records. When the provider runs WebAuthn with PRF
  itself (one ceremony for sign-in and unlock), it evaluates PRF with
  `account_idp_salt(subject) = BLAKE2b-256("0ndb idp prf salt" ‖ subject)`
  and passes the credential and output to `account_login_prf`;
  `account_passkey_add_prf` registers such a credential as a wrapper.
- **Org-managed membership.** An embedder backend may hold an admin member
  for an org's spaces (`kind directory`, a leaf, its key behind the host's
  keyring the way the pool key is), added once by an owner. Directory events
  then call `directory_add(space, person, role, devices)` (an account-kind
  member plus devices with `method directory`, each `Add` carrying a seal of
  the current epoch) and `directory_remove(space, person)`, which removes the
  person and every device whose `person` is it in one commit, forcing a new
  epoch. This admin reads whatever its role covers, the same trust trade-off
  as the pool; spaces without it stay strictly device-only end to end.

**PRF support** (WebAuthn `prf` / CTAP2 `hmac-secret`, November 2026; checked
on macOS 26.4 with the Xcode 26.5 SDK headers, and on Windows 11 25H2 build
26200, `webauthn.dll` API version 9):

| Provider | PRF create / get | Synced | Same output on every device | Since |
|---|---|---|---|---|
| iCloud Keychain (Safari, Chrome, native AuthenticationServices) | yes / yes | yes | intended; mismatches reported across OS versions and over hybrid in 2026 | macOS 15 / iOS 18, hybrid fixed 18.4 / 15.4 |
| Google Password Manager (Chrome desktop, Android) | yes / yes | yes | yes (`hmac_secret` synced) | Chrome 116 |
| Windows Hello (Chrome/Edge 147+, Firefox 148+) | yes / yes | no, device-bound | n/a | build 26100/26200.7840 |
| Microsoft Password Manager | yes / no | yes | n/a | — |
| 1Password (extension, Android, iOS 18+) | yes / yes | yes | yes | 2024-07 / 2025-04 |
| Bitwarden | partial / partial | yes | no | — |
| Security keys (YubiKey 5) | via hmac-secret | no | n/a | Safari 26.4 |
| Firefox desktop | yes / yes | provider | provider | 139 |

Consequences: decryption success (the AEAD tag) is the only proof of PRF
support; each credential gets its own salt and wrapper; user verification is
always required (hmac-secret keeps separate with/without-UV secrets); and
because Apple outputs are not reliably identical across devices, path 2 is a
working default, not a rarity.

### Local-only mode and the transitions

With no account, relay or passkey a device still creates spaces (a genesis
and epoch 0 held by the device), and every feature that needs no other device
works: conversations, agents, queue and steer, branches, file trees, search,
catalog. Every write is recorded as pending upload exactly as when online.

- **Local to synced.** On sign-in (or when an embedder attaches an account)
  every local space gets the account's home relay, an account `Add` and a
  commit (epoch 1, with a back link to epoch 0), a manifest entry, and the
  pool if the account has one. Pending segments upload from their existing
  offsets; nothing is rewritten, and history written before sign-in stays
  verifiable (same signed chains, keys sealed under epoch 0, reachable from
  epoch 1).
- **Synced to local.** `account_sign_out` / `0ndb logout` drops the account
  state, closes the approval link and detaches the relay; every space keeps
  its local copy and keeps working local-only. Objects this device never
  fetched remain remote-only until it signs in again.

### Runner pools

A runner pool is one member (`kind pool`, leaf) per account, added on the
first sign-in with one consent and included in every epoch of every space
whose access level is *Everything* (default) or added to a workspace scope;
*Off* never includes it. The pool key lives with the embedder's host behind
the `Runner_Pool` plug (`identity`, `verify(token, runner) -> lease`,
optional `attest`, `joined`); the host's engine keyring may be a KMS that
signs and unwraps on request, so the backend never holds raw key bytes.

- **Enrollment.** The host launches a runner with a short-lived token. The
  runner makes its own device key and sends its card and the token; the host
  (`pool_enroll`) verifies the token, and for every space where the pool is a
  member appends `Add{runner, kind runner, method pool, lease_ms, seal =
  epoch id ‖ epoch secret ‖ N sealed to the runner}` and returns those
  records; the runner presents them as hello proofs (`runner_enroll`).
  Enrollment is idempotent (an active runner gets its existing `Add` back)
  and crash-safe (the proof is carried until the runner's own stream holds
  it). The runner renews with `Renew` records on one timer (its only armed
  timer); a lapsed lease is refused by the relay. Runners are not leaves: no
  epoch rotation per runner. On a rotation the host `Seal`s the new epoch to
  its live runners.
- Runners never authorize runners: devices and runners only write placement
  requests; the host launches and enrolls. Per-run scoped grants (capability
  tokens plus `Share`s carrying object epoch keys) remain only for
  third-party runners outside a pool, with no re-delegation.
- Every device sees runner enrollments (`Runner_Enrolled`) and gets
  `Runner_Anomaly` when more than `Config.runner_alarm` enroll in a minute.
  Attestation is a future `attest` plug in enrollment, not part of the
  default path.
- **Threat model.** Relay or storage compromise reads nothing (content keys
  never reach them; the log they see is identities and roles). Compromise of
  the host plus the pool key reads what the pool can read (spaces with access
  Everything or its scope) and nothing else, and can enroll runners, which
  every device sees. Nobody can forge device-signed history (segments are
  hash-chained and signed by their writers; the pool key signs only pool
  records). The model provider sees what is sent to it.

**Device-only storage.** The membership log and keys streams are relay-stored
metadata even for device-only objects.

**Costs** (measured, x86-64, `-o:speed`): a normal append is unchanged (same
per-record key derivation, nothing added per record); a writer's first append
in a new epoch republishes its key tree once (~1.5 KB). Membership change on
a filled tree: removal commit 129 B / 571 B / 1.8 KB and 0.03 / 0.36 / 1.3 ms
to create at 2 / 10 / 1000 members (0 / 4 / 16 ciphertexts); each receiver
opens one ciphertext. Resolving a 1000-member log (~2000 records) takes
~1.4 ms. Bulk-adding 1000 members into an unfilled tree in one commit is
O(n) (152 KB) by nature; joiners commit their own path, which fills the tree.
Sign-in by recovery key with every other device offline: 148 ms for the call
(Argon2id dominates), first history page about 1 s later; approval sign-in
completes within one round trip of the approve.

### Relay storage: store small, deduplicate big

Relay cost tracks the reachable information, not the activity. Items marked
(planned) are designed here but not yet built.

- **Default policy.** Conversations, maps and all metadata are relay-stored,
  so any conversation can move to a new runner with every original device
  offline. Record bodies are zstd-compressed (level 3, no dictionary) in the
  obj envelope before sealing, so offsets and lengths are identical
  everywhere and each record stays its own redaction unit; content
  dictionaries are not used for relay records because a trained dictionary
  would retain redacted text. Measured on a real tool-heavy agent
  transcript (2769 messages, 4.4 MB of text): zstd alone gives 0.75 MB
  (level 3) to 0.60 MB (level 19). Recording it grew the pack-backed relay
  by 34.5 MB, attributed below under "Cost tracks reachable information".
  A 12-message chat is 3.8 KB of text, 1.6 KB
  compressed. File trees of git repositories store on the
  relay only what the git remote lacks (below). Large unique content that is
  in no git remote is relay-stored up to a per-space budget
  (`Config.content_budget`, the `Storage_Policy` plug); beyond it it stays on
  devices, is replicated to the account's always-on devices (which advertise
  themselves as holders), and is served by the peer pipe. Only reads of those
  exact files can then be unavailable; everything else materializes.
- **Git-backed trees.** A blob is *remote-backed* when it is reachable from
  a remote-tracking ref (`refs/remotes/<remote>/*`) of a remote configured
  in the tree's repository; tree history records reference it (`Insert_Ref`,
  content ops) and its bytes are never uploaded, neither as a content object
  nor inside a checkpoint bundle (the bundle lists it in a `CKPT_REMOTE`
  frame instead). Anything else (uncommitted and unpushed content) is
  uploaded, so a later push strands nothing.
  - *Reachability* (`fs/remote.odin`) is tracked per repository under
    `$DATA/remotes/<hash of the common dir>/`: `state` (HEAD, every tracking
    tip, up to 64 anchor commits) and `oids`, the sorted set of tree and blob
    ids in the anchors' root trees. Anchors are the tips and the merge bases
    of HEAD with each tip (a date-ordered walk capped at 20 000 commits).
    Unchanged refs cost reading the refs (under 0.3 ms on git/git); a new tip
    or a moved HEAD walks only subtrees not yet in the set (13 ms for a local
    commit on git/git, 0.47 s for the first build of its 8 tips); merge bases
    are recomputed only for new or moved tips unless HEAD jumped. A tip that
    is no longer a descendant of its previous value (force-push, prune)
    rebuilds the set from the current anchors only. The test is sound, not
    complete: a blob found only in older history counts as not remote-backed
    and is uploaded.
  - *Where readers learn the remote.* The writer records the public URLs of
    the remotes whose tips it used (userinfo stripped, one per line) in the
    tree's catalog entry (tag 33), so a reader knows the remote before it
    admits any record and independent of record order.
  - *Fetching.* A reader that admits a record whose blobs are missing asks
    the relay first (it answers `Missing` at once for remote-backed blobs);
    the blobs the relay lacks are queued, and once per tick the engine starts
    one `Git_Remote.fetch` per (tree, URL) with every queued oid. Protocol v2
    fails a whole fetch when the server lacks any wanted object, so a failed
    batch is split in halves and retried down to single objects. The reference plug runs
    `git --git-dir=$DATA/objects fetch --stdin <url>` with the oids on stdin
    (protocol v2 serves any existing object by id; negotiation `noop`,
    auto-gc and maintenance off, objects fsynced), so the device store, which
    is a bare repository, receives exactly the wanted blobs as one pack.
    The `Git_Credentials` plug adds environment for the child (an
    `http.extraHeader` through `GIT_CONFIG_*`, `GIT_SSH_COMMAND`), either
    synchronously (`env`) or as a resumable request (`begin` with a
    completion, `cancel` on shutdown; the fetch starts when it completes,
    and a refused request starts it without extra environment); without it
    git uses the user's own credential helpers, and prompting is disabled.
    Whatever the remote did not return goes to the next URL, then the relay,
    then the object pipe.
  - *Rewrites.* Blobs that a rewrite made unreachable stay on their holders
    (the scope commit chain pins them) and are pulled through the object
    pipe on demand; with no holder online the read reports `Unavailable`.
  - *Measured* (Linux, loopback relay, local bare remote; three devices
    on one host, the writer stopped before the fresh device starts).
    git/git (4876 files, 62 MB, two unpushed commits and four uncommitted
    edits): the relay holds 2.85 MB instead of 108.5 MB; a fresh device with the writer offline
    materializes it in 3.4 s, about 4750 blobs in one 13 MB pack from the
    remote and the edits from the relay (2.9 s from the relay alone without
    deduplication). A GitHub checkout (75 files, one uncommitted edit, https
    remote, no credentials): the relay holds 104 KB and a fresh device with
    the writer offline materializes it in 0.43 s from github.com. A small
    pushed repository with two untracked 24 MiB binaries and a 30 MiB
    budget: the relay stores 25.5 MB (one binary); an idle always-on device
    (no mount, the tree never opened) holds the other 0.26 s after it signs
    in, pulled through the pipe; with the writer offline a fresh device
    materializes everything, that binary from the always-on device, in
    0.45 s; with every holder offline everything but that file materializes
    and it arrives 0.23 s after the always-on device's daemon starts again.
    The git/git and GitHub fresh-device trees are byte-identical to the
    writer's checkout, CRLF (`eol=crlf`) files and the uninitialized
    submodule's empty directory included.
- **Storage classes and modes.** Each object has a class: `stored` (segments
  on the relay) or `device` (the relay keeps only segment lengths). The class
  is the catalog field `storage` (tag 12: 1 device, 2 stored, absent: policy),
  so every device agrees and session lists can show it. `Config.storage`
  selects the reference policy: `auto` (default: everything stored as above),
  `stored` (everything, no deduplication; pool runners), `until_run`
  (conversations, texts and trees device-only until a pool runner is
  assigned, then promoted) and `device` (strict device-only, for privacy,
  never promoted). A `Storage_Policy` plug overrides per space and object.
  Maps, keys streams, cards, the feed, presence, the redaction log and the
  membership log are always stored.
- **Hollow segments.** On the relay a segment has a `base` and a `length`;
  content is stored for exactly the contiguous suffix `[base, length)`. A
  device-only segment is fully hollow (`base == length`): its writer
  advances the length with `Note` instead of `Append`, and the relay persists
  only the length (a based storage slot). Appending to a hollow segment
  stores content from the old length on; `Fill` stores ciphertext backward
  from `base`, so stored content stays one suffix, uploads resume from the
  relay's `base` and nothing is uploaded twice. Offsets are the writer's, so
  ids never change. The relay never reads below `base`: reads, tails and
  follows are clamped and preceded by a `Hollow` frame with `base` and
  `length`. Feed compaction keeps the hollow flag.
- **Content budget.** Large content is content-op (opaque) blobs: binaries
  and files over the mount's large limit. A device uploads such a blob, when
  it is not remote-backed, only while the space's budget allows
  (`Config.content_budget`, default 1 GiB, or `Storage_Policy.budget`).
  Usage is space-wide: every device keeps its own row in the space map
  `0ndb:holders` (tag 1 flags, bit 0 *always-on*; tag 2 bytes it stored on
  the relay under the budget) and a device sums the rows before uploading,
  so concurrent devices can overshoot by at most one blob each. Over-budget
  blobs stay on their devices and are served by the object pipe.
  Devices with `Config.always_on` advertise themselves in the same map, and
  every reader adds them to a blob's holders. A writer that keeps a blob off
  the relay for the budget records it in the space map `0ndb:held` (key: the
  blob id; tag 1 the tree, tag 2 the size). An always-on device follows that
  map's segments in every space it belongs to, without opening the trees,
  and whenever it grows (and on connect) pulls each listed blob it lacks
  through the usual content path (relay, remote, then the pipe), up to
  `Config.holder_budget` bytes (default 8 GiB, negative: no limit); arrivals
  are registered for serving. Nothing polls: the work runs on the map's
  growth and on reconnects. Records are admitted without their opaque blobs:
  materialization skips exactly those files (they are recorded as *absent*
  in the mount state and retried when content arrives, before any disk
  change, so a skipped move never leaves a path the shadow does not know),
  and only those files wait.
- **Checkout form.** A writer mounted in a git checkout records file
  contents in git's clean form (attributes, `core.autocrlf`, filters) and
  marks each such file with the fstree flag `Git_Clean` (bit 3), setting it
  on files it creates and on files it rewrites that lack it. Any mount
  applies the checkout conversions to flagged files when it materializes
  them and the clean conversions when it ingests them, with the tree's
  `.gitattributes` and the device's own git configuration, even when its
  directory is not a git checkout, so a fresh device writes the same bytes
  as `git checkout` there; unflagged files are written as stored. A gitlink
  in the writer's index is recorded as an empty directory that ingest never
  descends into, which is what `git checkout` leaves for a submodule that is
  not initialized.
- **Object pipe.** A content get that the relay answers `Missing` becomes a
  pull from the blob's holders: the tree's participants and the always-on
  devices, filtered by presence. It uses the existing `Pull`/`Serve` frames
  with the object's (part) key in the `segment` field; the relay forwards
  them like a segment pull and reads nothing. The holder resolves the key
  through its registry of objects it chose not to upload (remote-backed,
  device-only, over budget; one entry per key and per part of a chunked
  object), seals exactly the sealed chunks of the requested aligned range as
  a `Put` would (blobs of 8 MiB and more are streamed once into
  `$DATA/serve/` and read by range) and answers in at most 256 KiB frames
  without record framing, 127 sealed chunks per pull. The reader decrypts
  and verifies each chunk with the object key exactly as a relay-served
  object; a bad holder is skipped and `Peer_Misbehaving` reported. With no
  holder online the engine emits `Unavailable{object, device}` per holder
  and keeps the read pending; a presence `up` re-pulls. Device-only trees
  upload neither blobs nor checkpoints.
- **Peer serving.** A reader that needs a range below `base` pulls it from a
  holder: the segment's writer or another device with segments in the same
  object, filtered by presence. Up to four 1 MiB pulls per segment are in
  flight, each to the least-loaded holder, so a large fetch spreads across
  every online holder. A holder down in presence, or an `Unserved` answer,
  re-pulls elsewhere at once. The holder answers from its journal (sealing
  each whole record exactly as an upload would, serving only durable bytes;
  it finds the first record boundary at or after the range start from its
  length, trailer and offset-keyed checksum, or walks back from the end) or
  from its replica (already wire form), in frames of at most 256 KiB cut at
  record boundaries, with at most 4096 pulls queued. The reader
  verifies the bytes exactly as relay-served data (AEAD per record, chains,
  signatures); a frame interleaved mid-record with another stream's frame is
  carried per segment, not refetched. A holder can withhold but cannot
  alter: bytes that fail verification are dropped, the holder is skipped for
  that segment until its presence changes, `Peer_Misbehaving` is reported
  and the relay is not blamed.
- **Unavailable.** When no holder of a hollow range is online the reader
  re-probes the relay once (a promotion may have stored it), then reports
  `Unavailable{segment, from, to, holders}`; the engine emits
  `Unavailable{object, device}` per holder and keeps the read pending, never
  failing it. A presence `up` re-pulls at once, the read completes by itself
  and `Available{object}` follows; nothing polls and no timer is armed.
- **Promotion** (`until_run`). When the runtime assigns a run to a pool
  runner (its advert in the runners map carries field 3 `pool`), the
  assigning device promotes the conversation and every mounted tree
  (`object_promote_run`): it records `storage = stored` in the catalog,
  switches its own segment to appends, and fills every segment it holds
  backward from the relay's `base`, tail first, down to exactly what the run
  reads. For the conversation that is, per segment, the oldest record on the
  answered message's path (walked with `page`), and the segment's last
  record (its tail summary) for segments with no message on the path. For a
  tree the device writes and publishes a checkpoint at its current length,
  fills its own segment from that length, and uploads the blobs referenced
  from there on that are not remote-backed; the checkpoint bundle carries
  the rest. Pending promotions are durable in the
  registry and resume after a restart. A writer that still notes a filled
  segment gets `Noted` with `base < length` and switches to appends.
- **Redaction** is metadata: it is applied to the stored suffix (if any) and
  always appended to the redaction log and the feed, so every device
  zero-fills its device-only copies when it follows the feed.
- **Measured** (reference relay, loopback, one Linux host, holder and
  reader replicators sharing one thread, kernel TLS off). A device-only
  segment costs the pack-backed relay about 840 bytes on disk (its length
  slot, one feed entry and container overhead; 200 segments of 20 KiB:
  168 KB versus 4.3 MB stored) and 40 bytes per further note until feed
  compaction folds them; the file-store relay keeps a 576-byte slot file per
  segment. 64 MiB through the peer pipe took 1.3 to 1.5 s against 0.6 to
  0.8 s relay-served; a 64 KiB tail 3 to 8 ms. Forwarding cost the relay
  1.25 to 1.6 ms of CPU per MiB, relay-served reads 1.9 to 2.5 ms per MiB
  with user-space TLS. A read waiting on an offline holder completed 15 to
  110 ms after the holder reconnected. A 64 MiB promotion was then read by a
  new device with the writer offline in 0.5 to 0.7 s.
- **Cost tracks reachable information.** Measured attribution of the
  transcript above (2769 messages recorded one `record` call each, so one
  commit per message; pack-backed reference relay; bytes on the relay after
  minus before):

  | Item | HEAD | after defrag fix |
  |---|---|---|
  | Conversation segment: Block 4.68 MB (4.40 MB text + 0.29 MB framing), Msg 0.38, Seal 0.30, Recorded 0.33, Spine and Forks 0.015, signature records 0.81 (one per commit, 294 B) | 6.53 MB | 6.53 MB |
  | Catalog map: 2771 Activity puts 0.18 MB + 2772 signature records 0.53 MB | 0.71 MB | 0.71 MB |
  | Placement `pending` map: 2215 puts and clears 0.31 MB + signatures 0.43 MB | 0.74 MB | 0.74 MB |
  | Announce feed: 40 B per append, folded only at 64 MiB | 0.30 MB | 0.31 MB |
  | Keys, cards, key trees, slots | < 3 KB | < 3 KB |
  | Pack container: small-stream rewrites by defragmentation | about 19.4 MB | about 2.0 MB |
  | Pack container: pre-promotion copies, length slots, usage file, inode, stale and commit records | 6.5 MB | 7.2 MB |
  | Pack index runs and superblock | 0.43 MB | 0.46 MB |
  | Total | 34.5 MB | 17.8 MB |

  Not on the relay: raw provider lines (the local `raw/<object>` journal is
  never published; drivers re-read it locally) and padding (off by
  default). The 24-byte record envelope is 5% of the segment. The pack
  container is garbage that compaction reclaims once a container is no
  longer active (live ratio under one half), so it is bounded rather than
  cumulative, but it is written per append: each relay append writes the
  data, the stream's length slot, the feed entry, its slot and the usage
  file, each with an inode record. Everything in the first four rows is
  cumulative: it grows with activity and is never collected. Catalog
  Activity puts are also the change trigger runtimes evaluate on (catalog
  deltas queue evaluation), so they cannot be thinned: a 60 s grain cut the
  relay to 9.4 MB and stopped placement evaluation entirely. The cumulative
  rows are what segment archives (below) collect.

  Compression of the whole history is what the reachable information costs:
  the segment's non-signature records concatenated compress to 1.12 MB at
  zstd level 3 and 0.89 MB at level 19 (1.5 and 1.2 times the 0.75 MB of
  the bare text), the catalog's 712 KB to 7.6 KB and the pending map's
  735 KB to 26 KB. Per-message compression without a dictionary gives
  2.28 MB for the text alone, a self-trained 110 KB dictionary 1.43 MB, and
  groups of 64 KiB, 256 KiB and 1 MiB of consecutive messages 1.02, 0.85
  and 0.79 MB. The target of 1 to 1.5 times the text's zstd size is
  therefore reachable only with cross-record compression of history plus
  collection of the cumulative rows; per-record compression of the live
  tail is a constant factor on top.
- **Per-record compression.** Every obj record whose fields are at least
  128 bytes is compressed on its own with the pinned zstd (level 3, no
  dictionary) before it is appended: leading fields under 64 bytes stay
  raw (links tag 6 their length) and the rest is one frame (links tag 5 its
  raw length), kept only if it saves an eighth. The stored form is the only
  form, so the local journal, the wire (ChaCha20 over the same bytes), the
  relay and replicas keep identical offsets and lengths; chain links,
  signatures, tags, fetches and redaction act on stored bytes, and
  redaction still zero-fills the whole record, which is the redaction
  unit, so it stays exact. Readers inflate in `convo.decode_env` and
  `map.decode_body`; decoding is size-checked and bounded. The browser
  links a wasm32 build of the same zstd (68 KB). Measured on the
  transcript: Block records 4.68 to 2.59 MB, relay 17.8 to 15.9 MB;
  compress 7.6 ms and inflate 2.6 ms per MB.
- **No content dictionaries.** A trained zstd dictionary copies verbatim
  segments of its samples, so redacting a sampled message would leave its
  bytes in the dictionary, and retiring the dictionary makes every record
  compressed with it unreadable unless it is rewritten, which durable
  records never are. Dictionaries are therefore not used for relay records;
  cross-record redundancy is captured by segment archives instead, whose
  redaction is exact (below).
- **Live drafts.** Streaming text never enters a segment as chunks and the
  relay never stores a byte of it. A draft is the live preview of a message
  its writer is still streaming. The sealed Blocks in the conversation
  segment are the only durable copy.
  - *Writer.* `convo.Writer` keeps one local draft journal per segment
    (`<segment>.draft`, a pack stream, in the journal record format). Every
    group commit appends the open block's new bytes as a
    `Draft{msg, prev, block index, offset in block, start meta, bytes}`
    record, where `prev` is the offset of the message's previous draft
    record. The segment commits first and the draft commits second, in the
    same tick, so a draft record is never durable before its Msg record. A
    block's text reaches the segment only at block end (the next block,
    flush or seal) as ordinary Block records, plus a 16 KiB `CHUNK_MAX`
    overflow that bounds the writer's buffer. Any other record the writer
    appends mid-block first flushes the block. Once the batch is durable,
    the engine reads the new draft records, seals each one end to end
    (ChaCha20-Poly1305, nonce = draft offset) under the message's draft key
    and sends `Live(segment id, msg, at, records)` (relay protocol 8.15).
    It sends only durable bytes. Once a seal or `Interrupted` is durable,
    its message leaves the draft. When no live message remains, the draft
    journal is removed and its generation bumped (pack zero-fills a
    destroyed stream's extents).
  - *Relay.* `Live` is forwarded at once as `Lived` to every connection
    with live interest in that segment (`Follow` with the LIVE flag), and
    nothing else happens: no storage, no feed entry, no acknowledgement, no
    fsync. Streaming therefore costs the relay zero stored bytes, and the
    relay's group commit leaves the token path. A token used to reach a
    reader after the writer's tick commit, the relay fsync, a feed
    `Announce`, the reader's `Read` and `Data`. Now it arrives after the
    writer's tick commit plus one forward.
  - *Readers.* A subscribed conversation live-follows every other
    participant's segment. Incoming records are opened with the draft key
    and must chain by `prev`. A reader that joins mid-stream, reconnects,
    restarts, or sees a gap (an unknown key, or a `Lived` the relay skipped
    under backpressure) fetches the missing records with a draft pull: a
    `Pull` whose `from` is `DRAFT | msg`, answered by the writer over the
    peer pipe from its draft journal. The answer starts at the first record
    of the block still open and contains only durable bytes. Drafts live
    only in reader memory, as `Draft_View` per open message and capped at
    4 MiB. A reader never writes a draft to disk. Subscription deltas merge
    segment and draft text per block: a block's text is the contiguous
    union of prefixes from both sources, and each byte is delivered once
    whichever source brings it first. A view is dropped when the segment
    shows the message closed (seal, `Interrupted`, or revival declined),
    or when its draft key stops deriving (redaction).
  - *Draft key.* `draft_key(msg) = HKDF(K(c), "0ndb draft key" ‖ u64 msg)`,
    where `K` is the segment's key provider (the writer's GGM key tree, or
    the stream key) and `c = (msg >> 4 + 1) << 4` is the cell right after
    the one where the Msg record starts. Proof that it never collides with
    a real record's key:
    1. A record's key is `K` of the cell that holds its start offset.
    2. The writer drafts a message only if its Msg record is at least
       `DRAFT_MSG_MIN` = 32 bytes long (otherwise the message streams the
       old way, as chunks in the segment). The record therefore covers
       `[msg, msg + 32)`, which includes all of cell `c`, since `c ≤ msg + 16`
       and `c + 16 ≤ msg + 32`.
    3. So no record starts in cell `c`, and `K(c)` is never used directly.
    4. `draft_key` is HKDF of `K(c)` with a label no record key uses, and
       distinct messages have distinct cells `c`.

    Within one message the draft nonce is the draft offset, unique because
    the draft journal is append-only and only durable records are ever
    sealed. A reset journal restarts offsets only after every message in it
    has closed, and a closed message never streams again. So no (key,
    nonce) pair ever carries two plaintexts. The simulator's cipher watch
    taps `Live`, `Lived` and draft `Serve`/`Served` frames as their own
    channel per (segment, msg) and reports any reuse.
  - *Redaction.* Drafts never reach a search index: indexers read only
    segment records, so the index can hold only text that was finalized
    into Blocks. Redacting a message whose writer is this device flushes
    any open block into the segment, zero-fills the message's draft
    records, punctures cell `c` in the writer's tree, republishes the
    tree, redacts every Block of the message and, if the message is still
    open, seals it `Cancelled`. Nothing of it can be written afterwards,
    by the stream or by crash recovery: zero-filled draft records are
    skipped when the writer reopens. Redacting another device's message
    also appends `Redact_Msg{msg}` (convo kind 44) to the redactor's
    segment, next to the `Redact` records for the Blocks it can see. A
    message that is still streaming may have none of its text in the
    segment yet, and a redactor's replica may lag. The writer applies
    `Redact_Msg` in the durable remote-record scan (`_scan_object`, the
    same persisted cursor that applies remote `Redact` records). It runs
    the own-message redaction above, which covers draft text, blocks the
    redactor never saw and blocks written later. Every other device purges
    its index for the message and drops its view. Before this,
    redacting an open message from another device left its later Blocks
    unredacted and indexed everywhere (sim `SIM_STORAGE=device
    SIM_SEED=3`). Captured draft ciphertext is undecryptable everywhere
    once the cell is punctured. The relay never held the draft, so
    nothing is redacted there.
  - *What a draft promises.* Every byte a reader sees in a draft was
    durable in the writer's draft journal before it was sent, and its Msg
    record was durable in the segment. The sealed block is a function of
    the segment alone: Blocks chain only to their message and earlier
    Blocks, and no segment record refers to a draft offset. So a lost,
    dropped or never-seen draft changes nothing durable, and readers that
    saw draft text converge on the sealed block because both are prefixes
    of one buffer. A draft is a preview, not a durable record. If the
    writer's disk is destroyed mid-stream, its preview is gone, and with it
    the only device that could have sealed the message.
  - *Writer crash.* `writer_open` replays the draft journal. Each still-open
    message's draft text beyond what its Blocks hold is appended as final
    Blocks before anything else is written. Recovery's `Interrupted` (and
    the revival's new reply, which reads this transcript; the provider's
    raw lines stay local and resume its native session) therefore ends with
    exactly the text readers saw. A reader of a writer that died keeps its
    preview, with no timer and no pending read, until the segment shows
    `Interrupted` or the revived run's seal. It never waits on a draft:
    pulls to an absent writer are answered `Unserved` at once.
  - *Measured* (reference relay on loopback, two daemons on one Linux host,
    `0ndb log --follow` on the reading device). A scripted Claude stream-json
    provider sends 40 text deltas per second, about 470 B/s of text. Before,
    with chunks in the segment, the relay's stored bytes grew 12.0 KB per
    streaming second (180 KB for a 15 s turn) and its disk 85 KB per second.
    With drafts the turn costs a constant 10.2 KB (the user message, the
    final compressed Block, the seal, signatures and catalog) at 15 s,
    11.2 KB at 30 s and 17.8 KB at 60 s. The only growth is the final text
    itself, compressed, as 16 KiB overflow Blocks: about 0.17 KB per
    streaming second and no framing. End-to-end token latency from the
    provider line on the writer to the reader's delta: p50 12.5 ms and p90
    15.5 ms before, 3.7 ms and 5.1 ms after; p50 4.4 ms over a 60 s
    stream. With real Claude (haiku, a 350-word answer), cross-device
    latency (the same byte offset on the writer's and the reader's
    subscriptions): p50 10.6 ms and p90 17.2 ms before, 2.6 ms and 6.0 ms
    after. The relay grew 375 KB versus 312 KB for that turn; about 300 KB
    of both is outside the stream.
- **Segment archives.** A writer archives a closed prefix `[0, B)` of each
  of its segments (conversations, maps, texts and trees alike) into its own
  archive stream `arc/<segment>` (same device and epoch, so any reader
  derives its id), then drops the stored prefix with `Trim`. No mapping
  exists: offsets stay the record ids, and the archive reproduces every
  archived record's exact stored body at its original offset and length.
  The format (`src/arc`, built):
  - *Group* record: kind 1, version, `first`, `end`, record count, the
    segment chain heads before `first` and after `end`, mode (plain for
    transparent spaces, sealed otherwise), the key-tree cell shift and a
    16-byte random salt, then one zstd frame (level 19), sealed with
    ChaCha20-Poly1305 under the group key with the header as associated
    data. The frame holds a metadata section (per record: kind and stored
    length; for a redacted record its 32-byte chain commitment; for a
    record whose body ends in a per-record zstd frame, the raw prefix and
    the inflated length; small structured bodies verbatim) followed by a
    data section of inflated text, so text compresses against text. A body
    is stored inflated only if recompressing it with the pinned zstd at the
    per-record level reproduces the stored frame byte for byte, checked
    when archiving; otherwise it is kept verbatim. Signature records are
    elided (kind and length only): they are not part of the chain, and the
    writer-signed archive replaces their role. Groups close at 1 MiB of
    raw content.
  - *Group key*: BLAKE2b over the domain, `first`, `end` and the key of
    every key-tree cell in `[first, end)`, then keyed BLAKE2b of the salt.
    A redaction punctures a record's cell, so after any redaction inside a
    group its key is underivable on every device and the relay never had
    it; the salt makes every (key, nonce) pair unique even if a group is
    re-archived with different compression. Readers need no layout before
    decrypting. Correction of the earlier design: a key from the group's
    record keys alone cannot be derived without knowing which records the
    group holds; the cell grid needs nothing but the range.
  - *Seal* record: kind 2, `B`, the segment chain head at `B`, and the group
    index (first, end, archive offset per group, delta coded). A seal holds
    every entry since the last full seal and is full again once its delta
    reaches half the full index, so a reader finds any group with two reads
    (the tail and the last full seal) and the index costs O(groups)
    overall. A later entry for the same `first` supersedes an earlier one.
  - The archive stream itself is an ordinary chained, signed journal
    (plain at the journal layer, since groups carry their own AEAD), so
    the relay can withhold but not alter it, and it is never archived.
  - *Verification*: a reader opens a group, recomputes each body's chain
    commitment with the segment's keys, takes redacted records'
    commitments from the group, folds from `head_before` and must reach
    `head_after`; the seal's head must equal the head of the stored suffix
    at `B` (the first stored signature's `prev_head`). Two different heads
    are equivocation.
  - *Materialization*: verified records are written into the reader's
    sparse replica in wire form (resealed per record with the segment key
    at the same offset, which reproduces the writer's ciphertext exactly),
    signature records as redacted-form placeholders; the replica records
    the range as archive-verified so chain checks there use the archive.
    Paging both ways is unchanged.
  - Measured on a 4.16 MB synthetic tool-heavy transcript (2,769 messages,
    sequential repository source and agent text; zstd -3 1.03 MB, -19
    0.77 MB) recorded through `0ndb record`: the conversation segment's
    3.92 MB (0.81 MB of it signature records) archives to 1.20 MB in
    5 groups (1.30 MB with 256 KiB groups, 1.22 MB at level 9), the
    catalog's 713 KB to 7.6 KB; every record round-trips byte for byte.
    Archiving costs 80 ms per MB of segment (most of it the
    recompression check), reading 30 ms per MB, both off the append path.
  The rest is the planned integration. Runs start once enough acknowledged
  bytes accumulate past the last seal; `B` is a commit boundary strictly
  below the relay's length, so a trimmed segment always keeps one stored
  commit and never looks device-only. `Trim{segment, B}` is sent only once
  the seal is durable on the relay and is idempotent, so a crash anywhere
  leaves the segment whole and the run is resumed or redone. Redaction: a
  record inside a group cannot be zero-filled alone, so the redactor (any
  member: it holds the keys) writes `Restore{group ref, the group without
  that record, the removed record's commitment}` into its own segment of
  the object, then the group is zero-filled and its key punctured
  everywhere; readers of the other records of that group resolve them
  through the restore, verifying them against `head_after`, and the
  writer's next archive absorbs the restore. Nothing other than the
  redacted record is lost and its bytes exist nowhere. Every version
  reachable from a message is kept; superseded run lines and runs,
  deleted forks and redacted content are collected the same way.
  Cold-tier movement is a `Relay_Storage` hint.
- **Relay write amplification.** The usage counter is written once per
  group commit, not per append; the feed is folded when it exceeds twice its
  last folded size (64 KiB floor); and the relay's pack rolls its active
  container when half of it is garbage, so compaction reclaims it promptly.
  (planned) Pack-backed relay streams need no length slots once the pack
  buffers appends until their own commit, so a partial append can never
  become durable through another space's commit.
- **Relay writes** are host-chosen and never protocol-visible: an append is
  acknowledged once durable in the host's durable buffer (group-committed
  local files for the reference relay, Durable Object storage for a DO host)
  and any object-store flush is coalesced per space and asynchronous. With
  `--objects` the reference relay's tiered store writes one batch object per
  space per window (`--flush-ms`, default 2000) or every `--flush-mb` MiB
  (default 8); a per-space manifest in the pack, marked dirty in the same
  group commit as a window's first change, makes the tier crash-safe, and a
  redaction rewrites the batch objects that hold the range. The relay counts
  per space stored bytes, appends, notes, fills, pulls, piped bytes,
  object-store writes and bytes, pending bytes and client bytes per UTC day
  (`Relay_Space_Stats`), served to members by the `Account` frame (feature
  bit 0 of `Welcome`) and to embedders by the C API op `space.relay_account`.

### Relay messages for storage classes

All integers little endian; `segment` is a 32-byte stream id, `device` a
16-byte device id. Frames are `len:u32 kind:u8 payload`; bulk frames carry a
fixed part then `len - fixed` content bytes. None of this depends on the
host: a relay core needs per-space state only (stream lengths and bases, and
open pipes), and `sendfile` remains an optimization of relay-served `Data`.

Client to relay:

- `Note` (0x11, 40 bytes): `segment, length:u64`. Owner only (`Append`
  access). If the segment is new or fully hollow and `length` exceeds its
  length, the relay persists the new length (`base = length`) and appends
  the feed entry `(segment, length | 1<<61)`. Reply `Noted`. A segment with
  stored content is not changed; the reply shows `base < length`.
- `Fill` (0x12, bulk, fixed 40): `segment, at:u64`, then ciphertext for
  `[at, at + n)` where `at + n` must equal the segment's `base` and
  `n <= APPEND_MAX`. Members only (`Fill` access: the space credential, not a
  share grant). On success `base = at`; reply `Noted`. A mismatched `at`
  answers `Noted` with the current `base` and stores nothing (the uploader
  resumes from there); quota applies as for appends.
- `Pull` (0x13, 72 bytes): `holder:device, tag:u64, segment, from:u64,
  to:u64`. `segment` may also be a content object's (part) key; the relay
  does not distinguish the two and the holder resolves it, so the object
  pipe needs no further frames. Requires `Read` access to `segment`. If `holder` has no live
  connection in the space the relay answers `Unserved` at once; otherwise it
  records a pipe `(requester, tag, holder, segment)` and sends `Pulled` to
  one live connection of the holder. At most 64 pipes per requester.
- `Serve` (0x14, bulk, fixed 64): `requester:device, tag:u64, segment,
  at:u64, word:u64`, then at most 256 KiB of wire-form bytes for
  `[at, at + n)`. `word` bit 63 is `final` (last frame of the answer), bit 62
  `none` (the holder lacks the range; no bytes), the low 62 bits the
  holder's length of the segment. The relay forwards it as `Served` only if
  it matches an open pipe from this holder; it closes the pipe on `final`
  or `none` (answering `Unserved` for `none`) and drops unmatched frames.

- `Trim` (0x16, 40, feature bit 1): `segment, base:u64`. Owner only. Raises
  `base` once an archive covers `[0, base)`, frees the stored prefix and
  marks the base as a trim; `base` must stay below the length, a lower or
  equal base changes nothing, and `Fill` below a trim stores nothing. Reply
  `Noted` once durable; no feed entry.

Relay to client:

- `Noted` (0x95, 48): `segment, base:u64, length:u64`, the reply to `Note`
  and `Fill`.
- `Hollow` (0x96, 48): `segment, base:u64, length:u64`, sent before any
  `Probed`, `Length` or `Data` answer about a segment whose `base > 0`.
- `Pulled` (0x97, 72): `requester:device, tag:u64, segment, from:u64,
  to:u64`, to the holder.
- `Served` (0x98, bulk, fixed 64): `holder:device, tag:u64, segment, at:u64,
  word:u64` and the holder's bytes, unchanged, to the requester. The relay
  buffers one frame at a time per pipe and stops reading a holder while its
  requester has more than 1 MiB of served bytes queued.
- `Trimmed` (0x9c, 48, feature bit 2): `segment, base:u64, length:u64`,
  sent instead of `Hollow` when the base is a trim, so the reader reads
  `[0, base)` from the writer's archive stream instead of pulling from peers.
- `Unserved` (0x99, 56): `holder:device, tag:u64, segment`: the pull ended
  without (complete) data because the holder lacks it, left, or was never
  connected. A requester that disconnects simply closes its pipes.

## engine

The runtime: spaces, objects, runs, runners, triggers, channels,
orchestration, attribution, recording and change events, over the plug
points `Vfs`, `Keyring`, `Credentials`, `Transport`, `Authorizer`,
`Relay_Storage`, `Scheduler`, `Spawner`, `Write_Observer`, `Secrets`,
`Model`, `Http`, `Tools`, `Channels`, `Embedder`, `Providers`, `Clock`,
`Log`, `Search_Remote`, `Storage_Policy`. Any engine instance can be a runner or a full
indexer. Live buffers (`buffer_open`, `buffer_read`, `buffer_edit`,
`buffer_ack`, `buffer_undo`, `buffer_redo`, `buffer_anchors`,
`buffer_resolve`, `buffer_cursors`, `buffer_close`) deliver `Buffer_Delta`s
through the subscription callback path at the end of each tick. Several engines can share a process to use several cores, each
owning a shard of objects.

## capi

ABI 2.0: ops are numbered contiguously from 1 in table order (the header op
list is generated from the capi tables); account sign-in, sealed-store and
runner-pool plugs are C callback tables (`ondb_unlock`, `ondb_sealed_store`,
`ondb_runner_pool`) at the tail of `ondb_config`.

`lib0ndb` (shared and static) with `0ndb.h`: opaque handles, plug points as
C function-pointer tables, binary or JSON payloads, no global state, no
callbacks on foreign threads except through the embedder's loop. The read
side (journal, thread, index, crdt, sync client) also builds for
`js_wasm32` so browsers read and decrypt streams directly. Buffer ops are
appended to the op table; deltas and cursors arrive on a buffer
subscription (daemon frame `Buffer`), with the payload
`{buffer, rev, ack, base, ops:[{kind, n, text, author}], cursors}`.

## cli

The reference consumer, assembled from the default plug implementations:
`0ndb daemon | relay | runner | record | mcp | login | approve | devices |
members | remove | rotate | recovery-key | pool | pair | join | status | ls |
new | send | queue | steer | edit | switch | back | log | show | search |
interrupt | models | agent | task | workspace | mount | schedule | blame |
revert | land | share | redact | verify`.
