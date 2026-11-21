package fs

import "base:runtime"
import "core:slice"
import "core:sync"
import "core:thread"
import "../prim"

Disk_Kind :: enum u8 {
	Missing,
	File,
	Dir,
	Symlink,
	Other,
}

Scan_Entry :: struct {
	name:    string,
	target:  string,
	kind:    Disk_Kind,
	ignored: bool,
	statted: bool,
	stat:    Stat,
	task:    ^Dir_Task,
}

Scan_Item :: struct {
	path:    string,
	name:    string,
	target:  string,
	kind:    Disk_Kind,
	ignored: bool,
	statted: bool,
	stat:    Stat,
	depth:   int,
}

Raw_Dirent :: struct {
	name_off:   u32,
	name_len:   u32,
	target_off: u32,
	target_len: u32,
	kind:       Disk_Kind,
	statted:    bool,
	stat:       Stat,
}

@(private)
Task_State :: enum u8 {
	Pending,
	Claimed,
	Done,
}

Dir_Task :: struct {
	path:      string,
	chain:     ^Ignore_Chain,
	entries:   [dynamic]Scan_Entry,
	names:     [dynamic]u8,
	err:       Error,
	state:     Task_State,
	cancelled: bool,
}

@(private)
Scan_Frame :: struct {
	task:  ^Dir_Task,
	index: int,
	plen:  int,
}

SCAN_OUTSTANDING :: 256

Scan_Options :: struct {
	threads:      int,
	stat_ignored: bool,
	descend_ignored: bool,
}

Scanner :: struct {
	vfs:       prim.Vfs,
	root:      string,
	root_fd:   prim.Fd,
	ignore:    ^Ignore,
	opts:      Scan_Options,
	allocator: runtime.Allocator,
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	stack:     [dynamic]^Dir_Task,
	outstanding: int,
	closing:   bool,
	workers:   [dynamic]^thread.Thread,
	frames:    [dynamic]Scan_Frame,
	path:      [dynamic]u8,
	item:      Scan_Item,
	pending_child: ^Dir_Task,
	chains:    [dynamic]^Ignore_Chain,
	rules:     [dynamic]^Rules,
	first:     bool,
	err:       Error,
	start:     ^Dir_Task,
}

scan_open :: proc(sc: ^Scanner, vfs: prim.Vfs, root: string, start: string, ig: ^Ignore, chain: ^Ignore_Chain, opts: Scan_Options, allocator := context.allocator) -> Error {
	sc^ = {
		vfs       = vfs,
		root      = root,
		root_fd   = prim.INVALID_FD,
		ignore    = ig,
		opts      = opts,
		allocator = runtime.heap_allocator(),
	}
	_ = allocator
	a := sc.allocator
	sc.stack = make([dynamic]^Dir_Task, a)
	sc.workers = make([dynamic]^thread.Thread, a)
	sc.frames = make([dynamic]Scan_Frame, a)
	sc.path = make([dynamic]u8, a)
	sc.chains = make([dynamic]^Ignore_Chain, a)
	sc.rules = make([dynamic]^Rules, a)
	fd, err := _open_root(sc, root)
	if err != .None {
		scan_close(sc)
		return err
	}
	sc.root_fd = fd
	t := new_task(sc, start, chain)
	if t == nil {
		scan_close(sc)
		return .No_Memory
	}
	sc.start = t
	append(&sc.stack, t)
	append(&sc.path, ..transmute([]u8)start)
	n := sc.opts.threads
	if n <= 0 || vfs.procs != prim.os_vfs().procs {
		n = 1
	}
	for _ in 1 ..< n {
		w := thread.create_and_start_with_data(sc, worker_main, context)
		if w != nil {
			append(&sc.workers, w)
		}
	}
	sc.first = true
	return .None
}

