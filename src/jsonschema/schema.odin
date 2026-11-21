package jsonschema

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

Vocabulary :: enum u8 {
	Core,
	Applicator,
	Unevaluated,
	Validation,
	Meta_Data,
	Format_Annotation,
	Format_Assertion,
	Content,
}

Vocabularies :: bit_set[Vocabulary;u8]

VOCAB_DEFAULT :: Vocabularies{.Core, .Applicator, .Unevaluated, .Validation, .Meta_Data, .Format_Annotation, .Content}

DRAFT_2020_12 :: "https://json-schema.org/draft/2020-12/schema"

Dialect :: enum u8 {
	Draft_04,
	Draft_06,
	Draft_07,
	Draft_2019_09,
	Draft_2020_12,
}

dialect_uri :: proc "contextless" (d: Dialect) -> string {
	switch d {
	case .Draft_04:
		return "http://json-schema.org/draft-04/schema#"
	case .Draft_06:
		return "http://json-schema.org/draft-06/schema#"
	case .Draft_07:
		return "http://json-schema.org/draft-07/schema#"
	case .Draft_2019_09:
		return "https://json-schema.org/draft/2019-09/schema"
	case .Draft_2020_12:
		return DRAFT_2020_12
	}
	return DRAFT_2020_12
}

@(private)
known_dialect :: proc "contextless" (uri: string) -> (Dialect, bool) {
	u, _ := uri_split(uri)
	switch u {
	case "http://json-schema.org/draft-04/schema", "https://json-schema.org/draft-04/schema":
		return .Draft_04, true
	case "http://json-schema.org/draft-06/schema", "https://json-schema.org/draft-06/schema":
		return .Draft_06, true
	case "http://json-schema.org/draft-07/schema", "https://json-schema.org/draft-07/schema":
		return .Draft_07, true
	case "https://json-schema.org/draft/2019-09/schema", "http://json-schema.org/draft/2019-09/schema":
		return .Draft_2019_09, true
	case "https://json-schema.org/draft/2020-12/schema", "http://json-schema.org/draft/2020-12/schema":
		return .Draft_2020_12, true
	}
	return .Draft_2020_12, false
}

Error :: enum u8 {
	None,
	Parse,
	No_Memory,
}

Loader :: #type proc(data: rawptr, uri: string) -> ([]u8, bool)

Registry :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	docs:      map[string]^Value,
	anchors:   map[string]^Value,
	dynamics:  map[string]^Value,
	base_of:   map[^Value]string,
	vocab_of:  map[^Value]Vocabularies,
	dialect_of: map[^Value]Dialect,
	dialect:   Dialect,
	regexes:   map[string]Rx,
	loader:    Loader,
	loader_data: rawptr,
	anon:      int,
	max_depth: int,
}

@(private)
Rx :: struct {
	rx: Regex,
	ok: bool,
}

Schema :: struct {
	reg:  ^Registry,
	root: ^Value,
	base: string,
}

registry_init :: proc(r: ^Registry) -> Error {
	r^ = {}
	if virtual.arena_init_growing(&r.arena) != nil {
		return .No_Memory
	}
	r.allocator = virtual.arena_allocator(&r.arena)
	r.docs = make(map[string]^Value, r.allocator)
	r.anchors = make(map[string]^Value, r.allocator)
	r.dynamics = make(map[string]^Value, r.allocator)
	r.base_of = make(map[^Value]string, r.allocator)
	r.vocab_of = make(map[^Value]Vocabularies, r.allocator)
	r.dialect_of = make(map[^Value]Dialect, r.allocator)
	r.dialect = .Draft_2020_12
	r.regexes = make(map[string]Rx, r.allocator)
	r.max_depth = 512
	return .None
}

registry_destroy :: proc(r: ^Registry) {
	virtual.arena_destroy(&r.arena)
	r^ = {}
}

registry_bytes :: proc(r: ^Registry) -> uint {
	return r.arena.total_used
}

set_loader :: proc(r: ^Registry, loader: Loader, data: rawptr) {
	r.loader = loader
	r.loader_data = data
}

