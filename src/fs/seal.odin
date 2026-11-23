package fs

import "../crdt"
import "../fshist"
import "../fstree"

REC_SEAL :: fshist.REC_SEAL

history_effective_seal :: proc(h: ^History, allocator := context.allocator) -> (v: Version, found: bool, err: Error) {
	data, ok := kv_get(&h.kv, transmute([]u8)string("seal"), context.temp_allocator) or_return
	if !ok {
		return nil, false, .None
	}
	out := decode_version(data, allocator) or_return
	return out, true, .None
}

@(private)
seal_key :: proc(stream: u32) -> []u8 {
	out := make([]u8, 7, context.temp_allocator)
	copy(out, "seal:")
	out[5] = u8(stream)
	out[6] = u8(stream >> 8)
	return out
}

@(private)
apply_seal :: proc(h: ^History, stream: u32, v: Version) -> Error {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return .None
	}
	buf := make([dynamic]u8, context.temp_allocator)
	encode_version(&buf, v)
	kv_put(&h.kv, seal_key(stream), buf[:]) or_return
	eff := make([dynamic]crdt.Lv, context.temp_allocator)
	have := false
	for i in 0 ..< len(h.stream_ids) {
		data, ok := kv_get(&h.kv, seal_key(u32(i)), context.temp_allocator) or_return
		if !ok {
			continue
		}
		sv := decode_version(data, context.temp_allocator) or_return
		sl := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, sv, &sl) != .None {
			continue
		}
		if !have {
			append(&eff, ..sl[:])
			have = true
			continue
		}
		walk := make([dynamic]crdt.Walk_Span, context.temp_allocator)
		common := make([dynamic]crdt.Lv, context.temp_allocator)
		crdt.graph_conflicting(&h.g, eff[:], sl[:], &walk, &common)
		clear(&eff)
		append(&eff, ..common[:])
	}
	if !have {
		return .None
	}
	prev, had := history_effective_seal(h, context.temp_allocator) or_return
	pl := make([dynamic]crdt.Lv, context.temp_allocator)
	if had {
		crdt.graph_version_lvs(&h.g, prev, &pl)
		if crdt.frontier_eq(pl[:], eff[:]) {
			return .None
		}
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, pl[:], eff[:], &only_a, &only_b)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	spans_touched(h, only_b[:], &touched) or_return
	for ino in sorted_inodes(touched) {
		seal_checkpoint(h, ino, eff[:]) or_return
	}
	ev := crdt.graph_version_ids(&h.g, eff[:], context.temp_allocator)
	clear(&buf)
	encode_version(&buf, ev)
	return kv_put(&h.kv, transmute([]u8)string("seal"), buf[:])
}

@(private)
seal_checkpoint :: proc(h: ^History, ino: fstree.Inode_Id, eff: []crdt.Lv) -> Error {
	if h.db == nil {
		return .None
	}
	history_unload_files(h)
	tmp: File_State
	tmp.inode = ino
	defer {
		fshist.text_drop(&tmp.st)
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	read_file_record(h, ino, &tmp.rec) or_return
	load_text(h, &tmp, eff) or_return
	data := crdt.text_bytes(&tmp.text, context.temp_allocator)
	oid := history_stage_blob(h, data) or_return
	history_note_file_blob(h, ino, oid, crdt.graph_version_ids(&h.g, eff, context.temp_allocator))
	count: u32
	for count < tmp.rec.ops {
		ref := read_op_ref(h, ino, count) or_return
		last, ok := ref_last_lv(h, ref)
		if !ok || !crdt.graph_contains(&h.g, eff, last) {
			break
		}
		count += 1
	}
	clear(&tmp.rec.cp_version)
	append(&tmp.rec.cp_version, ..crdt.graph_version_ids(&h.g, eff, context.temp_allocator))
	clear(&tmp.rec.cp_spans)
	append(&tmp.rec.cp_spans, ..crdt.text_spans(&tmp.text, &h.g, context.temp_allocator))
	tmp.rec.spans_ext = false
	tmp.rec.cp_text = fshist.Raw_Oid(oid)
	tmp.rec.cp_len = i64(len(data))
	tmp.rec.cp_count = count
	tmp.rec.has_cp = true
	buf := make([dynamic]u8, context.temp_allocator)
	encode_file_record(&buf, &tmp.rec)
	return kv_put(&h.kv, inode_key("f", ino), buf[:])
}

@(private)
ref_last_lv :: proc(h: ^History, ref: Op_Ref) -> (crdt.Lv, bool) {
	buf := make([dynamic]u8, context.temp_allocator)
	body, err := read_stream(h, ref.stream, i64(ref.off), &buf)
	if err != .None {
		return 0, false
	}
	payload, ok := batch_payload(body)
	if !ok {
		return 0, false
	}
	b, derr := crdt.batch_decode(payload, context.temp_allocator, stream_dict(h, ref.stream))
	if derr != .None || ref.to == 0 {
		return 0, false
	}
	return crdt.graph_lv(&h.g, crdt.Op_Id{b.actor, b.seq + u64(ref.to) - 1})
}

@(private)
apply_seal_record :: proc(h: ^History, stream: u32, body: []u8) -> Error {
	v, err := decode_version(body[1:], context.temp_allocator)
	if err != .None {
		return .Corrupt
	}
	return apply_seal(h, stream, v)
}
