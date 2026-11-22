package engine

import "base:runtime"
import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:slice"
import convo "../convo"
import "../journal"
import "../obj"
import omap "../map"
import "../prim"
import "../search"
import osync "../sync"

@(private)
ROOT_SEARCH :: ROOT_CKPT
@(private)
SEARCH_KEY_QUEUE :: u8(0xf1)
@(private)
SEARCH_KEY_MODE :: u8(0xf2)

INDEXERS_NAME :: "0ndb:indexers"
INDEXER_TAG_FLAGS :: u32(1)
INDEXER_TAG_CARD :: u32(2)
INDEXER_TAG_BEHIND :: u32(3)
INDEXER_FULL :: u64(1)

DEFAULT_SEARCH_HEDGE_MS :: 250
DEFAULT_SEARCH_DEADLINE_MS :: 3000

@(private)
REMOTE_VERSION :: u8(1)
@(private)
REMOTE_QUERY :: u8(1)
@(private)
REMOTE_ANSWER :: u8(2)
@(private)
REMOTE_AD_QUERY :: "0ndb-search-query-v1"
@(private)
REMOTE_AD_ANSWER :: "0ndb-search-answer-v1"
@(private)
REMOTE_MEMBER :: "0ndb-search-member-v1"
@(private)
FULL_ACTIVE :: 8
@(private)
FULL_STALL :: 64
@(private)
REMOTE_FLIGHTS :: 2
@(private)
REMOTE_REF_MAX :: 64
@(private)
VERIFY_TRIES :: 8
@(private)
CURSOR_REMOTE :: u8(0xa1)

Search_Mode :: enum u8 {
	Default,
	Full,
	Local,
}

Search_Scope :: enum u8 {
	Auto,
	Local,
	Everywhere,
}

Search_State :: enum u8 {
	Ok,
	Partial,
	Offline,
	Timeout,
	Denied,
	Failed,
	Cancelled,
}

Remote_Query :: struct {
	id:     u64,
	space:  prim.Id,
	query:  string,
	limit:  int,
	skip:   int,
	sort:   search.Sort,
	cursor: []u8,
	now:    prim.Hlc,
}

Remote_Ref :: struct {
	object: prim.Id,
	ref:    []u8,
	part:   u32,
	kind:   u8,
	hlc:    u64,
	score:  f64,
	spans:  []search.Match,
}

Remote_Mark :: struct {
	object:   prim.Id,
	device:   prim.Id,
	position: i64,
}

Remote_Answer :: struct {
	state:  Search_State,
	refs:   []Remote_Ref,
	cursor: []u8,
	marks:  []Remote_Mark,
	behind: int,
}

Search_Remote :: struct {
	data:   rawptr,
	query:  proc(data: rawptr, e: ^Engine, q: ^Remote_Query) -> Error,
	cancel: proc(data: rawptr, e: ^Engine, id: u64),
}

Search_Source :: struct {
	device:   prim.Id,
	local:    bool,
	state:    Search_State,
	behind:   int,
	hits:     int,
	rejected: int,
}

Search_Result :: struct {
	hits:    []search.Hit,
	cursor:  []u8,
	partial: bool,
	behind:  int,
	sources: []Search_Source,
}

@(private)
Remote_State :: struct {
	init:       bool,
	next:       u64,
	queries:    [dynamic]^Remote_Q,
	inbox:      [dynamic]Remote_Msg,
	modes:      map[prim.Id]Search_Mode,
	active:     [dynamic]Full_Active,
	skip:       map[prim.Id]bool,
	behind:     map[prim.Id]int,
	advertised: map[prim.Id]int,
	timer:      prim.Timer,
	timer_at:   i64,
	current:    ^Remote_Q,
	restores:   map[prim.Id]^Snap_Restore,
	parked:     [dynamic]Index_Item,
	decided:    map[prim.Id]bool,
	rebuilt:    bool,
	restore_ms: i64,
	restore_docs: int,
	stats:      Search_Stats,
}

Search_Stats :: struct {
	queries:   u64,
	sent:      u64,
	answers:   u64,
	served:    u64,
	verified:  u64,
	rejected:  u64,
	bytes_out: u64,
	bytes_in:  u64,
}

search_stats :: proc(e: ^Engine) -> Search_Stats {
	return e.remote.stats
}

@(private)
Remote_Msg :: struct {
	space:   prim.Id,
	device:  prim.Id,
	tag:     u64,
	failed:  bool,
	payload: []u8,
}

@(private)
Full_Active :: struct {
	space:    prim.Id,
	object:   prim.Id,
	kind:     Kind,
	progress: i64,
	stall:    int,
	probed:   bool,
}

@(private)
Flight :: struct {
	device: prim.Id,
	tag:    u64,
	key:    [32]u8,
	live:   bool,
}

@(private)
Pending_Ref :: struct {
	ref:     Remote_Ref,
	state:   u8,
	tries:   u8,
	waiting: bool,
}

@(private)
Remote_Q :: struct {
	id:          u64,
	space:       prim.Id,
	arena:       runtime.Arena,
	alloc:       runtime.Allocator,
	query:       string,
	req:         search.Request,
	scope:       Search_Scope,
	done:        Done,
	local:       search.Results,
	local_skip:  int,
	local_prev:  []u8,
	peer_prev:   []u8,
	peer_skip:   int,
	peer_pin:    prim.Id,
	flights:     [REMOTE_FLIGHTS]Flight,
	tried:       [dynamic]prim.Id,
	hedge_at:    i64,
	deadline:    i64,
	answered:    bool,
	answer:      Remote_Answer,
	answer_from: prim.Id,
	refs:        [dynamic]Pending_Ref,
	verified:    [dynamic]search.Hit,
	sources:     [dynamic]Search_Source,
	finished:    bool,
	ready_now:   bool,
	awaiting:    bool,
	due:         bool,
	plug:        bool,
	result:      Search_Result,
}

@(private)
_remote :: proc(e: ^Engine) -> ^Remote_State {
	r := &e.remote
	if !r.init {
		r.init = true
		r.queries = make([dynamic]^Remote_Q, e.allocator)
		r.inbox = make([dynamic]Remote_Msg, e.allocator)
		r.modes = make(map[prim.Id]Search_Mode, e.allocator)
		r.active = make([dynamic]Full_Active, e.allocator)
		r.skip = make(map[prim.Id]bool, e.allocator)
		r.behind = make(map[prim.Id]int, e.allocator)
		r.advertised = make(map[prim.Id]int, e.allocator)
		r.restores = make(map[prim.Id]^Snap_Restore, e.allocator)
		r.parked = make([dynamic]Index_Item, e.allocator)
		r.decided = make(map[prim.Id]bool, e.allocator)
		if e.reg.open {
			k := [1]u8{SEARCH_KEY_REBUILT}
			_, hit, _ := omap.db_get(&e.reg.db, ROOT_SEARCH, k[:], context.temp_allocator)
			r.rebuilt = hit
		}
	}
	return r
}

@(private)
_remote_close :: proc(e: ^Engine) {
	r := &e.remote
	if !r.init {
		return
	}
	for len(r.queries) > 0 {
		q := r.queries[len(r.queries) - 1]
		_q_finish(e, q, .Cancelled)
	}
	if r.timer != 0 {
		prim.timer_cancel(e.loop, r.timer)
		r.timer = 0
	}
	for m in r.inbox {
		delete(m.payload, e.allocator)
	}
	for _, rs in r.restores {
		_snap_restore_free(e, rs)
	}
	delete(r.restores)
	delete(r.parked)
	delete(r.decided)
	delete(r.queries)
	delete(r.inbox)
	delete(r.modes)
	delete(r.active)
	delete(r.skip)
	delete(r.behind)
	delete(r.advertised)
	r^ = {}
}

