package rt

import "base:runtime"
import "core:mem/virtual"
import "../agent"
import "../convo"
import eng "../engine"
import "../fs"
import "../journal"
import "../obj"
import "../observe"
import "../odb"
import "../prim"

Run_State :: enum u8 {
	Preparing,
	Running,
	Stopping,
	Finished,
}

Run_Tool :: struct {
	id:      string,
	name:    string,
	parent:  string,
	index:   u32,
	input:   string,
	call:    observe.Tool_Call,
	has_obs: bool,
	token:   u64,
	done:    bool,
	scope:   int,
}

Run_Perm :: struct {
	id:    string,
	block: Rid,
}

Run :: struct {
	r:            ^Runtime,
	arena:        virtual.Arena,
	alloc:        runtime.Allocator,
	o:            Object,
	ai:           Agent_Info,
	state:        Run_State,
	user:         Rid,
	parent:       Rid,
	reply:        Rid,
	claim:        Rid,
	text:         string,
	files:        []agent.Attachment,
	revive:       bool,
	attempt:      u8,
	cur:          i64,
	cur_kind:     convo.Block_Kind,
	tools:        [dynamic]Run_Tool,
	file_holds:   [dynamic]File_Hold,
	perms:        [dynamic]Run_Perm,
	steered:      [dynamic]Rid,
	usage:        convo.Usage,
	cost:         f64,
	steps:        int,
	status:       convo.Seal_Status,
	error:        string,
	checkpoint:   string,
	native_items: [dynamic]u8,
	interrupting: bool,
	kill_timer:   prim.Timer,
	int_timer:    prim.Timer,
	budget_timer: prim.Timer,
	superseded:   bool,
	by:           Rid,
	cancelled:    bool,
	proc_:        ^Proc,
	native:       ^Native,
	ws:           ^Worktree,
	sub:          eng.Sub_Id,
	raw:          journal.Journal,
	raw_open:     bool,
	line_at:      fs.Observe_Since,
	line_prev:    fs.Observe_Since,
	raw_link:     Rid,
	started_ms:   i64,
	token:        string,
	sealed:       bool,
	pinned:       bool,
	lines:        []convo.Line,
	bound:        []convo.Line_Bind,
	hold:         convo.Hold_Reason,
	hold_line:    string,
	hold_commit:  string,
	holding:      bool,
	revive_of:    Rid,
	renew_timer:  prim.Timer,
}

@(private)
RAW_STDOUT :: u8(1)
@(private)
RAW_STDERR :: u8(2)
@(private)
RAW_STDIN :: u8(3)
@(private)
RAW_META :: u8(4)
@(private)
RAW_HTTP :: u8(5)
@(private)
RAW_OWNER :: u8(6)
@(private)
RAW_LINK :: u8(7)

run_find :: proc(r: ^Runtime, o: Object) -> ^Run {
	for run in r.runs {
		if run.o == o {
			return run
		}
	}
	return nil
}

@(private)
_run_new :: proc(r: ^Runtime, o: Object) -> ^Run {
	run := new(Run, r.allocator)
	run.r = r
	run.o = o
	run.cur = -1
	if !_arena_init(&run.arena) {
		free(run, r.allocator)
		return nil
	}
	run.alloc = virtual.arena_allocator(&run.arena)
	run.tools = make([dynamic]Run_Tool, run.alloc)
	run.perms = make([dynamic]Run_Perm, run.alloc)
	run.steered = make([dynamic]Rid, run.alloc)
	run.native_items = make([dynamic]u8, run.alloc)
	run.started_ms = wall_ms(r)
	append(&r.runs, run)
	return run
}

@(private)
_run_free :: proc(run: ^Run) {
	r := run.r
	l := eng.loop(r.e)
	if run.kill_timer != 0 {
		prim.timer_cancel(l, run.kill_timer)
	}
	if run.int_timer != 0 {
		prim.timer_cancel(l, run.int_timer)
	}
	if run.budget_timer != 0 {
		prim.timer_cancel(l, run.budget_timer)
	}
	if run.renew_timer != 0 {
		prim.timer_cancel(l, run.renew_timer)
	}
	for &t in run.tools {
		if t.has_obs {
			observe.tool_call_destroy(&t.call)
		}
	}
	if run.raw_open {
		journal.journal_commit(&run.raw)
		journal.journal_close(&run.raw)
		run.raw_open = false
	}
	if run.sub != 0 {
		eng.unsubscribe(r.e, run.sub)
	}
	if len(run.token) > 0 {
		serve_revoke(r, run.token)
	}
	if run.pinned {
		eng.unpin(r.e, run.o)
	}
	for x, i in r.runs {
		if x == run {
			ordered_remove(&r.runs, i)
			break
		}
	}
	virtual.arena_destroy(&run.arena)
	free(run, r.allocator)
	if !r.closing {
		_hold_waits_check(r)
		undo_kick(r)
	}
}

