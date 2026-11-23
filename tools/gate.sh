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
if [ -n "$VET" ] || [ -n "$VET_WEB" ]; then FAIL=1; note "vet: FAIL $VET $VET_WEB"; else note "vet: ok"; fi

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

lane() {
	local name=$1 env=$2 from=$3 to=$4 f=0 msg=""
	for s in $(seq "$from" "$to"); do
		local o
		o=$(env $env SIM_SEED=$s timeout 900 "$OUT/sim.bin" 2>&1)
		if ! echo "$o" | grep -qE "All tests were successful|The test was successful"; then
			f=$((f+1)); msg="$msg [$s: $(echo "$o" | grep -E 'trace: FAIL|panic|FATAL|Killed' | head -1 | sed 's/^ *//' | cut -c1-160)]"
		fi
	done
	echo "$name $from-$to: $f failed$msg"
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
	( r=$(SIM_MEMBER_SEED=1 SIM_MEMBER_SEEDS=6 timeout 2400 "$OUT/mem.bin" 2>&1); n=$(echo "$r" | grep -c 'membership seed [0-9]*: '); echo "$r" | grep -qE "All tests were successful|The test was successful" || n=$((n+1)); echo "membership 1-6 isolated: $n failure lines $(echo "$r" | grep -E 'membership seed [0-9]+: ' | sort -u | head -2 | tr '\n' ' ')" ) > "$OUT/l7" &
	( r=$(timeout 2400 "$OUT/sim.bin" 2>&1); echo "scenarios: $(echo "$r" | grep -E 'Finished [0-9]+ tests' | tail -1 | grep -q 'All tests were successful' && echo 0 || echo 1) failed $(echo "$r" | grep -E 'seed [0-9]+ FAILED|membership seed [0-9]+: |local_first.*FAIL|staged.*FAIL' | head -3 | tr '\n' ' ')" ) > "$OUT/l8" &
	( r=$(timeout 900 "$OUT/cvg.bin" 2>&1 | grep -E "Finished|FAILED|panic|FATAL" | tail -1); echo "convergence: $r" ) > "$OUT/l9" &
	( r=$(timeout 900 "$OUT/fst.bin" 2>&1 | grep -E "Finished|FAILED|panic|FATAL" | tail -1); echo "fstree: $r" ) > "$OUT/l10" &
	( r=$(cd docs/relay-vectors && timeout 300 "$OUT/relayvec" check . 2>&1 | tail -1); echo "relay vectors: $r" ) > "$OUT/l11" &
	wait
}
if command -v cargo > /dev/null; then
	( cd bindings/rust/ondb && timeout 900 cargo check -q --examples > "$OUT/cargo.log" 2>&1 ) && note "cargo: ok" || { FAIL=1; note "cargo: FAIL $(tail -3 "$OUT/cargo.log" | tr '\n' ' ')"; }
fi
for i in 1 2 3 4 5 13 6 12 7 8 9 10 11; do
	l=$(cat "$OUT/l$i")
	note "$l"
	case "$l" in
	*": 0 failed"*|*": 0 failure lines"*|"scenarios: 0 failed"*|*"All tests were successful"*|*" 0 failed") ;;
	*) FAIL=1 ;;
	esac
done
[ "$DIRTY" -ne 0 ] && note "warning: uncommitted changes in tracked files"
[ $FAIL -eq 0 ] && note "result: PASS" || note "result: FAIL"
cat "$OUT/summary"
exit $FAIL
