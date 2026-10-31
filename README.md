# 0ndb

Tracked, attributed, syncable worktrees. 0ndb records every change to a
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
| `ondb-core` | Pure data model: Lamport-stamped batches in a causal DAG, a persistent summarized B-tree, a sequence CRDT for text built on it, an inode-based file-tree CRDT, line diffing, codecs. No I/O. |
| `ondb-store` | SQLite persistence: append-only batches, refcounted copy-on-write tree nodes, per-inode state rows, lazily read blobs, outbox, mount state. |
| `ondb` | `Workspace` (history + store + events), `Mount` (filesystem watcher, ingestion, materialization, fences), attribution `Recorder`, change reports, blame, selective revert, managed `Worktrees`. |
| `ondb-git` | Git through `git` itself (repositories, branches, worktrees, status) and git hosting providers behind one `Forge` interface (GitHub today), chosen per remote host. |
| `ondb-agents` | Provider sessions: agent providers behind one `Provider` interface (Claude Code, Codex, scripted mock), threads as message trees with editing and branch switching, recorded provider events, tool calls and CLI output. |
| `ondb-sync` | Sans-IO replication: `Replica` trait, `Client` and `Relay` state machines, memory and TCP transports. |
| `ondb-cli` | The `0ndb` binary. |

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

**Storage engine.** Text and durable state are built for large files and
large histories:

* *Summarized B-tree.* Each file's fragments live in a copy-on-write
  B-tree (leaves of 48 fragments, branches of 32 children). Branches keep
  child summaries and item counts in arrays separate from the child
  pointers, so a seek scans dense arrays. A summary holds visible bytes,
  total bytes and the newest timestamp of any insertion or deletion below
  it. Seeking by visible offset costs O(log n).
* *Seeks in past versions.* Each view reports the oldest timestamp it does
  not observe. A subtree whose newest op is older than that looks the same in
  the view as it does now, so its summary is used as is. Edits against a
  stale parent only descend where concurrent work actually happened.
  Splices of one op are applied independently, each with its own seek.
* *Copy-on-write snapshots.* Mutating a tree copies only the root-to-leaf
  path when the tree is shared; cloning is O(1). Readers of a snapshot need
  no latches.
* *Incremental, refcounted persistence.* Tree nodes are LZ4-compressed rows
  with refcounts and packed child ids. A commit writes only nodes created
  since the last commit. When an inode's root changes, the old root is
  released and nodes reaching zero are deleted along with what they
  reference. Batch, blobs, inode rows, insertions, meta and tree nodes are
  written in **one SQLite transaction**, so stored state always equals
  replaying stored batches. There are no snapshots, no replay on open and
  nothing to recover after a crash.
* *Lazy content.* Text larger than 4 KiB is a content-addressed blob. Ops
  reference it, batches carry it as an attachment, and readers load it
  through a separate read connection and a bounded LRU cache (32 MiB). A
  large file that is never read costs its fragment tree, not its bytes.
* *Content git already has is not copied.* Blob ids are git's blob ids, so
  in a git checkout any file content the repository's object database holds
  (every clean tracked file, and anything git checks out later) is
  referenced there instead of stored, small files included. Referenced blobs
  are pinned by a chain of commits under `refs/0ndb/<history>` (never pushed
  by default), so `git gc` can't collect content history still relies on,
  even after its branch is deleted. Pins are queued in the same transaction
  as the batch and flushed in bulk; if pinning fails the bytes are copied
  into the store instead. Content is read through one long-lived
  `git cat-file --batch-command` per active worktree, stopped while it
  hibernates.

Measured on an 8 MiB, 200k-line file (`cargo run --release -p ondb-core
--example bigfile`, `-p ondb --example durable`):

| | flat fragment list | 0ndb |
|---|---:|---:|
| local edit | 231 µs | 1.4 µs |
| edit against a stale parent (200 scattered concurrent edits) | 6.4 ms | 0.25 ms |
| durable commit (SQLite transaction incl. tree nodes) | — | 190 µs |
| store size after 2000 edits | — | 1 MiB |
| reopen | — | 2.4 ms |

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
6. **Git's writes are not edits.** Mounts work in plain clones and linked
   worktrees (whose `HEAD` lives outside the folder). When git writes files
   (branch switch, pull, rebase, reset, or a merge/cherry-pick/revert paused
   on conflicts), the mount waits for git's locks to clear, rescans in one
   pass, and uses git's own records to decide what git wrote. HEAD's reflog
   tells checkouts from commits, which write nothing. The index tells which
   files git wrote: their entry changed and the file matches it. Those go in
   one batch marked `GitCheckout` (or `GitWrite` for a paused operation). A
   file edited right after git wrote it is split into git's version plus the
   edit. Everything else stays an ordinary edit. Git batches are never
   credited to a scope, are summarized in change reports, and are left alone
   by revert. The last `HEAD` is persisted, so switches made while unmounted
   are recognized too. `0ndb verify` checks the history against the disk.
