package fstree_test

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import fs "../../src/fstree"
import "../../src/prim"

N :: 4

NAMES := [?]string{"a", "b", "c", "d", "e"}
TARGETS := [?]string{"x", "y", "../z"}

Rec :: struct {
	id:      fs.Op_Id,
	lamport: u64,
	op:      fs.Op,
	deps:    [N]u64,
}

Store :: struct {
	inodes: map[fs.Inode_Id][dynamic]u8,
	nodes:  map[fs.Node_Key][dynamic]u8,
}

Replica :: struct {
	tree:    fs.Tree,
	vc:      [N]u64,
	lamport: u64,
	have:    [dynamic]int,
	created: [dynamic]fs.Inode_Id,
	store:   Store,
	lazy:    bool,
	fanout:  int,
	world:   ^World,
}

World :: struct {
	actors:   [N]prim.Id,
	ops:      [dynamic]Rec,
	by_actor: [N][dynamic]int,
	names:    [dynamic]string,
}

world_destroy :: proc(w: ^World) {
	delete(w.ops)
	for a in w.by_actor {
		delete(a)
	}
	for n in w.names {
		delete(n)
	}
	delete(w.names)
	free(w)
}

own :: proc(w: ^World, s: string) -> string {
	c := strings.clone(s)
	append(&w.names, c)
	return c
}

actor_of :: proc(data: rawptr, actor: u32) -> prim.Id {
	r := (^Replica)(data)
	if actor >= N {
		return {}
	}
	return r.world.actors[actor]
}

load_inode :: proc(data: rawptr, id: fs.Inode_Id) -> ([]u8, bool, fs.Error) {
	r := (^Replica)(data)
	if b, ok := r.store.inodes[id]; ok {
		return b[:], true, nil
	}
	return nil, false, nil
}

load_node :: proc(data: rawptr, key: fs.Node_Key) -> ([]u8, bool, fs.Error) {
	r := (^Replica)(data)
	if b, ok := r.store.nodes[key]; ok {
		return b[:], true, nil
	}
	return nil, false, nil
}

load_moves :: proc(data: rawptr, from: u64, out: ^[dynamic]fs.Move_Ref) -> bool {
	r := (^Replica)(data)
	for i in r.have {
		rec := r.world.ops[i]
		if m, ok := rec.op.(fs.Op_Move); ok && rec.lamport >= from {
			append(out, fs.Move_Ref{event = {lamport = rec.lamport, seq = rec.id.seq, actor = rec.id.actor}, inode = m.inode})
		}
	}
	return true
}

replica_init :: proc(r: ^Replica, w: ^World, lazy: bool, fanout := 4, allocator := context.allocator) {
	r^ = Replica {
		world  = w,
		lazy   = lazy,
		fanout = fanout,
	}
	source := fs.Source {
		data  = r,
		actor = actor_of,
	}
	if lazy {
		source.load_inode = load_inode
		source.load_node = load_node
		source.load_moves = load_moves
	}
	_ = fs.init(&r.tree, source, 0, fanout, allocator)
}

replica_destroy :: proc(r: ^Replica) {
	fs.destroy(&r.tree)
	delete(r.have)
	delete(r.created)
	for _, b in r.store.inodes {
		delete(b)
	}
	for _, b in r.store.nodes {
		delete(b)
	}
	delete(r.store.inodes)
	delete(r.store.nodes)
}

persist :: proc(r: ^Replica, keep: int) {
	inodes, nodes, _ := fs.dirty(&r.tree, context.temp_allocator)
	for id in inodes {
		buf := make([dynamic]u8)
		if fs.encode_inode_record(&r.tree, id, &buf) {
			if old, ok := r.store.inodes[id]; ok {
				delete(old)
			}
			r.store.inodes[id] = buf
		} else {
			delete(buf)
		}
	}
	for st in nodes {
		if old, ok := r.store.nodes[st.key]; ok {
			delete(old)
			delete_key(&r.store.nodes, st.key)
		}
		if st.deleted {
			continue
		}
		buf := make([dynamic]u8)
		if fs.encode_node_record(&r.tree, st.key, &buf) {
			r.store.nodes[st.key] = buf
		} else {
			delete(buf)
		}
	}
	fs.mark_persisted(&r.tree)
	fs.trim(&r.tree, keep)
}

