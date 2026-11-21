package rt

import "base:runtime"
import "core:crypto/blake2b"
import "core:mem/virtual"
import "../agent"
import "../convo"
import eng "../engine"
import "../model"
import "../obj"
import "../observe"
import "../prim"

Object :: eng.Object
Rid :: obj.Rid

Error :: enum u8 {
	None,
	Invalid,
	Not_Found,
	Busy,
	Pending,
	Unsupported,
	Closed,
	Limit,
	Io,
	Engine,
	Spawn,
	Permission,
	Conflict,
	Cancelled,
	Budget,
	Not_Assigned,
}

Spawn_Request :: struct {
	argv:      []string,
	cwd:       string,
	env:       []string,
	new_group: bool,
	observe:   bool,
}

Spawner :: struct {
	data:  rawptr,
	spawn: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error),
}

Placement_Kind :: enum u8 {
	Message,
	Intent,
	Revive,
	Schedule,
	Channel,
}

Placement :: struct {
	kind:   Placement_Kind,
	object: Object,
	msg:    Rid,
	sender: prim.Id,
	agent:  prim.Id,
	policy: []u8,
}

Scheduler :: struct {
	data:  rawptr,
	place: proc(data: rawptr, r: ^Runtime, p: ^Placement) -> prim.Id,
}

Model_Plug :: struct {
	data:    rawptr,
	resolve: proc(data: rawptr, r: ^Runtime, provider: string, model_id: string, cfg: ^model.Config, m: ^model.Model) -> bool,
}

Tool_Call :: struct {
	id:     string,
	name:   string,
	input:  string,
	object: Object,
	agent:  ^Agent_Info,
	cwd:    string,
	token:  u64,
}

Tools :: struct {
	data:  rawptr,
	list:  proc(data: rawptr, r: ^Runtime, a: ^Agent_Info, out: ^[dynamic]model.Tool_Def),
	call:  proc(data: rawptr, r: ^Runtime, call: ^Tool_Call) -> bool,
	abort: proc(data: rawptr, r: ^Runtime, token: u64),
}

Channels :: struct {
	data: rawptr,
	send: proc(data: rawptr, r: ^Runtime, channel: string, key: string, o: Object, text: string),
}

Providers :: struct {
	data:     rawptr,
	lookup:   proc(data: rawptr, id: string) -> (agent.Provider_Descriptor, bool),
	mcp_args: proc(data: rawptr, desc: ^agent.Provider_Descriptor, url: string, token: string, out: ^[dynamic]string) -> bool,
}

Secrets :: struct {
	data: rawptr,
	get:  proc(data: rawptr, name: string, allocator: runtime.Allocator) -> (string, bool),
}

Homes :: struct {
	data: rawptr,
	home: proc(data: rawptr, tree: prim.Id, allocator: runtime.Allocator) -> (string, bool),
}

Hooks :: struct {
	data:   rawptr,
	sealed: proc(data: rawptr, r: ^Runtime, o: Object, reply: Rid, status: convo.Seal_Status),
	event:  proc(data: rawptr, r: ^Runtime, name: string, o: Object),
}

Config :: struct {
	runner:           bool,
	work_root:        string,
	scheduler:        Scheduler,
	spawner:          Spawner,
	model:            Model_Plug,
	tools:            Tools,
	channels:         Channels,
	providers:        Providers,
	secrets:          Secrets,
	homes:            Homes,
	hooks:            Hooks,
	default_provider: string,
	default_model:    string,
	default_runner:   prim.Id,
	capacity:         int,
	lease_ms:         u64,
	warm_max:         int,
	warm_idle_ms:     i64,
	interrupt_ms:     i64,
	mcp_http:         bool,
	mcp_port:         int,
	home_dir:         string,
	env:              []string,
}

DEFAULT_LEASE_MS :: 10 * 60 * 1000
DEFAULT_WARM_IDLE_MS :: 5 * 60 * 1000
DEFAULT_WARM_MAX :: 4
DEFAULT_INTERRUPT_MS :: 10_000
DEFAULT_CAPACITY :: 16

Stats :: struct {
	runs_started:  u64,
	runs_finished: u64,
	evaluations:   u64,
	spawns:        u64,
	warm_hits:     u64,
	raw_lines:     u64,
	tool_calls:    u64,
	schedules:     u64,
	timers:        int,
}

@(private)
Space_Watch :: struct {
	space:     prim.Id,
	catalog:   eng.Sub_Id,
	schedules: eng.Sub_Id,
}

