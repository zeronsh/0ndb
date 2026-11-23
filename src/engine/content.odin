package engine

import "core:crypto"
import "core:crypto/blake2b"
import "core:strings"
import "../fs"
import "../journal"
import omap "../map"
import "../odb"
import "../pack"
import "../prim"
import osync "../sync"

@(private)
CONTENT_RETRY_MIN :: 1_000
@(private)
CONTENT_RETRY_MAX :: 60_000
@(private)
CONTENT_RETRIES :: 8

@(private)
Content_State :: struct {
	waits:  map[odb.Oid]^Content_Wait,
	ups:    map[odb.Oid]Content_Up,
	marks:  map[prim.Id]Content_Mark,
	events: [dynamic]Content_Ev,
	owed:   map[prim.Id]prim.Id,
}

@(private)
Content_Wait :: struct {
	e:        ^Engine,
	oid:      odb.Oid,
	n:        int,
	space:    prim.Id,
	object:   prim.Id,
	inflight: bool,
	attempts: int,
	rounds:   int,
	reported: bool,
	timer:    prim.Timer,
	path:     string,
	url:      int,
	stage:    Content_Stage,
}

@(private)
Content_Stage :: enum u8 {
	Relay,
	Remote,
	Holders,
}

@(private)
Content_Up :: struct {
	space:  prim.Id,
	object: prim.Id,
}

@(private)
Content_Mark :: struct {
	space:   prim.Id,
	target:  i64,
	pending: int,
	failed:  bool,
}

@(private)
Content_Ev :: struct {
	space: prim.Id,
	kind:  osync.Repl_Event_Kind,
	oid:   odb.Oid,
	n:     int,
	path:  string,
}

@(private)
_content_init :: proc(e: ^Engine) {
	e.content.waits = make(map[odb.Oid]^Content_Wait, e.allocator)
	e.content.ups = make(map[odb.Oid]Content_Up, e.allocator)
	e.content.marks = make(map[prim.Id]Content_Mark, e.allocator)
	e.content.events = make([dynamic]Content_Ev, e.allocator)
	e.content.owed = make(map[prim.Id]prim.Id, e.allocator)
}

@(private)
_content_destroy :: proc(e: ^Engine) {
	for _, w in e.content.waits {
		if w.timer != 0 {
			prim.timer_cancel(e.loop, w.timer)
		}
		delete(w.path, e.allocator)
		free(w, e.allocator)
	}
	delete(e.content.waits)
	delete(e.content.ups)
	delete(e.content.marks)
	delete(e.content.owed)
	for ev in e.content.events {
		delete(ev.path, e.allocator)
	}
	delete(e.content.events)
}

