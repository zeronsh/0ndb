package crdt

Located :: struct {
	pos: int,
	seq: u64,
	len: int,
}

text_locate :: proc(t: ^Text, g: ^Graph, id: Op_Id, n: int, out: ^[dynamic]Located) {
	ix, known := g.actor_index[id.actor]
	if !known || n <= 0 {
		return
	}
	cur := id.seq
	end := id.seq + u64(n)
	for cur < end {
		p, found := span_position(t, ix, cur)
		if !found {
			cur += 1
			continue
		}
		s, off, ok := run_get(&t.spans, p)
		if !ok {
			cur += 1
			continue
		}
		k := min(s.len - off, int(end - cur))
		if k <= 0 {
			cur += 1
			continue
		}
		if l := len(out); l > 0 && out[l - 1].pos + out[l - 1].len == p && out[l - 1].seq + u64(out[l - 1].len) == cur {
			out[l - 1].len += k
		} else {
			append(out, Located{p, cur, k})
		}
		cur += u64(k)
	}
}

text_ops :: proc(t: ^Text, g: ^Graph, pos: int, n: int, out: ^[dynamic]Op_Span) {
	at := pos
	rest := min(n, text_len(t) - pos)
	for rest > 0 {
		s, off, ok := run_get(&t.spans, at)
		if !ok {
			return
		}
		k := min(s.len - off, rest)
		id := Op_Id{g.actors[s.actor], s.seq + u64(off)}
		if l := len(out); l > 0 && out[l - 1].id.actor == id.actor && out[l - 1].id.seq + u64(out[l - 1].len) == id.seq {
			out[l - 1].len += k
		} else {
			append(out, Op_Span{id, k})
		}
		at += k
		rest -= k
	}
}
