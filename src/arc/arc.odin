package arc

import "base:runtime"
import "core:c"
import "core:crypto/blake2b"
import "core:crypto/chacha20poly1305"
import "../journal"
import "../prim"
import "../zstd"

GROUP_KIND :: 1
SEAL_KIND :: 2
VERSION :: 1
GROUP_RAW :: 1024 * 1024
LEVEL :: 19
RECORD_LEVEL :: 3
SALT :: 16
TAG :: chacha20poly1305.TAG_SIZE
MAGIC :: 0xFD2FB528
STREAM_PREFIX :: "arc/"
SPAN_MAX :: i64(1) << 62
RAW_MAX :: i64(journal.MAX_BODY) * 2

Error :: enum u8 {
	None,
	Corrupt,
	No_Key,
	Forged,
	Too_Large,
	No_Memory,
}

Mode :: enum u8 {
	Plain  = 0,
	Sealed = 1,
}

Entry_Kind :: enum u8 {
	Body     = 0,
	Sig      = 1,
	Redacted = 2,
	Zipped   = 3,
}

Entry :: struct {
	kind:   Entry_Kind,
	off:    i64,
	len:    int,
	body:   []u8,
	commit: journal.Hash,
}

Group :: struct {
	arc_off:     i64,
	first:       i64,
	end:         i64,
	count:       int,
	head_before: journal.Hash,
	head_after:  journal.Hash,
	mode:        Mode,
	shift:       u8,
	salt:        [SALT]u8,
	header:      []u8,
	payload:     []u8,
}

Builder :: struct {
	first:       i64,
	pos:         i64,
	count:       int,
	zipped:      int,
	head_before: journal.Hash,
	head:        journal.Hash,
	meta:        [dynamic]u8,
	data:        [dynamic]u8,
	cctx:        ^zstd.CCtx,
	allocator:   runtime.Allocator,
}

Seal_Entry :: struct {
	first:   i64,
	end:     i64,
	arc_off: i64,
}

Seal :: struct {
	base:    i64,
	head:    journal.Hash,
	full:    bool,
	full_at: i64,
	entries: [dynamic]Seal_Entry,
}

@(private)
KEY_DOMAIN :: "0ndb-arc-group-v1"
@(private)
AEAD_DOMAIN :: "0ndb-arc-aead-v1"

stream_name :: proc(segment: string, allocator := context.temp_allocator) -> (string, Error) {
	out, err := make([]u8, len(STREAM_PREFIX) + len(segment), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, STREAM_PREFIX)
	copy(out[n:], segment)
	return string(out), .None
}

is_stream :: proc "contextless" (name: string) -> bool {
	return len(name) > len(STREAM_PREFIX) && name[:len(STREAM_PREFIX)] == STREAM_PREFIX
}

builder_init :: proc(b: ^Builder, first: i64, head: journal.Hash, allocator := context.allocator) {
	b^ = {
		first       = first,
		pos         = first,
		head_before = head,
		head        = head,
		allocator   = allocator,
	}
	b.meta = make([dynamic]u8, allocator)
	b.data = make([dynamic]u8, allocator)
}

builder_destroy :: proc(b: ^Builder) {
	if b.cctx != nil {
		zstd.ZSTD_freeCCtx(b.cctx)
	}
	_wipe(b.meta[:])
	_wipe(b.data[:])
	delete(b.meta)
	delete(b.data)
	b^ = {}
}

builder_reset :: proc(b: ^Builder, first: i64, head: journal.Hash) {
	_wipe(b.meta[:])
	_wipe(b.data[:])
	clear(&b.meta)
	clear(&b.data)
	b.first = first
	b.pos = first
	b.count = 0
	b.head_before = head
	b.head = head
}

builder_raw :: proc "contextless" (b: ^Builder) -> int {
	return len(b.meta) + len(b.data)
}

