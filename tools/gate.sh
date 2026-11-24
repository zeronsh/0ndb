#!/usr/bin/env bash
set -u
ROOT=$(git rev-parse --show-toplevel)
OUT=${1:-${TMPDIR:-/tmp}/0ndb-gate-$$}
CAP=${GATE_VMEM:-4000000}
mkdir -p "$OUT"
cd "$ROOT"
ulimit -v "$CAP"
HEAD_SHA=$(git rev-parse --short HEAD)
BASE_SHA=$(git merge-base HEAD origin/odin-rewrite 2>/dev/null | cut -c1-7)
TREE_SHA=$(git rev-parse --short HEAD^{tree})
DIRTY=$(git status --porcelain --untracked-files=no | wc -l)
FAIL=0
note() { echo "$*" >> "$OUT/summary"; }
: > "$OUT/summary"
note "gate head=$HEAD_SHA base=$BASE_SHA tree=$TREE_SHA dirty=$DIRTY"

vet_one() {
	local p=$1 t=$2
	if ! timeout 600 odin check "src/$p" -vet -strict-style -no-entry-point $t > "$OUT/vet-$p${t//[:-]/_}.log" 2>&1; then
		echo "vet $p $t: $(head -2 "$OUT/vet-$p${t//[:-]/_}.log" | tr '\n' ' ')"
	fi
}
VET=$( for p in $(ls src); do
	[ -d "src/$p" ] || continue
	[ "$p" = zstd ] && continue
	for t in "" "-target:darwin_arm64" "-target:windows_amd64"; do vet_one "$p" "$t" & done
	wait
done )
VET_WEB=$(timeout 600 odin check src/web -vet -strict-style -no-entry-point -target:js_wasm32 2>&1 | head -2 | tr '\n' ' ')
VET_TESTS=$( for p in tests/sim tests/convergence tests/fstree tools/relayvec; do
	( o=$(timeout 600 odin check "$p" -vet -strict-style -no-entry-point 2>&1 | head -2 | tr '\n' ' '); [ -n "$o" ] && echo "vet $p: $o" ) &
done; wait )
if [ -n "$VET" ] || [ -n "$VET_WEB" ] || [ -n "$VET_TESTS" ]; then FAIL=1; note "vet: FAIL $VET $VET_WEB $VET_TESTS"; else note "vet: ok"; fi
SOURCES_PAT='prim\.(now_ns|now_ms|mono_ns|mono_ms|id_new)\(\)|time\.(now|tick_now)\(\)|crypto\.rand_bytes|runtime\.rand_bytes|rand\.(uint|int|float)[0-9]*\('
SOURCES=$( for d in engine fs sync odb pack journal map crdt fstree fshist textdiff convo search obj; do
	grep -rnE "$SOURCES_PAT" "src/$d" --include=*.odin
done | grep -v "_windows.odin:\|_darwin.odin:" | while IFS=: read -r f l rest; do
	from=$(( l > 3 ? l - 3 : 1 ))
	sed -n "${from},$(( l - 1 ))p" "$f" | grep -q "prim.unrouted" || printf '%s:%s ' "$f" "$l"
done )
if [ -n "$SOURCES" ]; then FAIL=1; note "sources: FAIL clock or randomness not routed through the engine's Clock and Random: $SOURCES"; else note "sources: ok"; fi
if command -v python3 > /dev/null; then
	MAPORDER=$(python3 tools/maporder.py . src,tests/sim 2> /dev/null)
	if [ -n "$MAPORDER" ]; then FAIL=1; note "map order: FAIL a map loop with effects iterates in hash order (use prim.sorted_keys, or prim.unordered when order cannot matter): $(echo "$MAPORDER" | head -5 | tr '\n' ' ')"; else note "map order: ok"; fi
else
	note "map order: skipped (no python3)"
fi

build() {
	local name=$1; shift
	timeout 1200 odin build "$@" -out:"$OUT/$name" -o:speed > "$OUT/build-$name.log" 2>&1 || echo "build $name failed: $(tail -3 "$OUT/build-$name.log" | tr '\n' ' ')"
}
BUILD=$( { build sim.bin tests/sim -build-mode:test &
	build mem.bin tests/sim -build-mode:test -define:ODIN_TEST_NAMES=sim.membership &
	build cvg.bin tests/convergence -build-mode:test &
	build fst.bin tests/fstree -build-mode:test &
	build relayvec tools/relayvec &
	wait; } )
if [ -n "$BUILD" ]; then note "build: FAIL $BUILD"; cat "$OUT/summary"; exit 1; fi
note "build: ok"

fail_list() {
	printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | awk '
	match($0, /^\[(ERROR|FATAL)\] --- \[[^]]*\] \[[^]]*:[0-9]+:[A-Za-z0-9_]+\(\)\] /) {
		head = substr($0, 1, RLENGTH)
		msg = substr($0, RLENGTH + 1)
		sub(/\(\)\] $/, "", head)
		n = split(head, a, ":")
		if (!(a[n] in first)) first[a[n]] = msg
		next
	}
	/^sim: seed [0-9]+ FAILED/ {
		seeds++
		if (!("simulate" in own)) own["simulate"] = $0
	}
	/^membership seed [0-9]+: / && !("membership" in own) {
		own["membership"] = $0
	}
	/^ - [A-Za-z0-9_]+\.[A-Za-z0-9_]+[ \t]/ {
		line = substr($0, 4)
		name = line
		sub(/[ \t].*$/, "", name)
		msg = line
		sub(/^[^ \t]+[ \t]+/, "", msg)
		if (!(name in seen)) {
			seen[name] = 1
			order[++k] = name
			last[name] = msg
		}
	}
	END {
		out = ""
		for (i = 1; i <= k; i++) {
			name = order[i]
			short = name
			sub(/^.*\./, "", short)
			m = (short in own) ? own[short] : (short in first) ? first[short] : last[name]
			if (length(m) > 160) m = substr(m, 1, 160) "..."
			if (short == "simulate" && seeds > 1) m = m " (+" (seeds - 1) " more seeds)"
			out = out (i > 1 ? " | " : "") name ": " m
		}
		print k + 0
		print out
	}'
}

