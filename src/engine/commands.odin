package engine

import "base:runtime"
import "core:mem/virtual"
import "../convo"
import "../pack"
import omap "../map"
import "../obj"
import "../prim"

Cmd_Send :: struct {
	object:      Object,
	text:        string,
	parent:      Rid,
	role:        convo.Role,
	attachments: []convo.Attachment,
	provider:    string,
	model:       string,
}

Cmd_Queue :: struct {
	object:      Object,
	text:        string,
	attachments: []convo.Attachment,
}

Cmd_Steer :: struct {
	object:      Object,
	text:        string,
	msg:         Rid,
	attachments: []convo.Attachment,
}

Cmd_Edit :: struct {
	object:      Object,
	item:        Rid,
	text:        string,
	attachments: []convo.Attachment,
}

Cmd_Cancel :: struct {
	object: Object,
	item:   Rid,
}

Cmd_Interrupt :: struct {
	object: Object,
	msg:    Rid,
}

Cmd_Answer :: struct {
	object:  Object,
	request: Rid,
	allow:   bool,
	text:    string,
}

Cmd_Switch :: struct {
	object:  Object,
	sibling: Rid,
}

Cmd_Back :: struct {
	object: Object,
	msg:    Rid,
}

Cmd_Follow :: struct {
	object: Object,
}

Cmd_Mount :: struct {
	object: Object,
	name:   string,
	tree:   prim.Id,
	line:   prim.Id,
	path:   string,
}

Cmd_Unmount :: struct {
	object: Object,
	name:   string,
}

Cmd_Await :: struct {
	object:    Object,
	tasks:     []prim.Id,
	condition: convo.Condition,
	deadline:  prim.Hlc,
	expr:      string,
}

Cmd_Assign :: struct {
	object: Object,
	msg:    Rid,
	runner: prim.Id,
}

Cmd_Redact :: struct {
	object: Object,
	msg:    Rid,
}

Cmd_Map_Set :: struct {
	object: Object,
	key:    []u8,
	fields: []omap.Field,
}

Cmd_Map_Delete :: struct {
	object: Object,
	key:    []u8,
	tags:   []u32,
}

Cmd_Map_Add :: struct {
	object:  Object,
	key:     []u8,
	tag:     u32,
	element: []u8,
}

Cmd_Map_Remove :: struct {
	object:  Object,
	key:     []u8,
	tag:     u32,
	element: []u8,
}

Cmd_Text_Edit :: struct {
	object: Object,
	pos:    int,
	remove: int,
	insert: string,
}

Catalog_Field :: enum u8 {
	Title,
	Archived,
	Pinned,
	Parent,
	Workspace,
	Agent,
	Storage,
	Takeover,
}

Catalog_Fields :: bit_set[Catalog_Field;u8]

Cmd_Catalog_Set :: struct {
	object:    Object,
	set:       Catalog_Fields,
	title:     string,
	archived:  bool,
	pinned:    bool,
	parent:    obj.Xref,
	workspace: prim.Id,
	agent:     prim.Id,
	storage:   Storage_Class,
	takeover:  Takeover,
}

Command :: union {
	Cmd_Send,
	Cmd_Queue,
	Cmd_Steer,
	Cmd_Edit,
	Cmd_Cancel,
	Cmd_Interrupt,
	Cmd_Answer,
	Cmd_Switch,
	Cmd_Back,
	Cmd_Follow,
	Cmd_Mount,
	Cmd_Unmount,
	Cmd_Await,
	Cmd_Assign,
	Cmd_Redact,
	Cmd_Map_Set,
	Cmd_Map_Delete,
	Cmd_Map_Add,
	Cmd_Map_Remove,
	Cmd_Text_Edit,
	Cmd_Catalog_Set,
}

Result :: struct {
	item: Rid,
	off:  i64,
	leaf: Rid,
	tick: u64,
}

Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, e: ^Engine, res: ^Result, err: Error),
}

@(private)
Cmd_State :: struct {
	msg:   Rid,
	stage: int,
}

@(private)
Pending_Cmd :: struct {
	arena: virtual.Arena,
	cmd:   Command,
	state: Cmd_State,
	done:  Done,
}

