# AGENTS.md

## Commands

- Build: `cargo build --workspace`
- Test (use release; the convergence fuzz is slow in debug): `cargo test --workspace --release`
- Lint: `cargo clippy --workspace --all-targets` (keep it warning-free)
- Format: `cargo fmt --all` (`rustfmt.toml`: width 130)
- CLI: `cargo run -p ondb-cli -- <command>` (binary `0ndb`)
- Benchmarks: `cargo run --release -p ondb-core --example bigfile`, `cargo run --release -p ondb --example durable`

## Layout

- `crates/ondb-core`: pure CRDT/DAG model. No I/O. Any change here must keep
  `tests/convergence.rs` passing.
- `crates/ondb-store`: SQLite schema and persistence.
- `crates/ondb`: workspace, mount (`src/mount/`), attribution, reports,
  blame, revert. Mount tests in `tests/mount.rs` use real directories and
  processes.
- `crates/ondb-sync`: sans-IO client/relay plus transports; local state is
  accessed only through the `Replica` trait.
- `crates/ondb-git`: git via subprocess (`cmd.rs`: timeouts, caps, no
  prompts, `GIT_OPTIONAL_LOCKS=0`), remotes, repos/worktrees, and `forge/`
  (provider-agnostic hosting; GitHub via `gh`). No 0ndb dependencies.
- `crates/ondb-agents`: provider sessions. `provider.rs` (trait + normalized
  events), `claude.rs` (stream-json driver), `codex.rs` (`codex exec --json` driver), `mock.rs` (scripted provider
  for tests), `store.rs` (SQLite: threads, messages, sessions, raw events,
  tool calls, outputs), `sessions.rs` (turns, switching, edit/branch, warm
  process pool).
- `crates/ondb-cli`: the `0ndb` binary (`src/agents.rs`: `worktree`/`thread`).

## Invariants

- Ops address inodes, not paths. They may only reference entries inside their
  own parent version (`require_known`).
- Ingested batches are parented on the mount's synced version, never blindly
  on heads.
- Materialization never writes over disk content that differs from the
  shadow; it ingests first.
- Batches are immutable; integration must stay idempotent and independent of
  delivery order.
- `Store::append` writes the batch and all dirty state (inode rows, tree
  nodes, insertions, meta) in one transaction; never persist state outside it.
- Sum-tree nodes are immutable once shared: mutate only via `Arc::make_mut`,
  which resets the node's persisted id. Tree node refcounts count parent
  nodes plus inode rows.
- `View::min_unobserved` must be a true lower bound on unobserved op
  timestamps (subtrees newer than it are pruned from view-relative seeks).
- One live mount per (history, directory), enforced by
  `.0ndb/mount-<history>.lock`. Different histories may share a directory;
  anything a mount writes into the watched tree (fence markers, temp files)
  must be unique per mount and internal to every mount.
- Memory must scale with active worktrees: anything a mount or workspace
  keeps per file must be dropped by hibernation (`MountState::hibernate`,
  `Workspace::hibernate`) and reloadable on demand. Content bytes live in the
  shared, budgeted cache (`ondb_core::contents`); only unpersisted content is
  pinned.
- Every mount entry point that touches the shadow calls `wake()` first.
- Linux watching (`mount/watch.rs`, Dirs mode) shares one inotify instance;
  never create a watcher per mount there.
- Background mount passes defer files younger than `settle`; fences, tool
  writes and shutdown must ingest everything.
- Files git wrote (decided from HEAD's reflog and the index, see
  `mount/git.rs`) go in one batch carrying `Op::GitCheckout` or
  `Op::GitWrite`; never split them across batches, never credit them to
  scopes. Commits move HEAD but write nothing.
- Real-repo check: `0ndb verify -C <dir>` must report no mismatches after any
  git operation.
- Resource checks: `cargo run --release -p ondb --example many -- <repo> <n>`
  (memory, threads, files, idle CPU across many worktrees) and
  `cargo run --release -p ondb --example soak` (must print `ok: flat`).
- Live checks (opt-in): `ONDB_LIVE_GITHUB=owner/repo cargo test -p ondb-git`
  and `ONDB_LIVE_CLAUDE=1 cargo test -p ondb-agents --test sessions live`,
  `ONDB_LIVE_SWITCH=1 cargo test -p ondb-agents --test sessions live_provider_switch`
  (Claude Code -> Codex -> Claude Code).
- Real git end-to-end (clone + linked worktrees, pushes to a scratch repo): `scripts/git-e2e.sh`
- Provider wiring stays behind `Provider`/`Forge`: nothing outside the
  driver files (`claude.rs`, `codex.rs`) or `forge/github.rs` may know a
  provider's wire format or CLI.
- Every provider event is recorded raw before it is interpreted; a turn's
  tool calls are attribution scopes nested in the turn's scope.
- Sessions keep nothing per thread in memory between turns; warm provider
  processes are bounded by `SessionOptions`.
- Branch navigation has one fixed file rule (exact restore to the message's
  version, git checkouts excepted). Don't add user-selectable branching
  behaviour; partial undo belongs to explicit scope reverts.
