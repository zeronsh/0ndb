const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const codec = @import("../store/codec.zig");
const vcs = @import("../fs/vcs.zig");
const iface = @import("../providers/interface.zig");

pub const MAX_SHORT_STR: usize = 4 * 1024;
pub const MAX_CONTENT_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_VERSION_HEADS: usize = 4096;
pub const MAX_BINDINGS: usize = 256;
pub const MAX_CHECKPOINTS: usize = 256;
pub const MAX_DEPS: usize = 1024;
pub const MAX_PAGE_MESSAGES: usize = 4096;
pub const PAGE_SIZE: usize = 32;
pub const PAGE_MAGIC: [4]u8 = .{ '0', 'T', 'P', '2' };
pub const PAGE_FORMAT_VERSION: u8 = 1;
pub const EVENT_FORMAT_VERSION: u8 = 1;
pub const CATALOG_FORMAT_VERSION: u8 = 1;

pub const Role = enum(u8) {
    user = 1,
    assistant = 2,
    system = 3,
    steer = 4,
};

pub const MessageStatus = enum(u8) {
    pending = 1,
    running = 2,
    completed = 3,
    interrupted = 4,
    failed = 5,
};

pub const SessionStatus = enum(u8) {
    idle = 0,
    running = 1,
    queued = 2,
    steering = 3,
    interrupted = 4,
    failed = 5,
};

pub const QueueKind = enum(u8) {
    follow_up = 1,
    steer = 2,
};

pub const QueueStatus = enum(u8) {
    pending = 1,
    dispatching = 2,
    injected = 3,
    completed = 4,
    cancelled = 5,
};

pub const SpaceKind = enum(u8) {
    virtual = 0,
    dir = 1,
    git_worktree = 2,
};

pub const SpaceAccess = enum(u8) {
    read_only = 0,
    shared_rw = 1,
    isolated_fork = 2,

    pub fn allowsChild(self: SpaceAccess, child: SpaceAccess) bool {
        return switch (self) {
            .read_only => child == .read_only,
            .isolated_fork => child == .read_only or child == .isolated_fork,
            .shared_rw => true,
        };
    }
};

pub const GrantError = error{
    UnauthorizedSpaceGrant,
    AccessEscalation,
};

pub fn validateGrantAttenuation(parent_bindings: []const SpaceBinding, child_grants: []const SpaceBinding) GrantError!void {
    for (child_grants) |cg| {
        var found: ?SpaceAccess = null;
        for (parent_bindings) |pb| {
            if (pb.space_id == cg.space_id) {
                found = pb.access;
                break;
            }
        }
        const parent_access = found orelse return error.UnauthorizedSpaceGrant;
        if (!parent_access.allowsChild(cg.access)) {
            return error.AccessEscalation;
        }
    }
}

fn decodeEnum(comptime T: type, r: *codec.Reader) !T {
    const raw = try r.readU8();
    return std.enums.fromInt(T, raw) orelse return error.CorruptRecord;
}

pub fn decodeFlag(r: *codec.Reader) !bool {
    const raw = try r.readU8();
    return switch (raw) {
        0 => false,
        1 => true,
        else => error.CorruptRecord,
    };
}

fn readBytesCapped(r: *codec.Reader, max_len: usize) ![]const u8 {
    const len_u64 = try r.readVarint();
    if (len_u64 > max_len or len_u64 > r.remaining()) return error.CorruptRecord;
    const len: usize = @intCast(len_u64);
    const out = r.data[r.pos .. r.pos + len];
    r.pos += len;
    return out;
}

fn readOptBytesAllocCapped(allocator: Allocator, r: *codec.Reader, max_len: usize) !?[]u8 {
    if (!try decodeFlag(r)) return null;
    return try allocator.dupe(u8, try readBytesCapped(r, max_len));
}

pub fn decodeVersionChecked(allocator: Allocator, r: *codec.Reader) !Version {
    const n = r.readCount(24, MAX_VERSION_HEADS) catch return error.CorruptRecord;
    var v = Version{};
    errdefer v.deinit(allocator);
    for (0..n) |_| {
        const ts = try r.readU64();
        const actor = try r.readU128();
        try v.insert(allocator, id.OpId.init(ts, actor));
    }
    return v;
}

pub const SpaceBinding = struct {
    space_id: u128,
    alias: []u8,
    access: SpaceAccess,
    mount_rel: ?[]u8 = null,

    pub fn deinit(self: *SpaceBinding, allocator: Allocator) void {
        if (self.alias.len > 0) allocator.free(self.alias);
        if (self.mount_rel) |m| allocator.free(m);
        self.alias = &.{};
        self.mount_rel = null;
    }

    pub fn clone(self: *const SpaceBinding, allocator: Allocator) Allocator.Error!SpaceBinding {
        const alias: []u8 = if (self.alias.len > 0) try allocator.dupe(u8, self.alias) else &.{};
        errdefer if (alias.len > 0) allocator.free(alias);
        const mount_rel = if (self.mount_rel) |m| try allocator.dupe(u8, m) else null;
        return .{
            .space_id = self.space_id,
            .alias = alias,
            .access = self.access,
            .mount_rel = mount_rel,
        };
    }

    pub fn encode(self: *const SpaceBinding, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.space_id);
        try w.writeBytes(allocator, self.alias);
        try w.writeU8(allocator, @intFromEnum(self.access));
        try w.writeOptBytes(allocator, self.mount_rel);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !SpaceBinding {
        const space_id = try r.readU128();
        const raw_alias = try readBytesCapped(r, MAX_SHORT_STR);
        const alias: []u8 = if (raw_alias.len > 0) try allocator.dupe(u8, raw_alias) else &.{};
        errdefer if (alias.len > 0) allocator.free(alias);
        const access = try decodeEnum(SpaceAccess, r);
        const mount_rel = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        return .{
            .space_id = space_id,
            .alias = alias,
            .access = access,
            .mount_rel = mount_rel,
        };
    }
};

pub fn computeBindingsDigest(bindings: []const SpaceBinding) [32]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("0ndb-bindings-v1:");
    const n = @min(bindings.len, MAX_BINDINGS);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, n, .little);
    h.update(&len_buf);

    var order: [MAX_BINDINGS]usize = undefined;
    for (0..n) |i| order[i] = i;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = order[i];
        var j = i;
        while (j > 0 and bindings[order[j - 1]].space_id > bindings[key].space_id) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = key;
    }

    for (order[0..n]) |idx| {
        const b = bindings[idx];
        var sid: [16]u8 = undefined;
        std.mem.writeInt(u128, &sid, b.space_id, .little);
        h.update(&sid);
        std.mem.writeInt(u64, &len_buf, b.alias.len, .little);
        h.update(&len_buf);
        h.update(b.alias);
        h.update(&[_]u8{@intFromEnum(b.access)});
        if (b.mount_rel) |mr| {
            h.update(&[_]u8{1});
            std.mem.writeInt(u64, &len_buf, mr.len, .little);
            h.update(&len_buf);
            h.update(mr);
        } else {
            h.update(&[_]u8{0});
        }
    }

    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub const SpaceCheckpoint = struct {
    space_id: u128,
    version: Version = .{},
    vcs_kind: vcs.VcsKind = .none,
    vcs_ref: ?[]u8 = null,
    vcs_rev: ?[]u8 = null,

    pub fn deinit(self: *SpaceCheckpoint, allocator: Allocator) void {
        self.version.deinit(allocator);
        if (self.vcs_ref) |r| allocator.free(r);
        if (self.vcs_rev) |v| allocator.free(v);
        self.vcs_ref = null;
        self.vcs_rev = null;
    }

    pub fn clone(self: *const SpaceCheckpoint, allocator: Allocator) Allocator.Error!SpaceCheckpoint {
        var ver = try self.version.clone(allocator);
        errdefer ver.deinit(allocator);
        const ref_copy = if (self.vcs_ref) |r| try allocator.dupe(u8, r) else null;
        errdefer if (ref_copy) |r| allocator.free(r);
        const rev_copy = if (self.vcs_rev) |v| try allocator.dupe(u8, v) else null;
        return .{
            .space_id = self.space_id,
            .version = ver,
            .vcs_kind = self.vcs_kind,
            .vcs_ref = ref_copy,
            .vcs_rev = rev_copy,
        };
    }

    pub fn eql(self: *const SpaceCheckpoint, other: *const SpaceCheckpoint) bool {
        if (self.space_id != other.space_id) return false;
        if (!self.version.eql(&other.version)) return false;
        if (self.vcs_kind != other.vcs_kind) return false;
        if (!optSliceEql(self.vcs_ref, other.vcs_ref)) return false;
        if (!optSliceEql(self.vcs_rev, other.vcs_rev)) return false;
        return true;
    }

    pub fn encode(self: *const SpaceCheckpoint, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.space_id);
        try self.version.encode(allocator, w);
        try w.writeU8(allocator, @intFromEnum(self.vcs_kind));
        try w.writeOptBytes(allocator, self.vcs_ref);
        try w.writeOptBytes(allocator, self.vcs_rev);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !SpaceCheckpoint {
        const space_id = try r.readU128();
        var ver = try decodeVersionChecked(allocator, r);
        errdefer ver.deinit(allocator);
        const vcs_kind = try decodeEnum(vcs.VcsKind, r);
        const vcs_ref = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (vcs_ref) |x| allocator.free(x);
        const vcs_rev = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        return .{
            .space_id = space_id,
            .version = ver,
            .vcs_kind = vcs_kind,
            .vcs_ref = vcs_ref,
            .vcs_rev = vcs_rev,
        };
    }
};