@(private)
_writer :: proc(run: ^Run) -> ^convo.Writer {
	w, err := eng.convo_writer(run.r.e, run.o)
	if err != .None {
		return nil
	}
	return w
}

run_raw :: proc(run: ^Run, kind: u8, data: []u8) -> (off: i64) {
	off = -1
	r := run.r
	if !run.raw_open {
		id := run.o.id
		path := concat(r.e.pack_root, "/raw/", hex(id))
		dir := prim.dir_name(path)
		prim.mkdir_all(eng.vfs(r.e), dir, 0o700)
		if journal.journal_open(&run.raw, eng.vfs(r.e), path, {}, r.allocator) != .None {
			return
		}
		run.raw_open = true
		meta := make(Buf, context.temp_allocator)
		append(&meta, RAW_META)
		c := rid_bytes(run.claim)
		append(&meta, ..c)
		journal.journal_append(&run.raw, meta[:])
		run_raw_owner(run)
	}
	body := make([]u8, len(data) + 1, context.temp_allocator)
	body[0] = kind
	copy(body[1:], data)
	at, err := journal.journal_append(&run.raw, body)
	if err == .None {
		off = at
	}
	if kind == RAW_STDOUT || kind == RAW_HTTP {
		run.line_prev = run.line_at
		run.line_at = fs.Observe_Since{mono = prim.clock_mono_ns(r.e.cfg.clock), wall = prim.clock_wall_ns(r.e.cfg.clock)}
	}
	r.stats.raw_lines += 1
	return
}

run_raw_commit :: proc(run: ^Run) {
	if run.raw_open {
		journal.journal_commit(&run.raw)
	}
}

run_text :: proc(run: ^Run, kind: convo.Block_Kind, text: string) {
	if len(text) == 0 || run.sealed {
		return
	}
	w := _writer(run)
	if w == nil {
		return
	}
	if run.cur >= 0 && run.cur_kind == kind {
		if convo.writer_chunk(w, run.reply, u32(run.cur), transmute([]u8)text) == .None {
			return
		}
	}
	idx, err := convo.writer_block(w, run.reply, kind, transmute([]u8)text)
	if err != .None {
		return
	}
	run.cur = i64(idx)
	run.cur_kind = kind
}

run_block :: proc(run: ^Run, kind: convo.Block_Kind, data: []u8, id := "", name := "", failed := false) -> (index: u32, off: i64, ok: bool) {
	if run.sealed {
		return 0, 0, false
	}
	w := _writer(run)
	if w == nil {
		return 0, 0, false
	}
	inline_ok := !(kind == .Tool_Result || kind == .Image || kind == .File) || len(data) <= convo.INLINE_MAX
	if inline_ok {
		convo.writer_flush(w)
		before := obj.writer_len(&w.core)
		idx, err := convo.writer_block(w, run.reply, kind, data, id, name, failed)
		if err == .Too_Large {
			return run_blob_block(run, kind, data, id, name, failed)
		}
		if err != .None {
			return 0, 0, false
		}
		run.cur = i64(idx)
		run.cur_kind = kind
		convo.writer_flush(w)
		return idx, before, true
	}
	return run_blob_block(run, kind, data, id, name, failed)
}

run_blob_block :: proc(run: ^Run, kind: convo.Block_Kind, data: []u8, id := "", name := "", failed := false) -> (index: u32, off: i64, ok: bool) {
	r := run.r
	db, derr := eng.device_odb(r.e)
	if derr != .None {
		return 0, 0, false
	}
	oid, werr := odb.write(db, .Blob, data)
	if werr != .None {
		return 0, 0, false
	}
	n := 32 if db.format == .Sha256 else 20
	preview, _ := utf8_clip(string(data), convo.INLINE_MAX)
	blob := convo.Blob {
		oid     = clone_bytes(oid[:n], context.temp_allocator),
		size    = u64(len(data)),
		preview = transmute([]u8)preview,
	}
	w := _writer(run)
	if w == nil {
		return 0, 0, false
	}
	convo.writer_flush(w)
	before := obj.writer_len(&w.core)
	idx, err := convo.writer_block_ref(w, run.reply, kind, blob, id, name, failed)
	if err != .None {
		return 0, 0, false
	}
	run.cur = -1
	return idx, before, true
}

