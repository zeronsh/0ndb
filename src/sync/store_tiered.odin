#+build linux, darwin, windows
package osync

import "base:runtime"
import "core:fmt"
import "core:slice"
import "../prim"

Object_Store :: struct {
	data: rawptr,
	put:    proc(data: rawptr, key: string, bytes: []u8, done: Storage_Done, ctx: rawptr),
	read:   proc(data: rawptr, req: ^Object_Read),
	cancel: proc(data: rawptr, req: ^Object_Read),
}

Tier_Config :: struct {
	objects:   Object_Store,
	window_ms: i64,
	max_ms:    i64,
	max_bytes: i64,
	hot:       i64,
}

TIER_MANIFEST_TAG :: 16
TIER_RECORD :: 64
TIER_MAGIC :: "0ndbbat1"
TIER_WINDOW_DEFAULT :: 30_000
TIER_MAX_DEFAULT :: 600_000
TIER_BYTES_DEFAULT :: 8 << 20

Tier_Kind :: enum u8 {
	None   = 0,
	Seg    = 1,
	Note   = 2,
	Drop   = 3,
	Put    = 4,
	Forget = 5,
	Redact = 6,
	Trim   = 7,
	Evict  = 8,
	Redacting = 9,
	Redacted = 10,
	Dirty  = 0x10,
	Clean  = 0x11,
	Flushed = 0x12,
}

Tier_Store :: struct {
	inner:     Relay_Storage,
	cfg:       Tier_Config,
	loop:      ^prim.Loop,
	clock:     prim.Clock,
	timer:     prim.Timer,
	spaces:    map[Space_Id]^Tier_Space,
	cold_reads: u64,
	cold_bytes: u64,
	blocks:     map[Tier_Block_Key]^Tier_Fetch,
	cache:      i64,
	tick:       u64,
	inflight:   int,
	gets:       u64,
	get_bytes:  u64,
	ready_cb:   proc(ctx: rawptr),
	ready_ctx:  rawptr,
	rewrites:   map[string]^Tier_Rewrite,
	evictions:  u64,
	thaws:      u64,
	parked:     [dynamic]^Tier_Thaw,
	park_timer: prim.Timer,
	park_ms:    i64,
	parks:      u64,
	allocator: runtime.Allocator,
}

@(private)
Tier_Seg :: struct {
	lo, hi:  i64,
	note:    i64,
	trim:    i64,
	dropped: bool,
	redacts: [dynamic][2]i64,
}

@(private)
Tier_Mark :: enum u8 {
	Clean,
	Pending,
	Marked,
}

@(private)
Tier_Space :: struct {
	t:         ^Tier_Store,
	id:        Space_Id,
	ns:        rawptr,
	refs:      int,
	holds:     int,
	pin:       [16]u8,
	usage:     i64,
	man:       rawptr,
	man_len:   i64,
	man_busy:  bool,
	man_dirty: bool,
	man_q:     [dynamic]u8,
	man_wait:  [dynamic]Tier_Hold,
	mark:      Tier_Mark,
	open:      map[Stream_Id]rawptr,
	segs:      map[Stream_Id]Tier_Seg,
	objs:      map[Object_Key]bool,
	bytes:     i64,
	since:     i64,
	last:      i64,
	seq:       u64,
	dirty:     bool,
	flushing:  bool,
	account:   Store_Account,
	cold:      map[Stream_Id]^Tier_Cold,
	ev_q:      [dynamic]Tier_Ev,
	ev_fly:    [dynamic]Tier_Ev,
	evicting:  int,
	thawing:   map[Stream_Id]int,
	redacting: map[Stream_Id]int,
	rewriting: map[Stream_Id]int,
}

@(private)
Tier_Hold :: struct {
	done:   Storage_Done,
	ctx:    rawptr,
	result: Error,
	value:  i64,
}

@(private)
Tier_Stream :: struct {
	sp:   ^Tier_Space,
	id:   Stream_Id,
	h:    rawptr,
	cold: ^Tier_Cold,
}

@(private)
Tier_Writer :: struct {
	sp:    ^Tier_Space,
	id:    [32]u8,
	w:     rawptr,
	at:    i64,
	total: i64,
	kind:  Tier_Kind,
	fill:  bool,
}

@(private)
Tier_Job :: struct {
	sp:    ^Tier_Space,
	kind:  Tier_Kind,
	id:    [32]u8,
	at:    i64,
	n:     i64,
	done:  Storage_Done,
	ctx:   rawptr,
	gate:  bool,
}

tier_store_init :: proc(t: ^Tier_Store, l: ^prim.Loop, inner: Relay_Storage, cfg: Tier_Config, clock := prim.Clock{}, allocator := context.allocator) -> Error {
	if cfg.objects.put == nil || inner.objects == nil {
		return .Invalid
	}
	t^ = {
		inner     = inner,
		cfg       = cfg,
		loop      = l,
		clock     = clock,
		allocator = allocator,
	}
	if t.cfg.window_ms <= 0 {
		t.cfg.window_ms = TIER_WINDOW_DEFAULT
	}
	if t.cfg.max_ms <= 0 {
		t.cfg.max_ms = max(TIER_MAX_DEFAULT, t.cfg.window_ms)
	}
	if t.cfg.max_bytes <= 0 {
		t.cfg.max_bytes = TIER_BYTES_DEFAULT
	}
	t.spaces = make(map[Space_Id]^Tier_Space, allocator)
	t.blocks = make(map[Tier_Block_Key]^Tier_Fetch, allocator)
	t.rewrites = make(map[string]^Tier_Rewrite, allocator)
	t.parked = make([dynamic]^Tier_Thaw, allocator)
	return .None
}

tier_store_destroy :: proc(t: ^Tier_Store) {
	if t.timer != 0 {
		prim.timer_cancel(t.loop, t.timer)
	}
	if t.park_timer != 0 {
		prim.timer_cancel(t.loop, t.park_timer)
	}
	for th in t.parked {
		free(th.job, t.allocator)
		free(th, t.allocator)
	}
	delete(t.parked)
	for _, sp in t.spaces {
		_tier_space_free(t, sp)
	}
	delete(t.spaces)
	_tier_cache_drop(t)
	delete(t.blocks)
	delete(t.rewrites)
	t^ = {}
}

tier_store_sweep :: proc(t: ^Tier_Store, ids: []Space_Id) -> (dirty: int) {
	for id in ids {
		h, _, err := _tier_ns_open(t, id)
		if err != .None {
			continue
		}
		sp := cast(^Tier_Space)h
		if sp.dirty {
			dirty += 1
		}
		_tier_ns_close(t, h)
	}
	return
}

tier_store_flush_all :: proc(t: ^Tier_Store) {
	for _, sp in t.spaces {
		if sp.dirty && !sp.flushing {
			_tier_flush(sp)
		}
	}
}

