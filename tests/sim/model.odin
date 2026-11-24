package sim

import "core:fmt"
import "core:mem"
import "core:strings"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/obj"
import "../../src/prim"

Op_Status :: enum u8 {
	Issued,
	Done,
	Acked,
	Uncertain,
	Observed,
	Lost,
	Failed,
}

M_Kind :: enum u8 {
	Convo,
	Map,
	Text,
	Tree,
}

Op_Kind :: enum u8 {
	Create,
	Send,
	Queue,
	Steer,
	Edit,
	Cancel,
	Interrupt,
	Switch,
	Back,
	Follow,
	Answer,
	Assign,
	Mount,
	Unmount,
	Map_Set,
	Map_Hot,
	Map_Add,
	Map_Remove,
	Map_Delete,
	Count,
	Text_Insert,
	Text_Delete,
	Tree_Write,
	Tree_Remove,
	Catalog,
	Usage,
	Share,
	Mount_Tree,
	Disk_Agent,
	Disk_Person,
	Git_Mount,
	Search_Peer,
	Promote,
	Read_Live,
	Stream,
	Buffer_Open,
	Buffer_Type,
	Buffer_Delete,
	Buffer_Undo,
	Buffer_Anchor,
	Buffer_Sync,
	Buffer_Burst,
}

M_Space :: struct {
	id:      prim.Id,
	members: [dynamic]int,
	guests:  [dynamic]int,
}

M_Obj :: struct {
	o:        eng.Object,
	kind:     M_Kind,
	creator:  int,
	op:       int,
	removed:  map[string]bool,
	shared:   [dynamic]int,
	lines:    [dynamic]string,
}

M_Op :: struct {
	w:       ^World,
	idx:     int,
	kind:    Op_Kind,
	node:    int,
	inc:     int,
	nseq:    int,
	obj:     int,
	actor:   prim.Id,
	status:  Op_Status,
	tick:    u64,
	rid:     eng.Rid,
	token:   string,
	tokens:  [dynamic]string,
	deletes: [dynamic]string,
	key:     string,
	path:    string,
	delta:   i64,
	target:  int,
	err:     eng.Error,
	at:      i64,
	overwrite: bool,
	gens:    [dynamic]string,
	power_crash: bool,
	line:    string,
}

M_Move :: struct {
	idx:    int,
	obj:    int,
	node:   int,
	from:   string,
	to:     string,
	at:     i64,
	status: Op_Status,
}

Model :: struct {
	w:      ^World,
	moves:  [dynamic]^M_Move,
	reasserted: map[string]bool,
	spaces: [dynamic]M_Space,
	objs:   [dynamic]M_Obj,
	ops:    [dynamic]^M_Op,
	nseq:   [dynamic]int,
	tok:    int,
	shares: [dynamic]Pending_Share,
	accepted: [dynamic]Pending_Share,
	grants:   [dynamic]Pending_Share,
	mounts:   [dynamic]M_Mount,
	probes:   [dynamic]int,
	temps:    [dynamic]M_Temp,
}

M_Temp :: struct {
	obj:    int,
	path:   string,
	actor:  prim.Id,
	tokens: [dynamic]string,
}

Pending_Share :: struct {
	share: eng.Share,
	to:    int,
	obj:   int,
	token: [eng.CAPABILITY_LEN]u8,
}

model_init :: proc(m: ^Model, w: ^World) {
	a := w.allocator
	m^ = {}
	m.w = w
	m.spaces = make([dynamic]M_Space, a)
	m.objs = make([dynamic]M_Obj, a)
	m.ops = make([dynamic]^M_Op, a)
	m.nseq = make([dynamic]int, a)
	m.shares = make([dynamic]Pending_Share, a)
	m.accepted = make([dynamic]Pending_Share, a)
	m.grants = make([dynamic]Pending_Share, a)
	m.mounts = make([dynamic]M_Mount, a)
	m.probes = make([dynamic]int, a)
	m.moves = make([dynamic]^M_Move, a)
	m.temps = make([dynamic]M_Temp, a)
	m.reasserted = make(map[string]bool, a)
}