run_notice :: proc(run: ^Run, text: string) {
	run_block(run, .Notice, transmute([]u8)text)
	run.cur = -1
}

run_error :: proc(run: ^Run, text: string, code := "") {
	if len(text) == 0 {
		return
	}
	run_block(run, .Error, transmute([]u8)text, name = code)
	run.cur = -1
	if len(run.error) == 0 {
		run.error = clone(text, run.alloc)
	}
}

run_usage :: proc(run: ^Run, u: agent.Usage) {
	run.usage.input += u.input_tokens
	run.usage.output += u.output_tokens
	run.usage.cache_read += u.cache_read_tokens
	run.usage.cache_write += u.cache_write_tokens
	run.cost += u.cost_usd
	_run_budget_check(run)
}

run_tool_started :: proc(run: ^Run, id, name, input, parent: string) {
	for t in run.tools {
		if t.id == id {
			return
		}
	}
	bid := id
	if len(parent) > 0 {
		bid = concat(parent, "/", id)
	}
	idx, _, ok := run_block(run, .Tool_Call, transmute([]u8)input, bid, name)
	if !ok {
		return
	}
	t := Run_Tool {
		id     = clone(id, run.alloc),
		name   = clone(name, run.alloc),
		parent = clone(parent, run.alloc),
		index  = idx,
		input  = clone(input, run.alloc),
		scope  = -1,
	}
	if run.ws != nil {
		canonical := false
		if reg, rerr := eng.registry(run.r.e); rerr == .None {
			canonical = fs.observer_installed(reg)
		}
		observe.tool_call_init(&t.call, id, transmute([]u8)input, run.ws.root, canonical, run.alloc)
		t.has_obs = true
		t.scope = worktree_tool_open(run.ws, run, id)
	}
	append(&run.tools, t)
	run.r.stats.tool_calls += 1
}

run_tool_input :: proc(run: ^Run, id: string, delta: string) {
	for &t in run.tools {
		if t.id != id {
			continue
		}
		if run.cur == i64(t.index) && run.cur_kind == .Tool_Call {
			if w := _writer(run); w != nil {
				convo.writer_chunk(w, run.reply, t.index, transmute([]u8)delta)
			}
		}
		t.input = concat(t.input, delta)
		t.input = clone(t.input, run.alloc)
		return
	}
}

run_tool_finished :: proc(run: ^Run, id: string, output: string, is_error: bool) {
	name := ""
	for &t in run.tools {
		if t.id == id {
			if t.done {
				return
			}
			t.done = true
			name = t.name
			if t.scope >= 0 && run.ws != nil {
				worktree_tool_close(run.ws, run, t.scope)
			}
			break
		}
	}
	run_block(run, .Tool_Result, transmute([]u8)output, id, name, is_error)
	run.cur = -1
	run_hold_check(run)
}

run_bound_to :: proc(run: ^Run, tree: prim.Id, line: string) -> bool {
	return binds_have(run.bound, tree, line)
}

binds_have :: proc(binds: []convo.Line_Bind, tree: prim.Id, line: string) -> bool {
	for b in binds {
		if b.tree == tree && b.line == line {
			return true
		}
	}
	return false
}

run_hold_request :: proc(run: ^Run, reason: convo.Hold_Reason, line: string) {
	if run.state == .Finished || run.hold != .None {
		return
	}
	run.hold = reason
	run.hold_line = clone(line, run.alloc)
	if run.cur < 0 {
		run_hold_check(run)
	}
}

run_hold_check :: proc(run: ^Run) {
	if run.hold == .None || run.holding || run.interrupting || run.state != .Running {
		return
	}
	run.holding = true
	switch run.hold {
	case .Branch_Deleted:
		run_notice(run, concat("held: branch ", run.hold_line, " deleted"))
	case .Undo:
		run_notice(run, "held: undo")
	case .Branch_Changed, .None:
		run_notice(run, concat("held: the folder left ", run.hold_line, "; this turn resumes when it returns"))
	}
	run_interrupt(run)
}

run_permission :: proc(run: ^Run, id, tool, title, input: string, answered: bool) {
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "tool", tool)
	jw_kstr(&b, "title", title)
	jw_kraw(&b, "input", input if len(input) > 0 else "{}")
	append(&b, '}')
	_, off, ok := run_block(run, .Permission, b[:], id, tool)
	run.cur = -1
	if !ok {
		return
	}
	if answered {
		run_block(run, .Permission_Answer, transmute([]u8)string("auto"), id, tool)
		run.cur = -1
		return
	}
	block, berr := eng.record_rid(run.r.e, run.o, .Conversation, run.reply.seg, off)
	if berr != .None {
		return
	}
	append(&run.perms, Run_Perm{id = clone(id, run.alloc), block = block})
}