add :: proc(r: ^Registry, uri: string, src: []u8) -> (Schema, Error) {
	v, ok := parse(src, r.allocator)
	if !ok {
		return {}, .Parse
	}
	root := new_clone(v, r.allocator)
	return add_value(r, uri, root), .None
}

add_value :: proc(r: ^Registry, uri: string, root: ^Value) -> Schema {
	base := uri
	if base == "" {
		r.anon += 1
		buf: [32]u8
		base = strings.concatenate({"urn:0ndb:schema:", itoa(buf[:], r.anon)}, r.allocator)
	} else {
		u, _ := uri_split(uri_resolve("", uri, r.allocator))
		base = strings.clone(u, r.allocator)
	}
	r.docs[base] = root
	walk(r, root, base, VOCAB_DEFAULT, r.dialect)
	return Schema{reg = r, root = root, base = r.base_of[root] if root in r.base_of else base}
}

compile :: proc(r: ^Registry, src: []u8, uri := "") -> (Schema, Error) {
	return add(r, uri, src)
}

@(private)
itoa :: proc(buf: []u8, n: int) -> string {
	i := len(buf)
	x := n
	if x == 0 {
		i -= 1
		buf[i] = '0'
	}
	for x > 0 {
		i -= 1
		buf[i] = u8('0' + x % 10)
		x /= 10
	}
	return string(buf[i:])
}

@(private)
id_key :: proc "contextless" (d: Dialect) -> string {
	return d == .Draft_04 ? "id" : "$id"
}

@(private)
walk :: proc(r: ^Registry, node: ^Value, base: string, vocab: Vocabularies, dialect: Dialect) {
	if node.kind == .Bool {
		r.base_of[node] = base
		r.vocab_of[node] = vocab
		r.dialect_of[node] = dialect
		return
	}
	if node.kind != .Object {
		return
	}
	b := base
	v := vocab
	d := dialect
	if sch, ok := get_string(node, "$schema"); ok {
		d = dialect_for(r, sch, 0)
		v = vocab_for(r, sch, d)
	}
	_, has_ref := get(node, "$ref")
	legacy := d <= .Draft_07
	if id, ok := get_string(node, id_key(d)); ok && !(legacy && has_ref) {
		full, frag := uri_split(uri_resolve(base, id))
		if full != "" || !legacy {
			b = strings.clone(full, r.allocator)
			if b not_in r.docs {
				r.docs[b] = node
			}
		}
		if legacy && frag != "" {
			r.anchors[strings.concatenate({b, "#", frag}, r.allocator)] = node
		}
	}
	r.base_of[node] = b
	r.vocab_of[node] = v
	r.dialect_of[node] = d
	if d >= .Draft_2019_09 {
		if a, ok := get_string(node, "$anchor"); ok {
			r.anchors[strings.concatenate({b, "#", a}, r.allocator)] = node
		}
	}
	if d >= .Draft_2020_12 {
		if a, ok := get_string(node, "$dynamicAnchor"); ok {
			key := strings.concatenate({b, "#", a}, r.allocator)
			if key not_in r.anchors {
				r.anchors[key] = node
			}
			r.dynamics[key] = node
		}
	}
	for k, i in node.keys {
		child := &node.vals[i]
		switch k {
		case "$defs", "definitions", "properties", "patternProperties", "dependentSchemas", "dependencies":
			if child.kind == .Object {
				for j in 0 ..< len(child.vals) {
					walk(r, &child.vals[j], b, v, d)
				}
			}
		case "additionalProperties", "propertyNames", "contains", "not", "if", "then", "else", "unevaluatedItems", "unevaluatedProperties", "additionalItems":
			walk(r, child, b, v, d)
		case "items":
			if child.kind == .Array {
				for j in 0 ..< len(child.items) {
					walk(r, &child.items[j], b, v, d)
				}
			} else {
				walk(r, child, b, v, d)
			}
		case "allOf", "anyOf", "oneOf", "prefixItems":
			if child.kind == .Array {
				for j in 0 ..< len(child.items) {
					walk(r, &child.items[j], b, v, d)
				}
			}
		}
	}
}

