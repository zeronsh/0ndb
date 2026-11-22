package crdt

import "base:runtime"
import "../prim"

Delta_Kind :: enum u8 {
	Retain,
	Delete,
	Insert,
}

Delta_Op :: struct {
	kind:   Delta_Kind,
	n:      int,
	text:   []u8,
	author: prim.Id,
}

Delta_Builder :: struct {
	allocator: runtime.Allocator,
	before:    [dynamic]Delta_Op,
	after:     [dynamic]Delta_Op,
	pos:       int,
	steps:     int,
}

delta_builder_init :: proc(b: ^Delta_Builder, allocator := context.allocator) {
	b^ = {}
	b.allocator = allocator
	b.before = make([dynamic]Delta_Op, allocator)
	b.after = make([dynamic]Delta_Op, allocator)
}

delta_builder_reset :: proc(b: ^Delta_Builder) {
	clear(&b.before)
	clear(&b.after)
	b.pos = 0
	b.steps = 0
}

@(private = "file")
new_len :: #force_inline proc "contextless" (o: Delta_Op) -> int {
	return 0 if o.kind == .Delete else o.n
}

@(private = "file")
seek :: proc(b: ^Delta_Builder, p: int) {
	for b.pos > p && len(b.before) > 0 {
		x := pop(&b.before)
		b.pos -= new_len(x)
		append(&b.after, x)
	}
	for len(b.after) > 0 {
		top := b.after[len(b.after) - 1]
		if b.pos + new_len(top) > p {
			break
		}
		append(&b.before, pop(&b.after))
		b.pos += new_len(top)
	}
	if len(b.after) == 0 && p > b.pos {
		append(&b.before, Delta_Op{kind = .Retain, n = p - b.pos})
		b.pos = p
	}
}

@(private = "file")
push :: #force_inline proc(list: ^[dynamic]Delta_Op, o: Delta_Op) {
	if o.n > 0 {
		append(list, o)
	}
}

delta_step_insert :: proc(b: ^Delta_Builder, pos: int, bytes: []u8, author: prim.Id) {
	if len(bytes) == 0 {
		return
	}
	b.steps += 1
	seek(b, pos)
	ins := Delta_Op{kind = .Insert, n = len(bytes), text = bytes, author = author}
	o := pos - b.pos
	if o > 0 && len(b.after) > 0 {
		c := pop(&b.after)
		if c.kind == .Retain {
			push(&b.before, Delta_Op{kind = .Retain, n = o})
			push(&b.after, Delta_Op{kind = .Retain, n = c.n - o})
		} else {
			push(&b.before, Delta_Op{kind = .Insert, n = o, text = c.text[:o], author = c.author})
			push(&b.after, Delta_Op{kind = .Insert, n = c.n - o, text = c.text[o:], author = c.author})
		}
		b.pos += o
	}
	append(&b.before, ins)
	b.pos += ins.n
}

delta_step_delete :: proc(b: ^Delta_Builder, pos: int, bytes: []u8) {
	step_delete(b, pos, len(bytes), bytes)
}

@(private = "file")
step_delete :: proc(b: ^Delta_Builder, pos: int, count: int, bytes: []u8) {
	rest := count
	text := bytes
	if rest <= 0 {
		return
	}
	b.steps += 1
	for rest > 0 {
		seek(b, pos)
		if len(b.after) == 0 {
			append(&b.before, Delta_Op{kind = .Delete, n = rest, text = text})
			return
		}
		c := pop(&b.after)
		o := pos - b.pos
		k := min(rest, c.n - o)
		if c.kind == .Retain {
			push(&b.before, Delta_Op{kind = .Retain, n = o})
			b.pos += o
			append(&b.before, Delta_Op{kind = .Delete, n = k, text = text[:k] if text != nil else nil})
			push(&b.after, Delta_Op{kind = .Retain, n = c.n - o - k})
		} else {
			push(&b.before, Delta_Op{kind = .Insert, n = o, text = c.text[:o], author = c.author})
			b.pos += o
			push(&b.after, Delta_Op{kind = .Insert, n = c.n - o - k, text = c.text[o + k:], author = c.author})
		}
		rest -= k
		if text != nil {
			text = text[k:]
		}
	}
}

