package engine

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fs"
import "../journal"
import "../prim"
import osync "../sync"

LIVE_BUFFER_MSG :: i64(osync.DRAFT_MSG_MAX - 1)

@(private)
LIVE_FRAME_V1 :: u8(1)

@(private)
LIVE_HEADER :: 1 + 16 + 8

@(private)
LIVE_TAG :: 16

@(private)
LIVE_FF_WINDOW :: 32

@(private)
Ovl :: struct {
	device: prim.Id,
	boot:   [16]u8,
	first:  crdt.Op_Id,
	n:      int,
	ops:    [dynamic]crdt.Delta_Op,
	seqs:   [dynamic]u64,
}

@(private)
_ovl_last :: proc(o: ^Ovl) -> crdt.Op_Id {
	return crdt.Op_Id{o.first.actor, o.first.seq + u64(o.n) - 1}
}

@(private)
_ops_own :: proc(e: ^Engine, src: []crdt.Delta_Op) -> [dynamic]crdt.Delta_Op {
	out := make([dynamic]crdt.Delta_Op, 0, len(src), e.allocator)
	for o in src {
		x := o
		if len(o.text) > 0 {
			t := make([]u8, len(o.text), e.allocator)
			copy(t, o.text)
			x.text = t
		}
		append(&out, x)
	}
	return out
}

@(private)
_ops_release :: proc(e: ^Engine, ops: ^[dynamic]crdt.Delta_Op) {
	for o in ops {
		if len(o.text) > 0 {
			delete(o.text, e.allocator)
		}
	}
	delete(ops^)
	ops^ = nil
}

@(private)
_ovl_free :: proc(e: ^Engine, o: ^Ovl) {
	_ops_release(e, &o.ops)
	delete(o.seqs)
	free(o, e.allocator)
}

@(private)
_ovl_anchor :: proc(b: ^Buffer, pos: int, bias: crdt.Bias) -> (a: Anchor, vpos: int, found: bool) {
	p := pos
	after := bias == .After
	#reverse for o in b.ovl {
		d, k := 0, 0
		for x in o.ops {
			switch x.kind {
			case .Retain:
				d += x.n
			case .Insert:
				q := p - 1 if after else p
				if q >= d && q < d + x.n {
					return Anchor{id = crdt.Op_Id{o.first.actor, o.seqs[k] + u64(q - d)}, bias = bias}, 0, true
				}
				d += x.n
				k += 1
			case .Delete:
			}
		}
		p = crdt.delta_untransform_pos(o.ops[:], p, !after, false)
	}
	return {}, p, false
}

@(private)
_ovl_resolve :: proc(b: ^Buffer, a: Anchor) -> (pos: int, found: bool) {
	for o, i in b.ovl {
		if a.id.actor != o.first.actor || a.id.seq < o.first.seq || a.id.seq >= o.first.seq + u64(o.n) {
			continue
		}
		d, k := 0, 0
		p := -1
		for x in o.ops {
			switch x.kind {
			case .Retain:
				d += x.n
			case .Insert:
				if a.id.seq >= o.seqs[k] && a.id.seq < o.seqs[k] + u64(x.n) {
					p = d + int(a.id.seq - o.seqs[k])
				}
				d += x.n
				k += 1
			case .Delete:
			}
			if p >= 0 {
				break
			}
		}
		if p < 0 {
			return 0, false
		}
		if a.bias == .After {
			p += 1
		}
		for later in b.ovl[i + 1:] {
			p = crdt.delta_transform_pos(later.ops[:], p, a.bias == .Before, false)
		}
		return p, true
	}
	return 0, false
}

@(private)
_bpush :: proc(out: ^[dynamic]crdt.Delta_Op, o: crdt.Delta_Op) {
	if o.n <= 0 {
		return
	}
	if n := len(out); n > 0 {
		l := &out[n - 1]
		if l.kind == o.kind && o.kind == .Retain {
			l.n += o.n
			return
		}
		if l.kind == o.kind && o.kind == .Delete {
			t := make([]u8, len(l.text) + len(o.text), context.temp_allocator)
			copy(t, l.text)
			copy(t[len(l.text):], o.text)
			l.n += o.n
			l.text = t
			return
		}
	}
	append(out, o)
}

@(private)
_btrim :: proc(ops: ^[dynamic]crdt.Delta_Op) {
	for len(ops) > 0 && ops[len(ops) - 1].kind == .Retain {
		pop(ops)
	}
}

@(private)
Bside :: struct {
	ops:  []crdt.Delta_Op,
	i:    int,
	used: int,
}

