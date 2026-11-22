package osync

import "base:runtime"
import "core:mem"
import "core:slice"
import "../journal"
import "../prim"

Mem_Effect_Kind :: enum u8 {
	Append,
	Fill,
	Note,
	Redact,
	Drop,
	Put,
	Remove,
}

Mem_Effect :: struct {
	kind:   Mem_Effect_Kind,
	space:  Space_Id,
	id:     [32]u8,
	at:     i64,
	length: i64,
	result: Error,
}

Mem_Store :: struct {
	spaces:    map[Space_Id]^Mem_Space,
	queue:     [dynamic]Mem_Job,
	log:       ^[dynamic]Mem_Effect,
	clock:     prim.Clock,
	allocator: runtime.Allocator,
}

Mem_Space :: struct {
	id:      Space_Id,
	streams: map[Stream_Id]^Mem_Stream,
	objects: map[Object_Key][]u8,
	usage:   i64,
	account: Store_Account,
}

Mem_Stream :: struct {
	space:  ^Mem_Space,
	id:     Stream_Id,
	data:   [dynamic]u8,
	base:   i64,
	length: i64,
	gone:   bool,
}

@(private)
Mem_Writer :: struct {
	space:  ^Mem_Space,
	stream: ^Mem_Stream,
	key:    Object_Key,
	at:     i64,
	total:  i64,
	fill:   bool,
	buf:    [dynamic]u8,
}

@(private)
Mem_Job_Kind :: enum u8 {
	Append,
	Fill,
	Note,
	Redact,
	Drop,
	Put,
	Remove,
}

@(private)
Mem_Job :: struct {
	kind:   Mem_Job_Kind,
	w:      ^Mem_Writer,
	space:  ^Mem_Space,
	stream: ^Mem_Stream,
	id:     Stream_Id,
	key:    Object_Key,
	from:   i64,
	to:     i64,
	done:   Storage_Done,
	ctx:    rawptr,
}

@(private)
Mem_List :: struct {
	ids: []Stream_Id,
	pos: int,
}

@(private)
Mem_Object :: struct {
	bytes: []u8,
}

mem_store_init :: proc(m: ^Mem_Store, clock := prim.Clock{}, allocator := context.allocator) {
	m^ = {
		clock     = clock,
		allocator = allocator,
	}
	m.spaces = make(map[Space_Id]^Mem_Space, allocator)
	m.queue = make([dynamic]Mem_Job, allocator)
}

mem_store_destroy :: proc(m: ^Mem_Store) {
	for _, sp in m.spaces {
		for _, st in sp.streams {
			delete(st.data)
			free(st, m.allocator)
		}
		for _, b in sp.objects {
			delete(b, m.allocator)
		}
		delete(sp.streams)
		delete(sp.objects)
		free(sp, m.allocator)
	}
	delete(m.spaces)
	for j in m.queue {
		if j.w != nil {
			_mem_writer_free(m, j.w)
		}
	}
	delete(m.queue)
	m^ = {}
}

mem_store_pending :: proc "contextless" (m: ^Mem_Store) -> int {
	return len(m.queue)
}

mem_store_settle :: proc(m: ^Mem_Store) -> int {
	n := 0
	for len(m.queue) > 0 {
		j := m.queue[0]
		ordered_remove(&m.queue, 0)
		_mem_run(m, j)
		n += 1
	}
	return n
}

mem_store :: proc(m: ^Mem_Store) -> Relay_Storage {
	return Relay_Storage {
		data = m,
		namespace_open = _mem_ns_open,
		namespace_close = _mem_ns_close,
		stream_open = _mem_stream_open,
		stream_close = _mem_stream_close,
		stream_probe = _mem_stream_probe,
		stream_base = _mem_stream_base,
		stream_read = _mem_stream_read,
		stream_hint = _mem_stream_hint,
		append_begin = _mem_append_begin,
		append_write = _mem_write,
		append_commit = _mem_append_commit,
		append_abort = _mem_abort,
		fill_begin = _mem_fill_begin,
		note = _mem_note,
		drop = _mem_drop,
		redact = _mem_redact,
		list_begin = _mem_list_begin,
		list_next = _mem_list_next,
		list_end = _mem_list_end,
		put_begin = _mem_put_begin,
		put_write = _mem_write,
		put_commit = _mem_put_commit,
		put_abort = _mem_abort,
		object_open = _mem_object_open,
		object_read = _mem_object_read,
		object_close = _mem_object_close,
		object_remove = _mem_object_remove,
		account = _mem_account,
		objects = _mem_objects,
	}
}

