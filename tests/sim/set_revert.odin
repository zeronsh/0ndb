package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fshist"
import "../../src/prim"

SR_ROOT :: "/work/setrev-n0"

@(private = "file")
Sr_Who :: enum u8 {
	Base,
	In,
	B,
	P,
}

@(private = "file")
Sr_Model :: struct {
	files:    map[string][dynamic]string,
	class:    map[string]Sr_Who,
	deleted:  map[string]bit_set[Sr_Who],
	region:   map[string]bool,
	created:  map[string]Sr_Who,
	out_body: map[string]bool,
	removed:  map[string]Sr_Who,
	tok_file: map[string]string,
	in_file_at_remove: map[string]string,
	tok:      int,
	alloc:    runtime.Allocator,
}

@(private = "file")
Sr_Ctx :: struct {
	w:     ^World,
	n:     ^Node,
	sm:    ^Sim_Mount,
	tree:  eng.Object,
	vfs:   prim.Vfs,
	model: Sr_Model,
	actor: [Sr_Who]prim.Id,
	tag:   u8,
	engine: bool,
}

@(private = "file")
_sr_model_init :: proc(md: ^Sr_Model, alloc: runtime.Allocator) {
	md.alloc = alloc
	md.files = make(map[string][dynamic]string, alloc)
	md.class = make(map[string]Sr_Who, alloc)
	md.deleted = make(map[string]bit_set[Sr_Who], alloc)
	md.region = make(map[string]bool, alloc)
	md.created = make(map[string]Sr_Who, alloc)
	md.out_body = make(map[string]bool, alloc)
	md.removed = make(map[string]Sr_Who, alloc)
	md.tok_file = make(map[string]string, alloc)
	md.in_file_at_remove = make(map[string]string, alloc)
}

@(private = "file")
_sr_rebase :: proc(c: ^Sr_Ctx) {
	old := c.model.files
	tok := c.model.tok
	_sr_model_init(&c.model, c.model.alloc)
	c.model.tok = tok
	for name in prim.sorted_keys(old) {
		if name not_in old {
			continue
		}
		lines := old[name]
		l := make([dynamic]string, c.model.alloc)
		for t in lines {
			append(&l, t)
			c.model.class[t] = .Base
			c.model.tok_file[t] = name
		}
		c.model.files[name] = l
	}
}

@(private = "file")
_sr_content :: proc(lines: []string) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for t in lines {
		strings.write_string(&b, t)
		strings.write_byte(&b, '\n')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
_sr_new_token :: proc(c: ^Sr_Ctx, who: Sr_Who) -> string {
	c.model.tok += 1
	letters := "abip"
	letter := letters[int(who)]
	t := fmt.aprintf("<%c%c%d>", rune(c.tag), rune(letter), c.model.tok, allocator = c.model.alloc)
	c.model.class[t] = who
	return t
}

@(private = "file")
_sr_names :: proc(c: ^Sr_Ctx) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(c.model.files) {
		append(&names, k)
	}
	slice.sort(names[:])
	return names[:]
}

@(private = "file")
_sr_write :: proc(c: ^Sr_Ctx, who: Sr_Who, name: string, lines: []string, remove := false) -> bool {
	n := c.n
	world_note(c.w, "set revert edit by %v: %s %s -> %v", who, "remove" if remove else "write", name, lines)
	abs := strings.concatenate({SR_ROOT, "/", name}, context.temp_allocator)
	context = instance_context(&n.inst)
	defer node_after(n)
	scope: ^fs.Scope
	if who != .P {
		sid := prim.id_new_with(node_clock(&n.clock), rng_random(&c.w.rng))
		scope = sim_scope_open(c.w, n.reg, c.sm.m, sid, c.actor[who])
		if abs in n.writers {
			n.writers[abs] = Writer_Info{scope = scope, agent = true}
		} else {
			n.writers[strings.clone(abs, c.w.allocator)] = Writer_Info{scope = scope, agent = true}
		}
		if prim.exists(c.vfs, abs) {
			fs.mount_observe_begin(c.sm.m, name, scope)
		}
	}
	err: prim.Error
	if remove {
		err = prim.remove(c.vfs, abs)
		if err == .None {
			err = prim.sync_dir(c.vfs, SR_ROOT)
		}
	} else {
		err = _sr_disk_write(c.vfs, abs, _sr_content(lines))
	}
	if scope != nil {
		fs.scope_close(n.reg, scope)
		if abs in n.writers {
			key, _ := delete_key(&n.writers, abs)
			delete(key, c.w.allocator)
		}
	} else {
		fs.mount_sync(c.sm.m)
	}
	return err == .None && !n.disk.dead
}