builder_add :: proc(b: ^Builder, off: i64, body: []u8, sig: bool, redacted: bool, commit: journal.Hash) -> Error {
	if off != b.pos || len(body) > journal.MAX_BODY {
		return .Corrupt
	}
	w := prim.writer(&b.meta)
	dw := prim.writer(&b.data)
	switch {
	case sig:
		prim.write_u8(&w, u8(Entry_Kind.Sig))
		prim.write_uvarint(&w, u64(len(body)))
	case redacted:
		prim.write_u8(&w, u8(Entry_Kind.Redacted))
		prim.write_uvarint(&w, u64(len(body)))
		c := commit
		prim.write_raw(&w, c[:])
		b.head = journal.chain_fold(b.head, off, journal.Link{len = u32(len(body)), commit = commit})
	case:
		if p, raw, ok := _unzip(b, body); ok {
			prim.write_u8(&w, u8(Entry_Kind.Zipped))
			prim.write_uvarint(&w, u64(len(body)))
			prim.write_uvarint(&w, u64(p))
			prim.write_raw(&w, body[:p])
			prim.write_uvarint(&w, u64(len(raw)))
			prim.write_raw(&dw, raw)
			_wipe(raw)
			b.zipped += 1
		} else {
			prim.write_u8(&w, u8(Entry_Kind.Body))
			prim.write_uvarint(&w, u64(len(body)))
			prim.write_raw(&w, body)
		}
		b.head = journal.chain_fold(b.head, off, journal.Link{len = u32(len(body)), commit = commit})
	}
	if w.err != .None || dw.err != .None {
		return .No_Memory
	}
	b.pos = off + journal.record_size(len(body))
	b.count += 1
	return .None
}

builder_finish :: proc(b: ^Builder, out: ^[dynamic]u8, mode: Mode, keys: journal.Key_Provider, shift: u8, salt: [SALT]u8, level: int = LEVEL) -> Error {
	if b.count == 0 {
		return .Corrupt
	}
	start := len(out)
	w := prim.writer(out)
	prim.write_u8(&w, GROUP_KIND)
	prim.write_u8(&w, VERSION)
	prim.write_uvarint(&w, u64(b.first))
	prim.write_uvarint(&w, u64(b.pos))
	prim.write_uvarint(&w, u64(b.count))
	prim.write_raw(&w, b.head_before[:])
	prim.write_raw(&w, b.head[:])
	prim.write_u8(&w, u8(mode))
	s := salt
	if mode == .Sealed {
		prim.write_u8(&w, shift)
		prim.write_raw(&w, s[:])
	}
	if w.err != .None {
		return .No_Memory
	}
	header_len := len(out) - start
	raw := make([dynamic]u8, 0, len(b.meta) + len(b.data) + 10, context.temp_allocator)
	rw := prim.writer(&raw)
	prim.write_uvarint(&rw, u64(len(b.meta)))
	prim.write_raw(&rw, b.meta[:])
	prim.write_raw(&rw, b.data[:])
	if rw.err != .None {
		resize(out, start)
		return .No_Memory
	}
	defer _wipe(raw[:])
	bound := int(zstd.ZSTD_compressBound(c.size_t(len(raw))))
	if resize(out, len(out) + bound + TAG) != nil {
		return .No_Memory
	}
	cctx := zstd.ZSTD_createCCtx()
	if cctx == nil {
		resize(out, start)
		return .No_Memory
	}
	dst := out[start + header_len:]
	got := zstd.ZSTD_compressCCtx(cctx, raw_data(dst), c.size_t(bound), raw_data(raw[:]), c.size_t(len(raw)), c.int(level))
	zstd.ZSTD_freeCCtx(cctx)
	if zstd.ZSTD_isError(got) != 0 {
		resize(out, start)
		return .No_Memory
	}
	n := int(got)
	if mode == .Plain {
		resize(out, start + header_len + n)
		return .None
	}
	k, kerr := group_key(keys, b.first, b.pos, shift, s)
	if kerr != .None {
		resize(out, start)
		return kerr
	}
	header := out[start:][:header_len]
	frame := out[start + header_len:][:n]
	tag := out[start + header_len + n:][:TAG]
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	_wipe(k[:])
	iv: [chacha20poly1305.IV_SIZE]u8
	chacha20poly1305.seal(&ctx, frame, tag, iv[:], header, frame)
	chacha20poly1305.reset(&ctx)
	resize(out, start + header_len + n + TAG)
	return .None
}

