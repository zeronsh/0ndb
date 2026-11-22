package sim

import eng "../../src/engine"
import "../../src/journal"
import "../../src/prim"
import osync "../../src/sync"

relay_stream_state :: proc(w: ^World, space: prim.Id, id: osync.Stream_Id) -> (length, base: i64, trimmed: bool, exists: bool) {
	rn := &w.relay
	if !rn.alive {
		return
	}
	context = instance_context(&rn.inst)
	defer relay_after(rn)
	st := rn.r.store
	ns: rawptr
	opened := false
	if sp, ok := rn.r.spaces[space]; ok && sp.ns != nil {
		ns = sp.ns
	} else {
		h, _, err := st.namespace_open(st.data, space)
		if err != .None {
			return
		}
		ns = h
		opened = true
	}
	defer if opened {
		st.namespace_close(st.data, ns)
	}
	sh, l, err := st.stream_open(st.data, ns, id, false)
	if err != .None {
		return
	}
	defer st.stream_close(st.data, sh)
	return l, st.stream_base(st.data, sh), st.stream_trimmed != nil && st.stream_trimmed(st.data, sh), true
}

@(private = "file")
Wipe :: struct {
	rep:  ^journal.Replica,
	base: i64,
	sid:  osync.Stream_Id,
}

check_archive_cipher :: proc(w: ^World) {
	m := &w.model
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for _, oi in m.objs {
			if obj_exists(m, oi) && _reader(w, oi, n.idx) {
				for x in _restored_segs(w, n, oi) {
					_compare_cipher(w, n, x)
				}
			}
		}
	}
}

check_archive_reread :: proc(w: ^World) {
	m := &w.model
	best := -1
	best_count := 0
	for n, idx in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		count := 0
		for _, oi in m.objs {
			if !obj_exists(m, oi) || !_reader(w, oi, idx) {
				continue
			}
			count += len(_trimmed_segs(w, n, oi))
		}
		if count > best_count {
			best, best_count = idx, count
		}
	}
	if best < 0 {
		return
	}
	n := w.nodes[best]
	if !_restart_settle(w, n) {
		return
	}
	objs := make([dynamic]int, w.allocator)
	before := make([dynamic]string, w.allocator)
	defer {
		for b in before {
			delete(b, w.allocator)
		}
		delete(before)
		delete(objs)
	}
	for _, oi in m.objs {
		if !obj_exists(m, oi) || !_reader(w, oi, best) {
			continue
		}
		d := digest_object(w, n, oi)
		if !d.complete {
			continue
		}
		append(&objs, oi)
		append(&before, d.text)
	}
	wiped: i64
	segs := 0
	for oi in objs {
		for x in _trimmed_segs(w, n, oi) {
			context = instance_context(&n.inst)
			if journal.replica_forget(x.rep, 0, x.base) == .None {
				wiped += x.base
				segs += 1
			}
			node_after(n)
		}
	}
	world_note(w, "archive reread: %s forgot %d bytes below trimmed bases in %d segments", n.name, wiped, segs)
	w.stats.rereads += u64(segs)
	w.stats.reread_bytes += u64(wiped)
	if segs == 0 || !_restart_settle(w, n) {
		return
	}
	for oi in objs {
		for x in _restored_segs(w, n, oi) {
			_compare_cipher(w, n, x)
		}
	}
	for oi, i in objs {
		d := digest_object(w, n, oi)
		if !d.complete {
			world_fail(w, "archive: %s could not reread %v %s through its archive after forgetting the trimmed prefix (%s)", n.name, m.objs[oi].kind, id_short(m.objs[oi].o.id), d.why)
			continue
		}
		if d.text != before[i] {
			world_fail(w, "archive: %v %s differs on %s after rereading the trimmed prefix through the archive:\n--- before\n%s--- after\n%s", m.objs[oi].kind, id_short(m.objs[oi].o.id), n.name, before[i], d.text)
		}
		delete(d.text, w.allocator)
	}
}

@(private = "file")
_reader :: proc(w: ^World, oi: int, idx: int) -> bool {
	for r in readers_of(w, oi) {
		if r == idx {
			return true
		}
	}
	return false
}

