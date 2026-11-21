package web

import "base:runtime"
import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "../journal"
import omap "../map"
import "../obj"
import "../prim"
import osync "../sync"

TAIL_BYTES :: 64 * 1024
KEYS_TAIL :: 4096
CARD_TAIL :: 4096
MIN_FETCH :: 64 * 1024
PROBES :: 4
STAGE_MAX :: 1 << 20
CARD_STREAM :: "card"
STATUS_CLOSED :: 252

Remote_Kind :: enum u8 {
	Segment,
	Keys,
	Card,
}

Remote :: struct {
	id:        osync.Stream_Id,
	kind:      Remote_Kind,
	device:    prim.Id,
	epoch:     u64,
	rep:       journal.Replica,
	relay_len: i64,
	inflight:  [dynamic]journal.Range,
	follow:    bool,
	full:      bool,
	object:    ^Object,
	seg:       ^Seg,
}

Seg_Check :: struct {
	signer: osync.Identity,
}

Seg :: struct {
	device:     prim.Id,
	data:       ^Remote,
	keys:       ^Remote,
	next:       ^Remote,
	probing:    bool,
	epoch:      u64,
	tree:       osync.Key_Tree,
	tree_ok:    bool,
	jr:         journal.Reader,
	chain:      journal.Chain,
	check:      Seg_Check,
	in_view:    bool,
	cursor:     i64,
	cursor_ok:  bool,
}

Object :: struct {
	id:       prim.Id,
	kind:     obj.Kind,
	scope:    osync.Scope,
	name:     string,
	suffix:   [16]u8,
	segs:     [dynamic]^Seg,
	view:     obj.View,
	table:    omap.Table,
	table_ok: bool,
	catalog:  bool,
	rekeyed:  bool,
	changed:  bool,
}

Probe :: struct {
	seg:   ^Seg,
	epoch: u64,
}

Request :: struct {
	id:     u32,
	op:     Op,
	args:   []u8,
	object: ^Object,
	tries:  int,
}

Sub :: struct {
	id:     u32,
	object: ^Object,
}

Event_Kind :: enum u8 {
	Result    = 1,
	Deltas    = 2,
	Connected = 3,
	Closed    = 4,
	Info      = 5,
}

Session :: struct {
	allocator:   runtime.Allocator,
	mem:         Mem_Vfs,
	vfs:         prim.Vfs,
	device:      osync.Device,
	space:       osync.Space,
	shared:      bool,
	space_id:    prim.Id,
	catalog_id:  prim.Id,
	scope:       osync.Scope,
	share:       Share_Grant,
	relay_pub:   osync.Public_Key,
	relay_addr:  string,
	keyring:     osync.Keyring,
	space_creds: osync.Space_Credentials,
	cap_creds:   Cap_Credentials,
	creds:       osync.Credentials,
	link:        Link,
	ready:       bool,
	announced:   bool,
	feed_dirty:  bool,
	feed_cursor: i64,
	remotes:     map[osync.Stream_Id]^Remote,
	probes:      map[osync.Stream_Id]Probe,
	objects:     map[prim.Id]^Object,
	groups:      map[[16]u8]^Object,
	identities:  map[prim.Id]osync.Identity,
	cards:       map[prim.Id]^Remote,
	requests:    [dynamic]^Request,
	subs:        [dynamic]^Sub,
	next_id:     u32,
	events:      [dynamic]u8,
	rx:          ^Remote,
	rx_at:       i64,
	rx_start:    i64,
	stage:       [dynamic]u8,
	stage_at:    i64,
	bytes_in:    u64,
	err:         osync.Error,
}

session_init :: proc(s: ^Session, allocator := context.allocator) {
	s^ = {
		allocator = allocator,
	}
	mem_vfs_init(&s.mem, allocator)
	s.vfs = mem_vfs(&s.mem)
	link_init(&s.link, allocator)
	s.remotes = make(map[osync.Stream_Id]^Remote, allocator)
	s.probes = make(map[osync.Stream_Id]Probe, allocator)
	s.objects = make(map[prim.Id]^Object, allocator)
	s.groups = make(map[[16]u8]^Object, allocator)
	s.identities = make(map[prim.Id]osync.Identity, allocator)
	s.cards = make(map[prim.Id]^Remote, allocator)
	s.requests = make([dynamic]^Request, allocator)
	s.subs = make([dynamic]^Sub, allocator)
	s.events = make([dynamic]u8, allocator)
	s.stage = make([dynamic]u8, allocator)
	s.keyring = osync.Keyring{data = s, identity = _kr_identity, sign = _kr_sign}
}

