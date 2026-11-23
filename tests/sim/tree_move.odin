package sim

import "core:fmt"
import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

TM_DIRS :: [?]string{"d1", "d2"}
TM_NAMES :: [?]string{"a.txt", "b.txt", "c.txt", "m1.txt", "m2.txt"}

Tm_Kind :: enum u8 {
	One_Name,
	Edit_Follows,
	Replaced_Edit,
}

Tm_Record :: struct {
	kind:  Tm_Kind,
	obj:   int,
	file:  [dynamic]string,
	other: [dynamic]string,
	what:  string,
	line:  string,
	ops:   int,
}

Tm_World :: struct {
	w:       ^World,
	records: [dynamic]Tm_Record,
}

@(thread_local, private = "file")
_tm: ^Tm_World

STAT_TM_RENAME: Stat
STAT_TM_DIR: Stat
STAT_TM_NAMES: Stat
STAT_TM_CYCLE: Stat
STAT_TM_REMOVE: Stat
STAT_TM_EDIT: Stat
STAT_TM_REPLACE: Stat

@(init)
_tree_move_init :: proc "contextless" () {
	register_world(40, _tm_init, _tm_destroy)
	register_op(13, "tree_move", proc(w: ^World) -> int {return 12 if env_u64("SIM_TREE_MOVE", 0) != 0 else 0}, op_tree_move)
	register_final_check(120, check_tree_moves)
	register_stat_line(53, "tree_moves")
	STAT_TM_RENAME = register_stat(53, 0, "renames")
	STAT_TM_DIR = register_stat(53, 1, "dir_moves")
	STAT_TM_NAMES = register_stat(53, 2, "two_names")
	STAT_TM_CYCLE = register_stat(53, 3, "cycles")
	STAT_TM_REMOVE = register_stat(53, 4, "vs_remove")
	STAT_TM_EDIT = register_stat(53, 5, "vs_edit")
	STAT_TM_REPLACE = register_stat(53, 6, "replace_edit")
}

@(private = "file")
_tm_init :: proc(w: ^World) {
	_tm = new(Tm_World, w.allocator)
	_tm.w = w
	_tm.records = make([dynamic]Tm_Record, w.allocator)
}

@(private = "file")
_tm_destroy :: proc(w: ^World) {
	if _tm == nil {
		return
	}
	for r in _tm.records {
		for t in r.file {
			delete(t, w.allocator)
		}
		for t in r.other {
			delete(t, w.allocator)
		}
		delete(r.file)
		delete(r.other)
		delete(r.what, w.allocator)
		delete(r.line, w.allocator)
	}
	delete(_tm.records)
	free(_tm, w.allocator)
	_tm = nil
}

@(private = "file")
_live_mount :: proc(w: ^World, n: ^Node) -> (sm: Sim_Mount, ok: bool) {
	live := make([dynamic]int, context.temp_allocator)
	for x, i in n.mounts {
		if x.m != nil {
			append(&live, i)
		}
	}
	if len(live) == 0 || n.reg == nil || !n.alive {
		return {}, false
	}
	return n.mounts[live[rng_int(&w.rng, len(live))]], true
}

@(private = "file")
_peer :: proc(w: ^World, n: ^Node, oi: int) -> (p: ^Node, sm: Sim_Mount, ok: bool) {
	cands := make([dynamic]int, context.temp_allocator)
	for x in w.nodes {
		if x == n || !x.alive || x.reg == nil {
			continue
		}
		for y in x.mounts {
			if y.m != nil && y.oi == oi {
				append(&cands, x.idx)
				break
			}
		}
	}
	if len(cands) == 0 {
		m := &w.model
		si := space_index(m, m.objs[oi].o.space)
		for x in w.nodes {
			if x == n || !x.alive || x.reg == nil || si < 0 || !space_member(&m.spaces[si], x.idx) {
				continue
			}
			already := false
			for mm in m.mounts {
				already ||= mm.node == x.idx && mm.oi == oi
			}
			if !already {
				append(&cands, x.idx)
			}
		}
		if len(cands) == 0 {
			return nil, {}, false
		}
		x := w.nodes[cands[rng_int(&w.rng, len(cands))]]
		if !mount_obj(w, x, oi) {
			return nil, {}, false
		}
		return nil, {}, false
	}
	p = w.nodes[cands[rng_int(&w.rng, len(cands))]]
	for y in p.mounts {
		if y.m != nil && y.oi == oi {
			return p, y, true
		}
	}
	return nil, {}, false
}