@(private)
dialect_for :: proc(r: ^Registry, meta_uri: string, depth: int) -> Dialect {
	if d, ok := known_dialect(meta_uri); ok {
		return d
	}
	if depth > 8 {
		return r.dialect
	}
	u, _ := uri_split(meta_uri)
	doc := lookup_doc(r, u)
	if doc == nil {
		return r.dialect
	}
	if sch, ok := get_string(doc, "$schema"); ok && sch != meta_uri {
		return dialect_for(r, sch, depth + 1)
	}
	return r.dialect
}

@(private)
vocab_for :: proc(r: ^Registry, meta_uri: string, d: Dialect) -> Vocabularies {
	if d < .Draft_2019_09 {
		return VOCAB_DEFAULT
	}
	if _, known := known_dialect(meta_uri); known {
		return VOCAB_DEFAULT
	}
	u, _ := uri_split(meta_uri)
	doc := lookup_doc(r, u)
	if doc == nil {
		return VOCAB_DEFAULT
	}
	vv, ok := get(doc, "$vocabulary")
	if !ok || vv.kind != .Object {
		return VOCAB_DEFAULT
	}
	out := Vocabularies{.Core}
	for k in vv.keys {
		switch k {
		case "https://json-schema.org/draft/2020-12/vocab/applicator":
			out += {.Applicator}
		case "https://json-schema.org/draft/2019-09/vocab/applicator":
			out += {.Applicator, .Unevaluated}
		case "https://json-schema.org/draft/2020-12/vocab/unevaluated":
			out += {.Unevaluated}
		case "https://json-schema.org/draft/2020-12/vocab/validation", "https://json-schema.org/draft/2019-09/vocab/validation":
			out += {.Validation}
		case "https://json-schema.org/draft/2020-12/vocab/meta-data", "https://json-schema.org/draft/2019-09/vocab/meta-data":
			out += {.Meta_Data}
		case "https://json-schema.org/draft/2020-12/vocab/format-annotation", "https://json-schema.org/draft/2019-09/vocab/format":
			out += {.Format_Annotation}
		case "https://json-schema.org/draft/2020-12/vocab/format-assertion":
			out += {.Format_Assertion}
		case "https://json-schema.org/draft/2020-12/vocab/content", "https://json-schema.org/draft/2019-09/vocab/content":
			out += {.Content}
		}
	}
	return out
}

@(private)
lookup_doc :: proc(r: ^Registry, u: string) -> ^Value {
	if d, ok := r.docs[u]; ok {
		return d
	}
	if src, ok := embedded(u); ok {
		s, err := add(r, u, src)
		if err == .None {
			return s.root
		}
	}
	if r.loader != nil {
		if src, ok := r.loader(r.loader_data, u); ok {
			s, err := add(r, u, src)
			if err == .None {
				return s.root
			}
		}
	}
	return nil
}

@(private)
resolve :: proc(r: ^Registry, base: string, ref: string) -> (target: ^Value, doc_uri: string, frag: string, ok: bool) {
	full := uri_resolve(base, ref)
	u, f := uri_split(full)
	doc := lookup_doc(r, u)
	if doc == nil {
		return nil, u, f, false
	}
	if f == "" {
		return doc, u, f, true
	}
	if f[0] == '/' {
		t, pok := pointer(doc, percent_decode(f))
		return t, u, f, pok
	}
	key := strings.concatenate({u, "#", f}, context.temp_allocator)
	if t, aok := r.anchors[key]; aok {
		return t, u, f, true
	}
	return nil, u, f, false
}

Result :: struct {
	valid:   bool,
	message: string,
}

@(private)
Ann :: struct {
	props: []bool,
	items: []bool,
}

@(private)
Eval :: struct {
	r:     ^Registry,
	scope: [dynamic]string,
	err:   ^[dynamic]u8,
	path:  [dynamic]u8,
	quiet: int,
	depth: int,
}

validate :: proc(s: Schema, instance: []u8, err: ^[dynamic]u8 = nil) -> bool {
	inst, ok := parse(instance, context.temp_allocator)
	if !ok {
		if err != nil {
			append(err, "$: the instance is not valid JSON")
		}
		return false
	}
	return validate_value(s, &inst, err)
}

