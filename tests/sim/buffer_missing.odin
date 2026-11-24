package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/odb"
import "../../src/prim"

@(private = "file")
BM_ROOT :: "/work/bm-n0"

@(private = "file")
BM_BIG :: 60_000

Bm_Case :: enum {
	Lost,
	Unread_Once,
	Sends_Back,
	Io,
}

@(private = "file")
Bm_Client :: struct {
	open:   bool,
	zeros:  int,
	closed: int,
	err:    eng.Error,
}

@(private = "file")
_bm_cb :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	c := (^Bm_Client)(data)
	if ev.kind == .Closed {
		c.closed += 1
		c.err = ev.err
		return
	}
	if ev.kind != .Delta {
		return
	}
	if t, _, err := eng.buffer_text(e, ev.buffer, context.temp_allocator); err == .None {
		c.zeros += strings.count(string(t), "\x00")
	}
}

@(private = "file")
_bm_text :: proc(w: ^World, n: ^Node, id: eng.Buffer_Id) -> (text: string, rev: u64, err: eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	t: []u8
	t, rev, err = eng.buffer_text(&n.e, id, context.temp_allocator)
	return strings.clone(string(t), w.allocator), rev, err
}

@(private = "file")
_bm_file :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (text: string, err: eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	t: []u8
	t, err = eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator)
	return strings.clone(string(t), w.allocator), err
}

