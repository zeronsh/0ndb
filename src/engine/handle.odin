package engine

import "../convo"
import "../fs"
import "../journal"
import omap "../map"
import "../obj"
import "../prim"
import osync "../sync"

@(private)
MAX_TRIES :: 16

Change_Kind :: enum u8 {
	Data,
	Local,
	Keys,
	Members,
	Quarantined,
	Redacted,
}

Change_Kinds :: bit_set[Change_Kind;u8]

@(private)
Change :: struct {
	space: prim.Id,
	kinds: Change_Kinds,
}

Ready :: struct {
	data:  rawptr,
	call:  proc(data: rawptr, e: ^Engine, err: Error),
	fresh: bool,
}

@(private)
Waiter :: struct {
	space:  prim.Id,
	object: prim.Id,
	ready:  Ready,
	cmd:    ^Pending_Cmd,
	tries:  int,
	tick:   u64,
}

@(private)
Seg :: struct {
	device:  prim.Id,
	rep:     ^journal.Replica,
	jr:      journal.Reader,
	tree:    ^Remote_Tree,
	in_view: bool,
	waiting: bool,
	probing: bool,
	probed:  bool,
	follow:  bool,
	live:    bool,
	check:   Seg_Check,
	chain:   journal.Chain,
}

@(private)
Seg_Check :: struct {
	keyring: osync.Keyring,
	signer:  osync.Identity,
}

Handle :: struct {
	e:          ^Engine,
	sp:         ^Space,
	id:         prim.Id,
	kind:       Kind,
	name:       string,
	scope:      osync.Scope,
	view:       obj.View,
	view_init:  bool,
	segs:       [dynamic]^Seg,
	own:        bool,
	created:    prim.Hlc,
	w_open:     bool,
	cw:         convo.Writer,
	mw:         omap.Writer,
	hist:       ^fs.History,
	hist_chain: bool,
	own_tree:   ^Own_Tree,
	chain:      journal.Chain,
	published:  i64,
	pins:       int,
	used:       u64,
	table:      omap.Table,
	table_open: bool,
	local:      bool,
	grouped:    bool,
	drafts:     [dynamic]^Draft_View,
	dgen:       u64,
	dview:      i64,
	ddur:       i64,
	dpub:       i64,
	dclosed:    [DRAFT_CLOSED]Draft_Key,
	dclosed_n:  int,
}

@(private)
_group_follow :: proc(h: ^Handle, full: bool) {
	if h.grouped || !h.sp.repl_on || h.id == h.sp.catalog {
		return
	}
	if osync.replicator_follow_segments(&h.sp.repl, &h.scope, h.name, 0, full) == .None {
		h.grouped = true
	}
}

@(private)
_object_changed :: proc(e: ^Engine, space: prim.Id, id: prim.Id, kind: Change_Kind) {
	if prim.id_is_zero(id) {
		return
	}
	c := e.changed[id]
	c.space = space
	c.kinds += {kind}
	e.changed[id] = c
	_touch(e)
}

