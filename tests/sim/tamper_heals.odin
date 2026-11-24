package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
Heal_Key :: struct {
	kind:   eng.Event_Kind,
	device: prim.Id,
}

@(private = "file")
Heal_World :: struct {
	node:    int,
	stream:  osync.Stream_Id,
	at:      i64,
	active:  bool,
	flips:   int,
	limit:   int,
	reports: map[Heal_Key]int,
}

@(private = "file")
_th: ^Heal_World

@(init)
_tamper_heals_init :: proc "contextless" () {
	register_world(64, _th_init, _th_destroy)
	register_engine_event(64, _th_event)
	register_frame_filter(21, _th_filter)
}

@(private = "file")
_th_init :: proc(w: ^World) {
	_th = new(Heal_World, w.allocator)
	_th.node = -1
	_th.reports = make(map[Heal_Key]int, w.allocator)
}

@(private = "file")
_th_destroy :: proc(w: ^World) {
	if _th == nil {
		return
	}
	frame_filter_enable(false)
	delete(_th.reports)
	free(_th, w.allocator)
	_th = nil
}

@(private = "file")
_th_event :: proc(w: ^World, n: ^Node, ev: ^eng.Event) {
	if _th != nil && n.idx == _th.node && (ev.kind == .Relay_Misbehaving || ev.kind == .Peer_Misbehaving) {
		_th.reports[Heal_Key{ev.kind, ev.device}] += 1
	}
}

@(private = "file")
_th_filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> bool {
	if _th == nil || !_th.active || _th.flips >= _th.limit || c.node.idx != _th.node || kind != u8(osync.Kind.Data) || len(payload) <= 48 {
		return false
	}
	if string(payload[:32]) != string(_th.stream[:]) {
		return false
	}
	at := i64(prim.get_u64le(payload[32:40]))
	bytes := payload[48:]
	if _th.at < at || _th.at - at >= i64(len(bytes)) {
		return false
	}
	off := int(_th.at - at) + 24
	if off >= len(bytes) {
		off = int(_th.at - at)
	}
	bytes[off] ~= 0x01
	_th.flips += 1
	return false
}

tamper_heals_run :: proc(seed: u64, limit: int) -> (failures: [dynamic]string, flips, reports: int, read: bool) {
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
	reports, read = _tamper_heals(w, limit)
	flips = _th.flips
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_th_text :: proc(n: ^Node, o: eng.Object) -> (string, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.text_read(&n.e, o, context.temp_allocator)
	if err != .None {
		return "", false
	}
	return strings.clone(string(data), n.w.allocator), true
}

@(private = "file")
_tamper_heals :: proc(w: ^World, limit: int) -> (reports: int, read: bool) {
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
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "tamper", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "tamper heals: space setup: %v", err)
			return
		}
		space = id
		proof, perr := eng.member_add(&a.e, space, b.identity, .Device, .Member, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "tamper heals: member_add: %v", perr)
			return
		}
		o, err = eng.text_create(&a.e, space, "tamper", "clean\n")
		if err != .None {
			world_fail(w, "tamper heals: text_create: %v", err)
			return
		}
		node_after(a)
		context = instance_context(&b.inst)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "tamper", "relay", w.relay.public); jerr != .None {
			world_fail(w, "tamper heals: join: %v", jerr)
			return
		}
		eng.space_open(&b.e, space)
		node_after(b)
	}
	seen := false
	for i := 0; i < 60 && !seen; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		if t, ok := _th_text(b, o); ok {
			seen = strings.contains(t, "clean")
			delete(t, w.allocator)
		}
	}
	if !seen {
		world_fail(w, "tamper heals: the reader never read the clean text, so the check proves nothing")
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	ids: {
		context = instance_context(&a.inst)
		defer node_after(a)
		key, kerr := eng.object_key(&a.e, o)
		info, ierr := eng.space_info(&a.e, space)
		if kerr != .None || ierr != .None {
			world_fail(w, "tamper heals: object_key %v space_info %v", kerr, ierr)
			return
		}
		h := prim.id_hex(o.id)
		sc := osync.scope_make(key, info.mode)
		_th.stream = osync.stream_id(&sc, a.identity.id, fmt.tprintf("t%s", string(h[:])), 0)
		osync.scope_clear(&sc)
	}
	length, _, exists := relay_probe(w, space, _th.stream)
	if !exists || length <= 0 {
		world_fail(w, "tamper heals: the writer's segment is not on the relay, so the check proves nothing")
		return
	}
	node_kill(b)
	disk_crash(&b.disk, .Process, &w.fault_rng)
	write: {
		context = instance_context(&a.inst)
		defer node_after(a)
		if eerr := eng.text_edit(&a.e, o, len("clean\n"), 0, "tampered\n"); eerr != .None && eerr != .Pending {
			world_fail(w, "tamper heals: text_edit: %v", eerr)
			return
		}
	}
	run_until(w, w.now + 10_000_000_000, true)
	if now, _, _ := relay_probe(w, space, _th.stream); now <= length {
		world_fail(w, "tamper heals: the write never reached the relay, so the check proves nothing")
		return
	}
	node_kill(a)
	disk_crash(&a.disk, .Process, &w.fault_rng)
	_th.node = b.idx
	_th.at = length
	_th.limit = limit
	_th.active = true
	frame_filter_enable(true)
	b.boot += 1
	if !node_start(b) {
		world_fail(w, "tamper heals: reader restart")
		return
	}
	for i := 0; i < 240 && !read; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		if t, ok := _th_text(b, o); ok {
			read = strings.contains(t, "tampered")
			delete(t, w.allocator)
		}
	}
	for _, n in prim.unordered(_th.reports) {
		reports += n
	}
	return
}

@(test)
tamper_heals :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for limit in 1 ..= 6 {
		failures, flips, reports, read := tamper_heals_run(1, limit)
		fmt.eprintf("tamper_heals: limit %d: %d flips, %d reports, read %v\n", limit, flips, reports, read)
		for f in failures {
			fmt.eprintf("tamper_heals: %s\n", f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0 && flips == limit, "tamper_heals: the case did not run")
		testing.expect(t, read, "tamper_heals: the read never completed after the relay served the range right")
		testing.expect(t, reports <= 1, "tamper_heals: the relay was reported more than once")
		testing.expect(t, reports == 1 || limit < 3, "tamper_heals: three corruptions or more were not reported")
		delete(failures)
	}
}
