#+build linux, darwin, windows
package osync

import "../journal"
import "../prim"

checkpoint_stream :: proc(scope: ^Scope, self: Device_Id, history: string) -> (id: Stream_Id, err: Error) {
	name := _concat(context.temp_allocator, CHECKPOINT_STREAM, history) or_return
	return stream_id(scope, self, name, 0), .None
}

replicator_checkpoint_redact :: proc(r: ^Replicator, scope: ^Scope, history: string, from, to: i64) -> Error {
	_enter(r)
	defer _leave(r)
	if to <= from {
		return .None
	}
	name := _concat(context.temp_allocator, CHECKPOINT_STREAM, history) or_return
	id := stream_id(scope, r.cfg.self, name, 0)
	pbuf: prim.Path_Buf = ---
	n := copy(pbuf[:], r.dir)
	n += copy(pbuf[n:], "/ckpt/")
	sid := id
	n += prim.hex_encode(pbuf[n:], sid[:])
	floor := replicator_floor(r, scope, name, 0) or_return
	j: journal.Journal
	if jerr := journal.journal_open(&j, r.vfs, string(pbuf[:n]), journal.Options{keep_at_least = floor}, context.allocator); jerr != .None {
		return _from_journal(jerr)
	}
	end := journal.journal_durable_len(&j)
	rerr := journal.journal_redact(&j, from, min(to, end))
	journal.journal_close(&j)
	if rerr != .None {
		return _from_journal(rerr)
	}
	if r.phase != .Ready {
		return .Closed
	}
	client_redact(&r.client, id, from, min(to, end)) or_return
	_repl_flush(r)
	return .None
}

replicator_checkpoint_length :: proc(r: ^Replicator, scope: ^Scope, history: string) -> (length: i64, err: Error) {
	_enter(r)
	defer _leave(r)
	name := _concat(context.temp_allocator, CHECKPOINT_STREAM, history) or_return
	id := stream_id(scope, r.cfg.self, name, 0)
	pbuf: prim.Path_Buf = ---
	n := copy(pbuf[:], r.dir)
	n += copy(pbuf[n:], "/ckpt/")
	sid := id
	n += prim.hex_encode(pbuf[n:], sid[:])
	if !prim.exists(r.vfs, string(pbuf[:n])) {
		return 0, .None
	}
	floor := replicator_floor(r, scope, name, 0) or_return
	j: journal.Journal
	if jerr := journal.journal_open(&j, r.vfs, string(pbuf[:n]), journal.Options{keep_at_least = floor}, context.allocator); jerr != .None {
		return 0, _from_journal(jerr)
	}
	length = journal.journal_durable_len(&j)
	journal.journal_close(&j)
	return length, .None
}
