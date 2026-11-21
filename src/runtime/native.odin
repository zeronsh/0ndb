package rt

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "../agent"
import "../convo"
import eng "../engine"
import "../http"
import "../model"
import "../obj"
import "../prim"

@(private)
NATIVE_MAGIC :: "\x00ondb-native-1"

Native :: struct {
	r:        ^Runtime,
	run:      ^Run,
	arena:    virtual.Arena,
	alloc:    runtime.Allocator,
	mr:       model.Run,
	mr_on:    bool,
	api:      model.Api,
	cfg:      model.Config,
	http_id:  http.Id,
	timer:    prim.Timer,
	timer_at: i64,
	depth:    int,
	dead:     bool,
	started:  bool,
	ctx:      model.Context,
	defs:     [dynamic]model.Tool_Def,
	conns:    [dynamic]^Mcp_Conn,
	waiting:  int,
	first:    Rid,
	tokens:   [dynamic]Native_Tool,
	v:        ^obj.View,
}

@(private)
Native_Tool :: struct {
	id:    string,
	token: u64,
}

reference_model_plug :: proc() -> Model_Plug {
	return Model_Plug{resolve = _reference_resolve}
}

@(private)
_reference_resolve :: proc(data: rawptr, r: ^Runtime, provider: string, model_id: string, cfg: ^model.Config, m: ^model.Model) -> bool {
	id := model_id
	if len(id) == 0 {
		id = model.DEFAULT_ANTHROPIC_MODEL
	}
	spec, ok := model.spec_lookup(id)
	api := spec.api
	if !ok {
		switch provider {
		case "openai", "openai-responses":
			api = .OpenAI_Responses
		case "openai-chat", "chat":
			api = .OpenAI_Chat
		case:
			api = .Anthropic
		}
		spec = model.custom_spec(id, api, 200_000, 32_000)
	}
	cfg^ = model.Config {
		spec = spec,
	}
	prefix := "ANTHROPIC"
	if api != .Anthropic {
		prefix = "OPENAI"
	}
	if len(provider) > 0 && provider != "anthropic" && provider != "openai" && provider != "native" {
		prefix = strings.to_upper(provider, context.temp_allocator)
		for &c in transmute([]u8)prefix {
			if c == '-' {
				c = '_'
			}
		}
	}
	if key, kok := _secret(r, concat(prefix, "_API_KEY")); kok {
		cfg.api_key = key
	}
	if url, uok := _secret(r, concat(prefix, "_BASE_URL")); uok {
		cfg.url = url
	}
	cfg.bearer = api != .Anthropic
	m^ = model.model_for(api)
	return true
}

native_start :: proc(run: ^Run) -> Error {
	r := run.r
	n := new(Native, r.allocator)
	n.r = r
	n.run = run
	if !_arena_init(&n.arena) {
		free(n, r.allocator)
		return .Limit
	}
	n.alloc = virtual.arena_allocator(&n.arena)
	n.defs = make([dynamic]model.Tool_Def, n.alloc)
	n.conns = make([dynamic]^Mcp_Conn, n.alloc)
	n.tokens = make([dynamic]Native_Tool, n.alloc)
	run.native = n
	plug := r.cfg.model
	if plug.resolve == nil {
		plug = reference_model_plug()
	}
	m: model.Model
	if !plug.resolve(plug.data, r, run.ai.provider, run.ai.model, &n.cfg, &m) {
		return .Unsupported
	}
	n.api = m.api
	a := &run.ai
	if a.budget.tokens > 0 {
		n.cfg.budget.tokens = a.budget.tokens
	}
	if a.budget.usd > 0 {
		n.cfg.budget.cost_usd = a.budget.usd
	}
	if a.budget.turns > 0 {
		n.cfg.budget.steps = a.budget.turns
	}
	if a.budget.seconds > 0 {
		n.cfg.budget.wall_ms = a.budget.seconds * 1000
	}
	if a.compact_at > 0 {
		n.cfg.compact_at = a.compact_at
	}
	if len(a.effort) > 0 {
		n.cfg.effort = model.effort_from_name(a.effort)
	}
	n.cfg.keepalive.enabled = a.keepalive
	model.run_init(&n.mr, n.cfg, m, n.alloc)
	n.mr_on = true
	builtin_defs(r, a, &n.defs, n.alloc)
	if r.cfg.tools.list != nil {
		r.cfg.tools.list(r.cfg.tools.data, r, a, &n.defs)
	}
	cwd := run.ws.root if run.ws != nil else concat(r.cfg.work_root, "/", hex(run.o.id))
	if len(a.mcp) > 0 {
		prim.mkdir_all(r.e.base, cwd, 0o755)
	}
	for &spec in a.mcp {
		c, cerr := mcp_conn_open(r, &spec, cwd, n, _native_mcp_ready)
		if cerr == .None {
			append(&n.conns, c)
			n.waiting += 1
		} else {
			run_notice(run, concat("MCP server ", spec.name, " could not be started"))
		}
	}
	if n.waiting == 0 {
		_native_begin(n)
	}
	return .None
}

