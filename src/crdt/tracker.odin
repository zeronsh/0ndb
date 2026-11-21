package crdt

import "base:runtime"
import "core:slice"

@(private)
PH :: 1 << 46
@(private)
ID_SPACE :: 1 << 62
@(private)
CUR :: 0
@(private)
END :: 1
@(private)
RAW :: 2
@(private)
ITEM_CAP :: 24

@(private)
Item :: struct {
	id:    int,
	len:   int,
	left:  int,
	right: int,
	state: u32,
	ever:  bool,
}

@(private)
Item_Leaf :: struct {
	parent: u32,
	slot:   u8,
	n:      u8,
	items:  [ITEM_CAP]Item,
}

@(private)
Items :: Tree(Item_Leaf, 3)

@(private)
Del_Rec :: struct {
	lv:     Lv,
	len:    int,
	target: int,
	back:   bool,
}

@(private)
Tracker :: struct {
	items:   Items,
	index:   Index,
	dels:    [2][dynamic]Del_Rec,
	version: [dynamic]Lv,
	tail:    int,
	ra:      [dynamic]Lv_Span,
	ad:      [dynamic]Lv_Span,
	pieces:  [dynamic]Piece,
}

@(private)
Cursor :: struct {
	leaf: u32,
	i:    int,
	off:  int,
}

@(private)
item_metrics :: #force_inline proc "contextless" (it: Item) -> [3]int {
	return {it.len if it.state == 1 else 0, 0 if it.ever else it.len, it.len}
}

@(private)
tracker_init :: proc(tr: ^Tracker, allocator: runtime.Allocator) {
	tr^ = {}
	tree_init(&tr.items, allocator)
	tree_init(&tr.index, allocator)
	leaf := tr.items.root
	l := &tr.items.leaves[leaf]
	l.items[0] = Item {
		id    = 0,
		len   = PH,
		left  = -1,
		right = -1,
		state = 1,
	}
	l.n = 1
	tree_add(&tr.items, leaf, {PH, PH, PH})
	run_insert(&tr.index, 0, Ix{PH, leaf})
	run_insert(&tr.index, PH, Ix{ID_SPACE - PH, NIL})
	tr.dels[0] = make([dynamic]Del_Rec, allocator)
	tr.dels[1] = make([dynamic]Del_Rec, allocator)
	tr.version = make([dynamic]Lv, allocator)
	tr.ra = make([dynamic]Lv_Span, allocator)
	tr.ad = make([dynamic]Lv_Span, allocator)
	tr.pieces = make([dynamic]Piece, allocator)
}

@(private)
tracker_destroy :: proc(tr: ^Tracker) {
	tree_destroy(&tr.items)
	tree_destroy(&tr.index)
	delete(tr.dels[0])
	delete(tr.dels[1])
	delete(tr.version)
	delete(tr.ra)
	delete(tr.ad)
	delete(tr.pieces)
	tr^ = {}
}

@(private)
tr_room :: proc(tr: ^Tracker, leaf: u32, i: int, need: int) -> (u32, int) {
	if int(tr.items.leaves[leaf].n) + need <= ITEM_CAP {
		return leaf, i
	}
	id := tree_new_leaf(&tr.items)
	l := &tr.items.leaves[leaf]
	r := &tr.items.leaves[id]
	h := int(l.n) / 2
	moved: [3]int
	for k in h ..< int(l.n) {
		r.items[k - h] = l.items[k]
		moved += item_metrics(l.items[k])
	}
	r.n = l.n - u8(h)
	l.n = u8(h)
	tree_add(&tr.items, leaf, -moved)
	tree_insert_after(&tr.items, leaf, true, id, moved)
	for k in 0 ..< int(tr.items.leaves[id].n) {
		it := tr.items.leaves[id].items[k]
		run_assign(&tr.index, it.id, Ix{it.len, id})
	}
	if i >= h {
		return id, i - h
	}
	return leaf, i
}

@(private)
tr_split_at :: proc(tr: ^Tracker, leaf: u32, i: int, off: int) -> (u32, int) {
	lf, li := tr_room(tr, leaf, i, 1)
	l := &tr.items.leaves[lf]
	it := l.items[li]
	n := int(l.n)
	copy(l.items[li + 2:n + 1], l.items[li + 1:n])
	l.items[li].len = off
	l.items[li + 1] = Item {
		id    = it.id + off,
		len   = it.len - off,
		left  = it.id + off - 1,
		right = it.right,
		state = it.state,
		ever  = it.ever,
	}
	l.n += 1
	return lf, li
}

