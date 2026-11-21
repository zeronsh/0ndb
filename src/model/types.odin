package model

import "base:runtime"
import "../agent"

Role :: enum u8 {
	User,
	Assistant,
}

Text :: struct {
	text: string,
}

Image :: struct {
	mime: string,
	data: []u8,
	url:  string,
}

Document :: struct {
	mime:  string,
	data:  []u8,
	url:   string,
	title: string,
	text:  string,
}

Tool_Use :: struct {
	id:    string,
	name:  string,
	input: string,
}

Tool_Result :: struct {
	id:       string,
	content:  []Block,
	is_error: bool,
}

Thinking :: struct {
	text:      string,
	signature: string,
	redacted:  string,
}

Block :: union {
	Text,
	Image,
	Document,
	Tool_Use,
	Tool_Result,
	Thinking,
}

Message :: struct {
	role:       Role,
	blocks:     []Block,
	native:     string,
	native_api: Api,
	model:      string,
}

Tool_Def :: struct {
	name:        string,
	description: string,
	schema:      string,
	strict:      bool,
	eager:       bool,
}

Context :: struct {
	system:       string,
	tools:        []Tool_Def,
	messages:     []Message,
	server_id:    string,
	server_after: int,
}

Thinking_Display :: enum u8 {
	Default,
	Summarized,
	Omitted,
}

Budget :: struct {
	tokens:   u64,
	cost_usd: f64,
	steps:    int,
	wall_ms:  i64,
}

Server_State_Policy :: enum u8 {
	Off,
	Provider_Retained,
}

Keepalive :: struct {
	enabled:   bool,
	window_ms: i64,
	margin_ms: i64,
}

Retry :: struct {
	attempts:    int,
	base_ms:     i64,
	max_ms:      i64,
	max_wait_ms: i64,
	resumes:     int,
}

Config :: struct {
	spec:             Spec,
	url:              string,
	api_key:          string,
	bearer:           bool,
	headers:          []Header,
	max_tokens:       u64,
	effort:           Effort,
	display:          Thinking_Display,
	cache_ttl:        Cache_Ttl,
	cache_key:        string,
	explicit_cache:   bool,
	no_fallback:      bool,
	serial_tools:     bool,
	budget:           Budget,
	retry:            Retry,
	compact_at:       f64,
	compact_tokens:   u64,
	connect_ms:       i64,
	stall_ms:         i64,
	server_state:     Server_State_Policy,
	client_compact:   bool,
	keepalive:        Keepalive,
}

Stop_Reason :: enum u8 {
	None,
	End_Turn,
	Tool_Use,
	Max_Tokens,
	Stop_Sequence,
	Pause_Turn,
	Refusal,
	Context_Exceeded,
	Compaction,
	Other,
}

Failure_Class :: enum u8 {
	None,
	Network,
	Server,
	Overloaded,
	Rate_Limited,
	Too_Long,
	Auth,
	Invalid,
	Quota,
	Malformed,
	Fatal,
}

Failure :: struct {
	class:        Failure_Class,
	status:       int,
	code:         string,
	message:      string,
	retry_after:  i64,
	should_retry: i8,
}

Call_Usage :: struct {
	input:       u64,
	output:      u64,
	cache_read:  u64,
	cache_write: u64,
	cache_long:  u64,
	reasoning:   u64,
}

Block_Kind :: enum u8 {
	Text,
	Thinking,
	Tool_Call,
	Other,
}

Delta_Kind :: enum u8 {
	Start,
	Block_Start,
	Text,
	Thinking,
	Tool_Input,
	Block_Stop,
	Usage,
	Stop,
	Error,
}

Delta :: struct {
	kind:    Delta_Kind,
	block:   Block_Kind,
	index:   int,
	id:      string,
	name:    string,
	text:    string,
	usage:   Call_Usage,
	stop:    Stop_Reason,
	failure: Failure,
}

Acc :: struct {
	kind:     Block_Kind,
	index:    int,
	complete: bool,
	kept:     bool,
	emitted:  bool,
	id:       [dynamic]u8,
	name:     [dynamic]u8,
	type:     [dynamic]u8,
	text:     [dynamic]u8,
	sig:      [dynamic]u8,
	raw:      [dynamic]u8,
}

Stream :: struct {
	sse:      Sse,
	blocks:   [dynamic]Acc,
	used:     int,
	scratch:  [dynamic]u8,
	msg_id:   [dynamic]u8,
	model:    [dynamic]u8,
	stop:     Stop_Reason,
	detail:   [dynamic]u8,
	usage:    Call_Usage,
	done:     bool,
	started:  bool,
	failure:  Failure,
	fail_msg: [dynamic]u8,
	chat_open: int,
	fell_back: bool,
}

Transcript :: struct {
	buf:        [dynamic]u8,
	items:      int,
	positions:  int,
	mark:       int,
	prev_mark:  int,
	prev_pos:   int,
	text_bytes: int,
	media:      int,
	media_tok:  u64,
	last_role:  Role,
	has_last:   bool,
	compaction: bool,
}

