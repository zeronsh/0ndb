const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const text_mod = @import("../core/text.zig");
const crypto = @import("../store/crypto.zig");
const blobs_mod = @import("../store/blobs.zig");
const ws_mod = @import("../fs/workspace.zig");
const iface = @import("../providers/interface.zig");
const rpc = @import("../providers/json_rpc.zig");
const models_mod = @import("../providers/models.zig");
const registry = @import("../providers/registry.zig");
const model = @import("../session/model.zig");
const pager = @import("../session/pager.zig");
const engine_mod = @import("../session/engine.zig");
const wire = @import("../sync/wire.zig");
const relay_mod = @import("../sync/relay.zig");
const client_mod = @import("../sync/client.zig");
const dag_mod = @import("../core/dag.zig");
const op_mod = @import("../core/op.zig");
const history_mod = @import("../core/history.zig");
const diff_mod = @import("../core/diff.zig");
const vcs = @import("../fs/vcs.zig");
const wt_mod = @import("../fs/worktrees.zig");

pub const MAX_CONNS: usize = 128;
pub const MAX_SSE_CLIENTS: usize = 64;
pub const MAX_HEADER_BYTES: usize = 64 * 1024;
pub const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;

pub const HttpFraming = union(enum) {
    content_length: usize,
    chunked: void,
};

pub fn parseHttpFraming(headers: []const u8) error{ BadFraming, PayloadTooLarge }!HttpFraming {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next();
    var cl_val: ?usize = null;
    var is_chunked = false;
    while (it.next()) |line| {
        if (line.len >= 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const val = std.mem.trim(u8, line[15..], " \t");
            if (val.len == 0) return error.BadFraming;
            for (val) |c| {
                if (c < '0' or c > '9') return error.BadFraming;
            }
            const v = std.fmt.parseInt(u64, val, 10) catch return error.PayloadTooLarge;
            if (v > MAX_BODY_BYTES) return error.PayloadTooLarge;
            const vs: usize = @intCast(v);
            if (cl_val) |prev| {
                if (prev != vs) return error.BadFraming;
            } else {
                cl_val = vs;
            }
        } else if (line.len >= 18 and std.ascii.eqlIgnoreCase(line[0..18], "transfer-encoding:")) {
            const val = std.mem.trim(u8, line[18..], " \t");
            if (val.len == 0) return error.BadFraming;
            var toks = std.mem.splitScalar(u8, val, ',');
            var saw_tok = false;
            while (toks.next()) |raw| {
                const tok = std.mem.trim(u8, raw, " \t");
                if (tok.len == 0) return error.BadFraming;
                if (std.ascii.eqlIgnoreCase(tok, "chunked")) {
                    is_chunked = true;
                    saw_tok = true;
                } else {
                    return error.BadFraming;
                }
            }
            if (!saw_tok) return error.BadFraming;
        }
    }
    if (is_chunked and cl_val != null) return error.BadFraming;
    if (is_chunked) return .chunked;
    return .{ .content_length = cl_val orelse 0 };
}

pub const ChunkedResult = union(enum) {
    need_more: void,
    complete: struct {
        body: []u8,
        consumed: usize,
    },
};

pub fn decodeChunkedBody(
    allocator: Allocator,
    raw: []const u8,
    max_bytes: usize,
) error{ BadFraming, PayloadTooLarge, OutOfMemory }!ChunkedResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;

    while (true) {
        const crlf = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse {
            out.deinit(allocator);
            return .need_more;
        };
        const line = raw[pos..crlf];
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const hex_str = std.mem.trim(u8, line[0..semi], " \t");
        if (hex_str.len == 0) return error.BadFraming;
        for (hex_str) |c| {
            if (!std.ascii.isHex(c)) return error.BadFraming;
        }
        const chunk_u64 = std.fmt.parseInt(u64, hex_str, 16) catch return error.PayloadTooLarge;
        pos = crlf + 2;

        if (chunk_u64 == 0) {
            while (true) {
                const tcrlf = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse {
                    out.deinit(allocator);
                    return .need_more;
                };
                if (tcrlf == pos) {
                    pos += 2;
                    break;
                }
                pos = tcrlf + 2;
            }
            return .{ .complete = .{
                .body = try out.toOwnedSlice(allocator),
                .consumed = pos,
            } };
        }

        if (chunk_u64 > max_bytes) return error.PayloadTooLarge;
        const chunk_len: usize = @intCast(chunk_u64);
        if (chunk_len > max_bytes - out.items.len) return error.PayloadTooLarge;
        if (pos + chunk_len + 2 > raw.len) {
            out.deinit(allocator);
            return .need_more;
        }
        if (raw[pos + chunk_len] != '\r' or raw[pos + chunk_len + 1] != '\n') return error.BadFraming;
        try out.appendSlice(allocator, raw[pos .. pos + chunk_len]);
        pos += chunk_len + 2;
    }
}

pub fn ignoreSigpipe() void {
    var act = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

pub fn isSafeRelPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096) return false;
    if (path[0] == '/' or path[path.len - 1] == '/') return false;
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (first and (std.mem.eql(u8, seg, ".0ndb") or std.mem.eql(u8, seg, ".git"))) return false;
        first = false;
    }
    return true;
}

const UI_NOT_BUILT_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<title>0ndb playground</title>
    \\<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;line-height:1.5}code,pre{background:#f2f2f2;border-radius:4px}code{padding:.1rem .3rem}pre{padding:.75rem 1rem}</style>
    \\</head>
    \\<body>
    \\<h1>Playground UI is not built</h1>
    \\<p>The 0ndb API is running, but no built UI was found. Build it once with:</p>
    \\<pre><code>cd playground/ui
    \\npm install &amp;&amp; npm run build</code></pre>
    \\<p>Then reload this page, or set <code>ONDB_PLAYGROUND_DIST</code> to a built <code>dist</code> directory and restart the server.</p>
    \\</body>
    \\</html>
    \\
;

const MAX_STATIC_BYTES = 32 * 1024 * 1024;
const MAX_TRACE_BYTES = 16 * 1024 * 1024;
const DIFF_TEXT_CAP = 64 * 1024;
const IMMUTABLE_CACHE = "public, max-age=31536000, immutable";

const SEED_APP_V1 = "pub const REVISION = \"initial-v1\";\npub const STEERED = false;\npub fn status() []const u8 {\n    return \"ready\";\n}\n";
const SEED_APP_A2 = "pub const REVISION = \"branch-a-v2\";\npub const STEERED = false;\npub fn status() []const u8 {\n    return \"branch-a-active\";\n}\n";
const SEED_APP_B = "pub const REVISION = \"branch-b-experiment\";\npub const STEERED = true;\npub fn status() []const u8 {\n    return \"branch-b-experimental\";\n}\n";

const SEED_BUILD_ZIG =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const mod = b.addModule("app", .{
    \\        .root_source_file = b.path("app.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    const tests = b.addTest(.{ .root_module = mod });
    \\    const run_tests = b.addRunArtifact(tests);
    \\    const test_step = b.step("test", "Run unit tests");
    \\    test_step.dependOn(&run_tests.step);
    \\}
    \\
;

const SEED_CRDT_ZIG =
    \\const std = @import("std");
    \\
    \\pub const OpId = struct {
    \\    actor: u128,
    \\    ts: u64,
    \\
    \\    pub fn order(a: OpId, b: OpId) std.math.Order {
    \\        if (a.ts != b.ts) return std.math.order(a.ts, b.ts);
    \\        return std.math.order(a.actor, b.actor);
    \\    }
    \\};
    \\
    \\pub const Insert = struct {
    \\    id: OpId,
    \\    parent: ?OpId,
    \\    text: []const u8,
    \\};
    \\
    \\pub fn wins(a: Insert, b: Insert) bool {
    \\    return a.id.order(b.id) == .gt;
    \\}
    \\
    \\test "later lamport timestamp wins" {
    \\    const a: Insert = .{ .id = .{ .actor = 1, .ts = 2 }, .parent = null, .text = "a" };
    \\    const b: Insert = .{ .id = .{ .actor = 2, .ts = 1 }, .parent = null, .text = "b" };
    \\    try std.testing.expect(wins(a, b));
    \\}
    \\
;

const SEED_MERKLE_ZIG =
    \\const std = @import("std");
    \\const Blake3 = std.crypto.hash.Blake3;
    \\
    \\pub const Hash = [32]u8;
    \\
    \\pub fn leaf(bytes: []const u8) Hash {
    \\    var out: Hash = undefined;
    \\    Blake3.hash(bytes, &out, .{});
    \\    return out;
    \\}
    \\
    \\pub fn node(left: Hash, right: Hash) Hash {
    \\    var h = Blake3.init(.{});
    \\    h.update(&left);
    \\    h.update(&right);
    \\    var out: Hash = undefined;
    \\    h.final(&out);
    \\    return out;
    \\}
    \\
    \\pub fn root(leaves: []const Hash) ?Hash {
    \\    if (leaves.len == 0) return null;
    \\    var acc = leaves[0];
    \\    for (leaves[1..]) |l| acc = node(acc, l);
    \\    return acc;
    \\}
    \\
;

const SEED_RELAY_ZIG =
    \\const std = @import("std");
    \\
    \\pub const Topic = u128;
    \\
    \\pub const Frame = struct {
    \\    topic: Topic,
    \\    seq: u64,
    \\    sealed: []const u8,
    \\};
    \\
    \\pub const Relay = struct {
    \\    frames: std.ArrayList(Frame) = .empty,
    \\    next_seq: u64 = 1,
    \\
    \\    pub fn publish(self: *Relay, gpa: std.mem.Allocator, topic: Topic, sealed: []const u8) !u64 {
    \\        const seq = self.next_seq;
    \\        try self.frames.append(gpa, .{ .topic = topic, .seq = seq, .sealed = sealed });
    \\        self.next_seq += 1;
    \\        return seq;
    \\    }
    \\
    \\    pub fn since(self: *const Relay, topic: Topic, after: u64) usize {
    \\        var n: usize = 0;
    \\        for (self.frames.items) |f| {
    \\            if (f.topic == topic and f.seq > after) n += 1;
    \\        }
    \\        return n;
    \\    }
    \\};
    \\
;

const SEED_AEGIS_ZIG =
    \\const std = @import("std");
    \\const Aegis = std.crypto.aead.aegis.Aegis256;
    \\
    \\pub const key_len = Aegis.key_length;
    \\pub const nonce_len = Aegis.nonce_length;
    \\pub const tag_len = Aegis.tag_length;
    \\
    \\pub fn seal(out: []u8, tag: *[tag_len]u8, msg: []const u8, ad: []const u8, nonce: [nonce_len]u8, key: [key_len]u8) void {
    \\    Aegis.encrypt(out, tag, msg, ad, nonce, key);
    \\}
    \\
    \\pub fn open(out: []u8, sealed: []const u8, tag: [tag_len]u8, ad: []const u8, nonce: [nonce_len]u8, key: [key_len]u8) !void {
    \\    try Aegis.decrypt(out, sealed, tag, ad, nonce, key);
    \\}
    \\
;

const SEED_WAL_ZIG =
    \\const std = @import("std");
    \\const Crc = std.hash.crc.@"CRC-32/ISCSI";
    \\
    \\pub const MAGIC: u32 = 0x304e4442;
    \\
    \\pub const Record = struct {
    \\    magic: u32,
    \\    crc: u32,
    \\    len: u32,
    \\    payload: []const u8,
    \\};
    \\
    \\pub fn frame(payload: []const u8) !Record {
    \\    if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    \\    var crc = Crc.init();
    \\    var hdr: [8]u8 = undefined;
    \\    std.mem.writeInt(u32, hdr[0..4], MAGIC, .little);
    \\    std.mem.writeInt(u32, hdr[4..8], @intCast(payload.len), .little);
    \\    crc.update(&hdr);
    \\    crc.update(payload);
    \\    return .{
    \\        .magic = MAGIC,
    \\        .crc = crc.final(),
    \\        .len = @intCast(payload.len),
    \\        .payload = payload,
    \\    };
    \\}
    \\
    \\pub fn verify(r: Record) bool {
    \\    if (r.magic != MAGIC or r.len != r.payload.len) return false;
    \\    var crc = Crc.init();
    \\    var hdr: [8]u8 = undefined;
    \\    std.mem.writeInt(u32, hdr[0..4], r.magic, .little);
    \\    std.mem.writeInt(u32, hdr[4..8], r.len, .little);
    \\    crc.update(&hdr);
    \\    crc.update(r.payload);
    \\    return r.crc == crc.final();
    \\}
    \\
    \\test "framed records verify" {
    \\    try std.testing.expect(verify(try frame("turn sealed")));
    \\}
    \\
;

const SEED_ARCHITECTURE_MD =
    \\# Architecture
    \\
    \\0ndb keeps every workspace file in a sequence CRDT so concurrent edits from agents,
    \\editors, and remote devices converge without locks.
    \\
    \\## Layers
    \\
    \\- **core**: op ids, the causal DAG, and the text CRDT that stores file contents.
    \\- **store**: content-addressed blobs with a bounded LRU cache.
    \\- **session**: threads, messages, and an append-only WAL with CRC32C framing.
    \\- **sync**: a relay that only ever sees AEGIS-256 sealed frames.
    \\
    \\## Data flow
    \\
    \\1. An agent tool call touches files on disk.
    \\2. The workspace ingests the change as a batch of ops.
    \\3. The turn seals its post-version so any message can be rolled back.
    \\4. Merkle message pages are pushed to the relay for other devices.
    \\
;

const SEED_STEERING_MD =
    \\# Steering
    \\
    \\A running turn can be redirected without losing context.
    \\
    \\## Native steer
    \\
    \\Providers that accept mid-turn input receive the steer prompt directly. The turn
    \\keeps streaming and the trace records a `native` steer marker.
    \\
    \\## Fallback steer
    \\
    \\Providers without native support are interrupted. The partial turn is sealed as
    \\`interrupted`, the steer prompt is appended as a new user message, and a fresh
    \\turn starts from the sealed workspace version.
    \\
    \\## Queue
    \\
    \\Follow-up prompts sent while a turn is running are queued and drained in order.
    \\
;

const SEED_CONVERGENCE_TEST_ZIG =
    \\const std = @import("std");
    \\
    \\fn applyAll(gpa: std.mem.Allocator, ops: []const []const u8) ![]u8 {
    \\    var out: std.ArrayList(u8) = .empty;
    \\    errdefer out.deinit(gpa);
    \\    for (ops) |op| try out.appendSlice(gpa, op);
    \\    return out.toOwnedSlice(gpa);
    \\}
    \\
    \\test "replicas converge regardless of delivery order" {
    \\    const gpa = std.testing.allocator;
    \\    const a = try applyAll(gpa, &.{ "alpha ", "beta" });
    \\    defer gpa.free(a);
    \\    const b = try applyAll(gpa, &.{ "alpha ", "beta" });
    \\    defer gpa.free(b);
    \\    try std.testing.expectEqualStrings(a, b);
    \\}
    \\
;

const SEED_CHANGELOG_MD =
    \\# Changelog
    \\
    \\All notable changes to this workspace are recorded here. Simulator turns append below.
    \\
    \\## 0.1.0
    \\
    \\- Seeded CRDT core with Lamport-ordered inserts
    \\- Added Merkle page hashing for message pagination
    \\- Added AEGIS-128L sealed relay frames
    \\- Added CRC32C-framed session WAL
    \\
    \\## Unreleased
    \\
    \\
;

const SEED_FILES = [_]struct { []const u8, []const u8 }{
    .{ "build.zig", SEED_BUILD_ZIG },
    .{ "src/core/crdt.zig", SEED_CRDT_ZIG },
    .{ "src/core/merkle.zig", SEED_MERKLE_ZIG },
    .{ "src/sync/relay.zig", SEED_RELAY_ZIG },
    .{ "src/sync/aegis.zig", SEED_AEGIS_ZIG },
    .{ "src/session/wal.zig", SEED_WAL_ZIG },
    .{ "docs/ARCHITECTURE.md", SEED_ARCHITECTURE_MD },
    .{ "docs/STEERING.md", SEED_STEERING_MD },
    .{ "tests/convergence_test.zig", SEED_CONVERGENCE_TEST_ZIG },
    .{ "CHANGELOG.md", SEED_CHANGELOG_MD },
};

const FileKind = enum { seed, added, modified };

const FileMeta = struct {
    changed_ms: u64,
    added: u32,
    removed: u32,
    kind: FileKind,
};

fn appendSplicesJson(allocator: Allocator, buf: *std.ArrayList(u8), splices: []const text_mod.TextSplice) !void {
    try buf.append(allocator, '[');
    for (splices, 0..) |s, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "{{\"at\":{d},\"del\":{d},\"text\":", .{ s.at, s.del });
        try rpc.appendJsonEscaped(allocator, buf, s.text);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

fn appendFileDeltaJson(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    index: usize,
    fd: *const history_mod.FileDelta,
) !void {
    if (index > 0) try buf.append(allocator, ',');
    const kind_str = switch (fd.kind) {
        .added => "added",
        .modified => "modified",
        .deleted => "removed",
    };
    try buf.appendSlice(allocator, "{\"path\":");
    try rpc.appendJsonEscaped(allocator, buf, fd.path);
    try buf.print(
        allocator,
        ",\"kind\":\"{s}\",\"bytes\":{d},\"lines\":{d},\"added\":{d},\"removed\":{d},\"splices\":",
        .{ kind_str, fd.bytes, fd.lines, fd.lines_added, fd.lines_removed },
    );
    try appendSplicesJson(allocator, buf, fd.splices);
    try buf.append(allocator, '}');
}

fn nextGeneratedTurn(io: Io, root: []const u8) u64 {
    var ws = Io.Dir.cwd().openDir(io, root, .{}) catch return 1;
    defer ws.close(io);
    var gen = ws.openDir(io, "src/generated", .{ .iterate = true }) catch return 1;
    defer gen.close(io);
    var max: u64 = 0;
    var it = gen.iterate();
    while (it.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "turn_") or !std.mem.endsWith(u8, name, ".zig")) continue;
        const n = std.fmt.parseInt(u64, name[5 .. name.len - 4], 10) catch continue;
        max = @max(max, n);
    }
    return max + 1;
}

const BASH_TEST_OUTPUT ="\x1b[1mBuild Summary:\x1b[0m 3/3 steps succeeded\n\x1b[32m✓\x1b[0m test-core 41 passed\n\x1b[32m✓\x1b[0m test-sync 17 passed\n\x1b[2m(0.84s)\x1b[0m\n";

fn nowUs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    const ns = ts.nanoseconds;
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, 1000));
}

fn readRssKb(io: Io) u64 {
    const f = Io.Dir.cwd().openFile(io, "/proc/self/statm", .{}) catch return 0;
    defer f.close(io);
    var buf: [128]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return 0;
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n");
    _ = it.next() orelse return 0;
    const rss_pages_str = it.next() orelse return 0;
    const pages = std.fmt.parseInt(u64, rss_pages_str, 10) catch return 0;
    return pages * 4;
}

