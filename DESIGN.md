# 0ndb design

0ndb records everything that happens in a worktree and in the agent sessions
that work on it, keeps that history forever at near-zero cost, and replicates
it between a person's devices through relays that do nothing but store and
forward opaque bytes.

The design is built around four ideas:

1. **Everything is a single-writer append-only stream.** Thread transcripts,
   session lists, commands from other devices: each is a log that exactly one
   device appends to. There is never a write conflict to resolve at storage,
   relay, or replica level. Merging happens only where meaning lives (session
   list fields are last-writer-wins by hybrid logical clock).
2. **A record's identity is its byte offset.** A message id is
   `(stream, offset)`. Offsets are identical on the writer, the relay, and
   every replica, so a remote device can page a transcript by fetching byte
   ranges from the end of a stream and following parent offsets. No index is
   needed anywhere for the common path.
3. **Worktree history is git's object model.** Snapshots are git trees and
   commits, written in git's own formats (into the repository's object store
   for git checkouts, into a device-wide bare object store otherwise). Content
   git already holds is never hashed or copied again. Diffing two snapshots
   costs O(changed), rollback costs O(changed), and every snapshot is
   inspectable with plain `git`.
4. **Sans-IO cores, one event loop.** Provider drivers, the thread writer,
   the sync client and the relay are pure state machines fed bytes and
   returning bytes. One thread per daemon runs an epoll/kqueue loop and is
   asleep (zero wakeups, no timers armed) whenever nothing is happening.

## Targets

- Idle daemon: 0 wakeups/s, RSS under 4 MiB with any number of threads and
  worktrees. Nothing per thread or per file stays in memory between events.
- Opening a thread with 100k messages: O(page) reads.
- Remote first paint of a thread: one round trip to the relay for the tail
  of the stream.
- Snapshot after an agent tool call in a 1M-file repository: O(changed
  directories), driven by the watcher; no full walk.
- Relay: one signature verification per connection, then byte copies
  (`sendfile`/`splice`); it never parses or decrypts records.

## Layout

```
src/
  prim/      ids, hybrid logical clock, binary codec, file helpers, event loop, child processes, paths
  journal/   the record log format (local, replica and wire), group commit, sparse replicas
  odb/       git object database: read loose/packed objects, write loose/packs, trees, commits
  textdiff/  line diff, three-way merge, blame
  snap/      worktree snapshots: ignore rules, dircache, scanning, watching, materialize, fork, land
  thread/    thread stream records: messages, blocks, branches, queue, pagination
  agent/     provider drivers (sans-IO) and the normalized event model
  sync/      keys, encryption, relay protocol, replicator client, relay server
  host/      the daemon: registry, commands, runs, attribution, local API
  cli/       the `0ndb` binary
tests/       a handful of end-to-end tests
```

Packages import each other with relative paths (`import "../journal"`).
Build: `odin build src/cli -out:bin/0ndb -o:speed`. Every package must pass
`odin check src/<pkg> -vet -strict-style` and also
`odin check src/<pkg> -target:darwin_arm64` (Linux is primary; macOS must
compile, with platform code in `_linux.odin` / `_darwin.odin` files).

Code style: idiomatic Odin, no comments, explicit allocators where lifetimes
matter, `context.temp_allocator` for per-event scratch freed by the loop,
errors as enums/unions returned as the last value, no global mutable state
outside `host`. No panics on bad input from disk, network or child processes.

## prim

- `Id :: distinct [16]u8`. `id_new()` is UUIDv7-shaped (48-bit ms time then
  random) so ids sort by creation. Hex encode/decode.
- `Hlc :: distinct u64` (48-bit ms physical, 16-bit logical). `hlc_now`,
  `hlc_observe`.
- Codec: `Writer` (appends to a `[dynamic]u8`) and `Reader` (over `[]u8`,
  sticky error flag) with `u8`, `u16le`, `u32le`, `u64le`, `uvarint`,
  `ivarint`, `bytes` (uvarint length prefix), `str`, `id`, fixed arrays.
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
  the owner (the host commits at most every 50 ms while streaming and
  immediately at message boundaries). Reads go through the same `Reader`.
- `Reader`: `pread`-based (no mmap: works on sparse files and keeps RSS
  flat), `record_at(off) -> (body, next)`, `record_before(end) -> (body, off)`,
  iteration both ways, small reusable buffer.
- Replica: the same file, sparse. Ranges fetched from the relay are written at
  their offsets; a sidecar `.have` file keeps the sorted list of present
  ranges. Reads of missing ranges return `.Missing` with the range, which the
  caller fetches and retries.
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
  own `gc`/`maintenance` recompresses later. Bulk writes (first snapshot of a
  large folder) go to one pack with its `.idx`; small writes go loose.
- Streaming: blobs larger than a threshold are hashed and written by streaming
  from the file and read by streaming, never held in memory.
- Trees: encode/decode git tree entries (mode, name, oid) with git's sort
  order. Commits: encode/decode tree, parents, author/committer, message.
