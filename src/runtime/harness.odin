package rt

import "core:sys/posix"
import "core:strings"
import "../agent"
import "../convo"
import eng "../engine"
import omap "../map"
import "../obj"
import "../prim"

@(private)
KEY_NATIVE :: "native"
@(private)
ERR_TAIL :: 8192

Native_Info :: struct {
	provider:   string,
	session:    string,
	runner:     prim.Id,
	head:       Rid,
	cwd:        string,
	manifest:   string,
	home:       string,
	native:     string,
	checkpoint: string,
}

Proc :: struct {
	r:          ^Runtime,
	o:          Object,
	d:          agent.Driver,
	d_on:       bool,
	desc:       agent.Provider_Descriptor,
	key:        string,
	child:      prim.Child,
	alive:      bool,
	w_out:      prim.Watch,
	w_err:      prim.Watch,
	w_in:       prim.Watch,
	cw:         prim.Child_Watch,
	lb_out:     prim.Line_Buffer,
	lb_err:     prim.Line_Buffer,
	inq:        [dynamic]u8,
	err_tail:   [dynamic]u8,
	run:        ^Run,
	ws:         ^Worktree,
	idle_since: i64,
	cwd:        string,
	token:      string,
	extra:      []string,
	closing:    bool,
	kill_timer: prim.Timer,
}

native_get :: proc(r: ^Runtime, o: Object) -> (n: Native_Info, found: bool) {
	en, ok := map_read(r, meta_object(o), transmute([]u8)string(KEY_NATIVE))
	if !ok {
		return {}, false
	}
	n.provider = entry_str(&en, 1)
	n.session = entry_str(&en, 2)
	n.runner = entry_id(&en, 3)
	n.head = entry_rid(&en, 4)
	n.cwd = entry_str(&en, 5)
	n.manifest = entry_str(&en, 6)
	n.home = entry_str(&en, 7)
	n.native = entry_str(&en, 8)
	n.checkpoint = entry_str(&en, 9)
	return n, len(n.provider) > 0
}

native_put :: proc(r: ^Runtime, o: Object, n: Native_Info) {
	map_put(r, meta_object(o), transmute([]u8)string(KEY_NATIVE), omap.field_str(1, n.provider), omap.field_str(2, n.session), omap.field_id(3, n.runner), field_rid(4, n.head), omap.field_str(5, n.cwd), omap.field_str(6, n.manifest), omap.field_str(7, n.home), omap.field_str(8, n.native), omap.field_str(9, n.checkpoint))
}

proc_for :: proc(r: ^Runtime, o: Object) -> ^Proc {
	for p in r.procs {
		if p.o == o && !p.closing {
			return p
		}
	}
	return nil
}

@(private)
_proc_key :: proc(run: ^Run, cwd: string) -> string {
	a := &run.ai
	acc := "full"
	switch a.access {
	case .Plan:
		acc = "plan"
	case .Edit:
		acc = "edit"
	case .Full:
	}
	return concat(a.provider, "|", a.model, "|", a.effort, "|", acc, "|", "ask" if a.ask_permissions else "auto", "|", cwd)
}

