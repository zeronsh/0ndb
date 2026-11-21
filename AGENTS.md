# AGENTS.md

## Commands

- Toolchain: Odin `dev-2026-11` (`odin version`).
- Build: `odin build src/cli -out:bin/0ndb -o:speed`
- Check a package: `odin check src/<pkg> -vet -strict-style -no-entry-point` and
  the same with `-target:darwin_arm64` and `-target:windows_amd64`
- Platform testing happens on real machines through Zeron `run_command`:
  macOS on `home-laptop`, Windows on `WING-PC`. No CI.
- Tests: `odin test tests -o:speed`
- Design: `DESIGN.md` is the source of truth for formats and invariants.

## Rules

- No code comments.
- Run every scratch program, benchmark and test under a memory cap in the
  same shell (`ulimit -v 4000000; <cmd>`, raise only with a reason) and a
  `timeout`. The machine has 16 GB shared with the agent host; an uncapped
  runaway gets the whole session killed.
- Minimal tests: `tests/convergence`, `tests/fstree` and `tests/sim` (the
  deterministic whole-system simulator). Everything else is verified with throwaway programs, real git and
  real provider CLIs, not committed tests.
- Nothing per thread or per file stays in memory between events. Idle means
  no wakeups and no armed timers.
- Streams are single-writer and append-only. A durable record is never
  rewritten or truncated, except that redaction zero-fills it in place. Offsets are identical locally, on the relay and on
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