@(private = "file")
_abs :: proc(sm: Sim_Mount, rel: string) -> string {
	return strings.concatenate({sm.root, "/", rel}, context.temp_allocator)
}

@(private = "file")
_kind :: proc(n: ^Node, abs: string) -> prim.File_Kind {
	st, err := prim.stat(disk_vfs(&n.disk), abs)
	if err != .None {
		return .Unknown
	}
	return st.kind
}

@(private = "file")
_tokens :: proc(n: ^Node, abs: string) -> []string {
	data, err := prim.read_file(disk_vfs(&n.disk), abs, context.temp_allocator)
	if err != .None {
		return nil
	}
	out := make([dynamic]string, context.temp_allocator)
	for t in parse_tokens(data) {
		append(&out, t.text)
	}
	return out[:]
}

@(private = "file")
_files_under :: proc(n: ^Node, abs: string) -> []string {
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	prefix := strings.concatenate({abs, "/"}, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for f in files {
		if strings.has_prefix(f.path, prefix) {
			append(&out, f.path)
		}
	}
	return out[:]
}

@(private = "file")
_failed :: proc(w: ^World, n: ^Node, err: prim.Error) -> bool {
	if n.disk.dead {
		node_crashed(n)
		return true
	}
	if err == .None {
		return false
	}
	if err == .Io || w.cfg.io_rate > 0 {
		n.restart_pending = true
	}
	return true
}

@(private = "file")
_rename :: proc(w: ^World, n: ^Node, sm: Sim_Mount, from: string, to: string) -> bool {
	m := &w.model
	vfs := disk_vfs(&n.disk)
	src := _abs(sm, from)
	dst := _abs(sm, to)
	rop: ^M_Op
	if _kind(n, dst) == .File {
		rop = new_op(m, .Tree_Remove, n, sm.oi)
		rop.path = strings.clone(to, w.allocator)
		delete(rop.line, w.allocator)
		rop.line = strings.clone(_line(n, sm), w.allocator)
		for t in _tokens(n, dst) {
			append(&rop.deletes, strings.clone(t, w.allocator))
		}
		if !(to in m.objs[sm.oi].removed) {
			m.objs[sm.oi].removed[strings.clone(to, w.allocator)] = true
		}
	}
	mv := new_move(m, n, sm.oi, from, to)
	_writer_set(w, n, src, Writer_Info{})
	_writer_set(w, n, dst, Writer_Info{})
	err := prim.rename(vfs, src, dst)
	if err == .None {
		err = prim.sync_dir(vfs, prim.dir_name(src))
	}
	if err == .None {
		err = prim.sync_dir(vfs, prim.dir_name(dst))
	}
	world_note(w, "%s tree move %s/%s -> %s -> %v", n.name, id_short(m.objs[sm.oi].o.id), from, to, err)
	if err != .None {
		mv.status = .Uncertain if err == .Io else .Failed
		if rop != nil {
			rop.status = mv.status
		}
		_failed(w, n, err)
		return false
	}
	mv.status = .Acked
	if rop != nil {
		op_done(rop, 0, .None)
		rop.status = .Acked
	}
	return true
}

@(private = "file")
_write :: proc(w: ^World, n: ^Node, sm: Sim_Mount, rel: string, append_to: bool, count: int) -> (op: ^M_Op, ok: bool) {
	m := &w.model
	vfs := disk_vfs(&n.disk)
	abs := _abs(sm, rel)
	if err := prim.mkdir_all(vfs, prim.dir_name(abs)); err != .None {
		_failed(w, n, err)
		return nil, false
	}
	b := strings.builder_make(context.temp_allocator)
	if append_to {
		old, _ := prim.read_file(vfs, abs, context.temp_allocator)
		strings.write_bytes(&b, old)
		if len(old) > 0 && old[len(old) - 1] != '\n' {
			strings.write_byte(&b, '\n')
		}
	}
	op = new_op(m, .Disk_Person, n, sm.oi)
	op.path = strings.clone(rel, w.allocator)
	delete(op.line, w.allocator)
	op.line = strings.clone(_line(n, sm), w.allocator)
	for _ in 0 ..< count {
		tok := new_token(m, n, "p")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	_writer_set(w, n, abs, Writer_Info{})
	err := _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), false)
	if err == .None {
		err = prim.sync_dir(vfs, prim.dir_name(prim.dir_name(abs)))
	}
	world_note(w, "%s tree move write %s/%s %v -> %v", n.name, id_short(m.objs[sm.oi].o.id), rel, op.tokens[:], err)
	if err != .None {
		op.status = .Uncertain if err == .Io else .Failed
		_failed(w, n, err)
		return op, false
	}
	op_done(op, 0, .None)
	op.status = .Acked
	return op, true
}

