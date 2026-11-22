/*
 * 0ndb.h - the C ABI of lib0ndb.
 *
 * Build:
 *   odin build src/capi -build-mode:shared -o:speed \
 *     -extra-linker-flags:"-Wl,--version-script=src/capi/lib0ndb.map"     (Linux)
 *     -extra-linker-flags:"-Wl,-exported_symbols_list,src/capi/lib0ndb.exports"  (macOS)
 *   odin build src/capi -build-mode:static -no-entry-point -o:speed
 *   Link against: libcurl (soname libcurl.so.4), zlib, pthread, libm, libdl.
 *
 * Model
 *   An engine is an opaque handle (ondb). There is no global state: any number
 *   of handles may live in one process, each owning its own directory, loop and
 *   plug points. Every callback the engine makes runs on the engine thread:
 *   either the thread that calls ondb_step (embedder-driven loop), or the
 *   engine's own thread after ondb_start. All functions must be called on the
 *   engine thread, except ondb_abi_version, ondb_status_name, ondb_free,
 *   ondb_post (thread-safe from any thread), ondb_stop and ondb_close (from the
 *   thread that owns the handle, never from a callback).
 *
 * Memory
 *   Buffers returned through out-parameters are owned by the caller and are
 *   released with ondb_free; they never alias engine memory. Buffers and
 *   strings passed to callbacks (done, subscription, event, post and every
 *   plug function) are borrowed and valid only for the duration of that
 *   callback. Plug tables are copied at open; the ud pointers they carry must
 *   stay valid until ondb_close returns.
 *   Allocations from the default temp allocator do not survive a loop pump:
 *   the engine releases that allocator at settle. Copy anything you keep
 *   across ondb_step (or the engine thread's run) into your own allocator.
 *   This is why every borrowed buffer above must be copied before the
 *   callback returns if it is needed later.
 *
 * Versioning
 *   ondb_abi_version() returns (major << 16) | minor. A major change breaks the
 *   ABI; a minor change only adds functions, ops, struct tails or payload
 *   fields at the end. Every struct passed in starts with a size field set to
 *   sizeof(the struct as the caller knows it), so newer libraries accept older
 *   callers. Binary payloads append fields only at the end, so readers must
 *   ignore trailing bytes; binary requests may omit trailing arguments, which
 *   then take their zero value.
 *
 * Requests (ondb_call, ondb_subscribe)
 *   A request is either binary or JSON (ONDB_JSON flag).
 *   Binary request := u8 version(=1), uvarint op_code, then the op's arguments
 *                     in order, encoded by type (see Encoding).
 *   JSON request   := {"op": "<op name>", "<arg>": value, ...}; absent or
 *                     null arguments take their zero value.
 *   The response payload of a successful call is the op's result in the same
 *   form as the request (binary fields in order, or a JSON object). A failed
 *   call returns status != ONDB_OK and an error payload: binary
 *   {status: uvarint} or JSON {"error": "<status name>"}.
 *   A call either completes synchronously (status != ONDB_PENDING, payload in
 *   *out) or returns ONDB_PENDING and later invokes its done callback exactly
 *   once on the engine thread with the final status and payload. A pending
 *   read waits for remote data; after timeout_ms (0 = no limit) it completes
 *   with whatever is locally available, or ONDB_TIMEOUT for writes.
 *   ondb_describe returns the full op table (codes, names, argument names and
 *   types, result layouts) so bindings can be generated mechanically.
 *
 * Encoding (the prim codec)
 *   u8, bool       1 byte
 *   u32le, u64le   little-endian fixed width
 *   uvarint        LEB128 unsigned
 *   ivarint        zigzag LEB128
 *   f64            u64le of the IEEE-754 bits
 *   str, bytes     uvarint length, then that many bytes (str is UTF-8)
 *   id             16 raw bytes; JSON: 32 lowercase hex chars, null when zero
 *   rid            id seg, ivarint off, uvarint gen; JSON: "<seg hex>:<off>:<gen>",
 *                  null when zero. gen is the generation of the writer session
 *                  that wrote the record; a rid resolves only to a record of
 *                  exactly that generation at that offset, otherwise not_found
 *                  (the two-part form means generation 0)
 *   object         id space, id id; JSON: "<space hex>/<id hex>"
 *   enum           uvarint; JSON: the value's name (numbers also accepted)
 *   [T]            uvarint count, then count T; JSON: array
 *   ids, strs, uvarints  [id], [str], [uvarint]
 *   fields         [ {tag: uvarint, value: bytes} ]; JSON value is hex, or
 *                  "text" may be given instead of "value"
 *   attachments    [ {name: str, mime: str, oid: bytes, size: uvarint} ]
 *   blocks         [ {kind: enum block, text: str, id: str, name: str,
 *                  failed: bool} ]
 *   bytes in JSON are lowercase hex strings. str in JSON replaces invalid
 *   UTF-8 with U+FFFD; use the binary form for exact bytes.
 *
 * Enumerations (value = name)
 *   kind          1 conversation, 2 map, 3 text, 4 tree
 *   role          1 user, 2 assistant, 3 system, 4 tool
 *   block         1 text, 2 reasoning, 3 tool_call, 4 tool_result, 5 image,
 *                 6 error, 7 notice, 8 permission, 9 permission_answer,
 *                 10 question, 11 file
 *   seal          0 open, 1 done, 2 interrupted, 3 failed, 4 cancelled
 *   convo_status  0 idle, 1 running, 2 queued, 3 awaiting_permission,
 *                 4 failed, 5 interrupted, 6 waiting, 7 reviving
 *   open_state    0 running, 1 revive
 *   condition     1 any, 2 all
 *   mode          0 end_to_end, 1 transparent
 *   unit          0 lines, 1 bytes
 *   sort          0 relevance, 1 newest
 *   scope         0 auto, 1 local, 2 everywhere
 *   search_mode   0 default, 1 full, 2 local
 *   search_state  0 ok, 1 partial, 2 offline, 3 timeout, 4 denied,
 *                 5 failed, 6 cancelled
 *   dir           0 older, 1 newer
 *   member_role   1 tree, 2 document, 3 memory
 *   intent        23 assign, 25 queue, 26 steer, 27 edit_queued, 28 cancel,
 *                 29 interrupt, 30 answer, 37 await
 *   delta         0 message, 1 block, 2 chunk, 3 seal, 4 leaf, 5 intent,
 *                 6 run, 7 mount, 8 record, 9 status, 10 field, 11 element,
 *                 12 counter, 13 catalog, 14 text, 15 files, 16 redacted,
 *                 17 members, 18 quarantined
 *   event         0 connected, 1 disconnected, 2 durable, 3 uploaded,
 *                 4 quarantined, 5 refused, 6 fatal, 7 space_joined,
 *                 8 object_seen, 9 failure, 10 placement,
 *                 11 relay_misbehaving, 12 presence, 13 caught_up,
 *                 14 indexer_wanted, 15 unavailable,
 *                 16 available, 17 promoted, 18 peer_misbehaving,
 *                 19 members_changed, 20 epoch_changed, 21 access_revoked,
 *                 22 runner_enrolled, 23 runner_anomaly, 24 approval_requested,
 *                 25 login_done, 26 login_failed, 27 lease_lapsed, 28 space_left
 *   member_kind   0 device, 1 account, 2 recovery, 3 custodian, 4 pool,
 *                 5 runner, 6 guest, 7 directory
 *   member_role   0 owner, 1 admin, 2 member, 3 reader
 *   enroll        0 genesis, 1 approval, 2 recovery, 3 account, 4 custodian,
 *                 5 pool, 6 grant, 7 directory
 *   login_path    0 created, 1 passkey, 2 approval, 3 cross_device,
 *                 4 recovery
 *   login_status  0 done, 1 waiting, 2 no_approver
 *   pool_access   0 off, 1 everything, 2 workspace, 3 only_sent
 *   placement     0 none, 1 assigned, 2 running, 3 waiting_runner, 4 idle,
 *                 5 placing
 *   takeover      0 default, 1 auto, 2 never
 *   takeover_level 0 conversation, 1 agent, 2 workspace
 *   runner_kind   0 device, 1 pool
 *   runner_state  0 offline, 1 online, 2 wakeable
 *
 * Shared payload structures
 *   Result     := item: rid, off: ivarint, leaf: rid, tick: uvarint
 *   Usage      := input: uvarint, output: uvarint, cache_read: uvarint,
 *                 cache_write: uvarint
 *   Status     := status: enum convo_status, head: rid, position: rid,
 *                 browsing: bool, head_status: enum seal, queued: uvarint,
 *                 waiting: uvarint, intents: uvarint, running: bool,
 *                 awaiting: bool, revive: bool, head_hlc: uvarint
 *   Blob       := oid: bytes, size: uvarint, preview: str
 *   File       := mount: str, tree: id, line: id, version: bytes
 *   Line       := mount: str, line: id
 *   Block      := index: uvarint, kind: enum block, failed: bool, id: str,
 *                 name: str, text: str, is_ref: bool, blob: Blob
 *   Message    := id: rid, role: enum role, author: id, parent: rid,
 *                 depth: ivarint, runner: id, hlc: uvarint, provider: str,
 *                 model: str, native: str, intent: rid, status: enum seal,
 *                 open: bool, open_state: enum open_state, seal: rid,
 *                 usage: Usage, redacted: bool, sibling: uvarint,
 *                 siblings: uvarint, superseded: bool, landed: bool,
 *                 claim: rid, files: [File], lines: [Line], blocks: [Block]
 *   Position   := msg: rid, seal: rid, seal_known: bool
 *   Page       := messages: [Message], next: Edge, more: bool,
 *                 cursor: bytes
 *                 (dir older: newest first, toward the root; dir newer:
 *                 oldest first, toward leaf or the reader's position)
 *   Window     := messages: [Message] (oldest first), anchor: uvarint (index
 *                 of the anchor in messages), older: Edge, newer: Edge,
 *                 more_older: bool, more_newer: bool, leaf: rid,
 *                 older_cursor: bytes, newer_cursor: bytes
 *   Edge       := Position when there is more in that direction; otherwise
 *                 JSON null (binary: an all-zero Position). An absent from
 *                 means "start at the reader's position", so never page from
 *                 an exhausted edge: continue with the cursor instead.
 *   cursor     := opaque bytes carrying direction, position, leaf and an end
 *                 mark. Pass it as convo.page's cursor argument (it overrides
 *                 from, dir and leaf); an end cursor returns an empty page with
 *                 more=false and the same end cursor.
 *   Attachment := name: str, mime: str, oid: bytes, size: uvarint
 *   Intent     := item: rid, latest: rid, kind: enum intent, by: id,
 *                 stamp: uvarint, text: str, target: rid, allow: bool,
 *                 tasks: ids, condition: enum condition, deadline: uvarint,
 *                 expr: str, attachments: [Attachment]
 *   Mount      := name: str, tree: id, line: id, path: str, stamp: uvarint,
 *                 by: id, removed: bool
 *   Compaction := at: rid, from: rid, to: rid, summary: str, blob: Blob,
 *                 stamp: uvarint
 *   Unsealed   := msg: rid, state: enum open_state, attempt: uvarint
 *   Settings   := title: str, agent: id, workspace: id, parent: Xref,
 *                 provider: str, model: str
 *   Xref       := object: id, msg: rid
 *   Register   := tag: uvarint, hlc: uvarint, by: id, value: bytes
 *   Element    := tag: uvarint, value: bytes, live: uvarint
 *   Counter    := tag: uvarint, value: ivarint
 *   Entry      := key: bytes, registers: [Register], elements: [Element],
 *                 counters: [Counter]
 *   CatalogRow := object: object, kind: enum kind, title: str, parent: Xref,
 *                 workspace: id, agent: id, status: enum convo_status,
 *                 activity: uvarint, archived: bool, pinned: bool
 *   CatalogEntry := object: object, kind: enum kind, title: str, parent: Xref,
 *                 workspace: id, agent: id, participants: ids,
 *                 status: enum convo_status, activity: uvarint,
 *                 archived: bool, pinned: bool, takeover: enum takeover
 *   Space      := id: id, name: str, relay: str, relay_key: bytes,
 *                 mode: enum mode, open: bool, connected: bool, catalog: id,
 *                 relay_usage: uvarint, relay_quota: uvarint (
 *                 the bytes the relay stores for the space and its quota,
 *                 as of the last connect)
 *   RelayAccount := accounted: bool, stored: uvarint, quota: uvarint,
 *                 appends: uvarint, bytes_in: uvarint, notes: uvarint,
 *                 fills: uvarint, pulls: uvarint, piped_bytes: uvarint,
 *                 store_writes: uvarint, store_bytes: uvarint,
 *                 pending: uvarint, day: uvarint, day_bytes: uvarint,
 *                 total_bytes: uvarint (since 2.0: the relay's accounting
 *                 for the space as of its last Accounted reply; counters
 *                 since the relay loaded the space, store_* from its
 *                 object-store tier, day = UTC days since 1970)
 *   Identity   := id: id, sign: bytes, box: bytes
 *   AccountState := signed_in: bool, account: bytes, subject: str,
 *                 pool: enum pool_access, relay: str, waiting: bool,
 *                 code: str, no_approver: bool (account fields are empty
 *                 when signed_in is false, code when waiting is false)
 *   Approval   := device: id, code: str, label: str, at: ivarint
 *   Span       := lo: uvarint, hi: uvarint, line_lo: uvarint,
 *                 line_hi: uvarint, actor: id, seq: uvarint, op_actor: id,
 *                 op_seq: uvarint, redacted: bool
 *   Mounted    := object: object, root: str, line: str
 *   Hit        := object: object, participant: id, msg: rid, ref: bytes,
 *                 part: uvarint, kind: enum kind, title: bool, hlc: uvarint,
 *                 score: f64, snippet: str, snippet_at: uvarint,
 *                 matches: [ {start: uvarint, len: uvarint} ]
 *   Results    := hits: [Hit], cursor: bytes, incomplete: bool,
 *                 verified: uvarint, partial: bool, behind: uvarint,
 *                 sources: [Source] (filled when search is
 *                 given a space)
 *   Source     := device: id, local: bool, state: enum search_state,
 *                 behind: uvarint, hits: uvarint, rejected: uvarint
 *   Wrote      := scope: id, object: id, ref: bytes, hlc: uvarint,
 *                 lo: uvarint, hi: uvarint, known: bool
 *   Stats      := ticks, commits, durable, handles, opened, evicted, pending,
 *                 subs, fetches, indexed, wakeups, calls, mounts: uvarint
 *   Workspace  := name: str, agent: id, provider: str, model: str,
 *                 runner_policy: bytes, setup: str, access: bytes,
 *                 members: [ {object: id, kind: enum kind,
 *                 role: enum member_role, mount: str, path: str} ],
 *                 linked: strs, takeover: enum takeover
 *   Agent      := name: str, instructions: str, driver: str, provider: str,
 *                 model: str, options: bytes, budget: bytes, workspace: id,
 *                 runner_policy: bytes, tools: [bytes], memory: ids,
 *                 triggers: [bytes], takeover: enum takeover
 *   Delta      := kind: enum delta, object: object, rid: rid, msg: rid,
 *                 record: uvarint, by: id, local: bool, hlc: uvarint,
 *                 role: enum role, index: uvarint, block: enum block,
 *                 seal: enum seal, status: enum convo_status, usage: Usage,
 *                 text: str, key: bytes, tag: uvarint, removed: bool,
 *                 length: ivarint
 *   Deltas     := deltas: [Delta]
 *   BufferEvent := kind: enum{open,delta,cursors,closed}, buffer: uvarint,
 *                 rev: uvarint, ack: uvarint, length: uvarint, text: str,
 *                 more: bool, actor: id, line: str, ops: [ {kind:
 *                 enum{retain,delete,insert}, n: uvarint, text: str,
 *                 author: id} ], cursors: [ {device: id, actor: id,
 *                 ranges: [ {anchor: ivarint, head: ivarint} ]} ],
 *                 status: enum status (since 2.0). buffer.open is a
 *                 subscription: its first payload (the daemon's subscribe
 *                 result, or the first callback of ondb_subscribe) is kind
 *                 open with the snapshot's first page in text, more set when
 *                 the rest must be read with buffer.read; later payloads are
 *                 delta (ops against the previous rev, in the buffer's units;
 *                 insert n counts units of text, which is UTF-8), cursors
 *                 (remote cursors resolved at rev; -1 when not yet known) and
 *                 closed. ondb_unsubscribe closes the buffer. Clients keep
 *                 their unacknowledged edits, drop those with seq <= ack and
 *                 transform each delta over the rest (their own insert first
 *                 at equal positions) before applying it; buffer.edit takes
 *                 sorted non-overlapping edits against the client's text at
 *                 rev plus its earlier edits, returns ack and rev, and
 *                 fails with conflict once rev is too old to transform
 *                 (reopen). Every delta the edit was transformed over is
 *                 delivered before its result, so the result's rev never
 *                 exceeds the deltas a client has received and either ack
 *                 source may drop acknowledged edits.
 *                 Anchors are opaque strings ("s", "e", or
 *                 "<actor hex>.<seq>[.<offset>].<b|a>").
 *   Event      := kind: enum event, space: id, object: id, device: id,
 *                 tick: uvarint, length: ivarint, status: enum status,
 *                 detail: str, Placement (zero unless kind is
 *                 placement, delivered whenever a conversation's placement
 *                 changes when the runtime is enabled); presence carries
 *                 device, tick 1 up or 0 down and length the relay's time;
 *                 caught_up carries space and length the relay feed
 *                 position the device has read up to; indexer_wanted
 *                 carries the space a search wanted a full indexer in
 *                 while none was online; unavailable carries object and
 *                 one holder device per event when a device-only range of
 *                 object has no holder online (reads stay pending and
 *                 complete when a holder returns, followed by available);
 *                 promoted carries object, a segment's writer as device
 *                 and length the bytes filled into the relay;
 *                 peer_misbehaving carries the device whose served bytes
 *                 failed verification
 *   Placement  := state: enum placement, msg: rid, runner: id, provider: str,
 *                 since_ms: ivarint, last_runner: id (assigned and running:
 *                 runner runs msg; waiting_runner: msg waits since since_ms
 *                 for runner, a pool runner the host may wake or a pool, or
 *                 for any runner when runner is zero; idle: nothing moves on
 *                 its own, msg is set when its turn was cut off on
 *                 last_runner; placing: the scheduler plug has not answered)
 *   Runner     := device: id, name: str, kind: enum runner_kind,
 *                 state: enum runner_state, providers: strs,
 *                 signed_in: strs, current: bool, last: bool (a pool is one
 *                 entry: device is its member id, name its label)
 *   Runners    := runners: [Runner]
 *   Description := version: uvarint, ops: [ {code: uvarint, name: str,
 *                 args: [ {name: str, type: str, values: strs} ],
 *                 result: str} ]
 *   RuntimeStats := runner: bool, active_runs, warm_processes,
 *                 runs_started, runs_finished, evaluations, spawns,
 *                 warm_hits, raw_lines, tool_calls, schedules, timers: uvarint
 *   Models     := providers: [ {id: str, name: str, command: str,
 *                 protocol: enum{claude_stream_json,codex_app_server,pi_rpc,
 *                 muse,acp}, available: bool} ], models: [ {id: str,
 *                 api: enum{anthropic,openai_responses,openai_chat},
 *                 context_window: uvarint} ], default_provider: str,
 *                 default_model: str
 *   AgentInfo  := agent: object, name: str, driver: enum{harness,native},
 *                 provider: str, model: str, effort: str,
 *                 ask_permissions: bool, observe: bool, workspace: id,
 *                 instructions: str, budget_tokens: uvarint, budget_usd: f64,
 *                 budget_turns: uvarint, budget_seconds: ivarint
 *   TaskStatus := status: str (queued, running, waiting, completed, failed,
 *                 cancelled), summary: str, cancelled: bool, reason: str,
 *                 budget_tokens: uvarint, budget_usd: f64
 *   Change     := mount: str, path: str, change: str
 *   Schedule   := id: str, owner: object, prompt: str, cron: str, at: ivarint,
 *                 tz: str, conversation: id, fresh: bool, next: ivarint,
 *                 last: ivarint, creator: id, agent: id
 *
 * Ops: see ONDB_OPS below (generated from ondb_describe).
 */
