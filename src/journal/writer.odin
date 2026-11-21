package journal

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

Journal :: struct {
	fd:         prim.Fd,
	ck_fd:      prim.Fd,
	durable:    i64,
	checkpoint: i64,
	pending:    [dynamic]u8,
	open_at:    int,
	allocator:  runtime.Allocator,
}

journal_open :: proc(j: ^Journal, path: string, allocator := context.allocator, keep_at_least: i64 = 0) -> Error {
	j^ = {
		fd        = prim.INVALID_FD,
		ck_fd     = prim.INVALID_FD,
		open_at   = -1,
		allocator = allocator,
	}
	ck_path, cerr := _sidecar(path, ".ck", context.temp_allocator)
	if cerr != .None {
		return cerr
	}
	fd, oerr := prim.open_file(path, {.Write}, 0o600)
	if oerr == .Not_Found {
		if keep_at_least > 0 {
			return .Corrupt
		}
		if rerr := prim.remove(ck_path); rerr != .None && rerr != .Not_Found {
			return _err(rerr)
		}
		fd, oerr = prim.open_file(path, {.Write, .Create, .Exclusive}, 0o600)
		if oerr == .None {
			if serr := prim.sync_dir(prim.dir_name(path)); serr != .None {
				prim.close(fd)
				return _err(serr)
			}
		}
	}
	if oerr != .None {
		return _err(oerr)
	}
	j.fd = fd
	ck_fd, kerr := prim.open_file(ck_path, {.Write, .Create}, 0o600)
	if kerr != .None {
		_release(j)
		return _err(kerr)
	}
	j.ck_fd = ck_fd
	j.pending = make([dynamic]u8, allocator)
	if err := _recover(j, keep_at_least); err != .None {
		_release(j)
		return err
	}
	return .None
}

journal_close :: proc(j: ^Journal) -> Error {
	err: Error
	if j.fd >= 0 {
		journal_abort(j)
		err = journal_commit(j)
	}
	_release(j)
	return err
}

journal_durable_len :: proc "contextless" (j: ^Journal) -> i64 {
	return j.durable
}

journal_len :: proc "contextless" (j: ^Journal) -> i64 {
	if j.open_at >= 0 {
		return j.durable + i64(j.open_at)
	}
	return j.durable + i64(len(j.pending))
}

journal_pending :: proc "contextless" (j: ^Journal) -> int {
	if j.open_at >= 0 {
		return j.open_at
	}
	return len(j.pending)
}

journal_append :: proc(j: ^Journal, body: []u8) -> (off: i64, err: Error) {
	if j.open_at >= 0 || j.fd < 0 {
		return 0, .Invalid
	}
	if len(body) > MAX_BODY {
		return 0, .Too_Large
	}
	off = journal_len(j)
	start := len(j.pending)
	if rerr := resize(&j.pending, start + len(body) + OVERHEAD); rerr != nil {
		resize(&j.pending, start)
		return 0, .No_Memory
	}
	encode_record(j.pending[start:], body, off)
	return off, .None
}

journal_begin :: proc(j: ^Journal) -> (w: prim.Writer, err: Error) {
	if j.open_at >= 0 || j.fd < 0 {
		return {}, .Invalid
	}
	start := len(j.pending)
	if rerr := resize(&j.pending, start + HEADER); rerr != nil {
		resize(&j.pending, start)
		return {}, .No_Memory
	}
	j.open_at = start
	return prim.writer(&j.pending), .None
}

journal_end :: proc(j: ^Journal, w: ^prim.Writer) -> (off: i64, err: Error) {
	if j.open_at < 0 {
		return 0, .Invalid
	}
	start := j.open_at
	n := len(j.pending) - start - HEADER
	switch {
	case w.err != .None:
		err = .No_Memory
	case n > MAX_BODY:
		err = .Too_Large
	}
	if err == .None {
		if rerr := resize(&j.pending, len(j.pending) + TRAILER); rerr != nil {
			err = .No_Memory
		}
	}
	if err != .None {
		journal_abort(j)
		return 0, err
	}
	off = j.durable + i64(start)
	rec := j.pending[start:]
	body := rec[HEADER:][:n]
	prim.put_u32le(rec[0:4], u32(n))
	tag := local_tag(body, off)
	copy(rec[4:HEADER], tag[:])
	prim.put_u32le(rec[HEADER + n:], u32(n))
	j.open_at = -1
	return off, .None
}

