#!/bin/bash
G=/home/user/gates
ulimit -v 4000000
for r in 1 2 3; do for s in 5 7; do for b in kvf2 khs; do
SIM_SEED=$s /usr/bin/time -o $G/hst.t -f '%e wall %U user %S sys %M kB' timeout 400 $G/bin/$b-sim > $G/hst.$b.$s.$r.log 2>&1
echo "r$r seed $s $b $(tail -1 $G/hst.t) load=$(cut -d' ' -f1 /proc/loadavg) $(grep -aoE 'Finished [0-9]+ tests in [0-9.a-z]+' $G/hst.$b.$s.$r.log|head -1)"
done; done; done; echo done