#ifndef ONDB_H
#define ONDB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ONDB_ABI_MAJOR 2u
#define ONDB_ABI_MINOR 0u
#define ONDB_ABI_VERSION ((ONDB_ABI_MAJOR << 16) | ONDB_ABI_MINOR)

typedef struct ondb ondb;

enum ondb_status {
	ONDB_OK = 0,
	ONDB_PENDING = 1,
	ONDB_NOT_FOUND = 2,
	ONDB_EXISTS = 3,
	ONDB_INVALID = 4,
	ONDB_BUSY = 5,
	ONDB_CLOSED = 6,
	ONDB_OFFLINE = 7,
	ONDB_PERMISSION = 8,
	ONDB_FORGED = 9,
	ONDB_QUARANTINED = 10,
	ONDB_MISSING = 11,
	ONDB_CORRUPT = 12,
	ONDB_LIMIT = 13,
	ONDB_TOO_LARGE = 14,
	ONDB_UNSUPPORTED = 15,
	ONDB_NOT_ASSIGNED = 16,
	ONDB_NO_SPACE = 17,
	ONDB_NO_MEMORY = 18,
	ONDB_IO = 19,
	ONDB_BAD_REQUEST = 20,
	ONDB_UNKNOWN_OP = 21,
	ONDB_CONFLICT = 22,
	ONDB_CANCELLED = 23,
	ONDB_BUDGET = 24,
	ONDB_SPAWN = 25,
	ONDB_TIMEOUT = 26
};

