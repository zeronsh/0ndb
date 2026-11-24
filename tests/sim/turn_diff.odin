package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/obj"
import "../../src/prim"
import rt "../../src/runtime"

TD_ROOT :: "/home/sim/turns"

@(private = "file")
Td_Ctx :: struct {
	w:      ^World,
	n:      ^Node,
	vfs:    prim.Vfs,
	tree:   eng.Object,
	conv:   eng.Object,
	agent:  prim.Id,
	tok:    int,
	parent: obj.Rid,
	files:  map[string][dynamic]string,
	agents: map[string]bool,
	alloc:  runtime.Allocator,
	turns:  [dynamic]Td_Turn,
	nfiles: int,
	lines:  int,
}

@(private = "file")
Td_Turn :: struct {
	msg:    obj.Rid,
	before: map[string][]string,
	after:  map[string][]string,
	moved:  map[string]string,
}

@(private = "file")
_td_mount :: proc(c: ^Td_Ctx) -> ^fs.Mount {
	for &x in c.n.mounts {
		if x.root == TD_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_td_disk_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
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
_td_blob :: proc(c: ^Td_Ctx) -> []u8 {
	m := _td_mount(c)
	b := make([dynamic]u8, c.alloc)
	pw := prim.writer(&b)
	prim.write_uvarint(&pw, 1)
	prim.write_str(&pw, "work")
	prim.write_bytes(&pw, rt.version_encode(fs.mount_synced(m), "", ""))
	return b[:]
}

@(private = "file")
_td_model :: proc(c: ^Td_Ctx) -> map[string][]string {
	out := make(map[string][]string, c.alloc)
	for k, v in c.files {
		out[k] = slice.clone(v[:], c.alloc)
	}
	return out
}

@(private = "file")
_td_flush :: proc(c: ^Td_Ctx, name: string, agent: bool) -> bool {
	n := c.n
	abs := strings.concatenate({TD_ROOT, "/", name}, context.temp_allocator)
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _td_mount(c)
	if m == nil {
		return false
	}
	scope: ^fs.Scope
	if agent {
		sid := prim.id_new_with(node_clock(&n.clock), rng_random(&c.w.rng))
		scope = fs.scope_open(n.reg, m, sid, c.agent)
		if abs in n.writers {
			n.writers[abs] = Writer_Info{scope = scope, agent = true}
		} else {
			n.writers[strings.clone(abs, c.w.allocator)] = Writer_Info{scope = scope, agent = true}
		}
		fs.mount_observe_begin(m, name, scope)
	}
	err: prim.Error
	if lines, ok := c.files[name]; ok {
		b := strings.builder_make(context.temp_allocator)
		for x in lines {
			strings.write_string(&b, x)
			strings.write_byte(&b, '\n')
		}
		err = _td_disk_write(c.vfs, abs, transmute([]u8)strings.to_string(b))
	} else {
		err = prim.remove(c.vfs, abs)
		if err == .None {
			err = prim.sync_dir(c.vfs, TD_ROOT)
		}
	}
	if scope != nil {
		fs.scope_close(n.reg, scope)
		if abs in n.writers {
			key, _ := delete_key(&n.writers, abs)
			delete(key, c.w.allocator)
		}
	} else {
		fs.mount_sync(m)
	}
	return err == .None && !n.disk.dead
}

@(private = "file")
_td_token :: proc(c: ^Td_Ctx, agent: bool) -> string {
	c.tok += 1
	t := fmt.aprintf("<%c%d>", 'a' if agent else 'p', c.tok, allocator = c.alloc)
	c.agents[t] = agent
	return t
}

@(private = "file")
_td_edit :: proc(c: ^Td_Ctx, agent: bool, moved: ^map[string]string) -> bool {
	w := c.w
	names := make([dynamic]string, context.temp_allocator)
	for k in c.files {
		append(&names, k)
	}
	slice.sort(names[:])
	pick := rng_int(&w.rng, 10) if agent else rng_int(&w.rng, 6)
	if len(names) == 0 {
		pick = 7
	}
	switch {
	case pick < 4:
		name := names[rng_int(&w.rng, len(names))]
		lines := &c.files[name]
		append(lines, _td_token(c, agent))
		return _td_flush(c, name, agent)
	case pick < 7:
		name := names[rng_int(&w.rng, len(names))]
		lines := &c.files[name]
		if len(lines) == 0 {
			append(lines, _td_token(c, agent))
		} else {
			lines[rng_int(&w.rng, len(lines))] = _td_token(c, agent)
		}
		return _td_flush(c, name, agent)
	case pick < 9 || len(names) < 2:
		name := fmt.aprintf("f%d.txt", c.tok + 1, allocator = c.alloc)
		lines := make([dynamic]string, c.alloc)
		for _ in 0 ..< 1 + rng_int(&w.rng, 3) {
			append(&lines, _td_token(c, agent))
		}
		c.files[name] = lines
		return _td_flush(c, name, agent)
	case:
		name := names[rng_int(&w.rng, len(names))]
		if rng_chance(&w.rng, 1, 2) {
			nn := fmt.aprintf("m%d.txt", c.tok + 1, allocator = c.alloc)
			c.tok += 1
			lines := c.files[name]
			delete_key(&c.files, name)
			c.files[nn] = lines
			n := c.n
			context = instance_context(&n.inst)
			defer node_after(n)
			m := _td_mount(c)
			if m == nil {
				return false
			}
			sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
			scope := fs.scope_open(n.reg, m, sid, c.agent)
			fs.mount_observe_begin(m, nn, scope)
			err := prim.rename(c.vfs, strings.concatenate({TD_ROOT, "/", name}, context.temp_allocator), strings.concatenate({TD_ROOT, "/", nn}, context.temp_allocator))
			if err == .None {
				err = prim.sync_dir(c.vfs, TD_ROOT)
			}
			fs.mount_sync(m)
			fs.scope_close(n.reg, scope)
			orig := name
			if was, had := moved[name]; had {
				orig = was
				delete_key(moved, name)
			}
			moved[nn] = orig
			return err == .None
		}
		delete_key(&c.files, name)
		return _td_flush(c, name, true)
	}
}

@(private = "file")
_td_msg :: proc(c: ^Td_Ctx, role: convo.Role, files: []convo.File_Delta) -> (msg: obj.Rid, ok: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, c.conv)
	if werr != .None {
		world_fail(c.w, "turn diff: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = c.parent, files = files})
	if merr != .None {
		world_fail(c.w, "turn diff: writer_message: %v", merr)
		return
	}
	convo.writer_commit(wr)
	c.parent = m
	return m, true
}

@(private = "file")
_td_turn :: proc(c: ^Td_Ctx, person: bool) -> bool {
	w := c.w
	t := Td_Turn{before = _td_model(c), moved = make(map[string]string, c.alloc)}
	before: []u8
	files: []convo.File_Delta
	{
		context = instance_context(&c.n.inst)
		m := _td_mount(c)
		fs.mount_sync(m)
		before = _td_blob(c)
		files = make([]convo.File_Delta, 1, c.alloc)
		files[0] = convo.File_Delta{mount = "work", tree = c.tree.id, version = rt.version_encode(fs.mount_synced(m), "", "", c.alloc)}
		node_after(c.n)
	}
	if _, ok := _td_msg(c, .User, nil); !ok {
		return false
	}
	reply, pok := _td_msg(c, .Assistant, files)
	if !pok {
		return false
	}
	t.msg = reply
	for _ in 0 ..< 1 + rng_int(&w.rng, 4) {
		if !_td_edit(c, true, &t.moved) {
			return false
		}
		run_until(w, w.now + 500_000_000, true)
	}
	if person && !_td_edit(c, false, &t.moved) {
		return false
	}
	run_until(w, w.now + 1_000_000_000, true)
	{
		n := c.n
		context = instance_context(&n.inst)
		defer node_after(n)
		m := _td_mount(c)
		fs.mount_sync(m)
		after := _td_blob(c)
		wr, werr := eng.convo_writer(&n.e, c.conv)
		if werr != .None {
			world_fail(w, "turn diff: convo_writer: %v", werr)
			return false
		}
		sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		convo.writer_scope(wr, reply, .Turn, sid, c.agent, before, after)
		if _, serr := convo.writer_seal(wr, reply, .Done); serr != .None {
			world_fail(w, "turn diff: writer_seal: %v", serr)
			return false
		}
		convo.writer_commit(wr)
	}
	t.after = _td_model(c)
	append(&c.turns, t)
	run_until(w, w.now + 1_000_000_000, true)
	return true
}

@(private = "file")
_td_apply :: proc(before: []string, patch: string) -> (out: [dynamic]string, ok: bool) {
	out = make([dynamic]string, context.temp_allocator)
	pos := 0
	at := 0
	lines := strings.split_lines(strings.trim_suffix(patch, "\n"), context.temp_allocator)
	if len(lines) < 2 || !strings.has_prefix(lines[0], "--- ") || !strings.has_prefix(lines[1], "+++ ") {
		return out, false
	}
	for l in lines[2:] {
		switch {
		case strings.has_prefix(l, "@@ -"):
			rest := l[4:]
			sp := strings.index_byte(rest, ' ')
			if sp < 0 {
				return out, false
			}
			r := rest[:sp]
			start, count := r, "1"
			if comma := strings.index_byte(r, ','); comma >= 0 {
				start, count = r[:comma], r[comma + 1:]
			}
			a, aok := strconv.parse_int(start)
			b, bok := strconv.parse_int(count)
			if !aok || !bok {
				return out, false
			}
			at = a - 1 if b > 0 else a
			if at < pos || at > len(before) {
				return out, false
			}
			append(&out, ..before[pos:at])
			pos = at
		case strings.has_prefix(l, " "), strings.has_prefix(l, "-"):
			if pos >= len(before) || before[pos] != l[1:] {
				return out, false
			}
			if l[0] == ' ' {
				append(&out, l[1:])
			}
			pos += 1
		case strings.has_prefix(l, "+"):
			append(&out, l[1:])
		case:
			return out, false
		}
	}
	append(&out, ..before[pos:])
	return out, true
}

@(private = "file")
_td_eq :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

@(private = "file")
_td_check :: proc(c: ^Td_Ctx, r: ^rt.Runtime, ti: int, t: ^Td_Turn) {
	w := c.w
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	got, err := rt.turn_diff(r, c.conv, t.msg, rt.Turn_Opts{patch = true, blame = true, max_chars = 1 << 24}, context.temp_allocator)
	if err != .None {
		world_fail(w, "turn diff: turn %d: turn_diff: %v", ti, err)
		return
	}
	if !got.ended || got.msg != t.msg || got.actor != c.agent {
		world_fail(w, "turn diff: turn %d answers ended=%v msg=%v actor=%v", ti, got.ended, got.msg == t.msg, got.actor == c.agent)
	}
	want := make(map[string]bool, context.temp_allocator)
	for k, v in t.after {
		if old, had := t.before[k]; !had || !_td_eq(old, v) {
			want[k] = true
		}
	}
	for k in t.before {
		if k not_in t.after {
			want[k] = true
		}
	}
	for k, from in t.moved {
		if k in t.after && from in t.before && from not_in t.after {
			want[from] = true
		}
	}
	seen := make(map[string]bool, context.temp_allocator)
	added, removed := 0, 0
	for f in got.files {
		if f.mount != "work" {
			world_fail(w, "turn diff: turn %d: file %s on mount %q", ti, f.path, f.mount)
			continue
		}
		seen[f.path] = true
		if len(f.from) > 0 {
			seen[f.from] = true
		}
		old := t.before[f.from if f.status == "moved" else f.path] or_else nil
		cur, now := t.after[f.path]
		switch f.status {
		case "added":
			if f.path in t.before && !(f.path in t.moved) {
				world_fail(w, "turn diff: turn %d: %s is added but existed at the turn's start", ti, f.path)
			}
			old = nil
		case "removed":
			if now {
				world_fail(w, "turn diff: turn %d: %s is removed but exists at the turn's end", ti, f.path)
			}
			cur = nil
		case "moved":
			if t.moved[f.path] != f.from {
				world_fail(w, "turn diff: turn %d: %s moved from %q, the turn moved it from %q", ti, f.path, f.from, t.moved[f.path])
			}
		case "modified":
			if f.path not_in t.before || !now {
				world_fail(w, "turn diff: turn %d: %s is modified but is not on both sides", ti, f.path)
			}
		case:
			world_fail(w, "turn diff: turn %d: %s has status %q", ti, f.path, f.status)
		}
		if f.binary || f.clipped {
			world_fail(w, "turn diff: turn %d: %s binary=%v clipped=%v", ti, f.path, f.binary, f.clipped)
			continue
		}
		res, aok := _td_apply(old, f.patch)
		if !aok || !_td_eq(res[:], cur) {
			world_fail(w, "turn diff: turn %d: %s %s: the patch applied to the start gives %v, the turn wrote %v\n%s", ti, f.status, f.path, res[:], cur, f.patch)
		}
		plus, minus := 0, 0
		for l in strings.split_lines(f.patch, context.temp_allocator)[2:] {
			if strings.has_prefix(l, "+") {
				plus += 1
			} else if strings.has_prefix(l, "-") {
				minus += 1
			}
		}
		if plus != f.added || minus != f.removed {
			world_fail(w, "turn diff: turn %d: %s counts +%d -%d, its patch has +%d -%d", ti, f.path, f.added, f.removed, plus, minus)
		}
		added += f.added
		removed += f.removed
		c.nfiles += 1
		covered := 0
		for b in f.blame {
			if b.line_lo != covered + 1 || b.line_hi <= b.line_lo || b.line_hi - 1 > len(cur) {
				world_fail(w, "turn diff: turn %d: %s blame run %d..%d after line %d of %d", ti, f.path, b.line_lo, b.line_hi, covered, len(cur))
				break
			}
			for li in b.line_lo ..< b.line_hi {
				c.lines += 1
				tok := cur[li - 1]
				agent := c.agents[tok] or_else false
				by_conv := b.owner == c.conv.id
				if agent != by_conv || (agent && b.actor != c.agent) {
					world_fail(w, "turn diff: turn %d: %s line %d %s blames owner %v actor %v, the agent wrote it: %v", ti, f.path, li, tok, b.owner == c.conv.id, b.actor == c.agent, agent)
				}
			}
			covered = b.line_hi - 1
		}
		if covered != len(cur) {
			world_fail(w, "turn diff: turn %d: %s blame covers %d of %d lines", ti, f.path, covered, len(cur))
		}
	}
	for k in want {
		if !seen[k] {
			world_fail(w, "turn diff: turn %d changed %s but the diff leaves it out", ti, k)
		}
	}
	for k in seen {
		if !want[k] {
			world_fail(w, "turn diff: turn %d did not change %s but the diff lists it", ti, k)
		}
	}
	if added != got.added || removed != got.removed {
		world_fail(w, "turn diff: turn %d totals +%d -%d, its files sum to +%d -%d", ti, got.added, got.removed, added, removed)
	}
}

@(private = "file")
_td_run :: proc(w: ^World, alloc: runtime.Allocator) -> (turns: int, moves: int, files: int, lines: int) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "turn diff: node start")
		return
	}
	c := new(Td_Ctx, alloc)
	c.w = w
	c.n = n
	c.vfs = disk_vfs(&n.disk)
	c.alloc = alloc
	c.files = make(map[string][dynamic]string, alloc)
	c.agents = make(map[string]bool, alloc)
	c.turns = make([dynamic]Td_Turn, alloc)
	m := &w.model
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "turns")
		if err != .None {
			world_fail(w, "turn diff: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		c.tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "turn diff: tree_create: %v", err)
			return
		}
		c.conv, err = eng.convo_create(&n.e, space, eng.Convo_Settings{title = "turns"})
		if err != .None {
			world_fail(w, "turn diff: convo_create: %v", err)
			return
		}
		if merr := eng.convo_mount(&n.e, c.conv, "work", c.tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "turn diff: convo_mount: %v", merr)
			return
		}
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	prim.mkdir_all(c.vfs, TD_ROOT, 0o755)
	for name in ([]string{"a.txt", "b.txt"}) {
		lines := make([dynamic]string, alloc)
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 3 {
			t := _td_token(c, false)
			append(&lines, t)
			strings.write_string(&b, t)
			strings.write_byte(&b, '\n')
		}
		c.files[strings.clone(name, alloc)] = lines
		_td_disk_write(c.vfs, strings.concatenate({TD_ROOT, "/", name}, context.temp_allocator), transmute([]u8)strings.to_string(b))
	}
	if err := node_mount(w, n, oi, TD_ROOT); err != .None {
		world_fail(w, "turn diff: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(TD_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		mt := _td_mount(c)
		if mt == nil {
			world_fail(w, "turn diff: mount missing")
			return
		}
		actor, pseudo := eng.scope_actor(&n.e, c.conv.id, mt.id, mt.line)
		c.agent = actor
		context = eng.context_for(&n.e)
		fs.history_register_owned_actor(mt.history, actor, pseudo, c.conv.id)
	}
	count := 3 + rng_int(&w.rng, 4)
	for i in 0 ..< count {
		if !_td_turn(c, rng_chance(&w.rng, 1, 2)) {
			world_fail(w, "turn diff: turn %d failed", i)
			return
		}
	}
	r := new(rt.Runtime, alloc)
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		if err := rt.open(r, &n.e, rt.Config{home_dir = NODE_DIR + "/home", work_root = NODE_DIR + "/work"}, context.allocator); err != .None {
			world_fail(w, "turn diff: runtime open: %v", err)
			return
		}
	}
	defer {
		context = instance_context(&n.inst)
		rt.close(r)
		node_after(n)
	}
	for &t, i in c.turns {
		_td_check(c, r, i, &t)
		for k, from in t.moved {
			if k in t.after && from in t.before {
				moves += 1
			}
		}
	}
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		hist, _, more, herr := rt.turn_history(r, c.conv, {}, 0, 40, context.temp_allocator)
		if herr != .None || more || len(hist) != len(c.turns) {
			world_fail(w, "turn diff: history lists %d turns (more %v, %v), the conversation has %d", len(hist), more, herr, len(c.turns))
			return
		}
		for h, i in hist {
			t := &c.turns[len(c.turns) - 1 - i]
			d, _ := rt.turn_diff(r, c.conv, t.msg, {}, context.temp_allocator)
			if h.msg != t.msg || !h.ended || h.added != d.added || h.removed != d.removed || len(h.files) + h.more_files != len(d.files) {
				world_fail(w, "turn diff: history entry %d is not turn %d's diff (+%d -%d %d files, diff +%d -%d %d files)", i, len(c.turns) - 1 - i, h.added, h.removed, len(h.files), d.added, d.removed, len(d.files))
			}
		}
		if len(c.turns) > 2 {
			first, at, fmore, _ := rt.turn_history(r, c.conv, {}, 1, 40, context.temp_allocator)
			second, _, _, _ := rt.turn_history(r, c.conv, at, 1, 40, context.temp_allocator)
			if len(first) != 1 || !fmore || first[0].msg != c.turns[len(c.turns) - 1].msg || len(second) != 1 || second[0].msg != c.turns[len(c.turns) - 2].msg {
				world_fail(w, "turn diff: a one-turn page and the page after it are not the last two turns")
			}
		}
	}
	return len(c.turns), moves, c.nfiles, c.lines
}

