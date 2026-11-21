package mcp

import "core:crypto"
import "core:strings"
import "../prim"

TASKS_EXTENSION :: "io.modelcontextprotocol/tasks"
TASKS_REQUIRED_DATA :: `{"requiredCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}`

Task_Status :: enum u8 {
	Working,
	Input_Required,
	Completed,
	Failed,
	Cancelled,
}

@(rodata)
TASK_STATUS_NAMES := [Task_Status]string {
	.Working        = "working",
	.Input_Required = "input_required",
	.Completed      = "completed",
	.Failed         = "failed",
	.Cancelled      = "cancelled",
}

task_status_parse :: proc "contextless" (s: string) -> (Task_Status, bool) {
	for t in Task_Status {
		if TASK_STATUS_NAMES[t] == s {
			return t, true
		}
	}
	return .Working, false
}

task_status_terminal :: proc "contextless" (t: Task_Status) -> bool {
	return t == .Completed || t == .Failed || t == .Cancelled
}

@(private)
Task_Input :: struct {
	key: string,
	raw: string,
}

Server_Task :: struct {
	id:          string,
	ref:         Ref,
	status:      Task_Status,
	message:     string,
	created:     i64,
	updated:     i64,
	ttl:         i64,
	poll:        i64,
	result:      string,
	error:       string,
	outstanding: [dynamic]Task_Input,
	used_keys:   [dynamic]string,
	collected:   Buf,
	state:       string,
	has_state:   bool,
	authz:       string,
}

client_has_tasks :: proc(c: Client_Capabilities) -> bool {
	return c.extensions != "" && json_has(c.extensions, TASKS_EXTENSION)
}

@(private)
_task_free :: proc(s: ^Server, t: ^Server_Task) {
	delete(t.id, s.allocator)
	delete(t.message, s.allocator)
	delete(t.result, s.allocator)
	delete(t.error, s.allocator)
	for x in t.outstanding {
		delete(x.key, s.allocator)
		delete(x.raw, s.allocator)
	}
	delete(t.outstanding)
	for k in t.used_keys {
		delete(k, s.allocator)
	}
	delete(t.used_keys)
	delete(t.collected)
	delete(t.state, s.allocator)
	delete(t.authz, s.allocator)
	free(t, s.allocator)
}

@(private)
_task_purge :: proc(s: ^Server) {
	now := prim.now_ms()
	i := 0
	for i < len(s.tasks) {
		t := s.tasks[i]
		if t.ttl >= 0 && now > t.created + t.ttl {
			ordered_remove(&s.tasks, i)
			if a := _active(s, t.ref); a != nil && a.task == t {
				a.task = nil
				_cancel_active(s, t.ref, false)
			}
			_task_free(s, t)
			continue
		}
		i += 1
	}
}

@(private)
_task_find :: proc(s: ^Server, id: string) -> ^Server_Task {
	for t in s.tasks {
		if t.id == id {
			return t
		}
	}
	return nil
}

@(private)
_task_visible :: proc(s: ^Server, id: string, authz: string) -> ^Server_Task {
	t := _task_find(s, id)
	if t == nil || t.authz != authz {
		return nil
	}
	return t
}

