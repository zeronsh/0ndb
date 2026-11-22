package rt

import "base:runtime"
import "core:crypto/blake2b"
import "core:mem/virtual"
import "core:strings"
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
	Takeover,
	Intent,
	Revive,
	Schedule,
	Channel,
}

Placement :: struct {
	kind:     Placement_Kind,
	object:   Object,
	msg:      Rid,
	sender:   prim.Id,
	agent:    prim.Id,
	provider: string,
	policy:   []u8,
	exclude:  prim.Id,
	prefer:   prim.Id,
}

Placement_State :: enum u8 {
	None,
	Assigned,
	Running,
	Waiting_Runner,
	Idle,
	Placing,
}

Placement_Info :: struct {
	state:    Placement_State,
	msg:      Rid,
	runner:   prim.Id,
	provider:    string,
	since_ms:    i64,
	last_runner: prim.Id,
}

Scheduler :: struct {
	data:   rawptr,
	place:  proc(data: rawptr, r: ^Runtime, p: ^Placement) -> prim.Id,
	ask:    proc(data: rawptr, r: ^Runtime, p: ^Placement, token: u64),
	cancel: proc(data: rawptr, r: ^Runtime, token: u64),
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
	data:      rawptr,
	sealed:    proc(data: rawptr, r: ^Runtime, o: Object, reply: Rid, status: convo.Seal_Status),
	event:     proc(data: rawptr, r: ^Runtime, name: string, o: Object),
	placement: proc(data: rawptr, r: ^Runtime, o: Object, info: Placement_Info),
	runners:   proc(data: rawptr, r: ^Runtime, space: prim.Id),
	observed:  proc(data: rawptr, r: ^Runtime, o: Object),
}

Config :: struct {
	runner:           bool,
	pool:             bool,
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
	name:             string,
	host_name:        string,
	default_provider: string,
	default_model:    string,
	default_runner:   prim.Id,
	capacity:         int,
	lease_ms:         u64,
	warm_max:         int,
	warm_idle_ms:     i64,
	interrupt_ms:     i64,
	claim_wait_ms:    i64,
	mcp_http:         bool,
	mcp_port:         int,
	catalog_command:  []string,
	home_dir:         string,
	env:              []string,
}

DEFAULT_LEASE_MS :: 10 * 60 * 1000
DEFAULT_WARM_IDLE_MS :: 5 * 60 * 1000
DEFAULT_WARM_MAX :: 4
DEFAULT_INTERRUPT_MS :: 10_000
DEFAULT_CAPACITY :: 16
DEFAULT_CLAIM_WAIT_MS :: 60 * 1000

Stats :: struct {
	runs_started:  u64,
	runs_finished: u64,
	runs_held:     u64,
	runs_resumed:  u64,
	evaluations:   u64,
	spawns:        u64,
	warm_hits:     u64,
	raw_lines:     u64,
	tool_calls:    u64,
	schedules:     u64,
	warmups:       u64,
	takeovers:     u64,
	inexact:       u64,
	quiesces:      u64,
	quiesce_held:  u64,
	timers:        int,
}

@(private)
Space_Watch :: struct {
	space:     prim.Id,
	catalog:   eng.Sub_Id,
	schedules: eng.Sub_Id,
	runners:   eng.Sub_Id,
}

@(private)
Lease_Watch :: struct {
	object:   Object,
	msg:      Rid,
	activity: prim.Hlc,
	seen:     i64,
	at:       i64,
	sub:      eng.Sub_Id,
	runner:   prim.Id,
	claim:    bool,
}

@(private)
Revive_Wait :: struct {
	object: Object,
}

@(private)
Follow :: struct {
	object: Object,
	sub:    eng.Sub_Id,
	fresh:  bool,
	timer:  prim.Timer,
	grace:  ^Follow_Grace,
}

@(private)
Follow_Grace :: struct {
	r:   ^Runtime,
	sub: eng.Sub_Id,
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
	leases:      [dynamic]Lease_Watch,
	follows:     [dynamic]Follow,
	revives:     [dynamic]Revive_Wait,
	catchups:    [dynamic]Object,
	quiesce:     Quiesce_State,
	lease_timer: prim.Timer,
	lease_at:    i64,
	prev_events: eng.Event_Hook,
	hooked:      bool,
	asks:        [dynamic]Ask,
	hold_waits:  [dynamic]^Hold_Wait,
	stats:       Stats,
}

