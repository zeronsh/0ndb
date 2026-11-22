package api

import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import eng "../../engine"
import "../../prim"
import rt "../../runtime"

Stack_Options :: struct {
	runtime: bool,
	observe: bool,
	attach:  bool,
	rt_cfg:  rt.Config,
	host:    Host,
	placement: Placement_Hook,
}

Placement_Hook :: struct {
	data: rawptr,
	call: proc(data: rawptr, o: Object, info: rt.Placement_Info),
}

Stack :: struct {
	allocator: runtime.Allocator,
	loop:      prim.Loop,
	loop_on:   bool,
	e:         eng.Engine,
	e_on:      bool,
	r:         rt.Runtime,
	r_on:      bool,
	a:         Api,
	a_on:      bool,
	obs:       Observer,
	obs_on:    bool,
	spawner:   rt.Spawner,
	placement: Placement_Hook,
	thread:    ^thread.Thread,
	running:   bool,
	stop_mu:   sync.Mutex,
	joined:    [dynamic]prim.Id,
}

stack_open :: proc(s: ^Stack, ec: eng.Config, opts: Stack_Options, allocator := context.allocator) -> (st: Status) {
	s^ = {
		allocator = allocator,
		joined    = make([dynamic]prim.Id, allocator),
	}
	defer if st != .Ok {
		stack_close(s)
	}
	if err := prim.loop_init(&s.loop, allocator); err != .None {
		return .Io
	}
	s.loop_on = true
	prim.loop_set_clock(&s.loop, ec.clock)
	cfg := ec
	cfg.loop = &s.loop
	if opts.runtime && opts.observe && cfg.write_observer.start == nil {
		if _observer_init(s) {
			s.obs_on = true
			cfg.write_observer = _observer_plug(s)
		}
	}
	if opts.runtime && cfg.purge.purge == nil {
		cfg.purge = eng.Purge_Hook{data = s, purge = _purge}
	}
	if err := eng.open(&s.e, cfg, allocator); err != .None {
		return status_of(err)
	}
	s.e_on = true
	rp: ^rt.Runtime
	if opts.runtime {
		rc := opts.rt_cfg
		if opts.placement.call != nil && rc.hooks.placement == nil {
			s.placement = opts.placement
			rc.hooks.data = s
			rc.hooks.placement = _on_placement
		}
		if rc.secrets.get == nil {
			rc.secrets = rt.Secrets{get = _env_secret}
		}
		if err := rt.open(&s.r, &s.e, rc, allocator); err != .None {
			return .Io
		}
		s.r_on = true
		rp = &s.r
		if s.obs_on && opts.rt_cfg.spawner.spawn == nil {
			s.spawner = _observer_spawner(s)
			s.r.cfg.spawner = s.spawner
			_observer_sink(s)
		}
	}
	init(&s.a, &s.e, rp, opts.host, allocator)
	s.a_on = true
	if opts.runtime && opts.attach {
		for sp in eng.space_list(&s.e, context.temp_allocator) {
			rt.attach(&s.r, sp.id)
		}
	}
	return .Ok
}

stack_close :: proc(s: ^Stack) -> Status {
	stack_stop(s)
	if s.a_on {
		destroy(&s.a)
		s.a_on = false
	}
	if s.r_on {
		if s.obs_on {
			_observer_unsink(s)
		}
		rt.close(&s.r)
		if s.spawner.spawn != nil {
			_observer_spawner_free(s)
			s.spawner = {}
		}
		s.r_on = false
	}
	err: eng.Error
	if s.e_on {
		err = eng.close(&s.e)
		s.e_on = false
	}
	if s.obs_on {
		_observer_destroy(s)
		s.obs_on = false
	}
	if s.loop_on {
		prim.loop_destroy(&s.loop)
		s.loop_on = false
	}
	delete(s.joined)
	s.joined = nil
	return status_of(err)
}

stack_start :: proc(s: ^Stack) -> Status {
	if s.running {
		return .Busy
	}
	t := thread.create(_stack_thread)
	if t == nil {
		return .No_Memory
	}
	t.data = s
	t.init_context = context
	s.thread = t
	s.running = true
	thread.start(t)
	return .Ok
}

stack_stop :: proc(s: ^Stack) {
	if !s.running {
		return
	}
	eng.post(&s.e, proc(e: ^eng.Engine, data: rawptr) {
		x := (^Stack)(data)
		eng.flush(e)
		prim.loop_stop(&x.loop)
	}, s)
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
	s.running = false
}

@(private)
_stack_thread :: proc(t: ^thread.Thread) {
	s := (^Stack)(t.data)
	context.allocator = s.allocator
	for !prim.loop_stopped(&s.loop) {
		if prim.loop_step(&s.loop, true) != .None {
			break
		}
		stack_attach_joined(s)
	}
}

stack_space_joined :: proc(s: ^Stack, space: prim.Id) {
	append(&s.joined, space)
}

stack_attach_joined :: proc(s: ^Stack) {
	if len(s.joined) == 0 {
		return
	}
	if s.r_on {
		for id in s.joined {
			rt.attach(&s.r, id)
			rt.readvertise(&s.r, id)
		}
	}
	clear(&s.joined)
}

stack_attach_space :: proc(s: ^Stack, space: prim.Id) {
	if s.r_on {
		rt.attach(&s.r, space)
	}
}

@(private)
_on_placement :: proc(data: rawptr, r: ^rt.Runtime, o: Object, info: rt.Placement_Info) {
	s := (^Stack)(data)
	if s.placement.call != nil {
		s.placement.call(s.placement.data, o, info)
	}
}

@(private)
_purge :: proc(data: rawptr, e: ^eng.Engine, req: ^eng.Purge_Request) {
	s := (^Stack)(data)
	if !s.r_on {
		return
	}
	h := rt.purge_hook(&s.r)
	if h.purge != nil {
		h.purge(h.data, e, req)
	}
}

@(private)
_env_secret :: proc(data: rawptr, name: string, allocator: runtime.Allocator) -> (string, bool) {
	v, found := os.lookup_env(name, allocator)
	if !found || len(v) == 0 {
		delete(v, allocator)
		return "", false
	}
	return v, true
}
