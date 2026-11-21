const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const git = @import("git.zig");
const watch = @import("watch.zig");

pub const VcsKind = enum(u8) {
    none = 0,
    git = 1,

    pub fn slug(self: VcsKind) []const u8 {
        return switch (self) {
            .none => "none",
            .git => "git",
        };
    }

    pub fn parseSlug(s: []const u8) VcsKind {
        if (std.mem.eql(u8, s, "git")) return .git;
        return .none;
    }
};

pub const VcsHead = struct {
    kind: VcsKind = .none,
    ref_name: ?[]u8 = null,
    rev: ?[]u8 = null,

    pub fn deinit(self: *VcsHead, allocator: Allocator) void {
        if (self.ref_name) |r| allocator.free(r);
        if (self.rev) |c| allocator.free(c);
    }
};

pub const VcsRepo = struct {
    kind: VcsKind,
    root: []u8,

    pub fn deinit(self: *VcsRepo, allocator: Allocator) void {
        allocator.free(self.root);
    }
};

pub const VcsError = error{
    VcsFailed,
    VcsOperationInProgress,
    RevMissing,
};

pub const VcsBackend = struct {
    kind: VcsKind,
    marker: ?[]const u8,
    detect_root: *const fn (allocator: Allocator, io: Io, dir_path: []const u8) anyerror!?[]u8,
    head: *const fn (allocator: Allocator, io: Io, dir_path: []const u8) anyerror!VcsHead,
    operation_in_progress: *const fn (allocator: Allocator, io: Io, dir_path: []const u8) ?[]const u8,
    move_head_safe: *const fn (allocator: Allocator, io: Io, dir_path: []const u8, ref_name: ?[]const u8, rev: []const u8) anyerror!void,
    is_clean: *const fn (allocator: Allocator, io: Io, dir_path: []const u8) anyerror!bool,
    add_workspace: *const fn (allocator: Allocator, io: Io, repo_root: []const u8, dest_path: []const u8, ref_name: ?[]const u8, rev: ?[]const u8) anyerror!void,
    remove_workspace: *const fn (allocator: Allocator, io: Io, repo_root: ?[]const u8, dest_path: []const u8, ref_name: ?[]const u8, delete_ref: bool) anyerror!void,
};

fn findMarkerRoot(allocator: Allocator, io: Io, dir_path: []const u8, marker: []const u8) !?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur: []const u8 = if (Io.Dir.cwd().realPathFile(io, dir_path, &path_buf)) |n|
        path_buf[0..n]
    else |_|
        dir_path;

    while (true) {
        var dir = Io.Dir.cwd().openDir(io, cur, .{}) catch return null;
        const found = if (dir.statFile(io, marker, .{})) |_| true else |_| false;
        dir.close(io);
        if (found) return try allocator.dupe(u8, cur);
        const parent = std.fs.path.dirname(cur) orelse return null;
        if (parent.len == cur.len) return null;
        cur = parent;
    }
}

fn noneDetectRoot(allocator: Allocator, io: Io, dir_path: []const u8) !?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canon = if (Io.Dir.cwd().realPathFile(io, dir_path, &path_buf)) |n|
        path_buf[0..n]
    else |_|
        dir_path;
    return try allocator.dupe(u8, canon);
}

fn noneHead(_: Allocator, _: Io, _: []const u8) !VcsHead {
    return .{};
}

fn noneOpInProgress(_: Allocator, _: Io, _: []const u8) ?[]const u8 {
    return null;
}

fn noneMoveHeadSafe(_: Allocator, _: Io, _: []const u8, _: ?[]const u8, _: []const u8) !void {}

fn noneIsClean(_: Allocator, io: Io, dir_path: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".0ndb")) continue;
        return false;
    }
    return true;
}

fn noneAddWorkspace(_: Allocator, io: Io, _: []const u8, dest_path: []const u8, _: ?[]const u8, _: ?[]const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dest_path);
}

