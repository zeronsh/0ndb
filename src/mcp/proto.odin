package mcp

Version :: enum u8 {
	None,
	V2024_11_05,
	V2025_03_26,
	V2025_06_18,
	V2025_11_25,
	V2026_07_28,
}

@(rodata)
VERSION_NAMES := [Version]string {
	.None        = "",
	.V2024_11_05 = "2024-11-05",
	.V2025_03_26 = "2025-03-26",
	.V2025_06_18 = "2025-06-18",
	.V2025_11_25 = "2025-11-25",
	.V2026_07_28 = "2026-07-28",
}

LATEST_VERSION :: Version.V2026_07_28
LATEST_LEGACY_VERSION :: Version.V2025_11_25
FIRST_MODERN_VERSION :: Version.V2026_07_28

Versions :: bit_set[Version;u8]

ALL_VERSIONS :: Versions{.V2024_11_05, .V2025_03_26, .V2025_06_18, .V2025_11_25, .V2026_07_28}

version_parse :: proc "contextless" (s: string) -> Version {
	for v in Version {
		if v != .None && VERSION_NAMES[v] == s {
			return v
		}
	}
	return .None
}

version_name :: proc "contextless" (v: Version) -> string {
	return VERSION_NAMES[v]
}

version_modern :: proc "contextless" (v: Version) -> bool {
	return v >= FIRST_MODERN_VERSION
}

version_best :: proc "contextless" (set: Versions, modern: bool) -> Version {
	for i := int(max(Version)); i > 0; i -= 1 {
		v := Version(i)
		if v in set && version_modern(v) == modern {
			return v
		}
	}
	return .None
}

JSONRPC_PARSE_ERROR :: -32700
JSONRPC_INVALID_REQUEST :: -32600
JSONRPC_METHOD_NOT_FOUND :: -32601
JSONRPC_INVALID_PARAMS :: -32602
JSONRPC_INTERNAL_ERROR :: -32603
MCP_LEGACY_RESOURCE_NOT_FOUND :: -32002
MCP_LEGACY_URL_ELICITATION_REQUIRED :: -32042
MCP_HEADER_MISMATCH :: -32020
MCP_MISSING_CLIENT_CAPABILITY :: -32021
MCP_UNSUPPORTED_VERSION :: -32022

META_PROTOCOL_VERSION :: "io.modelcontextprotocol/protocolVersion"
META_CLIENT_INFO :: "io.modelcontextprotocol/clientInfo"
META_CLIENT_CAPABILITIES :: "io.modelcontextprotocol/clientCapabilities"
META_LOG_LEVEL :: "io.modelcontextprotocol/logLevel"
META_SERVER_INFO :: "io.modelcontextprotocol/serverInfo"
META_SUBSCRIPTION_ID :: "io.modelcontextprotocol/subscriptionId"

Log_Level :: enum u8 {
	None,
	Debug,
	Info,
	Notice,
	Warning,
	Error,
	Critical,
	Alert,
	Emergency,
}

@(rodata)
LOG_LEVEL_NAMES := [Log_Level]string {
	.None      = "",
	.Debug     = "debug",
	.Info      = "info",
	.Notice    = "notice",
	.Warning   = "warning",
	.Error     = "error",
	.Critical  = "critical",
	.Alert     = "alert",
	.Emergency = "emergency",
}

log_level_parse :: proc "contextless" (s: string) -> Log_Level {
	for l in Log_Level {
		if l != .None && LOG_LEVEL_NAMES[l] == s {
			return l
		}
	}
	return .None
}

Implementation :: struct {
	name:        string,
	version:     string,
	title:       string,
	description: string,
	website_url: string,
	icons:       string,
}

write_implementation :: proc(b: ^Buf, impl: Implementation) {
	w_sep(b)
	append(b, '{')
	f_str(b, "name", impl.name if impl.name != "" else "ondb")
	f_str(b, "version", impl.version if impl.version != "" else "0.0.0")
	if impl.title != "" {
		f_str(b, "title", impl.title)
	}
	if impl.description != "" {
		f_str(b, "description", impl.description)
	}
	if impl.website_url != "" {
		f_str(b, "websiteUrl", impl.website_url)
	}
	if impl.icons != "" {
		f_raw(b, "icons", impl.icons)
	}
	append(b, '}')
}

Client_Cap :: enum u8 {
	Roots,
	Roots_List_Changed,
	Sampling,
	Sampling_Context,
	Sampling_Tools,
	Elicitation_Form,
	Elicitation_Url,
}

Client_Caps :: bit_set[Client_Cap;u16]

Client_Capabilities :: struct {
	caps:         Client_Caps,
	extensions:   string,
	experimental: string,
}

