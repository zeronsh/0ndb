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
const pool_mod = @import("../fs/pool.zig");
const space_mod = @import("../space/space.zig");
const space_mgr_mod = @import("../space/manager.zig");
const project_mod = @import("../project/project.zig");
const timeline_mod = @import("../fs/timeline.zig");
const keyring_mod = @import("../sync/keyring.zig");
const lease_mod = @import("../sync/lease.zig");
const thread_model = @import("../thread/model.zig");
const thread_store_mod = @import("../thread/store.zig");
const thread_rt_mod = @import("../thread/runtime.zig");

pub const MAX_CONNS: usize = 128;
pub const MAX_WORKERS: usize = 32;
pub const MAX_SSE_CLIENTS: usize = 64;
pub const MAX_SSE_PENDING_BYTES: usize = 256 * 1024;
pub const SSE_KEEPALIVE_MS: u64 = 15_000;
pub const REQUEST_READ_TIMEOUT_MS: u64 = 15_000;
pub const KEEPALIVE_IDLE_MS: u64 = 15_000;
pub const MAX_HEADER_BYTES: usize = 64 * 1024;
pub const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_CHUNK_LINE_BYTES: usize = 4096;
pub const MAX_TRAILER_BYTES: usize = 64 * 1024;
pub const MAX_MSG_CHAIN_DEPTH: usize = 100_000;
const CONFLICTS_MAGIC: u32 = 0x43464C31;

pub const ServerConfig = struct {
    default_access: iface.AccessMode = .accept_edits,
    prewarm_models: bool = true,
    v2_root: ?[]const u8 = null,
};

pub fn parseAccessMode(s: []const u8) ?iface.AccessMode {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "read_only") or std.ascii.eqlIgnoreCase(trimmed, "plan")) return .plan;
    if (std.ascii.eqlIgnoreCase(trimmed, "accept_edits")) return .accept_edits;
    if (std.ascii.eqlIgnoreCase(trimmed, "full")) return .full;
    return null;
}

fn resolveDefaultAccess(allocator: Allocator, io: Io) iface.AccessMode {
    if (readEnvVarAlloc(allocator, io, "ONDB_PLAYGROUND_ACCESS")) |raw| {
        defer allocator.free(raw);
        if (parseAccessMode(raw)) |mode| return mode;
    }
    return .accept_edits;
}

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
                    if (is_chunked) return error.BadFraming;
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

fn isValidLocalHostPort(host_port: []const u8, out_port: *?u16) bool {
    out_port.* = null;
    if (host_port.len == 0) return false;
    var host: []const u8 = host_port;
    var port_str: ?[]const u8 = null;
    if (host_port[0] == '[') {
        const close_b = std.mem.indexOfScalar(u8, host_port, ']') orelse return false;
        host = host_port[0 .. close_b + 1];
        const tail = host_port[close_b + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return false;
            port_str = tail[1..];
        }
        if (!std.mem.eql(u8, host, "[::1]")) return false;
    } else {
        if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
            host = host_port[0..colon];
            port_str = host_port[colon + 1 ..];
        }
        const ok_host = std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
        if (!ok_host) return false;
    }
    if (port_str) |ps| {
        if (ps.len == 0 or ps.len > 5) return false;
        for (ps) |c| {
            if (c < '0' or c > '9') return false;
        }
        const p = std.fmt.parseInt(u16, ps, 10) catch return false;
        if (p == 0) return false;
        out_port.* = p;
    }
    return true;
}

pub fn validateHostHeader(headers: []const u8) bool {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next();
    var host_val: ?[]const u8 = null;
    while (it.next()) |line| {
        if (line.len >= 5 and std.ascii.eqlIgnoreCase(line[0..5], "host:")) {
            if (host_val != null) return false;
            host_val = std.mem.trim(u8, line[5..], " \t");
        }
    }
    const hv = host_val orelse return false;
    var parsed_port: ?u16 = null;
    return isValidLocalHostPort(hv, &parsed_port);
}

pub fn validateOriginHeaders(headers: []const u8, expected_port: u16) bool {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next();
    var saw_origin = false;
    var saw_sfs = false;
    while (it.next()) |line| {
        if (line.len >= 15 and std.ascii.eqlIgnoreCase(line[0..15], "sec-fetch-site:")) {
            if (saw_sfs) return false;
            saw_sfs = true;
            const sfs = std.mem.trim(u8, line[15..], " \t");
            if (!std.ascii.eqlIgnoreCase(sfs, "same-origin") and !std.ascii.eqlIgnoreCase(sfs, "none")) {
                return false;
            }
        } else if (line.len >= 7 and std.ascii.eqlIgnoreCase(line[0..7], "origin:")) {
            if (saw_origin) return false;
            saw_origin = true;
            const orig = std.mem.trim(u8, line[7..], " \t");
            var rest: []const u8 = "";
            var default_port: u16 = 80;
            if (orig.len > 7 and std.ascii.eqlIgnoreCase(orig[0..7], "http://")) {
                rest = orig[7..];
                default_port = 80;
            } else if (orig.len > 8 and std.ascii.eqlIgnoreCase(orig[0..8], "https://")) {
                rest = orig[8..];
                default_port = 443;
            } else {
                return false;
            }
            if (std.mem.indexOfAny(u8, rest, "/?#@ \t") != null) return false;
            var parsed_port: ?u16 = null;
            if (!isValidLocalHostPort(rest, &parsed_port)) return false;
            if (expected_port != 0) {
                const eff_port = parsed_port orelse default_port;
                if (eff_port != expected_port) return false;
            }
        }
    }
    return true;
}

pub fn hasJsonContentType(headers: []const u8) bool {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next();
    var found = false;
    while (it.next()) |line| {
        if (line.len >= 13 and std.ascii.eqlIgnoreCase(line[0..13], "content-type:")) {
            const raw = std.mem.trim(u8, line[13..], " \t");
            const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
            const media = std.mem.trim(u8, raw[0..semi], " \t");
            if (!std.ascii.eqlIgnoreCase(media, "application/json")) return false;
            found = true;
        }
    }
    return found;
}

pub fn isMutationMethod(method: []const u8) bool {
    return !std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD");
}

pub const ChunkedStatus = enum {
    need_more,
    complete,
};

pub const ChunkedDecoder = struct {
    state: enum { size_line, chunk_data, chunk_crlf, trailers, done } = .size_line,
    cursor: usize = 0,
    remaining_chunk: usize = 0,
    trailer_bytes: usize = 0,
    max_bytes: usize,
    out: std.ArrayList(u8) = .empty,

    pub fn init(max_bytes: usize) ChunkedDecoder {
        return .{ .max_bytes = max_bytes };
    }

    pub fn deinit(self: *ChunkedDecoder, allocator: Allocator) void {
        self.out.deinit(allocator);
    }

    pub fn feed(
        self: *ChunkedDecoder,
        allocator: Allocator,
        raw: []const u8,
    ) error{ BadFraming, PayloadTooLarge, OutOfMemory }!ChunkedStatus {
        while (true) {
            switch (self.state) {
                .size_line => {
                    const crlf = std.mem.indexOfPos(u8, raw, self.cursor, "\r\n") orelse {
                        if (raw.len - self.cursor > MAX_CHUNK_LINE_BYTES) return error.BadFraming;
                        return .need_more;
                    };
                    if (crlf - self.cursor > MAX_CHUNK_LINE_BYTES) return error.BadFraming;
                    const line = raw[self.cursor..crlf];
                    const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                    const hex_str = std.mem.trim(u8, line[0..semi], " \t");
                    if (hex_str.len == 0) return error.BadFraming;
                    for (hex_str) |c| {
                        if (!std.ascii.isHex(c)) return error.BadFraming;
                    }
                    const chunk_u64 = std.fmt.parseInt(u64, hex_str, 16) catch return error.PayloadTooLarge;
                    self.cursor = crlf + 2;
                    if (chunk_u64 == 0) {
                        self.state = .trailers;
                        continue;
                    }
                    if (chunk_u64 > self.max_bytes) return error.PayloadTooLarge;
                    const chunk_len: usize = @intCast(chunk_u64);
                    if (chunk_len > self.max_bytes - self.out.items.len) return error.PayloadTooLarge;
                    self.remaining_chunk = chunk_len;
                    self.state = .chunk_data;
                },
                .chunk_data => {
                    const avail = raw.len - self.cursor;
                    if (avail == 0) return .need_more;
                    const take = @min(avail, self.remaining_chunk);
                    try self.out.appendSlice(allocator, raw[self.cursor .. self.cursor + take]);
                    self.cursor += take;
                    self.remaining_chunk -= take;
                    if (self.remaining_chunk == 0) {
                        self.state = .chunk_crlf;
                    } else {
                        return .need_more;
                    }
                },
                .chunk_crlf => {
                    if (raw.len - self.cursor < 2) return .need_more;
                    if (raw[self.cursor] != '\r' or raw[self.cursor + 1] != '\n') return error.BadFraming;
                    self.cursor += 2;
                    self.state = .size_line;
                },
                .trailers => {
                    const tcrlf = std.mem.indexOfPos(u8, raw, self.cursor, "\r\n") orelse {
                        if (self.trailer_bytes + (raw.len - self.cursor) > MAX_TRAILER_BYTES) return error.BadFraming;
                        return .need_more;
                    };
                    if (tcrlf == self.cursor) {
                        self.cursor += 2;
                        self.state = .done;
                        return .complete;
                    }
                    const line_len = (tcrlf - self.cursor) + 2;
                    self.trailer_bytes = std.math.add(usize, self.trailer_bytes, line_len) catch return error.BadFraming;
                    if (self.trailer_bytes > MAX_TRAILER_BYTES) return error.BadFraming;
                    self.cursor = tcrlf + 2;
                },
                .done => return .complete,
            }
        }
    }

    pub fn takeBody(self: *ChunkedDecoder, allocator: Allocator) ![]u8 {
        return try self.out.toOwnedSlice(allocator);
    }

    pub fn consumed(self: *const ChunkedDecoder) usize {
        return self.cursor;
    }
};

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
    var dec = ChunkedDecoder.init(max_bytes);
    defer dec.deinit(allocator);
    const st = try dec.feed(allocator, raw);
    if (st == .need_more) return .need_more;
    return .{ .complete = .{
        .body = try dec.takeBody(allocator),
        .consumed = dec.consumed(),
    } };
}

