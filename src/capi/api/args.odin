package api

import "base:runtime"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "../../convo"
import eng "../../engine"
import omap "../../map"
import "../../obj"
import "../../prim"

Rid :: obj.Rid
Object :: eng.Object

Arg_Type :: enum u8 {
	Bool,
	U64,
	I64,
	F64,
	Str,
	Bytes,
	Id,
	Rid,
	Object,
	Enum,
	Ids,
	Strs,
	U64s,
	Fields,
	Attachments,
	Blocks,
}

ARG_TYPE_NAMES := [Arg_Type]string {
	.Bool        = "bool",
	.U64         = "uvarint",
	.I64         = "ivarint",
	.F64         = "f64",
	.Str         = "str",
	.Bytes       = "bytes",
	.Id          = "id",
	.Rid         = "rid",
	.Object      = "object",
	.Enum        = "enum",
	.Ids         = "ids",
	.Strs        = "strs",
	.U64s        = "uvarints",
	.Fields      = "fields",
	.Attachments = "attachments",
	.Blocks      = "blocks",
}

Arg :: struct {
	name:  string,
	type:  Arg_Type,
	names: []string,
}

Value :: union {
	bool,
	u64,
	i64,
	f64,
	string,
	[]u8,
	prim.Id,
	Rid,
	Object,
	[]prim.Id,
	[]string,
	[]u64,
	[]omap.Field,
	[]convo.Attachment,
	[]Block_Arg,
}

Block_Arg :: struct {
	kind:   convo.Block_Kind,
	text:   string,
	id:     string,
	name:   string,
	failed: bool,
}

Args :: struct {
	values:  []Value,
	present: bit_set[0 ..< 64;u64],
}

decode_binary :: proc(op: ^Op, r: ^prim.Reader, a: ^Args, allocator: runtime.Allocator) -> bool {
	a.values = make([]Value, len(op.args), allocator)
	for arg, i in op.args {
		if prim.reader_remaining(r) == 0 {
			break
		}
		v: Value
		switch arg.type {
		case .Bool:
			v = prim.read_bool(r)
		case .U64, .Enum:
			v = prim.read_uvarint(r)
		case .I64:
			v = prim.read_ivarint(r)
		case .F64:
			v = transmute(f64)prim.read_u64le(r)
		case .Str:
			v = prim.read_str(r)
		case .Bytes:
			v = prim.read_bytes(r)
		case .Id:
			v = prim.read_id(r)
		case .Rid:
			seg := prim.read_id(r)
			off := prim.read_ivarint(r)
			v = Rid{seg, off, prim.read_uvarint(r)}
		case .Object:
			sp := prim.read_id(r)
			v = Object{sp, prim.read_id(r)}
		case .Ids:
			n := prim.read_len(r)
			if n > prim.reader_remaining(r) / 16 {
				return false
			}
			out := make([]prim.Id, n, allocator)
			for j in 0 ..< n {
				out[j] = prim.read_id(r)
			}
			v = out
		case .Strs:
			n := prim.read_len(r)
			if n > prim.reader_remaining(r) {
				return false
			}
			out := make([]string, n, allocator)
			for j in 0 ..< n {
				out[j] = prim.read_str(r)
			}
			v = out
		case .U64s:
			n := prim.read_len(r)
			if n > prim.reader_remaining(r) {
				return false
			}
			out := make([]u64, n, allocator)
			for j in 0 ..< n {
				out[j] = prim.read_uvarint(r)
			}
			v = out
		case .Fields:
			n := prim.read_len(r)
			if n > prim.reader_remaining(r) {
				return false
			}
			out := make([]omap.Field, n, allocator)
			for j in 0 ..< n {
				out[j].tag = u32(prim.read_uvarint(r))
				out[j].value = prim.read_bytes(r)
			}
			v = out
		case .Attachments:
			n := prim.read_len(r)
			if n > prim.reader_remaining(r) {
				return false
			}
			out := make([]convo.Attachment, n, allocator)
			for j in 0 ..< n {
				out[j].name = prim.read_str(r)
				out[j].mime = prim.read_str(r)
				out[j].oid = prim.read_bytes(r)
				out[j].size = prim.read_uvarint(r)
			}
			v = out
		case .Blocks:
			n := prim.read_len(r)
			if n > prim.reader_remaining(r) {
				return false
			}
			out := make([]Block_Arg, n, allocator)
			for j in 0 ..< n {
				k := prim.read_uvarint(r)
				out[j].kind = convo.Block_Kind(k) if k >= 1 && k <= 11 else .Text
				out[j].text = prim.read_str(r)
				out[j].id = prim.read_str(r)
				out[j].name = prim.read_str(r)
				out[j].failed = prim.read_bool(r)
			}
			v = out
		}
		if !prim.reader_ok(r) {
			return false
		}
		a.values[i] = v
		a.present += {i}
	}
	return prim.reader_done(r)
}