session_destroy :: proc(s: ^Session) {
	for _, o in s.objects {
		_object_free(s, o)
	}
	for _, rm in s.remotes {
		_remote_free(s, rm)
	}
	for r in s.requests {
		delete(r.args, s.allocator)
		free(r, s.allocator)
	}
	for sb in s.subs {
		free(sb, s.allocator)
	}
	delete(s.remotes)
	delete(s.probes)
	delete(s.objects)
	delete(s.groups)
	delete(s.identities)
	delete(s.cards)
	delete(s.requests)
	delete(s.subs)
	delete(s.events)
	delete(s.stage)
	delete(s.relay_addr, s.allocator)
	link_destroy(&s.link)
	mem_vfs_destroy(&s.mem)
	osync.device_clear(&s.device)
	osync.space_clear(&s.space)
	osync.scope_clear(&s.scope)
	crypto.zero_explicit(&s.share, size_of(Share_Grant))
	crypto.zero_explicit(&s.cap_creds, size_of(Cap_Credentials))
	s^ = {}
}

session_device :: proc(s: ^Session, seed: []u8) -> osync.Error {
	raw: [32]u8
	defer crypto.zero_explicit(&raw, size_of(raw))
	if len(seed) == 32 {
		copy(raw[:], seed)
	} else if len(seed) == 0 {
		crypto.rand_bytes(raw[:])
	} else {
		return .Invalid
	}
	osync.device_clear(&s.device)
	s.device = osync.device_from_seed(raw[:]) or_return
	return .None
}

session_open_pairing :: proc(s: ^Session, code: string) -> osync.Error {
	p := osync.pairing_decode(code) or_return
	defer crypto.zero_explicit(&p, size_of(p))
	s.space = osync.space_from_secret(p.secret) or_return
	s.space_id = s.space.id
	s.catalog_id = catalog_id(s.space_id)
	s.scope = osync.space_scope(&s.space)
	s.relay_pub = p.relay_public
	s.relay_addr = _clone(osync.pairing_addr(&p), s.allocator)
	s.space_creds = osync.Space_Credentials{space = &s.space, keyring = s.keyring}
	s.creds = osync.space_credentials(&s.space_creds)
	c := _object_get(s, s.catalog_id, .Map)
	c.catalog = true
	return .None
}

catalog_id :: proc(space: prim.Id) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	sp := space
	blake2b.update(&ctx, transmute([]u8)string("0ndb-catalog-v1"))
	blake2b.update(&ctx, sp[:])
	blake2b.final(&ctx, id[:])
	id[6] = (id[6] & 0x0f) | 0x80
	return
}

seg_name :: proc(kind: obj.Kind, id: prim.Id, allocator := context.allocator) -> string {
	b := make([]u8, 1 + prim.ID_HEX_LEN, allocator)
	switch kind {
	case .Conversation:
		b[0] = 'c'
	case .Map:
		b[0] = 'm'
	case .Text:
		b[0] = 't'
	case .File_Tree:
		b[0] = 'f'
	}
	h := prim.id_hex(id)
	copy(b[1:], h[:])
	return string(b)
}

object_scope :: proc(s: ^Session, id: prim.Id) -> osync.Scope {
	if s.shared {
		if id == s.share.object {
			return osync.scope_make(s.share.key)
		}
		return {}
	}
	if id == s.catalog_id {
		return s.scope
	}
	x := id
	k := osync.object_content_key(&s.scope, x[:])
	sc := osync.scope_make(osync.Content_Key{key = k})
	crypto.zero_explicit(&k, size_of(k))
	return sc
}

session_connect :: proc(s: ^Session) -> osync.Error {
	s.ready = false
	s.announced = false
	_rx_reset(s)
	for _, rm in s.remotes {
		clear(&rm.inflight)
	}
	return link_begin(&s.link, &s.device, s.relay_pub)
}

session_down :: proc(s: ^Session) {
	link_reset(&s.link)
	s.ready = false
	s.announced = false
	_rx_reset(s)
	for _, rm in s.remotes {
		clear(&rm.inflight)
	}
	_event(s, .Closed, 0, 0, nil)
}

session_input :: proc(s: ^Session, data: []u8) -> osync.Error {
	s.bytes_in += u64(len(data))
	_, err := link_input(&s.link, data, &s.creds, _on_event, s)
	if err != .None {
		s.err = err
		session_down(s)
		return err
	}
	_settle(s)
	link_flush(&s.link)
	return .None
}

