package fstree

import "base:runtime"
import "core:strings"
import "../prim"

RECORD_VERSION :: 1

@(private)
write_inode_id :: proc(w: ^prim.Writer, id: Inode_Id) {
	prim.write_uvarint(w, u64(id.actor))
	prim.write_uvarint(w, id.seq)
}

@(private)
write_event :: proc(w: ^prim.Writer, e: Event) {
	prim.write_uvarint(w, e.lamport)
	prim.write_uvarint(w, u64(e.actor))
	prim.write_uvarint(w, e.seq)
}

@(private)
read_inode_id :: proc(r: ^prim.Reader) -> Inode_Id {
	actor := prim.read_uvarint(r)
	seq := prim.read_uvarint(r)
	if actor > u64(max(u32)) {
		prim.reader_fail(r, .Invalid)
		return {}
	}
	return Inode_Id{actor = u32(actor), seq = seq}
}

@(private)
read_event :: proc(r: ^prim.Reader) -> Event {
	lamport := prim.read_uvarint(r)
	actor := prim.read_uvarint(r)
	seq := prim.read_uvarint(r)
	if actor > u64(max(u32)) {
		prim.reader_fail(r, .Invalid)
		return {}
	}
	return Event{lamport = lamport, seq = seq, actor = u32(actor)}
}

@(private)
read_flags :: proc(r: ^prim.Reader) -> Flags {
	v := prim.read_u8(r)
	f := transmute(Flags)v
	if f - ALL_FLAGS != {} {
		prim.reader_fail(r, .Invalid)
		return {}
	}
	return f
}

@(private)
read_kind :: proc(r: ^prim.Reader) -> Kind {
	v := prim.read_u8(r)
	if v > u8(Kind.Symlink) {
		prim.reader_fail(r, .Invalid)
		return .File
	}
	return Kind(v)
}

@(private)
read_count :: proc(r: ^prim.Reader, min_size: int) -> int {
	n := prim.read_uvarint(r)
	if r.err != .None {
		return 0
	}
	if n > u64(prim.reader_remaining(r) / min_size) {
		prim.reader_fail(r, .Short)
		return 0
	}
	return int(n)
}

encode_inode :: proc(w: ^prim.Writer, n: ^Inode) {
	prim.write_u8(w, RECORD_VERSION)
	write_inode_id(w, n.id)
	prim.write_u8(w, u8(n.kind))
	prim.write_uvarint(w, u64(n.present_children))
	prim.write_uvarint(w, u64(max(n.cur, 0)))
	prim.write_uvarint(w, u64(len(n.moves)))
	for m in n.moves {
		write_event(w, m.event)
		write_inode_id(w, m.parent)
		prim.write_str(w, m.name)
		prim.write_bool(w, m.applied)
	}
	prim.write_uvarint(w, u64(len(n.alive_log)))
	for e in n.alive_log {
		write_event(w, e.event)
		prim.write_bool(w, e.alive)
	}
	prim.write_uvarint(w, u64(len(n.flag_log)))
	for e in n.flag_log {
		write_event(w, e.event)
		prim.write_u8(w, transmute(u8)e.mask)
		prim.write_u8(w, transmute(u8)e.value)
	}
	prim.write_uvarint(w, u64(len(n.targets)))
	for e in n.targets {
		write_event(w, e.event)
		prim.write_str(w, e.target)
	}
}

decode_inode :: proc(record: []u8, allocator := context.allocator) -> (n: Inode, err: Error) {
	r := prim.reader(record)
	if prim.read_u8(&r) != RECORD_VERSION {
		return {}, .Corrupt
	}
	n.id = read_inode_id(&r)
	n.kind = read_kind(&r)
	children := prim.read_uvarint(&r)
	cur := prim.read_uvarint(&r)
	if children > u64(max(u32)) {
		return {}, .Corrupt
	}
	n.present_children = u32(children)
	n.moves = make([dynamic]Move, allocator)
	n.alive_log = make([dynamic]Alive_Entry, allocator)
	n.flag_log = make([dynamic]Flag_Entry, allocator)
	n.targets = make([dynamic]Target_Entry, allocator)
	defer if err != nil {
		for m in n.moves {
			delete(m.name, allocator)
		}
		for e in n.targets {
			delete(e.target, allocator)
		}
		delete(n.moves)
		delete(n.alive_log)
		delete(n.flag_log)
		delete(n.targets)
		n = {}
	}
	count := read_count(&r, 6)
	reserve(&n.moves, count) or_return
	for _ in 0 ..< count {
		ev := read_event(&r)
		parent := read_inode_id(&r)
		name := prim.read_str(&r)
		applied := prim.read_bool(&r)
		if r.err != .None {
			break
		}
		owned := strings.clone(name, allocator) or_return
		append(&n.moves, Move{event = ev, parent = parent, name = owned, applied = applied}) or_return
	}
	count = read_count(&r, 4)
	reserve(&n.alive_log, count) or_return
	for _ in 0 ..< count {
		ev := read_event(&r)
		alive := prim.read_bool(&r)
		if r.err != .None {
			break
		}
		append(&n.alive_log, Alive_Entry{event = ev, alive = alive}) or_return
	}
	count = read_count(&r, 5)
	reserve(&n.flag_log, count) or_return
	for _ in 0 ..< count {
		ev := read_event(&r)
		mask := read_flags(&r)
		value := read_flags(&r)
		if r.err != .None {
			break
		}
		append(&n.flag_log, Flag_Entry{event = ev, mask = mask, value = value}) or_return
	}
	count = read_count(&r, 4)
	reserve(&n.targets, count) or_return
	for _ in 0 ..< count {
		ev := read_event(&r)
		target := prim.read_str(&r)
		if r.err != .None {
			break
		}
		owned := strings.clone(target, allocator) or_return
		append(&n.targets, Target_Entry{event = ev, target = owned}) or_return
	}
	if !prim.reader_done(&r) || len(n.moves) == 0 || cur >= u64(len(n.moves)) || !n.moves[cur].applied || !n.moves[0].applied {
		return n, .Corrupt
	}
	for m in n.moves {
		if !valid_name(m.name) {
			return n, .Corrupt
		}
	}
	n.cur = int(cur)
	n.listed = n.cur
	n.alive = true if len(n.alive_log) == 0 else n.alive_log[len(n.alive_log) - 1].alive
	recompute_flags(&n)
	return n, nil
}