@(private)
_content_tree :: proc(scope: ^osync.Scope, t: ^osync.Key_Tree) -> Error {
	root: [32]u8
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, scope.content.key[:], 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb content tree"))
	blake2b.final(&ctx, root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return _serr(osync.keytree_init(t, root, osync.OBJECT_TREE_DEPTH, 0, context.temp_allocator))
}

@(private)
_content_marks :: proc(e: ^Engine, space: prim.Id, id: prim.Id) -> (mark: i64, target: i64) {
	k := _pending_key(space, id)
	v, found, err := omap.db_get(&e.reg.db, ROOT_OWNED, k[:], context.temp_allocator)
	if err != .None || !found || len(v) != 9 && len(v) != 17 {
		return 0, 0
	}
	mark = i64(prim.get_u64le(v[1:]))
	target = mark
	if len(v) == 17 {
		target = max(mark, i64(prim.get_u64le(v[9:])))
	}
	return mark, target
}

@(private)
_content_mark_get :: proc(e: ^Engine, sp: ^Space, id: prim.Id) -> i64 {
	mark, _ := _content_marks(e, sp.id, id)
	return mark
}

@(private)
_content_mark_put :: proc(e: ^Engine, space: prim.Id, id: prim.Id, kind: Kind, mark: i64, target: i64 = -1, urls: string = "", set_urls := false) {
	_, stored := _content_marks(e, space, id)
	want := max(target, stored)
	k := _pending_key(space, id)
	buf: [17]u8
	buf[0] = u8(kind)
	prim.put_u64le(buf[1:], u64(mark))
	v := buf[:9]
	if want > mark {
		prim.put_u64le(buf[9:], u64(want))
		v = buf[:]
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	if omap.txn_put(t, ROOT_OWNED, k[:], v[:]) != .None {
		omap.txn_abort(t)
		_reg_fail(e, .Io)
		return
	}
	if set_urls && _tree_remote_stored(e, space, id) != urls {
		rk := _tree_remote_key(space, id)
		if omap.txn_put(t, ROOT_OWNED, rk[:], transmute([]u8)urls) != .None {
			omap.txn_abort(t)
			_reg_fail(e, .Io)
			return
		}
	}
	_reg_commit_lazy(e, t)
}

@(private)
_content_target :: proc(e: ^Engine, space: prim.Id, id: prim.Id, length: i64) {
	mark, target := _content_marks(e, space, id)
	if length > target {
		_content_mark_put(e, space, id, .File_Tree, mark, length)
	}
}

@(private)
_content_durable :: proc(e: ^Engine, space: prim.Id, id: prim.Id, length: i64) {
	_content_target(e, space, id, length)
	sp, ok := e.spaces[space]
	if ok && sp.repl_on {
		_content_kick(e, sp, id)
	}
}

@(private)
_content_kick :: proc(e: ^Engine, sp: ^Space, id: prim.Id) {
	h, err := _handle_get(e, Object{sp.id, id}, .File_Tree)
	if err != .None {
		if err == .Busy {
			e.content.owed[id] = sp.id
		}
		return
	}
	if _hist_ready(e, h) != .None || _handle_create_writer(h) != .None {
		e.content.owed[id] = sp.id
		return
	}
	delete_key(&e.content.owed, id)
	_content_publish(e, h)
}

@(private)
_content_settle :: proc(e: ^Engine) {
	if len(e.content.owed) == 0 {
		return
	}
	ids := make([dynamic]prim.Id, 0, len(e.content.owed), context.temp_allocator)
	spaces := make([dynamic]prim.Id, 0, len(e.content.owed), context.temp_allocator)
	for id, s in e.content.owed {
		append(&ids, id)
		append(&spaces, s)
	}
	for id, i in ids {
		sp, ok := e.spaces[spaces[i]]
		if !ok || !sp.repl_on {
			delete_key(&e.content.owed, id)
			continue
		}
		_content_kick(e, sp, id)
	}
}

@(private)
_content_publish :: proc(e: ^Engine, h: ^Handle) {
	if h.kind != .File_Tree || !h.sp.repl_on || h.hist == nil || !h.hist.awake || !h.w_open {
		return
	}
	if m, busy := e.content.marks[h.id]; busy && m.pending > 0 {
		return
	}
	from, end := _content_marks(e, h.sp.id, h.id)
	end = min(end, _own_len(h))
	if from >= end || h.hist == nil || !h.hist.awake {
		return
	}
	db, derr := device_odb(e)
	if derr != .None {
		return
	}
	r: journal.Reader
	journal.journal_reader(&h.hist.journal, &r, context.temp_allocator)
	defer journal.reader_close(&r)
	refs := make([dynamic]fs.Content_Ref, context.temp_allocator)
	pos := from
	for pos < end {
		body, next, jerr := journal.record_at(&r, pos)
		if jerr == .Redacted {
			pos = next
			continue
		}
		if jerr != .None {
			break
		}
		if !journal.is_sig(body) {
			fs.history_record_oids(h.hist, e.self, body, &refs)
		}
		pos = next
	}
	tree: osync.Key_Tree
	if h.scope.mode != .Transparent {
		if _content_tree(&h.scope, &tree) != .None {
			return
		}
	}
	defer if h.scope.mode != .Transparent {
		osync.keytree_destroy(&tree)
	}
	mark := Content_Mark{space = h.sp.id, target = pos}
	tr := _tree_reach(e, h) if len(refs) > 0 else Tree_Reach{}
	if tr.ok {
		_tree_remote_note(e, h.sp, h.id, tr.urls)
	}
	device := _storage_class(e, h.sp, h.id, h.kind) == .Device
	held := make([dynamic]fs.Content_Ref, context.temp_allocator)
	for ref in refs {
		if _, up := e.content.ups[ref.oid]; up {
			continue
		}
		if tr.ok && fs.remote_reach_has(&tr.reach, ref.oid) {
			e.stats.remote_skipped += 1
			append(&held, ref)
			continue
		}
		if device {
			append(&held, ref)
			continue
		}
		if ref.opaque {
			_, size, herr := odb.read_header(db, ref.oid)
			if herr != .None || !_budget_take(e, h.sp, size) {
				e.stats.over_budget += 1
				if herr == .None {
					_held_note(e, h, ref, size)
				}
				append(&held, ref)
				continue
			}
		}
		t, data, rerr := odb.read(db, ref.oid, context.temp_allocator)
		if rerr != .None || t != .Blob {
			continue
		}
		oid := ref.oid
		tp := &tree if h.scope.mode != .Transparent else nil
		if osync.replicator_put_object(&h.sp.repl, &h.scope, tp, oid[:ref.len], data) != .None {
			mark.failed = true
			continue
		}
		e.content.ups[ref.oid] = Content_Up{space = h.sp.id, object = h.id}
		append(&held, ref)
		mark.pending += 1
	}
	_serve_register(e, h, held[:])
	if mark.pending == 0 {
		if !mark.failed {
			_content_mark_put(e, h.sp.id, h.id, h.kind, pos, -1, tr.urls, tr.ok)
		}
		return
	}
	e.content.marks[h.id] = mark
	_content_mark_put(e, h.sp.id, h.id, h.kind, from, pos, tr.urls, tr.ok)
}

@(private)
_content_resume :: proc(e: ^Engine, sp: ^Space) {
	Remote :: struct {
		id:   prim.Id,
		urls: string,
	}
	Acc :: struct {
		ids:     [dynamic]prim.Id,
		trees:   [dynamic]prim.Id,
		remotes: [dynamic]Remote,
	}
	acc := Acc{ids = make([dynamic]prim.Id, context.temp_allocator), trees = make([dynamic]prim.Id, context.temp_allocator), remotes = make([dynamic]Remote, context.temp_allocator)}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) == 32 && len(value) == 17 && value[0] == u8(Kind.File_Tree) && prim.get_u64le(value[9:]) > prim.get_u64le(value[1:]) {
			id: prim.Id
			copy(id[:], key[16:])
			append(&a.ids, id)
		} else if len(key) == 32 && (len(value) == 1 || len(value) == 9 || len(value) == 17) && value[0] == u8(Kind.File_Tree) {
			id: prim.Id
			copy(id[:], key[16:])
			append(&a.trees, id)
		} else if len(key) == 33 && key[32] == 'r' && len(value) > 0 {
			x := Remote{}
			copy(x.id[:], key[16:32])
			x.urls = strings.clone(string(value), context.temp_allocator)
			append(&a.remotes, x)
		}
		return true
	}
	s := sp.id
	omap.db_scan(&e.reg.db, ROOT_OWNED, s[:], s[:], &acc, visit)
	for x in acc.remotes {
		_tree_remote_note(e, sp, x.id, x.urls)
	}
	for id in acc.trees {
		if _content_behind(e, sp, id) {
			append(&acc.ids, id)
		}
	}
	for id in acc.ids {
		_content_kick(e, sp, id)
	}
}