@(private)
tr_locate :: proc(tr: ^Tracker, id: int) -> (leaf: u32, i: int, off: int, ok: bool) {
	e, _, found := run_get(&tr.index, id)
	if !found || e.leaf == NIL {
		return
	}
	l := &tr.items.leaves[e.leaf]
	for k in 0 ..< int(l.n) {
		it := l.items[k]
		if id >= it.id && id < it.id + it.len {
			return e.leaf, k, id - it.id, true
		}
	}
	return
}

@(private)
tr_raw_pos :: proc(tr: ^Tracker, id: int) -> int {
	leaf, i, off, ok := tr_locate(tr, id)
	if !ok {
		return -1
	}
	p := tree_leaf_pos(&tr.items, leaf)[RAW]
	l := &tr.items.leaves[leaf]
	for k in 0 ..< i {
		p += l.items[k].len
	}
	return p + off
}

@(private)
tr_end_pos :: proc(tr: ^Tracker, leaf: u32, i: int) -> int {
	p := tree_leaf_pos(&tr.items, leaf)[END]
	l := &tr.items.leaves[leaf]
	for k in 0 ..< i {
		if !l.items[k].ever {
			p += l.items[k].len
		}
	}
	return p
}

@(private)
cursor_norm :: proc(tr: ^Tracker, c: Cursor) -> Cursor {
	x := c
	for x.leaf != NIL {
		l := &tr.items.leaves[x.leaf]
		if x.i < int(l.n) {
			if x.off < l.items[x.i].len {
				return x
			}
			x.i += 1
			x.off = 0
			continue
		}
		x = Cursor{tree_next_leaf(&tr.items, x.leaf), 0, 0}
	}
	return x
}

@(private)
cursor_next :: proc(tr: ^Tracker, c: Cursor) -> Cursor {
	return cursor_norm(tr, Cursor{c.leaf, c.i + 1, 0})
}

@(private)
order_less :: proc(g: ^Graph, a, b: int) -> bool {
	ia := graph_id(g, a - PH)
	ib := graph_id(g, b - PH)
	return op_id_less(ia, ib)
}

@(private)
tr_insert :: proc(tr: ^Tracker, g: ^Graph, at: int, id: int, n: int) -> int {
	pos := clamp(at, 0, tr.items.total[CUR])
	left := -1
	c: Cursor
	if pos == 0 {
		c = Cursor{tree_first_leaf(&tr.items), 0, 0}
	} else {
		leaf, off := tree_find(&tr.items, CUR, pos - 1, false)
		l := &tr.items.leaves[leaf]
		i := 0
		for i < int(l.n) {
			cl := l.items[i].len if l.items[i].state == 1 else 0
			if off < cl {
				break
			}
			off -= cl
			i += 1
		}
		if i >= int(l.n) {
			return -1
		}
		left = l.items[i].id + off
		c = Cursor{leaf, i, off + 1}
	}
	c = cursor_norm(tr, c)
	scan := c
	right := -1
	for scan.leaf != NIL {
		it := tr.items.leaves[scan.leaf].items[scan.i]
		if it.state != 0 {
			right = it.id + scan.off
			break
		}
		scan = cursor_next(tr, scan)
	}
	dest := c
	if scan != c {
		left_pos := -1 if left < 0 else tr_raw_pos(tr, left)
		right_pos := tr.items.total[RAW] if right < 0 else tr_raw_pos(tr, right)
		scanning := false
		cc := c
		for {
			if !scanning {
				dest = cc
			}
			if cc.leaf == NIL || cc == scan {
				break
			}
			other := tr.items.leaves[cc.leaf].items[cc.i]
			ol := -1 if other.left < 0 else tr_raw_pos(tr, other.left)
			if ol < left_pos {
				break
			}
			if ol == left_pos {
				orp := tr.items.total[RAW] if other.right < 0 else tr_raw_pos(tr, other.right)
				if orp < right_pos {
					scanning = true
				} else if orp == right_pos {
					if order_less(g, id, other.id) {
						break
					}
					scanning = false
				} else {
					scanning = false
				}
			}
			cc = cursor_next(tr, cc)
		}
	}
	leaf: u32
	i: int
	if dest.leaf == NIL {
		leaf = tree_last_leaf(&tr.items)
		i = int(tr.items.leaves[leaf].n)
	} else if dest.off > 0 {
		leaf, i = tr_split_at(tr, dest.leaf, dest.i, dest.off)
		i += 1
	} else {
		leaf, i = dest.leaf, dest.i
	}
	ep := tr_end_pos(tr, leaf, i)
	if i > 0 {
		prev := &tr.items.leaves[leaf].items[i - 1]
		if prev.id + prev.len == id && left == id - 1 && prev.right == right && prev.state == 1 && !prev.ever {
			prev.len += n
			tree_add(&tr.items, leaf, {n, n, n})
			run_assign(&tr.index, id, Ix{n, leaf})
			return ep
		}
	}
	leaf, i = tr_room(tr, leaf, i, 1)
	l := &tr.items.leaves[leaf]
	cnt := int(l.n)
	copy(l.items[i + 1:cnt + 1], l.items[i:cnt])
	l.items[i] = Item {
		id    = id,
		len   = n,
		left  = left,
		right = right,
		state = 1,
	}
	l.n += 1
	tree_add(&tr.items, leaf, {n, n, n})
	run_assign(&tr.index, id, Ix{n, leaf})
	return ep
}

