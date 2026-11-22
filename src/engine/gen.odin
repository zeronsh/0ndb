package engine

import "../obj"
import "../prim"

@(private)
GEN_BLOCK :: 1024

@(private)
_gen_load :: proc(e: ^Engine) -> Error {
	path := _join(context.temp_allocator, e.dir, "gen") or_return
	data, err := prim.read_file(e.base, path, context.temp_allocator)
	stored: u64
	switch {
	case err == .Not_Found:
	case err != .None:
		return _perr(err)
	case len(data) != 8:
		return .Corrupt
	case:
		stored = prim.get_u64le(data)
	}
	if stored == max(u64) {
		return .Corrupt
	}
	e.gen_next = stored + 1
	e.gen_ceil = stored
	return .None
}

@(private)
_gen_take :: proc(e: ^Engine) -> (gen: u64, err: Error) {
	if e.gen_next > e.gen_ceil {
		if e.gen_next > max(u64) - GEN_BLOCK {
			return 0, .Corrupt
		}
		ceil := e.gen_next + GEN_BLOCK - 1
		path := _join(context.temp_allocator, e.dir, "gen") or_return
		buf: [8]u8
		prim.put_u64le(buf[:], ceil)
		_perr(prim.replace_atomic(e.base, path, buf[:])) or_return
		e.gen_ceil = ceil
	}
	gen = e.gen_next
	e.gen_next += 1
	return gen, .None
}

record_rid :: proc(e: ^Engine, o: Object, kind: Kind, seg: prim.Id, off: i64, ready: Ready = {}) -> (r: Rid, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, kind) or_return
	vs := obj.view_find(&h.view, seg)
	if vs < 0 {
		return {}, .Not_Found
	}
	got, gerr := obj.rid(&h.view, obj.Vref{vs, off})
	if gerr != .None {
		return {}, _pending_result(e, h, _oerr(gerr), ready)
	}
	return got, .None
}
