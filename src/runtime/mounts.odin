package rt

import "base:runtime"
import "core:mem/virtual"
import "../convo"
import "../crdt"
import eng "../engine"
import "../fs"
import "../obj"
import "../observe"
import "../prim"

Wt_Member :: struct {
	name:      string,
	tree:      prim.Id,
	conv_line: prim.Id,
	run_line:  prim.Id,
	path:      string,
	dir:       string,
	m:         ^fs.Mount,
	owned:     bool,
	engine:    bool,
	borrowed:  bool,
	turn:      ^fs.Scope,
	start:     []crdt.Op_Id,
	branch:    string,
	commit:    string,
}

Wt_Tool :: struct {
	id:     string,
	scopes: []^fs.Scope,
	before: []u8,
	open:   bool,
}

Worktree :: struct {
	r:       ^Runtime,
	o:       Object,
	arena:   virtual.Arena,
	alloc:   runtime.Allocator,
	root:    string,
	members: [dynamic]Wt_Member,
	tools:   [dynamic]Wt_Tool,
	actor:   prim.Id,
	scope:   prim.Id,
	setup:   bool,
	busy:    bool,
}

line_name :: proc(id: prim.Id, allocator := context.temp_allocator) -> string {
	if prim.id_is_zero(id) {
		return "main"
	}
	return concat("l/", hex(id, allocator))
}

version_encode :: proc(v: []crdt.Op_Id, branch: string, commit: string, allocator := context.temp_allocator) -> []u8 {
	vb := make([dynamic]u8, allocator)
	fs.encode_version(&vb, v)
	b := make([dynamic]u8, allocator)
	w := prim.writer(&b)
	prim.write_bytes(&w, vb[:])
	prim.write_str(&w, branch)
	prim.write_str(&w, commit)
	return b[:]
}

version_decode :: proc(b: []u8, allocator := context.temp_allocator) -> (v: []crdt.Op_Id, branch: string, commit: string, ok: bool) {
	rd := prim.reader(b)
	vb := prim.read_bytes(&rd)
	branch = prim.read_str(&rd)
	commit = prim.read_str(&rd)
	if !prim.reader_ok(&rd) {
		return nil, "", "", false
	}
	vv, err := fs.decode_version(vb, allocator)
	if err != .None {
		return nil, "", "", false
	}
	return vv, branch, commit, true
}

agent_actor :: proc(r: ^Runtime, agent_id: prim.Id) -> prim.Id {
	me, a := r.self, agent_id
	return derive_id("0ndb-agent-actor-v1", me[:], a[:])
}

worktree_dir_busy :: proc(r: ^Runtime, dir: string, except: ^Worktree) -> bool {
	for run in r.runs {
		if run.ws != nil && run.ws != except {
			for mb in run.ws.members {
				if mb.dir == dir {
					return true
				}
			}
		}
	}
	for p in r.procs {
		if p.ws != nil && p.ws != except && p.ws.busy {
			for mb in p.ws.members {
				if mb.dir == dir {
					return true
				}
			}
		}
	}
	return false
}

worktree_open :: proc(r: ^Runtime, o: Object, run: ^Run, lines: []convo.Line) -> (ws: ^Worktree, err: Error) {
	if p := proc_for(r, o); p != nil && p.ws != nil && len(p.ws.members) == len(lines) {
		ws = p.ws
		match := true
		for mb, i in ws.members {
			if mb.name != lines[i].mount {
				match = false
			}
		}
		if match {
			for &mb, i in ws.members {
				mb.run_line = lines[i].line
			}
			ws.busy = true
			if e := _worktree_begin(ws, run); e != .None {
				return nil, e
			}
			return ws, .None
		}
	}
	ws, err = worktree_attach(r, o, run.ai.object.id, lines)
	if err != .None {
		return nil, err
	}
	if e := _worktree_begin(ws, run); e != .None {
		worktree_close(ws)
		return nil, e
	}
	return ws, .None
}

