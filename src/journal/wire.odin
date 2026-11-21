package journal

import "core:crypto/chacha20poly1305"
import "../prim"

nonce :: proc "contextless" (off: i64) -> (iv: [chacha20poly1305.IV_SIZE]u8) {
	prim.put_u64le(iv[0:8], u64(off))
	return
}

seal_record :: proc(rec: []u8, off: i64, keys: Key_Provider) -> Error {
	return _seal(rec, off, keys)
}

open_record :: proc(rec: []u8, off: i64, keys: Key_Provider) -> Error {
	return _open(rec, off, keys)
}

seal_range :: proc(data: []u8, off: i64, keys: Key_Provider) -> Error {
	return _each(data, off, keys, _seal)
}

open_range :: proc(data: []u8, off: i64, keys: Key_Provider) -> Error {
	return _each(data, off, keys, _open)
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
_each :: proc(data: []u8, off: i64, keys: Key_Provider, f: proc(_: []u8, _: i64, _: Key_Provider) -> Error) -> Error {
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
		if err := f(data[pos:][:size], off + i64(pos), keys); err != .None {
			return err
		}
		pos += size
	}
	return .None
}

@(private)
_seal :: proc(rec: []u8, off: i64, keys: Key_Provider) -> Error {
	body, berr := record_body(rec)
	if berr != .None {
		return berr
	}
	switch classify(rec, off) {
	case .Invalid, .Sealed:
		return .Corrupt
	case .Redacted:
		return .None
	case .Plain:
		if is_sig(body) {
			return .None
		}
	}
	if keys.key == nil {
		return .No_Key
	}
	k: Key
	if !keys.key(keys.data, off, &k) {
		return .No_Key
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	_zero(k[:])
	iv := nonce(off)
	chacha20poly1305.seal(&ctx, body, rec[4:HEADER], iv[:], nil, body)
	chacha20poly1305.reset(&ctx)
	return .None
}

@(private)
_open :: proc(rec: []u8, off: i64, keys: Key_Provider) -> Error {
	body, berr := record_body(rec)
	if berr != .None {
		return berr
	}
	switch classify(rec, off) {
	case .Invalid:
		return .Corrupt
	case .Redacted:
		return .None
	case .Plain:
		if is_sig(body) {
			return .None
		}
		return .Corrupt
	case .Sealed:
	}
	if keys.key == nil {
		return .No_Key
	}
	k: Key
	if !keys.key(keys.data, off, &k) {
		return .No_Key
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	_zero(k[:])
	iv := nonce(off)
	ok := chacha20poly1305.open(&ctx, body, iv[:], nil, body, rec[4:HEADER])
	chacha20poly1305.reset(&ctx)
	if !ok {
		return .Corrupt
	}
	tag := local_tag(body, off)
	copy(rec[4:HEADER], tag[:])
	return .None
}
