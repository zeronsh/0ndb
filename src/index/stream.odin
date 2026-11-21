package index

import "../journal"
import "../prim"

Index_Body :: union {
	Device,
	Thread_Update,
	Worktree_Update,
	Cursor,
	Rejected,
}

append_index :: proc(j: ^journal.Journal, body: Index_Body) -> (off: i64, err: Error) {
	w, jerr := journal.journal_begin(j)
	if jerr != .None {
		return 0, _jerr(jerr)
	}
	switch v in body {
	case Device:
		encode_device(&w, v)
	case Thread_Update:
		encode_thread_update(&w, v)
	case Worktree_Update:
		encode_worktree_update(&w, v)
	case Cursor:
		encode_cursor(&w, v)
	case Rejected:
		encode_rejected(&w, v)
	case:
		journal.journal_abort(j)
		return 0, .Invalid
	}
	o, eerr := journal.journal_end(j, &w)
	return o, _jerr(eerr)
}

append_entity :: proc(j: ^journal.Journal, kind: Kind, e: Entity) -> (off: i64, err: Error) {
	if kind != .Thread && kind != .Worktree {
		return 0, .Invalid
	}
	w, jerr := journal.journal_begin(j)
	if jerr != .None {
		return 0, _jerr(jerr)
	}
	encode_entity(&w, kind, e)
	o, eerr := journal.journal_end(j, &w)
	return o, _jerr(eerr)
}

append_cmd :: proc(j: ^journal.Journal, c: Cmd, p: Payload) -> (off: i64, err: Error) {
	if p == nil {
		return 0, .Invalid
	}
	w, jerr := journal.journal_begin(j)
	if jerr != .None {
		return 0, _jerr(jerr)
	}
	encode_cmd(&w, c, p)
	if w.err != .None {
		journal.journal_abort(j)
		return 0, .No_Memory
	}
	o, eerr := journal.journal_end(j, &w)
	return o, _jerr(eerr)
}

new_cmd :: proc(clock: ^prim.Hlc, host: prim.Id, thread: prim.Id) -> Cmd {
	return Cmd{id = prim.id_new(), hlc = prim.hlc_now(clock), host = host, thread = thread}
}
