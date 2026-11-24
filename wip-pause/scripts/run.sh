export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/stepbase; tag=$1
cd $G/wt
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.step_replay -out:$G/sr_$tag) > $G/sr_${tag}_build.log 2>&1
(ulimit -v 4000000; timeout 3000 $G/sr_$tag > $G/sr_$tag.txt 2>&1); echo "SR END" >> $G/sr_$tag.txt