@(private)
_handle_get :: proc(e: ^Engine, o: Object, kind: Kind) -> (h: ^Handle, err: Error) {
	if x, ok := e.handles[o.id]; ok {
		if x.kind != kind || x.sp.id != o.space {
			return nil, .Invalid
		}
		x.used = e.tick
		_lru_touch(e, x)
		return x, .None
	}
	sp := _space_open(e, o.space) or_return
	if x, ok := e.handles[o.id]; ok {
		if x.kind != kind || x.sp.id != o.space {
			return nil, .Invalid
		}
		x.used = e.tick
		_lru_touch(e, x)
		return x, .None
	}
	rec, found := _rec_get(e, o.id) or_return
	if found && (rec.space != o.space || rec.kind != kind) {
		return nil, .Invalid
	}
	h = new(Handle, e.allocator)
	h.e = e
	h.sp = sp
	h.id = o.id
	h.kind = kind
	h.used = e.tick
	h.scope = _object_scope(sp, o.id)
	h.segs = make([dynamic]^Seg, e.allocator)
	h.name = _clone(_seg_name(kind, o.id), e.allocator) or_return
	if kind == .Conversation || kind == .Map {
		obj.view_init(&h.view, o.id, e.allocator)
		h.view.self = e.self
		h.view_init = true
	}
	e.handles[o.id] = h
	append(&e.lru, h)
	e.stats.opened += 1
	if e.settle_timer == 0 && !e.in_tick {
		_settle_arm(e)
	}
	defer if err != .None {
		was := e.closing
		e.closing = true
		_handle_close(e, h)
		e.closing = was
		h = nil
	}
	if found {
		h.created = rec.created
		if rec.own {
			h.own = true
			_handle_open_writer(h) or_return
		}
		for m in rec.members {
			_handle_add_member(h, m.device, m.keys_epoch)
		}
	}
	if o.id != sp.catalog {
		_catalog_members(e, h)
	}
	if kind != .Conversation {
		_group_follow(h, true)
		for s in h.segs {
			_follow(e, h, s, true)
		}
	}
	return h, .None
}

@(private)
_lru_touch :: proc(e: ^Engine, h: ^Handle) {
	n := len(e.lru)
	if n > 0 && e.lru[n - 1] == h {
		return
	}
	for x, i in e.lru {
		if x == h {
			ordered_remove(&e.lru, i)
			break
		}
	}
	append(&e.lru, h)
}

@(private)
_own_path :: proc(e: ^Engine, h: ^Handle) -> (path: string, err: Error) {
	if h.kind == .Text || h.kind == .File_Tree {
		d := _obj_dir(e, h.id, context.temp_allocator) or_return
		return _join(context.temp_allocator, d, "hist", "fs.journal")
	}
	return _seg_path(e, h.id)
}

@(private)
_own_len :: proc(h: ^Handle) -> i64 {
	if !h.w_open {
		return 0
	}
	switch h.kind {
	case .Conversation:
		return obj.writer_durable(&h.cw.core)
	case .Map:
		return obj.writer_durable(&h.mw.core)
	case .Text, .File_Tree:
		if h.hist != nil && !h.hist.awake && fs.history_wake(h.hist) != .None {
			return 0
		}
		if h.hist != nil {
			return journal.journal_durable_len(&h.hist.journal)
		}
	}
	return 0
}

@(private)
_journal_opts :: proc(h: ^Handle) -> journal.Options {
	e := h.e
	floor: i64
	if h.sp.repl_on {
		floor, _ = osync.replicator_floor(&h.sp.repl, &h.scope, h.name, 0)
	}
	stream := osync.stream_id(&h.scope, e.self, h.name, 0)
	h.chain = journal.Chain {
		seed   = osync.chain_seed(stream),
		keys   = osync.keytree_provider(&h.own_tree.tree),
		signer = osync.keyring_signer(&e.keyring),
	}
	return journal.Options{keep_at_least = floor, chain = &h.chain}
}

@(private)
_handle_open_writer :: proc(h: ^Handle) -> Error {
	if h.w_open {
		return .None
	}
	e := h.e
	if h.kind == .Conversation || h.kind == .Map {
		if !prim.exists(e.vfs, _seg_path(e, h.id) or_return) {
			return .None
		}
	}
	if h.own_tree == nil {
		h.own_tree = _own_tree_get(e, h.sp, h.id, h.kind, &h.scope, false) or_return
	}
	switch h.kind {
	case .Conversation:
		path := _seg_path(e, h.id) or_return
		if !prim.exists(e.vfs, path) {
			return .None
		}
		opts := _journal_opts(h)
		gen := _gen_take(e) or_return
		_, err := convo.writer_open(&h.cw, &h.view, e.vfs, path, h.id, e.self, gen, opts, e.allocator, _obj_clock(e))
		_oerr(err) or_return
		h.published = obj.writer_durable(&h.cw.core)
	case .Map:
		path := _seg_path(e, h.id) or_return
		if !prim.exists(e.vfs, path) {
			return .None
		}
		opts := _journal_opts(h)
		gen := _gen_take(e) or_return
		_, err := omap.writer_open(&h.mw, &h.view, e.vfs, path, h.id, e.self, gen, opts, e.allocator, _obj_clock(e))
		_oerr(err) or_return
		h.published = obj.writer_durable(&h.mw.core)
		_map_own_check(e, h) or_return
	case .Text, .File_Tree:
		_hist_open(h) or_return
		h.published = journal.journal_durable_len(&h.hist.journal)
	}
	h.w_open = true
	_own_tree_epoch(e, h)
	return .None
}