@(private)
_native_mcp_ready :: proc(data: rawptr, c: ^Mcp_Conn) {
	n := (^Native)(data)
	if n.started || n.dead {
		return
	}
	n.waiting -= 1
	if !c.ready {
		run_notice(n.run, concat("MCP server ", c.name, " is unavailable: ", c.error))
	}
	if n.waiting <= 0 {
		_native_begin(n)
	}
}

@(private)
_native_begin :: proc(n: ^Native) {
	if n.started || n.dead {
		return
	}
	n.started = true
	r := n.r
	run := n.run
	for c in n.conns {
		mcp_conn_defs(c, &n.defs, n.alloc)
	}
	n.ctx = native_context(n)
	n.ctx.tools = n.defs[:]
	out := model.output_make()
	model.run_start(&n.mr, &n.ctx, rid_text(run.reply), mono_ns(r), &out)
	_native_apply(n, &out)
}

native_context :: proc(n: ^Native) -> model.Context {
	r := n.r
	run := n.run
	ctx: model.Context
	b := make(Buf, n.alloc)
	append(&b, run.ai.instructions)
	if len(run.ai.memory) > 0 && .Memory in run.ai.builtins {
		if len(b) > 0 {
			append(&b, "\n\n")
		}
		append(&b, "You have durable memory: use memory_search, memory_read and memory_write to recall and record facts and notes that should outlive this conversation.")
	}
	if run.ws != nil {
		if len(b) > 0 {
			append(&b, "\n\n")
		}
		append(&b, "Your working directory is ")
		append(&b, run.ws.root)
		append(&b, ". File paths in tools are relative to it.")
	}
	ctx.system = string(b[:])
	msgs := make([dynamic]model.Message, n.alloc)
	v, verr := eng.convo_view(r.e, run.o)
	if verr != .None {
		return ctx
	}
	n.v = v
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return ctx
	}
	from := run.user
	if run.revive {
		if m, merr := convo.message(v, &t, convo.Position{msg = run.reply}, context.temp_allocator); merr == .None && !obj.rid_none(m.parent) {
			from = m.parent
		}
	}
	pg, _ := convo.page(v, &t, convo.Position{msg = from}, 1_000_000, n.alloc)
	comps, _ := convo.compactions(v, 0, context.temp_allocator)
	cut := -1
	summary := ""
	for ci := len(comps) - 1; ci >= 0 && cut < 0; ci -= 1 {
		for m, i in pg.messages {
			if m.id == comps[ci].to {
				cut = i
				summary = comps[ci].summary
				break
			}
		}
	}
	start := len(pg.messages) - 1
	if cut >= 0 {
		start = cut - 1
		text := concat(model.COMPACT_PREAMBLE, summary, model.COMPACT_RESUME)
		_push(&msgs, .User, model.Text{text = clone(text, n.alloc)}, n.alloc)
	}
	if start >= 0 && start < len(pg.messages) {
		n.first = pg.messages[start].id
	}
	for i := start; i >= 0; i -= 1 {
		_message_blocks(n, &msgs, &pg.messages[i])
	}
	if run.revive {
		_push(&msgs, .User, model.Text{text = REVIVE_PROMPT}, n.alloc)
	}
	ctx.messages = msgs[:]
	return ctx
}

