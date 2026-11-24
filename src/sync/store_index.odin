#+build linux, darwin, windows
package osync

import "core:fmt"
import "core:hash"
import "core:slice"
import "../prim"

TIER_INDEX_RECORD :: 80
TIER_WM_RECORD :: 16
TIER_WM_SLACK :: i64(64 << 10)

@(private)
TIER_INDEX_SIDE :: u8(1)

@(private)
TIER_INDEX_MARK :: u8(2)

@(private)
_tier_index_id :: proc(id: Stream_Id) -> (x: Stream_Id) {
	x = reserved_id(TIER_MANIFEST_TAG, 0)
	x[17] = TIER_INDEX_SIDE
	v := id
	h: [16]u8
	prim.put_u64le(h[:], hash.fnv64a(v[:]))
	prim.put_u64le(h[8:], hash.fnv64a(v[:], 0x9E3779B97F4A7C15))
	copy(x[18:32], h[:14])
	return
}

@(private)
_tier_wm_id :: proc "contextless" () -> (x: Stream_Id) {
	x = reserved_id(TIER_MANIFEST_TAG, 0)
	x[17] = TIER_INDEX_MARK
	return
}

@(private)
_tier_rec_id :: proc "contextless" (r: []u8) -> (id: Stream_Id) {
	copy(id[:], r[8:40])
	return
}

@(private)
_tier_indexed :: proc "contextless" (k: Tier_Kind) -> bool {
	return k == .Seg || k == .Evict || k == .Drop
}

@(private)
_tier_slot :: proc(rec: []u8, moff: i64) -> (s: [TIER_INDEX_RECORD]u8) {
	copy(s[:TIER_RECORD], rec[:TIER_RECORD])
	prim.put_u64le(s[64:], u64(moff))
	prim.put_u64le(s[72:], hash.fnv64a(s[:72]))
	return
}

@(private)
_tier_slot_ok :: proc(s: []u8) -> (moff: i64, ok: bool) {
	if len(s) < TIER_INDEX_RECORD || prim.get_u64le(s[72:]) != hash.fnv64a(s[:72]) {
		return 0, false
	}
	return i64(prim.get_u64le(s[64:])), true
}

@(private)
_tier_side_read :: proc(sp: ^Tier_Space, id: Stream_Id) -> (raw: []u8, ok: bool) {
	t := sp.t
	x := _tier_index_id(id)
	length, _, exists, perr := t.inner.stream_probe(t.inner.data, sp.ns, x)
	if perr != .None {
		return nil, false
	}
	if !exists || length == 0 {
		return nil, true
	}
	h, _, oerr := t.inner.stream_open(t.inner.data, sp.ns, x, false)
	if oerr != .None {
		return nil, false
	}
	defer t.inner.stream_close(t.inner.data, h)
	raw = make([]u8, int(length), context.temp_allocator)
	got, rerr := t.inner.stream_read(t.inner.data, h, 0, raw)
	t.index_reads += 1
	t.index_read_bytes += u64(max(got, 0))
	if rerr != .None || got != len(raw) {
		return nil, false
	}
	return raw, true
}

@(private)
_tier_man_range :: proc(sp: ^Tier_Space, from, to: i64) -> (raw: []u8, ok: bool) {
	t := sp.t
	if to <= from {
		return nil, true
	}
	raw = make([]u8, int(to - from), context.temp_allocator)
	got, err := t.inner.stream_read(t.inner.data, sp.man, from, raw)
	t.man_reads += 1
	t.man_read_bytes += u64(max(got, 0))
	return raw, err == .None && got == len(raw)
}

@(private)
_tier_stream_records :: proc(sp: ^Tier_Space, id: Stream_Id) -> (recs: []u8, ok: bool) {
	out := make([dynamic]u8, context.temp_allocator)
	want := id
	w := min(sp.idx_w, sp.man_len)
	side, sok := _tier_side_read(sp, id)
	if !sok {
		raw, mok := _tier_man_range(sp, 0, sp.man_len)
		if !mok {
			return nil, false
		}
		return _tier_filter(raw, id), true
	}
	for i := 0; i + TIER_INDEX_RECORD <= len(side); i += TIER_INDEX_RECORD {
		s := side[i:][:TIER_INDEX_RECORD]
		moff, valid := _tier_slot_ok(s)
		if !valid || moff >= w || !_tier_indexed(Tier_Kind(s[0])) || string(s[8:40]) != string(want[:]) {
			continue
		}
		append(&out, ..s[:TIER_RECORD])
	}
	tail, tok := _tier_man_range(sp, w, sp.man_len)
	if !tok {
		return nil, false
	}
	append(&out, .._tier_filter(tail, id))
	return out[:], true
}

