package api

import "core:strings"
import "core:sys/posix"
import "../../agent"
import eng "../../engine"
import "../../prim"
import rt "../../runtime"

MODELS_TTL_MS :: 5 * 60 * 1000
PROBE_TIMEOUT_MS :: 20_000

Live_Model :: struct {
	id:         string,
	name:       string,
	is_default: bool,
}

Live_Provider :: struct {
	id:     string,
	ok:     bool,
	error:  string,
	models: [dynamic]Live_Model,
}

Models_Cache :: struct {
	at_ms:     i64,
	providers: [dynamic]Live_Provider,
	probes:    [dynamic]^Probe,
	waiters:   [dynamic]u64,
}

Probe :: struct {
	api:      ^Api,
	slot:     int,
	d:        agent.Driver,
	d_on:     bool,
	child:    prim.Child,
	w_out:    prim.Watch,
	w_err:    prim.Watch,
	cw:       prim.Child_Watch,
	timer:    prim.Timer,
	lb:       prim.Line_Buffer,
	finished: bool,
}

@(private)
_models_reset :: proc(a: ^Api) {
	m := &a.models
	for &p in m.providers {
		delete(p.id, a.allocator)
		delete(p.error, a.allocator)
		for x in p.models {
			delete(x.id, a.allocator)
			delete(x.name, a.allocator)
		}
		delete(p.models)
	}
	clear(&m.providers)
}

models_destroy :: proc(a: ^Api) {
	m := &a.models
	for len(m.probes) > 0 {
		_probe_free(m.probes[len(m.probes) - 1])
	}
	_models_reset(a)
	delete(m.providers)
	delete(m.probes)
	delete(m.waiters)
}

@(private)
_models_fresh :: proc(a: ^Api) -> bool {
	m := &a.models
	return len(m.probes) == 0 && m.at_ms > 0 && prim.now_ms() - m.at_ms < MODELS_TTL_MS
}

@(private)
_models_start :: proc(a: ^Api, r: ^rt.Runtime) {
	m := &a.models
	if len(m.probes) > 0 {
		return
	}
	if m.providers == nil {
		m.providers = make([dynamic]Live_Provider, a.allocator)
		m.probes = make([dynamic]^Probe, a.allocator)
		m.waiters = make([dynamic]u64, a.allocator)
	}
	_models_reset(a)
	dir := strings.concatenate({r.cfg.work_root, "/.models"}, context.temp_allocator)
	prim.mkdir_all(prim.os_vfs(), dir, 0o700)
	for &desc in r.registry.list {
		if .List_Models not_in desc.capabilities || len(desc.argv) == 0 || !_on_path(desc.argv[0]) {
			continue
		}
		append(&m.providers, Live_Provider{id = strings.clone(desc.id, a.allocator), models = make([dynamic]Live_Model, a.allocator)})
		p := new(Probe, a.allocator)
		p.api = a
		p.slot = len(m.providers) - 1
		append(&m.probes, p)
		if err := _probe_start(p, r, desc, dir); len(err) > 0 {
			_probe_end(p, err)
		}
	}
	if len(m.probes) == 0 {
		m.at_ms = prim.now_ms()
	}
}

@(private)
_probe_start :: proc(p: ^Probe, r: ^rt.Runtime, desc: agent.Provider_Descriptor, dir: string) -> string {
	a := p.api
	req := agent.Start_Request {
		cwd     = dir,
		scratch = dir,
		access  = .Plan,
		clock   = a.e.cfg.clock,
		random  = a.e.cfg.random,
	}
	if agent.init_with(&p.d, desc, req, a.allocator) != .None {
		return "the driver cannot start"
	}
	p.d_on = true
	l := agent.launch(&p.d)
	for f in l.files {
		if prim.replace_atomic(prim.os_vfs(), f.path, f.data) != .None {
			return "cannot write launch files"
		}
	}
	sreq := rt.Spawn_Request{argv = l.argv, cwd = l.cwd, env = _env_merge(l.env), new_group = true}
	child, serr := r.cfg.spawner.spawn(r.cfg.spawner.data, &sreq)
	if serr != .None {
		return "cannot start the harness"
	}
	p.child = child
	prim.line_buffer_init(&p.lb, 64 * 1024, 16 << 20, a.allocator)
	loop := eng.loop(a.e)
	p.w_out, _ = prim.watch(loop, child.stdout, {.Read}, p, _probe_on_out)
	if child.stderr >= 0 {
		p.w_err, _ = prim.watch(loop, child.stderr, {.Read}, p, _probe_on_err)
	}
	p.cw, _ = prim.child_watch(loop, child.pid, p, _probe_on_exit)
	p.timer = prim.timer(loop, PROBE_TIMEOUT_MS, p, _probe_on_timeout)
	lm := agent.list_models(&p.d)
	_probe_write(p, l.stdin)
	_probe_write(p, lm.bytes[:])
	return ""
}

