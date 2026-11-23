package sim

import "core:fmt"
import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
Pf_Kind :: enum u8 {
	None,
	Create,
	Remove,
	Rename_Dir,
	Rewrite,
}

@(private = "file")
Pf_Node :: struct {
	reg:   ^fs.Registry,
	armed: Pf_Kind,
	dirs:  [dynamic]string,
	seq:   int,
}

@(private = "file")
pf_nodes: map[^Node]^Pf_Node

STAT_PF_SLICES: Stat
STAT_PF_FAULTS: Stat
STAT_PF_SEEDS: Stat

@(init)
_passfault_init :: proc "contextless" () {
	register_op(40, "pass_fault", _pf_weight, _pf_run)
	register_world(40, nil, _pf_destroy)
	register_stat_line(60, "resumable_passes")
	STAT_PF_SLICES = register_stat(60, 0, "slices")
	STAT_PF_FAULTS = register_stat(60, 1, "faults")
	STAT_PF_SEEDS = register_stat(60, 2, "seeded_dirs")
}

@(private = "file")
_pf_destroy :: proc(w: ^World) {
	for _, st in pf_nodes {
		for d in st.dirs {
			delete(d, w.allocator)
		}
		delete(st.dirs)
		free(st, w.allocator)
	}
	delete(pf_nodes)
	pf_nodes = nil
}

@(private = "file")
_pf_weight :: proc(w: ^World) -> int {
	for n in w.nodes {
		if n.alive && n.reg != nil && len(n.mounts) > 0 {
			return 3
		}
	}
	return 0
}

@(private = "file")
_pf_state :: proc(w: ^World, n: ^Node) -> ^Pf_Node {
	if pf_nodes == nil {
		pf_nodes = make(map[^Node]^Pf_Node, w.allocator)
	}
	st, ok := pf_nodes[n]
	if !ok {
		st = new(Pf_Node, w.allocator)
		st.dirs = make([dynamic]string, w.allocator)
		pf_nodes[n] = st
	}
	return st
}

@(private = "file")
_pf_mount :: proc(w: ^World, n: ^Node, m: ^fs.Mount) -> (sm: ^Sim_Mount, ok: bool) {
	for &x in n.mounts {
		if x.m != nil && (m == nil || x.m == m) {
			return &x, true
		}
	}
	return nil, false
}

@(private = "file")
_pf_run :: proc(w: ^World, n: ^Node) {
	if !n.alive || n.reg == nil || n.disk.dead {
		return
	}
	st := _pf_state(w, n)
	context = instance_context(&n.inst)
	if st.reg != n.reg {
		st.reg = n.reg
		fs.registry_set_slice(n.reg, i64(1 + rng_int(&w.rng, 12)), 1 + rng_int(&w.rng, 4), _pf_hook, n)
	}
	sm, ok := _pf_mount(w, n, nil)
	if !ok {
		return
	}
	if len(st.dirs) == 0 || rng_chance(&w.rng, 1, 3) {
		_pf_seed(w, n, st, sm)
	} else {
		st.armed = Pf_Kind(1 + rng_int(&w.rng, 4))
		paths := TREE_PATHS
		_pf_person(w, n, sm, paths[rng_int(&w.rng, len(paths))], false)
	}
	node_after(n)
}

@(private = "file")
_pf_seed :: proc(w: ^World, n: ^Node, st: ^Pf_Node, sm: ^Sim_Mount) {
	st.seq += 1
	dir := fmt.aprintf("pf%d_%d", n.idx, st.seq, allocator = w.allocator)
	vfs := disk_vfs(&n.disk)
	abs := strings.concatenate({sm.root, "/", dir}, context.temp_allocator)
	if prim.mkdir_all(vfs, abs, 0o755) != .None {
		delete(dir, w.allocator)
		return
	}
	append(&st.dirs, dir)
	stat_add(w, STAT_PF_SEEDS)
	for i in 0 ..< 2 + rng_int(&w.rng, 5) {
		name := fmt.tprintf("%s/f%d.txt", dir, i)
		_pf_agent(w, n, sm, name)
		if n.disk.dead {
			return
		}
	}
}