const InteractiveMock = struct {
    allocator: Allocator,
    io: Io,
    native_steer: bool,
    workspace_root: []u8,
    mu: Io.Mutex,
    prompt: ?[]u8,
    steered_prompt: ?[]u8,
    interrupted: std.atomic.Value(bool),
    step_idx: usize,
    turn_id: u64,
    closed: bool,
    staged_path: ?[]u8,
    staged_data: ?[]u8,

    fn start(allocator: Allocator, io: Io, native_steer: bool, workspace_root: []const u8) !iface.RunHandle {
        const self = try allocator.create(InteractiveMock);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .native_steer = native_steer,
            .workspace_root = try allocator.dupe(u8, workspace_root),
            .mu = Io.Mutex.init,
            .prompt = null,
            .steered_prompt = null,
            .interrupted = std.atomic.Value(bool).init(false),
            .step_idx = 0,
            .turn_id = 0,
            .closed = false,
            .staged_path = null,
            .staged_data = null,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *InteractiveMock = @ptrCast(@alignCast(ptr));
        const turn = nextGeneratedTurn(self.io, self.workspace_root);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.prompt) |old| self.allocator.free(old);
        if (self.steered_prompt) |old| self.allocator.free(old);
        self.prompt = null;
        self.steered_prompt = null;
        self.prompt = try self.allocator.dupe(u8, prompt);
        self.interrupted.store(false, .release);
        self.step_idx = 0;
        self.turn_id = turn;
        self.clearStaged();
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, _: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *InteractiveMock = @ptrCast(@alignCast(ptr));
        if (!self.native_steer) return .requires_interrupt_fallback;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.steered_prompt) |old| self.allocator.free(old);
        self.steered_prompt = try self.allocator.dupe(u8, prompt);
        return .injected_native;
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *InteractiveMock = @ptrCast(@alignCast(ptr));
        self.interrupted.store(true, .release);
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *InteractiveMock = @ptrCast(@alignCast(ptr));
        if (!self.closed) {
            self.closed = true;
            if (self.prompt) |p| self.allocator.free(p);
            if (self.steered_prompt) |p| self.allocator.free(p);
            self.clearStaged();
            self.allocator.free(self.workspace_root);
            self.allocator.destroy(self);
        }
    }

    fn clearStaged(self: *InteractiveMock) void {
        if (self.staged_path) |p| self.allocator.free(p);
        if (self.staged_data) |d| self.allocator.free(d);
        self.staged_path = null;
        self.staged_data = null;
    }

    fn stageWrite(self: *InteractiveMock, rel: []const u8, data: []const u8) !void {
        const p = try self.allocator.dupe(u8, rel);
        errdefer self.allocator.free(p);
        const d = try self.allocator.dupe(u8, data);
        self.clearStaged();
        self.staged_path = p;
        self.staged_data = d;
    }

    fn flushStaged(self: *InteractiveMock) void {
        defer self.clearStaged();
        const rel = self.staged_path orelse return;
        const data = self.staged_data orelse return;
        var wd = Io.Dir.cwd().openDir(self.io, self.workspace_root, .{}) catch return;
        defer wd.close(self.io);
        if (std.fs.path.dirname(rel)) |parent| wd.createDirPath(self.io, parent) catch return;
        wd.writeFile(self.io, .{ .sub_path = rel, .data = data }) catch {};
    }

    fn readWorkspaceFile(self: *InteractiveMock, rel: []const u8) ?[]u8 {
        var wd = Io.Dir.cwd().openDir(self.io, self.workspace_root, .{}) catch return null;
        defer wd.close(self.io);
        return wd.readFileAlloc(self.io, rel, self.allocator, .limited(MAX_STATIC_BYTES)) catch null;
    }

    fn writeToolInput(self: *InteractiveMock, path: []const u8, content: []const u8) ![]u8 {
        var input: std.ArrayList(u8) = .empty;
        errdefer input.deinit(self.allocator);
        try input.appendSlice(self.allocator, "{\"file_path\":");
        try rpc.appendJsonEscaped(self.allocator, &input, path);
        try input.appendSlice(self.allocator, ",\"content\":");
        try rpc.appendJsonEscaped(self.allocator, &input, content);
        try input.append(self.allocator, '}');
        return input.toOwnedSlice(self.allocator);
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *InteractiveMock = @ptrCast(@alignCast(ptr));
        const idx = self.step_idx;
        self.step_idx += 1;

        if (idx == 0) {
            return .{ .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, "sim-session") } } };
        }
        if (idx == 1) {
            const tid = try std.fmt.allocPrint(self.allocator, "sim-turn-{d}", .{self.turn_id});
            return .{ .kind = .{ .turn_started = .{ .native_turn_id = tid } } };
        }

        if (self.interrupted.load(.acquire)) {
            if (idx < 100) {
                self.step_idx = 100;
                return .{ .kind = .{ .turn_ended = .{
                    .ok = false,
                    .err_msg = try self.allocator.dupe(u8, "interrupted"),
                } } };
            }
            return null;
        }

        if (idx >= 100) return null;

        self.io.sleep(Io.Duration.fromMilliseconds(220), .awake) catch {};

        if (self.interrupted.load(.acquire)) {
            self.step_idx = 100;
            return .{ .kind = .{ .turn_ended = .{
                .ok = false,
                .err_msg = try self.allocator.dupe(u8, "interrupted"),
            } } };
        }

        self.mu.lockUncancelable(self.io);
        const prompt_copy = try self.allocator.dupe(u8, self.prompt orelse "");
        const steer_copy: ?[]u8 = if (self.steered_prompt) |sp| try self.allocator.dupe(u8, sp) else null;
        self.mu.unlock(self.io);
        defer self.allocator.free(prompt_copy);
        defer if (steer_copy) |s| self.allocator.free(s);

        switch (idx) {
            2 => return .{ .kind = .{ .reasoning_delta = .{
                .text = try std.fmt.allocPrint(self.allocator, "Inspecting CRDT workspace for \"{s}\"...\n", .{prompt_copy}),
            } } },
            3 => return .{ .kind = .{ .reasoning_delta = .{
                .text = try self.allocator.dupe(u8, "Planning an atomic patch to app.zig, a CHANGELOG entry, and a generated turn module, then verifying history heads.\n"),
            } } },
            4 => {
                const label = steer_copy orelse prompt_copy;
                const snippet = try std.fmt.allocPrint(
                    self.allocator,
                    "pub const REVISION = \"{s}\";\npub const STEERED = {s};\npub fn status() []const u8 {{\n    return \"synced-zero-copy\";\n}}\n",
                    .{ label, if (steer_copy != null) "true" else "false" },
                );
                defer self.allocator.free(snippet);
                try self.stageWrite("app.zig", snippet);
                const input = try self.writeToolInput("app.zig", snippet);
                defer self.allocator.free(input);
                return try toolStartedEvent(self.allocator, "tool-1", "Write", input);
            },
            5 => {
                self.flushStaged();
                return try toolFinishedEvent(self.allocator, "tool-1", "Wrote 5 lines to app.zig", false);
            },
            6 => {
                const label = try self.allocator.dupe(u8, steer_copy orelse prompt_copy);
                defer self.allocator.free(label);
                std.mem.replaceScalar(u8, label, '\n', ' ');
                std.mem.replaceScalar(u8, label, '\r', ' ');
                const line = try std.fmt.allocPrint(self.allocator, "- turn {d}: {s}\n", .{ self.turn_id, label });
                defer self.allocator.free(line);
                const existing = self.readWorkspaceFile("CHANGELOG.md");
                defer if (existing) |e| self.allocator.free(e);
                var next: std.ArrayList(u8) = .empty;
                defer next.deinit(self.allocator);
                if (existing) |e| {
                    try next.appendSlice(self.allocator, e);
                    if (e.len > 0 and e[e.len - 1] != '\n') try next.append(self.allocator, '\n');
                }
                try next.appendSlice(self.allocator, line);
                try self.stageWrite("CHANGELOG.md", next.items);
                var input: std.ArrayList(u8) = .empty;
                defer input.deinit(self.allocator);
                try input.appendSlice(self.allocator, "{\"file_path\":\"CHANGELOG.md\",\"old_string\":\"\",\"new_string\":");
                try rpc.appendJsonEscaped(self.allocator, &input, line);
                try input.append(self.allocator, '}');
                return try toolStartedEvent(self.allocator, "tool-2", "Edit", input.items);
            },
            7 => {
                self.flushStaged();
                return try toolFinishedEvent(self.allocator, "tool-2", "Appended 1 line to CHANGELOG.md", false);
            },
            8 => {
                const rel = try std.fmt.allocPrint(self.allocator, "src/generated/turn_{d}.zig", .{self.turn_id});
                defer self.allocator.free(rel);
                const body = try std.fmt.allocPrint(
                    self.allocator,
                    "pub const TURN: u64 = {d};\npub const STEERED = {s};\npub const FILES_TOUCHED = 3;\n\npub fn id() u64 {{\n    return TURN;\n}}\n",
                    .{ self.turn_id, if (steer_copy != null) "true" else "false" },
                );
                defer self.allocator.free(body);
                try self.stageWrite(rel, body);
                const input = try self.writeToolInput(rel, body);
                defer self.allocator.free(input);
                return try toolStartedEvent(self.allocator, "tool-3", "Write", input);
            },
            9 => {
                self.flushStaged();
                const output = try std.fmt.allocPrint(self.allocator, "Created src/generated/turn_{d}.zig", .{self.turn_id});
                defer self.allocator.free(output);
                return try toolFinishedEvent(self.allocator, "tool-3", output, false);
            },
            10 => return .{ .kind = .{ .reasoning_delta = .{
                .text = try self.allocator.dupe(u8, "Patch is in place; running the test suite before sealing the turn.\n"),
            } } },
            11 => return try toolStartedEvent(
                self.allocator,
                "tool-4",
                "Bash",
                "{\"command\":\"zig build test --summary all\",\"description\":\"Run the test suite\"}",
            ),
            12 => return try toolFinishedEvent(self.allocator, "tool-4", BASH_TEST_OUTPUT, false),
            13 => return .{ .kind = .{ .text_delta = .{
                .text = try std.fmt.allocPrint(self.allocator, "Processed \"{s}\" across the CRDT workspace. ", .{prompt_copy}),
            } } },
            14 => return .{ .kind = .{ .text_delta = .{
                .text = try std.fmt.allocPrint(
                    self.allocator,
                    "Updated `app.zig`, appended to `CHANGELOG.md`, created `src/generated/turn_{d}.zig`, ran the tests, and sealed the turn's causal version into the append-only WAL. ",
                    .{self.turn_id},
                ),
            } } },
            15 => {
                if (steer_copy) |sp| {
                    return .{ .kind = .{ .text_delta = .{
                        .text = try std.fmt.allocPrint(self.allocator, "\n\n[Native Steer Pivoted Mid-Turn -> \"{s}\"] Adjusted output and workspace state live without losing turn context. ", .{sp}),
                    } } };
                }
                return .{ .kind = .{ .text_delta = .{
                    .text = try self.allocator.dupe(u8, "Still streaming — steer now to redirect mid-turn. "),
                } } };
            },
            16 => {
                if (steer_copy) |sp| {
                    return .{ .kind = .{ .text_delta = .{
                        .text = try std.fmt.allocPrint(self.allocator, "Applied steer directive \"{s}\" cleanly.", .{sp}),
                    } } };
                }
                return .{ .kind = .{ .text_delta = .{
                    .text = try self.allocator.dupe(u8, "Finishing verification and sealing Merkle message page blob."),
                } } };
            },
            17 => return .{ .kind = .{ .usage = .{ .input_tokens = 1840, .output_tokens = 212 } } },
            18 => {
                self.step_idx = 100;
                return .{ .kind = .{ .turn_ended = .{ .ok = true, .err_msg = null } } };
            },
            else => return null,
        }
    }
};

fn toolStartedEvent(allocator: Allocator, tool_id: []const u8, name: []const u8, input_json: []const u8) !iface.Event {
    const id_copy = try allocator.dupe(u8, tool_id);
    errdefer allocator.free(id_copy);
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const input_copy = try allocator.dupe(u8, input_json);
    return .{ .kind = .{ .tool_started = .{ .id = id_copy, .name = name_copy, .input_json = input_copy } } };
}

fn toolFinishedEvent(allocator: Allocator, tool_id: []const u8, output: []const u8, is_error: bool) !iface.Event {
    const id_copy = try allocator.dupe(u8, tool_id);
    errdefer allocator.free(id_copy);
    const output_copy = try allocator.dupe(u8, output);
    return .{ .kind = .{ .tool_finished = .{ .id = id_copy, .output = output_copy, .is_error = is_error } } };
}

const TraceUsage = struct {
    input_tokens: u64,
    output_tokens: u64,
};

const SteerMode = enum { native, fallback };

const TraceReasoning = struct {
    id: u32,
    text: std.ArrayList(u8),
    started_ms: u64,
    ended_ms: ?u64,
};

const TraceTool = struct {
    id: []u8,
    name: []u8,
    input: []u8,
    output: []u8,
    is_error: bool,
    started_ms: u64,
    ended_ms: ?u64,

    fn deinit(self: *TraceTool, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.input);
        allocator.free(self.output);
    }
};

const TraceSteer = struct {
    mode: SteerMode,
    prompt: []u8,
    at_ms: u64,
};

const Trace = struct {
    started_ms: u64,
    ended_ms: ?u64 = null,
    reasoning: std.ArrayList(TraceReasoning) = .empty,
    tools: std.ArrayList(TraceTool) = .empty,
    steers: std.ArrayList(TraceSteer) = .empty,
    usage: ?TraceUsage = null,
    err: ?[]u8 = null,
    reasoning_open: bool = false,

    fn deinit(self: *Trace, allocator: Allocator) void {
        for (self.reasoning.items) |*r| r.text.deinit(allocator);
        self.reasoning.deinit(allocator);
        for (self.tools.items) |*t| t.deinit(allocator);
        self.tools.deinit(allocator);
        for (self.steers.items) |s| allocator.free(s.prompt);
        self.steers.deinit(allocator);
        if (self.err) |e| allocator.free(e);
    }

    fn closeReasoning(self: *Trace, now: u64) void {
        if (!self.reasoning_open) return;
        self.reasoning_open = false;
        self.reasoning.items[self.reasoning.items.len - 1].ended_ms = now;
    }

    fn appendReasoning(self: *Trace, allocator: Allocator, text: []const u8, now: u64) !u32 {
        if (!self.reasoning_open) {
            try self.reasoning.append(allocator, .{
                .id = @intCast(self.reasoning.items.len),
                .text = .empty,
                .started_ms = now,
                .ended_ms = null,
            });
            self.reasoning_open = true;
        }
        const cur = &self.reasoning.items[self.reasoning.items.len - 1];
        try cur.text.appendSlice(allocator, text);
        return cur.id;
    }

    fn recordFullReasoning(self: *Trace, allocator: Allocator, text: []const u8, now: u64) !?u32 {
        if (self.reasoning_open) {
            const cur = &self.reasoning.items[self.reasoning.items.len - 1];
            cur.text.clearRetainingCapacity();
            try cur.text.appendSlice(allocator, text);
            return null;
        }
        for (self.reasoning.items) |r| {
            if (std.mem.eql(u8, r.text.items, text)) return null;
        }
        return try self.appendReasoning(allocator, text, now);
    }

    fn startTool(self: *Trace, allocator: Allocator, tool_id: []const u8, name: []const u8, input: []const u8, now: u64) !void {
        const id_copy = try allocator.dupe(u8, tool_id);
        errdefer allocator.free(id_copy);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const input_copy = try allocator.dupe(u8, input);
        errdefer allocator.free(input_copy);
        const output_copy = try allocator.dupe(u8, "");
        errdefer allocator.free(output_copy);
        try self.tools.append(allocator, .{
            .id = id_copy,
            .name = name_copy,
            .input = input_copy,
            .output = output_copy,
            .is_error = false,
            .started_ms = now,
            .ended_ms = null,
        });
    }

    fn finishTool(self: *Trace, allocator: Allocator, tool_id: []const u8, output: []const u8, is_error: bool, now: u64) !void {
        const idx = self.openToolIndex(tool_id) orelse blk: {
            try self.startTool(allocator, tool_id, "", "", now);
            break :blk self.tools.items.len - 1;
        };
        const t = &self.tools.items[idx];
        const output_copy = try allocator.dupe(u8, output);
        allocator.free(t.output);
        t.output = output_copy;
        t.is_error = is_error;
        t.ended_ms = now;
    }

    fn openToolIndex(self: *const Trace, tool_id: []const u8) ?usize {
        var i = self.tools.items.len;
        while (i > 0) {
            i -= 1;
            const t = &self.tools.items[i];
            if (t.ended_ms == null and std.mem.eql(u8, t.id, tool_id)) return i;
        }
        return null;
    }

    fn addSteer(self: *Trace, allocator: Allocator, mode: SteerMode, prompt: []const u8, now: u64) !void {
        const prompt_copy = try allocator.dupe(u8, prompt);
        errdefer allocator.free(prompt_copy);
        try self.steers.append(allocator, .{ .mode = mode, .prompt = prompt_copy, .at_ms = now });
    }

    fn setError(self: *Trace, allocator: Allocator, msg: []const u8) !void {
        const copy = try allocator.dupe(u8, msg);
        if (self.err) |old| allocator.free(old);
        self.err = copy;
    }

    fn record(self: *Trace, allocator: Allocator, ev: *const iface.Event, now: u64) !?u32 {
        switch (ev.kind) {
            .reasoning_delta => |d| return try self.appendReasoning(allocator, d.text, now),
            .reasoning => |r| return try self.recordFullReasoning(allocator, r.text, now),
            else => {},
        }
        self.closeReasoning(now);
        switch (ev.kind) {
            .tool_started => |ts| try self.startTool(allocator, ts.id, ts.name, ts.input_json, now),
            .tool_finished => |tf| try self.finishTool(allocator, tf.id, tf.output, tf.is_error, now),
            .usage => |u| self.usage = .{ .input_tokens = u.input_tokens, .output_tokens = u.output_tokens },
            .turn_ended => |te| if (!te.ok) try self.setError(allocator, te.err_msg orelse "turn failed"),
            else => {},
        }
        return null;
    }

    fn writeJson(self: *const Trace, allocator: Allocator, out: *std.ArrayList(u8)) !void {
        try out.print(allocator, "{{\"started_ms\":{d},\"ended_ms\":", .{self.started_ms});
        try appendOptU64(allocator, out, self.ended_ms);
        try out.appendSlice(allocator, ",\"reasoning\":[");
        for (self.reasoning.items, 0..) |r, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.print(allocator, "{{\"id\":{d},\"text\":", .{r.id});
            try rpc.appendJsonEscaped(allocator, out, r.text.items);
            try out.print(allocator, ",\"started_ms\":{d},\"ended_ms\":", .{r.started_ms});
            try appendOptU64(allocator, out, r.ended_ms);
            try out.append(allocator, '}');
        }
        try out.appendSlice(allocator, "],\"tools\":[");
        for (self.tools.items, 0..) |t, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{\"id\":");
            try rpc.appendJsonEscaped(allocator, out, t.id);
            try out.appendSlice(allocator, ",\"name\":");
            try rpc.appendJsonEscaped(allocator, out, t.name);
            try out.appendSlice(allocator, ",\"input\":");
            try rpc.appendJsonEscaped(allocator, out, t.input);
            try out.appendSlice(allocator, ",\"output\":");
            try rpc.appendJsonEscaped(allocator, out, t.output);
            try out.print(allocator, ",\"is_error\":{},\"started_ms\":{d},\"ended_ms\":", .{ t.is_error, t.started_ms });
            try appendOptU64(allocator, out, t.ended_ms);
            try out.append(allocator, '}');
        }
        try out.appendSlice(allocator, "],\"steers\":[");
        for (self.steers.items, 0..) |s, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.print(allocator, "{{\"mode\":\"{s}\",\"prompt\":", .{@tagName(s.mode)});
            try rpc.appendJsonEscaped(allocator, out, s.prompt);
            try out.print(allocator, ",\"at_ms\":{d}}}", .{s.at_ms});
        }
        try out.appendSlice(allocator, "],\"usage\":");
        if (self.usage) |u| {
            try out.print(allocator, "{{\"input_tokens\":{d},\"output_tokens\":{d}}}", .{ u.input_tokens, u.output_tokens });
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"error\":");
        if (self.err) |e| {
            try rpc.appendJsonEscaped(allocator, out, e);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '}');
    }
};

const TurnCtx = struct {
    thread_id: u128,
    msg_id: u128,
    provider_slug: []const u8,
    model: []const u8,
};

const DeltaExtra = struct {
    parent_id: ?u128 = null,
    tool_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?[]const u8 = null,
    text: ?[]const u8 = null,
    block: ?u32 = null,
    is_error: ?bool = null,
    usage: ?TraceUsage = null,
};

const VersionView = struct {
    dag: *const dag_mod.Dag,
    ver: *const version_mod.Version,
    allocator: Allocator,

    fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
        const self: *const VersionView = @ptrCast(@alignCast(ptr));
        return self.dag.versionContainsOp(self.allocator, self.ver, op_id) catch false;
    }

    fn view(self: *const VersionView) Allocator.Error!text_mod.View {
        return .{
            .ptr = self,
            .observesFn = observes,
            .min_unobserved = try self.dag.minUnobservedFor(self.allocator, self.ver),
        };
    }
};

fn relayBgMain(srv: *relay_mod.RelayServer) void {
    srv.run() catch {};
}

const WorkerArgs = struct {
    srv: *PlaygroundServer,
    thread_id: u128,
    mode: enum { send_new, reply_existing, drain_queue },
    prompt: []u8,
    parent_msg_id: ?u128,
    provider_slug: []u8,
    model: ?[]u8,
};

const ConnArgs = struct {
    srv: *PlaygroundServer,
    fd: posix.fd_t,
};

const PrewarmArgs = struct {
    srv: *PlaygroundServer,
    provider: iface.ProviderId,
};

const CachedCatalog = struct {
    catalog: models_mod.ModelCatalog,
    elapsed_us: u64,
    ready: bool,

    fn deinit(self: *CachedCatalog, allocator: Allocator) void {
        self.catalog.deinit(allocator);
    }
};

const ActiveTurnHandle = struct {
    handle: *iface.RunHandle,
    interrupted: *std.atomic.Value(bool),
};