@(private)
_handle_create_writer :: proc(h: ^Handle, convo_settings: convo.Settings = {}, settings: []u8 = nil) -> Error {
	if h.w_open {
		return .None
	}
	e := h.e
	if h.sp.keyless {
		if a, ok := h.sp.grant_access[h.id]; !ok || .Write not_in a {
			return .Permission
		}
	}
	rec, found := _rec_get(e, h.id) or_return
	if found && rec.own {
		h.own = true
		_handle_open_writer(h) or_return
		if h.w_open {
			return .None
		}
	}
	if !found {
		rec = Obj_Rec{space = h.sp.id, kind = h.kind, members = make([dynamic]Member, context.temp_allocator)}
	}
	dir := _obj_dir(e, h.id) or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	if h.own_tree == nil {
		h.own_tree = _own_tree_get(e, h.sp, h.id, h.kind, &h.scope, true) or_return
	}
	created := hlc_now(e)
	if h.created == 0 {
		h.created = created
	}
	if h.own_tree.dirty {
		_own_tree_store(e, h.own_tree) or_return
		h.own_tree.dirty = false
	}
	if !rec.own && !((h.kind == .Text || h.kind == .File_Tree) && _ckpt_waiting(h)) {
		rec.own = true
		if rec.created == 0 {
			rec.created = h.created
		}
		_rec_put(e, h.id, &rec) or_return
		_registry_flush(e) or_return
	}
	switch h.kind {
	case .Conversation:
		path := _seg_path(e, h.id) or_return
		opts := _journal_opts(h)
		gen := _gen_take(e) or_return
		_oerr(convo.writer_create(&h.cw, &h.view, e.vfs, path, h.id, e.self, gen, created, convo_settings, opts, e.allocator, _obj_clock(e))) or_return
	case .Map:
		path := _seg_path(e, h.id) or_return
		opts := _journal_opts(h)
		gen := _gen_take(e) or_return
		_oerr(omap.writer_create(&h.mw, &h.view, e.vfs, path, h.id, e.self, gen, created, settings, opts, e.allocator, _obj_clock(e))) or_return
		_map_own_check(e, h) or_return
	case .Text, .File_Tree:
		if _ckpt_waiting(h) {
			return .Missing
		}
		h.own = true
		if h.hist != nil && !h.hist_chain {
			if h.own_tree == nil {
				if t, terr := _own_tree_get(e, h.sp, h.id, h.kind, &h.scope, false); terr == .None {
					h.own_tree = t
				}
			}
			_ferr(fs.history_reconfigure(h.hist, _hist_options(h))) or_return
			h.hist_chain = h.own_tree != nil
		}
		_hist_open(h) or_return
	}
	h.w_open = true
	h.own = true
	h.published = 0
	rec.own = true
	for &m in rec.members {
		if h.sp.repl_on {
			n := osync.replicator_relay_length(&h.sp.repl, &h.scope, m.device, h.name, 0)
			m.scanned = max(m.scanned, n)
		}
	}
	_owned_add(e, h.sp, h.id, h.kind)
	_group_follow(h, h.kind != .Conversation)
	if rec.created == 0 {
		rec.created = h.created
	}
	_rec_put(e, h.id, &rec) or_return
	_dirty_keys(e, h.sp, h.id, h.kind, h.scope, h.own_tree)
	if h.own_tree != nil {
		_pending_set(e, h.sp.id, h.id, 0)
	}
	_handle_mark(h)
	if h.id != h.sp.catalog {
		_catalog_participant(e, h.sp, h.id, h.kind)
	}
	return .None
}