@(private)
_tier_filter :: proc(raw: []u8, id: Stream_Id) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	want := id
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		if _tier_indexed(Tier_Kind(r[0])) && string(r[8:40]) == string(want[:]) {
			append(&out, ..r)
		}
	}
	return out[:]
}

@(private)
_tier_index_queue :: proc(sp: ^Tier_Space, raw: []u8, base: i64) {
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		if !_tier_indexed(Tier_Kind(r[0])) || _tier_reserved(cast([32]u8)_tier_rec_id(r)) {
			continue
		}
		s := _tier_slot(r, base + i64(i))
		append(&sp.idx_q, ..s[:])
	}
	sp.idx_next = max(sp.idx_next, base + i64(len(raw)))
}

@(private)
_tier_side_tail :: proc(sp: ^Tier_Space, h: rawptr, length: i64, w: i64) -> (last: i64, after: i64, ok: bool) {
	t := sp.t
	last = -1
	after = length % TIER_INDEX_RECORD
	end := length - after
	win := i64(8 * TIER_INDEX_RECORD)
	for end > 0 {
		from := max(end - win, 0)
		buf := make([]u8, int(end - from), context.temp_allocator)
		got, err := t.inner.stream_read(t.inner.data, h, from, buf)
		t.index_reads += 1
		t.index_read_bytes += u64(max(got, 0))
		if err != .None || got != len(buf) {
			return -1, 0, false
		}
		for k := len(buf) / TIER_INDEX_RECORD - 1; k >= 0; k -= 1 {
			moff, valid := _tier_slot_ok(buf[k * TIER_INDEX_RECORD:][:TIER_INDEX_RECORD])
			if !valid {
				after += TIER_INDEX_RECORD
				continue
			}
			if last < 0 {
				last = moff
			}
			if moff < w {
				return last, after, true
			}
			after += TIER_INDEX_RECORD
		}
		end = from
		win *= 2
	}
	return last, after, true
}

@(private)
_tier_index_load :: proc(sp: ^Tier_Space) -> Error {
	t := sp.t
	x := _tier_wm_id()
	length, _, exists, perr := t.inner.stream_probe(t.inner.data, sp.ns, x)
	if perr != .None {
		return perr
	}
	w, total: i64
	if exists && length >= TIER_WM_RECORD {
		h, _, oerr := t.inner.stream_open(t.inner.data, sp.ns, x, false)
		if oerr != .None {
			return oerr
		}
		last: [TIER_WM_RECORD]u8
		at := length - length % TIER_WM_RECORD - TIER_WM_RECORD
		got, rerr := t.inner.stream_read(t.inner.data, h, at, last[:])
		t.inner.stream_close(t.inner.data, h)
		if rerr != .None || got != TIER_WM_RECORD {
			return .Corrupt
		}
		w = i64(prim.get_u64le(last[:]))
		total = i64(prim.get_u64le(last[8:]))
	}
	if exists {
		sp.idx_mark = length
	}
	w = clamp(w - w % TIER_RECORD, 0, sp.man_len - sp.man_len % TIER_RECORD)
	sp.idx_w = w
	sp.idx_dw = w
	sp.idx_next = w
	sp.idx_len = total + sp.idx_mark
	if w >= sp.man_len {
		return .None
	}
	raw, ok := _tier_man_range(sp, w, sp.man_len)
	if !ok {
		return .Corrupt
	}
	seen := make(map[Stream_Id]bool, context.temp_allocator)
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		if !_tier_indexed(Tier_Kind(r[0])) {
			continue
		}
		id := _tier_rec_id(r)
		if _tier_reserved(cast([32]u8)id) {
			continue
		}
		sx := _tier_index_id(id)
		if seen[sx] {
			continue
		}
		seen[sx] = true
		slen, _, sexists, serr := t.inner.stream_probe(t.inner.data, sp.ns, sx)
		if serr != .None || !sexists || slen == 0 {
			continue
		}
		sh, _, soerr := t.inner.stream_open(t.inner.data, sp.ns, sx, false)
		if soerr != .None {
			continue
		}
		_, after, tok := _tier_side_tail(sp, sh, slen, w)
		t.inner.stream_close(t.inner.data, sh)
		if tok {
			sp.idx_len += after
		}
	}
	_tier_index_queue(sp, raw, w)
	return .None
}

