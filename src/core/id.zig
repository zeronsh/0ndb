const std = @import("std");
const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [32]u8;
pub const ActorId = u128;
pub const Lamport = u64;
pub const Oid = Hash;
pub const StreamId = Hash;
pub const PageId = Hash;

pub const ZERO_HASH: Hash = @splat(0);

pub fn hashBytes(data: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(data, &out, .{});
    return out;
}

pub const ObjectFormat = enum(u8) {
    sha1 = 20,
    sha256 = 32,

    pub fn byteLen(self: ObjectFormat) usize {
        return @backingInt(self);
    }

    pub fn hexLen(self: ObjectFormat) usize {
        return @as(usize, @backingInt(self)) * 2;
    }
};

pub const GitOid = struct {
    len: u8,
    bytes: [32]u8,

    pub const ZERO: GitOid = .{
        .len = 20,
        .bytes = @splat(0),
    };

    pub fn zeroFor(fmt: ObjectFormat) GitOid {
        return .{
            .len = @backingInt(fmt),
            .bytes = @splat(0),
        };
    }

    pub fn fromSlice(raw: []const u8) error{InvalidOidLength}!GitOid {
        if (raw.len != 20 and raw.len != 32) return error.InvalidOidLength;
        var out: GitOid = .{
            .len = @intCast(raw.len),
            .bytes = @splat(0),
        };
        @memcpy(out.bytes[0..raw.len], raw);
        return out;
    }

    pub fn ofObject(fmt: ObjectFormat, kind_name: []const u8, data: []const u8) GitOid {
        var hdr_buf: [64]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {d}\x00", .{ kind_name, data.len }) catch unreachable;
        var out: GitOid = .{
            .len = @backingInt(fmt),
            .bytes = @splat(0),
        };
        switch (fmt) {
            .sha1 => {
                var h = Sha1.init(.{});
                h.update(hdr);
                h.update(data);
                var digest: [20]u8 = undefined;
                h.final(&digest);
                @memcpy(out.bytes[0..20], &digest);
            },
            .sha256 => {
                var h = Sha256.init(.{});
                h.update(hdr);
                h.update(data);
                var digest: [32]u8 = undefined;
                h.final(&digest);
                @memcpy(out.bytes[0..32], &digest);
            },
        }
        return out;
    }

    pub fn ofBlob(fmt: ObjectFormat, data: []const u8) GitOid {
        return ofObject(fmt, "blob", data);
    }

    pub fn fromHex(hex: []const u8) error{ InvalidHexLength, InvalidHexChar }!GitOid {
        if (hex.len != 40 and hex.len != 64) return error.InvalidHexLength;
        const n = hex.len / 2;
        var out: GitOid = .{
            .len = @intCast(n),
            .bytes = @splat(0),
        };
        for (0..n) |i| {
            const hi = hexNibble(hex[i * 2]) orelse return error.InvalidHexChar;
            const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidHexChar;
            out.bytes[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
        return out;
    }

    pub fn toHex(self: GitOid, buf: *[64]u8) []const u8 {
        const alphabet = "0123456789abcdef";
        const n: usize = self.len;
        for (0..n) |i| {
            const b = self.bytes[i];
            buf[i * 2] = alphabet[b >> 4];
            buf[i * 2 + 1] = alphabet[b & 0x0f];
        }
        return buf[0 .. n * 2];
    }

    pub fn slice(self: *const GitOid) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn isZero(self: GitOid) bool {
        for (self.bytes[0..self.len]) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    pub fn eql(a: GitOid, b: GitOid) bool {
        if (a.len != b.len) return false;
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    pub fn order(a: GitOid, b: GitOid) std.math.Order {
        return std.mem.order(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    pub const hashContext = struct {
        pub fn hash(_: @This(), k: GitOid) u64 {
            const w0 = std.mem.readInt(u64, k.bytes[0..8], .little);
            const w1 = std.mem.readInt(u64, k.bytes[8..16], .little);
            return w0 ^ w1 ^ @as(u64, k.len);
        }

        pub fn eql(_: @This(), a: GitOid, b: GitOid) bool {
            return a.eql(b);
        }
    };
};

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

pub fn isValidHexOid(s: []const u8, expected_fmt: ?ObjectFormat) bool {
    if (expected_fmt) |fmt| {
        if (s.len != fmt.hexLen()) return false;
    } else {
        if (s.len != 40 and s.len != 64) return false;
    }
    for (s) |c| {
        if (hexNibble(c) == null) return false;
    }
    return true;
}

pub const OpId = struct {
    ts: Lamport,
    actor: ActorId,

    pub const ZERO: OpId = .{ .ts = 0, .actor = 0 };

    pub fn init(ts: Lamport, actor: ActorId) OpId {
        return .{ .ts = ts, .actor = actor };
    }

    pub fn eql(self: OpId, other: OpId) bool {
        return self.ts == other.ts and self.actor == other.actor;
    }

    pub fn order(self: OpId, other: OpId) std.math.Order {
        if (self.ts < other.ts) return .lt;
        if (self.ts > other.ts) return .gt;
        if (self.actor < other.actor) return .lt;
        if (self.actor > other.actor) return .gt;
        return .eq;
    }

    pub fn lessThan(self: OpId, other: OpId) bool {
        return self.order(other) == .lt;
    }

    pub fn greaterThan(self: OpId, other: OpId) bool {
        return self.order(other) == .gt;
    }
};

pub const BatchId = OpId;

pub const InodeId = struct {
    op: OpId,
    part: u32,

    pub const ROOT: InodeId = .{ .op = OpId.ZERO, .part = 0 };

    pub fn init(op: OpId, part: u32) InodeId {
        return .{ .op = op, .part = part };
    }

    pub fn isRoot(self: InodeId) bool {
        return self.op.ts == 0 and self.op.actor == 0 and self.part == 0;
    }

    pub fn eql(self: InodeId, other: InodeId) bool {
        return self.op.eql(other.op) and self.part == other.part;
    }

    pub fn order(self: InodeId, other: InodeId) std.math.Order {
        const o = self.op.order(other.op);
        if (o != .eq) return o;
        return std.math.order(self.part, other.part);
    }
};

pub const InsertionKey = struct {
    op: OpId,
    part: u32,

    pub fn eql(self: InsertionKey, other: InsertionKey) bool {
        return self.op.eql(other.op) and self.part == other.part;
    }
};

var id_counter: std.atomic.Value(u32) = .init(0);

pub fn nowMs(io: Io) u64 {
    const ts = Io.Clock.real.now(io);
    const ms = @divFloor(ts.nanoseconds, std.time.ns_per_ms);
    return if (ms < 0) 0 else @intCast(ms);
}

pub fn newUuidV7(io: Io) u128 {
    const ms: u64 = nowMs(io);
    const seq: u32 = id_counter.fetchAdd(1, .monotonic);
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const rand_u64 = std.mem.readInt(u64, &rand_bytes, .little);

    const hi_ts: u128 = @as(u128, ms & 0xFFFF_FFFF_FFFF) << 80;
    const ver: u128 = @as(u128, 0x7) << 76;
    const rand_a: u128 = @as(u128, seq & 0xFFF) << 64;
    const variant: u128 = @as(u128, 0x2) << 62;
    const rand_b: u128 = @as(u128, rand_u64 & 0x3FFF_FFFF_FFFF_FFFF);
    return hi_ts | ver | rand_a | variant | rand_b;
}

pub fn formatIdHex(id: u128, buf: *[32]u8) []const u8 {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, id, .big);
    buf.* = std.fmt.bytesToHex(bytes, .lower);
    return buf[0..32];
}

pub fn formatHashHex(h: Hash, buf: *[64]u8) []const u8 {
    buf.* = std.fmt.bytesToHex(h, .lower);
    return buf[0..64];
}

pub fn formatShortId(id: u128, buf: *[16]u8) []const u8 {
    var full: [32]u8 = undefined;
    _ = formatIdHex(id, &full);
    @memcpy(buf[0..16], full[16..32]);
    return buf[0..16];
}

pub fn parseIdHex(hex: []const u8) !u128 {
    if (hex.len != 32) return error.InvalidId;
    var bytes: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidId;
    return std.mem.readInt(u128, &bytes, .big);
}

pub fn streamId(namespace: []const u8, entity_id: u128) StreamId {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("0ndb-stream-v1:");
    h.update(namespace);
    h.update(":");
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, entity_id, .little);
    h.update(&bytes);
    var out: StreamId = undefined;
    h.final(&out);
    return out;
}

pub fn catalogStreamId(workspace_id: u128) StreamId {
    return streamId("catalog", workspace_id);
}

pub fn threadStreamId(thread_id: u128) StreamId {
    return streamId("thread", thread_id);
}

pub fn worktreeStreamId(history_id: u128) StreamId {
    return streamId("worktree", history_id);
}

pub fn spaceStreamId(space_id: u128) StreamId {
    return streamId("space", space_id);
}