/* Errors returned by Vfs and Spawner plug functions (0 = success). */
enum ondb_io_error {
	ONDB_IO_NONE = 0,
	ONDB_IO_NOT_FOUND = 1,
	ONDB_IO_EXISTS = 2,
	ONDB_IO_PERMISSION = 3,
	ONDB_IO_WOULD_BLOCK = 4,
	ONDB_IO_INTERRUPTED = 5,
	ONDB_IO_BROKEN_PIPE = 6,
	ONDB_IO_BUSY = 7,
	ONDB_IO_INVALID = 8,
	ONDB_IO_NOT_DIR = 9,
	ONDB_IO_IS_DIR = 10,
	ONDB_IO_NOT_EMPTY = 11,
	ONDB_IO_NO_SPACE = 12,
	ONDB_IO_TOO_MANY_FILES = 13,
	ONDB_IO_NAME_TOO_LONG = 14,
	ONDB_IO_TOO_LARGE = 15,
	ONDB_IO_UNSUPPORTED = 16,
	ONDB_IO_NO_MEMORY = 17,
	ONDB_IO_NO_CHILD = 18,
	ONDB_IO_EIO = 19
};

/* ondb_call / ondb_subscribe / ondb_describe flags */
#define ONDB_JSON 1u

/* ondb_config.flags */
#define ONDB_NO_VERIFY (1u << 0)   /* do not verify signed segment chains */
#define ONDB_NO_KTLS (1u << 1)     /* never offload relay TLS to the kernel */
#define ONDB_PADDING (1u << 2)     /* pad appends and objects to size buckets */
#define ONDB_NO_SEARCH (1u << 3)   /* no derived search indexes */
#define ONDB_DEFERRED (1u << 4)    /* the embedder makes writes durable (ondb "flush" op) */
#define ONDB_EVENTS_JSON (1u << 5) /* deliver Event payloads as JSON */
#define ONDB_IDLE_PAGEOUT (1u << 6) /* ignored: an idle engine always returns heap and never pages out code */
#define ONDB_SEARCH_FULL (1u << 7) /* keep a full search index of every space and serve peer queries */
#define ONDB_STORAGE_SHIFT 8       /* bits 8-9: storage mode: */
#define ONDB_STORAGE_AUTO 0u       /*   relay stores conversations and metadata (default) */
#define ONDB_STORAGE_STORED 1u     /*   relay stores everything (pool runners) */
#define ONDB_STORAGE_UNTIL_RUN 2u  /*   device-only until a pool runner is assigned */
#define ONDB_STORAGE_DEVICE 3u     /*   strict device-only, peers serve through the relay pipe */

/* ---- plug points (every table: size = sizeof(table), ud passed back) ---- */

typedef struct ondb_stat {
	int64_t size;
	uint32_t mode;
	uint32_t kind; /* 0 unknown, 1 file, 2 dir, 3 symlink, 4 other */
	uint64_t ino;
	uint64_t dev;
	uint64_t nlink;
	int64_t mtime_ns;
	int64_t ctime_ns;
} ondb_stat;

typedef struct ondb_dirent {
	const char *name; /* valid until the next dir_next/dir_close */
	size_t name_len;
	uint64_t ino;
	uint32_t kind;
} ondb_dirent;

/* Open flags */
#define ONDB_O_WRITE (1u << 0)
#define ONDB_O_CREATE (1u << 1)
#define ONDB_O_TRUNCATE (1u << 2)
#define ONDB_O_EXCLUSIVE (1u << 3)
#define ONDB_O_APPEND (1u << 4)
#define ONDB_O_NONBLOCK (1u << 5)
#define ONDB_O_DIRECTORY (1u << 6)

/* Vfs capabilities */
#define ONDB_VFS_DURABLE_DIR_OPS (1u << 0)
#define ONDB_VFS_ATOMIC_GROUP_COMMIT (1u << 1)

/* Every path is NUL-terminated; the length excludes the NUL. All functions
   return 0 or an ondb_io_error. Optional members may be NULL: fullsync,
   truncate, punch_hole, lock, rmdir, symlink, readlink, fchmod, set_times,
   caps. */
typedef struct ondb_vfs {
	uint32_t size;
	void *ud;
	int (*open)(void *ud, const char *path, size_t len, uint32_t flags, uint32_t mode, int32_t *fd);
	int (*close)(void *ud, int32_t fd);
	int (*read_at)(void *ud, int32_t fd, uint8_t *buf, size_t len, int64_t off, size_t *n);
	int (*write_at)(void *ud, int32_t fd, const uint8_t *src, size_t len, int64_t off);
	int (*datasync)(void *ud, int32_t fd);
	int (*fullsync)(void *ud, int32_t fd);
	int (*truncate)(void *ud, int32_t fd, int64_t size);
	int (*punch_hole)(void *ud, int32_t fd, int64_t off, int64_t size);
	int (*lock)(void *ud, int32_t fd);
	int (*fstat)(void *ud, int32_t fd, ondb_stat *st);
	int (*stat)(void *ud, const char *path, size_t len, int follow, ondb_stat *st);
	int (*rename)(void *ud, const char *from, size_t from_len, const char *to, size_t to_len);
	int (*unlink)(void *ud, const char *path, size_t len);
	int (*rmdir)(void *ud, const char *path, size_t len);
	int (*mkdir)(void *ud, const char *path, size_t len, uint32_t mode);
	int (*symlink)(void *ud, const char *target, size_t target_len, const char *path, size_t len);
	int (*readlink)(void *ud, const char *path, size_t len, uint8_t *buf, size_t cap, size_t *n);
	int (*fchmod)(void *ud, int32_t fd, uint32_t mode);
	int (*set_times)(void *ud, const char *path, size_t len, int64_t atime_ns, int64_t mtime_ns);
	int (*dir_open)(void *ud, const char *path, size_t len, void **dir);
	int (*dir_next)(void *ud, void *dir, ondb_dirent *ent); /* 1 entry, 0 end, -error */
	void (*dir_close)(void *ud, void *dir);
	uint32_t (*caps)(void *ud, int32_t fd);
} ondb_vfs;

typedef struct ondb_identity {
	uint8_t id[16];
	uint8_t sign[32]; /* Ed25519 public key */
	uint8_t box[32];  /* X25519 public key */
} ondb_identity;

typedef struct ondb_content_key {
	uint8_t key[32];
	uint32_t epoch;
} ondb_content_key;

#define ONDB_WRAP_LEN 84

/* Device key custody. Functions return 0 on success. verify may be NULL
   (Ed25519 verification is then done by the engine). */
typedef struct ondb_keyring {
	uint32_t size;
	void *ud;
	void (*identity)(void *ud, ondb_identity *out);
	int (*sign)(void *ud, const uint8_t *msg, size_t len, uint8_t sig[64]);
	int (*wrap)(void *ud, const ondb_identity *recipient, const ondb_content_key *key, uint8_t out[ONDB_WRAP_LEN]);
	int (*unwrap)(void *ud, const uint8_t *wrapped, size_t len, ondb_content_key *key);
	int (*verify)(void *ud, const ondb_identity *signer, const uint8_t *msg, size_t len, const uint8_t *sig, size_t sig_len);
} ondb_keyring;

