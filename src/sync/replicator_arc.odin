#+build linux, darwin, windows
package osync

import "core:crypto"
import "../arc"
import "../journal"
import "../prim"

ARCHIVE_MIN_DEFAULT :: 512 * 1024
archive_target :: proc "contextless" (name: string) -> (segment: string, ok: bool) {
	if !arc.is_stream(name) {
		return "", false
	}
	return name[len(arc.STREAM_PREFIX):], true
}

Arc_Read :: struct {
	arm:     ^Remote,
	loaded:  bool,
	base:    i64,
	head:    journal.Hash,
	index:   [dynamic]arc.Seal_Entry,
	wants:   [dynamic]journal.Range,
	seal_at: i64,
	driving: bool,
	fresh_need: u64,
	redacts: [dynamic]journal.Range,
	wipes:    [dynamic]journal.Range,
	rsts:     [dynamic]^Remote,
	rst_need: [dynamic]u64,
	rst_init: bool,
	pend:     [dynamic]_Rst_Pend,
	again:    bool,
	back_pos: i64,
	back_win: i64,
}

@(private)
_Rst_Pend :: struct {
	arc_off: i64,
	local:   Stream_Id,
	end:     i64,
	src:     Stream_Id,
	src_off: i64,
	src_len: i64,
}

@(private)
_Src :: struct {
	id:   Stream_Id,
	off:  i64,
	size: i64,
	body: []u8,
	own:  bool,
	zeroed: bool,
}

@(private)
_Res :: enum u8 {
	Wait,
	Found,
	None,
}

@(private)
_Arc_Item :: struct {
	off:    i64,
	n:      int,
	body:   []u8,
	commit: journal.Hash,
	sig:    bool,
	rdx:    bool,
}

@(private)
_Span_Rec :: struct {
	off:  i64,
	size: i64,
	rdx:  bool,
}

restore_target :: proc "contextless" (name: string) -> (segment: string, ok: bool) {
	n := len(arc.RESTORE_PREFIX) + 33
	if len(name) <= n || name[:len(arc.RESTORE_PREFIX)] != arc.RESTORE_PREFIX || name[n - 1] != '/' {
		return "", false
	}
	return name[n:], true
}

derived_target :: proc "contextless" (name: string) -> (segment: string, ok: bool) {
	if segment, ok = archive_target(name); ok {
		return
	}
	return restore_target(name)
}

@(private)
_arc_path :: proc(r: ^Replicator, buf: ^prim.Path_Buf, id: Stream_Id) -> string {
	n := copy(buf[:], r.dir)
	n += copy(buf[n:], "/arc/")
	sid := id
	n += prim.hex_encode(buf[n:], sid[:])
	return string(buf[:n])
}

@(private)
_arc_dir :: proc(r: ^Replicator) -> bool {
	if r.arc_dir {
		return true
	}
	p, perr := prim.path_join(context.temp_allocator, r.dir, "arc")
	if perr != .None || prim.mkdir_all(r.vfs, p, 0o700) != .None {
		return false
	}
	r.arc_dir = true
	return true
}

@(private)
_arc_on :: proc(r: ^Replicator) -> bool {
	return r.cfg.archive_min > 0 && r.features & FEATURE_TRIM != 0 && r.features & FEATURE_BELOW_BASE != 0 && r.cfg.signer.sign != nil
}

@(private)
_arc_maybe_run :: proc(r: ^Replicator, l: ^Local) {
	if !l.archive || l.hollow || l.fatal || l.superseded || !_arc_on(r) || r.phase != .Ready || l.arc_timer != 0 {
		return
	}
	if l.floor - l.arc_sealed < r.cfg.archive_min {
		return
	}
	l.arc_timer = prim.timer(r.loop, 0, l, _arc_tick)
}

@(private)
_arc_tick :: proc(lp: ^prim.Loop, data: rawptr) {
	l := cast(^Local)data
	l.arc_timer = 0
	r := l.repl
	if r == nil {
		return
	}
	_enter(r)
	defer _leave(r)
	more := _arc_step(r, l)
	if more && r.phase == .Ready && !l.fatal && !l.superseded {
		l.arc_timer = prim.timer(r.loop, 0, l, _arc_tick)
	}
	_local_maybe_free(r, l)
	_repl_flush(r)
}

@(private)
_arc_step :: proc(r: ^Replicator, l: ^Local) -> (more: bool) {
	scope := Scope{}
	name, nerr := arc.stream_name(l.name)
	if nerr != .None {
		return false
	}
	scope = l.scope
	aid := stream_id(&scope, r.cfg.self, name, l.epoch)
	pbuf: prim.Path_Buf = ---
	path := _arc_path(r, &pbuf, aid)
	chain := journal.Chain {
		seed   = chain_seed(aid),
		signer = r.cfg.signer,
	}
	if !_arc_dir(r) {
		return false
	}
	j: journal.Journal
	if err := journal.journal_open(&j, r.vfs, path, journal.Options{chain = &chain}, context.temp_allocator); err != .None {
		return false
	}
	defer journal.journal_close(&j)
	seal: arc.Seal
	seal.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
	full := make([dynamic]arc.Seal_Entry, context.temp_allocator)
	seal_at, seal_end, have_seal, lerr := _arc_last_seal(&j, &seal, &full)
	if lerr != .None {
		return false
	}
	sealed: i64
	head := journal.chain_genesis(chain_seed(l.id))
	if have_seal {
		sealed = seal.base
		head = seal.head
	}
	if sealed != l.arc_sealed {
		l.arc_sealed = sealed
		_arc_floor_save(r, l)
	}
	if l.floor - sealed >= r.cfg.archive_min {
		group, gerr := _arc_build_keyed(r, l, &j, sealed, head)
		if gerr == .None && group.end > group.first {
			delta := make([dynamic]arc.Seal_Entry, context.temp_allocator)
			if have_seal && !seal.full {
				for e in seal.entries {
					append(&delta, e)
				}
			}
			arc.seal_merge(&delta, []arc.Seal_Entry{group.entry})
			ns: arc.Seal
			ns.base = group.end
			ns.head = group.head
			if len(full) == 0 || len(delta) * 2 >= len(full) {
				arc.seal_merge(&full, delta[:])
				ns.full = true
				ns.entries = full
			} else {
				ns.full_at = seal.full_at if have_seal && !seal.full else seal_at
				ns.entries = delta
			}
			body := make([dynamic]u8, context.temp_allocator)
			if arc.seal_encode(&body, &ns) == .None {
				at := journal.journal_len(&j)
				if _, aerr := journal.journal_append(&j, body[:]); aerr == .None && journal.journal_commit(&j) == .None {
					seal_end = at + journal.record_size(len(body))
					l.arc_sealed = ns.base
					_arc_floor_save(r, l)
					have_seal = true
					more = l.floor - ns.base >= r.cfg.archive_min
				}
			}
		}
	}
	if !have_seal {
		return more
	}
	durable := journal.journal_durable_len(&j)
	al, ok := r.locals[aid]
	if !ok {
		nl, oerr := _local_open(r, &scope, name, l.epoch, aid, path)
		if oerr != .None {
			return more
		}
		al = nl
	}
	al.plain = true
	al.arc_child = true
	al.trim_for = l.id
	al.trim_base = l.arc_sealed
	al.trim_at = seal_end
	al.durable = max(al.durable, durable)
	al.blocked = false
	if al.floor >= al.trim_at {
		_arc_trim_send(r, al)
	}
	_local_pump(r, al)
	return more
}

