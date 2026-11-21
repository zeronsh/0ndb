package thread

import "base:runtime"
import "core:slice"
import "../journal"
import "../prim"

Reader :: struct {
	jr:        ^journal.Reader,
	w:         ^Writer,
	kids:      Children,
	has_kids:  bool,
	stride:    i64,
	want:      [dynamic]Range,
	scratch:   runtime.Allocator,
	allocator: runtime.Allocator,
}

Tail :: struct {
	length:      i64,
	last:        i64,
	links:       Links,
	leaf:        i64,
	fork_head:   i64,
	leaf_status: Seal_Status,
	queued:      int,
	awaiting:    bool,
	status:      Status,
}

Position :: struct {
	msg:        i64,
	seal:       i64,
	seal_known: bool,
}

Block_View :: struct {
	index:  u32,
	kind:   Block_Kind,
	failed: bool,
	id:     string,
	name:   string,
	text:   []u8,
	is_ref: bool,
	ref:    Ref,
	off:    i64,
}

Message :: struct {
	off:               i64,
	role:              Role,
	parent:            i64,
	depth:             i64,
	prev_sibling:      i64,
	parent_seal:       i64,
	cmd:               prim.Id,
	hlc:               prim.Hlc,
	version:           []u8,
	git_branch:        string,
	git_commit:        []u8,
	provider_session:  string,
	provider_msg:      string,
	status:            Seal_Status,
	open:              bool,
	open_state:        Open_State,
	seal:              i64,
	last_block:        i64,
	usage:             Usage,
	seal_provider_msg: string,
	seal_cmd:          prim.Id,
	blocks:            []Block_View,
	sibling:           int,
	siblings:          int,
}

Page :: struct {
	messages: []Message,
	next:     Position,
	more:     bool,
}

Queue_Item :: struct {
	item:        i64,
	latest:      i64,
	cmd:         prim.Id,
	mode:        Queue_Mode,
	text:        string,
	attachments: []Attachment,
}

@(private)
Chunk :: struct {
	off:    i64,
	index:  u32,
	flags:  Block_Flags,
	kind:   Block_Kind,
	id:     string,
	name:   string,
	data:   []u8,
	ref:    Ref,
}

@(private)
Node :: struct {
	off:        i64,
	parent:     i64,
	depth:      i64,
	jump:       i64,
	jump_depth: i64,
}

reader_init :: proc(r: ^Reader, jr: ^journal.Reader, allocator := context.allocator, scratch := context.temp_allocator) {
	r^ = {
		jr        = jr,
		want      = make([dynamic]Range, allocator),
		scratch   = scratch,
		allocator = allocator,
	}
}

reader_destroy :: proc(r: ^Reader) {
	delete(r.want)
	r.want = nil
	if r.has_kids {
		children_close(&r.kids)
		r.has_kids = false
	}
}

reader_children :: proc(r: ^Reader, path: string, thread: prim.Id) -> Error {
	if r.has_kids {
		children_close(&r.kids)
		r.has_kids = false
	}
	kp := _kids_path(path, context.temp_allocator) or_return
	children_open(&r.kids, kp, thread, r.allocator, false) or_return
	r.has_kids = true
	return .None
}

reader_reset :: proc(r: ^Reader) {
	clear(&r.want)
}

wanted :: proc(r: ^Reader) -> []Range {
	if len(r.want) < 2 {
		return r.want[:]
	}
	slice.sort_by(r.want[:], proc(a, b: Range) -> bool {
		return a.from < b.from
	})
	n := 1
	for i in 1 ..< len(r.want) {
		cur := r.want[i]
		top := &r.want[n - 1]
		if cur.from <= top.to {
			top.to = max(top.to, cur.to)
		} else {
			r.want[n] = cur
			n += 1
		}
	}
	resize(&r.want, n)
	return r.want[:]
}

suggested_tail :: proc "contextless" (length: i64) -> i64 {
	return min(length, TAIL_GUESS)
}

@(private)
_want :: proc(r: ^Reader, from, to: i64) {
	end := journal.reader_end(r.jr)
	a := max(from, 0)
	b := min(to, end)
	if b <= a {
		return
	}
	append(&r.want, Range{a, b})
}