group_key :: proc(keys: journal.Key_Provider, first, end: i64, shift: u8, salt: [SALT]u8) -> (k: journal.Key, err: Error) {
	if keys.key == nil || shift > 30 || end <= first {
		return {}, .No_Key
	}
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, transmute([]u8)string(KEY_DOMAIN))
	b: [16]u8
	prim.put_u64le(b[0:8], u64(first))
	prim.put_u64le(b[8:16], u64(end))
	blake2b.update(&ctx, b[:])
	step := i64(1) << shift
	for off := first &~ (step - 1); off < end; off += step {
		rk: journal.Key
		if !keys.key(keys.data, off, &rk) {
			_wipe(rk[:])
			blake2b.final(&ctx, k[:])
			_wipe(k[:])
			return {}, .No_Key
		}
		blake2b.update(&ctx, rk[:])
		_wipe(rk[:])
	}
	g: [32]u8
	blake2b.final(&ctx, g[:])
	mctx: blake2b.Context
	blake2b.init_mac(&mctx, g[:], 32)
	_wipe(g[:])
	blake2b.update(&mctx, transmute([]u8)string(AEAD_DOMAIN))
	s := salt
	blake2b.update(&mctx, s[:])
	blake2b.final(&mctx, k[:])
	return k, .None
}

group_parse :: proc(body: []u8, arc_off: i64) -> (g: Group, err: Error) {
	r := prim.reader(body)
	if prim.read_u8(&r) != GROUP_KIND || prim.read_u8(&r) != VERSION {
		return {}, .Corrupt
	}
	g.arc_off = arc_off
	first := prim.read_uvarint(&r)
	end := prim.read_uvarint(&r)
	count := prim.read_uvarint(&r)
	prim.read_fixed(&r, g.head_before[:])
	prim.read_fixed(&r, g.head_after[:])
	mode := prim.read_u8(&r)
	if r.err != .None || first > end || end > u64(SPAN_MAX) || count == 0 || count > (end - first) / journal.OVERHEAD || mode > 1 {
		return {}, .Corrupt
	}
	g.first = i64(first)
	g.end = i64(end)
	g.count = int(count)
	g.mode = Mode(mode)
	if g.mode == .Sealed {
		g.shift = prim.read_u8(&r)
		prim.read_fixed(&r, g.salt[:])
		if r.err != .None || g.shift > 30 || prim.reader_remaining(&r) < TAG {
			return {}, .Corrupt
		}
	}
	g.header = body[:r.pos]
	g.payload = body[r.pos:]
	return g, .None
}

