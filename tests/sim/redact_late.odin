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
RL_ROOT :: "/work/rl-n0"

@(private = "file")
RL_CROOT :: "/work/rl-n2"

@(private = "file")
RL_SECRET :: "the late token 3f0a-77c2"

@(private = "file")
_rl_cut :: proc(w: ^World, n: ^Node, cut: bool) {
	n.partitioned = cut
	if cut {
		for cn in n.conns {
			conn_reset(cn, true)
		}
	}
}

@(private = "file")
_rl_read :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (string, eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	t, err := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator)
	return strings.clone(string(t), w.allocator), err
}

@(private = "file")
_rl_holds :: proc(w: ^World, n: ^Node) -> (where_: string, found: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	for f in files {
		if strings.has_prefix(f.path, "/work/") {
			continue
		}
		if strings.contains(string(f.data), RL_SECRET) || strings.contains(string(f.durable), RL_SECRET) {
			return strings.clone(f.path, w.allocator), true
		}
		parts := strings.split(f.path, "/", context.temp_allocator)
		if len(parts) >= 3 && strings.contains(f.path, "/objects/") {
			hex := strings.concatenate({parts[len(parts) - 2], parts[len(parts) - 1]}, context.temp_allocator)
			if oid, _, ok := odb.oid_from_hex(hex); ok {
				if _, obj, err := odb.read(&n.e.db, oid, context.temp_allocator); err == .None && strings.contains(string(obj), RL_SECRET) {
					return strings.clone(f.path, w.allocator), true
				}
			}
		}
	}
	return "", false
}

@(private = "file")
_rl :: proc(w: ^World) {
	a, b, c := w.nodes[0], w.nodes[1], w.nodes[2]
	if !relay_start(&w.relay) || !node_start(a) || !node_start(b) || !node_start(c) {
		world_fail(w, "start")
		return
	}
	m := &w.model
	space: prim.Id
	tree: eng.Object
	proofs: [2][]u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		space, err = eng.space_create(&a.e, "rl", "relay", w.relay.public)
		if err == .None {
			err = eng.space_open(&a.e, space)
		}
		for n, i in ([]^Node{b, c}) {
			if err == .None {
				proofs[i], err = eng.member_add(&a.e, space, n.identity, .Device, .Admin, .Approval, 0, w.allocator)
			}
		}
		if err == .None {
			tree, err = eng.tree_create(&a.e, space, "work")
		}
		if err != .None {
			world_fail(w, "late: setup: %v", err)
			return
		}
	}
	for n, i in ([]^Node{b, c}) {
		context = instance_context(&n.inst)
		if _, err := eng.space_join_enrollment(&n.e, space, proofs[i], "rl", "relay", w.relay.public); err != .None {
			world_fail(w, "late: join: %v", err)
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
	vfs := disk_vfs(&a.disk)
	if prim.mkdir_all(vfs, RL_ROOT, 0o755) != .None || node_mount(w, a, len(m.objs) - 1, RL_ROOT) != .None {
		world_fail(w, "late: mount")
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	for _ in 0 ..< 20 {
		_rl_read(w, b, tree)
		run_until(w, w.now + 1_000_000_000, true)
	}
	_rl_cut(w, b, true)
	big := make([]u8, 20_000, w.allocator)
	for i in 0 ..< len(big) {
		big[i] = '\n' if i % 61 == 60 else u8('a' + (i * 7 + i / 61) % 26)
	}
	at := 10_000
	copy(big[at:], RL_SECRET)
	cvfs := disk_vfs(&c.disk)
	if prim.mkdir_all(cvfs, RL_CROOT, 0o755) != .None || node_mount(w, c, len(m.objs) - 1, RL_CROOT) != .None {
		world_fail(w, "late: the writer's mount")
		return
	}
	append(&m.mounts, M_Mount{node = c.idx, oi = len(m.objs) - 1, root = strings.clone(RL_CROOT, w.allocator)})
	run_until(w, w.now + 5_000_000_000, true)
	if prim.replace_atomic(cvfs, RL_CROOT + "/a.txt", big) != .None {
		world_fail(w, "late: the writer's disk write")
		return
	}
	{
		context = instance_context(&c.inst)
		defer node_after(c)
		if err := fs.mount_sync(c.mounts[0].m); err != .None {
			world_fail(w, "late: the writer's ingest: %v", err)
			return
		}
	}
	full := string(big)
	ok := false
	for _ in 0 ..< 60 {
		run_until(w, w.now + 1_000_000_000, true)
		if got, _ := _rl_read(w, a, tree); got == full {
			ok = true
			break
		}
	}
	if !ok {
		world_fail(w, "late: the redactor never read the writer's file, so the check proves nothing")
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	boid, _ := odb.hash(.Sha1, .Blob, big)
	world_note(w, "late: before the redaction n0 holds the writer's blob: %v; reader fetches so far %d", odb.exists(&a.e.db, boid), b.e.stats.fetches)
	if !odb.exists(&a.e.db, boid) {
		world_fail(w, "late: the writer's file is not one blob on the redactor, so the check proves nothing")
		return
	}
	_rl_cut(w, c, true)
	redact: {
		context = instance_context(&a.inst)
		defer node_after(a)
		mnt := a.mounts[0].m
		fs.mount_sync(mnt)
		if _, err := fs.mount_redact_range(mnt, "a.txt", nil, at, at + len(RL_SECRET), context.temp_allocator); err != .None {
			world_fail(w, "late: redact: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	if p, held := _rl_holds(w, a); held {
		world_fail(w, "late: the redactor still holds the secret at %s", p)
	}
	_rl_cut(w, b, false)
	for i in 0 ..< 60 {
		run_until(w, w.now + 2_000_000_000, true)
		got, err := _rl_read(w, b, tree)
		if i == 59 {
			world_note(w, "late: the reader reads %d bytes, secret %v, %v", len(got), strings.contains(got, RL_SECRET), err)
		}
	}
	world_note(w, "late: the reader holds the writer's blob: %v; reader fetches %d", odb.exists(&b.e.db, boid), b.e.stats.fetches)
	p, held := _rl_holds(w, b)
	world_note(w, "late: with the writer still offline the reader holds the secret: %v %s", held, p)
	if held {
		world_fail(w, "late: the reader holds the redacted text at %s while the writer is offline", p)
	}
	_rl_cut(w, c, false)
	run_until(w, w.now + 90_000_000_000, true)
	for n in ([]^Node{a, b, c}) {
		if q, h := _rl_holds(w, n); h {
			world_fail(w, "late: with every device caught up %s holds the redacted text at %s", n.name, q)
		}
	}
}

@(test)
redact_late :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
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
	_rl(w)
	for f in w.failures {
		fmt.eprintf("redact_late: %s\n", f)
	}
	testing.expect(t, len(w.failures) == 0, "redact_late failed")
	world_destroy(w)
	free(w)
}
