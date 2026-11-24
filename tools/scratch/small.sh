#!/bin/bash
G=/home/user/gates; ulimit -v 4000000
for r in 1 2 3; do SIM_SEED=296 SIM_DURABILITY=async timeout 900 $G/bin/h6f-sim > $G/a296.$r.log 2>&1; echo "async 296 #$r rc=$? $(grep -aE 'FAILED|observe|Corrupt' $G/a296.$r.log | head -2 | cut -c1-200)"; done
for r in 1 2; do SIM_SEED=34 timeout 900 $G/out-kvf2-g/sim.bin > $G/w34.$r.log 2>&1; echo "wide 34 fresh #$r rc=$? $(grep -a 'sim: events=' $G/w34.$r.log | cut -c1-110) $(grep -ac NOT.det $G/w34.$r.log)"; done
SIM_SEED=34 SIM_VERBOSE=1 timeout 900 $G/out-kvf2-g/sim.bin > $G/w34.verbose.log 2>&1; echo "verbose rc=$? $(wc -c < $G/w34.verbose.log)"
grep -aoE 'objects/objects/[0-9a-f]{2}/[0-9a-f]+ exists only in the (first|second) run' $G/out-kvf2-g/runs/wide-34.log | while read f rest; do h=${f#objects/objects/}; echo "$h ${rest##*the } count=$(grep -acF "$h" $G/w34.verbose.log)"; done
(time SIM_READ_FAULT=1 RF_MAX=400 timeout 3000 $G/bin/h6f-sim) > $G/rf.h6f.log 2>&1; echo "sweep rc=$?"; grep -aE 'CONTROL|fault points|real' $G/rf.h6f.log
echo done
