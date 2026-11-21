const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const git_dirs = @import("git_dirs.zig");

pub const ForgeError = error{
    GhNotInstalled,
    PrFailed,
    InvalidResponse,
};

pub const RemoteUrl = struct {
    host: []u8,
    owner: []u8,
    repo: []u8,
    is_github: bool,

    pub fn deinit(self: *RemoteUrl, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.owner);
        allocator.free(self.repo);
    }

    pub fn slug(self: *const RemoteUrl, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.owner, self.repo });
    }

    pub fn webUrl(self: *const RemoteUrl, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}", .{ self.host, self.owner, self.repo });
    }

    pub fn parse(allocator: Allocator, raw_url: []const u8) Allocator.Error!?RemoteUrl {
        const url = std.mem.trim(u8, raw_url, " \t\r\n");
        if (url.len == 0) return null;

        var host_slice: []const u8 = "";
        var path_slice: []const u8 = "";

        if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
            const scheme = url[0..scheme_end];
            if (!isSupportedScheme(scheme)) return null;
            const rest = url[scheme_end + 3 ..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            const authority = rest[0..slash];
            path_slice = rest[slash + 1 ..];
            if (authority.len == 0) return null;

            const after_at = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
                authority[at + 1 ..]
            else
                authority;
            if (after_at.len == 0) return null;

            if (after_at[0] == '[') {
                const close = std.mem.indexOfScalar(u8, after_at, ']') orelse return null;
                host_slice = after_at[1..close];
            } else {
                const colon = std.mem.indexOfScalar(u8, after_at, ':');
                host_slice = if (colon) |c| after_at[0..c] else after_at;
            }
        } else {
            const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
            const authority = url[0..colon];
            path_slice = url[colon + 1 ..];
            if (authority.len == 0) return null;
            if (std.mem.indexOfScalar(u8, authority, '/') != null) return null;
            if (std.mem.indexOfScalar(u8, authority, '\\') != null) return null;
            if (std.mem.startsWith(u8, path_slice, "//")) return null;

            const after_at = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
                authority[at + 1 ..]
            else
                authority;
            if (after_at.len <= 1) return null;

            if (after_at[0] == '[') {
                const close = std.mem.indexOfScalar(u8, after_at, ']') orelse return null;
                host_slice = after_at[1..close];
            } else {
                host_slice = after_at;
            }
        }

        if (host_slice.len == 0) return null;
        for (host_slice) |c| {
            if (c <= 0x20 or c == '/' or c == '\\') return null;
        }

        const trimmed_path = std.mem.trim(u8, path_slice, "/");
        if (trimmed_path.len == 0) return null;

        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(allocator);
        var seg_it = std.mem.splitScalar(u8, trimmed_path, '/');
        while (seg_it.next()) |seg| {
            if (seg.len == 0) continue;
            try segments.append(allocator, seg);
        }
        if (segments.items.len < 2) return null;

        const last_seg = segments.items[segments.items.len - 1];
        const repo_slice = if (std.mem.endsWith(u8, last_seg, ".git"))
            last_seg[0 .. last_seg.len - 4]
        else
            last_seg;
        if (repo_slice.len == 0) return null;

        var owner_buf: std.ArrayList(u8) = .empty;
        errdefer owner_buf.deinit(allocator);
        for (segments.items[0 .. segments.items.len - 1], 0..) |seg, i| {
            if (i > 0) try owner_buf.append(allocator, '/');
            try owner_buf.appendSlice(allocator, seg);
        }
        if (owner_buf.items.len == 0) {
            owner_buf.deinit(allocator);
            return null;
        }

        const host_lower = try allocator.alloc(u8, host_slice.len);
        errdefer allocator.free(host_lower);
        for (host_slice, 0..) |c, i| {
            host_lower[i] = std.ascii.toLower(c);
        }

        const repo_copy = try allocator.dupe(u8, repo_slice);
        errdefer allocator.free(repo_copy);
        const owner_owned = try owner_buf.toOwnedSlice(allocator);
        errdefer allocator.free(owner_owned);

        const is_gh = std.mem.eql(u8, host_lower, "github.com") or
            std.mem.endsWith(u8, host_lower, ".github.com");

        return .{
            .host = host_lower,
            .owner = owner_owned,
            .repo = repo_copy,
            .is_github = is_gh,
        };
    }
};

pub const PrInfo = struct {
    number: u64,
    url: []u8,
    title: []u8,
    state: []u8,
    head_branch: []u8,
    base_branch: []u8,

    pub fn deinit(self: *PrInfo, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.title);
        allocator.free(self.state);
        allocator.free(self.head_branch);
        allocator.free(self.base_branch);
    }
};

