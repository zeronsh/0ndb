#!/bin/bash
export PATH=/home/user/.local/odin:$PATH
G=/home/user/gates; cd $G/wt/kvf2 && (ulimit -v 6000000; timeout 900 odin build tests/sim -build-mode:test -o:speed -out:$G/bin/kvf2-sim > $G/kvf2-build.log 2>&1)
ulimit -v 4000000
for b in kvf2 khs; do for s in 1 3 5 7; do t0=$(date +%s.%N); SIM_SEED=$s timeout 300 $G/bin/$b-sim > $G/x.$b.log 2>&1; rc=$?; t1=$(date +%s.%N); echo "$b seed $s rc=$rc $(grep -aoE 'Finished [0-9]+ tests in [0-9.]+m?s' $G/x.$b.log | head -1) wall=$(echo "$t1 - $t0" | bc)"; done; done
for b in kvf2 khs; do SIM_READ_FAULT=1 RF_MAX=400 timeout 900 $G/bin/$b-sim > $G/rf.$b.log 2>&1; echo "== $b rc=$?"; grep -aE 'CONTROL|fault points' $G/rf.$b.log | cut -c1-90; done
echo done
