package agent

import "core:mem"
import "../prim"
import "core:strings"

Provider :: enum u8 {
	Claude,
	Codex,
	Pi,
	Muse,
	Antigravity,
	Cursor,
	Devin,
	Hermes,
	OpenCode,
}

Access :: enum u8 {
	Plan,
	Edit,
	Full,
}

Capability :: enum u8 {
	Native_Steer,
	Resume,
	Fork_At_Message,
	Persistent,
	List_Models,
	Images,
	Files,
}

Capabilities :: bit_set[Capability;u8]

Decision :: enum u8 {
	Allow,
	Allow_Always,
	Deny,
}

Turn_Status :: enum u8 {
	Done,
	Interrupted,
}

Notice_Level :: enum u8 {
	Info,
	Warning,
	Error,
}

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Descriptor,
}

Rewind_Path :: enum u8 {
	Fresh,
	Native,
	Native_Undo,
	Seeded,
}

Seed_Role :: enum u8 {
	User,
	Assistant,
	Tool,
}

Seed_Entry :: struct {
	role:     Seed_Role,
	text:     string,
	tool:     string,
	input:    string,
	is_error: bool,
}

Rewind_Target :: struct {
	session: string,
	after:   string,
	before:  string,
	head:    string,
	seed:    []Seed_Entry,
}

Attachment :: struct {
	path: string,
	name: string,
	mime: string,
	data: []u8,
}

Start_Request :: struct {
	cwd:             string,
	model:           string,
	effort:          string,
	program:         string,
	access:          Access,
	ask_permissions: bool,
	resume:          string,
	checkpoint:      string,
	rewind:          Rewind_Target,
	seed_budget:     int,
	mcp:             []Mcp_Server,
	scratch:         string,
	clock:           prim.Clock,
	random:          prim.Random,
	seed:            []Seed_Entry,
	env:             []string,
}

Mcp_Server :: struct {
	name:    string,
	command: string,
	args:    []string,
	env:     []string,
	url:     string,
	headers: []string,
}

Launch_File :: struct {
	path: string,
	data: []u8,
}

Launch :: struct {
	argv:    []string,
	env:     []string,
	cwd:     string,
	stdin:   []u8,
	files:   []Launch_File,
	prompts: []string,
}

Model :: struct {
	id:         string,
	name:       string,
	is_default: bool,
}

Session_Started :: struct {
	session: string,
}

Session_Failed :: struct {
	message: string,
}

Turn_Started :: struct {
	id: string,
}

Prompt_Accepted :: struct {
	id:        string,
	native_id: string,
	steer:     bool,
}

Prompt_Dropped :: struct {
	id: string,
}

Message_Started :: struct {
	native_id: string,
}

Text_Delta :: struct {
	text: string,
}

Reasoning_Delta :: struct {
	text: string,
}

Tool_Started :: struct {
	id:     string,
	name:   string,
	input:  string,
	parent: string,
}

Tool_Updated :: struct {
	id:     string,
	input:  string,
	output: string,
	append: bool,
	parent: string,
}

Tool_Finished :: struct {
	id:       string,
	output:   string,
	is_error: bool,
	parent:   string,
}

Permission_Request :: struct {
	id:       string,
	tool:     string,
	title:    string,
	input:    string,
	answered: bool,
}

Usage :: struct {
	input_tokens:       u64,
	output_tokens:      u64,
	cache_read_tokens:  u64,
	cache_write_tokens: u64,
	reasoning_tokens:   u64,
	context_tokens:     u64,
	context_window:     u64,
	cost_usd:           f64,
}

Turn_Finished :: struct {
	status:     Turn_Status,
	checkpoint: string,
}

Turn_Failed :: struct {
	message:    string,
	checkpoint: string,
}

Rewind_Failed :: struct {
	message: string,
}

Rewound :: struct {
	session: string,
	path:    Rewind_Path,
}

Models :: struct {
	models: []Model,
}

Notice :: struct {
	level: Notice_Level,
	text:  string,
}

Event :: union {
	Session_Started,
	Session_Failed,
	Turn_Started,
	Prompt_Accepted,
	Prompt_Dropped,
	Message_Started,
	Text_Delta,
	Reasoning_Delta,
	Tool_Started,
	Tool_Updated,
	Tool_Finished,
	Permission_Request,
	Usage,
	Turn_Finished,
	Turn_Failed,
	Rewind_Failed,
	Rewound,
	Models,
	Notice,
}