space_search_mode :: proc(e: ^Engine, space: prim.Id) -> Search_Mode {
	context = context_for(e)
	r := _remote(e)
	if m, ok := r.modes[space]; ok {
		return m
	}
	key := _mode_key(space)
	v, found, err := omap.db_get(&e.reg.db, ROOT_SEARCH, key[:], context.temp_allocator)
	m := Search_Mode.Default
	if err == .None && found && len(v) == 1 && v[0] <= u8(Search_Mode.Local) {
		m = Search_Mode(v[0])
	}
	r.modes[space] = m
	return m
}

space_search_set :: proc(e: ^Engine, space: prim.Id, mode: Search_Mode) -> Error {
	context = context_for(e)
	_space_open(e, space) or_return
	r := _remote(e)
	key := _mode_key(space)
	v := [1]u8{u8(mode)}
	_reg_put(e, ROOT_SEARCH, key[:], v[:]) or_return
	r.modes[space] = mode
	if sp, ok := e.spaces[space]; ok && _full_on(e, sp) {
		_full_rewalk(e, sp)
		_touch(e)
	}
	return .None
}

@(private)
_full_on :: proc(e: ^Engine, sp: ^Space) -> bool {
	if !e.cfg.search || sp.keyless || !sp.open {
		return false
	}
	switch space_search_mode(e, sp.id) {
	case .Full:
		return true
	case .Local:
		return false
	case .Default:
		return e.cfg.search_full
	}
	return false
}

@(private)
_reg_put :: proc(e: ^Engine, root: int, key: []u8, value: []u8) -> Error {
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	if err := omap.txn_put(t, root, key, value); err != .None {
		omap.txn_abort(t)
		return _oerr(err)
	}
	return _oerr(omap.txn_commit(t))
}

@(private)
_reg_del :: proc(e: ^Engine, root: int, key: []u8) -> Error {
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	if _, err := omap.txn_delete(t, root, key); err != .None {
		omap.txn_abort(t)
		return _oerr(err)
	}
	return _oerr(omap.txn_commit(t))
}

@(private)
_full_key :: proc(space, object: prim.Id) -> (k: [33]u8) {
	a, b := space, object
	k[0] = SEARCH_KEY_QUEUE
	copy(k[1:17], a[:])
	copy(k[17:], b[:])
	return
}

@(private)
_mode_key :: proc(space: prim.Id) -> (k: [17]u8) {
	a := space
	k[0] = SEARCH_KEY_MODE
	copy(k[1:], a[:])
	return
}

@(private)
_full_note :: proc(e: ^Engine, sp: ^Space, object: prim.Id, kind: Kind) {
	if !_full_on(e, sp) || object == sp.catalog {
		return
	}
	#partial switch kind {
	case .Conversation:
	case .File_Tree:
		if !e.cfg.search_trees {
			return
		}
	case:
		return
	}
	r := _remote(e)
	k := _full_key(sp.id, object)
	v := [1]u8{u8(kind)}
	_, found, _ := omap.db_get(&e.reg.db, ROOT_SEARCH, k[:], context.temp_allocator)
	if !found {
		if _reg_put(e, ROOT_SEARCH, k[:], v[:]) != .None {
			return
		}
		r.behind[sp.id] += 1
	}
	delete_key(&r.skip, object)
	_touch(e)
}

@(private)
_full_catalog_record :: proc(e: ^Engine, sp: ^Space, body: []u8, at: i64) {
	if !_full_on(e, sp) {
		return
	}
	env, derr := obj.decode_envelope(body, at)
	if derr != .None {
		return
	}
	b, berr := omap.decode_body(&env, context.temp_allocator)
	if berr != .None {
		return
	}
	put, ok := b.(omap.Put)
	if !ok || len(put.key) != 16 {
		return
	}
	id: prim.Id
	copy(id[:], put.key)
	kind := Kind(0)
	activity := false
	for f in put.fields {
		switch f.tag {
		case u32(omap.Catalog_Tag.Kind):
			if len(f.value) >= 1 {
				kind = Kind(f.value[0])
			}
		case u32(omap.Catalog_Tag.Activity), u32(omap.Catalog_Tag.Status), u32(omap.Catalog_Tag.Title):
			activity = true
		}
	}
	if kind == Kind(0) {
		if !activity {
			return
		}
		rec, found, _ := _rec_get(e, id)
		if found {
			kind = rec.kind
		} else if c, cfound, _ := catalog_get(e, Object{sp.id, id}, context.temp_allocator); cfound {
			kind = Kind(c.kind)
		} else {
			kind = .Conversation
		}
	}
	_full_note(e, sp, id, kind)
}

@(private)
_full_rewalk :: proc(e: ^Engine, sp: ^Space) {
	rec, found, err := _rec_get(e, sp.catalog)
	if err != .None || !found {
		_index_item_add(e, sp.id, sp.catalog, .Map)
		return
	}
	changed := false
	for &m in rec.members {
		if m.scanned != 0 {
			m.scanned = 0
			changed = true
		}
	}
	if changed {
		_rec_put(e, sp.catalog, &rec)
	}
	_index_item_add(e, sp.id, sp.catalog, .Map)
}

@(private)
_full_step :: proc(e: ^Engine) {
	r := &e.remote
	if !r.init || !e.cfg.search {
		return
	}
	_snap_step(e)
	for i := 0; i < len(r.active); {
		a := r.active[i]
		sp, ok := e.spaces[a.space]
		if !ok || !sp.open || !_full_on(e, sp) {
			unordered_remove(&r.active, i)
			continue
		}
		done, progress := _full_check(e, sp, a.object, a.kind, !a.probed)
		r.active[i].probed = true
		if done {
			k := _full_key(a.space, a.object)
			_reg_del(e, ROOT_SEARCH, k[:])
			if n := r.behind[a.space]; n > 0 {
				r.behind[a.space] = n - 1
			}
			unordered_remove(&r.active, i)
			continue
		}
		if progress != a.progress {
			r.active[i].progress = progress
			r.active[i].stall = 0
		} else {
			r.active[i].stall += 1
			if r.active[i].stall >= FULL_STALL || !sp.connected {
				r.skip[a.object] = true
				unordered_remove(&r.active, i)
				continue
			}
		}
		i += 1
	}
	if len(r.active) >= FULL_ACTIVE {
		return
	}
	for sid in _sorted_keys(e.spaces) {
		sp := e.spaces[sid]
		if !sp.open || !sp.connected || !_full_on(e, sp) || sid in r.restores {
			continue
		}
		if r.rebuilt && !r.decided[sid] {
			_snap_restore_maybe(e, sp)
			continue
		}
		Walk :: struct {
			e:     ^Engine,
			r:     ^Remote_State,
			space: prim.Id,
			count: int,
		}
		visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
			w := (^Walk)(data)
			if len(key) != 33 || len(value) != 1 {
				return true
			}
			w.count += 1
			if len(w.r.active) >= FULL_ACTIVE {
				return true
			}
			id: prim.Id
			copy(id[:], key[17:])
			if id in w.r.skip {
				return true
			}
			for a in w.r.active {
				if a.object == id {
					return true
				}
			}
			append(&w.r.active, Full_Active{space = w.space, object = id, kind = Kind(value[0]), progress = -1})
			_index_item_add(w.e, w.space, id, Kind(value[0]))
			return true
		}
		w := Walk{e = e, r = r, space = sid}
		pfx: [17]u8
		pfx[0] = SEARCH_KEY_QUEUE
		s := sid
		copy(pfx[1:], s[:])
		omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &w, visit)
		r.behind[sid] = w.count
		if len(r.active) >= FULL_ACTIVE {
			return
		}
	}
}