integrate :: proc(t: ^testing.T, r: ^Replica, index: int) -> bool {
	rec := r.world.ops[index]
	err := fs.apply(&r.tree, rec.id, rec.lamport, rec.op)
	if !testing.expectf(t, err == nil, "apply %v %v: %v lazy=%v", rec.id, rec.op, err, r.lazy) {
		return false
	}
	append(&r.have, index)
	r.vc[rec.id.actor] = rec.id.seq + 1
	r.lamport = max(r.lamport, rec.lamport)
	if _, ok := rec.op.(fs.Op_Create); ok {
		append(&r.created, rec.id)
	}
	return true
}

emit :: proc(t: ^testing.T, r: ^Replica, actor: u32, op: fs.Op) -> bool {
	w := r.world
	r.lamport += 1
	rec := Rec {
		id      = {actor = actor, seq = u64(len(w.by_actor[actor]))},
		lamport = r.lamport,
		op      = op,
		deps    = r.vc,
	}
	append(&w.ops, rec)
	append(&w.by_actor[actor], len(w.ops) - 1)
	return integrate(t, r, len(w.ops) - 1)
}

deliverable :: proc(r: ^Replica, a: int) -> (int, bool) {
	w := r.world
	if r.vc[a] >= u64(len(w.by_actor[a])) {
		return 0, false
	}
	index := w.by_actor[a][r.vc[a]]
	rec := w.ops[index]
	for b in 0 ..< N {
		if b != a && rec.deps[b] > r.vc[b] {
			return 0, false
		}
	}
	return index, true
}

Present :: struct {
	id:   fs.Inode_Id,
	kind: fs.Kind,
}

present_list :: proc(r: ^Replica) -> [dynamic]Present {
	out := make([dynamic]Present, context.temp_allocator)
	ids, _ := fs.descendants(&r.tree, fs.ROOT, context.temp_allocator)
	for id in ids {
		n, _ := fs.get(&r.tree, id)
		if n != nil {
			append(&out, Present{id, n.kind})
		}
	}
	return out
}

pick_dir :: proc(list: []Present) -> fs.Inode_Id {
	dirs := make([dynamic]fs.Inode_Id, context.temp_allocator)
	append(&dirs, fs.ROOT)
	for p in list {
		if p.kind == .Dir {
			append(&dirs, p.id)
		}
	}
	return rand.choice(dirs[:])
}

