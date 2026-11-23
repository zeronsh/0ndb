package sim

import "core:strings"
import eng "../../src/engine"

check_buffer_edits :: proc(w: ^World) {
	m := &w.model
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		for &ob, oi in m.objs {
			if ob.kind != .Text || !obj_exists(m, oi) {
				continue
			}
			data, err := eng.text_read(&n.e, ob.o, context.temp_allocator)
			if err != .None {
				continue
			}
			text := string(data)
			for op in m.ops {
				if op.obj != oi || !op_happened(op) {
					continue
				}
				#partial switch op.kind {
				case .Buffer_Delete:
					for tok in op.deletes {
						if strings.contains(text, tok) {
							world_fail(w, "buffer: edit lost: %s's buffer delete of %s (op %d) did not hold on %s", w.nodes[op.node].name, tok, op.idx, n.name)
						}
					}
				case .Buffer_Type:
					for tok in op.tokens {
						if !strings.contains(text, tok) && !_buffer_token_removed(m, oi, tok) {
							world_fail(w, "buffer: edit lost: %s's buffer insert of %s (op %d) is missing on %s", w.nodes[op.node].name, tok, op.idx, n.name)
						}
					}
				}
			}
		}
	}
}

@(private = "file")
_buffer_token_removed :: proc(m: ^Model, oi: int, tok: string) -> bool {
	for d in m.ops {
		if d.obj != oi || !op_maybe(d) {
			continue
		}
		if d.kind == .Redact_Text {
			return true
		}
		for x in d.deletes {
			if x == tok {
				return true
			}
		}
	}
	return false
}

@(init)
_buffer_edits_register :: proc "contextless" () {
	register_final_check(41, check_buffer_edits)
}