validate_value :: proc(s: Schema, inst: ^Value, err: ^[dynamic]u8 = nil) -> bool {
	e := Eval {
		r     = s.reg,
		scope = make([dynamic]string, context.temp_allocator),
		err   = err,
		path  = make([dynamic]u8, context.temp_allocator),
	}
	append(&e.path, '$')
	append(&e.scope, s.base)
	return eval(&e, s.root, inst, s.base, nil)
}

@(private)
fail :: proc(e: ^Eval, msg: string, detail := "") -> bool {
	if e.quiet > 0 || e.err == nil || len(e.err) > 0 {
		return false
	}
	append(e.err, ..e.path[:])
	append(e.err, ": ")
	append(e.err, msg)
	if detail != "" {
		append(e.err, " ")
		append(e.err, detail)
	}
	return false
}

@(private)
ann_make :: proc(inst: ^Value) -> Ann {
	a: Ann
	#partial switch inst.kind {
	case .Object:
		a.props = make([]bool, len(inst.keys), context.temp_allocator)
	case .Array:
		a.items = make([]bool, len(inst.items), context.temp_allocator)
	}
	return a
}

@(private)
ann_merge :: proc(dst: ^Ann, src: ^Ann) {
	if dst == nil {
		return
	}
	for i in 0 ..< min(len(dst.props), len(src.props)) {
		dst.props[i] ||= src.props[i]
	}
	for i in 0 ..< min(len(dst.items), len(src.items)) {
		dst.items[i] ||= src.items[i]
	}
}

@(private)
regex_for :: proc(r: ^Registry, pattern: string) -> (^Regex, bool) {
	if c, ok := &r.regexes[pattern]; ok {
		return &c.rx, c.ok
	}
	rx, ok := regex_compile(pattern, r.allocator)
	key := strings.clone(pattern, r.allocator)
	r.regexes[key] = Rx{rx, ok}
	c := &r.regexes[key]
	return &c.rx, ok
}

@(private)
matches :: proc(e: ^Eval, pattern: string, s: string) -> (bool, bool) {
	rx, ok := regex_for(e.r, pattern)
	if !ok {
		return false, false
	}
	res := regex_search(rx, s)
	return res == .Match, res != .Too_Complex
}

@(private)
push_key :: proc(e: ^Eval, key: string) -> int {
	n := len(e.path)
	append(&e.path, '/')
	append(&e.path, key)
	return n
}

@(private)
push_index :: proc(e: ^Eval, i: int) -> int {
	n := len(e.path)
	append(&e.path, '/')
	buf: [32]u8
	append(&e.path, itoa(buf[:], i))
	return n
}

@(private)
eval :: proc(e: ^Eval, s: ^Value, inst: ^Value, base: string, parent: ^Ann) -> bool {
	if s.kind == .Bool {
		if !s.b {
			return fail(e, "no value is allowed here")
		}
		return true
	}
	if s.kind != .Object {
		return true
	}
	if e.depth > e.r.max_depth {
		return fail(e, "schema evaluation is nested too deeply")
	}
	e.depth += 1
	defer e.depth -= 1
	b := base
	if known, ok := e.r.base_of[s]; ok {
		b = known
	}
	vocab := VOCAB_DEFAULT
	if v, ok := e.r.vocab_of[s]; ok {
		vocab = v
	}
	d := e.r.dialect
	if dd, ok := e.r.dialect_of[s]; ok {
		d = dd
	}
	pushed := false
	if len(e.scope) == 0 || e.scope[len(e.scope) - 1] != b {
		append(&e.scope, b)
		pushed = true
	}
	defer if pushed {
		pop(&e.scope)
	}
	my := ann_make(inst)
	if !eval_core(e, s, inst, b, &my, d) {
		return false
	}
	if d <= .Draft_07 {
		if _, has_ref := get(s, "$ref"); has_ref {
			ann_merge(parent, &my)
			return true
		}
	}
	if .Applicator in vocab && !eval_applicators(e, s, inst, b, &my, d) {
		return false
	}
	if .Validation in vocab && !eval_validation(e, s, inst, d) {
		return false
	}
	if d >= .Draft_2019_09 && .Unevaluated in vocab && !eval_unevaluated(e, s, inst, b, &my) {
		return false
	}
	ann_merge(parent, &my)
	return true
}