pub fn validateSplices(
    splices: []const diff_mod.Splice,
    base_len: u64,
    inserted_len: usize,
) error{InvalidSplice}!void {
    var prev_end: u64 = 0;
    var total_ins: u64 = 0;
    for (splices) |s| {
        if (s.at < prev_end) return error.InvalidSplice;
        const end = std.math.add(u64, s.at, s.del) catch return error.InvalidSplice;
        if (end > base_len) return error.InvalidSplice;
        total_ins = std.math.add(u64, total_ins, s.ins) catch return error.InvalidSplice;
        if (total_ins > inserted_len or total_ins > MAX_BODY_BYTES) return error.InvalidSplice;
        prev_end = end;
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
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (std.mem.eql(u8, seg, ".0ndb") or std.mem.eql(u8, seg, ".git")) return false;
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

const BASH_TEST_OUTPUT = "\x1b[1mBuild Summary:\x1b[0m 3/3 steps succeeded\n\x1b[32m✓\x1b[0m test-core 41 passed\n\x1b[32m✓\x1b[0m test-sync 17 passed\n\x1b[2m(0.84s)\x1b[0m\n";

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
        self.clearStagedLocked();
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
        self.mu.lockUncancelable(self.io);
        if (self.closed) {
            self.mu.unlock(self.io);
            return;
        }
        self.closed = true;
        const p = self.prompt;
        const sp = self.steered_prompt;
        const stp = self.staged_path;
        const std_d = self.staged_data;
        self.prompt = null;
        self.steered_prompt = null;
        self.staged_path = null;
        self.staged_data = null;
        self.mu.unlock(self.io);

        if (p) |x| self.allocator.free(x);
        if (sp) |x| self.allocator.free(x);
        if (stp) |x| self.allocator.free(x);
        if (std_d) |x| self.allocator.free(x);
        self.allocator.free(self.workspace_root);
        self.allocator.destroy(self);
    }

    fn clearStagedLocked(self: *InteractiveMock) void {
        if (self.staged_path) |p| self.allocator.free(p);
        if (self.staged_data) |d| self.allocator.free(d);
        self.staged_path = null;
        self.staged_data = null;
    }

    fn stageWrite(self: *InteractiveMock, rel: []const u8, data: []const u8) !void {
        const p = try self.allocator.dupe(u8, rel);
        errdefer self.allocator.free(p);
        const d = try self.allocator.dupe(u8, data);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.clearStagedLocked();
        self.staged_path = p;
        self.staged_data = d;
    }

    fn flushStaged(self: *InteractiveMock) void {
        self.mu.lockUncancelable(self.io);
        const rel = self.staged_path;
        const data = self.staged_data;
        self.staged_path = null;
        self.staged_data = null;
        self.mu.unlock(self.io);

        defer if (rel) |p| self.allocator.free(p);
        defer if (data) |d| self.allocator.free(d);
        const r = rel orelse return;
        const d = data orelse return;
        var wd = Io.Dir.cwd().openDir(self.io, self.workspace_root, .{}) catch return;
        defer wd.close(self.io);
        if (std.fs.path.dirname(r)) |parent| wd.createDirPath(self.io, parent) catch return;
        wd.writeFile(self.io, .{ .sub_path = r, .data = d }) catch {};
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
        self.mu.lockUncancelable(self.io);
        if (self.closed) {
            self.mu.unlock(self.io);
            return null;
        }
        const idx = self.step_idx;
        self.step_idx += 1;
        const tid_num = self.turn_id;
        self.mu.unlock(self.io);

        if (idx == 0) {
            return .{ .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, "sim-session") } } };
        }
        if (idx == 1) {
            const tid = try std.fmt.allocPrint(self.allocator, "sim-turn-{d}", .{tid_num});
            return .{ .kind = .{ .turn_started = .{ .native_turn_id = tid } } };
        }

        if (self.interrupted.load(.acquire)) {
            if (idx < 100) {
                self.mu.lockUncancelable(self.io);
                self.step_idx = 100;
                self.mu.unlock(self.io);
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
            self.mu.lockUncancelable(self.io);
            self.step_idx = 100;
            self.mu.unlock(self.io);
            return .{ .kind = .{ .turn_ended = .{
                .ok = false,
                .err_msg = try self.allocator.dupe(u8, "interrupted"),
            } } };
        }

        self.mu.lockUncancelable(self.io);
        const prompt_copy = self.allocator.dupe(u8, self.prompt orelse "") catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        const steer_copy: ?[]u8 = if (self.steered_prompt) |sp|
            self.allocator.dupe(u8, sp) catch |err| {
                self.mu.unlock(self.io);
                self.allocator.free(prompt_copy);
                return err;
            }
        else
            null;
        const cur_turn_id = self.turn_id;
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
                const line = try std.fmt.allocPrint(self.allocator, "- turn {d}: {s}\n", .{ cur_turn_id, label });
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
                const rel = try std.fmt.allocPrint(self.allocator, "src/generated/turn_{d}.zig", .{cur_turn_id});
                defer self.allocator.free(rel);
                const body = try std.fmt.allocPrint(
                    self.allocator,
                    "pub const TURN: u64 = {d};\npub const STEERED = {s};\npub const FILES_TOUCHED = 3;\n\npub fn id() u64 {{\n    return TURN;\n}}\n",
                    .{ cur_turn_id, if (steer_copy != null) "true" else "false" },
                );
                defer self.allocator.free(body);
                try self.stageWrite(rel, body);
                const input = try self.writeToolInput(rel, body);
                defer self.allocator.free(input);
                return try toolStartedEvent(self.allocator, "tool-3", "Write", input);
            },
            9 => {
                self.flushStaged();
                const output = try std.fmt.allocPrint(self.allocator, "Created src/generated/turn_{d}.zig", .{cur_turn_id});
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
                    .{cur_turn_id},
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
                self.mu.lockUncancelable(self.io);
                self.step_idx = 100;
                self.mu.unlock(self.io);
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

const SseClient = struct {
    fd: posix.fd_t,
    pending: std.ArrayList(u8) = .empty,

    fn deinit(self: *SseClient, allocator: Allocator) void {
        self.pending.deinit(allocator);
    }
};

fn loadOrCreateMasterKey(allocator: Allocator, io: Io, state_path: []const u8) !crypto.Key {
    const key_path = try std.fmt.allocPrint(allocator, "{s}/sync_master.key", .{state_path});
    defer allocator.free(key_path);
    const key_path_buf = try allocator.alloc(u8, key_path.len + 1);
    defer allocator.free(key_path_buf);
    @memcpy(key_path_buf[0..key_path.len], key_path);
    key_path_buf[key_path.len] = 0;
    const key_path_z: [*:0]const u8 = @ptrCast(key_path_buf.ptr);

    const open_r = linux.open(key_path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(open_r) == .SUCCESS) {
        const fd: posix.fd_t = @intCast(open_r);
        defer _ = linux.close(fd);
        var key: crypto.Key = undefined;
        var got: usize = 0;
        while (got < key.len) {
            const rrc = linux.read(fd, key[got..].ptr, key.len - got);
            const re = linux.errno(rrc);
            if (re == .INTR) continue;
            if (re != .SUCCESS or rrc == 0) break;
            got += rrc;
        }
        if (got == key.len) {
            _ = linux.fchmod(fd, 0o600);
            return key;
        }
    }

    var key: crypto.Key = undefined;
    io.random(&key);
    const open_w = linux.open(
        key_path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o600,
    );
    if (linux.errno(open_w) != .SUCCESS) return error.MasterKeyWriteFailed;
    const wfd: posix.fd_t = @intCast(open_w);
    defer _ = linux.close(wfd);
    _ = linux.fchmod(wfd, 0o600);
    var off: usize = 0;
    while (off < key.len) {
        const wrc = linux.write(wfd, key[off..].ptr, key.len - off);
        const we = linux.errno(wrc);
        if (we == .INTR) continue;
        if (we != .SUCCESS or wrc == 0) return error.MasterKeyWriteFailed;
        off += wrc;
    }
    return key;
}

fn chmodPath(allocator: Allocator, path: []const u8, mode: posix.mode_t) void {
    const z = allocator.alloc(u8, path.len + 1) catch return;
    defer allocator.free(z);
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const zptr: [*:0]const u8 = @ptrCast(z.ptr);
    _ = linux.fchmodat(linux.AT.FDCWD, zptr, mode);
}

const V2State = struct {
    v2_root_path: []u8,
    runner_id: u128,
    device_id: u128,
    resources: *pool_mod.DaemonResources,
    spaces: space_mgr_mod.SpaceManager,
    projects: project_mod.ProjectStore,
    catalog_dir: Io.Dir,
    catalog: thread_store_mod.CatalogStore,
    keyring: keyring_mod.Keyring,
    leases: lease_mod.LeaseManager,
    runtime: thread_rt_mod.ThreadRuntime,
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
    default_access: iface.AccessMode,
    dev_a: client_mod.SyncClient,
    dev_b: client_mod.SyncClient,
    dev_b_dir: Io.Dir,
    dev_b_pages: blobs_mod.BlobStore,
    dev_b_path: []u8,
    sse_clients: std.ArrayList(SseClient),
    sse_keepalive_thread: std.Thread,
    listen_fd: posix.fd_t,
    http_port: u16,
    running: std.atomic.Value(bool),
    active_threads: std.atomic.Value(usize),
    active_conns: std.atomic.Value(usize),
    active_workers: std.atomic.Value(usize),
    busy_threads_mu: Io.Mutex,
    busy_threads: std.AutoHashMapUnmanaged(u128, void),
    client_fds_mu: Io.Mutex,
    client_fds: std.AutoHashMapUnmanaged(posix.fd_t, void),
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
    v2_mu: Io.Mutex,
    v2: V2State,
    v2_maint_thread: std.Thread,

    pub fn start(
        allocator: Allocator,
        io: Io,
        workspace_path: []const u8,
        port: u16,
    ) !*PlaygroundServer {
        return startWithConfig(allocator, io, workspace_path, port, .{
            .default_access = resolveDefaultAccess(allocator, io),
        });
    }

    pub fn startWithConfig(
        allocator: Allocator,
        io: Io,
        workspace_path: []const u8,
        port: u16,
        config: ServerConfig,
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
        self.active_workers = std.atomic.Value(usize).init(0);
        self.busy_threads_mu = Io.Mutex.init;
        self.busy_threads = .empty;
        errdefer self.busy_threads.deinit(allocator);
        self.client_fds_mu = Io.Mutex.init;
        self.client_fds = .empty;
        errdefer self.client_fds.deinit(allocator);
        self.active_handles_mu = Io.Mutex.init;
        self.active_handles = .empty;
        errdefer self.active_handles.deinit(allocator);
        self.relay_io_mu = Io.Mutex.init;
        self.relay_sync_mu = Io.Mutex.init;
        self.relay_sync_cond = Io.Condition.init;
        self.relay_sync_pending = .empty;
        errdefer self.relay_sync_pending.deinit(allocator);
        self.traces_dir = try Io.Dir.cwd().openDir(io, traces_path, .{});
        errdefer self.traces_dir.close(io);
        self.ui_dist = resolveUiDist(allocator, io);
        errdefer if (self.ui_dist) |d| allocator.free(d);

        var auth_secret: [32]u8 = undefined;
        io.random(&auth_secret);
        const master_key = try loadOrCreateMasterKey(allocator, io, state_path);

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
        self.default_access = config.default_access;
        self.sse_clients = .empty;
        errdefer self.sse_clients.deinit(allocator);
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

        self.v2_mu = Io.Mutex.init;
        const v2_root = if (config.v2_root) |vr|
            try allocator.dupe(u8, vr)
        else
            try std.fmt.allocPrint(allocator, "{s}/.0ndb/v2", .{workspace_path});
        self.v2.v2_root_path = v2_root;
        errdefer allocator.free(self.v2.v2_root_path);

        try Io.Dir.cwd().createDirPath(io, v2_root);
        chmodPath(allocator, v2_root, 0o700);

        const v2_res_path = try std.fmt.allocPrint(allocator, "{s}/resources", .{v2_root});
        defer allocator.free(v2_res_path);
        const v2_spaces_path = try std.fmt.allocPrint(allocator, "{s}/spaces", .{v2_root});
        defer allocator.free(v2_spaces_path);
        const v2_checkouts_path = try std.fmt.allocPrint(allocator, "{s}/checkouts", .{v2_root});
        defer allocator.free(v2_checkouts_path);
        const v2_projects_path = try std.fmt.allocPrint(allocator, "{s}/projects", .{v2_root});
        defer allocator.free(v2_projects_path);
        const v2_catalog_path = try std.fmt.allocPrint(allocator, "{s}/catalog", .{v2_root});
        defer allocator.free(v2_catalog_path);
        const v2_leases_path = try std.fmt.allocPrint(allocator, "{s}/leases", .{v2_root});
        defer allocator.free(v2_leases_path);
        const v2_threads_path = try std.fmt.allocPrint(allocator, "{s}/threads", .{v2_root});
        defer allocator.free(v2_threads_path);

        try Io.Dir.cwd().createDirPath(io, v2_catalog_path);

        self.v2.resources = try pool_mod.DaemonResources.init(allocator, io, v2_res_path, .{});
        errdefer self.v2.resources.deinit();

        self.v2.spaces = try space_mgr_mod.SpaceManager.open(allocator, io, v2_spaces_path, v2_checkouts_path, self.v2.resources);
        errdefer self.v2.spaces.deinit();

        self.v2.projects = try project_mod.ProjectStore.open(allocator, io, v2_projects_path);
        errdefer self.v2.projects.deinit();

        self.v2.catalog_dir = try Io.Dir.cwd().openDir(io, v2_catalog_path, .{ .iterate = true });
        errdefer self.v2.catalog_dir.close(io);

        self.v2.catalog = try thread_store_mod.CatalogStore.open(allocator, io, self.v2.catalog_dir);
        errdefer self.v2.catalog.deinit();

        {
            var v2_dir = try Io.Dir.cwd().openDir(io, v2_root, .{ .iterate = true });
            defer v2_dir.close(io);
            if (keyring_mod.Keyring.load(allocator, io, v2_dir, "keyring.bin")) |kr| {
                self.v2.keyring = kr;
            } else |_| {
                const rid = id.newUuidV7(io);
                const ark = crypto.AccountRootKey.generate(io);
                self.v2.keyring = keyring_mod.Keyring.initAccountDevice(allocator, io, ark, rid);
                try self.v2.keyring.saveAtomic(v2_dir, "keyring.bin");
                const kr_path = try std.fmt.allocPrint(allocator, "{s}/keyring.bin", .{v2_root});
                defer allocator.free(kr_path);
                chmodPath(allocator, kr_path, 0o600);
            }
        }
        errdefer self.v2.keyring.deinit();

        self.v2.runner_id = self.v2.keyring.runner_id;
        self.v2.device_id = self.v2.keyring.runner_id;

        self.v2.leases = try lease_mod.LeaseManager.init(allocator, io, v2_leases_path, self.v2.runner_id, null);
        errdefer self.v2.leases.deinit();

        self.v2.runtime = try thread_rt_mod.ThreadRuntime.init(allocator, io, .{
            .spaces = &self.v2.spaces,
            .projects = &self.v2.projects,
            .catalog = &self.v2.catalog,
            .keyring = &self.v2.keyring,
            .leases = &self.v2.leases,
            .root_dir = v2_threads_path,
            .runner_id = self.v2.runner_id,
            .device_id = self.v2.device_id,
            .shared_blobs = self.v2.resources.blob_pool,
        });
        errdefer self.v2.runtime.deinit();

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
        errdefer {
            self.running.store(false, .release);
            self.relay_sync_mu.lockUncancelable(io);
            self.relay_sync_cond.broadcast(io);
            self.relay_sync_mu.unlock(io);
            self.relay_sync_thread.join();
        }
        self.sse_keepalive_thread = try std.Thread.spawn(.{}, sseKeepaliveMain, .{self});
        errdefer {
            self.running.store(false, .release);
            self.sse_keepalive_thread.join();
            self.v2_maint_thread.join();
        }
        self.v2_maint_thread = try std.Thread.spawn(.{}, v2MaintMain, .{self});
        if (config.prewarm_models) {
            self.startPrewarmModels();
        }
        return self;
    }

    pub fn stop(self: *PlaygroundServer) void {
        self.running.store(false, .release);
        _ = linux.shutdown(self.listen_fd, linux.SHUT.RDWR);
        self.interruptAllActiveTurns();
        self.shutdownAllClientSockets();
        self.closeAllSseClients();
    }

    pub fn deinit(self: *PlaygroundServer) void {
        self.stop();
        _ = linux.close(self.listen_fd);
        self.sse_keepalive_thread.join();

        var spins: usize = 0;
        while (self.active_threads.load(.acquire) > 0) : (spins += 1) {
            if (spins % 20 == 0) {
                self.interruptAllActiveTurns();
                self.shutdownAllClientSockets();
            }
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
        self.closeAllSseClients();
        self.sse_clients.deinit(self.allocator);
        self.client_fds_mu.lockUncancelable(self.io);
        self.client_fds.deinit(self.allocator);
        self.client_fds_mu.unlock(self.io);
        self.busy_threads_mu.lockUncancelable(self.io);
        self.busy_threads.deinit(self.allocator);
        self.busy_threads_mu.unlock(self.io);
        self.active_handles_mu.lockUncancelable(self.io);
        self.active_handles.deinit(self.allocator);
        self.active_handles_mu.unlock(self.io);
        self.models_mu.lockUncancelable(self.io);
        var mit = self.model_cache.valueIterator();
        while (mit.next()) |v| v.deinit(self.allocator);
        self.model_cache.deinit();
        self.models_mu.unlock(self.io);
        self.v2.runtime.deinit();
        self.v2.leases.deinit();
        if (Io.Dir.cwd().openDir(self.io, self.v2.v2_root_path, .{ .iterate = true })) |vd_val| {
            var vd = vd_val;
            defer vd.close(self.io);
            self.v2.keyring.saveAtomic(vd, "keyring.bin") catch {};
        } else |_| {}
        self.v2.keyring.deinit();
        self.v2.catalog.deinit();
        self.v2.catalog_dir.close(self.io);
        self.v2.projects.deinit();
        self.v2.spaces.deinit();
        self.v2.resources.deinit();
        self.allocator.free(self.v2.v2_root_path);
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

    fn registerClientFd(self: *PlaygroundServer, fd: posix.fd_t) void {
        self.client_fds_mu.lockUncancelable(self.io);
        defer self.client_fds_mu.unlock(self.io);
        self.client_fds.put(self.allocator, fd, {}) catch {};
    }

    fn unregisterClientFd(self: *PlaygroundServer, fd: posix.fd_t) void {
        self.client_fds_mu.lockUncancelable(self.io);
        defer self.client_fds_mu.unlock(self.io);
        _ = self.client_fds.remove(fd);
    }

    fn shutdownAllClientSockets(self: *PlaygroundServer) void {
        self.client_fds_mu.lockUncancelable(self.io);
        defer self.client_fds_mu.unlock(self.io);
        var it = self.client_fds.keyIterator();
        while (it.next()) |k| {
            _ = linux.shutdown(k.*, linux.SHUT.RDWR);
        }
    }

    fn closeAllSseClients(self: *PlaygroundServer) void {
        self.sse_mu.lockUncancelable(self.io);
        defer self.sse_mu.unlock(self.io);
        for (self.sse_clients.items) |*c| {
            _ = linux.shutdown(c.fd, linux.SHUT.RDWR);
            _ = linux.close(c.fd);
            c.deinit(self.allocator);
        }
        self.sse_clients.clearRetainingCapacity();
    }

    fn acquireThreadTurn(self: *PlaygroundServer, thread_id: u128) error{ TurnAlreadyActive, OutOfMemory }!void {
        self.busy_threads_mu.lockUncancelable(self.io);
        defer self.busy_threads_mu.unlock(self.io);
        if (self.busy_threads.contains(thread_id)) return error.TurnAlreadyActive;
        try self.busy_threads.put(self.allocator, thread_id, {});
    }

    fn releaseThreadTurn(self: *PlaygroundServer, thread_id: u128) void {
        self.busy_threads_mu.lockUncancelable(self.io);
        defer self.busy_threads_mu.unlock(self.io);
        _ = self.busy_threads.remove(thread_id);
    }

    fn isThreadTurnActive(self: *PlaygroundServer, thread_id: u128) bool {
        self.busy_threads_mu.lockUncancelable(self.io);
        defer self.busy_threads_mu.unlock(self.io);
        return self.busy_threads.contains(thread_id);
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
        const key = @backingInt(provider);
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

    fn drainSseClientLocked(self: *PlaygroundServer, client: *SseClient) bool {
        const poll_rdhup: i16 = 0x2000;
        var pfd = [_]linux.pollfd{.{
            .fd = client.fd,
            .events = poll_rdhup,
            .revents = 0,
        }};
        const prc = linux.poll(&pfd, 1, 0);
        if (linux.errno(prc) == .SUCCESS and prc > 0) {
            if ((pfd[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL | poll_rdhup)) != 0) {
                return false;
            }
        }
        var sent: usize = 0;
        while (sent < client.pending.items.len) {
            const rc = linux.sendto(
                client.fd,
                client.pending.items[sent..].ptr,
                client.pending.items.len - sent,
                linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT,
                null,
                0,
            );
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) break;
            if (e != .SUCCESS or rc == 0) return false;
            sent += rc;
        }
        if (sent > 0) {
            const rem = client.pending.items.len - sent;
            if (rem > 0) {
                std.mem.copyForwards(u8, client.pending.items[0..rem], client.pending.items[sent..]);
            }
            client.pending.shrinkRetainingCapacity(rem);
        }
        _ = self;
        return true;
    }

    fn pushSseRaw(self: *PlaygroundServer, frame: []const u8) void {
        self.sse_mu.lockUncancelable(self.io);
        defer self.sse_mu.unlock(self.io);

        var i: usize = 0;
        while (i < self.sse_clients.items.len) {
            var client = &self.sse_clients.items[i];
            var alive = self.drainSseClientLocked(client);
            if (alive) {
                if (client.pending.items.len + frame.len > MAX_SSE_PENDING_BYTES) {
                    alive = false;
                } else {
                    client.pending.appendSlice(self.allocator, frame) catch {
                        alive = false;
                    };
                    if (alive) {
                        alive = self.drainSseClientLocked(client);
                    }
                }
            }
            if (!alive) {
                _ = linux.shutdown(client.fd, linux.SHUT.RDWR);
                _ = linux.close(client.fd);
                client.deinit(self.allocator);
                _ = self.sse_clients.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn broadcastSse(self: *PlaygroundServer, json_payload: []const u8) void {
        const frame = std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{json_payload}) catch return;
        defer self.allocator.free(frame);
        self.pushSseRaw(frame);
    }

    fn sseKeepaliveMain(self: *PlaygroundServer) void {
        var elapsed_ms: u64 = 0;
        while (self.running.load(.acquire)) {
            self.io.sleep(Io.Duration.fromMilliseconds(250), .awake) catch {};
            if (!self.running.load(.acquire)) return;
            elapsed_ms += 250;
            if (elapsed_ms >= SSE_KEEPALIVE_MS) {
                elapsed_ms = 0;
                self.pushSseRaw(": ping\n\n");
            } else {
                self.sse_mu.lockUncancelable(self.io);
                var i: usize = 0;
                while (i < self.sse_clients.items.len) {
                    var client = &self.sse_clients.items[i];
                    if (client.pending.items.len > 0 and !self.drainSseClientLocked(client)) {
                        _ = linux.shutdown(client.fd, linux.SHUT.RDWR);
                        _ = linux.close(client.fd);
                        client.deinit(self.allocator);
                        _ = self.sse_clients.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
                self.sse_mu.unlock(self.io);
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

    fn readMoreHttpUntil(
        self: *PlaygroundServer,
        fd: posix.fd_t,
        req_buf: *std.ArrayList(u8),
        tmp: *[4096]u8,
        deadline_ms: u64,
    ) bool {
        while (true) {
            if (!self.running.load(.acquire)) return false;
            const now = id.nowMs(self.io);
            if (now >= deadline_ms) return false;
            const remain_ms = deadline_ms - now;
            const poll_ms: i32 = @intCast(@min(remain_ms, 250));
            var pfd = [_]linux.pollfd{.{
                .fd = fd,
                .events = linux.POLL.IN,
                .revents = 0,
            }};
            const prc = linux.poll(&pfd, 1, poll_ms);
            const pe = linux.errno(prc);
            if (pe == .INTR) continue;
            if (pe != .SUCCESS) return false;
            if (prc == 0) continue;
            const rc = linux.read(fd, tmp, tmp.len);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS or rc == 0) return false;
            req_buf.appendSlice(self.allocator, tmp[0..rc]) catch return false;
            return true;
        }
    }

    fn handleConnection(self: *PlaygroundServer, fd: posix.fd_t) void {
        self.registerClientFd(fd);
        var req_buf: std.ArrayList(u8) = .empty;
        defer req_buf.deinit(self.allocator);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var tmp: [4096]u8 = undefined;
        var handed_to_sse = false;
        defer {
            self.unregisterClientFd(fd);
            if (!handed_to_sse) {
                _ = linux.close(fd);
            }
        }

        var req_count: usize = 0;
        while (self.running.load(.acquire)) {
            if (req_buf.items.len == 0) {
                const idle_ms: u64 = if (req_count == 0) REQUEST_READ_TIMEOUT_MS else KEEPALIVE_IDLE_MS;
                const first_deadline = id.nowMs(self.io) + idle_ms;
                if (!self.readMoreHttpUntil(fd, &req_buf, &tmp, first_deadline)) return;
            }
            const deadline_ms = id.nowMs(self.io) + REQUEST_READ_TIMEOUT_MS;

            var header_idx: ?usize = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n");
            while (header_idx == null) {
                if (req_buf.items.len > MAX_HEADER_BYTES) {
                    _ = sendHttp(fd, "431 Request Header Fields Too Large", "application/json", "{\"error\":\"HeadersTooLarge\"}", false);
                    return;
                }
                if (!self.readMoreHttpUntil(fd, &req_buf, &tmp, deadline_ms)) return;
                header_idx = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n");
            }

            const hidx = header_idx.?;
            if (hidx > MAX_HEADER_BYTES) {
                _ = sendHttp(fd, "431 Request Header Fields Too Large", "application/json", "{\"error\":\"HeadersTooLarge\"}", false);
                return;
            }
            const hend = hidx + 4;
            const head_pre = req_buf.items[0..hidx];

            if (!validateHostHeader(head_pre)) {
                _ = sendHttp(fd, "403 Forbidden", "application/json", "{\"error\":\"InvalidHost\"}", false);
                return;
            }

            const first_nl_pre = std.mem.indexOf(u8, head_pre, "\r\n") orelse head_pre.len;
            const req_line_pre = head_pre[0..first_nl_pre];
            var parts_pre = std.mem.splitScalar(u8, req_line_pre, ' ');
            const method_pre = parts_pre.next() orelse "";

            if (isMutationMethod(method_pre)) {
                if (!validateOriginHeaders(head_pre, self.http_port)) {
                    _ = sendHttp(fd, "403 Forbidden", "application/json", "{\"error\":\"CrossOriginForbidden\"}", false);
                    return;
                }
                if (!hasJsonContentType(head_pre)) {
                    _ = sendHttp(fd, "415 Unsupported Media Type", "application/json", "{\"error\":\"UnsupportedMediaType\"}", false);
                    return;
                }
            }

            const framing = parseHttpFraming(head_pre) catch |err| {
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
                        if (!self.readMoreHttpUntil(fd, &req_buf, &tmp, deadline_ms)) return;
                    }
                    total_req_len = hend + content_len;
                    body = req_buf.items[hend..total_req_len];
                },
                .chunked => {
                    const max_raw_chunked = hend + MAX_BODY_BYTES * 2 + 65536;
                    var dec = ChunkedDecoder.init(MAX_BODY_BYTES);
                    defer dec.deinit(self.allocator);
                    while (true) {
                        const st = dec.feed(self.allocator, req_buf.items[hend..]) catch |err| {
                            switch (err) {
                                error.BadFraming => _ = sendHttp(fd, "400 Bad Request", "application/json", "{\"error\":\"BadFraming\"}", false),
                                error.PayloadTooLarge => _ = sendHttp(fd, "413 Payload Too Large", "application/json", "{\"error\":\"PayloadTooLarge\"}", false),
                                error.OutOfMemory => {},
                            }
                            return;
                        };
                        if (st == .complete) {
                            chunked_body = dec.takeBody(self.allocator) catch return;
                            body = chunked_body.?;
                            total_req_len = hend + dec.consumed();
                            break;
                        }
                        if (req_buf.items.len >= max_raw_chunked) {
                            _ = sendHttp(fd, "413 Payload Too Large", "application/json", "{\"error\":\"PayloadTooLarge\"}", false);
                            return;
                        }
                        if (!self.readMoreHttpUntil(fd, &req_buf, &tmp, deadline_ms)) return;
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
                const sse_hdr =
                    "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/event-stream\r\n" ++
                    "Cache-Control: no-cache\r\n" ++
                    "Connection: keep-alive\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "X-Frame-Options: DENY\r\n" ++
                    "Referrer-Policy: no-referrer\r\n" ++
                    "\r\n: connected\n\n";
                if (!writeAllRaw(fd, sse_hdr)) return;
                wire.setNonBlocking(fd) catch return;
                self.sse_mu.lockUncancelable(self.io);
                if (!self.running.load(.acquire) or self.sse_clients.items.len >= MAX_SSE_CLIENTS) {
                    self.sse_mu.unlock(self.io);
                    return;
                }
                self.sse_clients.append(self.allocator, .{ .fd = fd }) catch {
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
                    write_ok = sendHttp(fd, httpStatusForError(err), "application/json", out.items, keep_alive);
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
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPathFile(self.io, full, &resolved_buf) catch return null;
        const resolved = resolved_buf[0..n];
        if (resolved.len <= dist.len) return null;
        if (!std.mem.startsWith(u8, resolved, dist)) return null;
        if (resolved[dist.len] != '/') return null;
        return Io.Dir.cwd().readFileAlloc(self.io, resolved, self.allocator, .limited(MAX_STATIC_BYTES)) catch null;
    }

    fn routeApi(
        self: *PlaygroundServer,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        if (std.mem.startsWith(u8, path, "/api/v2/")) {
            return self.routeV2Api(method, path, query, body, out);
        }
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/info")) {
            const provs = registry.listProviders(self.io);
            const rss_kb = readRssKb(self.io);
            self.mu.lockUncancelable(self.io);
            var hhex: [32]u8 = undefined;
            _ = id.formatIdHex(self.workspace.history.history_id, &hhex);
            const root_copy = try self.allocator.dupe(u8, self.workspace.root_path);
            const heads_len = self.workspace.history.dag.heads.slice().len;
            const batch_cnt = self.workspace.batch_log.count();
            const owned_heap = self.workspace.history.ownedHeapBytes();
            const page_sz = self.engine.page_size;
            const thread_cnt = self.engine.journal.threads.count();
            const dag_cnt = self.workspace.history.dag.count();
            self.mu.unlock(self.io);
            defer self.allocator.free(root_copy);

            try out.appendSlice(self.allocator, "{\"workspace_root\":");
            try rpc.appendJsonEscaped(self.allocator, out, root_copy);
            try out.print(
                self.allocator,
                ",\"history_id\":\"{s}\",\"heads\":{d},\"batches\":{d},\"rss_kb\":{d},\"owned_heap_bytes\":{d},\"relay_port\":{d},\"page_size\":{d},\"threads\":{d},\"dag_batches\":{d},\"default_access\":\"{s}\",\"ui_dist\":",
                .{
                    hhex,
                    heads_len,
                    batch_cnt,
                    rss_kb,
                    owned_heap,
                    self.relay.port,
                    page_sz,
                    thread_cnt,
                    dag_cnt,
                    @tagName(self.default_access),
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
                const entry = self.model_cache.get(@backingInt(pid)) orelse continue;
                if (!first) try out.append(self.allocator, ',');
                first = false;
                try out.print(self.allocator, "\"{s}\":", .{pid.slug()});
                try appendCatalogJson(self.allocator, out, pid, &entry);
            }
            try out.appendSlice(self.allocator, "}}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/models")) {
            const pslug = (try queryParamAlloc(self.allocator, query, "provider")) orelse return error.MissingProvider;
            defer self.allocator.free(pslug);
            const refresh_val = try queryParamAlloc(self.allocator, query, "refresh");
            defer if (refresh_val) |r| self.allocator.free(r);
            const force = if (refresh_val) |r| std.mem.eql(u8, r, "1") else false;
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
                has_cached = self.model_cache.contains(@backingInt(pid));
                self.models_mu.unlock(self.io);
            }
            if (!has_cached or force) {
                try self.refreshModelCache(pid);
            }

            self.models_mu.lockUncancelable(self.io);
            defer self.models_mu.unlock(self.io);
            if (self.model_cache.get(@backingInt(pid))) |entry| {
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
                const t_opt = self.engine.journal.threads.get(s.thread_id);
                const t_model: ?[]const u8 = if (t_opt) |t| t.default_model else null;
                const t_wt: ?u128 = if (t_opt) |t| t.worktree_id else null;
                try appendSessionSummaryJson(self.allocator, out, &s, t_model, t_wt);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and (std.mem.eql(u8, path, "/api/threads") or std.mem.eql(u8, path, "/api/chats"))) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "Untitled session";
            const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
            const mdl_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model")) orelse "";
            const wt_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse "";
            const prompt_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt"));
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
            if (std.mem.eql(u8, path, "/api/chats")) {
                if (prompt_opt) |prompt| {
                    if (prompt.len > 0) {
                        try self.spawnWorker(tid, .send_new, prompt, null, prov_slug, mdl);
                    }
                }
            }
            var thex: [32]u8 = undefined;
            _ = id.formatIdHex(tid, &thex);
            if (std.mem.eql(u8, path, "/api/chats")) {
                try out.print(self.allocator, "{{\"thread_id\":\"{s}\",\"chat_id\":\"{s}\"}}", .{ thex, thex });
            } else {
                try out.print(self.allocator, "{{\"thread_id\":\"{s}\"}}", .{thex});
            }
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
                    const t = self.engine.journal.threads.getPtr(tid) orelse return error.ThreadNotFound;
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

                self.scheduleRelaySync(tid);
                self.emitSessionEvent(tid);
                try out.appendSlice(self.allocator, "{\"ok\":true}");
                return;
            }

            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "page")) {
                const limit_str = try queryParamAlloc(self.allocator, query, "limit");
                defer if (limit_str) |s| self.allocator.free(s);
                const limit = @min(if (limit_str) |s| (std.fmt.parseInt(usize, s, 10) catch 8) else 8, 200);
                const before_str = try queryParamAlloc(self.allocator, query, "before");
                defer if (before_str) |s| self.allocator.free(s);
                const before_id: ?u128 = if (before_str) |b| (if (b.len == 32) try id.parseIdHex(b) else null) else null;
                const branch_str = try queryParamAlloc(self.allocator, query, "branch");
                defer if (branch_str) |s| self.allocator.free(s);
                const branch_id: ?u128 = if (branch_str) |b| (if (b.len == 32) try id.parseIdHex(b) else null) else null;
                const from_str = try queryParamAlloc(self.allocator, query, "from_msg_id");
                defer if (from_str) |s| self.allocator.free(s);
                const from_id: ?u128 = if (from_str) |b| (if (b.len == 32) id.parseIdHex(b) catch null else null) else null;

                if (branch_id) |bmid| {
                    try self.appendBranchPreviewJson(tid, bmid, from_id, limit, out);
                } else {
                    try self.appendPageJson(tid, before_id, limit, out);
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
                const mid_hex = (try queryParamAlloc(self.allocator, query, "msg_id")) orelse return error.MissingMsgId;
                defer self.allocator.free(mid_hex);
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

                if (self.isThreadTurnActive(tid)) return error.TurnAlreadyActive;

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
                const req_limit = try jsonU64Opt(rpc.jsonObjGet(parsed.value, "limit"));
                const limit: usize = if (req_limit > 0) @intCast(@min(req_limit, 200)) else self.engine.page_size;

                const res_rb = blk: {
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
                    const hp = if (self.engine.journal.threads.get(tid)) |t| t.head_page else null;
                    break :blk .{ .elapsed = elapsed, .head_page = hp };
                };

                try out.print(self.allocator, "{{\"ok\":true,\"elapsed_us\":{d},\"page\":", .{res_rb.elapsed});
                try self.appendPageJson(tid, null, limit, out);
                try out.append(self.allocator, '}');
                self.emitSessionEventWithHead(tid, res_rb.head_page);
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
                const req_limit = try jsonU64Opt(rpc.jsonObjGet(parsed.value, "limit"));
                const limit: usize = if (req_limit > 0) @intCast(@min(req_limit, 200)) else self.engine.page_size;

                const res_br = blk: {
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
                        var slow: ?u128 = leaf;
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
                            if (count % 2 == 1) {
                                if (slow) |sid| {
                                    slow = if (self.engine.journal.messages.get(sid)) |sm| sm.parent_id else null;
                                }
                            }
                            if (cur != null and slow != null and cur.? == slow.?) break;
                        }
                    }
                    const hp = if (self.engine.journal.threads.get(tid)) |t| t.head_page else null;
                    break :blk .{ .leaf = leaf, .elapsed = elapsed, .effective_limit = effective_limit, .head_page = hp };
                };

                var lhex: [32]u8 = undefined;
                _ = id.formatIdHex(res_br.leaf, &lhex);
                try out.print(self.allocator, "{{\"leaf_msg_id\":\"{s}\",\"elapsed_us\":{d},\"page\":", .{ lhex, res_br.elapsed });
                try self.appendPageJson(tid, null, res_br.effective_limit, out);
                try out.append(self.allocator, '}');
                self.emitSessionEventWithHead(tid, res_br.head_page);
                self.scheduleRelaySync(tid);
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "sync")) {
                const wid = try self.threadWorktreeId(tid);
                try self.handleWorktreeSync(wid, out);
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "land")) {
                const wid = try self.threadWorktreeId(tid);
                try self.handleWorktreeLand(wid, out);
                return;
            }

            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "conflicts")) {
                const wid = try self.threadWorktreeId(tid);
                try self.handleWorktreeConflicts(wid, out);
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "resolve")) {
                const wid = try self.threadWorktreeId(tid);
                try self.handleWorktreeResolve(wid, body, out);
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
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.appendFilesJsonLocked(&self.workspace, true, out);
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/file")) {
            const decoded_p = (try queryParamAlloc(self.allocator, query, "path")) orelse return error.MissingPath;
            defer self.allocator.free(decoded_p);
            if (!isSafeRelPath(decoded_p)) return error.InvalidPath;
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.appendFileJsonLocked(&self.workspace, decoded_p, query, out);
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/file/rebase")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const fpath = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path")) orelse return error.MissingPath;
            if (!isSafeRelPath(fpath)) return error.InvalidPath;
            const bv_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "base_version")) orelse "";
            const draft = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "draft")) orelse "";
            const cur_start = try jsonU64Opt(rpc.jsonObjGet(parsed.value, "cursor_start"));
            const cur_end = try jsonU64Opt(rpc.jsonObjGet(parsed.value, "cursor_end"));

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
                                    .at = try jsonU64(rpc.jsonObjGet(item, "at")),
                                    .del = try jsonU64(rpc.jsonObjGet(item, "del")),
                                    .ins = try jsonU64(rpc.jsonObjGet(item, "ins")),
                                });
                            }
                            const base_bytes = try self.workspace.history.readFileAt(self.allocator, fpath, bv);
                            defer if (base_bytes) |b| self.allocator.free(b);
                            const base_len: u64 = if (base_bytes) |b| b.len else 0;
                            try validateSplices(splices.items, base_len, inserted.len);
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
            const decoded_p = (try queryParamAlloc(self.allocator, query, "path")) orelse return error.MissingPath;
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
            const limit_str = try queryParamAlloc(self.allocator, query, "limit");
            defer if (limit_str) |s| self.allocator.free(s);
            const limit = if (limit_str) |s| (std.fmt.parseInt(usize, s, 10) catch 200) else 200;
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            try self.appendHistoryJsonLocked(&self.workspace, limit, out);
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
                const t_opt = self.engine.journal.threads.get(s.thread_id);
                const t_model: ?[]const u8 = if (t_opt) |t| t.default_model else null;
                const t_wt: ?u128 = if (t_opt) |t| t.worktree_id else null;
                try appendSessionSummaryJson(self.allocator, out, &s, t_model, t_wt);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/remote/page")) {
            const tid_hex = (try queryParamAlloc(self.allocator, query, "thread_id")) orelse return error.MissingThreadId;
            defer self.allocator.free(tid_hex);
            const pid_hex = (try queryParamAlloc(self.allocator, query, "page_id")) orelse return error.MissingPageId;
            defer self.allocator.free(pid_hex);
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
            var snapshot: std.ArrayList(wt_mod.WorktreeInfo) = .empty;
            defer {
                for (snapshot.items) |*info| info.deinit(self.allocator);
                snapshot.deinit(self.allocator);
            }
            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                const items = self.worktrees.list();
                try snapshot.ensureTotalCapacityPrecise(self.allocator, items.len);
                for (items) |*info| {
                    snapshot.appendAssumeCapacity(try info.clone(self.allocator));
                }
            }
            try out.appendSlice(self.allocator, "{\"worktrees\":[");
            for (snapshot.items, 0..) |*info, i| {
                if (i > 0) try out.append(self.allocator, ',');
                const conflict_count = readStoredConflictCount(self.allocator, self.io, info.state_path);
                try appendWorktreeJson(self.allocator, out, info, info.id == self.primary_wt_id, conflict_count);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and (std.mem.eql(u8, path, "/api/worktrees") or std.mem.eql(u8, path, "/api/worktrees/scratch"))) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "scratch";
            if (std.mem.eql(u8, path, "/api/worktrees")) {
                if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "source_id"))) |src_hex| {
                    if (src_hex.len > 0) {
                        const src_id = try id.parseIdHex(src_hex);
                        const ref_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "ref_name")) orelse "";
                        const ref_opt: ?[]const u8 = if (ref_raw.len > 0) ref_raw else null;
                        try self.handleWorktreeFork(src_id, title, ref_opt, out);
                        return;
                    }
                }
                if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path"))) |adopt_path| {
                    if (adopt_path.len > 0) {
                        try self.handleWorktreeAdopt(adopt_path, title, out);
                        return;
                    }
                }
            }
            self.mu.lockUncancelable(self.io);
            var info = self.worktrees.scratch(title) catch |err| {
                self.mu.unlock(self.io);
                return err;
            };
            self.mu.unlock(self.io);
            defer info.deinit(self.allocator);
            try out.appendSlice(self.allocator, "{\"worktree\":");
            try appendWorktreeJson(self.allocator, out, &info, false, 0);
            try out.append(self.allocator, '}');
            self.emitWorktreesUpdated();
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/adopt")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const adopt_path = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path")) orelse return error.MissingPath;
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "adopted";
            try self.handleWorktreeAdopt(adopt_path, title, out);
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
            try self.handleWorktreeFork(src_id, title, ref_opt, out);
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/sync")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const wid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse return error.MissingWorktreeId;
            const wid = try id.parseIdHex(wid_hex);
            try self.handleWorktreeSync(wid, out);
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/land")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const wid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse return error.MissingWorktreeId;
            const wid = try id.parseIdHex(wid_hex);
            try self.handleWorktreeLand(wid, out);
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/worktrees/resolve")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const wid_hex = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "worktree_id")) orelse return error.MissingWorktreeId;
            const wid = try id.parseIdHex(wid_hex);
            try self.handleWorktreeResolveParsed(wid, parsed.value, out);
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/worktrees/")) {
            const rest = path["/api/worktrees/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const wid = try id.parseIdHex(rest[0..slash]);
                const sub = rest[slash + 1 ..];
                if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "conflicts")) {
                    try self.handleWorktreeConflicts(wid, out);
                    return;
                }
                if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "fork")) {
                    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                    defer parsed.deinit();
                    const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "fork";
                    const ref_raw = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "ref_name")) orelse "";
                    const ref_opt: ?[]const u8 = if (ref_raw.len > 0) ref_raw else null;
                    try self.handleWorktreeFork(wid, title, ref_opt, out);
                    return;
                }
                if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "sync")) {
                    try self.handleWorktreeSync(wid, out);
                    return;
                }
                if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "land")) {
                    try self.handleWorktreeLand(wid, out);
                    return;
                }
                if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "resolve")) {
                    try self.handleWorktreeResolve(wid, body, out);
                    return;
                }
                if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "remove")) {
                    var force = false;
                    var delete_ref = false;
                    if (body.len > 0) {
                        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                        defer parsed.deinit();
                        if (rpc.jsonObjGet(parsed.value, "force")) |fv| {
                            if (fv == .bool) force = fv.bool;
                        }
                        if (rpc.jsonObjGet(parsed.value, "delete_ref")) |dv| {
                            if (dv == .bool) delete_ref = dv.bool;
                        }
                    }
                    try self.handleWorktreeRemove(wid, force, delete_ref, out);
                    return;
                }
                if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "files")) {
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const ws = self.worktrees.getWorkspace(wid) orelse return error.WorktreeNotFound;
                    try self.appendFilesJsonLocked(ws, wid == self.primary_wt_id, out);
                    return;
                }
                if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "file")) {
                    const decoded_p = (try queryParamAlloc(self.allocator, query, "path")) orelse return error.MissingPath;
                    defer self.allocator.free(decoded_p);
                    if (!isSafeRelPath(decoded_p)) return error.InvalidPath;
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const ws = self.worktrees.getWorkspace(wid) orelse return error.WorktreeNotFound;
                    try self.appendFileJsonLocked(ws, decoded_p, query, out);
                    return;
                }
                if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "history")) {
                    const limit_str = try queryParamAlloc(self.allocator, query, "limit");
                    defer if (limit_str) |s| self.allocator.free(s);
                    const limit = if (limit_str) |s| (std.fmt.parseInt(usize, s, 10) catch 200) else 200;
                    self.mu.lockUncancelable(self.io);
                    defer self.mu.unlock(self.io);
                    const ws = self.worktrees.getWorkspace(wid) orelse return error.WorktreeNotFound;
                    try self.appendHistoryJsonLocked(ws, limit, out);
                    return;
                }
            } else if (std.mem.eql(u8, method, "DELETE")) {
                const wid = try id.parseIdHex(rest);
                const force_str = try queryParamAlloc(self.allocator, query, "force");
                defer if (force_str) |s| self.allocator.free(s);
                const del_str = try queryParamAlloc(self.allocator, query, "delete_ref");
                defer if (del_str) |s| self.allocator.free(s);
                const force = if (force_str) |s| std.mem.eql(u8, s, "1") else false;
                const delete_ref = if (del_str) |s| std.mem.eql(u8, s, "1") else false;
                try self.handleWorktreeRemove(wid, force, delete_ref, out);
                return;
            }
        }

        return error.NotFound;
    }

    fn threadWorktreeId(self: *PlaygroundServer, tid: u128) !u128 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const t = self.engine.journal.threads.get(tid) orelse return error.ThreadNotFound;
        return if (t.worktree_id != 0) t.worktree_id else self.primary_wt_id;
    }

    fn emitWorktreesUpdated(self: *PlaygroundServer) void {
        self.broadcastSse("{\"type\":\"worktrees_updated\"}");
    }

    fn handleWorktreeAdopt(self: *PlaygroundServer, adopt_path: []const u8, title: []const u8, out: *std.ArrayList(u8)) !void {
        if (adopt_path.len == 0 or adopt_path.len > 4096) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, adopt_path, 0) != null) return error.InvalidPath;
        var d = Io.Dir.cwd().openDir(self.io, adopt_path, .{}) catch return error.InvalidPath;
        d.close(self.io);
        self.mu.lockUncancelable(self.io);
        var info = self.worktrees.adopt(adopt_path, title) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        defer info.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"worktree\":");
        try appendWorktreeJson(self.allocator, out, &info, info.id == self.primary_wt_id, 0);
        try out.append(self.allocator, '}');
        self.emitWorktreesUpdated();
    }

    fn handleWorktreeFork(self: *PlaygroundServer, src_id: u128, title: []const u8, ref_opt: ?[]const u8, out: *std.ArrayList(u8)) !void {
        self.mu.lockUncancelable(self.io);
        var info = self.worktrees.fork(src_id, title, null, ref_opt) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        defer info.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"worktree\":");
        try appendWorktreeJson(self.allocator, out, &info, false, 0);
        try out.append(self.allocator, '}');
        self.emitWorktreesUpdated();
    }

    fn handleWorktreeSync(self: *PlaygroundServer, wid: u128, out: *std.ArrayList(u8)) !void {
        self.mu.lockUncancelable(self.io);
        var rep = self.worktrees.syncFork(wid) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
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
        self.emitWorktreesUpdated();
    }

    fn handleWorktreeLand(self: *PlaygroundServer, wid: u128, out: *std.ArrayList(u8)) !void {
        self.mu.lockUncancelable(self.io);
        var rep = self.worktrees.landFork(wid) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        defer rep.deinit(self.allocator);
        try out.print(self.allocator, "{{\"landed\":{d},\"brought\":{d}}}", .{ rep.landed, rep.sync.brought });
        self.emitWorktreesUpdated();
    }

    fn handleWorktreeConflicts(self: *PlaygroundServer, wid: u128, out: *std.ArrayList(u8)) !void {
        self.mu.lockUncancelable(self.io);
        const cfs = self.worktrees.conflicts(wid) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
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
    }

    fn handleWorktreeResolve(self: *PlaygroundServer, wid: u128, body: []const u8, out: *std.ArrayList(u8)) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        try self.handleWorktreeResolveParsed(wid, parsed.value, out);
    }

    fn handleWorktreeResolveParsed(self: *PlaygroundServer, wid: u128, val: std.json.Value, out: *std.ArrayList(u8)) !void {
        const rel = rpc.jsonStr(rpc.jsonObjGet(val, "path")) orelse return error.MissingPath;
        if (!isSafeRelPath(rel)) return error.InvalidPath;
        const res_str = rpc.jsonStr(rpc.jsonObjGet(val, "resolution")) orelse return error.MissingResolution;
        const res: wt_mod.Resolution = if (std.mem.eql(u8, res_str, "ours"))
            .ours
        else if (std.mem.eql(u8, res_str, "theirs"))
            .theirs
        else if (std.mem.eql(u8, res_str, "delete"))
            .{ .content = null }
        else if (std.mem.eql(u8, res_str, "content"))
            .{ .content = rpc.jsonStr(rpc.jsonObjGet(val, "content")) orelse "" }
        else
            return error.InvalidResolution;
        self.mu.lockUncancelable(self.io);
        self.worktrees.resolveConflict(wid, rel, res) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        try out.appendSlice(self.allocator, "{\"ok\":true}");
        self.emitWorktreesUpdated();
    }

    fn handleWorktreeRemove(self: *PlaygroundServer, wid: u128, force: bool, delete_ref: bool, out: *std.ArrayList(u8)) !void {
        self.mu.lockUncancelable(self.io);
        self.worktrees.remove(wid, force, delete_ref) catch |err| {
            self.mu.unlock(self.io);
            return err;
        };
        self.mu.unlock(self.io);
        try out.appendSlice(self.allocator, "{\"ok\":true}");
        self.emitWorktreesUpdated();
    }

    fn appendFilesJsonLocked(self: *PlaygroundServer, ws: *const ws_mod.Workspace, use_meta: bool, out: *std.ArrayList(u8)) !void {
        const t0 = nowUs(self.io);
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }
        try self.collectTrackedFilePathsFrom(ws, id.InodeId.ROOT, "", text_mod.View.EVERYTHING, &paths);
        sortDedupePaths(self.allocator, &paths);
        const ver_hex = try ws.history.dag.heads.formatHex(self.allocator);
        defer self.allocator.free(ver_hex);
        try out.appendSlice(self.allocator, "{\"version\":");
        try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
        try out.appendSlice(self.allocator, ",\"files\":[");
        for (paths.items, 0..) |p, i| {
            if (i > 0) try out.append(self.allocator, ',');
            var bytes_len: u64 = 0;
            var lines_cnt: usize = 0;
            if (try ws.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, p)) |iid| {
                if (ws.history.tree.get(iid)) |inode| {
                    if (inode.fileConstPtr()) |f| {
                        bytes_len = f.text.visibleLen();
                        lines_cnt = f.text.lineCount();
                    }
                }
            }
            const meta = if (use_meta) self.file_meta.get(p) else null;
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
    }

    fn appendFileJsonLocked(self: *PlaygroundServer, ws: *const ws_mod.Workspace, decoded_p: []const u8, query: []const u8, out: *std.ArrayList(u8)) !void {
        const at_hex_opt = try queryParamAlloc(self.allocator, query, "at");
        defer if (at_hex_opt) |s| self.allocator.free(s);
        if (at_hex_opt) |at_hex| {
            const mid = try id.parseIdHex(at_hex);
            const msg = self.engine.journal.messages.getPtr(mid) orelse return error.MessageNotFound;
            const side_opt = try queryParamAlloc(self.allocator, query, "side");
            defer if (side_opt) |s| self.allocator.free(s);
            const side = side_opt orelse "post";
            const ver = if (std.mem.eql(u8, side, "pre")) &msg.pre_version else &msg.post_version;
            const at_content = try ws.history.readFileAt(self.allocator, decoded_p, ver);
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
            const iid = (try ws.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, decoded_p)) orelse break :blk 0;
            const inode = ws.history.tree.get(iid) orelse break :blk 0;
            const f = inode.fileConstPtr() orelse break :blk 0;
            break :blk f.text.lineCount();
        };
        const ver_hex = try ws.history.dag.heads.formatHex(self.allocator);
        defer self.allocator.free(ver_hex);
        const start_param = try queryParamAlloc(self.allocator, query, "start_line");
        defer if (start_param) |s| self.allocator.free(s);
        const lines_param = try queryParamAlloc(self.allocator, query, "lines");
        defer if (lines_param) |s| self.allocator.free(s);
        if (start_param != null or lines_param != null) {
            const start_1 = if (start_param) |s| std.fmt.parseInt(usize, s, 10) catch 1 else 1;
            const clamped_1 = if (start_1 == 0) 1 else start_1;
            const max_lines = if (lines_param) |l| std.fmt.parseInt(usize, l, 10) catch 200 else 200;
            const slice = try ws.history.readFileLines(self.allocator, decoded_p, clamped_1 - 1, max_lines) orelse return error.FileNotFound;
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
        const content = try ws.history.readFileAt(self.allocator, decoded_p, null) orelse return error.FileNotFound;
        defer self.allocator.free(content);
        try out.appendSlice(self.allocator, "{\"path\":");
        try rpc.appendJsonEscaped(self.allocator, out, decoded_p);
        try out.appendSlice(self.allocator, ",\"version\":");
        try rpc.appendJsonEscaped(self.allocator, out, ver_hex);
        try out.print(self.allocator, ",\"total_lines\":{d},\"content\":", .{total_lines});
        try rpc.appendJsonEscaped(self.allocator, out, content);
        try out.append(self.allocator, '}');
    }

    fn appendHistoryJsonLocked(self: *PlaygroundServer, ws: *const ws_mod.Workspace, limit: usize, out: *std.ArrayList(u8)) !void {
        const t0 = nowUs(self.io);
        const dag = &ws.history.dag;
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
    }

    fn collectTrackedFilePaths(
        self: *const PlaygroundServer,
        dir_iid: id.InodeId,
        prefix: []const u8,
        view: text_mod.View,
        out: *std.ArrayList([]u8),
    ) !void {
        try self.collectTrackedFilePathsFrom(&self.workspace, dir_iid, prefix, view, out);
    }

    fn collectTrackedFilePathsFrom(
        self: *const PlaygroundServer,
        ws: *const ws_mod.Workspace,
        dir_iid: id.InodeId,
        prefix: []const u8,
        view: text_mod.View,
        out: *std.ArrayList([]u8),
    ) !void {
        var entries = try ws.history.tree.listDir(self.allocator, view, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            const inode = ws.history.tree.get(entry.inode_id) orelse {
                self.allocator.free(rel);
                continue;
            };
            if (inode.isDir()) {
                defer self.allocator.free(rel);
                try self.collectTrackedFilePathsFrom(ws, entry.inode_id, rel, view, out);
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
        if (self.active_workers.fetchAdd(1, .acq_rel) >= MAX_WORKERS) {
            _ = self.active_workers.fetchSub(1, .release);
            return error.TooManyWorkers;
        }
        errdefer _ = self.active_workers.fetchSub(1, .release);

        try self.acquireThreadTurn(thread_id);
        errdefer self.releaseThreadTurn(thread_id);

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
        const tid = wa.thread_id;
        defer _ = self.active_threads.fetchSub(1, .release);
        defer _ = self.active_workers.fetchSub(1, .release);
        defer self.releaseThreadTurn(tid);
        defer {
            self.allocator.free(wa.prompt);
            self.allocator.free(wa.provider_slug);
            if (wa.model) |m| self.allocator.free(m);
            self.allocator.destroy(wa);
        }

        switch (wa.mode) {
            .send_new => {
                self.mu.lockUncancelable(self.io);
                const t = self.engine.journal.threads.get(tid) orelse {
                    self.mu.unlock(self.io);
                    return;
                };
                const prov = parseProviderSlug(wa.provider_slug);
                const uid = self.engine.appendUserMessage(tid, t.leaf_msg_id, .user, wa.prompt, prov, wa.model, null, null) catch {
                    self.mu.unlock(self.io);
                    return;
                };
                self.mu.unlock(self.io);
                self.emitSessionEvent(tid);
                self.executeStreamingTurn(tid, uid, wa.prompt, wa.provider_slug, wa.model);
                self.drainPendingFollowUps(tid);
            },
            .reply_existing => {
                const pid = wa.parent_msg_id orelse return;
                self.executeStreamingTurn(tid, pid, wa.prompt, wa.provider_slug, wa.model);
                self.drainPendingFollowUps(tid);
            },
            .drain_queue => {
                self.drainPendingFollowUps(tid);
            },
        }
    }

    fn drainPendingFollowUps(self: *PlaygroundServer, thread_id: u128) void {
        while (self.running.load(.acquire)) {
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
            const disp_prov = disp.provider;
            self.engine.journal.putQueueItem(disp) catch {
                disp.deinit(self.allocator);
                self.allocator.free(prompt_copy);
                self.allocator.free(prov_slug);
                if (mdl_copy) |m| self.allocator.free(m);
                self.mu.unlock(self.io);
                return;
            };
            const leaf = if (self.engine.journal.threads.get(thread_id)) |t| t.leaf_msg_id else null;
            const uid = self.engine.appendUserMessage(thread_id, leaf, .user, prompt_copy, disp_prov, mdl_copy, null, null) catch {
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
                    self.engine.journal.putQueueItem(done) catch {
                        done.deinit(self.allocator);
                    };
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

        while (self.running.load(.acquire)) {
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
            const init_content = self.allocator.dupe(u8, "") catch {
                var pv = pre_ver;
                pv.deinit(self.allocator);
                var piv = post_init;
                piv.deinit(self.allocator);
                plan.deinit(self.allocator);
                self.allocator.free(root_copy);
                self.mu.unlock(self.io);
                return;
            };
            const asst_id = id.newUuidV7(self.io);
            const now = id.nowMs(self.io);
            var running_msg = model.Message{
                .msg_id = asst_id,
                .thread_id = thread_id,
                .parent_id = cur_parent,
                .role = .assistant,
                .content = init_content,
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
            self.engine.journal.putMessage(running_msg, false) catch {
                running_msg.deinit(self.allocator);
                plan.deinit(self.allocator);
                self.allocator.free(root_copy);
                self.mu.unlock(self.io);
                return;
            };
            self.engine.journal.setBranchChoice(thread_id, cur_parent, asst_id) catch {};
            if (self.engine.journal.threads.getPtr(thread_id)) |t| {
                if (t.clone(self.allocator)) |u_init| {
                    var u = u_init;
                    u.status = .running;
                    u.updated_ms = now;
                    self.engine.journal.putThread(u) catch {
                        u.deinit(self.allocator);
                    };
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
                            .access = self.default_access,
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
            const end_ms = id.nowMs(self.io);
            self.finalizeTrace(asst_id, &trace, end_ms, null);

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
            if (self.engine.journal.messages.getPtr(asst_id)) |existing| {
                if (existing.clone(self.allocator)) |s_init| {
                    var sealed = s_init;
                    if (self.allocator.dupe(u8, acc_text.items)) |new_content| {
                        self.allocator.free(sealed.content);
                        sealed.content = new_content;
                    } else |_| {}
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
                    self.engine.journal.putMessage(sealed, true) catch {
                        sealed.deinit(self.allocator);
                    };
                } else |_| {
                    var pv = post_ver;
                    pv.deinit(self.allocator);
                }
            } else {
                var pv = post_ver;
                pv.deinit(self.allocator);
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
                    var slow_id: ?u128 = asst_id;
                    while (c_id) |cid| {
                        if (count_m >= MAX_MSG_CHAIN_DEPTH) break;
                        const mm = self.engine.journal.messages.get(cid) orelse break;
                        count_m += 1;
                        c_id = mm.parent_id;
                        if (count_m % 2 == 0) {
                            if (slow_id) |sid| {
                                slow_id = if (self.engine.journal.messages.get(sid)) |sm| sm.parent_id else null;
                            }
                        }
                        if (c_id != null and slow_id != null and c_id.? == slow_id.?) break;
                    }
                    u.message_count = count_m;
                    u.updated_ms = end_ms;
                    self.engine.journal.putThread(u) catch {
                        u.deinit(self.allocator);
                    };
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
        self.engine.journal.putQueueItem(u) catch {
            u.deinit(self.allocator);
        };
    }

    fn finishTurnError(self: *PlaygroundServer, ctx: *const TurnCtx, trace: *Trace, err_name: []const u8) void {
        const now = id.nowMs(self.io);
        self.finalizeTrace(ctx.msg_id, trace, now, err_name);
        self.mu.lockUncancelable(self.io);
        if (self.engine.journal.messages.getPtr(ctx.msg_id)) |existing| {
            if (existing.clone(self.allocator)) |s_init| {
                var sealed = s_init;
                if (std.fmt.allocPrint(self.allocator, "Provider error: {s}", .{err_name})) |msg_str| {
                    self.allocator.free(sealed.content);
                    sealed.content = msg_str;
                } else |_| {}
                sealed.status = .failed;
                sealed.updated_ms = now;
                self.engine.journal.putMessage(sealed, true) catch {
                    sealed.deinit(self.allocator);
                };
            } else |_| {}
        }
        if (self.engine.journal.threads.getPtr(ctx.thread_id)) |t| {
            if (t.clone(self.allocator)) |u_init| {
                var u = u_init;
                u.leaf_msg_id = ctx.msg_id;
                u.status = .failed;
                u.updated_ms = now;
                self.engine.journal.putThread(u) catch {
                    u.deinit(self.allocator);
                };
            } else |_| {}
        }
        self.mu.unlock(self.io);
        self.scheduleRelaySync(ctx.thread_id);
        self.emitTurnCompletedEvent(ctx.thread_id);
    }

    fn appendPageJson(
        self: *PlaygroundServer,
        tid: u128,
        before_id: ?u128,
        limit: usize,
        out: *std.ArrayList(u8),
    ) !void {
        const t0 = nowUs(self.io);
        var sibs_list: std.ArrayList([]u128) = .empty;
        defer {
            for (sibs_list.items) |s| self.allocator.free(s);
            sibs_list.deinit(self.allocator);
        }
        var page = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var p = try self.engine.getPage(self.allocator, tid, before_id, limit);
            errdefer p.deinit(self.allocator);
            try sibs_list.ensureTotalCapacityPrecise(self.allocator, p.messages.len);
            for (p.messages) |m| {
                sibs_list.appendAssumeCapacity(try self.siblingsIncluding(m.msg_id));
            }
            break :blk p;
        };
        defer page.deinit(self.allocator);
        const elapsed = nowUs(self.io) -| t0;

        try out.appendSlice(self.allocator, "{\"messages\":[");
        for (page.messages, 0..) |m, i| {
            if (i > 0) try out.append(self.allocator, ',');
            const trace_json = self.traceJsonFor(m.msg_id);
            defer if (trace_json) |tj| self.allocator.free(tj);
            try appendMessageJson(self.allocator, out, &m, sibs_list.items[i], trace_json);
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

    fn appendBranchPreviewJson(
        self: *PlaygroundServer,
        tid: u128,
        branch_mid: u128,
        from_mid: ?u128,
        limit: usize,
        out: *std.ArrayList(u8),
    ) !void {
        const t0 = nowUs(self.io);
        var cloned_msgs: std.ArrayList(model.Message) = .empty;
        defer {
            for (cloned_msgs.items) |*m| m.deinit(self.allocator);
            cloned_msgs.deinit(self.allocator);
        }
        var sibs_list: std.ArrayList([]u128) = .empty;
        defer {
            for (sibs_list.items) |s| self.allocator.free(s);
            sibs_list.deinit(self.allocator);
        }
        var has_more = false;
        var next_before_id: ?u128 = null;

        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            _ = self.engine.journal.threads.get(tid) orelse return error.ThreadNotFound;
            const target = self.engine.journal.messages.get(branch_mid) orelse return error.MessageNotFound;
            if (target.thread_id != tid) return error.MessageWrongThread;

            const leaf = self.engine.journal.resolveBranchLeaf(tid, branch_mid);
            var effective_limit: usize = if (limit == 0) self.engine.page_size else limit;
            {
                var cur: ?u128 = leaf;
                var slow: ?u128 = leaf;
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
                    if (count % 2 == 1) {
                        if (slow) |sid| {
                            slow = if (self.engine.journal.messages.get(sid)) |sm| sm.parent_id else null;
                        }
                    }
                    if (cur != null and slow != null and cur.? == slow.?) break;
                }
            }

            var rev: std.ArrayList(u128) = .empty;
            defer rev.deinit(self.allocator);
            var cur: ?u128 = leaf;
            var slow: ?u128 = leaf;
            var step: usize = 0;
            while (cur) |cid| : (step += 1) {
                if (step >= MAX_MSG_CHAIN_DEPTH) break;
                if (rev.items.len >= effective_limit) {
                    has_more = true;
                    break;
                }
                const m = self.engine.journal.messages.get(cid) orelse break;
                try rev.append(self.allocator, cid);
                cur = m.parent_id;
                if (step % 2 == 1) {
                    if (slow) |sid| {
                        slow = if (self.engine.journal.messages.get(sid)) |sm| sm.parent_id else null;
                    }
                }
                if (cur != null and slow != null and cur.? == slow.?) break;
            }
            if (has_more and rev.items.len > 0) {
                next_before_id = rev.items[rev.items.len - 1];
            }

            try cloned_msgs.ensureTotalCapacityPrecise(self.allocator, rev.items.len);
            try sibs_list.ensureTotalCapacityPrecise(self.allocator, rev.items.len);
            for (0..rev.items.len) |i| {
                const cid = rev.items[rev.items.len - 1 - i];
                const m = self.engine.journal.messages.getPtr(cid).?;
                cloned_msgs.appendAssumeCapacity(try m.clone(self.allocator));
                sibs_list.appendAssumeCapacity(try self.siblingsIncluding(m.msg_id));
            }
        }
        const elapsed = nowUs(self.io) -| t0;

        try out.appendSlice(self.allocator, "{\"messages\":[");
        for (cloned_msgs.items, 0..) |*m, i| {
            if (i > 0) try out.append(self.allocator, ',');
            const trace_json = self.traceJsonFor(m.msg_id);
            defer if (trace_json) |tj| self.allocator.free(tj);
            try appendMessageJson(self.allocator, out, m, sibs_list.items[i], trace_json);
        }
        try out.print(self.allocator, "],\"has_more\":{},\"elapsed_us\":{d},\"next_before\":", .{ has_more, elapsed });
        if (next_before_id) |nb| {
            var nhex: [32]u8 = undefined;
            _ = id.formatIdHex(nb, &nhex);
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

    fn v2MaintMain(self: *PlaygroundServer) void {
        var elapsed_ms: u64 = 0;
        while (self.running.load(.acquire)) {
            self.io.sleep(Io.Duration.fromMilliseconds(100), .awake) catch {};
            if (!self.running.load(.acquire)) return;
            elapsed_ms += 100;
            if (elapsed_ms >= 2000) {
                elapsed_ms = 0;
                self.v2_mu.lockUncancelable(self.io);
                self.runV2MaintenanceTickLocked();
                self.v2_mu.unlock(self.io);
            }
        }
    }

    fn runV2MaintenanceTickLocked(self: *PlaygroundServer) void {
        const now_ms = id.nowMs(self.io);
        _ = self.v2.spaces.hibernateIdle(now_ms, self.v2.resources.governor.budget.idle_hibernate_ms);

        if (self.v2.resources.watcher) |w| {
            if (w.nextEventBatch(self.io, 0) catch null) |res_val| {
                var res = res_val;
                defer res.deinit(self.allocator);
                for (res.batches.items) |*batch| {
                    var sit = self.v2.spaces.slots.valueIterator();
                    while (sit.next()) |slot| {
                        if (slot.projection) |proj| {
                            if (proj.watcher_mount_id) |mid| {
                                if (mid == batch.mount_id) {
                                    _ = proj.ingestMountBatch(batch) catch {};
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        var sit2 = self.v2.spaces.slots.valueIterator();
        while (sit2.next()) |slot| {
            if (slot.projection) |proj| {
                if (proj.isDirty()) {
                    _ = proj.ingestDirty() catch {};
                }
            }
        }

        if (self.v2.runtime.listThreads(self.allocator, null) catch null) |threads| {
            defer {
                for (threads) |*t| t.deinit(self.allocator);
                self.allocator.free(threads);
            }
            for (threads) |ts| {
                if (self.v2.runtime.pollDueTriggers(self.allocator, ts.thread_id, now_ms) catch null) |due| {
                    defer thread_rt_mod.freeDueTriggers(self.allocator, due);
                    for (due) |dt| {
                        const outcome = self.v2.runtime.fireTrigger(ts.thread_id, dt.trigger_id, dt.event_token, now_ms) catch continue;
                        if (outcome == .fired) {
                            self.emitV2Event("v2_trigger_fired");
                        }
                    }
                }
            }
        }

        self.v2.resources.refreshGovernorStats();
    }

    fn emitV2Event(self: *PlaygroundServer, kind: []const u8) void {
        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\"}}", .{kind}) catch return;
        self.broadcastSse(json);
    }

    fn hibernateSpaceByIdLocked(self: *PlaygroundServer, space_id: u128) !struct { hibernated: bool, state: space_mgr_mod.SlotState } {
        if (self.v2.spaces.get(space_id) == null) return error.SpaceNotFound;
        const slot = self.v2.spaces.slots.getPtr(space_id) orelse return error.SpaceNotFound;
        if (slot.state != .hot or slot.pin_count > 0) {
            return .{ .hibernated = false, .state = slot.state };
        }
        if (slot.projection) |proj| {
            proj.hibernate();
        } else if (slot.space) |sp| {
            sp.hibernate();
        }
        slot.state = .warm;
        self.v2.resources.governor.decHot();
        const new_bytes: usize = if (slot.space) |sp| sp.approxMemoryBytes() else 0;
        if (new_bytes > slot.approx_bytes) {
            self.v2.resources.governor.addWorkspaceBytes(new_bytes - slot.approx_bytes);
        } else if (slot.approx_bytes > new_bytes) {
            self.v2.resources.governor.subWorkspaceBytes(slot.approx_bytes - new_bytes);
        }
        slot.approx_bytes = new_bytes;
        self.v2.resources.refreshGovernorStats();
        return .{ .hibernated = true, .state = slot.state };
    }

    fn routeV2Api(
        self: *PlaygroundServer,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v2/health")) {
            return self.handleV2Health(out);
        }
        if (std.mem.eql(u8, path, "/api/v2/projects") or std.mem.startsWith(u8, path, "/api/v2/projects/")) {
            return self.handleV2Projects(method, path, body, out);
        }
        if (std.mem.eql(u8, path, "/api/v2/spaces") or std.mem.startsWith(u8, path, "/api/v2/spaces/")) {
            return self.handleV2Spaces(method, path, query, body, out);
        }
        if (std.mem.eql(u8, path, "/api/v2/threads") or std.mem.startsWith(u8, path, "/api/v2/threads/")) {
            return self.handleV2Threads(method, path, query, body, out);
        }
        return error.InvalidRoute;
    }

    fn handleV2Health(self: *PlaygroundServer, out: *std.ArrayList(u8)) !void {
        self.v2_mu.lockUncancelable(self.io);
        defer self.v2_mu.unlock(self.io);

        self.v2.resources.refreshGovernorStats();
        const stats = self.v2.resources.governor.snapshot();
        const hot = self.v2.spaces.hotCount();
        const warm = self.v2.spaces.warmCount();
        const cold = self.v2.spaces.coldCount();
        const open_spaces = hot + warm;
        const hibernated_spaces = warm + cold;
        const projects_count = self.v2.projects.list().len;
        const threads = try self.v2.runtime.listThreads(self.allocator, null);
        defer {
            for (threads) |*t| t.deinit(self.allocator);
            self.allocator.free(threads);
        }
        const watcher_fds: usize = if (self.v2.resources.watcher) |w| w.fdCount() else 0;
        const mem_bytes = stats.workspace_bytes + stats.blob_bytes + stats.git_delta_bytes;

        var rhex: [32]u8 = undefined;
        _ = id.formatIdHex(self.v2.runner_id, &rhex);
        var dhex: [32]u8 = undefined;
        _ = id.formatIdHex(self.v2.device_id, &dhex);

        try out.print(
            self.allocator,
            "{{\"ok\":true,\"open_spaces\":{d},\"total_spaces\":{d},\"hot_spaces\":{d},\"warm_spaces\":{d},\"cold_spaces\":{d},\"hibernated_spaces\":{d},\"projects_count\":{d},\"threads_count\":{d},\"memory_governor_bytes\":{d},\"workspace_bytes\":{d},\"blob_bytes\":{d},\"git_delta_bytes\":{d},\"watcher_fds\":{d},\"watch_count\":{d},\"runner_id\":\"{s}\",\"device_id\":\"{s}\"}}",
            .{
                open_spaces,
                self.v2.spaces.spaceCount(),
                hot,
                warm,
                cold,
                hibernated_spaces,
                projects_count,
                threads.len,
                mem_bytes,
                stats.workspace_bytes,
                stats.blob_bytes,
                stats.git_delta_bytes,
                watcher_fds,
                stats.watch_count,
                rhex,
                dhex,
            },
        );
    }

    fn handleV2Projects(
        self: *PlaygroundServer,
        method: []const u8,
        path: []const u8,
        body: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        if (std.mem.eql(u8, path, "/api/v2/projects")) {
            if (std.mem.eql(u8, method, "GET")) {
                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                try out.appendSlice(self.allocator, "{\"projects\":[");
                for (self.v2.projects.list(), 0..) |*p, i| {
                    if (i > 0) try out.append(self.allocator, ',');
                    try appendV2ProjectJson(self.allocator, out, p);
                }
                try out.appendSlice(self.allocator, "]}");
                return;
            }
            if (std.mem.eql(u8, method, "POST")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const name = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "name")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse return error.MissingName;
                const instructions = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "instructions")) orelse "";
                const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "default_provider")) orelse "mock";
                const prov_id = parseProviderSlug(prov_slug);
                const def_model = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "default_model"));

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);

                var proj = try self.v2.projects.create(name, instructions, @backingInt(prov_id), def_model);
                const pid = proj.project_id;
                proj.deinit(self.allocator);

                if (rpc.jsonObjGet(parsed.value, "space_ids")) |sids_val| {
                    if (sids_val == .array) {
                        for (sids_val.array.items) |item| {
                            var sid: u128 = 0;
                            var alias_opt: ?[]const u8 = null;
                            var access_u8: u8 = @backingInt(thread_model.SpaceAccess.shared_rw);
                            if (item == .string) {
                                sid = try id.parseIdHex(item.string);
                            } else if (item == .object) {
                                const sid_str = rpc.jsonStr(rpc.jsonObjGet(item, "space_id")) orelse return error.InvalidSpaceId;
                                sid = try id.parseIdHex(sid_str);
                                alias_opt = rpc.jsonStr(rpc.jsonObjGet(item, "alias")) orelse rpc.jsonStr(rpc.jsonObjGet(item, "role"));
                                if (rpc.jsonStr(rpc.jsonObjGet(item, "access"))) |acc_s| {
                                    access_u8 = @backingInt(parseV2SpaceAccess(acc_s));
                                }
                            } else {
                                return error.InvalidSpaceId;
                            }
                            const rec = self.v2.spaces.get(sid) orelse return error.SpaceNotFound;
                            try self.v2.projects.addSpace(pid, .{
                                .space_id = sid,
                                .alias = @constCast(alias_opt orelse rec.title),
                                .kind = rec.kind,
                                .default_access = access_u8,
                                .git_remote_url = rec.git_remote_url,
                            });
                        }
                    }
                }

                const stored = self.v2.projects.get(pid) orelse return error.ProjectNotFound;
                const proj_sids = try self.allocator.alloc(u128, stored.spaces.len);
                defer self.allocator.free(proj_sids);
                for (stored.spaces, 0..) |sr, idx| proj_sids[idx] = sr.space_id;
                _ = self.v2.catalog.putProject(.{
                    .project_id = stored.project_id,
                    .name = stored.title,
                    .space_ids = proj_sids,
                    .default_provider = prov_id,
                    .updated_ms = stored.updated_ms,
                    .actor = self.v2.runner_id,
                }) catch {};

                try out.appendSlice(self.allocator, "{\"project\":");
                try appendV2ProjectJson(self.allocator, out, stored);
                try out.append(self.allocator, '}');
                self.emitV2Event("v2_updated");
                return;
            }
            return error.InvalidRoute;
        }

        const rest = path["/api/v2/projects/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidRoute;
        const pid = try id.parseIdHex(rest[0..slash]);
        const sub = rest[slash + 1 ..];

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "spaces")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const sid_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "space_id")) orelse return error.InvalidSpaceId;
            const sid = try id.parseIdHex(sid_str);
            const alias_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "alias")) orelse rpc.jsonStr(rpc.jsonObjGet(parsed.value, "role"));
            const acc_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "access")) orelse "shared_rw";
            const acc = parseV2SpaceAccess(acc_str);

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const rec = self.v2.spaces.get(sid) orelse return error.SpaceNotFound;
            try self.v2.projects.addSpace(pid, .{
                .space_id = sid,
                .alias = @constCast(alias_opt orelse rec.title),
                .kind = rec.kind,
                .default_access = @backingInt(acc),
                .git_remote_url = rec.git_remote_url,
            });
            const stored = self.v2.projects.get(pid) orelse return error.ProjectNotFound;
            try out.appendSlice(self.allocator, "{\"ok\":true,\"project\":");
            try appendV2ProjectJson(self.allocator, out, stored);
            try out.append(self.allocator, '}');
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "DELETE") and std.mem.startsWith(u8, sub, "spaces/")) {
            const sid = try id.parseIdHex(sub["spaces/".len..]);
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const removed = try self.v2.projects.removeSpace(pid, sid);
            try out.print(self.allocator, "{{\"ok\":true,\"removed\":{}}}", .{removed});
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "fork")) {
            var title_prefix: []const u8 = "fork";
            var project_locally = false;
            var parsed_opt: ?std.json.Parsed(std.json.Value) = null;
            defer if (parsed_opt) |*p| p.deinit();
            if (body.len > 0) {
                parsed_opt = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                if (rpc.jsonStr(rpc.jsonObjGet(parsed_opt.?.value, "title_prefix"))) |tp| title_prefix = tp;
                if (rpc.jsonBool(rpc.jsonObjGet(parsed_opt.?.value, "project_locally"))) |pl| project_locally = pl;
            }

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const proj = self.v2.projects.get(pid) orelse return error.ProjectNotFound;
            const sids = try self.allocator.alloc(u128, proj.spaces.len);
            defer self.allocator.free(sids);
            for (proj.spaces, 0..) |sr, i| sids[i] = sr.space_id;

            const forked_ids = try project_mod.SpaceSet.forkSpaceSet(self.allocator, &self.v2.spaces, sids, title_prefix, project_locally);
            defer self.allocator.free(forked_ids);

            var phex: [32]u8 = undefined;
            _ = id.formatIdHex(pid, &phex);
            try out.print(self.allocator, "{{\"project_id\":\"{s}\",\"forked_space_ids\":[", .{phex});
            for (forked_ids, 0..) |fid, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var fhex: [32]u8 = undefined;
                _ = id.formatIdHex(fid, &fhex);
                try out.print(self.allocator, "\"{s}\"", .{fhex});
            }
            try out.appendSlice(self.allocator, "]}");
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "sync")) {
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const fork_ids = try self.resolveProjectForkIdsLocked(pid, body);
            defer self.allocator.free(fork_ids);

            const entries = try project_mod.SpaceSet.syncSpaceSet(self.allocator, &self.v2.spaces, fork_ids);
            defer {
                for (entries) |*e| e.deinit(self.allocator);
                self.allocator.free(entries);
            }

            try out.appendSlice(self.allocator, "{\"synced\":[");
            for (entries, 0..) |e, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var shex: [32]u8 = undefined;
                var ohex: [32]u8 = undefined;
                _ = id.formatIdHex(e.space_id, &shex);
                _ = id.formatIdHex(e.origin_space_id, &ohex);
                try out.print(
                    self.allocator,
                    "{{\"space_id\":\"{s}\",\"origin_space_id\":\"{s}\",\"brought\":{d},\"merged_count\":{d},\"conflict_count\":{d}}}",
                    .{ shex, ohex, e.report.brought, e.report.merged.len, e.report.conflicts.len },
                );
            }
            try out.appendSlice(self.allocator, "]}");
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "land")) {
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const fork_ids = try self.resolveProjectForkIdsLocked(pid, body);
            defer self.allocator.free(fork_ids);

            var report = try project_mod.SpaceSet.landSpaceSet(self.allocator, &self.v2.spaces, fork_ids);
            defer report.deinit(self.allocator);

            try appendV2LandReportJson(self.allocator, out, &report);
            self.emitV2Event("v2_updated");
            return;
        }

        return error.InvalidRoute;
    }

    fn resolveProjectForkIdsLocked(self: *PlaygroundServer, pid: u128, body: []const u8) ![]u128 {
        var list: std.ArrayList(u128) = .empty;
        errdefer list.deinit(self.allocator);

        if (body.len > 0) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            if (rpc.jsonObjGet(parsed.value, "fork_ids")) |fv| {
                if (fv == .array) {
                    for (fv.array.items) |it| {
                        if (it != .string) return error.InvalidSpaceId;
                        try list.append(self.allocator, try id.parseIdHex(it.string));
                    }
                    return try list.toOwnedSlice(self.allocator);
                }
            }
        }

        const proj = self.v2.projects.get(pid) orelse return error.ProjectNotFound;
        for (proj.spaces) |sr| {
            if (self.v2.spaces.get(sr.space_id)) |rec| {
                if (rec.origin != null) {
                    try list.append(self.allocator, sr.space_id);
                }
            }
        }
        return try list.toOwnedSlice(self.allocator);
    }

    fn handleV2Spaces(
        self: *PlaygroundServer,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        if (std.mem.eql(u8, path, "/api/v2/spaces")) {
            if (std.mem.eql(u8, method, "GET")) {
                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                try out.appendSlice(self.allocator, "{\"spaces\":[");
                for (self.v2.spaces.list(), 0..) |*rec, i| {
                    if (i > 0) try out.append(self.allocator, ',');
                    try self.appendV2SpaceJsonLocked(out, rec);
                }
                try out.appendSlice(self.allocator, "]}");
                return;
            }
            if (std.mem.eql(u8, method, "POST")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const name = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "name")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse return error.MissingName;
                const kind_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "kind")) orelse "virtual";
                const local_path_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path"));

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);

                var rec = if (std.mem.eql(u8, kind_str, "virtual") and local_path_opt == null)
                    try self.v2.spaces.createVirtual(name)
                else if (std.mem.eql(u8, kind_str, "dir") or std.mem.eql(u8, kind_str, "git_worktree") or local_path_opt != null) blk: {
                    const lp = local_path_opt orelse return error.MissingPath;
                    if (lp.len == 0) return error.MissingPath;
                    break :blk try self.v2.spaces.adoptLocal(lp, name);
                } else return error.InvalidKind;
                defer rec.deinit(self.allocator);

                const proj_lp: ?[]u8 = if (self.v2.spaces.getProjectionRecord(rec.space_id)) |pr| pr.local_path else null;
                _ = self.v2.catalog.putSpace(.{
                    .space_id = rec.space_id,
                    .name = rec.title,
                    .kind = switch (rec.kind) {
                        .virtual => .virtual,
                        .dir => .dir,
                        .git_worktree => .git_worktree,
                    },
                    .local_path = proj_lp,
                    .remote_url = rec.git_remote_url,
                    .updated_ms = rec.updated_ms,
                    .actor = self.v2.runner_id,
                }) catch {};

                const stored = self.v2.spaces.get(rec.space_id) orelse &rec;
                try out.appendSlice(self.allocator, "{\"space\":");
                try self.appendV2SpaceJsonLocked(out, stored);
                try out.append(self.allocator, '}');
                self.emitV2Event("v2_updated");
                return;
            }
            return error.InvalidRoute;
        }

        const rest = path["/api/v2/spaces/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidRoute;
        const sid = try id.parseIdHex(rest[0..slash]);
        const sub = rest[slash + 1 ..];

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "fork")) {
            var title: []const u8 = "fork";
            var project_locally = false;
            var parsed_opt: ?std.json.Parsed(std.json.Value) = null;
            defer if (parsed_opt) |*p| p.deinit();
            if (body.len > 0) {
                parsed_opt = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                if (rpc.jsonStr(rpc.jsonObjGet(parsed_opt.?.value, "name")) orelse rpc.jsonStr(rpc.jsonObjGet(parsed_opt.?.value, "title"))) |t| title = t;
                if (rpc.jsonBool(rpc.jsonObjGet(parsed_opt.?.value, "project_locally"))) |pl| project_locally = pl;
            }

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            var rec = try self.v2.spaces.forkSpace(sid, title, project_locally);
            defer rec.deinit(self.allocator);
            const stored = self.v2.spaces.get(rec.space_id) orelse &rec;
            try out.appendSlice(self.allocator, "{\"space\":");
            try self.appendV2SpaceJsonLocked(out, stored);
            try out.append(self.allocator, '}');
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "hibernate")) {
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const res = try self.hibernateSpaceByIdLocked(sid);
            try out.print(
                self.allocator,
                "{{\"ok\":true,\"hibernated\":{},\"state\":\"{s}\"}}",
                .{ res.hibernated, slotStateName(res.state) },
            );
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "compact")) {
            var policy = space_mod.CompactPolicy{};
            if (body.len > 0) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                if (rpc.jsonU64(rpc.jsonObjGet(parsed.value, "retain_latest_batches"))) |v| policy.retain_latest_batches = @intCast(v);
                if (rpc.jsonU64(rpc.jsonObjGet(parsed.value, "retain_ms"))) |v| policy.retain_ms = v;
                if (rpc.jsonBool(rpc.jsonObjGet(parsed.value, "force_gc"))) |v| policy.force_gc = v;
            }
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            const st = try sp.compactWithPolicy(policy);
            try out.print(
                self.allocator,
                "{{\"ok\":true,\"pruned_batches\":{d},\"reclaimed_batch_bytes\":{d},\"removed_blobs\":{d},\"reclaimed_blob_bytes\":{d},\"removed_segments\":{d},\"rewritten_segments\":{d},\"base_size_bytes\":{d}}}",
                .{
                    st.pruned_batches,
                    st.reclaimed_batch_bytes,
                    st.removed_blobs,
                    st.reclaimed_blob_bytes,
                    st.removed_segments,
                    st.rewritten_segments,
                    st.base_size_bytes,
                },
            );
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "files")) {
            const dir_opt = try queryParamAlloc(self.allocator, query, "dir");
            defer if (dir_opt) |d| self.allocator.free(d);
            const rec_opt = try queryParamAlloc(self.allocator, query, "recursive");
            defer if (rec_opt) |r| self.allocator.free(r);
            const base_dir = dir_opt orelse "";
            const recursive = if (rec_opt) |r| !std.mem.eql(u8, r, "0") else (dir_opt == null);

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);

            var entries: std.ArrayList(V2FileItem) = .empty;
            defer {
                for (entries.items) |*e| e.deinit(self.allocator);
                entries.deinit(self.allocator);
            }
            try collectSpaceFiles(self.allocator, sp, base_dir, recursive, 0, &entries);

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"dir\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, base_dir);
            try out.appendSlice(self.allocator, ",\"files\":[");
            for (entries.items, 0..) |e, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try out.appendSlice(self.allocator, "{\"path\":");
                try rpc.appendJsonEscaped(self.allocator, out, e.path);
                try out.appendSlice(self.allocator, ",\"name\":");
                try rpc.appendJsonEscaped(self.allocator, out, e.name);
                try out.print(self.allocator, ",\"kind\":\"{s}\"}}", .{dirEntryKindName(e.kind)});
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "file")) {
            const rel_path = (try queryParamAlloc(self.allocator, query, "path")) orelse return error.MissingPath;
            defer self.allocator.free(rel_path);
            if (!isSafeRelPath(rel_path)) return error.InvalidPath;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            const content_opt = try sp.readFileAlloc(self.allocator, rel_path);
            defer if (content_opt) |c| self.allocator.free(c);

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"path\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, rel_path);
            try out.print(self.allocator, ",\"exists\":{},\"content\":", .{content_opt != null});
            if (content_opt) |c| {
                try rpc.appendJsonEscaped(self.allocator, out, c);
            } else {
                try out.appendSlice(self.allocator, "null");
            }
            try out.append(self.allocator, '}');
            return;
        }

        if (std.mem.eql(u8, method, "PUT") and std.mem.eql(u8, sub, "file")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const rel_path = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path")) orelse return error.MissingPath;
            const content = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "content")) orelse return error.MissingContent;
            if (!isSafeRelPath(rel_path)) return error.InvalidPath;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            const bid = try sp.putFile(self.v2.runner_id, rel_path, content);
            if (try self.v2.spaces.activateProjection(sid)) |proj| {
                proj.materializeFile(rel_path) catch {};
            }

            var shex: [32]u8 = undefined;
            var ahex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            _ = id.formatIdHex(bid.actor, &ahex);
            try out.print(self.allocator, "{{\"ok\":true,\"space_id\":\"{s}\",\"path\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, rel_path);
            try out.print(self.allocator, ",\"batch_ts\":{d},\"batch_actor\":\"{s}\"}}", .{ bid.ts, ahex });
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "DELETE") and std.mem.eql(u8, sub, "file")) {
            const rel_alloc: ?[]u8 = try queryParamAlloc(self.allocator, query, "path");
            defer if (rel_alloc) |p| self.allocator.free(p);
            var parsed_opt: ?std.json.Parsed(std.json.Value) = null;
            defer if (parsed_opt) |*p| p.deinit();
            var rel_path: []const u8 = "";
            if (rel_alloc) |p| {
                rel_path = p;
            } else if (body.len > 0) {
                parsed_opt = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                rel_path = rpc.jsonStr(rpc.jsonObjGet(parsed_opt.?.value, "path")) orelse return error.MissingPath;
            } else {
                return error.MissingPath;
            }
            if (!isSafeRelPath(rel_path)) return error.InvalidPath;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            const deleted_bid = try sp.deletePath(self.v2.runner_id, rel_path);
            if (try self.v2.spaces.activateProjection(sid)) |proj| {
                proj.materializeChanged() catch {};
            }
            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"ok\":true,\"space_id\":\"{s}\",\"path\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, rel_path);
            try out.print(self.allocator, ",\"deleted\":{}}}", .{deleted_bid != null});
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "search")) {
            const q_str = (try queryParamAlloc(self.allocator, query, "q")) orelse return error.MissingQuery;
            defer self.allocator.free(q_str);
            const prefix_opt = try queryParamAlloc(self.allocator, query, "prefix");
            defer if (prefix_opt) |p| self.allocator.free(p);
            const lim_opt = try queryParamAlloc(self.allocator, query, "limit");
            defer if (lim_opt) |l| self.allocator.free(l);
            const limit: usize = if (lim_opt) |l| std.fmt.parseInt(usize, l, 10) catch 50 else 50;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            const hits = try sp.searchText(self.allocator, q_str, prefix_opt, @min(limit, 500));
            defer {
                for (hits) |*h| h.deinit(self.allocator);
                self.allocator.free(hits);
            }

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"query\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, q_str);
            try out.appendSlice(self.allocator, ",\"hits\":[");
            for (hits, 0..) |h, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try out.appendSlice(self.allocator, "{\"path\":");
                try rpc.appendJsonEscaped(self.allocator, out, h.path);
                try out.print(self.allocator, ",\"line\":{d},\"snippet\":", .{h.line});
                try rpc.appendJsonEscaped(self.allocator, out, h.snippet);
                try out.append(self.allocator, '}');
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "meta")) {
            const key_opt = try queryParamAlloc(self.allocator, query, "key");
            defer if (key_opt) |k| self.allocator.free(k);
            const prefix_opt = try queryParamAlloc(self.allocator, query, "prefix");
            defer if (prefix_opt) |p| self.allocator.free(p);

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);

            if (key_opt) |k| {
                const val = sp.getMeta(k);
                try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"key\":", .{shex});
                try rpc.appendJsonEscaped(self.allocator, out, k);
                try out.appendSlice(self.allocator, ",\"value\":");
                if (val) |v| {
                    try rpc.appendJsonEscaped(self.allocator, out, v);
                } else {
                    try out.appendSlice(self.allocator, "null");
                }
                try out.append(self.allocator, '}');
                return;
            }

            const pref = prefix_opt orelse "";
            const entries = try sp.listMetaPrefix(self.allocator, pref);
            defer {
                for (entries) |*e| e.deinit(self.allocator);
                self.allocator.free(entries);
            }
            try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"prefix\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, pref);
            try out.appendSlice(self.allocator, ",\"entries\":[");
            for (entries, 0..) |e, i| {
                if (i > 0) try out.append(self.allocator, ',');
                try out.appendSlice(self.allocator, "{\"key\":");
                try rpc.appendJsonEscaped(self.allocator, out, e.key);
                try out.appendSlice(self.allocator, ",\"value\":");
                try rpc.appendJsonEscaped(self.allocator, out, e.value);
                try out.append(self.allocator, '}');
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "PUT") and std.mem.eql(u8, sub, "meta")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const key = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "key")) orelse return error.MissingKey;
            const val_raw = rpc.jsonObjGet(parsed.value, "value");
            const val_opt: ?[]const u8 = if (val_raw) |vr| switch (vr) {
                .null => null,
                .string => |s| s,
                else => return error.InvalidValue,
            } else null;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            _ = try sp.setMeta(self.v2.runner_id, key, val_opt);

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"ok\":true,\"space_id\":\"{s}\",\"key\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, key);
            try out.appendSlice(self.allocator, ",\"value\":");
            if (val_opt) |v| {
                try rpc.appendJsonEscaped(self.allocator, out, v);
            } else {
                try out.appendSlice(self.allocator, "null");
            }
            try out.append(self.allocator, '}');
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "timeline")) {
            const lim_opt = try queryParamAlloc(self.allocator, query, "limit");
            defer if (lim_opt) |l| self.allocator.free(l);
            const limit: usize = if (lim_opt) |l| std.fmt.parseInt(usize, l, 10) catch 50 else 50;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);
            const entries = try timeline_mod.listEntriesForSpace(self.allocator, sp, null, @min(limit, 500));
            defer timeline_mod.freeTimelineEntries(self.allocator, entries);

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"entries\":[", .{shex});
            for (entries, 0..) |e, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var ahex: [32]u8 = undefined;
                _ = id.formatIdHex(e.batch_id.actor, &ahex);
                try out.print(
                    self.allocator,
                    "{{\"batch_id\":{{\"ts\":{d},\"actor\":\"{s}\"}},\"wall_ms\":{d},\"total_added\":{d},\"total_removed\":{d},\"files\":[",
                    .{ e.batch_id.ts, ahex, e.wall_ms, e.total_added, e.total_removed },
                );
                for (e.files, 0..) |f, j| {
                    if (j > 0) try out.append(self.allocator, ',');
                    try out.appendSlice(self.allocator, "{\"path\":");
                    try rpc.appendJsonEscaped(self.allocator, out, f.path);
                    try out.print(
                        self.allocator,
                        ",\"kind\":\"{s}\",\"added_lines\":{d},\"removed_lines\":{d}}}",
                        .{ changeKindName(f.kind), f.added_lines, f.removed_lines },
                    );
                }
                try out.appendSlice(self.allocator, "]}");
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "diff")) {
            const ts_opt = try queryParamAlloc(self.allocator, query, "ts");
            defer if (ts_opt) |t| self.allocator.free(t);
            const actor_opt = try queryParamAlloc(self.allocator, query, "actor");
            defer if (actor_opt) |a| self.allocator.free(a);

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            try self.v2.spaces.pin(sid);
            defer self.v2.spaces.unpin(sid);
            const sp = try self.v2.spaces.activate(sid);

            var bids_buf: [1]id.BatchId = undefined;
            var bids_len: usize = 0;
            if (ts_opt != null and actor_opt != null) {
                const ts = try std.fmt.parseInt(u64, ts_opt.?, 10);
                const actor = try id.parseIdHex(actor_opt.?);
                bids_buf[0] = id.BatchId.init(ts, actor);
                bids_len = 1;
            } else {
                const latest = try timeline_mod.listEntriesForSpace(self.allocator, sp, null, 1);
                defer timeline_mod.freeTimelineEntries(self.allocator, latest);
                if (latest.len > 0) {
                    bids_buf[0] = latest[0].batch_id;
                    bids_len = 1;
                }
            }

            const diff_text = try timeline_mod.unifiedDiffForSpace(self.allocator, sp, bids_buf[0..bids_len]);
            defer self.allocator.free(diff_text);

            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sid, &shex);
            try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"diff\":", .{shex});
            try rpc.appendJsonEscaped(self.allocator, out, diff_text);
            try out.append(self.allocator, '}');
            return;
        }

        return error.InvalidRoute;
    }

    fn handleV2Threads(
        self: *PlaygroundServer,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        if (std.mem.eql(u8, path, "/api/v2/threads")) {
            if (std.mem.eql(u8, method, "GET")) {
                const pid_opt_str = try queryParamAlloc(self.allocator, query, "project_id");
                defer if (pid_opt_str) |s| self.allocator.free(s);
                const pid_filter: ?u128 = if (pid_opt_str) |s| if (s.len > 0) try id.parseIdHex(s) else null else null;

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                const summaries = try self.v2.runtime.listThreads(self.allocator, pid_filter);
                defer {
                    for (summaries) |*s| s.deinit(self.allocator);
                    self.allocator.free(summaries);
                }

                try out.appendSlice(self.allocator, "{\"threads\":[");
                for (summaries, 0..) |s, i| {
                    if (i > 0) try out.append(self.allocator, ',');
                    const active_turn: ?u128 = if (self.v2.runtime.active_turns.get(s.thread_id)) |at| at.turn_id else null;
                    if (self.v2.runtime.getThreadMeta(self.allocator, s.thread_id) catch null) |meta_val| {
                        var meta = meta_val;
                        defer meta.deinit(self.allocator);
                        try appendV2ThreadMetaJson(self.allocator, out, &meta, active_turn, s.message_count, s.active_tasks, s.unread_mailbox);
                    } else {
                        try appendV2ThreadSummaryFallbackJson(self.allocator, out, &s, active_turn);
                    }
                }
                try out.appendSlice(self.allocator, "]}");
                return;
            }

            if (std.mem.eql(u8, method, "POST")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "Untitled V2 Thread";
                const pid_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "project_id"));
                const project_id: ?u128 = if (pid_str) |ps| if (ps.len > 0) try id.parseIdHex(ps) else null else null;
                const prov_slug = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider_id")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider")) orelse "mock";
                const prov_id = parseProviderSlug(prov_slug);
                const model_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model"));
                const sys_prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "system_prompt"));
                const budget = parseV2Budget(rpc.jsonObjGet(parsed.value, "budget"));

                var bindings: std.ArrayList(thread_model.SpaceBinding) = .empty;
                defer {
                    for (bindings.items) |*b| b.deinit(self.allocator);
                    bindings.deinit(self.allocator);
                }

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);

                if (rpc.jsonObjGet(parsed.value, "bindings")) |bval| {
                    if (bval == .array) {
                        for (bval.array.items) |item| {
                            const b = try self.parseBindingItemLocked(item);
                            try bindings.append(self.allocator, b);
                        }
                    }
                }

                var meta = try self.v2.runtime.createThread(.{
                    .title = title,
                    .project_id = project_id,
                    .bindings = bindings.items,
                    .budget = budget,
                    .provider_id = prov_id,
                    .model = model_opt,
                    .system_prompt = sys_prompt,
                });
                defer meta.deinit(self.allocator);

                try out.appendSlice(self.allocator, "{\"thread\":");
                try appendV2ThreadMetaJson(self.allocator, out, &meta, null, 0, 0, 0);
                try out.append(self.allocator, '}');
                self.emitV2Event("v2_updated");
                return;
            }
            return error.InvalidRoute;
        }

        const rest = path["/api/v2/threads/".len..];
        const slash_opt = std.mem.indexOfScalar(u8, rest, '/');
        if (slash_opt == null) {
            if (!std.mem.eql(u8, method, "GET")) return error.InvalidRoute;
            const tid = try id.parseIdHex(rest);
            return self.handleV2ThreadDetail(tid, out);
        }

        const tid = try id.parseIdHex(rest[0..slash_opt.?]);
        const sub = rest[slash_opt.? + 1 ..];

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "bind")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            var b = try self.parseBindingItemLocked(parsed.value);
            defer b.deinit(self.allocator);
            try self.v2.runtime.bindSpace(tid, b);
            var meta = (try self.v2.runtime.getThreadMeta(self.allocator, tid)) orelse return error.ThreadNotFound;
            defer meta.deinit(self.allocator);
            const active_turn: ?u128 = if (self.v2.runtime.active_turns.get(tid)) |at| at.turn_id else null;
            try out.appendSlice(self.allocator, "{\"ok\":true,\"thread\":");
            try appendV2ThreadMetaJson(self.allocator, out, &meta, active_turn, 0, 0, 0);
            try out.append(self.allocator, '}');
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "DELETE") and std.mem.startsWith(u8, sub, "bind/")) {
            const sid = try id.parseIdHex(sub["bind/".len..]);
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const removed = try self.v2.runtime.unbindSpace(tid, sid);
            try out.print(self.allocator, "{{\"ok\":true,\"removed\":{}}}", .{removed});
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "turns")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse return error.MissingPrompt;
            const reply_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "reply")) orelse
                rpc.jsonStr(rpc.jsonObjGet(parsed.value, "assistant_text"));
            const prov_opt: ?iface.ProviderId = if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider_id")) orelse rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider"))) |ps|
                parseProviderSlug(ps)
            else
                null;
            const model_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model"));
            const parent_msg_id: ?u128 = if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "parent_msg_id"))) |ps|
                if (ps.len > 0) try id.parseIdHex(ps) else null
            else
                null;
            const usage = thread_rt_mod.TurnUsage{
                .tokens = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "tokens")) orelse 0,
                .cost_microusd = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "cost_microusd")) orelse 0,
                .wall_ms = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "wall_ms")) orelse 0,
            };

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);

            var begin_res = try self.v2.runtime.beginTurn(tid, prompt, .{
                .provider = prov_opt,
                .model = model_opt,
                .parent_msg_id = parent_msg_id,
            });
            defer begin_res.deinit(self.allocator);
            var completed = false;
            errdefer if (!completed) {
                self.v2.runtime.cancelTurn(tid, begin_res.turn_id) catch {};
            };

            if (rpc.jsonObjGet(parsed.value, "mutations")) |mval| {
                if (mval == .array) {
                    const store = try self.v2.runtime.openThread(tid);
                    const meta = store.meta orelse return error.ThreadNotFound;
                    for (mval.array.items) |mut| {
                        const sid_str = rpc.jsonStr(rpc.jsonObjGet(mut, "space_id")) orelse return error.InvalidSpaceId;
                        const sid = try id.parseIdHex(sid_str);
                        const rel_path = rpc.jsonStr(rpc.jsonObjGet(mut, "path")) orelse return error.MissingPath;
                        const content = rpc.jsonStr(rpc.jsonObjGet(mut, "content")) orelse return error.MissingContent;
                        if (!isSafeRelPath(rel_path)) return error.InvalidPath;
                        var writable = false;
                        for (meta.bindings) |b| {
                            if (b.space_id == sid) {
                                writable = (b.access != .read_only);
                                break;
                            }
                        }
                        if (!writable) return error.AccessEscalation;
                        try self.v2.spaces.pin(sid);
                        defer self.v2.spaces.unpin(sid);
                        const sp = try self.v2.spaces.activate(sid);
                        _ = try sp.putFile(self.v2.runner_id, rel_path, content);
                        if (try self.v2.spaces.activateProjection(sid)) |proj| {
                            proj.materializeFile(rel_path) catch {};
                        }
                    }
                }
            }

            const default_reply = if (reply_opt == null)
                try std.fmt.allocPrint(self.allocator, "Acknowledged: {s}", .{prompt})
            else
                null;
            defer if (default_reply) |r| self.allocator.free(r);
            const assistant_text = reply_opt orelse default_reply.?;

            var post_cp = try self.v2.runtime.completeTurn(tid, begin_res.turn_id, assistant_text, &.{}, usage, null);
            defer post_cp.deinit(self.allocator);
            completed = true;

            var turn_hex: [32]u8 = undefined;
            var umsg_hex: [32]u8 = undefined;
            _ = id.formatIdHex(begin_res.turn_id, &turn_hex);
            _ = id.formatIdHex(begin_res.user_msg_id, &umsg_hex);
            try out.print(
                self.allocator,
                "{{\"turn_id\":\"{s}\",\"user_msg_id\":\"{s}\",\"fencing_epoch\":{d},\"assistant_text\":",
                .{ turn_hex, umsg_hex, begin_res.fencing_epoch },
            );
            try rpc.appendJsonEscaped(self.allocator, out, assistant_text);
            try out.appendSlice(self.allocator, ",\"pre_checkpoint\":");
            try appendV2CheckpointVectorJson(self.allocator, out, &begin_res.pre_checkpoint);
            try out.appendSlice(self.allocator, ",\"post_checkpoint\":");
            try appendV2CheckpointVectorJson(self.allocator, out, &post_cp);
            try out.append(self.allocator, '}');
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "rollback")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const mid_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "message_id")) orelse
                rpc.jsonStr(rpc.jsonObjGet(parsed.value, "msg_id")) orelse return error.MissingMessageId;
            const mid = try id.parseIdHex(mid_str);
            const use_pre = rpc.jsonBool(rpc.jsonObjGet(parsed.value, "use_pre_checkpoint")) orelse false;

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const res = try self.v2.runtime.rollbackThreadToMessage(tid, mid, .{
                .use_pre_checkpoint = use_pre,
            });
            var ihex: [32]u8 = undefined;
            _ = id.formatIdHex(res.intent_id, &ihex);
            try out.print(
                self.allocator,
                "{{\"ok\":true,\"intent_id\":\"{s}\",\"spaces_rolled_back\":{d},\"completed\":{}}}",
                .{ ihex, res.spaces_rolled_back, res.completed },
            );
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "recover-rollbacks")) {
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const res_opt = try self.v2.runtime.recoverPendingRollbacks(tid);
            if (res_opt) |res| {
                var ihex: [32]u8 = undefined;
                _ = id.formatIdHex(res.intent_id, &ihex);
                try out.print(
                    self.allocator,
                    "{{\"ok\":true,\"recovered\":true,\"intent_id\":\"{s}\",\"spaces_rolled_back\":{d},\"completed\":{}}}",
                    .{ ihex, res.spaces_rolled_back, res.completed },
                );
            } else {
                try out.appendSlice(self.allocator, "{\"ok\":true,\"recovered\":false}");
            }
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, sub, "tasks")) {
            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const store = try self.v2.runtime.openThread(tid);
            var thex: [32]u8 = undefined;
            _ = id.formatIdHex(tid, &thex);
            try out.print(self.allocator, "{{\"thread_id\":\"{s}\",\"tasks\":[", .{thex});
            var it = store.tasks.valueIterator();
            var idx: usize = 0;
            while (it.next()) |task| {
                if (idx > 0) try out.append(self.allocator, ',');
                idx += 1;
                try appendV2TaskJson(self.allocator, out, task);
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "subordinates")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
            defer parsed.deinit();
            const title = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "title")) orelse "Subordinate Task";
            const prompt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse "";
            const budget = parseV2Budget(rpc.jsonObjGet(parsed.value, "budget"));
            const join_quorum: u16 = @intCast(rpc.jsonU64(rpc.jsonObjGet(parsed.value, "join_quorum")) orelse 0);
            const project_forks = rpc.jsonBool(rpc.jsonObjGet(parsed.value, "project_forks_locally")) orelse false;
            const prov_opt: ?iface.ProviderId = if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider_id")) orelse rpc.jsonStr(rpc.jsonObjGet(parsed.value, "provider"))) |ps|
                parseProviderSlug(ps)
            else
                null;
            const model_opt = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "model"));

            var grants: std.ArrayList(thread_model.SpaceBinding) = .empty;
            defer {
                for (grants.items) |*g| g.deinit(self.allocator);
                grants.deinit(self.allocator);
            }
            var deps: std.ArrayList(u128) = .empty;
            defer deps.deinit(self.allocator);
            var virt_spaces: std.ArrayList([]const u8) = .empty;
            defer virt_spaces.deinit(self.allocator);

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);

            const grants_val = rpc.jsonObjGet(parsed.value, "bindings") orelse rpc.jsonObjGet(parsed.value, "grants");
            if (grants_val) |gv| {
                if (gv == .array) {
                    for (gv.array.items) |item| {
                        try grants.append(self.allocator, try self.parseBindingItemLocked(item));
                    }
                }
            }
            if (rpc.jsonObjGet(parsed.value, "depends_on")) |dv| {
                if (dv == .array) {
                    for (dv.array.items) |item| {
                        if (item != .string) return error.InvalidTaskId;
                        try deps.append(self.allocator, try id.parseIdHex(item.string));
                    }
                }
            }
            if (rpc.jsonObjGet(parsed.value, "create_virtual_spaces")) |vv| {
                if (vv == .array) {
                    for (vv.array.items) |item| {
                        if (item == .string) try virt_spaces.append(self.allocator, item.string);
                    }
                }
            }

            var res = try self.v2.runtime.spawnSubordinate(self.allocator, tid, .{
                .title = title,
                .prompt = prompt,
                .grants = grants.items,
                .create_virtual_spaces = virt_spaces.items,
                .budget = budget,
                .depends_on = deps.items,
                .join_quorum = join_quorum,
                .project_forks_locally = project_forks,
                .provider_id = prov_opt,
                .model = model_opt,
            });
            defer res.deinit(self.allocator);

            var task_hex: [32]u8 = undefined;
            var child_hex: [32]u8 = undefined;
            _ = id.formatIdHex(res.task_id, &task_hex);
            _ = id.formatIdHex(res.child_thread_id, &child_hex);
            try out.print(
                self.allocator,
                "{{\"task_id\":\"{s}\",\"child_thread_id\":\"{s}\",\"status\":\"{s}\",\"carved_budget\":",
                .{ task_hex, child_hex, taskStatusName(res.status) },
            );
            try appendV2BudgetJson(self.allocator, out, &res.carved_budget);
            try out.appendSlice(self.allocator, ",\"forked_space_ids\":[");
            for (res.forked_space_ids, 0..) |fid, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var fhex: [32]u8 = undefined;
                _ = id.formatIdHex(fid, &fhex);
                try out.print(self.allocator, "\"{s}\"", .{fhex});
            }
            try out.appendSlice(self.allocator, "]}");
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.startsWith(u8, sub, "tasks/")) {
            const trest = sub["tasks/".len..];
            const tslash = std.mem.indexOfScalar(u8, trest, '/') orelse return error.InvalidRoute;
            const task_id = try id.parseIdHex(trest[0..tslash]);
            const taction = trest[tslash + 1 ..];

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, taction, "settle")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const status_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "status")) orelse "completed";
                const status = parseV2TaskStatus(status_str) orelse return error.InvalidTaskTransition;
                const summary = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "summary")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(parsed.value, "result_summary")) orelse "";

                var used_opt: ?thread_model.Budget = null;
                const ut = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "used_tokens"));
                const uc = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "used_cost_microusd"));
                const uw = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "used_wall_ms"));
                if (ut != null or uc != null or uw != null) {
                    used_opt = .{
                        .used_tokens = ut orelse 0,
                        .used_cost_microusd = uc orelse 0,
                        .used_wall_ms = uw orelse 0,
                    };
                }

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                const woken = try self.v2.runtime.settleTask(tid, task_id, status, summary, used_opt);
                var task_hex: [32]u8 = undefined;
                _ = id.formatIdHex(task_id, &task_hex);
                try out.print(
                    self.allocator,
                    "{{\"ok\":true,\"task_id\":\"{s}\",\"status\":\"{s}\",\"woken_tasks\":{d}}}",
                    .{ task_hex, taskStatusName(status), woken },
                );
                self.emitV2Event("v2_updated");
                return;
            }

            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, taction, "land")) {
                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                var report = try self.v2.runtime.landSubordinateForks(self.allocator, tid, task_id);
                defer report.deinit(self.allocator);
                try appendV2LandReportJson(self.allocator, out, &report);
                self.emitV2Event("v2_updated");
                return;
            }
            return error.InvalidRoute;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "cancel-tree")) {
            var reason_opt: ?[]const u8 = null;
            var parsed_opt: ?std.json.Parsed(std.json.Value) = null;
            defer if (parsed_opt) |*p| p.deinit();
            if (body.len > 0) {
                parsed_opt = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                reason_opt = rpc.jsonStr(rpc.jsonObjGet(parsed_opt.?.value, "reason"));
            }

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const rep = try self.v2.runtime.cancelTree(tid, reason_opt);
            try out.print(
                self.allocator,
                "{{\"ok\":true,\"canceled_threads\":{d},\"canceled_tasks\":{d},\"canceled_leases\":{d}}}",
                .{ rep.canceled_threads, rep.canceled_tasks, rep.canceled_leases },
            );
            self.emitV2Event("v2_updated");
            return;
        }

        if (std.mem.eql(u8, sub, "mailbox")) {
            if (std.mem.eql(u8, method, "GET")) {
                const drain_opt = try queryParamAlloc(self.allocator, query, "drain");
                defer if (drain_opt) |d| self.allocator.free(d);
                const do_drain = if (drain_opt) |d| std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true") else false;

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                var thex: [32]u8 = undefined;
                _ = id.formatIdHex(tid, &thex);
                if (do_drain) {
                    const drained = try self.v2.runtime.drainMailbox(self.allocator, tid);
                    defer {
                        for (drained) |*it| it.deinit(self.allocator);
                        self.allocator.free(drained);
                    }
                    try out.print(self.allocator, "{{\"thread_id\":\"{s}\",\"drained\":true,\"unread_count\":0,\"items\":[", .{thex});
                    for (drained, 0..) |*it, i| {
                        if (i > 0) try out.append(self.allocator, ',');
                        try appendV2MailboxItemJson(self.allocator, out, it);
                    }
                    try out.appendSlice(self.allocator, "]}");
                    return;
                }

                const store = try self.v2.runtime.openThread(tid);
                const unread = try self.v2.runtime.unreadMailboxCount(tid);
                try out.print(self.allocator, "{{\"thread_id\":\"{s}\",\"unread_count\":{d},\"items\":[", .{ thex, unread });
                var wrote: usize = 0;
                for (store.mailbox_order.items) |iid| {
                    const it = store.mailbox.getPtr(iid) orelse continue;
                    if (wrote > 0) try out.append(self.allocator, ',');
                    wrote += 1;
                    try appendV2MailboxItemJson(self.allocator, out, it);
                }
                try out.appendSlice(self.allocator, "]}");
                return;
            }

            if (std.mem.eql(u8, method, "POST")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const action = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "action"));

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);

                if (action != null and std.mem.eql(u8, action.?, "drain")) {
                    const drained = try self.v2.runtime.drainMailbox(self.allocator, tid);
                    defer {
                        for (drained) |*it| it.deinit(self.allocator);
                        self.allocator.free(drained);
                    }
                    try out.appendSlice(self.allocator, "{\"ok\":true,\"drained\":true,\"items\":[");
                    for (drained, 0..) |*it, i| {
                        if (i > 0) try out.append(self.allocator, ',');
                        try appendV2MailboxItemJson(self.allocator, out, it);
                    }
                    try out.appendSlice(self.allocator, "]}");
                    self.emitV2Event("v2_updated");
                    return;
                }

                const payload = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "payload")) orelse "";
                const kind_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "kind")) orelse "progress";
                const kind = parseV2MailboxKind(kind_str);
                const from_tid: u128 = if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "from_thread_id"))) |fs|
                    if (fs.len > 0) try id.parseIdHex(fs) else tid
                else
                    tid;
                const task_id_opt: ?u128 = if (rpc.jsonStr(rpc.jsonObjGet(parsed.value, "task_id"))) |ts|
                    if (ts.len > 0) try id.parseIdHex(ts) else null
                else
                    null;

                const iid = id.newUuidV7(self.io);
                const posted = try self.v2.runtime.postMailbox(tid, .{
                    .item_id = iid,
                    .from_thread_id = from_tid,
                    .to_thread_id = tid,
                    .task_id = task_id_opt,
                    .kind = kind,
                    .payload = @constCast(payload),
                    .created_ms = id.nowMs(self.io),
                });
                var ihex: [32]u8 = undefined;
                _ = id.formatIdHex(iid, &ihex);
                try out.print(self.allocator, "{{\"ok\":true,\"posted\":{},\"item_id\":\"{s}\"}}", .{ posted, ihex });
                self.emitV2Event("v2_updated");
                return;
            }
            return error.InvalidRoute;
        }

        if (std.mem.eql(u8, sub, "triggers")) {
            if (std.mem.eql(u8, method, "GET")) {
                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                const triggers = try self.v2.runtime.listTriggers(self.allocator, tid);
                defer {
                    for (triggers) |*t| t.deinit(self.allocator);
                    self.allocator.free(triggers);
                }
                var thex: [32]u8 = undefined;
                _ = id.formatIdHex(tid, &thex);
                try out.print(self.allocator, "{{\"thread_id\":\"{s}\",\"triggers\":[", .{thex});
                for (triggers, 0..) |*t, i| {
                    if (i > 0) try out.append(self.allocator, ',');
                    try appendV2TriggerJson(self.allocator, out, t);
                }
                try out.appendSlice(self.allocator, "]}");
                return;
            }

            if (std.mem.eql(u8, method, "POST")) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                const kind_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "kind")) orelse return error.MissingTriggerKind;
                const prompt_tpl = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt_template")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(parsed.value, "prompt")) orelse "";
                const enabled = rpc.jsonBool(rpc.jsonObjGet(parsed.value, "enabled")) orelse true;

                const tkind: thread_model.TriggerKind = if (std.mem.eql(u8, kind_str, "once")) blk: {
                    const at_ms = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "at_ms")) orelse id.nowMs(self.io);
                    break :blk .{ .once = at_ms };
                } else if (std.mem.eql(u8, kind_str, "cron")) blk: {
                    const expr = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "cron")) orelse
                        rpc.jsonStr(rpc.jsonObjGet(parsed.value, "expr")) orelse return error.InvalidCron;
                    break :blk .{ .cron = @constCast(expr) };
                } else if (std.mem.eql(u8, kind_str, "space_changed")) blk: {
                    const sid_str = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "space_id")) orelse return error.InvalidSpaceId;
                    const sid = try id.parseIdHex(sid_str);
                    const pref = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "path_prefix")) orelse "";
                    const deb: u32 = @intCast(rpc.jsonU64(rpc.jsonObjGet(parsed.value, "debounce_ms")) orelse 0);
                    break :blk .{ .space_changed = .{
                        .space_id = sid,
                        .path_prefix = @constCast(pref),
                        .debounce_ms = deb,
                    } };
                } else if (std.mem.eql(u8, kind_str, "mailbox"))
                    .mailbox
                else if (std.mem.eql(u8, kind_str, "webhook")) blk: {
                    const secret = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "webhook_secret")) orelse
                        rpc.jsonStr(rpc.jsonObjGet(parsed.value, "secret")) orelse "";
                    break :blk .{ .webhook = @constCast(secret) };
                } else return error.InvalidTriggerKind;

                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                const tr_id = try self.v2.runtime.registerTrigger(tid, .{
                    .trigger_id = 0,
                    .thread_id = tid,
                    .kind = tkind,
                    .prompt_template = @constCast(prompt_tpl),
                    .enabled = enabled,
                    .created_ms = id.nowMs(self.io),
                });
                var tr_hex: [32]u8 = undefined;
                _ = id.formatIdHex(tr_id, &tr_hex);
                try out.print(self.allocator, "{{\"ok\":true,\"trigger_id\":\"{s}\"}}", .{tr_hex});
                self.emitV2Event("v2_updated");
                return;
            }
            return error.InvalidRoute;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, sub, "triggers/poll")) {
            var now_ms = id.nowMs(self.io);
            var fire_due = true;
            if (body.len > 0) {
                var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                defer parsed.deinit();
                if (rpc.jsonU64(rpc.jsonObjGet(parsed.value, "now_ms"))) |nm| now_ms = nm;
                if (rpc.jsonBool(rpc.jsonObjGet(parsed.value, "fire"))) |f| fire_due = f;
            }

            self.v2_mu.lockUncancelable(self.io);
            defer self.v2_mu.unlock(self.io);
            const due = try self.v2.runtime.pollDueTriggers(self.allocator, tid, now_ms);
            defer thread_rt_mod.freeDueTriggers(self.allocator, due);

            try out.print(self.allocator, "{{\"now_ms\":{d},\"due\":[", .{now_ms});
            for (due, 0..) |dt, i| {
                if (i > 0) try out.append(self.allocator, ',');
                var outcome_str: []const u8 = "pending";
                if (fire_due) {
                    const outcome = try self.v2.runtime.fireTrigger(tid, dt.trigger_id, dt.event_token, now_ms);
                    outcome_str = fireOutcomeName(outcome);
                }
                var tr_hex: [32]u8 = undefined;
                _ = id.formatIdHex(dt.trigger_id, &tr_hex);
                try out.print(self.allocator, "{{\"trigger_id\":\"{s}\",\"event_token\":", .{tr_hex});
                try rpc.appendJsonEscaped(self.allocator, out, dt.event_token);
                try out.appendSlice(self.allocator, ",\"prompt\":");
                try rpc.appendJsonEscaped(self.allocator, out, dt.prompt);
                try out.print(self.allocator, ",\"outcome\":\"{s}\"}}", .{outcome_str});
            }
            try out.appendSlice(self.allocator, "]}");
            return;
        }

        if (std.mem.startsWith(u8, sub, "triggers/")) {
            const tr_rest = sub["triggers/".len..];
            if (std.mem.eql(u8, method, "DELETE") and std.mem.indexOfScalar(u8, tr_rest, '/') == null) {
                const trigger_id = try id.parseIdHex(tr_rest);
                self.v2_mu.lockUncancelable(self.io);
                defer self.v2_mu.unlock(self.io);
                try self.v2.runtime.disableTrigger(tid, trigger_id);
                var tr_hex: [32]u8 = undefined;
                _ = id.formatIdHex(trigger_id, &tr_hex);
                try out.print(self.allocator, "{{\"ok\":true,\"trigger_id\":\"{s}\",\"enabled\":false}}", .{tr_hex});
                self.emitV2Event("v2_updated");
                return;
            }
            if (std.mem.eql(u8, method, "POST")) {
                const tr_slash = std.mem.indexOfScalar(u8, tr_rest, '/') orelse return error.InvalidRoute;
                const trigger_id = try id.parseIdHex(tr_rest[0..tr_slash]);
                const action = tr_rest[tr_slash + 1 ..];
                if (std.mem.eql(u8, action, "fire")) {
                    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
                    defer parsed.deinit();
                    const token = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "event_token")) orelse return error.MissingEventToken;
                    const now_ms = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "now_ms")) orelse id.nowMs(self.io);

                    self.v2_mu.lockUncancelable(self.io);
                    defer self.v2_mu.unlock(self.io);
                    const outcome = try self.v2.runtime.fireTrigger(tid, trigger_id, token, now_ms);
                    var tr_hex: [32]u8 = undefined;
                    _ = id.formatIdHex(trigger_id, &tr_hex);
                    try out.print(
                        self.allocator,
                        "{{\"ok\":true,\"trigger_id\":\"{s}\",\"outcome\":\"{s}\"}}",
                        .{ tr_hex, fireOutcomeName(outcome) },
                    );
                    return;
                }
            }
        }

        return error.InvalidRoute;
    }

    fn handleV2ThreadDetail(self: *PlaygroundServer, tid: u128, out: *std.ArrayList(u8)) !void {
        self.v2_mu.lockUncancelable(self.io);
        defer self.v2_mu.unlock(self.io);

        const store = try self.v2.runtime.openThread(tid);
        const meta = store.meta orelse return error.ThreadNotFound;
        const active_turn: ?u128 = if (self.v2.runtime.active_turns.get(tid)) |at| at.turn_id else null;
        const msgs = try store.activeChain(self.allocator);
        defer thread_store_mod.ThreadStore.freeMessages(self.allocator, msgs);
        const unread = try self.v2.runtime.unreadMailboxCount(tid);

        var active_tasks: u32 = 0;
        var tit_count = store.tasks.valueIterator();
        while (tit_count.next()) |tk| {
            if (!tk.status.isTerminal()) active_tasks += 1;
        }

        try out.appendSlice(self.allocator, "{\"thread\":");
        try appendV2ThreadMetaJson(self.allocator, out, &meta, active_turn, store.total_message_count, active_tasks, @intCast(unread));

        try out.appendSlice(self.allocator, ",\"messages\":[");
        for (msgs, 0..) |*m, i| {
            if (i > 0) try out.append(self.allocator, ',');
            try appendV2MessageJson(self.allocator, out, m);
        }
        try out.appendSlice(self.allocator, "],\"sealed_pages\":[");
        for (store.sealed_pages.items, 0..) |sp, i| {
            if (i > 0) try out.append(self.allocator, ',');
            var phex: [64]u8 = undefined;
            _ = id.formatHashHex(sp.page_id, &phex);
            var fhex: [32]u8 = undefined;
            var lhex: [32]u8 = undefined;
            _ = id.formatIdHex(sp.first_msg_id, &fhex);
            _ = id.formatIdHex(sp.last_msg_id, &lhex);
            try out.print(
                self.allocator,
                "{{\"page_id\":\"{s}\",\"first_msg_id\":\"{s}\",\"last_msg_id\":\"{s}\",\"msg_count\":{d},\"sealed_ms\":{d}}}",
                .{ phex, fhex, lhex, sp.msg_count, sp.sealed_ms },
            );
        }
        try out.appendSlice(self.allocator, "],\"tasks\":[");
        var tit = store.tasks.valueIterator();
        var tidx: usize = 0;
        while (tit.next()) |task| {
            if (tidx > 0) try out.append(self.allocator, ',');
            tidx += 1;
            try appendV2TaskJson(self.allocator, out, task);
        }
        try out.appendSlice(self.allocator, "],\"mailbox\":[");
        var midx: usize = 0;
        for (store.mailbox_order.items) |iid| {
            const it = store.mailbox.getPtr(iid) orelse continue;
            if (midx > 0) try out.append(self.allocator, ',');
            midx += 1;
            try appendV2MailboxItemJson(self.allocator, out, it);
        }
        try out.appendSlice(self.allocator, "],\"triggers\":[");
        var trit = store.triggers.valueIterator();
        var tridx: usize = 0;
        while (trit.next()) |tr| {
            if (tridx > 0) try out.append(self.allocator, ',');
            tridx += 1;
            try appendV2TriggerJson(self.allocator, out, tr);
        }
        try out.print(
            self.allocator,
            "],\"pending_rollback\":{},\"unread_mailbox\":{d}}}",
            .{ store.pendingRollback() != null, unread },
        );
    }

    fn parseBindingItemLocked(self: *PlaygroundServer, item: std.json.Value) !thread_model.SpaceBinding {
        const sid_str = rpc.jsonStr(rpc.jsonObjGet(item, "space_id")) orelse return error.InvalidSpaceId;
        const sid = try id.parseIdHex(sid_str);
        const alias_src = rpc.jsonStr(rpc.jsonObjGet(item, "alias")) orelse blk: {
            if (self.v2.spaces.get(sid)) |rec| break :blk rec.title;
            break :blk "space";
        };
        const acc_str = rpc.jsonStr(rpc.jsonObjGet(item, "access")) orelse "shared_rw";
        const mount_rel_opt = rpc.jsonStr(rpc.jsonObjGet(item, "mount_rel"));
        const alias_copy = try self.allocator.dupe(u8, alias_src);
        errdefer self.allocator.free(alias_copy);
        const mount_copy: ?[]u8 = if (mount_rel_opt) |mr| if (mr.len > 0) try self.allocator.dupe(u8, mr) else null else null;
        return .{
            .space_id = sid,
            .alias = alias_copy,
            .access = parseV2SpaceAccess(acc_str),
            .mount_rel = mount_copy,
        };
    }

    fn appendV2SpaceJsonLocked(
        self: *PlaygroundServer,
        out: *std.ArrayList(u8),
        rec: *const space_mgr_mod.SpaceRecord,
    ) !void {
        var shex: [32]u8 = undefined;
        _ = id.formatIdHex(rec.space_id, &shex);
        const slot_opt = self.v2.spaces.slots.get(rec.space_id);
        const state: space_mgr_mod.SlotState = if (slot_opt) |sl| sl.state else .cold;
        const head_count: usize = if (slot_opt) |sl| if (sl.space) |sp| sp.history.dag.heads.slice().len else 0 else 0;
        const approx_bytes: usize = if (slot_opt) |sl| sl.approx_bytes else 0;
        const proj_opt = self.v2.spaces.getProjectionRecord(rec.space_id);

        try out.print(self.allocator, "{{\"space_id\":\"{s}\",\"name\":", .{shex});
        try rpc.appendJsonEscaped(self.allocator, out, rec.title);
        try out.appendSlice(self.allocator, ",\"title\":");
        try rpc.appendJsonEscaped(self.allocator, out, rec.title);
        try out.print(
            self.allocator,
            ",\"kind\":\"{s}\",\"state\":\"{s}\",\"projection_path\":",
            .{ spaceKindName(rec.kind), slotStateName(state) },
        );
        if (proj_opt) |pr| {
            try rpc.appendJsonEscaped(self.allocator, out, pr.local_path);
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.appendSlice(self.allocator, ",\"origin_space_id\":");
        if (rec.origin) |o| {
            var ohex: [32]u8 = undefined;
            _ = id.formatIdHex(o.origin_space_id, &ohex);
            try out.print(self.allocator, "\"{s}\"", .{ohex});
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.appendSlice(self.allocator, ",\"git_remote_url\":");
        if (rec.git_remote_url) |u| {
            try rpc.appendJsonEscaped(self.allocator, out, u);
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.print(
            self.allocator,
            ",\"head_count\":{d},\"approx_bytes\":{d},\"created_ms\":{d},\"updated_ms\":{d}}}",
            .{ head_count, approx_bytes, rec.created_ms, rec.updated_ms },
        );
    }
};

const V2FileItem = struct {
    path: []u8,
    name: []u8,
    kind: space_mod.DirEntryKind,

    fn deinit(self: *V2FileItem, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
    }
};

fn collectSpaceFiles(
    allocator: Allocator,
    sp: *const space_mod.Space,
    rel_dir: []const u8,
    recursive: bool,
    depth: usize,
    out: *std.ArrayList(V2FileItem),
) !void {
    if (depth > 64) return;
    const entries = try sp.listDir(allocator, rel_dir);
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }
    for (entries) |e| {
        const full_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_dir, e.name });
        errdefer allocator.free(full_path);
        const name_copy = try allocator.dupe(u8, e.name);
        errdefer allocator.free(name_copy);
        try out.append(allocator, .{
            .path = full_path,
            .name = name_copy,
            .kind = e.kind,
        });
        if (recursive and e.kind == .dir) {
            try collectSpaceFiles(allocator, sp, full_path, true, depth + 1, out);
        }
    }
}

