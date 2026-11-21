const std = @import("std");
const builtin = @import("builtin");
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
const codec = @import("../core/codec.zig");
const crypto = @import("../store/crypto.zig");
const mmap = @import("../store/mmap.zig");
const log_mod = @import("../store/log.zig");
const blobs_mod = @import("../store/blobs.zig");
const manifest_mod = @import("../store/manifest.zig");
const segments_mod = @import("../store/segments.zig");
const snapshot_mod = @import("../store/snapshot.zig");
const pool_mod = @import("../fs/pool.zig");

pub const FRAME_BATCH: u8 = 1;
pub const AUTO_MINOR_WAL_BATCHES: usize = 256;
pub const AUTO_MINOR_WAL_BYTES: u64 = 8 * 1024 * 1024;
pub const AUTO_MINOR_DIRTY_INODES: usize = 4096;
pub const AUTO_MAJOR_DELTA_BYTES: u64 = 16 * 1024 * 1024;

const CONFLICTS_MAGIC: u32 = 0x53434631;
const ORIGIN_MAGIC: u32 = 0x534F5231;

pub const SpaceKind = enum(u8) {
    virtual = 0,
    dir = 1,
    git_worktree = 2,
};

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

pub const SpaceOrigin = struct {
    origin_space_id: u128,
    fork_base_version: Version,
    git_remote_url: ?[]u8 = null,
    git_base_rev: ?[]u8 = null,

    pub fn clone(self: *const SpaceOrigin, allocator: Allocator) Allocator.Error!SpaceOrigin {
        var ver = try self.fork_base_version.clone(allocator);
        errdefer ver.deinit(allocator);
        const url = if (self.git_remote_url) |u| try allocator.dupe(u8, u) else null;
        errdefer if (url) |u| allocator.free(u);
        const rev = if (self.git_base_rev) |r| try allocator.dupe(u8, r) else null;
        return .{
            .origin_space_id = self.origin_space_id,
            .fork_base_version = ver,
            .git_remote_url = url,
            .git_base_rev = rev,
        };
    }

    pub fn deinit(self: *SpaceOrigin, allocator: Allocator) void {
        self.fork_base_version.deinit(allocator);
        if (self.git_remote_url) |u| allocator.free(u);
        if (self.git_base_rev) |r| allocator.free(r);
        self.git_remote_url = null;
        self.git_base_rev = null;
    }

    pub fn encode(self: *const SpaceOrigin, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.origin_space_id);
        try self.fork_base_version.encode(allocator, w);
        try w.writeOptBytes(allocator, self.git_remote_url);
        try w.writeOptBytes(allocator, self.git_base_rev);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!SpaceOrigin {
        const oid = try r.readU128();
        var ver = try Version.decode(allocator, r);
        errdefer ver.deinit(allocator);
        const url = try r.readOptBytesAlloc(allocator);
        errdefer if (url) |u| allocator.free(u);
        const rev = try r.readOptBytesAlloc(allocator);
        return .{
            .origin_space_id = oid,
            .fork_base_version = ver,
            .git_remote_url = url,
            .git_base_rev = rev,
        };
    }
};

pub const SpaceConflictKind = enum(u8) {
    text = 1,
    binary = 2,
    deleted_here = 3,
    deleted_there = 4,
};

pub const SpaceConflict = struct {
    path: []u8,
    kind: SpaceConflictKind,
    ours: ?[]u8,
    theirs: ?[]u8,

    pub fn clone(self: *const SpaceConflict, allocator: Allocator) Allocator.Error!SpaceConflict {
        const p = try allocator.dupe(u8, self.path);
        errdefer allocator.free(p);
        const o = if (self.ours) |b| try allocator.dupe(u8, b) else null;
        errdefer if (o) |b| allocator.free(b);
        const t = if (self.theirs) |b| try allocator.dupe(u8, b) else null;
        return .{ .path = p, .kind = self.kind, .ours = o, .theirs = t };
    }

    pub fn deinit(self: *SpaceConflict, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.ours) |b| allocator.free(b);
        if (self.theirs) |b| allocator.free(b);
    }
};

pub const SpaceResolution = union(enum) {
    ours,
    theirs,
    content: ?[]const u8,
};

pub const SpaceSyncReport = struct {
    brought: usize = 0,
    merged: [][]u8 = &.{},
    conflicts: []SpaceConflict = &.{},

    pub fn deinit(self: *SpaceSyncReport, allocator: Allocator) void {
        for (self.merged) |p| allocator.free(p);
        if (self.merged.len > 0) allocator.free(self.merged);
        for (self.conflicts) |*c| c.deinit(allocator);
        if (self.conflicts.len > 0) allocator.free(self.conflicts);
    }
};

pub const SpaceLandReport = struct {
    sync: SpaceSyncReport = .{},
    landed: usize = 0,

    pub fn deinit(self: *SpaceLandReport, allocator: Allocator) void {
        self.sync.deinit(allocator);
    }
};

pub const SearchHit = struct {
    path: []u8,
    line: u32,
    snippet: []u8,

    pub fn deinit(self: *SearchHit, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.snippet);
    }
};

pub const DirEntryKind = enum {
    file,
    dir,
    symlink,
};

