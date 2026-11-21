package index

import "../journal"
import "../prim"

Overlay_State :: enum u8 {
	Pending  = 0,
	Rejected = 1,
}

Overlay_Item :: struct {
	off:       i64,
	cmd:       Cmd,
	state:     Overlay_State,
	rejection: Rejection,
}

overlay :: proc(t: ^Table, self: prim.Id, cmds: ^journal.Reader, from: i64, echoed: []prim.Id, allocator := context.allocator) -> (items: []Overlay_Item, next_from: i64, err: Error) {
	out := make([dynamic]Overlay_Item, allocator)
	pos := max(from, 0)
	oldest: i64 = -1
	for {
		body, next, e := journal.record_at(cmds, pos)
		if e == .Eof {
			break
		}
		if e != .None {
			return out[:], oldest if oldest >= 0 else pos, _jerr(e)
		}
		c, ce := decode_cmd(body)
		if ce == .None {
			state, keep, rej := _overlay_state(t, self, pos, &c, echoed, allocator) or_return
			if keep {
				c.payload = _clone_bytes(c.payload, allocator) or_return
				append(&out, Overlay_Item{pos, c, state, rej})
				if state == .Pending && oldest < 0 {
					oldest = pos
				}
			}
		}
		pos = next
	}
	return out[:], oldest if oldest >= 0 else pos, .None
}

command_pending :: proc(t: ^Table, self: prim.Id, off: i64, c: ^Cmd, echoed: []prim.Id) -> (pending: bool, err: Error) {
	state, keep, _ := _overlay_state(t, self, off, c, echoed, context.temp_allocator) or_return
	return keep && state == .Pending, .None
}

@(private)
_overlay_state :: proc(t: ^Table, self: prim.Id, off: i64, c: ^Cmd, echoed: []prim.Id, allocator := context.allocator) -> (state: Overlay_State, keep: bool, rej: Rejection, err: Error) {
	j, rejected := table_rejection(t, c.id, allocator) or_return
	if rejected {
		return .Rejected, true, j, .None
	}
	for id in echoed {
		if id == c.id {
			return .Pending, false, {}, .None
		}
	}
	cursor := table_cursor(t, c.host, self) or_return
	if off < cursor {
		return .Pending, false, {}, .None
	}
	return .Pending, true, {}, .None
}

@(private)
_clone_bytes :: proc(b: []u8, allocator := context.allocator) -> ([]u8, Error) {
	s, err := _clone_str(string(b), allocator)
	return transmute([]u8)s, err
}
