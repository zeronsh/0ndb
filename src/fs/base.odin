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
	path:        string,
	read:        [dynamic]crdt.Op_Id,
	read_inode:  fstree.Inode_Id,
	read_hash:   [32]u8,
	has_read:    bool,
	write:       [dynamic]crdt.Op_Id,
	write_inode: fstree.Inode_Id,
	base_hash:   [32]u8,
	has_write:   bool,
	has_base:    bool,
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
	at, cur, terr := _pin_at(m, rel, inode)
	if !cok || terr != .None || string(cur) != string(clean) {
		if p := _pin(s, rel, false); p != nil {
			p.has_read = false
		}
		return .None
	}
	hash := _content_hash(clean)
	if oerr := observe_record(m, s, .Read, inode, rel, at, hash); oerr != .None && oerr != .Reloading {
		return oerr
	}
	p := _pin(s, rel, true)
	clear(&p.read)
	append(&p.read, ..at)
	p.read_inode = inode
	p.read_hash = hash
	p.has_read = true
	return .None
}

@(private)
_pin_at :: proc(m: ^Mount, rel: string, inode: fstree.Inode_Id) -> (at: []crdt.Op_Id, text: []u8, err: Error) {
	h := m.history
	at = m.synced[:]
	if e, found := _file_entry(m, rel); found && e.inode == inode && e.ver != 0 {
		if ids, vok := shadow_version(&m.shadow, e); vok && len(ids) > 0 {
			own := make([]crdt.Op_Id, len(ids), context.temp_allocator)
			for id, i in ids {
				own[i] = inode_op(h, id)
			}
			at = own
		}
	}
	text, err = history_text_at(h, inode, at, context.temp_allocator)
	return
}

@(private)
observe_record :: proc(m: ^Mount, s: ^Scope, kind: fshist.Observe_Kind, inode: fstree.Inode_Id, rel: string, version: []crdt.Op_Id, hash: [32]u8) -> Error {
	if !actor_on_line(m, s.actor) {
		return .None
	}
	buf := make([dynamic]u8, context.temp_allocator)
	fshist.encode_observe(&buf, fshist.Observe_Op{kind = kind, inode = inode_op(m.history, inode), path = rel, version = version, hash = hash})
	b: Builder
	builder_init(&b, m.history, s.actor)
	builder_opaque(&b, buf[:])
	if slice.equal(version, m.synced[:]) {
		return builder_commit(m, &b)
	}
	_, _, err := builder_commit_at(m, &b, version)
	return err
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
	at, cur, terr := _pin_at(m, rel, inode)
	if terr != .None {
		return
	}
	if oerr := observe_record(m, s, .Write_Begin, inode, rel, at, _content_hash(cur)); oerr != .None && oerr != .Reloading {
		return
	}
	p := _pin(s, rel, true)
	clear(&p.write)
	append(&p.write, ..at)
	p.write_inode = inode
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
_same_content :: proc(m: ^Mount, c: ^Change) -> bool {
	return c.kind == .Modify && c.moved == "" && c.disk == .File && c.old.kind == .File && disk_content_matches(m, c.path, c.stat, c.old)
}

@(private)
_change_pin :: proc(m: ^Mount, c: ^Change, buf: ^Pin) -> (p: ^Pin, actor: prim.Id, observed: bool) {
	if c.scope != nil {
		if x := _pin(c.scope, c.path, false); x != nil && (x.has_read || x.has_write) && !_same_content(m, c) {
			return x, c.scope.actor, false
		}
		return _entry_pin(m, c, buf, c.scope.actor)
	}
	a, ok := m.attrib[c.path]
	if !ok || a.used || m.history == nil {
		return _entry_pin(m, c, buf, attrib_default_actor(m, c.path))
	}
	o, found := _observed(m.history, a.actor, c.path)
	if !found || _same_content(m, c) {
		return _entry_pin(m, c, buf, attrib_default_actor(m, c.path))
	}
	buf.read = make([dynamic]crdt.Op_Id, context.temp_allocator)
	append(&buf.read, ..o.version)
	buf.read_inode = op_inode(m.history, o.inode)
	buf.read_hash = o.hash
	buf.has_read = true
	return buf, a.actor, true
}

@(private)
_entry_pin :: proc(m: ^Mount, c: ^Change, buf: ^Pin, actor: prim.Id) -> (p: ^Pin, who: prim.Id, observed: bool) {
	if m.history == nil || c.kind != .Modify || c.old.kind != .File || c.old.ver == 0 {
		return nil, {}, false
	}
	h := m.history
	snap, serr := synced_snapshot(m)
	if serr != .None {
		return nil, {}, false
	}
	removed, rerr := snapshot_removed(&snap, c.old.inode)
	fstree.snapshot_destroy(&snap)
	if rerr != .None || removed {
		return nil, {}, false
	}
	buf.read = make([dynamic]crdt.Op_Id, context.temp_allocator)
	ids, vok := shadow_version(&m.shadow, c.old)
	if !vok {
		return nil, {}, false
	}
	for id in ids {
		append(&buf.read, inode_op(h, id))
	}
	t, terr := history_text_at(h, c.old.inode, buf.read[:], context.temp_allocator)
	if terr != .None {
		return nil, {}, false
	}
	buf.read_inode = c.old.inode
	buf.read_hash = _content_hash(t)
	buf.has_read = true
	return buf, actor, true
}

@(private)
_observed :: proc(h: ^History, actor: prim.Id, rel: string) -> (o: fshist.Observe_Op, found: bool) {
	known := crdt.graph_known(&h.g, actor)
	seq := known
	written := make(map[crdt.Op_Id]bool, context.temp_allocator)
	for seq > 0 {
		lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{actor, seq - 1})
		if !ok {
			return
		}
		first, _, stream, off, bok := history_batch_at(h, lv)
		if !bok {
			return
		}
		b, berr := history_read_batch(h, stream, off, context.temp_allocator)
		if berr == .None {
			for op in b.ops {
				if op.kind == .Opaque && len(op.content) > 0 && op.content[0] == fshist.TOP_OBSERVE {
					if x, dok := fshist.decode_observe(op.content); dok && x.kind == .Read && x.path == rel {
						o = x
						found = true
					}
				}
			}
			if found {
				if written[o.inode] {
					return {}, false
				}
				return
			}
			for op in b.ops {
				if op.kind != .Opaque {
					written[op.target] = true
				}
			}
		}
		back := u64(lv - first) + 1
		seq = seq - min(seq, back)
	}
	return
}

