package sim

import "core:fmt"

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
	stat_add(w, STAT_REREADS, u64(segs))
	stat_add(w, STAT_REREAD_BYTES, u64(wiped))
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

check_archive_streams :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		for _, sp in n.e.spaces {
			for id, rm in sp.repl.remotes {
				im, ok := w.cipher.images[id]
				if !ok {
					continue
				}
				for t in rm.rep.trusted {
					_compare_trusted(w, n, rm, im, t)
				}
			}
		}
		node_after(n)
	}
}

@(private = "file")
_compare_trusted :: proc(w: ^World, n: ^Node, rm: ^osync.Remote, im: ^Cipher_Image, t: journal.Range) {
	buf := make([]u8, int(t.to - t.from), context.temp_allocator)
	if got, err := prim.read_at(eng.vfs(&n.e), rm.rep.fd, buf, t.from); err != .None || got != len(buf) {
		return
	}
	pos := t.from
	for pos + journal.OVERHEAD <= t.to {
		rec := buf[pos - t.from:]
		size := i64(prim.get_u32le(rec)) + journal.OVERHEAD
		end := pos + size
		if end > t.to || end > i64(len(im.data)) {
			return
		}
		rec = rec[:size]
		orig := im.data[pos:end]
		known := true
		for k in pos ..< end {
			if !im.have[k] {
				known = false
				break
			}
		}
		if known {
			sig := size > journal.OVERHEAD && orig[journal.HEADER] == journal.SIG_KIND
			mine := journal.classify(rec, pos)
			theirs := journal.classify(orig, pos)
			if !sig && theirs != .Redacted && mine != .Redacted && string(rec) != string(orig) {
				world_fail(w, "archive: %s materialized record of %s at %d differs from the writer's ciphertext", n.name, rm.name, pos)
			}
		}
		pos = end
	}
}

STAT_TRIMS: Stat
STAT_TRIMMED: Stat
STAT_RESTORES_WRITTEN: Stat
STAT_RESTORES_READ: Stat
STAT_RESTORE_SCENARIOS: Stat
STAT_REREADS: Stat
STAT_REREAD_BYTES: Stat

@(init)
_archive_hooks :: proc "contextless" () {
	register_final_check(90, check_restore_offline_writer)
	register_final_check(95, check_archive_cipher)
	register_final_check(96, check_archive_streams)
	register_final_check(200, check_archive_reread)
	register_collect(20, proc(w: ^World, res: ^Run_Result) {
		res.stats.extra[int(STAT_TRIMS)] += w.relay.r.stats.trims
		res.stats.extra[int(STAT_TRIMMED)] += w.relay.r.stats.trimmed
	})
	register_stat_line(77)
	STAT_TRIMS = register_stat(77, 0, "trims")
	STAT_TRIMMED = register_stat(77, 1, "trimmed_bytes")
	STAT_REREADS = register_stat(77, 2, "archive_rereads")
	STAT_REREAD_BYTES = register_stat(77, 3, "reread_bytes")
	STAT_RESTORE_SCENARIOS = register_stat(77, 4, "restore_scenarios")
	STAT_RESTORES_WRITTEN = register_stat(77, 5, "restores_written")
	STAT_RESTORES_READ = register_stat(77, 6, "restores_read")
}

@(private = "file")
Restore_Pick :: struct {
	oi:   int,
	wn:   ^Node,
	rn:   ^Node,
	t:    ^M_Op,
	base: i64,
	dev:  prim.Id,
}

@(private = "file")
_node_of :: proc(w: ^World, dev: prim.Id) -> ^Node {
	for n in w.nodes {
		if n.alive && n.e_open && eng.self(&n.e) == dev {
			return n
		}
	}
	return nil
}

@(private = "file")
_msg_redacted :: proc(m: ^Model, idx: int) -> bool {
	for op in m.ops {
		if op.kind == .Redact_Msg && op.target == idx {
			return true
		}
	}
	return false
}

@(private = "file")
_online :: proc(n: ^Node) -> bool {
	return n.alive && n.e_open && !n.partitioned
}

