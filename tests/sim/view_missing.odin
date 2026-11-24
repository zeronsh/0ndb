package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/odb"
import "../../src/prim"

@(private = "file")
VM_ROOT :: "/work/vm-n0"

@(private = "file")
VM_BIG :: 300_000

@(private = "file")
Vm_Client :: struct {
	text:   [dynamic]u8,
	events: int,
}

@(private = "file")
_vm_sink :: proc(c: ^Vm_Client) -> crdt.Text_Sink {
	return crdt.Text_Sink {
		data = c,
		insert = proc(data: rawptr, pos: int, bytes: []u8, author: crdt.Op_Id) {
			c := (^Vm_Client)(data)
			c.events += 1
			inject_at(&c.text, pos, ..bytes)
		},
		delete = proc(data: rawptr, pos: int, bytes: []u8) {
			c := (^Vm_Client)(data)
			c.events += 1
			remove_range(&c.text, pos, pos + len(bytes))
		},
	}
}

@(private = "file")
_vm :: proc(w: ^World) {
	if !relay_start(&w.relay) || !node_start(w.nodes[0]) {
		world_fail(w, "start")
		return
	}
	a := w.nodes[0]
	m := &w.model
	vfs := disk_vfs(&a.disk)
	tree: eng.Object
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "vm", "relay", w.relay.public)
		if err == .None {
			err = eng.space_open(&a.e, id)
		}
		if err == .None {
			tree, err = eng.tree_create(&a.e, id, "work")
		}
		if err != .None {
			world_fail(w, "view missing: setup: %v", err)
			return
		}
	}
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	small := "first line\n"
	big := make([]u8, VM_BIG, w.allocator)
	for i in 0 ..< VM_BIG {
		big[i] = '\n' if i % 61 == 60 else u8('a' + (i * 7 + i / 61) % 26)
	}
	full := strings.concatenate({small, string(big)}, w.allocator)
	if prim.mkdir_all(vfs, VM_ROOT, 0o755) != .None || prim.replace_atomic(vfs, VM_ROOT + "/a.txt", transmute([]u8)small) != .None {
		world_fail(w, "view missing: disk setup")
		return
	}
	if err := node_mount(w, a, len(m.objs) - 1, VM_ROOT); err != .None {
		world_fail(w, "view missing: mount: %v", err)
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	client: Vm_Client
	client.text = make([dynamic]u8, w.allocator)
	append(&client.text, small)
	context = instance_context(&a.inst)
	defer node_after(a)
	mnt := a.mounts[0].m
	hist := mnt.history
	werr := fs.mount_wake(mnt)
	if werr == .None {
		werr = fs.history_wake(hist)
	}
	e, found, _ := fs.shadow_get(&mnt.shadow, "a.txt")
	if werr != .None || !found {
		world_fail(w, "view missing: the file was never ingested: %v", werr)
		return
	}
	view, verr := fs.history_view_open(hist, e.inode, fs.history_heads(hist, context.temp_allocator))
	if verr != .None || string(crdt.text_bytes(&view.text, context.temp_allocator)) != small {
		world_fail(w, "view missing: view open: %v", verr)
		return
	}
	defer fs.history_view_close(hist, view)
	fd, oerr := prim.open_file(vfs, VM_ROOT + "/a.txt", {.Write})
	if oerr != .None || prim.write_at(vfs, fd, big, i64(len(small))) != .None || prim.close_file(vfs, fd) != .None {
		world_fail(w, "view missing: append")
		return
	}
	if serr := fs.mount_sync(mnt); serr != .None || odb.barrier(mnt.db) != .None {
		world_fail(w, "view missing: ingest: %v", serr)
		return
	}
	hb: [odb.MAX_HEX]u8
	oid, _ := odb.hash(.Sha1, .Blob, big)
	hex := odb.oid_to_string(oid, .Sha1, &hb)
	want := strings.concatenate({"/", hex[:2], "/", hex[2:]}, w.allocator)
	path := ""
	files := make([dynamic]Disk_File, w.allocator)
	disk_walk(&a.disk, &files, w.allocator)
	for f in files {
		if strings.has_suffix(f.path, want) {
			path = f.path
		}
	}
	if path == "" || view.stale {
		world_fail(w, "view missing: blob %q, view stale %v: the merge path would not run, so the check proves nothing", path, view.stale)
		return
	}
	hidden := strings.concatenate({path, ".hidden"}, w.allocator)
	if prim.rename(vfs, path, hidden) != .None {
		world_fail(w, "view missing: hide")
		return
	}
	for step in 0 ..< 3 {
		if step == 2 && prim.rename(vfs, hidden, path) != .None {
			world_fail(w, "view missing: restore")
			return
		}
		if hist.blob_data != nil {
			delete(hist.blob_data, hist.allocator)
			hist.blob_data = nil
			hist.blob_cache = {}
		}
		try: Vm_Client
		try.text = make([dynamic]u8, w.allocator)
		append(&try.text, small)
		reloaded, err := fs.history_view_advance_ex(hist, view, fs.history_heads(hist, context.temp_allocator), _vm_sink(&try))
		got := crdt.text_bytes(&view.text, context.temp_allocator)
		if step < 2 {
			if err == .None {
				world_fail(w, "view missing: try %d with the blob missing returned success, %d zero bytes sent", step, strings.count(string(try.text[:]), "\x00"))
			}
			if try.events != 0 || string(got) != small {
				world_fail(w, "view missing: try %d with the blob missing sent %d events and left the view at %d bytes, want %d", step, try.events, len(got), len(small))
			}
			continue
		}
		if err != .None || string(got) != full {
			world_fail(w, "view missing: with the blob back the view is %v, %d bytes, want %d", err, len(got), len(full))
		}
		if reloaded {
			world_fail(w, "view missing: the last advance reloaded instead of merging")
		}
		if string(try.text[:]) != full {
			world_fail(w, "view missing: with the blob back a client that applied only successful advances holds %d bytes, want %d", len(try.text), len(full))
		}
	}
}

@(test)
view_missing :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	cfg := default_config(1)
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
	_vm(w)
	for f in w.failures {
		fmt.eprintf("view_missing: %s\n", f)
	}
	testing.expect(t, len(w.failures) == 0, "view_missing failed")
	world_destroy(w)
	free(w)
}
