package fstree

import "core:strings"

apply :: proc(t: ^Tree, id: Op_Id, lamport: u64, op: Op) -> Error {
	if id.actor == ROOT.actor {
		return .Reserved_Actor
	}
	if t.txn.active {
		return .Corrupt
	}
	ev := Event {
		lamport = lamport,
		seq     = id.seq,
		actor   = id.actor,
	}
	txn_begin(t)
	err: Error
	switch o in op {
	case Op_Create:
		err = apply_create(t, ev, o)
	case Op_Move:
		err = apply_move(t, ev, o)
	case Op_Remove:
		err = apply_alive(t, ev, o.inode, false)
	case Op_Restore:
		err = apply_alive(t, ev, o.inode, true)
	case Op_Set_Flags:
		err = apply_flags(t, ev, o)
	case Op_Set_Target:
		err = apply_target(t, ev, o)
	case:
		err = .Corrupt
	}
	if err != nil {
		txn_abort(t)
		return err
	}
	txn_commit(t) or_return
	if lamport > t.max_lamport {
		t.max_lamport = lamport
	}
	return nil
}

@(private)
referenced :: proc(t: ^Tree, id: Inode_Id, lamport: u64) -> (^Inode, Error) {
	if id == ROOT {
		return t.root, nil
	}
	n, err := get(t, id)
	if err != nil {
		return nil, err
	}
	if n == nil {
		return nil, .Unknown_Inode
	}
	if len(n.moves) == 0 || n.moves[0].event.lamport >= lamport {
		return nil, .Not_Causal
	}
	return n, nil
}

@(private)
valid_kind :: proc "contextless" (k: Kind) -> bool {
	return u8(k) <= u8(Kind.Symlink)
}

@(private)
apply_create :: proc(t: ^Tree, ev: Event, o: Op_Create) -> Error {
	if !valid_name(o.name) {
		return .Invalid_Name
	}
	if !valid_kind(o.kind) {
		return .Corrupt
	}
	parent := referenced(t, o.parent, ev.lamport) or_return
	if parent.kind != .Dir {
		return .Not_Dir
	}
	id := event_id(ev)
	existing := get(t, id) or_return
	if existing != nil {
		return nil
	}
	n := new(Inode, t.allocator) or_return
	n^ = Inode {
		id     = id,
		kind   = o.kind,
		alive  = true,
		flags  = o.flags & ALL_FLAGS,
		cur    = 0,
		listed = 0,
	}
	if err := adopt(t, n); err != nil {
		free(n, t.allocator)
		return err
	}
	n.moves = make([dynamic]Move, 0, 1, t.allocator) or_return
	n.flag_log = make([dynamic]Flag_Entry, 0, 1, t.allocator) or_return
	n.alive_log = make([dynamic]Alive_Entry, t.allocator)
	n.targets = make([dynamic]Target_Entry, t.allocator)
	name := strings.clone(o.name, t.allocator) or_return
	append(&n.moves, Move{event = ev, parent = o.parent, name = name, applied = true})
	append(&n.flag_log, Flag_Entry{event = ev, mask = ALL_FLAGS, value = n.flags})
	if o.kind == .Symlink {
		target := strings.clone(o.target, t.allocator) or_return
		if _, err := append(&n.targets, Target_Entry{event = ev, target = target}); err != nil {
			delete(target, t.allocator)
			return err
		}
	}
	if o.kind == .Dir {
		dir_create(t, id) or_return
	}
	return list_entry(t, n)
}

@(private)
insert_event :: proc(t: ^Tree, list: ^[dynamic]$T, item: T) -> (index: int, inserted: bool, err: Error) {
	i := len(list)
	for i > 0 {
		c := event_cmp(t, list[i - 1].event, item.event)
		if c == 0 {
			return i - 1, false, nil
		}
		if c < 0 {
			break
		}
		i -= 1
	}
	if _, e := inject_at(list, i, item); e != nil {
		return 0, false, e
	}
	return i, true, nil
}

@(private)
has_event :: proc(t: ^Tree, list: []$T, ev: Event) -> bool {
	for i := len(list) - 1; i >= 0; i -= 1 {
		c := event_cmp(t, list[i].event, ev)
		if c == 0 {
			return true
		}
		if c < 0 {
			return false
		}
	}
	return false
}

@(private)
find_move :: proc "contextless" (n: ^Inode, ev: Event) -> int {
	for i := len(n.moves) - 1; i >= 0; i -= 1 {
		if n.moves[i].event == ev {
			return i
		}
	}
	return -1
}

