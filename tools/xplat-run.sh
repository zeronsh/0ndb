#!/bin/sh
set -u
ROOT=${XPLAT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
export XPLAT_ROOT="$ROOT"
BIN="$ROOT/.xplat"
UL=0
if (ulimit -v 4000000) 2>/dev/null; then
	UL=1
fi
capped() {
	n=$1
	shift
	(
		if [ "$UL" = 1 ]; then
			ulimit -v "$n"
		fi
		exec "$@"
	)
}
if [ "${1:-}" = --one ]; then
	lane=$2
	seed=$3
	case $lane in
	default) e="" ;;
	until-run) e="SIM_STORAGE=until-run" ;;
	async) e="SIM_DURABILITY=async" ;;
	byzantine) e="SIM_BYZANTINE=1" ;;
	*) e="" ;;
	esac
	log="$BIN/$lane-$seed.log"
	capped 4000000 env $e SIM_SEED="$seed" perl -e 'alarm shift; exec @ARGV' 1500 "$BIN/sim.bin" > "$log" 2>&1
	rc=$?
	m=$(grep -m1 -E '^sim: events=' "$log" | sed -E 's/^sim: events=([0-9]+) loop_steps=[0-9]+ disk_ops=([0-9]+).*/\1 \2/')
	[ -n "$m" ] || m="- -"
	echo "XPLAT $lane $seed $m $rc"
	exit 0
fi
SEEDS=${1:-1-20}
LANES=${2:-default,until-run}
JOBS=${3:-2}
mkdir -p "$BIN"
cd "$ROOT"
ODIN=${ODIN:-}
for c in "$(command -v odin 2>/dev/null)" "$HOME/.local/bin/odin" "$HOME/.local/odin/odin"; do
	if [ -z "$ODIN" ] && [ -n "$c" ] && [ -x "$c" ]; then
		ODIN=$c
	fi
done
if [ -z "$ODIN" ]; then
	echo "XPLAT-ERROR no odin"
	exit 2
fi
if [ "$(uname)" = Darwin ]; then
	busy=$(ps -Ao pid,command | grep -E 'odin (build|test|check)|\.bin( |$)' | grep -v grep | grep -v "$BIN" | head -1)
	if [ -n "$busy" ]; then
		echo "XPLAT-BUSY $busy"
		exit 3
	fi
fi
start=$(date +%s)
if ! capped 8000000 perl -e 'alarm shift; exec @ARGV' 1500 "$ODIN" build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.simulate -out:"$BIN/sim.bin" > "$BIN/build.log" 2>&1; then
	echo "XPLAT-ERROR build $(tail -3 "$BIN/build.log" | tr '\n' ' ')"
	exit 2
fi
echo "XPLAT-BUILD $(( $(date +%s) - start ))"
lo=${SEEDS%-*}
hi=${SEEDS#*-}
start=$(date +%s)
for lane in $(echo "$LANES" | tr ',' ' '); do
	s=$lo
	while [ "$s" -le "$hi" ]; do
		echo "$lane $s"
		s=$((s + 1))
	done
done | xargs -P "$JOBS" -n 2 sh "$0" --one
echo "XPLAT-WALL $(( $(date +%s) - start ))"
