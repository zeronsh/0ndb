const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const id = @import("../core/id.zig");
const codec = @import("../store/codec.zig");
const crypto = @import("../store/crypto.zig");
const blobs_mod = @import("../store/blobs.zig");
const op_mod = @import("../core/op.zig");
const model = @import("../session/model.zig");
const pager = @import("../session/pager.zig");
const ws_mod = @import("../fs/workspace.zig");
const git_dirs_mod = @import("../fs/git_dirs.zig");
const wire = @import("wire.zig");

pub const SenderKey = struct {
    topic: [32]u8,
    sender_id: u128,
};

pub const CapabilityToken = struct {
    topic: [32]u8,
    perms: u8,
    expires_ms: u64,
    mac: crypto.Mac,

    pub fn mint(secret: [32]u8, topic: [32]u8, perms: u8, expires_ms: u64) CapabilityToken {
        return .{
            .topic = topic,
            .perms = perms,
            .expires_ms = expires_ms,
            .mac = crypto.deriveCapabilityToken(secret, topic, perms, expires_ms),
        };
    }
};

pub const QuarantineReason = enum {
    invalid_envelope,
    auth_failed,
    decode_failed,
};

pub const QuarantinedFrame = struct {
    topic_id: [32]u8,
    seq: u64,
    reason: QuarantineReason,
};

pub const DecryptedFrame = struct {
    topic_id: [32]u8,
    seq: u64,
    sender_id: u128,
    sender_seq: u64,
    plaintext: []u8,

    pub fn deinit(self: *DecryptedFrame, allocator: Allocator) void {
        allocator.free(self.plaintext);
    }
};

pub const RangePage = struct {
    frames: []DecryptedFrame,
    last_seq: u64,
    has_more: bool,
    item_count: usize,

    pub fn deinit(self: *RangePage, allocator: Allocator) void {
        for (self.frames) |*f| f.deinit(allocator);
        allocator.free(self.frames);
    }
};

pub const FramePayload = struct {
    sender_id: u128,
    sender_seq: u64,
    plaintext: []u8,
};

const FRAME_AAD_PREFIX = "0ndb-frame-v2";
const BLOB_AAD_PREFIX = "0ndb-blob-v2";
const FRAME_HEADER_LEN: usize = 24;
const SEQ_RESERVE_STRIDE: u64 = 64;
pub const PULL_PAGE_LIMIT: u32 = 128;
const MAX_WAITING_BATCHES: usize = 4096;
const MAX_QUARANTINED_RECORDS: usize = 1024;

fn buildFrameAad(topic: [32]u8, sender_id: u128, sender_seq: u64) [FRAME_AAD_PREFIX.len + 32 + 16 + 8]u8 {
    var aad: [FRAME_AAD_PREFIX.len + 32 + 16 + 8]u8 = undefined;
    const p0 = FRAME_AAD_PREFIX.len;
    @memcpy(aad[0..p0], FRAME_AAD_PREFIX);
    @memcpy(aad[p0 .. p0 + 32], &topic);
    std.mem.writeInt(u128, aad[p0 + 32 .. p0 + 48], sender_id, .little);
    std.mem.writeInt(u64, aad[p0 + 48 .. p0 + 56], sender_seq, .little);
    return aad;
}

fn buildBlobAad(topic: [32]u8, oid: [32]u8) [BLOB_AAD_PREFIX.len + 64]u8 {
    var aad: [BLOB_AAD_PREFIX.len + 64]u8 = undefined;
    @memcpy(aad[0..BLOB_AAD_PREFIX.len], BLOB_AAD_PREFIX);
    @memcpy(aad[BLOB_AAD_PREFIX.len .. BLOB_AAD_PREFIX.len + 32], &topic);
    @memcpy(aad[BLOB_AAD_PREFIX.len + 32 .. BLOB_AAD_PREFIX.len + 64], &oid);
    return aad;
}

pub fn sealFramePayload(
    allocator: Allocator,
    io: Io,
    master_key: crypto.Key,
    topic: [32]u8,
    sender_id: u128,
    sender_seq: u64,
    plaintext: []const u8,
) ![]u8 {
    var key = crypto.deriveTopicKey(master_key, topic);
    defer crypto.zeroize(&key);
    const aad = buildFrameAad(topic, sender_id, sender_seq);
    const sealed = try crypto.sealRandom(allocator, io, key, &aad, plaintext);
    defer allocator.free(sealed);

    const out = try allocator.alloc(u8, FRAME_HEADER_LEN + sealed.len);
    std.mem.writeInt(u128, out[0..16], sender_id, .little);
    std.mem.writeInt(u64, out[16..24], sender_seq, .little);
    @memcpy(out[24..], sealed);
    return out;
}

pub fn openFramePayload(
    allocator: Allocator,
    master_key: crypto.Key,
    expected_topic: [32]u8,
    raw: []const u8,
    seen_seqs: *std.AutoHashMapUnmanaged(SenderKey, u64),
    seen_alloc: Allocator,
) !FramePayload {
    if (raw.len < FRAME_HEADER_LEN + crypto.ENVELOPE_OVERHEAD) return error.InvalidEnvelope;
    const sender_id = std.mem.readInt(u128, raw[0..16], .little);
    const sender_seq = std.mem.readInt(u64, raw[16..24], .little);
    if (sender_seq == 0) return error.ReplayOrReorder;

    const sk = SenderKey{ .topic = expected_topic, .sender_id = sender_id };
    if (seen_seqs.get(sk)) |prev| {
        if (sender_seq <= prev) return error.ReplayOrReorder;
    }

    var key = crypto.deriveTopicKey(master_key, expected_topic);
    defer crypto.zeroize(&key);
    const aad = buildFrameAad(expected_topic, sender_id, sender_seq);
    const plain = try crypto.open(allocator, key, &aad, raw[FRAME_HEADER_LEN..]);
    errdefer allocator.free(plain);

    try seen_seqs.put(seen_alloc, sk, sender_seq);
    return .{
        .sender_id = sender_id,
        .sender_seq = sender_seq,
        .plaintext = plain,
    };
}

const SYNC_CURSOR_MAGIC: u32 = 0x30534352;
const SYNC_CURSOR_VERSION_V1: u16 = 1;
const SYNC_CURSOR_VERSION: u16 = 2;