Delta_Region :: struct {
	old:  int,
	new:  int,
	del:  []u8,
	ins:  [dynamic]Delta_Op,
}

Text_Reader :: struct {
	data:   rawptr,
	read:   proc(data: rawptr, pos: int, dst: []u8) -> int,
	author: proc(data: rawptr, pos: int) -> prim.Id,
	len:    int,
}

@(private = "file")
cat :: proc(a, b: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(a) == 0 {
		return b
	}
	if len(b) == 0 {
		return a
	}
	out := make([]u8, len(a) + len(b), allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

@(private = "file")
ins_push :: proc(list: ^[dynamic]Delta_Op, o: Delta_Op, allocator: runtime.Allocator) {
	if o.n <= 0 {
		return
	}
	if n := len(list); n > 0 && list[n - 1].author == o.author {
		l := &list[n - 1]
		l.text = cat(l.text, o.text, allocator)
		l.n = len(l.text)
		return
	}
	append(list, o)
}

delta_regions :: proc(b: ^Delta_Builder, allocator := context.allocator) -> []Delta_Region {
	out := make([dynamic]Delta_Region, allocator)
	old, nw := 0, 0
	cur: ^Delta_Region
	visit :: proc(o: Delta_Op, out: ^[dynamic]Delta_Region, cur: ^^Delta_Region, old, nw: ^int, allocator: runtime.Allocator) {
		if o.kind == .Retain {
			cur^ = nil
			old^ += o.n
			nw^ += o.n
			return
		}
		if cur^ == nil {
			append(out, Delta_Region{old = old^, new = nw^, ins = make([dynamic]Delta_Op, allocator)})
			cur^ = &out[len(out) - 1]
		}
		if o.kind == .Delete {
			cur^.del = cat(cur^.del, o.text, allocator)
			old^ += o.n
		} else {
			ins_push(&cur^.ins, o, allocator)
			nw^ += o.n
		}
	}
	for o in b.before {
		visit(o, &out, &cur, &old, &nw, allocator)
	}
	#reverse for o in b.after {
		visit(o, &out, &cur, &old, &nw, allocator)
	}
	w := 0
	for r in out {
		if len(r.del) == 0 && len(r.ins) == 0 {
			continue
		}
		out[w] = r
		w += 1
	}
	resize(&out, w)
	return out[:]
}

@(private = "file")
cont :: #force_inline proc "contextless" (x: u8) -> bool {
	return x & 0xC0 == 0x80
}

@(private = "file")
region_new_len :: proc(r: ^Delta_Region) -> int {
	n := 0
	for o in r.ins {
		n += o.n
	}
	return n
}

@(private = "file")
read_byte :: proc(rd: ^Text_Reader, pos: int) -> (u8, bool) {
	if pos < 0 || pos >= rd.len {
		return 0, false
	}
	b: [1]u8
	if rd.read(rd.data, pos, b[:]) != 1 {
		return 0, false
	}
	return b[0], true
}

@(private = "file")
grow_left :: proc(r: ^Delta_Region, rd: ^Text_Reader, k: int, allocator: runtime.Allocator) {
	if k <= 0 {
		return
	}
	buf := make([]u8, k, allocator)
	rd.read(rd.data, r.new - k, buf)
	r.del = cat(buf, r.del, allocator)
	pre := make([dynamic]Delta_Op, allocator)
	i := 0
	for i < k {
		a := rd.author(rd.data, r.new - k + i)
		j := i + 1
		for j < k && rd.author(rd.data, r.new - k + j) == a {
			j += 1
		}
		ins_push(&pre, Delta_Op{kind = .Insert, n = j - i, text = buf[i:j], author = a}, allocator)
		i = j
	}
	for o in r.ins {
		ins_push(&pre, o, allocator)
	}
	r.ins = pre
	r.old -= k
	r.new -= k
}

@(private = "file")
grow_right :: proc(r: ^Delta_Region, rd: ^Text_Reader, k: int, allocator: runtime.Allocator) {
	if k <= 0 {
		return
	}
	at := r.new + region_new_len(r)
	buf := make([]u8, k, allocator)
	rd.read(rd.data, at, buf)
	r.del = cat(r.del, buf, allocator)
	i := 0
	for i < k {
		a := rd.author(rd.data, at + i)
		j := i + 1
		for j < k && rd.author(rd.data, at + j) == a {
			j += 1
		}
		ins_push(&r.ins, Delta_Op{kind = .Insert, n = j - i, text = buf[i:j], author = a}, allocator)
		i = j
	}
}

