const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

pub const WIRE_MAGIC = [2]u8{ '0', 'S' };
pub const WIRE_HEADER_LEN: usize = 8;
pub const MAX_FRAME_LEN: usize = 32 * 1024 * 1024;
pub const DEFAULT_IO_TIMEOUT_MS: i32 = 30_000;

pub const RANGE_FLAG_HAS_MORE: u8 = 1;

pub const PERM_READ: u8 = 1;
pub const PERM_WRITE: u8 = 2;
pub const PERM_SUB: u8 = 4;
pub const PERM_ALL: u8 = PERM_READ | PERM_WRITE | PERM_SUB;

pub const PERM_INBOX_APPEND: u32 = 1 << 4;
pub const PERM_LEASE: u32 = 1 << 5;
pub const PERM_ALL_V3: u32 = @as(u32, PERM_ALL) | PERM_INBOX_APPEND | PERM_LEASE;

pub const Op = enum(u8) {
    auth = 1,
    put_frame = 2,
    get_range = 3,
    subscribe = 4,
    put_blob = 5,
    get_blob = 6,
    frame_event = 7,
    blob_data = 8,
    ack = 9,
    err = 10,
    range_end = 11,
    range_item = 12,
    lease_acquire = 13,
    lease_renew = 14,
    lease_handoff = 15,
    lease_release = 16,
    lease_cancel = 17,
    lease_status = 18,
    put_frame_fenced = 19,
    lease_resp = 20,
    lease_cancel_event = 21,
};

pub const REQ_LEASE_ACQUIRE: Op = .lease_acquire;
pub const REQ_LEASE_RENEW: Op = .lease_renew;
pub const REQ_LEASE_HANDOFF: Op = .lease_handoff;
pub const REQ_LEASE_RELEASE: Op = .lease_release;
pub const REQ_LEASE_CANCEL: Op = .lease_cancel;
pub const REQ_LEASE_STATUS: Op = .lease_status;
pub const REQ_PUT_FRAME_FENCED: Op = .put_frame_fenced;
pub const RESP_LEASE: Op = .lease_resp;
pub const EVENT_LEASE_CANCEL: Op = .lease_cancel_event;

pub const ErrCode = enum(u8) {
    unauthorized = 1,
    bad_frame = 2,
    not_found = 3,
    internal = 4,
    fenced = 5,
    lease_held = 6,
    cancelled = 7,
};

pub const ERR_FENCED: ErrCode = .fenced;
pub const ERR_LEASE_HELD: ErrCode = .lease_held;
pub const ERR_CANCELLED: ErrCode = .cancelled;

pub const WireHeader = struct {
    op: Op,
    flags: u8,
    len: u32,
};