- `exists(oid)`, `read(oid) -> (type, bytes)`, `stream(oid, writer)`,
  `write(type, bytes) -> oid`, `hash_file(path) -> oid`, `write_file(path)`.
- Refs: `update_ref(name, new, old)` via lockfile + rename, used to pin
  snapshot chains so git's gc keeps them.

## textdiff

Histogram diff over lines (with Myers fallback), unified-diff rendering,
three-way merge (diff3 with conflict markers), and a blame walker that maps
lines through a chain of revisions. Pure functions over byte slices.

## snap

A worktree is any directory registered with the host. Its state is a chain
of snapshot commits.

- **Snapshot** = git commit whose tree is the worktree content (respecting
  ignore rules), parent = previous snapshot, message = scope metadata. The
  chain is pinned at `refs/0ndb/<worktree-id>` (git checkouts) or in the
  device store's refs.
- **Dircache** (per worktree, under `$DATA/worktrees/<id>/`): for each
  directory path, the tree oid and per-entry stat signatures
  `(mtime_ns, ctime_ns, size, ino, mode)`. Stored as an append-only record
  file of directory records plus an on-disk open-addressing hash
  (path hash -> record offset); compacted when garbage exceeds half. Only the
  directories touched since the last snapshot are read.
- **First scan** walks the tree with parallel `getdents64`/`statx` workers
  (threads that exist only for the scan). In a git checkout the index is read
  once: entries whose stat matches reuse the index oid and the cache-tree
  extension supplies tree oids for whole clean directories, so a clean
  checkout snapshots without hashing a single file.
- **Watching**: Linux shares one inotify instance across all worktrees
  (directory watches, overflow triggers a dircache-guided rescan); fanotify
  with `FAN_REPORT_DFID_NAME` is used when permitted. Darwin uses kqueue/FSEvents.
  Events only mark directories dirty; no work happens until a snapshot is
  requested (end of a tool call, end of a turn, or a settle timer for edits
  by other actors).
- **Snapshot pass**: for each dirty directory read entries, compare stat
  signatures, hash only changed files, write blobs and the new tree,
  propagate new tree oids to the root, write the commit, update the
  dircache and the ref. Racy entries (mtime not older than the pass start)
  are always rehashed next time.
- **Ignore**: full `.gitignore` semantics (negation, anchoring, `**`,
  directory-only), `info/exclude`, core.excludesFile; folders outside git
  also ignore a fixed list of unambiguous dependency/cache/OS directories.
  `.git` is never tracked.
- **Diff**: two tree oids -> changed paths, skipping identical subtrees.
- **Materialize** (rollback, branch switch): take a snapshot first so the
  current state is recorded, then apply the diff from current to target with
  temp-file + rename per file, modes and symlinks, removing emptied
  directories. Disk content that differs from the recorded snapshot is never
  overwritten without being snapshotted first.
- **Git awareness**: HEAD branch and commit are recorded with each snapshot.
  Moving back to a message restores HEAD as described in Threads.
- **Fork**: git worktree (`git worktree add`) at the message's commit, or a
  reflink clone (`FICLONE` / `clonefile`, falling back to copy) for plain
  folders, then only paths that can differ are rewritten.
- **Land**: three-way merge of snapshot trees (base = fork point), file-level
  merges via `textdiff`, conflicts written only into the fork; land refuses
  while conflicts remain.
- **Blame/revert**: blame lines across the snapshot chain; revert a scope by
  three-way applying the inverse of its snapshot pair.

## thread

A thread is one stream written by its host device. A message's id is the
offset of its `Msg` record. Offset 0 holds the `Head` record, so 0 means
"none" in pointer fields.

Records (kind byte then fields):

- `Head{thread, created, worktree, provider, model, title}`.
- `Msg{role, parent, depth, jump, prev_sibling, fork_head, prev_leaf_event,
  cmd, hlc, snapshot, git_branch, git_commit, provider_session,
  provider_msg}`.
  - `jump` is a skew-binary jump pointer (level-ancestor and ancestry tests
    in O(log depth)).
  - `prev_sibling` is the newest existing child of `parent` when this one was
    created (0 if first). `fork_head` is the newest message in the thread that
    was created as a non-first child (itself, if it is one), so every
    message carries the head of the fork chain at its time.
  - `prev_leaf_event` links every leaf-setting event (`Msg`, `Leaf`) into one
    backward chain.
- `Block{msg, prev, index, kind, ...}` content of a message: text, reasoning,
  tool call, tool result, image, error, notice. Streaming text is appended as
  further `Block` records with the same `index` carrying the next chunk (`prev`
  chains a message's blocks backwards). Payloads over 4 KiB (tool output,
  images) are stored as git blobs referenced by oid with a preview.
- `Seal{msg, last_block, status, usage, provider_msg}` ends a message.
  Statuses: done, interrupted, failed, cancelled.
- `Leaf{msg, prev_leaf_event, fork_head}` the current leaf changed by
  navigation rather than by appending.
- `Queue{cmd, mode, text, attachments, prev_pending}` and
  `Unqueue{cmd, outcome, msg, prev_pending}`: the durable queue. Each carries
  the head of the pending chain so the pending set is read from the tail.