harness_start :: proc(run: ^Run) -> Error {
	r := run.r
	desc, ok := _descriptor(r, run.ai.provider)
	if !ok {
		return .Not_Found
	}
	cwd := ""
	if run.ws != nil {
		cwd = run.ws.root
	} else {
		id := run.o.id
		cwd = concat(r.cfg.work_root, "/", hex(id))
		prim.mkdir_all(r.e.base, cwd, 0o755)
	}
	ni, has_ni := native_get(r, run.o)
	same := has_ni && ni.provider == desc.id && len(ni.session) > 0
	resume := ""
	rewind: agent.Rewind_Target
	seed: []agent.Seed_Entry
	if same && ni.runner != r.self {
		if s, iok := port_import(r, run.o, desc, &ni, cwd); iok {
			ni.session = s
		} else {
			same = false
		}
	}
	if same {
		if run.revive || run.parent == ni.head {
			resume = ni.session
		} else if obj.rid_none(run.parent) {
			rewind = agent.Rewind_Target{session = ni.session}
		} else if cp := _checkpoint_of(r, run.o, run.parent, desc.id); len(cp) > 0 {
			rewind = agent.Rewind_Target{session = ni.session, after = cp, head = ni.checkpoint}
			rewind.seed = transcript_seed(r, run.o, run.parent)
		} else {
			seed = transcript_seed(r, run.o, run.parent)
		}
	} else if !obj.rid_none(run.parent) {
		seed = transcript_seed(r, run.o, run.parent)
	}
	key := _proc_key(run, cwd)
	if p := proc_for(r, run.o); p != nil {
		reusable := p.alive && p.run == nil && p.key == key && len(rewind.session) == 0 && len(seed) == 0 && (len(resume) == 0 || resume == p.d.session)
		if reusable {
			r.stats.warm_hits += 1
			p.run = run
			run.proc_ = p
			if p.ws != nil && p.ws != run.ws {
				worktree_close(p.ws)
				p.ws = nil
			}
			if run.ws != nil {
				worktree_add_pid(run.ws, p.child.pid)
			}
			_proc_prompt(p, run)
			_warm_arm(r)
			return .None
		}
		if p.ws == run.ws {
			p.ws = nil
		}
		_proc_close(p)
	}
	p := new(Proc, r.allocator)
	p.r = r
	p.o = run.o
	p.cwd = clone(cwd, r.allocator)
	p.key = clone(key, r.allocator)
	p.inq = make([dynamic]u8, r.allocator)
	p.err_tail = make([dynamic]u8, r.allocator)
	prim.line_buffer_init(&p.lb_out, 64 * 1024, 64 << 20, r.allocator)
	prim.line_buffer_init(&p.lb_err, 4096, 1 << 20, r.allocator)
	append(&r.procs, p)
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..r.cfg.env)
	req := agent.Start_Request {
		cwd             = cwd,
		model           = run.ai.model,
		effort          = run.ai.effort,
		access          = run.ai.access,
		ask_permissions = run.ai.ask_permissions,
		resume          = resume,
		checkpoint      = ni.checkpoint if same else "",
		rewind          = rewind,
		seed            = seed,
		env             = env[:],
	}
	if agent.init_with(&p.d, desc, req, r.allocator) != .None {
		_proc_free(p, false)
		return .Invalid
	}
	p.d_on = true
	p.desc = p.d.desc
	if run.ai.catalog {
		if url, token, sok := serve_http_token(r, run.o); sok && r.cfg.providers.mcp_args != nil {
			extra := make([dynamic]string, context.temp_allocator)
			if r.cfg.providers.mcp_args(r.cfg.providers.data, &p.desc, url, token, &extra) {
				p.token = clone(token, r.allocator)
				list := make([]string, len(extra), r.allocator)
				for s, i in extra {
					list[i] = clone(s, r.allocator)
				}
				p.extra = list
			} else {
				serve_revoke(r, token)
			}
		}
	}
	p.run = run
	run.proc_ = p
	if err := _proc_spawn(p); err != .None {
		run.proc_ = nil
		p.run = nil
		_proc_free(p, false)
		return err
	}
	_proc_prompt(p, run)
	return .None
}

@(private)
_proc_spawn :: proc(p: ^Proc) -> Error {
	r := p.r
	l := agent.launch(&p.d)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, ..l.argv)
	append(&argv, ..p.extra)
	req := Spawn_Request {
		argv      = argv[:],
		cwd       = l.cwd if len(l.cwd) > 0 else p.cwd,
		env       = l.env,
		new_group = true,
		observe   = p.run == nil || p.run.ai.observe,
	}
	child, serr := r.cfg.spawner.spawn(r.cfg.spawner.data, &req)
	if serr != .None {
		return .Spawn
	}
	r.stats.spawns += 1
	p.child = child
	p.alive = true
	prim.line_buffer_reset(&p.lb_out)
	prim.line_buffer_reset(&p.lb_err)
	lp := eng.loop(r.e)
	if child.stdout >= 0 {
		prim.set_nonblocking(child.stdout)
		p.w_out, _ = prim.watch(lp, child.stdout, {.Read}, p, _proc_on_out)
	}
	if child.stderr >= 0 {
		prim.set_nonblocking(child.stderr)
		p.w_err, _ = prim.watch(lp, child.stderr, {.Read}, p, _proc_on_err)
	}
	if child.stdin >= 0 {
		prim.set_nonblocking(child.stdin)
	}
	p.cw, _ = prim.child_watch(lp, child.pid, p, _proc_on_exit)
	if p.run != nil {
		if p.run.ws != nil {
			worktree_add_pid(p.run.ws, child.pid)
		}
		b := make(Buf, context.temp_allocator)
		append(&b, "spawn ")
		for a, i in argv {
			if i > 0 {
				append(&b, ' ')
			}
			append(&b, a)
		}
		run_raw(p.run, RAW_META, b[:])
	}
	_proc_write(p, l.stdin)
	return .None
}