group_open :: proc(g: ^Group, keys: journal.Key_Provider, allocator := context.temp_allocator) -> (raw: []u8, err: Error) {
	plain := g.payload
	if g.mode == .Sealed {
		frame := g.payload[:len(g.payload) - TAG]
		k := group_key(keys, g.first, g.end, g.shift, g.salt) or_return
		buf, aerr := make([]u8, len(frame), context.temp_allocator)
		if aerr != nil {
			_wipe(k[:])
			return nil, .No_Memory
		}
		ctx: chacha20poly1305.Context
		chacha20poly1305.init(&ctx, k[:])
		_wipe(k[:])
		iv: [chacha20poly1305.IV_SIZE]u8
		good := chacha20poly1305.open(&ctx, buf, iv[:], g.header, frame, g.payload[len(frame):])
		chacha20poly1305.reset(&ctx)
		if !good {
			_wipe(buf)
			return nil, .Forged
		}
		plain = buf
	}
	defer if g.mode == .Sealed {
		_wipe(plain)
	}
	n, ok := _frame_size(plain)
	if !ok || n > RAW_MAX {
		return nil, .Corrupt
	}
	out, aerr := make([]u8, int(n), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	d := zstd.ZSTD_createDCtx()
	if d == nil {
		delete(out, allocator)
		return nil, .No_Memory
	}
	got := zstd.ZSTD_decompressDCtx(d, raw_data(out), c.size_t(n), raw_data(plain), c.size_t(len(plain)))
	zstd.ZSTD_freeDCtx(d)
	if zstd.ZSTD_isError(got) != 0 || i64(got) != n {
		_wipe(out)
		delete(out, allocator)
		return nil, .Corrupt
	}
	return out, .None
}

Cursor :: struct {
	r:    prim.Reader,
	d:    prim.Reader,
	off:  i64,
	left: int,
	end:  i64,
	buf:  [dynamic]u8,
	cctx: ^zstd.CCtx,
}

cursor_init :: proc(cur: ^Cursor, g: ^Group, raw: []u8, allocator := context.temp_allocator) {
	r := prim.reader(raw)
	n := prim.read_uvarint(&r)
	meta: []u8
	data: []u8
	if r.err == .None && n <= u64(prim.reader_remaining(&r)) {
		meta = raw[r.pos:][:n]
		data = raw[r.pos + int(n):]
	}
	cur^ = {
		r    = prim.reader(meta),
		d    = prim.reader(data),
		off  = g.first,
		left = g.count,
		end  = g.end,
	}
	cur.buf = make([dynamic]u8, allocator)
}

cursor_destroy :: proc(cur: ^Cursor) {
	if cur.cctx != nil {
		zstd.ZSTD_freeCCtx(cur.cctx)
	}
	_wipe(cur.buf[:])
	delete(cur.buf)
	cur^ = {}
}

cursor_next :: proc(cur: ^Cursor, e: ^Entry) -> (ok: bool, err: Error) {
	if cur.left == 0 {
		if cur.off != cur.end || !prim.reader_done(&cur.r) || !prim.reader_done(&cur.d) {
			return false, .Corrupt
		}
		return false, .None
	}
	r := &cur.r
	kind := prim.read_u8(r)
	n := prim.read_uvarint(r)
	if r.err != .None || n > journal.MAX_BODY || kind > u8(Entry_Kind.Zipped) {
		return false, .Corrupt
	}
	e^ = {kind = Entry_Kind(kind), off = cur.off, len = int(n)}
	switch e.kind {
	case .Sig:
	case .Redacted:
		prim.read_fixed(r, e.commit[:])
	case .Body:
		e.body = prim.read_raw(r, int(n))
	case .Zipped:
		p := prim.read_uvarint(r)
		if r.err != .None || p >= n {
			return false, .Corrupt
		}
		prefix := prim.read_raw(r, int(p))
		rawn := prim.read_uvarint(r)
		if r.err != .None || rawn > journal.MAX_BODY {
			return false, .Corrupt
		}
		tail := prim.read_raw(&cur.d, int(rawn))
		if r.err != .None || cur.d.err != .None {
			return false, .Corrupt
		}
		body, zerr := _rezip(cur, prefix, tail, int(n))
		if zerr != .None {
			return false, zerr
		}
		e.body = body
	}
	if r.err != .None || cur.d.err != .None {
		return false, .Corrupt
	}
	cur.off += journal.record_size(int(n))
	cur.left -= 1
	if cur.off > cur.end {
		return false, .Corrupt
	}
	return true, .None
}

group_verify :: proc(g: ^Group, raw: []u8, chain: ^journal.Chain) -> Error {
	cur: Cursor
	cursor_init(&cur, g, raw)
	defer cursor_destroy(&cur)
	head := g.head_before
	e: Entry
	for {
		ok, err := cursor_next(&cur, &e)
		if err != .None {
			return err
		}
		if !ok {
			break
		}
		switch e.kind {
		case .Sig:
			continue
		case .Redacted:
			head = journal.chain_fold(head, e.off, journal.Link{len = u32(e.len), commit = e.commit})
		case .Body, .Zipped:
			if journal.is_sig(e.body) {
				return .Forged
			}
			cm, cerr := journal.commitment(chain, e.body, e.off)
			if cerr != .None {
				return .No_Key
			}
			head = journal.chain_fold(head, e.off, journal.Link{len = u32(e.len), commit = cm})
		}
	}
	if head != g.head_after {
		return .Forged
	}
	return .None
}

entry_record :: proc(e: ^Entry, out: []u8, keys: journal.Key_Provider, sealed: bool) -> Error {
	size := int(journal.record_size(e.len))
	if len(out) < size {
		return .Too_Large
	}
	rec := out[:size]
	prim.put_u32le(rec[0:4], u32(e.len))
	prim.put_u32le(rec[journal.HEADER + e.len:], u32(e.len))
	body := rec[journal.HEADER:][:e.len]
	switch e.kind {
	case .Sig, .Redacted:
		_wipe(body)
		tag := journal.redacted_tag(e.off, e.len)
		copy(rec[4:journal.HEADER], tag[:])
		return .None
	case .Body, .Zipped:
		copy(body, e.body)
		tag := journal.local_tag(body, e.off)
		copy(rec[4:journal.HEADER], tag[:])
	}
	if sealed {
		if err := journal.seal_record(rec, e.off, keys); err != .None {
			return .No_Key
		}
	}
	return .None
}

seal_encode :: proc(out: ^[dynamic]u8, s: ^Seal) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, SEAL_KIND)
	prim.write_u8(&w, VERSION)
	prim.write_uvarint(&w, u64(s.base))
	prim.write_raw(&w, s.head[:])
	prim.write_uvarint(&w, 0 if s.full else u64(s.full_at) + 1)
	prim.write_uvarint(&w, u64(len(s.entries)))
	prev: Seal_Entry
	for e in s.entries {
		prim.write_ivarint(&w, e.first - prev.end)
		prim.write_uvarint(&w, u64(e.end - e.first))
		prim.write_ivarint(&w, e.arc_off - prev.arc_off)
		prev = e
	}
	return .None if w.err == .None else .No_Memory
}

