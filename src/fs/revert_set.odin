package fs

import "core:mem/virtual"
import "core:slice"
import "core:strings"
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
	created:  bool,
	creator:  crdt.Revert_Class,
}

@(private)
Set_Ctx :: struct {
	h:     ^History,
	after: []crdt.Lv_Span,
	set:   map[u32]bool,
}

@(private)
Kept_Piece :: struct {
	src:    crdt.Op_Id,
	len:    int,
	pos:    int,
	vis:    bool,
	nl:     bool,
	in_b:   bool,
	in_t:   bool,
	out:    bool,
	outdel: bool,
	out_lv: crdt.Lv,
	b:      int,
	t:      int,
	text:   []u8,
}

@(private)
Kept_Line :: struct {
	first:   int,
	last:    int,
	len:     int,
	pair:    int,
	hunk:    int,
	anchor:  bool,
	shared:  bool,
	touched: bool,
	outdel:  bool,
}

@(private)
Kept_Hunk :: struct {
	t0, t1: int,
	b0, b1: int,
	frozen: bool,
}

@(private)
Kept_Edit :: struct {
	pos:  int,
	del:  int,
	ins:  int,
	hunk: int,
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

mount_revert_set :: proc(m: ^Mount, base: Version, actors: []prim.Id, undo: prim.Id = {}, owner: prim.Id = {}) -> (revert: prim.Id, err: Error) {
	mount_sync(m) or_return
	h := m.history
	revert = history_revert_set(h, m.line, base, m.synced[:], actors, undo, owner) or_return
	if revert == {} {
		return
	}
	if history_reloading(h) {
		m.reload_owed = true
		mount_reload_retry(m)
		return revert, .None
	}
	if merr := mount_materialize(m); merr != .Reloading {
		return revert, merr
	}
	m.reload_owed = true
	mount_reload_retry(m)
	return revert, .None
}

mount_unrevert :: proc(m: ^Mount, revert: prim.Id) -> (again: prim.Id, err: Error) {
	mount_wake(m) or_return
	before := revert_parents(m.history, revert, context.temp_allocator) or_return
	return mount_revert_set(m, before, []prim.Id{revert})
}

revert_parents :: proc(h: ^History, revert: prim.Id, allocator := context.allocator) -> (before: Version, err: Error) {
	history_ready(h) or_return
	lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{revert, 0})
	if !ok {
		return nil, .Not_Found
	}
	buf: [1]crdt.Lv
	ps := crdt.graph_parents(&h.g, lv, &buf)
	return crdt.graph_version_ids(&h.g, ps, allocator), .None
}

history_version_has :: proc(h: ^History, version: Version, actor: prim.Id) -> (has: bool, err: Error) {
	history_ready(h) or_return
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, version, &cl) != .None {
		return false, .Not_Found
	}
	return actor_bound(h, cl[:], actor) > 0, .None
}

history_undo_revert :: proc(h: ^History, current: Version, undo: prim.Id) -> (revert: prim.Id, found: bool, err: Error) {
	history_ready(h) or_return
	list, ok := kv_get(&h.kv, revert_key("ru:", undo), context.temp_allocator) or_return
	if !ok {
		return {}, false, .None
	}
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, current, &cl) != .None {
		return {}, false, .Not_Found
	}
	for i := 0; i + 16 <= len(list); i += 16 {
		id: prim.Id
		copy(id[:], list[i:][:16])
		if actor_bound(h, cl[:], id) > 0 {
			return id, true, .None
		}
	}
	return {}, false, .None
}

