#!/bin/bash
N=$1; case=hide$N; D=/home/user/gates/daemon
export ONDB_HOME=$D/$case ONDB_RUNTIME_DIR=$D/$case-run ONDB_KEYSTORE=file HOME=$D/home USER=tester
H=/home/user/gates/bin/ondb-hide B=/home/user/gates/bin/ondb-base X=/home/user/gates/bin/ondb-khs T=$D/$case-tree
rm -rf $ONDB_HOME $ONDB_RUNTIME_DIR $T $T.copy; mkdir -p $ONDB_HOME $ONDB_RUNTIME_DIR $T
ulimit -v 8000000
dpid() { timeout 5 $B status 2>/dev/null | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p'; }
stop() { P=$(dpid); [ -n "$P" ] && [ "$(cat /proc/$P/comm)" = "$1" ] && kill -TERM $P; for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(dpid)" ] && break; sleep 0.5; done; }
look() { echo "--- $1"; timeout 60 $B verify $T 2>&1 | tail -2 | cut -c1-200; for f in f7 f13 f29; do echo "$f tree: $(timeout 20 $B blame $T/$f.txt 2>&1 | wc -l) lines, last: $(timeout 20 $B blame $T/$f.txt 2>&1 | tail -1 | cut -c1-60)"; done; echo "disk vs the user's copy: $(diff -rq $T $T.copy 2>/dev/null | wc -l) differ"; diff -r $T $T.copy 2>/dev/null | head -6; }
KVF_HIDE=$N timeout 30 $H daemon start --no-runner > /dev/null 2>&1
for i in $(seq 1 40); do echo "file $i line one" > $T/f$i.txt; done
timeout 30 $B mount $T > /dev/null 2>&1
for r in 1 2 3 4 5 6; do sleep 2; for i in $(seq 1 40); do echo "round $r for $i" >> $T/f$i.txt; done; done; sleep 5
cp -r $T $T.copy
grep -ah 'KVF hide' $ONDB_HOME/daemon.log | sed 's#/home.*/o/#o/#' | head -3
look "on the faulted daemon"
stop ondb-hide
timeout 30 $B daemon start --no-runner > /dev/null 2>&1; sleep 4
look "plain 2e7233d after restart"
for i in 7 13 29; do echo "round 7 for $i" >> $T/f$i.txt; echo "round 7 for $i" >> $T.copy/f$i.txt; done; sleep 5
look "plain 2e7233d after more edits"
stop ondb-base
timeout 30 $X daemon start --no-runner > /dev/null 2>&1; sleep 4
look "fixed build (kv-hidden-slot-1)"
stop ondb-khs