decode_json :: proc(op: ^Op, root: json.Object, a: ^Args, allocator: runtime.Allocator) -> bool {
	a.values = make([]Value, len(op.args), allocator)
	for arg, i in op.args {
		jv, ok := root[arg.name]
		if !ok {
			continue
		}
		if _, is_null := jv.(json.Null); is_null {
			continue
		}
		v, vok := _json_value(arg, jv, allocator)
		if !vok {
			return false
		}
		a.values[i] = v
		a.present += {i}
	}
	return true
}

@(private)
_json_value :: proc(arg: Arg, jv: json.Value, allocator: runtime.Allocator) -> (v: Value, ok: bool) {
	switch arg.type {
	case .Bool:
		b := jv.(json.Boolean) or_return
		return bool(b), true
	case .U64:
		return _json_u64(jv)
	case .I64:
		#partial switch x in jv {
		case json.Integer:
			return i64(x), true
		case json.Float:
			return i64(x), true
		case json.String:
			n, nok := strconv.parse_i64(string(x))
			return n, nok
		}
		return nil, false
	case .F64:
		#partial switch x in jv {
		case json.Integer:
			return f64(x), true
		case json.Float:
			return f64(x), true
		}
		return nil, false
	case .Enum:
		if s, is_str := jv.(json.String); is_str {
			for n, k in arg.names {
				if len(n) > 0 && n == string(s) {
					return u64(k), true
				}
			}
			return nil, false
		}
		return _json_u64(jv)
	case .Str:
		s := jv.(json.String) or_return
		return string(s), true
	case .Bytes:
		s := jv.(json.String) or_return
		return parse_hex(string(s), allocator)
	case .Id:
		s := jv.(json.String) or_return
		id, iok := prim.id_parse(string(s))
		return id, iok
	case .Rid:
		s := jv.(json.String) or_return
		r, rok := parse_rid(string(s))
		return r, rok
	case .Object:
		s := jv.(json.String) or_return
		ob, ook := parse_object(string(s))
		return ob, ook
	case .Ids:
		arr := jv.(json.Array) or_return
		out := make([]prim.Id, len(arr), allocator)
		for x, j in arr {
			s := x.(json.String) or_return
			out[j] = prim.id_parse(string(s)) or_return
		}
		return out, true
	case .Strs:
		arr := jv.(json.Array) or_return
		out := make([]string, len(arr), allocator)
		for x, j in arr {
			s := x.(json.String) or_return
			out[j] = string(s)
		}
		return out, true
	case .U64s:
		arr := jv.(json.Array) or_return
		out := make([]u64, len(arr), allocator)
		for x, j in arr {
			n := _json_u64(x) or_return
			out[j] = n.(u64)
		}
		return out, true
	case .Fields:
		arr := jv.(json.Array) or_return
		out := make([]omap.Field, len(arr), allocator)
		for x, j in arr {
			ob := x.(json.Object) or_return
			t := _json_u64(ob["tag"]) or_return
			out[j].tag = u32(t.(u64))
			if s, sok := ob["value"].(json.String); sok {
				b := parse_hex(string(s), allocator) or_return
				out[j].value = b.([]u8)
			} else if s2, tok := ob["text"].(json.String); tok {
				out[j].value = transmute([]u8)string(s2)
			}
		}
		return out, true
	case .Attachments:
		arr := jv.(json.Array) or_return
		out := make([]convo.Attachment, len(arr), allocator)
		for x, j in arr {
			ob := x.(json.Object) or_return
			if s, sok := ob["name"].(json.String); sok {
				out[j].name = string(s)
			}
			if s, sok := ob["mime"].(json.String); sok {
				out[j].mime = string(s)
			}
			if s, sok := ob["oid"].(json.String); sok {
				b := parse_hex(string(s), allocator) or_return
				out[j].oid = b.([]u8)
			}
			if n, nok := _json_u64(ob["size"]); nok {
				out[j].size = n.(u64)
			}
		}
		return out, true
	case .Blocks:
		arr := jv.(json.Array) or_return
		out := make([]Block_Arg, len(arr), allocator)
		for x, j in arr {
			ob := x.(json.Object) or_return
			out[j].kind = .Text
			if kv, kok := _json_value(Arg{"kind", .Enum, BLOCK_NAMES[:]}, ob["kind"], allocator); kok {
				k := kv.(u64)
				if k >= 1 && k <= 11 {
					out[j].kind = convo.Block_Kind(k)
				}
			}
			if s, sok := ob["text"].(json.String); sok {
				out[j].text = string(s)
			}
			if s, sok := ob["id"].(json.String); sok {
				out[j].id = string(s)
			}
			if s, sok := ob["name"].(json.String); sok {
				out[j].name = string(s)
			}
			if b, bok := ob["failed"].(json.Boolean); bok {
				out[j].failed = bool(b)
			}
		}
		return out, true
	}
	return nil, false
}