delta_widen :: proc(regions: []Delta_Region, rd: ^Text_Reader, allocator := context.allocator) -> []Delta_Region {
	out := make([dynamic]Delta_Region, allocator)
	for &src, idx in regions {
		r := src
		hi := regions[idx + 1].new if idx + 1 < len(regions) else rd.len
		for _ in 0 ..< 4 {
			lo := 0
			if n := len(out); n > 0 {
				p := &out[n - 1]
				lo = p.new + region_new_len(p)
			}
			end := r.new + region_new_len(&r)
			rb, has_rb := read_byte(rd, end)
			first_old := r.del[0] if len(r.del) > 0 else rb
			first_new := r.ins[0].text[0] if len(r.ins) > 0 else rb
			split_left := (len(r.del) > 0 || has_rb) && cont(first_old) || (len(r.ins) > 0 || has_rb) && cont(first_new)
			k := 0
			if split_left {
				for k < 4 && r.new - k > lo {
					k += 1
					x, _ := read_byte(rd, r.new - k)
					if !cont(x) {
						break
					}
				}
			}
			j := 0
			for has_rb && j < 3 && end + j < hi && cont(rb) {
				j += 1
				rb, has_rb = read_byte(rd, end + j)
			}
			if k == 0 && j == 0 {
				break
			}
			grow_left(&r, rd, k, allocator)
			grow_right(&r, rd, j, allocator)
		}
		if n := len(out); n > 0 {
			p := &out[n - 1]
			if p.new + region_new_len(p) == r.new {
				p.del = cat(p.del, r.del, allocator)
				for o in r.ins {
					ins_push(&p.ins, o, allocator)
				}
				continue
			}
		}
		append(&out, r)
	}
	return out[:]
}

op_units :: #force_inline proc "contextless" (o: Delta_Op, utf16: bool) -> int {
	if o.kind == .Insert && utf16 {
		return units(o.text)
	}
	return o.n
}

delta_emit :: proc(regions: []Delta_Region, utf16: bool, units_at: proc(data: rawptr, pos: int) -> int, data: rawptr, out: ^[dynamic]Delta_Op) {
	nw := 0
	for &r in regions {
		if r.new > nw {
			n := r.new - nw
			if utf16 {
				n = units_at(data, r.new) - units_at(data, nw)
			}
			delta_push(out, Delta_Op{kind = .Retain, n = n})
		}
		if len(r.del) > 0 {
			delta_push(out, Delta_Op{kind = .Delete, n = units(r.del) if utf16 else len(r.del)})
		}
		for o in r.ins {
			x := o
			x.n = op_units(o, utf16)
			delta_push(out, x)
		}
		nw = r.new + region_new_len(&r)
	}
}

delta_push :: proc(out: ^[dynamic]Delta_Op, o: Delta_Op) {
	if o.n <= 0 {
		return
	}
	if n := len(out); n > 0 {
		l := &out[n - 1]
		if l.kind == o.kind && o.kind != .Insert {
			l.n += o.n
			return
		}
		if o.kind == .Delete && l.kind == .Insert {
			ins := l^
			l^ = o
			delta_push_after_delete(out, ins)
			return
		}
	}
	append(out, o)
}

@(private = "file")
delta_push_after_delete :: proc(out: ^[dynamic]Delta_Op, ins: Delta_Op) {
	n := len(out)
	if n >= 2 && out[n - 2].kind == .Delete {
		out[n - 2].n += out[n - 1].n
		out[n - 1] = ins
		return
	}
	append(out, ins)
}

delta_trim :: proc(ops: ^[dynamic]Delta_Op) {
	for len(ops) > 0 && ops[len(ops) - 1].kind == .Retain {
		pop(ops)
	}
}

Delta_Side :: struct {
	ops:  []Delta_Op,
	i:    int,
	used: int,
}

@(private = "file")
side_peek :: proc(s: ^Delta_Side, utf16: bool) -> (Delta_Op, int, bool) {
	if s.i >= len(s.ops) {
		return Delta_Op{kind = .Retain}, max(int), false
	}
	o := s.ops[s.i]
	return o, op_units(o, utf16) - s.used, true
}