tier_store :: proc(t: ^Tier_Store) -> Relay_Storage {
	return Relay_Storage {
		data = t,
		namespace_open = _tier_ns_open,
		namespace_close = _tier_ns_close,
		stream_open = _tier_stream_open,
		stream_close = _tier_stream_close,
		stream_probe = _tier_stream_probe,
		stream_base = _tier_stream_base,
		stream_read = _tier_stream_read,
		stream_extent = _tier_stream_extent,
		stream_hint = _tier_stream_hint,
		append_begin = _tier_append_begin,
		append_write = _tier_append_write,
		append_commit = _tier_append_commit,
		append_abort = _tier_append_abort,
		fill_begin = _tier_fill_begin,
		note = _tier_note,
		trim = _tier_trim,
		stream_trimmed = _tier_stream_trimmed,
		drop = _tier_drop,
		redact = _tier_redact,
		list_begin = _tier_list_begin,
		list_next = _tier_list_next,
		list_end = _tier_list_end,
		put_begin = _tier_put_begin,
		put_write = _tier_put_write,
		put_commit = _tier_put_commit,
		put_abort = _tier_put_abort,
		object_open = _tier_object_open,
		object_read = _tier_object_read,
		object_extent = _tier_object_extent,
		object_close = _tier_object_close,
		object_remove = _tier_object_remove,
		account = _tier_account,
		objects = _tier_objects,
		atomic = t.inner.atomic,
		on_ready = _tier_on_ready,
	}
}

@(private)
_tier_on_ready :: proc(data: rawptr, cb: proc(ctx: rawptr), ctx: rawptr) {
	t := cast(^Tier_Store)data
	t.ready_cb = cb
	t.ready_ctx = ctx
}

@(private)
_tier_reserved :: proc "contextless" (id: [32]u8) -> bool {
	return _reserved(id) && id[16] == TIER_MANIFEST_TAG
}

@(private)
_tier_ns_open :: proc(data: rawptr, id: Space_Id) -> (h: rawptr, usage: i64, err: Error) {
	t := cast(^Tier_Store)data
	if sp, ok := t.spaces[id]; ok {
		sp.refs += 1
		return sp, max(sp.usage - sp.man_len, 0), .None
	}
	ns, u := t.inner.namespace_open(t.inner.data, id) or_return
	sp := new(Tier_Space, t.allocator)
	sp^ = {t = t, id = id, ns = ns, refs = 1, usage = u}
	sp.pin = stream_id_suffix(members_stream(id, Device_Id{}))
	sp.segs = make(map[Stream_Id]Tier_Seg, t.allocator)
	sp.objs = make(map[Object_Key]bool, t.allocator)
	sp.open = make(map[Stream_Id]rawptr, t.allocator)
	sp.man_q = make([dynamic]u8, t.allocator)
	sp.man_wait = make([dynamic]Tier_Hold, t.allocator)
	sp.cold = make(map[Stream_Id]^Tier_Cold, t.allocator)
	sp.ev_q = make([dynamic]Tier_Ev, t.allocator)
	sp.ev_fly = make([dynamic]Tier_Ev, t.allocator)
	sp.thawing = make(map[Stream_Id]int, t.allocator)
	sp.redacting = make(map[Stream_Id]int, t.allocator)
	sp.rewriting = make(map[Stream_Id]int, t.allocator)
	t.spaces[id] = sp
	if lerr := _tier_load(sp); lerr != .None {
		delete_key(&t.spaces, id)
		_tier_space_free(t, sp)
		return nil, 0, lerr
	}
	return sp, max(sp.usage - sp.man_len, 0), .None
}

@(private)
_tier_ns_close :: proc(data: rawptr, h: rawptr) {
	sp := cast(^Tier_Space)h
	sp.refs -= 1
	_tier_maybe_release(sp)
}

@(private)
_tier_hold :: proc(sp: ^Tier_Space) {
	sp.refs += 1
	sp.holds += 1
}

@(private)
_tier_unhold :: proc(sp: ^Tier_Space) {
	sp.holds -= 1
	sp.refs -= 1
	_tier_maybe_release(sp)
}

@(private)
_tier_maybe_release :: proc(sp: ^Tier_Space) {
	t := sp.t
	if sp.refs > 0 || sp.dirty || sp.flushing || sp.man_busy || len(sp.man_q) > 0 || len(sp.man_wait) > 0 || len(sp.open) > 0 || sp.evicting > 0 || len(sp.ev_q) > 0 || len(sp.ev_fly) > 0 {
		return
	}
	delete_key(&t.spaces, sp.id)
	_tier_space_free(t, sp)
}

@(private)
_tier_space_free :: proc(t: ^Tier_Store, sp: ^Tier_Space) {
	assert(sp.holds == 0, "a tier space was freed while a completion callback held it")
	for _, &g in sp.segs {
		delete(g.redacts)
	}
	delete(sp.segs)
	delete(sp.objs)
	delete(sp.open)
	delete(sp.man_q)
	delete(sp.man_wait)
	for _, c in sp.cold {
		delete(c.recs)
		free(c, t.allocator)
	}
	delete(sp.cold)
	delete(sp.ev_q)
	delete(sp.ev_fly)
	delete(sp.thawing)
	delete(sp.redacting)
	delete(sp.rewriting)
	if sp.man != nil {
		t.inner.stream_close(t.inner.data, sp.man)
	}
	if sp.ns != nil {
		t.inner.namespace_close(t.inner.data, sp.ns)
	}
	free(sp, t.allocator)
}

@(private)
_tier_read :: proc(sp: ^Tier_Space, id: Stream_Id, lo, hi: i64, allocator := context.temp_allocator) -> (data: []u8, at: i64, ok: bool) {
	t := sp.t
	h, opened := sp.open[id]
	if !opened {
		nh, _, err := t.inner.stream_open(t.inner.data, sp.ns, id, false)
		if err != .None {
			return nil, 0, false
		}
		h = nh
	}
	defer if !opened {
		t.inner.stream_close(t.inner.data, h)
	}
	length, base, _, perr := t.inner.stream_probe(t.inner.data, sp.ns, id)
	if perr != .None {
		return nil, 0, false
	}
	a, b := max(lo, base), min(hi, length)
	if b <= a {
		return nil, a, true
	}
	buf := make([]u8, int(b - a), allocator)
	got, rerr := t.inner.stream_read(t.inner.data, h, a, buf)
	if rerr != .None || got != len(buf) {
		return nil, 0, false
	}
	return buf, a, true
}

