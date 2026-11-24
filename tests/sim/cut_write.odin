package sim

import "core:strings"
import "../../src/prim"

Cut_Write :: struct {
	op:   ^M_Op,
	path: string,
	data: string,
	toks: []string,
}

disk_write_by :: proc(w: ^World, n: ^Node, op: ^M_Op, abs: string, data: []u8) -> prim.Error {
	old, _, _ := disk_probe_read(&n.disk, abs)
	err := _disk_write(disk_vfs(&n.disk), abs, data, false)
	if err == .None && !n.disk.dead {
		return .None
	}
	found := parse_tokens(old)
	toks := make([]string, len(found), w.allocator)
	for t, i in found {
		toks[i] = strings.clone(t.text, w.allocator)
	}
	if n.cut_writes == nil {
		n.cut_writes = make([dynamic]Cut_Write, w.allocator)
	}
	append(&n.cut_writes, Cut_Write{op = op, path = strings.clone(abs, w.allocator), data = strings.clone(string(data), w.allocator), toks = toks})
	if !n.disk.dead {
		_cut_write_note(n, n.cut_writes[len(n.cut_writes) - 1])
	}
	return err
}

cut_writes_crashed :: proc(n: ^Node) {
	for c in n.cut_writes {
		_cut_write_note(n, c)
	}
	cut_writes_drop(n)
}

cut_writes_drop :: proc(n: ^Node) {
	a := n.w.allocator
	for c in n.cut_writes {
		for t in c.toks {
			delete(t, a)
		}
		delete(c.toks, a)
		delete(c.path, a)
		delete(c.data, a)
	}
	clear(&n.cut_writes)
}

@(private = "file")
_cut_write_note :: proc(n: ^Node, c: Cut_Write) {
	now, _, _ := disk_probe_read(&n.disk, c.path)
	if string(now) == c.data {
		return
	}
	for t in c.toks {
		if token_in(string(now), t) {
			continue
		}
		known := false
		for d in c.op.deletes {
			known ||= d == t
		}
		if !known {
			append(&c.op.deletes, strings.clone(t, n.w.allocator))
		}
	}
}
