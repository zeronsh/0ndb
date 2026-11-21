const std = @import("std");
const Io = std.Io;
const crypto = @import("../store/crypto.zig");

pub const ActorId = u128;
pub const Lamport = u64;
pub const Oid = crypto.Hash;
pub const StreamId = crypto.Hash;
pub const PageId = crypto.Hash;

pub const ZERO_HASH: crypto.Hash = @splat(0);

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

pub fn formatHashHex(h: crypto.Hash, buf: *[64]u8) []const u8 {
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
