package capi

import "base:runtime"
import "core:sync"
import "./api"
import eng "../engine"

ABI_MAJOR :: 1
ABI_MINOR :: 1

FLAG_JSON :: u32(1)

CFG_NO_VERIFY :: u32(1 << 0)
CFG_NO_KTLS :: u32(1 << 1)
CFG_PADDING :: u32(1 << 2)
CFG_NO_SEARCH :: u32(1 << 3)
CFG_DEFERRED :: u32(1 << 4)
CFG_EVENTS_JSON :: u32(1 << 5)
CFG_IDLE_PAGEOUT :: u32(1 << 6)

Done_Fn :: #type proc "c" (ud: rawptr, call: u64, status: i32, payload: [^]u8, len: uint)
Sub_Fn :: #type proc "c" (ud: rawptr, sub: u64, payload: [^]u8, len: uint)
Post_Fn :: #type proc "c" (h: ^Handle, ud: rawptr)
Event_Fn :: #type proc "c" (ud: rawptr, payload: [^]u8, len: uint)

Events :: struct {
	size:  u32,
	ud:    rawptr,
	event: Event_Fn,
}

Config :: struct {
	size:           u32,
	flags:          u32,
	dir:            cstring,
	handle_cache:   i32,
	search_budget:  i32,
	settle_ms:      i64,
	vfs:            ^C_Vfs,
	keyring:        ^C_Keyring,
	credentials:    ^C_Credentials,
	transport:      ^C_Transport,
	clock:          ^C_Clock,
	random:         ^C_Random,
	spawner:        ^C_Spawner,
	http:           ^C_Http,
	write_observer: ^C_Write_Observer,
	embedder:       ^C_Embedder,
	log:            ^C_Log,
	events:         ^Events,
	runtime:        ^C_Runtime,
}

Post_Item :: struct {
	h:  ^Handle,
	fn: Post_Fn,
	ud: rawptr,
}

Handle :: struct {
	s:         api.Stack,
	allocator: runtime.Allocator,
	flags:     u32,
	plugs:     Plugs,
	rt:        Rt_Plugs,
	events:    Events,
	post_mu:   sync.Mutex,
	posts:     [dynamic]^Post_Item,
	open:      bool,
}

@(private)
_ctx :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	context = c
	c.allocator = runtime.heap_allocator()
	return c
}

@(export, link_name = "ondb_abi_version")
ondb_abi_version :: proc "c" () -> u32 {
	return ABI_MAJOR << 16 | ABI_MINOR
}

@(export, link_name = "ondb_status_name")
ondb_status_name :: proc "c" (status: i32) -> cstring {
	switch status {
	case 0:
		return "ok"
	case 1:
		return "pending"
	case 2:
		return "not_found"
	case 3:
		return "exists"
	case 4:
		return "invalid"
	case 5:
		return "busy"
	case 6:
		return "closed"
	case 7:
		return "offline"
	case 8:
		return "permission"
	case 9:
		return "forged"
	case 10:
		return "quarantined"
	case 11:
		return "missing"
	case 12:
		return "corrupt"
	case 13:
		return "limit"
	case 14:
		return "too_large"
	case 15:
		return "unsupported"
	case 16:
		return "not_assigned"
	case 17:
		return "no_space"
	case 18:
		return "no_memory"
	case 19:
		return "io"
	case 20:
		return "bad_request"
	case 21:
		return "unknown_op"
	case 22:
		return "conflict"
	case 23:
		return "cancelled"
	case 24:
		return "budget"
	case 25:
		return "spawn"
	case 26:
		return "timeout"
	}
	return "unknown"
}

@(export, link_name = "ondb_free")
ondb_free :: proc "c" (p: rawptr) {
	if p == nil {
		return
	}
	context = _ctx()
	free(p, runtime.heap_allocator())
}