write_client_capabilities :: proc(b: ^Buf, c: Client_Capabilities, version: Version) {
	w_sep(b)
	append(b, '{')
	if c.experimental != "" {
		f_raw(b, "experimental", c.experimental)
	}
	if .Roots in c.caps {
		f_obj(b, "roots")
		if .Roots_List_Changed in c.caps && !version_modern(version) {
			f_bool(b, "listChanged", true)
		}
		w_close(b)
	}
	if .Sampling in c.caps {
		f_obj(b, "sampling")
		if version >= .V2025_11_25 {
			if .Sampling_Context in c.caps {
				f_raw(b, "context", "{}")
			}
			if .Sampling_Tools in c.caps {
				f_raw(b, "tools", "{}")
			}
		}
		w_close(b)
	}
	if c.caps & {.Elicitation_Form, .Elicitation_Url} != {} && version >= .V2025_06_18 {
		f_obj(b, "elicitation")
		if version >= .V2025_11_25 {
			if .Elicitation_Form in c.caps {
				f_raw(b, "form", "{}")
			}
			if .Elicitation_Url in c.caps {
				f_raw(b, "url", "{}")
			}
		}
		w_close(b)
	}
	if c.extensions != "" && version_modern(version) {
		f_raw(b, "extensions", c.extensions)
	}
	append(b, '}')
}

read_client_capabilities :: proc(raw: string) -> (c: Client_Capabilities) {
	if r, ok := json_get_object(raw, "roots"); ok {
		c.caps += {.Roots}
		if json_get_bool(r, "listChanged") {
			c.caps += {.Roots_List_Changed}
		}
	}
	if s, ok := json_get_object(raw, "sampling"); ok {
		c.caps += {.Sampling}
		if json_has(s, "context") {
			c.caps += {.Sampling_Context}
		}
		if json_has(s, "tools") {
			c.caps += {.Sampling_Tools}
		}
	}
	if e, ok := json_get_object(raw, "elicitation"); ok {
		form := json_has(e, "form")
		url := json_has(e, "url")
		if form || !url {
			c.caps += {.Elicitation_Form}
		}
		if url {
			c.caps += {.Elicitation_Url}
		}
	}
	if x, ok := json_get_object(raw, "extensions"); ok {
		c.extensions = x
	}
	if x, ok := json_get_object(raw, "experimental"); ok {
		c.experimental = x
	}
	return
}

Server_Cap :: enum u8 {
	Tools,
	Tools_List_Changed,
	Resources,
	Resources_Subscribe,
	Resources_List_Changed,
	Prompts,
	Prompts_List_Changed,
	Logging,
	Completions,
}

Server_Caps :: bit_set[Server_Cap;u16]

Server_Capabilities :: struct {
	caps:         Server_Caps,
	extensions:   string,
	experimental: string,
}

write_server_capabilities :: proc(b: ^Buf, c: Server_Capabilities, version: Version) {
	w_sep(b)
	append(b, '{')
	if c.experimental != "" {
		f_raw(b, "experimental", c.experimental)
	}
	if .Logging in c.caps {
		f_raw(b, "logging", "{}")
	}
	if .Completions in c.caps && version >= .V2025_03_26 {
		f_raw(b, "completions", "{}")
	}
	if .Prompts in c.caps {
		f_obj(b, "prompts")
		if .Prompts_List_Changed in c.caps {
			f_bool(b, "listChanged", true)
		}
		w_close(b)
	}
	if .Resources in c.caps {
		f_obj(b, "resources")
		if .Resources_Subscribe in c.caps {
			f_bool(b, "subscribe", true)
		}
		if .Resources_List_Changed in c.caps {
			f_bool(b, "listChanged", true)
		}
		w_close(b)
	}
	if .Tools in c.caps {
		f_obj(b, "tools")
		if .Tools_List_Changed in c.caps {
			f_bool(b, "listChanged", true)
		}
		w_close(b)
	}
	if c.extensions != "" && version_modern(version) {
		f_raw(b, "extensions", c.extensions)
	}
	append(b, '}')
}

read_server_capabilities :: proc(raw: string) -> (c: Server_Capabilities) {
	if t, ok := json_get_object(raw, "tools"); ok {
		c.caps += {.Tools}
		if json_get_bool(t, "listChanged") {
			c.caps += {.Tools_List_Changed}
		}
	}
	if r, ok := json_get_object(raw, "resources"); ok {
		c.caps += {.Resources}
		if json_get_bool(r, "subscribe") {
			c.caps += {.Resources_Subscribe}
		}
		if json_get_bool(r, "listChanged") {
			c.caps += {.Resources_List_Changed}
		}
	}
	if p, ok := json_get_object(raw, "prompts"); ok {
		c.caps += {.Prompts}
		if json_get_bool(p, "listChanged") {
			c.caps += {.Prompts_List_Changed}
		}
	}
	if json_has(raw, "logging") {
		c.caps += {.Logging}
	}
	if json_has(raw, "completions") {
		c.caps += {.Completions}
	}
	if x, ok := json_get_object(raw, "extensions"); ok {
		c.extensions = x
	}
	if x, ok := json_get_object(raw, "experimental"); ok {
		c.experimental = x
	}
	return
}

