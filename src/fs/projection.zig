const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const id = @import("../core/id.zig");
const codec = @import("../core/codec.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const text_mod = @import("../core/text.zig");
const tree_mod = @import("../core/tree.zig");
const op_mod = @import("../core/op.zig");
const diff = @import("../core/diff.zig");
const history_mod = @import("../core/history.zig");
const shadow_mod = @import("../store/shadow.zig");
const space_mod = @import("../space/space.zig");
const git_dirs_mod = @import("git_dirs.zig");
const git_odb_mod = @import("git_odb.zig");
const git_index_mod = @import("git_index.zig");
const pool_mod = @import("pool.zig");
const watch = @import("watch.zig");
const vcs = @import("vcs.zig");

pub const DEFAULT_MAX_FILE_SIZE: u64 = 16 * 1024 * 1024;
pub const SHADOW_FILE_NAME: []const u8 = "shadow.0ndb";
pub const SYNCED_VERSION_FILE_NAME: []const u8 = "proj_synced.0ndb";

var g_next_mount_id: std.atomic.Value(u64) = .init(1);
var g_tmp_seq: std.atomic.Value(u64) = .init(1);

pub const MaterializeOptions = struct {
    force: bool = false,
};

const GitReaderCtx = struct {
    odb: ?*git_odb_mod.GitOdb = null,
    blobs: *space_mod.BlobStoreHandle,

    fn readAlloc(ptr: *anyopaque, allocator: Allocator, oid: id.GitOid) Allocator.Error!?[]u8 {
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

    fn readCached(_: *anyopaque, _: id.GitOid) ?[]const u8 {
        return null;
    }

    fn contains(ptr: *anyopaque, oid: id.GitOid) bool {
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
        const em: u32 = @backingInt(self.mode);
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
        oid: id.GitOid,
        len: u64,
        mode: tree_mod.FileMode,
        is_binary: bool,
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
        oid: id.GitOid,
        len: u64,
        mode: tree_mod.FileMode,
        is_binary: bool,
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
    priority: u16,
};

const NestedIgnoreStamp = struct {
    size: u64,
    mtime: i96,
};

const GitIgnore = struct {
    rules: std.ArrayList(IgnoreRule) = .empty,
    root_stamp_size: u64 = 0,
    root_stamp_mtime: i96 = 0,
    root_loaded: bool = false,
    exclude_stamp_size: u64 = 0,
    exclude_stamp_mtime: i96 = 0,
    exclude_loaded: bool = false,
    nested_loaded_dirs: std.StringHashMapUnmanaged(NestedIgnoreStamp) = .empty,

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

    fn nestedPriority(prefix: []const u8) u16 {
        var depth: u16 = 1;
        for (prefix) |ch| {
            if (ch == '/') depth +|= 1;
        }
        return 2 +| depth;
    }

    fn parseRulesInto(self: *GitIgnore, allocator: Allocator, prefix: []const u8, priority: u16, data: []const u8) void {
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
                .priority = priority,
            }) catch {
                allocator.free(p_dup);
                allocator.free(dup);
            };
        }
    }

    fn loadFileRules(self: *GitIgnore, allocator: Allocator, io: Io, dir: Io.Dir, file_rel: []const u8, prefix: []const u8, priority: u16) void {
        const f = dir.openFile(io, file_rel, .{}) catch return;
        defer f.close(io);
        const st = f.stat(io) catch return;
        if (st.size == 0 or st.size > 512 * 1024) return;
        const buf = allocator.alloc(u8, @intCast(st.size)) catch return;
        defer allocator.free(buf);
        const n = f.readPositionalAll(io, buf, 0) catch return;
        self.parseRulesInto(allocator, prefix, priority, buf[0..n]);
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
        if (root_same and excl_same) {
            var nested_same = true;
            var nit = self.nested_loaded_dirs.iterator();
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            while (nit.next()) |kv| {
                const rel_gi = std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{kv.key_ptr.*}) catch {
                    nested_same = false;
                    break;
                };
                const st = work_dir.statFile(io, rel_gi, .{}) catch {
                    nested_same = false;
                    break;
                };
                if (st.size != kv.value_ptr.size or st.mtime.nanoseconds != kv.value_ptr.mtime) {
                    nested_same = false;
                    break;
                }
            }
            if (nested_same) return;
        }

        self.clear(allocator);

        if (excl_st) |st| {
            self.exclude_loaded = true;
            self.exclude_stamp_size = st.size;
            self.exclude_stamp_mtime = st.mtime.nanoseconds;
            if (excl_path) |ep| {
                self.loadFileRules(allocator, io, Io.Dir.cwd(), ep, "", 0);
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
            self.loadFileRules(allocator, io, work_dir, ".gitignore", "", 1);
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
        self.nested_loaded_dirs.put(allocator, key, .{
            .size = st.size,
            .mtime = st.mtime.nanoseconds,
        }) catch {
            allocator.free(key);
            return;
        };
        self.loadFileRules(allocator, io, dir, ".gitignore", rel_prefix, nestedPriority(rel_prefix));
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
        var best_priority: u16 = 0;
        var matched_any = false;
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
                if (!matched_any or rule.priority >= best_priority) {
                    best_priority = rule.priority;
                    ignored = !rule.negated;
                    matched_any = true;
                }
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

    fn watchIgnoreCallback(ctx: ?*const anyopaque, rel_path: []const u8, is_dir: bool) bool {
        const ptr = ctx orelse return false;
        const self: *const GitIgnore = @ptrCast(@alignCast(ptr));
        return self.isPathOrAncestorIgnored(rel_path, is_dir);
    }
};

fn globMatch(pat: []const u8, str: []const u8) bool {
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

pub const Projection = struct {
    allocator: Allocator,
    io: Io,
    space: *space_mod.Space,
    root_path: []u8,
    work_dir: Io.Dir,
    shadow: *shadow_mod.ShadowStore,
    gitignore: *GitIgnore,
    watcher: ?*watch.DaemonWatcher = null,
    watcher_mount_id: ?u64 = null,
    watcher_mode: watch.WatchMode = .none,
    dirty: std.atomic.Value(bool) = .init(false),
    git_dirs: ?git_dirs_mod.GitDirs = null,
    git_odb: ?*git_odb_mod.GitOdb = null,
    uses_shared_git_odb: bool = false,
    git_index: ?git_index_mod.GitIndex = null,
    git_index_stamp: ?git_dirs_mod.IndexStamp = null,
    has_custom_filters: bool = false,
    git_reader_ctx: ?*GitReaderCtx = null,
    pinned_git_oids: std.HashMapUnmanaged(id.GitOid, void, id.GitOid.hashContext, 80) = .empty,
    synced_version: Version = Version.ROOT,
    resources: ?*pool_mod.DaemonResources = null,
    max_file_size: u64 = DEFAULT_MAX_FILE_SIZE,
    hibernated: bool = false,
    stat_cache_dirty: bool = false,

    pub fn attach(
        allocator: Allocator,
        io: Io,
        space: *space_mod.Space,
        root_path: []const u8,
        resources: ?*pool_mod.DaemonResources,
    ) !Projection {
        try Io.Dir.cwd().createDirPath(io, root_path);

        var transferred = false;

        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon_root = if (Io.Dir.cwd().realPathFile(io, root_path, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            root_path;

        const root_copy = try allocator.dupe(u8, canon_root);
        errdefer if (!transferred) allocator.free(root_copy);

        var work_dir = try Io.Dir.cwd().openDir(io, canon_root, .{ .iterate = true });
        errdefer if (!transferred) work_dir.close(io);

        const shadow = try allocator.create(shadow_mod.ShadowStore);
        var shadow_inited = false;
        errdefer if (!transferred) {
            if (shadow_inited) shadow.deinit();
            allocator.destroy(shadow);
        };
        shadow.* = try shadow_mod.ShadowStore.open(allocator, io, space.state_dir, SHADOW_FILE_NAME);
        shadow_inited = true;

        const gitignore = try allocator.create(GitIgnore);
        gitignore.* = .{};
        errdefer if (!transferred) {
            gitignore.deinit(allocator);
            allocator.destroy(gitignore);
        };

        var git_dirs: ?git_dirs_mod.GitDirs = null;
        if (space.kind == .git_worktree) {
            git_dirs = git_dirs_mod.GitDirs.locate(allocator, io, canon_root) catch null;
        }
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

        var git_reader_ctx: ?*GitReaderCtx = null;
        errdefer if (!transferred) {
            if (git_reader_ctx) |ctx| {
                space.attachExternalGitReader(null);
                allocator.destroy(ctx);
            }
        };

        if (git_odb != null) {
            const ctx = try allocator.create(GitReaderCtx);
            ctx.* = .{
                .odb = git_odb,
                .blobs = &space.blob_store,
            };
            git_reader_ctx = ctx;
            space.attachExternalGitReader(.{
                .ptr = ctx,
                .readAllocFn = GitReaderCtx.readAlloc,
                .readCachedFn = GitReaderCtx.readCached,
                .containsFn = GitReaderCtx.contains,
            });
        }

        const common_dir_opt: ?[]const u8 = if (git_dirs) |*gd| gd.common_dir else null;
        gitignore.reloadIfNeeded(allocator, io, work_dir, common_dir_opt);

        var git_index: ?git_index_mod.GitIndex = null;
        var git_index_stamp: ?git_dirs_mod.IndexStamp = null;
        errdefer if (!transferred) {
            if (git_index) |*gi| gi.deinit(allocator);
        };
        if (git_dirs) |*gd| {
            if (git_odb != null) {
                git_index_stamp = gd.indexStamp(io) catch null;
                git_index = git_index_mod.GitIndex.load(allocator, io, gd) catch null;
            }
        }

        var watcher: ?*watch.DaemonWatcher = null;
        var watcher_mount_id: ?u64 = null;
        var watcher_mode: watch.WatchMode = .none;
        errdefer if (!transferred) {
            if (watcher) |w| {
                if (watcher_mount_id) |mid| w.removeMount(mid);
            }
        };

        if (resources) |res| {
            if (res.ensureWatcher()) |w| {
                const mid = g_next_mount_id.fetchAdd(1, .monotonic);
                const filter = watch.IgnoreFilter{
                    .ctx = gitignore,
                    .should_ignore = GitIgnore.watchIgnoreCallback,
                };
                if (w.registerMount(io, mid, canon_root, filter)) |mode| {
                    watcher = w;
                    watcher_mount_id = mid;
                    watcher_mode = mode;
                    if (git_dirs) |*gd| {
                        w.subscribeGitCommon(mid, gd.common_dir) catch {};
                    }
                } else |_| {}
            } else |_| {}
        }

        var loaded_synced: ?Version = loadSyncedVersion(allocator, io, space.state_dir);
        var has_persisted_synced = false;
        var synced_ver: Version = undefined;
        if (loaded_synced) |*lv| {
            if (space.history.isKnownVersion(lv)) {
                synced_ver = lv.*;
                has_persisted_synced = true;
            } else {
                lv.deinit(allocator);
                synced_ver = try space.headsClone(allocator);
            }
        } else {
            synced_ver = try space.headsClone(allocator);
        }
        errdefer if (!transferred) synced_ver.deinit(allocator);

        transferred = true;

        var proj = Projection{
            .allocator = allocator,
            .io = io,
            .space = space,
            .root_path = root_copy,
            .work_dir = work_dir,
            .shadow = shadow,
            .gitignore = gitignore,
            .watcher = watcher,
            .watcher_mount_id = watcher_mount_id,
            .watcher_mode = watcher_mode,
            .dirty = .init(watcher_mode != .full_inotify),
            .git_dirs = git_dirs,
            .git_odb = git_odb,
            .uses_shared_git_odb = uses_shared_git_odb,
            .git_index = git_index,
            .git_index_stamp = git_index_stamp,
            .has_custom_filters = has_custom_filters,
            .git_reader_ctx = git_reader_ctx,
            .pinned_git_oids = .empty,
            .synced_version = synced_ver,
            .resources = resources,
            .max_file_size = DEFAULT_MAX_FILE_SIZE,
            .hibernated = false,
            .stat_cache_dirty = false,
        };
        errdefer proj.deinit();

        if (has_persisted_synced and !proj.synced_version.eql(&space.history.dag.heads)) {
            try proj.materializeChanged();
        }

        if (resources) |res| {
            res.refreshGovernorStats();
        }
        return proj;
    }

    pub fn deinit(self: *Projection) void {
        if (self.git_reader_ctx) |ctx| {
            self.space.attachExternalGitReader(null);
            self.allocator.destroy(ctx);
            self.git_reader_ctx = null;
        }
        if (self.watcher) |w| {
            if (self.watcher_mount_id) |mid| {
                w.removeMount(mid);
            }
            self.watcher = null;
            self.watcher_mount_id = null;
        }
        if (self.git_index) |*gi| {
            gi.deinit(self.allocator);
            self.git_index = null;
        }
        if (self.git_odb) |odb| {
            if (self.uses_shared_git_odb) {
                if (self.resources) |res| {
                    if (self.git_dirs) |*gd| {
                        res.releaseGitOdb(gd.common_dir);
                    }
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
        self.pinned_git_oids.deinit(self.allocator);
        self.synced_version.deinit(self.allocator);
        self.shadow.deinit();
        self.allocator.destroy(self.shadow);
        self.gitignore.deinit(self.allocator);
        self.allocator.destroy(self.gitignore);
        self.work_dir.close(self.io);
        self.allocator.free(self.root_path);
        if (self.resources) |res| {
            res.refreshGovernorStats();
        }
    }

    pub fn commonDirOpt(self: *const Projection) ?[]const u8 {
        if (self.git_dirs) |*gd| return gd.common_dir;
        return null;
    }

    pub fn markDirty(self: *Projection) void {
        self.dirty.store(true, .release);
    }

    pub fn isDirty(self: *const Projection) bool {
        if (self.dirty.load(.acquire)) return true;
        if (self.watcher) |w| {
            if (self.watcher_mount_id) |mid| {
                if (w.hasPending(mid) or w.isMountOverflow(mid)) return true;
            }
        }
        return false;
    }

    pub fn adoptInitial(self: *Projection) !void {
        if (self.hibernated) try self.restoreFromHibernate();
        _ = try self.ingestFullScan();
        if (self.watcher) |w| {
            if (self.watcher_mount_id) |mid| {
                if (try w.flushMountPending(mid)) |batch_val| {
                    var b = batch_val;
                    b.deinit(self.allocator);
                }
            }
        }
        self.dirty.store(self.watcher_mode != .full_inotify, .release);
    }

    pub fn ingestDirty(self: *Projection) !?id.BatchId {
        if (self.hibernated) {
            try self.restoreFromHibernate();
            const res = try self.ingestFullScan();
            self.dirty.store(self.watcher_mode != .full_inotify, .release);
            return res;
        }

        if (self.watcher) |w| {
            if (self.watcher_mount_id) |mid| {
                if (self.watcher_mode == .full_inotify) {
                    w.drainPending(self.io) catch {};
                    const flag_dirty = self.dirty.load(.acquire);
                    const has_pending = w.hasPending(mid) or w.isMountOverflow(mid);
                    if (!flag_dirty and !has_pending) {
                        return null;
                    }
                    if (has_pending) {
                        if (try w.flushMountPending(mid)) |batch_val| {
                            var b = batch_val;
                            defer b.deinit(self.allocator);
                            const res = try self.ingestMountBatch(&b);
                            self.dirty.store(false, .release);
                            return res;
                        }
                    }
                    const res = try self.ingestFullScan();
                    self.dirty.store(false, .release);
                    return res;
                }
            }
        }

        const res = try self.ingestFullScan();
        self.dirty.store(self.watcher_mode != .full_inotify, .release);
        return res;
    }

    pub fn ingestMountBatch(self: *Projection, batch: *const watch.MountBatch) !?id.BatchId {
        if (self.hibernated) try self.restoreFromHibernate();
        if (batch.overflow or batch.mode == .stat_on_demand or batch.git_changed) {
            const res = try self.ingestFullScan();
            self.dirty.store(false, .release);
            return res;
        }
        if (batch.paths.items.len == 0) {
            self.dirty.store(false, .release);
            return null;
        }
        var rel_paths: std.ArrayList([]const u8) = .empty;
        defer rel_paths.deinit(self.allocator);
        var scan_dirs: std.ArrayList([]const u8) = .empty;
        defer scan_dirs.deinit(self.allocator);
        for (batch.paths.items) |dp| {
            if (dp.is_dir) {
                try scan_dirs.append(self.allocator, dp.rel_path);
            } else {
                try rel_paths.append(self.allocator, dp.rel_path);
            }
        }
        const res = try self.ingestPaths(rel_paths.items, scan_dirs.items);
        self.dirty.store(false, .release);
        return res;
    }

    pub fn hibernate(self: *Projection) void {
        self.shadow.hibernate();
        if (self.git_index) |*gi| {
            gi.deinit(self.allocator);
            self.git_index = null;
        }
        self.git_index_stamp = null;
        if (self.watcher) |w| {
            if (self.watcher_mount_id) |mid| {
                _ = w.hibernateMountWatches(mid);
                self.watcher_mode = .stat_on_demand;
            }
        }
        self.space.hibernate();
        self.hibernated = true;
        if (self.resources) |res| {
            res.refreshGovernorStats();
        }
    }

    pub fn restoreFromHibernate(self: *Projection) !void {
        if (!self.hibernated) return;
        self.hibernated = false;
        self.refreshGitIndexIfNeeded();
        if (self.watcher) |w| {
            if (self.watcher_mount_id) |mid| {
                self.watcher_mode = w.restoreMountWatches(self.io, mid) catch .stat_on_demand;
            }
        }
        self.dirty.store(true, .release);
        if (self.resources) |res| {
            res.refreshGovernorStats();
        }
    }

    pub fn vcsHead(self: *const Projection, allocator: Allocator) !vcs.VcsHead {
        if (self.git_dirs == null) return .{ .kind = .none };
        return try vcs.head(allocator, self.io, self.root_path);
    }

    pub fn operationInProgress(self: *const Projection, allocator: Allocator) ?[]const u8 {
        if (self.git_dirs == null) return null;
        return vcs.operationInProgress(allocator, self.io, self.root_path);
    }

    pub fn moveHeadSafe(self: *Projection, target_rev: []const u8, target_ref: ?[]const u8) !void {
        if (self.git_dirs == null) return;
        try vcs.moveHeadSafe(self.allocator, self.io, self.root_path, target_ref, target_rev);
        self.git_index_stamp = null;
        self.refreshGitIndexIfNeeded();
        self.markDirty();
    }

    fn updateShadowForPath(self: *Projection, rel: []const u8, stamp: StatStamp, iid_opt: ?id.InodeId, git_oid_opt: ?id.GitOid, blob_oid_opt: ?id.Oid) void {
        const iid = iid_opt orelse (self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel) catch null) orelse id.InodeId.ROOT;
        var entry = shadow_mod.ShadowEntry{
            .inode_id = iid,
            .kind = if (stamp.kind == .symlink) .symlink else .file,
            .mode = @backingInt(stamp.mode),
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

    fn removeStatCache(self: *Projection, rel: []const u8) void {
        self.shadow.remove(rel) catch return;
        self.stat_cache_dirty = true;
    }

    fn recordStatFromDisk(self: *Projection, rel: []const u8) void {
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

    fn refreshGitIndexIfNeeded(self: *Projection) void {
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

    fn queueGitPin(self: *Projection, oid: id.GitOid, new_pins: *std.ArrayList(id.GitOid)) !void {
        if (self.pinned_git_oids.contains(oid)) return;
        try self.pinned_git_oids.put(self.allocator, oid, {});
        try new_pins.append(self.allocator, oid);
    }

    fn loadSyncedVersion(allocator: Allocator, io: Io, state_dir: Io.Dir) ?Version {
        const f = state_dir.openFile(io, SYNCED_VERSION_FILE_NAME, .{}) catch return null;
        defer f.close(io);
        const st = f.stat(io) catch return null;
        if (st.size == 0 or st.size > 1024 * 1024) return null;
        const buf = allocator.alloc(u8, @intCast(st.size)) catch return null;
        defer allocator.free(buf);
        const n = f.readPositionalAll(io, buf, 0) catch return null;
        var r = codec.Reader.init(buf[0..n]);
        return Version.decode(allocator, &r) catch null;
    }

    fn saveSyncedVersion(self: *const Projection) void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        self.synced_version.encode(self.allocator, &w) catch return;
        var tmp_buf: [128]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.{d}.{d}.tmp", .{
            SYNCED_VERSION_FILE_NAME,
            linux.getpid(),
            g_tmp_seq.fetchAdd(1, .monotonic),
        }) catch return;
        const f = self.space.state_dir.createFile(self.io, tmp_name, .{ .truncate = true }) catch return;
        var closed = false;
        errdefer {
            if (!closed) f.close(self.io);
            self.space.state_dir.deleteFile(self.io, tmp_name) catch {};
        }
        f.writePositionalAll(self.io, w.items(), 0) catch {
            f.close(self.io);
            self.space.state_dir.deleteFile(self.io, tmp_name) catch {};
            return;
        };
        f.sync(self.io) catch {};
        f.close(self.io);
        closed = true;
        self.space.state_dir.rename(tmp_name, self.space.state_dir, SYNCED_VERSION_FILE_NAME, self.io) catch {
            self.space.state_dir.deleteFile(self.io, tmp_name) catch {};
        };
    }

    fn updateSyncedVersionToHeads(self: *Projection) !void {
        const next_ver = try self.space.headsClone(self.allocator);
        self.synced_version.deinit(self.allocator);
        self.synced_version = next_ver;
        self.saveSyncedVersion();
    }

    fn flushGitPins(self: *Projection, new_pins: []const id.GitOid) void {
        if (new_pins.len == 0) return;
        const odb = self.git_odb orelse return;
        var all_oids: std.ArrayList(id.GitOid) = .empty;
        defer all_oids.deinit(self.allocator);
        all_oids.ensureTotalCapacityPrecise(self.allocator, self.pinned_git_oids.count()) catch return;
        var it = self.pinned_git_oids.keyIterator();
        while (it.next()) |k| all_oids.appendAssumeCapacity(k.*);
        var ref_buf: [64]u8 = undefined;
        const pin_ref = std.fmt.bufPrint(&ref_buf, "refs/0ndb/pins/{x:0>32}", .{self.space.space_id}) catch git_odb_mod.DEFAULT_PIN_REF;
        odb.pinOidsForRef(pin_ref, all_oids.items) catch {};
    }

    fn makeFileContentAndMeta(
        self: *Projection,
        raw_bytes: []const u8,
        blobs: *std.ArrayList(op_mod.BlobAttachment),
        new_pins: ?*std.ArrayList(id.GitOid),
    ) !struct { content: op_mod.Content, line_ending: tree_mod.LineEnding, is_binary: bool, git_oid: ?id.GitOid = null, blob_oid: ?id.Oid = null } {
        const is_bin = space_mod.isBinaryBytes(raw_bytes);
        if (self.git_odb) |odb| {
            if (self.git_dirs) |*gd| {
                const goid = id.GitOid.ofBlob(gd.config.object_format, raw_bytes);
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
                    const ending = space_mod.detectLineEnding(raw_bytes);
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
            const oid = id.hashBytes(raw_bytes);
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
        const ending = space_mod.detectLineEnding(raw_bytes);
        const norm = try space_mod.normalizeToLf(self.allocator, raw_bytes);
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
        self: *Projection,
        iid: id.InodeId,
        raw_bytes: []const u8,
        disk_mode: tree_mod.FileMode,
        ops: *std.ArrayList(op_mod.Op),
        blobs: *std.ArrayList(op_mod.BlobAttachment),
        new_pins: ?*std.ArrayList(id.GitOid),
    ) !void {
        self.space.history.tree.beginPinScope();
        defer self.space.history.tree.endPinScope();
        const inode = self.space.history.tree.get(iid) orelse return;
        const f = inode.fileConstPtr() orelse return;
        const cur_ck = f.content.get() orelse return;
        const cur_mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
        const cur_ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;

        if (disk_mode != cur_mode) {
            try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = disk_mode } });
        }

        const new_is_bin = space_mod.isBinaryBytes(raw_bytes);
        if (new_is_bin) {
            if (self.git_odb) |odb| {
                if (self.git_dirs) |*gd| {
                    const goid = id.GitOid.ofBlob(gd.config.object_format, raw_bytes);
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
            const new_oid = id.hashBytes(raw_bytes);
            const same_bin = switch (cur_ck.*) {
                .binary => |ref| std.mem.eql(u8, &ref.oid, &new_oid) and ref.len == raw_bytes.len,
                .git_binary => |ref| blk: {
                    const existing = (try self.space.history.readGitBlobAlloc(self.allocator, ref.oid)) orelse break :blk false;
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

        const new_ending = space_mod.detectLineEnding(raw_bytes);
        if (new_ending != cur_ending) {
            try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = new_ending } });
        }
        const norm = try space_mod.normalizeToLf(self.allocator, raw_bytes);
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
                const cur_raw = (try self.space.history.readGitBlobAlloc(self.allocator, ref.oid)) orelse "";
                defer if (cur_raw.len > 0) self.allocator.free(cur_raw);
                const cur_norm = try space_mod.normalizeToLf(self.allocator, cur_raw);
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
                const cur_text_opt = try f.text.read(self.allocator, self.space.history.resolver());
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

    pub fn ingestFullScan(self: *Projection) !?id.BatchId {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir, self.commonDirOpt());
        self.refreshGitIndexIfNeeded();

        const use_shadow_tracking = self.shadow.count() > 0 or self.space.history.dag.count() == 0;
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
        var new_pins: std.ArrayList(id.GitOid) = .empty;
        defer new_pins.deinit(self.allocator);

        var parents = try self.space.headsClone(self.allocator);
        defer parents.deinit(self.allocator);
        const base_start_ts = self.space.history.nextStartTs(&parents);
        const actor = self.space.actor_id;

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var pit = pending_dirs.keyIterator();
            while (pit.next()) |k| self.allocator.free(k.*);
            pending_dirs.deinit(self.allocator);
        }

        const MissingTracked = struct {
            rel: []u8,
            iid: id.InodeId,
            hash: ?id.Hash,
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
                const resolved_iid = (try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, item.rel_path)) orelse {
                    self.removeStatCache(item.rel_path);
                    continue;
                };
                var h: ?id.Hash = if (item.entry.has_blob_oid) item.entry.blob_oid else null;
                if (h == null) {
                    self.space.history.tree.beginPinScope();
                    defer self.space.history.tree.endPinScope();
                    if (self.space.history.tree.get(resolved_iid)) |inode| {
                        if (inode.fileConstPtr()) |f| {
                            if (try self.readInodeDiskBytes(f)) |old_b| {
                                defer self.allocator.free(old_b);
                                h = id.hashBytes(old_b);
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
                var h: ?id.Hash = null;
                {
                    self.space.history.tree.beginPinScope();
                    defer self.space.history.tree.endPinScope();
                    if (self.space.history.tree.get(iid)) |inode| {
                        if (inode.fileConstPtr()) |f| {
                            if (try self.readInodeDiskBytes(f)) |old_b| {
                                defer self.allocator.free(old_b);
                                h = id.hashBytes(old_b);
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

        var missing_by_hash: std.AutoHashMapUnmanaged(id.Hash, ?usize) = .empty;
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

        var new_hash_counts: std.AutoHashMapUnmanaged(id.Hash, usize) = .empty;
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
                        const nh = id.hashBytes(f.bytes);
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
            git_oid: ?id.GitOid = null,
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
                break :blk try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
            } else existing_paths.get(rel);

            if (existing_iid) |iid| {
                switch (entry) {
                    .unchanged => {},
                    .git_clean => |gc| {
                        try self.queueGitPin(gc.oid, &new_pins);
                        const gc_content: op_mod.Content = if (gc.is_binary)
                            .{ .git_binary = .{ .oid = gc.oid, .len = gc.len } }
                        else
                            .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } };
                        self.space.history.tree.beginPinScope();
                        const inode_opt = self.space.history.tree.get(iid);
                        const is_file = if (inode_opt) |in| in.fileConstPtr() != null else false;
                        const cur_ending = if (inode_opt) |in| blk: {
                            const fp = in.fileConstPtr() orelse break :blk tree_mod.LineEnding.lf;
                            break :blk if (fp.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                        } else tree_mod.LineEnding.lf;
                        const same_git_and_mode = if (inode_opt) |in| blk: {
                            const fp = in.fileConstPtr() orelse break :blk false;
                            const cm = if (fp.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                            if (cm != gc.mode) break :blk false;
                            if (!gc.is_binary and cur_ending != .lf) break :blk false;
                            const ck = fp.content.get() orelse break :blk false;
                            break :blk switch (ck.*) {
                                .git_lazy => |r| !gc.is_binary and r.oid.eql(gc.oid) and r.len == gc.len,
                                .git_binary => |r| gc.is_binary and r.oid.eql(gc.oid) and r.len == gc.len,
                                else => false,
                            };
                        } else false;
                        self.space.history.tree.endPinScope();
                        if (!same_git_and_mode) {
                            if (is_file) {
                                try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = gc.mode } });
                                if (!gc.is_binary and cur_ending != .lf) {
                                    try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = .lf } });
                                }
                                try ops.append(self.allocator, .{ .set_content = .{
                                    .inode = iid,
                                    .content = gc_content,
                                } });
                            } else {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                                const base_name = std.fs.path.basename(rel);
                                const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                                try ops.append(self.allocator, .{ .create_file = .{
                                    .parent = parent_iid,
                                    .name = try self.allocator.dupe(u8, base_name),
                                    .mode = gc.mode,
                                    .line_ending = .lf,
                                    .content = gc_content,
                                } });
                                try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = new_iid, .git_oid = gc.oid });
                                continue;
                            }
                        }
                        try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = iid, .git_oid = gc.oid });
                    },
                    .file => |df| {
                        self.space.history.tree.beginPinScope();
                        const is_file = if (self.space.history.tree.get(iid)) |in| in.fileConstPtr() != null else false;
                        self.space.history.tree.endPinScope();
                        if (is_file) {
                            try self.emitUpdateFileOps(iid, df.bytes, df.mode, &ops, &blobs, &new_pins);
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = iid });
                        } else {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs, &new_pins);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
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
                        self.space.history.tree.beginPinScope();
                        const inode_opt = self.space.history.tree.get(iid);
                        const is_symlink = if (inode_opt) |in| in.kind == .symlink else false;
                        const same_target = if (inode_opt) |in| switch (in.kind) {
                            .symlink => |*sl| std.mem.eql(u8, if (sl.get()) |t| t.* else "", ds.target),
                            else => false,
                        } else false;
                        self.space.history.tree.endPinScope();
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
                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
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
                        const gc_content: op_mod.Content = if (gc.is_binary)
                            .{ .git_binary = .{ .oid = gc.oid, .len = gc.len } }
                        else
                            .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } };
                        var did_rename = false;
                        var target_iid = id.InodeId.ROOT;
                        if (gc.stamp.ino != 0) {
                            if (missing_by_ino.get(gc.stamp.ino)) |maybe_idx| {
                                if (maybe_idx) |midx| {
                                    if (!renamed_missing[midx]) {
                                        const old_iid = missing_tracked.items[midx].iid;
                                        self.space.history.tree.beginPinScope();
                                        const old_in = self.space.history.tree.get(old_iid);
                                        const old_is_file = if (old_in) |in| in.fileConstPtr() != null else false;
                                        const old_ending = if (old_in) |in| blk: {
                                            const fp = in.fileConstPtr() orelse break :blk tree_mod.LineEnding.lf;
                                            break :blk if (fp.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                                        } else tree_mod.LineEnding.lf;
                                        const same_old = if (old_in) |in| blk: {
                                            const fp = in.fileConstPtr() orelse break :blk false;
                                            const cm = if (fp.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                                            if (cm != gc.mode) break :blk false;
                                            if (!gc.is_binary and old_ending != .lf) break :blk false;
                                            const ck = fp.content.get() orelse break :blk false;
                                            break :blk switch (ck.*) {
                                                .git_lazy => |r| !gc.is_binary and r.oid.eql(gc.oid) and r.len == gc.len,
                                                .git_binary => |r| gc.is_binary and r.oid.eql(gc.oid) and r.len == gc.len,
                                                else => false,
                                            };
                                        } else false;
                                        self.space.history.tree.endPinScope();
                                        if (old_is_file) {
                                            renamed_missing[midx] = true;
                                            did_rename = true;
                                            target_iid = old_iid;
                                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                                            const base_name = std.fs.path.basename(rel);
                                            try ops.append(self.allocator, .{ .rename = .{
                                                .inode = old_iid,
                                                .parent = parent_iid,
                                                .name = try self.allocator.dupe(u8, base_name),
                                            } });
                                            if (!same_old) {
                                                try ops.append(self.allocator, .{ .set_mode = .{ .inode = old_iid, .mode = gc.mode } });
                                                if (!gc.is_binary and old_ending != .lf) {
                                                    try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = old_iid, .ending = .lf } });
                                                }
                                                try ops.append(self.allocator, .{ .set_content = .{
                                                    .inode = old_iid,
                                                    .content = gc_content,
                                                } });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if (!did_rename) {
                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            target_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = gc.mode,
                                .line_ending = .lf,
                                .content = gc_content,
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
                                        const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
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
                            const nh = id.hashBytes(df.bytes);
                            if (new_hash_counts.get(nh) == 1) {
                                if (missing_by_hash.get(nh)) |maybe_idx| {
                                    if (maybe_idx) |midx| {
                                        if (!renamed_missing[midx]) {
                                            renamed_missing[midx] = true;
                                            did_rename = true;
                                            const old_iid = missing_tracked.items[midx].iid;
                                            target_iid = old_iid;
                                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
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
                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs, &new_pins);
                            target_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
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
                        const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
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
            if (!renamed_missing[idx]) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = m.iid } });
            }
        }

        self.flushGitPins(new_pins.items);

        if (ops.items.len == 0) {
            for (missing_tracked.items) |m| self.removeStatCache(m.rel);
            for (shadow_updates.items) |su| {
                self.updateShadowForPath(su.rel, su.stamp, su.iid, su.git_oid, su.blob_oid);
            }
            try self.updateSyncedVersionToHeads();
            return null;
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

        _ = try self.space.commitBatch(&batch);
        for (missing_tracked.items) |m| self.removeStatCache(m.rel);
        for (shadow_updates.items) |su| {
            self.updateShadowForPath(su.rel, su.stamp, su.iid, su.git_oid, su.blob_oid);
        }
        try self.updateSyncedVersionToHeads();
        return batch.header.batchId();
    }

    pub fn ingestPaths(
        self: *Projection,
        rel_paths: []const []const u8,
        scan_dirs: []const []const u8,
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

                if (try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, dir_rel)) |dir_iid| {
                    self.space.history.tree.beginPinScope();
                    const is_dir = if (self.space.history.tree.get(dir_iid)) |in| in.isDir() else false;
                    self.space.history.tree.endPinScope();
                    if (is_dir) {
                        var sub_tracked: std.StringHashMapUnmanaged(id.InodeId) = .empty;
                        defer {
                            var sit = sub_tracked.keyIterator();
                            while (sit.next()) |k| self.allocator.free(k.*);
                            sub_tracked.deinit(self.allocator);
                        }
                        try self.collectTrackedPaths(dir_iid, dir_rel, &sub_tracked);
                        var sit = sub_tracked.keyIterator();
                        while (sit.next()) |k| {
                            if (!candidates.contains(k.*)) {
                                try candidates.put(self.allocator, try self.allocator.dupe(u8, k.*), {});
                            }
                        }
                    } else if (!candidates.contains(dir_rel)) {
                        try candidates.put(self.allocator, try self.allocator.dupe(u8, dir_rel), {});
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
        var new_pins: std.ArrayList(id.GitOid) = .empty;
        defer new_pins.deinit(self.allocator);

        var parents = try self.space.headsClone(self.allocator);
        defer parents.deinit(self.allocator);
        const base_start_ts = self.space.history.nextStartTs(&parents);
        const actor = self.space.actor_id;

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var pit = pending_dirs.keyIterator();
            while (pit.next()) |k| self.allocator.free(k.*);
            pending_dirs.deinit(self.allocator);
        }

        const MissingFile = struct {
            rel: []const u8,
            iid: id.InodeId,
            hash: id.Hash,
            matched: bool = false,
        };
        const AddedFile = struct {
            rel: []const u8,
            bytes: []u8,
            mode: tree_mod.FileMode,
            stamp: StatStamp,
            hash: id.Hash,
        };
        const PendingShadow = struct {
            rel: []const u8,
            stamp: StatStamp,
            iid: id.InodeId,
            git_oid: ?id.GitOid = null,
            blob_oid: ?id.Oid = null,
        };
        var shadow_updates: std.ArrayList(PendingShadow) = .empty;
        defer shadow_updates.deinit(self.allocator);
        var shadow_removals: std.ArrayList([]const u8) = .empty;
        defer shadow_removals.deinit(self.allocator);

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
            const existing_iid = try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
            var disk_res = self.readDiskEntry(rel, existing_iid != null) catch DiskReadResult.missing;
            var owned_res = true;
            defer if (owned_res) disk_res.deinit(self.allocator);

            switch (disk_res) {
                .skipped_oversize, .ignored => {},
                .missing => {
                    try shadow_removals.append(self.allocator, rel);
                    if (existing_iid) |iid| {
                        self.space.history.tree.beginPinScope();
                        defer self.space.history.tree.endPinScope();
                        if (self.space.history.tree.get(iid)) |inode| {
                            if (inode.fileConstPtr()) |f| {
                                if (try self.readInodeDiskBytes(f)) |old_bytes| {
                                    defer self.allocator.free(old_bytes);
                                    try missing_files.append(self.allocator, .{
                                        .rel = rel,
                                        .iid = iid,
                                        .hash = id.hashBytes(old_bytes),
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
                    const gc_content: op_mod.Content = if (gc.is_binary)
                        .{ .git_binary = .{ .oid = gc.oid, .len = gc.len } }
                    else
                        .{ .git_lazy = .{ .oid = gc.oid, .len = gc.len } };
                    if (existing_iid) |iid| {
                        self.space.history.tree.beginPinScope();
                        const inode_opt = self.space.history.tree.get(iid);
                        const is_file = if (inode_opt) |in| in.fileConstPtr() != null else false;
                        const is_dir = if (inode_opt) |in| in.isDir() else false;
                        const cur_ending = if (inode_opt) |in| blk: {
                            const fp = in.fileConstPtr() orelse break :blk tree_mod.LineEnding.lf;
                            break :blk if (fp.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                        } else tree_mod.LineEnding.lf;
                        const same_git_and_mode = if (inode_opt) |in| blk: {
                            const fp = in.fileConstPtr() orelse break :blk false;
                            const cm = if (fp.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                            if (cm != gc.mode) break :blk false;
                            if (!gc.is_binary and cur_ending != .lf) break :blk false;
                            const ck = fp.content.get() orelse break :blk false;
                            break :blk switch (ck.*) {
                                .git_lazy => |r| !gc.is_binary and r.oid.eql(gc.oid) and r.len == gc.len,
                                .git_binary => |r| gc.is_binary and r.oid.eql(gc.oid) and r.len == gc.len,
                                else => false,
                            };
                        } else false;
                        self.space.history.tree.endPinScope();
                        if (is_file) {
                            if (!same_git_and_mode) {
                                try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = gc.mode } });
                                if (!gc.is_binary and cur_ending != .lf) {
                                    try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = .lf } });
                                }
                                try ops.append(self.allocator, .{ .set_content = .{
                                    .inode = iid,
                                    .content = gc_content,
                                } });
                            }
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = iid, .git_oid = gc.oid });
                        } else if (!is_dir) {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = gc.mode,
                                .line_ending = .lf,
                                .content = gc_content,
                            } });
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = new_iid, .git_oid = gc.oid });
                        }
                    } else {
                        const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                        try ops.append(self.allocator, .{ .create_file = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .mode = gc.mode,
                            .line_ending = .lf,
                            .content = gc_content,
                        } });
                        try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = gc.stamp, .iid = new_iid, .git_oid = gc.oid });
                    }
                },
                .file => |df| {
                    if (existing_iid) |iid| {
                        self.space.history.tree.beginPinScope();
                        const inode_opt = self.space.history.tree.get(iid);
                        const is_file = if (inode_opt) |in| in.fileConstPtr() != null else false;
                        const is_dir = if (inode_opt) |in| in.isDir() else false;
                        self.space.history.tree.endPinScope();
                        if (is_file) {
                            try self.emitUpdateFileOps(iid, df.bytes, df.mode, &ops, &blobs, &new_pins);
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = iid });
                        } else if (!is_dir) {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs, &new_pins);
                            const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = df.mode,
                                .line_ending = cm.line_ending,
                                .content = cm.content,
                            } });
                            try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = df.stamp, .iid = new_iid, .git_oid = cm.git_oid, .blob_oid = cm.blob_oid });
                        }
                    } else {
                        try added_files.append(self.allocator, .{
                            .rel = rel,
                            .bytes = df.bytes,
                            .mode = df.mode,
                            .stamp = df.stamp,
                            .hash = id.hashBytes(df.bytes),
                        });
                        owned_res = false;
                    }
                },
                .symlink => |ds| {
                    if (existing_iid) |iid| {
                        self.space.history.tree.beginPinScope();
                        const inode_opt = self.space.history.tree.get(iid);
                        const kind_tag: ?std.meta.Tag(tree_mod.NodeKind) = if (inode_opt) |in| std.meta.activeTag(in.kind) else null;
                        const same_target = if (inode_opt) |in| switch (in.kind) {
                            .symlink => |*sl| std.mem.eql(u8, if (sl.get()) |t| t.* else "", ds.target),
                            else => false,
                        } else false;
                        self.space.history.tree.endPinScope();
                        if (kind_tag) |kt| switch (kt) {
                            .symlink => {
                                if (!same_target) {
                                    try ops.append(self.allocator, .{ .set_symlink_target = .{
                                        .inode = iid,
                                        .target = try self.allocator.dupe(u8, ds.target),
                                    } });
                                }
                                try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = ds.stamp, .iid = iid });
                            },
                            .file => {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                                const base_name = std.fs.path.basename(rel);
                                const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                                try ops.append(self.allocator, .{ .create_symlink = .{
                                    .parent = parent_iid,
                                    .name = try self.allocator.dupe(u8, base_name),
                                    .target = try self.allocator.dupe(u8, ds.target),
                                } });
                                try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = ds.stamp, .iid = new_iid });
                            },
                            .dir => {},
                        };
                    } else {
                        const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                        try ops.append(self.allocator, .{ .create_symlink = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .target = try self.allocator.dupe(u8, ds.target),
                        } });
                        try shadow_updates.append(self.allocator, .{ .rel = rel, .stamp = ds.stamp, .iid = new_iid });
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
            const parent_iid = try self.ensureParentDirs(actor, base_start_ts, af.rel, &ops, &pending_dirs);
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
                try shadow_updates.append(self.allocator, .{ .rel = af.rel, .stamp = af.stamp, .iid = iid });
            } else {
                const cm = try self.makeFileContentAndMeta(af.bytes, &blobs, &new_pins);
                const new_iid = id.InodeId.init(id.OpId.init(base_start_ts + @as(u64, @intCast(ops.items.len)), actor), 0);
                try ops.append(self.allocator, .{ .create_file = .{
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base_name),
                    .mode = af.mode,
                    .line_ending = cm.line_ending,
                    .content = cm.content,
                } });
                try shadow_updates.append(self.allocator, .{ .rel = af.rel, .stamp = af.stamp, .iid = new_iid, .git_oid = cm.git_oid, .blob_oid = cm.blob_oid });
            }
        }

        for (missing_files.items) |mf| {
            if (!mf.matched) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = mf.iid } });
            }
        }

        self.flushGitPins(new_pins.items);

        if (ops.items.len == 0) {
            for (shadow_removals.items) |rel| self.removeStatCache(rel);
            for (shadow_updates.items) |su| {
                self.updateShadowForPath(su.rel, su.stamp, su.iid, su.git_oid, su.blob_oid);
            }
            return null;
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

        _ = try self.space.commitBatch(&batch);
        for (shadow_removals.items) |rel| self.removeStatCache(rel);
        for (shadow_updates.items) |su| {
            self.updateShadowForPath(su.rel, su.stamp, su.iid, su.git_oid, su.blob_oid);
        }
        try self.updateSyncedVersionToHeads();
        return batch.header.batchId();
    }

    pub fn materializeChanged(self: *Projection) !void {
        if (self.hibernated) try self.restoreFromHibernate();
        if (self.synced_version.eql(&self.space.history.dag.heads)) return;

        var diff_a = self.space.history.dag.difference(self.allocator, &self.space.history.dag.heads, &self.synced_version) catch null;
        defer if (diff_a) |*l| l.deinit(self.allocator);
        var diff_b = self.space.history.dag.difference(self.allocator, &self.synced_version, &self.space.history.dag.heads) catch null;
        defer if (diff_b) |*l| l.deinit(self.allocator);

        if (diff_a == null or diff_b == null) {
            try self.materializeToDisk(.{ .force = false });
            return;
        }

        var t1 = self.space.collectTouchedInodes(self.allocator, diff_a.?.items) catch null;
        defer if (t1) |*m| m.deinit(self.allocator);
        var t2 = self.space.collectTouchedInodes(self.allocator, diff_b.?.items) catch null;
        defer if (t2) |*m| m.deinit(self.allocator);

        if (t1 == null or t2 == null) {
            try self.materializeToDisk(.{ .force = false });
            return;
        }

        var touched: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer touched.deinit(self.allocator);
        var k1 = t1.?.keyIterator();
        while (k1.next()) |k| try touched.put(self.allocator, k.*, {});
        var k2 = t2.?.keyIterator();
        while (k2.next()) |k| try touched.put(self.allocator, k.*, {});

        if (touched.count() == 0) {
            try self.updateSyncedVersionToHeads();
            return;
        }

        var dir_touched = false;
        var path_set: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = path_set.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            path_set.deinit(self.allocator);
        }

        var tit = touched.keyIterator();
        while (tit.next()) |iid_ptr| {
            const iid = iid_ptr.*;
            self.space.history.tree.beginPinScope();
            const inode_opt = self.space.history.tree.get(iid);
            const is_dir = if (inode_opt) |in| in.isDir() else false;
            self.space.history.tree.endPinScope();
            if (is_dir) {
                dir_touched = true;
                break;
            }
            if (try self.space.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) |p| {
                const gop = try path_set.getOrPut(self.allocator, p);
                if (gop.found_existing) self.allocator.free(p);
            }
        }

        if (dir_touched) {
            try self.materializeToDisk(.{ .force = false });
            return;
        }

        if (self.shadow.count() > 0) {
            var sit = touched.keyIterator();
            while (sit.next()) |iid_ptr| {
                if (try self.shadow.pathOfInode(self.allocator, iid_ptr.*)) |old_path| {
                    const gop = try path_set.getOrPut(self.allocator, old_path);
                    if (gop.found_existing) self.allocator.free(old_path);
                }
            }
        }

        var pit = path_set.keyIterator();
        while (pit.next()) |p_ptr| {
            try self.materializeFile(p_ptr.*);
        }

        try self.updateSyncedVersionToHeads();
    }

    pub fn materializeFile(self: *Projection, rel: []const u8) !void {
        const iid_opt = try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
        if (iid_opt) |iid| {
            self.space.history.tree.beginPinScope();
            const inode_opt = self.space.history.tree.get(iid);
            if (inode_opt == null) {
                self.space.history.tree.endPinScope();
                if ((self.shadow.get(rel) catch null) != null) {
                    self.work_dir.deleteFile(self.io, rel) catch {};
                    self.removeStatCache(rel);
                }
                return;
            }
            const inode = inode_opt.?;
            switch (inode.kind) {
                .dir => {
                    self.space.history.tree.endPinScope();
                    return;
                },
                .symlink => |*sl| {
                    const target_copy = if (sl.get()) |t| try self.allocator.dupe(u8, t.*) else null;
                    self.space.history.tree.endPinScope();
                    if (target_copy) |t| {
                        defer self.allocator.free(t);
                        try self.writeSymlinkAtomic(rel, t);
                    }
                    return;
                },
                .file => |*f| {
                    const bytes_opt = try self.readInodeDiskBytes(f);
                    const mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                    self.space.history.tree.endPinScope();
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

    pub fn materializePaths(self: *Projection, rel_paths: []const []const u8) !void {
        for (rel_paths) |rel| {
            try self.materializeFile(rel);
        }
        try self.updateSyncedVersionToHeads();
    }

    pub fn materializeToDisk(self: *Projection, opts: MaterializeOptions) !void {
        if (self.hibernated) try self.restoreFromHibernate();
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
        if (self.synced_version.eql(&self.space.history.dag.heads)) {
            has_touched_set = true;
        } else {
            var diff_a = self.space.history.dag.difference(self.allocator, &self.space.history.dag.heads, &self.synced_version) catch null;
            defer if (diff_a) |*l| l.deinit(self.allocator);
            var diff_b = self.space.history.dag.difference(self.allocator, &self.synced_version, &self.space.history.dag.heads) catch null;
            defer if (diff_b) |*l| l.deinit(self.allocator);
            if (diff_a != null and diff_b != null) {
                var t1 = self.space.collectTouchedInodes(self.allocator, diff_a.?.items) catch null;
                defer if (t1) |*m| m.deinit(self.allocator);
                var t2 = self.space.collectTouchedInodes(self.allocator, diff_b.?.items) catch null;
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

            self.space.history.tree.beginPinScope();
            const inode_opt = self.space.history.tree.get(iid);
            if (inode_opt == null or inode_opt.?.isDir()) {
                self.space.history.tree.endPinScope();
                continue;
            }
            const inode = inode_opt.?;
            switch (inode.kind) {
                .dir => {
                    self.space.history.tree.endPinScope();
                },
                .symlink => |*sl| {
                    const target_copy = if (sl.get()) |t| try self.allocator.dupe(u8, t.*) else null;
                    self.space.history.tree.endPinScope();
                    if (target_copy) |t| {
                        defer self.allocator.free(t);
                        try self.writeSymlinkAtomic(rel, t);
                    }
                },
                .file => |*f| {
                    const bytes_opt = try self.readInodeDiskBytes(f);
                    const mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                    self.space.history.tree.endPinScope();
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

        try self.updateSyncedVersionToHeads();
    }

    fn collectDiskPathsInDir(
        self: *Projection,
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

    fn readDiskEntry(self: *Projection, rel: []const u8, already_tracked: bool) !DiskReadResult {
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
                                        if (odb.readBlobAlloc(self.allocator, ie.oid) catch null) |raw_blob| {
                                            defer self.allocator.free(raw_blob);
                                            if (raw_blob.len == st.size) {
                                                const is_bin = space_mod.isBinaryBytes(raw_blob);
                                                if (is_bin or space_mod.detectLineEnding(raw_blob) == .lf) {
                                                    return .{ .git_clean = .{
                                                        .oid = ie.oid,
                                                        .len = st.size,
                                                        .mode = mode,
                                                        .is_binary = is_bin,
                                                        .stamp = stamp,
                                                    } };
                                                }
                                            }
                                        }
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

    fn readDiskFile(self: *Projection, rel: []const u8) !?[]u8 {
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
        self: *Projection,
        actor: id.ActorId,
        base_start_ts: id.Lamport,
        rel: []const u8,
        ops: *std.ArrayList(op_mod.Op),
        pending_dirs: *std.StringHashMapUnmanaged(id.InodeId),
    ) !id.InodeId {
        const dir_part = std.fs.path.dirname(rel) orelse return id.InodeId.ROOT;
        if (dir_part.len == 0 or std.mem.eql(u8, dir_part, ".")) return id.InodeId.ROOT;
        if (pending_dirs.get(dir_part)) |iid| return iid;
        if (try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, dir_part)) |iid| {
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
            } else if (try self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, acc.items)) |existing| {
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

    fn hasLiveFileInSubtree(self: *const Projection, dir_iid: id.InodeId) bool {
        var entries = self.space.history.tree.listDir(self.allocator, text_mod.View.EVERYTHING, dir_iid) catch return false;
        defer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (entries.items) |entry| {
            self.space.history.tree.beginPinScope();
            const inode_opt = self.space.history.tree.get(entry.inode_id);
            const is_dir = if (inode_opt) |in| in.isDir() else false;
            const exists = inode_opt != null;
            self.space.history.tree.endPinScope();
            if (!exists) continue;
            if (!is_dir) return true;
            if (self.hasLiveFileInSubtree(entry.inode_id)) return true;
        }
        return false;
    }

    fn hasTrackedUnderDir(
        self: *Projection,
        dir_rel: []const u8,
        use_shadow_tracking: bool,
        existing_paths: *const std.StringHashMapUnmanaged(id.InodeId),
    ) bool {
        _ = use_shadow_tracking;
        _ = existing_paths;
        const dir_iid = (self.space.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, dir_rel) catch null) orelse return false;
        return self.hasLiveFileInSubtree(dir_iid);
    }

    fn scanDir(
        self: *Projection,
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
                                            if (odb.readBlobAlloc(self.allocator, ie.oid) catch null) |raw_blob| {
                                                defer self.allocator.free(raw_blob);
                                                if (raw_blob.len == st.size) {
                                                    const is_bin = space_mod.isBinaryBytes(raw_blob);
                                                    if (is_bin or space_mod.detectLineEnding(raw_blob) == .lf) {
                                                        try out.put(self.allocator, child_rel, .{ .git_clean = .{
                                                            .oid = ie.oid,
                                                            .len = st.size,
                                                            .mode = mode,
                                                            .is_binary = is_bin,
                                                            .stamp = stamp,
                                                        } });
                                                        continue;
                                                    }
                                                }
                                            }
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
        self: *const Projection,
        dir_iid: id.InodeId,
        prefix: []const u8,
        out: *std.StringHashMapUnmanaged(id.InodeId),
    ) !void {
        var entries = try self.space.history.tree.listDir(self.allocator, text_mod.View.EVERYTHING, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            self.space.history.tree.beginPinScope();
            const inode_opt = self.space.history.tree.get(entry.inode_id);
            const is_dir = if (inode_opt) |in| in.isDir() else false;
            const exists = inode_opt != null;
            self.space.history.tree.endPinScope();
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

    fn readInodeDiskBytes(self: *Projection, f: *const tree_mod.FileNode) !?[]u8 {
        const ck = f.content.get() orelse return null;
        return switch (ck.*) {
            .text => blk: {
                const raw = (try f.text.read(self.allocator, self.space.history.resolver())) orelse break :blk null;
                const ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                if (ending == .crlf) {
                    defer self.allocator.free(raw);
                    break :blk try smudgeLineEnding(self.allocator, raw, .crlf);
                }
                break :blk raw;
            },
            .binary => |ref| blk: {
                if (self.space.history.resolveBlob(ref.oid)) |b| {
                    break :blk try self.allocator.dupe(u8, b);
                }
                break :blk try self.space.blob_store.get(self.allocator, ref.oid);
            },
            .git_binary => |ref| try self.space.history.readGitBlobAlloc(self.allocator, ref.oid),
            .git_lazy => |ref| blk: {
                const raw = (try self.space.history.readGitBlobAlloc(self.allocator, ref.oid)) orelse break :blk null;
                const ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                if (ending == .crlf) {
                    defer self.allocator.free(raw);
                    break :blk try smudgeLineEnding(self.allocator, raw, .crlf);
                }
                break :blk raw;
            },
        };
    }

    fn writeRegularFileAtomic(self: *Projection, rel: []const u8, bytes: []const u8, mode: tree_mod.FileMode) !void {
        if (std.fs.path.dirname(rel)) |parent_dir| {
            try self.work_dir.createDirPath(self.io, parent_dir);
            if (self.watcher) |w| {
                if (self.watcher_mount_id) |mid| {
                    w.watchSubdirRecursive(self.io, mid, self.root_path, parent_dir) catch {};
                }
            }
        }
        const existing_st = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch null;
        var perm_mode: std.posix.mode_t = if (mode == .executable) 0o755 else 0o644;
        if (existing_st) |st| {
            if (st.kind == .file) {
                const raw: std.posix.mode_t = @intCast(st.permissions.toMode() & 0o777);
                if (mode == .executable) {
                    var p = raw | 0o100;
                    if ((raw & 0o040) != 0) p |= 0o010;
                    if ((raw & 0o004) != 0) p |= 0o001;
                    perm_mode = p;
                } else {
                    const p = raw & ~@as(std.posix.mode_t, 0o111);
                    if (p != 0) perm_mode = p;
                }
            }
        }
        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}.{d}.0ndb-tmp", .{
            rel,
            linux.getpid(),
            g_tmp_seq.fetchAdd(1, .monotonic),
        });
        defer self.allocator.free(tmp_name);
        const f = try self.work_dir.createFile(self.io, tmp_name, .{ .truncate = true });
        var f_closed = false;
        errdefer {
            if (!f_closed) f.close(self.io);
            self.work_dir.deleteFile(self.io, tmp_name) catch {};
        }
        try f.writePositionalAll(self.io, bytes, 0);
        f.setPermissions(self.io, Io.File.Permissions.fromMode(perm_mode)) catch {};
        try f.sync(self.io);
        f.close(self.io);
        f_closed = true;
        if (existing_st) |st| {
            if (st.kind == .directory) {
                self.work_dir.deleteTree(self.io, rel) catch {};
            }
        }
        try self.work_dir.rename(tmp_name, self.work_dir, rel, self.io);
        self.recordStatFromDisk(rel);
    }

    fn writeSymlinkAtomic(self: *Projection, rel: []const u8, target: []const u8) !void {
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.work_dir.readLink(self.io, rel, &link_buf)) |n| {
            if (std.mem.eql(u8, link_buf[0..n], target)) {
                self.recordStatFromDisk(rel);
                return;
            }
        } else |_| {}
        if (std.fs.path.dirname(rel)) |parent_dir| {
            try self.work_dir.createDirPath(self.io, parent_dir);
            if (self.watcher) |w| {
                if (self.watcher_mount_id) |mid| {
                    w.watchSubdirRecursive(self.io, mid, self.root_path, parent_dir) catch {};
                }
            }
        }
        const existing_st = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch null;
        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}.{d}.0ndb-sym-tmp", .{
            rel,
            linux.getpid(),
            g_tmp_seq.fetchAdd(1, .monotonic),
        });
        defer self.allocator.free(tmp_name);
        self.work_dir.deleteFile(self.io, tmp_name) catch {};
        try self.work_dir.symLink(self.io, target, tmp_name, .{});
        errdefer self.work_dir.deleteFile(self.io, tmp_name) catch {};
        if (existing_st) |st| {
            if (st.kind == .directory) {
                self.work_dir.deleteTree(self.io, rel) catch {};
            }
        }
        try self.work_dir.rename(tmp_name, self.work_dir, rel, self.io);
        self.recordStatFromDisk(rel);
    }
};
