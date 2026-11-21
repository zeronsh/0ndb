# Provider protocols

Wire facts for every coding-agent CLI that `src/agent/` drives. Everything here
was read from the installed CLIs (help output, generated schemas, shipped
sources) or observed on the wire in November 2026; the "verified" column of
the table at the end says how far each one was exercised.

## Driver model

The host spawns the process described by `launch(d)` (argv, extra env, cwd,
and bytes to write to stdin right away), writes every byte a driver call
returns to the child's stdin, and hands every stdout line to `feed(d, line)`
after recording it raw. Stderr is diagnostics only for every provider below;
it is recorded but never parsed.

- `send(d, text, id)` starts a turn. `steer(d, text, id)` adds input to the
  running turn (it starts a turn when none is running, so a steer racing the
  end of a turn is never lost). `id` should be the host's queue command id
  formatted as a UUID (`8-4-4-4-12`, UUIDv7 preferred): Claude uses it as the
  transcript message uuid, Codex as `clientUserMessageId`, Muse as the
  idempotent `commandId`, ACP as `messageId`.
- `Prompt_Accepted{id, native_id}` means the agent has taken the input into
  the conversation; `native_id` is the provider's id for that user message
  when it has one. `Prompt_Dropped{id}` means the input never reached the
  conversation (interrupt withdrew a queued steer, a steer was refused, or
  the process died first); the host keeps it in its durable queue and
  re-delivers. After `process_exited(d, ...)` every prompt that was not
  accepted is reported dropped, so delivery is exactly once across restarts
  (Muse additionally deduplicates by `commandId`).
- `Turn_Finished{checkpoint}` / `Turn_Failed{checkpoint}` carry the native
  point to rewind to so that the session ends just after this turn. The host
  stores it on the assistant message.
- `rewind(d, {session, after, before, head, seed})` re-targets the driver:
  continue from native `session`, keeping everything up to checkpoint
  `after` (empty keeps nothing: a fresh session), dropping the user message
  `before` (its native id, if known) and everything after it. `head` is the
  session's latest checkpoint when the host knows it (it defaults to the
  driver's own when `session` is the current one). Rewinds never truncate
  the original session, so other branches keep working. The output is
  either bytes or `restart = true` (kill the child and spawn `launch(d)`
  again). When the new native session is live the driver emits
  `Rewound{session, path}`: `Native` (a native fork at the target),
  `Native_Undo` (fork, then the agent's own undo), `Seeded` (fallback, see
  below) or `Fresh` (empty `after`). `Rewind_Failed` only happens when there
  is neither a native path nor a seed.
- Seed fallback: `seed` is the rendered transcript up to the target
  (`Seed_Entry{role: User|Assistant|Tool, text, tool, input, is_error}`,
  oldest first). It is used when the provider has no native way to the
  target or its native rewind fails: the driver opens a fresh native session
  and prefixes the next prompt with the transcript (it stays pending until a
  prompt carrying it is accepted, so it survives a crash). The renderer
  keeps the newest entries verbatim (tool inputs ≤ 2 000 bytes, outputs
  ≤ 4 000) until three quarters of the budget, condenses older ones (text
  ≤ 400 bytes, tools to one line each), drops the oldest beyond the budget
  with an "[N earlier entries omitted]" marker, and cuts on UTF-8
  boundaries. Claude gets XML (`<previous_conversation>`, `<user>`,
  `<assistant>`, `<tool name status><input/><output/></tool>`); the others
  get Markdown (`### User`, `### Assistant`, ``- tool `name` (ok): input → output``,
  closed by `## New message`). Default budgets: 120 000 bytes for Claude,
  Codex and Muse, 80 000 for Pi, Hermes, Devin and Antigravity, 60 000 for
  Cursor and OpenCode (`Start_Request.seed_budget` overrides).
- Attachments: `send` / `steer` take `files: []Attachment{path, name, mime,
  data}` (the host reads the file). Each driver uses the provider's native
  content type where it has one and otherwise appends a text note
  (`[Attached file: name at path, mime, N bytes]`, plus the content in a
  fenced block for text files up to 100 000 bytes).
- Tool events carry `parent`: the id of the tool call (a sub-agent) they
  run under, empty for top-level calls.
- `Usage` adds `context_tokens` / `context_window` (latest context fill)
  where the provider reports them.
- Permissions: with `ask_permissions = false` the driver answers every
  request itself from `access` and emits `Permission_Request{answered =
  true}` for the record; otherwise the host answers with
  `answer_permission(d, id, decision)`.
- `list_models(d)` returns request bytes; the answer arrives as a `Models`
  event (ACP agents emit `Models` whenever a session opens).

## MCP servers

`Start_Request.mcp` lists MCP servers for the session:
`Mcp_Server{name, command, args, env ("KEY=VALUE"), url, headers ("Name: value")}`
(a `url` selects streamable HTTP, otherwise stdio). Each driver passes them
in its provider's own form; nothing outside the driver files knows a flag:

