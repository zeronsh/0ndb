#!/bin/sh
cd /home/user/gates/f4a8
L=logs/var.log
: > $L
for v in "base:" "same-actor:a" "same-scope:i" "no-base:b" "no-observe:o" "no-scope:s" "pump60:p"; do n=${v%%:*}; f=${v#*:}; d=/home/user/gates/f4a8/var-$n; rm -rf $d; timeout 660 python3 sw2.py 400 0 $d /home/user/gates/f4a8/wtold/bin/stepvar "$n" "$f" >> $L 2>&1; ls -la $d/state/pack 2>/dev/null | awk -v n=$n '$9 ~ /^x/{s+=$5;c++} END{print n, "external files", c, "bytes", s}' >> $L; rm -rf $d/state $d/repo; done
echo done >> $L