@(private)
_want_chain :: proc(r: ^Reader, floor: i64, above: i64) {
	if r.stride < TAIL_GUESS {
		r.stride = TAIL_GUESS
	}
	_want(r, max(floor, above - r.stride), above)
	r.stride = min(r.stride * 2, CHAIN_MAX)
}

@(private)
_get :: proc(r: ^Reader, off: i64, hint_from: i64 = -1, hint_to: i64 = 0) -> (body: []u8, next: i64, err: Error) {
	b, n, jerr := journal.record_at(r.jr, off)
	if jerr == .Missing {
		from := off if hint_from < 0 else min(hint_from, off)
		to := max(hint_to, r.jr.missing.to, off + MSG_GUESS)
		_want(r, min(from, r.jr.missing.from), to)
		return nil, off, .Missing
	}
	if jerr != .None {
		return nil, off, _jerr(jerr)
	}
	return b, n, .None
}

@(private)
_get_before :: proc(r: ^Reader, off: i64, after: i64, hint_from: i64 = -1) -> (body: []u8, next: i64, err: Error) {
	if after > off && after - off <= BACK_SCAN {
		e := after
		for {
			b, o, jerr := journal.record_before(r.jr, e)
			if jerr == .Missing {
				from := off if hint_from < 0 else min(hint_from, off)
				_want(r, min(from, r.jr.missing.from), max(after, r.jr.missing.to))
				return nil, off, .Missing
			}
			if jerr != .None || o < off {
				break
			}
			if o == off {
				return b, e, .None
			}
			e = o
		}
	}
	return _get(r, off, hint_from, after)
}

@(private)
_node :: proc(r: ^Reader, off: i64) -> (n: Node, err: Error) {
	body, _ := _get(r, off) or_return
	rd := prim.reader(body)
	if Kind(prim.read_u8(&rd)) != .Msg {
		return n, .Corrupt
	}
	l: Links
	decode_links(&rd, off, &l)
	m := decode_msg(&rd, off)
	if rd.err != .None {
		return n, .Corrupt
	}
	return Node{off, m.parent, m.depth, m.jump, m.jump_depth}, .None
}

@(private)
_decode_msg :: proc(body: []u8, off: i64) -> (m: Msg, err: Error) {
	rd := prim.reader(body)
	if Kind(prim.read_u8(&rd)) != .Msg {
		return m, .Corrupt
	}
	l: Links
	decode_links(&rd, off, &l)
	m = decode_msg(&rd, off)
	if rd.err != .None {
		return m, .Corrupt
	}
	return m, .None
}

read_head :: proc(r: ^Reader, allocator := context.allocator) -> (h: Head, err: Error) {
	body, _ := _get(r, 0, 0, 512) or_return
	rec := decode(body, 0, r.scratch) or_return
	head, ok := rec.body.(Head)
	if !ok {
		return h, .Corrupt
	}
	if head.version > FORMAT_VERSION {
		return h, .Unsupported
	}
	h = head
	h.provider = _clone_str(head.provider, allocator) or_return
	h.model = _clone_str(head.model, allocator) or_return
	h.title = _clone_str(head.title, allocator) or_return
	return h, .None
}