/* Asynchronous plug calls. Every request-reply plug function (credentials
   produce, unlock, enroll, sealed store get/put/add, runner pool
   verify/attest/renew, scheduler place) receives an ondb_plug_call handle and completes it with
   exactly one ondb_plug_done, either before returning (a synchronous answer)
   or later from any thread. status is an ondb_status: ONDB_OK, or
   ONDB_NOT_FOUND, ONDB_CONFLICT, ONDB_PERMISSION, ONDB_UNSUPPORTED,
   ONDB_TIMEOUT, ONDB_CANCELLED, ONDB_INVALID; anything else counts as an I/O
   error. reply (NULL for errors) is copied before ondb_plug_done returns;
   set size = sizeof(ondb_plug_reply) and only the fields the function
   answers: record and entries (each entry a u32le length then the entry) for
   get, credential and prf for unlock, credential, prf and ecosystem for
   enroll, lease_ms for verify and renew, credential for produce, runner for place. The optional cancel
   member of each table tells the embedder that the engine no longer waits
   for that call (the user cancelled, a deadline passed, the engine closed);
   ondb_plug_done must still be called once for it, and its answer is
   ignored. The handle is valid until ondb_plug_done. */
typedef struct ondb_plug_call ondb_plug_call;

typedef struct ondb_plug_reply {
	uint32_t size;
	const uint8_t *record;
	size_t record_len;
	const uint8_t *entries;
	size_t entries_len;
	const uint8_t *credential;
	size_t credential_len;
	uint8_t prf[32];
	int32_t ecosystem;
	uint64_t lease_ms;
	uint8_t runner[16];
} ondb_plug_reply;

int ondb_plug_done(ondb_plug_call *call, int status, const ondb_plug_reply *reply);

/* Relay credentials per space. available returns nonzero when the embedder
   supplies credentials for the space (otherwise the space key is used);
   produce answers the credential for one connection binding (reply
   credential, at most 8192 bytes). cancel may be NULL. */
typedef struct ondb_credentials {
	uint32_t size;
	void *ud;
	int (*available)(void *ud, const uint8_t space[16]);
	void (*produce)(void *ud, const uint8_t space[16], const uint8_t *binding, size_t binding_len, ondb_plug_call *call);
	void (*cancel)(void *ud, ondb_plug_call *call);
} ondb_credentials;

typedef struct ondb_peer {
	uint8_t space[16];
	const char *relay;
	size_t relay_len;
	uint8_t relay_key[32];
} ondb_peer;

/* Byte transport to a relay. The embedder reports connection progress with
   ondb_link_up / ondb_link_input / ondb_link_writable / ondb_link_down on the
   engine thread. send returns 0 (all or part sent, *sent set), ONDB_BUSY
   when it would block (then call ondb_link_writable later), or any other
   status when the connection is gone. */
typedef struct ondb_transport {
	uint32_t size;
	void *ud;
	int (*open)(void *ud, ondb *h, uint64_t link, const ondb_peer *peer, void **conn);
	int (*send)(void *ud, void *conn, const uint8_t *data, size_t len, size_t *sent);
	void (*close)(void *ud, void *conn);
} ondb_transport;

/* Either member may be NULL (system clock). */
typedef struct ondb_clock {
	uint32_t size;
	void *ud;
	int64_t (*mono_ns)(void *ud);
	int64_t (*wall_ns)(void *ud);
} ondb_clock;

typedef struct ondb_random {
	uint32_t size;
	void *ud;
	void (*fill)(void *ud, uint8_t *out, size_t len);
} ondb_random;

typedef struct ondb_child {
	int32_t pid;
	int32_t stdin_fd;  /* non-blocking pipes, -1 when absent */
	int32_t stdout_fd;
	int32_t stderr_fd;
	int32_t group;     /* nonzero: pid leads its own process group */
} ondb_child;

#define ONDB_SPAWN_NEW_GROUP (1u << 0)
#define ONDB_SPAWN_OBSERVE (1u << 1)

/* argv and env are NULL-terminated arrays (argc/envc entries). cwd may be
   NULL. Returns 0 or an ondb_io_error. */
typedef struct ondb_spawner {
	uint32_t size;
	void *ud;
	int (*spawn)(void *ud, const char *const *argv, size_t argc, const char *cwd, const char *const *env, size_t envc, uint32_t flags, ondb_child *out);
} ondb_spawner;

typedef struct ondb_header {
	const char *name;
	size_t name_len;
	const char *value;
	size_t value_len;
} ondb_header;

typedef struct ondb_slice {
	const uint8_t *ptr;
	size_t len;
} ondb_slice;

typedef struct ondb_http_request {
	const char *method;
	size_t method_len;
	const char *url;
	size_t url_len;
	const ondb_header *headers;
	size_t header_count;
	const ondb_slice *body; /* gathered body pieces; like every field here, valid only during start: copy what you send later */
	size_t body_count;
	int64_t body_len;
	int32_t streamed; /* nonzero: pull the body with ondb_http_read */
	uint32_t version; /* 0 auto, 1 HTTP/1.1, 2 HTTP/2, 3 HTTP/2 prior knowledge */
	int64_t connect_ms;
	int64_t stall_ms;
	int64_t timeout_ms;
	int32_t follow;
} ondb_http_request;

/* HTTP client. The embedder reports the response with ondb_http_head,
   ondb_http_body and finally ondb_http_done, on the engine thread. */
typedef struct ondb_http {
	uint32_t size;
	void *ud;
	int (*start)(void *ud, ondb *h, uint64_t id, const ondb_http_request *req);
	void (*cancel)(void *ud, uint64_t id);
	void (*resume)(void *ud, uint64_t id);
} ondb_http;

/* ondb_http_done error codes */
enum ondb_http_error {
	ONDB_HTTP_OK = 0,
	ONDB_HTTP_CANCELLED = 1,
	ONDB_HTTP_DNS = 2,
	ONDB_HTTP_CONNECT = 3,
	ONDB_HTTP_TLS = 4,
	ONDB_HTTP_TIMEOUT = 5,
	ONDB_HTTP_STALLED = 6,
	ONDB_HTTP_RESET = 7,
	ONDB_HTTP_PROTOCOL = 8,
	ONDB_HTTP_TOO_LARGE = 9,
	ONDB_HTTP_UNSUPPORTED = 10,
	ONDB_HTTP_BODY = 11,
	ONDB_HTTP_NO_MEMORY = 12,
	ONDB_HTTP_OTHER = 13
};

/* Write attribution. start/stop bracket observation; the embedder pushes
   observed writes with ondb_observed_write. writer, when set, is asked which
   process wrote an absolute path (return nonzero and set *pid when known). */
typedef struct ondb_write_observer {
	uint32_t size;
	void *ud;
	int (*start)(void *ud, ondb *h);
	void (*stop)(void *ud, ondb *h);
	int (*writer)(void *ud, const char *path, size_t len, int32_t *pid);
} ondb_write_observer;

/* Vector embeddings for semantic search. Returns 0 and fills dim floats. */
typedef struct ondb_embedder {
	uint32_t size;
	void *ud;
	uint32_t dim;
	int (*embed)(void *ud, uint32_t kind, const uint8_t *text, size_t len, float *out, size_t dim);
} ondb_embedder;

/* level: 0 debug, 1 info, 2 warn, 3 error */
typedef struct ondb_log {
	uint32_t size;
	void *ud;
	void (*write)(void *ud, int level, const char *msg, size_t len);
} ondb_log;

/* Routes cross-device search queries to the embedder's own indexer instead
   of a full indexer reached through the relay. query is called
   on the engine loop with id and a RemoteQuery payload; answer later on the
   loop with ondb_search_answer(h, id, RemoteAnswer). The answer is verified
   like any peer's: every ref is fetched, chain-verified, decrypted and
   re-matched locally, so a hosted indexer can hide results but not inject
   them. cancel tells the indexer the search ended without its answer.
     RemoteQuery  := u8 version(=1), id space, u16 limit, u16 skip,
                     u8 sort, u64 now (hlc), u16 n + cursor, u16 n + query
     RemoteAnswer := u8 version(=1), u8 kind(=2), u8 state, u32 behind,
                     u16 n + cursor, u16 count, count * RemoteRef,
                     u16 marks, marks * (id object, id device, u64 indexed)
     RemoteRef    := id object, u8 n + ref, u32 part, u8 kind, u64 hlc,
                     f64 score, u8 spans, spans * (u32 start, u32 len)
   All integers little endian; state uses the search_state enum. */
typedef struct ondb_search_remote {
	uint32_t size;
	void *ud;
	int (*query)(void *ud, ondb *h, uint64_t id, const uint8_t *payload, size_t len);
	void (*cancel)(void *ud, ondb *h, uint64_t id);
} ondb_search_remote;

/* Engine events (connectivity, durability, uploads, quarantine...), as an
   Event payload. */
typedef struct ondb_events {
	uint32_t size;
	void *ud;
	void (*event)(void *ud, const uint8_t *payload, size_t len);
} ondb_events;

/* ---- runtime (runs, runners, triggers, channels, orchestration) ---- */

/* A model wire format implemented by the embedder. The request
   body is head + messages joined with ',' + tail; each callback appends bytes
   with ondb_sink_write. head receives {model, max_tokens, kind, system,
   tools: [{name, description, schema}]} as JSON; message receives
   {role: "user"|"assistant", blocks: [...]} where a block is one of
   {type:"text",text}, {type:"image",mime,data(base64),url},
   {type:"document",mime,title,text,data,url}, {type:"tool_use",id,name,input},
   {type:"tool_result",id,is_error,content:[blocks]},
   {type:"thinking",text,signature}; tail receives the request kind
   (0 normal, 1 compact, 2 keepalive). headers writes "Name: value" lines.
   The response must be text/event-stream: parse is called once per SSE event
   and reports what it saw with ondb_wire_emit. classify (optional) maps an
   error response to a failure class (return 0 for the default mapping).
   Every callback returns 0 on success. */
