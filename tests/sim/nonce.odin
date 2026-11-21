package sim

import "base:intrinsics"
import "core:fmt"
import "core:slice"
import "../../src/journal"
import "../../src/prim"
import osync "../../src/sync"

FRAME_HEADER :: 5
KIND_APPEND :: 0x03
KIND_FILL :: 0x12
KIND_SERVE :: 0x14
KIND_DATA :: 0x85
KIND_SERVED :: 0x98
APPEND_FIXED :: 32 + 8
FILL_FIXED :: 32 + 8
DATA_FIXED :: 32 + 8 + 8
SERVE_FIXED :: 16 + 8 + 32 + 8 + 8
SERVE_STREAM :: 24
SERVE_AT :: 56
REC_OVERHEAD :: journal.OVERHEAD
INJECT_AFTER :: 24

Tap :: struct {
	buf: [dynamic]u8,
	gen: u64,
}

Cipher_Image :: struct {
	data:   [dynamic]u8,
	have:   [dynamic]bool,
	starts: map[i64]bool,
}

Cipher_Source :: enum u8 {
	Append,
	Fill,
	Serve,
	Served,
	Data,
	Relay_Storage,
}

Cipher_Inject :: enum u8 {
	None,
	Append,
	Served,
	Relay_Storage,
}

Cipher_Pending :: struct {
	stream: osync.Stream_Id,
	off:    i64,
	old:    []u8,
	new:    []u8,
	src:    Cipher_Source,
	who:    string,
}

Cipher_Watch :: struct {
	images:   map[osync.Stream_Id]^Cipher_Image,
	pending:  [dynamic]Cipher_Pending,
	checked:  u64,
	reused:   u64,
	frames:   [Cipher_Source]u64,
	inject:   Cipher_Inject,
	seen:     int,
	injected: bool,
	want:     osync.Stream_Id,
	want_at:  i64,
}

cipher_init :: proc(w: ^World) {
	w.cipher.images = make(map[osync.Stream_Id]^Cipher_Image, w.allocator)
	w.cipher.pending = make([dynamic]Cipher_Pending, w.allocator)
	w.cipher.inject = Cipher_Inject(env_u64("SIM_INJECT_REUSE", 0) % len(Cipher_Inject))
}

cipher_destroy :: proc(w: ^World) {
	for _, im in w.cipher.images {
		delete(im.data)
		delete(im.have)
		delete(im.starts)
		free(im, w.allocator)
	}
	delete(w.cipher.images)
	for p in w.cipher.pending {
		delete(p.old, w.allocator)
		delete(p.new, w.allocator)
		delete(p.who, w.allocator)
	}
	delete(w.cipher.pending)
}

tap_feed :: proc(w: ^World, c: ^Conn, t: ^Tap, bytes: []u8, down: bool) {
	if t.gen != c.gen {
		clear(&t.buf)
		t.gen = c.gen
	}
	append(&t.buf, ..bytes)
	pos := 0
	for len(t.buf) - pos >= FRAME_HEADER {
		n := int(prim.get_u32le(t.buf[pos:pos + 4]))
		if len(t.buf) - pos < FRAME_HEADER + n {
			break
		}
		kind := t.buf[pos + 4]
		payload := t.buf[pos + FRAME_HEADER:pos + FRAME_HEADER + n]
		pos += FRAME_HEADER + n
		_frame(w, c, kind, payload, down)
	}
	remove_range(&t.buf, 0, pos)
}