@(private)
Eval_Wait :: struct {
	r:      ^Runtime,
	object: Object,
}

Runtime :: struct {
	e:           ^eng.Engine,
	cfg:         Config,
	allocator:   runtime.Allocator,
	self:        prim.Id,
	opened:      bool,
	closing:     bool,
	spaces:      [dynamic]Space_Watch,
	pending:     [dynamic]Object,
	eval_timer:  prim.Timer,
	waits:       [dynamic]^Eval_Wait,
	runs:        [dynamic]^Run,
	procs:       [dynamic]^Proc,
	warm_timer:  prim.Timer,
	warm_at:     i64,
	jobs:        [dynamic]^Job,
	awaits:      [dynamic]^Await_Wait,
	sched_timer: prim.Timer,
	sched_at:    i64,
	registry:    agent.Registry,
	serve:       Serve,
	clients:     [dynamic]^Mcp_Conn,
	warmer:      model.Warmer,
	warmer_on:   bool,
	router:      observe.Router,
	router_on:   bool,
	next_token:  u64,
	triggers:    bool,
	stats:       Stats,
}

open :: proc(r: ^Runtime, e: ^eng.Engine, cfg: Config, allocator := context.allocator) -> Error {
	r^ = {
		e         = e,
		cfg       = cfg,
		allocator = allocator,
		self      = eng.self(e),
	}
	if r.cfg.lease_ms == 0 {
		r.cfg.lease_ms = DEFAULT_LEASE_MS
	}
	if r.cfg.warm_idle_ms <= 0 {
		r.cfg.warm_idle_ms = DEFAULT_WARM_IDLE_MS
	}
	if r.cfg.warm_max < 0 {
		r.cfg.warm_max = 0
	} else if r.cfg.warm_max == 0 {
		r.cfg.warm_max = DEFAULT_WARM_MAX
	}
	if r.cfg.interrupt_ms <= 0 {
		r.cfg.interrupt_ms = DEFAULT_INTERRUPT_MS
	}
	if r.cfg.capacity <= 0 {
		r.cfg.capacity = DEFAULT_CAPACITY
	}
	r.cfg.work_root = clone(cfg.work_root, allocator)
	r.cfg.default_provider = clone(cfg.default_provider, allocator)
	r.cfg.default_model = clone(cfg.default_model, allocator)
	r.cfg.home_dir = clone(cfg.home_dir, allocator)
	if len(cfg.env) > 0 {
		env := make([]string, len(cfg.env), allocator)
		for s, i in cfg.env {
			env[i] = clone(s, allocator)
		}
		r.cfg.env = env
	}
	if len(r.cfg.work_root) == 0 {
		r.cfg.work_root = clone(concat(e.dir, "/work"), allocator)
	}
	if r.cfg.spawner.spawn == nil {
		r.cfg.spawner = engine_spawner(e)
	}
	if r.cfg.scheduler.place == nil {
		r.cfg.scheduler = default_scheduler()
	}
	r.spaces = make([dynamic]Space_Watch, allocator)
	r.pending = make([dynamic]Object, allocator)
	r.waits = make([dynamic]^Eval_Wait, allocator)
	r.runs = make([dynamic]^Run, allocator)
	r.procs = make([dynamic]^Proc, allocator)
	r.jobs = make([dynamic]^Job, allocator)
	r.awaits = make([dynamic]^Await_Wait, allocator)
	r.clients = make([dynamic]^Mcp_Conn, allocator)
	agent.registry_init(&r.registry, allocator)
	r.opened = true
	return .None
}

