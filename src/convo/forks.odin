package convo

import "base:runtime"
import "../obj"
import "../prim"

Entry :: struct {
	parent:      Vref,
	child:       Vref,
	child_hlc:   prim.Hlc,
	leaf:        Vref,
	leaf_hlc:    prim.Hlc,
	leaf_by:     prim.Id,
	child_depth: i64,
	leaf_depth:  i64,
	virtual:     bool,
	branch:      int,
}

Branch :: struct {
	seg:     int,
	bseg:    int,
	bsegs:   []int,
	blocks:  []i64,
	covered: i64,
	first:   i64,
	packed:  []u8,
	nodes:   []Vref,
}

Assign_Entry :: struct {
	msg:    Vref,
	runner: prim.Id,
	hlc:    prim.Hlc,
	by:     prim.Id,
}

Mount_Entry :: struct {
	name:    string,
	tree:    prim.Id,
	line:    prim.Id,
	path:    string,
	stamp:   prim.Hlc,
	by:      prim.Id,
	removed: bool,
}

Structure :: struct {
	entries:    [dynamic]Entry,
	chains:     [dynamic]Entry,
	virtual:    []Entry,
	index:      map[[2]Vref]int,
	assigns:    [dynamic]Assign_Entry,
	superseded: [dynamic][2]Vref,
	landed:     [dynamic]Landed_Entry,
	mounts:     [dynamic]Mount_Entry,
	spines:     []Seg_Spine,
	branches:   ^[dynamic]Branch,
	nodes:      ^map[[2]i64]Spine_Nodes,
	floor:      prim.Hlc,
	alloc:      runtime.Allocator,
}

Seg_Spine :: struct {
	heads:  map[i64]Spine_Head,
	digest: Spine_Index,
	start:  i64,
	c:      i64,
	blocks: []i64,
	target: Vref,
	ready:  bool,
	tried:  int,
	seen:   i64,
}

Pos :: struct {
	at:  Vref,
	hlc: prim.Hlc,
	by:  prim.Id,
}

@(private)
Structure_Cache :: struct {
	arena: obj.Arena,
	ready: bool,
	ends:  [dynamic]i64,
	now:   [dynamic]i64,
	walks: [dynamic]obj.Walk,
	nodes: map[Vref]Node,
	seals: map[Vref]i64,
	st:    Structure,
}

@(private)
_cache :: proc(v: ^obj.View) -> (c: ^Structure_Cache, err: Error) {
	c = (^Structure_Cache)(v.cache)
	if c != nil {
		return c, .None
	}
	c = new(Structure_Cache, v.allocator)
	if c == nil {
		return nil, .No_Memory
	}
	c.ends = make([dynamic]i64, v.allocator)
	c.now = make([dynamic]i64, v.allocator)
	c.walks = make([dynamic]obj.Walk, v.allocator)
	c.nodes = make(map[Vref]Node, v.allocator)
	c.seals = make(map[Vref]i64, v.allocator)
	v.cache = c
	v.cache_free = proc(p: rawptr, allocator: runtime.Allocator) {
		c := (^Structure_Cache)(p)
		if c.ready {
			obj.arena_destroy(&c.arena)
		}
		delete(c.ends)
		delete(c.now)
		delete(c.walks)
		delete(c.nodes)
		delete(c.seals)
		free(c, allocator)
	}
	return c, .None
}

