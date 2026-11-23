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

- **No writer's change is ever lost or silently overridden.** Worktree
  histories have *lines* (named frontiers). Every run writes on its own run
  line forked from its message's version; when its claim wins, the thread's
  line fast-forwards to it. Conversation branches are worktree lines, so
  sibling turns never share files. Two lines only ever combine through an
  explicit land that reports every overlapping concurrent region and refuses
  while any remain. Live editing by people on one line from several devices
  merges character-wise, as collaborative editors do. (planned) A git
  checkout's line is its checked-out branch, and a chat with its shared tasks,
  or two chats in one folder, write one line live: positional edits merge
  character-wise, disk edits line-wise, and any overlap between concurrent
  writers is a recorded, reported conflict region that keeps both texts.
- **No file is ever in a state nobody wrote** (planned for undos, branch
  switches and second chats). Through any sequence of sends, undos, branch
  switches and second chats, every line on disk is a line some write produced
  (an agent, a person, git, an import), and no line splices partial edits of
  two writers; non-overlapping concurrent edits combine as in a collaborative
  editor.
- **Undo is time travel for files and conversations, never for the world**
  (planned). Undoing a turn rewinds its whole task tree (files, the
  conversation, every task's conversation and native session) and keeps the
  undone timeline as a branch. It is owner-scoped: only the tree's own writes
  are undone, so a person's own edits made during the turn, another chat's
  edits and git's survive it. Side effects outside files and conversations
  (deploys, network calls, installs, messages sent, git commits, refs and
  pushes, anything a tool did to the world) are never undone.
- **Nothing in the default flow asks a question** (planned). Branch switches,
  undos and second chats hold, resume and report on their own; choices exist
  in the API for embedders and power users and are never prompted.
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
  is recorded. A reader tells the two absences apart: a cell the loaded
  tree has punctured reads as redacted, which is permanent and safe for a
  derived reader to consume past, while a key the reader does not hold yet
  (its tree for that writer is not loaded) reads as `Need_Keys`, surfaced as
  `Missing`. Every derived reader (the map table, the conversation view and
  index) stops there, keeps how far it got, and resumes on the rekey.
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
  Replay depends on nothing following memory layout: Odin seeds a map's hash
  from its data address, so a map is never iterated in hash order where the
  order can reach I/O, a commit, an emitted event or an ordered result. Such
  loops walk `prim.sorted_keys`; a loop whose order cannot matter (a free, an
  any-check, a unique lookup, a collection sorted afterwards) says so with
  `prim.unordered`. The gate checks every map loop in `src` and `tests/sim`
  for one or the other, and reruns seeds with the sim's allocation regions
  shifted, requiring identical traces and disk images.
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
- Redaction is one in-place change: a `Redact` record names a range,
  and every holder (writer, replicas, relay) zero-fills that body and marks
  the record redacted in its tag slot, keeping lengths and offsets. The
  record's plaintext key was already destroyed by puncturing the key tree,
  so zero-filling removes the only remaining ciphertext.
- Restoring a damaged own record is the other. `journal_restore(off, rec)`
  writes back exactly the bytes the writer appended at `off`, taken from the
  relay copy after it opened as this device's own sealed write (or passed its
  record check in a transparent space), and syncs. It refuses unless `off`
  is below the durable length, the given record is valid at `off`, and the
  record on disk there fails its own check by its own framing, so a valid
  record is never overwritten; the replicator holds the stream's upload
  until the batch holding the restore is durable. Lengths, offsets and the
  chain are unchanged, and the restored bytes are the ones every replica
  already holds. A restore never brings back what a redaction removed: a
  record whose range the redaction log names is written in its zero-filled
  redacted form, a relay copy that still holds ciphertext under a key this
  device's tree has already punctured restores as redacted (it is never
  taken for tampering), and a redaction that lands while a repair is pending
  wins, because `journal_restore` accepts a record that is now validly
  redacted on disk.
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
- Durability follows git's invariant: an object's final name exists only
  once its data is durable. The device store runs deferred: a new loose
  object, or a new pack's data and `.idx`, stays at its temp name, and an
  in-memory staged entry (oid → temp path for loose objects, a loaded pack
  marked staged) serves `exists` and reads; a read from a temp path verifies
  the oid. The loop never syncs them: the pack's commit job takes everything
  staged before it writes its commit record and, on the worker, syncs the
  temp files, renames them to their final names under the odb mutex, syncs
  the directories, and only then writes the record, so every op naming an
  oid becomes durable after the object it names. Staged entries live only
  until that job completes. Everything else that names an oid durably goes
  through the same commit (history journals, checkpoint bundles, mount
  images, which wait for the batch carrying their history) or calls the
  synchronous `barrier`, which installs every staged object first, including
  those an in-flight job holds (pins, refs, scope commits, repack, redact).
  At its first open the engine removes temps in its own name format (prefix
  plus 16 hex digits); no durable record names one, and git's own temps
  (6-character mkstemp names) and other handles' temps are never touched,
  because no other handle sweeps.

## textdiff

