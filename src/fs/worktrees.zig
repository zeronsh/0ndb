const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const text_mod = @import("../core/text.zig");
const tree_mod = @import("../core/tree.zig");
const op_mod = @import("../core/op.zig");
const codec = @import("../store/codec.zig");
const crypto = @import("../store/crypto.zig");
const ws_mod = @import("workspace.zig");
const vcs = @import("vcs.zig");

pub const BRANCH_PREFIX = "ondb/";
const CONFLICT_MARKER = "<<<<<<< ";
const REGISTRY_MAGIC: u32 = 0x57545231;
const CONFLICTS_MAGIC: u32 = 0x43464C31;

pub const ForkOrigin = struct {
    source_id: u128,
    fork_version: Version,
    shared: bool,

    pub fn clone(self: *const ForkOrigin, allocator: Allocator) Allocator.Error!ForkOrigin {
        return .{
            .source_id = self.source_id,
            .fork_version = try self.fork_version.clone(allocator),
            .shared = self.shared,
        };
    }

    pub fn deinit(self: *ForkOrigin, allocator: Allocator) void {
        self.fork_version.deinit(allocator);
    }
};

pub const WorktreeInfo = struct {
    id: u128,
    title: []u8,
    path: []u8,
    vcs_kind: vcs.VcsKind,
    repo_root: ?[]u8,
    ref_name: ?[]u8,
    state_path: []u8,
    history_id: u128,
    created: bool,
    created_ms: u64,
    forked_from: ?ForkOrigin,

    pub fn clone(self: *const WorktreeInfo, allocator: Allocator) Allocator.Error!WorktreeInfo {
        const title_copy = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title_copy);
        const path_copy = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path_copy);
        const repo_copy = if (self.repo_root) |r| try allocator.dupe(u8, r) else null;
        errdefer if (repo_copy) |r| allocator.free(r);
        const ref_copy = if (self.ref_name) |r| try allocator.dupe(u8, r) else null;
        errdefer if (ref_copy) |r| allocator.free(r);
        const state_copy = try allocator.dupe(u8, self.state_path);
        errdefer allocator.free(state_copy);
        const fork_copy = if (self.forked_from) |*f| try f.clone(allocator) else null;
        return .{
            .id = self.id,
            .title = title_copy,
            .path = path_copy,
            .vcs_kind = self.vcs_kind,
            .repo_root = repo_copy,
            .ref_name = ref_copy,
            .state_path = state_copy,
            .history_id = self.history_id,
            .created = self.created,
            .created_ms = self.created_ms,
            .forked_from = fork_copy,
        };
    }

    pub fn deinit(self: *WorktreeInfo, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.path);
        if (self.repo_root) |r| allocator.free(r);
        if (self.ref_name) |r| allocator.free(r);
        allocator.free(self.state_path);
        if (self.forked_from) |*f| f.deinit(allocator);
    }
};

pub const ConflictKind = enum(u8) {
    text = 1,
    binary = 2,
    deleted_here = 3,
    deleted_there = 4,
};

pub const Conflict = struct {
    path: []u8,
    kind: ConflictKind,
    ours: ?[]u8,
    theirs: ?[]u8,

    pub fn clone(self: *const Conflict, allocator: Allocator) Allocator.Error!Conflict {
        const p = try allocator.dupe(u8, self.path);
        errdefer allocator.free(p);
        const o = if (self.ours) |b| try allocator.dupe(u8, b) else null;
        errdefer if (o) |b| allocator.free(b);
        const t = if (self.theirs) |b| try allocator.dupe(u8, b) else null;
        return .{ .path = p, .kind = self.kind, .ours = o, .theirs = t };
    }

    pub fn deinit(self: *Conflict, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.ours) |b| allocator.free(b);
        if (self.theirs) |b| allocator.free(b);
    }
};

pub const Resolution = union(enum) {
    ours,
    theirs,
    content: ?[]const u8,
};

pub const SyncReport = struct {
    brought: usize = 0,
    merged: [][]u8 = &.{},
    conflicts: []Conflict = &.{},

    pub fn deinit(self: *SyncReport, allocator: Allocator) void {
        for (self.merged) |p| allocator.free(p);
        if (self.merged.len > 0) allocator.free(self.merged);
        for (self.conflicts) |*c| c.deinit(allocator);
        if (self.conflicts.len > 0) allocator.free(self.conflicts);
    }
};

pub const LandReport = struct {
    sync: SyncReport = .{},
    landed: usize = 0,

    pub fn deinit(self: *LandReport, allocator: Allocator) void {
        self.sync.deinit(allocator);
    }
};

pub const WorktreeError = error{
    WorktreeNotFound,
    NotAFork,
    HistoryNotShared,
    UnresolvedConflicts,
    DirtyWorktree,
    ConflictNotFound,
};

