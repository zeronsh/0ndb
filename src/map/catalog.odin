package omap

import "base:runtime"
import "../obj"
import "../prim"

Catalog_Tag :: enum u32 {
	Kind         = 1,
	Title        = 2,
	Parent       = 3,
	Workspace    = 4,
	Agent        = 5,
	Participants = 6,
	Status       = 7,
	Activity     = 8,
	Usage        = 9,
	Archived     = 10,
	Pinned       = 11,
	Storage      = 12,
	Takeover     = 13,
	Provider     = 14,
	Unanswered   = 15,
}

Catalog_Entry :: struct {
	object:       prim.Id,
	kind:         obj.Kind,
	title:        string,
	parent:       obj.Xref,
	workspace:    prim.Id,
	agent:        prim.Id,
	participants: []prim.Id,
	status:       u64,
	activity:     u64,
	usage:        []u8,
	archived:     bool,
	pinned:       bool,
	storage:      u8,
	takeover:     u8,
	provider:     string,
	unanswered:   bool,
}

CATALOG_BY_ACTIVITY :: 0

Catalog_Row :: struct {
	object:    prim.Id,
	kind:      obj.Kind,
	title:     string,
	parent:    obj.Xref,
	workspace: prim.Id,
	agent:     prim.Id,
	status:    u64,
	activity:  u64,
	archived:  bool,
	pinned:    bool,
}

CATALOG_LIST_TAGS :: [?]Catalog_Tag{.Kind, .Title, .Parent, .Workspace, .Agent, .Status, .Activity, .Archived, .Pinned}

catalog_defs :: proc() -> [1]Index_Def {
	return {{extract = _catalog_order, project = _catalog_project}}
}

@(private)
_catalog_project :: proc(data: rawptr, e: ^Entry, out: ^[dynamic]u8) {
	w := prim.writer(out)
	for r in e.registers {
		for t in CATALOG_LIST_TAGS {
			if u32(t) == r.tag {
				prim.write_uvarint(&w, u64(r.tag))
				prim.write_bytes(&w, r.value)
				break
			}
		}
	}
}

@(private)
_catalog_order :: proc(data: rawptr, e: ^Entry, out: ^[dynamic]u8) -> bool {
	archived := false
	activity: u64
	if v, ok := entry_register(e, u32(Catalog_Tag.Archived)); ok {
		archived, _ = value_bool(v)
	}
	if v, ok := entry_register(e, u32(Catalog_Tag.Activity)); ok {
		activity, _ = value_u64(v)
	}
	append(out, 1 if archived else 0)
	inv := ~activity
	for i in 0 ..< 8 {
		append(out, u8(inv >> (56 - 8 * u64(i))))
	}
	return true
}

catalog_fields :: proc(c: Catalog_Entry, allocator := context.temp_allocator) -> []Field {
	out := make([dynamic]Field, allocator)
	append(&out, field_u64(u32(Catalog_Tag.Kind), u64(c.kind), allocator))
	if len(c.title) > 0 {
		append(&out, field_str(u32(Catalog_Tag.Title), c.title))
	}
	if !prim.id_is_zero(c.parent.object) {
		b := make([dynamic]u8, allocator)
		w := prim.writer(&b)
		prim.write_id(&w, c.parent.object)
		prim.write_id(&w, c.parent.rid.seg)
		prim.write_uvarint(&w, u64(max(c.parent.rid.off, 0)))
		prim.write_uvarint(&w, c.parent.rid.gen)
		append(&out, Field{tag = u32(Catalog_Tag.Parent), value = b[:]})
	}
	if !prim.id_is_zero(c.workspace) {
		append(&out, field_id(u32(Catalog_Tag.Workspace), c.workspace, allocator))
	}
	if !prim.id_is_zero(c.agent) {
		append(&out, field_id(u32(Catalog_Tag.Agent), c.agent, allocator))
	}
	append(&out, field_u64(u32(Catalog_Tag.Status), c.status, allocator))
	append(&out, field_u64(u32(Catalog_Tag.Activity), c.activity, allocator))
	if len(c.usage) > 0 {
		append(&out, Field{tag = u32(Catalog_Tag.Usage), value = c.usage})
	}
	append(&out, field_bool(u32(Catalog_Tag.Archived), c.archived, allocator))
	append(&out, field_bool(u32(Catalog_Tag.Pinned), c.pinned, allocator))
	return out[:]
}