@(private)
_content_behind :: proc(e: ^Engine, sp: ^Space, id: prim.Id) -> bool {
	_, target := _content_marks(e, sp.id, id)
	d, derr := _obj_dir(e, id, context.temp_allocator)
	if derr != .None {
		return false
	}
	path, perr := _join(context.temp_allocator, d, "hist", "fs.journal")
	if perr != .None {
		return false
	}
	st, serr := prim.stat(e.vfs, path)
	if serr != .None || st.size <= target {
		return false
	}
	_content_target(e, sp.id, id, st.size)
	return true
}

@(private)
_content_missing :: proc(e: ^Engine, h: ^Handle, device: prim.Id, body: []u8) -> bool {
	if len(body) == 0 || body[0] != fs.REC_BATCH && body[0] != fs.REC_IMPORT {
		return false
	}
	db, derr := device_odb(e)
	if derr != .None {
		return false
	}
	refs := make([dynamic]fs.Content_Ref, context.temp_allocator)
	if fs.history_record_oids(h.hist, device, body, &refs) != .None {
		return false
	}
	missing := false
	for ref in refs {
		if odb.exists(db, ref.oid) {
			continue
		}
		missing ||= !ref.opaque
		if h.sp.repl_on {
			_content_fetch(e, h, ref)
		}
	}
	return missing
}