@(private = "file")
_restore_pick :: proc(w: ^World) -> (p: Restore_Pick, ok: bool) {
	m := &w.model
	for _, oi in m.objs {
		ob := &m.objs[oi]
		if !obj_exists(m, oi) || ob.kind != .Convo {
			continue
		}
		readers := readers_of(w, oi)
		for ri in readers {
			rn := w.nodes[ri]
			if !_online(rn) {
				continue
			}
			context = instance_context(&rn.inst)
			h := _archive_handle(rn, ob)
			node_after(rn)
			if h == nil {
				continue
			}
			for s in h.segs {
				if s.device == eng.self(&rn.e) {
					continue
				}
				sid := osync.stream_id(&h.scope, s.device, h.name, 0)
				_, base, trimmed, exists := relay_stream_state(w, ob.o.space, sid)
				if !exists || !trimmed || base <= 0 {
					continue
				}
				wn := _node_of(w, s.device)
				if wn == nil || wn == rn || !_online(wn) {
					continue
				}
				for t in m.ops {
					if t.obj != oi || t.kind != .Send || t.node != wn.idx || t.rid.seg != s.device || t.rid.off >= base {
						continue
					}
					if (t.status != .Done && t.status != .Acked && t.status != .Observed) || _msg_redacted(m, t.idx) {
						continue
					}
					return Restore_Pick{oi = oi, wn = wn, rn = rn, t = t, base = base, dev = s.device}, true
				}
			}
		}
	}
	return
}

@(private = "file")
_restore_counts :: proc(n: ^Node) -> (written, read: u64) {
	context = instance_context(&n.inst)
	st := eng.stats(&n.e)
	node_after(n)
	return st.restores_written, st.restores_read
}

check_restore_offline_writer :: proc(w: ^World) {
	if w.aborted || len(w.failures) > 0 || w.cfg.archive_min < 0 {
		return
	}
	p, ok := _restore_pick(w)
	if !ok {
		return
	}
	m := &w.model
	ob := &m.objs[p.oi]
	space := ob.o.space
	stat_add(w, STAT_RESTORE_SCENARIOS)
	p.wn.partitioned = true
	for c in p.wn.conns {
		conn_reset(c, true)
	}
	world_note(w, "restore: %s offline; %s redacts %s's message %s at %d below the trimmed base %d; a new device reads it", p.wn.name, p.rn.name, p.wn.name, p.t.token, p.t.rid.off, p.base)
	written0, _ := _restore_counts(p.rn)
	op := new_op(m, .Redact_Msg, p.rn, p.oi)
	op.target = p.t.idx
	snapshot_search_models(w, p.rn, op)
	{
		context = instance_context(&p.rn.inst)
		err := eng.convo_redact(&p.rn.e, ob.o, p.t.rid, op_done_handle(op))
		op_result(op, p.rn, err)
		node_after(p.rn)
		if err != .None {
			world_fail(w, "restore: %s could not redact %s: %v", p.rn.name, p.t.token, err)
			return
		}
	}
	written: u64
	for _ in 0 ..< 6 {
		run_until(w, w.now + 60_000_000_000, true)
		if len(w.failures) > 0 || w.aborted {
			return
		}
		if wr, _ := _restore_counts(p.rn); wr > written0 {
			written = wr - written0
			break
		}
	}
	if written == 0 {
		world_fail(w, "restore: %s redacted %s's archived message %s with the writer offline but wrote no Restore", p.rn.name, p.wn.name, p.t.token)
		return
	}
	stat_add(w, STAT_RESTORES_WRITTEN, written)
	run_until(w, w.now + 60_000_000_000, true)
	ref := digest_object(w, p.rn, p.oi)
	if !ref.complete {
		world_fail(w, "restore: %s cannot read %v %s after its redaction (%s)", p.rn.name, ob.kind, id_short(ob.o.id), ref.why)
		return
	}
	defer delete(ref.text, w.allocator)
	tn := _new_reader(w, p.rn, space)
	if tn == nil {
		return
	}
	run_until(w, w.now + 60_000_000_000, true)
	offline := make([dynamic]^Node, w.allocator)
	defer delete(offline)
	for n in w.nodes {
		if n == tn || n.partitioned || !n.alive {
			continue
		}
		n.partitioned = true
		for c in n.conns {
			conn_reset(c, true)
		}
		append(&offline, n)
	}
	got: Digest
	for _ in 0 ..< 12 {
		run_until(w, w.now + 120_000_000_000, true)
		if len(w.failures) > 0 || w.aborted {
			return
		}
		got = digest_object(w, tn, p.oi)
		if got.complete {
			break
		}
	}
	if !got.complete {
		world_fail(w, "restore: new device %s could not read %v %s through the Restore with every other device offline (%s)", tn.name, ob.kind, id_short(ob.o.id), got.why)
		return
	}
	if _strip_catalog(got.text) != _strip_catalog(ref.text) {
		world_fail(w, "restore: %v %s on %s read through the Restore differs from the redactor %s:\n--- %s\n%s--- %s\n%s", ob.kind, id_short(ob.o.id), tn.name, p.rn.name, p.rn.name, ref.text, tn.name, got.text)
	}
	delete(got.text, w.allocator)
	_, read := _restore_counts(tn)
	if read == 0 {
		world_fail(w, "restore: new device %s read %s's trimmed prefix with every other device offline without resolving a Restore", tn.name, p.wn.name)
	}
	stat_add(w, STAT_RESTORES_READ, read)
	check_archive_streams(w)
	live_close(tn)
	{
		context = instance_context(&tn.inst)
		eng.close(&tn.e)
	}
	node_kill(tn)
	world_note(w, "restore: %s wrote %d Restores, new device %s resolved %d", p.rn.name, written, tn.name, read)
	for n in offline {
		n.partitioned = false
	}
	p.wn.partitioned = false
	for _ in 0 ..< 6 {
		idle := run_until(w, w.now + 120_000_000_000, true)
		if len(w.failures) > 0 || w.aborted {
			return
		}
		if idle && check_convergence(w, false) {
			break
		}
	}
	check_convergence(w, true)
}