@(private)
_arc_trim_send :: proc(r: ^Replicator, al: ^Local) {
	if al.trim_at <= 0 || al.trim_base <= 0 || al.trim_sent >= al.trim_base || r.phase != .Ready {
		return
	}
	if _, inflight := r.trims[al.trim_for]; inflight {
		al.trim_wait = true
		return
	}
	if client_trim(&r.client, al.trim_for, al.trim_base) == .None {
		al.trim_sent = al.trim_base
		r.trims[al.trim_for] = al.trim_base
	}
}


@(private)
_arc_advanced :: proc(r: ^Replicator, l: ^Local) {
	if l.arc_child && l.floor >= l.trim_at {
		_arc_trim_send(r, l)
	}
	if l.rst_on {
		if rm, ok := r.remotes[l.rst_of]; ok && rm.arc != nil && len(rm.arc.pend) > 0 {
			_arc_drive(r, rm)
		}
	}
	_arc_maybe_run(r, l)
}

@(private)
_arc_floor_save :: proc(r: ^Replicator, l: ^Local) {
	seq := l.floor_seq + 1
	if slot_write(r.vfs, l.floor_fd, Slot{seq = seq, value = l.floor, start = min(l.arc_sealed, l.floor)}) != .None {
		return
	}
	if prim.sync_owed(r.vfs, l.floor_fd, &l.floor_owed) == .None {
		l.floor_seq = seq
	}
}

@(private)
_arc_last_seal :: proc(j: ^journal.Journal, seal: ^arc.Seal, full: ^[dynamic]arc.Seal_Entry) -> (at: i64, end: i64, found: bool, err: Error) {
	rd: journal.Reader
	journal.journal_reader(j, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	pos := journal.journal_durable_len(j)
	for pos > 0 {
		body, off, rerr := journal.record_before(&rd, pos)
		if rerr == .Redacted {
			pos = off
			continue
		}
		if rerr != .None {
			return 0, 0, false, .Corrupt
		}
		if len(body) > 0 && body[0] == arc.SEAL_KIND {
			if arc.seal_parse(body, seal) != .None {
				return 0, 0, false, .Corrupt
			}
			at, end, found = off, pos, true
			break
		}
		pos = off
	}
	if !found {
		return
	}
	if seal.full {
		for e in seal.entries {
			append(full, e)
		}
		return
	}
	body, _, rerr := journal.record_at(&rd, seal.full_at)
	if rerr != .None {
		return 0, 0, false, .Corrupt
	}
	fs: arc.Seal
	fs.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
	if arc.seal_parse(body, &fs) != .None || !fs.full {
		return 0, 0, false, .Corrupt
	}
	for e in fs.entries {
		append(full, e)
	}
	return
}

@(private)
_Built :: struct {
	first: i64,
	end:   i64,
	head:  journal.Hash,
	entry: arc.Seal_Entry,
}

@(private)
_Build_Ctx :: struct {
	r:    ^Replicator,
	l:    ^Local,
	j:    ^journal.Journal,
	from: i64,
	stop: i64,
	head: journal.Hash,
	out:  _Built,
	err:  Error,
	ran:  bool,
}

@(private)
_arc_build_use :: proc(data: rawptr, keys: journal.Key_Provider, shift: u8) {
	c := cast(^_Build_Ctx)data
	c.out, c.err = _arc_build(c.r, c.l, c.j, c.from, c.head, keys, shift, c.stop)
	c.ran = true
}

@(private)
_arc_build_keyed :: proc(r: ^Replicator, l: ^Local, j: ^journal.Journal, from: i64, head: journal.Hash, stop: i64 = 0) -> (out: _Built, err: Error) {
	if l.plain {
		return _arc_build(r, l, j, from, head, {}, 0, stop)
	}
	if r.cfg.archive_keys == nil {
		if l.keyed {
			return {first = from, end = from}, .Busy
		}
		return _arc_build(r, l, j, from, head, static_provider(&l.key), 0, stop)
	}
	c := _Build_Ctx{r = r, l = l, j = j, from = from, head = head, stop = stop}
	if !r.cfg.archive_keys(r.cfg.user, l.name, l.id, _arc_build_use, &c) || !c.ran {
		return {first = from, end = from}, .Busy
	}
	return c.out, c.err
}

@(private)
_arc_build :: proc(r: ^Replicator, l: ^Local, j: ^journal.Journal, from: i64, head: journal.Hash, keys: journal.Key_Provider, shift: u8, stop: i64 = 0) -> (out: _Built, err: Error) {
	rd: journal.Reader
	if journal.reader_open(&rd, r.vfs, l.path, context.temp_allocator) != .None {
		return {}, .Io
	}
	defer journal.reader_close(&rd)
	limit := min(l.floor, journal.reader_end(&rd))
	if stop > 0 {
		limit = min(stop, journal.reader_end(&rd))
	}
	items := make([dynamic]_Arc_Item, context.temp_allocator)
	span := make([dynamic]_Span_Rec, context.temp_allocator)
	links := make([dynamic]journal.Link, context.temp_allocator)
	group_raw := r.cfg.archive_group if r.cfg.archive_group > 0 else arc.GROUP_RAW
	mode := arc.Mode.Plain if l.plain else arc.Mode.Sealed
	pos := from
	span_start := from
	raw := 0
	for pos < limit && (stop > 0 || raw < group_raw) {
		body, nxt, rerr := journal.record_at(&rd, pos)
		if rerr == .Redacted {
			append(&span, _Span_Rec{off = pos, size = nxt - pos, rdx = true})
			pos = nxt
			continue
		}
		if rerr != .None {
			break
		}
		if !journal.is_sig(body) {
			append(&span, _Span_Rec{off = pos, size = nxt - pos})
			pos = nxt
			continue
		}
		if nxt > limit || (stop <= 0 && nxt == limit) {
			break
		}
		info, _, perr := journal.parse_sig(body, pos, &links)
		if perr != .None || info.range_start != span_start || len(links) != len(span) {
			return {}, .Corrupt
		}
		for &s, i in span {
			if i64(links[i].len) + journal.OVERHEAD != s.size {
				return {}, .Corrupt
			}
			if !s.rdx && mode == .Sealed && !_key_live(keys, s.off) {
				s.rdx = true
			}
			it := _Arc_Item{off = s.off, n = int(links[i].len), commit = links[i].commit, rdx = s.rdx}
			if !s.rdx {
				sb, _, serr := journal.record_at(&rd, s.off)
				if serr != .None {
					return {}, .Corrupt
				}
				it.body = make([]u8, len(sb), context.temp_allocator)
				copy(it.body, sb)
				raw += len(sb)
			}
			append(&items, it)
		}
		append(&items, _Arc_Item{off = pos, n = int(nxt - pos - journal.OVERHEAD), sig = true})
		clear(&span)
		pos = nxt
		span_start = nxt
	}
	if len(items) == 0 {
		return {first = from, end = from}, .None
	}
	gone := make([]bool, len(items), context.temp_allocator)
	if r.cfg.archive_collect != nil {
		bodies := make([][]u8, len(items), context.temp_allocator)
		offs := make([]i64, len(items), context.temp_allocator)
		for it, i in items {
			offs[i] = it.off
			if !it.sig && !it.rdx {
				bodies[i] = it.body
			}
		}
		r.cfg.archive_collect(r.cfg.user, l.name, offs, bodies, gone)
	}
	b: arc.Builder
	arc.builder_init(&b, from, head, context.temp_allocator)
	defer arc.builder_destroy(&b)
	for it, i in items {
		e: arc.Error
		switch {
		case it.sig:
			e = arc.builder_hole(&b, it.off, it.n, true, {})
		case it.rdx:
			e = arc.builder_hole(&b, it.off, it.n, false, it.commit)
		case gone[i]:
			e = arc.builder_gone(&b, it.off, it.n, it.commit)
		case:
			e = arc.builder_add(&b, it.off, it.body, false, false, it.commit)
		}
		if it.body != nil {
			crypto.zero_explicit(raw_data(it.body), len(it.body))
		}
		if e != .None {
			return {}, .Corrupt
		}
	}
	if b.count == 0 {
		return {first = from, end = from}, .None
	}
	salt: [arc.SALT]u8
	prim.random_fill(r.cfg.random, salt[:])
	level := r.cfg.archive_level if r.cfg.archive_level > 0 else arc.LEVEL
	body := make([dynamic]u8, context.temp_allocator)
	if e := arc.builder_finish(&b, &body, mode, keys, shift, salt, level); e != .None {
		return {}, .Corrupt
	}
	at := journal.journal_len(j)
	if _, aerr := journal.journal_append(j, body[:]); aerr != .None {
		return {}, .Io
	}
	out = _Built {
		first = b.first,
		end   = b.pos,
		head  = b.head,
		entry = arc.Seal_Entry{first = b.first, end = b.pos, arc_off = at, arc_len = journal.record_size(len(body)), head_before = b.head_before, head_after = b.head},
	}
	return out, .None
}

@(private)
_arc_want :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	if to <= from {
		return
	}
	for b in rm.arc_broken {
		if b.from <= from && b.to >= to {
			_pull_range(r, rm, from, to)
			return
		}
	}
	a := _arc_reader(r, rm)
	if a == nil {
		return
	}
	for &w in a.wants {
		if w.from <= from && w.to >= to {
			_arc_drive(r, rm)
			return
		}
		if w.from <= to && from <= w.to {
			w.from = min(w.from, from)
			w.to = max(w.to, to)
			_arc_drive(r, rm)
			return
		}
	}
	append(&a.wants, journal.Range{from, to})
	_arc_drive(r, rm)
}