@(private)
_content_fetch :: proc(e: ^Engine, h: ^Handle, ref: fs.Content_Ref) {
	w, known := e.content.waits[ref.oid]
	if known && (w.inflight || w.timer != 0 || w.attempts >= CONTENT_RETRIES) {
		return
	}
	if !known {
		w = new(Content_Wait, e.allocator)
		w.e = e
		w.oid = ref.oid
		w.n = ref.len
		w.space = h.sp.id
		w.object = h.id
		e.content.waits[ref.oid] = w
	}
	_content_request(e, w)
}

@(private)
_content_request :: proc(e: ^Engine, w: ^Content_Wait) -> bool {
	sp, ok := e.spaces[w.space]
	if !ok || !sp.repl_on {
		return false
	}
	h, herr := _handle_get(e, Object{w.space, w.object}, .File_Tree)
	if herr != .None {
		return false
	}
	if len(w.path) == 0 {
		hx := prim.id_hex(w.object)
		ox: [64]u8
		prim.hex_encode(ox[:], w.oid[:w.n])
		dir, jerr := _join(context.temp_allocator, e.pack_root, "content", string(hx[:]))
		if jerr != .None {
			return false
		}
		if prim.mkdir_all(e.vfs, dir, 0o700) != .None {
			return false
		}
		p, perr := _join(e.allocator, dir, string(ox[:2 * w.n]))
		if perr != .None {
			return false
		}
		w.path = p
	}
	tree: osync.Key_Tree
	tp: ^osync.Key_Tree
	if h.scope.mode != .Transparent {
		if _content_tree(&h.scope, &tree) != .None {
			return false
		}
		tp = &tree
	}
	defer if tp != nil {
		osync.keytree_destroy(&tree)
	}
	if w.stage == .Remote {
		if _git_wanted(e, w) {
			w.inflight = true
			return true
		}
		w.stage = .Holders
	}
	holders: []osync.Device_Id
	if w.stage == .Holders {
		holders = _content_holders(e, sp, w.object)
	}
	oid := w.oid
	if osync.replicator_get_object_from(&sp.repl, &h.scope, tp, oid[:w.n], w.path, holders) != .None {
		return false
	}
	w.inflight = true
	e.stats.fetches += 1
	return true
}

@(private)
_content_on_event :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	if len(ev.oid) != 20 && len(ev.oid) != 32 {
		return
	}
	oid: odb.Oid
	copy(oid[:], ev.oid)
	_, waiting := e.content.waits[oid]
	_, uploading := e.content.ups[oid]
	if !waiting && !uploading {
		return
	}
	p, _ := _clone(ev.path, e.allocator)
	append(&e.content.events, Content_Ev{space = sp.id, kind = ev.kind, oid = oid, n = len(ev.oid), path = p})
	_touch(e)
}

