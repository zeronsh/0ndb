package fs

import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fshist"
import "../fstree"
import "../odb"
import "../prim"

@(private)
Revert_Field :: enum u8 {
	Exist,
	Place,
	Flags,
	Target,
	Blob,
	Text,
}

@(private)
Field_Last :: struct {
	set:     bool,
	class:   crdt.Revert_Class,
	lamport: u64,
}

@(private)
Inode_Events :: struct {
	last:     [Revert_Field]Field_Last,
	has_in:   bit_set[Revert_Field;u8],
	out_body: bool,
	first_in_blob: u64,
}

@(private)
Set_Ctx :: struct {
	h:     ^History,
	after: []crdt.Lv_Span,
	set:   map[u32]bool,
}

@(private)
Revert_Unit :: struct {
	src:     crdt.Op_Id,
	len:     int,
	pos:     int,
	visible: bool,
	ins:     crdt.Revert_Class,
	del:     crdt.Revert_Classes,
	out_lv:  crdt.Lv,
	line:    int,
	after:   bool,
}

@(private)
set_classify :: proc(data: rawptr, lv: crdt.Lv) -> crdt.Revert_Class {
	c := (^Set_Ctx)(data)
	lo, hi := 0, len(c.after)
	for lo < hi {
		mid := (lo + hi) / 2
		s := c.after[mid]
		if s.lv + crdt.Lv(s.len) <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= len(c.after) || c.after[lo].lv > lv {
		return .Base
	}
	actor, _ := crdt.graph_op(&c.h.g, lv)
	return .In if actor in c.set else .Out
}

mount_revert_set :: proc(m: ^Mount, base: Version, actors: []prim.Id) -> (revert: prim.Id, err: Error) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return {}, .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	mount_sync(m) or_return
	h := m.history
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, base, &bl) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &cl) != .None {
		return {}, .Not_Found
	}
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_c := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, bl[:], cl[:], &only_b, &only_c)
	slice.sort_by(only_c[:], proc(a, b: crdt.Lv_Span) -> bool {return a.lv < b.lv})
	ctx := Set_Ctx {
		h     = h,
		after = only_c[:],
		set   = make(map[u32]bool, context.temp_allocator),
	}
	for a in actors {
		if ix, known := h.g.actor_index[a]; known {
			ctx.set[ix] = true
		}
	}
	events := make(map[fstree.Inode_Id]^Inode_Events, context.temp_allocator)
	collect_revert_events(h, &ctx, &events) or_return
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	for ino, ev in events {
		if ev.has_in != {} {
			touched[ino] = true
		}
	}
	if len(touched) == 0 {
		return {}, .None
	}
	snap_b := version_snapshot(h, bl[:]) or_return
	defer fstree.snapshot_destroy(&snap_b)
	snap_c := version_snapshot(h, cl[:]) or_return
	defer fstree.snapshot_destroy(&snap_c)
	revert = history_id_new(h)
	b: Builder
	builder_init(&b, h, revert)
	conflicts := make([dynamic]fshist.Revert_Conflict, context.temp_allocator)
	for ino in sorted_inodes(touched) {
		ev := events[ino]
		revert_inode(h, &b, ino, ev, &snap_b, &snap_c, bl[:], cl[:], &ctx, &conflicts) or_return
		history_unload_files(h)
	}
	if b.n == 0 {
		return {}, .None
	}
	marker := make([dynamic]u8, context.temp_allocator)
	fshist.encode_revert(&marker, fshist.Revert_Op{base = base, actors = actors, conflicts = conflicts[:]})
	builder_opaque(&b, marker[:])
	before := make([]crdt.Op_Id, len(m.synced), context.temp_allocator)
	copy(before, m.synced[:])
	if cerr := builder_commit(m, &b); cerr != .None && cerr != .Reloading {
		return {}, cerr
	}
	clear(&m.synced)
	append(&m.synced, ..before)
	if merr := mount_materialize(m); merr != .Reloading {
		return revert, merr
	}
	m.reload_owed = true
	mount_reload_retry(m)
	return revert, .None
}