encode_node :: proc(w: ^prim.Writer, n: ^Node) {
	prim.write_u8(w, RECORD_VERSION)
	prim.write_bool(w, n.leaf)
	prim.write_uvarint(w, n.next)
	if n.leaf {
		prim.write_uvarint(w, u64(len(n.entries)))
		for e in n.entries {
			prim.write_str(w, entry_name(n, e))
			write_inode_id(w, e.inode)
			write_event(w, e.event)
			prim.write_u8(w, u8(e.kind))
			bits: u8 = 0
			if e.alive {
				bits |= 1
			}
			if e.present {
				bits |= 2
			}
			prim.write_u8(w, bits)
			prim.write_uvarint(w, e.alive_lamport)
		}
		return
	}
	prim.write_uvarint(w, u64(len(n.kids)))
	for k in n.kids {
		prim.write_uvarint(w, k)
	}
	for sp in n.seps {
		prim.write_str(w, sep_name(n, sp))
		write_event(w, sp.event)
		write_inode_id(w, sp.inode)
	}
}

decode_node :: proc(record: []u8, allocator := context.allocator) -> (n: Node, err: Error) {
	err = decode_node_into(record, &n, allocator)
	return
}

@(private)
arena_add :: proc(n: ^Node, name: string) -> (off: u32, err: Error) {
	if u64(len(n.arena)) + u64(len(name)) > u64(max(u32)) {
		return 0, .Corrupt
	}
	off = u32(len(n.arena))
	append(&n.arena, name) or_return
	return off, nil
}

@(private)
decode_node_into :: proc(record: []u8, n: ^Node, allocator: runtime.Allocator) -> (err: Error) {
	r := prim.reader(record)
	n^ = {}
	n.entries = make([dynamic]Entry, allocator)
	n.seps = make([dynamic]Sep, allocator)
	n.kids = make([dynamic]u64, allocator)
	n.arena = make([dynamic]u8, allocator)
	defer if err != nil {
		node_destroy(n)
	}
	if prim.read_u8(&r) != RECORD_VERSION {
		return .Corrupt
	}
	n.leaf = prim.read_bool(&r)
	n.next = prim.read_uvarint(&r)
	if n.leaf {
		count := read_count(&r, 9)
		reserve(&n.entries, count) or_return
		reserve(&n.arena, prim.reader_remaining(&r)) or_return
		for _ in 0 ..< count {
			name := prim.read_str(&r)
			id := read_inode_id(&r)
			ev := read_event(&r)
			kind := read_kind(&r)
			bits := prim.read_u8(&r)
			alive_lamport := prim.read_uvarint(&r)
			if r.err != .None {
				break
			}
			if bits > 3 || !valid_name(name) {
				return .Corrupt
			}
			off := arena_add(n, name) or_return
			e := Entry {
				inode         = id,
				event         = ev,
				alive_lamport = alive_lamport,
				name_off      = off,
				name_len      = u32(len(name)),
				kind          = kind,
				alive         = bits & 1 != 0,
				present       = bits & 2 != 0,
			}
			append(&n.entries, e) or_return
		}
	} else {
		kids := read_count(&r, 1)
		if kids == 0 {
			return .Corrupt
		}
		reserve(&n.kids, kids) or_return
		for _ in 0 ..< kids {
			append(&n.kids, prim.read_uvarint(&r)) or_return
		}
		reserve(&n.seps, kids - 1) or_return
		reserve(&n.arena, prim.reader_remaining(&r)) or_return
		for _ in 0 ..< kids - 1 {
			name := prim.read_str(&r)
			ev := read_event(&r)
			id := read_inode_id(&r)
			if r.err != .None {
				break
			}
			if !valid_name(name) {
				return .Corrupt
			}
			off := arena_add(n, name) or_return
			append(&n.seps, Sep{inode = id, event = ev, name_off = off, name_len = u32(len(name))}) or_return
		}
	}
	if !prim.reader_done(&r) {
		return .Corrupt
	}
	return nil
}

encode_inode_record :: proc(t: ^Tree, id: Inode_Id, buf: ^[dynamic]u8) -> bool {
	n, ok := t.inodes[id]
	if !ok || id == ROOT {
		return false
	}
	w := prim.writer(buf)
	encode_inode(&w, n)
	return w.err == .None
}

encode_node_record :: proc(t: ^Tree, key: Node_Key, buf: ^[dynamic]u8) -> bool {
	n, ok := t.nodes[key]
	if !ok {
		return false
	}
	w := prim.writer(buf)
	encode_node(&w, n)
	return w.err == .None
}
