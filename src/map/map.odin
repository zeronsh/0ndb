package omap

import "base:runtime"
import "core:slice"
import "../journal"
import "../obj"
import "../prim"

Error :: obj.Error
Rid :: obj.Rid

Dot :: struct {
	seg: prim.Id,
	off: i64,
}

MAX_KEY_LEN :: 200
MAX_FIELDS :: 256
MAX_TOMBS :: 4096

Kind :: enum u8 {
	Put = 16,
	Add = 17,
	Del = 18,
	Count = 19,
}

Field :: struct {
	tag:   u32,
	hlc:   prim.Hlc,
	value: []u8,
}

Put :: struct {
	key:    []u8,
	fields: []Field,
}

Add :: struct {
	key:     []u8,
	tag:     u32,
	element: []u8,
}

Del :: struct {
	key:     []u8,
	tag:     u32,
	element: []u8,
	removed: []Dot,
}

Count :: struct {
	key:   []u8,
	tag:   u32,
	delta: i64,
}

Body :: union {
	Put,
	Add,
	Del,
	Count,
}

Counter :: struct {
	tag: u32,
	by:  prim.Id,
	p:   u64,
	n:   u64,
	at:  i64,
}

Register :: struct {
	tag:    u32,
	hlc:    prim.Hlc,
	by:     prim.Id,
	value:  []u8,
}

Element :: struct {
	tag:   u32,
	value: []u8,
	live:  []Dot,
	dead:  []Dot,
}

Entry :: struct {
	key:       []u8,
	registers: []Register,
	elements:  []Element,
	counters:  []Counter,
}

encode_fields :: proc(w: ^prim.Writer, body: Body) {
	switch v in body {
	case Put:
		obj.tw_bytes(w, 1, v.key)
		for f in v.fields {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			obj.tw_uv(&bw, 1, u64(f.tag) + 1)
			obj.tw_u64(&bw, 2, u64(f.hlc))
			obj.tw_bytes(&bw, 3, f.value)
			prim.write_uvarint(w, 2 << 2 | obj.F_BYTES)
			prim.write_bytes(w, b[:])
		}
	case Add:
		obj.tw_bytes(w, 1, v.key)
		obj.tw_uv(w, 2, u64(v.tag) + 1)
		obj.tw_bytes(w, 3, v.element)
	case Del:
		obj.tw_bytes(w, 1, v.key)
		obj.tw_uv(w, 2, u64(v.tag) + 1)
		obj.tw_bytes(w, 3, v.element)
		for r in v.removed {
			f: obj.Fixed
			id := r.seg
			obj.fx_raw(&f, id[:])
			obj.fx_uv(&f, u64(max(r.off, 0)))
			obj.tw_fixed(w, 4, &f)
		}
	case Count:
		obj.tw_bytes(w, 1, v.key)
		obj.tw_uv(w, 2, u64(v.tag) + 1)
		obj.tw_uv(w, 3, u64(v.delta << 1) ~ u64(v.delta >> 63))
	}
}

