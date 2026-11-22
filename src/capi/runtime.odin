package capi

import "base:runtime"
import "core:strings"
import "./api"
import "../model"
import "../prim"
import rt "../runtime"
import osync "../sync"

RT_RUNNER :: u32(1 << 0)
RT_OBSERVE :: u32(1 << 1)
RT_MCP_HTTP :: u32(1 << 2)
RT_NO_ATTACH :: u32(1 << 3)
RT_POOL :: u32(1 << 4)

C_Model_Config :: struct {
	api:            u32,
	url:            cstring,
	url_len:        uint,
	api_key:        cstring,
	api_key_len:    uint,
	bearer:         i32,
	max_tokens:     u64,
	context_window: u64,
	max_output:     u64,
	wire:           ^C_Wire,
}

C_Model :: struct {
	size:    u32,
	ud:      rawptr,
	resolve: proc "c" (ud: rawptr, provider: cstring, provider_len: uint, model: cstring, model_len: uint, out: ^C_Model_Config) -> i32,
}

C_Tool_Def :: struct {
	name:            cstring,
	name_len:        uint,
	description:     cstring,
	description_len: uint,
	schema:          cstring,
	schema_len:      uint,
}

C_Tool_Call :: struct {
	token:     u64,
	space:     [16]u8,
	object:    [16]u8,
	agent:     [16]u8,
	id:        cstring,
	id_len:    uint,
	name:      cstring,
	name_len:  uint,
	input:     cstring,
	input_len: uint,
	cwd:       cstring,
	cwd_len:   uint,
}

C_Tools :: struct {
	size:  u32,
	ud:    rawptr,
	list:  proc "c" (ud: rawptr, space: ^[16]u8, agent: ^[16]u8, out: [^]C_Tool_Def, cap: uint) -> uint,
	call:  proc "c" (ud: rawptr, h: ^Handle, call: ^C_Tool_Call) -> i32,
	abort: proc "c" (ud: rawptr, token: u64),
}

C_Channels :: struct {
	size: u32,
	ud:   rawptr,
	send: proc "c" (ud: rawptr, channel: cstring, channel_len: uint, key: cstring, key_len: uint, space: ^[16]u8, object: ^[16]u8, text: cstring, text_len: uint),
}

C_Placement :: struct {
	kind:         u32,
	space:        [16]u8,
	object:       [16]u8,
	msg_seg:      [16]u8,
	msg_off:      i64,
	sender:       [16]u8,
	agent:        [16]u8,
	policy:       [^]u8,
	policy_len:   uint,
	msg_gen:      u64,
	exclude:      [16]u8,
	prefer:       [16]u8,
	provider:     cstring,
	provider_len: uint,
}

C_Scheduler :: struct {
	size:   u32,
	ud:     rawptr,
	place:  proc "c" (ud: rawptr, p: ^C_Placement, call: ^Plug_Call),
	cancel: proc "c" (ud: rawptr, call: ^Plug_Call),
}

C_Secrets :: struct {
	size: u32,
	ud:   rawptr,
	get:  proc "c" (ud: rawptr, name: cstring, name_len: uint, out: [^]u8, cap: uint, len: ^uint) -> i32,
}

C_Runtime :: struct {
	size:             u32,
	flags:            u32,
	work_root:        cstring,
	default_provider: cstring,
	default_model:    cstring,
	home_dir:         cstring,
	capacity:         i32,
	warm_max:         i32,
	warm_idle_ms:     i64,
	interrupt_ms:     i64,
	lease_ms:         u64,
	mcp_port:         i32,
	default_runner:   [16]u8,
	model:            ^C_Model,
	tools:            ^C_Tools,
	channels:         ^C_Channels,
	scheduler:        ^C_Scheduler,
	secrets:          ^C_Secrets,
	name:             cstring,
}

Rt_Plugs :: struct {
	model:     C_Model,
	tools:     C_Tools,
	channels:  C_Channels,
	scheduler: C_Scheduler,
	secrets:   C_Secrets,
	interned:  map[string]string,
	wires:     [dynamic]^Wire_Ctx,
}

