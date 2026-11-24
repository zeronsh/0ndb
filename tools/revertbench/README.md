# revertbench

Runs the revert-shapes case list (`tests/sim/revert_shapes.cases`, one case
per line) against real daemons: a local relay, one device, a mounted
directory and a fake Anthropic endpoint whose turns do each case's file ops
through the native `shell` tool (`rbop.py`). Person ops go through the API
(`tree.find`, `tree.list`, `tree.write` with the base it read), or with
`RB_PERSON=disk` straight to the file, settled `RB_PERSON_SETTLE` (1.5) s
before and after. Every operation must exit 0, answer with an undo id (undo,
redo, regenerate), move `convo.status` position, and a regenerated turn must
reach the provider. Then the tree must match and stay matched for `RB_HOLD`
(4) s. After every step it compares the exact tree: every path including empty directories,
its type, a file's bytes and exec bit, a symlink's target; mtimes are not
compared and nothing under the root is excluded, so `.0ndb-*` names and
collision copies show as extra paths. Expected trees come from a model of
the ops; a fifth column in a case overrides the tree after undo, regenerate
and switch forward (`!path` means absent). The person cases follow the rule: a line
the turn changed and the person edited since stays as it is now (also
deleted), every other line goes back to base, and a created file keeps only
the lines the person touched.

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

Negative controls: `RB_NOOP=1` answers every operation with success and does
nothing, `RB_BROKEN=add|missing|bytes|exec` perturbs the expected tree. Every
applicable step must fail; the last line counts the ones that did not.

Knobs: `RB_CRASH=0` skips the crash runs, `RB_CRASH_DELAYS` (`0.05,0.2,0.6`),
`RB_PYTHON` (the interpreter the turns run `rbop.py` with). Each failing run
leaves `repro.json` and the daemon, host and relay logs in its directory;
`results.json` holds every step.
