package engine

import "base:runtime"
import omap "../map"
import "../prim"

DEF_KEY :: "def"

Workspace_Tag :: enum u32 {
	Name          = 1,
	Agent         = 2,
	Provider      = 3,
	Model         = 4,
	Runner_Policy = 5,
	Setup         = 6,
	Access        = 7,
	Members       = 16,
	Linked        = 17,
}

Member_Role :: enum u8 {
	Tree     = 1,
	Document = 2,
	Memory   = 3,
}

Workspace_Member :: struct {
	object: prim.Id,
	kind:   Kind,
	role:   Member_Role,
	mount:  string,
	path:   string,
}

Workspace_Def :: struct {
	name:          string,
	agent:         prim.Id,
	provider:      string,
	model:         string,
	runner_policy: []u8,
	setup:         string,
	access:        []u8,
	members:       []Workspace_Member,
	linked:        []string,
}

Agent_Tag :: enum u32 {
	Name          = 1,
	Instructions  = 2,
	Driver        = 3,
	Provider      = 4,
	Model         = 5,
	Options       = 6,
	Budget        = 7,
	Workspace     = 8,
	Runner_Policy = 9,
	Tools         = 16,
	Memory        = 17,
	Triggers      = 18,
}

Agent_Def :: struct {
	name:          string,
	instructions:  string,
	driver:        string,
	provider:      string,
	model:         string,
	options:       []u8,
	budget:        []u8,
	workspace:     prim.Id,
	runner_policy: []u8,
	tools:         [][]u8,
	memory:        []prim.Id,
	triggers:      [][]u8,
}

workspace_create :: proc(e: ^Engine, space: prim.Id, def: Workspace_Def) -> (o: Object, err: Error) {
	context = context_for(e)
	o = map_create(e, space, def.name) or_return
	workspace_set(e, o, def) or_return
	for m in def.members {
		workspace_add_member(e, o, m) or_return
	}
	for l in def.linked {
		_, aerr := map_add(e, o, transmute([]u8)string(DEF_KEY), u32(Workspace_Tag.Linked), transmute([]u8)l)
		aerr_ok(aerr) or_return
	}
	return o, .None
}

workspace_set :: proc(e: ^Engine, o: Object, def: Workspace_Def) -> Error {
	context = context_for(e)
	f := make([dynamic]omap.Field, context.temp_allocator)
	append(&f, omap.field_str(u32(Workspace_Tag.Name), def.name))
	append(&f, omap.field_id(u32(Workspace_Tag.Agent), def.agent))
	append(&f, omap.field_str(u32(Workspace_Tag.Provider), def.provider))
	append(&f, omap.field_str(u32(Workspace_Tag.Model), def.model))
	append(&f, omap.Field{tag = u32(Workspace_Tag.Runner_Policy), value = def.runner_policy})
	append(&f, omap.field_str(u32(Workspace_Tag.Setup), def.setup))
	append(&f, omap.Field{tag = u32(Workspace_Tag.Access), value = def.access})
	_, err := map_set(e, o, transmute([]u8)string(DEF_KEY), f[:])
	aerr_ok(err) or_return
	if len(def.name) > 0 {
		aerr_ok(catalog_set(e, Cmd_Catalog_Set{object = o, set = {.Title}, title = def.name})) or_return
	}
	return .None
}

workspace_add_member :: proc(e: ^Engine, o: Object, m: Workspace_Member) -> Error {
	context = context_for(e)
	b := _member_encode(m)
	_, err := map_add(e, o, transmute([]u8)string(DEF_KEY), u32(Workspace_Tag.Members), b)
	return aerr_ok(err)
}

workspace_remove_member :: proc(e: ^Engine, o: Object, m: Workspace_Member) -> Error {
	context = context_for(e)
	return aerr_ok(map_remove(e, o, transmute([]u8)string(DEF_KEY), u32(Workspace_Tag.Members), _member_encode(m)))
}

workspace_get :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (def: Workspace_Def, err: Error) {
	context = context_for(e)
	en, found := map_get(e, o, transmute([]u8)string(DEF_KEY), context.temp_allocator, ready) or_return
	if !found {
		return def, .Not_Found
	}
	def.name = _reg_str(&en, u32(Workspace_Tag.Name), allocator) or_return
	if v, ok := omap.entry_register(&en, u32(Workspace_Tag.Agent)); ok {
		def.agent, _ = omap.value_id(v)
	}
	def.provider = _reg_str(&en, u32(Workspace_Tag.Provider), allocator) or_return
	def.model = _reg_str(&en, u32(Workspace_Tag.Model), allocator) or_return
	def.runner_policy = _reg_bytes(&en, u32(Workspace_Tag.Runner_Policy), allocator) or_return
	def.setup = _reg_str(&en, u32(Workspace_Tag.Setup), allocator) or_return
	def.access = _reg_bytes(&en, u32(Workspace_Tag.Access), allocator) or_return
	members := make([dynamic]Workspace_Member, allocator)
	for el in omap.entry_elements(&en, u32(Workspace_Tag.Members)) {
		if m, ok := _member_decode(el, allocator); ok {
			append(&members, m)
		}
	}
	def.members = members[:]
	linked := make([dynamic]string, allocator)
	for el in omap.entry_elements(&en, u32(Workspace_Tag.Linked)) {
		append(&linked, _clone(string(el), allocator) or_return)
	}
	def.linked = linked[:]
	return def, .None
}

agent_create :: proc(e: ^Engine, space: prim.Id, def: Agent_Def) -> (o: Object, err: Error) {
	context = context_for(e)
	o = map_create(e, space, def.name) or_return
	agent_set(e, o, def) or_return
	for t in def.tools {
		agent_add(e, o, .Tools, t) or_return
	}
	for m in def.memory {
		x := m
		agent_add(e, o, .Memory, x[:]) or_return
	}
	for t in def.triggers {
		agent_add(e, o, .Triggers, t) or_return
	}
	return o, .None
}