@(private)
_rx_reset :: proc(s: ^Session) {
	s.rx = nil
	clear(&s.stage)
}

@(private)
_kr_identity :: proc(data: rawptr) -> osync.Identity {
	s := (^Session)(data)
	return osync.device_identity(&s.device)
}

@(private)
_kr_sign :: proc(data: rawptr, msg: []u8, sig: ^[64]u8) -> osync.Error {
	s := (^Session)(data)
	ed25519.sign(&s.device.sign, msg, sig[:])
	return .None
}

@(private)
_clone :: proc(str: string, allocator: runtime.Allocator) -> string {
	if len(str) == 0 {
		return ""
	}
	b := make([]u8, len(str), allocator)
	copy(b, str)
	return string(b)
}

@(private)
_on_event :: proc(user: rawptr, ev: ^osync.Event) -> osync.Error {
	s := (^Session)(user)
	#partial switch ev.kind {
	case .Welcome:
		s.ready = true
		_event(s, .Connected, 0, 0, nil)
		_on_ready(s)
	case .Announce:
		s.announced = true
		for i in 0 ..< len(ev.entries) / osync.FEED_ENTRY {
			e := ev.entries[i * osync.FEED_ENTRY:][:osync.FEED_ENTRY]
			id: osync.Stream_Id
			copy(id[:], e[:32])
			length := prim.get_u64le(e[32:])
			if length == osync.FEED_DROPPED || length > u64(max(i64)) {
				continue
			}
			_seen(s, id, i64(length))
		}
		s.feed_cursor = max(s.feed_cursor, ev.length)
	case .Length, .Probed:
		_seen(s, osync.Stream_Id(ev.id), ev.length)
	case .Data:
		_on_data(s, ev)
	case .Refused:
		if rm, ok := s.remotes[osync.Stream_Id(ev.id)]; ok {
			clear(&rm.inflight)
			if rm.relay_len < 0 {
				rm.relay_len = 0
			}
			_mark(rm)
		}
	case .Error:
		return .Refused
	}
	return .None
}

@(private)
_mark :: proc(rm: ^Remote) {
	if rm.object != nil {
		rm.object.changed = true
	}
}

@(private)
_on_ready :: proc(s: ^Session) {
	_feed_subscribe(s, 0)
	for _, rm in s.remotes {
		_remote_resume(s, rm)
	}
	for _, o in s.objects {
		o.changed = true
		for sg in o.segs {
			sg.probing = false
			_seg_probe(s, o, sg, sg.next.epoch if sg.next != nil else sg.epoch)
		}
	}
}

@(private)
_feed_subscribe :: proc(s: ^Session, from: i64) {
	s.feed_dirty = false
	if !s.ready {
		return
	}
	pats := make([dynamic]osync.Feed_Pattern, context.temp_allocator)
	for suffix in s.groups {
		p := osync.Feed_Pattern{kind = .Suffix}
		x := suffix
		copy(p.bytes[:16], x[:])
		append(&pats, p)
	}
	card := _card_scope(s)
	defer osync.scope_clear(&card)
	cs := osync.stream_suffix(&card, CARD_STREAM, 0)
	p := osync.Feed_Pattern{kind = .Suffix}
	copy(p.bytes[:16], cs[:])
	append(&pats, p)
	for id in s.probes {
		append(&pats, osync.Feed_Pattern{kind = .Exact, bytes = cast([32]u8)id})
	}
	for _, o in s.objects {
		for sg in o.segs {
			if !sg.tree_ok {
				append(&pats, osync.Feed_Pattern{kind = .Exact, bytes = cast([32]u8)sg.keys.id})
			}
		}
	}
	osync.client_feed_follow(&s.link.client, u64(max(from, 0)), pats[:], true)
}

@(private)
_card_scope :: proc(s: ^Session) -> osync.Scope {
	if s.shared {
		return object_scope(s, s.share.object)
	}
	return s.scope
}

@(private)
_remote_get :: proc(s: ^Session, kind: Remote_Kind, scope: ^osync.Scope, device: prim.Id, name: string, epoch: u64) -> ^Remote {
	id := osync.stream_id(scope, device, name, epoch)
	if rm, ok := s.remotes[id]; ok {
		return rm
	}
	rm := new(Remote, s.allocator)
	rm.id = id
	rm.kind = kind
	rm.device = device
	rm.epoch = epoch
	rm.relay_len = -1
	rm.inflight = make([dynamic]journal.Range, s.allocator)
	h := id
	path: [2 + 64]u8
	path[0] = 'r'
	path[1] = '/'
	prim.hex_encode(path[2:], h[:])
	journal.replica_open(&rm.rep, s.vfs, string(path[:]), s.allocator)
	s.remotes[id] = rm
	return rm
}

