const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const dag_mod = @import("../core/dag.zig");
const diff = @import("../core/diff.zig");
const text_mod = @import("../core/text.zig");
const tree_mod = @import("../core/tree.zig");
const op_mod = @import("../core/op.zig");
const history_mod = @import("../core/history.zig");
const History = history_mod.History;
const codec = @import("../store/codec.zig");
const crypto = @import("../store/crypto.zig");
const mmap = @import("../store/mmap.zig");
const log_mod = @import("../store/log.zig");
const blobs_mod = @import("../store/blobs.zig");
const manifest_mod = @import("../store/manifest.zig");
const segments_mod = @import("../store/segments.zig");
const shadow_mod = @import("../store/shadow.zig");
const snapshot_mod = @import("../store/snapshot.zig");
const git_dirs_mod = @import("git_dirs.zig");
const git_index_mod = @import("git_index.zig");
const git_odb_mod = @import("git_odb.zig");
const pool_mod = @import("pool.zig");
const watch = @import("watch.zig");

pub const FRAME_BATCH: u8 = 1;
pub const FRAME_SCOPE: u8 = 2;
pub const FRAME_SCOPE_BATCH: u8 = 3;
pub const FRAME_SCOPE_END: u8 = 4;
pub const DEFAULT_MAX_FILE_SIZE: u64 = 16 * 1024 * 1024;
pub const SHADOW_FILE_NAME: []const u8 = "shadow.0ndb";
pub const AUTO_MINOR_WAL_BATCHES: usize = 256;
pub const AUTO_MINOR_WAL_BYTES: u64 = 8 * 1024 * 1024;
pub const AUTO_MINOR_DIRTY_INODES: usize = 4096;
pub const AUTO_MAJOR_DELTA_BYTES: u64 = 16 * 1024 * 1024;

pub const CheckpointKind = enum {
    minor,
    major,
};

pub const CompactPolicy = struct {
    retain_latest_batches: usize = 0,
    retain_ms: u64 = 0,
    force_gc: bool = true,
};

pub const CompactStats = struct {
    pruned_batches: usize = 0,
    reclaimed_batch_bytes: u64 = 0,
    removed_blobs: usize = 0,
    reclaimed_blob_bytes: u64 = 0,
    removed_segments: u32 = 0,
    rewritten_segments: u32 = 0,
    base_size_bytes: u64 = 0,
};

pub const MaterializeOptions = struct {
    force: bool = false,
};

pub const ScopeKind = enum(u8) {
    turn = 1,
    tool_call = 2,
    manual = 3,
    checkpoint = 4,
};

pub const ScopeRecord = struct {
    scope_id: u128,
    kind: ScopeKind,
    actor: id.ActorId,
    label: []u8,
    started_ms: u64,
    ended_ms: ?u64 = null,
    start_version: Version,
    batches: std.ArrayList(id.BatchId),

    pub fn deinit(self: *ScopeRecord, allocator: Allocator) void {
        allocator.free(self.label);
        self.start_version.deinit(allocator);
        self.batches.deinit(allocator);
    }

    pub fn encode(self: *const ScopeRecord, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.scope_id);
        try w.writeByte(allocator, @intFromEnum(self.kind));
        try w.writeU128(allocator, self.actor);
        try w.writeBytes(allocator, self.label);
        try w.writeU64(allocator, self.started_ms);
        try w.writeU8(allocator, if (self.ended_ms != null) 1 else 0);
        if (self.ended_ms) |em| try w.writeU64(allocator, em);
        const heads = self.start_version.slice();
        try w.writeVarint(allocator, heads.len);
        for (heads) |bid| {
            try w.writeU128(allocator, bid.actor);
            try w.writeU64(allocator, bid.ts);
        }
        try w.writeVarint(allocator, self.batches.items.len);
        for (self.batches.items) |bid| {
            try w.writeU128(allocator, bid.actor);
            try w.writeU64(allocator, bid.ts);
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!ScopeRecord {
        const scope_id = try r.readU128();
        const kind_b = try r.readByte();
        const kind: ScopeKind = switch (kind_b) {
            1 => .turn,
            2 => .tool_call,
            3 => .manual,
            4 => .checkpoint,
            else => return error.InvalidData,
        };
        const actor = try r.readU128();
        const label = try r.readBytesAlloc(allocator);
        errdefer allocator.free(label);
        const started_ms = try r.readU64();
        const has_ended = try r.readU8();
        const ended_ms: ?u64 = if (has_ended != 0) try r.readU64() else null;
        const hc = try r.readCount(24, 65536);
        var ver = Version.ROOT;
        errdefer ver.deinit(allocator);
        if (hc > 0) {
            for (0..hc) |_| {
                const a = try r.readU128();
                const t = try r.readU64();
                try ver.insert(allocator, id.OpId.init(t, a));
            }
        }
        const bc = try r.readCount(24, 1_000_000);
        var batches: std.ArrayList(id.BatchId) = .empty;
        errdefer batches.deinit(allocator);
        try batches.ensureTotalCapacityPrecise(allocator, bc);
        for (0..bc) |_| {
            const a = try r.readU128();
            const t = try r.readU64();
            batches.appendAssumeCapacity(id.OpId.init(t, a));
        }
        return .{
            .scope_id = scope_id,
            .kind = kind,
            .actor = actor,
            .label = label,
            .started_ms = started_ms,
            .ended_ms = ended_ms,
            .start_version = ver,
            .batches = batches,
        };
    }
};

pub const ChangeObserver = struct {
    ptr: *anyopaque,
    on_commit: *const fn (ptr: *anyopaque, source: []const u8, delta: *const history_mod.CommitDelta) void,
};

pub const EditCommitResult = struct {
    batch_id: id.BatchId,
    version: Version,
    content: []u8,
    concurrent_merged: bool,

    pub fn deinit(self: *EditCommitResult, allocator: Allocator) void {
        self.version.deinit(allocator);
        allocator.free(self.content);
    }
};

pub const WatchStepResult = struct {
    batch_id: ?id.BatchId = null,
    woken: bool = false,
    events: usize = 0,
};

pub const StatCacheProxy = struct {
    shadow: ?*shadow_mod.ShadowStore = null,

    pub fn contains(self: *const StatCacheProxy, rel: []const u8) bool {
        const s = self.shadow orelse return false;
        return (s.get(rel) catch null) != null;
    }

    pub fn count(self: *const StatCacheProxy) u64 {
        const s = self.shadow orelse return 0;
        return s.count();
    }
};

pub const BlobStoreHandle = struct {
    owned: ?*blobs_mod.BlobStore = null,
    shared: ?*blobs_mod.SharedBlobPool = null,

    pub fn isShared(self: BlobStoreHandle) bool {
        return self.shared != null;
    }

    pub fn put(self: *BlobStoreHandle, data: []const u8) !crypto.Hash {
        if (self.shared) |p| return p.put(data);
        return self.owned.?.put(data);
    }

    pub fn putVerified(self: *BlobStoreHandle, hash: crypto.Hash, data: []const u8) !void {
        if (self.shared) |p| return p.putVerified(hash, data);
        return self.owned.?.putVerified(hash, data);
    }

    pub fn putBatch(self: *BlobStoreHandle, items: []const blobs_mod.BlobItem) !void {
        if (self.shared) |p| return p.putBatch(items);
        return self.owned.?.putBatch(items);
    }

    pub fn get(self: *BlobStoreHandle, allocator: Allocator, hash: crypto.Hash) !?[]u8 {
        if (self.shared) |p| return p.get(allocator, hash);
        return self.owned.?.get(allocator, hash);
    }

    pub fn exists(self: *BlobStoreHandle, hash: crypto.Hash) bool {
        if (self.shared) |p| return p.exists(hash);
        return self.owned.?.exists(hash);
    }

    pub fn putGitFallback(self: *BlobStoreHandle, git_oid: []const u8, data: []const u8) !void {
        if (self.shared) |p| return p.putGitFallback(git_oid, data);
        return self.owned.?.putGitFallback(git_oid, data);
    }

    pub fn getGitFallback(self: *BlobStoreHandle, allocator: Allocator, git_oid: []const u8) !?[]u8 {
        if (self.shared) |p| return p.getGitFallback(allocator, git_oid);
        return self.owned.?.getGitFallback(allocator, git_oid);
    }

    pub fn sealActivePack(self: *BlobStoreHandle) !void {
        if (self.shared) |p| return p.sealActivePack();
        return self.owned.?.sealActivePack();
    }

    pub fn gc(self: *BlobStoreHandle, live_oids: *const std.AutoHashMapUnmanaged(crypto.Hash, void)) !blobs_mod.GcStats {
        if (self.shared) |p| return p.gc(live_oids);
        return self.owned.?.gc(live_oids);
    }

    pub fn hibernate(self: *BlobStoreHandle) void {
        if (self.shared) |p| {
            p.hibernate();
            return;
        }
        if (self.owned) |o| o.hibernate();
    }

    pub fn packIdxDigest(self: *const BlobStoreHandle) crypto.Hash {
        if (self.owned) |o| return o.packIdxDigest();
        return @splat(0);
    }

    pub fn maxPackId(self: *const BlobStoreHandle) u32 {
        if (self.owned) |o| return o.maxPackId();
        return 0;
    }

    pub fn deinit(self: *BlobStoreHandle, allocator: Allocator) void {
        if (self.shared) |p| {
            p.release();
            self.shared = null;
        }
        if (self.owned) |o| {
            o.deinit();
            allocator.destroy(o);
            self.owned = null;
        }
    }
};

const BlobReaderCtx = struct {
    handle: BlobStoreHandle,

    fn readAlloc(ptr: *anyopaque, allocator: Allocator, oid: id.Oid) Allocator.Error!?[]u8 {
        const self: *BlobReaderCtx = @ptrCast(@alignCast(ptr));
        return self.handle.get(allocator, oid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn existsFn(ptr: *anyopaque, oid: id.Oid) bool {
        const self: *BlobReaderCtx = @ptrCast(@alignCast(ptr));
        return self.handle.exists(oid);
    }
};

const GitReaderCtx = struct {
    odb: ?*git_odb_mod.GitOdb = null,
    blobs: BlobStoreHandle = .{},

    fn readAlloc(ptr: *anyopaque, allocator: Allocator, oid: git_dirs_mod.GitOid) Allocator.Error!?[]u8 {
        const self: *GitReaderCtx = @ptrCast(@alignCast(ptr));
        if (self.odb) |odb| {
            const got = odb.readBlobAlloc(allocator, oid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (got) |data| return data;
        }
        return self.blobs.getGitFallback(allocator, oid.slice()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn readCached(_: *anyopaque, _: git_dirs_mod.GitOid) ?[]const u8 {
        return null;
    }

    fn contains(ptr: *anyopaque, oid: git_dirs_mod.GitOid) bool {
        const self: *GitReaderCtx = @ptrCast(@alignCast(ptr));
        if (self.odb) |odb| {
            if (odb.contains(oid)) return true;
        }
        const raw = self.blobs.getGitFallback(std.heap.page_allocator, oid.slice()) catch return false;
        if (raw) |buf| {
            std.heap.page_allocator.free(buf);
            return true;
        }
        return false;
    }
};

const ProcessLockSlot = struct {
    in_use: bool = false,
    ino: u64 = 0,
    fd: posix.fd_t = -1,
    refs: usize = 0,
};

var g_lock_spin: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_lock_slots: [256]ProcessLockSlot = @splat(.{});

fn acquireLockSpin() void {
    while (g_lock_spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn releaseLockSpin() void {
    g_lock_spin.store(0, .release);
}

const StateDirLock = struct {
    slot_idx: ?usize = null,
    direct_fd: ?posix.fd_t = null,

    fn acquire(io: Io, state_dir: Io.Dir) !StateDirLock {
        const lock_file = try state_dir.createFile(io, "lock", .{ .truncate = false });
        const st = lock_file.stat(io) catch {
            lock_file.close(io);
            return error.LockFailed;
        };
        const ino: u64 = st.inode;
        const fd: posix.fd_t = lock_file.handle;

        acquireLockSpin();
        defer releaseLockSpin();

        for (&g_lock_slots, 0..) |*slot, idx| {
            if (slot.in_use and slot.ino == ino) {
                slot.refs += 1;
                lock_file.close(io);
                return .{ .slot_idx = idx };
            }
        }

        const rc = linux.flock(fd, @intCast(posix.LOCK.EX | posix.LOCK.NB));
        if (linux.errno(rc) != .SUCCESS) {
            lock_file.close(io);
            return error.WorkspaceLocked;
        }

        for (&g_lock_slots, 0..) |*slot, idx| {
            if (!slot.in_use) {
                slot.* = .{
                    .in_use = true,
                    .ino = ino,
                    .fd = fd,
                    .refs = 1,
                };
                return .{ .slot_idx = idx };
            }
        }
        return .{ .direct_fd = fd };
    }

    fn release(self: *StateDirLock) void {
        if (self.slot_idx) |idx| {
            acquireLockSpin();
            var close_fd: ?posix.fd_t = null;
            if (g_lock_slots[idx].in_use) {
                if (g_lock_slots[idx].refs > 1) {
                    g_lock_slots[idx].refs -= 1;
                } else {
                    close_fd = g_lock_slots[idx].fd;
                    g_lock_slots[idx] = .{};
                }
            }
            releaseLockSpin();
            if (close_fd) |fd| {
                _ = linux.flock(fd, @intCast(posix.LOCK.UN));
                _ = linux.close(fd);
            }
            self.slot_idx = null;
        }
        if (self.direct_fd) |fd| {
            _ = linux.flock(fd, @intCast(posix.LOCK.UN));
            _ = linux.close(fd);
            self.direct_fd = null;
        }
    }
};

const StatKind = enum(u8) {
    file = 1,
    symlink = 2,
};

const StatStamp = struct {
    size: u64,
    mtime_ns: i96,
    mode: tree_mod.FileMode,
    kind: StatKind,
    ino: u64 = 0,

    fn matchesShadow(self: StatStamp, entry: shadow_mod.ShadowEntry) bool {
        const ek: shadow_mod.EntryKind = switch (self.kind) {
            .file => .file,
            .symlink => .symlink,
        };
        const em: u32 = @intFromEnum(self.mode);
        return entry.kind == ek and
            entry.size == self.size and
            entry.mtime_ns == self.mtime_ns and
            entry.mode == em and
            (entry.ino == 0 or self.ino == 0 or entry.ino == self.ino);
    }
};

const DiskEntry = union(enum) {
    unchanged: StatStamp,
    git_clean: struct {
        oid: git_dirs_mod.GitOid,
        len: u64,
        mode: tree_mod.FileMode,
        stamp: StatStamp,
    },
    file: struct {
        bytes: []u8,
        mode: tree_mod.FileMode,
        stamp: StatStamp,
    },
    symlink: struct {
        target: []u8,
        stamp: StatStamp,
    },

    fn deinit(self: *DiskEntry, allocator: Allocator) void {
        switch (self.*) {
            .unchanged, .git_clean => {},
            .file => |f| allocator.free(f.bytes),
            .symlink => |s| allocator.free(s.target),
        }
    }
};

const DiskReadResult = union(enum) {
    missing,
    skipped_oversize,
    ignored,
    git_clean: struct {
        oid: git_dirs_mod.GitOid,
        len: u64,
        mode: tree_mod.FileMode,
        stamp: StatStamp,
    },
    file: struct {
        bytes: []u8,
        mode: tree_mod.FileMode,
        stamp: StatStamp,
    },
    symlink: struct {
        target: []u8,
        stamp: StatStamp,
    },

    fn deinit(self: *DiskReadResult, allocator: Allocator) void {
        switch (self.*) {
            .missing, .skipped_oversize, .ignored, .git_clean => {},
            .file => |f| allocator.free(f.bytes),
            .symlink => |s| allocator.free(s.target),
        }
    }
};

const IgnoreRule = struct {
    prefix: []u8,
    pattern: []u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
};

const GitIgnore = struct {
    rules: std.ArrayList(IgnoreRule) = .empty,
    root_stamp_size: u64 = 0,
    root_stamp_mtime: i96 = 0,
    root_loaded: bool = false,
    exclude_stamp_size: u64 = 0,
    exclude_stamp_mtime: i96 = 0,
    exclude_loaded: bool = false,
    nested_loaded_dirs: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *GitIgnore, allocator: Allocator) void {
        self.clear(allocator);
        self.rules.deinit(allocator);
        self.nested_loaded_dirs.deinit(allocator);
    }

    fn clear(self: *GitIgnore, allocator: Allocator) void {
        for (self.rules.items) |r| {
            allocator.free(r.prefix);
            allocator.free(r.pattern);
        }
        self.rules.clearRetainingCapacity();
        var it = self.nested_loaded_dirs.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.nested_loaded_dirs.clearRetainingCapacity();
    }

    fn parseRulesInto(self: *GitIgnore, allocator: Allocator, prefix: []const u8, data: []const u8) void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            var line = std.mem.trimEnd(u8, raw_line, "\r \t");
            line = std.mem.trimStart(u8, line, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            var negated = false;
            if (line[0] == '!') {
                negated = true;
                line = line[1..];
                if (line.len == 0) continue;
            }
            var dir_only = false;
            if (line[line.len - 1] == '/') {
                dir_only = true;
                line = line[0 .. line.len - 1];
                if (line.len == 0) continue;
            }
            var anchored = false;
            if (line[0] == '/') {
                anchored = true;
                line = line[1..];
                if (line.len == 0) continue;
            } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
                anchored = true;
            }
            const p_dup = allocator.dupe(u8, prefix) catch continue;
            const dup = allocator.dupe(u8, line) catch {
                allocator.free(p_dup);
                continue;
            };
            self.rules.append(allocator, .{
                .prefix = p_dup,
                .pattern = dup,
                .negated = negated,
                .dir_only = dir_only,
                .anchored = anchored,
            }) catch {
                allocator.free(p_dup);
                allocator.free(dup);
            };
        }
    }

    fn loadFileRules(self: *GitIgnore, allocator: Allocator, io: Io, dir: Io.Dir, file_rel: []const u8, prefix: []const u8) void {
        const f = dir.openFile(io, file_rel, .{}) catch return;
        defer f.close(io);
        const st = f.stat(io) catch return;
        if (st.size == 0 or st.size > 512 * 1024) return;
        const buf = allocator.alloc(u8, @intCast(st.size)) catch return;
        defer allocator.free(buf);
        const n = f.readPositionalAll(io, buf, 0) catch return;
        self.parseRulesInto(allocator, prefix, buf[0..n]);
    }

    fn reloadIfNeeded(self: *GitIgnore, allocator: Allocator, io: Io, work_dir: Io.Dir, common_dir_opt: ?[]const u8) void {
        const root_st = work_dir.statFile(io, ".gitignore", .{}) catch null;
        var excl_st: ?Io.File.Stat = null;
        var excl_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var excl_path: ?[]const u8 = null;
        if (common_dir_opt) |cd| {
            if (std.fmt.bufPrint(&excl_path_buf, "{s}/info/exclude", .{cd})) |ep| {
                excl_path = ep;
                excl_st = Io.Dir.cwd().statFile(io, ep, .{}) catch null;
            } else |_| {}
        }

        const root_same = if (root_st) |st|
            self.root_loaded and st.size == self.root_stamp_size and st.mtime.nanoseconds == self.root_stamp_mtime
        else
            !self.root_loaded;
        const excl_same = if (excl_st) |st|
            self.exclude_loaded and st.size == self.exclude_stamp_size and st.mtime.nanoseconds == self.exclude_stamp_mtime
        else
            !self.exclude_loaded;
        if (root_same and excl_same and self.nested_loaded_dirs.count() == 0) return;

        self.clear(allocator);

        if (excl_st) |st| {
            self.exclude_loaded = true;
            self.exclude_stamp_size = st.size;
            self.exclude_stamp_mtime = st.mtime.nanoseconds;
            if (excl_path) |ep| {
                self.loadFileRules(allocator, io, Io.Dir.cwd(), ep, "");
            }
        } else {
            self.exclude_loaded = false;
            self.exclude_stamp_size = 0;
            self.exclude_stamp_mtime = 0;
        }

        if (root_st) |st| {
            self.root_loaded = true;
            self.root_stamp_size = st.size;
            self.root_stamp_mtime = st.mtime.nanoseconds;
            self.loadFileRules(allocator, io, work_dir, ".gitignore", "");
        } else {
            self.root_loaded = false;
            self.root_stamp_size = 0;
            self.root_stamp_mtime = 0;
        }
    }

    fn loadNestedForDir(self: *GitIgnore, allocator: Allocator, io: Io, dir: Io.Dir, rel_prefix: []const u8) void {
        if (rel_prefix.len == 0) return;
        if (self.nested_loaded_dirs.contains(rel_prefix)) return;
        const st = dir.statFile(io, ".gitignore", .{}) catch return;
        if (st.size == 0 or st.size > 512 * 1024) return;
        const key = allocator.dupe(u8, rel_prefix) catch return;
        self.nested_loaded_dirs.put(allocator, key, {}) catch {
            allocator.free(key);
            return;
        };
        self.loadFileRules(allocator, io, dir, ".gitignore", rel_prefix);
    }

    fn ensureNestedAncestorsLoaded(self: *GitIgnore, allocator: Allocator, io: Io, work_dir: Io.Dir, rel_path: []const u8) void {
        var idx: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel_path, idx, '/')) |slash| {
            const sub = rel_path[0..slash];
            if (!self.nested_loaded_dirs.contains(sub)) {
                if (work_dir.openDir(io, sub, .{})) |d_val| {
                    var d = d_val;
                    defer d.close(io);
                    self.loadNestedForDir(allocator, io, d, sub);
                } else |_| {}
            }
            idx = slash + 1;
        }
    }

    fn isIgnored(self: *const GitIgnore, rel_path: []const u8, is_dir: bool) bool {
        if (self.rules.items.len == 0) return false;
        var ignored = false;
        for (self.rules.items) |rule| {
            if (rule.dir_only and !is_dir) continue;
            const target_rel: []const u8 = if (rule.prefix.len == 0)
                rel_path
            else blk: {
                if (rel_path.len <= rule.prefix.len) continue;
                if (!std.mem.startsWith(u8, rel_path, rule.prefix)) continue;
                if (rel_path[rule.prefix.len] != '/') continue;
                break :blk rel_path[rule.prefix.len + 1 ..];
            };
            if (matchRule(rule, target_rel)) {
                ignored = !rule.negated;
            }
        }
        return ignored;
    }

    fn isPathOrAncestorIgnored(self: *const GitIgnore, rel_path: []const u8, is_dir: bool) bool {
        if (self.rules.items.len == 0) return false;
        var idx: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel_path, idx, '/')) |slash| {
            if (self.isIgnored(rel_path[0..slash], true)) return true;
            idx = slash + 1;
        }
        return self.isIgnored(rel_path, is_dir);
    }

    fn matchRule(rule: IgnoreRule, rel_path: []const u8) bool {
        if (rule.anchored) {
            return globMatch(rule.pattern, rel_path);
        }
        const base = std.fs.path.basename(rel_path);
        if (globMatch(rule.pattern, base)) return true;
        return globMatch(rule.pattern, rel_path);
    }
};

pub fn globMatch(pat: []const u8, str: []const u8) bool {
    const MAX_PAT: usize = 512;
    if (pat.len >= MAX_PAT) return std.mem.eql(u8, pat, str);

    var cur: [MAX_PAT]bool = @splat(false);
    var nxt: [MAX_PAT]bool = @splat(false);
    const n = pat.len;
    cur[0] = true;

    const closeEps = struct {
        fn run(p: []const u8, states: *[MAX_PAT]bool, at_boundary: bool) void {
            var i: usize = 0;
            while (i < p.len) : (i += 1) {
                if (!states[i]) continue;
                if (i + 1 < p.len and p[i] == '*' and p[i + 1] == '*') {
                    if (i + 2 < p.len and p[i + 2] == '/') {
                        if (at_boundary) states[i + 3] = true;
                    } else {
                        states[i + 2] = true;
                    }
                } else if (p[i] == '*') {
                    states[i + 1] = true;
                }
            }
        }
    }.run;

    closeEps(pat, &cur, true);

    for (str) |ch| {
        @memset(nxt[0 .. n + 1], false);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!cur[i]) continue;
            if (i + 1 < n and pat[i] == '*' and pat[i + 1] == '*') {
                nxt[i] = true;
            } else if (pat[i] == '*') {
                if (ch != '/') nxt[i] = true;
            } else if (pat[i] == '?') {
                if (ch != '/') nxt[i + 1] = true;
            } else if (pat[i] == ch) {
                nxt[i + 1] = true;
            }
        }
        const next_boundary = (ch == '/');
        closeEps(pat, &nxt, next_boundary);
        @memcpy(cur[0 .. n + 1], nxt[0 .. n + 1]);
    }

    return cur[n];
}

