package relayvec

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import osync "../../src/sync"

Vector :: struct {
	name:    string,
	summary: string,
	cfg:     Vec_Config,
	h:       Harness,
	b:       strings.Builder,
	nsteps:  int,
	failed:  bool,
}

Scenario :: struct {
	name:    string,
	summary: string,
	run:     proc(v: ^Vector),
}

vector_begin :: proc(v: ^Vector, sc: Scenario) {
	v.name = sc.name
	v.summary = sc.summary
	v.cfg = default_config()
	v.b = strings.builder_make()
}

vector_config :: proc(v: ^Vector, cfg: Vec_Config) {
	v.cfg = cfg
}

@(private)
_vector_start :: proc(v: ^Vector) {
	if v.nsteps > 0 {
		return
	}
	if harness_init(&v.h, v.cfg) != .None {
		v.failed = true
	}
	c := v.cfg
	fmt.sbprintf(&v.b, "{{\n  \"format\": \"%s\",\n  \"name\": \"%s\",\n  \"summary\": %q,\n", FORMAT, v.name, v.summary)
	fmt.sbprintf(&v.b, "  \"config\": {{\"wall_ms\": %d, \"mono_ms\": %d, \"open\": %v, \"quota\": %d, \"feed_compact\": %d, \"max_follows\": %d, \"principal_conns\": %d, \"max_space_conns\": %d}},\n", c.wall_ms, c.mono_ms, c.open, c.quota, c.feed_compact, c.max_follows, c.principal_conns, c.max_space_conns)
	strings.write_string(&v.b, "  \"steps\": [")
}

vector_track :: proc(v: ^Vector, space: osync.Space_Id) {
	for s in v.h.spaces {
		if s == space {
			return
		}
	}
	append(&v.h.spaces, space)
}

vector_step :: proc(v: ^Vector, s: Step) -> Step_Result {
	_vector_start(v)
	if v.failed {
		return {}
	}
	res, ok := harness_apply(&v.h, s, context.temp_allocator)
	if !ok {
		v.failed = true
		return {}
	}
	b := &v.b
	if v.nsteps > 0 {
		strings.write_string(b, ",")
	}
	v.nsteps += 1
	strings.write_string(b, "\n    {")
	switch s.kind {
	case .Connect:
		fmt.sbprintf(b, "\"step\": \"connect\", \"conn\": \"%s\", \"local\": %v, \"binding\": \"%s\"", s.conn, s.local, hex(s.binding))
	case .Send:
		fmt.sbprintf(b, "\"step\": \"send\", \"conn\": \"%s\", \"bytes\": \"%s\"", s.conn, hex(s.bytes))
	case .Durable:
		strings.write_string(b, "\"step\": \"durable\"")
	case .Close:
		fmt.sbprintf(b, "\"step\": \"close\", \"conn\": \"%s\"", s.conn)
	case .Clock:
		fmt.sbprintf(b, "\"step\": \"clock\", \"wall_ms\": %d, \"mono_ms\": %d", s.wall_ms, s.mono_ms)
	}
	if len(s.comment) > 0 {
		fmt.sbprintf(b, ", \"comment\": %q", s.comment)
	}
	strings.write_string(b, ",\n     \"out\": {")
	for o, i in res.outs {
		if i > 0 {
			strings.write_string(b, ",")
		}
		fmt.sbprintf(b, "\n       \"%s\": [", o.conn)
		for f, j in o.frames {
			if j > 0 {
				strings.write_string(b, ",")
			}
			fmt.sbprintf(b, "\n         {{\"kind\": \"%s\", \"frame\": \"%s\"}}", frame_name(f), hex(f))
		}
		strings.write_string(b, "]")
	}
	strings.write_string(b, "},\n     \"closed\": [")
	for c, i in res.closed {
		fmt.sbprintf(b, "%s\"%s\"", ", " if i > 0 else "", c)
	}
	strings.write_string(b, "],\n     \"store\": [")
	for e, i in res.effects {
		strings.write_string(b, ",\n       " if i > 0 else "\n       ")
		effect_json(b, e)
	}
	strings.write_string(b, "]}")
	return res
}