fn noneRemoveWorkspace(_: Allocator, io: Io, _: ?[]const u8, dest_path: []const u8, _: ?[]const u8, _: bool) !void {
    Io.Dir.cwd().deleteTree(io, dest_path) catch {};
}

fn gitDetectRoot(allocator: Allocator, io: Io, dir_path: []const u8) !?[]u8 {
    if (try git.mainCheckout(allocator, io, dir_path)) |root| return root;
    return try findMarkerRoot(allocator, io, dir_path, ".git");
}

fn gitHead(allocator: Allocator, io: Io, dir_path: []const u8) !VcsHead {
    const gi = try git.head(allocator, io, dir_path);
    return .{
        .kind = .git,
        .ref_name = gi.branch,
        .rev = gi.commit,
    };
}

fn gitOpInProgress(allocator: Allocator, io: Io, dir_path: []const u8) ?[]const u8 {
    return git.operationInProgress(allocator, io, dir_path);
}

fn gitMoveHeadSafe(allocator: Allocator, io: Io, dir_path: []const u8, ref_name: ?[]const u8, rev: []const u8) !void {
    git.moveHeadSafe(allocator, io, dir_path, ref_name, rev) catch |err| switch (err) {
        error.GitOperationInProgress => return error.VcsOperationInProgress,
        error.CommitMissing => return error.RevMissing,
        else => return error.VcsFailed,
    };
}

fn gitIsClean(allocator: Allocator, io: Io, dir_path: []const u8) !bool {
    return git.isClean(allocator, io, dir_path) catch return error.VcsFailed;
}

fn gitAddWorkspace(allocator: Allocator, io: Io, repo_root: []const u8, dest_path: []const u8, ref_name: ?[]const u8, rev: ?[]const u8) !void {
    const target_rev = rev orelse "HEAD";
    git.addWorktree(allocator, io, repo_root, dest_path, ref_name, target_rev) catch return error.VcsFailed;
}

fn gitRemoveWorkspace(allocator: Allocator, io: Io, repo_root: ?[]const u8, dest_path: []const u8, ref_name: ?[]const u8, delete_ref: bool) !void {
    if (repo_root) |rr| {
        git.removeWorktree(allocator, io, rr, dest_path) catch {
            Io.Dir.cwd().deleteTree(io, dest_path) catch {};
        };
        if (delete_ref) {
            if (ref_name) |b| {
                git.deleteBranch(allocator, io, rr, b) catch {};
            }
        }
    } else {
        Io.Dir.cwd().deleteTree(io, dest_path) catch {};
    }
}

pub const NONE_BACKEND = VcsBackend{
    .kind = .none,
    .marker = null,
    .detect_root = noneDetectRoot,
    .head = noneHead,
    .operation_in_progress = noneOpInProgress,
    .move_head_safe = noneMoveHeadSafe,
    .is_clean = noneIsClean,
    .add_workspace = noneAddWorkspace,
    .remove_workspace = noneRemoveWorkspace,
};

pub const GIT_BACKEND = VcsBackend{
    .kind = .git,
    .marker = ".git",
    .detect_root = gitDetectRoot,
    .head = gitHead,
    .operation_in_progress = gitOpInProgress,
    .move_head_safe = gitMoveHeadSafe,
    .is_clean = gitIsClean,
    .add_workspace = gitAddWorkspace,
    .remove_workspace = gitRemoveWorkspace,
};

pub const REGISTERED_BACKENDS = [_]*const VcsBackend{
    &GIT_BACKEND,
};

pub fn backendFor(kind: VcsKind) *const VcsBackend {
    return switch (kind) {
        .none => &NONE_BACKEND,
        .git => &GIT_BACKEND,
    };
}

