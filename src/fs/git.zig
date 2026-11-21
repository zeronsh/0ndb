const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const git_dirs = @import("git_dirs.zig");
const watch = @import("watch.zig");

const FICLONE: u32 = 0x40049409;

var env_cache_mutex: Io.Mutex = .init;
var env_cache_loaded: std.atomic.Value(bool) = .init(false);
var env_cache_buf: [65536]u8 = undefined;
var env_cache_len: usize = 0;

pub const HeadInfo = struct {
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,

    pub fn deinit(self: *HeadInfo, allocator: Allocator) void {
        if (self.branch) |b| allocator.free(b);
        if (self.commit) |c| allocator.free(c);
    }
};

pub const GitError = error{
    GitFailed,
    GitOperationInProgress,
    CommitMissing,
};

fn ensureParentEnvLoaded(io: Io) []const u8 {
    if (env_cache_loaded.load(.acquire)) {
        return env_cache_buf[0..env_cache_len];
    }
    env_cache_mutex.lockUncancelable(io);
    defer env_cache_mutex.unlock(io);
    if (!env_cache_loaded.load(.monotonic)) {
        if (Io.Dir.cwd().openFile(io, "/proc/self/environ", .{})) |ef| {
            defer ef.close(io);
            env_cache_len = ef.readPositionalAll(io, &env_cache_buf, 0) catch 0;
        } else |_| {
            env_cache_len = 0;
        }
        env_cache_loaded.store(true, .release);
    }
    return env_cache_buf[0..env_cache_len];
}

fn loadParentEnv(io: Io, env_map: *process.Environ.Map) void {
    const raw = ensureParentEnvLoaded(io);
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        env_map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
    }
    if (env_map.get("PATH") == null) {
        env_map.put("PATH", "/usr/local/bin:/usr/bin:/bin") catch {};
    }
}

fn runGit(allocator: Allocator, io: Io, cwd: []const u8, args: []const []const u8) !struct { ok: bool, stdout: []u8, stderr: []u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-c");
    try argv.append(allocator, "core.fsmonitor=false");
    try argv.appendSlice(allocator, args);

    var env_map = process.Environ.Map.init(allocator);
    defer env_map.deinit();
    loadParentEnv(io, &env_map);
    try env_map.put("GIT_OPTIONAL_LOCKS", "0");
    try env_map.put("GIT_TERMINAL_PROMPT", "0");

    const res = try process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = res.stdout, .stderr = res.stderr };
}

fn trimLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn isGitRepo(allocator: Allocator, io: Io, dir_path: []const u8) bool {
    var dirs = (git_dirs.GitDirs.locate(allocator, io, dir_path) catch return false) orelse return false;
    dirs.deinit(allocator);
    return true;
}

pub fn head(allocator: Allocator, io: Io, dir_path: []const u8) !HeadInfo {
    var dirs = (try git_dirs.GitDirs.locate(allocator, io, dir_path)) orelse return HeadInfo{};
    defer dirs.deinit(allocator);

    if (!dirs.config.reftable) {
        const hs = try dirs.readHead(allocator, io);
        return .{
            .branch = hs.branch,
            .commit = hs.commit,
        };
    }

    var info = HeadInfo{};
    errdefer info.deinit(allocator);

    const rev = runGit(allocator, io, dir_path, &.{ "rev-parse", "--verify", "HEAD" }) catch return info;
    defer allocator.free(rev.stdout);
    defer allocator.free(rev.stderr);
    if (rev.ok) {
        const trimmed = trimLine(rev.stdout);
        if (trimmed.len > 0) info.commit = try allocator.dupe(u8, trimmed);
    }

    const sym = runGit(allocator, io, dir_path, &.{ "symbolic-ref", "--short", "-q", "HEAD" }) catch return info;
    defer allocator.free(sym.stdout);
    defer allocator.free(sym.stderr);
    if (sym.ok) {
        const trimmed = trimLine(sym.stdout);
        if (trimmed.len > 0) info.branch = try allocator.dupe(u8, trimmed);
    }
    return info;
}

pub fn commitExists(allocator: Allocator, io: Io, dir_path: []const u8, commit: []const u8) bool {
    if (commit.len == 0 or commit[0] == '-') return false;
    var spec_buf: [128]u8 = undefined;
    const spec = std.fmt.bufPrint(&spec_buf, "{s}^{{commit}}", .{commit}) catch return false;
    const r = runGit(allocator, io, dir_path, &.{ "cat-file", "-e", "--", spec }) catch return false;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return r.ok;
}

