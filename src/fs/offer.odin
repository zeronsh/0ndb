package fs

import "../crdt"
import "../fshist"
import "../fstree"
import "../prim"

@(private)
OFFER_LIST :: "rol"

@(private)
Offer :: struct {
	source: fstree.Inode_Id,
	dest:   fstree.Inode_Id,
	taken:  crdt.Op_Id,
}

@(private)
offer_get :: proc(h: ^History, source: fstree.Inode_Id) -> (o: Offer, found: bool, err: Error) {
	data, ok := kv_get(&h.kv, inode_key("ro:", source), context.temp_allocator) or_return
	if !ok {
		return {}, false, .None
	}
	rd := prim.reader(data)
	o.source = source
	o.dest.actor = prim.read_u32le(&rd)
	o.dest.seq = prim.read_u64le(&rd)
	o.taken.actor = prim.read_id(&rd)
	o.taken.seq = prim.read_uvarint(&rd)
	if !prim.reader_ok(&rd) {
		return {}, false, .Corrupt
	}
	return o, true, .None
}

@(private)
offer_put :: proc(h: ^History, o: Offer) -> Error {
	_, had := offer_get(h, o.source) or_return
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u32le(&w, o.dest.actor)
	prim.write_u64le(&w, o.dest.seq)
	prim.write_id(&w, o.taken.actor)
	prim.write_uvarint(&w, o.taken.seq)
	kv_put(&h.kv, inode_key("ro:", o.source), buf[:]) or_return
	if had {
		return .None
	}
	list, _ := kv_get(&h.kv, transmute([]u8)string(OFFER_LIST), context.temp_allocator) or_return
	lb := make([dynamic]u8, 0, len(list) + 12, context.temp_allocator)
	append(&lb, ..list)
	lw := prim.writer(&lb)
	prim.write_u32le(&lw, o.source.actor)
	prim.write_u64le(&lw, o.source.seq)
	return kv_put(&h.kv, transmute([]u8)string(OFFER_LIST), lb[:])
}

@(private)
offer_pending :: proc(h: ^History, o: Offer, lvs: []crdt.Lv, snap: ^fstree.Snapshot) -> (pending: bool, err: Error) {
	if info, ok, ierr := fstree.info(snap, o.source, context.temp_allocator); ierr != nil {
		return false, .Corrupt
	} else if ok && info.present {
		return false, .None
	}
	if info, ok, ierr := fstree.info(snap, o.dest, context.temp_allocator); ierr != nil {
		return false, .Corrupt
	} else if !ok || !info.present {
		return false, .None
	}
	tlv, known := crdt.graph_lv(&h.g, o.taken)
	if !known || !crdt.graph_contains(&h.g, lvs, tlv) {
		return false, .None
	}
	now, nerr := history_text_at(h, o.source, crdt.graph_version_ids(&h.g, lvs, context.temp_allocator), context.temp_allocator)
	if nerr != .None {
		return false, .None
	}
	at := [1]crdt.Op_Id{o.taken}
	then, terr := history_text_at(h, o.source, at[:], context.temp_allocator)
	if terr != .None {
		return false, .None
	}
	return string(now) != string(then), .None
}

@(private)
offers_apply :: proc(h: ^History, b: ^crdt.Batch, spans: []Target_Span) -> Error {
	n := crdt.batch_len(b)
	if n == 0 {
		return .None
	}
	head := crdt.Op_Id{b.actor, b.seq + u64(n) - 1}
	checked := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	for op in b.ops {
		if op.kind != .Opaque || len(op.content) == 0 {
			continue
		}
		switch op.content[0] {
		case fshist.TOP_RENAMED:
			if r, ok := fshist.decode_renamed(op.content); ok {
				src := op_inode(h, r.source)
				offer_put(h, Offer{source = src, dest = op_inode(h, r.dest), taken = head}) or_return
				offer_check(h, src) or_return
				checked[src] = true
			}
		case fshist.TOP_ACCEPT:
			if a, ok := fshist.decode_accept(op.content); ok && a.kind == u8(Conflict_Kind.Offered) {
				src := op_inode(h, a.source)
				if o, found := offer_get(h, src) or_return; found {
					o.taken = head
					offer_put(h, o) or_return
				}
				checked[src] = true
			}
		}
	}
	for sp in spans {
		ino := op_inode(h, sp.target)
		if !checked[ino] {
			checked[ino] = true
			offer_check(h, ino) or_return
		}
	}
	return .None
}

