#!/bin/sh
cd /home/user/gates/f4a8
B=/home/user/gates/f4a8/wtstep/bin/stepsize
L=logs/step.log
: > $L
for x in "20 60" "100 60" "400 60"; do set -- $x; d=/home/user/gates/f4a8/step-$1; rm -rf $d; echo "=== edits $1 idle $2" >> $L; timeout 1200 python3 stepwatch.py $1 $2 $d $B >> $L 2>&1; done
echo done >> $L
