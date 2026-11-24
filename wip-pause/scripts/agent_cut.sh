export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/stepbase; w=$1; tag=$2
cd $G/$w
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.agent_cut_crash -define:ODIN_TEST_THREADS=1 -out:$G/ac_$tag) > $G/ac_${tag}_build.log 2>&1
(ulimit -v 4000000; timeout 900 $G/ac_$tag > $G/ac_$tag.txt 2>&1); echo "AC END" >> $G/ac_$tag.txt
