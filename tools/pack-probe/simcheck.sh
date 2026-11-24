#!/bin/sh
cd "$1" || exit 1
export PATH=$HOME/.local/odin:$PATH
ulimit -v 8000000
echo "== sim $(git log --oneline -1)"; timeout 3000 odin test tests/sim -o:speed -out:$2 2>&1 | grep -v "^\[INFO" | tail -14
echo done
