package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import omap "../../src/map"
import "../../src/prim"

Ms_Case :: enum u8 {
	Join,
	Rotate,
}

member_secrets_run :: proc(seed: u64, c: Ms_Case, mode: Crash_Mode, crash_at: u64) -> (failures: [dynamic]string, crashed: bool) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	crashed = _ms_world(w, c, mode, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ms_reads :: proc(w: ^World, n: ^Node, o: eng.Object, want: string, ms: i64) -> bool {
	for i: i64 = 0; i < ms / 500; i += 1 {
		run_until(w, w.now + 500_000_000, true)
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		data, err := eng.text_read(&n.e, o, context.temp_allocator)
		ok := err == .None && strings.contains(string(data), want)
		node_after(n)
		if ok {
			return true
		}
	}
	return false
}

@(private = "file")
_ms_join :: proc(w: ^World, b: ^Node, space: prim.Id, proof: []u8) -> eng.Error {
	context = instance_context(&b.inst)
	_, err := eng.space_join_enrollment(&b.e, space, proof, "member-secrets", "relay", w.relay.public)
	if err == .None {
		err = eng.space_open(&b.e, space)
	}
	node_after(b)
	return err
}

@(private = "file")
_ms_epoch :: proc(n: ^Node, space: prim.Id) -> (epoch: bool) {
	if !n.alive || !n.e_open {
		return false
	}
	context = instance_context(&n.inst)
	_, epoch = eng.space_epoch_current(&n.e, space)
	node_after(n)
	return
}

@(private = "file")
_ms_world :: proc(w: ^World, c: Ms_Case, mode: Crash_Mode, crash_at: u64) -> (crashed: bool) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	proof: []u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "member-secrets", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "member secrets: space setup: %v", err)
			return
		}
		space = id
		o, err = eng.text_create(&a.e, space, "shared", "owner\n")
		if err != .None {
			world_fail(w, "member secrets: text_create: %v", err)
			return
		}
		p, perr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "member secrets: member_add: %v", perr)
			return
		}
		proof = p
	}
	run_until(w, w.now + 5_000_000_000, true)
	victim := b
	arm :: proc(n: ^Node, mode: Crash_Mode, crash_at: u64) {
		if crash_at == 0 {
			return
		}
		n.disk.force_process = mode == .Process
		n.disk.force_power = mode == .Power
		n.disk.crash_at = n.disk.stats.ops + crash_at
	}
	crashes := w.stats.crashes
	switch c {
	case .Join:
		arm(b, mode, crash_at)
		_ms_join(w, b, space, proof)
	case .Rotate:
		if err := _ms_join(w, b, space, proof); err != .None {
			world_fail(w, "member secrets: join: %v", err)
			return
		}
		run_until(w, w.now + 20_000_000_000, true)
		if !_ms_epoch(b, space) {
			world_fail(w, "member secrets: the member holds no epoch before the rotation, so the check proves nothing")
			return
		}
		victim = a
		arm(a, mode, crash_at)
		context = instance_context(&a.inst)
		eng.space_rotate(&a.e, space)
		node_after(a)
	}
	run_until(w, w.now + 20_000_000_000, true)
	victim.disk.crash_at = 0
	victim.disk.force_process = false
	victim.disk.force_power = false
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 10_000_000_000, true)
	if !victim.alive || !victim.e_open {
		world_fail(w, "member secrets: the node did not come back")
		return
	}
	if c == .Join {
		have: bool
		{
			context = instance_context(&b.inst)
			_, err := eng.space_members_status(&b.e, space)
			have = err != .Not_Found
			node_after(b)
		}
		if !have {
			if err := _ms_join(w, b, space, proof); err != .None {
				world_fail(w, "member secrets: joining again after the crash: %v", err)
				return
			}
		} else {
			context = instance_context(&b.inst)
			eng.space_open(&b.e, space)
			node_after(b)
		}
	}
	run_until(w, w.now + 60_000_000_000, true)
	for n in ([]^Node{a, b}) {
		if !_ms_epoch(n, space) {
			world_fail(w, "member secrets: %s holds no current epoch after the restart", n.name)
		}
		if !_ms_reads(w, n, o, "owner", 5_000) {
			world_fail(w, "member secrets: %s never read the shared text", n.name)
		}
	}
	if len(w.failures) > 0 {
		return
	}
	write: {
		context = instance_context(&victim.inst)
		defer node_after(victim)
		cur, rerr := eng.text_read(&victim.e, o, context.temp_allocator)
		if rerr != .None {
			world_fail(w, "member secrets: text_read: %v", rerr)
			return
		}
		if err := eng.text_edit(&victim.e, o, len(cur), 0, "victim\n"); err != .None && err != .Pending {
			world_fail(w, "member secrets: text_edit: %v", err)
			return
		}
	}
	other := a if victim == b else b
	if !_ms_reads(w, other, o, "victim", 30_000) {
		world_fail(w, "member secrets: %s never read %s's write", other.name, victim.name)
	}
	return
}

