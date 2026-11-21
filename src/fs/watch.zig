const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;

pub const DEFAULT_IGNORES = [_][]const u8{
    ".git",
    ".jj",
    ".0ndb",
    "node_modules",
    "target",
    ".venv",
    "__pycache__",
    ".zig-cache",
    "zig-out",
    "dist",
    "build",
    ".next",
    ".DS_Store",
};

pub const WATCH_MASK: u32 = linux.IN.CLOSE_WRITE |
    linux.IN.MOVED_FROM |
    linux.IN.MOVED_TO |
    linux.IN.CREATE |
    linux.IN.DELETE |
    linux.IN.ATTRIB |
    linux.IN.DELETE_SELF |
    linux.IN.MOVE_SELF;

pub const FENCE_MASK: u32 = linux.IN.CREATE |
    linux.IN.CLOSE_WRITE |
    linux.IN.MOVED_TO |
    linux.IN.DELETE_SELF;

pub const DEFAULT_DEBOUNCE_MS: u64 = 40;
pub const DEFAULT_MAX_LATENCY_MS: u64 = 200;
pub const MAX_DEFAULT_WATCH_BUDGET: usize = 256_000;
pub const FALLBACK_MAX_USER_WATCHES: usize = 65_536;

pub const WatchMode = enum(u8) {
    none = 0,
    full_inotify = 1,
    stat_on_demand = 2,
};

pub const IgnoreFn = *const fn (ctx: ?*const anyopaque, rel_path: []const u8, is_dir: bool) bool;

pub const IgnoreFilter = struct {
    ctx: ?*const anyopaque = null,
    should_ignore: IgnoreFn,

    pub fn matches(self: IgnoreFilter, rel_path: []const u8, is_dir: bool) bool {
        return self.should_ignore(self.ctx, rel_path, is_dir);
    }
};

pub fn isIgnoredName(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".0ndb-tmp")) return true;
    for (DEFAULT_IGNORES) |ig| {
        if (std.mem.eql(u8, name, ig)) return true;
    }
    return false;
}

pub fn isIgnoredPath(rel_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (isIgnoredName(seg)) return true;
    }
    return false;
}

pub fn readSystemMaxUserWatches() usize {
    const fd_rc = linux.open(
        "/proc/sys/fs/inotify/max_user_watches",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    if (linux.errno(fd_rc) != .SUCCESS) return FALLBACK_MAX_USER_WATCHES;
    const fd: posix.fd_t = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var buf: [64]u8 = undefined;
    const r_rc = linux.read(fd, &buf, buf.len);
    if (linux.errno(r_rc) != .SUCCESS or r_rc == 0) return FALLBACK_MAX_USER_WATCHES;
    const trimmed = std.mem.trim(u8, buf[0..r_rc], " \t\r\n");
    return std.fmt.parseInt(usize, trimmed, 10) catch FALLBACK_MAX_USER_WATCHES;
}

pub fn computeDefaultWatchBudget() usize {
    const limit = readSystemMaxUserWatches();
    const scaled = (limit * 3) / 4;
    const capped = @min(scaled, MAX_DEFAULT_WATCH_BUDGET);
    return if (capped == 0) 1 else capped;
}

pub fn nowMonotonicMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    return sec * 1000 + nsec / 1_000_000;
}

pub const WatchEvent = struct {
    mount_id: u64,
    wd: i32,
    mask: u32,
    name: []u8,
    rel_path: []u8,
    is_dir: bool,
    is_git: bool = false,

    pub fn deinit(self: *WatchEvent, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
    }
};

pub const WaitResult = struct {
    ready: bool = false,
    woken: bool = false,
    timer: bool = false,
};

pub const DrainResult = struct {
    count: usize = 0,
    overflow: bool = false,
};

pub const PollResult = struct {
    count: usize = 0,
    woken: bool = false,
    overflow: bool = false,
    timer: bool = false,
};

pub const DirtyPath = struct {
    rel_path: []u8,
    mask: u32,
    is_dir: bool,

    pub fn deinit(self: *DirtyPath, allocator: Allocator) void {
        allocator.free(self.rel_path);
    }
};

pub const MountBatch = struct {
    mount_id: u64,
    mode: WatchMode,
    overflow: bool = false,
    git_changed: bool = false,
    paths: std.ArrayList(DirtyPath) = .empty,

    pub fn deinit(self: *MountBatch, allocator: Allocator) void {
        for (self.paths.items) |*p| p.deinit(allocator);
        self.paths.deinit(allocator);
    }
};

pub const EventBatchResult = struct {
    batches: std.ArrayList(MountBatch) = .empty,
    woken: bool = false,
    idle_ticked: bool = false,
    timed_out: bool = false,

    pub fn deinit(self: *EventBatchResult, allocator: Allocator) void {
        for (self.batches.items) |*b| b.deinit(allocator);
        self.batches.deinit(allocator);
    }
};

pub const IdleTickFn = *const fn (ctx: ?*anyopaque, watcher: *SharedWatcher, now_ms: u64) void;

pub const IdleTickCallback = struct {
    ctx: ?*anyopaque = null,
    on_tick: IdleTickFn,
};

const DirtyMeta = struct {
    mask: u32,
    is_dir: bool,
};

const WatchEntry = struct {
    mount_idx: u32,
    rel_dir: []u8,

    fn deinit(self: *WatchEntry, allocator: Allocator) void {
        allocator.free(self.rel_dir);
    }
};

const SharedGitWd = struct {
    wd: i32,
    sub_prefix: []u8,

    fn deinit(self: *SharedGitWd, allocator: Allocator) void {
        allocator.free(self.sub_prefix);
    }
};

const SharedGitGroup = struct {
    common_dir: []u8,
    wds: std.ArrayList(SharedGitWd) = .empty,
    subscribers: std.ArrayList(u32) = .empty,

    fn deinit(self: *SharedGitGroup, allocator: Allocator) void {
        allocator.free(self.common_dir);
        for (self.wds.items) |*w| w.deinit(allocator);
        self.wds.deinit(allocator);
        self.subscribers.deinit(allocator);
    }

    fn subPrefixForWd(self: *const SharedGitGroup, wd: i32) []const u8 {
        for (self.wds.items) |w| {
            if (w.wd == wd) return w.sub_prefix;
        }
        return "";
    }
};