ok_run() {
	echo "$1" | grep -q "FATAL" && return 1
	echo "$1" | grep -E "Finished [0-9]+ tests?" | tail -1 | grep -qE "All tests were successful|The test was successful"
}

mkdir -p "$OUT/runs"
rec_run() {
	local id=$1 limit=$2; shift 2
	local t0=$SECONDS
	REC_LOG="$OUT/runs/$id.log"
	if [ -x /usr/bin/time ]; then
		/usr/bin/time -q -f "%e %M" -o "$REC_LOG.time" timeout "$limit" env "$@" > "$REC_LOG" 2>&1
		REC_RC=$?
		read -r REC_WALL REC_RSS < <(tail -1 "$REC_LOG.time" 2>/dev/null)
		rm -f "$REC_LOG.time"
	else
		timeout "$limit" env "$@" > "$REC_LOG" 2>&1
		REC_RC=$?
		REC_WALL=$((SECONDS - t0)) REC_RSS=
	fi
	REC_OUT=$(tr -d '\000' < "$REC_LOG")
	REC_SIG=
	[ "$REC_RC" -gt 128 ] && REC_SIG=" SIG$(kill -l $((REC_RC - 128)) 2>/dev/null)"
	[ "$REC_RC" -eq 124 ] && REC_SIG=" timeout"
	REC_WHAT="rc=$REC_RC$REC_SIG wall=${REC_WALL:-?}s rss=${REC_RSS:-?}KB bytes=$(wc -c < "$REC_LOG" | tr -d ' ')"
}

