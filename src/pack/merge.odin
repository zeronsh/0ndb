package pack

import "../prim"

@(private)
Merge_Iter :: struct {
	p:         ^Pack,
	hi:        [dynamic]u8,
	has_hi:    bool,
	mem_order: []u32,
	mi:        int,
	imm:       ^Mem,
	imm_order: []u32,
	ii:        int,
	with_mem:  bool,
	iters:     [dynamic]Run_Iter,
	keep_tomb: bool,
	key:       [MAX_KEY]u8,
	klen:      int,
	val:       [dynamic]u8,
	tomb:      bool,
	err:       Error,
}

@(private)
_miter_init :: proc(it: ^Merge_Iter, p: ^Pack, lo: []u8, hi: []u8, with_mem := true, run_lo := 0, run_hi := -1, keep_tomb := false) -> Error {
	it^ = {
		p         = p,
		with_mem  = with_mem,
		keep_tomb = keep_tomb,
	}
	it.hi = make([dynamic]u8, p.allocator)
	it.val = make([dynamic]u8, p.allocator)
	it.iters = make([dynamic]Run_Iter, p.allocator)
	if hi != nil {
		append(&it.hi, ..hi)
		it.has_hi = true
	}
	if with_mem {
		it.mem_order = _mem_sorted(&p.mem, lo, hi, p.allocator)
		if p.fl.imm != nil {
			it.imm = p.fl.imm
			it.imm_order = _mem_sorted(it.imm, lo, hi, p.allocator)
		}
	}
	rh := len(p.runs) if run_hi < 0 else run_hi
	for i := rh - 1; i >= run_lo; i -= 1 {
		ri: Run_Iter
		if e := _run_iter_init(&ri, p, p.runs[i], lo); e != .None {
			_run_iter_destroy(&ri)
			return e
		}
		append(&it.iters, ri)
	}
	return .None
}

@(private)
_miter_destroy :: proc(it: ^Merge_Iter) {
	for &ri in it.iters {
		_run_iter_destroy(&ri)
	}
	delete(it.iters)
	delete(it.hi)
	delete(it.val)
	if it.mem_order != nil {
		delete(it.mem_order, it.p.allocator)
	}
	if it.imm_order != nil {
		delete(it.imm_order, it.p.allocator)
	}
	it.mem_order = nil
	it.imm_order = nil
}

@(private)
_miter_raw :: proc(it: ^Merge_Iter) -> (key: []u8, ok: bool) {
	best: []u8
	have := false
	if it.with_mem && it.mi < len(it.mem_order) {
		best = _mem_rec(&it.p.mem, it.mem_order[it.mi]).key
		have = true
	}
	if it.imm != nil && it.ii < len(it.imm_order) {
		k := _mem_rec(it.imm, it.imm_order[it.ii]).key
		if !have || _key_cmp(k, best) < 0 {
			best = k
			have = true
		}
	}
	for &ri in it.iters {
		k, _, _, rok := _run_iter_peek(&ri)
		if ri.err != .None {
			it.err = ri.err
			return nil, false
		}
		if rok && (!have || _key_cmp(k, best) < 0) {
			best = k
			have = true
		}
	}
	if !have {
		return nil, false
	}
	copy(it.key[:], best)
	it.klen = len(best)
	key = it.key[:it.klen]
	taken := false
	if it.with_mem && it.mi < len(it.mem_order) {
		r := _mem_rec(&it.p.mem, it.mem_order[it.mi])
		if _key_cmp(r.key, key) == 0 {
			clear(&it.val)
			append(&it.val, ..r.val)
			it.tomb = r.flags & MEM_TOMB != 0
			taken = true
			it.mi += 1
		}
	}
	if it.imm != nil && it.ii < len(it.imm_order) {
		r := _mem_rec(it.imm, it.imm_order[it.ii])
		if _key_cmp(r.key, key) == 0 {
			if !taken {
				clear(&it.val)
				append(&it.val, ..r.val)
				it.tomb = r.flags & MEM_TOMB != 0
				taken = true
			}
			it.ii += 1
		}
	}
	for &ri in it.iters {
		k, v, t, rok := _run_iter_peek(&ri)
		if rok && _key_cmp(k, key) == 0 {
			if !taken {
				clear(&it.val)
				append(&it.val, ..v)
				it.tomb = t
				taken = true
			}
			_run_iter_advance(&ri)
		}
	}
	return key, true
}