@(private = "file")
_trimmed_segs :: proc(w: ^World, n: ^Node, oi: int) -> []Wipe {
	out := make([dynamic]Wipe, context.temp_allocator)
	ob := &w.model.objs[oi]
	context = instance_context(&n.inst)
	h := _archive_handle(n, ob)
	node_after(n)
	if h == nil {
		return out[:]
	}
	for s in h.segs {
		if s.device == eng.self(&n.e) || s.rep == nil {
			continue
		}
		sid := osync.stream_id(&h.scope, s.device, h.name, 0)
		_, base, trimmed, exists := relay_stream_state(w, ob.o.space, sid)
		if exists && trimmed && base > 0 && journal.replica_covers(s.rep, 0, base) {
			append(&out, Wipe{s.rep, base, sid})
		}
	}
	return out[:]
}

@(private = "file")
_archive_handle :: proc(n: ^Node, ob: ^M_Obj) -> ^eng.Handle {
	switch ob.kind {
	case .Convo:
		eng.convo_status(&n.e, ob.o)
	case .Map:
		eng.map_get(&n.e, ob.o, transmute([]u8)string("?"), context.temp_allocator)
	case .Text:
		eng.text_read(&n.e, ob.o, context.temp_allocator)
	case .Tree:
		eng.tree_list(&n.e, ob.o, "", context.temp_allocator)
	}
	h, ok := n.e.handles[ob.o.id]
	return h if ok else nil
}

@(private = "file")
_restart_settle :: proc(w: ^World, n: ^Node) -> bool {
	live_close(n)
	{
		context = instance_context(&n.inst)
		eng.close(&n.e)
	}
	node_kill(n)
	if !node_start(n) {
		return false
	}
	model_after_restart(&w.model, n)
	for _ in 0 ..< 12 {
		idle := run_until(w, w.now + 120_000_000_000, true)
		if len(w.failures) > 0 {
			return false
		}
		if idle && check_convergence(w, false) {
			return true
		}
	}
	return true
}

@(private = "file")
_restored_segs :: proc(w: ^World, n: ^Node, oi: int) -> []Wipe {
	out := make([dynamic]Wipe, context.temp_allocator)
	ob := &w.model.objs[oi]
	context = instance_context(&n.inst)
	h := _archive_handle(n, ob)
	node_after(n)
	if h == nil {
		return out[:]
	}
	for s in h.segs {
		if s.device == eng.self(&n.e) || s.rep == nil {
			continue
		}
		sid := osync.stream_id(&h.scope, s.device, h.name, 0)
		_, base, trimmed, exists := relay_stream_state(w, ob.o.space, sid)
		if exists && trimmed && base > 0 {
			append(&out, Wipe{s.rep, base, sid})
		}
	}
	return out[:]
}

@(private = "file")
_compare_cipher :: proc(w: ^World, n: ^Node, x: Wipe) {
	im, ok := w.cipher.images[x.sid]
	if !ok {
		return
	}
	buf := make([]u8, int(x.base), context.temp_allocator)
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		for h in journal.replica_have(x.rep) {
			lo := max(h.from, 0)
			hi := min(h.to, x.base)
			if hi > lo {
				prim.read_at(eng.vfs(&n.e), x.rep.fd, buf[lo:hi], lo)
			}
		}
	}
	pos: i64
	for pos + journal.OVERHEAD <= x.base {
		if !journal.replica_covers(x.rep, pos, pos + journal.HEADER) {
			return
		}
		size := i64(prim.get_u32le(buf[pos:])) + journal.OVERHEAD
		end := pos + size
		if end > x.base || !journal.replica_covers(x.rep, pos, end) {
			return
		}
		rec := buf[pos:end]
		sig := size > journal.OVERHEAD && rec[journal.HEADER] == journal.SIG_KIND
		if !sig && journal.classify(rec, pos) != .Redacted && end <= i64(len(im.data)) {
			for k in pos ..< end {
				if im.have[k] && im.data[k] != buf[k] {
					orig := im.data[pos:end]
					if journal.classify(orig, pos) != .Redacted {
						world_fail(w, "archive: %s rebuilt record at offset %d of stream %s differs from the writer's ciphertext (nonce reuse or a wrong rebuild)", n.name, pos, stream_short(x.sid))
					}
					break
				}
			}
		}
		pos = end
	}
}
