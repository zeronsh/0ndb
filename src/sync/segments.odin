package osync

import "core:crypto"
import "../journal"
import "../prim"

CHECKPOINT_STREAM :: "ckpt/"
CHECKPOINT_RECORD :: 1
CHECKPOINT_TAIL :: 4096

Fetch_State :: enum u8 {
	Listing,
	Tails,
	Getting,
}

Ckpt_Fetch :: struct {
	scope:   Scope,
	name:    string,
	suffix:  [16]u8,
	dest:    string,
	state:   Fetch_State,
	wait:    int,
	cands:   [dynamic]Stream_Id,
	done:    [dynamic]bool,
	found:   bool,
	hlc:     u64,
	writer:  Device_Id,
	oid:     [32]u8,
	oid_len: int,
	key:     Object_Key,
	meta:    [dynamic]u8,
	tree:    ^Key_Tree,
}

replicator_follow_segments :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, full: bool) -> Error {
	suffix := stream_suffix(scope, name, epoch)
	if g, ok := r.groups[suffix]; ok {
		g.full = g.full || full
		return .None
	}
	g, aerr := new(Group, r.allocator)
	if aerr != nil {
		return .No_Memory
	}
	g.scope = scope^
	g.epoch = epoch
	g.suffix = suffix
	g.full = full
	g.members = make([dynamic]Device_Id, r.allocator)
	nerr: Error
	g.name, nerr = _clone_string(name, r.allocator)
	if nerr != .None {
		_group_free(r, g)
		return nerr
	}
	r.groups[suffix] = g
	if r.phase == .Ready {
		if r.cfg.filtered {
			_feed_subscribe(r, true)
		} else {
			_list_all(r)
		}
		_repl_flush(r)
	}
	return .None
}

replicator_unfollow_segments :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64) {
	suffix := stream_suffix(scope, name, epoch)
	g, ok := r.groups[suffix]
	if !ok {
		return
	}
	for dev in g.members {
		replicator_unfollow(r, &g.scope, dev, g.name, g.epoch)
	}
	delete_key(&r.groups, suffix)
	_group_free(r, g)
	if r.cfg.filtered && r.phase == .Ready {
		_feed_subscribe(r, false)
		_repl_flush(r)
	}
}

replicator_segments :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64) -> []Device_Id {
	if g, ok := r.groups[stream_suffix(scope, name, epoch)]; ok {
		return g.members[:]
	}
	return nil
}

replicator_publish_checkpoint :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, history: string, hlc: u64, oid: []u8, meta: []u8, data: []u8 = nil, path: string = "") -> Error {
	if len(oid) == 0 || len(oid) > 32 || len(meta) > journal.MAX_BODY - 64 {
		return .Invalid
	}
	name := _concat(context.temp_allocator, CHECKPOINT_STREAM, history) or_return
	id := stream_id(scope, r.cfg.self, name, 0)
	pbuf: prim.Path_Buf = ---
	n := copy(pbuf[:], r.dir)
	n += copy(pbuf[n:], "/ckpt/")
	sid := id
	n += prim.hex_encode(pbuf[n:], sid[:])
	jpath := string(pbuf[:n])
	floor := replicator_floor(r, scope, name, 0) or_return
	size: i64
	if len(path) > 0 {
		fd, oerr := prim.open_file(r.vfs, path)
		if oerr != .None {
			return _from_prim(oerr)
		}
		sz, serr := prim.file_size(r.vfs, fd)
		prim.close_file(r.vfs, fd)
		if serr != .None {
			return _from_prim(serr)
		}
		size = sz
	} else {
		size = i64(len(data))
	}
	j: journal.Journal
	if jerr := journal.journal_open(&j, r.vfs, jpath, journal.Options{keep_at_least = floor}, context.allocator); jerr != .None {
		return _from_journal(jerr)
	}
	body := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&body)
	prim.write_u8(&w, CHECKPOINT_RECORD)
	prim.write_u64le(&w, hlc)
	prim.write_bytes(&w, oid)
	prim.write_u64le(&w, u64(size))
	prim.write_raw(&w, meta)
	if w.err != .None {
		journal.journal_close(&j)
		return .No_Memory
	}
	_, aerr := journal.journal_append(&j, body[:])
	if aerr == .None {
		aerr = journal.journal_commit(&j)
	}
	durable := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	if aerr != .None {
		return _from_journal(aerr)
	}
	if len(path) > 0 {
		replicator_put_object_file(r, scope, tree, oid, path) or_return
	} else {
		replicator_put_object(r, scope, tree, oid, data) or_return
	}
	return replicator_publish(r, scope, name, 0, jpath, durable)
}