pub const WireFrame = struct {
    op: Op,
    flags: u8,
    payload: []u8,

    pub fn deinit(self: *WireFrame, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

pub const ErrPayload = struct {
    code: ErrCode,
    body: []const u8,
};

pub fn decodeErrPayload(payload: []const u8) !ErrPayload {
    if (payload.len < 1) return error.BadFrame;
    const code = std.enums.fromInt(ErrCode, payload[0]) orelse return error.BadFrame;
    return .{ .code = code, .body = payload[1..] };
}

pub const AUTH_V3_LEN: usize = 32 + 4 + 8 + 32;

pub fn encodeAuthV3(topic: [32]u8, perms: u32, expires_ms: u64, mac: [32]u8) [AUTH_V3_LEN]u8 {
    var out: [AUTH_V3_LEN]u8 = undefined;
    @memcpy(out[0..32], &topic);
    std.mem.writeInt(u32, out[32..36], perms, .little);
    std.mem.writeInt(u64, out[36..44], expires_ms, .little);
    @memcpy(out[44..76], &mac);
    return out;
}

pub const LeaseAcquireReq = struct {
    topic: [32]u8,
    runner_id: u128,
    expected_epoch: u64,
    ttl_ms: u64,

    pub const ENCODED_LEN: usize = 32 + 16 + 8 + 8;

    pub fn encode(self: LeaseAcquireReq) [ENCODED_LEN]u8 {
        var out: [ENCODED_LEN]u8 = undefined;
        @memcpy(out[0..32], &self.topic);
        std.mem.writeInt(u128, out[32..48], self.runner_id, .little);
        std.mem.writeInt(u64, out[48..56], self.expected_epoch, .little);
        std.mem.writeInt(u64, out[56..64], self.ttl_ms, .little);
        return out;
    }

    pub fn decode(data: []const u8) !LeaseAcquireReq {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        return .{
            .topic = data[0..32].*,
            .runner_id = std.mem.readInt(u128, data[32..48], .little),
            .expected_epoch = std.mem.readInt(u64, data[48..56], .little),
            .ttl_ms = std.mem.readInt(u64, data[56..64], .little),
        };
    }
};

pub const LeaseRenewReq = struct {
    topic: [32]u8,
    runner_id: u128,
    fencing_epoch: u64,
    ttl_ms: u64,

    pub const ENCODED_LEN: usize = 32 + 16 + 8 + 8;

    pub fn encode(self: LeaseRenewReq) [ENCODED_LEN]u8 {
        var out: [ENCODED_LEN]u8 = undefined;
        @memcpy(out[0..32], &self.topic);
        std.mem.writeInt(u128, out[32..48], self.runner_id, .little);
        std.mem.writeInt(u64, out[48..56], self.fencing_epoch, .little);
        std.mem.writeInt(u64, out[56..64], self.ttl_ms, .little);
        return out;
    }

    pub fn decode(data: []const u8) !LeaseRenewReq {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        return .{
            .topic = data[0..32].*,
            .runner_id = std.mem.readInt(u128, data[32..48], .little),
            .fencing_epoch = std.mem.readInt(u64, data[48..56], .little),
            .ttl_ms = std.mem.readInt(u64, data[56..64], .little),
        };
    }
};

pub const LeaseHandoffReq = struct {
    topic: [32]u8,
    runner_id: u128,
    fencing_epoch: u64,
    target_runner_id: u128,

    pub const ENCODED_LEN: usize = 32 + 16 + 8 + 16;

    pub fn encode(self: LeaseHandoffReq) [ENCODED_LEN]u8 {
        var out: [ENCODED_LEN]u8 = undefined;
        @memcpy(out[0..32], &self.topic);
        std.mem.writeInt(u128, out[32..48], self.runner_id, .little);
        std.mem.writeInt(u64, out[48..56], self.fencing_epoch, .little);
        std.mem.writeInt(u128, out[56..72], self.target_runner_id, .little);
        return out;
    }

    pub fn decode(data: []const u8) !LeaseHandoffReq {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        return .{
            .topic = data[0..32].*,
            .runner_id = std.mem.readInt(u128, data[32..48], .little),
            .fencing_epoch = std.mem.readInt(u64, data[48..56], .little),
            .target_runner_id = std.mem.readInt(u128, data[56..72], .little),
        };
    }
};

pub const LeaseReleaseReq = struct {
    topic: [32]u8,
    runner_id: u128,
    fencing_epoch: u64,

    pub const ENCODED_LEN: usize = 32 + 16 + 8;

    pub fn encode(self: LeaseReleaseReq) [ENCODED_LEN]u8 {
        var out: [ENCODED_LEN]u8 = undefined;
        @memcpy(out[0..32], &self.topic);
        std.mem.writeInt(u128, out[32..48], self.runner_id, .little);
        std.mem.writeInt(u64, out[48..56], self.fencing_epoch, .little);
        return out;
    }

    pub fn decode(data: []const u8) !LeaseReleaseReq {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        return .{
            .topic = data[0..32].*,
            .runner_id = std.mem.readInt(u128, data[32..48], .little),
            .fencing_epoch = std.mem.readInt(u64, data[48..56], .little),
        };
    }
};

pub const LeaseCancelReq = struct {
    topic: [32]u8,
    cancel_epoch: u64,

    pub const ENCODED_LEN: usize = 32 + 8;

    pub fn encode(self: LeaseCancelReq) [ENCODED_LEN]u8 {
        var out: [ENCODED_LEN]u8 = undefined;
        @memcpy(out[0..32], &self.topic);
        std.mem.writeInt(u64, out[32..40], self.cancel_epoch, .little);
        return out;
    }

    pub fn decode(data: []const u8) !LeaseCancelReq {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        return .{
            .topic = data[0..32].*,
            .cancel_epoch = std.mem.readInt(u64, data[32..40], .little),
        };
    }
};

pub const LeaseStatusReq = struct {
    topic: [32]u8,

    pub const ENCODED_LEN: usize = 32;

    pub fn encode(self: LeaseStatusReq) [ENCODED_LEN]u8 {
        return self.topic;
    }

    pub fn decode(data: []const u8) !LeaseStatusReq {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        return .{ .topic = data[0..32].* };
    }
};

pub const LeaseResponse = struct {
    holder_runner_id: u128 = 0,
    fencing_epoch: u64 = 0,
    expires_ms: u64 = 0,
    handoff_target: ?u128 = null,
    canceled: bool = false,
    cancel_epoch: u64 = 0,

    pub const ENCODED_LEN: usize = 16 + 8 + 8 + 1 + 16 + 1 + 8;

    pub fn encode(self: LeaseResponse) [ENCODED_LEN]u8 {
        var out: [ENCODED_LEN]u8 = undefined;
        std.mem.writeInt(u128, out[0..16], self.holder_runner_id, .little);
        std.mem.writeInt(u64, out[16..24], self.fencing_epoch, .little);
        std.mem.writeInt(u64, out[24..32], self.expires_ms, .little);
        if (self.handoff_target) |target| {
            out[32] = 1;
            std.mem.writeInt(u128, out[33..49], target, .little);
        } else {
            out[32] = 0;
            std.mem.writeInt(u128, out[33..49], 0, .little);
        }
        out[49] = if (self.canceled) 1 else 0;
        std.mem.writeInt(u64, out[50..58], self.cancel_epoch, .little);
        return out;
    }

    pub fn decode(data: []const u8) !LeaseResponse {
        if (data.len != ENCODED_LEN) return error.BadFrame;
        const has_handoff = data[32];
        if (has_handoff > 1) return error.BadFrame;
        const canceled_byte = data[49];
        if (canceled_byte > 1) return error.BadFrame;
        const target_val = std.mem.readInt(u128, data[33..49], .little);
        return .{
            .holder_runner_id = std.mem.readInt(u128, data[0..16], .little),
            .fencing_epoch = std.mem.readInt(u64, data[16..24], .little),
            .expires_ms = std.mem.readInt(u64, data[24..32], .little),
            .handoff_target = if (has_handoff == 1) target_val else null,
            .canceled = canceled_byte == 1,
            .cancel_epoch = std.mem.readInt(u64, data[50..58], .little),
        };
    }
};

pub const PutFrameFencedReq = struct {
    topic: [32]u8,
    required_epoch: u64,
    frame: []const u8,

    pub const HEADER_LEN: usize = 32 + 8;

    pub fn encode(self: PutFrameFencedReq, allocator: Allocator) Allocator.Error![]u8 {
        const out = try allocator.alloc(u8, HEADER_LEN + self.frame.len);
        @memcpy(out[0..32], &self.topic);
        std.mem.writeInt(u64, out[32..40], self.required_epoch, .little);
        if (self.frame.len > 0) @memcpy(out[40..], self.frame);
        return out;
    }

    pub fn decode(data: []const u8) !PutFrameFencedReq {
        if (data.len < HEADER_LEN) return error.BadFrame;
        return .{
            .topic = data[0..32].*,
            .required_epoch = std.mem.readInt(u64, data[32..40], .little),
            .frame = data[40..],
        };
    }
};

fn monotonicMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * 1000 + nsec / 1_000_000;
}

fn waitFdReady(fd: posix.fd_t, events: i16, deadline_ms: u64) !void {
    while (true) {
        const now = monotonicMs();
        if (now >= deadline_ms) return error.Timeout;
        const rem_u64 = deadline_ms - now;
        const rem_i32: i32 = @intCast(@min(rem_u64, @as(u64, std.math.maxInt(i32))));
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const prc = linux.poll(&pfd, 1, rem_i32);
        const pe = linux.errno(prc);
        if (pe == .INTR) continue;
        if (pe != .SUCCESS) return error.ConnectionClosed;
        if (prc == 0) return error.Timeout;
        if ((pfd[0].revents & linux.POLL.NVAL) != 0) return error.ConnectionClosed;
        return;
    }
}

pub fn setSocketTimeouts(fd: posix.fd_t, timeout_ms: u32) !void {
    const tv = linux.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const rrc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    if (linux.errno(rrc) != .SUCCESS) return error.SetSockOptFailed;
    const src = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    if (linux.errno(src) != .SUCCESS) return error.SetSockOptFailed;
}

pub fn encodeFrame(allocator: Allocator, op: Op, flags: u8, payload: []const u8) (Allocator.Error || error{FrameTooLarge})![]u8 {
    if (payload.len > MAX_FRAME_LEN) return error.FrameTooLarge;
    const out = try allocator.alloc(u8, WIRE_HEADER_LEN + payload.len);
    out[0] = WIRE_MAGIC[0];
    out[1] = WIRE_MAGIC[1];
    out[2] = @backingInt(op);
    out[3] = flags;
    std.mem.writeInt(u32, out[4..8], @intCast(payload.len), .little);
    if (payload.len > 0) @memcpy(out[WIRE_HEADER_LEN..], payload);
    return out;
}

pub fn decodeHeader(buf: []const u8) !?WireHeader {
    if (buf.len < WIRE_HEADER_LEN) return null;
    if (buf[0] != WIRE_MAGIC[0] or buf[1] != WIRE_MAGIC[1]) return error.InvalidMagic;
    const op = std.enums.fromInt(Op, buf[2]) orelse return error.InvalidOp;
    const flags = buf[3];
    const len = std.mem.readInt(u32, buf[4..8], .little);
    if (len > MAX_FRAME_LEN) return error.FrameTooLarge;
    return .{ .op = op, .flags = flags, .len = len };
}

pub fn writeAllFdTimeout(fd: posix.fd_t, data: []const u8, timeout_ms: i32) !void {
    const budget: u64 = if (timeout_ms <= 0) 1 else @intCast(timeout_ms);
    const deadline = monotonicMs() +| budget;
    var off: usize = 0;
    while (off < data.len) {
        try waitFdReady(fd, linux.POLL.OUT, deadline);
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
        const e = linux.errno(rc);
        if (e == .INTR or e == .AGAIN) continue;
        if (e != .SUCCESS or rc == 0) return error.ConnectionClosed;
        off += rc;
    }
}

pub fn readExactFdTimeout(fd: posix.fd_t, out: []u8, timeout_ms: i32) !void {
    const budget: u64 = if (timeout_ms <= 0) 1 else @intCast(timeout_ms);
    const deadline = monotonicMs() +| budget;
    var off: usize = 0;
    while (off < out.len) {
        try waitFdReady(fd, linux.POLL.IN, deadline);
        const rc = linux.read(fd, out[off..].ptr, out.len - off);
        const e = linux.errno(rc);
        if (e == .INTR or e == .AGAIN) continue;
        if (e != .SUCCESS or rc == 0) return error.ConnectionClosed;
        off += rc;
    }
}

pub fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
    return writeAllFdTimeout(fd, data, DEFAULT_IO_TIMEOUT_MS);
}

