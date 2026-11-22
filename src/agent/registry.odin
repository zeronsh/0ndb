package agent

import "core:mem"
import "core:strings"

Protocol :: enum u8 {
	Claude_Stream_Json,
	Codex_App_Server,
	Pi_Rpc,
	Muse,
	Acp,
}

Steer_Hint :: enum u8 {
	Auto,
	Cancel,
	Concurrent,
	Supersede,
	Command,
}

Store :: enum u8 {
	None,
	Claude_Projects,
	Codex_Rollouts,
	Pi_Sessions,
	Muse_Sessions,
	OpenCode_Cli,
	Hermes_Cli,
	Cursor_Chats,
	Antigravity_Conversations,
}

Seed_Style :: enum u8 {
	Markdown,
	Xml,
}

Provider_Descriptor :: struct {
	id:           string,
	name:         string,
	argv:         []string,
	protocol:     Protocol,
	capabilities: Capabilities,
	env:          []string,
	steer:        Steer_Hint,
	client_meta:  []string,
	undo:         bool,
	store:        Store,
	seed_style:   Seed_Style,
	seed_budget:  int,
	auth_env:     []string,
	auth_files:   []Auth_Probe,
}

Auth_Probe :: struct {
	path:     string,
	contains: string,
}

Registry :: struct {
	list:      [dynamic]Provider_Descriptor,
	allocator: mem.Allocator,
}

@(private, rodata)
ARGV_CLAUDE := [?]string{"claude"}

@(private, rodata)
AUTH_ENV_CLAUDE := [?]string{"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"}

@(private, rodata)
AUTH_FILES_CLAUDE := [?]Auth_Probe{{".claude/.credentials.json", ""}, {".claude.json", "\"oauthAccount\""}}

@(private, rodata)
AUTH_ENV_CODEX := [?]string{"OPENAI_API_KEY", "CODEX_API_KEY"}

@(private, rodata)
AUTH_FILES_CODEX := [?]Auth_Probe{{".codex/auth.json", ""}}

@(private, rodata)
AUTH_ENV_PI := [?]string{"ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY"}

@(private, rodata)
AUTH_FILES_PI := [?]Auth_Probe{{".pi/agent/auth.json", ""}}

@(private, rodata)
AUTH_ENV_CURSOR := [?]string{"CURSOR_API_KEY"}

@(private, rodata)
AUTH_FILES_CURSOR := [?]Auth_Probe{{".cursor/cli-config.json", "\"authInfo\""}}

@(private, rodata)
AUTH_FILES_OPENCODE := [?]Auth_Probe{{".local/share/opencode/auth.json", ""}}

@(private, rodata)
ARGV_CODEX := [?]string{"codex", "app-server"}

@(private, rodata)
ARGV_PI := [?]string{"pi"}

@(private, rodata)
ARGV_MUSE := [?]string{"muse", "serve"}

@(private, rodata)
ARGV_CURSOR := [?]string{"cursor-agent", "acp"}

@(private, rodata)
ARGV_DEVIN := [?]string{"devin", "acp", "--process-model", "in-process"}

@(private, rodata)
META_DEVIN := [?]string{"cognition.ai/revert", "cognition.ai/revertByUserMessageId"}

@(private, rodata)
ARGV_HERMES := [?]string{"hermes", "acp"}

@(private, rodata)
ARGV_OPENCODE := [?]string{"opencode", "acp"}

when ODIN_OS == .Linux {
	@(private, rodata)
	ARGV_AGY := [?]string{"agy_acp_server", "--uid="}
} else {
	@(private, rodata)
	ARGV_AGY := [?]string{"agy_acp_server"}
}