pub const DirEntry = struct {
    name: []u8,
    kind: DirEntryKind,

    pub fn deinit(self: *DirEntry, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const MetaEntry = struct {
    key: []u8,
    value: []u8,

    pub fn deinit(self: *MetaEntry, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const SpaceError = error{
    SpaceLocked,
    LockFailed,
    NotAFork,
    HistoryNotShared,
    UnresolvedConflicts,
    ConflictNotFound,
    NotFound,
    NotAFile,
    NotADir,
    InvalidPath,
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

const FallbackGitReaderCtx = struct {
    handle: BlobStoreHandle,

    fn readAlloc(ptr: *anyopaque, allocator: Allocator, oid: id.GitOid) Allocator.Error!?[]u8 {
        const self: *FallbackGitReaderCtx = @ptrCast(@alignCast(ptr));
        return self.handle.getGitFallback(allocator, oid.slice()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn readCached(_: *anyopaque, _: id.GitOid) ?[]const u8 {
        return null;
    }

    fn contains(ptr: *anyopaque, oid: id.GitOid) bool {
        const self: *FallbackGitReaderCtx = @ptrCast(@alignCast(ptr));
        const raw = self.handle.getGitFallback(std.heap.page_allocator, oid.slice()) catch return false;
        if (raw) |buf| {
            std.heap.page_allocator.free(buf);
            return true;
        }
        return false;
    }
};

const ProcessLockSlot = struct {
    in_use: bool = false,
    dev: u64 = 0,
    ino: u64 = 0,
    fd: posix.fd_t = -1,
    refs: usize = 0,
};

var g_lock_spin: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_lock_slots: [512]ProcessLockSlot = @splat(.{});

fn acquireLockSpin() void {
    while (g_lock_spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn releaseLockSpin() void {
    g_lock_spin.store(0, .release);
}

pub const StateDirLock = struct {
    slot_idx: ?usize = null,
    direct_fd: ?posix.fd_t = null,

    pub fn acquire(io: Io, state_dir: Io.Dir) !StateDirLock {
        const lock_file = try state_dir.createFile(io, "lock", .{ .truncate = false });
        const st = lock_file.stat(io) catch {
            lock_file.close(io);
            return error.LockFailed;
        };
        const ino: u64 = st.inode;
        const fd: posix.fd_t = lock_file.handle;
        var dev: u64 = 0;
        if (builtin.os.tag == .linux) {
            var stx: linux.Statx = undefined;
            if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{}, &stx)) == .SUCCESS) {
                dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
            }
        }

        acquireLockSpin();
        defer releaseLockSpin();

        for (&g_lock_slots, 0..) |*slot, idx| {
            if (slot.in_use and slot.dev == dev and slot.ino == ino) {
                slot.refs += 1;
                lock_file.close(io);
                return .{ .slot_idx = idx };
            }
        }

        const rc = linux.flock(fd, @intCast(posix.LOCK.EX | posix.LOCK.NB));
        if (linux.errno(rc) != .SUCCESS) {
            lock_file.close(io);
            return error.SpaceLocked;
        }

        for (&g_lock_slots, 0..) |*slot, idx| {
            if (!slot.in_use) {
                slot.* = .{
                    .in_use = true,
                    .dev = dev,
                    .ino = ino,
                    .fd = fd,
                    .refs = 1,
                };
                return .{ .slot_idx = idx };
            }
        }
        return .{ .direct_fd = fd };
    }

    pub fn release(self: *StateDirLock) void {
        if (self.slot_idx) |idx| {
            acquireLockSpin();
            if (g_lock_slots[idx].in_use) {
                if (g_lock_slots[idx].refs > 1) {
                    g_lock_slots[idx].refs -= 1;
                } else {
                    const fd = g_lock_slots[idx].fd;
                    _ = linux.flock(fd, @intCast(posix.LOCK.UN));
                    _ = linux.close(fd);
                    g_lock_slots[idx] = .{};
                }
            }
            releaseLockSpin();
            self.slot_idx = null;
        }
        if (self.direct_fd) |fd| {
            _ = linux.flock(fd, @intCast(posix.LOCK.UN));
            _ = linux.close(fd);
            self.direct_fd = null;
        }
    }
};

pub const FileFlock = struct {
    file: Io.File,

    pub fn acquireBlocking(io: Io, dir: Io.Dir, lock_name: []const u8) !FileFlock {
        const f = try dir.createFile(io, lock_name, .{ .truncate = false });
        errdefer f.close(io);
        if (builtin.os.tag == .linux) {
            while (true) {
                const rc = linux.flock(f.handle, @intCast(posix.LOCK.EX));
                switch (linux.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => return error.LockFailed,
                }
            }
        }
        return .{ .file = f };
    }

    pub fn release(self: *FileFlock, io: Io) void {
        if (builtin.os.tag == .linux) {
            _ = linux.flock(self.file.handle, @intCast(posix.LOCK.UN));
        }
        self.file.close(io);
    }
};

pub const Space = struct {
    allocator: Allocator,
    io: Io,
    space_id: u128,
    kind: SpaceKind,
    state_path: []u8,
    state_dir: Io.Dir,
    state_lock: StateDirLock,
    history: History,
    batch_log: *log_mod.AppendLog,
    segments: *segments_mod.SegmentStore,
    snapshot_stack: ?*snapshot_mod.SnapshotStack = null,
    manifest: manifest_mod.Manifest = .{},
    blob_store: BlobStoreHandle,
    blob_reader_ctx: *BlobReaderCtx,
    fallback_git_reader_ctx: *FallbackGitReaderCtx,
    external_git_reader: ?history_mod.ExternalGitReader = null,
    actor_id: id.ActorId,
    origin: ?SpaceOrigin = null,
    resources: ?*pool_mod.DaemonResources = null,
    conflicts_path: []u8,
    retained_versions: std.ArrayList(Version) = .empty,
    batch_log_idx: std.AutoHashMapUnmanaged(id.BatchId, usize) = .empty,
    in_checkpoint: bool = false,

    fn readBatchLogSlice(ptr: *anyopaque, offset: u64, len: u32) ?[]const u8 {
        const log_ptr: *log_mod.AppendLog = @ptrCast(@alignCast(ptr));
        return log_ptr.readSlice(offset, len);
    }

    pub fn open(
        allocator: Allocator,
        io: Io,
        state_path: []const u8,
        space_id: u128,
        kind: SpaceKind,
        resources: ?*pool_mod.DaemonResources,
    ) !Space {
        try Io.Dir.cwd().createDirPath(io, state_path);

        var transferred = false;
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

        const fallback_git_reader_ctx = try allocator.create(FallbackGitReaderCtx);
        errdefer if (!transferred) allocator.destroy(fallback_git_reader_ctx);
        fallback_git_reader_ctx.* = .{ .handle = blob_handle };

        const segments = try allocator.create(segments_mod.SegmentStore);
        var seg_inited = false;
        errdefer if (!transferred) {
            if (seg_inited) segments.deinit();
            allocator.destroy(segments);
        };
        segments.* = try segments_mod.SegmentStore.open(allocator, io, state_dir);
        seg_inited = true;

        const loaded_manifest = try manifest_mod.Manifest.load(io, state_dir);
        var mf: manifest_mod.Manifest = loaded_manifest orelse .{
            .history_id = space_id,
            .generation = 0,
            .base_gen = 0,
            .delta_gen = 0,
            .wal_gen = 1,
            .wal_base_seq = 0,
        };
        if (mf.history_id == 0) mf.history_id = space_id;
        if (mf.wal_gen == 0) mf.wal_gen = 1;

        var wal_dir = try state_dir.openDir(io, "wal", .{ .iterate = true });
        defer wal_dir.close(io);

        const batch_log = try allocator.create(log_mod.AppendLog);
        var batch_log_inited = false;
        errdefer if (!transferred) {
            if (batch_log_inited) batch_log.deinit();
            allocator.destroy(batch_log);
        };
        var wal_name_buf: [32]u8 = undefined;
        const wal_name = manifest_mod.walFileName(mf.wal_gen, &wal_name_buf);
        batch_log.* = try log_mod.AppendLog.open(allocator, io, wal_dir, wal_name, true);
        if (batch_log.next_seq <= mf.wal_base_seq) {
            batch_log.next_seq = mf.wal_base_seq + 1;
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
            .ptr = fallback_git_reader_ctx,
            .readAllocFn = FallbackGitReaderCtx.readAlloc,
            .readCachedFn = FallbackGitReaderCtx.readCached,
            .containsFn = FallbackGitReaderCtx.contains,
        });

        const actor = try loadOrCreateActor(io, state_dir);
        const state_path_copy = try allocator.dupe(u8, state_path);
        errdefer if (!transferred) allocator.free(state_path_copy);
        const conflicts_path = try std.fmt.allocPrint(allocator, "{s}/conflicts.0ndb", .{state_path});
        errdefer if (!transferred) allocator.free(conflicts_path);

        var loaded_origin = try loadOrigin(allocator, io, state_dir);
        errdefer if (!transferred) {
            if (loaded_origin) |*o| o.deinit(allocator);
        };

        var sp = Space{
            .allocator = allocator,
            .io = io,
            .space_id = space_id,
            .kind = kind,
            .state_path = state_path_copy,
            .state_dir = state_dir,
            .state_lock = state_lock,
            .history = hist,
            .batch_log = batch_log,
            .segments = segments,
            .snapshot_stack = null,
            .manifest = mf,
            .blob_store = blob_handle,
            .blob_reader_ctx = blob_reader_ctx,
            .fallback_git_reader_ctx = fallback_git_reader_ctx,
            .external_git_reader = null,
            .actor_id = actor,
            .origin = loaded_origin,
            .resources = resources,
            .conflicts_path = conflicts_path,
            .retained_versions = .empty,
            .batch_log_idx = .empty,
            .in_checkpoint = false,
        };
        transferred = true;
        errdefer sp.deinit();

        if (loaded_manifest != null) {
            if (mf.base_gen != 0 or mf.delta_gen != 0) {
                var snap_dir = try sp.state_dir.openDir(io, "snap", .{ .iterate = true });
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
                sp.snapshot_stack = stack;
                sp.history.attachSnapshotStack(stack);

                var msd = try stack.loadStateIntoHistory(allocator, &sp.history);
                defer msd.deinit(allocator);
                for (msd.retained_versions.items) |*rv| {
                    try sp.retained_versions.append(allocator, try rv.clone(allocator));
                }
            }
            try sp.replayLogAfterSeq(mf.wal_base_seq);
            manifest_mod.Manifest.gcOrphanFiles(allocator, io, sp.state_dir, sp.manifest);
        } else {
            try sp.manifest.saveAtomic(io, sp.state_dir);
            mmap.fsyncDir(io, sp.state_dir) catch {};
        }

        return sp;
    }

    pub fn deinit(self: *Space) void {
        self.history.deinit();
        if (self.snapshot_stack) |stack| {
            stack.release();
            self.snapshot_stack = null;
        }
        self.batch_log.deinit();
        self.allocator.destroy(self.batch_log);
        self.segments.deinit();
        self.allocator.destroy(self.segments);
        self.allocator.destroy(self.blob_reader_ctx);
        self.allocator.destroy(self.fallback_git_reader_ctx);
        self.blob_store.deinit(self.allocator);
        for (self.retained_versions.items) |*rv| rv.deinit(self.allocator);
        self.retained_versions.deinit(self.allocator);
        self.batch_log_idx.deinit(self.allocator);
        if (self.origin) |*o| o.deinit(self.allocator);
        self.allocator.free(self.conflicts_path);
        self.allocator.free(self.state_path);
        self.state_lock.release();
        self.state_dir.close(self.io);
    }

    pub fn attachExternalGitReader(self: *Space, reader: ?history_mod.ExternalGitReader) void {
        self.external_git_reader = reader;
        if (reader) |r| {
            self.history.setGitReader(r);
        } else {
            self.history.setGitReader(.{
                .ptr = self.fallback_git_reader_ctx,
                .readAllocFn = FallbackGitReaderCtx.readAlloc,
                .readCachedFn = FallbackGitReaderCtx.readCached,
                .containsFn = FallbackGitReaderCtx.contains,
            });
        }
    }

    pub fn setOrigin(self: *Space, new_origin: ?SpaceOrigin) !void {
        if (self.origin) |*old| old.deinit(self.allocator);
        if (new_origin) |*no| {
            self.origin = try no.clone(self.allocator);
            try saveOrigin(self.allocator, self.io, self.state_dir, &self.origin.?);
        } else {
            self.origin = null;
            self.state_dir.deleteFile(self.io, "origin.0ndb") catch {};
        }
    }

    pub fn approxMemoryBytes(self: *const Space) usize {
        var bytes: usize = @sizeOf(Space) + self.history.ownedHeapBytes();
        bytes += self.history.tree.loadedInodesCount() * 256;
        bytes += self.batch_log_idx.count() * 48;
        return bytes;
    }

    pub fn hibernate(self: *Space) void {
        self.history.hibernate();
        if (self.snapshot_stack) |stack| stack.hibernate();
        self.batch_log.hibernate();
        self.segments.hibernate();
        if (!self.blob_store.isShared()) {
            self.blob_store.hibernate();
        }
    }

    pub fn headsClone(self: *const Space, allocator: Allocator) Allocator.Error!Version {
        return self.history.dag.heads.clone(allocator);
    }

    pub fn readFileAlloc(self: *const Space, allocator: Allocator, rel_path: []const u8) !?[]u8 {
        const norm = trimRelPath(rel_path);
        return try self.history.readFileAt(allocator, norm, null);
    }

    pub fn readFileAt(self: *const Space, allocator: Allocator, rel_path: []const u8, version: ?*const Version) !?[]u8 {
        const norm = trimRelPath(rel_path);
        return try self.history.readFileAt(allocator, norm, version);
    }

    pub fn putFile(self: *Space, actor: id.ActorId, rel_path: []const u8, bytes: []const u8) !id.BatchId {
        return self.putFileWithMeta(actor, rel_path, bytes, .regular, null);
    }

    pub fn putFileWithMeta(
        self: *Space,
        actor: id.ActorId,
        rel_path: []const u8,
        bytes: []const u8,
        mode: tree_mod.FileMode,
        ending_opt: ?tree_mod.LineEnding,
    ) !id.BatchId {
        const norm = trimRelPath(rel_path);
        if (norm.len == 0) return error.InvalidPath;

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

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const start_ts = self.history.nextStartTs(&parents);

        const existing = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, norm);
        const is_bin = isBinaryBytes(bytes);

        if (existing) |iid| {
            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(iid);
            const is_file = if (inode_opt) |in| in.fileConstPtr() != null else false;
            const cur_mode = if (inode_opt) |in| (if (in.fileConstPtr()) |fp| (if (fp.mode.get()) |m| m.* else tree_mod.FileMode.regular) else tree_mod.FileMode.regular) else tree_mod.FileMode.regular;
            const cur_ending = if (inode_opt) |in| (if (in.fileConstPtr()) |fp| (if (fp.line_ending.get()) |l| l.* else tree_mod.LineEnding.lf) else tree_mod.LineEnding.lf) else tree_mod.LineEnding.lf;
            const cur_is_text = if (inode_opt) |in| (if (in.fileConstPtr()) |fp| (if (fp.content.get()) |c| (c.* == .text or c.* == .git_lazy) else false) else false) else false;
            self.history.tree.endPinScope();

            if (is_file) {
                if (cur_mode != mode) {
                    try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = mode } });
                }
                if (is_bin) {
                    const oid = id.hashBytes(bytes);
                    try blobs.append(self.allocator, .{ .oid = oid, .data = try self.allocator.dupe(u8, bytes) });
                    try ops.append(self.allocator, .{ .set_content = .{
                        .inode = iid,
                        .content = .{ .binary = .{ .oid = oid, .len = bytes.len } },
                    } });
                } else {
                    const desired_ending = ending_opt orelse detectLineEnding(bytes);
                    const normalized = try normalizeToLf(self.allocator, bytes);
                    defer self.allocator.free(normalized);
                    if (cur_ending != desired_ending) {
                        try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = desired_ending } });
                    }
                    if (cur_is_text) {
                        const old_bytes_opt = try self.history.readFileAt(self.allocator, norm, null);
                        defer if (old_bytes_opt) |ob| self.allocator.free(ob);
                        if (old_bytes_opt) |old_bytes| {
                            if (!std.mem.eql(u8, old_bytes, normalized)) {
                                var d = try diff.diffBytes(self.allocator, old_bytes, normalized);
                                defer d.deinit(self.allocator);
                                if (d.splices.items.len > 0) {
                                    try ops.append(self.allocator, .{ .edit_text = .{
                                        .inode = iid,
                                        .text = try self.allocator.dupe(u8, d.inserted.items),
                                        .splices = try self.allocator.dupe(diff.Splice, d.splices.items),
                                    } });
                                }
                            } else if (ops.items.len == 0) {
                                const cm = try op_mod.makeTextContent(self.allocator, normalized);
                                if (cm[1]) |att| try blobs.append(self.allocator, att);
                                try ops.append(self.allocator, .{ .set_content = .{ .inode = iid, .content = cm[0] } });
                            }
                        } else {
                            const cm = try op_mod.makeTextContent(self.allocator, normalized);
                            if (cm[1]) |att| try blobs.append(self.allocator, att);
                            try ops.append(self.allocator, .{ .set_content = .{ .inode = iid, .content = cm[0] } });
                        }
                    } else {
                        const cm = try op_mod.makeTextContent(self.allocator, normalized);
                        if (cm[1]) |att| try blobs.append(self.allocator, att);
                        try ops.append(self.allocator, .{ .set_content = .{ .inode = iid, .content = cm[0] } });
                    }
                }
            } else {
                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
                defer freeStringMapKeys(self.allocator, &pending_dirs);
                const parent_iid = try self.ensureParentDirs(actor, start_ts, norm, &ops, &pending_dirs);
                try self.appendCreateFileOp(parent_iid, std.fs.path.basename(norm), bytes, mode, ending_opt, is_bin, &ops, &blobs);
            }
        } else {
            var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
            defer freeStringMapKeys(self.allocator, &pending_dirs);
            const parent_iid = try self.ensureParentDirs(actor, start_ts, norm, &ops, &pending_dirs);
            try self.appendCreateFileOp(parent_iid, std.fs.path.basename(norm), bytes, mode, ending_opt, is_bin, &ops, &blobs);
        }

        return try self.commitOpsList(actor, start_ts, &parents, &ops, &blobs);
    }

    pub fn editText(self: *Space, actor: id.ActorId, rel_path: []const u8, splices: []const text_mod.TextSplice) !id.BatchId {
        const norm = trimRelPath(rel_path);
        if (norm.len == 0) return error.InvalidPath;
        const iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, norm) orelse return error.NotFound;

        self.history.tree.beginPinScope();
        const is_file = if (self.history.tree.get(iid)) |in| in.fileConstPtr() != null else false;
        self.history.tree.endPinScope();
        if (!is_file) return error.NotAFile;

        var total_ins: usize = 0;
        for (splices) |s| total_ins += s.text.len;
        const diff_splices = try self.allocator.alloc(diff.Splice, splices.len);
        errdefer self.allocator.free(diff_splices);
        const inserted = try self.allocator.alloc(u8, total_ins);
        errdefer self.allocator.free(inserted);
        var pos: usize = 0;
        for (splices, 0..) |s, i| {
            diff_splices[i] = .{ .at = s.at, .del = s.del, .ins = s.text.len };
            if (s.text.len > 0) {
                @memcpy(inserted[pos .. pos + s.text.len], s.text);
                pos += s.text.len;
            }
        }

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const start_ts = self.history.nextStartTs(&parents);

        var ops_arr = [_]op_mod.Op{.{ .edit_text = .{
            .inode = iid,
            .text = inserted,
            .splices = diff_splices,
        } }};
        defer ops_arr[0].deinit(self.allocator);

        const batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = start_ts,
                .end = start_ts,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = &ops_arr,
            .blobs = &.{},
        };
        _ = try self.commitBatch(&batch);
        return batch.header.batchId();
    }

    pub fn deletePath(self: *Space, actor: id.ActorId, rel_path: []const u8) !?id.BatchId {
        const norm = trimRelPath(rel_path);
        if (norm.len == 0) return error.InvalidPath;
        const iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, norm) orelse return null;

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const start_ts = self.history.nextStartTs(&parents);

        var ops_arr = [_]op_mod.Op{.{ .remove = .{ .inode = iid } }};
        const batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = start_ts,
                .end = start_ts,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = &ops_arr,
            .blobs = &.{},
        };
        _ = try self.commitBatch(&batch);
        return batch.header.batchId();
    }

    pub fn movePath(self: *Space, actor: id.ActorId, from: []const u8, to: []const u8) !id.BatchId {
        const norm_from = trimRelPath(from);
        const norm_to = trimRelPath(to);
        if (norm_from.len == 0 or norm_to.len == 0) return error.InvalidPath;
        const src_iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, norm_from) orelse return error.NotFound;

        var ops: std.ArrayList(op_mod.Op) = .empty;
        defer {
            for (ops.items) |*o| o.deinit(self.allocator);
            ops.deinit(self.allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        defer blobs.deinit(self.allocator);

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const start_ts = self.history.nextStartTs(&parents);

        if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, norm_to)) |dst_iid| {
            if (!dst_iid.eql(src_iid)) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = dst_iid } });
            }
        }

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer freeStringMapKeys(self.allocator, &pending_dirs);
        const parent_iid = try self.ensureParentDirs(actor, start_ts, norm_to, &ops, &pending_dirs);
        try ops.append(self.allocator, .{ .rename = .{
            .inode = src_iid,
            .parent = parent_iid,
            .name = try self.allocator.dupe(u8, std.fs.path.basename(norm_to)),
        } });

        return try self.commitOpsList(actor, start_ts, &parents, &ops, &blobs);
    }

    pub fn listDir(self: *const Space, allocator: Allocator, rel_dir: []const u8) ![]DirEntry {
        const norm = trimRelPath(rel_dir);
        const dir_iid = if (norm.len == 0)
            id.InodeId.ROOT
        else
            (try self.history.tree.resolvePath(allocator, text_mod.View.EVERYTHING, norm)) orelse return error.NotFound;

        self.history.tree.beginPinScope();
        defer self.history.tree.endPinScope();
        if (!dir_iid.isRoot()) {
            const dnode = self.history.tree.get(dir_iid) orelse return error.NotFound;
            if (!dnode.isDir()) return error.NotADir;
        }

        var raw_entries = try self.history.tree.listDir(allocator, text_mod.View.EVERYTHING, dir_iid);
        defer {
            for (raw_entries.items) |*e| e.deinit(allocator);
            raw_entries.deinit(allocator);
        }

        var out: std.ArrayList(DirEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        for (raw_entries.items) |e| {
            const inode = self.history.tree.get(e.inode_id) orelse continue;
            const kind: DirEntryKind = switch (inode.kind) {
                .dir => .dir,
                .file => .file,
                .symlink => .symlink,
            };
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, e.name),
                .kind = kind,
            });
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn searchText(
        self: *const Space,
        allocator: Allocator,
        query: []const u8,
        path_prefix: ?[]const u8,
        max_hits: usize,
    ) ![]SearchHit {
        var hits: std.ArrayList(SearchHit) = .empty;
        errdefer {
            for (hits.items) |*h| h.deinit(allocator);
            hits.deinit(allocator);
        }
        if (query.len == 0 or max_hits == 0) return try hits.toOwnedSlice(allocator);
        const norm_prefix: ?[]const u8 = if (path_prefix) |p| blk: {
            const t = trimRelPath(p);
            break :blk if (t.len == 0) null else t;
        } else null;

        try self.searchDirRec(allocator, id.InodeId.ROOT, "", query, norm_prefix, max_hits, &hits);
        return try hits.toOwnedSlice(allocator);
    }

    fn searchDirRec(
        self: *const Space,
        allocator: Allocator,
        dir_iid: id.InodeId,
        prefix: []const u8,
        query: []const u8,
        path_prefix: ?[]const u8,
        max_hits: usize,
        hits: *std.ArrayList(SearchHit),
    ) !void {
        if (hits.items.len >= max_hits) return;
        var entries = try self.history.tree.listDir(allocator, text_mod.View.EVERYTHING, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        for (entries.items) |entry| {
            if (hits.items.len >= max_hits) break;
            const full = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(full);

            self.history.tree.beginPinScope();
            const inode_opt = self.history.tree.get(entry.inode_id);
            const node_kind: ?DirEntryKind = if (inode_opt) |in| switch (in.kind) {
                .dir => .dir,
                .file => .file,
                .symlink => .symlink,
            } else null;
            const is_bin_content = if (inode_opt) |in| switch (in.kind) {
                .file => |*f| if (f.content.get()) |ck| (ck.* == .binary or ck.* == .git_binary) else false,
                else => false,
            } else false;
            self.history.tree.endPinScope();

            const nk = node_kind orelse continue;
            switch (nk) {
                .dir => {
                    if (path_prefix) |pp| {
                        const could_match = std.mem.startsWith(u8, pp, full) or std.mem.startsWith(u8, full, pp);
                        if (!could_match) continue;
                    }
                    try self.searchDirRec(allocator, entry.inode_id, full, query, path_prefix, max_hits, hits);
                },
                .file => {
                    if (is_bin_content) continue;
                    if (path_prefix) |pp| {
                        if (!std.mem.startsWith(u8, full, pp)) continue;
                    }
                    const raw_opt = try self.history.readInodeInView(allocator, entry.inode_id, text_mod.View.EVERYTHING);
                    const raw = raw_opt orelse continue;
                    defer allocator.free(raw);
                    if (isBinaryBytes(raw)) continue;

                    var line_no: u32 = 1;
                    var it = std.mem.splitScalar(u8, raw, '\n');
                    while (it.next()) |line_raw| : (line_no += 1) {
                        const line = std.mem.trimEnd(u8, line_raw, "\r");
                        if (std.mem.indexOf(u8, line, query) != null) {
                            const max_snip: usize = @min(line.len, 240);
                            const p_copy = try allocator.dupe(u8, full);
                            errdefer allocator.free(p_copy);
                            const s_copy = try allocator.dupe(u8, line[0..max_snip]);
                            try hits.append(allocator, .{
                                .path = p_copy,
                                .line = line_no,
                                .snippet = s_copy,
                            });
                            if (hits.items.len >= max_hits) break;
                        }
                    }
                },
                .symlink => {},
            }
        }
    }

    pub fn getMeta(self: *const Space, key: []const u8) ?[]const u8 {
        const lww = self.history.meta.getPtr(key) orelse return null;
        const val = lww.get() orelse return null;
        return val.*;
    }

    pub fn setMeta(self: *Space, actor: id.ActorId, key: []const u8, val: ?[]const u8) !id.BatchId {
        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const start_ts = self.history.nextStartTs(&parents);

        const k_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k_copy);
        const v_copy: ?[]u8 = if (val) |v| try self.allocator.dupe(u8, v) else null;

        var ops_arr = [_]op_mod.Op{.{ .meta = .{ .key = k_copy, .value = v_copy } }};
        defer ops_arr[0].deinit(self.allocator);

        const batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = start_ts,
                .end = start_ts,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = &ops_arr,
            .blobs = &.{},
        };
        _ = try self.commitBatch(&batch);
        return batch.header.batchId();
    }

    pub fn listMetaPrefix(self: *const Space, allocator: Allocator, prefix: []const u8) ![]MetaEntry {
        var out: std.ArrayList(MetaEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }

        var it = self.history.meta.iterator();
        while (it.next()) |kv| {
            if (!std.mem.startsWith(u8, kv.key_ptr.*, prefix)) continue;
            const latest = kv.value_ptr.get() orelse continue;
            const v = latest.* orelse continue;
            const kc = try allocator.dupe(u8, kv.key_ptr.*);
            errdefer allocator.free(kc);
            const vc = try allocator.dupe(u8, v);
            try out.append(allocator, .{ .key = kc, .value = vc });
        }

        std.mem.sort(MetaEntry, out.items, {}, struct {
            fn lt(_: void, a: MetaEntry, b: MetaEntry) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lt);
        return try out.toOwnedSlice(allocator);
    }

    pub fn hydrateBatchInodes(self: *Space, batches: []const id.BatchId) !void {
        for (batches) |bid| {
            if (self.history.batch_inodes.contains(bid)) continue;
            var touched = try self.collectTouchedInodes(self.allocator, &.{bid});
            defer touched.deinit(self.allocator);
            const slice = try self.history.allocator.alloc(id.InodeId, touched.count());
            errdefer self.history.allocator.free(slice);
            var i: usize = 0;
            var it = touched.keyIterator();
            while (it.next()) |k| : (i += 1) {
                slice[i] = k.*;
            }
            try self.history.batch_inodes.put(self.history.allocator, bid, slice);
        }
    }

    pub fn rollbackToVersion(self: *Space, actor: id.ActorId, target_version: *const Version) !bool {
        if (target_version.eql(&self.history.dag.heads)) return false;
        var diff_batches = try self.history.dag.difference(self.allocator, &self.history.dag.heads, target_version);
        defer diff_batches.deinit(self.allocator);
        if (diff_batches.items.len == 0) return false;
        try self.hydrateBatchInodes(diff_batches.items);
        const batch_opt = try self.history.buildRollbackBatch(
            self.allocator,
            actor,
            target_version,
            id.nowMs(self.io),
        );
        var batch = batch_opt orelse return false;
        defer batch.deinit(self.allocator);
        return try self.commitBatch(&batch);
    }

    fn rollbackWalAppend(self: *Space, prev_offset: u64, prev_next_seq: u64, prev_index_len: usize) void {
        self.batch_log.file.setLength(self.io, prev_offset) catch {};
        self.batch_log.write_offset = prev_offset;
        self.batch_log.next_seq = prev_next_seq;
        self.batch_log.index.shrinkRetainingCapacity(prev_index_len);
    }

    pub fn commitBatch(self: *Space, batch: *const op_mod.Batch) !bool {
        const already = self.history.dag.check(&batch.header) catch |err| return err;
        if (already) return false;

        if (batch.blobs.len > 0) {
            const items = try self.allocator.alloc(blobs_mod.BlobItem, batch.blobs.len);
            defer self.allocator.free(items);
            for (batch.blobs, 0..) |b, i| {
                items[i] = .{ .hash = b.oid, .data = b.data };
            }
            try self.blob_store.putBatch(items);
        }

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);
        try batch.encodeWithSpans(self.allocator, &w, &op_spans, &blob_spans);

        const prev_offset = self.batch_log.write_offset;
        const prev_next_seq = self.batch_log.next_seq;
        const prev_index_len = self.batch_log.index.items.len;

        const append_res = try self.batch_log.appendWithOffset(self.batch_log.next_seq, FRAME_BATCH, 0, 0, w.items());
        const log_idx = self.batch_log.count() - 1;

        const applied = self.history.integrate(batch) catch |err| {
            self.rollbackWalAppend(prev_offset, prev_next_seq, prev_index_len);
            return err;
        };
        if (!applied) {
            self.rollbackWalAppend(prev_offset, prev_next_seq, prev_index_len);
            return false;
        }

        self.history.pinBatchToLog(batch, append_res.payload_offset, op_spans.items, blob_spans.items);
        try self.batch_log_idx.put(self.allocator, batch.header.batchId(), log_idx);
        self.maybeAutoCheckpoint();
        return true;
    }

    pub fn readBatchPayloadAlloc(self: *Space, allocator: Allocator, bid: id.BatchId) !?[]u8 {
        if (self.batch_log_idx.get(bid)) |idx| {
            const frame = try self.batch_log.readAt(idx);
            return try allocator.dupe(u8, frame.payload);
        }
        if (self.history.dag.getBatchLocation(bid)) |loc| {
            if (loc.seg_id > 0 and loc.len > 0) {
                return try self.segments.readFrameAt(loc.seg_id, loc.offset, loc.len, allocator);
            }
        }
        const total = self.batch_log.count();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const entry = self.batch_log.index.items[i];
            if (entry.kind != FRAME_BATCH) continue;
            const frame = self.batch_log.readAt(i) catch continue;
            var r = codec.Reader.init(frame.payload);
            var hdr = dag_mod.BatchHeader.decode(allocator, &r) catch continue;
            defer hdr.deinit(allocator);
            if (hdr.batchId().eql(bid)) {
                return try allocator.dupe(u8, frame.payload);
            }
        }
        return null;
    }

    pub fn collectTouchedInodes(
        self: *Space,
        allocator: Allocator,
        batches: []const id.BatchId,
    ) !std.AutoHashMapUnmanaged(id.InodeId, void) {
        var out: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        errdefer out.deinit(allocator);

        for (batches) |bid| {
            if (self.history.batch_inodes.get(bid)) |inodes| {
                for (inodes) |iid| {
                    if (!iid.isRoot()) try out.put(allocator, iid, {});
                }
                continue;
            }
            const payload = (try self.readBatchPayloadAlloc(allocator, bid)) orelse continue;
            defer allocator.free(payload);
            var r = codec.Reader.init(payload);
            var batch = op_mod.Batch.decode(allocator, &r) catch continue;
            defer batch.deinit(allocator);
            for (batch.ops, 0..) |*operation, idx| {
                const maybe_iid: ?id.InodeId = switch (operation.*) {
                    .create_dir, .create_file, .create_symlink => id.InodeId.init(batch.header.opId(idx), 0),
                    .rename => |v| v.inode,
                    .remove => |v| v.inode,
                    .restore => |v| v.inode,
                    .edit_text => |v| v.inode,
                    .set_content => |v| v.inode,
                    .set_mode => |v| v.inode,
                    .set_line_ending => |v| v.inode,
                    .set_symlink_target => |v| v.inode,
                    else => null,
                };
                if (maybe_iid) |iid| {
                    if (!iid.isRoot()) try out.put(allocator, iid, {});
                }
            }
        }
        return out;
    }

    pub fn exportMissing(self: *Space, allocator: Allocator, peer_dag: *const dag_mod.Dag) ![]op_mod.Batch {
        var missing_ids: std.ArrayList(id.BatchId) = .empty;
        defer missing_ids.deinit(allocator);

        var all_bids = try self.history.dag.collectAllBatchIds(allocator);
        defer all_bids.deinit(allocator);
        for (all_bids.items) |bid| {
            if (!peer_dag.containsBatch(bid)) {
                try missing_ids.append(allocator, bid);
            }
        }
        if (missing_ids.items.len == 0) return &.{};

        std.mem.sort(id.BatchId, missing_ids.items, {}, struct {
            fn lt(_: void, a: id.BatchId, b: id.BatchId) bool {
                return a.order(b) == .lt;
            }
        }.lt);

        var out: std.ArrayList(op_mod.Batch) = .empty;
        errdefer {
            for (out.items) |*b| b.deinit(allocator);
            out.deinit(allocator);
        }

        for (missing_ids.items) |bid| {
            const payload = (try self.readBatchPayloadAlloc(allocator, bid)) orelse continue;
            defer allocator.free(payload);
            var r = codec.Reader.init(payload);
            var batch = try op_mod.Batch.decode(allocator, &r);
            errdefer batch.deinit(allocator);

            var extra_blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
            errdefer {
                for (extra_blobs.items) |*b| b.deinit(allocator);
                extra_blobs.deinit(allocator);
            }
            for (batch.blobs) |b| try extra_blobs.append(allocator, .{
                .oid = b.oid,
                .data = try allocator.dupe(u8, b.data),
            });

            for (batch.ops) |*operation| {
                const oid_opt: ?id.Oid = switch (operation.*) {
                    .create_file => |v| switch (v.content) {
                        .text_blob => |ref| ref.oid,
                        .binary => |ref| ref.oid,
                        else => null,
                    },
                    .set_content => |v| switch (v.content) {
                        .text_blob => |ref| ref.oid,
                        .binary => |ref| ref.oid,
                        else => null,
                    },
                    else => null,
                };
                if (oid_opt) |oid| {
                    var already_in = false;
                    for (extra_blobs.items) |eb| {
                        if (std.mem.eql(u8, &eb.oid, &oid)) {
                            already_in = true;
                            break;
                        }
                    }
                    if (!already_in) {
                        if (try self.blob_store.get(allocator, oid)) |data| {
                            errdefer allocator.free(data);
                            try extra_blobs.append(allocator, .{ .oid = oid, .data = data });
                        }
                    }
                }
            }

            for (batch.blobs) |*b| b.deinit(allocator);
            allocator.free(batch.blobs);
            batch.blobs = &.{};
            batch.blobs = try extra_blobs.toOwnedSlice(allocator);
            try out.append(allocator, batch);
        }

        return try out.toOwnedSlice(allocator);
    }

    pub fn forkCow(self: *Space, dst_state_path: []const u8, new_space_id: u128) !Space {
        if (self.batch_log.count() > 0 or self.manifest.base_gen == 0) {
            try self.checkpoint(if (self.manifest.base_gen == 0) .major else .minor);
        }
        if (!self.blob_store.isShared()) {
            try self.blob_store.sealActivePack();
        }

        try Io.Dir.cwd().createDirPath(self.io, dst_state_path);
        var dst_dir = try Io.Dir.cwd().openDir(self.io, dst_state_path, .{ .iterate = true });
        defer dst_dir.close(self.io);
        try dst_dir.createDirPath(self.io, "snap");
        try dst_dir.createDirPath(self.io, "wal");
        try dst_dir.createDirPath(self.io, "seg");

        try linkOrCopyDirFiles(self.allocator, self.io, self.state_dir, dst_dir, "snap");
        try linkOrCopyDirFiles(self.allocator, self.io, self.state_dir, dst_dir, "seg");
        if (!self.blob_store.isShared()) {
            try dst_dir.createDirPath(self.io, "blobs");
            try linkOrCopyDirFiles(self.allocator, self.io, self.state_dir, dst_dir, "blobs");
        }

        var fork_manifest = self.manifest;
        fork_manifest.wal_gen = self.manifest.wal_gen + 1;
        try fork_manifest.saveAtomic(self.io, dst_dir);

        var base_ver = try self.history.headsClone();
        defer base_ver.deinit(self.allocator);
        const orig_meta = SpaceOrigin{
            .origin_space_id = self.space_id,
            .fork_base_version = base_ver,
            .git_remote_url = if (self.origin) |o| o.git_remote_url else null,
            .git_base_rev = if (self.origin) |o| o.git_base_rev else null,
        };
        try saveOrigin(self.allocator, self.io, dst_dir, &orig_meta);
        mmap.fsyncDir(self.io, dst_dir) catch {};

        return try Space.open(self.allocator, self.io, dst_state_path, new_space_id, self.kind, self.resources);
    }

    pub fn conflicts(self: *Space, allocator: Allocator) ![]SpaceConflict {
        var loaded = try self.loadConflictsList(allocator);
        errdefer {
            for (loaded.items) |*c| c.deinit(allocator);
            loaded.deinit(allocator);
        }

        var changed = false;
        var i: usize = 0;
        while (i < loaded.items.len) {
            const c = &loaded.items[i];
            if (c.kind == .text) {
                const cur_opt = try self.readFileAlloc(allocator, c.path);
                defer if (cur_opt) |b| allocator.free(b);
                if (cur_opt == null or !hasConflictMarkers(cur_opt.?)) {
                    var rem = loaded.orderedRemove(i);
                    rem.deinit(allocator);
                    changed = true;
                    continue;
                }
            }
            i += 1;
        }

        if (changed) {
            try self.saveConflictsSlice(loaded.items);
        }
        return try loaded.toOwnedSlice(allocator);
    }

    pub fn resolveConflict(self: *Space, rel_path: []const u8, resolution: SpaceResolution) !void {
        const norm = trimRelPath(rel_path);
        var list_c = try self.loadConflictsList(self.allocator);
        defer {
            for (list_c.items) |*c| c.deinit(self.allocator);
            list_c.deinit(self.allocator);
        }

        var idx_opt: ?usize = null;
        for (list_c.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.path, norm)) {
                idx_opt = i;
                break;
            }
        }
        const idx = idx_opt orelse return error.ConflictNotFound;
        const target = &list_c.items[idx];

        const chosen: ?[]const u8 = switch (resolution) {
            .ours => target.ours,
            .theirs => target.theirs,
            .content => |c| c,
        };

        if (chosen) |bytes| {
            _ = try self.putFile(self.actor_id, norm, bytes);
        } else {
            _ = try self.deletePath(self.actor_id, norm);
        }

        var rem = list_c.orderedRemove(idx);
        rem.deinit(self.allocator);
        try self.saveConflictsSlice(list_c.items);
    }

    const ClashItem = struct {
        iid: id.InodeId,
        extra_iid: ?id.InodeId,
        path: []u8,
        base: ?[]u8,
        ours: ?[]u8,
        theirs: ?[]u8,
        mode: tree_mod.FileMode,
        ending: tree_mod.LineEnding,

        fn deinit(c: *ClashItem, alloc: Allocator) void {
            alloc.free(c.path);
            if (c.base) |b| alloc.free(b);
            if (c.ours) |b| alloc.free(b);
            if (c.theirs) |b| alloc.free(b);
        }
    };

    fn computeClashes(
        self: *Space,
        origin_space: *Space,
        incoming: []const op_mod.Batch,
    ) !std.ArrayList(ClashItem) {
        var clashes: std.ArrayList(ClashItem) = .empty;
        errdefer {
            for (clashes.items) |*c| c.deinit(self.allocator);
            clashes.deinit(self.allocator);
        }

        var ours_only_ids: std.ArrayList(id.BatchId) = .empty;
        defer ours_only_ids.deinit(self.allocator);
        {
            var all_bids = try self.history.dag.collectAllBatchIds(self.allocator);
            defer all_bids.deinit(self.allocator);
            for (all_bids.items) |bid| {
                if (!origin_space.history.dag.containsBatch(bid)) {
                    try ours_only_ids.append(self.allocator, bid);
                }
            }
        }
        if (ours_only_ids.items.len == 0) return clashes;

        var base_cv = try self.history.dag.compileExcluding(self.allocator, ours_only_ids.items);
        defer base_cv.deinit(self.allocator);
        const base_view = base_cv.view();

        var ours_inodes = try self.collectTouchedInodes(self.allocator, ours_only_ids.items);
        defer ours_inodes.deinit(self.allocator);

        var theirs_inodes: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer theirs_inodes.deinit(self.allocator);
        for (incoming) |*b| {
            for (b.ops, 0..) |*operation, idx| {
                const maybe_iid: ?id.InodeId = switch (operation.*) {
                    .create_file, .create_symlink => id.InodeId.init(b.header.opId(idx), 0),
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
                    try theirs_inodes.put(self.allocator, iid, {});
                }
            }
        }

        var seen_paths: std.StringHashMapUnmanaged(void) = .empty;
        defer freeStringMapKeys(self.allocator, &seen_paths);

        var oit = ours_inodes.keyIterator();
        while (oit.next()) |iid_ptr| {
            const iid = iid_ptr.*;
            if (!theirs_inodes.contains(iid)) continue;

            const path_opt = (try self.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) orelse
                (try origin_space.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) orelse
                (try self.history.tree.pathOf(self.allocator, base_view, iid));
            const p = path_opt orelse continue;
            errdefer self.allocator.free(p);

            const b_bytes = try self.history.readInodeInView(self.allocator, iid, base_view);
            errdefer if (b_bytes) |b| self.allocator.free(b);
            const o_bytes = try self.history.readInodeInView(self.allocator, iid, text_mod.View.EVERYTHING);
            errdefer if (o_bytes) |b| self.allocator.free(b);
            const t_bytes = try origin_space.history.readInodeInView(self.allocator, iid, text_mod.View.EVERYTHING);
            errdefer if (t_bytes) |b| self.allocator.free(b);

            const ours_changed = !optBytesEql(b_bytes, o_bytes);
            const theirs_changed = !optBytesEql(b_bytes, t_bytes);
            if (ours_changed and theirs_changed) {
                const bm = resolveFileMeta(self, iid, base_view);
                const om = resolveFileMeta(self, iid, text_mod.View.EVERYTHING);
                const tm = resolveFileMeta(origin_space, iid, text_mod.View.EVERYTHING);
                const p_seen = try self.allocator.dupe(u8, p);
                const gop = try seen_paths.getOrPut(self.allocator, p_seen);
                if (gop.found_existing) self.allocator.free(p_seen);
                try clashes.append(self.allocator, .{
                    .iid = iid,
                    .extra_iid = null,
                    .path = p,
                    .base = b_bytes,
                    .ours = o_bytes,
                    .theirs = t_bytes,
                    .mode = mergeMode(bm.mode, om.mode, tm.mode),
                    .ending = mergeEnding(bm.ending, om.ending, tm.ending),
                });
            } else {
                self.allocator.free(p);
                if (b_bytes) |b| self.allocator.free(b);
                if (o_bytes) |b| self.allocator.free(b);
                if (t_bytes) |b| self.allocator.free(b);
            }
        }

        var oit2 = ours_inodes.keyIterator();
        while (oit2.next()) |iid_ptr| {
            const iid = iid_ptr.*;
            if (theirs_inodes.contains(iid)) continue;
            const p = (try self.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) orelse continue;
            if (seen_paths.contains(p)) {
                self.allocator.free(p);
                continue;
            }
            if (try origin_space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, p)) |t_iid| {
                if (!t_iid.eql(iid) and theirs_inodes.contains(t_iid)) {
                    const o_bytes = try self.history.readInodeInView(self.allocator, iid, text_mod.View.EVERYTHING);
                    errdefer if (o_bytes) |b| self.allocator.free(b);
                    const t_bytes = try origin_space.history.readInodeInView(self.allocator, t_iid, text_mod.View.EVERYTHING);
                    errdefer if (t_bytes) |b| self.allocator.free(b);
                    const om = resolveFileMeta(self, iid, text_mod.View.EVERYTHING);
                    const tm = resolveFileMeta(origin_space, t_iid, text_mod.View.EVERYTHING);
                    const p_seen = try self.allocator.dupe(u8, p);
                    const gop = try seen_paths.getOrPut(self.allocator, p_seen);
                    if (gop.found_existing) self.allocator.free(p_seen);
                    try clashes.append(self.allocator, .{
                        .iid = iid,
                        .extra_iid = t_iid,
                        .path = p,
                        .base = null,
                        .ours = o_bytes,
                        .theirs = t_bytes,
                        .mode = if (om.mode == .executable or tm.mode == .executable) .executable else .regular,
                        .ending = if (om.ending == .crlf or tm.ending == .crlf) .crlf else .lf,
                    });
                    continue;
                }
            }
            self.allocator.free(p);
        }

        return clashes;
    }

    pub fn previewSyncConflicts(self: *Space, allocator: Allocator, origin_space: *Space) ![][]u8 {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |p| allocator.free(p);
            paths.deinit(allocator);
        }

        const existing = try self.conflicts(allocator);
        defer {
            for (existing) |*c| c.deinit(allocator);
            allocator.free(existing);
        }
        for (existing) |c| {
            try paths.append(allocator, try allocator.dupe(u8, c.path));
        }

        const incoming = try origin_space.exportMissing(self.allocator, &self.history.dag);
        defer {
            for (incoming) |*b| b.deinit(self.allocator);
            self.allocator.free(incoming);
        }
        if (incoming.len == 0) return try paths.toOwnedSlice(allocator);

        var clashes = try self.computeClashes(origin_space, incoming);
        defer {
            for (clashes.items) |*cl| cl.deinit(self.allocator);
            clashes.deinit(self.allocator);
        }

        for (clashes.items) |*cl| {
            if (optBytesEql(cl.ours, cl.theirs)) continue;
            var is_conflict = false;
            if (cl.ours == null or cl.theirs == null) {
                is_conflict = true;
            } else {
                const ob = cl.ours.?;
                const tb = cl.theirs.?;
                const bb = cl.base orelse "";
                if (isBinaryBytes(ob) or isBinaryBytes(tb) or isBinaryBytes(bb)) {
                    is_conflict = true;
                } else {
                    const m = try merge3LinesDiff3(self.allocator, bb, ob, tb);
                    defer self.allocator.free(m.output);
                    if (m.has_conflict) is_conflict = true;
                }
            }
            if (is_conflict) {
                var dup = false;
                for (paths.items) |ep| {
                    if (std.mem.eql(u8, ep, cl.path)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try paths.append(allocator, try allocator.dupe(u8, cl.path));
            }
        }
        return try paths.toOwnedSlice(allocator);
    }

    pub fn syncFromOrigin(self: *Space, origin_space: *Space) !SpaceSyncReport {
        return try self.syncFromOriginAlloc(self.allocator, origin_space);
    }

    pub fn syncFromOriginAlloc(self: *Space, allocator: Allocator, origin_space: *Space) !SpaceSyncReport {
        if (self.history.history_id != origin_space.history.history_id) {
            return error.HistoryNotShared;
        }

        const incoming = try origin_space.exportMissing(self.allocator, &self.history.dag);
        defer {
            for (incoming) |*b| b.deinit(self.allocator);
            self.allocator.free(incoming);
        }

        if (incoming.len == 0) {
            const cur_conflicts = try self.conflicts(allocator);
            return .{ .brought = 0, .merged = &.{}, .conflicts = cur_conflicts };
        }

        var clashes = try self.computeClashes(origin_space, incoming);
        defer {
            for (clashes.items) |*cl| cl.deinit(self.allocator);
            clashes.deinit(self.allocator);
        }

        var brought: usize = 0;
        for (incoming) |*b| {
            if (try self.commitBatch(b)) {
                brought += 1;
            }
        }

        const existing_conflicts = try self.conflicts(allocator);
        var conflict_list: std.ArrayList(SpaceConflict) = .empty;
        errdefer {
            for (conflict_list.items) |*c| c.deinit(allocator);
            conflict_list.deinit(allocator);
        }
        var ec_transferred: usize = 0;
        errdefer {
            for (existing_conflicts[ec_transferred..]) |*c| c.deinit(allocator);
            allocator.free(existing_conflicts);
        }
        for (existing_conflicts) |c| {
            try conflict_list.append(allocator, c);
            ec_transferred += 1;
        }
        allocator.free(existing_conflicts);

        var merged_paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (merged_paths.items) |p| allocator.free(p);
            merged_paths.deinit(allocator);
        }

        for (clashes.items) |*cl| {
            if (cl.extra_iid) |extra| {
                const keep_iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, cl.path);
                if (keep_iid) |kid| {
                    if (kid.eql(cl.iid)) {
                        try self.removeInodeDirect(extra);
                    } else if (kid.eql(extra)) {
                        try self.removeInodeDirect(cl.iid);
                    } else {
                        try self.removeInodeDirect(extra);
                    }
                } else {
                    try self.removeInodeDirect(extra);
                }
            }

            const target_path_owned = if (cl.extra_iid == null)
                (try self.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, cl.iid)) orelse try self.allocator.dupe(u8, cl.path)
            else
                try self.allocator.dupe(u8, cl.path);
            defer self.allocator.free(target_path_owned);
            const target_path = target_path_owned;

            if (optBytesEql(cl.ours, cl.theirs)) {
                if (cl.ours) |o| {
                    _ = try self.putFileWithMeta(self.actor_id, target_path, o, cl.mode, cl.ending);
                } else {
                    _ = try self.deletePath(self.actor_id, target_path);
                }
                removeConflictByPath(&conflict_list, allocator, target_path);
                try merged_paths.append(allocator, try allocator.dupe(u8, target_path));
                continue;
            }

            if (cl.ours == null and cl.theirs != null) {
                _ = try self.putFileWithMeta(self.actor_id, target_path, cl.theirs.?, cl.mode, cl.ending);
                const p_dup = try allocator.dupe(u8, target_path);
                errdefer allocator.free(p_dup);
                const t_dup = try allocator.dupe(u8, cl.theirs.?);
                errdefer allocator.free(t_dup);
                try upsertConflict(&conflict_list, allocator, .{
                    .path = p_dup,
                    .kind = .deleted_here,
                    .ours = null,
                    .theirs = t_dup,
                });
                continue;
            }

            if (cl.ours != null and cl.theirs == null) {
                _ = try self.putFileWithMeta(self.actor_id, target_path, cl.ours.?, cl.mode, cl.ending);
                const p_dup = try allocator.dupe(u8, target_path);
                errdefer allocator.free(p_dup);
                const o_dup = try allocator.dupe(u8, cl.ours.?);
                errdefer allocator.free(o_dup);
                try upsertConflict(&conflict_list, allocator, .{
                    .path = p_dup,
                    .kind = .deleted_there,
                    .ours = o_dup,
                    .theirs = null,
                });
                continue;
            }

            const ob = cl.ours.?;
            const tb = cl.theirs.?;
            const bb = cl.base orelse "";
            if (isBinaryBytes(ob) or isBinaryBytes(tb) or isBinaryBytes(bb)) {
                _ = try self.putFileWithMeta(self.actor_id, target_path, ob, cl.mode, cl.ending);
                const p_dup = try allocator.dupe(u8, target_path);
                errdefer allocator.free(p_dup);
                const o_dup = try allocator.dupe(u8, ob);
                errdefer allocator.free(o_dup);
                const t_dup = try allocator.dupe(u8, tb);
                errdefer allocator.free(t_dup);
                try upsertConflict(&conflict_list, allocator, .{
                    .path = p_dup,
                    .kind = .binary,
                    .ours = o_dup,
                    .theirs = t_dup,
                });
                continue;
            }

            const m = try merge3LinesDiff3(self.allocator, bb, ob, tb);
            defer self.allocator.free(m.output);
            _ = try self.putFileWithMeta(self.actor_id, target_path, m.output, cl.mode, cl.ending);
            if (m.has_conflict) {
                const p_dup = try allocator.dupe(u8, target_path);
                errdefer allocator.free(p_dup);
                const o_dup = try allocator.dupe(u8, ob);
                errdefer allocator.free(o_dup);
                const t_dup = try allocator.dupe(u8, tb);
                errdefer allocator.free(t_dup);
                try upsertConflict(&conflict_list, allocator, .{
                    .path = p_dup,
                    .kind = .text,
                    .ours = o_dup,
                    .theirs = t_dup,
                });
            } else {
                removeConflictByPath(&conflict_list, allocator, target_path);
                try merged_paths.append(allocator, try allocator.dupe(u8, target_path));
            }
        }

        try self.saveConflictsSlice(conflict_list.items);
        return .{
            .brought = brought,
            .merged = try merged_paths.toOwnedSlice(allocator),
            .conflicts = try conflict_list.toOwnedSlice(allocator),
        };
    }

    pub fn landToOrigin(self: *Space, origin_space: *Space) !SpaceLandReport {
        return try self.landToOriginAlloc(self.allocator, origin_space);
    }

    pub fn landToOriginAlloc(self: *Space, allocator: Allocator, origin_space: *Space) !SpaceLandReport {
        if (self.history.history_id != origin_space.history.history_id) {
            return error.HistoryNotShared;
        }
        var sync_rep = try self.syncFromOriginAlloc(allocator, origin_space);
        errdefer sync_rep.deinit(allocator);
        if (sync_rep.conflicts.len > 0) {
            return error.UnresolvedConflicts;
        }

        const outgoing = try self.exportMissing(self.allocator, &origin_space.history.dag);
        defer {
            for (outgoing) |*b| b.deinit(self.allocator);
            self.allocator.free(outgoing);
        }

        var landed: usize = 0;
        for (outgoing) |*b| {
            if (try origin_space.commitBatch(b)) {
                landed += 1;
            }
        }
        return .{ .sync = sync_rep, .landed = landed };
    }

    fn sealCurrentWalIntoSegments(self: *Space, wal_dir: Io.Dir) !u32 {
        if (self.batch_log.count() == 0) return self.manifest.seg_max_id;
        var wal_buf: [32]u8 = undefined;
        const wal_name = manifest_mod.walFileName(self.manifest.wal_gen, &wal_buf);
        const new_seg_id = self.manifest.seg_max_id + 1;
        const written = try self.segments.sealFromWal(wal_dir, wal_name, new_seg_id);
        defer self.allocator.free(written);

        var mf_opt: ?*mmap.MappedFile = null;
        if (written.len > 0) {
            mf_opt = try self.segments.getMapped(new_seg_id);
        }
        if (mf_opt) |mf| {
            for (written) |wf| {
                if (wf.kind != FRAME_BATCH) continue;
                const payload = mf.sliceCheckedU64(wf.offset + log_mod.HEADER_SIZE, wf.payload_len) catch continue;
                var r = codec.Reader.init(payload);
                var hdr = dag_mod.BatchHeader.decode(self.allocator, &r) catch continue;
                defer hdr.deinit(self.allocator);
                try self.history.dag.setBatchLocation(self.allocator, hdr.batchId(), .{
                    .seg_id = new_seg_id,
                    .offset = wf.offset,
                    .len = wf.payload_len,
                });
            }
        }
        return new_seg_id;
    }

    pub fn checkpoint(self: *Space, kind: CheckpointKind) !void {
        if (self.in_checkpoint) return;
        self.in_checkpoint = true;
        defer self.in_checkpoint = false;

        var snap_dir = try self.state_dir.openDir(self.io, "snap", .{ .iterate = true });
        defer snap_dir.close(self.io);
        var wal_dir = try self.state_dir.openDir(self.io, "wal", .{ .iterate = true });
        defer wal_dir.close(self.io);

        const new_seg_max = try self.sealCurrentWalIntoSegments(wal_dir);
        const wal_cutoff_seq: u64 = if (self.batch_log.next_seq > 0) self.batch_log.next_seq - 1 else self.manifest.wal_base_seq;

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
                .scopes_blob = &.{},
                .retained_versions = self.retained_versions.items,
                .synced_version = Version.ROOT,
                .git_head = null,
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

    fn maybeAutoCheckpoint(self: *Space) void {
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

    pub fn compactWithPolicy(self: *Space, policy: CompactPolicy) !CompactStats {
        if (self.in_checkpoint) return .{};
        self.in_checkpoint = true;
        defer self.in_checkpoint = false;

        var stats = CompactStats{};
        var snap_dir = try self.state_dir.openDir(self.io, "snap", .{ .iterate = true });
        defer snap_dir.close(self.io);
        var wal_dir = try self.state_dir.openDir(self.io, "wal", .{ .iterate = true });
        defer wal_dir.close(self.io);

        const sealed_seg_max = try self.sealCurrentWalIntoSegments(wal_dir);
        const wal_cutoff_seq: u64 = if (self.batch_log.next_seq > 0) self.batch_log.next_seq - 1 else self.manifest.wal_base_seq;

        var retained_vers: std.ArrayList(Version) = .empty;
        defer retained_vers.deinit(self.allocator);
        try retained_vers.append(self.allocator, self.history.dag.heads);
        for (self.retained_versions.items) |rv| {
            if (!rv.isEmpty()) try retained_vers.append(self.allocator, rv);
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
                for (all_below.items[0..keep_n]) |item| _ = below.remove(item.bid);
            }

            var bit = below.keyIterator();
            while (bit.next()) |bid| try pruned_set.put(self.allocator, bid.*, {});
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
        var prune_res = try self.segments.pruneSegmentsDeferred(KeepCtx{ .loc_map = &loc_to_bid, .pruned = &pruned_set });
        defer prune_res.deinit(self.allocator);

        stats.removed_segments = prune_res.removed_segments;
        stats.rewritten_segments = prune_res.rewritten_segments;
        stats.pruned_batches = pruned_set.count();

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
                .scopes_blob = &.{},
                .retained_versions = self.retained_versions.items,
                .synced_version = Version.ROOT,
                .git_head = null,
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
        new_manifest.seg_max_id = @max(prune_res.max_seg_id, sealed_seg_max);
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

        self.segments.unlinkSegments(prune_res.obsolete_seg_ids.items);
        const seg_bytes_after = dirTotalBytes(self.io, self.state_dir, "seg");
        stats.reclaimed_batch_bytes = if (seg_bytes_before > seg_bytes_after) seg_bytes_before - seg_bytes_after else 0;

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
                            for (b.blobs) |ba| {
                                try live_oids.put(self.allocator, ba.oid, {});
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

            const new_pack_max = self.blob_store.maxPackId();
            const new_pack_digest = self.blob_store.packIdxDigest();
            if (new_pack_max != new_manifest.pack_max_id or !std.mem.eql(u8, &new_pack_digest, &new_manifest.pack_idx_blake3)) {
                new_manifest.pack_max_id = new_pack_max;
                new_manifest.pack_idx_blake3 = new_pack_digest;
                new_manifest.saveAtomic(self.io, self.state_dir) catch {};
                mmap.fsyncDir(self.io, self.state_dir) catch {};
            }
        }

        self.manifest = new_manifest;
        manifest_mod.Manifest.gcOrphanFiles(self.allocator, self.io, self.state_dir, self.manifest);
        return stats;
    }

    fn replayLogAfterSeq(self: *Space, cutoff_seq: u64) !void {
        const n = self.batch_log.count();
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);

        for (0..n) |i| {
            const entry = self.batch_log.index.items[i];
            if (entry.seq <= cutoff_seq) continue;
            if (entry.kind != FRAME_BATCH) continue;
            const frame = try self.batch_log.readAt(i);
            op_spans.clearRetainingCapacity();
            blob_spans.clearRetainingCapacity();
            var r = codec.Reader.init(frame.payload);
            var batch = try op_mod.Batch.decodeWithSpans(self.allocator, &r, &op_spans, &blob_spans);
            defer batch.deinit(self.allocator);
            const applied = try self.history.integrate(&batch);
            if (applied) {
                const payload_off = entry.offset + log_mod.HEADER_SIZE;
                self.history.pinBatchToLog(&batch, payload_off, op_spans.items, blob_spans.items);
            }
            try self.batch_log_idx.put(self.allocator, batch.header.batchId(), i);
        }
    }

    fn appendCreateFileOp(
        self: *Space,
        parent_iid: id.InodeId,
        base_name: []const u8,
        bytes: []const u8,
        mode: tree_mod.FileMode,
        ending_opt: ?tree_mod.LineEnding,
        is_bin: bool,
        ops: *std.ArrayList(op_mod.Op),
        blobs: *std.ArrayList(op_mod.BlobAttachment),
    ) !void {
        if (is_bin) {
            const oid = id.hashBytes(bytes);
            try blobs.append(self.allocator, .{ .oid = oid, .data = try self.allocator.dupe(u8, bytes) });
            try ops.append(self.allocator, .{ .create_file = .{
                .parent = parent_iid,
                .name = try self.allocator.dupe(u8, base_name),
                .mode = mode,
                .line_ending = .lf,
                .content = .{ .binary = .{ .oid = oid, .len = bytes.len } },
            } });
        } else {
            const ending = ending_opt orelse detectLineEnding(bytes);
            const normalized = try normalizeToLf(self.allocator, bytes);
            defer self.allocator.free(normalized);
            const cm = try op_mod.makeTextContent(self.allocator, normalized);
            if (cm[1]) |att| try blobs.append(self.allocator, att);
            try ops.append(self.allocator, .{ .create_file = .{
                .parent = parent_iid,
                .name = try self.allocator.dupe(u8, base_name),
                .mode = mode,
                .line_ending = ending,
                .content = cm[0],
            } });
        }
    }

    fn ensureParentDirs(
        self: *Space,
        actor: id.ActorId,
        base_start_ts: id.Lamport,
        rel_path: []const u8,
        ops: *std.ArrayList(op_mod.Op),
        pending_dirs: *std.StringHashMapUnmanaged(id.InodeId),
    ) !id.InodeId {
        const dir_part = std.fs.path.dirname(rel_path) orelse return id.InodeId.ROOT;
        if (dir_part.len == 0 or std.mem.eql(u8, dir_part, ".")) return id.InodeId.ROOT;

        var cur_parent = id.InodeId.ROOT;
        var prefix_buf: std.ArrayList(u8) = .empty;
        defer prefix_buf.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, dir_part, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (prefix_buf.items.len > 0) try prefix_buf.append(self.allocator, '/');
            try prefix_buf.appendSlice(self.allocator, seg);

            if (pending_dirs.get(prefix_buf.items)) |pid| {
                cur_parent = pid;
                continue;
            }
            if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, prefix_buf.items)) |existing_id| {
                self.history.tree.beginPinScope();
                const is_dir = if (self.history.tree.get(existing_id)) |in| in.isDir() else false;
                self.history.tree.endPinScope();
                if (is_dir) {
                    cur_parent = existing_id;
                    continue;
                }
                try ops.append(self.allocator, .{ .remove = .{ .inode = existing_id } });
            }

            const op_idx = ops.items.len;
            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(op_idx)), actor), 0);
            try ops.append(self.allocator, .{ .create_dir = .{
                .parent = cur_parent,
                .name = try self.allocator.dupe(u8, seg),
            } });
            try pending_dirs.put(self.allocator, try self.allocator.dupe(u8, prefix_buf.items), new_iid);
            cur_parent = new_iid;
        }
        return cur_parent;
    }

    fn commitOpsList(
        self: *Space,
        actor: id.ActorId,
        start_ts: id.Lamport,
        parents: *const Version,
        ops: *std.ArrayList(op_mod.Op),
        blobs: *std.ArrayList(op_mod.BlobAttachment),
    ) !id.BatchId {
        if (ops.items.len == 0) {
            const heads = self.history.dag.heads.slice();
            return if (heads.len > 0) heads[0] else id.OpId.ZERO;
        }
        const batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = start_ts,
                .end = start_ts + @as(u64, @intCast(ops.items.len)) - 1,
                .parents = parents.*,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = ops.items,
            .blobs = blobs.items,
        };
        _ = try self.commitBatch(&batch);
        return batch.header.batchId();
    }

    fn removeInodeDirect(self: *Space, iid: id.InodeId) !void {
        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const start_ts = self.history.nextStartTs(&parents);
        var ops_arr = [_]op_mod.Op{.{ .remove = .{ .inode = iid } }};
        const batch = op_mod.Batch{
            .header = .{
                .actor = self.actor_id,
                .start = start_ts,
                .end = start_ts,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = &ops_arr,
            .blobs = &.{},
        };
        _ = try self.commitBatch(&batch);
    }

    fn loadConflictsList(self: *Space, allocator: Allocator) !std.ArrayList(SpaceConflict) {
        var out: std.ArrayList(SpaceConflict) = .empty;
        errdefer {
            for (out.items) |*c| c.deinit(allocator);
            out.deinit(allocator);
        }

        var fl = try FileFlock.acquireBlocking(self.io, self.state_dir, "conflicts.0ndb.lock");
        defer fl.release(self.io);

        const f = self.state_dir.openFile(self.io, "conflicts.0ndb", .{}) catch |err| switch (err) {
            error.FileNotFound => return out,
            else => return err,
        };
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size == 0) return out;
        const buf = try allocator.alloc(u8, @intCast(st.size));
        defer allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n < 8) return out;

        var r = codec.Reader.init(buf[0..n]);
        const magic = r.readU32() catch return out;
        if (magic != CONFLICTS_MAGIC) return out;
        const count = r.readCount(1, 65536) catch return out;
        for (0..count) |_| {
            const path = try r.readBytesAlloc(allocator);
            errdefer allocator.free(path);
            const kind_b = try r.readByte();
            const kind: SpaceConflictKind = switch (kind_b) {
                1 => .text,
                2 => .binary,
                3 => .deleted_here,
                4 => .deleted_there,
                else => return error.InvalidData,
            };
            const ours = try r.readOptBytesAlloc(allocator);
            errdefer if (ours) |b| allocator.free(b);
            const theirs = try r.readOptBytesAlloc(allocator);
            try out.append(allocator, .{ .path = path, .kind = kind, .ours = ours, .theirs = theirs });
        }
        return out;
    }

    fn saveConflictsSlice(self: *Space, items: []const SpaceConflict) !void {
        var fl = try FileFlock.acquireBlocking(self.io, self.state_dir, "conflicts.0ndb.lock");
        defer fl.release(self.io);

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, CONFLICTS_MAGIC);
        try w.writeVarint(self.allocator, items.len);
        for (items) |c| {
            try w.writeBytes(self.allocator, c.path);
            try w.writeByte(self.allocator, @backingInt(c.kind));
            try w.writeOptBytes(self.allocator, c.ours);
            try w.writeOptBytes(self.allocator, c.theirs);
        }
        try mmap.atomicWriteFile(self.io, self.state_dir, "conflicts.0ndb", w.items());
    }
};