const MountState = struct {
    mount_id: u64,
    root_path: []u8,
    mode: WatchMode = .none,
    wd_list: std.ArrayList(i32) = .empty,
    ignore_filter: ?IgnoreFilter = null,
    shared_git_idx: ?u32 = null,
    fence_wd: ?i32 = null,
    fence_dir: ?[]u8 = null,
    expected_fence_seq: u64 = 0,
    fence_observed: bool = false,
    dirty_paths: std.StringHashMapUnmanaged(DirtyMeta) = .empty,
    overflow: bool = false,
    git_changed: bool = false,
    pending: bool = false,
    first_event_ms: u64 = 0,
    last_event_ms: u64 = 0,
    last_activity_ms: u64 = 0,

    fn deinit(self: *MountState, allocator: Allocator) void {
        allocator.free(self.root_path);
        self.wd_list.deinit(allocator);
        if (self.fence_dir) |fd| allocator.free(fd);
        var it = self.dirty_paths.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.dirty_paths.deinit(allocator);
    }

    fn isIgnored(self: *const MountState, rel_path: []const u8, is_dir: bool) bool {
        if (rel_path.len > 0 and isIgnoredPath(rel_path)) return true;
        if (self.ignore_filter) |f| {
            if (rel_path.len > 0 and f.matches(rel_path, is_dir)) return true;
        }
        return false;
    }

    fn markPending(self: *MountState, now_ms: u64) void {
        if (!self.pending) {
            self.pending = true;
            self.first_event_ms = now_ms;
        }
        self.last_event_ms = now_ms;
        self.last_activity_ms = now_ms;
    }

    fn recordDirty(self: *MountState, allocator: Allocator, rel_path: []const u8, mask: u32, is_dir: bool, now_ms: u64) !void {
        self.markPending(now_ms);
        if (rel_path.len == 0) return;
        if (self.dirty_paths.getPtr(rel_path)) |existing| {
            existing.mask |= mask;
            existing.is_dir = existing.is_dir or is_dir;
            return;
        }
        const owned = try allocator.dupe(u8, rel_path);
        errdefer allocator.free(owned);
        try self.dirty_paths.put(allocator, owned, .{
            .mask = mask,
            .is_dir = is_dir,
        });
    }

    fn deadlineMs(self: *const MountState, debounce_ms: u64, max_latency_ms: u64) u64 {
        const quiet = self.last_event_ms +| debounce_ms;
        const cap = self.first_event_ms +| max_latency_ms;
        return @min(quiet, cap);
    }
};

pub const DaemonWatcher = SharedWatcher;

