package sim

import "core:fmt"
import eng "../../src/engine"
import "../../src/pack"
import "../../src/prim"
import osync "../../src/sync"

NODE_DIR :: "/data"
RELAY_DIR :: "/relay"

loop_due :: proc(l: ^prim.Loop) -> bool {
	at, ok := loop_deadline(l)
	if !ok {
		return false
	}
	return at <= prim.loop_now_ns(l)
}

node_start :: proc(n: ^Node) -> bool {
	w := n.w
	n.incarnation += 1
	{
		context = w.ctx
		bid := fmt.tprintf("%08x-%04x-4%03x-8%03x-%012x\n", u32(w.cfg.seed), u32(n.idx), u32(n.boot) & 0xfff, u32(n.boot >> 12) & 0xfff, u64(n.boot) * 0x9e3779b1)
		disk_put_virtual(&n.disk, "/proc/sys/kernel/random/boot_id", transmute([]u8)bid)
	}
	rng_init(&n.rng, w.cfg.seed, 1000 + u64(n.idx) * 64 + u64(n.incarnation))
	rng_init(&n.ids, w.cfg.seed, 9000 + u64(n.idx) * 64 + u64(n.incarnation))
	if !instance_begin(&n.inst, n.idx) {
		world_fail(w, "%s could not map its deterministic memory region", n.name)
		return false
	}
	context = instance_context(&n.inst)
	if err := prim.loop_init(&n.inst.loop); err != .None {
		world_fail(w, "%s loop_init failed: %v", n.name, err)
		_free_partial(n)
		return false
	}
	n.inst.loop_on = true
	prim.loop_set_clock(&n.inst.loop, node_clock(&n.clock))
	vfs := disk_vfs(&n.disk)
	if kerr := osync.file_keyring_open(&n.keyring, vfs, NODE_DIR + "/device", rng_random(&n.rng)); kerr != .None {
		if n.disk.dead {
			node_crashed(n)
			return false
		}
		if w.cfg.io_rate > 0 && (kerr == .Io || kerr == .No_Space) {
			world_note(w, "%s keyring open hit injected %v; supervisor retries", n.name, kerr)
			_free_partial(n)
			schedule(w, Sim_Event{at = w.now + 200_000_000, kind = .Restart, node = n.idx})
			return false
		}
		world_fail(w, "%s keyring open failed: %v", n.name, kerr)
		_free_partial(n)
		return false
	}
	n.key_open = true
	cfg := eng.default_config(NODE_DIR)
	cfg.vfs = vfs
	cfg.loop = &n.inst.loop
	cfg.keyring = osync.file_keyring(&n.keyring)
	cfg.transport = eng.Transport{data = n, open = _t_open, send = _t_send, close = _t_close}
	cfg.clock = node_clock(&n.clock)
	cfg.random = rng_random(&n.rng)
	cfg.ids = eng.Id_Source{data = n, next = _next_id}
	cfg.log = eng.Log{data = n, write = _on_log}
	cfg.events = eng.Event_Hook{data = n, event = _on_event}
	cfg.purge = eng.Purge_Hook{data = n, purge = _on_purge}
	cfg.credentials = eng.Credentials_Source{data = n, produce = node_credentials}
	cfg.write_observer = sim_observer(n)
	cfg.watcher = sim_watcher(n)
	cfg.embedder = sim_embedder()
	cfg.boot_id = eng.Boot_Source{boot_id = proc(data: rawptr) -> prim.Id {
		return {}
	}}
	cfg.search_options.train_min = w.cfg.train_min
	cfg.search_options.dict_sample_min = w.cfg.dict_sample_min
	cfg.search_options.no_compress = true
	cfg.durability = .Deferred
	cfg.kernel_tls = false
	cfg.settle_ms = w.cfg.settle_ms
	cfg.pack_options = pack.DEFAULT_OPTIONS
	cfg.pack_options.clock = node_clock(&n.clock)
	cfg.use_pack_options = true
	n.alive = true
	err := eng.open(&n.e, cfg, context.allocator)
	if n.disk.dead {
		node_crashed(n)
		return false
	}
	if err != .None && w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
		world_note(w, "%s engine open hit injected %v; supervisor retries", n.name, err)
		n.alive = false
		_free_partial(n)
		schedule(w, Sim_Event{at = w.now + 200_000_000, kind = .Restart, node = n.idx})
		return false
	}
	if err != .None {
		world_fail(w, "%s engine open failed after restart %d: %v", n.name, n.incarnation, err)
		n.alive = false
		_free_partial(n)
		return false
	}
	n.e_open = true
	if n.disk.dead {
		node_crashed(n)
		return false
	}
	n.identity = eng.identity(&n.e)
	n.durable = eng.durable_tick(&n.e)
	world_note(w, "%s up (incarnation %d, self %s)", n.name, n.incarnation, id_short(n.identity.id))
	infos := eng.space_list(&n.e, context.temp_allocator)
	sort_spaces(infos)
	for sp in infos {
		if oerr := eng.space_open(&n.e, sp.id); oerr != .None {
			if n.disk.dead {
				node_crashed(n)
				return false
			}
			if w.cfg.io_rate > 0 && (oerr == .Io || oerr == .No_Space) {
				n.restart_pending = true
				node_after(n)
				return false
			}
			world_fail(w, "%s space_open %s failed after restart: %v", n.name, id_short(sp.id), oerr)
		}
	}
	node_after(n)
	if n.alive {
		node_remount(w, n)
	}
	return n.alive
}

