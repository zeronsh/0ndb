package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

Run_Result :: struct {
	seed:     u64,
	op_events:    int,
	fault_events: int,
	failures: [dynamic]string,
	trace:    u64,
	stats:    World_Stats,
	sim_ns:   i64,
	wall_ns:  i64,
	disk_ops: u64,
}

default_config :: proc(seed: u64) -> Config {
	r: Rng
	rng_init(&r, seed, 99)
	return Config {
		seed = seed,
		nodes = 2 + rng_int(&r, 3),
		spaces = 1 + rng_int(&r, 2),
		ops = 150 + rng_int(&r, 250),
		op_gap_ms = 5 + rng_range(&r, 0, 80),
		crash_rate = rng_int(&r, 4),
		fault_rate = rng_int(&r, 4),
		max_delay = rng_range(&r, 5, 2000) * 1_000_000,
		window = 2048 + rng_int(&r, 256 * 1024),
		fault_gap_ms = 2000 + rng_range(&r, 0, 20000),
		io_rate = u64(rng_range(&r, 200, 5000)) if rng_chance(&r, 1, 5) else 0,
		byzantine = rng_chance(&r, 1, 6),
		train_min = 16 + rng_int(&r, 48),
		bulk = rng_chance(&r, 1, 8),
		dict_sample_min = 64 + rng_int(&r, 960),
		settle_ms = 200 + rng_range(&r, 0, 1500),
		trace_limit = 4000,
		storage = .Device if rng_chance(&r, 1, 3) else .Device_Until_Run if rng_chance(&r, 1, 3) else .Auto,
	}
}

drain_all :: proc(w: ^World) {
	for round := 0; ; round += 1 {
		any := false
		for n in w.nodes {
			if node_drain(n) {
				any = true
			}
		}
		if relay_drain(&w.relay) {
			any = true
		}
		if !any {
			return
		}
		if round > 1_000_000 {
			world_fail(w, "livelock: world never settles at t=%d", w.now)
			return
		}
	}
}

next_time :: proc(w: ^World) -> (t: i64, ok: bool) {
	if len(w.queue) > 0 {
		t = w.queue[0].at
		ok = true
	}
	for n in w.nodes {
		if !n.alive {
			continue
		}
		if at, has := loop_deadline(&n.inst.loop); has {
			g := at - n.clock.mono_off
			if !ok || g < t {
				t = g
				ok = true
			}
		}
	}
	if w.relay.alive {
		if at, has := loop_deadline(&w.relay.inst.loop); has {
			g := at - w.relay.clock.mono_off
			if !ok || g < t {
				t = g
				ok = true
			}
		}
	}
	return
}

run_until :: proc(w: ^World, limit: i64, stop_when_idle: bool) -> (idle: bool) {
	for w.phase != .Workload || len(w.failures) < 20 {
		if w.aborted {
			return false
		}
		if memory_runaway(w) {
			return false
		}
		free_all(w.ctx.temp_allocator)
		drain_all(w)
		t, ok := next_time(w)
		if !ok {
			return true
		}
		if t > limit {
			w.now = max(w.now, limit)
			return false
		}
		if t > w.now {
			w.now = t
		}
		for len(w.queue) > 0 && w.queue[0].at <= w.now {
			ev := pop_event(w)
			w.stats.events += 1
			if trace_events {
				cid: u64 = ev.conn.id if ev.conn != nil else 0
				fmt.eprintf("ev %d t=%d k=%v node=%d conn=%d gen=%d len=%d h=%x arg=%d\n", w.stats.events, ev.at, ev.kind, ev.node, cid, ev.gen, len(ev.bytes), mix_bytes(0, ev.bytes), ev.arg)
				if trace_bytes_at == w.stats.events {
					fmt.eprintf("evbytes %d node=%s %x\n", w.stats.events, ev.conn.node.name if ev.conn != nil else "-", ev.bytes)
				}
			}
			handle_event(w, &ev)
			delete(ev.bytes, w.allocator)
			drain_all(w)
			if w.phase == .Workload && len(w.failures) >= 20 {
				return false
			}
		}
	}
	return false
}