structure_load :: proc(v: ^obj.View, t: ^Tail, floor: prim.Hlc, st: ^Structure) -> Error {
	c := _cache(v) or_return
	obj.view_ends(v, &c.now)
	same := c.ready && len(c.now) == len(c.ends)
	for i in 0 ..< len(c.now) {
		same &&= c.now[i] == c.ends[i]
	}
	if !same {
		if c.ready {
			obj.arena_destroy(&c.arena)
			c.ready = false
		}
		if obj.arena_init(&c.arena) != nil {
			return .No_Memory
		}
		c.ready = true
		a := obj.arena_allocator(&c.arena)
		c.st = {
			entries    = make([dynamic]Entry, a),
			chains     = make([dynamic]Entry, a),
			index      = make(map[[2]Vref]int, a),
			assigns    = make([dynamic]Assign_Entry, a),
			superseded = make([dynamic][2]Vref, a),
			landed     = make([dynamic]Landed_Entry, a),
			mounts     = make([dynamic]Mount_Entry, a),
			spines     = make([]Seg_Spine, len(v.segs), a),
			branches   = new([dynamic]Branch, a),
			nodes      = new(map[[2]i64]Spine_Nodes, a),
			floor      = max(prim.Hlc),
			alloc      = a,
		}
		c.st.nodes^ = make(map[[2]i64]Spine_Nodes, a)
		c.st.branches^ = make([dynamic]Branch, a)
		for &sp in c.st.spines {
			sp.heads = make(map[i64]Spine_Head, a)
			sp.tried = -1
		}
		clear(&c.walks)
		resize(&c.walks, len(v.segs))
		for &w in c.walks {
			w = {}
		}
		clear(&c.ends)
		append(&c.ends, ..c.now[:])
	}
	if c.st.floor > floor {
		a := obj.arena_allocator(&c.arena)
		missing := false
		for s in 0 ..< len(v.segs) {
			w := &c.walks[s]
			if !w.started {
				sum, ok := _tail(v, s) or_return
				if ok && sum.digest != 0 {
					w.base = sum.digest
					w.base_len = sum.digest_len
					w.base_hlc = sum.digest_hlc
					if sum.base != sum.digest && sum.base != 0 {
						w.extra = {sum.base, sum.base + max(sum.base_len, obj.MSG_GUESS)}
					}
				}
			}
			e := _load_chain(v, s, w, floor, &c.st, a)
			if e == .Missing {
				missing = true
			} else if e != .None {
				obj.arena_destroy(&c.arena)
				c.ready = false
				return e
			}
		}
		if missing {
			return .Missing
		}
		c.st.floor = floor
		done := true
		for w in c.walks {
			done &&= w.done
		}
		if done {
			c.st.floor = 0
		}
	}
	st^ = c.st
	st.virtual = t.virtual[:] if t != nil else nil
	return .None
}

chains :: proc(st: ^Structure, allocator := context.temp_allocator) -> []Entry {
	if len(st.virtual) == 0 {
		return st.chains[:]
	}
	out := make([]Entry, len(st.chains) + len(st.virtual), allocator)
	copy(out, st.chains[:])
	copy(out[len(st.chains):], st.virtual)
	return out
}

entry_find :: proc(st: ^Structure, parent, child: Vref) -> (Entry, bool) {
	if i, ok := st.index[{parent, child}]; ok {
		return st.entries[i], true
	}
	return {}, false
}

assignee_of :: proc(st: ^Structure, msg: Vref, initial: prim.Id) -> prim.Id {
	r, _ := assign_winner(st, msg, initial, 0)
	return r
}

assign_winner :: proc(st: ^Structure, msg: Vref, initial: prim.Id, initial_hlc: prim.Hlc) -> (runner: prim.Id, hlc: prim.Hlc) {
	best: Assign_Entry
	found := false
	for a in st.assigns {
		if a.msg != msg {
			continue
		}
		if !found || a.hlc > best.hlc || (a.hlc == best.hlc && obj.id_less(best.by, a.by)) {
			best = a
			found = true
		}
	}
	if found {
		return best.runner, best.hlc
	}
	return initial, initial_hlc
}

mount_set :: proc(st: ^Structure, allocator := context.allocator) -> []Mount_Entry {
	out := make([dynamic]Mount_Entry, allocator)
	for m in st.mounts {
		k := -1
		for o, i in out {
			if o.name == m.name {
				k = i
				break
			}
		}
		if k < 0 {
			append(&out, m)
			continue
		}
		o := out[k]
		if m.stamp > o.stamp || (m.stamp == o.stamp && obj.id_less(o.by, m.by)) {
			out[k] = m
		}
	}
	n := 0
	for m in out {
		if !m.removed {
			out[n] = m
			n += 1
		}
	}
	resize(&out, n)
	return out[:]
}

is_superseded :: proc(st: ^Structure, claim: Vref) -> bool {
	for s in st.superseded {
		if s[0] == claim {
			return true
		}
	}
	return false
}

Landed_Entry :: struct {
	run:     Vref,
	outcome: Seal_Status,
}

