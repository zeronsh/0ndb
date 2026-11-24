package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"
import "../../src/journal"

@(test)
step_size :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	edits := int(env_u64("SS_EDITS", 1000))
	big := int(env_u64("SS_SIZE", 400))
	cfg := default_config(1)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.durability = .Async
	cfg.mem_max = 1500
	w := new(World)
	world_init(w, cfg)
	defer {
		world_destroy(w)
		free(w)
	}
	n := w.nodes[0]
	node_start(n)
	vfs := disk_vfs(&n.disk)
	root := "/work/size-n0-git"
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, _ := eng.space_create(&n.e, "size")
		eng.space_open(&n.e, space)
		tree, _ = eng.tree_create(&n.e, space, "work")
		node_after(n)
	}
	m := &w.model
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	base := make([dynamic]u8, w.allocator)
	for i in 0 ..< big {
		append(&base, ..transmute([]u8)fmt.tprintf("line %d of the file\n", i))
	}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	files := [?]Git_File{{name = "a.txt", data = base[:]}}
	git_checkout_create(vfs, root, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng))
	node_mount(w, n, oi, root)
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(root, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	sm: ^Sim_Mount
	for &x in n.mounts {
		if x.root == root {
			sm = &x
		}
	}
	h := sm.m.history
	before := journal.journal_durable_len(&h.journal)
	max_log := i64(0)
	cur := make([dynamic]u8, w.allocator)
	append(&cur, ..base[:])
	for i in 0 ..< edits {
		who := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		{
			context = instance_context(&n.inst)
			s := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), who)
			fs.scope_read_base(s, "a.txt", cur[:])
			fs.mount_observe_begin(sm.m, "a.txt", s)
			_writer_set(w, n, strings.concatenate({root, "/a.txt"}), Writer_Info{scope = s, agent = true})
			append(&cur, ..transmute([]u8)fmt.tprintf("edit %d added by the agent\n", i))
			fd, _ := prim.open_file(vfs, strings.concatenate({root, "/a.txt"}), {.Write, .Create, .Truncate}, 0o644)
			prim.write_at(vfs, fd, cur[:], 0)
			prim.datasync(vfs, fd)
			prim.close_file(vfs, fd)
			fs.scope_close(n.reg, s)
			_forget_scope(w, n, s)
			node_after(n)
		}
		max_log = max(max_log, sm.m.log_len)
		run_until(w, w.now + 20_000_000, true)
	}
	run_until(w, w.now + 4_000_000_000, true)
	after := journal.journal_durable_len(&h.journal)
	fmt.eprintf("step_size: edits=%d journal_bytes=%d per_edit=%.1f max_attrib_log=%d\n", edits, after - before, f64(after - before) / f64(edits), max_log)
}