@(private)
_content_events_process :: proc(e: ^Engine) {
	if len(e.content.events) == 0 {
		return
	}
	evs := e.content.events
	e.content.events = make([dynamic]Content_Ev, e.allocator)
	defer delete(evs)
	for ev in evs {
		#partial switch ev.kind {
		case .Object_Stored, .Object_Failed:
			if up, ok := e.content.ups[ev.oid]; ok && (ev.kind == .Object_Stored || !_content_waiting(e, ev.oid)) {
				delete_key(&e.content.ups, ev.oid)
				_content_uploaded(e, up, ev.kind == .Object_Stored)
			}
		}
		if w, ok := e.content.waits[ev.oid]; ok {
			#partial switch ev.kind {
			case .Object_Fetched:
				_content_arrived(e, w, ev.path)
			case .Object_Missing, .Object_Failed:
				w.inflight = false
				if w.stage == .Relay && ev.kind == .Object_Missing {
					w.stage = .Remote
					if _content_request(e, w) {
						break
					}
				}
				_content_retry(e, w)
			}
		}
		delete(ev.path, e.allocator)
	}
}

@(private)
_content_pending :: proc(e: ^Engine, object: prim.Id) -> bool {
	for _, w in e.content.waits {
		if w.object == object && w.attempts < CONTENT_RETRIES {
			return true
		}
	}
	return false
}

@(private)
_content_waiting :: proc(e: ^Engine, oid: odb.Oid) -> bool {
	w, ok := e.content.waits[oid]
	return ok && w.inflight
}

@(private)
_content_uploaded :: proc(e: ^Engine, up: Content_Up, stored: bool) {
	m, ok := &e.content.marks[up.object]
	if !ok {
		return
	}
	m.pending -= 1
	m.failed ||= !stored
	if m.pending > 0 {
		return
	}
	space, target := m.space, m.target
	failed := m.failed
	delete_key(&e.content.marks, up.object)
	if failed {
		return
	}
	_content_mark_put(e, space, up.object, .File_Tree, target)
	if _, stored := _content_marks(e, space, up.object); stored > target {
		if sp, found := e.spaces[space]; found && sp.repl_on {
			_content_kick(e, sp, up.object)
		}
	}
}

@(private)
_content_arrived :: proc(e: ^Engine, w: ^Content_Wait, path: string) {
	w.inflight = false
	ok := false
	if db, derr := device_odb(e); derr == .None {
		if data, rerr := prim.read_file(e.vfs, path, context.temp_allocator); rerr == .None {
			if h, herr := odb.hash(db.format, .Blob, data); herr == .None && h == w.oid {
				if _, werr := odb.write(db, .Blob, data); werr == .None {
					ok = true
				}
			}
		}
	}
	prim.remove(e.vfs, path)
	if !ok {
		_content_retry(e, w)
		return
	}
	space, object := w.space, w.object
	ref := fs.Content_Ref{oid = w.oid, len = w.n}
	_content_forget(e, w)
	if h, herr := _handle_get(e, Object{space, object}, .File_Tree); herr == .None {
		refs := [1]fs.Content_Ref{ref}
		_serve_register(e, h, refs[:])
	}
	if sp, sok := e.spaces[space]; sok {
		_unavailable_clear(e, sp, object)
	}
	_ckpt_content(e, space, object)
	_object_changed(e, space, object, .Data)
}

@(private)
_content_forget :: proc(e: ^Engine, w: ^Content_Wait) {
	if w.timer != 0 {
		prim.timer_cancel(e.loop, w.timer)
	}
	delete_key(&e.content.waits, w.oid)
	delete(w.path, e.allocator)
	free(w, e.allocator)
}

