package fs

import "core:slice"
import "../crdt"
import "../fshist"
import "../fstree"
import "../prim"

Own_Touch :: struct {
	exist: bool,
	place: bool,
	text:  bool,
	blob:  bool,
	flags: bool,
}

Own_View :: struct {
	h:       ^History,
	bl:      []crdt.Lv,
	cl:      []crdt.Lv,
	ctx:     Set_Ctx,
	touched: map[fstree.Inode_Id]Own_Touch,
}

own_view_open :: proc(h: ^History, base, current: Version, own: []prim.Id, allocator := context.temp_allocator) -> (v: Own_View, err: Error) {
	bl := make([dynamic]crdt.Lv, allocator)
	cl := make([dynamic]crdt.Lv, allocator)
	if crdt.graph_version_lvs(&h.g, base, &bl) != .None || crdt.graph_version_lvs(&h.g, current, &cl) != .None {
		return {}, .Not_Found
	}
	only_b := make([dynamic]crdt.Lv_Span, allocator)
	only_c := make([dynamic]crdt.Lv_Span, allocator)
	crdt.graph_diff(&h.g, bl[:], cl[:], &only_b, &only_c)
	slice.sort_by(only_c[:], proc(a, b: crdt.Lv_Span) -> bool {return a.lv < b.lv})
	v = Own_View {
		h  = h,
		bl = bl[:],
		cl = cl[:],
		ctx = Set_Ctx{h = h, after = only_c[:], set = make(map[u32]bool, allocator)},
		touched = make(map[fstree.Inode_Id]Own_Touch, allocator),
	}
	for a in own {
		if ix, known := h.g.actor_index[a]; known {
			v.ctx.set[ix] = true
		}
	}
	events := make(map[fstree.Inode_Id]^Inode_Events, context.temp_allocator)
	collect_revert_events(h, &v.ctx, &events) or_return
	for ino, ev in prim.unordered(events) {
		if ev.has_in == {} {
			continue
		}
		v.touched[ino] = Own_Touch {
			exist = .Exist in ev.has_in,
			place = .Place in ev.has_in,
			text  = .Text in ev.has_in,
			blob  = .Blob in ev.has_in,
			flags = .Flags in ev.has_in || .Target in ev.has_in,
		}
	}
	return v, .None
}

own_view_text :: proc(v: ^Own_View, ino: fstree.Inode_Id, allocator := context.temp_allocator) -> (data: []u8, spans: []crdt.Author_Span, err: Error) {
	h := v.h
	base, bspans := history_text_spans_at(h, ino, v.bl, context.temp_allocator) or_return
	cur, cspans := history_text_spans_at(h, ino, v.cl, context.temp_allocator) or_return
	tmp: File_State
	tmp.inode = ino
	defer {
		fshist.text_drop(&tmp.st)
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	read_file_record(h, ino, &tmp.rec) or_return
	load_text(h, &tmp, v.bl, true) or_return
	common := make([dynamic]crdt.Lv, context.temp_allocator)
	items := make([dynamic]crdt.Revert_Item, context.temp_allocator)
	if crdt.text_revert_items(&tmp.text, &h.g, &tmp.log, v.cl, set_classify, &v.ctx, &common, &items) != .None {
		return nil, nil, .Corrupt
	}
	ospans: []crdt.Author_Span
	if len(common) > 0 {
		_, ospans = history_text_spans_at(h, ino, common[:], context.temp_allocator) or_return
	}
	bidx := span_index(bspans)
	out := make([dynamic]u8, allocator)
	sp := make([dynamic]crdt.Author_Span, allocator)
	push :: proc(sp: ^[dynamic]crdt.Author_Span, s: crdt.Author_Span) {
		if s.len <= 0 {
			return
		}
		if k := len(sp); k > 0 {
			l := &sp[k - 1]
			if l.id.actor == s.id.actor && l.id.seq + u64(l.len) == s.id.seq && l.op.actor == s.op.actor && l.op.seq + u64(l.len) == s.op.seq && l.redacted == s.redacted {
				l.len += s.len
				return
			}
		}
		append(sp, s)
	}
	slice_spans :: proc(sp: ^[dynamic]crdt.Author_Span, src: []crdt.Author_Span, lo, hi: int) {
		at := 0
		for s in src {
			a := max(lo, at)
			b := min(hi, at + s.len)
			if b > a {
				d := u64(a - at)
				push(sp, crdt.Author_Span{id = {s.id.actor, s.id.seq + d}, op = {s.op.actor, s.op.seq + d}, len = b - a, redacted = s.redacted})
			}
			at += s.len
			if at >= hi {
				break
			}
		}
	}
	Run :: struct {
		op: crdt.Op_Id,
		n:  int,
	}
	runs := make([dynamic]Run, context.temp_allocator)
	at := 0
	for it in items {
		clear(&runs)
		if it.lv < 0 {
			o := 0
			for s in ospans {
				lo := max(it.pos, o)
				hi := min(it.pos + it.len, o + s.len)
				if hi > lo {
					append(&runs, Run{crdt.Op_Id{s.op.actor, s.op.seq + u64(lo - o)}, hi - lo})
				}
				o += s.len
				if o >= it.pos + it.len {
					break
				}
			}
		} else {
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
				append(&runs, Run{id, j - k})
				k = j
			}
		}
		class := crdt.Revert_Class.Base if it.lv < 0 else it.ins
		for r in runs {
			if it.visible {
				lo := min(at, len(cur))
				hi := min(at + r.n, len(cur))
				at += r.n
				if class != .Out {
					append(&out, ..cur[lo:hi])
					slice_spans(&sp, cspans, lo, hi)
				}
				continue
			}
			if class != .Base || .In in it.del || .Base in it.del {
				continue
			}
			for x in 0 ..< r.n {
				p := span_find(bidx, crdt.Op_Id{r.op.actor, r.op.seq + u64(x)})
				if p >= 0 && p < len(base) {
					append(&out, base[p])
					slice_spans(&sp, bspans, p, p + 1)
				}
			}
		}
	}
	return out[:], sp[:], .None
}
