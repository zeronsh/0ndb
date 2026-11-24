package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/obj"
import "../../src/prim"

RS_ROOT :: "/home/sim/shapes"

@(private = "file")
RS_CASES :: #load("revert_shapes.cases", string)

@(private = "file")
Rs_Kind :: enum u8 {
	File,
	Dir,
	Link,
}

@(private = "file")
Rs_Entry :: struct {
	kind:   Rs_Kind,
	data:   string,
	exec:   bool,
	target: string,
}

@(private = "file")
Rs_Tree :: map[string]Rs_Entry

@(private = "file")
Rs_Op :: struct {
	verb: string,
	args: []string,
}

@(private = "file")
Rs_Case :: struct {
	name:  string,
	setup: []string,
	ops:   []Rs_Op,
	undo:  [][2]string,
	offer: []string,
	known: string,
}

@(private = "file")
Rs_Ctx :: struct {
	w:     ^World,
	n:     ^Node,
	vfs:   prim.Vfs,
	tree:  eng.Object,
	conv:  eng.Object,
	agent: prim.Id,
	alloc: runtime.Allocator,
}

@(private = "file")
_rs_all :: proc() -> bool {
	return env_u64("SHAPES_ALL", 0) != 0
}

@(private = "file")
_rs_big :: proc(n: int, alloc: runtime.Allocator) -> string {
	b := strings.builder_make(alloc)
	for i := 0; strings.builder_len(b) < n; i += 1 {
		fmt.sbprintf(&b, "%07d\n", i)
	}
	return strings.to_string(b)[:n]
}

@(private = "file")
_rs_bin :: proc(n: int, alloc: runtime.Allocator) -> string {
	b := make([]u8, n, alloc)
	for i in 0 ..< n {
		b[i] = u8(i % 256)
	}
	return string(b)
}

@(private = "file")
_rs_text :: proc(v: string, alloc: runtime.Allocator) -> string {
	if v == `""` {
		return ""
	}
	if len(v) >= 4 {
		if n, ok := strconv.parse_int(v); ok {
			return _rs_big(n, alloc)
		}
	}
	u, _ := strings.replace_all(v, "\\n", "\n", alloc)
	return strings.concatenate({u, "\n"}, alloc)
}

@(private = "file")
_rs_cases :: proc(alloc: runtime.Allocator) -> []Rs_Case {
	out := make([dynamic]Rs_Case, alloc)
	for line in strings.split_lines(RS_CASES, alloc) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' {
			continue
		}
		f := strings.split(l, "|", alloc)
		if len(f) < 3 {
			continue
		}
		c := Rs_Case{name = strings.trim_space(f[0])}
		c.setup = strings.fields(f[1], alloc)
		ops := make([dynamic]Rs_Op, alloc)
		for o in strings.split(f[2], ";", alloc) {
			w := strings.fields(o, alloc)
			if len(w) == 0 {
				continue
			}
			append(&ops, Rs_Op{verb = w[0], args = w[1:]})
		}
		c.ops = ops[:]
		undo := make([dynamic][2]string, alloc)
		offer := make([dynamic]string, alloc)
		for w in strings.fields(f[3] if len(f) > 3 else "", alloc) {
			if strings.has_prefix(w, "undo:") {
				eq := strings.index_byte(w, '=')
				append(&undo, [2]string{w[len("undo:"):eq], w[eq + 1:]})
			} else if strings.has_prefix(w, "offer:") {
				append(&offer, w[len("offer:"):])
			} else if strings.has_prefix(w, "known:") {
				c.known = w[len("known:"):]
			}
		}
		c.undo = undo[:]
		c.offer = offer[:]
		append(&out, c)
	}
	return out[:]
}

@(private = "file")
_rs_parents :: proc(t: ^Rs_Tree, path: string) {
	for i := 0; i < len(path); i += 1 {
		if path[i] == '/' {
			t[path[:i]] = Rs_Entry{kind = .Dir}
		}
	}
}