@(private)
_proc_prompt :: proc(p: ^Proc, run: ^Run) {
	id := rid_uuid(run.reply if run.revive else run.user)
	out := agent.send(&p.d, run.text, id, run.files)
	_proc_output(p, &out)
}

proc_steer :: proc(p: ^Proc, text: string, id: string, files: []agent.Attachment) -> bool {
	if .Native_Steer not_in p.desc.capabilities || !p.alive {
		return false
	}
	out := agent.steer(&p.d, text, id, files)
	_proc_output(p, &out)
	return true
}

proc_interrupt :: proc(p: ^Proc) {
	if !p.alive {
		if p.run != nil {
			run_finish(p.run, .Interrupted)
		}
		return
	}
	out := agent.interrupt(&p.d)
	_proc_output(p, &out)
}

proc_answer :: proc(p: ^Proc, id: string, allow: bool) {
	out := agent.answer_permission(&p.d, id, .Allow if allow else .Deny)
	_proc_output(p, &out)
}

proc_kill :: proc(p: ^Proc) {
	if p.alive {
		prim.child_kill(&p.child, .Kill)
	}
}

@(private)
_proc_write :: proc(p: ^Proc, data: []u8) {
	if len(data) == 0 || !p.alive || p.child.stdin < 0 {
		return
	}
	if p.run != nil {
		run_raw(p.run, RAW_STDIN, data)
	}
	append(&p.inq, ..data)
	_proc_flush(p)
}

@(private)
_proc_flush :: proc(p: ^Proc) {
	r := p.r
	lp := eng.loop(r.e)
	for len(p.inq) > 0 && p.child.stdin >= 0 {
		n, err := prim.write(p.child.stdin, p.inq[:])
		if err == .Interrupted {
			continue
		}
		if err == .Would_Block {
			if p.w_in == 0 {
				p.w_in, _ = prim.watch(lp, p.child.stdin, {.Write}, p, _proc_on_in)
			}
			return
		}
		if err != .None || n <= 0 {
			clear(&p.inq)
			break
		}
		remove_range(&p.inq, 0, n)
	}
	if p.w_in != 0 {
		prim.unwatch(lp, p.w_in)
		p.w_in = 0
	}
}

@(private)
_proc_on_in :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	_proc_flush((^Proc)(data))
}

@(private)
_proc_on_out :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	p := (^Proc)(data)
	for p.alive || p.child.stdout >= 0 {
		n, err := prim.line_fill(&p.lb_out, fd)
		if err == .Would_Block || err == .Interrupted {
			break
		}
		eof := err != .None || n == 0
		if eof {
			prim.line_finish(&p.lb_out)
		}
		_proc_lines(p)
		if eof {
			if p.w_out != 0 {
				prim.unwatch(l, p.w_out)
				p.w_out = 0
			}
			break
		}
	}
	if p.run != nil {
		run_raw_commit(p.run)
	}
}

@(private)
_proc_lines :: proc(p: ^Proc) {
	for {
		line, ok := prim.line_next(&p.lb_out)
		if !ok {
			return
		}
		if p.run != nil {
			run_raw(p.run, RAW_STDOUT, line)
		}
		out := agent.feed(&p.d, line)
		_proc_output(p, &out)
		if p.closing && p.run == nil && !p.alive {
			return
		}
	}
}

@(private)
_proc_on_err :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	p := (^Proc)(data)
	for {
		n, err := prim.line_fill(&p.lb_err, fd)
		if err == .Would_Block || err == .Interrupted {
			break
		}
		eof := err != .None || n == 0
		if eof {
			prim.line_finish(&p.lb_err)
		}
		for {
			line, ok := prim.line_next(&p.lb_err)
			if !ok {
				break
			}
			if p.run != nil {
				run_raw(p.run, RAW_STDERR, line)
			}
			append(&p.err_tail, ..line)
			append(&p.err_tail, '\n')
			if len(p.err_tail) > ERR_TAIL {
				remove_range(&p.err_tail, 0, len(p.err_tail) - ERR_TAIL)
			}
		}
		if eof {
			if p.w_err != 0 {
				prim.unwatch(l, p.w_err)
				p.w_err = 0
			}
			break
		}
	}
}

