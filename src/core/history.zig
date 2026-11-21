const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const version_mod = @import("version.zig");
const Version = version_mod.Version;
const dag_mod = @import("dag.zig");
const Dag = dag_mod.Dag;
const text_mod = @import("text.zig");
const Text = text_mod.Text;
const View = text_mod.View;
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const op_mod = @import("op.zig");
const diff = @import("diff.zig");

pub const IntegrateError = error{
    MissingParents,
    LamportViolation,
    InvalidRange,
    Overlap,
    OpCountMismatch,
    UnknownInode,
    NotAFile,
    NotASymlink,
    Unordered,
    OutOfBounds,
    LengthMismatch,
    MissingBlob,
};

pub const LogSliceReader = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, offset: u64, len: u32) ?[]const u8,

    pub inline fn read(self: LogSliceReader, offset: u64, len: u32) ?[]const u8 {
        return self.readFn(self.ptr, offset, len);
    }
};

pub const InsertionStorage = union(enum) {
    owned: []u8,
    log_span: struct {
        offset: u64,
        len: u32,
    },

    pub fn deinit(self: *InsertionStorage, allocator: Allocator) void {
        switch (self.*) {
            .owned => |b| allocator.free(b),
            .log_span => {},
        }
    }
};

pub const BlameLine = struct {
    line_no: usize,
    op: id.OpId,
    batch: ?id.BatchId,
    text: []u8,

    pub fn deinit(self: *BlameLine, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

pub const FileChangeKind = enum {
    added,
    modified,
    deleted,
};

pub const FileDelta = struct {
    inode_id: id.InodeId,
    path: []u8,
    kind: FileChangeKind,
    bytes: u64,
    lines: usize,
    lines_added: u32,
    lines_removed: u32,
    splices: []text_mod.TextSplice,

    pub fn deinit(self: *FileDelta, allocator: Allocator) void {
        allocator.free(self.path);
        for (self.splices) |*s| s.deinit(allocator);
        if (self.splices.len > 0) allocator.free(self.splices);
        self.splices = &.{};
    }
};

pub const CommitDelta = struct {
    batch_id: id.BatchId,
    from_version: Version,
    to_version: Version,
    files: []FileDelta,

    pub fn deinit(self: *CommitDelta, allocator: Allocator) void {
        self.from_version.deinit(allocator);
        self.to_version.deinit(allocator);
        for (self.files) |*f| f.deinit(allocator);
        if (self.files.len > 0) allocator.free(self.files);
        self.files = &.{};
    }
};

pub const BufferRebase = struct {
    version: Version,
    splices: []text_mod.TextSplice,
    cursor_start: u64,
    cursor_end: u64,
    lines_added: u32,
    lines_removed: u32,

    pub fn deinit(self: *BufferRebase, allocator: Allocator) void {
        self.version.deinit(allocator);
        for (self.splices) |*s| s.deinit(allocator);
        if (self.splices.len > 0) allocator.free(self.splices);
        self.splices = &.{};
    }
};

const DRAFT_EPHEMERAL_ACTOR: id.ActorId = std.math.maxInt(id.ActorId);

pub const History = struct {
    allocator: Allocator,
    history_id: u128,
    dag: Dag,
    tree: Tree,
    insertions: std.AutoHashMapUnmanaged(id.InsertionKey, InsertionStorage),
    blobs: std.AutoHashMapUnmanaged(id.Oid, InsertionStorage),
    insertion_blobs: std.AutoHashMapUnmanaged(id.InsertionKey, id.Oid),
    meta: std.StringHashMapUnmanaged(tree_mod.Lww(?[]u8)),
    log_reader: ?LogSliceReader = null,

    pub fn init(allocator: Allocator, history_id: u128) Allocator.Error!History {
        return .{
            .allocator = allocator,
            .history_id = history_id,
            .dag = .{},
            .tree = try Tree.init(allocator),
            .insertions = .empty,
            .blobs = .empty,
            .insertion_blobs = .empty,
            .meta = .empty,
            .log_reader = null,
        };
    }

    pub fn deinit(self: *History) void {
        self.dag.deinit(self.allocator);
        self.tree.deinit(self.allocator);
        var iit = self.insertions.valueIterator();
        while (iit.next()) |s| s.deinit(self.allocator);
        self.insertions.deinit(self.allocator);
        var bit = self.blobs.valueIterator();
        while (bit.next()) |s| s.deinit(self.allocator);
        self.blobs.deinit(self.allocator);
        self.insertion_blobs.deinit(self.allocator);
        var mit = self.meta.iterator();
        while (mit.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            for (kv.value_ptr.entries.items) |e| {
                if (e.value) |v| self.allocator.free(v);
            }
            kv.value_ptr.entries.deinit(self.allocator);
        }
        self.meta.deinit(self.allocator);
    }

    pub fn setLogReader(self: *History, reader: ?LogSliceReader) void {
        self.log_reader = reader;
    }

    pub fn pinBatchToLog(
        self: *History,
        batch: *const op_mod.Batch,
        payload_base_offset: u64,
        op_spans: []const op_mod.PayloadSpan,
        blob_spans: []const op_mod.BlobSpan,
    ) void {
        const lr = self.log_reader orelse return;
        for (op_spans) |sp| {
            if (sp.op_index >= batch.ops.len) continue;
            const key = id.InsertionKey{ .op = batch.header.opId(sp.op_index), .part = 0 };
            if (self.insertions.getPtr(key)) |slot| {
                const can_pin = switch (batch.ops[sp.op_index]) {
                    .create_file, .edit_text => true,
                    .set_content => switch (slot.*) {
                        .owned => |b| blk: {
                            if (b.len != sp.len) break :blk false;
                            const log_bytes = lr.read(payload_base_offset + sp.offset, sp.len) orelse break :blk false;
                            break :blk std.mem.eql(u8, b, log_bytes);
                        },
                        .log_span => false,
                    },
                    else => false,
                };
                if (can_pin) {
                    slot.deinit(self.allocator);
                    slot.* = .{ .log_span = .{ .offset = payload_base_offset + sp.offset, .len = sp.len } };
                }
            }
        }
        for (blob_spans) |sp| {
            if (self.blobs.getPtr(sp.oid)) |slot| {
                slot.deinit(self.allocator);
                slot.* = .{ .log_span = .{ .offset = payload_base_offset + sp.offset, .len = sp.len } };
            }
        }
    }

    pub fn unpinAllLogSpans(self: *History) Allocator.Error!void {
        const lr = self.log_reader orelse return;
        var iit = self.insertions.valueIterator();
        while (iit.next()) |slot| {
            switch (slot.*) {
                .owned => {},
                .log_span => |sp| {
                    if (lr.read(sp.offset, sp.len)) |bytes| {
                        const copy = try self.allocator.dupe(u8, bytes);
                        slot.* = .{ .owned = copy };
                    }
                },
            }
        }
        var bit = self.blobs.valueIterator();
        while (bit.next()) |slot| {
            switch (slot.*) {
                .owned => {},
                .log_span => |sp| {
                    if (lr.read(sp.offset, sp.len)) |bytes| {
                        const copy = try self.allocator.dupe(u8, bytes);
                        slot.* = .{ .owned = copy };
                    }
                },
            }
        }
    }

    pub fn ownedHeapBytes(self: *const History) usize {
        var total: usize = 0;
        var iit = self.insertions.valueIterator();
        while (iit.next()) |s| {
            switch (s.*) {
                .owned => |b| total += b.len,
                .log_span => {},
            }
        }
        var bit = self.blobs.valueIterator();
        while (bit.next()) |s| {
            switch (s.*) {
                .owned => |b| total += b.len,
                .log_span => {},
            }
        }
        return total;
    }

    fn resolveStorage(self: *const History, s: InsertionStorage) ?[]const u8 {
        return switch (s) {
            .owned => |b| b,
            .log_span => |sp| if (self.log_reader) |lr| lr.read(sp.offset, sp.len) else null,
        };
    }

    pub fn resolver(self: *const History) text_mod.ContentResolver {
        return .{
            .ptr = self,
            .resolveFn = resolveInsertion,
        };
    }

    fn resolveInsertion(ptr: *const anyopaque, key: id.InsertionKey) ?[]const u8 {
        const self: *const History = @ptrCast(@alignCast(ptr));
        if (self.insertions.get(key)) |s| return self.resolveStorage(s);
        if (self.insertion_blobs.get(key)) |oid| {
            if (self.blobs.get(oid)) |bs| return self.resolveStorage(bs);
        }
        return null;
    }

    pub fn resolveBlob(self: *const History, oid: id.Oid) ?[]const u8 {
        const s = self.blobs.get(oid) orelse return null;
        return self.resolveStorage(s);
    }

    pub fn putBlob(self: *History, oid: id.Oid, data: []const u8) Allocator.Error!void {
        if (self.blobs.contains(oid)) return;
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        try self.blobs.put(self.allocator, oid, .{ .owned = copy });
    }

    pub fn headsClone(self: *const History) Allocator.Error!Version {
        return self.dag.heads.clone(self.allocator);
    }

    pub fn nextStartTs(self: *const History, parents: *const Version) id.Lamport {
        return @max(self.dag.max_ts, parents.maxTs()) +| 1;
    }

    pub fn integrate(self: *History, batch: *const op_mod.Batch) (IntegrateError || Allocator.Error)!bool {
        if (batch.header.opCount() != batch.ops.len) return error.OpCountMismatch;
        const already = self.dag.check(&batch.header) catch |err| return switch (err) {
            error.MissingParents => error.MissingParents,
            error.LamportViolation => error.LamportViolation,
            error.InvalidRange => error.InvalidRange,
            error.Overlap => error.Overlap,
        };
        if (already) return false;

        for (batch.blobs) |blob| {
            if (!self.blobs.contains(blob.oid)) {
                try self.blobs.put(self.allocator, blob.oid, .{ .owned = try self.allocator.dupe(u8, blob.data) });
            }
        }

        var cv = try self.dag.compileView(self.allocator, &batch.header.parents);
        defer cv.deinit(self.allocator);
        const parent_view = cv.view();

        const BatchLocalCtx = struct {
            base: View,
            actor: id.ActorId,
            start: id.Lamport,
            cur_ts: id.Lamport,

            fn observes(ptr: *const anyopaque, op: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                if (op.actor == ctx.actor and op.ts >= ctx.start and op.ts < ctx.cur_ts) {
                    return true;
                }
                return ctx.base.observes(op);
            }
        };

        var local_ctx = BatchLocalCtx{
            .base = parent_view,
            .actor = batch.header.actor,
            .start = batch.header.start,
            .cur_ts = batch.header.start,
        };
        const min_unobs = @min(parent_view.min_unobserved, batch.header.start);

        for (batch.ops, 0..) |*operation, idx| {
            const op_id = batch.header.opId(idx);
            local_ctx.cur_ts = op_id.ts;
            const op_view = if (idx == 0) parent_view else View{
                .ptr = &local_ctx,
                .observesFn = BatchLocalCtx.observes,
                .min_unobserved = min_unobs,
            };
            try self.applyOp(op_id, op_view, operation);
        }

        const hdr_copy = try batch.header.clone(self.allocator);
        _ = self.dag.insert(self.allocator, hdr_copy) catch |err| return switch (err) {
            error.MissingParents => error.MissingParents,
            error.LamportViolation => error.LamportViolation,
            error.InvalidRange => error.InvalidRange,
            error.Overlap => error.Overlap,
            error.OutOfMemory => error.OutOfMemory,
        };
        return true;
    }

    pub fn isKnownVersion(self: *const History, v: *const Version) bool {
        for (v.slice()) |bid| {
            if (!self.dag.containsBatch(bid)) return false;
        }
        return true;
    }

    pub fn integrateWithDelta(
        self: *History,
        allocator: Allocator,
        batch: *const op_mod.Batch,
    ) (IntegrateError || Allocator.Error)!?CommitDelta {
        var from_version = try self.dag.heads.clone(allocator);
        errdefer from_version.deinit(allocator);

        const PrevSnap = struct { bytes: u64, lines: usize };
        var set_content_prev: std.AutoHashMapUnmanaged(id.InodeId, PrevSnap) = .empty;
        defer set_content_prev.deinit(allocator);

        for (batch.ops) |*operation| {
            if (operation.* == .set_content) {
                const iid = operation.set_content.inode;
                if (!set_content_prev.contains(iid)) {
                    if (self.tree.get(iid)) |inode| {
                        if (inode.fileConstPtr()) |f| {
                            try set_content_prev.put(allocator, iid, .{
                                .bytes = f.text.visibleLen(),
                                .lines = f.text.lineCount(),
                            });
                        }
                    }
                }
            }
        }

        const applied = try self.integrate(batch);
        if (!applied) {
            from_version.deinit(allocator);
            return null;
        }

        var to_version = try self.dag.heads.clone(allocator);
        errdefer to_version.deinit(allocator);

        const BeforeBatchCtx = struct {
            actor: id.ActorId,
            start: id.Lamport,
            end: id.Lamport,
            fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                return !(ctx.actor == op_id.actor and op_id.ts >= ctx.start and op_id.ts <= ctx.end);
            }
        };
        const bctx = BeforeBatchCtx{
            .actor = batch.header.actor,
            .start = batch.header.start,
            .end = batch.header.end,
        };
        const before_view = View{
            .ptr = &bctx,
            .observesFn = BeforeBatchCtx.observes,
            .min_unobserved = batch.header.start,
        };

        var touched: std.ArrayList(id.InodeId) = .empty;
        defer touched.deinit(allocator);
        var seen: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer seen.deinit(allocator);

        for (batch.ops, 0..) |*operation, idx| {
            const maybe_iid: ?id.InodeId = switch (operation.*) {
                .create_file => id.InodeId.init(batch.header.opId(idx), 0),
                .edit_text => |v| v.inode,
                .set_content => |v| v.inode,
                .remove => |v| v.inode,
                .restore => |v| v.inode,
                .rename => |v| v.inode,
                else => null,
            };
            if (maybe_iid) |iid| {
                const gop = try seen.getOrPut(allocator, iid);
                if (!gop.found_existing) {
                    try touched.append(allocator, iid);
                }
            }
        }

        var files: std.ArrayList(FileDelta) = .empty;
        errdefer {
            for (files.items) |*fd| fd.deinit(allocator);
            files.deinit(allocator);
        }

        const res = self.resolver();
        for (touched.items) |iid| {
            const inode = self.tree.get(iid) orelse continue;
            const f = inode.fileConstPtr() orelse continue;
            const before_alive = if (inode.alive.getIn(before_view)) |a| a.* else false;
            const after_alive = if (inode.alive.get()) |a| a.* else false;
            if (!before_alive and !after_alive) continue;

            const before_path = if (before_alive) try self.tree.pathOf(allocator, before_view, iid) else null;
            defer if (before_path) |p| allocator.free(p);
            const after_path = if (after_alive) try self.tree.pathOf(allocator, View.EVERYTHING, iid) else null;
            defer if (after_path) |p| allocator.free(p);

            if (before_alive and !after_alive) {
                const p = before_path orelse continue;
                const old_lines = f.text.lineCount();
                try files.append(allocator, .{
                    .inode_id = iid,
                    .path = try allocator.dupe(u8, p),
                    .kind = .deleted,
                    .bytes = 0,
                    .lines = 0,
                    .lines_added = 0,
                    .lines_removed = @intCast(old_lines),
                    .splices = &.{},
                });
                continue;
            }

            const ap = after_path orelse continue;
            const bytes_len = f.text.visibleLen();
            const lines_cnt = f.text.lineCount();
            const is_text = if (f.content.get()) |ck| ck.* == .text else false;

            if (!before_alive or before_path == null or !std.mem.eql(u8, before_path.?, ap)) {
                if (before_alive) {
                    if (before_path) |bp| {
                        const old_lines = f.text.lineCount();
                        try files.append(allocator, .{
                            .inode_id = iid,
                            .path = try allocator.dupe(u8, bp),
                            .kind = .deleted,
                            .bytes = 0,
                            .lines = 0,
                            .lines_added = 0,
                            .lines_removed = @intCast(old_lines),
                            .splices = &.{},
                        });
                    }
                }
                var splices: []text_mod.TextSplice = &.{};
                if (is_text and bytes_len > 0) {
                    if (try f.text.read(allocator, res)) |content| {
                        errdefer allocator.free(content);
                        splices = try allocator.alloc(text_mod.TextSplice, 1);
                        splices[0] = .{ .at = 0, .del = 0, .text = content };
                    }
                }
                errdefer {
                    for (splices) |*s| s.deinit(allocator);
                    if (splices.len > 0) allocator.free(splices);
                }
                try files.append(allocator, .{
                    .inode_id = iid,
                    .path = try allocator.dupe(u8, ap),
                    .kind = .added,
                    .bytes = bytes_len,
                    .lines = lines_cnt,
                    .lines_added = @intCast(lines_cnt),
                    .lines_removed = 0,
                    .splices = splices,
                });
                continue;
            }

            if (set_content_prev.get(iid)) |prev| {
                var splices: []text_mod.TextSplice = &.{};
                if (is_text) {
                    if (try f.text.read(allocator, res)) |content| {
                        errdefer allocator.free(content);
                        splices = try allocator.alloc(text_mod.TextSplice, 1);
                        splices[0] = .{ .at = 0, .del = prev.bytes, .text = content };
                    }
                }
                errdefer {
                    for (splices) |*s| s.deinit(allocator);
                    if (splices.len > 0) allocator.free(splices);
                }
                try files.append(allocator, .{
                    .inode_id = iid,
                    .path = try allocator.dupe(u8, ap),
                    .kind = .modified,
                    .bytes = bytes_len,
                    .lines = lines_cnt,
                    .lines_added = @intCast(lines_cnt),
                    .lines_removed = @intCast(prev.lines),
                    .splices = splices,
                });
                continue;
            }

            if (!is_text) continue;
            var vd = try f.text.diffViews(allocator, res, before_view, View.EVERYTHING);
            if (vd.splices.len == 0) {
                vd.deinit(allocator);
                continue;
            }
            errdefer vd.deinit(allocator);
            try files.append(allocator, .{
                .inode_id = iid,
                .path = try allocator.dupe(u8, ap),
                .kind = .modified,
                .bytes = bytes_len,
                .lines = lines_cnt,
                .lines_added = vd.lines_added,
                .lines_removed = vd.lines_removed,
                .splices = vd.splices,
            });
        }

        return .{
            .batch_id = batch.header.batchId(),
            .from_version = from_version,
            .to_version = to_version,
            .files = try files.toOwnedSlice(allocator),
        };
    }

    pub fn rebaseBuffer(
        self: *const History,
        allocator: Allocator,
        rel_path: []const u8,
        base_version: *const Version,
        draft_bytes: []const u8,
        cursor_start: u64,
        cursor_end: u64,
    ) Allocator.Error!?BufferRebase {
        if (base_version.eql(&self.dag.heads)) {
            return .{
                .version = try self.dag.heads.clone(allocator),
                .splices = &.{},
                .cursor_start = cursor_start,
                .cursor_end = cursor_end,
                .lines_added = 0,
                .lines_removed = 0,
            };
        }

        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.get() orelse return null;
        if (ck.* != .text) return null;

        var cv = try self.dag.compileView(allocator, base_version);
        defer cv.deinit(allocator);
        const base_view = cv.view();

        const res = self.resolver();
        const base_bytes_opt = try f.text.readIn(allocator, res, base_view);
        defer if (base_bytes_opt) |b| allocator.free(b);
        const base_bytes = base_bytes_opt orelse "";

        if (std.mem.eql(u8, base_bytes, draft_bytes)) {
            var vd = try f.text.diffViews(allocator, res, base_view, View.EVERYTHING);
            errdefer vd.deinit(allocator);
            const cur_s = text_mod.mapCursor(cursor_start, vd.splices);
            const cur_e = text_mod.mapCursor(cursor_end, vd.splices);
            return .{
                .version = try self.dag.heads.clone(allocator),
                .splices = vd.splices,
                .cursor_start = cur_s,
                .cursor_end = cur_e,
                .lines_added = vd.lines_added,
                .lines_removed = vd.lines_removed,
            };
        }

        var local_diff = try diff.diffBytes(allocator, base_bytes, draft_bytes);
        defer local_diff.deinit(allocator);

        var merged = f.text.share();
        defer merged.deinit(allocator);

        const draft_op = id.OpId.init(self.dag.max_ts +| 1, DRAFT_EPHEMERAL_ACTOR);
        merged.apply(
            allocator,
            draft_op,
            base_view,
            local_diff.splices.items,
            local_diff.inserted.items,
            res,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };

        const DraftResolverCtx = struct {
            base: text_mod.ContentResolver,
            draft_key: id.InsertionKey,
            draft_text: []const u8,
            fn resolve(ptr: *const anyopaque, key: id.InsertionKey) ?[]const u8 {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                if (key.part == ctx.draft_key.part and key.op.eql(ctx.draft_key.op)) {
                    return ctx.draft_text;
                }
                return ctx.base.resolve(key);
            }
        };
        const dr_ctx = DraftResolverCtx{
            .base = res,
            .draft_key = .{ .op = draft_op, .part = 0 },
            .draft_text = local_diff.inserted.items,
        };
        const draft_resolver = text_mod.ContentResolver{
            .ptr = &dr_ctx,
            .resolveFn = DraftResolverCtx.resolve,
        };

        const DraftViewCtx = struct {
            base: View,
            draft_op: id.OpId,
            fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                if (op_id.eql(ctx.draft_op)) return true;
                return ctx.base.observes(op_id);
            }
        };
        const dv_ctx = DraftViewCtx{
            .base = base_view,
            .draft_op = draft_op,
        };
        const draft_view = View{
            .ptr = &dv_ctx,
            .observesFn = DraftViewCtx.observes,
            .min_unobserved = base_view.min_unobserved,
        };

        var vd = try merged.diffViews(allocator, draft_resolver, draft_view, View.EVERYTHING);
        errdefer vd.deinit(allocator);
        const cur_s = text_mod.mapCursor(cursor_start, vd.splices);
        const cur_e = text_mod.mapCursor(cursor_end, vd.splices);
        return .{
            .version = try self.dag.heads.clone(allocator),
            .splices = vd.splices,
            .cursor_start = cur_s,
            .cursor_end = cur_e,
            .lines_added = vd.lines_added,
            .lines_removed = vd.lines_removed,
        };
    }

    fn applyOp(self: *History, op_id: id.OpId, view: View, operation: *const op_mod.Op) (IntegrateError || Allocator.Error)!void {
        switch (operation.*) {
            .create_dir => |v| {
                if (!self.tree.contains(v.parent)) return error.UnknownInode;
                const inode = try self.allocator.create(tree_mod.Inode);
                inode.* = .{ .inode_id = id.InodeId.init(op_id, 0), .kind = .dir };
                errdefer {
                    inode.deinit(self.allocator);
                    self.allocator.destroy(inode);
                }
                try inode.alive.set(self.allocator, op_id, true);
                try inode.placement.set(self.allocator, op_id, .{
                    .parent = v.parent,
                    .name = try self.allocator.dupe(u8, v.name),
                });
                try self.tree.insertInode(self.allocator, inode);
            },
            .create_file => |v| {
                if (!self.tree.contains(v.parent)) return error.UnknownInode;
                const inode = try self.allocator.create(tree_mod.Inode);
                inode.* = .{ .inode_id = id.InodeId.init(op_id, 0), .kind = .{ .file = .{} } };
                errdefer {
                    inode.deinit(self.allocator);
                    self.allocator.destroy(inode);
                }
                try inode.alive.set(self.allocator, op_id, true);
                try inode.placement.set(self.allocator, op_id, .{
                    .parent = v.parent,
                    .name = try self.allocator.dupe(u8, v.name),
                });
                const f = inode.filePtr().?;
                try f.mode.set(self.allocator, op_id, v.mode);
                try f.line_ending.set(self.allocator, op_id, v.line_ending);
                try self.initFileContent(f, op_id, &v.content);
                try self.tree.insertInode(self.allocator, inode);
            },
            .create_symlink => |v| {
                if (!self.tree.contains(v.parent)) return error.UnknownInode;
                const inode = try self.allocator.create(tree_mod.Inode);
                inode.* = .{ .inode_id = id.InodeId.init(op_id, 0), .kind = .{ .symlink = .{} } };
                errdefer {
                    inode.deinit(self.allocator);
                    self.allocator.destroy(inode);
                }
                try inode.alive.set(self.allocator, op_id, true);
                try inode.placement.set(self.allocator, op_id, .{
                    .parent = v.parent,
                    .name = try self.allocator.dupe(u8, v.name),
                });
                try inode.kind.symlink.set(self.allocator, op_id, try self.allocator.dupe(u8, v.target));
                try self.tree.insertInode(self.allocator, inode);
            },
            .rename => |v| {
                if (!self.tree.contains(v.inode) or !self.tree.contains(v.parent)) return error.UnknownInode;
                try self.tree.place(self.allocator, v.inode, op_id, v.parent, v.name);
            },
            .remove => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                if (inode.isDir()) {
                    try self.removeDirSubtree(v.inode, op_id, view);
                } else {
                    try inode.alive.set(self.allocator, op_id, false);
                }
            },
            .restore => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                try inode.alive.set(self.allocator, op_id, true);
            },
            .edit_text => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                const f = inode.filePtr() orelse return error.NotAFile;
                if (v.text.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    const owned = try self.allocator.dupe(u8, v.text);
                    if (self.insertions.getPtr(key)) |prev| prev.deinit(self.allocator);
                    try self.insertions.put(self.allocator, key, .{ .owned = owned });
                }
                f.text.apply(self.allocator, op_id, view, v.splices, v.text, self.resolver()) catch |err| return switch (err) {
                    error.Unordered => error.Unordered,
                    error.OutOfBounds => error.OutOfBounds,
                    error.LengthMismatch => error.LengthMismatch,
                    error.OutOfMemory => error.OutOfMemory,
                };
            },
            .set_content => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                const f = inode.filePtr() orelse return error.NotAFile;
                try self.applySetContent(f, op_id, view, &v.content);
            },
            .set_mode => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                const f = inode.filePtr() orelse return error.NotAFile;
                try f.mode.set(self.allocator, op_id, v.mode);
            },
            .set_line_ending => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                const f = inode.filePtr() orelse return error.NotAFile;
                try f.line_ending.set(self.allocator, op_id, v.ending);
            },
            .set_symlink_target => |v| {
                const inode = self.tree.getMut(v.inode) orelse return error.UnknownInode;
                switch (inode.kind) {
                    .symlink => |*s| try s.set(self.allocator, op_id, try self.allocator.dupe(u8, v.target)),
                    else => return error.NotASymlink,
                }
            },
            .git_checkout => {},
            .meta => |v| {
                const gop = try self.meta.getOrPut(self.allocator, v.key);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.allocator.dupe(u8, v.key);
                    gop.value_ptr.* = .{};
                }
                const val_copy: ?[]u8 = if (v.value) |raw| try self.allocator.dupe(u8, raw) else null;
                try gop.value_ptr.set(self.allocator, op_id, val_copy);
            },
        }
    }

    fn removeDirSubtree(self: *History, dir_iid: id.InodeId, op_id: id.OpId, view: View) Allocator.Error!void {
        var stack: std.ArrayList(id.InodeId) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, dir_iid);

        while (stack.pop()) |cur_iid| {
            const cur = self.tree.getMut(cur_iid) orelse continue;
            try cur.alive.set(self.allocator, op_id, false);
            if (!cur.isDir()) continue;
            var entries = try self.tree.listDir(self.allocator, view, cur_iid);
            defer {
                for (entries.items) |*e| e.deinit(self.allocator);
                entries.deinit(self.allocator);
            }
            for (entries.items) |entry| {
                try stack.append(self.allocator, entry.inode_id);
            }
        }
    }

    fn applySetContent(
        self: *History,
        f: *tree_mod.FileNode,
        op_id: id.OpId,
        view: View,
        content: *const op_mod.Content,
    ) (IntegrateError || Allocator.Error)!void {
        switch (content.*) {
            .text_inline => |bytes| {
                try f.content.set(self.allocator, op_id, .text);
                try self.applySetTextBytes(f, op_id, view, bytes, null);
            },
            .text_blob => |ref| {
                try f.content.set(self.allocator, op_id, .text);
                if (ref.len == 0) {
                    try self.applySetTextBytes(f, op_id, view, "", ref.oid);
                } else if (self.resolveBlob(ref.oid)) |raw_bytes| {
                    const copy = try self.allocator.dupe(u8, raw_bytes);
                    defer self.allocator.free(copy);
                    try self.applySetTextBytes(f, op_id, view, copy, ref.oid);
                } else {
                    return error.MissingBlob;
                }
            },
            .binary => |ref| {
                try f.content.set(self.allocator, op_id, .{ .binary = ref });
            },
        }
    }

    fn applySetTextBytes(
        self: *History,
        f: *tree_mod.FileNode,
        op_id: id.OpId,
        view: View,
        new_bytes: []const u8,
        blob_oid: ?id.Oid,
    ) (IntegrateError || Allocator.Error)!void {
        const vis_len = f.text.lenIn(view);
        if (vis_len == 0) {
            if (new_bytes.len == 0) return;
            const key = id.InsertionKey{ .op = op_id, .part = 0 };
            if (blob_oid) |oid| {
                try self.insertion_blobs.put(self.allocator, key, oid);
            } else {
                const owned = try self.allocator.dupe(u8, new_bytes);
                if (self.insertions.getPtr(key)) |prev| prev.deinit(self.allocator);
                try self.insertions.put(self.allocator, key, .{ .owned = owned });
            }
            const sp = [_]diff.Splice{.{ .at = 0, .del = 0, .ins = new_bytes.len }};
            f.text.apply(self.allocator, op_id, view, &sp, new_bytes, self.resolver()) catch |err| return switch (err) {
                error.Unordered => error.Unordered,
                error.OutOfBounds => error.OutOfBounds,
                error.LengthMismatch => error.LengthMismatch,
                error.OutOfMemory => error.OutOfMemory,
            };
            return;
        }

        const old_bytes = (try f.text.readIn(self.allocator, self.resolver(), view)) orelse try self.allocator.dupe(u8, "");
        defer self.allocator.free(old_bytes);
        var d = try diff.diffBytes(self.allocator, old_bytes, new_bytes);
        defer d.deinit(self.allocator);
        if (d.splices.items.len == 0) return;

        if (d.inserted.items.len > 0) {
            const key = id.InsertionKey{ .op = op_id, .part = 0 };
            const owned = try self.allocator.dupe(u8, d.inserted.items);
            if (self.insertions.getPtr(key)) |prev| prev.deinit(self.allocator);
            try self.insertions.put(self.allocator, key, .{ .owned = owned });
        }
        f.text.apply(self.allocator, op_id, view, d.splices.items, d.inserted.items, self.resolver()) catch |err| return switch (err) {
            error.Unordered => error.Unordered,
            error.OutOfBounds => error.OutOfBounds,
            error.LengthMismatch => error.LengthMismatch,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn initFileContent(self: *History, f: *tree_mod.FileNode, op_id: id.OpId, content: *const op_mod.Content) Allocator.Error!void {
        switch (content.*) {
            .text_inline => |bytes| {
                try f.content.set(self.allocator, op_id, .text);
                if (bytes.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    const owned = try self.allocator.dupe(u8, bytes);
                    if (self.insertions.getPtr(key)) |prev| prev.deinit(self.allocator);
                    try self.insertions.put(self.allocator, key, .{ .owned = owned });
                    f.text.deinit(self.allocator);
                    f.text = try Text.fromInsertion(self.allocator, op_id, 0, 0, bytes.len, bytes);
                } else {
                    f.text.deinit(self.allocator);
                }
            },
            .text_blob => |ref| {
                try f.content.set(self.allocator, op_id, .text);
                if (ref.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    try self.insertion_blobs.put(self.allocator, key, ref.oid);
                    f.text.deinit(self.allocator);
                    f.text = try Text.fromInsertion(self.allocator, op_id, 0, 0, ref.len, self.resolveBlob(ref.oid));
                } else {
                    f.text.deinit(self.allocator);
                }
            },
            .binary => |ref| {
                try f.content.set(self.allocator, op_id, .{ .binary = ref });
            },
        }
    }

    pub fn readInodeInView(self: *const History, allocator: Allocator, iid: id.InodeId, view: View) Allocator.Error!?[]u8 {
        const inode = self.tree.get(iid) orelse return null;
        const alive = inode.alive.getIn(view) orelse return null;
        if (!alive.*) return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.getIn(view) orelse return null;
        return switch (ck.*) {
            .text => try f.text.readIn(allocator, self.resolver(), view),
            .binary => |ref| if (self.resolveBlob(ref.oid)) |b| try allocator.dupe(u8, b) else null,
        };
    }

    pub fn readFileInView(self: *const History, allocator: Allocator, rel_path: []const u8, view: View) Allocator.Error!?[]u8 {
        const iid = try self.tree.resolvePath(allocator, view, rel_path) orelse return null;
        return self.readInodeInView(allocator, iid, view);
    }

    pub fn readFileAt(self: *const History, allocator: Allocator, rel_path: []const u8, at_version: ?*const Version) Allocator.Error!?[]u8 {
        if (at_version) |v| {
            var cv = try self.dag.compileView(allocator, v);
            defer cv.deinit(allocator);
            return self.readFileInView(allocator, rel_path, cv.view());
        }
        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.get() orelse return null;
        return switch (ck.*) {
            .text => try f.text.read(allocator, self.resolver()),
            .binary => |ref| if (self.resolveBlob(ref.oid)) |b| try allocator.dupe(u8, b) else null,
        };
    }

    pub fn readFileLines(
        self: *const History,
        allocator: Allocator,
        rel_path: []const u8,
        start_line: usize,
        max_lines: usize,
    ) Allocator.Error!?[]u8 {
        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.get() orelse return null;
        if (ck.* != .text) return null;
        return try f.text.readLineRange(allocator, self.resolver(), start_line, max_lines);
    }

    pub fn blameFile(self: *const History, allocator: Allocator, rel_path: []const u8) Allocator.Error!?std.ArrayList(BlameLine) {
        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const f = inode.fileConstPtr() orelse return null;
        var spans = try f.text.collectVisibleSpans(allocator, View.EVERYTHING);
        defer {
            for (spans.items) |*s| s.deinit(allocator);
            spans.deinit(allocator);
        }

        var out: std.ArrayList(BlameLine) = .empty;
        errdefer {
            for (out.items) |*l| l.deinit(allocator);
            out.deinit(allocator);
        }
        var cur_line: std.ArrayList(u8) = .empty;
        defer cur_line.deinit(allocator);
        var cur_op = id.OpId.ZERO;
        var line_no: usize = 1;
        const res = self.resolver();

        for (spans.items) |*span| {
            const bytes = res.resolve(span.key()) orelse continue;
            const slice = bytes[@intCast(span.off)..@intCast(span.off + span.len)];
            for (slice) |ch| {
                if (span.ins.greaterThan(cur_op)) cur_op = span.ins;
                if (ch == '\n') {
                    try out.append(allocator, .{
                        .line_no = line_no,
                        .op = cur_op,
                        .batch = self.dag.batchOf(cur_op),
                        .text = try cur_line.toOwnedSlice(allocator),
                    });
                    line_no += 1;
                    cur_op = id.OpId.ZERO;
                } else {
                    try cur_line.append(allocator, ch);
                }
            }
        }
        if (cur_line.items.len > 0) {
            try out.append(allocator, .{
                .line_no = line_no,
                .op = cur_op,
                .batch = self.dag.batchOf(cur_op),
                .text = try cur_line.toOwnedSlice(allocator),
            });
        }
        return out;
    }

    fn appendViewDiffOp(
        allocator: Allocator,
        ops: *std.ArrayList(op_mod.Op),
        iid: id.InodeId,
        f: *const tree_mod.FileNode,
        res: text_mod.ContentResolver,
        target_view: View,
    ) Allocator.Error!void {
        var vd = try f.text.diffViews(allocator, res, View.EVERYTHING, target_view);
        defer vd.deinit(allocator);
        if (vd.splices.len == 0) return;

        var total_ins: usize = 0;
        for (vd.splices) |s| total_ins += s.text.len;
        const splices = try allocator.alloc(diff.Splice, vd.splices.len);
        errdefer allocator.free(splices);
        const inserted = try allocator.alloc(u8, total_ins);
        errdefer allocator.free(inserted);

        var pos: usize = 0;
        for (vd.splices, 0..) |s, i| {
            splices[i] = .{ .at = s.at, .del = s.del, .ins = s.text.len };
            if (s.text.len > 0) {
                @memcpy(inserted[pos .. pos + s.text.len], s.text);
                pos += s.text.len;
            }
        }
        try ops.append(allocator, .{ .edit_text = .{
            .inode = iid,
            .text = inserted,
            .splices = splices,
        } });
    }

    fn appendNodeRevertOps(
        self: *const History,
        allocator: Allocator,
        ops: *std.ArrayList(op_mod.Op),
        blobs: *std.ArrayList(op_mod.BlobAttachment),
        iid: id.InodeId,
        inode: *const tree_mod.Inode,
        res: text_mod.ContentResolver,
        target_view: View,
    ) Allocator.Error!void {
        switch (inode.kind) {
            .dir => {},
            .file => |*f| {
                const now_mode = if (f.mode.get()) |m| m.* else tree_mod.FileMode.regular;
                const tgt_mode = if (f.mode.getIn(target_view)) |m| m.* else tree_mod.FileMode.regular;
                if (now_mode != tgt_mode) {
                    try ops.append(allocator, .{ .set_mode = .{ .inode = iid, .mode = tgt_mode } });
                }

                const now_le = if (f.line_ending.get()) |l| l.* else tree_mod.LineEnding.lf;
                const tgt_le = if (f.line_ending.getIn(target_view)) |l| l.* else tree_mod.LineEnding.lf;
                if (now_le != tgt_le) {
                    try ops.append(allocator, .{ .set_line_ending = .{ .inode = iid, .ending = tgt_le } });
                }

                const now_ck = if (f.content.get()) |c| c.* else tree_mod.ContentKind.text;
                const tgt_ck = if (f.content.getIn(target_view)) |c| c.* else tree_mod.ContentKind.text;
                switch (tgt_ck) {
                    .binary => |tref| {
                        const same = switch (now_ck) {
                            .binary => |nref| nref.eql(tref),
                            .text => false,
                        };
                        if (!same) {
                            try ops.append(allocator, .{ .set_content = .{ .inode = iid, .content = .{ .binary = tref } } });
                            var already_attached = false;
                            for (blobs.items) |b| {
                                if (std.mem.eql(u8, &b.oid, &tref.oid)) {
                                    already_attached = true;
                                    break;
                                }
                            }
                            if (!already_attached) {
                                if (self.resolveBlob(tref.oid)) |raw| {
                                    try blobs.append(allocator, .{
                                        .oid = tref.oid,
                                        .data = try allocator.dupe(u8, raw),
                                    });
                                }
                            }
                        }
                    },
                    .text => {
                        switch (now_ck) {
                            .binary => {
                                const tgt_text = (try f.text.readIn(allocator, res, target_view)) orelse try allocator.dupe(u8, "");
                                errdefer allocator.free(tgt_text);
                                try ops.append(allocator, .{ .set_content = .{
                                    .inode = iid,
                                    .content = .{ .text_inline = tgt_text },
                                } });
                            },
                            .text => {
                                try appendViewDiffOp(allocator, ops, iid, f, res, target_view);
                            },
                        }
                    },
                }
            },
            .symlink => |*sym| {
                const now_tgt = if (sym.get()) |t| t.* else "";
                const tgt_tgt = if (sym.getIn(target_view)) |t| t.* else "";
                if (!std.mem.eql(u8, now_tgt, tgt_tgt)) {
                    try ops.append(allocator, .{ .set_symlink_target = .{
                        .inode = iid,
                        .target = try allocator.dupe(u8, tgt_tgt),
                    } });
                }
            },
        }
    }

    pub fn buildRollbackBatch(
        self: *const History,
        allocator: Allocator,
        actor: id.ActorId,
        target_version: *const Version,
        wall_ms: u64,
    ) Allocator.Error!?op_mod.Batch {
        var cv = try self.dag.compileView(allocator, target_version);
        defer cv.deinit(allocator);
        const target_view = cv.view();

        var ops: std.ArrayList(op_mod.Op) = .empty;
        errdefer {
            for (ops.items) |*o| o.deinit(allocator);
            ops.deinit(allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        errdefer {
            for (blobs.items) |*b| b.deinit(allocator);
            blobs.deinit(allocator);
        }

        const res = self.resolver();
        var it = self.tree.inodes.iterator();
        while (it.next()) |kv| {
            const iid = kv.key_ptr.*;
            if (iid.isRoot()) continue;
            const inode = kv.value_ptr.*;
            const now_alive = if (inode.alive.get()) |a| a.* else false;
            const target_alive = if (inode.alive.getIn(target_view)) |a| a.* else false;

            if (now_alive and !target_alive) {
                try ops.append(allocator, .{ .remove = .{ .inode = iid } });
                continue;
            }
            if (!now_alive and target_alive) {
                try ops.append(allocator, .{ .restore = .{ .inode = iid } });
            }

            const now_p = inode.placement.get();
            const target_p = inode.placement.getIn(target_view);
            if (target_p) |tp| {
                const moved = if (now_p) |np|
                    (!np.parent.eql(tp.parent) or !std.mem.eql(u8, np.name, tp.name))
                else
                    true;
                if (moved) {
                    try ops.append(allocator, .{ .rename = .{
                        .inode = iid,
                        .parent = tp.parent,
                        .name = try allocator.dupe(u8, tp.name),
                    } });
                }
            }

            if (target_alive) {
                try self.appendNodeRevertOps(allocator, &ops, &blobs, iid, inode, res, target_view);
            }
        }

        if (ops.items.len == 0) {
            for (blobs.items) |*b| b.deinit(allocator);
            blobs.deinit(allocator);
            return null;
        }

        const parents = try self.dag.heads.clone(allocator);
        var parents_owned = true;
        errdefer if (parents_owned) {
            var p = parents;
            p.deinit(allocator);
        };
        const ops_slice = try ops.toOwnedSlice(allocator);
        errdefer {
            for (ops_slice) |*o| o.deinit(allocator);
            allocator.free(ops_slice);
        }
        const blobs_slice = try blobs.toOwnedSlice(allocator);
        const start = self.nextStartTs(&parents);
        const end = start + @as(u64, @intCast(ops_slice.len)) - 1;
        parents_owned = false;
        return .{
            .header = .{
                .actor = actor,
                .start = start,
                .end = end,
                .parents = parents,
                .wall_ms = wall_ms,
            },
            .ops = ops_slice,
            .blobs = blobs_slice,
        };
    }

    pub fn buildRevertScopeBatch(
        self: *const History,
        allocator: Allocator,
        actor: id.ActorId,
        excluded: []const id.BatchId,
        wall_ms: u64,
    ) Allocator.Error!?op_mod.Batch {
        const ExclCtx = struct {
            dag_ptr: *const Dag,
            excluded: []const id.BatchId,
            fn observes(ptr: *const anyopaque, op_id: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                const bid = ctx.dag_ptr.batchOf(op_id) orelse return true;
                for (ctx.excluded) |ex| {
                    if (ex.eql(bid)) return false;
                }
                return true;
            }
        };
        var min_ts: id.Lamport = std.math.maxInt(id.Lamport);
        for (excluded) |ex| {
            if (self.dag.getHeader(ex)) |h| {
                if (h.start < min_ts) min_ts = h.start;
            } else if (ex.ts < min_ts) {
                min_ts = ex.ts;
            }
        }
        const ctx = ExclCtx{ .dag_ptr = &self.dag, .excluded = excluded };
        const view = View{ .ptr = &ctx, .observesFn = ExclCtx.observes, .min_unobserved = min_ts };

        var ops: std.ArrayList(op_mod.Op) = .empty;
        errdefer {
            for (ops.items) |*o| o.deinit(allocator);
            ops.deinit(allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        errdefer {
            for (blobs.items) |*b| b.deinit(allocator);
            blobs.deinit(allocator);
        }

        const res = self.resolver();
        var it = self.tree.inodes.iterator();
        while (it.next()) |kv| {
            const iid = kv.key_ptr.*;
            if (iid.isRoot()) continue;
            const inode = kv.value_ptr.*;
            const now_alive = if (inode.alive.get()) |a| a.* else false;
            const tgt_alive = if (inode.alive.getIn(view)) |a| a.* else false;
            if (now_alive and !tgt_alive) {
                try ops.append(allocator, .{ .remove = .{ .inode = iid } });
                continue;
            }
            if (!now_alive and tgt_alive) {
                try ops.append(allocator, .{ .restore = .{ .inode = iid } });
            }

            const now_p = inode.placement.get();
            const target_p = inode.placement.getIn(view);
            if (target_p) |tp| {
                const moved = if (now_p) |np|
                    (!np.parent.eql(tp.parent) or !std.mem.eql(u8, np.name, tp.name))
                else
                    true;
                if (moved) {
                    try ops.append(allocator, .{ .rename = .{
                        .inode = iid,
                        .parent = tp.parent,
                        .name = try allocator.dupe(u8, tp.name),
                    } });
                }
            }

            if (tgt_alive) {
                try self.appendNodeRevertOps(allocator, &ops, &blobs, iid, inode, res, view);
            }
        }

        if (ops.items.len == 0) {
            for (blobs.items) |*b| b.deinit(allocator);
            blobs.deinit(allocator);
            return null;
        }
        const parents = try self.dag.heads.clone(allocator);
        var parents_owned = true;
        errdefer if (parents_owned) {
            var p = parents;
            p.deinit(allocator);
        };
        const ops_slice = try ops.toOwnedSlice(allocator);
        errdefer {
            for (ops_slice) |*o| o.deinit(allocator);
            allocator.free(ops_slice);
        }
        const blobs_slice = try blobs.toOwnedSlice(allocator);
        const start = self.nextStartTs(&parents);
        const end = start + @as(u64, @intCast(ops_slice.len)) - 1;
        parents_owned = false;
        return .{
            .header = .{
                .actor = actor,
                .start = start,
                .end = end,
                .parents = parents,
                .wall_ms = wall_ms,
            },
            .ops = ops_slice,
            .blobs = blobs_slice,
        };
    }
};