@(private)
_str :: proc(c: cstring) -> string {
	return string(c) if c != nil else ""
}

runtime_config :: proc(h: ^Handle, c: ^C_Runtime) -> (opts: api.Stack_Options, st: api.Status) {
	if c == nil {
		return {}, .Ok
	}
	if c.size < u32(offset_of(C_Runtime, model)) {
		return {}, .Invalid
	}
	x: C_Runtime
	n := min(int(c.size), size_of(C_Runtime))
	runtime.mem_copy(&x, c, n)
	p := &h.rt
	p.interned = make(map[string]string, h.allocator)
	p.wires = make([dynamic]^Wire_Ctx, h.allocator)
	opts.runtime = true
	opts.observe = x.flags & RT_OBSERVE != 0
	opts.attach = x.flags & RT_NO_ATTACH == 0
	rc := &opts.rt_cfg
	rc.runner = x.flags & RT_RUNNER != 0
	rc.mcp_http = x.flags & RT_MCP_HTTP != 0
	rc.pool = x.flags & RT_POOL != 0
	rc.work_root = _str(x.work_root)
	rc.default_provider = _str(x.default_provider)
	rc.default_model = _str(x.default_model)
	rc.home_dir = _str(x.home_dir)
	rc.capacity = int(x.capacity)
	rc.warm_max = int(x.warm_max)
	rc.warm_idle_ms = x.warm_idle_ms
	rc.interrupt_ms = x.interrupt_ms
	rc.lease_ms = x.lease_ms
	rc.mcp_port = int(x.mcp_port)
	rc.default_runner = prim.Id(x.default_runner)
	if c.size >= u32(offset_of(C_Runtime, name)) + size_of(cstring) {
		rc.name = _str(x.name)
	}
	if x.model != nil {
		if !_copy_table(&p.model, x.model) || p.model.resolve == nil {
			return opts, .Invalid
		}
		rc.model = rt.Model_Plug{data = h, resolve = _model_resolve}
	}
	if x.tools != nil {
		if !_copy_table(&p.tools, x.tools) || p.tools.list == nil || p.tools.call == nil {
			return opts, .Invalid
		}
		rc.tools = rt.Tools{data = h, list = _tools_list, call = _tools_call, abort = _tools_abort}
	}
	if x.channels != nil {
		if !_copy_table(&p.channels, x.channels) || p.channels.send == nil {
			return opts, .Invalid
		}
		rc.channels = rt.Channels{data = h, send = _channels_send}
	}
	if x.scheduler != nil {
		if !_copy_table(&p.scheduler, x.scheduler) || p.scheduler.place == nil {
			return opts, .Invalid
		}
		rc.scheduler = rt.Scheduler{data = h, place = _scheduler_reference, ask = _scheduler_ask, cancel = _scheduler_cancel}
	}
	if x.secrets != nil {
		if !_copy_table(&p.secrets, x.secrets) || p.secrets.get == nil {
			return opts, .Invalid
		}
		rc.secrets = rt.Secrets{data = h, get = _secrets_get}
	}
	if h.plugs.spawner.spawn != nil {
		rc.spawner = rt.Spawner{data = &h.plugs.spawner, spawn = _rt_spawn}
	}
	return opts, .Ok
}

runtime_destroy :: proc(h: ^Handle) {
	for k, v in h.rt.interned {
		delete(k, h.allocator)
		delete(v, h.allocator)
	}
	delete(h.rt.interned)
	for w in h.rt.wires {
		free(w, h.allocator)
	}
	delete(h.rt.wires)
}

@(private)
_intern :: proc(h: ^Handle, s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	if v, ok := h.rt.interned[s]; ok {
		return v
	}
	k := strings.clone(s, h.allocator)
	v := strings.clone(s, h.allocator)
	h.rt.interned[k] = v
	return v
}

@(private)
_cslice :: proc(p: cstring, n: uint) -> string {
	if p == nil {
		return ""
	}
	return strings.string_from_ptr((^u8)(p), int(n))
}

