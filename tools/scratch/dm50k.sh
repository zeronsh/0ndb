#!/bin/bash
D=/home/user/gates/daemon; case=heal50k
export ONDB_HOME=$D/$case ONDB_RUNTIME_DIR=$D/$case-run ONDB_KEYSTORE=file HOME=$D/home USER=tester
B=/home/user/gates/bin/ondb-sh2 T=$D/$case-tree
rm -rf $ONDB_HOME $ONDB_RUNTIME_DIR $T; mkdir -p $ONDB_HOME $ONDB_RUNTIME_DIR $T
ulimit -v 8000000
dpid() { timeout 5 $B status 2>/dev/null | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p'; }
start() { local t0=$(date +%s.%N); timeout 120 $B daemon start --no-runner >/dev/null 2>&1; local t1=$(date +%s.%N); echo "$1: daemon start $(echo "$t1 - $t0" | bc) s, rss $(grep VmHWM /proc/$(dpid)/status | awk '{print $2}') kB peak"; }
kill9() { P=$(dpid); [ "$(cat /proc/$P/comm)" = ondb-sh2 ] && kill -9 $P; sleep 1; }
timeout 30 $B daemon start --no-runner >/dev/null 2>&1
python3 -I - $T <<'P'
import os,sys
t=sys.argv[1]
for i in range(50000):
    d=f"{t}/d{i%200}"; os.makedirs(d,exist_ok=True) if i<200 else None
    open(f"{d}/f{i}.txt","w").write(f"file {i}\nsecond line of it\n")
P
timeout 300 $B mount $T | tail -1
for i in $(seq 1 60); do sleep 2; timeout 60 $B verify $T > $D/v.out 2>&1; grep -q '50000 files match' $D/v.out && break; done; cat $D/v.out; 
sleep 5; kill9; start "control (kill -9, undamaged)"; timeout 120 $B verify $T | tail -1
kill9; L=$(ls $ONDB_HOME/*/worktrees/*/shadow/shadow.*.log 2>/dev/null | head -1; find $ONDB_HOME -name 'shadow.*.log' | head -1); L=$(echo "$L" | head -1); ls -la $L
python3 -I - $L <<'P'
import sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read()); i=b.find(b'd77/f20077.txt'); b[i+18]^=0x10; open(p,'r+b').write(b)
P
rm -f ${L%.log}.idx
start "damaged record, index gone"; timeout 120 $B verify $T | tail -1; grep -a remount $ONDB_HOME/daemon.log | tail -1; ls $(dirname $L)
kill9; L=$(find $ONDB_HOME -name 'shadow.*.log' | head -1); rm -f $L; start "log gone"; timeout 120 $B verify $T | tail -1
kill9; start "control again"; timeout 120 $B verify $T | tail -1; P=$(dpid); kill -TERM $P
