package fs

import "../crdt"
import "../odb"
import "../prim"

Content_Ref :: struct {
	oid: odb.Oid,
	len: int,
}

history_record_oids :: proc(h: ^History, stream: prim.Id, body: []u8, out: ^[dynamic]Content_Ref) -> Error {
	if len(body) == 0 || body[0] != REC_BATCH && body[0] != REC_IMPORT {
		return .None
	}
	dict := &h.dict if stream == h.self else stream_dict(h, stream_index(h, stream))
	b, derr := crdt.batch_decode(body[1:], context.temp_allocator, dict)
	if derr != .None {
		return .Corrupt
	}
	for op in b.ops {
		switch op.kind {
		case .Insert_Ref:
			if op.ref.oid.len == 20 || op.ref.oid.len == 32 {
				content_ref_add(out, odb_oid(op.ref.oid), int(op.ref.oid.len))
			}
		case .Opaque:
			r := prim.reader(op.content)
			if prim.read_u8(&r) != TOP_CONTENT {
				continue
			}
			prim.read_id(&r)
			prim.read_uvarint(&r)
			n := int(prim.read_u8(&r))
			if n != 20 && n != 32 {
				continue
			}
			o: odb.Oid
			prim.read_fixed(&r, o[:n])
			if prim.reader_ok(&r) {
				content_ref_add(out, o, n)
			}
		case .Insert, .Delete, .Delete_Back, .Insert_Copy:
		}
	}
	return .None
}

@(private)
content_ref_add :: proc(out: ^[dynamic]Content_Ref, oid: odb.Oid, n: int) {
	for x in out {
		if x.oid == oid {
			return
		}
	}
	append(out, Content_Ref{oid, n})
}