@(private)
_push :: proc(msgs: ^[dynamic]model.Message, role: model.Role, blk: model.Block, allocator: runtime.Allocator) {
	if k := len(msgs); k > 0 && msgs[k - 1].role == role && len(msgs[k - 1].native) == 0 {
		old := msgs[k - 1].blocks
		nb := make([]model.Block, len(old) + 1, allocator)
		copy(nb, old)
		nb[len(old)] = blk
		msgs[k - 1].blocks = nb
		return
	}
	nb := make([]model.Block, 1, allocator)
	nb[0] = blk
	append(msgs, model.Message{role = role, blocks = nb})
}

@(private)
_message_blocks :: proc(n: ^Native, msgs: ^[dynamic]model.Message, m: ^convo.Message) {
	a := n.alloc
	if m.role == .Assistant || m.role == .Tool {
		if items, ok := native_items_decode(seal_native(n.v, m), a); ok {
			usable := len(items) > 0
			for it in items {
				usable &&= it.api == n.api
			}
			if usable {
				last_reset := 0
				for it, i in items {
					if it.reset {
						last_reset = i
					}
				}
				for it in items[last_reset:] {
					append(msgs, model.Message{role = it.role, native = it.native, native_api = it.api})
				}
				return
			}
		}
		results := make(map[string]bool, context.temp_allocator)
		for blk in m.blocks {
			if blk.kind == .Tool_Result {
				results[blk.id] = true
			}
		}
		for blk in m.blocks {
			#partial switch blk.kind {
			case .Text:
				if len(blk.text) > 0 {
					_push(msgs, .Assistant, model.Text{text = clone(string(blk.text), a)}, a)
				}
			case .Tool_Call:
				id := blk.id
				if i := strings.last_index_byte(id, '/'); i >= 0 {
					continue
				}
				input := string(blk.text)
				if len(input) == 0 {
					input = "{}"
				}
				_push(msgs, .Assistant, model.Tool_Use{id = clone(id, a), name = clone(blk.name, a), input = clone(input, a)}, a)
				if id not_in results {
					content := make([]model.Block, 1, a)
					content[0] = model.Text{text = "The tool call was interrupted before it produced a result."}
					_push(msgs, .User, model.Tool_Result{id = clone(id, a), content = content, is_error = true}, a)
				}
			case .Tool_Result:
				text := string(blk.text) if !blk.is_ref else string(_blob_read(n.r, blk.blob.oid))
				content := make([]model.Block, 1, a)
				content[0] = model.Text{text = clone(text, a)}
				_push(msgs, .User, model.Tool_Result{id = clone(blk.id, a), content = content, is_error = blk.failed}, a)
			}
		}
		return
	}
	any := false
	for blk in m.blocks {
		#partial switch blk.kind {
		case .Text:
			_push(msgs, .User, model.Text{text = clone(string(blk.text), a)}, a)
			any = true
		case .File, .Image:
			data := blk.text if !blk.is_ref else _blob_read(n.r, blk.blob.oid)
			if len(data) == 0 {
				continue
			}
			mime := blk.id
			if strings.has_prefix(mime, "image/") {
				_push(msgs, .User, model.Image{mime = clone(mime, a), data = clone_bytes(data, a)}, a)
			} else if mime == "application/pdf" {
				_push(msgs, .User, model.Document{mime = clone(mime, a), data = clone_bytes(data, a), title = clone(blk.name, a)}, a)
			} else {
				_push(msgs, .User, model.Document{text = clone(string(data), a), title = clone(blk.name, a)}, a)
			}
			any = true
		}
	}
	if !any {
		_push(msgs, .User, model.Text{text = "(empty message)"}, a)
	}
}

Native_Item :: struct {
	role:   model.Role,
	api:    model.Api,
	reset:  bool,
	native: string,
}

native_items_decode :: proc(s: string, allocator: runtime.Allocator) -> (items: []Native_Item, ok: bool) {
	if !strings.has_prefix(s, NATIVE_MAGIC) {
		return nil, false
	}
	rd := prim.reader(transmute([]u8)s[len(NATIVE_MAGIC):])
	cnt := prim.read_uvarint(&rd)
	if cnt > 1 << 20 {
		return nil, false
	}
	out := make([dynamic]Native_Item, 0, int(cnt), allocator)
	for _ in 0 ..< cnt {
		role := prim.read_u8(&rd)
		api := prim.read_u8(&rd)
		reset := prim.read_bool(&rd)
		native := prim.read_str(&rd)
		if !prim.reader_ok(&rd) || role > u8(max(model.Role)) || api > u8(max(model.Api)) {
			return nil, false
		}
		append(&out, Native_Item{role = model.Role(role), api = model.Api(api), reset = reset, native = clone(native, allocator)})
	}
	return out[:], true
}