typedef struct ondb_sink ondb_sink;
typedef struct ondb_emit ondb_emit;

enum ondb_wire_kind {
	ONDB_WIRE_START = 0,       /* id: message id */
	ONDB_WIRE_BLOCK_START = 1, /* index, block, id/name for tool calls */
	ONDB_WIRE_TEXT = 2,        /* index, text */
	ONDB_WIRE_THINKING = 3,    /* index, text */
	ONDB_WIRE_TOOL_INPUT = 4,  /* index, text: a fragment of the JSON input */
	ONDB_WIRE_BLOCK_STOP = 5,  /* index */
	ONDB_WIRE_USAGE = 6,       /* token counts (cumulative) */
	ONDB_WIRE_STOP = 7,        /* stop */
	ONDB_WIRE_ERROR = 8        /* failure, text, retry_after */
};
/* block: 0 text, 1 thinking, 2 tool_call, 3 other
   stop: 0 none, 1 end_turn, 2 tool_use, 3 max_tokens, 4 stop_sequence,
         5 pause_turn, 6 refusal, 7 context_exceeded, 8 compaction, 9 other
   failure: 1 network, 2 server, 3 overloaded, 4 rate_limited, 5 too_long,
            6 auth, 7 invalid, 8 quota, 9 malformed, 10 fatal */
typedef struct ondb_wire_event {
	uint32_t kind;
	uint32_t block;
	int32_t index;
	const char *id;
	size_t id_len;
	const char *name;
	size_t name_len;
	const char *text;
	size_t text_len;
	uint64_t input_tokens;
	uint64_t output_tokens;
	uint64_t cache_read_tokens;
	uint64_t cache_write_tokens;
	uint64_t reasoning_tokens;
	uint32_t stop;
	uint32_t failure;
	int64_t retry_after_ms;
} ondb_wire_event;

typedef struct ondb_wire {
	uint32_t size;
	void *ud;
	int (*head)(void *ud, const uint8_t *request, size_t len, ondb_sink *out);
	int (*message)(void *ud, const uint8_t *message, size_t len, ondb_sink *out);
	int (*tail)(void *ud, uint32_t kind, ondb_sink *out);
	int (*headers)(void *ud, const char *api_key, size_t key_len, ondb_sink *out);
	int (*parse)(void *ud, uint64_t stream, const char *event, size_t event_len, const uint8_t *data, size_t data_len, ondb_emit *emit);
	int (*classify)(void *ud, int32_t status, const uint8_t *body, size_t len, int64_t *retry_after_ms);
} ondb_wire;

int ondb_sink_write(ondb_sink *sink, const uint8_t *data, size_t len);
int ondb_wire_emit(ondb_emit *emit, const ondb_wire_event *ev);

/* Resolve a provider/model for the native model loop. Return 0 when
   resolved; strings are copied. With wire NULL the request is built by the
   reference adapter for api; with wire set by the embedder. */
typedef struct ondb_model_config {
	uint32_t api; /* 0 anthropic, 1 openai_responses, 2 openai_chat */
	const char *url;
	size_t url_len;
	const char *api_key;
	size_t api_key_len;
	int32_t bearer;
	uint64_t max_tokens;
	uint64_t context_window; /* for models unknown to the engine */
	uint64_t max_output;
	const ondb_wire *wire;
} ondb_model_config;

typedef struct ondb_model {
	uint32_t size;
	void *ud;
	int (*resolve)(void *ud, const char *provider, size_t provider_len, const char *model, size_t model_len, ondb_model_config *out);
} ondb_model;

typedef struct ondb_tool_def {
	const char *name;
	size_t name_len;
	const char *description;
	size_t description_len;
	const char *schema; /* JSON Schema of the input */
	size_t schema_len;
} ondb_tool_def;

typedef struct ondb_tool_call {
	uint64_t token;
	uint8_t space[16];
	uint8_t object[16];
	uint8_t agent[16];
	const char *id;
	size_t id_len;
	const char *name;
	size_t name_len;
	const char *input; /* JSON */
	size_t input_len;
	const char *cwd;
	size_t cwd_len;
} ondb_tool_call;

/* Embedder tools for native agents. list fills up to cap definitions and
   returns how many exist (call again with a larger array when more).
   call returns nonzero when it handles the tool; the result is delivered
   later with ondb_tool_result. abort cancels a call by token. */
typedef struct ondb_tools {
	uint32_t size;
	void *ud;
	size_t (*list)(void *ud, const uint8_t space[16], const uint8_t agent[16], ondb_tool_def *out, size_t cap);
	int (*call)(void *ud, ondb *h, const ondb_tool_call *call);
	void (*abort)(void *ud, uint64_t token);
} ondb_tools;

/* Outbound replies of channel-triggered conversations. */
typedef struct ondb_channels {
	uint32_t size;
	void *ud;
	void (*send)(void *ud, const char *channel, size_t channel_len, const char *key, size_t key_len,
	             const uint8_t space[16], const uint8_t object[16], const char *text, size_t text_len);
} ondb_channels;

typedef struct ondb_placement {
	uint32_t kind; /* 0 message, 1 takeover, 2 intent, 3 revive, 4 schedule, 5 channel */
	uint8_t space[16];
	uint8_t object[16];
	uint8_t msg_seg[16];
	int64_t msg_off;
	uint8_t sender[16];
	uint8_t agent[16];
	const uint8_t *policy;
	size_t policy_len;
	uint64_t msg_gen;
	uint8_t exclude[16]; /* a runner the work must leave */
	uint8_t prefer[16];  /* the runner it last ran on, or the parent conversation's */
	const char *provider;
	size_t provider_len;
} ondb_placement;

/* Run placement, asynchronous (see ondb_plug_call): complete with ONDB_OK and
   reply runner set to the device or pool runner that runs it (all zero keeps
   the work waiting), or with ONDB_NOT_FOUND (or any error) for the
   reference policy. The runtime keeps the answer per placement and asks
   again when a runner's presence or advert changes; the conversation's
   placement is "placing" until the answer arrives. cancel may be NULL. */
typedef struct ondb_scheduler {
	uint32_t size;
	void *ud;
	void (*place)(void *ud, const ondb_placement *p, ondb_plug_call *call);
	void (*cancel)(void *ud, ondb_plug_call *call);
} ondb_scheduler;

/* Secrets such as ANTHROPIC_API_KEY. Return 0 when found. When absent the
   process environment is used. */
typedef struct ondb_secrets {
	uint32_t size;
	void *ud;
	int (*get)(void *ud, const char *name, size_t name_len, char *out, size_t cap, size_t *len);
} ondb_secrets;

#define ONDB_RT_RUNNER (1u << 0)    /* this engine executes runs */
#define ONDB_RT_OBSERVE (1u << 1)   /* attribute writes with the reference observer */
#define ONDB_RT_MCP_HTTP (1u << 2)  /* serve the catalog to harnesses over local HTTP */
#define ONDB_RT_NO_ATTACH (1u << 3) /* do not attach existing spaces at open */
#define ONDB_RT_POOL (1u << 4)      /* advertise this runner as a pool runner with an ephemeral sandbox */

typedef struct ondb_runtime {
	uint32_t size; /* sizeof(ondb_runtime) */
	uint32_t flags;
	const char *work_root; /* NULL: <dir>/work */
	const char *default_provider;
	const char *default_model;
	const char *home_dir;
	int32_t capacity;
	int32_t warm_max;
	int64_t warm_idle_ms;
	int64_t interrupt_ms;
	uint64_t lease_ms;
	int32_t mcp_port;
	uint8_t default_runner[16];
	const ondb_model *model;
	const ondb_tools *tools;
	const ondb_channels *channels;
	const ondb_scheduler *scheduler;
	const ondb_secrets *secrets;
	const char *name; /* this runner's display name in the runner directory */
} ondb_runtime;

/* Any plug pointer may be NULL to use the reference implementation. */
/* Account sign-in plugs, asynchronous (see ondb_plug_call); the engine keeps
   serving everything else while a call is outstanding.

   unlock: the platform passkey (WebAuthn PRF / CTAP2 hmac-secret). unlock
   evaluates PRF with the given per-credential salts and answers the chosen
   credential id and the 32-byte output (ONDB_NOT_FOUND when none of the
   credentials is available); mode 0 is this device, 1 is a passkey on
   another device (hybrid/QR). enroll registers a new platform passkey for
   rp_user and answers its credential id, PRF output for salt and ecosystem
   (0 unknown, 1 apple, 2 google, 3 microsoft, 4 1password, 5 bitwarden,
   6 security_key, 7 recovery, 8 test). User verification must always be
   required. */
typedef struct ondb_unlock_option {
	const uint8_t *credential;
	size_t credential_len;
	uint8_t salt[32];
} ondb_unlock_option;

typedef struct ondb_unlock {
	uint32_t size;
	void *ud;
	void (*unlock)(void *ud, const uint8_t *rp_user, size_t rp_user_len, const ondb_unlock_option *options, size_t count, int mode, ondb_plug_call *call);
	void (*enroll)(void *ud, const uint8_t *rp_user, size_t rp_user_len, const char *label, size_t label_len, const uint8_t salt[32], ondb_plug_call *call);
	void (*cancel)(void *ud, ondb_plug_call *call);
} ondb_unlock;

/* The embedder's account server, keyed by its opaque login subject. get
   answers the newest account record (at most 64 KiB) and the manifest
   entries, each as a u32le length followed by the entry (at most 4 MiB in
   all), or ONDB_NOT_FOUND; put stores a record only if the stored one has
   seq prev_seq (otherwise ONDB_CONFLICT; a put repeating the stored record
   exactly answers ONDB_OK); add appends one manifest entry (the engine keeps
   unconfirmed entries and offers them again until one is stored). */