@(private)
eval_core :: proc(e: ^Eval, s: ^Value, inst: ^Value, b: string, my: ^Ann, d: Dialect) -> bool {
	if ref, ok := get_string(s, "$ref"); ok {
		t, u, _, found := resolve(e.r, b, ref)
		if !found {
			return fail(e, "unresolvable $ref", ref)
		}
		if !eval(e, t, inst, u, my) {
			return false
		}
	}
	if ref, ok := get_string(s, "$recursiveRef"); ok && d == .Draft_2019_09 {
		t, u, _, found := resolve(e.r, b, ref)
		if !found {
			return fail(e, "unresolvable $recursiveRef", ref)
		}
		if ra, rok := get(t, "$recursiveAnchor"); rok && ra.kind == .Bool && ra.b {
			for i := len(e.scope) - 1; i >= 0; i -= 1 {
				root, has := e.r.docs[e.scope[i]]
				if !has {
					break
				}
				anchor, aok := get(root, "$recursiveAnchor")
				if !aok || anchor.kind != .Bool || !anchor.b {
					break
				}
				t = root
				u = e.scope[i]
			}
		}
		if !eval(e, t, inst, u, my) {
			return false
		}
	}
	if ref, ok := get_string(s, "$dynamicRef"); ok && d == .Draft_2020_12 {
		t, u, frag, found := resolve(e.r, b, ref)
		if !found {
			return fail(e, "unresolvable $dynamicRef", ref)
		}
		if frag != "" && frag[0] != '/' {
			if da, dok := get_string(t, "$dynamicAnchor"); dok && da == frag {
				for scope_uri in e.scope {
					key := strings.concatenate({scope_uri, "#", frag}, context.temp_allocator)
					if d, hit := e.r.dynamics[key]; hit {
						t = d
						break
					}
				}
			}
		}
		if !eval(e, t, inst, u, my) {
			return false
		}
	}
	return true
}

@(private)
eval_applicators :: proc(e: ^Eval, s: ^Value, inst: ^Value, b: string, my: ^Ann, d: Dialect) -> bool {
	if all, ok := get(s, "allOf"); ok && all.kind == .Array {
		for i in 0 ..< len(all.items) {
			if !eval(e, &all.items[i], inst, b, my) {
				return false
			}
		}
	}
	if anyv, ok := get(s, "anyOf"); ok && anyv.kind == .Array {
		hit := false
		e.quiet += 1
		for i in 0 ..< len(anyv.items) {
			sub := ann_make(inst)
			if eval(e, &anyv.items[i], inst, b, &sub) {
				hit = true
				ann_merge(my, &sub)
			}
		}
		e.quiet -= 1
		if !hit {
			return fail(e, "the value matches none of anyOf")
		}
	}
	if one, ok := get(s, "oneOf"); ok && one.kind == .Array {
		n := 0
		keep: Ann
		e.quiet += 1
		for i in 0 ..< len(one.items) {
			sub := ann_make(inst)
			if eval(e, &one.items[i], inst, b, &sub) {
				n += 1
				keep = sub
			}
		}
		e.quiet -= 1
		if n != 1 {
			return fail(e, "the value must match exactly one of oneOf")
		}
		ann_merge(my, &keep)
	}
	if not, ok := get(s, "not"); ok {
		e.quiet += 1
		m := eval(e, not, inst, b, nil)
		e.quiet -= 1
		if m {
			return fail(e, "the value must not match the not schema")
		}
	}
	if cond, ok := get(s, "if"); ok && d >= .Draft_07 {
		sub := ann_make(inst)
		e.quiet += 1
		m := eval(e, cond, inst, b, &sub)
		e.quiet -= 1
		if m {
			ann_merge(my, &sub)
			if th, tok := get(s, "then"); tok && !eval(e, th, inst, b, my) {
				return false
			}
		} else if el, eok := get(s, "else"); eok && !eval(e, el, inst, b, my) {
			return false
		}
	}
	#partial switch inst.kind {
	case .Object:
		return eval_object_applicators(e, s, inst, b, my, d)
	case .Array:
		return eval_array_applicators(e, s, inst, b, my, d)
	}
	return true
}

