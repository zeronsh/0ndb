package journal

import "core:hash/xxhash"
import "../prim"

@(private)
INTENT_MAGIC :: 0x7463_6164_6572_6e30
@(private)
INTENT_SEED :: 0x696e_7465_6e74

@(private)
_intent_write :: proc(vfs: prim.Vfs, path: string, from, to: i64) -> Error {
	b: [32]u8
	prim.put_u64le(b[0:8], INTENT_MAGIC)
	prim.put_u64le(b[8:16], u64(from))
	prim.put_u64le(b[16:24], u64(to))
	prim.put_u64le(b[24:32], xxhash.XXH3_64_with_seed(b[0:24], INTENT_SEED))
	return _err(prim.replace_atomic(vfs, path, b[:]))
}

@(private)
_intent_read :: proc(vfs: prim.Vfs, path: string) -> (r: Range, ok: bool) {
	fd, err := prim.open_file(vfs, path)
	if err != .None {
		return
	}
	defer prim.close_file(vfs, fd)
	b: [32]u8
	n, rerr := prim.read_at(vfs, fd, b[:], 0)
	if rerr != .None || n != 32 {
		return
	}
	if prim.get_u64le(b[0:8]) != INTENT_MAGIC || xxhash.XXH3_64_with_seed(b[0:24], INTENT_SEED) != prim.get_u64le(b[24:32]) {
		return
	}
	from := prim.get_u64le(b[8:16])
	to := prim.get_u64le(b[16:24])
	if from > to || to > u64(max(i64)) {
		return
	}
	return Range{i64(from), i64(to)}, true
}

@(private)
_Redact_Target :: struct {
	vfs:     prim.Vfs,
	fd:      prim.Fd,
	end:     i64,
	have:    ^[dynamic]Range,
	sealed:  bool,
	replay:  bool,
	missing: Range,
}

@(private)
_redact_apply :: proc(t: ^_Redact_Target, from, to: i64) -> Error {
	if from < 0 || to > t.end || from > to {
		return .Bad_Offset
	}
	buf := make([dynamic]u8, context.temp_allocator)
	result: Error
	pos := from
	walk: for pos + OVERHEAD <= to {
		if t.have != nil {
			if gap, missing := _have_missing(t.have[:], pos, pos + HEADER); missing {
				t.missing = gap
				result = .Missing
				break walk
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
				result = .Missing
				break walk
			}
		}
		if resize(&buf, int(size) + OVERHEAD) != nil {
			return .No_Memory
		}
		if n, err := prim.read_at(t.vfs, t.fd, buf[:], pos); err != .None || n != len(buf) {
			return .Corrupt if err == .None else _err(err)
		}
		kind := classify(buf[:], pos)
		skip := false
		switch kind {
		case .Invalid:
			return .Corrupt
		case .Sealed:
			if !t.sealed && !t.replay {
				return .Corrupt
			}
		case .Plain:
			skip = is_sig(buf[HEADER:][:size])
		case .Redacted:
		}
		if !skip {
			tag := redacted_tag(pos, int(size))
			if err := prim.write_at(t.vfs, t.fd, tag[:], pos + 4); err != .None {
				return _err(err)
			}
			if err := prim.zero_range(t.vfs, t.fd, pos + HEADER, size); err != .None {
				return _err(err)
			}
		}
		pos = rec_end
	}
	if err := prim.datasync(t.vfs, t.fd); err != .None {
		return _err(err)
	}
	return result
}

@(private)
_redact_replay :: proc(t: ^_Redact_Target, intent_path: string) -> Error {
	r, ok := _intent_read(t.vfs, intent_path)
	if !ok {
		if prim.exists(t.vfs, intent_path) {
			prim.remove(t.vfs, intent_path)
		}
		return .None
	}
	t.replay = true
	err := _redact_apply(t, r.from, r.to)
	t.replay = false
	if err != .None && err != .Missing {
		return err
	}
	return _err(prim.remove(t.vfs, intent_path))
}

@(private)
_redact :: proc(t: ^_Redact_Target, intent_path: string, from, to: i64) -> Error {
	if from < 0 || to > t.end || from > to {
		return .Bad_Offset
	}
	if err := _intent_write(t.vfs, intent_path, from, to); err != .None {
		return err
	}
	err := _redact_apply(t, from, to)
	if err != .None && err != .Missing {
		return err
	}
	if rerr := prim.remove(t.vfs, intent_path); rerr != .None {
		return _err(rerr)
	}
	return err
}