typedef struct ondb_sealed_store {
	uint32_t size;
	void *ud;
	void (*get)(void *ud, const uint8_t *subject, size_t subject_len, ondb_plug_call *call);
	void (*put)(void *ud, const uint8_t *subject, size_t subject_len, const uint8_t *record, size_t record_len, uint64_t prev_seq, ondb_plug_call *call);
	void (*add)(void *ud, const uint8_t *subject, size_t subject_len, const uint8_t *entry, size_t entry_len, ondb_plug_call *call);
	void (*cancel)(void *ud, ondb_plug_call *call);
} ondb_sealed_store;

/* Runner pool host. identity returns the pool member's public identity
   synchronously (0 on success; its private key lives with the host, e.g. a
   KMS behind the keyring plug of the host's engine). verify checks a launch
   token for a runner and answers its lease_ms (ONDB_PERMISSION to refuse);
   attest optionally checks evidence; renew (may be NULL) readmits a runner
   whose lease lapsed: answer lease_ms when the machine is still valid,
   ONDB_PERMISSION when it is gone; all three are asynchronous. joined tells the
   host that a user device added the pool to a space (proof is the pool's
   Add record, to pass to space.join_enrollment on the host). A host-held
   directory admin uses the same keyring and the directory.* ops. */
typedef struct ondb_runner_pool {
	uint32_t size;
	void *ud;
	int (*identity)(void *ud, ondb_identity *out);
	void (*verify)(void *ud, const uint8_t *token, size_t token_len, const ondb_identity *runner, ondb_plug_call *call);
	void (*attest)(void *ud, const uint8_t *evidence, size_t evidence_len, const ondb_identity *runner, ondb_plug_call *call);
	void (*joined)(void *ud, const uint8_t space[16], const char *name, size_t name_len, const char *relay, size_t relay_len, const uint8_t relay_key[32], const uint8_t *proof, size_t proof_len);
	void (*cancel)(void *ud, ondb_plug_call *call);
	void (*renew)(void *ud, const ondb_identity *runner, ondb_plug_call *call);
} ondb_runner_pool;

typedef struct ondb_config {
	uint32_t size;        /* sizeof(ondb_config) */
	uint32_t flags;       /* ONDB_NO_VERIFY ... */
	const char *dir;      /* engine directory, created if absent */
	int32_t handle_cache; /* open objects kept warm, 0 = default */
	int32_t search_budget;
	int64_t settle_ms;    /* idle delay before checkpoints and release, 0 = default */
	const ondb_vfs *vfs;
	const ondb_keyring *keyring;
	const ondb_credentials *credentials;
	const ondb_transport *transport;
	const ondb_clock *clock;
	const ondb_random *random;
	const ondb_spawner *spawner;
	const ondb_http *http;
	const ondb_write_observer *write_observer;
	const ondb_embedder *embedder;
	const ondb_log *log;
	const ondb_events *events;
	const ondb_runtime *runtime; /* NULL: engine only, runtime ops return ONDB_UNSUPPORTED */
	const ondb_search_remote *search_remote; /* NULL: peer queries go to full indexers through the relay */
	const ondb_unlock *unlock;               /* NULL: no passkey sign-in on this device */
	const ondb_sealed_store *sealed_store;   /* NULL: no account sign-in */
	const ondb_runner_pool *runner_pool;     /* NULL: no cloud runner pool */
	uint32_t approver;                       /* nonzero: listen for sign-in approval requests */
} ondb_config;

typedef void (*ondb_done_fn)(void *ud, uint64_t call, int status, const uint8_t *payload, size_t len);
typedef void (*ondb_sub_fn)(void *ud, uint64_t sub, const uint8_t *payload, size_t len);
typedef void (*ondb_post_fn)(ondb *h, void *ud);

/* ---- lifecycle ---- */
uint32_t ondb_abi_version(void);
const char *ondb_status_name(int status);
void ondb_free(void *p);
int ondb_open(const ondb_config *cfg, ondb **out);
int ondb_close(ondb *h);

/* ---- loop: own thread, or embedder-driven ---- */
int ondb_start(ondb *h);   /* run the engine loop on its own thread */
int ondb_stop(ondb *h);    /* stop and join that thread */
int ondb_post(ondb *h, ondb_post_fn fn, void *ud); /* any thread; fn runs on the engine thread */
int ondb_fd(ondb *h);      /* readable when ondb_step has work */
int64_t ondb_timeout_ms(ondb *h); /* -1 = sleep until ondb_fd is readable */
int ondb_step(ondb *h, int block);

/* ---- requests ---- */
/* Delivers a Search_Remote answer for query id. Call on the
   engine loop. */
int ondb_search_answer(ondb *h, uint64_t id, const uint8_t *payload, size_t len);

int ondb_call(ondb *h, const uint8_t *req, size_t len, uint32_t flags, int64_t timeout_ms,
              uint8_t **out, size_t *out_len, ondb_done_fn done, void *ud, uint64_t *call);
void ondb_cancel(ondb *h, uint64_t call);
int ondb_subscribe(ondb *h, const uint8_t *req, size_t len, uint32_t flags, ondb_sub_fn fn, void *ud, uint64_t *sub);
void ondb_unsubscribe(ondb *h, uint64_t sub);
int ondb_describe(ondb *h, uint32_t flags, uint8_t **out, size_t *out_len);

/* ---- transport, http and observer feedback (engine thread) ---- */
int ondb_link_up(ondb *h, uint64_t link, const uint8_t *binding, size_t len);
int ondb_link_input(ondb *h, uint64_t link, const uint8_t *data, size_t len);
void ondb_link_writable(ondb *h, uint64_t link);
void ondb_link_down(ondb *h, uint64_t link);
int ondb_http_head(ondb *h, uint64_t id, int status, const ondb_header *headers, size_t count);
int ondb_http_body(ondb *h, uint64_t id, const uint8_t *chunk, size_t len); /* 0: paused until resume */
void ondb_http_done(ondb *h, uint64_t id, int err, const char *detail, size_t len);
int ondb_http_read(ondb *h, uint64_t id, uint8_t *dst, size_t cap, size_t *n); /* 0 data, 1 wait, 2 end, 3 fail */
int ondb_observed_write(ondb *h, int32_t pid, const char *path, size_t len, int closed);
int ondb_tool_result(ondb *h, const uint8_t space[16], const uint8_t object[16], const char *id, size_t id_len,
                     const char *text, size_t len, int is_error);

/* ONDB_OPS_BEGIN */
/*
 * Ops (generated from ondb_describe). code name(arg: type, ...) -> result
 * enum arguments list their accepted names after the type.
 */