@(private)
_remote_free :: proc(s: ^Session, rm: ^Remote) {
	journal.replica_close(&rm.rep)
	delete(rm.inflight)
	free(rm, s.allocator)
}

@(private)
_remote_drop :: proc(s: ^Session, rm: ^Remote) {
	if s.rx == rm {
		_rx_reset(s)
	}
	if rm.follow && s.ready {
		ids := [1]osync.Stream_Id{rm.id}
		osync.client_unfollow(&s.link.client, ids[:])
	}
	delete_key(&s.remotes, rm.id)
	h := rm.id
	path: [2 + 64]u8
	path[0] = 'r'
	path[1] = '/'
	prim.hex_encode(path[2:], h[:])
	_remote_free(s, rm)
	_remove_replica(s, string(path[:]))
}

@(private)
_remove_replica :: proc(s: ^Session, path: string) {
	prim.remove(s.vfs, path)
	buf: [80]u8
	n := copy(buf[:], path)
	copy(buf[n:], ".have")
	prim.remove(s.vfs, string(buf[:n + 5]))
	copy(buf[n:], ".redact")
	prim.remove(s.vfs, string(buf[:n + 7]))
}

@(private)
_contiguous :: proc(rm: ^Remote) -> i64 {
	have := journal.replica_have(&rm.rep)
	if len(have) > 0 && have[0].from == 0 {
		return have[0].to
	}
	return 0
}

@(private)
_have_end :: proc(rm: ^Remote) -> i64 {
	have := journal.replica_have(&rm.rep)
	if len(have) == 0 {
		return 0
	}
	return have[len(have) - 1].to
}

@(private)
_remote_tail :: proc(s: ^Session, rm: ^Remote, n: i64) {
	for f in rm.inflight {
		if f.from < 0 {
			return
		}
	}
	if !s.ready {
		append(&rm.inflight, journal.Range{-1, -n})
		return
	}
	if osync.client_tail(&s.link.client, rm.id, n) == .None {
		append(&rm.inflight, journal.Range{-1, -n})
	}
}

@(private)
_remote_follow :: proc(s: ^Session, rm: ^Remote, full: bool) {
	rm.follow = true
	rm.full = rm.full || full
	if !s.ready {
		return
	}
	off := u64(_contiguous(rm)) if rm.full else osync.FOLLOW_END
	if !rm.full {
		if e := _have_end(rm); e > 0 {
			off = u64(e)
		} else if rm.relay_len >= 0 {
			off = u64(max(journal.replica_length(&rm.rep), rm.relay_len))
		}
	}
	e := [1]osync.Follow_Entry{{rm.id, off}}
	osync.client_follow(&s.link.client, e[:], true)
}

@(private)
_remote_resume :: proc(s: ^Session, rm: ^Remote) {
	tail := i64(0)
	for f in rm.inflight {
		if f.from < 0 {
			tail = -f.to
		}
	}
	clear(&rm.inflight)
	if tail > 0 {
		_remote_tail(s, rm, tail)
	}
	if rm.follow {
		_remote_follow(s, rm, rm.full)
	}
}

@(private)
_remote_fetch :: proc(s: ^Session, rm: ^Remote, from, to: i64) -> bool {
	if to <= from || !s.ready {
		return false
	}
	for f in rm.inflight {
		if f.from < 0 || (f.from <= from && f.to >= to) {
			return true
		}
	}
	a := from
	if to - a < MIN_FETCH {
		a = max(to - MIN_FETCH, 0)
	}
	if osync.client_read(&s.link.client, rm.id, a, to) != .None {
		return false
	}
	append(&rm.inflight, journal.Range{a, to})
	return true
}

@(private)
_seen :: proc(s: ^Session, id: osync.Stream_Id, length: i64) {
	if rm, ok := s.remotes[id]; ok {
		if length > rm.relay_len {
			rm.relay_len = length
			if length > journal.replica_length(&rm.rep) {
				journal.replica_set_length(&rm.rep, length)
			}
			_mark(rm)
		}
		return
	}
	if pr, ok := s.probes[id]; ok {
		pr.seg.probing = false
		if length > 0 && pr.epoch > pr.seg.epoch {
			_seg_rekey(s, pr.seg, pr.epoch)
		}
		return
	}
	if length <= 0 {
		return
	}
	if o, ok := s.groups[osync.stream_id_suffix(id)]; ok {
		dev := osync.stream_device(id)
		if _seg_find(o, dev) == nil {
			_seg_add(s, o, dev)
		}
		if rm, rok := s.remotes[id]; rok && length > rm.relay_len {
			rm.relay_len = length
			journal.replica_set_length(&rm.rep, length)
			_mark(rm)
		}
	}
}