@(private)
_arc_release :: proc(r: ^Replicator, rm: ^Remote) {
	a := rm.arc
	if a == nil {
		return
	}
	rm.arc = nil
	if a.arm != nil {
		a.arm.arc_of = nil
		a.arm.refs -= 1
		_remote_maybe_free(r, a.arm)
	}
	for rr in a.rsts {
		rr.arc_of = nil
		rr.refs -= 1
		_remote_maybe_free(r, rr)
	}
	delete(a.index)
	delete(a.wants)
	delete(a.redacts)
	delete(a.wipes)
	delete(a.rsts)
	delete(a.rst_need)
	delete(a.pend)
	free(a, r.allocator)
}

@(private)
_arm_want :: proc(r: ^Replicator, arm: ^Remote, from, to: i64) {
	for &w in arm.wants {
		if w.from <= from && w.to >= to {
			return
		}
		if w.from <= to && from <= w.to {
			w.from = min(w.from, from)
			w.to = max(w.to, to)
			if arm.relay_len < 0 || to > arm.relay_len {
				arm.want_gen += 1
			}
			_remote_settle(r, arm)
			return
		}
	}
	append(&arm.wants, journal.Range{from, to})
	if arm.relay_len < 0 || to > arm.relay_len {
		arm.want_gen += 1
	}
	_remote_settle(r, arm)
}

@(private)
_arc_drive :: proc(r: ^Replicator, rm: ^Remote) {
	a := rm.arc
	if a == nil || a.arm == nil || r.phase != .Ready {
		return
	}
	if a.driving {
		a.again = true
		return
	}
	a.driving = true
	defer a.driving = false
	for n := 0; n < 8; n += 1 {
		a.again = false
		if len(a.wants) == 0 && len(a.redacts) == 0 && len(a.wipes) == 0 && len(a.pend) == 0 {
			return
		}
		_arc_drive_once(r, rm)
		if !a.again || rm.arc != a {
			return
		}
	}
}