server_create_task :: proc(s: ^Server, ref: Ref, ttl_ms: i64 = 0, poll_ms: i64 = 0, message := "") -> (id: string, ok: bool) {
	a := _active(s, ref)
	if a == nil || a.kind != .Call || a.task != nil || !s.cfg.tasks || !a.modern || a.method != "tools/call" || !client_has_tasks(a.caps) {
		return "", false
	}
	_task_purge(s)
	if len(s.tasks) >= s.cfg.max_tasks {
		oldest := -1
		for t, i in s.tasks {
			if task_status_terminal(t.status) && (oldest < 0 || t.updated < s.tasks[oldest].updated) {
				oldest = i
			}
		}
		if oldest < 0 {
			return "", false
		}
		_task_free(s, s.tasks[oldest])
		ordered_remove(&s.tasks, oldest)
	}
	raw: [16]u8
	crypto.rand_bytes(raw[:])
	hex: [32]u8
	prim.hex_encode(hex[:], raw[:])
	t := new(Server_Task, s.allocator)
	t.id = _sclone(s, string(hex[:]))
	t.ref = ref
	t.status = .Working
	t.message = _sclone(s, message)
	t.created = prim.now_ms()
	t.updated = t.created
	t.ttl = ttl_ms if ttl_ms != 0 else s.cfg.task_ttl_ms
	if t.ttl < 0 {
		t.ttl = -1
	}
	t.poll = poll_ms if poll_ms > 0 else s.cfg.task_poll_ms
	t.authz = _sclone(s, a.authz)
	t.outstanding = make([dynamic]Task_Input, s.allocator)
	t.used_keys = make([dynamic]string, s.allocator)
	t.collected = make(Buf, s.allocator)
	append(&s.tasks, t)
	b := make(Buf, context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0","id":`)
	append(&b, a.id)
	append(&b, `,"result":{"resultType":"task"`)
	_write_task_fields(&b, t, false)
	if !s.cfg.omit_server_info {
		f_obj(&b, "_meta")
		w_key(&b, META_SERVER_INFO)
		write_implementation(&b, s.cfg.info)
		w_close(&b)
	}
	append(&b, "}}")
	conn, stream := a.conn, a.stream
	a.task = t
	a.stream = 0
	_send(s, conn, stream, b[:], true, 200)
	return t.id, true
}

server_task_status :: proc(s: ^Server, ref: Ref, message: string) -> bool {
	a := _active(s, ref)
	if a == nil || a.task == nil {
		return false
	}
	t := a.task
	delete(t.message, s.allocator)
	t.message = _sclone(s, message)
	t.updated = prim.now_ms()
	_task_notify(s, t)
	return true
}

server_task_of :: proc(s: ^Server, ref: Ref) -> string {
	a := _active(s, ref)
	if a == nil || a.task == nil {
		return ""
	}
	return a.task.id
}

@(private)
_write_iso :: proc(b: ^Buf, ms: i64) {
	secs := ms / 1000
	if ms < 0 && ms % 1000 != 0 {
		secs -= 1
	}
	frac := ms - secs * 1000
	days := secs / 86400
	rem := secs - days * 86400
	if rem < 0 {
		rem += 86400
		days -= 1
	}
	z := days + 719468
	era := (z if z >= 0 else z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	if m <= 2 {
		y += 1
	}
	two :: proc(b: ^Buf, v: i64) {
		append(b, u8('0' + v / 10), u8('0' + v % 10))
	}
	append(b, '"')
	w_int(b, y)
	append(b, '-')
	two(b, m)
	append(b, '-')
	two(b, d)
	append(b, 'T')
	two(b, rem / 3600)
	append(b, ':')
	two(b, (rem / 60) % 60)
	append(b, ':')
	two(b, rem % 60)
	append(b, '.')
	append(b, u8('0' + frac / 100), u8('0' + (frac / 10) % 10), u8('0' + frac % 10))
	append(b, "Z\"")
}

@(private)
_write_task_fields :: proc(b: ^Buf, t: ^Server_Task, detailed: bool) {
	f_str(b, "taskId", t.id)
	f_str(b, "status", TASK_STATUS_NAMES[t.status])
	if t.message != "" {
		f_str(b, "statusMessage", t.message)
	}
	w_key(b, "createdAt")
	_write_iso(b, t.created)
	w_key(b, "lastUpdatedAt")
	_write_iso(b, t.updated)
	if t.ttl >= 0 {
		f_int(b, "ttlMs", t.ttl)
	} else {
		f_raw(b, "ttlMs", "null")
	}
	f_int(b, "pollIntervalMs", t.poll)
	if !detailed {
		return
	}
	switch t.status {
	case .Input_Required:
		f_obj(b, "inputRequests")
		for x in t.outstanding {
			w_key(b, x.key)
			append(b, x.raw)
		}
		w_close(b)
	case .Completed:
		f_raw(b, "result", t.result)
	case .Failed:
		f_raw(b, "error", t.error)
	case .Working, .Cancelled:
	}
}

@(private)
_task_notify :: proc(s: ^Server, t: ^Server_Task) {
	targets := make([dynamic]Ref, context.temp_allocator)
	for a in s.actives {
		if a.kind != .Listen || a.done {
			continue
		}
		for id in a.sub_tasks {
			if id == t.id {
				append(&targets, a.ref)
				break
			}
		}
	}
	for r in targets {
		a := _active(s, r)
		if a == nil {
			continue
		}
		members := make(Buf, context.temp_allocator)
		_write_task_fields(&members, t, true)
		b := make(Buf, context.temp_allocator)
		_write_sub_notification(&b, "notifications/tasks", a.id, string(members[:]))
		_send(s, a.conn, a.stream, b[:], false, 200)
	}
}

@(private)
_task_complete :: proc(s: ^Server, a: ^Active, members: string) -> bool {
	t := a.task
	m := json_trim(members)
	if len(m) >= 2 && m[0] == '{' {
		m = m[1:len(m) - 1]
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	append(&b, m)
	w_sep(&b)
	f_str(&b, "resultType", "complete")
	append(&b, '}')
	if t.status != .Cancelled {
		delete(t.result, s.allocator)
		t.result = _sclone(s, string(b[:]))
		t.status = .Completed
		t.updated = prim.now_ms()
	}
	_task_detach(s, a)
	_task_notify(s, t)
	return true
}

@(private)
_task_fail :: proc(s: ^Server, a: ^Active, code: i64, message: string, data: string) -> bool {
	t := a.task
	if t.status != .Cancelled {
		b := make(Buf, context.temp_allocator)
		append(&b, `{"code":`)
		w_int(&b, code)
		f_str(&b, "message", message)
		if data != "" {
			f_raw(&b, "data", data)
		}
		append(&b, '}')
		delete(t.error, s.allocator)
		t.error = _sclone(s, string(b[:]))
		delete(t.message, s.allocator)
		t.message = _sclone(s, message)
		t.status = .Failed
		t.updated = prim.now_ms()
	}
	_task_detach(s, a)
	_task_notify(s, t)
	return true
}

@(private)
_task_detach :: proc(s: ^Server, a: ^Active) {
	a.task = nil
	_remove_active(s, a)
}

@(private)
_task_input :: proc(s: ^Server, a: ^Active, reqs: string, state: string, has_state: bool) -> bool {
	t := a.task
	if t.status == .Cancelled {
		return false
	}
	it, _ := json_object(reqs)
	for k, _ in json_next_member(&it) {
		key, _ := json_string(k)
		for u in t.used_keys {
			if u == key {
				return _task_fail(s, a, JSONRPC_INTERNAL_ERROR, "input request key reused within a task", "")
			}
		}
	}
	for x in t.outstanding {
		delete(x.key, s.allocator)
		delete(x.raw, s.allocator)
	}
	clear(&t.outstanding)
	clear(&t.collected)
	it2, _ := json_object(reqs)
	for k, v in json_next_member(&it2) {
		key, _ := json_string(k)
		append(&t.outstanding, Task_Input{key = _sclone(s, key), raw = _sclone(s, json_trim(v))})
		append(&t.used_keys, _sclone(s, key))
	}
	delete(t.state, s.allocator)
	t.state = _sclone(s, state)
	t.has_state = has_state
	if len(t.outstanding) == 0 {
		_task_resume(s, a)
		return true
	}
	t.status = .Input_Required
	t.updated = prim.now_ms()
	_task_notify(s, t)
	return true
}

@(private)
_task_resume :: proc(s: ^Server, a: ^Active) {
	t := a.task
	t.status = .Working
	t.updated = prim.now_ms()
	resp := make(Buf, context.temp_allocator)
	append(&resp, '{')
	append(&resp, ..t.collected[:])
	append(&resp, '}')
	clear(&t.collected)
	state := strings.clone(t.state, context.temp_allocator)
	_task_notify(s, t)
	req := Request {
		ref             = a.ref,
		conn            = a.conn,
		method          = a.method,
		params          = a.params,
		version         = a.version,
		modern          = true,
		client          = a.caps,
		client_info     = a.client_info,
		input_responses = string(resp[:]),
		request_state   = state,
		has_state       = t.has_state,
		authorization   = a.authz,
	}
	req.meta, _ = json_get_object(a.params, "_meta")
	req.name, _ = json_get_string(a.params, "name")
	if x, ok := json_get(a.params, "arguments"); ok {
		req.arguments = json_trim(x)
	} else {
		req.arguments = "{}"
	}
	a.in_handler = true
	a.handler(a.hdata, s, &req)
	a.in_handler = false
	if a.done {
		_active_free(s, a)
	}
}

@(private)
_on_task_request :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, req: ^Request) {
	if !client_has_tasks(req.client) {
		_reply_error(s, c.id, stream, m.id, MCP_MISSING_CLIENT_CAPABILITY, "Missing required client capability", TASKS_REQUIRED_DATA, 400 if c.http else 200)
		return
	}
	_task_purge(s)
	id, ok := json_get_string(req.params, "taskId")
	t := _task_visible(s, id, req.authorization) if ok else nil
	if t == nil {
		_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "Task not found")
		return
	}
	switch m.method {
	case "tasks/get":
		b := make(Buf, context.temp_allocator)
		append(&b, '{')
		_write_task_fields(&b, t, true)
		_write_result_tail(s, &b, true)
		_send_result(s, c.id, stream, m.id, string(b[:]))
	case "tasks/update":
		responses, rok := json_get_object(req.params, "inputResponses")
		if !rok {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "inputResponses is required")
			return
		}
		b := make(Buf, context.temp_allocator)
		append(&b, '{')
		_write_result_tail(s, &b, true)
		_send_result(s, c.id, stream, m.id, string(b[:]))
		if t.status != .Input_Required {
			return
		}
		it, _ := json_object(responses)
		for k, v in json_next_member(&it) {
			key, _ := json_string(k)
			for x, i in t.outstanding {
				if x.key == key {
					w_key(&t.collected, key)
					append(&t.collected, json_trim(v))
					delete(x.key, s.allocator)
					delete(x.raw, s.allocator)
					ordered_remove(&t.outstanding, i)
					break
				}
			}
		}
		if len(t.outstanding) == 0 {
			a := _active(s, t.ref)
			if a != nil && a.task == t {
				_task_resume(s, a)
			}
		} else {
			t.updated = prim.now_ms()
		}
	case "tasks/cancel":
		b := make(Buf, context.temp_allocator)
		append(&b, '{')
		_write_result_tail(s, &b, true)
		_send_result(s, c.id, stream, m.id, string(b[:]))
		if task_status_terminal(t.status) {
			return
		}
		t.status = .Cancelled
		t.updated = prim.now_ms()
		a := _active(s, t.ref)
		if a != nil && a.task == t {
			a.task = nil
			_cancel_active(s, t.ref, false)
		}
		_task_notify(s, t)
	}
}
