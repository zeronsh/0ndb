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
const lru = @import("lru.zig");

pub const IntegrateError = error{
    MissingParents,
    LamportViolation,
    InvalidRange,
    Overlap,
    OpCountMismatch,
    UnknownInode,
    NotAFile,
    NotADir,
    NotASymlink,
    Unordered,
    OutOfBounds,
    LengthMismatch,
    InvalidSplice,
    MissingBlob,
    InvalidName,
    CannotModifyRoot,
    HistoryPoisoned,
};

pub const UnpinError = error{
    LogReadFailed,
};

pub const RevertError = error{
    MissingBlob,
};

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 4096) return false;
    if (std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".0ndb"))
    {
        return false;
    }
    for (name) |b| {
        if (b == '/' or b == '\\' or b == 0) return false;
    }
    return true;
}

pub const LogSliceReader = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, offset: u64, len: u32) ?[]const u8,

    pub inline fn read(self: LogSliceReader, offset: u64, len: u32) ?[]const u8 {
        return self.readFn(self.ptr, offset, len);
    }
};

pub const ExternalGitReader = struct {
    ptr: *anyopaque,
    readAllocFn: *const fn (ptr: *anyopaque, allocator: Allocator, oid: id.GitOid) Allocator.Error!?[]u8,
    readCachedFn: *const fn (ptr: *anyopaque, oid: id.GitOid) ?[]const u8,
    containsFn: *const fn (ptr: *anyopaque, oid: id.GitOid) bool,

    pub fn readAlloc(self: ExternalGitReader, allocator: Allocator, oid: id.GitOid) Allocator.Error!?[]u8 {
        return self.readAllocFn(self.ptr, allocator, oid);
    }

    pub fn readCached(self: ExternalGitReader, oid: id.GitOid) ?[]const u8 {
        return self.readCachedFn(self.ptr, oid);
    }

    pub fn contains(self: ExternalGitReader, oid: id.GitOid) bool {
        return self.containsFn(self.ptr, oid);
    }
};

pub const ExternalBlobReader = struct {
    ptr: *anyopaque,
    readAllocFn: *const fn (ptr: *anyopaque, allocator: Allocator, oid: id.Oid) Allocator.Error!?[]u8,
    existsFn: *const fn (ptr: *anyopaque, oid: id.Oid) bool,

    pub fn readAlloc(self: ExternalBlobReader, allocator: Allocator, oid: id.Oid) Allocator.Error!?[]u8 {
        return self.readAllocFn(self.ptr, allocator, oid);
    }

    pub fn exists(self: ExternalBlobReader, oid: id.Oid) bool {
        return self.existsFn(self.ptr, oid);
    }
};

pub const InsertionLookup = union(enum) {
    inline_bytes: []const u8,
    blob_oid: id.Oid,
    git_oid: id.GitOid,
};

pub const InsertionSource = struct {
    ptr: *const anyopaque,
    lookupFn: *const fn (ptr: *const anyopaque, key: id.InsertionKey) ?InsertionLookup,

    pub fn lookup(self: InsertionSource, key: id.InsertionKey) ?InsertionLookup {
        return self.lookupFn(self.ptr, key);
    }
};

pub const InsertionStorage = union(enum) {
    owned: []u8,
    log_span: struct {
        offset: u64,
        len: u32,
    },
    blob_ref: id.Oid,
    git_blob: id.GitOid,

    pub fn deinit(self: *InsertionStorage, allocator: Allocator) void {
        switch (self.*) {
            .owned => |b| allocator.free(b),
            .log_span, .blob_ref, .git_blob => {},
        }
    }
};

const ReadCacheKey = struct {
    kind: u8,
    len: u8,
    bytes: [32]u8,

    fn forBlob(oid: id.Oid) ReadCacheKey {
        return .{ .kind = 1, .len = 32, .bytes = oid };
    }

    fn forGit(oid: id.GitOid) ReadCacheKey {
        return .{ .kind = 2, .len = oid.len, .bytes = oid.bytes };
    }
};

fn sliceSizeFn(s: []u8) usize {
    return s.len;
}

fn sliceDeinitFn(allocator: Allocator, s: []u8) void {
    allocator.free(s);
}

const ExternalReadCache = lru.LruCache(ReadCacheKey, []u8, sliceSizeFn, sliceDeinitFn);

