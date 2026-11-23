package journal

import "base:runtime"
import "core:crypto/chacha20poly1305"
import "../prim"

Reader :: struct {
	vfs:        prim.Vfs,
	fd:         prim.Fd,
	end:        i64,
	owns_fd:    bool,
	journal:    ^Journal,
	replica:    ^Replica,
	version:    u64,
	keys:       Key_Provider,
	chained:    bool,
	chain:      Chain,
	span:       Sig_Info,
	span_ok:    bool,
	span_links: [dynamic]Link,
	span_offs:  [dynamic]i64,
	win:        []u8,
	win_len:    int,
	win_off:    i64,
	out:        []u8,
	scan:       []u8,
	missing:    Range,
	damage:     Damage,
	allocator:  runtime.Allocator,
}

Cursor :: struct {
	r:   ^Reader,
	pos: i64,
	err: Error,
}

reader_init :: proc(r: ^Reader, vfs: prim.Vfs, fd: prim.Fd, end: i64, allocator := context.allocator) {
	r^ = {
		vfs       = vfs,
		fd        = fd,
		end       = end,
		allocator = allocator,
	}
}

reader_open :: proc(r: ^Reader, vfs: prim.Vfs, path: string, allocator := context.allocator) -> Error {
	r^ = {
		fd = prim.INVALID_FD,
	}
	fd, err := prim.open_file(vfs, path)
	if err != .None {
		return _err(err)
	}
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		prim.close_file(vfs, fd)
		return _err(serr)
	}
	reader_init(r, vfs, fd, size, allocator)
	r.owns_fd = true
	return .None
}

reader_refresh :: proc(r: ^Reader) -> Error {
	if !r.owns_fd {
		return .None
	}
	size, err := prim.file_size(r.vfs, r.fd)
	if err != .None {
		return _err(err)
	}
	r.end = size
	return .None
}

reader_set_keys :: proc(r: ^Reader, keys: Key_Provider) {
	r.keys = keys
}

reader_set_chain :: proc(r: ^Reader, chain: ^Chain) {
	r.chained = chain != nil
	if chain != nil {
		r.chain = chain^
	}
	r.span_ok = false
}

reader_span :: proc "contextless" (r: ^Reader) -> (Sig_Info, bool) {
	return r.span, r.span_ok
}

reader_close :: proc(r: ^Reader) {
	if r.owns_fd {
		prim.close_file(r.vfs, r.fd)
	}
	if r.win != nil {
		delete(r.win, r.allocator)
	}
	if r.out != nil {
		_zero(r.out)
		delete(r.out, r.allocator)
	}
	if r.scan != nil {
		_zero(r.scan)
		delete(r.scan, r.allocator)
	}
	delete(r.span_links)
	delete(r.span_offs)
	r^ = {
		fd = prim.INVALID_FD,
	}
}

reader_end :: proc "contextless" (r: ^Reader) -> i64 {
	if r.journal != nil {
		return journal_len(r.journal)
	}
	if r.replica != nil {
		return r.replica.length
	}
	return r.end
}

JOURNAL_POISON :: #config(JOURNAL_POISON, false)

record_at :: proc(r: ^Reader, off: i64) -> (body: []u8, next: i64, err: Error) {
	_poison(r)
	end := reader_end(r)
	if off == end {
		return nil, off, .Eof
	}
	if off < 0 || off > end {
		return nil, off, .Bad_Offset
	}
	if end - off < OVERHEAD {
		return nil, off, .Corrupt
	}
	head := _fetch(r, off, off + HEADER, true) or_return
	n := i64(prim.get_u32le(head[0:4]))
	if n > MAX_BODY || n + OVERHEAD > end - off {
		_damaged(r, off)
		return nil, off, .Corrupt
	}
	next = off + n + OVERHEAD
	body, err = _read(r, off, next, true)
	return body, next, err
}

