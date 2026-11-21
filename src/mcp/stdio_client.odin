package mcp

import "base:runtime"
import "core:strings"
import "../prim"

Spawner :: struct {
	data:  rawptr,
	spawn: proc(data: rawptr, argv: []string, env: []string, cwd: string) -> (prim.Child, prim.Error),
}

Event_Handler :: struct {
	data:  rawptr,
	event: proc(data: rawptr, c: ^Client, e: ^Event),
}

Stdio_Config :: struct {
	argv:          []string,
	env:           []string,
	cwd:           string,
	spawner:       Spawner,
	restart:       bool,
	max_line:      int,
	stop_grace_ms: i64,
	stderr_events: bool,
}

DEFAULT_MAX_LINE :: 64 << 20
RESTART_MIN_MS :: 250
RESTART_MAX_MS :: 30_000
STABLE_MS :: 60_000

Stdio_Client :: struct {
	client:      Client,
	loop:        ^prim.Loop,
	allocator:   runtime.Allocator,
	argv:        []string,
	env:         []string,
	cwd:         string,
	spawner:     Spawner,
	restart:     bool,
	grace_ms:    i64,
	stderr_ev:   bool,
	handler:     Event_Handler,
	child:       prim.Child,
	running:     bool,
	exited:      bool,
	w_out:       prim.Watch,
	w_err:       prim.Watch,
	w_in:        prim.Watch,
	cw:          prim.Child_Watch,
	lb_out:      prim.Line_Buffer,
	lb_err:      prim.Line_Buffer,
	outq:        Out_Queue,
	timer:       prim.Timer,
	timer_at:    i64,
	restart_t:   prim.Timer,
	kill_t:      prim.Timer,
	backoff:     i64,
	started_at:  i64,
	stopping:    bool,
	kill_stage:  int,
	on_stopped:  proc(data: rawptr, sc: ^Stdio_Client),
	stop_data:   rawptr,
}

@(private)
_default_spawn :: proc(data: rawptr, argv: []string, env: []string, cwd: string) -> (prim.Child, prim.Error) {
	return prim.spawn(argv, cwd, env, true)
}

default_spawner :: proc "contextless" () -> Spawner {
	return Spawner{spawn = _default_spawn}
}

stdio_client_open :: proc(sc: ^Stdio_Client, loop: ^prim.Loop, cfg: Stdio_Config, client_cfg: Client_Config, handler: Event_Handler, allocator := context.allocator) -> prim.Error {
	sc^ = {}
	sc.loop = loop
	sc.allocator = allocator
	sc.argv = make([]string, len(cfg.argv), allocator)
	for a, i in cfg.argv {
		sc.argv[i] = strings.clone(a, allocator)
	}
	if cfg.env != nil {
		sc.env = make([]string, len(cfg.env), allocator)
		for a, i in cfg.env {
			sc.env[i] = strings.clone(a, allocator)
		}
	}
	sc.cwd = strings.clone(cfg.cwd, allocator)
	sc.spawner = cfg.spawner
	if sc.spawner.spawn == nil {
		sc.spawner = default_spawner()
	}
	sc.restart = cfg.restart
	sc.grace_ms = cfg.stop_grace_ms if cfg.stop_grace_ms > 0 else 2000
	sc.stderr_ev = cfg.stderr_events
	sc.handler = handler
	max_line := cfg.max_line if cfg.max_line > 0 else DEFAULT_MAX_LINE
	prim.line_buffer_init(&sc.lb_out, 64 * 1024, max_line, allocator)
	prim.line_buffer_init(&sc.lb_err, 4096, 1 << 20, allocator)
	ccfg := client_cfg
	ccfg.transport = .Stdio
	client_init(&sc.client, ccfg, Client_Sink{data = sc, send = _stdio_send, event = _stdio_event}, allocator)
	sc.backoff = RESTART_MIN_MS
	return _stdio_spawn(sc)
}

@(private)
_stdio_spawn :: proc(sc: ^Stdio_Client) -> prim.Error {
	child, err := sc.spawner.spawn(sc.spawner.data, sc.argv, sc.env, sc.cwd)
	if err != .None {
		return err
	}
	sc.child = child
	sc.running = true
	sc.exited = false
	sc.started_at = prim.mono_ns() / 1_000_000
	prim.line_buffer_reset(&sc.lb_out)
	prim.line_buffer_reset(&sc.lb_err)
	out_destroy(&sc.outq)
	sc.outq.base = {}
	werr: prim.Error
	sc.w_out, werr = prim.watch(sc.loop, child.stdout, {.Read}, sc, _stdio_on_out)
	if werr == .None && child.stderr != prim.INVALID_FD {
		sc.w_err, werr = prim.watch(sc.loop, child.stderr, {.Read}, sc, _stdio_on_err)
	}
	if werr == .None {
		sc.w_in, werr = prim.watch(sc.loop, child.stdin, {}, sc, _stdio_on_in)
	}
	if werr == .None {
		sc.cw, werr = prim.child_watch(sc.loop, child.pid, sc, _stdio_on_exit)
	}
	if werr != .None {
		_stdio_unwatch(sc)
		prim.child_kill(&sc.child, .Kill)
		prim.reap(sc.child.pid, true)
		prim.child_close(&sc.child)
		sc.running = false
		return werr
	}
	client_start(&sc.client)
	_stdio_arm(sc)
	return .None
}

