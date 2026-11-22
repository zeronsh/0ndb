package journal

import "core:hash/xxhash"
import "core:slice"
import "../prim"

@(private)
INTENT_MAGIC :: 0x7463_6164_6572_6e31
@(private)
INTENT_SEED :: 0x696e_7465_6e74

@(private)
_Redact_Target :: struct {
	vfs:     prim.Vfs,
	fd:      prim.Fd,
	end:     i64,
	have:    ^[dynamic]Range,
	sealed:  bool,
	keys:    Key_Provider,
	missing: Range,
}

@(private)
_intent_write :: proc(vfs: prim.Vfs, path: string, offs: []i64) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u64le(&w, INTENT_MAGIC)
	prim.write_uvarint(&w, u64(len(offs)))
	for off in offs {
		prim.write_u64le(&w, u64(off))
	}
	if w.err != .None {
		return .No_Memory
	}
	prim.write_u64le(&w, xxhash.XXH3_64_with_seed(buf[:], INTENT_SEED))
	if w.err != .None {
		return .No_Memory
	}
	return _err(prim.replace_atomic(vfs, path, buf[:]))
}

@(private)
_intent_read :: proc(vfs: prim.Vfs, path: string) -> (offs: [dynamic]i64, present: bool, err: Error) {
	data, rerr := prim.read_file(vfs, path, context.temp_allocator)
	if rerr == .Not_Found {
		return nil, false, .None
	}
	if rerr != .None {
		return nil, true, _err(rerr)
	}
	offs = make([dynamic]i64, context.temp_allocator)
	if len(data) < 16 {
		return offs, true, .None
	}
	payload := data[:len(data) - 8]
	if xxhash.XXH3_64_with_seed(payload, INTENT_SEED) != prim.get_u64le(data[len(data) - 8:]) {
		return offs, true, .None
	}
	r := prim.reader(payload)
	if prim.read_u64le(&r) != INTENT_MAGIC {
		return offs, true, .None
	}
	count := prim.read_uvarint(&r)
	if r.err != .None || count != u64(prim.reader_remaining(&r) / 8) {
		return offs, true, .None
	}
	for _ in 0 ..< count {
		v := prim.read_u64le(&r)
		if v > u64(max(i64)) {
			clear(&offs)
			return offs, true, .None
		}
		append(&offs, i64(v))
	}
	return offs, true, .None
}

@(private)
_redact_plan :: proc(t: ^_Redact_Target, from, to: i64, offs: ^[dynamic]i64) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	pos := from
	for pos + OVERHEAD <= to {
		if t.have != nil {
			if gap, missing := _have_missing(t.have[:], pos, pos + HEADER); missing {
				t.missing = gap
				return .Missing
			}
		}
		head: [4]u8
		if n, err := prim.read_at(t.vfs, t.fd, head[:], pos); err != .None || n != 4 {
			return .Corrupt if err == .None else _err(err)
		}
		size := i64(prim.get_u32le(head[:]))
		if size > MAX_BODY {
			return .Corrupt
		}
		rec_end := pos + size + OVERHEAD
		if rec_end > to {
			break
		}
		if t.have != nil {
			if gap, missing := _have_missing(t.have[:], pos, rec_end); missing {
				t.missing = gap
				return .Missing
			}
		}
		if resize(&buf, int(size) + OVERHEAD) != nil {
			return .No_Memory
		}
		if n, err := prim.read_at(t.vfs, t.fd, buf[:], pos); err != .None || n != len(buf) {
			return .Corrupt if err == .None else _err(err)
		}
		body := buf[HEADER:][:size]
		skip := false
		switch classify(buf[:], pos) {
		case .Invalid:
			return .Corrupt
		case .Sealed:
			if !t.sealed {
				return .Corrupt
			}
			if is_sig(body) {
				if t.keys.key == nil {
					return .No_Key
				}
				tag, ok := sig_tag(body, pos, t.keys)
				skip = ok && _tag_eq(tag[:], buf[4:HEADER])
			}
		case .Plain:
			skip = is_sig(body)
		case .Redacted:
		}
		if !skip {
			if _, aerr := append(offs, pos); aerr != nil {
				return .No_Memory
			}
		}
		pos = rec_end
	}
	return .None
}