@(private)
_native_item_add :: proc(n: ^Native, it: model.Transcript_Item) {
	run := n.run
	items, _ := native_items_decode(string(run.native_items[:]), context.temp_allocator)
	list := make([dynamic]Native_Item, context.temp_allocator)
	append(&list, ..items)
	append(&list, Native_Item{role = it.role, api = it.api, reset = it.reset, native = it.native})
	clear(&run.native_items)
	append(&run.native_items, NATIVE_MAGIC)
	w := prim.writer(&run.native_items)
	prim.write_uvarint(&w, u64(len(list)))
	for x in list {
		prim.write_u8(&w, u8(x.role))
		prim.write_u8(&w, u8(x.api))
		prim.write_bool(&w, x.reset)
		prim.write_str(&w, x.native)
	}
}

@(private)
_native_apply :: proc(n: ^Native, out: ^model.Output) {
	r := n.r
	n.depth += 1
	for e in out.events {
		if n.dead {
			break
		}
		_native_event(n, e)
	}
	for &act in out.actions {
		if n.dead {
			break
		}
		switch v in act {
		case model.Http_Start:
			req := v.req
			c, herr := eng.http_client(r.e)
			if herr != .None {
				nested := model.output_make()
				model.run_on_done(&n.mr, .Unsupported, "no HTTP client", mono_ns(r), &nested)
				_native_apply(n, &nested)
				continue
			}
			id, serr := http.start(c, &req, http.Sink{data = n, head = _native_head, body = _native_body, done = _native_done})
			if serr != .None {
				n.http_id = 0
				nested := model.output_make()
				model.run_on_done(&n.mr, serr, http.error_text(serr), mono_ns(r), &nested)
				_native_apply(n, &nested)
			} else {
				n.http_id = id
			}
		case model.Http_Abort:
			if n.http_id != 0 {
				id := n.http_id
				n.http_id = 0
				if c, herr := eng.http_client(r.e); herr == .None {
					http.cancel(c, id)
				}
			}
		case model.Tool_Run:
			_native_tool(n, v)
		case model.Tool_Abort:
			for t in n.tokens {
				if t.id == v.id {
					tool_abort(r, t.token)
				}
			}
		}
	}
	n.depth -= 1
	if n.dead {
		if n.depth == 0 {
			_native_free(n)
		}
		return
	}
	_native_arm(n)
}

@(private)
_native_event :: proc(n: ^Native, e: model.Event) {
	run := n.run
	if run == nil {
		return
	}
	switch ev in e {
	case agent.Turn_Started:
	case agent.Prompt_Accepted:
		if ev.steer {
			run_steer_accepted(run, ev.id)
		}
	case agent.Prompt_Dropped:
		run_steer_dropped(run, ev.id)
	case agent.Message_Started:
		run.steps += 1
		run.cur = -1
	case agent.Text_Delta:
		run_text(run, .Text, ev.text)
	case agent.Reasoning_Delta:
		run_text(run, .Reasoning, ev.text)
	case agent.Tool_Started:
		run_tool_started(run, ev.id, ev.name, ev.input, ev.parent)
	case agent.Tool_Updated:
		if ev.append && len(ev.input) > 0 {
			run_tool_input(run, ev.id, ev.input)
		}
	case agent.Tool_Finished:
		run_tool_finished(run, ev.id, ev.output, ev.is_error)
	case agent.Usage:
		run_usage(run, ev)
	case agent.Turn_Finished:
		run_finish(run, .Done if ev.status == .Done && !run.interrupting else .Interrupted)
	case agent.Turn_Failed:
		run_error(run, ev.message)
		run_finish(run, .Interrupted if run.interrupting else .Failed)
	case agent.Notice:
		run_notice(run, ev.text)
	case model.Raw:
		run_raw(run, RAW_HTTP, ev.bytes)
	case model.Transcript_Item:
		_native_item_add(n, ev)
	case model.Compacted:
		if w := _writer(run); w != nil && !obj.rid_none(n.first) {
			convo.writer_compact(w, n.first, run.user, ev.summary)
		}
	case model.Retrying:
		run_notice(run, concat("retrying the model request: ", ev.reason))
	case model.Budget_Exceeded:
		run_notice(run, "budget exhausted")
	case model.Reasoning_Dropped:
	case model.Server_Session:
	case model.Keepalive_Due:
		keepalive_schedule(n.r, run.o, ev.at, ev.until)
	}
}