read_tail :: proc(r: ^Reader) -> (t: Tail, err: Error) {
	end := journal.reader_end(r.jr)
	t.length = end
	if end == 0 {
		return t, .Not_Found
	}
	body, off, jerr := journal.record_before(r.jr, end)
	if jerr == .Missing {
		_want(r, end - suggested_tail(end), end)
		return t, .Missing
	}
	if jerr != .None {
		return t, _jerr(jerr)
	}
	_, links := decode_links_only(body, off) or_return
	t.last = off
	t.links = links
	missing := false
	if links.leaf_event != 0 {
		if b, _, e := _get(r, links.leaf_event); e == .Missing {
			missing = true
		} else if e != .None {
			return t, e
		} else {
			rec := decode(b, links.leaf_event, r.scratch) or_return
			#partial switch v in rec.body {
			case Msg:
				t.leaf = links.leaf_event
				t.fork_head = v.fork_head
			case Leaf:
				t.leaf = v.msg
				t.fork_head = v.fork_head
			case:
				return t, .Corrupt
			}
		}
	}
	if links.leaf_seal != 0 {
		if b, _, e := _get(r, links.leaf_seal); e == .Missing {
			missing = true
		} else if e != .None {
			return t, e
		} else {
			rec := decode(b, links.leaf_seal, r.scratch) or_return
			#partial switch v in rec.body {
			case Seal:
				t.leaf_status = v.status
			case Interrupted:
				t.leaf_status = .Interrupted
			case:
				return t, .Corrupt
			}
		}
	}
	if links.pending != 0 {
		if b, _, e := _get(r, links.pending); e == .Missing {
			missing = true
		} else if e != .None {
			return t, e
		} else {
			rec := decode(b, links.pending, r.scratch) or_return
			#partial switch v in rec.body {
			case Queue:
				t.queued = len(v.list)
			case Unqueue:
				t.queued = len(v.list)
			case:
				return t, .Corrupt
			}
		}
	}
	for o in links_open(&t.links) {
		if o.state != .Running || o.last == 0 {
			continue
		}
		b, _, e := _get(r, o.last)
		if e == .Missing {
			missing = true
			continue
		}
		if e != .None {
			return t, e
		}
		rec := decode(b, o.last, r.scratch) or_return
		blk, ok := rec.body.(Block)
		if !ok || blk.msg != o.msg {
			return t, .Corrupt
		}
		if .Start in blk.flags && blk.kind == .Permission {
			t.awaiting = true
		}
	}
	if missing {
		return t, .Missing
	}
	t.status = derive_status(&t)
	return t, .None
}

derive_status :: proc "contextless" (t: ^Tail) -> Status {
	running, revive := false, false
	for o in links_open(&t.links) {
		if o.state == .Running {
			running = true
		} else {
			revive = true
		}
	}
	switch {
	case running && t.awaiting:
		return .Awaiting_Permission
	case running:
		return .Running
	case t.queued > 0:
		return .Queued
	case revive:
		return .Interrupted
	case t.leaf_status == .Failed:
		return .Failed
	case t.leaf_status == .Interrupted:
		return .Interrupted
	}
	return .Idle
}

unsealed :: proc "contextless" (t: ^Tail) -> []Open {
	return links_open(&t.links)
}

leaf_position :: proc "contextless" (t: ^Tail) -> Position {
	return Position{t.leaf, t.links.leaf_seal, true}
}

page :: proc(r: ^Reader, t: ^Tail, from: Position, limit: int, allocator := context.allocator) -> (p: Page, err: Error) {
	pos := from
	if pos.msg == 0 {
		pos = leaf_position(t)
	}
	if limit <= 0 || pos.msg == 0 {
		p.next = pos
		p.more = pos.msg != 0
		return p, .None
	}
	out := make([dynamic]Message, 0, limit, allocator)
	bound := t.length
	lowest := t.length
	missing := false
	prev_depth: i64 = -1
	for pos.msg != 0 && len(out) < limit {
		if pos.msg >= bound {
			return p, .Corrupt
		}
		msg := Message{
			off = pos.msg,
		}
		below := bound
		re := _resolve(r, t, pos, bound, &msg, &below, allocator)
		if re != .None && re != .Missing {
			return p, re
		}
		body, _, e := _get_before(r, pos.msg, below)
		if e == .Missing {
			seen := len(out)
			per := (t.length - lowest) / i64(seen) if seen > 0 else i64(MSG_GUESS)
			_want(r, pos.msg - per * i64(limit - seen - 1), bound)
			_want_chain(r, 0, bound)
			missing = true
			break
		}
		if e != .None {
			return p, e
		}
		if re == .Missing {
			missing = true
		}
		m := _decode_msg(body, pos.msg) or_return
		if prev_depth >= 0 && prev_depth != m.depth + 1 {
			return p, .Corrupt
		}
		_message_from(&msg, &m, allocator) or_return
		next := Position{m.parent, m.parent_seal, m.parent == 0 || m.parent_seal != 0}
		prev_depth = m.depth
		append(&out, msg)
		lowest = pos.msg
		bound = pos.msg
		pos = next
	}
	if se := _page_siblings(r, t, out[:]); se == .Missing {
		missing = true
	} else if se != .None {
		return p, se
	}
	p.messages = out[:]
	p.next = pos
	p.more = pos.msg != 0
	if missing {
		return p, .Missing
	}
	return p, .None
}

