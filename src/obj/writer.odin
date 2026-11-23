package obj

import "base:runtime"
import "../journal"
import "../prim"

Clock :: struct {
	data:    rawptr,
	wall_ms: proc(data: rawptr) -> i64,
}

Writer :: struct {
	source:    Clock,
	vfs:       prim.Vfs,
	j:         journal.Journal,
	jr:        journal.Reader,
	lock:      prim.Fd,
	object:    prim.Id,
	kind:      Kind,
	id:        prim.Id,
	gen:       u64,
	gen_from:  i64,
	created:   prim.Hlc,
	ids:       [dynamic]prim.Id,
	ids_dirty: bool,
	event:     i64,
	segs:      i64,
	clock:     prim.Hlc,
	v:         ^View,
	seg:       int,
	allocator: runtime.Allocator,
}

Rec :: struct {
	pw:        prim.Writer,
	off:       i64,
	kind:      u8,
	links:     Links,
	extra:     []u8,
	links_at:  int,
	fields_at: int,
	open:      bool,
}

Redaction :: struct {
	seg:  prim.Id,
	from: i64,
	to:   i64,
}

writer_create :: proc(w: ^Writer, v: ^View, vfs: prim.Vfs, path: string, object: prim.Id, kind: Kind, id: prim.Id, gen: u64, created: prim.Hlc, settings: []u8 = nil, opts := journal.Options{}, allocator := context.allocator, clock := Clock{}) -> Error {
	_zero(w, vfs, allocator)
	w.source = clock
	if prim.id_is_zero(id) || prim.id_is_zero(object) || gen == 0 {
		return .Invalid
	}
	w.gen = gen
	lock, lerr := prim.lock_file(vfs, path)
	if lerr != .None {
		return perr(lerr)
	}
	w.lock = lock
	if err := jerr(journal.journal_open(&w.j, vfs, path, opts, allocator)); err != .None {
		_release(w)
		return err
	}
	if journal.journal_len(&w.j) != 0 {
		_release(w)
		return .Exists
	}
	if err := _attach(w, v, object, kind, id); err != .None {
		_release(w)
		return err
	}
	w.created = created
	observe(w, created)
	h := Head{
		object   = object,
		kind     = kind,
		format   = FORMAT_VERSION,
		seg      = id,
		created  = created,
		settings = settings,
	}
	pw, berr := journal.journal_begin(&w.j)
	if berr != .None {
		_release(w)
		return jerr(berr)
	}
	encode_head(&pw, &h, w.gen)
	if _, eerr := journal.journal_end(&w.j, &pw); eerr != .None {
		_release(w)
		return jerr(eerr)
	}
	if err := jerr(journal.journal_commit(&w.j)); err != .None {
		_release(w)
		return err
	}
	return .None
}

writer_open :: proc(w: ^Writer, v: ^View, vfs: prim.Vfs, path: string, object: prim.Id, kind: Kind, id: prim.Id, gen: u64, opts := journal.Options{}, allocator := context.allocator, clock := Clock{}) -> (head: Head, err: Error) {
	_zero(w, vfs, allocator)
	w.source = clock
	if gen == 0 {
		return head, .Invalid
	}
	w.gen = gen
	if !prim.exists(vfs, path) {
		return head, .Not_Found
	}
	lock, lerr := prim.lock_file(vfs, path)
	if lerr != .None {
		return head, perr(lerr)
	}
	w.lock = lock
	if e := jerr(journal.journal_open(&w.j, vfs, path, opts, allocator)); e != .None {
		_release(w)
		return head, e
	}
	if e := _attach(w, v, object, kind, id); e != .None {
		_release(w)
		return head, e
	}
	head, err = _recover(w)
	if err != .None {
		_release(w)
		return
	}
	w.gen_from = journal.journal_len(&w.j)
	return
}

writer_close :: proc(w: ^Writer) -> Error {
	err: Error
	if w.j.fd >= 0 {
		err = jerr(journal.journal_close(&w.j))
	}
	_release(w)
	return err
}

writer_commit :: proc(w: ^Writer) -> Error {
	return jerr(journal.journal_commit(&w.j))
}

writer_len :: proc "contextless" (w: ^Writer) -> i64 {
	return journal.journal_len(&w.j)
}

writer_durable :: proc "contextless" (w: ^Writer) -> i64 {
	return journal.journal_durable_len(&w.j)
}

wall_ms :: proc(w: ^Writer) -> i64 {
	if w.source.wall_ms != nil {
		return w.source.wall_ms(w.source.data)
	}
	prim.unrouted("a writer wall clock read without a source")
	return prim.now_ms()
}

