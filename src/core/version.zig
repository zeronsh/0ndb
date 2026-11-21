const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const codec = @import("../store/codec.zig");

pub const INLINE_CAP: usize = 4;
pub const MAX_VERSION_ENTRIES: usize = 65536;

pub const Version = struct {
    inline_buf: [INLINE_CAP]id.BatchId = undefined,
    heap: ?[]id.BatchId = null,
    len: usize = 0,

    pub const ROOT: Version = .{};

    pub fn single(b: id.BatchId) Version {
        var v = Version{};
        v.inline_buf[0] = b;
        v.len = 1;
        return v;
    }

    pub fn deinit(self: *Version, allocator: Allocator) void {
        if (self.heap) |h| {
            allocator.free(h);
            self.heap = null;
        }
        self.len = 0;
    }

    pub fn clone(self: *const Version, allocator: Allocator) Allocator.Error!Version {
        var out = Version{};
        out.len = self.len;
        if (self.len <= INLINE_CAP) {
            @memcpy(out.inline_buf[0..self.len], self.slice());
        } else {
            const copy = try allocator.alloc(id.BatchId, self.len);
            @memcpy(copy, self.slice());
            out.heap = copy;
        }
        return out;
    }

    pub fn slice(self: *const Version) []const id.BatchId {
        if (self.heap) |h| return h[0..self.len];
        return self.inline_buf[0..self.len];
    }

    fn sliceMut(self: *Version) []id.BatchId {
        if (self.heap) |h| return h[0..self.len];
        return self.inline_buf[0..self.len];
    }

    pub fn isEmpty(self: *const Version) bool {
        return self.len == 0;
    }

    pub fn maxTs(self: *const Version) id.Lamport {
        const s = self.slice();
        if (s.len == 0) return 0;
        return s[s.len - 1].ts;
    }

    pub fn contains(self: *const Version, target: id.BatchId) bool {
        return self.findIndex(target) != null;
    }

    fn findIndex(self: *const Version, target: id.BatchId) ?usize {
        const s = self.slice();
        var lo: usize = 0;
        var hi: usize = s.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (s[mid].order(target)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    fn insertPos(self: *const Version, target: id.BatchId) usize {
        const s = self.slice();
        var lo: usize = 0;
        var hi: usize = s.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s[mid].lessThan(target)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    pub fn insert(self: *Version, allocator: Allocator, b: id.BatchId) Allocator.Error!void {
        const pos = self.insertPos(b);
        if (pos < self.len and self.slice()[pos].eql(b)) return;
        const new_len = self.len + 1;
        if (self.heap) |h| {
            if (new_len <= h.len) {
                std.mem.copyBackwards(id.BatchId, h[pos + 1 .. new_len], h[pos..self.len]);
                h[pos] = b;
                self.len = new_len;
                return;
            }
            const next_cap = @max(h.len * 2, new_len);
            const grown = try allocator.alloc(id.BatchId, next_cap);
            @memcpy(grown[0..pos], h[0..pos]);
            grown[pos] = b;
            @memcpy(grown[pos + 1 .. new_len], h[pos..self.len]);
            allocator.free(h);
            self.heap = grown;
            self.len = new_len;
        } else if (new_len <= INLINE_CAP) {
            std.mem.copyBackwards(id.BatchId, self.inline_buf[pos + 1 .. new_len], self.inline_buf[pos..self.len]);
            self.inline_buf[pos] = b;
            self.len = new_len;
        } else {
            const grown = try allocator.alloc(id.BatchId, INLINE_CAP * 2);
            @memcpy(grown[0..pos], self.inline_buf[0..pos]);
            grown[pos] = b;
            @memcpy(grown[pos + 1 .. new_len], self.inline_buf[pos..self.len]);
            self.heap = grown;
            self.len = new_len;
        }
    }

    pub fn remove(self: *Version, b: id.BatchId) bool {
        const idx = self.findIndex(b) orelse return false;
        const s = self.sliceMut();
        std.mem.copyForwards(id.BatchId, s[idx .. self.len - 1], s[idx + 1 .. self.len]);
        self.len -= 1;
        return true;
    }

    pub fn eql(self: *const Version, other: *const Version) bool {
        const a = self.slice();
        const b = other.slice();
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    pub fn encode(self: *const Version, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        const s = self.slice();
        try w.writeVarint(allocator, s.len);
        for (s) |b| {
            try w.writeU64(allocator, b.ts);
            try w.writeU128(allocator, b.actor);
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!Version {
        const n_u64 = try r.readVarint();
        if (n_u64 > MAX_VERSION_ENTRIES) return error.InvalidData;
        const n: usize = @intCast(n_u64);
        if (n > r.remaining() / 24) return error.UnexpectedEof;
        var v = Version{};
        errdefer v.deinit(allocator);
        for (0..n) |_| {
            const ts = try r.readU64();
            const actor = try r.readU128();
            try v.insert(allocator, id.OpId.init(ts, actor));
        }
        return v;
    }

    pub fn formatHex(self: *const Version, allocator: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.slice(), 0..) |b, i| {
            if (i > 0) try out.append(allocator, ',');
            var ahex: [32]u8 = undefined;
            _ = id.formatIdHex(b.actor, &ahex);
            try out.print(allocator, "{d}:{s}", .{ b.ts, ahex });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn parseHex(allocator: Allocator, raw: []const u8) !Version {
        var v = Version{};
        errdefer v.deinit(allocator);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return v;
        var it = std.mem.splitScalar(u8, trimmed, ',');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidVersion;
            const ts = std.fmt.parseInt(u64, part[0..colon], 10) catch return error.InvalidVersion;
            const actor = id.parseIdHex(part[colon + 1 ..]) catch return error.InvalidVersion;
            try v.insert(allocator, id.OpId.init(ts, actor));
        }
        return v;
    }
};
