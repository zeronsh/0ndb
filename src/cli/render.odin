package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../prim"

ago :: proc(ms: i64) -> string {
	if ms <= 0 {
		return "-"
	}
	d := (prim.now_ms() - ms) / 1000
	switch {
	case d < 0:
		return "now"
	case d < 60:
		return fmt.tprintf("%ds ago", d)
	case d < 3600:
		return fmt.tprintf("%dm ago", d / 60)
	case d < 86400:
		return fmt.tprintf("%dh ago", d / 3600)
	}
	return fmt.tprintf("%dd ago", d / 86400)
}

hlc_ms :: proc(h: i64) -> i64 {
	return i64(u64(h) >> 16)
}

bytes_human :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30:
		return fmt.tprintf("%.1f GiB", f64(n) / f64(1 << 30))
	case n >= 1 << 20:
		return fmt.tprintf("%.1f MiB", f64(n) / f64(1 << 20))
	case n >= 1 << 10:
		return fmt.tprintf("%.1f KiB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

one_line :: proc(s: string, limit: int) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		t = t[:i]
	}
	if len(t) > limit {
		cut := limit
		for cut > 0 && (t[cut] & 0xc0) == 0x80 {
			cut -= 1
		}
		return strings.concatenate({t[:cut], "…"}, context.temp_allocator)
	}
	return t
}

indent :: proc(s: string, prefix: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	lines := strings.split(strings.trim_right(s, "\n"), "\n", context.temp_allocator)
	for l, i in lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, prefix)
		strings.write_string(&b, l)
	}
	return strings.to_string(b)
}

print_message :: proc(m: json.Value, self: string, mark := "●") {
	role := jstr(m, "role")
	who := role
	author := jstr(m, "author")
	if role == "user" && len(author) > 0 && author != self {
		who = fmt.tprintf("user@%s", short(author))
	}
	if model := jstr(m, "model"); len(model) > 0 {
		who = fmt.tprintf("%s (%s)", who, model)
	}
	state := jstr(m, "status")
	if jbool(m, "open") {
		state = "running" if jstr(m, "open_state") == "running" else "reviving"
	}
	extra := ""
	if n := jint(m, "siblings"); n > 1 {
		extra = fmt.tprintf(" · branch %d/%d", jint(m, "sibling"), n)
	}
	if jbool(m, "redacted") {
		extra = strings.concatenate({extra, " · redacted"}, context.temp_allocator)
	}
	marker := "" if state == "done" else fmt.tprintf(" · %s", state)
	fmt.printfln("%s %s · %s%s%s · %s", mark, who, ago(hlc_ms(jint(m, "hlc"))), marker, extra, short_rid(jstr(m, "id")))
	for b in jarr(m, "blocks") {
		print_block(b)
	}
	for f in jarr(m, "files") {
		fmt.printfln("  ▸ files %s → tree %s", jstr(f, "mount"), short(jstr(f, "tree")))
	}
	u := jget(m, "usage")
	if jint(u, "input") > 0 || jint(u, "output") > 0 {
		fmt.printfln("  · %d in / %d out tokens", jint(u, "input") + jint(u, "cache_read") + jint(u, "cache_write"), jint(u, "output"))
	}
}

print_block :: proc(b: json.Value) {
	text := jstr(b, "text")
	if jbool(b, "is_ref") {
		blob := jget(b, "blob")
		text = fmt.tprintf("%s [%s stored, %d bytes]", jstr(blob, "preview"), short(jstr(blob, "oid")), jint(blob, "size"))
	}
	switch jstr(b, "kind") {
	case "text":
		fmt.println(indent(text, "  "))
	case "reasoning":
		fmt.println(indent(one_line(text, 160), "  ∴ "))
	case "tool_call":
		fmt.printfln("  ⚙ %s %s", jstr(b, "name"), one_line(text, 120))
	case "tool_result":
		mark := "✗" if jbool(b, "failed") else "↳"
		fmt.printfln("  %s %s", mark, one_line(text, 160))
	case "error":
		fmt.println(indent(text, "  ! "))
	case "notice":
		fmt.println(indent(text, "  ~ "))
	case "permission":
		fmt.printfln("  ? permission %s: %s", jstr(b, "name"), one_line(text, 120))
	case "permission_answer":
		fmt.printfln("  ✓ %s", one_line(text, 120))
	case "question":
		fmt.println(indent(text, "  ? "))
	case "image", "file":
		fmt.printfln("  ▣ %s %s", jstr(b, "name"), one_line(text, 80))
	case:
		fmt.println(indent(text, "  "))
	}
}

table :: proc(rows: [][]string) {
	if len(rows) == 0 {
		return
	}
	widths := make([]int, len(rows[0]), context.temp_allocator)
	for r in rows {
		for c, i in r {
			if i < len(widths) {
				widths[i] = max(widths[i], strings.rune_count(c))
			}
		}
	}
	for r in rows {
		b := strings.builder_make(context.temp_allocator)
		for c, i in r {
			strings.write_string(&b, c)
			if i < len(r) - 1 {
				for _ in 0 ..< widths[i] - strings.rune_count(c) + 2 {
					strings.write_byte(&b, ' ')
				}
			}
		}
		fmt.println(strings.trim_right(strings.to_string(b), " "))
	}
}

duration :: proc(ms: i64) -> string {
	d := ms / 1000
	switch {
	case d < 60:
		return fmt.tprintf("%ds", d)
	case d < 3600:
		return fmt.tprintf("%dm%02ds", d / 60, d % 60)
	case d < 86400:
		return fmt.tprintf("%dh%02dm", d / 3600, (d % 3600) / 60)
	}
	return fmt.tprintf("%dd%02dh", d / 86400, (d % 86400) / 3600)
}

row :: proc(cells: ..string) -> []string {
	out := make([]string, len(cells), context.temp_allocator)
	copy(out, cells)
	return out
}
