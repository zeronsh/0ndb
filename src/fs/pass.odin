package fs

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../prim"

when ODIN_OS == .Windows {
	SLICE_COST_STAT :: 15
	SLICE_COST_OPEN :: 25
	SLICE_COST_MIB :: 65000
	SLICE_COST_DIR :: 50
	SLICE_COST_ENTRY :: 1
	SLICE_COST_CHANGE :: 50
	SLICE_COST_COMMIT :: 15000
} else when ODIN_OS == .Darwin {
	SLICE_COST_STAT :: 2
	SLICE_COST_OPEN :: 10
	SLICE_COST_MIB :: 65000
	SLICE_COST_DIR :: 10
	SLICE_COST_ENTRY :: 1
	SLICE_COST_CHANGE :: 30
	SLICE_COST_COMMIT :: 500
} else {
	SLICE_COST_STAT :: 1
	SLICE_COST_OPEN :: 10
	SLICE_COST_MIB :: 90000
	SLICE_COST_DIR :: 10
	SLICE_COST_ENTRY :: 1
	SLICE_COST_CHANGE :: 20
	SLICE_COST_COMMIT :: 150
}

SLICE_COST_EST :: SLICE_COST_CHANGE + SLICE_COST_OPEN + SLICE_COST_STAT + SLICE_COST_MIB / 256

SLICE_BUDGET :: 5000
SLICE_COMMIT :: 64

Slice_Hook :: proc(m: ^Mount, data: rawptr)

@(private)
Pass_Stage :: enum u8 {
	Keys,
	Deep,
	Walk,
	Final,
	Done,
}

@(private)
Walk_Frame :: struct {
	rel:     string,
	wd:      i32,
	kids:    [dynamic]Shadow_Child,
	names:   map[string]Listed,
	pending: []string,
	ki:      int,
	pi:      int,
	listed:  bool,
	gone:    bool,
}

@(private)
Commit_Unit :: struct {
	actor:  prim.Id,
	idx:    []int,
	marker: []u8,
}

Pass_Run :: struct {
	p:          Pass,
	long:       virtual.Arena,
	keys:       [dynamic]string,
	ki:         int,
	deep:       [dynamic]string,
	di:         int,
	frames:     [dynamic]Walk_Frame,
	stage:      Pass_Stage,
	settle:     bool,
	rescan_was: bool,
	flushing:   bool,
	final:      bool,
	units:      [dynamic]Commit_Unit,
	ui:         int,
	uo:         int,
}

registry_set_slice :: proc(reg: ^Registry, budget: i64, commit: int = 0, hook: Slice_Hook = nil, data: rawptr = nil) {
	reg.slice_budget = budget
	reg.slice_commit = commit
	reg.slice_hook = hook
	reg.slice_data = data
}

mount_pass_running :: proc "contextless" (m: ^Mount) -> bool {
	return m.pass != nil
}

slice_charge :: proc "contextless" (m: ^Mount, units: i64) {
	m.slice_spent += units
}

@(private)
_slice_budget :: proc(m: ^Mount) -> i64 {
	if m.reg != nil && m.reg.slice_budget > 0 {
		return m.reg.slice_budget
	}
	return SLICE_BUDGET
}

@(private)
_slice_over :: proc(pr: ^Pass_Run) -> bool {
	return pr.p.budget > 0 && pr.p.m.slice_spent >= pr.p.budget
}

@(private)
pass_begin :: proc(m: ^Mount, full: bool, settle: bool, budget: i64) -> (pr: ^Pass_Run, err: Error) {
	pr = new(Pass_Run, runtime.heap_allocator())
	if pr == nil {
		return nil, .No_Memory
	}
	if virtual.arena_init_growing(&pr.long, 256 << 10) != nil {
		free(pr, runtime.heap_allocator())
		return nil, .No_Memory
	}
	if virtual.arena_init_growing(&pr.p.chunk, 1 << 20) != nil {
		virtual.arena_destroy(&pr.long)
		free(pr, runtime.heap_allocator())
		return nil, .No_Memory
	}
	p := &pr.p
	p.m = m
	p.long = virtual.arena_allocator(&pr.long)
	p.budget = budget
	p.defer_flush = budget > 0
	pr.settle = settle
	context.temp_allocator = virtual.arena_allocator(&p.chunk)
	attr_begin(m)
	defer attr_end(m)
	if err = _pass_prologue(pr, full, settle); err != .None {
		_pass_free(pr)
		return nil, err
	}
	return pr, .None
}