@(private = "file")
side_take :: proc(s: ^Delta_Side, k: int, utf16: bool) {
	if s.i >= len(s.ops) {
		return
	}
	s.used += k
	if s.used >= op_units(s.ops[s.i], utf16) {
		s.i += 1
		s.used = 0
	}
}

delta_transform :: proc(a, b: []Delta_Op, utf16: bool, a_out, b_out: ^[dynamic]Delta_Op) {
	sa := Delta_Side{ops = a}
	sb := Delta_Side{ops = b}
	for {
		oa, ra, ha := side_peek(&sa, utf16)
		ob, rb, hb := side_peek(&sb, utf16)
		if !ha && !hb {
			break
		}
		if ha && oa.kind == .Insert {
			delta_push(a_out, oa)
			delta_push(b_out, Delta_Op{kind = .Retain, n = ra})
			side_take(&sa, ra, utf16)
			continue
		}
		if hb && ob.kind == .Insert {
			delta_push(a_out, Delta_Op{kind = .Retain, n = rb})
			delta_push(b_out, ob)
			side_take(&sb, rb, utf16)
			continue
		}
		k := min(ra, rb)
		switch {
		case oa.kind == .Retain && ob.kind == .Retain:
			delta_push(a_out, Delta_Op{kind = .Retain, n = k})
			delta_push(b_out, Delta_Op{kind = .Retain, n = k})
		case oa.kind == .Delete && ob.kind == .Delete:
		case oa.kind == .Delete:
			delta_push(a_out, Delta_Op{kind = .Delete, n = k})
		case ob.kind == .Delete:
			delta_push(b_out, Delta_Op{kind = .Delete, n = k})
		}
		side_take(&sa, k, utf16)
		side_take(&sb, k, utf16)
	}
	delta_trim(a_out)
	delta_trim(b_out)
}

delta_transform_pos :: proc(ops: []Delta_Op, pos: int, after: bool, utf16: bool) -> int {
	old := 0
	shift := 0
	for o in ops {
		n := op_units(o, utf16)
		switch o.kind {
		case .Retain:
			if pos < old + n {
				return pos + shift
			}
			old += n
		case .Insert:
			if pos == old && !after {
				return pos + shift
			}
			shift += n
		case .Delete:
			if pos <= old {
				return pos + shift
			}
			if pos < old + n {
				return old + shift
			}
			shift -= n
			old += n
		}
	}
	return pos + shift
}

delta_untransform_pos :: proc(ops: []Delta_Op, pos: int, after: bool, utf16: bool) -> int {
	old := 0
	nw := 0
	for o in ops {
		n := op_units(o, utf16)
		switch o.kind {
		case .Retain:
			if pos < nw + n {
				return old + pos - nw
			}
			old += n
			nw += n
		case .Insert:
			if pos < nw + n {
				return old
			}
			nw += n
		case .Delete:
			if pos == nw && !after {
				return old
			}
			old += n
		}
	}
	return old + pos - nw
}

delta_apply :: proc(doc: []u8, ops: []Delta_Op, allocator := context.allocator) -> (out: []u8, ok: bool) {
	res := make([dynamic]u8, 0, len(doc), allocator)
	at := 0
	for o in ops {
		switch o.kind {
		case .Retain:
			if at + o.n > len(doc) {
				delete(res)
				return nil, false
			}
			append(&res, ..doc[at:at + o.n])
			at += o.n
		case .Delete:
			if at + o.n > len(doc) {
				delete(res)
				return nil, false
			}
			at += o.n
		case .Insert:
			append(&res, ..o.text)
		}
	}
	append(&res, ..doc[at:])
	return res[:], true
}

text_units :: proc "contextless" (t: ^Text) -> int {
	return rope_units(&t.rope)
}

text_units_at :: proc(t: ^Text, pos: int) -> int {
	return rope_units_at(&t.rope, pos)
}

text_byte_at :: proc(t: ^Text, u: int) -> int {
	return rope_byte_at(&t.rope, u)
}

text_char_start :: proc(t: ^Text, pos: int) -> bool {
	if pos <= 0 || pos >= text_len(t) {
		return true
	}
	b: [1]u8
	rope_read(&t.rope, pos, b[:])
	return !cont(b[0])
}