fn spaceKindName(k: space_mod.SpaceKind) []const u8 {
    return switch (k) {
        .virtual => "virtual",
        .dir => "dir",
        .git_worktree => "git_worktree",
    };
}

fn slotStateName(s: space_mgr_mod.SlotState) []const u8 {
    return switch (s) {
        .cold => "cold",
        .warm => "warm",
        .hot => "hot",
    };
}

fn dirEntryKindName(k: space_mod.DirEntryKind) []const u8 {
    return switch (k) {
        .file => "file",
        .dir => "dir",
        .symlink => "symlink",
    };
}

fn changeKindName(k: timeline_mod.ChangeKind) []const u8 {
    return switch (k) {
        .added => "added",
        .modified => "modified",
        .deleted => "deleted",
        .renamed => "renamed",
        .binary => "binary",
    };
}

fn spaceAccessName(a: thread_model.SpaceAccess) []const u8 {
    return switch (a) {
        .read_only => "read_only",
        .shared_rw => "shared_rw",
        .isolated_fork => "isolated_fork",
    };
}

fn parseV2SpaceAccess(s: []const u8) thread_model.SpaceAccess {
    if (std.ascii.eqlIgnoreCase(s, "read_only") or std.ascii.eqlIgnoreCase(s, "ro")) return .read_only;
    if (std.ascii.eqlIgnoreCase(s, "isolated_fork") or std.ascii.eqlIgnoreCase(s, "fork")) return .isolated_fork;
    return .shared_rw;
}

