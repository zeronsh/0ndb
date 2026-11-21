package mcp

import "core:strings"

@(private)
_task_send :: proc(c: ^Client, p: ^Pending, method: string, members: string) {
	p.id = c.next_id
	c.next_id += 1
	p.sent = true
	p.deadline = _now(c) + c.cfg.request_timeout_ms
	b := make(Buf, 0, 256 + len(members), context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0","id":`)
	w_int(&b, p.id)
	append(&b, `,"method":`)
	w_str(&b, method)
	append(&b, `,"params":{`)
	f_str(&b, "taskId", p.task_id)
	if members != "" {
		append(&b, ',')
		append(&b, members)
	}
	saved := p.progress
	p.progress = false
	_write_meta(c, &b, p)
	p.progress = saved
	append(&b, "}}")
	m := Outgoing {
		kind    = .Request,
		id      = p.id,
		body    = b[:],
		method  = method,
		name    = p.task_id,
		version = version_name(c.version),
	}
	if c.sink.send != nil {
		c.sink.send(c.sink.data, c, &m)
	}
}

@(private)
_task_get :: proc(c: ^Client, p: ^Pending) {
	p.task_phase = .Get
	_task_send(c, p, "tasks/get", "")
}

@(private)
_task_wait :: proc(c: ^Client, p: ^Pending) {
	p.task_phase = .Wait
	p.deadline = 0
	p.id = 0
	poll := p.task_poll if p.task_poll > 0 else 1000
	p.task_due = _now(c) + poll
}

@(private)
_on_task_created :: proc(c: ^Client, p: ^Pending, result: string) {
	tid, ok := json_get_string(result, "taskId")
	if !ok || tid == "" {
		_fail(c, p, "task result without taskId")
		return
	}
	p.task_id = _clone(c, tid)
	p.task_seen = make([dynamic]string, c.allocator)
	p.hard = 0
	_emit(c, Event{kind = .Task, call = p.call, op = p.op, message = tid, result = result})
	_, q := _find_call(c, p.call)
	if q != p {
		return
	}
	_task_handle(c, p, result)
}

@(private)
_on_task_response :: proc(c: ^Client, p: ^Pending, result: string) {
	switch p.task_phase {
	case .Get:
		_task_handle(c, p, result)
	case .Update:
		_task_wait(c, p)
	case .None, .Wait:
	}
}

@(private)
_task_handle :: proc(c: ^Client, p: ^Pending, task: string) {
	if poll, ok := json_get_int(task, "pollIntervalMs"); ok && poll > 0 {
		p.task_poll = min(poll, 3_600_000)
	}
	st, _ := json_get_string(task, "status")
	status, known := task_status_parse(st)
	if !known {
		_fail(c, p, "task has an unknown status")
		return
	}
	call, op := p.call, p.op
	if status != p.task_status || status == .Input_Required {
		p.task_status = status
		msg, _ := json_get_string(task, "statusMessage")
		_emit(c, Event{kind = .Task_Status, call = call, op = op, method = st, message = msg})
		_, q := _find_call(c, call)
		if q != p {
			return
		}
	}
	switch status {
	case .Working:
		_task_wait(c, p)
	case .Input_Required:
		reqs, _ := json_get_object(task, "inputRequests")
		it, _ := json_object(reqs)
		fresh := 0
		for k, v in json_next_member(&it) {
			key, kok := json_string(k)
			if !kok {
				continue
			}
			seen := false
			for x in p.task_seen {
				if x == key {
					seen = true
					break
				}
			}
			if seen {
				continue
			}
			method, _ := json_get_string(v, "method")
			params, _ := json_get(v, "params")
			if !_input_allowed(c, method, params) {
				_task_cancel(c, p)
				_fail(c, p, strings.concatenate({"task requested undeclared capability: ", method}, context.temp_allocator))
				return
			}
			append(&p.task_seen, _clone(c, key))
			_add_input(c, p, key, method, params if params != "" else "{}")
			fresh += 1
		}
		if fresh == 0 {
			_task_wait(c, p)
			return
		}
		p.task_phase = .None
		p.deadline = 0
		p.id = 0
		p.waiting = true
		_task_emit_inputs(c, p)
	case .Completed:
		res, ok := json_get_object(task, "result")
		if !ok {
			_fail(c, p, "completed task without result")
			return
		}
		if why, vok := _check_tool_result(c, p.name, res); !vok {
			_fail(c, p, why)
			return
		}
		_detach(c, p)
		out := strings.clone(res, context.temp_allocator)
		_pending_free(c, p)
		_emit(c, Event{kind = .Result, call = call, op = op, result = out})
	case .Failed:
		err, _ := json_get_object(task, "error")
		code := error_code(err)
		msg := error_message(err)
		data, _ := json_get(err, "data")
		data = strings.clone(json_trim(data), context.temp_allocator)
		msg = strings.clone(msg, context.temp_allocator)
		_detach(c, p)
		_pending_free(c, p)
		_emit(c, Event{kind = .Error, call = call, op = op, code = code, message = msg, data = data})
	case .Cancelled:
		_detach(c, p)
		_pending_free(c, p)
		_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = JSONRPC_INTERNAL_ERROR, message = "task cancelled"})
	}
}