scan_close :: proc(sc: ^Scanner) {
	sync.mutex_lock(&sc.mutex)
	sc.closing = true
	sync.cond_broadcast(&sc.cond)
	sync.mutex_unlock(&sc.mutex)
	for w in sc.workers {
		thread.join(w)
		thread.destroy(w)
	}
	clear(&sc.workers)
	for len(sc.frames) > 0 {
		f := pop(&sc.frames)
		for i in f.index ..< len(f.task.entries) {
			if c := f.task.entries[i].task; c != nil {
				cancel_task(sc, c)
			}
		}
		free_task(sc, f.task)
	}
	if sc.pending_child != nil {
		cancel_task(sc, sc.pending_child)
		sc.pending_child = nil
	}
	if sc.first && sc.start != nil {
		cancel_task(sc, sc.start)
	}
	for len(sc.stack) > 0 {
		t := pop(&sc.stack)
		cancel_done(sc, t)
	}
	for c in sc.chains {
		free(c, sc.allocator)
	}
	for r in sc.rules {
		rules_destroy(r, sc.allocator)
	}
	delete(sc.stack)
	delete(sc.workers)
	delete(sc.frames)
	delete(sc.path)
	delete(sc.chains)
	delete(sc.rules)
	if sc.root_fd >= 0 {
		prim.close_file(sc.vfs, sc.root_fd)
	}
	sc^ = {}
}

scan_root_entry :: proc(sc: ^Scanner) -> (^Dir_Task) {
	return sc.start
}

scan_next :: proc(sc: ^Scanner) -> (item: ^Scan_Item, ok: bool, err: Error) {
	if sc.first {
		sc.first = false
		wait_task(sc, sc.start)
		if sc.start.err != .None {
			e := sc.start.err
			free_task(sc, sc.start)
			sc.start = nil
			return nil, false, e
		}
		append(&sc.frames, Scan_Frame{task = sc.start, plen = len(sc.path)})
		sc.start = nil
	}
	if sc.pending_child != nil {
		c := sc.pending_child
		sc.pending_child = nil
		wait_task(sc, c)
		append(&sc.frames, Scan_Frame{task = c, plen = len(sc.path)})
	}
	for len(sc.frames) > 0 {
		f := &sc.frames[len(sc.frames) - 1]
		if f.index >= len(f.task.entries) {
			t := f.task
			pop(&sc.frames)
			free_task(sc, t)
			if len(sc.frames) > 0 {
				resize(&sc.path, sc.frames[len(sc.frames) - 1].plen)
			}
			continue
		}
		e := f.task.entries[f.index]
		f.index += 1
		resize(&sc.path, f.plen)
		if len(sc.path) > 0 {
			append(&sc.path, '/')
		}
		append(&sc.path, ..transmute([]u8)e.name)
		sc.item = Scan_Item {
			path    = string(sc.path[:]),
			name    = e.name,
			target  = e.target,
			kind    = e.kind,
			ignored = e.ignored,
			statted = e.statted,
			stat    = e.stat,
			depth   = len(sc.frames),
		}
		if e.task != nil {
			sc.pending_child = e.task
		}
		return &sc.item, true, .None
	}
	return nil, false, .None
}

scan_skip :: proc(sc: ^Scanner) {
	if sc.pending_child != nil {
		cancel_task(sc, sc.pending_child)
		sc.pending_child = nil
	}
}

scan_dir_error :: proc(sc: ^Scanner) -> Error {
	if sc.pending_child != nil {
		wait_task(sc, sc.pending_child)
		return sc.pending_child.err
	}
	return .None
}

@(private)
new_task :: proc(sc: ^Scanner, path: string, chain: ^Ignore_Chain) -> ^Dir_Task {
	t := new(Dir_Task, sc.allocator)
	if t == nil {
		return nil
	}
	p, err := clone_string(path, sc.allocator)
	if err != nil {
		free(t, sc.allocator)
		return nil
	}
	t.path = p
	t.chain = chain
	t.entries = make([dynamic]Scan_Entry, sc.allocator)
	t.names = make([dynamic]u8, sc.allocator)
	return t
}

@(private)
free_task :: proc(sc: ^Scanner, t: ^Dir_Task) {
	delete(t.path, sc.allocator)
	delete(t.entries)
	delete(t.names)
	free(t, sc.allocator)
	sync.mutex_lock(&sc.mutex)
	if sc.outstanding > 0 {
		sc.outstanding -= 1
	}
	sync.cond_broadcast(&sc.cond)
	sync.mutex_unlock(&sc.mutex)
}

