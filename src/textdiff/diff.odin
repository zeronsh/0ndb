package textdiff

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:hash/xxhash"
import "core:simd"

Edit :: struct {
	a_start: u32,
	a_len:   u32,
	b_start: u32,
	b_len:   u32,
}

Stats :: struct {
	added:   int,
	removed: int,
}

Algorithm :: enum u8 {
	Histogram,
	Myers,
}

Diff_Options :: struct {
	algorithm:        Algorithm,
	indent_heuristic: bool,
}

DEFAULT_DIFF :: Diff_Options {
	indent_heuristic = true,
}

@(private)
Differ :: struct {
	a, b:       Lines,
	a0, b0:     int,
	ida, idb:   []u32,
	chga, chgb: []u8,
	cnt, aux:   []u32,
	nxt:        []u32,
}

@(private)
Region :: struct {
	a0, a1, b0, b1: int,
}

diff :: proc(a, b: []u8, opts := DEFAULT_DIFF, allocator := context.allocator) -> (edits: []Edit, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	la := split_lines(a, context.temp_allocator) or_return
	lb := split_lines(b, context.temp_allocator) or_return
	return diff_lines(la, lb, opts, allocator)
}

diff_lines :: proc(a, b: Lines, opts := DEFAULT_DIFF, allocator := context.allocator) -> (edits: []Edit, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	d: Differ
	run_diff(&d, a, b, opts) or_return
	return collect_edits(&d, allocator)
}

stats :: proc "contextless" (edits: []Edit) -> (s: Stats) {
	for e in edits {
		s.added += int(e.b_len)
		s.removed += int(e.a_len)
	}
	return
}

@(private)
run_diff :: proc(d: ^Differ, a, b: Lines, opts: Diff_Options) -> Error {
	d.a, d.b = a, b
	d.chga = make([]u8, line_count(a) + 2, context.temp_allocator) or_return
	d.chgb = make([]u8, line_count(b) + 2, context.temp_allocator) or_return
	p := common_prefix(a.data, b.data)
	if p == len(a.data) && p == len(b.data) {
		d.a0, d.b0 = line_count(a), line_count(b)
		return nil
	}
	pl := bytes.last_index_byte(a.data[:p], '\n') + 1
	s := common_suffix(a.data[pl:], b.data[pl:])
	sa, sb := len(a.data) - s, len(b.data) - s
	if !at_line_start(a.data, sa, pl) || !at_line_start(b.data, sb, pl) {
		k := bytes.index_byte(a.data[sa:], '\n')
		if k < 0 {
			sa, sb = len(a.data), len(b.data)
		} else {
			sa += k + 1
			sb += k + 1
		}
	}
	a0, a1 := line_at(a.offs, pl), line_at(a.offs, sa)
	b0, b1 := line_at(b.offs, pl), line_at(b.offs, sb)
	d.a0, d.b0 = a0, b0
	if a0 == a1 || b0 == b1 {
		for i in a0 ..< a1 {
			d.chga[i + 1] = 1
		}
		for i in b0 ..< b1 {
			d.chgb[i + 1] = 1
		}
	} else {
		ia0, ia1, ib0, ib1 := a0, a1, b0, b1
		if opts.algorithm == .Myers {
			ia0, ia1, ib0, ib1 = 0, line_count(a), 0, line_count(b)
		}
		d.a0, d.b0 = ia0, ib0
		d.ida = make([]u32, ia1 - ia0, context.temp_allocator) or_return
		d.idb = make([]u32, ib1 - ib0, context.temp_allocator) or_return
		nids := intern(a, ia0, b, ib0, d.ida, d.idb) or_return
		d.cnt = make([]u32, nids, context.temp_allocator) or_return
		d.aux = make([]u32, nids, context.temp_allocator) or_return
		middle := Region{a0 - ia0, a1 - ia0, b0 - ib0, b1 - ib0}
		switch opts.algorithm {
		case .Histogram:
			d.nxt = make([]u32, len(d.ida), context.temp_allocator) or_return
			histogram(d, middle) or_return
		case .Myers:
			myers(d, middle, .Whole) or_return
		}
	}
	compact(d, false, opts.indent_heuristic)
	compact(d, true, opts.indent_heuristic)
	return nil
}

@(private)
collect_edits :: proc(d: ^Differ, allocator: runtime.Allocator) -> (edits: []Edit, err: Error) {
	n := walk_edits(d, nil)
	edits = make([]Edit, n, allocator) or_return
	walk_edits(d, edits)
	return edits, nil
}

@(private)
walk_edits :: proc "contextless" (d: ^Differ, out: []Edit) -> int {
	ca, cb := d.chga[1:], d.chgb[1:]
	ea, eb := last_changed(d.chga), last_changed(d.chgb)
	i := min(first_changed(d.chga), first_changed(d.chgb))
	j, n := i, 0
	for i < ea || j < eb {
		if ca[i] == 0 && cb[j] == 0 {
			i += 1
			j += 1
			continue
		}
		si, sj := i, j
		for ca[i] != 0 {
			i += 1
		}
		for cb[j] != 0 {
			j += 1
		}
		if out != nil {
			out[n] = Edit{u32(si), u32(i - si), u32(sj), u32(j - sj)}
		}
		n += 1
	}
	return n
}