@(private)
tr_delete :: proc(tr: ^Tracker, pos: int, count: int, lv: Lv, back: bool, lv_hi: Lv, side: int, m: ^Merge) {
	start := len(tr.dels[side])
	done := 0
	for done < count {
		leaf, off := tree_find(&tr.items, CUR, pos, false)
		l := &tr.items.leaves[leaf]
		i := 0
		for i < int(l.n) {
			cl := l.items[i].len if l.items[i].state == 1 else 0
			if off < cl {
				break
			}
			off -= cl
			i += 1
		}
		if i >= int(l.n) {
			break
		}
		if off > 0 {
			leaf, i = tr_split_at(tr, leaf, i, off)
			i += 1
		}
		k := min(count - done, tr.items.leaves[leaf].items[i].len)
		if k < tr.items.leaves[leaf].items[i].len {
			leaf, i = tr_split_at(tr, leaf, i, k)
		}
		ep := -1
		if !tr.items.leaves[leaf].items[i].ever && m != nil {
			ep = tr_end_pos(tr, leaf, i)
		}
		it := &tr.items.leaves[leaf].items[i]
		before := item_metrics(it^)
		it.ever = true
		it.state += 1
		target := it.id
		tree_add(&tr.items, leaf, item_metrics(it^) - before)
		if ep >= 0 {
			doc_delete(m, ep, k)
		}
		if back {
			append(&tr.dels[side], Del_Rec{lv = lv_hi - done - k + 1, len = k, target = target + k - 1, back = true})
		} else {
			append(&tr.dels[side], Del_Rec{lv = lv + done, len = k, target = target, back = false})
		}
		done += k
	}
	if back {
		slice.reverse(tr.dels[side][start:])
	}
}

@(private)
tr_state :: proc(tr: ^Tracker, id: int, n: int, delta: int) {
	cur := id
	rem := n
	for rem > 0 {
		leaf, i, off, ok := tr_locate(tr, cur)
		if !ok {
			return
		}
		if off > 0 {
			leaf, i = tr_split_at(tr, leaf, i, off)
			i += 1
		}
		k := min(rem, tr.items.leaves[leaf].items[i].len)
		if k < tr.items.leaves[leaf].items[i].len {
			leaf, i = tr_split_at(tr, leaf, i, k)
		}
		it := &tr.items.leaves[leaf].items[i]
		before := item_metrics(it^)
		it.state = u32(max(int(it.state) + delta, 0))
		tree_add(&tr.items, leaf, item_metrics(it^) - before)
		cur += k
		rem -= k
	}
}

@(private)
rec_first :: proc "contextless" (recs: []Del_Rec, lv: Lv) -> int {
	lo, hi := 0, len(recs)
	for lo < hi {
		mid := (lo + hi) / 2
		if recs[mid].lv + recs[mid].len <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
tr_del_targets :: proc(tr: ^Tracker, a, b: Lv, delta: int) {
	for side in 0 ..< 2 {
		recs := tr.dels[side][:]
		for j := rec_first(recs, a); j < len(recs) && recs[j].lv < b; j += 1 {
			r := recs[j]
			x := max(a, r.lv)
			y := min(b, r.lv + r.len)
			if y <= x {
				continue
			}
			if r.back {
				hi := r.target - (x - r.lv)
				tr_state(tr, hi - (y - x) + 1, y - x, delta)
			} else {
				tr_state(tr, r.target + (x - r.lv), y - x, delta)
			}
		}
	}
}

@(private)
tr_move :: proc(tr: ^Tracker, g: ^Graph, log: ^Text_Log, to: []Lv) {
	if frontier_eq(tr.version[:], to) {
		return
	}
	graph_diff(g, tr.version[:], to, &tr.ra, &tr.ad)
	for pass in 0 ..< 2 {
		spans := tr.ra[:] if pass == 0 else tr.ad[:]
		delta := -1 if pass == 0 else 1
		clear(&tr.pieces)
		_ = log_pieces(log, spans, &tr.pieces)
		for p in tr.pieces {
			e := log.entries[p.entry]
			if e.kind == .Insert {
				tr_state(tr, PH + p.lv, p.len, delta)
			} else {
				tr_del_targets(tr, p.lv, p.lv + p.len, delta)
			}
		}
	}
	clear(&tr.version)
	append(&tr.version, ..to)
}
