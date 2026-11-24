#!/bin/sh
cd /home/user/gates/f4a8
L=logs/pk.log
: > $L
for n in "pk" ; do d=/home/user/gates/f4a8/pk-run; rm -rf $d; timeout 660 python3 sw2.py 400 60 $d /home/user/gates/f4a8/wtpk/bin/stepvar "$n" "" >> $L 2>&1; rm -rf $d/state $d/repo; done
echo done >> $L
