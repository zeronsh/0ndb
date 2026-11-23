package sim

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
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
	rng_init(&n.pack_rng, w.cfg.seed, 13000 + u64(n.idx) * 64 + u64(n.incarnation))
	if iok, iwhy := instance_begin(&n.inst, n.idx); !iok {
		world_fail(w, "%s could not map its deterministic memory region (%d MiB at slot %d): %s", n.name, region_stride() >> 20, n.idx, iwhy)
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
	cfg.fs_exec = fs.Sync_Exec{run = proc(data: rawptr, job: proc(arg: rawptr), done: proc(arg: rawptr), arg: rawptr) {
		job(arg)
		done(arg)
	}}
	cfg.watcher = sim_watcher(n)
	cfg.history_fault = fs.Persist_Fault{data = n, fail = _persist_fail}
	cfg.redact_fault = eng.Redact_Fault{data = n, withhold = _redact_withhold, learned = _redact_learned}
	cfg.embedder = sim_embedder()
	cfg.boot_id = eng.Boot_Source{boot_id = proc(data: rawptr) -> prim.Id {
		return {}
	}}
	cfg.search_options.train_min = w.cfg.train_min
	cfg.search_options.dict_sample_min = w.cfg.dict_sample_min
	cfg.durability = w.cfg.durability
	cfg.kernel_tls = false
	cfg.settle_ms = w.cfg.settle_ms
	cfg.search_full = n.idx % 2 == 0
	cfg.search_hedge_ms = 200
	cfg.search_deadline_ms = 2000
	cfg.pack_options = pack.DEFAULT_OPTIONS
	cfg.pack_options.clock = node_clock(&n.clock)
	cfg.use_pack_options = true
	if w.cfg.promote > 0 {
		cfg.pack_options.promote_size = w.cfg.promote
	}
	if cfg.durability == .Async {
		cfg.pack_options.worker = pack.Worker_Hook{data = n, submit = _pack_submit}
	}
	cfg.storage = w.cfg.storage
	cfg.git_remote = sim_git_remote(n)
	if w.node_cfg != nil {
		w.node_cfg(n, &cfg)
	}
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
	check_derived(n, "open")
	if n.disk.dead {
		node_crashed(n)
		return false
	}
	live_start(n)
	if n.disk.dead {
		node_crashed(n)
		return false
	}
	n.identity = eng.identity(&n.e)
	n.durable = eng.durable_seq(&n.e)
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
	n.observed = 0
	w := n.w
	context = w.ctx
	live_kill(n)
	buffers_drop(w, n)
	watches_node_killed(w, n)
	conns_drop_node(w, n)
	node_mounts_drop(w, n)
	n.alive = false
	n.e_open = false
	n.key_open = false
	instance_kill(&n.inst)
	virtual.arena_destroy(&n.e.temp)
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
	_learned_drop(n)
	world_note(w, "%s crashed at disk op %d (%v)", n.name, n.disk.stats.ops, mode)
	w.stats.crashes += 1
	promos_crashed(w, n)
	node_kill(n)
	disk_crash(&n.disk, mode, &w.fault_rng)
	model_node_crashed(&w.model, n, mode)
	delay := rng_range(&w.fault_rng, 10, 3000) * 1_000_000
	schedule(w, Sim_Event{at = w.now + delay, kind = .Restart, node = n.idx})
}

node_crash_now :: proc(n: ^Node, mode: Crash_Mode, salt: u64) {
	w := n.w
	context = w.ctx
	n.disk.dead = false
	if mode == .Power {
		n.boot += 1
	}
	_learned_drop(n)
	world_note(w, "%s crashed right after returning a message id (%v)", n.name, mode)
	w.stats.crashes += 1
	promos_crashed(w, n)
	node_kill(n)
	r: Rng
	rng_init(&r, w.cfg.seed, 4_000_000 + salt)
	disk_crash(&n.disk, mode, &r)
	model_node_crashed(&w.model, n, mode)
	schedule(w, Sim_Event{at = w.now + 500_000_000, kind = .Restart, node = n.idx})
}

