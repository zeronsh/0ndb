package engine

import "core:strconv"
import "../journal"
import "../prim"
import osync "../sync"

@(private)
NOTICES_DIR :: "notices"
@(private)
NOTICES_ROTATE_DEFAULT :: i64(64 << 10)
@(private)
NOTICES_SEARCH :: u64(64)

@(private)
Notice_Peer :: struct {
	id:    osync.Identity,
	epoch: u64,
	seen:  i64,
	known: bool,
	bad:   bool,
}

@(private)
Notice_Ev :: struct {
	kind:   osync.Repl_Event_Kind,
	device: prim.Id,
	epoch:  u64,
	length: i64,
	stream: osync.Stream_Id,
}

Notices :: struct {
	on:        bool,
	tried:     bool,
	list:      bool,
	epoch:     u64,
	stale:     bool,
	scope:     osync.Scope,
	peers:     map[prim.Id]Notice_Peer,
	removed:   map[prim.Id]bool,
	joins:     map[[32]u8]bool,
	follows:   [dynamic]u64,
	queue:     [dynamic]Notice_Ev,
	dirty:     map[prim.Id]bool,
	dirty_all: bool,
}

@(private)
_join_key :: proc(target: prim.Id, space: prim.Id) -> (k: [32]u8) {
	t, s := target, space
	copy(k[:16], t[:])
	copy(k[16:], s[:])
	return
}

@(private)
_id_lt :: proc(a, b: prim.Id) -> bool {
	x, y := a, b
	return string(x[:]) < string(y[:])
}

@(private)
_notices_dir :: proc(e: ^Engine) -> (string, Error) {
	ns := osync.account_namespace(e.account.sign)
	h := prim.id_hex(prim.Id(ns))
	return _join(context.temp_allocator, e.pack_root, NOTICES_DIR, string(h[:]))
}

@(private)
_notices_path :: proc(e: ^Engine, epoch: u64) -> (path: string, err: Error) {
	dir := _notices_dir(e) or_return
	buf: [24]u8
	return _join(context.temp_allocator, dir, strconv.write_uint(buf[:], epoch, 10))
}

@(private)
_notices_rotate_at :: proc(e: ^Engine) -> i64 {
	return e.cfg.notices_rotate if e.cfg.notices_rotate > 0 else NOTICES_ROTATE_DEFAULT
}

@(private)
_notices_chain :: proc(e: ^Engine, epoch: u64, chain: ^journal.Chain) {
	id := osync.stream_id(&e.notices.scope, osync.Device_Id(e.self), osync.NOTICES_STREAM, epoch)
	chain^ = journal.Chain {
		seed   = osync.chain_seed(id),
		signer = osync.keyring_signer(&e.keyring),
	}
}

@(private)
_notices_epoch_load :: proc(e: ^Engine) -> u64 {
	dir, err := _notices_dir(e)
	if err != .None {
		return 0
	}
	path, perr := _join(context.temp_allocator, dir, "epoch")
	if perr != .None {
		return 0
	}
	data, rerr := prim.read_file(e.vfs, path, context.temp_allocator)
	if rerr != .None || len(data) != 8 {
		return 0
	}
	return prim.get_u64le(data)
}

@(private)
_notices_epoch_store :: proc(e: ^Engine, epoch: u64) -> Error {
	dir := _notices_dir(e) or_return
	path := _join(context.temp_allocator, dir, "epoch") or_return
	b: [8]u8
	prim.put_u64le(b[:], epoch)
	return _perr(prim.replace_atomic(e.vfs, path, b[:]))
}

@(private)
_notices_start :: proc(e: ^Engine) {
	n := &e.notices
	_notices_stop(e)
	if !e.account.have || e.approvals.rv == nil {
		return
	}
	n.on = true
	n.scope = osync.notices_scope(e.account.sign)
	n.peers = make(map[prim.Id]Notice_Peer, e.allocator)
	n.removed = make(map[prim.Id]bool, e.allocator)
	n.joins = make(map[[32]u8]bool, e.allocator)
	n.follows = make([dynamic]u64, e.allocator)
	n.queue = make([dynamic]Notice_Ev, e.allocator)
	n.dirty = make(map[prim.Id]bool, e.allocator)
	n.dirty_all = true
	dir, derr := _notices_dir(e)
	if derr != .None || prim.mkdir_all(e.vfs, dir, 0o700) != .None {
		return
	}
	n.epoch = _notices_epoch_load(e)
	if n.epoch > 0 {
		if old, err := _notices_path(e, n.epoch - 1); err == .None && prim.exists(e.vfs, old) {
			n.stale = true
		}
	}
	path, perr := _notices_path(e, n.epoch)
	if perr != .None {
		return
	}
	chain: journal.Chain
	_notices_chain(e, n.epoch, &chain)
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, path, journal.Options{chain = &chain}, context.temp_allocator) != .None {
		return
	}
	if journal.journal_len(&j) == 0 {
		hello := make([dynamic]u8, context.temp_allocator)
		if osync.notice_hello_encode(e.identity, e.account.cert, &hello) == .None {
			journal.journal_append(&j, hello[:])
			journal.journal_commit(&j)
		}
	}
	durable := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	_notices_own_scan(e, path)
	osync.replicator_publish(&e.approvals.rv.repl, &n.scope, osync.NOTICES_STREAM, n.epoch, path, durable)
	_notices_follow(e)
}