@(private)
_run_budget_check :: proc(run: ^Run) {
	b := run.ai.budget
	if run.interrupting || run.state != .Running {
		return
	}
	over := false
	if b.tokens > 0 && run.usage.input + run.usage.output + run.usage.cache_read + run.usage.cache_write >= b.tokens {
		over = true
	}
	if b.usd > 0 && run.cost >= b.usd {
		over = true
	}
	if b.turns > 0 && run.steps >= b.turns {
		over = true
	}
	if over {
		run_notice(run, "budget exhausted")
		run_interrupt(run)
	}
}

@(private)
_on_budget_timer :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Run)(data).r.e)
	run := (^Run)(data)
	run.budget_timer = 0
	if run.state == .Running && !run.interrupting {
		run_notice(run, "time budget exhausted")
		run_interrupt(run)
	}
}

run_interrupt :: proc(run: ^Run) {
	if run.interrupting || run.state == .Finished {
		return
	}
	run.interrupting = true
	if run.kill_timer == 0 {
		run.kill_timer = prim.timer(eng.loop(run.r.e), run.r.cfg.interrupt_ms, run, _on_kill_timer)
	}
	if run.proc_ != nil {
		proc_interrupt(run.proc_)
	} else if run.int_timer == 0 {
		run.int_timer = prim.timer(eng.loop(run.r.e), 0, run, _on_interrupt_timer)
	}
}

@(private)
_on_interrupt_timer :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Run)(data).r.e)
	run := (^Run)(data)
	run.int_timer = 0
	if run.state == .Finished {
		return
	}
	if run.native != nil {
		native_interrupt(run.native)
		return
	}
	run_finish(run, .Interrupted)
}

@(private)
_on_kill_timer :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Run)(data).r.e)
	run := (^Run)(data)
	run.kill_timer = 0
	if run.state == .Finished {
		return
	}
	if run.proc_ != nil {
		run_notice(run, "the agent did not stop in time and was killed")
		proc_kill(run.proc_)
		return
	}
	run_finish(run, .Interrupted)
}

run_finish :: proc(run: ^Run, status: convo.Seal_Status) {
	if run.state == .Finished {
		return
	}
	r := run.r
	_ensure_reply(run, nil)
	run.state = .Finished
	run.status = status
	if run.superseded {
		run.status = .Cancelled
	}
	for &t in run.tools {
		if !t.done {
			t.done = true
			if t.token != 0 {
				tool_abort(r, t.token)
			}
			if t.scope >= 0 && run.ws != nil {
				worktree_tool_close(run.ws, run, t.scope)
			}
			run_block(run, .Tool_Result, transmute([]u8)string("The tool call did not complete before the turn ended."), t.id, t.name, true)
		}
	}
	if run.ws != nil {
		worktree_fence(run.ws, 0, _finish_fenced)
		return
	}
	_run_finish_tail(run)
}

@(private)
_finish_fenced :: proc(r: ^Runtime, o: Object, arg: int, err: Error) {
	if run := run_find(r, o); run != nil && run.state == .Finished && !run.sealed {
		_run_finish_tail(run)
	}
}

@(private)
_run_finish_tail :: proc(run: ^Run) {
	r := run.r
	if run.holding && !run.superseded {
		_run_hold_tail(run)
		return
	}
	files: []convo.File_Delta
	land_tried, land_ok := false, false
	land_conflicts: []string
	if run.ws != nil {
		files = worktree_finish(run.ws, run, !run.superseded)
		if !run.superseded && run.status == .Done {
			if t, tok := task_get(r, run.o); tok && t.isolate == .Yes {
				land_tried, land_ok, land_conflicts = task_land(r, run.o, run.ws)
				if land_tried {
					land_refresh_files(run.ws, files)
				}
			}
		}
	}
	w := _writer(run)
	if w != nil {
		native := run.checkpoint
		if len(run.native_items) > 0 {
			native = string(run.native_items[:])
		}
		convo.writer_seal(w, run.reply, run.status, run.usage, native, run.claim.off)
		run.sealed = true
		if run.superseded {
			convo.writer_superseded(w, run.claim, run.by)
		} else if run.ws != nil {
			convo.writer_landed(w, run.claim, files, run.status)
		}
		if land_tried {
			land_note(r, run.o, w, land_ok, land_conflicts)
		}
	}
	if pe, ok := pending_get(r, run.o); ok && pe.msg == run.user && pe.runner == r.self {
		_pending_clear(r, run.o)
	}
	_awaits_settle(r, run.o)
	run_raw_commit(run)
	eng.catalog_usage(r.e, run.o, run.usage)
	usage_rollup(r, run.o, run.usage)
	state_run_clear(r, run.o)
	r.stats.runs_finished += 1
	p := run.proc_
	if p != nil {
		proc_turn_done(p, run)
	}
	if run.native != nil {
		native_done(run.native, run)
	}
	_reply_hooks(r, run.o, run.reply, run.status)
	o := run.o
	kept := false
	for x in r.procs {
		kept ||= x == p && x.ws == run.ws
	}
	if run.ws != nil && !kept {
		worktree_close(run.ws)
	}
	run.ws = nil
	_run_free(run)
	_queue_eval(r, o)
}