| Provider | Wire form | Verified |
|---|---|---|
| Claude Code | `--mcp-config '{"mcpServers":{name:{"type":"stdio","command","args","env"} \| {"type":"http","url","headers"}}}'` (inline JSON) | live: the model called `mcp__ondbtest__secret_word` on a scratch stdio server and got its output, env included |
| Codex | `config: {"mcp_servers": {name: {command, args, env} \| {url, http_headers}}}` on `thread/start` / `resume` / `fork` | live: the server reached `mcpServer/startupStatus/updated` `ready` and was initialized and listed |
| Pi | no per-run option exists (Pi reads `mcp.json` files); the driver returns a `Launch.files` entry, `<scratch>/ondb-mcp.mjs`, an extension calling `pi.registerMcpServer(name, config)` for each server, and adds `--extension <file>`. Needs `Start_Request.scratch`; the host writes `Launch.files` before spawning | live: Pi initialized the server and listed its tools |
| Muse | `config: {"mcpServers": {name: {"transport":"stdio","command","args","env"} \| {"transport":"streamableHttp","url","headers"}}}` on `session/start` / `session/resume`; `initialize` must request `capabilities.requestedCapabilities: ["sessionMcp"]` or the session is refused ("session MCP configuration requires the sessionMcp capability") | live: capability granted and session started (servers start on use; turns need a login) |
| ACP | `mcpServers` in `session/new`, `load`, `resume`, `fork`: `{name, command, args, env:[{name,value}]}` or `{type:"http", name, url, headers:[{name,value}]}` (HTTP only when `agentCapabilities.mcpCapabilities.http`) | live (OpenCode): the model called the server's tool |

## Determinism

Ids the driver mints (prompt ids when the host passes none, Muse command ids,
the undo prompt) come from `prim.id_new_with(Start_Request.clock,
Start_Request.random)`: UUIDv7 from the injected clock and `prim.Random`
(system clock and `crypto.rand_bytes` when unset), so a simulator gets the
same bytes on every run.

## Provider registry

Every provider is a `Provider_Descriptor{id, name, argv, protocol,
capabilities, env, steer, client_meta, undo, store, seed_style,
seed_budget}`. `protocol` picks the driver family: `Claude_Stream_Json`,
`Codex_App_Server`, `Pi_Rpc`, `Muse` or `Acp`. For `Codex_App_Server`,
`Muse` and `Acp`, `argv` is the whole server command (`codex app-server`,
`muse serve`, `opencode acp`); for `Claude_Stream_Json` and `Pi_Rpc` it is
the program prefix and the driver appends the protocol flags (stream-json,
`--mode rpc`, model, resume, ...). `Start_Request.program` replaces
`argv[0]`; `env` is added to every launch. ACP-only fields: `steer` (`Auto`
lets the driver detect `midTurnPrompts` / a `steer` command, else it
cancels and continues), `client_meta` (keys sent as `true` in
`clientCapabilities._meta`), `undo` (the agent has `/undo N`). `store`
names how its native sessions are exported (below); `seed_style` /
`seed_budget` shape the seed fallback.

`builtin(p)` returns the descriptor of each of the nine built-ins (static
data); `registry_init` registers them; `register(r, desc)` adds or replaces
a provider by id (the registry owns a copy); `lookup(r, id)` finds one;
`init_with(d, desc, req)` starts a driver from any descriptor (`init(d,
provider, req)` is `init_with(d, builtin(provider), req)`).

## Session portability

`export_session(desc, env, session, native_path)` returns a `Port_Plan`
for moving a provider's own session state to another machine or runner,
where `env = Port_Env{home, cwd, scratch, env}` describes the provider's
environment there (`env` holds overrides such as `CLAUDE_CONFIG_DIR`):

1. the host runs `plan.runs` (argv, cwd, env; stdout saved under the bundle
   key `stdout` when set);
2. reads `plan.files` (a file or, with `dir`, a tree; `optional` ones may be
   absent; with `match`, `path` is a directory to search for the file whose
   path ends with `match`, and the host replaces `path` with what it found);
3. stores the bytes under each `key` plus `export_manifest(desc, env,
   session, files)` as the bundle's manifest (JSON: format, provider, store,
   session, cwd, home, store root, and each file's key, path and path
   relative to the root).

`import_session(desc, manifest, env)` returns the reverse plan for the
target environment: write each bundle `key` to `files[i].path` (trees
recursively), passing `rewrite` files through `apply_rewrites(plan, bytes)`
(one pass, longest match first, binary files untouched), then run
`plan.runs`. The native session id to resume is `plan.session`, or
`import_result(desc, plan, run_outputs)` when the provider assigns a new one.
`native_path` / `session_path(d)` is the file the driver saw the provider
report (Codex `thread.path`, Muse `session.path`, Pi `sessionFile`). When a
provider cannot import (`plan.seeded`, with `reason`), the host starts the
next driver with `Start_Request.seed` instead: a fresh session seeded with
the transcript, reported as `Rewound{path = Seeded}`.