decode_body :: proc(env: ^obj.Envelope, allocator := context.temp_allocator) -> (body: Body, err: Error) {
	obj.inflate(env, allocator) or_return
	d := obj.dec_init(env.fields, env.off)
	switch Kind(env.kind) {
	case .Put:
		v: Put
		fields := make([dynamic]Field, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.key = obj.dec_bytes(&d)
			case 2:
				sub := obj.dec_init(obj.dec_bytes(&d), env.off)
				f: Field
				has := false
				for obj.dec_next(&sub) {
					switch sub.f.tag {
					case 1:
						t := obj.dec_uv(&sub)
						if t == 0 || t - 1 > u64(max(u32)) {
							sub.bad = true
						}
						f.tag = u32(t - 1)
						has = true
					case 2:
						f.hlc = obj.dec_hlc(&sub)
					case 3:
						f.value = obj.dec_bytes(&sub)
					}
				}
				if !obj.dec_ok(&sub) || !has || len(fields) >= MAX_FIELDS {
					return nil, .Corrupt
				}
				append(&fields, f)
			}
		}
		v.fields = fields[:]
		if len(v.key) == 0 || len(v.key) > MAX_KEY_LEN {
			d.bad = true
		}
		body = v
	case .Add, .Del:
		key, elem: []u8
		tag: u32
		has := false
		removed := make([dynamic]Dot, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				key = obj.dec_bytes(&d)
			case 2:
				t := obj.dec_uv(&d)
				if t == 0 || t - 1 > u64(max(u32)) {
					d.bad = true
				}
				tag = u32(t - 1)
				has = true
			case 3:
				elem = obj.dec_bytes(&d)
			case 4:
				r := prim.reader(obj.dec_bytes(&d))
				id := prim.read_id(&r)
				off := prim.read_uvarint(&r)
				if !prim.reader_done(&r) || off == 0 || off > u64(max(i64)) || len(removed) >= MAX_TOMBS {
					d.bad = true
				} else {
					append(&removed, Dot{id, i64(off)})
				}
			}
		}
		if len(key) == 0 || len(key) > MAX_KEY_LEN || !has {
			d.bad = true
		}
		if Kind(env.kind) == .Add {
			body = Add{key, tag, elem}
		} else {
			body = Del{key, tag, elem, removed[:]}
		}
	case .Count:
		v: Count
		has := false
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.key = obj.dec_bytes(&d)
			case 2:
				t := obj.dec_uv(&d)
				if t == 0 || t - 1 > u64(max(u32)) {
					d.bad = true
				}
				v.tag = u32(t - 1)
				has = true
			case 3:
				z := obj.dec_uv(&d)
				v.delta = i64(z >> 1) ~ -i64(z & 1)
			}
		}
		if len(v.key) == 0 || len(v.key) > MAX_KEY_LEN || !has {
			d.bad = true
		}
		body = v
	case:
		return nil, .Unsupported
	}
	if !obj.dec_ok(&d) {
		return nil, .Corrupt
	}
	return body, .None
}

register_wins :: proc "contextless" (a_hlc: prim.Hlc, a_by: prim.Id, a_val: []u8, b_hlc: prim.Hlc, b_by: prim.Id, b_val: []u8) -> bool {
	if a_hlc != b_hlc {
		return a_hlc > b_hlc
	}
	if a_by != b_by {
		return obj.id_less(b_by, a_by)
	}
	n := min(len(a_val), len(b_val))
	for i in 0 ..< n {
		if a_val[i] != b_val[i] {
			return a_val[i] > b_val[i]
		}
	}
	return len(a_val) > len(b_val)
}

entry_empty :: proc "contextless" (e: ^Entry) -> bool {
	if len(e.registers) > 0 || len(e.counters) > 0 {
		return false
	}
	for el in e.elements {
		if len(el.live) > 0 {
			return false
		}
	}
	return true
}

entry_register :: proc "contextless" (e: ^Entry, tag: u32) -> (value: []u8, found: bool) {
	for r in e.registers {
		if r.tag == tag {
			return r.value, true
		}
	}
	return nil, false
}

entry_elements :: proc(e: ^Entry, tag: u32, allocator := context.temp_allocator) -> [][]u8 {
	out := make([dynamic][]u8, allocator)
	for el in e.elements {
		if el.tag == tag && len(el.live) > 0 {
			append(&out, el.value)
		}
	}
	return out[:]
}

ENTRY_FORMAT :: 4

