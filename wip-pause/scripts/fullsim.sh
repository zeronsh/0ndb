export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/stepbase
cd $G/wt4
(ulimit -v 8000000; timeout 2400 odin build tests/sim -build-mode:test -o:speed -out:$G/sim4) > $G/sim4_build.log 2>&1
echo BUILT >> $G/sim4_build.log