@(private)
_handle_mark :: proc(h: ^Handle) {
	h.local = true
	_object_changed(h.e, h.sp.id, h.id, .Local)
}

@(private)
_handle_add_member :: proc(h: ^Handle, device: prim.Id, keys_epoch: u64) {
	e := h.e
	sp := h.sp
	if device == e.self || !sp.repl_on {
		return
	}
	for s in h.segs {
		if s.device == device {
			return
		}
	}
	rep, aerr := osync.replicator_acquire(&sp.repl, &h.scope, device, h.name, 0)
	if aerr != .None {
		return
	}
	seg := new(Seg, e.allocator)
	seg.device = device
	seg.rep = rep
	journal.replica_reader(rep, &seg.jr, e.allocator)
	rt, terr := _remote_tree_get(e, sp, &h.scope, device, h.name, keys_epoch)
	if terr == .None {
		rt.refs += 1
		seg.tree = rt
	}
	append(&h.segs, seg)
	if journal.replica_length(rep) == 0 {
		seg.waiting = !osync.replicator_confirmed_empty(&sp.repl, &h.scope, device, h.name, 0)
		osync.replicator_want_tail(&sp.repl, &h.scope, device, h.name, 0)
		e.stats.fetches += 1
	}
	_seg_enter(h, seg)
}

@(private)
_seg_enter :: proc(h: ^Handle, seg: ^Seg) {
	if seg.in_view || seg.tree == nil || !seg.tree.loaded {
		return
	}
	e := h.e
	if e.cfg.verify_chains {
		id, known := h.sp.identities[seg.device]
		if !known {
			if h.sp.repl_on {
				_need_add(e, h.sp, .Card, seg.device, h.name)
			}
			return
		}
		seg.check = Seg_Check{keyring = e.keyring, signer = id}
		seg.chain = journal.Chain {
			seed = osync.chain_seed(osync.stream_id(&h.scope, seg.device, h.name, 0)),
			keys = osync.keytree_provider(&seg.tree.tree),
			verifier = journal.Verifier{data = &seg.check, verify = _seg_sig_verify},
		}
		journal.reader_set_chain(&seg.jr, &seg.chain)
	}
	if h.sp.mode == .End_To_End {
		journal.reader_set_keys(&seg.jr, osync.keytree_provider(&seg.tree.tree))
	}
	if h.view_init {
		if _, err := obj.view_add(&h.view, seg.device, &seg.jr); err != .None {
			return
		}
	}
	seg.in_view = true
	_index_item_add(e, h.sp.id, h.id, h.kind)
	_object_changed(e, h.sp.id, h.id, .Keys)
}

@(private)
_seg_sig_verify :: proc(data: rawptr, msg: []u8, sig: []u8) -> bool {
	c := (^Seg_Check)(data)
	if c.keyring.verify != nil {
		return c.keyring.verify(c.keyring.data, &c.signer, msg, sig)
	}
	return osync.signature_verify(c.signer.sign, msg, sig)
}

@(private)
_handle_remote_grew :: proc(h: ^Handle, device: prim.Id) {
	for s in h.segs {
		if s.device == device {
			s.waiting = false
			s.probing = false
			if !s.in_view && s.tree != nil && !s.tree.loaded {
				_remote_tree_load(h.e, h.sp, s.tree)
			}
			_seg_enter(h, s)
			if h.view_init && s.in_view {
				if i := obj.view_find(&h.view, device); i >= 0 {
					h.view.segs[i].tail_end = -1
				}
			}
			return
		}
	}
}