@(private)
Tier_Index_Job :: struct {
	sp:     ^Tier_Space,
	upto:   i64,
	left:   int,
	failed: bool,
	bytes:  i64,
	slots:  [dynamic]u8,
}

@(private)
Tier_Index_Part :: struct {
	job: ^Tier_Index_Job,
	h:   rawptr,
	n:   i64,
}

@(private)
_tier_index_flush :: proc(sp: ^Tier_Space) {
	t := sp.t
	if sp.idx_busy || sp.idx_next <= sp.idx_w {
		return
	}
	if len(sp.idx_q) == 0 && sp.idx_next - sp.idx_dw < TIER_WM_SLACK {
		sp.idx_w = sp.idx_next
		return
	}
	j := new(Tier_Index_Job, t.allocator)
	j.sp = sp
	j.upto = sp.idx_next
	j.slots = sp.idx_q
	sp.idx_q = make([dynamic]u8, t.allocator)
	sp.idx_busy = true
	groups := make(map[Stream_Id][dynamic]u8, context.temp_allocator)
	sides := make([dynamic]Stream_Id, context.temp_allocator)
	for i := 0; i + TIER_INDEX_RECORD <= len(j.slots); i += TIER_INDEX_RECORD {
		s := j.slots[i:][:TIER_INDEX_RECORD]
		x := _tier_index_id(_tier_rec_id(s))
		g, had := groups[x]
		if !had {
			g = make([dynamic]u8, context.temp_allocator)
			append(&sides, x)
		}
		append(&g, ..s)
		groups[x] = g
	}
	slice.sort_by(sides[:], _mem_id_less)
	j.left = 1
	for x in sides {
		_tier_side_append(j, x, groups[x][:])
	}
	_tier_index_part_done(j, .None, 0)
}

@(private)
_tier_side_append :: proc(j: ^Tier_Index_Job, x: Stream_Id, slots: []u8) {
	sp := j.sp
	t := sp.t
	h, length, oerr := t.inner.stream_open(t.inner.data, sp.ns, x, true)
	if oerr != .None {
		j.failed = true
		return
	}
	last := i64(-1)
	pad := 0
	if length > 0 {
		l, _, ok := _tier_side_tail(sp, h, length, max(i64))
		if !ok {
			t.inner.stream_close(t.inner.data, h)
			j.failed = true
			return
		}
		last = l
		if r := int(length % TIER_INDEX_RECORD); r > 0 {
			pad = TIER_INDEX_RECORD - r
		}
	}
	body := make([dynamic]u8, context.temp_allocator)
	for k := 0; k < pad; k += 1 {
		append(&body, 0)
	}
	for i := 0; i + TIER_INDEX_RECORD <= len(slots); i += TIER_INDEX_RECORD {
		s := slots[i:][:TIER_INDEX_RECORD]
		if moff, _ := _tier_slot_ok(s); moff > last {
			append(&body, ..s)
		}
	}
	if len(body) == pad {
		t.inner.stream_close(t.inner.data, h)
		return
	}
	if pad > 0 {
		t.index_repairs += 1
	}
	w, berr := t.inner.append_begin(t.inner.data, h, length, i64(len(body)))
	if berr == .None {
		berr = t.inner.append_write(t.inner.data, w, body[:])
		if berr != .None {
			t.inner.append_abort(t.inner.data, w)
		}
	}
	if berr != .None {
		t.inner.stream_close(t.inner.data, h)
		j.failed = true
		return
	}
	pt := new(Tier_Index_Part, t.allocator)
	pt^ = {job = j, h = h, n = i64(len(body))}
	j.left += 1
	t.index_writes += 1
	t.inner.append_commit(t.inner.data, w, _tier_side_done, pt)
}

@(private)
_tier_side_done :: proc(ctx: rawptr, result: Error, value: i64) {
	pt := cast(^Tier_Index_Part)ctx
	j := pt.job
	t := j.sp.t
	t.inner.stream_close(t.inner.data, pt.h)
	n := pt.n
	free(pt, t.allocator)
	_tier_index_part_done(j, result, n)
}

