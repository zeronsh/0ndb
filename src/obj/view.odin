package obj

import "base:runtime"
import "core:slice"
import "../journal"
import "../prim"

View_Seg :: struct {
	id:       prim.Id,
	jr:       ^journal.Reader,
	ids:      [dynamic]prim.Id,
	vmap:     [dynamic]int,
	table_at: i64,
	tail_end: i64,
	last:     i64,
	links:    Links,
	extra:    [dynamic]u8,
	stride:   i64,
	grown:    u64,
}

View :: struct {
	object:    prim.Id,
	segs:      [dynamic]View_Seg,
	want:      [dynamic]Want,
	unknown:   [dynamic]prim.Id,
	w:          ^Writer,
	cache:      rawptr,
	cache_free: proc(cache: rawptr, allocator: runtime.Allocator),
	allocator:  runtime.Allocator,
	scratch:    runtime.Allocator,
	pass:       u64,
}

Visit :: #type proc(data: rawptr, s: int, off: i64, env: ^Envelope) -> (stop: bool, err: Error)

view_init :: proc(v: ^View, object: prim.Id, allocator := context.allocator, scratch := context.temp_allocator) {
	v^ = {
		object    = object,
		segs      = make([dynamic]View_Seg, allocator),
		want      = make([dynamic]Want, allocator),
		unknown   = make([dynamic]prim.Id, allocator),
		allocator = allocator,
		scratch   = scratch,
	}
}

view_destroy :: proc(v: ^View) {
	if v.cache != nil && v.cache_free != nil {
		v.cache_free(v.cache, v.allocator)
	}
	for &s in v.segs {
		delete(s.ids)
		delete(s.vmap)
		delete(s.extra)
	}
	delete(v.segs)
	delete(v.want)
	delete(v.unknown)
	v^ = {}
}

view_find :: proc "contextless" (v: ^View, id: prim.Id) -> int {
	for s, i in v.segs {
		if s.id == id {
			return i
		}
	}
	return -1
}

view_add :: proc(v: ^View, id: prim.Id, jr: ^journal.Reader) -> (index: int, err: Error) {
	if i := view_find(v, id); i >= 0 {
		v.segs[i].jr = jr
		v.segs[i].tail_end = -1
		v.segs[i].table_at = -1
		return i, .None
	}
	if len(v.segs) >= MAX_SEGS {
		return -1, .Limit
	}
	s := View_Seg{
		id       = id,
		jr       = jr,
		ids      = make([dynamic]prim.Id, v.allocator),
		vmap     = make([dynamic]int, v.allocator),
		extra    = make([dynamic]u8, v.allocator),
		table_at = -1,
		tail_end = -1,
	}
	if _, e := append(&v.segs, s); e != nil {
		return -1, .No_Memory
	}
	for &o in v.segs {
		o.table_at = -1
	}
	return len(v.segs) - 1, .None
}

view_reset :: proc(v: ^View) {
	clear(&v.want)
	clear(&v.unknown)
	v.pass += 1
}

view_wanted :: proc(v: ^View) -> []Want {
	if len(v.want) < 2 {
		return v.want[:]
	}
	slice.sort_by(v.want[:], proc(a, b: Want) -> bool {
		if a.seg != b.seg {
			return id_less(a.seg, b.seg)
		}
		return a.from < b.from
	})
	n := 1
	for i in 1 ..< len(v.want) {
		cur := v.want[i]
		top := &v.want[n - 1]
		if cur.seg == top.seg && cur.from <= top.to {
			top.to = max(top.to, cur.to)
		} else {
			v.want[n] = cur
			n += 1
		}
	}
	resize(&v.want, n)
	return v.want[:]
}

view_ends :: proc(v: ^View, out: ^[dynamic]i64) {
	clear(out)
	for s in 0 ..< len(v.segs) {
		append(out, end(v, s))
	}
}

view_unknown :: proc(v: ^View) -> []prim.Id {
	return v.unknown[:]
}

rid :: proc "contextless" (v: ^View, r: Vref) -> Rid {
	if vref_none(r) || r.seg < 0 || r.seg >= len(v.segs) {
		return {}
	}
	return Rid{v.segs[r.seg].id, r.off}
}

vref :: proc(v: ^View, m: Rid) -> (r: Vref, err: Error) {
	if rid_none(m) {
		return {}, .None
	}
	i := view_find(v, m.seg)
	if i < 0 {
		unknown(v, m.seg)
		return {}, .Unknown_Segment
	}
	return Vref{i, m.off}, .None
}

seg_id :: proc "contextless" (v: ^View, r: Vref) -> prim.Id {
	if r.seg < 0 || r.seg >= len(v.segs) {
		return {}
	}
	return v.segs[r.seg].id
}