@(private)
_handle_probe :: proc(h: ^Handle) {
	sp := h.sp
	if !sp.repl_on || !sp.connected {
		return
	}
	for s in h.segs {
		if s.probed || s.waiting || journal.replica_length(s.rep) == 0 {
			continue
		}
		s.probed = true
		if osync.replicator_current(&sp.repl, &h.scope, s.device, h.name, 0) {
			continue
		}
		s.probing = true
		osync.replicator_want_tail(&sp.repl, &h.scope, s.device, h.name, 0)
		h.e.stats.fetches += 1
	}
}

@(private)
_probes_settle :: proc(e: ^Engine, sp: ^Space, only := prim.Id{}) {
	for _, h in e.handles {
		if h.sp != sp || (!prim.id_is_zero(only) && h.id != only) {
			continue
		}
		settled := false
		for s in h.segs {
			if s.probing {
				s.probing = false
				s.waiting = false
				settled = true
			}
		}
		if settled {
			_object_changed(e, sp.id, h.id, .Data)
		}
	}
}

@(private)
_handle_rekey :: proc(h: ^Handle, device: prim.Id, rt: ^Remote_Tree) {
	for s in h.segs {
		if s.device == device {
			if s.in_view && rt.loaded && h.sp.mode == .End_To_End {
				journal.reader_set_keys(&s.jr, osync.keytree_provider(&rt.tree))
			}
			_seg_enter(h, s)
			for v in h.drafts {
				if v.device == device && v.gap && !v.pulling {
					_draft_pull(h.e, h, device, v)
				}
			}
			_object_changed(h.e, h.sp.id, h.id, .Data)
			return
		}
	}
}

@(private)
_handle_refresh :: proc(h: ^Handle) {
	for s in h.segs {
		if !s.in_view {
			if s.tree != nil && !s.tree.loaded {
				_remote_tree_load(h.e, h.sp, s.tree)
			}
			_seg_enter(h, s)
		}
	}
}

@(private)
_handle_waiting :: proc(h: ^Handle, fresh := false) -> bool {
	if fresh {
		_handle_probe(h)
	}
	for s in h.segs {
		if s.waiting || (fresh && s.probing) {
			return true
		}
		if !s.in_view && s.tree != nil && !s.tree.absent {
			return true
		}
		if s.follow && h.kind != .Conversation && h.sp.repl_on && h.sp.connected && osync.replicator_catching_up(&h.sp.repl, &h.scope, s.device, h.name, 0) {
			return true
		}
	}
	return false
}

@(private)
_handle_commit :: proc(e: ^Engine, h: ^Handle) -> Error {
	if !h.w_open {
		return .None
	}
	err: Error
	switch h.kind {
	case .Conversation:
		err = _oerr(convo.writer_commit(&h.cw))
	case .Map:
		err = _oerr(omap.writer_commit(&h.mw))
	case .Text, .File_Tree:
		if h.hist != nil && h.hist.awake {
			err = _jerr(journal.journal_commit(&h.hist.journal))
		}
	}
	if err == .Busy {
		h.local = true
		return .Busy
	}
	if err != .None {
		_fatal(e, err)
		return err
	}
	if h.kind == .Conversation {
		_draft_own_feed(e, h)
	}
	n := _own_len(h)
	if n > h.published {
		path, perr := _own_path(e, h)
		if perr == .None {
			_dirty_add(e, h, path, n)
			_content_publish(e, h)
			_pending_set(e, h.sp.id, h.id, n)
			_index_item_add(e, h.sp.id, h.id, h.kind)
			h.published = n
		}
	}
	return .None
}

@(private)
_handles_commit :: proc(e: ^Engine) {
	for h in e.lru {
		if h.local {
			h.local = false
			if _handle_commit(e, h) == .Busy {
				h.local = true
			}
		}
	}
}