@(private)
_content_retry :: proc(e: ^Engine, w: ^Content_Wait) {
	w.attempts += 1
	w.rounds += 1
	if w.rounds >= CONTENT_RETRIES && !w.reported {
		w.reported = true
		_log(e, .Warn, "content fetch gave up: no relay copy, remote or holder had it")
		ox: [64]u8
		prim.hex_encode(ox[:], w.oid[:w.n])
		_emit(e, Event{kind = .Unavailable, space = w.space, object = w.object, detail = string(ox[:2 * w.n])})
	}
	if w.attempts >= CONTENT_RETRIES || w.timer != 0 || e.closing {
		return
	}
	delay := i64(CONTENT_RETRY_MIN)
	for _ in 1 ..< w.attempts {
		delay = min(delay * 2, CONTENT_RETRY_MAX)
	}
	w.timer = prim.timer(e.loop, delay, w, proc(l: ^prim.Loop, data: rawptr) {
		w := (^Content_Wait)(data)
		context = context_for(w.e)
		w.timer = 0
		if !_content_request(w.e, w) {
			_content_retry(w.e, w)
		}
	})
}

@(private)
_content_rewait :: proc(e: ^Engine, sp: ^Space) {
	for k in _sorted_keys(e.content.waits) {
		w := e.content.waits[k]
		if w.space != sp.id || w.inflight {
			continue
		}
		if w.timer != 0 {
			prim.timer_cancel(e.loop, w.timer)
			w.timer = 0
		}
		w.attempts = 0
		w.rounds = 0
		w.reported = false
		w.url = 0
		w.stage = .Relay
		if !_content_request(e, w) {
			_content_retry(e, w)
		}
	}
}

@(private)
_content_data_arrived :: proc(e: ^Engine, object: prim.Id) {
	for sid in _sorted_keys(e.spaces) {
		sp := e.spaces[sid]
		if sp.open && object == named_id(sp.id, HOLDERS_NAME) {
			_content_holders_changed(e, sp)
		}
		if sp.open && object == named_id(sp.id, HELD_NAME) {
			_held_scan(e, sp)
		}
	}
	for _, w in e.content.waits {
		if w.object == object && !w.inflight && w.timer == 0 {
			w.attempts = 0
		}
	}
}

Content_Wait_Info :: struct {
	space:    prim.Id,
	object:   prim.Id,
	oid:      odb.Oid,
	n:        int,
	inflight: bool,
}

content_waits :: proc(e: ^Engine, allocator := context.allocator) -> []Content_Wait_Info {
	out := make([dynamic]Content_Wait_Info, allocator)
	for k in _sorted_keys(e.content.waits) {
		w := e.content.waits[k]
		append(&out, Content_Wait_Info{w.space, w.object, w.oid, w.n, w.inflight})
	}
	return out[:]
}

content_behind :: proc(e: ^Engine, allocator := context.temp_allocator) -> []prim.Id {
	context = context_for(e)
	out := make([dynamic]prim.Id, allocator)
	if !e.reg.open {
		return out[:]
	}
	Acc :: struct {
		ids: [dynamic]prim.Id,
	}
	acc := Acc{ids = make([dynamic]prim.Id, context.temp_allocator)}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) == 32 && len(value) >= 1 && value[0] == u8(Kind.File_Tree) {
			id: prim.Id
			copy(id[:], key[16:])
			append(&a.ids, id)
		}
		return true
	}
	omap.db_scan(&e.reg.db, ROOT_OWNED, nil, nil, &acc, visit)
	for id in acc.ids {
		rec, found, rerr := _rec_get(e, id)
		if rerr != .None || !found || !rec.own {
			continue
		}
		_, target := _content_marks(e, rec.space, id)
		path, perr := _own_stream_path(e, id, .File_Tree)
		if perr != .None {
			continue
		}
		n, nerr := pack.durable_size(&e.pk, path)
		if nerr == .None && n > target {
			append(&out, id)
		}
	}
	return out[:]
}