message :: proc(r: ^Reader, t: ^Tail, pos: Position, allocator := context.allocator) -> (msg: Message, err: Error) {
	msg.off = pos.msg
	below := t.length
	_resolve(r, t, pos, t.length, &msg, &below, allocator) or_return
	body, _ := _get_before(r, pos.msg, below) or_return
	m := _decode_msg(body, pos.msg) or_return
	_message_from(&msg, &m, allocator) or_return
	one := []Message{msg}
	_page_siblings(r, t, one) or_return
	return one[0], .None
}

siblings :: proc(r: ^Reader, t: ^Tail, msg: i64, allocator := context.allocator) -> (list: []i64, pos: int, err: Error) {
	m := _node(r, msg) or_return
	newest := _newest_children(r, t, []i64{m.parent}) or_return
	start := newest[0] if newest[0] != 0 else msg
	out := make([dynamic]i64, allocator)
	s := start
	for s != 0 {
		append(&out, s)
		body, _, ge := _get(r, s)
		if ge == .Missing {
			_want_chain(r, m.parent, s)
		}
		if ge != .None {
			delete(out)
			return nil, 0, ge
		}
		sm := _decode_msg(body, s) or_return
		if sm.parent != m.parent {
			delete(out)
			return nil, 0, .Corrupt
		}
		s = sm.prev_sibling
	}
	slice.reverse(out[:])
	for o, i in out {
		if o == msg {
			pos = i + 1
		}
	}
	if pos == 0 {
		delete(out)
		return nil, 0, .Corrupt
	}
	return out[:], pos, .None
}

is_ancestor :: proc(r: ^Reader, a: i64, x: i64) -> (yes: bool, err: Error) {
	if a == 0 || a == x {
		return true, .None
	}
	if x < a {
		return false, .None
	}
	na := _node(r, a) or_return
	v := _node(r, x) or_return
	return _ancestor_from(r, na, v)
}

@(private)
_ancestor_from :: proc(r: ^Reader, a: Node, start: Node) -> (yes: bool, err: Error) {
	v := start
	for {
		if v.off == a.off {
			return true, .None
		}
		if v.off < a.off || v.depth <= a.depth {
			return false, .None
		}
		next := v.jump if v.jump_depth >= a.depth else v.parent
		if next < a.off {
			return false, .None
		}
		v = _node(r, next) or_return
	}
}

level_ancestor :: proc(r: ^Reader, x: i64, depth: i64) -> (anc: i64, err: Error) {
	if depth <= 0 {
		return 0, .None
	}
	v := _node(r, x) or_return
	if depth > v.depth {
		return 0, .Invalid
	}
	for v.depth > depth {
		next := v.jump if v.jump_depth >= depth else v.parent
		v = _node(r, next) or_return
	}
	return v.off, .None
}

switch_target :: proc(r: ^Reader, t: ^Tail, s: i64) -> (leaf: i64, err: Error) {
	above := t.length
	leaf, err = _switch_walk(r, t, s, &above)
	if err == .Missing {
		_want_chain(r, s, above)
	}
	return
}

