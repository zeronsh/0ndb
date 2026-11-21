const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const version_mod = @import("version.zig");
const Version = version_mod.Version;
const codec = @import("../store/codec.zig");
const text_mod = @import("text.zig");

pub const BatchHeader = struct {
    actor: id.ActorId,
    start: id.Lamport,
    end: id.Lamport,
    parents: Version,
    wall_ms: u64,

    pub fn batchId(self: *const BatchHeader) id.BatchId {
        return id.OpId.init(self.end, self.actor);
    }

    pub fn opCount(self: *const BatchHeader) u64 {
        if (self.end < self.start) return 0;
        return (self.end - self.start) +| 1;
    }

    pub fn opId(self: *const BatchHeader, index: usize) id.OpId {
        return id.OpId.init(self.start + @as(u64, @intCast(index)), self.actor);
    }

    pub fn deinit(self: *BatchHeader, allocator: Allocator) void {
        self.parents.deinit(allocator);
    }

    pub fn clone(self: *const BatchHeader, allocator: Allocator) Allocator.Error!BatchHeader {
        return .{
            .actor = self.actor,
            .start = self.start,
            .end = self.end,
            .parents = try self.parents.clone(allocator),
            .wall_ms = self.wall_ms,
        };
    }

    pub fn encode(self: *const BatchHeader, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.actor);
        try w.writeU64(allocator, self.start);
        try w.writeU64(allocator, self.end);
        try w.writeU64(allocator, self.wall_ms);
        try self.parents.encode(allocator, w);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!BatchHeader {
        const actor = try r.readU128();
        const start = try r.readU64();
        const end = try r.readU64();
        const wall_ms = try r.readU64();
        const parents = try Version.decode(allocator, r);
        return .{
            .actor = actor,
            .start = start,
            .end = end,
            .parents = parents,
            .wall_ms = wall_ms,
        };
    }
};

pub const DagError = error{
    MissingParents,
    LamportViolation,
    InvalidRange,
    Overlap,
};

pub const ActorRun = struct {
    start: id.Lamport,
    end: id.Lamport,
    batch_idx: u32,
};

pub const BatchLocation = struct {
    seg_id: u32 = 0,
    offset: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
};

pub const BatchMeta = struct {
    actor: id.ActorId,
    start: id.Lamport,
    end: id.Lamport,
    wall_ms: u64,
    batch_idx: u32,
    log_seg: u32 = 0,
    log_off: u64 = 0,
    log_len: u32 = 0,
    flags: u16 = 0,
};

pub const DagSource = struct {
    ptr: *const anyopaque,
    batchCountFn: *const fn (ptr: *const anyopaque) usize,
    getBatchMetaFn: *const fn (ptr: *const anyopaque, bid: id.BatchId) ?BatchMeta,
    appendParentsFn: *const fn (ptr: *const anyopaque, allocator: Allocator, bid: id.BatchId, out: *std.ArrayList(id.BatchId)) Allocator.Error!bool,
    parentsEqualFn: *const fn (ptr: *const anyopaque, bid: id.BatchId, parents: *const Version) bool,
    actorRangeOverlapsFn: *const fn (ptr: *const anyopaque, actor: id.ActorId, start: id.Lamport, end: id.Lamport) bool,
    findActorRunFn: *const fn (ptr: *const anyopaque, op: id.OpId) ?ActorRun,
    appendAllBatchIdsFn: *const fn (ptr: *const anyopaque, allocator: Allocator, out: *std.ArrayList(id.BatchId)) Allocator.Error!void,

    pub fn batchCount(self: DagSource) usize {
        return self.batchCountFn(self.ptr);
    }

    pub fn getBatchMeta(self: DagSource, bid: id.BatchId) ?BatchMeta {
        return self.getBatchMetaFn(self.ptr, bid);
    }

    pub fn appendParents(self: DagSource, allocator: Allocator, bid: id.BatchId, out: *std.ArrayList(id.BatchId)) Allocator.Error!bool {
        return self.appendParentsFn(self.ptr, allocator, bid, out);
    }

    pub fn parentsEqual(self: DagSource, bid: id.BatchId, parents: *const Version) bool {
        return self.parentsEqualFn(self.ptr, bid, parents);
    }

    pub fn actorRangeOverlaps(self: DagSource, actor: id.ActorId, start: id.Lamport, end: id.Lamport) bool {
        return self.actorRangeOverlapsFn(self.ptr, actor, start, end);
    }

    pub fn findActorRun(self: DagSource, op: id.OpId) ?ActorRun {
        return self.findActorRunFn(self.ptr, op);
    }

    pub fn appendAllBatchIds(self: DagSource, allocator: Allocator, out: *std.ArrayList(id.BatchId)) Allocator.Error!void {
        return self.appendAllBatchIdsFn(self.ptr, allocator, out);
    }
};

