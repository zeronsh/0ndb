package journal

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

Replica :: struct {
	vfs:       prim.Vfs,
	fd:        prim.Fd,
	have:      [dynamic]Range,
	length:    i64,
	version:   u64,
	have_path: string,
	redact:    string,
	missing:   Range,
	allocator: runtime.Allocator,
}

@(private)
HAVE_MAGIC :: 0x6576_6168_6264_6e30
@(private)
HAVE_SEED :: 0x6861_7665

replica_open :: proc(rep: ^Replica, vfs: prim.Vfs, path: string, allocator := context.allocator) -> Error {
	rep^ = {
		vfs       = vfs,
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	fd, oerr := prim.open_file(vfs, path, {.Write}, 0o600)
	if oerr == .Not_Found {
		fd, oerr = prim.open_file(vfs, path, {.Write, .Create, .Exclusive}, 0o600)
		if oerr == .None {
			if serr := prim.sync_dir(vfs, prim.dir_name(path)); serr != .None {
				prim.close_file(vfs, fd)
				return _err(serr)
			}
		}
	}
	if oerr != .None {
		return _err(oerr)
	}
	rep.fd = fd
	have_path, herr := _sidecar(path, ".have", allocator)
	if herr != .None {
		replica_close(rep)
		return herr
	}
	rep.have_path = have_path
	redact, rerr := _sidecar(path, ".redact", allocator)
	if rerr != .None {
		replica_close(rep)
		return rerr
	}
	rep.redact = redact
	rep.have = make([dynamic]Range, allocator)
	if err := _load_have(rep); err != .None {
		replica_close(rep)
		return err
	}
	t := _target(rep)
	if err := _redact_replay(&t, rep.redact); err != .None {
		replica_close(rep)
		return err
	}
	return .None
}

replica_redact :: proc(rep: ^Replica, from, to: i64) -> Error {
	t := _target(rep)
	err := _redact(&t, rep.redact, from, to)
	if err == .Missing {
		rep.missing = t.missing
	}
	rep.version += 1
	return err
}

@(private)
_target :: proc(rep: ^Replica) -> _Redact_Target {
	return _Redact_Target{vfs = rep.vfs, fd = rep.fd, end = rep.length, have = &rep.have, sealed = true}
}

replica_close :: proc(rep: ^Replica) {
	if rep.fd >= 0 {
		prim.close_file(rep.vfs, rep.fd)
	}
	delete(rep.have)
	if len(rep.have_path) > 0 {
		delete(rep.have_path, rep.allocator)
	}
	if len(rep.redact) > 0 {
		delete(rep.redact, rep.allocator)
	}
	rep^ = {
		fd = prim.INVALID_FD,
	}
}

replica_reader :: proc(rep: ^Replica, r: ^Reader, allocator := context.allocator) {
	reader_init(r, rep.vfs, rep.fd, 0, allocator)
	r.replica = rep
	r.version = rep.version
}

replica_have :: proc "contextless" (rep: ^Replica) -> []Range {
	return rep.have[:]
}

replica_length :: proc "contextless" (rep: ^Replica) -> i64 {
	return rep.length
}

replica_write :: proc(rep: ^Replica, off: i64, data: []u8) -> Error {
	if off < 0 {
		return .Bad_Offset
	}
	if len(data) == 0 {
		return .None
	}
	if err := prim.write_at(rep.vfs, rep.fd, data, off); err != .None {
		return _err(err)
	}
	if err := prim.datasync(rep.vfs, rep.fd); err != .None {
		return _err(err)
	}
	if err := _add_range(&rep.have, {off, off + i64(len(data))}); err != .None {
		return err
	}
	rep.length = max(rep.length, off + i64(len(data)))
	rep.version += 1
	return _save_have(rep)
}

replica_set_length :: proc(rep: ^Replica, length: i64) -> Error {
	if length <= rep.length {
		return .None
	}
	rep.length = length
	rep.version += 1
	return _save_have(rep)
}

replica_covers :: proc "contextless" (rep: ^Replica, from, to: i64) -> bool {
	_, missing := replica_missing(rep, from, to)
	return !missing
}

replica_missing :: proc "contextless" (rep: ^Replica, from, to: i64) -> (gap: Range, missing: bool) {
	return _have_missing(rep.have[:], from, to)
}

@(private)
_have_missing :: proc "contextless" (have: []Range, from, to: i64) -> (gap: Range, missing: bool) {
	if to <= from {
		return
	}
	lo, hi := 0, len(have)
	for lo < hi {
		mid := (lo + hi) / 2
		if have[mid].to <= from {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	first: i64 = -1
	last: i64 = -1
	pos := from
	i := lo
	for pos < to {
		if i < len(have) && have[i].from <= pos {
			pos = have[i].to
			i += 1
			continue
		}
		gap_end := to
		if i < len(have) {
			gap_end = min(have[i].from, to)
		}
		if first < 0 {
			first = pos
		}
		last = gap_end
		pos = gap_end
	}
	if first < 0 {
		return
	}
	return Range{first, last}, true
}

@(private)
_add_range :: proc(have: ^[dynamic]Range, r: Range) -> Error {
	lo, hi := 0, len(have)
	for lo < hi {
		mid := (lo + hi) / 2
		if have[mid].to < r.from {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	merged := r
	j := lo
	for j < len(have) && have[j].from <= merged.to {
		merged.from = min(merged.from, have[j].from)
		merged.to = max(merged.to, have[j].to)
		j += 1
	}
	if j > lo {
		have[lo] = merged
		remove_range(have, lo + 1, j)
		return .None
	}
	if _, err := inject_at(have, lo, merged); err != nil {
		return .No_Memory
	}
	return .None
}

@(private)
_save_have :: proc(rep: ^Replica) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u64le(&w, HAVE_MAGIC)
	prim.write_uvarint(&w, u64(rep.length))
	prim.write_uvarint(&w, u64(len(rep.have)))
	prev: i64
	for r in rep.have {
		prim.write_uvarint(&w, u64(r.from - prev))
		prim.write_uvarint(&w, u64(r.to - r.from))
		prev = r.to
	}
	if w.err != .None {
		return .No_Memory
	}
	prim.write_u64le(&w, xxhash.XXH3_64_with_seed(buf[:], HAVE_SEED))
	if w.err != .None {
		return .No_Memory
	}
	return _err(prim.replace_atomic(rep.vfs, rep.have_path, buf[:]))
}

@(private)
_load_have :: proc(rep: ^Replica) -> Error {
	data, err := prim.read_file(rep.vfs, rep.have_path, context.temp_allocator)
	if err == .Not_Found {
		return .None
	}
	if err != .None {
		return _err(err)
	}
	if len(data) < 16 {
		return .None
	}
	payload := data[:len(data) - 8]
	if xxhash.XXH3_64_with_seed(payload, HAVE_SEED) != prim.get_u64le(data[len(data) - 8:]) {
		return .None
	}
	r := prim.reader(payload)
	if prim.read_u64le(&r) != HAVE_MAGIC {
		return .None
	}
	length := prim.read_uvarint(&r)
	count := prim.read_uvarint(&r)
	if r.err != .None || length > u64(max(i64)) || count > u64(prim.reader_remaining(&r) / 2) {
		return .None
	}
	if rerr := reserve(&rep.have, int(count)); rerr != nil {
		return .No_Memory
	}
	prev: u64
	for _ in 0 ..< count {
		gap := prim.read_uvarint(&r)
		size := prim.read_uvarint(&r)
		if r.err != .None || size == 0 || gap > length || size > length {
			clear(&rep.have)
			return .None
		}
		from := prev + gap
		to := from + size
		if (len(rep.have) > 0 && gap == 0) || from < prev || to < from || to > length {
			clear(&rep.have)
			return .None
		}
		append(&rep.have, Range{i64(from), i64(to)})
		prev = to
	}
	if !prim.reader_done(&r) {
		clear(&rep.have)
		return .None
	}
	rep.length = i64(length)
	return .None
}