generate :: proc(t: ^testing.T, r: ^Replica, actor: u32) -> bool {
	list := present_list(r)
	roll := rand.int_max(100)
	switch {
	case roll < 35 || len(list) == 0:
		kind := rand.choice_enum(fs.Kind)
		op := fs.Op_Create {
			parent = pick_dir(list[:]),
			name   = rand.choice(NAMES[:]),
			kind   = kind,
		}
		if kind == .File && rand.int_max(3) == 0 {
			op.flags = {.Exec}
		}
		if kind == .Symlink {
			op.target = rand.choice(TARGETS[:])
		}
		return emit(t, r, actor, op)
	case roll < 42:
		d := pick_dir(list[:])
		snap := fs.current(&r.tree)
		kids, _ := fs.children(&snap, d, nil, 0, context.temp_allocator)
		conflicted := make([dynamic]string, context.temp_allocator)
		for c in kids {
			if strings.contains_rune(c.name, '~') {
				append(&conflicted, c.name)
			}
		}
		if len(conflicted) == 0 {
			return true
		}
		name := rand.choice(conflicted[:])
		if rand.int_max(3) == 0 {
			name = fmt.tprintf("%s~1", name)
		}
		if rand.int_max(2) == 0 && len(list) > 0 {
			return emit(t, r, actor, fs.Op_Move{inode = rand.choice(list[:]).id, parent = d, name = own(r.world, name)})
		}
		return emit(t, r, actor, fs.Op_Create{parent = d, name = own(r.world, name), kind = .File})
	case roll < 60:
		x := rand.choice(list[:])
		parent := pick_dir(list[:])
		if rand.int_max(4) == 0 {
			if n, _ := fs.get(&r.tree, x.id); n != nil {
				parent = n.moves[n.cur].parent
			}
		}
		return emit(t, r, actor, fs.Op_Move{inode = x.id, parent = parent, name = rand.choice(NAMES[:])})
	case roll < 72:
		x := rand.choice(list[:])
		ids, _ := fs.descendants(&r.tree, x.id, context.temp_allocator)
		emit(t, r, actor, fs.Op_Remove{inode = x.id}) or_return
		for id in ids {
			emit(t, r, actor, fs.Op_Remove{inode = id}) or_return
		}
		return true
	case roll < 78:
		if len(r.created) == 0 {
			return true
		}
		id := rand.choice(r.created[:])
		n, _ := fs.get(&r.tree, id)
		if n != nil && !n.alive {
			return emit(t, r, actor, fs.Op_Restore{inode = id})
		}
		return true
	case roll < 92:
		x := rand.choice(list[:])
		if x.kind != .File {
			return true
		}
		mask := fs.Flags{.Exec} if rand.int_max(2) == 0 else fs.Flags{.Exec, .Crlf}
		value := fs.Flags{.Exec} if rand.int_max(2) == 0 else fs.Flags{}
		return emit(t, r, actor, fs.Op_Set_Flags{inode = x.id, mask = mask, value = value})
	case:
		x := rand.choice(list[:])
		if x.kind != .Symlink {
			return true
		}
		return emit(t, r, actor, fs.Op_Set_Target{inode = x.id, target = rand.choice(TARGETS[:])})
	}
}

walk :: proc(t: ^testing.T, s: ^fs.Snapshot, dir: fs.Inode_Id, prefix: string, out: ^[dynamic]string) -> bool {
	kids, err := fs.children(s, dir, nil, 0, context.temp_allocator)
	testing.expect(t, err == nil) or_return
	seen := make(map[string]bool, context.temp_allocator)
	for c in kids {
		testing.expectf(t, !(c.name in seen), "duplicate display name %q", c.name) or_return
		seen[c.name] = true
	}
	page_size := 1 + len(kids) % 3
	after: Maybe(fs.Child_Key)
	k := 0
	for {
		page, perr := fs.children(s, dir, after, page_size, context.temp_allocator)
		testing.expect(t, perr == nil) or_return
		if len(page) == 0 {
			break
		}
		for c in page {
			testing.expect(t, k < len(kids) && kids[k].inode == c.inode && kids[k].name == c.name, "paged listing differs") or_return
			k += 1
		}
		after = page[len(page) - 1].key
	}
	testing.expect(t, k == len(kids), "paged listing short") or_return
	for c in kids {
		p := c.name if prefix == "" else fmt.tprintf("%s/%s", prefix, c.name)
		inf, ok, ierr := fs.info(s, c.inode, context.temp_allocator)
		testing.expect(t, ok && ierr == nil && inf.present) or_return
		got, pok, _ := fs.path(s, c.inode, context.temp_allocator)
		testing.expectf(t, pok && got == p, "path %q != %q", got, p) or_return
		found, lok, _ := fs.lookup(s, p)
		testing.expectf(t, lok && found == c.inode, "lookup %q", p) or_return
		append(out, fmt.tprintf("%s|%v|%v|%s|%v:%v", p, c.kind, inf.flags, inf.target, c.inode.actor, c.inode.seq))
		if c.kind == .Dir {
			walk(t, s, c.inode, p, out) or_return
		}
	}
	return true
}

