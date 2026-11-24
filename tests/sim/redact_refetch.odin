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
RR_ROOT :: "/work/rr-n0"

@(private = "file")
RR_SECRET :: "the refetched token 91be-04d7"

@(private = "file")
RR_BIG :: 60_000

@(private = "file")
RR_AT :: 30_000

@(private = "file")
RR_Case :: enum {
	Buffer,
	Offline,
	Joins_Later,
}

@(private = "file")
Rr_Client :: struct {
	open: bool,
}

@(private = "file")
_rr_holds :: proc(w: ^World, n: ^Node) -> (where_: string, found: bool) {
	if !n.alive || !n.e_open {
		return "down", false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	for f in files {
		if strings.has_prefix(f.path, "/work/") {
			continue
		}
		if strings.contains(string(f.data), RR_SECRET) || strings.contains(string(f.durable), RR_SECRET) {
			return strings.clone(f.path, w.allocator), true
		}
		parts := strings.split(f.path, "/", context.temp_allocator)
		if len(parts) < 3 || parts[1] != "data" || parts[2] != "objects" {
			continue
		}
		hex := strings.concatenate({parts[len(parts) - 2], parts[len(parts) - 1]}, context.temp_allocator)
		if oid, _, ok := odb.oid_from_hex(hex); ok {
			if _, obj, err := odb.read(&n.e.db, oid, context.temp_allocator); err == .None && strings.contains(string(obj), RR_SECRET) {
				return strings.clone(f.path, w.allocator), true
			}
		}
		if strings.has_suffix(f.path, ".idx") && len(f.data) > 8 + 256 * 4 {
			fan := f.data[8 + 255 * 4:]
			count := int(u32(fan[0]) << 24 | u32(fan[1]) << 16 | u32(fan[2]) << 8 | u32(fan[3]))
			for i in 0 ..< count {
				oid: odb.Oid
				at := 8 + 256 * 4 + i * 20
				if at + 20 > len(f.data) {
					break
				}
				copy(oid[:], f.data[at:][:20])
				if _, obj, err := odb.read(&n.e.db, oid, context.temp_allocator); err == .None && strings.contains(string(obj), RR_SECRET) {
					return strings.clone(f.path, w.allocator), true
				}
			}
		}
	}
	return "", false
}

@(private = "file")
_rr_read :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (string, eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	t, err := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator)
	return strings.clone(string(t), w.allocator), err
}

@(private = "file")
_rr_join :: proc(w: ^World, n: ^Node, space: prim.Id, proof: []u8) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	if _, err := eng.space_join_enrollment(&n.e, space, proof, "rr", "relay", w.relay.public); err != .None {
		world_fail(w, "refetch: join: %v", err)
		return false
	}
	eng.space_open(&n.e, space)
	return true
}