@(private)
_bpeek :: proc(s: ^Bside) -> (o: crdt.Delta_Op, rest: int, ok: bool) {
	if s.i >= len(s.ops) {
		return crdt.Delta_Op{kind = .Retain}, max(int), false
	}
	o = s.ops[s.i]
	return o, o.n - s.used, true
}

@(private)
_btake :: proc(s: ^Bside, k: int) -> crdt.Delta_Op {
	o := s.ops[s.i]
	part := o
	part.n = k
	if len(o.text) > 0 {
		part.text = o.text[s.used:s.used + k]
	}
	s.used += k
	if s.used >= o.n {
		s.i += 1
		s.used = 0
	}
	return part
}

@(private)
_bcompose :: proc(a, b: []crdt.Delta_Op) -> [dynamic]crdt.Delta_Op {
	out := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	sa := Bside{ops = a}
	sb := Bside{ops = b}
	for {
		oa, ra, ha := _bpeek(&sa)
		ob, rb, hb := _bpeek(&sb)
		if !ha && !hb {
			break
		}
		if ha && oa.kind == .Delete {
			_bpush(&out, _btake(&sa, ra))
			continue
		}
		if hb && ob.kind == .Insert {
			_bpush(&out, _btake(&sb, rb))
			continue
		}
		if !hb {
			_bpush(&out, _btake(&sa, ra))
			continue
		}
		if !ha {
			_bpush(&out, _btake(&sb, rb))
			continue
		}
		k := min(ra, rb)
		pa := _btake(&sa, k)
		pb := _btake(&sb, k)
		switch {
		case pa.kind == .Retain && pb.kind == .Retain:
			_bpush(&out, pa)
		case pa.kind == .Insert && pb.kind == .Retain:
			_bpush(&out, pa)
		case pa.kind == .Retain && pb.kind == .Delete:
			_bpush(&out, pb)
		case pa.kind == .Insert && pb.kind == .Delete:
		}
	}
	_btrim(&out)
	return out
}

@(private)
_binverse :: proc(d: []crdt.Delta_Op) -> [dynamic]crdt.Delta_Op {
	out := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	for o in d {
		switch o.kind {
		case .Retain:
			_bpush(&out, o)
		case .Insert:
			_bpush(&out, crdt.Delta_Op{kind = .Delete, n = o.n, text = o.text})
		case .Delete:
			_bpush(&out, crdt.Delta_Op{kind = .Insert, n = o.n, text = o.text})
		}
	}
	_btrim(&out)
	return out
}

@(private)
_bequal :: proc(a, b: []crdt.Delta_Op) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i].kind != b[i].kind || a[i].n != b[i].n || string(a[i].text) != string(b[i].text) {
			return false
		}
	}
	return true
}

@(private)
_regions_bytes :: proc(regions: []crdt.Delta_Region) -> [dynamic]crdt.Delta_Op {
	out := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	nw := 0
	for &r in regions {
		if r.new > nw {
			_bpush(&out, crdt.Delta_Op{kind = .Retain, n = r.new - nw})
		}
		if len(r.del) > 0 {
			_bpush(&out, crdt.Delta_Op{kind = .Delete, n = len(r.del), text = r.del})
		}
		added := 0
		for o in r.ins {
			_bpush(&out, crdt.Delta_Op{kind = .Insert, n = len(o.text), text = o.text, author = o.author})
			added += len(o.text)
		}
		nw = r.new + added
	}
	_btrim(&out)
	return out
}

@(private)
_ovl_on :: #force_inline proc "contextless" (b: ^Buffer) -> bool {
	return len(b.ovl) > 0
}

@(private)
_disp_len :: proc(b: ^Buffer) -> int {
	n := crdt.text_len(&b.view.text)
	for o in b.oc {
		switch o.kind {
		case .Insert:
			n += o.n
		case .Delete:
			n -= o.n
		case .Retain:
		}
	}
	return n
}