dump :: proc(t: ^testing.T, s: ^fs.Snapshot) -> ([dynamic]string, bool) {
	out := make([dynamic]string, context.temp_allocator)
	ok := walk(t, s, fs.ROOT, "", &out)
	return out, ok
}

acyclic :: proc(t: ^testing.T, r: ^Replica) -> bool {
	for id in r.created {
		cur := id
		steps := 0
		for cur != fs.ROOT {
			n, _ := fs.get(&r.tree, cur)
			testing.expect(t, n != nil) or_return
			cur = n.moves[n.cur].parent
			steps += 1
			testing.expect(t, steps < 10_000, "cycle") or_return
		}
	}
	return true
}

Version :: struct {
	vc: [N]u64,
}

visible :: proc(data: rawptr, id: fs.Op_Id) -> bool {
	v := (^Version)(data)
	return id.actor < N && id.seq < v.vc[id.actor]
}

view_of :: proc(w: ^World, v: ^Version) -> fs.View {
	floor := max(u64)
	top: u64 = 0
	for rec in w.ops {
		top = max(top, rec.lamport)
		if rec.id.seq >= v.vc[rec.id.actor] {
			floor = min(floor, rec.lamport)
		}
	}
	if floor == max(u64) {
		floor = top + 1
	}
	return fs.View{data = v, visible = visible, floor = floor}
}

fresh :: proc(t: ^testing.T, w: ^World, v: Version, lazy: bool) -> ^Replica {
	r := new(Replica)
	replica_init(r, w, lazy, 4 + rand.int_max(5))
	order := make([dynamic]int, context.temp_allocator)
	for rec, i in w.ops {
		if rec.id.seq < v.vc[rec.id.actor] {
			append(&order, i)
		}
	}
	for len(order) > 0 {
		progressed := false
		for k := 0; k < len(order); k += 1 {
			rec := w.ops[order[k]]
			ready := r.vc[rec.id.actor] == rec.id.seq
			for b in 0 ..< N {
				if b != int(rec.id.actor) && rec.deps[b] > r.vc[b] {
					ready = false
				}
			}
			if ready && rand.int_max(3) == 0 {
				integrate(t, r, order[k])
				ordered_remove(&order, k)
				progressed = true
				break
			}
			if ready {
				progressed = true
			}
		}
		if !progressed {
			break
		}
	}
	return r
}

free_replica :: proc(r: ^Replica) {
	replica_destroy(r)
	free(r)
}

same_dump :: proc(t: ^testing.T, a, b: []string, what: string) -> bool {
	if len(a) != len(b) {
		testing.expectf(t, false, "%s: %d entries vs %d\n%v\n%v", what, len(a), len(b), a, b)
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			testing.expectf(t, false, "%s: %s != %s", what, a[i], b[i])
			return false
		}
	}
	return true
}

State :: struct {
	present: bool,
	parent:  fs.Inode_Id,
	name:    string,
	flags:   fs.Flags,
	target:  string,
}

state_of :: proc(r: ^Replica, id: fs.Inode_Id) -> State {
	s := fs.current(&r.tree)
	inf, ok, _ := fs.info(&s, id, context.temp_allocator)
	if !ok {
		return {}
	}
	return State{inf.present, inf.parent, inf.name, inf.flags, inf.target}
}

