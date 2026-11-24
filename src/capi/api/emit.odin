package api

import "core:unicode/utf8"
import "../../convo"
import eng "../../engine"
import omap "../../map"
import "../../prim"
import "../../search"
import osync "../../sync"

KIND_NAMES := [5]string{"", "conversation", "map", "text", "tree"}
ROLE_NAMES := [5]string{"", "user", "assistant", "system", "tool"}
BLOCK_NAMES := [12]string{"", "text", "reasoning", "tool_call", "tool_result", "image", "error", "notice", "permission", "permission_answer", "question", "file"}
SEAL_NAMES := [5]string{"open", "done", "interrupted", "failed", "cancelled"}
CONVO_STATUS_NAMES := [9]string{"idle", "running", "queued", "awaiting_permission", "failed", "interrupted", "waiting", "reviving", "held"}
OPEN_STATE_NAMES := [3]string{"running", "revive", "held"}
MOVE_CAUSE_NAMES := [6]string{"undo", "redo", "switch", "edit", "regenerate", "rebase"}
#assert(len(MOVE_CAUSE_NAMES) == len(convo.Move_Cause))
#assert(len(OPEN_STATE_NAMES) == len(convo.Open_State))
CONDITION_NAMES := [3]string{"", "any", "all"}
MODE_NAMES := [2]string{"end_to_end", "transparent"}
UNIT_NAMES := [2]string{"lines", "bytes"}
TREE_KIND_NAMES := [3]string{"file", "dir", "symlink"}
SORT_NAMES := [2]string{"relevance", "newest"}
SCOPE_NAMES := [3]string{"auto", "local", "everywhere"}
SEARCH_MODE_NAMES := [3]string{"default", "full", "local"}
SEARCH_STATE_NAMES := [7]string{"ok", "partial", "offline", "timeout", "denied", "failed", "cancelled"}
DIR_NAMES := [2]string{"older", "newer"}
EVENT_PLACEMENT :: u64(10)
TAKEOVER_NAMES := [3]string{"default", "auto", "never"}
TAKEOVER_LEVEL_NAMES := [3]string{"conversation", "agent", "workspace"}
RUNNER_KIND_NAMES := [2]string{"device", "pool"}
ISOLATE_NAMES := [3]string{"unset", "true", "false"}
RUNNER_STATE_NAMES := [3]string{"offline", "online", "wakeable"}
EVENT_NAMES := [34]string{"connected", "disconnected", "durable", "uploaded", "quarantined", "refused", "fatal", "space_joined", "object_seen", "failure", "placement", "relay_misbehaving", "presence", "caught_up", "indexer_wanted", "unavailable", "available", "promoted", "peer_misbehaving", "members_changed", "epoch_changed", "access_revoked", "runner_enrolled", "runner_anomaly", "approval_requested", "login_done", "login_failed", "lease_lapsed", "space_left", "line_switched", "replica_redacted", "rename_offered", "redact_unreached", "models_changed"}

event_code :: proc "contextless" (kind: eng.Event_Kind) -> u64 {
	switch kind {
	case .Connected, .Disconnected, .Durable, .Uploaded, .Quarantined, .Refused, .Fatal, .Space_Joined, .Object_Seen, .Failure:
		return u64(kind)
	case .Relay_Misbehaving:
		return 11
	case .Presence:
		return 12
	case .Caught_Up:
		return 13
	case .Indexer_Wanted:
		return 14
	case .Unavailable:
		return 15
	case .Available:
		return 16
	case .Promoted:
		return 17
	case .Peer_Misbehaving:
		return 18
	case .Members_Changed:
		return 19
	case .Epoch_Changed:
		return 20
	case .Access_Revoked:
		return 21
	case .Runner_Enrolled:
		return 22
	case .Runner_Anomaly:
		return 23
	case .Approval_Requested:
		return 24
	case .Login_Done:
		return 25
	case .Login_Failed:
		return 26
	case .Lease_Lapsed:
		return 27
	case .Space_Left:
		return 28
	case .Line_Switched:
		return 29
	case .Replica_Redacted:
		return 30
	case .Rename_Offered:
		return 31
	case .Redact_Unreached:
		return 32
	case .Models_Changed:
		return 33
	}
	return u64(len(EVENT_NAMES))
}
DELTA_NAMES := [19]string{"message", "block", "chunk", "seal", "leaf", "intent", "run", "mount", "record", "status", "field", "element", "counter", "catalog", "text", "files", "redacted", "members", "quarantined"}
INTENT_NAMES := [46]string {
	25 = "queue",
	26 = "steer",
	27 = "edit_queued",
	28 = "cancel",
	29 = "interrupt",
	30 = "answer",
	23 = "assign",
	37 = "await",
	45 = "hold",
}
ACCESS_NAMES := [4]string{"read", "write", "redact", "share"}
ROLE_MEMBER_NAMES := [4]string{"", "tree", "document", "memory"}

