#!/bin/sh
cd /home/user/gates/f4a8
L=logs/cmp.log
: > $L
run(){ d=/home/user/gates/f4a8/cmp-$1-$2; rm -rf $d; python3 sw2.py $2 30 $d $3 "$1" >> $L 2>&1; rm -rf $d/state; }
run old 100 /home/user/gates/f4a8/wtold/bin/stepsize
run new 100 /home/user/gates/f4a8/wtstep/bin/stepsize
run old 400 /home/user/gates/f4a8/wtold/bin/stepsize
run new 400 /home/user/gates/f4a8/wtstep/bin/stepsize
echo done >> $L