pub const CompiledView = struct {
    dag: *const Dag,
    min_unobserved: id.Lamport,
    mode: enum(u8) {
        everything,
        inline_excl,
        bitset_excl,
    },
    inline_len: u8 = 0,
    inline_ids: [32]u32 = undefined,
    bitset: []u64 = &.{},

    pub fn deinit(self: *CompiledView, allocator: Allocator) void {
        if (self.bitset.len > 0) {
            allocator.free(self.bitset);
            self.bitset = &.{};
        }
    }

    pub fn observes(self: *const CompiledView, op: id.OpId) bool {
        if (self.mode == .everything) return true;
        if (op.ts < self.min_unobserved) return true;
        const bidx = self.dag.batchIndexOf(op) orelse return false;
        switch (self.mode) {
            .everything => return true,
            .inline_excl => {
                for (self.inline_ids[0..self.inline_len]) |ex| {
                    if (ex == bidx) return false;
                }
                return true;
            },
            .bitset_excl => {
                const word = bidx >> 6;
                if (word >= self.bitset.len) return true;
                const bit: u64 = @as(u64, 1) << @as(u6, @intCast(bidx & 63));
                return (self.bitset[word] & bit) == 0;
            },
        }
    }

    fn observesAdapter(ptr: *const anyopaque, op: id.OpId) bool {
        const self: *const CompiledView = @ptrCast(@alignCast(ptr));
        return self.observes(op);
    }

    pub fn view(self: *const CompiledView) text_mod.View {
        if (self.mode == .everything) return text_mod.View.EVERYTHING;
        return .{
            .ptr = self,
            .observesFn = observesAdapter,
            .min_unobserved = self.min_unobserved,
        };
    }
};