is_landed :: proc(st: ^Structure, claim: Vref) -> (landed: bool, outcome: Seal_Status) {
	for l in st.landed {
		if l.run == claim {
			landed = true
			outcome = max(outcome, l.outcome)
		}
	}
	return
}

sort_children :: proc(list: []Entry, v: ^obj.View) {
	for i in 1 ..< len(list) {
		j := i
		for j > 0 && _child_less(v, list[j], list[j - 1]) {
			list[j], list[j - 1] = list[j - 1], list[j]
			j -= 1
		}
	}
}

chain_at :: proc(v: ^obj.View, st: ^Structure, e: Entry, d: i64) -> (at: Vref, err: Error) {
	switch {
	case d <= 0 || d < e.child_depth - 1 || d > e.leaf_depth:
		return {}, .None
	case d == e.child_depth - 1:
		return e.parent, .None
	case d == e.child_depth && !obj.vref_none(e.child):
		return e.child, .None
	case d == e.leaf_depth:
		return e.leaf, .None
	}
	if st != nil {
		if x, ok := _branch_node(v, st, e, d) or_return; ok {
			return x, .None
		}
		for s in 0 ..< len(st.spines) {
			sp := _spine_get(v, st, s) or_return
			if sp == nil || !sp.ready || d > sp.c {
				continue
			}
			on := e.leaf == sp.target
			if !on && e.leaf_depth <= sp.c {
				x, ok := _spine_node(v, st, s, e.leaf_depth) or_return
				on = ok && x == e.leaf
			}
			if on {
				x, ok := _spine_node(v, st, s, d) or_return
				if ok {
					return x, .None
				}
			}
		}
	}
	n := level_ancestor(v, e.leaf, d) or_return
	return n.ref, .None
}

@(private)
_child_less :: proc(v: ^obj.View, a, b: Entry) -> bool {
	if a.child_hlc != b.child_hlc {
		return a.child_hlc < b.child_hlc
	}
	return obj.vref_less(v, a.child, b.child)
}

@(private)
_add_entry :: proc(st: ^Structure, e: Entry) {
	if !obj.vref_none(e.leaf) {
		append(&st.chains, e)
	}
	if obj.vref_none(e.child) {
		return
	}
	key := [2]Vref{e.parent, e.child}
	if i, ok := st.index[key]; ok {
		cur := &st.entries[i]
		if cur.child_hlc == 0 {
			cur.child_hlc = e.child_hlc
		}
		return
	}
	st.index[key] = len(st.entries)
	append(&st.entries, Entry{parent = e.parent, child = e.child, child_hlc = e.child_hlc})
}

@(private)
Chain_Ctx :: struct {
	st:    ^Structure,
	v:     ^obj.View,
	by:    prim.Id,
	floor: prim.Hlc,
	alloc: runtime.Allocator,
}

@(private)
_load_chain :: proc(v: ^obj.View, s: int, w: ^obj.Walk, floor: prim.Hlc, st: ^Structure, alloc: runtime.Allocator) -> Error {
	ctx := Chain_Ctx{st, v, v.segs[s].id, floor, alloc}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		c := (^Chain_Ctx)(data)
		st := c.st
		mark := [6]int{len(st.entries), len(st.chains), len(st.assigns), len(st.superseded), len(st.landed), len(st.mounts)}
		stop, err = _visit_structure(c, s, off, env)
		if err != .None {
			for i in mark[0] ..< len(st.entries) {
				delete_key(&st.index, [2]Vref{st.entries[i].parent, st.entries[i].child})
			}
			resize(&st.entries, mark[0])
			resize(&st.chains, mark[1])
			resize(&st.assigns, mark[2])
			resize(&st.superseded, mark[3])
			resize(&st.landed, mark[4])
			resize(&st.mounts, mark[5])
		}
		return
	}
	return obj.walk_resume(v, s, w, floor, &ctx, visit)
}