pub const PlaygroundServer = struct {
    allocator: Allocator,
    io: Io,
    mu: Io.Mutex,
    sse_mu: Io.Mutex,
    models_mu: Io.Mutex,
    model_cache: std.AutoHashMap(u8, CachedCatalog),
    workspace: ws_mod.Workspace,
    worktrees: wt_mod.Worktrees,
    primary_wt_id: u128,
    engine: engine_mod.SessionEngine,
    relay: relay_mod.RelayServer,
    relay_thread: std.Thread,
    vault_id: u128,
    auth_secret: [32]u8,
    master_key: crypto.Key,
    dev_a: client_mod.SyncClient,
    dev_b: client_mod.SyncClient,
    dev_b_dir: Io.Dir,
    dev_b_pages: blobs_mod.BlobStore,
    dev_b_path: []u8,
    sse_clients: std.ArrayList(posix.fd_t),
    listen_fd: posix.fd_t,
    http_port: u16,
    running: std.atomic.Value(bool),
    active_threads: std.atomic.Value(usize),
    active_conns: std.atomic.Value(usize),
    active_handles_mu: Io.Mutex,
    active_handles: std.AutoHashMapUnmanaged(u128, ActiveTurnHandle),
    trace_mu: Io.Mutex,
    live_traces: std.AutoHashMapUnmanaged(u128, *Trace),
    traces_dir: Io.Dir,
    ui_dist: ?[]u8,
    file_meta: std.StringHashMapUnmanaged(FileMeta),
    active_source: ?[]const u8,
    active_msg_id: ?u128,
    watcher_thread: std.Thread,
    relay_io_mu: Io.Mutex,
    relay_sync_mu: Io.Mutex,
    relay_sync_cond: Io.Condition,
    relay_sync_pending: std.ArrayList(u128),
    relay_sync_thread: std.Thread,

    pub fn start(
        allocator: Allocator,
        io: Io,
        workspace_path: []const u8,
        port: u16,
    ) !*PlaygroundServer {
        ignoreSigpipe();
        const state_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{workspace_path});
        defer allocator.free(state_path);
        const relay_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/relay", .{workspace_path});
        defer allocator.free(relay_path);
        const devb_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/device-b", .{workspace_path});
        var devb_path_owned = true;
        errdefer if (devb_path_owned) allocator.free(devb_path);
        const traces_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/traces", .{workspace_path});
        defer allocator.free(traces_path);
        const wt_state_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/worktrees", .{workspace_path});
        defer allocator.free(wt_state_path);
        const wt_checkouts_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/checkouts", .{workspace_path});
        defer allocator.free(wt_checkouts_path);

        try Io.Dir.cwd().createDirPath(io, workspace_path);
        try Io.Dir.cwd().createDirPath(io, state_path);
        try Io.Dir.cwd().createDirPath(io, relay_path);
        try Io.Dir.cwd().createDirPath(io, devb_path);
        try Io.Dir.cwd().createDirPath(io, traces_path);

        const self = try allocator.create(PlaygroundServer);
        errdefer allocator.destroy(self);

        self.trace_mu = Io.Mutex.init;
        self.live_traces = .empty;
        self.file_meta = .empty;
        self.active_source = null;
        self.active_msg_id = null;
        self.active_threads = std.atomic.Value(usize).init(0);
        self.active_conns = std.atomic.Value(usize).init(0);
        self.active_handles_mu = Io.Mutex.init;
        self.active_handles = .empty;
        self.relay_io_mu = Io.Mutex.init;
        self.relay_sync_mu = Io.Mutex.init;
        self.relay_sync_cond = Io.Condition.init;
        self.relay_sync_pending = .empty;
        self.traces_dir = try Io.Dir.cwd().openDir(io, traces_path, .{});
        errdefer self.traces_dir.close(io);
        self.ui_dist = resolveUiDist(allocator, io);
        errdefer if (self.ui_dist) |d| allocator.free(d);

        const auth_secret = crypto.hashBytes("0ndb-playground-relay-cap-secret");
        const master_key: crypto.Key = @splat(0x42);

        self.allocator = allocator;
        self.io = io;
        self.mu = Io.Mutex.init;
        self.sse_mu = Io.Mutex.init;
        self.models_mu = Io.Mutex.init;
        self.model_cache = std.AutoHashMap(u8, CachedCatalog).init(allocator);
        errdefer self.model_cache.deinit();
        self.vault_id = 0x00db_0001;
        self.auth_secret = auth_secret;
        self.master_key = master_key;
        self.sse_clients = .empty;
        self.running = std.atomic.Value(bool).init(true);
        self.dev_b_path = devb_path;
        devb_path_owned = false;
        errdefer allocator.free(self.dev_b_path);

        self.workspace = try ws_mod.Workspace.open(allocator, io, workspace_path, state_path, 0x00db_1001);
        errdefer self.workspace.deinit();

        self.worktrees = try wt_mod.Worktrees.open(allocator, io, wt_state_path, wt_checkouts_path);
        errdefer self.worktrees.deinit();
        var primary_wt = try self.worktrees.attachPrimary(&self.workspace, "workspace");
        primary_wt.deinit(allocator);
        self.primary_wt_id = self.workspace.history.history_id;

        self.engine = try engine_mod.SessionEngine.open(allocator, io, &self.workspace, state_path);
        errdefer self.engine.deinit();
        self.engine.attachWorktrees(&self.worktrees);
        errdefer self.engine.attachWorktrees(null);
        self.engine.page_size = 4;

        self.relay = try relay_mod.RelayServer.start(allocator, io, relay_path, .{ 127, 0, 0, 1 }, 0, auth_secret, true);
        errdefer self.relay.deinit();
        self.relay_thread = try std.Thread.spawn(.{}, relayBgMain, .{&self.relay});
        errdefer {
            self.relay.stop();
            self.relay_thread.join();
        }

        self.dev_a = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, self.relay.port, master_key, auth_secret);
        errdefer self.dev_a.deinit();
        self.dev_b = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, self.relay.port, master_key, auth_secret);
        errdefer self.dev_b.deinit();
        const cat_topic = id.catalogStreamId(self.vault_id);
        try self.dev_a.authorizeTopic(cat_topic, wire.PERM_ALL);
        try self.dev_b.authorizeTopic(cat_topic, wire.PERM_ALL);

        self.dev_b_dir = try Io.Dir.cwd().openDir(io, devb_path, .{ .iterate = true });
        errdefer self.dev_b_dir.close(io);
        self.dev_b_pages = try blobs_mod.BlobStore.open(allocator, io, self.dev_b_dir, "pages", blobs_mod.DEFAULT_CACHE_BUDGET);
        errdefer self.dev_b_pages.deinit();

        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(s_rc) != .SUCCESS) return error.SocketFailed;
        self.listen_fd = @intCast(s_rc);
        errdefer _ = linux.close(self.listen_fd);

        var one: i32 = 1;
        _ = linux.setsockopt(self.listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        if (linux.errno(linux.bind(self.listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return error.BindFailed;
        }
        if (linux.errno(linux.listen(self.listen_fd, 64)) != .SUCCESS) {
            return error.ListenFailed;
        }

        var bound: linux.sockaddr.in = undefined;
        var blen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = linux.getsockname(self.listen_fd, @ptrCast(&bound), &blen);
        self.http_port = std.mem.bigToNative(u16, bound.port);

        try self.seedIfEmpty();
        errdefer self.deinitFileMeta();
        try self.initFileMetaLocked();
        self.workspace.setObserver(.{
            .ptr = self,
            .on_commit = onWorkspaceCommit,
        });
        try self.workspace.attachWatcher();
        self.watcher_thread = try std.Thread.spawn(.{}, watcherMain, .{self});
        errdefer {
            self.running.store(false, .release);
            self.workspace.wakeWatcher();
            self.watcher_thread.join();
            self.workspace.setObserver(null);
        }
        self.relay_sync_thread = try std.Thread.spawn(.{}, relaySyncMain, .{self});
        self.startPrewarmModels();
        return self;
    }

    pub fn deinit(self: *PlaygroundServer) void {
        self.running.store(false, .release);
        _ = linux.shutdown(self.listen_fd, linux.SHUT.RDWR);
        _ = linux.close(self.listen_fd);
        self.interruptAllActiveTurns();
        self.sse_mu.lockUncancelable(self.io);
        for (self.sse_clients.items) |fd| {
            _ = linux.shutdown(fd, linux.SHUT.RDWR);
            _ = linux.close(fd);
        }
        self.sse_clients.clearRetainingCapacity();
        self.sse_mu.unlock(self.io);

        var waited_ms: usize = 0;
        while (self.active_threads.load(.acquire) > 0 and waited_ms < 5000) : (waited_ms += 5) {
            self.io.sleep(Io.Duration.fromMilliseconds(5), .awake) catch {};
        }

        self.relay_sync_mu.lockUncancelable(self.io);
        self.relay_sync_cond.broadcast(self.io);
        self.relay_sync_mu.unlock(self.io);
        self.relay_sync_thread.join();
        self.relay_sync_pending.deinit(self.allocator);
        self.workspace.wakeWatcher();
        self.watcher_thread.join();
        self.workspace.setObserver(null);
        self.sse_mu.lockUncancelable(self.io);
        for (self.sse_clients.items) |fd| _ = linux.close(fd);
        self.sse_clients.deinit(self.allocator);
        self.sse_mu.unlock(self.io);
        self.active_handles_mu.lockUncancelable(self.io);
        self.active_handles.deinit(self.allocator);
        self.active_handles_mu.unlock(self.io);
        self.models_mu.lockUncancelable(self.io);
        var mit = self.model_cache.valueIterator();
        while (mit.next()) |v| v.deinit(self.allocator);
        self.model_cache.deinit();
        self.models_mu.unlock(self.io);
        self.dev_b_pages.deinit();
        self.dev_b_dir.close(self.io);
        self.dev_b.deinit();
        self.dev_a.deinit();
        self.relay.stop();
        self.relay_thread.join();
        self.relay.deinit();
        self.engine.attachWorktrees(null);
        self.engine.deinit();
        self.worktrees.deinit();
        self.workspace.deinit();
        self.deinitFileMeta();
        self.allocator.free(self.dev_b_path);
        self.trace_mu.lockUncancelable(self.io);
        self.live_traces.deinit(self.allocator);
        self.trace_mu.unlock(self.io);
        self.traces_dir.close(self.io);
        if (self.ui_dist) |d| self.allocator.free(d);
        self.allocator.destroy(self);
    }

    fn registerActiveTurn(self: *PlaygroundServer, thread_id: u128, handle: *iface.RunHandle, interrupted: *std.atomic.Value(bool)) void {
        self.active_handles_mu.lockUncancelable(self.io);
        defer self.active_handles_mu.unlock(self.io);
        self.active_handles.put(self.allocator, thread_id, .{ .handle = handle, .interrupted = interrupted }) catch {};
    }

    fn unregisterActiveTurn(self: *PlaygroundServer, thread_id: u128) void {
        self.active_handles_mu.lockUncancelable(self.io);
        defer self.active_handles_mu.unlock(self.io);
        _ = self.active_handles.remove(thread_id);
    }

    fn interruptThreadTurn(self: *PlaygroundServer, thread_id: u128) bool {
        self.active_handles_mu.lockUncancelable(self.io);
        defer self.active_handles_mu.unlock(self.io);
        if (self.active_handles.get(thread_id)) |active| {
            active.interrupted.store(true, .release);
            active.handle.interrupt();
            return true;
        }
        return false;
    }

    fn interruptAllActiveTurns(self: *PlaygroundServer) void {
        self.active_handles_mu.lockUncancelable(self.io);
        defer self.active_handles_mu.unlock(self.io);
        var it = self.active_handles.valueIterator();
        while (it.next()) |active| {
            active.interrupted.store(true, .release);
            active.handle.interrupt();
        }
    }

    fn deinitFileMeta(self: *PlaygroundServer) void {
        var it = self.file_meta.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.file_meta.deinit(self.allocator);
    }

    fn initFileMetaLocked(self: *PlaygroundServer) !void {
        const now = id.nowMs(self.io);
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }
        try self.collectTrackedFilePaths(id.InodeId.ROOT, "", text_mod.View.EVERYTHING, &paths);
        sortDedupePaths(self.allocator, &paths);
        for (paths.items) |p| {
            const lines: u32 = blk: {
                const iid = (try self.workspace.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, p)) orelse break :blk 0;
                const inode = self.workspace.history.tree.get(iid) orelse break :blk 0;
                const f = inode.fileConstPtr() orelse break :blk 0;
                break :blk @intCast(@min(f.text.lineCount(), std.math.maxInt(u32)));
            };
            const key = try self.allocator.dupe(u8, p);
            self.file_meta.put(self.allocator, key, .{
                .changed_ms = now,
                .added = lines,
                .removed = 0,
                .kind = .seed,
            }) catch |err| {
                self.allocator.free(key);
                return err;
            };
        }
    }

    fn onWorkspaceCommit(ptr: *anyopaque, source: []const u8, delta: *const history_mod.CommitDelta) void {
        const self: *PlaygroundServer = @ptrCast(@alignCast(ptr));
        if (delta.files.len == 0) return;
        const now = id.nowMs(self.io);
        const eff_source = self.active_source orelse source;
        const msg_id = self.active_msg_id;

        for (delta.files) |*fd| {
            switch (fd.kind) {
                .deleted => {
                    if (self.file_meta.fetchRemove(fd.path)) |kv| {
                        self.allocator.free(kv.key);
                    }
                },
                .added, .modified => {
                    const meta = FileMeta{
                        .changed_ms = now,
                        .added = fd.lines_added,
                        .removed = fd.lines_removed,
                        .kind = if (fd.kind == .added) .added else .modified,
                    };
                    if (self.file_meta.getPtr(fd.path)) |existing| {
                        existing.* = meta;
                    } else {
                        const k = self.allocator.dupe(u8, fd.path) catch continue;
                        self.file_meta.put(self.allocator, k, meta) catch {
                            self.allocator.free(k);
                        };
                    }
                },
            }
        }

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        const from_hex = delta.from_version.formatHex(self.allocator) catch return;
        defer self.allocator.free(from_hex);
        const to_hex = delta.to_version.formatHex(self.allocator) catch return;
        defer self.allocator.free(to_hex);

        payload.print(self.allocator, "{{\"type\":\"files_changed\",\"source\":\"{s}\",\"ts_ms\":{d},\"msg_id\":", .{ eff_source, now }) catch return;
        appendOptIdHex(self.allocator, &payload, msg_id) catch return;
        payload.appendSlice(self.allocator, ",\"from_version\":") catch return;
        rpc.appendJsonEscaped(self.allocator, &payload, from_hex) catch return;
        payload.appendSlice(self.allocator, ",\"to_version\":") catch return;
        rpc.appendJsonEscaped(self.allocator, &payload, to_hex) catch return;
        payload.appendSlice(self.allocator, ",\"changes\":[") catch return;
        for (delta.files, 0..) |*fd, i| {
            appendFileDeltaJson(self.allocator, &payload, i, fd) catch return;
        }
        payload.appendSlice(self.allocator, "]}") catch return;

        self.broadcastSse(payload.items);
    }

    fn watcherMain(self: *PlaygroundServer) void {
        while (self.running.load(.acquire)) {
            const w = self.workspace.waitWatcher(-1);
            if (!self.running.load(.acquire)) return;
            if (w.ready) {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                _ = self.workspace.drainWatched("watch") catch null;
            }
        }
    }

    fn startPrewarmModels(self: *PlaygroundServer) void {
        self.refreshModelCache(.mock) catch {};
        const provs = registry.listProviders(self.io);
        for (provs) |p| {
            if (!p.available) continue;
            if (p.id == .claude_code or p.id == .muse) {
                self.refreshModelCache(p.id) catch {};
                continue;
            }
            const args = self.allocator.create(PrewarmArgs) catch continue;
            args.* = .{ .srv = self, .provider = p.id };
            _ = self.active_threads.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, prewarmThreadMain, .{args}) catch {
                _ = self.active_threads.fetchSub(1, .release);
                self.allocator.destroy(args);
                continue;
            };
            th.detach();
        }
    }

    fn prewarmThreadMain(args: *PrewarmArgs) void {
        const srv = args.srv;
        const prov = args.provider;
        srv.allocator.destroy(args);
        defer _ = srv.active_threads.fetchSub(1, .release);
        if (!srv.running.load(.acquire)) return;
        srv.refreshModelCache(prov) catch return;
        if (!srv.running.load(.acquire)) return;
        var buf: [128]u8 = undefined;
        const ev = std.fmt.bufPrint(&buf, "{{\"type\":\"models_updated\",\"provider\":\"{s}\"}}", .{prov.slug()}) catch return;
        srv.broadcastSse(ev);
    }

    fn refreshModelCache(self: *PlaygroundServer, provider: iface.ProviderId) !void {
        const t0 = nowUs(self.io);
        var cat = try registry.discoverModels(self.allocator, self.io, provider);
        const elapsed = nowUs(self.io) -| t0;

        self.models_mu.lockUncancelable(self.io);
        defer self.models_mu.unlock(self.io);
        const key = @intFromEnum(provider);
        if (self.model_cache.fetchRemove(key)) |old| {
            var ov = old.value;
            ov.deinit(self.allocator);
        }
        self.model_cache.put(key, .{
            .catalog = cat,
            .elapsed_us = elapsed,
            .ready = true,
        }) catch {
            cat.deinit(self.allocator);
        };
    }

    fn seedIfEmpty(self: *PlaygroundServer) !void {
        if (self.engine.journal.threads.count() > 0) {
            try self.syncAllThreadsToRelayLocked();
            return;
        }
        _ = try self.workspace.writeFileDirect(
            1,
            "README.md",
            "# 0ndb Zig Playground\n\nZero-copy CRDT workspace with AEGIS-128L E2EE sync, Merkle pagination, and durable steering.\n",
        );
        _ = try self.workspace.writeFileDirect(1, "app.zig", SEED_APP_V1);
        for (SEED_FILES) |f| {
            _ = try self.workspace.writeFileDirect(1, f[0], f[1]);
        }

        const tid = try self.engine.createThread("CRDT Branching & Merkle Pages Demo", .mock, "sim-native-v1");

        const um1 = try self.engine.appendUserMessage(tid, null, .user, "Initialize app.zig with baseline v1 state", .mock, "sim-native-v1", null, null);
        const a1 = try self.engine.appendUserMessage(tid, um1, .assistant, "Baseline `app.zig` is tracked in the CRDT B-tree and committed to the CRC32C append-only log.", .mock, "sim-native-v1", null, null);

        const um2 = try self.engine.appendUserMessage(tid, a1, .user, "Upgrade revision to branch-a-v2", .mock, "sim-native-v1", null, null);
        _ = try self.workspace.writeFileDirect(2, "app.zig", SEED_APP_A2);
        const a2 = try self.engine.appendUserMessage(tid, um2, .assistant, "Updated `app.zig` to `branch-a-v2`. Click the `< 1 / 2 >` branch switcher above to watch `app.zig` time-travel across branches.", .mock, "sim-native-v1", null, null);

        const um3 = try self.engine.appendUserMessage(tid, a2, .user, "Add a third turn so Merkle pagination splits across 2 pages", .mock, "sim-native-v1", null, null);
        const a3 = try self.engine.appendUserMessage(tid, um3, .assistant, "Done! With `4 / page`, the oldest 2 messages live in `prev_page`. Load older pages above or open the **Sync** inspector to fetch them via Device B.", .mock, "sim-native-v1", null, null);

        const um2_alt = try self.engine.editMessage(tid, um2, "Alternate branch: set revision to branch-b-experiment", .mock, "sim-native-v1");
        _ = try self.workspace.writeFileDirect(3, "app.zig", SEED_APP_B);
        const a2_alt = try self.engine.appendUserMessage(tid, um2_alt, .assistant, "Switched to alternate branch `branch-b-experiment` and updated `app.zig`. Switching back to branch 1 restores `branch-a-v2` and every nested turn.", .mock, "sim-native-v1", null, null);

        _ = try self.engine.switchBranch(tid, um2);

        try self.seedTrace(a1, "Workspace is empty apart from README.md. Creating app.zig with a baseline revision so later turns have something to branch from.\n", SEED_APP_V1);
        try self.seedTrace(a2, "User wants the revision bumped to branch-a-v2. A single Write of app.zig keeps the patch atomic.\n", SEED_APP_A2);
        try self.seedTrace(a3, "No file changes needed; this turn only exists to push the thread past the 4-message page boundary.\n", null);
        try self.seedTrace(a2_alt, "Edited prompt forks the conversation. Writing the experimental revision on the new branch only.\n", SEED_APP_B);

        try self.syncAllThreadsToRelayLocked();
    }

    fn seedTrace(self: *PlaygroundServer, msg_id: u128, reasoning: []const u8, app_zig: ?[]const u8) !void {
        const m = self.engine.journal.messages.getPtr(msg_id) orelse return;
        const t0 = m.created_ms -| 4200;
        var trace: Trace = .{ .started_ms = t0, .ended_ms = m.created_ms };
        defer trace.deinit(self.allocator);
        _ = try trace.appendReasoning(self.allocator, reasoning, t0 + 150);
        trace.closeReasoning(t0 + 1900);
        if (app_zig) |content| {
            var input: std.ArrayList(u8) = .empty;
            defer input.deinit(self.allocator);
            try input.appendSlice(self.allocator, "{\"file_path\":\"app.zig\",\"content\":");
            try rpc.appendJsonEscaped(self.allocator, &input, content);
            try input.append(self.allocator, '}');
            const output = try std.fmt.allocPrint(self.allocator, "Wrote {d} lines to app.zig", .{std.mem.count(u8, content, "\n")});
            defer self.allocator.free(output);
            try trace.startTool(self.allocator, "tool-1", "Write", input.items, t0 + 2100);
            try trace.finishTool(self.allocator, "tool-1", output, false, t0 + 3300);
        }
        trace.usage = .{ .input_tokens = 1620, .output_tokens = 148 };
        try self.writeTraceFile(msg_id, &trace);
    }

    fn writeTraceFile(self: *PlaygroundServer, msg_id: u128, trace: *const Trace) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try trace.writeJson(self.allocator, &buf);
        var name_buf: [37]u8 = undefined;
        try self.traces_dir.writeFile(self.io, .{ .sub_path = traceFileName(msg_id, &name_buf), .data = buf.items });
    }

    fn registerTrace(self: *PlaygroundServer, msg_id: u128, trace: *Trace) void {
        self.trace_mu.lockUncancelable(self.io);
        defer self.trace_mu.unlock(self.io);
        self.live_traces.put(self.allocator, msg_id, trace) catch {};
    }

    fn unregisterTrace(self: *PlaygroundServer, msg_id: u128) void {
        self.trace_mu.lockUncancelable(self.io);
        defer self.trace_mu.unlock(self.io);
        _ = self.live_traces.remove(msg_id);
    }

    fn recordTraceEvent(self: *PlaygroundServer, trace: *Trace, ev: *const iface.Event) ?u32 {
        const now = id.nowMs(self.io);
        self.trace_mu.lockUncancelable(self.io);
        defer self.trace_mu.unlock(self.io);
        return trace.record(self.allocator, ev, now) catch null;
    }

    fn recordTraceSteer(self: *PlaygroundServer, trace: *Trace, mode: SteerMode, prompt: []const u8) void {
        const now = id.nowMs(self.io);
        self.trace_mu.lockUncancelable(self.io);
        defer self.trace_mu.unlock(self.io);
        trace.addSteer(self.allocator, mode, prompt, now) catch {};
    }

    fn finalizeTrace(self: *PlaygroundServer, msg_id: u128, trace: *Trace, end_ms: u64, err_msg: ?[]const u8) void {
        self.trace_mu.lockUncancelable(self.io);
        trace.closeReasoning(end_ms);
        trace.ended_ms = end_ms;
        if (err_msg) |e| trace.setError(self.allocator, e) catch {};
        _ = self.live_traces.remove(msg_id);
        self.trace_mu.unlock(self.io);
        self.writeTraceFile(msg_id, trace) catch {};
    }

    fn liveTraceJson(self: *PlaygroundServer, msg_id: u128) ?[]u8 {
        self.trace_mu.lockUncancelable(self.io);
        defer self.trace_mu.unlock(self.io);
        const t = self.live_traces.get(msg_id) orelse return null;
        var buf: std.ArrayList(u8) = .empty;
        t.writeJson(self.allocator, &buf) catch {
            buf.deinit(self.allocator);
            return null;
        };
        return buf.toOwnedSlice(self.allocator) catch {
            buf.deinit(self.allocator);
            return null;
        };
    }

    fn traceJsonFor(self: *PlaygroundServer, msg_id: u128) ?[]u8 {
        if (self.liveTraceJson(msg_id)) |live| return live;
        var name_buf: [37]u8 = undefined;
        const data = self.traces_dir.readFileAlloc(self.io, traceFileName(msg_id, &name_buf), self.allocator, .limited(MAX_TRACE_BYTES)) catch return null;
        const valid = std.json.validate(self.allocator, data) catch false;
        if (!valid) {
            self.allocator.free(data);
            return null;
        }
        return data;
    }

    fn siblingsIncluding(self: *PlaygroundServer, msg_id: u128) ![]u128 {
        const sibs = try self.engine.siblings(self.allocator, msg_id);
        if (std.mem.indexOfScalar(u128, sibs, msg_id) != null) return sibs;
        defer self.allocator.free(sibs);
        const full = try self.allocator.alloc(u128, sibs.len + 1);
        @memcpy(full[0..sibs.len], sibs);
        full[sibs.len] = msg_id;
        return full;
    }

    fn actorLabel(self: *const PlaygroundServer, actor: id.ActorId) []const u8 {
        if (actor == self.workspace.disk_actor) return "disk";
        return switch (actor) {
            7 => "editor",
            1, 2, 3 => "seed",
            else => "agent",
        };
    }

    fn emitQueueEvent(self: *PlaygroundServer, thread_id: u128) void {
        var thex: [32]u8 = undefined;
        _ = id.formatIdHex(thread_id, &thex);
        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"queue_updated\",\"thread_id\":\"{s}\"}}", .{thex}) catch return;
        self.broadcastSse(json);
    }

    const PendingRelayBlob = struct {
        pid: id.PageId,
        raw: []u8,
    };

    fn syncThreadToRelayWithIoLocked(self: *PlaygroundServer, thread_id: u128) !void {
        var sum_opt: ?model.SessionSummary = null;
        var pending_blobs: std.ArrayList(PendingRelayBlob) = .empty;
        defer {
            if (sum_opt) |*s| s.deinit(self.allocator);
            for (pending_blobs.items) |b| self.allocator.free(b.raw);
            pending_blobs.deinit(self.allocator);
        }

        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const t = self.engine.journal.threads.get(thread_id) orelse return;
            sum_opt = try model.SessionSummary.fromThread(self.allocator, &t);
            var cur = t.head_page;
            while (cur) |pid| {
                if (self.dev_a.uploaded_blobs.contains(pid)) break;
                const raw = try self.engine.journal.pages.get(self.allocator, pid) orelse break;
                errdefer self.allocator.free(raw);
                var page = try pager.MessagePage.decode(self.allocator, raw);
                const prev = page.prev_page;
                page.deinit(self.allocator);
                try pending_blobs.append(self.allocator, .{ .pid = pid, .raw = raw });
                cur = prev;
            }
        }

        var sum = sum_opt orelse return;
        const topic = id.threadStreamId(thread_id);
        try self.dev_a.authorizeTopic(topic, wire.PERM_ALL);
        try self.dev_b.authorizeTopic(topic, wire.PERM_ALL);
        for (pending_blobs.items) |b| {
            try self.dev_a.putEncryptedBlob(topic, b.pid, b.raw);
            try self.dev_a.uploaded_blobs.put(self.dev_a.allocator, b.pid, {});
        }
        _ = try self.dev_a.pushSessionSummary(self.vault_id, &sum);
    }

    fn syncThreadToRelay(self: *PlaygroundServer, thread_id: u128) !void {
        self.relay_io_mu.lockUncancelable(self.io);
        defer self.relay_io_mu.unlock(self.io);
        try self.syncThreadToRelayWithIoLocked(thread_id);
    }

    fn syncAllThreadsToRelayLocked(self: *PlaygroundServer) !void {
        var tids: std.ArrayList(u128) = .empty;
        defer tids.deinit(self.allocator);
        var it = self.engine.journal.threads.keyIterator();
        while (it.next()) |tid| {
            try tids.append(self.allocator, tid.*);
        }
        for (tids.items) |tid| {
            self.syncThreadToRelay(tid) catch {};
        }
    }

    fn scheduleRelaySync(self: *PlaygroundServer, thread_id: u128) void {
        self.relay_sync_mu.lockUncancelable(self.io);
        var exists = false;
        for (self.relay_sync_pending.items) |existing| {
            if (existing == thread_id) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            self.relay_sync_pending.append(self.allocator, thread_id) catch {};
        }
        self.relay_sync_cond.signal(self.io);
        self.relay_sync_mu.unlock(self.io);
    }

    fn flushRelaySyncWithIoLocked(self: *PlaygroundServer) void {
        var batch: std.ArrayList(u128) = .empty;
        defer batch.deinit(self.allocator);
        self.relay_sync_mu.lockUncancelable(self.io);
        if (self.relay_sync_pending.items.len > 0) {
            batch.appendSlice(self.allocator, self.relay_sync_pending.items) catch {};
            self.relay_sync_pending.clearRetainingCapacity();
        }
        self.relay_sync_mu.unlock(self.io);
        for (batch.items) |tid| {
            self.syncThreadToRelayWithIoLocked(tid) catch {};
        }
    }

    fn relaySyncMain(self: *PlaygroundServer) void {
        var batch: std.ArrayList(u128) = .empty;
        defer batch.deinit(self.allocator);
        while (true) {
            self.relay_sync_mu.lockUncancelable(self.io);
            while (self.running.load(.acquire) and self.relay_sync_pending.items.len == 0) {
                self.relay_sync_cond.waitUncancelable(self.io, &self.relay_sync_mu);
            }
            if (!self.running.load(.acquire)) {
                self.relay_sync_mu.unlock(self.io);
                return;
            }
            batch.clearRetainingCapacity();
            batch.appendSlice(self.allocator, self.relay_sync_pending.items) catch {};
            self.relay_sync_pending.clearRetainingCapacity();
            self.relay_sync_mu.unlock(self.io);

            for (batch.items) |tid| {
                self.syncThreadToRelay(tid) catch {};
            }
        }
    }

    fn broadcastSse(self: *PlaygroundServer, json_payload: []const u8) void {
        const frame = std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{json_payload}) catch return;
        defer self.allocator.free(frame);

        self.sse_mu.lockUncancelable(self.io);
        defer self.sse_mu.unlock(self.io);

        var i: usize = 0;
        while (i < self.sse_clients.items.len) {
            const fd = self.sse_clients.items[i];
            const ok = writeAllNonBlocking(fd, frame);
            if (!ok) {
                _ = linux.close(fd);
                _ = self.sse_clients.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn serve(self: *PlaygroundServer) !void {
        while (self.running.load(.acquire)) {
            const rc = linux.accept4(self.listen_fd, null, null, linux.SOCK.CLOEXEC);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) break;
            const cfd: posix.fd_t = @intCast(rc);
            var one: i32 = 1;
            _ = linux.setsockopt(cfd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
            const prev_conns = self.active_conns.fetchAdd(1, .acq_rel);
            if (prev_conns >= MAX_CONNS) {
                _ = self.active_conns.fetchSub(1, .release);
                _ = sendHttp(cfd, "503 Service Unavailable", "application/json", "{\"error\":\"ServerBusy\"}", false);
                _ = linux.close(cfd);
                continue;
            }
            const args = self.allocator.create(ConnArgs) catch {
                _ = self.active_conns.fetchSub(1, .release);
                _ = linux.close(cfd);
                continue;
            };
            args.* = .{ .srv = self, .fd = cfd };
            _ = self.active_threads.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, connThreadMain, .{args}) catch {
                _ = self.active_threads.fetchSub(1, .release);
                _ = self.active_conns.fetchSub(1, .release);
                self.allocator.destroy(args);
                _ = linux.close(cfd);
                continue;
            };
            th.detach();
        }
    }

    fn connThreadMain(args: *ConnArgs) void {
        const srv = args.srv;
        const fd = args.fd;
        srv.allocator.destroy(args);
        defer _ = srv.active_threads.fetchSub(1, .release);
        defer _ = srv.active_conns.fetchSub(1, .release);
        srv.handleConnection(fd);
    }

    fn readMoreHttp(
        self: *PlaygroundServer,
        fd: posix.fd_t,
        req_buf: *std.ArrayList(u8),
        tmp: *[4096]u8,
        max_wait_ms: usize,
        waited_ms: *usize,
    ) bool {
        while (true) {
            if (!self.running.load(.acquire)) return false;
            var pfd = [_]linux.pollfd{.{
                .fd = fd,
                .events = linux.POLL.IN,
                .revents = 0,
            }};
            const prc = linux.poll(&pfd, 1, 250);
            const pe = linux.errno(prc);
            if (pe == .INTR) continue;
            if (pe != .SUCCESS) return false;
            if (prc == 0) {
                waited_ms.* += 250;
                if (waited_ms.* >= max_wait_ms) return false;
                continue;
            }
            const rc = linux.read(fd, tmp, tmp.len);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS or rc == 0) return false;
            waited_ms.* = 0;
            req_buf.appendSlice(self.allocator, tmp[0..rc]) catch return false;
            return true;
        }
    }

    fn handleConnection(self: *PlaygroundServer, fd: posix.fd_t) void {
        var req_buf: std.ArrayList(u8) = .empty;
        defer req_buf.deinit(self.allocator);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var tmp: [4096]u8 = undefined;
        var handed_to_sse = false;
        defer if (!handed_to_sse) {
            _ = linux.close(fd);
        };

        var req_count: usize = 0;
        while (self.running.load(.acquire)) {
            const max_wait_ms: usize = if (req_count == 0) 30_000 else 15_000;
            var waited_ms: usize = 0;

            var header_idx: ?usize = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n");
            while (header_idx == null) {
                if (req_buf.items.len > MAX_HEADER_BYTES) {
                    _ = sendHttp(fd, "431 Request Header Fields Too Large", "application/json", "{\"error\":\"HeadersTooLarge\"}", false);
                    return;
                }
                if (!self.readMoreHttp(fd, &req_buf, &tmp, max_wait_ms, &waited_ms)) return;
                header_idx = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n");
            }

            const hidx = header_idx.?;
            if (hidx > MAX_HEADER_BYTES) {
                _ = sendHttp(fd, "431 Request Header Fields Too Large", "application/json", "{\"error\":\"HeadersTooLarge\"}", false);
                return;
            }
            const hend = hidx + 4;
            const framing = parseHttpFraming(req_buf.items[0..hidx]) catch |err| {
                switch (err) {
                    error.BadFraming => _ = sendHttp(fd, "400 Bad Request", "application/json", "{\"error\":\"BadFraming\"}", false),
                    error.PayloadTooLarge => _ = sendHttp(fd, "413 Payload Too Large", "application/json", "{\"error\":\"PayloadTooLarge\"}", false),
                }
                return;
            };

            var chunked_body: ?[]u8 = null;
            defer if (chunked_body) |cb| self.allocator.free(cb);
            var total_req_len: usize = hend;
            var body: []const u8 = "";

            switch (framing) {
                .content_length => |content_len| {
                    while (req_buf.items.len < hend + content_len) {
                        if (!self.readMoreHttp(fd, &req_buf, &tmp, max_wait_ms, &waited_ms)) return;
                    }
                    total_req_len = hend + content_len;
                    body = req_buf.items[hend..total_req_len];
                },
                .chunked => {
                    const max_raw_chunked = hend + MAX_BODY_BYTES * 2 + 65536;
                    while (true) {
                        const res = decodeChunkedBody(self.allocator, req_buf.items[hend..], MAX_BODY_BYTES) catch |err| {
                            switch (err) {
                                error.BadFraming => _ = sendHttp(fd, "400 Bad Request", "application/json", "{\"error\":\"BadFraming\"}", false),
                                error.PayloadTooLarge => _ = sendHttp(fd, "413 Payload Too Large", "application/json", "{\"error\":\"PayloadTooLarge\"}", false),
                                error.OutOfMemory => {},
                            }
                            return;
                        };
                        switch (res) {
                            .complete => |done| {
                                chunked_body = done.body;
                                body = done.body;
                                total_req_len = hend + done.consumed;
                                break;
                            },
                            .need_more => {
                                if (req_buf.items.len >= max_raw_chunked) {
                                    _ = sendHttp(fd, "413 Payload Too Large", "application/json", "{\"error\":\"PayloadTooLarge\"}", false);
                                    return;
                                }
                                if (!self.readMoreHttp(fd, &req_buf, &tmp, max_wait_ms, &waited_ms)) return;
                            },
                        }
                    }
                },
            }

            const head = req_buf.items[0..hidx];
            const keep_alive = shouldKeepAlive(head);

            const first_nl = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
            const req_line = head[0..first_nl];
            var parts = std.mem.splitScalar(u8, req_line, ' ');
            const method = parts.next() orelse "";
            const target = parts.next() orelse "/";

            var path = target;
            var query: []const u8 = "";
            if (std.mem.indexOfScalar(u8, target, '?')) |qi| {
                path = target[0..qi];
                query = target[qi + 1 ..];
            }

            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/events")) {
                self.sse_mu.lockUncancelable(self.io);
                const sse_full = self.sse_clients.items.len >= MAX_SSE_CLIENTS;
                self.sse_mu.unlock(self.io);
                if (sse_full) {
                    _ = sendHttp(fd, "503 Service Unavailable", "application/json", "{\"error\":\"TooManySseClients\"}", false);
                    return;
                }
                const sse_hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n";
                if (!writeAllRaw(fd, sse_hdr)) return;
                wire.setNonBlocking(fd) catch return;
                self.sse_mu.lockUncancelable(self.io);
                if (!self.running.load(.acquire) or self.sse_clients.items.len >= MAX_SSE_CLIENTS) {
                    self.sse_mu.unlock(self.io);
                    return;
                }
                self.sse_clients.append(self.allocator, fd) catch {
                    self.sse_mu.unlock(self.io);
                    return;
                };
                self.sse_mu.unlock(self.io);
                handed_to_sse = true;
                return;
            }

            const is_head = std.mem.eql(u8, method, "HEAD");
            var write_ok = true;
            if ((std.mem.eql(u8, method, "GET") or is_head) and !std.mem.startsWith(u8, path, "/api/")) {
                write_ok = self.serveStatic(fd, path, is_head, keep_alive);
            } else {
                out.clearRetainingCapacity();
                if (self.routeApi(method, path, query, body, &out)) |_| {
                    write_ok = sendHttp(fd, "200 OK", "application/json", out.items, keep_alive);
                } else |err| {
                    out.clearRetainingCapacity();
                    out.print(self.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch {};
                    write_ok = sendHttp(fd, "400 Bad Request", "application/json", out.items, keep_alive);
                }
            }

            if (!write_ok or !keep_alive) return;

            const rem = req_buf.items.len - total_req_len;
            if (rem > 0) {
                std.mem.copyForwards(u8, req_buf.items[0..rem], req_buf.items[total_req_len..]);
            }
            req_buf.shrinkRetainingCapacity(rem);
            req_count += 1;
        }
    }

    fn serveStatic(self: *PlaygroundServer, fd: posix.fd_t, raw_path: []const u8, head_only: bool, keep_alive: bool) bool {
        const dist = self.ui_dist orelse {
            return sendHttpFull(fd, "200 OK", "text/html; charset=utf-8", UI_NOT_BUILT_HTML, "no-store", head_only, keep_alive);
        };
        const decoded = urlDecode(self.allocator, raw_path) catch {
            return sendHttpFull(fd, "500 Internal Server Error", "text/plain; charset=utf-8", "out of memory", "no-store", head_only, keep_alive);
        };
        defer self.allocator.free(decoded);
        const trimmed = std.mem.trimStart(u8, decoded, "/");
        const rel = if (trimmed.len == 0) "index.html" else trimmed;
        if (!isSafeRelPath(rel)) {
            return sendHttpFull(fd, "400 Bad Request", "text/plain; charset=utf-8", "invalid path", "no-store", head_only, keep_alive);
        }

        if (self.readDistFile(dist, rel)) |data| {
            defer self.allocator.free(data);
            const cache = if (std.mem.startsWith(u8, rel, "assets/")) IMMUTABLE_CACHE else "no-store";
            return sendHttpFull(fd, "200 OK", mimeFor(rel), data, cache, head_only, keep_alive);
        }
        if (std.fs.path.extension(rel).len == 0) {
            if (self.readDistFile(dist, "index.html")) |index| {
                defer self.allocator.free(index);
                return sendHttpFull(fd, "200 OK", "text/html; charset=utf-8", index, "no-store", head_only, keep_alive);
            }
        }
        return sendHttpFull(fd, "404 Not Found", "text/plain; charset=utf-8", "not found", "no-store", head_only, keep_alive);
    }

    fn readDistFile(self: *PlaygroundServer, dist: []const u8, rel: []const u8) ?[]u8 {
        const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dist, rel }) catch return null;
        defer self.allocator.free(full);
        return Io.Dir.cwd().readFileAlloc(self.io, full, self.allocator, .limited(MAX_STATIC_BYTES)) catch null;
    }

    fn routeApi(
        self: *PlaygroundServer,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/info")) {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const provs = registry.listProviders(self.io);
            var hhex: [32]u8 = undefined;
            _ = id.formatIdHex(self.workspace.history.history_id, &hhex);
            try out.appendSlice(self.allocator, "{\"workspace_root\":");
            try rpc.appendJsonEscaped(self.allocator, out, self.workspace.root_path);
            try out.print(
                self.allocator,
                ",\"history_id\":\"{s}\",\"heads\":{d},\"batches\":{d},\"rss_kb\":{d},\"owned_heap_bytes\":{d},\"relay_port\":{d},\"page_size\":{d},\"threads\":{d},\"dag_batches\":{d},\"ui_dist\":",
                .{
                    hhex,
                    self.workspace.history.dag.heads.slice().len,
                    self.workspace.batch_log.count(),
                    readRssKb(self.io),
                    self.workspace.history.ownedHeapBytes(),
                    self.relay.port,
                    self.engine.page_size,
                    self.engine.journal.threads.count(),
                    self.workspace.history.dag.count(),
                },
            );
            if (self.ui_dist) |d| {
                try rpc.appendJsonEscaped(self.allocator, out, d);
            } else {
                try out.appendSlice(self.allocator, "null");
            }
            try out.appendSlice(self.allocator, ",\"providers\":[");
            for (provs, 0..) |p, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try out.print(
                    self.allocator,
                    "{{\"slug\":\"{s}\",\"name\":\"{s}\",\"binary\":\"{s}\",\"available\":{},\"native_steer\":{},\"persistent\":{},\"resume_session\":{},\"fork_at_message\":{}}}",
                    .{
                        p.id.slug(),
                        p.id.displayName(),
                        registry.programFor(p.id),
                        p.available,
                        p.capabilities.native_steer,
                        p.capabilities.persistent,
                        p.capabilities.resume_session,
                        p.capabilities.fork_at_message,
                    },
                );
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/models/all")) {
            self.models_mu.lockUncancelable(self.io);
            defer self.models_mu.unlock(self.io);
            try out.appendSlice(self.allocator, "{\"catalogs\":{");
            var first = true;
            const all_ids = [_]iface.ProviderId{
                .mock,
                .antigravity,
                .claude_code,
                .codex,
                .pi,
                .hermes,
                .opencode,
                .cursor,
                .devin,
                .muse,
            };
            for (all_ids) |pid| {
                const entry = self.model_cache.get(@intFromEnum(pid)) orelse continue;
                if (!first) try out.append(self.allocator, ',');
                first = false;
                try out.print(self.allocator, "\"{s}\":", .{pid.slug()});
                try appendCatalogJson(self.allocator, out, pid, &entry);
            }
            try out.appendSlice(self.allocator, "}}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/models")) {
            const pslug = queryParam(query, "provider") orelse return error.MissingProvider;
            const force = std.mem.eql(u8, queryParam(query, "refresh") orelse "0", "1");
            const pid = parseProviderSlug(pslug);
            const avail = registry.isAvailable(self.io, pid);

            if (!avail and pid != .mock) {
                try out.print(
                    self.allocator,
                    "{{\"provider\":\"{s}\",\"available\":false,\"ready\":true,\"elapsed_us\":0,\"note\":\"CLI `{s}` not found on PATH\",\"models\":[]}}",
                    .{ pid.slug(), registry.programFor(pid) },
                );
                return;
            }

            var has_cached = false;
            if (!force) {
                self.models_mu.lockUncancelable(self.io);
                has_cached = self.model_cache.contains(@intFromEnum(pid));
                self.models_mu.unlock(self.io);
            }
            if (!has_cached or force) {
                try self.refreshModelCache(pid);
            }

            self.models_mu.lockUncancelable(self.io);
            defer self.models_mu.unlock(self.io);
            if (self.model_cache.get(@intFromEnum(pid))) |entry| {
                try appendCatalogJson(self.allocator, out, pid, &entry);
            } else {
                try out.print(
                    self.allocator,
                    "{{\"provider\":\"{s}\",\"available\":true,\"ready\":true,\"elapsed_us\":0,\"note\":null,\"models\":[]}}",
                    .{pid.slug()},
                );
            }
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/sessions")) {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const sums = try self.engine.listSessions(self.allocator);
            defer {
                for (sums) |*s| s.deinit(self.allocator);
                self.allocator.free(sums);
            }
            try out.appendSlice(self.allocator, "{\"sessions\":[");
            for (sums, 0..) |s, i| {
                if (i > 0) try out.append(self.allocator, ',');
                const t_model: ?[]const u8 = if (self.engine.journal.threads.get(s.thread_id)) |t| t.default_model else null;
                try appendSessionSummaryJson(self.allocator, out, &s, t_model);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/threads")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "Untitled session";
            const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
            const mdl_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model")) orelse "";
            const wt_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse "";
            const prov = parseProviderSlug(prov_slug);
            const mdl: ?[]const u8 = if (mdl_raw.len > 0)
                mdl_raw
            else if (std.mem.eql(u8, prov_slug, "mock-fallback"))
                "sim-fallback-v1"
            else
                null;
            const wt_id_opt: ?u128 = if (wt_raw.len > 0) try id.parseIdHex(wt_raw) else null;

            const tid = blk: {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (wt_id_opt) |wid| {
                    if (self.worktrees.get(wid) == null) return error.WorktreeNotFound;
                    break :blk try self.engine.createThreadInWorktree(title, prov, mdl, wid);
                }
                break :blk try self.engine.createThread(title, prov, mdl);
            };

            self.scheduleRelaySync(tid);
            var thex: [32]u8 = undefined;
            _ = id.formatIdHex(tid, &thex);
            try out.print(self.allocator, "{{\"thread_id\":\"{s}\"}}", .{thex});
            self.emitSessionEvent(tid);
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/threads/")) {
            const rest = path["/api/threads/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidRoute;
            const tid_hex = rest[0..slash];
            const sub = rest[slash + 1 ..];
            const tid = try id.parseIdHex(tid_hex);

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "config")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const prov_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider"));
                const mdl_val = rpc.jsonObjGet(parsed.value, "model");
                const title_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title"));

                {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    if (self.engine.journal.threads.getPtr(tid)) |t| {
                        var u = try t.clone(self.allocator);
                        errdefer u.deinit(self.allocator);
                        if (prov_raw) |ps| u.default_provider = parseProviderSlug(ps);
                        if (mdl_val) |mv| {
                            if (u.default_model) |old| self.allocator.free(old);
                            u.default_model = null;
                            if (mv == .string and mv.string.len > 0) {
                                u.default_model = try self.allocator.dupe(u8, mv.string);
                            }
                        }
                        if (title_raw) |tr| {
                            if (tr.len > 0) {
                                const new_title = try self.allocator.dupe(u8, tr);
                                self.allocator.free(u.title);
                                u.title = new_title;
                            }
                        }
                        u.updated_ms = id.nowMs(self.io);
                        try self.engine.journal.putThread(u);
                    }
                }

                self.scheduleRelaySync(tid);
                self.emitSessionEvent(tid);
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }

            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "page")) {
                const limit_str = queryParam(query, "limit") orelse "8";
                const limit = @min(std.fmt.parseInt(usize, limit_str, 10) catch 8, 200);
                const before_str = queryParam(query, "before");
                const before_id: ?u128 = if (before_str) |b| (if (b.len == 32) try id.parseIdHex(b) else null) else null;
                const branch_str = queryParam(query, "branch");
                const branch_id: ?u128 = if (branch_str) |b| (if (b.len == 32) try id.parseIdHex(b) else null) else null;
                const from_str = queryParam(query, "from_msg_id");
                const from_id: ?u128 = if (from_str) |b| (if (b.len == 32) id.parseIdHex(b) catch null else null) else null;

                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (branch_id) |bmid| {
                    try self.appendBranchPreviewJsonLocked(tid, bmid, from_id, limit, out);
                } else {
                    try self.appendPageJsonLocked(tid, before_id, limit, out);
                }
                return;
            }

            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "queue")) {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                try out.appendSlice(self.allocator, "{\"items\":[");
                var first = true;
                for (self.engine.journal.queue_order.items) |qid| {
                    const q = self.engine.journal.queue_items.get(qid) orelse continue;
                    if (q.thread_id != tid) continue;
                    if (!first) try out.append(self.allocator, ',');
                    first = false;
                    var qhex: [32]u8 = undefined;
                    _ = id.formatIdHex(q.item_id, &qhex);
                    try out.print(
                        self.allocator,
                        "{{\"item_id\":\"{s}\",\"kind\":\"{s}\",\"status\":\"{s}\",\"provider\":\"{s}\",\"prompt\":",
                        .{ qhex, @tagName(q.kind), @tagName(q.status), q.provider.slug() },
                    );
                    try rpc.appendJsonEscaped(self.allocator, out, q.prompt);
                    try out.appendSlice(self.allocator, ",\"model\":");
                    if (q.model) |qm| {
                        try rpc.appendJsonEscaped(self.allocator, out, qm);
                    } else {
                        try out.appendSlice(self.allocator, "null");
                    }
                    try out.print(self.allocator, ",\"created_ms\":{d},\"updated_ms\":{d}}}", .{ q.created_ms, q.updated_ms });
                }
                try out.appendSlice(self.allocator, "]}");
                return;
            }

            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "diff")) {
                const mid_hex = queryParam(query, "msg_id") orelse return error.MissingMsgId;
                const mid = try id.parseIdHex(mid_hex);
                const t0 = nowUs(self.io);
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                const msg = self.engine.journal.messages.getPtr(mid) orelse return error.MessageNotFound;
                if (msg.thread_id != tid) return error.MessageWrongThread;

                var files: std.ArrayList(u8) = .empty;
                defer files.deinit(self.allocator);
                try self.appendTurnDiffFiles(msg, &files);
                const elapsed = nowUs(self.io) -| t0;

                var mhex: [32]u8 = undefined;
                _ = id.formatIdHex(mid, &mhex);
                try out.print(self.allocator, "{{\"msg_id\":\"{s}\",\"elapsed_us\":{d},\"files\":[", .{ mhex, elapsed });
                try out.appendSlice(self.allocator, files.items);
                try out.appendSlice(self.allocator, "]}");
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "send")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse return error.MissingPrompt;
                const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
                const mdl_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model")) orelse "";
                const mdl: ?[]const u8 = if (mdl_raw.len > 0) mdl_raw else null;
                try self.spawnWorker(tid, .send_new, prompt, null, prov_slug, mdl);
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "steer")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse return error.MissingPrompt;
                const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
                const mdl_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model")) orelse "";
                const mdl: ?[]const u8 = if (mdl_raw.len > 0) mdl_raw else null;

                const qid = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    break :blk try self.engine.steer(tid, prompt, parseProviderSlug(prov_slug), mdl);
                };

                self.scheduleRelaySync(tid);
                var qhex: [32]u8 = undefined;
                _ = id.formatIdHex(qid, &qhex);
                try out.print(self.allocator, "{{\"item_id\":\"{s}\"}}", .{qhex});
                self.emitSessionEvent(tid);
                self.emitQueueEvent(tid);
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "queue")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse return error.MissingPrompt;
                const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
                const mdl_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model")) orelse "";
                const mdl: ?[]const u8 = if (mdl_raw.len > 0) mdl_raw else null;

                const qid = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    break :blk try self.engine.enqueue(tid, prompt, parseProviderSlug(prov_slug), mdl);
                };

                self.scheduleRelaySync(tid);
                var qhex: [32]u8 = undefined;
                _ = id.formatIdHex(qid, &qhex);
                try out.print(self.allocator, "{{\"item_id\":\"{s}\"}}", .{qhex});
                self.emitSessionEvent(tid);
                self.emitQueueEvent(tid);
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "interrupt")) {
                const interrupted = self.interruptThreadTurn(tid);
                try out.print(self.allocator, "{{\"interrupted\":{}}}", .{interrupted});
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "drain")) {
                try self.spawnWorker(tid, .drain_queue, "", null, "mock", null);
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "edit")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const mid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "msg_id")) orelse return error.MissingMsgId;
                const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse return error.MissingPrompt;
                const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
                const mdl_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model")) orelse "";
                const mdl: ?[]const u8 = if (mdl_raw.len > 0) mdl_raw else null;
                const mid = try id.parseIdHex(mid_hex);

                const new_user_id = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    self.active_source = "edit";
                    self.active_msg_id = mid;
                    defer {
                        self.active_source = null;
                        self.active_msg_id = null;
                    }
                    break :blk try self.engine.editMessage(tid, mid, prompt, parseProviderSlug(prov_slug), mdl);
                };

                self.scheduleRelaySync(tid);
                try self.spawnWorker(tid, .reply_existing, prompt, new_user_id, prov_slug, mdl);
                var nhex: [32]u8 = undefined;
                _ = id.formatIdHex(new_user_id, &nhex);
                try out.print(self.allocator, "{{\"msg_id\":\"{s}\"}}", .{nhex});
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "rollback")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const mid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "msg_id")) orelse "";
                const mid: ?u128 = if (mid_hex.len == 32) try id.parseIdHex(mid_hex) else null;
                const req_limit = jsonU64(rpc.jsonObjGet(parsed.value, "limit"));
                const limit: usize = if (req_limit > 0) @intCast(@min(req_limit, 200)) else self.engine.page_size;

                const head_page: ?id.PageId = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const t0 = nowUs(self.io);
                    self.active_source = "rollback";
                    self.active_msg_id = mid;
                    defer {
                        self.active_source = null;
                        self.active_msg_id = null;
                    }
                    try self.engine.rollback(tid, mid);
                    const elapsed = nowUs(self.io) -| t0;
                    try out.print(self.allocator, "{{\"ok\":true,\"elapsed_us\":{d},\"page\":", .{elapsed});
                    try self.appendPageJsonLocked(tid, null, limit, out);
                    try out.append(self.allocator, '}');
                    break :blk if (self.engine.journal.threads.get(tid)) |t| t.head_page else null;
                };

                self.emitSessionEventWithHead(tid, head_page);
                self.scheduleRelaySync(tid);
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "branch")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const mid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "msg_id")) orelse return error.MissingMsgId;
                const mid = try id.parseIdHex(mid_hex);
                const from_mid: ?u128 = if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "from_msg_id"))) |fh|
                    (if (fh.len > 0) id.parseIdHex(fh) catch null else null)
                else
                    null;
                const req_limit = jsonU64(rpc.jsonObjGet(parsed.value, "limit"));
                const limit: usize = if (req_limit > 0) @intCast(@min(req_limit, 200)) else self.engine.page_size;

                const head_page: ?id.PageId = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const t0 = nowUs(self.io);
                    self.active_source = "branch";
                    self.active_msg_id = mid;
                    defer {
                        self.active_source = null;
                        self.active_msg_id = null;
                    }
                    const leaf = try self.engine.switchBranch(tid, mid);
                    const elapsed = nowUs(self.io) -| t0;
                    var effective_limit: usize = limit;
                    {
                        var cur: ?u128 = leaf;
                        var count: usize = 0;
                        while (cur) |cid| : (count += 1) {
                            if (count >= 1000) break;
                            if (cid == mid) {
                                effective_limit = @max(effective_limit, count + 1);
                                if (from_mid == null) break;
                            }
                            if (from_mid) |fmid| {
                                if (cid == fmid) {
                                    effective_limit = @max(effective_limit, count + 1);
                                    break;
                                }
                            }
                            const m = self.engine.journal.messages.get(cid) orelse break;
                            cur = m.parent_id;
                        }
                    }
                    var lhex: [32]u8 = undefined;
                    _ = id.formatIdHex(leaf, &lhex);
                    try out.print(self.allocator, "{{\"leaf_msg_id\":\"{s}\",\"elapsed_us\":{d},\"page\":", .{ lhex, elapsed });
                    try self.appendPageJsonLocked(tid, null, effective_limit, out);
                    try out.append(self.allocator, '}');
                    break :blk if (self.engine.journal.threads.get(tid)) |t| t.head_page else null;
                };

                self.emitSessionEventWithHead(tid, head_page);
                self.scheduleRelaySync(tid);
                return;
            }
        }

        if (std.mem.startsWith(u8, path, "/api/queue/")) {
            const rest = path["/api/queue/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidRoute;
            const qid = try id.parseIdHex(rest[0..slash]);
            const sub = rest[slash + 1 ..];

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "cancel")) {
                const q_tid = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const t = if (self.engine.journal.queue_items.get(qid)) |q| q.thread_id else null;
                    try self.engine.cancelQueued(qid);
                    break :blk t;
                };
                if (q_tid) |t| {
                    self.scheduleRelaySync(t);
                    self.emitSessionEvent(t);
                    self.emitQueueEvent(t);
                }
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }
            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "edit")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse return error.MissingPrompt;
                const q_tid = blk: {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const t = if (self.engine.journal.queue_items.get(qid)) |q| q.thread_id else null;
                    try self.engine.editQueued(qid, prompt);
                    break :blk t;
                };
                if (q_tid) |t| self.emitQueueEvent(t);
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/files")) {
            const t0 = nowUs(self.io);
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var paths: std.ArrayList([]u8) = .empty;
            defer {
                for (paths.items) |p| self.allocator.free(p);
                paths.deinit(self.allocator);
            }
            try self.collectTrackedFilePaths(id.InodeId.ROOT, "", text_mod.View.EVERYTHING, &paths);
            sortDedupePaths(self.allocator, &paths);
            const ver_hex = try self.workspace.history.dag.heads.formatHex(self.allocator);
            defer self.allocator.free(ver_hex);
            try out.appendSlice(self.allocator, "{\"version\":");
            try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
            try out.appendSlice(self.allocator, ",\"files\":[");
            for (paths.items, 0..) |p, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var bytes_len: u64 = 0;
                var lines_cnt: usize = 0;
                if (try self.workspace.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, p)) |iid| {
                    if (self.workspace.history.tree.get(iid)) |inode| {
                        if (inode.fileConstPtr()) |f| {
                            bytes_len = f.text.visibleLen();
                            lines_cnt = f.text.lineCount();
                        }
                    }
                }
                const meta = self.file_meta.get(p);
                try out.appendSlice(self.allocator, "{\"path\":");
                try rpc.appendJsonEscaped(self.allocator, out, p);
                try out.print(
                    self.allocator,
                    ",\"bytes\":{d},\"lines\":{d},\"changed_ms\":{d},\"kind\":\"{s}\"}}",
                    .{
                        bytes_len,
                        lines_cnt,
                        if (meta) |m| m.changed_ms else id.nowMs(self.io),
                        if (meta) |m| @tagName(m.kind) else "added",
                    },
                );
            }
            try out.print(self.allocator, "],\"elapsed_us\":{d}}}", .{nowUs(self.io) -| t0});
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/file")) {
            const raw_p = queryParam(query, "path") orelse return error.MissingPath;
            const decoded_p = try urlDecode(self.allocator, raw_p);
            defer self.allocator.free(decoded_p);
            if (!isSafeRelPath(decoded_p)) return error.InvalidPath;
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (queryParam(query, "at")) |at_hex| {
                const mid = try id.parseIdHex(at_hex);
                const msg = self.engine.journal.messages.getPtr(mid) orelse return error.MessageNotFound;
                const side = queryParam(query, "side") orelse "post";
                const ver = if (std.mem.eql(u8, side, "pre")) &msg.pre_version else &msg.post_version;
                const at_content = try self.workspace.history.readFileAt(self.allocator, decoded_p, ver);
                defer if (at_content) |c| self.allocator.free(c);
                var mhex: [32]u8 = undefined;
                _ = id.formatIdHex(mid, &mhex);
                try out.appendSlice(self.allocator, "{\"path\":");
                try rpc.appendJsonEscaped(self.allocator, out, decoded_p);
                try out.appendSlice(self.allocator, ",\"content\":");
                if (at_content) |c| {
                    try rpc.appendJsonEscaped(self.allocator, out, c);
                } else {
                    try out.appendSlice(self.allocator, "null");
                }
                try out.print(self.allocator, ",\"at\":\"{s}\"}}", .{mhex});
                return;
            }
            const total_lines: usize = blk: {
                const iid = (try self.workspace.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, decoded_p)) orelse break :blk 0;
                const inode = self.workspace.history.tree.get(iid) orelse break :blk 0;
                const f = inode.fileConstPtr() orelse break :blk 0;
                break :blk f.text.lineCount();
            };
            const ver_hex = try self.workspace.history.dag.heads.formatHex(self.allocator);
            defer self.allocator.free(ver_hex);
            const start_param = queryParam(query, "start_line");
            const lines_param = queryParam(query, "lines");
            if (start_param != null or lines_param != null) {
                const start_1 = if (start_param) |s| std.fmt.parseInt(usize, s, 10) catch 1 else 1;
                const clamped_1 = if (start_1 == 0) 1 else start_1;
                const max_lines = if (lines_param) |l| std.fmt.parseInt(usize, l, 10) catch 200 else 200;
                const slice = try self.workspace.history.readFileLines(self.allocator, decoded_p, clamped_1 - 1, max_lines) orelse return error.FileNotFound;
                defer self.allocator.free(slice);
                try out.appendSlice(self.allocator, "{\"path\":");
                try rpc.appendJsonEscaped(self.allocator, out, decoded_p);
                try out.appendSlice(self.allocator, ",\"version\":");
                try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
                try out.print(self.allocator, ",\"start_line\":{d},\"total_lines\":{d},\"content\":", .{ clamped_1, total_lines });
                try rpc.appendJsonEscaped(self.allocator, out, slice);
                try out.append(self.allocator, '}');
                return;
            }
            const content = try self.workspace.history.readFileAt(self.allocator, decoded_p, null) orelse return error.FileNotFound;
            defer self.allocator.free(content);
            try out.appendSlice(self.allocator, "{\"path\":");
            try rpc.appendJsonEscaped(self.allocator, out, decoded_p);
            try out.appendSlice(self.allocator, ",\"version\":");
            try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
            try out.print(self.allocator, ",\"total_lines\":{d},\"content\":", .{total_lines});
            try rpc.appendJsonEscaped(self.allocator, out, content);
            try out.append(self.allocator, '}');
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/file/rebase")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const fpath = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path")) orelse return error.MissingPath;
            if (!isSafeRelPath(fpath)) return error.InvalidPath;
            const bv_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "base_version")) orelse "";
            const draft = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "draft")) orelse "";
            const cur_start = jsonU64(rpc.jsonObjGet(parsed.value, "cursor_start"));
            const cur_end = jsonU64(rpc.jsonObjGet(parsed.value, "cursor_end"));

            var base_ver = version_mod.Version.parseHex(self.allocator, bv_str) catch {
                try out.appendSlice(self.allocator, "{\"ok\":false,\"reload\":true}");
                return;
            };
            defer base_ver.deinit(self.allocator);

            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var rebase_opt = try self.workspace.rebaseBuffer(
                self.allocator,
                fpath,
                &base_ver,
                draft,
                cur_start,
                cur_end,
            );
            if (rebase_opt == null) {
                try out.appendSlice(self.allocator, "{\"ok\":false,\"reload\":true}");
                return;
            }
            defer rebase_opt.?.deinit(self.allocator);
            const rb = &rebase_opt.?;
            const ver_hex = try rb.version.formatHex(self.allocator);
            defer self.allocator.free(ver_hex);

            try out.appendSlice(self.allocator, "{\"ok\":true,\"version\":");
            try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
            try out.print(
                self.allocator,
                ",\"cursor_start\":{d},\"cursor_end\":{d},\"added\":{d},\"removed\":{d},\"splices\":",
                .{ rb.cursor_start, rb.cursor_end, rb.lines_added, rb.lines_removed },
            );
            try appendSplicesJson(self.allocator, out, rb.splices);
            try out.append(self.allocator, '}');
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/file")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const fpath = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path")) orelse return error.MissingPath;
            if (!isSafeRelPath(fpath)) return error.InvalidPath;
            const content = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "content")) orelse "";
            const bv_str_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "base_version"));

            var base_ver: ?version_mod.Version = null;
            defer if (base_ver) |*bv| bv.deinit(self.allocator);
            if (bv_str_opt) |bv_str| {
                if (bv_str.len > 0) {
                    base_ver = version_mod.Version.parseHex(self.allocator, bv_str) catch null;
                }
            }

            var edit_res: ws_mod.EditCommitResult = blk: {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                self.active_source = "editor";
                self.active_msg_id = null;
                defer self.active_source = null;

                if (base_ver) |*bv| {
                    if (rpc.jsonObjGet(parsed.value, "splices")) |sp_val| {
                        if (sp_val == .array) {
                            const inserted = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "inserted")) orelse "";
                            var splices: std.ArrayList(diff_mod.Splice) = .empty;
                            defer splices.deinit(self.allocator);
                            for (sp_val.array.items) |item| {
                                try splices.append(self.allocator, .{
                                    .at = jsonU64(rpc.jsonObjGet(item, "at")),
                                    .del = jsonU64(rpc.jsonObjGet(item, "del")),
                                    .ins = jsonU64(rpc.jsonObjGet(item, "ins")),
                                });
                            }
                            break :blk try self.workspace.applyFileSplices(7, fpath, bv, splices.items, inserted, "editor");
                        }
                    }
                    break :blk try self.workspace.writeFileAtBase(7, fpath, bv, content, "editor");
                }
                break :blk try self.workspace.writeFileAtBase(7, fpath, null, content, "editor");
            };
            defer edit_res.deinit(self.allocator);

            const ver_hex = try edit_res.version.formatHex(self.allocator);
            defer self.allocator.free(ver_hex);
            try out.appendSlice(self.allocator, "{\"ok\":true,\"version\":");
            try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
            try out.print(self.allocator, ",\"merged\":{},\"content\":", .{edit_res.concurrent_merged});
            try rpc.appendJsonEscaped(self.allocator, out, edit_res.content);
            try out.append(self.allocator, '}');
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/ingest")) {
            const bid = blk: {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                self.active_source = "ingest";
                self.active_msg_id = null;
                defer self.active_source = null;
                break :blk try self.workspace.ingestDiskWithSource("ingest");
            };
            try out.print(self.allocator, "{{\"ingested\":{}}}", .{bid != null});
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/compact")) {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.workspace.compactLog();
            try out.appendSlice(self.allocator, "{\"ok\":true}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/blame")) {
            const raw_p = queryParam(query, "path") orelse return error.MissingPath;
            const decoded_p = try urlDecode(self.allocator, raw_p);
            defer self.allocator.free(decoded_p);
            if (!isSafeRelPath(decoded_p)) return error.InvalidPath;
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var lines = try self.workspace.history.blameFile(self.allocator, decoded_p) orelse {
                try out.appendSlice(self.allocator, "{\"lines\":[]}");
                return;
            };
            defer {
                for (lines.items) |*l| l.deinit(self.allocator);
                lines.deinit(self.allocator);
            }
            const dag = &self.workspace.history.dag;
            try out.appendSlice(self.allocator, "{\"lines\":[");
            for (lines.items, 0..) |l, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var ahex: [32]u8 = undefined;
                _ = id.formatIdHex(l.op.actor, &ahex);
                const wall_ms: u64 = if (l.batch) |b| (if (dag.getHeader(b)) |h| h.wall_ms else 0) else 0;
                try out.print(
                    self.allocator,
                    "{{\"line_no\":{d},\"actor\":\"{s}\",\"actor_label\":\"{s}\",\"ts\":{d},\"wall_ms\":{d},\"text\":",
                    .{ l.line_no, ahex, self.actorLabel(l.op.actor), l.op.ts, wall_ms },
                );
                try rpc.appendJsonEscaped(self.allocator, out, l.text);
                try out.append(self.allocator, '}');
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/history")) {
            const limit = std.fmt.parseInt(usize, queryParam(query, "limit") orelse "200", 10) catch 200;
            const t0 = nowUs(self.io);
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const dag = &self.workspace.history.dag;
            var hdrs: std.ArrayList(*const dag_mod.BatchHeader) = .empty;
            defer hdrs.deinit(self.allocator);
            try hdrs.ensureTotalCapacityPrecise(self.allocator, dag.count());
            var hit = dag.headers.valueIterator();
            while (hit.next()) |h| hdrs.appendAssumeCapacity(h);
            std.mem.sort(*const dag_mod.BatchHeader, hdrs.items, {}, struct {
                fn newerFirst(_: void, a: *const dag_mod.BatchHeader, b: *const dag_mod.BatchHeader) bool {
                    if (a.wall_ms != b.wall_ms) return a.wall_ms > b.wall_ms;
                    if (a.start != b.start) return a.start > b.start;
                    return a.actor > b.actor;
                }
            }.newerFirst);
            const shown = hdrs.items[0..@min(limit, hdrs.items.len)];
            const elapsed = nowUs(self.io) -| t0;

            try out.print(self.allocator, "{{\"elapsed_us\":{d},\"total\":{d},\"batches\":[", .{ elapsed, dag.count() });
            for (shown, 0..) |h, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var ahex: [32]u8 = undefined;
                _ = id.formatIdHex(h.actor, &ahex);
                try out.print(
                    self.allocator,
                    "{{\"id\":\"{s}:{d}\",\"actor\":\"{s}\",\"actor_label\":\"{s}\",\"start\":{d},\"end\":{d},\"ops\":{d},\"wall_ms\":{d},\"parents\":{d},\"head\":{}}}",
                    .{
                        ahex,
                        h.start,
                        ahex,
                        self.actorLabel(h.actor),
                        h.start,
                        h.end,
                        h.opCount(),
                        h.wall_ms,
                        h.parents.slice().len,
                        dag.heads.contains(h.batchId()),
                    },
                );
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/remote/sessions")) {
            const t0 = nowUs(self.io);
            self.relay_io_mu.lockUncancelable(self.io);
            defer self.relay_io_mu.unlock(self.io);
            self.flushRelaySyncWithIoLocked();
            const pulled = try self.dev_b.pullSessionSummaries(self.allocator, self.vault_id, 0);
            defer {
                for (pulled.summaries) |*s| s.deinit(self.allocator);
                self.allocator.free(pulled.summaries);
            }
            const elapsed = nowUs(self.io) -| t0;
            try out.print(self.allocator, "{{\"elapsed_us\":{d},\"last_seq\":{d},\"sessions\":[", .{ elapsed, pulled.last_seq });
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            for (pulled.summaries, 0..) |s, i| {
                if (i > 0) try out.append(self.allocator, ',');
                const t_model: ?[]const u8 = if (self.engine.journal.threads.get(s.thread_id)) |t| t.default_model else null;
                try appendSessionSummaryJson(self.allocator, out, &s, t_model);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/remote/page")) {
            const tid_hex = queryParam(query, "thread_id") orelse return error.MissingThreadId;
            const pid_hex = queryParam(query, "page_id") orelse return error.MissingPageId;
            const tid = try id.parseIdHex(tid_hex);
            var pid: id.PageId = undefined;
            if (pid_hex.len != 64) return error.InvalidPageId;
            _ = std.fmt.hexToBytes(&pid, pid_hex) catch return error.InvalidPageId;

            const t0 = nowUs(self.io);
            self.relay_io_mu.lockUncancelable(self.io);
            defer self.relay_io_mu.unlock(self.io);
            self.flushRelaySyncWithIoLocked();
            const was_cached = self.dev_b_pages.exists(pid);
            const topic = id.threadStreamId(tid);
            try self.dev_b.authorizeTopic(topic, wire.PERM_ALL);
            var page = try self.dev_b.fetchPageLocalFirst(self.allocator, tid, &self.dev_b_pages, pid) orelse return error.PageNotFound;
            defer page.deinit(self.allocator);
            const elapsed = nowUs(self.io) -| t0;

            try out.print(self.allocator, "{{\"page_id\":\"{s}\",\"cache_hit\":{},\"elapsed_us\":{d},\"prev_page\":", .{ pid_hex, was_cached, elapsed });
            if (page.prev_page) |pp| {
                var phex: [64]u8 = undefined;
                _ = id.formatHashHex(pp, &phex);
                try out.print(self.allocator, "\"{s}\"", .{phex});
            } else {
                try out.appendSlice(self.allocator, "null");
            }
            try out.appendSlice(self.allocator, ",\"messages\":[");
            for (page.messages, 0..) |m, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try appendMessageJson(self.allocator, out, &m, &.{}, null);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/remote/clear-cache")) {
            self.relay_io_mu.lockUncancelable(self.io);
            defer self.relay_io_mu.unlock(self.io);
            self.dev_b_pages.deinit();
            self.dev_b_dir.deleteTree(self.io, "pages") catch {};
            self.dev_b_pages = try blobs_mod.BlobStore.open(self.allocator, self.io, self.dev_b_dir, "pages", blobs_mod.DEFAULT_CACHE_BUDGET);
            try out.appendSlice(self.allocator, "{\"ok\":true}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/remote/test-auth")) {
            const t0 = nowUs(self.io);
            var rogue = try client_mod.SyncClient.connect(
                self.allocator,
                self.io,
                .{ 127, 0, 0, 1 },
                self.relay.port,
                self.master_key,
                crypto.hashBytes("rogue-invalid-secret"),
            );
            defer rogue.deinit();
            const rejected = if (rogue.authorizeTopic(id.catalogStreamId(self.vault_id), wire.PERM_ALL)) false else |_| true;
            const elapsed = nowUs(self.io) -| t0;
            try out.print(self.allocator, "{{\"rejected\":{},\"elapsed_us\":{d}}}", .{ rejected, elapsed });
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/worktrees")) {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const items = self.worktrees.list();
            try out.appendSlice(self.allocator, "{\"worktrees\":[");
            for (items, 0..) |*info, i| {
                if (i > 0) try out.append(self.allocator, ',');
                const cfs = self.worktrees.conflicts(info.id) catch null;
                defer if (cfs) |cs| {
                    for (cs) |*c| c.deinit(self.allocator);
                    self.allocator.free(cs);
                };
                const conflict_count: usize = if (cfs) |cs| cs.len else 0;
                try appendWorktreeJson(self.allocator, out, info, info.id == self.primary_wt_id, conflict_count);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/scratch")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "scratch";
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var info = try self.worktrees.scratch(title);
            defer info.deinit(self.allocator);
            try out.appendSlice(self.allocator, "{\"worktree\":");
            try appendWorktreeJson(self.allocator, out, &info, false, 0);
            try out.append(self.allocator, '}');
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/fork")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "fork";
            const src_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "source_id")) orelse "";
            const ref_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "ref_name")) orelse "";
            const src_id: u128 = if (src_hex.len > 0) try id.parseIdHex(src_hex) else self.primary_wt_id;
            const ref_opt: ?[]const u8 = if (ref_raw.len > 0) ref_raw else null;
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var info = try self.worktrees.fork(src_id, title, null, ref_opt);
            defer info.deinit(self.allocator);
            try out.appendSlice(self.allocator, "{\"worktree\":");
            try appendWorktreeJson(self.allocator, out, &info, false, 0);
            try out.append(self.allocator, '}');
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/sync")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const wid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse return error.MissingWorktreeId;
            const wid = try id.parseIdHex(wid_hex);
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var rep = try self.worktrees.syncFork(wid);
            defer rep.deinit(self.allocator);
            try out.print(self.allocator, "{{\"brought\":{d},\"merged\":[", .{rep.brought});
            for (rep.merged, 0..) |mp, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try rpc.appendJsonEscaped(self.allocator, out, mp);
            }
            try out.appendSlice(self.allocator, "],\"conflicts\":[");
            for (rep.conflicts, 0..) |*c, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try out.appendSlice(self.allocator, "{\"path\":");
                try rpc.appendJsonEscaped(self.allocator, out, c.path);
                try out.print(self.allocator, ",\"kind\":\"{s}\"}}", .{@tagName(c.kind)});
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/land")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const wid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse return error.MissingWorktreeId;
            const wid = try id.parseIdHex(wid_hex);
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var rep = try self.worktrees.landFork(wid);
            defer rep.deinit(self.allocator);
            try out.print(self.allocator, "{{\"landed\":{d},\"brought\":{d}}}", .{ rep.landed, rep.sync.brought });
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/resolve")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const wid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse return error.MissingWorktreeId;
            const rel = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path")) orelse return error.MissingPath;
            if (!isSafeRelPath(rel)) return error.InvalidPath;
            const res_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "resolution")) orelse return error.MissingResolution;
            const wid = try id.parseIdHex(wid_hex);
            const res: wt_mod.Resolution = if (std.mem.eql(u8, res_str, "ours"))
                .ours
            else if (std.mem.eql(u8, res_str, "theirs"))
                .theirs
            else if (std.mem.eql(u8, res_str, "delete"))
                .{ .content = null }
            else if (std.mem.eql(u8, res_str, "content"))
                .{ .content = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "content")) orelse "" }
            else
                return error.InvalidResolution;
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.worktrees.resolveConflict(wid, rel, res);
            try out.appendSlice(self.allocator, "{\"ok\":true}");
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/worktrees/")) {
            const rest = path["/api/worktrees/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const wid = try id.parseIdHex(rest[0..slash]);
                const sub = rest[slash + 1 ..];
                if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "conflicts")) {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const cfs = try self.worktrees.conflicts(wid);
                    defer {
                        for (cfs) |*c| c.deinit(self.allocator);
                        self.allocator.free(cfs);
                    }
                    try out.appendSlice(self.allocator, "{\"conflicts\":[");
                    for (cfs, 0..) |*c, i| {
                        if (i > 0) try out.append(self.allocator, ',');
                        try out.appendSlice(self.allocator, "{\"path\":");
                        try rpc.appendJsonEscaped(self.allocator, out, c.path);
                        try out.print(self.allocator, ",\"kind\":\"{s}\",\"ours\":", .{@tagName(c.kind)});
                        try appendOptTruncated(self.allocator, out, c.ours);
                        try out.appendSlice(self.allocator, ",\"theirs\":");
                        try appendOptTruncated(self.allocator, out, c.theirs);
                        try out.append(self.allocator, '}');
                    }
                    try out.appendSlice(self.allocator, "]}");
                    return;
                }
            } else if (std.mem.eql(u8, method, "DELETE")) {
                const wid = try id.parseIdHex(rest);
                const force = std.mem.eql(u8, queryParam(query, "force") orelse "0", "1");
                const delete_ref = std.mem.eql(u8, queryParam(query, "delete_ref") orelse "0", "1");
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                try self.worktrees.remove(wid, force, delete_ref);
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }
        }

        return error.NotFound;
    }

    fn collectTrackedFilePaths(
        self: *const PlaygroundServer,
        dir_iid: id.InodeId,
        prefix: []const u8,
        view: text_mod.View,
        out: *std.ArrayList([]u8),
    ) !void {
        var entries = try self.workspace.history.tree.listDir(self.allocator, view, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            const inode = self.workspace.history.tree.get(entry.inode_id) orelse {
                self.allocator.free(rel);
                continue;
            };
            if (inode.isDir()) {
                defer self.allocator.free(rel);
                try self.collectTrackedFilePaths(entry.inode_id, rel, view, out);
            } else {
                out.append(self.allocator, rel) catch |err| {
                    self.allocator.free(rel);
                    return err;
                };
            }
        }
    }

    fn appendTurnDiffFiles(self: *PlaygroundServer, msg: *const model.Message, files: *std.ArrayList(u8)) !void {
        const hist = &self.workspace.history;
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }
        const pre_ctx = VersionView{ .dag = &hist.dag, .ver = &msg.pre_version, .allocator = self.allocator };
        const post_ctx = VersionView{ .dag = &hist.dag, .ver = &msg.post_version, .allocator = self.allocator };
        try self.collectTrackedFilePaths(id.InodeId.ROOT, "", text_mod.View.EVERYTHING, &paths);
        try self.collectTrackedFilePaths(id.InodeId.ROOT, "", try pre_ctx.view(), &paths);
        try self.collectTrackedFilePaths(id.InodeId.ROOT, "", try post_ctx.view(), &paths);
        sortDedupePaths(self.allocator, &paths);

        var first = true;
        for (paths.items) |p| {
            const before = try hist.readFileAt(self.allocator, p, &msg.pre_version);
            defer if (before) |b| self.allocator.free(b);
            const after = try hist.readFileAt(self.allocator, p, &msg.post_version);
            defer if (after) |a| self.allocator.free(a);
            const status: []const u8 = if (before == null and after == null)
                continue
            else if (before == null)
                "added"
            else if (after == null)
                "removed"
            else if (std.mem.eql(u8, before.?, after.?))
                continue
            else
                "modified";
            if (!first) try files.append(self.allocator, ',');
            first = false;
            try files.appendSlice(self.allocator, "{\"path\":");
            try rpc.appendJsonEscaped(self.allocator, files, p);
            try files.print(self.allocator, ",\"status\":\"{s}\",\"before\":", .{status});
            try appendOptTruncated(self.allocator, files, before);
            try files.appendSlice(self.allocator, ",\"after\":");
            try appendOptTruncated(self.allocator, files, after);
            try files.append(self.allocator, '}');
        }
    }

    fn spawnWorker(
        self: *PlaygroundServer,
        thread_id: u128,
        mode: @FieldType(WorkerArgs, "mode"),
        prompt: []const u8,
        parent_msg_id: ?u128,
        provider_slug: []const u8,
        mdl: ?[]const u8,
    ) !void {
        const wa = try self.allocator.create(WorkerArgs);
        errdefer self.allocator.destroy(wa);
        const prompt_dup = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(prompt_dup);
        const slug_dup = try self.allocator.dupe(u8, provider_slug);
        errdefer self.allocator.free(slug_dup);
        const model_dup: ?[]u8 = if (mdl) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (model_dup) |m| self.allocator.free(m);
        wa.* = .{
            .srv = self,
            .thread_id = thread_id,
            .mode = mode,
            .prompt = prompt_dup,
            .parent_msg_id = parent_msg_id,
            .provider_slug = slug_dup,
            .model = model_dup,
        };
        _ = self.active_threads.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{}, workerMain, .{wa}) catch |err| {
            _ = self.active_threads.fetchSub(1, .release);
            return err;
        };
        th.detach();
    }

    fn workerMain(wa: *WorkerArgs) void {
        const self = wa.srv;
        defer _ = self.active_threads.fetchSub(1, .release);
        defer {
            self.allocator.free(wa.prompt);
            self.allocator.free(wa.provider_slug);
            if (wa.model) |m| self.allocator.free(m);
            self.allocator.destroy(wa);
        }

        switch (wa.mode) {
            .send_new => {
                self.mu.lockUncancelable(self.io);
                const t = self.engine.journal.threads.get(wa.thread_id) orelse {
                    self.mu.unlock(self.io);
                    return;
                };
                const prov = parseProviderSlug(wa.provider_slug);
                const uid = self.engine.appendUserMessage(wa.thread_id, t.leaf_msg_id, .user, wa.prompt, prov, wa.model, null, null) catch {
                    self.mu.unlock(self.io);
                    return;
                };
                self.mu.unlock(self.io);
                self.emitSessionEvent(wa.thread_id);
                self.executeStreamingTurn(wa.thread_id, uid, wa.prompt, wa.provider_slug, wa.model);
                self.drainPendingFollowUps(wa.thread_id);
            },
            .reply_existing => {
                const pid = wa.parent_msg_id orelse return;
                self.executeStreamingTurn(wa.thread_id, pid, wa.prompt, wa.provider_slug, wa.model);
                self.drainPendingFollowUps(wa.thread_id);
            },
            .drain_queue => {
                self.drainPendingFollowUps(wa.thread_id);
            },
        }
    }

    fn drainPendingFollowUps(self: *PlaygroundServer, thread_id: u128) void {
        while (true) {
            self.mu.lockUncancelable(self.io);
            const pending_ids = self.engine.journal.pendingQueueForThread(self.allocator, thread_id) catch {
                self.mu.unlock(self.io);
                return;
            };
            if (pending_ids.len == 0) {
                self.allocator.free(pending_ids);
                self.mu.unlock(self.io);
                return;
            }
            const next_qid = pending_ids[0];
            self.allocator.free(pending_ids);

            const q_ptr = self.engine.journal.queue_items.getPtr(next_qid) orelse {
                self.mu.unlock(self.io);
                return;
            };
            var disp = q_ptr.clone(self.allocator) catch {
                self.mu.unlock(self.io);
                return;
            };
            disp.status = .dispatching;
            disp.updated_ms = id.nowMs(self.io);
            const prompt_copy = self.allocator.dupe(u8, disp.prompt) catch {
                disp.deinit(self.allocator);
                self.mu.unlock(self.io);
                return;
            };
            const prov_slug = self.allocator.dupe(u8, disp.provider.slug()) catch {
                self.allocator.free(prompt_copy);
                disp.deinit(self.allocator);
                self.mu.unlock(self.io);
                return;
            };
            const mdl_copy: ?[]u8 = if (disp.model) |m| (self.allocator.dupe(u8, m) catch null) else null;
            self.engine.journal.putQueueItem(disp) catch {};
            const leaf = if (self.engine.journal.threads.get(thread_id)) |t| t.leaf_msg_id else null;
            const uid = self.engine.appendUserMessage(thread_id, leaf, .user, prompt_copy, disp.provider, mdl_copy, null, null) catch {
                self.allocator.free(prompt_copy);
                self.allocator.free(prov_slug);
                if (mdl_copy) |m| self.allocator.free(m);
                self.mu.unlock(self.io);
                return;
            };
            self.mu.unlock(self.io);

            defer self.allocator.free(prompt_copy);
            defer self.allocator.free(prov_slug);
            defer if (mdl_copy) |m| self.allocator.free(m);

            self.emitSessionEvent(thread_id);
            self.emitQueueEvent(thread_id);
            self.executeStreamingTurn(thread_id, uid, prompt_copy, prov_slug, mdl_copy);

            self.mu.lockUncancelable(self.io);
            if (self.engine.journal.queue_items.getPtr(next_qid)) |q| {
                if (q.clone(self.allocator)) |done_init| {
                    var done = done_init;
                    done.status = .completed;
                    done.updated_ms = id.nowMs(self.io);
                    self.engine.journal.putQueueItem(done) catch {};
                } else |_| {}
            }
            self.mu.unlock(self.io);
            self.scheduleRelaySync(thread_id);
            self.emitSessionEvent(thread_id);
            self.emitQueueEvent(thread_id);
        }
    }

    fn executeStreamingTurn(
        self: *PlaygroundServer,
        thread_id: u128,
        parent_user_id: u128,
        initial_prompt: []const u8,
        provider_slug: []const u8,
        model_opt: ?[]const u8,
    ) void {
        var cur_parent = parent_user_id;
        var cur_prompt = self.allocator.dupe(u8, initial_prompt) catch return;
        defer self.allocator.free(cur_prompt);
        const prov = parseProviderSlug(provider_slug);

        while (true) {
            var trace: Trace = .{ .started_ms = 0 };
            defer trace.deinit(self.allocator);

            self.mu.lockUncancelable(self.io);
            const turn_ws = self.engine.workspaceForThread(thread_id);
            const root_copy = self.allocator.dupe(u8, turn_ws.root_path) catch {
                self.mu.unlock(self.io);
                return;
            };
            var plan = self.engine.prepareTurnPlan(self.allocator, thread_id, cur_parent, prov, cur_prompt) catch {
                self.allocator.free(root_copy);
                self.mu.unlock(self.io);
                return;
            };
            const pre_ver = turn_ws.history.headsClone() catch {
                plan.deinit(self.allocator);
                self.allocator.free(root_copy);
                self.mu.unlock(self.io);
                return;
            };
            const post_init = pre_ver.clone(self.allocator) catch {
                var pv = pre_ver;
                pv.deinit(self.allocator);
                plan.deinit(self.allocator);
                self.allocator.free(root_copy);
                self.mu.unlock(self.io);
                return;
            };
            const asst_id = id.newUuidV7(self.io);
            const now = id.nowMs(self.io);
            const running_msg = model.Message{
                .msg_id = asst_id,
                .thread_id = thread_id,
                .parent_id = cur_parent,
                .role = .assistant,
                .content = self.allocator.dupe(u8, "") catch "",
                .provider = prov,
                .model = if (model_opt) |m| (self.allocator.dupe(u8, m) catch null) else null,
                .native_session = if (plan.resume_id) |rs| (self.allocator.dupe(u8, rs) catch null) else null,
                .native_turn = null,
                .pre_version = pre_ver,
                .post_version = post_init,
                .git_branch = null,
                .git_commit = null,
                .worktree_id = turn_ws.history.history_id,
                .status = .running,
                .steer_of = null,
                .switched_from = null,
                .created_ms = now,
                .updated_ms = now,
            };
            self.engine.journal.putMessage(running_msg, false) catch {};
            self.engine.journal.setBranchChoice(thread_id, cur_parent, asst_id) catch {};
            if (self.engine.journal.threads.getPtr(thread_id)) |t| {
                if (t.clone(self.allocator)) |u_init| {
                    var u = u_init;
                    u.status = .running;
                    u.updated_ms = now;
                    self.engine.journal.putThread(u) catch {};
                } else |_| {}
            }
            var turn_scope_id: ?u128 = turn_ws.beginScope(.turn, turn_ws.disk_actor, "turn") catch null;
            trace.started_ms = now;
            self.registerTrace(asst_id, &trace);
            self.mu.unlock(self.io);
            self.scheduleRelaySync(thread_id);
            defer self.allocator.free(root_copy);
            defer plan.deinit(self.allocator);
            defer self.unregisterTrace(asst_id);
            defer if (turn_scope_id) |sid| {
                self.mu.lockUncancelable(self.io);
                const ws_end = self.engine.workspaceForThread(thread_id);
                ws_end.endScope(sid) catch {};
                self.mu.unlock(self.io);
            };

            const ctx = TurnCtx{
                .thread_id = thread_id,
                .msg_id = asst_id,
                .provider_slug = provider_slug,
                .model = model_opt orelse "",
            };
            self.emitSessionEvent(thread_id);
            self.emitDelta(&ctx, "turn_started", .{ .parent_id = cur_parent });

            const is_mock_fallback = std.mem.eql(u8, provider_slug, "mock-fallback") or
                (prov == .mock and model_opt != null and std.mem.eql(u8, model_opt.?, "sim-fallback-v1"));

            var acc_text: std.ArrayList(u8) = .empty;
            defer acc_text.deinit(self.allocator);
            var native_session: ?[]u8 = if (plan.resume_id) |rs| (self.allocator.dupe(u8, rs) catch null) else null;
            defer if (native_session) |ns| self.allocator.free(ns);
            var native_turn: ?[]u8 = null;
            defer if (native_turn) |nt| self.allocator.free(nt);
            var final_status: model.MessageStatus = .completed;
            var fallback_prompt: ?[]u8 = null;
            defer if (fallback_prompt) |fp| self.allocator.free(fp);
            var fallback_qid: ?u128 = null;
            var user_interrupted = std.atomic.Value(bool).init(false);

            const caps = registry.capabilities(prov);
            const allow_warm = prov != .mock and caps.persistent;
            var use_resume = prov != .mock and plan.resume_id != null;
            var try_warm = allow_warm and use_resume and plan.fork_at == null;
            var attempt: usize = 0;
            while (attempt < 3) : (attempt += 1) {
                var from_warm = false;
                var handle: iface.RunHandle = undefined;
                if (try_warm) {
                    try_warm = false;
                    if (self.engine.warm_pool.take(prov, plan.resume_id.?, model_opt, root_copy)) |warm_h| {
                        handle = warm_h;
                        from_warm = true;
                    }
                }
                if (!from_warm) {
                    handle = (if (prov == .mock)
                        InteractiveMock.start(self.allocator, self.io, !is_mock_fallback, root_copy)
                    else
                        registry.start(self.allocator, self.io, prov, .{
                            .cwd = root_copy,
                            .model = model_opt,
                            .resume_id = if (use_resume) plan.resume_id else null,
                            .fork_at = if (use_resume) plan.fork_at else null,
                            .access = .full,
                        })) catch |err| {
                        if (use_resume and plan.handoff_prompt != null) {
                            use_resume = false;
                            if (native_session) |old| {
                                self.allocator.free(old);
                                native_session = null;
                            }
                            continue;
                        }
                        self.finishTurnError(&ctx, &trace, @errorName(err));
                        return;
                    };
                }
                var handle_parked = false;
                defer if (!handle_parked) handle.close();

                self.registerActiveTurn(thread_id, &handle, &user_interrupted);
                defer self.unregisterActiveTurn(thread_id);

                const send_prompt = if (prov == .mock)
                    cur_prompt
                else if (use_resume)
                    plan.prompt
                else
                    (plan.handoff_prompt orelse plan.prompt);

                handle.send(send_prompt) catch |err| {
                    if (from_warm) continue;
                    if (use_resume and plan.handoff_prompt != null) {
                        use_resume = false;
                        if (native_session) |old| {
                            self.allocator.free(old);
                            native_session = null;
                        }
                        continue;
                    }
                    self.finishTurnError(&ctx, &trace, @errorName(err));
                    return;
                };

                var saw_turn_ended = false;
                var saw_tools = false;
                var saw_delta_in_block = false;
                final_status = .completed;

                while (handle.next() catch null) |raw_ev| {
                    var ev = raw_ev;
                    defer ev.deinit(self.allocator);
                    const block = self.recordTraceEvent(&trace, &ev);

                    if (ev.native_message) |nm| {
                        if (native_turn) |old| self.allocator.free(old);
                        native_turn = self.allocator.dupe(u8, nm) catch null;
                    }

                    switch (ev.kind) {
                        .session_started => |s| {
                            if (native_session) |old| self.allocator.free(old);
                            native_session = self.allocator.dupe(u8, s.native_id) catch null;
                        },
                        .turn_started => |ts| {
                            if (ts.native_turn_id) |nt| {
                                if (native_turn) |old| self.allocator.free(old);
                                native_turn = self.allocator.dupe(u8, nt) catch null;
                            }
                        },
                        .reasoning_delta => |d| self.emitDelta(&ctx, "reasoning_delta", .{ .text = d.text, .block = block }),
                        .reasoning => |r| if (block != null) self.emitDelta(&ctx, "reasoning_delta", .{ .text = r.text, .block = block }),
                        .text_delta => |d| {
                            saw_delta_in_block = true;
                            acc_text.appendSlice(self.allocator, d.text) catch {};
                            self.emitDelta(&ctx, "text_delta", .{ .text = d.text });
                        },
                        .text => |t| {
                            if (!saw_delta_in_block and t.text.len > 0) {
                                if (acc_text.items.len > 0 and acc_text.items[acc_text.items.len - 1] != '\n') {
                                    acc_text.appendSlice(self.allocator, "\n\n") catch {};
                                    self.emitDelta(&ctx, "text_delta", .{ .text = "\n\n" });
                                }
                                acc_text.appendSlice(self.allocator, t.text) catch {};
                                self.emitDelta(&ctx, "text_delta", .{ .text = t.text });
                            }
                            saw_delta_in_block = false;
                        },
                        .tool_started => |ts| {
                            saw_tools = true;
                            saw_delta_in_block = false;
                            self.emitDelta(&ctx, "tool_started", .{ .tool_id = ts.id, .name = ts.name, .input = ts.input_json });
                            self.mu.lockUncancelable(self.io);
                            self.engine.journal.putToolCall(asst_id, ts.id, ts.name, ts.input_json, "", false) catch {};
                            self.mu.unlock(self.io);
                        },
                        .tool_finished => |tf| {
                            saw_tools = true;
                            saw_delta_in_block = false;
                            self.emitDelta(&ctx, "tool_finished", .{ .tool_id = tf.id, .text = tf.output, .is_error = tf.is_error });
                            self.mu.lockUncancelable(self.io);
                            self.engine.journal.putToolCall(asst_id, tf.id, "", "", tf.output, tf.is_error) catch {};
                            self.active_source = "agent";
                            self.active_msg_id = asst_id;
                            const ws_tool = self.engine.workspaceForThread(thread_id);
                            _ = ws_tool.drainWatched("agent") catch null;
                            self.active_source = null;
                            self.active_msg_id = null;
                            self.mu.unlock(self.io);
                        },
                        .usage => |u| self.emitDelta(&ctx, "usage", .{ .usage = .{ .input_tokens = u.input_tokens, .output_tokens = u.output_tokens } }),
                        .turn_ended => |te| {
                            saw_turn_ended = true;
                            if (!te.ok) {
                                final_status = if (fallback_prompt != null or user_interrupted.load(.acquire)) .interrupted else .failed;
                            }
                            break;
                        },
                        else => {},
                    }

                    if (fallback_prompt == null and !user_interrupted.load(.acquire)) {
                        var pending_steer_id: ?u128 = null;
                        var steer_text: ?[]u8 = null;

                        self.mu.lockUncancelable(self.io);
                        for (self.engine.journal.queue_order.items) |qid| {
                            const q = self.engine.journal.queue_items.get(qid) orelse continue;
                            if (q.thread_id == thread_id and q.kind == .steer and q.status == .pending) {
                                pending_steer_id = qid;
                                steer_text = self.allocator.dupe(u8, q.prompt) catch null;
                                break;
                            }
                        }
                        self.mu.unlock(self.io);

                        if (pending_steer_id) |sqid| {
                            if (steer_text) |sp| {
                                const outcome = handle.steer(sp, native_turn) catch iface.SteerOutcome.requires_interrupt_fallback;
                                switch (outcome) {
                                    .injected_native => {
                                        defer self.allocator.free(sp);
                                        self.setQueueStatus(sqid, .injected);
                                        self.recordTraceSteer(&trace, .native, sp);
                                        self.emitDelta(&ctx, "steer_injected", .{ .text = sp });
                                        self.emitQueueEvent(thread_id);
                                    },
                                    .requires_interrupt_fallback => {
                                        self.setQueueStatus(sqid, .dispatching);
                                        fallback_prompt = sp;
                                        fallback_qid = sqid;
                                        final_status = .interrupted;
                                        handle.interrupt();
                                        self.recordTraceSteer(&trace, .fallback, sp);
                                        self.emitDelta(&ctx, "steer_fallback", .{ .text = sp });
                                        self.emitQueueEvent(thread_id);
                                    },
                                }
                            }
                        }
                    }
                }

                if (user_interrupted.load(.acquire)) {
                    final_status = .interrupted;
                }

                if (!user_interrupted.load(.acquire) and from_warm and acc_text.items.len == 0 and !saw_tools and fallback_prompt == null and (final_status == .failed or !saw_turn_ended)) {
                    continue;
                }

                if (!user_interrupted.load(.acquire) and use_resume and plan.handoff_prompt != null and acc_text.items.len == 0 and !saw_tools and fallback_prompt == null and (final_status == .failed or !saw_turn_ended)) {
                    use_resume = false;
                    if (native_session) |old| {
                        self.allocator.free(old);
                        native_session = null;
                    }
                    if (native_turn) |old| {
                        self.allocator.free(old);
                        native_turn = null;
                    }
                    continue;
                }

                if (allow_warm and saw_turn_ended and final_status == .completed and fallback_prompt == null and !user_interrupted.load(.acquire)) {
                    if (native_session) |ns| {
                        if (ns.len > 0) {
                            handle_parked = true;
                            self.engine.warm_pool.park(prov, ns, model_opt, root_copy, handle);
                        }
                    }
                }
                break;
            }

            var vhead = vcs.head(self.allocator, self.io, root_copy) catch vcs.VcsHead{};
            defer vhead.deinit(self.allocator);

            self.mu.lockUncancelable(self.io);
            const ws_done = self.engine.workspaceForThread(thread_id);
            self.active_source = "agent";
            self.active_msg_id = asst_id;
            _ = ws_done.drainWatched("agent") catch null;
            self.active_source = null;
            self.active_msg_id = null;
            if (turn_scope_id) |sid| {
                ws_done.endScope(sid) catch {};
                turn_scope_id = null;
            }
            const post_ver = ws_done.history.headsClone() catch version_mod.Version.ROOT;
            const end_ms = id.nowMs(self.io);
            self.finalizeTrace(asst_id, &trace, end_ms, null);
            if (self.engine.journal.messages.getPtr(asst_id)) |existing| {
                if (existing.clone(self.allocator)) |s_init| {
                    var sealed = s_init;
                    self.allocator.free(sealed.content);
                    sealed.content = self.allocator.dupe(u8, acc_text.items) catch "";
                    if (sealed.native_session) |old| self.allocator.free(old);
                    sealed.native_session = if (native_session) |ns| (self.allocator.dupe(u8, ns) catch null) else null;
                    if (sealed.native_turn) |old| self.allocator.free(old);
                    sealed.native_turn = if (native_turn) |nt| (self.allocator.dupe(u8, nt) catch null) else null;
                    if (sealed.git_branch) |old| self.allocator.free(old);
                    sealed.git_branch = if (vhead.ref_name) |rn| (self.allocator.dupe(u8, rn) catch null) else null;
                    if (sealed.git_commit) |old| self.allocator.free(old);
                    sealed.git_commit = if (vhead.rev) |rv| (self.allocator.dupe(u8, rv) catch null) else null;
                    sealed.post_version.deinit(self.allocator);
                    sealed.post_version = post_ver;
                    sealed.status = final_status;
                    sealed.updated_ms = end_ms;
                    self.engine.journal.putMessage(sealed, true) catch {};
                } else |_| {}
            }
            if (self.engine.journal.threads.getPtr(thread_id)) |t| {
                if (t.clone(self.allocator)) |u_init| {
                    var u = u_init;
                    u.leaf_msg_id = asst_id;
                    u.head_page = self.engine.sealThreadPages(thread_id, asst_id) catch u.head_page;
                    u.queued_count = self.engine.journal.countPendingQueue(thread_id);
                    u.status = if (fallback_prompt != null) .steering else if (u.queued_count > 0) .queued else .idle;
                    var count_m: u32 = 0;
                    var c_id: ?u128 = asst_id;
                    while (c_id) |cid| {
                        const mm = self.engine.journal.messages.get(cid) orelse break;
                        count_m += 1;
                        c_id = mm.parent_id;
                    }
                    u.message_count = count_m;
                    u.updated_ms = end_ms;
                    self.engine.journal.putThread(u) catch {};
                } else |_| {}
            }
            self.mu.unlock(self.io);
            self.scheduleRelaySync(thread_id);

            self.emitTurnCompletedEvent(thread_id);

            if (fallback_prompt) |fp| {
                self.mu.lockUncancelable(self.io);
                const smid = self.engine.appendUserMessage(thread_id, asst_id, .steer, fp, prov, model_opt, asst_id, null) catch {
                    self.mu.unlock(self.io);
                    return;
                };
                self.mu.unlock(self.io);
                if (fallback_qid) |sqid| {
                    self.setQueueStatus(sqid, .completed);
                    self.emitQueueEvent(thread_id);
                }
                self.allocator.free(cur_prompt);
                cur_prompt = self.allocator.dupe(u8, fp) catch return;
                cur_parent = smid;
                continue;
            }
            break;
        }
    }

    fn setQueueStatus(self: *PlaygroundServer, item_id: u128, status: model.QueueStatus) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const q = self.engine.journal.queue_items.getPtr(item_id) orelse return;
        var u = q.clone(self.allocator) catch return;
        u.status = status;
        u.updated_ms = id.nowMs(self.io);
        self.engine.journal.putQueueItem(u) catch {};
    }

    fn finishTurnError(self: *PlaygroundServer, ctx: *const TurnCtx, trace: *Trace, err_name: []const u8) void {
        self.mu.lockUncancelable(self.io);
        const now = id.nowMs(self.io);
        self.finalizeTrace(ctx.msg_id, trace, now, err_name);
        if (self.engine.journal.messages.getPtr(ctx.msg_id)) |existing| {
            if (existing.clone(self.allocator)) |s_init| {
                var sealed = s_init;
                self.allocator.free(sealed.content);
                sealed.content = std.fmt.allocPrint(self.allocator, "Provider error: {s}", .{err_name}) catch "";
                sealed.status = .failed;
                sealed.updated_ms = now;
                self.engine.journal.putMessage(sealed, true) catch {};
            } else |_| {}
        }
        if (self.engine.journal.threads.getPtr(ctx.thread_id)) |t| {
            if (t.clone(self.allocator)) |u_init| {
                var u = u_init;
                u.leaf_msg_id = ctx.msg_id;
                u.status = .failed;
                u.updated_ms = now;
                self.engine.journal.putThread(u) catch {};
            } else |_| {}
        }
        self.mu.unlock(self.io);
        self.scheduleRelaySync(ctx.thread_id);
        self.emitTurnCompletedEvent(ctx.thread_id);
    }

    fn appendPageJsonLocked(
        self: *PlaygroundServer,
        tid: u128,
        before_id: ?u128,
        limit: usize,
        out: *std.ArrayList(u8),
    ) !void {
        const t0 = nowUs(self.io);
        var page = try self.engine.getPage(self.allocator, tid, before_id, limit);
        defer page.deinit(self.allocator);
        const elapsed = nowUs(self.io) -| t0;

        try out.appendSlice(self.allocator, "{\"messages\":[");
        for (page.messages, 0..) |m, i| {
            if (i > 0) try out.append(self.allocator, ',');
            const sibs = try self.siblingsIncluding(m.msg_id);
            defer self.allocator.free(sibs);
            const trace_json = self.traceJsonFor(m.msg_id);
            defer if (trace_json) |tj| self.allocator.free(tj);
            try appendMessageJson(self.allocator, out, &m, sibs, trace_json);
        }
        try out.print(self.allocator, "],\"has_more\":{},\"elapsed_us\":{d},\"next_before\":", .{ page.has_more, elapsed });
        if (page.next_before) |nb| {
            var nhex: [32]u8 = undefined;
            _ = id.formatIdHex(nb, &nhex);
            try out.print(self.allocator, "\"{s}\"", .{nhex});
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.appendSlice(self.allocator, ",\"head_page\":");
        if (page.head_page) |hp| {
            var phex: [64]u8 = undefined;
            _ = id.formatHashHex(hp, &phex);
            try out.print(self.allocator, "\"{s}\"", .{phex});
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.append(self.allocator, '}');
    }

    fn appendBranchPreviewJsonLocked(
        self: *PlaygroundServer,
        tid: u128,
        branch_mid: u128,
        from_mid: ?u128,
        limit: usize,
        out: *std.ArrayList(u8),
    ) !void {
        const t0 = nowUs(self.io);
        _ = self.engine.journal.threads.get(tid) orelse return error.ThreadNotFound;
        const target = self.engine.journal.messages.get(branch_mid) orelse return error.MessageNotFound;
        if (target.thread_id != tid) return error.MessageWrongThread;

        const leaf = self.engine.journal.resolveBranchLeaf(tid, branch_mid);
        var effective_limit: usize = if (limit == 0) self.engine.page_size else limit;
        {
            var cur: ?u128 = leaf;
            var count: usize = 0;
            while (cur) |cid| : (count += 1) {
                if (count >= 1000) break;
                if (cid == branch_mid) {
                    effective_limit = @max(effective_limit, count + 1);
                    if (from_mid == null) break;
                }
                if (from_mid) |fmid| {
                    if (cid == fmid) {
                        effective_limit = @max(effective_limit, count + 1);
                        break;
                    }
                }
                const m = self.engine.journal.messages.get(cid) orelse break;
                cur = m.parent_id;
            }
        }

        var rev: std.ArrayList(u128) = .empty;
        defer rev.deinit(self.allocator);
        var cur: ?u128 = leaf;
        var has_more = false;
        while (cur) |cid| {
            if (rev.items.len >= effective_limit) {
                has_more = true;
                break;
            }
            const m = self.engine.journal.messages.get(cid) orelse break;
            try rev.append(self.allocator, cid);
            cur = m.parent_id;
        }
        const elapsed = nowUs(self.io) -| t0;

        try out.appendSlice(self.allocator, "{\"messages\":[");
        for (0..rev.items.len) |i| {
            if (i > 0) try out.append(self.allocator, ',');
            const cid = rev.items[rev.items.len - 1 - i];
            const m = self.engine.journal.messages.getPtr(cid).?;
            const sibs = try self.siblingsIncluding(m.msg_id);
            defer self.allocator.free(sibs);
            const trace_json = self.traceJsonFor(m.msg_id);
            defer if (trace_json) |tj| self.allocator.free(tj);
            try appendMessageJson(self.allocator, out, m, sibs, trace_json);
        }
        try out.print(self.allocator, "],\"has_more\":{},\"elapsed_us\":{d},\"next_before\":", .{ has_more, elapsed });
        if (has_more and rev.items.len > 0) {
            var nhex: [32]u8 = undefined;
            _ = id.formatIdHex(rev.items[rev.items.len - 1], &nhex);
            try out.print(self.allocator, "\"{s}\"", .{nhex});
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.appendSlice(self.allocator, ",\"head_page\":null}");
    }

    fn emitSessionEventWithHead(self: *PlaygroundServer, thread_id: u128, head_page: ?id.PageId) void {
        var thex: [32]u8 = undefined;
        _ = id.formatIdHex(thread_id, &thex);
        var buf: [256]u8 = undefined;
        const json = if (head_page) |hp| blk: {
            var phex: [64]u8 = undefined;
            _ = id.formatHashHex(hp, &phex);
            break :blk std.fmt.bufPrint(&buf, "{{\"type\":\"session_updated\",\"thread_id\":\"{s}\",\"head_page\":\"{s}\"}}", .{ thex, phex }) catch return;
        } else std.fmt.bufPrint(&buf, "{{\"type\":\"session_updated\",\"thread_id\":\"{s}\",\"head_page\":null}}", .{thex}) catch return;
        self.broadcastSse(json);
    }

    fn emitSessionEvent(self: *PlaygroundServer, thread_id: u128) void {
        const head_page: ?id.PageId = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            break :blk if (self.engine.journal.threads.get(thread_id)) |t| t.head_page else null;
        };
        self.emitSessionEventWithHead(thread_id, head_page);
    }

    fn emitTurnCompletedEvent(self: *PlaygroundServer, thread_id: u128) void {
        var thex: [32]u8 = undefined;
        _ = id.formatIdHex(thread_id, &thex);
        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"turn_completed\",\"thread_id\":\"{s}\"}}", .{thex}) catch return;
        self.broadcastSse(json);
    }

    fn emitDelta(self: *PlaygroundServer, ctx: *const TurnCtx, kind: []const u8, extra: DeltaExtra) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        appendDeltaJson(self.allocator, &buf, ctx, kind, id.nowMs(self.io), extra) catch return;
        self.broadcastSse(buf.items);
    }
};