model_destroy :: proc(m: ^Model) {
	a := m.w.allocator
	for &s in m.spaces {
		delete(s.members)
		delete(s.guests)
	}
	delete(m.spaces)
	for &o in m.objs {
		for k in o.removed {
			delete(k, a)
		}
		delete(o.removed)
		delete(o.shared)
	}
	delete(m.objs)
	for op in m.ops {
		delete(op.token, a)
		for t in op.tokens {
			delete(t, a)
		}
		delete(op.tokens)
		for t in op.deletes {
			delete(t, a)
		}
		delete(op.deletes)
		for g in op.gens {
			delete(g, a)
		}
		delete(op.gens)
		delete(op.key, a)
		delete(op.path, a)
		free(op, a)
	}
	delete(m.ops)
	delete(m.nseq)
	delete(m.shares)
	delete(m.accepted)
	delete(m.grants)
	delete(m.mounts)
	delete(m.probes)
	for mv in m.moves {
		delete(mv.from, a)
		delete(mv.to, a)
		free(mv, a)
	}
	delete(m.moves)
	for &t in m.temps {
		delete(t.path, a)
		for x in t.tokens {
			delete(x, a)
		}
		delete(t.tokens)
	}
	delete(m.temps)
	for k in m.reasserted {
		delete(k, a)
	}
	delete(m.reasserted)
}

model_temp_write :: proc(m: ^Model, obj: int, path: string, actor: prim.Id, data: []u8) {
	a := m.w.allocator
	t := M_Temp{obj = obj, path = strings.clone(path, a), actor = actor, tokens = make([dynamic]string, a)}
	for x in parse_tokens(data) {
		append(&t.tokens, strings.clone(x.text, a))
	}
	append(&m.temps, t)
}

model_temp :: proc(m: ^Model, obj: int, path: string) -> bool {
	for t in m.temps {
		if t.obj == obj && t.path == path {
			return true
		}
	}
	return false
}

new_move :: proc(m: ^Model, n: ^Node, obj: int, from: string, to: string) -> ^M_Move {
	a := m.w.allocator
	mv := new(M_Move, a)
	mv.idx = len(m.moves)
	mv.obj = obj
	mv.node = n.idx
	mv.from = strings.clone(from, a)
	mv.to = strings.clone(to, a)
	mv.at = m.w.now
	mv.status = .Issued
	append(&m.moves, mv)
	return mv
}

move_maybe :: proc(mv: ^M_Move) -> bool {
	return mv.status == .Done || mv.status == .Acked || mv.status == .Observed || mv.status == .Uncertain
}

same_file :: proc(m: ^Model, obj: int, a: string, b: string) -> bool {
	if a == b {
		return true
	}
	any := false
	for mv in m.moves {
		any ||= mv.obj == obj && move_maybe(mv)
	}
	if !any {
		return false
	}
	buf: [32 << 10]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	seen := make(map[string]bool, context.temp_allocator)
	queue := make([dynamic]string, context.temp_allocator)
	append(&queue, a)
	seen[a] = true
	for i := 0; i < len(queue) && len(queue) < 256; i += 1 {
		cur := queue[i]
		for mv in m.moves {
			if mv.obj != obj || !move_maybe(mv) {
				continue
			}
			for dir in 0 ..< 2 {
				from, to := mv.from, mv.to
				if dir == 1 {
					from, to = mv.to, mv.from
				}
				next := ""
				if cur == from {
					next = to
				} else if strings.has_prefix(cur, from) && len(cur) > len(from) && cur[len(from)] == '/' {
					next = strings.concatenate({to, cur[len(from):]}, context.temp_allocator)
				} else {
					continue
				}
				if next == b {
					return true
				}
				if !seen[next] {
					seen[next] = true
					append(&queue, next)
				}
			}
		}
	}
	return false
}

new_token :: proc(m: ^Model, n: ^Node, tag: string) -> string {
	m.tok += 1
	return fmt.aprintf("<%s%x.%s%d.%d>", tag, m.w.cfg.seed & 0xfff, n.name, n.incarnation, m.tok, allocator = m.w.allocator)
}

new_op :: proc(m: ^Model, kind: Op_Kind, n: ^Node, obj: int) -> ^M_Op {
	a := m.w.allocator
	for len(m.nseq) <= n.idx {
		append(&m.nseq, 0)
	}
	m.nseq[n.idx] += 1
	op := new(M_Op, a)
	op.w = m.w
	op.idx = len(m.ops)
	op.kind = kind
	op.node = n.idx
	op.inc = n.incarnation
	op.nseq = m.nseq[n.idx]
	op.obj = obj
	op.actor = n.identity.id
	op.status = .Issued
	op.target = -1
	op.at = m.w.now
	op.tokens = make([dynamic]string, a)
	op.deletes = make([dynamic]string, a)
	op.gens = make([dynamic]string, a)
	if obj >= 0 && obj < len(m.objs) && m.objs[obj].kind == .Tree && n.e_open {
		op.line = strings.clone(line_norm(eng.tree_line(&n.e, m.objs[obj].o)), a)
	}
	append(&m.ops, op)
	m.w.stats.ops += 1
	return op
}

