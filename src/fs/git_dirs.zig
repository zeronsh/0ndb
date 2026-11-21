const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const ObjectFormat = enum(u8) {
    sha1 = 20,
    sha256 = 32,

    pub fn byteLen(self: ObjectFormat) usize {
        return @backingInt(self);
    }

    pub fn hexLen(self: ObjectFormat) usize {
        return @as(usize, @backingInt(self)) * 2;
    }
};

pub const GitOid = struct {
    len: u8,
    bytes: [32]u8,

    pub const ZERO: GitOid = .{
        .len = 20,
        .bytes = @splat(0),
    };

    pub fn zeroFor(fmt: ObjectFormat) GitOid {
        return .{
            .len = @backingInt(fmt),
            .bytes = @splat(0),
        };
    }

    pub fn fromSlice(raw: []const u8) error{InvalidOidLength}!GitOid {
        if (raw.len != 20 and raw.len != 32) return error.InvalidOidLength;
        var out: GitOid = .{
            .len = @intCast(raw.len),
            .bytes = @splat(0),
        };
        @memcpy(out.bytes[0..raw.len], raw);
        return out;
    }

    pub fn ofObject(fmt: ObjectFormat, kind_name: []const u8, data: []const u8) GitOid {
        var hdr_buf: [64]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {d}\x00", .{ kind_name, data.len }) catch unreachable;
        var out: GitOid = .{
            .len = @backingInt(fmt),
            .bytes = @splat(0),
        };
        switch (fmt) {
            .sha1 => {
                var h = Sha1.init(.{});
                h.update(hdr);
                h.update(data);
                var digest: [20]u8 = undefined;
                h.final(&digest);
                @memcpy(out.bytes[0..20], &digest);
            },
            .sha256 => {
                var h = Sha256.init(.{});
                h.update(hdr);
                h.update(data);
                var digest: [32]u8 = undefined;
                h.final(&digest);
                @memcpy(out.bytes[0..32], &digest);
            },
        }
        return out;
    }

    pub fn ofBlob(fmt: ObjectFormat, data: []const u8) GitOid {
        return ofObject(fmt, "blob", data);
    }

    pub fn fromHex(hex: []const u8) error{ InvalidHexLength, InvalidHexChar }!GitOid {
        if (hex.len != 40 and hex.len != 64) return error.InvalidHexLength;
        const n = hex.len / 2;
        var out: GitOid = .{
            .len = @intCast(n),
            .bytes = @splat(0),
        };
        for (0..n) |i| {
            const hi = hexNibble(hex[i * 2]) orelse return error.InvalidHexChar;
            const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidHexChar;
            out.bytes[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
        return out;
    }

    pub fn toHex(self: GitOid, buf: *[64]u8) []const u8 {
        const alphabet = "0123456789abcdef";
        const n: usize = self.len;
        for (0..n) |i| {
            const b = self.bytes[i];
            buf[i * 2] = alphabet[b >> 4];
            buf[i * 2 + 1] = alphabet[b & 0x0f];
        }
        return buf[0 .. n * 2];
    }

    pub fn slice(self: *const GitOid) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn isZero(self: GitOid) bool {
        for (self.bytes[0..self.len]) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    pub fn eql(a: GitOid, b: GitOid) bool {
        if (a.len != b.len) return false;
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    pub fn order(a: GitOid, b: GitOid) std.math.Order {
        return std.mem.order(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    pub const hashContext = struct {
        pub fn hash(_: @This(), k: GitOid) u64 {
            const w0 = std.mem.readInt(u64, k.bytes[0..8], .little);
            const w1 = std.mem.readInt(u64, k.bytes[8..16], .little);
            return w0 ^ w1 ^ @as(u64, k.len);
        }

        pub fn eql(_: @This(), a: GitOid, b: GitOid) bool {
            return a.eql(b);
        }
    };
};

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

pub fn isValidHexOid(s: []const u8, expected_fmt: ?ObjectFormat) bool {
    if (expected_fmt) |fmt| {
        if (s.len != fmt.hexLen()) return false;
    } else {
        if (s.len != 40 and s.len != 64) return false;
    }
    for (s) |c| {
        if (hexNibble(c) == null) return false;
    }
    return true;
}

pub const AutoCrlf = enum(u8) {
    off,
    on,
    input,
};

pub const GitConfigFlags = struct {
    object_format: ObjectFormat = .sha1,
    autocrlf: AutoCrlf = .off,
    eol_crlf: bool = false,
    filemode: bool = true,
    symlinks: bool = true,
    trustctime: bool = true,
    reftable: bool = false,
};

pub const IndexStamp = struct {
    mtime_ns: i96,
    size: u64,
    ino: u64,
};

pub const HeadState = struct {
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,

    pub fn deinit(self: *HeadState, allocator: Allocator) void {
        if (self.branch) |b| allocator.free(b);
        if (self.commit) |c| allocator.free(c);
        self.* = .{};
    }
};

pub const GitDirs = struct {
    worktree_root: []u8,
    git_dir: []u8,
    common_dir: []u8,
    config: GitConfigFlags,

    pub fn deinit(self: *GitDirs, allocator: Allocator) void {
        allocator.free(self.worktree_root);
        allocator.free(self.git_dir);
        allocator.free(self.common_dir);
    }

    pub fn locate(allocator: Allocator, io: Io, dir_path: []const u8) !?GitDirs {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const start_slice: []const u8 = if (Io.Dir.cwd().realPathFile(io, dir_path, &real_buf)) |n|
            real_buf[0..n]
        else |_|
            dir_path;

        var cur = trimTrailingSlash(start_slice);
        while (true) {
            var dir = Io.Dir.cwd().openDir(io, cur, .{}) catch return null;
            const st_opt = dir.statFile(io, ".git", .{}) catch null;
            if (st_opt) |st| {
                if (st.kind == .directory) {
                    dir.close(io);
                    const wt_root = try allocator.dupe(u8, cur);
                    errdefer allocator.free(wt_root);
                    const gd = try joinAndCanonicalize(allocator, io, cur, ".git");
                    errdefer allocator.free(gd);
                    const cd = try resolveCommonDir(allocator, io, gd);
                    errdefer allocator.free(cd);
                    const cfg = try loadConfigFlags(allocator, io, gd, cd);
                    return .{
                        .worktree_root = wt_root,
                        .git_dir = gd,
                        .common_dir = cd,
                        .config = cfg,
                    };
                } else if (st.kind == .file) {
                    const raw_gitfile = readSmallFile(allocator, io, dir, ".git", 64 * 1024) catch {
                        dir.close(io);
                        return null;
                    };
                    dir.close(io);
                    defer allocator.free(raw_gitfile);

                    const trimmed = std.mem.trim(u8, raw_gitfile, " \t\r\n");
                    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
                    const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
                    if (target.len == 0) return null;

                    const wt_root = try allocator.dupe(u8, cur);
                    errdefer allocator.free(wt_root);
                    const gd = try resolveRelativePath(allocator, io, cur, target);
                    errdefer allocator.free(gd);
                    const cd = try resolveCommonDir(allocator, io, gd);
                    errdefer allocator.free(cd);
                    const cfg = try loadConfigFlags(allocator, io, gd, cd);
                    return .{
                        .worktree_root = wt_root,
                        .git_dir = gd,
                        .common_dir = cd,
                        .config = cfg,
                    };
                }
            }
            dir.close(io);
            const parent = std.fs.path.dirname(cur) orelse return null;
            if (parent.len == cur.len) return null;
            cur = parent;
        }
    }

    pub fn readHead(self: *const GitDirs, allocator: Allocator, io: Io) !HeadState {
        var out = HeadState{};
        errdefer out.deinit(allocator);

        var gd = Io.Dir.cwd().openDir(io, self.git_dir, .{}) catch return out;
        defer gd.close(io);
        const raw = readSmallFile(allocator, io, gd, "HEAD", 4096) catch return out;
        defer allocator.free(raw);

        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return out;

        if (std.mem.startsWith(u8, line, "ref:")) {
            const ref_target = std.mem.trim(u8, line["ref:".len..], " \t\r\n");
            if (std.mem.startsWith(u8, ref_target, "refs/heads/")) {
                out.branch = try allocator.dupe(u8, ref_target["refs/heads/".len..]);
            }
            out.commit = try self.resolveRef(allocator, io, ref_target);
        } else if (isValidHexOid(line, null)) {
            out.commit = try allocator.dupe(u8, line);
        }
        return out;
    }

    pub fn resolveRef(self: *const GitDirs, allocator: Allocator, io: Io, ref_name: []const u8) !?[]u8 {
        var cur_ref = try allocator.dupe(u8, ref_name);
        defer allocator.free(cur_ref);

        var depth: usize = 0;
        while (depth < 8) : (depth += 1) {
            if (try self.readLooseRef(allocator, io, cur_ref)) |val| {
                defer allocator.free(val);
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                if (std.mem.startsWith(u8, trimmed, "ref:")) {
                    const next_ref = std.mem.trim(u8, trimmed["ref:".len..], " \t\r\n");
                    const owned = try allocator.dupe(u8, next_ref);
                    allocator.free(cur_ref);
                    cur_ref = owned;
                    continue;
                }
                if (isValidHexOid(trimmed, null)) {
                    return try allocator.dupe(u8, trimmed);
                }
                return null;
            }
            if (try self.readPackedRef(allocator, io, cur_ref)) |oid_hex| {
                return oid_hex;
            }
            return null;
        }
        return null;
    }

    fn readLooseRef(self: *const GitDirs, allocator: Allocator, io: Io, ref_name: []const u8) !?[]u8 {
        {
            var gd = Io.Dir.cwd().openDir(io, self.git_dir, .{}) catch null;
            if (gd) |*d| {
                defer d.close(io);
                if (readSmallFile(allocator, io, d.*, ref_name, 4096)) |raw| {
                    return raw;
                } else |_| {}
            }
        }
        if (!std.mem.eql(u8, self.git_dir, self.common_dir)) {
            var cd = Io.Dir.cwd().openDir(io, self.common_dir, .{}) catch null;
            if (cd) |*d| {
                defer d.close(io);
                if (readSmallFile(allocator, io, d.*, ref_name, 4096)) |raw| {
                    return raw;
                } else |_| {}
            }
        }
        return null;
    }

    fn readPackedRef(self: *const GitDirs, allocator: Allocator, io: Io, ref_name: []const u8) !?[]u8 {
        var cd = Io.Dir.cwd().openDir(io, self.common_dir, .{}) catch return null;
        defer cd.close(io);
        const raw = readSmallFile(allocator, io, cd, "packed-refs", 16 * 1024 * 1024) catch return null;
        defer allocator.free(raw);

        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const oid_part = line[0..sp];
            const name_part = line[sp + 1 ..];
            if (std.mem.eql(u8, name_part, ref_name) and isValidHexOid(oid_part, null)) {
                return try allocator.dupe(u8, oid_part);
            }
        }
        return null;
    }

    pub fn operationInProgress(self: *const GitDirs, io: Io) ?[]const u8 {
        var gd = Io.Dir.cwd().openDir(io, self.git_dir, .{}) catch return null;
        defer gd.close(io);

        const markers = .{
            .{ "MERGE_HEAD", "merge" },
            .{ "REBASE_HEAD", "rebase" },
            .{ "CHERRY_PICK_HEAD", "cherry-pick" },
            .{ "REVERT_HEAD", "revert" },
            .{ "rebase-merge", "rebase" },
            .{ "rebase-apply", "rebase" },
            .{ "BISECT_LOG", "bisect" },
        };
        inline for (markers) |m| {
            if (gd.statFile(io, m[0], .{})) |_| {
                return m[1];
            } else |_| {}
        }
        return null;
    }

    pub fn isBusy(self: *const GitDirs, io: Io) bool {
        var gd = Io.Dir.cwd().openDir(io, self.git_dir, .{}) catch return false;
        defer gd.close(io);
        if (gd.statFile(io, "index.lock", .{})) |_| return true else |_| {}
        if (gd.statFile(io, "HEAD.lock", .{})) |_| return true else |_| {}
        return false;
    }

    pub fn indexStamp(self: *const GitDirs, io: Io) !?IndexStamp {
        var gd = Io.Dir.cwd().openDir(io, self.git_dir, .{}) catch return null;
        defer gd.close(io);
        const st = gd.statFile(io, "index", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return .{
            .mtime_ns = st.mtime.nanoseconds,
            .size = st.size,
            .ino = st.inode,
        };
    }

    pub fn ensureExclude(self: *const GitDirs, io: Io) !void {
        var cd = try Io.Dir.cwd().openDir(io, self.common_dir, .{});
        defer cd.close(io);
        try cd.createDirPath(io, "info");

        var existing_buf: [65536]u8 = undefined;
        var existing_len: usize = 0;
        var file_exists = false;
        if (cd.openFile(io, "info/exclude", .{})) |ef| {
            defer ef.close(io);
            file_exists = true;
            const st = try ef.stat(io);
            if (st.size <= existing_buf.len) {
                existing_len = try ef.readPositionalAll(io, existing_buf[0..@intCast(st.size)], 0);
            } else {
                var off: u64 = 0;
                var line_buf: [128]u8 = undefined;
                var line_len: usize = 0;
                var overflow = false;
                while (off < st.size) {
                    const chunk = try ef.readPositionalAll(io, &existing_buf, off);
                    if (chunk == 0) break;
                    off += chunk;
                    for (existing_buf[0..chunk]) |b| {
                        if (b == '\n') {
                            if (!overflow) {
                                const ln = std.mem.trimEnd(u8, line_buf[0..line_len], "\r");
                                if (std.mem.eql(u8, ln, "/.0ndb/")) return;
                            }
                            line_len = 0;
                            overflow = false;
                        } else if (line_len < line_buf.len) {
                            line_buf[line_len] = b;
                            line_len += 1;
                        } else {
                            overflow = true;
                        }
                    }
                }
                if (!overflow and line_len > 0) {
                    const ln = std.mem.trimEnd(u8, line_buf[0..line_len], "\r");
                    if (std.mem.eql(u8, ln, "/.0ndb/")) return;
                }
                const wf = try cd.openFile(io, "info/exclude", .{ .mode = .read_write });
                defer wf.close(io);
                try wf.writePositionalAll(io, "\n/.0ndb/\n", st.size);
                return;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const existing = existing_buf[0..existing_len];
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (std.mem.eql(u8, line, "/.0ndb/")) return;
        }

        if (file_exists) {
            const wf = try cd.openFile(io, "info/exclude", .{ .mode = .read_write });
            defer wf.close(io);
            const suffix = if (existing.len == 0 or existing[existing.len - 1] == '\n') "/.0ndb/\n" else "\n/.0ndb/\n";
            try wf.writePositionalAll(io, suffix, existing.len);
        } else {
            const wf = try cd.createFile(io, "info/exclude", .{ .truncate = true });
            defer wf.close(io);
            try wf.writePositionalAll(io, "/.0ndb/\n", 0);
        }
    }

    pub fn hasCustomFilters(self: *const GitDirs, allocator: Allocator, io: Io) !bool {
        {
            var cd = Io.Dir.cwd().openDir(io, self.common_dir, .{}) catch null;
            if (cd) |*d| {
                defer d.close(io);
                if (readSmallFile(allocator, io, d.*, "info/attributes", 4 * 1024 * 1024)) |raw| {
                    defer allocator.free(raw);
                    if (attributesHaveCustomFilters(raw)) return true;
                } else |_| {}
            }
        }
        {
            var wt = Io.Dir.cwd().openDir(io, self.worktree_root, .{}) catch null;
            if (wt) |*d| {
                defer d.close(io);
                if (readSmallFile(allocator, io, d.*, ".gitattributes", 4 * 1024 * 1024)) |raw| {
                    defer allocator.free(raw);
                    if (attributesHaveCustomFilters(raw)) return true;
                } else |_| {}
            }
        }
        return false;
    }
};

fn attributesHaveCustomFilters(raw: []const u8) bool {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var pos: usize = 0;
        if (line[0] == '"') {
            pos = 1;
            while (pos < line.len) : (pos += 1) {
                if (line[pos] == '\\' and pos + 1 < line.len) {
                    pos += 1;
                    continue;
                }
                if (line[pos] == '"') {
                    pos += 1;
                    break;
                }
            }
        } else {
            while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') : (pos += 1) {}
        }
        const rest = std.mem.trim(u8, line[pos..], " \t");
        if (rest.len == 0) continue;

        var toks = std.mem.tokenizeAny(u8, rest, " \t");
        while (toks.next()) |tok| {
            if (tok.len == 0) continue;
            if (tok[0] == '-' or tok[0] == '!') continue;
            if (std.mem.startsWith(u8, tok, "filter=")) return true;
            if (std.mem.startsWith(u8, tok, "eol=")) return true;
            if (std.mem.startsWith(u8, tok, "working-tree-encoding=")) return true;
            if (std.mem.eql(u8, tok, "ident")) return true;
        }
    }
    return false;
}

fn trimTrailingSlash(p: []const u8) []const u8 {
    if (p.len <= 1) return p;
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') : (end -= 1) {}
    return p[0..end];
}

fn joinAndCanonicalize(allocator: Allocator, io: Io, base: []const u8, child: []const u8) ![]u8 {
    const joined = try std.fs.path.join(allocator, &.{ base, child });
    defer allocator.free(joined);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().realPathFile(io, joined, &real_buf)) |n| {
        return try allocator.dupe(u8, trimTrailingSlash(real_buf[0..n]));
    } else |_| {
        return try allocator.dupe(u8, trimTrailingSlash(joined));
    }
}

fn resolveRelativePath(allocator: Allocator, io: Io, base_dir: []const u8, target: []const u8) ![]u8 {
    const combined = if (std.fs.path.isAbsolute(target))
        try allocator.dupe(u8, target)
    else
        try std.fs.path.join(allocator, &.{ base_dir, target });
    defer allocator.free(combined);

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().realPathFile(io, combined, &real_buf)) |n| {
        return try allocator.dupe(u8, trimTrailingSlash(real_buf[0..n]));
    } else |_| {
        return try allocator.dupe(u8, trimTrailingSlash(combined));
    }
}

fn resolveCommonDir(allocator: Allocator, io: Io, git_dir: []const u8) ![]u8 {
    var gd = Io.Dir.cwd().openDir(io, git_dir, .{}) catch return try allocator.dupe(u8, git_dir);
    defer gd.close(io);
    const raw = readSmallFile(allocator, io, gd, "commondir", 8192) catch return try allocator.dupe(u8, git_dir);
    defer allocator.free(raw);
    const target = std.mem.trim(u8, raw, " \t\r\n");
    if (target.len == 0) return try allocator.dupe(u8, git_dir);
    return try resolveRelativePath(allocator, io, git_dir, target);
}

fn readSmallFile(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, max_bytes: usize) ![]u8 {
    const f = try dir.openFile(io, sub_path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    if (st.kind != .file) return error.IsDir;
    if (st.size > max_bytes) return error.FileTooBig;
    const sz: usize = @intCast(st.size);
    const buf = try allocator.alloc(u8, sz);
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == sz) return buf;
    return try allocator.realloc(buf, n);
}

fn loadConfigFlags(allocator: Allocator, io: Io, git_dir: []const u8, common_dir: []const u8) !GitConfigFlags {
    var cfg = GitConfigFlags{};
    {
        var cd = Io.Dir.cwd().openDir(io, common_dir, .{}) catch null;
        if (cd) |*d| {
            defer d.close(io);
            if (readSmallFile(allocator, io, d.*, "config", 4 * 1024 * 1024)) |raw| {
                defer allocator.free(raw);
                parseGitConfig(raw, &cfg);
            } else |_| {}
            if (d.statFile(io, "reftable", .{})) |st| {
                if (st.kind == .directory) cfg.reftable = true;
            } else |_| {}
        }
    }
    {
        var gd = Io.Dir.cwd().openDir(io, git_dir, .{}) catch null;
        if (gd) |*d| {
            defer d.close(io);
            if (readSmallFile(allocator, io, d.*, "config.worktree", 4 * 1024 * 1024)) |raw| {
                defer allocator.free(raw);
                parseGitConfig(raw, &cfg);
            } else |_| {}
        }
    }
    return cfg;
}

const ConfigSection = enum {
    other,
    core,
    extensions,
};

fn parseGitConfig(raw: []const u8, cfg: *GitConfigFlags) void {
    var section: ConfigSection = .other;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const stripped = stripConfigComment(line_raw);
        const line = std.mem.trim(u8, stripped, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const header = std.mem.trim(u8, line[1..close], " \t");
            if (std.ascii.eqlIgnoreCase(header, "core")) {
                section = .core;
            } else if (std.ascii.eqlIgnoreCase(header, "extensions")) {
                section = .extensions;
            } else {
                section = .other;
            }
            continue;
        }
        if (section == .other) continue;
        const eq_opt = std.mem.indexOfScalar(u8, line, '=');
        const key = std.mem.trim(u8, if (eq_opt) |eq| line[0..eq] else line, " \t");
        const val_raw = if (eq_opt) |eq| std.mem.trim(u8, line[eq + 1 ..], " \t") else "true";
        const val = unquoteConfigValue(val_raw);

        switch (section) {
            .core => {
                if (std.ascii.eqlIgnoreCase(key, "autocrlf")) {
                    if (std.ascii.eqlIgnoreCase(val, "input")) {
                        cfg.autocrlf = .input;
                    } else if (parseConfigBool(val)) |b| {
                        cfg.autocrlf = if (b) .on else .off;
                    }
                } else if (std.ascii.eqlIgnoreCase(key, "eol")) {
                    cfg.eol_crlf = std.ascii.eqlIgnoreCase(val, "crlf");
                } else if (std.ascii.eqlIgnoreCase(key, "filemode")) {
                    if (parseConfigBool(val)) |b| cfg.filemode = b;
                } else if (std.ascii.eqlIgnoreCase(key, "symlinks")) {
                    if (parseConfigBool(val)) |b| cfg.symlinks = b;
                } else if (std.ascii.eqlIgnoreCase(key, "trustctime")) {
                    if (parseConfigBool(val)) |b| cfg.trustctime = b;
                }
            },
            .extensions => {
                if (std.ascii.eqlIgnoreCase(key, "objectformat")) {
                    if (std.ascii.eqlIgnoreCase(val, "sha256")) {
                        cfg.object_format = .sha256;
                    } else if (std.ascii.eqlIgnoreCase(val, "sha1")) {
                        cfg.object_format = .sha1;
                    }
                } else if (std.ascii.eqlIgnoreCase(key, "refstorage")) {
                    if (std.ascii.eqlIgnoreCase(val, "reftable")) {
                        cfg.reftable = true;
                    } else if (std.ascii.eqlIgnoreCase(val, "files")) {
                        cfg.reftable = false;
                    }
                }
            },
            .other => {},
        }
    }
}

fn stripConfigComment(line: []const u8) []const u8 {
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\' and in_quote and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
        } else if (!in_quote and (c == '#' or c == ';')) {
            return line[0..i];
        }
    }
    return line;
}

fn unquoteConfigValue(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    return val;
}

fn parseConfigBool(val: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(val, "true") or
        std.ascii.eqlIgnoreCase(val, "yes") or
        std.ascii.eqlIgnoreCase(val, "on") or
        std.mem.eql(u8, val, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(val, "false") or
        std.ascii.eqlIgnoreCase(val, "no") or
        std.ascii.eqlIgnoreCase(val, "off") or
        std.mem.eql(u8, val, "0") or
        val.len == 0)
    {
        return false;
    }
    return null;
}