@(private)
_native_tool :: proc(n: ^Native, call: model.Tool_Run) {
	r := n.r
	run := n.run
	tc := Tool_Call {
		id     = call.id,
		name   = call.name,
		input  = call.input,
		object = run.o,
		agent  = &run.ai,
		cwd    = run.ws.root if run.ws != nil else "",
	}
	token := tool_dispatch(r, run, n, &tc)
	if token != 0 {
		append(&n.tokens, Native_Tool{id = clone(call.id, n.alloc), token = token})
		for &t in run.tools {
			if t.id == call.id {
				t.token = token
			}
		}
	}
}

native_tool_result :: proc(n: ^Native, id: string, text: string, is_error: bool) {
	if n.dead || !n.mr_on {
		return
	}
	for t, i in n.tokens {
		if t.id == id {
			ordered_remove(&n.tokens, i)
			break
		}
	}
	out := model.output_make()
	content := []model.Block{model.Text{text = text}}
	model.run_tool_done(&n.mr, id, content, is_error, mono_ns(n.r), &out)
	_native_apply(n, &out)
}

native_steer :: proc(n: ^Native, text: string, id: string, files: []agent.Attachment) -> bool {
	if !n.started || n.dead {
		return false
	}
	out := model.output_make()
	ok := model.run_steer(&n.mr, id, text, files, mono_ns(n.r), &out)
	_native_apply(n, &out)
	return ok
}

native_interrupt :: proc(n: ^Native) {
	if !n.started {
		if n.run != nil {
			run_finish(n.run, .Interrupted)
		}
		return
	}
	out := model.output_make()
	model.run_interrupt(&n.mr, mono_ns(n.r), &out)
	_native_apply(n, &out)
}

native_done :: proc(n: ^Native, run: ^Run) {
	n.run = nil
	run.native = nil
	native_free(n)
}

native_free :: proc(n: ^Native) {
	if n.dead {
		return
	}
	n.dead = true
	if n.depth == 0 {
		_native_free(n)
	}
}

@(private)
_native_free :: proc(n: ^Native) {
	r := n.r
	l := eng.loop(r.e)
	if n.http_id != 0 {
		if c, err := eng.http_client(r.e); err == .None {
			http.cancel(c, n.http_id)
		}
		n.http_id = 0
	}
	if n.timer != 0 {
		prim.timer_cancel(l, n.timer)
		n.timer = 0
	}
	for t in n.tokens {
		tool_abort(r, t.token)
	}
	for c in n.conns {
		_mcp_conn_free(c)
	}
	if n.mr_on {
		model.run_destroy(&n.mr)
	}
	if n.run != nil {
		n.run.native = nil
	}
	virtual.arena_destroy(&n.arena)
	free(n, r.allocator)
}

@(private)
_native_arm :: proc(n: ^Native) {
	l := eng.loop(n.r.e)
	d := model.run_deadline(&n.mr)
	if d == n.timer_at && (d == 0 || prim.timer_pending(l, n.timer)) {
		return
	}
	if n.timer != 0 {
		prim.timer_cancel(l, n.timer)
		n.timer = 0
	}
	n.timer_at = d
	if d != 0 {
		n.timer = prim.timer_at(l, d, n, _native_on_timer)
	}
}

@(private)
_native_on_timer :: proc(l: ^prim.Loop, data: rawptr) {
	n := (^Native)(data)
	n.timer = 0
	n.timer_at = 0
	out := model.output_make()
	model.run_tick(&n.mr, mono_ns(n.r), &out)
	_native_apply(n, &out)
}

@(private)
_native_head :: proc(data: rawptr, id: http.Id, status: int, headers: []http.Header) {
	n := (^Native)(data)
	if n.http_id != id || n.dead {
		return
	}
	out := model.output_make()
	model.run_on_head(&n.mr, status, headers, mono_ns(n.r), &out)
	_native_apply(n, &out)
}

