package rt

import "core:encoding/json"
import "core:strings"
import eng "../engine"
import omap "../map"
import "../prim"
import "../search"

@(private)
NOTE_PREFIX :: "n/"
@(private)
FACT_PREFIX :: "f/"

memory_object :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value, create: bool) -> (o: Object, ok: bool) {
	if s := jstr(v, "memory"); len(s) > 0 {
		id, iok := prim.id_parse(s)
		return Object{caller.space, id}, iok
	}
	for id in _memory_ids(r, caller, a) {
		c, found, _ := eng.catalog_get(r.e, Object{caller.space, id}, context.temp_allocator)
		if found && c.kind == .Map {
			return Object{caller.space, id}, true
		}
	}
	if a == nil || prim.id_is_zero(a.object.id) {
		if create {
			return named_w(r, memory_named(caller.space)), true
		}
		return named_obj(memory_named(caller.space)), true
	}
	if !create {
		return {}, false
	}
	title := concat("memory: ", a.name if len(a.name) > 0 else hex(a.object.id))
	m, err := eng.map_create(r.e, caller.space, title)
	if err != .None {
		return {}, false
	}
	id := m.id
	eng.agent_add(r.e, a.object, .Memory, id[:])
	return m, true
}

memory_objects :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value) -> []Object {
	out := make([dynamic]Object, context.temp_allocator)
	for s in jstrs(v, "memory") {
		if id, ok := prim.id_parse(s); ok {
			append(&out, Object{caller.space, id})
		}
	}
	if len(out) == 0 {
		for id in _memory_ids(r, caller, a) {
			append(&out, Object{caller.space, id})
		}
		if len(out) == 0 {
			if o, ok := memory_object(r, caller, a, v, false); ok {
				append(&out, o)
			}
		}
	}
	return out[:]
}

memory_write :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value, rep: Reply) {
	key := jstr(v, "key")
	kind := jstr(v, "kind")
	if len(kind) == 0 {
		kind = "note"
	}
	op := jstr(v, "op")
	if len(op) == 0 {
		op = "set"
	}
	mem, ok := memory_object(r, caller, a, v, true)
	if !ok {
		reply_done(r, rep, "no memory object is available", "", true)
		return
	}
	record := ""
	switch kind {
	case "fact":
		k := key_of(FACT_PREFIX, transmute([]u8)key)
		switch op {
		case "delete":
			map_clear(r, mem, k, 1)
		case:
			val := jget(v, "value")
			if val == nil {
				val = json.String(jstr(v, "text"))
			}
			off, err := eng.map_set(r.e, mem, k, []omap.Field{omap.field_str(1, json_text(val))})
			if err != .None && err != .Pending {
				reply_done(r, rep, "the fact could not be written", "", true)
				return
			}
			record = rid_text(Rid{r.self, off})
		}
	case:
		k := key_of(NOTE_PREFIX, transmute([]u8)key)
		text := jstr(v, "text")
		en, found := map_read(r, mem, k)
		tid := entry_id(&en, 1) if found else prim.Id{}
		switch op {
		case "delete":
			map_clear(r, mem, k, 1)
		case "append", "set":
			if prim.id_is_zero(tid) {
				t, err := eng.text_create(r.e, caller.space, key, text)
				if err != .None {
					reply_done(r, rep, "the note could not be created", "", true)
					return
				}
				tid = t.id
				map_put(r, mem, k, omap.field_id(1, tid))
			} else {
				to := Object{caller.space, tid}
				cur, rerr := eng.text_read(r.e, to, context.temp_allocator)
				if rerr != .None {
					reply_done(r, rep, "the note could not be read", "", true)
					return
				}
				if op == "append" {
					ins := text
					if len(cur) > 0 && cur[len(cur) - 1] != '\n' && len(text) > 0 {
						ins = concat("\n", text)
					}
					eng.text_edit(r.e, to, len(cur), 0, ins)
				} else {
					eng.text_edit(r.e, to, 0, len(cur), text)
				}
			}
			record = hex(tid)
		}
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "key", key)
	jw_kstr(&b, "kind", kind)
	jw_kstr(&b, "op", op)
	if len(record) > 0 {
		jw_kstr(&b, "record", record)
	}
	append(&b, '}')
	reply_done(r, rep, concat(op, " ", kind, " ", key), string(b[:]), false)
}

