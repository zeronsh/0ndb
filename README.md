# strand

Tracked, attributed, syncable worktrees. strand records every change to a
directory — whoever or whatever makes it — as operations in a causal history,
credits each change to the actor and scope (agent turn, tool call, shell
command) that produced it, and replicates the history between devices through
a pluggable sync layer.

It does not care which agent harness edits the files. An edit tool, `sed`, a
Python script, a formatter, a `git checkout`, or a human in an editor all end
up as the same kind of operation; the harness only decides how *precisely* a
change can be credited.

## Crates

| crate | what it is |
|---|---|
| `strand-core` | Pure data model: Lamport-stamped batches in a causal DAG, a sequence CRDT for text, an inode-based file-tree CRDT, line diffing, codecs. No I/O. |
| `strand-store` | SQLite persistence: append-only batches (LZ4), interned actors, snapshots, outbox, blobs, mount state. |
| `strand` | `Workspace` (history + store + events), `Mount` (filesystem watcher, ingestion, materialization, fences), attribution `Recorder`, change reports, blame, selective revert. |
| `strand-sync` | Sans-IO replication: `Replica` trait, `Client` and `Relay` state machines, memory and TCP transports. |
| `strand-cli` | The `strand` binary. |

## Model

**Identity.** Every operation is `(lamport timestamp, actor)`. Actors are
UUIDs, one per (replica, role): each device's disk ingestion, each agent, the
attribution recorder. An actor never writes from two replicas, so operation
ids are globally unique without coordination.

**Batches and versions.** Operations are grouped into batches: a contiguous
timestamp run by one actor, made on top of a *parent version* (a frontier of
batch ids). Admission rules: parents must be known, the batch must start after
its parents' largest timestamp, and an actor's runs may not overlap. A version
is a frontier; the DAG answers containment and computes differences by walking
both frontiers in descending timestamp order, so cost scales with divergence,
not history length.

**Text.** A file's text is a list of fragments, each a slice of one
operation's inserted bytes. Deletion marks fragments with the deleting op
(tombstones) instead of removing them, so every byte keeps a stable identity
`(insertion op, offset)`. Edits are splices `(at, del, ins)` in the *visible
bytes of the parent version*. Applying one on a replica that holds concurrent
edits replays it through a view of that parent (unseen fragments occupy zero
width); at an insertion point, concurrent insertions with a greater op id stay
to the left. That gives one order regardless of delivery order. Anchors
`(insertion op, offset, bias)` survive edits and resolve to where deleted text
used to be.

**Files and directories.** Entries are inodes named by the operation that
created them. Placement (parent + name), liveness, mode, line ending, symlink
target and content kind are last-writer-wins registers that keep their full
history. Operations address inodes, never paths, so a rename and a concurrent
edit commute. Name collisions get deterministic conflict names. Rename cycles
are broken by reverting the most recent move. Removing a directory removes
what its author could see; entries created concurrently inside it survive,
and keep the directory present.

**Views.** Any version, or "everything except these batches", can be read
exactly. That one mechanism powers historical reads, ingestion against stale
parents, change reports and selective revert.

## Mounts: from disk to operations

A mount binds a workspace to a directory:

1. **Shadow.** The mount keeps what it believes is on disk: inode, git blob id
   of the exact on-disk bytes, mode and stat per path. It also keeps the
   *synced version* the disk reflects. Both are persisted, so restarts don't
   rehash unchanged files.
2. **Ingestion.** A recursive watcher (FSEvents on macOS) feeds paths into a
   debounced reconcile pass. It respects `.gitignore` and `.git/info/exclude`,
   and waits for git's `index.lock` to clear. The pass compares disk with the
   shadow, uses stat first and content identity second, and records the
   difference as one batch by the mount's ingestion actor, **parented on the
   synced version**. Edits made while remote changes were arriving therefore
   merge through the CRDT instead of clobbering them. Text changes become
   line-granular hunks (histogram diff). Files whose exact bytes reappear
   elsewhere become renames, and so do whole directories, so identity,
   anchors and blame survive `mv`. Uniformly-CRLF files are stored as LF plus
   a line-ending attribute, round-tripped byte-exactly.