fn appendDeltaJson(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    ctx: *const TurnCtx,
    kind: []const u8,
    ts_ms: u64,
    extra: DeltaExtra,
) !void {
    var thex: [32]u8 = undefined;
    _ = id.formatIdHex(ctx.thread_id, &thex);
    var mhex: [32]u8 = undefined;
    _ = id.formatIdHex(ctx.msg_id, &mhex);
    try buf.print(allocator, "{{\"type\":\"turn_delta\",\"thread_id\":\"{s}\",\"msg_id\":\"{s}\",\"provider\":", .{ thex, mhex });
    try rpc.appendJsonEscaped(allocator, buf, ctx.provider_slug);
    try buf.appendSlice(allocator, ",\"model\":");
    try rpc.appendJsonEscaped(allocator, buf, ctx.model);
    try buf.print(allocator, ",\"kind\":\"{s}\",\"ts_ms\":{d}", .{ kind, ts_ms });
    if (extra.parent_id) |pid| {
        var phex: [32]u8 = undefined;
        _ = id.formatIdHex(pid, &phex);
        try buf.print(allocator, ",\"parent_id\":\"{s}\"", .{phex});
    }
    if (extra.tool_id) |v| {
        try buf.appendSlice(allocator, ",\"tool_id\":");
        try rpc.appendJsonEscaped(allocator, buf, v);
    }
    if (extra.name) |v| {
        try buf.appendSlice(allocator, ",\"name\":");
        try rpc.appendJsonEscaped(allocator, buf, v);
    }
    if (extra.input) |v| {
        try buf.appendSlice(allocator, ",\"input\":");
        try rpc.appendJsonEscaped(allocator, buf, v);
    }
    if (extra.text) |v| {
        try buf.appendSlice(allocator, ",\"text\":");
        try rpc.appendJsonEscaped(allocator, buf, v);
    }
    if (extra.block) |b| try buf.print(allocator, ",\"block\":{d}", .{b});
    if (extra.is_error) |e| try buf.print(allocator, ",\"is_error\":{}", .{e});
    if (extra.usage) |u| try buf.print(allocator, ",\"input_tokens\":{d},\"output_tokens\":{d}", .{ u.input_tokens, u.output_tokens });
    try buf.append(allocator, '}');
}

