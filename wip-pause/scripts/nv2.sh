export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/retarget
cd $G/wt-2
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.named_version_crash,sim.retarget_keep -out:$G/nv2) > $G/nv2_build.log 2>&1
(ulimit -v 4000000; timeout 3000 $G/nv2 > $G/nv2.txt 2>&1); echo "NV END" >> $G/nv2.txt
