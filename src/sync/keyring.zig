const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const crypto = @import("../store/crypto.zig");
const mmap = @import("../store/mmap.zig");
const wire = @import("wire.zig");

const KEYRING_MAGIC: [8]u8 = .{ '0', 'N', 'D', 'B', 'K', 'R', 'G', '3' };
const KEYRING_VERSION: u32 = 3;
const KEYRING_HEADER_LEN: usize = 8 + 4 + 16 + 1 + 32 + 32 + 4;
const TOPIC_ENTRY_FIXED_LEN: usize = 32 + 32 + 4 + 4 + 4 + 8 + 4;
const MAX_KEYRING_TOPICS: usize = 65536;
const MAX_TOKEN_LEN: usize = 65536;

pub const TopicKeyEntry = struct {
    entity_key: crypto.EntityKey,
    min_active_epoch: u32,
    perms: u32,
    expires_ms: u64,
    token: []u8,

    pub fn deinit(self: *TopicKeyEntry, allocator: Allocator) void {
        self.entity_key.zeroize();
        self.min_active_epoch = 0;
        self.perms = 0;
        self.expires_ms = 0;
        if (self.token.len > 0) {
            crypto.zeroize(self.token);
            allocator.free(self.token);
        }
        self.token = &.{};
    }
};

pub const TopicGrantView = struct {
    entity_key: crypto.EntityKey,
    min_active_epoch: u32,
    perms: u32,
    expires_ms: u64,
    token: []const u8,
};

pub const DelegationRequest = struct {
    topic_id: [32]u8,
    perms: u32,
    expires_ms: u64,
    token: []const u8 = &.{},
};

