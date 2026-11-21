package fstree

import "base:runtime"
import "core:slice"
import "core:strings"

Place :: struct {
	parent: Inode_Id,
	name:   string,
	event:  Event,
}

Raw :: struct {
	key:  Key,
	kind: Kind,
}

Snapshot :: struct {
	tree:      ^Tree,
	view:      View,
	current:   bool,
	place:     map[Inode_Id]Place,
	moved_in:  map[Inode_Id][dynamic]Raw,
	present:   map[Inode_Id]bool,
	allocator: runtime.Allocator,
}

Child_Key :: struct {
	name:  string,
	event: Event,
	inode: Inode_Id,
}

Child :: struct {
	name:  string,
	inode: Inode_Id,
	kind:  Kind,
	key:   Child_Key,
}

Info :: struct {
	inode:   Inode_Id,
	kind:    Kind,
	present: bool,
	parent:  Inode_Id,
	name:    string,
	flags:   Flags,
	target:  string,
}

current :: proc(t: ^Tree) -> Snapshot {
	return Snapshot{tree = t, current = true}
}

snapshot :: proc(t: ^Tree, view: View, allocator := context.allocator) -> (s: Snapshot, err: Error) {
	s.tree = t
	s.view = view
	s.allocator = allocator
	if view.visible == nil {
		s.current = true
		return
	}
	s.place = make(map[Inode_Id]Place, allocator)
	s.moved_in = make(map[Inode_Id][dynamic]Raw, allocator)
	s.present = make(map[Inode_Id]bool, allocator)
	defer if err != nil {
		snapshot_destroy(&s)
	}
	ensure_log(t, view.floor) or_return
	start := log_lower_lamport(t, view.floor)
	for r in t.log[start:] {
		if r.inode in s.place {
			continue
		}
		n := get(t, r.inode) or_return
		if n == nil || len(n.moves) == 0 {
			continue
		}
		k := 0
		for j := len(n.moves) - 1; j > 0; j -= 1 {
			if n.moves[j].applied && n.moves[j].event.lamport < view.floor {
				k = j
				break
			}
		}
		m := n.moves[k]
		map_insert(&s.place, n.id, Place{m.parent, m.name, m.event}) or_return
	}
	for r in t.log[start:] {
		if !view.visible(view.data, event_id(r.event)) {
			continue
		}
		n := get(t, r.inode) or_return
		if n == nil {
			continue
		}
		k := find_move(n, r.event)
		if k < 0 {
			continue
		}
		m := n.moves[k]
		if m.parent == n.id || snap_is_ancestor(&s, n.id, m.parent) {
			continue
		}
		s.place[n.id] = Place{m.parent, m.name, m.event}
	}
	for id, p in s.place {
		if !snap_exists(&s, id) {
			continue
		}
		n := get(t, id) or_return
		if n == nil {
			continue
		}
		raw := Raw{Key{name = p.name, event = p.event, inode = id}, n.kind}
		if list, ok := &s.moved_in[p.parent]; ok {
			append(list, raw) or_return
		} else {
			l := make([dynamic]Raw, 0, 1, allocator) or_return
			append(&l, raw) or_return
			map_insert(&s.moved_in, p.parent, l) or_return
		}
	}
	context.user_ptr = t
	for _, l in s.moved_in {
		slice.sort_by(l[:], proc(a, b: Raw) -> bool {
			return key_cmp((^Tree)(context.user_ptr), a.key, b.key) < 0
		})
	}
	return
}

snapshot_destroy :: proc(s: ^Snapshot) {
	if s.current {
		return
	}
	for _, l in s.moved_in {
		delete(l)
	}
	delete(s.moved_in)
	delete(s.place)
	delete(s.present)
	s.place = nil
	s.moved_in = nil
	s.present = nil
}

@(private)
snap_exists :: proc(s: ^Snapshot, id: Inode_Id) -> bool {
	if id == ROOT || s.current {
		return true
	}
	return s.view.visible(s.view.data, id)
}

@(private)
visible_event :: proc(s: ^Snapshot, e: Event) -> bool {
	return s.current || e.lamport < s.view.floor || s.view.visible(s.view.data, event_id(e))
}

@(private)
snap_parent :: proc(s: ^Snapshot, id: Inode_Id) -> (p: Place, ok: bool, err: Error) {
	if id == ROOT {
		return
	}
	if !s.current {
		if pl, found := s.place[id]; found {
			return pl, true, nil
		}
	}
	n := get(s.tree, id) or_return
	if n == nil || n.cur < 0 || n.cur >= len(n.moves) {
		return
	}
	m := n.moves[n.cur]
	return Place{m.parent, m.name, m.event}, true, nil
}