builtin :: proc(p: Provider) -> Provider_Descriptor {
	switch p {
	case .Claude:
		return {
			id = "claude",
			name = "Claude Code",
			argv = ARGV_CLAUDE[:],
			protocol = .Claude_Stream_Json,
			capabilities = {.Native_Steer, .Resume, .Fork_At_Message, .Persistent, .List_Models, .Images, .Files},
			store = .Claude_Projects,
			seed_style = .Xml,
			seed_budget = 120_000,
			auth_env = AUTH_ENV_CLAUDE[:],
			auth_files = AUTH_FILES_CLAUDE[:],
		}
	case .Codex:
		return {
			id = "codex",
			name = "Codex",
			argv = ARGV_CODEX[:],
			protocol = .Codex_App_Server,
			capabilities = {.Native_Steer, .Resume, .Fork_At_Message, .Persistent, .List_Models, .Images},
			store = .Codex_Rollouts,
			seed_budget = 120_000,
			auth_env = AUTH_ENV_CODEX[:],
			auth_files = AUTH_FILES_CODEX[:],
		}
	case .Pi:
		return {
			id = "pi",
			name = "Pi",
			argv = ARGV_PI[:],
			protocol = .Pi_Rpc,
			capabilities = {.Native_Steer, .Resume, .Fork_At_Message, .Persistent, .List_Models, .Images},
			store = .Pi_Sessions,
			seed_budget = 80_000,
			auth_env = AUTH_ENV_PI[:],
			auth_files = AUTH_FILES_PI[:],
		}
	case .Muse:
		return {
			id = "muse",
			name = "Muse",
			argv = ARGV_MUSE[:],
			protocol = .Muse,
			capabilities = {.Native_Steer, .Resume, .Fork_At_Message, .Persistent, .List_Models, .Images},
			store = .Muse_Sessions,
			seed_budget = 120_000,
		}
	case .Antigravity:
		return {
			id = "antigravity",
			name = "Antigravity",
			argv = ARGV_AGY[:],
			protocol = .Acp,
			capabilities = {.Resume, .Persistent, .List_Models, .Images, .Files},
			steer = .Cancel,
			store = .Antigravity_Conversations,
			seed_budget = 80_000,
		}
	case .Cursor:
		return {
			id = "cursor",
			name = "Cursor",
			argv = ARGV_CURSOR[:],
			protocol = .Acp,
			capabilities = {.Native_Steer, .Resume, .Persistent, .List_Models, .Images, .Files},
			steer = .Supersede,
			store = .Cursor_Chats,
			seed_budget = 60_000,
			auth_env = AUTH_ENV_CURSOR[:],
			auth_files = AUTH_FILES_CURSOR[:],
		}
	case .Devin:
		return {
			id = "devin",
			name = "Devin",
			argv = ARGV_DEVIN[:],
			protocol = .Acp,
			capabilities = {.Native_Steer, .Resume, .Fork_At_Message, .Persistent, .List_Models, .Images, .Files},
			client_meta = META_DEVIN[:],
			seed_budget = 80_000,
		}
	case .Hermes:
		return {
			id = "hermes",
			name = "Hermes",
			argv = ARGV_HERMES[:],
			protocol = .Acp,
			capabilities = {.Native_Steer, .Resume, .Fork_At_Message, .Persistent, .List_Models, .Images, .Files},
			steer = .Command,
			undo = true,
			store = .Hermes_Cli,
			seed_budget = 80_000,
		}
	case .OpenCode:
		return {
			id = "opencode",
			name = "OpenCode",
			argv = ARGV_OPENCODE[:],
			protocol = .Acp,
			capabilities = {.Native_Steer, .Resume, .Persistent, .List_Models, .Images, .Files},
			steer = .Concurrent,
			store = .OpenCode_Cli,
			seed_budget = 60_000,
			auth_files = AUTH_FILES_OPENCODE[:],
		}
	}
	return {}
}

registry_init :: proc(r: ^Registry, allocator := context.allocator) {
	r.allocator = allocator
	r.list = make([dynamic]Provider_Descriptor, allocator)
	for p in Provider {
		register(r, builtin(p))
	}
}

registry_destroy :: proc(r: ^Registry) {
	for &desc in r.list {
		drop_descriptor(&desc, r.allocator)
	}
	delete(r.list)
	r^ = {}
}

register :: proc(r: ^Registry, desc: Provider_Descriptor) -> Error {
	if desc.id == "" || len(desc.argv) == 0 {
		return .Invalid_Descriptor
	}
	owned, err := clone_descriptor(desc, r.allocator)
	if err != .None {
		return err
	}
	for &existing in r.list {
		if existing.id == desc.id {
			drop_descriptor(&existing, r.allocator)
			existing = owned
			return .None
		}
	}
	append(&r.list, owned)
	return .None
}

lookup :: proc(r: ^Registry, id: string) -> (Provider_Descriptor, bool) {
	for desc in r.list {
		if desc.id == id {
			return desc, true
		}
	}
	if p, ok := provider_from_name(id); ok {
		for desc in r.list {
			if desc.id == provider_name(p) {
				return desc, true
			}
		}
	}
	return {}, false
}

@(private)
clone_strings :: proc(list: []string, allocator: mem.Allocator) -> ([]string, Error) {
	if len(list) == 0 {
		return nil, .None
	}
	out, err := make([]string, len(list), allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	for s, i in list {
		out[i] = strings.clone(s, allocator)
	}
	return out, .None
}

@(private)
drop_strings :: proc(list: []string, allocator: mem.Allocator) {
	for s in list {
		delete(s, allocator)
	}
	delete(list, allocator)
}

@(private)
clone_descriptor :: proc(desc: Provider_Descriptor, allocator: mem.Allocator) -> (Provider_Descriptor, Error) {
	out := desc
	out.id = strings.clone(desc.id, allocator)
	out.name = strings.clone(desc.name, allocator)
	err: Error
	if out.argv, err = clone_strings(desc.argv, allocator); err != .None {
		return {}, err
	}
	if out.env, err = clone_strings(desc.env, allocator); err != .None {
		return {}, err
	}
	if out.client_meta, err = clone_strings(desc.client_meta, allocator); err != .None {
		return {}, err
	}
	if out.auth_env, err = clone_strings(desc.auth_env, allocator); err != .None {
		return {}, err
	}
	out.auth_files = nil
	if len(desc.auth_files) > 0 {
		files, merr := make([]Auth_Probe, len(desc.auth_files), allocator)
		if merr != nil {
			return {}, .Out_Of_Memory
		}
		for f, i in desc.auth_files {
			files[i] = Auth_Probe{strings.clone(f.path, allocator), strings.clone(f.contains, allocator)}
		}
		out.auth_files = files
	}
	return out, .None
}

@(private)
drop_descriptor :: proc(desc: ^Provider_Descriptor, allocator: mem.Allocator) {
	delete(desc.id, allocator)
	delete(desc.name, allocator)
	drop_strings(desc.argv, allocator)
	drop_strings(desc.env, allocator)
	drop_strings(desc.client_meta, allocator)
	drop_strings(desc.auth_env, allocator)
	for f in desc.auth_files {
		delete(f.path, allocator)
		delete(f.contains, allocator)
	}
	delete(desc.auth_files, allocator)
	desc^ = {}
}