handle_event :: proc(w: ^World, ev: ^Sim_Event) {
	switch ev.kind {
	case .Op:
		if ev.arg == 1 {
			deliver_shares(w)
			return
		}
		if w.phase == .Workload {
			k := w.op_index
			w.op_index += 1
			if filter_keeps(&w.cfg.keep_ops, k) {
				rng_init(&w.rng, w.cfg.seed, 1_000_000 + u64(k))
				w.cur_op = k
				workload_step(w)
			}
			w.cfg.ops -= 1
			if w.cfg.ops > 0 {
				gap := rng_range(&w.sched_rng, 0, 2 * w.cfg.op_gap_ms) * 1_000_000 + rng_range(&w.sched_rng, 0, 999_999)
				schedule(w, Sim_Event{at = w.now + gap, kind = .Op})
			}
		}
	case .Connect, .To_Relay, .To_Node, .Fin_To_Node, .Writable_Node, .Writable_Relay:
		net_event(w, ev)
	case .Reset:
	case .Fault:
		if w.phase == .Workload {
			k := w.fault_index
			w.fault_index += 1
			if filter_keeps(&w.cfg.keep_faults, k) {
				r := rng_fork(&w.sched_rng, 0)
				rng_init(&r, w.cfg.seed, 2_000_000 + u64(k))
				w.cur_fault = k
				inject_fault(w, &r)
			}
			gap := rng_range(&w.sched_rng, 500, w.cfg.fault_gap_ms) * 1_000_000
			schedule(w, Sim_Event{at = w.now + gap, kind = .Fault})
		}
	case .Restart:
		n := w.nodes[ev.node]
		if !n.alive {
			if node_start(n) {
				model_after_restart(&w.model, n)
				requeue_shares(w, n)
			}
		}
	case .Relay_Restart:
		if !w.relay.alive {
			relay_start(&w.relay)
		}
	case .Watch:
		watch_event(w, w.nodes[ev.node])
	case .Git_Fetch:
		remote_event(w, ev)
	case .Heal:
		n := w.nodes[ev.node]
		if n.partitioned {
			n.partitioned = false
			world_note(w, "%s partition healed", n.name)
		}
	}
}

requeue_shares :: proc(w: ^World, n: ^Node) {
	m := &w.model
	for ps in m.accepted {
		if ps.to == n.idx {
			append(&m.shares, ps)
		}
	}
	if len(m.shares) > 0 {
		schedule(w, Sim_Event{at = w.now + 1_000_000, kind = .Op, arg = 1})
	}
}

inject_fault :: proc(w: ^World, r: ^Rng) {
	weights := [?]int{
		w.cfg.crash_rate * 3,
		w.cfg.crash_rate * 2,
		w.cfg.crash_rate,
		w.cfg.fault_rate * 3,
		w.cfg.fault_rate * 2,
		w.cfg.fault_rate * 2,
		1,
	}
	k := rng_pick(r, weights[:])
	n := w.nodes[rng_int(r, len(w.nodes))]
	switch k {
	case 0:
		if n.alive {
			n.disk.crash_at = n.disk.stats.ops + 1 + u64(rng_range(r, 0, 400))
			world_note(w, "%s armed crash at disk op %d", n.name, n.disk.crash_at)
		}
	case 1:
		if n.alive {
			node_crashed(n)
		}
	case 2:
		if w.relay.alive {
			if rng_chance(r, 1, 2) {
				w.relay.disk.crash_at = w.relay.disk.stats.ops + 1 + u64(rng_range(r, 0, 200))
			} else {
				relay_crashed(&w.relay)
			}
		}
	case 3:
		if !n.partitioned {
			n.partitioned = true
			w.stats.partitions += 1
			world_note(w, "%s partitioned", n.name)
			for c in n.conns {
				conn_reset(c, true)
			}
			schedule(w, Sim_Event{at = w.now + rng_range(r, 100, 8000) * 1_000_000, kind = .Heal, node = n.idx})
		}
	case 4:
		for c in n.conns {
			if c.state == .Up && rng_chance(r, 1, 2) {
				w.stats.resets += 1
				world_note(w, "%s conn %d reset", n.name, c.id)
				conn_reset(c, true)
			}
		}
	case 5:
		jump := rng_range(r, -3_600_000, 3_600_000) * 1_000_000
		n.clock.wall_off += jump
		w.stats.jumps += 1
		world_note(w, "%s wall clock jumps %d ms", n.name, jump / 1_000_000)
	case 6:
		if n.alive {
			n.disk.fail_sync = 0
		}
	}
}

