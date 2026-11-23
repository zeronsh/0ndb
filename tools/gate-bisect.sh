#!/usr/bin/env bash
set -u
if [ $# -lt 3 ]; then
	echo "usage: tools/gate-bisect.sh '<env>' <base> <commit>... (env like 'SIM_DURABILITY=async SIM_SEED=14', or 'SIM_MEMBER_SEED=5 MEMBERSHIP=1')"
	exit 2
fi
ENVS=$1; BASE=$2; shift 2
ROOT=$(git rev-parse --show-toplevel)
OUT=${GATE_BISECT_OUT:-${TMPDIR:-/tmp}/0ndb-bisect-$$}
JOBS=${GATE_BISECT_JOBS:-4}
mkdir -p "$OUT"
cd "$ROOT"
ulimit -v "${GATE_VMEM:-4000000}"
DEFINE=""
case " $ENVS " in *" MEMBERSHIP=1 "*) DEFINE="-define:ODIN_TEST_NAMES=sim.membership" ;; esac
POINTS=("$BASE" "$@")
i=0
for c in "${POINTS[@]}"; do
	(
		W="$OUT/wt$i"
		git worktree add -q --detach "$W" "$c" 2>/dev/null || exit 0
		cd "$W" && timeout 1200 odin build tests/sim -build-mode:test $DEFINE -out:"$OUT/sim$i.bin" -o:speed > "$OUT/build$i.log" 2>&1
		cd "$ROOT" && git worktree remove --force "$W" 2>/dev/null
	) &
	i=$((i+1))
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
done
wait
i=0
for c in "${POINTS[@]}"; do
	if [ ! -x "$OUT/sim$i.bin" ]; then
		echo "$(git log --format='%h %s' -1 "$c" | cut -c1-70): build failed"
	else
		o=$(env $ENVS timeout 900 "$OUT/sim$i.bin" 2>&1)
		if echo "$o" | grep -qE "membership seed [0-9]+: |FATAL" || ! echo "$o" | grep -E "Finished [0-9]+ tests?" | tail -1 | grep -qE "All tests were successful|The test was successful"; then
			r="FAIL $(echo "$o" | grep -E 'trace: FAIL|membership seed [0-9]+: |panic|FATAL' | head -1 | sed 's/^ *//' | cut -c1-120)"
		else
			r="pass"
		fi
		echo "$(git log --format='%h %s' -1 "$c" | cut -c1-70): $r"
	fi
	i=$((i+1))
done
git worktree prune