@(private)
_disp_read :: proc(b: ^Buffer, pos: int, dst: []u8) -> int {
	d, v, got := 0, 0, 0
	want := len(dst)
	emit :: proc(b: ^Buffer, dst: []u8, got: ^int, want: int, at: int, lo, hi: int, v_from: int, text: []u8) {
		if got^ >= want || hi <= at + got^ {
			return
		}
		s := max(lo, at + got^)
		if s >= hi {
			return
		}
		k := min(hi - s, want - got^)
		if text != nil {
			copy(dst[got^:got^ + k], text[s - lo:s - lo + k])
		} else {
			crdt.text_read(&b.view.text, v_from + (s - lo), dst[got^:got^ + k])
		}
		got^ += k
	}
	for o in b.oc {
		switch o.kind {
		case .Retain:
			emit(b, dst, &got, want, pos, d, d + o.n, v, nil)
			d += o.n
			v += o.n
		case .Insert:
			emit(b, dst, &got, want, pos, d, d + o.n, 0, o.text)
			d += o.n
		case .Delete:
			v += o.n
		}
	}
	vlen := crdt.text_len(&b.view.text)
	if v < vlen {
		emit(b, dst, &got, want, pos, d, d + (vlen - v), v, nil)
	}
	return got
}

@(private)
_disp_units_at :: proc(b: ^Buffer, pos: int) -> int {
	d, v, u := 0, 0, 0
	vunits :: proc(b: ^Buffer, from, to: int) -> int {
		return crdt.text_units_at(&b.view.text, to) - crdt.text_units_at(&b.view.text, from)
	}
	for o in b.oc {
		switch o.kind {
		case .Retain:
			if pos <= d + o.n {
				return u + vunits(b, v, v + (pos - d))
			}
			u += vunits(b, v, v + o.n)
			d += o.n
			v += o.n
		case .Insert:
			if pos <= d + o.n {
				return u + crdt.units(o.text[:pos - d])
			}
			u += crdt.units(o.text)
			d += o.n
		case .Delete:
			v += o.n
		}
	}
	return u + vunits(b, v, v + (pos - d))
}

@(private)
_disp_byte_at :: proc(b: ^Buffer, want: int) -> int {
	d, v, u := 0, 0, 0
	for o in b.oc {
		switch o.kind {
		case .Retain:
			ru := crdt.text_units_at(&b.view.text, v + o.n) - crdt.text_units_at(&b.view.text, v)
			if want <= u + ru {
				base := crdt.text_units_at(&b.view.text, v)
				return d + (crdt.text_byte_at(&b.view.text, base + (want - u)) - v)
			}
			u += ru
			d += o.n
			v += o.n
		case .Insert:
			iu := crdt.units(o.text)
			if want <= u + iu {
				k := 0
				for k < len(o.text) && crdt.units(o.text[:k]) < want - u {
					k += 1
				}
				return d + k
			}
			u += iu
			d += o.n
		case .Delete:
			v += o.n
		}
	}
	base := crdt.text_units_at(&b.view.text, v)
	return d + (crdt.text_byte_at(&b.view.text, base + (want - u)) - v)
}

@(private)
_disp_units :: proc(b: ^Buffer) -> int {
	return _disp_units_at(b, _disp_len(b))
}

@(private)
_disp_bytes :: proc(b: ^Buffer, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, _disp_len(b), allocator)
	_disp_read(b, 0, out)
	return out
}

@(private)
_bytes_to_units :: proc(b: ^Buffer, d: []crdt.Delta_Op, units_at: proc(b: ^Buffer, pos: int) -> int, on_target: bool) -> [dynamic]crdt.Delta_Op {
	out := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	p := 0
	for o in d {
		switch o.kind {
		case .Retain:
			n := o.n
			if _utf16(b) {
				n = units_at(b, p + o.n) - units_at(b, p)
			}
			crdt.delta_push(&out, crdt.Delta_Op{kind = .Retain, n = n})
			p += o.n
		case .Delete:
			crdt.delta_push(&out, crdt.Delta_Op{kind = .Delete, n = crdt.units(o.text) if _utf16(b) else o.n})
			if !on_target {
				p += o.n
			}
		case .Insert:
			crdt.delta_push(&out, crdt.Delta_Op{kind = .Insert, n = crdt.units(o.text) if _utf16(b) else o.n, text = o.text, author = o.author})
			if on_target {
				p += o.n
			}
		}
	}
	crdt.delta_trim(&out)
	return out
}

@(private)
_ovl_recompose :: proc(e: ^Engine, b: ^Buffer) {
	cur := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	for o in b.ovl {
		cur = _bcompose(cur[:], o.ops[:])
	}
	_ops_release(e, &b.oc)
	b.oc = _ops_own(e, cur[:])
}

@(private)
_ovl_clear :: proc(e: ^Engine, b: ^Buffer) {
	for o in b.ovl {
		_ovl_free(e, o)
	}
	clear(&b.ovl)
	_ops_release(e, &b.oc)
	_buffer_release_held(e, b)
}