| Provider | Native state | Export | Import | Verified |
|---|---|---|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR` or `~/.claude` → `projects/<key>/<session>.jsonl` plus `projects/<key>/<session>/` (sub-agent transcripts, tool results). `<key>` is the absolute cwd with every UTF-16 unit outside `[A-Za-z0-9]` replaced by `-`; longer than 200 → first 200 + `-` + base-36 of `abs(h)`, `h = (h<<5) - h + unit` in 32 bits | copy both | same layout under the new root and key; rewrite old projects dir, key, root, cwd and home in the JSONL; same session id | live: session made in config dir A / cwd A, resumed with `--resume` from config dir B / cwd B and remembered its word |
| Codex | `$CODEX_HOME` or `~/.codex` → `sessions/YYYY/MM/DD/rollout-<time>-<thread>.jsonl` (also indexed in `state_5.sqlite`, but resume finds the file by id) | copy the rollout | same relative path under the new root; rewrite cwd/home; same thread id | live: `thread/resume` in a fresh `CODEX_HOME` returned both turns (no model turn: CLI not logged in) |
| Pi | the session file itself (`~/.pi/agent/sessions/--<cwd without leading /, / \ : → ->--/<time>_<id>.jsonl`, or `PI_CODING_AGENT_SESSION_DIR` / `PI_CODING_AGENT_DIR`) | copy | new sessions dir keyed by the new cwd; rewrite the header `cwd`; **new session id = new path** | live: a session file exported from one agent dir loaded with `--session` from another (no model: no API key) |
| Muse | `~/.local/share/muse/sessions/YYYY/MM/DD/<id>/session.jsonl` (`session.path`) | copy | same relative path, **byte for byte** (the log is fingerprinted; rewriting it makes resume refuse with "stored session.start fingerprint does not match"); the driver sends `workspaceRoots: [cwd]` on every `turn/start` so the new cwd applies | live: `session/resume` in a fresh HOME, then a turn (fails only on login) |
| OpenCode | SQLite `$XDG_DATA_HOME/opencode/opencode.db` | run `opencode export <id>` (JSON on stdout) | rewrite `directory` / `path` (cwd without its leading `/`), then `opencode import <file>`; same session id | live: exported from the default data dir, imported into a fresh `XDG_DATA_HOME` and cwd, resumed with `session/resume`, remembered its word |
| Hermes | SQLite `$HERMES_HOME/state.db` (default `~/.hermes`) | run `hermes sessions export --format trace --session-id <id> --yes <file>` (Claude Code JSONL) | rewrite cwd/home, run `hermes sessions import --from claude <file>`; **new id** parsed from "Imported Claude Code session as <id>" | live: imported into a fresh `HERMES_HOME`, resumed over ACP, answered from the imported history |
| Cursor | `$CURSOR_CONFIG_DIR`, `$XDG_CONFIG_HOME/cursor` or `~/.cursor` → `chats/<md5(abs cwd)>/<chatId>/store.db` (SQLite) | copy the chat directory | same under the new cwd's md5, byte for byte; same chat id | layout read from the shipped source; not exercised (needs login) |
| Antigravity | `$GEMINI_HOME` or `~/.gemini` → `antigravity-acp/conversations/<id>.db` (SQLite trajectory) and `<id>.meta` (JSON), `antigravity-acp/brain/<id>/` | copy | same relative paths; rewrite only `.meta`; same id | layout read from the shipped source; not exercised (needs login) |
| Devin | one shared SQLite `~/.local/share/devin/cli/sessions.db` | none | seed fallback (`plan.seeded`) | — |

## Deletion (purge)

`purge(d, env, targets)` (or `purge_session(desc, env, session,
native_path, targets)`) returns a `Purge_Plan` that removes redacted content
from the provider's own stored state. A `Purge_Target` is a native message
range (`from`..`to` inclusive in the provider's own order, `to` empty for one
message, `keep_from` to start after `from`) and/or a literal `text` to scrub
everywhere. The host stops the provider process, then executes
`plan.steps` in order:

- `Edit` (a file or a tree; with `match`, search under `path`): replace each
  file with `purge_bytes(plan, bytes)`;
- `Scrub`: replace each file with `purge_text(plan, bytes)` (literal texts
  only; used for logs);
- `Run`: run `argv` in `cwd` with `env`; stdout is kept under `key`;
- `Write`: write `purge_bytes(plan, output of key)` to `path`;
- `Delete`: remove `path` (a file or a tree; `optional` may be absent);
- `Sql`: update the SQLite database at `path`. Preferred: run the provider's
  own Python, `<interpreter> -I -c <script> <args...>`, where `script` uses
  the `sqlite3` module and the values arrive as parameters (`args`: database,
  table, column, the texts as a JSON array, the replacement; bound with `?`,
  never interpolated). The interpreter is found from the provider's launcher
  (`launcher`, e.g. `hermes` on `PATH`): the host reads the file and calls
  `launcher_interpreter(text) -> (interpreter, next)`, which returns a
  `#!...python...` shebang (also through `env`), or the absolute target of
  the first `exec /path ...` line (an interpreter when its name starts with
  `python`, otherwise the next launcher to read). Only when no interpreter is
  found does the host fall back to `sqlite3 <path> <sql>` with the
  equivalent escaped SQL.

Afterwards the driver is relaunched with `resume = purge_result(desc, plan,
run_outputs)`; when `plan.seeded` is set (the format cannot be rewritten),
the native session has been deleted and the host starts a fresh one with
`Start_Request.seed` (the already redacted transcript).

`purge_bytes` understands each format and keeps the session resumable:
entries in a range keep their ids, parent links, roles, tool ids and names,
but every text, tool input and tool output becomes `[redacted]` (tool inputs
`{}`, Codex arguments `"{}"`); thinking/reasoning blocks (their signatures
would no longer verify), images, documents and files are dropped, and an
emptied content array gets one `[redacted]` text block. Codex reasoning
items in a range are dropped. Literal texts are replaced by `[redacted]` in
every string of every entry, and a thinking block that contains one is
dropped. Untouched lines keep their exact bytes.