@(private)
_on_data :: proc(s: ^Session, ev: ^osync.Event) {
	if ev.first {
		_rx_reset(s)
		s.rx_at = ev.at
		s.rx_start = ev.at
		s.stage_at = ev.at
		rm, ok := s.remotes[osync.Stream_Id(ev.id)]
		if !ok {
			return
		}
		s.rx = rm
		if ev.length > rm.relay_len {
			rm.relay_len = ev.length
		}
		if ev.length > journal.replica_length(&rm.rep) {
			journal.replica_set_length(&rm.rep, ev.length)
		}
		return
	}
	if len(ev.data) > 0 {
		if s.rx != nil {
			append(&s.stage, ..ev.data)
			if len(s.stage) >= STAGE_MAX {
				_stage_flush(s)
			}
		}
		s.rx_at += i64(len(ev.data))
	}
	if !ev.last {
		return
	}
	rm := s.rx
	if rm == nil {
		return
	}
	_stage_flush(s)
	s.rx = nil
	_landed(rm, s.rx_start, s.rx_at, ev.length)
	if ev.length < rm.relay_len {
		rm.relay_len = ev.length
	}
	switch rm.kind {
	case .Segment:
		_mark(rm)
	case .Keys:
		_keys_landed(s, rm)
	case .Card:
		_card_landed(s, rm)
	}
}

@(private)
_stage_flush :: proc(s: ^Session) {
	if len(s.stage) == 0 {
		return
	}
	if rm := s.rx; rm != nil {
		at := s.stage_at
		end := at + i64(len(s.stage))
		pos := at
		for h in journal.replica_have(&rm.rep) {
			if h.to <= pos {
				continue
			}
			if h.from >= end {
				break
			}
			if h.from > pos {
				journal.replica_write(&rm.rep, pos, s.stage[pos - at:h.from - at])
			}
			pos = max(pos, h.to)
		}
		if pos < end {
			journal.replica_write(&rm.rep, pos, s.stage[pos - at:])
		}
	}
	s.stage_at += i64(len(s.stage))
	clear(&s.stage)
	if cap(s.stage) > STAGE_MAX * 2 {
		delete(s.stage)
		s.stage = make([dynamic]u8, s.allocator)
	}
}

@(private)
_landed :: proc(rm: ^Remote, from, to: i64, stream_len: i64) {
	for i := 0; i < len(rm.inflight); {
		f := rm.inflight[i]
		if f.from < 0 || (from <= f.from && to >= f.to) || (to >= stream_len && f.from >= from) || f.from >= stream_len {
			ordered_remove(&rm.inflight, i)
			continue
		}
		if from <= f.from && to > f.from {
			rm.inflight[i].from = to
		}
		i += 1
	}
}

@(private)
_object_get :: proc(s: ^Session, id: prim.Id, kind: obj.Kind) -> ^Object {
	if o, ok := s.objects[id]; ok {
		return o
	}
	o := new(Object, s.allocator)
	o.id = id
	o.kind = kind
	o.scope = object_scope(s, id)
	o.name = seg_name(kind, id, s.allocator)
	o.suffix = osync.stream_suffix(&o.scope, o.name, 0)
	o.segs = make([dynamic]^Seg, s.allocator)
	o.catalog = id == s.catalog_id && !s.shared
	if kind == .Conversation || kind == .Map {
		obj.view_init(&o.view, id, s.allocator)
	}
	if kind == .Map {
		h := prim.id_hex(id)
		path: [2 + prim.ID_HEX_LEN]u8
		path[0] = 't'
		path[1] = '/'
		copy(path[2:], h[:])
		if o.catalog {
			defs := omap.catalog_defs()
			o.table_ok = omap.table_open(&o.table, s.vfs, string(path[:]), defs[:], s.allocator) == .None
		} else {
			o.table_ok = omap.table_open(&o.table, s.vfs, string(path[:]), nil, s.allocator) == .None
		}
	}
	s.objects[id] = o
	s.groups[o.suffix] = o
	s.feed_dirty = true
	if !o.catalog && !s.shared {
		_catalog_members(s, o)
	}
	o.changed = true
	return o
}