exec :: proc(e: ^Engine, cmd: Command, done: Done = {}) -> (res: Result, err: Error) {
	context = context_for(e)
	if sp, settling := _space_settling_id(e, _cmd_object(cmd).space); settling {
		p := new(Pending_Cmd, e.allocator)
		if virtual.arena_init_growing(&p.arena) != nil {
			free(p, e.allocator)
			return res, .No_Memory
		}
		p.cmd = _cmd_clone(cmd, virtual.arena_allocator(&p.arena))
		p.done = done
		if werr := _space_wait(e, sp, {}, p); werr != .Pending {
			_cmd_free(e, p)
			return res, werr
		}
		return res, .Pending
	}
	st: Cmd_State
	h: ^Handle
	if len(e.held) > 0 || _object_blocked(e, _cmd_object(cmd).id) {
		p := new(Pending_Cmd, e.allocator)
		if virtual.arena_init_growing(&p.arena) != nil {
			free(p, e.allocator)
			return res, .No_Memory
		}
		p.cmd = _cmd_clone(cmd, virtual.arena_allocator(&p.arena))
		p.done = done
		_queue_behind(e, p)
		return res, .Pending
	}
	res, h, err = _cmd_run(e, cmd, &st)
	busy := err == .Busy && pack.pressure(&e.pk)
	if !busy && (err != .Missing || h == nil) {
		res.tick = pending_seq(e)
		return res, err
	}
	p := new(Pending_Cmd, e.allocator)
	if virtual.arena_init_growing(&p.arena) != nil {
		free(p, e.allocator)
		return res, .No_Memory
	}
	p.cmd = _cmd_clone(cmd, virtual.arena_allocator(&p.arena))
	p.state = st
	p.done = done
	if busy {
		append(&e.held, p)
		return res, .Pending
	}
	werr := _wait(e, h, {}, p)
	if werr != .Pending {
		_cmd_free(e, p)
		return res, werr
	}
	return res, .Pending
}

convo_send :: proc(e: ^Engine, o: Object, text: string, parent: Rid = {}, attachments: []convo.Attachment = nil, done: Done = {}) -> (msg: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Send{object = o, text = text, parent = parent, attachments = attachments}, done)
	return r.item, x
}

convo_queue :: proc(e: ^Engine, o: Object, text: string, attachments: []convo.Attachment = nil, done: Done = {}) -> (item: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Queue{object = o, text = text, attachments = attachments}, done)
	return r.item, x
}

convo_steer :: proc(e: ^Engine, o: Object, text: string, msg: Rid = {}, done: Done = {}) -> (item: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Steer{object = o, text = text, msg = msg}, done)
	return r.item, x
}

convo_edit :: proc(e: ^Engine, o: Object, item: Rid, text: string, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Edit{object = o, item = item, text = text}, done)
	return x
}

convo_cancel :: proc(e: ^Engine, o: Object, item: Rid, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Cancel{object = o, item = item}, done)
	return x
}

convo_interrupt :: proc(e: ^Engine, o: Object, msg: Rid = {}, done: Done = {}) -> (item: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Interrupt{object = o, msg = msg}, done)
	return r.item, x
}

convo_answer :: proc(e: ^Engine, o: Object, request: Rid, allow: bool, text := "", done: Done = {}) -> (item: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Answer{object = o, request = request, allow = allow, text = text}, done)
	return r.item, x
}

convo_switch :: proc(e: ^Engine, o: Object, sibling: Rid, done: Done = {}) -> (leaf: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Switch{object = o, sibling = sibling}, done)
	return r.leaf, x
}

convo_back :: proc(e: ^Engine, o: Object, msg: Rid, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Back{object = o, msg = msg}, done)
	return x
}

convo_follow :: proc(e: ^Engine, o: Object, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Follow{object = o}, done)
	return x
}

convo_mount :: proc(e: ^Engine, o: Object, name: string, tree: prim.Id, line: prim.Id, path := "", done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Mount{object = o, name = name, tree = tree, line = line, path = path}, done)
	return x
}

convo_unmount :: proc(e: ^Engine, o: Object, name: string, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Unmount{object = o, name = name}, done)
	return x
}

convo_redact :: proc(e: ^Engine, o: Object, msg: Rid, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Redact{object = o, msg = msg}, done)
	return x
}

map_set :: proc(e: ^Engine, o: Object, key: []u8, fields: []omap.Field, done: Done = {}) -> (off: i64, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Map_Set{object = o, key = key, fields = fields}, done)
	return r.off, x
}

map_delete :: proc(e: ^Engine, o: Object, key: []u8, tags: []u32, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Map_Delete{object = o, key = key, tags = tags}, done)
	return x
}