const WaitingBatch = struct {
    batch_id: id.BatchId,
    raw_batch: []u8,
};

const WorkspaceSyncState = struct {
    last_pulled_seq: u64 = 0,
    pushed_batches: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty,
    uploaded_blobs: std.AutoHashMapUnmanaged([32]u8, void) = .empty,
    waiting: std.ArrayList(WaitingBatch) = .empty,

    fn deinit(self: *WorkspaceSyncState, allocator: Allocator) void {
        self.pushed_batches.deinit(allocator);
        self.uploaded_blobs.deinit(allocator);
        for (self.waiting.items) |w| allocator.free(w.raw_batch);
        self.waiting.deinit(allocator);
    }

    fn containsWaiting(self: *const WorkspaceSyncState, bid: id.BatchId) bool {
        for (self.waiting.items) |w| {
            if (w.batch_id.eql(bid)) return true;
        }
        return false;
    }

    fn addWaiting(self: *WorkspaceSyncState, allocator: Allocator, bid: id.BatchId, raw: []const u8) !bool {
        if (self.containsWaiting(bid)) return false;
        if (self.waiting.items.len >= MAX_WAITING_BATCHES) return false;
        const dup = try allocator.dupe(u8, raw);
        errdefer allocator.free(dup);
        try self.waiting.append(allocator, .{ .batch_id = bid, .raw_batch = dup });
        return true;
    }
};

const IntegrateOutcome = enum {
    applied,
    already_present,
    waiting_parents,
    waiting_blob,
};

const OpBlobRef = union(enum) {
    blake3: struct { oid: id.Oid, is_text_blob: bool },
    git: git_dirs_mod.GitOid,
};

fn gitBlobLookupOid(git_oid: git_dirs_mod.GitOid) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("0ndb-git-blob-v1:");
    hasher.update(git_oid.slice());
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn opReferencedBlob(op: op_mod.Op) ?OpBlobRef {
    return switch (op) {
        .create_file => |cf| switch (cf.content) {
            .binary => |b| .{ .blake3 = .{ .oid = b.oid, .is_text_blob = false } },
            .text_blob => |b| .{ .blake3 = .{ .oid = b.oid, .is_text_blob = true } },
            .git_text_blob => |g| .{ .git = g.oid },
            .git_binary => |g| .{ .git = g.oid },
            .git_lazy => |g| .{ .git = g.oid },
            .text_inline => null,
        },
        .set_content => |sc| switch (sc.content) {
            .binary => |b| .{ .blake3 = .{ .oid = b.oid, .is_text_blob = false } },
            .text_blob => |b| .{ .blake3 = .{ .oid = b.oid, .is_text_blob = true } },
            .git_text_blob => |g| .{ .git = g.oid },
            .git_binary => |g| .{ .git = g.oid },
            .git_lazy => |g| .{ .git = g.oid },
            .text_inline => null,
        },
        else => null,
    };
}