rec_keep() {
	{
		echo "$1 $REC_WHAT load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null) at=$(date -u +%H:%M:%S)"
		echo "cmd: $2"
		echo "last 20 lines:"
		tail -20 "$REC_LOG"
	} > "$OUT/runs/$1.rec"
}

rec_msg() {
	local m
	m=$(echo "$REC_OUT" | grep -aE 'trace: FAIL|panic|FATAL|Killed' | head -1 | sed 's/^ *//' | cut -c1-160)
	if ! echo "$REC_OUT" | grep -qaE "Finished [0-9]+ tests?"; then
		echo "$REC_WHAT no summary; last: $(tail -1 "$REC_LOG" | tr -d '\000' | cut -c1-120)${m:+; $m}"
	elif [ -z "$m" ]; then
		echo "$REC_WHAT; $(fail_list "$REC_OUT" | tail -n +2 | cut -c1-160)"
	else
		echo "$m"
	fi
}

lane() {
	local name=$1 env=$2 from=$3 to=$4 f=0 msg=""
	for s in $(seq "$from" "$to"); do
		rec_run "$name-$s" 900 $env SIM_SEED=$s "$OUT/sim.bin"
		if [ "$REC_RC" -ne 0 ] || ! ok_run "$REC_OUT"; then
			f=$((f+1)); msg="$msg [$s: $(rec_msg)]"
			rec_keep "$name-$s" "$env SIM_SEED=$s sim.bin"
		else
			rm -f "$REC_LOG"
		fi
	done
	echo "$name $from-$to: $f failed$msg"
}