check_diff :: proc(t: ^testing.T, w: ^World, full: ^Replica, va, vb: ^Version) -> bool {
	ra := fresh(t, w, va^, false)
	defer free_replica(ra)
	rb := fresh(t, w, vb^, true)
	defer free_replica(rb)
	touched := make([dynamic]fs.Inode_Id, context.temp_allocator)
	for rec in w.ops {
		ina := rec.id.seq < va.vc[rec.id.actor]
		inb := rec.id.seq < vb.vc[rec.id.actor]
		if ina != inb {
			append(&touched, fs.op_inode(rec.id, rec.op))
		}
	}
	got, err := fs.diff(&full.tree, view_of(w, va), view_of(w, vb), touched[:], context.temp_allocator)
	testing.expect(t, err == nil) or_return
	expected := make(map[fs.Inode_Id]fs.Changes, context.temp_allocator)
	for id in full.created {
		a := state_of(ra, id)
		b := state_of(rb, id)
		what: fs.Changes
		switch {
		case !a.present && b.present:
			what = {.Added}
		case a.present && !b.present:
			what = {.Removed}
		case a.present && b.present:
			if a.parent != b.parent {
				what += {.Moved}
			}
			if a.name != b.name {
				what += {.Renamed}
			}
			if a.flags != b.flags {
				what += {.Flags}
			}
			if a.target != b.target {
				what += {.Target}
			}
		}
		if what != {} {
			expected[id] = what
		}
	}
	testing.expectf(t, len(got) == len(expected), "diff size %d != %d", len(got), len(expected)) or_return
	for c in got {
		e, ok := expected[c.inode]
		testing.expectf(t, ok && e == c.what, "diff %v: %v != %v", c.inode, c.what, e) or_return
	}
	return true
}

check_snapshot :: proc(t: ^testing.T, w: ^World, full: ^Replica, v: ^Version) -> bool {
	r := fresh(t, w, v^, false)
	defer free_replica(r)
	cs := fs.current(&r.tree)
	want, ok := dump(t, &cs)
	ok or_return
	s, err := fs.snapshot(&full.tree, view_of(w, v), context.temp_allocator)
	testing.expect(t, err == nil) or_return
	defer fs.snapshot_destroy(&s)
	got, gok := dump(t, &s)
	gok or_return
	return same_dump(t, want[:], got[:], "snapshot")
}

run_seed :: proc(t: ^testing.T, seed: u64) -> bool {
	state := rand.create(seed)
	context.random_generator = runtime.default_random_generator(&state)
	w := new(World)
	defer world_destroy(w)
	for i in 0 ..< N {
		_ = rand.read(w.actors[i][:])
	}
	copy(w.actors[1][12:], w.actors[0][12:])
	replicas: [N]Replica
	for i in 0 ..< N {
		replica_init(&replicas[i], w, i >= 2, 4 + 2 * i)
	}
	defer for i in 0 ..< N {
		replica_destroy(&replicas[i])
	}
	versions := make([dynamic]Version)
	defer delete(versions)
	partitioned: [N]int
	rounds := 40 + rand.int_max(30)
	for _ in 0 ..< rounds {
		for i in 0 ..< N {
			if partitioned[i] > 0 {
				partitioned[i] -= 1
			} else if rand.int_max(10) == 0 {
				partitioned[i] = rand.int_max(6)
			}
			for _ in 0 ..< 1 + rand.int_max(3) {
				generate(t, &replicas[i], u32(i)) or_return
			}
		}
		for _ in 0 ..< 6 * N {
			i := rand.int_max(N)
			a := rand.int_max(N)
			if a == i || partitioned[i] > 0 || partitioned[a] > 0 {
				continue
			}
			for _ in 0 ..< 1 + rand.int_max(4) {
				index, ok := deliverable(&replicas[i], a)
				if !ok {
					break
				}
				integrate(t, &replicas[i], index) or_return
			}
		}
		for i in 2 ..< N {
			if rand.int_max(3) == 0 {
				persist(&replicas[i], rand.int_max(8))
			}
		}
		if rand.int_max(8) == 0 {
			append(&versions, Version{replicas[rand.int_max(N)].vc})
		}
		free_all(context.temp_allocator)
	}
	for {
		progressed := false
		for i in 0 ..< N {
			for a in 0 ..< N {
				for {
					index, ok := deliverable(&replicas[i], a)
					if !ok {
						break
					}
					integrate(t, &replicas[i], index) or_return
					progressed = true
				}
			}
		}
		if !progressed {
			break
		}
	}
	for i in 2 ..< N {
		persist(&replicas[i], 3)
	}
	dumps: [N][dynamic]string
	for i in 0 ..< N {
		acyclic(t, &replicas[i]) or_return
		s := fs.current(&replicas[i].tree)
		d, ok := dump(t, &s)
		ok or_return
		dumps[i] = d
		testing.expect(t, len(replicas[i].have) == len(w.ops)) or_return
	}
	for i in 1 ..< N {
		same_dump(t, dumps[0][:], dumps[i][:], "replicas") or_return
	}
	final := Version{replicas[0].vc}
	append(&versions, final)
	for &v in versions {
		check_snapshot(t, w, &replicas[3], &v) or_return
	}
	for k in 0 ..< len(versions) - 1 {
		check_diff(t, w, &replicas[3], &versions[k], &versions[k + 1]) or_return
		check_diff(t, w, &replicas[1], &versions[k + 1], &versions[k]) or_return
	}
	free_all(context.temp_allocator)
	return true
}

