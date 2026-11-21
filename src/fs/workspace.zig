const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const op_mod = @import("../core/op.zig");
const history_mod = @import("../core/history.zig");
const History = history_mod.History;
const tree_mod = @import("../core/tree.zig");
const text_mod = @import("../core/text.zig");
const diff = @import("../core/diff.zig");
const codec = @import("../store/codec.zig");
const crypto = @import("../store/crypto.zig");
const log_mod = @import("../store/log.zig");
const blobs_mod = @import("../store/blobs.zig");
const watch = @import("watch.zig");
const dag_mod = @import("../core/dag.zig");

pub const FRAME_BATCH: u8 = 1;
pub const FRAME_SCOPE: u8 = 2;
pub const FRAME_SCOPE_BATCH: u8 = 3;
pub const FRAME_SCOPE_END: u8 = 4;
pub const DEFAULT_MAX_FILE_SIZE: u64 = 16 * 1024 * 1024;

pub const ScopeKind = enum(u8) {
    turn = 1,
    tool_call = 2,
    command = 3,
    revert = 4,
};

pub const ScopeRecord = struct {
    scope_id: u128,
    parent_scope: ?u128,
    kind: ScopeKind,
    actor: id.ActorId,
    label: []u8,
    started_ms: u64,
    ended_ms: ?u64,
    batches: std.ArrayList(id.BatchId),

    pub fn deinit(self: *ScopeRecord, allocator: Allocator) void {
        allocator.free(self.label);
        self.batches.deinit(allocator);
    }

    pub fn encode(self: *const ScopeRecord, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.scope_id);
        if (self.parent_scope) |ps| {
            try w.writeByte(allocator, 1);
            try w.writeU128(allocator, ps);
        } else {
            try w.writeByte(allocator, 0);
        }
        try w.writeByte(allocator, @intFromEnum(self.kind));
        try w.writeU128(allocator, self.actor);
        try w.writeBytes(allocator, self.label);
        try w.writeU64(allocator, self.started_ms);
        if (self.ended_ms) |em| {
            try w.writeByte(allocator, 1);
            try w.writeU64(allocator, em);
        } else {
            try w.writeByte(allocator, 0);
        }
        try w.writeU32(allocator, @intCast(self.batches.items.len));
        for (self.batches.items) |bid| {
            try w.writeU64(allocator, bid.ts);
            try w.writeU128(allocator, bid.actor);
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!ScopeRecord {
        const sid = try r.readU128();
        const has_parent = (try r.readByte()) != 0;
        const parent_scope: ?u128 = if (has_parent) try r.readU128() else null;
        const kind = std.enums.fromInt(ScopeKind, try r.readByte()) orelse return error.InvalidData;
        const actor = try r.readU128();
        const label = try r.readBytesAlloc(allocator);
        errdefer allocator.free(label);
        const started_ms = try r.readU64();
        const has_end = (try r.readByte()) != 0;
        const ended_ms: ?u64 = if (has_end) try r.readU64() else null;
        const bcount: usize = try r.readU32();
        var batches: std.ArrayList(id.BatchId) = .empty;
        errdefer batches.deinit(allocator);
        try batches.ensureTotalCapacityPrecise(allocator, bcount);
        for (0..bcount) |_| {
            const ts = try r.readU64();
            const ba = try r.readU128();
            batches.appendAssumeCapacity(id.OpId.init(ts, ba));
        }
        return .{
            .scope_id = sid,
            .parent_scope = parent_scope,
            .kind = kind,
            .actor = actor,
            .label = label,
            .started_ms = started_ms,
            .ended_ms = ended_ms,
            .batches = batches,
        };
    }
};

pub const ChangeObserver = struct {
    ptr: *anyopaque,
    on_commit: *const fn (ptr: *anyopaque, source: []const u8, delta: *const history_mod.CommitDelta) void,
};

pub const EditCommitResult = struct {
    batch_id: id.BatchId,
    version: Version,
    content: []u8,
    concurrent_merged: bool,

    pub fn deinit(self: *EditCommitResult, allocator: Allocator) void {
        self.version.deinit(allocator);
        allocator.free(self.content);
    }
};

pub const WatchStepResult = struct {
    batch_id: ?id.BatchId = null,
    woken: bool = false,
    events: usize = 0,
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

    fn eql(a: StatStamp, b: StatStamp) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns and a.mode == b.mode and a.kind == b.kind;
    }
};

const DiskEntry = union(enum) {
    unchanged: StatStamp,
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
            .unchanged => {},
            .file => |f| allocator.free(f.bytes),
            .symlink => |s| allocator.free(s.target),
        }
    }
};

const DiskReadResult = union(enum) {
    missing,
    skipped_oversize,
    ignored,
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
            .missing, .skipped_oversize, .ignored => {},
            .file => |f| allocator.free(f.bytes),
            .symlink => |s| allocator.free(s.target),
        }
    }
};

const IgnoreRule = struct {
    pattern: []u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
};