@(private = "file")
_sr_disk_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	if err == .None {
		err = cerr
	}
	if err == .None {
		err = prim.sync_dir(vfs, prim.dir_name(path))
	}
	return err
}

@(private = "file")
_sr_edit :: proc(c: ^Sr_Ctx, inset: Sr_Who) -> bool {
	r := &c.w.rng
	md := &c.model
	who := Sr_Who.B
	switch rng_int(r, 5) {
	case 0, 1:
		who = inset
	case 2:
		who = .P
	}
	cls := who
	names := _sr_names(c)
	kind := rng_int(r, 10)
	if len(names) == 0 || kind == 9 {
		name := fmt.aprintf("n%d.txt", md.tok + 1, allocator = md.alloc)
		lines := make([dynamic]string, md.alloc)
		for _ in 0 ..< 1 + rng_int(r, 2) {
			append(&lines, _sr_new_token(c, cls))
		}
		md.files[name] = lines
		md.created[name] = cls
		for t in lines {
			md.tok_file[t] = name
		}
		return _sr_write(c, who, name, lines[:])
	}
	name := names[rng_int(r, len(names))]
	lines := &md.files[name]
	if made, has := md.created[name]; kind == 8 && len(names) > 1 && !(has && made == .In && cls == .In) {
		for t in lines {
			md.in_file_at_remove[t] = name
		}
		if cls != .In {
			if cr, ok := md.created[name]; ok && cr == .In {
				md.out_body[name] = true
			}
		}
		md.removed[name] = cls
		delete_key(&md.files, name)
		return _sr_write(c, who, name, nil, true)
	}
	if cls != .In {
		if cr, ok := md.created[name]; ok && cr == .In {
			md.out_body[name] = true
		}
	}
	switch {
	case kind <= 2 || len(lines) == 0:
		append(lines, _sr_new_token(c, cls))
	case kind <= 4:
		at := rng_int(r, len(lines) + 1)
		inject_at(lines, at, _sr_new_token(c, cls))
	case kind <= 6:
		at := rng_int(r, len(lines))
		old := lines[at]
		md.deleted[old] += {cls}
		t := _sr_new_token(c, cls)
		if cls != .In && md.class[old] == .In {
			md.region[t] = true
		}
		lines[at] = t
	case:
		at := rng_int(r, len(lines))
		md.deleted[lines[at]] += {cls}
		ordered_remove(lines, at)
	}
	for t in lines {
		if _, has := md.tok_file[t]; !has {
			md.tok_file[t] = name
		}
	}
	return _sr_write(c, who, name, lines[:])
}

@(private = "file")
_sr_disk :: proc(c: ^Sr_Ctx) -> map[string]string {
	out := make(map[string]string, c.model.alloc)
	n := c.n
	n.disk.probe += 1
	defer n.disk.probe -= 1
	names := make([dynamic]string, context.temp_allocator)
	d: prim.Dir
	if prim.dir_open(c.vfs, &d, SR_ROOT, context.temp_allocator) != .None {
		return out
	}
	for {
		e, more, derr := prim.dir_next(c.vfs, &d)
		if derr != .None || !more {
			break
		}
		append(&names, strings.clone(e.name, context.temp_allocator))
	}
	prim.dir_close(c.vfs, &d)
	for nm in names {
		if strings.has_prefix(nm, ".") {
			continue
		}
		data, rerr := prim.read_file(c.vfs, strings.concatenate({SR_ROOT, "/", nm}, context.temp_allocator), c.model.alloc)
		if rerr == .None {
			out[strings.clone(nm, c.model.alloc)] = string(data)
		}
	}
	return out
}