@(private)
_arc_drive_once :: proc(r: ^Replicator, rm: ^Remote) {
	a := rm.arc
	if a.loaded && rm.base > a.base {
		for w in a.wants {
			if w.to > a.base {
				a.loaded = false
				break
			}
		}
	}
	if !a.loaded {
		if !_arc_load(r, rm) {
			return
		}
	}
	keys, sealed, ok := _arc_keys(r, rm)
	if !ok {
		return
	}
	if len(a.wipes) > 0 {
		_arc_wipe(r, rm, keys)
	}
	if len(a.redacts) > 0 || len(a.pend) > 0 {
		_arc_redacts(r, rm, keys, sealed)
	}
	if len(a.wants) == 0 {
		return
	}
	progressed := false
	for i := 0; i < len(a.wants); {
		w := a.wants[i]
		lo := w.from
		hi := min(w.to, a.base)
		done := true
		for lo < hi {
			e, found := arc.seal_lookup(a.index[:], lo)
			if !found {
				_arc_broken(r, rm, lo, hi)
				break
			}
			if journal.replica_covers(&rm.rep, e.first, e.end) {
				lo = e.end
				continue
			}
			res, src := _arc_resolve(r, rm, e, keys)
			switch res {
			case .Wait:
				done = false
				lo = e.end
				continue
			case .None:
				if src.zeroed {
					done = false
					lo = e.end
					continue
				}
				_arc_broken(r, rm, e.first, e.end)
			case .Found:
				if !_arc_apply(r, rm, e, src.body, keys, sealed) {
					_arc_broken(r, rm, e.first, e.end)
				} else if src.id != rm.arc.arm.id {
					r.restores_read += 1
				}
			}
			progressed = true
			lo = e.end
		}
		if done && w.to > a.base {
			_arc_broken(r, rm, max(w.from, a.base), w.to)
		}
		if done {
			ordered_remove(&a.wants, i)
			progressed = true
			continue
		}
		i += 1
	}
	if progressed {
		_remote_settle(r, rm)
	}
}

@(private)
_arm_verified :: proc(arm: ^Remote, from, to: i64) -> bool {
	for v in arm.verified {
		if v.from <= from && v.to >= to {
			return true
		}
	}
	return false
}

@(private)
_arc_broken :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	if to <= from {
		return
	}
	append(&rm.arc_broken, journal.Range{from, to})
	_pull_range(r, rm, from, to)
}

@(private)
_arc_keys :: proc(r: ^Replicator, rm: ^Remote) -> (keys: journal.Key_Provider, sealed: bool, ok: bool) {
	if rm.plain {
		if r.cfg.keys != nil {
			_, tree := r.cfg.keys(r.cfg.user, rm.device, rm.name, rm.epoch, rm.id)
			return tree, false, true
		}
		return {}, false, true
	}
	if r.cfg.keys == nil {
		return static_provider(&rm.skey), true, true
	}
	sealing, tree := r.cfg.keys(r.cfg.user, rm.device, rm.name, rm.epoch, rm.id)
	switch sealing {
	case .Unknown:
		if !rm.keys_wait {
			rm.keys_wait = true
			_emit(r, Repl_Event{kind = .Keys_Needed, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
		}
		return {}, false, false
	case .Stream_Key:
		return static_provider(&rm.skey), true, true
	case .Key_Tree, .Key_Tree_Stale:
		return tree, true, true
	}
	return {}, false, false
}

@(private)
_arc_load :: proc(r: ^Replicator, rm: ^Remote) -> bool {
	a := rm.arc
	arm := a.arm
	if arm.relay_len < 0 || arm.fresh_gen < a.fresh_need {
		if arm.tail == 0 && !arm.probing {
			_remote_want_tail(r, arm, TAIL_DEFAULT)
			a.fresh_need = arm.want_gen
		}
		return false
	}
	end := arm.relay_len
	if end <= 0 {
		clear(&a.index)
		a.base = 0
		a.loaded = true
		a.fresh_need = arm.want_gen + 1
		return true
	}
	rd: journal.Reader
	journal.replica_reader(&arm.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	pos := end
	seal: arc.Seal
	seal.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
	for pos > 0 {
		if !journal.replica_covers(&arm.rep, max(pos - journal.TRAILER, 0), pos) {
			_arc_back_read(r, a, arm, pos)
			return false
		}
		body, off, rerr := journal.record_before(&rd, pos)
		if rerr == .Missing {
			_arc_back_read(r, a, arm, pos)
			return false
		}
		if rerr == .Redacted {
			pos = off
			continue
		}
		if rerr != .None {
			_arc_fail(r, rm)
			return false
		}
		if !_arm_verified(arm, off, pos) {
			_arm_want(r, arm, off, pos)
			return false
		}
		if len(body) > 0 && body[0] == arc.SEAL_KIND {
			if arc.seal_parse(body, &seal) != .None {
				_arc_fail(r, rm)
				return false
			}
			a.seal_at = off
			break
		}
		pos = off
	}
	if pos <= 0 {
		_arc_fail(r, rm)
		return false
	}
	clear(&a.index)
	if !seal.full {
		fbody, _, ferr := journal.record_at(&rd, seal.full_at)
		if ferr == .Missing || (ferr == .None && !_arm_verified(arm, seal.full_at, seal.full_at + journal.record_size(len(fbody)))) {
			hi := seal.full_at + journal.HEADER
			if ferr == .None {
				hi = seal.full_at + journal.record_size(len(fbody))
			} else if journal.replica_covers(&arm.rep, seal.full_at, seal.full_at + 4) {
				hi = seal.full_at + journal.record_size(int(_arm_u32(r, arm, seal.full_at)))
			}
			_arm_want(r, arm, seal.full_at, _arm_span_end(arm, hi))
			return false
		}
		fs: arc.Seal
		fs.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
		if ferr != .None || arc.seal_parse(fbody, &fs) != .None || !fs.full {
			_arc_fail(r, rm)
			return false
		}
		for e in fs.entries {
			append(&a.index, e)
		}
	}
	arc.seal_merge(&a.index, seal.entries[:])
	a.base = seal.base
	a.head = seal.head
	a.loaded = true
	a.fresh_need = arm.want_gen + 1
	return true
}

@(private)
_arm_span_end :: proc(arm: ^Remote, hi: i64) -> i64 {
	end := hi + TAIL_DEFAULT
	if arm.relay_len >= 0 {
		end = min(end, arm.relay_len)
	}
	for h in journal.replica_have(&arm.rep) {
		if h.from >= hi {
			end = min(end, h.from)
			break
		}
		if h.to > hi {
			return hi
		}
	}
	return max(end, hi)
}

@(private)
_arc_back_read :: proc(r: ^Replicator, a: ^Arc_Read, arm: ^Remote, pos: i64) {
	end := pos
	for h in journal.replica_have(&arm.rep) {
		if h.from < pos && h.to >= pos {
			end = h.from
		}
	}
	if end <= 0 || r.phase != .Ready {
		return
	}
	if a.back_pos == end {
		a.back_win = min(a.back_win * 2, end)
	} else {
		a.back_win = min(i64(TAIL_DEFAULT), end)
	}
	a.back_pos = end
	gap := journal.Range{end - a.back_win, end}
	if _covered_inflight(arm, gap) {
		return
	}
	if client_read(&r.client, arm.id, gap.from, gap.to) == .None {
		append(&arm.inflight, gap)
		r.read_reqs += 1
	}
}

@(private)
_arm_u32 :: proc(r: ^Replicator, arm: ^Remote, at: i64) -> u32 {
	b: [4]u8
	if n, err := prim.read_at(r.vfs, arm.rep.fd, b[:], at); err != .None || n != 4 {
		return 0
	}
	return min(prim.get_u32le(b[:]), journal.MAX_BODY)
}

@(private)
_arc_apply :: proc(r: ^Replicator, rm: ^Remote, e: arc.Seal_Entry, body: []u8, keys: journal.Key_Provider, sealed: bool) -> bool {
	g, perr := arc.group_parse(body, e.arc_off)
	if perr != .None || g.first != e.first || g.end != e.end || g.head_before != e.head_before || g.head_after != e.head_after {
		return false
	}
	raw, oerr := arc.group_open(&g, keys)
	if oerr != .None {
		return false
	}
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	chain := journal.Chain{keys = keys}
	verr := arc.group_verify(&g, raw, &chain)
	if verr != .None {
		return false
	}
	if g.end == rm.arc.base && g.head_after != rm.arc.head {
		return false
	}
	out := make([dynamic]u8, 0, int(g.end - g.first), context.temp_allocator)
	cur: arc.Cursor
	arc.cursor_init(&cur, &g, raw)
	defer arc.cursor_destroy(&cur)
	en: arc.Entry
	for {
		more, cerr := arc.cursor_next(&cur, &en)
		if cerr != .None {
			return false
		}
		if !more {
			break
		}
		at := len(out)
		resize(&out, at + int(journal.record_size(en.len)))
		if arc.entry_record(&en, out[at:], keys, sealed) != .None {
			return false
		}
	}
	if i64(len(out)) != g.end - g.first {
		return false
	}
	if _stage_write(r, rm, g.first, out[:]) != .None {
		return false
	}
	crypto.zero_explicit(raw_data(out[:]), len(out))
	journal.replica_trust(&rm.rep, g.first, g.end)
	_verified_add(rm, g.first, g.end)
	_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = g.first, to = g.end, length = rm.relay_len})
	return true
}

@(private)
_arc_arm_settled :: proc(r: ^Replicator, arm: ^Remote) {
	if rm := arm.arc_of; rm != nil {
		_arc_drive(r, rm)
	}
}

@(private)
_arc_free_local :: proc(r: ^Replicator, l: ^Local) {
	if l.arc_timer != 0 {
		prim.timer_cancel(r.loop, l.arc_timer)
		l.arc_timer = 0
	}
}


@(private)
_key_live :: proc(keys: journal.Key_Provider, off: i64) -> bool {
	k: journal.Key
	ok := keys.key != nil && keys.key(keys.data, off, &k)
	crypto.zero_explicit(&k, size_of(k))
	return ok
}

@(private)
_arc_trim_reply :: proc(r: ^Replicator, id: Stream_Id, refused: bool) -> bool {
	if _, ok := r.trims[id]; !ok {
		return false
	}
	delete_key(&r.trims, id)
	if !refused {
		_arc_trim_resume(r, id)
		return true
	}
	for _, al in r.locals {
		if al.arc_child && al.trim_for == id {
			al.trim_sent = 0
			al.trim_wait = true
		}
	}
	return true
}

@(private)
_arc_trim_resume :: proc(r: ^Replicator, id: Stream_Id) {
	if _, inflight := r.trims[id]; inflight {
		return
	}
	for _, al in r.locals {
		if al.arc_child && al.trim_wait && al.trim_for == id {
			al.trim_wait = false
			if al.floor >= al.trim_at {
				_arc_trim_send(r, al)
			}
		}
	}
}

@(private)
_arc_reader :: proc(r: ^Replicator, rm: ^Remote) -> ^Arc_Read {
	if rm.arc != nil {
		return rm.arc
	}
	name, nerr := arc.stream_name(rm.name)
	if nerr != .None {
		return nil
	}
	arm, err := _remote_get(r, &rm.scope, rm.device, name, rm.epoch)
	if err != .None {
		return nil
	}
	na, aerr := new(Arc_Read, r.allocator)
	if aerr != nil {
		return nil
	}
	na.arm = arm
	na.index = make([dynamic]arc.Seal_Entry, r.allocator)
	na.wants = make([dynamic]journal.Range, r.allocator)
	na.redacts = make([dynamic]journal.Range, r.allocator)
	na.wipes = make([dynamic]journal.Range, r.allocator)
	na.rsts = make([dynamic]^Remote, r.allocator)
	na.rst_need = make([dynamic]u64, r.allocator)
	na.pend = make([dynamic]_Rst_Pend, r.allocator)
	arm.refs += 1
	arm.plain = true
	arm.arc_of = rm
	rm.arc = na
	return na
}

@(private)
_arc_members_grew :: proc(r: ^Replicator, g: ^Group) {
	for m in g.members {
		if rm, ok := r.remotes[stream_id(&g.scope, m, g.name, g.epoch)]; ok && rm.arc != nil && rm.arc.rst_init && len(rm.arc.wants) > 0 {
			_arc_drive(r, rm)
		}
	}
}

@(private)
_arc_redact_remote :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) -> bool {
	if to <= from || !_arc_on(r) || rm.arc_of != nil || arc.is_stream(rm.name) || _is_restore(rm.name) {
		return false
	}
	a := _arc_reader(r, rm)
	if a == nil {
		return false
	}
	append(&a.redacts, journal.Range{from, to})
	a.loaded = false
	_arc_drive(r, rm)
	return true
}