@(private)
_full_check :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind, probe: bool) -> (done: bool, progress: i64) {
	h, err := _handle_get(e, Object{sp.id, id}, kind)
	if err != .None {
		return err == .Not_Found || err == .Invalid, 0
	}
	if !e.index_open {
		return false, 0
	}
	done = true
	for s in h.segs {
		if s.waiting || s.probing || !s.in_view {
			done = false
			continue
		}
		pos, _ := search.position(&e.index, _source_id(id, s.device))
		end := journal.reader_end(&s.jr)
		if sp.repl_on {
			n := osync.replicator_relay_length(&sp.repl, &h.scope, s.device, h.name, 0)
			if n < 0 {
				osync.replicator_want_tail(&sp.repl, &h.scope, s.device, h.name, 0, 1)
				done = false
			} else if n > end {
				r := [1]journal.Range{{end, n}}
				osync.replicator_want(&sp.repl, &h.scope, s.device, h.name, 0, r[:])
				end = n
			}
		}
		progress += pos
		if pos < end {
			done = false
		}
	}
	if _ckpt_waiting(h) || probe {
		done = false
	}
	return
}

@(private)
_full_kick :: proc(e: ^Engine, sp: ^Space) {
	if !e.cfg.search {
		return
	}
	r := _remote(e)
	clear(&r.skip)
	if _full_on(e, sp) {
		_snap_kick(e, sp)
		_touch(e)
	}
}

@(private)
_full_settle :: proc(e: ^Engine) {
	_full_step(e)
	for sid in _sorted_keys(e.spaces) {
		sp := e.spaces[sid]
		if !sp.open || !sp.connected {
			continue
		}
		if !_full_on(e, sp) {
			if e.cfg.search {
				_indexer_retract(e, sp)
			}
			continue
		}
		r := _remote(e)
		behind := r.behind[sid]
		prev, said := r.advertised[sid]
		if said && (prev == behind || (prev > 0 && behind > 0 && abs(prev - behind) < 64)) {
			continue
		}
		if _indexer_advertise(e, sp, behind) == .None {
			r.advertised[sid] = behind
		}
	}
	for sid in _sorted_keys(e.spaces) {
		sp := e.spaces[sid]
		if sp.open && sp.connected && _full_on(e, sp) {
			_snap_settle(e, sp)
		}
	}
}

@(private)
_indexer_advertise :: proc(e: ^Engine, sp: ^Space, behind: int) -> Error {
	o := map_named(e, sp.id, INDEXERS_NAME) or_return
	card, cerr := osync.keyring_card(&e.keyring)
	if cerr != .None {
		return _serr(cerr)
	}
	me := e.self
	fields := [3]omap.Field {
		omap.field_u64(INDEXER_TAG_FLAGS, INDEXER_FULL),
		omap.Field{tag = INDEXER_TAG_CARD, value = card[:]},
		omap.field_u64(INDEXER_TAG_BEHIND, u64(max(behind, 0))),
	}
	_, err := map_set(e, o, me[:], fields[:])
	if err == .Pending || err == .None {
		k := _snap_key(SEARCH_KEY_ADVERTISED, sp.id)
		v := [1]u8{1}
		_reg_put(e, ROOT_SEARCH, k[:], v[:])
		return .None
	}
	return err
}

@(private)
_indexer_retract :: proc(e: ^Engine, sp: ^Space) {
	k := _snap_key(SEARCH_KEY_ADVERTISED, sp.id)
	if _, hit, _ := omap.db_get(&e.reg.db, ROOT_SEARCH, k[:], context.temp_allocator); !hit {
		return
	}
	o, oerr := map_named(e, sp.id, INDEXERS_NAME)
	if oerr != .None {
		return
	}
	me := e.self
	fields := [1]omap.Field{omap.field_u64(INDEXER_TAG_FLAGS, 0)}
	if _, err := map_set(e, o, me[:], fields[:]); err == .None || err == .Pending {
		_reg_del(e, ROOT_SEARCH, k[:])
		delete_key(&_remote(e).advertised, sp.id)
	}
}

@(private)
Indexer :: struct {
	device: prim.Id,
	ident:  osync.Identity,
	behind: int,
}

@(private)
_indexers :: proc(e: ^Engine, sp: ^Space, allocator: runtime.Allocator, ready: Ready = {}) -> (list: []Indexer, pending: bool) {
	out := make([dynamic]Indexer, allocator)
	o := Object{sp.id, named_id(sp.id, INDEXERS_NAME)}
	cur: Map_Cursor
	defer omap.cursor_destroy(&cur)
	rows, _, err := map_scan(e, o, nil, &cur, 256, context.temp_allocator, ready)
	if err == .Pending {
		pending = true
	} else if err != .None {
		return out[:], false
	}
	for &row in rows {
		if len(row.key) != 16 {
			continue
		}
		id: prim.Id
		copy(id[:], row.key)
		if id == e.self {
			continue
		}
		flags, fok := _entry_u64(&row.entry, INDEXER_TAG_FLAGS)
		if !fok || flags & INDEXER_FULL == 0 {
			continue
		}
		card, cok := omap.entry_register(&row.entry, INDEXER_TAG_CARD)
		if !cok {
			continue
		}
		ident, verr := osync.card_verify(card)
		if verr != .None || ident.id != osync.Device_Id(id) {
			continue
		}
		up, _, _ := presence(e, sp.id, id)
		if !up {
			continue
		}
		behind, _ := _entry_u64(&row.entry, INDEXER_TAG_BEHIND)
		append(&out, Indexer{device = id, ident = ident, behind = int(min(behind, u64(max(int))))})
	}
	slice.sort_by(out[:], proc(a, b: Indexer) -> bool {
		if a.behind != b.behind {
			return a.behind < b.behind
		}
		x, y := a.device, b.device
		return string(x[:]) < string(y[:])
	})
	return out[:], pending
}

search_indexer_known :: proc(e: ^Engine, space: prim.Id) -> bool {
	context = context_for(e)
	sp, ok := e.spaces[space]
	if !ok || !sp.open {
		return false
	}
	if _full_on(e, sp) {
		return true
	}
	list, _ := _indexers(e, sp, context.temp_allocator)
	return len(list) > 0
}

