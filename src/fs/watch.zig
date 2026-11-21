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
    ".DS_Store",
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

pub const WatchEvent = struct {
    mount_id: u64,
    wd: i32,
    mask: u32,
    name: []u8,
    rel_path: []u8,
    is_dir: bool,

    pub fn deinit(self: *WatchEvent, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
    }
};

pub const WaitResult = struct {
    ready: bool = false,
    woken: bool = false,
};

pub const DrainResult = struct {
    count: usize = 0,
    overflow: bool = false,
};

pub const PollResult = struct {
    count: usize = 0,
    woken: bool = false,
    overflow: bool = false,
};

const WatchEntry = struct {
    mount_id: u64,
    root_path: []u8,
    rel_dir: []u8,

    fn deinit(self: *WatchEntry, allocator: Allocator) void {
        allocator.free(self.root_path);
        allocator.free(self.rel_dir);
    }
};

pub const SharedWatcher = struct {
    allocator: Allocator,
    inotify_fd: posix.fd_t,
    epoll_fd: posix.fd_t,
    wake_fd: posix.fd_t,
    watches: std.AutoHashMapUnmanaged(i32, WatchEntry),

    pub fn init(allocator: Allocator) !SharedWatcher {
        const in_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(in_rc) != .SUCCESS) return error.InotifyInitFailed;
        const in_fd: posix.fd_t = @intCast(in_rc);
        errdefer _ = linux.close(in_fd);

        const wake_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(wake_rc) != .SUCCESS) return error.EventfdInitFailed;
        const wake_fd: posix.fd_t = @intCast(wake_rc);
        errdefer _ = linux.close(wake_fd);

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

        return .{
            .allocator = allocator,
            .inotify_fd = in_fd,
            .epoll_fd = ep_fd,
            .wake_fd = wake_fd,
            .watches = .empty,
        };
    }

    pub fn deinit(self: *SharedWatcher) void {
        var it = self.watches.valueIterator();
        while (it.next()) |e| e.deinit(self.allocator);
        self.watches.deinit(self.allocator);
        _ = linux.close(self.epoll_fd);
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.inotify_fd);
    }

    pub fn wake(self: *const SharedWatcher) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    pub fn addDir(self: *SharedWatcher, mount_id: u64, dir_path: []const u8) !i32 {
        return self.addSubdir(mount_id, dir_path, "");
    }

    pub fn addSubdir(self: *SharedWatcher, mount_id: u64, root_path: []const u8, rel_dir: []const u8) !i32 {
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
        const mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE;
        const rc = linux.inotify_add_watch(self.inotify_fd, path_z, mask);
        if (linux.errno(rc) != .SUCCESS) return error.InotifyAddWatchFailed;
        const wd: i32 = @intCast(rc);

        const root_copy = try self.allocator.dupe(u8, root_path);
        errdefer self.allocator.free(root_copy);
        const rel_copy = try self.allocator.dupe(u8, rel_dir);
        errdefer self.allocator.free(rel_copy);

        if (self.watches.getPtr(wd)) |existing| {
            existing.deinit(self.allocator);
            existing.* = .{
                .mount_id = mount_id,
                .root_path = root_copy,
                .rel_dir = rel_copy,
            };
        } else {
            try self.watches.put(self.allocator, wd, .{
                .mount_id = mount_id,
                .root_path = root_copy,
                .rel_dir = rel_copy,
            });
        }
        return wd;
    }

    pub fn addDirRecursive(self: *SharedWatcher, io: Io, mount_id: u64, root_path: []const u8) !void {
        _ = try self.addSubdir(mount_id, root_path, "");
        try self.watchChildrenRecursive(io, mount_id, root_path, "");
    }

    pub fn watchSubdirRecursive(self: *SharedWatcher, io: Io, mount_id: u64, root_path: []const u8, rel_dir: []const u8) !void {
        if (rel_dir.len > 0 and isIgnoredPath(rel_dir)) return;
        _ = self.addSubdir(mount_id, root_path, rel_dir) catch return;
        try self.watchChildrenRecursive(io, mount_id, root_path, rel_dir);
    }

    fn watchChildrenRecursive(self: *SharedWatcher, io: Io, mount_id: u64, root_path: []const u8, rel_dir: []const u8) !void {
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
            _ = self.addSubdir(mount_id, root_path, child_rel) catch continue;
            try self.watchChildrenRecursive(io, mount_id, root_path, child_rel);
        }
    }

    pub fn removeMount(self: *SharedWatcher, mount_id: u64) void {
        var to_remove: std.ArrayList(i32) = .empty;
        defer to_remove.deinit(self.allocator);
        var it = self.watches.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.mount_id == mount_id) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |wd| {
            _ = linux.inotify_rm_watch(self.inotify_fd, wd);
            if (self.watches.fetchRemove(wd)) |kv| {
                var val = kv.value;
                val.deinit(self.allocator);
            }
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
            }
        }
        return res;
    }

    pub fn drain(self: *SharedWatcher, io: Io, out: *std.ArrayList(WatchEvent)) !DrainResult {
        var res = DrainResult{};
        var buf: [16384]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const r_rc = linux.read(self.inotify_fd, &buf, buf.len);
            const err = linux.errno(r_rc);
            if (err == .AGAIN) break;
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
                    continue;
                }
                if ((ev.mask & linux.IN.IGNORED) != 0) {
                    if (self.watches.fetchRemove(ev.wd)) |kv| {
                        var val = kv.value;
                        val.deinit(self.allocator);
                    }
                    continue;
                }

                const raw_name = buf[name_start..name_end];
                const nul_pos = std.mem.indexOfScalar(u8, raw_name, 0) orelse raw_name.len;
                const name = raw_name[0..nul_pos];
                if (name.len > 0 and isIgnoredName(name)) continue;

                const entry = self.watches.get(ev.wd) orelse continue;
                const mount_id = entry.mount_id;
                const rel_path = if (entry.rel_dir.len == 0)
                    try self.allocator.dupe(u8, name)
                else if (name.len == 0)
                    try self.allocator.dupe(u8, entry.rel_dir)
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ entry.rel_dir, name });
                errdefer self.allocator.free(rel_path);

                const is_dir = (ev.mask & linux.IN.ISDIR) != 0;
                if (is_dir and rel_path.len > 0 and ((ev.mask & linux.IN.CREATE) != 0 or (ev.mask & linux.IN.MOVED_TO) != 0)) {
                    const root_dup = try self.allocator.dupe(u8, entry.root_path);
                    defer self.allocator.free(root_dup);
                    self.watchSubdirRecursive(io, mount_id, root_dup, rel_path) catch {};
                }

                const name_copy = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(name_copy);

                try out.append(self.allocator, .{
                    .mount_id = mount_id,
                    .wd = ev.wd,
                    .mask = ev.mask,
                    .name = name_copy,
                    .rel_path = rel_path,
                    .is_dir = is_dir,
                });
                res.count += 1;
            }
        }
        return res;
    }

    pub fn poll(self: *SharedWatcher, io: Io, timeout_ms: i32, out: *std.ArrayList(WatchEvent)) !PollResult {
        const w = self.wait(timeout_ms);
        if (!w.ready) return .{ .count = 0, .woken = w.woken, .overflow = false };
        const d = try self.drain(io, out);
        return .{ .count = d.count, .woken = w.woken, .overflow = d.overflow };
    }
};