@(test)
convergence_fuzz :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 220 {
		if !run_seed(t, seed) {
			testing.expectf(t, false, "seed %d failed", seed)
			return
		}
	}
}

@(test)
records_round_trip :: proc(t: ^testing.T) {
	w := new(World)
	defer world_destroy(w)
	r: Replica
	replica_init(&r, w, false)
	defer replica_destroy(&r)
	testing.expect(t, emit(t, &r, 0, fs.Op_Create{parent = fs.ROOT, name = "dir", kind = .Dir}))
	testing.expect(t, emit(t, &r, 0, fs.Op_Create{parent = {0, 0}, name = "f", kind = .File, flags = {.Exec}}))
	testing.expect(t, emit(t, &r, 0, fs.Op_Move{inode = {0, 1}, parent = fs.ROOT, name = "g"}))
	testing.expect(t, emit(t, &r, 0, fs.Op_Remove{inode = {0, 0}}))
	buf := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, fs.encode_inode_record(&r.tree, {0, 1}, &buf))
	n, err := fs.decode_inode(buf[:], context.temp_allocator)
	testing.expect(t, err == nil && n.id == fs.Inode_Id{0, 1} && len(n.moves) == 2 && n.cur == 1 && n.flags == {.Exec})
	for cut in 0 ..< len(buf) {
		_, cerr := fs.decode_inode(buf[:cut], context.temp_allocator)
		testing.expect(t, cerr != nil)
	}
	garbage := [?]u8{1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 9}
	_, gerr := fs.decode_inode(garbage[:], context.temp_allocator)
	testing.expect(t, gerr != nil)
	clear(&buf)
	testing.expect(t, fs.encode_node_record(&r.tree, fs.Node_Key{fs.ROOT, 0}, &buf))
	d, derr := fs.decode_node(buf[:], context.temp_allocator)
	testing.expect(t, derr == nil && d.leaf && len(d.entries) == 2)
	for cut in 0 ..< len(buf) {
		_, cerr := fs.decode_node(buf[:cut], context.temp_allocator)
		testing.expect(t, cerr != nil)
	}
	bad := fs.apply(&r.tree, {1, 0}, 1, fs.Op_Move{inode = {0, 1}, parent = {0, 1}, name = "x"})
	testing.expect(t, bad != nil)
	free_all(context.temp_allocator)
}

exchange :: proc(t: ^testing.T, rs: []^Replica) -> bool {
	for {
		progressed := false
		for r in rs {
			for a in 0 ..< N {
				for {
					index, ok := deliverable(r, a)
					if !ok {
						break
					}
					integrate(t, r, index) or_return
					progressed = true
				}
			}
		}
		if !progressed {
			return true
		}
	}
}