@(private = "file")
_td_world :: proc(seed: u64) -> ^World {
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
turn_diffs :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad := 0
	turns, moves, files, lines := 0, 0, 0, 0
	count := env_u64("TD_SEEDS", 20)
	for seed in u64(1) ..= count {
		w := _td_world(seed)
		a: virtual.Arena
		if virtual.arena_init_growing(&a, 1 << 20) == nil {
			tn, mv, fl, ln := _td_run(w, virtual.arena_allocator(&a))
			turns += tn
			moves += mv
			files += fl
			lines += ln
		}
		for f in w.failures {
			if bad < 30 {
				fmt.eprintf("turn_diffs seed %d: %s\n", seed, f)
			}
		}
		if len(w.failures) > 0 {
			bad += 1
		}
		world_destroy(w)
		free(w)
		virtual.arena_destroy(&a)
	}
	fmt.eprintf("turn_diffs: %d seeds, %d turns, %d files and %d blamed lines checked, %d moves, %d failed\n", count, turns, files, lines, moves, bad)
	testing.expect(t, bad == 0, fmt.tprintf("turn_diffs: %d failures", bad))
	testing.expect(t, turns > 0 && files > 0 && lines > 0 && moves > 0, "turn_diffs: the case checked no turn, file, blamed line or move")
}