@(private)
latest_lamport :: proc "contextless" (n: ^Inode) -> u64 {
	if len(n.alive_log) == 0 {
		return 0
	}
	return n.alive_log[len(n.alive_log) - 1].event.lamport
}

@(private)
listed_key :: proc "contextless" (n: ^Inode) -> (key: Key, parent: Inode_Id, ok: bool) {
	if n.listed < 0 || n.listed >= len(n.moves) {
		return
	}
	m := n.moves[n.listed]
	return Key{name = m.name, event = m.event, inode = n.id}, m.parent, true
}

@(private)
list_entry :: proc(t: ^Tree, n: ^Inode) -> Error {
	key, parent, ok := listed_key(n)
	if !ok {
		return .Corrupt
	}
	e := Entry {
		inode         = n.id,
		event         = key.event,
		alive_lamport = latest_lamport(n),
		kind          = n.kind,
		alive         = n.alive,
		present       = is_present(n),
	}
	btree_insert(t, parent, key, e) or_return
	if e.present {
		return adjust_count(t, parent, true)
	}
	return nil
}

@(private)
unlist_entry :: proc(t: ^Tree, n: ^Inode) -> Error {
	key, parent, ok := listed_key(n)
	if !ok {
		return .Corrupt
	}
	removed := btree_delete(t, parent, key) or_return
	if removed.present {
		return adjust_count(t, parent, false)
	}
	return nil
}

@(private)
refresh_entry :: proc(t: ^Tree, n: ^Inode) -> (was: bool, now: bool, parent: Inode_Id, err: Error) {
	if n.id == ROOT || n.listed < 0 {
		return true, true, ROOT, nil
	}
	key, p, ok := listed_key(n)
	if !ok {
		return false, false, ROOT, .Corrupt
	}
	now = is_present(n)
	was = btree_update(t, p, key, n.alive, latest_lamport(n), now) or_return
	return was, now, p, nil
}

@(private)
adjust_count :: proc(t: ^Tree, dir: Inode_Id, up: bool) -> Error {
	id := dir
	inc := up
	for _ in 0 ..< MAX_DEPTH {
		if id == ROOT {
			return nil
		}
		d := edit(t, id) or_return
		before := is_present(d)
		if inc {
			d.present_children += 1
		} else if d.present_children > 0 {
			d.present_children -= 1
		}
		if is_present(d) == before {
			return nil
		}
		was, now, parent := refresh_entry(t, d) or_return
		if was == now {
			return nil
		}
		id = parent
		inc = now
	}
	return .Corrupt
}

@(private)
apply_alive :: proc(t: ^Tree, ev: Event, id: Inode_Id, alive: bool) -> Error {
	if id == ROOT {
		return .Root
	}
	r := referenced(t, id, ev.lamport) or_return
	if has_event(t, r.alive_log[:], ev) {
		return nil
	}
	n := edit(t, id) or_return
	insert_event(t, &n.alive_log, Alive_Entry{event = ev, alive = alive}) or_return
	n.alive = n.alive_log[len(n.alive_log) - 1].alive
	was, now, parent := refresh_entry(t, n) or_return
	if was != now {
		return adjust_count(t, parent, now)
	}
	return nil
}

@(private)
recompute_flags :: proc "contextless" (n: ^Inode) {
	f: Flags
	for flag in Flag {
		for i := len(n.flag_log) - 1; i >= 0; i -= 1 {
			e := n.flag_log[i]
			if flag in e.mask {
				if flag in e.value {
					f += {flag}
				}
				break
			}
		}
	}
	n.flags = f
}

@(private)
apply_flags :: proc(t: ^Tree, ev: Event, o: Op_Set_Flags) -> Error {
	if o.inode == ROOT {
		return .Root
	}
	r := referenced(t, o.inode, ev.lamport) or_return
	if r.kind != .File {
		return .Wrong_Kind
	}
	if has_event(t, r.flag_log[:], ev) {
		return nil
	}
	n := edit(t, o.inode) or_return
	entry := Flag_Entry {
		event = ev,
		mask  = o.mask & ALL_FLAGS,
		value = o.value & o.mask & ALL_FLAGS,
	}
	insert_event(t, &n.flag_log, entry) or_return
	recompute_flags(n)
	return nil
}

