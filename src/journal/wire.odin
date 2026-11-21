package journal

import "core:crypto/chacha20poly1305"
import "../prim"

nonce :: proc "contextless" (off: i64) -> (iv: [chacha20poly1305.IV_SIZE]u8) {
	prim.put_u64le(iv[0:8], u64(off))
	return
}

seal_record :: proc(rec: []u8, off: i64, key: ^Key) -> Error {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	return _seal(&ctx, rec, off)
}

open_record :: proc(rec: []u8, off: i64, key: ^Key) -> Error {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	return _open(&ctx, rec, off)
}

seal_range :: proc(data: []u8, off: i64, key: ^Key) -> Error {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	return _each(&ctx, data, off, _seal)
}

open_range :: proc(data: []u8, off: i64, key: ^Key) -> Error {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	return _each(&ctx, data, off, _open)
}

record_bounds :: proc "contextless" (data: []u8) -> int {
	pos := 0
	for len(data) - pos >= OVERHEAD {
		n := int(prim.get_u32le(data[pos:]))
		if n > MAX_BODY || n + OVERHEAD > len(data) - pos {
			break
		}
		if int(prim.get_u32le(data[pos + HEADER + n:])) != n {
			break
		}
		pos += n + OVERHEAD
	}
	return pos
}

@(private)
_each :: proc(ctx: ^chacha20poly1305.Context, data: []u8, off: i64, f: proc(_: ^chacha20poly1305.Context, _: []u8, _: i64) -> Error) -> Error {
	pos := 0
	for pos < len(data) {
		if len(data) - pos < OVERHEAD {
			return .Corrupt
		}
		n := int(prim.get_u32le(data[pos:]))
		if n > MAX_BODY || n + OVERHEAD > len(data) - pos {
			return .Corrupt
		}
		size := n + OVERHEAD
		if err := f(ctx, data[pos:][:size], off + i64(pos)); err != .None {
			return err
		}
		pos += size
	}
	return .None
}

@(private)
_seal :: proc(ctx: ^chacha20poly1305.Context, rec: []u8, off: i64) -> Error {
	if err := check_record(rec, off); err != .None {
		return err
	}
	body := rec[HEADER:len(rec) - TRAILER]
	iv := nonce(off)
	chacha20poly1305.seal(ctx, body, rec[4:HEADER], iv[:], nil, body)
	return .None
}

@(private)
_open :: proc(ctx: ^chacha20poly1305.Context, rec: []u8, off: i64) -> Error {
	body, err := record_body(rec)
	if err != .None {
		return err
	}
	iv := nonce(off)
	if !chacha20poly1305.open(ctx, body, iv[:], nil, body, rec[4:HEADER]) {
		return .Corrupt
	}
	tag := local_tag(body, off)
	copy(rec[4:HEADER], tag[:])
	return .None
}
