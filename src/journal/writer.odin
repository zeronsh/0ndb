package journal

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

Damage :: struct {
	data: rawptr,
	call: proc(data: rawptr, at: i64),
}

Options :: struct {
	keep_at_least: i64,
	chain:         ^Chain,
	damage:        Damage,
}

Journal :: struct {
	vfs:         prim.Vfs,
	fd:          prim.Fd,
	ck_fd:       prim.Fd,
	atomic:      bool,
	sized:       bool,
	durable:     i64,
	checkpoint:  i64,
	version:     u64,
	pending:     [dynamic]u8,
	open_at:     int,
	chained:     bool,
	chain:       Chain,
	head:        Hash,
	range_start: i64,
	links:       [dynamic]Link,
	redact_path: string,
	damage:      Damage,
	allocator:   runtime.Allocator,
}

journal_open :: proc(j: ^Journal, vfs: prim.Vfs, path: string, opts := Options{}, allocator := context.allocator) -> Error {
	j^ = {
		vfs       = vfs,
		fd        = prim.INVALID_FD,
		ck_fd     = prim.INVALID_FD,
		open_at   = -1,
		allocator = allocator,
	}
	ck_path, cerr := _sidecar(path, ".ck", context.temp_allocator)
	if cerr != .None {
		return cerr
	}
	redact_path, rerr := _sidecar(path, ".redact", allocator)
	if rerr != .None {
		return rerr
	}
	j.redact_path = redact_path
	j.damage = opts.damage
	fd, oerr := prim.open_file(vfs, path, {.Write, .Group_Visible}, 0o600)
	if oerr == .Not_Found {
		if opts.keep_at_least > 0 {
			_release(j)
			return .Corrupt
		}
		for stale in ([]string{ck_path, redact_path}) {
			if e := prim.remove(vfs, stale); e != .None && e != .Not_Found {
				_release(j)
				return _err(e)
			}
		}
		fd, oerr = prim.open_file(vfs, path, {.Write, .Create, .Exclusive, .Group_Visible}, 0o600)
		if oerr == .None && .Durable_Dir_Ops_With_Data not_in prim.file_caps(vfs, fd) {
			if serr := prim.sync_dir(vfs, prim.dir_name(path)); serr != .None {
				prim.close_file(vfs, fd)
				_release(j)
				return _err(serr)
			}
		}
	}
	if oerr != .None {
		_release(j)
		return _err(oerr)
	}
	j.fd = fd
	caps := prim.file_caps(vfs, fd)
	j.atomic = .Atomic_Group_Commit in caps
	j.sized = j.atomic || .Durable_Size in caps
	if !j.atomic {
		ck_fd, kerr := prim.open_file(vfs, ck_path, {.Write, .Create}, 0o600)
		if kerr != .None {
			_release(j)
			return _err(kerr)
		}
		j.ck_fd = ck_fd
	}
	j.pending = make([dynamic]u8, allocator)
	j.links = make([dynamic]Link, allocator)
	if opts.chain != nil {
		j.chained = true
		j.chain = opts.chain^
	}
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		_release(j)
		return _err(serr)
	}
	t := _Redact_Target {
		vfs = vfs,
		fd  = fd,
		end = size,
	}
	if err := _redact_replay(&t, redact_path); err != .None {
		_release(j)
		return err
	}
	if err := _recover(j, size, opts.keep_at_least); err != .None {
		_release(j)
		return err
	}
	if j.chained {
		if err := _recover_chain(j); err != .None {
			_release(j)
			return err
		}
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

journal_head :: proc "contextless" (j: ^Journal) -> Hash {
	return j.head
}

journal_append :: proc(j: ^Journal, body: []u8) -> (off: i64, err: Error) {
	if j.open_at >= 0 || j.fd < 0 || is_sig(body) {
		return 0, .Invalid
	}
	return _append(j, body, true)
}

journal_begin :: proc(j: ^Journal) -> (w: prim.Writer, err: Error) {
	if j.open_at >= 0 || j.fd < 0 {
		return {}, .Invalid
	}
	start := len(j.pending)
	if resize(&j.pending, start + HEADER) != nil {
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
	case n > 0 && j.pending[start + HEADER] == SIG_KIND:
		err = .Invalid
	}
	if err == .None && resize(&j.pending, len(j.pending) + TRAILER) != nil {
		err = .No_Memory
	}
	off = j.durable + i64(start)
	if err == .None && j.chained {
		err = _link(j, j.pending[start + HEADER:][:n], off)
	}
	if err != .None {
		journal_abort(j)
		return 0, err
	}
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

Pending_Mark :: struct {
	durable: i64,
	pending: int,
	links:   int,
}

journal_pending_mark :: proc "contextless" (j: ^Journal) -> Pending_Mark {
	return {j.durable, len(j.pending), len(j.links)}
}

journal_rewind :: proc(j: ^Journal, m: Pending_Mark) -> bool {
	journal_abort(j)
	if j.durable != m.durable || len(j.pending) < m.pending || len(j.links) < m.links {
		return false
	}
	resize(&j.pending, m.pending)
	resize(&j.links, m.links)
	return true
}

journal_commit :: proc(j: ^Journal) -> Error {
	if j.fd < 0 {
		return .Invalid
	}
	if j.chained && j.open_at >= 0 {
		return .Invalid
	}
	sig_at := -1
	next_head: Hash
	if j.chained && len(j.links) > 0 {
		at, head, err := _append_sig(j)
		if err != .None {
			return err
		}
		sig_at = at
		next_head = head
	}
	n := journal_pending(j)
	if n == 0 {
		return .None
	}
	werr := prim.write_at(j.vfs, j.fd, j.pending[:n], j.durable)
	if werr == .None {
		werr = prim.datasync(j.vfs, j.fd)
	}
	if werr != .None {
		prim.truncate(j.vfs, j.fd, j.durable)
		if sig_at >= 0 {
			resize(&j.pending, sig_at)
		}
		return _err(werr)
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
	if sig_at >= 0 {
		j.head = next_head
		j.range_start = j.durable
		clear(&j.links)
	}
	_write_checkpoint(j)
	return .None
}

journal_redact :: proc(j: ^Journal, from, to: i64) -> Error {
	if j.fd < 0 || j.open_at >= 0 {
		return .Invalid
	}
	if err := journal_commit(j); err != .None {
		return err
	}
	t := _Redact_Target {
		vfs = j.vfs,
		fd  = j.fd,
		end = j.durable,
	}
	err := _redact(&t, j.redact_path, from, to)
	j.version += 1
	return err
}

journal_redact_records :: proc(j: ^Journal, offs: []i64) -> Error {
	if j.fd < 0 || j.open_at >= 0 {
		return .Invalid
	}
	if err := journal_commit(j); err != .None {
		return err
	}
	t := _Redact_Target {
		vfs = j.vfs,
		fd  = j.fd,
		end = j.durable,
	}
	err := _redact_records(&t, j.redact_path, offs)
	j.version += 1
	return err
}

journal_restore :: proc(j: ^Journal, off: i64, rec: []u8) -> Error {
	if j.fd < 0 || j.open_at >= 0 {
		return .Invalid
	}
	if err := journal_commit(j); err != .None {
		return err
	}
	if off < 0 || off + i64(len(rec)) > j.durable || len(rec) < OVERHEAD || int(prim.get_u32le(rec)) + OVERHEAD != len(rec) {
		return .Bad_Offset
	}
	if kind := classify(rec, off); kind != .Plain && kind != .Redacted {
		return .Corrupt
	}
	cur := make([]u8, len(rec), context.temp_allocator)
	defer delete(cur, context.temp_allocator)
	got, rerr := prim.read_at(j.vfs, j.fd, cur, off)
	if rerr != .None {
		return _err(rerr)
	}
	if got == len(rec) && _ct_same(cur, rec) {
		return .None
	}
	if got >= OVERHEAD {
		n := int(prim.get_u32le(cur)) + OVERHEAD
		if n <= got {
			switch classify(cur[:n], off) {
			case .Redacted:
				return .None
			case .Plain:
				return .Equivocation
			case .Invalid, .Sealed:
			}
		}
	}
	if err := prim.write_at(j.vfs, j.fd, rec, off); err != .None {
		return _err(err)
	}
	j.version += 1
	return _err(prim.datasync(j.vfs, j.fd))
}

@(private)
_ct_same :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	d: u8
	for i in 0 ..< len(a) {
		d |= a[i] ~ b[i]
	}
	return d == 0
}

journal_reader :: proc(j: ^Journal, r: ^Reader, allocator := context.allocator) {
	reader_init(r, j.vfs, j.fd, 0, allocator)
	r.journal = j
	r.version = j.version
}

@(private)
_append :: proc(j: ^Journal, body: []u8, link: bool) -> (off: i64, err: Error) {
	if len(body) > MAX_BODY {
		return 0, .Too_Large
	}
	off = journal_len(j)
	if link && j.chained {
		_link(j, body, off) or_return
	}
	start := len(j.pending)
	if resize(&j.pending, start + len(body) + OVERHEAD) != nil {
		resize(&j.pending, start)
		if link && j.chained {
			pop(&j.links)
		}
		return 0, .No_Memory
	}
	encode_record(j.pending[start:], body, off)
	return off, .None
}

@(private)
_link :: proc(j: ^Journal, body: []u8, off: i64) -> Error {
	c, err := commitment(&j.chain, body, off)
	if err != .None {
		return err
	}
	if _, aerr := append(&j.links, Link{len = u32(len(body)), commit = c}); aerr != nil {
		return .No_Memory
	}
	return .None
}

@(private)
_append_sig :: proc(j: ^Journal) -> (at: int, head: Hash, err: Error) {
	if j.chain.signer.sign == nil {
		return -1, {}, .No_Key
	}
	head = j.head
	pos := j.range_start
	for l in j.links {
		head = chain_fold(head, pos, l)
		pos += i64(l.len) + OVERHEAD
	}
	info := Sig_Info {
		off         = journal_len(j),
		range_start = j.range_start,
		prev_head   = j.head,
		head        = head,
	}
	msg_buf: [SIG_MESSAGE_MAX]u8
	msg := sig_message(msg_buf[:], j.chain.seed, info)
	sig := make([dynamic]u8, context.temp_allocator)
	if !j.chain.signer.sign(j.chain.signer.data, msg, &sig) {
		return -1, {}, .No_Key
	}
	body := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&body)
	prim.write_u8(&w, SIG_KIND)
	prim.write_u8(&w, 1)
	prim.write_uvarint(&w, u64(j.range_start))
	prim.write_uvarint(&w, u64(len(j.links)))
	for l in j.links {
		prim.write_uvarint(&w, u64(l.len))
		c := l.commit
		prim.write_raw(&w, c[:])
	}
	prim.write_raw(&w, info.prev_head[:])
	prim.write_raw(&w, info.head[:])
	prim.write_bytes(&w, sig[:])
	if w.err != .None {
		return -1, {}, .No_Memory
	}
	at = len(j.pending)
	if _, aerr := _append(j, body[:], false); aerr != .None {
		return -1, {}, aerr
	}
	return at, head, .None
}

@(private)
_release :: proc(j: ^Journal) {
	if j.fd >= 0 {
		prim.close_file(j.vfs, j.fd)
	}
	if j.ck_fd >= 0 {
		prim.close_file(j.vfs, j.ck_fd)
	}
	delete(j.pending)
	delete(j.links)
	if len(j.redact_path) > 0 {
		delete(j.redact_path, j.allocator)
	}
	j^ = {
		fd      = prim.INVALID_FD,
		ck_fd   = prim.INVALID_FD,
		open_at = -1,
	}
}

@(private)
_recover :: proc(j: ^Journal, size: i64, keep_at_least: i64) -> Error {
	if size < keep_at_least {
		return .Corrupt
	}
	ck := size if j.sized else _read_checkpoint(j.vfs, j.ck_fd)
	if ck > size {
		return .Corrupt
	}
	end := ck
	if ck < size {
		r: Reader
		reader_init(&r, j.vfs, j.fd, size, context.temp_allocator)
		defer reader_close(&r)
		end = _scan_end(&r, end) or_return
		if end < size && (end < keep_at_least || _damage_within(&r, end, size)) {
			return .Corrupt
		}
	}
	if end < size {
		if err := prim.truncate(j.vfs, j.fd, end); err != .None {
			return _err(err)
		}
	}
	if end > ck {
		if err := prim.resync_range(j.vfs, j.fd, ck, end); err != .None {
			return _err(err)
		}
	} else if end < size {
		if err := prim.datasync(j.vfs, j.fd); err != .None {
			return _err(err)
		}
	}
	j.durable = end
	j.checkpoint = ck
	j.range_start = 0
	if ck != end {
		_write_checkpoint(j)
	}
	return .None
}

@(private)
_scan_end :: proc(r: ^Reader, from: i64) -> (end: i64, err: Error) {
	end = from
	for {
		_, nxt, rerr := record_at(r, end)
		if rerr == .Eof || rerr == .Corrupt || rerr == .Bad_Offset {
			return end, .None
		}
		if rerr != .None && rerr != .Redacted {
			return end, rerr
		}
		end = nxt
	}
}

@(private)
_damage_within :: proc(r: ^Reader, at, size: i64) -> bool {
	if size - at < OVERHEAD {
		return false
	}
	head: [4]u8
	if n, err := prim.read_at(r.vfs, r.fd, head[:], at); err != .None || n != 4 {
		return false
	}
	n := i64(prim.get_u32le(head[:]))
	if n > MAX_BODY {
		return false
	}
	next := at + n + OVERHEAD
	if next >= size {
		return false
	}
	_, _, err := record_at(r, next)
	return err == .None || err == .Redacted
}

journal_peek_len :: proc(vfs: prim.Vfs, path: string) -> (n: i64, err: Error) {
	fd, oerr := prim.open_file(vfs, path, {})
	if oerr != .None {
		return 0, _err(oerr)
	}
	defer prim.close_file(vfs, fd)
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		return 0, _err(serr)
	}
	caps := prim.file_caps(vfs, fd)
	if .Atomic_Group_Commit in caps || .Durable_Size in caps {
		return size, .None
	}
	ck := i64(0)
	ck_path, cerr := _sidecar(path, ".ck", context.temp_allocator)
	if cerr != .None {
		return 0, cerr
	}
	if ck_fd, kerr := prim.open_file(vfs, ck_path, {}); kerr == .None {
		ck = min(_read_checkpoint(vfs, ck_fd), size)
		prim.close_file(vfs, ck_fd)
	}
	r: Reader
	reader_init(&r, vfs, fd, size, context.temp_allocator)
	defer reader_close(&r)
	return _scan_end(&r, ck)
}