fn sessionStatusName(s: thread_model.SessionStatus) []const u8 {
    return switch (s) {
        .idle => "idle",
        .running => "running",
        .queued => "queued",
        .steering => "steering",
        .interrupted => "interrupted",
        .failed => "failed",
    };
}

fn messageRoleName(r: thread_model.Role) []const u8 {
    return switch (r) {
        .user => "user",
        .assistant => "assistant",
        .system => "system",
        .steer => "steer",
    };
}

fn messageStatusName(s: thread_model.MessageStatus) []const u8 {
    return switch (s) {
        .pending => "pending",
        .running => "running",
        .completed => "completed",
        .interrupted => "interrupted",
        .failed => "failed",
    };
}

fn taskStatusName(s: thread_model.TaskStatus) []const u8 {
    return switch (s) {
        .pending => "pending",
        .ready => "ready",
        .leased => "leased",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .canceled => "canceled",
    };
}

fn parseV2TaskStatus(s: []const u8) ?thread_model.TaskStatus {
    if (std.ascii.eqlIgnoreCase(s, "completed")) return .completed;
    if (std.ascii.eqlIgnoreCase(s, "failed")) return .failed;
    if (std.ascii.eqlIgnoreCase(s, "canceled")) return .canceled;
    return null;
}

fn mailboxKindName(k: thread_model.MailboxKind) []const u8 {
    return switch (k) {
        .assign => "assign",
        .steer => "steer",
        .progress => "progress",
        .question => "question",
        .answer => "answer",
        .handoff => "handoff",
        .result => "result",
        .cancel => "cancel",
    };
}

