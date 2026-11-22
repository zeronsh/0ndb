package fs

import "core:crypto/blake2b"
import "core:slice"
import "../crdt"
import "../fshist"
import "../fstree"
import "../prim"

Base_Note :: enum u8 {
	Merged,
	Current,
	Mismatch,
	Not_Text,
}

Base_Proc :: #type proc(m: ^Mount, rel: string, note: Base_Note, data: rawptr)

registry_set_base_note :: proc(reg: ^Registry, cb: Base_Proc, data: rawptr) {
	reg.on_base = cb
	reg.base_data = data
}

@(private)
Pin :: struct {
	path:      string,
	read:      [dynamic]crdt.Op_Id,
	read_hash: [32]u8,
	has_read:  bool,
	write:     [dynamic]crdt.Op_Id,
	base_hash: [32]u8,
	has_write: bool,
	has_base:  bool,
}

@(private)
Path_Hold :: struct {
	scope: ^Scope,
	path:  string,
}

@(private)
_content_hash :: proc(data: []u8) -> (out: [32]u8) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, data)
	blake2b.final(&ctx, out[:])
	return
}

@(private)
_pin :: proc(s: ^Scope, rel: string, create: bool) -> ^Pin {
	for &p in s.pins {
		if p.path == rel {
			return &p
		}
	}
	if !create || s.mount == nil {
		return nil
	}
	a := s.allocator
	k, _ := clone_string(rel, a)
	append(&s.pins, Pin{path = k, read = make([dynamic]crdt.Op_Id, a), write = make([dynamic]crdt.Op_Id, a)})
	return &s.pins[len(s.pins) - 1]
}

@(private)
_pin_free :: proc(s: ^Scope, i: int) {
	a := s.allocator
	p := s.pins[i]
	delete(p.path, a)
	delete(p.read)
	delete(p.write)
	ordered_remove(&s.pins, i)
}

@(private)
_pin_drop :: proc(s: ^Scope, rel: string) {
	for p, i in s.pins {
		if p.path == rel {
			_pin_free(s, i)
			return
		}
	}
}

@(private)
_file_entry :: proc(m: ^Mount, rel: string) -> (e: Entry, ok: bool) {
	got, found, err := shadow_get(&m.shadow, rel)
	if err != .None || !found || got.kind != .File {
		return {}, false
	}
	return got, true
}

@(private)
_file_inode :: proc(m: ^Mount, rel: string) -> (inode: fstree.Inode_Id, ok: bool) {
	if e, found := _file_entry(m, rel); found {
		return e.inode, true
	}
	h := m.history
	if h == nil {
		return
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &lvs) != .None {
		return
	}
	snap, serr := version_snapshot(h, lvs[:])
	if serr != .None {
		return
	}
	defer fstree.snapshot_destroy(&snap)
	id, found, lerr := fstree.lookup(&snap, rel)
	if lerr != nil || !found {
		return
	}
	info, iok, ierr := fstree.info(&snap, id, context.temp_allocator)
	if ierr != nil || !iok || !info.present || info.kind != .File {
		return
	}
	return id, true
}

scope_read_base :: proc(s: ^Scope, rel: string, data: []u8) -> Error {
	m := s.mount
	if m == nil || m.history == nil || path_internal(rel) {
		return .None
	}
	mount_wake(m) or_return
	inode, ok := _file_inode(m, rel)
	if !ok {
		_pin_drop(s, rel)
		return .None
	}
	clean, cok := eol_clean(m, rel, data, inode, true)
	cur, terr := history_text_at(m.history, inode, m.synced[:], context.temp_allocator)
	if !cok || terr != .None || string(cur) != string(clean) {
		if p := _pin(s, rel, false); p != nil {
			p.has_read = false
		}
		return .None
	}
	hash := _content_hash(clean)
	if oerr := observe_record(m, s, .Read, inode, rel, m.synced[:], hash); oerr != .None && oerr != .Reloading {
		return oerr
	}
	p := _pin(s, rel, true)
	clear(&p.read)
	append(&p.read, ..m.synced[:])
	p.read_hash = hash
	p.has_read = true
	return .None
}

@(private)
observe_record :: proc(m: ^Mount, s: ^Scope, kind: fshist.Observe_Kind, inode: fstree.Inode_Id, rel: string, version: []crdt.Op_Id, hash: [32]u8) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	fshist.encode_observe(&buf, fshist.Observe_Op{kind = kind, inode = inode_op(m.history, inode), path = rel, version = version, hash = hash})
	b: Builder
	builder_init(&b, m.history, s.actor)
	builder_opaque(&b, buf[:])
	return builder_commit(m, &b)
}

