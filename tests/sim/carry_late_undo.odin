package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fshist"
import "../../src/obj"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
LATE_TURN_ROOT :: "/work/carry-late-undo-git"

@(private = "file")
LATE_TURN_FEATURE :: "git:refs/heads/feature"

@(private = "file")
LATE_TURN_TEXT :: "agent turn line\n"

@(private = "file")
LATE_TURN_PERSON :: "person later line\n"

@(private = "file")
Late_Turn_World :: struct {
	node: int,
	drop: osync.Stream_Id,
	on:   bool,
	hits: int,
	reader: int,
	events: int,
}

@(private = "file")
_late_turn: ^Late_Turn_World

@(init)
_carry_late_undo_init :: proc "contextless" () {
	register_world(68, _late_turn_init, _late_turn_destroy)
	register_engine_event(68, _late_turn_event)
	register_frame_filter(14, _late_turn_filter)
}

@(private = "file")
_late_turn_init :: proc(w: ^World) {
	_late_turn = new(Late_Turn_World, w.allocator)
	_late_turn.node = -1
}

@(private = "file")
_late_turn_destroy :: proc(w: ^World) {
	if _late_turn == nil {
		return
	}
	frame_filter_enable(false)
	free(_late_turn, w.allocator)
	_late_turn = nil
}

@(private = "file")
_late_turn_event :: proc(w: ^World, n: ^Node, ev: ^eng.Event) {
	if _late_turn != nil && _late_turn.reader > 0 && n.idx == _late_turn.reader - 1 {
		_late_turn.events += 1
	}
}

@(private = "file")
_late_turn_filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> bool {
	if _late_turn == nil || !_late_turn.on || c.node.idx != _late_turn.node || kind != 0x85 || len(payload) < 32 {
		return false
	}
	x := _late_turn.drop
	if string(payload[:32]) != string(x[:]) {
		return false
	}
	_late_turn.hits += 1
	return true
}