mem_store_stream :: proc(m: ^Mem_Store, space: Space_Id, id: Stream_Id) -> (base: i64, length: i64, data: []u8, ok: bool) {
	sp, found := m.spaces[space]
	if !found {
		return
	}
	st, sfound := sp.streams[id]
	if !sfound || st.gone {
		return
	}
	return st.base, st.length, st.data[:], true
}

mem_store_object :: proc(m: ^Mem_Store, space: Space_Id, key: Object_Key) -> (data: []u8, ok: bool) {
	sp, found := m.spaces[space]
	if !found {
		return
	}
	return sp.objects[key]
}

mem_store_streams :: proc(m: ^Mem_Store, space: Space_Id, allocator := context.temp_allocator) -> []Stream_Id {
	sp, found := m.spaces[space]
	if !found {
		return nil
	}
	ids := make([dynamic]Stream_Id, 0, len(sp.streams), allocator)
	for id, st in sp.streams {
		if !st.gone {
			append(&ids, id)
		}
	}
	slice.sort_by(ids[:], _mem_id_less)
	return ids[:]
}

mem_store_object_keys :: proc(m: ^Mem_Store, space: Space_Id, allocator := context.temp_allocator) -> []Object_Key {
	sp, found := m.spaces[space]
	if !found {
		return nil
	}
	keys := make([dynamic]Object_Key, 0, len(sp.objects), allocator)
	for k in sp.objects {
		append(&keys, k)
	}
	slice.sort_by(keys[:], proc(a, b: Object_Key) -> bool {
		x, y := a, b
		return mem.compare(x[:], y[:]) < 0
	})
	return keys[:]
}

@(private)
_mem_id_less :: proc(a, b: Stream_Id) -> bool {
	x, y := a, b
	return mem.compare(x[:], y[:]) < 0
}

@(private)
_mem_space :: proc(m: ^Mem_Store, id: Space_Id) -> ^Mem_Space {
	if sp, ok := m.spaces[id]; ok {
		return sp
	}
	sp := new(Mem_Space, m.allocator)
	sp.id = id
	sp.streams = make(map[Stream_Id]^Mem_Stream, m.allocator)
	sp.objects = make(map[Object_Key][]u8, m.allocator)
	m.spaces[id] = sp
	return sp
}

@(private)
_mem_ns_open :: proc(data: rawptr, id: Space_Id) -> (h: rawptr, usage: i64, err: Error) {
	m := cast(^Mem_Store)data
	sp := _mem_space(m, id)
	return sp, sp.usage, .None
}

@(private)
_mem_ns_close :: proc(data: rawptr, h: rawptr) {
}

@(private)
_mem_stream_open :: proc(data: rawptr, h: rawptr, id: Stream_Id, create: bool) -> (s: rawptr, length: i64, err: Error) {
	m := cast(^Mem_Store)data
	sp := cast(^Mem_Space)h
	if st, ok := sp.streams[id]; ok && !st.gone {
		return st, st.length, .None
	}
	if !create {
		return nil, 0, .Not_Found
	}
	st, ok := sp.streams[id]
	if !ok {
		st = new(Mem_Stream, m.allocator)
		st.data = make([dynamic]u8, m.allocator)
		sp.streams[id] = st
	}
	st^ = {
		space = sp,
		id    = id,
		data  = st.data,
	}
	clear(&st.data)
	return st, 0, .None
}

@(private)
_mem_stream_close :: proc(data: rawptr, s: rawptr) {
}

@(private)
_mem_stream_probe :: proc(data: rawptr, h: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool, err: Error) {
	sp := cast(^Mem_Space)h
	if st, ok := sp.streams[id]; ok && !st.gone {
		return st.length, st.base, true, .None
	}
	return 0, 0, false, .None
}