worktree_attach :: proc(r: ^Runtime, o: Object, agent_id: prim.Id, lines: []convo.Line) -> (ws: ^Worktree, err: Error) {
	ms, merr := eng.convo_mounts(r.e, o, context.temp_allocator)
	if merr != .None {
		return nil, .Engine
	}
	ws = new(Worktree, r.allocator)
	ws.r = r
	ws.o = o
	if !_arena_init(&ws.arena) {
		free(ws, r.allocator)
		return nil, .Limit
	}
	ws.alloc = virtual.arena_allocator(&ws.arena)
	ws.members = make([dynamic]Wt_Member, ws.alloc)
	ws.tools = make([dynamic]Wt_Tool, ws.alloc)
	ws.actor = agent_actor(r, agent_id)
	ws.busy = true
	id := o.id
	base := concat(r.cfg.work_root, "/", hex(id))
	single := len(ms) == 1
	for m in ms {
		run_line: prim.Id
		listed := lines == nil
		for l in lines {
			if l.mount == m.name {
				run_line = l.line
				listed = true
			}
		}
		if !listed {
			continue
		}
		mb := Wt_Member {
			name      = clone(m.name, ws.alloc),
			tree      = m.tree,
			conv_line = m.line,
			run_line  = run_line,
			path      = clone(m.path, ws.alloc),
		}
		home := ""
		if single && r.cfg.homes.home != nil {
			if h, ok := r.cfg.homes.home(r.cfg.homes.data, m.tree, context.temp_allocator); ok && !worktree_dir_busy(r, h, ws) {
				home = h
			}
		}
		if len(home) > 0 {
			mb.dir = clone(home, ws.alloc)
			ws.root = clone(home, ws.alloc)
		} else {
			sub := m.path if len(m.path) > 0 else m.name
			mb.dir = clone(base if single && len(m.path) == 0 else concat(base, "/", sub), ws.alloc)
		}
		append(&ws.members, mb)
	}
	if len(ws.root) == 0 {
		ws.root = clone(base, ws.alloc)
	}
	prim.mkdir_all(r.e.base, ws.root, 0o755)
	for &mb in ws.members {
		if e := _member_mount(ws, &mb); e != .None {
			worktree_close(ws)
			return nil, e
		}
	}
	return ws, .None
}

@(private)
_member_mount :: proc(ws: ^Worktree, mb: ^Wt_Member) -> Error {
	r := ws.r
	reg, rerr := eng.registry(r.e)
	if rerr != .None {
		return .Engine
	}
	tree := Object{ws.o.space, mb.tree}
	h, herr := eng.tree_history(r.e, tree)
	if herr != .None {
		return .Engine
	}
	clean := fs.clean_path(mb.dir, context.temp_allocator)
	for m in reg.mounts {
		if m != nil && m.history == h && m.root == clean {
			mb.m = m
			mb.borrowed = true
			return .None
		}
	}
	busy_src: ^fs.Mount
	for m in reg.mounts {
		if m != nil && m.history == h && worktree_dir_busy(r, m.root, ws) {
			busy_src = m
			break
		}
	}
	conv := line_name(mb.conv_line)
	if busy_src != nil && !prim.exists(r.e.base, mb.dir) {
		cur, found, verr := fs.history_line(h, conv, context.temp_allocator)
		if verr != .None || !found {
			cur = fs.mount_synced(busy_src)
		}
		m := new(fs.Mount, r.allocator)
		id := mb.tree
		state := concat(r.cfg.work_root, "/.state/", hex(derive_id("0ndb-fork-v1", id[:], transmute([]u8)clean)))
		opts := fs.DEFAULT_MOUNT
		opts.line = conv
		if ferr := fs.mount_fork(busy_src, m, derive_id("0ndb-fork-mount-v1", id[:], transmute([]u8)clean), mb.dir, state, cur, fs.Fork_Options{line = conv}, opts, r.allocator); ferr != .None {
			free(m, r.allocator)
			return .Io
		}
		mb.m = m
		mb.owned = true
		return .None
	}
	opts := fs.DEFAULT_MOUNT
	opts.line = conv
	m, merr := eng.tree_mount(r.e, tree, mb.dir, opts)
	eng.tree_release(r.e, tree)
	if merr != .None {
		return .Io
	}
	mb.m = m
	mb.engine = true
	return .None
}