Observation :: struct {
	actor:   prim.Id,
	lv:      crdt.Lv,
	using op: fshist.Observe_Op,
}

history_observations :: proc(h: ^History, from: crdt.Lv, out: ^[dynamic]Observation, allocator := context.allocator) -> Error {
	lv := from
	end := h.g.next
	for lv < end {
		first, n, stream, off, ok := history_batch_at(h, lv)
		if !ok {
			return .Corrupt
		}
		b, berr := history_read_batch(h, stream, off, context.temp_allocator)
		if berr == .Redacted {
			lv = first + crdt.Lv(n)
			continue
		}
		if berr != .None {
			return berr
		}
		at := first
		for op in b.ops {
			if op.kind == .Opaque && at >= lv && len(op.content) > 0 && op.content[0] == fshist.TOP_OBSERVE {
				if o, dok := fshist.decode_observe(op.content, allocator); dok {
					o.path, _ = clone_string(o.path, allocator)
					append(out, Observation{actor = b.actor, lv = at, op = o})
				}
			}
			at += crdt.Lv(max(op.len, 1))
		}
		lv = first + crdt.Lv(n)
	}
	return .None
}

scope_write_begin :: proc(s: ^Scope, rel: string) {
	m := s.mount
	if m == nil || m.history == nil || path_internal(rel) {
		return
	}
	if mount_wake(m) != .None {
		return
	}
	held := false
	for h in m.holds {
		held ||= h.scope == s && h.path == rel
	}
	if !held {
		k, _ := clone_string(rel, m.allocator)
		append(&m.holds, Path_Hold{scope = s, path = k})
	}
	if p := _pin(s, rel, false); p != nil {
		p.has_write = false
		p.has_base = false
	}
	inode, ok := _file_inode(m, rel)
	if !ok {
		return
	}
	cur, terr := history_text_at(m.history, inode, m.synced[:], context.temp_allocator)
	if terr != .None {
		return
	}
	if oerr := observe_record(m, s, .Write_Begin, inode, rel, m.synced[:], _content_hash(cur)); oerr != .None && oerr != .Reloading {
		return
	}
	p := _pin(s, rel, true)
	clear(&p.write)
	append(&p.write, ..m.synced[:])
	p.has_write = true
}

scope_write_base :: proc(s: ^Scope, rel: string, data: []u8) {
	m := s.mount
	if m == nil {
		return
	}
	p := _pin(s, rel, false)
	if p == nil || !p.has_write || mount_wake(m) != .None {
		return
	}
	inode, ok := _file_inode(m, rel)
	clean, cok := eol_clean(m, rel, data, inode, ok)
	if !cok {
		return
	}
	p.base_hash = _content_hash(clean)
	p.has_base = true
}

scope_write_end :: proc(s: ^Scope, rel: string) {
	m := s.mount
	if m == nil {
		return
	}
	if _hold_drop(m, s, rel) && !mount_held(m, rel) {
		mount_schedule(m, 0)
	}
}

scope_pinned :: proc(s: ^Scope, rel: string) -> bool {
	p := _pin(s, rel, false)
	return p != nil && (p.has_read || p.has_write)
}

@(private)
mount_held_by :: proc(m: ^Mount, rel: string, s: ^Scope) -> bool {
	if s == nil {
		return false
	}
	for h in m.holds {
		if h.path == rel && h.scope == s {
			return true
		}
	}
	return false
}

mount_held :: proc(m: ^Mount, rel: string) -> bool {
	for h in m.holds {
		if h.path == rel {
			return true
		}
	}
	return false
}

@(private)
_hold_drop :: proc(m: ^Mount, s: ^Scope, rel: string) -> bool {
	for h, i in m.holds {
		if h.scope == s && h.path == rel {
			delete(h.path, m.allocator)
			ordered_remove(&m.holds, i)
			return true
		}
	}
	return false
}

@(private)
scope_pins_free :: proc(s: ^Scope) {
	for len(s.pins) > 0 {
		_pin_free(s, len(s.pins) - 1)
	}
	delete(s.pins)
	s.pins = nil
}

@(private)
scope_release :: proc(s: ^Scope) {
	scope_pins_free(s)
	if scope_unhold(s) {
		mount_schedule(s.mount, 0)
	}
}

@(private)
scope_unhold :: proc(s: ^Scope) -> (released: bool) {
	m := s.mount
	if m == nil {
		return false
	}
	i := 0
	for i < len(m.holds) {
		if m.holds[i].scope == s {
			delete(m.holds[i].path, m.allocator)
			ordered_remove(&m.holds, i)
			released = true
			continue
		}
		i += 1
	}
	return
}