node_after :: proc(n: ^Node) {
	if !n.alive {
		return
	}
	if path, size, runaway := disk_runaway(&n.disk); runaway && !n.w.aborted {
		world_fail(n.w, "%s disk runaway: %s would grow to %d MiB", n.name, path, size >> 20)
		n.w.aborted = true
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
		t := eng.durable_seq(&n.e)
		if t > n.durable {
			n.durable = t
			model_durable(&n.w.model, n, t)
		}
		note_sent(n)
	}
	if len(n.mounts) > 0 {
		context = instance_context(&n.inst)
		check_synced_disk(n.w, n)
	}
}

note_sent :: proc(n: ^Node) {
	w := n.w
	if n.sent == nil {
		n.sent = make(map[string]i64, w.allocator)
	}
	note :: proc(n: ^Node, r: ^osync.Replicator) {
		for _, l in r.locals {
			end := l.cursor + l.inflight
			if end > n.sent[l.path] {
				if d, derr := eng.durable_len(&n.e, l.path); derr == .None && end > d {
					world_fail(n.w, "publish: %s handed bytes up to %d of %s to the relay with only %d durable", n.name, end, l.path, d)
				}
			}
			if prev, ok := n.sent[l.path]; ok {
				if end > prev {
					n.sent[l.path] = end
				}
			} else if end > 0 {
				n.sent[strings.clone(l.path, n.w.allocator)] = end
			}
		}
	}
	for _, sp in n.e.spaces {
		if sp.repl_on {
			note(n, &sp.repl)
		}
	}
	if rv := n.e.approvals.rv; rv != nil && rv.repl_on {
		note(n, &rv.repl)
	}
}

check_sent :: proc(n: ^Node) {
	w := n.w
	if n.sent == nil {
		return
	}
	keys := make([dynamic]string, context.temp_allocator)
	for k in n.sent {
		append(&keys, k)
	}
	slice.sort(keys[:])
	{
		context = instance_context(&n.inst)
		for k in keys {
			sent := n.sent[k]
			got, err := eng.durable_len(&n.e, k)
			if err == .None && got < sent {
				world_fail(w, "publish: %s sent bytes up to %d of %s but recovered only %d after a crash", n.name, sent, k, got)
			}
		}
	}
	node_after(n)
	for k in n.sent {
		delete(k, w.allocator)
	}
	clear(&n.sent)
}