pub const Keyring = struct {
    allocator: Allocator,
    io: Io,
    account_root_key: ?crypto.AccountRootKey,
    device_keypair: crypto.DeviceKeypair,
    runner_id: u128,
    topics: std.AutoHashMapUnmanaged([32]u8, TopicKeyEntry),

    pub fn initAccountDevice(
        allocator: Allocator,
        io: Io,
        root_key: crypto.AccountRootKey,
        runner_id: u128,
    ) Keyring {
        return .{
            .allocator = allocator,
            .io = io,
            .account_root_key = root_key,
            .device_keypair = crypto.DeviceKeypair.generate(io),
            .runner_id = runner_id,
            .topics = .empty,
        };
    }

    pub fn initSubordinateDevice(
        allocator: Allocator,
        io: Io,
        runner_id: u128,
    ) Keyring {
        return .{
            .allocator = allocator,
            .io = io,
            .account_root_key = null,
            .device_keypair = crypto.DeviceKeypair.generate(io),
            .runner_id = runner_id,
            .topics = .empty,
        };
    }

    pub fn deinit(self: *Keyring) void {
        if (self.account_root_key != null) {
            self.account_root_key.?.zeroize();
            self.account_root_key = null;
        }
        self.device_keypair.zeroize();
        var it = self.topics.valueIterator();
        while (it.next()) |entry| {
            entry.deinit(self.allocator);
        }
        self.topics.deinit(self.allocator);
    }

    pub fn setEntityKey(self: *Keyring, topic_id: [32]u8, entity_key: crypto.EntityKey) !void {
        const gop = try self.topics.getOrPut(self.allocator, topic_id);
        if (gop.found_existing) {
            if (entity_key.epoch < gop.value_ptr.min_active_epoch) {
                return error.EpochDowngrade;
            }
            gop.value_ptr.entity_key.zeroize();
            gop.value_ptr.entity_key = entity_key;
            gop.value_ptr.min_active_epoch = entity_key.epoch;
        } else {
            gop.value_ptr.* = .{
                .entity_key = entity_key,
                .min_active_epoch = entity_key.epoch,
                .perms = wire.PERM_ALL_V3,
                .expires_ms = 0,
                .token = &.{},
            };
        }
    }

    pub fn setTopicGrant(
        self: *Keyring,
        topic_id: [32]u8,
        entity_key: crypto.EntityKey,
        perms: u32,
        expires_ms: u64,
        token: []const u8,
    ) !void {
        if (perms == 0 or (perms & ~wire.PERM_ALL_V3) != 0) return error.InvalidPermissions;
        if (token.len > MAX_TOKEN_LEN) return error.TokenTooLarge;
        const duped: []u8 = if (token.len > 0) try self.allocator.dupe(u8, token) else &.{};
        errdefer if (duped.len > 0) {
            crypto.zeroize(duped);
            self.allocator.free(duped);
        };

        const gop = try self.topics.getOrPut(self.allocator, topic_id);
        if (gop.found_existing) {
            if (entity_key.epoch < gop.value_ptr.min_active_epoch) {
                return error.EpochDowngrade;
            }
            gop.value_ptr.deinit(self.allocator);
        }
        gop.value_ptr.* = .{
            .entity_key = entity_key,
            .min_active_epoch = entity_key.epoch,
            .perms = perms,
            .expires_ms = expires_ms,
            .token = duped,
        };
    }

    pub fn getEntityKey(self: *const Keyring, topic_id: [32]u8) ?crypto.EntityKey {
        const entry = self.topics.get(topic_id) orelse return null;
        return entry.entity_key;
    }

    pub fn getEntityKeyForEpoch(self: *const Keyring, topic_id: [32]u8, epoch: u32) ?crypto.EntityKey {
        const entry = self.topics.get(topic_id) orelse return null;
        if (epoch < entry.min_active_epoch or epoch != entry.entity_key.epoch) return null;
        return entry.entity_key;
    }

    pub fn getTopicGrant(self: *const Keyring, topic_id: [32]u8) ?TopicGrantView {
        const entry = self.topics.get(topic_id) orelse return null;
        return .{
            .entity_key = entry.entity_key,
            .min_active_epoch = entry.min_active_epoch,
            .perms = entry.perms,
            .expires_ms = entry.expires_ms,
            .token = entry.token,
        };
    }

    pub fn rotateEntityKey(self: *Keyring, topic_id: [32]u8) !crypto.EntityKey {
        const entry = self.topics.getPtr(topic_id) orelse return error.TopicNotFound;
        const next_epoch = std.math.add(u32, entry.entity_key.epoch, 1) catch return error.EpochOverflow;
        const next_key = crypto.EntityKey.generate(self.io, next_epoch);
        entry.entity_key.zeroize();
        entry.entity_key = next_key;
        entry.min_active_epoch = next_epoch;
        return next_key;
    }

    pub fn buildDelegationBundle(
        self: *const Keyring,
        allocator: Allocator,
        target_runner: u128,
        bundle_expires_ms: u64,
        requests: []const DelegationRequest,
    ) !crypto.DelegationBundle {
        const now_ms = id.nowMs(self.io);
        if (bundle_expires_ms != 0 and bundle_expires_ms <= now_ms) {
            return error.GrantExpired;
        }
        if (requests.len > crypto.DelegationBundle.MAX_GRANTS) {
            return error.TooManyGrants;
        }

        const grants = try allocator.alloc(crypto.DelegationGrant, requests.len);
        var built: usize = 0;
        errdefer {
            for (grants[0..built]) |*g| g.deinit(allocator);
            allocator.free(grants);
        }

        for (requests, 0..) |req, i| {
            const entry = self.topics.get(req.topic_id) orelse return error.TopicNotFound;
            if (entry.expires_ms != 0 and now_ms > entry.expires_ms) {
                return error.GrantExpired;
            }
            if (req.perms == 0 or (req.perms & ~wire.PERM_ALL_V3) != 0) {
                return error.InvalidPermissions;
            }
            if ((req.perms & ~entry.perms) != 0) {
                return error.PrivilegeEscalation;
            }

            if (entry.expires_ms != 0) {
                if (bundle_expires_ms == 0 or bundle_expires_ms > entry.expires_ms) {
                    return error.ExpiryEscalation;
                }
                if (req.expires_ms == 0 or req.expires_ms > entry.expires_ms) {
                    return error.ExpiryEscalation;
                }
            }
            if (req.expires_ms != 0) {
                if (req.expires_ms <= now_ms) return error.GrantExpired;
                if (bundle_expires_ms != 0 and req.expires_ms > bundle_expires_ms) {
                    return error.ExpiryEscalation;
                }
            }

            const src_tok = if (req.token.len > 0) req.token else entry.token;
            if (src_tok.len > MAX_TOKEN_LEN) return error.TokenTooLarge;
            const duped_tok: []u8 = if (src_tok.len > 0) try allocator.dupe(u8, src_tok) else &.{};

            grants[i] = .{
                .topic_id = req.topic_id,
                .entity_key = entry.entity_key,
                .perms = req.perms,
                .expires_ms = req.expires_ms,
                .token = duped_tok,
            };
            built += 1;
        }

        return .{
            .issued_by_runner = self.runner_id,
            .target_runner = target_runner,
            .issued_ms = now_ms,
            .expires_ms = bundle_expires_ms,
            .grants = grants,
        };
    }

    pub fn createDelegationBundle(
        self: *const Keyring,
        allocator: Allocator,
        target_runner: u128,
        target_pubkey: [32]u8,
        bundle_expires_ms: u64,
        requests: []const DelegationRequest,
    ) ![]u8 {
        var bundle = try self.buildDelegationBundle(allocator, target_runner, bundle_expires_ms, requests);
        defer bundle.deinit(allocator);
        return bundle.sealForDevice(allocator, self.io, target_pubkey);
    }

    pub fn importDelegationBundle(self: *Keyring, sealed: []const u8) !usize {
        var bundle = try crypto.DelegationBundle.openForDevice(
            self.allocator,
            self.device_keypair.secret_key,
            self.runner_id,
            sealed,
        );
        defer bundle.deinit(self.allocator);

        const now_ms = id.nowMs(self.io);
        if (bundle.expires_ms != 0 and now_ms > bundle.expires_ms) {
            return error.BundleExpired;
        }

        for (bundle.grants) |g| {
            if (g.expires_ms != 0 and now_ms > g.expires_ms) {
                return error.GrantExpired;
            }
            if (g.perms == 0 or (g.perms & ~wire.PERM_ALL_V3) != 0) {
                return error.InvalidPermissions;
            }
            if (self.topics.get(g.topic_id)) |existing| {
                if (g.entity_key.epoch < existing.min_active_epoch) {
                    return error.EpochDowngrade;
                }
            }
        }

        for (bundle.grants) |g| {
            const eff_exp: u64 = blk: {
                if (bundle.expires_ms == 0) break :blk g.expires_ms;
                if (g.expires_ms == 0) break :blk bundle.expires_ms;
                break :blk @min(bundle.expires_ms, g.expires_ms);
            };
            try self.setTopicGrant(g.topic_id, g.entity_key, g.perms, eff_exp, g.token);
        }
        return bundle.grants.len;
    }

    pub fn exportWrappedForAccount(self: *const Keyring, allocator: Allocator, topic_id: [32]u8) ![]u8 {
        const root = self.account_root_key orelse return error.MissingAccountRootKey;
        const entry = self.topics.get(topic_id) orelse return error.TopicNotFound;
        return crypto.wrapEntityKeyForAccount(allocator, self.io, &root, topic_id, &entry.entity_key);
    }

    pub fn importWrappedForAccount(self: *Keyring, topic_id: [32]u8, wrapped: []const u8) !crypto.EntityKey {
        const root = self.account_root_key orelse return error.MissingAccountRootKey;
        const ek = try crypto.unwrapEntityKeyForAccount(self.allocator, &root, topic_id, wrapped);
        try self.setEntityKey(topic_id, ek);
        return ek;
    }

    pub fn saveAtomic(self: *const Keyring, dir: Io.Dir, filename: []const u8) !void {
        var total_len: usize = KEYRING_HEADER_LEN + 32;
        var it_sz = self.topics.valueIterator();
        while (it_sz.next()) |entry| {
            total_len += TOPIC_ENTRY_FIXED_LEN + entry.token.len;
        }

        const buf = try self.allocator.alloc(u8, total_len);
        defer {
            crypto.zeroize(buf);
            self.allocator.free(buf);
        }

        var pos: usize = 0;
        @memcpy(buf[pos..][0..8], &KEYRING_MAGIC);
        pos += 8;
        std.mem.writeInt(u32, buf[pos..][0..4], KEYRING_VERSION, .little);
        pos += 4;
        std.mem.writeInt(u128, buf[pos..][0..16], self.runner_id, .little);
        pos += 16;
        if (self.account_root_key) |rk| {
            buf[pos] = 1;
            pos += 1;
            @memcpy(buf[pos..][0..32], &rk.bytes);
            pos += 32;
        } else {
            buf[pos] = 0;
            pos += 1;
            @memset(buf[pos..][0..32], 0);
            pos += 32;
        }
        @memcpy(buf[pos..][0..32], &self.device_keypair.secret_key);
        pos += 32;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(self.topics.count()), .little);
        pos += 4;

        var it = self.topics.iterator();
        while (it.next()) |kv| {
            @memcpy(buf[pos..][0..32], kv.key_ptr);
            pos += 32;
            const e = kv.value_ptr;
            @memcpy(buf[pos..][0..32], &e.entity_key.key);
            pos += 32;
            std.mem.writeInt(u32, buf[pos..][0..4], e.entity_key.epoch, .little);
            pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], e.min_active_epoch, .little);
            pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], e.perms, .little);
            pos += 4;
            std.mem.writeInt(u64, buf[pos..][0..8], e.expires_ms, .little);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(e.token.len), .little);
            pos += 4;
            if (e.token.len > 0) {
                @memcpy(buf[pos .. pos + e.token.len], e.token);
                pos += e.token.len;
            }
        }

        const digest = crypto.hashBytes(buf[0..pos]);
        @memcpy(buf[pos..][0..32], &digest);

        try mmap.atomicWriteFile(self.io, dir, filename, buf);
    }

    pub fn load(allocator: Allocator, io: Io, dir: Io.Dir, filename: []const u8) !Keyring {
        const f = try dir.openFile(io, filename, .{});
        defer f.close(io);
        const st = try f.stat(io);
        const file_len: usize = @intCast(st.size);
        if (file_len < KEYRING_HEADER_LEN + 32) return error.CorruptKeyring;

        const raw = try allocator.alloc(u8, file_len);
        defer {
            crypto.zeroize(raw);
            allocator.free(raw);
        }
        const n = try f.readPositionalAll(io, raw, 0);
        if (n != file_len) return error.CorruptKeyring;

        const payload_end = file_len - 32;
        const expected = crypto.hashBytes(raw[0..payload_end]);
        if (!std.crypto.timing_safe.eql([32]u8, expected, raw[payload_end..][0..32].*)) {
            return error.CorruptKeyring;
        }

        if (!std.mem.eql(u8, raw[0..8], &KEYRING_MAGIC)) return error.CorruptKeyring;
        const version = std.mem.readInt(u32, raw[8..12], .little);
        if (version != KEYRING_VERSION) return error.CorruptKeyring;

        var pos: usize = 12;
        const runner_id = std.mem.readInt(u128, raw[pos..][0..16], .little);
        pos += 16;
        const has_root = raw[pos];
        pos += 1;
        if (has_root > 1) return error.CorruptKeyring;
        const root_bytes: [32]u8 = raw[pos..][0..32].*;
        pos += 32;
        const dev_secret: [32]u8 = raw[pos..][0..32].*;
        pos += 32;
        const topic_count = std.mem.readInt(u32, raw[pos..][0..4], .little);
        pos += 4;

        if (topic_count > MAX_KEYRING_TOPICS) return error.CorruptKeyring;

        var kr = Keyring{
            .allocator = allocator,
            .io = io,
            .account_root_key = if (has_root == 1) crypto.AccountRootKey.fromBytes(root_bytes) else null,
            .device_keypair = crypto.DeviceKeypair.fromSecret(dev_secret),
            .runner_id = runner_id,
            .topics = .empty,
        };
        errdefer kr.deinit();

        for (0..topic_count) |_| {
            if (payload_end - pos < TOPIC_ENTRY_FIXED_LEN) return error.CorruptKeyring;
            const tid: [32]u8 = raw[pos..][0..32].*;
            pos += 32;
            const ek_bytes: [32]u8 = raw[pos..][0..32].*;
            pos += 32;
            const epoch = std.mem.readInt(u32, raw[pos..][0..4], .little);
            pos += 4;
            const min_epoch = std.mem.readInt(u32, raw[pos..][0..4], .little);
            pos += 4;
            const perms = std.mem.readInt(u32, raw[pos..][0..4], .little);
            pos += 4;
            const expires_ms = std.mem.readInt(u64, raw[pos..][0..8], .little);
            pos += 8;
            const tok_len = std.mem.readInt(u32, raw[pos..][0..4], .little);
            pos += 4;
            if (tok_len > MAX_TOKEN_LEN or payload_end - pos < tok_len) return error.CorruptKeyring;
            const tok: []u8 = if (tok_len > 0) try allocator.dupe(u8, raw[pos .. pos + tok_len]) else &.{};
            pos += tok_len;

            try kr.topics.put(allocator, tid, .{
                .entity_key = .{ .key = ek_bytes, .epoch = epoch },
                .min_active_epoch = min_epoch,
                .perms = perms,
                .expires_ms = expires_ms,
                .token = tok,
            });
        }
        if (pos != payload_end) return error.CorruptKeyring;
        return kr;
    }
};