| Provider | How | Message ids for ranges | Verified |
|---|---|---|---|
| Claude Code | edit the transcript JSONL and the session's folder (sub-agents, tool results) in place, delete `file-history/<session>` | transcript `uuid`s (prompt uuid = our message id; checkpoint = last entry) | live: after purging a turn and its passphrase, no byte of it remained under the config dir, `--resume` worked, the model still knew the earlier word and only saw `[redacted]` |
| Codex | edit the rollout JSONL (the only file holding message text; the SQLite stores hold none) | turn ids | not exercised (not logged in) |
| Pi | edit the session JSONL | entry ids | not exercised (no API key) |
| OpenCode | `opencode export`, redact, `opencode session delete`, `opencode import` (same id), `opencode db "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"`, scrub `log/` (its log records prompts) | OpenCode message ids (`msg_...`, the `messageId` of agent chunks) | live: no trace in the data dir afterwards; the session resumed and answered with the earlier word and `[redacted]` |
| Hermes | `hermes sessions export --format trace`, redact, `hermes sessions delete --yes`, `hermes sessions import --from claude` (new id), SQL on `state.db` through Hermes's own Python (its launcher chain here: `/usr/local/bin/hermes` → `.../ascii-harnesses/bin/hermes` → `.hermes/bin/hermes`, a shell script that `exec`s `~/.hermes/tools/python-3.14.9.../bin/python3`): Hermes keeps each turn's `final_response` in `state_meta` admission receipts even after a delete (by design, for exact retries), so those values are scrubbed with `replace(...)`; then `hermes sessions optimize --force` (VACUUM) and scrub `logs/` and `sessions/` | none over ACP: purge by text (the host passes the redacted texts) | live, with no `sqlite3` on `PATH`: no trace in the Hermes home (files and every SQLite cell); the imported session resumed |
| Muse | seeded: delete the session folder (its log is fingerprinted) | — | not exercised |
| Cursor, Antigravity | seeded: delete the chat folder / trajectory, sidecar and brain | — | not exercised |
| Devin | seeded: `devin rm <session>` | — | not exercised |

## Claude Code (`claude`, 2.1.330)

- Launch: `claude -p --input-format stream-json --output-format stream-json
  --verbose --include-partial-messages --replay-user-messages
  --permission-prompt-tool stdio --permission-mode <mode> [--model M]
  [--effort E] [--resume S [--resume-session-at UUID --fork-session]]`.
  Modes: plan `plan`, edit `acceptEdits`, full `bypassPermissions` (or
  `default` when the host answers permissions). `--resume-session-at` and
  `--resume-drops-turn` are hidden flags (`claude --help` omits them; they are
  in the binary): "When resuming, only messages up to and including the chain
  entry with <message.id>".
- One persistent process serves many turns. No handshake is needed; the
  process prints nothing until the first user message. Each turn begins with
  `{"type":"system","subtype":"init","session_id":...}` (repeated per turn).
- Send / steer: the same line, `{"type":"user","uuid":U,"session_id":"",
  "parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"text",
  "text":T}]}}`. The CLI honours the client `uuid` as the transcript entry id.
  It answers with `command_lifecycle` frames (`command_uuid`, `state`:
  `queued` / `started` / `cancelled` / `completed`) and, with
  `--replay-user-messages`, echoes the message with `"isReplay":true` when it
  enters the conversation. A message written mid-turn is queued and
  **absorbed into the running turn at the next model request** (after the
  current tool results): verified, the model ends the same turn obeying it
  and the turn's `system/status` lists both `user_message_uuids`. If the turn
  ends first, the queued message starts the next turn by itself. Steering is
  therefore native: the driver writes the steer and reports
  `Prompt_Accepted` on the replay echo.
- Interrupt: `{"type":"control_request","request_id":R,"request":
  {"subtype":"interrupt"}}` → `{"type":"control_response","response":
  {"subtype":"success","request_id":R,"response":{"still_queued":[uuids]}}}`.
  Queued messages survive an interrupt and run as the next turn, so the
  driver first withdraws every unaccepted prompt with `{"subtype":
  "cancel_async_message","message_uuid":U}` (answer `{"cancelled":true,
  "message_uuid":U}`, verified) and then interrupts; a cancelled steer becomes
  `Prompt_Dropped`. The interrupted turn ends with a `result` whose
  `subtype` is `error_during_execution` and `terminal_reason` is
  `aborted_tools` / `aborted_streaming`.
- Events: `stream_event` (`message_start` → message id;
  `content_block_delta` with `text_delta` / `thinking_delta`), `assistant`
  (full content blocks; `tool_use` gives id, name, input), `user`
  (`tool_result` blocks with `tool_use_id`, `content`, `is_error`),
  `result` (`subtype`, `is_error`, `result`, `usage` with `input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`,
  `total_cost_usd`, `terminal_reason`). Lines with a non-null
  `parent_tool_use_id` belong to sub-agents and are skipped. The `result`
  line has no stable key order (`type` is not first).