search_everywhere :: proc(e: ^Engine, space: prim.Id, query: string, req: search.Request, scope: Search_Scope, done: Done) -> (id: u64, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	if !e.cfg.search {
		return 0, .Unsupported
	}
	r := _remote(e)
	q := new(Remote_Q, e.allocator)
	if runtime.arena_init(&q.arena, 64 * 1024, e.allocator) != nil {
		free(q, e.allocator)
		return 0, .No_Memory
	}
	q.alloc = runtime.arena_allocator(&q.arena)
	r.next += 1
	r.stats.queries += 1
	q.id = r.next
	q.space = space
	q.scope = scope
	q.done = done
	q.query = _clone(query, q.alloc) or_return
	q.req = req
	q.req.limit = clamp(req.limit if req.limit > 0 else search.DEFAULT_LIMIT, 1, search.MAX_LIMIT)
	q.tried = make([dynamic]prim.Id, q.alloc)
	q.refs = make([dynamic]Pending_Ref, q.alloc)
	q.verified = make([dynamic]search.Hit, q.alloc)
	q.sources = make([dynamic]Search_Source, q.alloc)
	if !_cursor_split(q, req.cursor) {
		_q_free(e, q)
		return 0, .Invalid
	}
	append(&r.queries, q)
	lreq := q.req
	lreq.cursor = q.local_prev
	lreq.limit = q.req.limit + q.local_skip
	if _index_open(e) == .None {
		res, serr := search.search(&e.index, q.query, lreq, q.alloc)
		if serr == .Syntax {
			_q_free_list(e, q)
			return 0, .Invalid
		}
		if serr == .None {
			q.local = res
			q.local.hits = _hit_gens(e, q.local.hits, q.alloc)
			if q.local_skip > 0 {
				n := min(q.local_skip, len(res.hits))
				q.local.hits = res.hits[n:]
			}
		}
	}
	append(&q.sources, Search_Source{device = e.self, local = true, state = .Ok, hits = len(q.local.hits)})
	if scope == .Local || _full_on(e, sp) {
		q.ready_now = true
		_touch(e)
		return q.id, .None
	}
	if e.cfg.search_remote.query != nil {
		q.plug = true
		rq := Remote_Query {
			id     = q.id,
			space  = space,
			query  = q.query,
			limit  = q.req.limit,
			skip   = q.peer_skip,
			sort   = q.req.sort,
			cursor = q.peer_prev,
			now    = q.req.now,
		}
		perr: Error
		{
			context = _outer(e)
			perr = e.cfg.search_remote.query(e.cfg.search_remote.data, e, &rq)
		}
		if perr != .None {
			append(&q.sources, Search_Source{state = .Failed})
			q.ready_now = true
			_touch(e)
			return q.id, .None
		}
		_q_arm(e, q, false)
		return q.id, .None
	}
	_q_arm(e, q, false)
	_q_start(e, q, sp)
	return q.id, .None
}

@(private)
_q_start :: proc(e: ^Engine, q: ^Remote_Q, sp: ^Space) {
	sent, pending := _q_next(e, q, sp)
	q.awaiting = !sent && pending
	if sent || pending {
		return
	}
	_emit(e, Event{kind = .Indexer_Wanted, space = q.space})
	append(&q.sources, Search_Source{state = .Offline})
	q.ready_now = true
	_touch(e)
}

search_cancel :: proc(e: ^Engine, id: u64) -> bool {
	context = context_for(e)
	r := &e.remote
	if !r.init {
		return false
	}
	for q in r.queries {
		if q.id == id {
			_q_finish(e, q, .Cancelled)
			return true
		}
	}
	return false
}

search_result :: proc(e: ^Engine, id: u64) -> ^Search_Result {
	r := &e.remote
	if !r.init || r.current == nil || r.current.id != id {
		return nil
	}
	return &r.current.result
}

search_remote_answer :: proc(e: ^Engine, id: u64, answer: ^Remote_Answer) -> Error {
	context = context_for(e)
	q := _q_find(e, id)
	if q == nil || q.answered || !q.plug {
		return .Not_Found
	}
	_q_accept(e, q, {}, answer^, true)
	return .None
}

@(private)
_q_find :: proc(e: ^Engine, id: u64) -> ^Remote_Q {
	r := &e.remote
	if !r.init {
		return nil
	}
	for q in r.queries {
		if q.id == id {
			return q
		}
	}
	return nil
}

@(private)
_cursor_split :: proc(q: ^Remote_Q, c: []u8) -> bool {
	if len(c) == 0 {
		return true
	}
	if c[0] != CURSOR_REMOTE {
		q.local_prev = c
		return true
	}
	rd := prim.reader(c[1:])
	n := int(prim.read_u16le(&rd))
	q.local_prev = prim.read_raw(&rd, n)
	q.local_skip = int(prim.read_u16le(&rd))
	prim.read_fixed(&rd, q.peer_pin[:])
	n = int(prim.read_u16le(&rd))
	q.peer_prev = prim.read_raw(&rd, n)
	q.peer_skip = int(prim.read_u16le(&rd))
	return prim.reader_ok(&rd) && prim.reader_remaining(&rd) == 0
}

@(private)
_q_next :: proc(e: ^Engine, q: ^Remote_Q, sp: ^Space) -> (sent: bool, pending: bool) {
	list: []Indexer
	list, pending = _indexers(e, sp, context.temp_allocator, Ready{data = _q_ready_data(q.id, READY_NO_REF), call = _q_ready})
	if q.peer_pin != {} {
		for x, i in list {
			if x.device == q.peer_pin && i > 0 {
				list[0], list[i] = list[i], list[0]
				break
			}
		}
	}
	outer: for x in list {
		for t in q.tried {
			if t == x.device {
				continue outer
			}
		}
		slot := -1
		for f, i in q.flights {
			if !f.live {
				slot = i
				break
			}
		}
		if slot < 0 {
			return true, pending
		}
		append(&q.tried, x.device)
		ident := x.ident
		if _q_send(e, q, sp, slot, x.device, &ident) {
			return true, pending
		}
	}
	for f in q.flights {
		if f.live {
			return true, pending
		}
	}
	return false, pending
}

@(private)
_q_send :: proc(e: ^Engine, q: ^Remote_Q, sp: ^Space, slot: int, peer: prim.Id, ident: ^osync.Identity) -> bool {
	f := &q.flights[slot]
	f^ = {}
	prim.random_fill(e.cfg.random, f.key[:])
	ck := osync.Content_Key{key = f.key}
	wrapped: [osync.WRAP_LEN]u8
	if osync.seal_key_to(ident, &ck, &wrapped, e.cfg.random) != .None {
		crypto.zero_explicit(&ck, size_of(ck))
		return false
	}
	crypto.zero_explicit(&ck, size_of(ck))
	card, cerr := osync.keyring_card(&e.keyring)
	if cerr != .None {
		return false
	}
	plain := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&plain)
	prim.write_u8(&w, REMOTE_VERSION)
	prim.write_u8(&w, REMOTE_QUERY)
	prim.write_raw(&w, card[:])
	proof := _member_proof(sp, wrapped[:], peer)
	prim.write_raw(&w, proof[:])
	prim.write_u16le(&w, u16(q.req.limit))
	cursor := q.peer_prev if q.peer_pin == peer || q.peer_pin == {} else nil
	skip := q.peer_skip if len(cursor) > 0 else 0
	prim.write_u16le(&w, u16(min(skip, int(max(u16)))))
	prim.write_u8(&w, u8(q.req.sort))
	prim.write_u64le(&w, u64(q.req.now))
	prim.write_u16le(&w, u16(len(cursor)))
	prim.write_raw(&w, cursor)
	prim.write_u16le(&w, u16(min(len(q.query), int(max(u16)))))
	prim.write_raw(&w, transmute([]u8)q.query)
	sig: [64]u8
	msg := _remote_signed(wrapped[:], peer, plain[:])
	if e.keyring.sign(e.keyring.data, msg, &sig) != .None {
		return false
	}
	prim.write_raw(&w, sig[:])
	if w.err != .None || len(plain) + osync.WRAP_LEN + chacha20poly1305.TAG_SIZE > osync.DIRECT_MAX {
		return false
	}
	payload := make([]u8, osync.WRAP_LEN + len(plain) + chacha20poly1305.TAG_SIZE, context.temp_allocator)
	copy(payload, wrapped[:])
	_aead_seal(f.key[:], 0, REMOTE_AD_QUERY, payload[osync.WRAP_LEN:][:len(plain)], payload[osync.WRAP_LEN + len(plain):], plain[:])
	f.tag = q.id << 2 | u64(slot)
	f.device = peer
	r := _remote(e)
	r.stats.sent += 1
	r.stats.bytes_out += u64(len(payload) + osync.FRAME_HEADER + osync.DIRECT_FIXED)
	if osync.replicator_direct(&sp.repl, osync.Device_Id(peer), f.tag, payload) != .None {
		crypto.zero_explicit(&f.key, size_of(f.key))
		f^ = {}
		return false
	}
	f.live = true
	return true
}

