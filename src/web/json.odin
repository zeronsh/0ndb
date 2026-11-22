package web

import "core:strconv"
import "core:unicode/utf8"
import "../convo"
import omap "../map"
import "../obj"
import "../prim"

KIND_NAMES := [5]string{"", "conversation", "map", "text", "tree"}
ROLE_NAMES := [5]string{"", "user", "assistant", "system", "tool"}
BLOCK_NAMES := [12]string{"", "text", "reasoning", "tool_call", "tool_result", "image", "error", "notice", "permission", "permission_answer", "question", "file"}
SEAL_NAMES := [5]string{"open", "done", "interrupted", "failed", "cancelled"}
CONVO_STATUS_NAMES := [8]string{"idle", "running", "queued", "awaiting_permission", "failed", "interrupted", "waiting", "reviving"}
OPEN_STATE_NAMES := [2]string{"running", "revive"}
DELTA_NAMES := [19]string{"message", "block", "chunk", "seal", "leaf", "intent", "run", "mount", "record", "status", "field", "element", "counter", "catalog", "text", "files", "redacted", "members", "quarantined"}
HEX := "0123456789abcdef"

MAX_DEPTH :: 32

Out :: struct {
	buf:   ^[dynamic]u8,
	depth: int,
	stack: [MAX_DEPTH]u8,
	first: [MAX_DEPTH]bool,
}

out_init :: proc(o: ^Out, buf: ^[dynamic]u8, array := false) {
	o^ = {
		buf = buf,
	}
	append(buf, '[' if array else '{')
	o.stack[0] = ']' if array else '}'
	o.first[0] = true
	o.depth = 1
}

out_finish :: proc(o: ^Out) -> []u8 {
	for o.depth > 0 {
		o.depth -= 1
		append(o.buf, o.stack[o.depth])
	}
	return o.buf[:]
}

@(private)
_key :: proc(o: ^Out, name: string) {
	d := o.depth - 1
	if !o.first[d] {
		append(o.buf, ',')
	}
	o.first[d] = false
	if o.stack[d] == '}' {
		json_string(o.buf, name)
		append(o.buf, ':')
	}
}

@(private)
_push :: proc(o: ^Out, open: u8, close: u8) {
	append(o.buf, open)
	if o.depth < MAX_DEPTH {
		o.stack[o.depth] = close
		o.first[o.depth] = true
		o.depth += 1
	}
}

o_obj :: proc(o: ^Out, name: string) {
	_key(o, name)
	_push(o, '{', '}')
}

o_arr :: proc(o: ^Out, name: string) {
	_key(o, name)
	_push(o, '[', ']')
}

o_end :: proc(o: ^Out) {
	if o.depth > 1 {
		o.depth -= 1
		append(o.buf, o.stack[o.depth])
	}
}

o_bool :: proc(o: ^Out, name: string, v: bool) {
	_key(o, name)
	append(o.buf, "true" if v else "false")
}

o_u64 :: proc(o: ^Out, name: string, v: u64) {
	_key(o, name)
	b: [32]u8
	append(o.buf, strconv.write_uint(b[:], v, 10))
}

o_int :: proc(o: ^Out, name: string, v: int) {
	o_u64(o, name, u64(max(v, 0)))
}

o_i64 :: proc(o: ^Out, name: string, v: i64) {
	_key(o, name)
	b: [32]u8
	append(o.buf, strconv.write_int(b[:], v, 10))
}

o_str :: proc(o: ^Out, name: string, s: string) {
	_key(o, name)
	json_string(o.buf, s)
}

o_text :: proc(o: ^Out, name: string, b: []u8) {
	o_str(o, name, string(b))
}

o_bytes :: proc(o: ^Out, name: string, b: []u8) {
	_key(o, name)
	append(o.buf, '"')
	for c in b {
		append(o.buf, HEX[c >> 4], HEX[c & 15])
	}
	append(o.buf, '"')
}

o_id :: proc(o: ^Out, name: string, id: prim.Id) {
	_key(o, name)
	if prim.id_is_zero(id) {
		append(o.buf, "null")
		return
	}
	h := prim.id_hex(id)
	append(o.buf, '"')
	append(o.buf, ..h[:])
	append(o.buf, '"')
}

o_rid :: proc(o: ^Out, name: string, r: obj.Rid) {
	_key(o, name)
	if prim.id_is_zero(r.seg) {
		append(o.buf, "null")
		return
	}
	h := prim.id_hex(r.seg)
	append(o.buf, '"')
	append(o.buf, ..h[:])
	append(o.buf, ':')
	b: [32]u8
	append(o.buf, strconv.write_int(b[:], r.off, 10))
	append(o.buf, ':')
	append(o.buf, strconv.write_uint(b[:], r.gen, 10))
	append(o.buf, '"')
}

o_object :: proc(o: ^Out, name: string, space: prim.Id, id: prim.Id) {
	_key(o, name)
	if prim.id_is_zero(id) {
		append(o.buf, "null")
		return
	}
	a := prim.id_hex(space)
	b := prim.id_hex(id)
	append(o.buf, '"')
	append(o.buf, ..a[:])
	append(o.buf, '/')
	append(o.buf, ..b[:])
	append(o.buf, '"')
}

