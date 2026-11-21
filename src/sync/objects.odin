package osync

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "../prim"

OBJECT_CHUNK :: 64 * 1024
OBJECT_TAG :: chacha20poly1305.TAG_SIZE
OBJECT_SEALED_CHUNK :: OBJECT_CHUNK + OBJECT_TAG

Object_Sealer :: struct {
	ctx:   chacha20poly1305.Context,
	index: u64,
	total: i64,
	done:  i64,
}

Object_Opener :: struct {
	ctx:    chacha20poly1305.Context,
	index:  u64,
	chunks: u64,
	sealed: i64,
	seen:   i64,
	buf:    [OBJECT_SEALED_CHUNK]u8,
	have:   int,
}

Object_Sink :: #type proc(user: rawptr, plain: []u8) -> Error

object_sealed_size :: proc "contextless" (n: i64) -> i64 {
	chunks := max((n + OBJECT_CHUNK - 1) / OBJECT_CHUNK, 1)
	return n + chunks * OBJECT_TAG
}

object_plain_size :: proc "contextless" (sealed: i64) -> (n: i64, ok: bool) {
	if sealed < OBJECT_TAG {
		return 0, false
	}
	chunks := (sealed + OBJECT_SEALED_CHUNK - 1) / OBJECT_SEALED_CHUNK
	n = sealed - chunks * OBJECT_TAG
	if n < 0 || object_sealed_size(n) != sealed {
		return 0, false
	}
	return n, true
}

object_sealer_init :: proc(s: ^Object_Sealer, key: ^[32]u8, total: i64) {
	chacha20poly1305.init(&s.ctx, key[:])
	s.index = 0
	s.total = total
	s.done = 0
}

object_sealer_reset :: proc(s: ^Object_Sealer) {
	chacha20poly1305.reset(&s.ctx)
	s^ = {}
}

object_seal_next :: proc(s: ^Object_Sealer, plain: []u8, dst: []u8) -> (n: int, err: Error) {
	want := int(min(s.total - s.done, OBJECT_CHUNK))
	if len(plain) != want || len(dst) < want + OBJECT_TAG || (want == 0 && s.index > 0) {
		return 0, .Invalid
	}
	last := s.done + i64(want) == s.total
	iv := _object_iv(s.index, last)
	chacha20poly1305.seal(&s.ctx, dst[:want], dst[want:want + OBJECT_TAG], iv[:], nil, plain)
	s.index += 1
	s.done += i64(want)
	return want + OBJECT_TAG, .None
}

object_sealer_done :: proc "contextless" (s: ^Object_Sealer) -> bool {
	return s.done == s.total && s.index > 0
}

object_seal :: proc(key: ^[32]u8, plain: []u8, dst: []u8) -> (n: int, err: Error) {
	s: Object_Sealer
	object_sealer_init(&s, key, i64(len(plain)))
	defer object_sealer_reset(&s)
	pos := 0
	for !object_sealer_done(&s) {
		k := min(len(plain) - pos, OBJECT_CHUNK)
		w := object_seal_next(&s, plain[pos:][:k], dst[n:]) or_return
		pos += k
		n += w
	}
	return n, .None
}

object_opener_init :: proc(o: ^Object_Opener, key: ^[32]u8, sealed: i64) -> Error {
	if _, ok := object_plain_size(sealed); !ok {
		return .Corrupt
	}
	chacha20poly1305.init(&o.ctx, key[:])
	o.index = 0
	o.chunks = u64((sealed + OBJECT_SEALED_CHUNK - 1) / OBJECT_SEALED_CHUNK)
	o.sealed = sealed
	o.seen = 0
	o.have = 0
	return .None
}

object_opener_reset :: proc(o: ^Object_Opener) {
	chacha20poly1305.reset(&o.ctx)
	crypto.zero_explicit(o, size_of(Object_Opener))
}

object_open_feed :: proc(o: ^Object_Opener, data: []u8, sink: Object_Sink, user: rawptr) -> Error {
	pos := 0
	for pos < len(data) {
		if o.index >= o.chunks {
			return .Corrupt
		}
		chunk := int(min(o.sealed - o.seen, OBJECT_SEALED_CHUNK))
		k := min(chunk - o.have, len(data) - pos)
		copy(o.buf[o.have:], data[pos:][:k])
		o.have += k
		pos += k
		if o.have < chunk {
			break
		}
		o.seen += i64(chunk)
		last := o.index + 1 == o.chunks
		iv := _object_iv(o.index, last)
		body := o.buf[:chunk - OBJECT_TAG]
		if !chacha20poly1305.open(&o.ctx, body, iv[:], nil, body, o.buf[chunk - OBJECT_TAG:chunk]) {
			return .Corrupt
		}
		o.index += 1
		o.have = 0
		sink(user, body) or_return
	}
	return .None
}

object_open_done :: proc "contextless" (o: ^Object_Opener) -> bool {
	return o.index == o.chunks && o.have == 0 && o.seen == o.sealed
}

@(private)
_object_iv :: proc "contextless" (index: u64, last: bool) -> (iv: [12]u8) {
	prim.put_u64le(iv[0:8], index)
	iv[8] = 1 if last else 0
	return
}