@(private = "file")
_rs_setup_model :: proc(c: Rs_Case, alloc: runtime.Allocator) -> Rs_Tree {
	t := make(Rs_Tree, alloc)
	for s in c.setup {
		if i := strings.index(s, "->"); i > 0 {
			_rs_parents(&t, s[:i])
			t[s[:i]] = Rs_Entry{kind = .Link, target = s[i + 2:]}
			continue
		}
		eq := strings.index_byte(s, '=')
		if eq < 0 {
			continue
		}
		p, v := s[:eq], s[eq + 1:]
		if strings.has_suffix(p, "/") {
			_rs_parents(&t, p[:len(p) - 1])
			t[p[:len(p) - 1]] = Rs_Entry{kind = .Dir}
			continue
		}
		exec := strings.has_suffix(v, "+x")
		if exec {
			v = v[:len(v) - 2]
		}
		_rs_parents(&t, p)
		t[p] = Rs_Entry{kind = .File, data = _rs_text(v, alloc), exec = exec}
	}
	return t
}

@(private = "file")
_rs_under :: proc(p, root: string) -> bool {
	return p == root || (len(p) > len(root) && strings.has_prefix(p, root) && p[len(root)] == '/')
}

@(private = "file")
_rs_apply :: proc(t: ^Rs_Tree, op: Rs_Op, alloc: runtime.Allocator) {
	a := op.args
	switch op.verb {
	case "write", "person":
		text := strings.join(a[1:], " ", alloc) if len(a) > 1 else `""`
		_rs_parents(t, a[0])
		old := t[a[0]] or_else {}
		t[a[0]] = Rs_Entry{kind = .File, data = _rs_text(text, alloc), exec = old.kind == .File && old.exec}
	case "write_bin":
		n, _ := strconv.parse_int(a[1])
		_rs_parents(t, a[0])
		t[a[0]] = Rs_Entry{kind = .File, data = _rs_bin(n, alloc)}
	case "write_big":
		n, _ := strconv.parse_int(a[1])
		_rs_parents(t, a[0])
		t[a[0]] = Rs_Entry{kind = .File, data = _rs_big(n, alloc)}
	case "mkdir":
		_rs_parents(t, a[0])
		t[a[0]] = Rs_Entry{kind = .Dir}
	case "rm", "rmdir":
		delete_key(t, a[0])
	case "rmtree":
		for k in prim.sorted_keys(t^) {
			if _rs_under(k, a[0]) {
				delete_key(t, k)
			}
		}
	case "mv":
		moved := make([dynamic][2]string, context.temp_allocator)
		for k in prim.sorted_keys(t^) {
			if _rs_under(k, a[0]) {
				append(&moved, [2]string{k, strings.concatenate({a[1], k[len(a[0]):]}, alloc)})
			}
		}
		saved := make([]Rs_Entry, len(moved), context.temp_allocator)
		for x, i in moved {
			saved[i] = t[x[0]]
			delete_key(t, x[0])
		}
		for x, i in moved {
			t[x[1]] = saved[i]
		}
	case "chmod_x", "chmod_nx":
		if e, ok := &t[a[0]]; ok {
			e.exec = op.verb == "chmod_x"
		}
	case "ln_s":
		_rs_parents(t, a[1])
		t[a[1]] = Rs_Entry{kind = .Link, target = a[0]}
	}
}

@(private = "file")
_rs_abs :: proc(rel: string) -> string {
	return strings.concatenate({RS_ROOT, "/", rel}, context.temp_allocator)
}

@(private = "file")
_rs_write_file :: proc(vfs: prim.Vfs, rel: string, data: string, exec: bool) -> prim.Error {
	abs := _rs_abs(rel)
	prim.mkdir_all(vfs, prim.dir_name(abs), 0o755) or_return
	fd := prim.open_file(vfs, abs, {.Write, .Create, .Truncate}, 0o755 if exec else 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.fchmod(vfs, fd, 0o755 if exec else 0o644)
	}
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	if err == .None {
		err = cerr
	}
	if err == .None {
		err = prim.sync_dir(vfs, prim.dir_name(abs))
	}
	return err
}

@(private = "file")
_rs_rmtree :: proc(vfs: prim.Vfs, abs: string) -> prim.Error {
	st, serr := prim.lstat(vfs, abs)
	if serr != .None {
		return serr
	}
	if st.kind != .Dir {
		return prim.remove(vfs, abs)
	}
	names := make([dynamic]string, context.temp_allocator)
	d: prim.Dir
	prim.dir_open(vfs, &d, abs, context.temp_allocator) or_return
	for {
		e, more, derr := prim.dir_next(vfs, &d)
		if derr != .None || !more {
			break
		}
		if e.name != "." && e.name != ".." {
			append(&names, strings.clone(e.name, context.temp_allocator))
		}
	}
	prim.dir_close(vfs, &d)
	for nm in names {
		_rs_rmtree(vfs, strings.concatenate({abs, "/", nm}, context.temp_allocator)) or_return
	}
	return prim.remove_dir(vfs, abs)
}

