package osync

import "core:crypto"
import "core:crypto/blake2b"
import "../prim"

OBJECT_INLINE_MAX :: 64 * 1024 * 1024
OBJECT_PART :: 16 * 1024 * 1024
OBJECT_HEAD :: 9
OBJECT_MANIFEST :: 13

Object_Layout :: enum u8 {
	Inline,
	Chunked,
}

Object_Info :: struct {
	layout: Object_Layout,
	size:   i64,
	parts:  i64,
}

object_part_index :: proc(key: Object_Key, part: i64) -> Object_Key {
	if part < 0 {
		return key
	}
	out: Object_Key
	b: [8]u8
	prim.put_u64le(b[:], u64(part))
	k := key
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, k[:], 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb chunk"))
	blake2b.update(&ctx, b[:])
	blake2b.final(&ctx, out[:])
	return out
}

object_part_content_key :: proc(ckey: ^[32]u8, part: i64) -> (k: [32]u8) {
	if part < 0 {
		return ckey^
	}
	b: [8]u8
	prim.put_u64le(b[:], u64(part))
	_derive(ckey[:], "0ndb chunk key", b[:], k[:])
	return
}

object_open :: proc(tree: ^Key_Tree, scope: ^Scope, oid: []u8, ciphertext: []u8, allocator := context.allocator) -> (data: []u8, info: Object_Info, err: Error) {
	plain := _object_decrypt(tree, scope, oid, -1, ciphertext, allocator) or_return
	if len(plain) < OBJECT_HEAD {
		delete(plain, allocator)
		return nil, {}, .Corrupt
	}
	kind := plain[0]
	size := prim.get_u64le(plain[1:9])
	switch {
	case kind == 0 && size <= u64(len(plain) - OBJECT_HEAD):
		info = {layout = .Inline, size = i64(size)}
		copy(plain, plain[OBJECT_HEAD:][:size])
		return plain[:size], info, .None
	case kind == 1 && len(plain) >= OBJECT_MANIFEST && prim.get_u32le(plain[9:13]) == OBJECT_PART && size <= u64(max(i64)):
		info = {layout = .Chunked, size = i64(size), parts = (i64(size) + OBJECT_PART - 1) / OBJECT_PART}
		delete(plain, allocator)
		return nil, info, .None
	}
	delete(plain, allocator)
	return nil, {}, .Corrupt
}

object_open_part :: proc(tree: ^Key_Tree, scope: ^Scope, oid: []u8, info: Object_Info, part: i64, ciphertext: []u8, allocator := context.allocator) -> (data: []u8, err: Error) {
	if info.layout != .Chunked || part < 0 || part >= info.parts {
		return nil, .Invalid
	}
	plain := _object_decrypt(tree, scope, oid, part, ciphertext, allocator) or_return
	want := min(OBJECT_PART, info.size - part * OBJECT_PART)
	if i64(len(plain)) != want {
		delete(plain, allocator)
		return nil, .Corrupt
	}
	return plain, .None
}

@(private)
_object_decrypt :: proc(tree: ^Key_Tree, scope: ^Scope, oid: []u8, part: i64, ciphertext: []u8, allocator := context.allocator) -> (plain: []u8, err: Error) {
	if scope.mode == .Transparent {
		out, aerr := make([]u8, len(ciphertext), allocator)
		if aerr != nil {
			return nil, .No_Memory
		}
		copy(out, ciphertext)
		return out, .None
	}
	if tree == nil {
		return nil, .Invalid
	}
	ckey, ok := object_tree_key(tree, scope, oid)
	if !ok {
		return nil, .Permission
	}
	defer crypto.zero_explicit(&ckey, size_of(ckey))
	key := object_part_content_key(&ckey, part)
	defer crypto.zero_explicit(&key, size_of(key))
	n, sok := object_plain_size(i64(len(ciphertext)))
	if !sok {
		return nil, .Corrupt
	}
	out, aerr := make([]u8, int(n), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	o: Object_Opener
	object_opener_init(&o, &key, i64(len(ciphertext)))
	defer object_opener_reset(&o)
	sink := _Object_Collect{out = out}
	if e := object_open_feed(&o, ciphertext, _object_collect, &sink); e != .None || !object_open_done(&o) || sink.pos != len(out) {
		crypto.zero_explicit(raw_data(out), len(out))
		delete(out, allocator)
		return nil, .Corrupt
	}
	return out, .None
}

@(private)
_Object_Collect :: struct {
	out: []u8,
	pos: int,
}

@(private)
_object_collect :: proc(user: rawptr, plain: []u8) -> Error {
	c := cast(^_Object_Collect)user
	if len(plain) > len(c.out) - c.pos {
		return .Corrupt
	}
	copy(c.out[c.pos:], plain)
	c.pos += len(plain)
	return .None
}