history_revert_set :: proc(h: ^History, line: string, base: Version, current: Version, actors: []prim.Id, undo: prim.Id = {}, owner: prim.Id = {}) -> (revert: prim.Id, err: Error) {
	history_ready(h) or_return
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return {}, .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, base, &bl) != .None || crdt.graph_version_lvs(&h.g, current, &cl) != .None {
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
	for ino, ev in prim.unordered(events) {
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
	pseudo := history_id_new(h)
	revert = fshist.ingestion_actor(h.self, pseudo)
	b: Builder
	builder_init(&b, h, revert)
	conflicts := make([dynamic]fshist.Revert_Conflict, context.temp_allocator)
	drops := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	revert_drops(h, touched, events, &snap_b, &snap_c, bl[:], cl[:], &ctx, &drops) or_return
	for ino in sorted_inodes(touched) {
		ev := events[ino]
		revert_inode(h, &b, ino, ev, &snap_b, &snap_c, bl[:], cl[:], &ctx, &conflicts, drops) or_return
		history_unload_files(h)
	}
	if b.n == 0 && len(conflicts) == 0 {
		return {}, .None
	}
	marker := make([dynamic]u8, context.temp_allocator)
	fshist.encode_revert(&marker, fshist.Revert_Op{base = base, actors = actors, conflicts = conflicts[:], undo = undo})
	builder_opaque(&b, marker[:])
	batch := crdt.Batch {
		actor   = b.actor,
		seq     = b.seq0,
		lamport = history_lamport_after(h, current),
		parents = current,
		ops     = b.ops[:],
	}
	history_register_owned_actor(h, revert, pseudo, owner) or_return
	if _, cerr := history_commit_local(h, &batch, line); cerr != .None {
		return {}, cerr
	}
	return revert, .None
}

history_mount_actors :: proc(h: ^History, mounts: []prim.Id, lines: []string, allocator := context.allocator) -> (out: []prim.Id, err: Error) {
	history_ready(h) or_return
	ids := make([dynamic]prim.Id, context.temp_allocator)
	for mid in mounts {
		append(&ids, mid)
		for l in lines {
			append(&ids, mount_line_pseudo(mid, l))
		}
	}
	list := make([dynamic]prim.Id, allocator)
	for a in h.g.actors {
		owner, ok := history_actor_owner(h, a)
		if !ok {
			continue
		}
		for id in ids {
			if fshist.ingestion_actor(owner, id) == a {
				append(&list, a)
				break
			}
		}
	}
	return list[:], .None
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
					ino := fstree.Inode_Id{crdt.graph_intern(&h.g, b.actor), seq}
					note(events, ino, .Exist, class, lamport)
					events[ino].created = true
					events[ino].creator = class
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
revert_drops :: proc(h: ^History, touched: map[fstree.Inode_Id]bool, events: map[fstree.Inode_Id]^Inode_Events, snap_b, snap_c: ^fstree.Snapshot, bl, cl: []crdt.Lv, ctx: ^Set_Ctx, drops: ^map[fstree.Inode_Id]bool) -> Error {
	dirs := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	for ino in sorted_inodes(touched) {
		ev := events[ino]
		ib, okb, e1 := fstree.info(snap_b, ino, context.temp_allocator)
		ic, okc, e2 := fstree.info(snap_c, ino, context.temp_allocator)
		if e1 != nil || e2 != nil {
			return .Corrupt
		}
		if okb && ib.present || !okc || !ic.present || !ev.last[.Exist].set || ev.last[.Exist].class != .In {
			continue
		}
		if ic.kind == .File && ev.out_body {
			stays := revert_stays(h, ino, ev, &ic, bl, cl, ctx) or_return
			history_unload_files(h)
			if stays {
				continue
			}
		}
		drops[ino] = true
		if ic.kind == .Dir {
			append(&dirs, ino)
		}
	}
	for again := true; again; {
		again = false
		for d in dirs {
			if d not_in drops {
				continue
			}
			kids, kerr := fstree.children(snap_c, d, allocator = context.temp_allocator)
			if kerr != nil {
				return .Corrupt
			}
			for k in kids {
				if k.inode not_in drops {
					delete_key(drops, d)
					again = true
					break
				}
			}
		}
	}
	return .None
}

@(private)
revert_inode :: proc(h: ^History, b: ^Builder, ino: fstree.Inode_Id, ev: ^Inode_Events, snap_b, snap_c: ^fstree.Snapshot, bl, cl: []crdt.Lv, ctx: ^Set_Ctx, conflicts: ^[dynamic]fshist.Revert_Conflict, drops: map[fstree.Inode_Id]bool) -> Error {
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
	if !pb && pc && last_in(ev, .Exist) && ino in drops {
		builder_tree(b, fstree.Op_Remove{inode = ino})
		return .None
	}
	if !pc && last_in(ev, .Exist) && (pb || (ev.created && ev.creator != .In)) {
		builder_tree(b, fstree.Op_Restore{inode = ino})
		if pb {
			if !okc || ic.parent != ib.parent || ic.name != ib.name {
				builder_tree(b, fstree.Op_Move{inode = ino, parent = ib.parent, name = ib.name})
			}
			ic = ib
		}
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
		revert_text(h, b, ino, bl, cl, ctx, conflicts) or_return
	}
	return .None
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
revert_text :: proc(h: ^History, b: ^Builder, ino: fstree.Inode_Id, bl, cl: []crdt.Lv, ctx: ^Set_Ctx, conflicts: ^[dynamic]fshist.Revert_Conflict, created := false) -> (empty: bool, err: Error) {
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
		return false, .Corrupt
	}
	cspans: []crdt.Author_Span
	if len(common) > 0 {
		_, cspans = history_text_spans_at(h, ino, common[:], context.temp_allocator) or_return
	}
	cur, _ := history_text_spans_at(h, ino, cl, context.temp_allocator) or_return
	ps := kept_pieces(h, items[:], cspans, cur)
	tl, blines, hunks := kept_lines(ps[:])
	edits := make([dynamic]Kept_Edit, context.temp_allocator)
	for round := 0; ; round += 1 {
		clear(&edits)
		kept_edits(ps[:], tl, blines, hunks, &edits)
		slice.stable_sort_by(edits[:], proc(x, y: Kept_Edit) -> bool {
			if x.pos != y.pos {
				return x.pos < y.pos
			}
			return x.del == 0 && y.del > 0
		})
		bad := kept_check(ps[:], cur, blines, edits[:])
		if bad < 0 || round > len(hunks) {
			break
		}
		hunks[bad].frozen = true
	}
	size := len(cur)
	for e in edits {
		size += ps[e.ins].len if e.ins >= 0 else -e.del
	}
	if size == 0 && created {
		return true, .None
	}
	kept_conflicts(h, ps[:], tl, blines, hunks, edits[:], ino, conflicts)
	#reverse for e in edits {
		if e.ins >= 0 {
			builder_copy_root(b, ino, e.pos, ps[e.ins].src, ps[e.ins].len)
		} else {
			builder_delete(b, ino, e.pos, e.del)
		}
	}
	return false, .None
}

@(private)
kept_pieces :: proc(h: ^History, items: []crdt.Revert_Item, cspans: []crdt.Author_Span, cur: []u8) -> [dynamic]Kept_Piece {
	out := make([dynamic]Kept_Piece, context.temp_allocator)
	total := 0
	for s in cspans {
		total += s.len
	}
	pos := 0
	push :: proc(h: ^History, out: ^[dynamic]Kept_Piece, it: crdt.Revert_Item, src: crdt.Op_Id, n: int, pos: ^int, cur: []u8) {
		p := Kept_Piece {
			vis    = it.visible,
			in_b   = it.ins == .Base && .Base not_in it.del,
			in_t   = it.ins == .Base && it.del & {.Base, .In} == {} || it.ins == .In && .In not_in it.del,
			out    = it.ins == .Out,
			outdel = .Out in it.del,
			out_lv = it.out_lv,
			b      = -1,
			t      = -1,
		}
		text: []u8
		if p.vis {
			text = cur[min(pos^, len(cur)):min(pos^ + n, len(cur))]
		} else if p.in_b || p.in_t {
			buf := make([]u8, n, context.temp_allocator)
			authors := make([dynamic]crdt.Author_Span, context.temp_allocator)
			got := copy_read_depth(h, src, buf, &authors, 0)
			text = buf[:got]
		} else {
			return
		}
		at := 0
		for at < n {
			e := at
			for e < n && !(e < len(text) && text[e] == '\n') {
				e += 1
			}
			p.nl = e < n
			e = min(e + 1, n)
			p.src = crdt.Op_Id{src.actor, src.seq + u64(at)}
			p.len = e - at
			p.pos = pos^ + (at if p.vis else 0)
			p.text = text[min(at, len(text)):min(e, len(text))]
			append(out, p)
			at = e
		}
		if p.vis {
			pos^ += n
		}
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
					push(h, &out, it, crdt.Op_Id{s.op.actor, s.op.seq + u64(slo - at)}, shi - slo, &pos, cur)
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
			push(h, &out, it, id, j - k, &pos, cur)
			k = j
		}
	}
	return out
}

