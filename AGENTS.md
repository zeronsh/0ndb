# AGENTS.md

## Commands

- Build: `cargo build --workspace`
- Test (use release; the convergence fuzz is slow in debug): `cargo test --workspace --release`
- Lint: `cargo clippy --workspace --all-targets` (keep it warning-free)
- Format: `cargo fmt --all` (`rustfmt.toml`: width 130)
- CLI: `cargo run -p strand-cli -- <command>`

## Layout

- `crates/strand-core`: pure CRDT/DAG model. No I/O. Any change here must keep
  `tests/convergence.rs` passing.
- `crates/strand-store`: SQLite schema and persistence.
- `crates/strand`: workspace, mount (`src/mount/`), attribution, reports,
  blame, revert. Mount tests in `tests/mount.rs` use real directories and
  processes.
- `crates/strand-sync`: sans-IO client/relay plus transports; local state is
  accessed only through the `Replica` trait.
- `crates/strand-cli`: the `strand` binary.

## Invariants

- Ops address inodes, not paths. They may only reference entries inside their
  own parent version (`require_known`).
- Ingested batches are parented on the mount's synced version, never blindly
  on heads.
- Materialization never writes over disk content that differs from the
  shadow; it ingests first.
- Batches are immutable; integration must stay idempotent and independent of
  delivery order.