@(private)
_json_u64 :: proc(jv: json.Value) -> (v: Value, ok: bool) {
	#partial switch x in jv {
	case json.Integer:
		if x < 0 {
			return nil, false
		}
		return u64(x), true
	case json.Float:
		if x < 0 {
			return nil, false
		}
		return u64(x), true
	case json.String:
		n, nok := strconv.parse_u64(string(x))
		return n, nok
	}
	return nil, false
}

parse_hex :: proc(s: string, allocator: runtime.Allocator) -> (v: Value, ok: bool) {
	if len(s) % 2 != 0 {
		return nil, false
	}
	out := make([]u8, len(s) / 2, allocator)
	if !prim.hex_decode(out, transmute([]u8)s) {
		return nil, false
	}
	return out, true
}

parse_rid :: proc(s: string) -> (r: Rid, ok: bool) {
	if len(s) < 34 || s[32] != ':' {
		return {}, false
	}
	seg := prim.id_parse(s[:32]) or_return
	rest := s[33:]
	gen: u64
	if i := strings.index_byte(rest, ':'); i >= 0 {
		g, gok := strconv.parse_u64_of_base(rest[i + 1:], 10)
		if !gok {
			return {}, false
		}
		gen = g
		rest = rest[:i]
	}
	n, nok := strconv.parse_i64_of_base(rest, 10)
	if !nok {
		return {}, false
	}
	return Rid{seg, n, gen}, true
}

parse_object :: proc(s: string) -> (ob: Object, ok: bool) {
	if len(s) != 65 || (s[32] != '/' && s[32] != ':') {
		return {}, false
	}
	sp := prim.id_parse(s[:32]) or_return
	id := prim.id_parse(s[33:]) or_return
	return Object{sp, id}, true
}

@(private)
_index :: proc(c: ^Call, name: string) -> int {
	for a, i in c.op.args {
		if a.name == name {
			return i
		}
	}
	return -1
}

has :: proc(c: ^Call, name: string) -> bool {
	i := _index(c, name)
	return i >= 0 && i in c.args.present
}

@(private)
_get :: proc(c: ^Call, name: string) -> Value {
	i := _index(c, name)
	if i < 0 || i >= len(c.args.values) {
		return nil
	}
	return c.args.values[i]
}

a_bool :: proc(c: ^Call, name: string) -> bool {
	v, _ := _get(c, name).(bool)
	return v
}

a_u64 :: proc(c: ^Call, name: string, default_value: u64 = 0) -> u64 {
	if !has(c, name) {
		return default_value
	}
	v, _ := _get(c, name).(u64)
	return v
}

a_int :: proc(c: ^Call, name: string, default_value := 0) -> int {
	return int(min(a_u64(c, name, u64(max(default_value, 0))), u64(max(i32))))
}

a_i64 :: proc(c: ^Call, name: string) -> i64 {
	v, _ := _get(c, name).(i64)
	return v
}

a_f64 :: proc(c: ^Call, name: string) -> f64 {
	v, _ := _get(c, name).(f64)
	return v
}

a_str :: proc(c: ^Call, name: string) -> string {
	v, _ := _get(c, name).(string)
	return v
}

a_bytes :: proc(c: ^Call, name: string) -> []u8 {
	#partial switch v in _get(c, name) {
	case []u8:
		return v
	case string:
		return transmute([]u8)v
	}
	return nil
}

a_id :: proc(c: ^Call, name: string) -> prim.Id {
	v, _ := _get(c, name).(prim.Id)
	return v
}

a_rid :: proc(c: ^Call, name: string) -> Rid {
	v, _ := _get(c, name).(Rid)
	return v
}

a_object :: proc(c: ^Call, name: string) -> Object {
	v, _ := _get(c, name).(Object)
	return v
}

a_ids :: proc(c: ^Call, name: string) -> []prim.Id {
	v, _ := _get(c, name).([]prim.Id)
	return v
}

a_strs :: proc(c: ^Call, name: string) -> []string {
	v, _ := _get(c, name).([]string)
	return v
}

a_u64s :: proc(c: ^Call, name: string) -> []u64 {
	v, _ := _get(c, name).([]u64)
	return v
}

a_fields :: proc(c: ^Call, name: string) -> []omap.Field {
	v, _ := _get(c, name).([]omap.Field)
	return v
}

a_attachments :: proc(c: ^Call, name: string) -> []convo.Attachment {
	v, _ := _get(c, name).([]convo.Attachment)
	return v
}

a_blocks :: proc(c: ^Call, name: string) -> []Block_Arg {
	v, _ := _get(c, name).([]Block_Arg)
	return v
}