pub const Worktrees = struct {
    allocator: Allocator,
    io: Io,
    state_dir_path: []u8,
    checkouts_dir_path: []u8,
    entries: std.ArrayList(WorktreeInfo),
    live: std.AutoHashMapUnmanaged(u128, *ws_mod.Workspace),
    borrowed_live: std.AutoHashMapUnmanaged(u128, void),

    pub fn open(
        allocator: Allocator,
        io: Io,
        state_dir_path: []const u8,
        checkouts_dir_path: []const u8,
    ) !Worktrees {
        try Io.Dir.cwd().createDirPath(io, state_dir_path);
        try Io.Dir.cwd().createDirPath(io, checkouts_dir_path);
        const hist_dir = try std.fmt.allocPrint(allocator, "{s}/histories", .{state_dir_path});
        defer allocator.free(hist_dir);
        try Io.Dir.cwd().createDirPath(io, hist_dir);

        var self = Worktrees{
            .allocator = allocator,
            .io = io,
            .state_dir_path = try allocator.dupe(u8, state_dir_path),
            .checkouts_dir_path = try allocator.dupe(u8, checkouts_dir_path),
            .entries = .empty,
            .live = .empty,
            .borrowed_live = .empty,
        };
        errdefer self.deinit();

        try self.loadRegistry();
        var loaded = self.entries;
        self.entries = .empty;
        var next_idx: usize = 0;
        var loaded_freed = false;
        errdefer if (!loaded_freed) {
            for (loaded.items[next_idx..]) |*e| e.deinit(allocator);
            loaded.deinit(allocator);
        };
        while (next_idx < loaded.items.len) {
            var e = loaded.items[next_idx];
            next_idx += 1;
            const exists = if (Io.Dir.cwd().openDir(io, e.path, .{})) |d| blk: {
                var dir = d;
                dir.close(io);
                break :blk true;
            } else |_| false;
            if (!exists) {
                e.deinit(allocator);
                continue;
            }
            const ws = allocator.create(ws_mod.Workspace) catch |err| {
                e.deinit(allocator);
                return err;
            };
            ws.* = ws_mod.Workspace.open(allocator, io, e.path, e.state_path, e.history_id) catch {
                allocator.destroy(ws);
                self.entries.append(allocator, e) catch |err| {
                    e.deinit(allocator);
                    return err;
                };
                continue;
            };
            self.live.put(allocator, e.id, ws) catch |err| {
                ws.deinit();
                allocator.destroy(ws);
                e.deinit(allocator);
                return err;
            };
            self.entries.append(allocator, e) catch |err| {
                e.deinit(allocator);
                return err;
            };
        }
        loaded.deinit(allocator);
        loaded_freed = true;
        try self.saveRegistry();
        return self;
    }

    pub fn deinit(self: *Worktrees) void {
        var it = self.live.iterator();
        while (it.next()) |kv| {
            if (!self.borrowed_live.contains(kv.key_ptr.*)) {
                kv.value_ptr.*.deinit();
                self.allocator.destroy(kv.value_ptr.*);
            }
        }
        self.live.deinit(self.allocator);
        self.borrowed_live.deinit(self.allocator);
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.state_dir_path);
        self.allocator.free(self.checkouts_dir_path);
    }

    pub fn isBorrowed(self: *const Worktrees, wt_id: u128) bool {
        return self.borrowed_live.contains(wt_id);
    }

    pub fn attachPrimary(self: *Worktrees, ws: *ws_mod.Workspace, title: []const u8) !WorktreeInfo {
        const wt_id = ws.history.history_id;
        for (self.entries.items) |*e| {
            if (e.id == wt_id) return try e.clone(self.allocator);
        }
        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon = if (Io.Dir.cwd().realPathFile(self.io, ws.root_path, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            ws.root_path;

        var repo = try vcs.detect(self.allocator, self.io, canon);
        defer repo.deinit(self.allocator);

        const title_copy = try self.allocator.dupe(u8, title);
        var info_owned = false;
        errdefer if (!info_owned) self.allocator.free(title_copy);
        const path_copy = try self.allocator.dupe(u8, canon);
        errdefer if (!info_owned) self.allocator.free(path_copy);
        const rr_copy: ?[]u8 = if (repo.kind == .none) null else try self.allocator.dupe(u8, repo.root);
        errdefer if (!info_owned) if (rr_copy) |r| self.allocator.free(r);
        const state_copy = try std.fmt.allocPrint(self.allocator, "{s}/.0ndb", .{canon});
        errdefer if (!info_owned) self.allocator.free(state_copy);

        var info = WorktreeInfo{
            .id = wt_id,
            .title = title_copy,
            .path = path_copy,
            .vcs_kind = repo.kind,
            .repo_root = rr_copy,
            .ref_name = null,
            .state_path = state_copy,
            .history_id = wt_id,
            .created = false,
            .created_ms = id.nowMs(self.io),
            .forked_from = null,
        };
        info_owned = true;
        var in_entries = false;
        errdefer if (!in_entries) info.deinit(self.allocator);

        const out = try info.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }
        try self.borrowed_live.put(self.allocator, wt_id, {});
        errdefer _ = self.borrowed_live.remove(wt_id);
        try self.live.put(self.allocator, wt_id, ws);
        errdefer _ = self.live.remove(wt_id);
        try self.entries.append(self.allocator, info);
        in_entries = true;
        return out;
    }

    pub fn hibernateAll(self: *Worktrees) void {
        var vit = self.live.valueIterator();
        while (vit.next()) |ws_ptr| {
            ws_ptr.*.hibernate();
        }
    }

    pub fn list(self: *const Worktrees) []const WorktreeInfo {
        return self.entries.items;
    }

    pub fn get(self: *const Worktrees, wt_id: u128) ?*const WorktreeInfo {
        for (self.entries.items) |*e| {
            if (e.id == wt_id) return e;
        }
        return null;
    }

    pub fn getWorkspace(self: *Worktrees, wt_id: u128) ?*ws_mod.Workspace {
        return self.live.get(wt_id);
    }

    pub fn adopt(self: *Worktrees, path: []const u8, title: []const u8) !WorktreeInfo {
        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon = if (Io.Dir.cwd().realPathFile(self.io, path, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            path;

        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, canon)) {
                return try e.clone(self.allocator);
            }
        }

        var repo = try vcs.detect(self.allocator, self.io, canon);
        defer repo.deinit(self.allocator);

        const repo_root_opt: ?[]const u8 = if (repo.kind == .none) null else repo.root;
        return try self.registerNew(
            id.newUuidV7(self.io),
            title,
            canon,
            repo.kind,
            repo_root_opt,
            null,
            id.newUuidV7(self.io),
            false,
            null,
            true,
        );
    }

    pub fn scratch(self: *Worktrees, title: []const u8) !WorktreeInfo {
        const wt_id = id.newUuidV7(self.io);
        var short_buf: [16]u8 = undefined;
        const short = id.formatShortId(wt_id, &short_buf);
        const slug = try slugify(self.allocator, title);
        defer self.allocator.free(slug);
        const folder = try std.fmt.allocPrint(self.allocator, "{s}/scratch/{s}-{s}", .{ self.checkouts_dir_path, slug, short[0..6] });
        defer self.allocator.free(folder);
        try Io.Dir.cwd().createDirPath(self.io, folder);

        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon = if (Io.Dir.cwd().realPathFile(self.io, folder, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            folder;

        return try self.registerNew(
            wt_id,
            title,
            canon,
            .none,
            null,
            null,
            id.newUuidV7(self.io),
            true,
            null,
            false,
        );
    }

    pub fn fork(
        self: *Worktrees,
        source_id: u128,
        title: []const u8,
        at_version_opt: ?*const Version,
        ref_name_opt: ?[]const u8,
    ) !WorktreeInfo {
        const src_info_ptr = self.get(source_id) orelse return error.WorktreeNotFound;
        var src_info = try src_info_ptr.clone(self.allocator);
        defer src_info.deinit(self.allocator);

        const src_ws = self.getWorkspace(source_id) orelse return error.WorktreeNotFound;
        _ = try src_ws.ingestDisk();

        var fork_ver = if (at_version_opt) |v|
            try v.clone(self.allocator)
        else
            try src_ws.history.headsClone();
        defer fork_ver.deinit(self.allocator);

        const slug = try slugify(self.allocator, title);
        defer self.allocator.free(slug);
        const group_base = std.fs.path.basename(src_info.repo_root orelse src_info.path);
        const group_slug = try slugify(self.allocator, if (group_base.len > 0) group_base else "folder");
        defer self.allocator.free(group_slug);

        const dest_path = try self.uniqueCheckoutPath(group_slug, slug);
        defer self.allocator.free(dest_path);

        const wt_id = id.newUuidV7(self.io);
        var auto_ref: ?[]u8 = null;
        defer if (auto_ref) |ar| self.allocator.free(ar);
        const effective_ref: ?[]const u8 = if (ref_name_opt) |rn|
            rn
        else if (src_info.vcs_kind != .none) blk: {
            var sbuf: [16]u8 = undefined;
            const sh = id.formatShortId(wt_id, &sbuf);
            auto_ref = try std.fmt.allocPrint(self.allocator, "{s}{s}-{s}", .{ BRANCH_PREFIX, slug, sh[0..6] });
            break :blk auto_ref.?;
        } else null;

        var src_head = vcs.head(self.allocator, self.io, src_info.path) catch vcs.VcsHead{};
        defer src_head.deinit(self.allocator);

        try vcs.addWorkspace(
            self.allocator,
            self.io,
            src_info.vcs_kind,
            src_info.repo_root orelse src_info.path,
            dest_path,
            effective_ref,
            src_head.rev,
        );
        errdefer vcs.removeWorkspace(
            self.allocator,
            self.io,
            src_info.vcs_kind,
            src_info.repo_root,
            dest_path,
            effective_ref,
            true,
        ) catch {};

        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon_dest = if (Io.Dir.cwd().realPathFile(self.io, dest_path, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            dest_path;

        var fork_ws_path_owned: ?[]u8 = null;
        defer if (fork_ws_path_owned) |p| self.allocator.free(p);
        if (src_info.vcs_kind != .none) {
            if (src_info.repo_root) |rr| {
                if (src_info.path.len > rr.len + 1 and std.mem.startsWith(u8, src_info.path, rr) and src_info.path[rr.len] == '/') {
                    const rel_sub = src_info.path[rr.len + 1 ..];
                    const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ canon_dest, rel_sub });
                    try Io.Dir.cwd().createDirPath(self.io, sub_path);
                    fork_ws_path_owned = sub_path;
                }
            }
        }
        const effective_ws_path = fork_ws_path_owned orelse canon_dest;

        const origin = ForkOrigin{
            .source_id = source_id,
            .fork_version = try fork_ver.clone(self.allocator),
            .shared = true,
        };

        var info = try self.registerNew(
            wt_id,
            title,
            effective_ws_path,
            src_info.vcs_kind,
            src_info.repo_root,
            effective_ref,
            src_info.history_id,
            true,
            origin,
            false,
        );
        errdefer info.deinit(self.allocator);

        const fork_ws = self.getWorkspace(wt_id).?;
        const batches = try src_ws.exportAncestors(self.allocator, &fork_ver);
        defer {
            for (batches) |*b| b.deinit(self.allocator);
            self.allocator.free(batches);
        }
        for (batches) |*b| {
            _ = try fork_ws.commitBatchWithSource(b, "fork");
        }
        try fork_ws.materializeToDisk();
        return info;
    }

    pub fn conflicts(self: *Worktrees, fork_id: u128) ![]Conflict {
        const info = self.get(fork_id) orelse return error.WorktreeNotFound;
        const ws = self.getWorkspace(fork_id) orelse return error.WorktreeNotFound;
        _ = try ws.ingestDisk();

        const stored = try self.loadConflicts(info.state_path);
        defer {
            for (stored) |*c| c.deinit(self.allocator);
            self.allocator.free(stored);
        }

        var open_list: std.ArrayList(Conflict) = .empty;
        errdefer {
            for (open_list.items) |*c| c.deinit(self.allocator);
            open_list.deinit(self.allocator);
        }

        for (stored) |*c| {
            if (c.kind == .text) {
                const cur = try ws.history.readFileAt(self.allocator, c.path, null);
                defer if (cur) |b| self.allocator.free(b);
                if (cur == null or std.mem.indexOf(u8, cur.?, CONFLICT_MARKER) == null) {
                    continue;
                }
            }
            try open_list.append(self.allocator, try c.clone(self.allocator));
        }

        if (open_list.items.len != stored.len) {
            try self.saveConflicts(info.state_path, open_list.items);
        }
        return try open_list.toOwnedSlice(self.allocator);
    }

    fn resolveFileMeta(
        ws: *const ws_mod.Workspace,
        iid: id.InodeId,
        view: text_mod.View,
    ) struct { mode: tree_mod.FileMode, ending: tree_mod.LineEnding } {
        if (ws.history.tree.get(iid)) |inode| {
            if (inode.fileConstPtr()) |f| {
                const m = if (f.mode.getIn(view)) |mv| mv.* else tree_mod.FileMode.regular;
                const e = if (f.line_ending.getIn(view)) |ev| ev.* else tree_mod.LineEnding.lf;
                return .{ .mode = m, .ending = e };
            }
        }
        return .{ .mode = .regular, .ending = .lf };
    }

    fn mergeMode(base: tree_mod.FileMode, ours: tree_mod.FileMode, theirs: tree_mod.FileMode) tree_mod.FileMode {
        if (ours == theirs) return ours;
        if (ours == base) return theirs;
        if (theirs == base) return ours;
        return if (ours == .executable or theirs == .executable) .executable else .regular;
    }

    fn mergeEnding(base: tree_mod.LineEnding, ours: tree_mod.LineEnding, theirs: tree_mod.LineEnding) tree_mod.LineEnding {
        if (ours == theirs) return ours;
        if (ours == base) return theirs;
        if (theirs == base) return ours;
        return ours;
    }

    fn removeInodeDirect(self: *Worktrees, ws: *ws_mod.Workspace, iid: id.InodeId) !void {
        const old_path = try ws.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid);
        defer if (old_path) |p| self.allocator.free(p);
        var batch_owned = false;
        var parents = try ws.history.headsClone();
        errdefer if (!batch_owned) parents.deinit(self.allocator);
        const ts = ws.history.nextStartTs(&parents);
        const ops = try self.allocator.alloc(op_mod.Op, 1);
        errdefer if (!batch_owned) self.allocator.free(ops);
        ops[0] = .{ .remove = .{ .inode = iid } };
        const blobs_empty = try self.allocator.alloc(op_mod.BlobAttachment, 0);
        var batch = op_mod.Batch{
            .header = .{
                .actor = ws.disk_actor,
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
        _ = try ws.commitBatchWithSource(&batch, "sync-dedup");
        if (old_path) |p| {
            ws.work_dir.deleteFile(self.io, p) catch {};
        }
    }

    fn writeMergedFileWithMeta(
        self: *Worktrees,
        ws: *ws_mod.Workspace,
        rel_path: []const u8,
        bytes: []const u8,
        mode: tree_mod.FileMode,
        ending: tree_mod.LineEnding,
    ) !void {
        _ = try ws.writeFileDirect(ws.disk_actor, rel_path, bytes);
        const iid = (try ws.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, rel_path)) orelse return;
        const inode = ws.history.tree.get(iid) orelse return;
        const f = inode.fileConstPtr() orelse return;
        const cur_mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
        const cur_end = if (f.line_ending.get()) |e| e.* else tree_mod.LineEnding.lf;
        if (cur_mode == mode and cur_end == ending) return;

        var ops: std.ArrayList(op_mod.Op) = .empty;
        errdefer ops.deinit(self.allocator);
        if (cur_mode != mode) {
            try ops.append(self.allocator, .{ .set_mode = .{ .inode = iid, .mode = mode } });
        }
        if (cur_end != ending) {
            try ops.append(self.allocator, .{ .set_line_ending = .{ .inode = iid, .ending = ending } });
        }
        if (ops.items.len == 0) return;

        var batch_owned = false;
        var parents = try ws.history.headsClone();
        errdefer if (!batch_owned) parents.deinit(self.allocator);
        const start = ws.history.nextStartTs(&parents);
        const ops_slice = try ops.toOwnedSlice(self.allocator);
        errdefer if (!batch_owned) self.allocator.free(ops_slice);
        const blobs_empty = try self.allocator.alloc(op_mod.BlobAttachment, 0);
        var batch = op_mod.Batch{
            .header = .{
                .actor = ws.disk_actor,
                .start = start,
                .end = start + @as(u64, @intCast(ops_slice.len)) - 1,
                .parents = parents,
                .wall_ms = id.nowMs(self.io),
            },
            .ops = ops_slice,
            .blobs = blobs_empty,
        };
        batch_owned = true;
        defer batch.deinit(self.allocator);
        _ = try ws.commitBatchWithSource(&batch, "sync-meta");
        const touched = [_][]const u8{rel_path};
        try ws.materializePaths(&touched);
    }

    pub fn syncFork(self: *Worktrees, fork_id: u128) !SyncReport {
        const info_ptr = self.get(fork_id) orelse return error.WorktreeNotFound;
        const origin = info_ptr.forked_from orelse return error.NotAFork;
        if (!origin.shared) return error.HistoryNotShared;
        const fork_state_path = try self.allocator.dupe(u8, info_ptr.state_path);
        defer self.allocator.free(fork_state_path);

        const fork_ws = self.getWorkspace(fork_id) orelse return error.WorktreeNotFound;
        const src_ws = self.getWorkspace(origin.source_id) orelse return error.WorktreeNotFound;

        _ = try fork_ws.ingestDisk();
        _ = try src_ws.ingestDisk();

        const incoming = try src_ws.exportMissing(self.allocator, &fork_ws.history.dag);
        defer {
            for (incoming) |*b| b.deinit(self.allocator);
            self.allocator.free(incoming);
        }

        if (incoming.len == 0) {
            const cur_conflicts = try self.conflicts(fork_id);
            return .{ .brought = 0, .merged = &.{}, .conflicts = cur_conflicts };
        }

        var ours_only_ids: std.ArrayList(id.BatchId) = .empty;
        defer ours_only_ids.deinit(self.allocator);
        {
            var all_bids = try fork_ws.history.dag.collectAllBatchIds(self.allocator);
            defer all_bids.deinit(self.allocator);
            for (all_bids.items) |bid| {
                if (!src_ws.history.dag.containsBatch(bid)) {
                    try ours_only_ids.append(self.allocator, bid);
                }
            }
        }

        var base_cv = try fork_ws.history.dag.compileExcluding(self.allocator, ours_only_ids.items);
        defer base_cv.deinit(self.allocator);
        const base_view = base_cv.view();

        const Clash = struct {
            iid: id.InodeId,
            extra_iid: ?id.InodeId,
            path: []u8,
            base: ?[]u8,
            ours: ?[]u8,
            theirs: ?[]u8,
            mode: tree_mod.FileMode,
            ending: tree_mod.LineEnding,

            fn deinit(c: *@This(), alloc: Allocator) void {
                alloc.free(c.path);
                if (c.base) |b| alloc.free(b);
                if (c.ours) |b| alloc.free(b);
                if (c.theirs) |b| alloc.free(b);
            }
        };

        var clashes: std.ArrayList(Clash) = .empty;
        defer {
            for (clashes.items) |*c| c.deinit(self.allocator);
            clashes.deinit(self.allocator);
        }

        if (ours_only_ids.items.len > 0) {
            var ours_inodes = try fork_ws.collectTouchedInodes(self.allocator, ours_only_ids.items);
            defer ours_inodes.deinit(self.allocator);

            var theirs_inodes: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
            defer theirs_inodes.deinit(self.allocator);
            for (incoming) |*b| {
                for (b.ops, 0..) |*operation, idx| {
                    const maybe_iid: ?id.InodeId = switch (operation.*) {
                        .create_file, .create_symlink => id.InodeId.init(b.header.opId(idx), 0),
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
                        try theirs_inodes.put(self.allocator, iid, {});
                    }
                }
            }

            var seen_paths: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var pit = seen_paths.keyIterator();
                while (pit.next()) |k| self.allocator.free(k.*);
                seen_paths.deinit(self.allocator);
            }

            var oit = ours_inodes.keyIterator();
            while (oit.next()) |iid_ptr| {
                const iid = iid_ptr.*;
                if (!theirs_inodes.contains(iid)) continue;

                const path_opt = (try fork_ws.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) orelse
                    (try src_ws.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) orelse
                    (try fork_ws.history.tree.pathOf(self.allocator, base_view, iid));
                const p = path_opt orelse continue;
                errdefer self.allocator.free(p);

                const b_bytes = try fork_ws.history.readInodeInView(self.allocator, iid, base_view);
                errdefer if (b_bytes) |b| self.allocator.free(b);
                const o_bytes = try fork_ws.history.readInodeInView(self.allocator, iid, text_mod.View.EVERYTHING);
                errdefer if (o_bytes) |b| self.allocator.free(b);
                const t_bytes = try src_ws.history.readInodeInView(self.allocator, iid, text_mod.View.EVERYTHING);
                errdefer if (t_bytes) |b| self.allocator.free(b);

                const ours_changed = !optBytesEql(b_bytes, o_bytes);
                const theirs_changed = !optBytesEql(b_bytes, t_bytes);
                if (ours_changed and theirs_changed) {
                    const bm = resolveFileMeta(fork_ws, iid, base_view);
                    const om = resolveFileMeta(fork_ws, iid, text_mod.View.EVERYTHING);
                    const tm = resolveFileMeta(src_ws, iid, text_mod.View.EVERYTHING);
                    const p_seen = try self.allocator.dupe(u8, p);
                    const gop = try seen_paths.getOrPut(self.allocator, p_seen);
                    if (gop.found_existing) self.allocator.free(p_seen);
                    try clashes.append(self.allocator, .{
                        .iid = iid,
                        .extra_iid = null,
                        .path = p,
                        .base = b_bytes,
                        .ours = o_bytes,
                        .theirs = t_bytes,
                        .mode = mergeMode(bm.mode, om.mode, tm.mode),
                        .ending = mergeEnding(bm.ending, om.ending, tm.ending),
                    });
                } else {
                    self.allocator.free(p);
                    if (b_bytes) |b| self.allocator.free(b);
                    if (o_bytes) |b| self.allocator.free(b);
                    if (t_bytes) |b| self.allocator.free(b);
                }
            }

            var oit2 = ours_inodes.keyIterator();
            while (oit2.next()) |iid_ptr| {
                const iid = iid_ptr.*;
                if (theirs_inodes.contains(iid)) continue;
                const p = (try fork_ws.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, iid)) orelse continue;
                if (seen_paths.contains(p)) {
                    self.allocator.free(p);
                    continue;
                }
                if (try src_ws.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, p)) |t_iid| {
                    if (!t_iid.eql(iid) and theirs_inodes.contains(t_iid)) {
                        const o_bytes = try fork_ws.history.readInodeInView(self.allocator, iid, text_mod.View.EVERYTHING);
                        errdefer if (o_bytes) |b| self.allocator.free(b);
                        const t_bytes = try src_ws.history.readInodeInView(self.allocator, t_iid, text_mod.View.EVERYTHING);
                        errdefer if (t_bytes) |b| self.allocator.free(b);
                        const om = resolveFileMeta(fork_ws, iid, text_mod.View.EVERYTHING);
                        const tm = resolveFileMeta(src_ws, t_iid, text_mod.View.EVERYTHING);
                        const p_seen = try self.allocator.dupe(u8, p);
                        const gop = try seen_paths.getOrPut(self.allocator, p_seen);
                        if (gop.found_existing) self.allocator.free(p_seen);
                        try clashes.append(self.allocator, .{
                            .iid = iid,
                            .extra_iid = t_iid,
                            .path = p,
                            .base = null,
                            .ours = o_bytes,
                            .theirs = t_bytes,
                            .mode = if (om.mode == .executable or tm.mode == .executable) .executable else .regular,
                            .ending = if (om.ending == .crlf or tm.ending == .crlf) .crlf else .lf,
                        });
                        continue;
                    }
                }
                self.allocator.free(p);
            }
        }

        var brought: usize = 0;
        for (incoming) |*b| {
            if (try fork_ws.commitBatchWithSource(b, "sync")) {
                brought += 1;
            }
        }
        try fork_ws.materializeToDisk();

        const existing_conflicts = try self.conflicts(fork_id);
        var conflict_list: std.ArrayList(Conflict) = .empty;
        errdefer {
            for (conflict_list.items) |*c| c.deinit(self.allocator);
            conflict_list.deinit(self.allocator);
        }
        for (existing_conflicts) |c| {
            try conflict_list.append(self.allocator, c);
        }
        self.allocator.free(existing_conflicts);

        var merged_paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (merged_paths.items) |p| self.allocator.free(p);
            merged_paths.deinit(self.allocator);
        }

        for (clashes.items) |*cl| {
            if (cl.extra_iid) |extra| {
                const keep_iid = try fork_ws.history.tree.resolvePath(self.allocator, text_mod.View.EVERYTHING, cl.path);
                if (keep_iid) |kid| {
                    if (kid.eql(cl.iid)) {
                        try self.removeInodeDirect(fork_ws, extra);
                    } else if (kid.eql(extra)) {
                        try self.removeInodeDirect(fork_ws, cl.iid);
                    } else {
                        try self.removeInodeDirect(fork_ws, extra);
                    }
                } else {
                    try self.removeInodeDirect(fork_ws, extra);
                }
            }

            const target_path_owned = if (cl.extra_iid == null)
                (try fork_ws.history.tree.pathOf(self.allocator, text_mod.View.EVERYTHING, cl.iid)) orelse try self.allocator.dupe(u8, cl.path)
            else
                try self.allocator.dupe(u8, cl.path);
            defer self.allocator.free(target_path_owned);
            const target_path = target_path_owned;

            if (optBytesEql(cl.ours, cl.theirs)) {
                if (cl.ours) |o| {
                    try self.writeMergedFileWithMeta(fork_ws, target_path, o, cl.mode, cl.ending);
                } else {
                    _ = try fork_ws.deleteFileDirect(fork_ws.disk_actor, target_path);
                }
                removeConflictByPath(&conflict_list, self.allocator, target_path);
                try merged_paths.append(self.allocator, try self.allocator.dupe(u8, target_path));
                continue;
            }

            if (cl.ours == null and cl.theirs != null) {
                try self.writeMergedFileWithMeta(fork_ws, target_path, cl.theirs.?, cl.mode, cl.ending);
                try upsertConflict(&conflict_list, self.allocator, .{
                    .path = try self.allocator.dupe(u8, target_path),
                    .kind = .deleted_here,
                    .ours = null,
                    .theirs = try self.allocator.dupe(u8, cl.theirs.?),
                });
                continue;
            }

            if (cl.ours != null and cl.theirs == null) {
                try self.writeMergedFileWithMeta(fork_ws, target_path, cl.ours.?, cl.mode, cl.ending);
                try upsertConflict(&conflict_list, self.allocator, .{
                    .path = try self.allocator.dupe(u8, target_path),
                    .kind = .deleted_there,
                    .ours = try self.allocator.dupe(u8, cl.ours.?),
                    .theirs = null,
                });
                continue;
            }

            const ob = cl.ours.?;
            const tb = cl.theirs.?;
            const bb = cl.base orelse "";
            if (isBinary(ob) or isBinary(tb) or isBinary(bb)) {
                try self.writeMergedFileWithMeta(fork_ws, target_path, ob, cl.mode, cl.ending);
                try upsertConflict(&conflict_list, self.allocator, .{
                    .path = try self.allocator.dupe(u8, target_path),
                    .kind = .binary,
                    .ours = try self.allocator.dupe(u8, ob),
                    .theirs = try self.allocator.dupe(u8, tb),
                });
                continue;
            }

            const m = try merge3Lines(self.allocator, bb, ob, tb);
            defer self.allocator.free(m.output);
            try self.writeMergedFileWithMeta(fork_ws, target_path, m.output, cl.mode, cl.ending);
            if (m.has_conflict) {
                try upsertConflict(&conflict_list, self.allocator, .{
                    .path = try self.allocator.dupe(u8, target_path),
                    .kind = .text,
                    .ours = try self.allocator.dupe(u8, ob),
                    .theirs = try self.allocator.dupe(u8, tb),
                });
            } else {
                removeConflictByPath(&conflict_list, self.allocator, target_path);
                try merged_paths.append(self.allocator, try self.allocator.dupe(u8, target_path));
            }
        }

        try self.saveConflicts(fork_state_path, conflict_list.items);
        return .{
            .brought = brought,
            .merged = try merged_paths.toOwnedSlice(self.allocator),
            .conflicts = try conflict_list.toOwnedSlice(self.allocator),
        };
    }

    pub fn resolveConflict(self: *Worktrees, fork_id: u128, rel_path: []const u8, resolution: Resolution) !void {
        const info = self.get(fork_id) orelse return error.WorktreeNotFound;
        const fork_ws = self.getWorkspace(fork_id) orelse return error.WorktreeNotFound;
        const fork_state_path = try self.allocator.dupe(u8, info.state_path);
        defer self.allocator.free(fork_state_path);

        const existing = try self.conflicts(fork_id);
        var list_c: std.ArrayList(Conflict) = .empty;
        defer {
            for (list_c.items) |*c| c.deinit(self.allocator);
            list_c.deinit(self.allocator);
        }
        for (existing) |c| try list_c.append(self.allocator, c);
        self.allocator.free(existing);

        var idx_opt: ?usize = null;
        for (list_c.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.path, rel_path)) {
                idx_opt = i;
                break;
            }
        }
        const idx = idx_opt orelse return error.ConflictNotFound;
        const target = &list_c.items[idx];

        const chosen: ?[]const u8 = switch (resolution) {
            .ours => target.ours,
            .theirs => target.theirs,
            .content => |c| c,
        };

        if (chosen) |bytes| {
            _ = try fork_ws.writeFileDirect(fork_ws.disk_actor, rel_path, bytes);
        } else {
            _ = try fork_ws.deleteFileDirect(fork_ws.disk_actor, rel_path);
        }

        var removed = list_c.orderedRemove(idx);
        removed.deinit(self.allocator);
        try self.saveConflicts(fork_state_path, list_c.items);
    }

    pub fn landFork(self: *Worktrees, fork_id: u128) !LandReport {
        const info_ptr = self.get(fork_id) orelse return error.WorktreeNotFound;
        const origin = info_ptr.forked_from orelse return error.NotAFork;
        if (!origin.shared) return error.HistoryNotShared;
        const src_id = origin.source_id;

        var sync_rep = try self.syncFork(fork_id);
        errdefer sync_rep.deinit(self.allocator);
        if (sync_rep.conflicts.len > 0) {
            return error.UnresolvedConflicts;
        }

        const fork_ws = self.getWorkspace(fork_id) orelse return error.WorktreeNotFound;
        const src_ws = self.getWorkspace(src_id) orelse return error.WorktreeNotFound;

        const outgoing = try fork_ws.exportMissing(self.allocator, &src_ws.history.dag);
        defer {
            for (outgoing) |*b| b.deinit(self.allocator);
            self.allocator.free(outgoing);
        }

        var landed: usize = 0;
        for (outgoing) |*b| {
            if (try src_ws.commitBatchWithSource(b, "land")) {
                landed += 1;
            }
        }
        try src_ws.materializeToDisk();
        return .{ .sync = sync_rep, .landed = landed };
    }

    pub fn remove(self: *Worktrees, wt_id: u128, force: bool, delete_ref: bool) !void {
        if (self.borrowed_live.contains(wt_id)) return error.CannotRemovePrimary;
        var idx_opt: ?usize = null;
        for (self.entries.items, 0..) |e, i| {
            if (e.id == wt_id) {
                idx_opt = i;
                break;
            }
        }
        const idx = idx_opt orelse return error.WorktreeNotFound;
        const info = &self.entries.items[idx];

        if (info.created and !force) {
            const clean = try vcs.isClean(self.allocator, self.io, info.path);
            if (!clean) return error.DirtyWorktree;
        }

        if (self.live.fetchRemove(wt_id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }

        if (info.created) {
            try vcs.removeWorkspace(
                self.allocator,
                self.io,
                info.vcs_kind,
                info.repo_root,
                info.path,
                info.ref_name,
                delete_ref,
            );
        }
        Io.Dir.cwd().deleteTree(self.io, info.state_path) catch {};

        var removed = self.entries.orderedRemove(idx);
        removed.deinit(self.allocator);
        try self.saveRegistry();
    }

    fn registerNew(
        self: *Worktrees,
        wt_id: u128,
        title: []const u8,
        path: []const u8,
        vcs_kind: vcs.VcsKind,
        repo_root: ?[]const u8,
        ref_name: ?[]const u8,
        history_id: u128,
        created: bool,
        forked_from: ?ForkOrigin,
        ingest_initial: bool,
    ) !WorktreeInfo {
        var id_hex: [32]u8 = undefined;
        _ = id.formatIdHex(wt_id, &id_hex);
        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/histories/{s}", .{ self.state_dir_path, id_hex });
        var state_owned = true;
        errdefer if (state_owned) self.allocator.free(state_path);

        const ws = try self.allocator.create(ws_mod.Workspace);
        var ws_owned = true;
        var ws_inited = false;
        errdefer if (ws_owned) {
            if (ws_inited) ws.deinit();
            self.allocator.destroy(ws);
        };
        ws.* = try ws_mod.Workspace.open(self.allocator, self.io, path, state_path, history_id);
        ws_inited = true;

        if (ingest_initial) {
            _ = try ws.ingestDisk();
        }

        const title_copy = try self.allocator.dupe(u8, title);
        var info_owned = false;
        errdefer if (!info_owned) self.allocator.free(title_copy);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer if (!info_owned) self.allocator.free(path_copy);
        const rr_copy: ?[]u8 = if (repo_root) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (!info_owned) if (rr_copy) |r| self.allocator.free(r);
        const ref_copy: ?[]u8 = if (ref_name) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (!info_owned) if (ref_copy) |r| self.allocator.free(r);

        var info = WorktreeInfo{
            .id = wt_id,
            .title = title_copy,
            .path = path_copy,
            .vcs_kind = vcs_kind,
            .repo_root = rr_copy,
            .ref_name = ref_copy,
            .state_path = state_path,
            .history_id = history_id,
            .created = created,
            .created_ms = id.nowMs(self.io),
            .forked_from = forked_from,
        };
        state_owned = false;
        info_owned = true;
        var info_in_entries = false;
        errdefer if (!info_in_entries) info.deinit(self.allocator);

        const out = try info.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }

        try self.live.put(self.allocator, wt_id, ws);
        ws_owned = false;
        errdefer {
            if (self.live.fetchRemove(wt_id)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        }
        try self.entries.append(self.allocator, info);
        info_in_entries = true;
        errdefer {
            var popped = self.entries.pop().?;
            popped.deinit(self.allocator);
        }
        try self.saveRegistry();
        return out;
    }

    fn uniqueCheckoutPath(self: *const Worktrees, group_slug: []const u8, slug: []const u8) ![]u8 {
        const group_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.checkouts_dir_path, group_slug });
        defer self.allocator.free(group_dir);
        try Io.Dir.cwd().createDirPath(self.io, group_dir);

        var candidate = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ group_dir, slug });
        var n: usize = 2;
        while (true) {
            const exists = if (Io.Dir.cwd().statFile(self.io, candidate, .{})) |_| true else |_| false;
            if (!exists) return candidate;
            self.allocator.free(candidate);
            candidate = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{d}", .{ group_dir, slug, n });
            n += 1;
        }
    }

    fn saveRegistry(self: *const Worktrees) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, REGISTRY_MAGIC);
        var persisted_count: u32 = 0;
        for (self.entries.items) |*e| {
            if (!self.borrowed_live.contains(e.id)) persisted_count += 1;
        }
        try w.writeU32(self.allocator, persisted_count);
        for (self.entries.items) |*e| {
            if (self.borrowed_live.contains(e.id)) continue;
            try w.writeU128(self.allocator, e.id);
            try w.writeBytes(self.allocator, e.title);
            try w.writeBytes(self.allocator, e.path);
            try w.writeU8(self.allocator, @intFromEnum(e.vcs_kind));
            try w.writeOptBytes(self.allocator, e.repo_root);
            try w.writeOptBytes(self.allocator, e.ref_name);
            try w.writeBytes(self.allocator, e.state_path);
            try w.writeU128(self.allocator, e.history_id);
            try w.writeU8(self.allocator, if (e.created) 1 else 0);
            try w.writeU64(self.allocator, e.created_ms);
            if (e.forked_from) |*f| {
                try w.writeU8(self.allocator, 1);
                try w.writeU128(self.allocator, f.source_id);
                try f.fork_version.encode(self.allocator, &w);
                try w.writeU8(self.allocator, if (f.shared) 1 else 0);
            } else {
                try w.writeU8(self.allocator, 0);
            }
        }
        try writeAtomicFile(self.allocator, self.io, self.state_dir_path, "worktrees.0ndb", w.items());
    }

    fn loadRegistry(self: *Worktrees) !void {
        const reg_path = try std.fmt.allocPrint(self.allocator, "{s}/worktrees.0ndb", .{self.state_dir_path});
        defer self.allocator.free(reg_path);
        const f = Io.Dir.cwd().openFile(self.io, reg_path, .{}) catch return;
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size == 0 or st.size > 32 * 1024 * 1024) return;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n != buf.len) return;

        var r = codec.Reader.init(buf);
        const magic = r.readU32() catch return;
        if (magic != REGISTRY_MAGIC) return;
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const wt_id = try r.readU128();
            const title = try self.allocator.dupe(u8, try r.readBytes());
            errdefer self.allocator.free(title);
            const path = try self.allocator.dupe(u8, try r.readBytes());
            errdefer self.allocator.free(path);
            const kind_raw = try r.readU8();
            const vcs_kind: vcs.VcsKind = switch (kind_raw) {
                1 => .git,
                else => .none,
            };
            const repo_root = if (try r.readOptBytes()) |b| try self.allocator.dupe(u8, b) else null;
            errdefer if (repo_root) |b| self.allocator.free(b);
            const ref_name = if (try r.readOptBytes()) |b| try self.allocator.dupe(u8, b) else null;
            errdefer if (ref_name) |b| self.allocator.free(b);
            const state_path = try self.allocator.dupe(u8, try r.readBytes());
            errdefer self.allocator.free(state_path);
            const history_id = try r.readU128();
            const created = (try r.readU8()) != 0;
            const created_ms = try r.readU64();
            const has_fork = (try r.readU8()) != 0;
            var forked_from: ?ForkOrigin = null;
            if (has_fork) {
                const sid = try r.readU128();
                var fv = try Version.decode(self.allocator, &r);
                errdefer fv.deinit(self.allocator);
                const shared = (try r.readU8()) != 0;
                forked_from = .{ .source_id = sid, .fork_version = fv, .shared = shared };
            }
            errdefer if (forked_from) |*ff| ff.deinit(self.allocator);
            try self.entries.append(self.allocator, .{
                .id = wt_id,
                .title = title,
                .path = path,
                .vcs_kind = vcs_kind,
                .repo_root = repo_root,
                .ref_name = ref_name,
                .state_path = state_path,
                .history_id = history_id,
                .created = created,
                .created_ms = created_ms,
                .forked_from = forked_from,
            });
        }
    }

    fn saveConflicts(self: *const Worktrees, state_path: []const u8, items: []const Conflict) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, CONFLICTS_MAGIC);
        try w.writeU32(self.allocator, @intCast(items.len));
        for (items) |c| {
            try w.writeBytes(self.allocator, c.path);
            try w.writeU8(self.allocator, @intFromEnum(c.kind));
            try w.writeOptBytes(self.allocator, c.ours);
            try w.writeOptBytes(self.allocator, c.theirs);
        }
        try writeAtomicFile(self.allocator, self.io, state_path, "conflicts.0ndb", w.items());
    }

    fn loadConflicts(self: *const Worktrees, state_path: []const u8) ![]Conflict {
        const cpath = try std.fmt.allocPrint(self.allocator, "{s}/conflicts.0ndb", .{state_path});
        defer self.allocator.free(cpath);
        const f = Io.Dir.cwd().openFile(self.io, cpath, .{}) catch return try self.allocator.alloc(Conflict, 0);
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size == 0 or st.size > 32 * 1024 * 1024) return try self.allocator.alloc(Conflict, 0);
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n != buf.len) return try self.allocator.alloc(Conflict, 0);

        var r = codec.Reader.init(buf);
        const magic = r.readU32() catch return try self.allocator.alloc(Conflict, 0);
        if (magic != CONFLICTS_MAGIC) return try self.allocator.alloc(Conflict, 0);
        const count = r.readU32() catch return try self.allocator.alloc(Conflict, 0);

        var out: std.ArrayList(Conflict) = .empty;
        errdefer {
            for (out.items) |*c| c.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        for (0..count) |_| {
            const p = try self.allocator.dupe(u8, try r.readBytes());
            errdefer self.allocator.free(p);
            const kind_raw = try r.readU8();
            const kind: ConflictKind = switch (kind_raw) {
                2 => .binary,
                3 => .deleted_here,
                4 => .deleted_there,
                else => .text,
            };
            const o = if (try r.readOptBytes()) |b| try self.allocator.dupe(u8, b) else null;
            errdefer if (o) |b| self.allocator.free(b);
            const t = if (try r.readOptBytes()) |b| try self.allocator.dupe(u8, b) else null;
            try out.append(self.allocator, .{ .path = p, .kind = kind, .ours = o, .theirs = t });
        }
        return try out.toOwnedSlice(self.allocator);
    }
};