@(private = "file")
_new_reader :: proc(w: ^World, sponsor: ^Node, space: prim.Id) -> ^Node {
	m := &w.model
	si := -1
	for &sp, i in m.spaces {
		if sp.id == space {
			si = i
		}
	}
	if si < 0 {
		return nil
	}
	nn := new(Node, w.allocator)
	nn.w = w
	nn.idx = len(w.nodes)
	nn.name = fmt.aprintf("rd%d", nn.idx, allocator = w.allocator)
	disk_init(&nn.disk, nn.name, w.allocator)
	nn.clock = Node_Clock{w = w, mono_off = rng_range(&w.rng, 0, 1 << 40), wall_off = rng_range(&w.rng, -30_000_000_000, 30_000_000_000)}
	nn.disk.wall = clock_wall
	nn.disk.wall_data = &nn.clock
	rng_init(&nn.disk.fail_rng, w.cfg.seed, 6000 + u64(nn.idx))
	nn.conns = make([dynamic]^Conn, w.allocator)
	nn.mounts = make([dynamic]Sim_Mount, w.allocator)
	nn.writers = make(map[string]Writer_Info, w.allocator)
	append(&w.nodes, nn)
	if !node_start(nn) {
		world_fail(w, "restore: %s could not start", nn.name)
		return nil
	}
	proof: []u8
	{
		context = instance_context(&sponsor.inst)
		pr, aerr := eng.member_add(&sponsor.e, space, nn.identity, .Device, .Admin, .Approval, 0, w.allocator)
		node_after(sponsor)
		if aerr != .None {
			world_fail(w, "restore: %s member_add for %s failed: %v", sponsor.name, nn.name, aerr)
			return nil
		}
		proof = pr
	}
	context = instance_context(&nn.inst)
	if _, err := eng.space_join_enrollment(&nn.e, space, proof, fmt.tprintf("space%d", si), "relay", w.relay.public); err != .None {
		world_fail(w, "restore: %s space_join_enrollment failed: %v", nn.name, err)
		return nil
	}
	if err := eng.space_open(&nn.e, space); err != .None {
		world_fail(w, "restore: %s space_open failed: %v", nn.name, err)
		return nil
	}
	node_after(nn)
	return nn
}

@(private = "file")
_strip_catalog :: proc(text: string) -> string {
	if len(text) < 8 || text[:8] != "catalog " {
		return text
	}
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			return text[i + 1:]
		}
	}
	return ""
}