mount_unrevert :: proc(m: ^Mount, revert: prim.Id) -> (again: prim.Id, err: Error) {
	h := m.history
	mount_wake(m) or_return
	lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{revert, 0})
	if !ok {
		return {}, .Not_Found
	}
	buf: [1]crdt.Lv
	ps := crdt.graph_parents(&h.g, lv, &buf)
	before := crdt.graph_version_ids(&h.g, ps, context.temp_allocator)
	return mount_revert_set(m, before, []prim.Id{revert})
}

@(private)
collect_revert_events :: proc(h: ^History, ctx: ^Set_Ctx, events: ^map[fstree.Inode_Id]^Inode_Events) -> Error {
	note :: proc(events: ^map[fstree.Inode_Id]^Inode_Events, ino: fstree.Inode_Id, f: Revert_Field, class: crdt.Revert_Class, lamport: u64) {
		ev, ok := events[ino]
		if !ok {
			ev = new(Inode_Events, context.temp_allocator)
			events[ino] = ev
		}
		l := &ev.last[f]
		if !l.set || lamport >= l.lamport {
			l^ = Field_Last{true, class, lamport}
		}
		if class == .In {
			ev.has_in += {f}
			if f == .Blob && (ev.first_in_blob == 0 || lamport < ev.first_in_blob) {
				ev.first_in_blob = lamport
			}
		} else if f == .Text || f == .Blob {
			ev.out_body = true
		}
	}
	for span in ctx.after {
		lv := span.lv
		end := span.lv + crdt.Lv(span.len)
		for lv < end {
			first, n, stream, off, ok := history_batch_at(h, lv)
			if !ok {
				return .Corrupt
			}
			b, berr := history_read_batch(h, stream, off, context.temp_allocator)
			if berr == .Redacted {
				lv = first + n
				continue
			}
			if berr != .None {
				return berr
			}
			class := set_classify(ctx, first)
			at := first
			for op in b.ops {
				lo := at
				hi := at + crdt.Lv(op.len)
				at = hi
				if hi <= lv || lo >= end {
					continue
				}
				lamport := crdt.graph_lamport(&h.g, lo)
				if op.kind != .Opaque {
					note(events, op_inode(h, op.target), .Text, class, lamport)
					continue
				}
				if len(op.content) == 0 {
					continue
				}
				if op.content[0] == fshist.TOP_CREATE {
					_, seq := crdt.graph_op(&h.g, lo)
					note(events, fstree.Inode_Id{crdt.graph_intern(&h.g, b.actor), seq}, .Exist, class, lamport)
					continue
				}
				decoded, dok := fshist.decode_opaque(op.content, h, proc(data: rawptr, id: crdt.Op_Id) -> fstree.Inode_Id {
					return op_inode((^History)(data), id)
				})
				if !dok {
					continue
				}
				#partial switch o in decoded {
				case fshist.Content_Op:
					note(events, o.inode, .Blob, class, lamport)
				case fshist.Tree_Op:
					#partial switch t in o.op {
					case fstree.Op_Remove:
						note(events, t.inode, .Exist, class, lamport)
					case fstree.Op_Restore:
						note(events, t.inode, .Exist, class, lamport)
					case fstree.Op_Move:
						note(events, t.inode, .Place, class, lamport)
					case fstree.Op_Set_Flags:
						note(events, t.inode, .Flags, class, lamport)
					case fstree.Op_Set_Target:
						note(events, t.inode, .Target, class, lamport)
					}
				}
			}
			lv = first + n
		}
	}
	return .None
}