@(private)
_worktree_begin :: proc(ws: ^Worktree, run: ^Run) -> Error {
	r := ws.r
	reg, rerr := eng.registry(r.e)
	if rerr != .None {
		return .Engine
	}
	targets := _target_versions(r, ws.o, run)
	claim := run.claim
	cid := claim.seg
	off: [8]u8
	prim.put_u64le(off[:], u64(claim.off))
	ws.scope = derive_id("0ndb-turn-scope-v1", cid[:], off[:])
	for &mb in ws.members {
		m := mb.m
		if m == nil {
			return .Io
		}
		h := m.history
		if fs.mount_sync(m) != .None {
			return .Io
		}
		conv := line_name(mb.conv_line)
		target: []crdt.Op_Id
		branch, commit: string
		if tv, ok := targets[mb.name]; ok {
			v, b, c, dok := version_decode(tv)
			if dok {
				target = v
				branch = b
				commit = c
			}
		}
		if target == nil {
			cur, found, verr := fs.history_line(h, conv, context.temp_allocator)
			if verr != .None {
				return .Io
			}
			target = cur if found else fs.mount_synced(m)
		}
		run_line := line_name(mb.run_line)
		existing, has_run, _ := fs.history_line(h, run_line, context.temp_allocator)
		if !(run.revive && has_run) {
			if fs.history_set_line(h, run_line, target) != .None {
				return .Io
			}
		} else {
			target = existing
		}
		_member_switch(m, run_line)
		if fs.mount_materialize(m) != .None {
			return .Io
		}
		if m.has_git && len(commit) > 0 && (m.head.commit != commit || m.head.branch != branch) {
			fs.git_restore(m, branch, commit, fs_spawner(r), ws.o.id)
		}
		mb.start = clone_version(fs.mount_synced(m), ws.alloc)
		mb.branch = clone(m.head.branch, ws.alloc)
		mb.commit = clone(m.head.commit, ws.alloc)
		mb.turn = fs.scope_open(reg, m, ws.scope, ws.actor)
	}
	return .None
}

@(private)
_member_switch :: proc(m: ^fs.Mount, line: string) {
	if m.line == line {
		return
	}
	old := m.line
	m.line = clone(line, m.allocator)
	delete(old, m.allocator)
}

clone_version :: proc(v: []crdt.Op_Id, allocator: runtime.Allocator) -> []crdt.Op_Id {
	out := make([]crdt.Op_Id, len(v), allocator)
	copy(out, v)
	return out
}

@(private)
_target_versions :: proc(r: ^Runtime, o: Object, run: ^Run) -> map[string][]u8 {
	out := make(map[string][]u8, context.temp_allocator)
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return out
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return out
	}
	cur := run.parent
	oldest_reply: Rid
	for depth := 0; !obj.rid_none(cur) && depth < 4096; depth += 1 {
		m, merr := convo.message(v, &t, convo.Position{msg = cur}, context.temp_allocator)
		if merr != .None {
			break
		}
		if m.role == .Assistant {
			oldest_reply = m.id
		}
		if !obj.rid_none(m.claim) {
			for f in _landed_files(v, m.claim, m.hlc) {
				if f.mount not_in out {
					out[f.mount] = f.version
				}
			}
		}
		for f in m.files {
			if f.mount not_in out {
				out[f.mount] = f.version
			}
		}
		if len(out) > 0 {
			break
		}
		cur = m.parent
	}
	if len(out) == 0 && !obj.rid_none(oldest_reply) {
		_turn_before(v, oldest_reply, &out)
	}
	return out
}

@(private)
_versions_parse :: proc(blob: []u8, out: ^map[string][]u8) {
	rd := prim.reader(blob)
	n := prim.read_uvarint(&rd)
	if n > 4096 {
		return
	}
	for _ in 0 ..< n {
		name := prim.read_str(&rd)
		ver := prim.read_bytes(&rd)
		if !prim.reader_ok(&rd) {
			return
		}
		if name not_in out {
			out[clone(name, context.temp_allocator)] = clone_bytes(ver, context.temp_allocator)
		}
	}
}

