package fs

import "base:runtime"
import "../crdt"
import "../fstree"
import "../prim"

Text_Conflict :: struct {
	inode:  fstree.Inode_Id,
	start:  int,
	end:    int,
	ours:   []crdt.Op_Span,
	theirs: []crdt.Op_Span,
}

@(private)
CONFLICT_LIST :: "tcl"

@(private)
record_text_conflicts :: proc(h: ^History, ino: fstree.Inode_Id, found: []crdt.Conflict) -> Error {
	if len(found) == 0 {
		return .None
	}
	key := inode_key("tc:", ino)
	old, had := kv_get(&h.kv, key, context.temp_allocator) or_return
	known := make([dynamic]Text_Conflict, context.temp_allocator)
	if had {
		decode_text_conflicts(old, ino, &known, context.temp_allocator) or_return
	}
	buf := make([dynamic]u8, 0, len(old) + 64, context.temp_allocator)
	append(&buf, ..old)
	added := false
	for c in found {
		dup := false
		for k in known {
			if spans_equal(k.ours, c.ours) && spans_equal(k.theirs, c.theirs) || spans_equal(k.ours, c.theirs) && spans_equal(k.theirs, c.ours) {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		append(&known, Text_Conflict{inode = ino, start = c.start, end = c.end, ours = c.ours, theirs = c.theirs})
		w := prim.writer(&buf)
		prim.write_uvarint(&w, u64(c.start))
		prim.write_uvarint(&w, u64(c.end))
		write_spans(&w, c.ours)
		write_spans(&w, c.theirs)
		added = true
	}
	if !added {
		return .None
	}
	kv_put(&h.kv, key, buf[:]) or_return
	if !had {
		list, _ := kv_get(&h.kv, transmute([]u8)string(CONFLICT_LIST), context.temp_allocator) or_return
		lb := make([dynamic]u8, 0, len(list) + 12, context.temp_allocator)
		append(&lb, ..list)
		w := prim.writer(&lb)
		prim.write_u32le(&w, ino.actor)
		prim.write_u64le(&w, ino.seq)
		kv_put(&h.kv, transmute([]u8)string(CONFLICT_LIST), lb[:]) or_return
	}
	return .None
}

history_text_conflicts :: proc(h: ^History, out: ^[dynamic]Text_Conflict, allocator := context.allocator) -> Error {
	list, found := kv_get(&h.kv, transmute([]u8)string(CONFLICT_LIST), context.temp_allocator) or_return
	if !found {
		return .None
	}
	rd := prim.reader(list)
	for prim.reader_remaining(&rd) >= 12 {
		ino := fstree.Inode_Id{prim.read_u32le(&rd), prim.read_u64le(&rd)}
		data, ok := kv_get(&h.kv, inode_key("tc:", ino), context.temp_allocator) or_return
		if ok {
			decode_text_conflicts(data, ino, out, allocator) or_return
		}
	}
	return .None
}

@(private)
decode_text_conflicts :: proc(data: []u8, ino: fstree.Inode_Id, out: ^[dynamic]Text_Conflict, allocator: runtime.Allocator) -> Error {
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		c := Text_Conflict{inode = ino}
		c.start = int(prim.read_uvarint(&rd))
		c.end = int(prim.read_uvarint(&rd))
		c.ours = read_spans(&rd, allocator) or_return
		c.theirs = read_spans(&rd, allocator) or_return
		if !prim.reader_ok(&rd) {
			return .Corrupt
		}
		append(out, c)
	}
	return .None
}

@(private)
write_spans :: proc(w: ^prim.Writer, spans: []crdt.Op_Span) {
	prim.write_uvarint(w, u64(len(spans)))
	for s in spans {
		prim.write_id(w, s.id.actor)
		prim.write_uvarint(w, s.id.seq)
		prim.write_uvarint(w, u64(s.len))
	}
}

@(private)
read_spans :: proc(rd: ^prim.Reader, allocator: runtime.Allocator) -> (out: []crdt.Op_Span, err: Error) {
	n := prim.read_uvarint(rd)
	if n > u64(prim.reader_remaining(rd)) {
		return nil, .Corrupt
	}
	s, aerr := make([]crdt.Op_Span, int(n), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	for i in 0 ..< int(n) {
		s[i].id.actor = prim.read_id(rd)
		s[i].id.seq = prim.read_uvarint(rd)
		s[i].len = int(prim.read_uvarint(rd))
	}
	return s, .None
}

@(private)
spans_equal :: proc(a, b: []crdt.Op_Span) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x in a {
		hit := false
		for y in b {
			if x == y {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	return true
}

history_text_conflicts_clear :: proc(h: ^History) -> Error {
	list, found := kv_get(&h.kv, transmute([]u8)string(CONFLICT_LIST), context.temp_allocator) or_return
	if !found {
		return .None
	}
	rd := prim.reader(list)
	for prim.reader_remaining(&rd) >= 12 {
		ino := fstree.Inode_Id{prim.read_u32le(&rd), prim.read_u64le(&rd)}
		kv_del(&h.kv, inode_key("tc:", ino)) or_return
	}
	kv_del(&h.kv, transmute([]u8)string(CONFLICT_LIST)) or_return
	return kv_commit(&h.kv)
}
