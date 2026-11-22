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
}

@(private)
_Span_Rec :: struct {
	off:  i64,
	size: i64,
	rdx:  bool,
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
		group, gerr := _arc_build(r, l, &j, sealed, head)
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
	if client_trim(&r.client, al.trim_for, al.trim_base) == .None {
		al.trim_sent = al.trim_base
	}
}

@(private)
_arc_advanced :: proc(r: ^Replicator, l: ^Local) {
	if l.arc_child && l.floor >= l.trim_at {
		_arc_trim_send(r, l)
	}
	_arc_maybe_run(r, l)
}

@(private)
_arc_floor_save :: proc(r: ^Replicator, l: ^Local) {
	l.floor_seq += 1
	slot_write(r.vfs, l.floor_fd, Slot{seq = l.floor_seq, value = l.floor, start = min(l.arc_sealed, l.floor)})
	prim.datasync(r.vfs, l.floor_fd)
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
_arc_build :: proc(r: ^Replicator, l: ^Local, j: ^journal.Journal, from: i64, head: journal.Hash) -> (out: _Built, err: Error) {
	rd: journal.Reader
	if journal.reader_open(&rd, r.vfs, l.path, context.temp_allocator) != .None {
		return {}, .Io
	}
	defer journal.reader_close(&rd)
	limit := min(l.floor, journal.reader_end(&rd))
	b: arc.Builder
	arc.builder_init(&b, from, head, context.temp_allocator)
	defer arc.builder_destroy(&b)
	span := make([dynamic]_Span_Rec, context.temp_allocator)
	links := make([dynamic]journal.Link, context.temp_allocator)
	group_raw := r.cfg.archive_group if r.cfg.archive_group > 0 else arc.GROUP_RAW
	mode := arc.Mode.Plain if l.plain else arc.Mode.Sealed
	keys: journal.Key_Provider
	shift := u8(0)
	if !l.plain {
		if l.tree != nil {
			keys = keytree_provider(l.tree)
			shift = l.tree.shift
		} else {
			keys = static_provider(&l.key)
		}
	}
	pos := from
	span_start := from
	for pos < limit && arc.builder_raw(&b) < group_raw {
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
		if nxt >= limit {
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
			if s.rdx {
				zero := make([]u8, int(links[i].len), context.temp_allocator)
				if e := arc.builder_add(&b, s.off, zero, false, true, links[i].commit); e != .None {
					return {}, .Corrupt
				}
				continue
			}
			sb, _, serr := journal.record_at(&rd, s.off)
			if serr != .None {
				return {}, .Corrupt
			}
			if e := arc.builder_add(&b, s.off, sb, false, false, links[i].commit); e != .None {
				return {}, .Corrupt
			}
		}
		sigbody, _, serr := journal.record_at(&rd, pos)
		if serr != .None {
			return {}, .Corrupt
		}
		if e := arc.builder_add(&b, pos, sigbody, true, false, {}); e != .None {
			return {}, .Corrupt
		}
		clear(&span)
		pos = nxt
		span_start = nxt
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
		entry = arc.Seal_Entry{first = b.first, end = b.pos, arc_off = at, arc_len = journal.record_size(len(body))},
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
	a := rm.arc
	if a == nil {
		name, nerr := arc.stream_name(rm.name)
		if nerr != .None {
			return
		}
		arm, err := _remote_get(r, &rm.scope, rm.device, name, rm.epoch)
		if err != .None {
			return
		}
		na, aerr := new(Arc_Read, r.allocator)
		if aerr != nil {
			return
		}
		na.arm = arm
		na.index = make([dynamic]arc.Seal_Entry, r.allocator)
		na.wants = make([dynamic]journal.Range, r.allocator)
		arm.refs += 1
		arm.plain = true
		arm.arc_of = rm
		rm.arc = na
		a = na
	}
	for &w in a.wants {
		if w.from <= from && w.to >= to {
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
	delete(a.index)
	delete(a.wants)
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
	if a == nil || a.arm == nil || len(a.wants) == 0 || r.phase != .Ready || a.driving {
		return
	}
	a.driving = true
	defer a.driving = false
	arm := a.arm
	if !a.loaded {
		if !_arc_load(r, rm) {
			return
		}
	}
	keys, sealed, ok := _arc_keys(r, rm)
	if !ok {
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
			if !journal.replica_covers(&arm.rep, e.arc_off, e.arc_off + e.arc_len) || !_arm_verified(arm, e.arc_off, e.arc_off + e.arc_len) {
				_arm_want(r, arm, e.arc_off, e.arc_off + e.arc_len)
				done = false
				lo = e.end
				continue
			}
			if !_arc_apply(r, rm, e, keys, sealed) {
				_arc_broken(r, rm, e.first, e.end)
			}
			progressed = true
			lo = e.end
		}
		if w.to > a.base {
			_pull_range(r, rm, max(w.from, a.base), w.to)
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
		rm.keys_wait = true
		_emit(r, Repl_Event{kind = .Keys_Needed, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
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
	if arm.relay_len < 0 {
		_remote_want_tail(r, arm, TAIL_DEFAULT)
		return false
	}
	end := arm.relay_len
	if end <= 0 {
		_arc_broken(r, rm, 0, rm.base)
		clear(&a.wants)
		return false
	}
	rd: journal.Reader
	journal.replica_reader(&arm.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	pos := end
	seal: arc.Seal
	seal.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
	for pos > 0 {
		if !journal.replica_covers(&arm.rep, max(pos - TAIL_DEFAULT, 0), pos) || !_arm_verified(arm, max(pos - TAIL_DEFAULT, 0), pos) {
			if !journal.replica_covers(&arm.rep, max(pos - journal.TRAILER, 0), pos) {
				_arm_want(r, arm, max(pos - TAIL_DEFAULT, 0), pos)
				return false
			}
		}
		body, off, rerr := journal.record_before(&rd, pos)
		if rerr == .Missing {
			_arm_want(r, arm, max(rd.missing.from, pos - TAIL_DEFAULT, 0), pos)
			return false
		}
		if rerr == .Redacted {
			pos = off
			continue
		}
		if rerr != .None {
			_arc_broken(r, rm, 0, rm.base)
			clear(&a.wants)
			return false
		}
		if !_arm_verified(arm, off, pos) {
			_arm_want(r, arm, off, pos)
			return false
		}
		if len(body) > 0 && body[0] == arc.SEAL_KIND {
			if arc.seal_parse(body, &seal) != .None {
				_arc_broken(r, rm, 0, rm.base)
				clear(&a.wants)
				return false
			}
			a.seal_at = off
			break
		}
		pos = off
	}
	if pos <= 0 {
		_arc_broken(r, rm, 0, rm.base)
		clear(&a.wants)
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
			_arm_want(r, arm, seal.full_at, hi)
			return false
		}
		fs: arc.Seal
		fs.entries = make([dynamic]arc.Seal_Entry, context.temp_allocator)
		if ferr != .None || arc.seal_parse(fbody, &fs) != .None || !fs.full {
			_arc_broken(r, rm, 0, rm.base)
			clear(&a.wants)
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
	return true
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
_arc_apply :: proc(r: ^Replicator, rm: ^Remote, e: arc.Seal_Entry, keys: journal.Key_Provider, sealed: bool) -> bool {
	arm := rm.arc.arm
	rd: journal.Reader
	journal.replica_reader(&arm.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	body, nxt, rerr := journal.record_at(&rd, e.arc_off)
	if rerr != .None || nxt != e.arc_off + e.arc_len {
		return false
	}
	g, perr := arc.group_parse(body, e.arc_off)
	if perr != .None || g.first != e.first || g.end != e.end {
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
	if _stage_write(rm, g.first, out[:]) != .None {
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
