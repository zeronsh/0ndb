package relayvec

import "core:crypto/sha2"
import "core:fmt"
import "core:mem"
import "core:strings"
import "../../src/prim"
import osync "../../src/sync"

FORMAT :: "0ndb relay vectors 1"
STUB_CREDENTIAL :: u8(0x7e)

Vec_Config :: struct {
	wall_ms:         i64,
	mono_ms:         i64,
	open:            bool,
	quota:           i64,
	feed_compact:    i64,
	max_follows:     int,
	principal_conns: int,
	max_space_conns: int,
}

default_config :: proc() -> Vec_Config {
	return Vec_Config {
		wall_ms = 1_767_225_600_000,
		mono_ms = 1_000,
		open = true,
		feed_compact = -1,
		max_follows = 16384,
		principal_conns = 1024,
		max_space_conns = 4096,
	}
}

Step_Kind :: enum u8 {
	Connect,
	Send,
	Durable,
	Close,
	Clock,
}

Step :: struct {
	kind:    Step_Kind,
	conn:    string,
	local:   bool,
	binding: []u8,
	bytes:   []u8,
	wall_ms: i64,
	mono_ms: i64,
	comment: string,
}

Out_Frames :: struct {
	conn:   string,
	frames: [][]u8,
}

Step_Result :: struct {
	outs:    []Out_Frames,
	closed:  []string,
	effects: []osync.Mem_Effect,
}

H_Conn :: struct {
	h:        ^Harness,
	name:     string,
	ref:      osync.Conn_Ref,
	out:      [dynamic]u8,
	closed:   bool,
	reported: bool,
}

Harness :: struct {
	cfg:     Vec_Config,
	store:   osync.Mem_Store,
	auth:    osync.Member_Authorizer,
	caps:    osync.Cap_Authorizer,
	core:    osync.Relay_Core,
	wall_ns: i64,
	mono_ns: i64,
	conns:   [dynamic]^H_Conn,
	log:     [dynamic]osync.Mem_Effect,
	spaces:  [dynamic]osync.Space_Id,
}

harness_init :: proc(h: ^Harness, cfg: Vec_Config) -> osync.Error {
	h^ = {cfg = cfg, wall_ns = cfg.wall_ms * 1_000_000, mono_ns = cfg.mono_ms * 1_000_000}
	h.conns = make([dynamic]^H_Conn)
	h.log = make([dynamic]osync.Mem_Effect)
	clock := prim.Clock{data = h, mono_ns = _h_mono, wall_ns = _h_wall}
	osync.mem_store_init(&h.store, clock)
	h.store.log = &h.log
	stub := osync.Authorizer{data = h, authorize = _stub_authorize}
	osync.member_authorizer_init(&h.auth, {}, "", stub, cfg.open, cfg.quota, clock) or_return
	cc := osync.relay_core_config()
	cc.storage = osync.mem_store(&h.store)
	osync.cap_authorizer_init(&h.caps, osync.member_authorizer(&h.auth), cfg.quota, clock)
	h.caps.issuer_data = &h.auth
	h.caps.issuer_ok = proc(data: rawptr, space: prim.Id, issuer: osync.Public_Key) -> bool {
		return osync.member_authorizer_active((^osync.Member_Authorizer)(data), osync.Space_Id(space), issuer)
	}
	cc.authorizer = osync.cap_authorizer(&h.caps)
	cc.clock = clock
	cc.max_follows = cfg.max_follows
	cc.principal_conns = cfg.principal_conns
	cc.max_space_conns = cfg.max_space_conns
	cc.feed_compact = cfg.feed_compact
	osync.relay_core_init(&h.core, cc) or_return
	osync.member_authorizer_set_storage(&h.auth, cc.storage)
	return .None
}

harness_destroy :: proc(h: ^Harness) {
	osync.relay_core_destroy(&h.core)
	osync.cap_authorizer_destroy(&h.caps)
	osync.member_authorizer_destroy(&h.auth)
	osync.mem_store_destroy(&h.store)
	for c in h.conns {
		delete(c.out)
		free(c)
	}
	delete(h.conns)
	delete(h.log)
}

@(private)
_h_mono :: proc(data: rawptr) -> i64 {
	return (cast(^Harness)data).mono_ns
}

@(private)
_h_wall :: proc(data: rawptr) -> i64 {
	return (cast(^Harness)data).wall_ns
}

@(private)
_stub_authorize :: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^osync.Principal) -> osync.Code {
	h := cast(^Harness)data
	if len(credential) != 1 + 16 + 16 + 1 || credential[0] != STUB_CREDENTIAL {
		return .Auth
	}
	p^ = {}
	copy(p.namespace[:], credential[1:17])
	copy(p.participant[:], credential[17:33])
	flags := credential[33]
	p.read_all = flags & 1 != 0
	p.append_own = flags & 2 != 0
	p.objects = flags & 4 != 0
	p.quota = h.cfg.quota
	return .None
}

@(private)
_h_send :: proc(data: rawptr, bytes: []u8, more: bool) -> (int, osync.Error) {
	c := cast(^H_Conn)data
	append(&c.out, ..bytes)
	return len(bytes), .None
}

@(private)
_h_close :: proc(data: rawptr) {
	c := cast(^H_Conn)data
	c.closed = true
}

harness_conn :: proc(h: ^Harness, name: string) -> ^H_Conn {
	for c in h.conns {
		if c.name == name {
			return c
		}
	}
	return nil
}