seal_parse :: proc(body: []u8, s: ^Seal) -> Error {
	r := prim.reader(body)
	if prim.read_u8(&r) != SEAL_KIND || prim.read_u8(&r) != VERSION {
		return .Corrupt
	}
	base := prim.read_uvarint(&r)
	prim.read_fixed(&r, s.head[:])
	full := prim.read_uvarint(&r)
	count := prim.read_uvarint(&r)
	if r.err != .None || base > u64(SPAN_MAX) || count > u64(prim.reader_remaining(&r) / 3) {
		return .Corrupt
	}
	s.base = i64(base)
	s.full = full == 0
	s.full_at = i64(full) - 1 if full > 0 else 0
	clear(&s.entries)
	prev: Seal_Entry
	for _ in 0 ..< count {
		e: Seal_Entry
		e.first = prev.end + prim.read_ivarint(&r)
		e.end = e.first + i64(prim.read_uvarint(&r))
		e.arc_off = prev.arc_off + prim.read_ivarint(&r)
		if r.err != .None || e.first < 0 || e.end <= e.first || e.end > s.base || e.arc_off < 0 {
			return .Corrupt
		}
		append(&s.entries, e)
		prev = e
	}
	if !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

seal_lookup :: proc(entries: []Seal_Entry, off: i64) -> (e: Seal_Entry, found: bool) {
	lo, hi := 0, len(entries)
	for lo < hi {
		mid := (lo + hi) / 2
		if entries[mid].end <= off {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(entries) && entries[lo].first <= off {
		return entries[lo], true
	}
	return {}, false
}

seal_merge :: proc(into: ^[dynamic]Seal_Entry, add: []Seal_Entry) {
	for e in add {
		lo, hi := 0, len(into)
		for lo < hi {
			mid := (lo + hi) / 2
			if into[mid].first < e.first {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo < len(into) && into[lo].first == e.first {
			into[lo] = e
		} else {
			inject_at(into, lo, e)
		}
	}
}

@(private)
_unzip :: proc(b: ^Builder, body: []u8) -> (p: int, raw: []u8, ok: bool) {
	for i := 0; i + 6 <= len(body); i += 1 {
		if prim.get_u32le(body[i:]) != MAGIC {
			continue
		}
		n, fok := _frame_size(body[i:])
		if !fok || n > journal.MAX_BODY {
			continue
		}
		out, aerr := make([]u8, int(n), context.temp_allocator)
		if aerr != nil {
			return
		}
		d := zstd.ZSTD_createDCtx()
		if d == nil {
			return
		}
		got := zstd.ZSTD_decompressDCtx(d, raw_data(out), c.size_t(n), raw_data(body[i:]), c.size_t(len(body[i:])))
		zstd.ZSTD_freeDCtx(d)
		if zstd.ZSTD_isError(got) != 0 || i64(got) != n {
			continue
		}
		if b.cctx == nil {
			b.cctx = zstd.ZSTD_createCCtx()
			if b.cctx == nil {
				return
			}
		}
		frame := body[i:]
		bound := int(zstd.ZSTD_compressBound(c.size_t(n)))
		re, rerr := make([]u8, bound, context.temp_allocator)
		if rerr != nil {
			return
		}
		z := zstd.ZSTD_compressCCtx(b.cctx, raw_data(re), c.size_t(bound), raw_data(out), c.size_t(n), RECORD_LEVEL)
		if zstd.ZSTD_isError(z) != 0 || int(z) != len(frame) || string(re[:z]) != string(frame) {
			continue
		}
		return i, out, true
	}
	return
}

@(private)
_rezip :: proc(cur: ^Cursor, prefix: []u8, tail: []u8, want: int) -> ([]u8, Error) {
	if cur.cctx == nil {
		cur.cctx = zstd.ZSTD_createCCtx()
		if cur.cctx == nil {
			return nil, .No_Memory
		}
	}
	bound := int(zstd.ZSTD_compressBound(c.size_t(len(tail))))
	clear(&cur.buf)
	if resize(&cur.buf, len(prefix) + bound) != nil {
		return nil, .No_Memory
	}
	copy(cur.buf[:], prefix)
	z := zstd.ZSTD_compressCCtx(cur.cctx, raw_data(cur.buf[len(prefix):]), c.size_t(bound), raw_data(tail), c.size_t(len(tail)), RECORD_LEVEL)
	if zstd.ZSTD_isError(z) != 0 || len(prefix) + int(z) != want {
		return nil, .Corrupt
	}
	return cur.buf[:want], .None
}

@(private)
_frame_size :: proc "contextless" (f: []u8) -> (n: i64, ok: bool) {
	if len(f) < 6 || prim.get_u32le(f) != MAGIC {
		return 0, false
	}
	fhd := f[4]
	if fhd & 0x08 != 0 {
		return 0, false
	}
	single := fhd & 0x20 != 0
	pos := 5 if single else 6
	dict := [4]int{0, 1, 2, 4}
	sizes := [4]int{1 if single else 0, 2, 4, 8}
	pos += dict[fhd & 3]
	size := sizes[fhd >> 6]
	if size == 0 || pos + size > len(f) {
		return 0, false
	}
	v: u64
	switch size {
	case 1:
		v = u64(f[pos])
	case 2:
		v = (u64(f[pos]) | u64(f[pos + 1]) << 8) + 256
	case 4:
		v = u64(prim.get_u32le(f[pos:]))
	case 8:
		v = prim.get_u64le(f[pos:])
	}
	if v > u64(max(i64)) {
		return 0, false
	}
	return i64(v), true
}

@(private)
_wipe :: proc "contextless" (b: []u8) {
	for &x in b {
		x = 0
	}
}