pub fn branchTip(allocator: Allocator, io: Io, dir_path: []const u8, branch: []const u8) !?[]u8 {
    var dirs = (try git_dirs.GitDirs.locate(allocator, io, dir_path)) orelse return null;
    defer dirs.deinit(allocator);

    var ref_buf: [256]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{branch}) catch return null;
    if (!dirs.config.reftable) {
        return try dirs.resolveRef(allocator, io, ref);
    }

    const r = try runGit(allocator, io, dir_path, &.{ "rev-parse", "--verify", ref });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return null;
    const t = trimLine(r.stdout);
    if (t.len == 0) return null;
    return try allocator.dupe(u8, t);
}

pub fn operationInProgress(allocator: Allocator, io: Io, dir_path: []const u8) ?[]const u8 {
    var dirs = (git_dirs.GitDirs.locate(allocator, io, dir_path) catch return null) orelse return null;
    defer dirs.deinit(allocator);
    return dirs.operationInProgress(io);
}

pub fn createBranchAt(allocator: Allocator, io: Io, dir_path: []const u8, branch: []const u8, commit: []const u8) !void {
    if (branch.len == 0 or commit.len == 0 or commit[0] == '-') return error.GitFailed;
    const r = try runGit(allocator, io, dir_path, &.{ "branch", "--", branch, commit });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn moveHeadSafe(allocator: Allocator, io: Io, dir_path: []const u8, branch: ?[]const u8, commit: []const u8) !void {
    if (!isGitRepo(allocator, io, dir_path)) return error.GitFailed;
    var cur = head(allocator, io, dir_path) catch HeadInfo{};
    defer cur.deinit(allocator);
    if (cur.commit) |cc| {
        if (std.mem.eql(u8, cc, commit)) {
            if (branch) |b| {
                if (cur.branch) |cb| {
                    if (std.mem.eql(u8, cb, b)) return;
                }
            } else {
                return;
            }
        }
    }
    if (operationInProgress(allocator, io, dir_path) != null) return error.GitOperationInProgress;
    if (!commitExists(allocator, io, dir_path, commit)) return error.CommitMissing;

    var attach_branch = false;
    if (branch) |b| {
        if (try branchTip(allocator, io, dir_path, b)) |tip| {
            defer allocator.free(tip);
            if (std.mem.eql(u8, tip, commit)) {
                attach_branch = true;
            }
        }
    }

    if (attach_branch) {
        const b = branch.?;
        var ref_buf: [256]u8 = undefined;
        const ref = try std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{b});
        const r = try runGit(allocator, io, dir_path, &.{ "symbolic-ref", "-m", "checkout: 0ndb restore", "--", "HEAD", ref });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (!r.ok) return error.GitFailed;
    } else {
        const r = try runGit(allocator, io, dir_path, &.{ "update-ref", "--no-deref", "-m", "checkout: 0ndb restore", "--", "HEAD", commit });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (!r.ok) return error.GitFailed;
    }

    const reset_r = try runGit(allocator, io, dir_path, &.{ "reset", "--quiet", "--mixed" });
    defer allocator.free(reset_r.stdout);
    defer allocator.free(reset_r.stderr);
    if (!reset_r.ok) return error.GitFailed;
}