agent_set :: proc(e: ^Engine, o: Object, def: Agent_Def) -> Error {
	context = context_for(e)
	f := make([dynamic]omap.Field, context.temp_allocator)
	append(&f, omap.field_str(u32(Agent_Tag.Name), def.name))
	append(&f, omap.field_str(u32(Agent_Tag.Instructions), def.instructions))
	append(&f, omap.field_str(u32(Agent_Tag.Driver), def.driver))
	append(&f, omap.field_str(u32(Agent_Tag.Provider), def.provider))
	append(&f, omap.field_str(u32(Agent_Tag.Model), def.model))
	append(&f, omap.Field{tag = u32(Agent_Tag.Options), value = def.options})
	append(&f, omap.Field{tag = u32(Agent_Tag.Budget), value = def.budget})
	append(&f, omap.field_id(u32(Agent_Tag.Workspace), def.workspace))
	append(&f, omap.Field{tag = u32(Agent_Tag.Runner_Policy), value = def.runner_policy})
	_, err := map_set(e, o, transmute([]u8)string(DEF_KEY), f[:])
	aerr_ok(err) or_return
	if len(def.name) > 0 {
		aerr_ok(catalog_set(e, Cmd_Catalog_Set{object = o, set = {.Title}, title = def.name})) or_return
	}
	return .None
}

agent_add :: proc(e: ^Engine, o: Object, tag: Agent_Tag, element: []u8) -> Error {
	context = context_for(e)
	_, err := map_add(e, o, transmute([]u8)string(DEF_KEY), u32(tag), element)
	return aerr_ok(err)
}

agent_remove :: proc(e: ^Engine, o: Object, tag: Agent_Tag, element: []u8) -> Error {
	context = context_for(e)
	return aerr_ok(map_remove(e, o, transmute([]u8)string(DEF_KEY), u32(tag), element))
}

agent_get :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (def: Agent_Def, err: Error) {
	context = context_for(e)
	en, found := map_get(e, o, transmute([]u8)string(DEF_KEY), context.temp_allocator, ready) or_return
	if !found {
		return def, .Not_Found
	}
	def.name = _reg_str(&en, u32(Agent_Tag.Name), allocator) or_return
	def.instructions = _reg_str(&en, u32(Agent_Tag.Instructions), allocator) or_return
	def.driver = _reg_str(&en, u32(Agent_Tag.Driver), allocator) or_return
	def.provider = _reg_str(&en, u32(Agent_Tag.Provider), allocator) or_return
	def.model = _reg_str(&en, u32(Agent_Tag.Model), allocator) or_return
	def.options = _reg_bytes(&en, u32(Agent_Tag.Options), allocator) or_return
	def.budget = _reg_bytes(&en, u32(Agent_Tag.Budget), allocator) or_return
	if v, ok := omap.entry_register(&en, u32(Agent_Tag.Workspace)); ok {
		def.workspace, _ = omap.value_id(v)
	}
	def.runner_policy = _reg_bytes(&en, u32(Agent_Tag.Runner_Policy), allocator) or_return
	def.tools = _elements(&en, u32(Agent_Tag.Tools), allocator) or_return
	def.triggers = _elements(&en, u32(Agent_Tag.Triggers), allocator) or_return
	mem := make([dynamic]prim.Id, allocator)
	for el in omap.entry_elements(&en, u32(Agent_Tag.Memory)) {
		if id, ok := omap.value_id(el); ok {
			append(&mem, id)
		}
	}
	def.memory = mem[:]
	return def, .None
}

@(private)
aerr_ok :: proc "contextless" (err: Error) -> Error {
	if err == .Pending {
		return .None
	}
	return err
}

@(private)
_reg_str :: proc(en: ^omap.Entry, tag: u32, allocator: runtime.Allocator) -> (string, Error) {
	if v, ok := omap.entry_register(en, tag); ok {
		return _clone(string(v), allocator)
	}
	return "", .None
}

@(private)
_reg_bytes :: proc(en: ^omap.Entry, tag: u32, allocator: runtime.Allocator) -> ([]u8, Error) {
	if v, ok := omap.entry_register(en, tag); ok {
		return _clone_bytes(v, allocator)
	}
	return nil, .None
}

@(private)
_elements :: proc(en: ^omap.Entry, tag: u32, allocator: runtime.Allocator) -> (out: [][]u8, err: Error) {
	list := make([dynamic][]u8, allocator)
	for el in omap.entry_elements(en, tag) {
		append(&list, _clone_bytes(el, allocator) or_return)
	}
	return list[:], .None
}

@(private)
_member_encode :: proc(m: Workspace_Member) -> []u8 {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_id(&w, m.object)
	prim.write_u8(&w, u8(m.kind))
	prim.write_u8(&w, u8(m.role))
	prim.write_str(&w, m.mount)
	prim.write_str(&w, m.path)
	return buf[:]
}

@(private)
_member_decode :: proc(b: []u8, allocator: runtime.Allocator) -> (m: Workspace_Member, ok: bool) {
	r := prim.reader(b)
	m.object = prim.read_id(&r)
	k := prim.read_u8(&r)
	role := prim.read_u8(&r)
	mount := prim.read_str(&r)
	path := prim.read_str(&r)
	if !prim.reader_done(&r) || k < 1 || k > u8(max(Kind)) || role < 1 || role > u8(max(Member_Role)) {
		return {}, false
	}
	m.kind = Kind(k)
	m.role = Member_Role(role)
	m.mount, _ = _clone(mount, allocator)
	m.path, _ = _clone(path, allocator)
	return m, true
}
