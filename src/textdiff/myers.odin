package textdiff

import "base:runtime"
import "core:mem"

@(private)
MAX_COST_MIN :: 256
@(private)
HEUR_MIN_COST :: 256
@(private)
SNAKE_CNT :: 20
@(private)
K_HEUR :: 4
@(private)
MAX_EQLIMIT :: 1024
@(private)
SIMSCAN_WINDOW :: 100
@(private)
KPDIS_RUN :: 4
@(private)
KV_MAX :: max(i32)

@(private)
Discard :: enum u8 {
	None,
	Region,
	Whole,
}

@(private)
Box :: struct {
	off1, lim1, off2, lim2: int,
	need_min:               bool,
}

@(private)
Split :: struct {
	i1, i2:         int,
	min_lo, min_hi: bool,
}

@(private)
Myers :: struct {
	ha1, ha2:   []u32,
	kv:         []i32,
	fo, bo:     int,
	mxcost:     int,
}

@(private)
myers :: proc(d: ^Differ, r: Region, discard: Discard) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	a, b := d.ida[r.a0:r.a1], d.idb[r.b0:r.b1]
	n1, n2 := len(a), len(b)
	lim := min(n1, n2)
	s := 0
	for s < lim && a[s] == b[s] {
		s += 1
	}
	e := 0
	for e < lim - s && a[n1 - 1 - e] == b[n2 - 1 - e] {
		e += 1
	}
	dis1 := make([]u8, n1, context.temp_allocator) or_return
	dis2 := make([]u8, n2, context.temp_allocator) or_return
	switch discard {
	case .Region:
		count_and_classify(d, a, b, dis1[s:n1 - e], dis2[s:n2 - e], a[s:n1 - e], b[s:n2 - e])
	case .Whole:
		count_and_classify(d, d.ida, d.idb, dis1[s:n1 - e], dis2[s:n2 - e], a[s:n1 - e], b[s:n2 - e])
	case .None:
		mem.set(raw_data(dis1), 1, n1)
		mem.set(raw_data(dis2), 1, n2)
	}
	ha1 := make([]u32, n1 - s - e, context.temp_allocator) or_return
	ri1 := make([]u32, n1 - s - e, context.temp_allocator) or_return
	ha2 := make([]u32, n2 - s - e, context.temp_allocator) or_return
	ri2 := make([]u32, n2 - s - e, context.temp_allocator) or_return
	k1 := reduce(dis1, a, s, n1 - e, ha1, ri1, d.chga, d.a0 + r.a0)
	k2 := reduce(dis2, b, s, n2 - e, ha2, ri2, d.chgb, d.b0 + r.b0)
	ndiags := k1 + k2 + 3
	kvd := make([]i32, 2 * ndiags + 2, context.temp_allocator) or_return
	m := Myers {
		ha1    = ha1[:k1],
		ha2    = ha2[:k2],
		kv     = kvd,
		fo     = k2 + 1,
		bo     = ndiags + k2 + 1,
		mxcost = max(bogosqrt(ndiags), MAX_COST_MIN),
	}
	stack := make([dynamic]Box, 0, 32, context.temp_allocator) or_return
	append(&stack, Box{0, k1, 0, k2, false}) or_return
	for len(stack) > 0 {
		box := pop(&stack)
		off1, lim1, off2, lim2 := box.off1, box.lim1, box.off2, box.lim2
		for off1 < lim1 && off2 < lim2 && m.ha1[off1] == m.ha2[off2] {
			off1 += 1
			off2 += 1
		}
		for off1 < lim1 && off2 < lim2 && m.ha1[lim1 - 1] == m.ha2[lim2 - 1] {
			lim1 -= 1
			lim2 -= 1
		}
		if off1 == lim1 {
			for i in off2 ..< lim2 {
				d.chgb[d.b0 + r.b0 + int(ri2[i]) + 1] = 1
			}
		} else if off2 == lim2 {
			for i in off1 ..< lim1 {
				d.chga[d.a0 + r.a0 + int(ri1[i]) + 1] = 1
			}
		} else {
			spl := split(&m, off1, lim1, off2, lim2, box.need_min)
			append(&stack, Box{spl.i1, lim1, spl.i2, lim2, spl.min_hi}) or_return
			append(&stack, Box{off1, spl.i1, off2, spl.i2, spl.min_lo}) or_return
		}
	}
	return nil
}

