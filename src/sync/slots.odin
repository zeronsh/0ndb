package osync

import "core:hash/xxhash"
import "../prim"

SLOT_SPACING :: 512
SLOTS_SIZE :: 2 * SLOT_SPACING

Layout :: struct {
	spacing: i64,
	base:    i64,
	exact:   bool,
}

LAYOUT_SECTOR :: Layout{SLOT_SPACING, SLOTS_SIZE, false}
LAYOUT_COMPACT :: Layout{64, 128, false}

@(private)
SLOT_MAGIC :: 0x746f_6c73_6264_6e30
@(private)
SLOT_SEED :: 0x736c_6f74
@(private)
SLOT_MAGIC_BASED :: 0x6573_6273_6264_6e30
@(private)
SLOT_BYTES :: 48
@(private)
SLOT_BASED_BYTES :: 64
@(private)
SLOT_TRIMMED :: u64(1) << 63

Slot :: struct {
	seq:   u64,
	value: i64,
	start: i64,
	hash:  u64,
	base:  i64,
	end:   i64,
	trimmed: bool,
}

slot_end :: proc "contextless" (s: Slot) -> i64 {
	return s.end if s.end > 0 else s.value
}

slot_write :: proc(vfs: prim.Vfs, fd: prim.Fd, s: Slot, spacing: i64 = SLOT_SPACING) -> Error {
	if s.base == 0 && slot_end(s) == s.value && !s.trimmed {
		b: [SLOT_BYTES]u8
		prim.put_u64le(b[0:], SLOT_MAGIC)
		prim.put_u64le(b[8:], s.seq)
		prim.put_u64le(b[16:], u64(s.value))
		prim.put_u64le(b[24:], u64(s.start))
		prim.put_u64le(b[32:], s.hash)
		prim.put_u64le(b[40:], xxhash.XXH3_64_with_seed(b[:40], SLOT_SEED))
		return _from_prim(prim.write_at(vfs, fd, b[:], i64(s.seq & 1) * spacing))
	}
	b: [SLOT_BASED_BYTES]u8
	prim.put_u64le(b[0:], SLOT_MAGIC_BASED)
	prim.put_u64le(b[8:], s.seq)
	prim.put_u64le(b[16:], u64(s.value))
	prim.put_u64le(b[24:], u64(s.start))
	prim.put_u64le(b[32:], s.hash)
	prim.put_u64le(b[40:], u64(s.base) | (SLOT_TRIMMED if s.trimmed else 0))
	prim.put_u64le(b[48:], u64(slot_end(s)))
	prim.put_u64le(b[56:], xxhash.XXH3_64_with_seed(b[:56], SLOT_SEED))
	return _from_prim(prim.write_at(vfs, fd, b[:], i64(s.seq & 1) * spacing))
}

slots_read :: proc(vfs: prim.Vfs, fd: prim.Fd, spacing: i64 = SLOT_SPACING) -> (newest: Slot, older: Slot, count: int, err: Error) {
	b: [SLOTS_SIZE]u8
	n, rerr := prim.read_at(vfs, fd, b[:2 * spacing], 0)
	if rerr != .None {
		return {}, {}, 0, _from_prim(rerr)
	}
	found: [2]Slot
	ok: [2]bool
	for i in 0 ..< 2 {
		off := i * int(spacing)
		if off + SLOT_BYTES > n {
			continue
		}
		found[i], ok[i] = _slot_decode(b[off:min(n, off + SLOT_BASED_BYTES)])
		if ok[i] && int(found[i].seq & 1) != i {
			ok[i] = false
		}
	}
	switch {
	case ok[0] && ok[1]:
		if found[0].seq > found[1].seq {
			return found[0], found[1], 2, .None
		}
		return found[1], found[0], 2, .None
	case ok[0]:
		return found[0], {}, 1, .None
	case ok[1]:
		return found[1], {}, 1, .None
	}
	return {}, {}, 0, .None
}

@(private)
_slot_decode :: proc(b: []u8) -> (s: Slot, ok: bool) {
	magic := prim.get_u64le(b[0:])
	based := magic == SLOT_MAGIC_BASED
	if !based && magic != SLOT_MAGIC {
		return
	}
	if based && len(b) < SLOT_BASED_BYTES {
		return
	}
	check := 56 if based else 40
	if xxhash.XXH3_64_with_seed(b[:check], SLOT_SEED) != prim.get_u64le(b[check:]) {
		return
	}
	s.seq = prim.get_u64le(b[8:])
	v := prim.get_u64le(b[16:])
	st := prim.get_u64le(b[24:])
	base, end := u64(0), v
	if based {
		base = prim.get_u64le(b[40:])
		end = prim.get_u64le(b[48:])
		s.trimmed = base & SLOT_TRIMMED != 0
		base &~= SLOT_TRIMMED
	}
	if v > u64(max(i64)) || st > end || end > v || base > v || s.seq == 0 {
		return {}, false
	}
	s.value = i64(v)
	s.start = i64(st)
	s.hash = prim.get_u64le(b[32:])
	s.base = i64(base)
	s.end = i64(end)
	return s, true
}