@(private)
_switch_walk :: proc(r: ^Reader, t: ^Tail, s: i64, cursor: ^i64) -> (leaf: i64, err: Error) {
	ns := _node(r, s) or_return
	memo := _memo_make(r.scratch) or_return
	e := t.links.leaf_event
	above := t.length
	for e != 0 && e > s {
		cursor^ = above
		body, _ := _get_before(r, e, above) or_return
		rd := prim.reader(body)
		kind := Kind(prim.read_u8(&rd))
		l: Links
		decode_links(&rd, e, &l)
		prev: i64
		#partial switch kind {
		case .Msg:
			v := decode_msg(&rd, e)
			if rd.err != .None {
				return 0, .Corrupt
			}
			prev = v.prev_leaf_event
			if v.depth > ns.depth {
				if ok := _in_subtree(r, ns, Node{e, v.parent, v.depth, v.jump, v.jump_depth}, &memo) or_return; ok {
					return e, .None
				}
			}
		case .Leaf:
			v := decode_leaf(&rd, e)
			if rd.err != .None {
				return 0, .Corrupt
			}
			prev = v.prev_leaf_event
			if v.msg == s {
				return s, .None
			}
			if v.msg > s {
				hit := _memo_get(&memo, v.msg)
				if hit == 0 {
					nm := _node(r, v.msg) or_return
					if nm.depth > ns.depth {
						hit = 2 if (_in_subtree(r, ns, nm, &memo) or_return) else 1
					} else {
						hit = 1
					}
				}
				if hit == 2 {
					return v.msg, .None
				}
			}
		case:
			return 0, .Corrupt
		}
		if prev >= e {
			return 0, .Corrupt
		}
		above = e
		e = prev
	}
	return s, .None
}

@(private)
MEMO_SIZE :: 4096

@(private)
Memo :: struct {
	keys: []i64,
	vals: []u8,
	path: [dynamic]i64,
}

@(private)
_memo_make :: proc(allocator: runtime.Allocator) -> (m: Memo, err: Error) {
	keys, ke := make([]i64, MEMO_SIZE, allocator)
	vals, ve := make([]u8, MEMO_SIZE, allocator)
	if ke != nil || ve != nil {
		return m, .No_Memory
	}
	return Memo{keys = keys, vals = vals, path = make([dynamic]i64, allocator)}, .None
}

@(private)
_memo_get :: proc(m: ^Memo, off: i64) -> u8 {
	i := int(_child_hash(u64(off)) & (MEMO_SIZE - 1))
	if m.keys[i] == off {
		return m.vals[i]
	}
	return 0
}

@(private)
_memo_put :: proc(m: ^Memo, off: i64, yes: bool) {
	i := int(_child_hash(u64(off)) & (MEMO_SIZE - 1))
	m.keys[i] = off
	m.vals[i] = 2 if yes else 1
}

@(private)
_in_subtree :: proc(r: ^Reader, a: Node, start: Node, memo: ^Memo) -> (yes: bool, err: Error) {
	clear(&memo.path)
	v := start
	for {
		if v.off == a.off {
			yes = true
			break
		}
		if v.off < a.off || v.depth <= a.depth {
			break
		}
		if c := _memo_get(memo, v.off); c != 0 {
			yes = c == 2
			break
		}
		append(&memo.path, v.off)
		next := v.jump if v.jump_depth >= a.depth else v.parent
		if next < a.off {
			break
		}
		if c := _memo_get(memo, next); c != 0 {
			yes = c == 2
			break
		}
		v = _node(r, next) or_return
	}
	for off in memo.path {
		_memo_put(memo, off, yes)
	}
	if start.parent != 0 && start.depth - 1 >= a.depth {
		_memo_put(memo, start.parent, yes)
	}
	return yes, .None
}

pending_items :: proc(r: ^Reader, t: ^Tail, allocator := context.allocator) -> (items: []Queue_Item, err: Error) {
	if t.links.pending == 0 {
		return nil, .None
	}
	list := _pending_list(r, t.links.pending) or_return
	if len(list) == 0 {
		return nil, .None
	}
	out := make([]Queue_Item, len(list), allocator)
	missing := false
	for e, i in list {
		body, _, ge := _get(r, e.latest)
		if ge == .Missing {
			missing = true
			continue
		}
		if ge != .None {
			return nil, ge
		}
		rec := decode(body, e.latest, r.scratch) or_return
		q, ok := rec.body.(Queue)
		if !ok || q.item != e.item {
			return nil, .Corrupt
		}
		it := &out[i]
		it.item = e.item
		it.latest = e.latest
		it.cmd = q.cmd
		it.mode = q.mode
		it.text = _clone_str(q.text, allocator) or_return
		it.attachments = _clone_attachments(q.attachments, allocator) or_return
	}
	if missing {
		return nil, .Missing
	}
	return out, .None
}

