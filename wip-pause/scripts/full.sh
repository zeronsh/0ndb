export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/retarget; w=$1
bash $G/sig.sh $w
cd $G/wt-$w
cp $G/nv.odin tests/sim/named_version_crash.odin
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.named_version_crash,sim.retarget_keep -out:$G/full_$w) > $G/full_${w}_build.log 2>&1
(ulimit -v 4000000; timeout 3000 $G/full_$w > $G/full_$w.txt 2>&1); echo "NV END" >> $G/full_$w.txt