@(test)
semantics :: proc(t: ^testing.T) {
	w := new(World)
	defer world_destroy(w)
	for i in 0 ..< N {
		w.actors[i][0] = u8(i + 1)
	}
	a, b: Replica
	replica_init(&a, w, false)
	defer replica_destroy(&a)
	replica_init(&b, w, true)
	defer replica_destroy(&b)
	both := []^Replica{&a, &b}
	testing.expect(t, emit(t, &a, 0, fs.Op_Create{parent = fs.ROOT, name = "d", kind = .Dir}))
	testing.expect(t, emit(t, &a, 0, fs.Op_Create{parent = {0, 0}, name = "f", kind = .File}))
	testing.expect(t, emit(t, &a, 0, fs.Op_Create{parent = fs.ROOT, name = "p", kind = .Dir}))
	testing.expect(t, emit(t, &a, 0, fs.Op_Create{parent = fs.ROOT, name = "q", kind = .Dir}))
	testing.expect(t, exchange(t, both))
	before := Version{a.vc}
	testing.expect(t, emit(t, &a, 0, fs.Op_Remove{inode = {0, 1}}))
	testing.expect(t, emit(t, &a, 0, fs.Op_Remove{inode = {0, 0}}))
	testing.expect(t, emit(t, &a, 0, fs.Op_Move{inode = {0, 2}, parent = {0, 3}, name = "p"}))
	testing.expect(t, emit(t, &a, 0, fs.Op_Create{parent = fs.ROOT, name = "x", kind = .File}))
	testing.expect(t, emit(t, &b, 1, fs.Op_Create{parent = {0, 0}, name = "g", kind = .File}))
	testing.expect(t, emit(t, &b, 1, fs.Op_Move{inode = {0, 3}, parent = {0, 2}, name = "q"}))
	testing.expect(t, emit(t, &b, 1, fs.Op_Create{parent = fs.ROOT, name = "x", kind = .Symlink, target = "t"}))
	testing.expect(t, exchange(t, both))
	persist(&b, 0)
	expect_at := [?]struct {
		path:  string,
		inode: fs.Inode_Id,
	}{{"d", {0, 0}}, {"d/g", {1, 0}}, {"p", {0, 2}}, {"p/q", {0, 3}}, {"x", {1, 2}}, {"x~00000000-7", {0, 7}}}
	for r in both {
		s := fs.current(&r.tree)
		kids, _ := fs.children(&s, fs.ROOT, nil, 0, context.temp_allocator)
		testing.expect_value(t, len(kids), 4)
		for e in expect_at {
			id, ok, err := fs.lookup(&s, e.path)
			testing.expectf(t, ok && err == nil && id == e.inode, "%s: %v %v", e.path, id, ok)
		}
		_, found, _ := fs.lookup(&s, "d/f")
		testing.expect(t, !found)
	}
	final := Version{a.vc}
	got, err := fs.diff(&b.tree, view_of(w, &before), view_of(w, &final), {{0, 1}, {0, 0}, {0, 2}, {0, 7}, {1, 0}, {1, 1}, {1, 2}}, context.temp_allocator)
	testing.expect(t, err == nil)
	want := [?]fs.Change {
		{inode = {0, 1}, kind = .File, what = {.Removed}},
		{inode = {0, 3}, kind = .Dir, what = {.Moved}},
		{inode = {0, 7}, kind = .File, what = {.Added}},
		{inode = {1, 0}, kind = .File, what = {.Added}},
		{inode = {1, 2}, kind = .Symlink, what = {.Added}},
	}
	testing.expectf(t, slice.equal(got, want[:]), "diff %v", got)
	free_all(context.temp_allocator)
}

Fail_Alloc :: struct {
	backing:   runtime.Allocator,
	countdown: int,
}

