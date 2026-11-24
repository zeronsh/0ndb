#!/bin/sh
cd "$1" || exit 1
export PATH=$HOME/.local/odin:$PATH
ulimit -v 8000000
for t in "" -target:darwin_arm64 -target:windows_amd64; do echo "== vet pack $t"; timeout 600 odin check src/pack -vet -strict-style -no-entry-point $t 2>&1 | tail -3; done
for s in convergence fstree; do echo "== $s"; timeout 1500 odin test tests/$s -o:speed -out:$2/$s.bin 2>&1 | grep -v "^\[INFO" | tail -4; done
echo "== sim"; timeout 2400 odin test tests/sim -o:speed -out:$2/sim.bin 2>&1 | grep -v "^\[INFO" | tail -12
echo done
