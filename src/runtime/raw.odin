package rt

import "core:strings"
import "core:unicode/utf8"
import eng "../engine"
import "../journal"
import "../obj"
import "../prim"

@(private)
RAW_MATCH_MIN :: 16

raw_purge :: proc(r: ^Runtime, o: Object, claim: Rid, bodies: []string) {
	needles := make([dynamic]string, context.temp_allocator)
	for t in bodies {
		if len(t) == 0 {
			continue
		}
		for ascii in ([]bool{false, true}) {
			esc := _json_escape(t, ascii)
			n := esc if len(t) >= RAW_MATCH_MIN else concat("\"", esc, "\"")
			dup := false
			for x in needles {
				dup ||= x == n
			}
			if !dup {
				append(&needles, n)
			}
		}
	}
	if len(needles) == 0 && obj.rid_none(claim) {
		return
	}
	j: ^journal.Journal
	own: journal.Journal
	for run in r.runs {
		if run.o == o && run.raw_open {
			j = &run.raw
		}
	}
	if j == nil {
		vfs := eng.vfs(r.e)
		path := concat(r.e.pack_root, "/raw/", hex(o.id))
		if _, serr := prim.stat(vfs, path); serr != .None {
			return
		}
		if journal.journal_open(&own, vfs, path, {}, r.allocator) != .None {
			return
		}
		j = &own
	}
	defer if j == &own {
		journal.journal_close(&own)
	}
	if journal.journal_commit(j) != .None {
		return
	}
	start := rid_bytes(claim) if !obj.rid_none(claim) else nil
	rd: journal.Reader
	journal.journal_reader(j, &rd, context.temp_allocator)
	end := journal.journal_durable_len(j)
	offs := make([dynamic]i64, context.temp_allocator)
	in_run := false
	pos: i64
	for pos < end {
		body, next, err := journal.record_at(&rd, pos)
		if err == .Redacted {
			pos = next
			continue
		}
		if err != .None || len(body) == 0 {
			break
		}
		hit := false
		if body[0] == RAW_META && _raw_run_start(body) {
			in_run = start != nil && string(body[1:]) == string(start)
		} else if in_run && (body[0] == RAW_STDOUT || body[0] == RAW_STDERR || body[0] == RAW_HTTP) {
			hit = true
		}
		if !hit && body[0] != RAW_META {
			line := string(body[1:])
			for n in needles {
				if strings.contains(line, n) {
					hit = true
					break
				}
			}
		}
		if hit {
			append(&offs, pos)
		}
		pos = next
	}
	if len(offs) > 0 {
		journal.journal_redact_records(j, offs[:])
	}
}

@(private)
_raw_run_start :: proc(body: []u8) -> bool {
	if len(body) != 25 {
		return false
	}
	s := string(body[1:])
	return !strings.has_prefix(s, "spawn ") && !strings.has_prefix(s, "exit ")
}

@(private)
_json_escape :: proc(s: string, ascii: bool) -> string {
	b := make([dynamic]u8, 0, len(s) + 8, context.temp_allocator)
	u4 :: proc(b: ^[dynamic]u8, v: u32) {
		h := "0123456789abcdef"
		x := [6]u8{'\\', 'u', h[v >> 12 & 0xf], h[v >> 8 & 0xf], h[v >> 4 & 0xf], h[v & 0xf]}
		append(b, ..x[:])
	}
	for c in s {
		switch c {
		case '"':
			append(&b, '\\', '"')
		case '\\':
			append(&b, '\\', '\\')
		case '\n':
			append(&b, '\\', 'n')
		case '\r':
			append(&b, '\\', 'r')
		case '\t':
			append(&b, '\\', 't')
		case '\b':
			append(&b, '\\', 'b')
		case '\f':
			append(&b, '\\', 'f')
		case:
			v := u32(c)
			switch {
			case v < 0x20:
				u4(&b, v)
			case v < 0x80 || !ascii:
				e, n := utf8.encode_rune(c)
				append(&b, ..e[:n])
			case v < 0x10000:
				u4(&b, v)
			case:
				x := v - 0x10000
				u4(&b, 0xd800 + (x >> 10))
				u4(&b, 0xdc00 + (x & 0x3ff))
			}
		}
	}
	return string(b[:])
}