fn writeAtomicFile(allocator: Allocator, io: Io, dir_path: []const u8, name: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.0ndb-tmp", .{name});
    defer allocator.free(tmp_name);
    const f = try dir.createFile(io, tmp_name, .{ .truncate = true });
    var f_closed = false;
    errdefer {
        if (!f_closed) f.close(io);
        dir.deleteFile(io, tmp_name) catch {};
    }
    try f.writePositionalAll(io, data, 0);
    f.sync(io) catch {};
    f.close(io);
    f_closed = true;
    try dir.rename(tmp_name, dir, name, io);
}

fn slugify(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var prev_dash = true;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, std.ascii.toLower(c));
            prev_dash = false;
        } else if (!prev_dash) {
            try out.append(allocator, '-');
            prev_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, "worktree");
    }
    return try out.toOwnedSlice(allocator);
}

fn optBytesEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn isBinary(bytes: []const u8) bool {
    const check_len = @min(bytes.len, 8192);
    return std.mem.indexOfScalar(u8, bytes[0..check_len], 0) != null;
}

fn removeConflictByPath(list: *std.ArrayList(Conflict), allocator: Allocator, path: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].path, path)) {
            var rem = list.orderedRemove(i);
            rem.deinit(allocator);
        } else {
            i += 1;
        }
    }
}