@(private)
kept_lines :: proc(ps: []Kept_Piece) -> (tl: []Kept_Line, bl: []Kept_Line, hunks: []Kept_Hunk) {
	ts := make([dynamic]Kept_Line, context.temp_allocator)
	bs := make([dynamic]Kept_Line, context.temp_allocator)
	add :: proc(lines: ^[dynamic]Kept_Line, open: ^bool, i: int, p: Kept_Piece) -> int {
		if !open^ {
			append(lines, Kept_Line{first = i, pair = -1, hunk = -1})
			open^ = true
		}
		l := &lines[len(lines) - 1]
		l.last = i
		l.len += p.len
		if p.nl {
			open^ = false
		}
		return len(lines) - 1
	}
	topen, bopen := false, false
	for &p, i in ps {
		if p.in_t {
			p.t = add(&ts, &topen, i, p)
		}
		if p.in_b {
			p.b = add(&bs, &bopen, i, p)
			bs[p.b].outdel ||= !p.in_t && p.outdel
		}
	}
	for &l, t in ts {
		anchor := true
		bi := -1
		n := 0
		for i in l.first ..= l.last {
			p := ps[i]
			if p.t != t {
				if p.out && p.vis {
					l.touched = true
				}
				continue
			}
			if !p.vis {
				l.touched = true
			}
			if !p.in_b || bi >= 0 && p.b != bi {
				anchor = false
			} else {
				bi = p.b
				n += p.len
			}
		}
		if anchor && bi >= 0 && bs[bi].len == n && bs[bi].pair < 0 {
			l.anchor = true
			l.pair = bi
			bs[bi].anchor = true
			bs[bi].pair = t
		}
		for i := l.first - 1; i >= 0; i -= 1 {
			if ps[i].vis {
				l.touched ||= ps[i].out && !ps[i].nl
				break
			}
		}
		if !ps[l.last].nl {
			for i := l.last + 1; i < len(ps); i += 1 {
				if ps[i].vis {
					l.touched ||= ps[i].out
					break
				}
			}
		}
	}
	hs := make([dynamic]Kept_Hunk, context.temp_allocator)
	t0, b0 := 0, 0
	for t in 0 ..= len(ts) {
		if t < len(ts) && !ts[t].anchor {
			continue
		}
		b1 := ts[t].pair if t < len(ts) else len(bs)
		if t > t0 || b1 > b0 {
			append(&hs, Kept_Hunk{t0 = t0, t1 = t, b0 = b0, b1 = b1})
		}
		t0, b0 = t + 1, b1 + 1
	}
	for hk, k in hs {
		for t in hk.t0 ..< hk.t1 {
			ts[t].hunk = k
			l := &ts[t]
			for i in l.first ..= l.last {
				p := ps[i]
				if p.t == t && p.in_b && l.pair < 0 && bs[p.b].pair < 0 {
					l.pair, l.shared = p.b, true
					bs[p.b].pair, bs[p.b].shared = t, true
				}
			}
		}
		bi := hk.b0
		for t in hk.t0 ..< hk.t1 {
			if ts[t].pair >= 0 {
				bi = max(bi, ts[t].pair + 1)
				continue
			}
			limit := hk.b1
			for u in t + 1 ..< hk.t1 {
				if ts[u].pair >= 0 {
					limit = ts[u].pair
					break
				}
			}
			if bi < limit && bs[bi].pair < 0 {
				ts[t].pair = bi
				bs[bi].pair = t
				bi += 1
			}
		}
		for b in hk.b0 ..< hk.b1 {
			bs[b].hunk = k
		}
	}
	return ts[:], bs[:], hs[:]
}

