# flows

`flows.py` measures the user-facing flows end to end. It drives a real daemon over its socket with the same op sequences the playground uses, and reports p50 and p95 per flow. A flow that should feel instant is flagged `SLOW` when its p95 is over 50 ms.

| flow | what is timed |
|---|---|
| `send` | `send` to the first streamed token on the conversation subscription. It runs the native provider against an instant local SSE endpoint, so the time is 0ndb's own cost. |
| `cli` | The same through each signed-in provider CLI in `FLOWS_CLI_PROVIDERS` (claude,codex). This includes model latency, and `run_started` is 0ndb's spawn cost. It runs only with `FLOWS_CLI=1` or when named. |
| `window` | Opening a 10k-message conversation (`subscribe`, `convo.settings`, `convo.status`, `convo.window` tail). Also a `convo.page` of older messages and a ±30 `convo.window` jump. |
| `tree` | An agent's `tree.write`, and a person's disk edit in the mount, each until the tree subscription event (and until the follow-up `tree.list`). |
| `buffer` | A `buffer.edit` keystroke on one connection until a second `buffer.open` subscriber sees it. |
| `mount` | `tree.create` plus `mount.add` of a 3000-file git repo, until the first `tree.list`. Also later directory lists. |
| `switch` | A branch switch until its files are materialized. This is a stub for now. |

Build, then run (each daemon runs under `ulimit -v 4000000`):

```
odin build src/cli -out:bin/0ndb -o:speed
timeout 3600 python3 tools/flows/flows.py [send cli window tree buffer mount switch]
```

Each flow prints one JSON line, followed by a table, and the results land in `$FLOWS_OUT/results-<time>.json` (default `$TMPDIR/flows`). Knobs:

- `FLOWS_RUNS` (30)
- `FLOWS_MESSAGES` (10000)
- `FLOWS_REPO_FILES` (3000)
- `FLOWS_MOUNT_RUNS` (5)
- `FLOWS_CLI_RUNS` (3)
- `ONDB_BIN`