open :: proc(r: ^Runtime, e: ^eng.Engine, cfg: Config, allocator := context.allocator) -> Error {
	context = eng.context_for(e)
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
	if r.cfg.claim_wait_ms <= 0 {
		r.cfg.claim_wait_ms = DEFAULT_CLAIM_WAIT_MS
	}
	r.cfg.work_root = clone(cfg.work_root, allocator)
	r.cfg.default_provider = clone(cfg.default_provider, allocator)
	r.cfg.name = clone(cfg.name, allocator)
	r.cfg.host_name = clone(cfg.host_name, allocator)
	r.cfg.default_model = clone(cfg.default_model, allocator)
	r.cfg.home_dir = clone(cfg.home_dir if len(cfg.home_dir) > 0 else _home_default(cfg.env), allocator)
	if len(cfg.env) > 0 {
		env := make([]string, len(cfg.env), allocator)
		for s, i in cfg.env {
			env[i] = clone(s, allocator)
		}
		r.cfg.env = env
	}
	if len(cfg.catalog_command) > 0 {
		cc := make([]string, len(cfg.catalog_command), allocator)
		for x, i in cfg.catalog_command {
			cc[i] = clone(x, allocator)
		}
		r.cfg.catalog_command = cc
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
	r.leases = make([dynamic]Lease_Watch, allocator)
	r.follows = make([dynamic]Follow, allocator)
	r.revives = make([dynamic]Revive_Wait, allocator)
	r.catchups = make([dynamic]Object, allocator)
	r.asks = make([dynamic]Ask, allocator)
	agent.registry_init(&r.registry, allocator)
	r.prev_events = e.cfg.events
	e.cfg.events = eng.Event_Hook{data = r, event = _on_engine_event}
	r.hooked = true
	r.opened = true
	eng.set_tick_hook(e, eng.Tick_Hook{data = r, call = _on_tick_hook})
	return .None
}

@(private)
_home_default :: proc(env: []string) -> string {
	for kv in env {
		if strings.has_prefix(kv, "HOME=") {
			return kv[5:]
		}
	}
	h, _ := prim.getenv("HOME")
	return h
}

@(private)
_on_engine_event :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Event) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	if !r.closing {
		#partial switch ev.kind {
		case .Presence:
			_presence_changed(r, ev.space, ev.device, ev.tick != 0)
		case .Connected:
			_pending_scan(r, ev.space)
		case .Caught_Up:
			readvertise(r, ev.space)
			_catchup_run(r, ev.space)
			for w in r.revives {
				if w.object.space == ev.space {
					_queue_eval(r, w.object)
				}
			}
			_pending_scan(r, ev.space)
		}
	}
	if r.prev_events.event != nil {
		r.prev_events.event(r.prev_events.data, e, ev)
	}
}

@(private)
_presence_changed :: proc(r: ^Runtime, space: prim.Id, device: prim.Id, up: bool) {
	attached := false
	for sw in r.spaces {
		attached ||= sw.space == space
	}
	if !attached {
		return
	}
	_asks_forget(r, space)
	_runners_changed(r, space)
	_sched_rearm(r)
	if up {
		_pending_scan(r, space)
		return
	}
	for w in r.leases {
		if w.object.space == space {
			_queue_eval(r, w.object)
		}
	}
	_pending_scan(r, space, device)
}

