package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/odb"
import "../../src/prim"

@(private = "file")
RS_ROOT :: "/work/rs-n0-git"

@(private = "file")
RS_ROOT2 :: "/work/rs2-n0-git"

@(private = "file")
RS_FEATURE :: "git:refs/heads/feature"

@(private = "file")
RS_SHARED :: "shared a\n"

@(private = "file")
RS_BLOB :: "/objects/0a/dfbfc6a1d298c56eccc4effd562b8c4ca64358"

@(private = "file")
RS_SECRET :: "the redacted token 7c1f-a93e\n"


@(private = "file")
RS_Crash :: enum {
	None,
	Two_Trees,
	In_Blob,
}

@(private = "file")
_rs_read :: proc(n: ^Node, tree: eng.Object, line: string, path := "a.txt") -> (string, bool) {
	if !n.alive || !n.e_open {
		return "<down>", false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.tree_read(&n.e, tree, path, context.temp_allocator, {}, line)
	if err != .None {
		return fmt.aprintf("<%v>", err, allocator = n.w.allocator), false
	}
	return strings.clone(string(data), n.w.allocator), true
}

@(private = "file")
_rs_settle :: proc(w: ^World, n: ^Node, tree: eng.Object, line: string, want: string) -> (got: string, ok: bool) {
	for _ in 0 ..< 60 {
		got, ok = _rs_read(n, tree, line)
		if ok && got == want {
			return got, true
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	return got, false
}

@(private = "file")
_rs_redact :: proc(w: ^World, a: ^Node, oi: int, line := RS_FEATURE) -> (done: bool) {
	m := &w.model
	mounted := false
	for x in a.mounts {
		mounted ||= x.root == RS_ROOT && x.m != nil
	}
	if !mounted {
		if err := node_mount(w, a, oi, RS_ROOT); err != .None {
			world_fail(w, "redact shared: remount for the redaction: %v", err)
			return false
		}
		append(&m.mounts, M_Mount{node = a.idx, oi = oi, root = strings.clone(RS_ROOT, w.allocator)})
		run_until(w, w.now + 2_000_000_000, true)
	}
	context = instance_context(&a.inst)
	defer node_after(a)
	sm: ^Sim_Mount
	for &x in a.mounts {
		if x.root == RS_ROOT && x.m != nil {
			sm = &x
		}
	}
	if sm == nil {
		world_fail(w, "redact shared: the mount is gone before the redaction")
		return false
	}
	v, _, _ := fs.history_line(sm.m.history, line, context.temp_allocator)
	from := len(RS_SHARED)
	_, rerr := fs.mount_redact_range(sm.m, "a.txt", v, from, from + len(RS_SECRET), context.temp_allocator)

	if a.alive && a.e_open {
		eng.tree_unmount(&a.e, sm.m)
	}
	for x, i in a.mounts {
		if x.root == RS_ROOT {
			ordered_remove(&a.mounts, i)
			break
		}
	}
	for x, i in m.mounts {
		if x.node == a.idx && x.root == RS_ROOT {
			ordered_remove(&m.mounts, i)
			break
		}
	}
	return rerr == .None && a.alive
}

@(private = "file")
_oldver :: proc(w: ^World, crash: RS_Crash) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b, c := w.nodes[0], w.nodes[1], w.nodes[2]
	for n in ([]^Node{a, b, c}) {
		if !node_start(n) {
			world_fail(w, "node start")
			return
		}
	}
	m := &w.model
	vfs := disk_vfs(&a.disk)
	space: prim.Id
	tree: eng.Object
	proofs: [2][]u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "rs", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "redact shared: space setup: %v", err)
			return
		}
		space = id
		for n, i in ([]^Node{b, c}) {
			p, perr := eng.member_add(&a.e, space, n.identity, .Device, .Admin, .Approval, 0, w.allocator)
			if perr != .None {
				world_fail(w, "redact shared: member_add: %v", perr)
				return
			}
			proofs[i] = p
		}
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "redact shared: tree_create: %v", err)
			return
		}
	}
	for n, i in ([]^Node{b, c}) {
		context = instance_context(&n.inst)
		if _, jerr := eng.space_join_enrollment(&n.e, space, proofs[i], "rs", "relay", w.relay.public); jerr != .None {
			world_fail(w, "redact shared: join: %v", jerr)
			node_after(n)
			return
		}
		eng.space_open(&n.e, space)
		node_after(n)
	}
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(RS_SHARED + RS_SECRET if crash == .In_Blob else RS_SHARED)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}, {name = "d.txt", data = transmute([]u8)string("main d\n")}}
	when_s := clock_wall(&a.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, RS_ROOT, files[:], when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "redact shared: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}}
	if err := git_branch_commit(vfs, RS_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "redact shared: branch commit: %v", err)
		return
	}
	if err := node_mount(w, a, oi, RS_ROOT); err != .None {
		world_fail(w, "redact shared: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = a.idx, oi = oi, root = strings.clone(RS_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, RS_ROOT, "feature", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "redact shared: checkout feature: %v %v", res, err)
		return
	}
	tick: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	if crash != .In_Blob {
		written := false
		for _ in 0 ..< 30 {
			context = instance_context(&c.inst)
			base: fs.Version
			cur, rerr := eng.tree_read(&c.e, tree, "a.txt", context.temp_allocator, {}, RS_FEATURE, nil, &base)
			if rerr == .None && string(cur) == RS_SHARED {
				next := strings.concatenate({string(cur), RS_SECRET}, context.temp_allocator)
				if werr := eng.tree_write(&c.e, tree, "a.txt", transmute([]u8)next, base, RS_FEATURE); werr == .None {
					written = true
				}
			}
			node_after(c)
			if written {
				break
			}
			run_until(w, w.now + 1_000_000_000, true)
		}
		if !written {
			world_fail(w, "redact shared: the third device never wrote a.txt on feature, so the check proves nothing")
			return
		}
	}
	full := RS_SHARED + RS_SECRET
	for n in ([]^Node{a, b, c}) {
		if got, ok := _rs_settle(w, n, tree, "main" if crash == .In_Blob else RS_FEATURE, full); !ok {
			world_fail(w, "redact shared: %s never read the secret line before the redaction (%q), so the check proves nothing", n.name, got)
			return
		}
		if got, ok := _rs_settle(w, n, tree, "main", full if crash == .In_Blob else RS_SHARED); !ok {
			world_fail(w, "redact shared: %s never read main before the redaction (%q)", n.name, got)
			return
		}
	}
	other: eng.Object
	if crash == .Two_Trees {
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			err: eng.Error
			other, err = eng.tree_create(&a.e, space, "other")
			if err != .None {
				world_fail(w, "redact shared: second tree: %v", err)
				return
			}
		}
		op2 := new_op(m, .Create, a, len(m.objs))
		op_done(op2, 0, .None)
		ob2 := M_Obj{kind = .Tree, creator = a.idx, op = op2.idx, o = other}
		ob2.removed = make(map[string]bool, w.allocator)
		ob2.shared = make([dynamic]int, w.allocator)
		append(&m.objs, ob2)
		one := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(RS_SHARED)}}
		if err := git_checkout_create(vfs, RS_ROOT2, one[:], when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
			world_fail(w, "redact shared: second checkout: %v", err)
			return
		}
		if err := node_mount(w, a, len(m.objs) - 1, RS_ROOT2); err != .None {
			world_fail(w, "redact shared: second mount: %v", err)
			return
		}
		append(&m.mounts, M_Mount{node = a.idx, oi = len(m.objs) - 1, root = strings.clone(RS_ROOT2, w.allocator)})
		for n in ([]^Node{a, b, c}) {
			if got, ok := _rs_settle(w, n, other, "main", RS_SHARED); !ok {
				world_fail(w, "redact shared: %s never read the second tree (%q), so the check proves nothing", n.name, got)
				return
			}
		}
	}
	c.partitioned = true
	for cn in c.conns {
		conn_reset(cn, true)
	}
	client := Ov_Client{open = true}
	ids := make([dynamic]eng.Buffer_Id, w.allocator)
	targets := [][2]string{{"main", "a.txt"}, {RS_FEATURE, "a.txt"}}
	for t in targets {
		context = instance_context(&b.inst)
		info, err := eng.buffer_open(&b.e, tree, eng.Buffer_Options{path = t[1], line = t[0], data = &client, cb = proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {}, ready = proc(data: rawptr) -> bool {
			return (^Ov_Client)(data).open
		}}, context.temp_allocator)
		node_after(b)
		if err != .None {
			world_fail(w, "oldver: buffer on %s: %v", t[0], err)
			return
		}
		append(&ids, info.id)
	}
	if crash == .Two_Trees {
		context = instance_context(&b.inst)
		info, err := eng.buffer_open(&b.e, other, eng.Buffer_Options{path = "a.txt", data = &client, cb = proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {}, ready = proc(data: rawptr) -> bool {
			return (^Ov_Client)(data).open
		}}, context.temp_allocator)
		node_after(b)
		if err != .None {
			world_fail(w, "oldver: buffer on the second tree: %v", err)
			return
		}
		append(&ids, info.id)
	}
	if !_rs_redact(w, a, oi, "main" if crash == .In_Blob else RS_FEATURE) {
		world_fail(w, "oldver: the redaction failed")
		return
	}
	for step in 0 ..< 3 {
		if step == 1 {
			c.partitioned = false
		}
		for _ in 0 ..< 20 {
			run_until(w, w.now + 2_000_000_000, true)
			context = instance_context(&b.inst)
			for id in ids {
				eng.buffer_kick(&b.e, id)
			}
			node_after(b)
		}
		for n in ([]^Node{b, c}) {
			if step == 0 && n == c {
				continue
			}
			if p, held := _ov_holds(w, n); held {
				world_fail(w, "oldver: after step %d %s holds the redacted text again at %s", step, n.name, p)
			}
		}
	}
	for id, i in ids {
		context = instance_context(&b.inst)
		t, _, err := eng.buffer_text(&b.e, id, context.temp_allocator)
		world_note(w, "oldver: buffer %d shows %d bytes, secret %v, %v", i, len(t), strings.contains(string(t), RS_SECRET), err)
		node_after(b)
	}
}