@(private)
_proc_on_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	p := (^Proc)(data)
	r := p.r
	p.cw = 0
	if p.w_out != 0 && p.child.stdout >= 0 {
		_proc_on_out(l, p.child.stdout, {.Read}, p)
	}
	prim.line_finish(&p.lb_out)
	_proc_lines(p)
	p.alive = false
	if p.w_out != 0 {
		prim.unwatch(l, p.w_out)
		p.w_out = 0
	}
	if p.w_err != 0 {
		prim.unwatch(l, p.w_err)
		p.w_err = 0
	}
	if p.w_in != 0 {
		prim.unwatch(l, p.w_in)
		p.w_in = 0
	}
	if p.kill_timer != 0 {
		prim.timer_cancel(l, p.kill_timer)
		p.kill_timer = 0
	}
	prim.child_close(&p.child)
	clear(&p.inq)
	msg := ""
	if status.code != 0 || status.signal != 0 {
		tail := strings.trim_space(string(p.err_tail[:]))
		if len(tail) > 0 {
			msg = tail
		}
	}
	if p.run != nil {
		meta := make(Buf, context.temp_allocator)
		append(&meta, "exit ")
		jw_int(&meta, i64(status.code))
		append(&meta, ' ')
		jw_int(&meta, i64(status.signal))
		run_raw(p.run, RAW_META, meta[:])
	}
	out := agent.process_exited(&p.d, msg)
	if out.restart && p.run != nil && !p.closing {
		if len(msg) > 0 {
			run_notice(p.run, concat("the agent exited while resuming its session: ", msg))
		}
		for e in out.events {
			_proc_event(p, e)
		}
		clear(&p.err_tail)
		if _proc_spawn(p) == .None {
			return
		}
		if p.run != nil {
			run_error(p.run, "the agent could not be restarted")
			run_finish(p.run, .Failed)
		}
		return
	}
	_proc_output(p, &out)
	if p.run != nil {
		run := p.run
		run_error(run, msg if len(msg) > 0 else "the agent process exited")
		run_finish(run, .Interrupted if run.interrupting else .Failed)
	}
	if !p.closing {
		_proc_free(p, false)
		_warm_arm(r)
	} else {
		_proc_free(p, false)
	}
}

@(private)
_proc_output :: proc(p: ^Proc, out: ^agent.Output) {
	if len(out.bytes) > 0 {
		_proc_write(p, out.bytes[:])
	}
	for e in out.events {
		_proc_event(p, e)
	}
	if out.close_stdin && p.child.stdin >= 0 {
		_proc_flush(p)
		if len(p.inq) == 0 {
			prim.child_close_stdin(&p.child)
		}
	}
	if out.restart && p.alive && p.run != nil {
		prim.child_kill(&p.child, .Terminate)
	}
}

@(private)
_proc_event :: proc(p: ^Proc, e: agent.Event) {
	r := p.r
	run := p.run
	#partial switch ev in e {
	case agent.Session_Started:
		ni, _ := native_get(r, p.o)
		ni.provider = p.desc.id
		ni.session = ev.session
		ni.runner = r.self
		ni.cwd = p.cwd
		ni.home = r.cfg.home_dir
		ni.native = agent.session_path(&p.d)
		native_put(r, p.o, ni)
	}
	if run == nil {
		return
	}
	switch ev in e {
	case agent.Session_Started:
	case agent.Session_Failed:
		run_error(run, ev.message)
	case agent.Turn_Started:
	case agent.Prompt_Accepted:
		if ev.steer {
			run_steer_accepted(run, ev.id)
		}
	case agent.Prompt_Dropped:
		run_steer_dropped(run, ev.id)
	case agent.Message_Started:
		run.steps += 1
		run.cur = -1
		_run_budget_check(run)
	case agent.Text_Delta:
		run_text(run, .Text, ev.text)
	case agent.Reasoning_Delta:
		run_text(run, .Reasoning, ev.text)
	case agent.Tool_Started:
		run_tool_started(run, ev.id, ev.name, ev.input, ev.parent)
	case agent.Tool_Updated:
		if ev.append && len(ev.input) > 0 {
			run_tool_input(run, ev.id, ev.input)
		}
	case agent.Tool_Finished:
		run_tool_finished(run, ev.id, ev.output, ev.is_error)
	case agent.Permission_Request:
		run_permission(run, ev.id, ev.tool, ev.title, ev.input, ev.answered)
	case agent.Usage:
		run_usage(run, ev)
	case agent.Turn_Finished:
		run.checkpoint = clone(ev.checkpoint, run.alloc)
		status: convo.Seal_Status = .Done if ev.status == .Done && !run.interrupting else .Interrupted
		run_finish(run, status)
	case agent.Turn_Failed:
		run.checkpoint = clone(ev.checkpoint, run.alloc)
		run_error(run, ev.message)
		run_finish(run, .Interrupted if run.interrupting else .Failed)
	case agent.Rewind_Failed:
		run_notice(run, concat("could not rewind the agent session: ", ev.message))
	case agent.Rewound:
		if ev.path == .Seeded {
			run_notice(run, "the agent session was rebuilt from the transcript")
		}
	case agent.Models:
	case agent.Notice:
		if ev.level != .Info || len(ev.text) > 0 {
			run_notice(run, ev.text)
		}
	}
}

