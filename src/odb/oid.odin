package odb

import "core:strconv"

Oid :: distinct [32]u8

ZERO_OID :: Oid{}

Hash_Format :: enum u8 {
	Sha1,
	Sha256,
}

MAX_HEX :: 64

Object_Type :: enum u8 {
	None   = 0,
	Commit = 1,
	Tree   = 2,
	Blob   = 3,
	Tag    = 4,
}

Error :: enum u8 {
	None,
	Not_Found,
	Corrupt,
	Too_Large,
	Io,
	Out_Of_Memory,
	Invalid,
	Not_Repository,
	Locked,
	Stale,
	Changed,
	Collision,
}

@(private, rodata)
HEX_DIGITS := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

oid_size :: proc "contextless" (format: Hash_Format) -> int {
	return 32 if format == .Sha256 else 20
}

oid_bytes :: proc "contextless" (oid: ^Oid, format: Hash_Format) -> []u8 {
	return oid[:oid_size(format)]
}

oid_to_string :: proc "contextless" (oid: Oid, format: Hash_Format, buf: ^[MAX_HEX]u8) -> string {
	n := oid_size(format)
	for i in 0 ..< n {
		b := oid[i]
		buf[i * 2] = HEX_DIGITS[b >> 4]
		buf[i * 2 + 1] = HEX_DIGITS[b & 15]
	}
	return string(buf[:n * 2])
}

@(private)
hex_value :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

oid_from_hex :: proc "contextless" (s: string) -> (oid: Oid, format: Hash_Format, ok: bool) {
	switch len(s) {
	case 40:
		format = .Sha1
	case 64:
		format = .Sha256
	case:
		return
	}
	for i in 0 ..< len(s) / 2 {
		hi := hex_value(s[i * 2]) or_return
		lo := hex_value(s[i * 2 + 1]) or_return
		oid[i] = hi << 4 | lo
	}
	return oid, format, true
}

oid_is_zero :: proc "contextless" (oid: Oid) -> bool {
	return oid == ZERO_OID
}

oid_compare :: proc "contextless" (a, b: Oid) -> int {
	for i in 0 ..< 32 {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	return 0
}

type_name :: proc "contextless" (type: Object_Type) -> string {
	switch type {
	case .Commit:
		return "commit"
	case .Tree:
		return "tree"
	case .Blob:
		return "blob"
	case .Tag:
		return "tag"
	case .None:
	}
	return ""
}

type_from_name :: proc "contextless" (name: string) -> Object_Type {
	switch name {
	case "commit":
		return .Commit
	case "tree":
		return .Tree
	case "blob":
		return .Blob
	case "tag":
		return .Tag
	}
	return .None
}

@(private)
object_header :: proc(buf: []u8, type: Object_Type, size: i64) -> []u8 {
	name := type_name(type)
	n := copy(buf, name)
	buf[n] = ' '
	n += 1
	n += len(strconv.write_int(buf[n:], size, 10))
	buf[n] = 0
	return buf[:n + 1]
}

@(private)
parse_object_header :: proc(data: []u8) -> (type: Object_Type, size: i64, header_len: int, err: Error) {
	space := -1
	for i in 0 ..< min(len(data), 8) {
		if data[i] == ' ' {
			space = i
			break
		}
	}
	if space <= 0 {
		return .None, 0, 0, .Corrupt
	}
	type = type_from_name(string(data[:space]))
	if type == .None {
		return .None, 0, 0, .Corrupt
	}
	i := space + 1
	if i >= len(data) || data[i] == 0 {
		return .None, 0, 0, .Corrupt
	}
	if data[i] == '0' && i + 1 < len(data) && data[i + 1] != 0 {
		return .None, 0, 0, .Corrupt
	}
	for i < len(data) && data[i] != 0 {
		c := data[i]
		if c < '0' || c > '9' || size > (max(i64) - 9) / 10 {
			return .None, 0, 0, .Corrupt
		}
		size = size * 10 + i64(c - '0')
		i += 1
	}
	if i >= len(data) {
		return .None, 0, 0, .Corrupt
	}
	return type, size, i + 1, .None
}