@(private)
_notices_stop :: proc(e: ^Engine) {
	n := &e.notices
	if !n.on {
		return
	}
	delete(n.peers)
	delete(n.removed)
	delete(n.joins)
	delete(n.follows)
	delete(n.queue)
	delete(n.dirty)
	tried := n.tried
	n^ = {}
	n.tried = tried
}

@(private)
_notices_own_scan :: proc(e: ^Engine, path: string) {
	rd: journal.Reader
	if journal.reader_open(&rd, e.vfs, path, context.temp_allocator) != .None {
		return
	}
	defer journal.reader_close(&rd)
	pos := i64(0)
	for {
		body, next, err := journal.record_at(&rd, pos)
		if err != .None {
			break
		}
		pos = next
		if journal.is_sig(body) {
			continue
		}
		nt: osync.Notice
		if osync.notice_decode(body, &nt) != .None {
			continue
		}
		switch nt.kind {
		case osync.NOTICE_JOIN:
			e.notices.joins[_join_key(prim.Id(nt.target), prim.Id(nt.space))] = true
		case osync.NOTICE_REMOVED:
			e.notices.removed[prim.Id(nt.device)] = true
		}
	}
}

@(private)
_notices_on_event :: proc(e: ^Engine, ev: ^osync.Repl_Event) -> bool {
	if !e.notices.on {
		return false
	}
	#partial switch ev.kind {
	case .Segment_Seen, .Grew, .Present, .Epoch_Seen, .Uploaded:
		if ev.name != osync.NOTICES_STREAM {
			return false
		}
	case .Listed:
	case:
		return false
	}
	append(&e.notices.queue, Notice_Ev{kind = ev.kind, device = prim.Id(ev.device), epoch = ev.epoch, length = ev.length, stream = ev.stream})
	return true
}

@(private)
_notices_step :: proc(e: ^Engine) {
	n := &e.notices
	if !n.on {
		if e.account.have && e.approvals.rv == nil && !n.tried {
			n.tried = true
			_rv_open(e, e.account.sign, e.account.relay, e.account.relay_public, false)
		}
		return
	}
	sp := e.approvals.rv
	if sp == nil {
		return
	}
	if n.list && sp.connected {
		n.list = false
		osync.replicator_list(&sp.repl)
	}
	if len(n.queue) > 0 {
		q := n.queue
		n.queue = make([dynamic]Notice_Ev, e.allocator)
		defer delete(q)
		for &x in q {
			_notices_handle(e, &x)
		}
		_notices_follow(e)
	}
	if (n.dirty_all || len(n.dirty) > 0) && sp.connected && osync.replicator_caught_up(&sp.repl) {
		_notices_reconcile(e)
	}
}

@(private)
_notices_connected :: proc(e: ^Engine) {
	if e.notices.on {
		e.notices.list = true
		e.notices.dirty_all = true
	}
}

@(private)
_notices_handle :: proc(e: ^Engine, x: ^Notice_Ev) {
	n := &e.notices
	sp := e.approvals.rv
	if x.kind == .Uploaded {
		if x.device == e.self || x.device == {} {
			_notices_uploaded(e, x.epoch)
		}
		return
	}
	if x.device == e.self || x.device in n.removed {
		return
	}
	epoch := x.epoch
	if x.kind == .Listed {
		base := u64(0)
		if p, ok := n.peers[x.device]; ok {
			base = p.epoch
		}
		found := false
		for k in base ..< base + NOTICES_SEARCH {
			if osync.stream_id(&n.scope, osync.Device_Id(x.device), osync.NOTICES_STREAM, k) == x.stream {
				epoch = k
				found = true
				break
			}
		}
		if !found {
			return
		}
	}
	p, known := n.peers[x.device]
	if known && epoch < p.epoch {
		return
	}
	if !known {
		p = Notice_Peer{epoch = epoch}
	} else if epoch > p.epoch {
		osync.replicator_unfollow(&sp.repl, &n.scope, osync.Device_Id(x.device), osync.NOTICES_STREAM, p.epoch)
		p.epoch = epoch
		p.seen = 0
		p.bad = false
	}
	n.peers[x.device] = p
	osync.replicator_follow(&sp.repl, &n.scope, osync.Device_Id(x.device), osync.NOTICES_STREAM, epoch, true)
	_notices_read(e, x.device)
}