fail_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	f := (^Fail_Alloc)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.countdown == 0 {
			return nil, .Out_Of_Memory
		}
		if f.countdown > 0 {
			f.countdown -= 1
		}
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

integrate_failing :: proc(t: ^testing.T, r: ^Replica, index: int, fa, ft: ^Fail_Alloc) -> bool {
	rec := r.world.ops[index]
	s := fs.current(&r.tree)
	before, ok := dump(t, &s)
	ok or_return
	for attempt := 0; ; attempt += 1 {
		if index % 2 == 0 {
			fa.countdown = attempt
		} else {
			ft.countdown = attempt
		}
		err: fs.Error
		{
			context.temp_allocator = runtime.Allocator{fail_proc, ft}
			err = fs.apply(&r.tree, rec.id, rec.lamport, rec.op)
		}
		fa.countdown = -1
		ft.countdown = -1
		if err == nil {
			break
		}
		_, is_alloc := err.(runtime.Allocator_Error)
		testing.expectf(t, is_alloc && attempt < 100_000, "apply %v failed with %v", rec.id, err) or_return
		after, aok := dump(t, &s)
		aok or_return
		same_dump(t, before[:], after[:], "after failed apply") or_return
	}
	testing.expect(t, fs.apply(&r.tree, rec.id, rec.lamport, rec.op) == nil, "retry after success") or_return
	append(&r.have, index)
	r.vc[rec.id.actor] = rec.id.seq + 1
	r.lamport = max(r.lamport, rec.lamport)
	if _, created := rec.op.(fs.Op_Create); created {
		append(&r.created, rec.id)
	}
	return true
}

run_failing :: proc(t: ^testing.T, seed: u64) -> bool {
	state := rand.create(seed)
	context.random_generator = runtime.default_random_generator(&state)
	w := new(World)
	defer world_destroy(w)
	for i in 0 ..< N {
		_ = rand.read(w.actors[i][:])
	}
	gens: [N - 1]Replica
	for i in 0 ..< N - 1 {
		replica_init(&gens[i], w, false, 4)
	}
	defer for i in 0 ..< N - 1 {
		replica_destroy(&gens[i])
	}
	fa := Fail_Alloc{context.allocator, -1}
	ft := Fail_Alloc{context.temp_allocator, -1}
	victim: Replica
	replica_init(&victim, w, true, 4, runtime.Allocator{fail_proc, &fa})
	defer replica_destroy(&victim)
	gen_ptrs := [N - 1]^Replica{&gens[0], &gens[1], &gens[2]}
	for _ in 0 ..< 25 {
		for i in 0 ..< N - 1 {
			generate(t, &gens[i], u32(i)) or_return
		}
		if rand.int_max(3) == 0 {
			exchange(t, gen_ptrs[:]) or_return
		}
		for _ in 0 ..< 6 {
			a := rand.int_max(N - 1)
			index, ok := deliverable(&victim, a)
			if ok {
				integrate_failing(t, &victim, index, &fa, &ft) or_return
			}
		}
		if rand.int_max(3) == 0 {
			persist(&victim, rand.int_max(6))
		}
		free_all(context.temp_allocator)
	}
	exchange(t, gen_ptrs[:]) or_return
	for {
		progressed := false
		for a in 0 ..< N - 1 {
			if index, ok := deliverable(&victim, a); ok {
				integrate_failing(t, &victim, index, &fa, &ft) or_return
				progressed = true
			}
		}
		if !progressed {
			break
		}
	}
	sg := fs.current(&gens[0].tree)
	want, wok := dump(t, &sg)
	wok or_return
	sv := fs.current(&victim.tree)
	got, gok := dump(t, &sv)
	gok or_return
	ok := same_dump(t, want[:], got[:], "victim")
	free_all(context.temp_allocator)
	return ok
}

@(test)
allocation_failures :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 6 {
		if !run_failing(t, seed) {
			testing.expectf(t, false, "seed %d failed", seed)
			return
		}
	}
}