@(private)
_tier_load :: proc(sp: ^Tier_Space) -> Error {
	t := sp.t
	h, length, err := t.inner.stream_open(t.inner.data, sp.ns, reserved_id(TIER_MANIFEST_TAG, 0), true)
	if err != .None {
		return err
	}
	sp.man = h
	sp.man_len = length
	if length < TIER_RECORD {
		return .None
	}
	last: [TIER_RECORD]u8
	if got, lerr := t.inner.stream_read(t.inner.data, h, length - TIER_RECORD, last[:]); lerr != .None || got != TIER_RECORD {
		return .Corrupt
	}
	if Tier_Kind(last[0]) == .Clean {
		sp.seq = prim.get_u64le(last[8:])
		sp.account.writes = prim.get_u64le(last[16:])
		sp.account.write_bytes = prim.get_u64le(last[24:])
		sp.account.day = i64(prim.get_u64le(last[32:]))
		sp.account.day_bytes = prim.get_u64le(last[40:])
		sp.account.total_bytes = prim.get_u64le(last[48:])
		return .None
	}
	raw := make([]u8, int(length), context.temp_allocator)
	got, rerr := t.inner.stream_read(t.inner.data, h, 0, raw)
	if rerr != .None || i64(got) != length {
		return .Corrupt
	}
	dirty := false
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		#partial switch Tier_Kind(r[0]) {
		case .Dirty:
			dirty = true
		case .Clean, .Flushed:
			dirty = dirty && Tier_Kind(r[0]) == .Flushed
			sp.seq = prim.get_u64le(r[8:])
			sp.account.writes = prim.get_u64le(r[16:])
			sp.account.write_bytes = prim.get_u64le(r[24:])
			sp.account.day = i64(prim.get_u64le(r[32:]))
			sp.account.day_bytes = prim.get_u64le(r[40:])
			sp.account.total_bytes = prim.get_u64le(r[48:])
		}
	}
	if dirty {
		sp.mark = .Marked
		_tier_rescan(sp, raw)
	}
	return .None
}

@(private)
Tier_Red_Key :: struct {
	id: Stream_Id,
	at: i64,
	n:  i64,
}

@(private)
_tier_rescan :: proc(sp: ^Tier_Space, manifest: []u8) {
	t := sp.t
	covered := make(map[Stream_Id][2]i64, context.temp_allocator)
	gone := make(map[Stream_Id]bool, context.temp_allocator)
	objs := make(map[Object_Key]bool, context.temp_allocator)
	pend := make(map[Tier_Red_Key]int, context.temp_allocator)
	for i := 0; i + TIER_RECORD <= len(manifest); i += TIER_RECORD {
		r := manifest[i:][:TIER_RECORD]
		id: Stream_Id
		copy(id[:], r[8:40])
		at := i64(prim.get_u64le(r[40:]))
		n := i64(prim.get_u64le(r[48:]))
		#partial switch Tier_Kind(r[0]) {
		case .Seg:
			c, ok := covered[id]
			if !ok || gone[id] {
				c = {at, at + n}
			} else {
				c = {min(c[0], at), max(c[1], at + n)}
			}
			covered[id] = c
			gone[id] = false
		case .Note:
			c := covered[id]
			c = {max(c[0], at), max(c[1], at)}
			covered[id] = c
			gone[id] = false
		case .Trim:
			c := covered[id]
			c = {max(c[0], at), max(c[1], at)}
			covered[id] = c
		case .Drop:
			gone[id] = true
		case .Put:
			objs[cast(Object_Key)id] = true
		case .Forget:
			objs[cast(Object_Key)id] = false
		case .Redacting:
			pend[Tier_Red_Key{id, at, n}] += 1
		case .Redacted:
			if k := (Tier_Red_Key{id, at, n}); pend[k] > 0 {
				pend[k] -= 1
			}
		}
	}
	for k, c in pend {
		for _ in 0 ..< c {
			s := sp.segs[k.id]
			if s.redacts == nil {
				s.redacts = make([dynamic][2]i64, t.allocator)
			}
			append(&s.redacts, [2]i64{k.at, k.at + k.n})
			sp.segs[k.id] = s
			sp.redacting[k.id] += 1
			_tier_dirty(sp, 0)
		}
	}
	it, _, lerr := t.inner.list_begin(t.inner.data, sp.ns, 0)
	if lerr == .None {
		seen := make(map[Stream_Id]bool, context.temp_allocator)
		for {
			id, ok := t.inner.list_next(t.inner.data, it)
			if !ok {
				break
			}
			if _tier_reserved(cast([32]u8)id) {
				continue
			}
			seen[id] = true
			length, base, _, perr := t.inner.stream_probe(t.inner.data, sp.ns, id)
			if perr != .None {
				continue
			}
			c, had := covered[id]
			if !had || gone[id] {
				c = {length, length}
			}
			if base < c[0] || length > c[1] {
				_tier_seg(sp, id, min(base, c[0]) if base < c[0] else c[1], length)
			}
			if base == length && length > 0 {
				s := sp.segs[id]
				s.note = length
				sp.segs[id] = s
				_tier_dirty(sp, 0)
			}
		}
		t.inner.list_end(t.inner.data, it)
		for id, g in gone {
			if !g && !seen[id] {
				s := sp.segs[id]
				s.dropped = true
				sp.segs[id] = s
				_tier_dirty(sp, 0)
			}
		}
	}
	keys := make([dynamic]Object_Key, context.temp_allocator)
	if t.inner.objects(t.inner.data, sp.ns, &keys) == .None {
		for k in keys {
			if !objs[k] {
				sp.objs[k] = true
				_tier_dirty(sp, 0)
			}
		}
	}
	if !sp.dirty {
		sp.mark = .Clean
		_tier_mark(sp, .Clean)
	}
}

@(private)
_tier_seg :: proc(sp: ^Tier_Space, id: Stream_Id, lo, hi: i64) {
	if hi <= lo {
		return
	}
	s, ok := sp.segs[id]
	if !ok || s.hi <= s.lo {
		s.lo, s.hi = lo, hi
	} else {
		s.lo, s.hi = min(s.lo, lo), max(s.hi, hi)
	}
	s.dropped = false
	sp.segs[id] = s
	_tier_dirty(sp, hi - lo)
}

@(private)
_tier_dirty :: proc(sp: ^Tier_Space, n: i64) {
	t := sp.t
	sp.last = prim.clock_mono_ns(t.clock)
	if !sp.dirty {
		sp.dirty = true
		sp.since = sp.last
		_tier_arm(t)
	}
	sp.bytes += n
	sp.account.pending = sp.bytes
	if sp.bytes >= t.cfg.max_bytes && !sp.flushing {
		_tier_flush(sp)
	}
}

@(private)
_tier_arm :: proc(t: ^Tier_Store) {
	if t.loop == nil {
		return
	}
	due := max(i64)
	for _, sp in t.spaces {
		if sp.dirty && !sp.flushing {
			due = min(due, _tier_due(t, sp))
		}
	}
	if t.timer != 0 {
		prim.timer_cancel(t.loop, t.timer)
		t.timer = 0
	}
	if due == max(i64) {
		return
	}
	wait := max((due - prim.clock_mono_ns(t.clock) + 999_999) / 1_000_000, 0)
	t.timer = prim.timer(t.loop, wait, t, _tier_on_timer)
}

@(private)
_tier_due :: proc "contextless" (t: ^Tier_Store, sp: ^Tier_Space) -> i64 {
	return min(sp.last + t.cfg.window_ms * 1_000_000, sp.since + t.cfg.max_ms * 1_000_000)
}

