package sim

import "core:fmt"
import "core:slice"
import "core:strings"
import "../../src/convo"
import eng "../../src/engine"
import omap "../../src/map"
import "../../src/obj"
import "../../src/prim"
import "../../src/search"
import osync "../../src/sync"

Digest :: struct {
	text:     string,
	complete: bool,
	why:      string,
	guest:    bool,
}

rid_str :: proc(r: eng.Rid) -> string {
	if obj.rid_none(r) {
		return "-"
	}
	return fmt.tprintf("%s@%d", id_short(r.seg), r.off)
}

@(private = "file")
_incomplete :: proc(err: eng.Error) -> bool {
	return err == .Missing || err == .Pending || err == .Busy
}

digest_object :: proc(w: ^World, n: ^Node, oi: int) -> Digest {
	m := &w.model
	ob := &m.objs[oi]
	if !n.alive {
		return {}
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	b := strings.builder_make(context.temp_allocator)
	ready := eng.Ready{data = nil, call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}}
	si := space_index(m, ob.o.space)
	guest := si >= 0 && !space_member(&m.spaces[si], n.idx)
	if !guest {
		cat, cfound, cerr := eng.catalog_get(&n.e, ob.o, context.temp_allocator, ready)
		if _incomplete(cerr) {
			return Digest{why = fmt.tprintf("catalog: %v", cerr)}
		}
		if cerr == .None && cfound {
			fmt.sbprintf(&b, "catalog kind=%v title=%q archived=%v pinned=%v\n", cat.kind, cat.title, cat.archived, cat.pinned)
		} else {
			fmt.sbprintf(&b, "catalog none %v\n", cerr)
		}
	}
	switch ob.kind {
	case .Convo:
		st, serr := eng.convo_status(&n.e, ob.o, ready)
		if _incomplete(serr) {
			return Digest{why = fmt.tprintf("%s %v @%d", "serr", serr, #line)}
		}
		fmt.sbprintf(&b, "head=%s status=%v err=%v\n", rid_str(st.head), st.head_status, serr)
		if !obj.rid_none(st.head) {
			pos := convo.Position{msg = st.head}
			for _ in 0 ..< 64 {
				pg, perr := eng.convo_page(&n.e, ob.o, pos, 32, context.temp_allocator, ready)
				if _incomplete(perr) {
					return Digest{why = fmt.tprintf("%s %v @%d", "perr", perr, #line)}
				}
				if perr != .None {
					fmt.sbprintf(&b, "page err %v\n", perr)
					break
				}
				for msg in pg.messages {
					fmt.sbprintf(&b, "branch %s\n", rid_str(msg.id))
				}
				if !pg.more {
					break
				}
				pos = pg.next
			}
		}
		rids := make([dynamic]eng.Rid, context.temp_allocator)
		for op in m.ops {
			if op.obj == oi && op.kind == .Send && op.status != .Lost && op.status != .Failed && !obj.rid_none(op.rid) {
				append(&rids, op.rid)
			}
		}
		for r in rids {
			msg, merr := eng.convo_message(&n.e, ob.o, convo.Position{msg = r}, context.temp_allocator, ready)
			if _incomplete(merr) {
				return Digest{why = fmt.tprintf("message %s: %v", rid_str(r), merr)}
			}
			if merr != .None {
				fmt.sbprintf(&b, "msg %s err %v\n", rid_str(r), merr)
				continue
			}
			fmt.sbprintf(&b, "msg %s role=%v author=%s parent=%s depth=%d redacted=%v status=%v sib=%d/%d text=%q\n", rid_str(msg.id), msg.role, id_short(msg.author), rid_str(msg.parent), msg.depth, msg.redacted, msg.status, msg.sibling, msg.siblings, msg_text(msg))
		}
		its, ierr := eng.convo_intents(&n.e, ob.o, context.temp_allocator, ready)
		if _incomplete(ierr) {
			return Digest{why = fmt.tprintf("%s %v @%d", "ierr", ierr, #line)}
		}
		for it in its {
			fmt.sbprintf(&b, "intent %s %v by=%s text=%q target=%s\n", rid_str(it.item), it.kind, id_short(it.by), it.text, rid_str(it.target))
		}
		mts, mterr := eng.convo_mounts(&n.e, ob.o, context.temp_allocator, ready)
		if _incomplete(mterr) {
			return Digest{why = fmt.tprintf("%s %v @%d", "mterr", mterr, #line)}
		}
		mlines := make([dynamic]string, context.temp_allocator)
		for mt in mts {
			append(&mlines, fmt.tprintf("mount %s tree=%s path=%s removed=%v\n", mt.name, id_short(mt.tree), mt.path, mt.removed))
		}
		slice.sort(mlines[:])
		for l in mlines {
			strings.write_string(&b, l)
		}
	case .Map:
		after: eng.Map_Cursor
		defer omap.cursor_destroy(&after)
		for _ in 0 ..< 64 {
			rows, more, serr := eng.map_scan(&n.e, ob.o, nil, &after, 256, context.temp_allocator, ready)
			if _incomplete(serr) {
				return Digest{why = fmt.tprintf("%s %v @%d", "serr", serr, #line)}
			}
			if serr != .None {
				fmt.sbprintf(&b, "scan err %v\n", serr)
				break
			}
			for row in rows {
				fmt.sbprintf(&b, "key %q\n", string(row.key))
				for r in row.entry.registers {
					fmt.sbprintf(&b, "  reg %d by=%s %q\n", r.tag, id_short(r.by), string(r.value))
				}
				els := make([dynamic]string, context.temp_allocator)
				for el in row.entry.elements {
					if len(el.live) > 0 {
						append(&els, fmt.tprintf("  el %d %q", el.tag, string(el.value)))
					}
				}
				slice.sort(els[:])
				for s in els {
					fmt.sbprintf(&b, "%s\n", s)
				}
				en := row.entry
				tags := [?]u32{7}
				for t in tags {
					if v, ok := omap.counter_value(&en, t); ok {
						fmt.sbprintf(&b, "  count %d = %d\n", t, v)
					}
				}
			}
			if !more {
				break
			}
		}
	case .Text:
		data, terr := eng.text_read(&n.e, ob.o, context.temp_allocator, ready)
		if _incomplete(terr) {
			return Digest{why = fmt.tprintf("%s %v @%d", "terr", terr, #line)}
		}
		spans, serr := eng.text_spans(&n.e, ob.o, context.temp_allocator, ready)
		if _incomplete(serr) {
			return Digest{why = fmt.tprintf("%s %v @%d", "serr", serr, #line)}
		}
		fmt.sbprintf(&b, "text err=%v %q\n", terr, _printable(data))
		for s in spans {
			fmt.sbprintf(&b, "span %s/%d len=%d red=%v\n", id_short(s.id.actor), s.id.seq, s.len, s.redacted)
		}
	case .Tree:
		names, lerr := eng.tree_list(&n.e, ob.o, "", context.temp_allocator, ready)
		if _incomplete(lerr) {
			return Digest{why = fmt.tprintf("%s %v @%d", "lerr", lerr, #line)}
		}
		slice.sort(names)
		fmt.sbprintf(&b, "tree err=%v %v\n", lerr, names)
		for nm in names {
			data, rerr := eng.tree_read(&n.e, ob.o, nm, context.temp_allocator, ready)
			if _incomplete(rerr) {
				return Digest{why = fmt.tprintf("%s %v @%d", "rerr", rerr, #line)}
			}
			fmt.sbprintf(&b, "file %s err=%v %q\n", nm, rerr, _printable(data))
		}
	}
	return Digest{text = strings.clone(strings.to_string(b), w.allocator), complete = true, guest = guest}
}

@(private = "file")
_printable :: proc(data: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	zeros := 0
	for c in data {
		if c == 0 {
			zeros += 1
			continue
		}
		if zeros > 0 {
			fmt.sbprintf(&b, "\\0x%d;", zeros)
			zeros = 0
		}
		strings.write_byte(&b, c)
	}
	if zeros > 0 {
		fmt.sbprintf(&b, "\\0x%d;", zeros)
	}
	return strings.to_string(b)
}

readers_of :: proc(w: ^World, oi: int) -> []int {
	m := &w.model
	out := make([dynamic]int, context.temp_allocator)
	for n in w.nodes {
		if obj_reader(m, oi, n.idx) {
			append(&out, n.idx)
		}
	}
	return out[:]
}

obj_exists :: proc(m: ^Model, oi: int) -> bool {
	cop := m.ops[m.objs[oi].op]
	return cop.status != .Lost && cop.status != .Failed
}

check_convergence :: proc(w: ^World, final: bool) -> (converged: bool) {
	m := &w.model
	converged = true
	for _, oi in m.objs {
		if !obj_exists(m, oi) {
			continue
		}
		rs := readers_of(w, oi)
		ref: Digest
		refn := -1
		for idx in rs {
			n := w.nodes[idx]
			d := digest_object(w, n, oi)
			if !d.complete {
				converged = false
				if final {
					world_fail(w, "convergence: %s could not fully read %v %s (%s)", n.name, m.objs[oi].kind, id_short(m.objs[oi].o.id), d.why)
				}
				continue
			}
			if refn < 0 {
				ref = d
				refn = idx
				continue
			}
			if _strip_catalog(d.text, d.guest || ref.guest) != _strip_catalog(ref.text, d.guest || ref.guest) {
				converged = false
				if final {
					world_fail(w, "convergence: %v %s differs between %s and %s:\n--- %s\n%s--- %s\n%s", m.objs[oi].kind, id_short(m.objs[oi].o.id), w.nodes[refn].name, n.name, w.nodes[refn].name, ref.text, n.name, d.text)
				}
			}
			delete(d.text, w.allocator)
		}
		if refn >= 0 {
			if final {
				check_object_model(w, oi, w.nodes[refn], ref.text)
			}
			delete(ref.text, w.allocator)
		}
	}
	return
}

check_object_model :: proc(w: ^World, oi: int, n: ^Node, digest: string) {
	m := &w.model
	ob := &m.objs[oi]
	context = instance_context(&n.inst)
	defer node_after(n)
	switch ob.kind {
	case .Convo:
		for op in m.ops {
			if op.obj != oi || op.kind != .Send || obj.rid_none(op.rid) {
				continue
			}
			msg, err := eng.convo_message(&n.e, ob.o, convo.Position{msg = op.rid}, context.temp_allocator)
			present := err == .None && msg.author == op.actor && (msg.redacted || msg_text(msg) == op.token)
			redacted := _redacted_by(m, op)
			switch op.status {
			case .Acked, .Observed, .Done:
				if !present {
					world_fail(w, "model: message %s (op %d, %v) missing on %s: %v", op.token, op.idx, op.status, n.name, err)
				} else if redacted && !msg.redacted {
					world_fail(w, "redaction: message %s still readable on %s", op.token, n.name)
				}
			case .Uncertain:
				if present {
					op.status = .Observed
				} else {
					op.status = .Lost
				}
			case .Lost:
				if present && msg_text(msg) == op.token {
					world_fail(w, "model: lost message %s resurrected on %s", op.token, n.name)
				}
			case .Issued, .Failed:
			}
		}
	case .Map:
		for op in m.ops {
			if op.obj != oi || op.kind != .Map_Set {
				continue
			}
			en, found, err := eng.map_get(&n.e, ob.o, transmute([]u8)op.key, context.temp_allocator)
			present := false
			if err == .None && found {
				for r in en.registers {
					present ||= r.tag == 1 && string(r.value) == op.token
				}
			}
			redacted := _redacted_by(m, op)
			if redacted {
				if present {
					world_fail(w, "redaction: map key %s still readable on %s", op.key, n.name)
				}
				continue
			}
			switch op.status {
			case .Acked, .Observed, .Done:
				if !present {
					world_fail(w, "model: map key %s (op %d, %v) missing on %s", op.key, op.idx, op.status, n.name)
				}
			case .Uncertain:
				op.status = .Observed if present else .Lost
			case .Lost:
				if present {
					world_fail(w, "model: lost map write %s resurrected on %s", op.key, n.name)
				}
			case .Issued, .Failed:
			}
		}
		_check_counters(w, oi, n)
	case .Text, .Tree:
		_check_tokens(w, oi, n)
	}
}

@(private = "file")
_redacted_by :: proc(m: ^Model, target: ^M_Op) -> bool {
	for op in m.ops {
		if op.target == target.idx && (op.kind == .Redact_Msg || op.kind == .Redact_Map) && op_happened(op) {
			return true
		}
	}
	return false
}

@(private = "file")
_check_counters :: proc(w: ^World, oi: int, n: ^Node) {
	m := &w.model
	ob := &m.objs[oi]
	keys := [?]string{"c/0", "c/1"}
	for key in keys {
		lo, hi: i64
		any := false
		for op in m.ops {
			if op.obj != oi || op.kind != .Count || op.key != key {
				continue
			}
			any = true
			if op_happened(op) {
				lo += op.delta
				hi += op.delta
			} else if op.status == .Uncertain {
				if op.delta < 0 {
					lo += op.delta
				} else {
					hi += op.delta
				}
			}
		}
		if !any {
			continue
		}
		en, found, err := eng.map_get(&n.e, ob.o, transmute([]u8)key, context.temp_allocator)
		v: i64
		if err == .None && found {
			v, _ = omap.counter_value(&en, 7)
		}
		if v < lo || v > hi {
			world_fail(w, "model: counter %s on %s is %d, expected within [%d, %d]", key, n.name, v, lo, hi)
		}
	}
}

@(private = "file")
_check_tokens :: proc(w: ^World, oi: int, n: ^Node) {
	m := &w.model
	ob := &m.objs[oi]
	Seen :: struct {
		file:   string,
		actors: [dynamic]prim.Id,
	}
	present := make(map[string]Seen, context.temp_allocator)
	collect :: proc(present: ^map[string]Seen, data: []u8, spans: []crdt_span, file: string) {
		toks := parse_tokens(data)
		for t in toks {
			s := Seen{file = file, actors = make([dynamic]prim.Id, context.temp_allocator)}
			at := 0
			for sp in spans {
				lo := max(at, t.pos)
				hi := min(at + sp.len, t.pos + len(t.text))
				if lo < hi {
					already := false
					for x in s.actors {
						already ||= x == sp.actor
					}
					if !already {
						append(&s.actors, sp.actor)
					}
				}
				at += sp.len
			}
			present[t.text] = s
		}
	}
	if ob.kind == .Text {
		data, err := eng.text_read(&n.e, ob.o, context.temp_allocator)
		if err != .None {
			world_fail(w, "model: text %s unreadable on %s: %v", id_short(ob.o.id), n.name, err)
			return
		}
		raw, _ := eng.text_spans(&n.e, ob.o, context.temp_allocator)
		spans := make([dynamic]crdt_span, context.temp_allocator)
		total := 0
		for s in raw {
			append(&spans, crdt_span{actor = s.id.actor, len = s.len})
			total += s.len
		}
		if total != len(data) {
			world_fail(w, "attribution: text %s on %s has %d bytes but spans cover %d", id_short(ob.o.id), n.name, len(data), total)
		}
		collect(&present, data, spans[:], "")
	} else {
		names, _ := eng.tree_list(&n.e, ob.o, "", context.temp_allocator)
		for nm in names {
			data, _ := eng.tree_read(&n.e, ob.o, nm, context.temp_allocator)
			collect(&present, data, nil, nm)
		}
	}
	for op in m.ops {
		if op.obj != oi {
			continue
		}
		if !(op.kind == .Text_Insert || op.kind == .Tree_Write || op.kind == .Create) {
			continue
		}
		for tok in op.tokens {
			s, is := present[tok]
			if is && ob.kind == .Text {
				for a in s.actors {
					if a != op.actor {
						world_fail(w, "attribution: token %s written by %s is credited to %s on %s", tok, id_short(op.actor), id_short(a), n.name)
					}
				}
			}
			deleted := false
			maybe_deleted := false
			for d in m.ops {
				if d.obj != oi {
					continue
				}
				for x in d.deletes {
					if x == tok {
						if op_happened(d) {
							deleted = true
						} else if d.status == .Uncertain {
							maybe_deleted = true
						}
					}
				}
			}
			removed := false
			if ob.kind == .Tree {
				for d in m.ops {
					if d.obj == oi && d.kind == .Tree_Remove && op_maybe(d) && d.path == op.path {
						removed = true
					}
				}
			}
			switch op.status {
			case .Acked, .Observed, .Done:
				if deleted && is {
					world_fail(w, "model: token %s deleted but still present on %s", tok, n.name)
				} else if !deleted && !maybe_deleted && !removed && !is {
					world_fail(w, "model: token %s (op %d %v %v) missing on %s", tok, op.idx, op.kind, op.status, n.name)
				}
			case .Uncertain:
				if is {
					op.status = .Observed
				}
			case .Lost:
				if is {
					world_fail(w, "model: token %s from a lost op resurrected on %s", tok, n.name)
				}
			case .Issued, .Failed:
				if is && op.status == .Failed {
					world_fail(w, "model: token %s from a failed op is present on %s", tok, n.name)
				}
			}
		}
	}
	keys := make([dynamic]string, context.temp_allocator)
	for tok in present {
		append(&keys, tok)
	}
	slice.sort(keys[:])
	for tok in keys {
		if _token_op(m, oi, tok) == nil {
			world_fail(w, "model: unknown token %s present in %s on %s", tok, id_short(ob.o.id), n.name)
		}
	}
}

crdt_span :: struct {
	actor: prim.Id,
	len:   int,
}

check_redaction :: proc(w: ^World) {
	m := &w.model
	secrets := make([dynamic]string, context.temp_allocator)
	for op in m.ops {
		if !op_happened(op) {
			continue
		}
		switch op.kind {
		case .Redact_Msg, .Redact_Map:
			if op.target >= 0 {
				t := m.ops[op.target]
				append(&secrets, t.token)
			}
		case .Redact_Text:
			for d in op.deletes {
				append(&secrets, d)
			}
		case .Create, .Send, .Queue, .Steer, .Edit, .Cancel, .Interrupt, .Switch, .Back, .Follow, .Answer, .Assign, .Mount, .Unmount, .Map_Set, .Map_Hot, .Map_Add, .Map_Remove, .Map_Delete, .Count, .Text_Insert, .Text_Delete, .Tree_Write, .Tree_Remove, .Catalog, .Usage, .Share:
		}
	}
	for s in secrets {
		needle := transmute([]u8)s
		for n in w.nodes {
			if p, found := disk_contains(&n.disk, needle); found {
				world_fail(w, "redaction: %s still on %s disk in %s", s, n.name, p)
			}
			if n.alive && n.e_open {
				context = instance_context(&n.inst)
				req := search.Request{limit = 8, now = eng.hlc_now(&n.e)}
				res, err := eng.search_query(&n.e, s[1:len(s) - 1], req, context.temp_allocator)
				if err == .None {
					for h in res.hits {
						if strings.contains(h.snippet, s[1:len(s) - 1]) {
							world_fail(w, "redaction: search on %s still returns %s in a snippet (object %s): %q", n.name, s, id_short(h.object), h.snippet)
						}
					}
				}
				node_after(n)
			}
		}
		if p, found := disk_contains(&w.relay.disk, needle); found {
			world_fail(w, "redaction: %s still on relay disk in %s", s, p)
		}
	}
}

check_relay_plaintext :: proc(w: ^World) {
	m := &w.model
	for op in m.ops {
		toks := make([dynamic]string, context.temp_allocator)
		if len(op.token) > 0 {
			append(&toks, op.token)
		}
		for t in op.tokens {
			append(&toks, t)
		}
		for t in toks {
			if p, found := disk_contains(&w.relay.disk, transmute([]u8)t); found {
				world_fail(w, "confidentiality: plaintext %s on relay disk in %s", t, p)
				return
			}
		}
	}
}

check_idle :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive {
			continue
		}
		if a := loop_armed(&n.inst.loop); a > 0 {
			world_fail(w, "idle: %s has %d armed timers after settle (batches=%d dirty=%d durable_tick=%d tick=%d pack_pressure=%v)", n.name, a, len(n.e.batches), len(n.e.dirty), n.e.durable_tick, n.e.tick, eng.pressured(&n.e))
			for h in n.inst.loop.heap {
				t := n.inst.loop.timers[h]
				world_note(w, "  armed timer cb=%p ref=%p due in %d ms", rawptr(t.cb), rawptr(prim.loop_step), (t.deadline - prim.loop_now_ns(&n.inst.loop)) / 1_000_000)
			}
		}
		if loop_ready(&n.inst.loop) {
			world_fail(w, "idle: %s has pending wakeups after settle", n.name)
		}
	}
	if w.relay.alive {
		if a := loop_armed(&w.relay.inst.loop); a > 0 {
			world_fail(w, "idle: relay has %d armed timers after settle", a)
		}
	}
}

dump_replication :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive {
			continue
		}
		sids := make([dynamic]prim.Id, context.temp_allocator)
		for id in n.e.spaces {
			append(&sids, id)
		}
		slice.sort_by(sids[:], id_less)
		for id in sids {
			sp := n.e.spaces[id]
			if !sp.repl_on {
				continue
			}
			r := &sp.repl
			world_note(w, "dump %s space %s phase=%v connected=%v locals=%d remotes=%d uploading=%d hold=%d", n.name, id_short(id), r.phase, sp.connected, len(r.locals), len(r.remotes), r.uploading, r.hold)
			rms := make([dynamic]^osync.Remote, context.temp_allocator)
			for _, rm in r.remotes {
				append(&rms, rm)
			}
			slice.sort_by(rms[:], proc(a, b: ^osync.Remote) -> bool {
				return a.name < b.name || (a.name == b.name && id_less(a.device, b.device))
			})
			for rm in rms {
				world_note(w, "  remote dev=%s %s relay_len=%d tail=%d rep_len=%d have=%v wants=%v inflight=%v follow=%v full=%v quar=%v held=%d pulled=%d pulling=%v refs=%d", id_short(rm.device), rm.name, rm.relay_len, rm.tail, rm.rep.length, rm.rep.have[:], rm.wants[:], rm.inflight[:], rm.follow, rm.full, rm.quarantined, rm.held, rm.pulled, rm.pulling, rm.refs)
			}
			lls := make([dynamic]^osync.Local, context.temp_allocator)
			for _, l in r.locals {
				append(&lls, l)
			}
			slice.sort_by(lls[:], proc(a, b: ^osync.Local) -> bool {
				return a.name < b.name
			})
			for l in lls {
				world_note(w, "  local %s cursor=%d durable=%d floor=%d inflight=%d blocked=%v fatal=%v retry=%v verifying=%v", l.name, l.cursor, l.durable, l.floor, l.inflight, l.blocked, l.fatal, l.retry, l.verifying)
			}
		}
	}
}

@(private = "file")
_strip_catalog :: proc(text: string, strip: bool) -> string {
	if !strip || !strings.has_prefix(text, "catalog ") {
		return text
	}
	i := strings.index_byte(text, '\n')
	return text[i + 1:] if i >= 0 else ""
}