fn loadOrigin(allocator: Allocator, io: Io, state_dir: Io.Dir) !?SpaceOrigin {
    const f = state_dir.openFile(io, "origin.0ndb", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io);
    const st = try f.stat(io);
    if (st.size < 8) return null;
    const buf = try allocator.alloc(u8, @intCast(st.size));
    defer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    var r = codec.Reader.init(buf[0..n]);
    const magic = r.readU32() catch return null;
    if (magic != ORIGIN_MAGIC) return null;
    return SpaceOrigin.decode(allocator, &r) catch return null;
}

fn saveOrigin(allocator: Allocator, io: Io, state_dir: Io.Dir, orig: *const SpaceOrigin) !void {
    var w = codec.Writer{};
    defer w.deinit(allocator);
    try w.writeU32(allocator, ORIGIN_MAGIC);
    try orig.encode(allocator, &w);
    try mmap.atomicWriteFile(io, state_dir, "origin.0ndb", w.items());
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

fn linkOrCopyDirFiles(allocator: Allocator, io: Io, src_parent: Io.Dir, dst_parent: Io.Dir, sub: []const u8) !void {
    var src_d = src_parent.openDir(io, sub, .{ .iterate = true }) catch return;
    defer src_d.close(io);
    try dst_parent.createDirPath(io, sub);
    var dst_d = try dst_parent.openDir(io, sub, .{ .iterate = true });
    defer dst_d.close(io);

    var it = src_d.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "tmp.")) continue;
        switch (entry.kind) {
            .file => try linkOrCopyFile(allocator, io, src_d, dst_d, entry.name),
            .directory => try linkOrCopyDirFiles(allocator, io, src_d, dst_d, entry.name),
            else => {},
        }
    }
    mmap.fsyncDir(io, dst_d) catch {};
}

