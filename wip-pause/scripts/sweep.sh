G=/home/user/gates/stepbase
cd $G
for lane in default async until-run; do for s in $(seq 1 84); do echo "$lane $s"; done; done | xargs -P 5 -L1 bash -c '$0 "$@"' ./seedrun.sh ./sim4 > sweep4.txt 2>&1
echo SWEEPEND >> sweep4.txt