@(private = "file")
_sr_check :: proc(c: ^Sr_Ctx, revert: prim.Id, phase: string) {
	w := c.w
	md := &c.model
	disk := _sr_disk(c)
	present := make(map[string]string, context.temp_allocator)
	for name, data in disk {
		rest := data
		for line in strings.split_lines_iterator(&rest) {
			if len(line) == 0 {
				continue
			}
			if _, known := md.class[line]; !known {
				world_fail(w, "set revert %s: %s holds %q, which is not a whole token anybody wrote", phase, name, line)
				continue
			}
			if prev, twice := present[line]; twice {
				world_fail(w, "set revert %s: token %s appears in both %s and %s", phase, line, prev, name)
			}
			present[line] = name
		}
	}
	visible := make(map[string]string, context.temp_allocator)
	for name in prim.sorted_keys(md.files) {
		lines := md.files[name]
		for t in lines {
			visible[t] = name
		}
	}
	for t in prim.sorted_keys(md.class) {
		if t not_in md.class {
			continue
		}
		cls := md.class[t]
		_, now := present[t]
		_, before := visible[t]
		if f, ok := md.in_file_at_remove[t]; ok && !before {
			if rm, rok := md.removed[f]; rok && rm == .In {
				before = true
				visible[t] = f
			}
		}
		d := md.deleted[t]
		in_file := visible[t] if before else ""
		gone_file := false
		if before {
			if cr, ok := md.created[in_file]; ok && cr == .In {
				gone_file = true
			}
		}
		file := md.tok_file[t]
		_, alive := md.files[file]
		if cr, ok := md.created[file]; ok && cr == .In {
			alive = false
		}
		if rm, ok := md.removed[file]; ok && rm == .In {
			alive = true
		}
		want: bool
		switch {
		case cls == .In:
			want = false
		case gone_file || !alive:
			want = false
		case md.region[t] && before:
			want = false
		case before:
			want = true
		case:
			want = .In in d && d - {.In} == {}
		}
		if before && !now && md.region[t] {
			continue
		}
		if want != now {
			if !want && now && !before {
				world_fail(w, "set revert %s: token %s (%v, deleted by %v) came back", phase, t, cls, d)
			} else if want && !now {
				world_fail(w, "set revert %s: token %s (%v, deleted by %v, visible before %v) is missing", phase, t, cls, d, before)
			} else {
				world_fail(w, "set revert %s: token %s (%v, deleted by %v, visible before %v) is still present", phase, t, cls, d, before)
			}
		}
	}
	if revert == {} {
		return
	}
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	op, err := fs.history_revert_op(c.sm.m.history, revert, context.temp_allocator)
	if err != .None {
		world_fail(w, "set revert %s: cannot read the revert marker: %v", phase, err)
		return
	}
	regions, files := 0, 0
	for x in op.conflicts {
		#partial switch x.kind {
		case .Region:
			regions += 1
		case .File:
			files += 1
		}
	}
	want_regions := 0
	for t in md.region {
		if _, before := visible[t]; before {
			if cr, ok := md.created[visible[t]]; !ok || cr != .In {
				want_regions += 1
			}
		}
	}
	want_files := 0
	for name in md.out_body {
		if _, still := md.files[name]; still {
			want_files += 1
		}
	}
	if regions != want_regions || files != want_files {
		world_fail(w, "set revert %s: %d region and %d file conflicts, want %d and %d", phase, regions, files, want_regions, want_files)
	}
	_ = fshist.Revert_Conflict_Kind.Region
	listed := _sr_listed(c)
	if listed != len(op.conflicts) {
		world_fail(w, "set revert %s: tree_conflicts lists %d revert conflicts, the marker holds %d", phase, listed, len(op.conflicts))
	}
}

@(private = "file")
_sr_listed :: proc(c: ^Sr_Ctx) -> int {
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	list, err := eng.tree_conflicts(&c.n.e, c.tree, context.temp_allocator)
	if err != .None {
		world_fail(c.w, "set revert: tree_conflicts: %v", err)
		return -1
	}
	k := 0
	for x in list {
		if x.kind == .Revert {
			k += 1
		}
	}
	return k
}