@(private = "file")
_rmtree :: proc(w: ^World, n: ^Node, sm: Sim_Mount, rel: string) {
	m := &w.model
	vfs := disk_vfs(&n.disk)
	abs := _abs(sm, rel)
	files := _files_under(n, abs)
	dirs := make(map[string]bool, context.temp_allocator)
	dirs[abs] = true
	ops := make([dynamic]^M_Op, context.temp_allocator)
	for f in files {
		op := new_op(m, .Tree_Remove, n, sm.oi)
		op.path = strings.clone(f[len(sm.root) + 1:], w.allocator)
		delete(op.line, w.allocator)
		op.line = strings.clone(_line(n, sm), w.allocator)
		for t in _tokens(n, f) {
			append(&op.deletes, strings.clone(t, w.allocator))
		}
		if !(op.path in m.objs[sm.oi].removed) {
			m.objs[sm.oi].removed[strings.clone(op.path, w.allocator)] = true
		}
		append(&ops, op)
		for d := prim.dir_name(f); len(d) > len(abs); d = prim.dir_name(d) {
			dirs[d] = true
		}
		_writer_set(w, n, f, Writer_Info{})
	}
	err := prim.Error.None
	for f, i in files {
		e := prim.remove(vfs, f)
		if e == .None {
			op_done(ops[i], 0, .None)
			ops[i].status = .Acked
		} else {
			ops[i].status = .Uncertain if e == .Io else .Failed
			err = e
		}
	}
	order := make([dynamic]string, context.temp_allocator)
	for d in dirs {
		append(&order, d)
	}
	for len(order) > 0 {
		deepest := 0
		for d, i in order {
			if count_slashes(d) > count_slashes(order[deepest]) {
				deepest = i
			}
		}
		if e := prim.remove_dir(vfs, order[deepest]); e != .None && e != .Not_Empty && err == .None {
			err = e
		}
		unordered_remove(&order, deepest)
	}
	if e := prim.sync_dir(vfs, prim.dir_name(abs)); e != .None && err == .None {
		err = e
	}
	world_note(w, "%s tree move rm -r %s/%s (%d files) -> %v", n.name, id_short(m.objs[sm.oi].o.id), rel, len(files), err)
	_failed(w, n, err)
}

@(private = "file")
count_slashes :: proc(s: string) -> int {
	return strings.count(s, "/")
}