@(private)
_object_free :: proc(s: ^Session, o: ^Object) {
	for sg in o.segs {
		journal.reader_close(&sg.jr)
		if sg.tree_ok {
			osync.keytree_destroy(&sg.tree)
		}
		free(sg, s.allocator)
	}
	delete(o.segs)
	if o.kind == .Conversation || o.kind == .Map {
		obj.view_destroy(&o.view)
	}
	if o.table_ok {
		omap.table_close(&o.table)
	}
	osync.scope_clear(&o.scope)
	delete(o.name, s.allocator)
	free(o, s.allocator)
}

_object_close :: proc(s: ^Session, o: ^Object) {
	for i := 0; i < len(s.requests); {
		r := s.requests[i]
		if r.object == o {
			_event(s, .Result, r.id, STATUS_CLOSED, nil)
			ordered_remove(&s.requests, i)
			delete(r.args, s.allocator)
			free(r, s.allocator)
			continue
		}
		i += 1
	}
	for i := 0; i < len(s.subs); {
		if s.subs[i].object == o {
			free(s.subs[i], s.allocator)
			ordered_remove(&s.subs, i)
			continue
		}
		i += 1
	}
	stale := make([dynamic]osync.Stream_Id, context.temp_allocator)
	for sg in o.segs {
		for id, pr in s.probes {
			if pr.seg == sg {
				append(&stale, id)
			}
		}
	}
	for id in stale {
		delete_key(&s.probes, id)
	}
	for sg in o.segs {
		journal.reader_close(&sg.jr)
		if sg.tree_ok {
			osync.keytree_destroy(&sg.tree)
		}
		ebuf: [2 + 64]u8
		prim.remove(s.vfs, _epoch_path(sg.data, &ebuf))
		_remote_drop(s, sg.data)
		_remote_drop(s, sg.keys)
		if sg.next != nil {
			_remote_drop(s, sg.next)
		}
		free(sg, s.allocator)
	}
	clear(&o.segs)
	delete_key(&s.groups, o.suffix)
	delete_key(&s.objects, o.id)
	if o.table_ok {
		omap.table_close(&o.table)
		o.table_ok = false
		h := prim.id_hex(o.id)
		path: [2 + prim.ID_HEX_LEN]u8
		path[0] = 't'
		path[1] = '/'
		copy(path[2:], h[:])
		prim.remove(s.vfs, string(path[:]))
	}
	_object_free(s, o)
	s.feed_dirty = true
}

@(private)
_catalog_members :: proc(s: ^Session, o: ^Object) {
	c, ok := s.objects[s.catalog_id]
	if !ok || !c.table_ok {
		return
	}
	e, found, err := omap.catalog_get(&c.table, o.id, context.temp_allocator)
	if err != .None || !found {
		return
	}
	for p in e.participants {
		if _seg_find(o, p) == nil {
			_seg_add(s, o, p)
		}
	}
}

@(private)
_seg_find :: proc(o: ^Object, device: prim.Id) -> ^Seg {
	for sg in o.segs {
		if sg.device == device {
			return sg
		}
	}
	return nil
}

@(private)
_seg_add :: proc(s: ^Session, o: ^Object, device: prim.Id) -> ^Seg {
	sg := new(Seg, s.allocator)
	sg.device = device
	append(&o.segs, sg)
	rm := _remote_get(s, .Segment, &o.scope, device, o.name, 0)
	rm.object = o
	rm.seg = sg
	sg.data = rm
	journal.replica_reader(&rm.rep, &sg.jr, s.allocator)
	if o.kind == .Map {
		_remote_follow(s, rm, true)
	} else {
		if journal.replica_length(&rm.rep) == 0 {
			_remote_tail(s, rm, TAIL_BYTES)
		}
		_remote_follow(s, rm, false)
	}
	_seg_keys(s, o, sg, _epoch_load(s, rm))
	_card_want(s, device)
	o.changed = true
	return sg
}

@(private)
_seg_keys :: proc(s: ^Session, o: ^Object, sg: ^Seg, epoch: u64) {
	kn := _keys_name(o.name)
	km := _remote_get(s, .Keys, &o.scope, sg.device, kn, epoch)
	km.object = o
	km.seg = sg
	sg.keys = km
	sg.epoch = epoch
	if _have_end(km) > 0 {
		_keys_landed(s, km)
	}
	_remote_tail(s, km, KEYS_TAIL)
	_seg_probe(s, o, sg, epoch)
}

@(private)
_epoch_path :: proc(rm: ^Remote, buf: ^[2 + 64]u8) -> string {
	h := rm.id
	buf[0] = 'e'
	buf[1] = '/'
	prim.hex_encode(buf[2:], h[:])
	return string(buf[:])
}