@(private)
_recover_chain :: proc(j: ^Journal) -> Error {
	j.head = chain_genesis(j.chain.seed)
	j.range_start = 0
	clear(&j.links)
	r: Reader
	reader_init(&r, j.vfs, j.fd, j.durable, context.temp_allocator)
	r.damage = j.damage
	defer reader_close(&r)
	links := make([dynamic]Link, context.temp_allocator)
	pos := j.durable
	for pos > 0 {
		body, off, err := record_before(&r, pos)
		if err == .Redacted {
			pos = off
			continue
		}
		if err != .None {
			return _structural(err)
		}
		if is_sig(body) {
			info, _, perr := parse_sig(body, off, &links)
			if perr != .None {
				return .Corrupt
			}
			j.head = info.head
			j.range_start = info.end
			break
		}
		pos = off
	}
	pos = j.range_start
	for pos < j.durable {
		body, nxt, err := record_at(&r, pos)
		if err != .None {
			return _structural(err)
		}
		if lerr := _link(j, body, pos); lerr != .None {
			return lerr
		}
		pos = nxt
	}
	return .None
}

@(private)
_structural :: proc "contextless" (err: Error) -> Error {
	#partial switch err {
	case .Eof, .Bad_Offset, .Redacted:
		return .Corrupt
	}
	return err
}

@(private)
_read_checkpoint :: proc(vfs: prim.Vfs, fd: prim.Fd) -> i64 {
	b: [16]u8
	n, rerr := prim.read_at(vfs, fd, b[:], 0)
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
	if j.ck_fd < 0 {
		j.checkpoint = j.durable
		return
	}
	b: [16]u8
	prim.put_u64le(b[0:8], u64(j.durable))
	prim.put_u64le(b[8:16], xxhash.XXH3_64_with_seed(b[0:8], CHECKPOINT_SEED))
	if prim.write_at(j.vfs, j.ck_fd, b[:], 0) == .None {
		j.checkpoint = j.durable
	}
}