@(private = "file")
_bm :: proc(w: ^World, kind: Bm_Case) {
	a, b := w.nodes[0], w.nodes[1]
	if !relay_start(&w.relay) || !node_start(a) || !node_start(b) {
		world_fail(w, "start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&a.disk)
	space: prim.Id
	tree: eng.Object
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		space, err = eng.space_create(&a.e, "bm", "relay", w.relay.public)
		if err == .None {
			err = eng.space_open(&a.e, space)
		}
		if err == .None {
			proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		}
		if err == .None {
			tree, err = eng.tree_create(&a.e, space, "work")
		}
		if err != .None {
			world_fail(w, "buffer missing: setup: %v", err)
			return
		}
	}
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "bm", "relay", w.relay.public); err != .None {
			world_fail(w, "buffer missing: join: %v", err)
			return
		}
		eng.space_open(&b.e, space)
	}
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	small := "first line\n"
	big := make([]u8, BM_BIG, w.allocator)
	for i in 0 ..< BM_BIG {
		big[i] = '\n' if i % 61 == 60 else u8('a' + (i * 7 + i / 61) % 26)
	}
	full := strings.concatenate({small, string(big)}, w.allocator)
	if prim.mkdir_all(vfs, BM_ROOT, 0o755) != .None || prim.replace_atomic(vfs, BM_ROOT + "/a.txt", transmute([]u8)small) != .None {
		world_fail(w, "buffer missing: disk setup")
		return
	}
	if err := node_mount(w, a, len(m.objs) - 1, BM_ROOT); err != .None {
		world_fail(w, "buffer missing: mount: %v", err)
		return
	}
	c: Bm_Client
	c.open = true
	id: eng.Buffer_Id
	for _ in 0 ..< 30 {
		run_until(w, w.now + 1_000_000_000, true)
		context = instance_context(&b.inst)
		info, err := eng.buffer_open(&b.e, tree, eng.Buffer_Options{path = "a.txt", cb = _bm_cb, data = &c, ready = proc(data: rawptr) -> bool {
			return (^Bm_Client)(data).open
		}}, context.temp_allocator)
		node_after(b)
		if err == .None {
			id = info.id
			break
		}
	}
	if id == 0 {
		world_fail(w, "buffer missing: the buffer never opened")
		return
	}
	c.open = false
	fd, oerr := prim.open_file(vfs, BM_ROOT + "/a.txt", {.Write})
	if oerr != .None || prim.write_at(vfs, fd, big, i64(len(small))) != .None || prim.close_file(vfs, fd) != .None {
		world_fail(w, "buffer missing: append")
		return
	}
	hb: [odb.MAX_HEX]u8
	oid, _ := odb.hash(.Sha1, .Blob, big)
	hex := odb.oid_to_string(oid, .Sha1, &hb)
	want := strings.concatenate({"/", hex[:2], "/", hex[2:]}, w.allocator)
	path := ""
	for _ in 0 ..< 60 {
		run_until(w, w.now + 1_000_000_000, true)
		files := make([dynamic]Disk_File, w.allocator)
		disk_walk(&b.disk, &files, w.allocator)
		for f in files {
			if strings.has_suffix(f.path, want) {
				path = f.path
			}
		}
		if got, _ := _bm_file(w, b, tree); path != "" && got == full {
			break
		}
	}
	if path == "" {
		world_fail(w, "buffer missing: the reader never stored the append's blob, so the check proves nothing")
		return
	}
	hidden := strings.concatenate({path, ".hidden"}, w.allocator)
	if kind == .Io {
		b.disk.fail_read = path
	} else if prim.rename(disk_vfs(&b.disk), path, hidden) != .None {
		world_fail(w, "buffer missing: lose the blob")
		return
	}
	b.partitioned = kind == .Sends_Back
	if b.partitioned {
		for cn in b.conns {
			conn_reset(cn, true)
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	lose: {
		context = instance_context(&b.inst)
		defer node_after(b)
		h := b.e.handles[tree.id]
		if h != nil && h.hist != nil && h.hist.blob_data != nil {
			delete(h.hist.blob_data, h.hist.allocator)
			h.hist.blob_data = nil
			h.hist.blob_cache = {}
		}
		c.open = true
		eng.buffer_kick(&b.e, id)
	}
	run_until(w, w.now + 100_000_000, true)
	shown, rev, terr := _bm_text(w, b, id)
	world_note(w, "buffer missing: just after the loss the buffer shows %d bytes, %d zeros, %v", len(shown), strings.count(shown, "\x00"), terr)
	switch kind {
	case .Unread_Once:
		prim.rename(disk_vfs(&b.disk), hidden, path)
	case .Lost, .Sends_Back:
		prim.remove(disk_vfs(&b.disk), hidden)
	case .Io:
		if len(shown) != len(small) {
			world_fail(w, "buffer missing: the buffer shows %d bytes while its blob does not read, so the check proves nothing", len(shown))
		}
		b.disk.fail_read = ""
		run_until(w, w.now + 30_000_000_000, true)
		idle, _, _ := _bm_text(w, b, id)
		world_note(w, "buffer missing: idle for 30 s with the blob readable the buffer shows %d bytes", len(idle))
		context = instance_context(&b.inst)
		_, oerr := eng.tree_create(&b.e, space, "unrelated")
		node_after(b)
		run_until(w, w.now + 2_000_000_000, true)
		after, _, _ := _bm_text(w, b, id)
		if oerr != .None || after != full {
			world_fail(w, "buffer missing: an unrelated write left the buffer at %d bytes after its blob read again (%v)", len(after), oerr)
		}
		shown, rev, terr = _bm_text(w, b, id)
	}
	if kind == .Sends_Back {
		if terr == .None {
			context = instance_context(&b.inst)
			_, _, serr := eng.buffer_edit(&b.e, id, rev, []eng.Buffer_Edit{{0, len(shown), transmute([]u8)shown}}, 1)
			node_after(b)
			world_note(w, "buffer missing: sending back the %d bytes shown (%d zeros): %v, closed %d %v", len(shown), strings.count(shown, "\x00"), serr, c.closed, c.err)
		}
		run_until(w, w.now + 5_000_000_000, true)
		b.partitioned = false
		run_until(w, w.now + 60_000_000_000, true)
		last, _, _ := _bm_text(w, b, id)
		for n in ([]^Node{a, b}) {
			got, err := _bm_file(w, n, tree)
			if err != .None || strings.contains(got, "\x00") || !strings.contains(got, string(big)) {
				world_fail(w, "buffer missing: after a client sent back what it was shown, %s's file is %d bytes with %d zeros (%v)", n.name, len(got), strings.count(got, "\x00"), err)
			}
		}
		if c.zeros > 0 || strings.contains(last, "\x00") || !strings.contains(last, string(big)) {
			world_fail(w, "buffer missing: the client was shown %d zeros and its buffer ends at %d bytes", c.zeros, len(last))
		}
		return
	}
	if strings.contains(shown, "\x00") {
		world_fail(w, "buffer missing: the buffer shows %d zero bytes as text", strings.count(shown, "\x00"))
	}
	if terr == .None {
		context = instance_context(&b.inst)
		_, _, e1 := eng.buffer_edit(&b.e, id, rev, []eng.Buffer_Edit{{0, 0, transmute([]u8)string("typed ")}}, 1)
		node_after(b)
		run_until(w, w.now + 2_000_000_000, true)
		t2, r2, _ := _bm_text(w, b, id)
		at := strings.index(t2, "\x00")
		if at < 0 {
			at = max(len(t2) - 16, 0)
		}
		context = instance_context(&b.inst)
		_, _, e2 := eng.buffer_edit(&b.e, id, r2, []eng.Buffer_Edit{{at, 16, nil}}, 2)
		done, e3 := eng.buffer_undo(&b.e, id)
		node_after(b)
		world_note(w, "buffer missing: type %v; delete 16 at %d of %d %v; undo %v %v", e1, at, len(t2), e2, done, e3)
	}
	run_until(w, w.now + 60_000_000_000, true)
	typed := strings.concatenate({"typed ", full}, w.allocator)
	last, _, lerr := _bm_text(w, b, id)
	if lerr != .None || last != typed || c.zeros > 0 {
		world_fail(w, "buffer missing: with no user action the buffer ends at %d bytes (%d zeros, %v), want %d", len(last), strings.count(last, "\x00"), lerr, len(typed))
	}
	for n in ([]^Node{a, b}) {
		got, err := _bm_file(w, n, tree)
		if err != .None || got != typed {
			world_fail(w, "buffer missing: %s's file is %d bytes with %d zeros in history (%v), want %d", n.name, len(got), strings.count(got, "\x00"), err, len(typed))
		}
	}
}

@(test)
buffer_missing :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	cfg := default_config(1)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	for kind in Bm_Case {
		w := new(World)
		world_init(w, cfg)
		_bm(w, kind)
		for f in w.failures {
			fmt.eprintf("buffer_missing %v: %s\n", kind, f)
		}
		testing.expect(t, len(w.failures) == 0, "buffer_missing failed")
		world_destroy(w)
		free(w)
	}
}