vref_less :: proc "contextless" (v: ^View, a, b: Vref) -> bool {
	ai, bi := seg_id(v, a), seg_id(v, b)
	if ai != bi {
		return id_less(ai, bi)
	}
	return a.off < b.off
}

unknown :: proc(v: ^View, id: prim.Id) {
	for u in v.unknown {
		if u == id {
			return
		}
	}
	append(&v.unknown, id)
}

end :: proc(v: ^View, s: int) -> i64 {
	jr := v.segs[s].jr
	if jr == nil {
		return 0
	}
	return journal.reader_end(jr)
}

want :: proc(v: ^View, s: int, from, to: i64) {
	a := max(from, 0)
	b := to
	if b <= a {
		return
	}
	append(&v.want, Want{v.object, v.segs[s].id, a, b})
}

want_chain :: proc(v: ^View, s: int, floor: i64, above: i64) {
	sg := &v.segs[s]
	if sg.stride < TAIL_GUESS {
		sg.stride = TAIL_GUESS
		sg.grown = v.pass
	} else if sg.grown != v.pass {
		sg.stride = min(sg.stride * 2, CHAIN_MAX)
		sg.grown = v.pass
	}
	want(v, s, max(floor, above - sg.stride), above)
}

get :: proc(v: ^View, s: int, off: i64, hint_from: i64 = -1, hint_to: i64 = 0) -> (body: []u8, next: i64, err: Error) {
	jr := v.segs[s].jr
	if jr == nil {
		return nil, off, .Unknown_Segment
	}
	if off >= journal.reader_end(jr) {
		want(v, s, off, off + MSG_GUESS)
		return nil, off, .Missing
	}
	b, n, je := jrec_at(jr, off)
	if je == .Missing {
		from := off if hint_from < 0 else min(hint_from, off)
		to := max(hint_to, jr.missing.to, off + MSG_GUESS)
		want(v, s, min(from, jr.missing.from), to)
		return nil, off, .Missing
	}
	if je != .None {
		return nil, off, jerr(je)
	}
	return b, n, .None
}

get_before :: proc(v: ^View, s: int, off: i64, after: i64, hint_from: i64 = -1) -> (body: []u8, next: i64, err: Error) {
	jr := v.segs[s].jr
	if jr != nil && after > off && after - off <= BACK_SCAN && after <= journal.reader_end(jr) {
		e := after
		for {
			b, o, je := jrec_before(jr, e)
			if je == .Missing {
				from := off if hint_from < 0 else min(hint_from, off)
				want(v, s, min(from, jr.missing.from), max(after, jr.missing.to))
				return nil, off, .Missing
			}
			if je != .None || o < off {
				break
			}
			if o == off {
				return b, e, .None
			}
			e = o
		}
	}
	return get(v, s, off, hint_from, after if after - off <= TAIL_GUESS else 0)
}

record_before :: proc(v: ^View, s: int, end_off: i64) -> (body: []u8, off: i64, err: Error) {
	b, o, je := jrec_before(v.segs[s].jr, end_off)
	if je == .Missing {
		want(v, s, max(end_off - TAIL_GUESS, 0), end_off)
		return nil, end_off, .Missing
	}
	if je != .None {
		return nil, end_off, jerr(je)
	}
	return b, o, .None
}

envelope :: proc(v: ^View, s: int, off: i64, after: i64 = 0) -> (env: Envelope, redacted: bool, err: Error) {
	body: []u8
	if after > off {
		body, _ = get_before(v, s, off, after) or_return
	} else {
		body, _ = get(v, s, off) or_return
	}
	if is_redacted(body) {
		return Envelope{off = off}, true, .None
	}
	env = decode_envelope(body, off) or_return
	return env, false, .None
}

tail :: proc(v: ^View, s: int) -> (sg: ^View_Seg, ok: bool, err: Error) {
	sg = &v.segs[s]
	e := end(v, s)
	if e == 0 {
		sg.tail_end = 0
		sg.links = {}
		clear(&sg.extra)
		return sg, false, .None
	}
	if sg.tail_end == e {
		return sg, sg.last > 0, .None
	}
	pos := e
	for pos > 0 {
		body, off, je := jrec_before(sg.jr, pos)
		if je == .Missing {
			want(v, s, pos - suggested_tail(pos), pos)
			return sg, false, .Missing
		}
		if je != .None {
			return sg, false, jerr(je)
		}
		if is_redacted(body) || is_sig(body) {
			pos = off
			continue
		}
		env := decode_envelope(body, off) or_return
		sg.links = env.links
		clear(&sg.extra)
		append(&sg.extra, ..env.links.extra)
		sg.links.extra = sg.extra[:]
		sg.last = off
		sg.tail_end = e
		return sg, true, .None
	}
	sg.links = {}
	clear(&sg.extra)
	sg.last = 0
	sg.tail_end = e
	return sg, false, .None
}