Histogram diff over lines (with Myers fallback), unified-diff rendering,
three-way merge (diff3 with conflict markers), and a blame walker that maps
lines through a chain of revisions. Pure functions over byte slices.
`line_edits` emits whole-line edits (narrowed to the edit itself when a hunk
is one contiguous insertion or deletion, `single_edit`) and is what every
writer of CRDT ops from two whole states uses; `byte_diff` refines inside changed lines and serves
only display deltas, which are never stored.

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
  A region has a kind: `Concurrent` (overlapping concurrent edits),
  `Revert` (an undo's alternative, planned) or `Offered` (edits to the
  source of a rename onto an existing name); one accept action takes the
  alternative as copies of its spans, authors kept.

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
  and, when it is not `synced`, the version its content is at (a based
  write's own batch, below, or the pre-pass version of a path a failed
  materialization did not reach). A version is a list of op ids, recorded as
  their count followed by the ids (a count of 0 is `synced`) and interned in
  the shadow's memory while it is attached. An on-disk table (append-only records
  plus an open-addressing hash file), compacted right after a mount state
  save when garbage exceeds half. Only unpersisted changes live in memory.
  The hash file records how far into the log it is covered and whether it
  was closed cleanly; it is trusted only up to that point and the log tail
  is replayed. A replay that fails part way marks the hash file lost: it is
  never checkpointed or marked clean, so a later open replays the tail
  again instead of trusting an index that misses its records. A persist whose
  log write is durable but whose index update fails clears its pending
  changes (they are in the log) and rebuilds the hash file from the log;
  only if that fails is the index marked lost. A lost index is never read:
  every later lookup, change or persist first rebuilds it from the log and,
  while that fails, returns the error, so a pass fails (and stays dirty)
  instead of missing an entry the torn index no longer finds. Compaction carries each
  entry's version into the new generation's own version table, since an
  entry's version index names a table that belongs to one shadow.
  A compaction writes and syncs the whole new generation before it
  publishes `shadow.gen`, and both generations stay complete until a
  directory fsync after that rename succeeds: only then is the old one
  removed. A publish that fails may still have renamed (the page cache is
  not the disk), so the compaction re-publishes the old generation and stays
  on it, never reusing the new one's number; if that also fails the shadow
  detaches and its next attach must publish its generation durably before
  it takes a write. An open uses whichever generation `shadow.gen` names,
  and both are valid.
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
- **Racily clean entries**: a stat signature proves a file unchanged only
  if no write could have landed in the same timestamp tick after the shadow
  recorded it. A file entry recorded while its mtime or ctime is within one
  tick of the recording time (2 s when the mtime is a whole second, which
  covers HFS+ and FAT, else 100 ms for coarse kernel clocks) is marked racy,
  and every comparison that would skip it on an equal stat (an event's pass,
  a rescan, a carried move, materialization's disk check) compares content
  instead. The pass that rereads it records it again, clean once its mtime
  is older than a tick. A watcher event is therefore never dropped by an
  equal stat unless the entry was recorded a full tick after its last write.
- **Ingestion**: for each dirty path compare the stat signature, read only
  changed files, diff against the shadow text by lines (histogram diff; a
  changed hunk is a whole-line delete and insert, unless its new text is the
  old text with one contiguous insertion or deletion, which leaves every
  other byte where it was and is emitted exactly) and append the resulting
  ops as one batch parented on the mount's synced version, credited to the
  actor/scope active at the time of the write (or the writer pid's scope).
  Every source that diffs two whole states is line-granular the same way:
  disk passes, imports, `tree_write` (whole-file) and version restore. A
  snapshot carries no edit intent, so the CRDT never claims a byte inside a
  rewritten line was kept (a single insertion or deletion is not a rewrite:
  the bytes it keeps are observed, not inferred, so appending to an
  unterminated last line keeps that line's authors): a concurrent writer that deletes the old line
  would otherwise leave the "kept" bytes deleted and the inserted ones
  joined into text nobody wrote (a broken token, a lost line end). Only
  inputs with positional intent stay character-granular: `buffer_edit` and
  `text_insert`/`text_delete`. Two concurrent rewrites of the same line keep
  both new lines intact and report the overlap as a conflict region, as in
  git, including when the two edits touched different parts of the line.
  Blame is whole-line for disk edits; intra-line highlighting, if a UI wants
  it, is a display-time diff against the line's previous version that is
  never stored, so it cannot fabricate history. Background passes
  defer files younger than a settle delay; scope ends, fences and shutdown
  ingest everything. A rename onto an existing name (the target's inode
  number becomes the one a removed path had) is a content change of the
  replaced file plus a remove of the source, never a move: the runs of the
  new content that a line diff against the source's current text keeps
  equal are copies of the source's spans, so they keep their authors
  exactly (nothing is matched by content across files), an editor's atomic
  save never cuts the file's blame, and an edit made concurrently to the
  replaced file merges into it. The source's text is copied as the renamer
  saw it, so edits made concurrently to the source stay with the removed
  source (remove wins), but none vanishes silently: the batch carries a
  renamed marker (opaque tag 21: destination, source), and whenever the
  source's text has moved past the version the renamer copied, the
  destination lists an `Offered` conflict (the source's current spans with
  their authors as the alternative) and the device that applies those
  edits gets a `rename_offered` event ("a.txt was renamed onto c.txt;
  your edits are offered there"). Accepting replaces the destination's text
  with copies of the source's spans, authors kept, and records an accept
  marker (tag 22) that moves the copied version forward, so the offer is
  not listed again. An editor's atomic save has a temp-file source nobody
  else edits, so it never offers anything. (planned) Copies that track
  their source, so that a delete of a source character also deletes its
  copies and an insert next to one lands beside them, make edits to the
  source follow it like a move; that is the full answer, and offers then
  remain only for edits the copy cannot place. The mirror case, a path whose recorded
  inode number now sits at a created path while the path itself holds a
  different file (moved away, then a new file saved in its place), is a
  move of the file to the created path plus a new file at the old path,
  never an edit that hands the old file's history to the new one. A pass
  that defers a file (young, or held by a scope) also defers any created
  path holding that file's recorded inode number, so both halves of a move
  are always ingested in one pass.
  Changes no scope claims belong to the mount's ingestion
  actor, `blake2b-128("0ndb ingestion actor" || device || mount id)`, never
  to the device's own API writes, so disk changes concurrent with them stay
  representable. Opening a mount appends one `REC_ACTOR` record (tag 9: kind
  1, actor, mount id) to the device's stream; every replica checks the actor
  against that stream's device and presents the actor's edits in blame and
  conflict regions as that device. An actor that acts for a conversation (a
  rewind's, a set revert's) is registered with kind 2: actor, pseudo, owner
  conversation, device; replicas check the device against the stream and index
  the actor under its owner (`aw:`), so `history_owned_actors(owners)` lists
  every such actor of those conversations with no mount ids needed.
- **Shared writers** (planned): several scopes writing one line in one
  directory (a chat and its shared tasks, two chats) stay separate through
  base frontiers. Drivers record an `Observe` op (opaque, tag `0ndb:observe`
  v1: kind `read | write_begin`, inode, path, version frontier, content hash)
  when a tool reads a file or begins a write, credited to the scope. A scope's
  whole-file write is diffed against that scope's last observed version of the
  file, not against the shadow, so a write based on a stale read becomes ops
  concurrent with what it did not see instead of deleting it; edit-style tool
  calls (old text → new text) are ingested as positional replacements. Two
  scopes' edits conflict when neither's base frontier contained the other's
  ops and they touch the same lines: both texts stay in history as a conflict
  region with both authors, the disk keeps the later write's lines (never
  markers in a shared directory), and both conversations get a passive note
  with their next tool result naming the region. A read with no known frontier
  records nothing.
- **Agent writes from a known base**: an agent that rewrites a file it
  read earlier would otherwise revert everything that landed in between
  (keystrokes in a buffer, other devices), because ingestion diffs the
  shadow (which already holds them) against the agent's bytes. When the
  driver reports the content a write was based on, the write is ingested
  from that base instead. A scope pins one version per path: at a reported
  read whose content equals the file at `synced` (`scope_read_base`), and
  at a write tool's start (`scope_write_begin`), which also holds the path
  until the tool finishes (`scope_write_end`, or the scope closing; never a
  timer): a pass leaves the holding scope's own change to the held path
  dirty (a change by anyone else is ingested at once, as it was written, so
  the hold never reorders other writers), and materialization advances
  only to the largest version whose batches since `synced` neither touch a
  held file nor descend from one that does, so the disk under a write in
  progress never moves. The write's reported original (`scope_write_base`)
  must hash to the file at the write pin, and a read pin's hash is checked
  again, so a pin is used only for the content it names. A scoped change to
  a pinned path is then emitted as base→written text edits in a batch
  parented on the pinned version, credited to the scope's actor, without
  moving `synced`; the pass then materializes `synced` united with that
  batch, which rewrites the file with both the agent's edit and everything
  concurrent, and the CRDT reports overlapping edits as conflict regions.
  The path's shadow entry names that batch as its own version until the
  materializer writes the path at a version containing it and resets the
  entry to `synced`, so the shadow always describes the disk: on a path
  another scope holds, the merge waits for the hold like every other batch,
  and meanwhile the disk is exactly the text at the entry's version. A
  change to a path whose entry names a version is ingested from that
  version (a based batch credited as any change there would be, so a third
  writer during the hold is merged, not diffed against bytes `synced` never
  had), a based batch's Lamport time follows both `synced` and its parents,
  verification and the open-time names check compare such a path with its
  own version, and a rewind computes the current text from `synced` united
  with the versions its files' entries name. Recovery after a crash adds
  the mount's own committed batches to `synced`, but a based batch or a
  rewind on a held path is on disk only once it is materialized, so for each
  recovered file whose disk is not the text at that version the entry names
  the newest recovered batch whose own text the disk is, and the path is
  rematerialized; the reopen never ingests that gap as a disk change.
  A rewind (`mount_revert(mount, before, after, owner)`, the primitive under
  rollback and undo) commits as its own actor, one per (mount, line, owner):
  `ingestion_actor(h.self, mount_revert_pseudo(mount, line, owner))`,
  registered with its owner (kind 2) the first time it has ops. A rewind on a
  held path, or one not yet durable, sits in history until it is materialized,
  like a remote change, so the mount's ingestion actor never has an op that
  `synced` lacks and its next batch stays on one chain; the rewind actor's
  next batch includes that actor's last op, taken from the graph. The device
  in the outer hash is always `h.self`, never one taken from the mount or the
  owner: a fork mount's id is the same on every device, so the device is what
  makes the actor single-writer.
  A pin names the inode it read, and the edits go to that inode whatever
  the path holds when the write is ingested. If the inode was removed after
  the pin (and perhaps a new file created at the path), the edits are
  concurrent with the remove and the remove wins, as it does over any
  concurrent edit whichever reaches a device first: the edits stay in
  history on the removed inode, credited to the actor, and the path is
  materialized to the merged version (absent, or the new file), so bytes
  the agent only carried over from its base are never recreated under its
  name. Only the write whose pin read that inode goes to it: a later change
  at the path, made while the disk still shows the removed inode because
  its materialization waits for durability, never falls back to the shadow
  entry's version and is an edit of the removed inode like any edit
  concurrent with the remove. It stays in history, credited to its writer,
  and the path is owed a materialization, so the disk returns to `synced`
  (absent, or the file recreated there) as soon as it may. Removed means
  `synced` knows the inode and holds it nowhere; an inode it does not
  know, holds at another name or holds as a collision loser is not
  removed. A pinned inode that is live at another path is not used. A pin is
  taken at the version the file's shadow entry names (a held or based write
  that `synced` lacks, otherwise `synced`), and its observation is
  committed on that version, so a later base check finds the actor's own
  last op on top of exactly the text it read.
  Without a pin, or when the hash differs, ingestion is as above, and the
  mount reports each outcome (merged, current, mismatch, not text) to the
  registry's base hook. Each pin also appends a durable observation to the
  tree's history in the scope actor's stream: an opaque op (tag 19:
  version 1, kind read or write_begin, the file's inode, its path, the
  observed frontier, and the blake2b-256 of the clean content), so a later
  question such as which turns built on a version containing some ops is
  answered from history alone (`history_observations`). A write whose
  scope closed before it was ingested takes its base from the actor's
  latest read observation of the path, but only while that observation is
  unconsumed: once a later batch by the same actor has text ops on the
  observed inode, the write it covered is in history, so a recovery that
  re-detects the change never merges the actor's diff a second time.
- **Mount registration**: `tree_mount` creates the mount's state directory
  under `worktrees/` with a directory fsync of its parent (and of the data
  directory when `worktrees/` is new), and the mount state is saved before
  it returns. It reports success only once the registration survives a power
  cut: while the tree's own registry record is still staged (a tree created
  in the same batch) it returns `Pending` with a usable mount, and its
  `Mount_Done` completes with `None` when that record is flushed, or
  `Closed` when the mount or the engine closes first. It never blocks the
  loop for that wait.
- **Commit protocol**: each batch a mount commits carries one opaque
  mount-mark op (tag 18 plus a random per-mount nonce) and, unless the line
  is held, the mount's line record, in the same journal commit. Import
  batches carry the line record the same way and never hold the line, so a
  failed import leaves a subset of the checkout visible alike through the
  API and every mount of that line, and the next open finishes it. Nothing is
  written before the commit; the mount state records the journal position
  it reflects, and after a crash the mount finds its own committed batches
  by scanning its stream from there for its mark. The mount state alternates
  between two checksummed in-place slots carrying a sequence number. A pass
  costs four flushes: journal, store, shadow and mount state. The history
  journal is durable only when the pack batch carrying it completes, so the
  shadow, the mount state (synced frontier, journal position), staged blobs
  and materialization wait for that batch in every durability mode: a pass
  records an image under the history's mark and writes it when the mark is
  acknowledged. The history's derived state (graph, actor interning, which
  the shadow's inode ids refer to) is committed into the pack only once that
  batch completes, so it is durable one batch later; the history counts a
  mark as settled when that later batch completes too, and mount images wait
  for settled, not for durable. A local commit happens once its journal
  records are sealed. A failure before that drops the records it appended (and
  the actor ids they introduced) and reports the batch not committed; a
  failure after it (apply, line, persisting the derived state) never reports
  failure, because the caller would ingest the same disk change again.
  Instead the history reloads from its sealed state and replays the journal,
  keeping its in-memory actor interning order, so the batch is applied once.
  Derived state that failed to persist is never sealed partially (a seal
  first finishes the persist), and the history does not settle while a
  persist or a reload is outstanding. A redaction follows the same rule from
  its zero-fill on: a range that is zeroed is reported in the result even
  when a later step fails, and the engine announces every reported range
  (puncture and relay redaction) before it looks at the error; a failed
  persist after the zero-fill reloads the history and the call succeeds.
  Recovery from the mount's own intents (at
  open, or when a pass retries an import that did not finish) goes through
  the same wait: the intents stay in the saved state until the image that
  covers them is written. Recovery re-derives the shadow entries of the
  inodes its intents touched from the tree at the synced version it saves
  (the old synced frontier plus the intents), never from the history's
  current tree, whose later local operations the disk does not reflect yet. The mount state also records the shadow's
  generation and log end it was saved against; on open a longer shadow is
  rolled back to that end, so shadow and synced frontier are always one
  saved state and a crash between the shadow flush and the state save is
  undone. The rollback rebuilds the shadow as of that end and writes it as a
  new generation; it never truncates the log in place, because a lost size
  change or a lost index rename would bring the old tail (and an index that
  describes it) back after a later crash. Attributions follow the same checkpoint-plus-log rule: each
  observed write is appended to `attrib.log` before the write proceeds, an
  image carries a snapshot of the attribution map (which entries a pass
  consumed or pruned) and the log offset it covers, and the mount state saves
  that snapshot rather than the live map. The log is truncated, and its
  generation bumped, only when the saved image covers every live entry (a
  scope whose close fails syncs the log after appending its pending
  attributions, so they survive a power loss); on
  open the records past the image's offset are replayed over it. A crash
  that loses a history commit therefore reopens with the attributions that
  commit consumed still pending, and the re-detected change is credited to
  its writer, not to the device. An observation record is synced before the
  observed write proceeds wherever the observer can hold the write:
  `mount_observe_begin` completes its `done` only once the record is synced,
  observations arriving together share one fdatasync run off the loop
  through the registry's `Sync_Exec`, and `observe.route_held` records every
  content-changing path of an observed write and runs the write's `Release`
  (exactly once) only after; a supervisor that can hold a write (the Linux
  seccomp supervisor, which parks the notification) sets the `Release` and
  keeps the write blocked until it runs. A runtime tool-call pin records its path the same
  way but cannot hold the provider's write. A provider can write before the
  runtime has interpreted the tool_use line that names the file, so the
  watcher's change arrives first; it is still the tool's. Each unscoped dirty
  path records when it was first seen (the engine's monotonic clock), and the
  tool's scope open and observation carry the receive time of the run's
  provider line before that tool_use: the scope's opening pass leaves changes
  first seen at or after it pending, and the observation claims a pending
  change on the path it names (a file the watcher has not reported yet counts
  when its mtime is within a timestamp tick of that time). A change on any
  other path stays the person's. On macOS without Endpoint
  Security (libproc sees a change only after it happened) and on Windows,
  nothing holds a write: a write the runtime did not pin (an agent's shell
  command writing a file directly) is recorded only after the fact, so after
  a power loss inside that window it is credited to the device, not the
  agent. The record of the content a pass
  consumed for an observed actor, and of the content an observed scope closed
  with, goes through the same group sync, so a person's later edit of that
  file is split from it after a crash. A change with no record is therefore
  never an observed agent's, and after a power loss it is the device's
  (`attrib_default_actor` is the one rule for that); an observed entry whose
  content can no longer be matched is unattributed. Several writers can touch
  one file before a lost history commit (two agents, then the person), so
  replay keeps each path's ordered steps (actor, content oid) past the image's
  offset, and the re-detected change is committed step by step: the content of
  each step as its actor, then the rest by the rule above. Each step is a
  content diff against the one before, so a writer whose bytes a later step
  overwrote is credited nothing. A scope that closes having
  observed a path it never wrote retires that observation in the log (a
  record with no actor, which replay applies as a removal), so a later
  change by anyone else is never credited to it. A scope that closes with
  content no pass consumed yet logs a step for the content it was diffed
  from (the device's, unless an earlier step already names it, with its
  blob stored) before its own, so when the commit of that base is lost too,
  its bytes are the device's and only the scope's own diff is the actor's. A
  step whose content the disk holds exactly names its writer even when its
  blob never reached the object store, a step whose content is the text the
  replay already stands on changes nothing and is skipped, and any other
  step whose content is missing stops the chain and the rest is
  unattributed. The steps live
  only in the log, so while any path holds steps an image keeps the replay's
  offset and no save truncates the log or moves to a new generation; a full
  pass that finds a chained path unchanged drops its steps.
- **Materialization**: remote or merged ops are written to disk only for
  inodes touched since the synced version, plus every ancestor of a touched
  inode whose place differs between the two versions (a move that a later
  concurrent move turns into a cycle is skipped, which moves a directory no
  new op touches). A pass in which a directory is created, removed or placed
  differently from its shadow entry, or in which collisions or reshows are
  pending, also reconciles places in full: every inode whose path in the
  target differs from its shadow path is touched, so a place that only a
  cycle skip or a collision resolution changed is never left behind (the
  sim counts these passes). Each item takes its old path from the shadow
  when it is processed, so a directory an earlier item in the same pass
  moved is followed. An item whose parent is not yet in place waits and
  reshows the parent too; a directory created at a path whose tracked
  entry is another inode waits for that inode to move away; content that differs from the
  shadow, or untracked content where an inode must land, is ingested first,
  never overwritten, and the plan is rebuilt from the new synced version.
  Untracked content that is exactly the inode at the target version (what a
  truncated shadow forgot) is adopted: a shadow entry, no write, no ingest.
  A first mount of a folder whose tree already has content adopts against
  the tree's line: the disk is imported onto the line's inodes, then the
  line is materialized. The mount state carries an adopt-pending flag,
  written before the synced version takes the line and cleared only with
  the image saved after that materialization; while it is set, the synced
  version is not trusted, and every open, pass or materialization finishes
  the adopt first, so a failure in between never leaves the synced version
  claiming files the disk lacks.
  If ingesting changes nothing (an ignored file in the way), nothing is
  written and the path is reported as a collision. The synced version, with
  the versions shadow entries name, never claims anything the disk does not
  hold. Only durable history is materialized, so a crash never leaves disk
  content the history lacks.
  Writes are temp + rename, with modes and symlinks. A pass writes every
  file's temp first, syncs them as one group (fdatasync, or `syncfs` past a
  threshold, on Linux; `F_BARRIERFSYNC` on macOS), renames them into place,
  then syncs the directories ending in a full flush, so a file's data is
  durable before its name points at it: after any crash a written path holds
  its old content or its complete new content, and only directories are owed
  until that barrier. A structural item (a directory, a move or a removal)
  first commits the files staged before it, so the pass keeps its order. A
  pass that fails partway after its structural items rolls forward: `synced`
  becomes its target in memory (persisted only by the image saved after the
  owed barrier), and every file whose entry the pass left untouched (same
  inode, kind, content and version, whatever its stat) keeps the version
  still on disk in its entry and is pending, re-materialized by a retry
  armed while pending paths are ready, after any edit made to it meanwhile
  is ingested from that version. A pass that fails with structural items
  still to do keeps `synced`, names the target in the entries of the files
  it already wrote, and is redone from a rescan. `synced` equals the disk
  except for the paths in `absent`, the mount's owed paths: a rolled-forward
  pass owes every path it left pending, and a pass that keeps `synced` owes
  the removals, moves and directories it already applied. `absent` is
  persisted with the image's `synced` it qualifies, so no crash persists one
  without the other. While the shadow is owed (its writes wait on a failed
  barrier), the saved state keeps the last `synced` it saved and the journal
  position saved with it, so the image never names a `synced` whose pinned
  entries the shadow has not persisted and recovery still replays every own
  batch that `synced` does not contain;
  the first save after the owed shadow persists writes the current `synced`.
  A merge-mode materialization (catch-up of the mount's own batch) never
  writes over a file whose disk differs from the text at its base: it first
  commits the disk's difference from that base as the mount's snapshot actor
  (`ingestion_actor(h.self, mount_snapshot_pseudo(mount, line))`, registered
  for the device, parents the base and that actor's last op), points the
  file's entry at the snapshot version, and materializes the target with the
  snapshot, so the person's bytes are a durable op concurrent with the
  target and the written text is the CRDT's merge. A materialization writes
  nothing while history holds a batch that is not yet durable (a snapshot,
  an ingest a pass committed mid-materialization for a race retry or a
  blocker, a rebase): `materialize_to` returns `Deferred` before it touches
  disk or the shadow, by the same rule catch-up gates on, and the history's
  durable acknowledgement reschedules the mount. A caller that gets
  `Deferred` stays where it is: a pass whose catch-up defers stops before it
  ingests, the switch stays in its phase, `mount_materialize` returns as it
  does when the line is not yet durable, and `mount_sync` reports `Deferred`
  so a closing scope records its attribution for the pass that resumes.
  While a materialization is held, the image keeps its journal position, so
  recovery replays an own batch the held `synced` does not contain. Disk
  only ever holds content history can name after any crash. Ingest never reads an owed path that is missing on disk
  as a delete, and the next pass that completes drains `absent`. A removal
  whose unlink fails fails its item, so its entry is never dropped while the
  file is still on disk. A pass whose line version is ahead of `synced`
  adopts a changed file whose content is its text at the line version (what
  an interrupted materialization wrote before a crash): its entry names that
  version and nothing is committed. A removed file that the line version no
  longer holds (an unlink applied before a crash, its shadow entry rolled
  back to the image's mark) is adopted by dropping its entry and owing its
  path in `absent`, so `synced` still equals the disk except what is owed
  until the materialization that completes drains it. A created directory that is a present
  directory at the line version is adopted the same way, so a directory the
  pass made before a crash is never ingested as a new one beside the line's,
  but only when everything the pass creates under it is adopted too: a user
  file under it would otherwise commit as a child of an inode `synced` does
  not contain. A file whose content is still its
  entry's (a racy entry reread) is not adopted: its entry already describes
  the disk. Leftover temps are internal names and
  never ingested.
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
- **Lines are git branches**: a git mount follows its checked-out ref. The
  branch HEAD named when the mount was first opened (persisted in the mount
  state) keys the mount's own line (`main` for API mounts), so plain-folder
  mounts of the tree on other devices keep sharing it; any other branch is
  line `git:refs/heads/<name>` and a detached HEAD is `git:detached:<commit>`
  (detaching at the same commit returns to that line). `mount_line(m)`
  returns the key. Each line keeps its own history, attribution and
  uncommitted state. When a pass sees HEAD name another key (and no rebase,
  merge or cherry-pick is in progress), a new line forks from the synced
  version and git's writes become its git-op batch; an existing line is
  retargeted instead: the shadow entries of the inodes whose place differs
  between the synced version and the line (those an op between the two
  touches, closed under everything below a touched directory in either
  version and under any inode a collision displaces from a touched one's
  path) move
  to the line's paths with their stat cleared, the synced version becomes the line's, and the full pass diffs
  disk against the line, so git's writes (and anything git carried) land on
  that line only. A path the line has that is missing on disk after the
  switch and that the departing commit's git tree does not hold (a collision
  copy or another file of that line git never tracked) is owed: it is
  materialized like a pending path and never ingested as a removal; one the
  departing commit holds is git's deletion and lands on the line. A path
  deleted between git's checkout and the pass that sees the switch cannot be
  told from one git did not create, and is rewritten. Text a git rewrite
  carries (the departing commit, reflog entries, ORIG_HEAD and cherry-pick
  sources) is copied with its authors only from versions the line's synced
  version contains; anything else is a plain insert by the line's actor. A
  materialization whose pass switched lines restarts at the
  new line rather than writing the old one back. Ingestion on a line other
  than the mount's own uses an actor derived from the mount and the line,
  registered like the mount's ingestion actor, because an actor's ops stay on
  one chain. A scoped write whose scope actor's chain is not on the mount's
  line (a scope held across a switch) is never credited to the mount: it
  commits as that scope's line actor, `ingestion_actor(device,
  blake2b-128("0ndb scope line" || scope actor || line))`, registered with
  kind 3 (actor, pseudo, base scope actor, device). Blame presents a line
  actor as its base actor, and a line actor whose base is owned joins the
  base's owner, so the write undoes with its turn. An unscoped write that is
  off the line still falls back to the mount's actor. The engine reports each
  switch as `Line_Switched` (object = the tree, detail = from and to keys) and
  git's `index.lock` coming and going
  through a registry hook. Mounts the runtime manages on conversation lines
  keep their line until runs are bound to lines; only their key moves. Every
  run is bound to the (mount, line) it started on (Conversations, planned).
- **Switch** (`line.switch(tree, line)`, op 173): hold the runs bound to the
  old line and wait until every one has sealed (`runtime_hold_line` with
  `done`; `Interrupted{reason = branch_changed}` at the next tool boundary,
  native sessions kept), hold their writes under the mount
  (`mount_hold_writes`), then run a switch record (`switch_to`,
  `switch_from`, `switch_phase`) kept in the mount state and advanced by the
  mount's own passes, so nothing blocks the loop. Ingest: the record is saved
  with the mount still on the old line, and it waits until a pass has
  ingested everything onto the old line and that history is durable; a
  branch with no line yet gets one from its commit tree as one git-op batch
  (`line_from_commit`) forked from the synced version. Target: the mount
  moves to the target line and materializes its whole state, including its
  uncommitted edits, until the synced version is the line's. Git: update git
  in git's own order (`git read-tree <commit>` and `update-index -q
  --refresh`, so `git status` shows the line's edits; then `git symbolic-ref`
  or `update-ref --no-deref` with reflog message `0ndb: switch from <a> to
  <b>`), refresh the mount's view of HEAD so the next pass does not
  re-classify, clear the record and report done; the op then releases the
  writes and resumes the runs bound to the target line. Each phase is saved
  before its effects and every step is idempotent, so a mount that reopens
  with the record set resumes it: before the target phase it stays on the
  old line, after it it rolls forward (recreating a target line whose import
  was lost, and removing a stale `index.lock` the crash left). Lines are
  named by their git key (`git:refs/heads/<name>`; the mount's own branch maps
  to its line). Runtime-managed mounts are refused until run lines retire. **A
  0ndb switch keeps each line's uncommitted state with that line (an automatic
  per-branch stash), while a raw git checkout carries dirty files as git
  does**; (planned) the catalog shows on which line every uncommitted change
  lives, so nothing seems to vanish, `carry = true` gives a 0ndb switch git's
  semantics, `.Fork` moves held runs into an isolated fork of the old line
  that lands on completion and `.Stop` cancels them. The default is never
  asked.
- **Git's lock and our handles**: 0ndb never holds a handle on anything
  under `.git` or the work tree across a loop turn. Windows refuses to
  rename onto a file that another process has open, even with
  `FILE_SHARE_DELETE`, and git's retries are short. A daemon holding
  `.git/index` while git renamed `index.lock` onto it left `git checkout`
  failing with `unable to write new index file`: the work tree was
  switched, but the index and HEAD were not. The index reader therefore
  reopens the index by path for each window it reads (1 MiB), checks it is
  the same file (size, mtime, inode), and closes it again; a replaced index
  ends the scan with `.Changed`. Tree reads open with
  `FILE_SHARE_READ|WRITE|DELETE` and close before returning. On every OS,
  while `.git/index.lock` exists and a live creator is a working-tree
  writer, the mount runs one pass (paths dirtied before the lock) and then
  no batches until the lock disappears or every creator exits. Lock-gone
  schedules the next batch; fences still run. The creator is the write
  observer's `O_CREAT|O_EXCL` record of the lock. Failing that, it is a
  bounded process scan for a `git` holding the lock open or with its cwd at
  the repository (`/proc` on Linux, libproc on macOS, Restart Manager and
  `git.exe` on Windows), watched by child watch; `git checkout` keeps the
  lock's fd open for the whole working-tree update. The subcommand is read
  after `-C`, `-c` and the other valued options, and aliases are resolved
  from the repository's and user's config. Working-tree writers
  (`checkout`, `switch`, `reset`, `merge`, `rebase`, …), unknown
  subcommands, `!` aliases and unreadable command lines count. Index-only
  commands (`commit`, `add`, `status`, …) do not: `git commit` keeps the
  lock through its editor session, and edits made meanwhile keep syncing.
  Its final index rename is safe because no read holds the index. A lock
  with no live creator is stale: batches run as usual and the mount shows
  a passive `stale .git/index.lock` status.
- **Raw checkouts** follow git's write order (`builtin/checkout.c`:
  `merge_working_tree` takes `.git/index.lock`, `unpack_trees` unlinks then
  writes working files, `write_locked_index` renames the lock; only then
  `update_refs_for_switch` appends `checkout: moving from A to B` to
  `logs/HEAD` and renames `HEAD.lock` onto `HEAD`): every working-tree write
  precedes any HEAD or reflog signal, and a checkout without `-f` carries a
  dirty tracked file or refuses, never overwrites it. So the mount gates on
  the lock: for the same working-tree-writer locks that hold batches (see Git's
  lock and our handles), writes from the process trees of runs bound to the
  mount wait until the lock goes or its creator exits. Bounded by events,
  never by time. Writes from git's own process subtree (hooks) are git
  writes, never credited to a run's scope. Each OS gates its own way:
  - **Linux**: the seccomp supervisor parks write-intent opens under the
    mount root, except from the creator's subtree, and continues them on
    lift. The keeper's parked set keeps its guarantee: a dead supervisor or
    daemon continues every parked notification, so no run stays blocked.
    Parking never signals a process, so a process the user stopped stays
    stopped, and a parked request is answered by its notification id,
    never by pid. Reads, network and writes elsewhere go on.
  - **macOS**: the bound runs' process trees whose cwd is under the mount
    get `SIGSTOP`, then `SIGCONT` on lift; 0ndb's own processes and the
    creator's subtree are never stopped. Reads and network pause too.
    A process already stopped (`SSTOP`: job control, a debugger) is left
    alone. Each stopped process is recorded with its start time. On lift
    it gets `SIGCONT` only if its start time matches and it is still
    stopped, so a reused pid is never signalled. A keeper process, forked
    from the daemon and using only raw syscalls, holds the same set: the
    daemon tells it before every `SIGSTOP` and after every `SIGCONT`. When
    its socket to the daemon closes (crash, `SIGKILL`, upgrade) it
    continues every recorded process with the same checks and exits. A
    git/git checkout between v1.6.0 and v2.47.0 pauses 0.4–0.6 s.
  - **Windows**: no gate. Suspension is a kernel APC that can land inside a
    non-critical-region kernel wait, such as a filter driver waiting on its
    user-mode service, and a thread frozen there can deadlock git or the
    daemon's own loop. Without a minifilter there is no safe pre-open hook.
    Runs are held at the protocol level (`Interrupted{reason =
    branch_changed}` at the next tool boundary) once the switch is
    classified, and run writes that land inside the lock window are
    classified on the next pass like a tool that bypasses the lock.
  A gate is also bounded in time, because what git runs under the lock can
  wait on anything. Measured on git 2.43 and Apple git 2.50, no
  working-tree writer holds `index.lock` while an editor, pager or prompt
  is open: `rebase -i` todo and reword editors, `merge --edit`, the commit
  after a conflict, `checkout -p`/`restore -p`/`reset -p`/`stash -p`
  prompts, rebase `exec` lines and `post-checkout`/`post-merge` hooks all
  run unlocked. Under the lock git runs smudge/clean filters (`git lfs`
  downloads), merge drivers and `reference-transaction` hooks. Any of them
  can take minutes or wait on a server the agent runs under the mount,
  which the gate holds: a deadlock. So the gate lifts after at most 5 s on
  macOS (a stopped provider CLI cannot read its stream) and 30 s on Linux
  (only the writing tool call waits). The batch hold stays until the lock
  goes. An overrun is counted in the mount's `gate_overruns`, and writes
  after it are attributed and classified as usual.
  When the lock goes, HEAD, its target and the
  reflog tail decide: a changed branch or detached commit with a
  `checkout:`/`switch:` entry is a line switch A→B (git's writes are one
  git-op batch on B, carried dirty files are ingested onto B; planned: also
  onto A as a carry batch credited to their authors; A's runs are held, B's
  resume);
  anything else (commit, reset, merge, pull, restore, stash) is a git-op
  batch on the same line. While `rebase-merge/`, `rebase-apply/`,
  `MERGE_HEAD`, `CHERRY_PICK_HEAD` or `sequencer/` exist, a detached HEAD
  belongs to the branch in `head-name` and that branch's runs stay held until
  the operation ends; bisect steps are detached lines. A tool that bypasses
  the lock is classified the same way on the next pass, without the gate. A
  forced checkout destroys dirty content by the user's choice; ingesting at
  gate time bounds the loss to what git overwrote within milliseconds.
- **Deleted branches** (planned): runs and tasks bound to a line whose ref no
  longer exists show `held: branch <x> deleted` (passive) and resume if the
  ref comes back; the API can move them to the current line. Nothing is asked
  and the line's history is kept.
- **Going back** to a message is a move (Conversations): new ops turn the
  files into the message's version (history is never rewritten, every line
  keeps its author). (planned) It never moves a git branch: if the branch moved past the
  message's recorded commit, the restored files show in git as uncommitted
  changes against the tip, and commits of the left timeline stay reachable
  through `refs/0ndb/<history>`. Within a line, a conversation branch is an
  owner-scoped selection (Conversations): only the owning task tree's ops
  are reverted or restored, every other writer's stay.
- **Fork**: same history id cut at the fork version. Git checkouts get a
  separate clone whose `objects/info/alternates` points at the source
  repository (no object copies, any number of forks on one branch, unlike
  git worktrees) with reflink-copied working files (`FICLONE`/`clonefile`,
  else copy); plain folders get a reflink clone. Only paths that can differ
  are rewritten. **Land**: sync both ways, CRDT merge; overlapping concurrent
  regions are stored as conflicts in the fork and shown with markers there
  only; land refuses while any remain. A fork's live diff against its parent
  line is a subscribable view (`subscribe.fork_diff`), pushed on ingestion.
  Its fork side is the task's run line while a run is open, its conversation
  line otherwise. A file is listed when its presence, path or text differs
  between the two versions. Each push looks only at the files touched by the
  ops that entered or left either side since the last push. Whole-tree
  snapshots are built only when those ops change the tree's structure
  (create, move, remove, flags, target) or a side lost ops. A frame goes out
  only when the listed result changed, so an idle fork costs nothing.
  `task.changes` reads the same view once.
- **Blame** is a span lookup. **Revert** of a scope creates ops that undo
  exactly that scope's ops, transformed through everything since. Actors are
  bounded (one per conversation, mount and line, plus the ingestion actors),
  so a tool call is not an actor: a pass groups its changes by scope, and
  every scoped batch carries a sealed opaque op after its own ops, before the
  commit mark (tag 23, version 1: the scope id and nothing else, so redaction
  never touches it; at the end, it shifts no op id the pass already gave out,
  and a batch with nothing else is not committed); applying it appends `(first
  seq, op count, scope)` to `ss:<actor>`, and `history_scope_of(op)` (engine
  `tree_scope_of`) finds an op's scope by a binary search there. A change
  attributed through the attribution log takes the scope still open on its
  path; one ingested after its scope closed keeps its actor without a scope.
- **Set revert** (`mount_revert_set(mount, base, actors)`) undoes, as one
  batch on the mount's line, every op after `base` whose actor is in the set,
  transformed through everything since. Ops carry actors, not scopes: undo
  resolves a task tree to its scope actors, and every other actor (a person's
  disk edits, the unattributed and ingestion actors, git and imports, other
  trees) is outside the set, so its edits survive. Per text file a tracker
  walk over the ops from the common ancestor of `base` and the line to the
  line's version yields every item in document order with its insert class
  (base, in the set, outside it) and the classes of the ops that deleted it.
  An item the set inserted is deleted; an item the set deleted comes back only
  if neither an op outside the set nor the base also deleted it. Where an
  outside edit lies inside text the revert removes (a line holding both an
  outside insert and a set insert, or an outside batch that deleted text the
  set inserted and inserted its own line, i.e. a rewrite), the line reverts to
  its text at `base`: its outside inserts are removed, the base text that
  rewrite deleted is restored, and the line's pre-revert text is kept as a
  revert conflict alternative. An outside delete inside set-inserted text
  disappears with the insert and conflicts with nothing. Tree fields follow
  the last writer by lamport: a create by the set is removed (a file it
  created that an outside writer edited is removed too, and its whole
  pre-revert text, or blob, is the alternative on the removed inode), a remove
  by the set is restored when the file existed at `base` or was created
  outside the set, and a move, flags or target change, or an opaque file's
  blob, set by the set reverts unless an outside op set the same field later
  (then the outside value stays and the set's blob is the alternative).
  Restored text is an `Insert_Copy` of the original ops, so blame keeps the
  original authors. The batch commits under a fresh revert actor,
  `ingestion_actor(h.self, pseudo)` for a new pseudo id, registered with its
  owner (kind 2, the undoing conversation, or plain kind 1 outside an undo) so
  blame presents it as its device; it has exactly one batch. It carries an
  opaque marker (tag 20, version 2: the base version, the actors, the revert
  conflicts and the undo id, zero outside an undo), so the conflicts are
  durable with the batch; applying the marker indexes them (`rv:`/`rvl`) and
  the revert under its undo id (`ru:`), so `tree_undo_revert(tree, undo,
  line)` finds an undo's revert on a line, and `tree_conflicts` lists them as
  kind `Revert` (with the revert actor, and the blob for an opaque file) next
  to concurrent and offered ones: `ours` is the text that stays and `theirs`
  the alternative. Accepting one (`tree_conflict_accept`) replaces `ours` with
  an `Insert_Copy` of `theirs`, restores a removed file or sets the blob, and
  records `TOP_ACCEPT` naming the revert actor and the conflict's index, so it
  is no longer listed. The batch is committed like an API write and then
  materialized, never through the mount's ingest marks, so recovery never
  takes it for ingested disk content. **Reverting a revert**
  (`mount_unrevert`) is a set revert of the revert actor from the version just
  before its batch: with nothing in between it restores the files byte for
  byte, and the reverted revert's marker is marked so its alternatives are no
  longer listed. A tree no device mounts is set-reverted through its history
  (`tree_revert_set(tree, base, actors, line)`, `tree_unrevert`), committed
  like an API write; a mount is that plus materialization. A land or merge of
  an isolated task is a line merge, so the ops it brings keep their scope
  actors. `history_mount_actors(mounts, lines)` returns the ingestion actors
  of the given mounts (home and per line) from the actor registrations, which
  are replicated `REC_ACTOR` records in each device's history stream. Mount
  ids are not device-unique (a fork mount's id derives from its task and
  name), so every such actor is single-writer through the device in its outer
  hash, `ingestion_actor(device, mount or pseudo)`, and a device registers
  only actors derived from itself. The cross-tree notice for a removed file
  another tree edited comes with undo.
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
  first page of the snapshot; `buffer_read(buffer, rev, from, len)` maps
  `from` from `rev` to the current rev and serves that range there (the
  reply names the rev and ack it reflects), so a 50 MB file opens on its
  first screen and the rest fills in while deltas keep arriving.
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
  earlier edits. Every `pos` and `pos + del` falls on a code point boundary
  in the buffer's units; an edit that would split a UTF-8 sequence or a
  UTF-16 surrogate pair is refused with `Invalid` and changes nothing, so
  the engine never widens an edit the client applied as sent. The engine first advances the buffer to its target,
  delivering any pending delta ahead of the edit's result, then transforms
  the edit over its unacknowledged deltas, converts units at the view, and
  commits one batch whose author is the buffer's actor (the person; default
  an editor actor derived from the device and the followed line), parented
  on the version the buffer now shows. Local editors therefore never form a
  permanently concurrent ladder (which would make every merge walk back to
  the last cut); only other devices' concurrent work is merged by the CRDT,
  character-wise. The result returns `ack` and the `rev` it reflects. The batch is
  journaled and committed with the normal cadence, moves the followed line
  (`line_after`, so concurrent line heads stay), and wakes the mounts of the
  tree; materialization writes the file only after ingesting disk content
  that differs from the shadow. The view applies the batch linearly, so the
  edit never comes back to its author as a delta. An actor's ops stay
  causally ordered: a buffer whose version lacks its actor's latest op (two
  buffers on one line) advances first and transforms the edit over that
  delta; one explicit actor on two lines at once is refused with
  `Conflict`.
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
  as op-id runs, deletes as the deleted op-id runs. Undo of a group deletes
  whatever of its inserted characters still exist (wherever concurrent work
  moved them) and re-inserts its deleted characters where they were (each
  deleted character resolves through the transient merge state), as plain
  inserts whose content is read from the original ops at undo time;
  redacted text is never restored, and nothing in the batch depends on a
  replica's redaction or fetch state, so every replica admits it. Redo is
  the inverse. It never touches characters another author inserted, so an
  agent's or another device's concurrent work survives undo. Groups are the
  client's `group` ids (equal ids merge).
- **Large files.** Open is one rope clone or checkpoint read and a first
  page; deltas, edits and anchors cost O(changes · log n). A file the tree
  keeps as opaque large content cannot be opened as a buffer (`Too_Large`).
- **Idle.** Open buffers arm nothing and wake nothing; they cost the view's
  memory and run only when their object changes.
- **Live edits.** A buffer edit reaches other devices' buffers ahead of its
  durability, on the live channel of the object's segment, the way drafts
  do (relay fan-out to live followers only, never stored).
  - *Writer.* After `buffer_edit` commits its batch at journal offset
    `off`, it sends `Live(segment, msg = DRAFT_MSG_MAX - 1, at = off,
    frame)`, where `frame = 2 ‖ boot ‖ off ‖ seal(file frontier ‖ file
    length ‖ acks ‖ batch)`. The file frontier is the frontier of the last
    32 ops on that file in the writer's view before the batch; `acks` lists
    `(actor, next)`, the next seq the writer's view holds for each actor of
    those 32 ops and of the buffer's last four live peers (found by binary
    search over the actor's seqs, so a lagging view still names exactly
    what it has seen); the batch is
    encoded self-contained (actor ids inline, no stream dictionary), and
    `boot` is 16 random bytes, drawn at the first send after the engine
    opens and again whenever a commit's offset does not exceed the last
    offset sent live for that object. The seal is
    ChaCha20-Poly1305 under `HKDF(K(off), "0ndb buffer live key" ‖ boot)`,
    `K` the segment's key provider, with nonce = `off` and AAD = segment
    stream id ‖ object id ‖ the clear header; a transparent space sends the
    body in the clear. The key never equals a record key (HKDF with a
    label no record key uses), and no (key, nonce) pair carries two
    plaintexts: within one boot the offsets sent for an object strictly
    increase, so each (segment key, boot, offset) seals one batch. Every
    way a journal offset can be reused (a crash before durability, an
    append whose group commit fails and is aborted in process, a pack
    poison that rewinds without a restart) shows up as an offset at or
    below the last one sent, which draws a new boot first; segments of
    different objects have different key trees. The sim watches every
    sealed (segment, boot, offset) on the wire and fails if one carries
    two different frames (`SIM_INJECT_REUSE=4` proves the check fires).
    The relay admits a Live frame by the same rule as an append to that
    segment (the stream id names the writer), whether or not it has stored
    any of it, so a frame is refused only where the segment's own upload
    would be.
  - *Receiver.* A device with a buffer open on the object live-follows every
    other device's segment of it. A frame applies linearly when its file
    frontier and length equal the buffer's display (the durable view, or
    the last overlay batch) and the receiver has no unseen local edits.
    Otherwise it may still apply over the receiver's recent local edits
    (*pend*, each a display byte delta with its actor and seq range, at most
    64): the frame's ack for the receiver's actor drops every pend item the
    writer had seen; what is left must be exactly the unseen suffix (its
    first seq is the ack, its last is the actor's latest), every overlay
    batch must come from the same peer device and chain on that device's
    previous seq (in the overlay or the view), and the frame's length must
    equal the display length minus the net length of that suffix. Then the
    batch is transformed over the suffix with the CRDT's tie (the lower op
    id first, the order the merged text will have) and the suffix over the
    batch, so both devices' concurrent keystrokes stay live and land where
    the merge puts them. Anything else is skipped and arrives durably. A
    frame whose seal cannot open yet (the writer's key tree is not loaded,
    a first contact) loads the writer's tree and is counted keyless. It then joins the buffer's
    overlay, a list of positional byte deltas on the durable view; the
    client sees `D = V ⊕ overlay` and gets the batch as one delta at once.
    Every client position (edits after the transform, reads, lengths,
    anchors, resolve, cursors) is in `D`; anchors inside overlay text name
    the overlay op itself and resolve through the overlay. Nothing enters
    the history graph, so a batch that never becomes durable leaves no
    trace.
  - *Durable catch-up.* When the view advances, the change `A` it made to
    the file is compared with the overlay: if the view's file frontier is
    the last op of an overlay prefix and `A` equals that prefix composed,
    the prefix is confirmed by op id with no delta to the client and the
    rest stays. Otherwise the client gets one correction, `inverse(overlay)
    ∘ A`, and the overlay is cleared, so no op is ever shown twice and the
    text always ends equal to the durable text. The correction never keeps
    overlay text as retained because it reads the same: equal text is not
    the same op, and an edit mapped onto the wrong op corrupts a word.
  - *Edits against shown text.* A client edit names the text it was shown
    at its rev, overlay text included, and it is never lost. Insertions
    survive every transform. A correction or drop remembers the op ids of
    the overlay bytes it removes; when a later client edit is transformed
    over it, the part of its deletion that falls on those bytes is kept as
    their op ids. Every gone id names an op of the overlay being removed;
    one that does not (a durable op, a zero actor) is dropped and counted,
    and an edit hitting one is refused with `Invalid`. The kept ids are a
    durable intent, never buffer state: before the edit commits, one record
    `(space, object, kind, inode op, line, actor, spans)` is appended to the
    engine's buffer delete log (`pack/buffer-deletes`, one journal, records
    with their own checks, a torn tail cut on open) in the same pack batch
    as the edit, so the edit and its intent become durable together. Open
    replays the log and marks each object changed; the tick after a change
    to the object applies every intent whose ops the graph knows, buffer
    open or not: a transient view at the line's target (chained on the
    actor's latest op, read from the graph then), the still-visible bytes of
    those ops deleted as one batch by the intent's actor, then a `Done`
    record. The file is removed when no intent is live; replaying a file
    whose removal did not survive leaves nothing live. A batch that never
    becomes durable leaves nothing to delete. The sim checks every accepted
    buffer edit against the final text, deletes over a dropped overlay
    whose buffer closes and node crashes once the delete is durable, and
    the log at every crash point of add, commit, done and removal.
  - *Local edits while an overlay is shown.* An edit that does not touch
    overlay text is mapped from `D` to the durable view, committed there,
    and the overlay is rebased over it, so typing continues while a remote
    batch is shown. An edit that touches overlay text (deletes some of it,
    or inserts inside it, at its edge, or where it deleted text) and every
    undo or redo is held (the call pends) until the overlay is gone, so a
    local insert is never parented without the remote text it was typed
    next to; held calls rerun in order. A caller without a
    way to wait drops the overlay first. Every committed local edit is kept
    in pend until a frame's ack or the durable view covers it; corrections
    and drops rebase pend rather than clear it.
  - *Withdrawal.* An overlay batch is dropped only on knowledge: its
    durable record differs (the correction above), its writer's boot
    changes (seen on its next frame), its writer goes down in presence, or
    the history knows its ops once the view has reached its target and
    they were not confirmed (they landed on another line, or the view
    already holds them), which drops the overlay with one correction.
    Nothing is armed while idle.
  - *Measured* (Linux, two daemons on one relay, a 15 KB file, an edit every
    3 ms on one device): edit to the other device's buffer delta p50
    0.52–0.85 ms, p90 1.4–1.6 ms, against 1.7–1.9 ms and 2.4–2.8 ms through
    durability. When both devices type into the same file at once (the sim's
    duet: two fresh buffers on two devices, 24 rounds of both typing within
    3 ms of each other, every keystroke checked to land exactly once on both
    buffers and both client documents), 2710 of 2736 keystrokes over 57
    seeds are shown live before they are durable; the rest arrive durably.

## Storage

- Every segment is a logical journal stream. Physically, an engine stores its
  segments through `pack`, a `Vfs` that keeps small streams as extents inside
  shared append-only container files (an on-disk B+ tree maps stream ->
  extents) and promotes a stream to its own file once it grows past a
  threshold. Creating an object costs one record, not a file; ten million
  objects cost ten million small extents, not inodes.
- Truncating or replacing in place is never trusted to be durable. A
  shrink's new size and a rename can be lost in a power failure even after
  an fsync (portably across ext4, APFS and NTFS), so the old bytes and an
  old index can come back. Every file that is truncated or replaced in place
  therefore either binds its records to a generation that the authoritative
  state makes durable first (the mount's attribution log, a pack inode's
  recorded size), or is rewritten whole, renamed into place and published
  with a directory fsync (shadow generations, mount state slots, compacted
  containers). Inside the pack a file's size is an inode field, atomic with
  its group commit. Once promoted to its own file, a file opened with
  `Group_Visible` (journals, the history's state kv and `lv.idx`) keeps that
  property: its recorded size is authoritative and the first open after a
  crash cuts the file back to it. The pack reports this as the
  `Durable_Size` capability (every byte below the size it reports is
  committed), as it does for its inline streams, and a journal on such a
  file never scans for a torn tail: its durable length is the size. Only a
  journal without it (a plain file) scans forward from its checkpoint
  sidecar, which is written unsynced and may lag. Damage is `Corrupt` only
  below a length known durable: the durable size, the checkpoint (the scan
  starts there), or the caller's floor (the open answers `Corrupt` rather
  than cut below it, and the repair restores the record from the relay
  copy). Above it the scan cuts at the first record that does not verify,
  even when a later one does: writeback is unordered, so a crash can keep a
  later unsynced page and lose an earlier one, and that data was never
  durable. A length query never recovers: `journal_peek_len` reads the
  length (the size, or the scan end from the checkpoint) without writing. Scanning a pack journal
  stopped at the first record that did not verify and truncated there, so a
  flipped bit in an old record cut every later durable record (seen as an
  own stream going fatal with no crash). A promoted file is created fresh and
  exclusive, never by truncating a leftover.
- Durability is batched across objects: every journal written in a loop
  tick is committed with one container fdatasync. `Async` (the C API
  default) runs the commit on a worker thread and completes it on a later
  loop wake; `Deferred` runs it on the loop. Nothing derived depends on the
  mode, and the simulator picks the mode per seed, modelling the worker as a
  commit job that runs at a scheduled later time. Compaction rewrites cold
  containers so each stream's extents stay contiguous, keeping page reads to
  one or two preads.
- A staged handle (`pack.stage`) gives one writer commit scoping: its writes
  stay out of the log until that handle's own sync, which applies them inside
  the current batch, so no other commit can make them durable; closing it
  unsynced discards them. A small file promoted through a staged handle
  becomes a sized external file: the inode records the size of the last
  staged sync (written after the file's fsync, in the same commit), staged
  bytes past it go straight to the file, and the first open after a crash
  truncates the file back to that size. Only staged syncs and truncation
  change the recorded size.
- When the pack commits off the loop, a sync of a promoted external file
  inside a batch does not fsync on the caller's thread: it marks the file
  dirty and the batch's commit fsyncs it on the pack worker, so a store's
  inline job (a tier evict's punch-and-sync) never blocks the loop, and
  its acknowledgement, which follows the batch's completion, still follows
  the fsync.
- The unit of durability is the batch, not the tick: settle commits a batch
  of its own under the tick of the one before it. Every enqueued batch takes
  the next batch sequence; a command's result carries (as `tick`) the
  sequence of the batch that will hold its writes, and a `Durable` event
  carries the sequence of each completed batch, so a result is durable
  exactly when a `Durable` event reaches its value. Key material an own
  segment needs commits before the batch that uses it; a puncture commits
  only after the batch holding its zero-fill.
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
  - Add before use: nothing outside the inline batch becomes durable before
    the batch state it names, with one deliberate exception: ownership. A
    registry object row whose `own` bit turns on, and its owned entry,
    commit (synced) when the writer is created, before the first own record
    is appended, so `own` is durable no later than any own segment byte.
    The reverse order left a window where a crash after the batch but
    before the row kept an own segment the registry did not mark own; it
    was adopted only if the device wrote the object again, so otherwise it
    was never uploaded. The window this order leaves instead, `own` with no
    segment, is closed by the unclean open below, which clears it before
    spaces load and before anything reads `own`. Nothing leaves the device
    on the strength of the bit alone: what `own` drives (catalog rows, grant
    cards, publishing) rides batches at or after the first own record's.
    The own mark means "this device writes this object", not "this device
    holds data for it": an own Text or File_Tree with no local history yet
    is a normal state (a git mount waiting for its history, a writer created
    before its first record). Catalog participation is written when the
    writer opens and holds data, never inferred from the mark; the unclean
    reconcile lists only own objects whose own stream exists.
    Key trees and space rows commit at once, so an own key tree is durable
    before any own segment byte. A copy-on-write omap file inside the pack (map tables) writes
    and syncs its pages at commit but keeps the new meta page in memory,
    tagged with the open batch; the meta is written and synced only once that
    batch is durable, after the registry rows that batch made eligible, so a
    crash at any point leaves the previous meta valid. At most two pending
    metas are kept per file (the oldest unpublished one and the newest), the
    newest eligible one is the one written, and compaction waits while any is
    pending. The registry is a copy-on-write omap file outside the pack.
    A synchronous registry commit writes its pages, a barrier, the newest
    meta and a sync; content marks commit lazily (pages only, the new meta
    kept in memory, so every reader, compaction and synchronous commit
    sees them). Each pack commit's job publishes, on the worker and before
    its commit record, the newest meta taken when the commit started:
    barrier, the meta into the slot not holding the last published one, a
    sync, all under the Db mutex a synchronous commit and compaction also
    hold; a meta older than one already published is skipped. Commit-job
    hooks run in order before the commit record, and each hook's done runs
    once on the loop when the job ends; the odb install is the first, the
    registry publish the second. Journals use sized external files
    (committed size in the inode). Small sidecars (replica `.have`, floor slots) are inline or
    replaced by rename, which is batch metadata.
  - Registry: on an unclean open, before spaces load, `own` and the owned
    entry of an object whose own segment is absent or empty are cleared (not
    created yet), content and promotion marks are clamped to the recovered
    own stream, and a checkpoint length past it is dropped. This applies to
    Conversation and Map segments only; a Text or File_Tree history may
    legitimately be absent under an own mark (above).
  - Unclean-open work is marked durably, not read from the pack's in-memory
    unclean bit: an unclean open first commits a registry mark (cleared in
    the same transaction as the registry fixes above) and, once spaces load,
    one mark per space (cleared when that space's catalog reconcile and
    pending-republish scan have both run). The pack's superblock stays
    unclean until those marks are durable. A close in between, including an
    open that fails after the pack recovered, therefore never skips the
    work, and a space first opened in a later incarnation still gets it. Legacy registry
    rows migrated into the redaction log are deleted only after the batch
    holding their replacement records is durable.
  - Map tables: `ROOT_CONSUMED[self]` rides the same copy-on-write commit as
    the entries; it is checked when the table opens (and the writer opens the
    table before its first append) against the recovered own stream, and a
    table ahead of it is reset.
  - `.children` slots: before the first slot write after a sync the header is
    rewritten as dirty and synced; a clean header means the slots reflect
    exactly `covered`, a dirty one is rebuilt at open.
  - fs kv index: the same rule. After an open that trusts a clean header, the
    header is rewritten dirty and synced before the first slot write, so a
    clean header on disk never sits over slots that name log records a crash
    dropped.
  - fs history: the state kv is written only after what it reflects is
    durable. Each persist seals its writes into a group under the history's
    current mark (a new mark once the engine has taken the previous one for
    a batch); reads see the open writes, then the queued groups newest
    first, then disk. When the batch carrying a mark completes, the groups
    up to it are committed in order, each atomically (a marker record ends
    every commit; recovery keeps whole commits only), after `lv.idx` is
    synced. Groups outlive sleep, and a handle whose history awaits
    durability is not closed, so a crash only ever leaves the kv behind its
    journal, which replay closes. Every commit also carries the own journal
    length as a stamp, and `lv.idx` must cover exactly the graph's lv range;
    a stamp past the recovered journal, a short `lv.idx` or a corrupt state
    still rebuilds at wake: derived keys are dropped, keys that no record
    carries (sources, pins, blob versions, mount aliases and conflicts) are
    kept, and the history replays its journal and streams. Replay applies a
    redacted batch's replacement in its place (and serves any read of a
    zero-filled own record from its replacement while replaying, so a
    replayed redaction never loads a file without the batch it redacted),
    pauses at any own record (a batch, a redaction, a seal) that answers
    Not_Found because what it reads is not readable yet (a remote stream
    its text depends on, at wake); each such record loads before it
    mutates or is idempotent on rerun, and replay resumes when a catch-up
    next runs; it also pauses at an own batch whose
    parents are remote until those arrive (own sequence numbers in the
    paused region stay reserved, so local writes meanwhile never reuse an
    op id), and treats any other refusal of an own batch as corruption. A
    rebuild keeps meaning: the graph's actor order is saved before the wipe
    and interned first, so every persisted inode id and lv names the same
    actor afterwards, and a rebuild epoch moves the search index's per-tree
    lv source so the tree is reindexed.
  The simulator checks all of this after every engine open: registry facts
  against the own streams, and every map table, `.children` file and fs
  history against a rebuild of its sources cut at the positions it consumed. `SIM_PROMOTE`
  shrinks the promotion size so derived files are promoted.
- `pack.durable_size(path)` (engine wrapper `durable_len`) is the one answer
  to "how much of this stream is on disk": the longest prefix guaranteed to
  survive a crash. A container stream's write counts once its commit group
  is durable, a promoted stream's once its file is fsynced (with the
  batch that syncs it, when that is deferred to the commit), a truncate
  counts at once; bookkeeping exists only for streams written since the
  last durable group.
- Nothing is published or announced beyond that length. The replicator
  takes it from the store through `Replicator_Config.durable` on every
  upload and every note, never from the writer, so no stream kind (own
  segments, keys and keys-head, members, cards, checkpoint streams, promoted
  objects) can put a non-durable byte on the wire, and a wire nonce (the
  record offset) is never used for two different plaintexts after a crash.
  The engine re-pumps waiting streams when a batch becomes durable, and
  stages each tick's keys and keys-head records before the batch ends so
  they are durable with the data they open and still reach the relay first.
  The simulator checks it at every step (no byte handed to the relay beyond
  the store's durable length) and after every restart (every stream recovers
  at least what it sent, and the relay holds no more of a node's own object
  streams than the node has durable). So on a correct device the relay is
  never ahead of the local durable length of the device's own stream, in
  every durability mode: there is no lost own tail to adopt after a power
  cut, and a device never treats its own stream as a replica.
- **The relay copy of an own stream is checked, never trusted.** When the
  relay reports more of an own stream than the upload cursor, the replicator
  reads that range back and compares it, record by record, with the local
  bytes in wire form. A relay record that does not open as this device's own
  sealed write (or, in a transparent space, fails its record check) is relay
  tampering: `Relay_Misbehaving`, the connection drops and the check runs
  again on the next connection under the normal connect backoff, which keeps
  growing while the relay keeps tampering; it is never fatal and arms no
  timer of its own. A local record that fails its own check is local
  corruption: it is never sealed or uploaded. It is caught when the upload
  reads it, when the verify reads it, when any read of the writer's journal
  hits it below the durable length (the journal's damage hook), or by
  `scrub`, which walks every own object stream and catalog. `scrub` is an
  explicit call for the embedder (at quiesce, say); nothing schedules it, so
  detection otherwise stays event-driven: on read, on verify, and at open,
  where chain recovery reads through the same hook. A hook offset is only a
  hint: the engine finds the first damaged record by walking the local
  stream before it rechecks that range against the relay. A damaged record
  the relay already holds is restored from the relay copy (see journal), and
  the stream resumes once the restore is durable. The durable restore also
  re-drives what the damage made the engine skip, without a timer: the
  object's pending republish (its handle could not open, so the stream's
  unuploaded tail was never registered again) and its derived state (a map
  table reset, a conversation reindexed), which a redaction of another
  device's range could not purge while the handle was damaged; own
  redaction intents are retried every tick anyway. One the relay does not
  hold (never uploaded, or below the relay's base, as for a promoted object
  whose bytes live on peers), or one in a stream the relay keeps no bytes of
  (device storage class), is lost. Every consumer of a damaged own record treats it as a
  missing range, never as an I/O failure, so damage is never an engine
  failure: a map table resets clean and its reads park until the restore is
  durable, which wakes them; catalog updates that hit it park off the tick
  and resume with the restore; a command that hits it parks on the object
  until the check ends, then completes, or fails with `Corrupt` if the
  record is lost; a synchronous call answers `Busy` while the repair is
  pending, and so does every read (conversation status, page, window,
  message, siblings and intents, map get and scan, text and tree reads,
  listings and conflicts)
  that reaches the damaged object, which waits instead when it was given a
  ready callback, never `Not_Found` or `Corrupt` for a record the restore
  will bring back; a record found lost reports `Corrupt` on that one object while
  every other object and space runs on. An own conversation or map whose
  writer cannot open because recovery hit damage below the durable length
  (a record the chain walk or a floor-bounded scan reports through the hook)
  opens as a damaged handle with no writer: its reads take the damaged-read
  path, its writes answer `Busy` or park, and the writer reopens on the first
  refresh after the durable restore. The runtime's `attach` over a damaged
  catalog defers its runner steps (advertise, recovery) on a catalog read
  waiting for that restore, an event, never a timer and never an error. A relay that reports more of the stream than is durable
  locally, which a correct device never causes, is read back from the local
  durable length: bytes that open as this device's own sealed writes, or two
  different records that are both valid, can only come from a second device
  writing under this device id (a restored backup or a VM snapshot of the
  device), and the stream stops with `Conflict`, surfaced as a fatal event
  whose detail says a clone is suspected. A claimed length the relay cannot
  serve, or bytes that do not open, are tampering like any other. A relay-side redaction of an own record is
  tolerated and applied locally (`Local_Redacted`).
- **Read answers are checked against the request.** The relay answers
  reads in request order and announces a segment's base with `Hollow` or
  `Trimmed` before the `Data` that starts there (relay-protocol.md 7.2 and
  8.2). The client keeps its outstanding `Read`s and `Tail`s in request
  order, and each `FINAL` answer must belong to the oldest one and start at
  its `from`, at the base a preceding `Hollow`/`Trimmed` raised it to, or
  where that read's earlier frames ended. A `Refused Not_Owner` answers it
  too. Any other answer is `Relay_Misbehaving`: the connection drops and the
  reads are issued again on the next one, so a withheld `Hollow` never
  leaves a read's in-flight range waiting on an answer that already came.
- Redaction punches holes in extents and erases every copy: stale extents of
  the file, copies a defragmentation made and superseded within one write
  (zeroed as garbage), and the garbage of deleted files, whose pending zeros a
  redaction makes urgent. A stale extent is recorded under
  `S | inode | file offset | container | offset` with its length, split into
  pieces of at most 1 MiB, so erasing a range reads only the stale pieces
  that start within 1 MiB before it, not every stale extent the file ever
  had. Compaction drops the stale records of every data record in the
  container it reclaims, so the stale set is bounded by garbage still on
  disk. Deletes are tombstones until a merge that includes the base run; one
  is scheduled once the tombstones written since the last such merge exceed
  a quarter of the base run's entries, so deleted keys do not pile up in the
  ranges later scans read. The simulator substitutes its own disk
  beneath `pack` exactly as beneath plain files.
- A range of another device's conversation segment zeroed by the relay
  purges the index for every message whose last block lies in the range.
  The engine finds those messages in a seal map kept in the registry
  (`ROOT_CKPT`: `0xf3 | object | device | last block | position` to the
  message, and `0xf4 | object | device` to the replica ranges already
  scanned). A lookup scans only the held bytes outside that coverage and
  past the zeroed range, since a seal follows its last block and the
  zeroed records read as redacted. Once 32 KiB of held bytes are outside
  the coverage, the lookup scans all of them and commits their seals and
  the grown coverage in one transaction. A lookup therefore reads at most
  32 KiB of records plus its share of those commits, however far behind
  the tail the range lies (sim `seal_scan`). Leaving a space drops both.
- Redaction in the device object store is a durable scrub intent
  (`objects/info/0ndb-scrub`: targets, protected blobs, superseded commits and
  trees). It is written and synced before the first irreversible step (the
  journal or stream zero-fill), so a crash or a failed removal anywhere after
  it leaves a record. `odb.redact` rewrites the `refs/0ndb/` commits without
  the targets, moves those refs, repacks the store without every target and
  superseded object no other root reaches, then checks every one is gone from
  each loose path and unpinned pack of the primary directory. Only a
  verified scrub, after a barrier, clears its entries; anything left fails
  the call and stays in the intent, which the next redaction and every
  store open resume. What it can't reach: an object reachable from a ref
  outside `refs/0ndb/`, `HEAD` or a reflog (the user's own or pushed history,
  never rewritten; counted as protected), an object in a pack git pinned with
  `.keep` or `.promisor` (counted as pinned), alternates and extra object
  directories, and copies outside the store (other clones, remotes, the
  user's working tree).
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
- Holds: `Hold{key, reason}` is an intent that stays pending until an
  `Unqueue` with outcome `released`. A Hold replaces any pending Hold with
  the same key, and releasing key `*` releases all of them. While one is
  pending and nothing runs, is queued or waits, the conversation's status is
  `held`, which the catalog carries like any other status. The key is
  opaque: `land` for an isolated task's land conflicts, `line:<mount>` and
  `undo` for held lines and rewinds. A held run (`Interrupted` with a
  reason, below) is the run-level half: it parks one reply. The Hold intent
  is what gives the conversation the status `held`, so holding a run on a
  line goes with `Hold{key: line:<mount>}` and resuming it releases that
  key.
- Runs: `Claim{msg, runner, lease, lines, bound}` when a runner starts,
  `Unqueue` for what it consumed, `Seal` when done, `Superseded` when a
  reassignment made a duplicate. Each run writes its own lines of every
  mounted tree and fast-forwards the conversation's lines on success
  (`Landed{run}`), all mounts together. `bound` is the (mount, tree, line)
  of each mounted tree as the run starts: the branch key of a folder's git
  checkout (`git:refs/heads/<name>`, `git:detached:<commit>`), else the
  conversation's line; the catalog row carries the same binding (tag 16). A
  run whose line leaves the disk is held at its next tool boundary (after a
  tool result, or before the next model step): the harness is interrupted,
  its native session kept, and `Interrupted{msg, last_block, attempt,
  revive, reason = branch_changed | branch_deleted | undo, line}` puts the
  reply in the `Held` open state, which crash recovery never revives and
  which keeps the conversation from starting another run. When the line
  returns (`line.resume`, or the line-switch event) the run is revived with
  native session resume and a note saying whether the branch moved
  meanwhile. Holding touches neither the mount's line nor the disk.
  (planned, replacing run lines) A run writes on its bound line live,
  `Landed{run}` recording its result; only a duplicate claim's run writes on
  its own run line, dropped when `Superseded`, and an isolated task's run
  writes on its fork's lines.
- Mounts: `Mount{name, tree, line, path}` and `Unmount{name}` change which
  file trees a conversation works on; zero, one or many, from any
  workspace. Moving to a message (a switch, an edit, a regenerate, an undo)
  restores every mounted tree to that message's versions together.
- Conversation branches are owner-scoped and carry their files. The *task
  tree* of a conversation is it plus every task its turns spawned,
  transitively; ownership is derived (scope → task row → parent chain), never
  stored on ops. A branch of conversation A selects which of A's tree's ops
  its lines carry: switching branches set-reverts the A-tree ops only the old
  branch has and restores those only the new one has, transformed through
  everything since; other trees' ops on the line are never touched. Alone on a
  line this is exactly a line switch.
  - *The invariant.* A conversation's line always carries its current branch.
    So every version recorded at a message (a turn's start, a landed end, a
    park) is a valid base: a set revert of A's set to base W leaves A's content
    as it was at W and keeps every other writer's ops. Every move is that one
    operation per (tree, line), with A's set exactly as for an undo (below) and
    the base by cause: a switch to leaf L takes the park version of the move
    that last left L (or a message on L's path below the fork), else the
    start version of L's first reply after the fork; an edit of user message U
    (sending with a parent other than the current position) takes U's turn
    start, moves the leaf to U's parent, and the new message follows; an undo
    of T takes T's turn start; a redo is a switch to the undone position,
    restoring the leaves the undo recorded. A turn starts from its
    conversation line's head, so landing is a fast-forward unless another
    writer moved the line meanwhile, and the union then only merges those
    writers.
  - *The move record.* A move is the staged `Undo` record below with `cause`
    (undo, redo, switch, edit, regenerate, rebase), `from` (the position left,
    also when following the tip) and `to`; every `Fenced` set line records
    `park`, the line's version at the fence, before any revert, which a later
    switch back to `from` takes as its base. Each move writes one `Undone`, so
    every left branch stays switchable and nothing is deleted. For a switch
    the tree's tasks split by A's paths: tasks spawned on the old-only path
    are held, reverted and hidden; tasks on the new-only path and on the
    shared prefix stay outside the set.
  - *No loop syncs.* A move's records and reverts ride the pack's batch
    commit, which is atomic across streams, and materialization waits for
    that batch, so no phase fsyncs on the loop. The mounts of a reverted line
    wake at once, and `switch` answers once every local mount of the reverted
    lines holds the revert on disk.
  - *Concurrent moves.* Positions are per device, the line is shared. Moves
    order by their staged record (hlc, then device). A device whose newest
    move (within ten minutes) was staged elsewhere moves its own leaf to that
    move's target. The device of the newest move, once it is released, checks
    every earlier move's reverts against its park versions; one it did not
    see, or its own position having left its target, makes it write one
    `rebase` move to its own target with its own bases, so the line ends on
    exactly the winner's branch on every device. Only the winner rebases, so
    rebases never race each other.
  - *The moves in the API.* `switch` (67) moves to a sibling's newest leaf. A
    `send` (60) under a parent other than the position, or with `root`, is
    an edit: a move to that parent, then the message. `edit` keeps editing
    queued intents only. `regenerate` (177, a reply or its user message U)
    moves to U with the reply's turn start as the base and then answers U
    again as a new sibling reply: the runner answers a released regenerate
    move whose U has no reply newer than the move, so it works on any runner
    device and resends U as it was, attachments included. An undo of the
    first turn, like an edit of the first message, moves to before the first
    message: a `Leaf{root}` record puts the position at the root
    (`Summary.leaf_root`), and the next send starts a new root sibling.
    `convo.undone` (178) lists the left branches (the newest move per left
    position, with its cause and target), each switchable back with `redo`
    or `switch`. A park lookup takes the move that left exactly the target
    leaf first, and only without one a move that left an ancestor on the
    target's path. There is no leaf-only `back` and no per-turn `go_back` or
    `revert`; `follow` from a browsed position is a move to the tip first.
- **Undo** of turn T of A rewinds A's whole task tree to T's start, as a set
  revert (fs) per line plus leaf and session rewinds, driven by one staged
  record.
  - *The set.* A's task tree is A plus every task its turns spawned,
    transitively (scope → task row → parent chain). Its set is the scope actors
    of the `Scope` records of every conversation in the tree, every actor
    registered with a conversation of the tree as owner (the revert actors of
    earlier undos and redos, so undoing T' < T after undoing T reverts the
    first undo's copies and deletions too, and the rewind actors of turn
    reverts), and the ingestion actors of its tasks' fork mounts (home and per
    line). Landed and merged ops keep their scope actors, so a land needs no
    actor of its own. A scope actor belongs to one conversation: every scope a
    run opens (the turn's and each tool call's) writes as
    `ingestion_actor(device, scope_pseudo(conversation, mount, line))`,
    registered with the conversation as owner, never as an actor shared by
    every conversation of an agent, so an undo of A never reverts another
    conversation's writes. The line is the run's own line, so a held or undone
    turn never leaves the next turn's actor with a last op its line lacks. The
    set and each (tree, line) base are resolved once, after the hold and the
    fence (a running turn writes its `Scope` only when it ends), into the
    `Undo` record of the `Fenced` phase; every device reverts exactly those
    actors from that base, whatever registrations or records it has received
    since. Everything else is outside the set and survives: a person's own disk
    and buffer edits made during T, other trees, git and imports.
  - *Versions and lines.* A turn's reply records its mounts' versions as the
    turn starts, after the start fence, so the fold of `Msg.files` deltas along
    the ancestor chain of T's reply gives each mounted tree its version `V_T`
    (a task's base is the fold at its first reply at or after T; a conversation
    with no reply after T wrote nothing to revert). The user message's own
    deltas are not enough: on a runner they are empty and the fold would fall
    back to the previous reply, the version at the previous turn's start. Every
    (tree, line) the set wrote after T is set-reverted with base `V_T` on that
    line (a tree first mounted after T has an empty base and A gets an
    `Unmount` back to T's set). A tree no device mounts is reverted through its
    history (`tree_revert_set`, committed like an API write); mounted devices
    materialize what they see.
  - *Checkouts.* A folder whose checked-out branch changed during T moves back
    to its line at T (a `line.switch`, no carry) only if A's tree made that
    switch and no other conversation has runs bound to the folder's current
    line; otherwise the checkout stays, the Undone record says so and the
    owners get the passive notice. Undo never moves a git ref, and never pulls
    a branch from under another chat. As built, who made a switch is not yet
    recorded, so no checkout is moved: a home folder whose mount is on another
    line than the conversation's (not a run line) is listed in `Undone.kept`
    and gets a `Notice{kind = checkout}` in A (runtime `checkouts` hook).
  - *Heads.* Heads at T's start are derived, not recorded: each task's
    conversation head is its newest record with `hlc < T.hlc` and its provider
    head the last raw provider line recorded before T, so a task caught
    mid-turn rewinds at a provider-line boundary; every replica derives the
    same answer. A native session rewinds through its driver (`rewind` to that
    head); where a provider cannot, the task gets a fresh native session seeded
    from its conversation up to the derived head, never the newer session kept
    silently. As built, the rewind is lazy: the undo moves the leaves, and the
    next run of each conversation finds its parent is not the native head and
    rewinds (claude `--resume-session-at` + `--fork-session`, codex
    `thread/fork` at the parent's turn) or, when that fails, restarts with a
    fresh session whose first prompt carries the seed (a queued prompt takes
    the seed when the fallback is taken, and a claude process that exits on the
    fork keeps its prompts for the relaunch).
  - *The record.* `Undo{id, msg = T, redo, phase, set}` (convo kind 46) in A's
    conversation is durable and replicated, so any device that opens A resumes
    or rolls it forward (`convo_undo`, `convo_redo`, `convo_undo_drive`). Each
    phase appends one `Undo` record with the same id (`Staged`, `Held`,
    `Fenced` carrying the set, `Reverted`, `Moved`, `Leaves`, `Rewound`,
    `Released`); the fold (`undos`) takes the highest phase, and a phase's
    record is flushed durable before the next phase's effects start. Phases run
    in order: hold (`Hold{undo}` and `Interrupted{reason = undo}` on every run
    of the tree, waiting until each has sealed or is held), fence (every mount
    of the tree's lines syncs), reverts per (tree, line) and the `Undone`
    record, `Unmount` and checkout moves, `Leaf` records (A's leaf to T's
    parent, every task's to its derived head), native session rewinds, release.
    The hold, the fork mounts of a conversation, the rewinds and the release
    are runtime hooks (`Undo_Hooks`). Each step is idempotent: every revert
    marker carries the undo id, so a resumed step first looks for its revert on
    that line (`tree_undo_revert`), a written `Undone` is never written again,
    and a leaf already in place is not set again, so no crash leaves files
    rewound while conversations are not, or the reverse. The task tree is the
    catalog's parent chain from A; a task whose parent message is at or after T
    is hidden. Undoing a turn that is still running holds it first. The runtime
    implements the hooks: hold sets a `Hold{key = undo}` intent on every
    visible conversation of the tree and `run_hold_request(.Undo)` on its local
    runs, and answers pending until none is running; the driver is re-driven
    when a run is freed and every 2 s while an undo is pending, and after a
    restart from the runtime state map (`undo/run/`). Release declines the held
    reply of every run the undo held, puts its mounts back from the run line on
    the conversation's line (the held turn's writes stay on the run line, the
    undone timeline) and releases A's hold; the other tasks stay held (paused)
    until `undo.resume` (`0ndb continue`) or A's next run. Ops: `undo`, `redo`,
    `undo.resume` (174–176); CLI `0ndb undo`, `redo`, `continue`.
  - *The undone branch.* `Undone{undo id, T, old leaves, reverts (tree, line,
    revert actor), checkouts left in place, hidden tasks}` (kind 47) records the
    undone timeline; nothing is deleted. Tasks spawned after T's start go with
    it, hidden and paused. Switching back is a redo, the same staged record: a
    switch to the undo's `from` (a set revert of A's set to the undo's park
    versions, transformed through anything written since, with conflicts kept
    as alternatives), the old leaves and sessions, and the hidden tasks
    reappearing paused. After an undo or a
    redo the tasks are paused; one resume action, or simply sending in A,
    continues every task that was running from its head. Undoing again after new
    sends reverts only what came after the new turn's version.
- (planned) Other trees are owner-scoped out of an undo, with one rule for the
  invariant: where another tree's edit lies inside text the undo removes (it
  rewrote a line A had inserted or changed), that region reverts to its text
  at `V_T` and the edit is kept as a revert conflict alternative, offered back
  in one action (`tree_conflict_accept`); a file A's tree created that another
  tree edited is removed with that tree's content as the alternative; every
  other edit survives byte for byte. A tree whose `Observe` records show it
  read or began writes on versions containing the reverted ops, or that lost
  a file or a checkout to the undo, gets a passive notice: a durable `Notice`
  record (kind 48: undo, from, kind, tree, line, paths) in its conversation
  naming the files and the accept action, which
  the catalog and views show as a badge, and from which a note is derived
  once into its running agent's next tool result. Humans see the record,
  agents get the note; nothing is asked and nothing blocks.
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
runner policy, takeover policy), setup (`.agents/setup`, linked ignored files) and access.
Conversations may belong to a workspace or not, and mount any subset of its
file trees (or trees from elsewhere). A runner materializes a conversation's
mounts side by side under one root it gives the agent as its working
directory, each a clone with alternates or a reflink copy, so a turn that
spans many repositories sees them all and every write is attributed to the
right tree.

## Agents

An agent is a map: instructions, driver (a harness provider or the native
model loop) with model and options, tools (built-ins, MCP servers), memory
(objects it reads and writes), triggers, budgets, default workspace,
runner policy and takeover policy. Conversations name the agent that answers them.

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

- **Shared by default** (planned). A task mounts its parent's lines in the
  same directory and writes on them live, attributed per scope, with
  concurrent overlaps as reported conflict regions (fs, Shared writers).
  **Isolated** is opt-in per spawn or agent profile (`isolate: true` on
  `spawn`, or `options.isolate` on the agent; the spawn argument wins). Until
  sharing lands, a task that sets neither works on forks that land only
  through `merge`, and `isolate: false` works on the parent's lines. An
  isolated task's mounts are forked from the parent's lines and run in the
  task's own directory. Every turn that completes lands them into the
  parent's lines: its open run line if it has one, else its conversation
  line. Overlapping edits stay in the fork as diff3 markers, and nothing
  lands while any remain. The task is then held: a `Hold{key: land}` intent
  gives it catalog status `held`, and `task.status` and `result` list the
  paths. `merge` refuses while it is held. The next completed turn lands once
  the markers are gone, and releases the hold. Its live diff against the
  parent is `subscribe.fork_diff`. A task's merge is an ordinary change on
  the parent's line.
- (planned) A second top-level conversation in a folder on the same line simply
  shares it. One bound to another line of that folder waits (`waiting:
  <folder> is on <branch>`) and starts when the folder returns to its line;
  embedders may set `busy_line = .Fork` to run it in an automatic fork.
- (planned) Catalog rows of tasks and conversations carry their `(mount,
  line)` and conversation branch. Views show the folder's current line; tasks
  bound to other lines are listed under "on branch X" as held, undone-timeline
  tasks under their branch. Switches and undos delete nothing.
- Tools: `spawn`, `send`, `wait` (any/all/condition, with timeout), `list`,
  `cancel`, `result`, `merge` (land an isolated child's lines). The native
  loop has them built in; harnesses get them through the 0ndb MCP server
  (`mcp`), so a Claude Code captain orchestrates exactly like a native one.
- Waiting is a record (`Await{tasks, condition, deadline}`), so a captain
  resumes after a crash or on another runner without losing its place.
  Wake-ups come from object change events, never polling.
- Budgets and cancellation flow down the task tree; usage and status roll up
  through the catalog. Agent-to-agent messages are records written into the
  recipient's conversation by the sender.
- Placement of every run is the embedder's `Scheduler` (a host plug over
  the C ABI and the daemon, answered asynchronously); runners advertise
  capacity, installed and signed-in providers, a display name and their
  pool in the `0ndb:runners` map.

## Moving between devices and runners

Everything a run needs is objects: the conversation, its agent, its
workspace, its mounted trees (checkpoint plus tail), its memory, and the
provider's native session (exported into an object after each turn, imported
by the next runner). A run moves by assignment; the new runner fetches only
what it touches, tail first.

Moving work to another device is intentional. A stopped runner is usually
stopped on purpose, so when one goes away its work does not follow the next
live runner by default:

- **Takeover policy** `default | auto | never`, stored on the conversation's
  catalog row, the agent and the workspace (most specific wins). Under
  `default` a device runner's work goes *idle*: placement reports `idle`
  with `last_runner`, the cut-off message stays where it was, and a normal
  placement event lets UIs refresh. A pool runner's work becomes a
  placement request naming that runner (`waiting_runner`); the scheduler
  answers it, the reference answer being the same runner, whose sandbox
  keeps the checkout and build caches, for the host to wake; a host may
  name another runner. `auto` hands the work to the scheduler with the
  runner excluded; `never` waits for the same runner. The policy covers
  message runs, claims that were never taken up, queued intents and
  scheduled runs (which fire on the runner that created them). Revival of a
  runner's own cut-off turn after it restarts is not a move and always
  proceeds.
- **Placement** prefers the conversation's last runner (the newest
  assignee, else the newest message's runner), and for a child conversation
  with none of its own its parent's, so side chats see the same files. The
  `Placement` handed to the scheduler carries `prefer` and `exclude`.
- **Resume** is `assign(conversation, runner)` without a message: the
  runtime assigns the cut-off message (a turn mid-flight continues on that
  runner with full context) or the head, and moves the conversation's
  schedules whose creator is gone. Assigning a pool's member id records a
  request: the pool runner that last ran the conversation takes it, any
  other waits for the host to assign a concrete runner.
- **Runner directory** (`runners`, `subscribe.runners`): one entry per
  device and one per pool, never per pool machine, with state `online`,
  `offline` or `wakeable` (a member pool whose host can start or resume a
  runner), providers installed and signed in, and whether it is the
  conversation's current or last runner. Pushed on advert, presence and
  placement changes; nothing polls.
- **Not signed in.** A runner checks a harness provider's sign-in (its auth
  env or auth files) when a run begins: a provider that is not signed in on
  this device fails the run at once with an error block named
  `not_signed_in` whose text says how to sign in, and never spawns the CLI.
  The model list reports `signed_in` and the provider's `login` hint, so a
  client can grey a provider out before the user picks it.
- **Sleep and wake.** A sleeping pool runner's lease lapses. On wake its
  pool readmits it with an ephemeral lease token on its existing `Add` (see
  Runner pools), without enrolling again and without a membership record;
  its queued work runs once it is admitted.

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

Indexing runs in slices on the engine tick and never holds the loop: each
tick indexes until a time slice (8 ms on the engine clock) or a file cap
(256 for a tree) runs out, and a tree's per-handle cursor keeps its place
inside an lv range, so a batch that touched thousands of files (a mount's
import) is indexed over several ticks without redoing the files it already
indexed.

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
- *No snapshots.* Nothing about an index is shipped to the relay. Every
  member device and runner can read the content it indexes, and rebuilding
  costs well under a second of CPU per megabyte of text (2,769 messages,
  2.3 MB, index from scratch in about a quarter of a second), so a fresh or
  wiped indexer rebuilds from content, while devices without a full index
  search through peer queries; runners keep a persistent local index like
  any device. (Snapshots were measured at 1.75x the information of the
  conversations they indexed, plus merge rewrites and checkpoint
  zero-fills, to save one download at restore.) A device upgraded from a
  version that published snapshots retires them once per space: it shreds
  its snapshot objects, zero-fills its `ckpt/0ndb:search` records and drops
  their registry rows; an interrupted snapshot import found at open
  rebuilds the index.
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
  returns free heap to the OS once and sleeps until the next event. Idle
  release (the relay host and the engine's settle) only ever trims the heap:
  it never pages out code or empties the working set, which would refault
  hot pages after every burst while the OS reclaims clean pages under
  pressure by itself. `docs/relay-protocol.md` is the normative
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
- **An open handle is eventually fresh.** Every open object handle follows
  its members' segments: maps, texts and trees fully, conversations by length
  only (`full = false`), with or without a subscription. A length beyond the
  replica raises its logical length (`Grew`) and moves the view's tail, so the
  next read fetches the new records; a non-fresh read still never waits on
  the network for them. Without this, a conversation replica fetched
  mid-stream was served stale forever, because every later handle reopened
  the non-empty replica and nothing asked the relay again. Handles close when
  the engine settles (only pinned ones stay), and closing unfollows, so while
  idle there is no follow state and nothing is armed. Measured per followed
  segment while its handle is open: on the device, a 33-byte feed pattern in
  filtered feeds plus one 40-byte `Follow` entry on open and one `Unfollow`
  entry on close (the 1168-byte `Remote` and its replica are already held by
  the open handle); on the relay, a 16-byte `Sub` and an 8-byte follower
  pointer per connection, plus one resident 120-byte `Stream_State` and its
  store stream (an open file on the file store) shared by all followers.
- **A fresh read probes a segment once per connection.** The relay length a
  fresh read needs is kept by the replicator, not the handle: each stream's
  answer (a probe reply, or a feed entry for a followed stream) is cached for
  the connection and cleared on the next `Welcome`, and a probed stream joins
  the feed patterns, so every later relay-side change updates the cached
  length. A fresh read of a stream with a cached answer takes that length
  (raising the replica through the same path as a feed entry) and sends no
  probe; one without an answer probes. So a reader that polls fresh reads in
  a loop completes after at most one probe per segment per connection, even
  though handles close at every settle. A follow alone is not an answer: a
  conversation followed by length learns lengths only from later feed
  entries, so its first fresh read still probes.
- **A fresh read never answers from local data while the link is down.**
  For a space with a relay and an object with segments of other devices, a
  fresh read on a disconnected space reconnects at once (the backoff timer
  is replaced by an immediate attempt) and stays pending; `Connected` wakes
  the space's fresh waiters and the retried read probes as above. A
  connection attempt that fails (the transport does not open, or the link
  closes before `Connected`) marks the space offline until the next
  `Connected` and answers every fresh waiter in it with `Offline`; so does
  a space that cannot connect at all (revoked, refused, lapsed lease, no
  transport). An `Offline` answer emits `Unavailable` per remote segment.
  Local-only spaces and objects whose only segment is the device's own
  read locally as before.
  Replication of a space stops (a refusal, a lapsed lease, a leave) only
  once the space is drained: it is marked draining so no handle acquires
  a replica, its handles close through the normal path, which commits
  their own writes, and a handle that cannot close yet (an untaken history
  mark, a commit under pack pressure) holds the stop until a later durable
  batch retries it. The replicator, which owns every replica, is destroyed
  only when no handle holds one, so a refusal that is later lifted keeps
  every own write, and only the erase of a left space discards.
- **Direct messages.** A participant can send an opaque frame to another
  participant of the same space by device id. The relay delivers it to one
  live connection of that device or answers `Undelivered` at once; it keeps
  no state beyond delivery and cannot read the payload, which the endpoints
  encrypt end to end. Cross-device search and sign-in approvals use it.
- **Connection liveness.** Two mechanisms, neither of which wakes an idle
  device:
  - *Dead peers* are the kernel's job: every relay socket gets TCP keepalive
    (idle 120 s, interval 30 s, 4 probes on Linux, macOS and Windows) and on
    Linux `TCP_USER_TIMEOUT` 240 s, so a vanished relay, a half-open
    connection or a dropped NAT mapping closes the link within minutes, idle
    or not.
  - *A relay that stops answering* is caught by the request deadline: while
    the client awaits anything (Hello, an append's acknowledgement, a read,
    list, probe, get, put, feed or account request) the replicator arms a
    10 s tick, and a request that makes no progress for more than a full
    tick while queued output is not draining fails the link with `Timeout`,
    20 to 30 s after it was sent. The replicator then reconnects with
    backoff and republishes unacknowledged appends from the durable journals.
    With nothing awaited the tick is cancelled, so this is a heartbeat only
    while requests are outstanding. A device that sends its first request
    after a long idle is covered the same way. Progress is tracked per
    stream and reply family (probes, follows, everything else), never per
    stream alone: a reply or a new request in one family never refreshes an
    older unanswered request in another, so a stream with steady probe
    traffic cannot hide a read the relay never answers. A new request never
    refreshes older ones in its own family either; only a reply or partial
    data does.

  Limitation, by design: an idle connection to a relay process that is
  frozen while its kernel still acknowledges packets (stopped, or wedged
  without crashing) is not noticed, since keepalive succeeds and nothing
  is awaited. Live pushes (feed, presence, direct messages) stop until this
  device sends a request or the relay recovers. Nothing is lost: every
  write is in a durable journal and the feed resumes from its cursor, and a
  relay in that state serves no one. Closing the gap would need a ping
  while idle, which the idle rule rules out.

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
`Seal{subject, epoch, wrap}` (epoch keys for a non-leaf runner), `Revoke{grant}`,
`Scope{subject, add, object}` (add an object to, or remove one from, a guest's
scope; authorized like adding, respectively removing, that guest).
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

**Grants to guests** (`engine/grants.odin`, `sync/grants.odin`).
- **The share.** `share_object` hands the recipient an out-of-band share: the
  object key and the object keys of the epochs known at share time, wrapped
  to the recipient, plus a capability for the relay. Each epoch entry is
  `tag [12] | order u32 | view u32 | wrapped key`, where `order` is the
  epoch's place in the sharer's resolved roster and `view` the number of
  membership records that roster was resolved from. When the sharer knows
  more epochs than a share holds, it keeps the newest below its current one,
  and the current epoch goes last.
- **The grant record.** The share also appends `Add{kind guest, method
  grant, scope [object], role reader or member by access}` to the space's
  membership, so every member knows the grant. Scoped members are not tree
  leaves and don't count toward epoch eligibility, so a grant never forces a
  rotation. A guest's scope is a set: sharing another object of the same
  space with the same guest appends `Scope{guest, add, object}`, and the
  re-wrap covers every object in the scope.
- **Re-wrap.** Whenever a member's membership pass sees a current epoch
  (after a local change or a remote resolve), the member elected as for
  rotation does the re-wrap (`_members_elected`: lowest present admin leaf
  of that epoch's tree, else lowest present leaf). For every active scoped
  guest, and every object in its scope that has no wrap for that epoch
  yet, it appends a record to its own stream `grantkeys/<object hex>`
  (object scope, epoch 0, in the writer's namespace):

  ```
  1 | grantee sign [32] | epoch tag [12] | order u32 | view u32
    | bytes(seal(grantee box,
                 ctx "0ndb grant key" ‖ object ‖ order u32 ‖ view u32,
                 number u32 ‖ object_epoch_key [32]))
  ```

  `order` and `view` are as in a share; the seal's context binds them, so
  a changed value makes the wrap fail to open. When another epoch of the
  roster has the current epoch's number (two admins made it concurrently),
  the member also re-wraps an epoch it already wrapped whenever its view
  has grown past that wrap's, so after a partition heals the merged
  roster's choice reaches the guest with the largest view.

  There is one stream per (writing member, object), holding the wraps for
  every grantee and epoch of that object, so it grows with
  epochs × grantees. A guest's capability admits its object's grantkeys
  streams for reading.
- **The guest.** A guest follows the object's grantkeys group and opens the
  wraps addressed to its key. It adds each new epoch tag, or a larger view
  of a known one, to its persisted grant epochs and unlocks held key trees
  on any new grant epoch, not only on space epochs. A keyless guest has no
  roster of its own, so its current epoch for the object, which it seals new
  writes under and judges a writer's key tree stale against, is the grant
  epoch that is largest by (number, view, order, tag): the epoch the most
  complete roster any member wrapped for it resolved as current. Members
  take theirs from their own roster, the same order. A guest writes the
  objects it holds a Write grant for and not the space's catalog, unless it
  holds a Write grant on the catalog itself, so it queues no catalog update
  (participant, activity, status) for a catalog it cannot write; a catalog
  write refused with `Permission` is dropped and counted
  (`catalog_refused`), never an engine failure.
- **Revocation must rotate.** `share_revoke(object, grantee)` removes the
  object from the guest's scope (`Scope{guest, remove, object}`), or removes
  the guest when it was the last object, and the revoker commits a new space
  epoch at once. The guest still
  holds the current epoch's object key, so without the rotation it would
  keep opening new writes. Normal rotation ignores scoped members;
  revocation is the exception. Removing the guest is the only thing that
  stops re-wraps; grants survive their sharer leaving the space.
- **Expiry is not revocation.** When a grant's capability expires, the relay
  refuses the guest at once, but cryptographically the guest keeps the
  object keys it already holds until the next epoch advance. A guest member
  whose `expires` has passed gets no further wraps.
- **Capabilities for several objects.** A guest holds one capability token
  per granted object. Credential type 3 carries up to 16 tokens for one
  space and grantee: `3 | n u8 | token × n | sign [32] | sig [64]` (type 2
  stays the single-token form). The relay authorizer verifies every token
  and grants the union, keeping per-stream access per object; the
  credential formats and the admitted stream set are specified in
  `docs/relay-protocol.md` section 6.5 (`sync/cap_auth.odin`). The CLI
  daemon keeps every token of a space in its credentials file.
  `accept_share` reopens an already open guest space so the link
  re-authenticates with the new token.
- **Pre-release format.** Grants made before this design carry no `Add` and
  are not re-wrapped; there is no migration.

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
  epoch it holds; if there is no epoch or the member's own leaf is missing,
  it commits; if the newest epoch is ineligible (a pending removal), one
  elected member commits: among the active leaf members of that epoch's tree
  that are present (this device, or `up` in relay presence), the lowest
  device id with role admin or owner, else the lowest device id. The others
  wait and re-elect on every presence change, so the election moves on when
  the elected member goes down. Every commit waits until the member's
  membership log has caught up (relay caught-up and every announced members
  stream read) so joiners do not fork the epoch chain needlessly. Members keep path
  secrets for the newest 64 epoch numbers so late concurrent commits still
  open; older ones are reached through back links.
- Remove is always followed by a commit by the remover, so the new epoch is
  sealed only to the remaining members. `0ndb rotate` / `space_rotate`
  commits with no membership change (suspected compromise).
- **Leaving.** `space_leave` (`0ndb leave SPACE`) appends a self-signed
  `Remove` for this device and, unless `device_only`, for every active
  device of the same signed-in account (`person` = the account and method
  `account`, `genesis` or `recovery`) that this device's role may remove
  (owners any, admins non-owners; the rest are reported as skipped). It is
  refused with `Permission` when no active owner would remain outside the
  leaving set; an account-wide leave counts the account's own key and
  devices as leaving. The leaver cannot commit for others, so it appends no
  commit; the newest epoch turns ineligible and the elected member rotates.
  The leaver records `(space, leaving, members stream length)` in
  `pack/left` (write to a temporary file, sync, rename, sync the directory).
  Once the relay holds the removal (its upload floor of the members stream
  reaches that length, or it refuses this device with `Auth`, which it does
  only after observing the removal), the engine erases the space at the end
  of a tick with no durable batch in flight: it unmounts the space's trees,
  deletes every object of the space from the search index and scrubs it,
  zero-fills, syncs and removes every object directory, the members
  directory, the card and any retired search snapshot files, drops the
  registry rows (objects, owned, grants, space), marks the entry `done` and emits
  `Space_Left`. Pack zero-fill makes the erase redaction-grade. A restart
  in the `leaving` state resumes the wait. The entry stays as a tombstone:
  notice adoption, account-notice reconciliation and account sign-in skip a
  tombstoned space, and an account-wide leave also appends a manifest entry
  with `left` set so the account's other and future devices skip it. An
  explicit `space_join_enrollment` clears the tombstone and appends a fresh
  manifest entry.

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
`Auth` on every connection (`relay_revoke`). On an `Auth` failure the engine
marks the space refused: a member it had loaded is marked revoked, pending
reads fail with `Permission` and `Access_Revoked` is emitted, and the
space's replicator stops at the end of the tick with nothing armed. Two
cases retry first. A runner with a fresh lease token presents it once, and a
lapsed runner asks its pool. A space that has not completed a hello in this
process, and whose own removal it does not know, may be refused only
because the relay has not yet ingested the records that admit it, so it
retries with the link backoff (250 ms doubling to 30 s, reset only by a
completed hello, not by the transport coming up), at most 6 times. A
refused space reconnects only on information that could admit it: a
members record it had not seen (a `JOIN` proof, an explicit join), an
account sign-in that lists the space, a new lease token, an accepted share,
a relay change, or a restart. Request principals may only send
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
  holding `(space id, name, relay, relay pub, anchor id, anchor lamport
  [, left u8])`, where the anchor is the account's own `Add` in that space.
  The last entry per space wins; one with `left = 1` (appended by an
  account-wide `space_leave`) means the account left it, and sign-in skips
  it. Older readers reject the trailing byte as malformed and skip the
  entry.
- **Account notices** carry spaces created or joined after sign-in to the
  account's other signed-in devices live, since no device holds the account
  key to read the manifest again. Every signed-in device keeps the account
  link open (the keyless pseudo-space in the account namespace, the same
  connection as presence and approvals) and writes its own stream there,
  `stream_id(notices_scope(account), device, "notices", epoch)`, an
  ordinary journal with the device's signed chain (seed = the stream id,
  plaintext). The relay lets account principals read every stream of the
  namespace and append only to their own (`docs/relay-protocol.md` 6.3).
  Records (`sync/notices.odin`):

  ```
  HELLO   1 | device sign [32] | device box [32] | device cert [64]
  JOIN    2 | target device [16] | space [16]
            | bytes(seal(target box, ctx "0ndb notice",
                         name str | relay str | relay pub [32] | proof bytes))
  REMOVED 3 | device [16]
  ```

  Every epoch begins with `HELLO`. A reader acts on a stream only after its
  first record is a `HELLO` whose key hashes to the stream's device id and
  whose cert verifies against the account, and only on records covered by
  that key's chain signatures. In each account space the lowest device id
  among non-removed admins with a verified `HELLO` (or this device) is the
  announcer: for every known account device that the space has never added,
  it appends `Add{device, admin, method account}` and a `JOIN` whose proof
  is that `Add`; for one added but never seen writing, it repeats the
  existing `Add` as the proof. The target adopts a `JOIN` by
  `space_join_enrollment` and opening the space, so the runtime then
  attaches and advertises it like any joined space; a space it already
  holds (joined, removed or revoked) is left alone, so replays change
  nothing. `device_remove` appends `REMOVED`; every reader stops trusting
  that device's stream, no announcer adds it again, and announcers remove
  it from spaces where it is still present, which starts a new key epoch
  there as usual.

  **Bounded growth.** Before an append would take the current epoch past
  64 KiB (`Config.notices_rotate`), the device writes epoch + 1 as one
  signed commit: `HELLO`, then the snapshot of its outstanding records
  (every `REMOVED`, and each `JOIN` whose target is not removed and has not
  yet written to that space's membership), and drops the old epoch once
  the new one is uploaded. It skips the rotation when the snapshot would be
  more than half the limit. Readers follow the segment groups of epochs
  `{0, 1}` and each known device's current epoch and the next one, move to
  a newer epoch as soon as it appears, and on every connection list the
  namespace and match unknown streams against the next 64 epochs of their
  device, so missing rotations while offline is harmless. Nothing is
  timed: each step reacts to the link, a membership change or a local
  write, so an idle device has no wakeups.
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
  it). A runner never writes a renewal record: its `Add` carries the first
  lease, and every later lease comes from its pool as an ephemeral token.
  On one timer (its only armed timer) a third of a lease before expiry, or
  on waking past it, it asks (`lease_lapsed`): it signs a renewal request
  with its device key, the host's `Runner_Pool.renew` decides whether the
  machine is still valid, and the pool answers with a `Lease{space,
  subject, issued, expires}` token per space, signed by the pool and capped
  at issued + lease_ms. The token is a hello proof: the relay admits it when
  the signer is the pool that added the runner, the runner's `Add` stands
  with no `Remove`, and it has not expired, and stores nothing. A session
  whose lease runs out is closed with `Auth`, and the runner reconnects with
  its newest token (kept locally and presented until it expires); a refusal
  waits for a renewal instead of revoking access. So neither uptime nor
  sleep and wake cost membership records. The pool remembers the leases it
  issued and seals each new epoch to the runners holding one; member
  listings show a runner as removed only after a `Remove`. Runners are not
  leaves: no epoch rotation per runner.
- What a runner writes when it starts is latest-state-wins and only when it
  changed: its advert in `0ndb:runners` and its indexer entry in
  `0ndb:indexers` are written once the map has loaded and differs, and
  stopping writes nothing (presence tells devices it is gone), so a runner
  that wakes a hundred times costs the relay what one start costs.
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
  every device sees. A runner key outlives its sandbox by at most one lease:
  after a lapse only the pool readmits it, and a `Remove` refuses every
  later token, including replays. Nobody can forge device-signed history (segments are
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
    admits any record and independent of record order. The catalog write
    goes through the catalog queue and lands with a later batch, while the
    tree's content mark (the own-stream offset up to which its blobs are
    handled) commits in the registry; so the same registry
    transaction that advances the mark past a remote-skipped blob also
    stores the URLs (`ROOT_OWNED`, key space ‖ tree ‖ `r`), and opening the
    space re-notes them into the catalog. A crash between the two can no
    longer leave a blob that is neither uploaded nor findable on a remote.
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
  assigned, then promoted) and `device` (strict device-only, for privacy:
  the policy never promotes on its own, but an explicit `object_promote`
  records `stored`, and in every mode a recorded `stored`, or a pending
  promotion mark, makes the device upload everything it writes afterwards
  as stored content). A `Storage_Policy` plug overrides per space and object.
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
  `length`. Feed compaction keeps the hollow flag. A full follower of a
  based segment resumes from the end of the stored suffix it holds, not
  from its contiguous prefix (which stops at the base), so a reconnect
  never re-reads the suffix, and wants the prefix below the base it does
  not hold (from the archive under a trim, from peers otherwise): no full
  follower sits with a gap below its base that nothing asks for. A base a
  reader knows only from the feed is
  confirmed with one relay read of the range before it pulls that range
  from peers: a device-held base can later become a trim, and the relay's
  `Trimmed` answer sends the range to the archive instead.
- **Content uploads follow durability.** Each owned file tree keeps an upload
  mark and a target in the registry (`ROOT_OWNED`). The target rides the
  pack commit that makes the tree's records durable: before each commit the
  engine raises it, lazily, to every open own tree's journal length and to
  each ending batch's tree lengths, and that commit's job publishes the
  registry before its commit record, whether or not the space replicates
  yet. A journal synced outside a commit (an External journal synced inside
  an open batch) can be durable past its target across a crash; the
  unclean-open audit raises such a target to the recovered journal. Uploads
  always run from the mark to the target and move the mark only when every
  blob in range is stored, and a replication start resumes every tree whose
  target is past its mark. A tree written while local-only is therefore
  uploaded in full on sign-in. Nothing lowers a target: setting a mark keeps
  it, and the open-time audit clamps both to the recovered stream.
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
  through its registry of the blobs its own tree records reference, kept
  for every blob it published whether it uploaded it or not (uploaded,
  remote-backed, device-only, over budget; one entry per key and per part
  of a chunked object), so a writer whose upload is still in flight, or was
  lost in a crash and redone, serves the bytes on its disk. An entry lives
  exactly as long as its blob is on the device for that space: the device
  store is never collected, so entries go only when a redaction scrubs the
  blob (the scrub intent reports its targets when it is noted, before any
  irreversible step, and the entries are deleted then; a serve request for a
  blob that is still a pending scrub target, or already gone, is refused
  and deletes its entry) or when the device leaves the space; seals exactly the sealed chunks of the requested aligned range as
  a `Put` would (blobs of 8 MiB and more are streamed once into
  `$DATA/serve/` and read by range) and answers in at most 256 KiB frames
  without record framing, 127 sealed chunks per pull. The reader decrypts
  and verifies each chunk with the object key exactly as a relay-served
  object; a bad holder is skipped and `Peer_Misbehaving` reported. With no
  holder online the engine emits `Unavailable{object, device}` per holder
  and keeps the read pending; that answer completes the request. A
  presence `up` re-drives every pending content wait in the space from the
  relay stage with its rounds reset, so a blob uploaded meanwhile arrives
  from the relay and one still held arrives from the holder; no wait is
  left parked on a request that was already answered. Device-only trees
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
  the rest. Only a tree that was device-only before the promotion moves its
  content mark to the checkpoint length (its earlier blobs were held, never
  uploaded, and a reader starts from the bundle because the segment is
  hollow below it). A tree that was already stored keeps its mark and its
  pending uploads: its readers replay the stored segment and fetch each blob
  as an object, so a blob whose upload was in flight at the promotion must
  still be uploaded, including after a crash. The base comes only from `Noted` answers to the promotion's own
  `Fill` frames, starting with an empty one; `Not_Found` means there is
  nothing to fill. A lost or withheld frame therefore stalls a promotion
  until the reconnect re-asks, and never makes it report a hollow segment as
  stored. Pending promotions are durable in the
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
    writer's tick commit plus one forward. The relay admits a `Live` by the
    same rule as an append to that segment, so a `Not_Owner` refusal of one
    means the segment's upload is refused too.
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
    every key-tree cell in `[first, end)` except the cells listed in the
    header as already punctured when the group was built ("holes"), then
    keyed BLAKE2b of the salt. Why redaction stays exact: (1) a redaction
    of a record punctures every cell of its byte range in the writer's
    tree (`keytree_puncture_except`, keeping only signature cells), and
    puncturing is one-way: the punctured leaves and every GGM node above
    them are deleted, so no state derived after the puncture can produce
    them; (2) a group built before the redaction did not list those cells
    as holes, so its key input includes their keys; (3) hence anyone who
    only holds post-puncture state (every device once it follows the
    writer's keys stream, and the relay, which never held keys) cannot
    derive the group key, and the group's ciphertext is as dead as a
    zero-filled record. Holes are public (the relay already sees which
    ranges were redacted) and only let a group built after a redaction
    skip cells that were gone before it existed; a record whose cell is a
    hole is archived as a redacted entry (length and commitment), never
    with content. Because a surviving group becomes unreadable to everyone
    after any redaction inside it, the other records of that group would
    be lost to readers that did not already hold them; that is exactly
    what Restore (below) prevents, and until it runs readers fall back to
    peers that hold those records. The salt makes every (key, nonce) pair
    unique even if a range is re-archived with different compression.
    Readers need no layout before decrypting. Correction of the earlier
    design: a key from "the group's record keys" cannot be derived without
    knowing which records the group holds; the cell grid needs nothing but
    the range.
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
    at the same offset, which reproduces the writer's ciphertext exactly;
    the simulator compares every rebuilt record with the ciphertext the
    writer uploaded). Elided signature records become inert signature
    records of the same length (`0xff` and zeros, sealed with the
    signature tag), which every reader already skips; redacted-form
    placeholders were tried first and broke text history, which waits for
    a replacement of any redacted record. The replica persists the range
    as archive-verified (a trusted list in its `.have` sidecar) so chain
    checks there use the archive, not the elided signatures. Paging both
    ways is unchanged.
  - Measured on a 4.16 MB synthetic tool-heavy transcript (2,769 messages,
    sequential repository source and agent text; zstd -3 1.03 MB, -19
    0.77 MB) recorded through `0ndb record`: the conversation segment's
    3.92 MB (0.81 MB of it signature records) archives to 1.20 MB in
    5 groups (1.30 MB with 256 KiB groups, 1.22 MB at level 9), the
    catalog's 713 KB to 7.6 KB; every record round-trips byte for byte.
    Archiving costs 80 ms per MB of segment (most of it the
    recompression check), reading 30 ms per MB, both off the append path.
  Integration (built, `src/sync/replicator_arc.odin`). The replicator
  archives every object segment it uploads (`replicator_publish` with
  `archive`; members, keys, cards and the feed never), once the relay
  advertises Trim and reads below base. A run starts when the
  acknowledged length passes the last seal by `archive_min` (engine
  `Config.archive_min`, default 512 KiB, negative disables). One loop
  turn builds one group from the writer's own journal (plaintext bodies;
  commitments taken from its signature records, so no keys are needed for
  the chain), appends it and a seal to the local archive journal, commits,
  records the sealed `B` in the upload floor slot, and publishes the
  archive stream; a backlog continues on the next turn, so no turn
  compresses more than one group. `B` is the end of a commit strictly
  below the acknowledged length, so a trimmed segment always keeps one
  stored commit and never looks device-only. `Trim{segment, B}` is sent
  only once the archive stream's upload floor covers the seal, and it is
  idempotent, so a crash anywhere leaves the segment whole: an unsealed
  group is ignored (the next run redoes the range and the newer seal
  supersedes it), and an unsent trim is resent after the next upload.
  A replicator frees a local only when it owes nothing: no upload, note,
  verify, repair, drop, failed floor sync, archive turn or owed trim, so a
  Trim refused Busy keeps its archive local open until the reply that ends
  the Busy resends it. The sim's final checks require every archive whose
  seal the relay holds to have trimmed its segment by quiesce; a scenario
  holds a writer's segment commits at the relay while its archive trims,
  so the Trim is refused Busy and the writer goes idle before the held
  Appended arrives.
  Readers: a `Trimmed` reply marks the remote; wants below its base become
  archive wants: the reader tails the writer's archive stream (an ordinary
  remote, chain-verified with the writer's identity and no keys), reads
  the last seal and the last full seal, fetches each covering group by
  its offset and length, verifies and materializes it. A group that
  cannot be opened or verified (its key punctured, its record
  zero-filled, a forged fold) marks the range broken and the reader pulls
  it from peers. Measured end to end on the corpus above (2,769 `0ndb
  record` calls against a pack-backed `0ndb relay --objects`, allocated
  bytes): the relay grew 4.07 MB instead of 6.99 MB; segments alone (the
  1.20 MB search snapshot object is in both) 2.86 MB instead of 5.78 MB:
  the conversation's 1.13 MB archive and 0.29 MB stored tail instead of
  3.92 MB, the catalog's 0.20 MB tail (and an 8 KB archive) instead of
  0.71 MB, plus pack containers and index runs. The object-store tier
  wrote 5.88 MB in 10 batch objects instead of 5.96 MB in 9: it flushes
  appends before they are trimmed and has no delete, so trimmed batches
  are garbage there (collecting them needs an object-store delete).
  Redaction: a record inside a group cannot be zero-filled
  alone, so the redactor (any
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
  As built: the writer's own records are re-archived by the writer (it
  rebuilds every group overlapping the redaction from its journal, checks
  the heads, seals, then zero-fills the old groups); a redaction notice
  for its own segment reopens the local on demand, so this happens even
  when the writer was offline at the time. Another writer's record: the
  redactor resolves the group (the writer's, or the verifying Restore with
  the most holes), rebuilds it with the record as a Redacted entry
  (commitment kept) and the record's cells as holes, checks the fold
  against the writer-signed `head_before`/`head_after` that every seal
  entry carries, and appends `Restore{target writer, arc_off, group}` to
  its own plain chained stream `rst/<writer>/<segment>`. Only once the
  relay holds that Restore does it zero-fill the source (the writer's
  group or the previous Restore) and send the segment redaction, so the
  engine's persisted redaction intent drives the whole sequence again
  after a crash. A reader that finds a zeroed group probes the `rst/`
  streams of the object's segment-group members, verifies each candidate
  (group key from its holes, chain fold equal to the seal entry heads,
  the redactor's chain on the stream) and materializes the one with the
  most holes; a Restore can hide records but cannot alter one. Readers that
  get the redaction notice zero their own archived copies that still hold
  the record. The sim has a new device read such an object with the writer
  offline and must resolve a Restore; every other device goes offline too,
  except, under device storage, those holding a device-held segment of the
  object (the redactor's own segment included), since no archive covers it.
  Any puncture of the writer's own key tree (a redaction or a draft key)
  re-archives every group touching the punctured cells, aligned to the
  cell size, so no group's key ever depends on a cell its writer has
  deleted; the rebuilt groups list those cells as holes.
  A replica may lose bytes underneath a persisted engine view: until-run
  and evicting storage drop them, a user or the OS clears the cache, a
  backup restores replicas from another moment than the engine state, a
  disk-full cleanup removes files. The engine never waits on a fetch it
  has not issued: a view read that finds a record missing reports the
  range it wanted and the handle asks the replicator for it; the text
  history asks for the exact record it failed to read when the replica
  lacks its bytes (a record held back only until a later signature
  arrives is the catch-up's to wait for, not a fetch); a follower whose
  segment turns out to be trimmed asks for the prefix it lacks, which the
  replicator serves from the archive; a waiter whose view reported nothing
  asks for the newest gap of the segment it waits on, from the gap's start
  (a record boundary) forward (at most 64 KiB, the
  same on-demand read a view makes, so the storage mode still decides what
  is kept). The sim forgets every remote
  segment of an object on a reader, restarts it with the writer offline,
  and requires the same view afterwards (conversations, texts and maps),
  and does the same for a segment held on devices below its base with the
  writer online.
  A fetch never repeats the same short window: a forward parse whose first
  record runs past the fetched bytes asks again up to that record's end, a
  backward parse whose last record starts before them asks again from that
  record's start, and an archive read that ends inside a record doubles its
  window. What to fetch is one rule everywhere: the first run of a range that
  the replica neither holds nor has in flight (a read or a peer pull); a
  want is fetched run by run, a want across a trimmed base sends its part
  below the base to the archive and only such runs above it to the relay,
  and a full follower resumes where the held suffix from the base ends.
  A requested offset the replicator cannot prove is a boundary
  (a have edge, zero or the relay length) is only a claim: a parse from or
  to a claim that meets a malformed or unverifiable record drops the claim
  and keeps nothing, and is not counted as relay misbehaviour, so a view's
  guessed window cannot turn a mid-record offset into a have edge. The sim
  shrinks the tail and fetch window to 1 to 5 KiB on a third of its seeds,
  so records and archive groups larger than the window take every path,
  and fails a run in which a node receives more than four times the
  distinct bytes it kept of a stream per connection plus 256 KiB.
  Map groups collect: a Put whose every field is matched or beaten (by
  register order) by a later Put of the same key in the same group becomes
  a length-only `Gone` entry, a run of them ends with the chain head after
  it (`Gone_Head`), and it materializes as a redacted placeholder. Sets and
  counters stay whole. Collection is per group, so redacting the
  superseding record rebuilds that group and the earlier value returns from
  the writer's journal; a Restore copies `Gone` entries verbatim. The sim
  rereads every trimmed prefix of every object through its archive and
  requires identical views (maps of every kind included), and compares
  every archive-materialized range on every node, internal maps included,
  with the writer's ciphertext.
- **Relay write amplification.** The usage counter is written once per
  group commit, not per append; the feed is folded when it exceeds twice its
  last folded size (64 KiB floor); and the relay's pack rolls its active
  container when half of it is garbage once it holds 256 KiB
  (`Options.roll_min`; engines keep `container_size / 16`), and any pack
  checkpoints as soon as a sealed container past the checkpoint is half
  garbage, since compaction only takes containers the index covers. On
  `tools/costbench` the relay's pack on disk drops from 3.70 to 1.11 MB (s1),
  1.23 to 0.70 MB (s3) and 2.22 to 0.66 MB (s4); s1's container goes from
  2.76 MB (25 KB live) to 30 KB.
  Pack-backed relay streams write appended and filled content through a
  staged pack handle, so a partial append can never become durable through
  another space's commit, and keep no length slot: a stream's length is its
  size. Only based (hollow or filled) and trimmed streams keep slots, for
  `base` and the trim flag. Measured on 2769 appends of 1.6 KB: across 40
  small streams the relay writes 14.23 MB instead of 14.48 MB (89 B less per
  append); into one promoted stream 5.57 MB instead of 5.61 MB (the 45-byte
  slot per append becomes a committed-size inode record).
  The pack store is atomic (`Relay_Storage.atomic`): an append's feed entry
  is queued when the append is submitted and flushed into the same group
  commit (`relay_core_prepare`, called by the store's worker before it takes
  a group), so an acknowledgement follows one fsync, not one for the
  segment and another for its feed entry. A `0ndb new` costs the relay 2
  fdatasyncs, one per client round trip (47 for five before staging, 30
  after it, 10 with coalescing).
- **Early pushes**: the relay keeps an append of up to 256 KiB in memory
  while the frame arrives when the segment has followers. When the frame
  ends, it pushes the bytes to every follower whose offset falls inside the
  append, before the commit. Acknowledgements, feed entries, `Created`,
  `Length`/`Probed`, reads and the length word of each `Data` still wait for
  the commit. After the commit, a follower that already has the bytes gets one
  empty `Data` announcing the length. A follower may therefore hold bytes past
  the relay's durable length. A crash loses them only on the relay, and the
  writer's resend brings back identical bytes (relay-protocol.md 7.1.1).
- **Device follows**: a device's replicator follows a remote segment on the
  relay (`Follow` at the end) only while an open handle wants it. The
  engine's handle open and close set this through
  `replicator_live_segments`. The follow ends when the handle closes, so an
  idle device holds no follows. Pushed Data lands up to its last whole record
  through the same staging, record checks and `_verdict` as a read, and is
  then announced as `Grew`. The later feed entry finds nothing missing, so no
  `Read` follows. Bytes past the announced length stay in the replica, and a
  resend after a relay crash rewrites only what is missing. The sim's
  `early_push_crash` crashes the relay whenever a device holds pushed bytes
  that the relay has not yet committed. It then checks that every replica
  matches the relay's durable stream byte for byte.
- **Relay writes** are host-chosen and never protocol-visible: an append is
  acknowledged once durable in the host's durable buffer (group-committed
  local files for the reference relay, Durable Object storage for a DO host).
  The reference relay commits each worker group off its loop: the group's
  jobs stage into the pack, `batch_end_async` hands the commit (and the
  fsync of any promoted file a staged sync dirtied) to the pack's worker
  thread, and the group's acknowledgements go out when that commit completes
  through the loop's wake. The loop keeps serving reads and other spaces
  meanwhile, the next group stages behind the commit in flight, and the pack
  never runs two commits at once. On a disk with 20 to 40 ms fsyncs, other
  clients' p99 during a device's cold sync fell from 181 ms to 56 ms (the rest
  is the member authorizer's roster fsync and the local object store's
  atomic writes, both still on the loop)
  and any object-store flush is coalesced per space and asynchronous. With
  `--objects` the reference relay's tiered store writes one batch object per
  space once the space has been quiet for `--flush-ms` (default 30000), its
  oldest unflushed change is `--flush-max-ms` old (default 600000), or every
  `--flush-mb` MiB
  (default 8); a per-space manifest in the pack, marked dirty in the same
  group commit as a window's first change, makes the tier crash-safe, and a
  redaction rewrites the batch objects that hold the range. The pack is a
  hot cache, not a second copy: once a batch object and the manifest records
  naming it are durable, the tier appends an `Evict` record (stream, offset)
  for each stream it carried, keeping the last `--hot-kb` (default 256 KiB)
  plus anything the manifest does not cover contiguously from the stream's
  base, and only then punches that prefix out of the pack (a crash between
  the two leaves bytes in both places, never in neither). An open stream
  builds its cold index (watermark and `Seg` records) on first use and
  keeps it current while open. It does not read the space's manifest for
  that: each stream has a sidecar in the pack (a tier-reserved stream)
  holding copies of its `Seg`, `Evict` and `Drop` records, each slot being
  the 64-byte record, its manifest offset and a checksum, and an index
  mark stream records how far into the manifest every sidecar is
  complete, with the sidecars' bytes, which space usage excludes like the
  manifest's. The manifest stays authoritative and the sidecars are
  derived: after each manifest commit the tier appends the commit's
  records to their sidecars and only then advances the mark (a
  commit with nothing to index advances the mark in memory, and durably once it
  lags 64 KiB). A reader takes its sidecar's slots below the mark and
  scans the manifest past it. Opening a space copies the manifest past the
  durable mark into the sidecars, skipping slots already there by
  manifest offset, so a crash between the two writes is caught up, never
  trusted. A torn sidecar tail is padded to a slot boundary and its
  invalid slot skipped. Opening a stream therefore reads its own records
  and the unindexed tail, not the space's history (sim `tier_index`: 480 B
  per open in a space of 96 streams, against 37 KB from the whole
  manifest, and a crash sweep across a flush and its indexing). Reads
  below the watermark are
  ranged GETs from the batch objects (asynchronous: `Object_Store.read`
  completes later, the connection that needs the block is parked and
  resumed through `Relay_Storage.on_ready`, concurrent reads of a 256 KiB
  block share one request), `sendfile` is refused there, and a
  redaction reaching below it first restores the range into the pack from
  the objects, lowers the watermark durably, then redacts as before. A
  thaw whose object reads keep failing is never refused: after three fetches
  it is parked unanswered and re-driven by the next successful object read
  or put, or by a backoff timer (1 s doubling to 60 s) armed only while a
  thaw is parked. The device keeps the redaction in its redaction log until
  the relay answers and resends it on every connect, so a relay restart
  re-drives it too. A
  redaction is acknowledged only once a `Redacting` record naming its range
  is durable in the manifest; once every batch object holding the range is
  rewritten (the rewrite's GET and PUT are asynchronous, serialized per
  object, and a rewrite that keeps failing re-queues the redaction for the
  next flush) the tier appends the matching `Redacted` record, and a restart
  re-queues every `Redacting` record without one, so a crash between the
  acknowledgement and the rewrite cannot leave the old bytes in the object
  store. A stream is never evicted while a redaction of it is in progress
  or not yet rewritten into the objects. Streams the core or the authorizer
  read synchronously are pinned by class and never evicted, whatever their
  length: reserved streams (feed, redaction log, tier manifest) and every
  device's members stream (recognized by the space's members suffix), so
  authorization never waits on the object store. Every other read of a
  stream goes through the parked asynchronous path. Slotted
  (based or trimmed) streams stay whole in the pack. Measured with
  `tools/costbench` s1 (1062 transcript messages): the relay's pack on disk
  drops from 4.71 MB to 3.60 MB, the 1.23 MB conversation segment holding
  0.27 MB (its hot tail); the rest is container garbage awaiting compaction.
  The relay counts
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
  resumes from there); quota applies as for appends. An empty `Fill` is
  always mismatched: it is how a promotion asks for the base. A `Fill` may
  come from a replica that predates a redaction of the segment, so the relay
  keeps a per-stream index of the ranges its redaction log records (built
  from the log when the space's log opens, extended on each redaction) and
  applies the overlapping redactions to the fill's bytes before they are
  written, in the form a stored redaction takes (redacted tag, zero body);
  a fill whose records don't frame inside a redacted range is refused
  (`Protocol`). A piped `Served` chunk from a holder gets the same transform
  before the relay forwards it; a chunk that cuts a redacted range off its
  record boundaries is answered `Unserved`, so the requester fetches it
  elsewhere. Ciphertext a writer redacted is therefore never on the relay's
  disk, even transiently, and never forwarded. As a second line, a stream opened from
  storage re-applies any recorded redaction over stored bytes not yet in
  redacted form. A device that zero-fills its replica of another device's
  segment for a redaction it learned of emits `Replica_Redacted` (object,
  writer, range in `tick`..`length`); from then on no replica on it holds
  that range unredacted.
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
  marks the base as a trim; `base` must stay below the length, a lower base
  or a repeated trim changes nothing, a base equal to a device-held base
  only marks it as a trim (followers get `Trimmed`), and `Fill` below a trim
  stores nothing. Reply `Noted` once durable; no feed entry.

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

Tree API ops (`tree_read`, `tree_list`, `tree_write`, `tree_remove`,
`tree_blame`, `buffer_open`) act on one line of the tree: an explicit `line`,
else the line of this device's mount of the tree if one is live, else
`main`, and every result names the line it used. A read sees the tree at
that line's version and a write is parented on it and advances it, so an
edit on a device whose folder is on a feature branch lands on that branch.
When the line is at the history's heads (the only case with one line), the
loaded state is used directly, exactly as before.

A whole-file write never removes what its reader did not see. `tree_read`
and `tree_list` return the version they read (`base`), and `tree_write`
takes one and has no baseless form: the write is the line-granular diff from
the file's text at `base` to the new text, committed as a batch parented on
`base`, so the CRDT merges it with everything committed since, including
disk edits a mount ingested after the read. The line then advances to the
union of its version and the new batch. A path absent at `base` is created.
A `base` the history does not hold is refused.

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
appended to the op table. `buffer.open` is a subscription: its result (the
daemon's subscribe result, or the first callback of `ondb_subscribe`) is the
`open` record with the first page, and its later payloads are `delta`,
`cursors` and `closed` records of one `BufferEvent` layout
`{kind, buffer, rev, ack, length, text, more, actor, line, ops:[{kind, n,
text, author}], cursors, status}`; unsubscribing closes the buffer. Anchors
cross the API as strings (`s`, `e`, or `<actor hex>.<seq>[.<offset>].<b|a>`).
The daemon advances a buffer only while its connection has less than
256 KiB unsent and kicks it when the socket drains. `web/0ndb.js` exports
`LiveBuffer` (the client half: pending edits, delta transform, paged
loading of unread ranges as holes, anchor and cursor mapping) over any
transport that speaks the JSON form.

## cli

The reference consumer, assembled from the default plug implementations:
`0ndb daemon | relay | runner | record | mcp | login | approve | devices |
members | remove | rotate | recovery-key | pool | pair | join | status | ls |
new | send | queue | steer | edit | switch | back | log | show | search |
interrupt | models | agent | task | workspace | mount | schedule | blame |
revert | land | share | redact | verify`.

`new` prints the created id once the create returns, then, while connected,
waits for `object.uploaded` so the printed id resolves on other devices at
once (offline it returns at local durability; a dropped connection or Ctrl-C
ends the wait with a note). The daemon API stays local-first; only the CLI
waits. Cost of that wait, measured with strace on Linux:
- On the device, exactly one full sync precedes the upload: the pack batch
  holding the create (on macOS one `F_FULLFSYNC`). Ack bookkeeping is synced
  afterwards, on the durability worker, off the wait's path.
- On the relay, one group commit per appended stream: five back-to-back
  syncs for a new conversation, which dominate on macOS.
- Separately, before the wait: the CLI's current-conversation pointer
  (`daemon.state`), one file sync plus one directory sync.

Measured `new` latency, median including process start:

| Platform | Before the wait | With the wait |
|---|---|---|
| Linux | 4.9 ms | 10.2 ms |
| Windows | – | 16 ms |
| macOS (97%-full APFS) | 73 ms | 169 ms |
