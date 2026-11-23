package dlog

import "../journal"
import "../prim"

REC_ADD :: u8(1)
REC_DONE :: u8(2)
SPANS_MAX :: 4096

Error :: enum u8 {
	None,
	Io,
	Invalid,
}

Span :: struct {
	actor: prim.Id,
	seq:   u64,
	len:   int,
}

Entry :: struct {
	id:          u64,
	space:       prim.Id,
	object:      prim.Id,
	kind:        u8,
	inode_actor: prim.Id,
	inode_seq:   u64,
	actor:       prim.Id,
	line:        string,
	spans:       []Span,
}

Log :: struct {
	vfs:  prim.Vfs,
	path: string,
	j:    journal.Journal,
	open: bool,
	live: [dynamic]Entry,
}

open :: proc(l: ^Log, vfs: prim.Vfs, path: string, allocator := context.allocator) -> Error {
	l.vfs = vfs
	l.path = path
	l.live = make([dynamic]Entry, allocator)
	if !prim.exists(vfs, path) {
		return .None
	}
	_journal_open(l) or_return
	rd: journal.Reader
	journal.journal_reader(&l.j, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	end := journal.journal_durable_len(&l.j)
	pos: i64
	for pos < end {
		body, next, err := journal.record_at(&rd, pos)
		if err != .None {
			break
		}
		at := pos
		pos = next
		if len(body) == 0 {
			continue
		}
		switch body[0] {
		case REC_ADD:
			x, ok := _decode(body, u64(at), allocator)
			if ok {
				append(&l.live, x)
			}
		case REC_DONE:
			r := prim.reader(body[1:])
			id := prim.read_uvarint(&r)
			if prim.reader_ok(&r) {
				_drop(l, id)
			}
		}
	}
	return .None
}

close :: proc(l: ^Log) {
	if l.open {
		journal.journal_close(&l.j)
		l.open = false
	}
	for x in l.live {
		_free(l, x)
	}
	delete(l.live)
}

add :: proc(l: ^Log, x: Entry) -> (id: u64, err: Error) {
	if len(x.spans) == 0 || len(x.spans) > SPANS_MAX {
		return 0, .Invalid
	}
	for s in x.spans {
		if s.len <= 0 {
			return 0, .Invalid
		}
	}
	_journal_open(l) or_return
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, REC_ADD)
	prim.write_id(&w, x.space)
	prim.write_id(&w, x.object)
	prim.write_u8(&w, x.kind)
	prim.write_id(&w, x.inode_actor)
	prim.write_uvarint(&w, x.inode_seq)
	prim.write_id(&w, x.actor)
	prim.write_str(&w, x.line)
	prim.write_uvarint(&w, u64(len(x.spans)))
	for s in x.spans {
		prim.write_id(&w, s.actor)
		prim.write_uvarint(&w, s.seq)
		prim.write_uvarint(&w, u64(s.len))
	}
	off, aerr := journal.journal_append(&l.j, buf[:])
	if aerr != .None {
		journal.journal_abort(&l.j)
		return 0, .Io
	}
	if journal.journal_commit(&l.j) != .None {
		return 0, .Io
	}
	y, ok := _decode(buf[:], u64(off), l.live.allocator)
	if !ok {
		return 0, .Invalid
	}
	append(&l.live, y)
	return u64(off), .None
}

done :: proc(l: ^Log, id: u64) -> Error {
	if !_drop(l, id) {
		return .None
	}
	_journal_open(l) or_return
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, REC_DONE)
	prim.write_uvarint(&w, id)
	if _, aerr := journal.journal_append(&l.j, buf[:]); aerr != .None {
		journal.journal_abort(&l.j)
		return .Io
	}
	if journal.journal_commit(&l.j) != .None {
		return .Io
	}
	if len(l.live) == 0 {
		journal.journal_close(&l.j)
		l.open = false
		if journal.journal_remove(l.vfs, l.path) != .None {
			return .Io
		}
	}
	return .None
}

@(private)
_journal_open :: proc(l: ^Log) -> Error {
	if l.open {
		return .None
	}
	if journal.journal_open(&l.j, l.vfs, l.path, {}, l.live.allocator) != .None {
		return .Io
	}
	l.open = true
	return .None
}

@(private)
_drop :: proc(l: ^Log, id: u64) -> bool {
	for x, i in l.live {
		if x.id == id {
			_free(l, x)
			ordered_remove(&l.live, i)
			return true
		}
	}
	return false
}

@(private)
_free :: proc(l: ^Log, x: Entry) {
	delete(x.line, l.live.allocator)
	delete(x.spans, l.live.allocator)
}

@(private)
_decode :: proc(body: []u8, id: u64, allocator := context.allocator) -> (x: Entry, ok: bool) {
	r := prim.reader(body[1:])
	x.id = id
	x.space = prim.read_id(&r)
	x.object = prim.read_id(&r)
	x.kind = prim.read_u8(&r)
	x.inode_actor = prim.read_id(&r)
	x.inode_seq = prim.read_uvarint(&r)
	x.actor = prim.read_id(&r)
	line := prim.read_str(&r)
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || n == 0 || n > SPANS_MAX {
		return {}, false
	}
	spans := make([]Span, int(n), allocator)
	for i in 0 ..< int(n) {
		spans[i].actor = prim.read_id(&r)
		spans[i].seq = prim.read_uvarint(&r)
		spans[i].len = int(prim.read_uvarint(&r))
		if spans[i].len <= 0 {
			r.err = .Invalid
		}
	}
	if !prim.reader_ok(&r) || prim.reader_remaining(&r) != 0 {
		delete(spans, allocator)
		return {}, false
	}
	x.line = string(make([]u8, len(line), allocator))
	copy(transmute([]u8)x.line, line)
	x.spans = spans
	return x, true
}