@(private)
_buffer_release_held :: proc(e: ^Engine, b: ^Buffer) {
	if e.buffer_wakes == nil {
		e.buffer_wakes = make([dynamic]Ready, e.allocator)
	}
	for r in b.held {
		append(&e.buffer_wakes, r)
	}
	if len(b.held) > 0 {
		_touch(e)
	}
	clear(&b.held)
}

@(private)
_buffer_emit_ops :: proc(e: ^Engine, b: ^Buffer, ops: []crdt.Delta_Op, gone: []Gone = nil) {
	if len(ops) == 0 {
		return
	}
	b.rev += 1
	_sent_push(e, b, ops, gone)
	e.stats.buffer_deltas += 1
	if b.cb != nil {
		ev := Buffer_Event{kind = .Delta, buffer = b.id, rev = b.rev, ack = b.recv, length = _length(b), ops = ops}
		cb, data := b.cb, b.data
		{
			context = _outer(e)
			cb(data, e, &ev)
		}
	}
	if slice.contains(e.buffers[:], b) {
		_cursors_after_delta(e, b)
	}
}

@(private)
_view_units_at :: proc(b: ^Buffer, pos: int) -> int {
	return crdt.text_units_at(&b.view.text, pos)
}

@(private)
_ovl_drop :: proc(e: ^Engine, b: ^Buffer) {
	if !_ovl_on(b) {
		return
	}
	inv := _binverse(b.oc[:])
	saved := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	for o in inv {
		append(&saved, o)
	}
	gone := _gone_of(e, b, saved[:], _ovl_id_runs(b)[:])
	_ovl_clear(e, b)
	e.stats.buffer_live_dropped += 1
	ops := _bytes_to_units(b, saved[:], _view_units_at, true)
	_buffer_emit_ops(e, b, ops[:], gone[:])
}

@(private)
_ovl_advanced :: proc(e: ^Engine, b: ^Buffer, a: []crdt.Delta_Op) -> bool {
	if !_ovl_on(b) {
		return false
	}
	if len(a) == 0 {
		return true
	}
	ff := _log_frontier(b)
	acc := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	for o, j in b.ovl {
		acc = _bcompose(acc[:], o.ops[:])
		last := [1]crdt.Op_Id{_ovl_last(o)}
		if _ids_eq(ff, last[:]) && _bequal(acc[:], a) {
			for k in 0 ..= j {
				_ovl_free(e, b.ovl[k])
			}
			remove_range(&b.ovl, 0, j + 1)
			e.stats.buffer_live_confirmed += u64(j + 1)
			_ovl_recompose(e, b)
			if !_ovl_on(b) {
				_buffer_release_held(e, b)
			}
			return true
		}
	}
	fix := _bcompose(_binverse(b.oc[:])[:], a)
	gone := _gone_of(e, b, fix[:], _ovl_id_runs(b)[:])
	_ovl_clear(e, b)
	e.stats.buffer_live_dropped += 1
	ops := _bytes_to_units(b, fix[:], _view_units_at, true)
	_buffer_emit_ops(e, b, ops[:], gone[:])
	return true
}

@(private)
_ids_eq :: proc(a, b: []crdt.Op_Id) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x in a {
		na, nb := 0, 0
		for y in a {
			na += 1 if y == x else 0
		}
		for y in b {
			nb += 1 if y == x else 0
		}
		if na != nb {
			return false
		}
	}
	return true
}

@(private)
_file_frontier :: proc(b: ^Buffer) -> []crdt.Op_Id {
	if n := len(b.ovl); n > 0 {
		out := make([]crdt.Op_Id, 1, context.temp_allocator)
		out[0] = _ovl_last(b.ovl[n - 1])
		return out
	}
	return _log_frontier(b)
}

@(private)
_log_frontier :: proc(b: ^Buffer) -> []crdt.Op_Id {
	log := &b.view.log
	g := &b.hist.g
	cands := make([dynamic]crdt.Lv, context.temp_allocator)
	for i := len(log.entries) - 1; i >= 0 && len(cands) < LIVE_FF_WINDOW; i -= 1 {
		x := log.entries[i]
		append(&cands, x.lv + crdt.Lv(x.len) - 1)
	}
	out := make([dynamic]crdt.Op_Id, context.temp_allocator)
	outer: for c, i in cands {
		for d, k in cands {
			if k != i && d != c && crdt.graph_contains(g, []crdt.Lv{d}, c) {
				continue outer
			}
		}
		id := crdt.graph_id(g, c)
		dup := false
		for x in out {
			if x == id {
				dup = true
			}
		}
		if !dup {
			append(&out, id)
		}
	}
	slice.sort_by(out[:], crdt.op_id_less)
	return out[:]
}