@(private = "file")
_rs_disk_op :: proc(c: ^Rs_Ctx, op: Rs_Op, model: ^Rs_Tree) -> prim.Error {
	a := op.args
	vfs := c.vfs
	switch op.verb {
	case "write", "write_bin", "write_big":
		e := model[a[0]]
		return _rs_write_file(vfs, a[0], e.data, e.exec)
	case "mkdir":
		return prim.mkdir_all(vfs, _rs_abs(a[0]), 0o755)
	case "rm":
		return prim.remove(vfs, _rs_abs(a[0]))
	case "rmdir":
		return prim.remove_dir(vfs, _rs_abs(a[0]))
	case "rmtree":
		return _rs_rmtree(vfs, _rs_abs(a[0]))
	case "mv":
		prim.mkdir_all(vfs, prim.dir_name(_rs_abs(a[1])), 0o755) or_return
		return prim.rename(vfs, _rs_abs(a[0]), _rs_abs(a[1]))
	case "chmod_x", "chmod_nx":
		fd := prim.open_file(vfs, _rs_abs(a[0]), {.Write}) or_return
		err := prim.fchmod(vfs, fd, 0o755 if op.verb == "chmod_x" else 0o644)
		prim.close_file(vfs, fd)
		return err
	case "ln_s":
		prim.mkdir_all(vfs, prim.dir_name(_rs_abs(a[1])), 0o755) or_return
		return prim.symlink(vfs, a[0], _rs_abs(a[1]))
	}
	return .Invalid
}

@(private = "file")
_rs_read :: proc(c: ^Rs_Ctx, alloc: runtime.Allocator) -> Rs_Tree {
	out := make(Rs_Tree, alloc)
	c.n.disk.probe += 1
	defer c.n.disk.probe -= 1
	walk :: proc(c: ^Rs_Ctx, rel: string, out: ^Rs_Tree, alloc: runtime.Allocator) {
		abs := RS_ROOT if rel == "" else _rs_abs(rel)
		names := make([dynamic]string, context.temp_allocator)
		d: prim.Dir
		if prim.dir_open(c.vfs, &d, abs, context.temp_allocator) != .None {
			return
		}
		for {
			e, more, derr := prim.dir_next(c.vfs, &d)
			if derr != .None || !more {
				break
			}
			if e.name != "." && e.name != ".." {
				append(&names, strings.clone(e.name, context.temp_allocator))
			}
		}
		prim.dir_close(c.vfs, &d)
		slice.sort(names[:])
		for nm in names {
			r := strings.concatenate({rel, "/", nm}, alloc) if rel != "" else strings.clone(nm, alloc)
			p := _rs_abs(r)
			st, serr := prim.lstat(c.vfs, p)
			if serr != .None {
				continue
			}
			#partial switch st.kind {
			case .Dir:
				out[r] = Rs_Entry{kind = .Dir}
				walk(c, r, out, alloc)
			case .Symlink:
				buf: [4096]u8
				k, _ := prim.readlink(c.vfs, p, buf[:])
				out[r] = Rs_Entry{kind = .Link, target = strings.clone(string(buf[:max(k, 0)]), alloc)}
			case:
				data, _ := prim.read_file(c.vfs, p, alloc)
				out[r] = Rs_Entry{kind = .File, data = string(data), exec = st.mode & 0o100 != 0}
			}
		}
	}
	walk(c, "", &out, alloc)
	return out
}

@(private = "file")
_rs_show :: proc(e: Rs_Entry) -> string {
	switch e.kind {
	case .Dir:
		return "dir"
	case .Link:
		return fmt.tprintf("link -> %s", e.target)
	case .File:
		d := e.data
		shown := fmt.tprintf("%q", d) if len(d) <= 40 else fmt.tprintf("%d bytes", len(d))
		return fmt.tprintf("file %s%s", shown, " +x" if e.exec else "")
	}
	return "?"
}