run_seed :: proc(seed: u64, verbose := false, images: ^Disk_Images = nil, label := "first") -> (res: Run_Result) {
	cfg := default_config(seed)
	cfg.verbose = verbose
	cfg.disabled = env_disabled()
	leak_sites = env_u64("SIM_LEAK_SITES", 0) != 0
	trace_events = env_u64("SIM_TRACE_EVENTS", 0) != 0
	trace_bytes_at = env_u64("SIM_TRACE_BYTES_AT", 0)
	cfg.share_access = {.Read} if env_u64("SIM_SHARE_READONLY", 0) != 0 else {}
	cfg.io_rate = env_u64("SIM_IO", cfg.io_rate)
	cfg.drain_wall_s = int(env_u64("SIM_DRAIN_WALL", 30))
	region_configure(env_u64("SIM_REGION_MB", 256), env_u64("SIM_TEMP_MB", 96))
	cfg.rss_max = env_u64("SIM_RSS_MAX", 1500)
	cfg.byzantine = env_u64("SIM_BYZANTINE", 1 if cfg.byzantine else 0) != 0
	if v, ok := os.lookup_env("SIM_STORAGE", context.temp_allocator); ok {
		if mode, mok := storage_mode_of(v); mok {
			cfg.storage = mode
		}
	}
	cfg.keep_ops = filter_parse("SIM_KEEP_OPS")
	cfg.keep_faults = filter_parse("SIM_KEEP_FAULTS")
	if f, ok := os.lookup_env("SIM_FAULTS", context.temp_allocator); ok && f == "0" {
		cfg.crash_rate = 0
		cfg.fault_rate = 0
	}
	res.seed = seed
	res.failures = make([dynamic]string, runtime.heap_allocator())
	start := time.tick_now()
	w := new(World, runtime.heap_allocator())
	world_init(w, cfg)
	defer {
		world_destroy(w)
		free(w, runtime.heap_allocator())
	}
	world_note(w, "seed %d nodes=%d spaces=%d ops=%d crash=%d fault=%d window=%d settle=%d io=%d byzantine=%v bulk=%v storage=%v", seed, cfg.nodes, cfg.spaces, cfg.ops, cfg.crash_rate, cfg.fault_rate, cfg.window, cfg.settle_ms, cfg.io_rate, cfg.byzantine, cfg.bulk, cfg.storage)
	ok := relay_start(&w.relay)
	for n in w.nodes {
		ok = ok && node_start(n)
	}
	if ok {
		ok = setup_spaces(w)
	}
	if ok && env_u64("SIM_BULK", 1 if cfg.bulk else 0) != 0 {
		setup_bulk(w)
	}
	if ok {
		run_until(w, w.now + 2_000_000_000, true)
		for n in w.nodes {
			n.disk.failing = true
		}
		schedule(w, Sim_Event{at = w.now + 1_000_000, kind = .Op})
		if cfg.crash_rate + cfg.fault_rate > 0 {
			schedule(w, Sim_Event{at = w.now + rng_range(&w.fault_rng, 10, 1000) * 1_000_000, kind = .Fault})
		}
		for w.cfg.ops > 0 && len(w.failures) == 0 {
			if run_until(w, w.now + 1_000_000_000, false) {
				break
			}
		}
		finish(w)
	}
	res.trace = w.trace
	res.stats = w.stats
	res.op_events = w.op_index
	res.fault_events = w.fault_index
	res.sim_ns = w.now
	for n in w.nodes {
		res.stats.io_errors += n.disk.stats.injected
		res.disk_ops += n.disk.stats.ops
		res.trace = mix64(res.trace, disk_digest(&n.disk))
		res.trace = mix64(res.trace, n.disk.trace)
	}
	res.disk_ops += w.relay.disk.stats.ops
	res.trace = mix64(res.trace, disk_digest(&w.relay.disk))
	if images != nil {
		disk_images_take(w, images, label)
	}
	if verbose {
		for d in world_disks(w) {
			files := make([dynamic]Disk_File, context.temp_allocator)
			disk_walk(d, &files)
			fmt.eprintf("disk %s trace=%x digest=%x\n", d.name, d.trace, disk_digest(d))
			for f in files {
				fmt.eprintf("  file %s %d %x\n", f.path, len(f.data), mix_bytes(0, f.data))
			}
		}
	}
	for f in w.failures {
		append(&res.failures, fmt.aprintf("%s", f, allocator = runtime.heap_allocator()))
	}
	if len(w.failures) > 0 && !verbose {
		lo := max(0, len(w.log) - 60)
		for s in w.log[lo:] {
			append(&res.failures, fmt.aprintf("  trace: %s", s, allocator = runtime.heap_allocator()))
		}
	}
	res.wall_ns = i64(time.tick_since(start))
	delete(cfg.keep_ops.keep)
	delete(cfg.keep_faults.keep)
	return
}

