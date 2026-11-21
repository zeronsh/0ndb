package omap

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
}

CATALOG_BY_ACTIVITY :: 0

catalog_defs :: proc() -> [1]Index_Def {
	return {{extract = _catalog_order, covering = true}}
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
	for r in e.registers {
		v := r.value
		#partial switch Catalog_Tag(r.tag) {
		case .Kind:
			x, _ := value_u64(v)
			if x >= 1 && x <= u64(max(obj.Kind)) {
				c.kind = obj.Kind(x)
			}
		case .Title:
			c.title = obj.clone_str(string(v), allocator) or_return
		case .Parent:
			pr := prim.reader(v)
			c.parent.object = prim.read_id(&pr)
			c.parent.rid.seg = prim.read_id(&pr)
			c.parent.rid.off = i64(min(prim.read_uvarint(&pr), u64(max(i64))))
		case .Workspace:
			c.workspace, _ = value_id(v)
		case .Agent:
			c.agent, _ = value_id(v)
		case .Status:
			c.status, _ = value_u64(v)
		case .Activity:
			c.activity, _ = value_u64(v)
		case .Usage:
			c.usage = obj.clone_bytes(v, allocator) or_return
		case .Archived:
			c.archived, _ = value_bool(v)
		case .Pinned:
			c.pinned, _ = value_bool(v)
		}
	}
	parts := entry_elements(e, u32(Catalog_Tag.Participants))
	if len(parts) > 0 {
		c.participants = make([]prim.Id, len(parts), allocator)
		for p, i in parts {
			c.participants[i], _ = value_id(p)
		}
	}
	return c, .None
}

catalog_list :: proc(t: ^Table, archived: bool, after: ^Cursor, limit: int, allocator := context.allocator) -> (out: []Catalog_Entry, more: bool, err: Error) {
	prefix := [1]u8{1 if archived else 0}
	rows: []Row
	rows, more = table_scan(t, CATALOG_BY_ACTIVITY, prefix[:], after, limit, allocator) or_return
	list := make([]Catalog_Entry, len(rows), allocator)
	for &r, i in rows {
		list[i] = catalog_decode(&r.entry, allocator) or_return
	}
	return list, more, .None
}