- Checkpoint: the `uuid` of the last main-chain `user`/`assistant` line of
  the turn. Rewind = restart with `--resume S --resume-session-at
  <checkpoint> --fork-session` (verified: a two-turn session rewound to the
  first turn's last entry remembered only the first turn); the new session id
  arrives with the first turn's `system/init`. An empty `after` restarts
  without `--resume`.
- Permissions: `{"type":"control_request","request_id":R,"request":
  {"subtype":"can_use_tool","tool_name":...,"input":{...},"description":...,
  "permission_suggestions":[...],"tool_use_id":...}}`, answered with
  `{"type":"control_response","response":{"subtype":"success","request_id":R,
  "response":{"behavior":"allow","updatedInput":{...}}}}` or
  `{"behavior":"deny","message":...}` (both verified). Other control requests
  get `{"subtype":"error"}`. The CLI echoes our own `control_response` lines
  back on stdout; they are ignored.
- Attachments: images as `{"type":"image","source":{"type":"base64",
  "media_type","data"}}`, PDFs as `{"type":"document","source":{"type":
  "base64","media_type":"application/pdf","data"},"title"}`, text files as
  `{"type":"document","source":{"type":"text","media_type":"text/plain",
  "data"},"title"}`, before the text block; anything else becomes a note
  (verified: an image and a text note in one prompt answered correctly).
- Sub-agents: lines whose `parent_tool_use_id` is set belong to a sub-agent
  run by that tool call (`Agent` / `Task`); their `tool_use` / `tool_result`
  blocks become tool events with `parent` set (verified: the sub-agent's
  `Bash` call arrives with the `Agent` call as parent). They never move the
  checkpoint, and their stream deltas are not forwarded.
- Rewind fallback: if the CLI exits while a `--resume-session-at` restart is
  pending (an unknown target), `process_exited` switches to the seed and
  asks for another restart.
- Models: `{"subtype":"list_models"}` control request → `response.models[]`
  with `value`, `displayName`, `description`, `supportedEffortLevels`
  (`default` is the recommended model). Also present in the `initialize`
  control response.

## Codex (`codex app-server`, codex-cli 0.171.0)

- Launch: `codex app-server` (stdio JSON-RPC; messages carry no `"jsonrpc"`
  member). `codex app-server generate-json-schema --out DIR` and
  `generate-ts --out DIR [--experimental]` print the full protocol.
- Handshake (pipelined in one write, verified):
  `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ondb",
  "title":null,"version":"0.1.0"},"capabilities":null}}`,
  `{"method":"initialized"}`, then one of
  `thread/start {cwd, model, approvalPolicy, sandbox}`,
  `thread/resume {threadId, ..., excludeTurns:true}`,
  `thread/fork {threadId, lastTurnId, ..., excludeTurns:true}`.
  The result's `thread.id` is the session. `approvalPolicy` is `never` (or
  `on-request` when the host answers), `sandbox` is `read-only` /
  `workspace-write` / `danger-full-access`. A fork does not inherit the
  model: pass it again.
- Send: `turn/start {threadId, clientUserMessageId, input:[{type:"text",
  text, text_elements:[]}], effort?}` → `{turn:{id, status:"inProgress"}}`,
  then `turn/started`.
- Steer (native, verified): `turn/steer {threadId, clientUserMessageId,
  expectedTurnId, input}` → `{turnId}`; the input appears as a `userMessage`
  item (with our `clientId`) inside the running turn. A stale
  `expectedTurnId` fails with `-32600 "expected active turn id ..."`, a
  finished turn with `"no active turn to steer"`; the driver then re-sends
  the text as `turn/start` so nothing is lost.
- Interrupt: `turn/interrupt {threadId, turnId}` → `{}` then
  `turn/completed` with `status:"interrupted"` (verified). An interrupt
  requested before the turn id is known is sent as soon as it arrives.
- Events: `item/started` / `item/completed` with `item.type` `userMessage`
  (`id`, `clientId`), `agentMessage`, `reasoning`, `commandExecution`
  (`command`, `cwd`, `aggregatedOutput`, `exitCode`, `status`), `fileChange`
  (`changes[].path`), `mcpToolCall`, `dynamicToolCall`, `webSearch`, ...;
  `item/agentMessage/delta`, `item/reasoning/summaryTextDelta`,
  `item/reasoning/textDelta`, `item/commandExecution/outputDelta`,
  `thread/tokenUsage/updated` (`tokenUsage.last`), `error`
  (`willRetry`), `turn/completed` (`turn.status` `completed` / `interrupted`
  / `failed`, `turn.error.message`), `warning`.
- Checkpoint: the turn id. Rewind = `thread/fork {threadId, lastTurnId}`
  (inclusive) on the live process, verified; `thread/revert {threadId,
  beforeTurnId}` exists but rewrites the thread in place and is not used.
  A refused fork falls back to `thread/start` plus the seed.
- Attachments: `input` gets `{"type":"localImage","path"}` for images with a
  path, `{"type":"image","url":"data:<mime>;base64,..."}` otherwise; other
  files become notes in the text item (Codex can read the path itself).
- Permissions (server requests): `item/commandExecution/requestApproval`,
  `item/fileChange/requestApproval` answered `{decision: "accept" |
  "acceptForSession" | "decline"}`; legacy `execCommandApproval` /
  `applyPatchApproval` answered `approved` / `approved_for_session` /
  `denied`; `item/permissions/requestApproval` gets an error (not granted).
- Models: `model/list {limit}` → `data[]` with `model`, `displayName`,
  `hidden`, `isDefault`, `supportedReasoningEfforts` (verified).
- Experimental methods (`--experimental` bindings) include a server-side
  queue (`thread/queue/*`); the host keeps the durable queue, so it is not
  used.

## Pi (`pi --mode rpc`, 1.6.0)

Reference: `docs/rpc.md`, `rpc-commands.md`, `json.md`, `session-format.md`
and `rpc-extension-ui.md` in the installed package
(`@earendil-works/pi-coding-agent`).

- Launch: `pi --mode rpc --no-themes [--model provider/id] [--thinking E]
  [--session FILE] [--tools read,grep,find,ls | --exclude-tools bash]`
  (plan / edit access). JSONL, split on LF only. Commands carry a string
  `id`; responses are `{"id","type":"response","command","success",
  "data"|"error"}`.
- Handshake: `get_state` → `data.sessionFile` (the native session id; it is
  what `--session` and `switch_session` take), `data.messageCount`.