@(private)
_notices_verify :: proc(data: rawptr, msg: []u8, sig: []u8) -> bool {
	p := (^Notice_Peer)(data)
	return osync.signature_verify(p.id.sign, msg, sig)
}

@(private)
_notices_read :: proc(e: ^Engine, device: prim.Id) {
	n := &e.notices
	sp := e.approvals.rv
	p, ok := n.peers[device]
	if !ok || p.bad {
		return
	}
	dev := osync.Device_Id(device)
	rep, aerr := osync.replicator_acquire(&sp.repl, &n.scope, dev, osync.NOTICES_STREAM, p.epoch)
	if aerr != .None {
		return
	}
	defer osync.replicator_release(&sp.repl, &n.scope, dev, osync.NOTICES_STREAM, p.epoch)
	end := journal.replica_length(rep)
	if p.seen >= end {
		return
	}
	if p.seen == 0 {
		rd: journal.Reader
		journal.replica_reader(rep, &rd, context.temp_allocator)
		body, _, err := journal.record_at(&rd, 0)
		journal.reader_close(&rd)
		if err == .Missing {
			osync.replicator_want(&sp.repl, &n.scope, dev, osync.NOTICES_STREAM, p.epoch, []journal.Range{{0, end}})
			return
		}
		if err != .None {
			return
		}
		h: osync.Notice
		if osync.notice_decode(body, &h) != .None || h.kind != osync.NOTICE_HELLO || prim.Id(osync.device_id(h.sign)) != device || !osync.device_cert_verify(e.account.sign, h.sign, h.cert[:]) || (p.known && h.sign != p.id.sign) {
			p.bad = true
			n.peers[device] = p
			return
		}
		p.id = osync.identity_of(h.sign, h.box)
	}
	chain := journal.Chain {
		seed     = osync.chain_seed(osync.stream_id(&n.scope, dev, osync.NOTICES_STREAM, p.epoch)),
		verifier = journal.Verifier{data = &p, verify = _notices_verify},
	}
	rd: journal.Reader
	journal.replica_reader(rep, &rd, context.temp_allocator)
	journal.reader_set_chain(&rd, &chain)
	defer journal.reader_close(&rd)
	pos := p.seen
	for pos < end {
		body, next, err := journal.record_at(&rd, pos)
		if err == .Missing {
			osync.replicator_want(&sp.repl, &n.scope, dev, osync.NOTICES_STREAM, p.epoch, []journal.Range{{pos, end}})
			break
		}
		if err == .Unverified || err == .Redacted {
			break
		}
		if err != .None {
			p.bad = true
			break
		}
		at := pos
		pos = next
		if journal.is_sig(body) {
			continue
		}
		nt: osync.Notice
		if osync.notice_decode(body, &nt) != .None {
			continue
		}
		switch nt.kind {
		case osync.NOTICE_HELLO:
			if at == 0 && !p.known {
				p.known = true
				n.dirty_all = true
			}
		case osync.NOTICE_JOIN:
			if !p.known {
				continue
			}
			n.joins[_join_key(prim.Id(nt.target), prim.Id(nt.space))] = true
			if prim.Id(nt.target) == e.self {
				_notices_adopt(e, &nt)
			}
		case osync.NOTICE_REMOVED:
			if p.known {
				_notices_removed(e, prim.Id(nt.device))
			}
		}
	}
	if device in n.removed {
		return
	}
	p.seen = pos
	n.peers[device] = p
}

@(private)
_notices_adopt :: proc(e: ^Engine, nt: ^osync.Notice) {
	sid := prim.Id(nt.space)
	if space_left(e, sid) {
		return
	}
	if sp, ok := e.spaces[sid]; ok && !sp.keyless && !sp.refused {
		return
	}
	j: osync.Notice_Join
	if osync.notice_join_open(nt, &e.keyring, &j, context.temp_allocator) != .None {
		return
	}
	if _, err := space_join_enrollment(e, sid, j.proof, j.name, j.relay, j.relay_public); err != .None {
		return
	}
	space_open(e, sid)
}