Message_Kind :: enum u8 {
	Invalid,
	Request,
	Notification,
	Result,
	Error,
}

Message :: struct {
	kind:   Message_Kind,
	id:     string,
	method: string,
	params: string,
	result: string,
	error:  string,
	raw:    string,
}

message_parse :: proc(raw: string) -> (m: Message, parse_ok: bool) {
	m.raw = raw
	if !json_valid(raw) {
		return m, false
	}
	if json_kind(raw) != .Object {
		return m, true
	}
	it, _ := json_object(raw)
	has_id, has_method, has_result, has_error, versioned := false, false, false, false, false
	for k, v in json_next_member(&it) {
		switch {
		case json_key_is(k, "jsonrpc"):
			s, ok := json_string(v)
			versioned = ok && s == "2.0"
		case json_key_is(k, "id"):
			kd := json_kind(v)
			if kd == .String || kd == .Number {
				m.id = json_trim(v)
				has_id = true
			} else if kd == .Null {
				m.id = "null"
			}
		case json_key_is(k, "method"):
			s, ok := json_string(v)
			if ok {
				m.method = s
				has_method = true
			}
		case json_key_is(k, "params"):
			m.params = json_trim(v)
		case json_key_is(k, "result"):
			m.result = json_trim(v)
			has_result = true
		case json_key_is(k, "error"):
			m.error = json_trim(v)
			has_error = true
		}
	}
	if !versioned {
		return m, true
	}
	switch {
	case has_method && has_id:
		m.kind = .Request
	case has_method && m.id == "":
		m.kind = .Notification
	case has_result && has_id && !has_error:
		m.kind = .Result
	case has_error && !has_result:
		m.kind = .Error
	}
	if m.params != "" {
		k := json_kind(m.params)
		if k != .Object && k != .Array {
			m.kind = .Invalid
		}
	}
	return m, true
}

error_code :: proc(err: string) -> i64 {
	c, _ := json_get_int(err, "code")
	return c
}

error_message :: proc(err: string) -> string {
	s, _ := json_get_string(err, "message")
	return s
}

write_response_result :: proc(b: ^Buf, id: string, result: string) {
	append(b, `{"jsonrpc":"2.0","id":`)
	append(b, id)
	append(b, `,"result":`)
	append(b, result)
	append(b, '}')
}

write_response_error :: proc(b: ^Buf, id: string, code: i64, message: string, data := "") {
	append(b, `{"jsonrpc":"2.0"`)
	if id != "" {
		append(b, `,"id":`)
		append(b, id)
	}
	append(b, `,"error":{"code":`)
	w_int(b, code)
	f_str(b, "message", message)
	if data != "" {
		f_raw(b, "data", data)
	}
	append(b, "}}")
}

write_notification :: proc(b: ^Buf, method: string, params: string) {
	append(b, `{"jsonrpc":"2.0","method":`)
	w_str(b, method)
	if params != "" {
		append(b, `,"params":`)
		append(b, params)
	}
	append(b, '}')
}

meta_key_valid :: proc "contextless" (key: string) -> bool {
	slash := -1
	for i in 0 ..< len(key) {
		if key[i] == '/' {
			slash = i
			break
		}
	}
	name := key
	if slash >= 0 {
		prefix := key[:slash]
		name = key[slash + 1:]
		if len(prefix) == 0 {
			return false
		}
		start := 0
		for i in 0 ..= len(prefix) {
			if i < len(prefix) && prefix[i] != '.' {
				continue
			}
			label := prefix[start:i]
			if len(label) == 0 || !_alpha(label[0]) || !_alnum(label[len(label) - 1]) {
				return false
			}
			for c in transmute([]u8)label {
				if !_alnum(c) && c != '-' {
					return false
				}
			}
			start = i + 1
		}
	}
	if len(name) == 0 {
		return true
	}
	if !_alnum(name[0]) || !_alnum(name[len(name) - 1]) {
		return false
	}
	for c in transmute([]u8)name {
		if !_alnum(c) && c != '-' && c != '_' && c != '.' {
			return false
		}
	}
	return true
}

@(private)
_alpha :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
_alnum :: proc "contextless" (c: u8) -> bool {
	return _alpha(c) || (c >= '0' && c <= '9')
}