@(private)
_live_aad :: proc(stream: osync.Stream_Id, object: prim.Id, hdr: []u8) -> []u8 {
	aad := make([]u8, len(stream) + len(object) + len(hdr), context.temp_allocator)
	s := stream
	o := object
	copy(aad, s[:])
	copy(aad[len(stream):], o[:])
	copy(aad[len(stream) + len(object):], hdr)
	return aad
}

@(private)
_buffer_live_send :: proc(e: ^Engine, b: ^Buffer, h: ^Handle, batch: ^crdt.Batch, off: i64, ff: []crdt.Op_Id, flen: int) {
	sp := h.sp
	if !sp.repl_on || e.cfg.buffer_live_off || !osync.replicator_live_on(&sp.repl) {
		return
	}
	body := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&body)
	prim.write_uvarint(&w, u64(len(ff)))
	for id in ff {
		prim.write_id(&w, id.actor)
		prim.write_uvarint(&w, id.seq)
	}
	prim.write_uvarint(&w, u64(flen))
	bb := make([dynamic]u8, context.temp_allocator)
	if crdt.batch_encode(batch, &bb, nil) != .None {
		return
	}
	append(&body, ..bb[:])
	if e.live_sent == nil {
		e.live_sent = make(map[prim.Id]i64, e.allocator)
	}
	if last, sent := e.live_sent[h.id]; !e.live_booted || (sent && off <= last) {
		random_fill(e, e.live_boot[:])
		e.live_booted = true
		clear(&e.live_sent)
	}
	e.live_sent[h.id] = off
	hdr: [LIVE_HEADER]u8
	hdr[0] = LIVE_FRAME_V1
	boot := e.live_boot
	copy(hdr[1:17], boot[:])
	prim.put_u64le(hdr[17:], u64(off))
	plain := sp.mode == .Transparent
	frame := make([]u8, LIVE_HEADER + len(body) + (0 if plain else LIVE_TAG), context.temp_allocator)
	copy(frame, hdr[:])
	if plain {
		copy(frame[LIVE_HEADER:], body[:])
	} else {
		if h.own_tree == nil {
			return
		}
		key, ok := osync.buffer_live_key(osync.keytree_provider(&h.own_tree.tree), off, e.live_boot)
		if !ok {
			return
		}
		defer crypto.zero_explicit(&key, size_of(key))
		ctx: chacha20poly1305.Context
		chacha20poly1305.init(&ctx, key[:])
		iv := journal.nonce(off)
		aad := _live_aad(osync.stream_id(&h.scope, e.self, h.name, 0), h.id, hdr[:])
		chacha20poly1305.seal(&ctx, frame[LIVE_HEADER:LIVE_HEADER + len(body)], frame[LIVE_HEADER + len(body):], iv[:], aad, body[:])
		chacha20poly1305.reset(&ctx)
	}
	if len(frame) > osync.LIVE_MAX {
		return
	}
	if osync.replicator_live_send(&sp.repl, &h.scope, h.name, 0, LIVE_BUFFER_MSG, off, frame) {
		e.stats.buffer_live_sent += 1
	}
}