@(private)
_native_body :: proc(data: rawptr, id: http.Id, chunk: []u8) -> bool {
	n := (^Native)(data)
	if n.http_id != id || n.dead {
		return false
	}
	rest := chunk
	for len(rest) > 0 {
		cut := len(rest)
		for i in 0 ..< len(rest) - 1 {
			if rest[i] == '\n' && (rest[i + 1] == '\n' || (rest[i + 1] == '\r' && i + 2 < len(rest) && rest[i + 2] == '\n')) {
				cut = i + 2 if rest[i + 1] == '\n' else i + 3
				break
			}
		}
		piece := rest[:cut]
		rest = rest[cut:]
		out := model.output_make()
		keep := model.run_on_body(&n.mr, piece, mono_ns(n.r), &out)
		if !keep && n.http_id == id {
			n.http_id = 0
		}
		_native_apply(n, &out)
		if !keep || n.dead || n.http_id != id {
			return false
		}
	}
	return true
}

@(private)
_native_done :: proc(data: rawptr, id: http.Id, err: http.Error, detail: string) {
	n := (^Native)(data)
	if n.http_id != id || n.dead {
		return
	}
	n.http_id = 0
	out := model.output_make()
	model.run_on_done(&n.mr, err, detail, mono_ns(n.r), &out)
	_native_apply(n, &out)
	if n.run != nil {
		run_raw_commit(n.run)
	}
}

keepalive_schedule :: proc(r: ^Runtime, o: Object, at: i64, until: i64) {
	if !r.warmer_on {
		c, err := eng.http_client(r.e)
		if err != .None {
			return
		}
		model.warmer_init(&r.warmer, eng.loop(r.e), c^, _warm_supply, nil, r, r.allocator)
		r.warmer_on = true
	}
	model.warmer_schedule(&r.warmer, _warm_key(o), at, until)
	_warm_register(r, o)
}

@(private)
_warm_key :: proc(o: Object) -> u64 {
	id := o.id
	return prim.get_u64le(id[8:])
}

@(private)
_warm_register :: proc(r: ^Runtime, o: Object) {
	so := state_object(r, o.space)
	k := make([]u8, 8, context.temp_allocator)
	prim.put_u64le(k, _warm_key(o))
	id := o.id
	map_put(r, so, key_of("warm/", k), field_bytes(1, id[:]))
}

@(private)
_warm_supply :: proc(data: rawptr, key: u64, cfg: ^model.Config, ctx: ^model.Context) -> bool {
	r := (^Runtime)(data)
	k := make([]u8, 8, context.temp_allocator)
	prim.put_u64le(k, key)
	for sw in r.spaces {
		en, ok := map_read(r, state_object(r, sw.space), key_of("warm/", k))
		if !ok {
			continue
		}
		b := entry_bytes(&en, 1)
		if len(b) != 16 {
			continue
		}
		o := Object{space = sw.space}
		copy(o.id[:], b)
		if run_find(r, o) != nil {
			return false
		}
		return _warm_context(r, o, cfg, ctx)
	}
	return false
}

@(private)
_warm_context :: proc(r: ^Runtime, o: Object, cfg: ^model.Config, ctx: ^model.Context) -> bool {
	a, ok := agent_resolve(r, o, "", "", context.temp_allocator)
	if !ok || a.kind != .Native || !a.keepalive {
		return false
	}
	plug := r.cfg.model
	if plug.resolve == nil {
		plug = reference_model_plug()
	}
	m: model.Model
	if !plug.resolve(plug.data, r, a.provider, a.model, cfg, &m) {
		return false
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return false
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return false
	}
	fake := Run {
		r     = r,
		o     = o,
		ai    = a,
		user  = convo.tail_head(v, &t),
		alloc = context.temp_allocator,
	}
	n := Native {
		r     = r,
		run   = &fake,
		alloc = context.temp_allocator,
		api   = m.api,
	}
	n.defs = make([dynamic]model.Tool_Def, context.temp_allocator)
	builtin_defs(r, &a, &n.defs, context.temp_allocator)
	ctx^ = native_context(&n)
	ctx.tools = n.defs[:]
	return true
}
