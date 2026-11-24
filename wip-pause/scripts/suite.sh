export PATH=$HOME/.local/odin:$PATH
G=/home/user/gates/stepbase; w=$1; tag=$2; names=$3
cd $G/$w
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=$names -out:$G/su_$tag) > $G/su_${tag}_build.log 2>&1
(ulimit -v 4000000; timeout 5400 $G/su_$tag > $G/su_$tag.txt 2>&1); echo "SU END" >> $G/su_$tag.txt