@(private)
_buffer_live_rx :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	if e.cfg.buffer_live_off || len(ev.meta) < LIVE_HEADER || ev.meta[0] != LIVE_FRAME_V1 {
		return
	}
	scratch := virtual.arena_temp_begin(&e.temp)
	defer virtual.arena_temp_end(scratch)
	dev := osync.stream_device(ev.stream)
	if dev == e.self {
		return
	}
	h: ^Handle
	for _, x in e.handles {
		if x.sp == sp && (x.kind == .Text || x.kind == .File_Tree) && osync.stream_id(&x.scope, dev, x.name, 0) == ev.stream {
			h = x
			break
		}
	}
	if h == nil || h.hist == nil {
		return
	}
	has := false
	for b in e.buffers {
		if b.object.id == h.id {
			has = true
			break
		}
	}
	if !has {
		return
	}
	hdr := ev.meta[:LIVE_HEADER]
	boot: [16]u8
	copy(boot[:], hdr[1:17])
	off := i64(prim.get_u64le(hdr[17:]))
	if off != ev.from {
		return
	}
	if e.live_boots == nil {
		e.live_boots = make(map[prim.Id][16]u8, e.allocator)
	}
	if prev, seen := e.live_boots[dev]; seen && prev != boot {
		_buffers_live_drop_device(e, sp, dev)
	}
	e.live_boots[dev] = boot
	body: []u8
	if sp.mode == .Transparent {
		body = ev.meta[LIVE_HEADER:]
	} else {
		if len(ev.meta) < LIVE_HEADER + LIVE_TAG {
			return
		}
		rt, found := sp.remote_trees[ev.stream]
		if !found || !rt.loaded {
			return
		}
		key, ok := osync.buffer_live_key(osync.keytree_provider(&rt.tree), off, boot)
		if !ok {
			return
		}
		defer crypto.zero_explicit(&key, size_of(key))
		ct := ev.meta[LIVE_HEADER:len(ev.meta) - LIVE_TAG]
		tag := ev.meta[len(ev.meta) - LIVE_TAG:]
		out := make([]u8, len(ct), context.temp_allocator)
		ctx: chacha20poly1305.Context
		chacha20poly1305.init(&ctx, key[:])
		iv := journal.nonce(off)
		aad := _live_aad(ev.stream, h.id, hdr)
		okd := chacha20poly1305.open(&ctx, out, iv[:], aad, ct, tag)
		chacha20poly1305.reset(&ctx)
		if !okd {
			e.stats.buffer_live_rejected += 1
			return
		}
		body = out
	}
	r := prim.reader(body)
	nff := int(prim.read_uvarint(&r))
	if nff > LIVE_FF_WINDOW {
		return
	}
	ff := make([]crdt.Op_Id, nff, context.temp_allocator)
	for i in 0 ..< nff {
		ff[i].actor = prim.read_id(&r)
		ff[i].seq = prim.read_uvarint(&r)
	}
	flen := int(prim.read_uvarint(&r))
	if !prim.reader_ok(&r) {
		return
	}
	dec: crdt.Decoder
	crdt.decoder_init(&dec, context.temp_allocator)
	batch, derr := crdt.decode(&dec, body[len(body) - prim.reader_remaining(&r):], nil)
	if derr != .None || batch.actor == {} {
		return
	}
	e.stats.buffer_live_received += 1
	list := make([dynamic]^Buffer, context.temp_allocator)
	for b in e.buffers {
		if b.object.id == h.id {
			append(&list, b)
		}
	}
	for b in list {
		if slice.contains(e.buffers[:], b) {
			_ovl_apply(e, b, h, &batch, ff, flen, dev, boot)
		}
	}
}

@(private)
_ovl_apply :: proc(e: ^Engine, b: ^Buffer, h: ^Handle, batch: ^crdt.Batch, ff: []crdt.Op_Id, flen: int, dev: prim.Id, boot: [16]u8) {
	if b.hist != h.hist || b.view == nil || b.view.stale || len(batch.ops) == 0 {
		return
	}
	target := fs.inode_op(b.hist, b.inode)
	n := 0
	for r in batch.ops {
		if r.target != target || (r.kind != .Insert && r.kind != .Delete) {
			return
		}
		n += r.len
	}
	first := crdt.Op_Id{batch.actor, batch.seq}
	last := crdt.Op_Id{batch.actor, batch.seq + u64(n) - 1}
	if fs.history_contains(b.hist, b.version[:], last) {
		return
	}
	for o in b.ovl {
		if o.first == first {
			return
		}
	}
	if !_ids_eq(ff, _file_frontier(b)) || flen != _disp_len(b) {
		e.stats.buffer_live_skipped += 1
		return
	}
	d := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	seqs := make([dynamic]u64, context.temp_allocator)
	cur := batch.seq
	shift, consumed := 0, 0
	total := _disp_len(b)
	for r in batch.ops {
		dpos := r.pos - shift
		if dpos < consumed || dpos > total {
			return
		}
		#partial switch r.kind {
		case .Delete:
			if dpos + r.len > total {
				return
			}
			_bpush(&d, crdt.Delta_Op{kind = .Retain, n = dpos - consumed})
			c := make([]u8, r.len, context.temp_allocator)
			_disp_read(b, dpos, c)
			_bpush(&d, crdt.Delta_Op{kind = .Delete, n = r.len, text = c})
			consumed = dpos + r.len
			shift -= r.len
			cur += u64(r.len)
		case .Insert:
			if len(r.content) != r.len {
				return
			}
			_bpush(&d, crdt.Delta_Op{kind = .Retain, n = dpos - consumed})
			_bpush(&d, crdt.Delta_Op{kind = .Insert, n = r.len, text = r.content, author = batch.actor})
			append(&seqs, cur)
			consumed = dpos
			shift += r.len
			cur += u64(r.len)
		case:
			return
		}
	}
	_btrim(&d)
	ops := _bytes_to_units(b, d[:], _disp_units_at, false)
	o := new(Ovl, e.allocator)
	o.device = dev
	o.boot = boot
	o.first = first
	o.n = n
	o.ops = _ops_own(e, d[:])
	o.seqs = make([dynamic]u64, 0, len(seqs), e.allocator)
	append(&o.seqs, ..seqs[:])
	append(&b.ovl, o)
	_ovl_recompose(e, b)
	e.stats.buffer_live_applied += 1
	_buffer_emit_ops(e, b, ops[:])
}