@(private)
revert_inode :: proc(h: ^History, b: ^Builder, ino: fstree.Inode_Id, ev: ^Inode_Events, snap_b, snap_c: ^fstree.Snapshot, bl, cl: []crdt.Lv, ctx: ^Set_Ctx, conflicts: ^[dynamic]fshist.Revert_Conflict) -> Error {
	ib, okb, e1 := fstree.info(snap_b, ino, context.temp_allocator)
	ic, okc, e2 := fstree.info(snap_c, ino, context.temp_allocator)
	if e1 != nil || e2 != nil {
		return .Corrupt
	}
	pb := okb && ib.present
	pc := okc && ic.present
	last_in :: proc(ev: ^Inode_Events, f: Revert_Field) -> bool {
		return ev.last[f].set && ev.last[f].class == .In
	}
	if !pb && pc && last_in(ev, .Exist) {
		if ev.out_body && ic.kind == .File {
			file_conflict(h, ino, &ic, cl, conflicts) or_return
		}
		builder_tree(b, fstree.Op_Remove{inode = ino})
		return .None
	}
	if pb && !pc {
		if !last_in(ev, .Exist) {
			return .None
		}
		builder_tree(b, fstree.Op_Restore{inode = ino})
		if !okc || ic.parent != ib.parent || ic.name != ib.name {
			builder_tree(b, fstree.Op_Move{inode = ino, parent = ib.parent, name = ib.name})
		}
		ic = ib
		okc = true
	} else if !pc {
		return .None
	} else {
		if pb && last_in(ev, .Place) && (ic.parent != ib.parent || ic.name != ib.name) {
			builder_tree(b, fstree.Op_Move{inode = ino, parent = ib.parent, name = ib.name})
		}
		if pb && last_in(ev, .Flags) && ic.flags != ib.flags {
			builder_tree(b, fstree.Op_Set_Flags{inode = ino, mask = fstree.ALL_FLAGS, value = ib.flags})
		}
		if pb && ib.kind == .Symlink && last_in(ev, .Target) && ic.target != ib.target {
			builder_tree(b, fstree.Op_Set_Target{inode = ino, target = ib.target})
		}
	}
	if ic.kind != .File {
		return .None
	}
	if .Opaque in ic.flags {
		return revert_blob(h, b, ino, ev, cl, conflicts)
	}
	if .Text in ev.has_in {
		return revert_text(h, b, ino, bl, cl, ctx, conflicts)
	}
	return .None
}

@(private)
op_spans_of :: proc(spans: []crdt.Author_Span) -> []crdt.Op_Span {
	out := make([dynamic]crdt.Op_Span, context.temp_allocator)
	for s in spans {
		push_op_span(&out, s.op, s.len)
	}
	return out[:]
}

@(private)
push_op_span :: proc(out: ^[dynamic]crdt.Op_Span, id: crdt.Op_Id, n: int) {
	if n <= 0 {
		return
	}
	if k := len(out); k > 0 {
		l := &out[k - 1]
		if l.id.actor == id.actor && l.id.seq + u64(l.len) == id.seq {
			l.len += n
			return
		}
	}
	append(out, crdt.Op_Span{id, n})
}

@(private)
file_conflict :: proc(h: ^History, ino: fstree.Inode_Id, ic: ^fstree.Info, cl: []crdt.Lv, conflicts: ^[dynamic]fshist.Revert_Conflict) -> Error {
	c := fshist.Revert_Conflict {
		inode = inode_op(h, ino),
	}
	if .Opaque in ic.flags {
		reg, has := history_blob_at(h, ino, cl) or_return
		if !has {
			return .None
		}
		c.kind = .Blob
		c.oid = reg.oid
		c.oid_len = u8(len(reg.oid))
		c.size = reg.size
	} else {
		data, spans := history_text_spans_at(h, ino, cl, context.temp_allocator) or_return
		c.kind = .File
		c.end = len(data)
		c.theirs = op_spans_of(spans)
	}
	append(conflicts, c)
	return .None
}

@(private)
revert_blob :: proc(h: ^History, b: ^Builder, ino: fstree.Inode_Id, ev: ^Inode_Events, cl: []crdt.Lv, conflicts: ^[dynamic]fshist.Revert_Conflict) -> Error {
	if .Blob not_in ev.has_in {
		return .None
	}
	cur, hc := history_blob_at(h, ino, cl) or_return
	if !hc {
		return .None
	}
	if ev.last[.Blob].class != .In {
		append(conflicts, fshist.Revert_Conflict{kind = .Blob, inode = inode_op(h, ino), oid = cur.oid, oid_len = u8(len(cur.oid)), size = cur.size})
		return .None
	}
	prev, found := blob_before(h, ino, ev.first_in_blob) or_return
	if !found || prev.oid == cur.oid {
		return .None
	}
	builder_content(b, ino, odb.Oid(prev.oid), prev.size)
	return .None
}