const ReadCacheBox = struct {
    allocator: Allocator,
    cache: ExternalReadCache,
    git_reader: ?ExternalGitReader = null,
    blob_reader: ?ExternalBlobReader = null,
    insertion_source: ?InsertionSource = null,
    lazy_git_oids: std.AutoHashMapUnmanaged(id.InsertionKey, id.GitOid) = .empty,
    lazy_blob_oids: std.AutoHashMapUnmanaged(id.InsertionKey, id.Oid) = .empty,

    fn deinit(self: *ReadCacheBox) void {
        self.cache.deinit();
        self.lazy_git_oids.deinit(self.allocator);
        self.lazy_blob_oids.deinit(self.allocator);
    }

    fn resolveBlob(self: *ReadCacheBox, oid: id.Oid) ?[]const u8 {
        const ckey = ReadCacheKey.forBlob(oid);
        if (self.cache.get(ckey)) |slot| return slot.*;
        if (self.blob_reader) |br| {
            const loaded = (br.readAlloc(self.allocator, oid) catch return null) orelse return null;
            const slot = self.cache.put(ckey, loaded) catch {
                self.allocator.free(loaded);
                return null;
            };
            return slot.*;
        }
        return null;
    }

    fn resolveGitBlob(self: *ReadCacheBox, goid: id.GitOid) ?[]const u8 {
        const ckey = ReadCacheKey.forGit(goid);
        if (self.cache.get(ckey)) |slot| return slot.*;
        if (self.git_reader) |gr| {
            if (gr.readCached(goid)) |cached| return cached;
            const loaded = (gr.readAlloc(self.allocator, goid) catch return null) orelse return null;
            const slot = self.cache.put(ckey, loaded) catch {
                self.allocator.free(loaded);
                return null;
            };
            return slot.*;
        }
        return null;
    }

    fn resolveInsertion(ptr: *const anyopaque, key: id.InsertionKey) ?[]const u8 {
        const self: *ReadCacheBox = @ptrCast(@alignCast(@constCast(ptr)));
        if (self.lazy_git_oids.get(key)) |goid| {
            if (self.resolveGitBlob(goid)) |b| return b;
        }
        if (self.lazy_blob_oids.get(key)) |oid| {
            if (self.resolveBlob(oid)) |b| return b;
        }
        if (self.insertion_source) |src| {
            if (src.lookup(key)) |found| {
                return switch (found) {
                    .inline_bytes => |b| b,
                    .blob_oid => |oid| self.resolveBlob(oid),
                    .git_oid => |goid| self.resolveGitBlob(goid),
                };
            }
        }
        return null;
    }

    fn contentResolver(self: *ReadCacheBox) text_mod.ContentResolver {
        return .{
            .ptr = self,
            .resolveFn = resolveInsertion,
        };
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
    batch_inodes: std.AutoHashMapUnmanaged(id.BatchId, []id.InodeId),
    meta: std.StringHashMapUnmanaged(tree_mod.Lww(?[]u8)),
    log_reader: ?LogSliceReader = null,
    git_reader: ?ExternalGitReader = null,
    blob_reader: ?ExternalBlobReader = null,
    insertion_source: ?InsertionSource = null,
    node_source: ?text_mod.NodeSource = null,
    read_cache_box: ?*ReadCacheBox = null,
    poisoned: bool = false,

    pub fn init(allocator: Allocator, history_id: u128) Allocator.Error!History {
        var t = try Tree.init(allocator);
        errdefer t.deinit(allocator);
        const box = try allocator.create(ReadCacheBox);
        box.* = .{
            .allocator = allocator,
            .cache = ExternalReadCache.init(allocator, .{
                .budget_bytes = 4 * 1024 * 1024,
                .max_entries = 512,
            }),
        };
        t.setContentResolver(box.contentResolver());
        return .{
            .allocator = allocator,
            .history_id = history_id,
            .dag = .{},
            .tree = t,
            .insertions = .empty,
            .blobs = .empty,
            .insertion_blobs = .empty,
            .batch_inodes = .empty,
            .meta = .empty,
            .log_reader = null,
            .git_reader = null,
            .blob_reader = null,
            .insertion_source = null,
            .node_source = null,
            .read_cache_box = box,
            .poisoned = false,
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
        var biit = self.batch_inodes.valueIterator();
        while (biit.next()) |sl| self.allocator.free(sl.*);
        self.batch_inodes.deinit(self.allocator);
        var mit = self.meta.iterator();
        while (mit.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(self.allocator);
        }
        self.meta.deinit(self.allocator);
        if (self.read_cache_box) |box| {
            box.deinit();
            self.allocator.destroy(box);
            self.read_cache_box = null;
        }
    }

    fn lazyTextResolver(self: *const History) ?text_mod.ContentResolver {
        return if (self.read_cache_box) |box| box.contentResolver() else null;
    }

    pub fn setLogReader(self: *History, reader: ?LogSliceReader) void {
        self.log_reader = reader;
    }

    pub fn setGitReader(self: *History, reader: ?ExternalGitReader) void {
        self.git_reader = reader;
        if (self.read_cache_box) |box| box.git_reader = reader;
    }

    pub fn setBlobReader(self: *History, reader: ?ExternalBlobReader) void {
        self.blob_reader = reader;
        if (self.read_cache_box) |box| box.blob_reader = reader;
    }

    pub fn attachSnapshotSources(
        self: *History,
        dag_src: ?dag_mod.DagSource,
        inode_src: ?tree_mod.InodeSource,
        node_src: ?text_mod.NodeSource,
        ins_src: ?InsertionSource,
    ) void {
        self.dag.setSource(dag_src);
        self.tree.setSource(inode_src);
        self.node_source = node_src;
        self.insertion_source = ins_src;
        if (self.read_cache_box) |box| box.insertion_source = ins_src;
    }

    pub fn attachSnapshotStack(self: *History, stack_opt: anytype) void {
        const T = @TypeOf(stack_opt);
        if (T == @TypeOf(null)) {
            self.attachSnapshotSources(null, null, null, null);
            return;
        }
        const stack = switch (@typeInfo(T)) {
            .optional => stack_opt orelse {
                self.attachSnapshotSources(null, null, null, null);
                return;
            },
            else => stack_opt,
        };
        self.attachSnapshotSources(
            stack.dagSource(),
            stack.inodeSource(),
            stack.nodeSource(),
            stack.insertionSource(),
        );
    }

    pub fn markDirty(self: *History, iid: id.InodeId) Allocator.Error!void {
        try self.tree.markDirty(self.allocator, iid);
    }

    pub fn clearReadCache(self: *History) void {
        if (self.read_cache_box) |box| {
            box.cache.clear();
        }
    }

    pub fn hibernate(self: *History) void {
        self.tree.hibernate();
        self.clearReadCache();
    }

    pub fn clearDirtyAfterCheckpoint(self: *History) void {
        self.tree.clearDirtyAfterCheckpoint(self.allocator);
        self.dag.clearOverlayAfterCheckpoint(self.allocator);
        var iit = self.insertions.valueIterator();
        while (iit.next()) |s| s.deinit(self.allocator);
        self.insertions.clearRetainingCapacity();
        self.insertion_blobs.clearRetainingCapacity();
        var bit = self.blobs.valueIterator();
        while (bit.next()) |s| s.deinit(self.allocator);
        self.blobs.clearRetainingCapacity();
        if (self.read_cache_box) |box| {
            box.lazy_git_oids.clearRetainingCapacity();
            box.lazy_blob_oids.clearRetainingCapacity();
        }
        self.clearReadCache();
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
                        .log_span, .blob_ref, .git_blob => false,
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

    pub fn unpinAllLogSpans(self: *History) (UnpinError || Allocator.Error)!void {
        const lr = self.log_reader orelse {
            var iit = self.insertions.valueIterator();
            while (iit.next()) |slot| {
                if (slot.* == .log_span) return error.LogReadFailed;
            }
            var bit = self.blobs.valueIterator();
            while (bit.next()) |slot| {
                if (slot.* == .log_span) return error.LogReadFailed;
            }
            return;
        };
        var iit = self.insertions.valueIterator();
        while (iit.next()) |slot| {
            switch (slot.*) {
                .owned, .blob_ref, .git_blob => {},
                .log_span => |sp| {
                    const bytes = lr.read(sp.offset, sp.len) orelse return error.LogReadFailed;
                    const copy = try self.allocator.dupe(u8, bytes);
                    slot.* = .{ .owned = copy };
                },
            }
        }
        var bit = self.blobs.valueIterator();
        while (bit.next()) |slot| {
            switch (slot.*) {
                .owned, .blob_ref, .git_blob => {},
                .log_span => |sp| {
                    const bytes = lr.read(sp.offset, sp.len) orelse return error.LogReadFailed;
                    const copy = try self.allocator.dupe(u8, bytes);
                    slot.* = .{ .owned = copy };
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
                .log_span, .blob_ref, .git_blob => {},
            }
        }
        var bit = self.blobs.valueIterator();
        while (bit.next()) |s| {
            switch (s.*) {
                .owned => |b| total += b.len,
                .log_span, .blob_ref, .git_blob => {},
            }
        }
        return total;
    }

    fn resolveStorage(self: *const History, s: InsertionStorage) ?[]const u8 {
        return switch (s) {
            .owned => |b| b,
            .log_span => |sp| if (self.log_reader) |lr| lr.read(sp.offset, sp.len) else null,
            .blob_ref => |oid| self.resolveBlob(oid),
            .git_blob => |goid| self.resolveGitBlob(goid),
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
            if (self.resolveBlob(oid)) |b| return b;
        }
        if (self.insertion_source) |src| {
            if (src.lookup(key)) |found| {
                return switch (found) {
                    .inline_bytes => |b| b,
                    .blob_oid => |oid| self.resolveBlob(oid),
                    .git_oid => |goid| self.resolveGitBlob(goid),
                };
            }
        }
        return null;
    }

    pub fn resolveBlob(self: *const History, oid: id.Oid) ?[]const u8 {
        if (self.blobs.get(oid)) |s| {
            return self.resolveStorage(s);
        }
        if (self.read_cache_box) |box| {
            const ckey = ReadCacheKey.forBlob(oid);
            if (box.cache.get(ckey)) |slot| return slot.*;
            if (self.blob_reader) |br| {
                const loaded = (br.readAlloc(box.allocator, oid) catch return null) orelse return null;
                const slot = box.cache.put(ckey, loaded) catch {
                    box.allocator.free(loaded);
                    return null;
                };
                return slot.*;
            }
        }
        return null;
    }

    pub fn resolveGitBlob(self: *const History, goid: id.GitOid) ?[]const u8 {
        if (self.read_cache_box) |box| {
            const ckey = ReadCacheKey.forGit(goid);
            if (box.cache.get(ckey)) |slot| return slot.*;
            if (self.git_reader) |gr| {
                if (gr.readCached(goid)) |cached| return cached;
                const loaded = (gr.readAlloc(box.allocator, goid) catch return null) orelse return null;
                const slot = box.cache.put(ckey, loaded) catch {
                    box.allocator.free(loaded);
                    return null;
                };
                return slot.*;
            }
        } else if (self.git_reader) |gr| {
            return gr.readCached(goid);
        }
        return null;
    }

    pub fn readBlobAlloc(self: *const History, allocator: Allocator, oid: id.Oid) Allocator.Error!?[]u8 {
        if (self.blobs.get(oid)) |s| {
            if (self.resolveStorage(s)) |b| return try allocator.dupe(u8, b);
        }
        if (self.blob_reader) |br| {
            return try br.readAlloc(allocator, oid);
        }
        return null;
    }

    pub fn readGitBlobAlloc(self: *const History, allocator: Allocator, goid: id.GitOid) Allocator.Error!?[]u8 {
        if (self.git_reader) |gr| {
            return try gr.readAlloc(allocator, goid);
        }
        if (self.resolveGitBlob(goid)) |b| return try allocator.dupe(u8, b);
        return null;
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

    fn putOwnedInsertion(self: *History, key: id.InsertionKey, bytes: []const u8) Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        if (try self.insertions.fetchPut(self.allocator, key, .{ .owned = owned })) |prev| {
            var old = prev.value;
            old.deinit(self.allocator);
        }
    }

    pub fn integrate(self: *History, batch: *const op_mod.Batch) (IntegrateError || Allocator.Error)!bool {
        if (self.poisoned) return error.HistoryPoisoned;
        const already = self.dag.check(&batch.header) catch |err| return switch (err) {
            error.MissingParents => error.MissingParents,
            error.LamportViolation => error.LamportViolation,
            error.InvalidRange => error.InvalidRange,
            error.Overlap => error.Overlap,
        };
        if (already) return false;
        if (batch.header.opCount() != batch.ops.len) return error.OpCountMismatch;

        var mutated = false;
        errdefer if (mutated) {
            self.poisoned = true;
        };

        for (batch.blobs) |blob| {
            if (!self.blobs.contains(blob.oid)) {
                const copy = try self.allocator.dupe(u8, blob.data);
                errdefer self.allocator.free(copy);
                mutated = true;
                try self.blobs.put(self.allocator, blob.oid, .{ .owned = copy });
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

        var touched_set: std.AutoArrayHashMapUnmanaged(id.InodeId, void) = .empty;
        defer touched_set.deinit(self.allocator);

        for (batch.ops, 0..) |*operation, idx| {
            const op_id = batch.header.opId(idx);
            local_ctx.cur_ts = op_id.ts;
            const op_view = if (idx == 0) parent_view else View{
                .ptr = &local_ctx,
                .observesFn = BatchLocalCtx.observes,
                .min_unobserved = min_unobs,
            };
            try self.applyOp(op_id, op_view, operation, &mutated, &touched_set);
        }

        const bid = batch.header.batchId();
        if (touched_set.count() > 0) {
            const touched_slice = try self.allocator.dupe(id.InodeId, touched_set.keys());
            errdefer self.allocator.free(touched_slice);
            mutated = true;
            if (try self.batch_inodes.fetchPut(self.allocator, bid, touched_slice)) |prev| {
                self.allocator.free(prev.value);
            }
        }

        var hdr_copy = try batch.header.clone(self.allocator);
        var hdr_owned = true;
        errdefer if (hdr_owned) hdr_copy.deinit(self.allocator);
        mutated = true;
        _ = self.dag.insert(self.allocator, hdr_copy) catch |err| return switch (err) {
            error.MissingParents => error.MissingParents,
            error.LamportViolation => error.LamportViolation,
            error.InvalidRange => error.InvalidRange,
            error.Overlap => error.Overlap,
            error.OutOfMemory => error.OutOfMemory,
        };
        hdr_owned = false;
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
                                .lines = f.text.countLines(self.resolver()),
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
                const old_lines = f.text.countLines(res);
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
            const lines_cnt = f.text.countLines(res);
            const is_text = if (f.content.get()) |ck| ck.* == .text else false;

            if (!before_alive or before_path == null or !std.mem.eql(u8, before_path.?, ap)) {
                if (before_alive) {
                    if (before_path) |bp| {
                        const old_lines = f.text.countLines(res);
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
            var vd = f.text.diffViews(allocator, res, base_view, View.EVERYTHING) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MissingBlob => return null,
            };
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

        var vd = merged.diffViews(allocator, draft_resolver, draft_view, View.EVERYTHING) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingBlob => return null,
        };
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

    fn requireKnown(self: *History, view: View, iid: id.InodeId) IntegrateError!*tree_mod.Inode {
        if (!iid.isRoot() and !view.observes(iid.op)) return error.UnknownInode;
        return self.tree.getMut(iid) orelse error.UnknownInode;
    }

    fn requireKnownDir(self: *const History, view: View, parent: id.InodeId) IntegrateError!void {
        if (!parent.isRoot() and !view.observes(parent.op)) return error.UnknownInode;
        const inode = self.tree.get(parent) orelse return error.UnknownInode;
        if (!inode.isDir()) return error.NotADir;
    }

    fn applyOp(
        self: *History,
        op_id: id.OpId,
        view: View,
        operation: *const op_mod.Op,
        mutated: *bool,
        touched: *std.AutoArrayHashMapUnmanaged(id.InodeId, void),
    ) (IntegrateError || Allocator.Error)!void {
        switch (operation.*) {
            .create_dir => |v| {
                if (!isValidName(v.name)) return error.InvalidName;
                try self.requireKnownDir(view, v.parent);
                const iid = id.InodeId.init(op_id, 0);
                const inode = try self.allocator.create(tree_mod.Inode);
                inode.* = .{ .inode_id = iid, .kind = .dir };
                errdefer {
                    inode.deinit(self.allocator);
                    self.allocator.destroy(inode);
                }
                try inode.alive.set(self.allocator, op_id, true);
                {
                    const name_copy = try self.allocator.dupe(u8, v.name);
                    errdefer self.allocator.free(name_copy);
                    try inode.placement.set(self.allocator, op_id, .{
                        .parent = v.parent,
                        .name = name_copy,
                    });
                }
                mutated.* = true;
                try self.tree.insertInode(self.allocator, inode);
                try touched.put(self.allocator, iid, {});
                if (!v.parent.isRoot()) try touched.put(self.allocator, v.parent, {});
            },
            .create_file => |v| {
                if (!isValidName(v.name)) return error.InvalidName;
                try self.requireKnownDir(view, v.parent);
                const iid = id.InodeId.init(op_id, 0);
                const inode = try self.allocator.create(tree_mod.Inode);
                inode.* = .{ .inode_id = iid, .kind = .{ .file = .{} } };
                errdefer {
                    inode.deinit(self.allocator);
                    self.allocator.destroy(inode);
                }
                try inode.alive.set(self.allocator, op_id, true);
                {
                    const name_copy = try self.allocator.dupe(u8, v.name);
                    errdefer self.allocator.free(name_copy);
                    try inode.placement.set(self.allocator, op_id, .{
                        .parent = v.parent,
                        .name = name_copy,
                    });
                }
                const f = inode.filePtr().?;
                try f.mode.set(self.allocator, op_id, v.mode);
                try f.line_ending.set(self.allocator, op_id, v.line_ending);
                mutated.* = true;
                try self.initFileContent(f, op_id, &v.content);
                try self.tree.insertInode(self.allocator, inode);
                try touched.put(self.allocator, iid, {});
                if (!v.parent.isRoot()) try touched.put(self.allocator, v.parent, {});
            },
            .create_symlink => |v| {
                if (!isValidName(v.name)) return error.InvalidName;
                try self.requireKnownDir(view, v.parent);
                const iid = id.InodeId.init(op_id, 0);
                const inode = try self.allocator.create(tree_mod.Inode);
                inode.* = .{ .inode_id = iid, .kind = .{ .symlink = .{} } };
                errdefer {
                    inode.deinit(self.allocator);
                    self.allocator.destroy(inode);
                }
                try inode.alive.set(self.allocator, op_id, true);
                {
                    const name_copy = try self.allocator.dupe(u8, v.name);
                    errdefer self.allocator.free(name_copy);
                    try inode.placement.set(self.allocator, op_id, .{
                        .parent = v.parent,
                        .name = name_copy,
                    });
                }
                {
                    const target_copy = try self.allocator.dupe(u8, v.target);
                    errdefer self.allocator.free(target_copy);
                    try inode.kind.symlink.set(self.allocator, op_id, target_copy);
                }
                mutated.* = true;
                try self.tree.insertInode(self.allocator, inode);
                try touched.put(self.allocator, iid, {});
                if (!v.parent.isRoot()) try touched.put(self.allocator, v.parent, {});
            },
            .rename => |v| {
                if (v.inode.isRoot()) return error.CannotModifyRoot;
                if (!isValidName(v.name)) return error.InvalidName;
                _ = try self.requireKnown(view, v.inode);
                try self.requireKnownDir(view, v.parent);
                mutated.* = true;
                try self.tree.place(self.allocator, v.inode, op_id, v.parent, v.name);
                try touched.put(self.allocator, v.inode, {});
                if (!v.parent.isRoot()) try touched.put(self.allocator, v.parent, {});
            },
            .remove => |v| {
                if (v.inode.isRoot()) return error.CannotModifyRoot;
                const inode = try self.requireKnown(view, v.inode);
                mutated.* = true;
                try self.tree.markDirty(self.allocator, v.inode);
                if (inode.isDir()) {
                    try self.removeDirSubtree(v.inode, op_id, view, touched);
                } else {
                    try inode.alive.set(self.allocator, op_id, false);
                    try touched.put(self.allocator, v.inode, {});
                }
            },
            .restore => |v| {
                const inode = try self.requireKnown(view, v.inode);
                mutated.* = true;
                try self.tree.markDirty(self.allocator, v.inode);
                try inode.alive.set(self.allocator, op_id, true);
                if (!v.inode.isRoot()) try touched.put(self.allocator, v.inode, {});
            },
            .edit_text => |v| {
                const inode = try self.requireKnown(view, v.inode);
                const f = inode.filePtr() orelse return error.NotAFile;
                if (try self.promoteGitLazy(f, view, mutated)) {
                    try f.content.set(self.allocator, op_id, .text);
                }
                f.text.apply(self.allocator, op_id, view, v.splices, v.text, self.resolver()) catch |err| switch (err) {
                    error.Unordered => return error.Unordered,
                    error.OutOfBounds => return error.OutOfBounds,
                    error.LengthMismatch => return error.LengthMismatch,
                    error.InvalidSplice => return error.InvalidSplice,
                    error.OutOfMemory => {
                        mutated.* = true;
                        return error.OutOfMemory;
                    },
                };
                mutated.* = true;
                if (v.text.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    try self.putOwnedInsertion(key, v.text);
                }
                try touched.put(self.allocator, v.inode, {});
            },
            .set_content => |v| {
                const inode = try self.requireKnown(view, v.inode);
                const f = inode.filePtr() orelse return error.NotAFile;
                try self.applySetContent(f, op_id, view, &v.content, mutated);
                try touched.put(self.allocator, v.inode, {});
            },
            .set_mode => |v| {
                const inode = try self.requireKnown(view, v.inode);
                const f = inode.filePtr() orelse return error.NotAFile;
                mutated.* = true;
                try f.mode.set(self.allocator, op_id, v.mode);
                try touched.put(self.allocator, v.inode, {});
            },
            .set_line_ending => |v| {
                const inode = try self.requireKnown(view, v.inode);
                const f = inode.filePtr() orelse return error.NotAFile;
                mutated.* = true;
                try f.line_ending.set(self.allocator, op_id, v.ending);
                try touched.put(self.allocator, v.inode, {});
            },
            .set_symlink_target => |v| {
                const inode = try self.requireKnown(view, v.inode);
                switch (inode.kind) {
                    .symlink => |*s| {
                        const target_copy = try self.allocator.dupe(u8, v.target);
                        errdefer self.allocator.free(target_copy);
                        mutated.* = true;
                        try s.set(self.allocator, op_id, target_copy);
                        try touched.put(self.allocator, v.inode, {});
                    },
                    else => return error.NotASymlink,
                }
            },
            .git_checkout => {},
            .meta => |v| {
                if (self.meta.getPtr(v.key)) |lww| {
                    const val_copy: ?[]u8 = if (v.value) |raw| try self.allocator.dupe(u8, raw) else null;
                    errdefer if (val_copy) |vc| self.allocator.free(vc);
                    mutated.* = true;
                    try lww.set(self.allocator, op_id, val_copy);
                } else {
                    const key_copy = try self.allocator.dupe(u8, v.key);
                    errdefer self.allocator.free(key_copy);
                    var lww = tree_mod.Lww(?[]u8){};
                    errdefer lww.deinit(self.allocator);
                    {
                        const val_copy: ?[]u8 = if (v.value) |raw| try self.allocator.dupe(u8, raw) else null;
                        errdefer if (val_copy) |vc| self.allocator.free(vc);
                        try lww.set(self.allocator, op_id, val_copy);
                    }
                    mutated.* = true;
                    try self.meta.put(self.allocator, key_copy, lww);
                }
            },
        }
    }

    fn removeDirSubtree(
        self: *History,
        dir_iid: id.InodeId,
        op_id: id.OpId,
        view: View,
        touched: *std.AutoArrayHashMapUnmanaged(id.InodeId, void),
    ) Allocator.Error!void {
        var stack: std.ArrayList(id.InodeId) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, dir_iid);

        while (stack.pop()) |cur_iid| {
            const cur = self.tree.getMut(cur_iid) orelse continue;
            try self.tree.markDirty(self.allocator, cur_iid);
            try cur.alive.set(self.allocator, op_id, false);
            if (!cur_iid.isRoot()) try touched.put(self.allocator, cur_iid, {});
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

    fn promoteGitLazy(
        self: *History,
        f: *tree_mod.FileNode,
        view: View,
        mutated: *bool,
    ) Allocator.Error!bool {
        if (f.content.nthIn(view, 0)) |ck_entry| {
            if (ck_entry.value == .git_lazy) {
                const ref = ck_entry.value.git_lazy;
                mutated.* = true;
                if (ref.len > 0 and f.text.root == null and f.text.disk_root == null) {
                    const lazy_key = id.InsertionKey{ .op = ck_entry.op, .part = 0 };
                    if (try self.insertions.fetchPut(self.allocator, lazy_key, .{ .git_blob = ref.oid })) |prev| {
                        var old = prev.value;
                        old.deinit(self.allocator);
                    }
                    if (self.read_cache_box) |box| {
                        try box.lazy_git_oids.put(box.allocator, lazy_key, ref.oid);
                    }
                    f.text = try Text.fromInsertion(self.allocator, ck_entry.op, 0, 0, ref.len, null);
                    f.text.node_source = self.node_source;
                    f.text.content_resolver = self.lazyTextResolver();
                }
                return true;
            }
        }
        return false;
    }

    fn applySetContent(
        self: *History,
        f: *tree_mod.FileNode,
        op_id: id.OpId,
        view: View,
        content: *const op_mod.Content,
        mutated: *bool,
    ) (IntegrateError || Allocator.Error)!void {
        switch (content.*) {
            .text_inline => |bytes| {
                mutated.* = true;
                _ = try self.promoteGitLazy(f, view, mutated);
                try f.content.set(self.allocator, op_id, .text);
                try self.applySetTextBytes(f, op_id, view, bytes, null);
            },
            .text_blob => |ref| {
                if (ref.len == 0) {
                    mutated.* = true;
                    _ = try self.promoteGitLazy(f, view, mutated);
                    try f.content.set(self.allocator, op_id, .text);
                    try self.applySetTextBytes(f, op_id, view, "", ref.oid);
                } else if (self.resolveBlob(ref.oid)) |raw_bytes| {
                    const copy = try self.allocator.dupe(u8, raw_bytes);
                    defer self.allocator.free(copy);
                    mutated.* = true;
                    _ = try self.promoteGitLazy(f, view, mutated);
                    try f.content.set(self.allocator, op_id, .text);
                    try self.applySetTextBytes(f, op_id, view, copy, ref.oid);
                } else {
                    return error.MissingBlob;
                }
            },
            .binary => |ref| {
                mutated.* = true;
                try f.content.set(self.allocator, op_id, .{ .binary = ref });
            },
            .git_text_blob => |ref| {
                mutated.* = true;
                _ = try self.promoteGitLazy(f, view, mutated);
                try f.content.set(self.allocator, op_id, .text);
                if (ref.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    if (try self.insertions.fetchPut(self.allocator, key, .{ .git_blob = ref.oid })) |prev| {
                        var old = prev.value;
                        old.deinit(self.allocator);
                    }
                    if (self.read_cache_box) |box| {
                        try box.lazy_git_oids.put(box.allocator, key, ref.oid);
                    }
                }
                f.text.content_resolver = self.lazyTextResolver();
                f.text.replaceWithLazyInsertion(self.allocator, op_id, view, ref.len, self.resolver()) catch |err| return switch (err) {
                    error.Unordered => error.Unordered,
                    error.OutOfBounds => error.OutOfBounds,
                    error.LengthMismatch => error.LengthMismatch,
                    error.InvalidSplice => error.InvalidSplice,
                    error.OutOfMemory => error.OutOfMemory,
                };
            },
            .git_binary => |ref| {
                mutated.* = true;
                try f.content.set(self.allocator, op_id, .{ .git_binary = ref });
            },
            .git_lazy => |ref| {
                mutated.* = true;
                try f.content.set(self.allocator, op_id, .{ .git_lazy = ref });
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
        if (vis_len == 0 and new_bytes.len == 0) return;

        if (new_bytes.len > 0) {
            const key = id.InsertionKey{ .op = op_id, .part = 0 };
            if (blob_oid) |oid| {
                try self.insertion_blobs.put(self.allocator, key, oid);
            } else {
                try self.putOwnedInsertion(key, new_bytes);
            }
        }

        const sp = [_]diff.Splice{.{ .at = 0, .del = vis_len, .ins = new_bytes.len }};
        f.text.apply(self.allocator, op_id, view, &sp, new_bytes, self.resolver()) catch |err| return switch (err) {
            error.Unordered => error.Unordered,
            error.OutOfBounds => error.OutOfBounds,
            error.LengthMismatch => error.LengthMismatch,
            error.InvalidSplice => error.InvalidSplice,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn initFileContent(self: *History, f: *tree_mod.FileNode, op_id: id.OpId, content: *const op_mod.Content) Allocator.Error!void {
        switch (content.*) {
            .text_inline => |bytes| {
                try f.content.set(self.allocator, op_id, .text);
                if (bytes.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    try self.putOwnedInsertion(key, bytes);
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
                    if (self.read_cache_box) |box| {
                        try box.lazy_blob_oids.put(box.allocator, key, ref.oid);
                    }
                    f.text.deinit(self.allocator);
                    f.text = try Text.fromInsertion(self.allocator, op_id, 0, 0, ref.len, self.resolveBlob(ref.oid));
                    f.text.content_resolver = self.lazyTextResolver();
                } else {
                    f.text.deinit(self.allocator);
                }
            },
            .binary => |ref| {
                try f.content.set(self.allocator, op_id, .{ .binary = ref });
            },
            .git_text_blob => |ref| {
                try f.content.set(self.allocator, op_id, .text);
                if (ref.len > 0) {
                    const key = id.InsertionKey{ .op = op_id, .part = 0 };
                    if (try self.insertions.fetchPut(self.allocator, key, .{ .git_blob = ref.oid })) |prev| {
                        var old = prev.value;
                        old.deinit(self.allocator);
                    }
                    if (self.read_cache_box) |box| {
                        try box.lazy_git_oids.put(box.allocator, key, ref.oid);
                    }
                    f.text.deinit(self.allocator);
                    f.text = try Text.fromInsertion(self.allocator, op_id, 0, 0, ref.len, null);
                    f.text.node_source = self.node_source;
                    f.text.content_resolver = self.lazyTextResolver();
                } else {
                    f.text.deinit(self.allocator);
                }
            },
            .git_binary => |ref| {
                try f.content.set(self.allocator, op_id, .{ .git_binary = ref });
            },
            .git_lazy => |ref| {
                try f.content.set(self.allocator, op_id, .{ .git_lazy = ref });
            },
        }
    }

    pub fn readInodeInView(self: *const History, allocator: Allocator, iid: id.InodeId, view: View) Allocator.Error!?[]u8 {
        self.tree.beginPinScope();
        defer self.tree.endPinScope();
        const inode = self.tree.get(iid) orelse return null;
        const alive = inode.alive.getIn(view) orelse return null;
        if (!alive.*) return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.getIn(view) orelse return null;
        return switch (ck.*) {
            .text => try f.text.readIn(allocator, self.resolver(), view),
            .binary => |ref| try self.readBlobAlloc(allocator, ref.oid),
            .git_binary => |ref| try self.readGitBlobAlloc(allocator, ref.oid),
            .git_lazy => |ref| try self.readGitBlobAlloc(allocator, ref.oid),
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
        self.tree.beginPinScope();
        defer self.tree.endPinScope();
        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const alive = inode.alive.get() orelse return null;
        if (!alive.*) return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.get() orelse return null;
        return switch (ck.*) {
            .text => try f.text.read(allocator, self.resolver()),
            .binary => |ref| try self.readBlobAlloc(allocator, ref.oid),
            .git_binary => |ref| try self.readGitBlobAlloc(allocator, ref.oid),
            .git_lazy => |ref| try self.readGitBlobAlloc(allocator, ref.oid),
        };
    }

    pub fn readFileLines(
        self: *const History,
        allocator: Allocator,
        rel_path: []const u8,
        start_line: usize,
        max_lines: usize,
    ) Allocator.Error!?[]u8 {
        self.tree.beginPinScope();
        defer self.tree.endPinScope();
        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const alive = inode.alive.get() orelse return null;
        if (!alive.*) return null;
        const f = inode.fileConstPtr() orelse return null;
        const ck = f.content.get() orelse return null;
        switch (ck.*) {
            .text => return try f.text.readLineRange(allocator, self.resolver(), start_line, max_lines),
            .git_lazy => |ref| {
                const raw = (try self.readGitBlobAlloc(allocator, ref.oid)) orelse return null;
                defer allocator.free(raw);
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(allocator);
                if (max_lines == 0 or raw.len == 0) return try out.toOwnedSlice(allocator);
                var cur_line: usize = 0;
                var idx: usize = 0;
                while (idx < raw.len and cur_line < start_line) : (idx += 1) {
                    if (raw[idx] == '\n') cur_line += 1;
                }
                if (cur_line < start_line) return try out.toOwnedSlice(allocator);
                const start_idx = idx;
                var emitted: usize = 0;
                while (idx < raw.len) : (idx += 1) {
                    if (raw[idx] == '\n') {
                        emitted += 1;
                        if (emitted >= max_lines) {
                            idx += 1;
                            break;
                        }
                    }
                }
                if (idx > start_idx) try out.appendSlice(allocator, raw[start_idx..idx]);
                return try out.toOwnedSlice(allocator);
            },
            .binary, .git_binary => return null,
        }
    }

    pub fn blameFile(self: *const History, allocator: Allocator, rel_path: []const u8) Allocator.Error!?std.ArrayList(BlameLine) {
        self.tree.beginPinScope();
        defer self.tree.endPinScope();
        const iid = try self.tree.resolvePath(allocator, View.EVERYTHING, rel_path) orelse return null;
        const inode = self.tree.get(iid) orelse return null;
        const f = inode.fileConstPtr() orelse return null;
        if (f.content.nthIn(View.EVERYTHING, 0)) |ck_entry| {
            if (ck_entry.value == .git_lazy) {
                const ref = ck_entry.value.git_lazy;
                const raw = (try self.readGitBlobAlloc(allocator, ref.oid)) orelse return null;
                defer allocator.free(raw);
                var out: std.ArrayList(BlameLine) = .empty;
                errdefer {
                    for (out.items) |*l| l.deinit(allocator);
                    out.deinit(allocator);
                }
                const batch = self.dag.batchOf(ck_entry.op);
                var cur_line: std.ArrayList(u8) = .empty;
                defer cur_line.deinit(allocator);
                var line_no: usize = 1;
                for (raw) |ch| {
                    if (ch == '\n') {
                        try out.append(allocator, .{
                            .line_no = line_no,
                            .op = ck_entry.op,
                            .batch = batch,
                            .text = try cur_line.toOwnedSlice(allocator),
                        });
                        line_no += 1;
                    } else {
                        try cur_line.append(allocator, ch);
                    }
                }
                if (cur_line.items.len > 0) {
                    try out.append(allocator, .{
                        .line_no = line_no,
                        .op = ck_entry.op,
                        .batch = batch,
                        .text = try cur_line.toOwnedSlice(allocator),
                    });
                }
                return out;
            }
        }
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
    ) (RevertError || Allocator.Error)!void {
        var vd = try f.text.diffViews(allocator, res, View.EVERYTHING, target_view);
        defer vd.deinit(allocator);
        if (vd.splices.len == 0) return;

        const now_bytes = (try f.text.readIn(allocator, res, View.EVERYTHING)) orelse return error.MissingBlob;
        defer allocator.free(now_bytes);
        const tgt_bytes = (try f.text.readIn(allocator, res, target_view)) orelse return error.MissingBlob;
        defer allocator.free(tgt_bytes);
        if (std.mem.eql(u8, now_bytes, tgt_bytes)) return;

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
    ) (RevertError || Allocator.Error)!void {
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
                            else => false,
                        };
                        if (!same) {
                            var already_attached = false;
                            for (blobs.items) |b| {
                                if (std.mem.eql(u8, &b.oid, &tref.oid)) {
                                    already_attached = true;
                                    break;
                                }
                            }
                            if (!already_attached) {
                                if (self.resolveBlob(tref.oid)) |raw| {
                                    const data_copy = try allocator.dupe(u8, raw);
                                    errdefer allocator.free(data_copy);
                                    try blobs.append(allocator, .{
                                        .oid = tref.oid,
                                        .data = data_copy,
                                    });
                                } else if (tref.len == 0) {
                                    const empty_copy = try allocator.dupe(u8, "");
                                    errdefer allocator.free(empty_copy);
                                    try blobs.append(allocator, .{
                                        .oid = tref.oid,
                                        .data = empty_copy,
                                    });
                                } else {
                                    return error.MissingBlob;
                                }
                            }
                            try ops.append(allocator, .{ .set_content = .{ .inode = iid, .content = .{ .binary = tref } } });
                        }
                    },
                    .git_binary => |tref| {
                        const same = switch (now_ck) {
                            .git_binary => |nref| nref.eql(tref),
                            else => false,
                        };
                        if (!same) {
                            try ops.append(allocator, .{ .set_content = .{ .inode = iid, .content = .{ .git_binary = tref } } });
                        }
                    },
                    .git_lazy => |tref| {
                        const same = switch (now_ck) {
                            .git_lazy => |nref| nref.eql(tref),
                            else => false,
                        };
                        if (!same) {
                            try ops.append(allocator, .{ .set_content = .{ .inode = iid, .content = .{ .git_lazy = tref } } });
                        }
                    },
                    .text => {
                        switch (now_ck) {
                            .binary, .git_binary, .git_lazy => {
                                const tgt_text = (try f.text.readIn(allocator, res, target_view)) orelse return error.MissingBlob;
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
                    const copy = try allocator.dupe(u8, tgt_tgt);
                    errdefer allocator.free(copy);
                    try ops.append(allocator, .{ .set_symlink_target = .{
                        .inode = iid,
                        .target = copy,
                    } });
                }
            },
        }
    }

    fn depthIn(self: *const History, allocator: Allocator, view: View, iid: id.InodeId) Allocator.Error!usize {
        var depth: usize = 0;
        var cur = iid;
        while (!cur.isRoot() and depth < 4096) {
            var entry = try self.tree.placementIn(allocator, view, cur) orelse break;
            const parent = entry.value.parent;
            entry.deinit(allocator);
            cur = parent;
            depth += 1;
        }
        return depth;
    }

    fn buildRevertForTarget(
        self: *const History,
        allocator: Allocator,
        actor: id.ActorId,
        target_view: View,
        diff_batches: []const id.BatchId,
        wall_ms: u64,
    ) (RevertError || Allocator.Error)!?op_mod.Batch {
        if (diff_batches.len == 0) return null;
        self.tree.beginPinScope();
        defer self.tree.endPinScope();

        var touched: std.AutoArrayHashMapUnmanaged(id.InodeId, void) = .empty;
        defer touched.deinit(allocator);
        var queue: std.ArrayList(id.InodeId) = .empty;
        defer queue.deinit(allocator);

        for (diff_batches) |bid| {
            if (self.batch_inodes.get(bid)) |inodes| {
                for (inodes) |iid| {
                    if (iid.isRoot()) continue;
                    const gop = try touched.getOrPut(allocator, iid);
                    if (!gop.found_existing) try queue.append(allocator, iid);
                }
            }
        }
        while (queue.pop()) |cur| {
            const inode = self.tree.get(cur) orelse continue;
            for (inode.placement.entries.items) |e| {
                const p = e.value.parent;
                if (p.isRoot()) continue;
                const gop = try touched.getOrPut(allocator, p);
                if (!gop.found_existing) try queue.append(allocator, p);
            }
        }

        if (touched.count() == 0) return null;

        const candidates = try allocator.dupe(id.InodeId, touched.keys());
        defer allocator.free(candidates);
        std.mem.sort(id.InodeId, candidates, {}, struct {
            fn lt(_: void, a: id.InodeId, b: id.InodeId) bool {
                return a.order(b) == .lt;
            }
        }.lt);

        var restore_set: std.AutoArrayHashMapUnmanaged(id.InodeId, void) = .empty;
        defer restore_set.deinit(allocator);

        var phase2_ops: std.ArrayList(op_mod.Op) = .empty;
        errdefer {
            for (phase2_ops.items) |*o| o.deinit(allocator);
            phase2_ops.deinit(allocator);
        }
        var blobs: std.ArrayList(op_mod.BlobAttachment) = .empty;
        errdefer {
            for (blobs.items) |*b| b.deinit(allocator);
            blobs.deinit(allocator);
        }

        const RemoveItem = struct {
            iid: id.InodeId,
            depth: usize,
        };
        var phase3_items: std.ArrayList(RemoveItem) = .empty;
        defer phase3_items.deinit(allocator);

        const res = self.resolver();
        for (candidates) |iid| {
            const now_present = try self.tree.isPresent(allocator, View.EVERYTHING, iid);
            const target_present = try self.tree.isPresent(allocator, target_view, iid);

            if (!now_present and !target_present) continue;

            if (now_present and !target_present) {
                const d = try self.depthIn(allocator, View.EVERYTHING, iid);
                try phase3_items.append(allocator, .{ .iid = iid, .depth = d });
                continue;
            }

            const inode_alive = self.tree.get(iid) orelse continue;
            const now_alive = if (inode_alive.alive.get()) |a| a.* else false;
            const target_alive = if (inode_alive.alive.getIn(target_view)) |a| a.* else false;
            if (target_alive and !now_alive) {
                try restore_set.put(allocator, iid, {});
            }

            var anc = iid;
            var guard: usize = 0;
            while (!anc.isRoot() and guard < 4096) {
                guard += 1;
                var anc_entry = try self.tree.placementIn(allocator, target_view, anc) orelse break;
                const p = anc_entry.value.parent;
                anc_entry.deinit(allocator);
                if (p.isRoot()) break;
                if (self.tree.get(p)) |pinode| {
                    const p_now_alive = if (pinode.alive.get()) |a| a.* else false;
                    const p_tgt_alive = if (pinode.alive.getIn(target_view)) |a| a.* else false;
                    if (p_tgt_alive and !p_now_alive) {
                        try restore_set.put(allocator, p, {});
                    }
                }
                anc = p;
            }

            var now_entry = try self.tree.placementIn(allocator, View.EVERYTHING, iid);
            defer if (now_entry) |*ne| ne.deinit(allocator);
            var target_entry = try self.tree.placementIn(allocator, target_view, iid);
            defer if (target_entry) |*te| te.deinit(allocator);
            const inode = self.tree.get(iid) orelse continue;
            if (target_entry) |te| {
                const tp = &te.value;
                const eff_moved = if (now_entry) |ne|
                    (!ne.value.parent.eql(tp.parent) or !std.mem.eql(u8, ne.value.name, tp.name))
                else
                    true;
                const raw_moved = if (inode.placement.get()) |rn|
                    (!rn.parent.eql(tp.parent) or !std.mem.eql(u8, rn.name, tp.name))
                else
                    true;
                if (eff_moved or raw_moved) {
                    const name_copy = try allocator.dupe(u8, tp.name);
                    errdefer allocator.free(name_copy);
                    try phase2_ops.append(allocator, .{ .rename = .{
                        .inode = iid,
                        .parent = tp.parent,
                        .name = name_copy,
                    } });
                }
            }

            try self.appendNodeRevertOps(allocator, &phase2_ops, &blobs, iid, inode, res, target_view);
        }

        const total_ops = restore_set.count() + phase2_ops.items.len + phase3_items.items.len;
        if (total_ops == 0) {
            phase2_ops.deinit(allocator);
            for (blobs.items) |*b| b.deinit(allocator);
            blobs.deinit(allocator);
            return null;
        }

        const restore_ids = try allocator.dupe(id.InodeId, restore_set.keys());
        defer allocator.free(restore_ids);
        std.mem.sort(id.InodeId, restore_ids, {}, struct {
            fn lt(_: void, a: id.InodeId, b: id.InodeId) bool {
                return a.order(b) == .lt;
            }
        }.lt);

        std.mem.sort(RemoveItem, phase3_items.items, {}, struct {
            fn lt(_: void, a: RemoveItem, b: RemoveItem) bool {
                if (a.depth != b.depth) return a.depth > b.depth;
                return a.iid.order(b.iid) == .lt;
            }
        }.lt);

        const parents = try self.dag.heads.clone(allocator);
        var parents_owned = true;
        errdefer if (parents_owned) {
            var p = parents;
            p.deinit(allocator);
        };

        const ops_slice = try allocator.alloc(op_mod.Op, total_ops);
        var built: usize = 0;
        errdefer {
            for (ops_slice[0..built]) |*o| o.deinit(allocator);
            allocator.free(ops_slice);
        }

        for (restore_ids) |rid| {
            ops_slice[built] = .{ .restore = .{ .inode = rid } };
            built += 1;
        }
        for (phase2_ops.items) |op_item| {
            ops_slice[built] = op_item;
            built += 1;
        }
        phase2_ops.clearRetainingCapacity();
        phase2_ops.deinit(allocator);

        for (phase3_items.items) |rm| {
            ops_slice[built] = .{ .remove = .{ .inode = rm.iid } };
            built += 1;
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

    pub fn buildRollbackBatch(
        self: *const History,
        allocator: Allocator,
        actor: id.ActorId,
        target_version: *const Version,
        wall_ms: u64,
    ) (RevertError || Allocator.Error)!?op_mod.Batch {
        var diff_batches = try self.dag.difference(allocator, &self.dag.heads, target_version);
        defer diff_batches.deinit(allocator);
        if (diff_batches.items.len == 0) return null;

        var cv = try self.dag.compileExcluding(allocator, diff_batches.items);
        defer cv.deinit(allocator);
        return try self.buildRevertForTarget(allocator, actor, cv.view(), diff_batches.items, wall_ms);
    }

    pub fn buildRevertScopeBatch(
        self: *const History,
        allocator: Allocator,
        actor: id.ActorId,
        excluded: []const id.BatchId,
        wall_ms: u64,
    ) (RevertError || Allocator.Error)!?op_mod.Batch {
        if (excluded.len == 0) return null;

        var cv = try self.dag.compileExcluding(allocator, excluded);
        defer cv.deinit(allocator);
        return try self.buildRevertForTarget(allocator, actor, cv.view(), excluded, wall_ms);
    }
};