finish :: proc(w: ^World) {
	if w.aborted {
		return
	}
	w.phase = .Quiesce
	world_note(w, "quiesce")
	for n in w.nodes {
		n.disk.crash_at = 0
		n.disk.fail_sync = 0
		n.partitioned = false
	}
	w.relay.disk.crash_at = 0
	for n in w.nodes {
		n.disk.failing = false
	}
	byzantine_flush(w)
	if !w.relay.alive {
		relay_start(&w.relay)
	}
	for n in w.nodes {
		if !n.alive && len(w.failures) == 0 {
			if node_start(n) {
				model_after_restart(&w.model, n)
			}
		}
	}
	deliver_shares(w)
	for round in 0 ..< 12 {
		idle := run_until(w, w.now + 120_000_000_000, true)
		if len(w.failures) > 0 {
			return
		}
		w.phase = .Check
		if check_convergence(w, false) && idle {
			break
		}
		_ = round
	}
	run_until(w, w.now + 120_000_000_000, true)
	if len(w.failures) > 0 {
		return
	}
	if w.cfg.verbose {
		for _, oi in w.model.objs {
			if obj_exists(&w.model, oi) && w.model.objs[oi].kind != .Convo {
				rs := readers_of(w, oi)
				if len(rs) > 0 {
					d := digest_object(w, w.nodes[rs[0]], oi)
					world_note(w, "final %v %s on %s:\n%s", w.model.objs[oi].kind, id_short(w.model.objs[oi].o.id), w.nodes[rs[0]].name, d.text)
					delete(d.text, w.allocator)
				}
			}
		}
	}
	if !check_convergence(w, true) && w.cfg.verbose {
		dump_replication(w)
	}
	check_redaction(w)
	cipher_scan_relay(w)
	cipher_resolve(w)
	check_relay_redaction(w)
	check_relay_plaintext(w)
	check_relay_storage(w)
	check_mounts(w)
	if w.aborted {
		return
	}
	idle := run_until(w, w.now + 600_000_000_000, true)
	if !idle {
		world_fail(w, "idle: world never became idle (timers keep firing)")
	}
	check_live_reads(w)
	check_idle(w)
	if len(w.failures) == 0 && !w.aborted && w.cfg.storage == .Auto && !w.cfg.byzantine && env_u64("SIM_MOVE", 1) != 0 {
		check_move(w)
	}
	if len(w.failures) == 0 && !w.aborted {
		check_close(w)
	}
}

check_close :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		live_close(n)
		context = instance_context(&n.inst)
		err := eng.close(&n.e)
		n.e_open = false
		if n.disk.dead {
			continue
		}
		if err != .None {
			world_fail(w, "%s close failed: %v", n.name, err)
		}
		n.key_open = false
		prim.loop_destroy(&n.inst.loop)
		n.inst.loop_on = false
		osync.file_keyring_close(&n.keyring)
		if live, bytes := instance_leaks(&n.inst); live > 0 {
			world_fail(w, "leak: %s holds %d allocations (%d bytes) after a clean close", n.name, live, bytes)
			if n.inst.main.sites != nil {
				for _, loc in n.inst.main.sites^ {
					world_note(w, "  leaked from %s:%d %s", loc.file_path, loc.line, loc.procedure)
				}
			}
		}
		if fds := disk_open_fds(&n.disk); fds > 0 {
			world_fail(w, "leak: %s holds %d open files after a clean close", n.name, fds)
		}
	}
}

env_u64 :: proc(name: string, def: u64) -> u64 {
	v, ok := os.lookup_env(name, context.temp_allocator)
	if !ok || len(v) == 0 {
		return def
	}
	x, pok := strconv.parse_u64(v)
	if !pok {
		return def
	}
	return x
}

env_disabled :: proc() -> (out: bit_set[Op_Kind]) {
	v, ok := os.lookup_env("SIM_DISABLE", context.temp_allocator)
	if !ok {
		return
	}
	for part in strings.split(v, ",", context.temp_allocator) {
		for k in Op_Kind {
			if strings.equal_fold(fmt.tprintf("%v", k), strings.trim_space(part)) {
				out += {k}
			}
		}
		if strings.trim_space(part) == "redact" {
			out += {.Redact_Msg, .Redact_Text, .Redact_Map}
		}
	}
	return
}

trace_events := false
trace_bytes_at: u64

FIXED_SEEDS :: [?]u64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

report :: proc(t: ^testing.T, res: ^Run_Result) -> bool {
	if len(res.failures) == 0 {
		return true
	}
	if env_u64("SIM_QUIET", 0) != 0 {
		return false
	}
	fmt.eprintf("sim: seed %d FAILED (%d failures). Reproduce: SIM_SEED=%d odin test tests/sim -o:speed\n", res.seed, len(res.failures), res.seed)
	for f in res.failures {
		fmt.eprintf("  %s\n", f)
	}
	return false
}

free_result :: proc(res: ^Run_Result) {
	for f in res.failures {
		delete(f, runtime.heap_allocator())
	}
	delete(res.failures)
}