- Send: `{"type":"prompt","message":T,"streamingBehavior":"followUp"}`.
  Steer: `{"type":"prompt","message":T,"streamingBehavior":"steer"}`: while a
  run is active it is queued and "delivered after the current assistant turn
  finishes executing its tool calls, before the next LLM call"; while idle
  `streamingBehavior` is ignored and it starts a run. The bare `steer`
  command is not used because, sent while idle, it stays queued without
  starting a run (verified). A `prompt` response has
  `data.disposition` `started` / `queued` / `handled`.
- Turn: `agent_start` … `agent_end` … `agent_settled {aborted}`; only
  `agent_settled` means Pi will not continue by itself (retries, compaction,
  queued steers). `message_update.assistantMessageEvent` `text_delta` /
  `thinking_delta`, `message_end` (assistant `stopReason` `error` with
  `errorMessage`, `aborted`; `usage {input, output, cacheRead, cacheWrite,
  cost.total}`), `tool_execution_start/update/end` (`toolCallId`,
  `toolName`, `args`, `partialResult`, `result.content[]`, `isError`).
- Native ids: events carry none, so on `agent_settled` the driver asks
  `get_entries {since: <last leaf>}` and matches each new user `message`
  entry to the prompts it wrote **by content** (the entry's text, a string
  or the joined text parts, must equal the text the driver sent); entries
  that match nothing (extension-injected messages, custom messages) are
  ignored, and only prompts starting with `/` (expanded skills and templates,
  whose text changes) may be paired with a leftover entry. `leafId` becomes
  the checkpoint. Turn end is reported after that answer.
- Attachments: `prompt.images: [{"type":"image","data":<base64>,
  "mimeType"}]`; other files become notes in `message`.
- Rewind fallback: a refused `switch_session` / `fork`, or a checkpoint with
  no following user entry that is not the leaf, uses `new_session` plus the
  seed.
- Interrupt: `clear_queue` (returns the withdrawn `steering` / `followUp`
  texts, reported as `Prompt_Dropped`) then `abort`.
- Rewind: `switch_session {sessionPath}` when the target session differs,
  then `fork {entryId: before}` (forks into a new session file positioned at
  the parent of that user message; returns its text) or, when only `after`
  is known, `get_entries` to find the user entry whose `parentId` is `after`
  and fork at it; `new_session` for an empty `after`. Afterwards `get_state`
  reports the new session file.
- Permissions: Pi has no tool approvals; extension dialogs arrive as
  `extension_ui_request {id, method: select|confirm|input|editor, title,
  options}` and are answered with `extension_ui_response {id,
  confirmed|value|cancelled}`.
- Models: `get_available_models` → `data.models[] {provider, id, name}`
  (model ids are `provider/id`); `get_state.data.model` is the current one.

## Muse Code (`muse serve`, 1.4.24)

Meta's Muse Code. Installed with the vendor's installer
(`curl -fsSL https://dev.meta.ai/install.sh | bash`, here into a scratch
`HOME` / `MUSE_INSTALL_DIR`); protocol reference is the official
`@muse-code/sdk` package (`dist/src/msp.d.ts`, the Muse Session Protocol)
and `muse schema`.

- Launch: `muse serve` (JSON-RPC 2.0 over stdio, LF-delimited).
- Handshake: `initialize {clientInfo:{name, version}}` (`name` must match
  `[a-z0-9_]+`) → `{serverInfo, schema, sessionDurability, ...}`, then the
  `initialized` notification.
- Every command carries a `commandId` that must be a **UUIDv7**
  (`invalid ... commandId: expected UUIDv7` otherwise). Command ids are
  global idempotency keys: re-sending the same id with the same params is a
  safe retry; with different params it fails `command_id_conflict`. The
  driver uses the host's queue id as the `commandId` of `turn/start`, so a
  re-delivery after a crash can never run twice.
- Open: `session/start {commandId, workspaceRoot, modelId?, approvalMode}`
  (`allowAll` | `promptUnmatched` | `onRequest` | `denyUnmatched`),
  `session/resume {commandId, sessionId, excludeItems:true}`,
  `session/fork {commandId, sessionId, cutPoint:{lastTurnId},
  excludeItems:true}`; results carry `session.sessionId`.
- Send / steer (native, no race): `turn/start {commandId, sessionId,
  input:[{type:"text",text}], ifBusy, reasoningEffort?}` with `ifBusy`
  `queue` for a send and `steer` for a steer (`replace` also exists). Result
  `{turnId, disposition: started|queued|steered, startedNewTurn}`; the turn
  id equals the `commandId` that started it. `turn/steer {commandId,
  sessionId, expectedTurnId, input}` also exists; `turn/unqueue` reclaims a
  queued submit.
- Interrupt: `turn/interrupt {commandId, sessionId, turnId?, retract?}`
  (`missing_run` when idle). `turn/cancel` is the non-priority variant.
- Events: `turn/started {commandId, turnId}`, `item/started` /
  `item/updated` / `item/completed {item:{itemId, kind, status, text, tool,
  args, visibleOutput, commandId, ...}}` (`kind` `userMessage`,
  `agentMessage`, `reasoning`, `toolCall`, ...), `item/delta {itemId, delta,
  field}` (field absent means `text`), `turn/completed {turnId, terminal:
  completed|failed|cancelled, error{message}, usage{inputTokens,
  outputTokens, cachedTokens, cacheReadTokens, cacheWriteTokens,
  reasoningTokens}}`, `turn/unqueued`, `turn/retracted`.
- Checkpoint: the turn id. Rewind = `session/fork` with `cutPoint.lastTurnId`
  (a turn that never completed is refused with `forkBoundaryInvalid`,
  verified).