jitter_lane() {
	local f=0 msg="" n=0
	for run in "1" "2" "3" "4" "25 SIM_TREE_MOVE=1 SIM_STORAGE=until-run" "44 SIM_TREE_MOVE=1" "7 SIM_TREE_MOVE=1" "9 SIM_STORAGE=until-run"; do
		local s=${run%% *} env=""
		[ "$run" != "$s" ] && env=${run#* }
		n=$((n+1))
		rec_run "jitter-$n" 1800 $env SIM_ADDR_JITTER=1 SIM_SEED=$s "$OUT/sim.bin"
		if echo "$REC_OUT" | grep -qa "NOT deterministic"; then
			f=$((f+1)); msg="$msg [$s $env]"
			rec_keep "jitter-$n" "$env SIM_ADDR_JITTER=1 SIM_SEED=$s sim.bin"
		elif ! echo "$REC_OUT" | grep -qaE "Finished [0-9]+ tests?"; then
			f=$((f+1)); msg="$msg [$s $env: $(rec_msg)]"
			rec_keep "jitter-$n" "$env SIM_ADDR_JITTER=1 SIM_SEED=$s sim.bin"
		else
			rm -f "$REC_LOG"
		fi
	done
	echo "addr-jitter $n runs: $f failed$msg"
}

member_lane() {
	rec_run membership 2400 SIM_MEMBER_SEED=1 SIM_MEMBER_SEEDS=30 "$OUT/mem.bin"
	local n
	n=$(echo "$REC_OUT" | grep -ac 'membership seed [0-9]*: ')
	if [ "$REC_RC" -ne 0 ] || ! ok_run "$REC_OUT"; then
		n=$((n+1))
		rec_keep membership "SIM_MEMBER_SEED=1 SIM_MEMBER_SEEDS=30 mem.bin"
		echo "membership 1-30 isolated: $n failure lines $(echo "$REC_OUT" | grep -aE 'membership seed [0-9]+: ' | sort -u | head -2 | tr '\n' ' ') [$(rec_msg)]"
	else
		rm -f "$REC_LOG"
		echo "membership 1-30 isolated: $n failure lines "
	fi
}

scenario_lane() {
	rec_run scenarios 4800 SIM_TEST_TIMES=1 "$OUT/sim.bin"
	local f n list times
	echo "$REC_OUT" | grep -a '^test time ' | sort -t' ' -k4 -g -r | sed 's/^test time //' > "$OUT/scenario-times"
	times="wall ${REC_WALL:-?}s; slowest: $(head -3 "$OUT/scenario-times" | sed 's/ (waited.*//' | paste -sd, - | sed 's/,/, /g')"
	f=$(fail_list "$REC_OUT"); n=$(printf '%s\n' "$f" | head -1); list=$(printf '%s\n' "$f" | tail -n +2)
	if [ "$REC_RC" -ne 0 ] || ! ok_run "$REC_OUT"; then
		rec_keep scenarios "sim.bin"
		[ "$n" = 0 ] && { n=1; list=$(rec_msg); }
		echo "scenarios: $n failed [$list] ($times)"
	else
		rm -f "$REC_LOG"
		echo "scenarios: 0 failed ($times)"
	fi
}

suite_lane() {
	rec_run "$1" 900 "$2"
	if [ "$REC_RC" -ne 0 ] || ! ok_run "$REC_OUT"; then
		rec_keep "$1" "$2"
		echo "$1: $(echo "$REC_OUT" | grep -aE "Finished|FAILED|panic|FATAL" | tail -1) [$(rec_msg)]"
	else
		rm -f "$REC_LOG"
		echo "$1: $(echo "$REC_OUT" | grep -aE "Finished" | tail -1)"
	fi
}
{
	lane default "" 1 10 > "$OUT/l1" &
	lane default "" 11 20 > "$OUT/l2" &
	lane async SIM_DURABILITY=async 1 10 > "$OUT/l3" &
	lane async SIM_DURABILITY=async 11 20 > "$OUT/l4" &
	lane until-run SIM_STORAGE=until-run 1 20 > "$OUT/l5" &
	lane wide "" 21 40 > "$OUT/l6" &
	lane byzantine SIM_BYZANTINE=1 1 16 > "$OUT/l12" &
	lane until-run SIM_STORAGE=until-run 21 40 > "$OUT/l13" &
	lane wide "" 41 60 > "$OUT/l14" &
	lane byzantine SIM_BYZANTINE=1 17 32 > "$OUT/l15" &
	lane byzantine SIM_BYZANTINE=1 33 48 > "$OUT/l16" &
	lane until-run SIM_STORAGE=until-run 41 60 > "$OUT/l17" &
	lane until-run SIM_STORAGE=until-run 61 80 > "$OUT/l18" &
	lane until-run SIM_STORAGE=until-run 81 100 > "$OUT/l19" &
	member_lane > "$OUT/l7" &
	scenario_lane > "$OUT/l8" &
	suite_lane convergence "$OUT/cvg.bin" > "$OUT/l9" &
	suite_lane fstree "$OUT/fst.bin" > "$OUT/l10" &
	( r=$(cd docs/relay-vectors && timeout 300 "$OUT/relayvec" check . 2>&1 | tail -1); echo "relay vectors: $r" ) > "$OUT/l11" &
	jitter_lane > "$OUT/l20" &
	wait
}
if command -v cargo > /dev/null; then
	( cd bindings/rust/ondb && timeout 900 cargo check -q --examples > "$OUT/cargo.log" 2>&1 ) && note "cargo: ok" || { FAIL=1; note "cargo: FAIL $(tail -3 "$OUT/cargo.log" | tr '\n' ' ')"; }
fi
for i in 1 2 3 4 5 13 17 18 19 6 14 12 15 16 20 7 8 9 10 11; do
	l=$(cat "$OUT/l$i")
	note "$l"
	case "$l" in
	*" [rc="*) FAIL=1 ;;
	*": 0 failed"*|*": 0 failure lines"*|"scenarios: 0 failed"*|*"All tests were successful"*|*" 0 failed") ;;
	*) FAIL=1 ;;
	esac
done
[ "$DIRTY" -ne 0 ] && note "warning: uncommitted changes in tracked files"
[ $FAIL -eq 0 ] && note "result: PASS" || note "result: FAIL"
cat "$OUT/summary"
exit $FAIL
