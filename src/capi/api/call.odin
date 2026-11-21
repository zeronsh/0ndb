package api

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import eng "../../engine"
import "../../prim"
import rt "../../runtime"

VERSION :: 1

Status :: enum u8 {
	Ok           = 0,
	Pending      = 1,
	Not_Found    = 2,
	Exists       = 3,
	Invalid      = 4,
	Busy         = 5,
	Closed       = 6,
	Offline      = 7,
	Permission   = 8,
	Forged       = 9,
	Quarantined  = 10,
	Missing      = 11,
	Corrupt      = 12,
	Limit        = 13,
	Too_Large    = 14,
	Unsupported  = 15,
	Not_Assigned = 16,
	No_Space     = 17,
	No_Memory    = 18,
	Io           = 19,
	Bad_Request  = 20,
	Unknown_Op   = 21,
	Conflict     = 22,
	Cancelled    = 23,
	Budget       = 24,
	Spawn        = 25,
	Timeout      = 26,
}

STATUS_NAMES := [27]string{"ok", "pending", "not_found", "exists", "invalid", "busy", "closed", "offline", "permission", "forged", "quarantined", "missing", "corrupt", "limit", "too_large", "unsupported", "not_assigned", "no_space", "no_memory", "io", "bad_request", "unknown_op", "conflict", "cancelled", "budget", "spawn", "timeout"}

status_of :: proc "contextless" (err: eng.Error) -> Status {
	switch err {
	case .None:
		return .Ok
	case .Pending:
		return .Pending
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Invalid:
		return .Invalid
	case .Busy:
		return .Busy
	case .Closed:
		return .Closed
	case .Offline:
		return .Offline
	case .Permission:
		return .Permission
	case .Forged:
		return .Forged
	case .Quarantined:
		return .Quarantined
	case .Missing:
		return .Missing
	case .Corrupt:
		return .Corrupt
	case .Limit:
		return .Limit
	case .Too_Large:
		return .Too_Large
	case .Unsupported:
		return .Unsupported
	case .Not_Assigned:
		return .Not_Assigned
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Io:
		return .Io
	case .Conflict:
		return .Conflict
	}
	return .Io
}

Op_Proc :: #type proc(c: ^Call, o: ^Out) -> Status

Op :: struct {
	code:   u16,
	name:   string,
	args:   []Arg,
	result: string,
	run:    Op_Proc,
}

Done_Proc :: #type proc(data: rawptr, id: u64, status: Status, payload: []u8)

Host :: struct {
	data:  rawptr,
	ops:   []Op,
	event: proc(data: rawptr, a: ^Api, ev: ^eng.Event),
}

Api :: struct {
	e:         ^eng.Engine,
	r:         ^rt.Runtime,
	allocator: runtime.Allocator,
	host:      Host,
	ext:       rawptr,
	calls:     [dynamic]^Call,
	next_call: u64,
	subs:      [dynamic]^Sub,
	next_sub:  u64,
	mounts:    [dynamic]^Mounted,
	models:    Models_Cache,
	closing:   bool,
}

Call :: struct {
	api:      ^Api,
	id:       u64,
	op:       ^Op,
	args:     Args,
	json:     bool,
	arena:    virtual.Arena,
	done:     Done_Proc,
	data:     rawptr,
	tries:    int,
	waiting:  bool,
	final:    bool,
	timer:    prim.Timer,
	deadline: i64,
	stage:    int,
	scratch:  [4]u64,
	result:   eng.Result,
	err:      eng.Error,
	in_exec:  bool,
	orphan:   bool,
	account:  eng.Account_Result,
	job:      u64,
}

MAX_RETRIES :: 64

init :: proc(a: ^Api, e: ^eng.Engine, r: ^rt.Runtime = nil, host: Host = {}, allocator := context.allocator) {
	a^ = {
		e         = e,
		r         = r,
		allocator = allocator,
		host      = host,
	}
	a.calls = make([dynamic]^Call, allocator)
	a.subs = make([dynamic]^Sub, allocator)
	a.mounts = make([dynamic]^Mounted, allocator)
}

destroy :: proc(a: ^Api) {
	a.closing = true
	for len(a.calls) > 0 {
		c := a.calls[len(a.calls) - 1]
		_complete(c, .Closed, nil)
	}
	for len(a.subs) > 0 {
		unsubscribe(a, a.subs[len(a.subs) - 1].id)
	}
	_mounts_close_all(a)
	models_destroy(a)
	delete(a.calls)
	delete(a.subs)
	delete(a.mounts)
}

find_op :: proc(a: ^Api, name: string, code: u16) -> ^Op {
	for &op in OPS {
		if (len(name) > 0 && op.name == name) || (len(name) == 0 && op.code == code) {
			return &op
		}
	}
	for &op in RUNTIME_OPS {
		if (len(name) > 0 && op.name == name) || (len(name) == 0 && op.code == code) {
			return &op
		}
	}
	for &op in BUFFER_OPS {
		if (len(name) > 0 && op.name == name) || (len(name) == 0 && op.code == code) {
			return &op
		}
	}
	for &op in a.host.ops {
		if (len(name) > 0 && op.name == name) || (len(name) == 0 && op.code == code) {
			return &op
		}
	}
	return nil
}