observe :: proc(w: ^Writer, h: prim.Hlc) {
	if h > w.clock {
		prim.hlc_observe_at(&w.clock, h, wall_ms(w))
	}
}

now :: proc(w: ^Writer) -> prim.Hlc {
	return prim.hlc_tick(&w.clock, wall_ms(w))
}

local :: proc(w: ^Writer, r: Vref) -> (out: Ref, err: Error) {
	if vref_none(r) {
		return {}, .None
	}
	if r.seg == w.seg {
		return Ref{0, r.off}, .None
	}
	id := w.v.segs[r.seg].id
	for x, i in w.ids {
		if x == id && i > 0 {
			return Ref{u32(i), r.off}, .None
		}
	}
	if len(w.ids) >= MAX_SEGS {
		return {}, .Limit
	}
	append(&w.ids, id)
	w.ids_dirty = true
	return Ref{u32(len(w.ids) - 1), r.off}, .None
}

seg_flush :: proc(w: ^Writer, cross: bool) -> Error {
	if !w.ids_dirty && !(cross && len(w.ids) > 1 && journal.journal_len(&w.j) - w.segs > SEG_SPAN) {
		return .None
	}
	entries := make([]Seg_Entry, len(w.ids) - 1, context.temp_allocator)
	for i in 1 ..< len(w.ids) {
		entries[i - 1] = Seg_Entry{u32(i), w.ids[i]}
	}
	off := journal.journal_len(&w.j)
	l := Links{
		event = w.event,
		segs  = off,
		gen   = w.gen,
	}
	pw, berr := journal.journal_begin(&w.j)
	if berr != .None {
		return jerr(berr)
	}
	encode_seg(&pw, off, &l, entries)
	if _, eerr := journal.journal_end(&w.j, &pw); eerr != .None {
		return jerr(eerr)
	}
	w.segs = off
	w.ids_dirty = false
	return .None
}

begin :: proc(w: ^Writer, kind: u8, cross: bool, event: bool) -> (rec: Rec, err: Error) {
	if kind < RECORD_KIND_FIRST || kind > RECORD_KIND_LAST {
		return rec, .Invalid
	}
	seg_flush(w, cross) or_return
	rec.off = journal.journal_len(&w.j)
	rec.kind = kind
	rec.links = Links{
		event = w.event,
		segs  = w.segs,
		gen   = w.gen,
	}
	if event {
		rec.links.prev = w.event
		rec.links.event = rec.off
		rec.links.stamp = now(w)
	}
	pw, berr := journal.journal_begin(&w.j)
	if berr != .None {
		return rec, jerr(berr)
	}
	rec.pw = pw
	rec.open = true
	prim.write_u8(&rec.pw, kind)
	return rec, .None
}

put_links :: proc(rec: ^Rec, extra: []u8) {
	l := rec.links
	l.extra = extra
	rec.extra = extra
	rec.links_at = len(rec.pw.buf)
	encode_links(&rec.pw, rec.off, &l)
	rec.fields_at = len(rec.pw.buf)
}

finish :: proc(w: ^Writer, rec: ^Rec) -> (off: i64, err: Error) {
	if !rec.open {
		return 0, .Invalid
	}
	rec.open = false
	_zip(rec)
	got, eerr := journal.journal_end(&w.j, &rec.pw)
	if eerr != .None {
		return 0, jerr(eerr)
	}
	if got != rec.off {
		return 0, .Io
	}
	w.event = rec.links.event
	return got, .None
}

abort :: proc(w: ^Writer, rec: ^Rec) {
	if rec.open {
		journal.journal_abort(&w.j)
		rec.open = false
	}
}

writer_redact :: proc(w: ^Writer, from: Vref, to: i64, target: Vref, extra: []u8 = nil, cmd: prim.Id = {}) -> (off: i64, err: Error) {
	if vref_none(from) || to <= from.off {
		return 0, .Invalid
	}
	fr := local(w, from) or_return
	tr := local(w, target) or_return
	seg_flush(w, fr.seg != 0 || tr.seg != 0) or_return
	rec: Rec
	rec.off = journal.journal_len(&w.j)
	rec.links = Links{
		event = rec.off,
		segs  = w.segs,
		prev  = w.event,
		stamp = now(w),
		gen   = w.gen,
	}
	pw, berr := journal.journal_begin(&w.j)
	if berr != .None {
		return 0, jerr(berr)
	}
	l := rec.links
	l.extra = extra
	r := Redact{
		from   = fr,
		to     = to,
		target = tr,
		cmd    = cmd,
	}
	encode_redact(&pw, rec.off, &l, &r)
	got, eerr := journal.journal_end(&w.j, &pw)
	if eerr != .None {
		return 0, jerr(eerr)
	}
	w.event = rec.off
	if from.seg == w.seg {
		jerr(journal.journal_commit(&w.j)) or_return
		jerr(journal.journal_redact(&w.j, from.off, to)) or_return
		w.v.segs[w.seg].tail_end = -1
	}
	return got, .None
}

