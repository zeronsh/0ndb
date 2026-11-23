package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
Tamper_Key :: struct {
	kind:   eng.Event_Kind,
	device: prim.Id,
}

@(private = "file")
Tamper_World :: struct {
	node:    int,
	stream:  osync.Stream_Id,
	at:      i64,
	active:  bool,
	flips:   int,
	reports: map[Tamper_Key]int,
}

@(private = "file")
_tf: ^Tamper_World

@(init)
_tamper_forever_init :: proc "contextless" () {
	register_world(62, _tf_init, _tf_destroy)
	register_engine_event(62, _tf_event)
	register_frame_filter(20, _tf_filter)
}

@(private = "file")
_tf_init :: proc(w: ^World) {
	_tf = new(Tamper_World, w.allocator)
	_tf.node = -1
	_tf.reports = make(map[Tamper_Key]int, w.allocator)
}

@(private = "file")
_tf_destroy :: proc(w: ^World) {
	if _tf == nil {
		return
	}
	frame_filter_enable(false)
	delete(_tf.reports)
	free(_tf, w.allocator)
	_tf = nil
}

@(private = "file")
_tf_event :: proc(w: ^World, n: ^Node, ev: ^eng.Event) {
	if _tf != nil && n.idx == _tf.node && (ev.kind == .Relay_Misbehaving || ev.kind == .Peer_Misbehaving) {
		_tf.reports[Tamper_Key{ev.kind, ev.device}] += 1
	}
}

@(private = "file")
_tf_filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> bool {
	if _tf == nil || !_tf.active || c.node.idx != _tf.node || kind != u8(osync.Kind.Data) || len(payload) <= 48 {
		return false
	}
	if string(payload[:32]) != string(_tf.stream[:]) {
		return false
	}
	at := i64(prim.get_u64le(payload[32:40]))
	bytes := payload[48:]
	if _tf.at < at || _tf.at - at >= i64(len(bytes)) {
		return false
	}
	off := int(_tf.at - at) + 24
	if off >= len(bytes) {
		off = int(_tf.at - at)
	}
	bytes[off] ~= 0x01
	_tf.flips += 1
	return false
}

tamper_forever_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_tamper_forever(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_tf_text :: proc(n: ^Node, o: eng.Object) -> (string, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.text_read(&n.e, o, context.temp_allocator)
	if err != .None {
		return "", false
	}
	return strings.clone(string(data), n.w.allocator), true
}

@(private = "file")
_tamper_forever :: proc(w: ^World) {
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
			world_fail(w, "tamper forever: space setup: %v", err)
			return
		}
		space = id
		proof, perr := eng.member_add(&a.e, space, b.identity, .Device, .Member, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "tamper forever: member_add: %v", perr)
			return
		}
		o, err = eng.text_create(&a.e, space, "tamper", "clean\n")
		if err != .None {
			world_fail(w, "tamper forever: text_create: %v", err)
			return
		}
		node_after(a)
		context = instance_context(&b.inst)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "tamper", "relay", w.relay.public); jerr != .None {
			world_fail(w, "tamper forever: join: %v", jerr)
			return
		}
		eng.space_open(&b.e, space)
		node_after(b)
	}
	seen := false
	for i := 0; i < 60 && !seen; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		if t, ok := _tf_text(b, o); ok {
			seen = strings.contains(t, "clean")
			delete(t, w.allocator)
		}
	}
	if !seen {
		world_fail(w, "tamper forever: the reader never read the clean text, so the check proves nothing")
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	ids: {
		context = instance_context(&a.inst)
		defer node_after(a)
		key, kerr := eng.object_key(&a.e, o)
		info, ierr := eng.space_info(&a.e, space)
		if kerr != .None || ierr != .None {
			world_fail(w, "tamper forever: object_key %v space_info %v", kerr, ierr)
			return
		}
		h := prim.id_hex(o.id)
		sc := osync.scope_make(key, info.mode)
		_tf.stream = osync.stream_id(&sc, a.identity.id, fmt.tprintf("t%s", string(h[:])), 0)
		osync.scope_clear(&sc)
	}
	length, _, exists := relay_probe(w, space, _tf.stream)
	if !exists || length <= 0 {
		world_fail(w, "tamper forever: the writer's segment is not on the relay, so the check proves nothing")
		return
	}
	_tf.node = b.idx
	_tf.at = length
	_tf.active = true
	frame_filter_enable(true)
	write: {
		context = instance_context(&a.inst)
		defer node_after(a)
		if eerr := eng.text_edit(&a.e, o, len("clean\n"), 0, "tampered\n"); eerr != .None && eerr != .Pending {
			world_fail(w, "tamper forever: text_edit: %v", eerr)
			return
		}
	}
	for i := 0; i < 120; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		if t, ok := _tf_text(b, o); ok {
			delete(t, w.allocator)
		}
	}
	idle := run_until(w, w.now + 300_000_000_000, true)
	if _tf.flips == 0 {
		world_fail(w, "tamper forever: the relay never served the record it corrupts, so the check proves nothing")
		return
	}
	if !idle {
		world_fail(w, "tamper forever: the world never became idle while the relay corrupts one record forever")
	}
	check_idle(w)
	reports := 0
	for k, n in _tf.reports {
		reports += n
		if n > 1 {
			world_fail(w, "tamper forever: %s reported %v of device %s %d times for one corrupt record", b.name, k.kind, id_short(k.device), n)
		}
	}
	if reports == 0 {
		world_fail(w, "tamper forever: %s never reported the relay that corrupts the record (%d flips)", b.name, _tf.flips)
	}
}

@(test)
tamper_forever :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := tamper_forever_run(1)
	for f in failures {
		fmt.eprintf("tamper_forever: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "tamper_forever failed")
	delete(failures)
}