@(private)
_probe_write :: proc(p: ^Probe, b: []u8) {
	if len(b) > 0 && p.child.stdin >= 0 {
		prim.set_nonblocking(p.child.stdin, false)
		prim.write_all(p.child.stdin, b)
	}
}

@(private)
_probe_on_out :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	p := (^Probe)(data)
	for !p.finished {
		n, err := prim.line_fill(&p.lb, fd)
		for !p.finished {
			line, ok := prim.line_next(&p.lb)
			if !ok {
				break
			}
			out := agent.feed(&p.d, line)
			_probe_write(p, out.bytes[:])
			for e in out.events {
				if x, is_models := e.(agent.Models); is_models {
					pr := &p.api.models.providers[p.slot]
					for mm in x.models {
						append(&pr.models, Live_Model{id = strings.clone(mm.id, p.api.allocator), name = strings.clone(mm.name, p.api.allocator), is_default = mm.is_default})
					}
					_probe_end(p, "")
					return
				}
			}
		}
		if err == .Would_Block {
			return
		}
		if err != .None || n == 0 {
			_probe_end(p, "the harness closed its output before listing models")
			return
		}
	}
}

@(private)
_probe_on_err :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	buf: [4096]u8
	for {
		n := posix.read(posix.FD(fd), raw_data(buf[:]), len(buf))
		if n <= 0 {
			if n == 0 {
				p := (^Probe)(data)
				if p.w_err != 0 {
					prim.unwatch(l, p.w_err)
					p.w_err = 0
				}
			}
			return
		}
	}
}

@(private)
_probe_on_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	p := (^Probe)(data)
	p.cw = 0
	p.child.pid = 0
	_probe_end(p, "the harness exited before listing models")
}

@(private)
_probe_on_timeout :: proc(l: ^prim.Loop, data: rawptr) {
	p := (^Probe)(data)
	p.timer = 0
	_probe_end(p, "the harness did not list its models in time")
}

@(private)
_probe_end :: proc(p: ^Probe, err: string) {
	a := p.api
	m := &a.models
	if p.slot < len(m.providers) {
		pr := &m.providers[p.slot]
		pr.ok = len(err) == 0
		if len(err) > 0 && len(pr.error) == 0 {
			pr.error = strings.clone(err, a.allocator)
		}
	}
	_probe_free(p)
	if len(m.probes) > 0 {
		return
	}
	m.at_ms = prim.now_ms()
	ids := make([]u64, len(m.waiters), context.temp_allocator)
	copy(ids, m.waiters[:])
	clear(&m.waiters)
	for id in ids {
		for c in a.calls {
			if c.id == id {
				_rerun(c)
				break
			}
		}
	}
}

@(private)
_probe_free :: proc(p: ^Probe) {
	a := p.api
	loop := eng.loop(a.e)
	p.finished = true
	for x, i in a.models.probes {
		if x == p {
			ordered_remove(&a.models.probes, i)
			break
		}
	}
	if p.timer != 0 {
		prim.timer_cancel(loop, p.timer)
	}
	if p.w_out != 0 {
		prim.unwatch(loop, p.w_out)
	}
	if p.w_err != 0 {
		prim.unwatch(loop, p.w_err)
	}
	if p.cw != 0 {
		prim.child_unwatch(loop, p.cw)
	}
	if p.child.pid > 0 {
		prim.child_kill(&p.child, .Kill)
		status: i32
		posix.waitpid(posix.pid_t(p.child.pid), &status, {})
	}
	prim.child_close(&p.child)
	if p.lb.data != nil {
		prim.line_buffer_destroy(&p.lb)
	}
	if p.d_on {
		agent.destroy(&p.d)
	}
	free(p, a.allocator)
}

@(private)
_env_merge :: proc(env: []string) -> []string {
	if len(env) == 0 {
		return nil
	}
	out := make([dynamic]string, context.temp_allocator)
	base := posix.environ
	for i := 0; base != nil && base[i] != nil; i += 1 {
		s := string(base[i])
		eq := strings.index_byte(s, '=')
		name := s[:eq] if eq >= 0 else s
		over := false
		for e in env {
			over ||= strings.has_prefix(e, name) && len(e) > len(name) && e[len(name)] == '='
		}
		if !over {
			append(&out, s)
		}
	}
	append(&out, ..env)
	return out[:]
}