@(private)
_redact_apply :: proc(t: ^_Redact_Target, offs: []i64) -> Error {
	for off in offs {
		if off < 0 || t.end - off < OVERHEAD {
			return .Corrupt
		}
		head: [4]u8
		if n, err := prim.read_at(t.vfs, t.fd, head[:], off); err != .None || n != 4 {
			return .Corrupt if err == .None else _err(err)
		}
		size := i64(prim.get_u32le(head[:]))
		if size > MAX_BODY || size + OVERHEAD > t.end - off {
			return .Corrupt
		}
		tag := redacted_tag(off, int(size))
		if err := prim.write_at(t.vfs, t.fd, tag[:], off + 4); err != .None {
			return _err(err)
		}
		if err := prim.zero_range(t.vfs, t.fd, off + HEADER, size); err != .None {
			return _err(err)
		}
	}
	return _err(prim.datasync(t.vfs, t.fd))
}

@(private)
_redact_replay :: proc(t: ^_Redact_Target, intent_path: string) -> Error {
	offs, present, err := _intent_read(t.vfs, intent_path)
	if err != .None {
		return err
	}
	if !present {
		return .None
	}
	if err = _redact_apply(t, offs[:]); err != .None {
		return err
	}
	return _err(prim.remove(t.vfs, intent_path))
}

@(private)
_redact :: proc(t: ^_Redact_Target, intent_path: string, from, to: i64) -> Error {
	if from < 0 || to > t.end || from > to {
		return .Bad_Offset
	}
	offs := make([dynamic]i64, context.temp_allocator)
	result := _redact_plan(t, from, to, &offs)
	if result != .None && result != .Missing {
		return result
	}
	if len(offs) == 0 {
		return result
	}
	if err := _redact_logged(t, intent_path, offs[:]); err != .None {
		return err
	}
	return result
}

@(private)
_redact_logged :: proc(t: ^_Redact_Target, intent_path: string, offs: []i64) -> Error {
	if .Atomic_Group_Commit in prim.file_caps(t.vfs, t.fd) {
		return _redact_apply(t, offs)
	}
	all := _intent_merge(t, intent_path, offs) or_return
	_intent_write(t.vfs, intent_path, all) or_return
	_redact_apply(t, all) or_return
	return _err(prim.remove(t.vfs, intent_path))
}

@(private)
_intent_merge :: proc(t: ^_Redact_Target, intent_path: string, offs: []i64) -> (all: []i64, err: Error) {
	prev, present := _intent_read(t.vfs, intent_path) or_return
	if !present || len(prev) == 0 {
		return offs, .None
	}
	merged := make([dynamic]i64, 0, len(prev) + len(offs), context.temp_allocator)
	append(&merged, ..prev[:])
	append(&merged, ..offs)
	slice.sort(merged[:])
	n := 0
	for v, i in merged {
		if i > 0 && v == merged[n - 1] {
			continue
		}
		merged[n] = v
		n += 1
	}
	return merged[:n], .None
}

@(private)
_redact_records :: proc(t: ^_Redact_Target, intent_path: string, offs: []i64) -> Error {
	keep := make([dynamic]i64, context.temp_allocator)
	buf := make([dynamic]u8, context.temp_allocator)
	for off in offs {
		if off < 0 || t.end - off < OVERHEAD {
			return .Bad_Offset
		}
		head: [4]u8
		if n, err := prim.read_at(t.vfs, t.fd, head[:], off); err != .None || n != 4 {
			return .Corrupt if err == .None else _err(err)
		}
		size := i64(prim.get_u32le(head[:]))
		if size > MAX_BODY || size + OVERHEAD > t.end - off {
			return .Corrupt
		}
		if resize(&buf, int(size) + OVERHEAD) != nil {
			return .No_Memory
		}
		if n, err := prim.read_at(t.vfs, t.fd, buf[:], off); err != .None || n != len(buf) {
			return .Corrupt if err == .None else _err(err)
		}
		switch classify(buf[:], off) {
		case .Invalid:
			return .Corrupt
		case .Redacted:
			continue
		case .Sealed:
			if !t.sealed {
				return .Corrupt
			}
		case .Plain:
		}
		if is_sig(buf[HEADER:][:size]) {
			continue
		}
		if _, aerr := append(&keep, off); aerr != nil {
			return .No_Memory
		}
	}
	if len(keep) == 0 {
		return .None
	}
	return _redact_logged(t, intent_path, keep[:])
}
