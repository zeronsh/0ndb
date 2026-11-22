package engine

import "base:runtime"
import omap "../map"
import "../prim"

HOLDERS_NAME :: "0ndb:holders"
HOLDER_TAG_FLAGS :: u32(1)
HOLDER_TAG_BYTES :: u32(2)
HOLDER_ALWAYS_ON :: u64(1)
DEFAULT_CONTENT_BUDGET :: i64(1) << 30

@(private)
Budget_State :: struct {
	added:      map[prim.Id]i64,
	advertised: map[prim.Id]bool,
}

@(private)
_budget_init :: proc(e: ^Engine) {
	e.budget.added = make(map[prim.Id]i64, e.allocator)
	e.budget.advertised = make(map[prim.Id]bool, e.allocator)
}

@(private)
_budget_destroy :: proc(e: ^Engine) {
	delete(e.budget.added)
	delete(e.budget.advertised)
}

@(private)
_content_budget :: proc(e: ^Engine, sp: ^Space) -> i64 {
	if e.cfg.storage_policy.budget != nil {
		b: i64
		{
			context = _outer(e)
			b = e.cfg.storage_policy.budget(e.cfg.storage_policy.data, e, sp.id)
		}
		if b != 0 {
			return b
		}
	}
	if e.cfg.content_budget != 0 {
		return e.cfg.content_budget
	}
	return DEFAULT_CONTENT_BUDGET
}

@(private)
Holder_Row :: struct {
	device: prim.Id,
	flags:  u64,
	bytes:  u64,
}

@(private)
_holder_rows :: proc(e: ^Engine, sp: ^Space, allocator: runtime.Allocator) -> []Holder_Row {
	out := make([dynamic]Holder_Row, allocator)
	o := Object{sp.id, named_id(sp.id, HOLDERS_NAME)}
	cur: Map_Cursor
	defer omap.cursor_destroy(&cur)
	for {
		rows, more, err := map_scan(e, o, nil, &cur, 256, context.temp_allocator)
		if err != .None {
			break
		}
		for &row in rows {
			if len(row.key) != 16 {
				continue
			}
			hr: Holder_Row
			copy(hr.device[:], row.key)
			hr.flags, _ = _entry_u64(&row.entry, HOLDER_TAG_FLAGS)
			hr.bytes, _ = _entry_u64(&row.entry, HOLDER_TAG_BYTES)
			append(&out, hr)
		}
		if !more {
			break
		}
	}
	return out[:]
}

@(private)
_holders_always_on :: proc(e: ^Engine, sp: ^Space, allocator: runtime.Allocator) -> []prim.Id {
	out := make([dynamic]prim.Id, allocator)
	for r in _holder_rows(e, sp, context.temp_allocator) {
		if r.flags & HOLDER_ALWAYS_ON != 0 && r.device != e.self {
			append(&out, r.device)
		}
	}
	return out[:]
}

@(private)
_budget_used :: proc(e: ^Engine, sp: ^Space) -> (used: i64, own: i64) {
	for r in _holder_rows(e, sp, context.temp_allocator) {
		used += i64(min(r.bytes, u64(max(i64))))
		if r.device == e.self {
			own = i64(min(r.bytes, u64(max(i64))))
		}
	}
	add := e.budget.added[sp.id]
	return used + add, own + add
}

@(private)
_budget_take :: proc(e: ^Engine, sp: ^Space, size: i64) -> bool {
	used, _ := _budget_used(e, sp)
	if used + size > _content_budget(e, sp) {
		return false
	}
	e.budget.added[sp.id] += size
	_touch(e)
	return true
}

@(private)
_budget_flush :: proc(e: ^Engine) {
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if !sp.open || sp.keyless {
			continue
		}
		add := e.budget.added[id]
		want_ad := e.cfg.always_on && !e.budget.advertised[id]
		if add == 0 && !want_ad {
			continue
		}
		_, own := _budget_used(e, sp)
		o, err := map_named(e, id, HOLDERS_NAME)
		if err != .None {
			continue
		}
		flags := HOLDER_ALWAYS_ON if e.cfg.always_on else 0
		me := e.self
		fields := [2]omap.Field{omap.field_u64(HOLDER_TAG_FLAGS, flags), omap.field_u64(HOLDER_TAG_BYTES, u64(max(own, 0)))}
		if _, serr := map_set(e, o, me[:], fields[:]); serr == .None || serr == .Pending {
			delete_key(&e.budget.added, id)
			e.budget.advertised[id] = true
		}
	}
}