sort_spaces :: proc(infos: []eng.Space_Info) {
	for i in 1 ..< len(infos) {
		j := i
		for j > 0 && id_less(infos[j].id, infos[j - 1].id) {
			infos[j], infos[j - 1] = infos[j - 1], infos[j]
			j -= 1
		}
	}
}

id_less :: proc(a, b: prim.Id) -> bool {
	for i in 0 ..< 16 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

id_short :: proc(id: prim.Id) -> string {
	h := prim.id_hex(id)
	return fmt.tprintf("%s", string(h[24:32]))
}

@(private = "file")
_free_partial :: proc(n: ^Node) {
	context = n.w.ctx
	n.alive = false
	n.key_open = false
	n.e_open = false
	instance_kill(&n.inst)
}

node_kill :: proc(n: ^Node) {
	w := n.w
	context = w.ctx
	conns_drop_node(w, n)
	node_mounts_drop(w, n)
	n.alive = false
	n.e_open = false
	n.key_open = false
	instance_kill(&n.inst)
	n.e = {}
	n.keyring = {}
}

node_crashed :: proc(n: ^Node) {
	w := n.w
	context = w.ctx
	mode := Crash_Mode.Power if rng_chance(&w.fault_rng, 2, 3) else Crash_Mode.Process
	n.disk.dead = false
	if mode == .Power {
		n.boot += 1
	}
	world_note(w, "%s crashed at disk op %d (%v)", n.name, n.disk.stats.ops, mode)
	w.stats.crashes += 1
	node_kill(n)
	disk_crash(&n.disk, mode, &w.fault_rng)
	model_node_crashed(&w.model, n, mode)
	delay := rng_range(&w.fault_rng, 10, 3000) * 1_000_000
	schedule(w, Sim_Event{at = w.now + delay, kind = .Restart, node = n.idx})
}

node_after :: proc(n: ^Node) {
	if !n.alive {
		return
	}
	if n.disk.dead || n.restart_pending {
		n.restart_pending = false
		node_crashed(n)
		return
	}
	if len(n.disk.events) > 0 && !n.watch_scheduled && n.reg != nil {
		n.watch_scheduled = true
		schedule(n.w, Sim_Event{at = n.w.now + 1_000_000, kind = .Watch, node = n.idx})
	}
	if n.e_open {
		t := eng.durable_tick(&n.e)
		if t > n.durable {
			n.durable = t
			model_durable(&n.w.model, n, t)
		}
	}
}

node_drain :: proc(n: ^Node) -> bool {
	w := n.w
	if !n.alive {
		return false
	}
	did := false
	context = instance_context(&n.inst)
	for i := 0; ; i += 1 {
		if !n.alive {
			return did
		}
		if !loop_ready(&n.inst.loop) && !loop_due(&n.inst.loop) {
			return did
		}
		if i > 100_000 {
			world_fail(w, "%s livelock: loop never settles", n.name)
			return did
		}
		did = true
		w.stats.steps += 1
		prim.loop_step(&n.inst.loop, false)
		node_after(n)
	}
}

@(private = "file")
_next_id :: proc(data: rawptr) -> prim.Id {
	n := (^Node)(data)
	return prim.id_new_with(node_clock(&n.clock), rng_random(&n.ids))
}

@(private = "file")
_on_log :: proc(data: rawptr, level: eng.Log_Level, msg: string) {
	n := (^Node)(data)
	if level >= .Warn {
		world_note(n.w, "%s log %v: %s", n.name, level, msg)
	}
}

@(private = "file")
_on_purge :: proc(data: rawptr, e: ^eng.Engine, req: ^eng.Purge_Request) {
	n := (^Node)(data)
	world_note(n.w, "%s purge %s", n.name, req.provider)
}

@(private = "file")
_on_event :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Event) {
	n := (^Node)(data)
	w := n.w
	if n.disk.dead {
		return
	}
	#partial switch ev.kind {
	case .Durable:
	case .Quarantined:
		append(&w.quarantines, Quarantine{node = n.idx, object = ev.object})
		if w.cfg.byzantine {
			w.stats.detected += 1
			world_note(w, "%s quarantined %s from %s (tampering detected)", n.name, id_short(ev.object), id_short(ev.device))
			return
		}
		world_fail(w, "%s quarantined object %s device %s at %d (equivocation or forged chain)", n.name, id_short(ev.object), id_short(ev.device), ev.length)
	case .Fatal:
		if w.cfg.io_rate > 0 && (ev.err == .Io || ev.err == .No_Space) {
			world_note(w, "%s replication stopped by injected %v; supervisor restarts it", n.name, ev.err)
			n.restart_pending = true
		} else if w.cfg.byzantine && (ev.err == .Forged || ev.err == .Corrupt || ev.err == .Quarantined) {
			w.stats.detected += 1
			world_note(w, "%s rejected tampered data on %s: %v", n.name, id_short(ev.object), ev.err)
		} else {
			world_fail(w, "%s fatal replication error on %s: %v %s", n.name, id_short(ev.object), ev.err, ev.detail)
		}
	case .Failure:
		if n.disk.dead {
		} else if w.cfg.io_rate > 0 && (ev.err == .Io || ev.err == .No_Space) {
			world_note(w, "%s engine failure %v after injected I/O error; supervisor restarts it", n.name, ev.err)
			n.restart_pending = true
		} else {
			world_fail(w, "%s engine failure: %v %s", n.name, ev.err, ev.detail)
		}
	case .Refused:
		world_note(w, "%s refused by relay: %v", n.name, ev.err)
	case .Connected:
		world_note(w, "%s connected %s", n.name, id_short(ev.space))
	case .Disconnected:
		world_note(w, "%s disconnected %s", n.name, id_short(ev.space))
	}
}