op_done :: proc(op: ^M_Op, tick: u64, err: eng.Error) {
	w := op.w
	if op.status != .Issued {
		return
	}
	op.err = err
	if err != .None && w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
		op.status = .Uncertain
		w.stats.io_errors += 1
		w.nodes[op.node].restart_pending = true
		return
	}
	if err == .Io {
		op.status = .Uncertain
		w.stats.ops_failed += 1
		if !w.nodes[op.node].disk.dead {
			world_fail(w, "op %d %v on %s failed with Io on a healthy disk", op.idx, op.kind, w.nodes[op.node].name)
		}
		return
	}
	if err != .None {
		op.status = .Failed
		w.stats.ops_failed += 1
		#partial switch err {
		case .Corrupt, .Forged, .Quarantined, .No_Memory:
			world_fail(w, "op %d %v on %s failed with %v", op.idx, op.kind, w.nodes[op.node].name, err)
		case .Io:
			if !w.nodes[op.node].disk.dead {
				world_fail(w, "op %d %v on %s failed with Io on a healthy disk", op.idx, op.kind, w.nodes[op.node].name)
			}
		}
		return
	}
	op.tick = tick
	op.status = .Done
	n := w.nodes[op.node]
	if n.alive && n.incarnation == op.inc && tick <= n.durable {
		op.status = .Acked
	}
}

op_done_cb :: proc(data: rawptr, e: ^eng.Engine, res: ^eng.Result, err: eng.Error) {
	op := (^M_Op)(data)
	if op.kind == .Send || op.kind == .Queue || op.kind == .Steer || op.kind == .Interrupt || op.kind == .Answer {
		op.rid = res.item
	} else if op.kind == .Map_Set && err == .None {
		op.rid = eng.Rid{op.actor, res.off, 0}
	}
	op_done(op, res.tick, err)
}

op_done_handle :: proc(op: ^M_Op) -> eng.Done {
	return eng.Done{data = op, call = op_done_cb}
}

op_result :: proc(op: ^M_Op, n: ^Node, err: eng.Error) {
	if err == .Pending {
		return
	}
	op_done(op, eng.pending_seq(&n.e), err)
}

model_durable :: proc(m: ^Model, n: ^Node, t: u64) {
	for op in m.ops {
		if op.node == n.idx && op.inc == n.incarnation && op.status == .Done && op.tick <= t {
			op.status = .Acked
		}
	}
}

model_node_crashed :: proc(m: ^Model, n: ^Node, mode: Crash_Mode) {
	if mode == .Power {
		probe := -1
		for op in m.ops {
			if op.node == n.idx && op.kind == .Send && op.status == .Done && !obj.rid_none(op.rid) {
				probe = op.idx
			}
		}
		if probe >= 0 {
			append(&m.probes, probe)
		}
	}
	for op in m.ops {
		if op.node != n.idx {
			continue
		}
		switch op.status {
		case .Issued, .Done:
			op.status = .Uncertain
			op.power_crash = mode == .Power
		case .Uncertain:
			if op.inc == n.incarnation && mode == .Power {
				op.power_crash = true
			}
		case .Acked, .Observed, .Lost, .Failed:
		}
	}
}

op_happened :: proc(op: ^M_Op) -> bool {
	return op.status == .Done || op.status == .Acked || op.status == .Observed
}

op_maybe :: proc(op: ^M_Op) -> bool {
	return op_happened(op) || op.status == .Uncertain
}

node_of :: proc(m: ^Model, op: ^M_Op) -> ^Node {
	return m.w.nodes[op.node]
}

obj_kind_of :: proc(k: eng.Kind) -> M_Kind {
	#partial switch k {
	case .Conversation:
		return .Convo
	case .Map:
		return .Map
	case .Text:
		return .Text
	case .File_Tree:
		return .Tree
	}
	return .Map
}

msg_body :: proc(tok: string) -> string {
	if len(tok) < 2 || (tok[len(tok) - 2] - '0') % 3 != 0 {
		return tok
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, tok)
	for _ in 0 ..< 6 + int(tok[len(tok) - 2] - '0') {
		strings.write_string(&b, " the quick brown fox jumps over the lazy dog")
	}
	return strings.to_string(b)
}

msg_text :: proc(m: convo.Message) -> string {
	b := strings.builder_make(context.temp_allocator)
	for blk in m.blocks {
		if blk.kind == .Text {
			strings.write_bytes(&b, blk.text)
		}
	}
	return strings.to_string(b)
}

Presence :: enum u8 {
	Unknown,
	Present,
	Absent,
}