table :: proc(v: ^View, s: int) -> Error {
	sg := &v.segs[s]
	if v.w != nil && s == v.w.seg {
		if sg.table_at == i64(len(v.w.ids)) && len(sg.vmap) == len(v.w.ids) {
			return .None
		}
		clear(&sg.ids)
		append(&sg.ids, ..v.w.ids[:])
		sg.table_at = i64(len(v.w.ids))
	} else {
		_, ok := tail(v, s) or_return
		at := sg.links.segs if ok else 0
		if sg.table_at == at && len(sg.vmap) > 0 {
			return .None
		}
		clear(&sg.ids)
		append(&sg.ids, sg.id)
		if at != 0 {
			env, red := envelope(v, s, at) or_return
			if red {
				return .Corrupt
			}
			decode_seg(&env, &sg.ids) or_return
		}
		sg.table_at = at
	}
	clear(&sg.vmap)
	for id in sg.ids {
		append(&sg.vmap, view_find(v, id) if !prim.id_is_zero(id) else -1)
	}
	return .None
}

resolve :: proc(v: ^View, s: int, r: Ref) -> (out: Vref, err: Error) {
	if ref_none(r) {
		return {}, .None
	}
	t := s
	if r.seg != 0 {
		table(v, s) or_return
		sg := &v.segs[s]
		if int(r.seg) >= len(sg.vmap) {
			return {}, .Corrupt
		}
		t = sg.vmap[r.seg]
		if t < 0 {
			unknown(v, sg.ids[r.seg])
			return {}, .Unknown_Segment
		}
	}
	if r.off >= end(v, t) {
		want(v, t, r.off, r.off + MSG_GUESS)
		return {}, .Missing
	}
	return Vref{t, r.off}, .None
}

Walk :: struct {
	next:     i64,
	above:    i64,
	floor:    prim.Hlc,
	base:     i64,
	base_hlc: prim.Hlc,
	started:  bool,
	done:     bool,
}

walk_events :: proc(v: ^View, s: int, floor: prim.Hlc, data: rawptr, visit: Visit) -> Error {
	w: Walk
	return walk_resume(v, s, &w, floor, data, visit)
}

walk_resume :: proc(v: ^View, s: int, w: ^Walk, floor: prim.Hlc, data: rawptr, visit: Visit) -> Error {
	if w.done || (w.started && w.floor <= floor) {
		return .None
	}
	if !w.started {
		sg, ok := tail(v, s) or_return
		if !ok {
			w.done = true
			return .None
		}
		w.next = sg.links.event
		w.above = sg.tail_end
		w.floor = max(prim.Hlc)
		w.started = true
	}
	for w.next != 0 {
		e := w.next
		body, _, ge := get_before(v, s, e, w.above)
		if ge == .Missing {
			if w.base > 0 && floor <= w.base_hlc && w.base < w.above {
				want(v, s, w.base, w.above)
			} else {
				want_chain(v, s, w.base, w.above)
			}
			return .Missing
		}
		if ge != .None {
			return ge
		}
		if is_redacted(body) {
			w.next = scan_prev_event(v, s, e) or_return
			w.above = e
			continue
		}
		own := clone_bytes(body, v.scratch) or_return
		env := decode_envelope(own, e) or_return
		if !links_is_event(&env.links) || env.links.prev >= e {
			return .Corrupt
		}
		if env.links.stamp < floor {
			w.floor = floor
			return .None
		}
		stop := visit(data, s, e, &env) or_return
		w.above = e
		w.next = env.links.prev
		if stop {
			w.next = 0
		}
	}
	w.done = true
	w.floor = 0
	return .None
}

scan_prev_event :: proc(v: ^View, s: int, from: i64) -> (prev: i64, err: Error) {
	pos := from
	for pos > 0 {
		b, o := record_before(v, s, pos) or_return
		if !is_redacted(b) && !is_sig(b) {
			env, e := decode_envelope(b, o)
			if e == .None && links_is_event(&env.links) {
				return o, .None
			}
		}
		pos = o
	}
	return 0, .None
}

clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> ([]u8, Error) {
	if len(b) == 0 {
		return nil, .None
	}
	out, err := make([]u8, len(b), allocator)
	if err != nil {
		return nil, .No_Memory
	}
	copy(out, b)
	return out, .None
}

clone_str :: proc(s: string, allocator: runtime.Allocator) -> (string, Error) {
	b, err := clone_bytes(transmute([]u8)s, allocator)
	return string(b), err
}