@(private = "file")
Ms_Read :: struct {
	calls: int,
	err:   eng.Error,
}

@(private = "file")
_ms_read_done :: proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
	r := (^Ms_Read)(data)
	r.calls += 1
	r.err = err
}

@(private = "file")
_ms_settling :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	proof: []u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "member-settling", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "member settling: space setup: %v", err)
			return
		}
		space = id
		o, err = eng.map_create(&a.e, space, "keys")
		if err != .None {
			world_fail(w, "member settling: map_create: %v", err)
			return
		}
		if _, serr := eng.map_set(&a.e, o, transmute([]u8)string("k"), []omap.Field{omap.field_str(1, "v")}); serr != .None && serr != .Pending {
			world_fail(w, "member settling: map_set: %v", serr)
			return
		}
		p, perr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "member settling: member_add: %v", perr)
			return
		}
		proof = p
	}
	run_until(w, w.now + 5_000_000_000, true)
	if err := _ms_join(w, b, space, proof); err != .None {
		world_fail(w, "member settling: join: %v", err)
		return
	}
	if _ms_epoch(b, space) {
		world_fail(w, "member settling: the member holds its epoch before any frame arrived, so the check proves nothing")
		return
	}
	r: Ms_Read
	ready := eng.Ready{data = &r, call = _ms_read_done, fresh = true}
	first: {
		context = instance_context(&b.inst)
		_, found, err := eng.map_get(&b.e, o, transmute([]u8)string("k"), context.temp_allocator, ready)
		if err == .None && !found {
			world_fail(w, "member settling: a fresh map_get on a member without its key answers absent for a key its space holds")
		}
		cur: eng.Map_Cursor
		_, _, serr := eng.map_scan(&b.e, o, nil, &cur, 8, context.temp_allocator, eng.Ready{data = &r, call = _ms_read_done, fresh = true})
		if serr == .None {
			world_fail(w, "member settling: a fresh map_scan on a member without its key answers")
		}
		node_after(b)
	}
	for _ in 0 ..< 60 {
		run_until(w, w.now + 1_000_000_000, true)
		if r.calls >= 2 {
			break
		}
	}
	if len(w.failures) == 0 && r.calls < 2 {
		world_fail(w, "member settling: the waiting reads were called back %d times of 2", r.calls)
	}
	last: {
		context = instance_context(&b.inst)
		for _ in 0 ..< 1 {
			_, found, err := eng.map_get(&b.e, o, transmute([]u8)string("k"), context.temp_allocator)
			if len(w.failures) == 0 && (err != .None || !found) {
				world_fail(w, "member settling: after the wait the key is found %v, %v", found, err)
			}
		}
		node_after(b)
	}
}

member_settling_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_ms_settling(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(test)
member_settling_read :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := member_settling_run(1)
	for f in failures {
		fmt.eprintf("member_settling_read: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "member_settling_read failed")
	delete(failures)
}

@(test)
member_secrets_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for c in Ms_Case {
		for mode in ([]Crash_Mode{.Process, .Power}) {
			bad := 0
			done := false
			for k in u64(0) ..= 4000 {
				failures, crashed := member_secrets_run(1, c, mode, k)
				for f in failures {
					fmt.eprintf("member_secrets_crash %v %v at disk op %d: %s\n", c, mode, k, f)
					delete(f)
				}
				if len(failures) > 0 {
					bad += 1
				}
				delete(failures)
				if k > 0 && !crashed {
					fmt.eprintf("member_secrets_crash %v %v: %d crash points, %d failed\n", c, mode, k - 1, bad)
					done = true
					break
				}
			}
			testing.expect(t, bad == 0, fmt.tprintf("member_secrets_crash %v %v failed", c, mode))
			testing.expect(t, done, "member_secrets_crash: the run never finished without a crash")
		}
	}
}
