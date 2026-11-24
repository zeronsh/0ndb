#!/bin/bash
D=/home/user/gates/daemon; case=down
export ONDB_HOME=$D/$case ONDB_RUNTIME_DIR=$D/$case-run ONDB_KEYSTORE=file HOME=$D/home USER=tester
H=/home/user/gates/bin/ondb-hide B=/home/user/gates/bin/ondb-base X=/home/user/gates/bin/ondb-stack T=$D/$case-tree
rm -rf $ONDB_HOME $ONDB_RUNTIME_DIR $T $T.copy; mkdir -p $ONDB_HOME $ONDB_RUNTIME_DIR $T
ulimit -v 8000000
dpid() { timeout 5 $B status 2>/dev/null | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p'; }
stop() { P=$(dpid); [ -n "$P" ] && [ "$(cat /proc/$P/comm)" = "$1" ] && kill -TERM $P; for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(dpid)" ] && break; sleep 0.5; done; }
look() { echo "--- $1"; timeout 60 $B verify $T 2>&1 | tail -2 | cut -c1-200; for f in f7 f13 f29; do echo "$f tree: $(timeout 20 $B blame $T/$f.txt 2>&1 | wc -l) lines, last: $(timeout 20 $B blame $T/$f.txt 2>&1 | tail -1 | cut -c1-60)"; done; echo "disk vs the user's copy: $(diff -rq $T $T.copy 2>/dev/null | wc -l) differ"; diff -r $T $T.copy 2>/dev/null | head -6; }
timeout 30 $B daemon start --no-runner > /dev/null 2>&1
for i in $(seq 1 40); do echo "file $i line one" > $T/f$i.txt; done
timeout 30 $B mount $T > /dev/null 2>&1
for r in 1 2 3; do sleep 2; for i in $(seq 1 40); do echo "round $r for $i" >> $T/f$i.txt; done; done; sleep 4
cp -r $T $T.copy; look "base 2e7233d"
stop ondb-base; timeout 30 $X daemon start --no-runner > /dev/null 2>&1; sleep 4
for i in 7 13; do echo "round 4 for $i" | tee -a $T/f$i.txt >> $T.copy/f$i.txt; done; sleep 4; look "stack (upgraded, two edits)"
stop ondb-stack; timeout 30 $B daemon start --no-runner > /dev/null 2>&1; sleep 4
for i in 7 29; do echo "round 5 for $i" | tee -a $T/f$i.txt >> $T.copy/f$i.txt; done; sleep 4; look "old build on the upgraded home (two edits)"; timeout 20 $B mount $T 2>&1 | tail -1 | cut -c1-160; grep -a 'remount' $ONDB_HOME/daemon.log | tail -1 | cut -c1-160
stop ondb-base; timeout 30 $X daemon start --no-runner > /dev/null 2>&1; sleep 6; look "stack again"
echo "round 6 for 29" | tee -a $T/f29.txt >> $T.copy/f29.txt; sleep 4; look "stack again, one more edit"
stop ondb-stack