replicator_fetch_checkpoint :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, history: string, dest: string) -> Error {
	f, aerr := new(Ckpt_Fetch, r.allocator)
	if aerr != nil {
		return .No_Memory
	}
	f.scope = scope^
	f.tree = tree
	f.cands = make([dynamic]Stream_Id, r.allocator)
	f.done = make([dynamic]bool, r.allocator)
	f.meta = make([dynamic]u8, r.allocator)
	e1, e2: Error
	f.name, e1 = _concat(r.allocator, CHECKPOINT_STREAM, history)
	f.dest, e2 = _clone_string(dest, r.allocator)
	if e1 != .None || e2 != .None {
		_fetch_free(r, f)
		return .No_Memory
	}
	f.suffix = stream_suffix(scope, f.name, 0)
	if _, e := append(&r.fetches, f); e != nil {
		_fetch_free(r, f)
		return .No_Memory
	}
	if r.phase == .Ready {
		_fetch_start(r, f)
		_repl_flush(r)
	}
	return .None
}

@(private)
_group_free :: proc(r: ^Replicator, g: ^Group) {
	delete(g.members)
	if len(g.name) > 0 {
		delete(g.name, r.allocator)
	}
	scope_clear(&g.scope)
	free(g, r.allocator)
}

@(private)
_fetch_free :: proc(r: ^Replicator, f: ^Ckpt_Fetch) {
	if f.state == .Tails {
		_fetch_release(r, f)
	}
	delete(f.cands)
	delete(f.done)
	delete(f.meta)
	if len(f.name) > 0 {
		delete(f.name, r.allocator)
	}
	if len(f.dest) > 0 {
		delete(f.dest, r.allocator)
	}
	scope_clear(&f.scope)
	free(f, r.allocator)
}

@(private)
_fetch_remove :: proc(r: ^Replicator, f: ^Ckpt_Fetch) {
	for i := 0; i < len(r.fetches); i += 1 {
		if r.fetches[i] == f {
			ordered_remove(&r.fetches, i)
			break
		}
	}
	_fetch_free(r, f)
}

@(private)
_list_all :: proc(r: ^Replicator) {
	if client_list(&r.client, 0) == .None {
		r.lists_out += 1
	}
}

@(private)
_fetch_start :: proc(r: ^Replicator, f: ^Ckpt_Fetch) {
	clear(&f.cands)
	clear(&f.done)
	f.state = .Listing
	_list_all(r)
	f.wait = r.lists_out
}

@(private)
_fetch_release :: proc(r: ^Replicator, f: ^Ckpt_Fetch) {
	for id in f.cands {
		if rm, ok := r.remotes[id]; ok && rm.refs > 0 {
			rm.refs -= 1
			_remote_maybe_free(r, rm)
		}
	}
}

@(private)
_segments_seen :: proc(r: ^Replicator, id: Stream_Id, length: i64) {
	suffix := stream_id_suffix(id)
	dev := stream_device(id)
	if g, ok := r.groups[suffix]; ok && dev != r.cfg.self {
		known := false
		for m in g.members {
			if m == dev {
				known = true
				break
			}
		}
		if !known {
			append(&g.members, dev)
			if rm, err := _remote_get(r, &g.scope, dev, g.name, g.epoch); err == .None {
				rm.grouped = true
				if length > rm.relay_len {
					rm.relay_len = length
					if length > journal.replica_length(&rm.rep) {
						journal.replica_set_length(&rm.rep, length)
					}
				}
				replicator_follow(r, &g.scope, dev, g.name, g.epoch, g.full)
			}
			_emit(r, Repl_Event{kind = .Segment_Seen, device = dev, name = g.name, epoch = g.epoch, stream = id, length = length})
		}
	}
	for f in r.fetches {
		if f.state != .Listing || stream_id_suffix(id) != f.suffix || length <= 0 {
			continue
		}
		dup := false
		for c in f.cands {
			if c == id {
				dup = true
			}
		}
		if !dup {
			append(&f.cands, id)
			append(&f.done, false)
		}
	}
}