@(private)
_model_resolve :: proc(data: rawptr, r: ^rt.Runtime, provider: string, model_id: string, cfg: ^model.Config, m: ^model.Model) -> bool {
	h := (^Handle)(data)
	pp, pn := _cstr(provider)
	mp, mn := _cstr(model_id)
	out: C_Model_Config
	if h.rt.model.resolve(h.rt.model.ud, pp, pn, mp, mn, &out) != 0 {
		return false
	}
	a := model.Api.Anthropic
	if out.api <= u32(max(model.Api)) {
		a = model.Api(out.api)
	}
	id := model_id if len(model_id) > 0 else model.DEFAULT_ANTHROPIC_MODEL
	spec, ok := model.spec_lookup(id)
	if !ok || spec.api != a {
		spec = model.custom_spec(_intern(h, id), a, out.context_window if out.context_window > 0 else 200_000, out.max_output if out.max_output > 0 else 32_000)
	}
	cfg^ = model.Config {
		spec       = spec,
		url        = _intern(h, _cslice(out.url, out.url_len)),
		api_key    = _intern(h, _cslice(out.api_key, out.api_key_len)),
		bearer     = out.bearer != 0,
		max_tokens = out.max_tokens,
	}
	if out.wire != nil {
		wm, wok := wire_model(h, out.wire, a)
		if !wok {
			return false
		}
		m^ = wm
		return true
	}
	m^ = model.model_for(a)
	return true
}

@(private)
_tools_list :: proc(data: rawptr, r: ^rt.Runtime, a: ^rt.Agent_Info, out: ^[dynamic]model.Tool_Def) {
	h := (^Handle)(data)
	t := &h.rt.tools
	space, agent: [16]u8
	if a != nil {
		space = ([16]u8)(a.object.space)
		agent = ([16]u8)(a.object.id)
	}
	buf: [64]C_Tool_Def
	n := t.list(t.ud, &space, &agent, raw_data(buf[:]), len(buf))
	defs := buf[:]
	if n > len(buf) {
		big := make([]C_Tool_Def, n, context.temp_allocator)
		n = t.list(t.ud, &space, &agent, raw_data(big), uint(len(big)))
		defs = big
	}
	for d in defs[:min(n, uint(len(defs)))] {
		append(out, model.Tool_Def{name = _intern(h, _cslice(d.name, d.name_len)), description = _intern(h, _cslice(d.description, d.description_len)), schema = _intern(h, _cslice(d.schema, d.schema_len))})
	}
}

@(private)
_tools_call :: proc(data: rawptr, r: ^rt.Runtime, call: ^rt.Tool_Call) -> bool {
	h := (^Handle)(data)
	t := &h.rt.tools
	c := C_Tool_Call {
		token  = call.token,
		space  = ([16]u8)(call.object.space),
		object = ([16]u8)(call.object.id),
	}
	if call.agent != nil {
		c.agent = ([16]u8)(call.agent.object.id)
	}
	c.id, c.id_len = _cstr(call.id)
	c.name, c.name_len = _cstr(call.name)
	c.input, c.input_len = _cstr(call.input)
	c.cwd, c.cwd_len = _cstr(call.cwd)
	return t.call(t.ud, h, &c) != 0
}

@(private)
_tools_abort :: proc(data: rawptr, r: ^rt.Runtime, token: u64) {
	h := (^Handle)(data)
	if h.rt.tools.abort != nil {
		h.rt.tools.abort(h.rt.tools.ud, token)
	}
}