@(private)
_run_hold_tail :: proc(run: ^Run) {
	r := run.r
	if run.ws != nil {
		worktree_hold(run.ws, run)
	}
	if w := _writer(run); w != nil {
		convo.writer_hold(w, run.reply, run.hold, run.hold_line)
		run.sealed = true
	}
	state_run_put(r, Run_Entry{object = run.o, user = run.user, reply = run.reply, claim = run.claim, agent = run.ai.object.id, lines = lines_encode(run.lines), bound = convo.binds_encode(run.bound), hold = u8(run.hold), hold_line = run.hold_line, hold_commit = run.hold_commit})
	run_raw_commit(run)
	eng.catalog_usage(r.e, run.o, run.usage)
	usage_rollup(r, run.o, run.usage)
	r.stats.runs_held += 1
	p := run.proc_
	if p != nil {
		proc_turn_done(p, run)
	}
	if run.native != nil {
		native_done(run.native, run)
	}
	kept := false
	for x in r.procs {
		kept ||= x == p && x.ws == run.ws
	}
	if run.ws != nil && !kept {
		worktree_close(run.ws)
	}
	run.ws = nil
	_run_free(run)
}

@(private)
_run_abandon :: proc(run: ^Run) {
	if run.proc_ != nil {
		p := run.proc_
		p.run = nil
		run.proc_ = nil
		_proc_free(p, true)
	}
	if run.native != nil {
		native_free(run.native)
		run.native = nil
	}
	if run.ws != nil {
		worktree_close(run.ws)
		run.ws = nil
	}
	run_raw_commit(run)
	_run_free(run)
}

run_steer_accepted :: proc(run: ^Run, id: string) {
	for s, i in run.steered {
		if rid_uuid(s) == id {
			rid := s
			if w := _writer(run); w != nil {
				convo.writer_unqueue(w, rid, .Steered, run.reply)
			}
			ordered_remove(&run.steered, i)
			return
		}
	}
}

run_steer_dropped :: proc(run: ^Run, id: string) {
	for s, i in run.steered {
		if rid_uuid(s) == id {
			ordered_remove(&run.steered, i)
			return
		}
	}
}

run_steered :: proc(run: ^Run, item: Rid) -> bool {
	for s in run.steered {
		if s == item {
			return true
		}
	}
	return false
}

usage_rollup :: proc(r: ^Runtime, o: Object, u: convo.Usage) {
	if u == {} {
		return
	}
	cur := o
	for _ in 0 ..< 64 {
		c, found, err := eng.catalog_get(r.e, cur, context.temp_allocator)
		if err != .None || !found || prim.id_is_zero(c.parent.object) || c.parent.object == cur.id {
			return
		}
		cur = Object{o.space, c.parent.object}
		eng.catalog_usage(r.e, cur, u)
	}
}

@(private)
_awaits_settle :: proc(r: ^Runtime, o: Object) {
	items, err := eng.convo_intents(r.e, o, context.temp_allocator)
	if err != .None {
		return
	}
	for it in items {
		if it.kind != .Await || it.by != r.self {
			continue
		}
		live := false
		for w in r.awaits {
			live ||= w.caller == o && w.item == it.item
		}
		if live {
			continue
		}
		if w := _writer_of(r, o); w != nil {
			convo.writer_unqueue(w, it.item, .Rejected)
		}
	}
}

@(private)
_writer_of :: proc(r: ^Runtime, o: Object) -> ^convo.Writer {
	w, err := eng.convo_writer(r.e, o)
	if err != .None {
		return nil
	}
	return w
}
