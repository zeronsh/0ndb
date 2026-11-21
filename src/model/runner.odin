package model

import "base:runtime"
import "../agent"
import "../prim"

Tools :: struct {
	data:  rawptr,
	run:   proc(data: rawptr, s: ^Session, call: Tool_Run),
	abort: proc(data: rawptr, s: ^Session, id: string),
}

Event_Proc :: #type proc(data: rawptr, s: ^Session, events: []Event)

Runner :: struct {
	loop:      ^prim.Loop,
	http:      Http,
	tools:     Tools,
	allocator: runtime.Allocator,
	sessions:  int,
}

Session :: struct {
	runner:   ^Runner,
	run:      Run,
	http_id:  Http_Id,
	timer:    prim.Timer,
	timer_at: i64,
	on_event: Event_Proc,
	data:     rawptr,
	depth:    int,
	dead:     bool,
}

runner_init :: proc(r: ^Runner, l: ^prim.Loop, http: Http, tools: Tools, allocator := context.allocator) {
	r^ = {loop = l, http = http, tools = tools, allocator = allocator}
}

session_open :: proc(rn: ^Runner, cfg: Config, model: Model, on_event: Event_Proc, data: rawptr) -> ^Session {
	s := new(Session, rn.allocator)
	s.runner = rn
	s.on_event = on_event
	s.data = data
	run_init(&s.run, cfg, model, rn.allocator)
	rn.sessions += 1
	return s
}

session_start :: proc(s: ^Session, ctx: ^Context, turn: string) {
	out := output_make()
	run_start(&s.run, ctx, turn, prim.mono_ns(), &out)
	apply(s, &out)
}

session_steer :: proc(s: ^Session, id: string, text: string, files: []agent.Attachment = nil) -> bool {
	out := output_make()
	ok := run_steer(&s.run, id, text, files, prim.mono_ns(), &out)
	apply(s, &out)
	return ok
}

session_interrupt :: proc(s: ^Session) {
	out := output_make()
	run_interrupt(&s.run, prim.mono_ns(), &out)
	apply(s, &out)
}

session_tool_done :: proc(s: ^Session, id: string, content: []Block, is_error := false) {
	out := output_make()
	run_tool_done(&s.run, id, content, is_error, prim.mono_ns(), &out)
	apply(s, &out)
}

session_tool_text :: proc(s: ^Session, id: string, text: string, is_error := false) {
	blocks := [1]Block{Text{text = text}}
	session_tool_done(s, id, blocks[:], is_error)
}

session_active :: proc(s: ^Session) -> bool {
	return run_active(&s.run)
}

session_close :: proc(s: ^Session) {
	if s.dead {
		return
	}
	s.dead = true
	if s.depth == 0 {
		session_free(s)
	}
}

@(private)
session_free :: proc(s: ^Session) {
	rn := s.runner
	if s.http_id != 0 {
		http_cancel(&rn.http, s.http_id)
		s.http_id = 0
	}
	if s.timer != 0 {
		prim.timer_cancel(rn.loop, s.timer)
		s.timer = 0
	}
	if run_active(&s.run) && rn.tools.abort != nil {
		for p in s.run.pending {
			if p.run && !p.done {
				rn.tools.abort(rn.tools.data, s, p.id)
			}
		}
	}
	run_destroy(&s.run)
	rn.sessions -= 1
	free(s, rn.allocator)
}

@(private)
apply :: proc(s: ^Session, out: ^Output) {
	s.depth += 1
	rn := s.runner
	if len(out.events) > 0 && s.on_event != nil && !s.dead {
		s.on_event(s.data, s, out.events[:])
	}
	for &a in out.actions {
		if s.dead {
			break
		}
		switch v in a {
		case Http_Start:
			req := v.req
			id, err := http_start(&rn.http, &req, Http_Sink{data = s, head = sink_head, body = sink_body, done = sink_done})
			if err != .None {
				s.http_id = 0
				nested := output_make()
				run_on_done(&s.run, err, http_error_text(err), prim.mono_ns(), &nested)
				apply(s, &nested)
			} else {
				s.http_id = id
			}
		case Http_Abort:
			if s.http_id != 0 {
				id := s.http_id
				s.http_id = 0
				http_cancel(&rn.http, id)
			}
		case Tool_Run:
			if rn.tools.run != nil {
				rn.tools.run(rn.tools.data, s, v)
			} else {
				session_tool_text(s, v.id, "no tools are available", true)
			}
		case Tool_Abort:
			if rn.tools.abort != nil {
				rn.tools.abort(rn.tools.data, s, v.id)
			}
		}
	}
	s.depth -= 1
	if s.dead {
		if s.depth == 0 {
			session_free(s)
		}
		return
	}
	arm(s)
}

@(private)
arm :: proc(s: ^Session) {
	rn := s.runner
	d := run_deadline(&s.run)
	if d == s.timer_at && (d == 0 || prim.timer_pending(rn.loop, s.timer)) {
		return
	}
	if s.timer != 0 {
		prim.timer_cancel(rn.loop, s.timer)
		s.timer = 0
	}
	s.timer_at = d
	if d != 0 {
		s.timer = prim.timer_at(rn.loop, d, s, on_timer)
	}
}

@(private)
on_timer :: proc(l: ^prim.Loop, data: rawptr) {
	s := (^Session)(data)
	s.timer = 0
	s.timer_at = 0
	out := output_make()
	run_tick(&s.run, prim.mono_ns(), &out)
	apply(s, &out)
}

@(private)
sink_head :: proc(data: rawptr, id: Http_Id, status: int, headers: []Header) {
	s := (^Session)(data)
	if s.http_id != id || s.dead {
		return
	}
	out := output_make()
	run_on_head(&s.run, status, headers, prim.mono_ns(), &out)
	apply(s, &out)
}

@(private)
sink_body :: proc(data: rawptr, id: Http_Id, chunk: []u8) -> bool {
	s := (^Session)(data)
	if s.http_id != id || s.dead {
		return false
	}
	out := output_make()
	keep := run_on_body(&s.run, chunk, prim.mono_ns(), &out)
	if !keep && s.http_id == id {
		s.http_id = 0
	}
	apply(s, &out)
	return keep && s.http_id == id
}

@(private)
sink_done :: proc(data: rawptr, id: Http_Id, err: Http_Error, detail: string) {
	s := (^Session)(data)
	if s.http_id != id || s.dead {
		return
	}
	s.http_id = 0
	out := output_make()
	run_on_done(&s.run, err, detail, prim.mono_ns(), &out)
	apply(s, &out)
}
