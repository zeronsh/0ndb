export PATH=$HOME/.local/odin:$PATH
cd /home/user/gates/retarget/wt-base && cp /home/user/gates/retarget/nv.odin tests/sim/named_version_crash.odin
(ulimit -v 8000000; timeout 1500 odin build tests/sim -build-mode:test -o:speed -define:ODIN_TEST_NAMES=sim.named_version_crash -out:/home/user/gates/retarget/nvb_full) > /home/user/gates/retarget/nvb_build.log 2>&1
(ulimit -v 4000000; timeout 1800 /home/user/gates/retarget/nvb_full > /home/user/gates/retarget/nvb_full.txt 2>&1); echo "NV END" >> /home/user/gates/retarget/nvb_full.txt