@(private)
_turn_before :: proc(v: ^obj.View, reply: Rid, out: ^map[string][]u8) -> bool {
	s := obj.view_find(v, reply.seg)
	if s < 0 {
		return false
	}
	end := obj.end(v, s)
	_, pos, gerr := obj.get(v, s, reply.off)
	if gerr != .None {
		return false
	}
	for pos < end {
		body, next, e := obj.get(v, s, pos)
		if e != .None {
			return false
		}
		at := pos
		pos = next
		if obj.is_redacted(body) || obj.is_sig(body) {
			continue
		}
		k := obj.record_kind(body)
		if k == u8(convo.Kind.Seal) || k == u8(convo.Kind.Interrupted) {
			rec, derr := convo.decode_record(body, at, context.temp_allocator)
			if derr != .None {
				continue
			}
			#partial switch x in rec.body {
			case convo.Seal:
				if x.msg == reply.off {
					return false
				}
			case convo.Interrupted:
				if x.msg == reply.off {
					return false
				}
			}
			continue
		}
		if k != u8(convo.Kind.Scope) {
			continue
		}
		rec, derr := convo.decode_record(body, at, context.temp_allocator)
		if derr != .None {
			continue
		}
		sc := rec.body.(convo.Scope)
		if sc.kind != .Turn {
			continue
		}
		target, rerr := obj.resolve(v, s, sc.msg)
		if rerr != .None || obj.rid(v, target) != reply {
			continue
		}
		_versions_parse(sc.before, out)
		return true
	}
	return false
}

@(private)
_landed_files :: proc(v: ^obj.View, claim: Rid, floor: prim.Hlc) -> []convo.File_Delta {
	s := obj.view_find(v, claim.seg)
	if s < 0 {
		return nil
	}
	Ctx :: struct {
		v:     ^obj.View,
		claim: Rid,
		found: []convo.File_Delta,
	}
	c := Ctx{v = v, claim = claim}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: obj.Error) {
		c := (^Ctx)(data)
		if env.kind != u8(convo.Kind.Landed) {
			return false, .None
		}
		rec, derr := convo.decode_env(env, context.temp_allocator)
		if derr != .None {
			return false, .None
		}
		l := rec.body.(convo.Landed)
		target, rerr := obj.resolve(c.v, s, l.run)
		if rerr != .None || obj.rid(c.v, target) != c.claim {
			return false, .None
		}
		c.found = l.files
		return true, .None
	}
	obj.walk_events(v, s, floor, &c, visit)
	return c.found
}

worktree_needs_setup :: proc(ws: ^Worktree) -> bool {
	if ws.setup {
		return false
	}
	for mb in ws.members {
		if mb.m != nil && fs.mount_needs_setup(mb.m) {
			return true
		}
	}
	return false
}

@(private)
Setup_Ctx :: struct {
	ws:   ^Worktree,
	run:  ^Run,
	next: proc(run: ^Run),
	left: int,
}

worktree_setup :: proc(ws: ^Worktree, run: ^Run, next: proc(run: ^Run)) -> Error {
	r := ws.r
	ctx := new(Setup_Ctx, run.alloc)
	ctx^ = {ws = ws, run = run, next = next}
	for mb in ws.members {
		if mb.m == nil || !fs.mount_needs_setup(mb.m) {
			continue
		}
		path, found := fs.agents_setup(r.e.base, mb.m.root, context.temp_allocator)
		if !found {
			continue
		}
		argv := []string{path}
		req := Spawn_Request {
			argv      = argv,
			cwd       = mb.m.root,
			env       = r.cfg.env,
			new_group = true,
			observe   = run.ai.observe,
		}
		if _, err := job_start(r, &req, nil, ctx, _on_setup_done, 30 * 60 * 1000); err == .None {
			ctx.left += 1
		}
	}
	ws.setup = true
	if ctx.left == 0 {
		next(run)
	}
	return .None
}

@(private)
_on_setup_done :: proc(j: ^Job, status: prim.Exit_Status) {
	ctx := (^Setup_Ctx)(j.data)
	ctx.left -= 1
	if status.code != 0 || status.signal != 0 {
		tail, _ := utf8_clip(string(j.err[:]), 2000)
		run_notice(ctx.run, concat(".agents/setup failed: ", tail))
	} else {
		for mb in ctx.ws.members {
			if mb.m != nil && fs.mount_needs_setup(mb.m) {
				fs.mount_setup_done(mb.m)
			}
		}
	}
	if ctx.left == 0 && ctx.run.state != .Finished {
		ctx.next(ctx.run)
	}
}

worktree_add_pid :: proc(ws: ^Worktree, pid: prim.Pid) {
	for mb in ws.members {
		if mb.turn != nil {
			fs.scope_add_pid(mb.turn, pid)
		}
	}
}

