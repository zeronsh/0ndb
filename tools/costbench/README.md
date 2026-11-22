# costbench

Measures what long activity costs a real relay with the tiered object store
(`--objects` to a local directory standing in for R2). Each scenario reports
relay pack bytes (on disk and live), object-store PUTs and bytes, uploaded
and downloaded bytes, growth samples at 25/50/75/100% of the activity, and
the information content (zstd of the final state plus the history worth
keeping).

| scenario | activity |
|---|---|
| `s1` | a Claude Code transcript through `0ndb record` |
| `s2a` | an agent rewriting 5 files 300 times in a mount, uncommitted |
| `s2b` | the same, committed and pushed to a local bare remote every 10 rewrites |
| `s3` | live-draft streaming of 30 KB replies from a fake Anthropic endpoint |
| `s4` | catalog churn: titles, pins, archives and records on 20 conversations |
| `s5` | a pool runner that sleeps past its lease and wakes 100 times |

Build, then run (each process runs under `ulimit -v 4000000`):

```
odin build src/cli -out:bin/0ndb -o:speed
odin build src/cli -out:bin/0ndb-lease10 -o:speed -define:ONDB_POOL_LEASE_MS=10000
odin build tools/costbench/packlive -out:bin/packlive -o:speed
COST_TRANSCRIPT=~/.claude/projects/<project>/<session>.jsonl timeout 7200 python3 tools/costbench/harness.py [s1 s2a s2b s3 s4 s5]
```

Results print one JSON line per scenario and land in
`$COST_OUT/results-<time>.json` (default `$TMPDIR/costbench`). Knobs:
`COST_MSGS` (2769), `COST_REWRITES` (300), `COST_REPLIES` (20),
`COST_CATALOG_STEPS` (1000), `COST_WAKES` (100), `COST_LEASE_S` (10, must
match the lease build), `COST_SLEEP` (`restart` or `freeze`), `ONDB_BIN`,
`ONDB_BIN_LEASE`, `COST_PACKLIVE`.

`packlive PACK_DIR [ROOT]` opens a copy of a relay pack and prints each
container's size and live bytes, and with `ROOT` every file in it.
`packlive PACK_DIR OUT PATH` copies one file out of the pack.