pub const SyncClient = struct {
    allocator: Allocator,
    io: Io,
    fd: posix.fd_t,
    master_key: crypto.Key,
    auth_secret: ?[32]u8,
    sender_id: u128,
    out_seqs: std.AutoHashMapUnmanaged([32]u8, u64),
    persisted_out_seqs: std.AutoHashMapUnmanaged([32]u8, u64),
    seen_seqs: std.AutoHashMapUnmanaged(SenderKey, u64),
    authorized_topics: std.AutoHashMapUnmanaged([32]u8, u8),
    scoped_tokens: std.AutoHashMapUnmanaged([32]u8, CapabilityToken),
    uploaded_blobs: std.AutoHashMapUnmanaged([32]u8, void),
    ws_states: std.AutoHashMapUnmanaged(id.ActorId, WorkspaceSyncState),
    pending_events: std.ArrayList(DecryptedFrame),
    quarantined: std.ArrayList(QuarantinedFrame),
    quarantined_count: usize,

    fn connectInternal(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        master_key: crypto.Key,
        auth_secret: ?[32]u8,
    ) !SyncClient {
        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(s_rc) != .SUCCESS) return error.SocketFailed;
        const fd: posix.fd_t = @intCast(s_rc);
        errdefer _ = linux.close(fd);

        var one: i32 = 1;
        _ = linux.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
        wire.setSocketTimeouts(fd, @intCast(wire.DEFAULT_IO_TIMEOUT_MS)) catch {};

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(host_ip),
        };
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return error.ConnectFailed;
        }

        return .{
            .allocator = allocator,
            .io = io,
            .fd = fd,
            .master_key = master_key,
            .auth_secret = auth_secret,
            .sender_id = id.newUuidV7(io),
            .out_seqs = .empty,
            .persisted_out_seqs = .empty,
            .seen_seqs = .empty,
            .authorized_topics = .empty,
            .scoped_tokens = .empty,
            .uploaded_blobs = .empty,
            .ws_states = .empty,
            .pending_events = .empty,
            .quarantined = .empty,
            .quarantined_count = 0,
        };
    }

    pub fn connect(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        master_key: crypto.Key,
        auth_secret: [32]u8,
    ) !SyncClient {
        return connectInternal(allocator, io, host_ip, port, master_key, auth_secret);
    }

    pub fn connectWithToken(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        master_key: crypto.Key,
        token: CapabilityToken,
    ) !SyncClient {
        const toks = [_]CapabilityToken{token};
        return connectWithTokens(allocator, io, host_ip, port, master_key, &toks);
    }

    pub fn connectWithTokens(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        master_key: crypto.Key,
        tokens: []const CapabilityToken,
    ) !SyncClient {
        var client = try connectInternal(allocator, io, host_ip, port, master_key, null);
        errdefer client.deinit();
        for (tokens) |tok| {
            try client.scoped_tokens.put(allocator, tok.topic, tok);
        }
        return client;
    }

    pub fn deinit(self: *SyncClient) void {
        for (self.pending_events.items) |*ev| ev.deinit(self.allocator);
        self.pending_events.deinit(self.allocator);
        self.quarantined.deinit(self.allocator);
        self.out_seqs.deinit(self.allocator);
        self.persisted_out_seqs.deinit(self.allocator);
        self.seen_seqs.deinit(self.allocator);
        self.authorized_topics.deinit(self.allocator);
        var tit = self.scoped_tokens.valueIterator();
        while (tit.next()) |tok| crypto.zeroize(&tok.mac);
        self.scoped_tokens.deinit(self.allocator);
        self.uploaded_blobs.deinit(self.allocator);
        var wit = self.ws_states.valueIterator();
        while (wit.next()) |st| st.deinit(self.allocator);
        self.ws_states.deinit(self.allocator);
        crypto.zeroize(&self.master_key);
        if (self.auth_secret != null) {
            crypto.zeroize(&self.auth_secret.?);
            self.auth_secret = null;
        }
        _ = linux.close(self.fd);
    }

    fn recordQuarantine(self: *SyncClient, topic_id: [32]u8, seq: u64, reason: QuarantineReason) void {
        self.quarantined_count += 1;
        if (self.quarantined.items.len < MAX_QUARANTINED_RECORDS) {
            self.quarantined.append(self.allocator, .{
                .topic_id = topic_id,
                .seq = seq,
                .reason = reason,
            }) catch {};
        }
    }

    fn bufferLiveEventFrame(self: *SyncClient, frame: *const wire.WireFrame) !void {
        if (frame.payload.len < 40) return;
        const tid: [32]u8 = frame.payload[0..32].*;
        const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
        const dec = openFramePayload(self.allocator, self.master_key, tid, frame.payload[40..], &self.seen_seqs, self.allocator) catch |err| switch (err) {
            error.ReplayOrReorder => return,
            error.InvalidEnvelope => {
                self.recordQuarantine(tid, seq, .invalid_envelope);
                return;
            },
            error.AuthenticationFailed => {
                self.recordQuarantine(tid, seq, .auth_failed);
                return;
            },
            else => return err,
        };
        errdefer self.allocator.free(dec.plaintext);
        try self.pending_events.append(self.allocator, .{
            .topic_id = tid,
            .seq = seq,
            .sender_id = dec.sender_id,
            .sender_seq = dec.sender_seq,
            .plaintext = dec.plaintext,
        });
    }

    fn readRpcResponse(self: *SyncClient) !wire.WireFrame {
        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            if (frame.op == .frame_event) {
                defer frame.deinit(self.allocator);
                try self.bufferLiveEventFrame(&frame);
                continue;
            }
            return frame;
        }
    }

    fn drainUntilOp(self: *SyncClient, terminator: wire.Op) void {
        while (true) {
            var frame = wire.readFrameBlocking(self.allocator, self.fd) catch return;
            defer frame.deinit(self.allocator);
            if (frame.op == terminator or frame.op == .err) return;
            if (frame.op == .frame_event) {
                self.bufferLiveEventFrame(&frame) catch {};
            }
        }
    }

    pub fn authorizeWithToken(self: *SyncClient, token: CapabilityToken) !void {
        var payload: [32 + 1 + 8 + 32]u8 = undefined;
        defer crypto.zeroize(&payload);
        @memcpy(payload[0..32], &token.topic);
        payload[32] = token.perms;
        std.mem.writeInt(u64, payload[33..41], token.expires_ms, .little);
        @memcpy(payload[41..73], &token.mac);
        try wire.writeFrameBlocking(self.allocator, self.fd, .auth, 0, &payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op != .ack) return error.AuthRejected;
        if (token.expires_ms == 0) {
            const prev = self.authorized_topics.get(token.topic) orelse 0;
            try self.authorized_topics.put(self.allocator, token.topic, prev | token.perms);
        }
    }

    pub fn authorizeTopic(self: *SyncClient, topic: [32]u8, perms: u8) !void {
        if (self.authorized_topics.get(topic)) |existing| {
            if ((existing & perms) == perms) return;
        }
        if (self.scoped_tokens.get(topic)) |tok| {
            if ((tok.perms & perms) == perms) {
                try self.authorizeWithToken(tok);
                return;
            }
        }
        if (self.auth_secret == null) return error.MissingCapabilityToken;
        try self.authorizeTopicWithExpiry(topic, perms, 0);
        const prev = self.authorized_topics.get(topic) orelse 0;
        try self.authorized_topics.put(self.allocator, topic, prev | perms);
    }

    pub fn authorizeTopicWithExpiry(self: *SyncClient, topic: [32]u8, perms: u8, expires_ms: u64) !void {
        const secret = self.auth_secret orelse return error.MissingAuthSecret;
        var token = CapabilityToken.mint(secret, topic, perms, expires_ms);
        defer crypto.zeroize(&token.mac);
        try self.authorizeWithToken(token);
    }

    pub fn putEncryptedFrame(self: *SyncClient, topic: [32]u8, plaintext: []const u8) !u64 {
        const gop = try self.out_seqs.getOrPut(self.allocator, topic);
        const next_seq: u64 = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        gop.value_ptr.* = next_seq;

        const framed = try sealFramePayload(self.allocator, self.io, self.master_key, topic, self.sender_id, next_seq, plaintext);
        defer self.allocator.free(framed);

        const payload = try self.allocator.alloc(u8, 32 + framed.len);
        defer self.allocator.free(payload);
        @memcpy(payload[0..32], &topic);
        @memcpy(payload[32..], framed);

        try wire.writeFrameBlocking(self.allocator, self.fd, .put_frame, 0, payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op != .ack or resp.payload.len < 8) return error.PutFrameFailed;
        return std.mem.readInt(u64, resp.payload[0..8], .little);
    }

    pub fn getEncryptedRangePage(
        self: *SyncClient,
        allocator: Allocator,
        topic: [32]u8,
        after_seq: u64,
        limit: u32,
    ) !RangePage {
        var req: [32 + 8 + 4]u8 = undefined;
        @memcpy(req[0..32], &topic);
        std.mem.writeInt(u64, req[32..40], after_seq, .little);
        std.mem.writeInt(u32, req[40..44], limit, .little);
        try wire.writeFrameBlocking(self.allocator, self.fd, .get_range, 0, &req);

        var out: std.ArrayList(DecryptedFrame) = .empty;
        errdefer {
            for (out.items) |*f| f.deinit(allocator);
            out.deinit(allocator);
        }

        var last_seq = after_seq;
        var has_more = false;
        var item_count: usize = 0;

        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            defer frame.deinit(self.allocator);
            if (frame.op == .range_end) {
                has_more = (frame.flags & wire.RANGE_FLAG_HAS_MORE) != 0;
                break;
            }
            if (frame.op == .err) return error.RelayError;
            if (frame.op == .frame_event) {
                try self.bufferLiveEventFrame(&frame);
                continue;
            }
            if (frame.op != .range_item or frame.payload.len < 40) {
                self.drainUntilOp(.range_end);
                return error.BadRelayFrame;
            }

            const tid: [32]u8 = frame.payload[0..32].*;
            if (!std.mem.eql(u8, &tid, &topic)) {
                self.drainUntilOp(.range_end);
                return error.BadRelayFrame;
            }
            const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
            if (seq > last_seq) last_seq = seq;
            item_count += 1;

            const env = frame.payload[40..];
            const dec = openFramePayload(allocator, self.master_key, topic, env, &self.seen_seqs, self.allocator) catch |err| switch (err) {
                error.ReplayOrReorder => continue,
                error.InvalidEnvelope => {
                    self.recordQuarantine(tid, seq, .invalid_envelope);
                    continue;
                },
                error.AuthenticationFailed => {
                    self.recordQuarantine(tid, seq, .auth_failed);
                    continue;
                },
                else => {
                    self.drainUntilOp(.range_end);
                    return err;
                },
            };
            errdefer allocator.free(dec.plaintext);
            try out.append(allocator, .{
                .topic_id = tid,
                .seq = seq,
                .sender_id = dec.sender_id,
                .sender_seq = dec.sender_seq,
                .plaintext = dec.plaintext,
            });
        }
        return .{
            .frames = try out.toOwnedSlice(allocator),
            .last_seq = last_seq,
            .has_more = has_more,
            .item_count = item_count,
        };
    }

    pub fn getEncryptedRange(
        self: *SyncClient,
        allocator: Allocator,
        topic: [32]u8,
        after_seq: u64,
        limit: u32,
    ) ![]DecryptedFrame {
        var all: std.ArrayList(DecryptedFrame) = .empty;
        errdefer {
            for (all.items) |*f| f.deinit(allocator);
            all.deinit(allocator);
        }

        var cursor = after_seq;
        var seen_items: usize = 0;
        while (true) {
            const req_limit: u32 = if (limit == 0)
                PULL_PAGE_LIMIT
            else blk: {
                const rem = limit - @as(u32, @intCast(@min(seen_items, limit)));
                if (rem == 0) break;
                break :blk @min(rem, PULL_PAGE_LIMIT);
            };
            var page = try self.getEncryptedRangePage(allocator, topic, cursor, req_limit);
            errdefer page.deinit(allocator);

            for (page.frames) |f| {
                try all.append(allocator, f);
            }
            allocator.free(page.frames);
            page.frames = &.{};

            seen_items += page.item_count;
            if (!page.has_more or page.item_count == 0 or page.last_seq <= cursor) break;
            cursor = page.last_seq;
            if (limit > 0 and seen_items >= limit) break;
        }
        return try all.toOwnedSlice(allocator);
    }

    pub fn subscribe(self: *SyncClient, topic: [32]u8, after_seq: u64) ![]DecryptedFrame {
        var req: [32 + 8]u8 = undefined;
        @memcpy(req[0..32], &topic);
        std.mem.writeInt(u64, req[32..40], after_seq, .little);
        try wire.writeFrameBlocking(self.allocator, self.fd, .subscribe, 0, &req);

        var backlog: std.ArrayList(DecryptedFrame) = .empty;
        errdefer {
            for (backlog.items) |*f| f.deinit(self.allocator);
            backlog.deinit(self.allocator);
        }

        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            defer frame.deinit(self.allocator);
            if (frame.op == .ack) break;
            if (frame.op == .err) return error.RelayError;
            if (frame.op == .frame_event) {
                try self.bufferLiveEventFrame(&frame);
                continue;
            }
            if (frame.op == .range_item and frame.payload.len >= 40) {
                const tid: [32]u8 = frame.payload[0..32].*;
                if (!std.mem.eql(u8, &tid, &topic)) {
                    self.drainUntilOp(.ack);
                    return error.BadRelayFrame;
                }
                const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
                const dec = openFramePayload(self.allocator, self.master_key, topic, frame.payload[40..], &self.seen_seqs, self.allocator) catch |err| switch (err) {
                    error.ReplayOrReorder => continue,
                    error.InvalidEnvelope => {
                        self.recordQuarantine(tid, seq, .invalid_envelope);
                        continue;
                    },
                    error.AuthenticationFailed => {
                        self.recordQuarantine(tid, seq, .auth_failed);
                        continue;
                    },
                    else => {
                        self.drainUntilOp(.ack);
                        return err;
                    },
                };
                errdefer self.allocator.free(dec.plaintext);
                try backlog.append(self.allocator, .{
                    .topic_id = tid,
                    .seq = seq,
                    .sender_id = dec.sender_id,
                    .sender_seq = dec.sender_seq,
                    .plaintext = dec.plaintext,
                });
            }
        }
        return try backlog.toOwnedSlice(self.allocator);
    }

    pub fn readLiveEvent(self: *SyncClient, allocator: Allocator) !DecryptedFrame {
        if (self.pending_events.items.len > 0) {
            var ev = self.pending_events.orderedRemove(0);
            const duped = try allocator.dupe(u8, ev.plaintext);
            ev.deinit(self.allocator);
            ev.plaintext = duped;
            return ev;
        }
        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            defer frame.deinit(self.allocator);
            if (frame.op != .frame_event or frame.payload.len < 40) return error.BadRelayFrame;
            const tid: [32]u8 = frame.payload[0..32].*;
            const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
            const dec = openFramePayload(allocator, self.master_key, tid, frame.payload[40..], &self.seen_seqs, self.allocator) catch |err| switch (err) {
                error.ReplayOrReorder => continue,
                error.InvalidEnvelope => {
                    self.recordQuarantine(tid, seq, .invalid_envelope);
                    continue;
                },
                error.AuthenticationFailed => {
                    self.recordQuarantine(tid, seq, .auth_failed);
                    continue;
                },
                else => return err,
            };
            return .{
                .topic_id = tid,
                .seq = seq,
                .sender_id = dec.sender_id,
                .sender_seq = dec.sender_seq,
                .plaintext = dec.plaintext,
            };
        }
    }

    pub fn putEncryptedBlob(self: *SyncClient, topic: [32]u8, oid: [32]u8, plaintext: []const u8) !void {
        var key = crypto.deriveTopicKey(self.master_key, topic);
        defer crypto.zeroize(&key);
        const lookup_id = crypto.deriveBlobLookupId(self.master_key, topic, oid);
        const aad = buildBlobAad(topic, oid);
        const sealed = try crypto.sealRandom(self.allocator, self.io, key, &aad, plaintext);
        defer self.allocator.free(sealed);

        const payload = try self.allocator.alloc(u8, 64 + sealed.len);
        defer self.allocator.free(payload);
        @memcpy(payload[0..32], &topic);
        @memcpy(payload[32..64], &lookup_id);
        @memcpy(payload[64..], sealed);

        try wire.writeFrameBlocking(self.allocator, self.fd, .put_blob, 0, payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op != .ack) return error.PutBlobFailed;
    }

    pub fn getEncryptedBlob(self: *SyncClient, allocator: Allocator, topic: [32]u8, oid: [32]u8) !?[]u8 {
        const lookup_id = crypto.deriveBlobLookupId(self.master_key, topic, oid);
        var req: [64]u8 = undefined;
        @memcpy(req[0..32], &topic);
        @memcpy(req[32..64], &lookup_id);
        try wire.writeFrameBlocking(self.allocator, self.fd, .get_blob, 0, &req);

        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op != .blob_data or resp.payload.len < 33) return error.GetBlobFailed;
        if (resp.payload[32] == 0) return null;
        var key = crypto.deriveTopicKey(self.master_key, topic);
        defer crypto.zeroize(&key);
        const aad = buildBlobAad(topic, oid);
        const plain = try crypto.open(allocator, key, &aad, resp.payload[33..]);
        errdefer allocator.free(plain);
        const actual = crypto.hashBytes(plain);
        if (!std.mem.eql(u8, &actual, &oid)) return error.HashMismatch;
        return plain;
    }

    pub fn putEncryptedGitBlob(self: *SyncClient, topic: [32]u8, git_oid: git_dirs_mod.GitOid, plaintext: []const u8) !void {
        const key_oid = gitBlobLookupOid(git_oid);
        try self.putEncryptedBlob(topic, key_oid, plaintext);
    }

    pub fn getEncryptedGitBlob(self: *SyncClient, allocator: Allocator, topic: [32]u8, git_oid: git_dirs_mod.GitOid) !?[]u8 {
        const key_oid = gitBlobLookupOid(git_oid);
        const lookup_id = crypto.deriveBlobLookupId(self.master_key, topic, key_oid);
        var req: [64]u8 = undefined;
        @memcpy(req[0..32], &topic);
        @memcpy(req[32..64], &lookup_id);
        try wire.writeFrameBlocking(self.allocator, self.fd, .get_blob, 0, &req);

        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op != .blob_data or resp.payload.len < 33) return error.GetBlobFailed;
        if (resp.payload[32] == 0) return null;
        var key = crypto.deriveTopicKey(self.master_key, topic);
        defer crypto.zeroize(&key);
        const aad = buildBlobAad(topic, key_oid);
        const plain = try crypto.open(allocator, key, &aad, resp.payload[33..]);
        errdefer allocator.free(plain);
        const fmt: git_dirs_mod.ObjectFormat = if (git_oid.len == 32) .sha256 else .sha1;
        const actual = git_dirs_mod.GitOid.ofBlob(fmt, plain);
        if (!actual.eql(git_oid)) return error.HashMismatch;
        return plain;
    }

    pub fn pushSessionSummary(self: *SyncClient, vault_id: u128, summary: *const model.SessionSummary) !u64 {
        const topic = id.catalogStreamId(vault_id);
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try summary.encode(self.allocator, &w);
        return try self.putEncryptedFrame(topic, w.items());
    }

    pub fn pullSessionSummaries(
        self: *SyncClient,
        allocator: Allocator,
        vault_id: u128,
        after_seq: u64,
    ) !struct { summaries: []model.SessionSummary, last_seq: u64 } {
        const topic = id.catalogStreamId(vault_id);
        const frames = try self.getEncryptedRange(self.allocator, topic, after_seq, 0);
        defer {
            for (frames) |*f| f.deinit(self.allocator);
            self.allocator.free(frames);
        }

        var latest: std.AutoHashMapUnmanaged(u128, model.SessionSummary) = .empty;
        defer {
            var it = latest.valueIterator();
            while (it.next()) |s| s.deinit(allocator);
            latest.deinit(allocator);
        }

        var last_seq = after_seq;
        for (frames) |f| {
            if (f.seq > last_seq) last_seq = f.seq;
            var r = codec.Reader.init(f.plaintext);
            const sum = model.SessionSummary.decode(allocator, &r) catch {
                self.recordQuarantine(topic, f.seq, .decode_failed);
                continue;
            };
            const gop = try latest.getOrPut(allocator, sum.thread_id);
            if (gop.found_existing) gop.value_ptr.deinit(allocator);
            gop.value_ptr.* = sum;
        }

        const out = try allocator.alloc(model.SessionSummary, latest.count());
        var idx: usize = 0;
        var it = latest.valueIterator();
        while (it.next()) |s| {
            out[idx] = s.*;
            idx += 1;
        }
        latest.clearRetainingCapacity();
        std.mem.sort(model.SessionSummary, out, {}, struct {
            fn lessThan(_: void, a: model.SessionSummary, b: model.SessionSummary) bool {
                return a.updated_ms > b.updated_ms;
            }
        }.lessThan);
        return .{ .summaries = out, .last_seq = last_seq };
    }

    pub fn pushPageChain(
        self: *SyncClient,
        thread_id: u128,
        local_pages: *blobs_mod.BlobStore,
        head_page: ?id.PageId,
    ) !usize {
        const topic = id.threadStreamId(thread_id);
        var cur = head_page;
        var uploaded: usize = 0;
        while (cur) |pid| {
            if (self.uploaded_blobs.contains(pid)) break;
            const raw = try local_pages.get(self.allocator, pid) orelse break;
            defer self.allocator.free(raw);
            try self.putEncryptedBlob(topic, pid, raw);
            try self.uploaded_blobs.put(self.allocator, pid, {});
            uploaded += 1;
            var page = try pager.MessagePage.decode(self.allocator, raw);
            defer page.deinit(self.allocator);
            cur = page.prev_page;
        }
        return uploaded;
    }

    pub fn fetchPageLocalFirst(
        self: *SyncClient,
        allocator: Allocator,
        thread_id: u128,
        local_cache: *blobs_mod.BlobStore,
        page_id: id.PageId,
    ) !?pager.MessagePage {
        if (try pager.loadPage(allocator, local_cache, page_id)) |cached| {
            return cached;
        }
        const topic = id.threadStreamId(thread_id);
        const raw = try self.getEncryptedBlob(self.allocator, topic, page_id) orelse return null;
        defer self.allocator.free(raw);
        try local_cache.putVerified(page_id, raw);
        return try pager.MessagePage.decode(allocator, raw);
    }

    pub fn pushLiveMessage(self: *SyncClient, thread_id: u128, msg: *const model.Message) !u64 {
        const topic = id.threadStreamId(thread_id);
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try msg.encode(self.allocator, &w);
        return try self.putEncryptedFrame(topic, w.items());
    }

    pub fn pushBatch(self: *SyncClient, history_id: u128, batch: *const op_mod.Batch) !u64 {
        const topic = id.worktreeStreamId(history_id);
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try batch.encode(self.allocator, &w);
        return try self.putEncryptedFrame(topic, w.items());
    }

    pub fn waitingCount(self: *const SyncClient, ws: *const ws_mod.Workspace) usize {
        const st = self.ws_states.get(ws.disk_actor) orelse return 0;
        return st.waiting.items.len;
    }

    pub fn loadWorkspaceCursor(self: *SyncClient, ws: *ws_mod.Workspace) !void {
        _ = try self.getOrLoadWorkspaceState(ws);
    }

    pub fn persistWorkspaceCursor(self: *SyncClient, ws: *ws_mod.Workspace) !void {
        const st = try self.getOrLoadWorkspaceState(ws);
        try self.saveWorkspaceCursorFile(ws, st);
    }

    fn getOrLoadWorkspaceState(self: *SyncClient, ws: *ws_mod.Workspace) !*WorkspaceSyncState {
        const gop = try self.ws_states.getOrPut(self.allocator, ws.disk_actor);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            self.loadWorkspaceCursorFile(ws, gop.value_ptr);
        }
        return gop.value_ptr;
    }

    fn loadWorkspaceCursorFile(self: *SyncClient, ws: *ws_mod.Workspace, st: *WorkspaceSyncState) void {
        const f = ws.state_dir.openFile(self.io, "sync_cursor.0ndb", .{}) catch return;
        defer f.close(self.io);
        const stat = f.stat(self.io) catch return;
        if (stat.size < 14 or stat.size > 32 * 1024 * 1024) return;
        const buf = self.allocator.alloc(u8, @intCast(stat.size)) catch return;
        defer self.allocator.free(buf);
        const n = f.readPositionalAll(self.io, buf, 0) catch return;
        if (n != buf.len) return;

        var r = codec.Reader.init(buf);
        const magic = r.readU32() catch return;
        const ver = r.readU16() catch return;
        if (magic != SYNC_CURSOR_MAGIC) return;
        if (ver != SYNC_CURSOR_VERSION_V1 and ver != SYNC_CURSOR_VERSION) return;

        const saved_sender = r.readU128() catch return;
        const out_count: usize = if (ver == SYNC_CURSOR_VERSION_V1)
            @intCast(r.readU32() catch return)
        else
            r.readCount(40, 65536) catch return;
        if (out_count > r.remaining() / 40) return;

        const adopt_sender = self.out_seqs.count() == 0;
        if (adopt_sender and saved_sender != 0) {
            self.sender_id = saved_sender;
        }
        const merge_out = adopt_sender or (saved_sender == self.sender_id);
        for (0..out_count) |_| {
            const topic = (r.readFixed(32) catch return).*;
            const seq = r.readU64() catch return;
            if (merge_out) {
                const prev = self.out_seqs.get(topic) orelse 0;
                const merged = @max(prev, seq);
                self.out_seqs.put(self.allocator, topic, merged) catch return;
                const prev_p = self.persisted_out_seqs.get(topic) orelse 0;
                self.persisted_out_seqs.put(self.allocator, topic, @max(prev_p, merged)) catch return;
            }
        }

        st.last_pulled_seq = r.readU64() catch return;
        const batch_count: usize = if (ver == SYNC_CURSOR_VERSION_V1)
            @intCast(r.readU32() catch return)
        else
            r.readCount(24, 1_000_000) catch return;
        if (batch_count > r.remaining() / 24) return;
        for (0..batch_count) |_| {
            const actor = r.readU128() catch return;
            const ts = r.readU64() catch return;
            st.pushed_batches.put(self.allocator, id.OpId.init(ts, actor), {}) catch return;
        }

        const blob_count: usize = if (ver == SYNC_CURSOR_VERSION_V1)
            @intCast(r.readU32() catch return)
        else
            r.readCount(32, 1_000_000) catch return;
        if (blob_count > r.remaining() / 32) return;
        for (0..blob_count) |_| {
            const oid = (r.readFixed(32) catch return).*;
            st.uploaded_blobs.put(self.allocator, oid, {}) catch return;
        }

        if (ver >= SYNC_CURSOR_VERSION and r.remaining() > 0) {
            const seen_count = r.readCount(56, 1_000_000) catch return;
            for (0..seen_count) |_| {
                const topic = (r.readFixed(32) catch return).*;
                const sid = r.readU128() catch return;
                const last_seen = r.readU64() catch return;
                const sk = SenderKey{ .topic = topic, .sender_id = sid };
                const prev = self.seen_seqs.get(sk) orelse 0;
                if (last_seen > prev) {
                    self.seen_seqs.put(self.allocator, sk, last_seen) catch return;
                }
            }
            if (r.remaining() > 0) {
                const wait_count = r.readCount(25, MAX_WAITING_BATCHES) catch return;
                for (0..wait_count) |_| {
                    const actor = r.readU128() catch return;
                    const ts = r.readU64() catch return;
                    const raw = r.readBytes() catch return;
                    _ = st.addWaiting(self.allocator, id.OpId.init(ts, actor), raw) catch return;
                }
            }
        }
    }

    fn saveWorkspaceCursorFile(self: *SyncClient, ws: *ws_mod.Workspace, st: *const WorkspaceSyncState) !void {
        var combined_out: std.AutoHashMapUnmanaged([32]u8, u64) = .empty;
        defer combined_out.deinit(self.allocator);
        {
            var oit = self.out_seqs.iterator();
            while (oit.next()) |e| {
                try combined_out.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
            }
            var pit = self.persisted_out_seqs.iterator();
            while (pit.next()) |e| {
                const prev = combined_out.get(e.key_ptr.*) orelse 0;
                try combined_out.put(self.allocator, e.key_ptr.*, @max(prev, e.value_ptr.*));
            }
        }

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, SYNC_CURSOR_MAGIC);
        try w.writeU16(self.allocator, SYNC_CURSOR_VERSION);
        try w.writeU128(self.allocator, self.sender_id);
        try w.writeVarint(self.allocator, combined_out.count());
        var oit = combined_out.iterator();
        while (oit.next()) |e| {
            try w.writeRaw(self.allocator, &e.key_ptr.*);
            try w.writeU64(self.allocator, e.value_ptr.*);
        }
        try w.writeU64(self.allocator, st.last_pulled_seq);
        try w.writeVarint(self.allocator, st.pushed_batches.count());
        var bit = st.pushed_batches.keyIterator();
        while (bit.next()) |bid| {
            try w.writeU128(self.allocator, bid.actor);
            try w.writeU64(self.allocator, bid.ts);
        }
        try w.writeVarint(self.allocator, st.uploaded_blobs.count());
        var blit = st.uploaded_blobs.keyIterator();
        while (blit.next()) |oid| {
            try w.writeRaw(self.allocator, &oid.*);
        }
        try w.writeVarint(self.allocator, self.seen_seqs.count());
        var sit = self.seen_seqs.iterator();
        while (sit.next()) |e| {
            try w.writeRaw(self.allocator, &e.key_ptr.topic);
            try w.writeU128(self.allocator, e.key_ptr.sender_id);
            try w.writeU64(self.allocator, e.value_ptr.*);
        }
        try w.writeVarint(self.allocator, st.waiting.items.len);
        for (st.waiting.items) |wb| {
            try w.writeU128(self.allocator, wb.batch_id.actor);
            try w.writeU64(self.allocator, wb.batch_id.ts);
            try w.writeBytes(self.allocator, wb.raw_batch);
        }

        const tmp = "sync_cursor.0ndb.tmp";
        const f = try ws.state_dir.createFile(self.io, tmp, .{ .truncate = true });
        var f_closed = false;
        errdefer {
            if (!f_closed) f.close(self.io);
            ws.state_dir.deleteFile(self.io, tmp) catch {};
        }
        try f.writePositionalAll(self.io, w.items(), 0);
        f.sync(self.io) catch {};
        f.close(self.io);
        f_closed = true;
        try ws.state_dir.rename(tmp, ws.state_dir, "sync_cursor.0ndb", self.io);
    }

    fn reserveTopicSeqForWorkspace(
        self: *SyncClient,
        ws: *ws_mod.Workspace,
        st: *const WorkspaceSyncState,
        topic: [32]u8,
    ) !void {
        const used = self.out_seqs.get(topic) orelse 0;
        const reserved = self.persisted_out_seqs.get(topic) orelse 0;
        if (used + 1 <= reserved) return;
        const new_reserved = used + SEQ_RESERVE_STRIDE;
        try self.persisted_out_seqs.put(self.allocator, topic, new_reserved);
        try self.saveWorkspaceCursorFile(ws, st);
    }

    pub fn pushWorkspace(self: *SyncClient, ws: *ws_mod.Workspace) !usize {
        const topic = id.worktreeStreamId(ws.history.history_id);
        try self.authorizeTopic(topic, wire.PERM_WRITE);
        const st = try self.getOrLoadWorkspaceState(ws);
        var pushed: usize = 0;

        var all_bids = try ws.history.dag.collectAllBatchIds(self.allocator);
        defer all_bids.deinit(self.allocator);
        ws.history.dag.topoSortSlice(all_bids.items);

        for (all_bids.items) |bid| {
            if (st.pushed_batches.contains(bid)) continue;
            const raw_payload = (try ws.readBatchPayloadAlloc(self.allocator, bid)) orelse continue;
            defer self.allocator.free(raw_payload);
            var r = codec.Reader.init(raw_payload);
            var batch = try op_mod.Batch.decode(self.allocator, &r);
            defer batch.deinit(self.allocator);

            for (batch.blobs) |b| {
                if (!st.uploaded_blobs.contains(b.oid)) {
                    try self.putEncryptedBlob(topic, b.oid, b.data);
                    try st.uploaded_blobs.put(self.allocator, b.oid, {});
                }
            }
            for (batch.ops) |op| {
                if (opReferencedBlob(op)) |ref| {
                    switch (ref) {
                        .blake3 => |br| {
                            if (!st.uploaded_blobs.contains(br.oid)) {
                                if (try ws.blob_store.get(self.allocator, br.oid)) |raw| {
                                    defer self.allocator.free(raw);
                                    try self.putEncryptedBlob(topic, br.oid, raw);
                                    try st.uploaded_blobs.put(self.allocator, br.oid, {});
                                } else if (ws.history.resolveBlob(br.oid)) |raw| {
                                    try self.putEncryptedBlob(topic, br.oid, raw);
                                    try st.uploaded_blobs.put(self.allocator, br.oid, {});
                                }
                            }
                        },
                        .git => |git_oid| {
                            const key_oid = gitBlobLookupOid(git_oid);
                            if (!st.uploaded_blobs.contains(key_oid)) {
                                if (try ws.history.readGitBlobAlloc(self.allocator, git_oid)) |raw| {
                                    defer self.allocator.free(raw);
                                    try self.putEncryptedGitBlob(topic, git_oid, raw);
                                    try st.uploaded_blobs.put(self.allocator, key_oid, {});
                                }
                            }
                        },
                    }
                }
            }

            try self.reserveTopicSeqForWorkspace(ws, st, topic);

            if (batch.blobs.len > 0) {
                var stripped = batch;
                stripped.blobs = &.{};
                var w = codec.Writer{};
                defer w.deinit(self.allocator);
                try stripped.encode(self.allocator, &w);
                _ = try self.putEncryptedFrame(topic, w.items());
            } else {
                _ = try self.putEncryptedFrame(topic, raw_payload);
            }
            try st.pushed_batches.put(self.allocator, bid, {});
            pushed += 1;
        }
        if (pushed > 0) {
            try self.saveWorkspaceCursorFile(ws, st);
        }
        return pushed;
    }

    fn tryIntegrateBatch(
        self: *SyncClient,
        ws: *ws_mod.Workspace,
        st: *WorkspaceSyncState,
        topic: [32]u8,
        batch: *const op_mod.Batch,
    ) !IntegrateOutcome {
        const bid = batch.header.batchId();
        if (ws.history.dag.containsBatch(bid)) {
            if (!st.pushed_batches.contains(bid)) {
                try st.pushed_batches.put(self.allocator, bid, {});
            }
            return .already_present;
        }

        for (batch.blobs) |b| {
            if (!ws.blob_store.exists(b.oid)) {
                try ws.blob_store.putVerified(b.oid, b.data);
            }
        }
        for (batch.ops) |op| {
            if (opReferencedBlob(op)) |ref| {
                switch (ref) {
                    .blake3 => |br| {
                        if (!ws.blob_store.exists(br.oid)) {
                            const raw_opt = self.getEncryptedBlob(self.allocator, topic, br.oid) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => return .waiting_blob,
                            };
                            const raw = raw_opt orelse return .waiting_blob;
                            defer self.allocator.free(raw);
                            try ws.blob_store.putVerified(br.oid, raw);
                        }
                    },
                    .git => |git_oid| {
                        const local = ws.history.readGitBlobAlloc(self.allocator, git_oid) catch null;
                        if (local) |buf| {
                            self.allocator.free(buf);
                        } else {
                            const raw_opt = self.getEncryptedGitBlob(self.allocator, topic, git_oid) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => return .waiting_blob,
                            };
                            const raw = raw_opt orelse return .waiting_blob;
                            defer self.allocator.free(raw);
                            try ws.blob_store.putGitFallback(git_oid.slice(), raw);
                        }
                    },
                }
            }
        }

        const committed = ws.commitBatchWithSource(batch, "sync") catch |err| switch (err) {
            error.MissingParents => return .waiting_parents,
            else => return err,
        };
        if (!st.pushed_batches.contains(bid)) {
            try st.pushed_batches.put(self.allocator, bid, {});
        }
        return if (committed) .applied else .already_present;
    }

    fn drainWaiting(
        self: *SyncClient,
        ws: *ws_mod.Workspace,
        st: *WorkspaceSyncState,
        topic: [32]u8,
    ) !usize {
        var total_applied: usize = 0;
        var progress = true;
        while (progress and st.waiting.items.len > 0) {
            progress = false;
            var i: usize = 0;
            while (i < st.waiting.items.len) {
                var r = codec.Reader.init(st.waiting.items[i].raw_batch);
                var batch = op_mod.Batch.decode(self.allocator, &r) catch {
                    const bad = st.waiting.orderedRemove(i);
                    self.allocator.free(bad.raw_batch);
                    continue;
                };
                defer batch.deinit(self.allocator);
                const outcome = try self.tryIntegrateBatch(ws, st, topic, &batch);
                switch (outcome) {
                    .applied => {
                        total_applied += 1;
                        progress = true;
                        const done = st.waiting.orderedRemove(i);
                        self.allocator.free(done.raw_batch);
                    },
                    .already_present => {
                        const done = st.waiting.orderedRemove(i);
                        self.allocator.free(done.raw_batch);
                    },
                    .waiting_parents, .waiting_blob => {
                        i += 1;
                    },
                }
            }
        }
        return total_applied;
    }

    pub fn pullWorkspace(
        self: *SyncClient,
        ws: *ws_mod.Workspace,
        after_seq: u64,
    ) !struct { applied: usize, last_seq: u64 } {
        const topic = id.worktreeStreamId(ws.history.history_id);
        try self.authorizeTopic(topic, wire.PERM_READ);
        const st = try self.getOrLoadWorkspaceState(ws);
        const effective_after = @max(after_seq, st.last_pulled_seq);

        var applied: usize = 0;
        var last_seq = effective_after;
        var dirty = false;

        while (true) {
            const prev_seq = last_seq;
            var page = try self.getEncryptedRangePage(self.allocator, topic, prev_seq, PULL_PAGE_LIMIT);
            defer page.deinit(self.allocator);

            for (page.frames) |f| {
                if (f.seq > last_seq) {
                    last_seq = f.seq;
                    dirty = true;
                }
                var r = codec.Reader.init(f.plaintext);
                var batch = op_mod.Batch.decode(self.allocator, &r) catch {
                    self.recordQuarantine(topic, f.seq, .decode_failed);
                    continue;
                };
                defer batch.deinit(self.allocator);
                const bid = batch.header.batchId();
                const outcome = try self.tryIntegrateBatch(ws, st, topic, &batch);
                switch (outcome) {
                    .applied => {
                        applied += 1;
                        dirty = true;
                        const drained = try self.drainWaiting(ws, st, topic);
                        if (drained > 0) applied += drained;
                    },
                    .already_present => {
                        dirty = true;
                    },
                    .waiting_parents, .waiting_blob => {
                        if (try st.addWaiting(self.allocator, bid, f.plaintext)) {
                            dirty = true;
                        }
                    },
                }
            }

            if (page.last_seq > last_seq) {
                last_seq = page.last_seq;
                dirty = true;
            }
            if (!page.has_more or page.item_count == 0 or last_seq <= prev_seq) break;
        }

        if (st.waiting.items.len > 0) {
            const drained = try self.drainWaiting(ws, st, topic);
            if (drained > 0) {
                applied += drained;
                dirty = true;
            }
        }

        if (last_seq > st.last_pulled_seq) {
            st.last_pulled_seq = last_seq;
            dirty = true;
        }
        if (dirty) {
            try self.saveWorkspaceCursorFile(ws, st);
        }
        if (applied > 0) {
            try ws.materializeToDisk();
        }
        return .{ .applied = applied, .last_seq = last_seq };
    }
};