worktree_tool_open :: proc(ws: ^Worktree, run: ^Run, id: string) -> int {
	r := ws.r
	reg, rerr := eng.registry(r.e)
	if rerr != .None {
		return -1
	}
	scopes := make([]^fs.Scope, len(ws.members), ws.alloc)
	sid := _tool_scope_id(ws, id)
	for mb, i in ws.members {
		if mb.m != nil {
			scopes[i] = fs.scope_open(reg, mb.m, sid, ws.actor)
		}
	}
	append(&ws.tools, Wt_Tool{id = clone(id, ws.alloc), scopes = scopes, before = _versions_blob(ws, ws.alloc), open = true})
	return len(ws.tools) - 1
}

worktree_tool_close :: proc(ws: ^Worktree, run: ^Run, idx: int) {
	if idx < 0 || idx >= len(ws.tools) || !ws.tools[idx].open {
		return
	}
	r := ws.r
	reg, rerr := eng.registry(r.e)
	if rerr != .None {
		return
	}
	t := &ws.tools[idx]
	t.open = false
	for s in t.scopes {
		if s != nil {
			fs.scope_close(reg, s)
		}
	}
	after := _versions_blob(ws, context.temp_allocator)
	if w := _writer(run); w != nil {
		convo.writer_scope(w, run.reply, .Tool, _tool_scope_id(ws, t.id), ws.actor, t.before, after)
	}
}

@(private)
_tool_scope_id :: proc(ws: ^Worktree, id: string) -> prim.Id {
	s := ws.scope
	return derive_id("0ndb-tool-scope-v1", s[:], transmute([]u8)id)
}

@(private)
_versions_blob :: proc(ws: ^Worktree, allocator: runtime.Allocator) -> []u8 {
	b := make([dynamic]u8, allocator)
	w := prim.writer(&b)
	prim.write_uvarint(&w, u64(len(ws.members)))
	for mb in ws.members {
		prim.write_str(&w, mb.name)
		v: []crdt.Op_Id
		if mb.m != nil {
			v = fs.mount_synced(mb.m)
		}
		prim.write_bytes(&w, version_encode(v, mb.m.head.branch if mb.m != nil else "", mb.m.head.commit if mb.m != nil else ""))
	}
	return b[:]
}

worktree_finish :: proc(ws: ^Worktree, run: ^Run, land: bool) -> []convo.File_Delta {
	r := ws.r
	reg, rerr := eng.registry(r.e)
	files := make([dynamic]convo.File_Delta, context.temp_allocator)
	for &t in ws.tools {
		if t.open && rerr == .None {
			t.open = false
			for s in t.scopes {
				if s != nil {
					fs.scope_close(reg, s)
				}
			}
		}
	}
	clear(&ws.tools)
	before := make([dynamic]u8, context.temp_allocator)
	bw := prim.writer(&before)
	prim.write_uvarint(&bw, u64(len(ws.members)))
	for &mb in ws.members {
		prim.write_str(&bw, mb.name)
		prim.write_bytes(&bw, version_encode(mb.start, mb.branch, mb.commit))
		m := mb.m
		if m == nil {
			continue
		}
		if mb.turn != nil && rerr == .None {
			fs.scope_close(reg, mb.turn)
			mb.turn = nil
		} else {
			fs.mount_sync(m)
		}
		h := m.history
		conv := line_name(mb.conv_line)
		run_line := line_name(mb.run_line)
		end, found, _ := fs.history_line(h, run_line, context.temp_allocator)
		if !found {
			end = fs.mount_synced(m)
		}
		if land {
			fs.history_set_line(h, conv, end)
			append(&files, convo.File_Delta{mount = mb.name, tree = mb.tree, line = mb.conv_line, version = version_encode(end, m.head.branch, m.head.commit)})
		}
		_member_switch(m, conv)
		fs.mount_materialize(m)
	}
	after := _versions_blob(ws, context.temp_allocator)
	if w := _writer(run); w != nil {
		convo.writer_scope(w, run.reply, .Turn, ws.scope, ws.actor, before[:], after)
	}
	ws.busy = false
	return files[:]
}