@(private)
_epoch_load :: proc(s: ^Session, rm: ^Remote) -> u64 {
	buf: [2 + 64]u8
	data, err := prim.read_file(s.vfs, _epoch_path(rm, &buf), context.temp_allocator)
	if err != .None || len(data) != 8 {
		return 0
	}
	return prim.get_u64le(data)
}

@(private)
_epoch_store :: proc(s: ^Session, sg: ^Seg) {
	buf: [2 + 64]u8
	v: [8]u8
	prim.put_u64le(v[:], sg.epoch)
	prim.replace_atomic(s.vfs, _epoch_path(sg.data, &buf), v[:])
}

@(private)
_keys_name :: proc(name: string) -> string {
	b := make([]u8, len(osync.KEYS_STREAM) + len(name), context.temp_allocator)
	copy(b, osync.KEYS_STREAM)
	copy(b[len(osync.KEYS_STREAM):], name)
	return string(b)
}

@(private)
_seg_probe :: proc(s: ^Session, o: ^Object, sg: ^Seg, base: u64) {
	kn := _keys_name(o.name)
	stale := make([dynamic]osync.Stream_Id, context.temp_allocator)
	for id, pr in s.probes {
		if pr.seg == sg {
			append(&stale, id)
		}
	}
	for id in stale {
		delete_key(&s.probes, id)
	}
	ids: [PROBES]osync.Stream_Id
	for i in 0 ..< PROBES {
		ep := base + 1 + u64(i)
		ids[i] = osync.stream_id(&o.scope, sg.device, kn, ep)
		s.probes[ids[i]] = Probe{sg, ep}
	}
	s.feed_dirty = true
	if s.ready && osync.client_probe(&s.link.client, ids[:]) == .None {
		sg.probing = true
	}
}

@(private)
_seg_rekey :: proc(s: ^Session, sg: ^Seg, epoch: u64) {
	if epoch <= sg.epoch || (sg.next != nil && epoch <= sg.next.epoch) {
		return
	}
	o := sg.keys.object
	if sg.next != nil {
		_remote_drop(s, sg.next)
	}
	kn := _keys_name(o.name)
	km := _remote_get(s, .Keys, &o.scope, sg.device, kn, epoch)
	km.object = o
	km.seg = sg
	sg.next = km
	_remote_tail(s, km, KEYS_TAIL)
	_seg_probe(s, o, sg, epoch)
}