@(private)
_buffers_live_drop_device :: proc(e: ^Engine, sp: ^Space, device: prim.Id) {
	scratch := virtual.arena_temp_begin(&e.temp)
	defer virtual.arena_temp_end(scratch)
	list := make([dynamic]^Buffer, context.temp_allocator)
	for b in e.buffers {
		if b.object.space != sp.id {
			continue
		}
		for o in b.ovl {
			if o.device == device {
				append(&list, b)
				break
			}
		}
	}
	for b in list {
		if slice.contains(e.buffers[:], b) {
			_ovl_drop(e, b)
		}
	}
}

@(private)
_buffer_live_follow :: proc(e: ^Engine, h: ^Handle, on: bool) {
	if !h.sp.repl_on || e.cfg.buffer_live_off || (h.kind != .Text && h.kind != .File_Tree) {
		return
	}
	for sg in h.segs {
		if sg.device == e.self || sg.live == on {
			continue
		}
		sg.live = on
		osync.replicator_live_follow(&h.sp.repl, &h.scope, sg.device, h.name, 0, on)
	}
}

@(private)
_buffers_wake :: proc(e: ^Engine) {
	if len(e.buffer_wakes) == 0 {
		return
	}
	list := e.buffer_wakes
	e.buffer_wakes = make([dynamic]Ready, e.allocator)
	for r in list {
		if r.call != nil {
			context = _outer(e)
			r.call(r.data, e, .None)
		}
	}
	delete(list)
}

@(private)
_buffer_hold :: proc(e: ^Engine, b: ^Buffer, ready: Ready) -> Error {
	if ready.call == nil {
		_ovl_drop(e, b)
		return .None
	}
	append(&b.held, ready)
	return .Pending
}

buffer_overlay :: proc(e: ^Engine, id: Buffer_Id) -> int {
	b := _buffer_find(e, id)
	if b == nil {
		return 0
	}
	return len(b.ovl)
}

@(private)
Gone :: struct {
	pos:  int,
	n:    int,
	id:   crdt.Op_Id,
	text: []u8,
}

@(private)
Id_Run :: struct {
	pos: int,
	n:   int,
	id:  crdt.Op_Id,
}

@(private)
_runs_cut :: proc(runs: ^[dynamic]Id_Run, at, n: int) {
	out := make([dynamic]Id_Run, 0, len(runs) + 1, context.temp_allocator)
	for r in runs {
		lo, hi := r.pos, r.pos + r.n
		switch {
		case hi <= at:
			append(&out, r)
		case lo >= at + n:
			append(&out, Id_Run{lo - n, r.n, r.id})
		case:
			if lo < at {
				append(&out, Id_Run{lo, at - lo, r.id})
			}
			if hi > at + n {
				append(&out, Id_Run{at, hi - (at + n), crdt.Op_Id{r.id.actor, r.id.seq + u64(at + n - lo)}})
			}
		}
	}
	runs^ = out
}

@(private)
_runs_open :: proc(runs: ^[dynamic]Id_Run, at, n: int, id: crdt.Op_Id) {
	out := make([dynamic]Id_Run, 0, len(runs) + 2, context.temp_allocator)
	placed := false
	for r in runs {
		lo, hi := r.pos, r.pos + r.n
		switch {
		case hi <= at:
			append(&out, r)
		case lo >= at:
			if !placed {
				append(&out, Id_Run{at, n, id})
				placed = true
			}
			append(&out, Id_Run{lo + n, r.n, r.id})
		case:
			append(&out, Id_Run{lo, at - lo, r.id})
			append(&out, Id_Run{at, n, id})
			placed = true
			append(&out, Id_Run{at + n, hi - at, crdt.Op_Id{r.id.actor, r.id.seq + u64(at - lo)}})
		}
	}
	if !placed {
		append(&out, Id_Run{at, n, id})
	}
	runs^ = out
}