close :: proc(r: ^Runtime) {
	context = eng.context_for(r.e)
	if !r.opened {
		return
	}
	r.closing = true
	eng.set_tick_hook(r.e, {})
	l := eng.loop(r.e)
	if r.hooked && r.e.cfg.events.data == r {
		r.e.cfg.events = r.prev_events
		r.hooked = false
	}
	for len(r.runs) > 0 {
		run := r.runs[len(r.runs) - 1]
		_run_abandon(run)
	}
	_hold_waits_close(r)
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
		if sw.runners != 0 {
			eng.unsubscribe(r.e, sw.runners)
		}
	}
	for w in r.waits {
		eng.cancel_waits(r.e, w)
		free(w, r.allocator)
	}
	if r.warm_timer != 0 {
		prim.timer_cancel(l, r.warm_timer)
	}
	if r.sched_timer != 0 {
		prim.timer_cancel(l, r.sched_timer)
	}
	if r.lease_timer != 0 {
		prim.timer_cancel(l, r.lease_timer)
	}
	_quiesce_destroy(r)
	for w in r.leases {
		if w.sub != 0 {
			eng.unsubscribe(r.e, w.sub)
		}
	}
	delete(r.leases)
	for f in r.follows {
		eng.unsubscribe(r.e, f.sub)
		if f.timer != 0 {
			prim.timer_cancel(l, f.timer)
		}
		free(f.grace, r.allocator)
	}
	delete(r.follows)
	delete(r.revives)
	delete(r.catchups)
	_asks_close(r)
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
	delete(r.cfg.name, r.allocator)
	delete(r.cfg.host_name, r.allocator)
	delete(r.cfg.default_model, r.allocator)
	delete(r.cfg.home_dir, r.allocator)
	for s in r.cfg.env {
		delete(s, r.allocator)
	}
	delete(r.cfg.env, r.allocator)
	for x in r.cfg.catalog_command {
		delete(x, r.allocator)
	}
	delete(r.cfg.catalog_command, r.allocator)
	r.opened = false
}

runner_name :: proc(r: ^Runtime) -> string {
	if len(r.cfg.name) > 0 {
		return r.cfg.name
	}
	if acct := eng.account_state(r.e); acct.have && len(acct.label) > 0 {
		return acct.label
	}
	return r.cfg.host_name
}

readvertise_all :: proc(r: ^Runtime) {
	context = eng.context_for(r.e)
	if !r.cfg.runner {
		return
	}
	for sw in r.spaces {
		_advertise(r, sw.space, r.cfg.capacity)
	}
}

readvertise :: proc(r: ^Runtime, space: prim.Id) {
	context = eng.context_for(r.e)
	if !r.cfg.runner {
		return
	}
	for sw in r.spaces {
		if sw.space == space {
			_advertise(r, space, r.cfg.capacity)
			return
		}
	}
}

attach :: proc(r: ^Runtime, space: prim.Id) -> Error {
	context = eng.context_for(r.e)
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
	rid, rerr := eng.subscribe(r.e, runners_object(space), .Map, _on_runners, r)
	if rerr == .None {
		sw.runners = rid
	}
	append(&r.spaces, sw)
	if r.cfg.runner {
		_advertise(r, space, r.cfg.capacity)
		_recover(r, space)
		_quiesce_holds_queue(r, space)
		_quiesce_wake_scan(r, space)
	}
	_pending_scan(r, space)
	if len(map_rows(r, state_object(r, space), transmute([]u8)string("trig/"), 1)) > 0 {
		r.triggers = true
	}
	_sched_rearm(r)
	return .None
}

detach :: proc(r: ^Runtime, space: prim.Id) {
	context = eng.context_for(r.e)
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
		if sw.runners != 0 {
			eng.unsubscribe(r.e, sw.runners)
		}
		if r.cfg.runner {
			_advertise(r, space, 0)
		}
		ordered_remove(&r.spaces, i)
		_sched_rearm(r)
		return
	}
}

stats :: proc(r: ^Runtime) -> Stats {
	s := r.stats
	n := 0
	if r.warm_timer != 0 {
		n += 1
	}
	if r.sched_timer != 0 {
		n += 1
	}
	if r.lease_timer != 0 {
		n += 1
	}
	if r.quiesce.timer != 0 {
		n += 1
	}
	s.timers = n
	return s
}

active_runs :: proc(r: ^Runtime) -> int {
	context = eng.context_for(r.e)
	return len(r.runs)
}

warm_processes :: proc(r: ^Runtime) -> int {
	context = eng.context_for(r.e)
	n := 0
	for p in r.procs {
		if p.run == nil {
			n += 1
		}
	}
	return n
}

