#!/bin/bash
ulimit -v 4000000
run() { SIM_SEED=20 timeout 200 /home/user/gates/out-rtp4/sim.bin > /home/user/gates/p20.$1.log 2>&1; echo "$1 rc=$? $(grep -a '^sim: events' /home/user/gates/p20.$1.log | grep -o 'events=[0-9]* loop_steps=[0-9]* disk_ops=[0-9]*')"; }
for r in 1 2 3; do for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do run $r.$i & done; wait; done