@(private)
_tier_index_part_done :: proc(j: ^Tier_Index_Job, result: Error, n: i64) {
	sp := j.sp
	_tier_hold(sp)
	defer _tier_unhold(sp)
	if result != .None {
		j.failed = true
	} else {
		j.bytes += n
	}
	j.left -= 1
	if j.left > 0 {
		return
	}
	sp.usage += j.bytes
	sp.idx_len += j.bytes
	if j.failed {
		_tier_index_end(j, false)
		return
	}
	_tier_wm_write(j)
}

@(private)
_tier_wm_write :: proc(j: ^Tier_Index_Job) {
	sp := j.sp
	t := sp.t
	h, length, oerr := t.inner.stream_open(t.inner.data, sp.ns, _tier_wm_id(), true)
	if oerr != .None {
		_tier_index_end(j, false)
		return
	}
	rec: [TIER_WM_RECORD]u8
	prim.put_u64le(rec[:], u64(j.upto))
	prim.put_u64le(rec[8:], u64(max(sp.idx_len - sp.idx_mark, 0)))
	pad := int(length % TIER_WM_RECORD)
	body := make([dynamic]u8, context.temp_allocator)
	if pad > 0 {
		for _ in 0 ..< TIER_WM_RECORD - pad {
			append(&body, 0)
		}
	}
	append(&body, ..rec[:])
	w, berr := t.inner.append_begin(t.inner.data, h, length, i64(len(body)))
	if berr == .None {
		berr = t.inner.append_write(t.inner.data, w, body[:])
		if berr != .None {
			t.inner.append_abort(t.inner.data, w)
		}
	}
	if berr != .None {
		t.inner.stream_close(t.inner.data, h)
		_tier_index_end(j, false)
		return
	}
	pt := new(Tier_Index_Part, t.allocator)
	pt^ = {job = j, h = h, n = i64(len(body))}
	t.inner.append_commit(t.inner.data, w, _tier_wm_done, pt)
}

@(private)
_tier_wm_done :: proc(ctx: rawptr, result: Error, value: i64) {
	pt := cast(^Tier_Index_Part)ctx
	j := pt.job
	sp := j.sp
	t := sp.t
	t.inner.stream_close(t.inner.data, pt.h)
	n := pt.n
	free(pt, t.allocator)
	_tier_hold(sp)
	defer _tier_unhold(sp)
	if result != .None {
		_tier_index_end(j, false)
		return
	}
	sp.usage += n
	sp.idx_len += n
	sp.idx_mark += n
	sp.idx_dw = max(sp.idx_dw, j.upto)
	_tier_index_end(j, true)
}

@(private)
_tier_index_end :: proc(j: ^Tier_Index_Job, ok: bool) {
	sp := j.sp
	t := sp.t
	if ok {
		sp.idx_w = max(sp.idx_w, j.upto)
		delete(j.slots)
	} else {
		rest := sp.idx_q
		sp.idx_q = j.slots
		append(&sp.idx_q, ..rest[:])
		delete(rest)
		t.index_failures += 1
	}
	free(j, t.allocator)
	sp.idx_busy = false
	if ok {
		_tier_index_flush(sp)
	}
}

tier_index_verify :: proc(t: ^Tier_Store, space: Space_Id, settled := false) -> string {
	h, _, err := _tier_ns_open(t, space)
	if err != .None {
		return fmt.tprintf("the space did not open: %v", err)
	}
	sp := cast(^Tier_Space)h
	defer _tier_ns_close(t, h)
	if settled && sp.idx_w < sp.man_len - sp.man_len % TIER_RECORD {
		return fmt.tprintf("the index stops at %d of a %d-byte manifest after it settled", sp.idx_w, sp.man_len)
	}
	raw, ok := _tier_man_range(sp, 0, sp.man_len)
	if !ok {
		return "the manifest did not read"
	}
	seen := make(map[Stream_Id]bool, context.temp_allocator)
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		if !_tier_indexed(Tier_Kind(r[0])) {
			continue
		}
		id := _tier_rec_id(r)
		if seen[id] || _tier_reserved(cast([32]u8)id) {
			continue
		}
		seen[id] = true
		want := _tier_filter(raw, id)
		got, gok := _tier_stream_records(sp, id)
		if !gok {
			return fmt.tprintf("stream %x: its index did not read", id[:4])
		}
		if string(got) != string(want) {
			return fmt.tprintf("stream %x: its index gives %d records, the manifest %d (watermark %d of %d)", id[:4], len(got) / TIER_RECORD, len(want) / TIER_RECORD, sp.idx_w, sp.man_len)
		}
	}
	return ""
}