fn isBinaryBytes(data: []const u8) bool {
    var check_len = @min(data.len, 8192);
    if (std.mem.indexOfScalar(u8, data[0..check_len], 0) != null) return true;
    if (data.len > 8192) {
        var trim: usize = 0;
        while (trim < 4 and check_len > 0 and (data[check_len - 1] & 0xC0) == 0x80) : (trim += 1) {
            check_len -= 1;
        }
        if (check_len > 0 and (data[check_len - 1] & 0x80) != 0) {
            const lead = data[check_len - 1];
            const seq_len: usize = if ((lead & 0xE0) == 0xC0)
                2
            else if ((lead & 0xF0) == 0xE0)
                3
            else if ((lead & 0xF8) == 0xF0)
                4
            else
                1;
            if (seq_len > 1) check_len -= 1;
        }
    }
    return !std.unicode.utf8ValidateSlice(data[0..check_len]);
}

fn detectLineEnding(data: []const u8) tree_mod.LineEnding {
    var has_crlf = false;
    var has_bare_lf = false;
    for (data, 0..) |b, i| {
        if (b == '\n') {
            if (i > 0 and data[i - 1] == '\r') {
                has_crlf = true;
            } else {
                has_bare_lf = true;
            }
        }
    }
    return if (has_crlf and !has_bare_lf) .crlf else .lf;
}

fn normalizeToLf(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    var crlf_count: usize = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n') crlf_count += 1;
    }
    if (crlf_count == 0) return try allocator.dupe(u8, data);
    const out = try allocator.alloc(u8, data.len - crlf_count);
    var dst: usize = 0;
    i = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        out[dst] = data[i];
        dst += 1;
    }
    return out;
}

fn smudgeLineEnding(allocator: Allocator, data: []const u8, ending: tree_mod.LineEnding) Allocator.Error![]u8 {
    if (ending != .crlf) return try allocator.dupe(u8, data);
    var extra: usize = 0;
    for (data, 0..) |b, idx| {
        if (b == '\n' and (idx == 0 or data[idx - 1] != '\r')) extra += 1;
    }
    if (extra == 0) return try allocator.dupe(u8, data);
    const out = try allocator.alloc(u8, data.len + extra);
    var dst: usize = 0;
    for (data, 0..) |b, idx| {
        if (b == '\n' and (idx == 0 or data[idx - 1] != '\r')) {
            out[dst] = '\r';
            dst += 1;
        }
        out[dst] = b;
        dst += 1;
    }
    return out;
}

fn fileModeFromStat(st: Io.File.Stat) tree_mod.FileMode {
    const raw = st.permissions.toMode();
    return if ((raw & 0o111) != 0) .executable else .regular;
}

fn loadOrCreateActor(io: Io, state_dir: Io.Dir) !id.ActorId {
    if (state_dir.openFile(io, "actor.0ndb", .{})) |f| {
        defer f.close(io);
        var buf: [16]u8 = undefined;
        const n = f.readPositionalAll(io, &buf, 0) catch 0;
        if (n == 16) return std.mem.readInt(u128, &buf, .little);
    } else |_| {}

    const actor = id.newUuidV7(io);
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u128, &buf, actor, .little);
    try mmap.atomicWriteFile(io, state_dir, "actor.0ndb", &buf);
    return actor;
}

fn encodeScopesBlob(allocator: Allocator, scopes: []const ScopeRecord) Allocator.Error![]u8 {
    var w = codec.Writer{};
    errdefer w.deinit(allocator);
    try w.writeVarint(allocator, scopes.len);
    for (scopes) |*s| {
        try s.encode(allocator, &w);
    }
    return try w.buf.toOwnedSlice(allocator);
}

fn decodeScopesBlob(allocator: Allocator, data: []const u8, out: *std.ArrayList(ScopeRecord)) !void {
    if (data.len == 0) return;
    var r = codec.Reader.init(data);
    const count = try r.readCount(16, 1_000_000);
    for (0..count) |_| {
        const rec = try ScopeRecord.decode(allocator, &r);
        try out.append(allocator, rec);
    }
}

fn dirTotalBytes(io: Io, parent: Io.Dir, sub: []const u8) u64 {
    var d = parent.openDir(io, sub, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var total: u64 = 0;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const st = d.statFile(io, entry.name, .{}) catch continue;
        total += st.size;
    }
    return total;
}