@(private)
_ovl_id_runs :: proc(b: ^Buffer) -> [dynamic]Id_Run {
	runs := make([dynamic]Id_Run, context.temp_allocator)
	for o in b.ovl {
		c, k := 0, 0
		for op in o.ops {
			switch op.kind {
			case .Retain:
				c += op.n
			case .Delete:
				_runs_cut(&runs, c, op.n)
			case .Insert:
				if k < len(o.seqs) {
					_runs_open(&runs, c, op.n, crdt.Op_Id{o.first.actor, o.seqs[k]})
				}
				k += 1
				c += op.n
			}
		}
	}
	return runs
}

@(private)
_ovl_owns :: proc(b: ^Buffer, id: crdt.Op_Id, n: int) -> bool {
	if prim.id_is_zero(id.actor) {
		return false
	}
	for o in b.ovl {
		if o.first.actor == id.actor && id.seq >= o.first.seq && id.seq + u64(n) <= o.first.seq + u64(o.n) {
			return true
		}
	}
	return false
}

@(private)
_gone_of :: proc(e: ^Engine, b: ^Buffer, d: []crdt.Delta_Op, runs: []Id_Run) -> [dynamic]Gone {
	out := make([dynamic]Gone, context.temp_allocator)
	utf16 := _utf16(b)
	p, u, q := 0, 0, 0
	for o in d {
		switch o.kind {
		case .Retain:
			du := o.n
			if utf16 {
				du = _view_units_at(b, q + o.n) - _view_units_at(b, q)
			}
			p += o.n
			q += o.n
			u += du
		case .Insert:
			q += o.n
		case .Delete:
			for r in runs {
				s, t := max(p, r.pos), min(p + o.n, r.pos + r.n)
				if s >= t {
					continue
				}
				text := o.text[s - p:t - p]
				pos := u + (crdt.units(o.text[:s - p]) if utf16 else s - p)
				id := crdt.Op_Id{r.id.actor, r.id.seq + u64(s - r.pos)}
				if !_ovl_owns(b, id, t - s) {
					e.stats.buffer_live_bad_gone += 1
					continue
				}
				append(&out, Gone{pos, crdt.units(text) if utf16 else len(text), id, text})
			}
			p += o.n
			u += crdt.units(o.text) if utf16 else o.n
		}
	}
	return out
}

@(private)
_ubyte :: proc(text: []u8, u: int, utf16: bool) -> int {
	if !utf16 {
		return u
	}
	k, c := 0, 0
	for k < len(text) && c < u {
		x := text[k]
		l := 1 if x < 0x80 else 2 if x < 0xE0 else 3 if x < 0xF0 else 4
		c += 2 if l == 4 else 1
		k += l
	}
	return min(k, len(text))
}

@(private)
_gone_rebase :: proc(b: ^Buffer, gone: []Gone, cur: []crdt.Delta_Op) -> (kept: [dynamic]Gone, hit: [dynamic]Gone) {
	kept = make([dynamic]Gone, context.temp_allocator)
	hit = make([dynamic]Gone, context.temp_allocator)
	utf16 := _utf16(b)
	sub :: proc(g: Gone, lo, hi, shift: int, utf16: bool, out: ^[dynamic]Gone) {
		a := max(g.pos, lo) - g.pos
		z := min(g.pos + g.n, hi) - g.pos
		if a >= z {
			return
		}
		ba, bz := _ubyte(g.text, a, utf16), _ubyte(g.text, z, utf16)
		if ba >= bz {
			return
		}
		append(out, Gone{g.pos + a + shift, z - a, crdt.Op_Id{g.id.actor, g.id.seq + u64(ba)}, g.text[ba:bz]})
	}
	for g in gone {
		p, q := 0, 0
		for o in cur {
			n := crdt.op_units(o, utf16)
			switch o.kind {
			case .Retain:
				sub(g, p, p + n, q - p, utf16, &kept)
				p += n
				q += n
			case .Delete:
				sub(g, p, p + n, 0, utf16, &hit)
				p += n
			case .Insert:
				q += n
			}
		}
		sub(g, p, max(int), q - p, utf16, &kept)
	}
	return
}

@(private)
_gone_own :: proc(e: ^Engine, gone: []Gone) -> []Gone {
	if len(gone) == 0 {
		return nil
	}
	out := make([]Gone, len(gone), e.allocator)
	for g, i in gone {
		out[i] = g
		t := make([]u8, len(g.text), e.allocator)
		copy(t, g.text)
		out[i].text = t
	}
	return out
}

@(private)
_gone_free :: proc(e: ^Engine, gone: []Gone) {
	for g in gone {
		delete(g.text, e.allocator)
	}
	delete(gone, e.allocator)
}