- Approvals: `approval/requested` (and the server request `approval/request`,
  answered `{}`) `{approvalId, currentRequirementId:{approvalId,
  sourceIndex}, availableChoices:[{choiceId, decision}], toolName, rawArgs}`;
  decided with `approval/decide {commandId, sessionId, approvalId,
  requirementId, choiceId}` choosing the choice whose `decision` is
  `approved` / `approvedForSession` / `denied`.
- Models: `model/list` → `models[] {modelId, displayLabel, isDefault}`.
- Attachments: image input parts `{"type":"image","mediaType","base64Data"}`
  (the SDK's `TurnInputPart`; types are `text`, `image`, `skill`, `video`);
  other files become notes in the text part.
- Rewind fallback: a refused `session/fork` (for example `forkBoundaryInvalid`)
  uses `session/start` plus the seed.

## ACP agents (one driver)

JSON-RPC 2.0 over stdio, Agent Client Protocol v1.

| Provider | argv | Notes |
|---|---|---|
| Antigravity | `agy_acp_server [--uid=]` | `--uid=` on Linux per the ACP registry. Official build from `dl.google.com/agy-extensions/releases/...` (listed in `cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, sha256 there). |
| Cursor | `cursor-agent acp` | |
| Devin | `devin acp --process-model in-process` | Official npm package `devin`; in-process so no background daemon outlives the session. |
| Hermes | `hermes acp` | |
| OpenCode | `opencode acp` | |

- Handshake: `initialize {protocolVersion:1, clientCapabilities:{fs:
  {readTextFile:false, writeTextFile:false}, terminal:false}, clientInfo}`;
  `agentCapabilities.loadSession`, `sessionCapabilities.{resume, fork, list,
  close, delete}` decide how sessions are opened. Then `session/new {cwd,
  mcpServers:[]}`, `session/resume {sessionId, cwd, mcpServers}` (preferred)
  or `session/load` (replays history as `session/update`s, which are
  ignored until it answers). The response carries `configOptions` (category
  `model` → model list, category `mode`, category `thought_level`) and/or
  `models {currentModelId, availableModels}` and `modes`; the driver selects
  the model with `session/set_config_option {sessionId, configId, value}` or
  `session/set_model`, plan access with the `plan` mode, and holds prompts
  until those answers arrive (Hermes answers a prompt sent before its model
  switch completed with "not connected to any AI provider").
- Prompt: `session/prompt {sessionId, messageId, prompt:[{type:"text",
  text}, ...]}`. Attachments follow `promptCapabilities`: images as
  `{"type":"image","mimeType","data","uri"?}` when `image` is advertised;
  files as embedded `{"type":"resource","resource":{"uri","mimeType",
  "text"|"blob"}}` when `embeddedContext` is advertised, otherwise as
  `{"type":"resource_link","uri":"file://...","name","mimeType"}` (part of
  the ACP baseline) when there is a path, otherwise a text note (verified
  with OpenCode and Hermes). The messageId is reported as the prompt's
  native id; the response `{stopReason: end_turn|cancelled|refusal|max_tokens|
  max_turn_requests, usage{inputTokens, outputTokens, cachedReadTokens,
  cachedWriteTokens, thoughtTokens}}` ends the prompt. Streaming arrives as
  `session/update` with `sessionUpdate` `agent_message_chunk` (with
  `messageId`), `agent_thought_chunk`, `tool_call` / `tool_call_update`
  (`toolCallId`, `title`, `kind`, `status`, `rawInput`, `content[]`,
  `rawOutput`), `usage_update`, `available_commands_update`,
  `config_option_update`.
- Interrupt: notification `session/cancel {sessionId}`; the pending prompt
  answers `stopReason:"cancelled"`.
- Usage: the prompt response's `usage` gives tokens;
  `usage_update {used, size, cost:{amount, currency}}` gives the context
  fill (`context_tokens`, `context_window`) and the cumulative session cost,
  of which the turn's share (amount at turn end minus amount at turn start)
  becomes `cost_usd`.
- Checkpoint: the number of user turns in the session (prompts that
  completed, not counting `/steer` or `/undo`), as a decimal string; a
  resumed session restores the count from `Start_Request.checkpoint`.
- Permissions: request `session/request_permission {toolCall, options:
  [{optionId, kind: allow_once|allow_always|reject_once|reject_always}]}` →
  `{outcome:{outcome:"selected", optionId}}` or `{outcome:{outcome:
  "cancelled"}}`. Automatic answers: full allows everything, edit allows
  `read/edit/delete/move/search/think` kinds, plan allows
  `read/search/think`. `fs/*`, `terminal/*` and vendor requests are refused
  (`-32601`); we advertise no client capabilities.
- Steering, per agent, the most native channel each one has:
  - **OpenCode: concurrent prompt (native injection).** A second
    `session/prompt` while one is running is folded into the running turn at
    the next step; both requests answer together when the turn ends, with
    the same usage (verified live: the model obeyed the steer in the same
    reply). OpenCode's ACP `prompt` also accepts `messageId`.
  - **Devin: concurrent prompt.** `initialize` advertises
    `agentCapabilities._meta["cognition.ai/midTurnPrompts"]: true` ("Type
    while Devin works to steer it right away"); the driver keys on that flag.
    Not exercised live (needs a Devin login). Devin also ships
    `_cognition.ai/revert/*` methods, but a plain ACP client gets
    `Method not found` for them.
  - **Cursor: superseding prompt.** In `cursor-agent` 2026.11.19 the ACP
    `handlePrompt` cancels the running prompt (`pendingPromptCancel`) and
    runs the new one on the same conversation; the old request answers
    `cancelled`. The driver keeps the logical turn open across that. Read
    from the shipped source; not exercised live (needs `cursor-agent
    login`). `cursor-agent -p` has no streaming input, so ACP is its only
    live channel.
  - **Hermes: `/steer` command (native).** Hermes advertises an available
    command `steer` ("Inject guidance into the currently running agent
    turn"). A concurrent `session/prompt` with text `/steer <text>` answers
    `end_turn` immediately after an `agent_message_chunk` without
    `messageId` ("⏩ Steer queued for the active turn: ..."), which the
    driver reports as a notice; the running turn picks the guidance up
    (verified live). Any agent that advertises a `steer` command gets this
    path. Hermes also has `/queue` and `/undo N`.
  - **Antigravity: cancel and continue.** Its ACP server (Python, shipped in
    the `.par`) handles `prompt` with no queue or injection, so the driver
    sends `session/cancel`, holds the steer text (several steers are joined)
    and, when the cancelled prompt answers, sends one new `session/prompt`
    with it, keeping the logical turn open; streamed output is kept and the
    session history keeps the interrupted work (cancel and re-prompt
    verified against OpenCode). The held text is reported dropped if the
    process dies first.
- Resume: `session/resume` when advertised (OpenCode, Hermes, Antigravity,
  verified for OpenCode across a process restart), else `session/load`
  (Cursor, Devin).
- Rewind, in order of preference:
  - to the end of a session: `session/fork {sessionId, cwd, mcpServers}`
    when advertised (OpenCode, Hermes; OpenCode replays the forked history
    as updates under the new id, which are ignored), else resume/load it;
  - Hermes (or any agent advertising an `undo` command) with `fork`:
    `session/fork`, then a prompt `/undo N` on the fork with N = head −
    after; Hermes answers with a `messageId`-less chunk "Undid N turn(s)
    ... Removed message: ..." (reported as a notice) and `end_turn`; the
    original session is untouched (verified live: after undoing the second
    of two turns the fork remembered only the first, the original both);
  - Devin: `initialize` must send `clientCapabilities._meta
    {"cognition.ai/revert": true, "cognition.ai/revertByUserMessageId":
    true}`; only then does Devin answer its revert methods (otherwise
    `Method not found`) and advertise `_meta["cognition.ai/revert"]`. The
    driver calls `_cognition.ai/revert/listSteps {sessionId}` →
    `{steps:[{stepId, stepNumber, userMessageId, toolCallId, kind, ...}]}`,
    picks the step whose `userMessageId` (or `stepId`) is `before`, then
    `_cognition.ai/revert/forkFromStep {sessionId, stepId}` and loads the
    session it returns. `_cognition.ai/revert/execute {sessionId,
    userMessageId|stepId, force?, skipFileUndo?}` reverts in place and is
    not used; `preview` and `resume` also exist. Method names and parameter
    shapes were verified against the binary (errors such as "Target step is
    no longer on the current chain"), not on a real conversation (needs a
    login);
  - otherwise (OpenCode, Cursor, Antigravity mid-session, or any failure
    above): `session/new` plus the seed.
- Models come from the open response. OpenCode's free models
  (`opencode/big-pickle`, ...) need no login.

## Verification status

| Provider | send | steer | interrupt | resume | rewind | attachments | live |
|---|---|---|---|---|---|---|---|
| Claude Code | stdin `user` line | native (absorbed at next model request) | `interrupt` control + `cancel_async_message` | restart `--resume` | restart `--resume-session-at --fork-session` | image / PDF / text document blocks | all verified with haiku, incl. sub-agent parents and attachments |
| Codex | `turn/start` | native `turn/steer`, fallback `turn/start` | `turn/interrupt` | `thread/resume` | `thread/fork lastTurnId`, seed on failure | `localImage` / data-URL `image`, notes | wire verified; no model output (CLI not logged in: 401) |
| Pi | `prompt` + `followUp` | native `prompt` + `steer` | `clear_queue` + `abort` | `--session` | `fork entryId` / `get_entries`, seed on failure | `images`, notes | wire verified; prompts refused (no API key); id matching verified with recorded lines |
| Muse | `turn/start ifBusy:queue` | native `turn/start ifBusy:steer` | `turn/interrupt` | `session/resume` | `session/fork cutPoint`, seed on failure | `image` input parts, notes | wire verified on 1.4.24; turns fail (not logged in) |
| OpenCode | `session/prompt` | native concurrent prompt | `session/cancel` | `session/resume` | `session/fork` at the end, else seed | image, embedded resource | all verified with free models, incl. seeded rewind and attachments |
| Hermes | `session/prompt` | native `/steer` | `session/cancel` | `session/resume` | `session/fork` + `/undo N` | image, resource links | steer, undo rewind and image verified (claude-haiku) |
| Devin | `session/prompt` | concurrent (midTurnPrompts) | `session/cancel` | `session/load` | `_cognition.ai/revert/forkFromStep`, else seed | image, embedded resource | handshake and revert method shapes verified; turns need login |
| Cursor | `session/prompt` | superseding prompt | `session/cancel` | `session/load` | seed | image, resource links | handshake verified; session needs login |
| Antigravity | `session/prompt` | cancel and continue | `session/cancel` | `session/resume` | seed | image, embedded resource | handshake verified on 1.5.2; session needs login |
