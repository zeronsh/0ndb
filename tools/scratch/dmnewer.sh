#!/bin/bash
D=/home/user/gates/daemon; case=newer
export ONDB_HOME=$D/$case ONDB_RUNTIME_DIR=$D/$case-run ONDB_KEYSTORE=file HOME=$D/home USER=tester
B=/home/user/gates/bin/ondb-newer F=/home/user/gates/bin/ondb-f3 T=$D/$case-tree
rm -rf $ONDB_HOME $ONDB_RUNTIME_DIR $T $T.copy; mkdir -p $ONDB_HOME $ONDB_RUNTIME_DIR $T
ulimit -v 8000000
dpid() { timeout 5 $B status 2>/dev/null | sed -n 's/^daemon *pid \([0-9]*\).*/\1/p'; }
stop() { P=$(dpid); [ -n "$P" ] && [ "$(cat /proc/$P/comm)" = "$1" ] && kill -TERM $P; for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(dpid)" ] && break; sleep 0.5; done; }
look() { echo "--- $1"; timeout 60 $B verify $T 2>&1 | tail -2 | cut -c1-200; for f in f7 f29; do echo "$f: $(timeout 20 $B blame $T/$f.txt 2>&1 | wc -l) lines, last: $(timeout 20 $B blame $T/$f.txt 2>&1 | tail -1 | cut -c1-90)"; done; timeout 10 $B status | grep '^mount'; echo "disk vs copy: $(diff -rq $T $T.copy | wc -l) differ"; }
objs() { timeout 10 $B ls --all 2>&1 | wc -l; }
timeout 30 $F daemon start --no-runner >/dev/null 2>&1
for i in $(seq 1 40); do echo "file $i line one" > $T/f$i.txt; done
timeout 30 $F mount $T 2>&1 | tail -1
for r in 1 2 3; do sleep 2; for i in $(seq 1 40); do echo "round $r for $i" >> $T/f$i.txt; done; done; sleep 4
cp -r $T $T.copy; look "format 3 build"; echo "objects: $(objs)"
stop ondb-f3; timeout 30 $B daemon start --no-runner >/dev/null 2>&1; sleep 4
look "this build on a format 3 home"; grep -a remount $ONDB_HOME/daemon.log | tail -1; echo "mount ls:"; timeout 10 $B mount ls
for i in 7 29; do echo "round 4 for $i" | tee -a $T/f$i.txt >> $T.copy/f$i.txt; done; sleep 3
echo "manual mount:"; timeout 20 $B mount $T; echo "rc=$?"; echo "objects after the refused mount: $(objs)"
echo "mount --tree of another tree:"; mkdir -p $D/newer-other; timeout 20 $B mount $D/newer-other 2>&1 | tail -1; O=$(timeout 10 $B mount ls | sed -n 's/.*newer-other → tree \([0-9a-f]*\).*/\1/p'); timeout 20 $B mount $T --tree $O; echo "rc=$? (tree $O)"
echo "mount --tree of its own tree:"; N=$(timeout 10 $B mount ls | sed -n 's/.*newer-tree → tree \([0-9a-f]*\).*/\1/p'); timeout 20 $B mount $T --tree $N; echo "rc=$? (tree $N)"
echo "again after a restart:"; stop ondb-newer; timeout 30 $B daemon start --no-runner >/dev/null 2>&1; sleep 4; timeout 20 $B mount $T; echo "rc=$?"
echo "disk vs copy: $(diff -rq $T $T.copy | wc -l) differ"
stop ondb-newer; timeout 30 $F daemon start --no-runner >/dev/null 2>&1; sleep 6; look "format 3 build again"
stop ondb-f3; timeout 30 $B daemon start --no-runner >/dev/null 2>&1; sleep 4; echo "mount rm:"; timeout 10 $B mount rm $T; timeout 20 $B mount $T; echo "rc=$?"; stop ondb-newer