call :: proc(a: ^Api, req: []u8, json_form: bool, done: Done_Proc, data: rawptr, deadline_ms: i64 = 0, allocator := context.allocator) -> (id: u64, status: Status, payload: []u8) {
	c := new(Call, a.allocator)
	c.api = a
	c.json = json_form
	c.done = done
	c.data = data
	if virtual.arena_init_growing(&c.arena, 4096) != nil {
		free(c, a.allocator)
		return 0, .No_Memory, nil
	}
	arena := virtual.arena_allocator(&c.arena)
	body := make([]u8, len(req), arena)
	copy(body, req)
	st := _decode(a, c, body, arena)
	if st != .Ok {
		payload = _error_payload(c, st, allocator)
		_call_free(c)
		return 0, st, payload
	}
	a.next_call += 1
	c.id = a.next_call
	if deadline_ms > 0 {
		c.deadline = deadline_ms
	}
	st, payload = _run(c, allocator)
	if st != .Pending {
		_call_free(c)
		return 0, st, payload
	}
	append(&a.calls, c)
	if c.deadline > 0 && c.timer == 0 {
		c.timer = prim.timer(eng.loop(a.e), c.deadline, c, _on_deadline)
	}
	return c.id, .Pending, nil
}

cancel :: proc(a: ^Api, id: u64) {
	for c in a.calls {
		if c.id == id {
			c.done = nil
			if c.job != 0 {
				job := c.job
				c.job = 0
				eng.account_job_cancel(a.e, job)
				return
			}
			_complete(c, .Cancelled, nil)
			return
		}
	}
}

account_done :: proc(c: ^Call) -> eng.Account_Done {
	return eng.Account_Done{data = c, call = _on_account_done, job = &c.job}
}

@(private)
_on_account_done :: proc(data: rawptr, e: ^eng.Engine, res: ^eng.Account_Result, err: eng.Error) {
	c := (^Call)(data)
	c.in_exec = false
	c.job = 0
	if c.orphan {
		_call_free(c)
		return
	}
	arena := virtual.arena_allocator(&c.arena)
	c.account = res^
	c.account.text = _clone_str(res.text, arena)
	c.account.wrappers = eng.wrappers_clone(res.wrappers, arena)
	en := make([]u8, len(res.enrollment), arena)
	copy(en, res.enrollment)
	c.account.enrollment = en
	c.err = err
	c.stage += 1
	_rerun(c)
}

@(private)
_clone_str :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

account_step :: proc(c: ^Call, err: eng.Error) -> (Status, bool) {
	if err == .Pending {
		c.in_exec = true
		return .Pending, false
	}
	if err != .None {
		return status_of(err), false
	}
	c.stage = 1
	return .Ok, true
}

describe :: proc(a: ^Api, json_form: bool, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, json_form)
	o_u64(&o, "version", VERSION)
	n := len(OPS) + len(RUNTIME_OPS) + len(BUFFER_OPS) + len(a.host.ops)
	o_arr(&o, "ops", n)
	describe_op :: proc(o: ^Out, op: ^Op) {
		o_obj(o, "")
		o_u64(o, "code", u64(op.code))
		o_str(o, "name", op.name)
		o_arr(o, "args", len(op.args))
		for arg in op.args {
			o_obj(o, "")
			o_str(o, "name", arg.name)
			o_str(o, "type", ARG_TYPE_NAMES[arg.type])
			o_arr(o, "values", len(arg.names))
			for nm in arg.names {
				o_str(o, "", nm)
			}
			o_end(o)
			o_end(o)
		}
		o_end(o)
		o_str(o, "result", op.result)
		o_end(o)
	}
	for &op in OPS {
		describe_op(&o, &op)
	}
	for &op in RUNTIME_OPS {
		describe_op(&o, &op)
	}
	for &op in BUFFER_OPS {
		describe_op(&o, &op)
	}
	for &op in a.host.ops {
		describe_op(&o, &op)
	}
	o_end(&o)
	out_finish(&o)
	return buf[:]
}

