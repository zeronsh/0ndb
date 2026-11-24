#!/bin/bash
export PATH=/home/user/.local/odin:$PATH
for x in rtp4 kvf; do
	out=/home/user/gates/out-$x
	rm -rf $out; mkdir -p $out
	cd /home/user/gates/wt/$x && timeout 7000 /home/user/gates/bin/gate-rec.sh $out > $out.log 2>&1
	echo "$x rc=$? $(date -u +%T)" >> /home/user/gates/queue1.done
done