vector_end :: proc(v: ^Vector) -> string {
	_vector_start(v)
	strings.write_string(&v.b, "\n  ],\n  \"state\": ")
	state_json(&v.b, &v.h, "  ")
	strings.write_string(&v.b, "\n}\n")
	harness_destroy(&v.h)
	return strings.to_string(v.b)
}

check_embedded :: proc(files: []Embedded) -> (total: int, bad: int) {
	for f in files {
		total += 1
		if why, ok := check_vector(f.data); !ok {
			fmt.printfln("FAIL %s: %s", f.name, why)
			bad += 1
		} else {
			fmt.printfln("ok   %s", f.name)
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("%d vectors, %d failed", total, bad)
	return
}

Embedded :: struct {
	name: string,
	data: []u8,
}

@(private)
_obj :: proc(v: json.Value, key: string) -> json.Value {
	o, ok := v.(json.Object)
	if !ok {
		return nil
	}
	return o[key]
}

@(private)
_str :: proc(v: json.Value, key: string) -> string {
	s, _ := _obj(v, key).(json.String)
	return s
}

@(private)
_int :: proc(v: json.Value, key: string) -> i64 {
	#partial switch x in _obj(v, key) {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	}
	return 0
}

@(private)
_bool :: proc(v: json.Value, key: string) -> bool {
	b, _ := _obj(v, key).(json.Boolean)
	return b
}

check_vector :: proc(data: []u8) -> (why: string, ok: bool) {
	root, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != .None {
		return fmt.tprintf("json: %v", perr), false
	}
	if _str(root, "format") != FORMAT {
		return "unknown format", false
	}
	cv := _obj(root, "config")
	cfg := Vec_Config {
		wall_ms         = _int(cv, "wall_ms"),
		mono_ms         = _int(cv, "mono_ms"),
		open            = _bool(cv, "open"),
		quota           = _int(cv, "quota"),
		feed_compact    = _int(cv, "feed_compact"),
		max_follows     = int(_int(cv, "max_follows")),
		principal_conns = int(_int(cv, "principal_conns")),
		max_space_conns = int(_int(cv, "max_space_conns")),
	}
	h: Harness
	if harness_init(&h, cfg) != .None {
		return "harness init failed", false
	}
	defer harness_destroy(&h)
	steps, _ := _obj(root, "steps").(json.Array)
	for sv, i in steps {
		s: Step
		s.conn = _str(sv, "conn")
		switch _str(sv, "step") {
		case "connect":
			s.kind = .Connect
			s.local = _bool(sv, "local")
			s.binding, _ = unhex(_str(sv, "binding"), context.temp_allocator)
		case "send":
			s.kind = .Send
			b, hok := unhex(_str(sv, "bytes"), context.temp_allocator)
			if !hok {
				return fmt.tprintf("step %d: bad hex", i), false
			}
			s.bytes = b
		case "durable":
			s.kind = .Durable
		case "close":
			s.kind = .Close
		case "clock":
			s.kind = .Clock
			s.wall_ms = _int(sv, "wall_ms")
			s.mono_ms = _int(sv, "mono_ms")
		case:
			return fmt.tprintf("step %d: unknown step", i), false
		}
		res, aok := harness_apply(&h, s, context.temp_allocator)
		if !aok {
			return fmt.tprintf("step %d: harness rejected the step", i), false
		}
		want, _ := _obj(sv, "out").(json.Object)
		got := make(map[string][][]u8, context.temp_allocator)
		for o in res.outs {
			got[o.conn] = o.frames
		}
		for conn, fv in want {
			frames, _ := fv.(json.Array)
			have := got[conn]
			if len(have) != len(frames) {
				return fmt.tprintf("step %d (%s): conn %s got %d frames, want %d%s", i, _str(sv, "comment"), conn, len(have), len(frames), _frames_diff(have, frames)), false
			}
			for f, j in frames {
				wb, _ := unhex(_str(f, "frame"), context.temp_allocator)
				if !bytes_equal(wb, have[j]) {
					return fmt.tprintf("step %d (%s): conn %s frame %d differs: got %s %s want %s %s", i, _str(sv, "comment"), conn, j, frame_name(have[j]), hex(have[j]), frame_name(wb), hex(wb)), false
				}
			}
		}
		for conn, frames in got {
			if conn not_in want && len(frames) > 0 {
				return fmt.tprintf("step %d (%s): conn %s got %d unexpected frames%s", i, _str(sv, "comment"), conn, len(frames), _frames_diff(frames, nil)), false
			}
		}
		wclosed, _ := _obj(sv, "closed").(json.Array)
		if len(wclosed) != len(res.closed) {
			return fmt.tprintf("step %d: closed %v, want %d", i, res.closed, len(wclosed)), false
		}
		for c, j in wclosed {
			if cs, _ := c.(json.String); cs != res.closed[j] {
				return fmt.tprintf("step %d: closed %v differs", i, res.closed), false
			}
		}
		wstore, _ := _obj(sv, "store").(json.Array)
		if len(wstore) != len(res.effects) {
			return fmt.tprintf("step %d: %d storage effects, want %d", i, len(res.effects), len(wstore)), false
		}
		for e, j in res.effects {
			b := strings.builder_make(context.temp_allocator)
			effect_json(&b, e)
			ev, _ := json.parse(transmute([]u8)strings.to_string(b), .JSON, true, context.temp_allocator)
			w := wstore[j]
			if _str(ev, "op") != _str(w, "op") || _str(ev, "space") != _str(w, "space") || _str(ev, "id") != _str(w, "id") || _int(ev, "at") != _int(w, "at") || _int(ev, "len") != _int(w, "len") || _str(ev, "result") != _str(w, "result") {
				return fmt.tprintf("step %d: storage effect %d differs: %s", i, j, strings.to_string(b)), false
			}
		}
	}
	st, _ := _obj(root, "state").(json.Object)
	for k in st {
		if b, hok := unhex(k, context.temp_allocator); hok && len(b) == 16 {
			sp: osync.Space_Id
			copy(sp[:], b)
			append(&h.spaces, sp)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	state_json(&b, &h, "")
	gv, _ := json.parse(transmute([]u8)strings.to_string(b), .JSON, true, context.temp_allocator)
	if diff, same := _state_equal(gv, _obj(root, "state")); !same {
		return diff, false
	}
	return "", true
}

@(private)
_frames_diff :: proc(have: [][]u8, want: json.Array) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, " [got")
	for f in have {
		fmt.sbprintf(&b, " %s", frame_name(f))
	}
	strings.write_string(&b, "; want")
	for f in want {
		fmt.sbprintf(&b, " %s", _str(f, "kind"))
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

@(private)
_state_equal :: proc(got, want: json.Value) -> (string, bool) {
	g, _ := got.(json.Object)
	w, _ := want.(json.Object)
	if len(g) != len(w) {
		return "state: space count differs", false
	}
	for sp, wv in w {
		gv, found := g[sp]
		if !found {
			return fmt.tprintf("state: space %s missing", sp), false
		}
		for part in ([]string{"streams", "objects"}) {
			gp, _ := _obj(gv, part).(json.Object)
			wp, _ := _obj(wv, part).(json.Object)
			if len(gp) != len(wp) {
				return fmt.tprintf("state: %s count differs in %s (got %d, want %d)", part, sp, len(gp), len(wp)), false
			}
			for id, we in wp {
				ge, ok := gp[id]
				if !ok {
					return fmt.tprintf("state: %s %s missing", part, id), false
				}
				if _int(ge, "base") != _int(we, "base") || _int(ge, "length") != _int(we, "length") || _int(ge, "size") != _int(we, "size") || _str(ge, "sha256") != _str(we, "sha256") {
					return fmt.tprintf("state: %s %s differs", part, id), false
				}
			}
		}
	}
	return "", true
}