@(private = "file")
_frame :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8, down: bool) {
	sid: osync.Stream_Id
	at: i64
	body: []u8
	src: Cipher_Source
	switch {
	case !down && kind == KIND_APPEND && len(payload) >= APPEND_FIXED:
		copy(sid[:], payload[:32])
		at, body, src = i64(prim.get_u64le(payload[32:40])), payload[APPEND_FIXED:], .Append
	case !down && kind == KIND_FILL && len(payload) >= FILL_FIXED:
		copy(sid[:], payload[:32])
		at, body, src = i64(prim.get_u64le(payload[32:40])), payload[FILL_FIXED:], .Fill
	case !down && kind == KIND_SERVE && len(payload) >= SERVE_FIXED:
		copy(sid[:], payload[SERVE_STREAM:SERVE_STREAM + 32])
		at, body, src = i64(prim.get_u64le(payload[SERVE_AT:SERVE_AT + 8])), payload[SERVE_FIXED:], .Serve
	case down && kind == KIND_SERVED && len(payload) >= SERVE_FIXED && !w.cfg.byzantine:
		copy(sid[:], payload[SERVE_STREAM:SERVE_STREAM + 32])
		at, body, src = i64(prim.get_u64le(payload[SERVE_AT:SERVE_AT + 8])), payload[SERVE_FIXED:], .Served
	case down && kind == KIND_DATA && len(payload) >= DATA_FIXED && !w.cfg.byzantine:
		copy(sid[:], payload[:32])
		at, body, src = i64(prim.get_u64le(payload[32:40])), payload[DATA_FIXED:], .Data
	case:
		return
	}
	if !cipher_observe(w, sid, at, body, src, c.node.name) {
		return
	}
	want := Cipher_Inject.Append if src == .Append else Cipher_Inject.Served if src == .Served else Cipher_Inject.None
	if want != .None && w.cipher.inject == want {
		_inject(w, sid, at, body, src)
	}
}

@(private = "file")
_inject :: proc(w: ^World, sid: osync.Stream_Id, at: i64, body: []u8, src: Cipher_Source) {
	if w.cipher.injected || at == 0 || _bounds(body) <= 0 {
		return
	}
	w.cipher.seen += 1
	if w.cipher.seen < INJECT_AFTER {
		return
	}
	n := int(prim.get_u32le(body[:4]))
	if n == 0 {
		return
	}
	forged := slice.clone(body, context.temp_allocator)
	forged[journal.HEADER] ~= 0x5a
	w.cipher.injected = true
	w.cipher.want = sid
	w.cipher.want_at = at
	world_note(w, "crypto: injected a second ciphertext for stream %s record at offset %d (len %d) via %v", stream_short(sid), at, n, src)
	cipher_observe(w, sid, at, forged, src, "injected")
}

@(private = "file")
_bounds :: proc(bytes: []u8) -> int {
	pos := 0
	for len(bytes) - pos >= REC_OVERHEAD {
		n := int(prim.get_u32le(bytes[pos:pos + 4]))
		if n > journal.MAX_BODY || n + REC_OVERHEAD > len(bytes) - pos || int(prim.get_u32le(bytes[pos + journal.HEADER + n:])) != n {
			break
		}
		blank := true
		for b in bytes[pos + 4:pos + journal.HEADER] {
			if b != 0 {
				blank = false
				break
			}
		}
		if blank {
			break
		}
		pos += n + REC_OVERHEAD
	}
	return pos
}

@(private = "file")
_image :: proc(w: ^World, sid: osync.Stream_Id) -> ^Cipher_Image {
	if im, ok := w.cipher.images[sid]; ok {
		return im
	}
	im := new(Cipher_Image, w.allocator)
	im.data = make([dynamic]u8, w.allocator)
	im.have = make([dynamic]bool, w.allocator)
	im.starts = make(map[i64]bool, w.allocator)
	im.starts[0] = true
	w.cipher.images[sid] = im
	return im
}

@(private = "file")
_mark_starts :: proc(im: ^Cipher_Image, at: i64, bytes: []u8) {
	pos := 0
	for pos < len(bytes) {
		im.starts[at + i64(pos)] = true
		pos += int(prim.get_u32le(bytes[pos:pos + 4])) + REC_OVERHEAD
	}
	im.starts[at + i64(pos)] = true
}

