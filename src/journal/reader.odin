package journal

import "base:runtime"
import "core:crypto/chacha20poly1305"
import "../prim"

Reader :: struct {
	fd:        prim.Fd,
	end:       i64,
	owns_fd:   bool,
	journal:   ^Journal,
	replica:   ^Replica,
	version:   u64,
	sealed:    bool,
	aead:      chacha20poly1305.Context,
	win:       []u8,
	win_len:   int,
	win_off:   i64,
	out:       []u8,
	missing:   Range,
	allocator: runtime.Allocator,
}

Cursor :: struct {
	r:   ^Reader,
	pos: i64,
	err: Error,
}

reader_init :: proc(r: ^Reader, fd: prim.Fd, end: i64, allocator := context.allocator) {
	r^ = {
		fd        = fd,
		end       = end,
		allocator = allocator,
	}
}

reader_open :: proc(r: ^Reader, path: string, allocator := context.allocator) -> Error {
	fd, err := prim.open_file(path)
	if err != .None {
		r^ = {
			fd = prim.INVALID_FD,
		}
		return _err(err)
	}
	size, serr := prim.file_size(fd)
	if serr != .None {
		prim.close(fd)
		r^ = {
			fd = prim.INVALID_FD,
		}
		return _err(serr)
	}
	reader_init(r, fd, size, allocator)
	r.owns_fd = true
	return .None
}

reader_refresh :: proc(r: ^Reader) -> Error {
	if !r.owns_fd {
		return .None
	}
	size, err := prim.file_size(r.fd)
	if err != .None {
		return _err(err)
	}
	r.end = size
	return .None
}

reader_set_key :: proc(r: ^Reader, key: ^Key) {
	chacha20poly1305.init(&r.aead, key[:])
	r.sealed = true
}

reader_close :: proc(r: ^Reader) {
	if r.owns_fd {
		prim.close(r.fd)
	}
	if r.win != nil {
		delete(r.win, r.allocator)
	}
	if r.out != nil {
		delete(r.out, r.allocator)
	}
	if r.sealed {
		chacha20poly1305.reset(&r.aead)
	}
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

record_at :: proc(r: ^Reader, off: i64) -> (body: []u8, next: i64, err: Error) {
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
		return nil, off, .Corrupt
	}
	next = off + n + OVERHEAD
	rec := _fetch(r, off, next, true) or_return
	body = _verify(r, rec, off) or_return
	return body, next, .None
}

record_before :: proc(r: ^Reader, end_off: i64) -> (body: []u8, off: i64, err: Error) {
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
		return nil, end_off, .Corrupt
	}
	off = end_off - n - OVERHEAD
	rec := _fetch(r, off, end_off, false) or_return
	body = _verify(r, rec, off) or_return
	return body, off, .None
}

cursor :: proc "contextless" (r: ^Reader, pos: i64) -> Cursor {
	return Cursor{r = r, pos = pos}
}

cursor_tail :: proc "contextless" (r: ^Reader) -> Cursor {
	return Cursor{r = r, pos = reader_end(r)}
}

next :: proc(c: ^Cursor) -> (body: []u8, off: i64, ok: bool) {
	if c.err != .None {
		return
	}
	b, nxt, err := record_at(c.r, c.pos)
	if err != .None {
		if err != .Eof {
			c.err = err
		}
		return
	}
	off = c.pos
	c.pos = nxt
	return b, off, true
}

prev :: proc(c: ^Cursor) -> (body: []u8, off: i64, ok: bool) {
	if c.err != .None {
		return
	}
	b, start, err := record_before(c.r, c.pos)
	if err != .None {
		if err != .Eof {
			c.err = err
		}
		return
	}
	c.pos = start
	return b, start, true
}

@(private)
_verify :: proc(r: ^Reader, rec: []u8, off: i64) -> ([]u8, Error) {
	body, err := record_body(rec)
	if err != .None {
		return nil, err
	}
	tag := rec[4:HEADER]
	if !r.sealed {
		local := local_tag(body, off)
		if !_tag_eq(local[:], tag) {
			return nil, .Corrupt
		}
		return body, .None
	}
	if len(r.out) < len(body) {
		if r.out != nil {
			delete(r.out, r.allocator)
			r.out = nil
		}
		out, aerr := make([]u8, max(len(body), 256), r.allocator)
		if aerr != nil {
			return nil, .No_Memory
		}
		r.out = out
	}
	iv := nonce(off)
	plain := r.out[:len(body)]
	if !chacha20poly1305.open(&r.aead, plain, iv[:], nil, body, tag) {
		return nil, .Corrupt
	}
	return plain, .None
}

@(private)
_fetch :: proc(r: ^Reader, from, to: i64, forward: bool) -> ([]u8, Error) {
	file_end := reader_end(r)
	if j := r.journal; j != nil {
		if from >= j.durable {
			return j.pending[from - j.durable:to - j.durable], .None
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
		if gap, missing := replica_missing(rep, from, to); missing {
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
	n, err := prim.read_at(r.fd, r.win[:stop - start], start)
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
