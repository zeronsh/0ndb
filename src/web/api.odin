package web

import "base:intrinsics"
import "base:runtime"
import "../journal"
import "../prim"
import osync "../sync"

@(private)
_ctx :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

@(export)
ondb_alloc :: proc "c" (n: u32) -> [^]u8 {
	context = _ctx()
	b, err := make([]u8, int(n))
	if err != nil {
		return nil
	}
	return raw_data(b)
}

@(export)
ondb_free :: proc "c" (p: [^]u8, n: u32) {
	context = _ctx()
	if p != nil {
		delete(p[:n])
	}
}

@(export)
ondb_new :: proc "c" (seed: [^]u8, seed_len: u32) -> ^Session {
	context = _ctx()
	defer free_all(context.temp_allocator)
	s := new(Session)
	if s == nil {
		return nil
	}
	session_init(s)
	sd: []u8
	if seed != nil {
		sd = seed[:seed_len]
	}
	if session_device(s, sd) != .None {
		session_destroy(s)
		free(s)
		return nil
	}
	return s
}

@(export)
ondb_close :: proc "c" (s: ^Session) {
	context = _ctx()
	defer free_all(context.temp_allocator)
	session_destroy(s)
	free(s)
}

@(export)
ondb_join :: proc "c" (s: ^Session, code: [^]u8, n: u32) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	str := string(code[:n])
	err: osync.Error
	if len(str) > len(SHARE_PREFIX) && str[:len(SHARE_PREFIX)] == SHARE_PREFIX {
		err = session_open_share(s, str)
	} else {
		err = session_open_pairing(s, str)
	}
	return u32(err)
}

@(export)
ondb_connect :: proc "c" (s: ^Session) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	return u32(session_connect(s))
}

@(export)
ondb_input :: proc "c" (s: ^Session, data: [^]u8, n: u32) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	return u32(session_input(s, data[:n]))
}

@(export)
ondb_down :: proc "c" (s: ^Session) {
	context = _ctx()
	defer free_all(context.temp_allocator)
	session_down(s)
}

@(export)
ondb_request :: proc "c" (s: ^Session, op: u32, args: [^]u8, n: u32) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	a: []u8
	if args != nil {
		a = args[:n]
	}
	return request_submit(s, Op(op), a)
}

@(export)
ondb_out_ptr :: proc "c" (s: ^Session) -> [^]u8 {
	return raw_data(s.link.out)
}

@(export)
ondb_out_len :: proc "c" (s: ^Session) -> u32 {
	return u32(len(s.link.out))
}

@(export)
ondb_out_clear :: proc "c" (s: ^Session) {
	context = _ctx()
	clear(&s.link.out)
	if cap(s.link.out) > 1 << 20 {
		delete(s.link.out)
		s.link.out = make([dynamic]u8)
	}
}

@(export)
ondb_ev_ptr :: proc "c" (s: ^Session) -> [^]u8 {
	return raw_data(s.events)
}

@(export)
ondb_ev_len :: proc "c" (s: ^Session) -> u32 {
	return u32(len(s.events))
}

@(export)
ondb_ev_clear :: proc "c" (s: ^Session) {
	context = _ctx()
	clear(&s.events)
	if cap(s.events) > 1 << 20 {
		delete(s.events)
		s.events = make([dynamic]u8)
	}
}

@(export)
ondb_persist :: proc "c" (s: ^Session, on: u32) {
	s.mem.logging = on != 0
}

@(export)
ondb_log_ptr :: proc "c" (s: ^Session) -> [^]u8 {
	return raw_data(s.mem.log)
}

@(export)
ondb_log_len :: proc "c" (s: ^Session) -> u32 {
	return u32(len(s.mem.log))
}

@(export)
ondb_log_clear :: proc "c" (s: ^Session) {
	context = _ctx()
	clear(&s.mem.log)
	if cap(s.mem.log) > 1 << 20 {
		delete(s.mem.log)
		s.mem.log = make([dynamic]u8)
	}
}

@(export)
ondb_resident :: proc "c" (s: ^Session) -> u32 {
	return u32(min(s.mem.bytes, i64(max(u32))))
}

@(export)
ondb_snapshot :: proc "c" (s: ^Session) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	mem_vfs_snapshot(&s.mem)
	return u32(len(s.mem.log))
}

@(export)
ondb_restore :: proc "c" (s: ^Session, data: [^]u8, n: u32) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	return 0 if mem_vfs_restore(&s.mem, data[:n]) else u32(osync.Error.Corrupt)
}

@(export)
ondb_info :: proc "c" (s: ^Session) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	buf := make([dynamic]u8, 0, 512, context.temp_allocator)
	o: Out
	out_init(&o, &buf)
	o_id(&o, "space", s.space_id)
	none: prim.Id
	o_id(&o, "catalog", none if s.shared else s.catalog_id)
	o_id(&o, "shared", s.share.object if s.shared else none)
	o_id(&o, "device", s.device.id)
	card, _ := osync.keyring_card(&s.keyring)
	o_bytes(&o, "card", card[:])
	o_str(&o, "relay", s.relay_addr)
	o_bytes(&o, "relay_key", s.relay_pub[:])
	o_bool(&o, "connected", s.ready)
	o_u64(&o, "objects", u64(len(s.objects)))
	o_arr(&o, "views")
	for _, x in s.objects {
		o_obj(&o, "")
		o_id(&o, "object", x.id)
		o_u64(&o, "segments", u64(len(x.segs)))
		n := 0
		for sg in x.segs {
			if sg.in_view {
				n += 1
			}
		}
		o_u64(&o, "in_view", u64(n))
		o_end(&o)
	}
	o_end(&o)
	o_u64(&o, "streams", u64(len(s.remotes)))
	have: i64
	for _, rm in s.remotes {
		for h in journal.replica_have(&rm.rep) {
			have += h.to - h.from
		}
	}
	o_i64(&o, "replica_bytes", have)
	o_i64(&o, "resident_bytes", s.mem.bytes)
	o_u64(&o, "bytes_in", s.bytes_in)
	o_u64(&o, "pending", u64(len(s.requests)))
	when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
		o_u64(&o, "heap_pages", u64(intrinsics.wasm_memory_size(0)))
	}
	o_u64(&o, "err", u64(s.err))
	_event(s, .Info, 0, 0, out_finish(&o))
	return u32(len(s.events))
}

main :: proc() {
}