@(private = "file")
_rs_diff :: proc(want, got: Rs_Tree) -> string {
	b := strings.builder_make(context.temp_allocator)
	keys := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(want) {
		append(&keys, k)
	}
	for k in prim.sorted_keys(got) {
		if k not_in want {
			append(&keys, k)
		}
	}
	slice.sort(keys[:])
	for k in keys {
		wv, wok := want[k]
		gv, gok := got[k]
		switch {
		case wok && !gok:
			fmt.sbprintf(&b, " missing %s (%s);", k, _rs_show(wv))
		case !wok && gok:
			fmt.sbprintf(&b, " extra %s (%s);", k, _rs_show(gv))
		case wv != gv:
			fmt.sbprintf(&b, " %s is %s, want %s;", k, _rs_show(gv), _rs_show(wv))
		}
	}
	return strings.to_string(b)
}

@(private = "file")
_rs_mount :: proc(c: ^Rs_Ctx) -> ^fs.Mount {
	for &x in c.n.mounts {
		if x.root == RS_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_rs_version :: proc(c: ^Rs_Ctx) -> []u8 {
	m := _rs_mount(c)
	if m == nil {
		return nil
	}
	fs.mount_sync(m)
	vb := make([dynamic]u8, context.temp_allocator)
	fs.encode_version(&vb, fs.mount_synced(m))
	b := make([dynamic]u8, c.alloc)
	pw := prim.writer(&b)
	prim.write_bytes(&pw, vb[:])
	prim.write_str(&pw, "")
	prim.write_str(&pw, "")
	return b[:]
}

@(private = "file")
_rs_msg :: proc(c: ^Rs_Ctx, role: convo.Role, parent: obj.Rid, files: []convo.File_Delta) -> (msg: obj.Rid, ok: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, c.conv)
	if werr != .None {
		world_fail(c.w, "shapes: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = parent, files = files})
	if merr != .None {
		world_fail(c.w, "shapes: writer_message: %v", merr)
		return
	}
	convo.writer_commit(wr)
	return m, true
}

@(private = "file")
_rs_person :: proc(c: ^Rs_Ctx, op: Rs_Op, model: ^Rs_Tree) -> bool {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	if m := _rs_mount(c); m != nil {
		fs.mount_sync(m)
	}
	base: fs.Version
	eng.tree_read(&n.e, c.tree, op.args[0], context.temp_allocator, {}, "", nil, &base)
	if err := eng.tree_write(&n.e, c.tree, op.args[0], transmute([]u8)model[op.args[0]].data, base); err != .None {
		world_fail(c.w, "shapes: person tree_write %s: %v", op.args[0], err)
		return false
	}
	return true
}

@(private = "file")
_rs_agent :: proc(c: ^Rs_Ctx, op: Rs_Op, model: ^Rs_Tree, before: Rs_Tree) -> bool {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _rs_mount(c)
	if m == nil {
		world_fail(c.w, "shapes: mount missing")
		return false
	}
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&c.w.rng))
	scope := fs.scope_open(n.reg, m, sid, c.agent)
	touched := make([dynamic]string, context.temp_allocator)
	for t in ([]Rs_Tree{before, model^}) {
		for k in prim.sorted_keys(t) {
			for a in op.args {
				if _rs_under(k, a) {
					append(&touched, k)
				}
			}
		}
	}
	for a in op.args {
		append(&touched, a)
	}
	for rel in touched {
		abs := _rs_abs(rel)
		if abs not_in n.writers {
			n.writers[strings.clone(abs, c.w.allocator)] = Writer_Info{scope = scope, agent = true}
		}
		fs.mount_observe_begin(m, rel, scope)
	}
	err := _rs_disk_op(c, op, model)
	fs.scope_close(n.reg, scope)
	for rel in touched {
		abs := _rs_abs(rel)
		if abs in n.writers {
			key, _ := delete_key(&n.writers, abs)
			delete(key, c.w.allocator)
		}
	}
	if err != .None {
		world_fail(c.w, "shapes: %s %v: %v", op.verb, op.args, err)
		return false
	}
	return true
}

@(private = "file")
Rs_Run :: struct {
	user:    obj.Rid,
	r0:      obj.Rid,
	base:    obj.Rid,
	pre:     Rs_Tree,
	post:    Rs_Tree,
	undoneq: Rs_Tree,
}

@(private = "file")
_rs_setup :: proc(w: ^World, cs: Rs_Case, alloc: runtime.Allocator) -> (c: ^Rs_Ctx, ok: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "shapes: node start")
		return
	}
	c = new(Rs_Ctx, alloc)
	c^ = Rs_Ctx{w = w, n = n, vfs = disk_vfs(&n.disk), alloc = alloc}
	m := &w.model
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "shapes")
		if err != .None {
			world_fail(w, "shapes: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		c.tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "shapes: tree_create: %v", err)
			return
		}
		c.conv, err = eng.convo_create(&n.e, space, eng.Convo_Settings{title = "shapes"})
		if err != .None {
			world_fail(w, "shapes: convo_create: %v", err)
			return
		}
		if merr := eng.convo_mount(&n.e, c.conv, "work", c.tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "shapes: convo_mount: %v", merr)
			return
		}
		eng.undo_hooks_set(&n.e, eng.Undo_Hooks{})
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	prim.mkdir_all(c.vfs, RS_ROOT, 0o755)
	setup := _rs_setup_model(cs, alloc)
	for k in prim.sorted_keys(setup) {
		e := setup[k]
		switch e.kind {
		case .Dir:
			prim.mkdir_all(c.vfs, _rs_abs(k), 0o755)
		case .File:
			_rs_write_file(c.vfs, k, e.data, e.exec)
		case .Link:
			prim.symlink(c.vfs, e.target, _rs_abs(k))
		}
	}
	if err := node_mount(w, n, oi, RS_ROOT); err != .None {
		world_fail(w, "shapes: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(RS_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	c.agent = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	return c, true
}

@(private = "file")
_rs_turn :: proc(c: ^Rs_Ctx, cs: Rs_Case) -> (r: Rs_Run, ok: bool) {
	w := c.w
	n := c.n
	model := _rs_read(c, c.alloc)
	r.pre = _rs_read(c, c.alloc)
	r.undoneq = _rs_read(c, c.alloc)
	files: []convo.File_Delta
	{
		context = instance_context(&n.inst)
		files = make([]convo.File_Delta, 1, c.alloc)
		files[0] = convo.File_Delta{mount = "work", tree = c.tree.id, version = _rs_version(c)}
		node_after(n)
	}
	r.r0 = _rs_msg(c, .User, {}, nil) or_return
	r0r := _rs_msg(c, .Assistant, r.r0, files) or_return
	{
		context = instance_context(&n.inst)
		if wr, werr := eng.convo_writer(&n.e, c.conv); werr == .None {
			convo.writer_seal(wr, r0r, .Done)
			convo.writer_commit(wr)
		}
		node_after(n)
	}
	r.base = r0r
	r.user = _rs_msg(c, .User, r0r, nil) or_return
	reply := _rs_msg(c, .Assistant, r.user, files) or_return
	last := len(cs.ops)
	for last > 0 && cs.ops[last - 1].verb == "person" {
		last -= 1
	}
	for op in cs.ops[:last] {
		before := make(Rs_Tree, context.temp_allocator)
		for k in prim.sorted_keys(model) {
			before[k] = model[k]
		}
		_rs_apply(&model, op, c.alloc)
		if op.verb == "person" {
			_rs_apply(&r.undoneq, op, c.alloc)
			_rs_person(c, op, &model) or_return
		} else {
			_rs_agent(c, op, &model, before) or_return
		}
		run_until(w, w.now + 500_000_000, true)
	}
	run_until(w, w.now + 1_000_000_000, true)
	{
		context = instance_context(&n.inst)
		if m := _rs_mount(c); m != nil {
			fs.mount_sync(m)
		}
		wr, werr := eng.convo_writer(&n.e, c.conv)
		if werr == .None {
			convo.writer_scope(wr, reply, .Turn, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), c.agent, nil, nil)
			convo.writer_seal(wr, reply, .Done)
			convo.writer_commit(wr)
		}
		node_after(n)
	}
	run_until(w, w.now + 1_000_000_000, true)
	for op in cs.ops[last:] {
		_rs_apply(&model, op, c.alloc)
		_rs_apply(&r.undoneq, op, c.alloc)
		_rs_person(c, op, &model) or_return
		run_until(w, w.now + 1_000_000_000, true)
	}
	for x in cs.undo {
		if x[1] == "-" {
			delete_key(&r.undoneq, x[0])
		} else {
			r.undoneq[x[0]] = Rs_Entry{kind = .File, data = _rs_text(x[1], c.alloc)}
		}
	}
	r.post = model
	got := _rs_read(c, c.alloc)
	if d := _rs_diff(model, got); len(d) > 0 {
		world_fail(w, "shapes %s: after the turn:%s", cs.name, d)
		return r, false
	}
	return r, true
}

