package convo

import "../journal"
import "../obj"
import "../prim"

DRAFT_RECORD :: u8(0x44)
DRAFT_MSG_MIN :: 32
DRAFT_KEY_GAP :: 16

@(private)
DRAFT_START :: u8(1)
@(private)
DRAFT_FAILED :: u8(2)

Draft_Rec :: struct {
	msg:    i64,
	prev:   i64,
	index:  u32,
	off:    i64,
	start:  bool,
	failed: bool,
	kind:   Block_Kind,
	id:     string,
	name:   string,
	data:   []u8,
}

Draft_Msg :: struct {
	msg:     i64,
	last:    i64,
	first:   i64,
	index:   u32,
	retired: i64,
}

@(private)
Draft :: struct {
	open:   bool,
	j:      journal.Journal,
	path:   string,
	gen:    u64,
	msgs:   [MAX_OPEN]Draft_Msg,
	n:      int,
	off:    [MAX_OPEN]i64,
	off_n:  int,
}

Draft_Run :: struct {
	at:  i64,
	end: i64,
}

draft_encode :: proc(r: Draft_Rec, buf: ^[dynamic]u8) {
	w := prim.writer(buf)
	prim.write_u8(&w, DRAFT_RECORD)
	prim.write_uvarint(&w, u64(r.msg))
	prim.write_uvarint(&w, u64(r.prev + 1))
	prim.write_uvarint(&w, u64(r.index))
	prim.write_uvarint(&w, u64(r.off))
	flags: u8
	if r.start {
		flags |= DRAFT_START
	}
	if r.failed {
		flags |= DRAFT_FAILED
	}
	prim.write_u8(&w, flags)
	if r.start {
		prim.write_u8(&w, u8(r.kind))
		prim.write_str(&w, r.id)
		prim.write_str(&w, r.name)
	}
	prim.write_raw(&w, r.data)
}

draft_decode :: proc(body: []u8) -> (r: Draft_Rec, err: Error) {
	rd := prim.reader(body)
	if prim.read_u8(&rd) != DRAFT_RECORD {
		return r, .Corrupt
	}
	r.msg = i64(prim.read_uvarint(&rd))
	r.prev = i64(prim.read_uvarint(&rd)) - 1
	index := prim.read_uvarint(&rd)
	r.off = i64(prim.read_uvarint(&rd))
	flags := prim.read_u8(&rd)
	r.start = flags & DRAFT_START != 0
	r.failed = flags & DRAFT_FAILED != 0
	if r.start {
		r.kind = Block_Kind(prim.read_u8(&rd))
		r.id = prim.read_str(&rd)
		r.name = prim.read_str(&rd)
	}
	r.data = prim.read_rest(&rd)
	if !prim.reader_ok(&rd) || index > u64(max(u32)) || r.msg <= 0 || r.prev < -1 || r.off < 0 || r.off > i64(1) << 48 || (r.start && (r.off != 0 || u8(r.kind) < 1 || r.kind > max(Block_Kind))) {
		return r, .Corrupt
	}
	r.index = u32(index)
	return r, .None
}

draft_key_offset :: proc "contextless" (msg: i64) -> i64 {
	return (msg >> 4 + 1) << 4
}

writer_draft_gen :: proc "contextless" (w: ^Writer) -> u64 {
	return w.draft.gen
}

writer_draft_durable :: proc "contextless" (w: ^Writer) -> i64 {
	if !w.draft.open {
		return 0
	}
	return journal.journal_durable_len(&w.draft.j)
}

writer_draft_live :: proc(w: ^Writer) -> []Draft_Msg {
	return w.draft.msgs[:w.draft.n]
}

writer_draft_reader :: proc(w: ^Writer, r: ^journal.Reader, allocator := context.temp_allocator) -> bool {
	if !w.draft.open {
		return false
	}
	journal.journal_reader(&w.draft.j, r, allocator)
	return true
}