@(private)
_base_note :: proc(m: ^Mount, rel: string, note: Base_Note) {
	if m.reg != nil && m.reg.on_base != nil {
		m.reg.on_base(m, rel, note, m.reg.base_data)
	}
}

@(private)
_base_version :: proc(m: ^Mount, c: ^Change) -> (v: []crdt.Op_Id, pinned: bool) {
	s := c.scope
	p := _pin(s, c.path, false)
	if p == nil {
		return nil, false
	}
	h := m.history
	if p.has_write && p.has_base {
		if t, err := history_text_at(h, c.old.inode, p.write[:], context.temp_allocator); err == .None && _content_hash(t) == p.base_hash {
			return _base_parents(m, s.actor, c.old.inode, p.write[:], p.base_hash), true
		}
	}
	if p.has_read {
		if t, err := history_text_at(h, c.old.inode, p.read[:], context.temp_allocator); err == .None && _content_hash(t) == p.read_hash {
			return _base_parents(m, s.actor, c.old.inode, p.read[:], p.read_hash), true
		}
	}
	return nil, p.has_read || p.has_base
}

@(private)
_base_parents :: proc(m: ^Mount, actor: prim.Id, inode: fstree.Inode_Id, v: []crdt.Op_Id, hash: [32]u8) -> []crdt.Op_Id {
	h := m.history
	known := crdt.graph_known(&h.g, actor)
	if known == 0 {
		return slice.clone(v, context.temp_allocator)
	}
	own, ok := crdt.graph_lv(&h.g, crdt.Op_Id{actor, known - 1})
	vl := make([dynamic]crdt.Lv, context.temp_allocator)
	if !ok || crdt.graph_version_lvs(&h.g, v, &vl) != .None {
		return nil
	}
	if crdt.graph_contains(&h.g, vl[:], own) {
		return slice.clone(v, context.temp_allocator)
	}
	one := [1]crdt.Lv{own}
	both := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, vl[:], one[:], &both)
	ids := crdt.graph_version_ids(&h.g, both[:], context.temp_allocator)
	t, err := history_text_at(h, inode, ids, context.temp_allocator)
	if err != .None || _content_hash(t) != hash {
		return nil
	}
	return ids
}

@(private)
rebase_changes :: proc(p: ^Pass) -> Error {
	m := p.m
	if m.history == nil {
		return .None
	}
	h := m.history
	keep := make([dynamic]Change, 0, len(p.changes), context.temp_allocator)
	for &c in p.changes {
		if c.scope == nil || c.kind != .Modify || c.disk != .File || c.moved != "" || c.old.kind != .File {
			if c.scope != nil && scope_pinned(c.scope, c.path) {
				_pin_drop(c.scope, c.path)
				_base_note(m, c.path, .Mismatch)
			}
			append(&keep, c)
			continue
		}
		v, pinned := _base_version(m, &c)
		if v == nil {
			if pinned {
				_pin_drop(c.scope, c.path)
				_base_note(m, c.path, .Mismatch)
			}
			append(&keep, c)
			continue
		}
		vl := make([dynamic]crdt.Lv, context.temp_allocator)
		sl := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, v, &vl) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
			_pin_drop(c.scope, c.path)
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		if crdt.frontier_eq(vl[:], sl[:]) {
			_pin_drop(c.scope, c.path)
			_base_note(m, c.path, .Current)
			append(&keep, c)
			continue
		}
		off_line := false
		for lv in vl {
			if !crdt.graph_contains(&h.g, sl[:], lv) {
				off_line = true
				break
			}
		}
		if off_line {
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		done, rerr := rebase_commit(p, &c, v)
		#partial switch rerr {
		case .None:
		case .Reloading, .Io, .No_Space:
			return rerr
		case:
			_pin_drop(c.scope, c.path)
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		_pin_drop(c.scope, c.path)
		if !done {
			_base_note(m, c.path, .Not_Text)
			append(&keep, c)
			continue
		}
		_base_note(m, c.path, .Merged)
	}
	clear(&p.changes)
	append(&p.changes, ..keep[:])
	return .None
}

