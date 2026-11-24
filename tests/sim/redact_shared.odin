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
RS_FEATURE :: "git:refs/heads/feature"

@(private = "file")
RS_SHARED :: "shared a\n"

@(private = "file")
RS_SECRET :: "the redacted token 7c1f-a93e\n"

RS_Crash :: enum {
	None,
	Redactor,
	Holder,
}

redact_shared_run :: proc(seed: u64, crash: RS_Crash) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
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
	_redact_shared(w, crash)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_rs_read :: proc(n: ^Node, tree: eng.Object, line: string) -> (string, bool) {
	if !n.alive || !n.e_open {
		return "<down>", false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	if err != .None {
		return fmt.tprintf("<%v>", err), false
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
_rs_has :: proc(data: []u8) -> bool {
	return strings.contains(string(data), RS_SECRET)
}

@(private = "file")
_rs_scan :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open {
		world_fail(w, "redact shared: %s is down at the plaintext scan", n.name)
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	for f in files {
		p := f.path
		if strings.has_prefix(p, "/work/") && !strings.contains(p, "/.git/") {
			continue
		}
		data := f.data
		if _rs_has(f.data) || _rs_has(f.durable) {
			world_fail(w, "redact shared: %s holds the redacted text in plain bytes at %s", n.name, p)
		}
		if strings.contains(p, "/objects/") && !strings.contains(p, "/objects/pack/") && !strings.contains(p, "/objects/info/") {
			parts := strings.split(p, "/", context.temp_allocator)
			if len(parts) >= 2 {
				hex := strings.concatenate({parts[len(parts) - 2], parts[len(parts) - 1]}, context.temp_allocator)
				if oid, _, hok := odb.oid_from_hex(hex); hok {
					if _, obj, lerr := odb.read(&n.e.db, oid, context.temp_allocator); lerr == .None && _rs_has(obj) {
						world_fail(w, "redact shared: %s holds the redacted text in loose object %s", n.name, p)
					}
				}
			}
		}
		if strings.has_suffix(p, ".idx") && strings.contains(p, "/objects/pack/") && len(data) >= 8 + 256 * 4 {
			fan := data[8 + 255 * 4:]
			count := int(u32(fan[0]) << 24 | u32(fan[1]) << 16 | u32(fan[2]) << 8 | u32(fan[3]))
			hsz := 20
			for i in 0 ..< count {
				at := 8 + 256 * 4 + i * hsz
				if at + hsz > len(data) {
					break
				}
				oid: odb.Oid
				copy(oid[:], data[at:][:hsz])
				if _, obj, oerr := odb.read(&n.e.db, oid, context.temp_allocator); oerr == .None && _rs_has(obj) {
					world_fail(w, "redact shared: %s holds the redacted text in a packed object of %s", n.name, p)
				}
			}
		}
	}
}

@(private = "file")
_rs_redact :: proc(w: ^World, a: ^Node, oi: int) -> (done: bool) {
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
	v, _, _ := fs.history_line(sm.m.history, RS_FEATURE, context.temp_allocator)
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
_redact_shared :: proc(w: ^World, crash: RS_Crash) {
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(RS_SHARED)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
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
	full := RS_SHARED + RS_SECRET
	for n in ([]^Node{a, b, c}) {
		if got, ok := _rs_settle(w, n, tree, RS_FEATURE, full); !ok {
			world_fail(w, "redact shared: %s never read the secret line before the redaction (%q), so the check proves nothing", n.name, got)
			return
		}
		if got, ok := _rs_settle(w, n, tree, "main", RS_SHARED); !ok {
			world_fail(w, "redact shared: %s never read main before the redaction (%q)", n.name, got)
			return
		}
	}
	node_crash_now(b, .Power, 1)
	a.disk.blob_zero_crash = crash == .Redactor
	c.disk.blob_zero_crash = crash == .Holder
	done := _rs_redact(w, a, oi)
	if crash == .Redactor {
		if done {
			world_fail(w, "redact shared: the redactor's power cut before the scrub never fired, so the check proves nothing")
			return
		}
		run_until(w, w.now + 10_000_000_000, true)
		if got, ok := _rs_read(a, tree, RS_FEATURE); ok && got != full && !strings.has_prefix(got, RS_SHARED) {
			world_fail(w, "redact shared: after a power cut before the scrub the redactor reads feature as %q", got)
		}
		if !_rs_redact(w, a, oi) {
			world_fail(w, "redact shared: the redaction retried after the power cut failed")
			return
		}
	} else if !done {
		world_fail(w, "redact shared: the redaction failed")
		return
	}
	run_until(w, w.now + 60_000_000_000, true)
	zeroed := strings.concatenate({RS_SHARED, strings.repeat("\x00", len(RS_SECRET), w.allocator)}, w.allocator)
	for n in ([]^Node{a, b, c}) {
		if got, ok := _rs_settle(w, n, tree, "main", RS_SHARED); !ok {
			world_fail(w, "redact shared: %s reads main as %q after the redaction, want %q", n.name, got, RS_SHARED)
		}
		if got, ok := _rs_settle(w, n, tree, RS_FEATURE, zeroed); !ok {
			world_fail(w, "redact shared: %s reads feature as %q (%d bytes) after the redaction, want the secret zero-filled (%d bytes)", n.name, got, len(got), len(zeroed))
		}
	}
	for n in ([]^Node{a, b, c}) {
		_rs_scan(w, n)
	}
}

@(test)
redact_shared_blob :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for crash in RS_Crash {
		failures := redact_shared_run(1, crash)
		for f in failures {
			fmt.eprintf("redact_shared %v: %s\n", crash, f)
			delete(f)
		}
		testing.expectf(t, len(failures) == 0, "redact_shared %v failed", crash)
		delete(failures)
	}
}