#define ONDB_OPS_VERSION 2u
/* identity() -> Identity */
#define ONDB_OP_IDENTITY 1u
/* stats() -> Stats */
#define ONDB_OP_STATS 2u
/* flush() -> {} */
#define ONDB_OP_FLUSH 3u
/* subscribe(object: object, kind: enum{conversation,map,text,tree}) -> Deltas */
#define ONDB_OP_SUBSCRIBE 4u
/* subscribe.catalog(space: id) -> Deltas */
#define ONDB_OP_SUBSCRIBE_CATALOG 5u
/* describe() -> Description */
#define ONDB_OP_DESCRIBE 6u
/* space.create(name: str, relay: str, relay_key: bytes, mode: enum{end_to_end,transparent}) -> space:id */
#define ONDB_OP_SPACE_CREATE 7u
/* account.login(subject: str, label: str, relay: str, relay_key: bytes) -> path:enum login_path status:enum login_status code:str spaces:uvarint */
#define ONDB_OP_ACCOUNT_LOGIN 8u
/* account.login_cross_device(subject: str) -> path:enum login_path status:enum login_status code:str spaces:uvarint */
#define ONDB_OP_ACCOUNT_LOGIN_CROSS_DEVICE 9u
/* account.login_recovery(subject: str, key: str) -> path:enum login_path status:enum login_status code:str spaces:uvarint */
#define ONDB_OP_ACCOUNT_LOGIN_RECOVERY 10u
/* account.state() -> AccountState */
#define ONDB_OP_ACCOUNT_STATE 11u
/* account.listen() -> {} */
#define ONDB_OP_ACCOUNT_LISTEN 12u
/* approval.list() -> approvals:[Approval] */
#define ONDB_OP_APPROVAL_LIST 13u
/* approval.respond(code: str, approve: bool) -> {} */
#define ONDB_OP_APPROVAL_RESPOND 14u
/* account.passkeys() -> passkeys:[Passkey] */
#define ONDB_OP_ACCOUNT_PASSKEYS 15u
/* account.passkey_remove(credential: bytes) -> {} */
#define ONDB_OP_ACCOUNT_PASSKEY_REMOVE 16u
/* account.recovery_key() -> key:str */
#define ONDB_OP_ACCOUNT_RECOVERY_KEY 17u
/* account.devices() -> devices:[Device] */
#define ONDB_OP_ACCOUNT_DEVICES 18u
/* account.pool(access: enum{off,everything,workspace,only_sent}) -> {} */
#define ONDB_OP_ACCOUNT_POOL 19u
/* device.remove(device: id) -> spaces:uvarint */
#define ONDB_OP_DEVICE_REMOVE 20u
/* space.members(space: id) -> members:[Member] */
#define ONDB_OP_SPACE_MEMBERS 21u
/* space.members_status(space: id) -> MembersStatus */
#define ONDB_OP_SPACE_MEMBERS_STATUS 22u
/* member.remove(space: id, device: id) -> {} */
#define ONDB_OP_MEMBER_REMOVE 23u
/* member.add(space: id, card: bytes, kind: enum{device,account,recovery,custodian,pool,runner,guest,directory}, role: enum{owner,admin,member,reader}, lease_ms: uvarint) -> proof:bytes */
#define ONDB_OP_MEMBER_ADD 24u
/* space.rotate(space: id) -> {} */
#define ONDB_OP_SPACE_ROTATE 25u
/* space.leave(space: id, device_only: bool) -> removed:uvarint skipped:uvarint */
#define ONDB_OP_SPACE_LEAVE 170u
/* space.pool(space: id, on: bool) -> {} */
#define ONDB_OP_SPACE_POOL 26u
/* space.join_enrollment(space: id, proof: bytes, name: str, relay: str, relay_key: bytes) -> space:id */
#define ONDB_OP_SPACE_JOIN_ENROLLMENT 27u
/* account.join_space(space: id) -> {} */
#define ONDB_OP_ACCOUNT_JOIN_SPACE 28u
/* pool.enroll(token: bytes, card: bytes, evidence: bytes) -> enrollment:bytes */
#define ONDB_OP_POOL_ENROLL 29u
/* runner.enroll(enrollment: bytes) -> spaces:uvarint */
#define ONDB_OP_RUNNER_ENROLL 30u
/* runner.renewal_request() -> request:bytes */
#define ONDB_OP_RUNNER_RENEWAL_REQUEST 164u
/* pool.renew(request: bytes) -> renewal:bytes */
#define ONDB_OP_POOL_RENEW 165u
/* runner.renew(renewal: bytes) -> spaces:uvarint */
#define ONDB_OP_RUNNER_RENEW 166u
/* lease.renew() -> renewed:uvarint */
#define ONDB_OP_LEASE_RENEW 31u
/* account.login_prf(subject: str, credential: bytes, prf: bytes, label: str, relay: str, relay_key: bytes) -> path:enum login_path status:enum login_status code:str spaces:uvarint */
#define ONDB_OP_ACCOUNT_LOGIN_PRF 32u
/* account.passkey_add(label: str, credential: bytes, prf: bytes) -> {} */
#define ONDB_OP_ACCOUNT_PASSKEY_ADD 33u
/* account.idp_salt(subject: str) -> salt:bytes */
#define ONDB_OP_ACCOUNT_IDP_SALT 34u
/* directory.add(space: id, person: bytes, role: enum{owner,admin,member,reader}, devices: [str]) -> {} */
#define ONDB_OP_DIRECTORY_ADD 35u
/* directory.remove(space: id, person: bytes) -> {} */
#define ONDB_OP_DIRECTORY_REMOVE 36u
/* account.sign_out(keep_relay: bool) -> spaces:uvarint */
#define ONDB_OP_ACCOUNT_SIGN_OUT 37u
/* storage.availability(object: object) -> unavailable:bool holders:[id] class:uvarint */
#define ONDB_OP_STORAGE_AVAILABILITY 38u
/* storage.stats() -> promotions:uvarint promoted:uvarint served:uvarint unavailable:uvarint */
#define ONDB_OP_STORAGE_STATS 39u
/* object.promote(object: object, from: uvarint) -> {} */
#define ONDB_OP_OBJECT_PROMOTE 40u
/* space.list() -> spaces:[Space] */
#define ONDB_OP_SPACE_LIST 41u
/* space.info(space: id) -> space:Space */
#define ONDB_OP_SPACE_INFO 42u
/* space.set_relay(space: id, relay: str, relay_key: bytes) -> {} */
#define ONDB_OP_SPACE_SET_RELAY 43u
/* space.relay_account(space: id, refresh: bool) -> RelayAccount */
#define ONDB_OP_SPACE_RELAY_ACCOUNT 140u
/* takeover.get(object: object, level: enum{conversation,agent,workspace}) -> policy:enum takeover effective:enum takeover */
#define ONDB_OP_TAKEOVER_GET 160u
/* takeover.set(object: object, level: enum{conversation,agent,workspace}, policy: enum{default,auto,never}) -> {} */
#define ONDB_OP_TAKEOVER_SET 161u
/* space.open(space: id) -> {} */
#define ONDB_OP_SPACE_OPEN 44u
/* space.close(space: id) -> {} */
#define ONDB_OP_SPACE_CLOSE 45u
/* space.join_shared(space: id, name: str, relay: str, relay_key: bytes) -> {} */
#define ONDB_OP_SPACE_JOIN_SHARED 46u
/* convo.create(space: id, title: str, agent: id, workspace: id, parent: object, parent_msg: rid, provider: str, model: str) -> object:object */
#define ONDB_OP_CONVO_CREATE 47u
/* convo.status(object: object) -> Status */
#define ONDB_OP_CONVO_STATUS 48u
/* convo.page(object: object, from: rid, from_seal: rid, from_known: bool, limit: uvarint, dir: enum{older,newer}, leaf: rid, cursor: bytes) -> Page */
#define ONDB_OP_CONVO_PAGE 49u
/* convo.message(object: object, msg: rid) -> message:Message */
#define ONDB_OP_CONVO_MESSAGE 50u
/* convo.siblings(object: object, msg: rid) -> siblings:[rid] at:uvarint */
#define ONDB_OP_CONVO_SIBLINGS 51u
/* convo.intents(object: object) -> intents:[Intent] */
#define ONDB_OP_CONVO_INTENTS 52u
/* convo.mounts(object: object) -> mounts:[Mount] */
#define ONDB_OP_CONVO_MOUNTS 53u
/* convo.settings(object: object) -> Settings */
#define ONDB_OP_CONVO_SETTINGS 54u
/* convo.files_at(object: object, msg: rid) -> files:[File] */
#define ONDB_OP_CONVO_FILES_AT 55u
/* convo.compactions(object: object, floor: uvarint) -> compactions:[Compaction] */
#define ONDB_OP_CONVO_COMPACTIONS 56u
/* convo.unsealed(object: object) -> unsealed:[Unsealed] */
#define ONDB_OP_CONVO_UNSEALED 57u
/* convo.window(object: object, anchor: rid, before: uvarint, after: uvarint, leaf: rid) -> Window */
#define ONDB_OP_CONVO_WINDOW 58u
/* convo.peek_switch(object: object, sibling: rid, before: uvarint, after: uvarint) -> Window */
#define ONDB_OP_CONVO_PEEK_SWITCH 59u
/* send(object: object, text: str, parent: rid, role: enum{user,assistant,system,tool}, provider: str, model: str, attachments: [Attachment]) -> Result */
#define ONDB_OP_SEND 60u
/* queue(object: object, text: str, attachments: [Attachment]) -> Result */
#define ONDB_OP_QUEUE 61u
/* steer(object: object, text: str, msg: rid, attachments: [Attachment]) -> Result */
#define ONDB_OP_STEER 62u
/* edit(object: object, item: rid, text: str, attachments: [Attachment]) -> Result */
#define ONDB_OP_EDIT 63u
/* cancel(object: object, item: rid) -> Result */
#define ONDB_OP_CANCEL 64u
/* interrupt(object: object, msg: rid) -> Result */
#define ONDB_OP_INTERRUPT 65u
/* answer(object: object, request: rid, allow: bool, text: str) -> Result */
#define ONDB_OP_ANSWER 66u
/* switch(object: object, sibling: rid) -> Result */
#define ONDB_OP_SWITCH 67u
/* back(object: object, msg: rid) -> Result */
#define ONDB_OP_BACK 68u
/* follow(object: object) -> Result */
#define ONDB_OP_FOLLOW 69u
/* mount(object: object, name: str, tree: id, line: id, path: str) -> Result */
#define ONDB_OP_MOUNT 70u
/* unmount(object: object, name: str) -> Result */
#define ONDB_OP_UNMOUNT 71u
/* await(object: object, tasks: [id], condition: enum{any,all}, deadline: uvarint, expr: str) -> Result */
#define ONDB_OP_AWAIT 72u
/* assign(object: object, msg: rid, runner: id) -> Result */
#define ONDB_OP_ASSIGN 73u
/* redact(object: object, msg: rid) -> Result */
#define ONDB_OP_REDACT 74u
/* map.create(space: id, title: str, settings: bytes) -> object:object */
#define ONDB_OP_MAP_CREATE 75u
/* map.get(object: object, key: bytes) -> found:bool entry:Entry */
#define ONDB_OP_MAP_GET 76u
/* map.scan(object: object, prefix: bytes, after: bytes, limit: uvarint) -> rows:[Entry] more:bool next:bytes */
#define ONDB_OP_MAP_SCAN 77u
/* map.set(object: object, key: bytes, fields: [Field]) -> Result */
#define ONDB_OP_MAP_SET 78u
/* map.delete(object: object, key: bytes, tags: [uvarint]) -> Result */
#define ONDB_OP_MAP_DELETE 79u
/* map.add(object: object, key: bytes, tag: uvarint, element: bytes) -> Result */
#define ONDB_OP_MAP_ADD 80u
/* map.remove(object: object, key: bytes, tag: uvarint, element: bytes) -> Result */
#define ONDB_OP_MAP_REMOVE 81u
/* map.redact(object: object, key: bytes) -> {} */
#define ONDB_OP_MAP_REDACT 82u
/* text.create(space: id, title: str, initial: str) -> object:object */
#define ONDB_OP_TEXT_CREATE 83u
/* text.read(object: object) -> text:str */
#define ONDB_OP_TEXT_READ 84u
/* text.spans(object: object) -> spans:[Span] */
#define ONDB_OP_TEXT_SPANS 85u
/* text.edit(object: object, pos: uvarint, remove: uvarint, insert: str) -> Result */
#define ONDB_OP_TEXT_EDIT 86u
/* text.redact(object: object, pos: uvarint, len: uvarint) -> {} */
#define ONDB_OP_TEXT_REDACT 87u
/* tree.create(space: id, title: str) -> object:object */
#define ONDB_OP_TREE_CREATE 88u
/* tree.read(object: object, path: str) -> text:str */
#define ONDB_OP_TREE_READ 89u
/* tree.list(object: object, path: str) -> names:[str] */
#define ONDB_OP_TREE_LIST 90u
/* tree.write(object: object, path: str, text: str) -> {} */
#define ONDB_OP_TREE_WRITE 91u
/* tree.remove(object: object, path: str) -> {} */
#define ONDB_OP_TREE_REMOVE 92u
/* tree.mount(object: object, root: str) -> {} */
#define ONDB_OP_TREE_MOUNT 93u
/* tree.unmount(object: object, root: str) -> {} */
#define ONDB_OP_TREE_UNMOUNT 94u
/* tree.mounts() -> mounts:[Mounted] */
#define ONDB_OP_TREE_MOUNTS 95u
/* tree.blame(object: object, path: str) -> text:str spans:[Span] */
#define ONDB_OP_TREE_BLAME 96u
/* tree.sync(object: object, root: str) -> {} */
#define ONDB_OP_TREE_SYNC 97u
/* tree.find(path: str) -> object:object root:str rel:str */
#define ONDB_OP_TREE_FIND 98u
/* catalog.get(object: object) -> found:bool entry:CatalogEntry */
#define ONDB_OP_CATALOG_GET 99u
/* catalog.list(space: id, archived: bool, after: bytes, limit: uvarint) -> rows:[CatalogRow] more:bool next:bytes */
#define ONDB_OP_CATALOG_LIST 100u
/* catalog.find(space: id, text: str) -> rows:[CatalogRow] */
#define ONDB_OP_CATALOG_FIND 141u
/* object.uploaded(object: object) -> uploaded:bool dropped:bool */
#define ONDB_OP_OBJECT_UPLOADED 142u
/* catalog.usage(object: object) -> Usage */
#define ONDB_OP_CATALOG_USAGE 101u
/* catalog.set(object: object, set: uvarint, title: str, archived: bool, pinned: bool, parent: object, parent_msg: rid, workspace: id, agent: id, takeover: enum{default,auto,never}) -> Result */
#define ONDB_OP_CATALOG_SET 102u
/* search(query: str, limit: uvarint, cursor: bytes, sort: enum{relevance,newest}, semantic: bool, collapse: bool, space: id, scope: enum{auto,local,everywhere}) -> Results */
#define ONDB_OP_SEARCH 103u
/* search.mode(space: id, mode: enum{default,full,local}) -> mode:enum */
#define ONDB_OP_SEARCH_MODE 104u
/* search.wrote(tree: id, path: str, unit: enum{lines,bytes}, lo: uvarint, hi: uvarint) -> hits:[Wrote] */
#define ONDB_OP_SEARCH_WROTE 105u
/* share.object(object: object, card: bytes) -> share:bytes */
#define ONDB_OP_SHARE_OBJECT 106u
/* share.accept(share: bytes) -> object:object */
#define ONDB_OP_SHARE_ACCEPT 107u
/* capability.issue(object: object, grantee: id, access: uvarint, expires: ivarint) -> token:bytes */
#define ONDB_OP_CAPABILITY_ISSUE 108u
/* card() -> card:bytes */
#define ONDB_OP_CARD 109u
/* workspace.create(space: id, name: str, agent: id, provider: str, model: str, setup: str) -> object:object */
#define ONDB_OP_WORKSPACE_CREATE 110u
/* workspace.get(object: object) -> Workspace */
#define ONDB_OP_WORKSPACE_GET 111u
/* workspace.add_member(object: object, member: id, kind: enum{conversation,map,text,tree}, role: enum{tree,document,memory}, mount: str, path: str) -> {} */
#define ONDB_OP_WORKSPACE_ADD_MEMBER 112u
/* workspace.remove_member(object: object, member: id, kind: enum{conversation,map,text,tree}, role: enum{tree,document,memory}, mount: str, path: str) -> {} */
#define ONDB_OP_WORKSPACE_REMOVE_MEMBER 113u
/* agent.create(space: id, name: str, instructions: str, driver: str, provider: str, model: str, workspace: id, options: bytes, budget: bytes) -> object:object */
#define ONDB_OP_AGENT_CREATE 114u
/* agent.get(object: object) -> Agent */
#define ONDB_OP_AGENT_GET 115u
/* agent.set(object: object, name: str, instructions: str, driver: str, provider: str, model: str, workspace: id, options: bytes, budget: bytes) -> {} */
#define ONDB_OP_AGENT_SET 116u
/* agent.add(object: object, tag: uvarint, element: bytes) -> {} */
#define ONDB_OP_AGENT_ADD 117u
/* agent.remove(object: object, tag: uvarint, element: bytes) -> {} */
#define ONDB_OP_AGENT_REMOVE 118u
/* runtime.attach(space: id) -> {} */
#define ONDB_OP_RUNTIME_ATTACH 119u
/* runtime.detach(space: id) -> {} */
#define ONDB_OP_RUNTIME_DETACH 120u
/* runtime.stats() -> RuntimeStats */
#define ONDB_OP_RUNTIME_STATS 121u
/* models(live: bool, refresh: bool) -> Models */
#define ONDB_OP_MODELS 122u
/* agent.resolve(object: object, provider: str, model: str) -> AgentInfo */
#define ONDB_OP_AGENT_RESOLVE 123u
/* record(object: object, source: str, external_id: str, sequence: uvarint, role: enum{user,assistant,system,tool}, parent: rid, blocks: [Block], status: enum{open,done,interrupted,failed,cancelled}, input: uvarint, output: uvarint, cache_read: uvarint, cache_write: uvarint, provider: str, model: str, native: str) -> receipt:enum msg:rid */
#define ONDB_OP_RECORD 124u
/* task.status(object: object) -> TaskStatus */
#define ONDB_OP_TASK_STATUS 125u
/* task.children(object: object, limit: uvarint) -> children:[CatalogRow] */
#define ONDB_OP_TASK_CHILDREN 126u
/* task.changes(object: object, caller: object, diff: bool, max_chars: uvarint) -> changes:[Change] diff:str */
#define ONDB_OP_TASK_CHANGES 127u
/* schedule.create(owner: object, id: str, prompt: str, cron: str, at: ivarint, tz: str, conversation: object, fresh: bool) -> {} */
#define ONDB_OP_SCHEDULE_CREATE 128u
/* schedule.list(space: id) -> schedules:[Schedule] */
#define ONDB_OP_SCHEDULE_LIST 129u
/* schedule.remove(owner: object, id: str) -> found:bool */
#define ONDB_OP_SCHEDULE_REMOVE 130u
/* land(tree: object, from: str, into: str, dry: bool) -> landed:bool files:uvarint conflicts:strs */
#define ONDB_OP_LAND 131u
/* go_back(object: object, msg: rid) -> {} */
#define ONDB_OP_GO_BACK 132u
/* revert(object: object, msg: rid) -> reverted:[str] */
#define ONDB_OP_REVERT 133u
/* channel.deliver(space: id, channel: str, key: str, text: str, sender: str, title: str, agent: id, workspace: id) -> object:object */
#define ONDB_OP_CHANNEL_DELIVER 134u
/* event.deliver(space: id, agent: id, name: str, payload: str) -> {} */
#define ONDB_OP_EVENT_DELIVER 135u
/* trigger.watch(object: object) -> {} */
#define ONDB_OP_TRIGGER_WATCH 136u
/* agent.actor(agent: id) -> actor:id */
#define ONDB_OP_AGENT_ACTOR 137u
/* wake(object: object) -> {} */
#define ONDB_OP_WAKE 138u
/* placement(object: object) -> Placement */
#define ONDB_OP_PLACEMENT 139u
/* buffer.open(object: object, path: str, line: str, units: enum{bytes,utf16}, actor: id, page: uvarint) -> BufferEvent */
#define ONDB_OP_BUFFER_OPEN 150u
/* buffer.read(buffer: uvarint, rev: uvarint, from: uvarint, len: uvarint) -> rev:uvarint ack:uvarint from:uvarint length:uvarint text:str */
#define ONDB_OP_BUFFER_READ 151u
/* buffer.edit(buffer: uvarint, rev: uvarint, pos: uvarints, del: uvarints, ins: strs, group: uvarint) -> ack:uvarint rev:uvarint */
#define ONDB_OP_BUFFER_EDIT 152u
/* buffer.ack(buffer: uvarint, rev: uvarint) -> {} */
#define ONDB_OP_BUFFER_ACK 153u
/* buffer.undo(buffer: uvarint) -> done:bool */
#define ONDB_OP_BUFFER_UNDO 154u
/* buffer.redo(buffer: uvarint) -> done:bool */
#define ONDB_OP_BUFFER_REDO 155u
/* buffer.anchors(buffer: uvarint, rev: uvarint, positions: uvarints, bias: enum{before,after}) -> anchors:strs */
#define ONDB_OP_BUFFER_ANCHORS 156u
/* buffer.resolve(buffer: uvarint, anchors: strs) -> positions:[ivarint] rev:uvarint ack:uvarint */
#define ONDB_OP_BUFFER_RESOLVE 157u
/* buffer.cursors(buffer: uvarint, rev: uvarint, ranges: uvarints) -> {} */
#define ONDB_OP_BUFFER_CURSORS 158u
/* buffer.text(buffer: uvarint) -> rev:uvarint text:str */
#define ONDB_OP_BUFFER_TEXT 159u
/* runners(space: id, object: object) -> Runners */
#define ONDB_OP_RUNNERS 162u
/* subscribe.runners(space: id, object: object) -> Runners */
#define ONDB_OP_SUBSCRIBE_RUNNERS 163u
/* ONDB_OPS_END */

#ifdef __cplusplus
}
#endif

#endif