@(private)
_tier_on_timer :: proc(l: ^prim.Loop, data: rawptr) {
	t := cast(^Tier_Store)data
	t.timer = 0
	now := prim.clock_mono_ns(t.clock)
	list := make([dynamic]^Tier_Space, context.temp_allocator)
	for _, sp in t.spaces {
		if sp.dirty && !sp.flushing && now >= _tier_due(t, sp) {
			append(&list, sp)
		}
	}
	for sp in list {
		_tier_flush(sp)
	}
	_tier_arm(t)
}

@(private)
_tier_mark :: proc(sp: ^Tier_Space, kind: Tier_Kind) {
	r: [TIER_RECORD]u8
	r[0] = u8(kind)
	prim.put_u64le(r[8:], sp.seq)
	prim.put_u64le(r[16:], sp.account.writes)
	prim.put_u64le(r[24:], sp.account.write_bytes)
	prim.put_u64le(r[32:], u64(max(sp.account.day, 0)))
	prim.put_u64le(r[40:], sp.account.day_bytes)
	prim.put_u64le(r[48:], sp.account.total_bytes)
	append(&sp.man_q, ..r[:])
	_tier_man_flush(sp)
}

@(private)
_tier_man_flush :: proc(sp: ^Tier_Space) {
	t := sp.t
	if sp.man_busy || len(sp.man_q) == 0 {
		return
	}
	n := i64(len(sp.man_q))
	w, err := t.inner.append_begin(t.inner.data, sp.man, sp.man_len, n)
	if err == .None {
		err = t.inner.append_write(t.inner.data, w, sp.man_q[:])
		if err != .None {
			t.inner.append_abort(t.inner.data, w)
		}
	}
	if err != .None {
		clear(&sp.man_q)
		if sp.mark == .Pending {
			sp.mark = .Clean
		}
		append(&sp.ev_fly, ..sp.ev_q[:])
		clear(&sp.ev_q)
		_tier_ev_done(sp, err)
		_tier_release_held(sp, err)
		return
	}
	carries := sp.mark == .Pending
	for i := 0; i + TIER_RECORD <= len(sp.man_q); i += TIER_RECORD {
		carries ||= Tier_Kind(sp.man_q[i]) == .Dirty
	}
	sp.man_dirty = carries
	clear(&sp.man_q)
	append(&sp.ev_fly, ..sp.ev_q[:])
	clear(&sp.ev_q)
	sp.man_busy = true
	t.inner.append_commit(t.inner.data, w, _tier_man_done, sp)
}

@(private)
_tier_man_done :: proc(ctx: rawptr, result: Error, value: i64) {
	sp := cast(^Tier_Space)ctx
	_tier_hold(sp)
	defer _tier_unhold(sp)
	sp.man_busy = false
	if result == .None {
		sp.usage += value - sp.man_len
		sp.man_len = value
	}
	_tier_ev_done(sp, result)
	if sp.man_dirty {
		sp.man_dirty = false
		if result == .None {
			sp.mark = .Marked
		} else {
			sp.mark = .Clean
		}
		_tier_release_held(sp, result)
	}
	_tier_man_flush(sp)
}

@(private)
_tier_release_held :: proc(sp: ^Tier_Space, result: Error) {
	assert(sp.holds > 0 || sp.refs > 0, "tier waiters released without the space held")
	if len(sp.man_wait) == 0 {
		return
	}
	held := make([]Tier_Hold, len(sp.man_wait), context.temp_allocator)
	copy(held, sp.man_wait[:])
	clear(&sp.man_wait)
	for h in held {
		r := h.result if result == .None else Error.Io
		h.done(h.ctx, r, h.value)
	}
}

@(private)
_tier_job :: proc(sp: ^Tier_Space, kind: Tier_Kind, id: [32]u8, at, n: i64, done: Storage_Done, ctx: rawptr) -> ^Tier_Job {
	j := new(Tier_Job, sp.t.allocator)
	j^ = {sp = sp, kind = kind, id = id, at = at, n = n, done = done, ctx = ctx}
	if sp.mark != .Marked {
		j.gate = true
		if sp.mark == .Clean {
			sp.mark = .Pending
			_tier_mark(sp, .Dirty)
		}
	}
	return j
}

@(private)
_tier_job_done :: proc(ctx: rawptr, result: Error, value: i64) {
	j := cast(^Tier_Job)ctx
	sp := j.sp
	t := sp.t
	_tier_hold(sp)
	defer _tier_unhold(sp)
	if result != .None && j.kind == .Redact {
		_tier_unredact(sp, cast(Stream_Id)j.id, 1)
	}
	if result == .None {
		id := cast(Stream_Id)j.id
		switch j.kind {
		case .Seg:
			sp.usage += j.n
			if !_reserved(j.id) {
				_tier_count(sp, j.n)
			}
			_tier_seg(sp, id, j.at, j.at + j.n)
		case .Note:
			g := sp.segs[id]
			g.note = value
			g.dropped = false
			sp.segs[id] = g
			_tier_dirty(sp, 0)
		case .Trim:
			sp.usage -= value
			g := sp.segs[id]
			g.trim = j.at
			sp.segs[id] = g
			_tier_dirty(sp, 0)
		case .Drop:
			sp.usage -= value
			_tier_cold_drop(sp, id)
			g := sp.segs[id]
			delete(g.redacts)
			sp.segs[id] = Tier_Seg{dropped = true}
			_tier_dirty(sp, 0)
		case .Redact:
			g := sp.segs[id]
			if g.redacts == nil {
				g.redacts = make([dynamic][2]i64, t.allocator)
			}
			append(&g.redacts, [2]i64{j.at, j.at + j.n})
			sp.segs[id] = g
			_tier_dirty(sp, 0)
		case .Put:
			sp.usage += value
			_tier_count(sp, value)
			sp.objs[cast(Object_Key)j.id] = true
			_tier_dirty(sp, value)
		case .Forget:
			sp.usage -= value
			sp.objs[cast(Object_Key)j.id] = false
			_tier_dirty(sp, 0)
		case .None, .Dirty, .Clean, .Flushed, .Evict, .Redacting, .Redacted:
		}
	}
	done, cctx, gate := j.done, j.ctx, j.gate
	if j.kind == .Redact && result == .None {
		r: [TIER_RECORD]u8
		r[0] = u8(Tier_Kind.Redacting)
		copy(r[8:40], j.id[:])
		prim.put_u64le(r[40:], u64(j.at))
		prim.put_u64le(r[48:], u64(j.n))
		prim.put_u64le(r[56:], sp.seq)
		append(&sp.man_q, ..r[:])
		append(&sp.ev_q, Tier_Ev{id = cast(Stream_Id)j.id, hold = Tier_Hold{done = done, ctx = cctx, result = result, value = value}})
		free(j, t.allocator)
		_tier_man_flush(sp)
		return
	}
	free(j, t.allocator)
	if gate && sp.mark != .Marked {
		append(&sp.man_wait, Tier_Hold{done = done, ctx = cctx, result = result, value = value})
		return
	}
	done(cctx, result, value)
}