map_add :: proc(e: ^Engine, o: Object, key: []u8, tag: u32, element: []u8, done: Done = {}) -> (id: Rid, err: Error) {
	context = context_for(e)
	r, x := exec(e, Cmd_Map_Add{object = o, key = key, tag = tag, element = element}, done)
	return r.item, x
}

map_remove :: proc(e: ^Engine, o: Object, key: []u8, tag: u32, element: []u8, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Map_Remove{object = o, key = key, tag = tag, element = element}, done)
	return x
}

text_edit :: proc(e: ^Engine, o: Object, pos: int, remove: int, insert: string, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, Cmd_Text_Edit{object = o, pos = pos, remove = remove, insert = insert}, done)
	return x
}

catalog_set :: proc(e: ^Engine, c: Cmd_Catalog_Set, done: Done = {}) -> Error {
	context = context_for(e)
	_, x := exec(e, c, done)
	return x
}

@(private)
_cmd_object :: proc(cmd: Command) -> Object {
	switch c in cmd {
	case Cmd_Send:
		return c.object
	case Cmd_Queue:
		return c.object
	case Cmd_Steer:
		return c.object
	case Cmd_Edit:
		return c.object
	case Cmd_Cancel:
		return c.object
	case Cmd_Interrupt:
		return c.object
	case Cmd_Answer:
		return c.object
	case Cmd_Switch:
		return c.object
	case Cmd_Back:
		return c.object
	case Cmd_Follow:
		return c.object
	case Cmd_Mount:
		return c.object
	case Cmd_Unmount:
		return c.object
	case Cmd_Await:
		return c.object
	case Cmd_Assign:
		return c.object
	case Cmd_Redact:
		return c.object
	case Cmd_Map_Set:
		return c.object
	case Cmd_Map_Delete:
		return c.object
	case Cmd_Map_Add:
		return c.object
	case Cmd_Map_Remove:
		return c.object
	case Cmd_Text_Edit:
		return c.object
	case Cmd_Catalog_Set:
		return c.object
	}
	return {}
}

@(private)
_cmd_retry :: proc(e: ^Engine, p: ^Pending_Cmd, tries: int) {
	res, h, err := _cmd_run(e, p.cmd, &p.state)
	if err == .Busy && pack.pressure(&e.pk) {
		append(&e.held, p)
		return
	}
	if err == .Missing && h != nil {
		werr := _wait(e, h, {}, p, tries)
		if werr == .Pending {
			return
		}
		err = werr
	}
	res.tick = pending_seq(e)
	if p.done.call != nil {
		{
			context = _outer(e)
			p.done.call(p.done.data, e, &res, err)
		}
	}
	_cmd_free(e, p)
}

@(private)
_cmd_fail :: proc(e: ^Engine, p: ^Pending_Cmd, err: Error) {
	if p.done.call != nil {
		res: Result
		{
			context = _outer(e)
			p.done.call(p.done.data, e, &res, err)
		}
	}
	_cmd_free(e, p)
}

@(private)
_cmd_free :: proc(e: ^Engine, p: ^Pending_Cmd) {
	virtual.arena_destroy(&p.arena)
	free(p, e.allocator)
}

@(private)
_convo_writable :: proc(e: ^Engine, o: Object) -> (h: ^Handle, err: Error) {
	h = _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	if err = _handle_create_writer(h); err != .None {
		return h, err
	}
	return h, .None
}