worktree_close :: proc(ws: ^Worktree) {
	r := ws.r
	reg, rerr := eng.registry(r.e)
	for &mb in ws.members {
		if mb.turn != nil && rerr == .None {
			fs.scope_close(reg, mb.turn)
			mb.turn = nil
		}
		if mb.m == nil || mb.borrowed {
			continue
		}
		if mb.engine {
			eng.tree_unmount(r.e, mb.m)
		} else if mb.owned {
			fs.mount_close(mb.m)
			free(mb.m, r.allocator)
		}
		mb.m = nil
	}
	virtual.arena_destroy(&ws.arena)
	free(ws, r.allocator)
}

worktree_go_back :: proc(r: ^Runtime, o: Object, msg: Rid) -> Error {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return .Engine
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return .Pending
	}
	m, merr := convo.message(v, &t, convo.Position{msg = msg}, context.temp_allocator)
	if merr != .None {
		return .Not_Found
	}
	targets: map[string][]u8
	if m.role == .User {
		targets = make(map[string][]u8, context.temp_allocator)
		pg, _ := convo.page(v, &t, {}, 1_000_000, context.temp_allocator)
		for x, i in pg.messages {
			if x.id == msg && i > 0 && pg.messages[i - 1].role == .Assistant {
				_turn_before(v, pg.messages[i - 1].id, &targets)
			}
		}
		if len(targets) == 0 {
			fake: Run
			fake.parent = m.parent
			targets = _target_versions(r, o, &fake)
		}
	} else {
		fake: Run
		fake.parent = msg
		targets = _target_versions(r, o, &fake)
	}
	if len(targets) == 0 {
		return .None
	}
	if run_find(r, o) != nil {
		return .Busy
	}
	ws, werr := worktree_attach(r, o, {}, nil)
	if werr != .None {
		return werr
	}
	defer worktree_close(ws)
	set: fs.Mount_Set
	fs.mount_set_init(&set, ws.root, context.temp_allocator)
	versions := make([dynamic]fs.Tree_Version, context.temp_allocator)
	for mb in ws.members {
		tv, ok := targets[mb.name]
		if !ok || mb.m == nil {
			continue
		}
		ver, b, c, dok := version_decode(tv)
		if !dok {
			continue
		}
		fs.mount_set_add(&set, mb.name, mb.path if len(mb.path) > 0 else mb.name, mb.m)
		append(&versions, fs.Tree_Version{name = mb.name, line = line_name(mb.conv_line), version = ver, branch = b, commit = c})
	}
	if len(versions) == 0 {
		return .None
	}
	if fs.mount_set_go_back(&set, versions[:], fs_spawner(r), o.id) != .None {
		return .Io
	}
	return .None
}

observe_sink :: proc(r: ^Runtime) -> observe.Sink {
	return observe.Sink{data = r, write = _observe_write}
}

@(private)
_observe_write :: proc(data: rawptr, w: ^observe.Write) {
	r := (^Runtime)(data)
	reg, rerr := eng.registry(r.e)
	if rerr != .None {
		return
	}
	if !r.router_on {
		observe.router_init(&r.router, r.allocator)
		r.router_on = true
	}
	if r.router.reg != reg {
		observe.router_bind(&r.router, reg)
	}
	scope: ^fs.Scope
	for run in r.runs {
		if run.ws == nil || run.proc_ == nil || run.proc_.child.pid <= 0 {
			continue
		}
		pid := run.proc_.child.pid
		inside := w.pid == pid
		for p in w.lineage {
			inside ||= p == pid
		}
		if !inside {
			continue
		}
		calls := make([dynamic]observe.Tool_Call, context.temp_allocator)
		idx := make([dynamic]int, context.temp_allocator)
		for &t, i in run.tools {
			if !t.done && t.has_obs && t.scope >= 0 {
				append(&calls, t.call)
				append(&idx, i)
			}
		}
		k, ambiguous := observe.attribute(calls[:], w, pid)
		m, _, found := observe.router_locate(&r.router, w.path)
		if k >= 0 && !ambiguous && found {
			t := run.tools[idx[k]]
			for mb, mi in run.ws.members {
				if mb.m == m && t.scope < len(run.ws.tools) {
					scope = run.ws.tools[t.scope].scopes[mi]
				}
			}
		}
		if scope == nil && found {
			for mb in run.ws.members {
				if mb.m == m {
					scope = mb.turn
				}
			}
		}
		break
	}
	if scope != nil {
		observe.route(&r.router, w, scope)
	} else {
		observe.route_write(&r.router, w)
	}
}
