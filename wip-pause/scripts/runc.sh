export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/stepbase; w=$1; tag=$2
cd $G/$w
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.step_attack -out:$G/sa_$tag) > $G/sa_${tag}_build.log 2>&1
(ulimit -v 4000000; timeout 3000 $G/sa_$tag > $G/sa_$tag.txt 2>&1); echo "SA END" >> $G/sa_$tag.txt