@(private)
_task_emit_inputs :: proc(c: ^Client, p: ^Pending) {
	call := p.call
	ids := make([dynamic]Input, context.temp_allocator)
	for s in p.inputs {
		if !s.answered {
			append(&ids, s.id)
		}
	}
	for id in ids {
		_, q := _find_call(c, call)
		if q == nil {
			return
		}
		for &s in q.inputs {
			if s.id != id || s.answered {
				continue
			}
			if s.method == "roots/list" && c.roots_set {
				b := make(Buf, context.temp_allocator)
				append(&b, `{"roots":`)
				append(&b, c.roots)
				append(&b, '}')
				s.response = _clone(c, string(b[:]))
				s.answered = true
				break
			}
			method := strings.clone(s.method, context.temp_allocator)
			params := strings.clone(s.params, context.temp_allocator)
			key := strings.clone(s.key, context.temp_allocator)
			_emit(c, Event{kind = .Input_Request, call = call, input = id, op = q.op, method = method, params = params, key = key})
			break
		}
	}
	_, q := _find_call(c, call)
	if q != nil {
		_task_answered(c, q)
	}
}

@(private)
_task_answered :: proc(c: ^Client, p: ^Pending) {
	if !p.waiting {
		return
	}
	for s in p.inputs {
		if !s.answered {
			return
		}
	}
	p.waiting = false
	b := make(Buf, context.temp_allocator)
	f_obj(&b, "inputResponses")
	for s in p.inputs {
		w_key(&b, s.key)
		append(&b, s.response)
	}
	w_close(&b)
	_clear_inputs(c, p)
	if c.state != .Ready {
		p.sent = false
		p.task_phase = .None
		return
	}
	p.task_phase = .Update
	_task_send(c, p, "tasks/update", string(b[:]))
}

@(private)
_task_cancel :: proc(c: ^Client, p: ^Pending) {
	if c.state != .Ready {
		return
	}
	saved_id, saved_sent := p.id, p.sent
	_task_send(c, p, "tasks/cancel", "")
	p.id, p.sent = saved_id, saved_sent
}

client_resume_task :: proc(c: ^Client, task_id: string, tool_name := "") -> Call {
	p := new(Pending, c.allocator)
	p.call = Call(c.next_call)
	c.next_call += 1
	p.op = .Tools_Call
	p.method = "tools/call"
	p.name = _clone(c, tool_name)
	p.task_id = _clone(c, task_id)
	p.task_seen = make([dynamic]string, c.allocator)
	p.timeout_ms = c.cfg.request_timeout_ms
	append(&c.pending, p)
	if c.state == .Ready {
		p.sent = true
		p.task_phase = .Wait
		p.task_due = _now(c)
	}
	return p.call
}

client_task_id :: proc(c: ^Client, call: Call) -> string {
	_, p := _find_call(c, call)
	if p == nil {
		return ""
	}
	return p.task_id
}

@(private)
_check_tool_result :: proc(c: ^Client, name: string, result: string) -> (string, bool) {
	if name == "" {
		return "", true
	}
	for o in c.out_schemas {
		if o.name != name {
			continue
		}
		if json_get_bool(result, "isError") {
			return "", true
		}
		sc, has_sc := json_get(result, "structuredContent")
		if !has_sc {
			return strings.concatenate({"tool ", name, " has an output schema but returned no structured content"}, context.temp_allocator), false
		}
		if !o.ok {
			return "", true
		}
		if ok, why := _schema_check(o.schema, json_trim(sc)); !ok {
			return strings.concatenate({"structured content of tool ", name, " does not match its output schema: ", why}, context.temp_allocator), false
		}
		return "", true
	}
	return "", true
}
