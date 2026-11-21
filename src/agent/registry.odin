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
}

Registry :: struct {
	list:      [dynamic]Provider_Descriptor,
	allocator: mem.Allocator,
}

@(private, rodata)
ARGV_CLAUDE := [?]string{"claude"}

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
	return out, .None
}

@(private)
drop_descriptor :: proc(desc: ^Provider_Descriptor, allocator: mem.Allocator) {
	delete(desc.id, allocator)
	delete(desc.name, allocator)
	drop_strings(desc.argv, allocator)
	drop_strings(desc.env, allocator)
	drop_strings(desc.client_meta, allocator)
	desc^ = {}
}