@(private)
_tier_count :: proc(sp: ^Tier_Space, n: i64) {
	if n <= 0 {
		return
	}
	day := prim.clock_wall_ms(sp.t.clock) / 86_400_000
	if sp.account.day != day {
		sp.account.day = day
		sp.account.day_bytes = 0
	}
	sp.account.day_bytes += u64(n)
	sp.account.total_bytes += u64(n)
}

@(private)
Tier_Flight :: struct {
	sp:      ^Tier_Space,
	seq:     u64,
	n:       i64,
	pending: i64,
	segs:    map[Stream_Id]Tier_Seg,
	objs:    map[Object_Key]bool,
	entries: [dynamic]u8,
	rewrites: int,
}

@(private)
_tier_flush :: proc(sp: ^Tier_Space) {
	t := sp.t
	if sp.flushing || !sp.dirty {
		return
	}
	sp.flushing = true
	f := new(Tier_Flight, t.allocator)
	f.sp = sp
	f.seq = sp.seq + 1
	f.segs = sp.segs
	f.objs = sp.objs
	f.pending = sp.bytes
	sp.segs = make(map[Stream_Id]Tier_Seg, t.allocator)
	sp.objs = make(map[Object_Key]bool, t.allocator)
	sp.bytes = 0
	sp.dirty = false
	f.entries = make([dynamic]u8, t.allocator)
	body := make([dynamic]u8, t.allocator)
	w := prim.writer(&body)
	prim.write_raw(&w, transmute([]u8)string(TIER_MAGIC))
	s := sp.id
	prim.write_raw(&w, s[:])
	prim.write_u64le(&w, f.seq)
	count_at := len(body)
	prim.write_u32le(&w, 0)
	count := 0
	ids := make([dynamic]Stream_Id, 0, len(f.segs), context.temp_allocator)
	for id in f.segs {
		append(&ids, id)
	}
	slice.sort_by(ids[:], _mem_id_less)
	redacts := make([dynamic]struct {
		id:    Stream_Id,
		range: [2]i64,
	}, context.temp_allocator)
	for id in ids {
		g := f.segs[id]
		v := cast([32]u8)id
		if g.dropped {
			_tier_put_entry(&w, .Drop, v, 0, nil)
			_tier_entry_f(f, .Drop, v, 0, 0, 0)
			count += 1
			continue
		}
		if g.hi > g.lo {
			if buf, lo, ok := _tier_read(sp, id, g.lo, g.hi); ok && len(buf) > 0 {
				off := len(body) + 1 + 32 + 16
				_tier_put_entry(&w, .Seg, v, lo, buf)
				_tier_entry_f(f, .Seg, v, lo, i64(len(buf)), u32(off))
				count += 1
			}
		}
		if g.note > 0 {
			_tier_put_entry(&w, .Note, v, g.note, nil)
			_tier_entry_f(f, .Note, v, g.note, 0, 0)
			count += 1
		}
		if g.trim > 0 {
			_tier_put_entry(&w, .Trim, v, g.trim, nil)
			_tier_entry_f(f, .Trim, v, g.trim, 0, 0)
			count += 1
		}
		for r in g.redacts {
			_tier_put_entry(&w, .Redact, v, r[0], nil, r[1] - r[0])
			_tier_entry_f(f, .Redact, v, r[0], r[1] - r[0], 0)
			append(&redacts, struct {
				id:    Stream_Id,
				range: [2]i64,
			}{id, r})
			count += 1
		}
	}
	keys := make([dynamic]Object_Key, 0, len(f.objs), context.temp_allocator)
	for k in f.objs {
		append(&keys, k)
	}
	slice.sort_by(keys[:], proc(a, b: Object_Key) -> bool {
		x, y := a, b
		return string(x[:]) < string(y[:])
	})
	for k in keys {
		v := cast([32]u8)k
		if !f.objs[k] {
			_tier_put_entry(&w, .Forget, v, 0, nil)
			_tier_entry_f(f, .Forget, v, 0, 0, 0)
			count += 1
			continue
		}
		o, size, oerr := t.inner.object_open(t.inner.data, sp.ns, k)
		if oerr != .None {
			continue
		}
		buf := make([]u8, int(size), context.temp_allocator)
		got, rerr := t.inner.object_read(t.inner.data, o, 0, buf)
		t.inner.object_close(t.inner.data, o)
		if rerr == .None && got == len(buf) {
			off := len(body) + 1 + 32 + 16
			_tier_put_entry(&w, .Put, v, 0, buf)
			_tier_entry_f(f, .Put, v, 0, size, u32(off))
			count += 1
		}
	}
	prim.put_u32le(body[count_at:], u32(count))
	for r in redacts {
		f.rewrites += _tier_rewrite(sp, r.id, r.range)
	}
	f.n = i64(len(body))
	key := _tier_key(sp.id, f.seq)
	t.cfg.objects.put(t.cfg.objects.data, key, body[:], _tier_put_done, f)
	delete(body)
}

@(private)
_tier_key :: proc(space: Space_Id, seq: u64) -> string {
	h := prim.id_hex(space)
	return fmt.tprintf("%s/%016x", string(h[:]), seq)
}

@(private)
_tier_put_entry :: proc(w: ^prim.Writer, kind: Tier_Kind, id: [32]u8, at: i64, bytes: []u8, n: i64 = -1) {
	prim.write_u8(w, u8(kind))
	v := id
	prim.write_raw(w, v[:])
	prim.write_u64le(w, u64(at))
	prim.write_u64le(w, u64(n if n >= 0 else i64(len(bytes))))
	prim.write_raw(w, bytes)
}

@(private)
_tier_entry_f :: proc(f: ^Tier_Flight, kind: Tier_Kind, id: [32]u8, at, n: i64, off: u32) {
	r: [TIER_RECORD]u8
	r[0] = u8(kind)
	prim.put_u32le(r[4:], off)
	v := id
	copy(r[8:40], v[:])
	prim.put_u64le(r[40:], u64(at))
	prim.put_u64le(r[48:], u64(n))
	prim.put_u64le(r[56:], f.seq)
	append(&f.entries, ..r[:])
}

TIER_REWRITE_TRIES :: 8

@(private)
Tier_Red_Done :: struct {
	sp:     ^Tier_Space,
	id:     Stream_Id,
	at:     i64,
	n:      i64,
	left:   int,
	failed: bool,
}

@(private)
Tier_Patch :: struct {
	rd:   ^Tier_Red_Done,
	id:   Stream_Id,
	off:  i64,
	data: []u8,
}

@(private)
Tier_Rewrite :: struct {
	alloc:   runtime.Allocator,
	t:       ^Tier_Store,
	sp:      ^Tier_Space,
	key:     string,
	seq:     u64,
	req:     Object_Read,
	busy:    bool,
	tries:   int,
	patches: [dynamic]Tier_Patch,
	next:    [dynamic]Tier_Patch,
}