@(private)
kept_owner :: proc(hk: Kept_Hunk, bl: []Kept_Line, b: int) -> int {
	for x := b; x >= hk.b0; x -= 1 {
		if bl[x].pair >= 0 {
			return bl[x].pair
		}
	}
	return hk.t0 if hk.t1 > hk.t0 else -1
}

@(private)
kept_restores :: proc(hk: Kept_Hunk, tl, bl: []Kept_Line, b: int) -> bool {
	if hk.frozen || bl[b].outdel {
		return false
	}
	t := kept_owner(hk, bl, b)
	return t < 0 || !tl[t].touched
}

@(private)
kept_end :: proc(p: Kept_Piece) -> int {
	return p.pos + (p.len if p.vis else 0)
}

@(private)
kept_edits :: proc(ps: []Kept_Piece, tl, bl: []Kept_Line, hunks: []Kept_Hunk, out: ^[dynamic]Kept_Edit) {
	for hk, k in hunks {
		if hk.frozen {
			continue
		}
		for t in hk.t0 ..< hk.t1 {
			l := tl[t]
			if l.touched {
				continue
			}
			keep := l.shared && kept_restores(hk, tl, bl, l.pair)
			for i in l.first ..= l.last {
				p := ps[i]
				if p.t == t && p.vis && !(keep && p.in_b && p.b == l.pair) {
					append(out, Kept_Edit{p.pos, p.len, -1, k})
				}
			}
		}
		for b in hk.b0 ..< hk.b1 {
			if !kept_restores(hk, tl, bl, b) {
				continue
			}
			l := bl[b]
			for i in l.first ..= l.last {
				p := ps[i]
				if p.b != b {
					continue
				}
				t := l.pair
				if t >= 0 && l.shared && p.in_t && p.t == t {
					continue
				}
				pos := p.pos
				switch {
				case t >= 0 && l.shared:
					if i < tl[t].first {
						pos = ps[tl[t].first].pos
					} else if i > tl[t].last {
						pos = kept_end(ps[tl[t].last])
					}
				case t >= 0:
					pos = ps[tl[t].first].pos
				case:
					if o := kept_owner(hk, bl, b); o >= 0 {
						pos = kept_end(ps[tl[o].last]) if b > hk.b0 && bl[b].pair < 0 && kept_has_pair(hk, bl, b) else ps[tl[o].first].pos
					}
				}
				append(out, Kept_Edit{pos, 0, i, k})
			}
		}
	}
}