emit_usage :: proc(o: ^Out, name: string, u: convo.Usage) {
	o_obj(o, name)
	o_u64(o, "input", u.input)
	o_u64(o, "output", u.output)
	o_u64(o, "cache_read", u.cache_read)
	o_u64(o, "cache_write", u.cache_write)
	o_end(o)
}

emit_status :: proc(o: ^Out, st: ^eng.Convo_Status) {
	o_enum(o, "status", u64(st.status), CONVO_STATUS_NAMES[:])
	o_rid(o, "head", st.head)
	o_rid(o, "position", st.position)
	o_bool(o, "browsing", st.browsing)
	o_enum(o, "head_status", u64(st.head_status), SEAL_NAMES[:])
	o_int(o, "queued", st.queued)
	o_int(o, "waiting", st.waiting)
	o_int(o, "intents", st.intents)
	o_bool(o, "running", st.running)
	o_bool(o, "awaiting", st.awaiting)
	o_bool(o, "revive", st.revive)
	o_u64(o, "head_hlc", u64(st.head_hlc))
	o_int(o, "held", st.held)
}

emit_file_delta :: proc(o: ^Out, f: ^convo.File_Delta) {
	o_obj(o, "")
	o_str(o, "mount", f.mount)
	o_id(o, "tree", f.tree)
	o_id(o, "line", f.line)
	o_bytes(o, "version", f.version)
	o_end(o)
}

emit_blob :: proc(o: ^Out, name: string, b: convo.Blob) {
	o_obj(o, name)
	o_bytes(o, "oid", b.oid)
	o_u64(o, "size", b.size)
	o_text(o, "preview", b.preview)
	o_end(o)
}

emit_message :: proc(o: ^Out, name: string, m: ^convo.Message) {
	o_obj(o, name)
	o_rid(o, "id", m.id)
	o_enum(o, "role", u64(m.role), ROLE_NAMES[:])
	o_id(o, "author", m.author)
	o_rid(o, "parent", m.parent)
	o_i64(o, "depth", m.depth)
	o_id(o, "runner", m.runner)
	o_u64(o, "hlc", u64(m.hlc))
	o_str(o, "provider", m.provider)
	o_str(o, "model", m.model)
	o_str(o, "native", m.native)
	o_rid(o, "intent", m.intent)
	o_enum(o, "status", u64(m.status), SEAL_NAMES[:])
	o_bool(o, "open", m.open)
	o_enum(o, "open_state", u64(m.open_state), OPEN_STATE_NAMES[:])
	o_rid(o, "seal", m.seal)
	emit_usage(o, "usage", m.usage)
	o_bool(o, "redacted", m.redacted)
	o_int(o, "sibling", m.sibling)
	o_int(o, "siblings", m.siblings)
	o_bool(o, "superseded", m.superseded)
	o_bool(o, "landed", m.landed)
	o_rid(o, "claim", m.claim)
	o_arr(o, "files", len(m.files))
	for &f in m.files {
		emit_file_delta(o, &f)
	}
	o_end(o)
	o_arr(o, "lines", len(m.lines))
	for l in m.lines {
		o_obj(o, "")
		o_str(o, "mount", l.mount)
		o_id(o, "line", l.line)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "blocks", len(m.blocks))
	for &b in m.blocks {
		o_obj(o, "")
		o_u64(o, "index", u64(b.index))
		o_enum(o, "kind", u64(b.kind), BLOCK_NAMES[:])
		o_bool(o, "failed", b.failed)
		o_str(o, "id", b.id)
		o_str(o, "name", b.name)
		o_text(o, "text", b.text)
		o_bool(o, "is_ref", b.is_ref)
		emit_blob(o, "blob", b.blob)
		o_end(o)
	}
	o_end(o)
	o_end(o)
}