pub fn detectKind(io: Io, dir_path: []const u8) VcsKind {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur: []const u8 = if (Io.Dir.cwd().realPathFile(io, dir_path, &path_buf)) |n|
        path_buf[0..n]
    else |_|
        dir_path;

    while (true) {
        var dir = Io.Dir.cwd().openDir(io, cur, .{}) catch return .none;
        for (REGISTERED_BACKENDS) |backend| {
            if (backend.marker) |m| {
                if (dir.statFile(io, m, .{})) |_| {
                    dir.close(io);
                    return backend.kind;
                } else |_| {}
            }
        }
        dir.close(io);
        const parent = std.fs.path.dirname(cur) orelse return .none;
        if (parent.len == cur.len) return .none;
        cur = parent;
    }
}

pub fn detect(allocator: Allocator, io: Io, dir_path: []const u8) !VcsRepo {
    const kind = detectKind(io, dir_path);
    const backend = backendFor(kind);
    if (try backend.detect_root(allocator, io, dir_path)) |root| {
        return .{ .kind = kind, .root = root };
    }
    const fallback = (try NONE_BACKEND.detect_root(allocator, io, dir_path)) orelse try allocator.dupe(u8, dir_path);
    return .{ .kind = .none, .root = fallback };
}

pub fn head(allocator: Allocator, io: Io, dir_path: []const u8) !VcsHead {
    return try backendFor(detectKind(io, dir_path)).head(allocator, io, dir_path);
}

pub fn operationInProgress(allocator: Allocator, io: Io, dir_path: []const u8) ?[]const u8 {
    return backendFor(detectKind(io, dir_path)).operation_in_progress(allocator, io, dir_path);
}

pub fn moveHeadSafe(allocator: Allocator, io: Io, dir_path: []const u8, ref_name: ?[]const u8, rev: []const u8) !void {
    try backendFor(detectKind(io, dir_path)).move_head_safe(allocator, io, dir_path, ref_name, rev);
}

pub fn isClean(allocator: Allocator, io: Io, dir_path: []const u8) !bool {
    return try backendFor(detectKind(io, dir_path)).is_clean(allocator, io, dir_path);
}

pub fn addWorkspace(
    allocator: Allocator,
    io: Io,
    kind: VcsKind,
    repo_root: []const u8,
    dest_path: []const u8,
    ref_name: ?[]const u8,
    rev: ?[]const u8,
) !void {
    try backendFor(kind).add_workspace(allocator, io, repo_root, dest_path, ref_name, rev);
}

pub fn removeWorkspace(
    allocator: Allocator,
    io: Io,
    kind: VcsKind,
    repo_root: ?[]const u8,
    dest_path: []const u8,
    ref_name: ?[]const u8,
    delete_ref: bool,
) !void {
    try backendFor(kind).remove_workspace(allocator, io, repo_root, dest_path, ref_name, delete_ref);
}

pub fn copyDirFiles(allocator: Allocator, io: Io, src_root: []const u8, dst_root: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dst_root);
    var src = try Io.Dir.cwd().openDir(io, src_root, .{ .iterate = true });
    defer src.close(io);
    var dst = try Io.Dir.cwd().openDir(io, dst_root, .{ .iterate = true });
    defer dst.close(io);
    try copyDirRecursive(allocator, io, src, dst);
}

fn copyDirRecursive(allocator: Allocator, io: Io, src: Io.Dir, dst: Io.Dir) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (watch.isIgnoredName(entry.name)) continue;
        switch (entry.kind) {
            .directory => {
                try dst.createDirPath(io, entry.name);
                var sub_src = try src.openDir(io, entry.name, .{ .iterate = true });
                defer sub_src.close(io);
                var sub_dst = try dst.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dst.close(io);
                try copyDirRecursive(allocator, io, sub_src, sub_dst);
            },
            .file => {
                const sf = try src.openFile(io, entry.name, .{});
                defer sf.close(io);
                const st = try sf.stat(io);
                if (st.size > 64 * 1024 * 1024) continue;
                const buf = try allocator.alloc(u8, @intCast(st.size));
                defer allocator.free(buf);
                const n = try sf.readPositionalAll(io, buf, 0);
                const df = try dst.createFile(io, entry.name, .{ .truncate = true });
                defer df.close(io);
                try df.writeStreamingAll(io, buf[0..n]);
            },
            else => {},
        }
    }
}
