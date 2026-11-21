package odb

import "base:runtime"
import "core:crypto"
import hashing "core:hash"
import "core:os"

@(private)
STORED_BLOCK :: 65535

@(private)
Buf_Writer :: struct {
	f:      ^os.File,
	buf:    []u8,
	n:      int,
	pos:    i64,
	crc:    u32,
	sha:    ^Hasher,
	err:    Error,
}

@(private)
bw_flush :: proc(w: ^Buf_Writer) -> Error {
	if w.err != .None {
		return w.err
	}
	if w.n > 0 {
		if _, err := os.write(w.f, w.buf[:w.n]); err != nil {
			w.err = .Io
			return w.err
		}
		w.n = 0
	}
	return .None
}

@(private)
bw_write :: proc(w: ^Buf_Writer, data: []u8) {
	if w.err != .None || len(data) == 0 {
		return
	}
	w.crc = hashing.crc32(data, w.crc)
	if w.sha != nil {
		hasher_update(w.sha, data)
	}
	w.pos += i64(len(data))
	data := data
	for len(data) > 0 {
		if w.n == len(w.buf) && bw_flush(w) != .None {
			return
		}
		k := copy(w.buf[w.n:], data)
		w.n += k
		data = data[k:]
	}
}

@(private)
Zstream :: struct {
	left:       i64,
	block_left: int,
	adler:      u32,
}

@(private)
zlib_stored_size :: proc "contextless" (total: i64) -> i64 {
	blocks := max((total + STORED_BLOCK - 1) / STORED_BLOCK, 1)
	return 2 + blocks * 5 + total + 4
}

@(private)
z_begin :: proc(w: ^Buf_Writer, z: ^Zstream, total: i64) {
	z^ = {left = total, adler = 1}
	bw_write(w, {0x78, 0x01})
	if total == 0 {
		bw_write(w, {0x01, 0x00, 0x00, 0xff, 0xff})
	}
}

@(private)
z_write :: proc(w: ^Buf_Writer, z: ^Zstream, data: []u8) -> Error {
	if i64(len(data)) > z.left {
		return .Changed
	}
	data := data
	for len(data) > 0 {
		if z.block_left == 0 {
			n := int(min(z.left, STORED_BLOCK))
			final: u8 = 1 if z.left <= STORED_BLOCK else 0
			bw_write(w, {final, u8(n), u8(n >> 8), ~u8(n), ~u8(n >> 8)})
			z.block_left = n
		}
		k := min(len(data), z.block_left)
		bw_write(w, data[:k])
		z.adler = hashing.adler32(data[:k], z.adler)
		z.left -= i64(k)
		z.block_left -= k
		data = data[k:]
	}
	return w.err
}

@(private)
z_end :: proc(w: ^Buf_Writer, z: ^Zstream) -> Error {
	if z.left != 0 {
		return .Changed
	}
	a := z.adler
	bw_write(w, {u8(a >> 24), u8(a >> 16), u8(a >> 8), u8(a)})
	return w.err
}

@(private)
create_temp :: proc(dir, prefix: string, buf: []u8) -> (f: ^os.File, path: string, err: Error) {
	for _ in 0 ..< 16 {
		rnd: [6]u8
		crypto.rand_bytes(rnd[:])
		n := copy(buf, dir)
		n += copy(buf[n:], "/")
		n += copy(buf[n:], prefix)
		for b in rnd {
			if n + 2 > len(buf) {
				return nil, "", .Invalid
			}
			buf[n] = HEX_DIGITS[b >> 4]
			buf[n + 1] = HEX_DIGITS[b & 15]
			n += 2
		}
		path = string(buf[:n])
		ferr: os.Error
		f, ferr = os.open(path, {.Read, .Write, .Create, .Excl, .Trunc}, os.perm_number(0o444))
		if ferr == nil {
			return f, path, .None
		}
		if ferr != .Exist {
			return nil, "", map_os_error(ferr)
		}
	}
	return nil, "", .Io
}

@(private)
map_os_error :: proc(err: os.Error) -> Error {
	if err == nil {
		return .None
	}
	#partial switch e in err {
	case os.General_Error:
		#partial switch e {
		case .Not_Exist:
			return .Not_Found
		case .Exist:
			return .Invalid
		}
	case runtime.Allocator_Error:
		return .Out_Of_Memory
	}
	return .Io
}