pub fn addWorktree(allocator: Allocator, io: Io, repo_path: []const u8, dest_path: []const u8, branch: ?[]const u8, commit: []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "worktree");
    try args.append(allocator, "add");
    if (branch) |b| {
        try args.append(allocator, "-b");
        try args.append(allocator, b);
        try args.append(allocator, "--");
        try args.append(allocator, dest_path);
        try args.append(allocator, commit);
    } else {
        try args.append(allocator, "--detach");
        try args.append(allocator, "--");
        try args.append(allocator, dest_path);
        try args.append(allocator, commit);
    }
    const r = try runGit(allocator, io, repo_path, args.items);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn removeWorktree(allocator: Allocator, io: Io, repo_path: []const u8, dest_path: []const u8) !void {
    const r = try runGit(allocator, io, repo_path, &.{ "worktree", "remove", "--force", "--", dest_path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn deleteBranch(allocator: Allocator, io: Io, repo_path: []const u8, branch: []const u8) !void {
    const r = try runGit(allocator, io, repo_path, &.{ "branch", "-D", "--", branch });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn isClean(allocator: Allocator, io: Io, dir_path: []const u8) !bool {
    if (!isGitRepo(allocator, io, dir_path)) return true;
    const r = try runGit(allocator, io, dir_path, &.{ "status", "--porcelain" });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
    return trimLine(r.stdout).len == 0;
}

pub fn mainCheckout(allocator: Allocator, io: Io, dir_path: []const u8) !?[]u8 {
    var dirs = (try git_dirs.GitDirs.locate(allocator, io, dir_path)) orelse return null;
    defer dirs.deinit(allocator);
    if (std.mem.endsWith(u8, dirs.common_dir, "/.git")) {
        return try allocator.dupe(u8, dirs.common_dir[0 .. dirs.common_dir.len - 5]);
    }
    return try allocator.dupe(u8, dirs.worktree_root);
}

pub fn freePaths(allocator: Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

pub fn changedPaths(allocator: Allocator, io: Io, dir_path: []const u8, rev_a: []const u8, rev_b: []const u8) ![][]u8 {
    if (rev_a.len == 0 or rev_b.len == 0 or rev_a[0] == '-' or rev_b[0] == '-') return error.GitFailed;
    const r = try runGit(allocator, io, dir_path, &.{ "diff", "--name-only", "-z", rev_a, rev_b, "--" });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, r.stdout, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, entry));
    }
    return try out.toOwnedSlice(allocator);
}

pub fn dirtyPaths(allocator: Allocator, io: Io, dir_path: []const u8) ![][]u8 {
    const r = try runGit(allocator, io, dir_path, &.{ "status", "--porcelain=v1", "-z", "-uall" });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var pos: usize = 0;
    while (pos < r.stdout.len) {
        const nul = std.mem.indexOfScalarPos(u8, r.stdout, pos, 0) orelse r.stdout.len;
        const rec = r.stdout[pos..nul];
        pos = if (nul < r.stdout.len) nul + 1 else r.stdout.len;
        if (rec.len < 4) continue;

        const x = rec[0];
        const y = rec[1];
        const path_a = rec[3..];
        if (path_a.len > 0 and !seen.contains(path_a)) {
            const owned = try allocator.dupe(u8, path_a);
            errdefer allocator.free(owned);
            try out.append(allocator, owned);
            try seen.put(allocator, owned, {});
        }

        if (x == 'R' or x == 'C' or y == 'R' or y == 'C') {
            if (pos < r.stdout.len) {
                const nul2 = std.mem.indexOfScalarPos(u8, r.stdout, pos, 0) orelse r.stdout.len;
                const path_b = r.stdout[pos..nul2];
                pos = if (nul2 < r.stdout.len) nul2 + 1 else r.stdout.len;
                if (path_b.len > 0 and !seen.contains(path_b)) {
                    const owned = try allocator.dupe(u8, path_b);
                    errdefer allocator.free(owned);
                    try out.append(allocator, owned);
                    try seen.put(allocator, owned, {});
                }
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn cloneDirReflink(allocator: Allocator, io: Io, src_root: []const u8, dst_root: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dst_root);
    var src = try Io.Dir.cwd().openDir(io, src_root, .{ .iterate = true });
    defer src.close(io);
    var dst = try Io.Dir.cwd().openDir(io, dst_root, .{ .iterate = true });
    defer dst.close(io);
    try cloneDirRecursive(allocator, io, src, dst);
}

fn cloneDirRecursive(allocator: Allocator, io: Io, src: Io.Dir, dst: Io.Dir) !void {
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
                try cloneDirRecursive(allocator, io, sub_src, sub_dst);
            },
            .file => {
                try cloneFileReflink(io, src, dst, entry.name);
            },
            .sym_link => {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = src.readLink(io, entry.name, &link_buf) catch continue;
                dst.symLink(io, link_buf[0..n], entry.name, .{}) catch {};
            },
            else => {},
        }
    }
}

fn cloneFileReflink(io: Io, src: Io.Dir, dst: Io.Dir, name: []const u8) !void {
    const sf = try src.openFile(io, name, .{});
    defer sf.close(io);
    const st = try sf.stat(io);

    const df = try dst.createFile(io, name, .{ .truncate = true });
    defer df.close(io);

    var reflinked = false;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.ioctl(df.handle, FICLONE, @intCast(sf.handle));
        if (linux.errno(rc) == .SUCCESS) {
            reflinked = true;
        }
    }

    if (!reflinked) {
        var buf: [65536]u8 = undefined;
        var off: u64 = 0;
        while (off < st.size) {
            const want: usize = @intCast(@min(@as(u64, buf.len), st.size - off));
            const n = try sf.readPositionalAll(io, buf[0..want], off);
            if (n == 0) break;
            try df.writePositionalAll(io, buf[0..n], off);
            off += n;
        }
    }

    df.setPermissions(io, st.permissions) catch {};
}