fn isSupportedScheme(scheme: []const u8) bool {
    const allowed = [_][]const u8{ "https", "http", "ssh", "git", "git+ssh", "ssh+git" };
    for (allowed) |s| {
        if (std.ascii.eqlIgnoreCase(scheme, s)) return true;
    }
    return false;
}

fn readConfigFile(allocator: Allocator, io: Io, dir_path: []const u8, file_name: []const u8) !?[]u8 {
    var d = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer d.close(io);
    const f = d.openFile(io, file_name, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    if (st.kind != .file or st.size > 4 * 1024 * 1024) return null;
    const sz: usize = @intCast(st.size);
    const buf = try allocator.alloc(u8, sz);
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == sz) return buf;
    return try allocator.realloc(buf, n);
}

fn stripConfigComment(line: []const u8) []const u8 {
    var in_quotes = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and in_quotes and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (!in_quotes and (c == '#' or c == ';')) {
            return line[0..i];
        }
    }
    return line;
}

fn isOriginRemoteSection(header: []const u8) bool {
    const trimmed = std.mem.trim(u8, header, " \t");
    if (trimmed.len < 6) return false;
    var sep: usize = 0;
    while (sep < trimmed.len and trimmed[sep] != ' ' and trimmed[sep] != '\t' and trimmed[sep] != '"') : (sep += 1) {}
    const sec_name = trimmed[0..sep];
    if (!std.ascii.eqlIgnoreCase(sec_name, "remote")) return false;
    const rest = std.mem.trim(u8, trimmed[sep..], " \t");
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return false;
    const inner = rest[1 .. rest.len - 1];
    return std.mem.eql(u8, inner, "origin");
}

fn unquoteConfigValue(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_quotes = false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (c == '\\' and i + 1 < trimmed.len) {
            i += 1;
            switch (trimmed[i]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'b' => try out.append(allocator, 0x08),
                else => |esc| try out.append(allocator, esc),
            }
            continue;
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn extractOriginUrlFromConfig(allocator: Allocator, raw: []const u8, current: *?[]u8) Allocator.Error!void {
    var in_origin = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const stripped = stripConfigComment(line_raw);
        const line = std.mem.trim(u8, stripped, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_origin = isOriginRemoteSection(line[1..close]);
            continue;
        }
        if (!in_origin) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "url")) continue;
        const val = try unquoteConfigValue(allocator, line[eq + 1 ..]);
        if (current.*) |prev| allocator.free(prev);
        current.* = val;
    }
}

pub fn originRemoteUrl(allocator: Allocator, io: Io, dir_path: []const u8) !?RemoteUrl {
    var dirs = (try git_dirs.GitDirs.locate(allocator, io, dir_path)) orelse return null;
    defer dirs.deinit(allocator);

    var found_url: ?[]u8 = null;
    defer if (found_url) |u| allocator.free(u);

    if (try readConfigFile(allocator, io, dirs.common_dir, "config")) |raw| {
        defer allocator.free(raw);
        try extractOriginUrlFromConfig(allocator, raw, &found_url);
    }
    if (try readConfigFile(allocator, io, dirs.git_dir, "config.worktree")) |raw| {
        defer allocator.free(raw);
        try extractOriginUrlFromConfig(allocator, raw, &found_url);
    }

    const raw_url = found_url orelse return null;
    return try RemoteUrl.parse(allocator, raw_url);
}

fn loadParentEnv(io: Io, env_map: *process.Environ.Map) void {
    var buf: [65536]u8 = undefined;
    var len: usize = 0;
    if (Io.Dir.cwd().openFile(io, "/proc/self/environ", .{})) |ef| {
        defer ef.close(io);
        len = ef.readPositionalAll(io, &buf, 0) catch 0;
    } else |_| {}
    var it = std.mem.splitScalar(u8, buf[0..len], 0);
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

fn runGh(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    host_opt: ?[]const u8,
    args: []const []const u8,
) (ForgeError || Allocator.Error)!struct { stdout: []u8, stderr: []u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "gh");
    try argv.appendSlice(allocator, args);

    var env_map = process.Environ.Map.init(allocator);
    defer env_map.deinit();
    loadParentEnv(io, &env_map);
    try env_map.put("GH_PROMPT_DISABLED", "1");
    try env_map.put("GH_NO_UPDATE_NOTIFIER", "1");
    try env_map.put("NO_COLOR", "1");
    if (host_opt) |h| {
        try env_map.put("GH_HOST", h);
    }

    const res = process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GhNotInstalled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.PrFailed,
    };

    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
        return error.PrFailed;
    }
    return .{ .stdout = res.stdout, .stderr = res.stderr };
}

fn parsePrNumberFromUrl(url: []const u8) u64 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, url, " \t\r\n"), "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return 0;
    return std.fmt.parseInt(u64, trimmed[slash + 1 ..], 10) catch 0;
}

