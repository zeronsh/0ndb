package search

import "base:runtime"
import "core:slice"
import "../prim"

_dead_sorted :: proc(ix: ^Index, allocator: runtime.Allocator) -> (dead: []u32, err: Error) {
	all := make([dynamic]u32, allocator)
	for &s in ix.segs {
		if e := tomb_load(&s, &all); e != .None {
			delete(all)
			return nil, e
		}
	}
	append(&all, ..ix.mem.dead[:])
	slice.sort(all[:])
	return slice.unique(all[:]), .None
}

@(private)
_ids_hit :: proc(ids: []u8, dead: []u32) -> bool {
	for k := 0; k + 4 <= len(ids); k += 4 {
		if _, found := slice.binary_search(dead, prim.get_u32le(ids[k:])); found {
			return true
		}
	}
	return false
}

taint_refresh :: proc(ix: ^Index) -> Error {
	if !ix.taint_check {
		return .None
	}
	dead := _dead_sorted(ix, context.temp_allocator) or_return
	ix.zd_tainted = false
	ix.cb_tainted = false
	buf: Name_Buf
	if ix.man.zd_gen != 0 {
		data, rerr := prim.read_file(ix.vfs, zd_path(ix, ix.man.zd_gen, &buf), context.temp_allocator)
		if rerr != .None {
			return _perr(rerr)
		}
		_, ids, ok := zd_parse(data)
		if !ok {
			return .Corrupt
		}
		ix.zd_tainted = _ids_hit(ids, dead)
		slice.zero(data)
	}
	if ix.man.cb_gen != 0 {
		data, rerr := prim.read_file(ix.vfs, cb_path(ix, ix.man.cb_gen, &buf), context.temp_allocator)
		if rerr != .None {
			return _perr(rerr)
		}
		cb_load(ix, ix.man.cb_gen, context.temp_allocator) or_return
		dim := int(prim.get_u64le(data[16:]))
		m := int(prim.get_u64le(data[24:]))
		ksub := int(prim.get_u64le(data[32:]))
		at := CB_HEADER + (dim / m) * m * ksub * 4
		n := int(prim.get_u64le(data[at:]))
		ix.cb_tainted = _ids_hit(data[at + 8:][:4 * n], dead)
	}
	ix.taint_check = false
	return .None
}

zd_retrain :: proc(ix: ^Index) -> Error {
	dead := _dead_sorted(ix, context.temp_allocator) or_return
	zs := zd_samples_init(context.temp_allocator)
	m := &ix.mem
	for d, i in m.docs {
		if len(zs.bytes) >= DICT_SAMPLE_MAX {
			break
		}
		if d.flags & DF_TEXT == 0 || d.flags & (DF_DELETED | DF_UNSTABLE) != 0 {
			continue
		}
		at := int(m.frames[d.frame]) + int(d.frame_off)
		zd_sample_add(&zs, u32(m.base) + u32(i), m.raw[at:][:d.len])
	}
	blk: Doc_Block
	db_init(&blk, context.temp_allocator)
	frame := make([dynamic]u8, context.temp_allocator)
	scratch := make([dynamic]u8, context.temp_allocator)
	defer slice.zero(frame[:])
	frame_at := i64(-1)
	outer: for si := len(ix.segs) - 1; si >= 0; si -= 1 {
		s := &ix.segs[si]
		if !s.f.store || s.f.hi == s.f.lo {
			continue
		}
		for b := (s.f.hi - 1) / DOC_BLOCK; b >= s.f.lo / DOC_BLOCK; b -= 1 {
			doc_load(&ix.cache, s, &blk, b) or_return
			for k in 0 ..< blk.n {
				if len(zs.bytes) >= DICT_SAMPLE_MAX {
					break outer
				}
				dm := &blk.docs[k]
				if dm.flags & (DF_DELETED | DF_UNSTABLE) != 0 || dm.flags & DF_TEXT == 0 || dm.len < 8 {
					continue
				}
				if _, gone := slice.binary_search(dead, dm.id); gone {
					continue
				}
				if frame_at != dm.frame {
					frame_read(ix, s, dm.frame, &frame, &scratch) or_return
					frame_at = dm.frame
				}
				if int(dm.frame_off) + int(dm.len) > len(frame) {
					return .Corrupt
				}
				zd_sample_add(&zs, dm.id, frame[dm.frame_off:][:dm.len])
			}
			if b == 0 {
				break
			}
		}
		frame_at = -1
	}
	return zd_install(ix, &zs)
}

secure_remove :: proc(ix: ^Index, name: string) {
	buf: Name_Buf
	path := file_path(ix, name, &buf)
	fd, oerr := prim.open_file(ix.vfs, path, {.Write})
	if oerr != .None {
		_ = prim.remove(ix.vfs, path)
		return
	}
	st, serr := prim.fstat(ix.vfs, fd)
	ok := serr == .None
	zeros: [4096]u8
	for at := i64(0); ok && at < st.size; at += len(zeros) {
		n := min(i64(len(zeros)), st.size - at)
		ok = prim.write_at(ix.vfs, fd, zeros[:n], at) == .None
	}
	if ok {
		ok = prim.datasync(ix.vfs, fd) == .None
	}
	prim.close_file(ix.vfs, fd)
	if ok {
		_ = prim.remove(ix.vfs, path)
	}
}

@(private)
_stale_model :: proc(ix: ^Index) -> bool {
	for s in ix.segs {
		if s.f.vec_m > 0 && s.f.cb_gen != ix.man.cb_gen {
			return true
		}
		if ix.man.store && s.f.zd_gen != 0 && s.f.zd_gen != ix.man.zd_gen {
			return true
		}
	}
	return false
}

models_pending :: proc(ix: ^Index) -> bool {
	return ix.taint_check || ix.zd_tainted || ix.cb_tainted || ix.vtrain != nil || _stale_model(ix)
}

redact_models :: proc(ix: ^Index) -> (more: bool, err: Error) {
	taint_refresh(ix) or_return
	if ix.zd_tainted && ix.merge == nil {
		zd_retrain(ix) or_return
		ix.zd_tainted = false
	}
	if ix.cb_tainted && ix.vtrain == nil && ix.merge == nil {
		_ = vec_maybe_train(ix) or_return
		if ix.cb_tainted && ix.vtrain == nil {
			old := ix.man.cb_gen
			ix.man.cb_gen = 0
			if e := manifest_write(ix); e != .None {
				ix.man.cb_gen = old
				return false, e
			}
			ix.cb_tainted = false
		}
	}
	more = ix.zd_tainted || ix.cb_tainted || ix.vtrain != nil || _stale_model(ix)
	if !more && ix.merge == nil {
		cb_gc(ix)
	}
	return more, .None
}

@(private)
_clone_str :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