@(private)
eval_object_applicators :: proc(e: ^Eval, s: ^Value, inst: ^Value, b: string, my: ^Ann, d: Dialect) -> bool {
	if dep, ok := get(s, "dependencies"); ok && dep.kind == .Object {
		for k, i in dep.keys {
			if _, present := get(inst, k); !present {
				continue
			}
			d := &dep.vals[i]
			if d.kind == .Array {
				for j in 0 ..< len(d.items) {
					if d.items[j].kind == .String {
						if _, has := get(inst, d.items[j].s); !has {
							return fail(e, "a dependent property is missing:", d.items[j].s)
						}
					}
				}
			} else if !eval(e, d, inst, b, my) {
				return false
			}
		}
	}
	if ds, ok := get(s, "dependentSchemas"); ok && ds.kind == .Object && d >= .Draft_2019_09 {
		for k, i in ds.keys {
			if _, present := get(inst, k); present {
				if !eval(e, &ds.vals[i], inst, b, my) {
					return false
				}
			}
		}
	}
	props, has_props := get(s, "properties")
	pats, has_pats := get(s, "patternProperties")
	addl, has_addl := get(s, "additionalProperties")
	names, has_names := get(s, "propertyNames")
	if d < .Draft_06 {
		has_names = false
	}
	for key, i in inst.keys {
		mark := push_key(e, key)
		defer resize(&e.path, mark)
		if has_names {
			kv := Value {
				kind = .String,
				s    = key,
			}
			if !eval(e, names, &kv, b, nil) {
				return fail(e, "the property name is not allowed")
			}
		}
		matched := false
		if has_props && props.kind == .Object {
			if sub, sok := get(props, key); sok {
				matched = true
				if !eval(e, sub, &inst.vals[i], b, nil) {
					return false
				}
			}
		}
		if has_pats && pats.kind == .Object {
			for pk, pi in pats.keys {
				m, valid := matches(e, pk, key)
				if valid && m {
					matched = true
					if !eval(e, &pats.vals[pi], &inst.vals[i], b, nil) {
						return false
					}
				}
			}
		}
		if !matched && has_addl {
			if !eval(e, addl, &inst.vals[i], b, nil) {
				return fail(e, "the property is not allowed")
			}
			matched = true
		}
		if matched {
			my.props[i] = true
		}
	}
	return true
}

@(private)
eval_array_applicators :: proc(e: ^Eval, s: ^Value, inst: ^Value, b: string, my: ^Ann, d: Dialect) -> bool {
	prefix, has_prefix := get(s, "prefixItems")
	if d < .Draft_2020_12 {
		has_prefix = false
	}
	items, has_items := get(s, "items")
	start := 0
	if has_prefix && prefix.kind == .Array {
		for i in 0 ..< min(len(prefix.items), len(inst.items)) {
			mark := push_index(e, i)
			ok := eval(e, &prefix.items[i], &inst.items[i], b, nil)
			resize(&e.path, mark)
			if !ok {
				return false
			}
			my.items[i] = true
		}
		start = len(prefix.items)
	}
	if has_items {
		if items.kind == .Array {
			for i in 0 ..< min(len(items.items), len(inst.items)) {
				mark := push_index(e, i)
				ok := eval(e, &items.items[i], &inst.items[i], b, nil)
				resize(&e.path, mark)
				if !ok {
					return false
				}
				my.items[i] = true
			}
			if addl, aok := get(s, "additionalItems"); aok && d <= .Draft_2019_09 {
				for i in len(items.items) ..< len(inst.items) {
					mark := push_index(e, i)
					ok := eval(e, addl, &inst.items[i], b, nil)
					resize(&e.path, mark)
					if !ok {
						return false
					}
					my.items[i] = true
				}
			}
		} else {
			for i in start ..< len(inst.items) {
				mark := push_index(e, i)
				ok := eval(e, items, &inst.items[i], b, nil)
				resize(&e.path, mark)
				if !ok {
					return false
				}
				my.items[i] = true
			}
		}
	}
	if contains, ok := get(s, "contains"); ok && d >= .Draft_06 {
		hits := 0
		e.quiet += 1
		for i in 0 ..< len(inst.items) {
			if eval(e, contains, &inst.items[i], b, nil) {
				hits += 1
				my.items[i] = true
			}
		}
		e.quiet -= 1
		lo := 1
		vocab := e.r.vocab_of[s] if s in e.r.vocab_of else VOCAB_DEFAULT
		if .Validation in vocab && d >= .Draft_2019_09 {
			if v, mok := get(s, "minContains"); mok && v.kind == .Number {
				lo = int(v.n)
			}
			if v, mok := get(s, "maxContains"); mok && v.kind == .Number && f64(hits) > v.n {
				return fail(e, "the array contains too many matching items")
			}
		}
		if hits < lo {
			return fail(e, "the array does not contain enough matching items")
		}
	}
	return true
}

