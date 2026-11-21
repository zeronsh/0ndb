package mcp

import "core:strings"
import "../jsonschema"

@(private)
_dialect_uri :: proc(raw: string) -> string {
	v, ok := json_get_string(raw, "$schema")
	if !ok {
		return ""
	}
	return strings.trim_right(v, "#")
}

@(private)
_has_legacy_keywords :: proc(node: string, depth: int) -> bool {
	if depth > 64 {
		return true
	}
	switch json_kind(node) {
	case .Object:
		it, _ := json_object(node)
		for k, v in json_next_member(&it) {
			if json_key_is(k, "dependencies") || json_key_is(k, "additionalItems") || json_key_is(k, "$recursiveRef") {
				return true
			}
			if json_key_is(k, "items") && json_kind(v) == .Array {
				return true
			}
			if _has_legacy_keywords(v, depth + 1) {
				return true
			}
		}
	case .Array:
		it, _ := json_array(node)
		for v in json_next_item(&it) {
			if _has_legacy_keywords(v, depth + 1) {
				return true
			}
		}
	case .Invalid, .Null, .False, .True, .Number, .String:
	}
	return false
}

schema_dialect_supported :: proc(schema: string) -> bool {
	switch _dialect_uri(schema) {
	case "", "https://json-schema.org/draft/2020-12/schema":
		return true
	case "http://json-schema.org/draft-07/schema", "https://json-schema.org/draft-07/schema", "http://json-schema.org/draft-06/schema", "http://json-schema.org/draft-04/schema":
		return !_has_legacy_keywords(schema, 0)
	}
	return false
}

@(private)
_schema_compile :: proc(reg: ^jsonschema.Registry, schema: string) -> (jsonschema.Schema, bool) {
	src := schema
	uri := _dialect_uri(schema)
	if uri != "" && uri != "https://json-schema.org/draft/2020-12/schema" {
		b := make(Buf, 0, len(schema), context.temp_allocator)
		it, _ := json_object(schema)
		append(&b, '{')
		for k, v in json_next_member(&it) {
			if json_key_is(k, "$schema") {
				continue
			}
			w_sep(&b)
			append(&b, k)
			append(&b, ':')
			append(&b, v)
		}
		append(&b, '}')
		src = string(b[:])
	}
	compiled, err := jsonschema.compile(reg, transmute([]u8)src)
	return compiled, err == .None
}

@(private)
_schema_check :: proc(s: jsonschema.Schema, instance: string) -> (bool, string) {
	msg := make([dynamic]u8, context.temp_allocator)
	if jsonschema.validate(s, transmute([]u8)instance, &msg) {
		return true, ""
	}
	return false, string(msg[:])
}
