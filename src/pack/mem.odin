package pack

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"
import "../prim"

@(private)
MEM_HDR :: 7

@(private)
MEM_TOMB :: u8(1)
@(private)
MEM_DIRTY :: u8(2)

@(private)
Mem :: struct {
	arena:     [dynamic]u8,
	slots:     []u32,
	count:     int,
	allocator: runtime.Allocator,
}

@(private)
Mem_Rec :: struct {
	off:   u32,
	flags: u8,
	key:   []u8,
	val:   []u8,
}

@(private)
_mem_init :: proc(m: ^Mem, allocator: runtime.Allocator) {
	m^ = {
		allocator = allocator,
	}
	m.arena = make([dynamic]u8, allocator)
}

@(private)
_mem_destroy :: proc(m: ^Mem) {
	delete(m.arena)
	if m.slots != nil {
		delete(m.slots, m.allocator)
	}
	m.arena = nil
	m.slots = nil
	m.count = 0
}

@(private)
_mem_reset :: proc(m: ^Mem) {
	a := m.allocator
	_mem_destroy(m)
	_mem_init(m, a)
}

@(private)
_mem_bytes :: proc "contextless" (m: ^Mem) -> int {
	return len(m.arena) + len(m.slots) * 4
}

@(private)
_mem_rec :: proc "contextless" (m: ^Mem, off: u32) -> Mem_Rec {
	b := m.arena[off:]
	klen := int(b[1]) | int(b[2]) << 8
	vlen := int(prim.get_u32le(b[3:7]))
	return Mem_Rec{off = off, flags = b[0], key = b[MEM_HDR:][:klen], val = b[MEM_HDR + klen:][:vlen]}
}

@(private)
_mem_find :: proc(m: ^Mem, key: []u8) -> (slot: int, found: bool) {
	if len(m.slots) == 0 {
		return -1, false
	}
	mask := len(m.slots) - 1
	i := int(xxhash.XXH3_64_default(key)) & mask
	for {
		s := m.slots[i]
		if s == 0 {
			return i, false
		}
		r := _mem_rec(m, s - 1)
		if slice.equal(r.key, key) {
			return i, true
		}
		i = (i + 1) & mask
	}
}

@(private)
_mem_get :: proc(m: ^Mem, key: []u8) -> (r: Mem_Rec, found: bool) {
	slot, ok := _mem_find(m, key)
	if !ok {
		return {}, false
	}
	return _mem_rec(m, m.slots[slot] - 1), true
}

@(private)
_mem_grow :: proc(m: ^Mem) -> bool {
	n := max(len(m.slots) * 2, 1024)
	slots, err := make([]u32, n, m.allocator)
	if err != nil {
		return false
	}
	mask := n - 1
	for s in m.slots {
		if s == 0 {
			continue
		}
		r := _mem_rec(m, s - 1)
		i := int(xxhash.XXH3_64_default(r.key)) & mask
		for slots[i] != 0 {
			i = (i + 1) & mask
		}
		slots[i] = s
	}
	if m.slots != nil {
		delete(m.slots, m.allocator)
	}
	m.slots = slots
	return true
}

@(private)
_mem_put :: proc(m: ^Mem, key: []u8, val: []u8, flags: u8) -> (u32, bool) {
	if (m.count + 1) * 2 > len(m.slots) {
		if !_mem_grow(m) {
			return 0, false
		}
	}
	off := len(m.arena)
	if off + MEM_HDR + len(key) + len(val) >= int(max(u32)) {
		return 0, false
	}
	if resize(&m.arena, off + MEM_HDR + len(key) + len(val)) != nil {
		return 0, false
	}
	b := m.arena[off:]
	b[0] = flags
	b[1] = u8(len(key))
	b[2] = u8(len(key) >> 8)
	prim.put_u32le(b[3:7], u32(len(val)))
	copy(b[MEM_HDR:], key)
	copy(b[MEM_HDR + len(key):], val)
	slot, found := _mem_find(m, key)
	m.slots[slot] = u32(off) + 1
	if !found {
		m.count += 1
	}
	return u32(off), true
}

@(private)
_mem_clear_dirty :: proc "contextless" (m: ^Mem, off: u32) {
	m.arena[off] &~= MEM_DIRTY
}

@(private)
_mem_sorted :: proc(m: ^Mem, lo: []u8, hi: []u8, allocator: runtime.Allocator) -> []u32 {
	out := make([dynamic]u32, 0, 16, allocator)
	for s in m.slots {
		if s == 0 {
			continue
		}
		r := _mem_rec(m, s - 1)
		if lo != nil && _key_cmp(r.key, lo) < 0 {
			continue
		}
		if hi != nil && _key_cmp(r.key, hi) >= 0 {
			continue
		}
		append(&out, s - 1)
	}
	ctx := m
	slice.sort_by_with_data(out[:], proc(a, b: u32, data: rawptr) -> bool {
		mm := (^Mem)(data)
		return _key_cmp(_mem_rec(mm, a).key, _mem_rec(mm, b).key) < 0
	}, rawptr(ctx))
	return out[:]
}

@(private)
_key_cmp :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else 1
}