@(private = "file")
Ov_Client :: struct {
	open: bool,
}

@(private = "file")
_ov_holds :: proc(w: ^World, n: ^Node) -> (where_: string, found: bool) {
	if !n.alive || !n.e_open {
		return "", false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	for f in files {
		if strings.has_prefix(f.path, "/work/") && !strings.contains(f.path, "/.git/") {
			continue
		}
		if strings.contains(string(f.data), RS_SECRET) || strings.contains(string(f.durable), RS_SECRET) {
			return strings.clone(f.path, w.allocator), true
		}
		parts := strings.split(f.path, "/", context.temp_allocator)
		if len(parts) >= 3 && strings.contains(f.path, "/objects/") {
			hex := strings.concatenate({parts[len(parts) - 2], parts[len(parts) - 1]}, context.temp_allocator)
			if oid, _, ok := odb.oid_from_hex(hex); ok {
				if _, obj, err := odb.read(&n.e.db, oid, context.temp_allocator); err == .None && strings.contains(string(obj), RS_SECRET) {
					return strings.clone(f.path, w.allocator), true
				}
			}
		}
	}
	return "", false
}

@(test)
redact_oldver :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for crash in ([]RS_Crash{.None, .Two_Trees, .In_Blob}) {
		cfg := default_config(1)
		cfg.nodes = 3
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
		_oldver(w, crash)
		for f in w.failures {
			fmt.eprintf("redact_oldver %v: %s\n", crash, f)
		}
		testing.expectf(t, len(w.failures) == 0, "redact_oldver %v failed", crash)
		world_destroy(w)
		free(w)
	}
}