@(private)
_handle_close :: proc(e: ^Engine, h: ^Handle) -> Error {
	if h.hist != nil && !e.closing && fs.history_durable_mark(h.hist) > h.hist.durable {
		return .Busy
	}
	if err := _handle_commit(e, h); err == .Busy && !e.closing {
		return err
	}
	if h.w_open {
		switch h.kind {
		case .Conversation:
			convo.writer_close(&h.cw)
		case .Map:
			omap.writer_close(&h.mw)
		case .Text, .File_Tree:
		}
		h.w_open = false
	}
	if h.hist != nil {
		fs.history_set_streams(h.hist, {})
		fs.history_release(h.hist)
		h.hist = nil
	}
	if h.table_open {
		omap.table_close(&h.table)
		h.table_open = false
	}
	if h.view_init {
		obj.view_destroy(&h.view)
		h.view_init = false
	}
	keep_follow := h.id == h.sp.catalog || _subscribed(e, h.id) || h.own
	if !keep_follow && h.grouped && h.sp.repl_on {
		osync.replicator_unfollow_segments(&h.sp.repl, &h.scope, h.name, 0)
	}
	_drafts_free(h)
	for s in h.segs {
		journal.reader_close(&s.jr)
		if h.sp.repl_on && s.live && !_subscribed(e, h.id) {
			osync.replicator_live_follow(&h.sp.repl, &h.scope, s.device, h.name, 0, false)
		}
		if h.sp.repl_on {
			if s.follow && !keep_follow {
				osync.replicator_unfollow(&h.sp.repl, &h.scope, s.device, h.name, 0)
			}
			osync.replicator_release(&h.sp.repl, &h.scope, s.device, h.name, 0)
		}
		if s.tree != nil && s.tree.refs > 0 {
			s.tree.refs -= 1
		}
		free(s, e.allocator)
	}
	delete(h.segs)
	if h.own_tree != nil {
		_own_tree_unref(e, h.own_tree)
		h.own_tree = nil
	}
	osync.scope_clear(&h.scope)
	if cur, ok := e.handles[h.id]; ok && cur == h {
		delete_key(&e.handles, h.id)
	}
	for x, i in e.lru {
		if x == h {
			ordered_remove(&e.lru, i)
			break
		}
	}
	delete(h.name, e.allocator)
	free(h, e.allocator)
	e.stats.evicted += 1
	return .None
}

@(private)
_handles_sweep :: proc(e: ^Engine, keep: int) {
	i := 0
	for len(e.lru) > max(keep, 0) && i < len(e.lru) {
		h := e.lru[i]
		if keep >= 0 && h.pins > 0 {
			i += 1
			continue
		}
		if _handle_close(e, h) != .None {
			i += 1
		}
	}
}

@(private)
_handles_sweep_space :: proc(e: ^Engine, sp: ^Space) {
	i := 0
	for i < len(e.lru) {
		h := e.lru[i]
		if h.sp != sp {
			i += 1
			continue
		}
		if _handle_close(e, h) != .None {
			i += 1
		}
	}
}

@(private)
_handle_want :: proc(h: ^Handle) -> (fetched: bool) {
	e := h.e
	sp := h.sp
	if h.view_init {
		for u in obj.view_unknown(&h.view) {
			if u == e.self {
				continue
			}
			_member_seen(e, sp, h.id, h.kind, u)
			_handle_add_member(h, u, 0)
			fetched = true
		}
		if sp.repl_on {
			for w in obj.view_wanted(&h.view) {
				r := [1]journal.Range{{w.from, w.to}}
				if osync.replicator_want(&sp.repl, &h.scope, w.seg, h.name, 0, r[:]) == .None {
					fetched = true
					e.stats.fetches += 1
				}
				if osync.replicator_relay_length(&sp.repl, &h.scope, w.seg, h.name, 0) < 0 {
					osync.replicator_want_tail(&sp.repl, &h.scope, w.seg, h.name, 0, 1)
				}
			}
		}
		obj.view_reset(&h.view)
	}
	for s in h.segs {
		if s.waiting || s.probing || (!s.in_view && s.tree != nil && !s.tree.absent) {
			fetched = true
		}
	}
	if _ckpt_waiting(h) {
		fetched = true
	}
	return
}

