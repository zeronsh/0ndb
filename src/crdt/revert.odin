package crdt

import "core:slice"

Revert_Class :: enum u8 {
	Base,
	In,
	Out,
}

Revert_Classes :: bit_set[Revert_Class;u8]

Revert_Classify :: #type proc(data: rawptr, lv: Lv) -> Revert_Class

Revert_Item :: struct {
	lv:      Lv,
	pos:     int,
	len:     int,
	visible: bool,
	ins:     Revert_Class,
	del:     Revert_Classes,
	out_lv:  Lv,
}

@(private = "file")
Del_Cut :: struct {
	lo:    i64,
	hi:    i64,
	class: Revert_Class,
	lv:    Lv,
}

@(private = "file")
Del_Seg :: struct {
	lo:     i64,
	hi:     i64,
	del:    Revert_Classes,
	out_lv: Lv,
}

text_revert_items :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, target: []Lv, classify: Revert_Classify, data: rawptr, common: ^[dynamic]Lv, out: ^[dynamic]Revert_Item) -> Error {
	if !graph_valid(g, target) || !graph_valid(g, t.version[:]) {
		return .Unknown
	}
	m := Merge {
		t      = t,
		g      = g,
		log    = log,
		target = target,
	}
	alloc := t.allocator
	spans := make([dynamic]Walk_Span, alloc)
	defer delete(spans)
	graph_conflicting(g, t.version[:], target, &spans, common)
	tr: Tracker
	heads := make([dynamic]Lv, alloc)
	defer delete(heads)
	walked := make([dynamic]Walked, alloc)
	defer delete(walked)
	if err := build_tracker(&m, &tr, &heads, &walked, target); err != .None {
		tracker_destroy(&tr)
		return err
	}
	defer tracker_destroy(&tr)
	only_a := make([dynamic]Lv_Span, alloc)
	defer delete(only_a)
	only_b := make([dynamic]Lv_Span, alloc)
	defer delete(only_b)
	graph_diff(g, t.version[:], target, &only_a, &only_b)
	pieces := make([dynamic]Piece, alloc)
	defer delete(pieces)
	log_pieces(log, only_b[:], &pieces) or_return
	for p in pieces {
		walk_piece(&m, &tr, &heads, p, 1, false)
	}
	tr_move(&tr, g, log, target)
	cuts := make([dynamic]Del_Cut, alloc)
	defer delete(cuts)
	for side in 0 ..< 2 {
		for r in tr.dels[side] {
			j: i64 = 0
			for j < r.len {
				c := classify(data, r.lv + Lv(j))
				k := j + 1
				for k < r.len && classify(data, r.lv + Lv(k)) == c {
					k += 1
				}
				if r.back {
					append(&cuts, Del_Cut{r.target - (k - 1), r.target - j + 1, c, r.lv + Lv(k - 1)})
				} else {
					append(&cuts, Del_Cut{r.target + j, r.target + k, c, r.lv + Lv(k - 1)})
				}
				j = k
			}
		}
	}
	segs := del_segments(cuts[:], alloc)
	defer delete(segs)
	for leaf := tree_first_leaf(&tr.items); leaf != NIL; leaf = tree_next_leaf(&tr.items, leaf) {
		l := &tr.items.leaves[leaf]
		for i in 0 ..< int(l.n) {
			it := l.items[i]
			ins := Revert_Class.Base
			if it.id >= PH {
				ins = classify(data, Lv(it.id - PH))
			}
			emit_split(out, it, ins, segs[:])
		}
	}
	return m.err
}

@(private = "file")
del_segments :: proc(cuts: []Del_Cut, alloc := context.allocator) -> [dynamic]Del_Seg {
	points := make([dynamic]i64, 0, 2 * len(cuts), alloc)
	defer delete(points)
	for c in cuts {
		append(&points, c.lo, c.hi)
	}
	slice.sort(points[:])
	segs := make([dynamic]Del_Seg, alloc)
	if len(points) == 0 {
		return segs
	}
	uniq := 1
	for i in 1 ..< len(points) {
		if points[i] != points[uniq - 1] {
			points[uniq] = points[i]
			uniq += 1
		}
	}
	resize(&points, uniq)
	for i in 0 ..< len(points) - 1 {
		append(&segs, Del_Seg{points[i], points[i + 1], {}, -1})
	}
	for c in cuts {
		lo, _ := slice.binary_search_by(segs[:], c.lo, proc(s: Del_Seg, x: i64) -> slice.Ordering {
			return slice.cmp(s.lo, x)
		})
		for j := lo; j < len(segs) && segs[j].lo < c.hi; j += 1 {
			segs[j].del += {c.class}
			if c.class == .Out {
				segs[j].out_lv = max(segs[j].out_lv, c.lv)
			}
		}
	}
	return segs
}

@(private = "file")
emit_split :: proc(out: ^[dynamic]Revert_Item, it: Item, ins: Revert_Class, segs: []Del_Seg) {
	lo := it.id
	hi := it.id + it.len
	j, _ := slice.binary_search_by(segs, lo, proc(s: Del_Seg, x: i64) -> slice.Ordering {
		if s.hi <= x {
			return .Less
		}
		if s.lo > x {
			return .Greater
		}
		return .Equal
	})
	cur := lo
	for cur < hi {
		del: Revert_Classes
		out_lv := Lv(-1)
		next := hi
		if j < len(segs) && segs[j].lo <= cur && cur < segs[j].hi {
			del = segs[j].del
			out_lv = segs[j].out_lv
			next = min(hi, segs[j].hi)
			j += 1
		} else if j < len(segs) && segs[j].lo > cur {
			next = min(hi, segs[j].lo)
		}
		push_item(out, it, ins, cur, next - cur, del, out_lv)
		cur = next
	}
}

@(private = "file")
push_item :: proc(out: ^[dynamic]Revert_Item, it: Item, ins: Revert_Class, id: i64, n: i64, del: Revert_Classes, out_lv: Lv) {
	x := Revert_Item {
		lv      = -1,
		len     = narrow(n),
		visible = it.state == 1,
		ins     = ins,
		del     = del,
		out_lv  = out_lv,
	}
	if id >= PH {
		x.lv = Lv(id - PH)
	} else {
		x.pos = narrow(id)
	}
	if k := len(out); k > 0 {
		p := &out[k - 1]
		if p.visible == x.visible && p.ins == x.ins && p.del == x.del && p.out_lv == x.out_lv {
			if x.lv >= 0 && p.lv >= 0 && p.lv + Lv(p.len) == x.lv {
				p.len += x.len
				return
			}
			if x.lv < 0 && p.lv < 0 && p.pos + p.len == x.pos {
				p.len += x.len
				return
			}
		}
	}
	append(out, x)
}