@(private)
offer_check :: proc(h: ^History, source: fstree.Inode_Id) -> Error {
	o, found := offer_get(h, source) or_return
	if !found {
		return .None
	}
	if h.rebuilding || h.on_offered == nil {
		return .None
	}
	snap := fstree.current(&h.tree)
	if pending := offer_pending(h, o, h.g.heads[:], &snap) or_return; pending {
		h.on_offered(h.offered_data, h, o.dest, o.source)
	}
	return .None
}

history_offers :: proc(h: ^History, version: []crdt.Op_Id, snap: ^fstree.Snapshot, out: ^[dynamic]Text_Conflict, allocator := context.allocator) -> Error {
	list, found := kv_get(&h.kv, transmute([]u8)string(OFFER_LIST), context.temp_allocator) or_return
	if !found {
		return .None
	}
	vl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, version, &vl) != .None {
		return .Corrupt
	}
	lvs := vl[:]
	rd := prim.reader(list)
	for prim.reader_remaining(&rd) >= 12 {
		src := fstree.Inode_Id{prim.read_u32le(&rd), prim.read_u64le(&rd)}
		o, ok := offer_get(h, src) or_return
		if !ok {
			continue
		}
		if pending := offer_pending(h, o, lvs, snap) or_return; !pending {
			continue
		}
		dtext, dspans, derr := history_text_spans_at(h, o.dest, lvs, context.temp_allocator)
		_, sspans, serr := history_text_spans_at(h, o.source, lvs, context.temp_allocator)
		if derr != .None || serr != .None {
			continue
		}
		c := Text_Conflict{inode = o.dest, start = 0, end = len(dtext), kind = .Offered, source = o.source}
		c.ours = op_spans(dspans, allocator) or_return
		c.theirs = op_spans(sspans, allocator) or_return
		append(out, c)
	}
	return .None
}

@(private)
op_spans :: proc(spans: []crdt.Author_Span, allocator := context.allocator) -> (out: []crdt.Op_Span, err: Error) {
	s, aerr := make([]crdt.Op_Span, len(spans), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	for x, i in spans {
		s[i] = crdt.Op_Span{id = x.op, len = x.len}
	}
	return s, .None
}

conflict_accept_ops :: proc(h: ^History, c: Text_Conflict, version: []crdt.Op_Id, ops: ^[dynamic]crdt.Op_Run) -> Error {
	switch c.kind {
	case .Concurrent:
		return .Invalid
	case .Revert:
		return revert_accept_ops(h, c, version, ops)
	case .Offered:
		o, found := offer_get(h, c.source) or_return
		if !found || o.dest != c.inode {
			return .Not_Found
		}
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, version, &lvs) != .None {
			return .Corrupt
		}
		vsnap := version_snapshot(h, lvs[:]) or_return
		defer fstree.snapshot_destroy(&vsnap)
		if pending := offer_pending(h, o, lvs[:], &vsnap) or_return; !pending {
			return .Not_Found
		}
		dtext, _, derr := history_text_spans_at(h, o.dest, lvs[:], context.temp_allocator)
		stext, sspans, serr := history_text_spans_at(h, o.source, lvs[:], context.temp_allocator)
		if derr != .None || serr != .None {
			return .Corrupt
		}
		if string(stext) == string(dtext) {
			return .Not_Found
		}
		target := inode_op(h, o.dest)
		if len(dtext) > 0 {
			append(ops, crdt.Op_Run{target = target, kind = .Delete, pos = 0, len = len(dtext)})
		}
		pos := 0
		for s in sspans {
			if s.len <= 0 {
				continue
			}
			r := crdt.Op_Run{target = target, kind = .Insert_Copy, pos = pos, len = s.len}
			r.src = s.op
			append(ops, r)
			pos += s.len
		}
		buf := make([dynamic]u8, context.temp_allocator)
		fshist.encode_accept(&buf, fshist.Accept_Op{kind = u8(Conflict_Kind.Offered), dest = target, source = inode_op(h, o.source)})
		content := make([]u8, len(buf), context.temp_allocator)
		copy(content, buf[:])
		append(ops, crdt.Op_Run{kind = .Opaque, len = 1, content = content})
	}
	return .None
}
