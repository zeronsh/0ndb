package search

import "base:runtime"
import "core:slice"
import "../prim"

Verdict :: struct {
	ok:         bool,
	snippet:    string,
	snippet_at: u64,
	matches:    []Match,
}

Verify_Meta :: struct {
	object:      prim.Id,
	participant: prim.Id,
	hlc:         u64,
	kind:        u8,
}

verify_text :: proc(ix: ^Index, query: string, text: []u8, meta: Verify_Meta, now_ms: i64, allocator := context.allocator) -> (v: Verdict, err: Error) {
	arena: runtime.Arena
	if runtime.arena_init(&arena, 64 * 1024, context.allocator) != nil {
		return v, .No_Memory
	}
	defer runtime.arena_destroy(&arena)
	a := runtime.arena_allocator(&arena)
	req: Request
	q := parse(ix, query, &req, now_ms, a) or_return
	folded := make([]u8, len(text), a)
	fold_into(folded, text)
	for &c in q.clauses {
		any := false
		for &at in c.atoms {
			if _atom_holds(&at, folded, meta) != at.neg {
				any = true
				break
			}
		}
		if !any {
			return v, .None
		}
	}
	v.ok = true
	center := 0
	best := -1
	for &c in q.clauses {
		for &at in c.atoms {
			if !_is_text(&at) || at.neg || len(at.text) == 0 {
				continue
			}
			o := find_all(folded, at.text, at.word)
			if o.first >= 0 && len(at.text) > best {
				best = len(at.text)
				center = o.first
			}
		}
	}
	start := max(0, center - SNIPPET_LEAD)
	for k := start; k > max(0, start - 16); k -= 1 {
		if _is_space(text[k - 1]) {
			start = k
			break
		}
	}
	for start < len(text) && start > 0 && text[start] & 0xc0 == 0x80 {
		start += 1
	}
	end := min(len(text), start + SNIPPET)
	for end < len(text) && end > start && text[end] & 0xc0 == 0x80 {
		end -= 1
	}
	snip := make([]u8, end - start, allocator)
	copy(snip, text[start:end])
	v.snippet = string(snip)
	v.snippet_at = u64(start)
	ms := make([dynamic]Match, a)
	win := folded[start:end]
	for &c in q.clauses {
		for &at in c.atoms {
			if !_is_text(&at) || at.neg || len(at.text) == 0 {
				continue
			}
			p := 0
			for p + len(at.text) <= len(win) {
				o := find_all(win[p:], at.text, at.word)
				if o.first < 0 {
					break
				}
				append(&ms, Match{u32(p + o.first), u32(len(at.text))})
				p += o.first + len(at.text)
			}
		}
	}
	slice.sort_by(ms[:], proc(x, y: Match) -> bool {
		return x.start < y.start
	})
	out := make([dynamic]Match, allocator)
	for m in ms {
		if len(out) > 0 && m.start < out[len(out) - 1].start + out[len(out) - 1].len {
			continue
		}
		append(&out, m)
	}
	v.matches = out[:]
	return v, .None
}

@(private)
_atom_holds :: proc(at: ^Atom, folded: []u8, meta: Verify_Meta) -> bool {
	#partial switch at.field {
	case .Any, .Body:
		if len(at.text) == 0 {
			return true
		}
		return find_all(folded, at.text, at.word).first >= 0
	case .Title:
		return false
	case .Kind:
		return at.kind == meta.kind
	case .From:
		for id in at.ids {
			if id == meta.participant {
				return true
			}
		}
		return len(at.ids) == 0
	case .Object:
		for id in at.ids {
			if id == meta.object {
				return true
			}
		}
		return len(at.ids) == 0
	case .After:
		return u64(meta.hlc) >= at.hlc
	case .Before:
		return u64(meta.hlc) < at.hlc
	}
	return true
}