@(private = "file")
_rs_strip :: proc(t: ^Rs_Tree) -> string {
	b := strings.builder_make(context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(t^) {
		base := k[strings.last_index_byte(k, '/') + 1:]
		if strings.has_prefix(base, ".0ndb-") {
			append(&names, k)
		}
	}
	for k in names {
		delete_key(t, k)
		fmt.sbprintf(&b, "%s%s", "" if strings.builder_len(b) == 0 else ", ", k)
	}
	return strings.to_string(b)
}

@(private = "file")
_rs_released :: proc(c: ^Rs_Ctx, cs: Rs_Case, undo: prim.Id) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	list, err := eng.convo_undos(&n.e, c.conv, context.temp_allocator)
	if err != .None {
		world_fail(c.w, "shapes %s: convo_undos: %v", cs.name, err)
		return
	}
	for u in list {
		if u.id == undo {
			if u.phase != .Released {
				world_fail(c.w, "shapes %s: the undo stopped at %v, not released", cs.name, u.phase)
			}
			return
		}
	}
	world_fail(c.w, "shapes %s: the undo left no record", cs.name)
}

@(private = "file")
_rs_expect :: proc(c: ^Rs_Ctx, cs: Rs_Case, step: string, want: Rs_Tree) -> bool {
	got := _rs_read(c, c.alloc)
	if d := _rs_diff(want, got); len(d) > 0 {
		b := strings.builder_make(context.temp_allocator)
		if names, werr := tree_walk(c.n, c.tree, {}, "main"); werr == .None {
			for nm in names {
				fmt.sbprintf(&b, " %s", nm)
			}
		} else {
			fmt.sbprintf(&b, " unreadable: %v", werr)
		}
		world_fail(c.w, "shapes %s: after %s:%s the tree holds:%s", cs.name, step, d, strings.to_string(b))
		return false
	}
	return true
}

