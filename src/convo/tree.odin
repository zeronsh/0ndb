package convo

import "../obj"
import "../prim"

Node :: struct {
	ref:        Vref,
	parent:     Vref,
	depth:      i64,
	jump:       Vref,
	jump_depth: i64,
	hlc:        prim.Hlc,
	role:       Role,
	runner:     prim.Id,
	claim:      Vref,
	files:      bool,
	files_prev: Vref,
}

@(private)
_node :: proc(v: ^obj.View, ref: Vref) -> (n: Node, err: Error) {
	c := _cache(v) or_return
	if hit, ok := c.nodes[ref]; ok {
		return hit, .None
	}
	n = _read_node(v, ref) or_return
	if len(c.nodes) >= NODE_CACHE {
		clear(&c.nodes)
	}
	c.nodes[ref] = n
	return n, .None
}

@(private)
_read_node :: proc(v: ^obj.View, ref: Vref) -> (n: Node, err: Error) {
	body, _ := obj.get(v, ref.seg, ref.off, ref.off - obj.MSG_GUESS) or_return
	m := _decode_msg(body, ref.off) or_return
	n.ref = ref
	n.depth = m.depth
	n.jump_depth = m.jump_depth
	n.hlc = m.hlc
	n.role = m.role
	n.runner = m.runner
	n.files = len(m.files) > 0
	n.parent = obj.resolve(v, ref.seg, m.parent) or_return
	n.jump = obj.resolve(v, ref.seg, m.jump) or_return
	n.files_prev = obj.resolve(v, ref.seg, m.files_prev) or_return
	if m.claim != 0 {
		n.claim = Vref{ref.seg, m.claim}
	}
	return n, .None
}

@(private)
_decode_msg :: proc(body: []u8, off: i64) -> (m: Msg, err: Error) {
	if obj.record_kind(body) != u8(Kind.Msg) {
		return m, .Corrupt
	}
	rec := decode_record(body, off) or_return
	return rec.body.(Msg), .None
}

level_ancestor :: proc(v: ^obj.View, x: Vref, depth: i64) -> (anc: Node, err: Error) {
	n := _node(v, x) or_return
	if depth < 1 || depth > n.depth {
		return n, .Invalid
	}
	for n.depth > depth {
		next := n.jump if n.jump_depth >= depth else n.parent
		nn := _node(v, next) or_return
		if nn.depth >= n.depth {
			return n, .Corrupt
		}
		n = nn
	}
	return n, .None
}

lca :: proc(v: ^obj.View, a: Vref, b: Vref) -> (anc: Vref, err: Error) {
	if obj.vref_none(a) || obj.vref_none(b) {
		return {}, .None
	}
	if a == b {
		return a, .None
	}
	na := _node(v, a) or_return
	nb := _node(v, b) or_return
	if na.depth > nb.depth {
		na = level_ancestor(v, a, nb.depth) or_return
	} else if nb.depth > na.depth {
		nb = level_ancestor(v, b, na.depth) or_return
	}
	for na.ref != nb.ref {
		if na.depth <= 1 {
			return {}, .None
		}
		if na.jump != nb.jump && na.jump_depth == nb.jump_depth && !obj.vref_none(na.jump) {
			na = _node(v, na.jump) or_return
			nb = _node(v, nb.jump) or_return
		} else {
			na = _node(v, na.parent) or_return
			nb = _node(v, nb.parent) or_return
		}
		if na.depth != nb.depth {
			return {}, .Corrupt
		}
	}
	return na.ref, .None
}

is_ancestor :: proc(v: ^obj.View, a: Vref, x: Vref) -> (yes: bool, err: Error) {
	if obj.vref_none(a) || a == x {
		return true, .None
	}
	na := _node(v, a) or_return
	nx := _node(v, x) or_return
	if nx.depth <= na.depth {
		return false, .None
	}
	anc := level_ancestor(v, x, na.depth) or_return
	return anc.ref == a, .None
}

@(private)
_tail :: proc(v: ^obj.View, s: int) -> (sum: Summary, ok: bool, err: Error) {
	sg, has := obj.tail(v, s) or_return
	if !has {
		return sum, false, .None
	}
	if !decode_summary(sg.links.extra, sg.last, &sum) {
		return sum, false, .Corrupt
	}
	return sum, true, .None
}