writer_draft_serve :: proc(w: ^Writer, msg: i64, from: i64, allocator := context.temp_allocator) -> (runs: [dynamic]Draft_Run, err: Error) {
	runs = make([dynamic]Draft_Run, allocator)
	e := _draft_find(w, msg)
	if e == nil {
		return runs, .None
	}
	start := max(from, e.first)
	r: journal.Reader
	defer journal.reader_close(&r)
	pos := start
	end := journal.journal_durable_len(&w.draft.j)
	journal.journal_reader(&w.draft.j, &r, context.temp_allocator)
	for pos < end {
		body, next, je := journal.record_at(&r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			return runs, .Corrupt
		}
		if d, derr := draft_decode(body); derr == .None && d.msg == msg {
			if n := len(runs); n > 0 && runs[n - 1].end == pos {
				runs[n - 1].end = next
			} else {
				append(&runs, Draft_Run{at = pos, end = next})
			}
		}
		pos = next
	}
	return runs, .None
}

writer_draft_redact :: proc(w: ^Writer, msg: i64) -> Error {
	if w.buf.active && w.buf.msg == msg {
		_flush(w) or_return
	}
	_draft_disable(w, msg)
	if !w.draft.open {
		return .None
	}
	offs := make([dynamic]i64, context.temp_allocator)
	r: journal.Reader
	journal.journal_reader(&w.draft.j, &r, context.temp_allocator)
	pos := i64(0)
	end := journal.journal_durable_len(&w.draft.j)
	for pos < end {
		body, next, je := journal.record_at(&r, pos)
		if je == .None {
			if d, derr := draft_decode(body); derr == .None && d.msg == msg {
				append(&offs, pos)
			}
		} else if je != .Redacted {
			break
		}
		pos = next
	}
	journal.reader_close(&r)
	_draft_drop(w, msg)
	if len(offs) > 0 {
		if err := journal.journal_redact_records(&w.draft.j, offs[:]); err != .None {
			return .Io
		}
	}
	return _draft_maybe_reset(w)
}

@(private)
_draft_find :: proc(w: ^Writer, msg: i64) -> ^Draft_Msg {
	for i in 0 ..< w.draft.n {
		if w.draft.msgs[i].msg == msg {
			return &w.draft.msgs[i]
		}
	}
	return nil
}

@(private)
_draft_disabled :: proc(w: ^Writer, msg: i64) -> bool {
	for i in 0 ..< w.draft.off_n {
		if w.draft.off[i] == msg {
			return true
		}
	}
	return false
}

@(private)
_draft_disable :: proc(w: ^Writer, msg: i64) {
	if _draft_disabled(w, msg) {
		return
	}
	if w.draft.off_n == MAX_OPEN {
		copy(w.draft.off[:], w.draft.off[1:])
		w.draft.off_n -= 1
	}
	w.draft.off[w.draft.off_n] = msg
	w.draft.off_n += 1
}

@(private)
_draft_drop :: proc(w: ^Writer, msg: i64) {
	for i in 0 ..< w.draft.n {
		if w.draft.msgs[i].msg == msg {
			w.draft.msgs[i] = w.draft.msgs[w.draft.n - 1]
			w.draft.n -= 1
			return
		}
	}
}

@(private)
_draft_entry :: proc(w: ^Writer, msg: i64) -> ^Draft_Msg {
	if e := _draft_find(w, msg); e != nil {
		return e
	}
	if _draft_disabled(w, msg) || w.draft.n >= MAX_OPEN || len(w.draft.path) == 0 {
		return nil
	}
	_, next, err := obj.get(w.core.v, w.core.seg, msg)
	if err != .None || next - msg < DRAFT_MSG_MIN {
		_draft_disable(w, msg)
		return nil
	}
	if !w.draft.open {
		if journal.journal_open(&w.draft.j, w.core.vfs, w.draft.path, {}, w.allocator) != .None {
			_draft_disable(w, msg)
			return nil
		}
		w.draft.open = true
	}
	w.draft.msgs[w.draft.n] = Draft_Msg{msg = msg, last = -1, first = -1}
	w.draft.n += 1
	return &w.draft.msgs[w.draft.n - 1]
}