fn optSliceEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const CheckpointVector = struct {
    entries: []SpaceCheckpoint = &.{},

    pub fn deinit(self: *CheckpointVector, allocator: Allocator) void {
        if (self.entries.len > 0) {
            for (self.entries) |*e| e.deinit(allocator);
            allocator.free(self.entries);
            self.entries = &.{};
        }
    }

    pub fn isEmpty(self: *const CheckpointVector) bool {
        return self.entries.len == 0;
    }

    pub fn clone(self: *const CheckpointVector, allocator: Allocator) Allocator.Error!CheckpointVector {
        if (self.entries.len == 0) return .{ .entries = &.{} };
        const out = try allocator.alloc(SpaceCheckpoint, self.entries.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*e| e.deinit(allocator);
            allocator.free(out);
        }
        for (self.entries, 0..) |*e, i| {
            out[i] = try e.clone(allocator);
            built += 1;
        }
        return .{ .entries = out };
    }

    pub fn findSpace(self: *const CheckpointVector, space_id: u128) ?*const SpaceCheckpoint {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const cur = self.entries[mid].space_id;
            if (cur < space_id) {
                lo = mid + 1;
            } else if (cur > space_id) {
                hi = mid;
            } else {
                return &self.entries[mid];
            }
        }
        return null;
    }

    pub fn setSpace(self: *CheckpointVector, allocator: Allocator, cp: SpaceCheckpoint) Allocator.Error!void {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const cur = self.entries[mid].space_id;
            if (cur < cp.space_id) {
                lo = mid + 1;
            } else if (cur > cp.space_id) {
                hi = mid;
            } else {
                var cloned = try cp.clone(allocator);
                errdefer cloned.deinit(allocator);
                self.entries[mid].deinit(allocator);
                self.entries[mid] = cloned;
                return;
            }
        }

        var cloned = try cp.clone(allocator);
        errdefer cloned.deinit(allocator);

        const next = try allocator.alloc(SpaceCheckpoint, self.entries.len + 1);
        @memcpy(next[0..lo], self.entries[0..lo]);
        next[lo] = cloned;
        @memcpy(next[lo + 1 ..], self.entries[lo..]);
        if (self.entries.len > 0) allocator.free(self.entries);
        self.entries = next;
    }

    pub fn eql(self: *const CheckpointVector, other: *const CheckpointVector) bool {
        if (self.entries.len != other.entries.len) return false;
        for (self.entries, other.entries) |*a, *b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn digest(self: *const CheckpointVector) [32]u8 {
        var h = std.crypto.hash.Blake3.init(.{});
        h.update("0ndb-cpvec-v1:");
        var u64_buf: [8]u8 = undefined;
        var u128_buf: [16]u8 = undefined;
        std.mem.writeInt(u64, &u64_buf, self.entries.len, .little);
        h.update(&u64_buf);
        for (self.entries) |*e| {
            std.mem.writeInt(u128, &u128_buf, e.space_id, .little);
            h.update(&u128_buf);
            const vs = e.version.slice();
            std.mem.writeInt(u64, &u64_buf, vs.len, .little);
            h.update(&u64_buf);
            for (vs) |b| {
                std.mem.writeInt(u64, &u64_buf, b.ts, .little);
                h.update(&u64_buf);
                std.mem.writeInt(u128, &u128_buf, b.actor, .little);
                h.update(&u128_buf);
            }
            h.update(&[_]u8{@intFromEnum(e.vcs_kind)});
            if (e.vcs_ref) |r| {
                h.update(&[_]u8{1});
                std.mem.writeInt(u64, &u64_buf, r.len, .little);
                h.update(&u64_buf);
                h.update(r);
            } else {
                h.update(&[_]u8{0});
            }
            if (e.vcs_rev) |v| {
                h.update(&[_]u8{1});
                std.mem.writeInt(u64, &u64_buf, v.len, .little);
                h.update(&u64_buf);
                h.update(v);
            } else {
                h.update(&[_]u8{0});
            }
        }
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    pub fn encode(self: *const CheckpointVector, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeVarint(allocator, self.entries.len);
        for (self.entries) |*e| {
            try e.encode(allocator, w);
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !CheckpointVector {
        const count = r.readCount(20, MAX_CHECKPOINTS) catch return error.CorruptRecord;
        if (count == 0) return .{ .entries = &.{} };
        const entries = try allocator.alloc(SpaceCheckpoint, count);
        var decoded: usize = 0;
        errdefer {
            for (entries[0..decoded]) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (0..count) |i| {
            entries[i] = try SpaceCheckpoint.decode(allocator, r);
            decoded += 1;
            if (i > 0 and entries[i].space_id <= entries[i - 1].space_id) {
                return error.CorruptRecord;
            }
        }
        return .{ .entries = entries };
    }
};

pub const CursorScope = enum(u8) {
    local_process = 0,
    cloud_hosted = 1,
};

pub const ProviderCursor = struct {
    provider: iface.ProviderId,
    runner_id: u128,
    scope: CursorScope,
    native_session: []u8,
    native_turn: ?[]u8 = null,
    bindings_digest: [32]u8,

    pub fn deinit(self: *ProviderCursor, allocator: Allocator) void {
        if (self.native_session.len > 0) allocator.free(self.native_session);
        if (self.native_turn) |t| allocator.free(t);
        self.native_session = &.{};
        self.native_turn = null;
    }

    pub fn clone(self: *const ProviderCursor, allocator: Allocator) Allocator.Error!ProviderCursor {
        const ns: []u8 = if (self.native_session.len > 0) try allocator.dupe(u8, self.native_session) else &.{};
        errdefer if (ns.len > 0) allocator.free(ns);
        const nt = if (self.native_turn) |t| try allocator.dupe(u8, t) else null;
        return .{
            .provider = self.provider,
            .runner_id = self.runner_id,
            .scope = self.scope,
            .native_session = ns,
            .native_turn = nt,
            .bindings_digest = self.bindings_digest,
        };
    }

    pub fn canResumeNatively(
        self: *const ProviderCursor,
        target_provider: iface.ProviderId,
        local_runner_id: u128,
        current_bindings_digest: [32]u8,
    ) bool {
        if (self.provider != target_provider) return false;
        if (self.native_session.len == 0) return false;
        if (!std.mem.eql(u8, &self.bindings_digest, &current_bindings_digest)) return false;
        return switch (self.scope) {
            .local_process => self.runner_id == local_runner_id,
            .cloud_hosted => true,
        };
    }

    pub fn encode(self: *const ProviderCursor, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeU128(allocator, self.runner_id);
        try w.writeU8(allocator, @intFromEnum(self.scope));
        try w.writeBytes(allocator, self.native_session);
        try w.writeOptBytes(allocator, self.native_turn);
        try w.writeRaw(allocator, &self.bindings_digest);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ProviderCursor {
        const provider = try decodeEnum(iface.ProviderId, r);
        const runner_id = try r.readU128();
        const scope = try decodeEnum(CursorScope, r);
        const raw_ns = try readBytesCapped(r, MAX_SHORT_STR);
        const ns: []u8 = if (raw_ns.len > 0) try allocator.dupe(u8, raw_ns) else &.{};
        errdefer if (ns.len > 0) allocator.free(ns);
        const nt = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (nt) |t| allocator.free(t);
        const bd = (try r.readFixed(32)).*;
        return .{
            .provider = provider,
            .runner_id = runner_id,
            .scope = scope,
            .native_session = ns,
            .native_turn = nt,
            .bindings_digest = bd,
        };
    }
};

pub const BudgetError = error{
    BudgetExceeded,
    MaxDepthExceeded,
    MaxChildrenExceeded,
};

pub const Budget = struct {
    max_tokens: u64 = 0,
    used_tokens: u64 = 0,
    max_cost_microusd: u64 = 0,
    used_cost_microusd: u64 = 0,
    max_wall_ms: u64 = 0,
    used_wall_ms: u64 = 0,
    max_depth: u8 = 4,
    max_children: u16 = 32,
    active_children: u16 = 0,

    pub fn hasHeadroom(self: *const Budget) bool {
        if (self.max_tokens > 0 and self.used_tokens >= self.max_tokens) return false;
        if (self.max_cost_microusd > 0 and self.used_cost_microusd >= self.max_cost_microusd) return false;
        if (self.max_wall_ms > 0 and self.used_wall_ms >= self.max_wall_ms) return false;
        return true;
    }

    pub fn recordUsage(self: *Budget, tokens: u64, cost_microusd: u64, wall_ms: u64) BudgetError!void {
        const nt = std.math.add(u64, self.used_tokens, tokens) catch return error.BudgetExceeded;
        const nc = std.math.add(u64, self.used_cost_microusd, cost_microusd) catch return error.BudgetExceeded;
        const nw = std.math.add(u64, self.used_wall_ms, wall_ms) catch return error.BudgetExceeded;

        if (self.max_tokens > 0 and nt > self.max_tokens) return error.BudgetExceeded;
        if (self.max_cost_microusd > 0 and nc > self.max_cost_microusd) return error.BudgetExceeded;
        if (self.max_wall_ms > 0 and nw > self.max_wall_ms) return error.BudgetExceeded;

        self.used_tokens = nt;
        self.used_cost_microusd = nc;
        self.used_wall_ms = nw;
    }

    pub fn carveChild(self: *Budget, requested: Budget, current_depth: u8) BudgetError!Budget {
        if (current_depth >= self.max_depth) return error.MaxDepthExceeded;
        if (self.active_children >= self.max_children) return error.MaxChildrenExceeded;

        const grant_tokens: u64 = blk: {
            if (self.max_tokens > 0) {
                const avail = self.max_tokens -| self.used_tokens;
                if (requested.max_tokens == 0) {
                    if (avail == 0) return error.BudgetExceeded;
                    break :blk avail;
                }
                if (requested.max_tokens > avail) return error.BudgetExceeded;
                break :blk requested.max_tokens;
            }
            break :blk requested.max_tokens;
        };

        const grant_cost: u64 = blk: {
            if (self.max_cost_microusd > 0) {
                const avail = self.max_cost_microusd -| self.used_cost_microusd;
                if (requested.max_cost_microusd == 0) {
                    if (avail == 0) return error.BudgetExceeded;
                    break :blk avail;
                }
                if (requested.max_cost_microusd > avail) return error.BudgetExceeded;
                break :blk requested.max_cost_microusd;
            }
            break :blk requested.max_cost_microusd;
        };

        const grant_wall: u64 = blk: {
            if (self.max_wall_ms > 0) {
                const avail = self.max_wall_ms -| self.used_wall_ms;
                if (requested.max_wall_ms == 0) {
                    if (avail == 0) return error.BudgetExceeded;
                    break :blk avail;
                }
                if (requested.max_wall_ms > avail) return error.BudgetExceeded;
                break :blk requested.max_wall_ms;
            }
            break :blk requested.max_wall_ms;
        };

        self.used_tokens +|= grant_tokens;
        self.used_cost_microusd +|= grant_cost;
        self.used_wall_ms +|= grant_wall;
        self.active_children += 1;

        return .{
            .max_tokens = grant_tokens,
            .used_tokens = 0,
            .max_cost_microusd = grant_cost,
            .used_cost_microusd = 0,
            .max_wall_ms = grant_wall,
            .used_wall_ms = 0,
            .max_depth = @min(requested.max_depth, self.max_depth),
            .max_children = @min(requested.max_children, self.max_children),
            .active_children = 0,
        };
    }

    pub fn refundChild(self: *Budget, child: Budget) void {
        if (child.max_tokens > 0) {
            if (child.used_tokens <= child.max_tokens) {
                self.used_tokens -|= (child.max_tokens - child.used_tokens);
            } else {
                self.used_tokens +|= (child.used_tokens - child.max_tokens);
            }
        } else {
            self.used_tokens +|= child.used_tokens;
        }

        if (child.max_cost_microusd > 0) {
            if (child.used_cost_microusd <= child.max_cost_microusd) {
                self.used_cost_microusd -|= (child.max_cost_microusd - child.used_cost_microusd);
            } else {
                self.used_cost_microusd +|= (child.used_cost_microusd - child.max_cost_microusd);
            }
        } else {
            self.used_cost_microusd +|= child.used_cost_microusd;
        }

        if (child.max_wall_ms > 0) {
            if (child.used_wall_ms <= child.max_wall_ms) {
                self.used_wall_ms -|= (child.max_wall_ms - child.used_wall_ms);
            } else {
                self.used_wall_ms +|= (child.used_wall_ms - child.max_wall_ms);
            }
        } else {
            self.used_wall_ms +|= child.used_wall_ms;
        }

        self.active_children -|= 1;
    }

    pub fn encode(self: *const Budget, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU64(allocator, self.max_tokens);
        try w.writeU64(allocator, self.used_tokens);
        try w.writeU64(allocator, self.max_cost_microusd);
        try w.writeU64(allocator, self.used_cost_microusd);
        try w.writeU64(allocator, self.max_wall_ms);
        try w.writeU64(allocator, self.used_wall_ms);
        try w.writeU8(allocator, self.max_depth);
        try w.writeU16(allocator, self.max_children);
        try w.writeU16(allocator, self.active_children);
    }

    pub fn decode(r: *codec.Reader) !Budget {
        return .{
            .max_tokens = try r.readU64(),
            .used_tokens = try r.readU64(),
            .max_cost_microusd = try r.readU64(),
            .used_cost_microusd = try r.readU64(),
            .max_wall_ms = try r.readU64(),
            .used_wall_ms = try r.readU64(),
            .max_depth = try r.readU8(),
            .max_children = try r.readU16(),
            .active_children = try r.readU16(),
        };
    }
};

pub const ExecutionLeaseRef = struct {
    holder_runner_id: u128,
    fencing_epoch: u64,
    expires_ms: u64,
    handoff_target: ?u128 = null,

    pub fn encode(self: *const ExecutionLeaseRef, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.holder_runner_id);
        try w.writeU64(allocator, self.fencing_epoch);
        try w.writeU64(allocator, self.expires_ms);
        try w.writeOptU128(allocator, self.handoff_target);
    }

    pub fn decode(r: *codec.Reader) !ExecutionLeaseRef {
        return .{
            .holder_runner_id = try r.readU128(),
            .fencing_epoch = try r.readU64(),
            .expires_ms = try r.readU64(),
            .handoff_target = try r.readOptU128(),
        };
    }
};

pub const PlacementTag = enum(u8) {
    any = 0,
    local_only = 1,
    cloud_preferred = 2,
    pinned = 3,
};

pub const PlacementPolicy = union(PlacementTag) {
    any,
    local_only,
    cloud_preferred,
    pinned: u128,

    pub fn encode(self: PlacementPolicy, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU8(allocator, @intFromEnum(self));
        switch (self) {
            .pinned => |rid| try w.writeU128(allocator, rid),
            else => {},
        }
    }

    pub fn decode(r: *codec.Reader) !PlacementPolicy {
        const tag = try decodeEnum(PlacementTag, r);
        return switch (tag) {
            .any => .any,
            .local_only => .local_only,
            .cloud_preferred => .cloud_preferred,
            .pinned => .{ .pinned = try r.readU128() },
        };
    }
};

pub const TaskStatus = enum(u8) {
    pending = 0,
    ready = 1,
    leased = 2,
    running = 3,
    completed = 4,
    failed = 5,
    canceled = 6,

    pub fn isTerminal(self: TaskStatus) bool {
        return self == .completed or self == .failed or self == .canceled;
    }

    pub fn canTransitionTo(self: TaskStatus, next: TaskStatus) bool {
        if (self == next) return true;
        if (self.isTerminal()) return false;
        return @intFromEnum(next) >= @intFromEnum(self);
    }
};

pub const Task = struct {
    task_id: u128,
    parent_thread_id: u128,
    child_thread_id: u128,
    title: []u8,
    status: TaskStatus = .pending,
    attempt: u32 = 1,
    depends_on: []u128 = &.{},
    join_quorum: u16 = 0,
    placement: PlacementPolicy = .any,
    grants: []SpaceBinding = &.{},
    budget: Budget = .{},
    start_checkpoint: CheckpointVector = .{},
    end_checkpoint: CheckpointVector = .{},
    err_msg: ?[]u8 = null,
    created_ms: u64,
    updated_ms: u64,

    pub fn deinit(self: *Task, allocator: Allocator) void {
        if (self.title.len > 0) allocator.free(self.title);
        if (self.depends_on.len > 0) allocator.free(self.depends_on);
        if (self.grants.len > 0) {
            for (self.grants) |*g| g.deinit(allocator);
            allocator.free(self.grants);
        }
        self.start_checkpoint.deinit(allocator);
        self.end_checkpoint.deinit(allocator);
        if (self.err_msg) |e| allocator.free(e);
        self.title = &.{};
        self.depends_on = &.{};
        self.grants = &.{};
        self.err_msg = null;
    }

    pub fn clone(self: *const Task, allocator: Allocator) Allocator.Error!Task {
        const title: []u8 = if (self.title.len > 0) try allocator.dupe(u8, self.title) else &.{};
        errdefer if (title.len > 0) allocator.free(title);

        const deps: []u128 = if (self.depends_on.len > 0) try allocator.dupe(u128, self.depends_on) else &.{};
        errdefer if (deps.len > 0) allocator.free(deps);

        const grants = try cloneBindings(allocator, self.grants);
        errdefer freeBindings(allocator, grants);

        var start_cp = try self.start_checkpoint.clone(allocator);
        errdefer start_cp.deinit(allocator);

        var end_cp = try self.end_checkpoint.clone(allocator);
        errdefer end_cp.deinit(allocator);

        const err_msg = if (self.err_msg) |e| try allocator.dupe(u8, e) else null;

        return .{
            .task_id = self.task_id,
            .parent_thread_id = self.parent_thread_id,
            .child_thread_id = self.child_thread_id,
            .title = title,
            .status = self.status,
            .attempt = self.attempt,
            .depends_on = deps,
            .join_quorum = self.join_quorum,
            .placement = self.placement,
            .grants = grants,
            .budget = self.budget,
            .start_checkpoint = start_cp,
            .end_checkpoint = end_cp,
            .err_msg = err_msg,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const Task, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.task_id);
        try w.writeU128(allocator, self.parent_thread_id);
        try w.writeU128(allocator, self.child_thread_id);
        try w.writeBytes(allocator, self.title);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeU32(allocator, self.attempt);
        try w.writeVarint(allocator, self.depends_on.len);
        for (self.depends_on) |d| try w.writeU128(allocator, d);
        try w.writeU16(allocator, self.join_quorum);
        try self.placement.encode(allocator, w);
        try encodeBindings(allocator, w, self.grants);
        try self.budget.encode(allocator, w);
        try self.start_checkpoint.encode(allocator, w);
        try self.end_checkpoint.encode(allocator, w);
        try w.writeOptBytes(allocator, self.err_msg);
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !Task {
        const task_id = try r.readU128();
        const parent_tid = try r.readU128();
        const child_tid = try r.readU128();
        const raw_title = try readBytesCapped(r, MAX_SHORT_STR);
        const title: []u8 = if (raw_title.len > 0) try allocator.dupe(u8, raw_title) else &.{};
        errdefer if (title.len > 0) allocator.free(title);
        const status = try decodeEnum(TaskStatus, r);
        const attempt = try r.readU32();
        const dep_count = r.readCount(16, MAX_DEPS) catch return error.CorruptRecord;
        const deps: []u128 = if (dep_count > 0) try allocator.alloc(u128, dep_count) else &.{};
        errdefer if (deps.len > 0) allocator.free(deps);
        for (0..dep_count) |i| deps[i] = try r.readU128();
        const join_quorum = try r.readU16();
        const placement = try PlacementPolicy.decode(r);
        const grants = try decodeBindings(allocator, r);
        errdefer freeBindings(allocator, grants);
        const budget = try Budget.decode(r);
        var start_cp = try CheckpointVector.decode(allocator, r);
        errdefer start_cp.deinit(allocator);
        var end_cp = try CheckpointVector.decode(allocator, r);
        errdefer end_cp.deinit(allocator);
        const err_msg = try readOptBytesAllocCapped(allocator, r, MAX_CONTENT_BYTES);
        errdefer if (err_msg) |e| allocator.free(e);
        const created_ms = try r.readU64();
        const updated_ms = try r.readU64();
        return .{
            .task_id = task_id,
            .parent_thread_id = parent_tid,
            .child_thread_id = child_tid,
            .title = title,
            .status = status,
            .attempt = attempt,
            .depends_on = deps,
            .join_quorum = join_quorum,
            .placement = placement,
            .grants = grants,
            .budget = budget,
            .start_checkpoint = start_cp,
            .end_checkpoint = end_cp,
            .err_msg = err_msg,
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        };
    }
};

pub const MailboxKind = enum(u8) {
    assign = 0,
    steer = 1,
    progress = 2,
    question = 3,
    answer = 4,
    handoff = 5,
    result = 6,
    cancel = 7,
};

pub const MailboxItem = struct {
    item_id: u128,
    from_thread_id: u128,
    to_thread_id: u128,
    task_id: ?u128 = null,
    kind: MailboxKind,
    payload: []u8,
    blob_oid: ?id.Oid = null,
    checkpoint: CheckpointVector = .{},
    created_ms: u64,

    pub fn deinit(self: *MailboxItem, allocator: Allocator) void {
        if (self.payload.len > 0) allocator.free(self.payload);
        self.checkpoint.deinit(allocator);
        self.payload = &.{};
    }

    pub fn clone(self: *const MailboxItem, allocator: Allocator) Allocator.Error!MailboxItem {
        const payload: []u8 = if (self.payload.len > 0) try allocator.dupe(u8, self.payload) else &.{};
        errdefer if (payload.len > 0) allocator.free(payload);
        var cp = try self.checkpoint.clone(allocator);
        errdefer cp.deinit(allocator);
        return .{
            .item_id = self.item_id,
            .from_thread_id = self.from_thread_id,
            .to_thread_id = self.to_thread_id,
            .task_id = self.task_id,
            .kind = self.kind,
            .payload = payload,
            .blob_oid = self.blob_oid,
            .checkpoint = cp,
            .created_ms = self.created_ms,
        };
    }

    pub fn encode(self: *const MailboxItem, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.item_id);
        try w.writeU128(allocator, self.from_thread_id);
        try w.writeU128(allocator, self.to_thread_id);
        try w.writeOptU128(allocator, self.task_id);
        try w.writeU8(allocator, @intFromEnum(self.kind));
        try w.writeBytes(allocator, self.payload);
        if (self.blob_oid) |oid| {
            try w.writeU8(allocator, 1);
            try w.writeRaw(allocator, &oid);
        } else {
            try w.writeU8(allocator, 0);
        }
        try self.checkpoint.encode(allocator, w);
        try w.writeU64(allocator, self.created_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !MailboxItem {
        const item_id = try r.readU128();
        const from_tid = try r.readU128();
        const to_tid = try r.readU128();
        const task_id = try r.readOptU128();
        const kind = try decodeEnum(MailboxKind, r);
        const raw_payload = try readBytesCapped(r, MAX_CONTENT_BYTES);
        const payload: []u8 = if (raw_payload.len > 0) try allocator.dupe(u8, raw_payload) else &.{};
        errdefer if (payload.len > 0) allocator.free(payload);
        const has_oid = try decodeFlag(r);
        const blob_oid: ?id.Oid = if (has_oid) (try r.readFixed(32)).* else null;
        var cp = try CheckpointVector.decode(allocator, r);
        errdefer cp.deinit(allocator);
        const created_ms = try r.readU64();
        return .{
            .item_id = item_id,
            .from_thread_id = from_tid,
            .to_thread_id = to_tid,
            .task_id = task_id,
            .kind = kind,
            .payload = payload,
            .blob_oid = blob_oid,
            .checkpoint = cp,
            .created_ms = created_ms,
        };
    }
};

pub const SpaceChangedTrigger = struct {
    space_id: u128,
    path_prefix: []u8,
    debounce_ms: u32,
};

pub const TriggerKindTag = enum(u8) {
    once = 0,
    cron = 1,
    space_changed = 2,
    mailbox = 3,
    webhook = 4,
};

pub const TriggerKind = union(TriggerKindTag) {
    once: u64,
    cron: []u8,
    space_changed: SpaceChangedTrigger,
    mailbox,
    webhook: []u8,

    pub fn deinit(self: *TriggerKind, allocator: Allocator) void {
        switch (self.*) {
            .once, .mailbox => {},
            .cron => |s| if (s.len > 0) allocator.free(s),
            .space_changed => |sc| if (sc.path_prefix.len > 0) allocator.free(sc.path_prefix),
            .webhook => |s| if (s.len > 0) allocator.free(s),
        }
    }

    pub fn clone(self: *const TriggerKind, allocator: Allocator) Allocator.Error!TriggerKind {
        return switch (self.*) {
            .once => |ts| .{ .once = ts },
            .cron => |s| .{ .cron = if (s.len > 0) try allocator.dupe(u8, s) else &.{} },
            .space_changed => |sc| .{ .space_changed = .{
                .space_id = sc.space_id,
                .path_prefix = if (sc.path_prefix.len > 0) try allocator.dupe(u8, sc.path_prefix) else &.{},
                .debounce_ms = sc.debounce_ms,
            } },
            .mailbox => .mailbox,
            .webhook => |s| .{ .webhook = if (s.len > 0) try allocator.dupe(u8, s) else &.{} },
        };
    }

    pub fn encode(self: *const TriggerKind, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU8(allocator, @intFromEnum(self.*));
        switch (self.*) {
            .once => |ts| try w.writeU64(allocator, ts),
            .cron => |s| try w.writeBytes(allocator, s),
            .space_changed => |sc| {
                try w.writeU128(allocator, sc.space_id);
                try w.writeBytes(allocator, sc.path_prefix);
                try w.writeU32(allocator, sc.debounce_ms);
            },
            .mailbox => {},
            .webhook => |s| try w.writeBytes(allocator, s),
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !TriggerKind {
        const tag = try decodeEnum(TriggerKindTag, r);
        return switch (tag) {
            .once => .{ .once = try r.readU64() },
            .cron => blk: {
                const raw = try readBytesCapped(r, MAX_SHORT_STR);
                break :blk .{ .cron = if (raw.len > 0) try allocator.dupe(u8, raw) else &.{} };
            },
            .space_changed => blk: {
                const sid = try r.readU128();
                const raw_p = try readBytesCapped(r, MAX_SHORT_STR);
                const prefix: []u8 = if (raw_p.len > 0) try allocator.dupe(u8, raw_p) else &.{};
                errdefer if (prefix.len > 0) allocator.free(prefix);
                const deb = try r.readU32();
                break :blk .{ .space_changed = .{
                    .space_id = sid,
                    .path_prefix = prefix,
                    .debounce_ms = deb,
                } };
            },
            .mailbox => .mailbox,
            .webhook => blk: {
                const raw = try readBytesCapped(r, MAX_SHORT_STR);
                break :blk .{ .webhook = if (raw.len > 0) try allocator.dupe(u8, raw) else &.{} };
            },
        };
    }
};

pub const Trigger = struct {
    trigger_id: u128,
    thread_id: u128,
    kind: TriggerKind,
    prompt_template: []u8,
    enabled: bool = true,
    next_fire_ms: u64 = 0,
    placement: PlacementPolicy = .any,
    created_ms: u64,

    pub fn dedupKey(trigger_id: u128, fire_slot: u64) [32]u8 {
        var h = std.crypto.hash.Blake3.init(.{});
        h.update("0ndb-trigger-fire-v1:");
        var tid_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &tid_bytes, trigger_id, .little);
        h.update(&tid_bytes);
        var slot_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &slot_bytes, fire_slot, .little);
        h.update(&slot_bytes);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    pub fn deinit(self: *Trigger, allocator: Allocator) void {
        self.kind.deinit(allocator);
        if (self.prompt_template.len > 0) allocator.free(self.prompt_template);
        self.prompt_template = &.{};
    }

    pub fn clone(self: *const Trigger, allocator: Allocator) Allocator.Error!Trigger {
        var k = try self.kind.clone(allocator);
        errdefer k.deinit(allocator);
        const pt: []u8 = if (self.prompt_template.len > 0) try allocator.dupe(u8, self.prompt_template) else &.{};
        return .{
            .trigger_id = self.trigger_id,
            .thread_id = self.thread_id,
            .kind = k,
            .prompt_template = pt,
            .enabled = self.enabled,
            .next_fire_ms = self.next_fire_ms,
            .placement = self.placement,
            .created_ms = self.created_ms,
        };
    }

    pub fn encode(self: *const Trigger, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.trigger_id);
        try w.writeU128(allocator, self.thread_id);
        try self.kind.encode(allocator, w);
        try w.writeBytes(allocator, self.prompt_template);
        try w.writeBool(allocator, self.enabled);
        try w.writeU64(allocator, self.next_fire_ms);
        try self.placement.encode(allocator, w);
        try w.writeU64(allocator, self.created_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !Trigger {
        const trigger_id = try r.readU128();
        const thread_id = try r.readU128();
        var kind = try TriggerKind.decode(allocator, r);
        errdefer kind.deinit(allocator);
        const raw_pt = try readBytesCapped(r, MAX_CONTENT_BYTES);
        const pt: []u8 = if (raw_pt.len > 0) try allocator.dupe(u8, raw_pt) else &.{};
        errdefer if (pt.len > 0) allocator.free(pt);
        const enabled = try decodeFlag(r);
        const next_fire_ms = try r.readU64();
        const placement = try PlacementPolicy.decode(r);
        const created_ms = try r.readU64();
        return .{
            .trigger_id = trigger_id,
            .thread_id = thread_id,
            .kind = kind,
            .prompt_template = pt,
            .enabled = enabled,
            .next_fire_ms = next_fire_ms,
            .placement = placement,
            .created_ms = created_ms,
        };
    }
};

pub const RollbackIntent = struct {
    intent_id: u128,
    target_msg_id: ?u128 = null,
    target_vector: CheckpointVector = .{},
    completed_spaces: []u128 = &.{},
    created_ms: u64,

    pub fn deinit(self: *RollbackIntent, allocator: Allocator) void {
        self.target_vector.deinit(allocator);
        if (self.completed_spaces.len > 0) allocator.free(self.completed_spaces);
        self.completed_spaces = &.{};
    }

    pub fn clone(self: *const RollbackIntent, allocator: Allocator) Allocator.Error!RollbackIntent {
        var tv = try self.target_vector.clone(allocator);
        errdefer tv.deinit(allocator);
        const cs: []u128 = if (self.completed_spaces.len > 0) try allocator.dupe(u128, self.completed_spaces) else &.{};
        return .{
            .intent_id = self.intent_id,
            .target_msg_id = self.target_msg_id,
            .target_vector = tv,
            .completed_spaces = cs,
            .created_ms = self.created_ms,
        };
    }

    pub fn isSpaceCompleted(self: *const RollbackIntent, space_id: u128) bool {
        for (self.completed_spaces) |sid| {
            if (sid == space_id) return true;
        }
        return false;
    }

    pub fn markSpaceCompleted(self: *RollbackIntent, allocator: Allocator, space_id: u128) Allocator.Error!void {
        if (self.isSpaceCompleted(space_id)) return;
        const next = try allocator.alloc(u128, self.completed_spaces.len + 1);
        if (self.completed_spaces.len > 0) {
            @memcpy(next[0..self.completed_spaces.len], self.completed_spaces);
            allocator.free(self.completed_spaces);
        }
        next[next.len - 1] = space_id;
        self.completed_spaces = next;
    }

    pub fn allSpacesCompleted(self: *const RollbackIntent) bool {
        for (self.target_vector.entries) |*e| {
            if (!self.isSpaceCompleted(e.space_id)) return false;
        }
        return true;
    }

    pub fn encode(self: *const RollbackIntent, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.intent_id);
        try w.writeOptU128(allocator, self.target_msg_id);
        try self.target_vector.encode(allocator, w);
        try w.writeVarint(allocator, self.completed_spaces.len);
        for (self.completed_spaces) |sid| try w.writeU128(allocator, sid);
        try w.writeU64(allocator, self.created_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !RollbackIntent {
        const intent_id = try r.readU128();
        const target_msg_id = try r.readOptU128();
        var tv = try CheckpointVector.decode(allocator, r);
        errdefer tv.deinit(allocator);
        const cs_count = r.readCount(16, MAX_CHECKPOINTS) catch return error.CorruptRecord;
        const cs: []u128 = if (cs_count > 0) try allocator.alloc(u128, cs_count) else &.{};
        errdefer if (cs.len > 0) allocator.free(cs);
        for (0..cs_count) |i| cs[i] = try r.readU128();
        const created_ms = try r.readU64();
        return .{
            .intent_id = intent_id,
            .target_msg_id = target_msg_id,
            .target_vector = tv,
            .completed_spaces = cs,
            .created_ms = created_ms,
        };
    }
};

pub fn cloneBindings(allocator: Allocator, bindings: []const SpaceBinding) Allocator.Error![]SpaceBinding {
    if (bindings.len == 0) return &.{};
    const out = try allocator.alloc(SpaceBinding, bindings.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*b| b.deinit(allocator);
        allocator.free(out);
    }
    for (bindings, 0..) |*b, i| {
        out[i] = try b.clone(allocator);
        built += 1;
    }
    return out;
}

pub fn freeBindings(allocator: Allocator, bindings: []SpaceBinding) void {
    if (bindings.len == 0) return;
    for (bindings) |*b| b.deinit(allocator);
    allocator.free(bindings);
}

pub fn encodeBindings(allocator: Allocator, w: *codec.Writer, bindings: []const SpaceBinding) Allocator.Error!void {
    try w.writeVarint(allocator, bindings.len);
    for (bindings) |*b| try b.encode(allocator, w);
}

pub fn decodeBindings(allocator: Allocator, r: *codec.Reader) ![]SpaceBinding {
    const count = r.readCount(19, MAX_BINDINGS) catch return error.CorruptRecord;
    if (count == 0) return &.{};
    const out = try allocator.alloc(SpaceBinding, count);
    var decoded: usize = 0;
    errdefer {
        for (out[0..decoded]) |*b| b.deinit(allocator);
        allocator.free(out);
    }
    for (0..count) |i| {
        out[i] = try SpaceBinding.decode(allocator, r);
        decoded += 1;
    }
    return out;
}

pub const ThreadMeta = struct {
    thread_id: u128,
    project_id: ?u128 = null,
    parent_thread_id: ?u128 = null,
    root_thread_id: u128,
    task_id: ?u128 = null,
    depth: u8 = 0,
    title: []u8,
    default_provider: iface.ProviderId,
    default_model: ?[]u8 = null,
    bindings: []SpaceBinding = &.{},
    budget: Budget = .{},
    root_checkpoint: CheckpointVector = .{},
    status: SessionStatus = .idle,
    created_ms: u64,
    updated_ms: u64,

    pub const validateGrantAttenuation = @This().validateGrantAttenuationFn;

    fn validateGrantAttenuationFn(parent_bindings: []const SpaceBinding, child_grants: []const SpaceBinding) GrantError!void {
        return @import("model.zig").validateGrantAttenuation(parent_bindings, child_grants);
    }

    pub fn bindingsDigest(self: *const ThreadMeta) [32]u8 {
        return computeBindingsDigest(self.bindings);
    }

    pub fn deinit(self: *ThreadMeta, allocator: Allocator) void {
        if (self.title.len > 0) allocator.free(self.title);
        if (self.default_model) |m| allocator.free(m);
        freeBindings(allocator, self.bindings);
        self.root_checkpoint.deinit(allocator);
        self.title = &.{};
        self.default_model = null;
        self.bindings = &.{};
    }

    pub fn clone(self: *const ThreadMeta, allocator: Allocator) Allocator.Error!ThreadMeta {
        const title: []u8 = if (self.title.len > 0) try allocator.dupe(u8, self.title) else &.{};
        errdefer if (title.len > 0) allocator.free(title);
        const model = if (self.default_model) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        const bindings = try cloneBindings(allocator, self.bindings);
        errdefer freeBindings(allocator, bindings);
        var root_cp = try self.root_checkpoint.clone(allocator);
        errdefer root_cp.deinit(allocator);
        return .{
            .thread_id = self.thread_id,
            .project_id = self.project_id,
            .parent_thread_id = self.parent_thread_id,
            .root_thread_id = self.root_thread_id,
            .task_id = self.task_id,
            .depth = self.depth,
            .title = title,
            .default_provider = self.default_provider,
            .default_model = model,
            .bindings = bindings,
            .budget = self.budget,
            .root_checkpoint = root_cp,
            .status = self.status,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const ThreadMeta, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.thread_id);
        try w.writeOptU128(allocator, self.project_id);
        try w.writeOptU128(allocator, self.parent_thread_id);
        try w.writeU128(allocator, self.root_thread_id);
        try w.writeOptU128(allocator, self.task_id);
        try w.writeU8(allocator, self.depth);
        try w.writeBytes(allocator, self.title);
        try w.writeU8(allocator, @intFromEnum(self.default_provider));
        try w.writeOptBytes(allocator, self.default_model);
        try encodeBindings(allocator, w, self.bindings);
        try self.budget.encode(allocator, w);
        try self.root_checkpoint.encode(allocator, w);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ThreadMeta {
        const thread_id = try r.readU128();
        const project_id = try r.readOptU128();
        const parent_thread_id = try r.readOptU128();
        const root_thread_id = try r.readU128();
        const task_id = try r.readOptU128();
        const depth = try r.readU8();
        const raw_title = try readBytesCapped(r, MAX_SHORT_STR);
        const title: []u8 = if (raw_title.len > 0) try allocator.dupe(u8, raw_title) else &.{};
        errdefer if (title.len > 0) allocator.free(title);
        const default_provider = try decodeEnum(iface.ProviderId, r);
        const default_model = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (default_model) |m| allocator.free(m);
        const bindings = try decodeBindings(allocator, r);
        errdefer freeBindings(allocator, bindings);
        const budget = try Budget.decode(r);
        var root_cp = try CheckpointVector.decode(allocator, r);
        errdefer root_cp.deinit(allocator);
        const status = try decodeEnum(SessionStatus, r);
        const created_ms = try r.readU64();
        const updated_ms = try r.readU64();
        return .{
            .thread_id = thread_id,
            .project_id = project_id,
            .parent_thread_id = parent_thread_id,
            .root_thread_id = root_thread_id,
            .task_id = task_id,
            .depth = depth,
            .title = title,
            .default_provider = default_provider,
            .default_model = default_model,
            .bindings = bindings,
            .budget = budget,
            .root_checkpoint = root_cp,
            .status = status,
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        };
    }
};

pub const Message = struct {
    msg_id: u128,
    thread_id: u128,
    parent_id: ?u128 = null,
    role: Role,
    content: []u8,
    provider: iface.ProviderId,
    model: ?[]u8 = null,
    cursor: ?ProviderCursor = null,
    runner_id: u128 = 0,
    fencing_epoch: u64 = 0,
    pre_checkpoint: CheckpointVector = .{},
    post_checkpoint: CheckpointVector = .{},
    status: MessageStatus,
    steer_of: ?u128 = null,
    switched_from: ?u128 = null,
    err_msg: ?[]u8 = null,
    created_ms: u64,
    updated_ms: u64,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
        if (self.model) |m| allocator.free(m);
        if (self.cursor) |*c| c.deinit(allocator);
        self.pre_checkpoint.deinit(allocator);
        self.post_checkpoint.deinit(allocator);
        if (self.err_msg) |e| allocator.free(e);
        self.content = &.{};
        self.model = null;
        self.cursor = null;
        self.err_msg = null;
    }

    pub fn clone(self: *const Message, allocator: Allocator) Allocator.Error!Message {
        const content: []u8 = if (self.content.len > 0) try allocator.dupe(u8, self.content) else &.{};
        errdefer if (content.len > 0) allocator.free(content);
        const model = if (self.model) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        var cursor: ?ProviderCursor = if (self.cursor) |*c| try c.clone(allocator) else null;
        errdefer if (cursor) |*c| c.deinit(allocator);
        var pre_cp = try self.pre_checkpoint.clone(allocator);
        errdefer pre_cp.deinit(allocator);
        var post_cp = try self.post_checkpoint.clone(allocator);
        errdefer post_cp.deinit(allocator);
        const err_msg = if (self.err_msg) |e| try allocator.dupe(u8, e) else null;
        return .{
            .msg_id = self.msg_id,
            .thread_id = self.thread_id,
            .parent_id = self.parent_id,
            .role = self.role,
            .content = content,
            .provider = self.provider,
            .model = model,
            .cursor = cursor,
            .runner_id = self.runner_id,
            .fencing_epoch = self.fencing_epoch,
            .pre_checkpoint = pre_cp,
            .post_checkpoint = post_cp,
            .status = self.status,
            .steer_of = self.steer_of,
            .switched_from = self.switched_from,
            .err_msg = err_msg,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const Message, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.msg_id);
        try w.writeU128(allocator, self.thread_id);
        try w.writeOptU128(allocator, self.parent_id);
        try w.writeU8(allocator, @intFromEnum(self.role));
        try w.writeBytes(allocator, self.content);
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeOptBytes(allocator, self.model);
        if (self.cursor) |*c| {
            try w.writeU8(allocator, 1);
            try c.encode(allocator, w);
        } else {
            try w.writeU8(allocator, 0);
        }
        try w.writeU128(allocator, self.runner_id);
        try w.writeU64(allocator, self.fencing_epoch);
        try self.pre_checkpoint.encode(allocator, w);
        try self.post_checkpoint.encode(allocator, w);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeOptU128(allocator, self.steer_of);
        try w.writeOptU128(allocator, self.switched_from);
        try w.writeOptBytes(allocator, self.err_msg);
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !Message {
        const msg_id = try r.readU128();
        const thread_id = try r.readU128();
        const parent_id = try r.readOptU128();
        const role = try decodeEnum(Role, r);
        const raw_content = try readBytesCapped(r, MAX_CONTENT_BYTES);
        const content: []u8 = if (raw_content.len > 0) try allocator.dupe(u8, raw_content) else &.{};
        errdefer if (content.len > 0) allocator.free(content);
        const provider = try decodeEnum(iface.ProviderId, r);
        const model = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (model) |m| allocator.free(m);
        var cursor: ?ProviderCursor = null;
        if (try decodeFlag(r)) {
            cursor = try ProviderCursor.decode(allocator, r);
        }
        errdefer if (cursor) |*c| c.deinit(allocator);
        const runner_id = try r.readU128();
        const fencing_epoch = try r.readU64();
        var pre_cp = try CheckpointVector.decode(allocator, r);
        errdefer pre_cp.deinit(allocator);
        var post_cp = try CheckpointVector.decode(allocator, r);
        errdefer post_cp.deinit(allocator);
        const status = try decodeEnum(MessageStatus, r);
        const steer_of = try r.readOptU128();
        const switched_from = try r.readOptU128();
        const err_msg = try readOptBytesAllocCapped(allocator, r, MAX_CONTENT_BYTES);
        errdefer if (err_msg) |e| allocator.free(e);
        const created_ms = try r.readU64();
        const updated_ms = try r.readU64();
        return .{
            .msg_id = msg_id,
            .thread_id = thread_id,
            .parent_id = parent_id,
            .role = role,
            .content = content,
            .provider = provider,
            .model = model,
            .cursor = cursor,
            .runner_id = runner_id,
            .fencing_epoch = fencing_epoch,
            .pre_checkpoint = pre_cp,
            .post_checkpoint = post_cp,
            .status = status,
            .steer_of = steer_of,
            .switched_from = switched_from,
            .err_msg = err_msg,
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        };
    }
};

pub const ToolCallRecord = struct {
    msg_id: u128,
    call_id: []u8,
    name: []u8,
    input_json: []u8,
    output: []u8,
    is_error: bool,

    pub fn deinit(self: *ToolCallRecord, allocator: Allocator) void {
        if (self.call_id.len > 0) allocator.free(self.call_id);
        if (self.name.len > 0) allocator.free(self.name);
        if (self.input_json.len > 0) allocator.free(self.input_json);
        if (self.output.len > 0) allocator.free(self.output);
        self.call_id = &.{};
        self.name = &.{};
        self.input_json = &.{};
        self.output = &.{};
    }

    pub fn clone(self: *const ToolCallRecord, allocator: Allocator) Allocator.Error!ToolCallRecord {
        const cid: []u8 = if (self.call_id.len > 0) try allocator.dupe(u8, self.call_id) else &.{};
        errdefer if (cid.len > 0) allocator.free(cid);
        const nm: []u8 = if (self.name.len > 0) try allocator.dupe(u8, self.name) else &.{};
        errdefer if (nm.len > 0) allocator.free(nm);
        const inp: []u8 = if (self.input_json.len > 0) try allocator.dupe(u8, self.input_json) else &.{};
        errdefer if (inp.len > 0) allocator.free(inp);
        const out: []u8 = if (self.output.len > 0) try allocator.dupe(u8, self.output) else &.{};
        return .{
            .msg_id = self.msg_id,
            .call_id = cid,
            .name = nm,
            .input_json = inp,
            .output = out,
            .is_error = self.is_error,
        };
    }

    pub fn encode(self: *const ToolCallRecord, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.msg_id);
        try w.writeBytes(allocator, self.call_id);
        try w.writeBytes(allocator, self.name);
        try w.writeBytes(allocator, self.input_json);
        try w.writeBytes(allocator, self.output);
        try w.writeBool(allocator, self.is_error);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ToolCallRecord {
        const mid = try r.readU128();
        const raw_cid = try readBytesCapped(r, MAX_SHORT_STR);
        const cid: []u8 = if (raw_cid.len > 0) try allocator.dupe(u8, raw_cid) else &.{};
        errdefer if (cid.len > 0) allocator.free(cid);
        const raw_nm = try readBytesCapped(r, MAX_SHORT_STR);
        const nm: []u8 = if (raw_nm.len > 0) try allocator.dupe(u8, raw_nm) else &.{};
        errdefer if (nm.len > 0) allocator.free(nm);
        const raw_inp = try readBytesCapped(r, MAX_CONTENT_BYTES);
        const inp: []u8 = if (raw_inp.len > 0) try allocator.dupe(u8, raw_inp) else &.{};
        errdefer if (inp.len > 0) allocator.free(inp);
        const raw_out = try readBytesCapped(r, MAX_CONTENT_BYTES);
        const out: []u8 = if (raw_out.len > 0) try allocator.dupe(u8, raw_out) else &.{};
        errdefer if (out.len > 0) allocator.free(out);
        const is_err = try decodeFlag(r);
        return .{
            .msg_id = mid,
            .call_id = cid,
            .name = nm,
            .input_json = inp,
            .output = out,
            .is_error = is_err,
        };
    }
};

pub const QueueItem = struct {
    item_id: u128,
    thread_id: u128,
    kind: QueueKind,
    status: QueueStatus,
    prompt: []u8,
    provider: iface.ProviderId,
    model: ?[]u8 = null,
    target_turn_msg_id: ?u128 = null,
    created_ms: u64,
    updated_ms: u64,

    pub fn deinit(self: *QueueItem, allocator: Allocator) void {
        if (self.prompt.len > 0) allocator.free(self.prompt);
        if (self.model) |m| allocator.free(m);
        self.prompt = &.{};
        self.model = null;
    }

    pub fn clone(self: *const QueueItem, allocator: Allocator) Allocator.Error!QueueItem {
        const prompt: []u8 = if (self.prompt.len > 0) try allocator.dupe(u8, self.prompt) else &.{};
        errdefer if (prompt.len > 0) allocator.free(prompt);
        const model = if (self.model) |m| try allocator.dupe(u8, m) else null;
        return .{
            .item_id = self.item_id,
            .thread_id = self.thread_id,
            .kind = self.kind,
            .status = self.status,
            .prompt = prompt,
            .provider = self.provider,
            .model = model,
            .target_turn_msg_id = self.target_turn_msg_id,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const QueueItem, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.item_id);
        try w.writeU128(allocator, self.thread_id);
        try w.writeU8(allocator, @intFromEnum(self.kind));
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeBytes(allocator, self.prompt);
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeOptBytes(allocator, self.model);
        try w.writeOptU128(allocator, self.target_turn_msg_id);
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !QueueItem {
        const item_id = try r.readU128();
        const thread_id = try r.readU128();
        const kind = try decodeEnum(QueueKind, r);
        const status = try decodeEnum(QueueStatus, r);
        const raw_prompt = try readBytesCapped(r, MAX_CONTENT_BYTES);
        const prompt: []u8 = if (raw_prompt.len > 0) try allocator.dupe(u8, raw_prompt) else &.{};
        errdefer if (prompt.len > 0) allocator.free(prompt);
        const provider = try decodeEnum(iface.ProviderId, r);
        const model = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (model) |m| allocator.free(m);
        const target = try r.readOptU128();
        const created_ms = try r.readU64();
        const updated_ms = try r.readU64();
        return .{
            .item_id = item_id,
            .thread_id = thread_id,
            .kind = kind,
            .status = status,
            .prompt = prompt,
            .provider = provider,
            .model = model,
            .target_turn_msg_id = target,
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        };
    }
};

pub const BranchChoice = struct {
    parent_id: ?u128 = null,
    selected_child_id: u128,
    lamport: u64,
    actor: u128,

    pub fn winsOver(self: BranchChoice, other: BranchChoice) bool {
        if (self.lamport != other.lamport) return self.lamport > other.lamport;
        return self.actor > other.actor;
    }

    pub fn encode(self: *const BranchChoice, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeOptU128(allocator, self.parent_id);
        try w.writeU128(allocator, self.selected_child_id);
        try w.writeU64(allocator, self.lamport);
        try w.writeU128(allocator, self.actor);
    }

    pub fn decode(r: *codec.Reader) !BranchChoice {
        return .{
            .parent_id = try r.readOptU128(),
            .selected_child_id = try r.readU128(),
            .lamport = try r.readU64(),
            .actor = try r.readU128(),
        };
    }
};

pub const MessagePage = struct {
    thread_id: u128,
    prev_page: ?id.PageId = null,
    first_msg_id: ?u128 = null,
    last_msg_id: ?u128 = null,
    messages: []Message = &.{},

    pub fn deinit(self: *MessagePage, allocator: Allocator) void {
        if (self.messages.len > 0) {
            for (self.messages) |*m| m.deinit(allocator);
            allocator.free(self.messages);
            self.messages = &.{};
        }
    }

    pub fn encode(self: *const MessagePage, allocator: Allocator) Allocator.Error![]u8 {
        var w = codec.Writer{};
        defer w.deinit(allocator);
        try w.writeRaw(allocator, &PAGE_MAGIC);
        try w.writeU8(allocator, PAGE_FORMAT_VERSION);
        try w.writeU128(allocator, self.thread_id);
        if (self.prev_page) |p| {
            try w.writeU8(allocator, 1);
            try w.writeRaw(allocator, &p);
        } else {
            try w.writeU8(allocator, 0);
        }
        try w.writeOptU128(allocator, self.first_msg_id);
        try w.writeOptU128(allocator, self.last_msg_id);
        try w.writeVarint(allocator, self.messages.len);
        for (self.messages) |*m| {
            try m.encode(allocator, &w);
        }
        return try w.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, bytes: []const u8) !MessagePage {
        var r = codec.Reader.init(bytes);
        const magic = try r.readFixed(4);
        if (!std.mem.eql(u8, magic, &PAGE_MAGIC)) return error.InvalidPageMagic;
        const ver = try r.readU8();
        if (ver != PAGE_FORMAT_VERSION) return error.UnsupportedPageVersion;
        const tid = try r.readU128();
        const has_prev = try decodeFlag(&r);
        const prev_page: ?id.PageId = if (has_prev) (try r.readFixed(32)).* else null;
        const first_msg = try r.readOptU128();
        const last_msg = try r.readOptU128();
        const count = r.readCount(64, MAX_PAGE_MESSAGES) catch return error.CorruptRecord;
        const msgs: []Message = if (count > 0) try allocator.alloc(Message, count) else &.{};
        var decoded: usize = 0;
        errdefer {
            if (msgs.len > 0) {
                for (msgs[0..decoded]) |*m| m.deinit(allocator);
                allocator.free(msgs);
            }
        }
        for (0..count) |i| {
            msgs[i] = try Message.decode(allocator, &r);
            decoded += 1;
        }
        return .{
            .thread_id = tid,
            .prev_page = prev_page,
            .first_msg_id = first_msg,
            .last_msg_id = last_msg,
            .messages = msgs,
        };
    }
};

pub const ThreadUpdate = struct {
    title: ?[]u8 = null,
    default_provider: ?iface.ProviderId = null,
    default_model: ?[]u8 = null,
    status: ?SessionStatus = null,
    budget: ?Budget = null,
    updated_ms: u64,

    pub fn deinit(self: *ThreadUpdate, allocator: Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.default_model) |m| allocator.free(m);
        self.title = null;
        self.default_model = null;
    }

    pub fn clone(self: *const ThreadUpdate, allocator: Allocator) Allocator.Error!ThreadUpdate {
        const title = if (self.title) |t| try allocator.dupe(u8, t) else null;
        errdefer if (title) |t| allocator.free(t);
        const model = if (self.default_model) |m| try allocator.dupe(u8, m) else null;
        return .{
            .title = title,
            .default_provider = self.default_provider,
            .default_model = model,
            .status = self.status,
            .budget = self.budget,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const ThreadUpdate, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeOptBytes(allocator, self.title);
        if (self.default_provider) |p| {
            try w.writeU8(allocator, 1);
            try w.writeU8(allocator, @intFromEnum(p));
        } else {
            try w.writeU8(allocator, 0);
        }
        try w.writeOptBytes(allocator, self.default_model);
        if (self.status) |s| {
            try w.writeU8(allocator, 1);
            try w.writeU8(allocator, @intFromEnum(s));
        } else {
            try w.writeU8(allocator, 0);
        }
        if (self.budget) |*b| {
            try w.writeU8(allocator, 1);
            try b.encode(allocator, w);
        } else {
            try w.writeU8(allocator, 0);
        }
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ThreadUpdate {
        const title = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (title) |t| allocator.free(t);
        const prov: ?iface.ProviderId = if (try decodeFlag(r)) try decodeEnum(iface.ProviderId, r) else null;
        const model = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (model) |m| allocator.free(m);
        const status: ?SessionStatus = if (try decodeFlag(r)) try decodeEnum(SessionStatus, r) else null;
        const budget: ?Budget = if (try decodeFlag(r)) try Budget.decode(r) else null;
        const updated_ms = try r.readU64();
        return .{
            .title = title,
            .default_provider = prov,
            .default_model = model,
            .status = status,
            .budget = budget,
            .updated_ms = updated_ms,
        };
    }
};

pub const BindingsUpdate = struct {
    bindings: []SpaceBinding = &.{},
    updated_ms: u64,

    pub fn deinit(self: *BindingsUpdate, allocator: Allocator) void {
        freeBindings(allocator, self.bindings);
        self.bindings = &.{};
    }

    pub fn clone(self: *const BindingsUpdate, allocator: Allocator) Allocator.Error!BindingsUpdate {
        return .{
            .bindings = try cloneBindings(allocator, self.bindings),
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const BindingsUpdate, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try encodeBindings(allocator, w, self.bindings);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !BindingsUpdate {
        const bindings = try decodeBindings(allocator, r);
        errdefer freeBindings(allocator, bindings);
        const updated_ms = try r.readU64();
        return .{
            .bindings = bindings,
            .updated_ms = updated_ms,
        };
    }
};

pub const TriggerFired = struct {
    trigger_id: u128,
    fire_slot: u64,
    dedup_key: [32]u8,
    fired_ms: u64,
    runner_id: u128,

    pub fn encode(self: *const TriggerFired, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.trigger_id);
        try w.writeU64(allocator, self.fire_slot);
        try w.writeRaw(allocator, &self.dedup_key);
        try w.writeU64(allocator, self.fired_ms);
        try w.writeU128(allocator, self.runner_id);
    }

    pub fn decode(r: *codec.Reader) !TriggerFired {
        return .{
            .trigger_id = try r.readU128(),
            .fire_slot = try r.readU64(),
            .dedup_key = (try r.readFixed(32)).*,
            .fired_ms = try r.readU64(),
            .runner_id = try r.readU128(),
        };
    }
};

pub const RollbackSpaceDone = struct {
    intent_id: u128,
    space_id: u128,
    done_ms: u64,

    pub fn encode(self: *const RollbackSpaceDone, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.intent_id);
        try w.writeU128(allocator, self.space_id);
        try w.writeU64(allocator, self.done_ms);
    }

    pub fn decode(r: *codec.Reader) !RollbackSpaceDone {
        return .{
            .intent_id = try r.readU128(),
            .space_id = try r.readU128(),
            .done_ms = try r.readU64(),
        };
    }
};

pub const RollbackCommit = struct {
    intent_id: u128,
    committed_ms: u64,

    pub fn encode(self: *const RollbackCommit, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.intent_id);
        try w.writeU64(allocator, self.committed_ms);
    }

    pub fn decode(r: *codec.Reader) !RollbackCommit {
        return .{
            .intent_id = try r.readU128(),
            .committed_ms = try r.readU64(),
        };
    }
};

pub const CancelTree = struct {
    root_task_id: ?u128 = null,
    reason: ?[]u8 = null,
    canceled_ms: u64,

    pub fn deinit(self: *CancelTree, allocator: Allocator) void {
        if (self.reason) |r| allocator.free(r);
        self.reason = null;
    }

    pub fn clone(self: *const CancelTree, allocator: Allocator) Allocator.Error!CancelTree {
        return .{
            .root_task_id = self.root_task_id,
            .reason = if (self.reason) |r| try allocator.dupe(u8, r) else null,
            .canceled_ms = self.canceled_ms,
        };
    }

    pub fn encode(self: *const CancelTree, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeOptU128(allocator, self.root_task_id);
        try w.writeOptBytes(allocator, self.reason);
        try w.writeU64(allocator, self.canceled_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !CancelTree {
        const rtid = try r.readOptU128();
        const reason = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (reason) |x| allocator.free(x);
        const ms = try r.readU64();
        return .{
            .root_task_id = rtid,
            .reason = reason,
            .canceled_ms = ms,
        };
    }
};

pub const PageSealed = struct {
    page_id: id.PageId,
    prev_page: ?id.PageId = null,
    first_msg_id: u128,
    last_msg_id: u128,
    msg_count: u32,
    sealed_ms: u64,

    pub fn encode(self: *const PageSealed, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeRaw(allocator, &self.page_id);
        if (self.prev_page) |p| {
            try w.writeU8(allocator, 1);
            try w.writeRaw(allocator, &p);
        } else {
            try w.writeU8(allocator, 0);
        }
        try w.writeU128(allocator, self.first_msg_id);
        try w.writeU128(allocator, self.last_msg_id);
        try w.writeU32(allocator, self.msg_count);
        try w.writeU64(allocator, self.sealed_ms);
    }

    pub fn decode(r: *codec.Reader) !PageSealed {
        const pid = (try r.readFixed(32)).*;
        const has_prev = try decodeFlag(r);
        const prev: ?id.PageId = if (has_prev) (try r.readFixed(32)).* else null;
        return .{
            .page_id = pid,
            .prev_page = prev,
            .first_msg_id = try r.readU128(),
            .last_msg_id = try r.readU128(),
            .msg_count = try r.readU32(),
            .sealed_ms = try r.readU64(),
        };
    }
};

pub const ThreadEventTag = enum(u8) {
    thread_created = 1,
    thread_updated = 2,
    bindings_updated = 3,
    message_appended = 4,
    message_updated = 5,
    tool_call_put = 6,
    queue_enqueued = 7,
    queue_updated = 8,
    branch_choice_set = 9,
    task_created = 10,
    task_updated = 11,
    mailbox_received = 12,
    trigger_put = 13,
    trigger_fired = 14,
    rollback_begin = 15,
    rollback_space_done = 16,
    rollback_commit = 17,
    cancel_tree = 18,
    lease_observed = 19,
    page_sealed = 20,
};

pub const ThreadEvent = union(ThreadEventTag) {
    thread_created: ThreadMeta,
    thread_updated: ThreadUpdate,
    bindings_updated: BindingsUpdate,
    message_appended: Message,
    message_updated: Message,
    tool_call_put: ToolCallRecord,
    queue_enqueued: QueueItem,
    queue_updated: QueueItem,
    branch_choice_set: BranchChoice,
    task_created: Task,
    task_updated: Task,
    mailbox_received: MailboxItem,
    trigger_put: Trigger,
    trigger_fired: TriggerFired,
    rollback_begin: RollbackIntent,
    rollback_space_done: RollbackSpaceDone,
    rollback_commit: RollbackCommit,
    cancel_tree: CancelTree,
    lease_observed: ExecutionLeaseRef,
    page_sealed: PageSealed,

    pub fn deinit(self: *ThreadEvent, allocator: Allocator) void {
        switch (self.*) {
            .thread_created => |*v| v.deinit(allocator),
            .thread_updated => |*v| v.deinit(allocator),
            .bindings_updated => |*v| v.deinit(allocator),
            .message_appended => |*v| v.deinit(allocator),
            .message_updated => |*v| v.deinit(allocator),
            .tool_call_put => |*v| v.deinit(allocator),
            .queue_enqueued => |*v| v.deinit(allocator),
            .queue_updated => |*v| v.deinit(allocator),
            .branch_choice_set => {},
            .task_created => |*v| v.deinit(allocator),
            .task_updated => |*v| v.deinit(allocator),
            .mailbox_received => |*v| v.deinit(allocator),
            .trigger_put => |*v| v.deinit(allocator),
            .trigger_fired => {},
            .rollback_begin => |*v| v.deinit(allocator),
            .rollback_space_done => {},
            .rollback_commit => {},
            .cancel_tree => |*v| v.deinit(allocator),
            .lease_observed => {},
            .page_sealed => {},
        }
    }

    pub fn clone(self: *const ThreadEvent, allocator: Allocator) Allocator.Error!ThreadEvent {
        return switch (self.*) {
            .thread_created => |*v| .{ .thread_created = try v.clone(allocator) },
            .thread_updated => |*v| .{ .thread_updated = try v.clone(allocator) },
            .bindings_updated => |*v| .{ .bindings_updated = try v.clone(allocator) },
            .message_appended => |*v| .{ .message_appended = try v.clone(allocator) },
            .message_updated => |*v| .{ .message_updated = try v.clone(allocator) },
            .tool_call_put => |*v| .{ .tool_call_put = try v.clone(allocator) },
            .queue_enqueued => |*v| .{ .queue_enqueued = try v.clone(allocator) },
            .queue_updated => |*v| .{ .queue_updated = try v.clone(allocator) },
            .branch_choice_set => |v| .{ .branch_choice_set = v },
            .task_created => |*v| .{ .task_created = try v.clone(allocator) },
            .task_updated => |*v| .{ .task_updated = try v.clone(allocator) },
            .mailbox_received => |*v| .{ .mailbox_received = try v.clone(allocator) },
            .trigger_put => |*v| .{ .trigger_put = try v.clone(allocator) },
            .trigger_fired => |v| .{ .trigger_fired = v },
            .rollback_begin => |*v| .{ .rollback_begin = try v.clone(allocator) },
            .rollback_space_done => |v| .{ .rollback_space_done = v },
            .rollback_commit => |v| .{ .rollback_commit = v },
            .cancel_tree => |*v| .{ .cancel_tree = try v.clone(allocator) },
            .lease_observed => |v| .{ .lease_observed = v },
            .page_sealed => |v| .{ .page_sealed = v },
        };
    }

    pub fn encode(self: *const ThreadEvent, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU8(allocator, @intFromEnum(self.*));
        switch (self.*) {
            .thread_created => |*v| try v.encode(allocator, w),
            .thread_updated => |*v| try v.encode(allocator, w),
            .bindings_updated => |*v| try v.encode(allocator, w),
            .message_appended => |*v| try v.encode(allocator, w),
            .message_updated => |*v| try v.encode(allocator, w),
            .tool_call_put => |*v| try v.encode(allocator, w),
            .queue_enqueued => |*v| try v.encode(allocator, w),
            .queue_updated => |*v| try v.encode(allocator, w),
            .branch_choice_set => |*v| try v.encode(allocator, w),
            .task_created => |*v| try v.encode(allocator, w),
            .task_updated => |*v| try v.encode(allocator, w),
            .mailbox_received => |*v| try v.encode(allocator, w),
            .trigger_put => |*v| try v.encode(allocator, w),
            .trigger_fired => |*v| try v.encode(allocator, w),
            .rollback_begin => |*v| try v.encode(allocator, w),
            .rollback_space_done => |*v| try v.encode(allocator, w),
            .rollback_commit => |*v| try v.encode(allocator, w),
            .cancel_tree => |*v| try v.encode(allocator, w),
            .lease_observed => |*v| try v.encode(allocator, w),
            .page_sealed => |*v| try v.encode(allocator, w),
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ThreadEvent {
        const tag = try decodeEnum(ThreadEventTag, r);
        return switch (tag) {
            .thread_created => .{ .thread_created = try ThreadMeta.decode(allocator, r) },
            .thread_updated => .{ .thread_updated = try ThreadUpdate.decode(allocator, r) },
            .bindings_updated => .{ .bindings_updated = try BindingsUpdate.decode(allocator, r) },
            .message_appended => .{ .message_appended = try Message.decode(allocator, r) },
            .message_updated => .{ .message_updated = try Message.decode(allocator, r) },
            .tool_call_put => .{ .tool_call_put = try ToolCallRecord.decode(allocator, r) },
            .queue_enqueued => .{ .queue_enqueued = try QueueItem.decode(allocator, r) },
            .queue_updated => .{ .queue_updated = try QueueItem.decode(allocator, r) },
            .branch_choice_set => .{ .branch_choice_set = try BranchChoice.decode(r) },
            .task_created => .{ .task_created = try Task.decode(allocator, r) },
            .task_updated => .{ .task_updated = try Task.decode(allocator, r) },
            .mailbox_received => .{ .mailbox_received = try MailboxItem.decode(allocator, r) },
            .trigger_put => .{ .trigger_put = try Trigger.decode(allocator, r) },
            .trigger_fired => .{ .trigger_fired = try TriggerFired.decode(r) },
            .rollback_begin => .{ .rollback_begin = try RollbackIntent.decode(allocator, r) },
            .rollback_space_done => .{ .rollback_space_done = try RollbackSpaceDone.decode(r) },
            .rollback_commit => .{ .rollback_commit = try RollbackCommit.decode(r) },
            .cancel_tree => .{ .cancel_tree = try CancelTree.decode(allocator, r) },
            .lease_observed => .{ .lease_observed = try ExecutionLeaseRef.decode(r) },
            .page_sealed => .{ .page_sealed = try PageSealed.decode(r) },
        };
    }
};

pub const CausalEvent = struct {
    event_id: u128,
    lamport: u64,
    actor: u128,
    event: ThreadEvent,

    pub fn deinit(self: *CausalEvent, allocator: Allocator) void {
        self.event.deinit(allocator);
    }

    pub fn clone(self: *const CausalEvent, allocator: Allocator) Allocator.Error!CausalEvent {
        return .{
            .event_id = self.event_id,
            .lamport = self.lamport,
            .actor = self.actor,
            .event = try self.event.clone(allocator),
        };
    }

    pub fn encode(self: *const CausalEvent, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU8(allocator, EVENT_FORMAT_VERSION);
        try w.writeU128(allocator, self.event_id);
        try w.writeU64(allocator, self.lamport);
        try w.writeU128(allocator, self.actor);
        try self.event.encode(allocator, w);
    }

    pub fn encodeAlloc(self: *const CausalEvent, allocator: Allocator) Allocator.Error![]u8 {
        var w = codec.Writer{};
        defer w.deinit(allocator);
        try self.encode(allocator, &w);
        return try w.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !CausalEvent {
        const ver = try r.readU8();
        if (ver != EVENT_FORMAT_VERSION) return error.UnsupportedVersion;
        const event_id = try r.readU128();
        const lamport = try r.readU64();
        const actor = try r.readU128();
        const event = try ThreadEvent.decode(allocator, r);
        return .{
            .event_id = event_id,
            .lamport = lamport,
            .actor = actor,
            .event = event,
        };
    }

    pub fn decodeSlice(allocator: Allocator, bytes: []const u8) !CausalEvent {
        var r = codec.Reader.init(bytes);
        return try decode(allocator, &r);
    }
};

pub const RunnerKind = enum(u8) {
    laptop = 0,
    phone = 1,
    cloud = 2,
    desktop = 3,
};

pub fn lwwWins(new_ms: u64, new_actor: u128, old_ms: u64, old_actor: u128) bool {
    if (new_ms != old_ms) return new_ms > old_ms;
    return new_actor >= old_actor;
}

pub const ProjectSummary = struct {
    project_id: u128,
    name: []u8,
    space_ids: []u128 = &.{},
    default_provider: iface.ProviderId = .claude_code,
    deleted: bool = false,
    updated_ms: u64,
    actor: u128,

    pub fn deinit(self: *ProjectSummary, allocator: Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.space_ids.len > 0) allocator.free(self.space_ids);
        self.name = &.{};
        self.space_ids = &.{};
    }

    pub fn clone(self: *const ProjectSummary, allocator: Allocator) Allocator.Error!ProjectSummary {
        const name: []u8 = if (self.name.len > 0) try allocator.dupe(u8, self.name) else &.{};
        errdefer if (name.len > 0) allocator.free(name);
        const sids: []u128 = if (self.space_ids.len > 0) try allocator.dupe(u128, self.space_ids) else &.{};
        return .{
            .project_id = self.project_id,
            .name = name,
            .space_ids = sids,
            .default_provider = self.default_provider,
            .deleted = self.deleted,
            .updated_ms = self.updated_ms,
            .actor = self.actor,
        };
    }

    pub fn encode(self: *const ProjectSummary, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.project_id);
        try w.writeBytes(allocator, self.name);
        try w.writeVarint(allocator, self.space_ids.len);
        for (self.space_ids) |sid| try w.writeU128(allocator, sid);
        try w.writeU8(allocator, @intFromEnum(self.default_provider));
        try w.writeBool(allocator, self.deleted);
        try w.writeU64(allocator, self.updated_ms);
        try w.writeU128(allocator, self.actor);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ProjectSummary {
        const project_id = try r.readU128();
        const raw_name = try readBytesCapped(r, MAX_SHORT_STR);
        const name: []u8 = if (raw_name.len > 0) try allocator.dupe(u8, raw_name) else &.{};
        errdefer if (name.len > 0) allocator.free(name);
        const scount = r.readCount(16, MAX_BINDINGS) catch return error.CorruptRecord;
        const sids: []u128 = if (scount > 0) try allocator.alloc(u128, scount) else &.{};
        errdefer if (sids.len > 0) allocator.free(sids);
        for (0..scount) |i| sids[i] = try r.readU128();
        const prov = try decodeEnum(iface.ProviderId, r);
        const deleted = try decodeFlag(r);
        const updated_ms = try r.readU64();
        const actor = try r.readU128();
        return .{
            .project_id = project_id,
            .name = name,
            .space_ids = sids,
            .default_provider = prov,
            .deleted = deleted,
            .updated_ms = updated_ms,
            .actor = actor,
        };
    }
};

pub const SpaceSummary = struct {
    space_id: u128,
    name: []u8,
    kind: SpaceKind,
    vcs_kind: vcs.VcsKind = .none,
    local_path: ?[]u8 = null,
    remote_url: ?[]u8 = null,
    deleted: bool = false,
    updated_ms: u64,
    actor: u128,

    pub fn deinit(self: *SpaceSummary, allocator: Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.local_path) |p| allocator.free(p);
        if (self.remote_url) |u| allocator.free(u);
        self.name = &.{};
        self.local_path = null;
        self.remote_url = null;
    }

    pub fn clone(self: *const SpaceSummary, allocator: Allocator) Allocator.Error!SpaceSummary {
        const name: []u8 = if (self.name.len > 0) try allocator.dupe(u8, self.name) else &.{};
        errdefer if (name.len > 0) allocator.free(name);
        const lp = if (self.local_path) |p| try allocator.dupe(u8, p) else null;
        errdefer if (lp) |p| allocator.free(p);
        const ru = if (self.remote_url) |u| try allocator.dupe(u8, u) else null;
        return .{
            .space_id = self.space_id,
            .name = name,
            .kind = self.kind,
            .vcs_kind = self.vcs_kind,
            .local_path = lp,
            .remote_url = ru,
            .deleted = self.deleted,
            .updated_ms = self.updated_ms,
            .actor = self.actor,
        };
    }

    pub fn encode(self: *const SpaceSummary, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.space_id);
        try w.writeBytes(allocator, self.name);
        try w.writeU8(allocator, @intFromEnum(self.kind));
        try w.writeU8(allocator, @intFromEnum(self.vcs_kind));
        try w.writeOptBytes(allocator, self.local_path);
        try w.writeOptBytes(allocator, self.remote_url);
        try w.writeBool(allocator, self.deleted);
        try w.writeU64(allocator, self.updated_ms);
        try w.writeU128(allocator, self.actor);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !SpaceSummary {
        const space_id = try r.readU128();
        const raw_name = try readBytesCapped(r, MAX_SHORT_STR);
        const name: []u8 = if (raw_name.len > 0) try allocator.dupe(u8, raw_name) else &.{};
        errdefer if (name.len > 0) allocator.free(name);
        const kind = try decodeEnum(SpaceKind, r);
        const vcs_kind = try decodeEnum(vcs.VcsKind, r);
        const lp = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (lp) |p| allocator.free(p);
        const ru = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (ru) |u| allocator.free(u);
        const deleted = try decodeFlag(r);
        const updated_ms = try r.readU64();
        const actor = try r.readU128();
        return .{
            .space_id = space_id,
            .name = name,
            .kind = kind,
            .vcs_kind = vcs_kind,
            .local_path = lp,
            .remote_url = ru,
            .deleted = deleted,
            .updated_ms = updated_ms,
            .actor = actor,
        };
    }
};

pub const ThreadSummary = struct {
    thread_id: u128,
    project_id: ?u128 = null,
    parent_thread_id: ?u128 = null,
    root_thread_id: u128,
    title: []u8,
    provider: iface.ProviderId,
    model: ?[]u8 = null,
    status: SessionStatus = .idle,
    message_count: u32 = 0,
    active_tasks: u32 = 0,
    unread_mailbox: u32 = 0,
    deleted: bool = false,
    updated_ms: u64,
    actor: u128,

    pub fn deinit(self: *ThreadSummary, allocator: Allocator) void {
        if (self.title.len > 0) allocator.free(self.title);
        if (self.model) |m| allocator.free(m);
        self.title = &.{};
        self.model = null;
    }

    pub fn clone(self: *const ThreadSummary, allocator: Allocator) Allocator.Error!ThreadSummary {
        const title: []u8 = if (self.title.len > 0) try allocator.dupe(u8, self.title) else &.{};
        errdefer if (title.len > 0) allocator.free(title);
        const model = if (self.model) |m| try allocator.dupe(u8, m) else null;
        return .{
            .thread_id = self.thread_id,
            .project_id = self.project_id,
            .parent_thread_id = self.parent_thread_id,
            .root_thread_id = self.root_thread_id,
            .title = title,
            .provider = self.provider,
            .model = model,
            .status = self.status,
            .message_count = self.message_count,
            .active_tasks = self.active_tasks,
            .unread_mailbox = self.unread_mailbox,
            .deleted = self.deleted,
            .updated_ms = self.updated_ms,
            .actor = self.actor,
        };
    }

    pub fn encode(self: *const ThreadSummary, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.thread_id);
        try w.writeOptU128(allocator, self.project_id);
        try w.writeOptU128(allocator, self.parent_thread_id);
        try w.writeU128(allocator, self.root_thread_id);
        try w.writeBytes(allocator, self.title);
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeOptBytes(allocator, self.model);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeU32(allocator, self.message_count);
        try w.writeU32(allocator, self.active_tasks);
        try w.writeU32(allocator, self.unread_mailbox);
        try w.writeBool(allocator, self.deleted);
        try w.writeU64(allocator, self.updated_ms);
        try w.writeU128(allocator, self.actor);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ThreadSummary {
        const thread_id = try r.readU128();
        const project_id = try r.readOptU128();
        const parent_tid = try r.readOptU128();
        const root_tid = try r.readU128();
        const raw_title = try readBytesCapped(r, MAX_SHORT_STR);
        const title: []u8 = if (raw_title.len > 0) try allocator.dupe(u8, raw_title) else &.{};
        errdefer if (title.len > 0) allocator.free(title);
        const prov = try decodeEnum(iface.ProviderId, r);
        const model = try readOptBytesAllocCapped(allocator, r, MAX_SHORT_STR);
        errdefer if (model) |m| allocator.free(m);
        const status = try decodeEnum(SessionStatus, r);
        const msg_count = try r.readU32();
        const active_tasks = try r.readU32();
        const unread_mailbox = try r.readU32();
        const deleted = try decodeFlag(r);
        const updated_ms = try r.readU64();
        const actor = try r.readU128();
        return .{
            .thread_id = thread_id,
            .project_id = project_id,
            .parent_thread_id = parent_tid,
            .root_thread_id = root_tid,
            .title = title,
            .provider = prov,
            .model = model,
            .status = status,
            .message_count = msg_count,
            .active_tasks = active_tasks,
            .unread_mailbox = unread_mailbox,
            .deleted = deleted,
            .updated_ms = updated_ms,
            .actor = actor,
        };
    }
};

pub const RunnerInfo = struct {
    runner_id: u128,
    name: []u8,
    kind: RunnerKind,
    x25519_pub: [32]u8,
    last_seen_ms: u64,
    capabilities_flags: u64 = 0,
    updated_ms: u64,
    actor: u128,

    pub fn deinit(self: *RunnerInfo, allocator: Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        self.name = &.{};
    }

    pub fn clone(self: *const RunnerInfo, allocator: Allocator) Allocator.Error!RunnerInfo {
        const name: []u8 = if (self.name.len > 0) try allocator.dupe(u8, self.name) else &.{};
        return .{
            .runner_id = self.runner_id,
            .name = name,
            .kind = self.kind,
            .x25519_pub = self.x25519_pub,
            .last_seen_ms = self.last_seen_ms,
            .capabilities_flags = self.capabilities_flags,
            .updated_ms = self.updated_ms,
            .actor = self.actor,
        };
    }

    pub fn encode(self: *const RunnerInfo, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.runner_id);
        try w.writeBytes(allocator, self.name);
        try w.writeU8(allocator, @intFromEnum(self.kind));
        try w.writeRaw(allocator, &self.x25519_pub);
        try w.writeU64(allocator, self.last_seen_ms);
        try w.writeU64(allocator, self.capabilities_flags);
        try w.writeU64(allocator, self.updated_ms);
        try w.writeU128(allocator, self.actor);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !RunnerInfo {
        const runner_id = try r.readU128();
        const raw_name = try readBytesCapped(r, MAX_SHORT_STR);
        const name: []u8 = if (raw_name.len > 0) try allocator.dupe(u8, raw_name) else &.{};
        errdefer if (name.len > 0) allocator.free(name);
        const kind = try decodeEnum(RunnerKind, r);
        const x25519_pub = (try r.readFixed(32)).*;
        const last_seen_ms = try r.readU64();
        const caps = try r.readU64();
        const updated_ms = try r.readU64();
        const actor = try r.readU128();
        return .{
            .runner_id = runner_id,
            .name = name,
            .kind = kind,
            .x25519_pub = x25519_pub,
            .last_seen_ms = last_seen_ms,
            .capabilities_flags = caps,
            .updated_ms = updated_ms,
            .actor = actor,
        };
    }
};

pub const CatalogEntryTag = enum(u8) {
    project = 1,
    space = 2,
    thread = 3,
    runner = 4,
};

pub const CatalogEntry = union(CatalogEntryTag) {
    project: ProjectSummary,
    space: SpaceSummary,
    thread: ThreadSummary,
    runner: RunnerInfo,

    pub fn deinit(self: *CatalogEntry, allocator: Allocator) void {
        switch (self.*) {
            .project => |*v| v.deinit(allocator),
            .space => |*v| v.deinit(allocator),
            .thread => |*v| v.deinit(allocator),
            .runner => |*v| v.deinit(allocator),
        }
    }

    pub fn clone(self: *const CatalogEntry, allocator: Allocator) Allocator.Error!CatalogEntry {
        return switch (self.*) {
            .project => |*v| .{ .project = try v.clone(allocator) },
            .space => |*v| .{ .space = try v.clone(allocator) },
            .thread => |*v| .{ .thread = try v.clone(allocator) },
            .runner => |*v| .{ .runner = try v.clone(allocator) },
        };
    }

    pub fn encode(self: *const CatalogEntry, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU8(allocator, CATALOG_FORMAT_VERSION);
        try w.writeU8(allocator, @intFromEnum(self.*));
        switch (self.*) {
            .project => |*v| try v.encode(allocator, w),
            .space => |*v| try v.encode(allocator, w),
            .thread => |*v| try v.encode(allocator, w),
            .runner => |*v| try v.encode(allocator, w),
        }
    }

    pub fn encodeAlloc(self: *const CatalogEntry, allocator: Allocator) Allocator.Error![]u8 {
        var w = codec.Writer{};
        defer w.deinit(allocator);
        try self.encode(allocator, &w);
        return try w.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !CatalogEntry {
        const ver = try r.readU8();
        if (ver != CATALOG_FORMAT_VERSION) return error.UnsupportedVersion;
        const tag = try decodeEnum(CatalogEntryTag, r);
        return switch (tag) {
            .project => .{ .project = try ProjectSummary.decode(allocator, r) },
            .space => .{ .space = try SpaceSummary.decode(allocator, r) },
            .thread => .{ .thread = try ThreadSummary.decode(allocator, r) },
            .runner => .{ .runner = try RunnerInfo.decode(allocator, r) },
        };
    }

    pub fn decodeSlice(allocator: Allocator, bytes: []const u8) !CatalogEntry {
        var r = codec.Reader.init(bytes);
        return try decode(allocator, &r);
    }
};