redactions :: proc(v: ^View, s: int, floor: prim.Hlc, allocator := context.allocator) -> (out: []Redaction, err: Error) {
	Acc :: struct {
		list: [dynamic]Redaction,
		v:    ^View,
	}
	acc := Acc{
		list = make([dynamic]Redaction, allocator),
		v    = v,
	}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^Envelope) -> (stop: bool, err: Error) {
		a := (^Acc)(data)
		if env.kind != RECORD_REDACT {
			return false, .None
		}
		r := decode_redact(env) or_return
		from := resolve(a.v, s, r.from) or_return
		append(&a.list, Redaction{a.v.segs[from.seg].id, from.off, r.to})
		return false, .None
	}
	walk_events(v, s, floor, &acc, visit) or_return
	return acc.list[:], .None
}

@(private)
_zero :: proc(w: ^Writer, vfs: prim.Vfs, allocator: runtime.Allocator) {
	w^ = {
		vfs       = vfs,
		lock      = prim.INVALID_FD,
		seg       = -1,
		allocator = allocator,
	}
	w.j.fd = prim.INVALID_FD
}

@(private)
_attach :: proc(w: ^Writer, v: ^View, object: prim.Id, kind: Kind, id: prim.Id) -> Error {
	if v.object != object {
		return .Invalid
	}
	w.v = v
	w.object = object
	w.kind = kind
	w.id = id
	journal.journal_reader(&w.j, &w.jr, w.allocator)
	w.ids = make([dynamic]prim.Id, w.allocator)
	append(&w.ids, id)
	w.seg = view_add(v, id, &w.jr) or_return
	v.w = w
	v.segs[w.seg].table_at = -1
	return .None
}

@(private)
_release :: proc(w: ^Writer) {
	if w.v != nil && w.v.w == w {
		w.v.w = nil
		if w.seg >= 0 && w.seg < len(w.v.segs) {
			w.v.segs[w.seg].jr = nil
			w.v.segs[w.seg].tail_end = -1
			w.v.segs[w.seg].table_at = -1
		}
	}
	if w.j.fd >= 0 {
		journal.journal_abort(&w.j)
		journal.journal_close(&w.j)
	}
	if w.jr.win != nil || w.jr.out != nil {
		journal.reader_close(&w.jr)
	}
	delete(w.ids)
	if w.lock >= 0 {
		prim.close_file(w.vfs, w.lock)
	}
	_zero(w, w.vfs, w.allocator)
}

@(private)
_recover :: proc(w: ^Writer) -> (head: Head, err: Error) {
	end_ := journal.journal_len(&w.j)
	if end_ == 0 {
		return head, .Not_Found
	}
	hb, _, he := jrec_at(&w.jr, 0)
	if he != .None {
		return head, jerr(he)
	}
	henv := decode_envelope(hb, 0) or_return
	head = decode_head(&henv) or_return
	if head.object != w.object || head.kind != w.kind || (!prim.id_is_zero(head.seg) && head.seg != w.id) {
		return head, .Invalid
	}
	w.created = head.created
	observe(w, head.created)
	head.settings = clone_bytes(head.settings, context.temp_allocator) or_return
	pos := end_
	for pos > 0 {
		body, off, je := jrec_before(&w.jr, pos)
		if je != .None {
			return head, jerr(je)
		}
		if !is_redacted(body) && !is_sig(body) {
			env := decode_envelope(body, off) or_return
			w.event = env.links.event
			w.segs = env.links.segs
			if env.kind == RECORD_SEG {
				w.segs = off
			}
			break
		}
		pos = off
	}
	if w.segs != 0 {
		sb, _, se := jrec_at(&w.jr, w.segs)
		if se != .None {
			return head, jerr(se)
		}
		senv := decode_envelope(sb, w.segs) or_return
		decode_seg(&senv, &w.ids) or_return
	}
	if w.event != 0 {
		eb, _, ee := jrec_at(&w.jr, w.event)
		if ee == .None && !is_redacted(eb) {
			eenv := decode_envelope(eb, w.event) or_return
			observe(w, eenv.links.stamp)
		}
	}
	w.v.segs[w.seg].table_at = -1
	return head, .None
}