@(export, link_name = "ondb_open")
ondb_open :: proc "c" (cfg: ^Config, out: ^^Handle) -> i32 {
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if out == nil {
		return i32(api.Status.Invalid)
	}
	out^ = nil
	if cfg == nil || cfg.size < u32(offset_of(Config, events)) || cfg.dir == nil {
		return i32(api.Status.Invalid)
	}
	h := new(Handle)
	h.allocator = context.allocator
	h.flags = cfg.flags
	h.posts = make([dynamic]^Post_Item)
	if cfg.size >= u32(size_of(Config)) && cfg.events != nil && cfg.events.event != nil {
		h.events = cfg.events^
	}
	ec := eng.default_config(string(cfg.dir))
	ec.verify_chains = cfg.flags & CFG_NO_VERIFY == 0
	ec.kernel_tls = cfg.flags & CFG_NO_KTLS == 0
	ec.padding = cfg.flags & CFG_PADDING != 0
	ec.search = cfg.flags & CFG_NO_SEARCH == 0
	ec.durability = .Deferred if cfg.flags & CFG_DEFERRED != 0 else .Async
	ec.idle_pageout = cfg.flags & CFG_IDLE_PAGEOUT != 0
	if cfg.handle_cache > 0 {
		ec.handle_cache = int(cfg.handle_cache)
	}
	if cfg.search_budget > 0 {
		ec.search_budget = int(cfg.search_budget)
	}
	if cfg.settle_ms > 0 {
		ec.settle_ms = cfg.settle_ms
	}
	if st := plugs_install(h, cfg, &ec); st != .Ok {
		_handle_free(h)
		return i32(st)
	}
	ec.events = eng.Event_Hook{data = h, event = _on_event}
	opts: api.Stack_Options
	if cfg.size >= u32(size_of(Config)) && cfg.runtime != nil {
		o, st := runtime_config(h, cfg.runtime)
		if st != .Ok {
			_handle_free(h)
			return i32(st)
		}
		opts = o
	}
	if st := api.stack_open(&h.s, ec, opts, h.allocator); st != .Ok {
		_handle_free(h)
		return i32(st)
	}
	h.open = true
	out^ = h
	return 0
}

@(private)
_handle_free :: proc(h: ^Handle) {
	plugs_destroy(h)
	runtime_destroy(h)
	delete(h.posts)
	free(h)
}

@(export, link_name = "ondb_close")
ondb_close :: proc "c" (h: ^Handle) -> i32 {
	if h == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	api.stack_stop(&h.s)
	_posts_drop(h)
	plugs_detach(h)
	st := api.stack_close(&h.s)
	h.open = false
	_handle_free(h)
	return i32(st)
}

@(export, link_name = "ondb_start")
ondb_start :: proc "c" (h: ^Handle) -> i32 {
	if h == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	return i32(api.stack_start(&h.s))
}

@(export, link_name = "ondb_stop")
ondb_stop :: proc "c" (h: ^Handle) -> i32 {
	if h == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	if !h.s.running {
		return i32(api.Status.Invalid)
	}
	api.stack_stop(&h.s)
	return 0
}

@(export, link_name = "ondb_post")
ondb_post :: proc "c" (h: ^Handle, fn: Post_Fn, ud: rawptr) -> i32 {
	if h == nil || fn == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	p := new(Post_Item, h.allocator)
	p.h = h
	p.fn = fn
	p.ud = ud
	sync.mutex_lock(&h.post_mu)
	append(&h.posts, p)
	sync.mutex_unlock(&h.post_mu)
	if err := eng.post(&h.s.e, _run_post, p); err != .None {
		sync.mutex_lock(&h.post_mu)
		for x, i in h.posts {
			if x == p {
				unordered_remove(&h.posts, i)
				break
			}
		}
		sync.mutex_unlock(&h.post_mu)
		free(p, h.allocator)
		return i32(api.status_of(err))
	}
	return 0
}

@(private)
_run_post :: proc(e: ^eng.Engine, data: rawptr) {
	p := (^Post_Item)(data)
	h := p.h
	sync.mutex_lock(&h.post_mu)
	for x, i in h.posts {
		if x == p {
			unordered_remove(&h.posts, i)
			break
		}
	}
	sync.mutex_unlock(&h.post_mu)
	fn, ud := p.fn, p.ud
	free(p, h.allocator)
	fn(h, ud)
}

@(private)
_posts_drop :: proc(h: ^Handle) {
	sync.mutex_lock(&h.post_mu)
	list := h.posts
	h.posts = make([dynamic]^Post_Item, h.allocator)
	sync.mutex_unlock(&h.post_mu)
	for p in list {
		free(p, h.allocator)
	}
	delete(list)
}

@(export, link_name = "ondb_fd")
ondb_fd :: proc "c" (h: ^Handle) -> i32 {
	if h == nil {
		return -1
	}
	return i32(eng.fd(&h.s.e))
}

@(export, link_name = "ondb_timeout_ms")
ondb_timeout_ms :: proc "c" (h: ^Handle) -> i64 {
	if h == nil {
		return -1
	}
	context = _ctx()
	return eng.timeout_ms(&h.s.e)
}

