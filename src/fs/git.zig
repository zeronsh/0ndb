const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;

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

fn loadParentEnv(io: Io, env_map: *process.Environ.Map) void {
    var env_buf: [65536]u8 = undefined;
    if (Io.Dir.cwd().openFile(io, "/proc/self/environ", .{})) |ef| {
        defer ef.close(io);
        const n = ef.readPositionalAll(io, &env_buf, 0) catch 0;
        var it = std.mem.splitScalar(u8, env_buf[0..n], 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (eq == 0) continue;
            env_map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
        }
    } else |_| {}
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

fn hasGitMarker(io: Io, dir_path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cur: []const u8 = if (Io.Dir.cwd().realPathFile(io, dir_path, &path_buf)) |n|
        path_buf[0..n]
    else |_|
        dir_path;

    while (true) {
        var dir = Io.Dir.cwd().openDir(io, cur, .{}) catch return false;
        const found = if (dir.statFile(io, ".git", .{})) |_| true else |_| false;
        dir.close(io);
        if (found) return true;
        const parent = std.fs.path.dirname(cur) orelse return false;
        if (parent.len == cur.len) return false;
        cur = parent;
    }
}

pub fn isGitRepo(allocator: Allocator, io: Io, dir_path: []const u8) bool {
    if (!hasGitMarker(io, dir_path)) return false;
    const r = runGit(allocator, io, dir_path, &.{ "rev-parse", "--is-inside-work-tree" }) catch return false;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return r.ok and std.mem.eql(u8, trimLine(r.stdout), "true");
}

pub fn head(allocator: Allocator, io: Io, dir_path: []const u8) !HeadInfo {
    var info = HeadInfo{};
    if (!hasGitMarker(io, dir_path)) return info;
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
    var spec_buf: [128]u8 = undefined;
    const spec = std.fmt.bufPrint(&spec_buf, "{s}^{{commit}}", .{commit}) catch return false;
    const r = runGit(allocator, io, dir_path, &.{ "cat-file", "-e", spec }) catch return false;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return r.ok;
}

pub fn branchTip(allocator: Allocator, io: Io, dir_path: []const u8, branch: []const u8) !?[]u8 {
    var ref_buf: [256]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buf, "refs/heads/{s}", .{branch}) catch return null;
    const r = try runGit(allocator, io, dir_path, &.{ "rev-parse", "--verify", ref });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return null;
    const t = trimLine(r.stdout);
    if (t.len == 0) return null;
    return try allocator.dupe(u8, t);
}

pub fn operationInProgress(allocator: Allocator, io: Io, dir_path: []const u8) ?[]const u8 {
    if (!hasGitMarker(io, dir_path)) return null;
    const r = runGit(allocator, io, dir_path, &.{ "rev-parse", "--git-dir" }) catch return null;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return null;
    const git_dir_rel = trimLine(r.stdout);
    var base = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer base.close(io);
    var gd = base.openDir(io, git_dir_rel, .{}) catch return null;
    defer gd.close(io);

    const markers = .{
        .{ "MERGE_HEAD", "merge" },
        .{ "REBASE_HEAD", "rebase" },
        .{ "CHERRY_PICK_HEAD", "cherry-pick" },
        .{ "REVERT_HEAD", "revert" },
        .{ "rebase-merge", "rebase" },
        .{ "rebase-apply", "rebase" },
    };
    inline for (markers) |m| {
        if (gd.statFile(io, m[0], .{})) |_| {
            return m[1];
        } else |_| {}
    }
    return null;
}

pub fn createBranchAt(allocator: Allocator, io: Io, dir_path: []const u8, branch: []const u8, commit: []const u8) !void {
    const r = try runGit(allocator, io, dir_path, &.{ "branch", branch, commit });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn moveHeadSafe(allocator: Allocator, io: Io, dir_path: []const u8, branch: ?[]const u8, commit: []const u8) !void {
    if (!hasGitMarker(io, dir_path)) return error.GitFailed;
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
        const r = try runGit(allocator, io, dir_path, &.{ "symbolic-ref", "-m", "checkout: 0ndb restore", "HEAD", ref });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (!r.ok) return error.GitFailed;
    } else {
        const r = try runGit(allocator, io, dir_path, &.{ "update-ref", "--no-deref", "-m", "checkout: 0ndb restore", "HEAD", commit });
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
        try args.append(allocator, dest_path);
        try args.append(allocator, commit);
    } else {
        try args.append(allocator, "--detach");
        try args.append(allocator, dest_path);
        try args.append(allocator, commit);
    }
    const r = try runGit(allocator, io, repo_path, args.items);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn removeWorktree(allocator: Allocator, io: Io, repo_path: []const u8, dest_path: []const u8) !void {
    const r = try runGit(allocator, io, repo_path, &.{ "worktree", "remove", "--force", dest_path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn deleteBranch(allocator: Allocator, io: Io, repo_path: []const u8, branch: []const u8) !void {
    const r = try runGit(allocator, io, repo_path, &.{ "branch", "-D", branch });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
}

pub fn isClean(allocator: Allocator, io: Io, dir_path: []const u8) !bool {
    if (!hasGitMarker(io, dir_path)) return true;
    const r = try runGit(allocator, io, dir_path, &.{ "status", "--porcelain" });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return error.GitFailed;
    return trimLine(r.stdout).len == 0;
}

pub fn mainCheckout(allocator: Allocator, io: Io, dir_path: []const u8) !?[]u8 {
    if (!hasGitMarker(io, dir_path)) return null;
    const r = runGit(allocator, io, dir_path, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }) catch return null;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!r.ok) return null;
    const common = trimLine(r.stdout);
    if (common.len == 0) return null;
    if (std.mem.endsWith(u8, common, "/.git")) {
        return try allocator.dupe(u8, common[0 .. common.len - 5]);
    }
    const top = runGit(allocator, io, dir_path, &.{ "rev-parse", "--show-toplevel" }) catch return null;
    defer allocator.free(top.stdout);
    defer allocator.free(top.stderr);
    if (!top.ok) return null;
    const t = trimLine(top.stdout);
    if (t.len == 0) return null;
    return try allocator.dupe(u8, t);
}