@(private)
kept_has_pair :: proc(hk: Kept_Hunk, bl: []Kept_Line, b: int) -> bool {
	for x := b - 1; x >= hk.b0; x -= 1 {
		if bl[x].pair >= 0 {
			return true
		}
	}
	return false
}

@(private)
kept_check :: proc(ps: []Kept_Piece, cur: []u8, bl: []Kept_Line, edits: []Kept_Edit) -> int {
	known := make(map[string]bool, context.temp_allocator)
	rest := string(cur)
	for line in strings.split_lines_iterator(&rest) {
		known[line] = true
	}
	sb := make([dynamic]u8, context.temp_allocator)
	cb := -1
	for p in ps {
		if !p.in_b {
			continue
		}
		if p.b != cb {
			clear(&sb)
			cb = p.b
		}
		append(&sb, ..p.text)
		if len(sb) == bl[p.b].len {
			known[strings.clone(strings.trim_suffix(string(sb[:]), "\n"), context.temp_allocator)] = true
		}
	}
	line := make([dynamic]u8, context.temp_allocator)
	hunk := -1
	bad := -1
	feed :: proc(data: []u8, k: int, line: ^[dynamic]u8, hunk: ^int, bad: ^int, known: map[string]bool) {
		for c in data {
			if k >= 0 {
				hunk^ = k
			}
			if c != '\n' {
				append(line, c)
				continue
			}
			if string(line[:]) not_in known && hunk^ >= 0 && bad^ < 0 {
				bad^ = hunk^
			}
			clear(line)
			hunk^ = -1
		}
	}
	at := 0
	for e in edits {
		if e.pos > at {
			feed(cur[at:e.pos], -1, &line, &hunk, &bad, known)
			at = e.pos
		}
		if e.ins >= 0 {
			feed(ps[e.ins].text, e.hunk, &line, &hunk, &bad, known)
		} else {
			hunk = e.hunk
			at = max(at, e.pos + e.del)
		}
	}
	feed(cur[min(at, len(cur)):], -1, &line, &hunk, &bad, known)
	if len(line) > 0 && string(line[:]) not_in known && hunk >= 0 && bad < 0 {
		bad = hunk
	}
	return bad
}

@(private)
kept_conflicts :: proc(h: ^History, ps: []Kept_Piece, tl, bl: []Kept_Line, hunks: []Kept_Hunk, edits: []Kept_Edit, ino: fstree.Inode_Id, conflicts: ^[dynamic]fshist.Revert_Conflict) {
	shift :: proc(ps: []Kept_Piece, edits: []Kept_Edit, pos: int) -> int {
		d := 0
		for e in edits {
			if e.pos >= pos {
				break
			}
			d += ps[e.ins].len if e.ins >= 0 else -e.del
		}
		return pos + d
	}
	batch :: proc(h: ^History, lv: crdt.Lv) -> crdt.Lv {
		first, _, _, _, ok := history_batch_at(h, lv)
		return first if lv >= 0 && ok else -1
	}
	for hk in hunks {
		for t in hk.t0 ..< hk.t1 {
			l := tl[t]
			if !l.touched && !hk.frozen {
				continue
			}
			c := fshist.Revert_Conflict {
				kind  = .Region,
				inode = inode_op(h, ino),
			}
			ours := make([dynamic]crdt.Op_Span, context.temp_allocator)
			theirs := make([dynamic]crdt.Op_Span, context.temp_allocator)
			gone := make(map[crdt.Lv]bool, context.temp_allocator)
			for i in l.first ..= l.last {
				if ps[i].t == t && !ps[i].vis {
					if x := batch(h, ps[i].out_lv); x >= 0 {
						gone[x] = true
					}
				}
			}
			lo, hi := -1, -1
			for i in 0 ..< len(ps) {
				p := ps[i]
				if !p.vis {
					continue
				}
				mine := p.t == t
				if !mine && p.out {
					mine = i > l.first && i < l.last
					if !mine && len(gone) > 0 {
						if lv, ok := crdt.graph_lv(&h.g, p.src); ok {
							mine = batch(h, lv) in gone
						}
					}
				}
				if mine && (hi < 0 || p.pos == hi) {
					if lo < 0 {
						lo = p.pos
					}
					hi = p.pos + p.len
					push_op_span(&ours, p.src, p.len)
				}
			}
			if lo < 0 {
				lo = ps[l.first].pos
				hi = lo
			}
			c.start = shift(ps, edits, lo)
			c.end = c.start + (hi - lo)
			if l.pair >= 0 {
				for i in bl[l.pair].first ..= bl[l.pair].last {
					if ps[i].b == l.pair {
						push_op_span(&theirs, ps[i].src, ps[i].len)
					}
				}
			}
			c.ours = ours[:]
			c.theirs = theirs[:]
			append(conflicts, c)
		}
	}
}