@(private)
_pass_prologue :: proc(pr: ^Pass_Run, full: bool, settle: bool) -> Error {
	p := &pr.p
	m := p.m
	mount_wake(m) or_return
	catch_up(m) or_return
	if m.has_git {
		p.head, _ = git_head(m.vfs, m.git, p.long)
		p.head_moved = !git_head_equal(p.head, m.head)
		stamp := git_index_stamp(m.vfs, m.git)
		commits_only, _, rewritten := git_reflog_commits_only(m.vfs, m.git, m.reflog_pos)
		p.operation = git_operation(m.vfs, m.git)
		p.git_wrote = (p.head_moved && (!commits_only || rewritten)) || (p.operation != "" && stamp != m.stamp)
	}
	if p.git_wrote {
		collect_alias_sources(m, p)
	}
	p.changes = make([dynamic]Change, p.long)
	p.held = make([dynamic]Change, p.long)
	p.held_r = make(map[string]bool, p.long)
	p.held_c = make(map[string]bool, p.long)
	p.seen = make(map[string]bool, p.long)
	p.young = make([dynamic]string, p.long)
	p.holding = make([dynamic]string, p.long)
	p.rebased = make([dynamic]crdt.Op_Id, p.long)
	p.scope_of = make(map[string]^Scope, p.long)
	p.settle = settle && !p.git_wrote
	p.now = history_wall_ns(m.history)
	p.cutoff = p.now - m.opts.settle_ms * 1_000_000
	p.full = full || m.rescan || p.git_wrote
	m.hold_line = p.git_wrote
	pr.keys = make([dynamic]string, 0, len(m.dirty), p.long)
	pr.deep = make([dynamic]string, p.long)
	pr.frames = make([dynamic]Walk_Frame, runtime.heap_allocator())
	pr.units = make([dynamic]Commit_Unit, p.long)
	for k, v in m.dirty {
		c, _ := clone_string(k, p.long)
		p.scope_of[c] = v
		append(&pr.keys, c)
	}
	for k in m.dirty {
		delete(k, m.allocator)
	}
	clear(&m.dirty)
	pr.rescan_was = m.rescan
	m.rescan = false
	m.git_moved = false
	for k in m.redeep {
		if !p.full {
			append(&pr.deep, clone_string(k, p.long) or_else "")
		}
		delete(k, m.allocator)
	}
	clear(&m.redeep)
	if p.full {
		pr.stage = .Walk
		append(&pr.frames, Walk_Frame{rel = clone_string("", runtime.heap_allocator()) or_else "", wd = m.root_wd})
		return .None
	}
	slice.sort_by(pr.keys[:], proc(a, b: string) -> bool {return git_path_cmp(a, false, b, false) < 0})
	pre_moves(p, pr.keys[:]) or_return
	if !settle {
		for u in m.unwatched {
			append(&pr.deep, clone_string(u, p.long) or_else "")
		}
	}
	pr.stage = .Keys
	return .None
}

@(private)
_pass_free :: proc(pr: ^Pass_Run) {
	m := pr.p.m
	for &f in pr.frames {
		_frame_free(&f)
	}
	delete(pr.frames)
	delete(m.alias)
	m.alias = nil
	m.hold_line = false
	virtual.arena_destroy(&pr.p.chunk)
	virtual.arena_destroy(&pr.long)
	free(pr, runtime.heap_allocator())
}

@(private)
_pass_fail :: proc(pr: ^Pass_Run) {
	p := &pr.p
	m := p.m
	for k, v in p.scope_of {
		if k not_in m.dirty {
			c, _ := clone_string(k, m.allocator)
			m.dirty[c] = v
		}
	}
	m.rescan ||= pr.rescan_was || p.full
}

@(private)
pass_drive :: proc(m: ^Mount, pr: ^Pass_Run) -> (done: bool, err: Error) {
	p := &pr.p
	m.slice_spent = 0
	context.temp_allocator = virtual.arena_allocator(&p.chunk)
	attr_begin(m)
	done, err = _pass_steps(pr)
	attr_end(m)
	if err != .None {
		_pass_fail(pr)
		if m.history != nil {
			history_trim(m.history)
		}
		return true, err
	}
	if !done {
		return false, .None
	}
	attr_begin(m)
	err = _pass_epilogue(pr)
	attr_end(m)
	if err != .None {
		_pass_fail(pr)
	}
	if m.history != nil {
		history_trim(m.history)
	}
	return true, err
}