@(export, link_name = "ondb_step")
ondb_step :: proc "c" (h: ^Handle, block: i32) -> i32 {
	if h == nil {
		return i32(api.Status.Invalid)
	}
	if h.s.running {
		return i32(api.Status.Busy)
	}
	context = _ctx()
	return i32(api.status_of(eng.step(&h.s.e, block != 0)))
}

@(private)
Call_Ctx :: struct {
	h:  ^Handle,
	fn: Done_Fn,
	ud: rawptr,
}

@(export, link_name = "ondb_call")
ondb_call :: proc "c" (h: ^Handle, req: [^]u8, req_len: uint, flags: u32, timeout_ms: i64, out: ^[^]u8, out_len: ^uint, done: Done_Fn, ud: rawptr, call_id: ^u64) -> i32 {
	if h == nil || (req == nil && req_len > 0) {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if out != nil {
		out^ = nil
	}
	if out_len != nil {
		out_len^ = 0
	}
	if call_id != nil {
		call_id^ = 0
	}
	cc: ^Call_Ctx
	if done != nil {
		cc = new(Call_Ctx, h.allocator)
		cc^ = {h, done, ud}
	}
	id, st, payload := api.call(&h.s.a, req[:req_len], flags & FLAG_JSON != 0, _on_call_done if cc != nil else nil, cc, timeout_ms, h.allocator)
	if st == .Pending {
		if cc == nil {
			api.cancel(&h.s.a, id)
			return i32(api.Status.Pending)
		}
		if call_id != nil {
			call_id^ = id
		}
		return i32(st)
	}
	if cc != nil {
		free(cc, h.allocator)
	}
	if out != nil && out_len != nil && len(payload) > 0 {
		out^ = raw_data(payload)
		out_len^ = uint(len(payload))
	} else {
		delete(payload, h.allocator)
	}
	return i32(st)
}

@(private)
_on_call_done :: proc(data: rawptr, id: u64, st: api.Status, payload: []u8) {
	cc := (^Call_Ctx)(data)
	fn, ud := cc.fn, cc.ud
	free(cc, cc.h.allocator)
	fn(ud, id, i32(st), raw_data(payload), uint(len(payload)))
}

@(export, link_name = "ondb_cancel")
ondb_cancel :: proc "c" (h: ^Handle, call: u64) {
	if h == nil {
		return
	}
	context = _ctx()
	for c in h.s.a.calls {
		if c.id == call {
			if c.data != nil {
				free(c.data, h.allocator)
				c.data = nil
			}
			break
		}
	}
	api.cancel(&h.s.a, call)
}

@(private)
Sub_Ctx :: struct {
	fn: Sub_Fn,
	ud: rawptr,
}

@(export, link_name = "ondb_subscribe")
ondb_subscribe :: proc "c" (h: ^Handle, req: [^]u8, req_len: uint, flags: u32, fn: Sub_Fn, ud: rawptr, sub: ^u64) -> i32 {
	if h == nil || fn == nil || (req == nil && req_len > 0) {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sc := new(Sub_Ctx, h.allocator)
	sc^ = {fn, ud}
	id, st := api.subscribe(&h.s.a, req[:req_len], flags & FLAG_JSON != 0, _on_sub, sc)
	if st != .Ok {
		free(sc, h.allocator)
		return i32(st)
	}
	if sub != nil {
		sub^ = id
	}
	return 0
}

@(private)
_on_sub :: proc(data: rawptr, id: u64, payload: []u8) {
	sc := (^Sub_Ctx)(data)
	sc.fn(sc.ud, id, raw_data(payload), uint(len(payload)))
}

@(export, link_name = "ondb_unsubscribe")
ondb_unsubscribe :: proc "c" (h: ^Handle, sub: u64) {
	if h == nil {
		return
	}
	context = _ctx()
	for s in h.s.a.subs {
		if s.id == sub {
			free(s.data, h.allocator)
			break
		}
	}
	api.unsubscribe(&h.s.a, sub)
}

@(export, link_name = "ondb_describe")
ondb_describe :: proc "c" (h: ^Handle, flags: u32, out: ^[^]u8, out_len: ^uint) -> i32 {
	if h == nil || out == nil || out_len == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	b := api.describe(&h.s.a, flags & FLAG_JSON != 0, h.allocator)
	out^ = raw_data(b)
	out_len^ = uint(len(b))
	return 0
}

@(private)
_on_event :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Event) {
	h := (^Handle)(data)
	if h.events.event == nil {
		return
	}
	b := api.encode_event(ev, h.flags & CFG_EVENTS_JSON != 0)
	h.events.event(h.events.ud, raw_data(b), uint(len(b)))
}
