package mcp

import "../jsonschema"

@(private)
_schema_compile :: proc(reg: ^jsonschema.Registry, schema: string) -> (jsonschema.Schema, bool) {
	compiled, err := jsonschema.compile(reg, transmute([]u8)schema)
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