relay_start :: proc(rn: ^Relay_Node) -> bool {
	w := rn.w
	rng_init(&rn.rng, w.cfg.seed, 777 + u64(w.stats.relay_crash))
	if !instance_begin(&rn.inst, 15) {
		world_fail(w, "relay could not map its deterministic memory region")
		return false
	}
	context = instance_context(&rn.inst)
	if err := prim.loop_init(&rn.inst.loop); err != .None {
		world_fail(w, "relay loop_init failed")
		instance_kill(&rn.inst)
		return false
	}
	rn.inst.loop_on = true
	prim.loop_set_clock(&rn.inst.loop, node_clock(&rn.clock))
	cfg := osync.relay_config(RELAY_DIR)
	cfg.vfs = disk_vfs(&rn.disk)
	cfg.open = true
	cfg.default_quota = 1 << 30
	cfg.sync_threads = 0
	cfg.kernel_tls = false
	cfg.random = rng_random(&rn.rng)
	cfg.clock = node_clock(&rn.clock)
	if serr := osync.space_authorizer_init(&rn.sauth, cfg.vfs, RELAY_DIR + "/allow", true, cfg.default_quota); serr != .None {
		world_fail(w, "relay authorizer init failed: %v", serr)
		instance_kill(&rn.inst)
		return false
	}
	eng.cap_authorizer_init(&rn.cauth, osync.space_authorizer(&rn.sauth), cfg.default_quota, node_clock(&rn.clock))
	cfg.authorizer = eng.cap_authorizer(&rn.cauth)
	rn.alive = true
	err := osync.relay_init(&rn.r, &rn.inst.loop, cfg)
	if rn.disk.dead {
		relay_crashed(rn)
		return false
	}
	if err != .None {
		world_fail(w, "relay init failed after restart: %v", err)
		rn.alive = false
		instance_kill(&rn.inst)
		return false
	}
	rn.r_on = true
	rn.public = osync.relay_public_key(&rn.r)
	world_note(w, "relay up")
	return true
}

relay_kill :: proc(rn: ^Relay_Node) {
	context = rn.w.ctx
	conns_drop_relay(rn.w)
	rn.alive = false
	rn.r_on = false
	instance_kill(&rn.inst)
	rn.r = {}
	rn.sauth = {}
	rn.cauth = {}
}

relay_crashed :: proc(rn: ^Relay_Node) {
	w := rn.w
	context = w.ctx
	mode := Crash_Mode.Power if rng_chance(&w.fault_rng, 1, 2) else Crash_Mode.Process
	world_note(w, "relay crashed at disk op %d (%v)", rn.disk.stats.ops, mode)
	w.stats.relay_crash += 1
	relay_kill(rn)
	disk_crash(&rn.disk, mode, &w.fault_rng)
	delay := rng_range(&w.fault_rng, 50, 4000) * 1_000_000
	schedule(w, Sim_Event{at = w.now + delay, kind = .Relay_Restart})
}

relay_after :: proc(rn: ^Relay_Node) {
	if rn.alive && rn.disk.dead {
		relay_crashed(rn)
	}
}

relay_drain :: proc(rn: ^Relay_Node) -> bool {
	w := rn.w
	if !rn.alive {
		return false
	}
	did := false
	context = instance_context(&rn.inst)
	for i := 0; ; i += 1 {
		if !rn.alive {
			return did
		}
		if !loop_ready(&rn.inst.loop) && !loop_due(&rn.inst.loop) {
			return did
		}
		if i > 100_000 {
			world_fail(w, "relay livelock: loop never settles")
			return did
		}
		did = true
		w.stats.steps += 1
		prim.loop_step(&rn.inst.loop, false)
		relay_after(rn)
	}
}