pub const Workspace = struct {
    allocator: Allocator,
    io: Io,
    root_path: []u8,
    state_dir: Io.Dir,
    work_dir: Io.Dir,
    state_lock: StateDirLock,
    history: History,
    batch_log: *log_mod.AppendLog,
    blob_store: BlobStoreHandle,
    blob_reader_ctx: *BlobReaderCtx,
    git_reader_ctx: *GitReaderCtx,
    segments: *segments_mod.SegmentStore,
    shadow: *shadow_mod.ShadowStore,
    snapshot_stack: ?*snapshot_mod.SnapshotStack = null,
    manifest: manifest_mod.Manifest = .{},
    retained_versions: std.ArrayList(Version) = .empty,
    synced_version: Version,
    disk_actor: id.ActorId,
    scopes: std.ArrayList(ScopeRecord),
    active_scope: ?u128 = null,
    observer: ?ChangeObserver = null,
    watcher: ?watch.SharedWatcher = null,
    stat_cache: StatCacheProxy = .{},
    stat_cache_dirty: bool = false,
    batch_log_idx: std.AutoHashMapUnmanaged(id.BatchId, usize) = .empty,
    gitignore: GitIgnore = .{},
    max_file_size: u64 = DEFAULT_MAX_FILE_SIZE,
    git_dirs: ?git_dirs_mod.GitDirs = null,
    git_odb: ?*git_odb_mod.GitOdb = null,
    git_index: ?git_index_mod.GitIndex = null,
    git_index_stamp: ?git_dirs_mod.IndexStamp = null,
    has_custom_filters: bool = false,
    resources: ?*pool_mod.DaemonResources = null,
    uses_shared_git_odb: bool = false,
    pinned_git_oids: std.HashMapUnmanaged(git_dirs_mod.GitOid, void, git_dirs_mod.GitOid.hashContext, 80) = .empty,
    in_checkpoint: bool = false,

    fn readBatchLogSlice(ptr: *anyopaque, offset: u64, len: u32) ?[]const u8 {
        const log_ptr: *log_mod.AppendLog = @ptrCast(@alignCast(ptr));
        return log_ptr.readSlice(offset, len);
    }

    pub fn open(
        allocator: Allocator,
        io: Io,
        root_path: []const u8,
        state_path: []const u8,
        history_id_opt: ?u128,
    ) !Workspace {
        return openWithResources(allocator, io, root_path, state_path, history_id_opt, null);
    }

    pub fn openWithResources(
        allocator: Allocator,
        io: Io,
        root_path: []const u8,
        state_path: []const u8,
        history_id_opt: ?u128,
        resources: ?*pool_mod.DaemonResources,
    ) !Workspace {
        try Io.Dir.cwd().createDirPath(io, root_path);
        try Io.Dir.cwd().createDirPath(io, state_path);

        var transferred = false;

        var work_dir = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        errdefer if (!transferred) work_dir.close(io);
        var state_dir = try Io.Dir.cwd().openDir(io, state_path, .{ .iterate = true });
        errdefer if (!transferred) state_dir.close(io);

        var state_lock = try StateDirLock.acquire(io, state_dir);
        errdefer if (!transferred) state_lock.release();

        try state_dir.createDirPath(io, "snap");
        try state_dir.createDirPath(io, "wal");
        try state_dir.createDirPath(io, "seg");

        var blob_handle = BlobStoreHandle{};
        errdefer if (!transferred) blob_handle.deinit(allocator);
        if (resources) |res| {
            res.blob_pool.retain();
            blob_handle.shared = res.blob_pool;
        } else {
            const bs = try allocator.create(blobs_mod.BlobStore);
            errdefer allocator.destroy(bs);
            bs.* = try blobs_mod.BlobStore.open(allocator, io, state_dir, "blobs", blobs_mod.DEFAULT_CACHE_BUDGET);
            blob_handle.owned = bs;
        }

        const blob_reader_ctx = try allocator.create(BlobReaderCtx);
        errdefer if (!transferred) allocator.destroy(blob_reader_ctx);
        blob_reader_ctx.* = .{ .handle = blob_handle };

        var git_dirs = git_dirs_mod.GitDirs.locate(allocator, io, root_path) catch null;
        errdefer if (!transferred) {
            if (git_dirs) |*gd| gd.deinit(allocator);
        };

        var git_odb: ?*git_odb_mod.GitOdb = null;
        var uses_shared_git_odb = false;
        var has_custom_filters = false;
        errdefer if (!transferred) {
            if (git_odb) |odb| {
                if (uses_shared_git_odb) {
                    if (resources) |res| {
                        if (git_dirs) |*gd| res.releaseGitOdb(gd.common_dir);
                    }
                } else {
                    odb.deinit();
                }
            }
        };

        if (git_dirs) |*gd| {
            gd.ensureExclude(io) catch {};
            has_custom_filters = gd.hasCustomFilters(allocator, io) catch false;
            if (resources) |res| {
                git_odb = res.acquireGitOdb(gd.common_dir, gd.config.object_format, git_odb_mod.DEFAULT_PIN_REF) catch null;
                if (git_odb != null) uses_shared_git_odb = true;
            } else {
                git_odb = git_odb_mod.GitOdb.open(allocator, io, gd.common_dir, gd.config.object_format, git_odb_mod.DEFAULT_PIN_REF) catch null;
            }
        }

        const git_reader_ctx = try allocator.create(GitReaderCtx);
        errdefer if (!transferred) allocator.destroy(git_reader_ctx);
        git_reader_ctx.* = .{ .odb = git_odb, .blobs = blob_handle };

        const segments = try allocator.create(segments_mod.SegmentStore);
        var seg_inited = false;
        errdefer if (!transferred) {
            if (seg_inited) segments.deinit();
            allocator.destroy(segments);
        };
        segments.* = try segments_mod.SegmentStore.open(allocator, io, state_dir);
        seg_inited = true;

        const shadow = try allocator.create(shadow_mod.ShadowStore);
        var shadow_inited = false;
        errdefer if (!transferred) {
            if (shadow_inited) shadow.deinit();
            allocator.destroy(shadow);
        };
        shadow.* = try shadow_mod.ShadowStore.open(allocator, io, state_dir, SHADOW_FILE_NAME);
        shadow_inited = true;

        const loaded_manifest = try manifest_mod.Manifest.load(io, state_dir);
        const has_legacy_log = if (loaded_manifest == null) blk: {
            if (state_dir.statFile(io, "batches.0ndb", .{})) |_| break :blk true else |_| break :blk false;
        } else false;

        var mf: manifest_mod.Manifest = loaded_manifest orelse .{
            .history_id = history_id_opt orelse id.newUuidV7(io),
            .generation = 0,
            .base_gen = 0,
            .delta_gen = 0,
            .wal_gen = 1,
            .wal_base_seq = 0,
        };
        if (mf.history_id == 0) {
            mf.history_id = history_id_opt orelse id.newUuidV7(io);
        }
        if (mf.wal_gen == 0) mf.wal_gen = 1;

        var wal_dir = try state_dir.openDir(io, "wal", .{ .iterate = true });
        defer wal_dir.close(io);

        const batch_log = try allocator.create(log_mod.AppendLog);
        var batch_log_inited = false;
        errdefer if (!transferred) {
            if (batch_log_inited) batch_log.deinit();
            allocator.destroy(batch_log);
        };
        if (has_legacy_log) {
            batch_log.* = try log_mod.AppendLog.open(allocator, io, state_dir, "batches.0ndb", true);
        } else {
            var wal_name_buf: [32]u8 = undefined;
            const wal_name = manifest_mod.walFileName(mf.wal_gen, &wal_name_buf);
            batch_log.* = try log_mod.AppendLog.open(allocator, io, wal_dir, wal_name, true);
            if (batch_log.next_seq <= mf.wal_base_seq) {
                batch_log.next_seq = mf.wal_base_seq + 1;
            }
        }
        batch_log_inited = true;

        var hist = try History.init(allocator, mf.history_id);
        errdefer if (!transferred) hist.deinit();
        hist.setLogReader(.{
            .ptr = batch_log,
            .readFn = readBatchLogSlice,
        });
        hist.setBlobReader(.{
            .ptr = blob_reader_ctx,
            .readAllocFn = BlobReaderCtx.readAlloc,
            .existsFn = BlobReaderCtx.existsFn,
        });
        hist.setGitReader(.{
            .ptr = git_reader_ctx,
            .readAllocFn = GitReaderCtx.readAlloc,
            .readCachedFn = GitReaderCtx.readCached,
            .containsFn = GitReaderCtx.contains,
        });

        const actor = try loadOrCreateActor(io, state_dir);
        const root_copy = try allocator.dupe(u8, root_path);
        errdefer if (!transferred) allocator.free(root_copy);

        var ws = Workspace{
            .allocator = allocator,
            .io = io,
            .root_path = root_copy,
            .state_dir = state_dir,
            .work_dir = work_dir,
            .state_lock = state_lock,
            .history = hist,
            .batch_log = batch_log,
            .blob_store = blob_handle,
            .blob_reader_ctx = blob_reader_ctx,
            .git_reader_ctx = git_reader_ctx,
            .segments = segments,
            .shadow = shadow,
            .snapshot_stack = null,
            .manifest = mf,
            .retained_versions = .empty,
            .synced_version = Version.ROOT,
            .disk_actor = actor,
            .scopes = .empty,
            .active_scope = null,
            .observer = null,
            .watcher = null,
            .stat_cache = .{ .shadow = shadow },
            .stat_cache_dirty = false,
            .batch_log_idx = .empty,
            .gitignore = .{},
            .max_file_size = DEFAULT_MAX_FILE_SIZE,
            .git_dirs = git_dirs,
            .git_odb = git_odb,
            .git_index = null,
            .git_index_stamp = null,
            .has_custom_filters = has_custom_filters,
            .resources = resources,
            .uses_shared_git_odb = uses_shared_git_odb,
            .pinned_git_oids = .empty,
            .in_checkpoint = false,
        };
        transferred = true;
        errdefer ws.deinit();

        if (loaded_manifest != null) {
            if (mf.base_gen != 0 or mf.delta_gen != 0) {
                var snap_dir = try ws.state_dir.openDir(io, "snap", .{ .iterate = true });
                defer snap_dir.close(io);

                var base_reader: ?*snapshot_mod.SnapshotReader = null;
                defer if (base_reader) |r| r.release();
                if (mf.base_gen != 0) {
                    var bbuf: [32]u8 = undefined;
                    const bname = manifest_mod.baseSnapFileName(mf.base_gen, &bbuf);
                    base_reader = try snapshot_mod.SnapshotReader.open(allocator, io, snap_dir, bname);
                }

                var delta_reader: ?*snapshot_mod.SnapshotReader = null;
                defer if (delta_reader) |r| r.release();
                if (mf.delta_gen != 0) {
                    var dbuf: [32]u8 = undefined;
                    const dname = manifest_mod.deltaSnapFileName(mf.delta_gen, &dbuf);
                    delta_reader = try snapshot_mod.SnapshotReader.open(allocator, io, snap_dir, dname);
                }

                const stack = try snapshot_mod.SnapshotStack.create(allocator, base_reader, delta_reader);
                ws.snapshot_stack = stack;
                ws.history.attachSnapshotStack(stack);

                var msd = try stack.loadStateIntoHistory(allocator, &ws.history);
                defer msd.deinit(allocator);
                decodeScopesBlob(allocator, msd.scopes_blob, &ws.scopes) catch {};
                for (msd.retained_versions.items) |*rv| {
                    try ws.retained_versions.append(allocator, try rv.clone(allocator));
                }
                ws.synced_version.deinit(allocator);
                ws.synced_version = try msd.synced_version.clone(allocator);
            }
            try ws.replayLogAfterSeq(mf.wal_base_seq);
            manifest_mod.Manifest.gcOrphanFiles(allocator, io, ws.state_dir, ws.manifest);
        } else if (has_legacy_log) {
            try ws.replayLogAfterSeq(0);
            try ws.checkpoint(.major);
            ws.state_dir.deleteFile(io, "batches.0ndb") catch {};
        } else {
            try ws.manifest.saveAtomic(io, ws.state_dir);
            mmap.fsyncDir(io, ws.state_dir) catch {};
        }

        return ws;
    }

    pub fn deinit(self: *Workspace) void {
        if (self.stat_cache_dirty or self.shadow.dirtyCount() > 0) {
            self.saveStatCache() catch {};
        }
        if (self.watcher) |*w| {
            w.deinit();
            self.watcher = null;
        }
        self.gitignore.deinit(self.allocator);
        if (self.git_index) |*gi| {
            gi.deinit(self.allocator);
            self.git_index = null;
        }
        self.pinned_git_oids.deinit(self.allocator);
        self.batch_log_idx.deinit(self.allocator);
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        for (self.retained_versions.items) |*rv| rv.deinit(self.allocator);
        self.retained_versions.deinit(self.allocator);
        self.synced_version.deinit(self.allocator);
        self.history.deinit();
        if (self.snapshot_stack) |st| {
            st.release();
            self.snapshot_stack = null;
        }
        self.batch_log.deinit();
        self.allocator.destroy(self.batch_log);
        self.segments.deinit();
        self.allocator.destroy(self.segments);
        self.shadow.deinit();
        self.allocator.destroy(self.shadow);
        self.stat_cache.shadow = null;
        self.allocator.destroy(self.git_reader_ctx);
        self.allocator.destroy(self.blob_reader_ctx);
        if (self.git_odb) |odb| {
            if (self.uses_shared_git_odb) {
                if (self.resources) |res| {
                    if (self.git_dirs) |*gd| res.releaseGitOdb(gd.common_dir);
                }
            } else {
                odb.deinit();
            }
            self.git_odb = null;
        }
        if (self.git_dirs) |*gd| {
            gd.deinit(self.allocator);
            self.git_dirs = null;
        }
        self.blob_store.deinit(self.allocator);
        self.state_lock.release();
        self.state_dir.close(self.io);
        self.work_dir.close(self.io);
        self.allocator.free(self.root_path);
    }

    pub fn retainVersion(self: *Workspace, ver: *const Version) Allocator.Error!void {
        for (self.retained_versions.items) |*existing| {
            if (existing.eql(ver)) return;
        }
        try self.retained_versions.append(self.allocator, try ver.clone(self.allocator));
    }

    pub fn releaseVersion(self: *Workspace, ver: *const Version) void {
        var i: usize = 0;
        while (i < self.retained_versions.items.len) {
            if (self.retained_versions.items[i].eql(ver)) {
                var removed = self.retained_versions.swapRemove(i);
                removed.deinit(self.allocator);
                return;
            }
            i += 1;
        }
    }

    pub fn saveStatCache(self: *Workspace) !void {
        try self.shadow.flushAtomic(self.io, self.state_dir, SHADOW_FILE_NAME);
        self.stat_cache_dirty = false;
    }

    pub fn setObserver(self: *Workspace, observer: ?ChangeObserver) void {
        self.observer = observer;
    }

    pub fn beginScope(self: *Workspace, kind: ScopeKind, actor: id.ActorId, label: []const u8) !u128 {
        const sid = id.newUuidV7(self.io);
        const rec = ScopeRecord{
            .scope_id = sid,
            .kind = kind,
            .actor = actor,
            .label = try self.allocator.dupe(u8, label),
            .started_ms = id.nowMs(self.io),
            .ended_ms = null,
            .start_version = try self.history.headsClone(),
            .batches = .empty,
        };
        try self.scopes.append(self.allocator, rec);
        self.active_scope = sid;
        try self.persistScope(&self.scopes.items[self.scopes.items.len - 1]);
        return sid;
    }

    pub fn endScope(self: *Workspace, scope_id: u128) !void {
        const now = id.nowMs(self.io);
        for (self.scopes.items) |*s| {
            if (s.scope_id == scope_id) {
                s.ended_ms = now;
                try self.persistScopeEnd(scope_id, now);
                break;
            }
        }
        if (self.active_scope == scope_id) {
            self.active_scope = null;
        }
    }

    fn persistScope(self: *Workspace, rec: *const ScopeRecord) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try rec.encode(self.allocator, &w);
        _ = try self.batch_log.append(FRAME_SCOPE, 0, 0, w.items());
    }

    fn persistScopeBatch(self: *Workspace, scope_id: u128, batch_id: id.BatchId) !void {
        var buf: [40]u8 = undefined;
        std.mem.writeInt(u128, buf[0..16], scope_id, .little);
        std.mem.writeInt(u128, buf[16..32], batch_id.actor, .little);
        std.mem.writeInt(u64, buf[32..40], batch_id.ts, .little);
        _ = try self.batch_log.append(FRAME_SCOPE_BATCH, 0, 0, &buf);
    }

    fn persistScopeEnd(self: *Workspace, scope_id: u128, ended_ms: u64) !void {
        var buf: [24]u8 = undefined;
        std.mem.writeInt(u128, buf[0..16], scope_id, .little);
        std.mem.writeInt(u64, buf[16..24], ended_ms, .little);
        _ = try self.batch_log.append(FRAME_SCOPE_END, 0, 0, &buf);
    }

    fn upsertScopeRecord(self: *Workspace, rec: ScopeRecord) !void {
        for (self.scopes.items) |*existing| {
            if (existing.scope_id == rec.scope_id) {
                existing.deinit(self.allocator);
                existing.* = rec;
                return;
            }
        }
        try self.scopes.append(self.allocator, rec);
    }

    fn sealCurrentWalIntoSegments(self: *Workspace, wal_dir: Io.Dir) !u32 {
        if (self.batch_log.count() == 0) return self.manifest.seg_max_id;

        var seq_to_bid: std.AutoHashMapUnmanaged(u64, id.BatchId) = .empty;
        defer seq_to_bid.deinit(self.allocator);
        {
            var bit = self.batch_log_idx.iterator();
            while (bit.next()) |kv| {
                const idx = kv.value_ptr.*;
                if (idx < self.batch_log.index.items.len) {
                    const seq = self.batch_log.index.items[idx].seq;
                    try seq_to_bid.put(self.allocator, seq, kv.key_ptr.*);
                }
            }
        }

        const new_seg_id = self.manifest.seg_max_id + 1;
        var wal_name_buf: [32]u8 = undefined;
        const wal_name = manifest_mod.walFileName(self.manifest.wal_gen, &wal_name_buf);

        const is_legacy = blk: {
            if (self.manifest.generation == 0) {
                if (self.state_dir.statFile(self.io, "batches.0ndb", .{})) |_| break :blk true else |_| {}
            }
            break :blk false;
        };

        const written = if (is_legacy)
            try self.segments.sealFromWal(self.state_dir, "batches.0ndb", new_seg_id)
        else
            try self.segments.sealFromWal(wal_dir, wal_name, new_seg_id);
        defer self.allocator.free(written);

        for (written) |wf| {
            if (wf.kind != FRAME_BATCH) continue;
            if (seq_to_bid.get(wf.seq)) |bid| {
                try self.history.dag.setBatchLocation(self.allocator, bid, .{
                    .seg_id = wf.seg_id,
                    .offset = wf.offset,
                    .len = wf.payload_len,
                });
            }
        }
        return new_seg_id;
    }

    pub fn checkpoint(self: *Workspace, kind: CheckpointKind) !void {
        if (self.in_checkpoint) return;
        self.in_checkpoint = true;
        defer self.in_checkpoint = false;

        var snap_dir = try self.state_dir.openDir(self.io, "snap", .{ .iterate = true });
        defer snap_dir.close(self.io);
        var wal_dir = try self.state_dir.openDir(self.io, "wal", .{ .iterate = true });
        defer wal_dir.close(self.io);

        const new_seg_max = try self.sealCurrentWalIntoSegments(wal_dir);
        const wal_cutoff_seq: u64 = if (self.batch_log.next_seq > 0) self.batch_log.next_seq - 1 else self.manifest.wal_base_seq;

        const scopes_blob = try encodeScopesBlob(self.allocator, self.scopes.items);
        defer self.allocator.free(scopes_blob);

        var git_head_opt: ?[]u8 = null;
        defer if (git_head_opt) |gh| self.allocator.free(gh);
        if (self.git_dirs) |*gd| {
            if (gd.readHead(self.allocator, self.io)) |hs_val| {
                var hs = hs_val;
                defer hs.deinit(self.allocator);
                if (hs.commit) |c| {
                    git_head_opt = try self.allocator.dupe(u8, c);
                }
            } else |_| {}
        }

        const new_gen = self.manifest.generation + 1;
        const now_ms = id.nowMs(self.io);
        const has_existing_base = self.snapshot_stack != null and self.snapshot_stack.?.base != null;
        const do_delta = (kind == .minor) and has_existing_base;

        const params = snapshot_mod.WriteParams{
            .history = &self.history,
            .stack = self.snapshot_stack,
            .generation = new_gen,
            .base_generation = if (do_delta) self.manifest.base_gen else new_gen,
            .wal_cutoff_seq = wal_cutoff_seq,
            .created_ms = now_ms,
            .meta_scopes = .{
                .scopes_blob = scopes_blob,
                .retained_versions = self.retained_versions.items,
                .synced_version = self.synced_version,
                .git_head = git_head_opt,
            },
            .pruned_batches = null,
        };

        var new_manifest = self.manifest;
        new_manifest.generation = new_gen;
        new_manifest.wal_base_seq = wal_cutoff_seq;
        new_manifest.seg_max_id = new_seg_max;
        new_manifest.checkpoint_wall_ms = now_ms;
        new_manifest.pack_max_id = self.blob_store.maxPackId();
        new_manifest.pack_idx_blake3 = self.blob_store.packIdxDigest();
        if (self.history.dag.horizon.slice().len > 0) {
            new_manifest.flags |= manifest_mod.FLAG_HAS_HORIZON;
        }

        var new_base_reader: ?*snapshot_mod.SnapshotReader = null;
        defer if (new_base_reader) |r| r.release();
        var new_delta_reader: ?*snapshot_mod.SnapshotReader = null;
        defer if (new_delta_reader) |r| r.release();

        if (do_delta) {
            var dbuf: [32]u8 = undefined;
            const dname = manifest_mod.deltaSnapFileName(new_gen, &dbuf);
            const wres = try snapshot_mod.SnapshotWriter.writeDelta(self.allocator, self.io, snap_dir, dname, params);
            mmap.fsyncDir(self.io, snap_dir) catch {};

            new_manifest.delta_gen = new_gen;
            new_manifest.delta_blake3 = wres.file_blake3;
            new_manifest.total_batches = self.history.dag.count();

            new_base_reader = self.snapshot_stack.?.base.?;
            new_base_reader.?.retain();
            new_delta_reader = try snapshot_mod.SnapshotReader.open(self.allocator, self.io, snap_dir, dname);
        } else {
            var bbuf: [32]u8 = undefined;
            const bname = manifest_mod.baseSnapFileName(new_gen, &bbuf);
            const wres = try snapshot_mod.SnapshotWriter.writeCompactedBase(self.allocator, self.io, snap_dir, bname, params);
            mmap.fsyncDir(self.io, snap_dir) catch {};

            new_manifest.base_gen = new_gen;
            new_manifest.base_blake3 = wres.file_blake3;
            new_manifest.delta_gen = 0;
            new_manifest.delta_blake3 = @splat(0);
            new_manifest.total_inodes = wres.inode_count;
            new_manifest.total_batches = wres.batch_count;

            new_base_reader = try snapshot_mod.SnapshotReader.open(self.allocator, self.io, snap_dir, bname);
        }

        try self.shadow.flushAtomic(self.io, self.state_dir, SHADOW_FILE_NAME);
        self.stat_cache_dirty = false;

        const new_wal_gen = self.manifest.wal_gen + 1;
        var new_wal_buf: [32]u8 = undefined;
        const new_wal_name = manifest_mod.walFileName(new_wal_gen, &new_wal_buf);
        const new_log = try self.allocator.create(log_mod.AppendLog);
        var new_log_inited = false;
        errdefer {
            if (new_log_inited) new_log.deinit();
            self.allocator.destroy(new_log);
        }
        new_log.* = try log_mod.AppendLog.open(self.allocator, self.io, wal_dir, new_wal_name, true);
        new_log_inited = true;
        new_log.next_seq = wal_cutoff_seq + 1;
        mmap.fsyncDir(self.io, wal_dir) catch {};

        const new_stack = try snapshot_mod.SnapshotStack.create(self.allocator, new_base_reader, new_delta_reader);
        errdefer new_stack.release();

        new_manifest.wal_gen = new_wal_gen;
        try new_manifest.saveAtomic(self.io, self.state_dir);
        mmap.fsyncDir(self.io, self.state_dir) catch {};

        const old_log = self.batch_log;
        self.batch_log = new_log;
        self.history.setLogReader(.{
            .ptr = self.batch_log,
            .readFn = readBatchLogSlice,
        });
        self.batch_log_idx.clearRetainingCapacity();

        const old_stack = self.snapshot_stack;
        self.snapshot_stack = new_stack;
        self.history.attachSnapshotStack(new_stack);
        self.history.clearDirtyAfterCheckpoint();

        old_log.deinit();
        self.allocator.destroy(old_log);
        if (old_stack) |os| os.release();

        self.manifest = new_manifest;
        manifest_mod.Manifest.gcOrphanFiles(self.allocator, self.io, self.state_dir, self.manifest);
    }

    fn maybeAutoCheckpoint(self: *Workspace) void {
        if (self.in_checkpoint) return;
        const wal_batches = self.batch_log.count();
        const wal_bytes = self.batch_log.write_offset;
        const dirty_inodes = self.history.tree.dirtyInodesCount();
        if (wal_batches < AUTO_MINOR_WAL_BATCHES and wal_bytes < AUTO_MINOR_WAL_BYTES and dirty_inodes < AUTO_MINOR_DIRTY_INODES) {
            return;
        }
        const need_major = if (self.snapshot_stack) |st|
            if (st.delta) |d| d.mapped.slice().len >= AUTO_MAJOR_DELTA_BYTES else false
        else
            false;
        self.checkpoint(if (need_major) .major else .minor) catch {};
    }

    pub fn compactLog(self: *Workspace) !void {
        _ = try self.compactWithPolicy(.{});
    }

    pub fn compactWithPolicy(self: *Workspace, policy: CompactPolicy) !CompactStats {
        if (self.in_checkpoint) return .{};
        self.in_checkpoint = true;
        defer self.in_checkpoint = false;

        var stats = CompactStats{};

        var snap_dir = try self.state_dir.openDir(self.io, "snap", .{ .iterate = true });
        defer snap_dir.close(self.io);
        var wal_dir = try self.state_dir.openDir(self.io, "wal", .{ .iterate = true });
        defer wal_dir.close(self.io);

        const sealed_seg_max = try self.sealCurrentWalIntoSegments(wal_dir);
        self.manifest.seg_max_id = sealed_seg_max;
        const wal_cutoff_seq: u64 = if (self.batch_log.next_seq > 0) self.batch_log.next_seq - 1 else self.manifest.wal_base_seq;

        var retained_vers: std.ArrayList(Version) = .empty;
        defer retained_vers.deinit(self.allocator);
        try retained_vers.append(self.allocator, self.history.dag.heads);
        for (self.retained_versions.items) |rv| {
            if (!rv.isEmpty()) try retained_vers.append(self.allocator, rv);
        }
        for (self.scopes.items) |sc| {
            if (sc.ended_ms == null and !sc.start_version.isEmpty()) {
                try retained_vers.append(self.allocator, sc.start_version);
            }
        }
        if (!self.synced_version.isEmpty() and !self.synced_version.eql(&self.history.dag.heads)) {
            try retained_vers.append(self.allocator, self.synced_version);
        }

        var frontier = try self.history.dag.commonFrontier(self.allocator, retained_vers.items);
        defer frontier.deinit(self.allocator);

        var pruned_set: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        defer pruned_set.deinit(self.allocator);

        if (!frontier.isEmpty()) {
            var below = try self.history.dag.closure(self.allocator, &frontier);
            defer below.deinit(self.allocator);
            for (frontier.slice()) |fb| _ = below.remove(fb);
            for (self.history.dag.heads.slice()) |hb| _ = below.remove(hb);

            if (policy.retain_ms > 0) {
                const now_ms = id.nowMs(self.io);
                const cutoff_ms = if (now_ms > policy.retain_ms) now_ms - policy.retain_ms else 0;
                var to_unprune: std.ArrayList(id.BatchId) = .empty;
                defer to_unprune.deinit(self.allocator);
                var bit = below.keyIterator();
                while (bit.next()) |bid| {
                    if (self.history.dag.getBatchMeta(bid.*)) |meta| {
                        if (meta.wall_ms >= cutoff_ms) {
                            try to_unprune.append(self.allocator, bid.*);
                        }
                    }
                }
                for (to_unprune.items) |bid| _ = below.remove(bid);
            }

            if (policy.retain_latest_batches > 0 and below.count() > 0) {
                const BelowEntry = struct { bid: id.BatchId, ts: u64 };
                var all_below: std.ArrayList(BelowEntry) = .empty;
                defer all_below.deinit(self.allocator);
                var bit = below.keyIterator();
                while (bit.next()) |bid| {
                    try all_below.append(self.allocator, .{ .bid = bid.*, .ts = bid.ts });
                }
                std.mem.sort(BelowEntry, all_below.items, {}, struct {
                    fn lessThan(_: void, a: BelowEntry, b: BelowEntry) bool {
                        return a.ts > b.ts;
                    }
                }.lessThan);
                const keep_n = @min(policy.retain_latest_batches, all_below.items.len);
                for (all_below.items[0..keep_n]) |item| {
                    _ = below.remove(item.bid);
                }
            }

            var bit = below.keyIterator();
            while (bit.next()) |bid| {
                try pruned_set.put(self.allocator, bid.*, {});
            }
        }

        const SegLocKey = struct { seg_id: u32, offset: u64 };
        var loc_to_bid: std.AutoHashMapUnmanaged(SegLocKey, id.BatchId) = .empty;
        defer loc_to_bid.deinit(self.allocator);
        {
            var all_bids = try self.history.dag.collectAllBatchIds(self.allocator);
            defer all_bids.deinit(self.allocator);
            for (all_bids.items) |bid| {
                if (self.history.dag.getBatchLocation(bid)) |loc| {
                    if (loc.seg_id > 0) {
                        try loc_to_bid.put(self.allocator, .{ .seg_id = loc.seg_id, .offset = loc.offset }, bid);
                    }
                }
            }
        }

        const seg_bytes_before = dirTotalBytes(self.io, self.state_dir, "seg");

        const KeepCtx = struct {
            loc_map: *const std.AutoHashMapUnmanaged(SegLocKey, id.BatchId),
            pruned: *const std.AutoHashMapUnmanaged(id.BatchId, void),

            pub fn keep(ctx: @This(), ref: segments_mod.FrameRef) bool {
                if (ref.kind != FRAME_BATCH) return false;
                const bid = ctx.loc_map.get(.{ .seg_id = ref.seg_id, .offset = ref.offset }) orelse return false;
                return !ctx.pruned.contains(bid);
            }
        };
        const keep_ctx = KeepCtx{ .loc_map = &loc_to_bid, .pruned = &pruned_set };
        var prune_res = try self.segments.pruneSegments(keep_ctx);
        defer prune_res.deinit(self.allocator);

        const seg_bytes_after = dirTotalBytes(self.io, self.state_dir, "seg");
        stats.removed_segments = prune_res.removed_segments;
        stats.rewritten_segments = prune_res.rewritten_segments;
        stats.pruned_batches = pruned_set.count();
        stats.reclaimed_batch_bytes = if (seg_bytes_before > seg_bytes_after) seg_bytes_before - seg_bytes_after else 0;

        for (prune_res.remaps.items) |rm| {
            if (loc_to_bid.get(.{ .seg_id = rm.old_seg_id, .offset = rm.old_offset })) |bid| {
                try self.history.dag.setBatchLocation(self.allocator, bid, .{
                    .seg_id = rm.new_seg_id,
                    .offset = rm.new_offset,
                    .len = rm.payload_len,
                });
            }
        }

        if (pruned_set.count() > 0) {
            try self.history.dag.setHorizon(self.allocator, &frontier);
        }

        const scopes_blob = try encodeScopesBlob(self.allocator, self.scopes.items);
        defer self.allocator.free(scopes_blob);

        var git_head_opt: ?[]u8 = null;
        defer if (git_head_opt) |gh| self.allocator.free(gh);
        if (self.git_dirs) |*gd| {
            if (gd.readHead(self.allocator, self.io)) |hs_val| {
                var hs = hs_val;
                defer hs.deinit(self.allocator);
                if (hs.commit) |c| {
                    git_head_opt = try self.allocator.dupe(u8, c);
                }
            } else |_| {}
        }

        const new_gen = self.manifest.generation + 1;
        const now_ms = id.nowMs(self.io);
        const params = snapshot_mod.WriteParams{
            .history = &self.history,
            .stack = self.snapshot_stack,
            .generation = new_gen,
            .base_generation = new_gen,
            .wal_cutoff_seq = wal_cutoff_seq,
            .created_ms = now_ms,
            .meta_scopes = .{
                .scopes_blob = scopes_blob,
                .retained_versions = self.retained_versions.items,
                .synced_version = self.synced_version,
                .git_head = git_head_opt,
            },
            .pruned_batches = if (pruned_set.count() > 0) &pruned_set else null,
        };

        var bbuf: [32]u8 = undefined;
        const bname = manifest_mod.baseSnapFileName(new_gen, &bbuf);
        const wres = try snapshot_mod.SnapshotWriter.writeCompactedBase(self.allocator, self.io, snap_dir, bname, params);
        mmap.fsyncDir(self.io, snap_dir) catch {};
        stats.base_size_bytes = wres.file_size;

        const new_base_reader = try snapshot_mod.SnapshotReader.open(self.allocator, self.io, snap_dir, bname);
        defer new_base_reader.release();
        const new_stack = try snapshot_mod.SnapshotStack.create(self.allocator, new_base_reader, null);
        errdefer new_stack.release();

        if (policy.force_gc and !self.blob_store.isShared()) {
            var live_oids: std.AutoHashMapUnmanaged(crypto.Hash, void) = .empty;
            defer live_oids.deinit(self.allocator);

            try new_stack.collectReferencedBlobOids(self.allocator, &live_oids);

            const seg_ids = try self.segments.listSegmentIds(self.allocator);
            defer self.allocator.free(seg_ids);
            for (seg_ids) |sid| {
                const mf_seg = self.segments.getMapped(sid) catch continue;
                const data = mf_seg.slice();
                var off: usize = 0;
                while (off + log_mod.HEADER_SIZE <= data.len) {
                    const hdr = log_mod.FrameHeader.decode(data[off..][0..log_mod.HEADER_SIZE]) catch break;
                    const payload_start = off + log_mod.HEADER_SIZE;
                    const payload_end = payload_start + hdr.payload_len;
                    const aligned_end = log_mod.alignUp(payload_end);
                    if (aligned_end > data.len) break;
                    if (hdr.kind == FRAME_BATCH) {
                        var br = codec.Reader.init(data[payload_start..payload_end]);
                        if (op_mod.Batch.decode(self.allocator, &br)) |b_val| {
                            var b = b_val;
                            defer b.deinit(self.allocator);
                            for (b.ops) |op| {
                                const maybe_oid: ?id.Oid = switch (op) {
                                    .create_file => |cf| switch (cf.content) {
                                        .binary => |x| x.oid,
                                        .text_blob => |x| x.oid,
                                        else => null,
                                    },
                                    .set_content => |sc| switch (sc.content) {
                                        .binary => |x| x.oid,
                                        .text_blob => |x| x.oid,
                                        else => null,
                                    },
                                    else => null,
                                };
                                if (maybe_oid) |oid| try live_oids.put(self.allocator, oid, {});
                            }
                        } else |_| {}
                    }
                    off = aligned_end;
                }
            }

            try self.blob_store.sealActivePack();
            const gc_res = try self.blob_store.gc(&live_oids);
            stats.removed_blobs = gc_res.removed_blobs;
            stats.reclaimed_blob_bytes = gc_res.reclaimed_bytes;
        }

        try self.shadow.flushAtomic(self.io, self.state_dir, SHADOW_FILE_NAME);
        self.stat_cache_dirty = false;

        const new_wal_gen = self.manifest.wal_gen + 1;
        var new_wal_buf: [32]u8 = undefined;
        const new_wal_name = manifest_mod.walFileName(new_wal_gen, &new_wal_buf);
        const new_log = try self.allocator.create(log_mod.AppendLog);
        var new_log_inited = false;
        errdefer {
            if (new_log_inited) new_log.deinit();
            self.allocator.destroy(new_log);
        }
        new_log.* = try log_mod.AppendLog.open(self.allocator, self.io, wal_dir, new_wal_name, true);
        new_log_inited = true;
        new_log.next_seq = wal_cutoff_seq + 1;
        mmap.fsyncDir(self.io, wal_dir) catch {};

        var new_manifest = self.manifest;
        new_manifest.generation = new_gen;
        new_manifest.base_gen = new_gen;
        new_manifest.base_blake3 = wres.file_blake3;
        new_manifest.delta_gen = 0;
        new_manifest.delta_blake3 = @splat(0);
        new_manifest.wal_gen = new_wal_gen;
        new_manifest.wal_base_seq = wal_cutoff_seq;
        new_manifest.seg_max_id = @max(prune_res.max_seg_id, self.manifest.seg_max_id);
        new_manifest.pack_max_id = self.blob_store.maxPackId();
        new_manifest.pack_idx_blake3 = self.blob_store.packIdxDigest();
        new_manifest.checkpoint_wall_ms = now_ms;
        new_manifest.total_inodes = wres.inode_count;
        new_manifest.total_batches = wres.batch_count;
        if (self.history.dag.horizon.slice().len > 0) {
            new_manifest.flags |= manifest_mod.FLAG_HAS_HORIZON;
        }
        try new_manifest.saveAtomic(self.io, self.state_dir);
        mmap.fsyncDir(self.io, self.state_dir) catch {};

        const old_log = self.batch_log;
        self.batch_log = new_log;
        self.history.setLogReader(.{
            .ptr = self.batch_log,
            .readFn = readBatchLogSlice,
        });
        self.batch_log_idx.clearRetainingCapacity();

        const old_stack = self.snapshot_stack;
        self.snapshot_stack = new_stack;
        self.history.attachSnapshotStack(new_stack);
        self.history.clearDirtyAfterCheckpoint();

        old_log.deinit();
        self.allocator.destroy(old_log);
        if (old_stack) |os| os.release();

        self.manifest = new_manifest;
        manifest_mod.Manifest.gcOrphanFiles(self.allocator, self.io, self.state_dir, self.manifest);
        return stats;
    }

    fn watchIgnoreFilter(ctx: ?*const anyopaque, rel_path: []const u8, is_dir: bool) bool {
        const gi: *const GitIgnore = @ptrCast(@alignCast(ctx orelse return false));
        return gi.isPathOrAncestorIgnored(rel_path, is_dir);
    }

    fn commonDirOpt(self: *const Workspace) ?[]const u8 {
        if (self.git_dirs) |*gd| return gd.common_dir;
        return null;
    }

    pub fn attachWatcher(self: *Workspace) !void {
        if (self.watcher != null) return;
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir, self.commonDirOpt());
        var w = try watch.SharedWatcher.init(self.allocator);
        errdefer w.deinit();
        _ = try w.registerMount(self.io, 1, self.root_path, .{
            .ctx = &self.gitignore,
            .should_ignore = watchIgnoreFilter,
        });
        self.watcher = w;
    }

    pub fn wakeWatcher(self: *const Workspace) void {
        if (self.watcher) |*w| w.wake();
    }

    pub fn waitWatcher(self: *const Workspace, timeout_ms: i32) watch.WaitResult {
        if (self.watcher) |*w| return w.wait(timeout_ms);
        return .{};
    }

    pub fn drainWatched(self: *Workspace, source: []const u8) !?id.BatchId {
        if (self.watcher) |*w| {
            if (w.mountMode(1) == .stat_on_demand) {
                return try self.ingestDiskWithSource(source);
            }
            var events: std.ArrayList(watch.WatchEvent) = .empty;
            defer {
                for (events.items) |*ev| ev.deinit(self.allocator);
                events.deinit(self.allocator);
            }
            const d = try w.drain(self.io, &events);
            if (!d.overflow and d.count == 0) return null;
            return try self.ingestWatchEvents(events.items, d.overflow, source);
        }
        return try self.ingestDiskWithSource(source);
    }

    pub fn watchStep(self: *Workspace, timeout_ms: i32, source: []const u8) !WatchStepResult {
        if (self.watcher == null) try self.attachWatcher();
        if (self.watcher.?.mountMode(1) == .stat_on_demand) {
            const bid = try self.ingestDiskWithSource(source);
            return .{
                .batch_id = bid,
                .woken = false,
                .events = 0,
            };
        }
        var events: std.ArrayList(watch.WatchEvent) = .empty;
        defer {
            for (events.items) |*ev| ev.deinit(self.allocator);
            events.deinit(self.allocator);
        }
        const poll_res = try self.watcher.?.poll(self.io, timeout_ms, &events);
        var bid: ?id.BatchId = null;
        if (poll_res.overflow or poll_res.count > 0) {
            bid = try self.ingestWatchEvents(events.items, poll_res.overflow, source);
        }
        return .{
            .batch_id = bid,
            .woken = poll_res.woken,
            .events = poll_res.count,
        };
    }

    pub fn ingestWatchEvents(
        self: *Workspace,
        events: []const watch.WatchEvent,
        overflow: bool,
        source: []const u8,
    ) !?id.BatchId {
        if (overflow) return try self.ingestDiskWithSource(source);
        if (events.len == 0) return null;
        var rels: std.ArrayList([]const u8) = .empty;
        defer rels.deinit(self.allocator);
        var dirs: std.ArrayList([]const u8) = .empty;
        defer dirs.deinit(self.allocator);
        for (events) |ev| {
            if (ev.rel_path.len == 0) continue;
            if (watch.isIgnoredPath(ev.rel_path)) continue;
            if (ev.is_dir) {
                try dirs.append(self.allocator, ev.rel_path);
            } else {
                try rels.append(self.allocator, ev.rel_path);
            }
        }
        if (rels.items.len == 0 and dirs.items.len == 0) return null;
        return try self.ingestPaths(rels.items, dirs.items, source);
    }

    pub fn hibernate(self: *Workspace) void {
        if (self.batch_log.count() > 0 or self.history.tree.dirtyInodesCount() > 0) {
            self.checkpoint(.minor) catch {};
        } else if (self.stat_cache_dirty or self.shadow.dirtyCount() > 0) {
            self.saveStatCache() catch {};
        }
        self.history.hibernate();
        if (self.snapshot_stack) |st| st.hibernate();
        self.shadow.hibernate();
        self.segments.hibernate();
        self.batch_log.hibernate();
        if (!self.blob_store.isShared()) {
            self.blob_store.hibernate();
        }
        if (self.git_odb) |odb| {
            if (!self.uses_shared_git_odb) odb.hibernate();
        }
    }

    fn replayLogAfterSeq(self: *Workspace, min_exclusive_seq: u64) !void {
        const n = self.batch_log.count();
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);
        var replayed_any = false;
        for (0..n) |i| {
            const entry_seq = self.batch_log.index.items[i].seq;
            if (entry_seq <= min_exclusive_seq) continue;
            const view = try self.batch_log.readAt(i);
            if (view.header.kind == FRAME_SCOPE) {
                var sr = codec.Reader.init(view.payload);
                const rec = ScopeRecord.decode(self.allocator, &sr) catch continue;
                try self.upsertScopeRecord(rec);
                continue;
            }
            if (view.header.kind == FRAME_SCOPE_BATCH) {
                if (view.payload.len >= 40) {
                    const sid = std.mem.readInt(u128, view.payload[0..16], .little);
                    const bid = id.BatchId{
                        .actor = std.mem.readInt(u128, view.payload[16..32], .little),
                        .ts = std.mem.readInt(u64, view.payload[32..40], .little),
                    };
                    for (self.scopes.items) |*s| {
                        if (s.scope_id == sid) {
                            try s.batches.append(self.allocator, bid);
                            break;
                        }
                    }
                }
                continue;
            }
            if (view.header.kind == FRAME_SCOPE_END) {
                if (view.payload.len >= 24) {
                    const sid = std.mem.readInt(u128, view.payload[0..16], .little);
                    const ended_ms = std.mem.readInt(u64, view.payload[16..24], .little);
                    for (self.scopes.items) |*s| {
                        if (s.scope_id == sid) {
                            s.ended_ms = ended_ms;
                            break;
                        }
                    }
                }
                continue;
            }
            if (view.header.kind != FRAME_BATCH) continue;
            const payload_off = try self.batch_log.payloadOffsetAt(i);
            op_spans.clearRetainingCapacity();
            blob_spans.clearRetainingCapacity();
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decodeWithSpans(self.allocator, &r, &op_spans, &blob_spans);
            defer batch.deinit(self.allocator);
            const bid = batch.header.batchId();
            try self.batch_log_idx.put(self.allocator, bid, i);
            for (batch.blobs) |b| {
                if (!self.blob_store.exists(b.oid)) {
                    try self.blob_store.putVerified(b.oid, b.data);
                }
            }
            if (try self.history.integrate(&batch)) {
                self.history.pinBatchToLog(&batch, payload_off, op_spans.items, blob_spans.items);
                replayed_any = true;
            }
        }
        if (replayed_any or self.synced_version.isEmpty()) {
            self.synced_version.deinit(self.allocator);
            self.synced_version = try self.history.headsClone();
        }
    }

    fn persistBatch(self: *Workspace, batch: *const op_mod.Batch) !void {
        if (batch.blobs.len > 1) {
            var items = try self.allocator.alloc(blobs_mod.BlobItem, batch.blobs.len);
            defer self.allocator.free(items);
            for (batch.blobs, 0..) |b, idx| {
                items[idx] = .{ .hash = b.oid, .data = b.data };
            }
            try self.blob_store.putBatch(items);
        } else if (batch.blobs.len == 1) {
            try self.blob_store.putVerified(batch.blobs[0].oid, batch.blobs[0].data);
        }

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);
        try batch.encodeWithSpans(self.allocator, &w, &op_spans, &blob_spans);
        const log_idx = self.batch_log.count();
        const app = try self.batch_log.appendWithOffset(self.batch_log.next_seq, FRAME_BATCH, 0, 0, w.items());
        const bid = batch.header.batchId();
        try self.batch_log_idx.put(self.allocator, bid, log_idx);
        self.history.pinBatchToLog(batch, app.payload_offset, op_spans.items, blob_spans.items);

        if (self.active_scope) |sid| {
            for (self.scopes.items) |*s| {
                if (s.scope_id == sid) {
                    try s.batches.append(self.allocator, bid);
                    try self.persistScopeBatch(sid, bid);
                    break;
                }
            }
        }
    }

    pub fn commitBatch(self: *Workspace, batch: *const op_mod.Batch) !bool {
        return self.commitBatchWithSource(batch, "commit");
    }

    pub fn commitBatchWithSource(self: *Workspace, batch: *const op_mod.Batch, source: []const u8) !bool {
        if (self.observer) |obs| {
            var delta_opt = try self.history.integrateWithDelta(self.allocator, batch);
            if (delta_opt == null) return false;
            defer delta_opt.?.deinit(self.allocator);
            try self.persistBatch(batch);
            obs.on_commit(obs.ptr, source, &delta_opt.?);
            self.maybeAutoCheckpoint();
            return true;
        }
        const applied = try self.history.integrate(batch);
        if (!applied) return false;
        try self.persistBatch(batch);
        self.maybeAutoCheckpoint();
        return true;
    }

    fn updateShadowForPath(self: *Workspace, rel: []const u8, stamp: StatStamp, iid_opt: ?id.InodeId, git_oid_opt: ?git_dirs_mod.GitOid, blob_oid_opt: ?id.Oid) void {
        const iid = iid_opt orelse (self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel) catch null) orelse id.InodeId.ROOT;
        var entry = shadow_mod.ShadowEntry{
            .inode_id = iid,
            .kind = if (stamp.kind == .symlink) .symlink else .file,
            .mode = @intFromEnum(stamp.mode),
            .size = stamp.size,
            .mtime_ns = stamp.mtime_ns,
            .ino = stamp.ino,
        };
        if (git_oid_opt) |goid| {
            entry.has_git_oid = true;
            entry.git_oid_len = goid.len;
            entry.git_oid = goid.bytes;
        }
        if (blob_oid_opt) |boid| {
            entry.has_blob_oid = true;
            entry.blob_oid = boid;
        }
        self.shadow.put(rel, entry) catch return;
        self.stat_cache_dirty = true;
    }

    fn removeStatCache(self: *Workspace, rel: []const u8) void {
        self.shadow.remove(rel) catch return;
        self.stat_cache_dirty = true;
    }

    fn recordStatFromDisk(self: *Workspace, rel: []const u8) void {
        const st = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch {
            self.removeStatCache(rel);
            return;
        };
        const sk: StatKind = switch (st.kind) {
            .file => .file,
            .sym_link => .symlink,
            else => {
                self.removeStatCache(rel);
                return;
            },
        };
        self.updateShadowForPath(rel, .{
            .size = st.size,
            .mtime_ns = st.mtime.nanoseconds,
            .mode = if (sk == .file) fileModeFromStat(st) else .regular,
            .kind = sk,
            .ino = st.inode,
        }, null, null, null);
    }

    fn refreshGitIndexIfNeeded(self: *Workspace) void {
        const gd = if (self.git_dirs) |*g| g else return;
        if (self.git_odb == null) return;
        const stamp = (gd.indexStamp(self.io) catch null) orelse return;
        if (self.git_index_stamp) |prev| {
            if (prev.mtime_ns == stamp.mtime_ns and prev.size == stamp.size and prev.ino == stamp.ino) return;
        }
        if (self.git_index) |*old| {
            old.deinit(self.allocator);
            self.git_index = null;
        }
        self.git_index = git_index_mod.GitIndex.load(self.allocator, self.io, gd) catch null;
        self.git_index_stamp = stamp;
    }

    fn queueGitPin(self: *Workspace, oid: git_dirs_mod.GitOid, new_pins: *std.ArrayList(git_dirs_mod.GitOid)) !void {
        if (self.pinned_git_oids.contains(oid)) return;
        try self.pinned_git_oids.put(self.allocator, oid, {});
        try new_pins.append(self.allocator, oid);
    }

    fn flushGitPins(self: *Workspace, new_pins: []const git_dirs_mod.GitOid) void {
        if (new_pins.len == 0) return;
        const odb = self.git_odb orelse return;
        var all_oids: std.ArrayList(git_dirs_mod.GitOid) = .empty;
        defer all_oids.deinit(self.allocator);
        all_oids.ensureTotalCapacityPrecise(self.allocator, self.pinned_git_oids.count()) catch return;
        var it = self.pinned_git_oids.keyIterator();
        while (it.next()) |k| all_oids.appendAssumeCapacity(k.*);
        odb.pinOids(all_oids.items) catch {};
    }

    fn makeFileContentAndMeta(
        self: *Workspace,
        raw_bytes: []const u8,
        blobs: *std.ArrayList(op_mod.BlobAttachment),
        new_pins: ?*std.ArrayList(git_dirs_mod.GitOid),
    ) !struct { content: op_mod.Content, line_ending: tree_mod.LineEnding, is_binary: bool, git_oid: ?git_dirs_mod.GitOid = null, blob_oid: ?id.Oid = null } {
        const is_bin = isBinaryBytes(raw_bytes);
        if (self.git_odb) |odb| {
            if (self.git_dirs) |*gd| {
                const goid = git_dirs_mod.GitOid.ofBlob(gd.config.object_format, raw_bytes);
                if (odb.contains(goid)) {
                    if (new_pins) |np| try self.queueGitPin(goid, np);
                    if (is_bin) {
                        return .{
                            .content = .{ .git_binary = .{ .oid = goid, .len = raw_bytes.len } },
                            .line_ending = .lf,
                            .is_binary = true,
                            .git_oid = goid,
                        };
                    }
                    const ending = detectLineEnding(raw_bytes);
                    if (ending == .lf) {
                        return .{
                            .content = .{ .git_lazy = .{ .oid = goid, .len = raw_bytes.len } },
                            .line_ending = .lf,
                            .is_binary = false,
                            .git_oid = goid,
                        };
                    }
                }
            }
        }
        if (is_bin) {
            const oid = crypto.hashBytes(raw_bytes);
            try blobs.append(self.allocator, .{
                .oid = oid,
                .data = try self.allocator.dupe(u8, raw_bytes),
            });
            return .{
                .content = .{ .binary = .{ .oid = oid, .len = raw_bytes.len } },
                .line_ending = .lf,
                .is_binary = true,
                .blob_oid = oid,
            };
        }
        const ending = detectLineEnding(raw_bytes);
        const norm = try normalizeToLf(self.allocator, raw_bytes);
        defer self.allocator.free(norm);
        const pair = try op_mod.makeTextContent(self.allocator, norm);
        var boid: ?id.Oid = null;
        if (pair[1]) |b| {
            boid = b.oid;
            try blobs.append(self.allocator, b);
        }
        return .{
            .content = pair[0],
            .line_ending = ending,
            .is_binary = false,
            .blob_oid = boid,
        };
    }

    fn emitUpdateFileOps(
        self: *Workspace,
        iid: id.InodeId,
        raw_bytes: []const u8,
        disk_mode: tree_mod.FileMode,
        ops: *std.ArrayList(op_mod.Op),
        blobs: *std.ArrayList(op_mod.BlobAttachment),
        new_pins: ?*std.ArrayList(git_dirs_mod.GitOid),
    ) !void {
        self.history.tree.beginPinScope();
        defer self.history.tree.endPinScope();
        const inode = self.history.tree.get(iid) orelse return;
        const f = inode.fileConstPtr() orelse return;
        const cur_ck = f.content.get() orelse return;
        const cur_mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
        const cur_ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;

        if (disk_mode != cur_mode) {
            try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = disk_mode } });
        }

        const new_is_bin = isBinaryBytes(raw_bytes);
        if (new_is_bin) {
            if (self.git_odb) |odb| {
                if (self.git_dirs) |*gd| {
                    const goid = git_dirs_mod.GitOid.ofBlob(gd.config.object_format, raw_bytes);
                    if (odb.contains(goid)) {
                        const same_git = switch (cur_ck.*) {
                            .git_binary => |ref| ref.oid.eql(goid) and ref.len == raw_bytes.len,
                            else => false,
                        };
                        if (!same_git) {
                            if (new_pins) |np| try self.queueGitPin(goid, np);
                            try ops.append(self.allocator, .{ .set_content = .{
                                .inode = iid,
                                .content = .{ .git_binary = .{ .oid = goid, .len = raw_bytes.len } },
                            } });
                        }
                        return;
                    }
                }
            }
            const new_oid = crypto.hashBytes(raw_bytes);
            const same_bin = switch (cur_ck.*) {
                .binary => |ref| std.mem.eql(u8, &ref.oid, &new_oid) and ref.len == raw_bytes.len,
                .git_binary => |ref| blk: {
                    const existing = (try self.history.readGitBlobAlloc(self.allocator, ref.oid)) orelse break :blk false;
                    defer self.allocator.free(existing);
                    break :blk std.mem.eql(u8, existing, raw_bytes);
                },
                .text, .git_lazy => false,
            };
            if (!same_bin) {
                try blobs.append(self.allocator, .{
                    .oid = new_oid,
                    .data = try self.allocator.dupe(u8, raw_bytes),
                });
                try ops.append(self.allocator, .{ .set_content = .{
                    .inode = iid,
                    .content = .{ .binary = .{ .oid = new_oid, .len = raw_bytes.len } },
                } });
            }
            return;
        }

        const new_ending = detectLineEnding(raw_bytes);
        if (new_ending != cur_ending) {
            try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = new_ending } });
        }
        const norm = try normalizeToLf(self.allocator, raw_bytes);
        defer self.allocator.free(norm);

        switch (cur_ck.*) {
            .binary, .git_binary => {
                const pair = try op_mod.makeTextContent(self.allocator, norm);
                if (pair[1]) |b| try blobs.append(self.allocator, b);
                try ops.append(self.allocator, .{ .set_content = .{
                    .inode = iid,
                    .content = pair[0],
                } });
            },
            .git_lazy => |ref| {
                const cur_raw = (try self.history.readGitBlobAlloc(self.allocator, ref.oid)) orelse "";
                defer if (cur_raw.len > 0) self.allocator.free(cur_raw);
                const cur_norm = try normalizeToLf(self.allocator, cur_raw);
                defer self.allocator.free(cur_norm);
                if (!std.mem.eql(u8, cur_norm, norm)) {
                    var d = try diff.diffBytes(self.allocator, cur_norm, norm);
                    errdefer d.deinit(self.allocator);
                    try ops.append(self.allocator, .{ .edit_text = .{
                        .inode = iid,
                        .text = try d.inserted.toOwnedSlice(self.allocator),
                        .splices = try d.splices.toOwnedSlice(self.allocator),
                    } });
                }
            },
            .text => {
                const cur_text_opt = try f.text.read(self.allocator, self.history.resolver());
                defer if (cur_text_opt) |c| self.allocator.free(c);
                const cur_text = cur_text_opt orelse "";
                if (!std.mem.eql(u8, cur_text, norm)) {
                    var d = try diff.diffBytes(self.allocator, cur_text, norm);
                    errdefer d.deinit(self.allocator);
                    try ops.append(self.allocator, .{ .edit_text = .{
                        .inode = iid,
                        .text = try d.inserted.toOwnedSlice(self.allocator),
                        .splices = try d.splices.toOwnedSlice(self.allocator),
                    } });
                }
            },
        }
    }

    pub fn ingestDisk(self: *Workspace) !?id.BatchId {
        return self.ingestDiskWithSource("disk");
    }

    pub fn ingestDiskWithSource(self: *Workspace, source: []const u8) !?id.BatchId {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir, self.commonDirOpt());
        self.refreshGitIndexIfNeeded();

        const use_shadow_tracking = self.shadow.count() > 0 or self.history.dag.count() == 0;
        var existing_paths: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var it = existing_paths.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            existing_paths.deinit(self.allocator);
        }
        if (!use_shadow_tracking) {
            try self.collectTrackedPaths(id.InodeId.ROOT, "", &existing_paths);
        }

        var disk_entries: std.StringHashMapUnmanaged(DiskEntry) = .empty;
        defer {
            var it = disk_entries.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                kv.value_ptr.deinit(self.allocator);
            }
            disk_entries.deinit(self.allocator);
        }
        var skipped_oversize: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = skipped_oversize.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            skipped_oversize.deinit(self.allocator);
        }
        try self.scanDir("", use_shadow_tracking, &existing_paths, &disk_entries, &skipped_oversize);

        var ops: std.ArrayList(op_mod.Op) = .empty;
        defer {
            for (ops.items) |*o| o.deinit(self.allocator);
            ops.deinit(self.allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        defer {
            for (blobs.items) |*b| b.deinit(self.allocator);
            blobs.deinit(self.allocator);
        }
        var new_pins: std.ArrayList(git_dirs_mod.GitOid) = .empty;
        defer new_pins.deinit(self.allocator);

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const base_start_ts = self.history.nextStartTs(&parents);

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var pit = pending_dirs.keyIterator();
            while (pit.next()) |k| self.allocator.free(k.*);
            pending_dirs.deinit(self.allocator);
        }

        const MissingTracked = struct {
            rel: []u8,
            iid: id.InodeId,
            hash: ?crypto.Hash,
            ino: u64,
        };
        var missing_tracked: std.ArrayList(MissingTracked) = .empty;
        defer {
            for (missing_tracked.items) |m| self.allocator.free(m.rel);
            missing_tracked.deinit(self.allocator);
        }

        if (use_shadow_tracking) {
            var sit = try self.shadow.iterateAll(self.allocator);
            defer sit.deinit();
            while (try sit.next()) |item| {
                if (disk_entries.contains(item.rel_path)) continue;
                if (skipped_oversize.contains(item.rel_path)) continue;
                const resolved_iid = (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, item.rel_path)) orelse {
                    self.removeStatCache(item.rel_path);
                    continue;
                };
                var h: ?crypto.Hash = if (item.entry.has_blob_oid) item.entry.blob_oid else null;
                if (h == null) {
                    self.history.tree.beginPinScope();
                    defer self.history.tree.endPinScope();
                    if (self.history.tree.get(resolved_iid)) |inode| {
                        if (inode.fileConstPtr()) |f| {
                            if (try self.readInodeDiskBytes(f)) |old_b| {
                                defer self.allocator.free(old_b);
                                h = crypto.hashBytes(old_b);
                            }
                        }
                    }
                }
                try missing_tracked.append(self.allocator, .{
                    .rel = try self.allocator.dupe(u8, item.rel_path),
                    .iid = resolved_iid,
                    .hash = h,
                    .ino = item.entry.ino,
                });
            }
        } else {
            var eit = existing_paths.iterator();
            while (eit.next()) |kv| {
                const rel = kv.key_ptr.*;
                if (disk_entries.contains(rel)) continue;
                if (skipped_oversize.contains(rel)) continue;
                const iid = kv.value_ptr.*;
                var h: ?crypto.Hash = null;
                {
                    self.history.tree.beginPinScope();
                    defer self.history.tree.endPinScope();
                    if (self.history.tree.get(iid)) |inode| {
                        if (inode.fileConstPtr()) |f| {
                            if (try self.readInodeDiskBytes(f)) |old_b| {
                                defer self.allocator.free(old_b);
                                h = crypto.hashBytes(old_b);
                            }
                        }
                    }
                }
                try missing_tracked.append(self.allocator, .{
                    .rel = try self.allocator.dupe(u8, rel),
                    .iid = iid,
                    .hash = h,
                    .ino = 0,
                });
            }
        }

        var missing_by_hash: std.AutoHashMapUnmanaged(crypto.Hash, ?usize) = .empty;
        defer missing_by_hash.deinit(self.allocator);
        var missing_by_ino: std.AutoHashMapUnmanaged(u64, ?usize) = .empty;
        defer missing_by_ino.deinit(self.allocator);
        for (missing_tracked.items, 0..) |m, idx| {
            if (m.hash) |mh| {
                const gop = try missing_by_hash.getOrPut(self.allocator, mh);
                gop.value_ptr.* = if (!gop.found_existing) idx else null;
            }
            if (m.ino != 0) {
                const gop = try missing_by_ino.getOrPut(self.allocator, m.ino);
                gop.value_ptr.* = if (!gop.found_existing) idx else null;
            }
        }

        var new_hash_counts: std.AutoHashMapUnmanaged(crypto.Hash, usize) = .empty;
        defer new_hash_counts.deinit(self.allocator);
        if (missing_tracked.items.len > 0) {
            var nit = disk_entries.iterator();
            while (nit.next()) |kv| {
                const is_existing = if (use_shadow_tracking)
                    (self.shadow.get(kv.key_ptr.*) catch null) != null
                else
                    existing_paths.contains(kv.key_ptr.*);
                if (is_existing) continue;
                switch (kv.value_ptr.*) {
                    .file => |f| {
                        const nh = crypto.hashBytes(f.bytes);
                        const gop = try new_hash_counts.getOrPut(self.allocator, nh);
                        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                    },
                    else => {},
                }
            }
        }

        var renamed_missing = try self.allocator.alloc(bool, missing_tracked.items.len);
        defer self.allocator.free(renamed_missing);
        @memset(renamed_missing, false);

        const PendingShadow = struct {
            rel: []const u8,
            stamp: StatStamp,
            iid: id.InodeId,
            git_oid: ?git_dirs_mod.GitOid = null,
            blob_oid: ?id.Oid = null,
        };
        var shadow_updates: std.ArrayList(PendingShadow) = .empty;
        defer shadow_updates.deinit(self.allocator);

        var dit = disk_entries.iterator();
        while (dit.next()) |kv| {
            const rel = kv.key_ptr.*;
            const entry = kv.value_ptr.*;
            if (entry == .unchanged) continue;

            const existing_iid: ?id.InodeId = if (use_shadow_tracking) blk: {
                if (self.shadow.get(rel) catch null) |se| {
                    if (!se.inode_id.eql(id.InodeId.ROOT)) break :blk se.inode_id;
                }
                break :blk try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
            } else existing_paths.get(rel);

            if (existing_iid) |iid| {
                switch (entry) {
                    .unchanged => {},
                    .git_clean => |gc| {
                        try self.queueGitPin(gc.oid, &new_pins);
                        self.history.tree.beginPinScope();
                        const inode_opt = self.history.tree.get(iid);
                        const is_file = if (inode_opt) |in| in.fileConstPtr() != null else false;
                        const same_git_and_mode = if (inode_opt) |in| blk: {
                            const fp = in.fileConstPtr() orelse break :blk false;
                            const cm = if (fp.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                            if (cm != gc.mode) break :blk false;
                            const ck = fp.content.get() orelse break :blk false;
                            break :blk switch (ck.*) {
                                .git_lazy => |r| r.oid.eql(gc.oid) and r.len == gc.len,
                                .git_binary => |r| r.oid.eql(gc.oid) and r.len == gc.len,
                                else => false,
                            };
                        } else false;
                        self.history.tree.endPinScope();
                        if (!same_git_and_mode) {
                            if (is_file) {
                                try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = gc.mode } });
                                try ops.append(self.allocator, .{ .set_content = .{
                                    .inode = iid,
                                    .content = .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } },
                                } });
                            } else {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                const base_name = std.fs.path.basename(rel);
                                const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                                try ops.append(self.allocator, .{ .create_file = .{
                                    .parent = parent_iid,
                                    .name = try self.allocator.dupe(u8, base_name),
                                    .mode = gc.mode,
                                    .line_ending = .lf,
                                    .content = .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } },
                                } });
                                try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = new_iid, .git_oid = gc.oid });
                                continue;
                            }
                        }
                        try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = iid, .git_oid = gc.oid });
                    },
                    .file => |df| {
                        self.history.tree.beginPinScope();
                        const is_file = if (self.history.tree.get(iid)) |in| in.fileConstPtr() != null else false;
                        self.history.tree.endPinScope();
                        if (is_file) {
                            try self.emitUpdateFileOps(iid, df.bytes, df.mode, &ops, &blobs, &new_pins);
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = iid });
                        } else {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs, &new_pins);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = df.mode,
                                .line_ending = cm.line_ending,
                                .content = cm.content,
                            } });
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = new_iid, .git_oid = cm.git_oid, .blob_oid = cm.blob_oid });
                        }
                    },
                    .symlink => |ds| {
                        self.history.tree.beginPinScope();
                        const inode_opt = self.history.tree.get(iid);
                        const is_symlink = if (inode_opt) |in| in.kind == .symlink else false;
                        const same_target = if (inode_opt) |in| switch (in.kind) {
                            .symlink => |*sl| std.mem.eql(u8, if (sl.get()) |t| t.* else "", ds.target),
                            else => false,
                        } else false;
                        self.history.tree.endPinScope();
                        if (is_symlink) {
                            if (!same_target) {
                                try ops.append(self.allocator, .{ .set_symlink_target = .{
                                    .inode = iid,
                                    .target = try self.allocator.dupe(u8, ds.target),
                                } });
                            }
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = ds.stamp, .iid = iid });
                        } else {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                            try ops.append(self.allocator, .{ .create_symlink = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .target = try self.allocator.dupe(u8, ds.target),
                            } });
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = ds.stamp, .iid = new_iid });
                        }
                    },
                }
            } else {
                switch (entry) {
                    .unchanged => {},
                    .git_clean => |gc| {
                        try self.queueGitPin(gc.oid, &new_pins);
                        var did_rename = false;
                        var target_iid = id.InodeId.ROOT;
                        if (gc.stamp.ino != 0) {
                            if (missing_by_ino.get(gc.stamp.ino)) |maybe_idx| {
                                if (maybe_idx) |midx| {
                                    if (!renamed_missing[midx]) {
                                        renamed_missing[midx] = true;
                                        did_rename = true;
                                        const old_iid = missing_tracked.items[midx].iid;
                                        target_iid = old_iid;
                                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                        const base_name = std.fs.path.basename(rel);
                                        try ops.append(self.allocator, .{ .rename = .{
                                            .inode = old_iid,
                                            .parent = parent_iid,
                                            .name = try self.allocator.dupe(u8, base_name),
                                        } });
                                    }
                                }
                            }
                        }
                        if (!did_rename) {
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            target_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = gc.mode,
                                .line_ending = .lf,
                                .content = .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } },
                            } });
                        }
                        try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = target_iid, .git_oid = gc.oid });
                    },
                    .file => |df| {
                        var did_rename = false;
                        var target_iid = id.InodeId.ROOT;
                        if (df.stamp.ino != 0 and missing_tracked.items.len > 0) {
                            if (missing_by_ino.get(df.stamp.ino)) |maybe_idx| {
                                if (maybe_idx) |midx| {
                                    if (!renamed_missing[midx]) {
                                        renamed_missing[midx] = true;
                                        did_rename = true;
                                        const old_iid = missing_tracked.items[midx].iid;
                                        target_iid = old_iid;
                                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                        const base_name = std.fs.path.basename(rel);
                                        try ops.append(self.allocator, .{ .rename = .{
                                            .inode = old_iid,
                                            .parent = parent_iid,
                                            .name = try self.allocator.dupe(u8, base_name),
                                        } });
                                        try self.emitUpdateFileOps(old_iid, df.bytes, df.mode, &ops, &blobs, &new_pins);
                                    }
                                }
                            }
                        }
                        if (!did_rename and missing_tracked.items.len > 0) {
                            const nh = crypto.hashBytes(df.bytes);
                            if (new_hash_counts.get(nh) == 1) {
                                if (missing_by_hash.get(nh)) |maybe_idx| {
                                    if (maybe_idx) |midx| {
                                        if (!renamed_missing[midx]) {
                                            renamed_missing[midx] = true;
                                            did_rename = true;
                                            const old_iid = missing_tracked.items[midx].iid;
                                            target_iid = old_iid;
                                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                            const base_name = std.fs.path.basename(rel);
                                            try ops.append(self.allocator, .{ .rename = .{
                                                .inode = old_iid,
                                                .parent = parent_iid,
                                                .name = try self.allocator.dupe(u8, base_name),
                                            } });
                                            try self.emitUpdateFileOps(old_iid, df.bytes, df.mode, &ops, &blobs, &new_pins);
                                        }
                                    }
                                }
                            }
                        }
                        if (!did_rename) {
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs, &new_pins);
                            target_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = df.mode,
                                .line_ending = cm.line_ending,
                                .content = cm.content,
                            } });
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = target_iid, .git_oid = cm.git_oid, .blob_oid = cm.blob_oid });
                        } else {
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = target_iid });
                        }
                    },
                    .symlink => |ds| {
                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                        try ops.append(self.allocator, .{ .create_symlink = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .target = try self.allocator.dupe(u8, ds.target),
                        } });
                        try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = ds.stamp, .iid = new_iid });
                    },
                }
            }
        }

        for (missing_tracked.items, 0..) |m, idx| {
            self.removeStatCache(m.rel);
            if (!renamed_missing[idx]) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = m.iid } });
            }
        }

        self.flushGitPins(new_pins.items);

        for (shadow_updates.items) |su| {
            self.updateShadowForPath(su.rel, su.stamp, su.iid, su.git_oid, su.blob_oid);
        }

        if (ops.items.len == 0) return null;

        const batch_parents = try parents.clone(self.allocator);
        const end = base_start_ts + @as(u64, @intCast(ops.items.len)) - 1;
        var batch = op_mod.Batch{
            .header = .{
                .actor = self.disk_actor,
                .start = base_start_ts,
                .end = end,
                .parents = batch_parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = try ops.toOwnedSlice(self.allocator),
            .blobs = try blobs.toOwnedSlice(self.allocator),
        };
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
        return batch.header.batchId();
    }

    fn collectDiskPathsInDir(
        self: *Workspace,
        rel_dir: []const u8,
        out: *std.StringHashMapUnmanaged(void),
    ) !void {
        var dir = if (rel_dir.len == 0)
            try self.work_dir.openDir(self.io, ".", .{ .iterate = true })
        else
            self.work_dir.openDir(self.io, rel_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        self.gitignore.loadNestedForDir(self.allocator, self.io, dir, rel_dir);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') {
                if (std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".0ndb")) continue;
                if (std.mem.endsWith(u8, name, ".0ndb-tmp") or std.mem.endsWith(u8, name, ".0ndb-sym-tmp")) continue;
            }
            const child_rel = if (rel_dir.len == 0)
                try self.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_dir, name });
            errdefer self.allocator.free(child_rel);

            if (watch.isIgnoredPath(child_rel)) {
                self.allocator.free(child_rel);
                continue;
            }

            if (entry.kind == .directory) {
                if (self.gitignore.isIgnored(child_rel, true)) {
                    self.allocator.free(child_rel);
                    continue;
                }
                defer self.allocator.free(child_rel);
                try self.collectDiskPathsInDir(child_rel, out);
                continue;
            }

            if (self.gitignore.isIgnored(child_rel, false)) {
                self.allocator.free(child_rel);
                continue;
            }

            if (entry.kind == .file or entry.kind == .sym_link) {
                if (!out.contains(child_rel)) {
                    try out.put(self.allocator, child_rel, {});
                } else {
                    self.allocator.free(child_rel);
                }
            } else {
                self.allocator.free(child_rel);
            }
        }
    }

    pub fn ingestPaths(
        self: *Workspace,
        rel_paths: []const []const u8,
        scan_dirs: []const []const u8,
        source: []const u8,
    ) !?id.BatchId {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir, self.commonDirOpt());
        self.refreshGitIndexIfNeeded();

        var candidates: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = candidates.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            candidates.deinit(self.allocator);
        }

        for (rel_paths) |p| {
            if (p.len == 0 or watch.isIgnoredPath(p)) continue;
            self.gitignore.ensureNestedAncestorsLoaded(self.allocator, self.io, self.work_dir, p);
            if (!candidates.contains(p)) {
                try candidates.put(self.allocator, try self.allocator.dupe(u8, p), {});
            }
        }

        if (scan_dirs.len > 0) {
            for (scan_dirs) |dir_rel| {
                if (dir_rel.len == 0 or watch.isIgnoredPath(dir_rel)) continue;
                self.collectDiskPathsInDir(dir_rel, &candidates) catch {};
            }

            if (self.shadow.count() > 0) {
                var sit = try self.shadow.iterateAll(self.allocator);
                defer sit.deinit();
                while (try sit.next()) |item| {
                    for (scan_dirs) |dir_rel| {
                        if (std.mem.eql(u8, item.rel_path, dir_rel) or
                            (item.rel_path.len > dir_rel.len and std.mem.startsWith(u8, item.rel_path, dir_rel) and item.rel_path[dir_rel.len] == '/'))
                        {
                            if (!candidates.contains(item.rel_path)) {
                                try candidates.put(self.allocator, try self.allocator.dupe(u8, item.rel_path), {});
                            }
                            break;
                        }
                    }
                }
            } else {
                var tracked: std.StringHashMapUnmanaged(id.InodeId) = .empty;
                defer {
                    var it = tracked.keyIterator();
                    while (it.next()) |k| self.allocator.free(k.*);
                    tracked.deinit(self.allocator);
                }
                try self.collectTrackedPaths(id.InodeId.ROOT, "", &tracked);
                var tit = tracked.keyIterator();
                while (tit.next()) |k| {
                    for (scan_dirs) |dir_rel| {
                        if (std.mem.eql(u8, k.*, dir_rel) or
                            (k.*.len > dir_rel.len and std.mem.startsWith(u8, k.*, dir_rel) and k.*[dir_rel.len] == '/'))
                        {
                            if (!candidates.contains(k.*)) {
                                try candidates.put(self.allocator, try self.allocator.dupe(u8, k.*), {});
                            }
                            break;
                        }
                    }
                }
            }
        }

        if (candidates.count() == 0) return null;

        var ops: std.ArrayList(op_mod.Op) = .empty;
        defer {
            for (ops.items) |*o| o.deinit(self.allocator);
            ops.deinit(self.allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        defer {
            for (blobs.items) |*b| b.deinit(self.allocator);
            blobs.deinit(self.allocator);
        }
        var new_pins: std.ArrayList(git_dirs_mod.GitOid) = .empty;
        defer new_pins.deinit(self.allocator);

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const base_start_ts = self.history.nextStartTs(&parents);

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var pit = pending_dirs.keyIterator();
            while (pit.next()) |k| self.allocator.free(k.*);
            pending_dirs.deinit(self.allocator);
        }

        const MissingFile = struct {
            rel: []const u8,
            iid: id.InodeId,
            hash: crypto.Hash,
            matched: bool = false,
        };
        const AddedFile = struct {
            rel: []const u8,
            bytes: []u8,
            mode: tree_mod.FileMode,
            stamp: StatStamp,
            hash: crypto.Hash,
        };
        var missing_files: std.ArrayList(MissingFile) = .empty;
        defer missing_files.deinit(self.allocator);
        var added_files: std.ArrayList(AddedFile) = .empty;
        defer {
            for (added_files.items) |af| self.allocator.free(af.bytes);
            added_files.deinit(self.allocator);
        }

        var cit = candidates.keyIterator();
        while (cit.next()) |rel_ptr| {
            const rel = rel_ptr.*;
            const existing_iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
            var disk_res = self.readDiskEntry(rel, existing_iid != null) catch DiskReadResult.missing;
            var owned_res = true;
            defer if (owned_res) disk_res.deinit(self.allocator);

            switch (disk_res) {
                .skipped_oversize, .ignored => {},
                .missing => {
                    self.removeStatCache(rel);
                    if (existing_iid) |iid| {
                        self.history.tree.beginPinScope();
                        defer self.history.tree.endPinScope();
                        if (self.history.tree.get(iid)) |inode| {
                            if (inode.fileConstPtr()) |f| {
                                if (try self.readInodeDiskBytes(f)) |old_bytes| {
                                    defer self.allocator.free(old_bytes);
                                    try missing_files.append(self.allocator, .{
                                        .rel = rel,
                                        .iid = iid,
                                        .hash = crypto.hashBytes(old_bytes),
                                    });
                                } else {
                                    try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                }
                            } else if (!inode.isDir()) {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            }
                        }
                    }
                },
                .git_clean => |gc| {
                    try self.queueGitPin(gc.oid, &new_pins);
                    if (existing_iid) |iid| {
                        try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = gc.mode } });
                        try ops.append(self.allocator, .{ .set_content = .{
                            .inode = iid,
                            .content = .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } },
                        } });
                        self.updateShadowForPath(rel, gc.stamp, iid, gc.oid, null);
                    } else {
                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                        try ops.append(self.allocator, .{ .create_file = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .mode = gc.mode,
                            .line_ending = .lf,
                            .content = .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } },
                        } });
                        self.updateShadowForPath(rel, gc.stamp, new_iid, gc.oid, null);
                    }
                },
                .file => |df| {
                    if (existing_iid) |iid| {
                        self.history.tree.beginPinScope();
                        const inode_opt = self.history.tree.get(iid);
                        const is_file = if (inode_opt) |in| in.fileConstPtr() != null else false;
                        const is_dir = if (inode_opt) |in| in.isDir() else false;
                        self.history.tree.endPinScope();
                        if (is_file) {
                            try self.emitUpdateFileOps(iid, df.bytes, df.mode, &ops, &blobs, &new_pins);
                            self.updateShadowForPath(rel, df.stamp, iid, null, null);
                        } else if (!is_dir) {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs, &new_pins);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = df.mode,
                                .line_ending = cm.line_ending,
                                .content = cm.content,
                            } });
                            self.updateShadowForPath(rel, df.stamp, new_iid, cm.git_oid, cm.blob_oid);
                        }
                    } else {
                        try added_files.append(self.allocator, .{
                            .rel = rel,
                            .bytes = df.bytes,
                            .mode = df.mode,
                            .stamp = df.stamp,
                            .hash = crypto.hashBytes(df.bytes),
                        });
                        owned_res = false;
                    }
                },
                .symlink => |ds| {
                    if (existing_iid) |iid| {
                        self.history.tree.beginPinScope();
                        const inode_opt = self.history.tree.get(iid);
                        const kind_tag: ?std.meta.Tag(tree_mod.NodeKind) = if (inode_opt) |in| std.meta.activeTag(in.kind) else null;
                        const same_target = if (inode_opt) |in| switch (in.kind) {
                            .symlink => |*sl| std.mem.eql(u8, if (sl.get()) |t| t.* else "", ds.target),
                            else => false,
                        } else false;
                        self.history.tree.endPinScope();
                        if (kind_tag) |kt| switch (kt) {
                            .symlink => {
                                if (!same_target) {
                                    try ops.append(self.allocator, .{ .set_symlink_target = .{
                                        .inode = iid,
                                        .target = try self.allocator.dupe(u8, ds.target),
                                    } });
                                }
                                self.updateShadowForPath(rel, ds.stamp, iid, null, null);
                            },
                            .file => {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                const base_name = std.fs.path.basename(rel);
                                const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                                try ops.append(self.allocator, .{ .create_symlink = .{
                                    .parent = parent_iid,
                                    .name = try self.allocator.dupe(u8, base_name),
                                    .target = try self.allocator.dupe(u8, ds.target),
                                } });
                                self.updateShadowForPath(rel, ds.stamp, new_iid, null, null);
                            },
                            .dir => {},
                        };
                    } else {
                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                        try ops.append(self.allocator, .{ .create_symlink = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .target = try self.allocator.dupe(u8, ds.target),
                        } });
                        self.updateShadowForPath(rel, ds.stamp, new_iid, null, null);
                    }
                },
            }
        }

        for (added_files.items) |af| {
            var matched_idx: ?usize = null;
            if (missing_files.items.len > 0) {
                var count: usize = 0;
                for (missing_files.items, 0..) |mf, idx| {
                    if (!mf.matched and std.mem.eql(u8, &mf.hash, &af.hash)) {
                        matched_idx = idx;
                        count += 1;
                    }
                }
                if (count != 1) matched_idx = null;
            }
            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, af.rel, &ops, &pending_dirs);
            const base_name = std.fs.path.basename(af.rel);
            if (matched_idx) |idx| {
                missing_files.items[idx].matched = true;
                const iid = missing_files.items[idx].iid;
                try ops.append(self.allocator, .{ .rename = .{
                    .inode = iid,
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base_name),
                } });
                try self.emitUpdateFileOps(iid, af.bytes, af.mode, &ops, &blobs, &new_pins);
                self.updateShadowForPath(af.rel, af.stamp, iid, null, null);
            } else {
                const cm = try self.makeFileContentAndMeta(af.bytes, &blobs, &new_pins);
                const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), self.disk_actor), 0);
                try ops.append(self.allocator, .{ .create_file = .{
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base_name),
                    .mode = af.mode,
                    .line_ending = cm.line_ending,
                    .content = cm.content,
                } });
                self.updateShadowForPath(af.rel, af.stamp, new_iid, cm.git_oid, cm.blob_oid);
            }
        }

        for (missing_files.items) |mf| {
            if (!mf.matched) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = mf.iid } });
            }
        }

        self.flushGitPins(new_pins.items);

        if (ops.items.len == 0) return null;

        const batch_parents = try parents.clone(self.allocator);
        const end = base_start_ts + @as(u64, @intCast(ops.items.len)) - 1;
        var batch = op_mod.Batch{
            .header = .{
                .actor = self.disk_actor,
                .start = base_start_ts,
                .end = end,
                .parents = batch_parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = try ops.toOwnedSlice(self.allocator),
            .blobs = try blobs.toOwnedSlice(self.allocator),
        };
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
        return batch.header.batchId();
    }

    fn readDiskEntry(self: *Workspace, rel: []const u8, already_tracked: bool) !DiskReadResult {
        const st = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch return .missing;
        const is_dir = st.kind == .directory;
        if (!already_tracked and self.gitignore.isPathOrAncestorIgnored(rel, is_dir)) return .ignored;
        switch (st.kind) {
            .sym_link => {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = self.work_dir.readLink(self.io, rel, &link_buf) catch return .missing;
                return .{ .symlink = .{
                    .target = try self.allocator.dupe(u8, link_buf[0..n]),
                    .stamp = .{
                        .size = st.size,
                        .mtime_ns = st.mtime.nanoseconds,
                        .mode = .regular,
                        .kind = .symlink,
                        .ino = st.inode,
                    },
                } };
            },
            .file => {
                if (st.size > self.max_file_size) return .skipped_oversize;
                const mode = fileModeFromStat(st);
                const stamp = StatStamp{
                    .size = st.size,
                    .mtime_ns = st.mtime.nanoseconds,
                    .mode = mode,
                    .kind = .file,
                    .ino = st.inode,
                };
                if (!self.has_custom_filters) {
                    if (self.git_index) |*gi| {
                        if (self.git_dirs) |*gd| {
                            if (self.git_odb) |odb| {
                                if (gi.find(rel)) |ie| {
                                    if (ie.isRegularFile() and gi.isStatClean(ie, st, gd.config) and odb.contains(ie.oid)) {
                                        return .{ .git_clean = .{
                                            .oid = ie.oid,
                                            .len = st.size,
                                            .mode = mode,
                                            .stamp = stamp,
                                        } };
                                    }
                                }
                            }
                        }
                    }
                }
                const f = self.work_dir.openFile(self.io, rel, .{}) catch return .missing;
                defer f.close(self.io);
                const buf = try self.allocator.alloc(u8, @intCast(st.size));
                errdefer self.allocator.free(buf);
                const n = f.readPositionalAll(self.io, buf, 0) catch {
                    self.allocator.free(buf);
                    return .missing;
                };
                if (n != buf.len) {
                    self.allocator.free(buf);
                    return .missing;
                }
                return .{ .file = .{
                    .bytes = buf,
                    .mode = mode,
                    .stamp = stamp,
                } };
            },
            else => return .missing,
        }
    }

    fn readDiskFile(self: *Workspace, rel: []const u8) !?[]u8 {
        const f = self.work_dir.openFile(self.io, rel, .{}) catch return null;
        defer f.close(self.io);
        const st = f.stat(self.io) catch return null;
        if (st.kind != .file) return null;
        if (st.size > self.max_file_size) return null;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        errdefer self.allocator.free(buf);
        const n = f.readPositionalAll(self.io, buf, 0) catch {
            self.allocator.free(buf);
            return null;
        };
        if (n != buf.len) {
            self.allocator.free(buf);
            return null;
        }
        return buf;
    }

    fn ensureParentDirs(
        self: *Workspace,
        actor: id.ActorId,
        base_start_ts: id.Lamport,
        rel: []const u8,
        ops: *std.ArrayList(op_mod.Op),
        pending_dirs: *std.StringHashMapUnmanaged(id.InodeId),
    ) !id.InodeId {
        const dir_part = std.fs.path.dirname(rel) orelse return id.InodeId.ROOT;
        if (dir_part.len == 0 or std.mem.eql(u8, dir_part, ".")) return id.InodeId.ROOT;
        if (pending_dirs.get(dir_part)) |iid| return iid;
        if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, dir_part)) |iid| {
            return iid;
        }
        var cur = id.InodeId.ROOT;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, dir_part, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (acc.items.len > 0) try acc.append(self.allocator, '/');
            try acc.appendSlice(self.allocator, seg);
            if (pending_dirs.get(acc.items)) |existing| {
                cur = existing;
            } else if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, acc.items)) |existing| {
                cur = existing;
            } else {
                const op_ts = base_start_ts + @as(u64, @intCast(ops.items.len));
                const next_iid = id.InodeId.init(id.OpId.init(op_ts, actor), 0);
                try ops.append(self.allocator, .{ .create_dir = .{
                    .parent = cur,
                    .name = try self.allocator.dupe(u8, seg),
                } });
                try pending_dirs.put(self.allocator, try self.allocator.dupe(u8, acc.items), next_iid);
                cur = next_iid;
            }
        }
        return cur;
    }

    fn hasTrackedUnderDir(
        self: *Workspace,
        dir_rel: []const u8,
        use_shadow_tracking: bool,
        existing_paths: *const std.StringHashMapUnmanaged(id.InodeId),
    ) bool {
        if (use_shadow_tracking) {
            if (self.shadow.count() == 0) return false;
            var sit = self.shadow.iterateAll(self.allocator) catch return false;
            defer sit.deinit();
            while (sit.next() catch null) |item| {
                if (item.rel_path.len > dir_rel.len and std.mem.startsWith(u8, item.rel_path, dir_rel) and item.rel_path[dir_rel.len] == '/') {
                    return true;
                }
            }
            return false;
        }
        var it = existing_paths.keyIterator();
        while (it.next()) |k| {
            if (k.*.len > dir_rel.len and std.mem.startsWith(u8, k.*, dir_rel) and k.*[dir_rel.len] == '/') {
                return true;
            }
        }
        return false;
    }

    fn scanDir(
        self: *Workspace,
        rel_prefix: []const u8,
        use_shadow_tracking: bool,
        existing_paths: *const std.StringHashMapUnmanaged(id.InodeId),
        out: *std.StringHashMapUnmanaged(DiskEntry),
        skipped_oversize: *std.StringHashMapUnmanaged(void),
    ) !void {
        var dir = if (rel_prefix.len == 0)
            try self.work_dir.openDir(self.io, ".", .{ .iterate = true })
        else
            try self.work_dir.openDir(self.io, rel_prefix, .{ .iterate = true });
        defer dir.close(self.io);

        self.gitignore.loadNestedForDir(self.allocator, self.io, dir, rel_prefix);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (watch.isIgnoredName(entry.name)) continue;
            if (std.mem.endsWith(u8, entry.name, ".0ndb-tmp") or std.mem.endsWith(u8, entry.name, ".0ndb-sym-tmp")) continue;
            const child_rel = if (rel_prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_prefix, entry.name });
            errdefer self.allocator.free(child_rel);

            const is_dir = entry.kind == .directory;
            const shadow_opt: ?shadow_mod.ShadowEntry = if (!is_dir) (self.shadow.get(child_rel) catch null) else null;
            const is_tracked: bool = if (is_dir)
                false
            else if (use_shadow_tracking)
                shadow_opt != null
            else
                existing_paths.contains(child_rel);

            if (self.gitignore.isIgnored(child_rel, is_dir)) {
                if (is_dir) {
                    if (!self.hasTrackedUnderDir(child_rel, use_shadow_tracking, existing_paths)) {
                        self.allocator.free(child_rel);
                        continue;
                    }
                } else if (!is_tracked) {
                    self.allocator.free(child_rel);
                    continue;
                }
            }

            switch (entry.kind) {
                .directory => {
                    defer self.allocator.free(child_rel);
                    try self.scanDir(child_rel, use_shadow_tracking, existing_paths, out, skipped_oversize);
                },
                .sym_link => {
                    const st = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                        self.allocator.free(child_rel);
                        continue;
                    };
                    const stamp = StatStamp{
                        .size = st.size,
                        .mtime_ns = st.mtime.nanoseconds,
                        .mode = .regular,
                        .kind = .symlink,
                        .ino = st.inode,
                    };
                    if (is_tracked) {
                        if (shadow_opt) |cached| {
                            if (stamp.matchesShadow(cached)) {
                                try out.put(self.allocator, child_rel, .{ .unchanged = stamp });
                                continue;
                            }
                        }
                    }
                    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const n = dir.readLink(self.io, entry.name, &link_buf) catch {
                        self.allocator.free(child_rel);
                        continue;
                    };
                    const target = try self.allocator.dupe(u8, link_buf[0..n]);
                    errdefer self.allocator.free(target);
                    try out.put(self.allocator, child_rel, .{ .symlink = .{ .target = target, .stamp = stamp } });
                },
                .file => {
                    const st = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                        self.allocator.free(child_rel);
                        continue;
                    };
                    if (st.size > self.max_file_size) {
                        const gop = try skipped_oversize.getOrPut(self.allocator, child_rel);
                        if (gop.found_existing) self.allocator.free(child_rel);
                        continue;
                    }
                    const mode = fileModeFromStat(st);
                    const stamp = StatStamp{
                        .size = st.size,
                        .mtime_ns = st.mtime.nanoseconds,
                        .mode = mode,
                        .kind = .file,
                        .ino = st.inode,
                    };
                    if (is_tracked) {
                        if (shadow_opt) |cached| {
                            if (stamp.matchesShadow(cached)) {
                                try out.put(self.allocator, child_rel, .{ .unchanged = stamp });
                                continue;
                            }
                        }
                    }
                    if (!self.has_custom_filters) {
                        if (self.git_index) |*gi| {
                            if (self.git_dirs) |*gd| {
                                if (self.git_odb) |odb| {
                                    if (gi.find(child_rel)) |ie| {
                                        if (ie.isRegularFile() and gi.isStatClean(ie, st, gd.config) and odb.contains(ie.oid)) {
                                            try out.put(self.allocator, child_rel, .{ .git_clean = .{
                                                .oid = ie.oid,
                                                .len = st.size,
                                                .mode = mode,
                                                .stamp = stamp,
                                            } });
                                            continue;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    const f = dir.openFile(self.io, entry.name, .{}) catch {
                        self.allocator.free(child_rel);
                        continue;
                    };
                    defer f.close(self.io);
                    const buf = try self.allocator.alloc(u8, @intCast(st.size));
                    errdefer self.allocator.free(buf);
                    const n = try f.readPositionalAll(self.io, buf, 0);
                    if (n != buf.len) {
                        self.allocator.free(buf);
                        self.allocator.free(child_rel);
                        continue;
                    }
                    try out.put(self.allocator, child_rel, .{ .file = .{
                        .bytes = buf,
                        .mode = mode,
                        .stamp = stamp,
                    } });
                },
                else => {
                    self.allocator.free(child_rel);
                },
            }
        }
    }

    fn collectTrackedPaths(
        self: *const Workspace,
        dir_iid: id.InodeId,
        prefix: []const u8,
        out: *std.StringHashMapUnmanaged(id.InodeId),
    ) !void {
        var entries = try self.history.tree.listDir(self.allocator, text_mod.View.EVERYTHING, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(entry.inode_id);
            const is_dir = if (inode_opt) |in| in.isDir() else false;
            const exists = inode_opt != null;
            self.history.tree.endPinScope();
            if (!exists) {
                self.allocator.free(rel);
                continue;
            }
            if (is_dir) {
                defer self.allocator.free(rel);
                try self.collectTrackedPaths(entry.inode_id, rel, out);
            } else {
                try out.put(self.allocator, rel, entry.inode_id);
            }
        }
    }

    fn readInodeDiskBytes(self: *Workspace, f: *const tree_mod.FileNode) !?[]u8 {
        const ck = f.content.get() orelse return null;
        return switch (ck.*) {
            .text => blk: {
                const raw = (try f.text.read(self.allocator, self.history.resolver())) orelse break :blk null;
                const ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                if (ending == .crlf) {
                    defer self.allocator.free(raw);
                    break :blk try smudgeLineEnding(self.allocator, raw, .crlf);
                }
                break :blk raw;
            },
            .binary => |ref| blk: {
                if (self.history.resolveBlob(ref.oid)) |b| {
                    break :blk try self.allocator.dupe(u8, b);
                }
                break :blk try self.blob_store.get(self.allocator, ref.oid);
            },
            .git_binary => |ref| try self.history.readGitBlobAlloc(self.allocator, ref.oid),
            .git_lazy => |ref| blk: {
                const raw = (try self.history.readGitBlobAlloc(self.allocator, ref.oid)) orelse break :blk null;
                const ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                if (ending == .crlf) {
                    defer self.allocator.free(raw);
                    break :blk try smudgeLineEnding(self.allocator, raw, .crlf);
                }
                break :blk raw;
            },
        };
    }

    fn writeRegularFileAtomic(self: *Workspace, rel: []const u8, bytes: []const u8, mode: tree_mod.FileMode) !void {
        if (std.fs.path.dirname(rel)) |parent_dir| {
            try self.work_dir.createDirPath(self.io, parent_dir);
            if (self.watcher) |*w| {
                w.watchSubdirRecursive(self.io, 1, self.root_path, parent_dir) catch {};
            }
        }
        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.0ndb-tmp", .{rel});
        defer self.allocator.free(tmp_name);
        const f = try self.work_dir.createFile(self.io, tmp_name, .{ .truncate = true });
        var f_closed = false;
        errdefer {
            if (!f_closed) f.close(self.io);
            self.work_dir.deleteFile(self.io, tmp_name) catch {};
        }
        try f.writePositionalAll(self.io, bytes, 0);
        const perm_mode: std.posix.mode_t = if (mode == .executable) 0o755 else 0o644;
        f.setPermissions(self.io, Io.File.Permissions.fromMode(perm_mode)) catch {};
        try f.sync(self.io);
        f.close(self.io);
        f_closed = true;
        try self.work_dir.rename(tmp_name, self.work_dir, rel, self.io);
        self.recordStatFromDisk(rel);
    }

    fn writeSymlinkAtomic(self: *Workspace, rel: []const u8, target: []const u8) !void {
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.work_dir.readLink(self.io, rel, &link_buf)) |n| {
            if (std.mem.eql(u8, link_buf[0..n], target)) {
                self.recordStatFromDisk(rel);
                return;
            }
        } else |_| {}
        if (std.fs.path.dirname(rel)) |parent_dir| {
            try self.work_dir.createDirPath(self.io, parent_dir);
            if (self.watcher) |*w| {
                w.watchSubdirRecursive(self.io, 1, self.root_path, parent_dir) catch {};
            }
        }
        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.0ndb-sym-tmp", .{rel});
        defer self.allocator.free(tmp_name);
        self.work_dir.deleteFile(self.io, tmp_name) catch {};
        try self.work_dir.symLink(self.io, target, tmp_name, .{});
        errdefer self.work_dir.deleteFile(self.io, tmp_name) catch {};
        try self.work_dir.rename(tmp_name, self.work_dir, rel, self.io);
        self.recordStatFromDisk(rel);
    }

    pub fn materializeFile(self: *Workspace, rel: []const u8) !void {
        const iid_opt = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
        if (iid_opt) |iid| {
            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(iid);
            if (inode_opt == null) {
                self.history.tree.endPinScope();
                if ((self.shadow.get(rel) catch null) != null) {
                    self.work_dir.deleteFile(self.io, rel) catch {};
                    self.removeStatCache(rel);
                }
                return;
            }
            const inode = inode_opt.?;
            switch (inode.kind) {
                .dir => {
                    self.history.tree.endPinScope();
                    return;
                },
                .symlink => |*sl| {
                    const target_copy = if (sl.get()) |t| try self.allocator.dupe(u8, t.*) else null;
                    self.history.tree.endPinScope();
                    if (target_copy) |t| {
                        defer self.allocator.free(t);
                        try self.writeSymlinkAtomic(rel, t);
                    }
                    return;
                },
                .file => |*f| {
                    const bytes_opt = try self.readInodeDiskBytes(f);
                    const mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                    self.history.tree.endPinScope();
                    const bytes = bytes_opt orelse return;
                    defer self.allocator.free(bytes);
                    const st_opt = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch null;
                    if (st_opt) |st| {
                        if (st.kind == .file and fileModeFromStat(st) == mode) {
                            if (self.readDiskFile(rel) catch null) |cur| {
                                defer self.allocator.free(cur);
                                if (std.mem.eql(u8, cur, bytes)) {
                                    self.recordStatFromDisk(rel);
                                    return;
                                }
                            }
                        }
                    }
                    try self.writeRegularFileAtomic(rel, bytes, mode);
                    return;
                },
            }
        } else {
            if ((self.shadow.get(rel) catch null) != null) {
                self.work_dir.deleteFile(self.io, rel) catch {};
                self.removeStatCache(rel);
            }
        }
    }

    pub fn materializePaths(self: *Workspace, rel_paths: []const []const u8) !void {
        for (rel_paths) |rel| {
            try self.materializeFile(rel);
        }
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
    }

    pub fn materializeToDisk(self: *Workspace) !void {
        return self.materializeToDiskWithOptions(.{ .force = false });
    }

    pub fn materializeToDiskWithOptions(self: *Workspace, opts: MaterializeOptions) !void {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir, self.commonDirOpt());

        var tracked: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var it = tracked.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            tracked.deinit(self.allocator);
        }
        try self.collectTrackedPaths(id.InodeId.ROOT, "", &tracked);

        var disk_paths: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = disk_paths.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            disk_paths.deinit(self.allocator);
        }
        try self.collectDiskPathsInDir("", &disk_paths);

        var dit = disk_paths.keyIterator();
        while (dit.next()) |rel_ptr| {
            if (!tracked.contains(rel_ptr.*)) {
                const known_in_shadow = (self.shadow.get(rel_ptr.*) catch null) != null;
                if (opts.force or known_in_shadow) {
                    self.work_dir.deleteFile(self.io, rel_ptr.*) catch {};
                    self.removeStatCache(rel_ptr.*);
                }
            }
        }

        var touched: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer touched.deinit(self.allocator);
        var has_touched_set = false;
        if (self.synced_version.eql(&self.history.dag.heads)) {
            has_touched_set = true;
        } else {
            var diff_a = self.history.dag.difference(self.allocator, &self.history.dag.heads, &self.synced_version) catch null;
            defer if (diff_a) |*l| l.deinit(self.allocator);
            var diff_b = self.history.dag.difference(self.allocator, &self.synced_version, &self.history.dag.heads) catch null;
            defer if (diff_b) |*l| l.deinit(self.allocator);
            if (diff_a != null and diff_b != null) {
                var t1 = self.collectTouchedInodes(self.allocator, diff_a.?.items) catch null;
                defer if (t1) |*m| m.deinit(self.allocator);
                var t2 = self.collectTouchedInodes(self.allocator, diff_b.?.items) catch null;
                defer if (t2) |*m| m.deinit(self.allocator);
                if (t1 != null and t2 != null) {
                    var k1 = t1.?.keyIterator();
                    while (k1.next()) |k| try touched.put(self.allocator, k.*, {});
                    var k2 = t2.?.keyIterator();
                    while (k2.next()) |k| try touched.put(self.allocator, k.*, {});
                    has_touched_set = true;
                }
            }
        }

        var tit = tracked.iterator();
        while (tit.next()) |kv| {
            const rel = kv.key_ptr.*;
            const iid = kv.value_ptr.*;

            const st_opt = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch null;
            if (has_touched_set and !touched.contains(iid)) {
                if (st_opt) |st| {
                    if (self.shadow.get(rel) catch null) |cached| {
                        const sk_opt: ?StatKind = switch (st.kind) {
                            .file => .file,
                            .sym_link => .symlink,
                            else => null,
                        };
                        if (sk_opt) |sk| {
                            const cur_stamp = StatStamp{
                                .size = st.size,
                                .mtime_ns = st.mtime.nanoseconds,
                                .mode = if (sk == .file) fileModeFromStat(st) else .regular,
                                .kind = sk,
                                .ino = st.inode,
                            };
                            if (cur_stamp.matchesShadow(cached)) continue;
                        }
                    }
                }
            }

            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(iid);
            if (inode_opt == null or inode_opt.?.isDir()) {
                self.history.tree.endPinScope();
                continue;
            }
            const inode = inode_opt.?;
            switch (inode.kind) {
                .dir => {
                    self.history.tree.endPinScope();
                },
                .symlink => |*sl| {
                    const target_copy = if (sl.get()) |t| try self.allocator.dupe(u8, t.*) else null;
                    self.history.tree.endPinScope();
                    if (target_copy) |t| {
                        defer self.allocator.free(t);
                        try self.writeSymlinkAtomic(rel, t);
                    }
                },
                .file => |*f| {
                    const bytes_opt = try self.readInodeDiskBytes(f);
                    const mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                    self.history.tree.endPinScope();
                    const bytes = bytes_opt orelse continue;
                    defer self.allocator.free(bytes);
                    if (st_opt) |st| {
                        if (st.kind == .file and st.size == bytes.len and fileModeFromStat(st) == mode) {
                            if (self.readDiskFile(rel) catch null) |cur| {
                                defer self.allocator.free(cur);
                                if (std.mem.eql(u8, cur, bytes)) {
                                    self.updateShadowForPath(rel, .{
                                        .size = st.size,
                                        .mtime_ns = st.mtime.nanoseconds,
                                        .mode = mode,
                                        .kind = .file,
                                        .ino = st.inode,
                                    }, iid, null, null);
                                    continue;
                                }
                            }
                        }
                    }
                    try self.writeRegularFileAtomic(rel, bytes, mode);
                },
            }
        }

        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
    }

    pub fn readBatchPayloadAlloc(self: *Workspace, allocator: Allocator, bid: id.BatchId) !?[]u8 {
        if (self.batch_log_idx.get(bid)) |log_idx| {
            const view = try self.batch_log.readAt(log_idx);
            if (view.header.kind != FRAME_BATCH) return null;
            return try allocator.dupe(u8, view.payload);
        }
        if (self.history.dag.getBatchLocation(bid)) |loc| {
            if (loc.seg_id > 0 and loc.len > 0) {
                return try self.segments.readFrameAt(loc.seg_id, loc.offset, loc.len, allocator);
            }
        }
        return null;
    }

    pub fn collectTouchedInodes(
        self: *Workspace,
        allocator: Allocator,
        batch_ids: []const id.BatchId,
    ) !std.AutoHashMapUnmanaged(id.InodeId, void) {
        var out: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        errdefer out.deinit(allocator);
        for (batch_ids) |bid| {
            const payload = (try self.readBatchPayloadAlloc(allocator, bid)) orelse continue;
            defer allocator.free(payload);
            var r = codec.Reader.init(payload);
            var batch = try op_mod.Batch.decode(allocator, &r);
            defer batch.deinit(allocator);
            for (batch.ops, 0..) |*operation, idx| {
                const maybe_iid: ?id.InodeId = switch (operation.*) {
                    .create_file, .create_symlink => id.InodeId.init(batch.header.opId(idx), 0),
                    .edit_text => |v| v.inode,
                    .set_content => |v| v.inode,
                    .set_mode => |v| v.inode,
                    .set_line_ending => |v| v.inode,
                    .set_symlink_target => |v| v.inode,
                    .remove => |v| v.inode,
                    .restore => |v| v.inode,
                    .rename => |v| v.inode,
                    else => null,
                };
                if (maybe_iid) |iid| {
                    try out.put(allocator, iid, {});
                }
            }
        }
        return out;
    }

    pub fn rollbackToVersion(self: *Workspace, target_version: *const Version) !bool {
        return self.rollbackToVersionWithSource(target_version, "rollback");
    }

    fn collectOpFilePaths(
        self: *const Workspace,
        batch: *const op_mod.Batch,
        path_set: *std.StringHashMapUnmanaged(void),
        dir_renamed: *bool,
    ) !void {
        for (batch.ops, 0..) |*operation, idx| {
            const maybe_iid: ?id.InodeId = switch (operation.*) {
                .create_file, .create_symlink => id.InodeId.init(batch.header.opId(idx), 0),
                .edit_text => |v| v.inode,
                .set_content => |v| v.inode,
                .set_mode => |v| v.inode,
                .set_line_ending => |v| v.inode,
                .set_symlink_target => |v| v.inode,
                .remove => |v| v.inode,
                .restore => |v| v.inode,
                .rename => |v| v.inode,
                else => null,
            };
            const iid = maybe_iid orelse continue;
            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(iid);
            const is_dir = if (inode_opt) |in| in.isDir() else false;
            const exists = inode_opt != null;
            self.history.tree.endPinScope();
            if (!exists) continue;
            if (is_dir) {
                if (operation.* == .rename or operation.* == .remove or operation.* == .restore) dir_renamed.* = true;
                continue;
            }
            if (try self.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) |p| {
                const gop = try path_set.getOrPut(self.allocator, p);
                if (gop.found_existing) self.allocator.free(p);
            }
        }
    }

    pub fn rollbackToVersionWithSource(self: *Workspace, target_version: *const Version, source: []const u8) !bool {
        if (self.watcher != null) {
            _ = try self.drainWatched("watch");
        } else {
            _ = try self.ingestDiskWithSource("disk");
        }
        var batch = try self.history.buildRollbackBatch(
            self.allocator,
            self.disk_actor,
            target_version,
            id.nowMs(self.io),
        ) orelse return false;
        defer batch.deinit(self.allocator);

        var dir_renamed = false;
        var path_set: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = path_set.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            path_set.deinit(self.allocator);
        }
        try self.collectOpFilePaths(&batch, &path_set, &dir_renamed);

        _ = try self.commitBatchWithSource(&batch, source);

        if (dir_renamed) {
            try self.materializeToDisk();
            return true;
        }
        try self.collectOpFilePaths(&batch, &path_set, &dir_renamed);
        if (dir_renamed) {
            try self.materializeToDisk();
            return true;
        }

        var changed: std.ArrayList([]const u8) = .empty;
        defer changed.deinit(self.allocator);
        try changed.ensureTotalCapacityPrecise(self.allocator, path_set.count());
        var pit = path_set.keyIterator();
        while (pit.next()) |k| changed.appendAssumeCapacity(k.*);
        try self.materializePaths(changed.items);
        return true;
    }

    pub fn rebaseBuffer(
        self: *const Workspace,
        allocator: Allocator,
        rel_path: []const u8,
        base_version: *const Version,
        draft_bytes: []const u8,
        cursor_start: u64,
        cursor_end: u64,
    ) Allocator.Error!?history_mod.BufferRebase {
        if (!self.history.isKnownVersion(base_version)) return null;
        return try self.history.rebaseBuffer(
            allocator,
            rel_path,
            base_version,
            draft_bytes,
            cursor_start,
            cursor_end,
        );
    }

    pub fn applyFileSplices(
        self: *Workspace,
        actor: id.ActorId,
        rel_path: []const u8,
        base_version: *const Version,
        splices: []const diff.Splice,
        inserted: []const u8,
        source: []const u8,
    ) !EditCommitResult {
        if (self.watcher != null) {
            _ = try self.drainWatched("watch");
        }
        const effective_base = if (self.history.isKnownVersion(base_version)) base_version else &self.history.dag.heads;
        const concurrent = !effective_base.eql(&self.history.dag.heads);

        if (splices.len == 0) {
            const cur_content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, "");
            errdefer self.allocator.free(cur_content);
            var ver = try self.history.headsClone();
            errdefer ver.deinit(self.allocator);
            const bid = if (ver.slice().len > 0) ver.slice()[0] else id.OpId.ZERO;
            return .{
                .batch_id = bid,
                .version = ver,
                .content = cur_content,
                .concurrent_merged = concurrent,
            };
        }

        const BaseCtx = struct {
            dag_ptr: *const dag_mod.Dag,
            ver: *const Version,
            alloc: Allocator,
            fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                return ctx.dag_ptr.versionContainsOp(ctx.alloc, ctx.ver, op_id) catch false;
            }
        };
        const min_unobs = try self.history.dag.minUnobservedFor(self.allocator, effective_base);
        const bctx = BaseCtx{ .dag_ptr = &self.history.dag, .ver = effective_base, .alloc = self.allocator };
        const base_view = text_mod.View{
            .ptr = &bctx,
            .observesFn = BaseCtx.observes,
            .min_unobserved = min_unobs,
        };

        const iid = try self.history.tree.resolvePath(self.allocator, base_view, rel_path) orelse return error.UnknownInode;

        var batch_owned = false;
        const ops = try self.allocator.alloc(op_mod.Op, 1);
        errdefer if (!batch_owned) self.allocator.free(ops);
        const ins_copy = try self.allocator.dupe(u8, inserted);
        errdefer if (!batch_owned) self.allocator.free(ins_copy);
        const sp_copy = try self.allocator.dupe(diff.Splice, splices);
        errdefer if (!batch_owned) self.allocator.free(sp_copy);
        ops[0] = .{ .edit_text = .{
            .inode = iid,
            .text = ins_copy,
            .splices = sp_copy,
        } };
        var parents = try effective_base.clone(self.allocator);
        errdefer if (!batch_owned) parents.deinit(self.allocator);
        const blobs_empty = try self.allocator.alloc(op_mod.BlobAttachment, 0);
        const start = self.history.nextStartTs(&parents);
        var batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = start,
                .end = start,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = ops,
            .blobs = blobs_empty,
        };
        batch_owned = true;
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        const touched = [_][]const u8{rel_path};
        try self.materializePaths(&touched);

        const content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(content);
        var ver = try self.history.headsClone();
        errdefer ver.deinit(self.allocator);
        return .{
            .batch_id = batch.header.batchId(),
            .version = ver,
            .content = content,
            .concurrent_merged = concurrent,
        };
    }

    pub fn writeFileAtBase(
        self: *Workspace,
        actor: id.ActorId,
        rel_path: []const u8,
        base_version_opt: ?*const Version,
        bytes: []const u8,
        source: []const u8,
    ) !EditCommitResult {
        if (self.watcher != null) {
            _ = try self.drainWatched("watch");
        } else if (base_version_opt == null) {
            const single = [_][]const u8{rel_path};
            _ = try self.ingestPaths(&single, &.{}, "disk");
        }

        const use_base: ?*const Version = if (base_version_opt) |bv|
            if (self.history.isKnownVersion(bv)) bv else null
        else
            null;

        var ops: std.ArrayList(op_mod.Op) = .empty;
        defer {
            for (ops.items) |*o| o.deinit(self.allocator);
            ops.deinit(self.allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        defer {
            for (blobs.items) |*b| b.deinit(self.allocator);
            blobs.deinit(self.allocator);
        }

        var parents = Version.ROOT;
        defer parents.deinit(self.allocator);
        var concurrent = false;

        var resolved_at_base = false;
        if (use_base) |bv| {
            const BaseCtx = struct {
                dag_ptr: *const dag_mod.Dag,
                ver: *const Version,
                alloc: Allocator,
                fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                    const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                    return ctx.dag_ptr.versionContainsOp(ctx.alloc, ctx.ver, op_id) catch false;
                }
            };
            const min_unobs = try self.history.dag.minUnobservedFor(self.allocator, bv);
            const bctx = BaseCtx{ .dag_ptr = &self.history.dag, .ver = bv, .alloc = self.allocator };
            const base_view = text_mod.View{
                .ptr = &bctx,
                .observesFn = BaseCtx.observes,
                .min_unobserved = min_unobs,
            };
            if (try self.history.tree.resolvePath(self.allocator, base_view, rel_path)) |iid| {
                resolved_at_base = true;
                concurrent = !bv.eql(&self.history.dag.heads);
                parents = try bv.clone(self.allocator);
                const old = try self.history.readFileAt(self.allocator, rel_path, bv);
                defer if (old) |o| self.allocator.free(o);
                const old_bytes = old orelse "";
                if (!std.mem.eql(u8, old_bytes, bytes)) {
                    var d = try diff.diffBytes(self.allocator, old_bytes, bytes);
                    errdefer d.deinit(self.allocator);
                    try ops.append(self.allocator, .{ .edit_text = .{
                        .inode = iid,
                        .text = try d.inserted.toOwnedSlice(self.allocator),
                        .splices = try d.splices.toOwnedSlice(self.allocator),
                    } });
                }
            }
        }

        var base_start_ts: id.Lamport = 0;
        if (!resolved_at_base) {
            parents = try self.history.headsClone();
            base_start_ts = self.history.nextStartTs(&parents);
            if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel_path)) |iid| {
                self.history.tree.beginPinScope();
                const keep_mode: tree_mod.FileMode = if (self.history.tree.get(iid)) |in|
                    if (in.fileConstPtr()) |fp|
                        if (fp.mode.get()) |m| m.* else .regular
                    else
                        .regular
                else
                    .regular;
                self.history.tree.endPinScope();
                try self.emitUpdateFileOps(iid, bytes, keep_mode, &ops, &blobs, null);
            } else {
                var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
                defer {
                    var pit = pending_dirs.keyIterator();
                    while (pit.next()) |k| self.allocator.free(k.*);
                    pending_dirs.deinit(self.allocator);
                }
                const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel_path, &ops, &pending_dirs);
                const base = std.fs.path.basename(rel_path);
                const cm = try self.makeFileContentAndMeta(bytes, &blobs, null);
                try ops.append(self.allocator, .{ .create_file = .{
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base),
                    .mode = .regular,
                    .line_ending = cm.line_ending,
                    .content = cm.content,
                } });
            }
        } else {
            base_start_ts = self.history.nextStartTs(&parents);
        }

        if (ops.items.len == 0) {
            const cur_content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(cur_content);
            var ver = try self.history.headsClone();
            errdefer ver.deinit(self.allocator);
            const bid = if (ver.slice().len > 0) ver.slice()[0] else id.OpId.ZERO;
            return .{
                .batch_id = bid,
                .version = ver,
                .content = cur_content,
                .concurrent_merged = concurrent,
            };
        }

        const batch_parents = try parents.clone(self.allocator);
        const end = base_start_ts + @as(u64, @intCast(ops.items.len)) - 1;
        var batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = base_start_ts,
                .end = end,
                .parents = batch_parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = try ops.toOwnedSlice(self.allocator),
            .blobs = try blobs.toOwnedSlice(self.allocator),
        };
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        const touched = [_][]const u8{rel_path};
        try self.materializePaths(&touched);

        const content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(content);
        var ver = try self.history.headsClone();
        errdefer ver.deinit(self.allocator);
        return .{
            .batch_id = batch.header.batchId(),
            .version = ver,
            .content = content,
            .concurrent_merged = concurrent,
        };
    }

    pub fn writeFileDirect(self: *Workspace, actor: id.ActorId, rel_path: []const u8, bytes: []const u8) !id.BatchId {
        var res = try self.writeFileAtBase(actor, rel_path, null, bytes, "write");
        defer res.deinit(self.allocator);
        return res.batch_id;
    }

    pub fn deleteFileDirect(self: *Workspace, actor: id.ActorId, rel_path: []const u8) !?id.BatchId {
        const iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel_path) orelse {
            self.work_dir.deleteFile(self.io, rel_path) catch {};
            self.removeStatCache(rel_path);
            return null;
        };
        var batch_owned = false;
        var parents = try self.history.headsClone();
        errdefer if (!batch_owned) parents.deinit(self.allocator);
        const ts = self.history.nextStartTs(&parents);
        const ops = try self.allocator.alloc(op_mod.Op, 1);
        errdefer if (!batch_owned) self.allocator.free(ops);
        ops[0] = .{ .remove = .{ .inode = iid } };
        const blobs_empty = try self.allocator.alloc(op_mod.BlobAttachment, 0);
        var batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = ts,
                .end = ts,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = ops,
            .blobs = blobs_empty,
        };
        batch_owned = true;
        defer batch.deinit(self.allocator);
        _ = try self.commitBatchWithSource(&batch, "delete");
        const touched = [_][]const u8{rel_path};
        try self.materializePaths(&touched);
        return batch.header.batchId();
    }

    pub fn exportAncestors(self: *Workspace, allocator: Allocator, target: *const Version) ![]op_mod.Batch {
        var anc_list = try self.history.dag.difference(allocator, target, &Version.ROOT);
        defer anc_list.deinit(allocator);
        var wanted: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        defer wanted.deinit(allocator);
        for (anc_list.items) |bid| {
            try wanted.put(allocator, bid, {});
        }
        return self.exportLogBatchesFiltered(allocator, &wanted, true);
    }

    pub fn exportMissing(self: *Workspace, allocator: Allocator, peer_dag: *const dag_mod.Dag) ![]op_mod.Batch {
        var all_bids = try self.history.dag.collectAllBatchIds(allocator);
        defer all_bids.deinit(allocator);
        self.history.dag.topoSortSlice(all_bids.items);

        var out: std.ArrayList(op_mod.Batch) = .empty;
        errdefer {
            for (out.items) |*b| b.deinit(allocator);
            out.deinit(allocator);
        }
        for (all_bids.items) |bid| {
            if (peer_dag.containsBatch(bid)) continue;
            const payload = (try self.readBatchPayloadAlloc(allocator, bid)) orelse continue;
            defer allocator.free(payload);
            var r = codec.Reader.init(payload);
            const batch = try op_mod.Batch.decode(allocator, &r);
            try out.append(allocator, batch);
        }
        return try out.toOwnedSlice(allocator);
    }

    fn exportLogBatchesFiltered(
        self: *Workspace,
        allocator: Allocator,
        set: *const std.AutoHashMapUnmanaged(id.BatchId, void),
        include_if_in_set: bool,
    ) ![]op_mod.Batch {
        var all_bids = try self.history.dag.collectAllBatchIds(allocator);
        defer all_bids.deinit(allocator);
        self.history.dag.topoSortSlice(all_bids.items);

        var out: std.ArrayList(op_mod.Batch) = .empty;
        errdefer {
            for (out.items) |*b| b.deinit(allocator);
            out.deinit(allocator);
        }
        for (all_bids.items) |bid| {
            const in_set = set.contains(bid);
            if (in_set != include_if_in_set) continue;
            const payload = (try self.readBatchPayloadAlloc(allocator, bid)) orelse continue;
            defer allocator.free(payload);
            var r = codec.Reader.init(payload);
            const batch = try op_mod.Batch.decode(allocator, &r);
            try out.append(allocator, batch);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn collectPathsInView(
        self: *const Workspace,
        allocator: Allocator,
        view: text_mod.View,
        out: *std.StringHashMapUnmanaged(void),
    ) !void {
        try self.collectPathsInViewRec(allocator, id.InodeId.ROOT, "", view, out);
    }

    fn collectPathsInViewRec(
        self: *const Workspace,
        allocator: Allocator,
        dir_iid: id.InodeId,
        prefix: []const u8,
        view: text_mod.View,
        out: *std.StringHashMapUnmanaged(void),
    ) !void {
        var entries = try self.history.tree.listDir(allocator, view, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(entry.inode_id);
            const is_dir = if (inode_opt) |in| in.isDir() else false;
            const exists = inode_opt != null;
            self.history.tree.endPinScope();
            if (!exists) {
                allocator.free(rel);
                continue;
            }
            if (is_dir) {
                defer allocator.free(rel);
                try self.collectPathsInViewRec(allocator, entry.inode_id, rel, view, out);
            } else {
                const gop = try out.getOrPut(allocator, rel);
                if (gop.found_existing) allocator.free(rel);
            }
        }
    }
};