@(private)
_miter_next :: proc(it: ^Merge_Iter) -> (key: []u8, val: []u8, ok: bool) {
	for {
		k, rok := _miter_raw(it)
		if !rok {
			return nil, nil, false
		}
		if it.has_hi && _key_cmp(k, it.hi[:]) >= 0 {
			return nil, nil, false
		}
		if it.tomb && !it.keep_tomb {
			continue
		}
		return k, it.val[:], true
	}
}

@(private)
Merge :: struct {
	first_id: u32,
	count:    int,
	level:    u8,
	drop:     bool,
	it:       Merge_Iter,
	bd:       Builder,
	fd:       prim.Fd,
	out_id:   u32,
	out:      Run,
}

@(private)
_merge_pick :: proc(p: ^Pack) -> (lo: int, hi: int, ok: bool) {
	n := len(p.runs)
	if n < 2 {
		return
	}
	i := n
	for i > 0 {
		lvl := p.runs[i - 1].level
		j := i - 1
		for j > 0 && p.runs[j - 1].level == lvl {
			j -= 1
		}
		if i - j >= p.opts.merge_fanout {
			return i - p.opts.merge_fanout, i, true
		}
		i = j
	}
	if n > p.opts.max_runs {
		return n - p.opts.merge_fanout, n, true
	}
	return
}

@(private)
_merge_pick_idle :: proc(p: ^Pack) -> (lo: int, hi: int, ok: bool) {
	n := len(p.runs)
	if n <= 1 {
		return
	}
	newer := make([]u64, n + 1, context.temp_allocator)
	for i := n - 1; i >= 0; i -= 1 {
		newer[i] = newer[i + 1] + u64(p.runs[i].nblocks)
	}
	for i in 0 ..< n - 1 {
		if u64(p.runs[i].nblocks) <= 4 * newer[i + 1] {
			return i, n, true
		}
	}
	return
}

@(private)
_merge_start :: proc(p: ^Pack, lo, hi: int) -> Error {
	m := new(Merge, p.allocator)
	if m == nil {
		return .No_Memory
	}
	m.first_id = p.runs[lo].id
	m.count = hi - lo
	lvl: u8
	for r in p.runs[lo:hi] {
		lvl = max(lvl, r.level)
	}
	m.level = lvl + 1
	m.drop = lo == 0
	m.out_id = p.next_run
	p.next_run += 1
	pb: prim.Path_Buf
	fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'r', u64(m.out_id)), {.Write, .Create, .Truncate}, 0o600)
	if err != .None {
		free(m, p.allocator)
		return err
	}
	m.fd = fd
	if e := _builder_init(&m.bd, p.base, fd); e != .None {
		prim.close_file(p.base, fd)
		free(m, p.allocator)
		return e
	}
	p.merge = m
	if e := _miter_init(&m.it, p, nil, nil, false, lo, hi, !m.drop); e != .None {
		_merge_abort(p)
		return e
	}
	return .None
}

@(private)
_merge_abort :: proc(p: ^Pack) {
	m := p.merge
	if m == nil {
		return
	}
	_miter_destroy(&m.it)
	_builder_destroy(&m.bd)
	prim.close_file(p.base, m.fd)
	pb: prim.Path_Buf
	prim.remove(p.base, _phys_path(p, &pb, 'r', u64(m.out_id)))
	free(m, p.allocator)
	p.merge = nil
}