@(private)
_stdio_unwatch :: proc(sc: ^Stdio_Client) {
	if sc.w_out != 0 {
		prim.unwatch(sc.loop, sc.w_out)
		sc.w_out = 0
	}
	if sc.w_err != 0 {
		prim.unwatch(sc.loop, sc.w_err)
		sc.w_err = 0
	}
	if sc.w_in != 0 {
		prim.unwatch(sc.loop, sc.w_in)
		sc.w_in = 0
	}
}

@(private)
_stdio_send :: proc(data: rawptr, c: ^Client, m: ^Outgoing) {
	sc := (^Stdio_Client)(data)
	#partial switch m.kind {
	case .Request, .Notification, .Response:
		if !sc.running || sc.child.stdin == prim.INVALID_FD {
			return
		}
		nl := [1]u8{'\n'}
		if err := out_write(&sc.outq, sc.loop, sc.w_in, sc.child.stdin, m.body, nl[:]); err != .None {
			prim.child_close_stdin(&sc.child)
		}
		_stdio_arm(sc)
	}
}

@(private)
_stdio_event :: proc(data: rawptr, c: ^Client, e: ^Event) {
	sc := (^Stdio_Client)(data)
	if sc.handler.event != nil {
		sc.handler.event(sc.handler.data, c, e)
	}
}

@(private)
_stdio_arm :: proc(sc: ^Stdio_Client) {
	deadline, ok := client_next_deadline(&sc.client)
	if !ok {
		if sc.timer != 0 {
			prim.timer_cancel(sc.loop, sc.timer)
			sc.timer = 0
		}
		return
	}
	if sc.timer != 0 && prim.timer_pending(sc.loop, sc.timer) && sc.timer_at <= deadline {
		return
	}
	if sc.timer != 0 {
		prim.timer_cancel(sc.loop, sc.timer)
	}
	sc.timer_at = deadline
	sc.timer = prim.timer_at(sc.loop, deadline * 1_000_000, sc, _stdio_on_timer)
}

@(private)
_stdio_on_timer :: proc(l: ^prim.Loop, data: rawptr) {
	sc := (^Stdio_Client)(data)
	sc.timer = 0
	client_tick(&sc.client)
	_stdio_arm(sc)
}

@(private)
_stdio_on_out :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	sc := (^Stdio_Client)(data)
	for sc.running && !sc.lb_out.eof {
		n, err := prim.line_fill(&sc.lb_out, fd)
		if err == .Would_Block {
			break
		}
		if err == .Interrupted {
			continue
		}
		if err == .Too_Large {
			_stdio_event(sc, &sc.client, &Event{kind = .Warning, message = "server message exceeds the line limit; restarting"})
			prim.child_kill(&sc.child, .Kill)
			return
		}
		if err != .None {
			prim.line_finish(&sc.lb_out)
		}
		for line in prim.line_next(&sc.lb_out) {
			text := json_trim(string(line))
			if len(text) == 0 {
				continue
			}
			client_receive(&sc.client, transmute([]u8)text)
			if !sc.running {
				return
			}
		}
		if n == 0 && err == .None && !sc.lb_out.eof {
			break
		}
	}
	if sc.running {
		_stdio_arm(sc)
	}
}

@(private)
_stdio_on_err :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	sc := (^Stdio_Client)(data)
	for !sc.lb_err.eof {
		n, err := prim.line_fill(&sc.lb_err, fd)
		if err == .Would_Block {
			break
		}
		if err == .Interrupted {
			continue
		}
		if err == .Too_Large {
			for line in prim.line_next(&sc.lb_err) {
				_ = line
			}
			prim.line_buffer_reset(&sc.lb_err)
			continue
		}
		if err != .None {
			prim.line_finish(&sc.lb_err)
		}
		for line in prim.line_next(&sc.lb_err) {
			if sc.stderr_ev {
				e := Event{kind = .Stderr, message = string(line)}
				_stdio_event(sc, &sc.client, &e)
			}
		}
		if n == 0 && err == .None && !sc.lb_err.eof {
			break
		}
	}
	if sc.lb_err.eof && sc.w_err != 0 {
		prim.unwatch(sc.loop, sc.w_err)
		sc.w_err = 0
	}
}

