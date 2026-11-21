package model

Api :: enum u8 {
	Anthropic,
	OpenAI_Responses,
	OpenAI_Chat,
}

Thinking_Mode :: enum u8 {
	None,
	Adaptive_Always,
	Adaptive,
	Budget,
}

Effort :: enum u8 {
	Default,
	None,
	Minimal,
	Low,
	Medium,
	High,
	Xhigh,
	Max,
}

Cache_Ttl :: enum u8 {
	Short,
	Long,
}

Price :: struct {
	input:        f64,
	output:       f64,
	cache_read:   f64,
	cache_write:  f64,
	cache_write2: f64,
}

Spec :: struct {
	id:                string,
	api:               Api,
	context_window:    u64,
	max_output:        u64,
	thinking:          Thinking_Mode,
	default_effort:    Effort,
	min_cache_tokens:  u64,
	price:             Price,
	long_threshold:    u64,
	long_price:        Price,
	server_fallback:   bool,
	system_messages:   bool,
	explicit_cache:    bool,
	forced_tool_error: bool,
}

ANTHROPIC_URL :: "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION :: "2026-10-21"
ANTHROPIC_VERSION_HEADER :: "anthropic-version: " + ANTHROPIC_VERSION
ANTHROPIC_KEY_HEADER :: "x-api-key: "
ANTHROPIC_BETA_HEADER :: "anthropic-beta: "
ANTHROPIC_FALLBACK_BETA :: "server-side-fallback-2026-07-01"
ANTHROPIC_FALLBACK_FIELD :: `"fallbacks":"default"`
ANTHROPIC_AUTO_CACHE_SHORT :: `"cache_control":{"type":"ephemeral"}`
ANTHROPIC_AUTO_CACHE_LONG :: `"cache_control":{"type":"ephemeral","ttl":"1h"}`
ANTHROPIC_SPEND_CAP_CODE :: "enforced_spend_limit_reached"
ANTHROPIC_MAX_BREAKPOINTS :: 4
ANTHROPIC_LOOKBACK_POSITIONS :: 20
ANTHROPIC_EVENT_MESSAGE_START :: "message_start"
ANTHROPIC_EVENT_BLOCK_START :: "content_block_start"
ANTHROPIC_EVENT_BLOCK_DELTA :: "content_block_delta"
ANTHROPIC_EVENT_BLOCK_STOP :: "content_block_stop"
ANTHROPIC_EVENT_MESSAGE_DELTA :: "message_delta"
ANTHROPIC_EVENT_MESSAGE_STOP :: "message_stop"
ANTHROPIC_EVENT_PING :: "ping"
ANTHROPIC_EVENT_ERROR :: "error"
ANTHROPIC_DELTA_TEXT :: "text_delta"
ANTHROPIC_DELTA_INPUT :: "input_json_delta"
ANTHROPIC_DELTA_THINKING :: "thinking_delta"
ANTHROPIC_DELTA_SIGNATURE :: "signature_delta"
ANTHROPIC_DELTA_CITATIONS :: "citations_delta"
RESUME_PROMPT :: "Your previous response was interrupted by a network failure and ended with the text above. Continue from exactly where you left off without repeating anything."

OPENAI_RESPONSES_URL :: "https://api.openai.com/v1/responses"
OPENAI_CHAT_URL :: "https://api.openai.com/v1/chat/completions"
OPENAI_AUTH_HEADER :: "authorization: Bearer "
OPENAI_INCLUDE_REASONING :: `"include":["reasoning.encrypted_content"]`
OPENAI_EVENT_CREATED :: "response.created"
OPENAI_EVENT_ITEM_ADDED :: "response.output_item.added"
OPENAI_EVENT_ITEM_DONE :: "response.output_item.done"
OPENAI_EVENT_TEXT_DELTA :: "response.output_text.delta"
OPENAI_EVENT_REFUSAL_DELTA :: "response.refusal.delta"
OPENAI_EVENT_ARGS_DELTA :: "response.function_call_arguments.delta"
OPENAI_EVENT_SUMMARY_DELTA :: "response.reasoning_summary_text.delta"
OPENAI_EVENT_REASONING_DELTA :: "response.reasoning_text.delta"
OPENAI_EVENT_COMPLETED :: "response.completed"
OPENAI_EVENT_INCOMPLETE :: "response.incomplete"
OPENAI_EVENT_FAILED :: "response.failed"
OPENAI_EVENT_ERROR :: "error"
OPENAI_CHAT_DONE :: "[DONE]"
OPENAI_LONG_CONTEXT_TOKENS :: 272_000

HEADER_RETRY_AFTER :: "retry-after"
HEADER_RETRY_AFTER_MS :: "retry-after-ms"
HEADER_SHOULD_RETRY :: "x-should-retry"
HEADER_REQUEST_ID :: "request-id"
HEADER_X_REQUEST_ID :: "x-request-id"
HEADER_CONTENT_TYPE :: "content-type"
CONTENT_TYPE_JSON :: "content-type: application/json"
ACCEPT_SSE :: "accept: text/event-stream"
SSE_MEDIA_TYPE :: "text/event-stream"

RETRYABLE_STATUS :: [?]int{408, 409, 425, 429, 500, 502, 503, 504, 520, 522, 524, 529}

COMPACT_PROMPT :: "The conversation so far is about to be replaced by a summary because it is approaching the context limit. Write that summary now. Do not call any tools. Preserve, in order: the user's goals and every explicit instruction or constraint; decisions made and why; the current state of the work, including files, identifiers, commands and results that later steps depend on; tool calls whose results still matter and what they returned; open questions; and the exact next steps. Quote the most recent user request verbatim. Be complete but dense; omit pleasantries."
COMPACT_PREAMBLE :: "This conversation was compacted. Summary of everything before this point:\n\n"
COMPACT_RESUME :: "\n\nContinue the work from where it left off."

