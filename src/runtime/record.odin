package rt

import "../convo"
import eng "../engine"
import "../obj"

Record_Block :: struct {
	kind:   convo.Block_Kind,
	text:   string,
	id:     string,
	name:   string,
	failed: bool,
}

Record_Update :: struct {
	role:     convo.Role,
	parent:   Rid,
	blocks:   []Record_Block,
	status:   convo.Seal_Status,
	usage:    convo.Usage,
	provider: string,
	model:    string,
	native:   string,
}

record :: proc(r: ^Runtime, o: Object, source: string, external_id: string, sequence: u64, update: Record_Update) -> (receipt: convo.Receipt, msg: Rid, err: Error) {
	if len(source) == 0 || len(external_id) == 0 {
		return {}, {}, .Invalid
	}
	w := _convo_w(r, o)
	if w == nil {
		return {}, {}, .Engine
	}
	seq, prev, found, rerr := convo.writer_recorded(w, source, external_id)
	if rerr != .None {
		return {}, {}, .Engine
	}
	if found {
		if sequence == seq {
			return .Duplicate, prev, .None
		}
		if sequence < seq {
			return .Superseded, prev, .None
		}
	}
	parent := update.parent
	if found && obj.rid_none(parent) {
		v, verr := eng.convo_view(r.e, o)
		if verr == .None {
			if t, terr := convo.view_tail(v, r.self, context.temp_allocator); terr == .None {
				if m, merr := convo.message(v, &t, convo.Position{msg = prev}, context.temp_allocator); merr == .None {
					parent = m.parent
				}
			}
		}
	}
	role := update.role
	if role == convo.Role(0) {
		role = .Assistant
	}
	m, merr := convo.writer_message(w, convo.Msg_Spec{role = role, parent = parent, provider = update.provider, model = update.model, native = update.native})
	if merr != .None {
		return {}, {}, .Engine
	}
	for b in update.blocks {
		data := transmute([]u8)b.text
		if (b.kind == .Tool_Result || b.kind == .Image || b.kind == .File) && len(data) > convo.INLINE_MAX {
			fake := Run{r = r, o = o, reply = m}
			run_blob_block(&fake, b.kind, data, b.id, b.name, b.failed)
			continue
		}
		convo.writer_block(w, m, b.kind, data, b.id, b.name, b.failed)
	}
	status := update.status
	if status == .Open {
		status = .Done
	}
	convo.writer_seal(w, m, status, update.usage)
	rc, cerr := convo.writer_record(w, source, external_id, sequence, m)
	if cerr != .None {
		return {}, m, .Engine
	}
	eng.touched(r.e, o)
	eng.catalog_usage(r.e, o, update.usage)
	return rc, m, .None
}
