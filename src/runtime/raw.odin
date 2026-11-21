package rt

import "core:strings"
import "core:unicode/utf8"
import eng "../engine"
import "../journal"
import "../obj"
import "../prim"

@(private)
RAW_MATCH_MIN :: 16

raw_purge :: proc(r: ^Runtime, o: Object, msg: Rid, claim: Rid, bodies: []string) {
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
	Rec :: struct {
		off:  i64,
		kind: u8,
		run:  int,
	}
	Seg :: struct {
		owner: bool,
		claim: bool,
		typed: bool,
	}
	target := rid_bytes(msg)
	start := rid_bytes(claim) if !obj.rid_none(claim) else nil
	recs := make([dynamic]Rec, context.temp_allocator)
	segs := make([dynamic]Seg, context.temp_allocator)
	linked := make(map[i64]bool, context.temp_allocator)
	mine := make(map[i64]bool, context.temp_allocator)
	hits := make(map[i64]bool, context.temp_allocator)
	rd: journal.Reader
	journal.journal_reader(j, &rd, context.temp_allocator)
	end := journal.journal_durable_len(j)
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
		at := pos
		pos = next
		switch body[0] {
		case RAW_META:
			if _raw_run_start(body) {
				append(&segs, Seg{claim = start != nil && string(body[1:]) == string(start)})
			}
			continue
		case RAW_OWNER:
			if len(segs) > 0 && len(body) == 25 {
				segs[len(segs) - 1].typed = true
				segs[len(segs) - 1].owner ||= string(body[1:]) == string(target)
			}
			continue
		case RAW_LINK:
			if len(body) == 33 {
				x := i64(prim.get_u64le(body[25:33]))
				linked[x] = true
				if string(body[1:25]) == string(target) {
					mine[x] = true
				}
			}
			continue
		}
		append(&recs, Rec{off = at, kind = body[0], run = len(segs) - 1})
		line := string(body[1:])
		for n in needles {
			if strings.contains(line, n) {
				hits[at] = true
				break
			}
		}
	}
	offs := make([dynamic]i64, context.temp_allocator)
	for x in recs {
		take := mine[x.off] || hits[x.off]
		if !take && x.run >= 0 && !linked[x.off] {
			sg := segs[x.run]
			take = sg.owner || (!sg.typed && sg.claim && x.kind != RAW_STDIN)
		}
		if take {
			append(&offs, x.off)
		}
	}
	if len(offs) > 0 {
		journal.journal_redact_records(j, offs[:])
	}
}

run_raw_owner :: proc(run: ^Run) {
	if !run.raw_open || obj.rid_none(run.reply) {
		return
	}
	b: [25]u8
	b[0] = RAW_OWNER
	copy(b[1:], rid_bytes(run.reply))
	journal.journal_append(&run.raw, b[:])
}

run_raw_link :: proc(run: ^Run, msg: Rid, off: i64) {
	if !run.raw_open || obj.rid_none(msg) || off < 0 {
		return
	}
	b: [33]u8
	b[0] = RAW_LINK
	copy(b[1:25], rid_bytes(msg))
	prim.put_u64le(b[25:33], u64(off))
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