@(private)
_tier_rewrite :: proc(sp: ^Tier_Space, id: Stream_Id, rng: [2]i64) -> int {
	t := sp.t
	if sp.man_len == 0 || t.cfg.objects.read == nil {
		return 0
	}
	raw, ok := _tier_manifest(sp)
	if !ok {
		return 0
	}
	rd := new(Tier_Red_Done, t.allocator)
	rd^ = {sp = sp, id = id, at = rng[0], n = rng[1] - rng[0], left = 1}
	sp.evicting += 1
	n := 0
	want := id
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		if Tier_Kind(r[0]) != .Seg || string(r[8:40]) != string(want[:]) {
			continue
		}
		at := i64(prim.get_u64le(r[40:]))
		ln := i64(prim.get_u64le(r[48:]))
		lo, hi := max(at, rng[0]), min(at + ln, rng[1])
		if hi <= lo {
			continue
		}
		fresh, fat, fok := _tier_read(sp, id, lo, hi, t.allocator)
		if !fok || fat != lo || i64(len(fresh)) != hi - lo {
			delete(fresh, t.allocator)
			fresh = make([]u8, int(hi - lo), t.allocator)
		}
		_tier_rewrite_add(sp, prim.get_u64le(r[56:]), Tier_Patch{rd = rd, id = id, off = i64(prim.get_u32le(r[4:])) + (lo - at), data = fresh})
		rd.left += 1
		n += 1
	}
	_tier_red_part(rd, .None)
	return n
}

@(private)
_tier_red_part :: proc(rd: ^Tier_Red_Done, result: Error) {
	sp := rd.sp
	t := sp.t
	if result != .None && !rd.failed {
		rd.failed = true
		g := sp.segs[rd.id]
		if g.redacts == nil {
			g.redacts = make([dynamic][2]i64, t.allocator)
		}
		append(&g.redacts, [2]i64{rd.at, rd.at + rd.n})
		sp.segs[rd.id] = g
		sp.redacting[rd.id] += 1
		_tier_dirty(sp, 0)
	}
	rd.left -= 1
	if rd.left > 0 {
		return
	}
	if !rd.failed {
		r: [TIER_RECORD]u8
		r[0] = u8(Tier_Kind.Redacted)
		v := rd.id
		copy(r[8:40], v[:])
		prim.put_u64le(r[40:], u64(rd.at))
		prim.put_u64le(r[48:], u64(rd.n))
		prim.put_u64le(r[56:], sp.seq)
		append(&sp.man_q, ..r[:])
		_tier_man_flush(sp)
	}
	free(rd, t.allocator)
	sp.evicting -= 1
}

@(private)
_tier_rewrite_add :: proc(sp: ^Tier_Space, seq: u64, pt: Tier_Patch) {
	t := sp.t
	key := _tier_key(sp.id, seq)
	rw, ok := t.rewrites[key]
	if !ok {
		rw = new(Tier_Rewrite, t.allocator)
		rw.t, rw.sp, rw.alloc, rw.seq = t, sp, t.allocator, seq
		rw.key, _ = _clone_string(key, t.allocator)
		rw.patches = make([dynamic]Tier_Patch, t.allocator)
		rw.next = make([dynamic]Tier_Patch, t.allocator)
		t.rewrites[rw.key] = rw
		sp.evicting += 1
	}
	sp.rewriting[pt.id] += 1
	if rw.busy {
		append(&rw.next, pt)
		return
	}
	append(&rw.patches, pt)
	_tier_rewrite_start(rw)
}

@(private)
_tier_rewrite_orphan :: proc(rw: ^Tier_Rewrite) {
	for pt in rw.patches {
		delete(pt.data, rw.alloc)
	}
	for pt in rw.next {
		delete(pt.data, rw.alloc)
	}
	delete(rw.key, rw.alloc)
	delete(rw.patches)
	delete(rw.next)
	free(rw, rw.alloc)
}

@(private)
_tier_rewrite_start :: proc(rw: ^Tier_Rewrite) {
	t := rw.t
	rw.busy = true
	rw.req = Object_Read{key = rw.key, off = 0, n = -1, done = _tier_rewrite_read, ctx = rw}
	t.cfg.objects.read(t.cfg.objects.data, &rw.req)
}

@(private)
_tier_rewrite_read :: proc(req: ^Object_Read, err: Error, bytes: []u8) {
	rw := cast(^Tier_Rewrite)req.ctx
	t := rw.t
	sp := rw.sp
	if t == nil {
		_tier_rewrite_orphan(rw)
		return
	}
	_tier_hold(sp)
	defer _tier_unhold(sp)
	if err != .None {
		rw.tries += 1
		if rw.tries < TIER_REWRITE_TRIES {
			_tier_rewrite_start(rw)
		} else {
			_tier_rewrite_done(rw, err, 0)
		}
		return
	}
	rw.tries = 0
	data := make([]u8, len(bytes), context.temp_allocator)
	copy(data, bytes)
	for pt in rw.patches {
		if pt.off + i64(len(pt.data)) <= i64(len(data)) {
			copy(data[pt.off:], pt.data)
		}
	}
	sp.account.writes += 1
	sp.account.write_bytes += u64(len(data))
	t.cfg.objects.put(t.cfg.objects.data, rw.key, data, _tier_rewrite_done, rw)
}

@(private)
_tier_rewrite_done :: proc(ctx: rawptr, result: Error, value: i64) {
	rw := cast(^Tier_Rewrite)ctx
	t := rw.t
	sp := rw.sp
	if t == nil {
		_tier_rewrite_orphan(rw)
		return
	}
	_tier_hold(sp)
	defer _tier_unhold(sp)
	_tier_blocks_forget(t, sp.id, rw.seq)
	for pt in rw.patches {
		_tier_red_part(pt.rd, result)
		delete(pt.data, t.allocator)
		sp.rewriting[pt.id] -= 1
		if sp.rewriting[pt.id] <= 0 {
			delete_key(&sp.rewriting, pt.id)
		}
	}
	clear(&rw.patches)
	rw.busy = false
	if len(rw.next) > 0 {
		rw.patches, rw.next = rw.next, rw.patches
		_tier_rewrite_start(rw)
		return
	}
	delete_key(&t.rewrites, rw.key)
	delete(rw.key, t.allocator)
	delete(rw.patches)
	delete(rw.next)
	free(rw, t.allocator)
	sp.evicting -= 1
}

