# AGENTS.md

## Commands

- Toolchain: Odin `dev-2026-11` (`odin version`).
- Build: `odin build src/cli -out:bin/0ndb -o:speed`
- Check a package: `odin check src/<pkg> -vet -strict-style -no-entry-point` and
  the same with `-target:darwin_arm64` and `-target:windows_amd64`
- Platform testing happens on real machines through Zeron `run_command`:
  macOS on `home-laptop`, Windows on `WING-PC`. No CI.
- Tests: `odin test tests/convergence -o:speed`, `odin test tests/fstree -o:speed`,
  `odin test tests/sim -o:speed`. When several agents share the checkout,
  always pass `-out:<your scratch dir>/<name>` to `odin test` and
  `odin build`; the default output lands in the repo root and concurrent
  builds overwrite each other's binaries.
- Design: `DESIGN.md` is the source of truth for formats and invariants.
- zstd is vendored as the 1.5.7 amalgamation (`src/zstd/src/zstd.c`) with a
  prebuilt static library per target in `src/zstd/lib`, so the build stays
  one command. Rebuild a library only when `zstd.c` or the flags change, on
  its own host: `src/zstd/build.sh` (linux_amd64, darwin_arm64) and
  `src/zstd/build.bat` from a VS x64 prompt (windows_amd64).

## Cloud machines

- Fresh cloud machines need Odin `dev-2026-11`:
  `gh release download dev-2026-11 -R odin-lang/Odin -p odin-linux-amd64-dev-2026-11.tar.gz`,
  verify its sha256, extract to `~/.local/odin` with `--strip-components=1`,
  and put it on `PATH`.
- Set `git config user.name wingleeio` and
  `git config user.email 44917547+wingleeio@users.noreply.github.com` before
  the first commit, and export `GIT_AUTHOR_NAME=wingleeio` and
  `GIT_COMMITTER_NAME=wingleeio`: the environment sets both to another name,
  which overrides git config.
- The image has no `wasm-ld`, which the relay vectors' wasm run needs. Take
  it from zig in a scratch dir: `pip install -q --target $S/zigpkg ziglang`,
  `printf '#!/bin/sh\nexec %s/zigpkg/ziglang/zig wasm-ld "$@"\n' $S > $S/wbin/wasm-ld`
  (after `mkdir -p $S/wbin`, then `chmod +x`), put `$S/wbin` on `PATH`, then
  `odin build tools/relayvec -target:js_wasm32 -out:$S/relayvec.wasm` and,
  from `docs/relay-vectors`, `node ../../tools/relayvec/run_wasm.mjs $S/relayvec.wasm`.
- Odin on the test machines is not on the Zeron shell's `PATH`: on `WING-PC`
  use `C:\Users\wing_\dev-tools\odin\dist\odin.exe`, on `home-laptop`
  `~/.local/bin/odin`. Work only in `~/dev/0ndb-odin` and `~/dev/0ndb-scratch`
  (`C:\Users\wing_\dev\...` on Windows); `home-laptop` has little free disk.
- Work lands as small PRs into `odin-rewrite`; the coordinator verifies and
  merges them.
- Before opening or updating a PR, rebase it onto the current
  `origin/odin-rewrite` (a new branch name, never a force-push), run
  `tools/gate.sh <scratch dir>` in that checkout and paste its summary block,
  unedited, into the PR body. A PR whose summary is not `result: PASS` on a
  base at most a few commits old is not ready. The gate builds with private
  `-out` paths and takes about 15 minutes on 8 cores. A PR gated on the
  current `origin/odin-rewrite` head lands on its own gate when the
  coordinator's cherry-pick reproduces the summary's `tree=` hash, so gate
  on the newest head you can.
- `tools/gate-bisect.sh '<env>' <base> <commit>...` builds every point in
  parallel and runs one failing seed on each, for finding which commit
  breaks a seed.

## Rules

- No code comments.
- Run every scratch program, benchmark and test under a memory cap in the
  same shell (`ulimit -v 4000000; <cmd>`, raise only with a reason) and a
  `timeout`. The machine has 16 GB shared with the agent host; an uncapped
  runaway gets the whole session killed.
- A sim feature lives in its own file under `tests/sim` and plugs in
  through `hooks.odin` from an `@(init) proc "contextless"` there:
  `register_final_check`, `register_restarted`, `register_stat_line` and
  `register_stat` (bump with `stat_add`/`stat_max`), `register_event` for a
  new event kind, `register_op` for a workload op, `register_world` and
  `register_collect`. Orders are explicit, so traces do not depend on file
  order. Adding a feature does not edit `sim.odin`, `world.odin`,
  `check.odin` or `workload.odin`.
- Minimal tests: `tests/convergence`, `tests/fstree` and `tests/sim` (the
  deterministic whole-system simulator). Everything else is verified with throwaway programs, real git and
  real provider CLIs, not committed tests.
- Nothing per thread or per file stays in memory between events. Idle means
  no wakeups and no armed timers.
- Every file truncated or replaced in place binds its records to a
  generation the authoritative state makes durable first, or is rewritten
  whole, renamed into place and published with a directory fsync. Never
  trust a truncate's new size or a rename to survive a crash.
- Streams are single-writer and append-only. A durable record is never
  rewritten or truncated, except that redaction zero-fills it in place and
  a record that fails its own check is restored to the exact bytes its
  writer appended, from the relay copy verified as this device's own sealed
  write, and synced (`journal_restore`, DESIGN "journal"). Offsets are
  identical locally, on the relay and on replicas.
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