@(export, link_name = "ondb_tool_result")
ondb_tool_result :: proc "c" (h: ^Handle, space: ^[16]u8, object: ^[16]u8, id: [^]u8, id_len: uint, text: [^]u8, text_len: uint, is_error: i32) -> i32 {
	if h == nil || space == nil || object == nil || id == nil || (text == nil && text_len > 0) {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if !h.s.r_on {
		return i32(api.Status.Unsupported)
	}
	call := rt.Tool_Call {
		id     = string(id[:id_len]),
		object = api.Object{prim.Id(space^), prim.Id(object^)},
	}
	t := ""
	if text != nil {
		t = string(text[:text_len])
	}
	rt.tool_result(&h.s.r, &call, t, is_error != 0)
	return 0
}

@(private)
_channels_send :: proc(data: rawptr, r: ^rt.Runtime, channel: string, key: string, o: api.Object, text: string) {
	h := (^Handle)(data)
	c := &h.rt.channels
	cp, cn := _cstr(channel)
	kp, kn := _cstr(key)
	tp, tn := _cstr(text)
	sp := ([16]u8)(o.space)
	ob := ([16]u8)(o.id)
	c.send(c.ud, cp, cn, kp, kn, &sp, &ob, tp, tn)
}

@(private)
Sched_Ctx :: struct {
	h:     ^Handle,
	token: u64,
}

@(private)
_scheduler_reference :: proc(data: rawptr, r: ^rt.Runtime, p: ^rt.Placement) -> prim.Id {
	return rt.default_scheduler().place(nil, r, p)
}

@(private)
_scheduler_ask :: proc(data: rawptr, r: ^rt.Runtime, p: ^rt.Placement, token: u64) {
	h := (^Handle)(data)
	s := &h.rt.scheduler
	cp := C_Placement {
		kind       = u32(p.kind),
		space      = ([16]u8)(p.object.space),
		object     = ([16]u8)(p.object.id),
		msg_seg    = ([16]u8)(p.msg.seg),
		msg_off    = p.msg.off,
		sender     = ([16]u8)(p.sender),
		agent      = ([16]u8)(p.agent),
		policy     = raw_data(p.policy),
		policy_len = uint(len(p.policy)),
		msg_gen    = p.msg.gen,
		exclude    = ([16]u8)(p.exclude),
		prefer     = ([16]u8)(p.prefer),
	}
	cp.provider, cp.provider_len = _cstr(p.provider)
	ctx := new(Sched_Ctx, runtime.heap_allocator())
	ctx^ = Sched_Ctx{h, token}
	ap := &h.plugs.account
	pc := _pc_new(ap, .Scheduler, osync.Plug_Done{data = ctx, call = _scheduler_done})
	s.place(s.ud, &cp, pc)
	reply: osync.Plug_Reply
	err := _pc_settle(ap, pc, &reply)
	if err != .Pending {
		_scheduler_done(ctx, err, &reply)
	}
}

@(private)
_scheduler_done :: proc(data: rawptr, err: osync.Error, reply: ^osync.Plug_Reply) {
	ctx := (^Sched_Ctx)(data)
	h, token := ctx.h, ctx.token
	free(ctx, runtime.heap_allocator())
	if !h.s.r_on {
		return
	}
	if err == .None {
		rt.placed(&h.s.r, token, reply.runner, true)
	} else {
		rt.placed(&h.s.r, token, {}, false)
	}
}

@(private)
_scheduler_cancel :: proc(data: rawptr, r: ^rt.Runtime, token: u64) {
	h := (^Handle)(data)
	ap := &h.plugs.account
	for pc in ap.calls {
		if pc.kind != .Scheduler {
			continue
		}
		ctx := (^Sched_Ctx)(pc.done.data)
		if ctx.token == token {
			_pc_cancel(ap, pc.done)
			free(ctx, runtime.heap_allocator())
			return
		}
	}
}

@(private)
_secrets_get :: proc(data: rawptr, name: string, allocator: runtime.Allocator) -> (string, bool) {
	h := (^Handle)(data)
	s := &h.rt.secrets
	np, nn := _cstr(name)
	buf: [8192]u8
	n: uint
	if s.get(s.ud, np, nn, raw_data(buf[:]), len(buf), &n) != 0 || n > len(buf) {
		return "", false
	}
	out := strings.clone(string(buf[:n]), allocator)
	runtime.mem_zero(&buf, size_of(buf))
	return out, true
}

@(private)
_rt_spawn :: proc(data: rawptr, req: ^rt.Spawn_Request) -> (prim.Child, prim.Error) {
	flags: u32
	if req.new_group {
		flags |= SPAWN_NEW_GROUP
	}
	if req.observe {
		flags |= SPAWN_OBSERVE
	}
	return spawn_with(data, req.argv, req.cwd, req.env, flags)
}