@(private)
_tier_put_done :: proc(ctx: rawptr, result: Error, value: i64) {
	f := cast(^Tier_Flight)ctx
	sp := f.sp
	t := sp.t
	_tier_hold(sp)
	defer _tier_unhold(sp)
	sp.flushing = false
	if result != .None {
		for id, g in f.segs {
			cur, ok := sp.segs[id]
			if !ok {
				sp.segs[id] = g
				continue
			}
			if g.hi > g.lo {
				cur.lo = min(cur.lo, g.lo) if cur.hi > cur.lo else g.lo
				cur.hi = max(cur.hi, g.hi)
			}
			cur.note = max(cur.note, g.note)
			for r in g.redacts {
				append(&cur.redacts, r)
			}
			delete(g.redacts)
			sp.segs[id] = cur
		}
		for k, v in f.objs {
			if k not_in sp.objs {
				sp.objs[k] = v
			}
		}
		sp.bytes += f.pending
		sp.dirty = true
		sp.since = prim.clock_mono_ns(t.clock)
		sp.last = sp.since
	} else {
		sp.seq = f.seq
		sp.account.writes += 1
		sp.account.write_bytes += u64(f.n)
		append(&sp.man_q, ..f.entries[:])
		for id, g in f.segs {
			_tier_unredact(sp, id, len(g.redacts))
		}
		_tier_cold_note(sp, f.entries[:], f.segs)
		for _, &g in f.segs {
			delete(g.redacts)
		}
	}
	sp.account.pending = sp.bytes
	delete(f.segs)
	delete(f.objs)
	delete(f.entries)
	free(f, t.allocator)
	if result == .None {
		if sp.dirty {
			_tier_mark(sp, .Flushed)
		} else {
			sp.mark = .Clean
			_tier_mark(sp, .Clean)
		}
	}
	_tier_arm(t)
	if sp.bytes >= t.cfg.max_bytes {
		_tier_flush(sp)
	}
	if result == .None {
		_tier_unpark(t)
	}
}

@(private)
_tier_stream_open :: proc(data: rawptr, ns: rawptr, id: Stream_Id, create: bool) -> (s: rawptr, length: i64, err: Error) {
	t := cast(^Tier_Store)data
	sp := cast(^Tier_Space)ns
	h, l := t.inner.stream_open(t.inner.data, sp.ns, id, create) or_return
	ts := new(Tier_Stream, t.allocator)
	ts^ = {sp = sp, id = id, h = h}
	sp.open[id] = h
	return ts, l, .None
}

@(private)
_tier_stream_close :: proc(data: rawptr, s: rawptr) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	sp := ts.sp
	if cur, ok := sp.open[ts.id]; ok && cur == ts.h {
		delete_key(&sp.open, ts.id)
	}
	if ts.cold != nil {
		_tier_cold_unref(sp, ts.id, ts.cold)
	}
	t.inner.stream_close(t.inner.data, ts.h)
	free(ts, t.allocator)
	_tier_maybe_release(sp)
}

@(private)
_tier_stream_probe :: proc(data: rawptr, ns: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool, err: Error) {
	t := cast(^Tier_Store)data
	return t.inner.stream_probe(t.inner.data, (cast(^Tier_Space)ns).ns, id)
}

@(private)
_tier_stream_base :: proc(data: rawptr, s: rawptr) -> i64 {
	t := cast(^Tier_Store)data
	return t.inner.stream_base(t.inner.data, (cast(^Tier_Stream)s).h)
}

@(private)
_tier_stream_read :: proc(data: rawptr, s: rawptr, at: i64, dst: []u8) -> (int, Error) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	c := _tier_cold_of(ts)
	if c == nil || at >= c.upto || len(dst) == 0 {
		return t.inner.stream_read(t.inner.data, ts.h, at, dst)
	}
	cold := int(min(i64(len(dst)), c.upto - at))
	if err := _tier_cold_read(ts.sp, c, at, dst[:cold]); err != .None {
		return 0, err
	}
	if cold == len(dst) {
		return cold, .None
	}
	n, err := t.inner.stream_read(t.inner.data, ts.h, at + i64(cold), dst[cold:])
	return cold + n, err
}

@(private)
_tier_stream_extent :: proc(data: rawptr, s: rawptr, at: i64, n: i64) -> (fd: prim.Fd, off: i64, length: i64, ok: bool) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	if t.inner.stream_extent == nil {
		return prim.INVALID_FD, 0, 0, false
	}
	if c := _tier_cold_of(ts); c != nil && at < c.upto {
		return prim.INVALID_FD, 0, 0, false
	}
	return t.inner.stream_extent(t.inner.data, ts.h, at, n)
}

@(private)
_tier_stream_hint :: proc(data: rawptr, ns: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool) {
	t := cast(^Tier_Store)data
	sp := cast(^Tier_Space)ns
	if t.inner.stream_hint == nil {
		l, b, e, err := t.inner.stream_probe(t.inner.data, sp.ns, id)
		return l, b, e && err == .None
	}
	return t.inner.stream_hint(t.inner.data, sp.ns, id)
}

@(private)
_tier_append_begin :: proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	iw := t.inner.append_begin(t.inner.data, ts.h, at, total) or_return
	tw := new(Tier_Writer, t.allocator)
	tw^ = {sp = ts.sp, id = cast([32]u8)ts.id, w = iw, at = at, total = total, kind = .Seg}
	return tw, .None
}

@(private)
_tier_fill_begin :: proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	iw := t.inner.fill_begin(t.inner.data, ts.h, at, total) or_return
	tw := new(Tier_Writer, t.allocator)
	tw^ = {sp = ts.sp, id = cast([32]u8)ts.id, w = iw, at = at, total = total, kind = .Seg, fill = true}
	return tw, .None
}

@(private)
_tier_append_write :: proc(data: rawptr, w: rawptr, bytes: []u8) -> Error {
	t := cast(^Tier_Store)data
	return t.inner.append_write(t.inner.data, (cast(^Tier_Writer)w).w, bytes)
}

@(private)
_tier_append_abort :: proc(data: rawptr, w: rawptr) {
	t := cast(^Tier_Store)data
	tw := cast(^Tier_Writer)w
	t.inner.append_abort(t.inner.data, tw.w)
	free(tw, t.allocator)
}

@(private)
_tier_append_commit :: proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	tw := cast(^Tier_Writer)w
	j := _tier_job(tw.sp, .Seg, tw.id, tw.at, tw.total, done, ctx)
	iw := tw.w
	free(tw, t.allocator)
	t.inner.append_commit(t.inner.data, iw, _tier_job_done, j)
}

@(private)
_tier_note :: proc(data: rawptr, s: rawptr, length: i64, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	j := _tier_job(ts.sp, .Note, cast([32]u8)ts.id, length, 0, done, ctx)
	t.inner.note(t.inner.data, ts.h, length, _tier_job_done, j)
}

@(private)
_tier_trim :: proc(data: rawptr, s: rawptr, base: i64, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	j := _tier_job(ts.sp, .Trim, cast([32]u8)ts.id, base, 0, done, ctx)
	t.inner.trim(t.inner.data, ts.h, base, _tier_job_done, j)
}

@(private)
_tier_stream_trimmed :: proc(data: rawptr, s: rawptr) -> bool {
	t := cast(^Tier_Store)data
	return t.inner.stream_trimmed != nil && t.inner.stream_trimmed(t.inner.data, (cast(^Tier_Stream)s).h)
}

@(private)
_tier_drop :: proc(data: rawptr, ns: rawptr, id: Stream_Id, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	sp := cast(^Tier_Space)ns
	j := _tier_job(sp, .Drop, cast([32]u8)id, 0, 0, done, ctx)
	t.inner.drop(t.inner.data, sp.ns, id, _tier_job_done, j)
}