close :: proc(r: ^Runtime) {
	if !r.opened {
		return
	}
	r.closing = true
	l := eng.loop(r.e)
	for len(r.runs) > 0 {
		run := r.runs[len(r.runs) - 1]
		_run_abandon(run)
	}
	for len(r.procs) > 0 {
		_proc_free(r.procs[len(r.procs) - 1], true)
	}
	for len(r.jobs) > 0 {
		_job_free(r.jobs[len(r.jobs) - 1], true)
	}
	for len(r.awaits) > 0 {
		_await_free(r, r.awaits[len(r.awaits) - 1])
	}
	for len(r.clients) > 0 {
		_mcp_conn_free(r.clients[len(r.clients) - 1])
	}
	serve_close(r)
	for sw in r.spaces {
		if sw.catalog != 0 {
			eng.unsubscribe(r.e, sw.catalog)
		}
		if sw.schedules != 0 {
			eng.unsubscribe(r.e, sw.schedules)
		}
	}
	for w in r.waits {
		eng.cancel_waits(r.e, w)
		free(w, r.allocator)
	}
	if r.eval_timer != 0 {
		prim.timer_cancel(l, r.eval_timer)
	}
	if r.warm_timer != 0 {
		prim.timer_cancel(l, r.warm_timer)
	}
	if r.sched_timer != 0 {
		prim.timer_cancel(l, r.sched_timer)
	}
	if r.warmer_on {
		model.warmer_destroy(&r.warmer)
	}
	if r.router_on {
		observe.router_destroy(&r.router)
	}
	agent.registry_destroy(&r.registry)
	delete(r.spaces)
	delete(r.pending)
	delete(r.waits)
	delete(r.runs)
	delete(r.procs)
	delete(r.jobs)
	delete(r.awaits)
	delete(r.clients)
	delete(r.cfg.work_root, r.allocator)
	delete(r.cfg.default_provider, r.allocator)
	delete(r.cfg.default_model, r.allocator)
	delete(r.cfg.home_dir, r.allocator)
	for s in r.cfg.env {
		delete(s, r.allocator)
	}
	delete(r.cfg.env, r.allocator)
	r.opened = false
}

attach :: proc(r: ^Runtime, space: prim.Id) -> Error {
	for sw in r.spaces {
		if sw.space == space {
			return .None
		}
	}
	sw := Space_Watch {
		space = space,
	}
	cid, cerr := eng.subscribe_catalog(r.e, space, _on_catalog, r)
	if cerr != .None {
		return .Engine
	}
	sw.catalog = cid
	sid, serr := eng.subscribe(r.e, schedules_object(space), .Map, _on_schedules, r)
	if serr == .None {
		sw.schedules = sid
	}
	append(&r.spaces, sw)
	if r.cfg.runner {
		_advertise(r, space)
		_recover(r, space)
	}
	if len(map_rows(r, state_object(r, space), transmute([]u8)string("trig/"), 1)) > 0 {
		r.triggers = true
	}
	_sched_rearm(r)
	return .None
}

detach :: proc(r: ^Runtime, space: prim.Id) {
	for sw, i in r.spaces {
		if sw.space != space {
			continue
		}
		if sw.catalog != 0 {
			eng.unsubscribe(r.e, sw.catalog)
		}
		if sw.schedules != 0 {
			eng.unsubscribe(r.e, sw.schedules)
		}
		ordered_remove(&r.spaces, i)
		_sched_rearm(r)
		return
	}
}

stats :: proc(r: ^Runtime) -> Stats {
	s := r.stats
	n := 0
	if r.eval_timer != 0 {
		n += 1
	}
	if r.warm_timer != 0 {
		n += 1
	}
	if r.sched_timer != 0 {
		n += 1
	}
	s.timers = n
	return s
}

active_runs :: proc(r: ^Runtime) -> int {
	return len(r.runs)
}

warm_processes :: proc(r: ^Runtime) -> int {
	n := 0
	for p in r.procs {
		if p.run == nil {
			n += 1
		}
	}
	return n
}

wake :: proc(r: ^Runtime, o: Object) {
	_queue_eval(r, o)
}

wall_ms :: proc(r: ^Runtime) -> i64 {
	return prim.clock_wall_ms(r.e.cfg.clock)
}

mono_ns :: proc(r: ^Runtime) -> i64 {
	return prim.loop_now_ns(eng.loop(r.e))
}

new_id :: proc(r: ^Runtime) -> prim.Id {
	return eng.new_id(r.e)
}

derive_id :: proc(label: string, parts: ..[]u8) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, transmute([]u8)label)
	for p in parts {
		blake2b.update(&ctx, p)
	}
	blake2b.final(&ctx, id[:])
	id[6] = (id[6] & 0x0f) | 0x80
	return
}

id_bytes :: proc(id: ^prim.Id) -> []u8 {
	return id[:]
}

hex :: proc(id: prim.Id, allocator := context.temp_allocator) -> string {
	h := prim.id_hex(id)
	return clone(string(h[:]), allocator)
}

parse_id :: proc(s: string) -> (id: prim.Id, ok: bool) {
	return prim.id_parse(s)
}