@(private = "file")
_pf_agent :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, rel: string) {
	m := &w.model
	vfs := disk_vfs(&n.disk)
	abs := strings.concatenate({sm.root, "/", rel}, context.temp_allocator)
	op := new_op(m, .Disk_Agent, n, sm.oi)
	op.path = strings.clone(rel, w.allocator)
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 1 + rng_int(&w.rng, 2) {
		tok := new_token(m, n, "a")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	op.actor = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	scope := fs.scope_open(n.reg, sm.m, sid, op.actor)
	_pf_writer(w, n, abs, Writer_Info{scope = scope, agent = true})
	if oerr := fs.mount_observe_begin(sm.m, rel, scope); oerr != .None && !n.disk.dead && w.cfg.io_rate == 0 {
		world_fail(w, "%s pass_fault mount_observe_begin failed: %v", n.name, oerr)
	}
	err := _pf_write(vfs, abs, transmute([]u8)strings.to_string(b))
	serr := fs.Error.None
	if !n.disk.dead {
		serr = fs.scope_close(n.reg, scope)
		_pf_forget(w, n, scope)
	}
	world_note(w, "%s pass_fault agent(actor %s) wrote %s %v -> %v %v", n.name, id_short(op.actor), rel, op.tokens[:], err, serr)
	if err != .None || n.disk.dead {
		op.status = .Uncertain
		return
	}
	op_done(op, eng.pending_seq(&n.e), .None)
}

@(private = "file")
_pf_person :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, rel: string, overwrite: bool) {
	m := &w.model
	vfs := disk_vfs(&n.disk)
	abs := strings.concatenate({sm.root, "/", rel}, context.temp_allocator)
	old, _ := prim.read_file(vfs, abs, context.temp_allocator)
	if n.disk.dead {
		return
	}
	op := new_op(m, .Disk_Person, n, sm.oi)
	op.path = strings.clone(rel, w.allocator)
	b := strings.builder_make(context.temp_allocator)
	if overwrite && len(old) > 0 {
		op.overwrite = true
		for t in parse_tokens(old) {
			append(&op.deletes, strings.clone(t.text, w.allocator))
		}
	} else {
		strings.write_bytes(&b, old)
	}
	tok := new_token(m, n, "p")
	append(&op.tokens, tok)
	strings.write_string(&b, tok)
	strings.write_byte(&b, '\n')
	_pf_writer(w, n, abs, Writer_Info{})
	err := _pf_write(vfs, abs, transmute([]u8)strings.to_string(b))
	world_note(w, "%s pass_fault person %s %s %v -> %v", n.name, "overwrote" if op.overwrite else "appended", rel, op.tokens[:], err)
	if err != .None || n.disk.dead {
		op.status = .Uncertain
		return
	}
	op_done(op, 0, .None)
	op.status = .Acked
}

@(private = "file")
_pf_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	if err != .None {
		return err
	}
	return prim.sync_dir(vfs, prim.dir_name(path))
}

@(private = "file")
_pf_writer :: proc(w: ^World, n: ^Node, path: string, info: Writer_Info) {
	if _, has := n.writers[path]; has {
		n.writers[path] = info
		return
	}
	n.writers[strings.clone(path, w.allocator)] = info
}

@(private = "file")
_pf_forget :: proc(w: ^World, n: ^Node, scope: ^fs.Scope) {
	keys := make([dynamic]string, context.temp_allocator)
	for k, v in n.writers {
		if v.scope == scope && scope != nil {
			append(&keys, k)
		}
	}
	for k in keys {
		owned, _ := delete_key(&n.writers, k)
		delete(owned, w.allocator)
	}
}

@(private = "file")
_pf_files :: proc(n: ^Node, sm: ^Sim_Mount, dir: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	d: prim.Dir
	abs := strings.concatenate({sm.root, "/", dir}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	if prim.dir_open(vfs, &d, abs, context.temp_allocator) != .None {
		return out
	}
	defer prim.dir_close(vfs, &d)
	for {
		e, more, err := prim.dir_next(vfs, &d)
		if err != .None || !more {
			break
		}
		if e.kind == .File && strings.has_suffix(e.name, ".txt") {
			append(&out, strings.concatenate({dir, "/", e.name}, context.temp_allocator))
		}
	}
	return out
}

@(private = "file")
_pf_hook :: proc(m: ^fs.Mount, data: rawptr) {
	n := (^Node)(data)
	w := n.w
	stat_add(w, STAT_PF_SLICES)
	st, ok := pf_nodes[n]
	if !ok || st.armed == .None || n.disk.dead || len(st.dirs) == 0 {
		return
	}
	sm, mok := _pf_mount(w, n, m)
	if !mok {
		return
	}
	kind := st.armed
	st.armed = .None
	stat_add(w, STAT_PF_FAULTS)
	di := rng_int(&w.rng, len(st.dirs))
	dir := st.dirs[di]
	vfs := disk_vfs(&n.disk)
	switch kind {
	case .None:
	case .Create:
		st.seq += 1
		_pf_person(w, n, sm, fmt.tprintf("%s/new%d.txt", dir, st.seq), false)
	case .Rewrite:
		files := _pf_files(n, sm, dir)
		if len(files) > 0 {
			_pf_person(w, n, sm, files[rng_int(&w.rng, len(files))], true)
		}
	case .Remove:
		files := _pf_files(n, sm, dir)
		if len(files) < 2 {
			return
		}
		rel := files[rng_int(&w.rng, len(files))]
		abs := strings.concatenate({sm.root, "/", rel}, context.temp_allocator)
		old, _ := prim.read_file(vfs, abs, context.temp_allocator)
		op := new_op(&w.model, .Disk_Person, n, sm.oi)
		op.path = strings.clone(rel, w.allocator)
		op.overwrite = true
		for t in parse_tokens(old) {
			append(&op.deletes, strings.clone(t.text, w.allocator))
		}
		err := prim.remove(vfs, abs)
		world_note(w, "%s pass_fault removed %s %v -> %v", n.name, rel, op.deletes[:], err)
		if err != .None || n.disk.dead {
			op.status = .Uncertain
			return
		}
		op_done(op, 0, .None)
		op.status = .Acked
	case .Rename_Dir:
		st.seq += 1
		to := fmt.aprintf("%s_r%d", dir, st.seq, allocator = w.allocator)
		from_abs := strings.concatenate({sm.root, "/", dir}, context.temp_allocator)
		to_abs := strings.concatenate({sm.root, "/", to}, context.temp_allocator)
		err := prim.rename(vfs, from_abs, to_abs)
		world_note(w, "%s pass_fault renamed %s -> %s: %v", n.name, dir, to, err)
		if err != .None {
			delete(to, w.allocator)
			return
		}
		delete(dir, w.allocator)
		st.dirs[di] = to
	}
}