@(private)
snap_is_ancestor :: proc(s: ^Snapshot, a: Inode_Id, p: Inode_Id) -> bool {
	cur := p
	for _ in 0 ..< MAX_DEPTH {
		if cur == a {
			return true
		}
		if cur == ROOT {
			return false
		}
		pl, ok, err := snap_parent(s, cur)
		if err != nil || !ok {
			return false
		}
		cur = pl.parent
	}
	return true
}

@(private)
alive_at :: proc(s: ^Snapshot, n: ^Inode) -> bool {
	if s.current {
		return n.alive
	}
	for i := len(n.alive_log) - 1; i >= 0; i -= 1 {
		if visible_event(s, n.alive_log[i].event) {
			return n.alive_log[i].alive
		}
	}
	return true
}

@(private)
flags_at :: proc(s: ^Snapshot, n: ^Inode) -> Flags {
	if s.current {
		return n.flags
	}
	f: Flags
	for flag in Flag {
		for i := len(n.flag_log) - 1; i >= 0; i -= 1 {
			e := n.flag_log[i]
			if flag in e.mask && visible_event(s, e.event) {
				if flag in e.value {
					f += {flag}
				}
				break
			}
		}
	}
	return f
}

@(private)
target_at :: proc(s: ^Snapshot, n: ^Inode) -> string {
	for i := len(n.targets) - 1; i >= 0; i -= 1 {
		if visible_event(s, n.targets[i].event) {
			return n.targets[i].target
		}
	}
	return ""
}

@(private)
present_at :: proc(s: ^Snapshot, id: Inode_Id) -> (present: bool, err: Error) {
	if id == ROOT {
		return true, nil
	}
	if !snap_exists(s, id) {
		return false, nil
	}
	if !s.current {
		if v, ok := s.present[id]; ok {
			return v, nil
		}
	}
	n := get(s.tree, id) or_return
	if n == nil {
		return false, nil
	}
	if s.current {
		return is_present(n), nil
	}
	map_insert(&s.present, id, false) or_return
	result := alive_at(s, n)
	if !result && n.kind == .Dir {
		kids := scan(s, id, .First, {}, false, 1, context.temp_allocator) or_return
		result = len(kids) > 0
	}
	s.present[id] = result
	return result, nil
}

@(private)
Scan_From :: enum u8 {
	First,
	At,
	After,
}

@(private)
entry_present :: proc(s: ^Snapshot, item: Item) -> (bool, Error) {
	e := item.entry
	if s.current {
		return e.present, nil
	}
	if e.inode in s.place {
		return false, nil
	}
	floor := s.view.floor
	if e.event.lamport >= floor && !s.view.visible(s.view.data, e.inode) {
		return false, nil
	}
	if e.alive_lamport < floor && (e.alive || e.kind != .Dir) {
		return e.alive, nil
	}
	return present_at(s, e.inode)
}

@(private)
scan :: proc(
	s: ^Snapshot,
	dir: Inode_Id,
	from: Scan_From,
	start: Key,
	only_name: bool,
	limit: int,
	allocator: runtime.Allocator,
) -> (
	out: [dynamic]Raw,
	err: Error,
) {
	t := s.tree
	out = make([dynamic]Raw, allocator)
	it: Iter
	switch from {
	case .First:
		it = iter_first(t, dir) or_return
	case .At:
		it = iter_seek(t, dir, start, false) or_return
	case .After:
		it = iter_seek(t, dir, start, true) or_return
	}
	moved: []Raw
	if !s.current {
		if l, ok := s.moved_in[dir]; ok {
			moved = l[:]
		}
	}
	mpos := 0
	if from != .First {
		for mpos < len(moved) {
			c := key_cmp(t, moved[mpos].key, start)
			if c > 0 || (c == 0 && from == .At) {
				break
			}
			mpos += 1
		}
	}
	item: Item
	has_item := false
	for limit <= 0 || len(out) < limit {
		if !has_item && !it.done {
			item, has_item = iter_next(&it) or_return
		}
		take_moved := false
		if mpos < len(moved) {
			take_moved = !has_item || key_cmp(t, moved[mpos].key, item.key) < 0
		} else if !has_item {
			break
		}
		if take_moved {
			r := moved[mpos]
			mpos += 1
			if only_name && r.key.name != start.name {
				break
			}
			if present_at(s, r.key.inode) or_return {
				append(&out, r) or_return
			}
		} else {
			has_item = false
			if only_name && item.key.name != start.name {
				break
			}
			if entry_present(s, item) or_return {
				append(&out, Raw{item.key, item.entry.kind}) or_return
			}
		}
	}
	return
}