emit_position :: proc(o: ^Out, name: string, p: convo.Position) {
	o_obj(o, name)
	o_rid(o, "msg", p.msg)
	o_rid(o, "seal", p.seal)
	o_bool(o, "seal_known", p.seal_known)
	o_end(o)
}

CURSOR_VERSION :: u8(2)
CURSOR_END :: u8(1 << 0)
CURSOR_NEWER :: u8(1 << 1)
CURSOR_KNOWN :: u8(1 << 2)

Cursor :: struct {
	dir:  convo.Direction,
	pos:  convo.Position,
	leaf: Rid,
	end:  bool,
}

cursor_encode :: proc(c: Cursor) -> []u8 {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	f: u8
	if c.end {
		f |= CURSOR_END
	}
	if c.dir == .Newer {
		f |= CURSOR_NEWER
	}
	if c.pos.seal_known {
		f |= CURSOR_KNOWN
	}
	prim.write_u8(&w, CURSOR_VERSION)
	prim.write_u8(&w, f)
	for r in ([3]Rid{c.pos.msg, c.pos.seal, c.leaf}) {
		prim.write_id(&w, r.seg)
		prim.write_ivarint(&w, r.off)
		prim.write_uvarint(&w, r.gen)
	}
	return buf[:]
}

cursor_decode :: proc(b: []u8) -> (c: Cursor, ok: bool) {
	r := prim.reader(b)
	if prim.read_u8(&r) != CURSOR_VERSION {
		return {}, false
	}
	f := prim.read_u8(&r)
	rids: [3]Rid
	for &x in rids {
		x.seg = prim.read_id(&r)
		x.off = prim.read_ivarint(&r)
		x.gen = prim.read_uvarint(&r)
	}
	if !prim.reader_done(&r) || f & ~(CURSOR_END | CURSOR_NEWER | CURSOR_KNOWN) != 0 {
		return {}, false
	}
	c.end = f & CURSOR_END != 0
	c.dir = .Newer if f & CURSOR_NEWER != 0 else .Older
	c.pos = convo.Position{msg = rids[0], seal = rids[1], seal_known = f & CURSOR_KNOWN != 0}
	c.leaf = rids[2]
	return c, true
}

emit_edge :: proc(o: ^Out, name: string, p: convo.Position, present: bool) {
	if present {
		emit_position(o, name, p)
	} else if o.json {
		o_raw_json(o, name, "null")
	} else {
		emit_position(o, name, {})
	}
}

emit_page :: proc(o: ^Out, p: ^convo.Page, dir: convo.Direction, leaf: Rid) {
	o_arr(o, "messages", len(p.messages))
	for &m in p.messages {
		emit_message(o, "", &m)
	}
	o_end(o)
	emit_edge(o, "next", p.next, p.more)
	o_bool(o, "more", p.more)
	o_bytes(o, "cursor", cursor_encode(Cursor{dir = dir, pos = p.next if p.more else {}, leaf = leaf, end = !p.more}))
}

emit_intent :: proc(o: ^Out, it: ^convo.Intent) {
	o_obj(o, "")
	o_rid(o, "item", it.item)
	o_rid(o, "latest", it.latest)
	o_enum(o, "kind", u64(it.kind), INTENT_NAMES[:])
	o_id(o, "by", it.by)
	o_u64(o, "stamp", u64(it.stamp))
	o_str(o, "text", it.text)
	o_rid(o, "target", it.target)
	o_bool(o, "allow", it.allow)
	o_arr(o, "tasks", len(it.tasks))
	for t in it.tasks {
		o_id(o, "", t)
	}
	o_end(o)
	o_enum(o, "condition", u64(it.condition), CONDITION_NAMES[:])
	o_u64(o, "deadline", u64(it.deadline))
	o_str(o, "expr", it.expr)
	o_arr(o, "attachments", len(it.attachments))
	for at in it.attachments {
		o_obj(o, "")
		o_str(o, "name", at.name)
		o_str(o, "mime", at.mime)
		o_bytes(o, "oid", at.oid)
		o_u64(o, "size", at.size)
		o_end(o)
	}
	o_end(o)
	o_str(o, "key", it.key)
	o_end(o)
}

emit_mount_entry :: proc(o: ^Out, m: ^convo.Mount_Entry) {
	o_obj(o, "")
	o_str(o, "name", m.name)
	o_id(o, "tree", m.tree)
	o_id(o, "line", m.line)
	o_str(o, "path", m.path)
	o_u64(o, "stamp", u64(m.stamp))
	o_id(o, "by", m.by)
	o_bool(o, "removed", m.removed)
	o_end(o)
}