@(private)
_remote_signed :: proc(wrapped: []u8, peer: prim.Id, plain: []u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..transmute([]u8)string(REMOTE_AD_QUERY))
	append(&out, ..wrapped)
	p := peer
	append(&out, ..p[:])
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, plain, digest[:])
	append(&out, ..digest[:])
	return out[:]
}

@(private)
_member_proof :: proc(sp: ^Space, wrapped: []u8, peer: prim.Id) -> (proof: [32]u8) {
	if sp.keyless {
		return
	}
	k: [32]u8
	defer crypto.zero_explicit(&k, size_of(k))
	key := sp.keys.content.key
	hmac.sum(.SHA256, k[:], transmute([]u8)string(REMOTE_MEMBER), key[:])
	msg := make([dynamic]u8, context.temp_allocator)
	append(&msg, ..wrapped)
	p := peer
	append(&msg, ..p[:])
	hmac.sum(.SHA256, proof[:], msg[:], k[:])
	return
}

@(private)
_aead_seal :: proc(key: []u8, nonce: u8, ad: string, dst: []u8, tag: []u8, plain: []u8) {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key)
	defer chacha20poly1305.reset(&ctx)
	iv: [12]u8
	iv[0] = nonce
	chacha20poly1305.seal(&ctx, dst, tag, iv[:], transmute([]u8)ad, plain)
}

@(private)
_aead_open :: proc(key: []u8, nonce: u8, ad: string, dst: []u8, ct: []u8, tag: []u8) -> bool {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key)
	defer chacha20poly1305.reset(&ctx)
	iv: [12]u8
	iv[0] = nonce
	return chacha20poly1305.open(&ctx, dst, iv[:], transmute([]u8)ad, ct, tag)
}

@(private)
_q_arm :: proc(e: ^Engine, q: ^Remote_Q, hedged: bool) {
	now := prim.clock_mono_ns(e.cfg.clock) / 1_000_000
	if q.deadline == 0 {
		dl := e.cfg.search_deadline_ms if e.cfg.search_deadline_ms > 0 else DEFAULT_SEARCH_DEADLINE_MS
		q.deadline = now + dl
	}
	if !hedged && !q.plug {
		hm := e.cfg.search_hedge_ms if e.cfg.search_hedge_ms > 0 else DEFAULT_SEARCH_HEDGE_MS
		q.hedge_at = now + hm
	} else {
		q.hedge_at = 0
	}
	_remote_timer(e)
}

@(private)
_remote_timer :: proc(e: ^Engine) {
	r := &e.remote
	due := i64(max(i64))
	for q in r.queries {
		if q.finished || q.answered && len(q.refs) == 0 {
			continue
		}
		if q.hedge_at > 0 {
			due = min(due, q.hedge_at)
		}
		if q.deadline > 0 {
			due = min(due, q.deadline)
		}
	}
	if due == max(i64) {
		if r.timer != 0 {
			prim.timer_cancel(e.loop, r.timer)
			r.timer = 0
		}
		return
	}
	if r.timer != 0 && r.timer_at == due {
		return
	}
	if r.timer != 0 {
		prim.timer_cancel(e.loop, r.timer)
	}
	now := prim.clock_mono_ns(e.cfg.clock) / 1_000_000
	r.timer_at = due
	r.timer = prim.timer(e.loop, max(due - now, 0), e, _on_remote_timer)
}

@(private)
_on_remote_timer :: proc(l: ^prim.Loop, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	r := &e.remote
	r.timer = 0
	now := prim.clock_mono_ns(e.cfg.clock) / 1_000_000
	list := slice.clone(r.queries[:], context.temp_allocator)
	for q in list {
		if q.finished {
			continue
		}
		if q.deadline > 0 && now >= q.deadline {
			_q_finish(e, q, .Timeout)
			continue
		}
		if q.hedge_at > 0 && now >= q.hedge_at && !q.answered {
			q.hedge_at = 0
			if sp, ok := e.spaces[q.space]; ok {
				_q_next(e, q, sp)
			}
		}
	}
	_remote_timer(e)
}

@(private)
_remote_on_repl :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	r := _remote(e)
	m := Remote_Msg{space = sp.id, device = prim.Id(ev.device), tag = u64(ev.length), failed = ev.kind == .Undelivered}
	if len(ev.meta) > 0 {
		p, aerr := make([]u8, len(ev.meta), e.allocator)
		if aerr != nil {
			return
		}
		copy(p, ev.meta)
		m.payload = p
	}
	append(&r.inbox, m)
	_touch(e)
}

@(private)
_remote_presence :: proc(e: ^Engine, sp: ^Space, device: prim.Id, up: bool) {
	r := &e.remote
	if !r.init {
		return
	}
	if up {
		if device != e.self {
			_full_kick(e, sp)
		}
		return
	}
	list := slice.clone(r.queries[:], context.temp_allocator)
	for q in list {
		if q.finished || q.answered || q.space != sp.id {
			continue
		}
		hit := false
		for &f in q.flights {
			if f.live && f.device == device {
				crypto.zero_explicit(&f.key, size_of(f.key))
				f = {}
				hit = true
			}
		}
		if hit {
			_q_retry(e, q, sp, .Offline)
		}
	}
}

@(private)
_q_retry :: proc(e: ^Engine, q: ^Remote_Q, sp: ^Space, why: Search_State) {
	if sent, _ := _q_next(e, q, sp); sent {
		_remote_timer(e)
		return
	}
	append(&q.sources, Search_Source{state = why})
	_q_finish(e, q, why)
}

@(private)
_remote_step :: proc(e: ^Engine) {
	r := &e.remote
	if !r.init {
		return
	}
	for len(r.inbox) > 0 {
		inbox := r.inbox
		r.inbox = make([dynamic]Remote_Msg, e.allocator)
		for &m in inbox {
			if sp, ok := e.spaces[m.space]; ok && sp.open {
				if m.failed {
					_remote_undelivered(e, sp, m.device, m.tag)
				} else {
					_remote_direct(e, sp, m.device, m.tag, m.payload)
				}
			}
			if m.payload != nil {
				crypto.zero_explicit(raw_data(m.payload), len(m.payload))
				delete(m.payload, e.allocator)
			}
		}
		delete(inbox)
	}
	list := slice.clone(r.queries[:], context.temp_allocator)
	for q in list {
		if q.finished {
			continue
		}
		if q.ready_now {
			_q_finish(e, q, .Ok)
		} else if q.answered && q.due {
			q.due = false
			_q_verify(e, q)
		} else if q.awaiting && q.due {
			q.due = false
			if sp, ok := e.spaces[q.space]; ok {
				_q_start(e, q, sp)
			}
		}
	}
}

