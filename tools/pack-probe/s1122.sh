#!/bin/sh
cd /home/user/gates/f4a8/wts2
export PATH=$HOME/.local/odin:$PATH
mkdir -p bin
L=/home/user/gates/f4a8/logs/s1122.log
: > $L
(ulimit -v 8000000; timeout 900 odin build src/cli -out:bin/0ndb-soak -o:speed -define:ONDB_TEST_MODEL_URL=http://127.0.0.1:1/ondb-soak-no-provider >> $L 2>&1) || { echo "build failed" >> $L; exit 1; }
for i in 1 2; do rm -rf /home/user/gates/f4a8/s1122-$i; SOAK_HOME_MAX_MB=1500 timeout 600 python3 tools/soak/soak.py --minutes 6 --restart 9 --seed 3 --skip redo --stop --keep --bin bin/0ndb-soak --dir /home/user/gates/f4a8/s1122-$i < /dev/null >> $L 2>&1; done
echo done >> $L
