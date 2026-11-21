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
const keyring_mod = @import("keyring.zig");
const space_mod = @import("../space/space.zig");
const projection_mod = @import("../fs/projection.zig");
const thread_model = @import("../thread/model.zig");
const thread_store_mod = @import("../thread/store.zig");
const mmap = @import("../store/mmap.zig");
const version_mod = @import("../core/version.zig");
const text_mod = @import("../core/text.zig");

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

            try all.ensureUnusedCapacity(allocator, page.frames.len);
            for (page.frames) |f| {
                all.appendAssumeCapacity(f);
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
        if (!std.mem.eql(u8, resp.payload[0..32], &lookup_id)) return error.GetBlobFailed;
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
        if (!std.mem.eql(u8, resp.payload[0..32], &lookup_id)) return error.GetBlobFailed;
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
            if (last_seq > st.last_pulled_seq) {
                st.last_pulled_seq = last_seq;
                dirty = true;
            }
            if (dirty) {
                try self.saveWorkspaceCursorFile(ws, st);
                dirty = false;
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

pub const TopicKind = enum(u8) {
    catalog = 1,
    project = 2,
    space = 3,
    thread = 4,
    mailbox = 5,
};

pub fn topicIdFor(kind: TopicKind, entity_id: u128) [32]u8 {
    return switch (kind) {
        .catalog => id.catalogStreamId(entity_id),
        .project => id.streamId("project", entity_id),
        .space => id.spaceStreamId(entity_id),
        .thread => id.threadStreamId(entity_id),
        .mailbox => id.streamId("mailbox", entity_id),
    };
}

pub const HydrationPolicy = enum(u8) {
    thin_client = 0,
    workstation = 1,
    cloud_runner = 2,
};

pub const FramePutResult = struct {
    seq: u64,
    wire_bytes: usize,
};

pub const SyncStats = struct {
    frames_pushed: usize = 0,
    frames_pulled: usize = 0,
    blobs_pushed: usize = 0,
    blobs_pulled: usize = 0,
    git_blobs_skipped: usize = 0,
    bytes_transferred: usize = 0,
    last_seq: u64 = 0,
};

pub const LeaseResult = struct {
    epoch: u64 = 0,
    holder: u128 = 0,
    expires_at_ms: u64 = 0,
    handoff_target: ?u128 = null,
    canceled: bool = false,
    cancel_epoch: u64 = 0,

    pub fn fromWire(resp: wire.LeaseResponse) LeaseResult {
        return .{
            .epoch = resp.fencing_epoch,
            .holder = resp.holder_runner_id,
            .expires_at_ms = resp.expires_ms,
            .handoff_target = resp.handoff_target,
            .canceled = resp.canceled,
            .cancel_epoch = resp.cancel_epoch,
        };
    }
};

pub const LeaseCancelEvent = struct {
    topic_id: [32]u8,
    lease: LeaseResult,
};

pub const CapabilityTokenV3 = struct {
    topic: [32]u8,
    perms: u32,
    expires_ms: u64,
    mac: crypto.Mac,

    pub const ENCODED_LEN: usize = wire.AUTH_V3_LEN;

    pub fn mint(secret: [32]u8, topic: [32]u8, perms: u32, expires_ms: u64) CapabilityTokenV3 {
        return .{
            .topic = topic,
            .perms = perms,
            .expires_ms = expires_ms,
            .mac = crypto.deriveCapabilityTokenV3(secret, topic, perms, expires_ms),
        };
    }

    pub fn encode(self: CapabilityTokenV3) [ENCODED_LEN]u8 {
        return wire.encodeAuthV3(self.topic, self.perms, self.expires_ms, self.mac);
    }

    pub fn decode(data: []const u8) !CapabilityTokenV3 {
        if (data.len != ENCODED_LEN) return error.InvalidToken;
        return .{
            .topic = data[0..32].*,
            .perms = std.mem.readInt(u32, data[32..36], .little),
            .expires_ms = std.mem.readInt(u64, data[36..44], .little),
            .mac = data[44..76].*,
        };
    }

    pub fn zeroize(self: *CapabilityTokenV3) void {
        crypto.zeroize(&self.mac);
    }
};

pub const AttenuatedGrantSpec = struct {
    topic_id: [32]u8,
    perms: u32,
    expires_ms: u64 = 0,
};

pub fn sealDelegationBundle(
    allocator: Allocator,
    captain_keyring: *const keyring_mod.Keyring,
    auth_secret: [32]u8,
    target_runner: u128,
    target_pubkey: [32]u8,
    bundle_expires_ms: u64,
    grants: []const AttenuatedGrantSpec,
) ![]u8 {
    const reqs = try allocator.alloc(keyring_mod.DelegationRequest, grants.len);
    defer allocator.free(reqs);
    const enc_tokens = try allocator.alloc([wire.AUTH_V3_LEN]u8, grants.len);
    defer {
        for (enc_tokens) |*t| crypto.zeroize(t);
        allocator.free(enc_tokens);
    }

    for (grants, 0..) |g, i| {
        const eff_exp: u64 = blk: {
            if (bundle_expires_ms == 0) break :blk g.expires_ms;
            if (g.expires_ms == 0) break :blk bundle_expires_ms;
            break :blk @min(bundle_expires_ms, g.expires_ms);
        };
        var tok = CapabilityTokenV3.mint(auth_secret, g.topic_id, g.perms, eff_exp);
        defer tok.zeroize();
        enc_tokens[i] = tok.encode();
        reqs[i] = .{
            .topic_id = g.topic_id,
            .perms = g.perms,
            .expires_ms = g.expires_ms,
            .token = &enc_tokens[i],
        };
    }

    return captain_keyring.createDelegationBundle(
        allocator,
        target_runner,
        target_pubkey,
        bundle_expires_ms,
        reqs,
    );
}

const FRAME_V3_VERSION: u8 = 3;
const FRAME_V3_HEADER_LEN: usize = 1 + 4 + 16 + 8;
const FRAME_V3_AAD_PREFIX = "0ndb-frame-v3";
const BLOB_V3_AAD_PREFIX = "0ndb-blob-v3";
const INBOX_FRAME_VERSION: u8 = 1;
const SPACE_CURSOR_V3_MAGIC: u32 = 0x33534353;
const SPACE_CURSOR_V3_VERSION: u16 = 3;
const LOG_CURSOR_V3_MAGIC: u32 = 0x334C4353;
const LOG_CURSOR_V3_VERSION: u16 = 3;

fn buildFrameAadV3(
    topic: [32]u8,
    key_epoch: u32,
    sender_id: u128,
    sender_seq: u64,
) [FRAME_V3_AAD_PREFIX.len + 32 + 4 + 16 + 8]u8 {
    var aad: [FRAME_V3_AAD_PREFIX.len + 32 + 4 + 16 + 8]u8 = undefined;
    const p0 = FRAME_V3_AAD_PREFIX.len;
    @memcpy(aad[0..p0], FRAME_V3_AAD_PREFIX);
    @memcpy(aad[p0 .. p0 + 32], &topic);
    std.mem.writeInt(u32, aad[p0 + 32 .. p0 + 36], key_epoch, .little);
    std.mem.writeInt(u128, aad[p0 + 36 .. p0 + 52], sender_id, .little);
    std.mem.writeInt(u64, aad[p0 + 52 .. p0 + 60], sender_seq, .little);
    return aad;
}

fn buildBlobAadV3(
    topic: [32]u8,
    key_epoch: u32,
    oid: [32]u8,
) [BLOB_V3_AAD_PREFIX.len + 32 + 4 + 32]u8 {
    var aad: [BLOB_V3_AAD_PREFIX.len + 32 + 4 + 32]u8 = undefined;
    const p0 = BLOB_V3_AAD_PREFIX.len;
    @memcpy(aad[0..p0], BLOB_V3_AAD_PREFIX);
    @memcpy(aad[p0 .. p0 + 32], &topic);
    std.mem.writeInt(u32, aad[p0 + 32 .. p0 + 36], key_epoch, .little);
    @memcpy(aad[p0 + 36 .. p0 + 68], &oid);
    return aad;
}

pub fn sealFramePayloadV3(
    allocator: Allocator,
    io: Io,
    entity_key: *const crypto.EntityKey,
    topic: [32]u8,
    sender_id: u128,
    sender_seq: u64,
    plaintext: []const u8,
) ![]u8 {
    var stream_key = crypto.deriveStreamKeyV3(entity_key, topic);
    defer crypto.zeroize(&stream_key);
    const aad = buildFrameAadV3(topic, entity_key.epoch, sender_id, sender_seq);
    const sealed = try crypto.sealRandom(allocator, io, stream_key, &aad, plaintext);
    defer allocator.free(sealed);

    const out = try allocator.alloc(u8, FRAME_V3_HEADER_LEN + sealed.len);
    out[0] = FRAME_V3_VERSION;
    std.mem.writeInt(u32, out[1..5], entity_key.epoch, .little);
    std.mem.writeInt(u128, out[5..21], sender_id, .little);
    std.mem.writeInt(u64, out[21..29], sender_seq, .little);
    @memcpy(out[FRAME_V3_HEADER_LEN..], sealed);
    return out;
}

pub fn openFramePayloadV3(
    allocator: Allocator,
    keyring: *const keyring_mod.Keyring,
    expected_topic: [32]u8,
    raw: []const u8,
    seen_seqs: *std.AutoHashMapUnmanaged(SenderKey, u64),
    seen_alloc: Allocator,
) !FramePayload {
    if (raw.len < FRAME_V3_HEADER_LEN + crypto.ENVELOPE_OVERHEAD) return error.InvalidEnvelope;
    if (raw[0] != FRAME_V3_VERSION) return error.InvalidEnvelope;
    const key_epoch = std.mem.readInt(u32, raw[1..5], .little);
    const sender_id = std.mem.readInt(u128, raw[5..21], .little);
    const sender_seq = std.mem.readInt(u64, raw[21..29], .little);
    if (sender_seq == 0) return error.ReplayOrReorder;

    const sk = SenderKey{ .topic = expected_topic, .sender_id = sender_id };
    if (seen_seqs.get(sk)) |prev| {
        if (sender_seq <= prev) return error.ReplayOrReorder;
    }

    const grant = keyring.getTopicGrant(expected_topic) orelse return error.TopicNotFound;
    if (key_epoch < grant.min_active_epoch) return error.EpochDowngrade;
    if (key_epoch != grant.entity_key.epoch) return error.AuthenticationFailed;

    var stream_key = crypto.deriveStreamKeyV3(&grant.entity_key, expected_topic);
    defer crypto.zeroize(&stream_key);
    const aad = buildFrameAadV3(expected_topic, key_epoch, sender_id, sender_seq);
    const plain = try crypto.open(allocator, stream_key, &aad, raw[FRAME_V3_HEADER_LEN..]);
    errdefer allocator.free(plain);

    try seen_seqs.put(seen_alloc, sk, sender_seq);
    return .{
        .sender_id = sender_id,
        .sender_seq = sender_seq,
        .plaintext = plain,
    };
}

pub fn getSpaceFileBlobOid(space: *const space_mod.Space, allocator: Allocator, rel_path: []const u8) !?id.Oid {
    const iid = (try space.history.tree.resolvePath(allocator, text_mod.View.EVERYTHING, rel_path)) orelse return null;
    space.history.tree.beginPinScope();
    defer space.history.tree.endPinScope();
    const inode = space.history.tree.get(iid) orelse return null;
    const alive = inode.alive.getIn(text_mod.View.EVERYTHING) orelse return null;
    if (!alive.*) return null;
    const f = inode.fileConstPtr() orelse return null;
    const ck = f.content.getIn(text_mod.View.EVERYTHING) orelse return null;
    return switch (ck.*) {
        .binary => |ref| ref.oid,
        else => null,
    };
}

pub const RangePageV3 = struct {
    frames: []DecryptedFrame,
    last_seq: u64,
    has_more: bool,
    item_count: usize,
    wire_bytes: usize,

    pub fn deinit(self: *RangePageV3, allocator: Allocator) void {
        for (self.frames) |*f| f.deinit(allocator);
        allocator.free(self.frames);
    }
};

const AuthGrantCache = struct {
    perms: u32,
    expires_ms: u64,
};

const SpaceCursorState = struct {
    has_pushed_once: bool = false,
    last_pushed_wal_seq: u64 = 0,
    last_pushed_heads: version_mod.Version = version_mod.Version.ROOT,
    last_pulled_seq: u64 = 0,
    out_seq: u64 = 0,
    pushed_batches: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty,
    uploaded_blobs: std.AutoHashMapUnmanaged([32]u8, void) = .empty,
    waiting: std.ArrayList(WaitingBatch) = .empty,

    fn deinit(self: *SpaceCursorState, allocator: Allocator) void {
        self.last_pushed_heads.deinit(allocator);
        self.pushed_batches.deinit(allocator);
        self.uploaded_blobs.deinit(allocator);
        for (self.waiting.items) |w| allocator.free(w.raw_batch);
        self.waiting.deinit(allocator);
    }

    fn containsWaiting(self: *const SpaceCursorState, bid: id.BatchId) bool {
        for (self.waiting.items) |w| {
            if (w.batch_id.eql(bid)) return true;
        }
        return false;
    }

    fn addWaiting(self: *SpaceCursorState, allocator: Allocator, bid: id.BatchId, raw: []const u8) !bool {
        if (self.containsWaiting(bid)) return false;
        if (self.waiting.items.len >= MAX_WAITING_BATCHES) return false;
        const dup = try allocator.dupe(u8, raw);
        errdefer allocator.free(dup);
        try self.waiting.append(allocator, .{ .batch_id = bid, .raw_batch = dup });
        return true;
    }
};

const LogCursorState = struct {
    last_pushed_local_seq: u64 = 0,
    last_pulled_relay_seq: u64 = 0,
    out_seq: u64 = 0,
    pushed_ids: std.AutoHashMapUnmanaged(u128, void) = .empty,

    fn deinit(self: *LogCursorState, allocator: Allocator) void {
        self.pushed_ids.deinit(allocator);
    }
};

fn computeRemoteTag(host_ip: [4]u8, port: u16) [32]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("0ndb-remote-v3:");
    h.update(&host_ip);
    var pbuf: [2]u8 = undefined;
    std.mem.writeInt(u16, &pbuf, port, .little);
    h.update(&pbuf);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn cursorFileName(remote_tag: [32]u8, topic_id: [32]u8, buf: *[80]u8) []const u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("0ndb-cursor-file-v3:");
    h.update(&remote_tag);
    h.update(&topic_id);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    var hex: [64]u8 = undefined;
    _ = id.formatHashHex(digest, &hex);
    return std.fmt.bufPrint(buf, "{s}.cur", .{hex}) catch unreachable;
}

fn hashBytesToU128(data: []const u8) u128 {
    const digest = crypto.hashBytes(data);
    return std.mem.readInt(u128, digest[0..16], .little);
}

fn deterministicInboxEventId(topic_id: [32]u8, item_id: u128) u128 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("0ndb-inbox-ev-v3:");
    h.update(&topic_id);
    var ibuf: [16]u8 = undefined;
    std.mem.writeInt(u128, &ibuf, item_id, .little);
    h.update(&ibuf);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.mem.readInt(u128, digest[0..16], .little);
}

