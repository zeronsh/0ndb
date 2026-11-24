#!/bin/bash
export PATH=/home/user/.local/odin:$PATH
echo $$ > /home/user/gates/$1.pid
while [ -n "${2:-}" ] && kill -0 "$2" 2>/dev/null; do sleep 15; done
out=/home/user/gates/out-$1
rm -rf "$out"; mkdir -p "$out"
cd /home/user/gates/wt/$1 && timeout 7000 /home/user/gates/bin/gate-sh2.sh "$out" > "$out.log" 2>&1
echo "rc=$?" > "$out.done"