@(private)
_arc_wipe_remote :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	if !rm.trimmed || from >= rm.base || to <= from || rm.arc_of != nil {
		return
	}
	a := _arc_reader(r, rm)
	if a == nil {
		return
	}
	append(&a.wipes, journal.Range{from, min(to, rm.base)})
	a.loaded = false
	_arc_drive(r, rm)
}

@(private)
_is_restore :: proc "contextless" (name: string) -> bool {
	return len(name) >= len(arc.RESTORE_PREFIX) && name[:len(arc.RESTORE_PREFIX)] == arc.RESTORE_PREFIX
}

@(private)
_arc_fail :: proc(r: ^Replicator, rm: ^Remote) {
	a := rm.arc
	_arc_broken(r, rm, 0, rm.base)
	clear(&a.wants)
	clear(&a.wipes)
	for x in a.redacts {
		client_redact(&r.client, rm.id, x.from, x.to)
	}
	clear(&a.redacts)
}

@(private)
_rep_record :: proc(rep: ^journal.Replica, off: i64) -> (body: []u8, nxt: i64, err: journal.Error) {
	rd: journal.Reader
	journal.replica_reader(rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	b, n, e := journal.record_at(&rd, off)
	if e != .None {
		return nil, n, e
	}
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out, n, .None
}

@(private)
_arc_resolve :: proc(r: ^Replicator, rm: ^Remote, e: arc.Seal_Entry, keys: journal.Key_Provider) -> (_Res, _Src) {
	arm := rm.arc.arm
	hi := e.arc_off + e.arc_len
	if !journal.replica_covers(&arm.rep, e.arc_off, hi) || !_arm_verified(arm, e.arc_off, hi) {
		_arm_want(r, arm, e.arc_off, _arm_span_end(arm, hi))
		return .Wait, {}
	}
	body, nxt, rerr := _rep_record(&arm.rep, e.arc_off)
	if rerr == .None && nxt == hi {
		return .Found, _Src{id = arm.id, off = e.arc_off, size = e.arc_len, body = body}
	}
	if rerr == .Redacted {
		return _arc_rst_find(r, rm, e, keys)
	}
	return .None, {}
}

@(private)
_rst_name :: proc(rm: ^Remote) -> (string, bool) {
	name, err := arc.restore_stream_name(cast([16]u8)rm.device, rm.name)
	return name, err == .None
}

@(private)
_arc_rst_refresh :: proc(r: ^Replicator, rm: ^Remote) {
	a := rm.arc
	a.rst_init = true
	name, nok := _rst_name(rm)
	if !nok {
		return
	}
	devs := make([dynamic]Device_Id, context.temp_allocator)
	if g, ok := r.groups[stream_id_suffix(rm.id)]; ok {
		for d in g.members {
			append(&devs, d)
		}
	} else {
		for d in r.devices {
			append(&devs, d)
		}
	}
	for d in devs {
		full: [32]u8
		dv := d
		copy(full[:16], dv[:])
		if d == r.cfg.self || d == rm.device || _reserved(full) {
			continue
		}
		known := false
		for rr in a.rsts {
			if rr.device == d {
				known = true
				break
			}
		}
		if known {
			continue
		}
		rr, err := _remote_get(r, &rm.scope, d, name, rm.epoch)
		if err != .None || (rr.arc_of != nil && rr.arc_of != rm) {
			continue
		}
		rr.refs += 1
		rr.plain = true
		rr.arc_of = rm
		append(&a.rsts, rr)
		_remote_want_tail(r, rr, TAIL_DEFAULT)
		append(&a.rst_need, rr.want_gen)
	}
}

@(private)
_rst_check :: proc(group: []u8, e: arc.Seal_Entry, keys: journal.Key_Provider) -> (holes: int, ok: bool) {
	g, perr := arc.group_parse(group, e.arc_off)
	if perr != .None || g.first != e.first || g.end != e.end || g.head_before != e.head_before || g.head_after != e.head_after {
		return 0, false
	}
	raw, oerr := arc.group_open(&g, keys)
	if oerr != .None {
		return 0, false
	}
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	chain := journal.Chain{keys = keys}
	if arc.group_verify(&g, raw, &chain) != .None {
		return 0, false
	}
	cur: arc.Cursor
	arc.cursor_init(&cur, &g, raw)
	defer arc.cursor_destroy(&cur)
	en: arc.Entry
	for {
		more, cerr := arc.cursor_next(&cur, &en)
		if cerr != .None {
			return 0, false
		}
		if !more {
			break
		}
		if en.kind == .Redacted {
			holes += 1
		}
	}
	return holes, true
}

@(private)
_rst_scan :: proc(rd: ^journal.Reader, n: i64, id: Stream_Id, own: bool, rm: ^Remote, e: arc.Seal_Entry, keys: journal.Key_Provider, best: ^_Src, best_n: ^int) {
	target := cast([16]u8)rm.device
	pos := i64(0)
	for pos < n {
		body, nxt, rerr := journal.record_at(rd, pos)
		if rerr == .Redacted {
			pos = nxt
			continue
		}
		if rerr != .None || nxt <= pos {
			return
		}
		if len(body) > 0 && body[0] == arc.RESTORE_KIND {
			rs: arc.Restore
			if arc.restore_parse(body, &rs) == .None && rs.target == target && rs.arc_off == e.arc_off {
				if cnt, ok := _rst_check(rs.group, e, keys); ok && cnt >= best_n^ {
					g := make([]u8, len(rs.group), context.temp_allocator)
					copy(g, rs.group)
					best^ = _Src{id = id, off = pos, size = nxt - pos, body = g, own = own}
					best_n^ = cnt
				}
			}
		}
		pos = nxt
	}
}

@(private)
_rst_own :: proc(r: ^Replicator, rm: ^Remote, buf: ^prim.Path_Buf) -> (id: Stream_Id, path: string, ok: bool) {
	name, nok := _rst_name(rm)
	if !nok {
		return
	}
	id = stream_id(&rm.scope, r.cfg.self, name, rm.epoch)
	return id, _arc_path(r, buf, id), true
}

@(private)
_arc_rst_find :: proc(r: ^Replicator, rm: ^Remote, e: arc.Seal_Entry, keys: journal.Key_Provider) -> (_Res, _Src) {
	a := rm.arc
	_arc_rst_refresh(r, rm)
	wait := false
	best: _Src
	best_n := -1
	for rr, i in a.rsts {
		if rr.relay_len < 0 || rr.fresh_gen < a.rst_need[i] {
			if rr.tail == 0 && !rr.probing {
				_remote_want_tail(r, rr, TAIL_DEFAULT)
				a.rst_need[i] = rr.want_gen
			}
			wait = true
			continue
		}
		n := rr.relay_len
		if n <= 0 {
			continue
		}
		if !journal.replica_covers(&rr.rep, 0, n) || !_arm_verified(rr, 0, n) {
			_arm_want(r, rr, 0, n)
			wait = true
			continue
		}
		rd: journal.Reader
		journal.replica_reader(&rr.rep, &rd, context.temp_allocator)
		_rst_scan(&rd, n, rr.id, false, rm, e, keys, &best, &best_n)
		journal.reader_close(&rd)
	}
	pbuf: prim.Path_Buf = ---
	if oid, path, ok := _rst_own(r, rm, &pbuf); ok {
		rd: journal.Reader
		if journal.reader_open(&rd, r.vfs, path, context.temp_allocator) == .None {
			_rst_scan(&rd, journal.reader_end(&rd), oid, true, rm, e, keys, &best, &best_n)
			journal.reader_close(&rd)
		}
	}
	if wait {
		return .Wait, {}
	}
	if best_n < 0 {
		return .None, _Src{zeroed = true}
	}
	return .Found, best
}

@(private)
_group_live :: proc(body: []u8, e: arc.Seal_Entry, x: journal.Range, keys: journal.Key_Provider) -> bool {
	g, perr := arc.group_parse(body, e.arc_off)
	if perr != .None {
		return false
	}
	raw, oerr := arc.group_open(&g, keys)
	if oerr != .None {
		return true
	}
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	cur: arc.Cursor
	arc.cursor_init(&cur, &g, raw)
	defer arc.cursor_destroy(&cur)
	en: arc.Entry
	for {
		more, cerr := arc.cursor_next(&cur, &en)
		if cerr != .None {
			return true
		}
		if !more {
			return false
		}
		hi := en.off + journal.record_size(en.len)
		if (en.kind == .Body || en.kind == .Zipped) && en.off < x.to && x.from < hi {
			return true
		}
	}
}

@(private)
_arc_wipe :: proc(r: ^Replicator, rm: ^Remote, keys: journal.Key_Provider) {
	a := rm.arc
	arm := a.arm
	target := cast([16]u8)rm.device
	for x in a.wipes {
		for e in a.index {
			if !(e.first < x.to && x.from < e.end) {
				continue
			}
			hi := e.arc_off + e.arc_len
			if journal.replica_covers(&arm.rep, e.arc_off, hi) {
				if body, _, rerr := _rep_record(&arm.rep, e.arc_off); rerr == .None && _group_live(body, e, x, keys) {
					journal.replica_redact(&arm.rep, e.arc_off, hi, {})
				}
			}
			for rr in a.rsts {
				n := journal.replica_length(&rr.rep)
				pos := i64(0)
				for pos < n {
					if !journal.replica_covers(&rr.rep, pos, pos + journal.HEADER) {
						break
					}
					body, nxt, rerr := _rep_record(&rr.rep, pos)
					if rerr == .Redacted {
						pos = nxt
						continue
					}
					if rerr != .None || nxt <= pos {
						break
					}
					rs: arc.Restore
					if len(body) > 0 && body[0] == arc.RESTORE_KIND && arc.restore_parse(body, &rs) == .None && rs.target == target && rs.arc_off == e.arc_off && _group_live(rs.group, e, x, keys) {
						journal.replica_redact(&rr.rep, pos, nxt, {})
					}
					pos = nxt
				}
			}
		}
	}
	clear(&a.wipes)
}

@(private)
_arc_zero_src :: proc(r: ^Replicator, rm: ^Remote, src: _Src) {
	a := rm.arc
	if r.phase == .Ready {
		client_redact(&r.client, src.id, src.off, src.off + src.size)
	}
	if src.id == a.arm.id {
		if journal.replica_covers(&a.arm.rep, src.off, src.off + src.size) {
			journal.replica_redact(&a.arm.rep, src.off, src.off + src.size, {})
		}
		return
	}
	if src.own {
		pbuf: prim.Path_Buf = ---
		oid, path, ok := _rst_own(r, rm, &pbuf)
		if !ok || oid != src.id {
			return
		}
		chain := journal.Chain{seed = chain_seed(oid), signer = r.cfg.signer}
		j: journal.Journal
		if journal.journal_open(&j, r.vfs, path, journal.Options{chain = &chain}, context.temp_allocator) == .None {
			journal.journal_redact(&j, src.off, src.off + src.size)
			journal.journal_close(&j)
		}
		return
	}
	for rr in a.rsts {
		if rr.id == src.id && journal.replica_covers(&rr.rep, src.off, src.off + src.size) {
			journal.replica_redact(&rr.rep, src.off, src.off + src.size, {})
		}
	}
}

@(private)
_arc_redacts :: proc(r: ^Replicator, rm: ^Remote, keys: journal.Key_Provider, sealed: bool) {
	a := rm.arc
	for i := 0; i < len(a.pend); {
		p := a.pend[i]
		floor: i64 = -1
		if l, ok := r.locals[p.local]; ok {
			floor = l.floor
		} else if _, _, f, fok := _floor_meta_read(r, p.local); fok {
			floor = f
		}
		if floor < p.end {
			i += 1
			continue
		}
		_arc_zero_src(r, rm, _Src{id = p.src, off = p.src_off, size = p.src_len, own = stream_device(p.src) == r.cfg.self})
		ordered_remove(&a.pend, i)
	}
	for i := 0; i < len(a.redacts); {
		x := a.redacts[i]
		wait := false
		for e in a.index {
			if e.first < x.to && x.from < e.end && _arc_restore_one(r, rm, e, x, keys, sealed) == .Wait {
				wait = true
			}
		}
		if wait {
			i += 1
			continue
		}
		if r.phase == .Ready {
			client_redact(&r.client, rm.id, x.from, x.to)
		}
		ordered_remove(&a.redacts, i)
	}
}

@(private)
_arc_restore_one :: proc(r: ^Replicator, rm: ^Remote, e: arc.Seal_Entry, x: journal.Range, keys: journal.Key_Provider, sealed: bool) -> _Res {
	a := rm.arc
	for p in a.pend {
		if p.arc_off == e.arc_off {
			return .Wait
		}
	}
	res, src := _arc_resolve(r, rm, e, keys)
	if res != .Found {
		return res
	}
	g, perr := arc.group_parse(src.body, e.arc_off)
	if perr != .None || g.first != e.first || g.end != e.end {
		return .None
	}
	raw, oerr := arc.group_open(&g, keys)
	if oerr != .None {
		_arc_zero_src(r, rm, src)
		return .None
	}
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	chain := journal.Chain{keys = keys}
	b: arc.Builder
	arc.builder_init(&b, g.first, g.head_before, context.temp_allocator)
	defer arc.builder_destroy(&b)
	exclude := make([dynamic]journal.Range, context.temp_allocator)
	cur: arc.Cursor
	arc.cursor_init(&cur, &g, raw)
	defer arc.cursor_destroy(&cur)
	live := false
	broken := false
	en: arc.Entry
	for !broken {
		more, cerr := arc.cursor_next(&cur, &en)
		if cerr != .None {
			broken = true
			break
		}
		if !more {
			break
		}
		hi := en.off + journal.record_size(en.len)
		switch en.kind {
		case .Sig:
			broken = arc.builder_hole(&b, en.off, en.len, true, {}) != .None
		case .Gone, .Gone_Head:
			if en.off < x.to && x.from < hi {
				live = true
				append(&exclude, journal.Range{en.off, hi})
			}
			broken = arc.builder_gone_copy(&b, en.off, en.len, en.head, en.kind == .Gone_Head) != .None
		case .Redacted:
			append(&exclude, journal.Range{en.off, hi})
			broken = arc.builder_hole(&b, en.off, en.len, false, en.commit) != .None
		case .Body, .Zipped:
			cm, cerr2 := journal.commitment(&chain, en.body, en.off)
			if cerr2 != .None {
				broken = true
				break
			}
			if en.off < x.to && x.from < hi {
				live = true
				append(&exclude, journal.Range{en.off, hi})
				broken = arc.builder_hole(&b, en.off, en.len, false, cm) != .None
			} else {
				broken = arc.builder_add(&b, en.off, en.body, false, false, cm) != .None
			}
		}
	}
	if !broken && !live {
		return .Found
	}
	if broken || b.head != g.head_after || b.pos != g.end {
		_arc_zero_src(r, rm, src)
		return .None
	}
	for h in g.holes {
		append(&exclude, journal.Range{max(h.from << g.shift, g.first), min(h.to << g.shift, g.end)})
	}
	salt: [arc.SALT]u8
	prim.random_fill(r.cfg.random, salt[:])
	level := r.cfg.archive_level if r.cfg.archive_level > 0 else arc.LEVEL
	out := make([dynamic]u8, context.temp_allocator)
	if arc.builder_finish(&b, &out, g.mode, keys, g.shift, salt, level, exclude[:]) != .None {
		_arc_zero_src(r, rm, src)
		return .None
	}
	pbuf: prim.Path_Buf = ---
	rid, path, ok := _rst_own(r, rm, &pbuf)
	if !ok {
		return .None
	}
	chain2 := journal.Chain{seed = chain_seed(rid), signer = r.cfg.signer}
	if !_arc_dir(r) {
		return .Wait
	}
	j: journal.Journal
	if journal.journal_open(&j, r.vfs, path, journal.Options{chain = &chain2}, context.temp_allocator) != .None {
		return .Wait
	}
	defer journal.journal_close(&j)
	rs := arc.Restore{target = cast([16]u8)rm.device, arc_off = e.arc_off, group = out[:]}
	body := make([dynamic]u8, context.temp_allocator)
	if arc.restore_encode(&body, &rs) != .None {
		return .None
	}
	if _, aerr := journal.journal_append(&j, body[:]); aerr != .None || journal.journal_commit(&j) != .None {
		return .Wait
	}
	end := journal.journal_durable_len(&j)
	r.restores_written += 1
	append(&a.pend, _Rst_Pend{arc_off = e.arc_off, local = rid, end = end, src = src.id, src_off = src.off, src_len = src.size})
	name, _ := _rst_name(rm)
	al, have := r.locals[rid]
	if !have {
		nl, lerr := _local_open(r, &rm.scope, name, rm.epoch, rid, path)
		if lerr != .None {
			return .Wait
		}
		al = nl
	}
	al.plain = true
	al.rst_on = true
	al.rst_of = rm.id
	al.durable = max(al.durable, end)
	al.blocked = false
	_local_pump(r, al)
	return .Wait
}

@(private)
_arc_invalidate :: proc(r: ^Replicator, arm: ^Remote) {
	if up := arm.arc_of; up != nil && up.arc != nil {
		up.arc.loaded = false
	}
}

@(private)
_arc_own_open :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, id: Stream_Id) -> (^Local, bool) {
	if !_arc_on(r) {
		return nil, false
	}
	_, path, _, ok := _floor_meta_read(r, id)
	if !ok {
		return nil, false
	}
	l, err := _local_open(r, scope, name, epoch, id, path)
	if err != .None {
		return nil, false
	}
	l.archive = l.arc_sealed > 0
	return l, true
}

