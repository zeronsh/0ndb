package fshist

import "base:runtime"
import "../crdt"
import "../fstree"

Text_Source :: struct {
	data:       rawptr,
	g:          ^crdt.Graph,
	allocator:  runtime.Allocator,
	content:    crdt.Content_Source,
	copies:     crdt.Copy_Source,
	op_ref:     proc(data: rawptr, inode: fstree.Inode_Id, i: u32) -> (Op_Ref, Error),
	record:     proc(data: rawptr, stream: u32, off: u64, buf: ^[dynamic]u8) -> ([]u8, Error),
	dict:       proc(data: rawptr, stream: u32) -> ^crdt.Actor_Dict,
	checkpoint: proc(data: rawptr, oid: Raw_Oid, size: i64, allocator: runtime.Allocator) -> ([]u8, Error),
	decoded:    proc(data: rawptr, stream: u32, off: u64) -> (^Decoded, Error),
}

Decoded :: struct {
	batch:  crdt.Batch,
	starts: []int,
	runs:   map[crdt.Op_Id][dynamic]i32,
}

decoded_build :: proc(d: ^Decoded, body: []u8, dict: ^crdt.Actor_Dict, allocator: runtime.Allocator) -> Error {
	payload, pok := batch_payload(body)
	if !pok {
		return .Corrupt
	}
	b, derr := crdt.batch_decode(payload, allocator, dict)
	if derr != .None {
		return .Corrupt
	}
	d.batch = b
	d.starts = make([]int, len(b.ops), allocator)
	d.runs = make(map[crdt.Op_Id][dynamic]i32, allocator)
	o := 0
	for op, i in b.ops {
		d.starts[i] = o
		if op.kind != .Opaque {
			if list, ok := &d.runs[op.target]; ok {
				append(list, i32(i))
			} else {
				l := make([dynamic]i32, 0, 4, allocator)
				append(&l, i32(i))
				d.runs[op.target] = l
			}
		}
		o += op.len
	}
	return .None
}

Text_State :: struct {
	text:    crdt.Text,
	log:     crdt.Text_Log,
	loaded:  bool,
	from_cp: bool,
}

text_drop :: proc(st: ^Text_State) {
	if st.loaded {
		crdt.text_destroy(&st.text)
		crdt.log_destroy(&st.log)
		st.loaded = false
	}
}

text_load :: proc(src: ^Text_Source, st: ^Text_State, inode: fstree.Inode_Id, target: crdt.Op_Id, rec: ^File_Record, extra: []Op_Ref, v: []crdt.Lv, full := false) -> Error {
	next: Text_State
	if err := _text_build(src, &next, inode, target, rec, extra, v, full); err != .None {
		text_drop(&next)
		return err
	}
	text_drop(st)
	st^ = next
	return .None
}

@(private = "file")
_text_build :: proc(src: ^Text_Source, st: ^Text_State, inode: fstree.Inode_Id, target: crdt.Op_Id, rec: ^File_Record, extra: []Op_Ref, v: []crdt.Lv, full: bool) -> Error {
	if rec.has_cp && !full {
		ok := text_load_checkpoint(src, st, inode, target, rec, extra, v) or_return
		if ok {
			return .None
		}
	}
	crdt.text_init(&st.text, src.allocator)
	crdt.log_init(&st.log, src.allocator, src.content, src.copies)
	st.loaded = true
	st.from_cp = false
	buf := make([dynamic]u8, context.temp_allocator)
	if rec.has_base {
		text_replay(src, st, target, rec.base, &buf, nil) or_return
	}
	text_replay_all(src, st, inode, target, rec, extra, 0, nil, &buf) or_return
	if me := crdt.text_merge(&st.text, src.g, &st.log, v); me != .None {
		return .Missing if me == .Missing_Content else .Corrupt
	}
	return .None
}

text_load_checkpoint :: proc(src: ^Text_Source, st: ^Text_State, inode: fstree.Inode_Id, target: crdt.Op_Id, rec: ^File_Record, extra: []Op_Ref, v: []crdt.Lv) -> (ok: bool, err: Error) {
	cpv := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(src.g, rec.cp_version[:], &cpv) != .None {
		return false, .None
	}
	if !crdt.graph_contains_all(src.g, v, cpv[:]) {
		return false, .None
	}
	data: []u8
	if rec.cp_len > 0 {
		if src.checkpoint == nil {
			return false, .None
		}
		d, e := src.checkpoint(src.data, rec.cp_text, rec.cp_len, context.temp_allocator)
		if e == .Not_Found {
			return false, .None
		}
		if e != .None {
			return false, e
		}
		data = d
	}
	if crdt.text_from(&st.text, src.g, data, rec.cp_spans[:], rec.cp_version[:], src.allocator) != .None {
		return false, .None
	}
	crdt.log_init(&st.log, src.allocator, src.content, src.copies)
	st.loaded = true
	buf := make([dynamic]u8, context.temp_allocator)
	descends, rerr := text_replay_all(src, st, inode, target, rec, extra, rec.cp_count, cpv[:], &buf)
	if rerr != .None || !descends {
		text_drop(st)
		return false, rerr
	}
	if crdt.text_merge(&st.text, src.g, &st.log, v) != .None {
		text_drop(st)
		return false, .None
	}
	st.from_cp = true
	return true, .None
}