node_drain :: proc(n: ^Node) -> bool {
	w := n.w
	if !n.alive {
		return false
	}
	did := false
	if w.aborted {
		return false
	}
	context = instance_context(&n.inst)
	for i := 0; ; i += 1 {
		if !n.alive {
			return did
		}
		if !loop_ready(&n.inst.loop) && !loop_due(&n.inst.loop) {
			return did
		}
		if i > 100_000 {
			world_fail(w, "%s livelock: its loop kept running at t=%d ms for %d steps without settling; armed timers: %s", n.name, w.now / 1_000_000, i, armed_timers(&n.inst.loop))
			w.aborted = true
			return did
		}
		if memory_runaway(w) {
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
	case .Replica_Redacted:
		sid, known := learned_stream(w, n, ev.space, ev.object, ev.device)
		append(&n.learned, Learned_Redaction{object = ev.object, device = ev.device, from = i64(ev.tick), to = ev.length, seq = eng.pending_seq(e), stream = sid, known = known})
		stat_add(w, STAT_LEARNED)
		if !n.learn_check {
			n.learn_check = true
			schedule(w, Sim_Event{at = w.now, kind = EV_LEARN_CHECK, node = n.idx})
		}
		world_note(w, "%s learned redaction of %s@[%d,%d) in %s", n.name, id_short(ev.device), i64(ev.tick), ev.length, id_short(ev.object))
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
		} else if ev.device == n.identity.id {
			world_fail(w, "%s marked its own stream of %s fatal: %v %s", n.name, id_short(ev.object), ev.err, ev.detail)
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
	case .Relay_Misbehaving:
		if w.cfg.byzantine {
			w.stats.detected += 1
		}
		if ev.device == n.identity.id {
			stat_add(w, STAT_OWN_TAMPER)
		}
		world_note(w, "%s caught the relay misbehaving on %s device %s: %v", n.name, id_short(ev.object), id_short(ev.device), ev.err)
	case .Connected:
		n.connects += 1
		world_note(w, "%s connected %s", n.name, id_short(ev.space))
	case .Disconnected:
		world_note(w, "%s disconnected %s", n.name, id_short(ev.space))
	case .Unavailable, .Available, .Promoted, .Peer_Misbehaving:
		if ev.kind == .Unavailable {
			n.unavailable += 1
		}
		world_note(w, "%s %v %s device %s length %d %v", n.name, ev.kind, id_short(ev.object), id_short(ev.device), ev.length, ev.err)
	}
}

relay_start :: proc(rn: ^Relay_Node) -> bool {
	w := rn.w
	rng_init(&rn.rng, w.cfg.seed, 777 + u64(w.stats.relay_crash))
	if iok, iwhy := instance_begin(&rn.inst, 15); !iok {
		world_fail(w, "relay could not map its deterministic memory region (%d MiB at slot 15): %s", region_stride() >> 20, iwhy)
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
	vfs := disk_vfs(&rn.disk)
	quota := i64(1 << 30)
	if serr := osync.member_authorizer_init(&rn.mauth, vfs, RELAY_DIR + "/members", {}, true, quota, node_clock(&rn.clock)); serr != .None {
		world_fail(w, "relay authorizer init failed: %v", serr)
		instance_kill(&rn.inst)
		return false
	}
	osync.cap_authorizer_init(&rn.cauth, osync.member_authorizer(&rn.mauth), quota, node_clock(&rn.clock))
	rn.cauth.issuer_data = &rn.mauth
	rn.cauth.issuer_ok = proc(data: rawptr, space: prim.Id, issuer: osync.Public_Key) -> bool {
		return osync.member_authorizer_active((^osync.Member_Authorizer)(data), osync.Space_Id(space), issuer)
	}
	rn.alive = true
	prim.random_fill(rng_random(&rn.rng), rn.public[:])
	err: osync.Error
	store_vfs := vfs
	lay := osync.LAYOUT_SECTOR
	group: osync.Group_Commit
	if w.cfg.seed % 2 == 0 {
		opts := pack.DEFAULT_OPTIONS
		opts.clock = node_clock(&rn.clock)
		if w.cfg.promote > 0 {
			opts.promote_size = w.cfg.promote
		}
		if perr := prim.mkdir_all(vfs, RELAY_DIR + "/spaces", 0o700); perr != .None {
			err = .Io
		} else if perr = pack.open(&rn.pk, vfs, RELAY_DIR + "/spaces", opts); perr != .None {
			err = .Io
		} else {
			rn.packed = true
			store_vfs = pack.vfs(&rn.pk)
			lay = osync.LAYOUT_COMPACT
			lay.exact = true
			group = osync.Group_Commit {
				data = &rn.pk,
				begin = proc(data: rawptr) {
					pack.batch_begin((^pack.Pack)(data))
				},
				end = proc(data: rawptr) -> osync.Error {
					return .None if pack.batch_end((^pack.Pack)(data)) == .None else .Io
				},
			}
		}
	}
	if err == .None {
		err = osync.file_store_init(&rn.fs, &rn.inst.loop, store_vfs, RELAY_DIR, 0, lay, group, rng_random(&rn.rng), node_clock(&rn.clock))
	}
	if err == .None && rn.packed {
		rn.fs.pack = &rn.pk
		rn.fs.worker.prepare = proc(data: rawptr) {
			osync.relay_core_prepare(&(^Relay_Node)(data).r)
		}
		rn.fs.worker.prep_data = rn
	}
	store := osync.file_store(&rn.fs)
	if err == .None && rn.packed && w.cfg.seed % 4 == 0 {
		prim.mkdir_all(vfs, RELAY_DIR + "/objects", 0o700)
		rn.objs = osync.Dir_Object_Store{vfs = vfs, root = RELAY_DIR + "/objects"}
		rn.slow = Sim_Objects{inner = osync.dir_object_store(&rn.objs), loop = &rn.inst.loop, slow_ms = 200, fail = env_u64("SIM_OBJ_FAIL", 5)}
		rng_init(&rn.slow.rng, w.cfg.seed, 991 + u64(w.stats.relay_crash))
		tc := osync.Tier_Config{objects = sim_objects(&rn.slow), window_ms = 500, max_ms = 5000, hot = 4096}
		if terr := osync.tier_store_init(&rn.ts, &rn.inst.loop, store, tc, node_clock(&rn.clock)); terr != .None {
			err = terr
		} else {
			rn.tiered = true
			store = osync.tier_store(&rn.ts)
			osync.tier_store_sweep(&rn.ts, _relay_spaces(vfs))
		}
	}
	if err == .None {
		cc := osync.relay_core_config()
		cc.storage = store
		cc.authorizer = osync.cap_authorizer(&rn.cauth)
		cc.clock = node_clock(&rn.clock)
		cc.wake = _relay_wake
		cc.wake_data = rn
		cc.on_redacted_in = _relay_redacted_in
		cc.redacted_in_data = rn
		err = osync.relay_core_init(&rn.r, cc)
	}
	if err == .None {
		osync.member_authorizer_set_storage(&rn.mauth, rn.r.store)
	}
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
	world_note(w, "relay up")
	rn.red_check = true
	rn.fills_seen = 0
	return true
}

@(private = "file")
_relay_spaces :: proc(vfs: prim.Vfs) -> []osync.Space_Id {
	ids := make([dynamic]osync.Space_Id, context.temp_allocator)
	d: prim.Dir
	if prim.dir_open(vfs, &d, RELAY_DIR + "/spaces", context.temp_allocator) != .None {
		return nil
	}
	defer prim.dir_close(vfs, &d)
	for {
		e, more, derr := prim.dir_next(vfs, &d)
		if !more || derr != .None {
			break
		}
		if id, ok := prim.id_parse(e.name); ok {
			append(&ids, osync.Space_Id(id))
		}
	}
	return ids[:]
}

relay_kill :: proc(rn: ^Relay_Node) {
	context = rn.w.ctx
	conns_drop_relay(rn.w)
	rn.alive = false
	rn.r_on = false
	instance_kill(&rn.inst)
	stat_add(rn.w, STAT_RELAY_REDACTED_IN, rn.r.stats.redacted_in)
	stat_add(rn.w, STAT_RELAY_REFUSED_IN, rn.r.stats.refused_in)
	rn.r = {}
	rn.fs = {}
	rn.pk = {}
	rn.packed = false
	stat_add(rn.w, STAT_TIER_EVICTIONS, rn.ts.evictions)
	stat_add(rn.w, STAT_TIER_COLD_READS, rn.ts.cold_reads)
	stat_add(rn.w, STAT_TIER_THAWS, rn.ts.thaws)
	stat_add(rn.w, STAT_TIER_PARKS, rn.ts.parks)
	stat_add(rn.w, STAT_TIER_SLOW_READS, rn.slow.reads)
	stat_add(rn.w, STAT_TIER_FAILED_READS, rn.slow.failed)
	rn.ts = {}
	rn.objs = {}
	rn.slow = {}
	rn.tiered = false
	rn.wake = 0
	rn.mauth = {}
	rn.cauth = {}
}

@(private = "file")
_relay_wake :: proc(data: rawptr) {
	rn := (^Relay_Node)(data)
	if rn.wake == 0 {
		rn.wake = prim.timer(&rn.inst.loop, 0, rn, _relay_woken)
	}
}

@(private = "file")
_relay_woken :: proc(l: ^prim.Loop, data: rawptr) {
	rn := (^Relay_Node)(data)
	rn.wake = 0
	osync.relay_core_resume(&rn.r)
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
	if rn.alive && rn.r_on && (rn.r.stats.fills != rn.fills_seen || rn.red_check) {
		rn.fills_seen = rn.r.stats.fills
		rn.red_check = false
		context = instance_context(&rn.inst)
		bad := make([dynamic]osync.Redaction_Violation, context.temp_allocator)
		osync.relay_core_redactions_held(&rn.r, &bad)
		for v in bad {
			sid := v.stream
			world_fail(rn.w, "relay redaction: relay stores record %x@%d inside a recorded redaction without its redacted form", sid[:4], v.off)
		}
	}
	if rn.alive {
		free_all(region_allocator(&rn.inst.temp))
	}
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

@(private = "file")
_pack_submit :: proc(data: rawptr) {
	n := (^Node)(data)
	w := n.w
	delay := i64(0) if rng_chance(&n.pack_rng, 1, 4) else rng_range(&n.pack_rng, 0, 20_000_000)
	schedule(w, Sim_Event{at = w.now + delay, kind = .Pack_Job, node = n.idx, gen = u64(n.incarnation)})
}

pack_job_event :: proc(w: ^World, n: ^Node, gen: u64) {
	if !n.alive || !n.e_open || u64(n.incarnation) != gen {
		return
	}
	context = instance_context(&n.inst)
	pack.worker_run(&n.e.pk)
}

durability_of :: proc(s: string) -> (m: eng.Durability, ok: bool) {
	switch s {
	case "async":
		return .Async, true
	case "deferred":
		return .Deferred, true
	}
	return
}

check_derived :: proc(n: ^Node, at: string) {
	w := n.w
	notes, err := eng.verify_derived(&n.e, context.temp_allocator)
	if n.disk.dead {
		return
	}
	if err != .None {
		world_note(w, "%s derived check at %s skipped: %v", n.name, at, err)
		return
	}
	for s in notes {
		world_fail(w, "derived: %s at %s (incarnation %d): %s", n.name, at, n.incarnation, s)
	}
}

STAT_TIER_EVICTIONS: Stat
STAT_TIER_COLD_READS: Stat
STAT_TIER_THAWS: Stat
STAT_RELAY_REDACTED_IN: Stat
STAT_RELAY_REFUSED_IN: Stat
STAT_TIER_PARKS: Stat
STAT_TIER_SLOW_READS: Stat
STAT_TIER_FAILED_READS: Stat
STAT_PERSIST_FAULTS: Stat
STAT_REDACT_FAULTS: Stat
EV_LEARN_CHECK: Ev_Kind

_redact_learned :: proc(data: rawptr, space, object, device: prim.Id, from, to: i64, applied, pending: bool) {
	n := (^Node)(data)
	if applied && pending {
		world_fail(n.w, "device redaction: %s reported a redaction learned while it is only queued, its bytes still live in the replica", n.name)
	}
	if !applied && pending {
		sid, known := learned_stream(n.w, n, space, object, device)
		append(&n.held, Learned_Redaction{object = object, device = device, from = from, to = to, stream = sid, known = known})
	}
}

_redact_withhold :: proc(data: rawptr) -> bool {
	n := (^Node)(data)
	w := n.w
	if !w.cfg.redact_fault || n.disk.dead || n.redact_faulted || !rng_chance(&w.fault_rng, 1, 2) {
		return false
	}
	n.redact_faulted = true
	if n.disk.crash_at == 0 {
		n.disk.crash_at = n.disk.stats.ops + 1 + u64(rng_range(&w.fault_rng, 0, 200))
	}
	stat_add(w, STAT_REDACT_FAULTS)
	world_note(w, "%s keys withheld while applying a learned redaction; crash armed at disk op %d", n.name, n.disk.crash_at)
	return true
}
STAT_GHOST_TAILS: Stat

_persist_fail :: proc(data: rawptr) -> bool {
	n := (^Node)(data)
	if n.persist_fail <= 0 {
		return false
	}
	n.persist_fail -= 1
	stat_add(n.w, STAT_PERSIST_FAULTS)
	world_note(n.w, "%s history persist fails (injected)", n.name)
	return true
}

STAT_OWN_TAMPER: Stat
STAT_LENGTH_LIES: Stat

@(init)
_node_stats :: proc "contextless" () {
	register_restarted(10, proc(w: ^World, n: ^Node) {
		check_sent(n)
	})
	register_collect(10, proc(w: ^World, res: ^Run_Result) {
		res.stats.extra[int(STAT_TIER_EVICTIONS)] += w.relay.ts.evictions
		res.stats.extra[int(STAT_TIER_COLD_READS)] += w.relay.ts.cold_reads
		res.stats.extra[int(STAT_TIER_THAWS)] += w.relay.ts.thaws
		res.stats.extra[int(STAT_RELAY_REDACTED_IN)] += w.relay.r.stats.redacted_in
		res.stats.extra[int(STAT_RELAY_REFUSED_IN)] += w.relay.r.stats.refused_in
		res.stats.extra[int(STAT_TIER_PARKS)] += w.relay.ts.parks
		res.stats.extra[int(STAT_TIER_SLOW_READS)] += w.relay.slow.reads
		res.stats.extra[int(STAT_TIER_FAILED_READS)] += w.relay.slow.failed
		for n in w.nodes {
			res.stats.extra[int(STAT_GHOST_TAILS)] += n.disk.stats.ghosts
		}
	})
	register_stat_line(40)
	register_stat_line(45)
	STAT_PERSIST_FAULTS = register_stat(45, 0, "history_persist_faults")
	STAT_REDACT_FAULTS = register_stat(45, 2, "redact_key_faults")
	EV_LEARN_CHECK = register_event(proc(w: ^World, ev: ^Sim_Event) {
		n := w.nodes[ev.node]
		n.learn_check = false
		if n.alive && n.e_open && !n.disk.dead {
			check_learned_redactions(w, n)
		}
	})
	STAT_GHOST_TAILS = register_stat(45, 1, "ghost_tails")
	STAT_TIER_EVICTIONS = register_stat(40, 0, "relay_evictions")
	STAT_TIER_COLD_READS = register_stat(40, 1, "relay_cold_reads")
	register_stat_line(48)
	STAT_RELAY_REDACTED_IN = register_stat(48, 0, "relay_redacted_in")
	STAT_RELAY_REFUSED_IN = register_stat(48, 1, "relay_refused_in")
	STAT_TIER_THAWS = register_stat(40, 2, "relay_thaws")
	STAT_TIER_SLOW_READS = register_stat(40, 3, "object_reads")
	STAT_TIER_FAILED_READS = register_stat(40, 4, "object_read_faults")
	STAT_TIER_PARKS = register_stat(40, 5, "relay_thaws_parked")
	register_stat_line(45)
	STAT_OWN_TAMPER = register_stat(45, 0, "own_tamper_caught")
	STAT_LENGTH_LIES = register_stat(45, 1, "length_lies")
}

@(private = "file")
_learned_drop :: proc(n: ^Node) {
	k := 0
	for l in n.learned {
		if l.seq <= n.durable {
			n.learned[k] = l
			k += 1
		}
	}
	resize(&n.learned, k)
	clear(&n.held)
}

@(private = "file")
_relay_redacted_in :: proc(data: rawptr, sender: osync.Device_Id, space: osync.Space_Id, id: osync.Stream_Id, from, to: i64) {
	rn := (^Relay_Node)(data)
	w := rn.w
	for n in w.nodes {
		if n.identity.id != prim.Id(sender) {
			continue
		}
		for l in n.learned {
			if l.known && l.stream == id && l.from < to && l.to > from {
				sid := id
				world_fail(w, "device redaction: %s sent bytes of %x [%d,%d) to the relay after learning of its redaction", n.name, sid[:4], from, to)
			}
		}
		for l in n.held {
			if l.known && l.stream == id && l.from < to && l.to > from {
				sid := id
				world_fail(w, "device redaction: %s sent bytes of %x [%d,%d) to the relay while their redaction was queued", n.name, sid[:4], from, to)
			}
		}
	}
}
