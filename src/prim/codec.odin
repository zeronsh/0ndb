package prim

import "base:runtime"

Codec_Error :: enum u8 {
	None,
	Short,
	Overflow,
	Invalid,
	No_Memory,
}

Writer :: struct {
	buf: ^[dynamic]u8,
	err: Codec_Error,
}

Reader :: struct {
	data: []u8,
	pos:  int,
	err:  Codec_Error,
}

writer :: proc "contextless" (buf: ^[dynamic]u8) -> Writer {
	return Writer{buf = buf}
}

write_raw :: proc(w: ^Writer, data: []u8) {
	if w.err != .None || len(data) == 0 {
		return
	}
	if _, err := append(w.buf, ..data); err != nil {
		w.err = .No_Memory
	}
}

write_u8 :: proc(w: ^Writer, v: u8) {
	if w.err != .None {
		return
	}
	if _, err := append(w.buf, v); err != nil {
		w.err = .No_Memory
	}
}

write_bool :: proc(w: ^Writer, v: bool) {
	write_u8(w, 1 if v else 0)
}

write_u16le :: proc(w: ^Writer, v: u16) {
	b := [2]u8{u8(v), u8(v >> 8)}
	write_raw(w, b[:])
}

write_u32le :: proc(w: ^Writer, v: u32) {
	b: [4]u8
	put_u32le(b[:], v)
	write_raw(w, b[:])
}

write_u64le :: proc(w: ^Writer, v: u64) {
	b: [8]u8
	put_u64le(b[:], v)
	write_raw(w, b[:])
}

write_uvarint :: proc(w: ^Writer, v: u64) {
	b: [10]u8
	n := put_uvarint(b[:], v)
	write_raw(w, b[:n])
}

write_ivarint :: proc(w: ^Writer, v: i64) {
	write_uvarint(w, zigzag(v))
}

write_bytes :: proc(w: ^Writer, data: []u8) {
	write_uvarint(w, u64(len(data)))
	write_raw(w, data)
}

write_str :: proc(w: ^Writer, s: string) {
	write_bytes(w, transmute([]u8)s)
}

write_id :: proc(w: ^Writer, id: Id) {
	v := id
	write_raw(w, v[:])
}

writer_len :: proc "contextless" (w: ^Writer) -> int {
	return len(w.buf)
}

reader :: proc "contextless" (data: []u8) -> Reader {
	return Reader{data = data}
}

reader_remaining :: proc "contextless" (r: ^Reader) -> int {
	return len(r.data) - r.pos
}

reader_done :: proc "contextless" (r: ^Reader) -> bool {
	return r.err == .None && r.pos == len(r.data)
}

reader_ok :: proc "contextless" (r: ^Reader) -> bool {
	return r.err == .None
}

reader_fail :: proc "contextless" (r: ^Reader, err: Codec_Error) {
	if r.err == .None {
		r.err = err
	}
	r.pos = len(r.data)
}

read_raw :: proc "contextless" (r: ^Reader, n: int) -> []u8 {
	if r.err != .None {
		return nil
	}
	if n < 0 || n > len(r.data) - r.pos {
		reader_fail(r, .Short)
		return nil
	}
	out := r.data[r.pos:][:n]
	r.pos += n
	return out
}

read_rest :: proc "contextless" (r: ^Reader) -> []u8 {
	return read_raw(r, len(r.data) - r.pos)
}

read_fixed :: proc "contextless" (r: ^Reader, dst: []u8) {
	src := read_raw(r, len(dst))
	if src == nil {
		for &b in dst {
			b = 0
		}
		return
	}
	copy(dst, src)
}

read_u8 :: proc "contextless" (r: ^Reader) -> u8 {
	b := read_raw(r, 1)
	if b == nil {
		return 0
	}
	return b[0]
}

read_bool :: proc "contextless" (r: ^Reader) -> bool {
	v := read_u8(r)
	if v > 1 {
		reader_fail(r, .Invalid)
		return false
	}
	return v == 1
}