const GitIgnore = struct {
    rules: std.ArrayList(IgnoreRule) = .empty,
    stamp_size: u64 = 0,
    stamp_mtime: i96 = 0,
    loaded: bool = false,

    fn deinit(self: *GitIgnore, allocator: Allocator) void {
        for (self.rules.items) |r| allocator.free(r.pattern);
        self.rules.deinit(allocator);
    }

    fn clear(self: *GitIgnore, allocator: Allocator) void {
        for (self.rules.items) |r| allocator.free(r.pattern);
        self.rules.clearRetainingCapacity();
    }

    fn reloadIfNeeded(self: *GitIgnore, allocator: Allocator, io: Io, work_dir: Io.Dir) void {
        const st = work_dir.statFile(io, ".gitignore", .{}) catch {
            if (self.loaded) {
                self.clear(allocator);
                self.loaded = false;
                self.stamp_size = 0;
                self.stamp_mtime = 0;
            }
            return;
        };
        if (self.loaded and st.size == self.stamp_size and st.mtime.nanoseconds == self.stamp_mtime) return;
        self.clear(allocator);
        self.loaded = true;
        self.stamp_size = st.size;
        self.stamp_mtime = st.mtime.nanoseconds;
        if (st.size == 0 or st.size > 512 * 1024) return;

        const f = work_dir.openFile(io, ".gitignore", .{}) catch return;
        defer f.close(io);
        const buf = allocator.alloc(u8, @intCast(st.size)) catch return;
        defer allocator.free(buf);
        const n = f.readPositionalAll(io, buf, 0) catch return;

        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
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
            const dup = allocator.dupe(u8, line) catch continue;
            self.rules.append(allocator, .{
                .pattern = dup,
                .negated = negated,
                .dir_only = dir_only,
                .anchored = anchored,
            }) catch {
                allocator.free(dup);
            };
        }
    }

    fn isIgnored(self: *const GitIgnore, rel_path: []const u8, is_dir: bool) bool {
        if (self.rules.items.len == 0) return false;
        var ignored = false;
        for (self.rules.items) |rule| {
            if (rule.dir_only and !is_dir) continue;
            if (matchRule(rule, rel_path)) {
                ignored = !rule.negated;
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
};

pub fn globMatch(pat: []const u8, str: []const u8) bool {
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

    for (str, 0..) |ch, si| {
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
        _ = si;
        @memcpy(cur[0 .. n + 1], nxt[0 .. n + 1]);
    }

    return cur[n];
}

fn isBinaryBytes(data: []const u8) bool {
    const check_len = @min(data.len, 8192);
    return std.mem.indexOfScalar(u8, data[0..check_len], 0) != null;
}

fn detectLineEnding(data: []const u8) tree_mod.LineEnding {
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n') return .crlf;
    }
    return .lf;
}

fn normalizeToLf(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
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
    const f = try state_dir.createFile(io, "actor.0ndb.tmp", .{ .truncate = true });
    var f_closed = false;
    errdefer {
        if (!f_closed) f.close(io);
        state_dir.deleteFile(io, "actor.0ndb.tmp") catch {};
    }
    try f.writePositionalAll(io, &buf, 0);
    try f.sync(io);
    f.close(io);
    f_closed = true;
    try state_dir.rename("actor.0ndb.tmp", state_dir, "actor.0ndb", io);
    return actor;
}

pub const Workspace = struct {
    allocator: Allocator,
    io: Io,
    root_path: []u8,
    state_dir: Io.Dir,
    work_dir: Io.Dir,
    history: History,
    batch_log: *log_mod.AppendLog,
    blob_store: blobs_mod.BlobStore,
    synced_version: Version,
    disk_actor: id.ActorId,
    scopes: std.ArrayList(ScopeRecord),
    active_scope: ?u128 = null,
    observer: ?ChangeObserver = null,
    watcher: ?watch.SharedWatcher = null,
    stat_cache: std.StringHashMapUnmanaged(StatStamp) = .empty,
    stat_cache_dirty: bool = false,
    batch_log_idx: std.AutoHashMapUnmanaged(id.BatchId, usize) = .empty,
    gitignore: GitIgnore = .{},
    max_file_size: u64 = DEFAULT_MAX_FILE_SIZE,

    fn readBatchLogSlice(ptr: *anyopaque, offset: u64, len: u32) ?[]const u8 {
        const log_ptr: *log_mod.AppendLog = @ptrCast(@alignCast(ptr));
        return log_ptr.readSlice(offset, len);
    }

    pub fn open(allocator: Allocator, io: Io, root_path: []const u8, state_path: []const u8, history_id_opt: ?u128) !Workspace {
        try Io.Dir.cwd().createDirPath(io, root_path);
        try Io.Dir.cwd().createDirPath(io, state_path);

        var transferred = false;

        var work_dir = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        errdefer if (!transferred) work_dir.close(io);
        var state_dir = try Io.Dir.cwd().openDir(io, state_path, .{ .iterate = true });
        errdefer if (!transferred) state_dir.close(io);

        const batch_log = try allocator.create(log_mod.AppendLog);
        var batch_log_inited = false;
        errdefer if (!transferred) {
            if (batch_log_inited) batch_log.deinit();
            allocator.destroy(batch_log);
        };
        batch_log.* = try log_mod.AppendLog.open(allocator, io, state_dir, "batches.0ndb", true);
        batch_log_inited = true;

        var blob_store = try blobs_mod.BlobStore.open(allocator, io, state_dir, "blobs", blobs_mod.DEFAULT_CACHE_BUDGET);
        errdefer if (!transferred) blob_store.deinit();

        const hid = history_id_opt orelse id.newUuidV7(io);
        var hist = try History.init(allocator, hid);
        errdefer if (!transferred) hist.deinit();
        hist.setLogReader(.{
            .ptr = batch_log,
            .readFn = readBatchLogSlice,
        });

        const actor = try loadOrCreateActor(io, state_dir);
        const root_copy = try allocator.dupe(u8, root_path);
        errdefer if (!transferred) allocator.free(root_copy);

        var ws = Workspace{
            .allocator = allocator,
            .io = io,
            .root_path = root_copy,
            .state_dir = state_dir,
            .work_dir = work_dir,
            .history = hist,
            .batch_log = batch_log,
            .blob_store = blob_store,
            .synced_version = Version.ROOT,
            .disk_actor = actor,
            .scopes = .empty,
            .active_scope = null,
            .observer = null,
            .watcher = null,
            .stat_cache = .empty,
            .stat_cache_dirty = false,
            .batch_log_idx = .empty,
            .gitignore = .{},
            .max_file_size = DEFAULT_MAX_FILE_SIZE,
        };
        transferred = true;
        errdefer ws.deinit();

        try ws.replayLog();
        ws.loadStatCache();
        return ws;
    }

    pub fn deinit(self: *Workspace) void {
        if (self.stat_cache_dirty) {
            self.saveStatCache() catch {};
        }
        if (self.watcher) |*w| {
            w.deinit();
            self.watcher = null;
        }
        self.gitignore.deinit(self.allocator);
        {
            var it = self.stat_cache.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.stat_cache.deinit(self.allocator);
        }
        self.batch_log_idx.deinit(self.allocator);
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.synced_version.deinit(self.allocator);
        self.history.deinit();
        self.batch_log.deinit();
        self.allocator.destroy(self.batch_log);
        self.blob_store.deinit();
        self.state_dir.close(self.io);
        self.work_dir.close(self.io);
        self.allocator.free(self.root_path);
    }

    fn computeHeadsHash(self: *const Workspace) crypto.Hash {
        var h = std.crypto.hash.Blake3.init(.{});
        for (self.history.dag.heads.slice()) |bid| {
            var buf: [24]u8 = undefined;
            std.mem.writeInt(u128, buf[0..16], bid.actor, .little);
            std.mem.writeInt(u64, buf[16..24], bid.ts, .little);
            h.update(&buf);
        }
        var out: crypto.Hash = undefined;
        h.final(&out);
        return out;
    }

    pub fn saveStatCache(self: *Workspace) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeByte(self.allocator, 1);
        const h = self.computeHeadsHash();
        try w.writeRaw(self.allocator, &h);
        try w.writeU32(self.allocator, @intCast(self.stat_cache.count()));
        var it = self.stat_cache.iterator();
        while (it.next()) |kv| {
            try w.writeBytes(self.allocator, kv.key_ptr.*);
            try w.writeU64(self.allocator, kv.value_ptr.size);
            const raw_mtime: u128 = @bitCast(@as(i128, kv.value_ptr.mtime_ns));
            try w.writeU128(self.allocator, raw_mtime);
            try w.writeByte(self.allocator, @intFromEnum(kv.value_ptr.mode));
            try w.writeByte(self.allocator, @intFromEnum(kv.value_ptr.kind));
        }

        const f = try self.state_dir.createFile(self.io, "stat_cache.0ndb.tmp", .{ .truncate = true });
        var f_closed = false;
        errdefer {
            if (!f_closed) f.close(self.io);
            self.state_dir.deleteFile(self.io, "stat_cache.0ndb.tmp") catch {};
        }
        try f.writePositionalAll(self.io, w.items(), 0);
        try f.sync(self.io);
        f.close(self.io);
        f_closed = true;
        try self.state_dir.rename("stat_cache.0ndb.tmp", self.state_dir, "stat_cache.0ndb", self.io);
        self.stat_cache_dirty = false;
    }

    fn loadStatCache(self: *Workspace) void {
        const f = self.state_dir.openFile(self.io, "stat_cache.0ndb", .{}) catch return;
        defer f.close(self.io);
        const st = f.stat(self.io) catch return;
        if (st.size == 0 or st.size > 32 * 1024 * 1024) return;
        const buf = self.allocator.alloc(u8, @intCast(st.size)) catch return;
        defer self.allocator.free(buf);
        const n = f.readPositionalAll(self.io, buf, 0) catch return;
        if (n != buf.len) return;

        var r = codec.Reader.init(buf);
        const ver = r.readByte() catch return;
        if (ver != 1) return;
        const saved_hash = (r.readFixed(32) catch return).*;
        const cur_hash = self.computeHeadsHash();
        if (!std.mem.eql(u8, &saved_hash, &cur_hash)) return;

        const count = r.readU32() catch return;
        self.stat_cache.ensureTotalCapacity(self.allocator, count) catch return;
        for (0..count) |_| {
            const rel = r.readBytesAlloc(self.allocator) catch return;
            const size = r.readU64() catch {
                self.allocator.free(rel);
                return;
            };
            const raw_mtime = r.readU128() catch {
                self.allocator.free(rel);
                return;
            };
            const mode_b = r.readByte() catch {
                self.allocator.free(rel);
                return;
            };
            const kind_b = r.readByte() catch {
                self.allocator.free(rel);
                return;
            };
            const mode: tree_mod.FileMode = if (mode_b == @intFromEnum(tree_mod.FileMode.executable)) .executable else .regular;
            const kind: StatKind = if (kind_b == @intFromEnum(StatKind.symlink)) .symlink else .file;
            const mtime_i128: i128 = @bitCast(raw_mtime);
            const mtime_ns: i96 = @intCast(std.math.clamp(mtime_i128, std.math.minInt(i96), std.math.maxInt(i96)));
            if (self.stat_cache.getPtr(rel)) |ptr| {
                self.allocator.free(rel);
                ptr.* = .{ .size = size, .mtime_ns = mtime_ns, .mode = mode, .kind = kind };
            } else {
                self.stat_cache.put(self.allocator, rel, .{ .size = size, .mtime_ns = mtime_ns, .mode = mode, .kind = kind }) catch {
                    self.allocator.free(rel);
                    return;
                };
            }
        }
        self.stat_cache_dirty = false;
    }

    pub fn setObserver(self: *Workspace, observer: ?ChangeObserver) void {
        self.observer = observer;
    }

    pub fn beginScope(self: *Workspace, kind: ScopeKind, actor: id.ActorId, label: []const u8) !u128 {
        const sid = id.newUuidV7(self.io);
        const rec = ScopeRecord{
            .scope_id = sid,
            .parent_scope = self.active_scope,
            .kind = kind,
            .actor = actor,
            .label = try self.allocator.dupe(u8, label),
            .started_ms = id.nowMs(self.io),
            .ended_ms = null,
            .batches = .empty,
        };
        try self.scopes.append(self.allocator, rec);
        self.active_scope = sid;
        try self.persistScope(&self.scopes.items[self.scopes.items.len - 1]);
        return sid;
    }

    pub fn endScope(self: *Workspace, scope_id: u128) !void {
        for (self.scopes.items) |*s| {
            if (s.scope_id == scope_id) {
                const now = id.nowMs(self.io);
                s.ended_ms = now;
                if (self.active_scope == scope_id) {
                    self.active_scope = s.parent_scope;
                }
                try self.persistScopeEnd(scope_id, now);
                return;
            }
        }
    }

    fn persistScope(self: *Workspace, rec: *const ScopeRecord) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try rec.encode(self.allocator, &w);
        _ = try self.batch_log.append(FRAME_SCOPE, 0, 0, w.items());
    }

    fn persistScopeBatch(self: *Workspace, scope_id: u128, batch_id: id.BatchId) !void {
        var buf: [40]u8 = undefined;
        std.mem.writeInt(u128, buf[0..16], scope_id, .little);
        std.mem.writeInt(u128, buf[16..32], batch_id.actor, .little);
        std.mem.writeInt(u64, buf[32..40], batch_id.ts, .little);
        _ = try self.batch_log.append(FRAME_SCOPE_BATCH, 0, 0, &buf);
    }

    fn persistScopeEnd(self: *Workspace, scope_id: u128, ended_ms: u64) !void {
        var buf: [24]u8 = undefined;
        std.mem.writeInt(u128, buf[0..16], scope_id, .little);
        std.mem.writeInt(u64, buf[16..24], ended_ms, .little);
        _ = try self.batch_log.append(FRAME_SCOPE_END, 0, 0, &buf);
    }

    fn upsertScopeRecord(self: *Workspace, rec: ScopeRecord) !void {
        for (self.scopes.items) |*existing| {
            if (existing.scope_id == rec.scope_id) {
                existing.deinit(self.allocator);
                existing.* = rec;
                return;
            }
        }
        try self.scopes.append(self.allocator, rec);
    }

    pub fn compactLog(self: *Workspace) !void {
        try self.history.unpinAllLogSpans();

        var keep: std.ArrayList(usize) = .empty;
        defer keep.deinit(self.allocator);
        const n = self.batch_log.count();
        for (0..n) |i| {
            const entry = self.batch_log.index.items[i];
            if (entry.kind == FRAME_BATCH or entry.kind == FRAME_SCOPE or entry.kind == FRAME_SCOPE_BATCH or entry.kind == FRAME_SCOPE_END) {
                try keep.append(self.allocator, i);
            }
        }
        try self.batch_log.compact(self.state_dir, "batches.0ndb", keep.items);

        self.batch_log_idx.clearRetainingCapacity();
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);
        const new_n = self.batch_log.count();
        for (0..new_n) |i| {
            const view = try self.batch_log.readAt(i);
            if (view.header.kind != FRAME_BATCH) continue;
            const payload_off = try self.batch_log.payloadOffsetAt(i);
            op_spans.clearRetainingCapacity();
            blob_spans.clearRetainingCapacity();
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decodeWithSpans(self.allocator, &r, &op_spans, &blob_spans);
            defer batch.deinit(self.allocator);
            try self.batch_log_idx.put(self.allocator, batch.header.batchId(), i);
            self.history.pinBatchToLog(&batch, payload_off, op_spans.items, blob_spans.items);
        }
    }

    fn watchIgnoreFilter(ctx: ?*const anyopaque, rel_path: []const u8, is_dir: bool) bool {
        const gi: *const GitIgnore = @ptrCast(@alignCast(ctx orelse return false));
        return gi.isPathOrAncestorIgnored(rel_path, is_dir);
    }

    pub fn attachWatcher(self: *Workspace) !void {
        if (self.watcher != null) return;
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir);
        var w = try watch.SharedWatcher.init(self.allocator);
        errdefer w.deinit();
        _ = try w.registerMount(self.io, 1, self.root_path, .{
            .ctx = &self.gitignore,
            .should_ignore = watchIgnoreFilter,
        });
        self.watcher = w;
    }

    pub fn wakeWatcher(self: *const Workspace) void {
        if (self.watcher) |*w| w.wake();
    }

    pub fn waitWatcher(self: *const Workspace, timeout_ms: i32) watch.WaitResult {
        if (self.watcher) |*w| return w.wait(timeout_ms);
        return .{};
    }

    pub fn drainWatched(self: *Workspace, source: []const u8) !?id.BatchId {
        if (self.watcher) |*w| {
            if (w.mountMode(1) == .stat_on_demand) {
                return try self.ingestDiskWithSource(source);
            }
            var events: std.ArrayList(watch.WatchEvent) = .empty;
            defer {
                for (events.items) |*ev| ev.deinit(self.allocator);
                events.deinit(self.allocator);
            }
            const d = try w.drain(self.io, &events);
            if (!d.overflow and d.count == 0) return null;
            return try self.ingestWatchEvents(events.items, d.overflow, source);
        }
        return try self.ingestDiskWithSource(source);
    }

    pub fn watchStep(self: *Workspace, timeout_ms: i32, source: []const u8) !WatchStepResult {
        if (self.watcher == null) try self.attachWatcher();
        if (self.watcher.?.mountMode(1) == .stat_on_demand) {
            const bid = try self.ingestDiskWithSource(source);
            return .{
                .batch_id = bid,
                .woken = false,
                .events = 0,
            };
        }
        var events: std.ArrayList(watch.WatchEvent) = .empty;
        defer {
            for (events.items) |*ev| ev.deinit(self.allocator);
            events.deinit(self.allocator);
        }
        const poll_res = try self.watcher.?.poll(self.io, timeout_ms, &events);
        var bid: ?id.BatchId = null;
        if (poll_res.overflow or poll_res.count > 0) {
            bid = try self.ingestWatchEvents(events.items, poll_res.overflow, source);
        }
        return .{
            .batch_id = bid,
            .woken = poll_res.woken,
            .events = poll_res.count,
        };
    }

    pub fn ingestWatchEvents(
        self: *Workspace,
        events: []const watch.WatchEvent,
        overflow: bool,
        source: []const u8,
    ) !?id.BatchId {
        if (overflow) return try self.ingestDiskWithSource(source);
        if (events.len == 0) return null;
        var rels: std.ArrayList([]const u8) = .empty;
        defer rels.deinit(self.allocator);
        var dirs: std.ArrayList([]const u8) = .empty;
        defer dirs.deinit(self.allocator);
        for (events) |ev| {
            if (ev.rel_path.len == 0) continue;
            if (watch.isIgnoredPath(ev.rel_path)) continue;
            if (ev.is_dir) {
                try dirs.append(self.allocator, ev.rel_path);
            } else {
                try rels.append(self.allocator, ev.rel_path);
            }
        }
        if (rels.items.len == 0 and dirs.items.len == 0) return null;
        return try self.ingestPaths(rels.items, dirs.items, source);
    }

    pub fn hibernate(self: *Workspace) void {
        if (self.stat_cache_dirty) {
            self.saveStatCache() catch {};
        }
        self.batch_log.hibernate();
        self.blob_store.hibernate();
    }

    fn replayLog(self: *Workspace) !void {
        const n = self.batch_log.count();
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);
        for (0..n) |i| {
            const view = try self.batch_log.readAt(i);
            if (view.header.kind == FRAME_SCOPE) {
                var sr = codec.Reader.init(view.payload);
                const rec = ScopeRecord.decode(self.allocator, &sr) catch continue;
                try self.upsertScopeRecord(rec);
                continue;
            }
            if (view.header.kind == FRAME_SCOPE_BATCH) {
                if (view.payload.len >= 40) {
                    const sid = std.mem.readInt(u128, view.payload[0..16], .little);
                    const bid = id.BatchId{
                        .actor = std.mem.readInt(u128, view.payload[16..32], .little),
                        .ts = std.mem.readInt(u64, view.payload[32..40], .little),
                    };
                    for (self.scopes.items) |*s| {
                        if (s.scope_id == sid) {
                            try s.batches.append(self.allocator, bid);
                            break;
                        }
                    }
                }
                continue;
            }
            if (view.header.kind == FRAME_SCOPE_END) {
                if (view.payload.len >= 24) {
                    const sid = std.mem.readInt(u128, view.payload[0..16], .little);
                    const ended_ms = std.mem.readInt(u64, view.payload[16..24], .little);
                    for (self.scopes.items) |*s| {
                        if (s.scope_id == sid) {
                            s.ended_ms = ended_ms;
                            break;
                        }
                    }
                }
                continue;
            }
            if (view.header.kind != FRAME_BATCH) continue;
            const payload_off = try self.batch_log.payloadOffsetAt(i);
            op_spans.clearRetainingCapacity();
            blob_spans.clearRetainingCapacity();
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decodeWithSpans(self.allocator, &r, &op_spans, &blob_spans);
            defer batch.deinit(self.allocator);
            const bid = batch.header.batchId();
            try self.batch_log_idx.put(self.allocator, bid, i);
            for (batch.ops) |op| {
                const maybe_oid: ?id.Oid = switch (op) {
                    .create_file => |cf| switch (cf.content) {
                        .binary => |b| b.oid,
                        .text_blob => |b| b.oid,
                        .text_inline => null,
                    },
                    .set_content => |sc| switch (sc.content) {
                        .binary => |b| b.oid,
                        .text_blob => |b| b.oid,
                        .text_inline => null,
                    },
                    else => null,
                };
                if (maybe_oid) |oid| {
                    if (!self.history.blobs.contains(oid)) {
                        if (try self.blob_store.get(self.allocator, oid)) |raw| {
                            defer self.allocator.free(raw);
                            try self.history.putBlob(oid, raw);
                        }
                    }
                }
            }
            if (try self.history.integrate(&batch)) {
                self.history.pinBatchToLog(&batch, payload_off, op_spans.items, blob_spans.items);
            }
        }
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
    }

    fn persistBatch(self: *Workspace, batch: *const op_mod.Batch) !void {
        for (batch.blobs) |b| {
            try self.blob_store.putVerified(b.oid, b.data);
        }
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        var op_spans: std.ArrayList(op_mod.PayloadSpan) = .empty;
        defer op_spans.deinit(self.allocator);
        var blob_spans: std.ArrayList(op_mod.BlobSpan) = .empty;
        defer blob_spans.deinit(self.allocator);
        try batch.encodeWithSpans(self.allocator, &w, &op_spans, &blob_spans);
        const log_idx = self.batch_log.count();
        const app = try self.batch_log.appendWithOffset(self.batch_log.next_seq, FRAME_BATCH, 0, 0, w.items());
        const bid = batch.header.batchId();
        try self.batch_log_idx.put(self.allocator, bid, log_idx);
        self.history.pinBatchToLog(batch, app.payload_offset, op_spans.items, blob_spans.items);

        if (self.active_scope) |sid| {
            for (self.scopes.items) |*s| {
                if (s.scope_id == sid) {
                    try s.batches.append(self.allocator, bid);
                    try self.persistScopeBatch(sid, bid);
                    break;
                }
            }
        }
    }

    pub fn commitBatch(self: *Workspace, batch: *const op_mod.Batch) !bool {
        return self.commitBatchWithSource(batch, "commit");
    }

    pub fn commitBatchWithSource(self: *Workspace, batch: *const op_mod.Batch, source: []const u8) !bool {
        if (self.observer) |obs| {
            var delta_opt = try self.history.integrateWithDelta(self.allocator, batch);
            if (delta_opt == null) return false;
            defer delta_opt.?.deinit(self.allocator);
            try self.persistBatch(batch);
            obs.on_commit(obs.ptr, source, &delta_opt.?);
            return true;
        }
        const applied = try self.history.integrate(batch);
        if (!applied) return false;
        try self.persistBatch(batch);
        return true;
    }

    fn updateStatCache(self: *Workspace, rel: []const u8, stamp: StatStamp) void {
        if (self.stat_cache.getPtr(rel)) |ptr| {
            if (!ptr.eql(stamp)) {
                ptr.* = stamp;
                self.stat_cache_dirty = true;
            }
            return;
        }
        const dup = self.allocator.dupe(u8, rel) catch return;
        self.stat_cache.put(self.allocator, dup, stamp) catch {
            self.allocator.free(dup);
            return;
        };
        self.stat_cache_dirty = true;
    }

    fn removeStatCache(self: *Workspace, rel: []const u8) void {
        if (self.stat_cache.fetchRemove(rel)) |kv| {
            self.allocator.free(kv.key);
            self.stat_cache_dirty = true;
        }
    }

    fn recordStatFromDisk(self: *Workspace, rel: []const u8) void {
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
        self.updateStatCache(rel, .{
            .size = st.size,
            .mtime_ns = st.mtime.nanoseconds,
            .mode = if (sk == .file) fileModeFromStat(st) else .regular,
            .kind = sk,
        });
    }

    fn makeFileContentAndMeta(
        self: *Workspace,
        raw_bytes: []const u8,
        blobs: *std.ArrayList(op_mod.BlobAttachment),
    ) !struct { content: op_mod.Content, line_ending: tree_mod.LineEnding, is_binary: bool } {
        if (isBinaryBytes(raw_bytes)) {
            const oid = crypto.hashBytes(raw_bytes);
            try blobs.append(self.allocator, .{
                .oid = oid,
                .data = try self.allocator.dupe(u8, raw_bytes),
            });
            return .{
                .content = .{ .binary = .{ .oid = oid, .len = raw_bytes.len } },
                .line_ending = .lf,
                .is_binary = true,
            };
        }
        const ending = detectLineEnding(raw_bytes);
        const norm = try normalizeToLf(self.allocator, raw_bytes);
        defer self.allocator.free(norm);
        const pair = try op_mod.makeTextContent(self.allocator, norm);
        if (pair[1]) |b| try blobs.append(self.allocator, b);
        return .{
            .content = pair[0],
            .line_ending = ending,
            .is_binary = false,
        };
    }

    fn emitUpdateFileOps(
        self: *Workspace,
        iid: id.InodeId,
        raw_bytes: []const u8,
        disk_mode: tree_mod.FileMode,
        ops: *std.ArrayList(op_mod.Op),
        blobs: *std.ArrayList(op_mod.BlobAttachment),
    ) !void {
        const inode = self.history.tree.get(iid) orelse return;
        const f = inode.fileConstPtr() orelse return;
        const cur_ck = f.content.get() orelse return;
        const cur_mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
        const cur_ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;

        if (disk_mode != cur_mode) {
            try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = disk_mode } });
        }

        const new_is_bin = isBinaryBytes(raw_bytes);
        if (new_is_bin) {
            const new_oid = crypto.hashBytes(raw_bytes);
            const same_bin = switch (cur_ck.*) {
                .binary => |ref| std.mem.eql(u8, &ref.oid, &new_oid) and ref.len == raw_bytes.len,
                .text => false,
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

        const new_ending = detectLineEnding(raw_bytes);
        if (new_ending != cur_ending) {
            try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = new_ending } });
        }
        const norm = try normalizeToLf(self.allocator, raw_bytes);
        defer self.allocator.free(norm);

        switch (cur_ck.*) {
            .binary => {
                const pair = try op_mod.makeTextContent(self.allocator, norm);
                if (pair[1]) |b| try blobs.append(self.allocator, b);
                try ops.append(self.allocator, .{ .set_content = .{
                    .inode = iid,
                    .content = pair[0],
                } });
            },
            .text => {
                const cur_text_opt = try f.text.read(self.allocator, self.history.resolver());
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

    pub fn ingestDisk(self: *Workspace) !?id.BatchId {
        return self.ingestDiskWithSource("disk");
    }

    pub fn ingestDiskWithSource(self: *Workspace, source: []const u8) !?id.BatchId {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir);

        var existing_paths: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var it = existing_paths.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            existing_paths.deinit(self.allocator);
        }
        try self.collectTrackedPaths(id.InodeId.ROOT, "", &existing_paths);

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
        try self.scanDir("", &existing_paths, &disk_entries, &skipped_oversize);

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
        const base_start_ts = self.history.nextStartTs(&parents);

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var pit = pending_dirs.keyIterator();
            while (pit.next()) |k| self.allocator.free(k.*);
            pending_dirs.deinit(self.allocator);
        }

        var missing_tracked: std.ArrayList(struct { rel: []const u8, iid: id.InodeId, hash: ?crypto.Hash }) = .empty;
        defer missing_tracked.deinit(self.allocator);

        var eit = existing_paths.iterator();
        while (eit.next()) |kv| {
            const rel = kv.key_ptr.*;
            if (disk_entries.contains(rel)) continue;
            if (skipped_oversize.contains(rel)) continue;
            const iid = kv.value_ptr.*;
            var h: ?crypto.Hash = null;
            if (self.history.tree.get(iid)) |inode| {
                if (inode.fileConstPtr()) |f| {
                    if (try self.readInodeDiskBytes(f)) |old_b| {
                        defer self.allocator.free(old_b);
                        h = crypto.hashBytes(old_b);
                    }
                }
            }
            try missing_tracked.append(self.allocator, .{ .rel = rel, .iid = iid, .hash = h });
        }

        var missing_by_hash: std.AutoHashMapUnmanaged(crypto.Hash, ?usize) = .empty;
        defer missing_by_hash.deinit(self.allocator);
        for (missing_tracked.items, 0..) |m, idx| {
            if (m.hash) |mh| {
                const gop = try missing_by_hash.getOrPut(self.allocator, mh);
                if (!gop.found_existing) {
                    gop.value_ptr.* = idx;
                } else {
                    gop.value_ptr.* = null;
                }
            }
        }

        var new_hash_counts: std.AutoHashMapUnmanaged(crypto.Hash, usize) = .empty;
        defer new_hash_counts.deinit(self.allocator);
        {
            var nit = disk_entries.iterator();
            while (nit.next()) |kv| {
                if (existing_paths.contains(kv.key_ptr.*)) continue;
                switch (kv.value_ptr.*) {
                    .file => |f| {
                        const nh = crypto.hashBytes(f.bytes);
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

        var dit = disk_entries.iterator();
        while (dit.next()) |kv| {
            const rel = kv.key_ptr.*;
            const entry = kv.value_ptr.*;
            if (existing_paths.get(rel)) |iid| {
                switch (entry) {
                    .unchanged => {},
                    .file => |df| {
                        const inode = self.history.tree.get(iid) orelse continue;
                        if (inode.fileConstPtr() != null) {
                            try self.emitUpdateFileOps(iid, df.bytes, df.mode, &ops, &blobs);
                        } else {
                            try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = df.mode,
                                .line_ending = cm.line_ending,
                                .content = cm.content,
                            } });
                        }
                        self.updateStatCache(rel, df.stamp);
                    },
                    .symlink => |ds| {
                        const inode = self.history.tree.get(iid) orelse continue;
                        switch (inode.kind) {
                            .symlink => |*sl| {
                                const cur_target = if (sl.get()) |t| t.* else "";
                                if (!std.mem.eql(u8, cur_target, ds.target)) {
                                    try ops.append(self.allocator, .{ .set_symlink_target = .{
                                        .inode = iid,
                                        .target = try self.allocator.dupe(u8, ds.target),
                                    } });
                                }
                            },
                            else => {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                const base_name = std.fs.path.basename(rel);
                                try ops.append(self.allocator, .{ .create_symlink = .{
                                    .parent = parent_iid,
                                    .name = try self.allocator.dupe(u8, base_name),
                                    .target = try self.allocator.dupe(u8, ds.target),
                                } });
                            },
                        }
                        self.updateStatCache(rel, ds.stamp);
                    },
                }
            } else {
                switch (entry) {
                    .unchanged => {},
                    .file => |df| {
                        const nh = crypto.hashBytes(df.bytes);
                        var did_rename = false;
                        if (new_hash_counts.get(nh) == 1) {
                            if (missing_by_hash.get(nh)) |maybe_idx| {
                                if (maybe_idx) |midx| {
                                    if (!renamed_missing[midx]) {
                                        renamed_missing[midx] = true;
                                        did_rename = true;
                                        const old_iid = missing_tracked.items[midx].iid;
                                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                        const base_name = std.fs.path.basename(rel);
                                        try ops.append(self.allocator, .{ .rename = .{
                                            .inode = old_iid,
                                            .parent = parent_iid,
                                            .name = try self.allocator.dupe(u8, base_name),
                                        } });
                                        try self.emitUpdateFileOps(old_iid, df.bytes, df.mode, &ops, &blobs);
                                    }
                                }
                            }
                        }
                        if (!did_rename) {
                            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                            const base_name = std.fs.path.basename(rel);
                            const cm = try self.makeFileContentAndMeta(df.bytes, &blobs);
                            try ops.append(self.allocator, .{ .create_file = .{
                                .parent = parent_iid,
                                .name = try self.allocator.dupe(u8, base_name),
                                .mode = df.mode,
                                .line_ending = cm.line_ending,
                                .content = cm.content,
                            } });
                        }
                        self.updateStatCache(rel, df.stamp);
                    },
                    .symlink => |ds| {
                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        try ops.append(self.allocator, .{ .create_symlink = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .target = try self.allocator.dupe(u8, ds.target),
                        } });
                        self.updateStatCache(rel, ds.stamp);
                    },
                }
            }
        }

        for (missing_tracked.items, 0..) |m, idx| {
            self.removeStatCache(m.rel);
            if (!renamed_missing[idx]) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = m.iid } });
            }
        }

        if (ops.items.len == 0) return null;

        const batch_parents = try parents.clone(self.allocator);
        const end = base_start_ts + @as(u64, @intCast(ops.items.len)) - 1;
        var batch = op_mod.Batch{
            .header = .{
                .actor = self.disk_actor,
                .start = base_start_ts,
                .end = end,
                .parents = batch_parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = try ops.toOwnedSlice(self.allocator),
            .blobs = try blobs.toOwnedSlice(self.allocator),
        };
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
        return batch.header.batchId();
    }

    fn collectDiskPathsInDir(
        self: *Workspace,
        rel_dir: []const u8,
        out: *std.StringHashMapUnmanaged(void),
    ) !void {
        var dir = if (rel_dir.len == 0)
            try self.work_dir.openDir(self.io, ".", .{ .iterate = true })
        else
            self.work_dir.openDir(self.io, rel_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') {
                if (std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".0ndb")) continue;
                if (std.mem.endsWith(u8, name, ".0ndb-tmp")) continue;
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

    pub fn ingestPaths(
        self: *Workspace,
        rel_paths: []const []const u8,
        scan_dirs: []const []const u8,
        source: []const u8,
    ) !?id.BatchId {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir);

        var candidates: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = candidates.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            candidates.deinit(self.allocator);
        }

        for (rel_paths) |p| {
            if (p.len == 0 or watch.isIgnoredPath(p)) continue;
            if (!candidates.contains(p)) {
                try candidates.put(self.allocator, try self.allocator.dupe(u8, p), {});
            }
        }

        if (scan_dirs.len > 0) {
            for (scan_dirs) |dir_rel| {
                if (dir_rel.len == 0 or watch.isIgnoredPath(dir_rel)) continue;
                self.collectDiskPathsInDir(dir_rel, &candidates) catch {};
            }

            var tracked: std.StringHashMapUnmanaged(id.InodeId) = .empty;
            defer {
                var it = tracked.keyIterator();
                while (it.next()) |k| self.allocator.free(k.*);
                tracked.deinit(self.allocator);
            }
            try self.collectTrackedPaths(id.InodeId.ROOT, "", &tracked);
            var tit = tracked.keyIterator();
            while (tit.next()) |k| {
                for (scan_dirs) |dir_rel| {
                    if (std.mem.eql(u8, k.*, dir_rel) or
                        (k.*.len > dir_rel.len and std.mem.startsWith(u8, k.*, dir_rel) and k.*[dir_rel.len] == '/'))
                    {
                        if (!candidates.contains(k.*)) {
                            try candidates.put(self.allocator, try self.allocator.dupe(u8, k.*), {});
                        }
                        break;
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

        var parents = try self.history.headsClone();
        defer parents.deinit(self.allocator);
        const base_start_ts = self.history.nextStartTs(&parents);

        var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
        defer {
            var pit = pending_dirs.keyIterator();
            while (pit.next()) |k| self.allocator.free(k.*);
            pending_dirs.deinit(self.allocator);
        }

        const MissingFile = struct {
            rel: []const u8,
            iid: id.InodeId,
            hash: crypto.Hash,
            matched: bool = false,
        };
        const AddedFile = struct {
            rel: []const u8,
            bytes: []u8,
            mode: tree_mod.FileMode,
            stamp: StatStamp,
            hash: crypto.Hash,
        };
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
            var disk_res = self.readDiskEntry(rel) catch DiskReadResult.missing;
            var owned_res = true;
            defer if (owned_res) disk_res.deinit(self.allocator);

            const existing_iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
            switch (disk_res) {
                .skipped_oversize, .ignored => {},
                .missing => {
                    self.removeStatCache(rel);
                    if (existing_iid) |iid| {
                        if (self.history.tree.get(iid)) |inode| {
                            if (inode.fileConstPtr()) |f| {
                                if (try self.readInodeDiskBytes(f)) |old_bytes| {
                                    defer self.allocator.free(old_bytes);
                                    try missing_files.append(self.allocator, .{
                                        .rel = rel,
                                        .iid = iid,
                                        .hash = crypto.hashBytes(old_bytes),
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
                .file => |df| {
                    if (existing_iid) |iid| {
                        if (self.history.tree.get(iid)) |inode| {
                            if (inode.fileConstPtr() != null) {
                                try self.emitUpdateFileOps(iid, df.bytes, df.mode, &ops, &blobs);
                            } else if (!inode.isDir()) {
                                try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                const base_name = std.fs.path.basename(rel);
                                const cm = try self.makeFileContentAndMeta(df.bytes, &blobs);
                                try ops.append(self.allocator, .{ .create_file = .{
                                    .parent = parent_iid,
                                    .name = try self.allocator.dupe(u8, base_name),
                                    .mode = df.mode,
                                    .line_ending = cm.line_ending,
                                    .content = cm.content,
                                } });
                            }
                        }
                        self.updateStatCache(rel, df.stamp);
                    } else {
                        try added_files.append(self.allocator, .{
                            .rel = rel,
                            .bytes = df.bytes,
                            .mode = df.mode,
                            .stamp = df.stamp,
                            .hash = crypto.hashBytes(df.bytes),
                        });
                        owned_res = false;
                    }
                },
                .symlink => |ds| {
                    if (existing_iid) |iid| {
                        if (self.history.tree.get(iid)) |inode| {
                            switch (inode.kind) {
                                .symlink => |*sl| {
                                    const cur_target = if (sl.get()) |t| t.* else "";
                                    if (!std.mem.eql(u8, cur_target, ds.target)) {
                                        try ops.append(self.allocator, .{ .set_symlink_target = .{
                                            .inode = iid,
                                            .target = try self.allocator.dupe(u8, ds.target),
                                        } });
                                    }
                                },
                                .file => {
                                    try ops.append(self.allocator, .{ .remove = .{ .inode = iid } });
                                    const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                                    const base_name = std.fs.path.basename(rel);
                                    try ops.append(self.allocator, .{ .create_symlink = .{
                                        .parent = parent_iid,
                                        .name = try self.allocator.dupe(u8, base_name),
                                        .target = try self.allocator.dupe(u8, ds.target),
                                    } });
                                },
                                .dir => {},
                            }
                        }
                    } else {
                        const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, rel, &ops, &pending_dirs);
                        const base_name = std.fs.path.basename(rel);
                        try ops.append(self.allocator, .{ .create_symlink = .{
                            .parent = parent_iid,
                            .name = try self.allocator.dupe(u8, base_name),
                            .target = try self.allocator.dupe(u8, ds.target),
                        } });
                    }
                    self.updateStatCache(rel, ds.stamp);
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
            const parent_iid = try self.ensureParentDirs(self.disk_actor, base_start_ts, af.rel, &ops, &pending_dirs);
            const base_name = std.fs.path.basename(af.rel);
            if (matched_idx) |idx| {
                missing_files.items[idx].matched = true;
                const iid = missing_files.items[idx].iid;
                try ops.append(self.allocator, .{ .rename = .{
                    .inode = iid,
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base_name),
                } });
                try self.emitUpdateFileOps(iid, af.bytes, af.mode, &ops, &blobs);
            } else {
                const cm = try self.makeFileContentAndMeta(af.bytes, &blobs);
                try ops.append(self.allocator, .{ .create_file = .{
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base_name),
                    .mode = af.mode,
                    .line_ending = cm.line_ending,
                    .content = cm.content,
                } });
            }
            self.updateStatCache(af.rel, af.stamp);
        }

        for (missing_files.items) |mf| {
            if (!mf.matched) {
                try ops.append(self.allocator, .{ .remove = .{ .inode = mf.iid } });
            }
        }

        if (ops.items.len == 0) return null;

        const batch_parents = try parents.clone(self.allocator);
        const end = base_start_ts + @as(u64, @intCast(ops.items.len)) - 1;
        var batch = op_mod.Batch{
            .header = .{
                .actor = self.disk_actor,
                .start = base_start_ts,
                .end = end,
                .parents = batch_parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = try ops.toOwnedSlice(self.allocator),
            .blobs = try blobs.toOwnedSlice(self.allocator),
        };
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
        return batch.header.batchId();
    }

    fn readDiskEntry(self: *Workspace, rel: []const u8) !DiskReadResult {
        const st = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch return .missing;
        const is_dir = st.kind == .directory;
        if (self.gitignore.isPathOrAncestorIgnored(rel, is_dir)) return .ignored;
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
                    },
                } };
            },
            .file => {
                if (st.size > self.max_file_size) return .skipped_oversize;
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
                const mode = fileModeFromStat(st);
                return .{ .file = .{
                    .bytes = buf,
                    .mode = mode,
                    .stamp = .{
                        .size = st.size,
                        .mtime_ns = st.mtime.nanoseconds,
                        .mode = mode,
                        .kind = .file,
                    },
                } };
            },
            else => return .missing,
        }
    }

    fn readDiskFile(self: *Workspace, rel: []const u8) !?[]u8 {
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
        self: *Workspace,
        actor: id.ActorId,
        base_start_ts: id.Lamport,
        rel: []const u8,
        ops: *std.ArrayList(op_mod.Op),
        pending_dirs: *std.StringHashMapUnmanaged(id.InodeId),
    ) !id.InodeId {
        const dir_part = std.fs.path.dirname(rel) orelse return id.InodeId.ROOT;
        if (dir_part.len == 0 or std.mem.eql(u8, dir_part, ".")) return id.InodeId.ROOT;
        if (pending_dirs.get(dir_part)) |iid| return iid;
        if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, dir_part)) |iid| {
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
            } else if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, acc.items)) |existing| {
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

    fn scanDir(
        self: *Workspace,
        rel_prefix: []const u8,
        existing_paths: *const std.StringHashMapUnmanaged(id.InodeId),
        out: *std.StringHashMapUnmanaged(DiskEntry),
        skipped_oversize: *std.StringHashMapUnmanaged(void),
    ) !void {
        var dir = if (rel_prefix.len == 0)
            try self.work_dir.openDir(self.io, ".", .{ .iterate = true })
        else
            try self.work_dir.openDir(self.io, rel_prefix, .{ .iterate = true });
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (watch.isIgnoredName(entry.name)) continue;
            const child_rel = if (rel_prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_prefix, entry.name });
            errdefer self.allocator.free(child_rel);

            const is_dir = entry.kind == .directory;
            if (self.gitignore.isIgnored(child_rel, is_dir)) {
                self.allocator.free(child_rel);
                continue;
            }

            switch (entry.kind) {
                .directory => {
                    defer self.allocator.free(child_rel);
                    try self.scanDir(child_rel, existing_paths, out, skipped_oversize);
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
                    };
                    if (existing_paths.contains(child_rel)) {
                        if (self.stat_cache.get(child_rel)) |cached| {
                            if (cached.eql(stamp)) {
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
                    };
                    if (existing_paths.contains(child_rel)) {
                        if (self.stat_cache.get(child_rel)) |cached| {
                            if (cached.eql(stamp)) {
                                try out.put(self.allocator, child_rel, .{ .unchanged = stamp });
                                continue;
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
        self: *const Workspace,
        dir_iid: id.InodeId,
        prefix: []const u8,
        out: *std.StringHashMapUnmanaged(id.InodeId),
    ) !void {
        var entries = try self.history.tree.listDir(self.allocator, text_mod.View.EVERYTHING, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            const inode = self.history.tree.get(entry.inode_id) orelse {
                self.allocator.free(rel);
                continue;
            };
            if (inode.isDir()) {
                defer self.allocator.free(rel);
                try self.collectTrackedPaths(entry.inode_id, rel, out);
            } else {
                try out.put(self.allocator, rel, entry.inode_id);
            }
        }
    }

    fn readInodeDiskBytes(self: *Workspace, f: *const tree_mod.FileNode) !?[]u8 {
        const ck = f.content.get() orelse return null;
        return switch (ck.*) {
            .text => blk: {
                const raw = (try f.text.read(self.allocator, self.history.resolver())) orelse break :blk null;
                const ending = if (f.line_ending.get()) |le| le.* else tree_mod.LineEnding.lf;
                if (ending == .crlf) {
                    defer self.allocator.free(raw);
                    break :blk try smudgeLineEnding(self.allocator, raw, .crlf);
                }
                break :blk raw;
            },
            .binary => |ref| blk: {
                if (self.history.resolveBlob(ref.oid)) |b| {
                    break :blk try self.allocator.dupe(u8, b);
                }
                break :blk try self.blob_store.get(self.allocator, ref.oid);
            },
        };
    }

    fn writeRegularFileAtomic(self: *Workspace, rel: []const u8, bytes: []const u8, mode: tree_mod.FileMode) !void {
        if (std.fs.path.dirname(rel)) |parent_dir| {
            try self.work_dir.createDirPath(self.io, parent_dir);
            if (self.watcher) |*w| {
                w.watchSubdirRecursive(self.io, 1, self.root_path, parent_dir) catch {};
            }
        }
        const tmp_name = try std.fmt.allocPrint(self.allocator, "{s}.0ndb-tmp", .{rel});
        defer self.allocator.free(tmp_name);
        const f = try self.work_dir.createFile(self.io, tmp_name, .{ .truncate = true });
        var f_closed = false;
        errdefer {
            if (!f_closed) f.close(self.io);
            self.work_dir.deleteFile(self.io, tmp_name) catch {};
        }
        try f.writePositionalAll(self.io, bytes, 0);
        const perm_mode: std.posix.mode_t = if (mode == .executable) 0o755 else 0o644;
        f.setPermissions(self.io, Io.File.Permissions.fromMode(perm_mode)) catch {};
        f.close(self.io);
        f_closed = true;
        try self.work_dir.rename(tmp_name, self.work_dir, rel, self.io);
        self.recordStatFromDisk(rel);
    }

    fn writeSymlinkAtomic(self: *Workspace, rel: []const u8, target: []const u8) !void {
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.work_dir.readLink(self.io, rel, &link_buf)) |n| {
            if (std.mem.eql(u8, link_buf[0..n], target)) {
                self.recordStatFromDisk(rel);
                return;
            }
        } else |_| {}
        if (std.fs.path.dirname(rel)) |parent_dir| {
            try self.work_dir.createDirPath(self.io, parent_dir);
            if (self.watcher) |*w| {
                w.watchSubdirRecursive(self.io, 1, self.root_path, parent_dir) catch {};
            }
        }
        self.work_dir.deleteFile(self.io, rel) catch {};
        try self.work_dir.symLink(self.io, target, rel, .{});
        self.recordStatFromDisk(rel);
    }

    pub fn materializeFile(self: *Workspace, rel: []const u8) !void {
        const iid_opt = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel);
        if (iid_opt) |iid| {
            const inode = self.history.tree.get(iid) orelse {
                self.work_dir.deleteFile(self.io, rel) catch {};
                self.removeStatCache(rel);
                return;
            };
            switch (inode.kind) {
                .dir => return,
                .symlink => |*sl| {
                    const target = if (sl.get()) |t| t.* else return;
                    try self.writeSymlinkAtomic(rel, target);
                    return;
                },
                .file => |*f| {
                    const bytes = try self.readInodeDiskBytes(f) orelse return;
                    defer self.allocator.free(bytes);
                    const mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
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
            self.work_dir.deleteFile(self.io, rel) catch {};
            self.removeStatCache(rel);
        }
    }

    pub fn materializePaths(self: *Workspace, rel_paths: []const []const u8) !void {
        for (rel_paths) |rel| {
            try self.materializeFile(rel);
        }
        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
    }

    pub fn materializeToDisk(self: *Workspace) !void {
        self.gitignore.reloadIfNeeded(self.allocator, self.io, self.work_dir);

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
                self.work_dir.deleteFile(self.io, rel_ptr.*) catch {};
                self.removeStatCache(rel_ptr.*);
            }
        }

        var touched: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer touched.deinit(self.allocator);
        var has_touched_set = false;
        if (self.synced_version.eql(&self.history.dag.heads)) {
            has_touched_set = true;
        } else {
            var diff_a = self.history.dag.difference(self.allocator, &self.history.dag.heads, &self.synced_version) catch null;
            defer if (diff_a) |*l| l.deinit(self.allocator);
            var diff_b = self.history.dag.difference(self.allocator, &self.synced_version, &self.history.dag.heads) catch null;
            defer if (diff_b) |*l| l.deinit(self.allocator);
            if (diff_a != null and diff_b != null) {
                var t1 = self.collectTouchedInodes(self.allocator, diff_a.?.items) catch null;
                defer if (t1) |*m| m.deinit(self.allocator);
                var t2 = self.collectTouchedInodes(self.allocator, diff_b.?.items) catch null;
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
            const inode = self.history.tree.get(iid) orelse continue;
            if (inode.isDir()) continue;

            const st_opt = self.work_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch null;
            if (has_touched_set and !touched.contains(iid)) {
                if (st_opt) |st| {
                    if (self.stat_cache.get(rel)) |cached| {
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
                            };
                            if (cur_stamp.eql(cached)) continue;
                        }
                    }
                }
            }

            switch (inode.kind) {
                .dir => {},
                .symlink => |*sl| {
                    const target = if (sl.get()) |t| t.* else continue;
                    try self.writeSymlinkAtomic(rel, target);
                },
                .file => |*f| {
                    const bytes = try self.readInodeDiskBytes(f) orelse continue;
                    defer self.allocator.free(bytes);
                    const mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                    if (st_opt) |st| {
                        if (st.kind == .file and st.size == bytes.len and fileModeFromStat(st) == mode) {
                            if (self.readDiskFile(rel) catch null) |cur| {
                                defer self.allocator.free(cur);
                                if (std.mem.eql(u8, cur, bytes)) {
                                    self.updateStatCache(rel, .{
                                        .size = st.size,
                                        .mtime_ns = st.mtime.nanoseconds,
                                        .mode = mode,
                                        .kind = .file,
                                    });
                                    continue;
                                }
                            }
                        }
                    }
                    try self.writeRegularFileAtomic(rel, bytes, mode);
                },
            }
        }

        self.synced_version.deinit(self.allocator);
        self.synced_version = try self.history.headsClone();
    }

    pub fn collectTouchedInodes(
        self: *Workspace,
        allocator: Allocator,
        batch_ids: []const id.BatchId,
    ) !std.AutoHashMapUnmanaged(id.InodeId, void) {
        var out: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        errdefer out.deinit(allocator);
        for (batch_ids) |bid| {
            const log_idx = self.batch_log_idx.get(bid) orelse continue;
            const view = try self.batch_log.readAt(log_idx);
            if (view.header.kind != FRAME_BATCH) continue;
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decode(allocator, &r);
            defer batch.deinit(allocator);
            for (batch.ops, 0..) |*operation, idx| {
                const maybe_iid: ?id.InodeId = switch (operation.*) {
                    .create_file, .create_symlink => id.InodeId.init(batch.header.opId(idx), 0),
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
                    try out.put(allocator, iid, {});
                }
            }
        }
        return out;
    }

    pub fn rollbackToVersion(self: *Workspace, target_version: *const Version) !bool {
        return self.rollbackToVersionWithSource(target_version, "rollback");
    }

    fn collectOpFilePaths(
        self: *const Workspace,
        batch: *const op_mod.Batch,
        path_set: *std.StringHashMapUnmanaged(void),
        dir_renamed: *bool,
    ) !void {
        for (batch.ops, 0..) |*operation, idx| {
            const maybe_iid: ?id.InodeId = switch (operation.*) {
                .create_file, .create_symlink => id.InodeId.init(batch.header.opId(idx), 0),
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
            const iid = maybe_iid orelse continue;
            const inode = self.history.tree.get(iid) orelse continue;
            if (inode.isDir()) {
                if (operation.* == .rename or operation.* == .remove or operation.* == .restore) dir_renamed.* = true;
                continue;
            }
            if (try self.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) |p| {
                const gop = try path_set.getOrPut(self.allocator, p);
                if (gop.found_existing) self.allocator.free(p);
            }
        }
    }

    pub fn rollbackToVersionWithSource(self: *Workspace, target_version: *const Version, source: []const u8) !bool {
        if (self.watcher != null) {
            _ = try self.drainWatched("watch");
        } else {
            _ = try self.ingestDiskWithSource("disk");
        }
        var batch = try self.history.buildRollbackBatch(
            self.allocator,
            self.disk_actor,
            target_version,
            id.nowMs(self.io),
        ) orelse return false;
        defer batch.deinit(self.allocator);

        var dir_renamed = false;
        var path_set: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = path_set.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            path_set.deinit(self.allocator);
        }
        try self.collectOpFilePaths(&batch, &path_set, &dir_renamed);

        _ = try self.commitBatchWithSource(&batch, source);

        if (dir_renamed) {
            try self.materializeToDisk();
            return true;
        }
        try self.collectOpFilePaths(&batch, &path_set, &dir_renamed);
        if (dir_renamed) {
            try self.materializeToDisk();
            return true;
        }

        var changed: std.ArrayList([]const u8) = .empty;
        defer changed.deinit(self.allocator);
        try changed.ensureTotalCapacityPrecise(self.allocator, path_set.count());
        var pit = path_set.keyIterator();
        while (pit.next()) |k| changed.appendAssumeCapacity(k.*);
        try self.materializePaths(changed.items);
        return true;
    }

    pub fn rebaseBuffer(
        self: *const Workspace,
        allocator: Allocator,
        rel_path: []const u8,
        base_version: *const Version,
        draft_bytes: []const u8,
        cursor_start: u64,
        cursor_end: u64,
    ) Allocator.Error!?history_mod.BufferRebase {
        if (!self.history.isKnownVersion(base_version)) return null;
        return try self.history.rebaseBuffer(
            allocator,
            rel_path,
            base_version,
            draft_bytes,
            cursor_start,
            cursor_end,
        );
    }

    pub fn applyFileSplices(
        self: *Workspace,
        actor: id.ActorId,
        rel_path: []const u8,
        base_version: *const Version,
        splices: []const diff.Splice,
        inserted: []const u8,
        source: []const u8,
    ) !EditCommitResult {
        if (self.watcher != null) {
            _ = try self.drainWatched("watch");
        }
        const effective_base = if (self.history.isKnownVersion(base_version)) base_version else &self.history.dag.heads;
        const concurrent = !effective_base.eql(&self.history.dag.heads);

        if (splices.len == 0) {
            const cur_content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, "");
            errdefer self.allocator.free(cur_content);
            var ver = try self.history.headsClone();
            errdefer ver.deinit(self.allocator);
            const bid = if (ver.slice().len > 0) ver.slice()[0] else id.OpId.ZERO;
            return .{
                .batch_id = bid,
                .version = ver,
                .content = cur_content,
                .concurrent_merged = concurrent,
            };
        }

        const BaseCtx = struct {
            dag_ptr: *const @import("../core/dag.zig").Dag,
            ver: *const Version,
            alloc: Allocator,
            fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                return ctx.dag_ptr.versionContainsOp(ctx.alloc, ctx.ver, op_id) catch false;
            }
        };
        const min_unobs = try self.history.dag.minUnobservedFor(self.allocator, effective_base);
        const bctx = BaseCtx{ .dag_ptr = &self.history.dag, .ver = effective_base, .alloc = self.allocator };
        const base_view = text_mod.View{
            .ptr = &bctx,
            .observesFn = BaseCtx.observes,
            .min_unobserved = min_unobs,
        };

        const iid = try self.history.tree.resolvePath(self.allocator, base_view, rel_path) orelse return error.UnknownInode;

        var batch_owned = false;
        const ops = try self.allocator.alloc(op_mod.Op, 1);
        errdefer if (!batch_owned) self.allocator.free(ops);
        const ins_copy = try self.allocator.dupe(u8, inserted);
        errdefer if (!batch_owned) self.allocator.free(ins_copy);
        const sp_copy = try self.allocator.dupe(diff.Splice, splices);
        errdefer if (!batch_owned) self.allocator.free(sp_copy);
        ops[0] = .{ .edit_text = .{
            .inode = iid,
            .text = ins_copy,
            .splices = sp_copy,
        } };
        var parents = try effective_base.clone(self.allocator);
        errdefer if (!batch_owned) parents.deinit(self.allocator);
        const blobs_empty = try self.allocator.alloc(op_mod.BlobAttachment, 0);
        const start = self.history.nextStartTs(&parents);
        var batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = start,
                .end = start,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = ops,
            .blobs = blobs_empty,
        };
        batch_owned = true;
        defer batch.deinit(self.allocator);

        _ = try self.commitBatchWithSource(&batch, source);
        const touched = [_][]const u8{rel_path};
        try self.materializePaths(&touched);

        const content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(content);
        var ver = try self.history.headsClone();
        errdefer ver.deinit(self.allocator);
        return .{
            .batch_id = batch.header.batchId(),
            .version = ver,
            .content = content,
            .concurrent_merged = concurrent,
        };
    }

    pub fn writeFileAtBase(
        self: *Workspace,
        actor: id.ActorId,
        rel_path: []const u8,
        base_version_opt: ?*const Version,
        bytes: []const u8,
        source: []const u8,
    ) !EditCommitResult {
        if (self.watcher != null) {
            _ = try self.drainWatched("watch");
        } else if (base_version_opt == null) {
            const single = [_][]const u8{rel_path};
            _ = try self.ingestPaths(&single, &.{}, "disk");
        }

        const use_base: ?*const Version = if (base_version_opt) |bv|
            if (self.history.isKnownVersion(bv)) bv else null
        else
            null;

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

        var parents = Version.ROOT;
        defer parents.deinit(self.allocator);
        var concurrent = false;

        var resolved_at_base = false;
        if (use_base) |bv| {
            const BaseCtx = struct {
                dag_ptr: *const @import("../core/dag.zig").Dag,
                ver: *const Version,
                alloc: Allocator,
                fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                    const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                    return ctx.dag_ptr.versionContainsOp(ctx.alloc, ctx.ver, op_id) catch false;
                }
            };
            const min_unobs = try self.history.dag.minUnobservedFor(self.allocator, bv);
            const bctx = BaseCtx{ .dag_ptr = &self.history.dag, .ver = bv, .alloc = self.allocator };
            const base_view = text_mod.View{
                .ptr = &bctx,
                .observesFn = BaseCtx.observes,
                .min_unobserved = min_unobs,
            };
            if (try self.history.tree.resolvePath(self.allocator, base_view, rel_path)) |iid| {
                resolved_at_base = true;
                concurrent = !bv.eql(&self.history.dag.heads);
                parents = try bv.clone(self.allocator);
                const old = try self.history.readFileAt(self.allocator, rel_path, bv);
                defer if (old) |o| self.allocator.free(o);
                const old_bytes = old orelse "";
                if (!std.mem.eql(u8, old_bytes, bytes)) {
                    var d = try diff.diffBytes(self.allocator, old_bytes, bytes);
                    errdefer d.deinit(self.allocator);
                    try ops.append(self.allocator, .{ .edit_text = .{
                        .inode = iid,
                        .text = try d.inserted.toOwnedSlice(self.allocator),
                        .splices = try d.splices.toOwnedSlice(self.allocator),
                    } });
                }
            }
        }

        var base_start_ts: id.Lamport = 0;
        if (!resolved_at_base) {
            parents = try self.history.headsClone();
            base_start_ts = self.history.nextStartTs(&parents);
            if (try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel_path)) |iid| {
                try self.emitUpdateFileOps(iid, bytes, .regular, &ops, &blobs);
            } else {
                var pending_dirs: std.StringHashMapUnmanaged(id.InodeId) = .empty;
                defer {
                    var pit = pending_dirs.keyIterator();
                    while (pit.next()) |k| self.allocator.free(k.*);
                    pending_dirs.deinit(self.allocator);
                }
                const parent_iid = try self.ensureParentDirs(actor, base_start_ts, rel_path, &ops, &pending_dirs);
                const base = std.fs.path.basename(rel_path);
                const cm = try self.makeFileContentAndMeta(bytes, &blobs);
                try ops.append(self.allocator, .{ .create_file = .{
                    .parent = parent_iid,
                    .name = try self.allocator.dupe(u8, base),
                    .mode = .regular,
                    .line_ending = cm.line_ending,
                    .content = cm.content,
                } });
            }
        } else {
            base_start_ts = self.history.nextStartTs(&parents);
        }

        if (ops.items.len == 0) {
            const cur_content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(cur_content);
            var ver = try self.history.headsClone();
            errdefer ver.deinit(self.allocator);
            const bid = if (ver.slice().len > 0) ver.slice()[0] else id.OpId.ZERO;
            return .{
                .batch_id = bid,
                .version = ver,
                .content = cur_content,
                .concurrent_merged = concurrent,
            };
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

        _ = try self.commitBatchWithSource(&batch, source);
        const touched = [_][]const u8{rel_path};
        try self.materializePaths(&touched);

        const content = try self.history.readFileAt(self.allocator, rel_path, null) orelse try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(content);
        var ver = try self.history.headsClone();
        errdefer ver.deinit(self.allocator);
        return .{
            .batch_id = batch.header.batchId(),
            .version = ver,
            .content = content,
            .concurrent_merged = concurrent,
        };
    }

    pub fn writeFileDirect(self: *Workspace, actor: id.ActorId, rel_path: []const u8, bytes: []const u8) !id.BatchId {
        var res = try self.writeFileAtBase(actor, rel_path, null, bytes, "write");
        defer res.deinit(self.allocator);
        return res.batch_id;
    }

    pub fn deleteFileDirect(self: *Workspace, actor: id.ActorId, rel_path: []const u8) !?id.BatchId {
        const iid = try self.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel_path) orelse {
            self.work_dir.deleteFile(self.io, rel_path) catch {};
            self.removeStatCache(rel_path);
            return null;
        };
        var batch_owned = false;
        var parents = try self.history.headsClone();
        errdefer if (!batch_owned) parents.deinit(self.allocator);
        const ts = self.history.nextStartTs(&parents);
        const ops = try self.allocator.alloc(op_mod.Op, 1);
        errdefer if (!batch_owned) self.allocator.free(ops);
        ops[0] = .{ .remove = .{ .inode = iid } };
        const blobs_empty = try self.allocator.alloc(op_mod.BlobAttachment, 0);
        var batch = op_mod.Batch{
            .header = .{
                .actor = actor,
                .start = ts,
                .end = ts,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = ops,
            .blobs = blobs_empty,
        };
        batch_owned = true;
        defer batch.deinit(self.allocator);
        _ = try self.commitBatchWithSource(&batch, "delete");
        const touched = [_][]const u8{rel_path};
        try self.materializePaths(&touched);
        return batch.header.batchId();
    }

    pub fn exportAncestors(self: *Workspace, allocator: Allocator, target: *const Version) ![]op_mod.Batch {
        var anc_list = try self.history.dag.difference(allocator, target, &Version.ROOT);
        defer anc_list.deinit(allocator);
        var wanted: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        defer wanted.deinit(allocator);
        for (anc_list.items) |bid| {
            try wanted.put(allocator, bid, {});
        }
        return self.exportLogBatchesFiltered(allocator, &wanted, true);
    }

    pub fn exportMissing(self: *Workspace, allocator: Allocator, peer_dag: *const dag_mod.Dag) ![]op_mod.Batch {
        var out: std.ArrayList(op_mod.Batch) = .empty;
        errdefer {
            for (out.items) |*b| b.deinit(allocator);
            out.deinit(allocator);
        }
        const n = self.batch_log.count();
        for (0..n) |i| {
            const view = try self.batch_log.readAt(i);
            if (view.header.kind != FRAME_BATCH) continue;
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decode(allocator, &r);
            if (peer_dag.containsBatch(batch.header.batchId())) {
                batch.deinit(allocator);
                continue;
            }
            try out.append(allocator, batch);
        }
        return try out.toOwnedSlice(allocator);
    }

    fn exportLogBatchesFiltered(
        self: *Workspace,
        allocator: Allocator,
        set: *const std.AutoHashMapUnmanaged(id.BatchId, void),
        include_if_in_set: bool,
    ) ![]op_mod.Batch {
        var out: std.ArrayList(op_mod.Batch) = .empty;
        errdefer {
            for (out.items) |*b| b.deinit(allocator);
            out.deinit(allocator);
        }
        const n = self.batch_log.count();
        for (0..n) |i| {
            const view = try self.batch_log.readAt(i);
            if (view.header.kind != FRAME_BATCH) continue;
            var r = codec.Reader.init(view.payload);
            var batch = try op_mod.Batch.decode(allocator, &r);
            const in_set = set.contains(batch.header.batchId());
            if (in_set != include_if_in_set) {
                batch.deinit(allocator);
                continue;
            }
            try out.append(allocator, batch);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn collectPathsInView(
        self: *const Workspace,
        allocator: Allocator,
        view: text_mod.View,
        out: *std.StringHashMapUnmanaged(void),
    ) !void {
        try self.collectPathsInViewRec(allocator, id.InodeId.ROOT, "", view, out);
    }

    fn collectPathsInViewRec(
        self: *const Workspace,
        allocator: Allocator,
        dir_iid: id.InodeId,
        prefix: []const u8,
        view: text_mod.View,
        out: *std.StringHashMapUnmanaged(void),
    ) !void {
        var entries = try self.history.tree.listDir(allocator, view, dir_iid);
        defer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }
        for (entries.items) |entry| {
            const rel = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            const inode = self.history.tree.get(entry.inode_id) orelse {
                allocator.free(rel);
                continue;
            };
            if (inode.isDir()) {
                defer allocator.free(rel);
                try self.collectPathsInViewRec(allocator, entry.inode_id, rel, view, out);
            } else {
                const gop = try out.getOrPut(allocator, rel);
                if (gop.found_existing) allocator.free(rel);
            }
        }
    }
};
