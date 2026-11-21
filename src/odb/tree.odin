package odb

import "core:slice"
import "core:strings"

MODE_TREE :: 0o040000
MODE_FILE :: 0o100644
MODE_EXEC :: 0o100755
MODE_LINK :: 0o120000
MODE_GITLINK :: 0o160000

Tree_Entry :: struct {
	name: string,
	oid:  Oid,
	mode: u32,
}

Tree_Iter :: struct {
	data: []u8,
	pos:  int,
	hsz:  int,
	err:  Error,
}

mode_valid :: proc "contextless" (mode: u32) -> bool {
	switch mode {
	case MODE_TREE, MODE_FILE, MODE_EXEC, MODE_LINK, MODE_GITLINK:
		return true
	}
	return false
}

tree_entry_compare :: proc "contextless" (a_name: string, a_mode: u32, b_name: string, b_mode: u32) -> int {
	n := min(len(a_name), len(b_name))
	for i in 0 ..< n {
		if a_name[i] != b_name[i] {
			return -1 if a_name[i] < b_name[i] else 1
		}
	}
	ca, cb: u8
	if len(a_name) > n {
		ca = a_name[n]
	} else if a_mode == MODE_TREE {
		ca = '/'
	}
	if len(b_name) > n {
		cb = b_name[n]
	} else if b_mode == MODE_TREE {
		cb = '/'
	}
	if ca != cb {
		return -1 if ca < cb else 1
	}
	return 0
}

tree_entry_less :: proc(a, b: Tree_Entry) -> bool {
	return tree_entry_compare(a.name, a.mode, b.name, b.mode) < 0
}

tree_sort :: proc(entries: []Tree_Entry) {
	slice.sort_by(entries, tree_entry_less)
}

name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || name == "." || name == ".." || strings.equal_fold(name, ".git") {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == 0 {
			return false
		}
	}
	return true
}

@(private)
mode_octal :: proc(buf: []u8, mode: u32) -> []u8 {
	tmp: [12]u8
	n := 0
	m := mode
	for {
		tmp[n] = u8('0' + m & 7)
		n += 1
		m >>= 3
		if m == 0 {
			break
		}
	}
	for i in 0 ..< n {
		buf[i] = tmp[n - 1 - i]
	}
	return buf[:n]
}

tree_size :: proc(entries: []Tree_Entry, format: Hash_Format) -> int {
	total := 0
	mb: [12]u8
	for e in entries {
		total += len(mode_octal(mb[:], e.mode)) + 1 + len(e.name) + 1 + oid_size(format)
	}
	return total
}

tree_validate :: proc(entries: []Tree_Entry) -> Error {
	for e, i in entries {
		if !mode_valid(e.mode) || !name_valid(e.name) {
			return .Invalid
		}
		if i > 0 && tree_entry_compare(entries[i - 1].name, entries[i - 1].mode, e.name, e.mode) >= 0 {
			return .Invalid
		}
		if i > 0 && entries[i - 1].name == e.name {
			return .Invalid
		}
	}
	return .None
}

tree_encode_into :: proc(out: []u8, entries: []Tree_Entry, format: Hash_Format) -> (n: int, err: Error) {
	tree_validate(entries) or_return
	hsz := oid_size(format)
	mb: [12]u8
	for e in entries {
		mode := mode_octal(mb[:], e.mode)
		need := len(mode) + 1 + len(e.name) + 1 + hsz
		if n + need > len(out) {
			return n, .Invalid
		}
		n += copy(out[n:], mode)
		out[n] = ' '
		n += 1
		n += copy(out[n:], e.name)
		out[n] = 0
		n += 1
		oid := e.oid
		n += copy(out[n:], oid[:hsz])
	}
	return n, .None
}

tree_encode :: proc(entries: []Tree_Entry, format: Hash_Format, allocator := context.allocator) -> (data: []u8, err: Error) {
	size := tree_size(entries, format)
	out, aerr := make([]u8, size, allocator)
	if aerr != nil {
		return nil, .Out_Of_Memory
	}
	if _, e := tree_encode_into(out, entries, format); e != .None {
		delete(out, allocator)
		return nil, e
	}
	return out, .None
}

tree_iter :: proc(data: []u8, format: Hash_Format) -> Tree_Iter {
	return {data = data, hsz = oid_size(format)}
}

tree_next :: proc(it: ^Tree_Iter) -> (entry: Tree_Entry, ok: bool) {
	if it.err != .None || it.pos >= len(it.data) {
		return
	}
	d := it.data
	p := it.pos
	mode: u32
	digits := 0
	for p < len(d) && d[p] != ' ' {
		c := d[p]
		if c < '0' || c > '7' || digits >= 7 {
			it.err = .Corrupt
			return
		}
		mode = mode << 3 | u32(c - '0')
		digits += 1
		p += 1
	}
	if digits == 0 || p >= len(d) {
		it.err = .Corrupt
		return
	}
	p += 1
	start := p
	for p < len(d) && d[p] != 0 {
		if d[p] == '/' {
			it.err = .Corrupt
			return
		}
		p += 1
	}
	if p == start || p + 1 + it.hsz > len(d) {
		it.err = .Corrupt
		return
	}
	entry.name = string(d[start:p])
	entry.mode = mode
	p += 1
	copy(entry.oid[:it.hsz], d[p:p + it.hsz])
	it.pos = p + it.hsz
	return entry, true
}

tree_decode :: proc(data: []u8, format: Hash_Format, allocator := context.allocator) -> (entries: []Tree_Entry, err: Error) {
	out := make([dynamic]Tree_Entry, allocator)
	it := tree_iter(data, format)
	for e in tree_next(&it) {
		if _, aerr := append(&out, e); aerr != nil {
			delete(out)
			return nil, .Out_Of_Memory
		}
	}
	if it.err != .None {
		delete(out)
		return nil, it.err
	}
	return out[:], .None
}

write_tree :: proc(db: ^Odb, entries: []Tree_Entry) -> (oid: Oid, err: Error) {
	size := tree_size(entries, db.format)
	if size <= 16 * 1024 {
		buf: [16 * 1024]u8
		n := tree_encode_into(buf[:], entries, db.format) or_return
		return write(db, .Tree, buf[:n])
	}
	data := tree_encode(entries, db.format, db.allocator) or_return
	defer delete(data, db.allocator)
	return write(db, .Tree, data)
}

pack_add_tree :: proc(b: ^Pack_Builder, entries: []Tree_Entry) -> (oid: Oid, err: Error) {
	data := tree_encode(entries, b.db.format, b.db.allocator) or_return
	defer delete(data, b.db.allocator)
	return pack_add(b, .Tree, data)
}