@(private = "file")
_sr_accept :: proc(c: ^Sr_Ctx, phase: string) {
	w := c.w
	before := _sr_listed(c)
	if before <= 0 {
		return
	}
	pick: eng.Tree_Conflict
	ok := false
	{
		context = instance_context(&c.n.inst)
		defer node_after(c.n)
		list, err := eng.tree_conflicts(&c.n.e, c.tree, context.temp_allocator)
		if err != .None {
			return
		}
		for x in list {
			if x.kind == .Revert {
				pick = x
				pick.path = strings.clone(x.path, c.model.alloc)
				pick.theirs = slice.clone(x.theirs, c.model.alloc)
				ok = true
				break
			}
		}
		if !ok {
			return
		}
		if aerr := eng.tree_conflict_accept(&c.n.e, c.tree, pick); aerr != .None {
			world_fail(w, "set revert %s: accepting a revert conflict failed: %v", phase, aerr)
			return
		}
	}
	run_until(w, w.now + 2_000_000_000, true)
	_sr_synced(c)
	if after := _sr_listed(c); after != before - 1 {
		world_fail(w, "set revert %s: %d revert conflicts listed after an accept, want %d", phase, after, before - 1)
	}
	if pick.raw.oid != {} || len(pick.path) == 0 {
		return
	}
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	_, raw, berr := eng.tree_blame(&c.n.e, c.tree, pick.path, context.temp_allocator)
	if berr != .None {
		world_fail(w, "set revert %s: blame of %s after an accept: %v", phase, pick.path, berr)
		return
	}
	for t in pick.theirs {
		for k in 0 ..< t.len {
			seq := t.id.seq + u64(k)
			back := false
			for x in raw {
				if x.id.actor == t.id.actor && x.id.seq <= seq && seq < x.id.seq + u64(x.len) {
					back = true
					break
				}
			}
			if !back {
				world_fail(w, "set revert %s: the accepted alternative's byte %s/%d is not in %s", phase, id_short(t.id.actor), seq, pick.path)
				return
			}
		}
	}
}