@(private)
_keys_landed :: proc(s: ^Session, rm: ^Remote) {
	sg := rm.seg
	if sg == nil || (sg.keys != rm && sg.next != rm) {
		return
	}
	o := rm.object
	end := journal.replica_length(&rm.rep)
	if end <= 0 {
		return
	}
	rd: journal.Reader
	journal.replica_reader(&rm.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	key := osync.stream_key(&o.scope, rm.id)
	defer crypto.zero_explicit(&key, size_of(key))
	journal.reader_set_keys(&rd, osync.static_provider(&key))
	body, _, err := journal.record_before(&rd, end)
	if err != .None {
		if err == .Missing {
			_remote_fetch(s, rm, max(end - KEYS_TAIL, 0), end)
		}
		return
	}
	t: osync.Key_Tree
	if osync.keys_record_decode(&t, body, s.allocator) != .None {
		return
	}
	if rm == sg.next {
		old := sg.keys
		sg.keys = rm
		sg.next = nil
		sg.epoch = rm.epoch
		_epoch_store(s, sg)
		_remote_drop(s, old)
	}
	if sg.tree_ok {
		osync.keytree_destroy(&sg.tree)
		o.rekeyed = true
	}
	sg.tree = t
	sg.tree_ok = true
	if sg.in_view {
		journal.reader_set_keys(&sg.jr, osync.keytree_provider(&sg.tree))
		sg.chain.keys = osync.keytree_provider(&sg.tree)
		if i := obj.view_find(&o.view, sg.device); i >= 0 {
			o.view.segs[i].tail_end = -1
		}
	}
	_seg_enter(s, o, sg)
	o.changed = true
}

@(private)
_card_want :: proc(s: ^Session, device: prim.Id) {
	if device in s.identities || device in s.cards {
		return
	}
	sc := _card_scope(s)
	defer osync.scope_clear(&sc)
	rm := _remote_get(s, .Card, &sc, device, CARD_STREAM, 0)
	s.cards[device] = rm
	if _have_end(rm) > 0 {
		_card_landed(s, rm)
		if device in s.identities {
			return
		}
	}
	_remote_tail(s, rm, CARD_TAIL)
}

@(private)
_card_landed :: proc(s: ^Session, rm: ^Remote) {
	if rm.device in s.identities || journal.replica_length(&rm.rep) == 0 {
		return
	}
	sc := _card_scope(s)
	defer osync.scope_clear(&sc)
	rd: journal.Reader
	journal.replica_reader(&rm.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	key := osync.stream_key(&sc, rm.id)
	defer crypto.zero_explicit(&key, size_of(key))
	journal.reader_set_keys(&rd, osync.static_provider(&key))
	body, _, err := journal.record_at(&rd, 0)
	if err == .Missing {
		_remote_fetch(s, rm, 0, min(journal.replica_length(&rm.rep), CARD_TAIL))
		return
	}
	if err != .None {
		return
	}
	id, cerr := osync.card_verify(body)
	if cerr != .None || id.id != rm.device {
		return
	}
	s.identities[rm.device] = id
	for _, o in s.objects {
		for sg in o.segs {
			if sg.device == rm.device {
				_seg_enter(s, o, sg)
				o.changed = true
			}
		}
	}
}

@(private)
_seg_enter :: proc(s: ^Session, o: ^Object, sg: ^Seg) {
	if sg.in_view || !sg.tree_ok {
		return
	}
	id, known := s.identities[sg.device]
	if !known {
		return
	}
	sg.check = Seg_Check{signer = id}
	sg.chain = journal.Chain {
		seed     = osync.chain_seed(sg.data.id),
		keys     = osync.keytree_provider(&sg.tree),
		verifier = journal.Verifier{data = &sg.check, verify = _sig_verify},
	}
	journal.reader_set_chain(&sg.jr, &sg.chain)
	journal.reader_set_keys(&sg.jr, osync.keytree_provider(&sg.tree))
	if _, err := obj.view_add(&o.view, sg.device, &sg.jr); err != .None {
		return
	}
	sg.in_view = true
	o.changed = true
}

@(private)
_sig_verify :: proc(data: rawptr, msg: []u8, sig: []u8) -> bool {
	c := (^Seg_Check)(data)
	return osync.signature_verify(c.signer.sign, msg, sig)
}

@(private)
_object_waiting :: proc(s: ^Session, o: ^Object) -> bool {
	if !s.ready {
		return true
	}
	for sg in o.segs {
		if !sg.in_view {
			if len(sg.keys.inflight) > 0 || sg.probing || (sg.next != nil && len(sg.next.inflight) > 0) {
				return true
			}
			if c, ok := s.cards[sg.device]; ok && len(c.inflight) > 0 {
				return true
			}
		}
		if len(sg.data.inflight) > 0 {
			return true
		}
	}
	return false
}

@(private)
_object_wants :: proc(s: ^Session, o: ^Object) -> (issued: bool) {
	for u in obj.view_unknown(&o.view) {
		if _seg_find(o, u) == nil {
			_seg_add(s, o, u)
			issued = true
		}
	}
	for w in obj.view_wanted(&o.view) {
		sg := _seg_find(o, w.seg)
		if sg == nil {
			continue
		}
		to := w.to
		if sg.data.relay_len >= 0 {
			to = min(to, sg.data.relay_len)
		}
		if gap, missing := journal.replica_missing(&sg.data.rep, w.from, to); missing {
			if _remote_fetch(s, sg.data, gap.from, gap.to) {
				issued = true
			}
		}
	}
	obj.view_reset(&o.view)
	return
}

@(private)
_settle :: proc(s: ^Session) {
	for _, o in s.objects {
		if !o.changed {
			continue
		}
		if o.table_ok {
			for sg in o.segs {
				if sg.in_view {
					omap.table_apply(&o.table, sg.device, &sg.jr)
				}
			}
		}
		if o.catalog {
			for _, x in s.objects {
				if !x.catalog {
					_catalog_members(s, x)
				}
			}
		}
	}
	_deltas(s)
	_retry(s)
	for _, o in s.objects {
		o.changed = false
		o.rekeyed = false
	}
	if s.feed_dirty && s.ready {
		_feed_subscribe(s, s.feed_cursor)
	}
}

@(private)
_event :: proc(s: ^Session, kind: Event_Kind, id: u32, status: u8, payload: []u8) {
	head: [10]u8
	head[0] = u8(kind)
	prim.put_u32le(head[1:5], id)
	head[5] = status
	prim.put_u32le(head[6:10], u32(len(payload)))
	append(&s.events, ..head[:])
	append(&s.events, ..payload)
}