@(private)
blob_before :: proc(h: ^History, ino: fstree.Inode_Id, lamport: u64) -> (out: Blob_Reg, found: bool, err: Error) {
	data, _ := kv_get(&h.kv, inode_key("fb", ino), context.temp_allocator) or_return
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		e := read_blob_reg(&rd)
		if !prim.reader_ok(&rd) {
			return {}, false, .Corrupt
		}
		if e.lamport < lamport && (!found || blob_newer(e, out)) {
			out = e
			found = true
		}
	}
	return
}

@(private)
revert_text :: proc(h: ^History, b: ^Builder, ino: fstree.Inode_Id, bl, cl: []crdt.Lv, ctx: ^Set_Ctx, conflicts: ^[dynamic]fshist.Revert_Conflict) -> Error {
	tmp: File_State
	tmp.inode = ino
	defer {
		fshist.text_drop(&tmp.st)
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	read_file_record(h, ino, &tmp.rec) or_return
	load_text(h, &tmp, bl, true) or_return
	common := make([dynamic]crdt.Lv, context.temp_allocator)
	items := make([dynamic]crdt.Revert_Item, context.temp_allocator)
	if crdt.text_revert_items(&tmp.text, &h.g, &tmp.log, cl, set_classify, ctx, &common, &items) != .None {
		return .Corrupt
	}
	cspans: []crdt.Author_Span
	if len(common) > 0 {
		_, cspans = history_text_spans_at(h, ino, common[:], context.temp_allocator) or_return
	}
	cur, _ := history_text_spans_at(h, ino, cl, context.temp_allocator) or_return
	units := revert_units(h, items[:], cspans, cur)
	revert_regions(units, cur, ino, h, conflicts)
	edits := make([dynamic]Revert_Unit, context.temp_allocator)
	for u in units {
		if u.visible != u.after {
			append(&edits, u)
		}
	}
	#reverse for e in edits {
		if e.visible {
			builder_delete(b, ino, e.pos, e.len)
		} else {
			builder_copy(b, ino, e.pos, e.src, e.len)
		}
	}
	return .None
}

@(private)
revert_units :: proc(h: ^History, items: []crdt.Revert_Item, cspans: []crdt.Author_Span, cur: []u8) -> [dynamic]Revert_Unit {
	units := make([dynamic]Revert_Unit, context.temp_allocator)
	total := 0
	for s in cspans {
		total += s.len
	}
	pos := 0
	push :: proc(units: ^[dynamic]Revert_Unit, it: crdt.Revert_Item, src: crdt.Op_Id, n: int, pos: ^int, cur: []u8) {
		u := Revert_Unit{src = src, len = n, pos = pos^, visible = it.visible, ins = it.ins, del = it.del, out_lv = it.out_lv}
		if !u.visible {
			append(units, u)
			return
		}
		start := pos^
		for k in start ..< start + n {
			if k < len(cur) && cur[k] == '\n' {
				x := u
				x.pos = start
				x.len = k + 1 - start
				x.src = crdt.Op_Id{src.actor, src.seq + u64(start - pos^)}
				append(units, x)
				start = k + 1
			}
		}
		if start < pos^ + n {
			x := u
			x.pos = start
			x.len = pos^ + n - start
			x.src = crdt.Op_Id{src.actor, src.seq + u64(start - pos^)}
			append(units, x)
		}
		pos^ += n
	}
	for it in items {
		if it.lv < 0 {
			lo := it.pos
			hi := min(it.pos + it.len, total)
			at := 0
			for s in cspans {
				slo := max(lo, at)
				shi := min(hi, at + s.len)
				if shi > slo {
					push(&units, it, crdt.Op_Id{s.op.actor, s.op.seq + u64(slo - at)}, shi - slo, &pos, cur)
				}
				at += s.len
				if at >= hi {
					break
				}
			}
			continue
		}
		k := 0
		for k < it.len {
			id := crdt.graph_id(&h.g, it.lv + crdt.Lv(k))
			j := k + 1
			for j < it.len {
				nid := crdt.graph_id(&h.g, it.lv + crdt.Lv(j))
				if nid.actor != id.actor || nid.seq != id.seq + u64(j - k) {
					break
				}
				j += 1
			}
			push(&units, it, id, j - k, &pos, cur)
			k = j
		}
	}
	return units
}