pub fn readExactFd(fd: posix.fd_t, out: []u8) !void {
    return readExactFdTimeout(fd, out, DEFAULT_IO_TIMEOUT_MS);
}

pub fn readFrameWithTimeout(allocator: Allocator, fd: posix.fd_t, timeout_ms: i32) !WireFrame {
    var hdr_buf: [WIRE_HEADER_LEN]u8 = undefined;
    try readExactFdTimeout(fd, &hdr_buf, timeout_ms);
    const hdr = (try decodeHeader(&hdr_buf)) orelse return error.InvalidHeader;
    const payload = try allocator.alloc(u8, hdr.len);
    errdefer allocator.free(payload);
    if (hdr.len > 0) try readExactFdTimeout(fd, payload, timeout_ms);
    return .{ .op = hdr.op, .flags = hdr.flags, .payload = payload };
}

pub fn writeFrameWithTimeout(allocator: Allocator, fd: posix.fd_t, op: Op, flags: u8, payload: []const u8, timeout_ms: i32) !void {
    const raw = try encodeFrame(allocator, op, flags, payload);
    defer allocator.free(raw);
    try writeAllFdTimeout(fd, raw, timeout_ms);
}

pub fn readFrameBlocking(allocator: Allocator, fd: posix.fd_t) !WireFrame {
    return readFrameWithTimeout(allocator, fd, DEFAULT_IO_TIMEOUT_MS);
}

pub fn writeFrameBlocking(allocator: Allocator, fd: posix.fd_t, op: Op, flags: u8, payload: []const u8) !void {
    return writeFrameWithTimeout(allocator, fd, op, flags, payload, DEFAULT_IO_TIMEOUT_MS);
}

pub fn setNonBlocking(fd: posix.fd_t) !void {
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags_rc) != .SUCCESS) return error.FcntlFailed;
    const new_flags = flags_rc | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    const set_rc = linux.fcntl(fd, linux.F.SETFL, new_flags);
    if (linux.errno(set_rc) != .SUCCESS) return error.FcntlFailed;
}