@(private)
_pass_steps :: proc(pr: ^Pass_Run) -> (done: bool, err: Error) {
	p := &pr.p
	for {
		if pr.flushing {
			fin := _flush_step(pr) or_return
			if !fin {
				return false, .None
			}
			if pr.final {
				pr.stage = .Done
				return true, .None
			}
			continue
		}
		if p.flush_due {
			p.flush_due = false
			_flush_begin(pr, false) or_return
			continue
		}
		if _slice_over(pr) {
			return false, .None
		}
		switch pr.stage {
		case .Keys:
			if pr.ki >= len(pr.keys) {
				pr.stage = .Deep
				continue
			}
			k := pr.keys[pr.ki]
			pr.ki += 1
			if _dirtied_dir(p, k) {
				continue
			}
			collect_path(p, k) or_return
			pass_maybe_flush(p) or_return
		case .Deep:
			if len(pr.frames) > 0 {
				_walk_step(pr) or_return
				continue
			}
			if pr.di >= len(pr.deep) {
				pr.stage = .Final
				continue
			}
			u := pr.deep[pr.di]
			pr.di += 1
			d := probe(p.m, u) or_return
			if d.kind != .Dir {
				collect_path(p, u) or_return
				continue
			}
			append(&pr.frames, Walk_Frame{rel = clone_string(u, runtime.heap_allocator()) or_else "", wd = -1})
		case .Walk:
			if len(pr.frames) == 0 {
				pr.stage = .Final
				continue
			}
			_walk_step(pr) or_return
		case .Final:
			pr.final = true
			_flush_begin(pr, true) or_return
			if !pr.flushing {
				pr.stage = .Done
			}
		case .Done:
			return true, .None
		}
	}
}

@(private)
_dirtied_dir :: proc(p: ^Pass, rel: string) -> bool {
	m := p.m
	if rel not_in m.dirty {
		return false
	}
	e, found, _ := shadow_get(&m.shadow, rel)
	if !found || e.kind != .Dir {
		return false
	}
	if m.redeep == nil {
		m.redeep = make(map[string]bool, m.allocator)
	}
	if rel not_in m.redeep {
		k, _ := clone_string(rel, m.allocator)
		m.redeep[k] = true
	}
	return true
}

@(private)
_frame_free :: proc(f: ^Walk_Frame) {
	heap := runtime.heap_allocator()
	shadow_children_free(f.kids[:], heap)
	delete(f.kids)
	for k in f.names {
		delete(k, heap)
	}
	delete(f.names)
	delete(f.pending, heap)
	delete(f.rel, heap)
	f^ = {}
}

@(private)
_frame_pop :: proc(pr: ^Pass_Run) -> Error {
	f := pop(&pr.frames)
	_frame_free(&f)
	if len(pr.frames) > 0 {
		return pass_maybe_flush(&pr.p)
	}
	return .None
}

@(private)
_frame_list :: proc(p: ^Pass, f: ^Walk_Frame) -> Error {
	m := p.m
	heap := runtime.heap_allocator()
	f.listed = true
	f.kids = make([dynamic]Shadow_Child, heap)
	f.names = make(map[string]Listed, heap)
	shadow_children(&m.shadow, f.rel, &f.kids, heap) or_return
	abuf: prim.Path_Buf
	abs := abs_path(m, f.rel, abuf[:])
	d: prim.Dir
	if err := prim.dir_open(m.vfs, &d, abs, heap); err != .None {
		if gone(err) {
			f.gone = true
			return .None
		}
		return from_prim(err)
	}
	n := 0
	for {
		de, more, err := prim.dir_next(m.vfs, &d)
		if err != .None {
			prim.dir_close(m.vfs, &d)
			return from_prim(err)
		}
		if !more {
			break
		}
		if de.name == "." || de.name == ".." || name_internal(de.name) {
			continue
		}
		n += 1
		f.names[clone_string(de.name, heap) or_else ""] = Listed{kind = de.kind, has_stat = de.has_stat, size = de.size, mtime_ns = de.mtime_ns, ctime_ns = de.ctime_ns, ino = de.ino}
	}
	prim.dir_close(m.vfs, &d)
	slice_charge(m, SLICE_COST_DIR + i64(n) * SLICE_COST_ENTRY / 8)
	return .None
}