o_enum :: proc(o: ^Out, name: string, v: u64, names: []string) {
	if v < u64(len(names)) && len(names[v]) > 0 {
		o_str(o, name, names[v])
		return
	}
	o_u64(o, name, v)
}

json_string :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, '"')
	i := 0
	for i < len(s) {
		c := s[i]
		if c < 0x80 {
			switch c {
			case '"':
				append(buf, '\\', '"')
			case '\\':
				append(buf, '\\', '\\')
			case '\n':
				append(buf, '\\', 'n')
			case '\r':
				append(buf, '\\', 'r')
			case '\t':
				append(buf, '\\', 't')
			case:
				if c < 0x20 || c == 0x7f {
					append(buf, '\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15])
				} else {
					append(buf, c)
				}
			}
			i += 1
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && n <= 1 {
			append(buf, "\xef\xbf\xbd")
			i += 1
			continue
		}
		append(buf, s[i:i + n])
		i += n
	}
	append(buf, '"')
}

emit_usage :: proc(o: ^Out, name: string, u: convo.Usage) {
	o_obj(o, name)
	o_u64(o, "input", u.input)
	o_u64(o, "output", u.output)
	o_u64(o, "cache_read", u.cache_read)
	o_u64(o, "cache_write", u.cache_write)
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
	o_arr(o, "files")
	for f in m.files {
		o_obj(o, "")
		o_str(o, "mount", f.mount)
		o_id(o, "tree", f.tree)
		o_id(o, "line", f.line)
		o_bytes(o, "version", f.version)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "lines")
	for l in m.lines {
		o_obj(o, "")
		o_str(o, "mount", l.mount)
		o_id(o, "line", l.line)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "blocks")
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

emit_window :: proc(o: ^Out, w: ^convo.Window, leaf: obj.Rid) {
	o_arr(o, "messages")
	for &m in w.messages {
		emit_message(o, "", &m)
	}
	o_end(o)
	o_int(o, "anchor", w.anchor)
	emit_position(o, "older", w.older)
	emit_position(o, "newer", w.newer)
	o_bool(o, "more_older", w.more_older)
	o_bool(o, "more_newer", w.more_newer)
	o_rid(o, "leaf", leaf)
}

emit_tail :: proc(o: ^Out, v: ^obj.View, t: ^convo.Tail) -> obj.Error {
	head := convo.tail_head(v, t) or_return
	position := convo.tail_position(v, t) or_return
	o_enum(o, "status", u64(t.status), CONVO_STATUS_NAMES[:])
	o_rid(o, "head", head)
	o_rid(o, "position", position)
	o_bool(o, "browsing", t.browsing)
	o_enum(o, "head_status", u64(t.head_status), SEAL_NAMES[:])
	o_int(o, "queued", t.queued)
	o_int(o, "waiting", t.waiting)
	o_int(o, "intents", t.intents)
	o_bool(o, "running", t.running)
	o_bool(o, "awaiting", t.awaiting)
	o_bool(o, "revive", t.revive)
	o_u64(o, "head_hlc", u64(t.head_hlc))
	return .None
}

emit_entry :: proc(o: ^Out, name: string, en: ^omap.Entry) {
	o_obj(o, name)
	o_bytes(o, "key", en.key)
	o_arr(o, "registers")
	for r in en.registers {
		o_obj(o, "")
		o_u64(o, "tag", u64(r.tag))
		o_u64(o, "hlc", u64(r.hlc))
		o_id(o, "by", r.by)
		o_bytes(o, "value", r.value)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "elements")
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
	o_arr(o, "counters")
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

emit_xref :: proc(o: ^Out, name: string, x: obj.Xref) {
	o_obj(o, name)
	o_id(o, "object", x.object)
	o_rid(o, "msg", x.rid)
	o_end(o)
}

emit_catalog_row :: proc(o: ^Out, r: ^omap.Catalog_Row) {
	o_obj(o, "")
	o_id(o, "object", r.object)
	o_enum(o, "kind", u64(r.kind), KIND_NAMES[:])
	o_str(o, "title", r.title)
	emit_xref(o, "parent", r.parent)
	o_id(o, "workspace", r.workspace)
	o_id(o, "agent", r.agent)
	o_enum(o, "status", r.status, CONVO_STATUS_NAMES[:])
	o_u64(o, "activity", r.activity)
	o_bool(o, "archived", r.archived)
	o_bool(o, "pinned", r.pinned)
	o_end(o)
}

emit_catalog_entry :: proc(o: ^Out, name: string, c: ^omap.Catalog_Entry) {
	o_obj(o, name)
	o_id(o, "object", c.object)
	o_enum(o, "kind", u64(c.kind), KIND_NAMES[:])
	o_str(o, "title", c.title)
	emit_xref(o, "parent", c.parent)
	o_id(o, "workspace", c.workspace)
	o_id(o, "agent", c.agent)
	o_arr(o, "participants")
	for p in c.participants {
		o_id(o, "", p)
	}
	o_end(o)
	o_enum(o, "status", c.status, CONVO_STATUS_NAMES[:])
	o_u64(o, "activity", c.activity)
	o_bool(o, "archived", c.archived)
	o_bool(o, "pinned", c.pinned)
	o_end(o)
}