pub const SyncClientV3 = struct {
    allocator: Allocator,
    io: Io,
    fd: posix.fd_t,
    keyring: *keyring_mod.Keyring,
    auth_secret: ?[32]u8,
    policy: HydrationPolicy,
    sender_id: u128,
    remote_tag: [32]u8,
    out_seqs: std.AutoHashMapUnmanaged([32]u8, u64),
    persisted_out_seqs: std.AutoHashMapUnmanaged([32]u8, u64),
    seen_seqs: std.AutoHashMapUnmanaged(SenderKey, u64),
    authorized_topics: std.AutoHashMapUnmanaged([32]u8, AuthGrantCache),
    scoped_tokens: std.AutoHashMapUnmanaged([32]u8, CapabilityTokenV3),
    pending_events: std.ArrayList(DecryptedFrame),
    pending_lease_cancels: std.ArrayList(LeaseCancelEvent),
    quarantined: std.ArrayList(QuarantinedFrame),
    quarantined_count: usize,
    last_lease_result: ?LeaseResult,
    cursor_dir: ?Io.Dir,
    shared_git_remote_verified: bool,

    fn connectInternal(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        remote_tag: [32]u8,
        keyring: *keyring_mod.Keyring,
        auth_secret: ?[32]u8,
        policy: HydrationPolicy,
    ) !SyncClientV3 {
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

        const sender = if (keyring.runner_id != 0) keyring.runner_id else id.newUuidV7(io);
        return .{
            .allocator = allocator,
            .io = io,
            .fd = fd,
            .keyring = keyring,
            .auth_secret = auth_secret,
            .policy = policy,
            .sender_id = sender,
            .remote_tag = remote_tag,
            .out_seqs = .empty,
            .persisted_out_seqs = .empty,
            .seen_seqs = .empty,
            .authorized_topics = .empty,
            .scoped_tokens = .empty,
            .pending_events = .empty,
            .pending_lease_cancels = .empty,
            .quarantined = .empty,
            .quarantined_count = 0,
            .last_lease_result = null,
            .cursor_dir = null,
            .shared_git_remote_verified = false,
        };
    }

    pub fn connect(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        keyring: *keyring_mod.Keyring,
        auth_secret: ?[32]u8,
        policy: HydrationPolicy,
    ) !SyncClientV3 {
        return connectInternal(
            allocator,
            io,
            host_ip,
            port,
            computeRemoteTag(host_ip, port),
            keyring,
            auth_secret,
            policy,
        );
    }

    pub fn connectWithRemoteUrl(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        remote_url: []const u8,
        keyring: *keyring_mod.Keyring,
        auth_secret: ?[32]u8,
        policy: HydrationPolicy,
    ) !SyncClientV3 {
        return connectInternal(
            allocator,
            io,
            host_ip,
            port,
            crypto.hashBytes(remote_url),
            keyring,
            auth_secret,
            policy,
        );
    }

    pub fn connectFromDelegationBundle(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        keyring: *keyring_mod.Keyring,
        sealed_bundle: []const u8,
        policy: HydrationPolicy,
    ) !SyncClientV3 {
        _ = try keyring.importDelegationBundle(sealed_bundle);
        return connect(allocator, io, host_ip, port, keyring, null, policy);
    }

    pub fn deinit(self: *SyncClientV3) void {
        for (self.pending_events.items) |*ev| ev.deinit(self.allocator);
        self.pending_events.deinit(self.allocator);
        self.pending_lease_cancels.deinit(self.allocator);
        self.quarantined.deinit(self.allocator);
        self.out_seqs.deinit(self.allocator);
        self.persisted_out_seqs.deinit(self.allocator);
        self.seen_seqs.deinit(self.allocator);
        self.authorized_topics.deinit(self.allocator);
        var tit = self.scoped_tokens.valueIterator();
        while (tit.next()) |tok| tok.zeroize();
        self.scoped_tokens.deinit(self.allocator);
        if (self.auth_secret != null) {
            crypto.zeroize(&self.auth_secret.?);
            self.auth_secret = null;
        }
        _ = linux.close(self.fd);
    }

    pub fn setPolicy(self: *SyncClientV3, policy: HydrationPolicy) void {
        self.policy = policy;
    }

    pub fn setCursorDir(self: *SyncClientV3, dir: Io.Dir) void {
        self.cursor_dir = dir;
    }

    pub fn setSharedGitRemoteVerified(self: *SyncClientV3, verified: bool) void {
        self.shared_git_remote_verified = verified;
    }

    pub fn addScopedToken(self: *SyncClientV3, token: CapabilityTokenV3) !void {
        if (self.scoped_tokens.getPtr(token.topic)) |prev| {
            prev.zeroize();
        }
        try self.scoped_tokens.put(self.allocator, token.topic, token);
    }

    pub fn popLeaseCancelEvent(self: *SyncClientV3) ?LeaseCancelEvent {
        if (self.pending_lease_cancels.items.len == 0) return null;
        return self.pending_lease_cancels.orderedRemove(0);
    }

    fn recordQuarantine(self: *SyncClientV3, topic_id: [32]u8, seq: u64, reason: QuarantineReason) void {
        self.quarantined_count += 1;
        if (self.quarantined.items.len < MAX_QUARANTINED_RECORDS) {
            self.quarantined.append(self.allocator, .{
                .topic_id = topic_id,
                .seq = seq,
                .reason = reason,
            }) catch {};
        }
    }

    fn mapRelayError(self: *SyncClientV3, payload: []const u8) anyerror {
        const ep = wire.decodeErrPayload(payload) catch return error.RelayError;
        if (ep.body.len == wire.LeaseResponse.ENCODED_LEN) {
            if (wire.LeaseResponse.decode(ep.body)) |lr| {
                self.last_lease_result = LeaseResult.fromWire(lr);
            } else |_| {}
        }
        return switch (ep.code) {
            .unauthorized => error.PermissionDenied,
            .bad_frame => error.BadRelayFrame,
            .not_found => error.NotFound,
            .internal => error.RelayError,
            .fenced => error.Fenced,
            .lease_held => error.LeaseHeld,
            .cancelled => error.LeaseCancelled,
        };
    }

    fn bufferAsyncEvent(self: *SyncClientV3, frame: *const wire.WireFrame) !void {
        if (frame.op == .frame_event) {
            if (frame.payload.len < 40) return;
            const tid: [32]u8 = frame.payload[0..32].*;
            const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
            const dec = openFramePayloadV3(self.allocator, self.keyring, tid, frame.payload[40..], &self.seen_seqs, self.allocator) catch |err| switch (err) {
                error.ReplayOrReorder => return,
                error.InvalidEnvelope => {
                    self.recordQuarantine(tid, seq, .invalid_envelope);
                    return;
                },
                error.AuthenticationFailed, error.TopicNotFound, error.EpochDowngrade => {
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
            return;
        }
        if (frame.op == wire.EVENT_LEASE_CANCEL) {
            if (frame.payload.len == 32 + wire.LeaseResponse.ENCODED_LEN) {
                const tid: [32]u8 = frame.payload[0..32].*;
                if (wire.LeaseResponse.decode(frame.payload[32..])) |lr| {
                    try self.pending_lease_cancels.append(self.allocator, .{
                        .topic_id = tid,
                        .lease = LeaseResult.fromWire(lr),
                    });
                } else |_| {}
            }
        }
    }

    fn readRpcResponse(self: *SyncClientV3) !wire.WireFrame {
        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            if (frame.op == .frame_event or frame.op == wire.EVENT_LEASE_CANCEL) {
                defer frame.deinit(self.allocator);
                try self.bufferAsyncEvent(&frame);
                continue;
            }
            return frame;
        }
    }

    fn drainUntilOp(self: *SyncClientV3, stop_op: wire.Op) void {
        while (true) {
            var frame = wire.readFrameBlocking(self.allocator, self.fd) catch return;
            const op = frame.op;
            if (op == .frame_event or op == wire.EVENT_LEASE_CANCEL) {
                self.bufferAsyncEvent(&frame) catch {};
                frame.deinit(self.allocator);
                continue;
            }
            frame.deinit(self.allocator);
            if (op == stop_op or op == .err) return;
        }
    }

    pub fn authV3(self: *SyncClientV3, topic_id: [32]u8, needed_perms: u32) !void {
        const now_ms = id.nowMs(self.io);
        if (self.authorized_topics.get(topic_id)) |cached| {
            const not_expired = cached.expires_ms == 0 or now_ms < cached.expires_ms;
            if (not_expired and (cached.perms & needed_perms) == needed_perms) {
                return;
            }
        }

        var auth_buf: [wire.AUTH_V3_LEN]u8 = undefined;
        defer crypto.zeroize(&auth_buf);
        var granted_perms: u32 = 0;
        var granted_expires: u64 = 0;

        if (self.scoped_tokens.get(topic_id)) |tok| {
            auth_buf = tok.encode();
            granted_perms = tok.perms;
            granted_expires = tok.expires_ms;
        } else if (self.keyring.getTopicGrant(topic_id)) |grant| {
            if (grant.token.len == wire.AUTH_V3_LEN) {
                try keyring_mod.validateAuthV3Token(grant.token, topic_id, grant.perms, grant.expires_ms);
                @memcpy(&auth_buf, grant.token[0..wire.AUTH_V3_LEN]);
                granted_perms = grant.perms;
                granted_expires = grant.expires_ms;
            } else if (grant.token.len == 32) {
                const mac: [32]u8 = grant.token[0..32].*;
                auth_buf = wire.encodeAuthV3(topic_id, grant.perms, grant.expires_ms, mac);
                granted_perms = grant.perms;
                granted_expires = grant.expires_ms;
            } else if (self.auth_secret) |secret| {
                granted_perms = grant.perms;
                granted_expires = grant.expires_ms;
                var mac = crypto.deriveCapabilityTokenV3(secret, topic_id, granted_perms, granted_expires);
                defer crypto.zeroize(&mac);
                auth_buf = wire.encodeAuthV3(topic_id, granted_perms, granted_expires, mac);
            } else {
                return error.PermissionDenied;
            }
        } else if (self.auth_secret) |secret| {
            granted_perms = wire.PERM_ALL_V3;
            granted_expires = 0;
            var mac = crypto.deriveCapabilityTokenV3(secret, topic_id, granted_perms, 0);
            defer crypto.zeroize(&mac);
            auth_buf = wire.encodeAuthV3(topic_id, granted_perms, 0, mac);
        } else {
            return error.PermissionDenied;
        }

        try wire.writeFrameBlocking(self.allocator, self.fd, .auth, 0, &auth_buf);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != .ack) return error.AuthFailed;

        const raw_prev = self.authorized_topics.get(topic_id) orelse AuthGrantCache{ .perms = 0, .expires_ms = 0 };
        const prev_valid = raw_prev.perms != 0 and (raw_prev.expires_ms == 0 or now_ms < raw_prev.expires_ms);
        const prev = if (prev_valid) raw_prev else AuthGrantCache{ .perms = 0, .expires_ms = 0 };
        const merged_exp: u64 = blk: {
            if (prev.perms == 0) break :blk granted_expires;
            if (prev.expires_ms == 0) break :blk granted_expires;
            if (granted_expires == 0) break :blk prev.expires_ms;
            break :blk @min(prev.expires_ms, granted_expires);
        };
        try self.authorized_topics.put(self.allocator, topic_id, .{
            .perms = prev.perms | granted_perms,
            .expires_ms = merged_exp,
        });
    }

    pub fn leaseAcquire(self: *SyncClientV3, topic_id: [32]u8, runner_id: u128, ttl_ms: u64) !LeaseResult {
        return self.leaseAcquireExpected(topic_id, runner_id, 0, ttl_ms);
    }

    pub fn leaseAcquireExpected(
        self: *SyncClientV3,
        topic_id: [32]u8,
        runner_id: u128,
        expected_epoch: u64,
        ttl_ms: u64,
    ) !LeaseResult {
        try self.authV3(topic_id, wire.PERM_LEASE);
        const req = wire.LeaseAcquireReq{
            .topic = topic_id,
            .runner_id = runner_id,
            .expected_epoch = expected_epoch,
            .ttl_ms = ttl_ms,
        };
        const enc = req.encode();
        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_LEASE_ACQUIRE, 0, &enc);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = LeaseResult.fromWire(try wire.LeaseResponse.decode(resp.payload));
        self.last_lease_result = lr;
        return lr;
    }

    pub fn leaseRenew(
        self: *SyncClientV3,
        topic_id: [32]u8,
        runner_id: u128,
        epoch: u64,
        ttl_ms: u64,
    ) !LeaseResult {
        try self.authV3(topic_id, wire.PERM_LEASE);
        const req = wire.LeaseRenewReq{
            .topic = topic_id,
            .runner_id = runner_id,
            .fencing_epoch = epoch,
            .ttl_ms = ttl_ms,
        };
        const enc = req.encode();
        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_LEASE_RENEW, 0, &enc);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = LeaseResult.fromWire(try wire.LeaseResponse.decode(resp.payload));
        self.last_lease_result = lr;
        return lr;
    }

    pub fn leasePrepareHandoff(
        self: *SyncClientV3,
        topic_id: [32]u8,
        from_runner: u128,
        to_runner: u128,
        expected_epoch: u64,
    ) !LeaseResult {
        try self.authV3(topic_id, wire.PERM_LEASE);
        const req = wire.LeaseHandoffReq{
            .topic = topic_id,
            .runner_id = from_runner,
            .fencing_epoch = expected_epoch,
            .target_runner_id = to_runner,
        };
        const enc = req.encode();
        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_LEASE_HANDOFF, 0, &enc);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = LeaseResult.fromWire(try wire.LeaseResponse.decode(resp.payload));
        self.last_lease_result = lr;
        return lr;
    }

    pub fn leaseHandoff(
        self: *SyncClientV3,
        topic_id: [32]u8,
        from_runner: u128,
        to_runner: u128,
        expected_epoch: u64,
        ttl_ms: u64,
    ) !LeaseResult {
        _ = try self.leasePrepareHandoff(topic_id, from_runner, to_runner, expected_epoch);
        return self.leaseAcquireExpected(topic_id, to_runner, expected_epoch, ttl_ms);
    }

    pub fn leaseRelease(
        self: *SyncClientV3,
        topic_id: [32]u8,
        runner_id: u128,
        epoch: u64,
    ) !LeaseResult {
        try self.authV3(topic_id, wire.PERM_LEASE);
        const req = wire.LeaseReleaseReq{
            .topic = topic_id,
            .runner_id = runner_id,
            .fencing_epoch = epoch,
        };
        const enc = req.encode();
        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_LEASE_RELEASE, 0, &enc);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = LeaseResult.fromWire(try wire.LeaseResponse.decode(resp.payload));
        self.last_lease_result = lr;
        return lr;
    }

    pub fn leaseCancel(self: *SyncClientV3, topic_id: [32]u8, epoch: u64) !LeaseResult {
        try self.authV3(topic_id, wire.PERM_LEASE);
        const req = wire.LeaseCancelReq{
            .topic = topic_id,
            .cancel_epoch = epoch,
        };
        const enc = req.encode();
        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_LEASE_CANCEL, 0, &enc);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = LeaseResult.fromWire(try wire.LeaseResponse.decode(resp.payload));
        self.last_lease_result = lr;
        return lr;
    }

    pub fn leaseStatus(self: *SyncClientV3, topic_id: [32]u8) !LeaseResult {
        try self.authV3(topic_id, @as(u32, wire.PERM_READ) | wire.PERM_LEASE);
        const req = wire.LeaseStatusReq{ .topic = topic_id };
        const enc = req.encode();
        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_LEASE_STATUS, 0, &enc);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = LeaseResult.fromWire(try wire.LeaseResponse.decode(resp.payload));
        self.last_lease_result = lr;
        return lr;
    }

    pub fn putFrameFenced(
        self: *SyncClientV3,
        topic_id: [32]u8,
        epoch: u64,
        seq: u64,
        ciphertext: []const u8,
    ) !u64 {
        try self.authV3(topic_id, @as(u32, wire.PERM_WRITE) | wire.PERM_LEASE);
        const req = wire.PutFrameFencedReq{
            .topic = topic_id,
            .required_epoch = epoch,
            .frame = ciphertext,
        };
        const payload = try req.encode(self.allocator);
        defer self.allocator.free(payload);

        try wire.writeFrameBlocking(self.allocator, self.fd, wire.REQ_PUT_FRAME_FENCED, 0, payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != .ack or resp.payload.len < 8) return error.PutFrameFailed;
        if (seq > 0) {
            const cur = self.out_seqs.get(topic_id) orelse 0;
            if (seq > cur) try self.out_seqs.put(self.allocator, topic_id, seq);
        }
        return std.mem.readInt(u64, resp.payload[0..8], .little);
    }

    fn nextSenderSeq(self: *SyncClientV3, topic_id: [32]u8) !u64 {
        const gop = try self.out_seqs.getOrPut(self.allocator, topic_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        return gop.value_ptr.*;
    }

    fn putEncryptedFrameInternal(
        self: *SyncClientV3,
        topic_id: [32]u8,
        plaintext: []const u8,
        lease_epoch: ?u64,
        required_perm: u32,
    ) !FramePutResult {
        try self.authV3(topic_id, required_perm);
        const ek = self.keyring.getEntityKey(topic_id) orelse return error.PermissionDenied;
        const sender_seq = try self.nextSenderSeq(topic_id);
        const framed = try sealFramePayloadV3(
            self.allocator,
            self.io,
            &ek,
            topic_id,
            self.sender_id,
            sender_seq,
            plaintext,
        );
        defer self.allocator.free(framed);

        if (lease_epoch) |epoch| {
            const relay_seq = try self.putFrameFenced(topic_id, epoch, sender_seq, framed);
            return .{ .seq = relay_seq, .wire_bytes = wire.PutFrameFencedReq.HEADER_LEN + framed.len };
        }

        const payload = try self.allocator.alloc(u8, 32 + framed.len);
        defer self.allocator.free(payload);
        @memcpy(payload[0..32], &topic_id);
        @memcpy(payload[32..], framed);

        try wire.writeFrameBlocking(self.allocator, self.fd, .put_frame, 0, payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != .ack or resp.payload.len < 8) return error.PutFrameFailed;
        return .{
            .seq = std.mem.readInt(u64, resp.payload[0..8], .little),
            .wire_bytes = payload.len,
        };
    }

    pub fn putEncryptedFrameV3(
        self: *SyncClientV3,
        topic_id: [32]u8,
        plaintext: []const u8,
        lease_epoch: ?u64,
    ) !FramePutResult {
        const perm: u32 = if (lease_epoch != null)
            (@as(u32, wire.PERM_WRITE) | wire.PERM_LEASE)
        else
            wire.PERM_WRITE;
        return self.putEncryptedFrameInternal(topic_id, plaintext, lease_epoch, perm);
    }

    pub fn getEncryptedRangePageV3(
        self: *SyncClientV3,
        allocator: Allocator,
        topic_id: [32]u8,
        after_seq: u64,
        limit: u32,
    ) !RangePageV3 {
        try self.authV3(topic_id, wire.PERM_READ);
        var req: [32 + 8 + 4]u8 = undefined;
        @memcpy(req[0..32], &topic_id);
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
        var wire_bytes: usize = 0;

        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            defer frame.deinit(self.allocator);
            if (frame.op == .range_end) {
                has_more = (frame.flags & wire.RANGE_FLAG_HAS_MORE) != 0;
                break;
            }
            if (frame.op == .err) return self.mapRelayError(frame.payload);
            if (frame.op == .frame_event or frame.op == wire.EVENT_LEASE_CANCEL) {
                try self.bufferAsyncEvent(&frame);
                continue;
            }
            if (frame.op != .range_item or frame.payload.len < 40) {
                self.drainUntilOp(.range_end);
                return error.BadRelayFrame;
            }

            const tid: [32]u8 = frame.payload[0..32].*;
            if (!std.mem.eql(u8, &tid, &topic_id)) {
                self.drainUntilOp(.range_end);
                return error.BadRelayFrame;
            }
            const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
            if (seq > last_seq) last_seq = seq;
            item_count += 1;
            wire_bytes += frame.payload.len;

            const env = frame.payload[40..];
            const dec = openFramePayloadV3(allocator, self.keyring, topic_id, env, &self.seen_seqs, self.allocator) catch |err| switch (err) {
                error.ReplayOrReorder => continue,
                error.InvalidEnvelope => {
                    self.recordQuarantine(tid, seq, .invalid_envelope);
                    continue;
                },
                error.AuthenticationFailed, error.TopicNotFound, error.EpochDowngrade => {
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
            .wire_bytes = wire_bytes,
        };
    }

    pub fn subscribeV3(self: *SyncClientV3, topic_id: [32]u8, after_seq: u64) ![]DecryptedFrame {
        const req_perm: u32 = if (after_seq == std.math.maxInt(u64))
            wire.PERM_SUB
        else
            (@as(u32, wire.PERM_SUB) | wire.PERM_READ);
        try self.authV3(topic_id, req_perm);
        var req: [32 + 8]u8 = undefined;
        @memcpy(req[0..32], &topic_id);
        std.mem.writeInt(u64, req[32..40], after_seq, .little);
        try wire.writeFrameBlocking(self.allocator, self.fd, .subscribe, 0, &req);

        var backlog: std.ArrayList(DecryptedFrame) = .empty;
        errdefer {
            for (backlog.items) |*f| f.deinit(self.allocator);
            backlog.deinit(self.allocator);
        }

        var last_seq = after_seq;
        var has_more = false;
        var item_count: usize = 0;

        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            defer frame.deinit(self.allocator);
            if (frame.op == .ack) {
                has_more = (frame.flags & wire.RANGE_FLAG_HAS_MORE) != 0;
                break;
            }
            if (frame.op == .err) return self.mapRelayError(frame.payload);
            if (frame.op == .frame_event or frame.op == wire.EVENT_LEASE_CANCEL) {
                try self.bufferAsyncEvent(&frame);
                continue;
            }
            if (frame.op == .range_item and frame.payload.len >= 40) {
                const tid: [32]u8 = frame.payload[0..32].*;
                if (!std.mem.eql(u8, &tid, &topic_id)) {
                    self.drainUntilOp(.ack);
                    return error.BadRelayFrame;
                }
                const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
                if (seq > last_seq) last_seq = seq;
                item_count += 1;
                const dec = openFramePayloadV3(self.allocator, self.keyring, topic_id, frame.payload[40..], &self.seen_seqs, self.allocator) catch |err| switch (err) {
                    error.ReplayOrReorder => continue,
                    error.InvalidEnvelope => {
                        self.recordQuarantine(tid, seq, .invalid_envelope);
                        continue;
                    },
                    error.AuthenticationFailed, error.TopicNotFound, error.EpochDowngrade => {
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

        if (has_more and item_count > 0) {
            var cursor = last_seq;
            while (true) {
                var page = try self.getEncryptedRangePageV3(self.allocator, topic_id, cursor, PULL_PAGE_LIMIT);
                errdefer page.deinit(self.allocator);
                try backlog.ensureUnusedCapacity(self.allocator, page.frames.len);
                for (page.frames) |f| {
                    backlog.appendAssumeCapacity(f);
                }
                self.allocator.free(page.frames);
                page.frames = &.{};
                if (!page.has_more or page.item_count == 0 or page.last_seq <= cursor) break;
                cursor = page.last_seq;
            }
        }

        return try backlog.toOwnedSlice(self.allocator);
    }

    pub fn putEncryptedBlobV3(self: *SyncClientV3, topic_id: [32]u8, oid: [32]u8, plaintext: []const u8) !usize {
        try self.authV3(topic_id, wire.PERM_WRITE);
        const ek = self.keyring.getEntityKey(topic_id) orelse return error.PermissionDenied;
        var key = crypto.deriveStreamKeyV3(&ek, topic_id);
        defer crypto.zeroize(&key);
        const lookup_id = crypto.deriveBlobLookupIdV3(&ek, topic_id, oid);
        const aad = buildBlobAadV3(topic_id, ek.epoch, oid);
        const sealed = try crypto.sealRandom(self.allocator, self.io, key, &aad, plaintext);
        defer self.allocator.free(sealed);

        const payload = try self.allocator.alloc(u8, 64 + sealed.len);
        defer self.allocator.free(payload);
        @memcpy(payload[0..32], &topic_id);
        @memcpy(payload[32..64], &lookup_id);
        @memcpy(payload[64..], sealed);

        try wire.writeFrameBlocking(self.allocator, self.fd, .put_blob, 0, payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != .ack) return error.PutBlobFailed;
        return payload.len;
    }

    fn fetchEncryptedBlobWithKey(
        self: *SyncClientV3,
        allocator: Allocator,
        topic_id: [32]u8,
        ek: *const crypto.EntityKey,
        oid: [32]u8,
    ) !?[]u8 {
        const lookup_id = crypto.deriveBlobLookupIdV3(ek, topic_id, oid);
        var req: [64]u8 = undefined;
        @memcpy(req[0..32], &topic_id);
        @memcpy(req[32..64], &lookup_id);
        try wire.writeFrameBlocking(self.allocator, self.fd, .get_blob, 0, &req);

        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != .blob_data or resp.payload.len < 33) return error.GetBlobFailed;
        if (!std.mem.eql(u8, resp.payload[0..32], &lookup_id)) return error.GetBlobFailed;
        if (resp.payload[32] == 0) return null;

        var key = crypto.deriveStreamKeyV3(ek, topic_id);
        defer crypto.zeroize(&key);
        const aad = buildBlobAadV3(topic_id, ek.epoch, oid);
        const plain = try crypto.open(allocator, key, &aad, resp.payload[33..]);
        errdefer allocator.free(plain);
        const actual = crypto.hashBytes(plain);
        if (!std.mem.eql(u8, &actual, &oid)) return error.HashMismatch;
        return plain;
    }

    pub fn getEncryptedBlobV3(
        self: *SyncClientV3,
        allocator: Allocator,
        topic_id: [32]u8,
        oid: [32]u8,
    ) !?[]u8 {
        try self.authV3(topic_id, wire.PERM_READ);
        const ek = self.keyring.getEntityKey(topic_id) orelse return error.PermissionDenied;
        if (try self.fetchEncryptedBlobWithKey(allocator, topic_id, &ek, oid)) |plain| {
            return plain;
        }
        const priors = self.keyring.getPriorEntityKeys(topic_id);
        var idx = priors.len;
        while (idx > 0) {
            idx -= 1;
            if (try self.fetchEncryptedBlobWithKey(allocator, topic_id, &priors[idx], oid)) |plain| {
                return plain;
            }
        }
        return null;
    }

    pub fn putEncryptedGitBlobV3(
        self: *SyncClientV3,
        topic_id: [32]u8,
        git_oid: git_dirs_mod.GitOid,
        plaintext: []const u8,
    ) !usize {
        const key_oid = gitBlobLookupOid(git_oid);
        return self.putEncryptedBlobV3(topic_id, key_oid, plaintext);
    }

    fn fetchEncryptedGitBlobWithKey(
        self: *SyncClientV3,
        allocator: Allocator,
        topic_id: [32]u8,
        ek: *const crypto.EntityKey,
        git_oid: git_dirs_mod.GitOid,
        key_oid: [32]u8,
    ) !?[]u8 {
        const lookup_id = crypto.deriveBlobLookupIdV3(ek, topic_id, key_oid);
        var req: [64]u8 = undefined;
        @memcpy(req[0..32], &topic_id);
        @memcpy(req[32..64], &lookup_id);
        try wire.writeFrameBlocking(self.allocator, self.fd, .get_blob, 0, &req);

        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayError(resp.payload);
        if (resp.op != .blob_data or resp.payload.len < 33) return error.GetBlobFailed;
        if (!std.mem.eql(u8, resp.payload[0..32], &lookup_id)) return error.GetBlobFailed;
        if (resp.payload[32] == 0) return null;

        var key = crypto.deriveStreamKeyV3(ek, topic_id);
        defer crypto.zeroize(&key);
        const aad = buildBlobAadV3(topic_id, ek.epoch, key_oid);
        const plain = try crypto.open(allocator, key, &aad, resp.payload[33..]);
        errdefer allocator.free(plain);
        const fmt: git_dirs_mod.ObjectFormat = if (git_oid.len == 32) .sha256 else .sha1;
        const actual = git_dirs_mod.GitOid.ofBlob(fmt, plain);
        if (!actual.eql(git_oid)) return error.HashMismatch;
        return plain;
    }

    pub fn getEncryptedGitBlobV3(
        self: *SyncClientV3,
        allocator: Allocator,
        topic_id: [32]u8,
        git_oid: git_dirs_mod.GitOid,
    ) !?[]u8 {
        try self.authV3(topic_id, wire.PERM_READ);
        const ek = self.keyring.getEntityKey(topic_id) orelse return error.PermissionDenied;
        const key_oid = gitBlobLookupOid(git_oid);
        if (try self.fetchEncryptedGitBlobWithKey(allocator, topic_id, &ek, git_oid, key_oid)) |plain| {
            return plain;
        }
        const priors = self.keyring.getPriorEntityKeys(topic_id);
        var idx = priors.len;
        while (idx > 0) {
            idx -= 1;
            if (try self.fetchEncryptedGitBlobWithKey(allocator, topic_id, &priors[idx], git_oid, key_oid)) |plain| {
                return plain;
            }
        }
        return null;
    }

    fn loadSpaceCursor(self: *SyncClientV3, state_dir: Io.Dir, topic_id: [32]u8) !SpaceCursorState {
        var st = SpaceCursorState{};
        errdefer st.deinit(self.allocator);

        var cursors_dir = state_dir.openDir(self.io, "sync_cursors", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return st,
            else => return err,
        };
        defer cursors_dir.close(self.io);

        var name_buf: [80]u8 = undefined;
        const fname = cursorFileName(self.remote_tag, topic_id, &name_buf);
        const f = cursors_dir.openFile(self.io, fname, .{}) catch |err| switch (err) {
            error.FileNotFound => return st,
            else => return err,
        };
        defer f.close(self.io);

        const fstat = try f.stat(self.io);
        if (fstat.size == 0 or fstat.size > 32 * 1024 * 1024) return st;
        const raw = try self.allocator.alloc(u8, @intCast(fstat.size));
        defer self.allocator.free(raw);
        const n = try f.readPositionalAll(self.io, raw, 0);
        if (n < 8) return st;

        var r = codec.Reader.init(raw[0..n]);
        const magic = r.readU32() catch return st;
        const ver = r.readU16() catch return st;
        if (magic != SPACE_CURSOR_V3_MAGIC or ver != SPACE_CURSOR_V3_VERSION) return st;

        st.has_pushed_once = (r.readByte() catch return st) != 0;
        st.last_pushed_wal_seq = r.readU64() catch return st;
        const heads = version_mod.Version.decode(self.allocator, &r) catch return st;
        st.last_pushed_heads.deinit(self.allocator);
        st.last_pushed_heads = heads;
        st.last_pulled_seq = r.readU64() catch return st;
        st.out_seq = r.readU64() catch return st;

        const cur_out = self.out_seqs.get(topic_id) orelse 0;
        if (st.out_seq > cur_out) {
            try self.out_seqs.put(self.allocator, topic_id, st.out_seq);
        }
        const cur_persisted = self.persisted_out_seqs.get(topic_id) orelse 0;
        if (st.out_seq > cur_persisted) {
            try self.persisted_out_seqs.put(self.allocator, topic_id, st.out_seq);
        }

        const pushed_n = r.readVarint() catch return st;
        if (pushed_n > 2_000_000) return st;
        for (0..@intCast(pushed_n)) |_| {
            const actor = r.readU128() catch return st;
            const ts = r.readU64() catch return st;
            try st.pushed_batches.put(self.allocator, .{ .actor = actor, .ts = ts }, {});
        }

        const blobs_n = r.readVarint() catch return st;
        if (blobs_n > 2_000_000) return st;
        for (0..@intCast(blobs_n)) |_| {
            const oid: [32]u8 = (r.readFixed(32) catch return st).*;
            try st.uploaded_blobs.put(self.allocator, oid, {});
        }

        const seen_n = r.readVarint() catch return st;
        if (seen_n > 2_000_000) return st;
        for (0..@intCast(seen_n)) |_| {
            const sid = r.readU128() catch return st;
            const sseq = r.readU64() catch return st;
            const sk = SenderKey{ .topic = topic_id, .sender_id = sid };
            const prev = self.seen_seqs.get(sk) orelse 0;
            if (sseq > prev) try self.seen_seqs.put(self.allocator, sk, sseq);
        }

        const wait_n = r.readVarint() catch return st;
        if (wait_n > MAX_WAITING_BATCHES) return st;
        for (0..@intCast(wait_n)) |_| {
            const actor = r.readU128() catch return st;
            const ts = r.readU64() catch return st;
            const raw_b = r.readBytesAlloc(self.allocator) catch return st;
            errdefer self.allocator.free(raw_b);
            try st.waiting.append(self.allocator, .{
                .batch_id = .{ .actor = actor, .ts = ts },
                .raw_batch = raw_b,
            });
        }

        return st;
    }

    fn saveSpaceCursor(self: *SyncClientV3, state_dir: Io.Dir, topic_id: [32]u8, st: *const SpaceCursorState) !void {
        try state_dir.createDirPath(self.io, "sync_cursors");
        var cursors_dir = try state_dir.openDir(self.io, "sync_cursors", .{ .iterate = true });
        defer cursors_dir.close(self.io);

        const out_seq = @max(
            st.out_seq,
            @max(self.out_seqs.get(topic_id) orelse 0, self.persisted_out_seqs.get(topic_id) orelse 0),
        );

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, SPACE_CURSOR_V3_MAGIC);
        try w.writeU16(self.allocator, SPACE_CURSOR_V3_VERSION);
        try w.writeByte(self.allocator, if (st.has_pushed_once) 1 else 0);
        try w.writeU64(self.allocator, st.last_pushed_wal_seq);
        try st.last_pushed_heads.encode(self.allocator, &w);
        try w.writeU64(self.allocator, st.last_pulled_seq);
        try w.writeU64(self.allocator, out_seq);

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

        var seen_count: usize = 0;
        {
            var sit = self.seen_seqs.iterator();
            while (sit.next()) |e| {
                if (std.mem.eql(u8, &e.key_ptr.topic, &topic_id)) seen_count += 1;
            }
        }
        try w.writeVarint(self.allocator, seen_count);
        {
            var sit = self.seen_seqs.iterator();
            while (sit.next()) |e| {
                if (std.mem.eql(u8, &e.key_ptr.topic, &topic_id)) {
                    try w.writeU128(self.allocator, e.key_ptr.sender_id);
                    try w.writeU64(self.allocator, e.value_ptr.*);
                }
            }
        }

        try w.writeVarint(self.allocator, st.waiting.items.len);
        for (st.waiting.items) |wb| {
            try w.writeU128(self.allocator, wb.batch_id.actor);
            try w.writeU64(self.allocator, wb.batch_id.ts);
            try w.writeBytes(self.allocator, wb.raw_batch);
        }

        var name_buf: [80]u8 = undefined;
        const fname = cursorFileName(self.remote_tag, topic_id, &name_buf);
        try mmap.atomicWriteFile(self.io, cursors_dir, fname, w.items());
        const cur_persisted = self.persisted_out_seqs.get(topic_id) orelse 0;
        if (out_seq > cur_persisted) {
            self.persisted_out_seqs.put(self.allocator, topic_id, out_seq) catch {};
        }
    }

    fn reserveSpaceOutSeq(
        self: *SyncClientV3,
        state_dir: Io.Dir,
        topic_id: [32]u8,
        st: *const SpaceCursorState,
    ) !void {
        const used = self.out_seqs.get(topic_id) orelse 0;
        const reserved = self.persisted_out_seqs.get(topic_id) orelse 0;
        if (used + 1 <= reserved) return;
        const new_reserved = used + SEQ_RESERVE_STRIDE;
        const prev_opt = self.persisted_out_seqs.get(topic_id);
        try self.persisted_out_seqs.put(self.allocator, topic_id, new_reserved);
        errdefer {
            if (prev_opt) |prev| {
                self.persisted_out_seqs.put(self.allocator, topic_id, prev) catch {};
            } else {
                _ = self.persisted_out_seqs.remove(topic_id);
            }
        }
        try self.saveSpaceCursor(state_dir, topic_id, st);
    }

    fn loadLogCursor(self: *SyncClientV3, base_dir: Io.Dir, topic_id: [32]u8) !LogCursorState {
        var st = LogCursorState{};
        errdefer st.deinit(self.allocator);

        var cursors_dir = base_dir.openDir(self.io, "sync_cursors", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return st,
            else => return err,
        };
        defer cursors_dir.close(self.io);

        var name_buf: [80]u8 = undefined;
        const fname = cursorFileName(self.remote_tag, topic_id, &name_buf);
        const f = cursors_dir.openFile(self.io, fname, .{}) catch |err| switch (err) {
            error.FileNotFound => return st,
            else => return err,
        };
        defer f.close(self.io);

        const fstat = try f.stat(self.io);
        if (fstat.size == 0 or fstat.size > 32 * 1024 * 1024) return st;
        const raw = try self.allocator.alloc(u8, @intCast(fstat.size));
        defer self.allocator.free(raw);
        const n = try f.readPositionalAll(self.io, raw, 0);
        if (n < 8) return st;

        var r = codec.Reader.init(raw[0..n]);
        const magic = r.readU32() catch return st;
        const ver = r.readU16() catch return st;
        if (magic != LOG_CURSOR_V3_MAGIC or ver != LOG_CURSOR_V3_VERSION) return st;

        st.last_pushed_local_seq = r.readU64() catch return st;
        st.last_pulled_relay_seq = r.readU64() catch return st;
        st.out_seq = r.readU64() catch return st;

        const cur_out = self.out_seqs.get(topic_id) orelse 0;
        if (st.out_seq > cur_out) {
            try self.out_seqs.put(self.allocator, topic_id, st.out_seq);
        }
        const cur_persisted = self.persisted_out_seqs.get(topic_id) orelse 0;
        if (st.out_seq > cur_persisted) {
            try self.persisted_out_seqs.put(self.allocator, topic_id, st.out_seq);
        }

        const ids_n = r.readVarint() catch return st;
        if (ids_n > 2_000_000) return st;
        for (0..@intCast(ids_n)) |_| {
            const eid = r.readU128() catch return st;
            try st.pushed_ids.put(self.allocator, eid, {});
        }

        const seen_n = r.readVarint() catch return st;
        if (seen_n > 2_000_000) return st;
        for (0..@intCast(seen_n)) |_| {
            const sid = r.readU128() catch return st;
            const sseq = r.readU64() catch return st;
            const sk = SenderKey{ .topic = topic_id, .sender_id = sid };
            const prev = self.seen_seqs.get(sk) orelse 0;
            if (sseq > prev) try self.seen_seqs.put(self.allocator, sk, sseq);
        }

        return st;
    }

    fn saveLogCursor(self: *SyncClientV3, base_dir: Io.Dir, topic_id: [32]u8, st: *const LogCursorState) !void {
        try base_dir.createDirPath(self.io, "sync_cursors");
        var cursors_dir = try base_dir.openDir(self.io, "sync_cursors", .{ .iterate = true });
        defer cursors_dir.close(self.io);

        const out_seq = @max(
            st.out_seq,
            @max(self.out_seqs.get(topic_id) orelse 0, self.persisted_out_seqs.get(topic_id) orelse 0),
        );

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, LOG_CURSOR_V3_MAGIC);
        try w.writeU16(self.allocator, LOG_CURSOR_V3_VERSION);
        try w.writeU64(self.allocator, st.last_pushed_local_seq);
        try w.writeU64(self.allocator, st.last_pulled_relay_seq);
        try w.writeU64(self.allocator, out_seq);

        try w.writeVarint(self.allocator, st.pushed_ids.count());
        var iit = st.pushed_ids.keyIterator();
        while (iit.next()) |eid| {
            try w.writeU128(self.allocator, eid.*);
        }

        var seen_count: usize = 0;
        {
            var sit = self.seen_seqs.iterator();
            while (sit.next()) |e| {
                if (std.mem.eql(u8, &e.key_ptr.topic, &topic_id)) seen_count += 1;
            }
        }
        try w.writeVarint(self.allocator, seen_count);
        {
            var sit = self.seen_seqs.iterator();
            while (sit.next()) |e| {
                if (std.mem.eql(u8, &e.key_ptr.topic, &topic_id)) {
                    try w.writeU128(self.allocator, e.key_ptr.sender_id);
                    try w.writeU64(self.allocator, e.value_ptr.*);
                }
            }
        }

        var name_buf: [80]u8 = undefined;
        const fname = cursorFileName(self.remote_tag, topic_id, &name_buf);
        try mmap.atomicWriteFile(self.io, cursors_dir, fname, w.items());
        const cur_persisted = self.persisted_out_seqs.get(topic_id) orelse 0;
        if (out_seq > cur_persisted) {
            self.persisted_out_seqs.put(self.allocator, topic_id, out_seq) catch {};
        }
    }

    fn reserveLogOutSeq(
        self: *SyncClientV3,
        base_dir: Io.Dir,
        topic_id: [32]u8,
        st: *const LogCursorState,
    ) !void {
        const used = self.out_seqs.get(topic_id) orelse 0;
        const reserved = self.persisted_out_seqs.get(topic_id) orelse 0;
        if (used + 1 <= reserved) return;
        const new_reserved = used + SEQ_RESERVE_STRIDE;
        const prev_opt = self.persisted_out_seqs.get(topic_id);
        try self.persisted_out_seqs.put(self.allocator, topic_id, new_reserved);
        errdefer {
            if (prev_opt) |prev| {
                self.persisted_out_seqs.put(self.allocator, topic_id, prev) catch {};
            } else {
                _ = self.persisted_out_seqs.remove(topic_id);
            }
        }
        try self.saveLogCursor(base_dir, topic_id, st);
    }

    fn isGitBlobReachableForPull(space: *const space_mod.Space, git_oid: git_dirs_mod.GitOid) bool {
        if (space.external_git_reader) |gr| {
            return gr.contains(git_oid);
        }
        return false;
    }

    fn isGitBlobReachableForPush(self: *const SyncClientV3, space: *const space_mod.Space, git_oid: git_dirs_mod.GitOid) bool {
        if (!self.shared_git_remote_verified) return false;
        const orig = space.origin orelse return false;
        if (orig.git_remote_url == null or orig.git_base_rev == null) return false;
        if (space.external_git_reader) |gr| {
            return gr.contains(git_oid);
        }
        return false;
    }

    fn pushSingleSpaceBatch(
        self: *SyncClientV3,
        space: *space_mod.Space,
        cursor: *SpaceCursorState,
        topic_id: [32]u8,
        lease_epoch: ?u64,
        raw_payload: []const u8,
        batch: *const op_mod.Batch,
        stats: *SyncStats,
    ) !void {
        const bid = batch.header.batchId();
        if (cursor.pushed_batches.contains(bid)) return;

        for (batch.blobs) |b| {
            if (!cursor.uploaded_blobs.contains(b.oid)) {
                const wb = try self.putEncryptedBlobV3(topic_id, b.oid, b.data);
                try cursor.uploaded_blobs.put(self.allocator, b.oid, {});
                stats.blobs_pushed += 1;
                stats.bytes_transferred += wb;
            }
        }

        for (batch.ops) |op| {
            if (opReferencedBlob(op)) |ref| {
                switch (ref) {
                    .blake3 => |br| {
                        if (!cursor.uploaded_blobs.contains(br.oid)) {
                            if (try space.blob_store.get(self.allocator, br.oid)) |raw| {
                                defer self.allocator.free(raw);
                                const wb = try self.putEncryptedBlobV3(topic_id, br.oid, raw);
                                try cursor.uploaded_blobs.put(self.allocator, br.oid, {});
                                stats.blobs_pushed += 1;
                                stats.bytes_transferred += wb;
                            } else if (space.history.resolveBlob(br.oid)) |raw| {
                                const wb = try self.putEncryptedBlobV3(topic_id, br.oid, raw);
                                try cursor.uploaded_blobs.put(self.allocator, br.oid, {});
                                stats.blobs_pushed += 1;
                                stats.bytes_transferred += wb;
                            }
                        }
                    },
                    .git => |git_oid| {
                        if (self.isGitBlobReachableForPush(space, git_oid)) {
                            stats.git_blobs_skipped += 1;
                        } else {
                            const key_oid = gitBlobLookupOid(git_oid);
                            if (!cursor.uploaded_blobs.contains(key_oid)) {
                                if (try space.history.readGitBlobAlloc(self.allocator, git_oid)) |raw| {
                                    defer self.allocator.free(raw);
                                    const wb = try self.putEncryptedGitBlobV3(topic_id, git_oid, raw);
                                    try cursor.uploaded_blobs.put(self.allocator, key_oid, {});
                                    stats.blobs_pushed += 1;
                                    stats.bytes_transferred += wb;
                                }
                            }
                        }
                    },
                }
            }
        }

        try self.reserveSpaceOutSeq(space.state_dir, topic_id, cursor);

        const res = if (batch.blobs.len > 0) blk: {
            var stripped = batch.*;
            stripped.blobs = &.{};
            var w = codec.Writer{};
            defer w.deinit(self.allocator);
            try stripped.encode(self.allocator, &w);
            break :blk try self.putEncryptedFrameV3(topic_id, w.items(), lease_epoch);
        } else try self.putEncryptedFrameV3(topic_id, raw_payload, lease_epoch);

        try cursor.pushed_batches.put(self.allocator, bid, {});
        stats.frames_pushed += 1;
        stats.bytes_transferred += res.wire_bytes;
        if (res.seq > stats.last_seq) stats.last_seq = res.seq;
    }

    pub fn pushSpace(
        self: *SyncClientV3,
        space: *space_mod.Space,
        topic_id: [32]u8,
        lease_epoch: ?u64,
    ) !SyncStats {
        const perm: u32 = if (lease_epoch != null)
            (@as(u32, wire.PERM_WRITE) | wire.PERM_LEASE)
        else
            wire.PERM_WRITE;
        try self.authV3(topic_id, perm);

        var cursor = try self.loadSpaceCursor(space.state_dir, topic_id);
        defer cursor.deinit(self.allocator);

        var stats = SyncStats{ .last_seq = cursor.last_pulled_seq };

        if (cursor.has_pushed_once and space.history.dag.heads.eql(&cursor.last_pushed_heads)) {
            return stats;
        }

        errdefer {
            if (stats.frames_pushed > 0 or stats.blobs_pushed > 0) {
                cursor.out_seq = @max(cursor.out_seq, self.out_seqs.get(topic_id) orelse 0);
                self.saveSpaceCursor(space.state_dir, topic_id, &cursor) catch {};
            }
        }

        const wal_base = space.manifest.wal_base_seq;
        const can_scan_wal_tail = cursor.last_pushed_wal_seq >= wal_base and (cursor.has_pushed_once or wal_base == 0);

        if (can_scan_wal_tail) {
            const start_idx = space.batch_log.findIndexBySeq(cursor.last_pushed_wal_seq + 1);
            const total = space.batch_log.count();
            var new_wal_seq = cursor.last_pushed_wal_seq;
            for (start_idx..total) |i| {
                const view = try space.batch_log.readAt(i);
                if (view.header.seq > new_wal_seq) new_wal_seq = view.header.seq;
                if (view.header.kind != space_mod.FRAME_BATCH) continue;
                var r = codec.Reader.init(view.payload);
                var batch = try op_mod.Batch.decode(self.allocator, &r);
                defer batch.deinit(self.allocator);
                try self.pushSingleSpaceBatch(space, &cursor, topic_id, lease_epoch, view.payload, &batch, &stats);
            }
            cursor.last_pushed_wal_seq = new_wal_seq;
        } else {
            var bids = if (cursor.has_pushed_once and !cursor.last_pushed_heads.isEmpty())
                try space.history.dag.difference(self.allocator, &space.history.dag.heads, &cursor.last_pushed_heads)
            else
                try space.history.dag.collectAllBatchIds(self.allocator);
            defer bids.deinit(self.allocator);
            space.history.dag.topoSortSlice(bids.items);

            for (bids.items) |bid| {
                if (cursor.pushed_batches.contains(bid)) continue;
                const raw_payload = (try space.readBatchPayloadAlloc(self.allocator, bid)) orelse continue;
                defer self.allocator.free(raw_payload);
                var r = codec.Reader.init(raw_payload);
                var batch = try op_mod.Batch.decode(self.allocator, &r);
                defer batch.deinit(self.allocator);
                try self.pushSingleSpaceBatch(space, &cursor, topic_id, lease_epoch, raw_payload, &batch, &stats);
            }
            cursor.last_pushed_wal_seq = @max(space.batch_log.lastSeq(), wal_base);
        }

        const new_heads = try space.history.dag.heads.clone(self.allocator);
        cursor.last_pushed_heads.deinit(self.allocator);
        cursor.last_pushed_heads = new_heads;
        cursor.has_pushed_once = true;
        cursor.out_seq = self.out_seqs.get(topic_id) orelse cursor.out_seq;

        try self.saveSpaceCursor(space.state_dir, topic_id, &cursor);
        return stats;
    }

    fn hydrateBatchBlobsIfNeeded(
        self: *SyncClientV3,
        space: *space_mod.Space,
        topic_id: [32]u8,
        batch: *const op_mod.Batch,
        has_projection: bool,
        stats: *SyncStats,
    ) !bool {
        if (self.policy == .thin_client) {
            return true;
        }

        for (batch.blobs) |b| {
            if (!space.blob_store.exists(b.oid)) {
                try space.blob_store.putVerified(b.oid, b.data);
            }
        }

        for (batch.ops) |op| {
            if (opReferencedBlob(op)) |ref| {
                switch (ref) {
                    .blake3 => |br| {
                        const need_now = has_projection or (br.is_text_blob and op == .set_content);
                        if (!need_now) continue;
                        if (!space.blob_store.exists(br.oid)) {
                            const raw_opt = self.getEncryptedBlobV3(self.allocator, topic_id, br.oid) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => return false,
                            };
                            const raw = raw_opt orelse return false;
                            defer self.allocator.free(raw);
                            try space.blob_store.putVerified(br.oid, raw);
                            stats.blobs_pulled += 1;
                            stats.bytes_transferred += raw.len;
                        }
                    },
                    .git => |git_oid| {
                        if (isGitBlobReachableForPull(space, git_oid)) {
                            stats.git_blobs_skipped += 1;
                            continue;
                        }
                        if (!has_projection) continue;
                        const local = space.history.readGitBlobAlloc(self.allocator, git_oid) catch null;
                        if (local) |buf| {
                            self.allocator.free(buf);
                        } else {
                            const raw_opt = self.getEncryptedGitBlobV3(self.allocator, topic_id, git_oid) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => return false,
                            };
                            const raw = raw_opt orelse return false;
                            defer self.allocator.free(raw);
                            try space.blob_store.putGitFallback(git_oid.slice(), raw);
                            stats.blobs_pulled += 1;
                            stats.bytes_transferred += raw.len;
                        }
                    },
                }
            }
        }
        return true;
    }

    fn tryIntegrateSpaceBatch(
        self: *SyncClientV3,
        space: *space_mod.Space,
        cursor: *SpaceCursorState,
        topic_id: [32]u8,
        batch: *const op_mod.Batch,
        has_projection: bool,
        stats: *SyncStats,
    ) !IntegrateOutcome {
        const bid = batch.header.batchId();
        if (space.history.dag.containsBatch(bid)) {
            if (!cursor.pushed_batches.contains(bid)) {
                try cursor.pushed_batches.put(self.allocator, bid, {});
            }
            return .already_present;
        }

        const blobs_ready = try self.hydrateBatchBlobsIfNeeded(space, topic_id, batch, has_projection, stats);
        if (!blobs_ready) return .waiting_blob;

        const committed = space.commitBatch(batch) catch |err| switch (err) {
            error.MissingParents => return .waiting_parents,
            error.MissingBlob => return .waiting_blob,
            else => return err,
        };
        if (!cursor.pushed_batches.contains(bid)) {
            try cursor.pushed_batches.put(self.allocator, bid, {});
        }
        return if (committed) .applied else .already_present;
    }

    fn drainSpaceWaiting(
        self: *SyncClientV3,
        space: *space_mod.Space,
        cursor: *SpaceCursorState,
        topic_id: [32]u8,
        has_projection: bool,
        stats: *SyncStats,
    ) !usize {
        var total_applied: usize = 0;
        var progress = true;
        while (progress and cursor.waiting.items.len > 0) {
            progress = false;
            var i: usize = 0;
            while (i < cursor.waiting.items.len) {
                var r = codec.Reader.init(cursor.waiting.items[i].raw_batch);
                var batch = op_mod.Batch.decode(self.allocator, &r) catch {
                    const bad = cursor.waiting.orderedRemove(i);
                    self.allocator.free(bad.raw_batch);
                    continue;
                };
                defer batch.deinit(self.allocator);
                const outcome = try self.tryIntegrateSpaceBatch(space, cursor, topic_id, &batch, has_projection, stats);
                switch (outcome) {
                    .applied => {
                        total_applied += 1;
                        progress = true;
                        const done = cursor.waiting.orderedRemove(i);
                        self.allocator.free(done.raw_batch);
                    },
                    .already_present => {
                        const done = cursor.waiting.orderedRemove(i);
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

    pub fn pullSpace(
        self: *SyncClientV3,
        space: *space_mod.Space,
        topic_id: [32]u8,
        projection: ?*projection_mod.Projection,
    ) !SyncStats {
        try self.authV3(topic_id, wire.PERM_READ);

        var cursor = try self.loadSpaceCursor(space.state_dir, topic_id);
        defer cursor.deinit(self.allocator);

        const had_no_unpushed = cursor.has_pushed_once and space.history.dag.heads.eql(&cursor.last_pushed_heads);
        const has_projection = projection != null;
        var stats = SyncStats{ .last_seq = cursor.last_pulled_seq };
        var last_seq = cursor.last_pulled_seq;
        var dirty = false;

        while (true) {
            const prev_seq = last_seq;
            var page = try self.getEncryptedRangePageV3(self.allocator, topic_id, prev_seq, PULL_PAGE_LIMIT);
            defer page.deinit(self.allocator);
            stats.bytes_transferred += page.wire_bytes;

            for (page.frames) |f| {
                if (f.seq > last_seq) {
                    last_seq = f.seq;
                    dirty = true;
                }
                var r = codec.Reader.init(f.plaintext);
                var batch = op_mod.Batch.decode(self.allocator, &r) catch {
                    self.recordQuarantine(topic_id, f.seq, .decode_failed);
                    continue;
                };
                defer batch.deinit(self.allocator);
                const bid = batch.header.batchId();
                const outcome = try self.tryIntegrateSpaceBatch(space, &cursor, topic_id, &batch, has_projection, &stats);
                switch (outcome) {
                    .applied => {
                        stats.frames_pulled += 1;
                        dirty = true;
                        const drained = try self.drainSpaceWaiting(space, &cursor, topic_id, has_projection, &stats);
                        stats.frames_pulled += drained;
                    },
                    .already_present => {
                        dirty = true;
                    },
                    .waiting_parents, .waiting_blob => {
                        if (try cursor.addWaiting(self.allocator, bid, f.plaintext)) {
                            dirty = true;
                        }
                    },
                }
            }

            if (page.last_seq > last_seq) {
                last_seq = page.last_seq;
                dirty = true;
            }
            if (last_seq > cursor.last_pulled_seq) {
                cursor.last_pulled_seq = last_seq;
                dirty = true;
            }
            if (dirty) {
                try self.saveSpaceCursor(space.state_dir, topic_id, &cursor);
                dirty = false;
            }
            if (!page.has_more or page.item_count == 0 or last_seq <= prev_seq) break;
        }

        if (cursor.waiting.items.len > 0) {
            const drained = try self.drainSpaceWaiting(space, &cursor, topic_id, has_projection, &stats);
            if (drained > 0) {
                stats.frames_pulled += drained;
                dirty = true;
            }
        }

        if (last_seq > cursor.last_pulled_seq) {
            cursor.last_pulled_seq = last_seq;
            dirty = true;
        }
        if (had_no_unpushed and stats.frames_pulled > 0) {
            const new_heads = try space.history.dag.heads.clone(self.allocator);
            cursor.last_pushed_heads.deinit(self.allocator);
            cursor.last_pushed_heads = new_heads;
            cursor.last_pushed_wal_seq = @max(space.batch_log.lastSeq(), space.manifest.wal_base_seq);
            dirty = true;
        }
        if (dirty) {
            try self.saveSpaceCursor(space.state_dir, topic_id, &cursor);
        }

        if (projection) |proj| {
            if (stats.frames_pulled > 0) {
                try proj.materializeChanged();
            }
        }

        stats.last_seq = last_seq;
        return stats;
    }

    pub fn fetchBlobOnDemand(
        self: *SyncClientV3,
        space: *space_mod.Space,
        topic_id: [32]u8,
        hash: id.Oid,
    ) !?[]u8 {
        if (try space.blob_store.get(self.allocator, hash)) |local| {
            return local;
        }
        const raw = (try self.getEncryptedBlobV3(self.allocator, topic_id, hash)) orelse return null;
        errdefer self.allocator.free(raw);
        try space.blob_store.putVerified(hash, raw);
        return raw;
    }

    pub fn fetchGitBlobOnDemand(
        self: *SyncClientV3,
        space: *space_mod.Space,
        topic_id: [32]u8,
        git_oid: git_dirs_mod.GitOid,
    ) !?[]u8 {
        if (try space.history.readGitBlobAlloc(self.allocator, git_oid)) |local| {
            return local;
        }
        const raw = (try self.getEncryptedGitBlobV3(self.allocator, topic_id, git_oid)) orelse return null;
        errdefer self.allocator.free(raw);
        try space.blob_store.putGitFallback(git_oid.slice(), raw);
        return raw;
    }

    pub fn pushThread(
        self: *SyncClientV3,
        thread_store: *thread_store_mod.ThreadStore,
        topic_id: [32]u8,
        lease_epoch: ?u64,
    ) !SyncStats {
        const perm: u32 = if (lease_epoch != null)
            (@as(u32, wire.PERM_WRITE) | wire.PERM_LEASE)
        else
            wire.PERM_WRITE;
        try self.authV3(topic_id, perm);
        if (self.keyring.getEntityKey(topic_id) == null) return error.PermissionDenied;

        var cursor = try self.loadLogCursor(thread_store.thread_dir, topic_id);
        defer cursor.deinit(self.allocator);

        var stats = SyncStats{ .last_seq = cursor.last_pulled_relay_seq };
        const local_last = thread_store.lastSeq();
        if (local_last <= cursor.last_pushed_local_seq) return stats;

        const events = try thread_store.eventsSince(self.allocator, cursor.last_pushed_local_seq);
        defer thread_store_mod.ThreadStore.freeEvents(self.allocator, events);

        errdefer {
            if (stats.frames_pushed > 0) {
                cursor.out_seq = @max(cursor.out_seq, self.out_seqs.get(topic_id) orelse 0);
                self.saveLogCursor(thread_store.thread_dir, topic_id, &cursor) catch {};
            }
        }

        for (events) |ev| {
            if (cursor.pushed_ids.contains(ev.event_id)) continue;
            const raw = try ev.encodeAlloc(self.allocator);
            defer self.allocator.free(raw);
            try self.reserveLogOutSeq(thread_store.thread_dir, topic_id, &cursor);
            const res = try self.putEncryptedFrameV3(topic_id, raw, lease_epoch);
            try cursor.pushed_ids.put(self.allocator, ev.event_id, {});
            stats.frames_pushed += 1;
            stats.bytes_transferred += res.wire_bytes;
            if (res.seq > stats.last_seq) stats.last_seq = res.seq;
        }

        cursor.last_pushed_local_seq = local_last;
        cursor.out_seq = self.out_seqs.get(topic_id) orelse cursor.out_seq;
        try self.saveLogCursor(thread_store.thread_dir, topic_id, &cursor);
        return stats;
    }

    pub fn pullThread(
        self: *SyncClientV3,
        thread_store: *thread_store_mod.ThreadStore,
        topic_id: [32]u8,
    ) !SyncStats {
        try self.authV3(topic_id, wire.PERM_READ);

        var cursor = try self.loadLogCursor(thread_store.thread_dir, topic_id);
        defer cursor.deinit(self.allocator);

        var stats = SyncStats{ .last_seq = cursor.last_pulled_relay_seq };
        var last_seq = cursor.last_pulled_relay_seq;
        var dirty = false;

        while (true) {
            const prev_seq = last_seq;
            var page = try self.getEncryptedRangePageV3(self.allocator, topic_id, prev_seq, PULL_PAGE_LIMIT);
            defer page.deinit(self.allocator);
            stats.bytes_transferred += page.wire_bytes;

            for (page.frames) |f| {
                if (f.seq > last_seq) {
                    last_seq = f.seq;
                    dirty = true;
                }
                var ev = thread_model.CausalEvent.decodeSlice(self.allocator, f.plaintext) catch {
                    self.recordQuarantine(topic_id, f.seq, .decode_failed);
                    continue;
                };
                defer ev.deinit(self.allocator);

                try cursor.pushed_ids.put(self.allocator, ev.event_id, {});
                const applied = try thread_store.applyRemoteEvent(ev);
                if (applied) {
                    stats.frames_pulled += 1;
                    dirty = true;
                }
            }

            if (page.last_seq > last_seq) {
                last_seq = page.last_seq;
                dirty = true;
            }
            if (last_seq > cursor.last_pulled_relay_seq) {
                cursor.last_pulled_relay_seq = last_seq;
                dirty = true;
            }
            if (dirty) {
                try self.saveLogCursor(thread_store.thread_dir, topic_id, &cursor);
                dirty = false;
            }
            if (!page.has_more or page.item_count == 0 or last_seq <= prev_seq) break;
        }

        if (last_seq > cursor.last_pulled_relay_seq) {
            cursor.last_pulled_relay_seq = last_seq;
            dirty = true;
        }
        if (dirty) {
            try self.saveLogCursor(thread_store.thread_dir, topic_id, &cursor);
        }
        stats.last_seq = last_seq;
        return stats;
    }

    pub fn pushInboxWithDir(
        self: *SyncClientV3,
        base_dir: Io.Dir,
        parent_inbox_topic_id: [32]u8,
        mailbox_item: *const thread_model.MailboxItem,
    ) !SyncStats {
        var cursor = try self.loadLogCursor(base_dir, parent_inbox_topic_id);
        defer cursor.deinit(self.allocator);

        try self.reserveLogOutSeq(base_dir, parent_inbox_topic_id, &cursor);

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeByte(self.allocator, INBOX_FRAME_VERSION);
        try mailbox_item.encode(self.allocator, &w);
        const res = try self.putEncryptedFrameInternal(
            parent_inbox_topic_id,
            w.items(),
            null,
            wire.PERM_INBOX_APPEND,
        );
        cursor.out_seq = @max(cursor.out_seq, self.out_seqs.get(parent_inbox_topic_id) orelse 0);
        try self.saveLogCursor(base_dir, parent_inbox_topic_id, &cursor);
        return .{
            .frames_pushed = 1,
            .bytes_transferred = res.wire_bytes,
            .last_seq = res.seq,
        };
    }

    pub fn pushInbox(
        self: *SyncClientV3,
        parent_inbox_topic_id: [32]u8,
        mailbox_item: *const thread_model.MailboxItem,
    ) !SyncStats {
        if (self.cursor_dir) |dir| {
            return self.pushInboxWithDir(dir, parent_inbox_topic_id, mailbox_item);
        }
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeByte(self.allocator, INBOX_FRAME_VERSION);
        try mailbox_item.encode(self.allocator, &w);
        const res = try self.putEncryptedFrameInternal(
            parent_inbox_topic_id,
            w.items(),
            null,
            wire.PERM_INBOX_APPEND,
        );
        return .{
            .frames_pushed = 1,
            .bytes_transferred = res.wire_bytes,
            .last_seq = res.seq,
        };
    }

    pub fn pullInbox(
        self: *SyncClientV3,
        thread_store: *thread_store_mod.ThreadStore,
        inbox_topic_id: [32]u8,
    ) !SyncStats {
        try self.authV3(inbox_topic_id, wire.PERM_READ);

        var cursor = try self.loadLogCursor(thread_store.thread_dir, inbox_topic_id);
        defer cursor.deinit(self.allocator);

        var stats = SyncStats{ .last_seq = cursor.last_pulled_relay_seq };
        var last_seq = cursor.last_pulled_relay_seq;
        var dirty = false;

        while (true) {
            const prev_seq = last_seq;
            var page = try self.getEncryptedRangePageV3(self.allocator, inbox_topic_id, prev_seq, PULL_PAGE_LIMIT);
            defer page.deinit(self.allocator);
            stats.bytes_transferred += page.wire_bytes;

            for (page.frames) |f| {
                if (f.seq > last_seq) {
                    last_seq = f.seq;
                    dirty = true;
                }
                var r = codec.Reader.init(f.plaintext);
                const ver = r.readByte() catch {
                    self.recordQuarantine(inbox_topic_id, f.seq, .decode_failed);
                    continue;
                };
                if (ver != INBOX_FRAME_VERSION) {
                    self.recordQuarantine(inbox_topic_id, f.seq, .decode_failed);
                    continue;
                }
                var mb = thread_model.MailboxItem.decode(self.allocator, &r) catch {
                    self.recordQuarantine(inbox_topic_id, f.seq, .decode_failed);
                    continue;
                };
                defer mb.deinit(self.allocator);

                if (thread_store.mailbox.contains(mb.item_id)) continue;
                const ev = thread_model.CausalEvent{
                    .event_id = deterministicInboxEventId(inbox_topic_id, mb.item_id),
                    .lamport = thread_store.lamport + 1,
                    .actor = f.sender_id,
                    .event = .{ .mailbox_received = mb },
                };
                const applied = try thread_store.applyRemoteEvent(ev);
                if (applied) {
                    stats.frames_pulled += 1;
                    dirty = true;
                }
            }

            if (page.last_seq > last_seq) {
                last_seq = page.last_seq;
                dirty = true;
            }
            if (last_seq > cursor.last_pulled_relay_seq) {
                cursor.last_pulled_relay_seq = last_seq;
                dirty = true;
            }
            if (dirty) {
                try self.saveLogCursor(thread_store.thread_dir, inbox_topic_id, &cursor);
                dirty = false;
            }
            if (!page.has_more or page.item_count == 0 or last_seq <= prev_seq) break;
        }

        if (last_seq > cursor.last_pulled_relay_seq) {
            cursor.last_pulled_relay_seq = last_seq;
            dirty = true;
        }
        if (dirty) {
            try self.saveLogCursor(thread_store.thread_dir, inbox_topic_id, &cursor);
        }
        stats.last_seq = last_seq;
        return stats;
    }

    pub fn pushCatalog(
        self: *SyncClientV3,
        catalog_store: *thread_store_mod.CatalogStore,
        topic_id: [32]u8,
    ) !SyncStats {
        try self.authV3(topic_id, wire.PERM_WRITE);
        if (self.keyring.getEntityKey(topic_id) == null) return error.PermissionDenied;

        var cursor = try self.loadLogCursor(catalog_store.catalog_dir, topic_id);
        defer cursor.deinit(self.allocator);

        var stats = SyncStats{ .last_seq = cursor.last_pulled_relay_seq };
        const local_last = catalog_store.wal.lastSeq();
        if (local_last <= cursor.last_pushed_local_seq) return stats;

        const entries = try catalog_store.entriesSince(self.allocator, cursor.last_pushed_local_seq);
        defer {
            for (entries) |*e| e.deinit(self.allocator);
            if (entries.len > 0) self.allocator.free(entries);
        }

        errdefer {
            if (stats.frames_pushed > 0) {
                cursor.out_seq = @max(cursor.out_seq, self.out_seqs.get(topic_id) orelse 0);
                self.saveLogCursor(catalog_store.catalog_dir, topic_id, &cursor) catch {};
            }
        }

        for (entries) |entry| {
            const raw = try entry.encodeAlloc(self.allocator);
            defer self.allocator.free(raw);
            const eid = hashBytesToU128(raw);
            if (cursor.pushed_ids.contains(eid)) continue;
            try self.reserveLogOutSeq(catalog_store.catalog_dir, topic_id, &cursor);
            const res = try self.putEncryptedFrameV3(topic_id, raw, null);
            try cursor.pushed_ids.put(self.allocator, eid, {});
            stats.frames_pushed += 1;
            stats.bytes_transferred += res.wire_bytes;
            if (res.seq > stats.last_seq) stats.last_seq = res.seq;
        }

        cursor.last_pushed_local_seq = local_last;
        cursor.out_seq = self.out_seqs.get(topic_id) orelse cursor.out_seq;
        try self.saveLogCursor(catalog_store.catalog_dir, topic_id, &cursor);
        return stats;
    }

    pub fn pullCatalog(
        self: *SyncClientV3,
        catalog_store: *thread_store_mod.CatalogStore,
        topic_id: [32]u8,
    ) !SyncStats {
        try self.authV3(topic_id, wire.PERM_READ);

        var cursor = try self.loadLogCursor(catalog_store.catalog_dir, topic_id);
        defer cursor.deinit(self.allocator);

        var stats = SyncStats{ .last_seq = cursor.last_pulled_relay_seq };
        var last_seq = cursor.last_pulled_relay_seq;
        var dirty = false;

        while (true) {
            const prev_seq = last_seq;
            var page = try self.getEncryptedRangePageV3(self.allocator, topic_id, prev_seq, PULL_PAGE_LIMIT);
            defer page.deinit(self.allocator);
            stats.bytes_transferred += page.wire_bytes;

            for (page.frames) |f| {
                if (f.seq > last_seq) {
                    last_seq = f.seq;
                    dirty = true;
                }
                const eid = hashBytesToU128(f.plaintext);
                try cursor.pushed_ids.put(self.allocator, eid, {});
                var entry = thread_model.CatalogEntry.decodeSlice(self.allocator, f.plaintext) catch {
                    self.recordQuarantine(topic_id, f.seq, .decode_failed);
                    continue;
                };
                defer entry.deinit(self.allocator);

                const applied = try catalog_store.putEntry(entry);
                if (applied) {
                    stats.frames_pulled += 1;
                    dirty = true;
                }
            }

            if (page.last_seq > last_seq) {
                last_seq = page.last_seq;
                dirty = true;
            }
            if (last_seq > cursor.last_pulled_relay_seq) {
                cursor.last_pulled_relay_seq = last_seq;
                dirty = true;
            }
            if (dirty) {
                try self.saveLogCursor(catalog_store.catalog_dir, topic_id, &cursor);
                dirty = false;
            }
            if (!page.has_more or page.item_count == 0 or last_seq <= prev_seq) break;
        }

        if (last_seq > cursor.last_pulled_relay_seq) {
            cursor.last_pulled_relay_seq = last_seq;
            dirty = true;
        }
        if (dirty) {
            try self.saveLogCursor(catalog_store.catalog_dir, topic_id, &cursor);
        }
        stats.last_seq = last_seq;
        return stats;
    }
};