CHARS_PER_TOKEN :: 3

@(rodata)
MODELS := [?]Spec {
	{
		id = "claude-fable-5-2",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive_Always,
		default_effort = .High,
		min_cache_tokens = 512,
		price = {input = 8, output = 40, cache_read = 0.20, cache_write = 10, cache_write2 = 16},
		server_fallback = true,
		system_messages = true,
		forced_tool_error = true,
	},
	{
		id = "claude-opus-5-5",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive_Always,
		default_effort = .Medium,
		min_cache_tokens = 512,
		price = {input = 4, output = 20, cache_read = 0.20, cache_write = 5, cache_write2 = 8},
		server_fallback = true,
		system_messages = true,
		forced_tool_error = true,
	},
	{
		id = "claude-sonnet-5-5",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive,
		default_effort = .High,
		min_cache_tokens = 512,
		price = {input = 2, output = 10, cache_read = 0.10, cache_write = 2.50, cache_write2 = 4},
		server_fallback = true,
		system_messages = true,
		forced_tool_error = true,
	},
	{
		id = "claude-haiku-5-5",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive,
		default_effort = .Medium,
		min_cache_tokens = 512,
		price = {input = 0.10, output = 0.50, cache_read = 0.01, cache_write = 0.125, cache_write2 = 0.20},
		long_threshold = 100_000,
		long_price = {input = 0.50, output = 2.50, cache_read = 0.05, cache_write = 0.625, cache_write2 = 1},
		system_messages = true,
	},
	{
		id = "claude-opus-5",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive,
		default_effort = .High,
		min_cache_tokens = 512,
		price = {input = 5, output = 25, cache_read = 0.50, cache_write = 6.25, cache_write2 = 10},
		server_fallback = true,
		system_messages = true,
	},
	{
		id = "claude-sonnet-5",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive,
		default_effort = .High,
		min_cache_tokens = 1024,
		price = {input = 2, output = 10, cache_read = 0.20, cache_write = 2.50, cache_write2 = 4},
	},
	{
		id = "claude-opus-4-8",
		api = .Anthropic,
		context_window = 1_000_000,
		max_output = 128_000,
		thinking = .Adaptive,
		default_effort = .High,
		min_cache_tokens = 1024,
		price = {input = 5, output = 25, cache_read = 0.50, cache_write = 6.25, cache_write2 = 10},
		system_messages = true,
	},
	{
		id = "claude-haiku-4-5",
		api = .Anthropic,
		context_window = 200_000,
		max_output = 64_000,
		thinking = .Budget,
		min_cache_tokens = 4096,
		price = {input = 1, output = 5, cache_read = 0.10, cache_write = 1.25, cache_write2 = 2},
	},
	{
		id = "gpt-6.2-astra",
		api = .OpenAI_Responses,
		context_window = 1_050_000,
		max_output = 128_000,
		thinking = .Adaptive_Always,
		min_cache_tokens = 1024,
		price = {input = 8, output = 40, cache_read = 0.40, cache_write = 10, cache_write2 = 20},
		long_threshold = OPENAI_LONG_CONTEXT_TOKENS,
		long_price = {input = 16, output = 60, cache_read = 0.80, cache_write = 20, cache_write2 = 40},
		explicit_cache = true,
	},
	{
		id = "gpt-6.2-sol",
		api = .OpenAI_Responses,
		context_window = 1_050_000,
		max_output = 128_000,
		thinking = .Adaptive_Always,
		min_cache_tokens = 1024,
		price = {input = 2, output = 10, cache_read = 0.10, cache_write = 2.50, cache_write2 = 5},
		long_threshold = OPENAI_LONG_CONTEXT_TOKENS,
		long_price = {input = 4, output = 15, cache_read = 0.20, cache_write = 5, cache_write2 = 10},
		explicit_cache = true,
	},
	{
		id = "gpt-6-luna",
		api = .OpenAI_Responses,
		context_window = 1_050_000,
		max_output = 128_000,
		thinking = .Adaptive,
		min_cache_tokens = 1024,
		price = {input = 0.10, output = 0.50, cache_read = 0.01, cache_write = 0.125, cache_write2 = 0.25},
		long_threshold = OPENAI_LONG_CONTEXT_TOKENS,
		long_price = {input = 0.20, output = 0.75, cache_read = 0.02, cache_write = 0.25, cache_write2 = 0.50},
		explicit_cache = true,
	},
}

DEFAULT_ANTHROPIC_MODEL :: "claude-opus-5-5"
DEFAULT_OPENAI_MODEL :: "gpt-6.2-astra"

spec_lookup :: proc(id: string) -> (Spec, bool) {
	for s in MODELS {
		if s.id == id {
			return s, true
		}
	}
	return {}, false
}

effort_name :: proc(e: Effort) -> string {
	switch e {
	case .Default:
		return ""
	case .None:
		return "none"
	case .Minimal:
		return "minimal"
	case .Low:
		return "low"
	case .Medium:
		return "medium"
	case .High:
		return "high"
	case .Xhigh:
		return "xhigh"
	case .Max:
		return "max"
	}
	return ""
}

effort_from_name :: proc(s: string) -> Effort {
	for e in Effort {
		if effort_name(e) == s && s != "" {
			return e
		}
	}
	return .Default
}