@(private)
_change_pin_drop :: proc(m: ^Mount, c: ^Change, observed: bool) {
	if !observed && c.scope != nil {
		_pin_drop(c.scope, c.path)
	}
}

@(private)
_base_version :: proc(m: ^Mount, p: ^Pin, actor: prim.Id) -> (v: []crdt.Op_Id, inode: fstree.Inode_Id, pinned: bool) {
	if p == nil {
		return nil, {}, false
	}
	h := m.history
	if p.has_write && p.has_base {
		if t, err := history_text_at(h, p.write_inode, p.write[:], context.temp_allocator); err == .None && _content_hash(t) == p.base_hash {
			return _base_parents(m, actor, p.write_inode, p.write[:], p.base_hash), p.write_inode, true
		}
	}
	if p.has_read {
		if t, err := history_text_at(h, p.read_inode, p.read[:], context.temp_allocator); err == .None && _content_hash(t) == p.read_hash {
			return _base_parents(m, actor, p.read_inode, p.read[:], p.read_hash), p.read_inode, true
		}
	}
	return nil, {}, p.has_read || p.has_base
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
	if !lv_in_line(m, own) {
		return nil
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
		if c.moved != "" && c.old.ver != 0 && c.disk == .File && c.stat != c.old.stat {
			c.stat = c.old.stat
			k, _ := clone_string(c.path, p.long)
			append(&p.young, k)
		}
		pbuf: Pin
		pin, actor, observed := _change_pin(m, &c, &pbuf)
		if pin == nil {
			append(&keep, c)
			continue
		}
		if c.scope == nil && c.scope_id == {} {
			if a, ok := m.attrib[c.path]; ok && a.actor == actor {
				c.scope_id = a.scope
			}
		}
		if c.disk != .File || c.moved != "" || (c.kind != .Modify && c.kind != .Create) || (c.kind == .Modify && c.old.kind != .File) {
			_change_pin_drop(m, &c, observed)
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		v, inode, pinned := _base_version(m, pin, actor)
		if v != nil && (c.kind != .Modify || inode != c.old.inode) {
			if _, _, elsewhere, serr := shadow_by_inode(&m.shadow, inode, context.temp_allocator); serr != .None || elsewhere {
				v = nil
			}
		}
		fell := false
		if v == nil && pinned && c.kind == .Modify && c.old.ver != 0 {
			ebuf: Pin
			if ep, _, _ := _entry_pin(m, &c, &ebuf, actor); ep != nil {
				v, inode, _ = _base_version(m, ep, actor)
				fell = v != nil
			}
			if fell {
				_change_pin_drop(m, &c, observed)
				_base_note(m, c.path, .Mismatch)
			}
		}
		if v == nil {
			if pinned {
				_change_pin_drop(m, &c, observed)
				_base_note(m, c.path, .Mismatch)
			}
			append(&keep, c)
			continue
		}
		vl := make([dynamic]crdt.Lv, context.temp_allocator)
		sl := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, v, &vl) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
			_change_pin_drop(m, &c, observed)
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		if c.kind == .Modify && inode == c.old.inode && crdt.frontier_eq(vl[:], sl[:]) {
			_change_pin_drop(m, &c, observed)
			_base_note(m, c.path, .Current)
			append(&keep, c)
			continue
		}
		if _off_line(m, vl[:], sl[:]) {
			_change_pin_drop(m, &c, observed)
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		done, rerr := rebase_commit(p, &c, v, inode, actor)
		#partial switch rerr {
		case .None:
		case .Reloading, .Io, .No_Space:
			return rerr
		case:
			if fell {
				append(&keep, c)
				continue
			}
			_change_pin_drop(m, &c, observed)
			_base_note(m, c.path, .Mismatch)
			append(&keep, c)
			continue
		}
		if fell {
			if !done {
				append(&keep, c)
			}
			continue
		}
		_change_pin_drop(m, &c, observed)
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
_off_line :: proc(m: ^Mount, vl: []crdt.Lv, sl: []crdt.Lv) -> bool {
	h := m.history
	ll := make([dynamic]crdt.Lv, context.temp_allocator)
	if lv, found, lerr := history_line(h, m.line, context.temp_allocator); lerr == .None && found {
		if crdt.graph_version_lvs(&h.g, lv, &ll) != .None {
			return true
		}
	} else {
		append(&ll, ..sl)
	}
	for x in vl {
		if !crdt.graph_contains(&h.g, ll[:], x) {
			return true
		}
	}
	return false
}

@(private)
rebase_commit :: proc(p: ^Pass, c: ^Change, v: []crdt.Op_Id, inode: fstree.Inode_Id, actor: prim.Id) -> (done: bool, err: Error) {
	m := p.m
	h := m.history
	data, oid, binary, ok := read_content(m, c.path, c.stat, inode, true) or_return
	if !ok || binary || .Opaque in (tree_flags(h, inode) or_return) {
		return false, .None
	}
	old := history_text_at(h, inode, v, context.temp_allocator) or_return
	b: Builder
	builder_init(&b, h, actor)
	if c.scope != nil && c.scope.actor == actor {
		b.scope = scope_marker(actor, c.scope.id)
	} else if c.scope_id != {} {
		b.scope = scope_marker(actor, c.scope_id)
	}
	shadow_txn_begin(&m.shadow)
	err = copy_begin(m, c, data)
	if err == .None {
		err = emit_text_edits(m, &b, inode, c.path, old, data)
	}
	m.copy = nil
	if err == .None && c.has_copy {
		renamed_marker(h, &b, inode, c.copy_src)
	}
	ne := c.old if c.kind == .Modify && c.old.inode == inode else Entry{inode = inode, kind = .File}
	ne.stat = c.stat
	ne.oid = oid
	ne.ver = 0
	predicted: fstree.Op_Id
	if err == .None {
		if b.n == 0 {
			buf := make([dynamic]u8, context.temp_allocator)
			fshist.encode_observe(&buf, fshist.Observe_Op{kind = .Read, inode = inode_op(h, inode), path = c.path, version = v, hash = _content_hash(data)})
			builder_opaque(&b, buf[:])
		}
		if b.scope != nil {
			builder_opaque(&b, b.scope)
			b.scope = nil
		}
		predicted = op_inode(h, crdt.Op_Id{b.actor, b.seq0 + u64(b.n)})
		one := [1]fstree.Op_Id{predicted}
		ne.ver, err = shadow_version_add(&m.shadow, one[:])
	}
	if err == .None {
		err = shadow_put(&m.shadow, c.path, ne)
	}
	head: crdt.Op_Id
	has := false
	if err == .None {
		head, has, err = builder_commit_at(m, &b, v)
	}
	if (err == .None || err == .Reloading) && (!has || op_inode(h, head) != predicted) {
		err = .Corrupt
	}
	if err != .None && err != .Reloading {
		shadow_txn_rollback(&m.shadow)
		return false, err
	}
	shadow_txn_end(&m.shadow)
	based_scope := c.scope_id
	if c.scope != nil && c.scope.actor == actor {
		based_scope = c.scope.id
	}
	attrib_set(m, c.path, actor, true, {}, based_scope)
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
		lamport = max(history_lamport_after(h, m.synced[:]), history_lamport_after(h, parents)),
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
rebase_materialize :: proc(m: ^Mount, heads: []crdt.Op_Id, restored: bool) -> Error {
	if len(heads) == 0 && !restored {
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

@(private)
actor_on_line :: proc(m: ^Mount, actor: prim.Id) -> bool {
	h := m.history
	known := crdt.graph_known(&h.g, actor)
	if known == 0 {
		return true
	}
	own, ok := crdt.graph_lv(&h.g, crdt.Op_Id{actor, known - 1})
	if !ok {
		return true
	}
	return lv_in_line(m, own)
}

@(private)
lv_in_line :: proc(m: ^Mount, lv: crdt.Lv) -> bool {
	h := m.history
	ll := make([dynamic]crdt.Lv, context.temp_allocator)
	v, found, err := history_line(h, m.line, context.temp_allocator)
	if err != .None {
		return false
	}
	if !found {
		v = m.synced[:]
	}
	if crdt.graph_version_lvs(&h.g, v, &ll) != .None {
		return false
	}
	return crdt.graph_contains(&h.g, ll[:], lv)
}