@(private)
_notices_removed :: proc(e: ^Engine, device: prim.Id) {
	n := &e.notices
	if device == e.self || device in n.removed {
		return
	}
	n.removed[device] = true
	delete_key(&n.peers, device)
	n.dirty_all = true
}

@(private)
_notices_follow :: proc(e: ^Engine) {
	n := &e.notices
	sp := e.approvals.rv
	if sp == nil {
		return
	}
	want := make([dynamic]u64, context.temp_allocator)
	add :: proc(want: ^[dynamic]u64, k: u64) {
		for x in want {
			if x == k {
				return
			}
		}
		append(want, k)
	}
	add(&want, 0)
	add(&want, 1)
	for _, p in n.peers {
		add(&want, p.epoch)
		add(&want, p.epoch + 1)
	}
	for i := 0; i < len(n.follows); {
		k := n.follows[i]
		keep := false
		for x in want {
			if x == k {
				keep = true
			}
		}
		if keep {
			i += 1
			continue
		}
		osync.replicator_unfollow_segments(&sp.repl, &n.scope, osync.NOTICES_STREAM, k)
		unordered_remove(&n.follows, i)
	}
	for k in want {
		have := false
		for x in n.follows {
			if x == k {
				have = true
			}
		}
		if !have {
			osync.replicator_follow_segments(&sp.repl, &n.scope, osync.NOTICES_STREAM, k, true)
			append(&n.follows, k)
		}
	}
}

@(private)
_notices_append :: proc(e: ^Engine, body: []u8) -> Error {
	n := &e.notices
	if !n.on {
		return .Offline
	}
	path := _notices_path(e, n.epoch) or_return
	if st, err := prim.stat(e.vfs, path); err == .None && st.size + i64(len(body)) > _notices_rotate_at(e) {
		_notices_rotate(e, path)
		path = _notices_path(e, n.epoch) or_return
	}
	chain: journal.Chain
	_notices_chain(e, n.epoch, &chain)
	j: journal.Journal
	_jerr(journal.journal_open(&j, e.vfs, path, journal.Options{chain = &chain}, context.temp_allocator)) or_return
	if _, aerr := journal.journal_append(&j, body); aerr != .None {
		journal.journal_close(&j)
		return _jerr(aerr)
	}
	cerr := journal.journal_commit(&j)
	durable := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	_jerr(cerr) or_return
	osync.replicator_publish(&e.approvals.rv.repl, &n.scope, osync.NOTICES_STREAM, n.epoch, path, durable)
	return .None
}

@(private)
_notices_outstanding :: proc(e: ^Engine, body: []u8) -> bool {
	nt: osync.Notice
	if osync.notice_decode(body, &nt) != .None {
		return false
	}
	switch nt.kind {
	case osync.NOTICE_REMOVED:
		return true
	case osync.NOTICE_JOIN:
		target := prim.Id(nt.target)
		if target in e.notices.removed {
			return false
		}
		sp, ok := e.spaces[prim.Id(nt.space)]
		if !ok || sp.keyless {
			return false
		}
		m: osync.Membership
		if _members_load(e, sp, &m) != .None {
			return true
		}
		defer osync.membership_destroy(&m)
		if osync.membership_resolve(&m) != .None {
			return true
		}
		for &x in m.roster.members {
			if prim.Id(x.device) != target {
				continue
			}
			if x.removed {
				return false
			}
			for &r in m.records {
				if r.author == x.sign {
					return false
				}
			}
		}
		return true
	}
	return false
}

@(private)
_notices_rotate :: proc(e: ^Engine, path: string) {
	n := &e.notices
	keep := make([dynamic][]u8, context.temp_allocator)
	total := i64(0)
	{
		rd: journal.Reader
		if journal.reader_open(&rd, e.vfs, path, context.temp_allocator) != .None {
			return
		}
		defer journal.reader_close(&rd)
		pos := i64(0)
		for {
			body, next, err := journal.record_at(&rd, pos)
			if err != .None {
				break
			}
			pos = next
			if journal.is_sig(body) || !_notices_outstanding(e, body) {
				continue
			}
			cp := make([]u8, len(body), context.temp_allocator)
			copy(cp, body)
			append(&keep, cp)
			total += i64(len(cp))
		}
	}
	if total * 2 >= _notices_rotate_at(e) {
		return
	}
	next := n.epoch + 1
	npath, perr := _notices_path(e, next)
	if perr != .None {
		return
	}
	chain: journal.Chain
	_notices_chain(e, next, &chain)
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, npath, journal.Options{chain = &chain}, context.temp_allocator) != .None {
		return
	}
	hello := make([dynamic]u8, context.temp_allocator)
	osync.notice_hello_encode(e.identity, e.account.cert, &hello)
	journal.journal_append(&j, hello[:])
	for b in keep {
		journal.journal_append(&j, b)
	}
	cerr := journal.journal_commit(&j)
	durable := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	if cerr != .None || _notices_epoch_store(e, next) != .None {
		return
	}
	clear(&n.joins)
	n.epoch = next
	n.stale = true
	_notices_own_scan(e, npath)
	osync.replicator_publish(&e.approvals.rv.repl, &n.scope, osync.NOTICES_STREAM, next, npath, durable)
}