@(private = "file")
_sr_setup :: proc(w: ^World, alloc: runtime.Allocator) -> (c: Sr_Ctx, ok: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "set revert: node start")
		return
	}
	c.w = w
	c.n = n
	c.vfs = disk_vfs(&n.disk)
	c.tag = 's'
	_sr_model_init(&c.model, alloc)
	m := &w.model
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "setrev")
		if err != .None {
			world_fail(w, "set revert: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		c.tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "set revert: tree_create: %v", err)
			return
		}
		node_after(n)
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	prim.mkdir_all(c.vfs, SR_ROOT, 0o755)
	for name in ([]string{"a.txt", "b.txt"}) {
		lines := make([dynamic]string, alloc)
		for _ in 0 ..< 3 {
			append(&lines, _sr_new_token(&c, .Base))
		}
		c.model.files[name] = lines
		for t in lines {
			c.model.tok_file[t] = name
		}
		_sr_disk_write(c.vfs, strings.concatenate({SR_ROOT, "/", name}, context.temp_allocator), _sr_content(lines[:]))
	}
	if err := node_mount(w, n, oi, SR_ROOT); err != .None {
		world_fail(w, "set revert: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SR_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	for &x in n.mounts {
		if x.root == SR_ROOT && x.m != nil {
			c.sm = &x
		}
	}
	if c.sm == nil {
		world_fail(w, "set revert: mount missing")
		return
	}
	for who in Sr_Who {
		c.actor[who] = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	}
	return c, true
}

@(private = "file")
_sr_synced :: proc(c: ^Sr_Ctx) -> fs.Version {
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	fs.mount_sync(c.sm.m)
	return slice.clone(fs.mount_synced(c.sm.m), c.model.alloc)
}

@(private = "file")
_sr_revert :: proc(c: ^Sr_Ctx, base: fs.Version, actor: prim.Id) -> (revert: prim.Id, err: fs.Error) {
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	if c.engine {
		fs.mount_sync(c.sm.m)
		r, eerr := eng.tree_revert_set(&c.n.e, c.tree, base, []prim.Id{actor})
		return r, .None if eerr == .None else .Io
	}
	return fs.mount_revert_set(c.sm.m, base, []prim.Id{actor})
}

@(private = "file")
_sr_mount_actors :: proc(c: ^Sr_Ctx) {
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	m := c.sm.m
	got, err := fs.history_mount_actors(m.history, []prim.Id{m.id}, []string{m.line, "elsewhere"}, context.temp_allocator)
	if err != .None {
		world_fail(c.w, "set revert: history_mount_actors failed: %v", err)
		return
	}
	for a in got {
		if a != m.actor {
			world_fail(c.w, "set revert: history_mount_actors of the mount returned %v, not its ingestion actor %v", a, m.actor)
		}
	}
	if _, owned := fs.history_actor_owner(m.history, m.actor); owned && len(got) != 1 {
		world_fail(c.w, "set revert: history_mount_actors of the mount returned %d actors, not its ingestion actor", len(got))
	}
	other, _ := fs.history_mount_actors(m.history, []prim.Id{c.actor[.In]}, nil, context.temp_allocator)
	if len(other) != 0 {
		world_fail(c.w, "set revert: history_mount_actors of an unknown mount returned %v", other)
	}
}

_sr_unrevert :: proc(c: ^Sr_Ctx, revert: prim.Id) -> (again: prim.Id, err: fs.Error) {
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	if c.engine {
		fs.mount_sync(c.sm.m)
		r, eerr := eng.tree_unrevert(&c.n.e, c.tree, revert)
		return r, .None if eerr == .None else .Io
	}
	return fs.mount_unrevert(c.sm.m, revert)
}

@(private = "file")
_sr_same :: proc(a, b: map[string]string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for k, v in a {
		if bv, ok := b[k]; !ok || bv != v {
			return false
		}
	}
	return true
}

set_revert_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
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
	_sr_scenario(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_sr_scenario :: proc(w: ^World) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 20) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	c, ok := _sr_setup(w, virtual.arena_allocator(&arena))
	if !ok {
		return
	}
	c.engine = w.cfg.seed % 2 == 1
	base := _sr_synced(&c)
	steps := 6 + rng_int(&w.rng, 10)
	for _ in 0 ..< steps {
		if !_sr_edit(&c, .In) {
			world_fail(w, "set revert: an edit failed")
			return
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	run_until(w, w.now + 2_000_000_000, true)
	_sr_synced(&c)
	_sr_mount_actors(&c)
	before := _sr_disk(&c)
	revert, rerr := _sr_revert(&c, base, c.actor[.In])
	if rerr != .None {
		world_fail(w, "set revert: mount_revert_set failed: %v", rerr)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	_sr_check(&c, revert, "of A")
	if revert == {} {
		return
	}
	_, uerr := _sr_unrevert(&c, revert)
	if uerr != .None {
		world_fail(w, "set revert: mount_unrevert failed: %v", uerr)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	after := _sr_disk(&c)
	if !_sr_same(before, after) {
		world_fail(w, "set revert: the revert of the revert left %v, not %v", after, before)
		return
	}
	if k := _sr_listed(&c); k != 0 {
		world_fail(w, "set revert: %d revert conflicts are still listed after the revert of the revert", k)
	}
	v1 := _sr_synced(&c)
	_sr_rebase(&c)
	c.actor[.In] = prim.id_new_with(node_clock(&c.n.clock), rng_random(&w.rng))
	for _ in 0 ..< steps {
		if !_sr_edit(&c, .In) {
			world_fail(w, "set revert: a nested edit failed")
			return
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	run_until(w, w.now + 2_000_000_000, true)
	_sr_synced(&c)
	nested, nerr := _sr_revert(&c, v1, c.actor[.In])
	if nerr != .None {
		world_fail(w, "set revert: the nested revert failed: %v", nerr)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	_sr_check(&c, nested, "nested")
	_sr_accept(&c, "nested")
}

@(test)
set_revert_seeds :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	count := int(env_u64("SR_SEEDS", 200))
	first := env_u64("SR_FROM", 1)
	bad := 0
	for k in 0 ..< count {
		seed := first + u64(k)
		failures := set_revert_run(seed)
		for f in failures {
			if bad < 40 {
				fmt.eprintf("set_revert seed %d: %s\n", seed, f)
			}
			delete(f)
		}
		if len(failures) > 0 {
			bad += 1
		}
		delete(failures)
	}
	fmt.eprintf("set_revert: %d seeds, %d failed\n", count, bad)
	testing.expect(t, bad == 0, fmt.tprintf("set_revert: %d of %d seeds failed", bad, count))
}

@(private = "file")
_sr_crash_case :: proc(w: ^World, unrevert: bool, k: u64, arena: ^virtual.Arena) -> (pre, post: map[string]string, crashed: bool, ok: bool) {
	if virtual.arena_init_growing(arena, 1 << 20) != nil {
		return
	}
	c, sok := _sr_setup(w, virtual.arena_allocator(arena))
	if !sok {
		return
	}
	base := _sr_synced(&c)
	steps := 6 + rng_int(&w.rng, 10)
	for _ in 0 ..< steps {
		if !_sr_edit(&c, .In) {
			world_fail(w, "set revert crash: an edit failed")
			return
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	run_until(w, w.now + 2_000_000_000, true)
	_sr_synced(&c)
	pre = _sr_disk(&c)
	revert: prim.Id
	if unrevert {
		r, rerr := _sr_revert(&c, base, c.actor[.In])
		if rerr != .None || r == {} {
			return
		}
		revert = r
		run_until(w, w.now + 2_000_000_000, true)
		pre = _sr_disk(&c)
	}
	n := c.n
	crashes := w.stats.crashes
	if k > 0 {
		n.disk.crash_at = n.disk.stats.ops + k
	}
	sm := c.sm.m
	{
		context = instance_context(&n.inst)
		if unrevert {
			fs.mount_unrevert(sm, revert)
		} else {
			fs.mount_revert_set(sm, base, []prim.Id{c.actor[.In]})
		}
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "set revert crash: node did not come back")
		return
	}
	post = _sr_disk(&c)
	return pre, post, crashed, true
}

@(private = "file")
_sr_crash_world :: proc(seed: u64) -> ^World {
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
	return w
}

@(test)
set_revert_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	seeds := env_u64("SR_CRASH_SEEDS", 1)
	points := [2]int{}
	bad := 0
	for seed in u64(1) ..= seeds {
		for unrevert in ([2]bool{false, true}) {
			rw := _sr_crash_world(seed)
			ra: virtual.Arena
			_, want, _, rok := _sr_crash_case(rw, unrevert, 0, &ra)
			ref := make(map[string]string, context.allocator)
			for name, data in want {
				ref[strings.clone(name)] = strings.clone(data)
			}
			ref_failed := len(rw.failures) > 0
			for f in rw.failures {
				fmt.eprintf("set_revert_crash seed %d unrevert %v reference: %s\n", seed, unrevert, f)
			}
			world_destroy(rw)
			free(rw)
			virtual.arena_destroy(&ra)
			if !rok || ref_failed {
				bad += 1
				continue
			}
			only := env_u64("SR_CRASH_K", 0)
			for k in u64(1) ..= 4000 {
				if only != 0 && k != only {
					continue
				}
				w := _sr_crash_world(seed)
				ca: virtual.Arena
				pre, got, crashed, cok := _sr_crash_case(w, unrevert, k, &ca)
				if cok && !_sr_same(got, pre) && !_sr_same(got, ref) {
					names := make(map[string]bool, context.temp_allocator)
					for m in ([3]map[string]string{got, pre, ref}) {
						for nm in m {
							names[nm] = true
						}
					}
					for nm in prim.sorted_keys(names) {
						g, gh := got[nm]
						p0, ph := pre[nm]
						r, rh := ref[nm]
						if (gh != ph || g != p0) && (gh != rh || g != r) {
							world_fail(w, "after a crash at disk op %d %s is %q (%v), before %q (%v), after %q (%v)", k, nm, g, gh, p0, ph, r, rh)
						}
					}
				}
				for f in w.failures {
					if bad < 30 {
						fmt.eprintf("set_revert_crash seed %d unrevert %v at disk op %d: %s\n", seed, unrevert, k, f)
					}
				}
				if len(w.failures) > 0 {
					bad += 1
				}
				world_destroy(w)
				free(w)
				virtual.arena_destroy(&ca)
				if !crashed || only != 0 {
					break
				}
				points[1 if unrevert else 0] += 1
			}
			for name, data in ref {
				delete(name)
				delete(data)
			}
			delete(ref)
		}
	}
	fmt.eprintf("set_revert_crash: %d crash points in reverts, %d in reverts of reverts, %d failed\n", points[0], points[1], bad)
	testing.expect(t, bad == 0, fmt.tprintf("set_revert_crash: %d failures", bad))
}

@(test)
set_revert_unmounted :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad := 0
	reverts := 0
	count := env_u64("SR_UNMOUNTED_SEEDS", 40)
	for seed in u64(1) ..= count {
		w := _sr_crash_world(seed)
		if _sr_unmounted(w) {
			reverts += 1
		}
		for f in w.failures {
			fmt.eprintf("set_revert_unmounted seed %d: %s\n", seed, f)
		}
		if len(w.failures) > 0 {
			bad += 1
		}
		world_destroy(w)
		free(w)
	}
	fmt.eprintf("set_revert_unmounted: %d seeds, %d reverted, %d failed\n", count, reverts, bad)
	testing.expect(t, bad == 0, fmt.tprintf("set_revert_unmounted: %d seeds failed", bad))
}

@(private = "file")
_sr_unmounted :: proc(w: ^World) -> (reverted: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "unmounted revert: node start")
		return false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	space, serr := eng.space_create(&n.e, "unmounted")
	if serr != .None {
		world_fail(w, "unmounted revert: space_create: %v", serr)
		return false
	}
	eng.space_open(&n.e, space)
	tree, terr := eng.tree_create(&n.e, space, "work")
	if terr != .None {
		world_fail(w, "unmounted revert: tree_create: %v", terr)
		return false
	}
	names := []string{"a.txt", "b.txt", "c.txt"}
	tok := 0
	for nm in names[:2] {
		tok += 1
		ubase, _ := eng.tree_version(&n.e, tree, "", context.temp_allocator)
		eng.tree_write(&n.e, tree, nm, transmute([]u8)fmt.tprintf("<u%d>\n", tok), ubase)
	}
	snapshot :: proc(n: ^Node, tree: eng.Object, names: []string) -> map[string]string {
		out := make(map[string]string, context.temp_allocator)
		for nm in names {
			if data, err := eng.tree_read(&n.e, tree, nm, context.temp_allocator, {}); err == .None {
				out[nm] = string(data)
			}
		}
		return out
	}
	before := snapshot(n, tree, names)
	base, verr := eng.tree_version(&n.e, tree, "", context.temp_allocator)
	if verr != .None {
		world_fail(w, "unmounted revert: tree_version: %v", verr)
		return false
	}
	for _ in 0 ..< 3 + rng_int(&w.rng, 6) {
		nm := names[rng_int(&w.rng, len(names))]
		if rng_chance(&w.rng, 1, 5) {
			eng.tree_remove(&n.e, tree, nm)
			continue
		}
		cbase: fs.Version
		cur, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator, {}, "", nil, &cbase)
		tok += 1
		eng.tree_write(&n.e, tree, nm, transmute([]u8)strings.concatenate({string(cur), fmt.tprintf("<u%d>\n", tok)}, context.temp_allocator), cbase)
	}
	after := snapshot(n, tree, names)
	undo := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	if _, had, _ := eng.tree_undo_revert(&n.e, tree, undo); had {
		world_fail(w, "unmounted revert: an undo id finds a revert before any was made")
	}
	revert, rerr := eng.tree_revert_set(&n.e, tree, base, []prim.Id{n.e.self}, "", undo)
	if rerr != .None {
		world_fail(w, "unmounted revert: tree_revert_set: %v", rerr)
		return false
	}
	if got, had, _ := eng.tree_undo_revert(&n.e, tree, undo); revert != {} && (!had || got != revert) {
		world_fail(w, "unmounted revert: the undo id finds %v (found=%v), not its revert %v", got, had, revert)
	}
	if got := snapshot(n, tree, names); !_sr_same(got, before) {
		world_fail(w, "unmounted revert: the tree holds %v after the revert, not %v", got, before)
	}
	if revert == {} {
		return false
	}
	reverted = true
	if _, uerr := eng.tree_unrevert(&n.e, tree, revert); uerr != .None {
		world_fail(w, "unmounted revert: tree_unrevert: %v", uerr)
		return false
	}
	if got := snapshot(n, tree, names); !_sr_same(got, after) {
		world_fail(w, "unmounted revert: the tree holds %v after the revert of the revert, not %v", got, after)
	}
	return
}