@(test)
simulate :: proc(t: ^testing.T) {
	hermetic_env()
	verbose := env_u64("SIM_VERBOSE", 0) != 0
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 && env_u64("SIM_SHRINK", 0) != 0 {
		seed, _ := strconv.parse_u64(s)
		testing.expect(t, shrink(seed))
		return
	}
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		seed, _ := strconv.parse_u64(s)
		replay := env_u64("SIM_REPLAY", 1) != 0
		ia, ib: Disk_Images
		a := run_seed(seed, verbose, &ia if replay else nil, "first")
		ok1 := report(t, &a)
		if replay {
			b := run_seed(seed, false, &ib, "second")
			diffs := make([dynamic]string, runtime.heap_allocator())
			same := disk_images_compare(&ia, &ib, &diffs)
			if a.trace != b.trace || !same {
				msg := fmt.aprintf("determinism: seed %d is NOT deterministic: two runs in one process differ (trace %x vs %x, disks %s)", seed, a.trace, b.trace, "identical" if same else "differ", allocator = runtime.heap_allocator())
				fmt.eprintf("sim: seed %d FAILED (%s). Reproduce: SIM_SEED=%d odin test tests/sim -o:speed\n", seed, msg, seed)
				for d in diffs {
					fmt.eprintf("  %s\n", d)
				}
				inject_at(&a.failures, 0, msg)
				for d, k in diffs {
					inject_at(&a.failures, k + 1, d)
				}
				ok1 = false
			} else {
				for d in diffs {
					delete(d, runtime.heap_allocator())
				}
			}
			delete(diffs)
			disk_images_free(&ia)
			disk_images_free(&ib)
			free_result(&b)
		}
		if fd := env_u64("SIM_STATS_FD", 0); fd > 0 {
			st := Wire_Stats{stats = a.stats, disk_ops = a.disk_ops, wall_ns = a.wall_ns, sim_ns = a.sim_ns, ops = a.op_events, faults = a.fault_events}
			if len(a.failures) > 0 {
				pick := a.failures[0]
				if want, wok := os.lookup_env("SIM_MATCH", context.temp_allocator); wok && len(want) > 0 {
					pick = ""
					for f in a.failures {
						if strings.contains(f, want) && !strings.has_prefix(strings.trim_space(f), "trace:") {
							pick = f
							break
						}
					}
				}
				if len(pick) > 0 {
					sg := failure_signature(pick)
					st.sig_len = copy(st.sig[:], sg)
				}
				line := a.failures[0]
				if nl := strings.index_byte(line, '\n'); nl >= 0 {
					line = line[:nl]
				}
				st.first_len = copy(st.first[:], line)
			}
			b := transmute([size_of(Wire_Stats)]u8)st
			os_stats_write(fd, b[:])
		} else {
			print_stats(&a)
		}
		testing.expect(t, ok1)
		free_result(&a)
		return
	}
	count := env_u64("SIM_SEEDS", 0)
	seeds := make([dynamic]u64, runtime.heap_allocator())
	defer delete(seeds)
	if count > 0 {
		base := env_u64("SIM_BASE", u64(time.now()._nsec))
		fmt.eprintf("sim: %d random seeds from SIM_BASE=%d\n", count, base)
		x := base
		for _ in 0 ..< count {
			append(&seeds, splitmix(&x) >> 16)
		}
	} else {
		for s in FIXED_SEEDS {
			append(&seeds, s)
		}
	}
	failed := make([dynamic]u64, runtime.heap_allocator())
	defer delete(failed)
	firsts := make([dynamic]string, runtime.heap_allocator())
	defer {
		for f in firsts {
			delete(f, runtime.heap_allocator())
		}
		delete(firsts)
	}
	total: Run_Result
	start := time.tick_now()
	every := max(env_u64("SIM_REPLAY_EVERY", 1), 1)
	for seed, i in seeds {
		replay := count == 0 || u64(i) % every == 0
		st, ok, why := run_child(seed, replay)
		if !ok {
			fmt.eprintf("sim: seed %d FAILED (%s). Reproduce: SIM_SEED=%d odin test tests/sim -o:speed\n", seed, why, seed)
			append(&failed, seed)
			first := string(st.first[:st.first_len]) if st.first_len > 0 else why
			append(&firsts, fmt.aprintf("%d -> %s", seed, first, allocator = runtime.heap_allocator()))
		}
		total.stats.events += st.stats.events
		total.stats.steps += st.stats.steps
		total.stats.ops += st.stats.ops
		total.stats.crashes += st.stats.crashes
		total.stats.relay_crash += st.stats.relay_crash
		total.stats.resets += st.stats.resets
		total.stats.partitions += st.stats.partitions
		total.stats.engine_close += st.stats.engine_close
		total.stats.tampered += st.stats.tampered
		total.stats.detected += st.stats.detected
		total.stats.io_errors += st.stats.io_errors
		total.stats.stalls += st.stats.stalls
		total.stats.conflict_pairs += st.stats.conflict_pairs
		total.stats.live_reads += st.stats.live_reads
		total.stats.live_waited += st.stats.live_waited
		total.stats.live_data += st.stats.live_data
		total.stats.live_absent += st.stats.live_absent
		total.stats.live_quarantined += st.stats.live_quarantined
		total.stats.live_closed += st.stats.live_closed
		total.stats.live_dropped += st.stats.live_dropped
		total.stats.live_wait_ms = max(total.stats.live_wait_ms, st.stats.live_wait_ms)
		total.disk_ops += st.disk_ops
		total.sim_ns += st.sim_ns
	}
	total.wall_ns = i64(time.tick_since(start))
	print_stats(&total)
	fmt.eprintf("sim: %d seeds, %d failed %v\n", len(seeds), len(failed), failed[:])
	for f in firsts {
		fmt.eprintf("sim: %s\n", f)
	}
	testing.expect(t, len(failed) == 0)
}