fn upsertConflict(list: *std.ArrayList(Conflict), allocator: Allocator, item: Conflict) !void {
    removeConflictByPath(list, allocator, item.path);
    try list.append(allocator, item);
}

const LineHunk = struct {
    base_start: usize,
    base_end: usize,
    target_start: usize,
    target_end: usize,
};

fn splitLinesKeepNewline(allocator: Allocator, bytes: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |nl| {
            try lines.append(allocator, bytes[pos .. nl + 1]);
            pos = nl + 1;
        } else {
            try lines.append(allocator, bytes[pos..]);
            pos = bytes.len;
        }
    }
    return try lines.toOwnedSlice(allocator);
}

fn hashLine(line: []const u8) u64 {
    const h = crypto.hashBytes(line);
    return std.mem.readInt(u64, h[0..8], .little);
}

fn diffLinesRec(
    allocator: Allocator,
    base: []const []const u8,
    bh: []const u64,
    b_lo_in: usize,
    b_hi_in: usize,
    target: []const []const u8,
    th: []const u64,
    t_lo_in: usize,
    t_hi_in: usize,
    out: *std.ArrayList(LineHunk),
) Allocator.Error!void {
    var b_lo = b_lo_in;
    var b_hi = b_hi_in;
    var t_lo = t_lo_in;
    var t_hi = t_hi_in;

    while (b_lo < b_hi and t_lo < t_hi and bh[b_lo] == th[t_lo] and std.mem.eql(u8, base[b_lo], target[t_lo])) {
        b_lo += 1;
        t_lo += 1;
    }
    while (b_hi > b_lo and t_hi > t_lo and bh[b_hi - 1] == th[t_hi - 1] and std.mem.eql(u8, base[b_hi - 1], target[t_hi - 1])) {
        b_hi -= 1;
        t_hi -= 1;
    }

    if (b_lo == b_hi and t_lo == t_hi) return;
    if (b_lo == b_hi or t_lo == t_hi) {
        try out.append(allocator, .{
            .base_start = b_lo,
            .base_end = b_hi,
            .target_start = t_lo,
            .target_end = t_hi,
        });
        return;
    }

    const HistEntry = struct {
        count: u32,
        pos: usize,
    };
    var b_hist: std.AutoHashMapUnmanaged(u64, HistEntry) = .empty;
    defer b_hist.deinit(allocator);
    try b_hist.ensureTotalCapacity(allocator, @intCast(b_hi - b_lo));
    for (b_lo..b_hi) |bi| {
        const gop = b_hist.getOrPutAssumeCapacity(bh[bi]);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .count = 1, .pos = bi };
        } else {
            gop.value_ptr.count +|= 1;
        }
    }

    var t_counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer t_counts.deinit(allocator);
    try t_counts.ensureTotalCapacity(allocator, @intCast(t_hi - t_lo));
    for (t_lo..t_hi) |ti| {
        const gop = t_counts.getOrPutAssumeCapacity(th[ti]);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* +| 1 else 1;
    }

    var best_score: u64 = std.math.maxInt(u64);
    var best_len: usize = 0;
    var best_b: usize = 0;
    var best_t: usize = 0;

    var ti = t_lo;
    while (ti < t_hi) : (ti += 1) {
        const h = th[ti];
        const be = b_hist.get(h) orelse continue;
        if (be.count > 64) continue;
        const tc = t_counts.get(h) orelse continue;
        const freq: u64 = @as(u64, be.count) + @as(u64, tc);
        if (freq > best_score) continue;

        if (!std.mem.eql(u8, base[be.pos], target[ti])) continue;

        var bs = be.pos;
        var ts = ti;
        while (bs > b_lo and ts > t_lo and bh[bs - 1] == th[ts - 1] and std.mem.eql(u8, base[bs - 1], target[ts - 1])) {
            bs -= 1;
            ts -= 1;
        }
        var be_end = be.pos + 1;
        var te_end = ti + 1;
        while (be_end < b_hi and te_end < t_hi and bh[be_end] == th[te_end] and std.mem.eql(u8, base[be_end], target[te_end])) {
            be_end += 1;
            te_end += 1;
        }
        const run_len = be_end - bs;
        if (freq < best_score or (freq == best_score and run_len > best_len)) {
            best_score = freq;
            best_len = run_len;
            best_b = bs;
            best_t = ts;
        }
        if (te_end > ti + 1) ti = te_end - 1;
    }

    if (best_len == 0) {
        try out.append(allocator, .{
            .base_start = b_lo,
            .base_end = b_hi,
            .target_start = t_lo,
            .target_end = t_hi,
        });
        return;
    }

    try diffLinesRec(allocator, base, bh, b_lo, best_b, target, th, t_lo, best_t, out);
    try diffLinesRec(allocator, base, bh, best_b + best_len, b_hi, target, th, best_t + best_len, t_hi, out);
}