rid_text :: proc(rid: Rid, allocator := context.temp_allocator) -> string {
	h := prim.id_hex(rid.seg)
	b := make(Buf, allocator)
	append(&b, string(h[:]))
	append(&b, ':')
	jw_int(&b, rid.off)
	return string(b[:])
}

parse_rid :: proc(s: string) -> (rid: Rid, ok: bool) {
	if len(s) < 34 || s[32] != ':' {
		return {}, false
	}
	seg, sok := prim.id_parse(s[:32])
	if !sok {
		return {}, false
	}
	n: i64
	for c in s[33:] {
		if c < '0' || c > '9' {
			return {}, false
		}
		n = n * 10 + i64(c - '0')
	}
	return Rid{seg, n}, true
}

@(private)
_on_catalog :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	r := (^Runtime)(data)
	for &d in deltas {
		if d.kind != .Catalog || len(d.key) != 16 {
			continue
		}
		id: prim.Id
		copy(id[:], d.key)
		o := Object{d.object.space, id}
		_queue_eval(r, o)
		_await_touched(r, o)
		_trigger_touched(r, o)
	}
}

@(private)
_queue_eval :: proc(r: ^Runtime, o: Object) {
	if r.closing {
		return
	}
	for p in r.pending {
		if p == o {
			return
		}
	}
	append(&r.pending, o)
	if r.eval_timer == 0 {
		r.eval_timer = prim.timer(eng.loop(r.e), 0, r, _on_eval_timer)
	}
}

@(private)
_on_eval_timer :: proc(l: ^prim.Loop, data: rawptr) {
	r := (^Runtime)(data)
	r.eval_timer = 0
	list := make([]Object, len(r.pending), context.temp_allocator)
	copy(list, r.pending[:])
	clear(&r.pending)
	for o in list {
		r.stats.evaluations += 1
		evaluate(r, o)
	}
}

@(private)
_wait_ready :: proc(r: ^Runtime, o: Object) -> eng.Ready {
	for w in r.waits {
		if w.object == o {
			return eng.Ready{}
		}
	}
	w := new(Eval_Wait, r.allocator)
	w.r = r
	w.object = o
	append(&r.waits, w)
	return eng.Ready{data = w, call = _on_ready}
}

@(private)
_on_ready :: proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
	w := (^Eval_Wait)(data)
	r := w.r
	o := w.object
	for x, i in r.waits {
		if x == w {
			ordered_remove(&r.waits, i)
			break
		}
	}
	free(w, r.allocator)
	if err == .None {
		_queue_eval(r, o)
	}
}

@(private)
_arena_init :: proc(a: ^virtual.Arena) -> bool {
	return virtual.arena_init_growing(a, 16 << 10) == nil
}

engine_spawner :: proc(e: ^eng.Engine) -> Spawner {
	return Spawner{data = e, spawn = _engine_spawn}
}

@(private)
_engine_spawn :: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	e := (^eng.Engine)(data)
	sp := eng.spawner(e)
	return sp.spawn(sp.data, req.argv, req.cwd, _env_merge(req.env), req.new_group)
}

default_scheduler :: proc() -> Scheduler {
	return Scheduler{place = _default_place}
}

@(private)
_default_place :: proc(data: rawptr, r: ^Runtime, p: ^Placement) -> prim.Id {
	if !prim.id_is_zero(p.sender) && runner_known(r, p.object.space, p.sender) {
		return p.sender
	}
	if id, ok := policy_runner(p.policy); ok {
		return id
	}
	if !prim.id_is_zero(r.cfg.default_runner) {
		return r.cfg.default_runner
	}
	return p.sender
}

policy_runner :: proc(policy: []u8) -> (id: prim.Id, ok: bool) {
	if len(policy) == 16 {
		copy(id[:], policy)
		return id, !prim.id_is_zero(id)
	}
	if len(policy) == 32 {
		return prim.id_parse(string(policy))
	}
	v, pok := json_parse(string(policy))
	if !pok {
		return {}, false
	}
	if s := jstr(v, "runner"); len(s) == 32 {
		return prim.id_parse(s)
	}
	return {}, false
}

place :: proc(r: ^Runtime, p: ^Placement) -> prim.Id {
	return r.cfg.scheduler.place(r.cfg.scheduler.data, r, p)
}

@(private)
_secret :: proc(r: ^Runtime, name: string, allocator := context.temp_allocator) -> (string, bool) {
	if r.cfg.secrets.get != nil {
		return r.cfg.secrets.get(r.cfg.secrets.data, name, allocator)
	}
	return "", false
}