Request_Kind :: enum u8 {
	Normal,
	Compact,
	Keepalive,
}

Server_Op :: enum u8 {
	None,
	Create,
	Continue,
}

Request_Opts :: struct {
	kind:           Request_Kind,
	op:             Server_Op,
	prev:           string,
	server_compact: bool,
	compaction:     bool,
}

Model :: struct {
	data:       rawptr,
	api:        Api,
	encode:     proc(m: ^Model, cfg: ^Config, msg: ^Message, t: ^Transcript),
	head:       proc(m: ^Model, cfg: ^Config, ctx: ^Context, opts: ^Request_Opts, dst: ^[dynamic]u8),
	tail:       proc(m: ^Model, cfg: ^Config, kind: Request_Kind, dst: ^[dynamic]u8),
	next:       proc(m: ^Model, s: ^Stream, out: ^[dynamic]Delta) -> bool,
	finish:     proc(m: ^Model, s: ^Stream, t: ^Transcript, partial: bool) -> bool,
	classify:   proc(m: ^Model, status: int, headers: []Header, body: []u8) -> Failure,
	marker:     proc(m: ^Model, cfg: ^Config) -> string,
	auth:       proc(m: ^Model, cfg: ^Config, opts: ^Request_Opts, dst: ^[dynamic]Header),
	trigger:    proc(m: ^Model, cfg: ^Config, t: ^Transcript),
	compacted:  proc(m: ^Model, s: ^Stream, t: ^Transcript, summary: ^[dynamic]u8) -> bool,
	state_code: proc(m: ^Model, f: Failure) -> State_Fault,
	warm_usage: proc(m: ^Model, body: []u8) -> Call_Usage,
	warm_tail:  proc(t: ^Transcript, dst: ^[dynamic]u8),
}

State_Fault :: enum u8 {
	None,
	Replay,
	Disable,
}

Raw :: struct {
	bytes: []u8,
}

Transcript_Item :: struct {
	role:   Role,
	native: string,
	api:    Api,
	reset:  bool,
}

Compacted :: struct {
	summary: string,
	items:   int,
	server:  bool,
}

Drop_Reason :: enum u8 {
	Stream_Failed,
	Interrupted,
	Not_Replayable,
}

Reasoning_Dropped :: struct {
	text:   string,
	reason: Drop_Reason,
}

Server_Session :: struct {
	id:    string,
	state: Server_State,
}

Keepalive_Due :: struct {
	at:    i64,
	until: i64,
}

Retrying :: struct {
	attempt:  int,
	delay_ms: i64,
	resumed:  bool,
	status:   int,
	reason:   string,
}

Budget_Kind :: enum u8 {
	Tokens,
	Cost,
	Steps,
	Wall,
}

Budget_Exceeded :: struct {
	kind: Budget_Kind,
}

Event :: union {
	agent.Turn_Started,
	agent.Prompt_Accepted,
	agent.Prompt_Dropped,
	agent.Message_Started,
	agent.Text_Delta,
	agent.Reasoning_Delta,
	agent.Tool_Started,
	agent.Tool_Updated,
	agent.Tool_Finished,
	agent.Usage,
	agent.Turn_Finished,
	agent.Turn_Failed,
	agent.Notice,
	Raw,
	Transcript_Item,
	Compacted,
	Retrying,
	Budget_Exceeded,
	Reasoning_Dropped,
	Server_Session,
	Keepalive_Due,
}

Http_Start :: struct {
	req: Http_Request,
}

Http_Abort :: struct {}

Tool_Run :: struct {
	id:    string,
	name:  string,
	input: string,
}

Tool_Abort :: struct {
	id: string,
}

Action :: union {
	Http_Start,
	Http_Abort,
	Tool_Run,
	Tool_Abort,
}

Output :: struct {
	events:    [dynamic]Event,
	actions:   [dynamic]Action,
	allocator: runtime.Allocator,
}

output_make :: proc(allocator := context.temp_allocator) -> Output {
	return Output{events = make([dynamic]Event, allocator), actions = make([dynamic]Action, allocator), allocator = allocator}
}

model_for :: proc(api: Api) -> Model {
	switch api {
	case .Anthropic:
		return anthropic_model()
	case .OpenAI_Responses:
		return responses_model()
	case .OpenAI_Chat:
		return chat_model()
	}
	return anthropic_model()
}

config_default :: proc(model_id: string) -> (Config, bool) {
	spec, ok := spec_lookup(model_id)
	if !ok {
		return {}, false
	}
	return Config{spec = spec}, true
}

custom_spec :: proc(id: string, api: Api, context_window: u64, max_output: u64) -> Spec {
	return Spec{id = id, api = api, context_window = context_window, max_output = max_output, thinking = .None}
}
