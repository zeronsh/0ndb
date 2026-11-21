package fs

import "base:runtime"
import "../crdt"
import "../odb"
import "../prim"

BUNDLE_FORMAT :: u8(1)

Bundle_Frame :: enum u8 {
	Header = 1,
	Record = 2,
	Lvidx  = 3,
	End    = 4,
}

Bundle_Sink :: struct {
	data:  rawptr,
	write: proc(data: rawptr, frame: []u8) -> Error,
}

Bundle_Source :: struct {
	data: rawptr,
	read: proc(data: rawptr, out: ^[dynamic]u8) -> (ok: bool, err: Error),
}

history_bundle_write :: proc(h: ^History, sink: Bundle_Sink) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	history_wake(h) or_return
	history_persist(h) or_return
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, u8(Bundle_Frame.Header))
	prim.write_u8(&w, BUNDLE_FORMAT)
	prim.write_id(&w, h.id)
	prim.write_id(&w, h.self)
	vb := make([dynamic]u8, context.temp_allocator)
	encode_version(&vb, history_heads(h, context.temp_allocator))
	prim.write_bytes(&w, vb[:])
	sink.write(sink.data, buf[:]) or_return
	State :: struct {
		sink: Bundle_Sink,
		buf:  [dynamic]u8,
		err:  Error,
	}
	st := State{sink, make([dynamic]u8, context.temp_allocator), .None}
	kv_each(&h.kv, &st, proc(data: rawptr, key: []u8, value: []u8) -> bool {
		s := (^State)(data)
		clear(&s.buf)
		w := prim.writer(&s.buf)
		prim.write_u8(&w, u8(Bundle_Frame.Record))
		prim.write_bytes(&w, key)
		prim.write_bytes(&w, value)
		s.err = s.sink.write(s.sink.data, s.buf[:])
		return s.err == .None
	}) or_return
	st.err or_return
	chunk := make([]u8, 4096 * LVIDX_REC, context.temp_allocator)
	off: u64
	total := h.lvidx_n * LVIDX_REC
	for off < total {
		n := min(u64(len(chunk)), total - off)
		got, rerr := prim.read_at(h.vfs, h.lvidx, chunk[:n], i64(off))
		if rerr != .None || u64(got) != n {
			return .Io
		}
		clear(&buf)
		w2 := prim.writer(&buf)
		prim.write_u8(&w2, u8(Bundle_Frame.Lvidx))
		prim.write_bytes(&w2, chunk[:n])
		sink.write(sink.data, buf[:]) or_return
		off += n
	}
	end := [1]u8{u8(Bundle_Frame.End)}
	return sink.write(sink.data, end[:])
}

history_bundle_load :: proc(h: ^History, vfs: prim.Vfs, dir: string, id: prim.Id, self: prim.Id, db: ^odb.Odb, streams: Stream_Source, source: Bundle_Source, allocator := context.allocator, opts := History_Options{}) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	from_prim(prim.mkdir_all(vfs, dir, 0o700)) or_return
	kv: Kv
	kv_open(&kv, vfs, dir, "state", allocator) or_return
	defer kv_close(&kv)
	lp, _ := path_join(dir, "lv.idx", context.temp_allocator)
	lfd, lerr := prim.open_file(vfs, lp, {.Write, .Create, .Truncate}, 0o600)
	if lerr != .None {
		return from_prim(lerr)
	}
	defer prim.close_file(vfs, lfd)
	lpos: i64
	frame := make([dynamic]u8, context.temp_allocator)
	seen_header := false
	done := false
	for !done {
		clear(&frame)
		ok := source.read(source.data, &frame) or_return
		if !ok || len(frame) == 0 {
			return .Corrupt
		}
		rd := prim.reader(frame[1:])
		switch Bundle_Frame(frame[0]) {
		case .Header:
			if prim.read_u8(&rd) != BUNDLE_FORMAT || prim.read_id(&rd) != id {
				return .Corrupt
			}
			seen_header = true
		case .Record:
			if !seen_header {
				return .Corrupt
			}
			key := prim.read_bytes(&rd)
			value := prim.read_bytes(&rd)
			if !prim.reader_ok(&rd) {
				return .Corrupt
			}
			v := remap_record(key, value, self) or_return
			kv_put(&kv, key, v) or_return
			if kv_dirty(&kv) && len(kv.order) >= 4096 {
				kv_commit(&kv) or_return
			}
		case .Lvidx:
			data := prim.read_bytes(&rd)
			if !prim.reader_ok(&rd) || len(data) % LVIDX_REC != 0 {
				return .Corrupt
			}
			out := make([]u8, len(data), context.temp_allocator)
			copy(out, data)
			for i := 0; i < len(out); i += LVIDX_REC {
				prim.put_u32le(out[i + 8:i + 12], prim.get_u32le(out[i + 8:i + 12]) + 1)
			}
			from_prim(prim.write_at(vfs, lfd, out, lpos)) or_return
			lpos += i64(len(out))
		case .End:
			done = true
		case:
			return .Corrupt
		}
	}
	kv_commit(&kv) or_return
	from_prim(prim.datasync(vfs, lfd)) or_return
	kv_close(&kv)
	return history_open(h, vfs, dir, id, self, db, streams, allocator, opts)
}