encode_entry :: proc(buf: ^[dynamic]u8, e: ^Entry) -> Error {
	devs := make([dynamic]prim.Id, context.temp_allocator)
	dev :: proc(devs: ^[dynamic]prim.Id, id: prim.Id) -> u64 {
		for d, j in devs {
			if d == id {
				return u64(j)
			}
		}
		append(devs, id)
		return u64(len(devs) - 1)
	}
	base: prim.Hlc
	for r in e.registers {
		dev(&devs, r.by)
		base = max(base, r.hlc)
	}
	for el in e.elements {
		for r in el.live {
			dev(&devs, r.seg)
		}
		for r in el.dead {
			dev(&devs, r.seg)
		}
	}
	for c in e.counters {
		dev(&devs, c.by)
	}
	w := prim.writer(buf)
	prim.write_u8(&w, ENTRY_FORMAT)
	prim.write_uvarint(&w, u64(len(devs)))
	for d in devs {
		prim.write_id(&w, d)
	}
	prim.write_uvarint(&w, u64(len(e.registers)))
	if len(e.registers) > 0 {
		prim.write_u64le(&w, u64(base))
	}
	for r in e.registers {
		prim.write_uvarint(&w, u64(r.tag))
		prim.write_uvarint(&w, u64(base - r.hlc))
		prim.write_uvarint(&w, dev(&devs, r.by))
		prim.write_bytes(&w, r.value)
	}
	prim.write_uvarint(&w, u64(len(e.elements)))
	for el in e.elements {
		prim.write_uvarint(&w, u64(el.tag))
		prim.write_bytes(&w, el.value)
		for list in ([2][]Dot{el.live, el.dead}) {
			prim.write_uvarint(&w, u64(len(list)))
			for r in list {
				prim.write_uvarint(&w, dev(&devs, r.seg))
				prim.write_uvarint(&w, u64(r.off))
			}
		}
	}
	prim.write_uvarint(&w, u64(len(e.counters)))
	for c in e.counters {
		prim.write_uvarint(&w, u64(c.tag))
		prim.write_uvarint(&w, dev(&devs, c.by))
		prim.write_uvarint(&w, c.p)
		prim.write_uvarint(&w, c.n)
		prim.write_uvarint(&w, u64(c.at))
	}
	if w.err != .None {
		return .No_Memory
	}
	return .None
}

decode_entry :: proc(key: []u8, data: []u8, allocator := context.temp_allocator) -> (e: Entry, err: Error) {
	e.key = key
	if len(data) == 0 {
		return e, .None
	}
	r := prim.reader(data)
	if prim.read_u8(&r) != ENTRY_FORMAT {
		return e, .Corrupt
	}
	nd := prim.read_uvarint(&r)
	if r.err != .None || nd * 16 > u64(prim.reader_remaining(&r)) {
		return e, .Corrupt
	}
	devs := make([]prim.Id, int(nd), allocator)
	for &d in devs {
		d = prim.read_id(&r)
	}
	nr := prim.read_uvarint(&r)
	if r.err != .None || nr * 4 > u64(prim.reader_remaining(&r)) {
		return e, .Corrupt
	}
	base: u64
	if nr > 0 {
		base = prim.read_u64le(&r)
	}
	regs := make([]Register, int(nr), allocator)
	for &g in regs {
		t := prim.read_uvarint(&r)
		delta := prim.read_uvarint(&r)
		di := prim.read_uvarint(&r)
		g.value = prim.read_bytes(&r)
		if t > u64(max(u32)) || di >= nd || delta > base {
			return e, .Corrupt
		}
		g.tag = u32(t)
		g.hlc = prim.Hlc(base - delta)
		g.by = devs[di]
	}
	ne := prim.read_uvarint(&r)
	if r.err != .None || ne * 4 > u64(prim.reader_remaining(&r)) {
		return e, .Corrupt
	}
	els := make([]Element, int(ne), allocator)
	for &el in els {
		t := prim.read_uvarint(&r)
		el.value = prim.read_bytes(&r)
		if t > u64(max(u32)) {
			return e, .Corrupt
		}
		el.tag = u32(t)
		for k in 0 ..< 2 {
			n := prim.read_uvarint(&r)
			if r.err != .None || n * 2 > u64(prim.reader_remaining(&r)) {
				return e, .Corrupt
			}
			list := make([]Dot, int(n), allocator)
			for &x in list {
				di := prim.read_uvarint(&r)
				off := prim.read_uvarint(&r)
				if di >= nd || off > u64(max(i64)) {
					return e, .Corrupt
				}
				x.seg = devs[di]
				x.off = i64(off)
			}
			if k == 0 {
				el.live = list
			} else {
				el.dead = list
			}
		}
	}
	nc := prim.read_uvarint(&r)
	if r.err != .None || nc * 4 > u64(prim.reader_remaining(&r)) {
		return e, .Corrupt
	}
	cs := make([]Counter, int(nc), allocator)
	for &c in cs {
		t := prim.read_uvarint(&r)
		di := prim.read_uvarint(&r)
		c.p = prim.read_uvarint(&r)
		c.n = prim.read_uvarint(&r)
		ca := prim.read_uvarint(&r)
		if t > u64(max(u32)) || di >= nd || ca > u64(max(i64)) {
			return e, .Corrupt
		}
		c.tag = u32(t)
		c.by = devs[di]
		c.at = i64(ca)
	}
	if r.err != .None || !prim.reader_done(&r) {
		return e, .Corrupt
	}
	e.registers = regs
	e.elements = els
	e.counters = cs
	return e, .None
}

