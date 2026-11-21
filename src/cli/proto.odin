package main

import "../prim"

MAGIC :: "0NDB"
PROTO_VERSION :: u8(1)
FRAME_MAX :: 64 << 20

Frame_Kind :: enum u8 {
	None        = 0,
	Call        = 1,
	Result      = 2,
	Subscribe   = 3,
	Deltas      = 4,
	Unsubscribe = 5,
	Mcp         = 6,
	Events      = 7,
	Event       = 8,
}

frame_put :: proc(out: ^[dynamic]u8, kind: Frame_Kind, parts: ..[]u8) {
	n := 0
	for p in parts {
		n += len(p)
	}
	hdr: [5]u8
	prim.put_u32le(hdr[:4], u32(n))
	hdr[4] = u8(kind)
	append(out, ..hdr[:])
	for p in parts {
		append(out, ..p)
	}
}

frame_next :: proc(buf: []u8) -> (kind: Frame_Kind, payload: []u8, used: int, ok: bool, bad: bool) {
	if len(buf) < 5 {
		return
	}
	n := int(prim.get_u32le(buf[:4]))
	if n > FRAME_MAX {
		return .None, nil, 0, false, true
	}
	if len(buf) < 5 + n {
		return
	}
	return Frame_Kind(buf[4]), buf[5:5 + n], 5 + n, true, false
}

u64_bytes :: proc(v: u64) -> (out: [8]u8) {
	prim.put_u64le(out[:], v)
	return
}
