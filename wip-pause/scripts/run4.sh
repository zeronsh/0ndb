export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/stepbase; tag=$1
cd $G/wt4
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.step_replay,sim.retarget_keep,sim.named_version_crash,sim.named_version_edit,sim.step_attack -out:$G/sr_$tag) > $G/sr_${tag}_build.log 2>&1
(ulimit -v 4000000; timeout 3600 $G/sr_$tag > $G/sr_$tag.txt 2>&1); echo "SR END" >> $G/sr_$tag.txt