@(private)
_draft_write :: proc(w: ^Writer) -> Error {
	b := &w.buf
	if !b.active || len(b.data) <= b.drafted {
		return .None
	}
	e := _draft_entry(w, b.msg)
	if e == nil {
		return _flush(w)
	}
	off := b.pos + i64(b.drafted)
	rec := Draft_Rec {
		msg   = b.msg,
		prev  = e.last,
		index = b.index,
		off   = off,
		data  = b.data[b.drafted:],
	}
	if off == 0 && b.start {
		rec.start = true
		rec.kind = b.kind
		rec.failed = .Failed in b.flags
		rec.id = string(b.meta[:b.id_len])
		rec.name = string(b.meta[b.id_len:])
	}
	buf := make([dynamic]u8, context.temp_allocator)
	draft_encode(rec, &buf)
	at, jerr := journal.journal_append(&w.draft.j, buf[:])
	if jerr != .None {
		return .Io
	}
	if e.first < 0 || e.index != b.index {
		e.first = at
		e.index = b.index
	}
	e.last = at
	b.drafted = len(b.data)
	return .None
}

@(private)
_draft_commit :: proc(w: ^Writer) -> Error {
	if !w.draft.open {
		return .None
	}
	if journal.journal_commit(&w.draft.j) != .None {
		return .Io
	}
	for &e in w.draft.msgs[:w.draft.n] {
		if e.retired == 0 && summary_find(&w.sum, e.msg) < 0 {
			e.retired = max(obj.writer_len(&w.core), 1)
		}
	}
	if !w.core.j.atomic {
		return writer_draft_settle(w, obj.writer_durable(&w.core))
	}
	return .None
}

writer_draft_settle :: proc(w: ^Writer, durable: i64) -> Error {
	for i := 0; i < w.draft.n; {
		e := w.draft.msgs[i]
		if e.retired > 0 && e.retired <= durable {
			w.draft.msgs[i] = w.draft.msgs[w.draft.n - 1]
			w.draft.n -= 1
			continue
		}
		i += 1
	}
	return _draft_maybe_reset(w)
}

@(private)
_draft_maybe_reset :: proc(w: ^Writer) -> Error {
	if !w.draft.open || w.draft.n > 0 || (w.buf.active && len(w.buf.data) > w.buf.drafted) {
		return .None
	}
	if journal.journal_len(&w.draft.j) == 0 {
		return .None
	}
	journal.journal_close(&w.draft.j)
	w.draft.open = false
	w.draft.gen += 1
	if journal.journal_remove(w.core.vfs, w.draft.path) != .None {
		return .Io
	}
	return .None
}

@(private)
_draft_close :: proc(w: ^Writer) {
	if w.draft.open {
		journal.journal_close(&w.draft.j)
		w.draft.open = false
	}
	if len(w.draft.path) > 0 {
		delete(w.draft.path, w.allocator)
		w.draft.path = ""
	}
}

@(private)
_draft_set_path :: proc(w: ^Writer, path: string) -> Error {
	out, err := make([]u8, len(path) + len(".draft"), w.allocator)
	if err != nil {
		return .No_Memory
	}
	n := copy(out, path)
	copy(out[n:], ".draft")
	w.draft.path = string(out)
	return .None
}

@(private)
_seg_block_len :: proc(w: ^Writer, msg: i64, index: u32) -> (n: i64, err: Error) {
	i := summary_find(&w.sum, msg)
	if i < 0 {
		return 0, .Invalid
	}
	off := w.sum.open[i].last
	for off != 0 {
		body, _ := obj.get(w.core.v, w.core.seg, off) or_return
		if obj.is_redacted(body) {
			return n, .Invalid
		}
		rec := decode_record(body, off, w.core.v.scratch) or_return
		blk, ok := rec.body.(Block)
		if !ok || blk.msg != msg || blk.index < index {
			break
		}
		if blk.index == index {
			n += i64(len(blk.data))
		}
		off = blk.prev
	}
	return n, .None
}

