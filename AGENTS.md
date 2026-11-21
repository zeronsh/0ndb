# AGENTS.md

## Commands

- Toolchain: Odin `dev-2026-11` (`odin version`).
- Build: `odin build src/cli -out:bin/0ndb -o:speed`
- Check a package: `odin check src/<pkg> -vet -strict-style -no-entry-point` and
  the same with `-target:darwin_arm64`
- Tests: `odin test tests -o:speed`
- Design: `DESIGN.md` is the source of truth for formats and invariants.

## Rules

- No code comments.
- Minimal tests: `tests/convergence`, `tests/fstree` and one end-to-end
  package. Everything else is verified with throwaway programs, real git and
  real provider CLIs, not committed tests.
- Nothing per thread or per file stays in memory between events. Idle means
  no wakeups and no armed timers.
- Streams are single-writer and append-only. A durable record is never
  rewritten or truncated. Offsets are identical locally, on the relay and on
  replicas.
- Provider wire formats live only in their driver file under `src/agent/`.
- Every provider line is recorded raw before it is interpreted.
- Disk content that differs from the last snapshot is snapshotted before any
  materialization touches it.
- Never move, reset or delete an existing git branch. One thread never
  rewinds another thread's files.

## Commits

- Commit only as `wingleeio <44917547+wingleeio@users.noreply.github.com>`,
  author and committer both. Never bypass hooks.
- Push with the `wingleeio` GitHub login
  (`GH_TOKEN=$(gh auth token --user wingleeio)` with
  `credential.helper='!gh auth git-credential'`). Only `wingleeio` may push
  or merge to `main`.