fn computeLineHunks(allocator: Allocator, base: []const []const u8, target: []const []const u8) ![]LineHunk {
    var hunks: std.ArrayList(LineHunk) = .empty;
    errdefer hunks.deinit(allocator);

    const bh = try allocator.alloc(u64, base.len);
    defer allocator.free(bh);
    for (base, 0..) |l, i| bh[i] = hashLine(l);

    const th = try allocator.alloc(u64, target.len);
    defer allocator.free(th);
    for (target, 0..) |l, i| th[i] = hashLine(l);

    try diffLinesRec(allocator, base, bh, 0, base.len, target, th, 0, target.len, &hunks);
    return try hunks.toOwnedSlice(allocator);
}

fn appendLinesSlice(allocator: Allocator, out: *std.ArrayList(u8), lines: []const []const u8) !void {
    for (lines) |l| try out.appendSlice(allocator, l);
}

fn hunksOverlap(a: LineHunk, b: LineHunk) bool {
    if (a.base_start == a.base_end or b.base_start == b.base_end) {
        return a.base_start <= b.base_end and b.base_start <= a.base_end;
    }
    return a.base_start < b.base_end and b.base_start < a.base_end;
}

pub fn merge3Lines(
    allocator: Allocator,
    base_bytes: []const u8,
    ours_bytes: []const u8,
    theirs_bytes: []const u8,
) !struct { output: []u8, has_conflict: bool } {
    if (std.mem.eql(u8, ours_bytes, theirs_bytes)) {
        return .{ .output = try allocator.dupe(u8, ours_bytes), .has_conflict = false };
    }
    if (std.mem.eql(u8, ours_bytes, base_bytes)) {
        return .{ .output = try allocator.dupe(u8, theirs_bytes), .has_conflict = false };
    }
    if (std.mem.eql(u8, theirs_bytes, base_bytes)) {
        return .{ .output = try allocator.dupe(u8, ours_bytes), .has_conflict = false };
    }

    const base = try splitLinesKeepNewline(allocator, base_bytes);
    defer allocator.free(base);
    const ours = try splitLinesKeepNewline(allocator, ours_bytes);
    defer allocator.free(ours);
    const theirs = try splitLinesKeepNewline(allocator, theirs_bytes);
    defer allocator.free(theirs);

    const oh = try computeLineHunks(allocator, base, ours);
    defer allocator.free(oh);
    const th = try computeLineHunks(allocator, base, theirs);
    defer allocator.free(th);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var has_conflict = false;

    var base_pos: usize = 0;
    var oi: usize = 0;
    var ti: usize = 0;

    while (oi < oh.len or ti < th.len) {
        if (ti >= th.len) {
            const h = oh[oi];
            try appendLinesSlice(allocator, &out, base[base_pos..h.base_start]);
            try appendLinesSlice(allocator, &out, ours[h.target_start..h.target_end]);
            base_pos = h.base_end;
            oi += 1;
            continue;
        }
        if (oi >= oh.len) {
            const h = th[ti];
            try appendLinesSlice(allocator, &out, base[base_pos..h.base_start]);
            try appendLinesSlice(allocator, &out, theirs[h.target_start..h.target_end]);
            base_pos = h.base_end;
            ti += 1;
            continue;
        }

        const ho = oh[oi];
        const ht = th[ti];
        if (!hunksOverlap(ho, ht)) {
            if (ho.base_end <= ht.base_start and (ho.base_start < ht.base_start or ho.base_end < ht.base_end)) {
                try appendLinesSlice(allocator, &out, base[base_pos..ho.base_start]);
                try appendLinesSlice(allocator, &out, ours[ho.target_start..ho.target_end]);
                base_pos = ho.base_end;
                oi += 1;
                continue;
            }
            if (ht.base_end <= ho.base_start and (ht.base_start < ho.base_start or ht.base_end < ho.base_end)) {
                try appendLinesSlice(allocator, &out, base[base_pos..ht.base_start]);
                try appendLinesSlice(allocator, &out, theirs[ht.target_start..ht.target_end]);
                base_pos = ht.base_end;
                ti += 1;
                continue;
            }
        }

        const c_start = @min(ho.base_start, ht.base_start);
        var c_end = @max(ho.base_end, ht.base_end);
        const o_first = oi;
        const t_first = ti;
        oi += 1;
        ti += 1;
        var grew = true;
        while (grew) {
            grew = false;
            while (oi < oh.len and oh[oi].base_start <= c_end) {
                if (oh[oi].base_end > c_end) {
                    c_end = oh[oi].base_end;
                    grew = true;
                }
                oi += 1;
            }
            while (ti < th.len and th[ti].base_start <= c_end) {
                if (th[ti].base_end > c_end) {
                    c_end = th[ti].base_end;
                    grew = true;
                }
                ti += 1;
            }
        }

        try appendLinesSlice(allocator, &out, base[base_pos..c_start]);

        var o_buf: std.ArrayList(u8) = .empty;
        defer o_buf.deinit(allocator);
        {
            var p = c_start;
            for (oh[o_first..oi]) |h| {
                try appendLinesSlice(allocator, &o_buf, base[p..h.base_start]);
                try appendLinesSlice(allocator, &o_buf, ours[h.target_start..h.target_end]);
                p = h.base_end;
            }
            try appendLinesSlice(allocator, &o_buf, base[p..c_end]);
        }

        var t_buf: std.ArrayList(u8) = .empty;
        defer t_buf.deinit(allocator);
        {
            var p = c_start;
            for (th[t_first..ti]) |h| {
                try appendLinesSlice(allocator, &t_buf, base[p..h.base_start]);
                try appendLinesSlice(allocator, &t_buf, theirs[h.target_start..h.target_end]);
                p = h.base_end;
            }
            try appendLinesSlice(allocator, &t_buf, base[p..c_end]);
        }

        if (std.mem.eql(u8, o_buf.items, t_buf.items)) {
            try out.appendSlice(allocator, o_buf.items);
        } else {
            has_conflict = true;
            try out.appendSlice(allocator, "<<<<<<< ours\n");
            try out.appendSlice(allocator, o_buf.items);
            if (o_buf.items.len > 0 and o_buf.items[o_buf.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, "=======\n");
            try out.appendSlice(allocator, t_buf.items);
            if (t_buf.items.len > 0 and t_buf.items[t_buf.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, ">>>>>>> theirs\n");
        }
        base_pos = c_end;
    }

    try appendLinesSlice(allocator, &out, base[base_pos..]);
    return .{ .output = try out.toOwnedSlice(allocator), .has_conflict = has_conflict };
}