fn linkOrCopyFile(allocator: Allocator, io: Io, src_dir: Io.Dir, dst_dir: Io.Dir, name: []const u8) !void {
    if (builtin.os.tag == .linux and name.len < 255) {
        var name_z: [256]u8 = undefined;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        const rc = linux.linkat(src_dir.handle, @ptrCast(&name_z), dst_dir.handle, @ptrCast(&name_z), 0);
        if (linux.errno(rc) == .SUCCESS) return;
    }
    const sf = try src_dir.openFile(io, name, .{});
    defer sf.close(io);
    const st = try sf.stat(io);
    const buf = try allocator.alloc(u8, @intCast(st.size));
    defer allocator.free(buf);
    const n = try sf.readPositionalAll(io, buf, 0);
    try mmap.atomicWriteFile(io, dst_dir, name, buf[0..n]);
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

fn trimRelPath(p: []const u8) []const u8 {
    var s = std.mem.trim(u8, p, "/");
    while (std.mem.startsWith(u8, s, "./")) {
        s = s[2..];
        s = std.mem.trimStart(u8, s, "/");
    }
    return s;
}

fn freeStringMapKeys(allocator: Allocator, m: anytype) void {
    var it = m.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    m.deinit(allocator);
}

pub fn isBinaryBytes(data: []const u8) bool {
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

pub fn detectLineEnding(data: []const u8) tree_mod.LineEnding {
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

pub fn normalizeToLf(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
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

pub fn hasConflictMarkers(bytes: []const u8) bool {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (std.mem.startsWith(u8, line, "<<<<<<< ") or
            std.mem.startsWith(u8, line, "||||||| ") or
            std.mem.eql(u8, line, "=======") or
            std.mem.startsWith(u8, line, ">>>>>>> "))
        {
            return true;
        }
    }
    return false;
}

fn optBytesEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

const FileMeta = struct {
    mode: tree_mod.FileMode = .regular,
    ending: tree_mod.LineEnding = .lf,
};

fn resolveFileMeta(sp: *const Space, iid: id.InodeId, view: text_mod.View) FileMeta {
    sp.history.tree.beginPinScope();
    defer sp.history.tree.endPinScope();
    const inode = sp.history.tree.get(iid) orelse return .{};
    const f = inode.fileConstPtr() orelse return .{};
    const m = if (f.mode.getIn(view)) |mv| mv.* else tree_mod.FileMode.regular;
    const e = if (f.line_ending.getIn(view)) |ev| ev.* else tree_mod.LineEnding.lf;
    return .{ .mode = m, .ending = e };
}

fn mergeMode(base: tree_mod.FileMode, ours: tree_mod.FileMode, theirs: tree_mod.FileMode) tree_mod.FileMode {
    if (ours == theirs) return ours;
    if (ours == base) return theirs;
    if (theirs == base) return ours;
    return ours;
}

fn mergeEnding(base: tree_mod.LineEnding, ours: tree_mod.LineEnding, theirs: tree_mod.LineEnding) tree_mod.LineEnding {
    if (ours == theirs) return ours;
    if (ours == base) return theirs;
    if (theirs == base) return ours;
    return ours;
}

fn removeConflictByPath(list: *std.ArrayList(SpaceConflict), allocator: Allocator, path: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].path, path)) {
            var rem = list.orderedRemove(i);
            rem.deinit(allocator);
        } else {
            i += 1;
        }
    }
}

