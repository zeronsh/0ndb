package rt

import "core:strings"
import "../journal"
import "../obj"
import "../prim"

run_raw_owner :: proc(run: ^Run) {
	if !run.raw_open || obj.rid_none(run.reply) {
		return
	}
	b: [33]u8
	b[0] = RAW_OWNER
	copy(b[1:], rid_bytes(run.reply))
	journal.journal_append(&run.raw, b[:])
}

run_raw_link :: proc(run: ^Run, msg: Rid, off: i64) {
	if !run.raw_open || obj.rid_none(msg) || off < 0 {
		return
	}
	b: [41]u8
	b[0] = RAW_LINK
	copy(b[1:33], rid_bytes(msg))
	prim.put_u64le(b[33:41], u64(off))
	journal.journal_append(&run.raw, b[:])
}

run_prompt_rid :: proc(run: ^Run, id: string) -> (Rid, bool) {
	if !obj.rid_none(run.user) && rid_uuid(run.user) == id {
		return run.user, true
	}
	if !obj.rid_none(run.reply) && rid_uuid(run.reply) == id {
		return run.reply, true
	}
	for s in run.steered {
		if rid_uuid(s) == id {
			return s, true
		}
	}
	if !obj.rid_none(run.raw_link) && rid_uuid(run.raw_link) == id {
		return run.raw_link, true
	}
	return {}, false
}

@(private)
_raw_run_start :: proc(body: []u8) -> bool {
	if len(body) != 25 && len(body) != 33 {
		return false
	}
	s := string(body[1:])
	return !strings.has_prefix(s, "spawn ") && !strings.has_prefix(s, "exit ")
}
