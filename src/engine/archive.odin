package engine

import omap "../map"
import "../obj"
import "../prim"

@(private)
_Reg_Key :: struct {
	key: string,
	tag: u32,
}

@(private)
_Reg_Best :: struct {
	hlc:   prim.Hlc,
	value: []u8,
}

@(private)
_repl_archive_collect :: proc(user: rawptr, name: string, offs: []i64, bodies: [][]u8, gone: []bool) {
	_, kind, ok := _object_of_name(name)
	if !ok || kind != .Map {
		return
	}
	best := make(map[_Reg_Key]_Reg_Best, context.temp_allocator)
	for i := len(bodies) - 1; i >= 0; i -= 1 {
		body := bodies[i]
		if body == nil || obj.is_sig(body) || obj.is_redacted(body) || obj.record_kind(body) < obj.RECORD_KIND_FIRST {
			continue
		}
		env, eerr := obj.decode_envelope(body, offs[i])
		if eerr != .None || env.kind != u8(omap.Kind.Put) {
			continue
		}
		b, berr := omap.decode_body(&env, context.temp_allocator)
		if berr != .None {
			continue
		}
		put, is_put := b.(omap.Put)
		if !is_put || len(put.fields) == 0 {
			continue
		}
		covered := true
		for f in put.fields {
			k := _Reg_Key{string(put.key), f.tag}
			x, seen := best[k]
			if !seen || omap.register_wins(f.hlc, {}, f.value, x.hlc, {}, x.value) {
				covered = false
				best[k] = _Reg_Best{f.hlc, f.value}
			}
		}
		gone[i] = covered
	}
}