- `Scope{msg, kind, id, before, after}` attribution: snapshot commits before
  and after a tool call or turn.
- `Interrupted{msg}`, `Revived{msg, attempt}` crash recovery.

Semantics:

- The active path is the parent chain from the current leaf. Pages are read by
  following `parent` from any message. `page(before, limit)`.
- Siblings of `p`: newest fork child of `p` from the fork chain, then its
  `prev_sibling` chain.
- Switching to sibling `s`: the new leaf is the most recent leaf-setting event
  whose message is `s` or a descendant of `s` (walk the leaf-event chain,
  ancestry by jump pointers). This remembers every subtree's own last
  position and never disturbs siblings.
- Editing message `m`: a new `Msg` with `parent = m.parent`. Regenerating: a
  new assistant `Msg` under the same user message.
- Going back to a message restores the worktree to its snapshot and git to
  its recorded branch/commit (same branch if it still points there and is not
  checked out elsewhere, else a new `ondb/<thread>` branch; never move, reset
  or delete an existing branch). If another thread has worked in the same
  worktree since, or is running there, the thread forks into its own worktree
  instead; one thread never rewinds another's files.
- Queue: items run in order when the thread is idle. Steer injects into the
  running turn (native where the provider supports it, otherwise interrupt
  and continue with the steer text). Items can be edited or cancelled until
  they start. All of it survives crashes.
- Crash recovery: on startup the host seals messages left running as
  interrupted and re-runs recent ones (12 h, at most 3 revivals in a row)
  against the same provider session.
- The host keeps a derived child index (`parent -> newest child`) for writing
  `prev_sibling`; it is rebuildable from the stream and never synced.

## agent

Each driver is a sans-IO state machine:

- `start(req) -> argv, env, initial bytes`
- `feed(line) -> events, outgoing bytes`
- `send(prompt)`, `steer(text)`, `interrupt()`, `rewind(native_msg)` ->
  outgoing bytes or a restart request
- `capabilities`: native steer, resume, fork at message, persistent process,
  model listing.

Normalized events: session started (native id), message started, text delta,
reasoning delta, tool call started/updated/finished (id, name, input, output),
permission request, usage, turn finished/failed, native message id.

Every raw line from a provider is appended to the thread's local-only raw
stream before it is interpreted.

Drivers: Claude Code (stream-json in/out, persistent), Codex (app-server
JSON-RPC), Pi (RPC mode), Muse (`muse serve` JSON-RPC), and one ACP driver
for Antigravity, Cursor, Devin, Hermes and OpenCode. Provider wire formats are
known only to their driver file. `docs/providers.md` records each protocol.

Warm processes are pooled per (provider, session) with an idle timeout and a
global bound.

## sync

Identity and keys:

- Each device has an Ed25519 key; `device_id` = first 16 bytes of
  BLAKE2b(public key).
- A space (a person's devices) has a 32-byte secret. HKDF derives: stream
  encryption keys (per stream id and epoch), object keys, the stream-name key
  (stream ids on the relay are `device_id || keyed-hash(name)`, opaque), and
  the relay auth secret. Pairing: `0ndb pair` prints a code (space secret,
  relay address, relay public key); `0ndb join <code>` on another device.

Streams per device: `index` (session list and statuses, LWW per field by
HLC), `cmd` (commands to hosts), `thread/<id>` (transcripts it hosts).

Relay protocol (length-prefixed frames over TCP or a Unix socket):

- `Hello` challenge: relay nonce, client proves the space auth secret with a
  keyed MAC and signs with its device key; the relay then accepts appends only
  to streams prefixed with that device id.
- `List(since)` -> stream ids and lengths.
- `Append(stream, at, bytes)` -> ok(len) or conflict(len). `at` must equal the
  current length.
- `Read(stream, from, to)` -> bytes, served with `sendfile`.
- `Follow(streams with offsets)` -> the relay pushes appended bytes as they
  arrive.
- `Put(key, bytes)`, `Get(keys)` content-addressed encrypted objects.
- `Drop(stream)` for epoch compaction.

The relay stores each stream as one file and each object as one file, keeps
O(connections) memory, and never decrypts.

The local daemon speaks the same protocol on a Unix socket to local
clients, so a UI works identically against the local daemon whether a thread
is hosted here or on another device: it reads stream ranges, follows tails,
and appends commands to the device's `cmd` stream. A command is shown
optimistically until the host's stream contains a record carrying its `cmd`
id.

## host

`0ndb daemon` owns the loop, the journals, the worktrees, the provider
processes and the relay connection. It applies commands from its own and
other devices' `cmd` streams to the threads it hosts (cursor per source
stream, persisted), runs turns, records scopes, writes statuses to its
`index` stream and maintains the merged session list from every device's
`index` stream.

## cli

`0ndb daemon | relay | pair | join | status | ls | new | send | queue | steer |
edit | switch | back | log | show | interrupt | models | worktree | blame |
revert | land | verify`.