@(private)
_remote_undelivered :: proc(e: ^Engine, sp: ^Space, device: prim.Id, tag: u64) {
	q := _q_find(e, tag >> 2)
	if q == nil || q.finished || q.answered {
		return
	}
	slot := int(tag & 3)
	if slot >= REMOTE_FLIGHTS || !q.flights[slot].live || q.flights[slot].tag != tag {
		return
	}
	crypto.zero_explicit(&q.flights[slot].key, size_of(q.flights[slot].key))
	q.flights[slot] = {}
	_q_retry(e, q, sp, .Offline)
}

@(private)
_remote_direct :: proc(e: ^Engine, sp: ^Space, device: prim.Id, tag: u64, payload: []u8) {
	if len(payload) >= chacha20poly1305.TAG_SIZE {
		q := _q_find(e, tag >> 2)
		slot := int(tag & 3)
		if q != nil && slot < REMOTE_FLIGHTS && q.flights[slot].live && q.flights[slot].tag == tag && q.flights[slot].device == device {
			_remote_answer_in(e, sp, q, slot, payload)
			return
		}
	}
	if len(payload) > osync.WRAP_LEN + chacha20poly1305.TAG_SIZE {
		_remote_serve(e, sp, device, tag, payload)
	}
}

@(private)
_remote_answer_in :: proc(e: ^Engine, sp: ^Space, q: ^Remote_Q, slot: int, payload: []u8) {
	if q.answered || q.finished {
		return
	}
	f := &q.flights[slot]
	r := _remote(e)
	r.stats.answers += 1
	r.stats.bytes_in += u64(len(payload) + osync.FRAME_HEADER + osync.DIRECT_FIXED)
	if len(payload) < chacha20poly1305.TAG_SIZE {
		return
	}
	n := len(payload) - chacha20poly1305.TAG_SIZE
	plain := make([]u8, n, q.alloc)
	if !_aead_open(f.key[:], 1, REMOTE_AD_ANSWER, plain, payload[:n], payload[n:]) {
		return
	}
	ans, ok := _answer_decode(plain, q.alloc)
	if !ok {
		return
	}
	_q_accept(e, q, f.device, ans, false)
}

@(private)
_q_accept :: proc(e: ^Engine, q: ^Remote_Q, from: prim.Id, ans: Remote_Answer, plug: bool) {
	if ans.state == .Denied && !plug {
		for &x in q.flights {
			if x.live && x.device == from {
				crypto.zero_explicit(&x.key, size_of(x.key))
				x = {}
			}
		}
		append(&q.sources, Search_Source{device = from, state = .Denied})
		if sp, ok := e.spaces[q.space]; ok {
			_q_retry(e, q, sp, .Offline)
		}
		return
	}
	for &x in q.flights {
		crypto.zero_explicit(&x.key, size_of(x.key))
		x = {}
	}
	q.answered = true
	q.answer = ans
	q.answer_from = from
	q.hedge_at = 0
	if ans.state != .Ok {
		append(&q.sources, Search_Source{device = from, state = ans.state, behind = ans.behind})
		if plug {
			q.ready_now = true
			_touch(e)
			return
		}
		_q_finish(e, q, ans.state)
		return
	}
	for ref in ans.refs {
		x := ref
		if plug {
			x.ref = slice.clone(ref.ref, q.alloc)
			x.spans = slice.clone(ref.spans, q.alloc)
		}
		append(&q.refs, Pending_Ref{ref = x})
	}
	if plug {
		q.answer.refs = nil
		q.answer.cursor = slice.clone(ans.cursor, q.alloc)
		q.answer.marks = slice.clone(ans.marks, q.alloc)
		q.due = true
		_touch(e)
		return
	}
	_q_verify(e, q)
}

@(private)
READY_NO_REF :: 127

@(private)
_q_ready_data :: proc "contextless" (id: u64, ref: int) -> rawptr {
	return rawptr(uintptr(id << 7 | u64(ref & 127)))
}

@(private)
_q_ready :: proc(data: rawptr, e: ^Engine, err: Error) {
	x := u64(uintptr(data))
	q := _q_find(e, x >> 7)
	if q == nil || q.finished {
		return
	}
	if i := int(x & 127); i < len(q.refs) {
		q.refs[i].waiting = false
	}
	q.due = true
	_touch(e)
}

@(private)
_q_verify :: proc(e: ^Engine, q: ^Remote_Q) {
	pending := 0
	for &p, i in q.refs {
		if p.state != 0 {
			continue
		}
		if p.waiting {
			pending += 1
			continue
		}
		r := p.ref
		if len(r.ref) != 24 || r.kind != u8(Kind.Conversation) {
			p.state = 2
			continue
		}
		pos, _ := ref_rid(r.ref)
		ready := Ready{data = _q_ready_data(q.id, i), call = _q_ready}
		rid, gerr := record_rid(e, Object{q.space, r.object}, .Conversation, pos.seg, pos.off, ready)
		m: convo.Message
		err := gerr
		if err == .None {
			m, err = convo_message(e, Object{q.space, r.object}, convo.Position{msg = rid}, q.alloc, ready)
		}
		if err == .Pending || err == .Missing {
			p.tries += 1
			if p.tries > VERIFY_TRIES {
				p.state = 2
				continue
			}
			p.waiting = true
			pending += 1
			continue
		}
		if err != .None || m.redacted || m.id != rid {
			p.state = 2
			continue
		}
		var: search.Verdict
		found := false
		for b in m.blocks {
			if b.index != r.part {
				continue
			}
			found = true
			v, verr := search.verify_text(&e.index, q.query, b.text, search.Verify_Meta{object = r.object, participant = m.author, hlc = u64(m.hlc), kind = r.kind}, prim.clock_wall_ms(e.cfg.clock), q.alloc)
			if verr == .None {
				var = v
			}
			break
		}
		if !found || !var.ok {
			p.state = 2
			continue
		}
		p.state = 1
		_remote(e).stats.verified += 1
		append(&q.verified, search.Hit {
			object = r.object,
			participant = m.author,
			ref = _gen_ref(rid, q.alloc),
			part = r.part,
			kind = r.kind,
			hlc = m.hlc,
			score = r.score,
			snippet = var.snippet,
			snippet_at = var.snippet_at,
			matches = var.matches,
		})
	}
	if pending == 0 {
		_q_finish(e, q, .Ok)
	}
}

@(private)
_hit_less :: proc(sort: search.Sort, a, b: search.Hit) -> bool {
	if sort == .Relevance && a.score != b.score {
		return a.score > b.score
	}
	if a.hlc != b.hlc {
		return a.hlc > b.hlc
	}
	x, y := a.object, b.object
	if x != y {
		return string(x[:]) < string(y[:])
	}
	if string(a.ref) != string(b.ref) {
		return string(a.ref) < string(b.ref)
	}
	return a.part < b.part
}