@(private)
_notices_uploaded :: proc(e: ^Engine, epoch: u64) {
	n := &e.notices
	if !n.stale || epoch != n.epoch || n.epoch == 0 {
		return
	}
	old := n.epoch - 1
	if osync.replicator_drop(&e.approvals.rv.repl, &n.scope, osync.NOTICES_STREAM, old) != .None {
		return
	}
	n.stale = false
	if path, err := _notices_path(e, old); err == .None {
		prim.remove(e.vfs, path)
	}
}

@(private)
_notices_space_changed :: proc(e: ^Engine, space: prim.Id) {
	if e.notices.on {
		e.notices.dirty[space] = true
	}
}

@(private)
_notices_device_removed :: proc(e: ^Engine, device: prim.Id) {
	n := &e.notices
	if !n.on || device in n.removed {
		return
	}
	body := make([dynamic]u8, context.temp_allocator)
	if osync.notice_removed_encode(osync.Device_Id(device), &body) != .None {
		return
	}
	if _notices_append(e, body[:]) == .None {
		n.removed[device] = true
		delete_key(&n.peers, device)
		n.dirty_all = true
	}
}

@(private)
_notices_reconcile :: proc(e: ^Engine) {
	n := &e.notices
	all := n.dirty_all
	n.dirty_all = false
	dirty := n.dirty
	n.dirty = make(map[prim.Id]bool, e.allocator)
	defer delete(dirty)
	peers := make([dynamic]osync.Identity, context.temp_allocator)
	for id in _sorted_keys(n.peers) {
		p := n.peers[id]
		if p.known && !p.bad {
			append(&peers, p.id)
		}
	}
	for id in _sorted_keys(e.spaces) {
		if !all && !(id in dirty) {
			continue
		}
		sp := e.spaces[id]
		if sp.keyless || sp.mem.revoked || sp.mem.removed {
			continue
		}
		_notices_reconcile_space(e, sp, peers[:])
	}
}

@(private)
_notices_reconcile_space :: proc(e: ^Engine, sp: ^Space, peers: []osync.Identity) {
	n := &e.notices
	if space_left(e, sp.id) {
		return
	}
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return
	}
	if a := osync.roster_find(&m.roster, e.account.sign); a < 0 || m.roster.members[a].removed {
		return
	}
	lowest: prim.Id
	have := false
	for &x in m.roster.members {
		d := prim.Id(x.device)
		if x.removed || x.role > .Admin {
			continue
		}
		helper := d == e.self
		if !helper {
			if p, ok := n.peers[d]; ok && p.known && !p.bad {
				helper = true
			}
		}
		if helper && (!have || _id_lt(d, lowest)) {
			lowest = d
			have = true
		}
	}
	if !have || lowest != e.self {
		return
	}
	for &x in m.roster.members {
		if !x.removed && prim.Id(x.device) in n.removed {
			member_remove(e, sp.id, prim.Id(x.device))
		}
	}
	for p in peers {
		key := _join_key(prim.Id(p.id), sp.id)
		if key in n.joins {
			continue
		}
		proof: []u8
		if idx := osync.roster_find(&m.roster, p.sign); idx >= 0 {
			x := &m.roster.members[idx]
			if x.removed {
				continue
			}
			joined := false
			for &r in m.records {
				if r.author == p.sign {
					joined = true
					break
				}
			}
			if joined {
				continue
			}
			ri, ok := m.ids[x.added]
			if !ok {
				continue
			}
			proof = m.records[ri].raw
		} else {
			raw, err := member_add(e, sp.id, p, .Device, .Admin, .Account, 0, context.temp_allocator)
			if err != .None {
				continue
			}
			proof = raw
		}
		body := make([dynamic]u8, context.temp_allocator)
		nj := osync.Notice_Join{name = sp.name, relay = sp.relay, relay_public = sp.relay_public, proof = proof}
		if osync.notice_join_encode(p, osync.Space_Id(sp.id), nj, &body, e.cfg.random) != .None {
			continue
		}
		if _notices_append(e, body[:]) == .None {
			n.joins[key] = true
		}
	}
}