@(private)
_decode :: proc(a: ^Api, c: ^Call, body: []u8, arena: runtime.Allocator) -> Status {
	if c.json {
		root, perr := json.parse(body, json.DEFAULT_SPECIFICATION, true, arena)
		if perr != .None {
			return .Bad_Request
		}
		ob, ok := root.(json.Object)
		if !ok {
			return .Bad_Request
		}
		name, nok := ob["op"].(json.String)
		if !nok {
			return .Bad_Request
		}
		c.op = find_op(a, string(name), 0)
		if c.op == nil {
			return .Unknown_Op
		}
		if !decode_json(c.op, ob, &c.args, arena) {
			return .Bad_Request
		}
		return .Ok
	}
	r := prim.reader(body)
	if prim.read_u8(&r) != VERSION {
		return .Bad_Request
	}
	code := u16(prim.read_uvarint(&r))
	if !prim.reader_ok(&r) {
		return .Bad_Request
	}
	c.op = find_op(a, "", code)
	if c.op == nil {
		return .Unknown_Op
	}
	if !decode_binary(c.op, &r, &c.args, arena) {
		return .Bad_Request
	}
	return .Ok
}

@(private)
_run :: proc(c: ^Call, allocator: runtime.Allocator) -> (Status, []u8) {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, c.json)
	c.waiting = false
	if c.op.run == nil {
		delete(buf)
		return .Bad_Request, _error_payload(c, .Bad_Request, allocator)
	}
	st := c.op.run(c, &o)
	if st == .Pending {
		delete(buf)
		return .Pending, nil
	}
	if st != .Ok {
		delete(buf)
		return st, _error_payload(c, st, allocator)
	}
	return .Ok, out_finish(&o)
}

@(private)
_error_payload :: proc(c: ^Call, st: Status, allocator: runtime.Allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, c.json)
	if c.json {
		o_str(&o, "error", STATUS_NAMES[int(st)])
	} else {
		o_u64(&o, "status", u64(st))
	}
	return out_finish(&o)
}

ready :: proc(c: ^Call) -> eng.Ready {
	if c.final {
		return {}
	}
	c.waiting = true
	return eng.Ready{data = c, call = _on_ready, fresh = true}
}

done :: proc(c: ^Call) -> eng.Done {
	return eng.Done{data = c, call = _on_done}
}

pend :: proc(c: ^Call, err: eng.Error) -> Status {
	if err == .Pending {
		return .Pending
	}
	return status_of(err)
}

@(private)
_on_ready :: proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
	c := (^Call)(data)
	if err != .None {
		_complete(c, status_of(err), nil)
		return
	}
	c.tries += 1
	if c.tries >= MAX_RETRIES {
		c.final = true
	}
	_rerun(c)
}

@(private)
_on_done :: proc(data: rawptr, e: ^eng.Engine, res: ^eng.Result, err: eng.Error) {
	c := (^Call)(data)
	c.in_exec = false
	if c.orphan {
		_call_free(c)
		return
	}
	c.result = res^
	c.err = err
	c.stage += 1
	_rerun(c)
}

@(private)
_on_deadline :: proc(l: ^prim.Loop, data: rawptr) {
	c := (^Call)(data)
	c.timer = 0
	if c.in_exec || !c.waiting {
		_complete(c, .Timeout, nil)
		return
	}
	eng.cancel_waits(c.api.e, c)
	c.final = true
	_rerun(c)
}

@(private)
_rerun :: proc(c: ^Call) {
	for x in c.api.calls {
		if x == c {
			st, payload := _run(c, context.temp_allocator)
			if st == .Pending {
				if c.final && !c.in_exec {
					eng.cancel_waits(c.api.e, c)
					_complete(c, .Timeout, nil)
				}
				return
			}
			_complete(c, st, payload)
			return
		}
	}
}

exec :: proc(c: ^Call, o: ^Out, cmd: eng.Command) -> Status {
	if c.stage == 0 {
		res, err := eng.exec(c.api.e, cmd, done(c))
		if err == .Pending {
			c.in_exec = true
			return .Pending
		}
		c.result = res
		c.err = err
		c.stage = 1
	}
	if c.err != .None {
		return status_of(c.err)
	}
	o_rid(o, "item", c.result.item)
	o_i64(o, "off", c.result.off)
	o_rid(o, "leaf", c.result.leaf)
	o_u64(o, "tick", c.result.tick)
	return .Ok
}

@(private)
_complete :: proc(c: ^Call, st: Status, payload: []u8) {
	a := c.api
	for x, i in a.calls {
		if x == c {
			ordered_remove(&a.calls, i)
			break
		}
	}
	if c.timer != 0 {
		prim.timer_cancel(eng.loop(a.e), c.timer)
		c.timer = 0
	}
	eng.cancel_waits(a.e, c)
	p := payload
	if p == nil && st != .Ok {
		p = _error_payload(c, st, context.temp_allocator)
	}
	d := c.done
	c.done = nil
	if d != nil {
		d(c.data, c.id, st, p)
	}
	if c.in_exec {
		c.orphan = true
		if c.job != 0 {
			job := c.job
			c.job = 0
			eng.account_job_cancel(a.e, job)
		}
		return
	}
	_call_free(c)
}

@(private)
_call_free :: proc(c: ^Call) {
	a := c.api
	virtual.arena_destroy(&c.arena)
	free(c, a.allocator)
}

pending_calls :: proc(a: ^Api) -> int {
	return len(a.calls)
}