@(private = "file")
_rr :: proc(w: ^World, kind: RR_Case) {
	a, b, c := w.nodes[0], w.nodes[1], w.nodes[2]
	if !relay_start(&w.relay) || !node_start(a) || !node_start(b) || !node_start(c) {
		world_fail(w, "start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&a.disk)
	space: prim.Id
	tree: eng.Object
	proofs: [2][]u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		space, err = eng.space_create(&a.e, "rr", "relay", w.relay.public)
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
			world_fail(w, "refetch: setup: %v", err)
			return
		}
	}
	if kind != .Joins_Later && !_rr_join(w, b, space, proofs[0]) || !_rr_join(w, c, space, proofs[1]) {
		return
	}
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	small := "first line\n"
	big := make([]u8, RR_BIG, w.allocator)
	for i in 0 ..< RR_BIG {
		big[i] = '\n' if i % 61 == 60 else u8('a' + (i * 7 + i / 61) % 26)
	}
	copy(big[RR_AT:], RR_SECRET)
	if prim.mkdir_all(vfs, RR_ROOT, 0o755) != .None || prim.replace_atomic(vfs, RR_ROOT + "/a.txt", transmute([]u8)small) != .None {
		world_fail(w, "refetch: disk setup")
		return
	}
	if err := node_mount(w, a, len(m.objs) - 1, RR_ROOT); err != .None {
		world_fail(w, "refetch: mount: %v", err)
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	client := Rr_Client{open = true}
	id: eng.Buffer_Id
	if kind == .Buffer {
		for _ in 0 ..< 30 {
			context = instance_context(&b.inst)
			info, err := eng.buffer_open(&b.e, tree, eng.Buffer_Options{path = "a.txt", data = &client, cb = proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {}, ready = proc(data: rawptr) -> bool {
				return (^Rr_Client)(data).open
			}}, context.temp_allocator)
			node_after(b)
			if err == .None {
				id = info.id
				break
			}
			run_until(w, w.now + 1_000_000_000, true)
		}
		if id == 0 {
			world_fail(w, "refetch: the buffer never opened")
			return
		}
		client.open = false
	}
	if kind == .Offline {
		b.partitioned = true
		for cn in b.conns {
			conn_reset(cn, true)
		}
	}
	fd, oerr := prim.open_file(vfs, RR_ROOT + "/a.txt", {.Write})
	if oerr != .None || prim.write_at(vfs, fd, big, i64(len(small))) != .None || prim.close_file(vfs, fd) != .None {
		world_fail(w, "refetch: append")
		return
	}
	sync: {
		context = instance_context(&a.inst)
		defer node_after(a)
		if err := fs.mount_sync(a.mounts[0].m); err != .None {
			world_fail(w, "refetch: sync: %v", err)
			return
		}
	}
	full := strings.concatenate({small, string(big)}, w.allocator)
	before := []^Node{a, c} if kind != .Buffer else []^Node{a, b, c}
	for n in before {
		for _ in 0 ..< 60 {
			run_until(w, w.now + 1_000_000_000, true)
			if got, _ := _rr_read(w, n, tree); got == full {
				break
			}
		}
		if got, err := _rr_read(w, n, tree); got != full {
			world_fail(w, "refetch: %s reads %d bytes before the redaction (%v), so the check proves nothing", n.name, len(got), err)
			return
		}
	}
	if kind == .Buffer {
		if _, held := _rr_holds(w, b); !held {
			world_fail(w, "refetch: the reader never held the secret, so the check proves nothing")
			return
		}
	}
	c.partitioned = true
	for cn in c.conns {
		conn_reset(cn, true)
	}
	redact: {
		context = instance_context(&a.inst)
		defer node_after(a)
		from := len(small) + RR_AT
		if _, err := fs.mount_redact_range(a.mounts[0].m, "a.txt", nil, from, from + len(RR_SECRET), context.temp_allocator); err != .None {
			world_fail(w, "refetch: redact: %v", err)
			return
		}
		eng.tree_unmount(&a.e, a.mounts[0].m)
		ordered_remove(&a.mounts, 0)
	}
	run_until(w, w.now + 40_000_000_000, true)
	if p, held := _rr_holds(w, a); held {
		world_fail(w, "refetch: the redactor still holds the secret at %s", p)
	}
	switch kind {
	case .Buffer:
		p, held := _rr_holds(w, b)
		world_note(w, "refetch: before its buffer runs the reader holds the secret: %v %s", held, p)
		client.open = true
		context = instance_context(&b.inst)
		eng.buffer_kick(&b.e, id)
		node_after(b)
	case .Offline:
		b.partitioned = false
	case .Joins_Later:
		if !_rr_join(w, b, space, proofs[0]) {
			return
		}
	}
	for i in 0 ..< 60 {
		run_until(w, w.now + 2_000_000_000, true)
		got, err := _rr_read(w, b, tree)
		if i == 59 {
			world_note(w, "refetch: the reader reads %d bytes, secret %v, %v", len(got), strings.contains(got, RR_SECRET), err)
		}
	}
	if p, held := _rr_holds(w, b); held {
		world_fail(w, "refetch: the reader holds the redacted text again at %s", p)
	}
	c.partitioned = false
	run_until(w, w.now + 60_000_000_000, true)
	for n in ([]^Node{a, b, c}) {
		if p, held := _rr_holds(w, n); held {
			world_fail(w, "refetch: with every device caught up %s holds the redacted text at %s", n.name, p)
		}
	}
}

@(test)
redact_refetch :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for kind in RR_Case {
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
		_rr(w, kind)
		for f in w.failures {
			fmt.eprintf("redact_refetch %v: %s\n", kind, f)
		}
		testing.expectf(t, len(w.failures) == 0, "redact_refetch %v failed", kind)
		world_destroy(w)
		free(w)
	}
}