emit_delta :: proc(o: ^Out, d: ^eng.Delta) {
	o_obj(o, "")
	o_enum(o, "kind", u64(d.kind), DELTA_NAMES[:])
	o_object(o, "object", d.object)
	o_rid(o, "rid", d.rid)
	o_rid(o, "msg", d.msg)
	o_u64(o, "record", u64(d.record))
	o_id(o, "by", d.by)
	o_bool(o, "local", d.local)
	o_u64(o, "hlc", u64(d.hlc))
	o_enum(o, "role", u64(d.role), ROLE_NAMES[:])
	o_u64(o, "index", u64(d.index))
	o_enum(o, "block", u64(d.block), BLOCK_NAMES[:])
	o_enum(o, "seal", u64(d.seal), SEAL_NAMES[:])
	o_enum(o, "status", u64(d.status), CONVO_STATUS_NAMES[:])
	emit_usage(o, "usage", d.usage)
	o_text(o, "text", d.text)
	o_bytes(o, "key", d.key)
	o_u64(o, "tag", u64(d.tag))
	o_bool(o, "removed", d.removed)
	o_i64(o, "length", d.length)
	if o.json && d.draft {
		o_bool(o, "draft", true)
	}
	o_end(o)
}

emit_entry :: proc(o: ^Out, name: string, en: ^omap.Entry) {
	o_obj(o, name)
	o_bytes(o, "key", en.key)
	o_arr(o, "registers", len(en.registers))
	for r in en.registers {
		o_obj(o, "")
		o_u64(o, "tag", u64(r.tag))
		o_u64(o, "hlc", u64(r.hlc))
		o_id(o, "by", r.by)
		o_bytes(o, "value", r.value)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "elements", len(en.elements))
	for el in en.elements {
		o_obj(o, "")
		o_u64(o, "tag", u64(el.tag))
		o_bytes(o, "value", el.value)
		o_int(o, "live", len(el.live))
		o_end(o)
	}
	o_end(o)
	tags := make([dynamic]u32, context.temp_allocator)
	for ct in en.counters {
		seen := false
		for t in tags {
			seen ||= t == ct.tag
		}
		if !seen {
			append(&tags, ct.tag)
		}
	}
	o_arr(o, "counters", len(tags))
	for t in tags {
		v, _ := omap.counter_value(en, t)
		o_obj(o, "")
		o_u64(o, "tag", u64(t))
		o_i64(o, "value", v)
		o_end(o)
	}
	o_end(o)
	o_end(o)
}

emit_xref :: proc(o: ^Out, name: string, x: eng.Rid, object: prim.Id) {
	o_obj(o, name)
	o_id(o, "object", object)
	o_rid(o, "msg", x)
	o_end(o)
}

emit_catalog_row :: proc(o: ^Out, space: prim.Id, r: ^omap.Catalog_Row) {
	o_obj(o, "")
	o_object(o, "object", Object{space, r.object})
	o_enum(o, "kind", u64(r.kind), KIND_NAMES[:])
	o_str(o, "title", r.title)
	emit_xref(o, "parent", r.parent.rid, r.parent.object)
	o_id(o, "workspace", r.workspace)
	o_id(o, "agent", r.agent)
	o_enum(o, "status", r.status, CONVO_STATUS_NAMES[:])
	o_u64(o, "activity", r.activity)
	o_bool(o, "archived", r.archived)
	o_bool(o, "pinned", r.pinned)
	o_end(o)
}

emit_catalog_entry :: proc(o: ^Out, name: string, space: prim.Id, c: ^omap.Catalog_Entry) {
	o_obj(o, name)
	o_object(o, "object", Object{space, c.object})
	o_enum(o, "kind", u64(c.kind), KIND_NAMES[:])
	o_str(o, "title", c.title)
	emit_xref(o, "parent", c.parent.rid, c.parent.object)
	o_id(o, "workspace", c.workspace)
	o_id(o, "agent", c.agent)
	o_arr(o, "participants", len(c.participants))
	for p in c.participants {
		o_id(o, "", p)
	}
	o_end(o)
	o_enum(o, "status", c.status, CONVO_STATUS_NAMES[:])
	o_u64(o, "activity", c.activity)
	o_bool(o, "archived", c.archived)
	o_bool(o, "pinned", c.pinned)
	o_enum(o, "takeover", u64(c.takeover) if c.takeover <= 2 else 0, TAKEOVER_NAMES[:])
	o_end(o)
}