fn parseV2MailboxKind(s: []const u8) thread_model.MailboxKind {
    if (std.ascii.eqlIgnoreCase(s, "assign")) return .assign;
    if (std.ascii.eqlIgnoreCase(s, "steer")) return .steer;
    if (std.ascii.eqlIgnoreCase(s, "question")) return .question;
    if (std.ascii.eqlIgnoreCase(s, "answer")) return .answer;
    if (std.ascii.eqlIgnoreCase(s, "handoff")) return .handoff;
    if (std.ascii.eqlIgnoreCase(s, "result")) return .result;
    if (std.ascii.eqlIgnoreCase(s, "cancel")) return .cancel;
    return .progress;
}

fn fireOutcomeName(o: thread_rt_mod.FireTriggerOutcome) []const u8 {
    return switch (o) {
        .fired => "fired",
        .already_fired => "already_fired",
        .disabled => "disabled",
        .not_found => "not_found",
    };
}

fn failureReasonName(r: project_mod.FailureReason) []const u8 {
    return switch (r) {
        .space_not_found => "space_not_found",
        .not_a_fork => "not_a_fork",
        .origin_not_found => "origin_not_found",
        .vcs_operation_in_progress => "vcs_operation_in_progress",
        .unresolved_conflicts => "unresolved_conflicts",
        .would_conflict => "would_conflict",
    };
}