@(private)
_mem_stream_hint :: proc(data: rawptr, h: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool) {
	l, b, e, _ := _mem_stream_probe(data, h, id)
	return l, b, e
}

@(private)
_mem_stream_base :: proc(data: rawptr, s: rawptr) -> i64 {
	return (cast(^Mem_Stream)s).base
}

@(private)
_mem_stream_read :: proc(data: rawptr, s: rawptr, at: i64, dst: []u8) -> (int, Error) {
	st := cast(^Mem_Stream)s
	if at < st.base || at > st.length {
		return 0, .Invalid
	}
	return copy(dst, st.data[at - st.base:]), .None
}

@(private)
_mem_writer_new :: proc(m: ^Mem_Store, sp: ^Mem_Space, st: ^Mem_Stream, at, total: i64) -> ^Mem_Writer {
	w := new(Mem_Writer, m.allocator)
	w.space = sp
	w.stream = st
	w.at = at
	w.total = total
	w.buf = make([dynamic]u8, 0, int(min(total, 1 << 20)), m.allocator)
	return w
}

@(private)
_mem_writer_free :: proc(m: ^Mem_Store, w: ^Mem_Writer) {
	delete(w.buf)
	free(w, m.allocator)
}

@(private)
_mem_append_begin :: proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error) {
	m := cast(^Mem_Store)data
	st := cast(^Mem_Stream)s
	if at != st.length {
		return nil, .Conflict
	}
	return _mem_writer_new(m, st.space, st, at, total), .None
}

@(private)
_mem_fill_begin :: proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error) {
	m := cast(^Mem_Store)data
	st := cast(^Mem_Stream)s
	if at < 0 || total <= 0 || at + total != st.base {
		return nil, .Conflict
	}
	mw := _mem_writer_new(m, st.space, st, at, total)
	mw.fill = true
	return mw, .None
}

@(private)
_mem_write :: proc(data: rawptr, w: rawptr, bytes: []u8) -> Error {
	mw := cast(^Mem_Writer)w
	if i64(len(mw.buf) + len(bytes)) > mw.total {
		return .Invalid
	}
	if _, e := append(&mw.buf, ..bytes); e != nil {
		return .No_Memory
	}
	return .None
}

@(private)
_mem_abort :: proc(data: rawptr, w: rawptr) {
	_mem_writer_free(cast(^Mem_Store)data, cast(^Mem_Writer)w)
}

@(private)
_mem_append_commit :: proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr) {
	m := cast(^Mem_Store)data
	mw := cast(^Mem_Writer)w
	append(&m.queue, Mem_Job{kind = .Fill if mw.fill else .Append, w = mw, stream = mw.stream, space = mw.space, done = done, ctx = ctx})
}

@(private)
_mem_note :: proc(data: rawptr, s: rawptr, length: i64, done: Storage_Done, ctx: rawptr) {
	m := cast(^Mem_Store)data
	st := cast(^Mem_Stream)s
	append(&m.queue, Mem_Job{kind = .Note, stream = st, space = st.space, to = length, done = done, ctx = ctx})
}

@(private)
_mem_drop :: proc(data: rawptr, h: rawptr, id: Stream_Id, done: Storage_Done, ctx: rawptr) {
	m := cast(^Mem_Store)data
	append(&m.queue, Mem_Job{kind = .Drop, space = cast(^Mem_Space)h, id = id, done = done, ctx = ctx})
}

@(private)
_mem_redact :: proc(data: rawptr, s: rawptr, from, to: i64, done: Storage_Done, ctx: rawptr) {
	m := cast(^Mem_Store)data
	st := cast(^Mem_Stream)s
	append(&m.queue, Mem_Job{kind = .Redact, stream = st, space = st.space, from = from, to = to, done = done, ctx = ctx})
}

@(private)
_mem_put_begin :: proc(data: rawptr, h: rawptr, key: Object_Key, total: i64) -> (w: rawptr, exists: bool, err: Error) {
	m := cast(^Mem_Store)data
	sp := cast(^Mem_Space)h
	if key in sp.objects {
		return nil, true, .None
	}
	mw := _mem_writer_new(m, sp, nil, 0, total)
	mw.key = key
	return mw, false, .None
}