@(private)
_q_finish :: proc(e: ^Engine, q: ^Remote_Q, state: Search_State) {
	if q.finished {
		return
	}
	q.finished = true
	r := &e.remote
	for &f in q.flights {
		crypto.zero_explicit(&f.key, size_of(f.key))
		f = {}
	}
	if q.plug && !q.answered && e.cfg.search_remote.cancel != nil {
		context = _outer(e)
		e.cfg.search_remote.cancel(e.cfg.search_remote.data, e, q.id)
	}
	Tagged :: struct {
		hit:  search.Hit,
		peer: bool,
	}
	all := make([dynamic]Tagged, q.alloc)
	for h in q.local.hits {
		append(&all, Tagged{hit = h})
	}
	rejected := 0
	for p in q.refs {
		if p.state == 2 {
			rejected += 1
		}
	}
	r.stats.rejected += u64(rejected)
	outer: for h in q.verified {
		for t in all {
			if t.hit.object == h.object && string(t.hit.ref) == string(h.ref) && t.hit.part == h.part {
				continue outer
			}
		}
		append(&all, Tagged{hit = h, peer = true})
	}
	Ctx :: struct {
		sort: search.Sort,
	}
	ctx := Ctx{q.req.sort}
	slice.sort_by_with_data(all[:], proc(a, b: Tagged, data: rawptr) -> bool {
		c := (^Ctx)(data)
		return _hit_less(c.sort, a.hit, b.hit)
	}, &ctx)
	limit := q.req.limit
	n := min(limit, len(all))
	hits := make([]search.Hit, n, q.alloc)
	nl, np := 0, 0
	for i in 0 ..< n {
		hits[i] = all[i].hit
		if all[i].peer {
			np += 1
		} else {
			nl += 1
		}
	}
	peer_more := q.answered && len(q.answer.cursor) > 0
	local_more := len(q.local.cursor) > 0
	partial := false
	behind := 0
	if q.answered {
		behind = q.answer.behind + _marks_behind(e, q)
		append(&q.sources, Search_Source{device = q.answer_from, state = .Ok if state == .Ok else state, behind = behind, hits = np, rejected = rejected})
		if behind > 0 {
			partial = true
		}
	} else if q.scope != .Local {
		sp, ok := e.spaces[q.space]
		if !(ok && _full_on(e, sp)) {
			partial = true
			if state == .Timeout {
				append(&q.sources, Search_Source{state = .Timeout})
			}
		}
	}
	nverified := 0
	for t in all {
		if t.peer {
			nverified += 1
		}
	}
	if n < len(all) || local_more || peer_more {
		out := make([dynamic]u8, q.alloc)
		w := prim.writer(&out)
		prim.write_u8(&w, CURSOR_REMOTE)
		local_all := len(all) - nverified
		if nl >= local_all {
			prim.write_u16le(&w, u16(len(q.local.cursor)))
			prim.write_raw(&w, q.local.cursor)
			prim.write_u16le(&w, 0)
		} else {
			prim.write_u16le(&w, u16(len(q.local_prev)))
			prim.write_raw(&w, q.local_prev)
			prim.write_u16le(&w, u16(q.local_skip + nl))
		}
		pin := q.answer_from
		prim.write_raw(&w, pin[:])
		if np >= nverified + rejected {
			prim.write_u16le(&w, u16(len(q.answer.cursor)))
			prim.write_raw(&w, q.answer.cursor)
			prim.write_u16le(&w, 0)
		} else {
			prim.write_u16le(&w, u16(len(q.peer_prev)))
			prim.write_raw(&w, q.peer_prev)
			prim.write_u16le(&w, u16(q.peer_skip + np))
		}
		if !(n == len(all) && !local_more && !(q.answered && len(q.answer.cursor) > 0)) {
			q.result.cursor = out[:]
		}
	}
	q.result.hits = hits
	q.result.partial = partial
	q.result.behind = behind
	q.result.sources = q.sources[:]
	r.current = q
	if q.done.call != nil {
		res := Result{tick = u64(len(hits))}
		err := Error.None
		{
			context = _outer(e)
			q.done.call(q.done.data, e, &res, err)
		}
	}
	r.current = nil
	_q_free_list(e, q)
	_remote_timer(e)
}

@(private)
_q_free_list :: proc(e: ^Engine, q: ^Remote_Q) {
	r := &e.remote
	for x, i in r.queries {
		if x == q {
			ordered_remove(&r.queries, i)
			break
		}
	}
	_q_free(e, q)
}

@(private)
_q_free :: proc(e: ^Engine, q: ^Remote_Q) {
	runtime.arena_destroy(&q.arena)
	free(q, e.allocator)
}

@(private)
_answer_decode :: proc(b: []u8, allocator: runtime.Allocator) -> (a: Remote_Answer, ok: bool) {
	rd := prim.reader(b)
	if prim.read_u8(&rd) != REMOTE_VERSION || prim.read_u8(&rd) != REMOTE_ANSWER {
		return
	}
	a.state = Search_State(min(prim.read_u8(&rd), u8(Search_State.Cancelled)))
	a.behind = int(prim.read_u32le(&rd))
	n := int(prim.read_u16le(&rd))
	a.cursor = prim.read_raw(&rd, n)
	nr := int(prim.read_u16le(&rd))
	if nr > REMOTE_REF_MAX {
		return
	}
	refs := make([]Remote_Ref, nr, allocator)
	for &x in refs {
		prim.read_fixed(&rd, x.object[:])
		rl := int(prim.read_u8(&rd))
		x.ref = prim.read_raw(&rd, rl)
		x.part = prim.read_u32le(&rd)
		x.kind = prim.read_u8(&rd)
		x.hlc = prim.read_u64le(&rd)
		x.score = transmute(f64)prim.read_u64le(&rd)
		ns := int(prim.read_u8(&rd))
		spans := make([]search.Match, ns, allocator)
		for &s in spans {
			s.start = prim.read_u32le(&rd)
			s.len = prim.read_u32le(&rd)
		}
		x.spans = spans
	}
	a.refs = refs
	nm := int(prim.read_u16le(&rd))
	marks := make([]Remote_Mark, min(nm, 4096), allocator)
	for &m in marks {
		prim.read_fixed(&rd, m.object[:])
		prim.read_fixed(&rd, m.device[:])
		m.position = i64(prim.read_u64le(&rd))
	}
	a.marks = marks
	return a, prim.reader_ok(&rd) && prim.reader_remaining(&rd) == 0 && nm <= 4096
}

