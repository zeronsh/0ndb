package odb

import "core:crypto/legacy/sha1"
import "core:crypto/sha2"
import "core:encoding/endian"

Hash_Mode :: enum u8 {
	Fast,
	Software,
	Detect_Collisions,
}

Hasher :: struct {
	format: Hash_Format,
	mode:   Hash_Mode,
	hw:     bool,
	state:  [5]u32,
	block:  [64]u8,
	used:   int,
	length: u64,
	soft:   sha1.Context,
	dc:     Sha1dc,
	sha256: sha2.Context_256,
}

sha1_hardware :: proc "contextless" () -> bool {
	return sha1_hw_supported()
}

hasher_init :: proc(h: ^Hasher, format: Hash_Format, mode := Hash_Mode.Fast) {
	h.format = format
	h.mode = mode
	h.used = 0
	h.length = 0
	h.hw = false
	if format == .Sha256 {
		sha2.init_256(&h.sha256)
		return
	}
	switch mode {
	case .Fast:
		if sha1_hw_supported() {
			h.hw = true
			h.state = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0}
		} else {
			sha1.init(&h.soft)
		}
	case .Software:
		sha1.init(&h.soft)
	case .Detect_Collisions:
		sha1dc_init(&h.dc)
	}
}

hasher_update :: proc(h: ^Hasher, data: []u8) {
	if h.format == .Sha256 {
		sha2.update(&h.sha256, data)
		return
	}
	if !h.hw {
		if h.mode == .Detect_Collisions {
			sha1dc_update(&h.dc, data)
		} else {
			sha1.update(&h.soft, data)
		}
		return
	}
	data := data
	h.length += u64(len(data))
	if h.used > 0 {
		n := copy(h.block[h.used:], data)
		h.used += n
		data = data[n:]
		if h.used < 64 {
			return
		}
		sha1_hw_blocks(&h.state, h.block[:])
		h.used = 0
	}
	whole := len(data) &~ 63
	if whole > 0 {
		sha1_hw_blocks(&h.state, data[:whole])
		data = data[whole:]
	}
	h.used = copy(h.block[:], data)
}

hasher_final :: proc(h: ^Hasher) -> (oid: Oid, err: Error) {
	if h.format == .Sha256 {
		sha2.final(&h.sha256, oid[:32])
		return
	}
	if !h.hw {
		if h.mode == .Detect_Collisions {
			digest, collision := sha1dc_final(&h.dc)
			copy(oid[:20], digest[:])
			return oid, .Collision if collision else .None
		}
		sha1.final(&h.soft, oid[:20])
		return
	}
	bits := h.length * 8
	h.block[h.used] = 0x80
	h.used += 1
	if h.used > 56 {
		for i in h.used ..< 64 {
			h.block[i] = 0
		}
		sha1_hw_blocks(&h.state, h.block[:])
		h.used = 0
	}
	for i in h.used ..< 56 {
		h.block[i] = 0
	}
	endian.unchecked_put_u64be(h.block[56:], bits)
	sha1_hw_blocks(&h.state, h.block[:])
	for v, i in h.state {
		endian.unchecked_put_u32be(oid[i * 4:], v)
	}
	return
}

hasher_header :: proc(h: ^Hasher, type: Object_Type, size: i64) {
	buf: [32]u8
	hasher_update(h, object_header(buf[:], type, size))
}

hash :: proc(format: Hash_Format, type: Object_Type, data: []u8, mode := Hash_Mode.Fast) -> (Oid, Error) {
	h: Hasher
	hasher_init(&h, format, mode)
	hasher_header(&h, type, i64(len(data)))
	hasher_update(&h, data)
	return hasher_final(&h)
}

hash_bytes :: proc(format: Hash_Format, data: []u8) -> Oid {
	h: Hasher
	hasher_init(&h, format)
	hasher_update(&h, data)
	oid, _ := hasher_final(&h)
	return oid
}