@(private)
_arc_redact_own :: proc(r: ^Replicator, l: ^Local, from, to: i64) {
	if !l.archive || to <= from || from >= l.arc_sealed || r.cfg.signer.sign == nil {
		return
	}
	name, nerr := arc.stream_name(l.name)
	if nerr != .None {
		return
	}
	scope := l.scope
	aid := stream_id(&scope, r.cfg.self, name, l.epoch)
	pbuf: prim.Path_Buf = ---
	path := _arc_path(r, &pbuf, aid)
	chain := journal.Chain {
		seed   = chain_seed(aid),
		signer = r.cfg.signer,
	}
	j: journal.Journal
	if journal.journal_open(&j, r.vfs, path, journal.Options{chain = &chain}, context.temp_allocator) != .None {
		return
	}
	defer journal.journal_close(&j)
	seal: arc.Seal
	seal.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
	full := make([dynamic]arc.Seal_Entry, context.temp_allocator)
	seal_at, _, have, lerr := _arc_last_seal(&j, &seal, &full)
	if lerr != .None || !have {
		return
	}
	index := make([dynamic]arc.Seal_Entry, context.temp_allocator)
	for e in full {
		append(&index, e)
	}
	if !seal.full {
		arc.seal_merge(&index, seal.entries[:])
	}
	rd: journal.Reader
	journal.journal_reader(&j, &rd, context.temp_allocator)
	fresh := make([dynamic]arc.Seal_Entry, context.temp_allocator)
	old := make([dynamic]journal.Range, context.temp_allocator)
	for e in index {
		if !(e.first < to && from < e.end) {
			continue
		}
		body, _, rerr := journal.record_at(&rd, e.arc_off)
		if rerr != .None {
			continue
		}
		g, perr := arc.group_parse(body, e.arc_off)
		if perr != .None {
			continue
		}
		head := g.head_before
		built, berr := _arc_build_keyed(r, l, &j, e.first, head, e.end)
		if berr != .None || built.first != e.first || built.end != e.end || built.head != g.head_after {
			continue
		}
		append(&fresh, built.entry)
		append(&old, journal.Range{e.arc_off, e.arc_off + e.arc_len})
	}
	journal.reader_close(&rd)
	if len(fresh) == 0 {
		return
	}
	delta := make([dynamic]arc.Seal_Entry, context.temp_allocator)
	if !seal.full {
		for e in seal.entries {
			append(&delta, e)
		}
	}
	arc.seal_merge(&delta, fresh[:])
	ns: arc.Seal
	ns.base = seal.base
	ns.head = seal.head
	if len(full) == 0 || len(delta) * 2 >= len(full) {
		arc.seal_merge(&full, delta[:])
		ns.full = true
		ns.entries = full
	} else {
		ns.full_at = seal.full_at if !seal.full else seal_at
		ns.entries = delta
	}
	sb := make([dynamic]u8, context.temp_allocator)
	if arc.seal_encode(&sb, &ns) != .None {
		return
	}
	if _, aerr := journal.journal_append(&j, sb[:]); aerr != .None || journal.journal_commit(&j) != .None {
		return
	}
	for o in old {
		journal.journal_redact(&j, o.from, o.to)
		if r.phase == .Ready {
			client_redact(&r.client, aid, o.from, o.to)
		}
	}
	al, ok := r.locals[aid]
	if !ok {
		nl, oerr := _local_open(r, &scope, name, l.epoch, aid, path)
		if oerr != .None {
			return
		}
		al = nl
	}
	al.plain = true
	al.arc_child = true
	al.trim_for = l.id
	al.durable = max(al.durable, journal.journal_durable_len(&j))
	al.blocked = false
	_local_pump(r, al)
}
