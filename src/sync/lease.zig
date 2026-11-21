const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const id = @import("../core/id.zig");
const crypto = @import("../store/crypto.zig");
const mmap = @import("../store/mmap.zig");
const wire = @import("wire.zig");

pub const MIN_LEASE_TTL_MS: u64 = 1000;
pub const MAX_LEASE_TTL_MS: u64 = 300_000;

fn nowAwakeMs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    const ms = @divFloor(ts.nanoseconds, std.time.ns_per_ms);
    return if (ms < 0) 0 else @intCast(ms);
}

const LOCAL_EPOCH_MAGIC: [8]u8 = .{ '0', 'N', 'D', 'B', 'L', 'E', 'P', '1' };
const LOCAL_EPOCH_FILE_LEN: usize = 8 + 8 + 1 + 8 + 32;

pub const LeaseMode = enum {
    local_offline,
    relay_fenced,
};

pub const LeaseHandle = struct {
    topic_id: [32]u8,
    runner_id: u128,
    fencing_epoch: u64,
    expires_ms: u64,
    mode: LeaseMode,
    lock_fd: ?posix.fd_t = null,
    canceled: bool = false,
    cancel_epoch: u64 = 0,
    expires_mono_ms: u64 = 0,
};

pub const TopicToken = struct {
    topic: [32]u8,
    perms: u32,
    expires_ms: u64,
    mac: crypto.Mac,

    pub fn mint(secret: [32]u8, topic: [32]u8, perms: u32, expires_ms: u64) TopicToken {
        return .{
            .topic = topic,
            .perms = perms,
            .expires_ms = expires_ms,
            .mac = crypto.deriveCapabilityTokenV3(secret, topic, perms, expires_ms),
        };
    }

    pub fn zeroize(self: *TopicToken) void {
        crypto.zeroize(&self.mac);
    }
};

pub const RelayConfig = struct {
    host_ip: [4]u8,
    port: u16,
    auth_secret: ?[32]u8 = null,
    io_timeout_ms: i32 = wire.DEFAULT_IO_TIMEOUT_MS,
};

const LocalEpochRecord = struct {
    fencing_epoch: u64 = 0,
    canceled: bool = false,
    cancel_epoch: u64 = 0,

    fn encode(self: LocalEpochRecord) [LOCAL_EPOCH_FILE_LEN]u8 {
        var buf: [LOCAL_EPOCH_FILE_LEN]u8 = undefined;
        @memcpy(buf[0..8], &LOCAL_EPOCH_MAGIC);
        std.mem.writeInt(u64, buf[8..16], self.fencing_epoch, .little);
        buf[16] = if (self.canceled) 1 else 0;
        std.mem.writeInt(u64, buf[17..25], self.cancel_epoch, .little);
        const digest = crypto.hashBytes(buf[0..25]);
        @memcpy(buf[25..57], &digest);
        return buf;
    }

    fn decode(buf: *const [LOCAL_EPOCH_FILE_LEN]u8) !LocalEpochRecord {
        if (!std.mem.eql(u8, buf[0..8], &LOCAL_EPOCH_MAGIC)) return error.CorruptLeaseEpoch;
        const digest = crypto.hashBytes(buf[0..25]);
        if (!std.crypto.timing_safe.eql([32]u8, digest, buf[25..57].*)) return error.CorruptLeaseEpoch;
        if (buf[16] > 1) return error.CorruptLeaseEpoch;
        return .{
            .fencing_epoch = std.mem.readInt(u64, buf[8..16], .little),
            .canceled = buf[16] == 1,
            .cancel_epoch = std.mem.readInt(u64, buf[17..25], .little),
        };
    }
};

const LocalLockState = struct {
    fd: posix.fd_t,
    fencing_epoch: u64,
    expires_ms: u64,
    expires_mono_ms: u64,
    canceled: bool,
    cancel_epoch: u64,
};