journal_abort :: proc(j: ^Journal) {
	if j.open_at >= 0 {
		resize(&j.pending, j.open_at)
		j.open_at = -1
	}
}

journal_commit :: proc(j: ^Journal) -> Error {
	if j.fd < 0 {
		return .Invalid
	}
	n := journal_pending(j)
	if n == 0 {
		return .None
	}
	if err := prim.write_at(j.fd, j.pending[:n], j.durable); err != .None {
		prim.truncate(j.fd, j.durable)
		return _err(err)
	}
	if err := prim.datasync(j.fd); err != .None {
		prim.truncate(j.fd, j.durable)
		return _err(err)
	}
	j.durable += i64(n)
	rest := len(j.pending) - n
	if rest > 0 {
		copy(j.pending[:rest], j.pending[n:])
	}
	resize(&j.pending, rest)
	if j.open_at >= 0 {
		j.open_at -= n
	}
	if rest == 0 && cap(j.pending) > PENDING_KEEP {
		delete(j.pending)
		j.pending = make([dynamic]u8, j.allocator)
	}
	_write_checkpoint(j)
	return .None
}

journal_reader :: proc(j: ^Journal, r: ^Reader, allocator := context.allocator) {
	reader_init(r, j.fd, 0, allocator)
	r.journal = j
}

@(private)
_release :: proc(j: ^Journal) {
	if j.fd >= 0 {
		prim.close(j.fd)
	}
	if j.ck_fd >= 0 {
		prim.close(j.ck_fd)
	}
	delete(j.pending)
	j^ = {
		fd      = prim.INVALID_FD,
		ck_fd   = prim.INVALID_FD,
		open_at = -1,
	}
}

@(private)
_recover :: proc(j: ^Journal, keep_at_least: i64) -> Error {
	size, serr := prim.file_size(j.fd)
	if serr != .None {
		return _err(serr)
	}
	if size < keep_at_least {
		return .Corrupt
	}
	ck := _read_checkpoint(j.ck_fd)
	if ck > size {
		return .Corrupt
	}
	end := ck
	if ck < size {
		r: Reader
		reader_init(&r, j.fd, size, context.temp_allocator)
		defer reader_close(&r)
		for {
			_, nxt, err := record_at(&r, end)
			if err != .None {
				break
			}
			end = nxt
		}
		if end < size && end < keep_at_least {
			return .Corrupt
		}
	}
	if end < size {
		if err := prim.truncate(j.fd, end); err != .None {
			return _err(err)
		}
	}
	if end != ck || end < size {
		if err := prim.datasync(j.fd); err != .None {
			return _err(err)
		}
	}
	j.durable = end
	j.checkpoint = ck
	if ck != end {
		_write_checkpoint(j)
	}
	return .None
}

@(private)
_read_checkpoint :: proc(fd: prim.Fd) -> i64 {
	b: [16]u8
	n, rerr := prim.read_at(fd, b[:], 0)
	if rerr != .None || n != 16 {
		return 0
	}
	if xxhash.XXH3_64_with_seed(b[0:8], CHECKPOINT_SEED) != prim.get_u64le(b[8:16]) {
		return 0
	}
	v := prim.get_u64le(b[0:8])
	if v > u64(max(i64)) {
		return 0
	}
	return i64(v)
}

@(private)
CHECKPOINT_SEED :: 0x306e_6462_636b

@(private)
_write_checkpoint :: proc(j: ^Journal) {
	b: [16]u8
	prim.put_u64le(b[0:8], u64(j.durable))
	prim.put_u64le(b[8:16], xxhash.XXH3_64_with_seed(b[0:8], CHECKPOINT_SEED))
	if prim.write_at(j.ck_fd, b[:], 0) == .None {
		j.checkpoint = j.durable
	}
}
