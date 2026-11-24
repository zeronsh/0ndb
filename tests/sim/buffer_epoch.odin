package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import osync "../../src/sync"
import "../../src/prim"

@(private = "file")
Ep :: struct {
	w:      ^World,
	a, b:   ^Node,
	text:   eng.Object,
	tree:   eng.Object,
	actors: [2]prim.Id,
	infos:  [2]eng.Buffer_Info,
	tinfo:  eng.Buffer_Info,
	rev:    [2]u64,
	trev:   u64,
}

@(private = "file")
_ep_rev :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	if ev.kind == .Delta {
		(^u64)(data)^ = ev.rev
	}
}

@(private = "file")
_ep_open :: proc(x: ^Ep, n: ^Node, i: int) -> bool {
	for _ in 0 ..< 40 {
		err: eng.Error
		{
			context = instance_context(&n.inst)
			x.infos[i], err = eng.buffer_open(&n.e, x.text, eng.Buffer_Options{units = .Bytes, actor = x.actors[i], cb = _ep_rev, data = &x.rev[i]}, x.w.allocator)
			node_after(n)
		}
		if err == .None {
			x.rev[i] = x.infos[i].rev
			return true
		}
		run_until(x.w, x.w.now + 1_000_000_000, true)
	}
	world_fail(x.w, "buffer epoch: %s's buffer did not open", n.name)
	return false
}

@(private = "file")
_ep_type :: proc(x: ^Ep, n: ^Node, i: int, pos, del: int, ins: string) {
	{
		context = instance_context(&n.inst)
		if _, _, err := eng.buffer_edit(&n.e, x.infos[i].id, x.rev[i], []eng.Buffer_Edit{{pos, del, transmute([]u8)ins}}); err != .None {
			world_fail(x.w, "buffer epoch: edit on %s: %v", n.name, err)
		}
		node_after(n)
	}
	run_until(x.w, x.w.now + 6_000_000_000, true)
}

@(private = "file")
_ep_text :: proc(x: ^Ep, n: ^Node) -> string {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.text_read(&n.e, x.text, context.temp_allocator)
	if err != .None {
		return fmt.aprintf("<%v>", err, allocator = x.w.allocator)
	}
	return strings.clone(string(data), x.w.allocator)
}

@(private = "file")
_ep_crash :: proc(x: ^Ep, n: ^Node, salt: u64) -> bool {
	node_crash_now(n, .Process, salt)
	return reissue_restarted(x.w, n)
}

@(private = "file")
_ep_stop :: proc(x: ^Ep, n: ^Node) {
	live_close(n)
	{
		context = instance_context(&n.inst)
		if err := eng.close(&n.e); err != .None {
			world_fail(x.w, "buffer epoch: close: %v", err)
		}
	}
	n.e_open = false
	osync.file_keyring_close(&n.keyring)
	n.key_open = false
	node_kill(n)
}

@(private = "file")
_ep_clean :: proc(x: ^Ep, n: ^Node) -> bool {
	_ep_stop(x, n)
	schedule(x.w, Sim_Event{at = x.w.now + 200_000_000, kind = .Restart, node = n.idx})
	return reissue_restarted(x.w, n)
}

@(private = "file")
_ep_actors :: proc(x: ^Ep, n: ^Node) -> int {
	_ep_text(x, n)
	context = instance_context(&n.inst)
	if h, ok := n.e.handles[x.text.id]; ok && h.hist != nil && h.hist.awake {
		return len(h.hist.g.actors)
	}
	return -1
}

@(private = "file")
_ep_files :: proc(x: ^Ep, n: ^Node) -> (reg: []u8, live: []u8) {
	n.disk.probe += 1
	defer n.disk.probe -= 1
	vfs := disk_vfs(&n.disk)
	reg, _ = prim.read_file(vfs, NODE_DIR + "/registry", x.w.allocator)
	live, _ = prim.read_file(vfs, NODE_DIR + "/live", x.w.allocator)
	return
}