proc_turn_done :: proc(p: ^Proc, run: ^Run) {
	r := p.r
	p.run = nil
	run.proc_ = nil
	ni, _ := native_get(r, p.o)
	if len(p.d.session) > 0 {
		ni.provider = p.desc.id
		ni.session = p.d.session
		ni.runner = r.self
		ni.head = run.reply
		ni.cwd = p.cwd
		ni.home = r.cfg.home_dir
		ni.checkpoint = run.checkpoint
		ni.native = agent.session_path(&p.d)
		native_put(r, p.o, ni)
		port_export(r, p.o, p.desc, &ni, p.cwd)
	}
	keep := p.alive && !p.closing && run.ai.warm && .Persistent in p.desc.capabilities && run.status != .Failed && r.cfg.warm_max > 0
	if keep {
		p.idle_since = mono_ns(r)
		if run.ws != nil {
			p.ws = run.ws
		}
		_warm_trim(r)
		_warm_arm(r)
		return
	}
	_proc_close(p)
}

@(private)
_proc_close :: proc(p: ^Proc) {
	r := p.r
	if p.closing {
		return
	}
	p.closing = true
	if !p.alive {
		_proc_free(p, false)
		return
	}
	out := agent.close(&p.d)
	_proc_output(p, &out)
	if p.child.stdin >= 0 {
		prim.child_close_stdin(&p.child)
	}
	p.kill_timer = prim.timer(eng.loop(r.e), 3000, p, _proc_on_kill)
}

@(private)
_proc_on_kill :: proc(l: ^prim.Loop, data: rawptr) {
	p := (^Proc)(data)
	p.kill_timer = 0
	if p.alive {
		prim.child_kill(&p.child, .Kill)
	}
}

@(private)
_proc_free :: proc(p: ^Proc, kill: bool) {
	r := p.r
	lp := eng.loop(r.e)
	if p.run != nil {
		run := p.run
		p.run = nil
		run.proc_ = nil
		if run.state != .Finished && !r.closing {
			run_error(run, "the agent process was stopped")
			run_finish(run, .Interrupted)
		}
	}
	if kill && p.alive {
		prim.child_kill(&p.child, .Kill)
		prim.reap(p.child.pid, true)
		p.alive = false
	}
	if p.cw != 0 && p.alive {
		p.closing = true
		return
	}
	if p.w_out != 0 {
		prim.unwatch(lp, p.w_out)
		p.w_out = 0
	}
	if p.w_err != 0 {
		prim.unwatch(lp, p.w_err)
		p.w_err = 0
	}
	if p.w_in != 0 {
		prim.unwatch(lp, p.w_in)
		p.w_in = 0
	}
	if p.cw != 0 {
		prim.child_unwatch(lp, p.cw)
		p.cw = 0
	}
	if p.kill_timer != 0 {
		prim.timer_cancel(lp, p.kill_timer)
	}
	prim.child_close(&p.child)
	if p.ws != nil {
		worktree_close(p.ws)
		p.ws = nil
	}
	if len(p.token) > 0 {
		serve_revoke(r, p.token)
		delete(p.token, r.allocator)
	}
	for s in p.extra {
		delete(s, r.allocator)
	}
	delete(p.extra, r.allocator)
	if p.d_on {
		agent.destroy(&p.d)
	}
	prim.line_buffer_destroy(&p.lb_out)
	prim.line_buffer_destroy(&p.lb_err)
	delete(p.inq)
	delete(p.err_tail)
	delete(p.cwd, r.allocator)
	delete(p.key, r.allocator)
	for x, i in r.procs {
		if x == p {
			ordered_remove(&r.procs, i)
			break
		}
	}
	free(p, r.allocator)
}

