package main

import "core:fmt"
import "core:os"
import "core:strings"
import "../capi/api"
import "../prim"

VERSION :: "0.1.0"

Exit :: enum int {
	Ok        = 0,
	Error     = 1,
	Usage     = 2,
	Not_Found = 3,
	Daemon    = 4,
	Offline   = 5,
	Conflict  = 6,
	Denied    = 7,
}

Args :: struct {
	pos:   [dynamic]string,
	flags: map[string]string,
	json:  bool,
}

BOOL_FLAGS :: []string{"json", "follow", "all", "archived", "dry", "semantic", "stdin", "no-runner", "open", "allow", "deny", "fresh", "diff", "help", "version", "recursive", "quiet", "wait", "newest", "write", "refresh", "preview", "local", "everywhere", "no-full-index", "replace", "always-on", "device-only"}

Command :: struct {
	name:  string,
	run:   proc(a: ^Args) -> int,
	usage: string,
	help:  string,
}

COMMANDS := []Command {
	{"daemon", cmd_daemon, "daemon [start|stop] [--host-plugs LIST] [--no-runner] [--no-full-index] [--storage auto|stored|until-run|device] [--capacity N] [--content-budget BYTES] [--always-on] [--holder-budget BYTES] [--provider P] [--model M] [--name NAME] [--pool-host]", "run the device daemon in the foreground (engine, runtime, local socket), or start it detached and wait until it serves (start passes its flags through); --name is this runner's name in device switchers (default: the host name); --host-plugs names the plugs (sealed_store, unlock, credentials, scheduler, runner_pool or pool_user) a host connection supplies over the socket instead of the built-in references; --no-runner keeps this device from executing runs, so its messages wait for another runner; --no-full-index keeps it from indexing every conversation of its spaces and answering other devices' searches; --content-budget sets how many bytes of large non-git content a space keeps on the relay; --always-on makes this device hold the content its spaces keep off the relay (up to --holder-budget bytes, default 8 GiB) and serve it to other devices"},
	{"host", cmd_host, "host [token] [--plugs LIST] [--store DIR] [--passkey FILE] [--credentials-dir DIR] [--pool-card HEX] [--replace] [--json] [--quiet]", "reference host: register with the daemon and answer its plug requests (file account store, software passkey, runner-pool launch tokens, static relay credentials), reconnecting when the daemon restarts; token prints a runner launch token for --plugs runner_pool"},
	{"relay", cmd_relay, "relay [--listen ADDR]... [--dir DIR] [--open] [--quota BYTES]", "run a relay on files/pack, serving TCP with kernel TLS and Unix sockets"},
	{"runner", cmd_runner, "runner [--pool-token TOKEN] [--capacity N]", "run a dedicated runner engine in the foreground; with a launch token from a pool host (ONDB_POOL_HOST_SOCK) it enrolls through the pool"},
	{"record", cmd_record, "record [CONVO] --source S --id EXTERNAL_ID [--seq N] [--role R] [--status S] [--model M] [TEXT|--stdin]", "record a message from an external harness (idempotent)"},
	{"mcp", cmd_mcp, "mcp [CONVO]", "serve the 0ndb orchestration catalog over stdio MCP"},
	{"login", cmd_login, "login [--subject ID] [--relay ADDR --relay-key HEX] [--cross-device] [--recovery KEY] [--wait SECONDS]", "sign this device in (optional: without it 0ndb runs local-only, every feature that needs no other device works): a passkey on this device, else approval from a signed-in device (0ndb approve), else a passkey from another device; enrolls the device into every account space and brings existing local spaces into the account with their history"},
	{"logout", cmd_logout, "logout [--keep-relay]", "sign this device out; every space stays complete on this device and keeps working local-only"},
	{"approve", cmd_approve, "approve [CODE] [--deny]", "list devices waiting to sign in, or approve one by its code"},
	{"devices", cmd_devices, "devices [remove DEVICE | forget-passkey CREDENTIAL]", "list this account's devices, runners and passkeys; remove a device (every space starts a new key epoch without it)"},
	{"members", cmd_members, "members [--space S]", "list a space's members, how each enrolled, and the current key epoch"},
	{"remove", cmd_remove, "remove DEVICE [--space S]", "remove a device from every space (or one space) and start a new key epoch"},
	{"leave", cmd_leave, "leave SPACE [--device-only]", "leave a shared space: remove your devices from it and erase its local copies once the relay has the removal"},
	{"rotate", cmd_rotate, "rotate [--space S]", "start a new key epoch now (after a suspected compromise)"},
	{"recovery-key", cmd_recovery_key, "recovery-key", "create the account recovery key (settings; login --recovery uses it with no other device online)"},
	{"pool", cmd_pool, "pool token | on | off [--space S]", "print a runner launch token (pool host), or include or remove cloud runners for a space"},
	{"pair", cmd_pair, "pair DEVICE-CODE [--space S] [--relay ADDR --relay-key HEX]", "fallback: add a device by the code its 0ndb join prints, and print a join ticket for it"},
	{"join", cmd_join, "join [TICKET] [--name NAME]", "fallback: print this device's code, or join a space from a ticket printed by 0ndb pair"},
	{"status", cmd_status, "status", "show the daemon, device, spaces and mounts"},
	{"ls", cmd_ls, "ls [--all] [--archived] [--kind K] [--limit N]", "list objects in the default space"},
	{"new", cmd_new, "new [TITLE] [--agent A] [--workspace W] [--parent P] [--provider P] [--model M] [-m TEXT]", "create a conversation and make it current"},
	{"send", cmd_send, "send [CONVO] TEXT|--stdin [--parent MSG] [--provider P] [--model M] [--wait]", "send a message (starts a turn)"},
	{"queue", cmd_queue, "queue [CONVO] TEXT", "queue a message for after the running turn"},
	{"steer", cmd_steer, "steer [CONVO] TEXT", "steer the running turn"},
	{"edit", cmd_edit, "edit [CONVO] ITEM TEXT", "edit a queued message"},
	{"switch", cmd_switch, "switch [CONVO] SIBLING|next|prev [--preview] [-n N]", "switch to a sibling branch, or preview it without switching"},
	{"back", cmd_back, "back [CONVO] MSG", "go back to a message (restores mounted files)"},
	{"log", cmd_log, "log [CONVO] [-n N] [--follow] [--around MSG [--leaf MSG]] [--older CURSOR | --newer CURSOR]", "print a conversation, a window around a message, or one page from a cursor"},
	{"show", cmd_show, "show OBJECT|MSG [CONVO]", "show an object or a message"},
	{"search", cmd_search, "search QUERY [--limit N] [--semantic] [--newest] [--local | --everywhere]", "search this device's index and, by default when another device keeps a full index of the space, that index too; hits from other devices are fetched and verified locally"},
	{"interrupt", cmd_interrupt, "interrupt [CONVO]", "interrupt the running turn"},
	{"models", cmd_models, "models [--refresh]", "list harness providers with their live model lists, and native models"},
	{"agent", cmd_agent, "agent new NAME [--driver D] [--provider P] [--model M] [--instructions TEXT] | ls | show AGENT", "manage agents"},
	{"task", cmd_task, "task spawn|send|wait|ls|cancel|result|merge|status ... [--from CONVO]", "orchestrate tasks (the MCP catalog tools)"},
	{"workspace", cmd_workspace, "workspace new NAME | ls | show W | add W TREE [--mount NAME] [--path P]", "manage workspaces"},
	{"mount", cmd_mount, "mount DIR [--tree T] [--convo C] [--name NAME] | mount ls | mount rm DIR", "bind a directory to a file tree"},
	{"schedule", cmd_schedule, "schedule add OWNER PROMPT (--cron EXPR|--at TIME) [--tz Z] | ls | rm OWNER ID", "manage schedules"},
	{"runners", cmd_runners, "runners [CONVO] [--all]", "list the devices and pools a conversation can run on: * current, + last; state online, offline or wakeable; providers installed and signed in"},
	{"resume", cmd_resume, "resume [CONVO] RUNNER", "continue a conversation on another device or pool (by id, name or cloud); a turn cut off mid-flight continues there with full context"},
	{"takeover", cmd_takeover, "takeover [default|auto|never] [--workspace W | --agent A | --convo C]", "show or set whether work moves when its runner goes away: default (devices stay and the conversation goes idle; pool work waits for its runner, which the host wakes), auto (another runner continues) or never"},
	{"blame", cmd_blame, "blame FILE", "show who wrote each line of a mounted file"},
	{"revert", cmd_revert, "revert [CONVO] MSG", "undo exactly the file changes of one turn"},
	{"land", cmd_land, "land TREE|DIR --from LINE [--into LINE] [--dry]", "land one line of a file tree into another"},
	{"share", cmd_share, "share card | share OBJECT CARD [--write] | share accept CODE", "share an object with another device"},
	{"redact", cmd_redact, "redact [CONVO] MSG | redact text OBJECT POS LEN | redact key MAP KEY", "delete content everywhere, keeping ids"},
	{"verify", cmd_verify, "verify [DIR]", "check that mounted directories equal their history"},
}