@(private)
_tier_redact :: proc(data: rawptr, s: rawptr, from, to: i64, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	ts := cast(^Tier_Stream)s
	ts.sp.redacting[ts.id] += 1
	j := _tier_job(ts.sp, .Redact, cast([32]u8)ts.id, from, to - from, done, ctx)
	if c := _tier_cold_of(ts); c != nil && from < c.upto {
		_tier_thaw_start(t, ts, c, from, to, j)
		return
	}
	t.inner.redact(t.inner.data, ts.h, from, to, _tier_job_done, j)
}

@(private)
_tier_unredact :: proc(sp: ^Tier_Space, id: Stream_Id, n: int) {
	if n <= 0 {
		return
	}
	sp.redacting[id] -= n
	if sp.redacting[id] <= 0 {
		delete_key(&sp.redacting, id)
	}
}

@(private)
_tier_list_begin :: proc(data: rawptr, ns: rawptr, since: i64) -> (it: rawptr, cursor: i64, err: Error) {
	t := cast(^Tier_Store)data
	return t.inner.list_begin(t.inner.data, (cast(^Tier_Space)ns).ns, since)
}

@(private)
_tier_list_next :: proc(data: rawptr, it: rawptr) -> (id: Stream_Id, ok: bool) {
	t := cast(^Tier_Store)data
	for {
		id, ok = t.inner.list_next(t.inner.data, it)
		if !ok || !_tier_reserved(cast([32]u8)id) {
			return
		}
	}
}

@(private)
_tier_list_end :: proc(data: rawptr, it: rawptr) {
	t := cast(^Tier_Store)data
	t.inner.list_end(t.inner.data, it)
}

@(private)
_tier_put_begin :: proc(data: rawptr, ns: rawptr, key: Object_Key, total: i64) -> (w: rawptr, exists: bool, err: Error) {
	t := cast(^Tier_Store)data
	sp := cast(^Tier_Space)ns
	iw, ex, e := t.inner.put_begin(t.inner.data, sp.ns, key, total)
	if ex || e != .None {
		return nil, ex, e
	}
	tw := new(Tier_Writer, t.allocator)
	tw^ = {sp = sp, id = cast([32]u8)key, w = iw, total = total, kind = .Put}
	return tw, false, .None
}

@(private)
_tier_put_write :: proc(data: rawptr, w: rawptr, bytes: []u8) -> Error {
	t := cast(^Tier_Store)data
	return t.inner.put_write(t.inner.data, (cast(^Tier_Writer)w).w, bytes)
}

@(private)
_tier_put_abort :: proc(data: rawptr, w: rawptr) {
	t := cast(^Tier_Store)data
	tw := cast(^Tier_Writer)w
	t.inner.put_abort(t.inner.data, tw.w)
	free(tw, t.allocator)
}

@(private)
_tier_put_commit :: proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	tw := cast(^Tier_Writer)w
	j := _tier_job(tw.sp, .Put, tw.id, 0, tw.total, done, ctx)
	iw := tw.w
	free(tw, t.allocator)
	t.inner.put_commit(t.inner.data, iw, _tier_job_done, j)
}

@(private)
_tier_object_open :: proc(data: rawptr, ns: rawptr, key: Object_Key) -> (o: rawptr, size: i64, err: Error) {
	t := cast(^Tier_Store)data
	return t.inner.object_open(t.inner.data, (cast(^Tier_Space)ns).ns, key)
}

@(private)
_tier_object_read :: proc(data: rawptr, o: rawptr, at: i64, dst: []u8) -> (int, Error) {
	t := cast(^Tier_Store)data
	return t.inner.object_read(t.inner.data, o, at, dst)
}

@(private)
_tier_object_extent :: proc(data: rawptr, o: rawptr, at: i64, n: i64) -> (fd: prim.Fd, off: i64, length: i64, ok: bool) {
	t := cast(^Tier_Store)data
	if t.inner.object_extent == nil {
		return prim.INVALID_FD, 0, 0, false
	}
	return t.inner.object_extent(t.inner.data, o, at, n)
}

@(private)
_tier_object_close :: proc(data: rawptr, o: rawptr) {
	t := cast(^Tier_Store)data
	t.inner.object_close(t.inner.data, o)
}

@(private)
_tier_object_remove :: proc(data: rawptr, ns: rawptr, key: Object_Key, done: Storage_Done, ctx: rawptr) {
	t := cast(^Tier_Store)data
	sp := cast(^Tier_Space)ns
	j := _tier_job(sp, .Forget, cast([32]u8)key, 0, 0, done, ctx)
	t.inner.object_remove(t.inner.data, sp.ns, key, _tier_job_done, j)
}

@(private)
_tier_account :: proc(data: rawptr, ns: rawptr) -> Store_Account {
	sp := cast(^Tier_Space)ns
	a := sp.account
	a.pending = sp.bytes
	return a
}

@(private)
_tier_objects :: proc(data: rawptr, ns: rawptr, out: ^[dynamic]Object_Key) -> Error {
	t := cast(^Tier_Store)data
	return t.inner.objects(t.inner.data, (cast(^Tier_Space)ns).ns, out)
}

Dir_Object_Store :: struct {
	vfs:   prim.Vfs,
	root:  string,
	puts:  u64,
	bytes: u64,
	gets:      u64,
	get_bytes: u64,
}

dir_object_store :: proc(d: ^Dir_Object_Store) -> Object_Store {
	return Object_Store{data = d, put = _dir_put, read = _dir_read}
}

@(private)
_dir_read :: proc(data: rawptr, req: ^Object_Read) {
	d := cast(^Dir_Object_Store)data
	path, _ := prim.path_join(context.temp_allocator, d.root, req.key)
	fd, oerr := prim.open_file(d.vfs, path)
	if oerr != .None {
		object_read_done(req, _from_prim(oerr), nil)
		return
	}
	defer prim.close_file(d.vfs, fd)
	n := req.n
	if n < 0 {
		size, serr := prim.file_size(d.vfs, fd)
		if serr != .None {
			object_read_done(req, _from_prim(serr), nil)
			return
		}
		n = max(size - req.off, 0)
	}
	buf := make([]u8, int(n), context.temp_allocator)
	got, rerr := prim.read_at(d.vfs, fd, buf, req.off)
	d.gets += 1
	d.get_bytes += u64(max(got, 0))
	object_read_done(req, _from_prim(rerr), buf[:max(got, 0)])
}

@(private)
_dir_put :: proc(data: rawptr, key: string, bytes: []u8, done: Storage_Done, ctx: rawptr) {
	d := cast(^Dir_Object_Store)data
	path, _ := prim.path_join(context.temp_allocator, d.root, key)
	if err := prim.mkdir_all(d.vfs, prim.dir_name(path), 0o700); err != .None {
		done(ctx, _from_prim(err), 0)
		return
	}
	if err := prim.replace_atomic(d.vfs, path, bytes); err != .None {
		done(ctx, _from_prim(err), 0)
		return
	}
	d.puts += 1
	d.bytes += u64(len(bytes))
	done(ctx, .None, i64(len(bytes)))
}