hermetic_env :: proc() {
	_ = os.set_env("HOME", "/home/sim")
	_ = os.set_env("XDG_CONFIG_HOME", "/home/sim/.config")
	_ = os.set_env("GIT_CONFIG_SYSTEM", "/etc/gitconfig")
	_ = os.set_env("GIT_ATTR_NOSYSTEM", "1")
	_ = os.unset_env("GIT_CONFIG_NOSYSTEM")
	_ = os.unset_env("GIT_CONFIG_GLOBAL")
}

Filter :: struct {
	active: bool,
	keep:   [dynamic]int,
}

filter_keeps :: proc(f: ^Filter, k: int) -> bool {
	if !f.active {
		return true
	}
	for x in f.keep {
		if x == k {
			return true
		}
	}
	return false
}

filter_parse :: proc(name: string) -> (f: Filter) {
	v, ok := os.lookup_env(name, context.temp_allocator)
	if !ok {
		return
	}
	f.active = true
	f.keep = make([dynamic]int, runtime.heap_allocator())
	for part in strings.split(v, ",", context.temp_allocator) {
		p := strings.trim_space(part)
		if len(p) == 0 {
			continue
		}
		if i := strings.index_byte(p, '-'); i > 0 {
			lo, _ := strconv.parse_int(p[:i])
			hi, _ := strconv.parse_int(p[i + 1:])
			for x in lo ..= hi {
				append(&f.keep, x)
			}
		} else {
			x, _ := strconv.parse_int(p)
			append(&f.keep, x)
		}
	}
	return
}

Wire_Stats :: struct {
	stats:    World_Stats,
	disk_ops: u64,
	wall_ns:  i64,
	sim_ns:   i64,
	ops:      int,
	faults:   int,
	sig_len:  int,
	sig:      [240]u8,
	first_len: int,
	first:    [240]u8,
}