@(private)
_stdio_on_in :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	sc := (^Stdio_Client)(data)
	if .Write in events || .Error in events || .Hangup in events {
		if err := out_flush(&sc.outq, l, sc.w_in, fd); err != .None {
			out_destroy(&sc.outq)
		}
	}
}

@(private)
_stdio_on_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	sc := (^Stdio_Client)(data)
	sc.cw = 0
	sc.running = false
	sc.exited = true
	_stdio_unwatch(sc)
	prim.child_close(&sc.child)
	out_destroy(&sc.outq)
	if sc.kill_t != 0 {
		prim.timer_cancel(l, sc.kill_t)
		sc.kill_t = 0
	}
	if sc.stopping {
		if sc.timer != 0 {
			prim.timer_cancel(l, sc.timer)
			sc.timer = 0
		}
		if sc.on_stopped != nil {
			sc.on_stopped(sc.stop_data, sc)
		}
		return
	}
	reason := "server process exited"
	if status.signal != 0 {
		reason = "server process killed by signal"
	}
	if !sc.restart {
		client_close(&sc.client, reason)
		if sc.timer != 0 {
			prim.timer_cancel(l, sc.timer)
			sc.timer = 0
		}
		return
	}
	client_transport_lost(&sc.client, reason)
	now := prim.mono_ns() / 1_000_000
	if now - sc.started_at > STABLE_MS {
		sc.backoff = RESTART_MIN_MS
	}
	delay := sc.backoff
	sc.backoff = min(sc.backoff * 2, RESTART_MAX_MS)
	sc.restart_t = prim.timer(l, delay, sc, _stdio_on_restart)
	_stdio_arm(sc)
}

@(private)
_stdio_on_restart :: proc(l: ^prim.Loop, data: rawptr) {
	sc := (^Stdio_Client)(data)
	sc.restart_t = 0
	if sc.stopping {
		return
	}
	if err := _stdio_spawn(sc); err != .None {
		delay := sc.backoff
		sc.backoff = min(sc.backoff * 2, RESTART_MAX_MS)
		sc.restart_t = prim.timer(l, delay, sc, _stdio_on_restart)
	}
}

stdio_client_stop :: proc(sc: ^Stdio_Client, on_stopped: proc(data: rawptr, sc: ^Stdio_Client) = nil, data: rawptr = nil) {
	sc.stopping = true
	sc.on_stopped = on_stopped
	sc.stop_data = data
	client_close(&sc.client, "client stopped")
	if sc.restart_t != 0 {
		prim.timer_cancel(sc.loop, sc.restart_t)
		sc.restart_t = 0
	}
	if sc.timer != 0 {
		prim.timer_cancel(sc.loop, sc.timer)
		sc.timer = 0
	}
	if !sc.running {
		if on_stopped != nil {
			on_stopped(data, sc)
		}
		return
	}
	if sc.w_in != 0 {
		prim.unwatch(sc.loop, sc.w_in)
		sc.w_in = 0
	}
	out_destroy(&sc.outq)
	prim.child_close_stdin(&sc.child)
	sc.kill_stage = 0
	sc.kill_t = prim.timer(sc.loop, sc.grace_ms, sc, _stdio_on_kill)
}

@(private)
_stdio_on_kill :: proc(l: ^prim.Loop, data: rawptr) {
	sc := (^Stdio_Client)(data)
	sc.kill_t = 0
	if !sc.running {
		return
	}
	if sc.kill_stage == 0 {
		sc.kill_stage = 1
		prim.child_kill(&sc.child, .Terminate)
		sc.kill_t = prim.timer(l, sc.grace_ms, sc, _stdio_on_kill)
		return
	}
	prim.child_kill(&sc.child, .Kill)
}

stdio_client_destroy :: proc(sc: ^Stdio_Client) {
	if sc.running {
		_stdio_unwatch(sc)
		if sc.cw != 0 {
			prim.child_unwatch(sc.loop, sc.cw)
			sc.cw = 0
		}
		prim.child_kill(&sc.child, .Kill)
		prim.reap(sc.child.pid, true)
		prim.child_close(&sc.child)
		sc.running = false
	}
	for t in ([]prim.Timer{sc.timer, sc.restart_t, sc.kill_t}) {
		if t != 0 {
			prim.timer_cancel(sc.loop, t)
		}
	}
	client_destroy(&sc.client)
	prim.line_buffer_destroy(&sc.lb_out)
	prim.line_buffer_destroy(&sc.lb_err)
	out_destroy(&sc.outq)
	for a in sc.argv {
		delete(a, sc.allocator)
	}
	delete(sc.argv, sc.allocator)
	for a in sc.env {
		delete(a, sc.allocator)
	}
	delete(sc.env, sc.allocator)
	delete(sc.cwd, sc.allocator)
	sc^ = {}
}
