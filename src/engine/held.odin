package engine

import omap "../map"
import "../fs"
import "../odb"
import "../prim"
import osync "../sync"

HELD_NAME :: "0ndb:held"
HELD_TAG_TREE :: u32(1)
HELD_TAG_SIZE :: u32(2)
DEFAULT_HOLDER_BUDGET :: i64(8) << 30

@(private)
Held_Note :: struct {
	space: prim.Id,
	tree:  prim.Id,
	oid:   odb.Oid,
	n:     int,
	size:  i64,
}

@(private)
_held_note :: proc(e: ^Engine, h: ^Handle, ref: fs.Content_Ref, size: i64) {
	append(&e.budget.held, Held_Note{space = h.sp.id, tree = h.id, oid = ref.oid, n = ref.len, size = size})
	_touch(e)
}

@(private)
_held_flush :: proc(e: ^Engine) {
	if len(e.budget.held) == 0 {
		return
	}
	keep := 0
	for nt in e.budget.held {
		sp, ok := e.spaces[nt.space]
		if !ok || !sp.open || sp.keyless {
			continue
		}
		o, err := map_named(e, nt.space, HELD_NAME)
		if err != .None {
			e.budget.held[keep] = nt
			keep += 1
			continue
		}
		oid := nt.oid
		fields := [2]omap.Field{omap.field_id(HELD_TAG_TREE, nt.tree), omap.field_u64(HELD_TAG_SIZE, u64(max(nt.size, 0)))}
		if _, serr := map_set(e, o, oid[:nt.n], fields[:]); serr != .None && serr != .Pending {
			e.budget.held[keep] = nt
			keep += 1
		}
	}
	resize(&e.budget.held, keep)
}

@(private)
_held_follow :: proc(e: ^Engine, sp: ^Space) {
	if !e.cfg.always_on || !sp.repl_on || sp.keyless {
		return
	}
	id := named_id(sp.id, HELD_NAME)
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	osync.replicator_follow_segments(&sp.repl, &sc, _seg_name(.Map, id), 0, true)
}

@(private)
_held_scan :: proc(e: ^Engine, sp: ^Space) {
	if !e.cfg.always_on || !sp.open || !sp.repl_on {
		return
	}
	db, derr := device_odb(e)
	if derr != .None {
		return
	}
	limit := e.cfg.holder_budget if e.cfg.holder_budget != 0 else DEFAULT_HOLDER_BUDGET
	o := Object{sp.id, named_id(sp.id, HELD_NAME)}
	held: i64
	want := make([dynamic]Held_Note, context.temp_allocator)
	cur: Map_Cursor
	defer omap.cursor_destroy(&cur)
	for {
		rows, more, err := map_scan(e, o, nil, &cur, 256, context.temp_allocator, Ready{data = sp, call = _held_ready})
		if err != .None && err != .Pending {
			break
		}
		for &row in rows {
			if len(row.key) != 20 && len(row.key) != 32 {
				continue
			}
			tv, has_tree := omap.entry_register(&row.entry, HELD_TAG_TREE)
			size, _ := _entry_u64(&row.entry, HELD_TAG_SIZE)
			if !has_tree || len(tv) != 16 {
				continue
			}
			nt := Held_Note{space = sp.id, n = len(row.key), size = i64(min(size, u64(max(i64))))}
			copy(nt.oid[:], row.key)
			copy(nt.tree[:], tv)
			if odb.exists(db, nt.oid) {
				held += nt.size
				continue
			}
			append(&want, nt)
		}
		if !more {
			break
		}
	}
	for nt in want {
		if limit > 0 && held + nt.size > limit {
			continue
		}
		if _, waiting := e.content.waits[nt.oid]; waiting {
			held += nt.size
			continue
		}
		h, herr := _handle_get(e, Object{sp.id, nt.tree}, .File_Tree)
		if herr != .None {
			continue
		}
		_content_fetch(e, h, fs.Content_Ref{oid = nt.oid, len = nt.n, opaque = true, size = nt.size})
		held += nt.size
	}
}

@(private)
_held_ready :: proc(data: rawptr, e: ^Engine, err: Error) {
	if err != .None {
		return
	}
	for mk1_ in prim.sorted_keys(e.spaces) {
		if mk1_ not_in e.spaces {
			continue
		}
		sp := e.spaces[mk1_]
		if rawptr(sp) == data {
			_held_scan(e, sp)
			return
		}
	}
}
