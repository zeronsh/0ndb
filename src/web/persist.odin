package web

import "../prim"

Log_Op :: enum u8 {
	Reset    = 1,
	Write    = 2,
	Truncate = 3,
	Punch    = 4,
	Rename   = 5,
	Unlink   = 6,
}

@(private)
LOG_HEAD :: 1 + 2 + 8 + 8 + 4

@(private)
_log :: proc(m: ^Mem_Vfs, op: Log_Op, path: string, a: i64, data: []u8, b: i64 = 0) {
	if !m.logging || m.muted || (len(path) == 0 && op != .Reset) {
		return
	}
	head: [LOG_HEAD]u8
	head[0] = u8(op)
	head[1] = u8(len(path))
	head[2] = u8(len(path) >> 8)
	prim.put_u64le(head[3:11], u64(a))
	prim.put_u64le(head[11:19], u64(b))
	prim.put_u32le(head[19:23], u32(len(data)))
	append(&m.log, ..head[:])
	append(&m.log, path)
	append(&m.log, ..data)
}

mem_vfs_snapshot :: proc(m: ^Mem_Vfs) {
	was := m.logging
	m.logging = true
	clear(&m.log)
	_log(m, .Reset, "", 0, nil)
	for path in prim.sorted_keys(m.files) {
		if path not_in m.files {
			continue
		}
		n := m.files[path]
		for &e in n.ext {
			_log(m, .Write, path, e.off, e.data[:])
		}
		_log(m, .Truncate, path, n.size, nil)
	}
	m.logging = was
}

mem_vfs_restore :: proc(m: ^Mem_Vfs, log: []u8) -> bool {
	m.muted = true
	defer m.muted = false
	vfs := mem_vfs(m)
	p := 0
	for p + LOG_HEAD <= len(log) {
		op := Log_Op(log[p])
		plen := int(log[p + 1]) | int(log[p + 2]) << 8
		a := i64(prim.get_u64le(log[p + 3:p + 11]))
		b := i64(prim.get_u64le(log[p + 11:p + 19]))
		dlen := int(prim.get_u32le(log[p + 19:p + 23]))
		p += LOG_HEAD
		if plen > len(log) - p || dlen > len(log) - p - plen || a < 0 || b < 0 {
			return false
		}
		path := string(log[p:p + plen])
		data := log[p + plen:p + plen + dlen]
		p += plen + dlen
		switch op {
		case .Reset:
			names := make([dynamic]string, context.temp_allocator)
			for k in prim.sorted_keys(m.files) {
				append(&names, k)
			}
			for k in names {
				_mem_unlink(m, k)
			}
		case .Write, .Truncate, .Punch:
			fd, err := _mem_open(m, path, {.Write, .Create}, 0o600)
			if err != .None {
				return false
			}
			#partial switch op {
			case .Write:
				prim.write_at(vfs, fd, data, a)
			case .Truncate:
				prim.truncate(vfs, fd, a)
			case .Punch:
				prim.punch_hole(vfs, fd, a, b)
			}
			_mem_close(m, fd)
		case .Rename:
			_mem_rename(m, path, string(data))
		case .Unlink:
			_mem_unlink(m, path)
		case:
			return false
		}
	}
	return p == len(log)
}