pub const LeaseManager = struct {
    allocator: Allocator,
    io: Io,
    runner_id: u128,
    state_dir: Io.Dir,
    leases_dir: Io.Dir,
    relay_cfg: ?RelayConfig,
    fd: ?posix.fd_t,
    authed_topics: std.AutoHashMapUnmanaged([32]u8, u32),
    topic_tokens: std.AutoHashMapUnmanaged([32]u8, TopicToken),
    local_locks: std.AutoHashMapUnmanaged([32]u8, LocalLockState),
    last_lease_response: ?wire.LeaseResponse,

    pub fn init(
        allocator: Allocator,
        io: Io,
        state_path: []const u8,
        runner_id: u128,
        relay_cfg: ?RelayConfig,
    ) !LeaseManager {
        try Io.Dir.cwd().createDirPath(io, state_path);
        var state_dir = try Io.Dir.cwd().openDir(io, state_path, .{ .iterate = true });
        errdefer state_dir.close(io);
        try state_dir.createDirPath(io, "leases");
        var leases_dir = try state_dir.openDir(io, "leases", .{ .iterate = true });
        errdefer leases_dir.close(io);

        return .{
            .allocator = allocator,
            .io = io,
            .runner_id = runner_id,
            .state_dir = state_dir,
            .leases_dir = leases_dir,
            .relay_cfg = relay_cfg,
            .fd = null,
            .authed_topics = .empty,
            .topic_tokens = .empty,
            .local_locks = .empty,
            .last_lease_response = null,
        };
    }

    pub fn deinit(self: *LeaseManager) void {
        self.disconnectRelay();
        {
            var it = self.local_locks.valueIterator();
            while (it.next()) |st| {
                _ = linux.flock(st.fd, posix.LOCK.UN);
                _ = linux.close(st.fd);
            }
            self.local_locks.deinit(self.allocator);
        }
        {
            var tit = self.topic_tokens.valueIterator();
            while (tit.next()) |tok| tok.zeroize();
            self.topic_tokens.deinit(self.allocator);
        }
        self.authed_topics.deinit(self.allocator);
        if (self.relay_cfg != null and self.relay_cfg.?.auth_secret != null) {
            crypto.zeroize(&self.relay_cfg.?.auth_secret.?);
            self.relay_cfg.?.auth_secret = null;
        }
        self.leases_dir.close(self.io);
        self.state_dir.close(self.io);
    }

    pub fn setTopicToken(self: *LeaseManager, token: TopicToken) !void {
        if (self.topic_tokens.getPtr(token.topic)) |prev| {
            prev.zeroize();
        }
        try self.topic_tokens.put(self.allocator, token.topic, token);
    }

    pub fn disconnectRelay(self: *LeaseManager) void {
        if (self.fd) |sock| {
            _ = linux.close(sock);
            self.fd = null;
        }
        self.authed_topics.clearRetainingCapacity();
    }

    fn ioTimeoutMs(self: *const LeaseManager) i32 {
        return if (self.relay_cfg) |cfg| cfg.io_timeout_ms else wire.DEFAULT_IO_TIMEOUT_MS;
    }

    fn ensureConnected(self: *LeaseManager) !posix.fd_t {
        if (self.fd) |sock| return sock;
        const cfg = self.relay_cfg orelse return error.NoRelayConfigured;

        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(s_rc) != .SUCCESS) return error.SocketFailed;
        const sock: posix.fd_t = @intCast(s_rc);
        errdefer _ = linux.close(sock);

        var one: i32 = 1;
        _ = linux.setsockopt(sock, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
        const to_u32: u32 = if (cfg.io_timeout_ms <= 0) 1000 else @intCast(cfg.io_timeout_ms);
        wire.setSocketTimeouts(sock, to_u32) catch {};

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, cfg.port),
            .addr = @bitCast(cfg.host_ip),
        };
        if (linux.errno(linux.connect(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return error.ConnectFailed;
        }

        self.fd = sock;
        self.authed_topics.clearRetainingCapacity();
        return sock;
    }

    fn readRpcFrame(self: *LeaseManager, sock: posix.fd_t) !wire.WireFrame {
        const timeout_ms = self.ioTimeoutMs();
        while (true) {
            var frame = wire.readFrameWithTimeout(self.allocator, sock, timeout_ms) catch |err| {
                self.disconnectRelay();
                return err;
            };
            if (frame.op == .frame_event or frame.op == .lease_cancel_event) {
                frame.deinit(self.allocator);
                continue;
            }
            return frame;
        }
    }

    fn mapRelayErr(self: *LeaseManager, payload: []const u8) anyerror {
        const ep = wire.decodeErrPayload(payload) catch return error.RelayError;
        if (ep.body.len == wire.LeaseResponse.ENCODED_LEN) {
            if (wire.LeaseResponse.decode(ep.body)) |lr| {
                self.last_lease_response = lr;
            } else |_| {}
        }
        return switch (ep.code) {
            .fenced => error.Fenced,
            .lease_held => error.LeaseHeld,
            .cancelled => error.LeaseCancelled,
            .unauthorized => error.Unauthorized,
            .bad_frame => error.BadRelayFrame,
            .not_found => error.NotFound,
            .internal => error.RelayError,
        };
    }

    fn authorizeTopicLocked(self: *LeaseManager, sock: posix.fd_t, topic_id: [32]u8, needed_perms: u32) !void {
        if (self.authed_topics.get(topic_id)) |granted| {
            if ((granted & needed_perms) == needed_perms) return;
        }

        var auth_buf: [wire.AUTH_V3_LEN]u8 = undefined;
        defer crypto.zeroize(&auth_buf);
        var granted_perms: u32 = 0;
        var persistent_grant = false;

        if (self.topic_tokens.get(topic_id)) |tok| {
            auth_buf = wire.encodeAuthV3(tok.topic, tok.perms, tok.expires_ms, tok.mac);
            granted_perms = tok.perms;
            persistent_grant = tok.expires_ms == 0;
        } else if (self.relay_cfg != null and self.relay_cfg.?.auth_secret != null) {
            const secret = self.relay_cfg.?.auth_secret.?;
            const perms = wire.PERM_ALL_V3;
            var mac = crypto.deriveCapabilityTokenV3(secret, topic_id, perms, 0);
            defer crypto.zeroize(&mac);
            auth_buf = wire.encodeAuthV3(topic_id, perms, 0, mac);
            granted_perms = perms;
            persistent_grant = true;
        } else {
            return;
        }

        wire.writeFrameWithTimeout(self.allocator, sock, .auth, 0, &auth_buf, self.ioTimeoutMs()) catch |err| {
            self.disconnectRelay();
            return err;
        };
        var resp = try self.readRpcFrame(sock);
        defer resp.deinit(self.allocator);
        if (resp.op == .err) return self.mapRelayErr(resp.payload);
        if (resp.op != .ack) return error.BadRelayFrame;

        if (persistent_grant) {
            const prev = self.authed_topics.get(topic_id) orelse 0;
            try self.authed_topics.put(self.allocator, topic_id, prev | granted_perms);
        }
    }

    fn readLocalEpoch(self: *const LeaseManager, topic_id: [32]u8) !LocalEpochRecord {
        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(topic_id, &hex);
        var name_buf: [80]u8 = undefined;
        const fname = try std.fmt.bufPrint(&name_buf, "{s}.epoch", .{hex});

        const f = self.leases_dir.openFile(self.io, fname, .{}) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer f.close(self.io);
        var raw: [LOCAL_EPOCH_FILE_LEN]u8 = undefined;
        const n = try f.readPositionalAll(self.io, &raw, 0);
        if (n != LOCAL_EPOCH_FILE_LEN) return error.CorruptLeaseEpoch;
        return LocalEpochRecord.decode(&raw);
    }

    fn writeLocalEpoch(self: *const LeaseManager, topic_id: [32]u8, rec: LocalEpochRecord) !void {
        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(topic_id, &hex);
        var name_buf: [80]u8 = undefined;
        const fname = try std.fmt.bufPrint(&name_buf, "{s}.epoch", .{hex});
        const enc = rec.encode();
        try mmap.atomicWriteFile(self.io, self.leases_dir, fname, &enc);
    }

    fn acquireLocal(self: *LeaseManager, topic_id: [32]u8, ttl_ms: u64) !LeaseHandle {
        const now_ms = id.nowMs(self.io);
        const now_mono = nowAwakeMs(self.io);
        const clamped = std.math.clamp(ttl_ms, MIN_LEASE_TTL_MS, MAX_LEASE_TTL_MS);

        if (self.local_locks.getPtr(topic_id)) |existing| {
            if (!existing.canceled and now_mono < existing.expires_mono_ms) {
                existing.expires_ms = now_ms +| clamped;
                existing.expires_mono_ms = now_mono +| clamped;
                return .{
                    .topic_id = topic_id,
                    .runner_id = self.runner_id,
                    .fencing_epoch = existing.fencing_epoch,
                    .expires_ms = existing.expires_ms,
                    .mode = .local_offline,
                    .lock_fd = existing.fd,
                    .canceled = existing.canceled,
                    .cancel_epoch = existing.cancel_epoch,
                    .expires_mono_ms = existing.expires_mono_ms,
                };
            }
            _ = linux.flock(existing.fd, posix.LOCK.UN);
            _ = linux.close(existing.fd);
            _ = self.local_locks.remove(topic_id);
        }

        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(topic_id, &hex);
        var path_buf: [80]u8 = undefined;
        const lock_slice = try std.fmt.bufPrint(path_buf[0..79], "{s}.lock", .{hex});
        path_buf[lock_slice.len] = 0;
        const lock_name: [:0]const u8 = path_buf[0..lock_slice.len :0];

        const open_rc = linux.openat(
            self.leases_dir.handle,
            lock_name.ptr,
            .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true },
            0o600,
        );
        if (linux.errno(open_rc) != .SUCCESS) return error.LockOpenFailed;
        const lock_fd: posix.fd_t = @intCast(open_rc);
        errdefer _ = linux.close(lock_fd);

        while (true) {
            const fl_rc = linux.flock(lock_fd, posix.LOCK.EX | posix.LOCK.NB);
            const fl_e = linux.errno(fl_rc);
            if (fl_e == .INTR) continue;
            if (fl_e == .AGAIN) return error.LeaseHeld;
            if (fl_e != .SUCCESS) return error.FlockFailed;
            break;
        }
        errdefer _ = linux.flock(lock_fd, posix.LOCK.UN);

        const prev = try self.readLocalEpoch(topic_id);
        const next_epoch = std.math.add(u64, prev.fencing_epoch, 1) catch return error.EpochOverflow;
        const next_rec = LocalEpochRecord{
            .fencing_epoch = next_epoch,
            .canceled = false,
            .cancel_epoch = prev.cancel_epoch,
        };
        try self.writeLocalEpoch(topic_id, next_rec);

        const expires_ms = now_ms +| clamped;
        const expires_mono_ms = now_mono +| clamped;
        try self.local_locks.put(self.allocator, topic_id, .{
            .fd = lock_fd,
            .fencing_epoch = next_epoch,
            .expires_ms = expires_ms,
            .expires_mono_ms = expires_mono_ms,
            .canceled = false,
            .cancel_epoch = prev.cancel_epoch,
        });

        return .{
            .topic_id = topic_id,
            .runner_id = self.runner_id,
            .fencing_epoch = next_epoch,
            .expires_ms = expires_ms,
            .mode = .local_offline,
            .lock_fd = lock_fd,
            .canceled = false,
            .cancel_epoch = prev.cancel_epoch,
            .expires_mono_ms = expires_mono_ms,
        };
    }

    pub fn acquire(self: *LeaseManager, topic_id: [32]u8, expected_epoch: u64, ttl_ms: u64) !LeaseHandle {
        if (self.relay_cfg == null) {
            return self.acquireLocal(topic_id, ttl_ms);
        }

        const sock = self.ensureConnected() catch |err| switch (err) {
            error.ConnectFailed, error.SocketFailed => return self.acquireLocal(topic_id, ttl_ms),
            else => return err,
        };

        try self.authorizeTopicLocked(sock, topic_id, wire.PERM_LEASE);

        const clamped = std.math.clamp(ttl_ms, MIN_LEASE_TTL_MS, MAX_LEASE_TTL_MS);
        const req_mono = nowAwakeMs(self.io);
        const req = wire.LeaseAcquireReq{
            .topic = topic_id,
            .runner_id = self.runner_id,
            .expected_epoch = expected_epoch,
            .ttl_ms = ttl_ms,
        };
        const enc = req.encode();
        wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_LEASE_ACQUIRE, 0, &enc, self.ioTimeoutMs()) catch |err| {
            self.disconnectRelay();
            return err;
        };

        var resp_frame = try self.readRpcFrame(sock);
        defer resp_frame.deinit(self.allocator);
        if (resp_frame.op == .err) return self.mapRelayErr(resp_frame.payload);
        if (resp_frame.op != wire.RESP_LEASE) return error.BadRelayFrame;

        const lr = try wire.LeaseResponse.decode(resp_frame.payload);
        self.last_lease_response = lr;
        return .{
            .topic_id = topic_id,
            .runner_id = lr.holder_runner_id,
            .fencing_epoch = lr.fencing_epoch,
            .expires_ms = lr.expires_ms,
            .mode = .relay_fenced,
            .lock_fd = null,
            .canceled = lr.canceled,
            .cancel_epoch = lr.cancel_epoch,
            .expires_mono_ms = if (lr.expires_ms == 0) 0 else req_mono +| clamped,
        };
    }

    pub fn isStillValid(self: *const LeaseManager, handle: *const LeaseHandle) bool {
        if (handle.canceled) return false;
        const now_mono = nowAwakeMs(self.io);
        if (handle.expires_mono_ms != 0) {
            if (now_mono >= handle.expires_mono_ms) return false;
        } else {
            const now_ms = id.nowMs(self.io);
            if (now_ms >= handle.expires_ms) return false;
        }
        if (handle.mode == .local_offline) {
            const st = self.local_locks.get(handle.topic_id) orelse return false;
            if (st.fencing_epoch != handle.fencing_epoch or st.canceled or now_mono >= st.expires_mono_ms) return false;
            const disk = self.readLocalEpoch(handle.topic_id) catch return false;
            if (disk.fencing_epoch != handle.fencing_epoch or disk.canceled) return false;
        }
        return true;
    }

    pub fn renew(self: *LeaseManager, handle: *LeaseHandle, ttl_ms: u64) !void {
        switch (handle.mode) {
            .local_offline => {
                const now_ms = id.nowMs(self.io);
                const now_mono = nowAwakeMs(self.io);
                const st = self.local_locks.getPtr(handle.topic_id) orelse return error.Fenced;
                const handle_expired = if (handle.expires_mono_ms != 0) now_mono >= handle.expires_mono_ms else now_ms >= handle.expires_ms;
                if (st.fencing_epoch != handle.fencing_epoch or handle_expired or now_mono >= st.expires_mono_ms) {
                    return error.Fenced;
                }
                const disk = try self.readLocalEpoch(handle.topic_id);
                if (disk.fencing_epoch != handle.fencing_epoch) return error.Fenced;
                if (st.canceled or disk.canceled) {
                    st.canceled = true;
                    handle.canceled = true;
                    handle.cancel_epoch = @max(handle.cancel_epoch, disk.cancel_epoch);
                    return error.LeaseCancelled;
                }
                const clamped = std.math.clamp(ttl_ms, MIN_LEASE_TTL_MS, MAX_LEASE_TTL_MS);
                const new_exp = now_ms +| clamped;
                const new_mono = now_mono +| clamped;
                st.expires_ms = new_exp;
                st.expires_mono_ms = new_mono;
                handle.expires_ms = new_exp;
                handle.expires_mono_ms = new_mono;
            },
            .relay_fenced => {
                const sock = try self.ensureConnected();
                try self.authorizeTopicLocked(sock, handle.topic_id, wire.PERM_LEASE);
                const clamped = std.math.clamp(ttl_ms, MIN_LEASE_TTL_MS, MAX_LEASE_TTL_MS);
                const req_mono = nowAwakeMs(self.io);
                const req = wire.LeaseRenewReq{
                    .topic = handle.topic_id,
                    .runner_id = handle.runner_id,
                    .fencing_epoch = handle.fencing_epoch,
                    .ttl_ms = ttl_ms,
                };
                const enc = req.encode();
                wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_LEASE_RENEW, 0, &enc, self.ioTimeoutMs()) catch |err| {
                    self.disconnectRelay();
                    return err;
                };
                var resp_frame = try self.readRpcFrame(sock);
                defer resp_frame.deinit(self.allocator);
                if (resp_frame.op == .err) {
                    const mapped = self.mapRelayErr(resp_frame.payload);
                    if (mapped == error.LeaseCancelled) handle.canceled = true;
                    return mapped;
                }
                if (resp_frame.op != wire.RESP_LEASE) return error.BadRelayFrame;
                const lr = try wire.LeaseResponse.decode(resp_frame.payload);
                self.last_lease_response = lr;
                handle.expires_ms = lr.expires_ms;
                handle.expires_mono_ms = if (lr.expires_ms == 0) 0 else req_mono +| clamped;
                handle.fencing_epoch = lr.fencing_epoch;
                handle.canceled = lr.canceled;
                handle.cancel_epoch = lr.cancel_epoch;
            },
        }
    }

    pub fn handoff(self: *LeaseManager, handle: *const LeaseHandle, target_runner_id: u128) !wire.LeaseResponse {
        if (handle.mode == .local_offline) return error.OfflineUnsupported;
        const sock = try self.ensureConnected();
        try self.authorizeTopicLocked(sock, handle.topic_id, wire.PERM_LEASE);
        const req = wire.LeaseHandoffReq{
            .topic = handle.topic_id,
            .runner_id = handle.runner_id,
            .fencing_epoch = handle.fencing_epoch,
            .target_runner_id = target_runner_id,
        };
        const enc = req.encode();
        wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_LEASE_HANDOFF, 0, &enc, self.ioTimeoutMs()) catch |err| {
            self.disconnectRelay();
            return err;
        };
        var resp_frame = try self.readRpcFrame(sock);
        defer resp_frame.deinit(self.allocator);
        if (resp_frame.op == .err) return self.mapRelayErr(resp_frame.payload);
        if (resp_frame.op != wire.RESP_LEASE) return error.BadRelayFrame;
        const lr = try wire.LeaseResponse.decode(resp_frame.payload);
        self.last_lease_response = lr;
        return lr;
    }

    pub fn release(self: *LeaseManager, handle: *LeaseHandle) !void {
        switch (handle.mode) {
            .local_offline => {
                const st = self.local_locks.get(handle.topic_id) orelse return error.Fenced;
                if (st.fencing_epoch != handle.fencing_epoch) return error.Fenced;
                _ = linux.flock(st.fd, posix.LOCK.UN);
                _ = linux.close(st.fd);
                _ = self.local_locks.remove(handle.topic_id);
                handle.lock_fd = null;
                handle.expires_ms = 0;
                handle.expires_mono_ms = 0;
            },
            .relay_fenced => {
                const sock = try self.ensureConnected();
                try self.authorizeTopicLocked(sock, handle.topic_id, wire.PERM_LEASE);
                const req = wire.LeaseReleaseReq{
                    .topic = handle.topic_id,
                    .runner_id = handle.runner_id,
                    .fencing_epoch = handle.fencing_epoch,
                };
                const enc = req.encode();
                wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_LEASE_RELEASE, 0, &enc, self.ioTimeoutMs()) catch |err| {
                    self.disconnectRelay();
                    return err;
                };
                var resp_frame = try self.readRpcFrame(sock);
                defer resp_frame.deinit(self.allocator);
                if (resp_frame.op == .err) return self.mapRelayErr(resp_frame.payload);
                if (resp_frame.op != wire.RESP_LEASE) return error.BadRelayFrame;
                const lr = try wire.LeaseResponse.decode(resp_frame.payload);
                self.last_lease_response = lr;
                handle.expires_ms = 0;
                handle.expires_mono_ms = 0;
            },
        }
    }

    pub fn cancelTopic(self: *LeaseManager, topic_id: [32]u8, cancel_epoch: u64) !wire.LeaseResponse {
        if (self.relay_cfg != null) {
            if (self.ensureConnected()) |sock| {
                try self.authorizeTopicLocked(sock, topic_id, wire.PERM_LEASE);
                const req = wire.LeaseCancelReq{
                    .topic = topic_id,
                    .cancel_epoch = cancel_epoch,
                };
                const enc = req.encode();
                wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_LEASE_CANCEL, 0, &enc, self.ioTimeoutMs()) catch |err| {
                    self.disconnectRelay();
                    return err;
                };
                var resp_frame = try self.readRpcFrame(sock);
                defer resp_frame.deinit(self.allocator);
                if (resp_frame.op == .err) return self.mapRelayErr(resp_frame.payload);
                if (resp_frame.op != wire.RESP_LEASE) return error.BadRelayFrame;
                const lr = try wire.LeaseResponse.decode(resp_frame.payload);
                self.last_lease_response = lr;
                return lr;
            } else |err| switch (err) {
                error.ConnectFailed, error.SocketFailed => {},
                else => return err,
            }
        }

        const prev = try self.readLocalEpoch(topic_id);
        const next_cancel = @max(cancel_epoch, prev.cancel_epoch);
        const next_rec = LocalEpochRecord{
            .fencing_epoch = prev.fencing_epoch,
            .canceled = true,
            .cancel_epoch = next_cancel,
        };
        try self.writeLocalEpoch(topic_id, next_rec);
        var holder: u128 = 0;
        var expires: u64 = 0;
        if (self.local_locks.getPtr(topic_id)) |st| {
            st.canceled = true;
            st.cancel_epoch = next_cancel;
            holder = self.runner_id;
            expires = st.expires_ms;
        }
        return .{
            .holder_runner_id = holder,
            .fencing_epoch = next_rec.fencing_epoch,
            .expires_ms = expires,
            .handoff_target = null,
            .canceled = true,
            .cancel_epoch = next_cancel,
        };
    }

    pub fn status(self: *LeaseManager, topic_id: [32]u8) !wire.LeaseResponse {
        if (self.relay_cfg != null) {
            if (self.ensureConnected()) |sock| {
                try self.authorizeTopicLocked(sock, topic_id, wire.PERM_LEASE);
                const req = wire.LeaseStatusReq{ .topic = topic_id };
                const enc = req.encode();
                wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_LEASE_STATUS, 0, &enc, self.ioTimeoutMs()) catch |err| {
                    self.disconnectRelay();
                    return err;
                };
                var resp_frame = try self.readRpcFrame(sock);
                defer resp_frame.deinit(self.allocator);
                if (resp_frame.op == .err) return self.mapRelayErr(resp_frame.payload);
                if (resp_frame.op != wire.RESP_LEASE) return error.BadRelayFrame;
                const lr = try wire.LeaseResponse.decode(resp_frame.payload);
                self.last_lease_response = lr;
                return lr;
            } else |err| switch (err) {
                error.ConnectFailed, error.SocketFailed => {},
                else => return err,
            }
        }

        const rec = try self.readLocalEpoch(topic_id);
        var holder: u128 = 0;
        var expires: u64 = 0;
        if (self.local_locks.get(topic_id)) |st| {
            holder = self.runner_id;
            expires = st.expires_ms;
        }
        return .{
            .holder_runner_id = holder,
            .fencing_epoch = rec.fencing_epoch,
            .expires_ms = expires,
            .handoff_target = null,
            .canceled = rec.canceled,
            .cancel_epoch = rec.cancel_epoch,
        };
    }

    pub fn putFrameFenced(self: *LeaseManager, handle: *const LeaseHandle, opaque_frame: []const u8) !u64 {
        switch (handle.mode) {
            .local_offline => {
                const now_ms = id.nowMs(self.io);
                const now_mono = nowAwakeMs(self.io);
                const st = self.local_locks.get(handle.topic_id) orelse return error.Fenced;
                const handle_expired = if (handle.expires_mono_ms != 0) now_mono >= handle.expires_mono_ms else now_ms >= handle.expires_ms;
                if (st.fencing_epoch != handle.fencing_epoch or handle_expired or now_mono >= st.expires_mono_ms) {
                    return error.Fenced;
                }
                const disk = try self.readLocalEpoch(handle.topic_id);
                if (disk.fencing_epoch != handle.fencing_epoch) return error.Fenced;
                if (st.canceled or disk.canceled) return error.LeaseCancelled;
                return 0;
            },
            .relay_fenced => {
                const sock = try self.ensureConnected();
                try self.authorizeTopicLocked(sock, handle.topic_id, @as(u32, wire.PERM_WRITE) | wire.PERM_LEASE);
                const req = wire.PutFrameFencedReq{
                    .topic = handle.topic_id,
                    .required_epoch = handle.fencing_epoch,
                    .frame = opaque_frame,
                };
                const payload = try req.encode(self.allocator);
                defer self.allocator.free(payload);
                wire.writeFrameWithTimeout(self.allocator, sock, wire.REQ_PUT_FRAME_FENCED, 0, payload, self.ioTimeoutMs()) catch |err| {
                    self.disconnectRelay();
                    return err;
                };
                var resp_frame = try self.readRpcFrame(sock);
                defer resp_frame.deinit(self.allocator);
                if (resp_frame.op == .err) return self.mapRelayErr(resp_frame.payload);
                if (resp_frame.op != .ack or resp_frame.payload.len != 8) return error.BadRelayFrame;
                return std.mem.readInt(u64, resp_frame.payload[0..8], .little);
            },
        }
    }
};