@(private = "file")
_root_file :: proc(w: ^World, n: ^Node, sm: Sim_Mount, also: ^Node = nil, also_sm: Sim_Mount = {}) -> (name: string, ok: bool) {
	names := TM_NAMES
	cands := make([dynamic]string, context.temp_allocator)
	for x in names {
		if _kind(n, _abs(sm, x)) != .File || len(_tokens(n, _abs(sm, x))) == 0 {
			continue
		}
		if also != nil && (_kind(also, _abs(also_sm, x)) != .File || len(_tokens(also, _abs(also_sm, x))) == 0) {
			continue
		}
		append(&cands, x)
	}
	if len(cands) == 0 {
		return "", false
	}
	return cands[rng_int(&w.rng, len(cands))], true
}

@(private = "file")
_free_name :: proc(w: ^World, n: ^Node, sm: Sim_Mount, also: ^Node, also_sm: Sim_Mount, not: string, dir := "") -> (name: string, ok: bool) {
	names := TM_NAMES
	cands := make([dynamic]string, context.temp_allocator)
	for x in names {
		p := x if len(dir) == 0 else strings.concatenate({dir, "/", x}, context.temp_allocator)
		if p == not || _kind(n, _abs(sm, p)) != .Unknown {
			continue
		}
		if also != nil && _kind(also, _abs(also_sm, p)) != .Unknown {
			continue
		}
		append(&cands, p)
	}
	if len(cands) == 0 {
		return "", false
	}
	return cands[rng_int(&w.rng, len(cands))], true
}

@(private = "file")
_dir_file :: proc(w: ^World, n: ^Node, sm: Sim_Mount, dir: string, also: ^Node = nil, also_sm: Sim_Mount = {}) -> (rel: string, ok: bool) {
	cands := make([dynamic]string, context.temp_allocator)
	for f in _files_under(n, _abs(sm, dir)) {
		r := f[len(sm.root) + 1:]
		if strings.count(r, "/") != 1 {
			continue
		}
		if also != nil && _kind(also, _abs(also_sm, r)) != .File {
			continue
		}
		append(&cands, r)
	}
	if len(cands) == 0 {
		return "", false
	}
	return cands[rng_int(&w.rng, len(cands))], true
}

@(private = "file")
_line :: proc(n: ^Node, sm: Sim_Mount) -> string {
	return mount_model_line(sm.m, disk_vfs(&n.disk), sm.root)
}

@(private = "file")
_record :: proc(w: ^World, kind: Tm_Kind, oi: int, file: []string, other: []string, what: string, a: ^Node, asm_: Sim_Mount, b: ^Node, bsm: Sim_Mount) {
	if _tm == nil {
		return
	}
	line := _line(a, asm_)
	if line != _line(b, bsm) {
		return
	}
	r := Tm_Record{kind = kind, obj = oi, file = make([dynamic]string, w.allocator), other = make([dynamic]string, w.allocator), what = strings.clone(what, w.allocator), line = strings.clone(line, w.allocator), ops = len(w.model.ops)}
	for t in file {
		append(&r.file, strings.clone(t, w.allocator))
	}
	for t in other {
		append(&r.other, strings.clone(t, w.allocator))
	}
	append(&_tm.records, r)
}

@(private = "file")
_common :: proc(a: []string, b: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for x in a {
		for y in b {
			if x == y {
				append(&out, x)
				break
			}
		}
	}
	return out[:]
}