@(private)
_pending_list :: proc(r: ^Reader, at: i64) -> (list: []Pending_Entry, err: Error) {
	body, _ := _get(r, at) or_return
	rec := decode(body, at, r.scratch) or_return
	#partial switch v in rec.body {
	case Queue:
		return v.list, .None
	case Unqueue:
		return v.list, .None
	}
	return nil, .Corrupt
}

@(private)
_message_from :: proc(msg: ^Message, m: ^Msg, allocator: runtime.Allocator) -> Error {
	msg.role = m.role
	msg.parent = m.parent
	msg.depth = m.depth
	msg.prev_sibling = m.prev_sibling
	msg.parent_seal = m.parent_seal
	msg.cmd = m.cmd
	msg.hlc = m.hlc
	msg.version = _clone_bytes(m.version, allocator) or_return
	msg.git_branch = _clone_str(m.git_branch, allocator) or_return
	msg.git_commit = _clone_bytes(m.git_commit, allocator) or_return
	msg.provider_session = _clone_str(m.provider_session, allocator) or_return
	msg.provider_msg = _clone_str(m.provider_msg, allocator) or_return
	msg.sibling = 1
	msg.siblings = 1
	return .None
}

@(private)
_resolve :: proc(r: ^Reader, t: ^Tail, pos: Position, bound: i64, msg: ^Message, below: ^i64, allocator: runtime.Allocator) -> Error {
	last: i64
	if pos.seal_known && pos.seal != 0 {
		if pos.seal <= pos.msg || pos.seal >= t.length {
			return .Corrupt
		}
		body, _ := _get_before(r, pos.seal, bound if bound > pos.seal else t.length) or_return
		_apply_seal(body, pos.seal, msg, allocator) or_return
		last = msg.last_block
		below^ = pos.seal
	} else if i := links_find(&t.links, pos.msg); i >= 0 {
		o := t.links.open[i]
		last = o.last
		msg.open = o.state == .Running
		msg.open_state = o.state
		msg.status = .Open if o.state == .Running else .Interrupted
		msg.last_block = last
	} else {
		seal, l := _scan_seal(r, pos.msg, t.length) or_return
		last = l
		if seal != 0 {
			body, _ := _get(r, seal) or_return
			_apply_seal(body, seal, msg, allocator) or_return
			last = msg.last_block
			below^ = min(below^, seal)
		} else {
			msg.open = true
			msg.last_block = last
		}
	}
	if last == 0 {
		return .None
	}
	blocks, first, err := _blocks(r, pos.msg, last, below^, allocator)
	msg.blocks = blocks
	if err == .None && first != 0 {
		below^ = min(below^, first)
	}
	return err
}

@(private)
_apply_seal :: proc(body: []u8, off: i64, msg: ^Message, allocator: runtime.Allocator) -> Error {
	rec := decode(body, off) or_return
	#partial switch v in rec.body {
	case Seal:
		if v.msg != msg.off {
			return .Corrupt
		}
		msg.seal = off
		msg.status = v.status
		msg.usage = v.usage
		msg.last_block = v.last_block
		msg.seal_cmd = v.cmd
		msg.seal_provider_msg = _clone_str(v.provider_msg, allocator) or_return
		return .None
	case Interrupted:
		if v.msg != msg.off {
			return .Corrupt
		}
		msg.seal = off
		msg.status = .Interrupted
		msg.last_block = v.last_block
		msg.seal_cmd = v.cmd
		if v.revive {
			msg.open_state = .Revive
		}
		return .None
	}
	return .Corrupt
}

@(private)
_scan_seal :: proc(r: ^Reader, msg: i64, end: i64) -> (seal: i64, last: i64, err: Error) {
	_, pos := _get(r, msg) or_return
	for pos < end {
		body, next, e := _get(r, pos, -1, min(end, pos + TAIL_GUESS))
		if e != .None {
			return 0, 0, e
		}
		rd := prim.reader(body)
		kind := Kind(prim.read_u8(&rd))
		l: Links
		decode_links(&rd, pos, &l)
		#partial switch kind {
		case .Block:
			b := decode_block(&rd, pos)
			if rd.err == .None && b.msg == msg {
				last = pos
			}
		case .Seal:
			s := decode_seal(&rd, pos)
			if rd.err == .None && s.msg == msg {
				return pos, s.last_block, .None
			}
		case .Interrupted:
			s := decode_interrupted(&rd, pos)
			if rd.err == .None && s.msg == msg {
				return pos, s.last_block, .None
			}
		}
		if rd.err != .None {
			return 0, 0, .Corrupt
		}
		pos = next
	}
	return 0, last, .None
}