text_replay_all :: proc(src: ^Text_Source, st: ^Text_State, inode: fstree.Inode_Id, target: crdt.Op_Id, rec: ^File_Record, extra: []Op_Ref, from: u32, base: []crdt.Lv, buf: ^[dynamic]u8) -> (descends: bool, err: Error) {
	for i := from; i < rec.ops; i += 1 {
		ref := src.op_ref(src.data, inode, i) or_return
		if !(text_replay(src, st, target, ref, buf, base) or_return) {
			return false, .None
		}
	}
	for ref in extra {
		if !(text_replay(src, st, target, ref, buf, base) or_return) {
			return false, .None
		}
	}
	return true, .None
}

text_replay :: proc(src: ^Text_Source, st: ^Text_State, target: crdt.Op_Id, ref: Op_Ref, buf: ^[dynamic]u8, base: []crdt.Lv) -> (descends: bool, err: Error) {
	if src.decoded != nil {
		d, derr := src.decoded(src.data, ref.stream, ref.off)
		if derr == .Redacted {
			return true, .None
		}
		if derr != .None {
			return false, derr
		}
		return _replay_decoded(src, st, target, ref, d, base)
	}
	body, rerr := src.record(src.data, ref.stream, ref.off, buf)
	if rerr == .Redacted {
		return true, .None
	}
	if rerr != .None {
		return false, rerr
	}
	payload, pok := batch_payload(body)
	if !pok {
		return false, .Corrupt
	}
	b, derr := crdt.batch_decode(payload, context.temp_allocator, src.dict(src.data, ref.stream))
	if derr != .None {
		return false, .Corrupt
	}
	if len(base) > 0 {
		ps := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(src.g, b.parents, &ps) != .None || !crdt.graph_contains_all(src.g, ps[:], base) {
			return false, .None
		}
	}
	use := &b
	if ref.to < u32(crdt.batch_len(&b)) {
		cut, cerr := crdt.batch_slice(&b, 0, int(ref.to), context.temp_allocator)
		if cerr != .None {
			return false, .Corrupt
		}
		use = &cut
	}
	first, ok := crdt.graph_lv(src.g, crdt.Op_Id{use.actor, use.seq})
	if !ok {
		return false, .Corrupt
	}
	crdt.log_add_batch(&st.log, src.g, use, target, first, 0)
	return true, .None
}

@(private = "file")
_replay_decoded :: proc(src: ^Text_Source, st: ^Text_State, target: crdt.Op_Id, ref: Op_Ref, d: ^Decoded, base: []crdt.Lv) -> (descends: bool, err: Error) {
	b := &d.batch
	if len(base) > 0 {
		ps := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(src.g, b.parents, &ps) != .None || !crdt.graph_contains_all(src.g, ps[:], base) {
			return false, .None
		}
	}
	n := crdt.batch_len(b)
	to := n
	if int(ref.to) < n {
		to = int(ref.to)
		if to <= 0 {
			return false, .Corrupt
		}
		lo, hi := 0, len(b.ops)
		for lo + 1 < hi {
			mid := (lo + hi) / 2
			if d.starts[mid] < to {
				lo = mid
			} else {
				hi = mid
			}
		}
		if b.ops[lo].kind == .Opaque && d.starts[lo] + b.ops[lo].len > to {
			return false, .Corrupt
		}
	}
	first, ok := crdt.graph_lv(src.g, crdt.Op_Id{b.actor, b.seq})
	if !ok {
		return false, .Corrupt
	}
	if list, found := d.runs[target]; found {
		for idx in list {
			at := d.starts[idx]
			if at >= to {
				break
			}
			op := b.ops[idx]
			if at + op.len > to {
				op = crdt.run_head(op, to - at)
			}
			crdt.log_push(&st.log, src.g, first + crdt.Lv(at), op)
		}
	}
	return true, .None
}
