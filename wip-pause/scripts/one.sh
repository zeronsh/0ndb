#!/bin/bash
BIN=$1; LANE=$2; SEED=$3
ulimit -v 4000000
case $LANE in default) E="";; async) E="SIM_DURABILITY=async";; until-run) E="SIM_STORAGE=until-run";; byzantine) E="SIM_BYZANTINE=1";; esac
o=$(env $E SIM_SEED=$SEED timeout 900 $BIN 2>&1)
r=$(echo "$o" | grep -aE "trace: FAIL|\[FATAL\]|CRASHED" | head -1 | sed 's/^ *//' | cut -c1-220)
echo "$o" | grep -aqE "Finished .* tests" || r="${r:-NO FINISH}"
echo "$LANE $SEED: ${r:-pass}"
