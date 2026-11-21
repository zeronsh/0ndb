package odb

import "core:strconv"
import "core:strings"

Signature :: struct {
	name:  string,
	email: string,
	time:  i64,
	tz:    i32,
	raw:   string,
}

Commit :: struct {
	tree:      Oid,
	parents:   []Oid,
	author:    Signature,
	committer: Signature,
	extra:     string,
	message:   string,
	bodyless:  bool,
}

@(private)
sig_valid :: proc(s: Signature) -> bool {
	if s.time < 0 || s.tz <= -100 * 60 || s.tz >= 100 * 60 {
		return false
	}
	for c in transmute([]u8)s.name {
		if c == '<' || c == '>' || c == '\n' || c == 0 {
			return false
		}
	}
	for c in transmute([]u8)s.email {
		if c == '<' || c == '>' || c == '\n' || c == 0 {
			return false
		}
	}
	return true
}

@(private)
extra_valid :: proc(extra: string) -> bool {
	if len(extra) == 0 {
		return true
	}
	if extra[len(extra) - 1] != '\n' || extra[0] == ' ' || extra[0] == '\n' || strings.contains(extra, "\n\n") {
		return false
	}
	return strings.index_byte(extra, 0) < 0
}

@(private)
sig_text :: proc(s: Signature) -> (text: string, raw: bool) {
	if s.raw != "" && strings.index_byte(s.raw, '\n') < 0 && strings.index_byte(s.raw, 0) < 0 {
		p := sig_parse(s.raw)
		if p.name == s.name && p.email == s.email && p.time == s.time && p.tz == s.tz {
			return s.raw, true
		}
	}
	return "", false
}

@(private)
sig_write :: proc(b: ^strings.Builder, label: string, s: Signature) {
	strings.write_string(b, label)
	strings.write_byte(b, ' ')
	if text, raw := sig_text(s); raw {
		strings.write_string(b, text)
		strings.write_byte(b, '\n')
		return
	}
	strings.write_string(b, s.name)
	strings.write_string(b, " <")
	strings.write_string(b, s.email)
	strings.write_string(b, "> ")
	strings.write_i64(b, s.time)
	tz := s.tz
	strings.write_byte(b, ' ')
	strings.write_byte(b, '-' if tz < 0 else '+')
	if tz < 0 {
		tz = -tz
	}
	v := (tz / 60) * 100 + tz % 60
	digits := [4]u8{u8('0' + v / 1000), u8('0' + v / 100 % 10), u8('0' + v / 10 % 10), u8('0' + v % 10)}
	strings.write_bytes(b, digits[:])
	strings.write_byte(b, '\n')
}

commit_encode :: proc(c: Commit, format: Hash_Format, allocator := context.allocator) -> (data: []u8, err: Error) {
	_, author_raw := sig_text(c.author)
	_, committer_raw := sig_text(c.committer)
	if (!author_raw && !sig_valid(c.author)) || (!committer_raw && !sig_valid(c.committer)) || !extra_valid(c.extra) {
		return nil, .Invalid
	}
	if c.bodyless && len(c.message) > 0 {
		return nil, .Invalid
	}
	b, aerr := strings.builder_make_len_cap(0, 256 + len(c.message) + len(c.parents) * 72, allocator)
	if aerr != nil {
		return nil, .Out_Of_Memory
	}
	hb: [MAX_HEX]u8
	strings.write_string(&b, "tree ")
	strings.write_string(&b, oid_to_string(c.tree, format, &hb))
	strings.write_byte(&b, '\n')
	for p in c.parents {
		strings.write_string(&b, "parent ")
		strings.write_string(&b, oid_to_string(p, format, &hb))
		strings.write_byte(&b, '\n')
	}
	sig_write(&b, "author", c.author)
	sig_write(&b, "committer", c.committer)
	strings.write_string(&b, c.extra)
	if !c.bodyless {
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, c.message)
	if len(b.buf) != commit_size(c, format) {
		strings.builder_destroy(&b)
		return nil, .Out_Of_Memory
	}
	return b.buf[:], .None
}

@(private)
sig_size :: proc(label: string, s: Signature) -> int {
	if text, raw := sig_text(s); raw {
		return len(label) + 1 + len(text) + 1
	}
	tb: [24]u8
	return len(label) + 1 + len(s.name) + 2 + len(s.email) + 2 + len(strconv.write_int(tb[:], s.time, 10)) + 7
}