@(private = "file")
_rs_case :: proc(w: ^World, cs: Rs_Case, alloc: runtime.Allocator) {
	c, cok := _rs_setup(w, cs, alloc)
	if !cok {
		return
	}
	r, tok := _rs_turn(c, cs)
	if !tok {
		return
	}
	n := c.n
	undo: prim.Id
	{
		context = instance_context(&n.inst)
		u, err := eng.convo_undo(&n.e, c.conv, r.user)
		node_after(n)
		if err != .None {
			world_fail(w, "shapes %s: convo_undo: %v", cs.name, err)
			return
		}
		undo = u
	}
	run_until(w, w.now + 5_000_000_000, true)
	_rs_released(c, cs, undo)
	_rs_expect(c, cs, "undo", r.undoneq)
	for path in cs.offer {
		context = instance_context(&n.inst)
		list, err := eng.tree_conflicts(&n.e, c.tree, context.temp_allocator)
		found := false
		for x in list {
			found ||= x.path == path
		}
		if err != .None || !found {
			world_fail(w, "shapes %s: after undo: %s offers nothing back (%v, %d conflicts in the tree)", cs.name, path, err, len(list))
		}
		node_after(n)
	}
	if env_u64("SHAPES_TREE", 0) != 0 {
		context = instance_context(&n.inst)
		names, _ := tree_walk(n, c.tree, {}, "main")
		lst, lerr := eng.tree_list(&n.e, c.tree, "", context.temp_allocator)
		fmt.eprintfln("SHAPES %s tree files after undo: %v; root list %v %v", cs.name, names, lst, lerr)
		node_after(n)
	}
	redo: {
		context = instance_context(&n.inst)
		_, err := eng.convo_redo(&n.e, c.conv, undo)
		node_after(n)
		if err != .None {
			world_fail(w, "shapes %s: convo_redo: %v", cs.name, err)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	_rs_expect(c, cs, "redo", r.post)
	edit: {
		context = instance_context(&n.inst)
		_, err := eng.convo_move(&n.e, c.conv, .Edit, r.base)
		node_after(n)
		if err != .None {
			world_fail(w, "shapes %s: edit move: %v", cs.name, err)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	sib, sok := _rs_msg(c, .User, r.base, nil)
	if !sok {
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	_rs_expect(c, cs, "switch away (an edit of the turn's message)", r.undoneq)
	for step in ([2]obj.Rid{r.user, sib}) {
		{
			context = instance_context(&n.inst)
			_, err := eng.convo_switch(&n.e, c.conv, step)
			node_after(n)
			if err != .None {
				world_fail(w, "shapes %s: convo_switch: %v", cs.name, err)
				return
			}
		}
		run_until(w, w.now + 5_000_000_000, true)
		if step == r.user {
			_rs_expect(c, cs, "switch back to the turn", r.post)
		} else {
			_rs_expect(c, cs, "switch forward to the edit", r.undoneq)
		}
	}
}

Rs_Arm :: enum {
	Power,
	Touch,
	Fault,
}

@(private = "file")
_rs_touch :: proc(c: ^Rs_Ctx) {
	now := _rs_read(c, c.alloc)
	for p in prim.sorted_keys(now) {
		e := now[p]
		if e.kind != .File {
			continue
		}
		fd, oerr := prim.open_file(c.vfs, _rs_abs(p))
		if oerr != .None {
			continue
		}
		prim.fchmod(c.vfs, fd, 0o755 if e.exec else 0o644)
		prim.close_file(c.vfs, fd)
	}
}

@(private = "file")
_rs_crash_case :: proc(w: ^World, cs: Rs_Case, k: u64, arm: Rs_Arm, alloc: runtime.Allocator) -> (crashed: bool) {
	fault := arm == .Fault
	c, cok := _rs_setup(w, cs, alloc)
	if !cok {
		return
	}
	r, tok := _rs_turn(c, cs)
	if !tok {
		return
	}
	n := c.n
	crashes := w.stats.crashes
	if fault {
		n.disk.fail_root = RS_ROOT
		n.disk.fail_nth = k
	} else {
		n.disk.crash_at = n.disk.stats.ops + k
		n.disk.force_process = arm != .Power
		n.disk.force_power = arm == .Power
	}
	undo: prim.Id
	start: {
		context = instance_context(&n.inst)
		u, err := eng.convo_undo(&n.e, c.conv, r.user)
		node_after(n)
		if err == .None {
			undo = u
		}
	}
	if fault {
		run_until(w, w.now + 100_000_000, true)
		failed := n.disk.fail_nth == 0
		n.disk.fail_nth = 0
		n.disk.fail_root = ""
		if failed && n.alive {
			node_crash_now(n, .Power, k)
		}
	}
	if arm == .Touch {
		at := w.now
		for i := 0; i < 4000 && w.stats.crashes == crashes; i += 1 {
			at += 5_000_000
			run_until(w, at, true)
		}
		if w.stats.crashes > crashes {
			_rs_touch(c)
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	n.disk.force_power = false
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "shapes %s: after a crash at disk op %d the node did not come back", cs.name, k)
		return
	}
	if !crashed {
		if undo != {} {
			_rs_expect(c, cs, "undo", r.undoneq)
		}
		return
	}
	got := _rs_read(c, c.alloc)
	if left := _rs_strip(&got); len(left) > 0 && _rs_all() {
		world_fail(w, "shapes %s: LEFT after a crash at disk op %d: %s", cs.name, k, left)
	}
	if len(_rs_diff(r.undoneq, got)) > 0 && len(_rs_diff(r.post, got)) > 0 {
		world_fail(w, "shapes %s: MIX after a crash at disk op %d: against undone:%s against post:%s", cs.name, k, _rs_diff(r.undoneq, got), _rs_diff(r.post, got))
		return
	}
	resume: {
		context = instance_context(&n.inst)
		eng.undo_hooks_set(&n.e, eng.Undo_Hooks{})
		list, err := eng.convo_undos(&n.e, c.conv, context.temp_allocator)
		driven := err != .None
		for u in list {
			if u.phase != .Released {
				derr := eng.convo_undo_drive(&n.e, c.conv, u.id)
				if derr != .None {
					world_fail(w, "shapes %s: resume after a crash at disk op %d: %v", cs.name, k, derr)
				}
				driven = true
			}
		}
		if !driven {
			if _, uerr := eng.convo_undo(&n.e, c.conv, r.user); uerr != .None {
				world_fail(w, "shapes %s: undo again after a crash at disk op %d: %v", cs.name, k, uerr)
			}
		}
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	fin := _rs_read(c, c.alloc)
	_rs_strip(&fin)
	if len(_rs_diff(r.undoneq, fin)) > 0 {
		world_fail(w, "shapes %s: RESUME after a crash at disk op %d:%s", cs.name, k, _rs_diff(r.undoneq, fin))
	}
	return
}

revert_shapes_crash_run :: proc(seed: u64, only: string, stride: u64, limit: u64, arm: Rs_Arm) -> (failures: [dynamic]string, points: int) {
	failures = make([dynamic]string)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 20) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	for cs in _rs_cases(virtual.arena_allocator(&arena)) {
		if len(only) > 0 && cs.name != only || len(only) == 0 && len(cs.known) > 0 && !_rs_all() {
			continue
		}
		for k := env_u64("SHAPES_FROM", 1); k <= limit; k += stride {
			cfg := default_config(seed + k if arm == .Touch else seed)
			cfg.nodes = 1
			cfg.spaces = 0
			cfg.ops = 0
			cfg.crash_rate = 0
			cfg.fault_rate = 0
			cfg.io_rate = 0
			cfg.byzantine = false
			cfg.bulk = false
			cfg.mem_max = 1500
			cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
			w := new(World)
			world_init(w, cfg)
			ca: virtual.Arena
			crashed := false
			if virtual.arena_init_growing(&ca, 1 << 20) == nil {
				crashed = _rs_crash_case(w, cs, k, arm, virtual.arena_allocator(&ca))
				virtual.arena_destroy(&ca)
			}
			for f in w.failures {
				append(&failures, fmt.aprintf("%s at %d: %s", cs.name, k, f))
			}
			world_destroy(w)
			free(w)
			if !crashed {
				break
			}
			points += 1
		}
	}
	return
}

revert_shapes_run :: proc(seed: u64, only: string = "") -> (failures: [dynamic]string, cases: int) {
	failures = make([dynamic]string)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 20) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	list := _rs_cases(virtual.arena_allocator(&arena))
	for cs in list {
		if len(only) > 0 && cs.name != only || len(only) == 0 && cs.known == "revert" && !_rs_all() {
			continue
		}
		cases += 1
		cfg := default_config(seed)
		cfg.nodes = 1
		cfg.spaces = 0
		cfg.ops = 0
		cfg.crash_rate = 0
		cfg.fault_rate = 0
		cfg.io_rate = 0
		cfg.byzantine = false
		cfg.bulk = false
		cfg.mem_max = 1500
		cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
		w := new(World)
		world_init(w, cfg)
		ca: virtual.Arena
		if virtual.arena_init_growing(&ca, 1 << 20) == nil {
			_rs_case(w, cs, virtual.arena_allocator(&ca))
			virtual.arena_destroy(&ca)
		}
		for f in w.failures {
			append(&failures, fmt.aprintf("%s", f))
		}
		world_destroy(w)
		free(w)
	}
	return
}

@(test)
revert_shapes :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	only, _ := os.lookup_env("SHAPES_ONLY", context.allocator)
	defer delete(only)
	failures, cases := revert_shapes_run(1, only)
	for f in failures {
		fmt.eprintf("revert_shapes: %s\n", f)
		delete(f)
	}
	fmt.eprintf("revert_shapes: %d cases, %d failures\n", cases, len(failures))
	testing.expect(t, cases > 0, "revert_shapes: no case ran")
	testing.expect(t, len(failures) == 0, "revert_shapes failed")
	delete(failures)
}

@(test)
revert_shapes_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	only, _ := os.lookup_env("SHAPES_ONLY", context.allocator)
	defer delete(only)
	for arm in Rs_Arm {
		_rs_sweep(t, only, arm)
	}
}

@(private = "file")
_rs_sweep :: proc(t: ^testing.T, only: string, arm: Rs_Arm) {
	failures, points := revert_shapes_crash_run(1, only, env_u64("SHAPES_STRIDE", 11 if arm == .Fault else 37), env_u64("SHAPES_LIMIT", 4000), arm)
	for f, i in failures {
		if u64(i) < env_u64("SHAPES_PRINT", 40) {
			fmt.eprintf("revert_shapes_crash: %v %s\n", arm, f)
		}
		delete(f)
	}
	fmt.eprintf("revert_shapes_crash: %v %d points, %d failures\n", arm, points, len(failures))
	testing.expect(t, points > 0, "revert_shapes_crash: nothing crashed")
	testing.expect(t, len(failures) == 0, "revert_shapes_crash failed")
	delete(failures)
}