op_presence :: proc(m: ^Model, n: ^Node, op: ^M_Op) -> Presence {
	if !n.alive {
		return .Unknown
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	o := m.objs[op.obj].o
	#partial switch op.kind {
	case .Send:
		if obj.rid_none(op.rid) {
			return .Unknown
		}
		msg, err := eng.convo_message(&n.e, o, convo.Position{msg = op.rid}, context.temp_allocator)
		if err == .Not_Found {
			return .Absent
		}
		if err != .None {
			return .Unknown
		}
		if msg.redacted {
			return .Present
		}
		if msg.author != op.actor {
			return .Absent
		}
		if msg_text(msg) != msg_body(op.token) {
			return .Absent
		}
		return .Present
	case .Stream:
		if obj.rid_none(op.rid) {
			return .Unknown
		}
		msg, err := eng.convo_message(&n.e, o, convo.Position{msg = op.rid}, context.temp_allocator)
		if err == .Not_Found {
			return .Absent
		}
		if err != .None {
			return .Unknown
		}
		if msg.author != op.actor || msg.role != .Assistant {
			return .Absent
		}
		if msg.redacted || len(msg.blocks) == 0 {
			return .Present
		}
		return .Present if strings.has_prefix(string(msg.blocks[0].text), op.token) else .Absent
	case .Map_Set:
		en, found, err := eng.map_get(&n.e, o, transmute([]u8)op.key, context.temp_allocator)
		if err != .None {
			return .Unknown
		}
		if !found {
			return .Absent
		}
		for r in en.registers {
			if r.tag == 1 && string(r.value) == op.token {
				return .Present
			}
		}
		return .Absent
	case .Create:
		c, found, err := eng.catalog_get(&n.e, o, context.temp_allocator)
		_ = c
		if err != .None {
			return .Unknown
		}
		return .Present if found else .Absent
	}
	return .Unknown
}

model_after_restart :: proc(m: ^Model, n: ^Node) {
	w := m.w
	Per :: struct {
		obj:  int,
		kind: Op_Kind,
	}
	last_present := make(map[Per]int, context.temp_allocator)
	for op in m.ops {
		if op.node != n.idx || !(op.kind == .Send || op.kind == .Stream || op.kind == .Map_Set || op.kind == .Create) {
			continue
		}
		if op.status == .Lost || op.status == .Failed || op.status == .Issued {
			continue
		}
		if op.kind == .Create && m.objs[op.obj].creator != n.idx {
			continue
		}
		p := op_presence(m, n, op)
		if !n.alive {
			return
		}
		switch op.status {
		case .Acked, .Observed, .Done:
			if p == .Absent {
				world_fail(w, "durability: %s lost %v op %d (%s, tick %d, status %v) after crash", n.name, op.kind, op.idx, op.token, op.tick, op.status)
				op.status = .Lost
			}
		case .Uncertain:
			if p == .Present {
				op.status = .Observed
			} else if p == .Absent {
				op.status = .Lost
				world_note(w, "%s op %d %v %s lost in crash (unacknowledged)", n.name, op.idx, op.kind, op.token)
			}
		case .Issued, .Lost, .Failed:
		}
		if p == .Present {
			last_present[Per{op.obj, op.kind}] = op.nseq
		}
	}
	for op in m.ops {
		if op.node != n.idx || !(op.kind == .Send || op.kind == .Stream || op.kind == .Map_Set) {
			continue
		}
		if op.status == .Lost {
			if lp, ok := last_present[Per{op.obj, op.kind}]; ok && lp > op.nseq && op.inc == n.incarnation - 1 {
				world_fail(w, "prefix: %s kept a later %v but lost op %d (%s) on the same object", n.name, op.kind, op.idx, op.token)
			}
		}
	}
}

@(init)
_model_hooks :: proc "contextless" () {
	register_restarted(20, proc(w: ^World, n: ^Node) {
		model_after_restart(&w.model, n)
	})
}

line_norm :: proc(line: string) -> string {
	return "" if line == "main" else line
}

line_eng :: proc(line: string) -> string {
	return "main" if line == "" else line
}

obj_add_line :: proc(m: ^Model, oi: int, line: string) {
	if line == "" {
		return
	}
	ob := &m.objs[oi]
	for l in ob.lines {
		if l == line {
			return
		}
	}
	if ob.lines == nil {
		ob.lines = make([dynamic]string, m.w.allocator)
	}
	append(&ob.lines, strings.clone(line, m.w.allocator))
}

obj_lines :: proc(m: ^Model, oi: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "")
	for l in m.objs[oi].lines {
		append(&out, l)
	}
	return out[:]
}