pub fn parsePrJson(allocator: Allocator, json_bytes: []const u8) (ForgeError || Allocator.Error)!PrInfo {
    const RawPr = struct {
        number: u64 = 0,
        url: []const u8 = "",
        title: []const u8 = "",
        state: []const u8 = "",
        headRefName: []const u8 = "",
        baseRefName: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(RawPr, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
    defer parsed.deinit();

    const v = parsed.value;
    if (v.number == 0 or v.url.len == 0) return error.InvalidResponse;

    const url_copy = try allocator.dupe(u8, v.url);
    errdefer allocator.free(url_copy);
    const title_copy = try allocator.dupe(u8, v.title);
    errdefer allocator.free(title_copy);
    const state_copy = try allocator.dupe(u8, if (v.state.len > 0) v.state else "OPEN");
    errdefer allocator.free(state_copy);
    const head_copy = try allocator.dupe(u8, v.headRefName);
    errdefer allocator.free(head_copy);
    const base_copy = try allocator.dupe(u8, v.baseRefName);
    errdefer allocator.free(base_copy);

    return .{
        .number = v.number,
        .url = url_copy,
        .title = title_copy,
        .state = state_copy,
        .head_branch = head_copy,
        .base_branch = base_copy,
    };
}

pub fn createGitHubPr(
    allocator: Allocator,
    io: Io,
    dir_path: []const u8,
    title: []const u8,
    body: []const u8,
    base: ?[]const u8,
    draft: bool,
) !PrInfo {
    var remote_opt = originRemoteUrl(allocator, io, dir_path) catch null;
    defer if (remote_opt) |*r| r.deinit(allocator);
    const host_opt: ?[]const u8 = if (remote_opt) |r| r.host else null;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "pr", "create", "--title", title, "--body", body });
    if (base) |b| {
        try args.appendSlice(allocator, &.{ "--base", b });
    }
    if (draft) {
        try args.append(allocator, "--draft");
    }
    try args.append(allocator, "--");

    const create_res = try runGh(allocator, io, dir_path, host_opt, args.items);
    defer allocator.free(create_res.stdout);
    defer allocator.free(create_res.stderr);

    var pr_url_slice: []const u8 = "";
    var lines = std.mem.splitScalar(u8, create_res.stdout, '\n');
    while (lines.next()) |line_raw| {
        const t = std.mem.trim(u8, line_raw, " \t\r");
        if (t.len > 0) pr_url_slice = t;
    }
    if (pr_url_slice.len == 0) return error.InvalidResponse;

    if (runGh(allocator, io, dir_path, host_opt, &.{
        "pr",
        "view",
        "--json",
        "number,url,title,state,headRefName,baseRefName",
        "--",
        pr_url_slice,
    })) |view_res| {
        defer allocator.free(view_res.stdout);
        defer allocator.free(view_res.stderr);
        if (parsePrJson(allocator, view_res.stdout)) |info| {
            return info;
        } else |_| {}
    } else |_| {}

    var head_branch: ?[]u8 = null;
    errdefer if (head_branch) |hb| allocator.free(hb);
    if (git_dirs.GitDirs.locate(allocator, io, dir_path) catch null) |dirs_val| {
        var dirs = dirs_val;
        defer dirs.deinit(allocator);
        if (dirs.readHead(allocator, io) catch null) |hs_val| {
            var hs = hs_val;
            head_branch = hs.branch;
            hs.branch = null;
            hs.deinit(allocator);
        }
    }

    const url_copy = try allocator.dupe(u8, pr_url_slice);
    errdefer allocator.free(url_copy);
    const title_copy = try allocator.dupe(u8, title);
    errdefer allocator.free(title_copy);
    const state_copy = try allocator.dupe(u8, "OPEN");
    errdefer allocator.free(state_copy);
    const head_copy = head_branch orelse try allocator.dupe(u8, "");
    head_branch = null;
    errdefer allocator.free(head_copy);
    const base_copy = try allocator.dupe(u8, base orelse "");
    errdefer allocator.free(base_copy);

    return .{
        .number = parsePrNumberFromUrl(pr_url_slice),
        .url = url_copy,
        .title = title_copy,
        .state = state_copy,
        .head_branch = head_copy,
        .base_branch = base_copy,
    };
}

pub fn openPrInBrowser(allocator: Allocator, io: Io, dir_path: []const u8) !void {
    var remote_opt = originRemoteUrl(allocator, io, dir_path) catch null;
    defer if (remote_opt) |*r| r.deinit(allocator);
    const host_opt: ?[]const u8 = if (remote_opt) |r| r.host else null;

    const res = try runGh(allocator, io, dir_path, host_opt, &.{ "pr", "view", "--web", "--" });
    allocator.free(res.stdout);
    allocator.free(res.stderr);
}