fn parseV2Budget(val_opt: ?std.json.Value) thread_model.Budget {
    var b = thread_model.Budget{};
    const v = val_opt orelse return b;
    if (v != .object) return b;
    if (rpc.jsonU64(rpc.jsonObjGet(v, "max_tokens"))) |x| b.max_tokens = x;
    if (rpc.jsonU64(rpc.jsonObjGet(v, "max_cost_microusd"))) |x| b.max_cost_microusd = x;
    if (rpc.jsonU64(rpc.jsonObjGet(v, "max_wall_ms"))) |x| b.max_wall_ms = x;
    if (rpc.jsonU64(rpc.jsonObjGet(v, "max_depth"))) |x| b.max_depth = @intCast(@min(x, 255));
    if (rpc.jsonU64(rpc.jsonObjGet(v, "max_children"))) |x| b.max_children = @intCast(@min(x, 65535));
    return b;
}

fn appendV2BudgetJson(allocator: Allocator, out: *std.ArrayList(u8), b: *const thread_model.Budget) !void {
    try out.print(
        allocator,
        "{{\"max_tokens\":{d},\"used_tokens\":{d},\"max_cost_microusd\":{d},\"used_cost_microusd\":{d},\"max_wall_ms\":{d},\"used_wall_ms\":{d},\"max_depth\":{d},\"max_children\":{d},\"active_children\":{d}}}",
        .{
            b.max_tokens,
            b.used_tokens,
            b.max_cost_microusd,
            b.used_cost_microusd,
            b.max_wall_ms,
            b.used_wall_ms,
            b.max_depth,
            b.max_children,
            b.active_children,
        },
    );
}