failure_signature :: proc(f: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(f) {
		c := f[i]
		if c == '<' {
			j := strings.index_byte(f[i:], '>')
			if j > 0 {
				strings.write_string(&b, "<T>")
				i += j + 1
				continue
			}
		}
		if c >= '0' && c <= '9' || c >= 'a' && c <= 'f' && i + 1 < len(f) && _hexrun(f[i:]) >= 8 {
			for i < len(f) && (f[i] >= '0' && f[i] <= '9' || f[i] >= 'a' && f[i] <= 'f') {
				i += 1
			}
			strings.write_byte(&b, '#')
			continue
		}
		if c == '\n' {
			break
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
_hexrun :: proc(s: string) -> int {
	n := 0
	for n < len(s) && (s[n] >= '0' && s[n] <= '9' || s[n] >= 'a' && s[n] <= 'f') {
		n += 1
	}
	return n
}

run_child :: proc(seed: u64, replay: bool, extra: []string = nil) -> (st: Wire_Stats, ok: bool, why: string) {
	env := make([dynamic]string, context.temp_allocator)
	environ, _ := os.environ(context.temp_allocator)
	for kv in environ {
		if strings.has_prefix(kv, "SIM_SEED=") || strings.has_prefix(kv, "SIM_REPLAY=") || strings.has_prefix(kv, "SIM_STATS_FD=") || strings.has_prefix(kv, "SIM_SHRINK") || (len(extra) > 0 && strings.has_prefix(kv, "SIM_KEEP_")) {
			continue
		}
		append(&env, kv)
	}
	append(&env, fmt.tprintf("SIM_SEED=%d", seed))
	append(&env, fmt.tprintf("SIM_REPLAY=%d", 1 if replay else 0))
	for x in extra {
		append(&env, x)
	}
	buf: [size_of(Wire_Stats)]u8
	got, sig, code, err := os_child_run(env[:], buf[:])
	if len(err) > 0 {
		return st, false, err
	}
	if got == len(buf) {
		st = transmute(Wire_Stats)buf
	}
	if sig != 0 {
		return st, false, fmt.tprintf("killed by signal %d", sig)
	}
	if got != len(buf) {
		return st, false, fmt.tprintf("CRASHED before reporting (exit status %d, signal caught by the test runner)", code)
	}
	if code != 0 {
		return st, false, fmt.tprintf("exit status %d", code)
	}
	return st, true, ""
}

print_stats :: proc(r: ^Run_Result) {
	secs := f64(r.wall_ns) / 1e9
	ev := f64(r.stats.events + r.stats.steps + r.disk_ops)
	fmt.eprintf("sim: events=%d loop_steps=%d disk_ops=%d ops=%d crashes=%d relay_crashes=%d resets=%d partitions=%d engine_closes=%d tampered=%d detected=%d io_errors=%d byzantine_stalls=%d expected_conflicts=%d simulated=%.1fs wall=%.2fs throughput=%.0f events/s\n", r.stats.events, r.stats.steps, r.disk_ops, r.stats.ops, r.stats.crashes, r.stats.relay_crash, r.stats.resets, r.stats.partitions, r.stats.engine_close, r.stats.tampered, r.stats.detected, r.stats.io_errors, r.stats.stalls, r.stats.conflict_pairs, f64(r.sim_ns) / 1e9, secs, ev / max(secs, 1e-9))
	fmt.eprintf("sim: interactive_reads=%d waited=%d data=%d absent=%d quarantined=%d closed=%d dropped_by_crash=%d max_wait_ms=%d\n", r.stats.live_reads, r.stats.live_waited, r.stats.live_data, r.stats.live_absent, r.stats.live_quarantined, r.stats.live_closed, r.stats.live_dropped, r.stats.live_wait_ms)
}

@(private = "file")
_ranges :: proc(xs: []int) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(xs) {
		j := i
		for j + 1 < len(xs) && xs[j + 1] == xs[j] + 1 {
			j += 1
		}
		if b.buf != nil && len(b.buf) > 0 {
			strings.write_byte(&b, ',')
		}
		if j > i {
			fmt.sbprintf(&b, "%d-%d", xs[i], xs[j])
		} else {
			fmt.sbprintf(&b, "%d", xs[i])
		}
		i = j + 1
	}
	return strings.to_string(b)
}

Shrinker :: struct {
	seed:   u64,
	sig:    string,
	runs:   int,
	budget: int,
}

@(private = "file")
_try :: proc(s: ^Shrinker, ops: []int, faults: []int) -> bool {
	if s.runs >= s.budget {
		return false
	}
	s.runs += 1
	extra := []string{fmt.tprintf("SIM_KEEP_OPS=%s", _ranges(ops)), fmt.tprintf("SIM_KEEP_FAULTS=%s", _ranges(faults)), "SIM_QUIET=1"}
	st, ok, why := run_child(s.seed, false, extra)
	if ok {
		return false
	}
	if st.sig_len == 0 && got_stats(st) {
		return false
	}
	sig := string(st.sig[:st.sig_len]) if st.sig_len > 0 else why
	return sig == s.sig
}

@(private = "file")
_ddmin :: proc(s: ^Shrinker, set: ^[dynamic]int, other: []int, is_ops: bool) {
	n := 2
	for len(set) >= 2 && s.runs < s.budget {
		chunk := (len(set) + n - 1) / n
		reduced := false
		for start := 0; start < len(set); start += chunk {
			end := min(start + chunk, len(set))
			rest := make([dynamic]int, context.temp_allocator)
			append(&rest, ..set[:start])
			append(&rest, ..set[end:])
			ok := _try(s, rest[:], other) if is_ops else _try(s, other, rest[:])
			if ok {
				clear(set)
				append(set, ..rest[:])
				n = max(n - 1, 2)
				reduced = true
				fmt.eprintf("sim: shrink %s -> %d still fails (%d runs)\n", "ops" if is_ops else "faults", len(set), s.runs)
				break
			}
		}
		if !reduced {
			if n >= len(set) {
				break
			}
			n = min(n * 2, len(set))
		}
	}
	if len(set) == 1 && s.runs < s.budget {
		ok := _try(s, nil, other) if is_ops else _try(s, other, nil)
		if ok {
			clear(set)
		}
	}
}

shrink :: proc(seed: u64) -> bool {
	resume := make([dynamic]string, context.temp_allocator)
	if v, has := os.lookup_env("SIM_KEEP_OPS", context.temp_allocator); has {
		append(&resume, fmt.tprintf("SIM_KEEP_OPS=%s", v))
	}
	if v, has := os.lookup_env("SIM_KEEP_FAULTS", context.temp_allocator); has {
		append(&resume, fmt.tprintf("SIM_KEEP_FAULTS=%s", v))
	}
	st, ok, why := run_child(seed, false, resume[:])
	if ok {
		fmt.eprintf("sim: seed %d passes; nothing to shrink\n", seed)
		return true
	}
	s := Shrinker{seed = seed, budget = int(env_u64("SIM_SHRINK_BUDGET", 300))}
	if st.ops == 0 && st.faults == 0 {
		st.ops = default_config(seed).ops
		st.faults = 64
	}
	s.sig = strings.clone(string(st.sig[:st.sig_len]) if st.sig_len > 0 else why, context.temp_allocator)
	fmt.eprintf("sim: shrinking seed %d (%d ops, %d faults) for failure: %s\n", seed, st.ops, st.faults, s.sig)
	ops := make([dynamic]int, context.temp_allocator)
	faults := make([dynamic]int, context.temp_allocator)
	start_ops := filter_parse("SIM_KEEP_OPS")
	start_faults := filter_parse("SIM_KEEP_FAULTS")
	defer delete(start_ops.keep)
	defer delete(start_faults.keep)
	for i in 0 ..< st.ops {
		if filter_keeps(&start_ops, i) {
			append(&ops, i)
		}
	}
	for i in 0 ..< st.faults {
		if filter_keeps(&start_faults, i) {
			append(&faults, i)
		}
	}
	_ddmin(&s, &faults, ops[:], false)
	_ddmin(&s, &ops, faults[:], true)
	_ddmin(&s, &faults, ops[:], false)
	env := make([dynamic]string, context.temp_allocator)
	environ, _ := os.environ(context.temp_allocator)
	for kv in environ {
		if strings.has_prefix(kv, "SIM_") && !strings.has_prefix(kv, "SIM_SEED=") && !strings.has_prefix(kv, "SIM_SHRINK") && !strings.has_prefix(kv, "SIM_KEEP_") {
			append(&env, kv)
		}
	}
	fmt.eprintf("sim: minimal reproduction after %d runs (%d of %d ops, %d of %d faults):\n  %sSIM_SEED=%d SIM_KEEP_OPS=%s SIM_KEEP_FAULTS=%s odin test tests/sim -o:speed\n", s.runs, len(ops), st.ops, len(faults), st.faults, strings.concatenate({strings.join(env[:], " ", context.temp_allocator), " " if len(env) > 0 else ""}, context.temp_allocator), seed, _ranges(ops[:]), _ranges(faults[:]))
	return false
}

got_stats :: proc(st: Wire_Stats) -> bool {
	return st.ops > 0 || st.faults > 0 || st.disk_ops > 0
}

rss_mib :: proc() -> int {
	data, err := os.read_entire_file_from_path("/proc/self/statm", context.temp_allocator)
	if err != nil {
		return 0
	}
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	pages, _ := strconv.parse_int(fields[1])
	return pages * 4096 >> 20
}

memory_runaway :: proc(w: ^World) -> bool {
	w.mem_checks += 1
	if w.mem_checks & 255 != 0 {
		return false
	}
	rss := rss_mib()
	if rss < int(w.cfg.rss_max) {
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "memory runaway: RSS %d MiB at t=%d ms; queue=%d events", rss, w.now / 1_000_000, len(w.queue))
	for n in w.nodes {
		fmt.sbprintf(&b, "; %s region %d MiB live (%d blocks) temp peak %d MiB disk %d MiB unsynced %d MiB", n.name, n.inst.main.bytes >> 20, n.inst.main.live, int(n.inst.temp.peak - n.inst.temp.base) >> 20 if n.inst.temp.peak > 0 else 0, disk_bytes(&n.disk) >> 20, n.disk.pend_bytes >> 20)
	}
	fmt.sbprintf(&b, "; relay region %d MiB disk %d MiB", w.relay.inst.main.bytes >> 20, disk_bytes(&w.relay.disk) >> 20)
	world_fail(w, "%s", strings.to_string(b))
	w.aborted = true
	return true
}