@(private)
_cmd_run :: proc(e: ^Engine, cmd: Command, st: ^Cmd_State) -> (res: Result, h: ^Handle, err: Error) {
	switch c in cmd {
	case Cmd_Send:
		h = _convo_writable(e, c.object) or_return
		if st.stage == 0 {
			spec := convo.Msg_Spec {
				role     = c.role if c.role != convo.Role(0) else .User,
				author   = e.self,
				parent   = c.parent,
				provider = c.provider,
				model    = c.model,
			}
			msg, merr := convo.writer_message(&h.cw, spec)
			if merr != .None {
				return res, h, _oerr(merr)
			}
			st.msg = msg
			st.stage = 1
			_handle_mark(h)
		}
		if len(c.text) > 0 {
			_, berr := convo.writer_block(&h.cw, st.msg, .Text, transmute([]u8)c.text)
			if berr != .None {
				return res, h, _oerr(berr)
			}
		}
		for a in c.attachments {
			blob := convo.Blob{oid = a.oid, size = a.size}
			_, berr := convo.writer_block_ref(&h.cw, st.msg, .File, blob, a.mime, a.name)
			if berr != .None {
				return res, h, _oerr(berr)
			}
		}
		seal, serr := convo.writer_seal(&h.cw, st.msg, .Done)
		if serr != .None {
			return res, h, _oerr(serr)
		}
		res.item = st.msg
		res.off = seal.off
		_catalog_activity(e, h)
	case Cmd_Queue:
		h = _convo_writable(e, c.object) or_return
		item, x := convo.writer_queue(&h.cw, c.text, c.attachments)
		err = _oerr(x)
		res.item = item
	case Cmd_Steer:
		h = _convo_writable(e, c.object) or_return
		item, x := convo.writer_steer(&h.cw, c.text, c.msg, c.attachments)
		err = _oerr(x)
		res.item = item
	case Cmd_Edit:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_edit_queued(&h.cw, c.item, c.text, c.attachments)
		err = _oerr(x)
		res.off = off
	case Cmd_Cancel:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_cancel(&h.cw, c.item)
		err = _oerr(x)
		res.off = off
	case Cmd_Interrupt:
		h = _convo_writable(e, c.object) or_return
		item, x := convo.writer_interrupt(&h.cw, c.msg)
		err = _oerr(x)
		res.item = item
	case Cmd_Answer:
		h = _convo_writable(e, c.object) or_return
		item, x := convo.writer_answer(&h.cw, c.request, c.allow, c.text)
		err = _oerr(x)
		res.item = item
	case Cmd_Switch:
		h = _convo_writable(e, c.object) or_return
		leaf, off, x := convo.writer_switch(&h.cw, c.sibling)
		err = _oerr(x)
		res.leaf = leaf
		res.off = off
	case Cmd_Back:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_set_leaf(&h.cw, c.msg)
		err = _oerr(x)
		res.off = off
		res.leaf = c.msg
	case Cmd_Follow:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_follow(&h.cw)
		err = _oerr(x)
		res.off = off
	case Cmd_Mount:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_mount(&h.cw, c.name, c.tree, c.line, c.path)
		err = _oerr(x)
		res.off = off
	case Cmd_Unmount:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_unmount(&h.cw, c.name)
		err = _oerr(x)
		res.off = off
	case Cmd_Await:
		h = _convo_writable(e, c.object) or_return
		item, x := convo.writer_await(&h.cw, c.tasks, c.condition, c.deadline, c.expr)
		err = _oerr(x)
		res.item = item
	case Cmd_Assign:
		h = _convo_writable(e, c.object) or_return
		off, x := convo.writer_assign(&h.cw, c.msg, c.runner)
		err = _oerr(x)
		res.off = off
	case Cmd_Redact:
		h = _convo_writable(e, c.object) or_return
		err = _redact_message(e, h, c.msg)
	case Cmd_Map_Set:
		h = _map_writable(e, c.object) or_return
		off, x := omap.put(&h.mw, c.key, c.fields)
		err = _oerr(x)
		res.off = off
	case Cmd_Map_Delete:
		h = _map_writable(e, c.object) or_return
		fields := make([]omap.Field, len(c.tags), context.temp_allocator)
		for t, i in c.tags {
			fields[i] = omap.Field{tag = t}
		}
		off, x := omap.put(&h.mw, c.key, fields)
		err = _oerr(x)
		res.off = off
	case Cmd_Map_Add:
		h = _map_writable(e, c.object) or_return
		id, x := omap.add(&h.mw, c.key, c.tag, c.element)
		err = _oerr(x)
		res.item = id
	case Cmd_Map_Remove:
		h = _map_writable(e, c.object) or_return
		observed, oerr := _map_observed(e, h, c.key, c.tag, c.element)
		if oerr != .None {
			return res, h, oerr
		}
		off, x := omap.del(&h.mw, c.key, c.tag, c.element, observed)
		err = _oerr(x)
		res.off = off
	case Cmd_Text_Edit:
		h = _handle_get(e, c.object, .Text) or_return
		err = _text_edit(e, h, c.pos, c.remove, c.insert)
	case Cmd_Catalog_Set:
		err = _catalog_set(e, c)
	}
	if h != nil && err == .None {
		_handle_mark(h)
		_, redacting := cmd.(Cmd_Redact)
		if h.kind == .Conversation && !redacting {
			_catalog_activity(e, h)
		}
	}
	return
}