@(private)
_visit_structure :: proc(c: ^Chain_Ctx, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
	v := c.v
	if env.kind < obj.RECORD_KIND_FIRST {
		return false, .None
	}
	rec := decode_env(env, v.scratch) or_return
	#partial switch r in rec.body {
	case Spine:
		c.st.spines[s].heads[off] = Spine_Head{r.prev, r.c, r.first}
	case Forks:
		if r.base != 0 && c.floor > r.base_hlc {
			return false, .None
		}
		_add_digest(c, s, r) or_return
		full: Forks
		if r.base != 0 {
			raw, _ := obj.get(v, s, r.base, -1, r.base + r.base_len) or_return
			body := obj.clone_bytes(raw, v.scratch) or_return
			br := decode_record(body, r.base, v.scratch) or_return
			ok: bool
			full, ok = br.body.(Forks)
			if !ok || full.base != 0 {
				return false, .Corrupt
			}
			_add_digest(c, s, full) or_return
		}
		sp := &c.st.spines[s]
		sp.digest = Spine_Index{at = r.spine.at, c = r.spine.c}
		blocks, be := make([]i64, r.spine.c / SPINE_SPAN, c.alloc)
		if be != nil {
			return false, .No_Memory
		}
		for k in 0 ..< len(blocks) {
			j := i64(k) - r.spine.first
			if j >= 0 && j < i64(len(r.spine.blocks)) {
				blocks[k] = r.spine.blocks[j]
			} else if j < 0 && k < len(full.spine.blocks) && full.spine.first == 0 {
				blocks[k] = full.spine.blocks[k]
			}
		}
		sp.digest.blocks = blocks
		return true, .None
	case Fork:
		en := Entry{
			child_hlc = r.child_hlc,
		}
		en.parent = obj.resolve(v, s, r.parent) or_return
		en.child = obj.resolve(v, s, r.child) or_return
		_add_entry(c.st, en)
	case Remember:
		_add_remember(v, s, c.st, r, c.by) or_return
	case Assign:
		m := obj.resolve(v, s, r.msg) or_return
		append(&c.st.assigns, Assign_Entry{m, r.runner, r.hlc, c.by})
	case Superseded:
		run := obj.resolve(v, s, r.run) or_return
		by := obj.resolve(v, s, r.by) or_return
		append(&c.st.superseded, [2]Vref{run, by})
	case Landed:
		run := obj.resolve(v, s, r.run) or_return
		append(&c.st.landed, Landed_Entry{run, r.outcome})
	case Mount:
		name := obj.clone_str(r.name, c.alloc) or_return
		path := obj.clone_str(r.path, c.alloc) or_return
		append(&c.st.mounts, Mount_Entry{name, r.tree, r.line, path, rec.stamp, c.by, false})
	case Unmount:
		name := obj.clone_str(r.name, c.alloc) or_return
		append(&c.st.mounts, Mount_Entry{name = name, stamp = rec.stamp, by = c.by, removed = true})
	}
	return false, .None
}

@(private)
_add_remember :: proc(v: ^obj.View, s: int, st: ^Structure, d: Remember, by: prim.Id) -> Error {
	en := Entry{
		child_hlc   = d.child_hlc,
		leaf_hlc    = d.leaf_hlc,
		leaf_by     = by,
		child_depth = d.child_depth,
		leaf_depth  = d.leaf_depth,
	}
	en.parent = obj.resolve(v, s, d.parent) or_return
	en.child = obj.resolve(v, s, d.child) or_return
	en.leaf = obj.resolve(v, s, d.leaf) or_return
	if (len(d.branch) > 0 || len(d.blocks) > 0) && st.branches != nil {
		b := Branch{
			seg     = s,
			bseg    = -1,
			covered = d.covered,
			first   = (d.covered if len(d.blocks) > 0 else d.child_depth) + 1,
		}
		if len(d.blocks) > 0 {
			bs := obj.resolve(v, s, Ref{d.bseg, d.blocks[0]}) or_return
			b.bseg = bs.seg
			segs, se := make([]int, len(d.blocks), st.alloc)
			if se != nil {
				return .No_Memory
			}
			for i in 0 ..< len(segs) {
				if len(d.bsegs) > 0 {
					x := obj.resolve(v, s, Ref{d.bsegs[i], d.blocks[i]}) or_return
					segs[i] = x.seg
				} else {
					segs[i] = bs.seg
				}
			}
			b.bsegs = segs
			list, e := make([]i64, len(d.blocks), st.alloc)
			if e != nil {
				return .No_Memory
			}
			copy(list, d.blocks)
			b.blocks = list
		}
		b.packed = obj.clone_bytes(d.branch, st.alloc) or_return
		append(st.branches, b)
		en.branch = len(st.branches)
	}
	_add_entry(st, en)
	return .None
}