7. **Offline changes.** On restart, edits made while nothing was watching are
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

`ondb-sync` depends on local state only through the `Replica` trait
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

## Worktrees and git

`Worktrees` creates git worktrees on fresh `ondb/<title>` branches (or adopts
existing folders), mounts them with their histories kept in a state directory,
remounts them on start, and removes them (refusing uncommitted work unless
forced). Everything git goes through `ondb_git::Repo`, which runs `git` with
timeouts, output caps, no prompts and no optional locks, so it never contends
with a user's own git or a mount.

Hosting is provider-agnostic. A remote URL in any spelling (https, ssh,
scp-like, nested namespaces) parses to one `RemoteUrl`; `Forges` maps its host
to a `Forge` implementation (`github.com` to GitHub by default; self-hosted
hosts via `map_host`). A `Forge` reads repositories and change requests (state,
draft, checks, review, mergeability) and opens new ones. The GitHub provider
uses the `gh` CLI, so the user's own sign-in applies and no token passes
through 0ndb. Adding GitLab or another host means implementing `Forge` and
registering it. Nothing polls: provider calls happen on request.

## Provider sessions

`ondb_agents::Sessions` runs agent turns in managed worktrees.

* **Threads are message trees.** Editing a user message adds a sibling
  (`siblings()` gives the `<i/n>` switcher); `switch_branch` selects another.
* **Every message is pinned to a worktree version**, and every turn and every
  tool call is an attribution scope. Branching follows one fixed rule, not
  an option: editing a message or switching branches makes the files exactly
  what they were at that point (everything since is undone, people's edits
  included), except git checkouts, which are never undone. Undoing only an
  agent's work is a separate, explicit action (reverting its scope).
* **Provider sessions are chosen per turn.** Continue the native session that
  last saw this branch; else fork a native session at the branch point if the
  provider can (Claude Code: `--resume-session-at` + `--fork-session`); else
  start fresh. Whatever the chosen session hasn't seen (another provider's
  turns, another branch) is replayed in front of the prompt, so switching
  providers mid-thread and back keeps each provider's own native history.
* **Switching follows zeron's rules.** The reply that takes over records the
  seam (`switched_from`). A provider's earlier session is resumed only if it
  is that provider's own (owner gate) and was made in the same directory (cwd
  gate). Replayed history gets zeron's intros ("taking over" for a fresh
  session, "while you were away" for a resumed one, a branch note
  otherwise), includes tool calls with clipped output (600 characters, 8,000
  per message), keeps the newest messages within the budget, and is never
  put in front of native commands (`/name`).
* **Providers.** Claude Code (stream-json, persistent, native fork at a
  message) and Codex (`codex exec --json`, one process per turn, resume by
  thread id; forks at a message are replayed).
* **Everything is recorded.** Each provider event is stored verbatim
  (compressed), tool calls with inputs, outputs, stdout/stderr and their
  attribution scope, the provider's stderr, and any CLI output attached with
  `record_output`.
* **Bounded processes.** At most `warm_limit` provider processes (2) stay alive
  between turns, each for `warm_idle` (90 s); a parked session resumes
  natively. The reaper sleeps without wakeups while nothing is warm. Nothing
  about a thread is held in memory between turns.

## Resource use

0ndb is meant to watch many worktrees from one long-running process.

* **Memory scales with active worktrees.** A mount with no activity for
  `MountOptions::idle_unload` (30 s) hibernates: its shadow, the history's
  in-memory state and its SQLite connections are released, and reloaded on
  the next relevant event (about 20 ms for a 2.7k-file worktree).
* **One bounded content cache per process.** File text is read from the store
  on demand into a shared LRU (`ondb_core::set_cache_budget`, 32 MiB by
  default). Blobs are content-addressed, so worktrees of one repository share
  cached bytes. Only not-yet-persisted content is pinned in memory.