@(private)
_replica_covers :: proc(rep: ^journal.Replica, n: i64) -> bool {
	at: i64
	for r in journal.replica_have(rep) {
		if r.from > at {
			return false
		}
		at = max(at, r.to)
	}
	return at >= n
}

@(private)
_wait :: proc(e: ^Engine, h: ^Handle, ready: Ready, cmd: ^Pending_Cmd = nil, tries := 0) -> Error {
	fetched := _handle_want(h) || _content_pending(e, h.id)
	if !fetched && h.sp.repl_on {
		for sg in h.segs {
			if !sg.in_view {
				fetched = true
				break
			}
			n := osync.replicator_relay_length(&h.sp.repl, &h.scope, sg.device, h.name, 0)
			if n < 0 || !_replica_covers(sg.rep, n) {
				fetched = true
				break
			}
		}
	}
	if !fetched || !h.sp.repl_on {
		return .Missing
	}
	if tries >= MAX_TRIES {
		return .Missing
	}
	if h.sp.mem.revoked || h.sp.mem.removed {
		return .Permission
	}
	w := new(Waiter, e.allocator)
	w.space = h.sp.id
	w.object = h.id
	w.ready = ready
	w.cmd = cmd
	w.tries = tries
	w.tick = e.tick
	append(&e.waiters, w)
	return .Pending
}

@(private)
_waiters_run :: proc(e: ^Engine) {
	if len(e.waiters) == 0 {
		return
	}
	ready := make([dynamic]^Waiter, context.temp_allocator)
	i := 0
	for i < len(e.waiters) {
		w := e.waiters[i]
		c, ok := e.changed[w.object]
		if ok && c.kinds & {.Data, .Keys, .Members, .Redacted, .Quarantined} != {} {
			ordered_remove(&e.waiters, i)
			append(&ready, w)
			continue
		}
		i += 1
	}
	for w in ready {
		if h, ok := e.handles[w.object]; ok {
			_handle_refresh(h)
			c := e.changed[w.object]
			if w.cmd == nil && _handle_waiting(h, w.ready.fresh) && c.kinds & {.Quarantined, .Redacted} == {} {
				append(&e.waiters, w)
				continue
			}
		}
		if w.cmd != nil {
			_cmd_retry(e, w.cmd, w.tries + 1)
		} else if w.ready.call != nil {
			{
				context = _outer(e)
				w.ready.call(w.ready.data, e, .None)
			}
		}
		free(w, e.allocator)
	}
}

@(private)
_waiters_fail_all :: proc(e: ^Engine, err: Error) {
	ws := e.waiters
	e.waiters = make([dynamic]^Waiter, e.allocator)
	for w in ws {
		if w.cmd != nil {
			_cmd_fail(e, w.cmd, err)
		} else if w.ready.call != nil {
			{
				context = _outer(e)
				w.ready.call(w.ready.data, e, err)
			}
		}
		free(w, e.allocator)
	}
	delete(ws)
}

cancel_waits :: proc(e: ^Engine, data: rawptr) {
	context = context_for(e)
	i := 0
	for i < len(e.waiters) {
		w := e.waiters[i]
		if w.ready.data == data && w.cmd == nil {
			ordered_remove(&e.waiters, i)
			free(w, e.allocator)
			continue
		}
		i += 1
	}
}

@(private)
_pending_result :: proc(e: ^Engine, h: ^Handle, err: Error, ready: Ready) -> Error {
	if err != .Missing {
		return err
	}
	if ready.call == nil {
		_handle_want(h)
		return .Missing
	}
	return _wait(e, h, ready)
}