@(private)
_branch_node :: proc(v: ^obj.View, st: ^Structure, e: Entry, d: i64) -> (at: Vref, ok: bool, err: Error) {
	if e.branch <= 0 || st.branches == nil || e.branch > len(st.branches) || d <= e.child_depth || d >= e.leaf_depth {
		return {}, false, .None
	}
	b := &st.branches[e.branch - 1]
	if d <= b.covered {
		k := (d - 1) / SPINE_SPAN - e.child_depth / SPINE_SPAN
		if k < 0 || k >= i64(len(b.blocks)) || b.bseg < 0 {
			return {}, false, .None
		}
		return _record_node(v, st, b.bsegs[k], b.blocks[k], d)
	}
	if b.nodes == nil {
		n := int(e.leaf_depth - b.first)
		refs, rok := spine_decode(b.packed, n, v.scratch)
		if !rok {
			return {}, false, .Corrupt
		}
		list := make([]Vref, n, st.alloc)
		for r, i in refs {
			list[i] = obj.resolve(v, b.seg, r) or_return
		}
		b.nodes = list
	}
	i := d - b.first
	if i < 0 || i >= i64(len(b.nodes)) {
		return {}, false, .Corrupt
	}
	return b.nodes[i], true, .None
}

@(private)
_virtual :: proc(v: ^obj.View, t: ^Tail) -> Error {
	clear(&t.tips)
	for s in 0 ..< len(v.segs) {
		sum, ok := _tail(v, s) or_return
		if !ok {
			continue
		}
		id := v.segs[s].id
		if sum.tip != 0 {
			append(&t.tips, Pos{Vref{s, sum.tip}, sum.tip_hlc, id})
		}
		if !obj.ref_none(sum.leaf) && sum.leaf_hlc > sum.tip_hlc {
			x := obj.resolve(v, s, sum.leaf) or_return
			append(&t.tips, Pos{x, sum.leaf_hlc, id})
		}
	}
	missing := false
	for p in t.tips {
		n, e := _node(v, p.at)
		if e == .Missing {
			missing = true
			continue
		}
		if e != .None {
			return e
		}
		_add_virtual(t, Entry{leaf = p.at, leaf_hlc = p.hlc, leaf_by = p.by, child_depth = 1, leaf_depth = n.depth, virtual = true})
	}
	if missing {
		return .Missing
	}
	return .None
}

@(private)
_add_virtual :: proc(t: ^Tail, e: Entry) {
	for &o in t.virtual {
		if o.leaf == e.leaf {
			if e.leaf_hlc > o.leaf_hlc || (e.leaf_hlc == o.leaf_hlc && obj.id_less(o.leaf_by, e.leaf_by)) {
				o.leaf_hlc = e.leaf_hlc
				o.leaf_by = e.leaf_by
			}
			return
		}
	}
	append(&t.virtual, e)
}

Spine_Head :: struct {
	prev:  i64,
	c:     i64,
	first: i64,
}

spine_resolve :: proc(heads: map[i64]Spine_Head, start: i64, digest: ^Spine_Index, allocator: runtime.Allocator) -> (c: i64, blocks: []i64, low: i64, complete: bool) {
	switch {
	case start == 0:
		return 0, nil, 0, true
	case digest != nil && start == digest.at:
		c = digest.c
	case:
		h, ok := heads[start]
		if !ok {
			return 0, nil, 0, false
		}
		c = h.c
	}
	blocks = make([]i64, c / SPINE_SPAN, allocator)
	low = c / SPINE_SPAN
	limit := c
	cur := start
	for cur != 0 {
		if digest != nil && cur == digest.at {
			limit = min(limit, digest.c)
			for k := digest.first; k < limit / SPINE_SPAN; k += 1 {
				if blocks[k] == 0 && k - digest.first < i64(len(digest.blocks)) {
					blocks[k] = digest.blocks[k - digest.first]
				}
			}
			return c, blocks, low, true
		}
		h, ok := heads[cur]
		if !ok {
			return c, blocks, low, false
		}
		limit = min(limit, h.c)
		for k := h.first; k < limit / SPINE_SPAN; k += 1 {
			if blocks[k] == 0 {
				blocks[k] = cur
				low = min(low, k)
			}
		}
		if h.prev >= cur {
			return c, blocks, low, false
		}
		cur = h.prev
	}
	for x in blocks[:limit / SPINE_SPAN] {
		if x == 0 {
			return c, blocks, low, false
		}
	}
	return c, blocks, low, true
}