wake :: proc(r: ^Runtime, o: Object) {
	context = eng.context_for(r.e)
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
	append(&b, ':')
	jw_int(&b, i64(rid.gen))
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
	gen: u64
	second := false
	for c in s[33:] {
		if c == ':' && !second {
			second = true
			continue
		}
		if c < '0' || c > '9' {
			return {}, false
		}
		if second {
			gen = gen * 10 + u64(c - '0')
		} else {
			n = n * 10 + i64(c - '0')
		}
	}
	return Rid{seg, n, gen}, true
}

@(private)
_on_catalog :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	seen := make([dynamic]Object, context.temp_allocator)
	outer: for &d in deltas {
		if d.kind != .Catalog || len(d.key) != 16 {
			continue
		}
		id: prim.Id
		copy(id[:], d.key)
		o := Object{d.object.space, id}
		for x in seen {
			if x == o {
				continue outer
			}
		}
		append(&seen, o)
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
	eng.request_tick(r.e)
}

@(private)
_on_tick_hook :: proc(data: rawptr, e: ^eng.Engine) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	if r.closing || len(r.pending) == 0 {
		return
	}
	list := make([]Object, len(r.pending), context.temp_allocator)
	copy(list, r.pending[:])
	clear(&r.pending)
	for o in list {
		r.stats.evaluations += 1
		evaluate(r, o)
		if r.cfg.hooks.observed != nil {
			r.cfg.hooks.observed(r.cfg.hooks.data, r, o)
		}
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
_wait_drop :: proc(r: ^Runtime, ready: eng.Ready) {
	if ready.call != _on_ready || ready.data == nil {
		return
	}
	w := (^Eval_Wait)(ready.data)
	for x, i in r.waits {
		if x == w {
			ordered_remove(&r.waits, i)
			free(w, r.allocator)
			return
		}
	}
}

@(private)
_on_ready :: proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
	context = eng.context_for((^Eval_Wait)(data).r.e)
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
	if err != .None {
		return
	}
	if o == pending_object(o.space) {
		_pending_scan(r, o.space)
		return
	}
	if o == eng.space_catalog(r.e, o.space) {
		_quiesce_wake_scan(r, o.space)
		return
	}
	_queue_eval(r, o)
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
	env := req.env
	if e.cfg.spawner.spawn == nil {
		env = _env_merge(req.env)
	}
	return sp.spawn(sp.data, req.argv, req.cwd, env, req.new_group)
}

spawn_child :: proc(r: ^Runtime, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	context.allocator = r.allocator
	return r.cfg.spawner.spawn(r.cfg.spawner.data, req)
}

default_scheduler :: proc() -> Scheduler {
	return Scheduler{place = _default_place}
}

@(private)
_default_place :: proc(data: rawptr, r: ^Runtime, p: ^Placement) -> prim.Id {
	context = eng.context_for(r.e)
	space := p.object.space
	if !prim.id_is_zero(p.prefer) && p.prefer != p.exclude && (runner_live(r, space, p.prefer, p.provider) || (runner_pool(r, space, p.prefer) && !runner_live(r, space, p.prefer, "")) || is_pool_id(r, space, p.prefer)) {
		return p.prefer
	}
	if !prim.id_is_zero(p.sender) && p.sender != p.exclude && runner_live(r, space, p.sender, p.provider) {
		return p.sender
	}
	if id, ok := policy_runner(p.policy); ok && id != p.exclude {
		return id
	}
	if !prim.id_is_zero(r.cfg.default_runner) && r.cfg.default_runner != p.exclude {
		return r.cfg.default_runner
	}
	if p.kind == .Takeover && runner_live(r, space, r.self, p.provider) {
		return r.self
	}
	for id in convo_runners(r, p.object, p.msg) {
		if id != p.exclude && runner_live(r, space, id, p.provider) {
			return id
		}
	}
	for id in runners_live(r, space, p.provider) {
		if id != p.exclude {
			return id
		}
	}
	return {}
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
	x, _ := place_decided(r, p)
	return x
}

@(private)
_secret :: proc(r: ^Runtime, name: string, allocator := context.temp_allocator) -> (string, bool) {
	if r.cfg.secrets.get != nil {
		return r.cfg.secrets.get(r.cfg.secrets.data, name, allocator)
	}
	return "", false
}