@(private)
commit_size :: proc(c: Commit, format: Hash_Format) -> int {
	hex := oid_size(format) * 2
	return 6 + hex + len(c.parents) * (8 + hex) + sig_size("author", c.author) + sig_size("committer", c.committer) + len(c.extra) + (0 if c.bodyless else 1) + len(c.message)
}

@(private)
sig_parse :: proc(s: string) -> (sig: Signature) {
	sig.raw = s
	lt := strings.index_byte(s, '<')
	gt := strings.last_index_byte(s, '>')
	if lt < 0 || gt < lt {
		sig.name = s
		return
	}
	sig.name = strings.trim_right(s[:lt], " ")
	sig.email = s[lt + 1:gt]
	rest := strings.trim_space(s[gt + 1:])
	sp := strings.index_byte(rest, ' ')
	if sp < 0 {
		sig.time = strconv.parse_i64_of_base(rest, 10) or_else 0
		return
	}
	sig.time = strconv.parse_i64_of_base(rest[:sp], 10) or_else 0
	tz := strings.trim_space(rest[sp + 1:])
	if len(tz) != 5 || (tz[0] != '+' && tz[0] != '-') {
		return
	}
	v, vok := strconv.parse_int(tz[1:], 10)
	if !vok {
		return
	}
	minutes := i32(v / 100 * 60 + v % 100)
	sig.tz = -minutes if tz[0] == '-' else minutes
	return
}

@(private)
lower_hex :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if c >= 'A' && c <= 'F' {
			return false
		}
	}
	return true
}

commit_decode :: proc(data: []u8, format: Hash_Format, allocator := context.allocator) -> (c: Commit, err: Error) {
	text := string(data)
	parents := make([dynamic]Oid, allocator)
	defer if err != .None {
		delete(parents)
	}
	next_line :: proc(text: ^string) -> (line: string, ok: bool) {
		nl := strings.index_byte(text^, '\n')
		if nl < 0 {
			return "", false
		}
		line = text[:nl]
		text^ = text[nl + 1:]
		return line, true
	}
	field :: proc(line, key: string) -> (string, bool) {
		if len(line) > len(key) && strings.has_prefix(line, key) && line[len(key)] == ' ' {
			return line[len(key) + 1:], true
		}
		return "", false
	}
	hex_len := oid_size(format) * 2
	line, ok := next_line(&text)
	value: string
	if value, ok = field(line, "tree"); !ok || len(value) != hex_len {
		return {}, .Corrupt
	}
	f: Hash_Format
	if c.tree, f, ok = oid_from_hex(value); !ok || f != format || !lower_hex(value) {
		return {}, .Corrupt
	}
	for {
		line = next_line(&text) or_else ""
		value, ok = field(line, "parent")
		if !ok {
			break
		}
		oid, pf, pok := oid_from_hex(value)
		if !pok || pf != format || !lower_hex(value) {
			return {}, .Corrupt
		}
		if _, aerr := append(&parents, oid); aerr != nil {
			return {}, .Out_Of_Memory
		}
	}
	if value, ok = field(line, "author"); !ok {
		return {}, .Corrupt
	}
	c.author = sig_parse(value)
	line = next_line(&text) or_else ""
	if value, ok = field(line, "committer"); !ok {
		return {}, .Corrupt
	}
	c.committer = sig_parse(value)
	extra_start := text
	for {
		if len(text) == 0 {
			c.bodyless = true
			break
		}
		line, ok = next_line(&text)
		if !ok {
			return {}, .Corrupt
		}
		if len(line) == 0 {
			break
		}
	}
	c.extra = extra_start[:len(extra_start) - len(text) - (0 if c.bodyless else 1)]
	c.parents = parents[:]
	c.message = text
	return c, .None
}

commit_destroy :: proc(c: ^Commit, allocator := context.allocator) {
	delete(c.parents, allocator)
	c.parents = nil
}

write_commit :: proc(db: ^Odb, c: Commit) -> (oid: Oid, err: Error) {
	data := commit_encode(c, db.format, db.allocator) or_return
	defer delete(data, db.allocator)
	return write(db, .Commit, data)
}

pack_add_commit :: proc(b: ^Pack_Builder, c: Commit) -> (oid: Oid, err: Error) {
	data := commit_encode(c, b.db.format, b.db.allocator) or_return
	defer delete(data, b.db.allocator)
	return pack_add(b, .Commit, data)
}