@(private)
group :: proc(s: ^Snapshot, dir: Inode_Id, name: string, limit := 0) -> ([dynamic]Raw, Error) {
	return scan(s, dir, .At, Key{name = name, low = true}, true, limit, context.temp_allocator)
}

@(private)
name_taken :: proc(s: ^Snapshot, dir: Inode_Id, name: string) -> (bool, Error) {
	g, err := group(s, dir, name, 1)
	return len(g) > 0, err
}

@(private)
HEX :: "0123456789abcdef"

@(private)
suffix_name :: proc(t: ^Tree, base: string, id: Inode_Id, long: bool, counter: int, allocator: runtime.Allocator) -> (out: string, err: runtime.Allocator_Error) {
	actor := actor_id(t, id.actor)
	if t.source.actor == nil {
		actor = {}
		actor[12] = u8(id.actor >> 24)
		actor[13] = u8(id.actor >> 16)
		actor[14] = u8(id.actor >> 8)
		actor[15] = u8(id.actor)
	}
	b := strings.builder_make(0, len(base) + 64, allocator) or_return
	strings.write_string(&b, base)
	strings.write_byte(&b, '~')
	hex := HEX
	for i in (0 if long else 12) ..< 16 {
		strings.write_byte(&b, hex[actor[i] >> 4])
		strings.write_byte(&b, hex[actor[i] & 0xf])
	}
	strings.write_byte(&b, '-')
	strings.write_u64(&b, id.seq, 10)
	if counter > 0 {
		strings.write_byte(&b, '~')
		strings.write_u64(&b, u64(counter), 10)
	}
	return strings.to_string(b), nil
}

@(private)
group_longs :: proc(s: ^Snapshot, g: []Raw) -> (longs: []bool, err: Error) {
	longs = make([]bool, len(g), context.temp_allocator) or_return
	shorts := make([]string, len(g), context.temp_allocator) or_return
	for i in 1 ..< len(g) {
		shorts[i] = suffix_name(s.tree, g[i].key.name, g[i].key.inode, false, 0, context.temp_allocator) or_return
	}
	for i in 1 ..< len(g) {
		for j in 1 ..< len(g) {
			if i != j && shorts[i] == shorts[j] {
				longs[i] = true
				break
			}
		}
	}
	return longs, nil
}

@(private)
loser_name :: proc(s: ^Snapshot, dir: Inode_Id, g: []Raw, longs: []bool, idx: int, allocator: runtime.Allocator) -> (name: string, err: Error) {
	r := g[idx]
	for counter in 0 ..< MAX_DEPTH {
		cand := suffix_name(s.tree, r.key.name, r.key.inode, longs[idx], counter, context.temp_allocator) or_return
		taken := name_taken(s, dir, cand) or_return
		if !taken {
			name = strings.clone(cand, allocator) or_return
			return name, nil
		}
	}
	return "", .Corrupt
}

@(private)
name_in_group :: proc(s: ^Snapshot, dir: Inode_Id, g: []Raw, idx: int, allocator: runtime.Allocator) -> (name: string, err: Error) {
	if idx == 0 {
		name = strings.clone(g[0].key.name, allocator) or_return
		return name, nil
	}
	longs := group_longs(s, g) or_return
	return loser_name(s, dir, g, longs, idx, allocator)
}

display_name :: proc(s: ^Snapshot, id: Inode_Id, allocator := context.allocator) -> (name: string, ok: bool, err: Error) {
	if id == ROOT {
		return "", true, nil
	}
	if !(present_at(s, id) or_return) {
		return
	}
	p, placed := snap_parent(s, id) or_return
	if !placed {
		return
	}
	g := group(s, p.parent, p.name) or_return
	for r, i in g {
		if r.key.inode == id {
			name = name_in_group(s, p.parent, g[:], i, allocator) or_return
			return name, true, nil
		}
	}
	return
}