@(private)
rebase_commit :: proc(p: ^Pass, c: ^Change, v: []crdt.Op_Id) -> (done: bool, err: Error) {
	m := p.m
	h := m.history
	data, oid, binary, ok := read_content(m, c.path, c.stat, c.old.inode, true) or_return
	if !ok || binary || .Opaque in tree_flags(h, c.old.inode) {
		return false, .None
	}
	old := history_text_at(h, c.old.inode, v, context.temp_allocator) or_return
	b: Builder
	builder_init(&b, h, c.scope.actor)
	shadow_txn_begin(&m.shadow)
	err = emit_text_edits(m, &b, c.old.inode, c.path, old, data)
	ne := c.old
	ne.stat = c.stat
	ne.oid = oid
	if err == .None {
		err = shadow_put(&m.shadow, c.path, ne)
	}
	head: crdt.Op_Id
	has := false
	if err == .None {
		head, has, err = builder_commit_at(m, &b, v)
	}
	if err != .None && err != .Reloading {
		shadow_txn_rollback(&m.shadow)
		return false, err
	}
	shadow_txn_end(&m.shadow)
	attrib_set(m, c.path, c.scope.actor, true)
	if has {
		append(&p.rebased, head)
	}
	return true, err
}

@(private)
builder_commit_at :: proc(m: ^Mount, b: ^Builder, parents: []crdt.Op_Id) -> (head: crdt.Op_Id, has: bool, err: Error) {
	if b.n == 0 {
		return {}, false, .None
	}
	h := m.history
	batch := crdt.Batch {
		actor   = b.actor,
		seq     = b.seq0,
		lamport = history_lamport_after(h, m.synced[:]),
		parents = parents,
		ops     = b.ops[:],
	}
	builder_opaque(b, commit_mark(m))
	batch.ops = b.ops[:]
	line: Maybe(string)
	if !m.hold_line {
		line = m.line
	}
	history_commit_local(h, &batch, line) or_return
	m.jpend = mount_jlen(m)
	head = crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1}
	builder_reset(b)
	return head, true, .Reloading if history_reloading(h) else .None
}

@(private)
rebase_materialize :: proc(m: ^Mount, heads: []crdt.Op_Id) -> Error {
	if len(heads) == 0 {
		return .None
	}
	h := m.history
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	hl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None || crdt.graph_version_lvs(&h.g, heads, &hl) != .None {
		return .Corrupt
	}
	both := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, sl[:], hl[:], &both)
	return materialize_to(m, crdt.graph_version_ids(&h.g, both[:], context.temp_allocator), false)
}

@(private)
hold_target :: proc(m: ^Mount, tl: []crdt.Lv, sl: []crdt.Lv) -> (out: []crdt.Lv, changed: bool, err: Error) {
	h := m.history
	held := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	for x in m.holds {
		if ino, ok := _file_inode(m, x.path); ok {
			held[ino] = true
		}
	}
	if len(held) == 0 {
		return tl, false, .None
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, sl, tl, &only_a, &only_b)
	slice.sort_by(only_b[:], proc(a, b: crdt.Lv_Span) -> bool {return a.lv < b.lv})
	excluded := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	keep := make([dynamic]crdt.Lv, context.temp_allocator)
	append(&keep, ..sl)
	add :: proc(g: ^crdt.Graph, keep: ^[dynamic]crdt.Lv, lv: crdt.Lv) {
		one := [1]crdt.Lv{lv}
		out := make([dynamic]crdt.Lv, context.temp_allocator)
		crdt.version_union(g, keep[:], one[:], &out)
		clear(keep)
		append(keep, ..out[:])
	}
	in_excluded :: proc(ex: []crdt.Lv_Span, lv: crdt.Lv) -> bool {
		for s in ex {
			if lv >= s.lv && lv < s.lv + s.len {
				return true
			}
		}
		return false
	}
	for span in only_b {
		lv := span.lv
		end := span.lv + span.len
		for lv < end {
			first, n, stream, off, ok := history_batch_at(h, lv)
			if !ok {
				return tl, false, .Corrupt
			}
			hi := min(end, first + crdt.Lv(n))
			bad := false
			buf: [1]crdt.Lv
			for par in crdt.graph_parents(&h.g, lv, &buf) {
				bad ||= in_excluded(excluded[:], par)
			}
			if !bad {
				b, berr := history_read_batch(h, stream, off, context.temp_allocator)
				if berr == .None {
					touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
					collect_touched(h, &b, first, lv, hi, &touched)
					for ino in touched {
						bad ||= ino in held
					}
				} else if berr != .Redacted {
					return tl, false, berr
				}
			}
			if bad {
				append(&excluded, crdt.Lv_Span{lv = lv, len = hi - lv})
			} else {
				add(&h.g, &keep, hi - 1)
			}
			lv = hi
		}
	}
	if len(excluded) == 0 {
		return tl, false, .None
	}
	return keep[:], true, .None
}