main :: proc() {
	ignore_broken_pipes()
	code := run(os.args[1:])
	free_all(context.temp_allocator)
	os.exit(code)
}

run :: proc(argv: []string) -> int {
	a: Args
	a.flags = make(map[string]string)
	cmd := ""
	i := 0
	for i < len(argv) {
		x := argv[i]
		i += 1
		if x == "--" {
			for i < len(argv) {
				append(&a.pos, argv[i])
				i += 1
			}
			break
		}
		if strings.has_prefix(x, "--") || (len(x) == 2 && x[0] == '-' && x[1] != '-') {
			name := x[2:] if strings.has_prefix(x, "--") else x[1:]
			value := ""
			has_value := false
			if eq := strings.index_byte(name, '='); eq >= 0 {
				value = name[eq + 1:]
				name = name[:eq]
				has_value = true
			}
			switch name {
			case "n":
				name = "limit"
			case "m":
				name = "message"
			case "h":
				name = "help"
			case "j":
				name = "json"
			}
			is_bool := false
			for b in BOOL_FLAGS {
				is_bool ||= b == name
			}
			if !has_value {
				if is_bool {
					value = "true"
				} else {
					if i >= len(argv) {
						return usage_error("--%s needs a value", name)
					}
					value = argv[i]
					i += 1
				}
			}
			if name == "home" {
				os.set_env("ONDB_HOME", value)
				continue
			}
			a.flags[name] = value
			continue
		}
		if len(cmd) == 0 {
			cmd = x
		} else {
			append(&a.pos, x)
		}
	}
	a.json = flag_bool(&a, "json")
	if flag_bool(&a, "version") && len(cmd) == 0 {
		fmt.println("0ndb", VERSION)
		return 0
	}
	if len(cmd) == 0 || cmd == "help" {
		if len(a.pos) > 0 {
			for c in COMMANDS {
				if c.name == a.pos[0] {
					fmt.printfln("usage: 0ndb %s\n\n%s", c.usage, c.help)
					return 0
				}
			}
		}
		print_help()
		return 0 if cmd == "help" || flag_bool(&a, "help") else 2
	}
	for c in COMMANDS {
		if c.name == cmd {
			if flag_bool(&a, "help") {
				fmt.printfln("usage: 0ndb %s\n\n%s", c.usage, c.help)
				return 0
			}
			return c.run(&a)
		}
	}
	return usage_error("unknown command %q (see 0ndb help)", cmd)
}