read_u16le :: proc "contextless" (r: ^Reader) -> u16 {
	b := read_raw(r, 2)
	if b == nil {
		return 0
	}
	return u16(b[0]) | u16(b[1]) << 8
}

read_u32le :: proc "contextless" (r: ^Reader) -> u32 {
	b := read_raw(r, 4)
	if b == nil {
		return 0
	}
	return get_u32le(b)
}

read_u64le :: proc "contextless" (r: ^Reader) -> u64 {
	b := read_raw(r, 8)
	if b == nil {
		return 0
	}
	return get_u64le(b)
}

read_uvarint :: proc "contextless" (r: ^Reader) -> u64 {
	if r.err != .None {
		return 0
	}
	v, n := get_uvarint(r.data[r.pos:])
	if n <= 0 {
		reader_fail(r, .Short if n == 0 else .Overflow)
		return 0
	}
	r.pos += n
	return v
}

read_ivarint :: proc "contextless" (r: ^Reader) -> i64 {
	return unzigzag(read_uvarint(r))
}

read_len :: proc "contextless" (r: ^Reader) -> int {
	v := read_uvarint(r)
	if r.err != .None {
		return 0
	}
	if v > u64(len(r.data) - r.pos) {
		reader_fail(r, .Short)
		return 0
	}
	return int(v)
}

read_bytes :: proc "contextless" (r: ^Reader) -> []u8 {
	n := read_len(r)
	if r.err != .None {
		return nil
	}
	return read_raw(r, n)
}

read_str :: proc "contextless" (r: ^Reader) -> string {
	return string(read_bytes(r))
}

read_id :: proc "contextless" (r: ^Reader) -> (id: Id) {
	read_fixed(r, id[:])
	return
}

read_clone_bytes :: proc(r: ^Reader, allocator := context.allocator) -> (out: []u8, err: runtime.Allocator_Error) {
	b := read_bytes(r)
	if r.err != .None || len(b) == 0 {
		return nil, nil
	}
	out = make([]u8, len(b), allocator) or_return
	copy(out, b)
	return out, nil
}

read_clone_str :: proc(r: ^Reader, allocator := context.allocator) -> (string, runtime.Allocator_Error) {
	b, err := read_clone_bytes(r, allocator)
	return string(b), err
}

put_u32le :: proc "contextless" (b: []u8, v: u32) {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}

put_u64le :: proc "contextless" (b: []u8, v: u64) {
	for i in 0 ..< 8 {
		b[i] = u8(v >> (8 * u64(i)))
	}
}

get_u32le :: proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

get_u64le :: proc "contextless" (b: []u8) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v |= u64(b[i]) << (8 * u64(i))
	}
	return v
}

put_uvarint :: proc "contextless" (b: []u8, v: u64) -> int {
	x := v
	i := 0
	for x >= 0x80 {
		b[i] = u8(x) | 0x80
		x >>= 7
		i += 1
	}
	b[i] = u8(x)
	return i + 1
}

get_uvarint :: proc "contextless" (b: []u8) -> (v: u64, n: int) {
	shift: u64
	for i in 0 ..< len(b) {
		if i == 10 {
			return 0, -1
		}
		c := b[i]
		if c < 0x80 {
			if i == 9 && c > 1 {
				return 0, -1
			}
			return v | u64(c) << shift, i + 1
		}
		v |= u64(c & 0x7f) << shift
		shift += 7
	}
	return 0, 0
}

uvarint_len :: proc "contextless" (v: u64) -> int {
	n := 1
	x := v
	for x >= 0x80 {
		x >>= 7
		n += 1
	}
	return n
}

zigzag :: proc "contextless" (v: i64) -> u64 {
	return u64(v << 1) ~ u64(v >> 63)
}

unzigzag :: proc "contextless" (v: u64) -> i64 {
	return i64(v >> 1) ~ -i64(v & 1)
}