@(private)
first_changed :: proc "contextless" (chg: []u8) -> int {
	body := chg[1:len(chg) - 1]
	p := raw_data(body)
	zero: simd.u8x32
	i := 0
	for ; i + 32 <= len(body); i += 32 {
		v := intrinsics.unaligned_load((^simd.u8x32)(p[i:]))
		m := transmute(u32)simd.extract_msbs(simd.lanes_ne(v, zero))
		if m != 0 {
			return i + int(intrinsics.count_trailing_zeros(m))
		}
	}
	for i < len(body) && body[i] == 0 {
		i += 1
	}
	return i
}

@(private)
last_changed :: proc "contextless" (chg: []u8) -> int {
	for i := len(chg) - 2; i > 0; i -= 1 {
		if chg[i] != 0 {
			return i
		}
	}
	return 0
}

@(private)
mark :: #force_inline proc "contextless" (chg: []u8, base, from, to: int) {
	for i in from ..< to {
		chg[base + i + 1] = 1
	}
}

@(private)
at_line_start :: #force_inline proc "contextless" (data: []u8, pos, floor: int) -> bool {
	return pos == floor || data[pos - 1] == '\n'
}

@(private)
line_at :: proc "contextless" (offs: []u32, pos: int) -> int {
	lo, hi := 0, len(offs) - 1
	target := u32(pos)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if offs[mid] < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
diff_mask :: #force_inline proc "contextless" (a, b: [^]u8) -> u32 {
	x := intrinsics.unaligned_load((^simd.u8x32)(a))
	y := intrinsics.unaligned_load((^simd.u8x32)(b))
	return transmute(u32)simd.extract_msbs(simd.lanes_ne(x, y))
}

@(private)
common_prefix :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	pa, pb := raw_data(a), raw_data(b)
	i := 0
	for ; i + 32 <= n; i += 32 {
		m := diff_mask(pa[i:], pb[i:])
		if m != 0 {
			return i + int(intrinsics.count_trailing_zeros(m))
		}
	}
	for i < n && a[i] == b[i] {
		i += 1
	}
	return i
}

single_edit :: proc "contextless" (old, new: []u8) -> (at: int, del: int, ins: int, ok: bool) {
	p := common_prefix(old, new)
	s := common_suffix(old[p:], new[p:])
	if p + s != len(old) && p + s != len(new) {
		return 0, 0, 0, false
	}
	for p > 0 && (continuation(old, p) || continuation(new, p)) {
		p -= 1
	}
	s = common_suffix(old[p:], new[p:])
	for s > 0 && (continuation(old, len(old) - s) || continuation(new, len(new) - s)) {
		s -= 1
	}
	return p, len(old) - p - s, len(new) - p - s, true
}

@(private)
common_suffix :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	pa, pb := raw_data(a)[len(a) - n:], raw_data(b)[len(b) - n:]
	i := 0
	for ; i + 32 <= n; i += 32 {
		m := diff_mask(pa[n - i - 32:], pb[n - i - 32:])
		if m != 0 {
			return i + int(intrinsics.count_leading_zeros(m))
		}
	}
	for i < n && pa[n - i - 1] == pb[n - i - 1] {
		i += 1
	}
	return i
}

@(private)
Interner :: struct {
	slots:  []u32,
	hashes: []u64,
	reps:   []u32,
	a, b:   Lines,
	a0, b0: int,
	na:     u32,
	n:      u32,
}

@(private)
intern :: proc(a: Lines, a0: int, b: Lines, b0: int, ida, idb: []u32) -> (nids: int, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	total := len(ida) + len(idb)
	size := 64
	for size < total + total / 2 {
		size <<= 1
	}
	t := Interner {
		a  = a,
		b  = b,
		a0 = a0,
		b0 = b0,
		na = u32(len(ida)),
	}
	t.slots = make([]u32, size, context.temp_allocator) or_return
	t.hashes = make([]u64, total, context.temp_allocator) or_return
	t.reps = make([]u32, total, context.temp_allocator) or_return
	for &id, i in ida {
		id = intern_line(&t, line(a, a0 + i), u32(i))
	}
	for &id, i in idb {
		id = intern_line(&t, line(b, b0 + i), t.na + u32(i))
	}
	return int(t.n), nil
}

@(private)
rep_line :: #force_inline proc "contextless" (t: ^Interner, rep: u32) -> []u8 {
	if rep < t.na {
		return line(t.a, t.a0 + int(rep))
	}
	return line(t.b, t.b0 + int(rep - t.na))
}

@(private)
intern_line :: #force_inline proc(t: ^Interner, s: []u8, rep: u32) -> u32 {
	h := xxhash.XXH3_64_default(s)
	mask := u64(len(t.slots) - 1)
	i := h & mask
	for {
		slot := t.slots[i]
		if slot == 0 {
			id := t.n
			t.n += 1
			t.hashes[id] = h
			t.reps[id] = rep
			t.slots[i] = id + 1
			return id
		}
		id := slot - 1
		if t.hashes[id] == h && equal_bytes(rep_line(t, t.reps[id]), s) {
			return id
		}
		i = (i + 1) & mask
	}
}