@(private)
apply_target :: proc(t: ^Tree, ev: Event, o: Op_Set_Target) -> Error {
	if o.inode == ROOT {
		return .Root
	}
	r := referenced(t, o.inode, ev.lamport) or_return
	if r.kind != .Symlink {
		return .Wrong_Kind
	}
	if has_event(t, r.targets[:], ev) {
		return nil
	}
	n := edit(t, o.inode) or_return
	target := strings.clone(o.target, t.allocator) or_return
	if _, _, err := insert_event(t, &n.targets, Target_Entry{event = ev, target = target}); err != nil {
		delete(target, t.allocator)
		return err
	}
	return nil
}

@(private)
is_ancestor :: proc(t: ^Tree, a: Inode_Id, p: Inode_Id) -> (found: bool, err: Error) {
	cur := p
	for _ in 0 ..< MAX_DEPTH {
		if cur == a {
			return true, nil
		}
		if cur == ROOT {
			return false, nil
		}
		n := get(t, cur) or_return
		if n == nil || n.cur < 0 || n.cur >= len(n.moves) {
			return false, .Corrupt
		}
		cur = n.moves[n.cur].parent
	}
	return true, nil
}

@(private)
prev_applied :: proc "contextless" (n: ^Inode, k: int) -> int {
	for j := k - 1; j >= 0; j -= 1 {
		if n.moves[j].applied {
			return j
		}
	}
	return 0
}

@(private)
undo_move :: proc(n: ^Inode, ev: Event) {
	k := find_move(n, ev)
	if k <= 0 || !n.moves[k].applied {
		return
	}
	n.moves[k].applied = false
	if n.cur == k {
		n.cur = prev_applied(n, k)
	}
}

@(private)
redo_move :: proc(t: ^Tree, n: ^Inode, k: int) -> Error {
	if k <= 0 || k >= len(n.moves) {
		return nil
	}
	m := &n.moves[k]
	cycle := m.parent == n.id
	if !cycle {
		cycle = is_ancestor(t, n.id, m.parent) or_return
	}
	if cycle {
		m.applied = false
		return nil
	}
	m.applied = true
	if k > n.cur {
		n.cur = k
	}
	return nil
}

@(private)
detach :: proc(t: ^Tree, n: ^Inode) -> Error {
	if n.cur == n.listed || n.listed < 0 {
		return nil
	}
	unlist_entry(t, n) or_return
	n.listed = -1
	return nil
}

@(private)
attach :: proc(t: ^Tree, n: ^Inode) -> Error {
	if n.listed >= 0 {
		return nil
	}
	n.listed = n.cur
	return list_entry(t, n)
}

@(private)
Pending :: struct {
	node:  ^Inode,
	event: Event,
}

@(private)
apply_move :: proc(t: ^Tree, ev: Event, o: Op_Move) -> Error {
	if o.inode == ROOT {
		return .Root
	}
	if !valid_name(o.name) {
		return .Invalid_Name
	}
	r := referenced(t, o.inode, ev.lamport) or_return
	p := referenced(t, o.parent, ev.lamport) or_return
	if p.kind != .Dir {
		return .Not_Dir
	}
	if find_move(r, ev) >= 0 {
		return nil
	}
	ensure_log(t, ev.lamport) or_return
	start := log_upper(t, ev)
	logged := start > 0 && t.log[start - 1].event == ev
	later := make([dynamic]Pending, 0, len(t.log) - start, context.temp_allocator) or_return
	for ref in t.log[start:] {
		if ref.inode == ROOT {
			continue
		}
		if known := get(t, ref.inode) or_return; known == nil {
			continue
		}
		n := edit(t, ref.inode) or_return
		append(&later, Pending{n, ref.event}) or_return
	}
	x := edit(t, o.inode) or_return
	name := strings.clone(o.name, t.allocator) or_return
	k, _, err := insert_event(t, &x.moves, Move{event = ev, parent = o.parent, name = name})
	if err != nil {
		delete(name, t.allocator)
		return err
	}
	if k <= x.cur {
		x.cur += 1
	}
	if k <= x.listed {
		x.listed += 1
	}
	for i := len(later) - 1; i >= 0; i -= 1 {
		undo_move(later[i].node, later[i].event)
	}
	if !logged {
		t.txn.log_at = start
		t.txn.log_ref = Move_Ref{event = ev, inode = x.id}
		t.txn.has_log = true
	}
	redo_move(t, x, k) or_return
	for pend in later {
		redo_move(t, pend.node, find_move(pend.node, pend.event)) or_return
	}
	detach(t, x) or_return
	for pend in later {
		detach(t, pend.node) or_return
	}
	attach(t, x) or_return
	for pend in later {
		attach(t, pend.node) or_return
	}
	return nil
}