children :: proc(
	s: ^Snapshot,
	dir: Inode_Id,
	after: Maybe(Child_Key) = nil,
	limit := 0,
	allocator := context.allocator,
) -> (
	out: []Child,
	err: Error,
) {
	start: Key
	from := Scan_From.First
	if a, ok := after.?; ok {
		start = Key{name = a.name, event = a.event, inode = a.inode}
		from = .After
	}
	raw := scan(s, dir, from, start, false, limit, context.temp_allocator) or_return
	list := make([dynamic]Child, 0, len(raw), allocator) or_return
	defer if err != nil {
		children_free(list[:], allocator)
	}
	i := 0
	for i < len(raw) {
		j := i + 1
		for j < len(raw) && raw[j].key.name == raw[i].key.name {
			j += 1
		}
		run := raw[i:j]
		continued := i == 0 && from == .After && start.name == run[0].key.name
		g: [dynamic]Raw
		longs: []bool
		if continued || len(run) > 1 {
			g = group(s, dir, run[0].key.name) or_return
			longs = group_longs(s, g[:]) or_return
		}
		for r in run {
			idx := 0 if len(g) == 0 else -1
			for m, gi in g {
				if m.key.inode == r.key.inode {
					idx = gi
					break
				}
			}
			if idx < 0 {
				return nil, .Corrupt
			}
			name: string
			if idx == 0 {
				name = strings.clone(r.key.name, allocator) or_return
			} else {
				name = loser_name(s, dir, g[:], longs, idx, allocator) or_return
			}
			raw_name, cerr := strings.clone(r.key.name, allocator)
			if cerr != nil {
				delete(name, allocator)
				return nil, cerr
			}
			c := Child {
				name  = name,
				inode = r.key.inode,
				kind  = r.kind,
				key   = Child_Key{name = raw_name, event = r.key.event, inode = r.key.inode},
			}
			if _, aerr := append(&list, c); aerr != nil {
				delete(name, allocator)
				delete(raw_name, allocator)
				return nil, aerr
			}
		}
		i = j
	}
	return list[:], nil
}

children_free :: proc(list: []Child, allocator := context.allocator) {
	for c in list {
		delete(c.name, allocator)
		delete(c.key.name, allocator)
	}
	delete(list, allocator)
}

path :: proc(s: ^Snapshot, id: Inode_Id, allocator := context.allocator) -> (out: string, ok: bool, err: Error) {
	if id == ROOT {
		return "", true, nil
	}
	parts := make([dynamic]string, context.temp_allocator)
	cur := id
	for _ in 0 ..< MAX_DEPTH {
		if cur == ROOT {
			break
		}
		name, found := display_name(s, cur, context.temp_allocator) or_return
		if !found {
			return
		}
		append(&parts, name) or_return
		p, placed := snap_parent(s, cur) or_return
		if !placed {
			return
		}
		cur = p.parent
	}
	if cur != ROOT {
		return
	}
	b := strings.builder_make(allocator) or_return
	for i := len(parts) - 1; i >= 0; i -= 1 {
		strings.write_string(&b, parts[i])
		if i > 0 {
			strings.write_byte(&b, '/')
		}
	}
	return strings.to_string(b), true, nil
}

lookup :: proc(s: ^Snapshot, p: string) -> (id: Inode_Id, ok: bool, err: Error) {
	cur := ROOT
	rest := p
	for part in strings.split_iterator(&rest, "/") {
		if len(part) == 0 || part == "." {
			continue
		}
		next, found := lookup_child(s, cur, part) or_return
		if !found {
			return
		}
		cur = next
	}
	return cur, true, nil
}

lookup_child :: proc(s: ^Snapshot, dir: Inode_Id, part: string) -> (id: Inode_Id, ok: bool, err: Error) {
	first := group(s, dir, part, 1) or_return
	if len(first) > 0 {
		return first[0].key.inode, true, nil
	}
	for i := len(part) - 1; i > 0; i -= 1 {
		if part[i] != '~' {
			continue
		}
		g := group(s, dir, part[:i]) or_return
		if len(g) < 2 {
			continue
		}
		longs := group_longs(s, g[:]) or_return
		for k in 1 ..< len(g) {
			name := loser_name(s, dir, g[:], longs, k, context.temp_allocator) or_return
			if name == part {
				return g[k].key.inode, true, nil
			}
		}
	}
	return
}

info :: proc(s: ^Snapshot, id: Inode_Id, allocator := context.allocator) -> (out: Info, ok: bool, err: Error) {
	if !snap_exists(s, id) {
		return
	}
	n := get(s.tree, id) or_return
	if n == nil {
		return
	}
	out.inode = id
	out.kind = n.kind
	out.present = present_at(s, id) or_return
	out.flags = flags_at(s, n)
	if p, placed := snap_parent(s, id) or_return; placed {
		out.parent = p.parent
	}
	if out.present {
		name, found := display_name(s, id, allocator) or_return
		if found {
			out.name = name
		}
	}
	target, terr := strings.clone(target_at(s, n), allocator)
	if terr != nil {
		delete(out.name, allocator)
		return {}, false, terr
	}
	out.target = target
	return out, true, nil
}