fn upsertConflict(list: *std.ArrayList(SpaceConflict), allocator: Allocator, item: SpaceConflict) !void {
    removeConflictByPath(list, allocator, item.path);
    try list.append(allocator, item);
}

const LineHunk = struct {
    base_start: usize,
    base_end: usize,
    target_start: usize,
    target_end: usize,
};

fn splitLinesKeepNewline(allocator: Allocator, bytes: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |nl| {
            try out.append(allocator, bytes[pos .. nl + 1]);
            pos = nl + 1;
        } else {
            try out.append(allocator, bytes[pos..]);
            pos = bytes.len;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn appendLinesSlice(allocator: Allocator, out: *std.ArrayList(u8), lines: []const []const u8) !void {
    for (lines) |l| try out.appendSlice(allocator, l);
}

fn computeLineHunks(allocator: Allocator, base: []const []const u8, target: []const []const u8) ![]LineHunk {
    var hunks: std.ArrayList(LineHunk) = .empty;
    errdefer hunks.deinit(allocator);

    var prefix: usize = 0;
    while (prefix < base.len and prefix < target.len and std.mem.eql(u8, base[prefix], target[prefix])) {
        prefix += 1;
    }
    var suffix: usize = 0;
    while (prefix + suffix < base.len and prefix + suffix < target.len and
        std.mem.eql(u8, base[base.len - 1 - suffix], target[target.len - 1 - suffix]))
    {
        suffix += 1;
    }

    const nb = base.len - prefix - suffix;
    const nt = target.len - prefix - suffix;
    if (nb == 0 and nt == 0) return try hunks.toOwnedSlice(allocator);

    if (nb == 0 or nt == 0 or nb * nt > 1_000_000) {
        try hunks.append(allocator, .{
            .base_start = prefix,
            .base_end = base.len - suffix,
            .target_start = prefix,
            .target_end = target.len - suffix,
        });
        return try hunks.toOwnedSlice(allocator);
    }

    const cols = nt + 1;
    const dp = try allocator.alloc(u32, (nb + 1) * cols);
    defer allocator.free(dp);
    @memset(dp, 0);

    var i: usize = nb;
    while (i > 0) {
        i -= 1;
        var j: usize = nt;
        while (j > 0) {
            j -= 1;
            const idx = i * cols + j;
            if (std.mem.eql(u8, base[prefix + i], target[prefix + j])) {
                dp[idx] = dp[(i + 1) * cols + (j + 1)] + 1;
            } else {
                dp[idx] = @max(dp[(i + 1) * cols + j], dp[i * cols + (j + 1)]);
            }
        }
    }

    var bi: usize = 0;
    var ti: usize = 0;
    var in_hunk = false;
    var hs_b: usize = 0;
    var hs_t: usize = 0;

    while (bi < nb or ti < nt) {
        if (bi < nb and ti < nt and std.mem.eql(u8, base[prefix + bi], target[prefix + ti])) {
            if (in_hunk) {
                try hunks.append(allocator, .{
                    .base_start = prefix + hs_b,
                    .base_end = prefix + bi,
                    .target_start = prefix + hs_t,
                    .target_end = prefix + ti,
                });
                in_hunk = false;
            }
            bi += 1;
            ti += 1;
        } else {
            if (!in_hunk) {
                hs_b = bi;
                hs_t = ti;
                in_hunk = true;
            }
            if (bi < nb and (ti == nt or dp[(bi + 1) * cols + ti] >= dp[bi * cols + (ti + 1)])) {
                bi += 1;
            } else {
                ti += 1;
            }
        }
    }
    if (in_hunk) {
        try hunks.append(allocator, .{
            .base_start = prefix + hs_b,
            .base_end = prefix + bi,
            .target_start = prefix + hs_t,
            .target_end = prefix + ti,
        });
    }
    return try hunks.toOwnedSlice(allocator);
}

fn hunksOverlap(a: LineHunk, b: LineHunk) bool {
    if (a.base_start == a.base_end and b.base_start == b.base_end) {
        return a.base_start == b.base_start;
    }
    if (a.base_start == a.base_end) {
        return a.base_start >= b.base_start and a.base_start <= b.base_end;
    }
    if (b.base_start == b.base_end) {
        return b.base_start >= a.base_start and b.base_start <= a.base_end;
    }
    return a.base_start < b.base_end and b.base_start < a.base_end;
}

pub fn merge3LinesDiff3(
    allocator: Allocator,
    base_bytes: []const u8,
    ours_bytes: []const u8,
    theirs_bytes: []const u8,
) !struct { output: []u8, has_conflict: bool } {
    if (std.mem.eql(u8, ours_bytes, theirs_bytes)) {
        return .{ .output = try allocator.dupe(u8, ours_bytes), .has_conflict = false };
    }
    if (std.mem.eql(u8, ours_bytes, base_bytes)) {
        return .{ .output = try allocator.dupe(u8, theirs_bytes), .has_conflict = false };
    }
    if (std.mem.eql(u8, theirs_bytes, base_bytes)) {
        return .{ .output = try allocator.dupe(u8, ours_bytes), .has_conflict = false };
    }

    const base = try splitLinesKeepNewline(allocator, base_bytes);
    defer allocator.free(base);
    const ours = try splitLinesKeepNewline(allocator, ours_bytes);
    defer allocator.free(ours);
    const theirs = try splitLinesKeepNewline(allocator, theirs_bytes);
    defer allocator.free(theirs);

    const oh = try computeLineHunks(allocator, base, ours);
    defer allocator.free(oh);
    const th = try computeLineHunks(allocator, base, theirs);
    defer allocator.free(th);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var has_conflict = false;

    var base_pos: usize = 0;
    var oi: usize = 0;
    var ti: usize = 0;

    while (oi < oh.len or ti < th.len) {
        if (ti >= th.len) {
            const h = oh[oi];
            try appendLinesSlice(allocator, &out, base[base_pos..h.base_start]);
            try appendLinesSlice(allocator, &out, ours[h.target_start..h.target_end]);
            base_pos = h.base_end;
            oi += 1;
            continue;
        }
        if (oi >= oh.len) {
            const h = th[ti];
            try appendLinesSlice(allocator, &out, base[base_pos..h.base_start]);
            try appendLinesSlice(allocator, &out, theirs[h.target_start..h.target_end]);
            base_pos = h.base_end;
            ti += 1;
            continue;
        }

        const ho = oh[oi];
        const ht = th[ti];
        if (!hunksOverlap(ho, ht)) {
            if (ho.base_end <= ht.base_start and (ho.base_start < ht.base_start or ho.base_end < ht.base_end)) {
                try appendLinesSlice(allocator, &out, base[base_pos..ho.base_start]);
                try appendLinesSlice(allocator, &out, ours[ho.target_start..ho.target_end]);
                base_pos = ho.base_end;
                oi += 1;
                continue;
            }
            if (ht.base_end <= ho.base_start and (ht.base_start < ho.base_start or ht.base_end < ho.base_end)) {
                try appendLinesSlice(allocator, &out, base[base_pos..ht.base_start]);
                try appendLinesSlice(allocator, &out, theirs[ht.target_start..ht.target_end]);
                base_pos = ht.base_end;
                ti += 1;
                continue;
            }
        }

        const c_start = @min(ho.base_start, ht.base_start);
        var c_end = @max(ho.base_end, ht.base_end);
        const o_first = oi;
        const t_first = ti;
        oi += 1;
        ti += 1;
        var grew = true;
        while (grew) {
            grew = false;
            while (oi < oh.len and oh[oi].base_start <= c_end) {
                if (oh[oi].base_end > c_end) {
                    c_end = oh[oi].base_end;
                    grew = true;
                }
                oi += 1;
            }
            while (ti < th.len and th[ti].base_start <= c_end) {
                if (th[ti].base_end > c_end) {
                    c_end = th[ti].base_end;
                    grew = true;
                }
                ti += 1;
            }
        }

        try appendLinesSlice(allocator, &out, base[base_pos..c_start]);

        var b_buf: std.ArrayList(u8) = .empty;
        defer b_buf.deinit(allocator);
        try appendLinesSlice(allocator, &b_buf, base[c_start..c_end]);

        var o_buf: std.ArrayList(u8) = .empty;
        defer o_buf.deinit(allocator);
        {
            var p = c_start;
            for (oh[o_first..oi]) |h| {
                try appendLinesSlice(allocator, &o_buf, base[p..h.base_start]);
                try appendLinesSlice(allocator, &o_buf, ours[h.target_start..h.target_end]);
                p = h.base_end;
            }
            try appendLinesSlice(allocator, &o_buf, base[p..c_end]);
        }

        var t_buf: std.ArrayList(u8) = .empty;
        defer t_buf.deinit(allocator);
        {
            var p = c_start;
            for (th[t_first..ti]) |h| {
                try appendLinesSlice(allocator, &t_buf, base[p..h.base_start]);
                try appendLinesSlice(allocator, &t_buf, theirs[h.target_start..h.target_end]);
                p = h.base_end;
            }
            try appendLinesSlice(allocator, &t_buf, base[p..c_end]);
        }

        if (std.mem.eql(u8, o_buf.items, t_buf.items)) {
            try out.appendSlice(allocator, o_buf.items);
        } else {
            has_conflict = true;
            try out.appendSlice(allocator, "<<<<<<< ours\n");
            try out.appendSlice(allocator, o_buf.items);
            if (o_buf.items.len > 0 and o_buf.items[o_buf.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, "||||||| base\n");
            try out.appendSlice(allocator, b_buf.items);
            if (b_buf.items.len > 0 and b_buf.items[b_buf.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, "=======\n");
            try out.appendSlice(allocator, t_buf.items);
            if (t_buf.items.len > 0 and t_buf.items[t_buf.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, ">>>>>>> theirs\n");
        }
        base_pos = c_end;
    }

    try appendLinesSlice(allocator, &out, base[base_pos..]);
    return .{ .output = try out.toOwnedSlice(allocator), .has_conflict = has_conflict };
}
