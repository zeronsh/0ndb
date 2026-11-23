package sim

import "core:strings"
import eng "../../src/engine"

@(private = "file")
STAT_EB_CHECKED: Stat

@(private = "file")
Eb_Buf :: struct {
	rev: u64,
}

@(private = "file")
_eb_cb :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	if ev.kind == .Delta {
		(^Eb_Buf)(data).rev = ev.rev
	}
}

@(private = "file")
EB_TEXT :: "é😀"

@(private = "file")
_eb_one :: proc(w: ^World, n: ^Node, oi: int, utf16: bool) -> bool {
	context = instance_context(&n.inst)
	st := new(Eb_Buf, w.allocator)
	info, err := eng.buffer_open(&n.e, w.model.objs[oi].o, eng.Buffer_Options{units = .Utf16 if utf16 else .Bytes, cb = _eb_cb, data = st}, context.temp_allocator)
	if err != .None {
		return false
	}
	defer eng.buffer_close(&n.e, info.id)
	st.rev = info.rev
	text, rev, terr := eng.buffer_text(&n.e, info.id, context.temp_allocator)
	if terr != .None || rev != st.rev {
		return false
	}
	base := len(text) if !utf16 else _eb_units(string(text))
	mark := strings.clone(EB_TEXT, context.temp_allocator)
	ack, _, ierr := eng.buffer_edit(&n.e, info.id, st.rev, []eng.Buffer_Edit{{base, 0, transmute([]u8)mark}}, 0, {})
	if ierr != .None {
		return false
	}
	before, rev0, _ := eng.buffer_text(&n.e, info.id, context.temp_allocator)
	before = transmute([]u8)strings.clone(string(before), context.temp_allocator)
	splits: [dynamic]eng.Buffer_Edit
	splits.allocator = context.temp_allocator
	if utf16 {
		append(&splits, eng.Buffer_Edit{base + 2, 0, transmute([]u8)strings.clone("x", context.temp_allocator)})
		append(&splits, eng.Buffer_Edit{base + 1, 1, nil})
		append(&splits, eng.Buffer_Edit{base + 2, 1, nil})
	} else {
		append(&splits, eng.Buffer_Edit{base + 1, 0, transmute([]u8)strings.clone("x", context.temp_allocator)})
		append(&splits, eng.Buffer_Edit{base, 1, nil})
		append(&splits, eng.Buffer_Edit{base + 2, 2, nil})
		append(&splits, eng.Buffer_Edit{base + 4, 0, transmute([]u8)strings.clone("x", context.temp_allocator)})
	}
	for ed in splits {
		a2, r2, eerr := eng.buffer_edit(&n.e, info.id, rev0, []eng.Buffer_Edit{ed}, 0, {})
		after, rev1, _ := eng.buffer_text(&n.e, info.id, context.temp_allocator)
		if eerr != .Invalid {
			world_fail(w, "buffer: %s %s edit (pos %d del %d ins %q) splits a code point of %q but returned %v (ack %d rev %d)", n.name, "utf16" if utf16 else "bytes", ed.pos, ed.del, string(ed.ins), EB_TEXT, eerr, a2, r2)
			return true
		}
		if string(after) != string(before) || rev1 != rev0 {
			world_fail(w, "buffer: %s %s edit that splits a code point was refused but changed the buffer (rev %d -> %d)", n.name, "utf16" if utf16 else "bytes", rev0, rev1)
			return true
		}
	}
	ok_pos := base + (1 if utf16 else 2)
	if _, _, oerr := eng.buffer_edit(&n.e, info.id, rev0, []eng.Buffer_Edit{{ok_pos, 0, transmute([]u8)strings.clone("y", context.temp_allocator)}}, 0, {}); oerr != .None {
		world_fail(w, "buffer: %s %s edit on a code point boundary failed after refused splits: %v (ack %d)", n.name, "utf16" if utf16 else "bytes", oerr, ack)
	}
	stat_add(w, STAT_EB_CHECKED)
	return true
}

@(private = "file")
_eb_units :: proc(s: string) -> int {
	n := 0
	for r in s {
		n += 2 if r >= 0x10000 else 1
	}
	return n
}

check_edit_bounds :: proc(w: ^World) {
	if len(w.failures) > 0 {
		return
	}
	m := &w.model
	for &ob, oi in m.objs {
		if ob.kind != .Text || !obj_exists(m, oi) {
			continue
		}
		for idx in readers_of(w, oi) {
			n := w.nodes[idx]
			if !n.alive || !n.e_open {
				continue
			}
			if _eb_one(w, n, oi, true) && _eb_one(w, n, oi, false) {
				return
			}
		}
	}
}

@(init)
_edit_bounds_register :: proc "contextless" () {
	register_final_check(1004, check_edit_bounds)
	register_stat_line(34, "edit_bounds")
	STAT_EB_CHECKED = register_stat(34, 0, "checked")
}