Output :: struct {
	events:      [dynamic]Event,
	bytes:       [dynamic]u8,
	prompts:     [dynamic]string,
	restart:     bool,
	close_stdin: bool,
	allocator:   mem.Allocator,
}

@(private)
Request :: enum u8 {
	Other,
	Initialize,
	Open,
	Turn,
	Steer,
	Steer_Command,
	Interrupt,
	Cancel_Queued,
	Models,
	Model_State,
	Configure,
	Entries,
	Entries_Turn,
	State,
	Fork,
	Switch,
	Rewind_Lookup,
	Clear_Queue,
	Undo,
	Revert_Steps,
	Revert_Fork,
}

@(private)
Pending :: struct {
	id:   i64,
	kind: Request,
	ref:  string,
}

@(private)
Prompt :: struct {
	id:    string,
	cmd:   string,
	text:  string,
	files: []Attachment,
	steer: bool,
	sent:  bool,
}

@(private)
Perm :: struct {
	id:           string,
	raw_id:       string,
	kind:         string,
	allow:        string,
	allow_always: string,
	deny:         string,
	extra:        string,
}

@(private)
Acp_Steer :: enum u8 {
	Cancel,
	Concurrent,
	Supersede,
	Command,
}

Driver :: struct {
	desc:        Provider_Descriptor,
	native_path: string,
	allocator:   mem.Allocator,
	req:         Start_Request,
	session:     string,
	checkpoint:  string,
	turn:        string,
	running:     bool,
	ready:       bool,
	next_id:     i64,
	pending:     [dynamic]Pending,
	prompts:     [dynamic]Prompt,
	perms:       [dynamic]Perm,
	models:      [dynamic]Model,
	usage:       Usage,
	has_usage:   bool,
	last_error:  string,
	stream_item: string,
	reason_item: string,
	streamed:    bool,
	interrupted: bool,
	replaying:   bool,
	can_load:    bool,
	can_resume:  bool,
	can_fork:    bool,
	can_close:   bool,
	steer_mode:  Acp_Steer,
	in_flight:   int,
	model_opt:   string,
	set_model:   bool,
	seed:        string,
	seed_for:    string,
	fallback:    string,
	rewinding:   bool,
	rewind_path: Rewind_Path,
	turns:       int,
	can_image:   bool,
	can_embed:   bool,
	can_revert:  bool,
	has_undo:    bool,
	cost_base:   f64,
	cost_seen:   f64,
	undo:        int,
	can_http:    bool,
}

capabilities :: proc(p: Provider) -> Capabilities {
	return builtin(p).capabilities
}

provider_name :: proc(p: Provider) -> string {
	switch p {
	case .Claude:
		return "claude"
	case .Codex:
		return "codex"
	case .Pi:
		return "pi"
	case .Muse:
		return "muse"
	case .Antigravity:
		return "antigravity"
	case .Cursor:
		return "cursor"
	case .Devin:
		return "devin"
	case .Hermes:
		return "hermes"
	case .OpenCode:
		return "opencode"
	}
	return ""
}

provider_from_name :: proc(name: string) -> (Provider, bool) {
	for p in Provider {
		if provider_name(p) == name {
			return p, true
		}
	}
	switch name {
	case "claude-code":
		return .Claude, true
	case "open-code":
		return .OpenCode, true
	case "agy":
		return .Antigravity, true
	case "cursor-agent":
		return .Cursor, true
	}
	return .Claude, false
}

init :: proc(d: ^Driver, provider: Provider, req: Start_Request, allocator := context.allocator) -> Error {
	return init_with(d, builtin(provider), req, allocator)
}