@(private)
_lists_finished :: proc(r: ^Replicator) {
	r.lists_out = max(r.lists_out - 1, 0)
	for i := 0; i < len(r.fetches); {
		f := r.fetches[i]
		i += 1
		if f.state != .Listing {
			continue
		}
		f.wait -= 1
		if f.wait > 0 {
			continue
		}
		if len(f.cands) == 0 {
			_emit(r, Repl_Event{kind = .Checkpoint_Missing, err = .Not_Found, name = f.name})
			i -= 1
			_fetch_remove(r, f)
			continue
		}
		f.state = .Tails
		for id in f.cands {
			rm, err := _remote_get(r, &f.scope, stream_device(id), f.name, 0)
			if err != .None {
				continue
			}
			rm.refs += 1
			_remote_want_tail(r, rm, CHECKPOINT_TAIL)
		}
	}
	_fetch_check(r)
}

@(private)
_fetch_check :: proc(r: ^Replicator) {
	for i := 0; i < len(r.fetches); {
		f := r.fetches[i]
		i += 1
		if f.state != .Tails {
			continue
		}
		pending := false
		for id, k in f.cands {
			if f.done[k] {
				continue
			}
			rm, ok := r.remotes[id]
			if !ok {
				f.done[k] = true
				continue
			}
			if rm.relay_len < 0 {
				pending = true
				continue
			}
			key := stream_key(&f.scope, id)
			rd: journal.Reader
			journal.replica_reader(&rm.rep, &rd, context.temp_allocator)
			if f.scope.mode != .Transparent {
				journal.reader_set_keys(&rd, static_provider(&key))
			}
			body, _, err := journal.record_before(&rd, journal.replica_length(&rm.rep))
			missing := rd.missing
			if err == .None {
				_fetch_consider(f, stream_device(id), body)
				f.done[k] = true
			} else if err == .Missing {
				pending = true
				gap := []journal.Range{missing}
				append(&rm.wants, ..gap)
				_remote_settle(r, rm)
			} else {
				f.done[k] = true
			}
			journal.reader_close(&rd)
			crypto.zero_explicit(&key, size_of(key))
		}
		if pending {
			continue
		}
		_fetch_release(r, f)
		if !f.found {
			f.state = .Getting
			_emit(r, Repl_Event{kind = .Checkpoint_Missing, err = .Corrupt, name = f.name})
			i -= 1
			_fetch_remove(r, f)
			continue
		}
		f.state = .Getting
		f.key = object_index(&f.scope, f.oid[:f.oid_len])
		if err := replicator_get_object(r, &f.scope, f.tree, f.oid[:f.oid_len], f.dest); err != .None {
			_emit(r, Repl_Event{kind = .Checkpoint_Missing, err = err, name = f.name})
			i -= 1
			_fetch_remove(r, f)
		}
	}
}

@(private)
_fetch_consider :: proc(f: ^Ckpt_Fetch, writer: Device_Id, body: []u8) {
	rd := prim.reader(body)
	if prim.read_u8(&rd) != CHECKPOINT_RECORD {
		return
	}
	hlc := prim.read_u64le(&rd)
	oid := prim.read_bytes(&rd)
	_ = prim.read_u64le(&rd)
	meta := prim.read_rest(&rd)
	if !prim.reader_ok(&rd) || len(oid) == 0 || len(oid) > 32 {
		return
	}
	if f.found && hlc <= f.hlc {
		return
	}
	f.found = true
	f.hlc = hlc
	f.writer = writer
	f.oid_len = copy(f.oid[:], oid)
	clear(&f.meta)
	append(&f.meta, ..meta)
}

@(private)
_fetch_object_done :: proc(r: ^Replicator, key: Object_Key, kind: Repl_Event_Kind, err: Error, path: string) {
	for i := 0; i < len(r.fetches); i += 1 {
		f := r.fetches[i]
		if f.state != .Getting || f.key != key {
			continue
		}
		if kind == .Object_Fetched {
			_emit(r, Repl_Event{kind = .Checkpoint, device = f.writer, name = f.name, oid = f.oid[:f.oid_len], meta = f.meta[:], from = i64(f.hlc), path = path})
		} else {
			_emit(r, Repl_Event{kind = .Checkpoint_Missing, err = err, name = f.name, oid = f.oid[:f.oid_len]})
		}
		_fetch_remove(r, f)
		return
	}
}

@(private)
_fetches_reset :: proc(r: ^Replicator) {
	r.lists_out = 0
	for f in r.fetches {
		if f.state == .Tails {
			_fetch_release(r, f)
		}
		if f.state != .Getting {
			f.state = .Listing
			clear(&f.cands)
			clear(&f.done)
		}
	}
}

@(private)
_fetches_ready :: proc(r: ^Replicator) {
	for f in r.fetches {
		if f.state == .Listing {
			_fetch_start(r, f)
		}
	}
}