history_bundle_objects :: proc(h: ^History, data: rawptr, visit: proc(data: rawptr, oid: odb.Oid)) -> Error {
	State :: struct {
		data:  rawptr,
		visit: proc(data: rawptr, oid: odb.Oid),
	}
	st := State{data, visit}
	return kv_each(&h.kv, &st, proc(data: rawptr, key: []u8, value: []u8) -> bool {
		s := (^State)(data)
		if len(key) != 13 || key[0] != 'f' {
			return true
		}
		r: File_Record
		r.cp_version = make([dynamic]crdt.Op_Id, context.temp_allocator)
		r.cp_spans = make([dynamic]crdt.Author_Span, context.temp_allocator)
		if decode_file_record(value, &r) != .None {
			return true
		}
		if r.has_cp && r.cp_len > 0 {
			s.visit(s.data, r.cp_text)
		}
		if r.has_blob {
			s.visit(s.data, r.blob.oid)
		}
		return true
	})
}

@(private)
remap_record :: proc(key: []u8, value: []u8, self: prim.Id) -> (out: []u8, err: Error) {
	if string(key) == "s" {
		rd := prim.reader(value)
		if prim.read_u8(&rd) != 2 {
			return nil, .Corrupt
		}
		ns := prim.read_uvarint(&rd)
		if ns > u64(len(value)) {
			return nil, .Corrupt
		}
		Stream :: struct {
			id:      prim.Id,
			applied: u64,
			dict:    [dynamic]prim.Id,
		}
		list := make([dynamic]Stream, 0, int(ns), context.temp_allocator)
		for i in 0 ..< ns {
			s := Stream {
				id      = prim.read_id(&rd),
				applied = prim.read_uvarint(&rd),
				dict    = make([dynamic]prim.Id, context.temp_allocator),
			}
			if i > 0 {
				nd := prim.read_uvarint(&rd)
				if nd > u64(len(value)) {
					return nil, .Corrupt
				}
				for _ in 0 ..< nd {
					append(&s.dict, prim.read_id(&rd))
				}
			}
			append(&list, s)
		}
		own := prim.read_uvarint(&rd)
		if own > u64(len(value)) || len(list) == 0 {
			return nil, .Corrupt
		}
		for _ in 0 ..< own {
			append(&list[0].dict, prim.read_id(&rd))
		}
		moves := prim.read_uvarint(&rd)
		if !prim.reader_ok(&rd) {
			return nil, .Corrupt
		}
		buf := make([dynamic]u8, context.temp_allocator)
		w := prim.writer(&buf)
		prim.write_u8(&w, 2)
		prim.write_uvarint(&w, u64(len(list) + 1))
		prim.write_id(&w, self)
		prim.write_uvarint(&w, 0)
		for s in list {
			prim.write_id(&w, s.id)
			prim.write_uvarint(&w, s.applied)
			prim.write_uvarint(&w, u64(len(s.dict)))
			for x in s.dict {
				prim.write_id(&w, x)
			}
		}
		prim.write_uvarint(&w, 0)
		prim.write_uvarint(&w, moves)
		return buf[:], .None
	}
	if len(key) == 18 && key[0] == 'f' && key[1] == 'o' {
		rd := prim.reader(value)
		buf := make([dynamic]u8, 0, len(value) + 8, context.temp_allocator)
		w := prim.writer(&buf)
		for !prim.reader_done(&rd) {
			stream := prim.read_uvarint(&rd)
			off := prim.read_uvarint(&rd)
			from := prim.read_uvarint(&rd)
			to := prim.read_uvarint(&rd)
			if !prim.reader_ok(&rd) {
				return nil, .Corrupt
			}
			prim.write_uvarint(&w, stream + 1)
			prim.write_uvarint(&w, off)
			prim.write_uvarint(&w, from)
			prim.write_uvarint(&w, to)
		}
		return buf[:], .None
	}
	return value, .None
}
