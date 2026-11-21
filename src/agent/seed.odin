package agent

import "core:mem"
import "core:strings"

@(private)
seed_budget :: proc(p: Provider, budget: int) -> int {
	if budget > 0 {
		return budget
	}
	switch p {
	case .Claude, .Codex, .Muse:
		return 120_000
	case .Pi, .Hermes, .Devin, .Antigravity:
		return 80_000
	case .Cursor, .OpenCode:
		return 60_000
	}
	return 60_000
}

@(private)
clip :: proc(s: string, limit: int) -> (string, bool) {
	if len(s) <= limit {
		return s, false
	}
	n := limit
	for n > 0 && (s[n] & 0xc0) == 0x80 {
		n -= 1
	}
	return s[:n], true
}

@(private)
first_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		return t[:i]
	}
	return t
}

@(private)
seed_entry :: proc(b: ^[dynamic]u8, xml: bool, e: Seed_Entry, compact: bool) {
	text_limit := compact ? 400 : 1 << 30
	in_limit := compact ? 160 : 2_000
	out_limit := compact ? 200 : 4_000
	switch e.role {
	case .User, .Assistant:
		role := e.role == .User ? "user" : "assistant"
		body, cut := clip(strings.trim_space(e.text), text_limit)
		if xml {
			put(b, "<", role, ">\n", body)
			if cut {
				append(b, " […]")
			}
			put(b, "\n</", role, ">\n")
		} else {
			put(b, e.role == .User ? "### User\n" : "### Assistant\n", body)
			if cut {
				append(b, " […]")
			}
			append(b, "\n\n")
		}
	case .Tool:
		input := compact ? first_line(e.input) : strings.trim_space(e.input)
		output := compact ? first_line(e.text) : strings.trim_space(e.text)
		in_text, in_cut := clip(input, in_limit)
		out_text, out_cut := clip(output, out_limit)
		status := e.is_error ? "error" : "ok"
		if xml {
			put(b, `<tool name="`, e.tool, `" status="`, status, "\">\n<input>", in_text)
			if in_cut {
				append(b, " […]")
			}
			put(b, "</input>\n<output>", out_text)
			if out_cut {
				append(b, " […]")
			}
			append(b, "</output>\n</tool>\n")
		} else {
			put(b, "- tool `", e.tool, "` (", status, "): ", in_text)
			if in_cut {
				append(b, " […]")
			}
			if out_text != "" {
				put(b, "\n  → ", out_text)
				if out_cut {
					append(b, " […]")
				}
			}
			append(b, "\n\n")
		}
	}
}

@(private)
render_seed :: proc(p: Provider, entries: []Seed_Entry, budget: int, allocator: mem.Allocator) -> string {
	limit := seed_budget(p, budget)
	xml := p == .Claude
	parts := make([]string, len(entries), context.temp_allocator)
	used := 0
	first := len(entries)
	for i := len(entries) - 1; i >= 0; i -= 1 {
		b := make([dynamic]u8, context.temp_allocator)
		seed_entry(&b, xml, entries[i], used > limit * 3 / 4)
		if used + len(b) > limit {
			if used > limit * 3 / 4 {
				break
			}
			b = make([dynamic]u8, context.temp_allocator)
			seed_entry(&b, xml, entries[i], true)
			if used + len(b) > limit {
				break
			}
		}
		used += len(b)
		parts[i] = string(b[:])
		first = i
	}
	out := make([dynamic]u8, allocator)
	intro := "This conversation continues from an earlier session that could not be resumed here. Its transcript follows, newest part verbatim and older parts condensed. Treat it as what already happened: do not redo finished work, and answer the new message below it."
	if xml {
		put(&out, "<previous_conversation>\n", intro, "\n")
	} else {
		put(&out, "## Previous conversation\n\n", intro, "\n\n")
	}
	if first > 0 {
		buf: [32]u8
		n := first
		i := len(buf)
		for {
			i -= 1
			buf[i] = u8('0' + n % 10)
			n /= 10
			if n == 0 {
				break
			}
		}
		put(&out, "[", string(buf[i:]), " earlier entries omitted]\n\n")
	}
	for part in parts[first:] {
		append(&out, part)
	}
	if xml {
		append(&out, "</previous_conversation>")
	} else {
		append(&out, "## New message")
	}
	return string(out[:])
}