pub const SharedWatcher = struct {
    allocator: Allocator,
    inotify_fd: posix.fd_t,
    epoll_fd: posix.fd_t,
    wake_fd: posix.fd_t,
    timer_fd: posix.fd_t,
    max_watches: usize,
    active_watches: usize = 0,
    debounce_ms: u64 = DEFAULT_DEBOUNCE_MS,
    max_latency_ms: u64 = DEFAULT_MAX_LATENCY_MS,
    idle_tick_ms: u64 = 0,
    next_idle_tick_ms: u64 = 0,
    idle_callback: ?IdleTickCallback = null,
    fence_seq: u64 = 0,
    pending_wake: bool = false,
    watches: std.AutoHashMapUnmanaged(i32, std.ArrayList(WatchEntry)) = .empty,
    mounts: std.ArrayList(?MountState) = .empty,
    free_mount_slots: std.ArrayList(u32) = .empty,
    mount_id_to_idx: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    shared_git_groups: std.ArrayList(?SharedGitGroup) = .empty,
    free_git_slots: std.ArrayList(u32) = .empty,
    shared_git_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    shared_git_watches: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    fence_watches: std.AutoHashMapUnmanaged(i32, std.ArrayList(u32)) = .empty,

    pub fn init(allocator: Allocator) !SharedWatcher {
        return try initWithBudget(allocator, computeDefaultWatchBudget());
    }

    pub fn initWithBudget(allocator: Allocator, max_watches: usize) !SharedWatcher {
        const in_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(in_rc) != .SUCCESS) return error.InotifyInitFailed;
        const in_fd: posix.fd_t = @intCast(in_rc);
        errdefer _ = linux.close(in_fd);

        const wake_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(wake_rc) != .SUCCESS) return error.EventfdInitFailed;
        const wake_fd: posix.fd_t = @intCast(wake_rc);
        errdefer _ = linux.close(wake_fd);

        const timer_rc = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(timer_rc) != .SUCCESS) return error.TimerfdInitFailed;
        const timer_fd: posix.fd_t = @intCast(timer_rc);
        errdefer _ = linux.close(timer_fd);

        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(ep_rc) != .SUCCESS) return error.EpollInitFailed;
        const ep_fd: posix.fd_t = @intCast(ep_rc);
        errdefer _ = linux.close(ep_fd);

        var in_ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = in_fd },
        };
        if (linux.errno(linux.epoll_ctl(ep_fd, linux.EPOLL.CTL_ADD, in_fd, &in_ev)) != .SUCCESS) {
            return error.EpollCtlFailed;
        }

        var wake_ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = wake_fd },
        };
        if (linux.errno(linux.epoll_ctl(ep_fd, linux.EPOLL.CTL_ADD, wake_fd, &wake_ev)) != .SUCCESS) {
            return error.EpollCtlFailed;
        }

        var timer_ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = timer_fd },
        };
        if (linux.errno(linux.epoll_ctl(ep_fd, linux.EPOLL.CTL_ADD, timer_fd, &timer_ev)) != .SUCCESS) {
            return error.EpollCtlFailed;
        }

        return .{
            .allocator = allocator,
            .inotify_fd = in_fd,
            .epoll_fd = ep_fd,
            .wake_fd = wake_fd,
            .timer_fd = timer_fd,
            .max_watches = max_watches,
        };
    }

    pub fn deinit(self: *SharedWatcher) void {
        var wit = self.watches.valueIterator();
        while (wit.next()) |list| {
            for (list.items) |*e| e.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        self.watches.deinit(self.allocator);

        for (self.mounts.items) |*slot| {
            if (slot.*) |*m| {
                m.deinit(self.allocator);
                slot.* = null;
            }
        }
        self.mounts.deinit(self.allocator);
        self.free_mount_slots.deinit(self.allocator);
        self.mount_id_to_idx.deinit(self.allocator);

        self.shared_git_by_path.deinit(self.allocator);
        for (self.shared_git_groups.items) |*slot| {
            if (slot.*) |*g| {
                g.deinit(self.allocator);
                slot.* = null;
            }
        }
        self.shared_git_groups.deinit(self.allocator);
        self.free_git_slots.deinit(self.allocator);
        self.shared_git_watches.deinit(self.allocator);
        var fwit = self.fence_watches.valueIterator();
        while (fwit.next()) |list| list.deinit(self.allocator);
        self.fence_watches.deinit(self.allocator);

        _ = linux.close(self.epoll_fd);
        _ = linux.close(self.timer_fd);
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.inotify_fd);
    }

    pub fn fdCount(self: *const SharedWatcher) usize {
        _ = self;
        return 4;
    }

    pub fn activeWatches(self: *const SharedWatcher) usize {
        return self.active_watches;
    }

    pub fn mountCount(self: *const SharedWatcher) usize {
        return self.mount_id_to_idx.count();
    }

    pub fn sharedGitWatchCount(self: *const SharedWatcher) usize {
        return self.shared_git_watches.count();
    }

    pub fn mountMode(self: *const SharedWatcher, mount_id: u64) WatchMode {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return .none;
        const m = self.mounts.items[idx] orelse return .none;
        return m.mode;
    }

    pub fn isMountOverflow(self: *const SharedWatcher, mount_id: u64) bool {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return false;
        const m = self.mounts.items[idx] orelse return false;
        return m.overflow;
    }

    pub fn mountWatchCount(self: *const SharedWatcher, mount_id: u64) usize {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return 0;
        const m = self.mounts.items[idx] orelse return 0;
        return m.wd_list.items.len;
    }

    pub fn hasPending(self: *const SharedWatcher, mount_id: u64) bool {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return false;
        const m = self.mounts.items[idx] orelse return false;
        return m.pending;
    }

    pub fn setDebounce(self: *SharedWatcher, debounce_ms: u64, max_latency_ms: u64) void {
        self.debounce_ms = debounce_ms;
        self.max_latency_ms = if (max_latency_ms < debounce_ms) debounce_ms else max_latency_ms;
    }

    pub fn setIdleTick(self: *SharedWatcher, interval_ms: u64, callback: ?IdleTickCallback) void {
        self.idle_tick_ms = interval_ms;
        self.idle_callback = callback;
        if (interval_ms > 0) {
            self.next_idle_tick_ms = nowMonotonicMs() + interval_ms;
        } else {
            self.next_idle_tick_ms = 0;
        }
        self.rearmTimer(nowMonotonicMs());
    }

    pub fn wake(self: *const SharedWatcher) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    fn ensureMount(self: *SharedWatcher, mount_id: u64, root_path: []const u8, filter_opt: ?IgnoreFilter, update_filter: bool) !u32 {
        const trimmed_root = std.mem.trimEnd(u8, root_path, "/");
        const norm_root = if (trimmed_root.len == 0 and root_path.len > 0) "/" else trimmed_root;
        if (self.mount_id_to_idx.get(mount_id)) |idx| {
            var m = &(self.mounts.items[idx].?);
            if (!std.mem.eql(u8, m.root_path, norm_root)) {
                const new_root = try self.allocator.dupe(u8, norm_root);
                self.allocator.free(m.root_path);
                m.root_path = new_root;
            }
            if (update_filter) {
                m.ignore_filter = filter_opt;
            }
            return idx;
        }

        const root_copy = try self.allocator.dupe(u8, norm_root);
        var root_owned = true;
        errdefer if (root_owned) self.allocator.free(root_copy);

        const now = nowMonotonicMs();
        var state = MountState{
            .mount_id = mount_id,
            .root_path = root_copy,
            .mode = .none,
            .ignore_filter = if (update_filter) filter_opt else null,
            .last_activity_ms = now,
        };
        root_owned = false;
        var state_owned = true;
        errdefer if (state_owned) state.deinit(self.allocator);

        var idx: u32 = undefined;
        if (self.free_mount_slots.items.len > 0) {
            idx = self.free_mount_slots.pop().?;
            self.mounts.items[idx] = state;
        } else {
            idx = @intCast(self.mounts.items.len);
            try self.mounts.append(self.allocator, state);
        }
        state_owned = false;
        errdefer {
            if (self.mounts.items[idx]) |*m| {
                m.deinit(self.allocator);
                self.mounts.items[idx] = null;
            }
            self.free_mount_slots.append(self.allocator, idx) catch {};
        }
        try self.mount_id_to_idx.put(self.allocator, mount_id, idx);
        return idx;
    }

    pub fn setMountIgnoreFilter(self: *SharedWatcher, mount_id: u64, ignore_filter: ?IgnoreFilter) void {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return;
        if (self.mounts.items[idx]) |*m| {
            m.ignore_filter = ignore_filter;
        }
    }

    pub fn addDir(self: *SharedWatcher, mount_id: u64, dir_path: []const u8) !i32 {
        return self.addSubdir(mount_id, dir_path, "");
    }

    pub fn addSubdir(self: *SharedWatcher, mount_id: u64, root_path: []const u8, rel_dir: []const u8) !i32 {
        const mount_idx = try self.ensureMount(mount_id, root_path, null, false);
        const wd = try self.addSubdirByIdx(mount_idx, rel_dir);
        if (self.mounts.items[mount_idx]) |*m| {
            if (m.mode == .none) m.mode = .full_inotify;
        }
        return wd;
    }

    fn addSubdirByIdx(self: *SharedWatcher, mount_idx: u32, rel_dir: []const u8) !i32 {
        const root_path = self.mounts.items[mount_idx].?.root_path;
        const full_path = if (rel_dir.len == 0)
            try self.allocator.dupe(u8, root_path)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root_path, rel_dir });
        defer self.allocator.free(full_path);

        const path_buf = try self.allocator.alloc(u8, full_path.len + 1);
        defer self.allocator.free(path_buf);
        @memcpy(path_buf[0..full_path.len], full_path);
        path_buf[full_path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_buf.ptr);

        const rc = linux.inotify_add_watch(self.inotify_fd, path_z, WATCH_MASK);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            if (err == .NOSPC or err == .NOMEM) return error.WatchBudgetExceeded;
            return error.InotifyAddWatchFailed;
        }
        const wd: i32 = @intCast(rc);

        if (self.watches.getPtr(wd)) |bucket| {
            const rel_copy = try self.allocator.dupe(u8, rel_dir);
            var rel_owned = true;
            errdefer if (rel_owned) self.allocator.free(rel_copy);
            for (bucket.items) |*existing| {
                if (existing.mount_idx == mount_idx) {
                    self.allocator.free(existing.rel_dir);
                    existing.rel_dir = rel_copy;
                    rel_owned = false;
                    return wd;
                }
            }
            var new_m = &(self.mounts.items[mount_idx].?);
            try new_m.wd_list.append(self.allocator, wd);
            errdefer _ = new_m.wd_list.pop();
            try bucket.append(self.allocator, .{
                .mount_idx = mount_idx,
                .rel_dir = rel_copy,
            });
            rel_owned = false;
            return wd;
        }

        const already_counted = self.shared_git_watches.contains(wd) or self.fence_watches.contains(wd);
        if (!already_counted and self.active_watches >= self.max_watches) {
            _ = linux.inotify_rm_watch(self.inotify_fd, wd);
            return error.WatchBudgetExceeded;
        }

        const rel_copy = try self.allocator.dupe(u8, rel_dir);
        var rel_owned = true;
        errdefer if (rel_owned) self.allocator.free(rel_copy);

        var bucket: std.ArrayList(WatchEntry) = .empty;
        errdefer {
            for (bucket.items) |*e| e.deinit(self.allocator);
            bucket.deinit(self.allocator);
        }
        try bucket.append(self.allocator, .{
            .mount_idx = mount_idx,
            .rel_dir = rel_copy,
        });
        rel_owned = false;

        var m = &(self.mounts.items[mount_idx].?);
        try m.wd_list.append(self.allocator, wd);
        errdefer _ = m.wd_list.pop();

        try self.watches.put(self.allocator, wd, bucket);
        if (!already_counted) {
            self.active_watches += 1;
        }
        return wd;
    }

    pub fn addDirRecursive(self: *SharedWatcher, io: Io, mount_id: u64, root_path: []const u8) !void {
        _ = try self.registerMount(io, mount_id, root_path, null);
    }

    pub fn addDirRecursiveFiltered(
        self: *SharedWatcher,
        io: Io,
        mount_id: u64,
        root_path: []const u8,
        ignore_filter: ?IgnoreFilter,
    ) !WatchMode {
        return try self.registerMount(io, mount_id, root_path, ignore_filter);
    }

    pub fn registerMount(
        self: *SharedWatcher,
        io: Io,
        mount_id: u64,
        root_path: []const u8,
        ignore_filter: ?IgnoreFilter,
    ) !WatchMode {
        const mount_idx = try self.ensureMount(mount_id, root_path, ignore_filter, true);
        return try self.attachMountWatches(io, mount_idx);
    }

    fn attachMountWatches(self: *SharedWatcher, io: Io, mount_idx: u32) !WatchMode {
        self.dropMountWorktreeWatches(mount_idx);
        const res = self.walkAndWatchMount(io, mount_idx);
        res catch |err| switch (err) {
            error.WatchBudgetExceeded => {
                self.degradeMount(mount_idx);
                return .stat_on_demand;
            },
            else => return err,
        };
        if (self.mounts.items[mount_idx]) |*m| {
            m.mode = .full_inotify;
            m.last_activity_ms = nowMonotonicMs();
        }
        return .full_inotify;
    }

    fn walkAndWatchMount(self: *SharedWatcher, io: Io, mount_idx: u32) !void {
        _ = try self.addSubdirByIdx(mount_idx, "");
        try self.watchChildrenRecursiveByIdx(io, mount_idx, "");
    }

    fn degradeMount(self: *SharedWatcher, mount_idx: u32) void {
        self.dropMountWorktreeWatches(mount_idx);
        if (mount_idx < self.mounts.items.len) {
            if (self.mounts.items[mount_idx]) |*m| {
                m.mode = .stat_on_demand;
                m.overflow = true;
                m.markPending(nowMonotonicMs());
            }
        }
        self.rearmTimer(nowMonotonicMs());
    }

    pub fn watchSubdirRecursive(self: *SharedWatcher, io: Io, mount_id: u64, root_path: []const u8, rel_dir: []const u8) !void {
        const mount_idx = try self.ensureMount(mount_id, root_path, null, false);
        const m = self.mounts.items[mount_idx] orelse return;
        if (m.mode == .stat_on_demand) return;
        if (rel_dir.len > 0 and m.isIgnored(rel_dir, true)) return;
        self.watchSubdirRecursiveByIdx(io, mount_idx, rel_dir) catch |err| switch (err) {
            error.WatchBudgetExceeded => self.degradeMount(mount_idx),
            else => return err,
        };
    }

    fn watchSubdirRecursiveByIdx(self: *SharedWatcher, io: Io, mount_idx: u32, rel_dir: []const u8) !void {
        if (mount_idx >= self.mounts.items.len) return;
        const m = self.mounts.items[mount_idx] orelse return;
        if (rel_dir.len > 0 and m.isIgnored(rel_dir, true)) return;
        _ = self.addSubdirByIdx(mount_idx, rel_dir) catch |err| switch (err) {
            error.WatchBudgetExceeded => return error.WatchBudgetExceeded,
            else => return,
        };
        try self.watchChildrenRecursiveByIdx(io, mount_idx, rel_dir);
    }

    fn watchChildrenRecursiveByIdx(self: *SharedWatcher, io: Io, mount_idx: u32, rel_dir: []const u8) !void {
        const root_path = self.mounts.items[mount_idx].?.root_path;
        const full_path = if (rel_dir.len == 0)
            try self.allocator.dupe(u8, root_path)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root_path, rel_dir });
        defer self.allocator.free(full_path);

        var dir = Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (isIgnoredName(entry.name)) continue;
            const child_rel = if (rel_dir.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_dir, entry.name });
            defer self.allocator.free(child_rel);

            if (self.mounts.items[mount_idx]) |*m| {
                if (m.isIgnored(child_rel, true)) continue;
            }

            _ = self.addSubdirByIdx(mount_idx, child_rel) catch |err| switch (err) {
                error.WatchBudgetExceeded => return error.WatchBudgetExceeded,
                else => continue,
            };
            try self.watchChildrenRecursiveByIdx(io, mount_idx, child_rel);
        }
    }

    fn removeWdFromMountList(m: *MountState, wd: i32) void {
        var i: usize = 0;
        while (i < m.wd_list.items.len) {
            if (m.wd_list.items[i] == wd) {
                _ = m.wd_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn removeMountFromWd(self: *SharedWatcher, mount_idx: u32, wd: i32, call_rm: bool) void {
        const bucket = self.watches.getPtr(wd) orelse return;
        var i: usize = 0;
        while (i < bucket.items.len) {
            if (bucket.items[i].mount_idx == mount_idx) {
                var removed = bucket.swapRemove(i);
                removed.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
        if (bucket.items.len == 0) {
            if (self.watches.fetchRemove(wd)) |kv| {
                var empty_list = kv.value;
                empty_list.deinit(self.allocator);
            }
            if (!self.shared_git_watches.contains(wd) and !self.fence_watches.contains(wd)) {
                if (call_rm) {
                    _ = linux.inotify_rm_watch(self.inotify_fd, wd);
                }
                if (self.active_watches > 0) self.active_watches -= 1;
            }
        }
    }

    fn cleanupSubtreeWatchesForMount(self: *SharedWatcher, mount_idx: u32, moved_rel_dir: []const u8) void {
        if (mount_idx >= self.mounts.items.len) return;
        const m = &(self.mounts.items[mount_idx] orelse return);
        var to_remove: std.ArrayList(i32) = .empty;
        defer to_remove.deinit(self.allocator);

        for (m.wd_list.items) |wd| {
            const bucket = self.watches.get(wd) orelse continue;
            for (bucket.items) |entry| {
                if (entry.mount_idx != mount_idx) continue;
                const match = std.mem.eql(u8, entry.rel_dir, moved_rel_dir) or
                    (entry.rel_dir.len > moved_rel_dir.len and
                        std.mem.startsWith(u8, entry.rel_dir, moved_rel_dir) and
                        entry.rel_dir[moved_rel_dir.len] == '/');
                if (match) {
                    to_remove.append(self.allocator, wd) catch {};
                    break;
                }
            }
        }
        for (to_remove.items) |wd| {
            removeWdFromMountList(m, wd);
            self.removeMountFromWd(mount_idx, wd, true);
        }
    }

    fn dropMountWorktreeWatches(self: *SharedWatcher, mount_idx: u32) void {
        if (mount_idx >= self.mounts.items.len) return;
        var m = &(self.mounts.items[mount_idx] orelse return);
        for (m.wd_list.items) |wd| {
            self.removeMountFromWd(mount_idx, wd, true);
        }
        m.wd_list.clearRetainingCapacity();
    }

    fn removeWorktreeWatch(self: *SharedWatcher, wd: i32, call_rm: bool) void {
        if (self.watches.fetchRemove(wd)) |kv| {
            var bucket = kv.value;
            defer {
                for (bucket.items) |*e| e.deinit(self.allocator);
                bucket.deinit(self.allocator);
            }
            if (!self.shared_git_watches.contains(wd) and !self.fence_watches.contains(wd)) {
                if (call_rm) {
                    _ = linux.inotify_rm_watch(self.inotify_fd, wd);
                }
                if (self.active_watches > 0) self.active_watches -= 1;
            }
            for (bucket.items) |entry| {
                if (entry.mount_idx < self.mounts.items.len) {
                    if (self.mounts.items[entry.mount_idx]) |*m| {
                        removeWdFromMountList(m, wd);
                    }
                }
            }
        }
    }

    pub fn hibernateMountWatches(self: *SharedWatcher, mount_id: u64) bool {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return false;
        self.dropMountWorktreeWatches(idx);
        if (self.mounts.items[idx]) |*m| {
            m.mode = .stat_on_demand;
        }
        return true;
    }

    pub fn restoreMountWatches(self: *SharedWatcher, io: Io, mount_id: u64) !WatchMode {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return .none;
        if (self.mounts.items[idx]) |*m| {
            if (m.mode == .full_inotify) {
                m.last_activity_ms = nowMonotonicMs();
                return .full_inotify;
            }
        }
        return try self.attachMountWatches(io, idx);
    }

    pub fn hibernateIdleMounts(self: *SharedWatcher, idle_threshold_ms: u64, now_ms: u64) usize {
        var hibernated: usize = 0;
        for (self.mounts.items, 0..) |*slot, i| {
            if (slot.*) |*m| {
                if (m.mode != .full_inotify) continue;
                if (m.pending) continue;
                if (now_ms -| m.last_activity_ms >= idle_threshold_ms) {
                    self.dropMountWorktreeWatches(@intCast(i));
                    self.mounts.items[i].?.mode = .stat_on_demand;
                    hibernated += 1;
                }
            }
        }
        return hibernated;
    }

    pub fn subscribeGitCommon(self: *SharedWatcher, mount_id: u64, common_dir: []const u8) !void {
        const mount_idx = self.mount_id_to_idx.get(mount_id) orelse return error.UnknownMount;
        const trimmed = std.mem.trimEnd(u8, common_dir, "/");
        const norm = if (trimmed.len == 0 and common_dir.len > 0) "/" else trimmed;

        if (self.mounts.items[mount_idx].?.shared_git_idx) |old_gidx| {
            if (self.shared_git_groups.items[old_gidx]) |*old_g| {
                if (std.mem.eql(u8, old_g.common_dir, norm)) return;
            }
            self.unsubscribeGitCommonByIdx(mount_idx);
        }

        if (self.shared_git_by_path.get(norm)) |gidx| {
            var g = &(self.shared_git_groups.items[gidx].?);
            for (g.subscribers.items) |sub| {
                if (sub == mount_idx) {
                    self.mounts.items[mount_idx].?.shared_git_idx = gidx;
                    return;
                }
            }
            try g.subscribers.append(self.allocator, mount_idx);
            self.mounts.items[mount_idx].?.shared_git_idx = gidx;
            return;
        }

        const dir_copy = try self.allocator.dupe(u8, norm);
        var dir_owned = true;
        errdefer if (dir_owned) self.allocator.free(dir_copy);

        var group = SharedGitGroup{
            .common_dir = dir_copy,
        };
        dir_owned = false;
        var group_owned = true;
        errdefer if (group_owned) group.deinit(self.allocator);

        try group.subscribers.append(self.allocator, mount_idx);

        var gidx: u32 = undefined;
        if (self.free_git_slots.items.len > 0) {
            gidx = self.free_git_slots.pop().?;
            self.shared_git_groups.items[gidx] = group;
        } else {
            gidx = @intCast(self.shared_git_groups.items.len);
            try self.shared_git_groups.append(self.allocator, group);
        }
        group_owned = false;
        errdefer {
            self.destroySharedGitGroup(gidx);
        }

        try self.addSharedGitWatch(gidx, norm, "");
        const refs_path = try std.fmt.allocPrint(self.allocator, "{s}/refs", .{norm});
        defer self.allocator.free(refs_path);
        self.addSharedGitWatch(gidx, refs_path, "refs") catch {};

        const heads_path = try std.fmt.allocPrint(self.allocator, "{s}/refs/heads", .{norm});
        defer self.allocator.free(heads_path);
        self.addSharedGitWatch(gidx, heads_path, "refs/heads") catch {};

        try self.shared_git_by_path.put(self.allocator, self.shared_git_groups.items[gidx].?.common_dir, gidx);
        self.mounts.items[mount_idx].?.shared_git_idx = gidx;
    }

    fn addSharedGitWatch(self: *SharedWatcher, gidx: u32, full_path: []const u8, sub_prefix: []const u8) !void {
        const path_buf = try self.allocator.alloc(u8, full_path.len + 1);
        defer self.allocator.free(path_buf);
        @memcpy(path_buf[0..full_path.len], full_path);
        path_buf[full_path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_buf.ptr);

        const rc = linux.inotify_add_watch(self.inotify_fd, path_z, WATCH_MASK);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            if (err == .NOSPC or err == .NOMEM) return error.WatchBudgetExceeded;
            return error.InotifyAddWatchFailed;
        }
        const wd: i32 = @intCast(rc);

        const already_counted = self.watches.contains(wd) or self.shared_git_watches.contains(wd) or self.fence_watches.contains(wd);
        if (!already_counted and self.active_watches >= self.max_watches) {
            _ = linux.inotify_rm_watch(self.inotify_fd, wd);
            return error.WatchBudgetExceeded;
        }

        const prefix_copy = try self.allocator.dupe(u8, sub_prefix);
        var prefix_owned = true;
        errdefer if (prefix_owned) self.allocator.free(prefix_copy);

        var g = &(self.shared_git_groups.items[gidx].?);
        try g.wds.append(self.allocator, .{
            .wd = wd,
            .sub_prefix = prefix_copy,
        });
        prefix_owned = false;
        errdefer {
            var popped = g.wds.pop().?;
            popped.deinit(self.allocator);
        }

        try self.shared_git_watches.put(self.allocator, wd, gidx);
        if (!already_counted) {
            self.active_watches += 1;
        }
    }

    fn destroySharedGitGroup(self: *SharedWatcher, gidx: u32) void {
        if (gidx >= self.shared_git_groups.items.len) return;
        var g = &(self.shared_git_groups.items[gidx] orelse return);
        _ = self.shared_git_by_path.remove(g.common_dir);
        for (g.wds.items) |w| {
            _ = self.shared_git_watches.remove(w.wd);
            if (!self.watches.contains(w.wd) and !self.fence_watches.contains(w.wd)) {
                _ = linux.inotify_rm_watch(self.inotify_fd, w.wd);
                if (self.active_watches > 0) self.active_watches -= 1;
            }
        }
        g.deinit(self.allocator);
        self.shared_git_groups.items[gidx] = null;
        self.free_git_slots.append(self.allocator, gidx) catch {};
    }

    pub fn unsubscribeGitCommon(self: *SharedWatcher, mount_id: u64) void {
        const mount_idx = self.mount_id_to_idx.get(mount_id) orelse return;
        self.unsubscribeGitCommonByIdx(mount_idx);
    }

    fn unsubscribeGitCommonByIdx(self: *SharedWatcher, mount_idx: u32) void {
        if (mount_idx >= self.mounts.items.len) return;
        var m = &(self.mounts.items[mount_idx] orelse return);
        const gidx = m.shared_git_idx orelse return;
        m.shared_git_idx = null;

        if (gidx >= self.shared_git_groups.items.len) return;
        var g = &(self.shared_git_groups.items[gidx] orelse return);
        var i: usize = 0;
        while (i < g.subscribers.items.len) {
            if (g.subscribers.items[i] == mount_idx) {
                _ = g.subscribers.swapRemove(i);
            } else {
                i += 1;
            }
        }
        if (g.subscribers.items.len == 0) {
            self.destroySharedGitGroup(gidx);
        }
    }

    fn removeFenceWatchByIdx(self: *SharedWatcher, mount_idx: u32) void {
        if (mount_idx >= self.mounts.items.len) return;
        var m = &(self.mounts.items[mount_idx] orelse return);
        if (m.fence_wd) |wd| {
            if (self.fence_watches.getPtr(wd)) |list| {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == mount_idx) {
                        _ = list.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
                if (list.items.len == 0) {
                    if (self.fence_watches.fetchRemove(wd)) |kv| {
                        var empty_list = kv.value;
                        empty_list.deinit(self.allocator);
                    }
                    if (!self.watches.contains(wd) and !self.shared_git_watches.contains(wd)) {
                        _ = linux.inotify_rm_watch(self.inotify_fd, wd);
                        if (self.active_watches > 0) self.active_watches -= 1;
                    }
                }
            }
            m.fence_wd = null;
        }
        if (m.fence_dir) |fd| {
            self.allocator.free(fd);
            m.fence_dir = null;
        }
    }

    pub fn removeMount(self: *SharedWatcher, mount_id: u64) void {
        const kv = self.mount_id_to_idx.fetchRemove(mount_id) orelse return;
        const idx = kv.value;
        self.dropMountWorktreeWatches(idx);
        self.unsubscribeGitCommonByIdx(idx);
        self.removeFenceWatchByIdx(idx);
        if (idx < self.mounts.items.len) {
            if (self.mounts.items[idx]) |*m| {
                m.deinit(self.allocator);
                self.mounts.items[idx] = null;
            }
            self.free_mount_slots.append(self.allocator, idx) catch {};
        }
        self.rearmTimer(nowMonotonicMs());
    }

    fn armTimerRelativeMs(self: *const SharedWatcher, delay_ms: u64) void {
        const ms = if (delay_ms == 0) 1 else delay_ms;
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1_000_000),
            },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
    }

    fn disarmTimer(self: *const SharedWatcher) void {
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 0 },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
    }

    fn rearmTimer(self: *const SharedWatcher, now_ms: u64) void {
        var earliest: ?u64 = null;
        for (self.mounts.items) |slot| {
            if (slot) |m| {
                if (!m.pending) continue;
                const d = m.deadlineMs(self.debounce_ms, self.max_latency_ms);
                earliest = if (earliest) |e| @min(e, d) else d;
            }
        }
        if (self.idle_tick_ms > 0 and self.next_idle_tick_ms > 0) {
            earliest = if (earliest) |e| @min(e, self.next_idle_tick_ms) else self.next_idle_tick_ms;
        }
        if (earliest) |e| {
            const delay = if (e <= now_ms) 1 else (e - now_ms);
            self.armTimerRelativeMs(delay);
        } else {
            self.disarmTimer();
        }
    }

    pub fn wait(self: *const SharedWatcher, timeout_ms: i32) WaitResult {
        var res = WaitResult{};
        var ep_events: [8]linux.epoll_event = undefined;
        const n_rc = linux.epoll_wait(self.epoll_fd, &ep_events, ep_events.len, timeout_ms);
        const ep_err = linux.errno(n_rc);
        if (ep_err != .SUCCESS or n_rc == 0) return res;

        const n_ev: usize = @intCast(n_rc);
        for (ep_events[0..n_ev]) |eev| {
            if (eev.data.fd == self.wake_fd) {
                var val: u64 = 0;
                _ = linux.read(self.wake_fd, std.mem.asBytes(&val), @sizeOf(u64));
                res.woken = true;
            } else if (eev.data.fd == self.inotify_fd) {
                res.ready = true;
            } else if (eev.data.fd == self.timer_fd) {
                var exp: u64 = 0;
                _ = linux.read(self.timer_fd, std.mem.asBytes(&exp), @sizeOf(u64));
                res.timer = true;
            }
        }
        return res;
    }

    pub fn drain(self: *SharedWatcher, io: Io, out: *std.ArrayList(WatchEvent)) !DrainResult {
        return try self.drainKernel(io, out);
    }

    pub fn drainPending(self: *SharedWatcher, io: Io) !void {
        _ = try self.drainKernel(io, null);
    }

    pub fn poll(self: *SharedWatcher, io: Io, timeout_ms: i32, out: *std.ArrayList(WatchEvent)) !PollResult {
        const w = self.wait(timeout_ms);
        const woken = w.woken or self.pending_wake;
        self.pending_wake = false;
        if (!w.ready) {
            return .{ .count = 0, .woken = woken, .overflow = false, .timer = w.timer };
        }
        const d = try self.drain(io, out);
        return .{ .count = d.count, .woken = woken, .overflow = d.overflow, .timer = w.timer };
    }

    fn drainKernel(self: *SharedWatcher, io: Io, raw_out: ?*std.ArrayList(WatchEvent)) !DrainResult {
        var res = DrainResult{};
        const now = nowMonotonicMs();
        var buf: [32768]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const r_rc = linux.read(self.inotify_fd, &buf, buf.len);
            const err = linux.errno(r_rc);
            if (err == .AGAIN) break;
            if (err == .INTR) continue;
            if (err != .SUCCESS or r_rc == 0) break;

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= r_rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
                const name_start = offset + @sizeOf(linux.inotify_event);
                const name_end = name_start + ev.len;
                offset = name_end;
                if (name_end > r_rc) break;

                if ((ev.mask & linux.IN.Q_OVERFLOW) != 0) {
                    res.overflow = true;
                    for (self.mounts.items) |*slot| {
                        if (slot.*) |*m| {
                            m.overflow = true;
                            m.markPending(now);
                        }
                    }
                    continue;
                }

                if ((ev.mask & linux.IN.IGNORED) != 0) {
                    self.handleIgnoredWd(ev.wd);
                    continue;
                }

                const raw_name = buf[name_start..name_end];
                const nul_pos = std.mem.indexOfScalar(u8, raw_name, 0) orelse raw_name.len;
                const name = raw_name[0..nul_pos];

                if (self.fence_watches.get(ev.wd)) |f_list| {
                    for (f_list.items) |f_mount_idx| {
                        self.handleFenceEvent(io, f_mount_idx, ev.mask, name);
                    }
                    continue;
                }

                if (self.shared_git_watches.get(ev.wd)) |gidx| {
                    try self.handleSharedGitEvent(gidx, ev.wd, ev.mask, name, now, raw_out, &res);
                    continue;
                }

                const bucket_ptr = self.watches.getPtr(ev.wd) orelse continue;
                const SnapEntry = struct { mount_idx: u32, rel_dir: []u8 };
                var snapped: std.ArrayList(SnapEntry) = .empty;
                defer {
                    for (snapped.items) |se| self.allocator.free(se.rel_dir);
                    snapped.deinit(self.allocator);
                }
                for (bucket_ptr.items) |we| {
                    try snapped.append(self.allocator, .{
                        .mount_idx = we.mount_idx,
                        .rel_dir = try self.allocator.dupe(u8, we.rel_dir),
                    });
                }

                const is_self_event = (ev.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF)) != 0;
                if (is_self_event) {
                    for (snapped.items) |se| {
                        const mount_idx = se.mount_idx;
                        if (mount_idx >= self.mounts.items.len) continue;
                        if (self.mounts.items[mount_idx] == null) continue;
                        if (se.rel_dir.len == 0) {
                            self.mounts.items[mount_idx].?.overflow = true;
                            self.mounts.items[mount_idx].?.markPending(now);
                            res.overflow = true;
                        } else {
                            self.cleanupSubtreeWatchesForMount(mount_idx, se.rel_dir);
                            self.mounts.items[mount_idx].?.overflow = true;
                            if (raw_out == null) {
                                try self.mounts.items[mount_idx].?.recordDirty(self.allocator, se.rel_dir, ev.mask, true, now);
                            }
                            res.overflow = true;
                        }
                    }
                    continue;
                }

                if (name.len > 0 and isIgnoredName(name)) continue;

                const is_dir = (ev.mask & linux.IN.ISDIR) != 0;
                for (snapped.items) |se| {
                    const mount_idx = se.mount_idx;
                    if (mount_idx >= self.mounts.items.len) continue;
                    if (self.mounts.items[mount_idx] == null) continue;

                    const rel_path = if (se.rel_dir.len == 0)
                        try self.allocator.dupe(u8, name)
                    else if (name.len == 0)
                        try self.allocator.dupe(u8, se.rel_dir)
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ se.rel_dir, name });
                    var rel_owned = true;
                    errdefer if (rel_owned) self.allocator.free(rel_path);

                    if (self.mounts.items[mount_idx].?.isIgnored(rel_path, is_dir)) {
                        self.allocator.free(rel_path);
                        rel_owned = false;
                        continue;
                    }

                    if (is_dir and rel_path.len > 0 and ((ev.mask & linux.IN.CREATE) != 0 or (ev.mask & linux.IN.MOVED_TO) != 0)) {
                        self.watchSubdirRecursiveByIdx(io, mount_idx, rel_path) catch |werr| switch (werr) {
                            error.WatchBudgetExceeded => {
                                self.degradeMount(mount_idx);
                                res.overflow = true;
                            },
                            else => {},
                        };
                    }

                    const mount_id = self.mounts.items[mount_idx].?.mount_id;
                    if (raw_out) |out| {
                        const name_copy = try self.allocator.dupe(u8, name);
                        errdefer self.allocator.free(name_copy);
                        self.mounts.items[mount_idx].?.last_activity_ms = now;
                        try out.append(self.allocator, .{
                            .mount_id = mount_id,
                            .wd = ev.wd,
                            .mask = ev.mask,
                            .name = name_copy,
                            .rel_path = rel_path,
                            .is_dir = is_dir,
                            .is_git = false,
                        });
                        rel_owned = false;
                    } else {
                        defer self.allocator.free(rel_path);
                        rel_owned = false;
                        try self.mounts.items[mount_idx].?.recordDirty(self.allocator, rel_path, ev.mask, is_dir, now);
                    }
                    res.count += 1;
                }
            }
        }
        return res;
    }

    fn handleIgnoredWd(self: *SharedWatcher, wd: i32) void {
        if (self.watches.contains(wd)) {
            self.removeWorktreeWatch(wd, false);
        }
        if (self.shared_git_watches.fetchRemove(wd)) |kv| {
            const gidx = kv.value;
            if (gidx < self.shared_git_groups.items.len) {
                if (self.shared_git_groups.items[gidx]) |*g| {
                    var i: usize = 0;
                    while (i < g.wds.items.len) {
                        if (g.wds.items[i].wd == wd) {
                            var removed = g.wds.swapRemove(i);
                            removed.deinit(self.allocator);
                        } else {
                            i += 1;
                        }
                    }
                }
            }
            if (!self.watches.contains(wd) and !self.fence_watches.contains(wd)) {
                if (self.active_watches > 0) self.active_watches -= 1;
            }
        }
        if (self.fence_watches.fetchRemove(wd)) |kv| {
            var list = kv.value;
            defer list.deinit(self.allocator);
            for (list.items) |midx| {
                if (midx < self.mounts.items.len) {
                    if (self.mounts.items[midx]) |*m| {
                        if (m.fence_wd == wd) m.fence_wd = null;
                    }
                }
            }
            if (!self.watches.contains(wd) and !self.shared_git_watches.contains(wd)) {
                if (self.active_watches > 0) self.active_watches -= 1;
            }
        }
    }

    fn handleFenceEvent(self: *SharedWatcher, io: Io, mount_idx: u32, mask: u32, name: []const u8) void {
        if (mount_idx >= self.mounts.items.len) return;
        var m = &(self.mounts.items[mount_idx] orelse return);
        if (m.expected_fence_seq == 0 or name.len == 0) return;
        if ((mask & (linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO)) == 0) return;
        const parsed = std.fmt.parseInt(u64, name, 10) catch return;
        if (parsed == m.expected_fence_seq) {
            m.fence_observed = true;
            if (m.fence_dir) |fdir| {
                const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ fdir, name }) catch return;
                defer self.allocator.free(full);
                Io.Dir.cwd().deleteFile(io, full) catch {};
            }
        }
    }

    fn handleSharedGitEvent(
        self: *SharedWatcher,
        gidx: u32,
        wd: i32,
        mask: u32,
        name: []const u8,
        now: u64,
        raw_out: ?*std.ArrayList(WatchEvent),
        res: *DrainResult,
    ) !void {
        if (name.len > 0 and std.mem.endsWith(u8, name, ".0ndb-tmp")) return;
        if (gidx >= self.shared_git_groups.items.len) return;
        const g = &(self.shared_git_groups.items[gidx] orelse return);
        const sub_prefix = g.subPrefixForWd(wd);
        const rel_path = if (sub_prefix.len == 0 and name.len == 0)
            try self.allocator.dupe(u8, ".git")
        else if (sub_prefix.len == 0)
            try std.fmt.allocPrint(self.allocator, ".git/{s}", .{name})
        else if (name.len == 0)
            try std.fmt.allocPrint(self.allocator, ".git/{s}", .{sub_prefix})
        else
            try std.fmt.allocPrint(self.allocator, ".git/{s}/{s}", .{ sub_prefix, name });
        defer self.allocator.free(rel_path);

        const is_dir = (mask & linux.IN.ISDIR) != 0;
        for (g.subscribers.items) |mount_idx| {
            if (mount_idx >= self.mounts.items.len) continue;
            var m = &(self.mounts.items[mount_idx] orelse continue);
            if (raw_out) |out| {
                const name_copy = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(name_copy);
                const rel_copy = try self.allocator.dupe(u8, rel_path);
                errdefer self.allocator.free(rel_copy);
                m.last_activity_ms = now;
                try out.append(self.allocator, .{
                    .mount_id = m.mount_id,
                    .wd = wd,
                    .mask = mask,
                    .name = name_copy,
                    .rel_path = rel_copy,
                    .is_dir = is_dir,
                    .is_git = true,
                });
            } else {
                m.git_changed = true;
                try m.recordDirty(self.allocator, rel_path, mask, is_dir, now);
            }
            res.count += 1;
        }
    }

    fn takeMountBatchByIdx(self: *SharedWatcher, mount_idx: u32) !MountBatch {
        var m = &(self.mounts.items[mount_idx].?);
        var batch = MountBatch{
            .mount_id = m.mount_id,
            .mode = m.mode,
            .overflow = m.overflow,
            .git_changed = m.git_changed,
            .paths = .empty,
        };
        errdefer batch.deinit(self.allocator);

        const count = m.dirty_paths.count();
        try batch.paths.ensureTotalCapacityPrecise(self.allocator, count);
        var it = m.dirty_paths.iterator();
        while (it.next()) |kv| {
            batch.paths.appendAssumeCapacity(.{
                .rel_path = @constCast(kv.key_ptr.*),
                .mask = kv.value_ptr.mask,
                .is_dir = kv.value_ptr.is_dir,
            });
        }
        m.dirty_paths.clearRetainingCapacity();
        m.overflow = false;
        m.git_changed = false;
        m.pending = false;
        m.first_event_ms = 0;
        m.last_event_ms = 0;
        return batch;
    }

    pub fn flushMountPending(self: *SharedWatcher, mount_id: u64) !?MountBatch {
        const idx = self.mount_id_to_idx.get(mount_id) orelse return null;
        const m = self.mounts.items[idx] orelse return null;
        if (!m.pending and !m.overflow and !m.git_changed and m.dirty_paths.count() == 0) return null;
        const batch = try self.takeMountBatchByIdx(idx);
        self.rearmTimer(nowMonotonicMs());
        return batch;
    }

    pub fn nextEventBatch(self: *SharedWatcher, io: Io, timeout_ms: i32) !EventBatchResult {
        var res = EventBatchResult{};
        errdefer res.deinit(self.allocator);

        if (self.pending_wake) {
            self.pending_wake = false;
            res.woken = true;
        }

        const start_ms = nowMonotonicMs();
        const call_deadline_ms: ?u64 = if (timeout_ms >= 0) start_ms + @as(u64, @intCast(timeout_ms)) else null;

        while (true) {
            _ = try self.drainKernel(io, null);
            const now = nowMonotonicMs();

            for (self.mounts.items, 0..) |*slot, i| {
                if (slot.*) |*m| {
                    if (!m.pending) continue;
                    const deadline = m.deadlineMs(self.debounce_ms, self.max_latency_ms);
                    if (now >= deadline) {
                        var batch = try self.takeMountBatchByIdx(@intCast(i));
                        errdefer batch.deinit(self.allocator);
                        try res.batches.append(self.allocator, batch);
                    }
                }
            }

            if (self.idle_tick_ms > 0 and self.next_idle_tick_ms > 0 and now >= self.next_idle_tick_ms) {
                self.next_idle_tick_ms = now + self.idle_tick_ms;
                res.idle_ticked = true;
                if (self.idle_callback) |cb| {
                    cb.on_tick(cb.ctx, self, now);
                }
            }

            if (res.batches.items.len > 0 or res.woken or res.idle_ticked) {
                self.rearmTimer(nowMonotonicMs());
                return res;
            }

            self.rearmTimer(now);

            var wait_ms: i32 = -1;
            if (call_deadline_ms) |cd| {
                if (now >= cd) {
                    res.timed_out = true;
                    return res;
                }
                const rem = cd - now;
                wait_ms = @intCast(@min(rem, @as(u64, std.math.maxInt(i32))));
            }

            var ep_events: [8]linux.epoll_event = undefined;
            const n_rc = linux.epoll_wait(self.epoll_fd, &ep_events, ep_events.len, wait_ms);
            const ep_err = linux.errno(n_rc);
            if (ep_err == .INTR) continue;
            if (ep_err != .SUCCESS) {
                res.timed_out = true;
                return res;
            }
            if (n_rc == 0) {
                continue;
            }

            const n_ev: usize = @intCast(n_rc);
            for (ep_events[0..n_ev]) |eev| {
                if (eev.data.fd == self.wake_fd) {
                    var val: u64 = 0;
                    _ = linux.read(self.wake_fd, std.mem.asBytes(&val), @sizeOf(u64));
                    res.woken = true;
                } else if (eev.data.fd == self.timer_fd) {
                    var exp: u64 = 0;
                    _ = linux.read(self.timer_fd, std.mem.asBytes(&exp), @sizeOf(u64));
                }
            }
        }
    }

    fn ensureFenceWatch(self: *SharedWatcher, io: Io, mount_idx: u32, state_dir: []const u8) ![]const u8 {
        const trimmed = std.mem.trimEnd(u8, state_dir, "/");
        const fences_dir = try std.fmt.allocPrint(self.allocator, "{s}/fences", .{trimmed});
        errdefer self.allocator.free(fences_dir);

        if (self.mounts.items[mount_idx]) |*m| {
            if (m.fence_wd != null and m.fence_dir != null and std.mem.eql(u8, m.fence_dir.?, fences_dir)) {
                self.allocator.free(fences_dir);
                return m.fence_dir.?;
            }
        }

        try Io.Dir.cwd().createDirPath(io, fences_dir);
        self.removeFenceWatchByIdx(mount_idx);

        const path_buf = try self.allocator.alloc(u8, fences_dir.len + 1);
        defer self.allocator.free(path_buf);
        @memcpy(path_buf[0..fences_dir.len], fences_dir);
        path_buf[fences_dir.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_buf.ptr);

        const rc = linux.inotify_add_watch(self.inotify_fd, path_z, FENCE_MASK);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            if (err == .NOSPC or err == .NOMEM) return error.WatchBudgetExceeded;
            return error.InotifyAddWatchFailed;
        }
        const wd: i32 = @intCast(rc);

        const already_counted = self.watches.contains(wd) or self.shared_git_watches.contains(wd) or self.fence_watches.contains(wd);
        if (self.fence_watches.getPtr(wd)) |list| {
            var found = false;
            for (list.items) |existing_idx| {
                if (existing_idx == mount_idx) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try list.append(self.allocator, mount_idx);
            }
        } else {
            var list: std.ArrayList(u32) = .empty;
            errdefer list.deinit(self.allocator);
            try list.append(self.allocator, mount_idx);
            try self.fence_watches.put(self.allocator, wd, list);
        }
        if (!already_counted) {
            self.active_watches += 1;
        }

        var m = &(self.mounts.items[mount_idx].?);
        m.fence_wd = wd;
        m.fence_dir = fences_dir;
        return m.fence_dir.?;
    }

    pub fn fence(self: *SharedWatcher, io: Io, mount_id: u64, state_dir: []const u8, timeout_ms: u64) !bool {
        const mount_idx = self.mount_id_to_idx.get(mount_id) orelse return error.UnknownMount;
        const fences_dir = try self.ensureFenceWatch(io, mount_idx, state_dir);

        self.fence_seq += 1;
        const seq = self.fence_seq;

        self.mounts.items[mount_idx].?.expected_fence_seq = seq;
        self.mounts.items[mount_idx].?.fence_observed = false;
        defer {
            if (mount_idx < self.mounts.items.len) {
                if (self.mounts.items[mount_idx]) |*m| {
                    m.expected_fence_seq = 0;
                }
            }
        }

        const marker_path = try std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ fences_dir, seq });
        defer self.allocator.free(marker_path);

        {
            const f = try Io.Dir.cwd().createFile(io, marker_path, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "1");
        }

        const deadline_ms = nowMonotonicMs() +| timeout_ms;
        while (true) {
            _ = try self.drainKernel(io, null);
            if (self.mounts.items[mount_idx].?.fence_observed) {
                self.rearmTimer(nowMonotonicMs());
                return true;
            }

            const now = nowMonotonicMs();
            if (now >= deadline_ms) {
                Io.Dir.cwd().deleteFile(io, marker_path) catch {};
                self.rearmTimer(now);
                return false;
            }

            const rem = deadline_ms - now;
            const wait_ms: i32 = @intCast(@min(rem, @as(u64, std.math.maxInt(i32))));
            var ep_events: [8]linux.epoll_event = undefined;
            const n_rc = linux.epoll_wait(self.epoll_fd, &ep_events, ep_events.len, wait_ms);
            const ep_err = linux.errno(n_rc);
            if (ep_err == .INTR) continue;
            if (ep_err != .SUCCESS) {
                Io.Dir.cwd().deleteFile(io, marker_path) catch {};
                self.rearmTimer(nowMonotonicMs());
                return false;
            }
            if (n_rc == 0) continue;

            const n_ev: usize = @intCast(n_rc);
            for (ep_events[0..n_ev]) |eev| {
                if (eev.data.fd == self.wake_fd) {
                    var val: u64 = 0;
                    _ = linux.read(self.wake_fd, std.mem.asBytes(&val), @sizeOf(u64));
                    self.pending_wake = true;
                } else if (eev.data.fd == self.timer_fd) {
                    var exp: u64 = 0;
                    _ = linux.read(self.timer_fd, std.mem.asBytes(&exp), @sizeOf(u64));
                }
            }
        }
    }
};