init_with :: proc(d: ^Driver, desc: Provider_Descriptor, req: Start_Request, allocator := context.allocator) -> Error {
	d^ = {}
	if desc.id == "" || len(desc.argv) == 0 {
		return .Invalid_Descriptor
	}
	owned, derr := clone_descriptor(desc, allocator)
	if derr != .None {
		return derr
	}
	d.desc = owned
	d.allocator = allocator
	d.next_id = 1
	d.pending = make([dynamic]Pending, allocator)
	d.prompts = make([dynamic]Prompt, allocator)
	d.perms = make([dynamic]Perm, allocator)
	d.models = make([dynamic]Model, allocator)
	r := req
	r.cwd = own(d, req.cwd)
	r.model = own(d, req.model)
	r.effort = own(d, req.effort)
	r.program = own(d, req.program)
	r.resume = own(d, req.resume)
	r.checkpoint = own(d, req.checkpoint)
	r.rewind = own_target(d, req.rewind)
	r.scratch = own(d, req.scratch)
	r.seed = nil
	if len(req.mcp) > 0 {
		servers, merr := make([]Mcp_Server, len(req.mcp), allocator)
		if merr != nil {
			return .Out_Of_Memory
		}
		for m, i in req.mcp {
			servers[i] = Mcp_Server {
				name    = own(d, m.name),
				command = own(d, m.command),
				url     = own(d, m.url),
			}
			servers[i].args, _ = clone_strings(m.args, allocator)
			servers[i].env, _ = clone_strings(m.env, allocator)
			servers[i].headers, _ = clone_strings(m.headers, allocator)
		}
		r.mcp = servers
	}
	env, err := make([]string, len(req.env), allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	for e, i in req.env {
		env[i] = own(d, e)
	}
	r.env = env
	d.req = r
	d.checkpoint = own(d, req.checkpoint)
	d.turns = checkpoint_turns(req.checkpoint)
	if req.rewind.session != "" {
		begin_rewind(d, req.rewind.seed)
	} else if len(req.seed) > 0 && req.resume == "" {
		set(d, &d.seed, render_seed(d.desc, req.seed, req.seed_budget, context.temp_allocator))
		d.rewinding = true
		d.rewind_path = .Seeded
	}
	return .None
}

session_path :: proc(d: ^Driver) -> string {
	return d.native_path
}

destroy :: proc(d: ^Driver) {
	a := d.allocator
	delete(d.req.cwd, a)
	delete(d.req.model, a)
	delete(d.req.effort, a)
	delete(d.req.program, a)
	delete(d.req.resume, a)
	delete(d.req.checkpoint, a)
	drop_target(d, &d.req.rewind)
	delete(d.req.scratch, a)
	for m in d.req.mcp {
		delete(m.name, a)
		delete(m.command, a)
		delete(m.url, a)
		drop_strings(m.args, a)
		drop_strings(m.env, a)
		drop_strings(m.headers, a)
	}
	delete(d.req.mcp, a)
	for e in d.req.env {
		delete(e, a)
	}
	delete(d.req.env, a)
	delete(d.session, a)
	delete(d.checkpoint, a)
	delete(d.turn, a)
	delete(d.last_error, a)
	delete(d.stream_item, a)
	delete(d.reason_item, a)
	delete(d.model_opt, a)
	delete(d.native_path, a)
	drop_descriptor(&d.desc, a)
	delete(d.seed, a)
	delete(d.seed_for, a)
	delete(d.fallback, a)
	clear_pending(d)
	delete(d.pending)
	clear_prompts(d)
	delete(d.prompts)
	for &p in d.perms {
		drop_perm(d, &p)
	}
	delete(d.perms)
	clear_models(d)
	delete(d.models)
	d^ = {}
}

launch :: proc(d: ^Driver, allocator := context.temp_allocator) -> Launch {
	clear_pending(d)
	for &p in d.perms {
		drop_perm(d, &p)
	}
	clear(&d.perms)
	for &p in d.prompts {
		p.sent = false
	}
	d.running = false
	d.ready = false
	d.replaying = false
	d.in_flight = 0
	d.interrupted = false
	d.has_usage = false
	d.usage = {}
	argv := make([dynamic]string, allocator)
	b := make([dynamic]u8, allocator)
	files := make([dynamic]Launch_File, allocator)
	unsent := make([dynamic]bool, 0, len(d.prompts), context.temp_allocator)
	for p in d.prompts {
		append(&unsent, !p.sent)
	}
	switch d.desc.protocol {
	case .Claude_Stream_Json:
		claude_launch(d, &argv, &b)
	case .Codex_App_Server:
		codex_launch(d, &argv, &b)
	case .Pi_Rpc:
		pi_launch(d, &argv, &b, &files)
	case .Muse:
		muse_launch(d, &argv, &b)
	case .Acp:
		acp_launch(d, &argv, &b)
	}
	env := make([dynamic]string, allocator)
	append(&env, ..d.desc.env)
	append(&env, ..d.req.env)
	prompts := make([dynamic]string, allocator)
	for p, i in d.prompts {
		if i < len(unsent) && unsent[i] && p.sent {
			append(&prompts, strings.clone(p.id, allocator))
		}
	}
	return Launch{argv = argv[:], env = env[:], cwd = d.req.cwd, stdin = b[:], files = files[:], prompts = prompts[:]}
}

feed :: proc(d: ^Driver, line: []u8, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	text := strings.trim_space(string(line))
	if len(text) == 0 {
		return o
	}
	v, ok := parse_line(line)
	if !ok {
		notice(&o, .Warning, text)
		return o
	}
	switch d.desc.protocol {
	case .Claude_Stream_Json:
		claude_feed(d, v, &o)
	case .Codex_App_Server:
		codex_feed(d, v, &o)
	case .Pi_Rpc:
		pi_feed(d, v, &o)
	case .Muse:
		muse_feed(d, v, &o)
	case .Acp:
		acp_feed(d, v, &o)
	}
	return o
}

send :: proc(d: ^Driver, text: string, id := "", files: []Attachment = nil, allocator := context.temp_allocator) -> Output {
	return submit(d, text, id, files, false, allocator)
}

steer :: proc(d: ^Driver, text: string, id := "", files: []Attachment = nil, allocator := context.temp_allocator) -> Output {
	return submit(d, text, id, files, true, allocator)
}

@(private)
submit :: proc(d: ^Driver, text, id: string, files: []Attachment, steer: bool, allocator: mem.Allocator) -> Output {
	o := output(allocator)
	pid := id != "" ? id : new_uuid(d)
	body := text
	if d.seed != "" && d.seed_for == "" {
		body = strings.concatenate({d.seed, "\n\n", text}, context.temp_allocator)
		set(d, &d.seed_for, pid)
	}
	add_prompt(d, pid, body, steer, false, "", files)
	p := &d.prompts[len(d.prompts) - 1]
	switch d.desc.protocol {
	case .Claude_Stream_Json:
		claude_submit(d, p, &o)
	case .Codex_App_Server:
		codex_submit(d, p, &o)
	case .Pi_Rpc:
		pi_submit(d, p, &o)
	case .Muse:
		muse_submit(d, p, &o)
	case .Acp:
		acp_submit(d, p, &o)
	}
	return o
}

interrupt :: proc(d: ^Driver, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	switch d.desc.protocol {
	case .Claude_Stream_Json:
		claude_interrupt(d, &o)
	case .Codex_App_Server:
		codex_interrupt(d, &o)
	case .Pi_Rpc:
		pi_interrupt(d, &o)
	case .Muse:
		muse_interrupt(d, &o)
	case .Acp:
		acp_interrupt(d, &o)
	}
	return o
}

rewind :: proc(d: ^Driver, target: Rewind_Target, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	if d.running {
		emit(&o, Rewind_Failed{message = dup(&o, "a turn is running")})
		return o
	}
	drop_target(d, &d.req.rewind)
	d.req.rewind = own_target(d, target)
	if d.req.rewind.session == "" {
		set(d, &d.req.rewind.session, d.session)
	}
	if d.req.rewind.head == "" && d.req.rewind.session == d.session {
		set(d, &d.req.rewind.head, d.checkpoint)
	}
	begin_rewind(d, target.seed)
	switch d.desc.protocol {
	case .Claude_Stream_Json:
		claude_rewind(d, &o)
	case .Codex_App_Server:
		codex_rewind(d, &o)
	case .Pi_Rpc:
		pi_rewind(d, &o)
	case .Muse:
		muse_rewind(d, &o)
	case .Acp:
		acp_rewind(d, &o)
	}
	return o
}

answer_permission :: proc(d: ^Driver, id: string, decision: Decision, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	for &p, i in d.perms {
		if p.id != id {
			continue
		}
		switch d.desc.protocol {
		case .Claude_Stream_Json:
			claude_answer(d, &p, decision, &o)
		case .Codex_App_Server:
			codex_answer(d, &p, decision, &o)
		case .Pi_Rpc:
			pi_answer(d, &p, decision, &o)
		case .Muse:
			muse_answer(d, &p, decision, &o)
		case .Acp:
			acp_answer(d, &p, decision, &o)
		}
		drop_perm(d, &p)
		ordered_remove(&d.perms, i)
		return o
	}
	notice(&o, .Warning, "no pending permission request with that id")
	return o
}

list_models :: proc(d: ^Driver, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	switch d.desc.protocol {
	case .Claude_Stream_Json:
		claude_list_models(d, &o)
	case .Codex_App_Server:
		codex_list_models(d, &o)
	case .Pi_Rpc:
		pi_list_models(d, &o)
	case .Muse:
		muse_list_models(d, &o)
	case .Acp:
		acp_list_models(d, &o)
	}
	return o
}

close :: proc(d: ^Driver, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	if d.desc.protocol == .Acp {
		acp_close(d, &o)
	}
	o.close_stdin = true
	return o
}

process_exited :: proc(d: ^Driver, message: string, allocator := context.temp_allocator) -> Output {
	o := output(allocator)
	if d.running {
		msg := message != "" ? message : "the agent process exited"
		fail_turn(d, &o, msg)
	}
	for p in d.prompts {
		emit(&o, Prompt_Dropped{id = dup(&o, p.id)})
	}
	clear_prompts(d)
	clear_pending(d)
	set(d, &d.seed_for, "")
	for &p in d.perms {
		drop_perm(d, &p)
	}
	clear(&d.perms)
	d.ready = false
	d.running = false
	d.in_flight = 0
	if d.desc.protocol == .Claude_Stream_Json && d.rewinding && d.req.rewind.after != "" && take_fallback(d) {
		drop_target(d, &d.req.rewind)
		set(d, &d.req.resume, "")
		o.restart = true
	}
	return o
}

@(private)
output :: proc(allocator: mem.Allocator) -> Output {
	return Output {
		events = make([dynamic]Event, allocator),
		bytes = make([dynamic]u8, allocator),
		prompts = make([dynamic]string, allocator),
		allocator = allocator,
	}
}

@(private)
dup :: proc(o: ^Output, s: string) -> string {
	if s == "" {
		return ""
	}
	r, _ := strings.clone(s, o.allocator)
	return r
}

@(private)
wrote :: proc(o: ^Output, id: string) {
	if id != "" {
		append(&o.prompts, dup(o, id))
	}
}

@(private)
emit :: proc(o: ^Output, e: Event) {
	append(&o.events, e)
}

@(private)
notice :: proc(o: ^Output, level: Notice_Level, text: string) {
	emit(o, Notice{level = level, text = dup(o, text)})
}

@(private)
own :: proc(d: ^Driver, s: string) -> string {
	if s == "" {
		return ""
	}
	r, _ := strings.clone(s, d.allocator)
	return r
}

@(private)
set :: proc(d: ^Driver, dst: ^string, s: string) {
	if dst^ == s {
		return
	}
	old := dst^
	dst^ = own(d, s)
	delete(old, d.allocator)
}

@(private)
own_target :: proc(d: ^Driver, t: Rewind_Target) -> Rewind_Target {
	return {session = own(d, t.session), after = own(d, t.after), before = own(d, t.before), head = own(d, t.head)}
}

@(private)
drop_target :: proc(d: ^Driver, t: ^Rewind_Target) {
	delete(t.session, d.allocator)
	delete(t.after, d.allocator)
	delete(t.before, d.allocator)
	delete(t.head, d.allocator)
	t^ = {}
}

@(private)
drop_perm :: proc(d: ^Driver, p: ^Perm) {
	a := d.allocator
	delete(p.id, a)
	delete(p.raw_id, a)
	delete(p.kind, a)
	delete(p.allow, a)
	delete(p.allow_always, a)
	delete(p.deny, a)
	delete(p.extra, a)
	p^ = {}
}

@(private)
clear_pending :: proc(d: ^Driver) {
	for p in d.pending {
		delete(p.ref, d.allocator)
	}
	clear(&d.pending)
}

@(private)
clear_prompts :: proc(d: ^Driver) {
	for &p in d.prompts {
		drop_prompt_memory(d, &p)
	}
	clear(&d.prompts)
}

@(private)
clear_models :: proc(d: ^Driver) {
	for m in d.models {
		delete(m.id, d.allocator)
		delete(m.name, d.allocator)
	}
	clear(&d.models)
}

@(private)
request :: proc(d: ^Driver, kind: Request, ref := "") -> i64 {
	id := d.next_id
	d.next_id += 1
	append(&d.pending, Pending{id = id, kind = kind, ref = own(d, ref)})
	return id
}

@(private)
take_pending :: proc(d: ^Driver, id: i64) -> (Pending, bool) {
	for p, i in d.pending {
		if p.id == id {
			ordered_remove(&d.pending, i)
			return p, true
		}
	}
	return {}, false
}

@(private)
pending_kind :: proc(d: ^Driver, kind: Request) -> bool {
	for p in d.pending {
		if p.kind == kind {
			return true
		}
	}
	return false
}

@(private)
add_prompt :: proc(d: ^Driver, id, text: string, steer, sent: bool, cmd := "", files: []Attachment = nil) {
	owned: []Attachment
	if len(files) > 0 {
		owned = make([]Attachment, len(files), d.allocator)
		for f, i in files {
			data, _ := make([]u8, len(f.data), d.allocator)
			copy(data, f.data)
			owned[i] = Attachment{path = own(d, f.path), name = own(d, f.name), mime = own(d, f.mime), data = data}
		}
	}
	append(&d.prompts, Prompt{id = own(d, id), cmd = own(d, cmd), text = own(d, text), files = owned, steer = steer, sent = sent})
}

@(private)
drop_prompt_memory :: proc(d: ^Driver, p: ^Prompt) {
	a := d.allocator
	delete(p.id, a)
	delete(p.cmd, a)
	delete(p.text, a)
	for f in p.files {
		delete(f.path, a)
		delete(f.name, a)
		delete(f.mime, a)
		delete(f.data, a)
	}
	delete(p.files, a)
	p^ = {}
}

@(private)
find_prompt :: proc(d: ^Driver, id: string) -> int {
	for p, i in d.prompts {
		if p.id == id {
			return i
		}
	}
	return -1
}

@(private)
remove_prompt :: proc(d: ^Driver, i: int) {
	drop_prompt_memory(d, &d.prompts[i])
	ordered_remove(&d.prompts, i)
}

@(private)
accept_prompt :: proc(d: ^Driver, o: ^Output, id, native: string) {
	if id != "" && id == d.seed_for {
		set(d, &d.seed, "")
		set(d, &d.seed_for, "")
	}
	i := find_prompt(d, id)
	steer := false
	if i >= 0 {
		steer = d.prompts[i].steer
		remove_prompt(d, i)
	}
	emit(o, Prompt_Accepted{id = dup(o, id), native_id = dup(o, native), steer = steer})
}

@(private)
drop_prompt :: proc(d: ^Driver, o: ^Output, id: string) {
	if id == d.seed_for {
		set(d, &d.seed_for, "")
	}
	if i := find_prompt(d, id); i >= 0 {
		remove_prompt(d, i)
	}
	emit(o, Prompt_Dropped{id = dup(o, id)})
}

@(private)
start_turn :: proc(d: ^Driver, o: ^Output, id: string) {
	if d.running {
		return
	}
	d.running = true
	d.interrupted = false
	d.has_usage = false
	d.usage = {}
	d.cost_base = d.cost_seen
	set(d, &d.last_error, "")
	set(d, &d.stream_item, "")
	emit(o, Turn_Started{id = dup(o, id)})
}

@(private)
add_usage :: proc(d: ^Driver, u: Usage) {
	if u == {} {
		return
	}
	d.has_usage = true
	if u.context_window > 0 {
		d.usage.context_tokens = u.context_tokens
		d.usage.context_window = u.context_window
	}
	d.usage.input_tokens += u.input_tokens
	d.usage.output_tokens += u.output_tokens
	d.usage.cache_read_tokens += u.cache_read_tokens
	d.usage.cache_write_tokens += u.cache_write_tokens
	d.usage.reasoning_tokens += u.reasoning_tokens
	d.usage.cost_usd += u.cost_usd
}

@(private)
flush_usage :: proc(d: ^Driver, o: ^Output) {
	if d.has_usage {
		emit(o, d.usage)
	}
	d.has_usage = false
	d.usage = {}
}

@(private)
finish_turn :: proc(d: ^Driver, o: ^Output, status: Turn_Status) {
	flush_usage(d, o)
	emit(o, Turn_Finished{status = status, checkpoint = dup(o, d.checkpoint)})
	d.running = false
	d.interrupted = false
	set(d, &d.turn, "")
	set(d, &d.last_error, "")
}

@(private)
fail_turn :: proc(d: ^Driver, o: ^Output, message: string) {
	flush_usage(d, o)
	emit(o, Turn_Failed{message = dup(o, message), checkpoint = dup(o, d.checkpoint)})
	d.running = false
	d.interrupted = false
	set(d, &d.turn, "")
	set(d, &d.last_error, "")
}

@(private)
open_session :: proc(d: ^Driver, o: ^Output, session: string) {
	if session != "" && (session != d.session || !d.ready) {
		set(d, &d.session, session)
		emit(o, Session_Started{session = dup(o, session)})
	}
	if session != "" {
		set(d, &d.req.resume, session)
	}
	drop_target(d, &d.req.rewind)
	if d.rewinding && session != "" && d.undo == 0 {
		finish_rewind(d, o)
	}
}

@(private)
finish_rewind :: proc(d: ^Driver, o: ^Output) {
	d.rewinding = false
	set(d, &d.fallback, "")
	emit(o, Rewound{session = dup(o, d.session), path = d.rewind_path})
}

@(private)
begin_rewind :: proc(d: ^Driver, seed: []Seed_Entry) {
	d.rewinding = true
	d.rewind_path = d.req.rewind.after == "" ? .Fresh : .Native
	set(d, &d.fallback, "")
	if len(seed) > 0 && d.req.rewind.after != "" {
		set(d, &d.fallback, render_seed(d.desc, seed, d.req.seed_budget, context.temp_allocator))
	}
}

@(private)
take_fallback :: proc(d: ^Driver) -> bool {
	if d.fallback == "" {
		return false
	}
	set(d, &d.seed, d.fallback)
	set(d, &d.seed_for, "")
	set(d, &d.fallback, "")
	set(d, &d.checkpoint, "")
	d.turns = 0
	d.rewind_path = .Seeded
	return true
}

@(private)
rewind_failed :: proc(d: ^Driver, o: ^Output, message: string) {
	emit(o, Rewind_Failed{message = dup(o, message)})
	drop_target(d, &d.req.rewind)
	d.rewinding = false
	set(d, &d.fallback, "")
	d.ready = d.session != ""
}

@(private)
checkpoint_turns :: proc(s: string) -> int {
	n := 0
	if s == "" {
		return 0
	}
	for c in s {
		if c < '0' || c > '9' {
			return 0
		}
		n = n * 10 + int(c - '0')
	}
	return n
}

@(private)
emit_models :: proc(o: ^Output, models: []Model) {
	list := make([]Model, len(models), o.allocator)
	for m, i in models {
		list[i] = Model{id = dup(o, m.id), name = dup(o, m.name), is_default = m.is_default}
	}
	emit(o, Models{models = list})
}

@(private)
store_models :: proc(d: ^Driver, models: []Model) {
	clear_models(d)
	for m in models {
		append(&d.models, Model{id = own(d, m.id), name = own(d, m.name), is_default = m.is_default})
	}
}

@(private)
text_delta :: proc(d: ^Driver, o: ^Output, item, text: string) {
	if text == "" {
		return
	}
	set(d, &d.stream_item, item)
	d.streamed = true
	emit(o, Text_Delta{text = dup(o, text)})
}

@(private)
new_uuid :: proc(d: ^Driver) -> string {
	id := prim.id_new_with(d.req.clock, d.req.random)
	hex := "0123456789abcdef"
	out := make([]u8, 36, context.temp_allocator)
	j := 0
	for i in 0 ..< 16 {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[j] = '-'
			j += 1
		}
		out[j] = hex[id[i] >> 4]
		out[j + 1] = hex[id[i] & 0xf]
		j += 2
	}
	return string(out)
}

@(private)
base_argv :: proc(d: ^Driver, argv: ^[dynamic]string) {
	for a, i in d.desc.argv {
		append(argv, i == 0 && d.req.program != "" ? d.req.program : a)
	}
}

@(private)
auto_decision :: proc(access: Access, edit_ok: bool) -> Decision {
	switch access {
	case .Full:
		return .Allow
	case .Edit:
		return edit_ok ? .Allow : .Deny
	case .Plan:
		return .Deny
	}
	return .Deny
}