@(private)
_warm_trim :: proc(r: ^Runtime) {
	for {
		n := 0
		oldest: ^Proc
		for p in r.procs {
			if p.run == nil && !p.closing && p.alive {
				n += 1
				if oldest == nil || p.idle_since < oldest.idle_since {
					oldest = p
				}
			}
		}
		if n <= r.cfg.warm_max || oldest == nil {
			return
		}
		_proc_close(oldest)
	}
}

@(private)
_warm_arm :: proc(r: ^Runtime) {
	l := eng.loop(r.e)
	at: i64 = 0
	for p in r.procs {
		if p.run == nil && !p.closing && p.alive {
			due := p.idle_since + r.cfg.warm_idle_ms * 1_000_000
			if at == 0 || due < at {
				at = due
			}
		}
	}
	if at == r.warm_at && (at == 0 || prim.timer_pending(l, r.warm_timer)) {
		return
	}
	if r.warm_timer != 0 {
		prim.timer_cancel(l, r.warm_timer)
		r.warm_timer = 0
	}
	r.warm_at = at
	if at != 0 {
		r.warm_timer = prim.timer_at(l, at, r, _on_warm_timer)
	}
}

@(private)
_on_warm_timer :: proc(l: ^prim.Loop, data: rawptr) {
	r := (^Runtime)(data)
	r.warm_timer = 0
	r.warm_at = 0
	now := mono_ns(r)
	list := make([dynamic]^Proc, context.temp_allocator)
	for p in r.procs {
		if p.run == nil && !p.closing && p.idle_since + r.cfg.warm_idle_ms * 1_000_000 <= now {
			append(&list, p)
		}
	}
	for p in list {
		_proc_close(p)
	}
	_warm_arm(r)
}

@(private)
_checkpoint_of :: proc(r: ^Runtime, o: Object, msg: Rid, provider: string) -> string {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return ""
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return ""
	}
	m, merr := convo.message(v, &t, convo.Position{msg = msg}, context.temp_allocator)
	if merr != .None || m.role != .Assistant || m.provider != provider {
		return ""
	}
	if sn := seal_native(v, &m); len(sn) > 0 && sn[0] != 0 {
		return sn
	}
	return ""
}

transcript_seed :: proc(r: ^Runtime, o: Object, upto: Rid) -> []agent.Seed_Entry {
	if obj.rid_none(upto) {
		return nil
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return nil
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return nil
	}
	pg, perr := convo.page(v, &t, convo.Position{msg = upto}, 100_000, context.temp_allocator)
	if perr != .None && perr != .Missing {
		return nil
	}
	out := make([dynamic]agent.Seed_Entry, context.temp_allocator)
	for i := len(pg.messages) - 1; i >= 0; i -= 1 {
		m := &pg.messages[i]
		role: agent.Seed_Role = .User if m.role == .User || m.role == .System else .Assistant
		text := make(Buf, context.temp_allocator)
		tools := make(map[string]int, context.temp_allocator)
		for b in m.blocks {
			#partial switch b.kind {
			case .Text:
				if len(text) > 0 {
					append(&text, "\n\n")
				}
				append(&text, ..b.text)
			case .Tool_Call:
				if len(text) > 0 {
					append(&out, agent.Seed_Entry{role = role, text = string(text[:])})
					text = make(Buf, context.temp_allocator)
				}
				tools[b.id] = len(out)
				append(&out, agent.Seed_Entry{role = .Tool, tool = b.name, input = string(b.text)})
			case .Tool_Result:
				if k, ok := tools[b.id]; ok {
					res := string(b.text) if !b.is_ref else string(b.blob.preview)
					out[k].text = res
					out[k].is_error = b.failed
				}
			}
		}
		if len(text) > 0 {
			append(&out, agent.Seed_Entry{role = role, text = string(text[:])})
		}
	}
	return out[:]
}

@(private)
_env_merge :: proc(env: []string, allocator := context.temp_allocator) -> []string {
	if len(env) == 0 {
		return nil
	}
	out := make([dynamic]string, allocator)
	base := posix.environ
	for i := 0; base != nil && base[i] != nil; i += 1 {
		s := string(base[i])
		eq := strings.index_byte(s, '=')
		name := s[:eq] if eq >= 0 else s
		over := false
		for e in env {
			if strings.has_prefix(e, name) && len(e) > len(name) && e[len(name)] == '=' {
				over = true
				break
			}
		}
		if !over {
			append(&out, s)
		}
	}
	append(&out, ..env)
	return out[:]
}