@(private)
count_and_classify :: proc "contextless" (d: ^Differ, fa, fb: []u32, dis1, dis2: []u8, a, b: []u32) {
	for id in fa {
		d.aux[id] = 0
	}
	for id in fb {
		d.aux[id] = 0
	}
	for id in fa {
		d.cnt[id] += 1
	}
	for id in fb {
		d.aux[id] += 1
	}
	classify(dis1, a, d.aux, len(fa))
	classify(dis2, b, d.cnt, len(fb))
	for id in fa {
		d.cnt[id] = 0
	}
	for id in fb {
		d.aux[id] = 0
	}
}

@(private)
bogosqrt :: proc "contextless" (n: int) -> int {
	i := 1
	for v := n; v > 0; v >>= 2 {
		i <<= 1
	}
	return i
}

@(private)
classify :: proc "contextless" (dis: []u8, ids: []u32, other: []u32, nrec: int) {
	mlim := u32(min(bogosqrt(nrec), MAX_EQLIMIT))
	for id, i in ids {
		nm := other[id]
		if nm == 0 {
			dis[i] = 0
		} else if nm >= mlim {
			dis[i] = 2
		} else {
			dis[i] = 1
		}
	}
}

@(private)
reduce :: proc "contextless" (dis: []u8, ids: []u32, s, e: int, ha, ri: []u32, chg: []u8, base: int) -> int {
	k := 0
	for i in s ..< e {
		if dis[i] == 1 || (dis[i] == 2 && !clean_mmatch(dis, i, s, e - 1)) {
			ha[k] = ids[i]
			ri[k] = u32(i)
			k += 1
		} else {
			chg[base + i + 1] = 1
		}
	}
	return k
}

@(private)
clean_mmatch :: proc "contextless" (dis: []u8, i, start, end: int) -> bool {
	s, e := start, end
	if i - s > SIMSCAN_WINDOW {
		s = i - SIMSCAN_WINDOW
	}
	if e - i > SIMSCAN_WINDOW {
		e = i + SIMSCAN_WINDOW
	}
	rdis0, rpdis0 := 0, 1
	for r := 1; i - r >= s; r += 1 {
		v := dis[i - r]
		if v == 0 {
			rdis0 += 1
		} else if v == 2 {
			rpdis0 += 1
		} else {
			break
		}
	}
	if rdis0 == 0 {
		return false
	}
	rdis1, rpdis1 := 0, 1
	for r := 1; i + r <= e; r += 1 {
		v := dis[i + r]
		if v == 0 {
			rdis1 += 1
		} else if v == 2 {
			rpdis1 += 1
		} else {
			break
		}
	}
	if rdis1 == 0 {
		return false
	}
	rdis1 += rdis0
	rpdis1 += rpdis0
	return rpdis1 * KPDIS_RUN < rpdis1 + rdis1
}

