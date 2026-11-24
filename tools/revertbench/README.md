# revertbench

Runs the revert-shapes case list (`tests/sim/revert_shapes.cases`, one case
per line) against real daemons: a local relay, one device, a mounted
directory and a fake Anthropic endpoint whose turns do each case's file ops
through the native `shell` tool (`rbop.py`). Person ops go through the API
(`tree.find`, `tree.list`, `tree.write` with the base it read). After every
step it compares the exact tree: every path including empty directories,
its type, a file's bytes and exec bit, a symlink's target; mtimes are not
compared and nothing under the root is excluded, so `.0ndb-*` names and
collision copies show as extra paths. Expected trees come from a model of
the ops, so a person's write survives the undo.

Runs per case, each on a fresh daemon:

| run | steps |
|---|---|
| `undo` | turn, undo (pre-turn), redo (post-turn), undo again (pre-turn) |
| `switch` | turn, regenerate (pre-turn), switch prev (post-turn), switch next (pre-turn) |
| `redo-regenerate` | turn, undo, redo, regenerate (pre-turn) |
| `crashN` | turn, undo with the daemon killed (SIGKILL, taskkill /F on Windows) N s in; after restart the tree is pre- or post-turn, never a mix; `continue` and undo reach pre-turn |

Symlink cases are skipped on Windows (creating one needs admin or Developer
Mode). The exec bit is not compared on Windows.

```
odin build src/cli -out:bin/0ndb -o:speed
RB_CASES=tests/sim/revert_shapes.cases ONDB_BIN=bin/0ndb RB_OUT=/tmp/rb \
  python3 tools/revertbench/revertbench.py [CASE...]
```

Knobs: `RB_CRASH=0` skips the crash runs, `RB_CRASH_DELAYS` (`0.05,0.2,0.6`),
`RB_PYTHON` (the interpreter the turns run `rbop.py` with). Each failing run
leaves `repro.json` and the daemon, host and relay logs in its directory;
`results.json` holds every step.