@(private = "file")
_record_of :: proc(im: ^Cipher_Image, off: i64) -> (start: i64, length: int, ok: bool) {
	best := i64(-1)
	for s in im.starts {
		if s <= off && s > best {
			best = s
		}
	}
	if best < 0 || best + 4 > i64(len(im.data)) {
		return 0, 0, false
	}
	for k in best ..< best + 4 {
		if !im.have[k] {
			return 0, 0, false
		}
	}
	n := int(prim.get_u32le(im.data[best:best + 4]))
	if off >= best + i64(n) + REC_OVERHEAD {
		return 0, 0, false
	}
	return best, n, true
}

@(private = "file")
_is_redacted_form :: proc(start: i64, n: int, at: i64, bytes: []u8) -> bool {
	tag := journal.redacted_tag(start, n)
	for b, i in bytes {
		rel := at + i64(i) - start
		switch {
		case rel >= 4 && rel < journal.HEADER:
			if b != tag[rel - 4] {
				return false
			}
		case rel >= journal.HEADER && rel < journal.HEADER + i64(n):
			if b != 0 {
				return false
			}
		}
	}
	return true
}

cipher_observe :: proc(w: ^World, sid: osync.Stream_Id, at: i64, raw: []u8, src: Cipher_Source, who: string) -> (records: bool) {
	if at < 0 || reserved_stream(sid) {
		return false
	}
	bytes := raw[:_bounds(raw)]
	if len(bytes) == 0 {
		return false
	}
	w.cipher.frames[src] += 1
	im := _image(w, sid)
	end := at + i64(len(bytes))
	if i64(len(im.data)) < end {
		resize(&im.data, int(end))
		resize(&im.have, int(end))
	}
	_mark_starts(im, at, bytes)
	w.cipher.checked += u64(len(bytes))
	i := 0
	for i < len(bytes) {
		pos := at + i64(i)
		if !im.have[pos] || im.data[pos] == bytes[i] {
			i += 1
			continue
		}
		j := i
		for j < len(bytes) && im.have[at + i64(j)] && im.data[at + i64(j)] != bytes[j] {
			j += 1
		}
		_conflict(w, im, sid, pos, im.data[pos:at + i64(j)], bytes[i:j], src, who)
		i = j
	}
	for b, k in bytes {
		im.data[at + i64(k)] = b
		im.have[at + i64(k)] = true
	}
	return true
}

@(private = "file")
_conflict :: proc(w: ^World, im: ^Cipher_Image, sid: osync.Stream_Id, off: i64, old: []u8, new: []u8, src: Cipher_Source, who: string) {
	start, n, known := _record_of(im, off)
	if known {
		_judge(w, sid, start, n, off, old, new, src, who)
		return
	}
	p := Cipher_Pending{stream = sid, off = off, src = src}
	p.old = slice.clone(old, w.allocator)
	p.new = slice.clone(new, w.allocator)
	p.who = clone_str(who, w.allocator)
	append(&w.cipher.pending, p)
}

@(private = "file")
_judge :: proc(w: ^World, sid: osync.Stream_Id, start: i64, n: int, off: i64, old: []u8, new: []u8, src: Cipher_Source, who: string) {
	if _is_redacted_form(start, n, off, new) || _is_redacted_form(start, n, off, old) {
		return
	}
	w.cipher.reused += 1
	world_fail(w, "crypto: nonce reuse: stream %s, record at offset %d (len %d) seen with two different ciphertexts; bytes %d..%d differ, second copy from a %v frame of %s", stream_short(sid), start, n, off, off + i64(len(new)), src, who)
}