@(private)
eval_unevaluated :: proc(e: ^Eval, s: ^Value, inst: ^Value, b: string, my: ^Ann) -> bool {
	if up, ok := get(s, "unevaluatedProperties"); ok && inst.kind == .Object {
		for key, i in inst.keys {
			if my.props[i] {
				continue
			}
			mark := push_key(e, key)
			ok2 := eval(e, up, &inst.vals[i], b, nil)
			resize(&e.path, mark)
			if !ok2 {
				return fail(e, "the property is not allowed (unevaluatedProperties)", key)
			}
			my.props[i] = true
		}
	}
	if ui, ok := get(s, "unevaluatedItems"); ok && inst.kind == .Array {
		for i in 0 ..< len(inst.items) {
			if my.items[i] {
				continue
			}
			mark := push_index(e, i)
			ok2 := eval(e, ui, &inst.items[i], b, nil)
			resize(&e.path, mark)
			if !ok2 {
				return fail(e, "the item is not allowed (unevaluatedItems)")
			}
			my.items[i] = true
		}
	}
	return true
}

@(private)
type_ok :: proc(name: string, inst: ^Value, d: Dialect) -> bool {
	switch name {
	case "null":
		return inst.kind == .Null
	case "boolean":
		return inst.kind == .Bool
	case "object":
		return inst.kind == .Object
	case "array":
		return inst.kind == .Array
	case "string":
		return inst.kind == .String
	case "number":
		return inst.kind == .Number
	case "integer":
		if d == .Draft_04 && inst.frac {
			return false
		}
		return inst.kind == .Number && !math.is_inf(inst.n) && inst.n == math.trunc(inst.n)
	}
	return false
}

@(private)
num :: proc "contextless" (s: ^Value, key: string) -> (f64, bool) {
	v, ok := get(s, key)
	if !ok || v.kind != .Number {
		return 0, false
	}
	return v.n, true
}