3. **Materialization.** Changes from other actors (remote replicas, revert,
   tools) are written with atomic temp-file renames. Before any write, the
   disk is checked against the shadow; anything not yet ingested is ingested
   first and the plan is recomputed, so no local edit is ever overwritten. The
   shadow is updated with each write, so the watcher's echo of a write is a
   no-op.
4. **Fences.** `fence()` writes a marker into the watched tree and returns once
   its event arrives and everything before it is ingested. If the marker
   never arrives, it falls back to a full rescan. Fences are what make
   attribution of a command's disk effects exact.
5. **Edit tools.** `write_file/rename/remove(actor, …)` record the change
   under the agent's own actor, then materialize it. The watcher doesn't
   re-ingest it.
6. **Offline changes.** On restart, edits made while nothing was watching are
   ingested against the persisted synced version. Changes that arrived from
   elsewhere meanwhile are merged and materialized.

## Attribution

A `Recorder` opens **scopes**: `Turn`, `ToolCall`, `Command`, `Revert`. A scope
fences every mount when it opens, so earlier disk changes aren't blamed on it,
and again when it closes, so none of its effects leak into the next scope. It
then records every batch committed in between by the agent's actor or by a
mount's ingestion actor. Scope records are stored in the history, so
attribution replicates.

* Edits made through an edit tool are authored by the agent directly.
* `python rewrite.py`, `sed -i`, `cargo fmt` and the like are ingested and
  credited to the command scope that ran them.
* External agents that write files themselves are credited at turn level.
* A scope whose closing fence couldn't confirm settlement (for example, git
  kept its lock) is marked **unsettled**. Reverting it is refused unless
  forced, because some of its changes may still arrive.

What you can do with that:

* **Change reports** (`report::Reporter`) list what changed that the agent
  neither made nor ran: edits as unified diffs (lockfiles and huge diffs
  withheld), plus created, removed and moved files and git HEAD moves. They
  are computed from a view that excludes only the foreign batches, so the
  agent's own interleaved edits never appear as someone else's.
* **Blame** gives every line the newest operation that wrote any of its bytes,
  resolved to batch, actor and scope.
* **Revert** computes the worktree as if a scope's batches never happened and
  commits the difference: a selective undo that keeps every later change by
  anyone else.

## Sync

`strand-sync` depends on local state only through the `Replica` trait
(`heads`, `unpushed`, `mark_pushed`, `integrate`, `batches_missing_from`), and
`Client` and `Relay` are pure state machines. Batches are immutable and
integration is idempotent and order-independent once causally complete. A
replacement sync layer (peer-to-peer, object storage, another server) only has
to deliver every batch eventually.

The bundled relay enforces admission per history: causal completeness, the
Lamport rule, and actor/timestamp uniqueness. Two options are available:

* **Full validation:** each batch is applied to a replica and refused if it
  doesn't apply, so one bad client can't poison the others.
* **Concurrency cutoff:** batches built on a version older than the cutoff are
  refused. The cutoff advances to what every known peer has confirmed, minus
  a grace window. This bounds how far back concurrent work can reach.

Rejected batches are reported to the author. A replica that receives a batch
that is causally valid but doesn't apply rebuilds its state from storage
instead of continuing with partial state.

## CLI

```sh
strand init                                   # adopt the current directory
strand watch [--sync host:port]               # ingest live, optionally replicate
strand run --agent codex -- python fix.py     # run and attribute a command
strand log                                    # batches with authors and scopes
strand blame src/main.rs                      # per-line provenance
strand changes --agent codex                  # what codex hasn't seen
strand scopes                                 # attribution scopes
strand revert <scope-prefix> --agent codex    # selective undo
strand relay --listen 0.0.0.0:7420 --validate # relay server
strand status
```

State lives in `<root>/.strand/` (excluded from git automatically). Only one
process may mount a directory at a time. While `strand watch` runs, commands
that need the mount (`run`, `revert`) refuse rather than race it; read-only
commands read the store.

## Known limits

* While a turn-level scope is open, a human editing the same files is
  credited to that scope. Tool-call and command scopes narrow this window;
  attribution is exact only for edit-tool writes.
* Relay storage in the CLI is in-memory; implement `RelayStore` for
  durability.
* Text fragments live in a vector: edits cost linear time in the fragment
  count. This is fine for source files; a sum-tree is the next step for
  very large documents.
* Case-insensitive name collisions are not specially handled. The watcher and
  file modes assume a Unix platform.