cipher_resolve :: proc(w: ^World) {
	f := w.cipher.frames
	world_note(w, "crypto: compared %d ciphertext bytes on %d streams from %d Append, %d Fill, %d Serve, %d Served, %d Data frames and %d relay streams; %d deferred comparisons", w.cipher.checked, len(w.cipher.images), f[.Append], f[.Fill], f[.Serve], f[.Served], f[.Data], f[.Relay_Storage], len(w.cipher.pending))
	for p in w.cipher.pending {
		im := w.cipher.images[p.stream]
		start, n, known := _record_of(im, p.off)
		if !known {
			world_fail(w, "crypto: stream %s carried two different ciphertexts at offset %d (%d bytes, second from a %v frame of %s) and no record boundary covering it was ever observed", stream_short(p.stream), p.off, len(p.new), p.src, p.who)
			continue
		}
		_judge(w, p.stream, start, n, p.off, p.old, p.new, p.src, p.who)
	}
	if w.cipher.inject != .None {
		if !w.cipher.injected {
			world_fail(w, "crypto: SIM_INJECT_REUSE=%d found no %v frame to inject into", u8(w.cipher.inject), w.cipher.inject)
		} else if w.cipher.reused == 0 {
			world_fail(w, "crypto: the injected ciphertext reuse on stream %s at offset %d was NOT detected", stream_short(w.cipher.want), w.cipher.want_at)
		}
	}
}

cipher_scan_relay :: proc(w: ^World) {
	rn := &w.relay
	if !rn.alive {
		return
	}
	context = instance_context(&rn.inst)
	defer relay_after(rn)
	r := &rn.r
	st := r.store
	spaces := make([dynamic]prim.Id, context.temp_allocator)
	for id in r.spaces {
		append(&spaces, id)
	}
	slice.sort_by(spaces[:], id_less)
	for space in spaces {
		sp := r.spaces[space]
		if sp.ns == nil {
			continue
		}
		it, _, lerr := st.list_begin(st.data, sp.ns, 0)
		if lerr != .None {
			continue
		}
		ids := make([dynamic]osync.Stream_Id, context.temp_allocator)
		for {
			id, ok := st.list_next(st.data, it)
			if !ok {
				break
			}
			if !reserved_stream(id) && id in w.cipher.images {
				append(&ids, id)
			}
		}
		st.list_end(st.data, it)
		slice.sort_by(ids[:], proc(a, b: osync.Stream_Id) -> bool {
			x, y := a, b
			return string(x[:]) < string(y[:])
		})
		for id in ids {
			sh, length, serr := st.stream_open(st.data, sp.ns, id, false)
			if serr != .None || sh == nil {
				continue
			}
			base := clamp(stream_base_of(st, sh), 0, length)
			buf := make([]u8, length - base, context.temp_allocator)
			got, rerr := st.stream_read(st.data, sh, base, buf)
			st.stream_close(st.data, sh)
			if rerr != .None || got <= 0 {
				continue
			}
			data := buf[:got]
			if w.cipher.inject == .Relay_Storage && !w.cipher.injected && len(data) > REC_OVERHEAD && prim.get_u32le(data[:4]) > 0 {
				data[journal.HEADER] ~= 0x5a
				w.cipher.injected = true
				w.cipher.want = id
				w.cipher.want_at = base
				world_note(w, "crypto: injected a different relay-stored ciphertext for stream %s record at offset %d", stream_short(id), base)
			}
			cipher_observe(w, id, base, data, .Relay_Storage, "relay storage")
		}
	}
}

stream_base_of :: proc(st: osync.Relay_Storage, sh: rawptr) -> i64 {
	when intrinsics.type_has_field(osync.Relay_Storage, "stream_base") {
		return st.stream_base(st.data, sh)
	} else {
		return 0
	}
}

stream_short :: proc(sid: osync.Stream_Id) -> string {
	s := sid
	d, x: [16]u8
	prim.hex_encode(d[:], s[0:8])
	prim.hex_encode(x[:], s[16:24])
	return fmt.tprintf("%s/%s", string(d[:]), string(x[:]))
}

clone_str :: proc(s: string, allocator := context.allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

reserved_stream :: proc(sid: osync.Stream_Id) -> bool {
	for i in 0 ..< 16 {
		if sid[i] != 0xff {
			return false
		}
	}
	return true
}