@(private = "file")
_ep_put :: proc(x: ^Ep, n: ^Node, name: string, data: []u8) {
	n.disk.probe += 1
	defer n.disk.probe -= 1
	vfs := disk_vfs(&n.disk)
	path := strings.concatenate({NODE_DIR, "/", name}, context.temp_allocator)
	fd, err := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o600)
	if err == .None {
		err = prim.write_at(vfs, fd, data, 0)
	}
	if err == .None {
		err = prim.datasync(vfs, fd)
		prim.close_file(vfs, fd)
	}
	if err != .None {
		world_fail(x.w, "buffer epoch: put %s: %v", name, err)
	}
}

@(private = "file")
_ep_setup :: proc(x: ^Ep) -> bool {
	w := x.w
	if !relay_start(&w.relay) || !node_start(x.a) || !node_start(x.b) {
		world_fail(w, "buffer epoch: start")
		return false
	}
	space: prim.Id
	proof: []u8
	{
		context = instance_context(&x.a.inst)
		defer node_after(x.a)
		err: eng.Error
		space, err = eng.space_create(&x.a.e, "epoch", "relay", w.relay.public)
		if err == .None {
			err = eng.space_open(&x.a.e, space)
		}
		if err == .None {
			x.text, err = eng.text_create(&x.a.e, space, "notes", "base\n")
		}
		if err == .None {
			x.tree, err = eng.tree_create(&x.a.e, space, "work")
		}
		if err == .None {
			err = eng.tree_write(&x.a.e, x.tree, "a.txt", transmute([]u8)string("tree\n"), tree_base(&x.a.e, x.tree))
		}
		if err == .None {
			proof, err = eng.member_add(&x.a.e, space, x.b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		}
		if err != .None {
			world_fail(w, "buffer epoch: setup: %v", err)
			return false
		}
	}
	{
		context = instance_context(&x.b.inst)
		defer node_after(x.b)
		_, err := eng.space_join_enrollment(&x.b.e, space, proof, "epoch", "relay", w.relay.public)
		if err == .None {
			err = eng.space_open(&x.b.e, space)
		}
		if err != .None {
			world_fail(w, "buffer epoch: join: %v", err)
			return false
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	for &id in x.actors {
		id = prim.id_new_with(node_clock(&x.b.clock), rng_random(&w.rng))
	}
	return _ep_open(x, x.a, 0) && _ep_open(x, x.b, 1)
}

@(private = "file")
_ep_run :: proc(x: ^Ep, unclean: int) {
	w := x.w
	if !_ep_setup(x) {
		return
	}
	_, live := _ep_files(x, x.b)
	if x.b.e.live_epoch != 0 || len(live) != 0 {
		world_fail(w, "buffer epoch: an epoch exists before anything was sent")
	}
	if !_ep_clean(x, x.b) || !_ep_clean(x, x.b) || !_ep_open(x, x.b, 1) {
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	plain0, _ := _ep_files(x, x.b)
	for i in 0 ..< unclean {
		if !_ep_crash(x, x.b, 10_000 + u64(i)) {
			world_fail(w, "buffer epoch: unclean restart %d failed", i)
			return
		}
	}
	plain1, _ := _ep_files(x, x.b)
	if !_ep_open(x, x.b, 1) {
		return
	}
	if _, l := _ep_files(x, x.b); x.b.e.live_epoch != 0 || len(l) != 0 {
		world_fail(w, "buffer epoch: two clean restarts that sent nothing moved the epoch to %x", x.b.e.live_epoch)
	}
	run_until(w, w.now + 20_000_000_000, true)
	_ep_type(x, x.b, 1, 0, 0, "one ")
	if !x.b.e.live_armed {
		world_fail(w, "buffer epoch: a sent frame did not arm the epoch")
		return
	}
	old_reg, old_live := _ep_files(x, x.b)
	if !_ep_clean(x, x.b) || !_ep_clean(x, x.b) || !_ep_open(x, x.b, 1) {
		return
	}
	if x.b.e.live_epoch != 0 {
		world_fail(w, "buffer epoch: clean restarts after a sent frame moved the epoch")
	}
	clean_reg, clean_live := _ep_files(x, x.b)
	run_until(w, w.now + 20_000_000_000, true)
	_ep_type(x, x.b, 1, 4, 0, "two ")
	actors0 := _ep_actors(x, x.b)
	if !_ep_crash(x, x.b, 1) || !_ep_open(x, x.b, 1) {
		return
	}
	first := x.b.e.live_epoch
	if first == 0 {
		world_fail(w, "buffer epoch: an unclean restart after a sent frame kept the epoch")
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	if x.infos[1].actor != x.actors[1] {
		world_fail(w, "buffer epoch: the client sees another actor than its own")
	}
	_ep_type(x, x.b, 1, 8, 0, "three ")
	_ep_type(x, x.b, 1, 0, 4, "")
	if t := _ep_text(x, x.b); t != "two three base\n" {
		world_fail(w, "buffer epoch: text is %q before undo", t)
	}
	for want in ([]string{"one two three base\n", "one two base\n"}) {
		{
			context = instance_context(&x.b.inst)
			if done, err := eng.buffer_undo(&x.b.e, x.infos[1].id); err != .None || !done {
				world_fail(w, "buffer epoch: undo: %v %v", done, err)
			}
			node_after(x.b)
		}
		run_until(w, w.now + 6_000_000_000, true)
		if t := _ep_text(x, x.b); t != want {
			world_fail(w, "buffer epoch: undo across epochs gives %q, want %q", t, want)
		}
	}
	for _ in 0 ..< 2 {
		context = instance_context(&x.b.inst)
		if done, err := eng.buffer_redo(&x.b.e, x.infos[1].id); err != .None || !done {
			world_fail(w, "buffer epoch: redo: %v %v", done, err)
		}
		node_after(x.b)
		run_until(w, w.now + 6_000_000_000, true)
	}
	if t := _ep_text(x, x.b); t != "two three base\n" {
		world_fail(w, "buffer epoch: redo across epochs gives %q", t)
	}
	typed: {
		context = instance_context(&x.b.inst)
		info: eng.Buffer_Info
		err := eng.Error.Missing
		for _ in 0 ..< 40 {
			context = instance_context(&x.b.inst)
			info, err = eng.buffer_open(&x.b.e, x.tree, eng.Buffer_Options{path = "a.txt", units = .Bytes, actor = x.actors[1], cb = _ep_rev, data = &x.trev}, w.allocator)
			node_after(x.b)
			if err == .None {
				break
			}
			run_until(w, w.now + 1_000_000_000, true)
		}
		if err == .None {
			x.trev = info.rev
			_, _, err = eng.buffer_edit(&x.b.e, info.id, x.trev, []eng.Buffer_Edit{{0, 0, transmute([]u8)string("typed\n")}})
		}
		if err != .None {
			world_fail(w, "buffer epoch: tree buffer: %v", err)
		}
		node_after(x.b)
	}
	run_until(w, w.now + 20_000_000_000, true)
	for n in ([]^Node{x.a, x.b}) {
		context = instance_context(&n.inst)
		owners: []fs.Span_Owner
		data, spans, err := eng.tree_blame(&n.e, x.tree, "a.txt", context.temp_allocator, "", &owners)
		if err != .None || string(data) != "typed\ntree\n" || len(spans) == 0 || len(owners) != len(spans) {
			world_fail(w, "buffer epoch: blame on %s: %v %q", n.name, err, string(data))
		} else if spans[0].id.actor != x.actors[1] || owners[0].kind != .Person || owners[0].device != x.b.identity.id {
			world_fail(w, "buffer epoch: blame on %s credits the typed line to %v (%v of %v)", n.name, spans[0].id.actor, owners[0].kind, owners[0].device)
		}
		node_after(n)
	}
	{
		context = instance_context(&x.b.inst)
		for k, &v in x.b.e.live_ids {
			if k.object == x.text.id {
				v += 1000
			}
		}
		node_after(x.b)
	}
	before := x.b.e.live_epoch
	_ep_type(x, x.b, 1, 0, 0, "rewound ")
	if x.b.e.live_epoch == before || x.b.e.live_epoch == 0 {
		world_fail(w, "buffer epoch: a sequence below what was sent kept the epoch")
	}
	if ta, tb := _ep_text(x, x.a), _ep_text(x, x.b); ta != tb || !strings.has_prefix(tb, "rewound ") {
		world_fail(w, "buffer epoch: after a rewind n0 holds %q and n1 %q", ta, tb)
	}
	seen := make(map[u64]bool, w.allocator)
	seen[0] = true
	seen[first] = true
	seen[before] = true
	seen[x.b.e.live_epoch] = true
	_ep_stop(x, x.b)
	new_reg, new_live := _ep_files(x, x.b)
	for c in ([][2][]u8{{old_reg, nil}, {clean_reg, nil}, {nil, old_live}, {nil, clean_live}}) {
		_ep_put(x, x.b, "registry", new_reg)
		_ep_put(x, x.b, "live", new_live)
		if c[0] != nil {
			_ep_put(x, x.b, "registry", c[0])
		} else {
			_ep_put(x, x.b, "live", c[1])
		}
		schedule(w, Sim_Event{at = w.now + 200_000_000, kind = .Restart, node = x.b.idx})
		if !reissue_restarted(w, x.b) {
			world_fail(w, "buffer epoch: n1 did not start with an older copy")
			return
		}
		if seen[x.b.e.live_epoch] {
			world_fail(w, "buffer epoch: an older %s brought back epoch %x", "registry" if c[0] != nil else "live file", x.b.e.live_epoch)
		}
		seen[x.b.e.live_epoch] = true
		_ep_stop(x, x.b)
	}
	schedule(w, Sim_Event{at = w.now + 200_000_000, kind = .Restart, node = x.b.idx})
	if !reissue_restarted(w, x.b) || !_ep_open(x, x.b, 1) {
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	_ep_type(x, x.b, 1, 0, 0, "last ")
	actors1 := _ep_actors(x, x.b)
	reg0, live0 := _ep_files(x, x.b)
	for i in 0 ..< unclean {
		if !_ep_crash(x, x.b, 100 + u64(i)) {
			world_fail(w, "buffer epoch: unclean restart %d failed", i)
			return
		}
	}
	reg1, live1 := _ep_files(x, x.b)
	actors2 := _ep_actors(x, x.b)
	if actors0 < 0 || actors1 < 0 || actors2 != actors1 || len(live1) != len(live0) || len(reg1) - len(reg0) > len(plain1) - len(plain0) + 64 << 10 || len(x.b.e.live_ids) != 0 {
		world_fail(w, "buffer epoch: %d unclean restarts grew actors %d to %d, live file %d to %d, registry %d to %d (%d to %d before anything was sent), sent ids %d", unclean, actors1, actors2, len(live0), len(live1), len(reg0), len(reg1), len(plain0), len(plain1), len(x.b.e.live_ids))
	}
	if w.cfg.verbose {
		fmt.eprintf("buffer epoch: actors %d %d %d registry %d %d, before anything was sent %d %d\n", actors0, actors1, actors2, len(reg0), len(reg1), len(plain0), len(plain1))
	}
	if !_ep_open(x, x.b, 1) {
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	if ta, tb := _ep_text(x, x.a), _ep_text(x, x.b); ta != tb {
		world_fail(w, "buffer epoch: n0 holds %q and n1 %q", ta, tb)
	}
	check_uploaded(w)
	check_derived(x.a, "buffer epoch, n0")
	check_derived(x.b, "buffer epoch, n1")
}

@(test)
buffer_epoch :: proc(t: ^testing.T) {
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
	cfg.durability = .Async
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	x := Ep{w = w, a = w.nodes[0], b = w.nodes[1]}
	_ep_run(&x, 1000)
	for f in w.failures {
		fmt.eprintf("buffer_epoch: %s\n", f)
	}
	testing.expect(t, len(w.failures) == 0, "buffer_epoch failed")
	world_destroy(w)
	free(w)
	free_all(context.temp_allocator)
}
