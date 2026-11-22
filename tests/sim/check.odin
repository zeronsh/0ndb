package sim

import "core:fmt"
import "core:slice"
import "core:strings"
import "../../src/convo"
import "../../src/crdt"
import "../../src/fs"
import "../../src/journal"
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
			if op.obj == oi && (op.kind == .Send || op.kind == .Stream) && op.status != .Lost && op.status != .Failed && !obj.rid_none(op.rid) {
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

known_tokens :: proc(m: ^Model) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	for op in m.ops {
		if len(op.token) > 0 {
			out[op.token] = true
		}
		for t in op.tokens {
			out[t] = true
		}
	}
	return out
}

check_integrity :: proc(w: ^World, n: ^Node, oi: int, d: ^Digest, known: ^map[string]bool) {
	merged := merged_files(w, oi) if w.model.objs[oi].kind == .Tree else nil
	for line in strings.split_lines(d.text, context.temp_allocator) {
		if merged != nil && strings.has_prefix(line, "file ") {
			rest := line[5:]
			if sp := strings.index_byte(rest, ' '); sp > 0 && file_base(rest[:sp]) in merged {
				continue
			}
		}
		check_integrity_line(w, n, oi, line, known)
	}
}

check_integrity_line :: proc(w: ^World, n: ^Node, oi: int, line: string, known: ^map[string]bool) {
	for t in parse_tokens(transmute([]u8)line) {
		if !(t.text in known) {
			world_fail(w, "integrity: %s presents content no participant wrote in %v %s: %q", n.name, w.model.objs[oi].kind, id_short(w.model.objs[oi].o.id), t.text)
		}
	}
}

stall :: proc(w: ^World, format: string, args: ..any) {
	if w.cfg.byzantine {
		w.stats.stalls += 1
		world_note(w, format, ..args)
		return
	}
	world_fail(w, format, ..args)
}

check_convergence :: proc(w: ^World, final: bool) -> (converged: bool) {
	m := &w.model
	converged = true
	known := known_tokens(m)
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
					stall(w, "convergence: %s could not fully read %v %s (%s)", n.name, m.objs[oi].kind, id_short(m.objs[oi].o.id), d.why)
				}
				continue
			}
			if final {
				check_integrity(w, n, oi, &d, &known)
			}
			if refn < 0 {
				ref = d
				refn = idx
				continue
			}
			if _strip_catalog(d.text, d.guest || ref.guest) != _strip_catalog(ref.text, d.guest || ref.guest) {
				converged = false
				if final {
					stall(w, "convergence: %v %s differs between %s and %s:\n--- %s\n%s--- %s\n%s", m.objs[oi].kind, id_short(m.objs[oi].o.id), w.nodes[refn].name, n.name, w.nodes[refn].name, ref.text, n.name, d.text)
				}
			}
			delete(d.text, w.allocator)
		}
		if refn >= 0 {
			if final && w.cfg.verbose && !w.cfg.quiet && m.objs[oi].kind != .Convo {
				fmt.eprintf("[%9.3f] final %v %s on %s:\n%s\n", f64(w.now) / 1e6, m.objs[oi].kind, id_short(m.objs[oi].o.id), w.nodes[refn].name, ref.text)
			}
			if final && !w.cfg.byzantine {
				check_object_model(w, oi, w.nodes[refn], ref.text)
				check_conflicts(w, oi)
			}
			delete(ref.text, w.allocator)
		}
	}
	return
}