@(private)
_mem_put_commit :: proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr) {
	m := cast(^Mem_Store)data
	mw := cast(^Mem_Writer)w
	append(&m.queue, Mem_Job{kind = .Put, w = mw, space = mw.space, key = mw.key, done = done, ctx = ctx})
}

@(private)
_mem_object_open :: proc(data: rawptr, h: rawptr, key: Object_Key) -> (o: rawptr, size: i64, err: Error) {
	m := cast(^Mem_Store)data
	sp := cast(^Mem_Space)h
	b, ok := sp.objects[key]
	if !ok {
		return nil, 0, .Not_Found
	}
	ob := new(Mem_Object, m.allocator)
	ob.bytes = b
	return ob, i64(len(b)), .None
}

@(private)
_mem_object_read :: proc(data: rawptr, o: rawptr, at: i64, dst: []u8) -> (int, Error) {
	ob := cast(^Mem_Object)o
	if at < 0 || at > i64(len(ob.bytes)) {
		return 0, .Invalid
	}
	return copy(dst, ob.bytes[at:]), .None
}

@(private)
_mem_object_close :: proc(data: rawptr, o: rawptr) {
	m := cast(^Mem_Store)data
	free(cast(^Mem_Object)o, m.allocator)
}

@(private)
_mem_object_remove :: proc(data: rawptr, h: rawptr, key: Object_Key, done: Storage_Done, ctx: rawptr) {
	m := cast(^Mem_Store)data
	append(&m.queue, Mem_Job{kind = .Remove, space = cast(^Mem_Space)h, key = key, done = done, ctx = ctx})
}

@(private)
_mem_list_begin :: proc(data: rawptr, h: rawptr, since: i64) -> (it: rawptr, cursor: i64, err: Error) {
	m := cast(^Mem_Store)data
	sp := cast(^Mem_Space)h
	l := new(Mem_List, m.allocator)
	ids := make([dynamic]Stream_Id, 0, len(sp.streams), m.allocator)
	for id, st in sp.streams {
		if !st.gone {
			append(&ids, id)
		}
	}
	slice.sort_by(ids[:], _mem_id_less)
	l.ids = ids[:]
	return l, 0, .None
}

@(private)
_mem_list_next :: proc(data: rawptr, it: rawptr) -> (id: Stream_Id, ok: bool) {
	l := cast(^Mem_List)it
	if l.pos >= len(l.ids) {
		return {}, false
	}
	l.pos += 1
	return l.ids[l.pos - 1], true
}

@(private)
_mem_list_end :: proc(data: rawptr, it: rawptr) {
	m := cast(^Mem_Store)data
	l := cast(^Mem_List)it
	delete(l.ids, m.allocator)
	free(l, m.allocator)
}

@(private)
_mem_objects :: proc(data: rawptr, ns: rawptr, out: ^[dynamic]Object_Key) -> Error {
	sp := cast(^Mem_Space)ns
	for k in sp.objects {
		append(out, k)
	}
	return .None
}

@(private)
_mem_account :: proc(data: rawptr, ns: rawptr) -> Store_Account {
	sp := cast(^Mem_Space)ns
	return sp.account
}

@(private)
_mem_count :: proc(m: ^Mem_Store, sp: ^Mem_Space, n: i64) {
	if n <= 0 {
		return
	}
	day := prim.clock_wall_ms(m.clock) / 86_400_000
	if sp.account.day != day {
		sp.account.day = day
		sp.account.day_bytes = 0
	}
	sp.account.day_bytes += u64(n)
	sp.account.total_bytes += u64(n)
}

@(private)
_mem_log :: proc(m: ^Mem_Store, e: Mem_Effect) {
	if m.log != nil && !_reserved(e.id) {
		append(m.log, e)
	}
}