emit_space :: proc(o: ^Out, s: ^eng.Space_Info) {
	o_obj(o, "")
	o_id(o, "id", s.id)
	o_str(o, "name", s.name)
	o_str(o, "relay", s.relay)
	rk := s.relay_public
	zero := true
	for b in rk {
		zero &&= b == 0
	}
	o_bytes(o, "relay_key", nil if zero else rk[:])
	o_enum(o, "mode", u64(s.mode), MODE_NAMES[:])
	o_bool(o, "open", s.open)
	o_bool(o, "connected", s.connected)
	o_id(o, "catalog", s.catalog)
	o_u64(o, "relay_usage", u64(max(s.relay_usage, 0)))
	o_u64(o, "relay_quota", u64(max(s.relay_quota, 0)))
	o_end(o)
}

emit_identity :: proc(o: ^Out, id: osync.Identity) {
	x := id
	o_id(o, "id", x.id)
	o_bytes(o, "sign", x.sign[:])
	o_bytes(o, "box", x.box[:])
}

emit_results :: proc(o: ^Out, r: ^search.Results) {
	o_arr(o, "hits", len(r.hits))
	for &h in r.hits {
		o_obj(o, "")
		o_object(o, "object", Object{h.space, h.object})
		o_id(o, "participant", h.participant)
		if r, ok := eng.ref_rid(h.ref); ok && len(h.ref) == 32 {
			o_rid(o, "msg", r)
		} else {
			o_rid(o, "msg", {})
		}
		o_bytes(o, "ref", h.ref)
		o_u64(o, "part", u64(h.part))
		o_enum(o, "kind", u64(h.kind), KIND_NAMES[:])
		o_bool(o, "title", h.title)
		o_u64(o, "hlc", u64(h.hlc))
		o_f64(o, "score", h.score)
		o_str(o, "snippet", h.snippet)
		o_u64(o, "snippet_at", h.snippet_at)
		o_arr(o, "matches", len(h.matches))
		for mt in h.matches {
			o_obj(o, "")
			o_u64(o, "start", u64(mt.start))
			o_u64(o, "len", u64(mt.len))
			o_end(o)
		}
		o_end(o)
		o_end(o)
	}
	o_end(o)
	o_bytes(o, "cursor", r.cursor)
	o_bool(o, "incomplete", r.incomplete)
	o_int(o, "verified", r.verified)
}

emit_search :: proc(o: ^Out, r: ^eng.Search_Result) {
	res := search.Results{hits = r.hits, cursor = r.cursor, verified = len(r.hits)}
	emit_results(o, &res)
	o_bool(o, "partial", r.partial)
	o_int(o, "behind", r.behind)
	o_arr(o, "sources", len(r.sources))
	for s in r.sources {
		o_obj(o, "")
		o_id(o, "device", s.device)
		o_bool(o, "local", s.local)
		o_enum(o, "state", u64(s.state), SEARCH_STATE_NAMES[:])
		o_int(o, "behind", s.behind)
		o_int(o, "hits", s.hits)
		o_int(o, "rejected", s.rejected)
		o_end(o)
	}
	o_end(o)
}

valid_utf8 :: proc(b: []u8) -> bool {
	return utf8.valid_string(string(b))
}

emit_window :: proc(o: ^Out, w: ^convo.Window) {
	o_arr(o, "messages", len(w.messages))
	for &m in w.messages {
		emit_message(o, "", &m)
	}
	o_end(o)
	o_int(o, "anchor", w.anchor)
	emit_edge(o, "older", w.older, w.more_older)
	emit_edge(o, "newer", w.newer, w.more_newer)
	o_bool(o, "more_older", w.more_older)
	o_bool(o, "more_newer", w.more_newer)
	o_rid(o, "leaf", w.leaf)
	o_bytes(o, "older_cursor", cursor_encode(Cursor{dir = .Older, pos = w.older if w.more_older else {}, end = !w.more_older}))
	o_bytes(o, "newer_cursor", cursor_encode(Cursor{dir = .Newer, pos = w.newer if w.more_newer else {}, leaf = w.leaf, end = !w.more_newer}))
}