@(private)
cancel_task :: proc(sc: ^Scanner, t: ^Dir_Task) {
	sync.mutex_lock(&sc.mutex)
	switch t.state {
	case .Pending:
		t.cancelled = true
		sync.mutex_unlock(&sc.mutex)
		return
	case .Claimed:
		t.cancelled = true
		sync.mutex_unlock(&sc.mutex)
		return
	case .Done:
	}
	sync.mutex_unlock(&sc.mutex)
	for e in t.entries {
		if e.task != nil {
			cancel_task(sc, e.task)
		}
	}
	free_task(sc, t)
}

@(private)
wait_task :: proc(sc: ^Scanner, t: ^Dir_Task) {
	sync.mutex_lock(&sc.mutex)
	if t.state == .Pending {
		t.state = .Claimed
		sc.outstanding += 1
		for i := len(sc.stack) - 1; i >= 0; i -= 1 {
			if sc.stack[i] == t {
				ordered_remove(&sc.stack, i)
				break
			}
		}
		sync.mutex_unlock(&sc.mutex)
		run_task(sc, t)
		return
	}
	for t.state != .Done {
		sync.cond_wait(&sc.cond, &sc.mutex)
	}
	sync.mutex_unlock(&sc.mutex)
}

@(private)
worker_main :: proc(data: rawptr) {
	sc := (^Scanner)(data)
	for {
		sync.mutex_lock(&sc.mutex)
		t: ^Dir_Task
		for {
			if sc.closing {
				sync.mutex_unlock(&sc.mutex)
				return
			}
			for len(sc.stack) > 0 {
				top := sc.stack[len(sc.stack) - 1]
				if top.cancelled {
					pop(&sc.stack)
					top.state = .Done
					sync.mutex_unlock(&sc.mutex)
					cancel_done(sc, top)
					sync.mutex_lock(&sc.mutex)
					continue
				}
				break
			}
			if len(sc.stack) > 0 && sc.outstanding < SCAN_OUTSTANDING {
				t = pop(&sc.stack)
				t.state = .Claimed
				sc.outstanding += 1
				break
			}
			sync.cond_wait(&sc.cond, &sc.mutex)
		}
		sync.mutex_unlock(&sc.mutex)
		run_task(sc, t)
	}
}

@(private)
cancel_done :: proc(sc: ^Scanner, t: ^Dir_Task) {
	for e in t.entries {
		if e.task != nil {
			cancel_task(sc, e.task)
		}
	}
	delete(t.path, sc.allocator)
	delete(t.entries)
	delete(t.names)
	free(t, sc.allocator)
}

@(private)
run_task :: proc(sc: ^Scanner, t: ^Dir_Task) {
	gitignore: []u8
	raw := make([dynamic]Raw_Dirent, sc.allocator)
	if sc.vfs.procs == prim.os_vfs().procs {
		t.err = _read_dir(sc, t, &raw, &gitignore)
	} else {
		t.err = read_dir_vfs(sc, t, &raw, &gitignore)
	}
	if t.err == .None {
		finish_task(sc, t, raw[:], gitignore)
	}
	delete(raw)
	if gitignore != nil {
		delete(gitignore, sc.allocator)
	}
	sync.mutex_lock(&sc.mutex)
	cancelled := t.cancelled
	t.state = .Done
	if !cancelled {
		for i := len(t.entries) - 1; i >= 0; i -= 1 {
			if c := t.entries[i].task; c != nil {
				append(&sc.stack, c)
			}
		}
	}
	sync.cond_broadcast(&sc.cond)
	sync.mutex_unlock(&sc.mutex)
	if cancelled {
		for e in t.entries {
			if e.task != nil {
				e.task.cancelled = true
				e.task.state = .Done
				cancel_done(sc, e.task)
			}
		}
		delete(t.path, sc.allocator)
		delete(t.entries)
		delete(t.names)
		free(t, sc.allocator)
		sync.mutex_lock(&sc.mutex)
		sc.outstanding -= 1
		sync.cond_broadcast(&sc.cond)
		sync.mutex_unlock(&sc.mutex)
	}
}