@(private)
_cmd_clone :: proc(cmd: Command, a: runtime.Allocator) -> Command {
	s :: proc(x: string, a: runtime.Allocator) -> string {
		out, _ := _clone(x, a)
		return out
	}
	b :: proc(x: []u8, a: runtime.Allocator) -> []u8 {
		out, _ := _clone_bytes(x, a)
		return out
	}
	atts :: proc(x: []convo.Attachment, a: runtime.Allocator) -> []convo.Attachment {
		if len(x) == 0 {
			return nil
		}
		out := make([]convo.Attachment, len(x), a)
		for v, i in x {
			out[i] = convo.Attachment{name = s(v.name, a), mime = s(v.mime, a), oid = b(v.oid, a), size = v.size}
		}
		return out
	}
	switch c in cmd {
	case Cmd_Send:
		x := c
		x.text = s(c.text, a)
		x.provider = s(c.provider, a)
		x.model = s(c.model, a)
		x.attachments = atts(c.attachments, a)
		return x
	case Cmd_Queue:
		x := c
		x.text = s(c.text, a)
		x.attachments = atts(c.attachments, a)
		return x
	case Cmd_Steer:
		x := c
		x.text = s(c.text, a)
		x.attachments = atts(c.attachments, a)
		return x
	case Cmd_Edit:
		x := c
		x.text = s(c.text, a)
		x.attachments = atts(c.attachments, a)
		return x
	case Cmd_Answer:
		x := c
		x.text = s(c.text, a)
		return x
	case Cmd_Mount:
		x := c
		x.name = s(c.name, a)
		x.path = s(c.path, a)
		return x
	case Cmd_Unmount:
		x := c
		x.name = s(c.name, a)
		return x
	case Cmd_Await:
		x := c
		x.expr = s(c.expr, a)
		if len(c.tasks) > 0 {
			t := make([]prim.Id, len(c.tasks), a)
			copy(t, c.tasks)
			x.tasks = t
		}
		return x
	case Cmd_Map_Set:
		x := c
		x.key = b(c.key, a)
		f := make([]omap.Field, len(c.fields), a)
		for v, i in c.fields {
			f[i] = omap.Field{tag = v.tag, hlc = v.hlc, value = b(v.value, a)}
		}
		x.fields = f
		return x
	case Cmd_Map_Delete:
		x := c
		x.key = b(c.key, a)
		t := make([]u32, len(c.tags), a)
		copy(t, c.tags)
		x.tags = t
		return x
	case Cmd_Map_Add:
		x := c
		x.key = b(c.key, a)
		x.element = b(c.element, a)
		return x
	case Cmd_Map_Remove:
		x := c
		x.key = b(c.key, a)
		x.element = b(c.element, a)
		return x
	case Cmd_Text_Edit:
		x := c
		x.insert = s(c.insert, a)
		return x
	case Cmd_Catalog_Set:
		x := c
		x.title = s(c.title, a)
		return x
	case Cmd_Cancel, Cmd_Interrupt, Cmd_Switch, Cmd_Back, Cmd_Follow, Cmd_Assign, Cmd_Redact:
		return cmd
	}
	return cmd
}

pressured :: proc(e: ^Engine) -> bool {
	context = context_for(e)
	return e.pk_open && pack.pressure(&e.pk)
}

@(private)
_held_retry :: proc(e: ^Engine) {
	if len(e.held) == 0 || pack.pressure(&e.pk) {
		return
	}
	list := e.held
	e.held = make([dynamic]^Pending_Cmd, e.allocator)
	for p in list {
		if len(e.held) > 0 || _object_blocked(e, _cmd_object(p.cmd).id) {
			_queue_behind(e, p)
			continue
		}
		_cmd_retry(e, p, 0)
	}
	delete(list)
}

@(private)
_object_blocked :: proc(e: ^Engine, obj: prim.Id) -> bool {
	for p in e.held {
		if _cmd_object(p.cmd).id == obj {
			return true
		}
	}
	for w in e.waiters {
		if w.cmd != nil && w.object == obj {
			return true
		}
	}
	return false
}

@(private)
_queue_behind :: proc(e: ^Engine, p: ^Pending_Cmd) {
	obj := _cmd_object(p.cmd).id
	for w in e.waiters {
		if w.cmd != nil && w.object == obj {
			n := new(Waiter, e.allocator)
			n.space = w.space
			n.object = obj
			n.cmd = p
			n.tick = e.tick
			append(&e.waiters, n)
			return
		}
	}
	append(&e.held, p)
}