@(private)
_walk_step :: proc(pr: ^Pass_Run) -> Error {
	p := &pr.p
	m := p.m
	heap := runtime.heap_allocator()
	f := &pr.frames[len(pr.frames) - 1]
	if !f.listed {
		_frame_list(p, f) or_return
		if f.gone {
			return _frame_pop(pr)
		}
		return .None
	}
	cbuf: [prim.PATH_MAX]u8
	if f.ki < len(f.kids) {
		k := f.kids[f.ki]
		f.ki += 1
		child, ok := path_join_buf(cbuf[:], f.rel, k.name)
		if !ok {
			return .None
		}
		ls, listed := f.names[k.name]
		if !listed {
			add_remove_tree(p, child, k.entry) or_return
			return pass_maybe_flush(p)
		}
		dk, _ := delete_key(&f.names, k.name)
		delete(dk, heap)
		if _dirtied_dir(p, child) {
			return .None
		}
		if ls.has_stat && ls.kind == .File && k.entry.kind == .File && ls.size == k.entry.stat.size && ls.mtime_ns == k.entry.stat.mtime_ns && ls.ctime_ns == k.entry.stat.ctime_ns && ls.ino == k.entry.stat.ino {
			return .None
		}
		dp := Probe{kind = .Dir}
		if !(ls.kind == .Dir && k.entry.kind == .Dir) {
			dp = probe(m, child, true) or_return
		}
		if k.entry.kind == .Dir && dp.kind == .Dir {
			c, _ := clone_string(child, heap)
			cwd, _ := watch_dir(m.reg, m, c, f.wd)
			append(&pr.frames, Walk_Frame{rel = c, wd = cwd})
			return .None
		} else if dp.kind == .File && k.entry.kind == .File && dp.stat == k.entry.stat {
			return .None
		}
		collect_path(p, child, true) or_return
		return pass_maybe_flush(p)
	}
	if f.pending == nil {
		f.pending = sorted_strings(f.names, heap)
	}
	if f.pi < len(f.pending) {
		name := f.pending[f.pi]
		f.pi += 1
		child, ok := path_join_buf(cbuf[:], f.rel, name)
		if !ok {
			return .None
		}
		wd := f.wd
		collect_path(p, child) or_return
		if c := last_change(p); c != nil && c.path == child && c.kind == .Create && c.disk == .Dir {
			watch_dir(m.reg, m, child, wd)
		}
		return pass_maybe_flush(p)
	}
	return _frame_pop(pr)
}

@(private)
_flush_begin :: proc(pr: ^Pass_Run, final: bool) -> Error {
	p := &pr.p
	pr.flushing = true
	pr.ui = 0
	pr.uo = 0
	clear(&pr.units)
	p.plan_err = .None
	if !pass_flush_plan(p, final, &pr.units) {
		pr.flushing = false
		return p.plan_err
	}
	return .None
}

@(private)
_flush_step :: proc(pr: ^Pass_Run) -> (done: bool, err: Error) {
	p := &pr.p
	cap := PASS_CHUNK
	if p.budget > 0 {
		cap = SLICE_COMMIT
		if p.m.reg != nil && p.m.reg.slice_commit > 0 {
			cap = p.m.reg.slice_commit
		}
	}
	did := false
	for pr.ui < len(pr.units) {
		if did && _slice_over(pr) {
			return false, .None
		}
		did = true
		step := cap
		if p.budget > 0 {
			left := max(p.budget - p.m.slice_spent, 0)
			step = clamp(int(left / SLICE_COST_EST), 1, cap)
		}
		u := pr.units[pr.ui]
		hi := min(pr.uo + step, len(u.idx))
		marker := u.marker if pr.uo == 0 else nil
		commit_bounded(p, u.actor, u.idx[pr.uo:hi], marker) or_return
		slice_charge(p.m, SLICE_COST_COMMIT + i64(hi - pr.uo) * SLICE_COST_CHANGE)
		pr.uo = hi
		if pr.uo >= len(u.idx) {
			pr.ui += 1
			pr.uo = 0
		}
	}
	pass_flush_done(p) or_return
	pr.flushing = false
	return true, .None
}
