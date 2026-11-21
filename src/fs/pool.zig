const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const blobs = @import("../store/blobs.zig");
const git_dirs = @import("git_dirs.zig");
const git_odb = @import("git_odb.zig");
const watch = @import("watch.zig");

pub const MemoryBudget = struct {
    shared_blob_bytes: usize = 32 * 1024 * 1024,
    shared_git_delta_bytes: usize = 8 * 1024 * 1024,
    active_workspaces_bytes: usize = 128 * 1024 * 1024,
    max_hot_worktrees: u32 = 6,
    idle_hibernate_ms: u64 = 3_000,
    max_inotify_watches: usize = 0,
};

pub const MemoryGovernor = struct {
    pub const Stats = struct {
        blob_bytes: usize,
        git_delta_bytes: usize,
        workspace_bytes: usize,
        hot_count: u32,
        watch_count: usize,
        budget: MemoryBudget,
    };

    budget: MemoryBudget,
    blob_bytes: std.atomic.Value(usize),
    git_delta_bytes: std.atomic.Value(usize),
    workspace_bytes: std.atomic.Value(usize),
    hot_count: std.atomic.Value(u32),
    watch_count: std.atomic.Value(usize),

    pub fn init(budget: MemoryBudget) MemoryGovernor {
        return .{
            .budget = budget,
            .blob_bytes = .init(0),
            .git_delta_bytes = .init(0),
            .workspace_bytes = .init(0),
            .hot_count = .init(0),
            .watch_count = .init(0),
        };
    }

    pub fn addWorkspaceBytes(self: *MemoryGovernor, delta: usize) void {
        if (delta == 0) return;
        var cur = self.workspace_bytes.load(.monotonic);
        while (true) {
            const next = cur +| delta;
            if (self.workspace_bytes.cmpxchgWeak(cur, next, .acq_rel, .monotonic)) |actual| {
                cur = actual;
            } else {
                return;
            }
        }
    }

    pub fn subWorkspaceBytes(self: *MemoryGovernor, delta: usize) void {
        if (delta == 0) return;
        var cur = self.workspace_bytes.load(.monotonic);
        while (true) {
            const next = cur -| delta;
            if (self.workspace_bytes.cmpxchgWeak(cur, next, .acq_rel, .monotonic)) |actual| {
                cur = actual;
            } else {
                return;
            }
        }
    }

    pub fn incHot(self: *MemoryGovernor) void {
        var cur = self.hot_count.load(.monotonic);
        while (true) {
            const next = cur +| 1;
            if (self.hot_count.cmpxchgWeak(cur, next, .acq_rel, .monotonic)) |actual| {
                cur = actual;
            } else {
                return;
            }
        }
    }

    pub fn decHot(self: *MemoryGovernor) void {
        var cur = self.hot_count.load(.monotonic);
        while (true) {
            const next = cur -| 1;
            if (self.hot_count.cmpxchgWeak(cur, next, .acq_rel, .monotonic)) |actual| {
                cur = actual;
            } else {
                return;
            }
        }
    }

    pub fn setBlobBytes(self: *MemoryGovernor, bytes: usize) void {
        self.blob_bytes.store(bytes, .release);
    }

    pub fn setGitDeltaBytes(self: *MemoryGovernor, bytes: usize) void {
        self.git_delta_bytes.store(bytes, .release);
    }

    pub fn setWatchCount(self: *MemoryGovernor, count: usize) void {
        self.watch_count.store(count, .release);
    }

    pub fn needsWorkspaceEviction(self: *const MemoryGovernor, incoming_est: usize) bool {
        const cur_hot = self.hot_count.load(.acquire);
        if (self.budget.max_hot_worktrees > 0 and cur_hot >= self.budget.max_hot_worktrees) {
            return true;
        }
        const cur_bytes = self.workspace_bytes.load(.acquire);
        if (self.budget.active_workspaces_bytes > 0 and (cur_bytes +| incoming_est) > self.budget.active_workspaces_bytes) {
            return true;
        }
        return false;
    }

    pub fn snapshot(self: *const MemoryGovernor) Stats {
        return .{
            .blob_bytes = self.blob_bytes.load(.acquire),
            .git_delta_bytes = self.git_delta_bytes.load(.acquire),
            .workspace_bytes = self.workspace_bytes.load(.acquire),
            .hot_count = self.hot_count.load(.acquire),
            .watch_count = self.watch_count.load(.acquire),
            .budget = self.budget,
        };
    }
};

const GitOdbPoolEntry = struct {
    odb: *git_odb.GitOdb,
    map_refs: usize,
};

