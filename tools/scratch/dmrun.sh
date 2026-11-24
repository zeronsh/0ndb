#!/bin/bash
case=$1; D=/home/user/gates/daemon
export ONDB_HOME=$D/$case ONDB_RUNTIME_DIR=$D/$case-run ONDB_KEYSTORE=file HOME=$D/home USER=tester
B=/home/user/gates/bin/ondb-base F=/home/user/gates/bin/ondb-fault T=$D/$case-tree
rm -rf $ONDB_HOME $ONDB_RUNTIME_DIR $T; mkdir -p $ONDB_HOME $ONDB_RUNTIME_DIR $T
ulimit -v 8000000
look() { echo "--- $1"; timeout 30 $B status 2>&1 | grep -E 'engine|mount|daemon' | cut -c1-110 | head -4; timeout 60 $B verify $T 2>&1 | tail -3 | cut -c1-200; echo "blame f7:"; timeout 20 $B blame $T/f7.txt 2>&1 | head -6 | cut -c1-90; echo "disk: $(ls $T | wc -l) files, changed against the copy: $(diff -rq $T $T.copy 2>/dev/null | wc -l)"; diff -rq $T $T.copy 2>/dev/null | head -5; }
timeout 30 $B daemon start --no-runner > /dev/null 2>&1
for i in $(seq 1 40); do echo "file $i line one" > $T/f$i.txt; done
timeout 30 $B mount $T 2>&1 | tail -1
for r in 1 2 3 4 5; do sleep 2; for i in $(seq 1 40); do echo "round $r for $i" >> $T/f$i.txt; done; done; sleep 4
rm -rf $T.copy; cp -r $T $T.copy
look "before"
P=$(sed -n 's/^\([0-9]*\).*/\1/p' $ONDB_HOME/daemon.lock 2>/dev/null | head -1); P=${P:-$(timeout 5 $B status | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p')}
[ "$(cat /proc/$P/comm 2>/dev/null)" = ondb-base ] && kill -KILL $P; sleep 1
if [ "$2" != none ]; then
 KVF=$2 timeout 30 $F daemon start --no-runner > $D/$case.fault.out 2>&1; sleep 4; grep -ah KVF $ONDB_HOME/daemon.log $D/$case.fault.out | sed 's#/home.*/o/#o/#' | head -8
 look "during the fault boot"
 P=$(timeout 5 $B status | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p'); [ "$(cat /proc/$P/comm 2>/dev/null)" = ondb-fault ] && kill -KILL $P; sleep 1
fi
timeout 30 $B daemon start --no-runner > /dev/null 2>&1; sleep 4
look "after, plain 2e7233d build"
echo "a person edits f7 and f9 after" ; echo "after the fault" >> $T/f7.txt; echo "after the fault" >> $T/f9.txt; echo "after the fault" >> $T.copy/f7.txt; echo "after the fault" >> $T.copy/f9.txt; sleep 5
look "after an edit"
grep -aiE 'corrupt|damag|rebuil|wip|lost' $ONDB_HOME/daemon.log | sort | uniq -c | head -8
P=$(timeout 5 $B status | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p'); [ "$(cat /proc/$P/comm 2>/dev/null)" = ondb-base ] && kill -TERM $P