@(private)
_damaged :: proc(r: ^Reader, at: i64) {
	if r.damage.call != nil {
		r.damage.call(r.damage.data, at)
		return
	}
	if j := r.journal; j != nil && j.damage.call != nil && at < j.durable {
		j.damage.call(j.damage.data, at)
	}
}

record_before :: proc(r: ^Reader, end_off: i64) -> (body: []u8, off: i64, err: Error) {
	_poison(r)
	end := reader_end(r)
	if end_off == 0 {
		return nil, 0, .Eof
	}
	if end_off < 0 || end_off > end {
		return nil, end_off, .Bad_Offset
	}
	if end_off < OVERHEAD {
		return nil, end_off, .Corrupt
	}
	tail := _fetch(r, end_off - TRAILER, end_off, false) or_return
	n := i64(prim.get_u32le(tail))
	if n > MAX_BODY || n + OVERHEAD > end_off {
		_damaged(r, end_off - 1)
		return nil, end_off, .Corrupt
	}
	off = end_off - n - OVERHEAD
	body, err = _read(r, off, end_off, false)
	return body, off, err
}

cursor :: proc "contextless" (r: ^Reader, pos: i64) -> Cursor {
	return Cursor{r = r, pos = pos}
}

cursor_tail :: proc "contextless" (r: ^Reader) -> Cursor {
	return Cursor{r = r, pos = reader_end(r)}
}

next :: proc(c: ^Cursor) -> (body: []u8, off: i64, ok: bool) {
	for c.err == .None {
		b, nxt, err := record_at(c.r, c.pos)
		at := c.pos
		switch err {
		case .None:
			c.pos = nxt
			if is_sig(b) {
				continue
			}
			return b, at, true
		case .Redacted:
			c.pos = nxt
			continue
		case .Eof:
			return
		case .Corrupt, .Missing, .No_Key, .Forged, .Unverified, .Equivocation, .Too_Large, .Bad_Offset, .Invalid, .Busy, .Not_Found, .Permission, .No_Space, .No_Memory, .Io:
			c.err = err
		}
	}
	return
}

prev :: proc(c: ^Cursor) -> (body: []u8, off: i64, ok: bool) {
	for c.err == .None {
		b, start, err := record_before(c.r, c.pos)
		switch err {
		case .None:
			c.pos = start
			if is_sig(b) {
				continue
			}
			return b, start, true
		case .Redacted:
			c.pos = start
			continue
		case .Eof:
			return
		case .Corrupt, .Missing, .No_Key, .Forged, .Unverified, .Equivocation, .Too_Large, .Bad_Offset, .Invalid, .Busy, .Not_Found, .Permission, .No_Space, .No_Memory, .Io:
			c.err = err
		}
	}
	return
}

@(private)
_read :: proc(r: ^Reader, off, end: i64, forward: bool) -> (body: []u8, err: Error) {
	rec := _fetch(r, off, end, forward) or_return
	b, kind, derr := _decode(r, rec, off)
	if derr != .None {
		if derr == .Corrupt {
			_damaged(r, off)
		}
		return nil, derr
	}
	if r.chained {
		if kind == .Plain && is_sig(b) {
			return b, _check_sig_record(r, b, off)
		}
		if err = _check_chain(r, off, end, b, kind == .Redacted); err != .None {
			return nil, err
		}
		if kind == .Plain {
			rec = _fetch(r, off, end, forward) or_return
			b, _ = record_body(rec)
		}
	}
	if kind == .Redacted {
		return nil, .Redacted
	}
	return b, .None
}