@(private)
revert_stays :: proc(h: ^History, ino: fstree.Inode_Id, ev: ^Inode_Events, ic: ^fstree.Info, bl, cl: []crdt.Lv, ctx: ^Set_Ctx) -> (stays: bool, err: Error) {
	if .Opaque in ic.flags {
		return ev.last[.Blob].class != .In, .None
	}
	b: Builder
	builder_init(&b, h, h.self)
	conflicts := make([dynamic]fshist.Revert_Conflict, context.temp_allocator)
	empty := revert_text(h, &b, ino, bl, cl, ctx, &conflicts, true) or_return
	return !empty, .None
}

history_revert_op :: proc(h: ^History, revert: prim.Id, allocator := context.allocator) -> (op: fshist.Revert_Op, err: Error) {
	history_ready(h) or_return
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

@(private)
revert_accept_ops :: proc(h: ^History, c: Text_Conflict, version: []crdt.Op_Id, ops: ^[dynamic]crdt.Op_Run) -> Error {
	index, rc, found := revert_conflict_index(h, c) or_return
	if !found {
		return .Not_Found
	}
	if _, done := kv_get(&h.kv, revert_accept_key(c.revert, index), context.temp_allocator) or_return; done {
		return .Not_Found
	}
	target := inode_op(h, c.inode)
	opaque :: proc(ops: ^[dynamic]crdt.Op_Run, buf: []u8) {
		content := make([]u8, len(buf), context.temp_allocator)
		copy(content, buf)
		append(ops, crdt.Op_Run{kind = .Opaque, len = 1, content = content})
	}
	switch rc.kind {
	case .File:
		buf := make([dynamic]u8, context.temp_allocator)
		encode_tree_op(h, &buf, fstree.Op_Restore{inode = c.inode})
		opaque(ops, buf[:])
	case .Blob:
		buf := make([dynamic]u8, context.temp_allocator)
		encode_content_op(h, &buf, c.inode, c.oid, c.size)
		opaque(ops, buf[:])
	case .Region:
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, version, &lvs) != .None {
			return .Corrupt
		}
		data, spans := history_text_spans_at(h, c.inode, lvs[:], context.temp_allocator) or_return
		lo := min(c.start, len(data))
		hi := min(c.end, len(data))
		if len(rc.ours) > 0 {
			idx := span_index(spans)
			first := span_find(idx, rc.ours[0].id)
			if first >= 0 {
				n := 0
				for s in rc.ours {
					n += s.len
				}
				lo = first
				hi = min(first + n, len(data))
			}
		}
		if hi > lo {
			append(ops, crdt.Op_Run{target = target, kind = .Delete, pos = lo, len = hi - lo})
		}
		pos := lo
		for s in rc.theirs {
			if s.len <= 0 {
				continue
			}
			for a in copy_roots(h, s.id, s.len) {
				append(ops, crdt.Op_Run{target = target, kind = .Insert_Copy, pos = pos, len = a.len, src = a.op})
				pos += a.len
			}
		}
	}
	buf := make([dynamic]u8, context.temp_allocator)
	fshist.encode_accept(&buf, fshist.Accept_Op{kind = u8(Conflict_Kind.Revert), dest = target, revert = c.revert, index = index})
	opaque(ops, buf[:])
	return .None
}