memory_read :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value, rep: Reply) {
	key := jstr(v, "key")
	kind := jstr(v, "kind")
	objs := memory_objects(r, caller, a, v)
	b := make(Buf, context.temp_allocator)
	if strings.has_suffix(key, "/") || len(key) == 0 {
		append(&b, '{')
		jw_kstr(&b, "key", key)
		jw_kstr(&b, "kind", "prefix")
		jw_karr(&b, "keys")
		for mem in objs {
			prefixes := [2]string{NOTE_PREFIX, FACT_PREFIX}
			for p in prefixes {
				if (kind == "note" && p == FACT_PREFIX) || (kind == "fact" && p == NOTE_PREFIX) {
					continue
				}
				for row in map_rows(r, mem, key_of(p, transmute([]u8)key), 1000) {
					jw_item_str(&b, string(row.key[len(p):]))
				}
			}
		}
		jw_end(&b)
		append(&b, '}')
		reply_done(r, rep, "", string(b[:]), false)
		return
	}
	for mem in objs {
		if kind != "note" {
			if en, ok := map_read(r, mem, key_of(FACT_PREFIX, transmute([]u8)key)); ok {
				append(&b, '{')
				jw_kstr(&b, "key", key)
				jw_kstr(&b, "kind", "fact")
				val := entry_str(&en, 1)
				jw_kraw(&b, "value", val)
				for reg in en.registers {
					if reg.tag == 1 {
						jw_kstr(&b, "updated", rfc3339(prim.hlc_ms(reg.hlc)))
						jw_kstr(&b, "author", hex(reg.by))
					}
				}
				append(&b, '}')
				reply_done(r, rep, val, string(b[:]), false)
				return
			}
		}
		if kind != "fact" {
			if en, ok := map_read(r, mem, key_of(NOTE_PREFIX, transmute([]u8)key)); ok {
				tid := entry_id(&en, 1)
				data, err := eng.text_read(r.e, Object{caller.space, tid}, context.temp_allocator)
				if err != .None {
					continue
				}
				text := _line_range(string(data), int(jint(v, "start_line")), int(jint(v, "end_line")))
				append(&b, '{')
				jw_kstr(&b, "key", key)
				jw_kstr(&b, "kind", "note")
				jw_kstr(&b, "text", text)
				append(&b, '}')
				reply_done(r, rep, text, string(b[:]), false)
				return
			}
		}
	}
	reply_done(r, rep, concat("no memory under ", key), "", true)
}

@(private)
_line_range :: proc(text: string, start: int, end: int) -> string {
	if start <= 0 && end <= 0 {
		return text
	}
	lo := max(start, 1)
	hi := end if end > 0 else max(int)
	line := 1
	from := -1
	to := len(text)
	for i := 0; i <= len(text); i += 1 {
		if line == lo && from < 0 {
			from = i
		}
		if i == len(text) {
			break
		}
		if text[i] == '\n' {
			if line == hi {
				to = i
				break
			}
			line += 1
		}
	}
	if from < 0 {
		return ""
	}
	return text[from:to]
}

memory_search :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value, rep: Reply) {
	q := jstr(v, "query")
	limit := int(jint(v, "limit", 10))
	kind := jstr(v, "kind")
	objs := memory_objects(r, caller, a, v)
	b := make(Buf, context.temp_allocator)
	append(&b, `{"hits":[`)
	count := 0
	for mem in objs {
		if kind != "note" {
			for &row in map_rows(r, mem, transmute([]u8)string(FACT_PREFIX), 100_000) {
				if count >= limit {
					break
				}
				k := string(row.key[len(FACT_PREFIX):])
				val := entry_str(&row.entry, 1)
				if !_contains_fold(k, q) && !_contains_fold(val, q) {
					continue
				}
				jw_open(&b)
				jw_kstr(&b, "memory", hex(mem.id))
				jw_kstr(&b, "kind", "fact")
				jw_kstr(&b, "key", k)
				snip, _ := utf8_clip(val, 300)
				jw_kstr(&b, "snippet", snip)
				jw_close(&b)
				count += 1
			}
		}
		if kind != "fact" {
			for &row in map_rows(r, mem, transmute([]u8)string(NOTE_PREFIX), 100_000) {
				if count >= limit {
					break
				}
				tid := entry_id(&row.entry, 1)
				if prim.id_is_zero(tid) {
					continue
				}
				k := string(row.key[len(NOTE_PREFIX):])
				hit := ""
				res, err := eng.search_query(r.e, concat(q, " object:", hex(tid)), search.Request{limit = 1, semantic = jstr(v, "mode") == "semantic"}, context.temp_allocator)
				if err == .None && len(res.hits) > 0 {
					hit = res.hits[0].snippet
				} else if _contains_fold(k, q) {
					hit = k
				} else {
					data, rerr := eng.text_read(r.e, Object{caller.space, tid}, context.temp_allocator)
					if rerr != .None {
						continue
					}
					if i := _index_fold(string(data), q); i >= 0 {
						lo := max(i - 120, 0)
						hit, _ = utf8_clip(string(data[lo:]), 300)
					} else {
						continue
					}
				}
				jw_open(&b)
				jw_kstr(&b, "memory", hex(mem.id))
				jw_kstr(&b, "kind", "note")
				jw_kstr(&b, "key", k)
				jw_kstr(&b, "snippet", hit)
				jw_close(&b)
				count += 1
			}
		}
	}
	append(&b, "]}")
	reply_done(r, rep, "", string(b[:]), false)
}

@(private)
_contains_fold :: proc(hay, needle: string) -> bool {
	return _index_fold(hay, needle) >= 0
}

@(private)
_index_fold :: proc(hay, needle: string) -> int {
	if len(needle) == 0 {
		return 0
	}
	h := strings.to_lower(hay, context.temp_allocator)
	n := strings.to_lower(needle, context.temp_allocator)
	return strings.index(h, n)
}

@(private)
_memory_ids :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info) -> []prim.Id {
	if a == nil {
		return nil
	}
	if !prim.id_is_zero(a.object.id) {
		if def, err := eng.agent_get(r.e, a.object, context.temp_allocator); err == .None {
			out := make([dynamic]prim.Id, context.temp_allocator)
			append(&out, ..def.memory)
			for m in a.memory {
				dup := false
				for x in out {
					dup ||= x == m
				}
				if !dup {
					append(&out, m)
				}
			}
			return out[:]
		}
	}
	return a.memory
}