@(private)
_spine_get :: proc(v: ^obj.View, st: ^Structure, s: int) -> (sp: ^Seg_Spine, err: Error) {
	if st.spines == nil || s >= len(st.spines) {
		return nil, .None
	}
	sp = &st.spines[s]
	if sp.ready || (sp.tried == len(sp.heads) && sp.seen == sp.digest.at) {
		return sp, .None
	}
	sp.tried = len(sp.heads)
	sp.seen = sp.digest.at
	sum, ok := _tail(v, s) or_return
	if !ok || sum.spine == 0 {
		return sp, .None
	}
	sp.start = sum.spine
	if !obj.ref_none(sum.leaf) && sum.leaf_hlc > sum.tip_hlc {
		sp.target = obj.resolve(v, s, sum.leaf) or_return
	} else if sum.tip != 0 {
		sp.target = Vref{s, sum.tip}
	}
	dg := &sp.digest if sp.digest.at != 0 || sp.digest.c != 0 else nil
	c, blocks, _, complete := spine_resolve(sp.heads, sum.spine, dg, st.alloc)
	sp.c = c
	sp.blocks = blocks
	sp.ready = complete
	return sp, .None
}

@(private)
_spine_node :: proc(v: ^obj.View, st: ^Structure, s: int, d: i64) -> (at: Vref, ok: bool, err: Error) {
	sp := _spine_get(v, st, s) or_return
	if sp == nil || !sp.ready || d < 1 || d > sp.c {
		return {}, false, .None
	}
	rec := sp.blocks[(d - 1) / SPINE_SPAN]
	if rec == 0 {
		return {}, false, .None
	}
	return _record_node(v, st, s, rec, d)
}

@(private)
_record_node :: proc(v: ^obj.View, st: ^Structure, s: int, rec: i64, d: i64) -> (at: Vref, ok: bool, err: Error) {
	sn, has := st.nodes[{i64(s), rec}]
	if !has {
		body, _ := obj.get(v, s, rec) or_return
		if obj.is_redacted(body) {
			return {}, false, .None
		}
		r := decode_record(body, rec, v.scratch) or_return
		x, isx := r.body.(Spine)
		if !isx {
			return {}, false, .Corrupt
		}
		refs, rok := spine_decode(x.nodes, int(x.c - x.first * SPINE_SPAN), v.scratch)
		if !rok {
			return {}, false, .Corrupt
		}
		list := make([]Vref, len(refs), st.alloc)
		for f, i in refs {
			list[i] = obj.resolve(v, s, f) or_return
		}
		sn = Spine_Nodes{x.first * SPINE_SPAN, list}
		st.nodes[{i64(s), rec}] = sn
	}
	i := d - 1 - sn.first
	if i < 0 || i >= i64(len(sn.nodes)) {
		return {}, false, .Corrupt
	}
	return sn.nodes[i], true, .None
}

@(private)
Spine_Nodes :: struct {
	first: i64,
	nodes: []Vref,
}

@(private)
_add_digest :: proc(c: ^Chain_Ctx, s: int, r: Forks) -> Error {
	v := c.v
	for d in r.forks {
		_add_remember(v, s, c.st, d, c.by) or_return
	}
	for d in r.assigns {
		m := obj.resolve(v, s, d.msg) or_return
		append(&c.st.assigns, Assign_Entry{m, d.runner, d.hlc, c.by})
	}
	for d in r.mounts {
		name := obj.clone_str(d.name, c.alloc) or_return
		path := obj.clone_str(d.path, c.alloc) or_return
		append(&c.st.mounts, Mount_Entry{name, d.tree, d.line, path, d.stamp, c.by, d.removed})
	}
	for d in r.superseded {
		run := obj.resolve(v, s, d.run) or_return
		by := obj.resolve(v, s, d.by) or_return
		append(&c.st.superseded, [2]Vref{run, by})
	}
	for d in r.landed {
		run := obj.resolve(v, s, d.run) or_return
		append(&c.st.landed, Landed_Entry{run, d.outcome})
	}
	return .None
}
