K 1
[INFO ] --- [2026-11-24 19:22:25] Starting test runner with 1 thread.
[INFO ] --- [2026-11-24 19:22:25] The random seed sent to every test is: 61001447728309. Set with -define:ODIN_TEST_RANDOM_SEED=n.
[INFO ] --- [2026-11-24 19:22:25] Memory tracking is enabled. Tests will log their memory usage if there's an issue.
[INFO ] --- [2026-11-24 19:22:25] < Final Mem/ Total Mem> <  Peak Mem> (#Free/Alloc) :: [package.test_name]
[    0.000] relay up
dop n0 open /data/device/device.key
dop n0 open /data/device/device.key.tmp.7b7a71f35e1c62bd
dop n0 open /data/device/device.key.lock
dop n0 rename /data/device/device.key.tmp.7b7a71f35e1c62bd /data/device/device.key
dop n0 open /data/device
dop n0 open /data/device/device.key
dop n0 open /data/lock
dop n0 open /data/gen
dop n0 open /data/pack/LOCK
dop n0 open /data/pack/super
dop n0 open /data/pack/super
dop n0 open /data/pack/c00000001
dop n0 open /data/pack
dop n0 open /data/pack
dop n0 open /data/registry
dop n0 open /data/registry.init
dop n0 rename /data/registry.init /data/registry
dop n0 open /data
dop n0 open /data/registry
[    0.000] n0 up (incarnation 1, self b983f9c6)
dop n1 open /data/device/device.key
dop n1 open /data/device/device.key.tmp.efdbca971e067e0d
dop n1 open /data/device/device.key.lock
dop n1 rename /data/device/device.key.tmp.efdbca971e067e0d /data/device/device.key
dop n1 open /data/device
dop n1 open /data/device/device.key
dop n1 open /data/lock
dop n1 open /data/gen
dop n1 open /data/pack/LOCK
dop n1 open /data/pack/super
dop n1 open /data/pack/super
dop n1 open /data/pack/c00000001
dop n1 open /data/pack
dop n1 open /data/pack
dop n1 open /data/registry
dop n1 open /data/registry.init
dop n1 rename /data/registry.init /data/registry
dop n1 open /data
dop n1 open /data/registry
[    0.000] n1 up (incarnation 1, self 47aa329f)
dop n0 open /data/objects/.tmp_18d75b7ebf062979
dop n0 rename /data/objects/.tmp_18d75b7ebf062979 /data/objects/HEAD
dop n0 open /data/objects/.tmp_18d75b7ebf06297a
dop n0 rename /data/objects/.tmp_18d75b7ebf06297a /data/objects/config
dop n0 open /data/objects/config
dop n0 open /data/objects/objects/info/alternates
dop n0 open /data/gen.tmp
dop n0 rename /data/gen.tmp /data/gen
dop n0 open /data
[    2.366] FAIL publish: n0 handed bytes up to 33 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c625952ff1664290b19ec18643c0acc6bf to the relay with only 0 durable
[    2.366] FAIL publish: n0 handed bytes up to 104 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c6264713bdf850e00c92602be18b4b936c to the relay with only 0 durable
[    2.366] FAIL publish: n0 handed bytes up to 443 of /data/pack/o/01/01a0c450117f7ebaa2a275a49d2c6c86/hist/fs.journal to the relay with only 0 durable
[    2.366] FAIL publish: n0 handed bytes up to 1098 of /data/pack/members/a4c9169ef711894631aab98b05076604/stream to the relay with only 605 durable
[    2.366] FAIL publish: n0 handed bytes up to 691 of /data/pack/o/39/39625f5e9d158f4055c6489ea2a035fa/seg to the relay with only 0 durable
[    2.366] FAIL publish: n0 handed bytes up to 33 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c66745fdd6f40996dc3dafdbc16f0f0a92 to the relay with only 0 durable
[    2.366] FAIL publish: n0 handed bytes up to 104 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c6a623eab4fcc9a634a7a42df00073e6df to the relay with only 0 durable
[    2.366] n0 connected 05076604
dop n0 open /data/objects/HEAD
dop n0 open /data/objects/config
dop n0 open /data
dop n0 open /data/objects
[   34.626] FAIL publish: n1 handed bytes up to 493 of /data/pack/members/a4c9169ef711894631aab98b05076604/stream to the relay with only 0 durable
[   34.626] n1 connected 05076604
[   79.484] FAIL publish: n1 handed bytes up to 1034 of /data/pack/members/a4c9169ef711894631aab98b05076604/stream to the relay with only 493 durable
[  508.782] FAIL publish: n0 handed bytes up to 1717 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c6072f80d3f84c1cacc0f34915c6eb0a87 to the relay with only 0 durable
[  508.782] FAIL publish: n0 handed bytes up to 66 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c625952ff1664290b19ec18643c0acc6bf to the relay with only 33 durable
[  508.782] FAIL publish: n0 handed bytes up to 66 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c66745fdd6f40996dc3dafdbc16f0f0a92 to the relay with only 33 durable
[  508.782] FAIL publish: n0 handed bytes up to 1717 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c67fe50ae6f07dcc6d10b047d2489b74a8 to the relay with only 0 durable
[ 2290.469] FAIL publish: n0 handed bytes up to 682 of /data/pack/o/9d/9dbdc61222068b821cbce4aac29166ef/seg to the relay with only 0 durable
[ 2290.469] FAIL publish: n0 handed bytes up to 33 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c65fd92ba2ecf4e760873392d759009ab7 to the relay with only 0 durable
[ 2290.469] FAIL publish: n0 handed bytes up to 104 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k0417d8715be22477fd29053eb983f9c6a80a7f77d02a634280f9de0844ebf67b to the relay with only 0 durable
[ 2290.469] FAIL publish: n0 handed bytes up to 1153 of /data/pack/o/39/39625f5e9d158f4055c6489ea2a035fa/seg to the relay with only 691 durable
dop n1 open /data/objects/.tmp_18d75b8239df3140
dop n1 rename /data/objects/.tmp_18d75b8239df3140 /data/objects/HEAD
dop n1 open /data/objects/.tmp_18d75b8239df3141
dop n1 rename /data/objects/.tmp_18d75b8239df3141 /data/objects/config
dop n1 open /data/objects/config
dop n1 open /data/objects/objects/info/alternates
dop n1 open /data
dop n1 open /data/worktrees
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/lock
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/state.0
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/state.1
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/mount
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/attrib.log
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.gen
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.0.log
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.0.log.tmp
dop n1 rename /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.0.log.tmp /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.0.log
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.0.log
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.0.idx
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.gen.tmp
dop n1 rename /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.gen.tmp /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow/shadow.gen
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/shadow
dop n1 open /etc/gitconfig
dop n1 open /home/sim/.config/git/config
dop n1 open /home/sim/.gitconfig
dop n1 open /home/sim/.config/git/attributes
dop n1 open /home/sim/.config/git/ignore
dop n1 open /proc/sys/kernel/random/boot_id
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/state.1
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11/state.1
dop n1 open /data/worktrees/634e0403c6aae4bc5c1e35ff21926f11
dop n1 open /data/objects/objects/pack/tmp_pack_18d75b8239df3142
dop n1 open /work/rim-n1
dop n1 open /data/objects/objects/tmp_obj_18d75b8239df3143
dop n1 open /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86
dop n1 open /data/objects/packed-refs
dop n1 open /data/objects/objects/tmp_obj_18d75b8239df3144
dop n1 open /data/objects/objects/tmp_obj_18d75b8239df3143
dop n1 open /data/objects/objects/tmp_obj_18d75b8239df3144
dop n1 rename /data/objects/objects/tmp_obj_18d75b8239df3143 /data/objects/objects/4b/825dc642cb6eb9a060e54bf8d69288fbee4904
dop n1 rename /data/objects/objects/tmp_obj_18d75b8239df3144 /data/objects/objects/59/23658b1eb8bb02d5838e9168cfdefbe450bd7a
dop n1 open /data/objects/objects
dop n1 open /data/objects/objects/4b
dop n1 open /data/objects/objects/59
dop n1 open /data/objects/HEAD
dop n1 open /data/objects/config
dop n1 open /data
dop n1 open /data/objects
dop n1 open /data/objects/objects
dop n1 open /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86.lock
dop n1 open /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86
dop n1 open /data/objects/packed-refs
dop n1 rename /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86.lock /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86
dop n1 open /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86
dop n1 open /data/objects
dop n1 open /data/objects/refs
dop n1 open /data/objects/refs/0ndb
dop n1 open /data/objects/refs/0ndb/01a0c450117f7ebaa2a275a49d2c6c86
dop n1 open /data/gen.tmp
dop n1 rename /data/gen.tmp /data/gen
dop n1 open /data
[ 6682.039] FAIL publish: n1 handed bytes up to 33 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k2679a60edbb621c335a3da2c47aa329f25952ff1664290b19ec18643c0acc6bf to the relay with only 0 durable
[ 6682.039] FAIL publish: n1 handed bytes up to 104 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k2679a60edbb621c335a3da2c47aa329f264713bdf850e00c92602be18b4b936c to the relay with only 0 durable
[ 6682.039] FAIL publish: n1 handed bytes up to 471 of /data/pack/o/01/01a0c450117f7ebaa2a275a49d2c6c86/hist/fs.journal to the relay with only 0 durable
[ 6682.039] FAIL publish: n1 handed bytes up to 524 of /data/pack/o/39/39625f5e9d158f4055c6489ea2a035fa/seg to the relay with only 0 durable
[ 6682.039] FAIL publish: n1 handed bytes up to 33 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k2679a60edbb621c335a3da2c47aa329f6745fdd6f40996dc3dafdbc16f0f0a92 to the relay with only 0 durable
[ 6682.039] FAIL publish: n1 handed bytes up to 104 of /data/pack/sync/a4c9169ef711894631aab98b05076604/ckpt/k2679a60edbb621c335a3da2c47aa329fa623eab4fcc9a634a7a42df00073e6df to the relay with only 0 durable
[ 6690.580] n1 crashed at disk op 426 (Power)

Caught interrupt signal. Stopping all tests.

Finished 0 tests in 25.000471258s. 1 test was left undone.