op_tree_move :: proc(w: ^World, n: ^Node) {
	sm, ok := _live_mount(w, n)
	if !ok {
		return
	}
	m := &w.model
	if m.objs[sm.oi].kind != .Tree {
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	dirs := TM_DIRS
	shape := 0
	for d in dirs {
		if _kind(n, _abs(sm, d)) != .Dir {
			shape = -1
		}
	}
	if shape == 0 {
		shape = 1 + rng_int(&w.rng, 2) if rng_chance(&w.rng, 1, 3) else 3 + rng_int(&w.rng, 5)
	}
	switch shape {
	case -1:
		for d in dirs {
			if len(_files_under(n, _abs(sm, d))) == 0 {
				names := TM_NAMES
				if _, wok := _write(w, n, sm, strings.concatenate({d, "/", names[rng_int(&w.rng, len(names))]}, context.temp_allocator), false, 1); !wok {
					return
				}
			}
		}
	case 1:
		from, from_ok := _root_file(w, n, sm)
		if !from_ok {
			return
		}
		names := TM_NAMES
		to := names[rng_int(&w.rng, len(names))]
		if to == from {
			return
		}
		if _rename(w, n, sm, from, to) {
			stat_add(w, STAT_TM_RENAME)
		}
	case 2:
		d := dirs[rng_int(&w.rng, len(dirs))]
		if _kind(n, _abs(sm, d)) != .Dir {
			return
		}
		if rng_chance(&w.rng, 1, 2) {
			from, from_ok := _root_file(w, n, sm)
			if !from_ok {
				return
			}
			to, to_ok := _free_name(w, n, sm, nil, {}, "", d)
			if !to_ok {
				return
			}
			if _rename(w, n, sm, from, to) {
				stat_add(w, STAT_TM_DIR)
			}
		} else {
			from, from_ok := _dir_file(w, n, sm, d)
			if !from_ok {
				return
			}
			to, to_ok := _free_name(w, n, sm, nil, {}, "")
			if !to_ok {
				return
			}
			if _rename(w, n, sm, from, to) {
				stat_add(w, STAT_TM_DIR)
			}
		}
	case:
		p, psm, pok := _peer(w, n, sm.oi)
		if !pok {
			return
		}
		context = instance_context(&p.inst)
		defer node_after(p)
		context = instance_context(&n.inst)
		_pair_shape(w, shape, n, sm, p, psm)
	}
}

@(private = "file")
_on :: proc(n: ^Node) {
	context = instance_context(&n.inst)
}

@(private = "file")
_pair_shape :: proc(w: ^World, shape: int, a: ^Node, asm_: Sim_Mount, b: ^Node, bsm: Sim_Mount) {
	dirs := TM_DIRS
	oid := id_short(w.model.objs[asm_.oi].o.id)
	switch shape {
	case 3:
		from, from_ok := _root_file(w, a, asm_, b, bsm)
		if !from_ok {
			return
		}
		x, x_ok := _free_name(w, a, asm_, b, bsm, from)
		if !x_ok {
			return
		}
		y, y_ok := _free_name(w, a, asm_, b, bsm, x)
		if !y_ok {
			return
		}
		if y == from {
			return
		}
		toks := _common(_tokens(a, _abs(asm_, from)), _tokens(b, _abs(bsm, from)))
		if len(toks) == 0 {
			return
		}
		ra := _rename(w, a, asm_, from, x)
		context = instance_context(&b.inst)
		rb := ra && b.alive && _rename(w, b, bsm, from, y)
		context = instance_context(&a.inst)
		if ra && rb {
			_record(w, .One_Name, asm_.oi, toks, nil, strings.concatenate({oid, "/", from, " -> ", x, " | ", y}, context.temp_allocator), a, asm_, b, bsm)
			stat_add(w, STAT_TM_NAMES)
		}
	case 4:
		for d in dirs {
			if _kind(a, _abs(asm_, d)) != .Dir || _kind(b, _abs(bsm, d)) != .Dir {
				return
			}
		}
		ra := _rename(w, a, asm_, dirs[0], strings.concatenate({dirs[1], "/", dirs[0]}, context.temp_allocator))
		context = instance_context(&b.inst)
		rb := ra && b.alive && _rename(w, b, bsm, dirs[1], strings.concatenate({dirs[0], "/", dirs[1]}, context.temp_allocator))
		context = instance_context(&a.inst)
		if ra && rb {
			stat_add(w, STAT_TM_CYCLE)
		}
	case 5:
		for d in dirs {
			if _kind(a, _abs(asm_, d)) != .Dir || _kind(b, _abs(bsm, d)) != .Dir {
				return
			}
		}
		from, from_ok := _dir_file(w, a, asm_, dirs[0], b, bsm)
		if !from_ok {
			return
		}
		to, to_ok := _free_name(w, a, asm_, b, bsm, "", dirs[1])
		if !to_ok {
			return
		}
		if !_rename(w, a, asm_, from, to) {
			return
		}
		context = instance_context(&b.inst)
		if b.alive {
			_rmtree(w, b, bsm, dirs[rng_int(&w.rng, len(dirs))])
		}
		context = instance_context(&a.inst)
		stat_add(w, STAT_TM_REMOVE)
	case 6:
		from, from_ok := _root_file(w, a, asm_, b, bsm)
		if !from_ok {
			return
		}
		to: string
		if _kind(a, _abs(asm_, dirs[0])) == .Dir && rng_chance(&w.rng, 1, 2) {
			to_v, to_ok := _free_name(w, a, asm_, nil, {}, "", dirs[0])
			if !to_ok {
				return
			}
			to = to_v
		} else {
			to_v, to_ok := _free_name(w, a, asm_, b, bsm, from)
			if !to_ok {
				return
			}
			to = to_v
		}
		toks := _common(_tokens(a, _abs(asm_, from)), _tokens(b, _abs(bsm, from)))
		if len(toks) == 0 || !_rename(w, a, asm_, from, to) {
			return
		}
		context = instance_context(&b.inst)
		eop: ^M_Op
		eok := false
		if b.alive {
			eop, eok = _write(w, b, bsm, from, true, 1)
		}
		context = instance_context(&a.inst)
		if eok {
			_record(w, .Edit_Follows, asm_.oi, toks, eop.tokens[:], strings.concatenate({oid, "/", from, " -> ", to}, context.temp_allocator), a, asm_, b, bsm)
			stat_add(w, STAT_TM_EDIT)
		}
	case 7:
		target, target_ok := _root_file(w, a, asm_, b, bsm)
		if !target_ok {
			return
		}
		src, src_ok := _root_file(w, a, asm_, b, bsm)
		if !src_ok {
			return
		}
		if src == target {
			return
		}
		toks := _tokens(a, _abs(asm_, src))
		if len(toks) == 0 || !_rename(w, a, asm_, src, target) {
			return
		}
		context = instance_context(&b.inst)
		eop: ^M_Op
		eok := false
		if b.alive {
			eop, eok = _write(w, b, bsm, target, true, 1)
		}
		context = instance_context(&a.inst)
		if eok {
			_record(w, .Replaced_Edit, asm_.oi, toks, eop.tokens[:], strings.concatenate({oid, "/", src, " onto ", target}, context.temp_allocator), a, asm_, b, bsm)
			stat_add(w, STAT_TM_REPLACE)
		}
	}
}

@(private = "file")
_gone :: proc(m: ^Model, oi: int, toks: []string) -> bool {
	for op in m.ops {
		if op.obj != oi || !op_maybe(op) {
			continue
		}
		for d in op.deletes {
			for t in toks {
				if d == t {
					return true
				}
			}
		}
	}
	return false
}

@(private = "file")
_holders :: proc(files: map[string][]string, toks: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for f, have in files {
		hit := false
		for t in have {
			for x in toks {
				hit ||= t == x
			}
		}
		if hit {
			append(&out, f)
		}
	}
	return out[:]
}

@(private = "file")
_uncarried :: proc(m: ^Model, r: Tm_Record, files: map[string][]string, held: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for f in held {
		carried := false
		for op in m.ops[min(r.ops, len(m.ops)):] {
			if op.kind != .Disk_Agent || op.obj != r.obj || op.path != f {
				continue
			}
			for t in files[f] {
				for x in op.tokens {
					carried ||= t == x
				}
			}
		}
		if !carried {
			append(&out, f)
		}
	}
	return out[:]
}

@(private = "file")
_files :: proc(n: ^Node, o: eng.Object, line: string) -> map[string][]string {
	out := make(map[string][]string, context.temp_allocator)
	files, _ := tree_walk(n, o, {}, line_eng(line))
	for f in files {
		data, err := eng.tree_read(&n.e, o, f, context.temp_allocator, {}, line_eng(line))
		if err != .None {
			continue
		}
		toks := make([dynamic]string, context.temp_allocator)
		for t in parse_tokens(data) {
			append(&toks, t.text)
		}
		out[f] = toks[:]
	}
	return out
}

@(private = "file")
_authors_kept :: proc(w: ^World, n: ^Node, oi: int, file: string, toks: []string, what: string, line: string) {
	m := &w.model
	o := m.objs[oi].o
	data, err := eng.tree_read(&n.e, o, file, context.temp_allocator, {}, line_eng(line))
	if err != .None {
		return
	}
	_, raw, _ := eng.tree_blame(&n.e, o, file, context.temp_allocator, line_eng(line))
	spans := make([]crdt_span, len(raw), context.temp_allocator)
	for x, i in raw {
		spans[i] = crdt_span{actor = x.id.actor, len = x.len}
	}
	for t in parse_tokens(data) {
		want := false
		for x in toks {
			want ||= x == t.text
		}
		if !want {
			continue
		}
		op := _token_op(m, oi, t.text)
		if op == nil || op.power_crash {
			continue
		}
		at := 0
		for sp in spans {
			lo := max(at, t.pos)
			hi := min(at + sp.len, t.pos + len(t.text))
			if lo < hi && sp.actor != op.actor && !fs.is_unattributed(sp.actor) {
				world_fail(w, "tree move: token %s moved by a rename onto an existing name (%s) is credited to %s, not its writer %s, on %s", t.text, what, id_short(sp.actor), id_short(op.actor), n.name)
				return
			}
			at += sp.len
		}
	}
}

check_tree_moves :: proc(w: ^World) {
	if _tm == nil || len(_tm.records) == 0 {
		return
	}
	m := &w.model
	for n in w.nodes {
		if !n.alive {
			continue
		}
		context = instance_context(&n.inst)
		seen := make(map[string]map[string][]string, context.temp_allocator)
		for r in _tm.records {
			if _gone(m, r.obj, r.file[:]) || _gone(m, r.obj, r.other[:]) {
				continue
			}
			key := fmt.tprintf("%d|%s", r.obj, r.line)
			files, ok := seen[key]
			if !ok {
				files = _files(n, m.objs[r.obj].o, r.line)
				seen[key] = files
			}
			held := _holders(files, r.file[:])
			switch r.kind {
			case .One_Name:
				held = _uncarried(m, r, files, held)
				if len(held) > 1 {
					world_fail(w, "tree move: a file moved concurrently (%s) is in %d files on %s: %v", r.what, len(held), n.name, held)
				}
			case .Edit_Follows:
				edit := _holders(files, r.other[:])
				if len(held) == 1 && len(edit) == 1 && held[0] != edit[0] {
					world_fail(w, "tree move: an edit concurrent with a move (%s) landed in %s, not in the moved file %s, on %s", r.what, edit[0], held[0], n.name)
				}
			case .Replaced_Edit:
				edit := _holders(files, r.other[:])
				if len(held) == 1 && (len(edit) != 1 || edit[0] != held[0]) {
					world_fail(w, "tree move: an edit of a file replaced by a rename (%s) did not merge into the file that replaced it, %s, on %s (edit in %v)", r.what, held[0], n.name, edit)
				}
				if len(held) == 1 {
					_authors_kept(w, n, r.obj, held[0], r.file[:], r.what, r.line)
				}
			}
		}
		node_after(n)
		free_all(context.temp_allocator)
	}
}