@(private)
_mem_run :: proc(m: ^Mem_Store, j: Mem_Job) {
	result := Error.None
	value: i64
	switch j.kind {
	case .Append:
		w := j.w
		st := j.stream
		if st.gone || w.at != st.length {
			result = .Conflict
		} else if i64(len(w.buf)) != w.total {
			result = .Invalid
		} else {
			append(&st.data, ..w.buf[:])
			st.length += w.total
			st.space.usage += w.total
			if !_reserved(cast([32]u8)st.id) {
				_mem_count(m, st.space, w.total)
			}
			value = st.length
		}
		_mem_log(m, {kind = .Append, space = st.space.id, id = cast([32]u8)st.id, at = w.at, length = w.total, result = result})
		_mem_writer_free(m, w)
	case .Fill:
		w := j.w
		st := j.stream
		if st.gone || w.at + w.total != st.base {
			result = .Conflict
		} else if i64(len(w.buf)) != w.total {
			result = .Invalid
		} else {
			inject_at(&st.data, 0, ..w.buf[:])
			st.base = w.at
			st.space.usage += w.total
			_mem_count(m, st.space, w.total)
			value = st.length
		}
		_mem_log(m, {kind = .Fill, space = st.space.id, id = cast([32]u8)st.id, at = w.at, length = w.total, result = result})
		_mem_writer_free(m, w)
	case .Note:
		st := j.stream
		if st.gone || st.base != st.length || j.to < st.length {
			result = .Conflict
		} else {
			st.base = j.to
			st.length = j.to
			value = st.length
		}
		_mem_log(m, {kind = .Note, space = st.space.id, id = cast([32]u8)st.id, at = j.to, result = result})
	case .Redact:
		st := j.stream
		lo := clamp(j.from, st.base, st.length)
		hi := clamp(j.to, lo, st.length)
		if hi > lo {
			result = _mem_redact_records(st, lo, hi)
		}
		_mem_log(m, {kind = .Redact, space = st.space.id, id = cast([32]u8)st.id, at = lo, length = hi - lo, result = result})
	case .Drop:
		sp := j.space
		if st, ok := sp.streams[j.id]; ok && !st.gone {
			value = st.length - st.base
			sp.usage = max(sp.usage - value, 0)
			st.gone = true
			clear(&st.data)
		}
		_mem_log(m, {kind = .Drop, space = sp.id, id = cast([32]u8)j.id, length = value})
	case .Put:
		w := j.w
		sp := j.space
		if i64(len(w.buf)) != w.total {
			result = .Invalid
		} else if j.key not_in sp.objects {
			b := make([]u8, len(w.buf), m.allocator)
			copy(b, w.buf[:])
			sp.objects[j.key] = b
			sp.usage += w.total
			_mem_count(m, sp, w.total)
			value = w.total
		}
		_mem_log(m, {kind = .Put, space = sp.id, id = cast([32]u8)j.key, length = w.total, result = result})
		_mem_writer_free(m, w)
	case .Remove:
		sp := j.space
		if b, ok := sp.objects[j.key]; ok {
			value = i64(len(b))
			sp.usage = max(sp.usage - value, 0)
			delete(b, m.allocator)
			delete_key(&sp.objects, j.key)
		}
		_mem_log(m, {kind = .Remove, space = sp.id, id = cast([32]u8)j.key, length = value})
	}
	j.done(j.ctx, result, value)
}

@(private)
_mem_redact_records :: proc(st: ^Mem_Stream, from, to: i64) -> Error {
	pos := from
	for pos < to {
		rel := pos - st.base
		if rel + journal.HEADER > i64(len(st.data)) {
			return .Corrupt
		}
		body := i64(prim.get_u32le(st.data[rel:]))
		size := body + journal.OVERHEAD
		if body > journal.MAX_BODY || pos + size > to {
			return .Invalid
		}
		if prim.get_u32le(st.data[rel + journal.HEADER + body:]) != u32(body) {
			return .Invalid
		}
		pos += size
	}
	pos = from
	for pos < to {
		rel := pos - st.base
		body := i64(prim.get_u32le(st.data[rel:]))
		tag := journal.redacted_tag(pos, int(body))
		copy(st.data[rel + 4:][:16], tag[:])
		mem.zero_slice(st.data[rel + journal.HEADER:][:body])
		pos += body + journal.OVERHEAD
	}
	return .None
}