apply :: proc(e: ^Entry, by: prim.Id, at: Dot, body: Body, allocator := context.temp_allocator) -> (changed: bool) {
	switch v in body {
	case Put:
		regs := make([dynamic]Register, 0, len(e.registers) + len(v.fields), allocator)
		append(&regs, ..e.registers)
		for f in v.fields {
			k := -1
			for r, i in regs {
				if r.tag == f.tag {
					k = i
					break
				}
			}
			n := Register{f.tag, f.hlc, by, f.value}
			if k < 0 {
				append(&regs, n)
				changed = true
			} else if register_wins(f.hlc, by, f.value, regs[k].hlc, regs[k].by, regs[k].value) {
				regs[k] = n
				changed = true
			}
		}
		if changed {
			slice.sort_by(regs[:], proc(a, b: Register) -> bool {
				return a.tag < b.tag
			})
			e.registers = regs[:]
		}
	case Add:
		k := _element(e, v.tag, v.element, allocator)
		el := &e.elements[k]
		if _rid_in(el.live, at) || _rid_in(el.dead, at) {
			return false
		}
		live := make([dynamic]Dot, allocator)
		append(&live, ..el.live)
		append(&live, at)
		el.live = live[:]
		changed = true
	case Del:
		k := _element(e, v.tag, v.element, allocator)
		el := &e.elements[k]
		live := make([dynamic]Dot, allocator)
		dead := make([dynamic]Dot, allocator)
		append(&dead, ..el.dead)
		for r in v.removed {
			if !_rid_in(dead[:], r) {
				append(&dead, r)
				changed = true
			}
		}
		for r in el.live {
			if !_rid_in(dead[:], r) {
				append(&live, r)
			}
		}
		el.live = live[:]
		el.dead = dead[:]
	case Count:
		k := -1
		for c, i in e.counters {
			if c.tag == v.tag && c.by == by {
				k = i
				break
			}
		}
		if k < 0 {
			list := make([dynamic]Counter, 0, len(e.counters) + 1, allocator)
			append(&list, ..e.counters)
			append(&list, Counter{tag = v.tag, by = by, at = -1})
			slice.sort_by(list[:], _counter_less)
			e.counters = list[:]
			for c, i in e.counters {
				if c.tag == v.tag && c.by == by {
					k = i
					break
				}
			}
			changed = true
		} else {
			list := make([]Counter, len(e.counters), allocator)
			copy(list, e.counters)
			e.counters = list
		}
		c := &e.counters[k]
		if at.off <= c.at {
			return changed
		}
		c.at = at.off
		changed = true
		if v.delta > 0 {
			c.p = _sat_add(c.p, u64(v.delta))
			changed = true
		} else if v.delta < 0 {
			c.n = _sat_add(c.n, u64(-(v.delta + 1)) + 1)
			changed = true
		}
	}
	if changed {
		n := 0
		for el in e.elements {
			if len(el.live) > 0 || len(el.dead) > 0 {
				e.elements[n] = el
				n += 1
			}
		}
		e.elements = e.elements[:n]
	}
	return
}

@(private)
_rid_in :: proc "contextless" (list: []Dot, r: Dot) -> bool {
	for x in list {
		if x == r {
			return true
		}
	}
	return false
}

@(private)
_element :: proc(e: ^Entry, tag: u32, value: []u8, allocator: runtime.Allocator) -> int {
	for el, i in e.elements {
		if el.tag == tag && string(el.value) == string(value) {
			return i
		}
	}
	els := make([dynamic]Element, 0, len(e.elements) + 1, allocator)
	append(&els, ..e.elements)
	append(&els, Element{tag = tag, value = value})
	slice.sort_by(els[:], proc(a, b: Element) -> bool {
		if a.tag != b.tag {
			return a.tag < b.tag
		}
		return string(a.value) < string(b.value)
	})
	e.elements = els[:]
	for el, i in e.elements {
		if el.tag == tag && string(el.value) == string(value) {
			return i
		}
	}
	return -1
}