print_help :: proc() {
	fmt.println("0ndb: durable, replicated agent state\n\nusage: 0ndb COMMAND [ARGS] [--json] [--home DIR] [--space ID] [--timeout MS]\n\ncommands:")
	for c in COMMANDS {
		fmt.printfln("  %-10s %s", c.name, c.help)
	}
	fmt.println("\nexit codes: 0 ok, 1 error, 2 usage, 3 not found, 4 daemon unavailable, 5 offline or timed out, 6 conflict, 7 denied")
	fmt.println("environment: ONDB_HOME (data directory), ONDB_RUNTIME_DIR (socket directory)")
}

flag_value :: proc(a: ^Args, name: string) -> (string, bool) {
	v, ok := a.flags[name]
	return v, ok
}

flag_string :: proc(a: ^Args, name: string, default_value := "") -> string {
	if v, ok := a.flags[name]; ok {
		return v
	}
	return default_value
}

flag_bool :: proc(a: ^Args, name: string) -> bool {
	v, ok := a.flags[name]
	return ok && v != "false" && v != "0"
}

exit_of :: proc(st: api.Status) -> int {
	#partial switch st {
	case .Ok:
		return int(Exit.Ok)
	case .Not_Found:
		return int(Exit.Not_Found)
	case .Invalid, .Bad_Request, .Unknown_Op:
		return int(Exit.Usage)
	case .Offline, .Timeout, .Pending, .Missing:
		return int(Exit.Offline)
	case .Conflict, .Exists:
		return int(Exit.Conflict)
	case .Permission, .Forged, .Quarantined:
		return int(Exit.Denied)
	case .Closed:
		return int(Exit.Daemon)
	}
	return int(Exit.Error)
}

report_error :: proc(st: api.Status, format: string, args: ..any) -> int {
	fmt.eprintf("0ndb: ")
	fmt.eprintf(format, ..args)
	if st != .Ok {
		fmt.eprintf(" (%s)", api.STATUS_NAMES[int(st)])
	}
	fmt.eprintln()
	return exit_of(st)
}

usage_error :: proc(format: string, args: ..any) -> int {
	fmt.eprintf("0ndb: ")
	fmt.eprintfln(format, ..args)
	return int(Exit.Usage)
}

Failure :: enum {
	Io,
	Daemon,
	Usage,
}

fail :: proc(kind: Failure, format: string, args: ..any) -> ! {
	fmt.eprintf("0ndb: ")
	fmt.eprintfln(format, ..args)
	switch kind {
	case .Io:
		os.exit(int(Exit.Error))
	case .Daemon:
		os.exit(int(Exit.Daemon))
	case .Usage:
		os.exit(int(Exit.Usage))
	}
	os.exit(1)
}

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

clone :: proc(s: string) -> string {
	return strings.clone(s)
}

clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

hex :: proc(id: prim.Id) -> string {
	h := prim.id_hex(id)
	return strings.clone(string(h[:]), context.temp_allocator)
}

trim_slash :: proc(s: string) -> string {
	t := strings.trim_right(s, "/")
	if len(t) == 0 || (len(t) == 2 && t[1] == ':') {
		return s[:len(t) + 1] if len(s) > len(t) else s
	}
	return t
}

put :: proc(b: ^[dynamic]u8, parts: ..string) {
	for x in parts {
		append(b, x)
	}
}