@(private)
revert_regions :: proc(units: [dynamic]Revert_Unit, cur: []u8, ino: fstree.Inode_Id, h: ^History, conflicts: ^[dynamic]fshist.Revert_Conflict) {
	line := 0
	pending := false
	for &u in units {
		if u.visible {
			if pending {
				line += 1
				pending = false
			}
			if u.len > 0 && u.pos + u.len - 1 < len(cur) && cur[u.pos + u.len - 1] == '\n' {
				pending = true
			}
		}
		u.line = line
	}
	nl := line + 1
	region := make([]bool, nl, context.temp_allocator)
	out_vis := make([]bool, nl, context.temp_allocator)
	in_vis := make([]bool, nl, context.temp_allocator)
	batch_of := make([]crdt.Lv, len(units), context.temp_allocator)
	for u, i in units {
		batch_of[i] = -1
		if u.visible && u.ins == .Out {
			out_vis[u.line] = true
			if ulv, ok := crdt.graph_lv(&h.g, u.src); ok {
				if first, _, _, _, bok := history_batch_at(h, ulv); bok {
					batch_of[i] = first
				}
			}
		}
		if u.visible && u.ins == .In {
			in_vis[u.line] = true
		}
	}
	for l in 0 ..< nl {
		region[l] = out_vis[l] && in_vis[l]
	}
	del_batch :: proc(h: ^History, u: Revert_Unit) -> crdt.Lv {
		if u.out_lv < 0 {
			return -1
		}
		first, _, _, _, ok := history_batch_at(h, u.out_lv)
		return first if ok else -1
	}
	for u, i in units {
		if batch_of[i] < 0 || region[u.line] {
			continue
		}
		for dir in ([2]int{-1, 1}) {
			for j := i + dir; j >= 0 && j < len(units) && !units[j].visible; j += dir {
				t := units[j]
				if t.ins == .In && .Out in t.del && del_batch(h, t) == batch_of[i] {
					region[u.line] = true
				}
			}
		}
	}
	rewrites := make(map[crdt.Lv]bool, context.temp_allocator)
	for u, i in units {
		if batch_of[i] >= 0 && region[u.line] {
			rewrites[batch_of[i]] = true
		}
	}
	for &u in units {
		normal := u.ins != .In && .In in u.del && .Out not_in u.del && .Base not_in u.del
		if u.visible {
			u.after = u.ins == .Base if region[u.line] else u.ins != .In
		} else {
			u.after = normal || (u.ins == .Base && .Base not_in u.del && .Out in u.del && del_batch(h, u) in rewrites)
		}
	}
	result := 0
	i := 0
	for i < len(units) {
		u := units[i]
		if !region[u.line] {
			if u.after {
				result += u.len
			}
			i += 1
			continue
		}
		c := fshist.Revert_Conflict {
			kind  = .Region,
			inode = inode_op(h, ino),
			start = result,
		}
		ours := make([dynamic]crdt.Op_Span, context.temp_allocator)
		theirs := make([dynamic]crdt.Op_Span, context.temp_allocator)
		j := i
		for j < len(units) && units[j].line == u.line {
			x := units[j]
			if x.after {
				push_op_span(&ours, x.src, x.len)
				result += x.len
			}
			if x.visible {
				push_op_span(&theirs, x.src, x.len)
			}
			j += 1
		}
		c.end = result
		c.ours = ours[:]
		c.theirs = theirs[:]
		append(conflicts, c)
		i = j
	}
}

history_revert_op :: proc(h: ^History, revert: prim.Id, allocator := context.allocator) -> (op: fshist.Revert_Op, err: Error) {
	lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{revert, 0})
	if !ok {
		return {}, .Not_Found
	}
	_, _, stream, off, bok := history_batch_at(h, lv)
	if !bok {
		return {}, .Corrupt
	}
	b := history_read_batch(h, stream, off, context.temp_allocator) or_return
	#reverse for x in b.ops {
		if x.kind == .Opaque && len(x.content) > 0 && x.content[0] == fshist.TOP_REVERT {
			o, dok := fshist.decode_revert(x.content, allocator)
			if !dok {
				return {}, .Corrupt
			}
			return o, .None
		}
	}
	return {}, .Not_Found
}