@(private)
_blocks :: proc(r: ^Reader, msg: i64, last: i64, after: i64, allocator: runtime.Allocator) -> (out: []Block_View, first: i64, err: Error) {
	chunks := make([dynamic]Chunk, r.scratch)
	off := last
	above := after if after > last else journal.reader_end(r.jr)
	for off != 0 {
		body, _, e := _get_before(r, off, above, msg)
		if e != .None {
			return nil, 0, e
		}
		first = off
		above = off
		rec := decode(body, off, r.scratch) or_return
		b, ok := rec.body.(Block)
		if !ok || b.msg != msg {
			return nil, 0, .Corrupt
		}
		c := Chunk{
			off   = off,
			index = b.index,
			flags = b.flags,
			kind  = b.kind,
		}
		c.id = _clone_str(b.id, r.scratch) or_return
		c.name = _clone_str(b.name, r.scratch) or_return
		c.data = _clone_bytes(b.data, r.scratch) or_return
		c.ref.oid = _clone_bytes(b.ref.oid, r.scratch) or_return
		c.ref.size = b.ref.size
		c.ref.preview = _clone_bytes(b.ref.preview, r.scratch) or_return
		if _, aerr := append(&chunks, c); aerr != nil {
			return nil, 0, .No_Memory
		}
		off = b.prev
	}
	slice.reverse(chunks[:])
	slice.stable_sort_by(chunks[:], proc(a, b: Chunk) -> bool {
		return a.index < b.index
	})
	groups := 0
	for i in 0 ..< len(chunks) {
		if i == 0 || chunks[i].index != chunks[i - 1].index {
			groups += 1
		}
	}
	views, verr := make([]Block_View, groups, allocator)
	if verr != nil {
		return nil, 0, .No_Memory
	}
	g := 0
	i := 0
	for i < len(chunks) {
		j := i
		size := 0
		for j < len(chunks) && chunks[j].index == chunks[i].index {
			size += len(chunks[j].data)
			j += 1
		}
		head := &chunks[i]
		if .Start not_in head.flags {
			return nil, 0, .Corrupt
		}
		for k in i + 1 ..< j {
			if .Start in chunks[k].flags || .Ref in chunks[k].flags || .Ref in head.flags {
				return nil, 0, .Corrupt
			}
		}
		v := &views[g]
		v.index = head.index
		v.kind = head.kind
		v.failed = .Failed in head.flags
		v.off = head.off
		v.id = _clone_str(head.id, allocator) or_return
		v.name = _clone_str(head.name, allocator) or_return
		if .Ref in head.flags {
			v.is_ref = true
			v.ref.oid = _clone_bytes(head.ref.oid, allocator) or_return
			v.ref.size = head.ref.size
			v.ref.preview = _clone_bytes(head.ref.preview, allocator) or_return
		} else if size > 0 {
			text, aerr := make([]u8, size, allocator)
			if aerr != nil {
				return nil, 0, .No_Memory
			}
			n := 0
			for k in i ..< j {
				n += copy(text[n:], chunks[k].data)
			}
			v.text = text
		}
		g += 1
		i = j
	}
	return views, first, .None
}

@(private)
_newest_children :: proc(r: ^Reader, t: ^Tail, parents: []i64) -> (newest: []i64, err: Error) {
	newest = make([]i64, len(parents), r.scratch)
	if r.w != nil {
		for p, i in parents {
			newest[i] = _writer_newest_child(r.w, p) or_return
		}
		return newest, .None
	}
	low := max(i64)
	for p in parents {
		low = min(low, p)
	}
	if !r.has_kids {
		_fork_walk(r, t, parents, newest, low) or_return
		return newest, .None
	}
	end := journal.reader_end(r.jr)
	_fork_walk(r, t, parents, newest, max(low, r.kids.covered)) or_return
	fallback := false
	for p, i in parents {
		if newest[i] != 0 {
			continue
		}
		child, _, e := children_get(&r.kids, p)
		if e != .None || child <= p || child >= end {
			fallback = true
			break
		}
		newest[i] = child
	}
	if fallback {
		for &n in newest {
			n = 0
		}
		_fork_walk(r, t, parents, newest, low) or_return
	}
	return newest, .None
}