harness_apply :: proc(h: ^Harness, s: Step, allocator := context.allocator) -> (res: Step_Result, ok: bool) {
	clear(&h.log)
	switch s.kind {
	case .Connect:
		if harness_conn(h, s.conn) != nil {
			return {}, false
		}
		c := new(H_Conn)
		c.h = h
		c.name = strings.clone(s.conn)
		c.out = make([dynamic]u8)
		append(&h.conns, c)
		link := osync.Link{data = c, send = _h_send, close = _h_close}
		ref, err := osync.relay_core_attach(&h.core, link, s.local, s.binding)
		if err != .None {
			return {}, false
		}
		c.ref = ref
	case .Send:
		c := harness_conn(h, s.conn)
		if c == nil {
			return {}, false
		}
		if !c.closed {
			osync.relay_core_input(&h.core, c.ref, s.bytes)
		}
	case .Durable:
		osync.mem_store_settle(&h.store)
	case .Close:
		c := harness_conn(h, s.conn)
		if c == nil {
			return {}, false
		}
		if !c.closed {
			c.closed = true
			c.reported = true
			osync.relay_core_detach(&h.core, c.ref)
		}
	case .Clock:
		h.wall_ns = s.wall_ms * 1_000_000
		h.mono_ns = s.mono_ms * 1_000_000
	}
	outs := make([dynamic]Out_Frames, allocator)
	closed := make([dynamic]string, allocator)
	for c in h.conns {
		if len(c.out) > 0 {
			frames := make([dynamic][]u8, allocator)
			pos := 0
			for pos + 5 <= len(c.out) {
				n := 5 + int(prim.get_u32le(c.out[pos:]))
				if pos + n > len(c.out) {
					break
				}
				f := make([]u8, n, allocator)
				copy(f, c.out[pos:pos + n])
				append(&frames, f)
				pos += n
			}
			if pos != len(c.out) {
				return {}, false
			}
			clear(&c.out)
			append(&outs, Out_Frames{conn = c.name, frames = frames[:]})
		}
		if c.closed && !c.reported {
			c.reported = true
			append(&closed, c.name)
		}
	}
	effects := make([]osync.Mem_Effect, len(h.log), allocator)
	copy(effects, h.log[:])
	clear(&h.log)
	return {outs = outs[:], closed = closed[:], effects = effects}, true
}

hex :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(b) * 2, allocator)
	prim.hex_encode(out, b)
	return string(out)
}

unhex :: proc(s: string, allocator := context.allocator) -> (b: []u8, ok: bool) {
	if len(s) % 2 != 0 {
		return nil, false
	}
	b = make([]u8, len(s) / 2, allocator)
	if !prim.hex_decode(b, transmute([]u8)s) {
		return nil, false
	}
	return b, true
}

sha256_hex :: proc(b: []u8) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, b)
	d: [32]u8
	sha2.final(&ctx, d[:])
	return hex(d[:])
}

effect_name :: proc(k: osync.Mem_Effect_Kind) -> string {
	switch k {
	case .Append:
		return "append"
	case .Fill:
		return "fill"
	case .Note:
		return "note"
	case .Redact:
		return "redact"
	case .Drop:
		return "drop"
	case .Put:
		return "put"
	case .Remove:
		return "remove"
	case .Trim:
		return "trim"
	}
	return "?"
}

effect_json :: proc(b: ^strings.Builder, e: osync.Mem_Effect) {
	sp := e.space
	id := e.id
	fmt.sbprintf(b, `{{"op": "%s", "space": "%s", "id": "%s", "at": %d, "len": %d, "result": "%v"}}`, effect_name(e.kind), hex(sp[:]), hex(id[:]), e.at, e.length, e.result)
}

state_json :: proc(b: ^strings.Builder, h: ^Harness, indent: string) {
	strings.write_string(b, "{")
	first := true
	for sp in h.spaces {
		ids := osync.mem_store_streams(&h.store, sp)
		keys := osync.mem_store_object_keys(&h.store, sp)
		s := sp
		if !first {
			strings.write_string(b, ",")
		}
		first = false
		fmt.sbprintf(b, "\n%s  \"%s\": {{\"streams\": {{", indent, hex(s[:]))
		sf := true
		for id in ids {
			if _is_reserved(cast([32]u8)id) {
				continue
			}
			base, length, data, _ := osync.mem_store_stream(&h.store, sp, id)
			v := id
			if !sf {
				strings.write_string(b, ",")
			}
			sf = false
			fmt.sbprintf(b, "\n%s    \"%s\": {{\"base\": %d, \"length\": %d, \"sha256\": \"%s\"}}", indent, hex(v[:]), base, length, sha256_hex(data))
		}
		strings.write_string(b, "}, \"objects\": {")
		of := true
		for k in keys {
			data, _ := osync.mem_store_object(&h.store, sp, k)
			v := k
			if !of {
				strings.write_string(b, ",")
			}
			of = false
			fmt.sbprintf(b, "\n%s    \"%s\": {{\"size\": %d, \"sha256\": \"%s\"}}", indent, hex(v[:]), len(data), sha256_hex(data))
		}
		strings.write_string(b, "}}")
	}
	fmt.sbprintf(b, "\n%s}", indent)
}

@(private)
_is_reserved :: proc(id: [32]u8) -> bool {
	for i in 0 ..< 16 {
		if id[i] != 0xff {
			return false
		}
	}
	return true
}

frame_name :: proc(f: []u8) -> string {
	if len(f) < 5 {
		return "?"
	}
	return fmt.tprintf("%v", osync.Kind(f[4]))
}

bytes_equal :: proc(a, b: []u8) -> bool {
	return len(a) == len(b) && mem.compare(a, b) == 0
}
