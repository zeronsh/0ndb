package journal

import "core:hash/xxhash"
import "core:strconv"
import "../prim"

HEADER :: 20
TRAILER :: 4
OVERHEAD :: HEADER + TRAILER
MAX_BODY :: 64 * 1024 * 1024
WINDOW :: 16 * 1024
PENDING_KEEP :: 64 * 1024

Error :: enum u8 {
	None,
	Eof,
	Corrupt,
	Missing,
	Too_Large,
	Bad_Offset,
	Invalid,
	Busy,
	Not_Found,
	Permission,
	No_Space,
	No_Memory,
	Io,
}

Range :: struct {
	from: i64,
	to:   i64,
}

Key :: [32]u8

Tag :: [16]u8

record_size :: proc "contextless" (body_len: int) -> i64 {
	return i64(body_len) + OVERHEAD
}

local_tag :: proc(body: []u8, off: i64) -> (tag: Tag) {
	h := xxhash.XXH3_128_with_seed(body, u64(off))
	prim.put_u64le(tag[0:8], u64(h))
	prim.put_u64le(tag[8:16], u64(h >> 64))
	return
}

encode_record :: proc(dst: []u8, body: []u8, off: i64) -> int {
	n := len(body)
	prim.put_u32le(dst[0:4], u32(n))
	copy(dst[HEADER:], body)
	tag := local_tag(body, off)
	copy(dst[4:HEADER], tag[:])
	prim.put_u32le(dst[HEADER + n:], u32(n))
	return n + OVERHEAD
}

record_body :: proc "contextless" (rec: []u8) -> ([]u8, Error) {
	if len(rec) < OVERHEAD {
		return nil, .Corrupt
	}
	n := int(prim.get_u32le(rec[0:4]))
	if n > MAX_BODY || n + OVERHEAD != len(rec) || int(prim.get_u32le(rec[HEADER + n:])) != n {
		return nil, .Corrupt
	}
	return rec[HEADER:][:n], .None
}

check_record :: proc(rec: []u8, off: i64) -> Error {
	body, err := record_body(rec)
	if err != .None {
		return err
	}
	tag := local_tag(body, off)
	if !_tag_eq(tag[:], rec[4:HEADER]) {
		return .Corrupt
	}
	return .None
}

epoch_path :: proc(base: string, epoch: u64, allocator := context.allocator) -> (string, Error) {
	digits: [24]u8
	num := strconv.write_uint(digits[:], epoch, 10)
	out, err := make([]u8, len(base) + 2 + len(num), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, base)
	n += copy(out[n:], ".e")
	copy(out[n:], num)
	return string(out), .None
}

journal_remove :: proc(path: string) -> Error {
	err := prim.remove(path)
	for suffix in ([]string{".ck", ".have"}) {
		buf: prim.Path_Buf
		if len(path) + len(suffix) >= len(buf) {
			return .Invalid
		}
		n := copy(buf[:], path)
		n += copy(buf[n:], suffix)
		if e := prim.remove(string(buf[:n])); e != .None && e != .Not_Found && err == .None {
			err = e
		}
	}
	if err == .Not_Found {
		return .None
	}
	return _err(err)
}

@(private)
_tag_eq :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	d: u8
	for i in 0 ..< len(a) {
		d |= a[i] ~ b[i]
	}
	return d == 0
}

@(private)
_err :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Permission:
		return .Permission
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Busy, .Would_Block:
		return .Busy
	case .Too_Large:
		return .Too_Large
	case .Invalid:
		return .Invalid
	}
	return .Io
}

@(private)
_sidecar :: proc(path: string, suffix: string, allocator := context.allocator) -> (string, Error) {
	out, err := make([]u8, len(path) + len(suffix), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, path)
	copy(out[n:], suffix)
	return string(out), .None
}