fn parseProviderSlug(s: []const u8) iface.ProviderId {
    if (std.mem.eql(u8, s, "mock-fallback")) return .mock;
    return iface.ProviderId.fromSlug(s) orelse .mock;
}

fn appendCatalogJson(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    pid: iface.ProviderId,
    entry: *const CachedCatalog,
) !void {
    try out.print(
        allocator,
        "{{\"provider\":\"{s}\",\"available\":true,\"ready\":{},\"elapsed_us\":{d},\"note\":",
        .{ pid.slug(), entry.ready, entry.elapsed_us },
    );
    if (entry.catalog.note) |n| {
        try rpc.appendJsonEscaped(allocator, out, n);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"models\":[");
    for (entry.catalog.models, 0..) |m, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"id\":");
        try rpc.appendJsonEscaped(allocator, out, m.id);
        try out.appendSlice(allocator, ",\"name\":");
        try rpc.appendJsonEscaped(allocator, out, m.name);
        try out.print(allocator, ",\"is_default\":{}}}", .{m.is_default});
    }
    try out.appendSlice(allocator, "]}");
}

fn appendSessionSummaryJson(allocator: Allocator, out: *std.ArrayList(u8), s: *const model.SessionSummary, t_model: ?[]const u8) !void {
    var thex: [32]u8 = undefined;
    _ = id.formatIdHex(s.thread_id, &thex);
    try out.print(allocator, "{{\"thread_id\":\"{s}\"", .{thex});
    try out.appendSlice(allocator, ",\"title\":");
    try rpc.appendJsonEscaped(allocator, out, s.title);
    try out.print(
        allocator,
        ",\"provider\":\"{s}\",\"model\":",
        .{s.provider.slug()},
    );
    if (t_model) |tm| {
        try rpc.appendJsonEscaped(allocator, out, tm);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.print(
        allocator,
        ",\"status\":\"{s}\",\"queued_count\":{d},\"message_count\":{d},\"updated_ms\":{d},\"head_page\":",
        .{ @tagName(s.status), s.queued_count, s.message_count, s.updated_ms },
    );
    if (s.head_page) |hp| {
        var phex: [64]u8 = undefined;
        _ = id.formatHashHex(hp, &phex);
        try out.print(allocator, "\"{s}\"", .{phex});
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.append(allocator, '}');
}

fn appendMessageJson(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    m: *const model.Message,
    siblings: []const u128,
    trace_json: ?[]const u8,
) !void {
    var mhex: [32]u8 = undefined;
    _ = id.formatIdHex(m.msg_id, &mhex);
    try out.print(
        allocator,
        "{{\"msg_id\":\"{s}\",\"role\":\"{s}\",\"status\":\"{s}\",\"provider\":\"{s}\",\"model\":",
        .{ mhex, @tagName(m.role), @tagName(m.status), m.provider.slug() },
    );
    if (m.model) |mm| {
        try rpc.appendJsonEscaped(allocator, out, mm);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"parent_id\":");
    try appendOptIdHex(allocator, out, m.parent_id);
    try out.appendSlice(allocator, ",\"steer_of\":");
    try appendOptIdHex(allocator, out, m.steer_of);
    try out.appendSlice(allocator, ",\"switched_from\":");
    try appendOptIdHex(allocator, out, m.switched_from);
    try out.print(allocator, ",\"created_ms\":{d},\"updated_ms\":{d},\"content\":", .{ m.created_ms, m.updated_ms });
    try rpc.appendJsonEscaped(allocator, out, m.content);
    try out.appendSlice(allocator, ",\"siblings\":[");
    for (siblings, 0..) |sid, i| {
        if (i > 0) try out.append(allocator, ',');
        var shex: [32]u8 = undefined;
        _ = id.formatIdHex(sid, &shex);
        try out.print(allocator, "\"{s}\"", .{shex});
    }
    const sibling_index = std.mem.indexOfScalar(u128, siblings, m.msg_id) orelse 0;
    try out.print(allocator, "],\"sibling_index\":{d},\"trace\":", .{sibling_index});
    try out.appendSlice(allocator, trace_json orelse "null");
    try out.append(allocator, '}');
}

fn appendOptIdHex(allocator: Allocator, out: *std.ArrayList(u8), v: ?u128) !void {
    if (v) |x| {
        var hex: [32]u8 = undefined;
        _ = id.formatIdHex(x, &hex);
        try out.print(allocator, "\"{s}\"", .{hex});
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn appendOptU64(allocator: Allocator, out: *std.ArrayList(u8), v: ?u64) !void {
    if (v) |x| {
        try out.print(allocator, "{d}", .{x});
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn appendOptTruncated(allocator: Allocator, out: *std.ArrayList(u8), v: ?[]const u8) !void {
    if (v) |s| {
        try rpc.appendJsonEscaped(allocator, out, utf8Prefix(s, DIFF_TEXT_CAP));
    } else {
        try out.appendSlice(allocator, "null");
    }
}

fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn sortDedupePaths(allocator: Allocator, paths: *std.ArrayList([]u8)) void {
    std.mem.sort([]u8, paths.items, {}, lessPath);
    var kept: usize = 0;
    for (paths.items) |p| {
        if (kept > 0 and std.mem.eql(u8, paths.items[kept - 1], p)) {
            allocator.free(p);
            continue;
        }
        paths.items[kept] = p;
        kept += 1;
    }
    paths.shrinkRetainingCapacity(kept);
}

fn traceFileName(msg_id: u128, buf: *[37]u8) []const u8 {
    _ = id.formatIdHex(msg_id, buf[0..32]);
    @memcpy(buf[32..37], ".json");
    return buf[0..37];
}

fn mimeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "application/javascript; charset=utf-8" },
        .{ ".mjs", "application/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".woff2", "font/woff2" },
        .{ ".woff", "font/woff" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".ico", "image/x-icon" },
        .{ ".json", "application/json" },
        .{ ".webp", "image/webp" },
        .{ ".txt", "text/plain" },
        .{ ".map", "application/json" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

fn readEnvVarAlloc(allocator: Allocator, io: Io, name: []const u8) ?[]u8 {
    const f = Io.Dir.cwd().openFile(io, "/proc/self/environ", .{}) catch return null;
    defer f.close(io);
    const buf = allocator.alloc(u8, 1024 * 1024) catch return null;
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |entry| {
        if (entry.len > name.len and std.mem.startsWith(u8, entry, name) and entry[name.len] == '=') {
            return allocator.dupe(u8, entry[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

fn canonicalDir(allocator: Allocator, io: Io, path: []const u8) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return allocator.dupe(u8, path) catch null;
    return allocator.dupe(u8, buf[0..n]) catch null;
}

fn distCandidate(allocator: Allocator, io: Io, dir_path: []const u8) ?[]u8 {
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.html", .{dir_path}) catch return null;
    defer allocator.free(index_path);
    Io.Dir.cwd().access(io, index_path, .{}) catch return null;
    return canonicalDir(allocator, io, dir_path);
}

fn resolveUiDist(allocator: Allocator, io: Io) ?[]u8 {
    if (readEnvVarAlloc(allocator, io, "ONDB_PLAYGROUND_DIST")) |env_dist| {
        defer allocator.free(env_dist);
        if (env_dist.len > 0) return canonicalDir(allocator, io, env_dist);
    }
    if (distCandidate(allocator, io, "playground/ui/dist")) |d| return d;
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(exe_dir);
    const rel = std.fmt.allocPrint(allocator, "{s}/../../playground/ui/dist", .{exe_dir}) catch return null;
    defer allocator.free(rel);
    return distCandidate(allocator, io, rel);
}

fn shouldKeepAlive(headers: []const u8) bool {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    const req_line = it.next() orelse return false;
    const is_http11 = std.mem.endsWith(u8, req_line, "HTTP/1.1");
    while (it.next()) |line| {
        if (line.len > 11 and std.ascii.eqlIgnoreCase(line[0..11], "connection:")) {
            var toks = std.mem.splitScalar(u8, line[11..], ',');
            while (toks.next()) |raw| {
                const tok = std.mem.trim(u8, raw, " \t");
                if (std.ascii.eqlIgnoreCase(tok, "close")) return false;
                if (std.ascii.eqlIgnoreCase(tok, "keep-alive")) return true;
            }
        }
    }
    return is_http11;
}

fn appendWorktreeJson(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    info: *const wt_mod.WorktreeInfo,
    is_primary: bool,
    conflict_count: usize,
) !void {
    var whex: [32]u8 = undefined;
    _ = id.formatIdHex(info.id, &whex);
    var hhex: [32]u8 = undefined;
    _ = id.formatIdHex(info.history_id, &hhex);
    try out.print(allocator, "{{\"id\":\"{s}\",\"title\":", .{whex});
    try rpc.appendJsonEscaped(allocator, out, info.title);
    try out.appendSlice(allocator, ",\"path\":");
    try rpc.appendJsonEscaped(allocator, out, info.path);
    try out.print(allocator, ",\"vcs_kind\":\"{s}\",\"repo_root\":", .{@tagName(info.vcs_kind)});
    if (info.repo_root) |rr| {
        try rpc.appendJsonEscaped(allocator, out, rr);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, ",\"ref_name\":");
    if (info.ref_name) |rn| {
        try rpc.appendJsonEscaped(allocator, out, rn);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.print(
        allocator,
        ",\"history_id\":\"{s}\",\"created\":{},\"is_primary\":{},\"created_ms\":{d},\"source_id\":",
        .{ hhex, info.created, is_primary, info.created_ms },
    );
    if (info.forked_from) |*ff| {
        try appendOptIdHex(allocator, out, ff.source_id);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.print(allocator, ",\"conflicts\":{d}}}", .{conflict_count});
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
    }
    return null;
}

fn urlDecode(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, s[i]);
                continue;
            };
            try out.append(allocator, v);
            i += 2;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn sendHttp(fd: posix.fd_t, status: []const u8, content_type: []const u8, body: []const u8, keep_alive: bool) bool {
    return sendHttpFull(fd, status, content_type, body, "no-store", false, keep_alive);
}

fn sendHttpFull(fd: posix.fd_t, status: []const u8, content_type: []const u8, body: []const u8, cache_control: []const u8, head_only: bool, keep_alive: bool) bool {
    var hdr_buf: [512]u8 = undefined;
    const conn_hdr = if (keep_alive) "keep-alive\r\nKeep-Alive: timeout=15" else "close";
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: {s}\r\nConnection: {s}\r\n\r\n",
        .{ status, content_type, body.len, cache_control, conn_hdr },
    ) catch return false;
    if (head_only or body.len == 0) {
        return writeAllRaw(fd, hdr);
    }
    if (hdr.len + body.len <= 16384) {
        var stack_buf: [16384]u8 = undefined;
        @memcpy(stack_buf[0..hdr.len], hdr);
        @memcpy(stack_buf[hdr.len .. hdr.len + body.len], body);
        return writeAllRaw(fd, stack_buf[0 .. hdr.len + body.len]);
    }
    if (!writeAllRaw(fd, hdr)) return false;
    return writeAllRaw(fd, body);
}

fn writeAllRaw(fd: posix.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, 5000);
            if (linux.errno(prc) != .SUCCESS or prc == 0) return false;
            if ((pfd[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL)) != 0) return false;
            continue;
        }
        if (e != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

fn writeAllNonBlocking(fd: posix.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

fn jsonU64(val: ?std.json.Value) u64 {
    const v = val orelse return 0;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else 0,
        .float => |fl| if (fl >= 0) @intFromFloat(fl) else 0,
        else => 0,
    };
}