pub const DaemonResources = struct {
    allocator: Allocator,
    io: Io,
    state_dir_path: []u8,
    governor: MemoryGovernor,
    blob_pool: *blobs.SharedBlobPool,
    git_odbs_mu: Io.Mutex,
    git_odbs: std.StringHashMapUnmanaged(GitOdbPoolEntry),
    watcher_mu: Io.Mutex,
    watcher: ?*watch.DaemonWatcher,

    pub fn init(
        allocator: Allocator,
        io: Io,
        state_dir_path: []const u8,
        budget: MemoryBudget,
    ) !*DaemonResources {
        try Io.Dir.cwd().createDirPath(io, state_dir_path);
        var state_dir = try Io.Dir.cwd().openDir(io, state_dir_path, .{ .iterate = true });
        defer state_dir.close(io);

        const path_copy = try allocator.dupe(u8, state_dir_path);
        errdefer allocator.free(path_copy);

        const blob_pool = try blobs.SharedBlobPool.open(
            allocator,
            io,
            state_dir,
            "blobs",
            budget.shared_blob_bytes,
        );
        errdefer blob_pool.release();

        const self = try allocator.create(DaemonResources);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .state_dir_path = path_copy,
            .governor = MemoryGovernor.init(budget),
            .blob_pool = blob_pool,
            .git_odbs_mu = .init,
            .git_odbs = .empty,
            .watcher_mu = .init,
            .watcher = null,
        };
        return self;
    }

    pub fn deinit(self: *DaemonResources) void {
        const alloc = self.allocator;

        if (self.watcher) |w| {
            w.deinit();
            alloc.destroy(w);
            self.watcher = null;
        }

        var it = self.git_odbs.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            var n: usize = 0;
            while (n < entry.value_ptr.map_refs) : (n += 1) {
                entry.value_ptr.odb.release();
            }
        }
        self.git_odbs.deinit(alloc);

        self.blob_pool.release();
        alloc.free(self.state_dir_path);
        alloc.destroy(self);
    }

    fn canonicalizePath(io: Io, path: []const u8, buf: *[std.fs.max_path_bytes]u8) []const u8 {
        if (Io.Dir.cwd().realPathFile(io, path, buf)) |n| {
            return buf[0..n];
        } else |_| {
            return path;
        }
    }

    pub fn acquireGitOdb(
        self: *DaemonResources,
        common_dir_path: []const u8,
        format: git_dirs.ObjectFormat,
        pin_ref: ?[]const u8,
    ) !*git_odb.GitOdb {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon = canonicalizePath(self.io, common_dir_path, &real_buf);

        self.git_odbs_mu.lockUncancelable(self.io);
        defer self.git_odbs_mu.unlock(self.io);

        if (self.git_odbs.getPtr(canon)) |existing| {
            existing.map_refs += 1;
            existing.odb.retain();
            return existing.odb;
        }

        const odb = try git_odb.GitOdb.open(self.allocator, self.io, canon, format, pin_ref);
        var odb_owned = true;
        errdefer if (odb_owned) odb.release();

        if (self.governor.budget.shared_git_delta_bytes > 0) {
            odb.delta_cache.budget = self.governor.budget.shared_git_delta_bytes;
        }

        const key = try self.allocator.dupe(u8, canon);
        var key_owned = true;
        errdefer if (key_owned) self.allocator.free(key);

        try self.git_odbs.put(self.allocator, key, .{ .odb = odb, .map_refs = 1 });
        odb_owned = false;
        key_owned = false;
        return odb;
    }

    pub fn releaseGitOdb(self: *DaemonResources, common_dir_path: []const u8) void {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon = canonicalizePath(self.io, common_dir_path, &real_buf);

        var to_release: ?*git_odb.GitOdb = null;
        {
            self.git_odbs_mu.lockUncancelable(self.io);
            defer self.git_odbs_mu.unlock(self.io);

            const lookup_key = if (self.git_odbs.contains(canon))
                canon
            else if (self.git_odbs.contains(common_dir_path))
                common_dir_path
            else
                return;

            const entry = self.git_odbs.getPtr(lookup_key).?;
            to_release = entry.odb;
            if (entry.map_refs <= 1) {
                if (self.git_odbs.fetchRemove(lookup_key)) |kv| {
                    self.allocator.free(kv.key);
                }
            } else {
                entry.map_refs -= 1;
            }
        }

        if (to_release) |odb| {
            odb.release();
        }
    }

    pub fn gitOdbCount(self: *DaemonResources) usize {
        self.git_odbs_mu.lockUncancelable(self.io);
        defer self.git_odbs_mu.unlock(self.io);
        return self.git_odbs.count();
    }

    pub fn ensureWatcher(self: *DaemonResources) !*watch.DaemonWatcher {
        self.watcher_mu.lockUncancelable(self.io);
        defer self.watcher_mu.unlock(self.io);

        if (self.watcher) |w| return w;

        const w = try self.allocator.create(watch.DaemonWatcher);
        errdefer self.allocator.destroy(w);

        w.* = if (self.governor.budget.max_inotify_watches > 0)
            try watch.DaemonWatcher.initWithBudget(self.allocator, self.governor.budget.max_inotify_watches)
        else
            try watch.DaemonWatcher.init(self.allocator);

        self.watcher = w;
        return w;
    }

    pub fn refreshGovernorStats(self: *DaemonResources) void {
        self.governor.setBlobBytes(self.blob_pool.cacheUsedBytes());

        var total_delta: usize = 0;
        {
            self.git_odbs_mu.lockUncancelable(self.io);
            defer self.git_odbs_mu.unlock(self.io);
            var it = self.git_odbs.valueIterator();
            while (it.next()) |entry_ptr| {
                const odb = entry_ptr.odb;
                odb.lock();
                total_delta += odb.delta_cache.used;
                odb.unlock();
            }
        }
        self.governor.setGitDeltaBytes(total_delta);

        var watches: usize = 0;
        {
            self.watcher_mu.lockUncancelable(self.io);
            defer self.watcher_mu.unlock(self.io);
            if (self.watcher) |w| {
                watches = w.activeWatches();
            }
        }
        self.governor.setWatchCount(watches);
    }

    pub fn hibernateAllShared(self: *DaemonResources) void {
        self.blob_pool.hibernate();

        {
            self.git_odbs_mu.lockUncancelable(self.io);
            defer self.git_odbs_mu.unlock(self.io);
            var it = self.git_odbs.valueIterator();
            while (it.next()) |odb_ptr| {
                odb_ptr.odb.hibernate();
            }
        }

        self.governor.setBlobBytes(0);
        self.governor.setGitDeltaBytes(0);
    }
};