@(private = "file")
_late_turn_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_late_turn_msg :: proc(w: ^World, n: ^Node, conv: eng.Object, role: convo.Role, parent: obj.Rid, files: []convo.File_Delta) -> (msg: obj.Rid, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, conv)
	if werr != .None {
		world_fail(w, "carry late undo: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = parent, files = files})
	if merr != .None {
		world_fail(w, "carry late undo: writer_message: %v", merr)
		return
	}
	convo.writer_commit(wr)
	return m, true
}

carry_late_undo_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_carry_late_undo(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_late_turn_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == LATE_TURN_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_late_turn_read :: proc(n: ^Node, tree: eng.Object, line: string) -> (string, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	if err != .None {
		return fmt.aprintf("<%v>", err, allocator = n.w.allocator), false
	}
	return strings.clone(string(data), n.w.allocator), true
}

@(private = "file")
_carry_late_undo :: proc(w: ^World) {
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
	tree, conv: eng.Object
	proofs: [2][]u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "late", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "carry late undo: space setup: %v", err)
			return
		}
		space = id
		for n, i in ([]^Node{b, c}) {
			p, perr := eng.member_add(&a.e, space, n.identity, .Device, .Admin, .Approval, 0, w.allocator)
			if perr != .None {
				world_fail(w, "carry late undo: member_add: %v", perr)
				return
			}
			proofs[i] = p
		}
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "carry late undo: tree_create: %v", err)
			return
		}
		conv, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "carry"})
		if err != .None {
			world_fail(w, "carry late undo: convo_create: %v", err)
			return
		}
		if merr := eng.convo_mount(&a.e, conv, "work", tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "carry late undo: convo_mount: %v", merr)
			return
		}
	}
	for n, i in ([]^Node{b, c}) {
		context = instance_context(&n.inst)
		if _, jerr := eng.space_join_enrollment(&n.e, space, proofs[i], "late", "relay", w.relay.public); jerr != .None {
			world_fail(w, "carry late undo: join: %v", jerr)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("shared a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	when_s := clock_wall(&a.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, LATE_TURN_ROOT, files[:], when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry late undo: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}}
	if err := git_branch_commit(vfs, LATE_TURN_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry late undo: branch commit: %v", err)
		return
	}
	if err := node_mount(w, a, oi, LATE_TURN_ROOT); err != .None {
		world_fail(w, "carry late undo: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = a.idx, oi = oi, root = strings.clone(LATE_TURN_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, LATE_TURN_ROOT, "feature", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "carry late undo: checkout feature: %v %v", res, err)
		return
	}
	tick: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	seen := false
	for _ in 0 ..< 30 {
		if d, rok := _late_turn_read(b, tree, LATE_TURN_FEATURE); rok && len(d) > 0 {
			seen = true
			break
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	if !seen {
		world_fail(w, "carry late undo: the reader never read the tree, so the check proves nothing")
		return
	}
	cvfs := disk_vfs(&c.disk)
	if err := git_checkout_create(cvfs, LATE_TURN_ROOT, files[:], when_s, node_clock(&c.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry late undo: third checkout: %v", err)
		return
	}
	if err := git_branch_commit(cvfs, LATE_TURN_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&c.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry late undo: third branch commit: %v", err)
		return
	}
	if err := node_mount(w, c, oi, LATE_TURN_ROOT); err != .None {
		world_fail(w, "carry late undo: third mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = c.idx, oi = oi, root = strings.clone(LATE_TURN_ROOT, w.allocator)})
	run_until(w, w.now + 3_000_000_000, true)
	cch := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(cvfs, LATE_TURN_ROOT, "feature", false, when_s, node_clock(&c.clock), rng_random(&w.rng), &cch); res != .Done || err != .None {
		world_fail(w, "carry late undo: third checkout feature: %v %v", res, err)
		return
	}
	third: {
		context = instance_context(&c.inst)
		node_after(c)
	}
	run_until(w, w.now + 5_000_000_000, true)
	base: [dynamic]u8
	main_base: {
		context = instance_context(&c.inst)
		defer node_after(c)
		v, verr := eng.tree_version(&c.e, tree, "main", context.temp_allocator)
		if verr != .None {
			world_fail(w, "carry late undo: main version: %v", verr)
			return
		}
		vb := make([dynamic]u8, context.temp_allocator)
		fs.encode_version(&vb, v)
		base = make([dynamic]u8, w.allocator)
		bw := prim.writer(&base)
		prim.write_bytes(&bw, vb[:])
		prim.write_str(&bw, "")
		prim.write_str(&bw, "")
	}
	user, uok := _late_turn_msg(w, c, conv, .User, {}, nil)
	if !uok {
		return
	}
	delta := []convo.File_Delta{{mount = "work", tree = tree.id, version = base[:]}}
	reply, rok2 := _late_turn_msg(w, c, conv, .Assistant, user, delta)
	if !rok2 {
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	_late_turn_read(b, tree, LATE_TURN_FEATURE)
	ids: {
		name := osync.object_segment_name(u8(eng.Kind.File_Tree), tree.id, context.temp_allocator)
		sp, sok := b.e.spaces[space]
		if !sok {
			world_fail(w, "carry late undo: the reader has no space")
			return
		}
		found := false
		for _, rm in sp.repl.remotes {
			if rm.name == name && (rm.device == a.identity.id || rm.device == c.identity.id) {
				_late_turn.drop = osync.stream_id(&rm.scope, c.identity.id, name, 0)
				found = true
				break
			}
		}
		if !found {
			world_fail(w, "carry late undo: the reader has no remote for the mount's segment of the tree")
			return
		}
	}
	_late_turn.node = b.idx
	_late_turn.on = true
	frame_filter_enable(true)
	agent: prim.Id
	turn: {
		context = instance_context(&c.inst)
		defer node_after(c)
		sm := _late_turn_mount(c)
		if sm == nil || fs.mount_line(sm.m) != LATE_TURN_FEATURE {
			world_fail(w, "carry late undo: the third device's mount did not follow feature")
			return
		}
		pseudo := fs.scope_pseudo(conv.id, sm.m.id, sm.m.line)
		agent = fshist.ingestion_actor(sm.m.history.self, pseudo)
		if oerr := fs.history_register_owned_actor(sm.m.history, agent, pseudo, conv.id); oerr != .None {
			world_fail(w, "carry late undo: register the turn's actor: %v", oerr)
			return
		}
		scope := fs.scope_open(c.reg, sm.m, prim.id_new_with(node_clock(&c.clock), rng_random(&w.rng)), agent)
		if oerr := fs.mount_observe_begin(sm.m, "a.txt", scope); oerr != .None {
			world_fail(w, "carry late undo: observe: %v", oerr)
			return
		}
		if werr := _late_turn_write(cvfs, LATE_TURN_ROOT + "/a.txt", strings.concatenate({"shared a\n", LATE_TURN_TEXT}, context.temp_allocator)); werr != .None {
			world_fail(w, "carry late undo: agent write: %v", werr)
			return
		}
		if serr := fs.scope_close(c.reg, scope); serr != .None {
			world_fail(w, "carry late undo: scope close: %v", serr)
			return
		}
		wr, werr := eng.convo_writer(&c.e, conv)
		if werr != .None {
			world_fail(w, "carry late undo: convo_writer: %v", werr)
			return
		}
		convo.writer_scope(wr, reply, .Turn, prim.id_new_with(node_clock(&c.clock), rng_random(&w.rng)), agent, nil, nil)
		if _, sealerr := convo.writer_seal(wr, reply, .Done); sealerr != .None {
			world_fail(w, "carry late undo: writer_seal: %v", sealerr)
			return
		}
		convo.writer_commit(wr)
	}
	on_disk := false
	for _ in 0 ..< 30 {
		run_until(w, w.now + 1_000_000_000, true)
		if d, _ := prim.read_file(vfs, LATE_TURN_ROOT + "/a.txt", context.temp_allocator); strings.contains(string(d), LATE_TURN_TEXT) {
			on_disk = true
			break
		}
	}
	if !on_disk {
		world_fail(w, "carry late undo: the third device's feature write never reached the mount's disk")
		return
	}
	back := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, LATE_TURN_ROOT, "main", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &back); res != .Done || err != .None {
		world_fail(w, "carry late undo: checkout main: %v %v", res, err)
		return
	}
	step: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 20_000_000_000, true)
	main_a, ok := _late_turn_read(a, tree, "main")
	if !ok || !strings.contains(main_a, LATE_TURN_TEXT) {
		world_fail(w, "carry late undo: git did not carry the third device's line onto main on the mount (%q), so the check proves nothing", main_a)
		return
	}
	if _late_turn.hits == 0 {
		world_fail(w, "carry late undo: no frame of the source stream was withheld, so the check proves nothing")
		return
	}
	if d, rok := _late_turn_read(b, tree, LATE_TURN_FEATURE); rok && strings.contains(d, LATE_TURN_TEXT) {
		world_fail(w, "carry late undo: the reader already holds the source on feature (%q), so the check proves nothing", d)
		return
	}
	if werr := _late_turn_write(vfs, LATE_TURN_ROOT + "/a.txt", strings.concatenate({"shared a\n", LATE_TURN_TEXT, LATE_TURN_PERSON}, context.temp_allocator)); werr != .None {
		world_fail(w, "carry late undo: person write: %v", werr)
		return
	}
	person: {
		context = instance_context(&a.inst)
		defer node_after(a)
		if sm := _late_turn_mount(a); sm != nil {
			fs.mount_sync(sm.m)
		}
	}
	run_until(w, w.now + 10_000_000_000, true)
	want, wok := _late_turn_author(a, tree)
	raw, hok := _late_turn_author(b, tree)
	fmt.eprintfln("LATETURN agent %s mount-author %s reader-author %s", id_short(agent), id_short(want), id_short(raw))
	if !wok || !hok {
		world_fail(w, "carry late undo: main lacks the carried line: mount %v reader %v", wok, hok)
		return
	}
	if want == agent {
		world_fail(w, "carry late undo: the mount does not resolve the turn's actor, so the check proves nothing")
	}
	if raw != agent {
		world_fail(w, "carry late undo: before the owner record the reader shows %s, not the raw turn actor %s", id_short(raw), id_short(agent))
	}
	ready := false
	for _ in 0 ..< 40 {
		context = instance_context(&b.inst)
		st, serr := eng.convo_status(&b.e, conv)
		h, herr := eng.convo_message(&b.e, conv, {msg = reply}, context.temp_allocator)
		ready = serr == .None && herr == .None && h.parent == user && st.head == reply
		node_after(b)
		if ready {
			break
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	if !ready {
		world_fail(w, "carry late undo: the reader never loaded the turn's conversation, so its undo proves nothing")
		return
	}
	if who, got := _late_turn_author(b, tree); !got || who != agent {
		world_fail(w, "carry late undo: the owner record arrived with the conversation (%s), so the undo proves nothing", id_short(who))
		return
	}
	undo_err := eng.Error.None
	undo: {
		context = instance_context(&b.inst)
		defer node_after(b)
		eng.undo_hooks_set(&b.e, eng.Undo_Hooks{})
		_, undo_err = eng.convo_undo(&b.e, conv, user)
	}
	run_until(w, w.now + 20_000_000_000, true)
	mid, _ := _late_turn_read(b, tree, "main")
	fmt.eprintfln("LATETURN undo before the record: %v; reader main %q", undo_err, mid)
	if undo_err == .None && strings.contains(mid, LATE_TURN_TEXT) {
		world_fail(w, "carry late undo: the undo reported success before the owner record but left the carried line on the reader's main: %q", mid)
	}
	_late_turn.reader = b.idx + 1
	_late_turn.on = false
	for cn in b.conns {
		conn_reset(cn, true)
	}
	for _ in 0 ..< 60 {
		run_until(w, w.now + 500_000_000, true)
		if who, got := _late_turn_author(b, tree); got && who != agent && who != want {
			world_fail(w, "carry late undo: while resolving, the reader credits the carried line to %s, neither the raw actor nor its owner", id_short(who))
			break
		}
	}
	_late_turn.reader = 0
	if undo_err != .None {
		context = instance_context(&b.inst)
		_, undo_err = eng.convo_undo(&b.e, conv, user)
		node_after(b)
		fmt.eprintfln("LATETURN undo after the record: %v", undo_err)
		if undo_err != .None {
			world_fail(w, "carry late undo: the undo still fails after the owner record: %v", undo_err)
		}
	}
	run_until(w, w.now + 40_000_000_000, true)
	for n in ([]^Node{a, b, c}) {
		d, rok := _late_turn_read(n, tree, "main")
		if !rok || strings.contains(d, LATE_TURN_TEXT) || !strings.contains(d, LATE_TURN_PERSON) {
			world_fail(w, "carry late undo: after the undo %s reads main a.txt as %q (%v), want the turn's line gone and the person's kept", n.name, d, rok)
		}
	}
}

@(private = "file")
_late_turn_author :: proc(n: ^Node, tree: eng.Object) -> (who: prim.Id, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, spans, err := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, "main")
	if err != .None {
		return {}, false
	}
	lo := strings.index(string(data), LATE_TURN_TEXT)
	at := 0
	for sp in spans {
		if lo >= 0 && at <= lo && lo < at + sp.len {
			return sp.id.actor, true
		}
		at += sp.len
	}
	return {}, false
}

@(test)
carry_late_undo :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := carry_late_undo_run(1)
	for f in failures {
		fmt.eprintf("carry_late_undo: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "carry_late_undo failed")
	delete(failures)
}
