package sim

import "../../src/fs"

@(init)
_kv_rebuild_init :: proc "contextless" () {
	register_world(67, _kv_rebuild_world, nil)
}

@(private = "file")
_kv_rebuild_world :: proc(w: ^World) {
	fs.kv_rebuild_every = env_u64("SIM_KV_REBUILD", 2 if mix64(w.cfg.seed, 0x6b767265) % 3 == 2 else 0)
}