fn appendV2BindingsJson(allocator: Allocator, out: *std.ArrayList(u8), bindings: []const thread_model.SpaceBinding) !void {
    try out.append(allocator, '[');
    for (bindings, 0..) |b, i| {
        if (i > 0) try out.append(allocator, ',');
        var shex: [32]u8 = undefined;
        _ = id.formatIdHex(b.space_id, &shex);
        try out.print(allocator, "{{\"space_id\":\"{s}\",\"alias\":", .{shex});
        try rpc.appendJsonEscaped(allocator, out, b.alias);
        try out.print(allocator, ",\"access\":\"{s}\",\"mount_rel\":", .{spaceAccessName(b.access)});
        if (b.mount_rel) |mr| {
            try rpc.appendJsonEscaped(allocator, out, mr);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

fn appendV2CheckpointVectorJson(allocator: Allocator, out: *std.ArrayList(u8), cv: *const thread_model.CheckpointVector) !void {
    try out.append(allocator, '[');
    for (cv.entries, 0..) |e, i| {
        if (i > 0) try out.append(allocator, ',');
        var shex: [32]u8 = undefined;
        _ = id.formatIdHex(e.space_id, &shex);
        try out.print(allocator, "{{\"space_id\":\"{s}\",\"heads\":{d},\"vcs_ref\":", .{ shex, e.version.slice().len });
        if (e.vcs_ref) |r| {
            try rpc.appendJsonEscaped(allocator, out, r);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"vcs_rev\":");
        if (e.vcs_rev) |v| {
            try rpc.appendJsonEscaped(allocator, out, v);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
}

fn appendV2ProjectJson(allocator: Allocator, out: *std.ArrayList(u8), p: *const project_mod.Project) !void {
    var phex: [32]u8 = undefined;
    _ = id.formatIdHex(p.project_id, &phex);
    try out.print(allocator, "{{\"project_id\":\"{s}\",\"name\":", .{phex});
    try rpc.appendJsonEscaped(allocator, out, p.title);
    try out.appendSlice(allocator, ",\"title\":");
    try rpc.appendJsonEscaped(allocator, out, p.title);
    try out.appendSlice(allocator, ",\"instructions\":");
    try rpc.appendJsonEscaped(allocator, out, p.instructions);
    try out.appendSlice(allocator, ",\"spaces\":[");
    for (p.spaces, 0..) |sr, i| {
        if (i > 0) try out.append(allocator, ',');
        var shex: [32]u8 = undefined;
        _ = id.formatIdHex(sr.space_id, &shex);
        const acc = std.enums.fromInt(thread_model.SpaceAccess, sr.default_access) orelse .shared_rw;
        try out.print(allocator, "{{\"space_id\":\"{s}\",\"alias\":", .{shex});
        try rpc.appendJsonEscaped(allocator, out, sr.alias);
        try out.print(allocator, ",\"kind\":\"{s}\",\"access\":\"{s}\"}}", .{ spaceKindName(sr.kind), spaceAccessName(acc) });
    }
    try out.print(allocator, "],\"created_ms\":{d},\"updated_ms\":{d}}}", .{ p.created_ms, p.updated_ms });
}

fn appendV2LandReportJson(allocator: Allocator, out: *std.ArrayList(u8), report: *const project_mod.SpaceSetLandReport) !void {
    try out.print(allocator, "{{\"aborted\":{},\"entries\":[", .{report.aborted});
    for (report.entries, 0..) |e, i| {
        if (i > 0) try out.append(allocator, ',');
        var shex: [32]u8 = undefined;
        var ohex: [32]u8 = undefined;
        _ = id.formatIdHex(e.space_id, &shex);
        _ = id.formatIdHex(e.origin_space_id, &ohex);
        try out.print(
            allocator,
            "{{\"space_id\":\"{s}\",\"origin_space_id\":\"{s}\",\"landed\":{d},\"brought\":{d}}}",
            .{ shex, ohex, e.report.landed, e.report.sync.brought },
        );
    }
    try out.appendSlice(allocator, "],\"failures\":[");
    for (report.failures, 0..) |f, i| {
        if (i > 0) try out.append(allocator, ',');
        var shex: [32]u8 = undefined;
        _ = id.formatIdHex(f.space_id, &shex);
        try out.print(allocator, "{{\"space_id\":\"{s}\",\"reason\":\"{s}\",\"detail\":", .{ shex, failureReasonName(f.reason) });
        if (f.detail) |d| {
            try rpc.appendJsonEscaped(allocator, out, d);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
}

fn appendV2ThreadMetaJson(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    m: *const thread_model.ThreadMeta,
    active_turn_id: ?u128,
    message_count: u32,
    active_tasks: u32,
    unread_mailbox: u32,
) !void {
    var thex: [32]u8 = undefined;
    var rhex: [32]u8 = undefined;
    _ = id.formatIdHex(m.thread_id, &thex);
    _ = id.formatIdHex(m.root_thread_id, &rhex);
    try out.print(allocator, "{{\"thread_id\":\"{s}\",\"root_thread_id\":\"{s}\",\"project_id\":", .{ thex, rhex });
    try appendOptIdHex(allocator, out, m.project_id);
    try out.appendSlice(allocator, ",\"parent_thread_id\":");
    try appendOptIdHex(allocator, out, m.parent_thread_id);
    try out.appendSlice(allocator, ",\"task_id\":");
    try appendOptIdHex(allocator, out, m.task_id);
    try out.appendSlice(allocator, ",\"active_turn_id\":");
    try appendOptIdHex(allocator, out, active_turn_id);
    try out.print(allocator, ",\"depth\":{d},\"title\":", .{m.depth});
    try rpc.appendJsonEscaped(allocator, out, m.title);
    try out.print(allocator, ",\"provider\":\"{s}\",\"model\":", .{m.default_provider.slug()});
    if (m.default_model) |mdl| {
        try rpc.appendJsonEscaped(allocator, out, mdl);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.print(allocator, ",\"status\":\"{s}\",\"bindings\":", .{sessionStatusName(m.status)});
    try appendV2BindingsJson(allocator, out, m.bindings);
    try out.appendSlice(allocator, ",\"budget\":");
    try appendV2BudgetJson(allocator, out, &m.budget);
    try out.print(
        allocator,
        ",\"message_count\":{d},\"active_tasks\":{d},\"unread_mailbox\":{d},\"created_ms\":{d},\"updated_ms\":{d}}}",
        .{ message_count, active_tasks, unread_mailbox, m.created_ms, m.updated_ms },
    );
}

fn appendV2ThreadSummaryFallbackJson(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    s: *const thread_model.ThreadSummary,
    active_turn_id: ?u128,
) !void {
    var thex: [32]u8 = undefined;
    var rhex: [32]u8 = undefined;
    _ = id.formatIdHex(s.thread_id, &thex);
    _ = id.formatIdHex(s.root_thread_id, &rhex);
    try out.print(allocator, "{{\"thread_id\":\"{s}\",\"root_thread_id\":\"{s}\",\"project_id\":", .{ thex, rhex });
    try appendOptIdHex(allocator, out, s.project_id);
    try out.appendSlice(allocator, ",\"parent_thread_id\":");
    try appendOptIdHex(allocator, out, s.parent_thread_id);
    try out.appendSlice(allocator, ",\"task_id\":null,\"active_turn_id\":");
    try appendOptIdHex(allocator, out, active_turn_id);
    try out.appendSlice(allocator, ",\"depth\":0,\"title\":");
    try rpc.appendJsonEscaped(allocator, out, s.title);
    try out.print(allocator, ",\"provider\":\"{s}\",\"model\":", .{s.provider.slug()});
    if (s.model) |mdl| {
        try rpc.appendJsonEscaped(allocator, out, mdl);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.print(
        allocator,
        ",\"status\":\"{s}\",\"bindings\":[],\"budget\":{{\"max_tokens\":0,\"used_tokens\":0,\"max_cost_microusd\":0,\"used_cost_microusd\":0,\"max_wall_ms\":0,\"used_wall_ms\":0,\"max_depth\":4,\"max_children\":32,\"active_children\":0}},\"message_count\":{d},\"active_tasks\":{d},\"unread_mailbox\":{d},\"created_ms\":{d},\"updated_ms\":{d}}}",
        .{ sessionStatusName(s.status), s.message_count, s.active_tasks, s.unread_mailbox, s.updated_ms, s.updated_ms },
    );
}

fn appendV2MessageJson(allocator: Allocator, out: *std.ArrayList(u8), m: *const thread_model.Message) !void {
    var mhex: [32]u8 = undefined;
    var thex: [32]u8 = undefined;
    _ = id.formatIdHex(m.msg_id, &mhex);
    _ = id.formatIdHex(m.thread_id, &thex);
    try out.print(allocator, "{{\"msg_id\":\"{s}\",\"thread_id\":\"{s}\",\"parent_id\":", .{ mhex, thex });
    try appendOptIdHex(allocator, out, m.parent_id);
    try out.print(allocator, ",\"role\":\"{s}\",\"content\":", .{messageRoleName(m.role)});
    try rpc.appendJsonEscaped(allocator, out, m.content);
    try out.print(
        allocator,
        ",\"provider\":\"{s}\",\"status\":\"{s}\",\"fencing_epoch\":{d},\"pre_checkpoint\":",
        .{ m.provider.slug(), messageStatusName(m.status), m.fencing_epoch },
    );
    try appendV2CheckpointVectorJson(allocator, out, &m.pre_checkpoint);
    try out.appendSlice(allocator, ",\"post_checkpoint\":");
    try appendV2CheckpointVectorJson(allocator, out, &m.post_checkpoint);
    try out.print(allocator, ",\"created_ms\":{d},\"updated_ms\":{d}}}", .{ m.created_ms, m.updated_ms });
}

fn appendV2TaskJson(allocator: Allocator, out: *std.ArrayList(u8), t: *const thread_model.Task) !void {
    var task_hex: [32]u8 = undefined;
    var parent_hex: [32]u8 = undefined;
    var child_hex: [32]u8 = undefined;
    _ = id.formatIdHex(t.task_id, &task_hex);
    _ = id.formatIdHex(t.parent_thread_id, &parent_hex);
    _ = id.formatIdHex(t.child_thread_id, &child_hex);
    try out.print(
        allocator,
        "{{\"task_id\":\"{s}\",\"parent_thread_id\":\"{s}\",\"child_thread_id\":\"{s}\",\"title\":",
        .{ task_hex, parent_hex, child_hex },
    );
    try rpc.appendJsonEscaped(allocator, out, t.title);
    try out.print(
        allocator,
        ",\"status\":\"{s}\",\"attempt\":{d},\"join_quorum\":{d},\"depends_on\":[",
        .{ taskStatusName(t.status), t.attempt, t.join_quorum },
    );
    for (t.depends_on, 0..) |dep, i| {
        if (i > 0) try out.append(allocator, ',');
        var dhex: [32]u8 = undefined;
        _ = id.formatIdHex(dep, &dhex);
        try out.print(allocator, "\"{s}\"", .{dhex});
    }
    try out.appendSlice(allocator, "],\"grants\":");
    try appendV2BindingsJson(allocator, out, t.grants);
    try out.appendSlice(allocator, ",\"budget\":");
    try appendV2BudgetJson(allocator, out, &t.budget);
    try out.appendSlice(allocator, ",\"err_msg\":");
    if (t.err_msg) |em| {
        try rpc.appendJsonEscaped(allocator, out, em);
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.print(allocator, ",\"created_ms\":{d},\"updated_ms\":{d}}}", .{ t.created_ms, t.updated_ms });
}

fn appendV2MailboxItemJson(allocator: Allocator, out: *std.ArrayList(u8), it: *const thread_model.MailboxItem) !void {
    var ihex: [32]u8 = undefined;
    var fhex: [32]u8 = undefined;
    var thex: [32]u8 = undefined;
    _ = id.formatIdHex(it.item_id, &ihex);
    _ = id.formatIdHex(it.from_thread_id, &fhex);
    _ = id.formatIdHex(it.to_thread_id, &thex);
    try out.print(
        allocator,
        "{{\"item_id\":\"{s}\",\"from_thread_id\":\"{s}\",\"to_thread_id\":\"{s}\",\"task_id\":",
        .{ ihex, fhex, thex },
    );
    try appendOptIdHex(allocator, out, it.task_id);
    try out.print(allocator, ",\"kind\":\"{s}\",\"payload\":", .{mailboxKindName(it.kind)});
    try rpc.appendJsonEscaped(allocator, out, it.payload);
    try out.print(allocator, ",\"created_ms\":{d}}}", .{it.created_ms});
}

fn appendV2TriggerJson(allocator: Allocator, out: *std.ArrayList(u8), tr: *const thread_model.Trigger) !void {
    var tr_hex: [32]u8 = undefined;
    var thex: [32]u8 = undefined;
    _ = id.formatIdHex(tr.trigger_id, &tr_hex);
    _ = id.formatIdHex(tr.thread_id, &thex);
    try out.print(allocator, "{{\"trigger_id\":\"{s}\",\"thread_id\":\"{s}\",\"kind\":", .{ tr_hex, thex });
    switch (tr.kind) {
        .once => |at_ms| try out.print(allocator, "\"once\",\"at_ms\":{d}", .{at_ms}),
        .cron => |expr| {
            try out.appendSlice(allocator, "\"cron\",\"cron\":");
            try rpc.appendJsonEscaped(allocator, out, expr);
        },
        .space_changed => |sc| {
            var shex: [32]u8 = undefined;
            _ = id.formatIdHex(sc.space_id, &shex);
            try out.print(allocator, "\"space_changed\",\"space_id\":\"{s}\",\"path_prefix\":", .{shex});
            try rpc.appendJsonEscaped(allocator, out, sc.path_prefix);
            try out.print(allocator, ",\"debounce_ms\":{d}", .{sc.debounce_ms});
        },
        .mailbox => try out.appendSlice(allocator, "\"mailbox\""),
        .webhook => try out.appendSlice(allocator, "\"webhook\""),
    }
    try out.appendSlice(allocator, ",\"prompt_template\":");
    try rpc.appendJsonEscaped(allocator, out, tr.prompt_template);
    try out.print(allocator, ",\"enabled\":{},\"created_ms\":{d}}}", .{ tr.enabled, tr.created_ms });
}

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

fn appendSessionSummaryJson(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    s: *const model.SessionSummary,
    t_model: ?[]const u8,
    t_worktree_id: ?u128,
) !void {
    var thex: [32]u8 = undefined;
    _ = id.formatIdHex(s.thread_id, &thex);
    try out.print(allocator, "{{\"thread_id\":\"{s}\"", .{thex});
    try out.appendSlice(allocator, ",\"worktree_id\":");
    try appendOptIdHex(allocator, out, t_worktree_id);
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
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return null;
    return allocator.dupe(u8, buf[0..n]) catch null;
}

fn readStoredConflictCount(allocator: Allocator, io: Io, state_path: []const u8) usize {
    const path = std.fmt.allocPrint(allocator, "{s}/conflicts.0ndb", .{state_path}) catch return 0;
    defer allocator.free(path);
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    var hdr: [8]u8 = undefined;
    const n = f.readPositionalAll(io, &hdr, 0) catch return 0;
    if (n < 8) return 0;
    const magic = std.mem.readInt(u32, hdr[0..4], .little);
    if (magic != CONFLICTS_MAGIC) return 0;
    return @intCast(std.mem.readInt(u32, hdr[4..8], .little));
}

pub fn httpStatusForError(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound,
        error.ThreadNotFound,
        error.MessageNotFound,
        error.FileNotFound,
        error.PageNotFound,
        error.WorktreeNotFound,
        error.ConflictNotFound,
        error.SpaceNotFound,
        error.ProjectNotFound,
        error.TaskNotFound,
        error.TriggerNotFound,
        error.InvalidRoute,
        => "404 Not Found",
        error.AccessEscalation,
        error.UnauthorizedSpaceGrant,
        => "403 Forbidden",
        error.TurnAlreadyActive,
        error.UnresolvedConflicts,
        error.DirtyWorktree,
        error.RollbackAlreadyPending,
        error.LeaseNotActive,
        error.LeaseEpochMismatch,
        error.InvalidTaskTransition,
        error.NotAFork,
        error.BudgetExceeded,
        error.MaxDepthExceeded,
        error.MaxChildrenExceeded,
        error.SpaceLocked,
        => "409 Conflict",
        error.PayloadTooLarge => "413 Payload Too Large",
        error.TooManyWorkers,
        error.TooManySseClients,
        error.ServerBusy,
        => "503 Service Unavailable",
        error.OutOfMemory,
        error.MasterKeyWriteFailed,
        => "500 Internal Server Error",
        else => "400 Bad Request",
    };
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

fn queryParamAlloc(allocator: Allocator, query: []const u8, key: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const raw_k = pair[0..eq];
            if (std.mem.eql(u8, raw_k, key)) {
                return try urlDecodeQuery(allocator, pair[eq + 1 ..]);
            }
            const dec_k = try urlDecodeQuery(allocator, raw_k);
            defer allocator.free(dec_k);
            if (std.mem.eql(u8, dec_k, key)) {
                return try urlDecodeQuery(allocator, pair[eq + 1 ..]);
            }
        }
    }
    return null;
}

pub fn urlDecode(allocator: Allocator, s: []const u8) ![]u8 {
    return urlDecodeInternal(allocator, s, false);
}

pub fn urlDecodeQuery(allocator: Allocator, s: []const u8) ![]u8 {
    return urlDecodeInternal(allocator, s, true);
}

fn urlDecodeInternal(allocator: Allocator, s: []const u8, plus_as_space: bool) ![]u8 {
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
        } else if (plus_as_space and s[i] == '+') {
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
    var hdr_buf: [1024]u8 = undefined;
    const conn_hdr = if (keep_alive) "keep-alive\r\nKeep-Alive: timeout=15" else "close";
    const csp_hdr = if (std.mem.startsWith(u8, content_type, "text/html"))
        "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'\r\n"
    else
        "";
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: {s}\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n{s}Connection: {s}\r\n\r\n",
        .{ status, content_type, body.len, cache_control, csp_hdr, conn_hdr },
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

pub fn jsonU64(val: ?std.json.Value) error{InvalidNumber}!u64 {
    const v = val orelse return error.InvalidNumber;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidNumber,
        .float => |fl| if (std.math.isFinite(fl) and fl >= 0.0 and fl <= 9007199254740991.0 and @floor(fl) == fl)
            @intFromFloat(fl)
        else
            error.InvalidNumber,
        else => error.InvalidNumber,
    };
}

fn jsonU64Opt(val: ?std.json.Value) error{InvalidNumber}!u64 {
    const v = val orelse return 0;
    if (v == .null) return 0;
    return jsonU64(v);
}