@(private)
_remote_serve :: proc(e: ^Engine, sp: ^Space, from: prim.Id, tag: u64, payload: []u8) {
	if len(payload) < osync.WRAP_LEN + chacha20poly1305.TAG_SIZE {
		return
	}
	serving := _full_on(e, sp) && _index_open(e) == .None
	ck: osync.Content_Key
	if e.keyring.unwrap(e.keyring.data, payload[:osync.WRAP_LEN], &ck) != .None {
		return
	}
	key := ck.key
	defer crypto.zero_explicit(&key, size_of(key))
	crypto.zero_explicit(&ck, size_of(ck))
	body := payload[osync.WRAP_LEN:]
	n := len(body) - chacha20poly1305.TAG_SIZE
	plain := make([]u8, n, context.temp_allocator)
	if !_aead_open(key[:], 0, REMOTE_AD_QUERY, plain, body[:n], body[n:]) {
		return
	}
	if n < 2 + osync.CARD_LEN + 32 + 64 {
		return
	}
	sig := plain[n - 64:]
	signed := plain[:n - 64]
	rd := prim.reader(signed)
	if prim.read_u8(&rd) != REMOTE_VERSION || prim.read_u8(&rd) != REMOTE_QUERY {
		return
	}
	card := prim.read_raw(&rd, osync.CARD_LEN)
	proof: [32]u8
	prim.read_fixed(&rd, proof[:])
	limit := int(prim.read_u16le(&rd))
	skip := int(prim.read_u16le(&rd))
	sort := search.Sort(min(prim.read_u8(&rd), 1))
	now := prim.Hlc(prim.read_u64le(&rd))
	cl := int(prim.read_u16le(&rd))
	cursor := prim.read_raw(&rd, cl)
	ql := int(prim.read_u16le(&rd))
	query := string(prim.read_raw(&rd, ql))
	if !prim.reader_ok(&rd) || prim.reader_remaining(&rd) != 0 {
		return
	}
	ident, verr := osync.card_verify(card)
	if verr != .None || ident.id != osync.Device_Id(from) {
		return
	}
	msg := _remote_signed(payload[:osync.WRAP_LEN], e.self, signed)
	if !osync.signature_verify(ident.sign, msg, sig) {
		return
	}
	want := _member_proof(sp, payload[:osync.WRAP_LEN], e.self)
	member := !sp.keyless && crypto.compare_constant_time(want[:], proof[:]) == 1
	if !serving {
		deny := [?]u8{REMOTE_VERSION, REMOTE_ANSWER, u8(Search_State.Denied), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
		reply: [len(deny) + chacha20poly1305.TAG_SIZE]u8
		_aead_seal(key[:], 1, REMOTE_AD_ANSWER, reply[:len(deny)], reply[len(deny):], deny[:])
		osync.replicator_direct(&sp.repl, osync.Device_Id(from), tag, reply[:])
		return
	}
	limit = clamp(limit, 1, REMOTE_REF_MAX)
	req := search.Request{limit = min(limit + skip, search.MAX_LIMIT), cursor = cursor, sort = sort, now = now}
	res, serr := search.search(&e.index, query, req, context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&out)
	prim.write_u8(&w, REMOTE_VERSION)
	prim.write_u8(&w, REMOTE_ANSWER)
	state := Search_State.Ok if serr == .None else .Failed
	prim.write_u8(&w, u8(state))
	prim.write_u32le(&w, u32(min(_remote(e).behind[sp.id], int(max(u32)))))
	hits := res.hits[min(skip, len(res.hits)):] if serr == .None else nil
	prim.write_u16le(&w, u16(len(res.cursor)))
	prim.write_raw(&w, res.cursor)
	count_at := len(out)
	prim.write_u16le(&w, 0)
	count := 0
	objects := make([dynamic]prim.Id, context.temp_allocator)
	for h in hits {
		if count >= limit || h.kind != u8(Kind.Conversation) || len(h.ref) != 24 {
			continue
		}
		if !member && !_remote_participant(e, h.object, from) {
			continue
		}
		pin := h.object
		prim.write_raw(&w, pin[:])
		prim.write_u8(&w, u8(len(h.ref)))
		prim.write_raw(&w, h.ref)
		prim.write_u32le(&w, h.part)
		prim.write_u8(&w, h.kind)
		prim.write_u64le(&w, u64(h.hlc))
		prim.write_u64le(&w, transmute(u64)h.score)
		ns := min(len(h.matches), 32)
		prim.write_u8(&w, u8(ns))
		for m in h.matches[:ns] {
			prim.write_u32le(&w, u32(h.snippet_at) + m.start)
			prim.write_u32le(&w, m.len)
		}
		count += 1
		dup := false
		for o in objects {
			if o == h.object {
				dup = true
				break
			}
		}
		if !dup {
			append(&objects, h.object)
		}
	}
	out[count_at] = u8(count)
	out[count_at + 1] = u8(count >> 8)
	marks_at := len(out)
	prim.write_u16le(&w, 0)
	nmarks := 0
	for o in objects {
		rec, found, _ := _rec_get(e, o)
		if !found {
			continue
		}
		for m in rec.members {
			if nmarks >= 1024 {
				break
			}
			oo, dd := o, m.device
			prim.write_raw(&w, oo[:])
			prim.write_raw(&w, dd[:])
			mpos, _ := search.position(&e.index, _source_id(o, m.device))
			prim.write_u64le(&w, u64(mpos))
			nmarks += 1
		}
	}
	out[marks_at] = u8(nmarks)
	out[marks_at + 1] = u8(nmarks >> 8)
	if w.err != .None || len(out) + chacha20poly1305.TAG_SIZE > osync.DIRECT_MAX {
		return
	}
	reply := make([]u8, len(out) + chacha20poly1305.TAG_SIZE, context.temp_allocator)
	_aead_seal(key[:], 1, REMOTE_AD_ANSWER, reply[:len(out)], reply[len(out):], out[:])
	_remote(e).stats.served += 1
	osync.replicator_direct(&sp.repl, osync.Device_Id(from), tag, reply)
}

@(private)
_remote_participant :: proc(e: ^Engine, object: prim.Id, device: prim.Id) -> bool {
	rec, found, _ := _rec_get(e, object)
	if !found {
		return false
	}
	return _rec_member(&rec, device) >= 0
}

@(private)
_entry_u64 :: proc(en: ^omap.Entry, tag: u32) -> (v: u64, ok: bool) {
	b, found := omap.entry_register(en, tag)
	if !found {
		return 0, false
	}
	return omap.value_u64(b)
}

@(private)
_remote_pending :: proc(e: ^Engine) -> bool {
	r := &e.remote
	if !r.init {
		return false
	}
	if len(r.inbox) > 0 {
		return true
	}
	for q in r.queries {
		if (q.ready_now || q.due) && !q.finished {
			return true
		}
	}
	for _, rs in r.restores {
		if rs.failed || rs.importing || (rs.head && len(rs.oids) == 0) {
			return true
		}
	}
	return false
}

search_remote_answer_bytes :: proc(e: ^Engine, id: u64, payload: []u8) -> Error {
	context = context_for(e)
	q := _q_find(e, id)
	if q == nil || q.answered || !q.plug {
		return .Not_Found
	}
	ans, ok := _answer_decode(slice.clone(payload, q.alloc), q.alloc)
	if !ok {
		return .Invalid
	}
	_q_accept(e, q, {}, ans, false)
	return .None
}

remote_query_encode :: proc(q: ^Remote_Query, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	w := prim.writer(&out)
	prim.write_u8(&w, REMOTE_VERSION)
	s := q.space
	prim.write_raw(&w, s[:])
	prim.write_u16le(&w, u16(clamp(q.limit, 0, int(max(u16)))))
	prim.write_u16le(&w, u16(clamp(q.skip, 0, int(max(u16)))))
	prim.write_u8(&w, u8(q.sort))
	prim.write_u64le(&w, u64(q.now))
	prim.write_u16le(&w, u16(len(q.cursor)))
	prim.write_raw(&w, q.cursor)
	prim.write_u16le(&w, u16(min(len(q.query), int(max(u16)))))
	prim.write_raw(&w, transmute([]u8)q.query)
	return out[:]
}

@(private)
_marks_behind :: proc(e: ^Engine, q: ^Remote_Q) -> int {
	sp, ok := e.spaces[q.space]
	if !ok || !sp.repl_on || len(q.answer.marks) == 0 {
		return 0
	}
	behind := make([dynamic]prim.Id, context.temp_allocator)
	outer: for m in q.answer.marks {
		for b in behind {
			if b == m.object {
				continue outer
			}
		}
		known := i64(-1)
		if m.device == e.self {
			if h, hok := e.handles[m.object]; hok {
				if r := _own_reader(h); r != nil {
					known = journal.reader_end(r)
				}
			}
		} else {
			sc := _object_scope(sp, m.object)
			known = osync.replicator_relay_length(&sp.repl, &sc, osync.Device_Id(m.device), _seg_name(.Conversation, m.object), 0)
			osync.scope_clear(&sc)
		}
		if known > m.position {
			append(&behind, m.object)
		}
	}
	return len(behind)
}