catalog_key :: proc(object: prim.Id, buf: ^[16]u8) -> []u8 {
	o := object
	copy(buf[:], o[:])
	return buf[:]
}

catalog_decode :: proc(e: ^Entry, allocator := context.allocator) -> (c: Catalog_Entry, err: Error) {
	if id, ok := value_id(e.key); ok {
		c.object = id
	}
	row: Catalog_Row
	for r in e.registers {
		_catalog_field(&row, r.tag, r.value, allocator) or_return
		#partial switch Catalog_Tag(r.tag) {
		case .Usage:
			c.usage = obj.clone_bytes(r.value, allocator) or_return
		case .Storage:
			x, _ := value_u64(r.value)
			c.storage = u8(min(x, 255))
		case .Takeover:
			x, _ := value_u64(r.value)
			c.takeover = u8(min(x, 255))
		case .Provider:
			c.provider = obj.clone_str(string(r.value), allocator) or_return
		case .Unanswered:
			x, _ := value_u64(r.value)
			c.unanswered = x != 0
		}
	}
	c.kind = row.kind
	c.title = row.title
	c.parent = row.parent
	c.workspace = row.workspace
	c.agent = row.agent
	c.status = row.status
	c.activity = row.activity
	c.archived = row.archived
	c.pinned = row.pinned
	parts := entry_elements(e, u32(Catalog_Tag.Participants))
	if len(parts) > 0 {
		c.participants = make([]prim.Id, len(parts), allocator)
		for p, i in parts {
			c.participants[i], _ = value_id(p)
		}
	}
	return c, .None
}

catalog_row :: proc(key: []u8, value: []u8, allocator := context.allocator) -> (row: Catalog_Row, err: Error) {
	if id, ok := value_id(key); ok {
		row.object = id
	}
	r := prim.reader(value)
	for prim.reader_remaining(&r) > 0 {
		tag := prim.read_uvarint(&r)
		v := prim.read_bytes(&r)
		if r.err != .None || tag > u64(max(u32)) {
			return row, .Corrupt
		}
		_catalog_field(&row, u32(tag), v, allocator) or_return
	}
	return row, .None
}

catalog_get :: proc(t: ^Table, object: prim.Id, allocator := context.allocator) -> (c: Catalog_Entry, found: bool, err: Error) {
	kb: [16]u8
	e: Entry
	e, found = table_get(t, catalog_key(object, &kb), allocator) or_return
	if !found {
		return c, false, .None
	}
	c = catalog_decode(&e, allocator) or_return
	return c, true, .None
}

@(private)
_catalog_field :: proc(row: ^Catalog_Row, tag: u32, v: []u8, allocator: runtime.Allocator) -> Error {
	#partial switch Catalog_Tag(tag) {
	case .Kind:
		x, _ := value_u64(v)
		if x >= 1 && x <= u64(max(obj.Kind)) {
			row.kind = obj.Kind(x)
		}
	case .Title:
		row.title = obj.clone_str(string(v), allocator) or_return
	case .Parent:
		pr := prim.reader(v)
		row.parent.object = prim.read_id(&pr)
		row.parent.rid.seg = prim.read_id(&pr)
		row.parent.rid.off = i64(min(prim.read_uvarint(&pr), u64(max(i64))))
		if prim.reader_remaining(&pr) > 0 {
			row.parent.rid.gen = prim.read_uvarint(&pr)
		}
	case .Workspace:
		row.workspace, _ = value_id(v)
	case .Agent:
		row.agent, _ = value_id(v)
	case .Status:
		row.status, _ = value_u64(v)
	case .Activity:
		row.activity, _ = value_u64(v)
	case .Archived:
		row.archived, _ = value_bool(v)
	case .Pinned:
		row.pinned, _ = value_bool(v)
	}
	return .None
}

catalog_list :: proc(t: ^Table, archived: bool, after: ^Cursor, limit: int, allocator := context.allocator) -> (out: []Catalog_Row, more: bool, err: Error) {
	prefix := [1]u8{1 if archived else 0}
	rows: []Row
	rows, more = table_scan(t, CATALOG_BY_ACTIVITY, prefix[:], after, limit, allocator) or_return
	list := make([]Catalog_Row, len(rows), allocator)
	for r, i in rows {
		list[i] = catalog_row(r.key, r.value, allocator) or_return
	}
	return list, more, .None
}