Writer :: struct {
	core: obj.Writer,
}

writer_create :: proc(w: ^Writer, v: ^obj.View, vfs: prim.Vfs, path: string, object: prim.Id, participant: prim.Id, gen: u64, created: prim.Hlc, settings: []u8 = nil, opts := journal.Options{}, allocator := context.allocator, clock := obj.Clock{}) -> Error {
	return obj.writer_create(&w.core, v, vfs, path, object, .Map, participant, gen, created, settings, opts, allocator, clock)
}

writer_open :: proc(w: ^Writer, v: ^obj.View, vfs: prim.Vfs, path: string, object: prim.Id, participant: prim.Id, gen: u64, opts := journal.Options{}, allocator := context.allocator, clock := obj.Clock{}) -> (head: obj.Head, err: Error) {
	return obj.writer_open(&w.core, v, vfs, path, object, .Map, participant, gen, opts, allocator, clock)
}

writer_close :: proc(w: ^Writer) -> Error {
	return obj.writer_close(&w.core)
}

writer_commit :: proc(w: ^Writer) -> Error {
	return obj.writer_commit(&w.core)
}

observe_entry :: proc(w: ^Writer, e: ^Entry) {
	for r in e.registers {
		obj.observe(&w.core, r.hlc)
	}
}

put :: proc(w: ^Writer, key: []u8, fields: []Field) -> (off: i64, err: Error) {
	if len(key) == 0 || len(key) > MAX_KEY_LEN || len(fields) > MAX_FIELDS {
		return 0, .Invalid
	}
	stamped := make([]Field, len(fields), context.temp_allocator)
	h := obj.now(&w.core)
	for f, i in fields {
		stamped[i] = f
		if stamped[i].hlc == 0 {
			stamped[i].hlc = h
		} else {
			obj.observe(&w.core, f.hlc)
		}
	}
	return _append(w, Put{key, stamped})
}

add :: proc(w: ^Writer, key: []u8, tag: u32, element: []u8) -> (id: Rid, err: Error) {
	if len(key) == 0 || len(key) > MAX_KEY_LEN {
		return {}, .Invalid
	}
	off := _append(w, Add{key, tag, element}) or_return
	return Rid{w.core.id, off, w.core.gen}, .None
}

del :: proc(w: ^Writer, key: []u8, tag: u32, element: []u8, observed: []Dot) -> (off: i64, err: Error) {
	if len(key) == 0 || len(key) > MAX_KEY_LEN || len(observed) > MAX_TOMBS {
		return 0, .Invalid
	}
	return _append(w, Del{key, tag, element, observed})
}

count :: proc(w: ^Writer, key: []u8, tag: u32, delta: i64) -> (off: i64, err: Error) {
	if len(key) == 0 || len(key) > MAX_KEY_LEN {
		return 0, .Invalid
	}
	return _append(w, Count{key, tag, delta})
}

counter_value :: proc "contextless" (e: ^Entry, tag: u32) -> (value: i64, found: bool) {
	for c in e.counters {
		if c.tag == tag {
			value += i64(c.p) - i64(c.n)
			found = true
		}
	}
	return
}

@(private)
_counter_less :: proc(a, b: Counter) -> bool {
	if a.tag != b.tag {
		return a.tag < b.tag
	}
	return obj.id_less(a.by, b.by)
}

@(private)
_sat_add :: proc "contextless" (a, b: u64) -> u64 {
	if a > max(u64) - b {
		return max(u64)
	}
	return a + b
}

@(private)
_append :: proc(w: ^Writer, body: Body) -> (off: i64, err: Error) {
	k: Kind
	switch _ in body {
	case Put:
		k = .Put
	case Add:
		k = .Add
	case Del:
		k = .Del
	case Count:
		k = .Count
	}
	rec := obj.begin(&w.core, u8(k), false, false) or_return
	obj.put_links(&rec, nil)
	encode_fields(&rec.pw, body)
	if rec.pw.err != .None {
		obj.abort(&w.core, &rec)
		return 0, .No_Memory
	}
	return obj.finish(&w.core, &rec)
}

