package textdiff

@(private)
MAX_CHAIN :: 64

@(private)
NO_LINE :: max(u32)

@(private)
Lcs_Outcome :: enum u8 {
	Found,
	Disjoint,
	Fallback,
}

@(private)
histogram :: proc(d: ^Differ, whole: Region) -> Error {
	stack := make([dynamic]Region, 0, 32, context.temp_allocator) or_return
	append(&stack, whole) or_return
	for len(stack) > 0 {
		r := pop(&stack)
		for {
			if r.a0 == r.a1 {
				mark(d.chgb, d.b0, r.b0, r.b1)
				break
			}
			if r.b0 == r.b1 {
				mark(d.chga, d.a0, r.a0, r.a1)
				break
			}
			lcs, outcome := find_lcs(d, r)
			if outcome == .Fallback {
				myers(d, r, .Region) or_return
				break
			}
			if outcome == .Disjoint {
				mark(d.chga, d.a0, r.a0, r.a1)
				mark(d.chgb, d.b0, r.b0, r.b1)
				break
			}
			if lcs.a0 > r.a0 || lcs.b0 > r.b0 {
				append(&stack, Region{r.a0, lcs.a0, r.b0, lcs.b0}) or_return
			}
			r = Region{lcs.a1, r.a1, lcs.b1, r.b1}
			if r.a0 == r.a1 && r.b0 == r.b1 {
				break
			}
		}
	}
	return nil
}

@(private)
find_lcs :: proc(d: ^Differ, r: Region) -> (lcs: Region, outcome: Lcs_Outcome) {
	ida, idb, cnt, head, nxt := d.ida, d.idb, d.cnt, d.aux, d.nxt
	for p := r.a1 - 1; p >= r.a0; p -= 1 {
		id := ida[p]
		k := cnt[id]
		nxt[p] = k == 0 ? NO_LINE : head[id]
		head[id] = u32(p)
		cnt[id] = k + 1
	}
	best := u32(MAX_CHAIN + 1)
	span := 0
	has_common, found := false, false
	bp := r.b0
	for bp < r.b1 {
		b_next := bp + 1
		id := idb[bp]
		k := cnt[id]
		if k == 0 {
			bp = b_next
			continue
		}
		has_common = true
		if k > best {
			bp = b_next
			continue
		}
		as := int(head[id])
		scan: for {
			np := nxt[as]
			bs, ae, be := bp, as, bp
			rc := k
			for r.a0 < as && r.b0 < bs && ida[as - 1] == idb[bs - 1] {
				as -= 1
				bs -= 1
				if rc > 1 {
					rc = min(rc, cnt[ida[as]])
				}
			}
			for ae + 1 < r.a1 && be + 1 < r.b1 && ida[ae + 1] == idb[be + 1] {
				ae += 1
				be += 1
				if rc > 1 {
					rc = min(rc, cnt[ida[ae]])
				}
			}
			if b_next <= be {
				b_next = be + 1
			}
			if span < ae - as || rc < best {
				lcs = Region{as, ae + 1, bs, be + 1}
				span = ae - as
				best = rc
				found = true
			}
			for np != NO_LINE && int(np) <= ae {
				np = nxt[np]
			}
			if np == NO_LINE {
				break scan
			}
			as = int(np)
		}
		bp = b_next
	}
	for p in r.a0 ..< r.a1 {
		cnt[ida[p]] = 0
	}
	if has_common && best > MAX_CHAIN {
		return {}, .Fallback
	}
	if !found {
		return {}, .Disjoint
	}
	return lcs, .Found
}