* **Bounded adoption.** A first mount commits in 32 MiB chunks, so adopting a
  large repository never holds it in memory at once. Files are read and
  hashed in parallel (hardware SHA-1), each once.
* **No idle CPU.** Mount threads sleep until an event, command or timer.
  Events under ignored paths (build output, `node_modules`) are dropped before
  they can schedule a pass or wake a hibernating mount.
* **Watching.** macOS and Windows use one recursive OS watch per mount. On
  Linux every mount in the process shares one inotify instance and watches
  only tracked directories, so the default limit of 128 instances per user and
  ignored trees don't constrain how many worktrees can be mounted.

Measured with `cargo run --release -p ondb --example bigrepo -- <repo>` on a
shallow Linux kernel checkout (97,372 files, 1.6 GB, Apple M-series):

| | before | now |
|---|---|---|
| first mount | 49.3 s, 1.76 GB heap peak | 7.8 s, 281 MiB heap peak |
| store on disk | 741 MiB | 53 MiB |

Measured with `cargo run --release -p ondb --example many -- <repo> <n>` on 60
worktrees of a 2.7k-file, 74 MB repository in one process (Apple M-series):

| | per worktree |
|---|---|
| hibernated | 0.12 MiB heap, 1 open file, 2 threads |
| awake | about 3.5 MiB heap (about 1.3 KB per tracked file), 6 open files |
| shared content cache | 32 MiB total |
| idle CPU | none |
| 30,000 writes into ignored `target/` dirs | 1.8 s CPU total, no mount woken |

`examples/soak.rs` runs edit, scope, branch switch, hibernate and wake cycles
and fails if heap, open files or threads grow.

## CLI

```sh
0ndb init                                   # adopt the current directory
0ndb watch [--sync host:port]               # ingest live, optionally replicate
0ndb run --agent codex -- python fix.py     # run and attribute a command
0ndb log                                    # batches with authors and scopes
0ndb blame src/main.rs                      # per-line provenance
0ndb changes --agent codex                  # what codex hasn't seen
0ndb scopes                                 # attribution scopes
0ndb revert <scope-prefix> --agent codex    # selective undo
0ndb relay --listen 0.0.0.0:7420 --validate # relay server
0ndb status
0ndb verify                                 # history matches disk exactly?
0ndb worktree new <repo> "title"            # git worktree on ondb/<title>, mounted
0ndb worktree list | rm <id> | pr <id> | pr-open <id> "title"
0ndb thread new <worktree-id> "title"
0ndb thread send <thread> "prompt" [--model haiku] [--access plan|edits|full]
0ndb thread edit <message> "new prompt"
0ndb thread show <thread> | switch <message> | events <message>
```

State lives in `<root>/.0ndb/` (excluded from git automatically). The
database defaults to `<root>/.0ndb/0ndb.db`; `--db <path>` or `ONDB_DB` picks
another, so separate databases can track the same directory side by side (a
test build next to production, say). Each records the other's writes once, as
an ordinary external change. A history may be mounted on a directory by only
one live process at a time: two mounts of the same history would ingest every
change twice. While `0ndb watch` runs, commands that need the mount (`run`,
`revert`) refuse rather than race it; read-only commands read the store.

```sh
ONDB_DB=~/.0ndb-test/0ndb.db 0ndb watch    # alongside a production `0ndb watch`
```

## Known limits

* While a turn-level scope is open, a human editing the same files is
  credited to that scope. Tool-call and command scopes narrow this window;
  attribution is exact only for edit-tool writes.
* Relay storage in the CLI is in-memory; implement `RelayStore` for
  durability.
* Resolving an anchor scans the file's fragments (creating one is
  O(log n)). With copy-on-write nodes there are no parent pointers. An
  O(log n) resolve needs a secondary index from insertion id to position
  (ordered locators), which is not built yet.
* Stale-parent seeks degrade toward linear when concurrent edits are
  scattered across a whole file, because pruning is by timestamp.
* Text trees load eagerly on open (they hold no bytes, only fragments).
  Loading per file on first access would make opening huge repositories
  O(1).
* Case-insensitive name collisions are not specially handled. The watcher and
  file modes assume a Unix platform.

## Naming

The project, repository, binary (`0ndb`) and state directory (`.0ndb/`)
are called `0ndb`. Cargo package names cannot start with a digit, so the
crates are `ondb-*`.