field_u64 :: proc(tag: u32, v: u64, allocator := context.temp_allocator) -> Field {
	b := make([]u8, 10, allocator)
	n := prim.put_uvarint(b, v)
	return Field{tag = tag, value = b[:n]}
}

field_bool :: proc(tag: u32, v: bool, allocator := context.temp_allocator) -> Field {
	b := make([]u8, 1, allocator)
	b[0] = 1 if v else 0
	return Field{tag = tag, value = b}
}

field_id :: proc(tag: u32, id: prim.Id, allocator := context.temp_allocator) -> Field {
	b := make([]u8, 16, allocator)
	x := id
	copy(b, x[:])
	return Field{tag = tag, value = b}
}

field_str :: proc(tag: u32, s: string) -> Field {
	return Field{tag = tag, value = transmute([]u8)s}
}

value_u64 :: proc "contextless" (v: []u8) -> (x: u64, ok: bool) {
	n: int
	x, n = prim.get_uvarint(v)
	return x, n > 0 && n == len(v)
}

value_bool :: proc "contextless" (v: []u8) -> (bool, bool) {
	if len(v) != 1 || v[0] > 1 {
		return false, false
	}
	return v[0] == 1, true
}

value_id :: proc "contextless" (v: []u8) -> (id: prim.Id, ok: bool) {
	if len(v) != 16 {
		return
	}
	copy(id[:], v)
	return id, true
}

entry_join :: proc(a, b: ^Entry, allocator := context.temp_allocator) -> (out: Entry) {
	out.key = a.key
	regs := make([dynamic]Register, 0, len(a.registers) + len(b.registers), allocator)
	append(&regs, ..a.registers)
	for r in b.registers {
		k := -1
		for x, i in regs {
			if x.tag == r.tag {
				k = i
				break
			}
		}
		if k < 0 {
			append(&regs, r)
		} else if register_wins(r.hlc, r.by, r.value, regs[k].hlc, regs[k].by, regs[k].value) {
			regs[k] = r
		}
	}
	slice.sort_by(regs[:], proc(x, y: Register) -> bool {
		return x.tag < y.tag
	})
	out.registers = regs[:]
	els := make([dynamic]Element, 0, len(a.elements) + len(b.elements), allocator)
	append(&els, ..a.elements)
	for el in b.elements {
		k := -1
		for x, i in els {
			if x.tag == el.tag && string(x.value) == string(el.value) {
				k = i
				break
			}
		}
		if k < 0 {
			append(&els, el)
			continue
		}
		live := make([dynamic]Dot, 0, len(els[k].live) + len(el.live), allocator)
		dead := make([dynamic]Dot, 0, len(els[k].dead) + len(el.dead), allocator)
		append(&dead, ..els[k].dead)
		for r in el.dead {
			if !_rid_in(dead[:], r) {
				append(&dead, r)
			}
		}
		for list in ([2][]Dot{els[k].live, el.live}) {
			for r in list {
				if !_rid_in(dead[:], r) && !_rid_in(live[:], r) {
					append(&live, r)
				}
			}
		}
		els[k].live = live[:]
		els[k].dead = dead[:]
	}
	n := 0
	for el in els {
		if len(el.live) > 0 || len(el.dead) > 0 {
			els[n] = el
			n += 1
		}
	}
	slice.sort_by(els[:n], proc(x, y: Element) -> bool {
		if x.tag != y.tag {
			return x.tag < y.tag
		}
		return string(x.value) < string(y.value)
	})
	out.elements = els[:n]
	cs := make([dynamic]Counter, 0, len(a.counters) + len(b.counters), allocator)
	append(&cs, ..a.counters)
	for c in b.counters {
		k := -1
		for x, i in cs {
			if x.tag == c.tag && x.by == c.by {
				k = i
				break
			}
		}
		if k < 0 {
			append(&cs, c)
		} else {
			cs[k].p = _sat_add(cs[k].p, c.p)
			cs[k].n = _sat_add(cs[k].n, c.n)
			cs[k].at = max(cs[k].at, c.at)
		}
	}
	slice.sort_by(cs[:], _counter_less)
	out.counters = cs[:]
	return
}