@(private)
_draft_recover :: proc(w: ^Writer) -> Error {
	st, serr := prim.stat(w.core.vfs, w.draft.path)
	if serr == .Not_Found {
		return .None
	}
	if serr != .None {
		return .Io
	}
	_ = st
	if journal.journal_open(&w.draft.j, w.core.vfs, w.draft.path, {}, w.allocator) != .None {
		journal.journal_remove(w.core.vfs, w.draft.path)
		return .None
	}
	w.draft.open = true
	r: journal.Reader
	journal.journal_reader(&w.draft.j, &r, context.temp_allocator)
	defer journal.reader_close(&r)
	end := journal.journal_durable_len(&w.draft.j)
	pos := i64(0)
	for pos < end {
		body, next, je := journal.record_at(&r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			break
		}
		d, derr := draft_decode(body)
		if derr == .None && summary_find(&w.sum, d.msg) >= 0 {
			e := _draft_find(w, d.msg)
			if e == nil && w.draft.n < MAX_OPEN {
				w.draft.msgs[w.draft.n] = Draft_Msg{msg = d.msg, last = -1, first = -1}
				w.draft.n += 1
				e = &w.draft.msgs[w.draft.n - 1]
			}
			if e != nil && e.last == d.prev {
				if e.first < 0 || e.index != d.index {
					e.first = pos
					e.index = d.index
				}
				e.last = pos
				_draft_finalize(w, d) or_return
			}
		}
		pos = next
	}
	_flush(w) or_return
	return _draft_maybe_reset(w)
}

@(private)
_draft_finalize :: proc(w: ^Writer, d: Draft_Rec) -> Error {
	i := summary_find(&w.sum, d.msg)
	if i < 0 {
		return .None
	}
	b := &w.buf
	if b.active && b.msg == d.msg && b.index == d.index {
		end := b.pos + i64(len(b.data))
		if d.off + i64(len(d.data)) > end && d.off <= end {
			append(&b.data, ..d.data[end - d.off:])
			b.drafted = len(b.data)
		}
		return .None
	}
	_flush(w) or_return
	i = summary_find(&w.sum, d.msg)
	blocks := w.sum.open[i].blocks
	if d.index + 1 == blocks {
		have := _seg_block_len(w, d.msg, d.index) or_return
		if d.off > have || d.off + i64(len(d.data)) <= have {
			return .None
		}
		clear(&b.meta)
		clear(&b.data)
		append(&b.data, ..d.data[have - d.off:])
		b.active = true
		b.start = false
		b.msg = d.msg
		b.index = d.index
		b.flags = {}
		b.id_len = 0
		b.pos = have
		b.drafted = len(b.data)
		return .None
	}
	if d.index != blocks || !d.start || blocks == max(u32) {
		return .None
	}
	clear(&b.meta)
	clear(&b.data)
	append(&b.meta, d.id)
	append(&b.meta, d.name)
	append(&b.data, ..d.data)
	w.sum.open[i].blocks += 1
	b.active = true
	b.start = true
	b.msg = d.msg
	b.index = d.index
	b.kind = d.kind
	b.flags = {.Failed} if d.failed else {}
	b.id_len = len(d.id)
	b.pos = 0
	b.drafted = len(b.data)
	return .None
}

Draft_State :: enum u8 {
	Unknown,
	Open,
	Closed,
}

draft_msg_state :: proc(v: ^obj.View, s: int, msg: i64) -> Draft_State {
	if s < 0 || s >= len(v.segs) || msg <= 0 {
		return .Unknown
	}
	sum, ok, err := _tail(v, s)
	if err != .None || !ok {
		return .Unknown
	}
	if summary_find(&sum, msg) >= 0 {
		return .Open
	}
	if msg < obj.end(v, s) {
		return .Closed
	}
	return .Unknown
}

draft_open_msgs :: proc(v: ^obj.View, s: int, out: ^[dynamic]Open) -> Error {
	if s < 0 || s >= len(v.segs) {
		return .None
	}
	sum, ok := _tail(v, s) or_return
	if !ok {
		return .None
	}
	for o in summary_open(&sum) {
		if o.state == .Running {
			append(out, o)
		}
	}
	return .None
}

draft_block_len :: proc(v: ^obj.View, s: int, o: Open) -> (n: i64, err: Error) {
	if o.blocks == 0 {
		return 0, .None
	}
	index := o.blocks - 1
	off := o.last
	for off != 0 {
		body, _ := obj.get(v, s, off) or_return
		if obj.is_redacted(body) {
			return n, .None
		}
		rec := decode_record(body, off, v.scratch) or_return
		blk, isb := rec.body.(Block)
		if !isb || blk.msg != o.msg || blk.index < index {
			break
		}
		if blk.index == index {
			n += i64(len(blk.data))
		}
		off = blk.prev
	}
	return n, .None
}