@(private)
finish_task :: proc(sc: ^Scanner, t: ^Dir_Task, raw: []Raw_Dirent, gitignore: []u8) {
	chain := t.chain
	if len(gitignore) > 0 {
		r, err := rules_parse(gitignore, t.path, sc.allocator)
		if err == .None && r != nil {
			c := new(Ignore_Chain, sc.allocator)
			c.rules = r
			c.parent = t.chain
			chain = c
			sync.mutex_lock(&sc.mutex)
			append(&sc.rules, r)
			append(&sc.chains, c)
			sync.mutex_unlock(&sc.mutex)
		}
	}
	reserve(&t.entries, len(raw))
	for r in raw {
		e := Scan_Entry {
			name    = string(t.names[r.name_off:][:r.name_len]),
			target  = string(t.names[r.target_off:][:r.target_len]),
			kind    = r.kind,
			statted = r.statted,
			stat    = r.stat,
		}
		append(&t.entries, e)
	}
	buf: [prim.PATH_MAX]u8
	for &e in t.entries {
		rel, ok := path_join_buf(buf[:], t.path, e.name)
		if !ok {
			e.ignored = true
			continue
		}
		e.ignored = sc.ignore != nil && ignore_match(sc.ignore, chain, rel, e.kind == .Dir)
	}
	context.user_ptr = nil
	slice.sort_by(t.entries[:], proc(a, b: Scan_Entry) -> bool {
		return git_path_cmp(a.name, a.kind == .Dir, b.name, b.kind == .Dir) < 0
	})
	for &e in t.entries {
		if e.kind == .Dir && (!e.ignored || sc.opts.descend_ignored) {
			rel, ok := path_join_buf(buf[:], t.path, e.name)
			if ok {
				e.task = new_task(sc, rel, chain)
			}
		}
	}
}

disk_kind :: proc "contextless" (k: prim.File_Kind) -> Disk_Kind {
	switch k {
	case .File:
		return .File
	case .Dir:
		return .Dir
	case .Symlink:
		return .Symlink
	case .Other:
		return .Other
	case .Unknown:
		return .Missing
	}
	return .Other
}

disk_stat :: proc "contextless" (st: prim.Stat) -> Stat {
	return Stat{mtime_ns = st.mtime_ns, ctime_ns = st.ctime_ns, size = st.size, ino = st.ino, mode = st.mode}
}

@(private)
read_dir_vfs :: proc(sc: ^Scanner, t: ^Dir_Task, raw: ^[dynamic]Raw_Dirent, gitignore: ^[]u8) -> Error {
	dbuf: prim.Path_Buf
	dir, ok := path_join_buf(dbuf[:], sc.root, t.path)
	if !ok {
		return .Name_Too_Long
	}
	d: prim.Dir
	if err := prim.dir_open(sc.vfs, &d, dir, sc.allocator); err != .None {
		return from_prim(err)
	}
	defer prim.dir_close(sc.vfs, &d)
	for {
		e, more, err := prim.dir_next(sc.vfs, &d)
		if err != .None {
			return from_prim(err)
		}
		if !more {
			break
		}
		if e.name == "." || e.name == ".." || name_internal(e.name) {
			continue
		}
		append(raw, Raw_Dirent{name_off = u32(len(t.names)), name_len = u32(len(e.name)), kind = disk_kind(e.kind)})
		append(&t.names, ..transmute([]u8)e.name)
	}
	pbuf: prim.Path_Buf
	for &r in raw {
		name := string(t.names[r.name_off:][:r.name_len])
		p, pok := path_join_buf(pbuf[:], dir, name)
		if !pok {
			r.kind = .Other
			continue
		}
		st, serr := prim.lstat(sc.vfs, p)
		if serr != .None {
			r.kind = .Missing if serr == .Not_Found else .Other
			continue
		}
		r.kind = disk_kind(st.kind)
		r.stat = disk_stat(st)
		r.statted = true
		if r.kind == .Symlink {
			tbuf: [prim.PATH_MAX]u8
			n, lerr := prim.readlink(sc.vfs, p, tbuf[:])
			if lerr != .None || n <= 0 || n >= len(tbuf) {
				r.kind = .Other
				continue
			}
			r.target_off = u32(len(t.names))
			r.target_len = u32(n)
			append(&t.names, ..tbuf[:n])
		} else if r.kind == .File && name == ".gitignore" && gitignore^ == nil && r.stat.size < 8 << 20 {
			data, rerr := prim.read_file(sc.vfs, p, sc.allocator)
			if rerr == .None {
				gitignore^ = data
			}
		}
	}
	w := 0
	for r in raw {
		if r.kind != .Missing {
			raw[w] = r
			w += 1
		}
	}
	resize(raw, w)
	return .None
}