info_free :: proc(i: Info, allocator := context.allocator) {
	delete(i.name, allocator)
	delete(i.target, allocator)
}

Change_Kind :: enum u8 {
	Added,
	Removed,
	Moved,
	Renamed,
	Flags,
	Target,
}

Changes :: bit_set[Change_Kind;u8]

Change :: struct {
	inode: Inode_Id,
	kind:  Kind,
	what:  Changes,
}

@(private)
collect_ancestors :: proc(s: ^Snapshot, id: Inode_Id, set: ^map[Inode_Id]struct{}) -> Error {
	cur := id
	for _ in 0 ..< MAX_DEPTH {
		if !snap_exists(s, cur) {
			return nil
		}
		p, placed := snap_parent(s, cur) or_return
		if !placed || p.parent == ROOT || p.parent in set {
			return nil
		}
		map_insert(set, p.parent, struct{}{}) or_return
		cur = p.parent
	}
	return nil
}

@(private)
collect_namesakes :: proc(s: ^Snapshot, id: Inode_Id, set: ^map[Inode_Id]struct{}) -> Error {
	if !snap_exists(s, id) {
		return nil
	}
	p, placed := snap_parent(s, id) or_return
	if !placed {
		return nil
	}
	g := group(s, p.parent, p.name) or_return
	for r in g {
		map_insert(set, r.key.inode, struct{}{}) or_return
	}
	for i := len(p.name) - 1; i > 0; i -= 1 {
		if p.name[i] != '~' {
			continue
		}
		base := group(s, p.parent, p.name[:i]) or_return
		if len(base) < 2 {
			continue
		}
		for r in base {
			map_insert(set, r.key.inode, struct{}{}) or_return
		}
	}
	return nil
}

diff :: proc(t: ^Tree, a, b: View, touched: []Inode_Id, allocator := context.allocator) -> (out: []Change, err: Error) {
	sa := snapshot(t, a, context.temp_allocator) or_return
	defer snapshot_destroy(&sa)
	sb := snapshot(t, b, context.temp_allocator) or_return
	defer snapshot_destroy(&sb)
	set := make(map[Inode_Id]struct{}, context.temp_allocator)
	for id in touched {
		if id != ROOT {
			map_insert(&set, id, struct{}{}) or_return
		}
	}
	for id in sa.place {
		map_insert(&set, id, struct{}{}) or_return
	}
	for id in sb.place {
		map_insert(&set, id, struct{}{}) or_return
	}
	base := make([dynamic]Inode_Id, 0, len(set), context.temp_allocator) or_return
	for id in set {
		append(&base, id) or_return
	}
	for id in base {
		collect_ancestors(&sa, id, &set) or_return
		collect_ancestors(&sb, id, &set) or_return
	}
	clear(&base)
	for id in set {
		append(&base, id) or_return
	}
	for id in base {
		collect_namesakes(&sa, id, &set) or_return
		collect_namesakes(&sb, id, &set) or_return
	}
	ids := make([dynamic]Inode_Id, 0, len(set), context.temp_allocator) or_return
	for id in set {
		append(&ids, id) or_return
	}
	slice.sort_by(ids[:], proc(x, y: Inode_Id) -> bool {return id_cmp(x, y) < 0})
	result := make([dynamic]Change, allocator)
	defer if err != nil {
		delete(result)
	}
	for id in ids {
		ia, _ := info(&sa, id, context.temp_allocator) or_return
		ib, _ := info(&sb, id, context.temp_allocator) or_return
		what: Changes
		switch {
		case !ia.present && ib.present:
			what += {.Added}
		case ia.present && !ib.present:
			what += {.Removed}
		case ia.present && ib.present:
			if ia.parent != ib.parent {
				what += {.Moved}
			}
			if ia.name != ib.name {
				what += {.Renamed}
			}
			if ia.flags != ib.flags {
				what += {.Flags}
			}
			if ia.target != ib.target {
				what += {.Target}
			}
		}
		if what != {} {
			kind := ib.kind if ib.present else ia.kind
			append(&result, Change{inode = id, kind = kind, what = what}) or_return
		}
	}
	return result[:], nil
}
