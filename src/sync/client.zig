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
const wire = @import("wire.zig");

pub const SenderKey = struct {
    topic: [32]u8,
    sender_id: u128,
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

pub const FramePayload = struct {
    sender_id: u128,
    sender_seq: u64,
    plaintext: []u8,
};

const FRAME_AAD_PREFIX = "0ndb-frame-v2";
const BLOB_AAD_PREFIX = "0ndb-blob-v2";
const FRAME_HEADER_LEN: usize = 24;

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
    const key = crypto.deriveTopicKey(master_key, topic);
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

    const key = crypto.deriveTopicKey(master_key, expected_topic);
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
const SYNC_CURSOR_VERSION: u16 = 1;

const WorkspaceSyncState = struct {
    last_pulled_seq: u64 = 0,
    pushed_batches: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty,
    uploaded_blobs: std.AutoHashMapUnmanaged([32]u8, void) = .empty,

    fn deinit(self: *WorkspaceSyncState, allocator: Allocator) void {
        self.pushed_batches.deinit(allocator);
        self.uploaded_blobs.deinit(allocator);
    }
};

fn opReferencedBlob(op: op_mod.Op) ?struct { oid: id.Oid, is_text_blob: bool } {
    return switch (op) {
        .create_file => |cf| switch (cf.content) {
            .binary => |b| .{ .oid = b.oid, .is_text_blob = false },
            .text_blob => |b| .{ .oid = b.oid, .is_text_blob = true },
            .text_inline => null,
        },
        .set_content => |sc| switch (sc.content) {
            .binary => |b| .{ .oid = b.oid, .is_text_blob = false },
            .text_blob => |b| .{ .oid = b.oid, .is_text_blob = true },
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
    auth_secret: [32]u8,
    sender_id: u128,
    out_seqs: std.AutoHashMapUnmanaged([32]u8, u64),
    live_seen_seqs: std.AutoHashMapUnmanaged(SenderKey, u64),
    authorized_topics: std.AutoHashMapUnmanaged([32]u8, u8),
    uploaded_blobs: std.AutoHashMapUnmanaged([32]u8, void),
    ws_states: std.AutoHashMapUnmanaged(id.ActorId, WorkspaceSyncState),
    pending_events: std.ArrayList(DecryptedFrame),

    pub fn connect(
        allocator: Allocator,
        io: Io,
        host_ip: [4]u8,
        port: u16,
        master_key: crypto.Key,
        auth_secret: [32]u8,
    ) !SyncClient {
        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(s_rc) != .SUCCESS) return error.SocketFailed;
        const fd: posix.fd_t = @intCast(s_rc);
        errdefer _ = linux.close(fd);

        var one: i32 = 1;
        _ = linux.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));

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
            .live_seen_seqs = .empty,
            .authorized_topics = .empty,
            .uploaded_blobs = .empty,
            .ws_states = .empty,
            .pending_events = .empty,
        };
    }

    pub fn deinit(self: *SyncClient) void {
        for (self.pending_events.items) |*ev| ev.deinit(self.allocator);
        self.pending_events.deinit(self.allocator);
        self.out_seqs.deinit(self.allocator);
        self.live_seen_seqs.deinit(self.allocator);
        self.authorized_topics.deinit(self.allocator);
        self.uploaded_blobs.deinit(self.allocator);
        var wit = self.ws_states.valueIterator();
        while (wit.next()) |st| st.deinit(self.allocator);
        self.ws_states.deinit(self.allocator);
        _ = linux.close(self.fd);
    }

    fn bufferLiveEventFrame(self: *SyncClient, frame: *const wire.WireFrame) !void {
        if (frame.payload.len < 40) return;
        const tid: [32]u8 = frame.payload[0..32].*;
        const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
        const dec = openFramePayload(self.allocator, self.master_key, tid, frame.payload[40..], &self.live_seen_seqs, self.allocator) catch return;
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

    pub fn authorizeTopic(self: *SyncClient, topic: [32]u8, perms: u8) !void {
        if (self.authorized_topics.get(topic)) |existing| {
            if ((existing & perms) == perms) return;
        }
        try self.authorizeTopicWithExpiry(topic, perms, 0);
        const prev = self.authorized_topics.get(topic) orelse 0;
        try self.authorized_topics.put(self.allocator, topic, prev | perms);
    }

    pub fn authorizeTopicWithExpiry(self: *SyncClient, topic: [32]u8, perms: u8, expires_ms: u64) !void {
        const mac = crypto.deriveCapabilityToken(self.auth_secret, topic, perms, expires_ms);
        var payload: [32 + 1 + 8 + 32]u8 = undefined;
        @memcpy(payload[0..32], &topic);
        payload[32] = perms;
        std.mem.writeInt(u64, payload[33..41], expires_ms, .little);
        @memcpy(payload[41..73], &mac);
        try wire.writeFrameBlocking(self.allocator, self.fd, .auth, 0, &payload);
        var resp = try self.readRpcResponse();
        defer resp.deinit(self.allocator);
        if (resp.op != .ack) return error.AuthRejected;
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

    pub fn getEncryptedRange(
        self: *SyncClient,
        allocator: Allocator,
        topic: [32]u8,
        after_seq: u64,
        limit: u32,
    ) ![]DecryptedFrame {
        var req: [32 + 8 + 4]u8 = undefined;
        @memcpy(req[0..32], &topic);
        std.mem.writeInt(u64, req[32..40], after_seq, .little);
        std.mem.writeInt(u32, req[40..44], limit, .little);
        try wire.writeFrameBlocking(self.allocator, self.fd, .get_range, 0, &req);

        var range_seen: std.AutoHashMapUnmanaged(SenderKey, u64) = .empty;
        defer range_seen.deinit(self.allocator);

        var out: std.ArrayList(DecryptedFrame) = .empty;
        errdefer {
            for (out.items) |*f| f.deinit(allocator);
            out.deinit(allocator);
        }

        while (true) {
            var frame = try wire.readFrameBlocking(self.allocator, self.fd);
            defer frame.deinit(self.allocator);
            if (frame.op == .range_end) break;
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
            const env = frame.payload[40..];
            const dec = openFramePayload(allocator, self.master_key, topic, env, &range_seen, self.allocator) catch |err| {
                self.drainUntilOp(.range_end);
                return err;
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
        return try out.toOwnedSlice(allocator);
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
                const dec = openFramePayload(self.allocator, self.master_key, topic, frame.payload[40..], &self.live_seen_seqs, self.allocator) catch |err| {
                    self.drainUntilOp(.ack);
                    return err;
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
        var frame = try wire.readFrameBlocking(self.allocator, self.fd);
        defer frame.deinit(self.allocator);
        if (frame.op != .frame_event or frame.payload.len < 40) return error.BadRelayFrame;
        const tid: [32]u8 = frame.payload[0..32].*;
        const seq = std.mem.readInt(u64, frame.payload[32..40], .little);
        const dec = try openFramePayload(allocator, self.master_key, tid, frame.payload[40..], &self.live_seen_seqs, self.allocator);
        return .{
            .topic_id = tid,
            .seq = seq,
            .sender_id = dec.sender_id,
            .sender_seq = dec.sender_seq,
            .plaintext = dec.plaintext,
        };
    }

    pub fn putEncryptedBlob(self: *SyncClient, topic: [32]u8, oid: [32]u8, plaintext: []const u8) !void {
        const key = crypto.deriveTopicKey(self.master_key, topic);
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
        const key = crypto.deriveTopicKey(self.master_key, topic);
        const aad = buildBlobAad(topic, oid);
        const plain = try crypto.open(allocator, key, &aad, resp.payload[33..]);
        errdefer allocator.free(plain);
        const actual = crypto.hashBytes(plain);
        if (!std.mem.eql(u8, &actual, &oid)) return error.HashMismatch;
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
            const sum = try model.SessionSummary.decode(allocator, &r);
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
        if (magic != SYNC_CURSOR_MAGIC or ver != SYNC_CURSOR_VERSION) return;

        const saved_sender = r.readU128() catch return;
        const out_count = r.readU32() catch return;
        const adopt_sender = self.out_seqs.count() == 0;
        if (adopt_sender and saved_sender != 0) {
            self.sender_id = saved_sender;
        }
        for (0..out_count) |_| {
            const topic = (r.readFixed(32) catch return).*;
            const seq = r.readU64() catch return;
            if (adopt_sender) {
                self.out_seqs.put(self.allocator, topic, seq) catch return;
            }
        }

        st.last_pulled_seq = r.readU64() catch return;
        const batch_count = r.readU32() catch return;
        for (0..batch_count) |_| {
            const actor = r.readU128() catch return;
            const ts = r.readU64() catch return;
            st.pushed_batches.put(self.allocator, id.OpId.init(ts, actor), {}) catch return;
        }
        const blob_count = r.readU32() catch return;
        for (0..blob_count) |_| {
            const oid = (r.readFixed(32) catch return).*;
            st.uploaded_blobs.put(self.allocator, oid, {}) catch return;
        }
    }

    fn saveWorkspaceCursorFile(self: *SyncClient, ws: *ws_mod.Workspace, st: *const WorkspaceSyncState) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, SYNC_CURSOR_MAGIC);
        try w.writeU16(self.allocator, SYNC_CURSOR_VERSION);
        try w.writeU128(self.allocator, self.sender_id);
        try w.writeU32(self.allocator, @intCast(self.out_seqs.count()));
        var oit = self.out_seqs.iterator();
        while (oit.next()) |e| {
            try w.writeRaw(self.allocator, &e.key_ptr.*);
            try w.writeU64(self.allocator, e.value_ptr.*);
        }
        try w.writeU64(self.allocator, st.last_pulled_seq);
        try w.writeU32(self.allocator, @intCast(st.pushed_batches.count()));
        var bit = st.pushed_batches.keyIterator();
        while (bit.next()) |bid| {
            try w.writeU128(self.allocator, bid.actor);
            try w.writeU64(self.allocator, bid.ts);
        }
        try w.writeU32(self.allocator, @intCast(st.uploaded_blobs.count()));
        var blit = st.uploaded_blobs.keyIterator();
        while (blit.next()) |oid| {
            try w.writeRaw(self.allocator, &oid.*);
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

    pub fn pushWorkspace(self: *SyncClient, ws: *ws_mod.Workspace) !usize {
        const topic = id.worktreeStreamId(ws.history.history_id);
        try self.authorizeTopic(topic, wire.PERM_ALL);
        const st = try self.getOrLoadWorkspaceState(ws);
        var pushed: usize = 0;
        const n = ws.batch_log.count();
        for (0..n) |i| {
            const view = try ws.batch_log.readAt(i);
            if (view.header.kind != ws_mod.FRAME_BATCH) continue;
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decode(self.allocator, &r);
            defer batch.deinit(self.allocator);
            const bid = batch.header.batchId();
            if (st.pushed_batches.contains(bid)) continue;

            for (batch.blobs) |b| {
                if (!st.uploaded_blobs.contains(b.oid)) {
                    try self.putEncryptedBlob(topic, b.oid, b.data);
                    try st.uploaded_blobs.put(self.allocator, b.oid, {});
                }
            }
            for (batch.ops) |op| {
                if (opReferencedBlob(op)) |ref| {
                    if (!st.uploaded_blobs.contains(ref.oid)) {
                        if (try ws.blob_store.get(self.allocator, ref.oid)) |raw| {
                            defer self.allocator.free(raw);
                            try self.putEncryptedBlob(topic, ref.oid, raw);
                            try st.uploaded_blobs.put(self.allocator, ref.oid, {});
                        } else if (ws.history.resolveBlob(ref.oid)) |raw| {
                            try self.putEncryptedBlob(topic, ref.oid, raw);
                            try st.uploaded_blobs.put(self.allocator, ref.oid, {});
                        }
                    }
                }
            }

            if (batch.blobs.len > 0) {
                var stripped = batch;
                stripped.blobs = &.{};
                var w = codec.Writer{};
                defer w.deinit(self.allocator);
                try stripped.encode(self.allocator, &w);
                _ = try self.putEncryptedFrame(topic, w.items());
            } else {
                _ = try self.putEncryptedFrame(topic, view.payload);
            }
            try st.pushed_batches.put(self.allocator, bid, {});
            pushed += 1;
        }
        if (pushed > 0) {
            try self.saveWorkspaceCursorFile(ws, st);
        }
        return pushed;
    }

    pub fn pullWorkspace(
        self: *SyncClient,
        ws: *ws_mod.Workspace,
        after_seq: u64,
    ) !struct { applied: usize, last_seq: u64 } {
        const topic = id.worktreeStreamId(ws.history.history_id);
        try self.authorizeTopic(topic, wire.PERM_ALL);
        const st = try self.getOrLoadWorkspaceState(ws);
        const effective_after = @max(after_seq, st.last_pulled_seq);
        const frames = try self.getEncryptedRange(self.allocator, topic, effective_after, 0);
        defer {
            for (frames) |*f| f.deinit(self.allocator);
            self.allocator.free(frames);
        }

        var applied: usize = 0;
        var last_seq = effective_after;
        var dirty = false;
        for (frames) |f| {
            if (f.seq > last_seq) {
                last_seq = f.seq;
                dirty = true;
            }
            var r = codec.Reader.init(f.plaintext);
            var batch = try op_mod.Batch.decode(self.allocator, &r);
            defer batch.deinit(self.allocator);
            const bid = batch.header.batchId();
            if (!st.pushed_batches.contains(bid)) {
                try st.pushed_batches.put(self.allocator, bid, {});
                dirty = true;
            }
            if (ws.history.dag.containsBatch(bid)) continue;

            for (batch.blobs) |b| {
                if (!ws.blob_store.exists(b.oid)) {
                    try ws.blob_store.putVerified(b.oid, b.data);
                }
                if (!ws.history.blobs.contains(b.oid)) {
                    try ws.history.putBlob(b.oid, b.data);
                }
            }
            for (batch.ops) |op| {
                if (opReferencedBlob(op)) |ref| {
                    if (!ws.blob_store.exists(ref.oid)) {
                        if (try self.getEncryptedBlob(self.allocator, topic, ref.oid)) |raw| {
                            defer self.allocator.free(raw);
                            try ws.blob_store.putVerified(ref.oid, raw);
                            if (ref.is_text_blob and !ws.history.blobs.contains(ref.oid)) {
                                try ws.history.putBlob(ref.oid, raw);
                            }
                        }
                    } else if (ref.is_text_blob and !ws.history.blobs.contains(ref.oid)) {
                        if (try ws.blob_store.get(self.allocator, ref.oid)) |raw| {
                            defer self.allocator.free(raw);
                            try ws.history.putBlob(ref.oid, raw);
                        }
                    }
                }
            }

            if (try ws.commitBatchWithSource(&batch, "sync")) {
                applied += 1;
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