check_map_reapply :: proc(w: ^World) {
	m := &w.model
	for _, oi in m.objs {
		if !obj_exists(m, oi) || m.objs[oi].kind != .Map {
			continue
		}
		rs := readers_of(w, oi)
		if len(rs) == 0 {
			continue
		}
		n := w.nodes[rs[int(m.objs[oi].o.id[0]) % len(rs)]]
		before := digest_object(w, n, oi)
		defer delete(before.text, w.allocator)
		if !before.complete {
			continue
		}
		context = instance_context(&n.inst)
		err := eng.map_reapply(&n.e, m.objs[oi].o)
		node_after(n)
		if err != .None {
			world_fail(w, "idempotence: %s could not re-apply Map %s: %v", n.name, id_short(m.objs[oi].o.id), err)
			continue
		}
		after := digest_object(w, n, oi)
		defer delete(after.text, w.allocator)
		if after.text != before.text {
			world_fail(w, "idempotence: re-applying every record of Map %s on %s changed it:\n--- before\n%s--- after\n%s", id_short(m.objs[oi].o.id), n.name, before.text, after.text)
		}
	}
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
			if err == .Busy {
				world_note(w, "model: message %s unknown on %s (Busy)", op.token, n.name)
				continue
			}
			present := err == .None && msg.author == op.actor && (msg.redacted || msg_text(msg) == msg_body(op.token))
			if err == .None {
				_settle_redaction(m, op, msg.redacted)
			}
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
					if err == .None && !msg.redacted {
						world_fail(w, "rid: id of lost message %s names %q on %s", op.token, msg_text(msg), n.name)
					}
				}
			case .Lost:
				if present && msg_text(msg) == msg_body(op.token) {
					world_fail(w, "model: lost message %s resurrected on %s", op.token, n.name)
				} else if err == .None && !msg.redacted {
					world_fail(w, "rid: id of lost message %s names %q on %s", op.token, msg_text(msg), n.name)
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
			if err == .Busy {
				world_note(w, "model: map key %s unknown on %s (Busy)", op.key, n.name)
				continue
			}
			present := false
			if err == .None && found {
				for r in en.registers {
					present ||= r.tag == 1 && string(r.value) == op.token
				}
			}
			if !obj.rid_none(op.rid) {
				if state, known := _record_state(n, ob, op.rid); known {
					_settle_redaction(m, op, state == .Redacted)
				}
			}
			redacted := _redacted_by(m, op)
			if redacted {
				if present {
					world_fail(w, "redaction: map key %s still readable on %s", op.key, n.name)
				}
				continue
			}
			if !present && redaction_maybe(m, op) {
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
_settle_redaction :: proc(m: ^Model, target: ^M_Op, gone: bool) {
	for op in m.ops {
		if op.target == target.idx && (op.kind == .Redact_Msg || op.kind == .Redact_Map) && op.status == .Uncertain {
			op.status = .Observed if gone else .Lost
		}
	}
}

@(private = "file")
_record_state :: proc(n: ^Node, ob: ^M_Obj, rid: eng.Rid) -> (state: Rec_State, known: bool) {
	h, ok := n.e.handles[ob.o.id]
	if !ok {
		return
	}
	for s in h.segs {
		if s.device != rid.seg {
			continue
		}
		_, _, err := journal.record_at(&s.jr, rid.off)
		#partial switch err {
		case .None:
			return .Live, true
		case .Redacted:
			return .Redacted, true
		}
	}
	return
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
		if err == .Busy {
			world_note(w, "model: text %s unknown on %s (Busy)", id_short(ob.o.id), n.name)
			return
		}
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
			spans := tree_file_spans(n, ob.o, nm)
			total := 0
			for sp in spans {
				total += sp.len
			}
			if total != len(data) {
				world_fail(w, "attribution: %s/%s on %s has %d bytes but spans cover %d", id_short(ob.o.id), nm, n.name, len(data), total)
			}
			collect(&present, data, spans, nm)
		}
	}
	merged := merged_files(w, oi, true) if ob.kind == .Tree else nil
	for op in m.ops {
		if op.obj != oi {
			continue
		}
		if merged != nil && op.path in merged {
			continue
		}
		if !(op.kind == .Text_Insert || op.kind == .Tree_Write || op.kind == .Create || op.kind == .Disk_Agent || op.kind == .Disk_Person || op.kind == .Git_Mount) {
			continue
		}
		for tok in op.tokens {
			s, is := present[tok]
			if is {
				diffed := (op.kind == .Disk_Agent || op.kind == .Disk_Person) && len(op.deletes) > 0
				own := false
				for a in s.actors {
					own ||= a == op.actor
					if a == op.actor {
						continue
					}
					if op.kind == .Disk_Agent && op.power_crash && fs.is_unattributed(a) {
						own = true
						continue
					}
					if !diffed {
						world_fail(w, "attribution: token %s written by %s is credited to %s on %s", tok, id_short(op.actor), id_short(a), n.name)
					} else if !_wrote_file(m, oi, s.file, a) {
						world_fail(w, "attribution: token %s written by %s is partly credited to %s, which never wrote %s, on %s", tok, id_short(op.actor), id_short(a), s.file, n.name)
					}
				}
				if !own && len(s.actors) > 0 {
					world_fail(w, "attribution: no byte of token %s is credited to its writer %s on %s", tok, id_short(op.actor), n.name)
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
					if d.obj == oi && (d.kind == .Tree_Remove || d.kind == .Disk_Person || d.kind == .Disk_Agent || d.kind == .Tree_Write) && op_maybe(d) && d.path == op.path && d.kind == .Tree_Remove {
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
		if merged != nil && file_base(present[tok].file) in merged {
			continue
		}
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
	check_snapshot_restore(w)
	m := &w.model
	secrets := make([dynamic]string, context.temp_allocator)
	owners := make([dynamic]int, context.temp_allocator)
	for op in m.ops {
		if !op_happened(op) {
			continue
		}
		switch op.kind {
		case .Redact_Msg, .Redact_Map:
			if op.target >= 0 {
				t := m.ops[op.target]
				append(&secrets, t.token)
				append(&owners, op.obj)
			}
		case .Redact_Text:
			for d in op.deletes {
				append(&secrets, d)
				append(&owners, op.obj)
			}
		case .Create, .Send, .Queue, .Steer, .Edit, .Cancel, .Interrupt, .Switch, .Back, .Follow, .Answer, .Assign, .Mount, .Unmount, .Map_Set, .Map_Hot, .Map_Add, .Map_Remove, .Map_Delete, .Count, .Text_Insert, .Text_Delete, .Tree_Write, .Tree_Remove, .Catalog, .Usage, .Share, .Mount_Tree, .Disk_Agent, .Disk_Person, .Git_Mount, .Search_Peer, .Promote, .Read_Live, .Stream:
		}
	}
	for s, si in secrets {
		needle := transmute([]u8)s
		for n in w.nodes {
			if p, found := disk_contains(&n.disk, needle); found {
				redaction_finding(w, n, owners[si], "redaction: %s still on %s disk in %s", s, n.name, p)
			}
			if n.alive && n.e_open {
				context = instance_context(&n.inst)
				req := search.Request{limit = 8, now = eng.hlc_now(&n.e)}
				res, err := eng.search_query(&n.e, s[1:len(s) - 1], req, context.temp_allocator)
				if err == .None {
					for h in res.hits {
						if _snippet_leaks(h.snippet, s[1:len(s) - 1]) {
							redaction_finding(w, n, owners[si], "redaction: search on %s still returns %s in a snippet (object %s): %q", n.name, s, id_short(h.object), h.snippet)
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
	check_search_models(w, secrets[:], owners[:])
	check_peer_redaction(w, secrets[:], owners[:])
}

@(private = "file")
_snippet_leaks :: proc(snippet: string, tok: string) -> bool {
	rest := snippet
	for {
		i := strings.index(rest, tok)
		if i < 0 {
			return false
		}
		after := i + len(tok)
		if after >= len(rest) || rest[after] < '0' || rest[after] > '9' {
			return true
		}
		rest = rest[i + 1:]
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
			world_fail(w, "idle: %s has %d armed timers after settle (batches=%d dirty=%d durable_tick=%d tick=%d pack_pressure=%v): %s", n.name, a, len(n.e.batches), len(n.e.dirty), n.e.durable_tick, n.e.tick, eng.pressured(&n.e), armed_timers(&n.inst.loop))
		}
		if loop_ready(&n.inst.loop) {
			world_fail(w, "idle: %s has pending wakeups after settle", n.name)
		}
	}
	if w.relay.alive {
		if a := loop_armed(&w.relay.inst.loop); a > 0 {
			world_fail(w, "idle: relay has %d armed timers after settle: %s", a, armed_timers(&w.relay.inst.loop))
		}
	}
}

armed_timers :: proc(l: ^prim.Loop) -> string {
	b := strings.builder_make(context.temp_allocator)
	for h, i in l.heap {
		t := l.timers[h]
		fmt.sbprintf(&b, "%s%s armed at %s:%d due in %d ms", "" if i == 0 else "; ", t.owner.procedure, t.owner.file_path[strings.last_index_byte(t.owner.file_path, '/') + 1:], t.owner.line, (t.deadline - prim.loop_now_ns(l)) / 1_000_000)
	}
	return strings.to_string(b)
}

dump_replication :: proc(w: ^World) {
	for c in w.relay.r.conns {
		if c == nil {
			continue
		}
		world_note(w, "  relay conn %s state=%v paused=%v closing=%v pipe_wait=%v piped=%d inflight=%d out=%d stash=%d feed_on=%v", id_short(c.principal.participant), c.state, c.paused, c.closing, c.pipe_wait, c.piped, c.inflight, len(c.out) - c.out_head, len(c.stash), c.feed_on)
	}
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
			world_note(w, "dump %s space %s phase=%v connected=%v locals=%d remotes=%d uploading=%d hold=%d queued=%d streaming=%v serves=%d promos=%d", n.name, id_short(id), r.phase, sp.connected, len(r.locals), len(r.remotes), r.uploading, r.hold, osync.client_queued(&r.client), r.client.streaming, len(r.serves), len(r.promos))
			rms := make([dynamic]^osync.Remote, context.temp_allocator)
			for _, rm in r.remotes {
				append(&rms, rm)
			}
			slice.sort_by(rms[:], proc(a, b: ^osync.Remote) -> bool {
				return a.name < b.name || (a.name == b.name && id_less(a.device, b.device))
			})
			for rm in rms {
				world_note(w, "  remote dev=%s %s relay_len=%d tail=%d rep_len=%d have=%v wants=%v inflight=%v follow=%v full=%v quar=%v held=%d pulled=%d pulling=%v refs=%d probing=%v keys_wait=%v kheld=%d base=%d pulls=%v unavail=%v", id_short(rm.device), rm.name, rm.relay_len, rm.tail, rm.rep.length, rm.rep.have[:], rm.wants[:], rm.inflight[:], rm.follow, rm.full, rm.quarantined, rm.held, rm.pulled, rm.pulling, rm.refs, rm.probing, rm.keys_wait, len(rm.kheld), rm.base, rm.pulls[:], rm.unavail)
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

Rec_State :: enum u8 {
	Live,
	Redacted,
}

Rec_Key :: struct {
	device: prim.Id,
	off:    i64,
}

@(private = "file")
_kind_prefix :: proc(k: M_Kind) -> u8 {
	switch k {
	case .Convo:
		return 'c'
	case .Map:
		return 'm'
	case .Text:
		return 't'
	case .Tree:
		return 'f'
	}
	return 'm'
}

@(private = "file")
_open_handle :: proc(n: ^Node, ob: ^M_Obj) -> ^eng.Handle {
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
_node_records :: proc(w: ^World, n: ^Node, ob: ^M_Obj, out: ^map[Rec_Key]Rec_State) {
	context = instance_context(&n.inst)
	defer node_after(n)
	h := _open_handle(n, ob)
	if h == nil {
		return
	}
	for s in h.segs {
		end := journal.reader_end(&s.jr)
		pos: i64
		for pos < end {
			_, next, err := journal.record_at(&s.jr, pos)
			if err == .Redacted {
				out[Rec_Key{s.device, pos}] = .Redacted
			} else if err == .None {
				out[Rec_Key{s.device, pos}] = .Live
			} else {
				break
			}
			if next <= pos {
				break
			}
			pos = next
		}
	}
}

@(private = "file")
_relay_records :: proc(w: ^World, space: prim.Id, id: osync.Stream_Id, out: ^map[i64]Rec_State, zeros_bad: ^[dynamic]i64) -> bool {
	rn := &w.relay
	context = instance_context(&rn.inst)
	defer relay_after(rn)
	r := &rn.r
	st := r.store
	ns: rawptr
	opened_ns := false
	if sp, ok := r.spaces[space]; ok && sp.ns != nil {
		ns = sp.ns
	} else {
		h, _, err := st.namespace_open(st.data, space)
		if err != .None {
			return false
		}
		ns = h
		opened_ns = true
	}
	defer if opened_ns {
		st.namespace_close(st.data, ns)
	}
	sh, length, serr := st.stream_open(st.data, ns, id, false)
	if serr != .None || sh == nil {
		return false
	}
	defer st.stream_close(st.data, sh)
	hdr: [20]u8
	pos := st.stream_base(st.data, sh)
	for pos + 24 <= length {
		got, rerr := st.stream_read(st.data, sh, pos, hdr[:])
		if rerr != .None || got != len(hdr) {
			break
		}
		n := i64(prim.get_u32le(hdr[0:4]))
		if pos + n + 24 > length {
			break
		}
		tag: journal.Tag
		copy(tag[:], hdr[4:20])
		if tag == journal.redacted_tag(pos, int(n)) {
			out[pos] = .Redacted
			body := make([]u8, n, context.temp_allocator)
			if bgot, berr := st.stream_read(st.data, sh, pos + 20, body); berr == .None && i64(bgot) == n {
				for b in body {
					if b != 0 {
						append(zeros_bad, pos)
						break
					}
				}
			}
		} else {
			out[pos] = .Live
		}
		pos += n + 24
	}
	return true
}

check_relay_redaction :: proc(w: ^World) {
	m := &w.model
	if !w.relay.alive {
		return
	}
	for _, oi in m.objs {
		if !obj_exists(m, oi) {
			continue
		}
		ob := &m.objs[oi]
		readers := readers_of(w, oi)
		per_node := make([]map[Rec_Key]Rec_State, len(w.nodes), context.temp_allocator)
		devices := make([dynamic]prim.Id, context.temp_allocator)
		keyer := -1
		for idx in readers {
			n := w.nodes[idx]
			if !n.alive || !n.e_open {
				continue
			}
			per_node[idx] = make(map[Rec_Key]Rec_State, context.temp_allocator)
			_node_records(w, n, ob, &per_node[idx])
			for k in per_node[idx] {
				seen := false
				for d in devices {
					seen ||= d == k.device
				}
				if !seen {
					append(&devices, k.device)
				}
			}
			si := space_index(m, ob.o.space)
			if keyer < 0 && si >= 0 && space_member(&m.spaces[si], idx) {
				keyer = idx
			}
		}
		if keyer < 0 {
			continue
		}
		kn := w.nodes[keyer]
		scope: osync.Scope
		{
			context = instance_context(&kn.inst)
			key, kerr := eng.object_key(&kn.e, ob.o)
			info, _ := eng.space_info(&kn.e, ob.o.space)
			node_after(kn)
			if kerr != .None {
				continue
			}
			scope = osync.scope_make(key, info.mode)
		}
		name := make([]u8, 1 + prim.ID_HEX_LEN, context.temp_allocator)
		name[0] = _kind_prefix(ob.kind)
		hx := prim.id_hex(ob.o.id)
		copy(name[1:], hx[:])
		slice.sort_by(devices[:], id_less)
		for d in devices {
			sid := osync.stream_id(&scope, d, string(name), 0)
			relay := make(map[i64]Rec_State, context.temp_allocator)
			bad := make([dynamic]i64, context.temp_allocator)
			if !_relay_records(w, ob.o.space, sid, &relay, &bad) {
				continue
			}
			for off in bad {
				world_fail(w, "relay redaction: record %s@%d of %v %s is marked redacted on the relay but its ciphertext is not zero-filled", id_short(d), off, ob.kind, id_short(ob.o.id))
			}
			for idx in readers {
				if per_node[idx] == nil {
					continue
				}
				keys := make([dynamic]i64, context.temp_allocator)
				for k in per_node[idx] {
					if k.device == d {
						append(&keys, k.off)
					}
				}
				slice.sort(keys[:])
				for off in keys {
					ns := per_node[idx][Rec_Key{d, off}]
					rs, has := relay[off]
					if !has {
						continue
					}
					if ns == .Redacted && rs != .Redacted {
						world_fail(w, "relay redaction: relay still holds ciphertext of record %s@%d of %v %s, redacted on %s", id_short(d), off, ob.kind, id_short(ob.o.id), w.nodes[idx].name)
					} else if ns == .Live && rs == .Redacted {
						redaction_finding(w, w.nodes[idx], oi, "redaction: %s still holds record %s@%d of %v %s that the relay has redacted", w.nodes[idx].name, id_short(d), off, ob.kind, id_short(ob.o.id))
					}
				}
			}
		}
	}
}

@(private = "file")
_wrote_file :: proc(m: ^Model, oi: int, file: string, actor: prim.Id) -> bool {
	for op in m.ops {
		if op.obj == oi && op.actor == actor && (op.kind == .Disk_Agent || op.kind == .Disk_Person || op.kind == .Tree_Write || op.kind == .Git_Mount) {
			return true
		}
	}
	return false
}

token_in :: proc(text: string, tok: string) -> bool {
	inner := tok[1:len(tok) - 1]
	at := 0
	for at < len(text) {
		i := strings.index(text[at:], inner)
		if i < 0 {
			return false
		}
		start := at + i
		end := start + len(inner)
		before_ok := start == 0 || !_tok_char(text[start - 1]) || text[start - 1] == '<'
		after_ok := end == len(text) || !_tok_char(text[end]) || text[end] == '>'
		if before_ok && after_ok {
			return true
		}
		at = start + 1
	}
	return false
}

@(private = "file")
_tok_char :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '.'
}

@(private = "file")
_rewrites :: proc(op: ^M_Op) -> bool {
	return op.kind == .Tree_Write || ((op.kind == .Disk_Agent || op.kind == .Disk_Person) && op.overwrite)
}

@(private = "file")
_has_any :: proc(set: []string, xs: []string) -> bool {
	for a in set {
		for b in xs {
			if a == b {
				return true
			}
		}
	}
	return false
}

Pair :: struct {
	a: ^M_Op,
	b: ^M_Op,
}

concurrent_pairs :: proc(w: ^World, oi: int) -> []Pair {
	m := &w.model
	out := make([dynamic]Pair, context.temp_allocator)
	ops := make([dynamic]^M_Op, context.temp_allocator)
	for op in m.ops {
		if op.obj == oi && _rewrites(op) && op_maybe(op) {
			append(&ops, op)
		}
	}
	for a in ops {
		for b in ops {
			if a.node == b.node || a.path != b.path || a.at > b.at || (a.at == b.at && a.idx >= b.idx) {
				continue
			}
			live := true
			for d in m.ops {
				if d.obj == oi && d.at < b.at && d.idx != a.idx && op_maybe(d) && _has_any(d.deletes[:], a.tokens[:]) {
					live = false
					break
				}
			}
			if live && !_has_any(b.deletes[:], a.tokens[:]) {
				append(&out, Pair{a, b})
			}
		}
	}
	return out[:]
}

merged_files :: proc(w: ^World, oi: int, count := false) -> map[string]bool {
	m := &w.model
	out := make(map[string]bool, context.temp_allocator)
	for p in concurrent_pairs(w, oi) {
		if count {
			w.stats.conflict_pairs += 1
			world_note(w, "live merge: %s and %s rewrote %s/%s concurrently (ops %d, %d)", w.nodes[p.a.node].name, w.nodes[p.b.node].name, id_short(m.objs[oi].o.id), p.a.path, p.a.idx, p.b.idx)
		}
		out[p.a.path] = true
	}
	return out
}

@(private = "file")
_side_has :: proc(spans: []crdt.Op_Span, op: ^M_Op) -> bool {
	for s in spans {
		if s.id.actor == op.actor {
			return true
		}
		if op.kind == .Disk_Agent && op.power_crash && fs.is_unattributed(s.id.actor) {
			return true
		}
	}
	return false
}

@(private = "file")
_survived :: proc(m: ^Model, op: ^M_Op) -> bool {
	if op_happened(op) {
		return true
	}
	if op.status != .Uncertain {
		return false
	}
	for d in m.ops {
		if d == op || d.obj != op.obj || !op_maybe(d) || !_has_any(d.deletes[:], op.tokens[:]) {
			continue
		}
		if d.node != op.node || d.inc != op.inc || op_happened(d) {
			return true
		}
	}
	return false
}

check_conflicts :: proc(w: ^World, oi: int) {
	m := &w.model
	ob := &m.objs[oi]
	if ob.kind != .Tree {
		return
	}
	pairs := concurrent_pairs(w, oi)
	for idx in readers_of(w, oi) {
		n := w.nodes[idx]
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		list, err := eng.tree_conflicts(&n.e, ob.o, context.temp_allocator)
		node_after(n)
		if err != .None {
			if len(pairs) > 0 {
				world_fail(w, "conflict: %s cannot list conflicts of %s: %v", n.name, id_short(ob.o.id), err)
			}
			continue
		}
		for p in pairs {
			if !_has_any(p.a.deletes[:], p.b.deletes[:]) || !_survived(m, p.a) || !_survived(m, p.b) {
				continue
			}
			if r := pair_resolver(w, oi, p); r != nil {
				world_note(w, "conflict: pair ops %d/%d on %s resolved by op %d (%v), which saw both", p.a.idx, p.b.idx, p.a.path, r.idx, r.kind)
				continue
			}
			found := false
			for c in list {
				if file_base(c.path) != p.a.path {
					continue
				}
				if (_side_has(c.ours, p.a) && _side_has(c.theirs, p.b)) || (_side_has(c.ours, p.b) && _side_has(c.theirs, p.a)) {
					found = true
					break
				}
			}
			if !found {
				world_fail(w, "conflict: concurrent rewrites of %s/%s by %s (op %d) and %s (op %d) are not reported as a conflict region on %s (%d regions listed)", id_short(ob.o.id), p.a.path, id_short(p.a.actor), p.a.idx, id_short(p.b.actor), p.b.idx, n.name, len(list))
			}
		}
	}
}

file_base :: proc(name: string) -> string {
	if i := strings.index_byte(name, '~'); i >= 0 {
		return name[:i]
	}
	return name
}

pair_resolver :: proc(w: ^World, oi: int, p: Pair) -> ^M_Op {
	m := &w.model
	last := max(p.a.at, p.b.at)
	for r in m.ops {
		if r.obj != oi || r.path != p.a.path || r.idx == p.a.idx || r.idx == p.b.idx || !op_maybe(r) || r.at <= last {
			continue
		}
		if !(r.kind == .Tree_Remove || _rewrites(r)) {
			continue
		}
		if _has_any(r.deletes[:], p.a.tokens[:]) && _has_any(r.deletes[:], p.b.tokens[:]) {
			return r
		}
	}
	return nil
}
