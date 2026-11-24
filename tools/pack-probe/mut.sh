#!/bin/sh
cd /home/user/gates/f4a8/wtad
export PATH=$HOME/.local/odin:$PATH
L=/home/user/gates/f4a8/logs/mut.log
: > $L
one(){ echo "== $1" >> $L; cp ../vfs.keep src/pack/vfs.odin; sed -i "$2" src/pack/vfs.odin; cmp -s src/pack/vfs.odin ../vfs.keep && echo "(mutation did not apply)" >> $L; (ulimit -v 8000000; timeout 900 odin build tests/sim -build-mode:test -o:speed -out:../adm.bin -define:ODIN_TEST_NAMES=sim.pack_admit >> $L 2>&1; echo "build rc=$?" >> $L); (ulimit -v 4000000; timeout 250 ../adm.bin 2>&1 | grep -v "^\[INFO" | grep -v "^$" | tail -3 >> $L); cp ../vfs.keep src/pack/vfs.odin; }
one "no wait" 's/		return _admitted_wait(p)/		return .Would_Block/'
one "never wait" 's/		return _admitted_wait(p)/		return .None/'
one "no refusal at begin" 's/	if _async(p) \&\& p.fl.on \&\& (_over_budget(p, 4)/	if false \&\& (_over_budget(p, 4)/'
echo done >> $L
