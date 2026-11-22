package engine

import "core:fmt"
import "../pack"
import "../prim"
import osync "../sync"

Own_Length :: struct {
	space:   prim.Id,
	object:  prim.Id,
	kind:    Kind,
	stream:  osync.Stream_Id,
	durable: i64,
}

own_lengths :: proc(e: ^Engine, allocator := context.allocator) -> (out: []Own_Length, err: Error) {
	context = context_for(e)
	res := make([dynamic]Own_Length, allocator)
	objects := _reg_collect(e, ROOT_OBJECTS) or_return
	for &f in objects {
		if f.klen != 16 {
			continue
		}
		rec, derr := _rec_decode(f.value, context.temp_allocator)
		if derr != .None || !rec.own {
			continue
		}
		sp, ok := e.spaces[rec.space]
		if !ok || !sp.open || !sp.repl_on || sp.keyless {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[:16])
		path := _own_stream_path(e, id, rec.kind) or_return
		if !prim.exists(e.vfs, path) {
			continue
		}
		durable, perr := pack.durable_size(&e.pk, path)
		if perr != .None {
			continue
		}
		sc := _object_scope(sp, id)
		sid := osync.stream_id(&sc, e.self, _seg_name(rec.kind, id), 0)
		osync.scope_clear(&sc)
		append(&res, Own_Length{sp.id, id, rec.kind, sid, durable})
	}
	return res[:], .None
}

verify_uploaded :: proc(e: ^Engine, allocator := context.allocator) -> (notes: []string, err: Error) {
	context = context_for(e)
	out := make([dynamic]string, context.temp_allocator)
	objects := _reg_collect(e, ROOT_OBJECTS) or_return
	for &f in objects {
		if f.klen != 16 {
			continue
		}
		rec, derr := _rec_decode(f.value, context.temp_allocator)
		if derr != .None || !rec.own {
			continue
		}
		sp, ok := e.spaces[rec.space]
		if !ok || !sp.open || !sp.repl_on || sp.keyless {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[:16])
		path := _own_stream_path(e, id, rec.kind) or_return
		if !prim.exists(e.vfs, path) {
			continue
		}
		durable, perr := pack.durable_size(&e.pk, path)
		if perr != .None {
			continue
		}
		sc := _object_scope(sp, id)
		floor, ferr := osync.replicator_floor(&sp.repl, &sc, _seg_name(rec.kind, id), 0)
		osync.scope_clear(&sc)
		if ferr != .None {
			return nil, _serr(ferr)
		}
		if floor < durable {
			append(&out, fmt.tprintf("uploaded: own %v %s has %d durable bytes, %d uploaded", rec.kind, prim.id_hex(id), durable, floor))
		}
		if rec.kind == .File_Tree {
			mark, _ := _content_marks(e, sp.id, id)
			if mark < durable {
				append(&out, fmt.tprintf("uploaded: own tree %s has %d durable bytes, content uploaded to %d", prim.id_hex(id), durable, mark))
			}
		}
	}
	res := make([]string, len(out), allocator)
	for s, i in out {
		res[i] = _clone(s, allocator) or_return
	}
	return res, .None
}
