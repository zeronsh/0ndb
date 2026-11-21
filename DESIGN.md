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

## Storage

- Every segment is a logical journal stream. Physically, an engine stores its
  segments through `pack`, a `Vfs` that keeps small streams as extents inside
  shared append-only container files (an on-disk B+ tree maps stream ->
  extents) and promotes a stream to its own file once it grows past a
  threshold. Creating an object costs one record, not a file; ten million
  objects cost ten million small extents, not inodes.
- Durability is batched across objects: every journal written in a loop
  tick is committed with one container fdatasync. Compaction rewrites cold
  containers so each stream's extents stay contiguous, keeping page reads to
  one or two preads.
- Redaction punches holes in extents; the simulator substitutes its own disk
  beneath `pack` exactly as beneath plain files.

## Objects

- An object is `(id, kind, key)`. Its history is the set of its segments,
  one per participant that ever wrote it. Segment records share one
  envelope: kind byte, links prefix (segment table refs, chain state,
  per-kind tail summary), fields with tagged encoding so records written
  today decode forever.
- References: `Ref{seg, off}` within an object; `(object id, Ref)` across
  objects. Objects reference each other freely (a conversation names its
  agent, workspace, parent task and mounted file trees).
- Every kind supports: paging from any tail with batched missing-range
  reporting, per-participant signed hash chains, per-record keys from the
  object's puncturable key tree, and redaction.
- A space is a key hierarchy and a relay namespace. Its catalog is a map
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

A map holds keyed last-writer-wins registers (by `(hlc, participant)`) and
add-wins sets, per field. Materialized views (copy-on-write B+ trees,
rebuildable) give any secondary ordering as a paged range read. Maps are the
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
retrain when any of them is deleted.

**Cross-device search.** Partial replication means a device can only index
what it holds, so search reaches across devices:

- *Full indexers.* A device can keep a full index of a space (opt-in per
  device and per space; on by default for CLI daemons and runners, off for
  embedders). It walks the space catalog and every catalog change, keeps a
  persistent queue of objects to index, and fetches their segments through
  the ordinary replicator, conversations and titles first, file trees only
  when configured. Nothing per object stays in memory between events and
  nothing wakes it at rest. It advertises itself in the space's
  `0ndb:indexers` map: its card (for encryption) and its coverage.
- *Peer query.* A requester sends one end-to-end encrypted query (an
  ephemeral X25519 key against the indexer's card, so only that device can
  read it) through the relay's direct-message path to an online indexer and
  gets one reply: refs only, `(object, record ref, part, score, hlc, match
  spans)`, a cursor, and a freshness vector, never content. The request
  carries the requester's card and a signature, plus a proof derived from
  the space secret when the requester is a member; a non-member is answered
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
- *Snapshots.* An indexer checkpoints its index as an ordinary encrypted
  object of the space: each immutable index segment once, then a small
  manifest naming the live segments and their exact per-source coverage.
  Snapshots are incremental and taken only at settle. A fresh indexer
  restores the newest manifest and catches up from there. Redaction
  supersedes the manifest and zero-fills and punctures the segments that
  covered the redacted record. Only space members can read a snapshot.
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
  encrypt end to end. Cross-device search is its only user.

## engine

The runtime: spaces, objects, runs, runners, triggers, channels,
orchestration, attribution, recording and change events, over the plug
points `Vfs`, `Keyring`, `Credentials`, `Transport`, `Authorizer`,
`Relay_Storage`, `Scheduler`, `Spawner`, `Write_Observer`, `Secrets`,
`Model`, `Http`, `Tools`, `Channels`, `Embedder`, `Providers`, `Clock`,
`Log`, `Search_Remote`. Any engine instance can be a runner or a full
indexer. Several engines can share a process to use several cores, each
owning a shard of objects.

## capi

`lib0ndb` (shared and static) with `0ndb.h`: opaque handles, plug points as
C function-pointer tables, binary or JSON payloads, no global state, no
callbacks on foreign threads except through the embedder's loop. The read
side (journal, thread, index, crdt, sync client) also builds for
`js_wasm32` so browsers read and decrypt streams directly.

## cli

The reference consumer, assembled from the default plug implementations:
`0ndb daemon | relay | runner | record | mcp | pair | join | status | ls |
new | send | queue | steer | edit | switch | back | log | show | search |
interrupt | models | agent | task | workspace | mount | schedule | blame |
revert | land | share | redact | verify`.
