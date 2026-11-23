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
	return u32(session_open_share(s, string(code[:n])))
}

@(export)
ondb_account_options :: proc "c" (s: ^Session, record: [^]u8, n: u32) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	rec: osync.Account_Record
	if err := osync.account_record_decode(record[:n], &rec, context.temp_allocator); err != .None {
		return u32(err)
	}
	clear(&s.result)
	opts := osync.account_unlock_options(&rec)
	b: [4]u8
	prim.put_u32le(b[:], u32(len(opts)))
	append(&s.result, ..b[:])
	for o in opts {
		prim.put_u32le(b[:], u32(len(o.credential)))
		append(&s.result, ..b[:])
		append(&s.result, ..o.credential)
		x := o.salt
		append(&s.result, ..x[:])
	}
	return 0
}

@(export)
ondb_account_open :: proc "c" (s: ^Session, record: [^]u8, rn: u32, entries: [^]u8, en: u32, credential: [^]u8, cn: u32, prf: [^]u8, space: [^]u8) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	p: [32]u8
	copy(p[:], prf[:32])
	sp: prim.Id
	if space != nil {
		copy(sp[:], space[:16])
	}
	ents: []u8
	if entries != nil {
		ents = entries[:en]
	}
	err := session_open_account(s, record[:rn], ents, credential[:cn], p, sp)
	return u32(err)
}

@(export)
ondb_approver_open :: proc "c" (s: ^Session, record: [^]u8, rn: u32, credential: [^]u8, cn: u32, prf: [^]u8) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	p: [32]u8
	copy(p[:], prf[:32])
	return u32(session_open_approver(s, record[:rn], credential[:cn], p))
}

@(export)
ondb_approve :: proc "c" (s: ^Session, code: [^]u8, n: u32, approve: u32) -> u32 {
	context = _ctx()
	defer free_all(context.temp_allocator)
	return u32(session_approve(s, string(code[:n]), approve != 0))
}

@(export)
ondb_idp_salt :: proc "c" (s: ^Session, subject: [^]u8, n: u32) -> u32 {
	context = _ctx()
	salt := osync.idp_salt(subject[:n])
	clear(&s.result)
	append(&s.result, ..salt[:])
	return 0
}

@(export)
ondb_result_ptr :: proc "c" (s: ^Session) -> [^]u8 {
	return raw_data(s.result)
}

@(export)
ondb_result_len :: proc "c" (s: ^Session) -> u32 {
	return u32(len(s.result))
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
	for mk2_ in prim.sorted_keys(s.objects) {
		if mk2_ not_in s.objects {
			continue
		}
		x := s.objects[mk2_]
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
		o_arr(&o, "segs")
		for sg in x.segs {
			o_obj(&o, "")
			o_id(&o, "device", sg.device)
			o_bool(&o, "keys", sg.tree_ok)
			o_u64(&o, "epoch", sg.epoch)
			o_bool(&o, "card", sg.device in s.identities)
			o_end(&o)
		}
		o_end(&o)
		o_end(&o)
	}
	o_end(&o)
	o_u64(&o, "streams", u64(len(s.remotes)))
	have: i64
	for mk1_ in prim.sorted_keys(s.remotes) {
		if mk1_ not_in s.remotes {
			continue
		}
		rm := s.remotes[mk1_]
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