@(private)
_fork_walk :: proc(r: ^Reader, t: ^Tail, parents: []i64, newest: []i64, floor: i64) -> Error {
	above := t.length
	err := _fork_walk_from(r, t, parents, newest, floor, &above)
	if err == .Missing {
		_want_chain(r, floor, above)
	}
	return err
}

@(private)
_fork_walk_from :: proc(r: ^Reader, t: ^Tail, parents: []i64, newest: []i64, floor: i64, cursor: ^i64) -> Error {
	need := 0
	for p, i in parents {
		dup := false
		for q in parents[:i] {
			dup ||= q == p
		}
		if !dup && newest[i] == 0 {
			need += 1
		}
	}
	f := t.fork_head
	above := cursor^
	found := 0
	for f != 0 && f > floor && found < need {
		cursor^ = above
		body, _ := _get_before(r, f, above) or_return
		m := _decode_msg(body, f) or_return
		cursor^ = f
		hit := false
		for p, i in parents {
			if p == m.parent && newest[i] == 0 {
				newest[i] = f
				hit = true
			}
		}
		if hit {
			found += 1
		}
		ple := m.prev_leaf_event
		if ple == 0 || ple <= floor {
			break
		}
		pb, _ := _get_before(r, ple, f) or_return
		rec := decode(pb, ple, r.scratch) or_return
		nf: i64
		#partial switch v in rec.body {
		case Msg:
			nf = v.fork_head
		case Leaf:
			nf = v.fork_head
		case:
			return .Corrupt
		}
		if nf >= f {
			return .Corrupt
		}
		above = ple
		cursor^ = ple
		f = nf
	}
	return .None
}

@(private)
_page_siblings :: proc(r: ^Reader, t: ^Tail, msgs: []Message) -> Error {
	if len(msgs) == 0 {
		return .None
	}
	parents := make([]i64, len(msgs), r.scratch)
	for m, i in msgs {
		parents[i] = m.parent
	}
	newest := _newest_children(r, t, parents) or_return
	missing := false
	for &m, i in msgs {
		start := newest[i]
		if start == 0 {
			start = m.off
		}
		count := 0
		pos := 0
		s := start
		for s != 0 {
			count += 1
			if s == m.off {
				pos = count
			}
			if s == m.off {
				s = m.prev_sibling
				continue
			}
			body, _, e := _get(r, s)
			if e == .Missing {
				_want_chain(r, m.parent, s)
				missing = true
				break
			}
			if e != .None {
				return e
			}
			sm := _decode_msg(body, s) or_return
			if sm.parent != m.parent {
				return .Corrupt
			}
			s = sm.prev_sibling
		}
		if missing {
			continue
		}
		if pos == 0 {
			return .Corrupt
		}
		m.siblings = count
		m.sibling = count - pos + 1
	}
	if missing {
		return .Missing
	}
	return .None
}

@(private)
_clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> ([]u8, Error) {
	if len(b) == 0 {
		return nil, .None
	}
	out, err := make([]u8, len(b), allocator)
	if err != nil {
		return nil, .No_Memory
	}
	copy(out, b)
	return out, .None
}

@(private)
_clone_str :: proc(s: string, allocator: runtime.Allocator) -> (string, Error) {
	b, err := _clone_bytes(transmute([]u8)s, allocator)
	return string(b), err
}

@(private)
_clone_attachments :: proc(atts: []Attachment, allocator: runtime.Allocator) -> (out: []Attachment, err: Error) {
	if len(atts) == 0 {
		return nil, .None
	}
	res, aerr := make([]Attachment, len(atts), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	for a, i in atts {
		res[i].name = _clone_str(a.name, allocator) or_return
		res[i].mime = _clone_str(a.mime, allocator) or_return
		res[i].oid = _clone_bytes(a.oid, allocator) or_return
		res[i].size = a.size
	}
	return res, .None
}