@(private)
eval_validation :: proc(e: ^Eval, s: ^Value, inst: ^Value, d: Dialect) -> bool {
	if t, ok := get(s, "type"); ok {
		good := false
		if t.kind == .String {
			good = type_ok(t.s, inst, d)
		} else if t.kind == .Array {
			for i in 0 ..< len(t.items) {
				if t.items[i].kind == .String && type_ok(t.items[i].s, inst, d) {
					good = true
					break
				}
			}
		} else {
			good = true
		}
		if !good {
			return fail(e, "the value has the wrong type")
		}
	}
	if en, ok := get(s, "enum"); ok && en.kind == .Array {
		hit := false
		for i in 0 ..< len(en.items) {
			if equal(&en.items[i], inst) {
				hit = true
				break
			}
		}
		if !hit {
			return fail(e, "the value is not one of the allowed values")
		}
	}
	if c, ok := get(s, "const"); ok && d >= .Draft_06 && !equal(c, inst) {
		return fail(e, "the value does not equal the constant")
	}
	#partial switch inst.kind {
	case .Number:
		x := inst.n
		if m, ok := num(s, "multipleOf"); ok && m > 0 {
			q := x / m
			inv := 1 / m
			overflow_ok := math.is_inf(q) && x == math.trunc(x) && inv == math.trunc(inv)
			if !overflow_ok && (math.is_inf(q) || math.abs(q - math.round(q)) > 1e-9 * max(1, math.abs(q))) {
				return fail(e, "the number is not a multiple of multipleOf")
			}
		}
		if d == .Draft_04 {
			ex_max := false
			ex_min := false
			if v, ok := get(s, "exclusiveMaximum"); ok && v.kind == .Bool {
				ex_max = v.b
			}
			if v, ok := get(s, "exclusiveMinimum"); ok && v.kind == .Bool {
				ex_min = v.b
			}
			if m, ok := num(s, "maximum"); ok && (x > m || (ex_max && x == m)) {
				return fail(e, "the number is above maximum")
			}
			if m, ok := num(s, "minimum"); ok && (x < m || (ex_min && x == m)) {
				return fail(e, "the number is below minimum")
			}
		} else {
			if m, ok := num(s, "maximum"); ok && x > m {
				return fail(e, "the number is above maximum")
			}
			if m, ok := num(s, "exclusiveMaximum"); ok && x >= m {
				return fail(e, "the number is not below exclusiveMaximum")
			}
			if m, ok := num(s, "minimum"); ok && x < m {
				return fail(e, "the number is below minimum")
			}
			if m, ok := num(s, "exclusiveMinimum"); ok && x <= m {
				return fail(e, "the number is not above exclusiveMinimum")
			}
		}
	case .String:
		n := f64(utf8.rune_count_in_string(inst.s))
		if m, ok := num(s, "maxLength"); ok && n > m {
			return fail(e, "the string is longer than maxLength")
		}
		if m, ok := num(s, "minLength"); ok && n < m {
			return fail(e, "the string is shorter than minLength")
		}
		if p, ok := get_string(s, "pattern"); ok {
			m, valid := matches(e, p, inst.s)
			if valid && !m {
				return fail(e, "the string does not match pattern", p)
			}
		}
	case .Array:
		n := f64(len(inst.items))
		if m, ok := num(s, "maxItems"); ok && n > m {
			return fail(e, "the array has more than maxItems")
		}
		if m, ok := num(s, "minItems"); ok && n < m {
			return fail(e, "the array has fewer than minItems")
		}
		if u, ok := get(s, "uniqueItems"); ok && u.kind == .Bool && u.b {
			for i in 0 ..< len(inst.items) {
				for j in i + 1 ..< len(inst.items) {
					if equal(&inst.items[i], &inst.items[j]) {
						return fail(e, "the array items are not unique")
					}
				}
			}
		}
	case .Object:
		n := f64(len(inst.keys))
		if m, ok := num(s, "maxProperties"); ok && n > m {
			return fail(e, "the object has more than maxProperties")
		}
		if m, ok := num(s, "minProperties"); ok && n < m {
			return fail(e, "the object has fewer than minProperties")
		}
		if req, ok := get(s, "required"); ok && req.kind == .Array {
			for i in 0 ..< len(req.items) {
				if req.items[i].kind != .String {
					continue
				}
				if _, has := get(inst, req.items[i].s); !has {
					return fail(e, "a required property is missing:", req.items[i].s)
				}
			}
		}
		if dr, ok := get(s, "dependentRequired"); ok && dr.kind == .Object && d >= .Draft_2019_09 {
			for k, i in dr.keys {
				if _, present := get(inst, k); !present {
					continue
				}
				deps := &dr.vals[i]
				if deps.kind != .Array {
					continue
				}
				for j in 0 ..< len(deps.items) {
					if deps.items[j].kind == .String {
						if _, has := get(inst, deps.items[j].s); !has {
							return fail(e, "a dependent property is missing:", deps.items[j].s)
						}
					}
				}
			}
		}
	}
	return true
}
