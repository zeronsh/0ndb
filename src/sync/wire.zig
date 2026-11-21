const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

pub const WIRE_MAGIC = [2]u8{ '0', 'S' };
pub const WIRE_HEADER_LEN: usize = 8;
pub const MAX_FRAME_LEN: usize = 32 * 1024 * 1024;

pub const PERM_READ: u8 = 1;
pub const PERM_WRITE: u8 = 2;
pub const PERM_SUB: u8 = 4;
pub const PERM_ALL: u8 = PERM_READ | PERM_WRITE | PERM_SUB;

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
};

pub const ErrCode = enum(u8) {
    unauthorized = 1,
    bad_frame = 2,
    not_found = 3,
    internal = 4,
};

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

pub fn encodeFrame(allocator: Allocator, op: Op, flags: u8, payload: []const u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, WIRE_HEADER_LEN + payload.len);
    out[0] = WIRE_MAGIC[0];
    out[1] = WIRE_MAGIC[1];
    out[2] = @intFromEnum(op);
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

pub fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
            _ = linux.poll(&pfd, 1, -1);
            continue;
        }
        if (e != .SUCCESS or rc == 0) return error.ConnectionClosed;
        off += rc;
    }
}

pub fn readExactFd(fd: posix.fd_t, out: []u8) !void {
    var off: usize = 0;
    while (off < out.len) {
        const rc = linux.read(fd, out[off..].ptr, out.len - off);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, -1);
            continue;
        }
        if (e != .SUCCESS or rc == 0) return error.ConnectionClosed;
        off += rc;
    }
}

pub fn readFrameBlocking(allocator: Allocator, fd: posix.fd_t) !WireFrame {
    var hdr_buf: [WIRE_HEADER_LEN]u8 = undefined;
    try readExactFd(fd, &hdr_buf);
    const hdr = (try decodeHeader(&hdr_buf)) orelse return error.InvalidHeader;
    const payload = try allocator.alloc(u8, hdr.len);
    errdefer allocator.free(payload);
    if (hdr.len > 0) try readExactFd(fd, payload);
    return .{ .op = hdr.op, .flags = hdr.flags, .payload = payload };
}

pub fn writeFrameBlocking(allocator: Allocator, fd: posix.fd_t, op: Op, flags: u8, payload: []const u8) !void {
    const raw = try encodeFrame(allocator, op, flags, payload);
    defer allocator.free(raw);
    try writeAllFd(fd, raw);
}

pub fn setNonBlocking(fd: posix.fd_t) !void {
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags_rc) != .SUCCESS) return error.FcntlFailed;
    const new_flags = flags_rc | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    const set_rc = linux.fcntl(fd, linux.F.SETFL, new_flags);
    if (linux.errno(set_rc) != .SUCCESS) return error.FcntlFailed;
}