@(private)
_merge_inputs :: proc(p: ^Pack, m: ^Merge) -> int {
	for r, i in p.runs {
		if r.id == m.first_id {
			return i
		}
	}
	return -1
}

@(private)
_merge_work :: proc(p: ^Pack, budget: i64) -> (done: bool, err: Error) {
	m := p.merge
	start := m.bd.out_base + i64(m.bd.out_len)
	for {
		if m.bd.out_base + i64(m.bd.out_len) - start >= budget {
			return false, .None
		}
		key, val, ok := _miter_next(&m.it)
		if m.it.err != .None {
			e := m.it.err
			_merge_abort(p)
			return false, e
		}
		if !ok {
			break
		}
		_builder_add(&m.bd, key, val, m.it.tomb)
		p.stats.merge_bytes += u64(len(key) + len(val))
		if m.bd.err != .None {
			e := m.bd.err
			_merge_abort(p)
			return false, e
		}
	}
	_merge_finish(p) or_return
	return true, .None
}

@(private)
_merge_finish :: proc(p: ^Pack) -> Error {
	m := p.merge
	if m.bd.nentries == 0 {
		_builder_add(&m.bd, []u8{0}, nil, true)
	}
	run, err := _builder_finish(&m.bd, m.level)
	lo := _merge_inputs(p, m)
	if err == .None && lo < 0 {
		err = .Io
	}
	if err != .None {
		_merge_abort(p)
		return err
	}
	_miter_destroy(&m.it)
	_builder_destroy(&m.bd)
	run.id = m.out_id
	run.fd = m.fd
	m.out = run
	p.merge = nil
	_drain(p) or_return
	fl := &p.fl
	p.gen += 1
	_snap_take(p, &fl.snap)
	remove_range(&fl.snap.runs, lo, lo + m.count)
	inject_at(&fl.snap.runs, lo, run)
	fl.has_snap = true
	fl.super_fd = p.super_fd
	fl.root = p.root
	fl.merge = m
	fl.kind = .Merge
	_submit(p) or_return
	if !_async(p) {
		return _drain(p)
	}
	return .None
}

@(private)
_merge_installed :: proc(p: ^Pack, m: ^Merge) -> Error {
	lo := _merge_inputs(p, m)
	if lo < 0 {
		prim.close_file(p.base, m.fd)
		free(m, p.allocator)
		return _poison(p, .Io)
	}
	nr := new(Run, p.allocator)
	nr^ = m.out
	nr.root_buf = nil
	if e := _run_load(p, nr); e != .None {
		_run_close(p, nr)
		free(nr, p.allocator)
		free(m, p.allocator)
		return _poison(p, e)
	}
	old := make([dynamic]^Run, context.temp_allocator)
	for i in 0 ..< m.count {
		append(&old, p.runs[lo + i])
	}
	remove_range(&p.runs, lo, lo + m.count)
	inject_at(&p.runs, lo, nr)
	free(m, p.allocator)
	for r in old {
		pb: prim.Path_Buf
		id := r.id
		_run_close(p, r)
		free(r, p.allocator)
		prim.remove(p.base, _phys_path(p, &pb, 'r', u64(id)))
	}
	p.stats.merges += 1
	return .None
}

@(private)
_merge_step :: proc(p: ^Pack, budget: i64, idle := false) -> (more: bool, err: Error) {
	if p.fl.on && p.fl.kind == .Merge {
		return true, .None
	}
	if p.merge == nil {
		lo, hi, ok := _merge_pick(p)
		if !ok && idle {
			lo, hi, ok = _merge_pick_idle(p)
		}
		if !ok {
			return false, .None
		}
		_merge_start(p, lo, hi) or_return
	}
	done := _merge_work(p, budget) or_return
	if done {
		_, _, again := _merge_pick(p)
		if !again && idle {
			_, _, again = _merge_pick_idle(p)
		}
		return again, .None
	}
	return true, .None
}