@(private)
_decode :: proc(r: ^Reader, rec: []u8, off: i64) -> (body: []u8, kind: Record_Kind, err: Error) {
	kind = classify(rec, off)
	b, _ := record_body(rec)
	switch kind {
	case .Invalid:
		return nil, kind, .Corrupt
	case .Redacted:
		return nil, kind, .None
	case .Plain:
		if r.keys.key != nil {
			return nil, kind, .Corrupt
		}
		return b, kind, .None
	case .Sealed:
		if r.keys.key == nil {
			return nil, kind, .Corrupt
		}
		if is_sig(b) {
			if tag, ok := sig_tag(b, off, r.keys); ok && _tag_eq(tag[:], rec[4:HEADER]) {
				return b, .Plain, .None
			}
		}
	}
	k: Key
	if !r.keys.key(r.keys.data, off, &k) {
		return nil, .Redacted, .None
	}
	if len(r.out) < len(b) {
		if r.out != nil {
			_zero(r.out)
			delete(r.out, r.allocator)
			r.out = nil
		}
		out, aerr := make([]u8, max(len(b), 256), r.allocator)
		if aerr != nil {
			_zero(k[:])
			return nil, kind, .No_Memory
		}
		r.out = out
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	_zero(k[:])
	iv := nonce(off)
	plain := r.out[:len(b)]
	ok := chacha20poly1305.open(&ctx, plain, iv[:], nil, b, rec[4:HEADER])
	chacha20poly1305.reset(&ctx)
	if !ok {
		return nil, kind, .Corrupt
	}
	return plain, kind, .None
}

@(private)
_check_chain :: proc(r: ^Reader, off, end: i64, body: []u8, redacted: bool) -> Error {
	c: Hash
	have_commit := false
	if !redacted {
		cerr: Error
		c, cerr = commitment(&r.chain, body, off)
		switch cerr {
		case .None:
			have_commit = true
		case .No_Key:
			return .Redacted
		case .Eof, .Corrupt, .Missing, .Redacted, .Forged, .Unverified, .Equivocation, .Too_Large, .Bad_Offset, .Invalid, .Busy, .Not_Found, .Permission, .No_Space, .No_Memory, .Io:
			return cerr
		}
	}
	if !(r.span_ok && off >= r.span.range_start && off < r.span.off) {
		if err := _find_span(r, end); err != .None {
			return err
		}
		if !(off >= r.span.range_start && off < r.span.off) {
			return .Forged
		}
	}
	lo, hi := 0, len(r.span_offs)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.span_offs[mid] < off {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo >= len(r.span_offs) || r.span_offs[lo] != off {
		return .Forged
	}
	link := r.span_links[lo]
	if i64(link.len) != end - off - OVERHEAD {
		return .Forged
	}
	if have_commit && !_tag_eq(c[:], link.commit[:]) {
		return .Forged
	}
	return .None
}

@(private)
_find_span :: proc(r: ^Reader, from: i64) -> Error {
	limit := reader_end(r)
	pos := from
	for pos < limit {
		head := _fetch(r, pos, pos + HEADER, true) or_return
		n := i64(prim.get_u32le(head[0:4]))
		if n > MAX_BODY || n + OVERHEAD > limit - pos {
			return .Corrupt
		}
		end := pos + n + OVERHEAD
		if n > 0 {
			first := _fetch(r, pos + HEADER, pos + HEADER + 1, true) or_return
			if first[0] == SIG_KIND {
				rec := _fetch(r, pos, end, true) or_return
				out := r.out
				r.out = r.scan
				b, kind, err := _decode(r, rec, pos)
				r.scan = r.out
				r.out = out
				if err == .None && kind == .Plain && is_sig(b) {
					return _check_sig_record(r, b, pos)
				}
			}
		}
		pos = end
	}
	if r.replica != nil {
		r.missing = Range{limit, limit + HEADER}
		return .Missing
	}
	return .Unverified
}

@(private)
_check_sig_record :: proc(r: ^Reader, body: []u8, off: i64) -> Error {
	if r.span_ok && r.span.off == off {
		return .None
	}
	links := make([dynamic]Link, r.allocator)
	info, sig, err := parse_sig(body, off, &links)
	if err != .None {
		delete(links)
		return .Forged if err == .Corrupt else err
	}
	verdict := _verify_span(r, info, sig, links[:])
	if verdict != .None {
		delete(links)
		return verdict
	}
	if r.span_ok {
		old := r.span
		if (info.range_start == old.end && info.prev_head != old.head) || (old.range_start == info.end && old.prev_head != info.head) {
			delete(links)
			return .Equivocation
		}
	}
	offs := make([dynamic]i64, 0, len(links), r.allocator)
	pos := info.range_start
	for l in links {
		append(&offs, pos)
		pos += i64(l.len) + OVERHEAD
	}
	delete(r.span_links)
	delete(r.span_offs)
	r.span_links = links
	r.span_offs = offs
	r.span = info
	r.span_ok = true
	return .None
}

@(private)
_verify_span :: proc(r: ^Reader, info: Sig_Info, sig: []u8, links: []Link) -> Error {
	if r.chain.verifier.verify == nil {
		return .Unverified
	}
	if info.range_start == 0 && info.prev_head != chain_genesis(r.chain.seed) {
		return .Forged
	}
	head := info.prev_head
	pos := info.range_start
	for l in links {
		head = chain_fold(head, pos, l)
		pos += i64(l.len) + OVERHEAD
	}
	if pos != info.off || head != info.head {
		return .Forged
	}
	msg_buf: [SIG_MESSAGE_MAX]u8
	msg := sig_message(msg_buf[:], r.chain.seed, info)
	if !r.chain.verifier.verify(r.chain.verifier.data, msg, sig) {
		return .Forged
	}
	return .None
}

@(private)
_fetch :: proc(r: ^Reader, from, to: i64, forward: bool) -> ([]u8, Error) {
	file_end := reader_end(r)
	if j := r.journal; j != nil {
		if r.version != j.version {
			r.version = j.version
			r.win_len = 0
		}
		if from >= j.durable {
			when JOURNAL_POISON {
				if we := _window(r, int(to - from)); we != .None {
					return nil, we
				}
				r.win_len = 0
				copy(r.win, j.pending[from - j.durable:to - j.durable])
				return r.win[:to - from], .None
			} else {
				return j.pending[from - j.durable:to - j.durable], .None
			}
		}
		file_end = j.durable
		if to > file_end {
			return nil, .Corrupt
		}
	}
	if rep := r.replica; rep != nil {
		if r.version != rep.version {
			r.version = rep.version
			r.win_len = 0
		}
		if gap, missing := _have_missing(rep.have[:], from, to); missing {
			r.missing = gap
			return nil, .Missing
		}
	}
	if from >= r.win_off && to <= r.win_off + i64(r.win_len) {
		return r.win[from - r.win_off:to - r.win_off], .None
	}
	need := int(to - from)
	size := max(need, WINDOW)
	start := from
	if !forward {
		start = max(to - i64(size), 0)
	}
	stop := min(start + i64(size), file_end)
	if stop < to {
		stop = to
	}
	if err := _window(r, int(stop - start)); err != .None {
		return nil, err
	}
	n, err := prim.read_at(r.vfs, r.fd, r.win[:stop - start], start)
	if err != .None {
		r.win_len = 0
		return nil, _err(err)
	}
	r.win_off = start
	r.win_len = n
	if i64(n) < to - start {
		r.win_len = 0
		return nil, .Corrupt
	}
	return r.win[from - start:to - start], .None
}

@(private)
_window :: proc(r: ^Reader, size: int) -> Error {
	if len(r.win) >= size && !(len(r.win) > 4 * WINDOW && size <= WINDOW) {
		return .None
	}
	if r.win != nil {
		delete(r.win, r.allocator)
		r.win = nil
	}
	r.win_len = 0
	if r.allocator.procedure == nil {
		r.allocator = context.allocator
	}
	win, err := make([]u8, max(size, WINDOW), r.allocator)
	if err != nil {
		return .No_Memory
	}
	r.win = win
	return .None
}

@(private)
_poison :: proc "contextless" (r: ^Reader) {
	when JOURNAL_POISON {
		for &b in r.win {
			b = 0xa5
		}
		r.win_len = 0
		for &b in r.out {
			b = 0xa5
		}
		for &b in r.scan {
			b = 0xa5
		}
	}
}