@(private)
split :: proc "contextless" (m: ^Myers, off1, lim1, off2, lim2: int, need_min: bool) -> (spl: Split) {
	ha1, ha2, kv, fo, bo := m.ha1, m.ha2, m.kv, m.fo, m.bo
	dmin, dmax := off1 - lim2, lim1 - off2
	fmid, bmid := off1 - off2, lim1 - lim2
	odd := (fmid - bmid) & 1 != 0
	fmin, fmax := fmid, fmid
	bmin, bmax := bmid, bmid
	kv[fo + fmid] = i32(off1)
	kv[bo + bmid] = i32(lim1)
	for ec := 1;; ec += 1 {
		got_snake := false
		if fmin > dmin {
			fmin -= 1
			kv[fo + fmin - 1] = -1
		} else {
			fmin += 1
		}
		if fmax < dmax {
			fmax += 1
			kv[fo + fmax + 1] = -1
		} else {
			fmax -= 1
		}
		for d := fmax; d >= fmin; d -= 2 {
			i1 := kv[fo + d - 1] >= kv[fo + d + 1] ? int(kv[fo + d - 1]) + 1 : int(kv[fo + d + 1])
			prev1 := i1
			i2 := i1 - d
			for i1 < lim1 && i2 < lim2 && ha1[i1] == ha2[i2] {
				i1 += 1
				i2 += 1
			}
			if i1 - prev1 > SNAKE_CNT {
				got_snake = true
			}
			kv[fo + d] = i32(i1)
			if odd && bmin <= d && d <= bmax && int(kv[bo + d]) <= i1 {
				return Split{i1, i2, true, true}
			}
		}
		if bmin > dmin {
			bmin -= 1
			kv[bo + bmin - 1] = KV_MAX
		} else {
			bmin += 1
		}
		if bmax < dmax {
			bmax += 1
			kv[bo + bmax + 1] = KV_MAX
		} else {
			bmax -= 1
		}
		for d := bmax; d >= bmin; d -= 2 {
			i1 := kv[bo + d - 1] < kv[bo + d + 1] ? int(kv[bo + d - 1]) : int(kv[bo + d + 1]) - 1
			prev1 := i1
			i2 := i1 - d
			for i1 > off1 && i2 > off2 && ha1[i1 - 1] == ha2[i2 - 1] {
				i1 -= 1
				i2 -= 1
			}
			if prev1 - i1 > SNAKE_CNT {
				got_snake = true
			}
			kv[bo + d] = i32(i1)
			if !odd && fmin <= d && d <= fmax && i1 <= int(kv[fo + d]) {
				return Split{i1, i2, true, true}
			}
		}
		if need_min {
			continue
		}
		if got_snake && ec > HEUR_MIN_COST {
			best := 0
			for d := fmax; d >= fmin; d -= 2 {
				dd := d > fmid ? d - fmid : fmid - d
				i1 := int(kv[fo + d])
				i2 := i1 - d
				v := (i1 - off1) + (i2 - off2) - dd
				if v > K_HEUR * ec && v > best && off1 + SNAKE_CNT <= i1 && i1 < lim1 && off2 + SNAKE_CNT <= i2 && i2 < lim2 {
					for k := 1; ha1[i1 - k] == ha2[i2 - k]; k += 1 {
						if k == SNAKE_CNT {
							best = v
							spl.i1, spl.i2 = i1, i2
							break
						}
					}
				}
			}
			if best > 0 {
				spl.min_lo, spl.min_hi = true, false
				return
			}
			for d := bmax; d >= bmin; d -= 2 {
				dd := d > bmid ? d - bmid : bmid - d
				i1 := int(kv[bo + d])
				i2 := i1 - d
				v := (lim1 - i1) + (lim2 - i2) - dd
				if v > K_HEUR * ec && v > best && off1 < i1 && i1 <= lim1 - SNAKE_CNT && off2 < i2 && i2 <= lim2 - SNAKE_CNT {
					for k := 0; ha1[i1 + k] == ha2[i2 + k]; k += 1 {
						if k == SNAKE_CNT - 1 {
							best = v
							spl.i1, spl.i2 = i1, i2
							break
						}
					}
				}
			}
			if best > 0 {
				spl.min_lo, spl.min_hi = false, true
				return
			}
		}
		if ec >= m.mxcost {
			fbest, fbest1 := -1, -1
			for d := fmax; d >= fmin; d -= 2 {
				i1 := min(int(kv[fo + d]), lim1)
				i2 := i1 - d
				if lim2 < i2 {
					i1 = lim2 + d
					i2 = lim2
				}
				if fbest < i1 + i2 {
					fbest = i1 + i2
					fbest1 = i1
				}
			}
			bbest, bbest1 := max(int), max(int)
			for d := bmax; d >= bmin; d -= 2 {
				i1 := max(off1, int(kv[bo + d]))
				i2 := i1 - d
				if i2 < off2 {
					i1 = off2 + d
					i2 = off2
				}
				if i1 + i2 < bbest {
					bbest = i1 + i2
					bbest1 = i1
				}
			}
			if (lim1 + lim2) - bbest < fbest - (off1 + off2) {
				return Split{fbest1, fbest - fbest1, true, false}
			}
			return Split{bbest1, bbest - bbest1, false, true}
		}
	}
}