pub const Dag = struct {
    headers: std.AutoHashMapUnmanaged(id.BatchId, BatchHeader) = .empty,
    batch_indices: std.AutoHashMapUnmanaged(id.BatchId, u32) = .empty,
    by_actor: std.AutoHashMapUnmanaged(id.ActorId, std.ArrayList(ActorRun)) = .empty,
    batch_locations: std.AutoHashMapUnmanaged(id.BatchId, BatchLocation) = .empty,
    source: ?DagSource = null,
    heads: Version = Version.ROOT,
    horizon: Version = Version.ROOT,
    max_ts: id.Lamport = 0,
    next_batch_idx: u32 = 0,

    pub fn deinit(self: *Dag, allocator: Allocator) void {
        var hit = self.headers.valueIterator();
        while (hit.next()) |h| {
            h.deinit(allocator);
        }
        self.headers.deinit(allocator);
        self.batch_indices.deinit(allocator);
        var ait = self.by_actor.valueIterator();
        while (ait.next()) |list| {
            list.deinit(allocator);
        }
        self.by_actor.deinit(allocator);
        self.batch_locations.deinit(allocator);
        self.heads.deinit(allocator);
        self.horizon.deinit(allocator);
        self.source = null;
    }

    pub fn setSource(self: *Dag, src: ?DagSource) void {
        self.source = src;
    }

    pub fn clearOverlayAfterCheckpoint(self: *Dag, allocator: Allocator) void {
        var hit = self.headers.valueIterator();
        while (hit.next()) |h| {
            h.deinit(allocator);
        }
        self.headers.clearRetainingCapacity();
        self.batch_indices.clearRetainingCapacity();
        var ait = self.by_actor.valueIterator();
        while (ait.next()) |list| {
            list.deinit(allocator);
        }
        self.by_actor.clearRetainingCapacity();
        self.batch_locations.clearRetainingCapacity();
    }

    pub fn setHorizon(self: *Dag, allocator: Allocator, new_horizon: *const Version) Allocator.Error!void {
        const cloned = try new_horizon.clone(allocator);
        self.horizon.deinit(allocator);
        self.horizon = cloned;
    }

    pub fn setBatchLocation(self: *Dag, allocator: Allocator, bid: id.BatchId, loc: BatchLocation) Allocator.Error!void {
        try self.batch_locations.put(allocator, bid, loc);
    }

    pub fn getBatchLocation(self: *const Dag, bid: id.BatchId) ?BatchLocation {
        if (self.batch_locations.get(bid)) |loc| return loc;
        if (self.source) |src| {
            if (src.getBatchMeta(bid)) |m| {
                return .{
                    .seg_id = m.log_seg,
                    .offset = m.log_off,
                    .len = m.log_len,
                    .flags = m.flags,
                };
            }
        }
        return null;
    }

    pub fn count(self: *const Dag) usize {
        var n: usize = self.headers.count();
        if (self.source) |src| {
            n += src.batchCount();
        }
        return n;
    }

    pub fn containsBatch(self: *const Dag, bid: id.BatchId) bool {
        if (self.headers.contains(bid)) return true;
        if (self.source) |src| return src.getBatchMeta(bid) != null;
        return false;
    }

    pub fn getHeader(self: *const Dag, bid: id.BatchId) ?*const BatchHeader {
        return self.headers.getPtr(bid);
    }

    pub fn getBatchMeta(self: *const Dag, bid: id.BatchId) ?BatchMeta {
        if (self.headers.getPtr(bid)) |h| {
            const loc = self.batch_locations.get(bid) orelse BatchLocation{};
            return .{
                .actor = h.actor,
                .start = h.start,
                .end = h.end,
                .wall_ms = h.wall_ms,
                .batch_idx = self.batch_indices.get(bid) orelse 0,
                .log_seg = loc.seg_id,
                .log_off = loc.offset,
                .log_len = loc.len,
                .flags = loc.flags,
            };
        }
        if (self.source) |src| return src.getBatchMeta(bid);
        return null;
    }

    pub fn getHeaderAlloc(self: *const Dag, allocator: Allocator, bid: id.BatchId) Allocator.Error!?BatchHeader {
        if (self.headers.getPtr(bid)) |h| return try h.clone(allocator);
        if (self.source) |src| {
            const meta = src.getBatchMeta(bid) orelse return null;
            var plist: std.ArrayList(id.BatchId) = .empty;
            defer plist.deinit(allocator);
            _ = try src.appendParents(allocator, bid, &plist);
            var parents = Version{};
            errdefer parents.deinit(allocator);
            for (plist.items) |p| try parents.insert(allocator, p);
            return .{
                .actor = meta.actor,
                .start = meta.start,
                .end = meta.end,
                .parents = parents,
                .wall_ms = meta.wall_ms,
            };
        }
        return null;
    }

    pub fn collectAllBatchIds(self: *const Dag, allocator: Allocator) Allocator.Error!std.ArrayList(id.BatchId) {
        var out: std.ArrayList(id.BatchId) = .empty;
        errdefer out.deinit(allocator);
        if (self.source) |src| {
            try src.appendAllBatchIds(allocator, &out);
        }
        var it = self.headers.keyIterator();
        while (it.next()) |k| {
            if (self.source) |src| {
                if (src.getBatchMeta(k.*) != null) continue;
            }
            try out.append(allocator, k.*);
        }
        return out;
    }

    fn appendParentsOf(self: *const Dag, allocator: Allocator, bid: id.BatchId, out: *std.ArrayList(id.BatchId)) Allocator.Error!void {
        if (self.headers.getPtr(bid)) |h| {
            try out.appendSlice(allocator, h.parents.slice());
            return;
        }
        if (self.source) |src| {
            _ = try src.appendParents(allocator, bid, out);
        }
    }

    fn batchIdxOfId(self: *const Dag, bid: id.BatchId) ?u32 {
        if (self.batch_indices.get(bid)) |bidx| return bidx;
        if (self.source) |src| {
            if (src.getBatchMeta(bid)) |m| return m.batch_idx;
        }
        return null;
    }

    fn batchStartOfId(self: *const Dag, bid: id.BatchId) ?id.Lamport {
        if (self.headers.getPtr(bid)) |h| return h.start;
        if (self.source) |src| {
            if (src.getBatchMeta(bid)) |m| return m.start;
        }
        return null;
    }

    pub const MAX_SAFE_LAMPORT: id.Lamport = std.math.maxInt(id.Lamport) - (1 << 20);
    pub const MAX_LAMPORT_JUMP: id.Lamport = 1 << 32;

    pub fn check(self: *const Dag, h: *const BatchHeader) DagError!bool {
        if (h.end < h.start or h.start == 0) return error.InvalidRange;
        if (h.end > MAX_SAFE_LAMPORT) return error.LamportViolation;
        if (h.end - h.start > MAX_LAMPORT_JUMP) return error.LamportViolation;
        const bid = h.batchId();
        if (self.headers.getPtr(bid)) |existing| {
            if (existing.start == h.start and existing.parents.eql(&h.parents)) {
                return true;
            }
            return error.Overlap;
        }
        if (self.source) |src| {
            if (src.getBatchMeta(bid)) |existing| {
                if (existing.start == h.start and src.parentsEqual(bid, &h.parents)) {
                    return true;
                }
                return error.Overlap;
            }
        }
        for (h.parents.slice()) |p| {
            if (!self.containsBatch(p)) return error.MissingParents;
        }
        const parent_max = h.parents.maxTs();
        if (h.start <= parent_max) return error.LamportViolation;
        if (h.start - parent_max > MAX_LAMPORT_JUMP) return error.LamportViolation;
        if (self.by_actor.getPtr(h.actor)) |runs| {
            const idx = lowerBoundRuns(runs.items, h.start);
            if (idx < runs.items.len and runs.items[idx].start <= h.end) {
                return error.Overlap;
            }
        }
        if (self.source) |src| {
            if (src.actorRangeOverlaps(h.actor, h.start, h.end)) {
                return error.Overlap;
            }
        }
        return false;
    }

    pub fn insert(self: *Dag, allocator: Allocator, h: BatchHeader) (DagError || Allocator.Error)!bool {
        if (try self.check(&h)) {
            var tmp = h;
            tmp.deinit(allocator);
            return false;
        }
        const bid = h.batchId();
        const actor = h.actor;
        const start = h.start;
        const end = h.end;
        const bidx = self.next_batch_idx;

        for (h.parents.slice()) |p| {
            _ = self.heads.remove(p);
        }
        try self.heads.insert(allocator, bid);
        if (end > self.max_ts) self.max_ts = end;

        const gop = try self.by_actor.getOrPut(allocator, actor);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        const pos = lowerBoundRuns(gop.value_ptr.items, start);
        try gop.value_ptr.insert(allocator, pos, .{ .start = start, .end = end, .batch_idx = bidx });
        try self.batch_indices.put(allocator, bid, bidx);
        try self.headers.put(allocator, bid, h);
        self.next_batch_idx += 1;
        return true;
    }

    pub fn batchOf(self: *const Dag, op: id.OpId) ?id.BatchId {
        if (self.by_actor.getPtr(op.actor)) |runs| {
            const idx = lowerBoundRuns(runs.items, op.ts);
            if (idx < runs.items.len) {
                const run = runs.items[idx];
                if (op.ts >= run.start and op.ts <= run.end) {
                    return id.OpId.init(run.end, op.actor);
                }
            }
        }
        if (self.source) |src| {
            if (src.findActorRun(op)) |run| {
                return id.OpId.init(run.end, op.actor);
            }
        }
        return null;
    }

    pub fn batchIndexOf(self: *const Dag, op: id.OpId) ?u32 {
        if (self.by_actor.getPtr(op.actor)) |runs| {
            const idx = lowerBoundRuns(runs.items, op.ts);
            if (idx < runs.items.len) {
                const run = runs.items[idx];
                if (op.ts >= run.start and op.ts <= run.end) {
                    return run.batch_idx;
                }
            }
        }
        if (self.source) |src| {
            if (src.findActorRun(op)) |run| {
                return run.batch_idx;
            }
        }
        return null;
    }

    pub fn compileView(self: *const Dag, allocator: Allocator, v: *const Version) Allocator.Error!CompiledView {
        if (v.eql(&self.heads)) {
            return .{
                .dag = self,
                .min_unobserved = std.math.maxInt(id.Lamport),
                .mode = .everything,
            };
        }
        var diff_batches = try self.difference(allocator, &self.heads, v);
        defer diff_batches.deinit(allocator);
        if (diff_batches.items.len == 0) {
            return .{
                .dag = self,
                .min_unobserved = std.math.maxInt(id.Lamport),
                .mode = .everything,
            };
        }

        var min_ts: id.Lamport = std.math.maxInt(id.Lamport);
        for (diff_batches.items) |bid| {
            if (self.batchStartOfId(bid)) |st| {
                if (st < min_ts) min_ts = st;
            } else if (bid.ts < min_ts) {
                min_ts = bid.ts;
            }
        }

        if (diff_batches.items.len <= 32) {
            var cv = CompiledView{
                .dag = self,
                .min_unobserved = min_ts,
                .mode = .inline_excl,
                .inline_len = 0,
            };
            for (diff_batches.items) |bid| {
                if (self.batchIdxOfId(bid)) |bidx| {
                    cv.inline_ids[cv.inline_len] = bidx;
                    cv.inline_len += 1;
                }
            }
            return cv;
        }

        const words = (@as(usize, self.next_batch_idx) + 63) / 64;
        const bits = try allocator.alloc(u64, words);
        @memset(bits, 0);
        for (diff_batches.items) |bid| {
            if (self.batchIdxOfId(bid)) |bidx| {
                const w = bidx >> 6;
                if (w < bits.len) {
                    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bidx & 63));
                    bits[w] |= mask;
                }
            }
        }
        return .{
            .dag = self,
            .min_unobserved = min_ts,
            .mode = .bitset_excl,
            .bitset = bits,
        };
    }

    pub fn compileExcluding(self: *const Dag, allocator: Allocator, excluded: []const id.BatchId) Allocator.Error!CompiledView {
        if (excluded.len == 0) {
            return .{
                .dag = self,
                .min_unobserved = std.math.maxInt(id.Lamport),
                .mode = .everything,
            };
        }
        var min_ts: id.Lamport = std.math.maxInt(id.Lamport);
        for (excluded) |bid| {
            if (self.batchStartOfId(bid)) |st| {
                if (st < min_ts) min_ts = st;
            } else if (bid.ts < min_ts) {
                min_ts = bid.ts;
            }
        }
        if (excluded.len <= 32) {
            var cv = CompiledView{
                .dag = self,
                .min_unobserved = min_ts,
                .mode = .inline_excl,
                .inline_len = 0,
            };
            for (excluded) |bid| {
                if (self.batchIdxOfId(bid)) |bidx| {
                    cv.inline_ids[cv.inline_len] = bidx;
                    cv.inline_len += 1;
                }
            }
            return cv;
        }
        const words = (@as(usize, self.next_batch_idx) + 63) / 64;
        const bits = try allocator.alloc(u64, words);
        @memset(bits, 0);
        for (excluded) |bid| {
            if (self.batchIdxOfId(bid)) |bidx| {
                const w = bidx >> 6;
                if (w < bits.len) {
                    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bidx & 63));
                    bits[w] |= mask;
                }
            }
        }
        return .{
            .dag = self,
            .min_unobserved = min_ts,
            .mode = .bitset_excl,
            .bitset = bits,
        };
    }

    pub fn versionContainsBatch(self: *const Dag, allocator: Allocator, v: *const Version, target: id.BatchId) Allocator.Error!bool {
        if (v.contains(target)) return true;
        var stack: std.ArrayList(id.BatchId) = .empty;
        defer stack.deinit(allocator);
        var seen: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        defer seen.deinit(allocator);

        try stack.appendSlice(allocator, v.slice());
        while (stack.pop()) |cur| {
            if (cur.eql(target)) return true;
            if (cur.ts <= target.ts) continue;
            const gop = try seen.getOrPut(allocator, cur);
            if (gop.found_existing) continue;
            try self.appendParentsOf(allocator, cur, &stack);
        }
        return false;
    }

    pub fn versionContainsOp(self: *const Dag, allocator: Allocator, v: *const Version, op: id.OpId) Allocator.Error!bool {
        const bid = self.batchOf(op) orelse return false;
        return self.versionContainsBatch(allocator, v, bid);
    }

    pub fn includes(self: *const Dag, allocator: Allocator, a: *const Version, b: *const Version) Allocator.Error!bool {
        for (b.slice()) |h| {
            if (!try self.versionContainsBatch(allocator, a, h)) return false;
        }
        return true;
    }

    pub fn difference(self: *const Dag, allocator: Allocator, a: *const Version, b: *const Version) Allocator.Error!std.ArrayList(id.BatchId) {
        var out: std.ArrayList(id.BatchId) = .empty;
        errdefer out.deinit(allocator);
        if (a.eql(b)) return out;

        const OrderCtx = struct {
            fn cmp(_: void, lhs: id.BatchId, rhs: id.BatchId) std.math.Order {
                return rhs.order(lhs);
            }
        };
        var state: std.AutoHashMapUnmanaged(id.BatchId, bool) = .empty;
        defer state.deinit(allocator);
        var done: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        defer done.deinit(allocator);
        var heap = std.PriorityQueue(id.BatchId, void, OrderCtx.cmp).empty;
        defer heap.deinit(allocator);
        var parents_tmp: std.ArrayList(id.BatchId) = .empty;
        defer parents_tmp.deinit(allocator);
        var outside: usize = 0;

        for (b.slice()) |h| {
            try pushDiff(allocator, h, true, &state, &heap, &outside);
        }
        for (a.slice()) |h| {
            try pushDiff(allocator, h, false, &state, &heap, &outside);
        }

        while (outside > 0) {
            const cur = heap.pop() orelse break;
            const dgop = try done.getOrPut(allocator, cur);
            if (dgop.found_existing) continue;
            const in_b = state.get(cur) orelse false;
            if (!in_b) {
                outside -= 1;
                try out.append(allocator, cur);
            }
            parents_tmp.clearRetainingCapacity();
            try self.appendParentsOf(allocator, cur, &parents_tmp);
            for (parents_tmp.items) |p| {
                try pushDiff(allocator, p, in_b, &state, &heap, &outside);
            }
        }
        self.topoSortSlice(out.items);
        return out;
    }

    pub fn topoSortSlice(self: *const Dag, items: []id.BatchId) void {
        const Ctx = struct {
            dag: *const Dag,
            fn lessThan(ctx: @This(), lhs: id.BatchId, rhs: id.BatchId) bool {
                const ls = ctx.dag.batchStartOfId(lhs) orelse lhs.ts;
                const rs = ctx.dag.batchStartOfId(rhs) orelse rhs.ts;
                if (ls != rs) return ls < rs;
                return lhs.actor < rhs.actor;
            }
        };
        std.mem.sort(id.BatchId, items, Ctx{ .dag = self }, Ctx.lessThan);
    }

    pub fn minUnobservedFor(self: *const Dag, allocator: Allocator, v: *const Version) Allocator.Error!id.Lamport {
        var diff = try self.difference(allocator, &self.heads, v);
        defer diff.deinit(allocator);
        var min_ts: id.Lamport = std.math.maxInt(id.Lamport);
        for (diff.items) |bid| {
            if (self.batchStartOfId(bid)) |st| {
                if (st < min_ts) min_ts = st;
            } else if (bid.ts < min_ts) {
                min_ts = bid.ts;
            }
        }
        return min_ts;
    }

    pub fn closure(self: *const Dag, allocator: Allocator, v: *const Version) Allocator.Error!std.AutoHashMapUnmanaged(id.BatchId, void) {
        var seen: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        errdefer seen.deinit(allocator);
        var stack: std.ArrayList(id.BatchId) = .empty;
        defer stack.deinit(allocator);

        try stack.appendSlice(allocator, v.slice());
        while (stack.pop()) |cur| {
            const gop = try seen.getOrPut(allocator, cur);
            if (gop.found_existing) continue;
            try self.appendParentsOf(allocator, cur, &stack);
        }
        return seen;
    }

    pub fn commonFrontier(self: *const Dag, allocator: Allocator, versions: []const Version) Allocator.Error!Version {
        if (versions.len == 0) return Version.ROOT;
        for (versions) |*ver| {
            if (ver.isEmpty()) return Version.ROOT;
        }

        var common = try self.closure(allocator, &versions[0]);
        defer common.deinit(allocator);

        var to_remove: std.ArrayList(id.BatchId) = .empty;
        defer to_remove.deinit(allocator);

        for (versions[1..]) |*ver| {
            if (common.count() == 0) return Version.ROOT;
            var cur_closure = try self.closure(allocator, ver);
            defer cur_closure.deinit(allocator);
            to_remove.clearRetainingCapacity();
            var it = common.keyIterator();
            while (it.next()) |k| {
                if (!cur_closure.contains(k.*)) {
                    try to_remove.append(allocator, k.*);
                }
            }
            for (to_remove.items) |k| {
                _ = common.remove(k);
            }
        }

        if (common.count() == 0) return Version.ROOT;

        var non_maximal: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
        defer non_maximal.deinit(allocator);
        var parents_tmp: std.ArrayList(id.BatchId) = .empty;
        defer parents_tmp.deinit(allocator);
        var cit = common.keyIterator();
        while (cit.next()) |k| {
            parents_tmp.clearRetainingCapacity();
            try self.appendParentsOf(allocator, k.*, &parents_tmp);
            for (parents_tmp.items) |p| {
                if (common.contains(p)) {
                    try non_maximal.put(allocator, p, {});
                }
            }
        }

        var out = Version{};
        errdefer out.deinit(allocator);
        var fit = common.keyIterator();
        while (fit.next()) |k| {
            if (!non_maximal.contains(k.*)) {
                try out.insert(allocator, k.*);
            }
        }
        return out;
    }
};

fn pushDiff(
    allocator: Allocator,
    bid: id.BatchId,
    in_b: bool,
    state: *std.AutoHashMapUnmanaged(id.BatchId, bool),
    heap: anytype,
    outside: *usize,
) Allocator.Error!void {
    const gop = try state.getOrPut(allocator, bid);
    if (!gop.found_existing) {
        gop.value_ptr.* = in_b;
        try heap.push(allocator, bid);
        if (!in_b) outside.* += 1;
    } else if (in_b and !gop.value_ptr.*) {
        gop.value_ptr.* = true;
        outside.* -= 1;
    }
}

fn lowerBoundRuns(runs: []const ActorRun, target_ts: id.Lamport) usize {
    var lo: usize = 0;
    var hi: usize = runs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (runs[mid].end < target_ts) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}
