const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const diff = @import("diff.zig");

pub const View = struct {
    ptr: *const anyopaque,
    observesFn: *const fn (ptr: *const anyopaque, op: id.OpId) bool,
    min_unobserved: u64 = std.math.maxInt(u64),

    pub fn observes(self: View, op: id.OpId) bool {
        if (op.ts < self.min_unobserved) return true;
        return self.observesFn(self.ptr, op);
    }

    fn alwaysTrue(_: *const anyopaque, _: id.OpId) bool {
        return true;
    }

    var dummy_ctx: u8 = 0;

    pub const EVERYTHING = View{
        .ptr = &dummy_ctx,
        .observesFn = alwaysTrue,
        .min_unobserved = std.math.maxInt(u64),
    };
};

pub const FragSummary = struct {
    visible: u64 = 0,
    visible_newlines: u64 = 0,
    total: u64 = 0,
    max_ts: u64 = 0,
    ends_with_nl: bool = false,
    unknown_newlines: bool = false,

    pub inline fn add(self: *FragSummary, other: FragSummary) void {
        self.visible += other.visible;
        self.visible_newlines += other.visible_newlines;
        self.total += other.total;
        if (other.max_ts > self.max_ts) self.max_ts = other.max_ts;
        if (other.visible > 0) self.ends_with_nl = other.ends_with_nl;
        if (other.unknown_newlines) self.unknown_newlines = true;
    }
};

pub const ContentResolver = struct {
    ptr: *const anyopaque,
    resolveFn: *const fn (ptr: *const anyopaque, key: id.InsertionKey) ?[]const u8,

    pub fn resolve(self: ContentResolver, key: id.InsertionKey) ?[]const u8 {
        return self.resolveFn(self.ptr, key);
    }
};

fn countNewlinesSlice(slice: []const u8) u32 {
    var n: u32 = 0;
    for (slice) |b| {
        if (b == '\n') n +|= 1;
    }
    return n;
}

pub const Fragment = struct {
    ins: id.OpId,
    part: u32,
    newlines: u32 = 0,
    off: u64,
    len: u64,
    del_count: u8 = 0,
    ends_with_nl: bool = false,
    newlines_known: bool = true,
    del_inline: id.OpId = id.OpId.ZERO,
    del_overflow: ?[]id.OpId = null,

    pub fn deinit(self: *Fragment, allocator: Allocator) void {
        if (self.del_overflow) |ov| {
            allocator.free(ov);
            self.del_overflow = null;
        }
    }

    pub fn clone(self: *const Fragment, allocator: Allocator) Allocator.Error!Fragment {
        var copy = self.*;
        if (self.del_overflow) |ov| {
            copy.del_overflow = try allocator.dupe(id.OpId, ov);
        }
        return copy;
    }

    pub fn key(self: *const Fragment) id.InsertionKey {
        return .{ .op = self.ins, .part = self.part };
    }

    pub inline fn isVisible(self: *const Fragment) bool {
        return self.del_count == 0;
    }

    pub fn maxTs(self: *const Fragment) u64 {
        var m = self.ins.ts;
        if (self.del_count == 1) {
            if (self.del_inline.ts > m) m = self.del_inline.ts;
        } else if (self.del_overflow) |ov| {
            for (ov) |d| {
                if (d.ts > m) m = d.ts;
            }
        }
        return m;
    }

    pub fn visibleIn(self: *const Fragment, view: View) bool {
        if (!view.observes(self.ins)) return false;
        if (self.del_count == 0) return true;
        if (self.del_count == 1) return !view.observes(self.del_inline);
        if (self.del_overflow) |ov| {
            for (ov) |d| {
                if (view.observes(d)) return false;
            }
        }
        return true;
    }

    pub fn widthIn(self: *const Fragment, view: View) u64 {
        const vis = if (self.maxTs() < view.min_unobserved) self.isVisible() else self.visibleIn(view);
        return if (vis) self.len else 0;
    }

    pub fn summary(self: *const Fragment) FragSummary {
        const vis = self.isVisible() and self.len > 0;
        return .{
            .visible = if (vis) self.len else 0,
            .visible_newlines = if (vis and self.newlines_known) self.newlines else 0,
            .total = self.len,
            .max_ts = self.maxTs(),
            .ends_with_nl = if (vis and self.newlines_known) self.ends_with_nl else false,
            .unknown_newlines = vis and !self.newlines_known,
        };
    }

    pub fn markDeleted(self: *Fragment, allocator: Allocator, op: id.OpId) Allocator.Error!void {
        if (self.del_count == 0) {
            self.del_inline = op;
            self.del_count = 1;
            return;
        }
        if (self.del_count == 1) {
            if (self.del_inline.eql(op)) return;
            const ov = try allocator.alloc(id.OpId, 2);
            if (self.del_inline.lessThan(op)) {
                ov[0] = self.del_inline;
                ov[1] = op;
            } else {
                ov[0] = op;
                ov[1] = self.del_inline;
            }
            self.del_overflow = ov;
            self.del_count = 2;
            return;
        }
        const ov = self.del_overflow orelse return;
        for (ov) |d| {
            if (d.eql(op)) return;
        }
        var grown = try allocator.alloc(id.OpId, ov.len + 1);
        var inserted = false;
        var dst: usize = 0;
        for (ov) |d| {
            if (!inserted and op.lessThan(d)) {
                grown[dst] = op;
                dst += 1;
                inserted = true;
            }
            grown[dst] = d;
            dst += 1;
        }
        if (!inserted) grown[dst] = op;
        allocator.free(ov);
        self.del_overflow = grown;
        self.del_count = @intCast(@min(grown.len, 255));
    }

    pub fn split(self: *const Fragment, allocator: Allocator, at: u64, resolver_opt: ?ContentResolver) Allocator.Error!struct { Fragment, Fragment } {
        var left = try self.clone(allocator);
        errdefer left.deinit(allocator);
        var right = try self.clone(allocator);
        left.len = at;
        right.off += at;
        right.len -= at;

        if (self.newlines_known and self.newlines == 0) {
            left.newlines = 0;
            right.newlines = 0;
            left.ends_with_nl = false;
            right.ends_with_nl = false;
            left.newlines_known = true;
            right.newlines_known = true;
        } else {
            var resolved = false;
            if (resolver_opt) |res| {
                if (res.resolve(self.key())) |bytes| {
                    const ls: usize = @intCast(left.off);
                    const le: usize = @intCast(left.off + left.len);
                    const re: usize = @intCast(right.off + right.len);
                    if (re <= bytes.len) {
                        if (self.newlines_known) {
                            if (left.len <= right.len) {
                                const lnl = countNewlinesSlice(bytes[ls..le]);
                                left.newlines = lnl;
                                right.newlines = self.newlines -| lnl;
                            } else {
                                const rnl = countNewlinesSlice(bytes[le..re]);
                                right.newlines = rnl;
                                left.newlines = self.newlines -| rnl;
                            }
                        } else {
                            left.newlines = countNewlinesSlice(bytes[ls..le]);
                            right.newlines = countNewlinesSlice(bytes[le..re]);
                        }
                        left.ends_with_nl = left.len > 0 and bytes[le - 1] == '\n';
                        right.ends_with_nl = right.len > 0 and bytes[re - 1] == '\n';
                        left.newlines_known = true;
                        right.newlines_known = true;
                        resolved = true;
                    }
                }
            }
            if (!resolved) {
                left.newlines = 0;
                right.newlines = 0;
                left.ends_with_nl = false;
                right.ends_with_nl = false;
                left.newlines_known = false;
                right.newlines_known = false;
            }
        }
        return .{ left, right };
    }

    pub fn deletesEqual(self: *const Fragment, other: *const Fragment) bool {
        if (self.del_count != other.del_count) return false;
        if (self.del_count == 0) return true;
        if (self.del_count == 1) return self.del_inline.eql(other.del_inline);
        const a = self.del_overflow orelse return false;
        const b = other.del_overflow orelse return false;
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    pub fn mergeableWith(self: *const Fragment, next: *const Fragment) bool {
        return self.ins.eql(next.ins) and
            self.part == next.part and
            self.off + self.len == next.off and
            self.deletesEqual(next);
    }

    pub fn appendMerged(self: *Fragment, next: *const Fragment) void {
        self.len += next.len;
        if (self.newlines_known and next.newlines_known) {
            self.newlines +|= next.newlines;
            if (next.len > 0) self.ends_with_nl = next.ends_with_nl;
        } else {
            self.newlines = 0;
            self.ends_with_nl = false;
            self.newlines_known = false;
        }
    }
};

pub const LEAF_CAP: usize = 48;
pub const BRANCH_CAP: usize = 32;

const NodeKind = enum(u8) {
    leaf,
    branch,
};

const BranchData = struct {
    summaries: [BRANCH_CAP]FragSummary,
    counts: [BRANCH_CAP]usize,
    children: [BRANCH_CAP]*Node,
};

const NodeData = union {
    leaf: []Fragment,
    branch: *BranchData,
};

fn leafCapFor(n: usize) usize {
    if (n <= 1) return 1;
    if (n <= 4) return 4;
    if (n <= 12) return 12;
    if (n <= 24) return 24;
    return LEAF_CAP;
}

const Node = struct {
    refcount: std.atomic.Value(u32),
    kind: NodeKind,
    len: u8,
    summary: FragSummary,
    item_count: usize,
    data: NodeData,

    fn createLeaf(allocator: Allocator, items: []const Fragment) Allocator.Error!*Node {
        const n = try allocator.create(Node);
        errdefer allocator.destroy(n);
        const cap = leafCapFor(items.len);
        const buf = try allocator.alloc(Fragment, cap);
        n.refcount = std.atomic.Value(u32).init(1);
        n.kind = .leaf;
        n.len = @intCast(items.len);
        n.item_count = items.len;
        n.summary = .{};
        n.data = .{ .leaf = buf };
        for (items, 0..) |item, i| {
            n.data.leaf[i] = item;
            n.summary.add(item.summary());
        }
        return n;
    }

    fn createBranch(allocator: Allocator, children: []const *Node) Allocator.Error!*Node {
        const n = try allocator.create(Node);
        errdefer allocator.destroy(n);
        const bd = try allocator.create(BranchData);
        n.refcount = std.atomic.Value(u32).init(1);
        n.kind = .branch;
        n.len = @intCast(children.len);
        n.item_count = 0;
        n.summary = .{};
        n.data = .{ .branch = bd };
        for (children, 0..) |c, i| {
            n.data.branch.children[i] = c;
            n.data.branch.summaries[i] = c.summary;
            n.data.branch.counts[i] = c.item_count;
            n.summary.add(c.summary);
            n.item_count += c.item_count;
        }
        return n;
    }

    inline fn retain(self: *Node) *Node {
        _ = self.refcount.fetchAdd(1, .monotonic);
        return self;
    }

    fn release(self: *Node, allocator: Allocator) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) {
            switch (self.kind) {
                .leaf => {
                    for (self.data.leaf[0..self.len]) |*it| {
                        it.deinit(allocator);
                    }
                    allocator.free(self.data.leaf);
                },
                .branch => {
                    for (self.data.branch.children[0..self.len]) |c| {
                        c.release(allocator);
                    }
                    allocator.destroy(self.data.branch);
                },
            }
            allocator.destroy(self);
        }
    }

    fn makeUnique(self: *Node, allocator: Allocator) Allocator.Error!*Node {
        if (self.refcount.load(.acquire) == 1) return self;
        const copy = switch (self.kind) {
            .leaf => blk: {
                var items: [LEAF_CAP]Fragment = undefined;
                var built: usize = 0;
                errdefer {
                    for (items[0..built]) |*it| it.deinit(allocator);
                }
                for (self.data.leaf[0..self.len]) |*f| {
                    items[built] = try f.clone(allocator);
                    built += 1;
                }
                break :blk try Node.createLeaf(allocator, items[0..built]);
            },
            .branch => blk: {
                var children: [BRANCH_CAP]*Node = undefined;
                for (self.data.branch.children[0..self.len], 0..) |c, i| {
                    children[i] = c.retain();
                }
                errdefer {
                    for (children[0..self.len]) |c| c.release(allocator);
                }
                break :blk try Node.createBranch(allocator, children[0..self.len]);
            },
        };
        self.release(allocator);
        return copy;
    }

    fn recomputeLeaf(self: *Node) void {
        self.summary = .{};
        self.item_count = self.len;
        for (self.data.leaf[0..self.len]) |*f| {
            self.summary.add(f.summary());
        }
    }

    fn recomputeBranch(self: *Node) void {
        self.summary = .{};
        self.item_count = 0;
        for (0..self.len) |i| {
            const c = self.data.branch.children[i];
            self.data.branch.summaries[i] = c.summary;
            self.data.branch.counts[i] = c.item_count;
            self.summary.add(c.summary);
            self.item_count += c.item_count;
        }
    }

    fn widthIn(self: *const Node, view: View) u64 {
        if (self.summary.max_ts < view.min_unobserved) return self.summary.visible;
        var sum: u64 = 0;
        switch (self.kind) {
            .leaf => {
                for (self.data.leaf[0..self.len]) |*f| {
                    sum += f.widthIn(view);
                }
            },
            .branch => {
                for (self.data.branch.children[0..self.len], self.data.branch.summaries[0..self.len]) |c, s| {
                    if (s.max_ts < view.min_unobserved) {
                        sum += s.visible;
                    } else {
                        sum += c.widthIn(view);
                    }
                }
            },
        }
        return sum;
    }
};

fn buildTree(allocator: Allocator, frags: []Fragment) Allocator.Error!?*Node {
    if (frags.len == 0) return null;
    var level: std.ArrayList(*Node) = .empty;
    var level_consumed: usize = 0;
    defer level.deinit(allocator);
    errdefer {
        for (level.items[level_consumed..]) |n| n.release(allocator);
    }

    var i: usize = 0;
    while (i < frags.len) {
        const end = @min(i + LEAF_CAP, frags.len);
        const leaf = try Node.createLeaf(allocator, frags[i..end]);
        errdefer leaf.release(allocator);
        try level.append(allocator, leaf);
        i = end;
    }

    while (level.items.len > 1) {
        var next_level: std.ArrayList(*Node) = .empty;
        errdefer {
            for (next_level.items) |n| n.release(allocator);
            next_level.deinit(allocator);
        }
        var j: usize = 0;
        while (j < level.items.len) {
            const end = @min(j + BRANCH_CAP, level.items.len);
            const br = try Node.createBranch(allocator, level.items[j..end]);
            level_consumed = end;
            errdefer br.release(allocator);
            try next_level.append(allocator, br);
            j = end;
        }
        level.deinit(allocator);
        level = next_level;
        level_consumed = 0;
    }
    return level.items[0];
}

fn ensureLeafCap(allocator: Allocator, node: *Node, needed: usize) Allocator.Error!void {
    if (needed <= node.data.leaf.len) return;
    const new_cap = leafCapFor(needed);
    const new_buf = try allocator.alloc(Fragment, new_cap);
    @memcpy(new_buf[0..node.len], node.data.leaf[0..node.len]);
    allocator.free(node.data.leaf);
    node.data.leaf = new_buf;
}

fn writeLeafAndSplit(allocator: Allocator, node: *Node, buf: []const Fragment) Allocator.Error!?*Node {
    if (buf.len <= LEAF_CAP) {
        try ensureLeafCap(allocator, node, buf.len);
        for (buf, 0..) |f, i| node.data.leaf[i] = f;
        node.len = @intCast(buf.len);
        node.recomputeLeaf();
        return null;
    }
    const mid = buf.len / 2;
    try ensureLeafCap(allocator, node, mid);
    const right = try Node.createLeaf(allocator, buf[mid..]);
    for (buf[0..mid], 0..) |f, i| node.data.leaf[i] = f;
    node.len = @intCast(mid);
    node.recomputeLeaf();
    return right;
}

fn insertChildInBranch(allocator: Allocator, node: *Node, at: usize, child: *Node) Allocator.Error!?*Node {
    var tmp: [BRANCH_CAP + 1]*Node = undefined;
    const old_len: usize = node.len;
    for (0..at) |i| tmp[i] = node.data.branch.children[i];
    tmp[at] = child;
    for (at..old_len) |i| tmp[i + 1] = node.data.branch.children[i];
    const new_len = old_len + 1;
    if (new_len <= BRANCH_CAP) {
        for (0..new_len) |i| node.data.branch.children[i] = tmp[i];
        node.len = @intCast(new_len);
        node.recomputeBranch();
        return null;
    }
    const mid = new_len / 2;
    const right = try Node.createBranch(allocator, tmp[mid..new_len]);
    for (0..mid) |i| node.data.branch.children[i] = tmp[i];
    node.len = @intCast(mid);
    node.recomputeBranch();
    return right;
}

fn nodeInsertFast(
    allocator: Allocator,
    node_slot: **Node,
    pos: u64,
    frag: Fragment,
    resolver: ?ContentResolver,
) Allocator.Error!?*Node {
    node_slot.* = try node_slot.*.makeUnique(allocator);
    const node = node_slot.*;
    switch (node.kind) {
        .leaf => {
            var tmp: [LEAF_CAP + 2]Fragment = undefined;
            var out_len: usize = 0;
            var acc: u64 = 0;
            var placed = false;
            var split_old: ?Fragment = null;
            var new_left: ?Fragment = null;
            var new_right: ?Fragment = null;
            errdefer {
                if (new_left) |*l| l.deinit(allocator);
                if (new_right) |*r| r.deinit(allocator);
            }

            for (0..node.len) |i| {
                const cur = node.data.leaf[i];
                const w: u64 = if (cur.isVisible()) cur.len else 0;
                if (!placed) {
                    if (w == 0) {
                        if (acc < pos) {
                            tmp[out_len] = cur;
                            out_len += 1;
                            continue;
                        }
                        if (out_len > 0 and tmp[out_len - 1].mergeableWith(&frag)) {
                            tmp[out_len - 1].appendMerged(&frag);
                        } else {
                            tmp[out_len] = frag;
                            out_len += 1;
                        }
                        placed = true;
                        tmp[out_len] = cur;
                        out_len += 1;
                        continue;
                    }
                    if (acc + w < pos) {
                        tmp[out_len] = cur;
                        out_len += 1;
                        acc += w;
                        continue;
                    }
                    if (acc == pos) {
                        if (out_len > 0 and tmp[out_len - 1].mergeableWith(&frag)) {
                            tmp[out_len - 1].appendMerged(&frag);
                        } else {
                            tmp[out_len] = frag;
                            out_len += 1;
                        }
                        placed = true;
                        tmp[out_len] = cur;
                        out_len += 1;
                        acc += w;
                        continue;
                    }
                    if (acc + w == pos) {
                        tmp[out_len] = cur;
                        out_len += 1;
                        acc += w;
                        if (tmp[out_len - 1].mergeableWith(&frag)) {
                            tmp[out_len - 1].appendMerged(&frag);
                        } else {
                            tmp[out_len] = frag;
                            out_len += 1;
                        }
                        placed = true;
                        continue;
                    }
                    const cut = pos - acc;
                    const pair = try cur.split(allocator, cut, resolver);
                    split_old = cur;
                    new_left = pair[0];
                    new_right = pair[1];
                    tmp[out_len] = pair[0];
                    out_len += 1;
                    tmp[out_len] = frag;
                    out_len += 1;
                    tmp[out_len] = pair[1];
                    out_len += 1;
                    placed = true;
                    acc += w;
                } else {
                    tmp[out_len] = cur;
                    out_len += 1;
                }
            }
            if (!placed) {
                if (out_len > 0 and tmp[out_len - 1].mergeableWith(&frag)) {
                    tmp[out_len - 1].appendMerged(&frag);
                } else {
                    tmp[out_len] = frag;
                    out_len += 1;
                }
            }
            const right_node = try writeLeafAndSplit(allocator, node, tmp[0..out_len]);
            new_left = null;
            new_right = null;
            if (split_old) |*o| o.deinit(allocator);
            return right_node;
        },
        .branch => {
            var acc: u64 = 0;
            var target_idx: usize = node.len - 1;
            var local_pos: u64 = pos;
            for (0..node.len) |i| {
                const w = node.data.branch.summaries[i].visible;
                if (pos <= acc + w or i + 1 == node.len) {
                    target_idx = i;
                    local_pos = pos - acc;
                    break;
                }
                acc += w;
            }
            const split_right = try nodeInsertFast(allocator, &node.data.branch.children[target_idx], local_pos, frag, resolver);
            if (split_right) |r| {
                errdefer r.release(allocator);
                return try insertChildInBranch(allocator, node, target_idx + 1, r);
            }
            node.recomputeBranch();
            return null;
        },
    }
}

fn nodeDeleteFast(
    allocator: Allocator,
    node_slot: **Node,
    pos: u64,
    rem: *u64,
    op: id.OpId,
    resolver: ?ContentResolver,
) Allocator.Error!?*Node {
    if (rem.* == 0) return null;
    node_slot.* = try node_slot.*.makeUnique(allocator);
    const node = node_slot.*;
    switch (node.kind) {
        .leaf => {
            var tmp: [LEAF_CAP + 2]Fragment = undefined;
            var owned_new: [LEAF_CAP + 2]bool = @splat(false);
            var out_len: usize = 0;
            var deferred_free: [2]Fragment = undefined;
            var deferred_free_len: usize = 0;
            errdefer {
                for (0..out_len) |k| {
                    if (owned_new[k]) tmp[k].deinit(allocator);
                }
                node.recomputeLeaf();
            }
            var acc: u64 = 0;
            for (0..node.len) |i| {
                const orig = node.data.leaf[i];
                const w: u64 = if (orig.isVisible()) orig.len else 0;
                if (w == 0 or rem.* == 0 or acc + w <= pos) {
                    tmp[out_len] = orig;
                    owned_new[out_len] = false;
                    out_len += 1;
                    acc += w;
                    continue;
                }
                if (acc < pos) {
                    const pre = pos - acc;
                    const p1 = try orig.split(allocator, pre, resolver);
                    var left_part = p1[0];
                    errdefer left_part.deinit(allocator);
                    var right_part = p1[1];
                    errdefer right_part.deinit(allocator);
                    const avail = right_part.len;
                    if (avail <= rem.*) {
                        try right_part.markDeleted(allocator, op);
                        deferred_free[deferred_free_len] = orig;
                        deferred_free_len += 1;
                        tmp[out_len] = left_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = right_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        acc += pre + avail;
                        rem.* -= avail;
                    } else {
                        const p2 = try right_part.split(allocator, rem.*, resolver);
                        var mid_part = p2[0];
                        errdefer mid_part.deinit(allocator);
                        var tail_part = p2[1];
                        errdefer tail_part.deinit(allocator);
                        try mid_part.markDeleted(allocator, op);
                        right_part.deinit(allocator);
                        deferred_free[deferred_free_len] = orig;
                        deferred_free_len += 1;
                        tmp[out_len] = left_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = mid_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = tail_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        acc += pre + avail;
                        rem.* = 0;
                    }
                } else {
                    const avail = orig.len;
                    if (avail <= rem.*) {
                        try node.data.leaf[i].markDeleted(allocator, op);
                        tmp[out_len] = node.data.leaf[i];
                        owned_new[out_len] = false;
                        out_len += 1;
                        acc += avail;
                        rem.* -= avail;
                    } else {
                        const p2 = try orig.split(allocator, rem.*, resolver);
                        var mid_part = p2[0];
                        errdefer mid_part.deinit(allocator);
                        var tail_part = p2[1];
                        errdefer tail_part.deinit(allocator);
                        try mid_part.markDeleted(allocator, op);
                        deferred_free[deferred_free_len] = orig;
                        deferred_free_len += 1;
                        tmp[out_len] = mid_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = tail_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        acc += avail;
                        rem.* = 0;
                    }
                }
            }
            const right_node = try writeLeafAndSplit(allocator, node, tmp[0..out_len]);
            for (deferred_free[0..deferred_free_len]) |*old_f| old_f.deinit(allocator);
            return right_node;
        },
        .branch => {
            var acc: u64 = 0;
            var i: usize = 0;
            var extra_splits: [BRANCH_CAP * 2]*Node = undefined;
            var new_count: usize = 0;
            var extra_only: [BRANCH_CAP]*Node = undefined;
            var extra_only_len: usize = 0;
            errdefer {
                for (extra_only[0..extra_only_len]) |r| r.release(allocator);
                node.recomputeBranch();
            }
            while (i < node.len) : (i += 1) {
                const w = node.data.branch.summaries[i].visible;
                if (rem.* > 0 and w > 0 and acc + w > pos) {
                    const local_pos = if (pos > acc) pos - acc else 0;
                    const split_r = try nodeDeleteFast(allocator, &node.data.branch.children[i], local_pos, rem, op, resolver);
                    extra_splits[new_count] = node.data.branch.children[i];
                    new_count += 1;
                    if (split_r) |r| {
                        extra_splits[new_count] = r;
                        new_count += 1;
                        extra_only[extra_only_len] = r;
                        extra_only_len += 1;
                    }
                } else {
                    extra_splits[new_count] = node.data.branch.children[i];
                    new_count += 1;
                }
                acc += w;
            }
            if (new_count <= BRANCH_CAP) {
                for (0..new_count) |k| node.data.branch.children[k] = extra_splits[k];
                node.len = @intCast(new_count);
                node.recomputeBranch();
                return null;
            }
            const mid = new_count / 2;
            const right = try Node.createBranch(allocator, extra_splits[mid..new_count]);
            for (0..mid) |k| node.data.branch.children[k] = extra_splits[k];
            node.len = @intCast(mid);
            node.recomputeBranch();
            return right;
        },
    }
}

fn nodeInsertInView(
    allocator: Allocator,
    node_slot: **Node,
    pos: u64,
    frag: Fragment,
    op: id.OpId,
    view: View,
    acc: *u64,
    placed: *bool,
    is_rightmost: bool,
    resolver: ?ContentResolver,
) Allocator.Error!?*Node {
    if (placed.*) return null;
    const peek = node_slot.*;
    switch (peek.kind) {
        .leaf => {
            const leaf_w = peek.widthIn(view);
            if (!is_rightmost and acc.* + leaf_w < pos) {
                acc.* += leaf_w;
                return null;
            }

            var scan_acc = acc.*;
            var will_place = is_rightmost;
            if (!will_place) {
                for (peek.data.leaf[0..peek.len]) |*f| {
                    const fw = f.widthIn(view);
                    if (scan_acc < pos) {
                        if (fw == 0) continue;
                        if (scan_acc + fw <= pos) {
                            scan_acc += fw;
                            continue;
                        }
                        will_place = true;
                        break;
                    } else {
                        const skip = fw == 0 and !view.observes(f.ins) and (f.ins.greaterThan(op) or (f.ins.eql(op) and f.off < frag.off));
                        if (!skip) {
                            will_place = true;
                            break;
                        }
                    }
                }
            }
            if (!will_place) {
                acc.* = scan_acc;
                return null;
            }

            node_slot.* = try node_slot.*.makeUnique(allocator);
            const node = node_slot.*;
            var tmp: [LEAF_CAP + 2]Fragment = undefined;
            var out_len: usize = 0;
            var split_old: ?Fragment = null;
            var new_left: ?Fragment = null;
            var new_right: ?Fragment = null;
            errdefer {
                if (new_left) |*l| l.deinit(allocator);
                if (new_right) |*r| r.deinit(allocator);
            }

            for (0..node.len) |i| {
                const cur = node.data.leaf[i];
                if (placed.*) {
                    tmp[out_len] = cur;
                    out_len += 1;
                    continue;
                }
                const fw = cur.widthIn(view);
                if (acc.* < pos) {
                    if (fw == 0) {
                        tmp[out_len] = cur;
                        out_len += 1;
                        continue;
                    }
                    if (acc.* + fw <= pos) {
                        tmp[out_len] = cur;
                        out_len += 1;
                        acc.* += fw;
                        continue;
                    }
                    const cut = pos - acc.*;
                    const pair = try cur.split(allocator, cut, resolver);
                    split_old = cur;
                    new_left = pair[0];
                    new_right = pair[1];
                    tmp[out_len] = pair[0];
                    out_len += 1;
                    tmp[out_len] = frag;
                    out_len += 1;
                    tmp[out_len] = pair[1];
                    out_len += 1;
                    placed.* = true;
                    acc.* += fw;
                } else {
                    const skip = fw == 0 and !view.observes(cur.ins) and (cur.ins.greaterThan(op) or (cur.ins.eql(op) and cur.off < frag.off));
                    if (skip) {
                        tmp[out_len] = cur;
                        out_len += 1;
                        continue;
                    }
                    if (out_len > 0 and tmp[out_len - 1].mergeableWith(&frag)) {
                        tmp[out_len - 1].appendMerged(&frag);
                    } else {
                        tmp[out_len] = frag;
                        out_len += 1;
                    }
                    placed.* = true;
                    tmp[out_len] = cur;
                    out_len += 1;
                    acc.* += fw;
                }
            }
            if (!placed.* and is_rightmost) {
                if (out_len > 0 and tmp[out_len - 1].mergeableWith(&frag)) {
                    tmp[out_len - 1].appendMerged(&frag);
                } else {
                    tmp[out_len] = frag;
                    out_len += 1;
                }
                placed.* = true;
            }
            const right_node = try writeLeafAndSplit(allocator, node, tmp[0..out_len]);
            new_left = null;
            new_right = null;
            if (split_old) |*o| o.deinit(allocator);
            return right_node;
        },
        .branch => {
            var made_unique = false;
            var i: usize = 0;
            while (i < node_slot.*.len) : (i += 1) {
                if (placed.*) break;
                const cur_node = node_slot.*;
                const child_is_last = is_rightmost and (i + 1 == cur_node.len);
                const s = cur_node.data.branch.summaries[i];
                const cw = if (s.max_ts < view.min_unobserved) s.visible else cur_node.data.branch.children[i].widthIn(view);
                if (!child_is_last and acc.* + cw < pos) {
                    acc.* += cw;
                    continue;
                }
                if (!made_unique) {
                    node_slot.* = try node_slot.*.makeUnique(allocator);
                    made_unique = true;
                }
                const node = node_slot.*;
                const split_right = try nodeInsertInView(
                    allocator,
                    &node.data.branch.children[i],
                    pos,
                    frag,
                    op,
                    view,
                    acc,
                    placed,
                    child_is_last,
                    resolver,
                );
                if (split_right) |r| {
                    errdefer r.release(allocator);
                    return try insertChildInBranch(allocator, node, i + 1, r);
                }
                if (placed.*) {
                    node.recomputeBranch();
                    return null;
                }
            }
            if (made_unique) node_slot.*.recomputeBranch();
            return null;
        },
    }
}

fn nodeDeleteInView(
    allocator: Allocator,
    node_slot: **Node,
    pos: u64,
    rem: *u64,
    op: id.OpId,
    view: View,
    acc: *u64,
    resolver: ?ContentResolver,
) Allocator.Error!?*Node {
    if (rem.* == 0) return null;
    const peek = node_slot.*;
    switch (peek.kind) {
        .leaf => {
            const leaf_w = peek.widthIn(view);
            if (leaf_w == 0 or acc.* + leaf_w <= pos) {
                acc.* += leaf_w;
                return null;
            }
            node_slot.* = try node_slot.*.makeUnique(allocator);
            const node = node_slot.*;
            var tmp: [LEAF_CAP + 2]Fragment = undefined;
            var owned_new: [LEAF_CAP + 2]bool = @splat(false);
            var out_len: usize = 0;
            var deferred_free: [2]Fragment = undefined;
            var deferred_free_len: usize = 0;
            errdefer {
                for (0..out_len) |k| {
                    if (owned_new[k]) tmp[k].deinit(allocator);
                }
                node.recomputeLeaf();
            }
            for (0..node.len) |i| {
                const orig = node.data.leaf[i];
                const w = orig.widthIn(view);
                if (w == 0 or rem.* == 0 or acc.* + w <= pos) {
                    tmp[out_len] = orig;
                    owned_new[out_len] = false;
                    out_len += 1;
                    acc.* += w;
                    continue;
                }
                if (acc.* < pos) {
                    const pre = pos - acc.*;
                    const p1 = try orig.split(allocator, pre, resolver);
                    var left_part = p1[0];
                    errdefer left_part.deinit(allocator);
                    var right_part = p1[1];
                    errdefer right_part.deinit(allocator);
                    const avail = right_part.len;
                    if (avail <= rem.*) {
                        try right_part.markDeleted(allocator, op);
                        deferred_free[deferred_free_len] = orig;
                        deferred_free_len += 1;
                        tmp[out_len] = left_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = right_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        acc.* += pre + avail;
                        rem.* -= avail;
                    } else {
                        const p2 = try right_part.split(allocator, rem.*, resolver);
                        var mid_part = p2[0];
                        errdefer mid_part.deinit(allocator);
                        var tail_part = p2[1];
                        errdefer tail_part.deinit(allocator);
                        try mid_part.markDeleted(allocator, op);
                        right_part.deinit(allocator);
                        deferred_free[deferred_free_len] = orig;
                        deferred_free_len += 1;
                        tmp[out_len] = left_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = mid_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = tail_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        acc.* += pre + avail;
                        rem.* = 0;
                    }
                } else {
                    const avail = orig.len;
                    if (avail <= rem.*) {
                        try node.data.leaf[i].markDeleted(allocator, op);
                        tmp[out_len] = node.data.leaf[i];
                        owned_new[out_len] = false;
                        out_len += 1;
                        acc.* += avail;
                        rem.* -= avail;
                    } else {
                        const p2 = try orig.split(allocator, rem.*, resolver);
                        var mid_part = p2[0];
                        errdefer mid_part.deinit(allocator);
                        var tail_part = p2[1];
                        errdefer tail_part.deinit(allocator);
                        try mid_part.markDeleted(allocator, op);
                        deferred_free[deferred_free_len] = orig;
                        deferred_free_len += 1;
                        tmp[out_len] = mid_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        tmp[out_len] = tail_part;
                        owned_new[out_len] = true;
                        out_len += 1;
                        acc.* += avail;
                        rem.* = 0;
                    }
                }
            }
            const right_node = try writeLeafAndSplit(allocator, node, tmp[0..out_len]);
            for (deferred_free[0..deferred_free_len]) |*old_f| old_f.deinit(allocator);
            return right_node;
        },
        .branch => {
            var made_unique = false;
            var extra_splits: [BRANCH_CAP * 2]*Node = undefined;
            var new_count: usize = 0;
            var extra_only: [BRANCH_CAP]*Node = undefined;
            var extra_only_len: usize = 0;
            errdefer {
                for (extra_only[0..extra_only_len]) |r| r.release(allocator);
                if (made_unique) node_slot.*.recomputeBranch();
            }
            var i: usize = 0;
            while (i < node_slot.*.len) : (i += 1) {
                const cur_node = node_slot.*;
                const s = cur_node.data.branch.summaries[i];
                const cw = if (s.max_ts < view.min_unobserved) s.visible else cur_node.data.branch.children[i].widthIn(view);
                if (rem.* > 0 and cw > 0 and acc.* + cw > pos) {
                    if (!made_unique) {
                        node_slot.* = try node_slot.*.makeUnique(allocator);
                        made_unique = true;
                        for (0..i) |k| {
                            extra_splits[k] = node_slot.*.data.branch.children[k];
                        }
                    }
                    const node = node_slot.*;
                    const split_r = try nodeDeleteInView(allocator, &node.data.branch.children[i], pos, rem, op, view, acc, resolver);
                    extra_splits[new_count] = node.data.branch.children[i];
                    new_count += 1;
                    if (split_r) |r| {
                        extra_splits[new_count] = r;
                        new_count += 1;
                        extra_only[extra_only_len] = r;
                        extra_only_len += 1;
                    }
                } else {
                    if (made_unique) {
                        extra_splits[new_count] = node_slot.*.data.branch.children[i];
                    } else {
                        extra_splits[new_count] = cur_node.data.branch.children[i];
                    }
                    new_count += 1;
                    acc.* += cw;
                }
            }
            if (!made_unique) return null;
            const node = node_slot.*;
            if (new_count <= BRANCH_CAP) {
                for (0..new_count) |k| node.data.branch.children[k] = extra_splits[k];
                node.len = @intCast(new_count);
                node.recomputeBranch();
                return null;
            }
            const mid = new_count / 2;
            const right = try Node.createBranch(allocator, extra_splits[mid..new_count]);
            for (0..mid) |k| node.data.branch.children[k] = extra_splits[k];
            node.len = @intCast(mid);
            node.recomputeBranch();
            return right;
        },
    }
}

pub const TextError = error{
    Unordered,
    OutOfBounds,
    LengthMismatch,
    InvalidSplice,
};

pub const DiffError = error{
    MissingBlob,
};

pub const TextSplice = struct {
    at: u64,
    del: u64,
    text: []u8,

    pub fn deinit(self: *TextSplice, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

pub const ViewDiff = struct {
    splices: []TextSplice = &.{},
    lines_added: u32 = 0,
    lines_removed: u32 = 0,

    pub fn deinit(self: *ViewDiff, allocator: Allocator) void {
        for (self.splices) |*s| s.deinit(allocator);
        if (self.splices.len > 0) allocator.free(self.splices);
        self.splices = &.{};
    }
};

pub fn mapCursor(pos: u64, splices: []const TextSplice) u64 {
    var delta: i64 = 0;
    for (splices) |s| {
        if (pos < s.at) break;
        if (pos == s.at) {
            if (s.del == 0 and s.text.len > 0 and s.text[s.text.len - 1] == '\n') {
                delta += @as(i64, @intCast(s.text.len));
            }
            break;
        }
        if (pos < s.at + s.del) {
            return @intCast(@as(i64, @intCast(s.at)) + delta + @as(i64, @intCast(s.text.len)));
        }
        delta += @as(i64, @intCast(s.text.len)) - @as(i64, @intCast(s.del));
    }
    const mapped = @as(i64, @intCast(pos)) + delta;
    return if (mapped < 0) 0 else @intCast(mapped);
}

const PendingSplice = struct {
    at: u64,
    del: u64,
    del_nl: u32,
    ins_nl: u32,
    text: std.ArrayList(u8),
};

pub const Text = struct {
    root: ?*Node = null,

    pub fn deinit(self: *Text, allocator: Allocator) void {
        if (self.root) |r| {
            r.release(allocator);
            self.root = null;
        }
    }

    pub fn share(self: *const Text) Text {
        return .{ .root = if (self.root) |r| r.retain() else null };
    }

    pub fn clone(self: *const Text, _: Allocator) Allocator.Error!Text {
        return self.share();
    }

    pub fn fromInsertion(allocator: Allocator, ins: id.OpId, part: u32, off: u64, len: u64, bytes_opt: ?[]const u8) Allocator.Error!Text {
        if (len == 0) return .{};
        var nl: u32 = 0;
        var ends_nl = false;
        var known = false;
        if (bytes_opt) |bytes| {
            const s: usize = @intCast(off);
            const e: usize = @intCast(off + len);
            if (e <= bytes.len) {
                const sl = bytes[s..e];
                nl = countNewlinesSlice(sl);
                ends_nl = sl.len > 0 and sl[sl.len - 1] == '\n';
                known = true;
            }
        }
        var arr = [_]Fragment{.{
            .ins = ins,
            .part = part,
            .newlines = nl,
            .off = off,
            .len = len,
            .ends_with_nl = ends_nl,
            .newlines_known = known,
        }};
        return .{ .root = try buildTree(allocator, &arr) };
    }

    pub fn visibleLen(self: *const Text) u64 {
        const r = self.root orelse return 0;
        return r.summary.visible;
    }

    pub fn lineCount(self: *const Text) usize {
        const r = self.root orelse return 0;
        if (r.summary.visible == 0) return 0;
        const nl: usize = @intCast(r.summary.visible_newlines);
        return if (r.summary.ends_with_nl) nl else nl + 1;
    }

    pub fn countLines(self: *const Text, resolver: ContentResolver) usize {
        const r = self.root orelse return 0;
        if (r.summary.visible == 0) return 0;
        if (!r.summary.unknown_newlines) return self.lineCount();
        var nl: usize = 0;
        var last_nl = false;
        countLinesNode(r, resolver, &nl, &last_nl);
        return if (last_nl) nl else nl + 1;
    }

    fn countLinesNode(node: *const Node, resolver: ContentResolver, nl: *usize, last_nl: *bool) void {
        if (node.summary.visible == 0) return;
        if (!node.summary.unknown_newlines) {
            nl.* += @intCast(node.summary.visible_newlines);
            last_nl.* = node.summary.ends_with_nl;
            return;
        }
        switch (node.kind) {
            .leaf => {
                for (node.data.leaf[0..node.len]) |*f| {
                    if (!f.isVisible() or f.len == 0) continue;
                    if (f.newlines_known) {
                        nl.* += f.newlines;
                        last_nl.* = f.ends_with_nl;
                    } else if (resolver.resolve(f.key())) |bytes| {
                        const st: usize = @intCast(f.off);
                        const en: usize = @intCast(f.off + f.len);
                        if (en <= bytes.len) {
                            const sl = bytes[st..en];
                            nl.* += countNewlinesSlice(sl);
                            last_nl.* = sl.len > 0 and sl[sl.len - 1] == '\n';
                        }
                    }
                }
            },
            .branch => {
                for (node.data.branch.children[0..node.len]) |c| {
                    countLinesNode(c, resolver, nl, last_nl);
                }
            },
        }
    }

    pub fn lenIn(self: *const Text, view: View) u64 {
        const r = self.root orelse return 0;
        return r.widthIn(view);
    }

    pub fn fragmentCount(self: *const Text) usize {
        const r = self.root orelse return 0;
        return r.item_count;
    }

    pub fn read(self: *const Text, allocator: Allocator, resolver: ContentResolver) Allocator.Error!?[]u8 {
        return self.readIn(allocator, resolver, View.EVERYTHING);
    }

    pub fn readIn(self: *const Text, allocator: Allocator, resolver: ContentResolver, view: View) Allocator.Error!?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const r = self.root orelse return try out.toOwnedSlice(allocator);
        if (view.min_unobserved == std.math.maxInt(u64) and r.summary.visible > 0) {
            try out.ensureTotalCapacity(allocator, @intCast(r.summary.visible));
        }
        if (!try appendNodeBytes(allocator, r, resolver, view, &out)) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn readByteRange(
        self: *const Text,
        allocator: Allocator,
        resolver: ContentResolver,
        start_byte: u64,
        max_bytes: u64,
    ) Allocator.Error!?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const r = self.root orelse return try out.toOwnedSlice(allocator);
        if (max_bytes == 0 or start_byte >= r.summary.visible) return try out.toOwnedSlice(allocator);
        const actual = @min(max_bytes, r.summary.visible - start_byte);
        try out.ensureTotalCapacity(allocator, @intCast(actual));
        var pos: u64 = 0;
        var rem: u64 = actual;
        if (!try appendByteRangeNode(allocator, r, resolver, start_byte, &pos, &rem, &out)) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    fn appendByteRangeNode(
        allocator: Allocator,
        node: *const Node,
        resolver: ContentResolver,
        start_byte: u64,
        pos: *u64,
        rem: *u64,
        out: *std.ArrayList(u8),
    ) Allocator.Error!bool {
        if (rem.* == 0 or node.summary.visible == 0) return true;
        if (pos.* + node.summary.visible <= start_byte) {
            pos.* += node.summary.visible;
            return true;
        }
        switch (node.kind) {
            .leaf => {
                for (node.data.leaf[0..node.len]) |*f| {
                    if (rem.* == 0) break;
                    if (!f.isVisible() or f.len == 0) continue;
                    if (pos.* + f.len <= start_byte) {
                        pos.* += f.len;
                        continue;
                    }
                    const bytes = resolver.resolve(f.key()) orelse return false;
                    const skip = if (start_byte > pos.*) start_byte - pos.* else 0;
                    const take = @min(f.len - skip, rem.*);
                    const s: usize = @intCast(f.off + skip);
                    const e: usize = @intCast(f.off + skip + take);
                    if (e > bytes.len) return false;
                    try out.appendSlice(allocator, bytes[s..e]);
                    pos.* += f.len;
                    rem.* -= take;
                }
            },
            .branch => {
                for (node.data.branch.children[0..node.len]) |c| {
                    if (rem.* == 0) break;
                    if (!try appendByteRangeNode(allocator, c, resolver, start_byte, pos, rem, out)) return false;
                }
            },
        }
        return true;
    }

    pub fn readLineRange(
        self: *const Text,
        allocator: Allocator,
        resolver: ContentResolver,
        start_line: usize,
        max_lines: usize,
    ) Allocator.Error!?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const r = self.root orelse return try out.toOwnedSlice(allocator);
        if (max_lines == 0 or r.summary.visible == 0) return try out.toOwnedSlice(allocator);
        var cur_line: usize = 0;
        var emitted_lines: usize = 0;
        var done = false;
        if (!try appendLineRangeNode(allocator, r, resolver, start_line, max_lines, &cur_line, &emitted_lines, &done, &out)) {
            out.deinit(allocator);
            return null;
        }
        return try out.toOwnedSlice(allocator);
    }

    fn appendLineRangeNode(
        allocator: Allocator,
        node: *const Node,
        resolver: ContentResolver,
        start_line: usize,
        max_lines: usize,
        cur_line: *usize,
        emitted_lines: *usize,
        done: *bool,
        out: *std.ArrayList(u8),
    ) Allocator.Error!bool {
        if (done.* or node.summary.visible == 0) return true;
        if (!node.summary.unknown_newlines) {
            const sub_nl: usize = @intCast(node.summary.visible_newlines);
            if (cur_line.* + sub_nl < start_line) {
                cur_line.* += sub_nl;
                return true;
            }
        }
        switch (node.kind) {
            .leaf => {
                for (node.data.leaf[0..node.len]) |*f| {
                    if (done.*) break;
                    if (!f.isVisible() or f.len == 0) continue;
                    if (f.newlines_known) {
                        const fnl: usize = f.newlines;
                        if (cur_line.* + fnl < start_line) {
                            cur_line.* += fnl;
                            continue;
                        }
                    }
                    const bytes = resolver.resolve(f.key()) orelse return false;
                    const s: usize = @intCast(f.off);
                    const e: usize = @intCast(f.off + f.len);
                    if (e > bytes.len) return false;
                    const sl = bytes[s..e];
                    var start_idx: usize = 0;
                    if (cur_line.* < start_line) {
                        var idx: usize = 0;
                        while (idx < sl.len and cur_line.* < start_line) : (idx += 1) {
                            if (sl[idx] == '\n') cur_line.* += 1;
                        }
                        if (cur_line.* < start_line) continue;
                        start_idx = idx;
                    }
                    var end_idx: usize = start_idx;
                    while (end_idx < sl.len) : (end_idx += 1) {
                        if (sl[end_idx] == '\n') {
                            cur_line.* += 1;
                            emitted_lines.* += 1;
                            if (emitted_lines.* >= max_lines) {
                                end_idx += 1;
                                done.* = true;
                                break;
                            }
                        }
                    }
                    if (end_idx > start_idx) {
                        try out.appendSlice(allocator, sl[start_idx..end_idx]);
                    }
                }
            },
            .branch => {
                for (node.data.branch.children[0..node.len]) |c| {
                    if (done.*) break;
                    if (!try appendLineRangeNode(allocator, c, resolver, start_line, max_lines, cur_line, emitted_lines, done, out)) return false;
                }
            },
        }
        return true;
    }

    fn appendNodeBytes(
        allocator: Allocator,
        node: *const Node,
        resolver: ContentResolver,
        view: View,
        out: *std.ArrayList(u8),
    ) Allocator.Error!bool {
        if (node.summary.max_ts < view.min_unobserved and node.summary.visible == 0) return true;
        switch (node.kind) {
            .leaf => {
                for (node.data.leaf[0..node.len]) |*f| {
                    if (f.widthIn(view) == 0) continue;
                    const bytes = resolver.resolve(f.key()) orelse return false;
                    const start: usize = @intCast(f.off);
                    const end: usize = @intCast(f.off + f.len);
                    if (end > bytes.len) return false;
                    try out.appendSlice(allocator, bytes[start..end]);
                }
            },
            .branch => {
                for (node.data.branch.children[0..node.len]) |c| {
                    if (!try appendNodeBytes(allocator, c, resolver, view, out)) return false;
                }
            },
        }
        return true;
    }

    pub fn collectVisibleSpans(self: *const Text, allocator: Allocator, view: View) Allocator.Error!std.ArrayList(Fragment) {
        var out: std.ArrayList(Fragment) = .empty;
        errdefer {
            for (out.items) |*f| f.deinit(allocator);
            out.deinit(allocator);
        }
        if (self.root) |r| {
            try collectVisibleNode(allocator, r, view, &out);
        }
        return out;
    }

    fn collectVisibleNode(
        allocator: Allocator,
        node: *const Node,
        view: View,
        out: *std.ArrayList(Fragment),
    ) Allocator.Error!void {
        if (node.summary.max_ts < view.min_unobserved and node.summary.visible == 0) return;
        switch (node.kind) {
            .leaf => {
                for (node.data.leaf[0..node.len]) |*f| {
                    if (f.widthIn(view) > 0) {
                        try out.append(allocator, try f.clone(allocator));
                    }
                }
            },
            .branch => {
                for (node.data.branch.children[0..node.len]) |c| {
                    try collectVisibleNode(allocator, c, view, out);
                }
            },
        }
    }

    pub fn diffViews(
        self: *const Text,
        allocator: Allocator,
        resolver: ContentResolver,
        from_view: View,
        to_view: View,
    ) (DiffError || Allocator.Error)!ViewDiff {
        const r = self.root orelse return .{};
        var pending: std.ArrayList(PendingSplice) = .empty;
        defer {
            for (pending.items) |*p| p.text.deinit(allocator);
            pending.deinit(allocator);
        }
        var from_pos: u64 = 0;
        const cutoff = @min(from_view.min_unobserved, to_view.min_unobserved);
        try diffViewsNode(allocator, r, resolver, from_view, to_view, cutoff, &from_pos, &pending);
        if (pending.items.len == 0) return .{};

        var out = try allocator.alloc(TextSplice, pending.items.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*s| s.deinit(allocator);
            allocator.free(out);
        }
        var lines_added: u32 = 0;
        var lines_removed: u32 = 0;
        for (pending.items, 0..) |*p, i| {
            const ins_len = p.text.items.len;
            if (ins_len > 0) {
                lines_added +|= if (p.ins_nl > 0) p.ins_nl else 1;
            }
            if (p.del > 0) {
                lines_removed +|= if (p.del_nl > 0) p.del_nl else 1;
            }
            out[i] = .{
                .at = p.at,
                .del = p.del,
                .text = try p.text.toOwnedSlice(allocator),
            };
            built += 1;
        }
        return .{
            .splices = out,
            .lines_added = lines_added,
            .lines_removed = lines_removed,
        };
    }

    fn diffViewsNode(
        allocator: Allocator,
        node: *const Node,
        resolver: ContentResolver,
        from_view: View,
        to_view: View,
        cutoff: u64,
        from_pos: *u64,
        pending: *std.ArrayList(PendingSplice),
    ) (DiffError || Allocator.Error)!void {
        if (node.summary.max_ts < cutoff) {
            from_pos.* += node.summary.visible;
            return;
        }
        switch (node.kind) {
            .leaf => {
                for (node.data.leaf[0..node.len]) |*f| {
                    const in_from = f.widthIn(from_view) > 0;
                    const in_to = f.widthIn(to_view) > 0;
                    if (in_from and in_to) {
                        from_pos.* += f.len;
                    } else if (in_from and !in_to) {
                        const del_nl: u32 = f.newlines;
                        if (pending.items.len > 0) {
                            const last = &pending.items[pending.items.len - 1];
                            if (last.at + last.del == from_pos.*) {
                                last.del += f.len;
                                last.del_nl +|= del_nl;
                                from_pos.* += f.len;
                                continue;
                            }
                        }
                        try pending.append(allocator, .{
                            .at = from_pos.*,
                            .del = f.len,
                            .del_nl = del_nl,
                            .ins_nl = 0,
                            .text = .empty,
                        });
                        from_pos.* += f.len;
                    } else if (!in_from and in_to) {
                        const bytes = resolver.resolve(f.key()) orelse return error.MissingBlob;
                        const s: usize = @intCast(f.off);
                        const e: usize = @intCast(f.off + f.len);
                        if (e > bytes.len) return error.MissingBlob;
                        const slice = bytes[s..e];
                        const ins_nl = if (f.newlines_known) f.newlines else countNewlinesSlice(slice);
                        if (pending.items.len > 0) {
                            const last = &pending.items[pending.items.len - 1];
                            if (last.at + last.del == from_pos.*) {
                                try last.text.appendSlice(allocator, slice);
                                last.ins_nl +|= ins_nl;
                                continue;
                            }
                        }
                        var txt: std.ArrayList(u8) = .empty;
                        errdefer txt.deinit(allocator);
                        try txt.appendSlice(allocator, slice);
                        try pending.append(allocator, .{
                            .at = from_pos.*,
                            .del = 0,
                            .del_nl = 0,
                            .ins_nl = ins_nl,
                            .text = txt,
                        });
                    }
                }
            },
            .branch => {
                for (node.data.branch.children[0..node.len]) |c| {
                    try diffViewsNode(allocator, c, resolver, from_view, to_view, cutoff, from_pos, pending);
                }
            },
        }
    }

    fn makeFragment(op: id.OpId, ins_off: u64, ins_len: u64, inserted_bytes: []const u8) Fragment {
        const s: usize = @intCast(ins_off);
        const e: usize = @intCast(ins_off + ins_len);
        const sl = if (e <= inserted_bytes.len) inserted_bytes[s..e] else "";
        return .{
            .ins = op,
            .part = 0,
            .newlines = countNewlinesSlice(sl),
            .off = ins_off,
            .len = ins_len,
            .ends_with_nl = sl.len > 0 and sl[sl.len - 1] == '\n',
        };
    }

    fn applyFast(
        self: *Text,
        allocator: Allocator,
        op: id.OpId,
        s: diff.Splice,
        inserted_bytes: []const u8,
        resolver: ?ContentResolver,
    ) Allocator.Error!void {
        if (s.ins > 0) {
            const frag = makeFragment(op, 0, s.ins, inserted_bytes);
            if (self.root != null) {
                if (try nodeInsertFast(allocator, &(self.root.?), s.at, frag, resolver)) |right| {
                    errdefer right.release(allocator);
                    const pair = [_]*Node{ self.root.?, right };
                    self.root = try Node.createBranch(allocator, &pair);
                }
            } else {
                const arr = [_]Fragment{frag};
                self.root = try Node.createLeaf(allocator, &arr);
            }
        }
        if (s.del > 0) {
            if (self.root != null) {
                var rem = s.del;
                if (try nodeDeleteFast(allocator, &(self.root.?), s.at + s.ins, &rem, op, resolver)) |right| {
                    errdefer right.release(allocator);
                    const pair = [_]*Node{ self.root.?, right };
                    self.root = try Node.createBranch(allocator, &pair);
                }
            }
        }
    }

    pub fn apply(
        self: *Text,
        allocator: Allocator,
        op: id.OpId,
        base_view: View,
        splices: []const diff.Splice,
        inserted_bytes: []const u8,
        resolver: ?ContentResolver,
    ) (TextError || Allocator.Error)!void {
        var floor: u64 = 0;
        var used_check: u64 = 0;
        for (splices) |s| {
            if (s.at < floor) return error.Unordered;
            floor = std.math.add(u64, s.at, s.del) catch return error.InvalidSplice;
            used_check = std.math.add(u64, used_check, s.ins) catch return error.InvalidSplice;
        }
        if (used_check != inserted_bytes.len) return error.LengthMismatch;
        if (splices.len == 0) return;

        const fast_eligible = splices.len == 1 and (if (self.root) |r| r.summary.max_ts < @min(base_view.min_unobserved, op.ts) else true);
        if (fast_eligible) {
            if (floor > self.visibleLen()) return error.OutOfBounds;
            try self.applyFast(allocator, op, splices[0], inserted_bytes, resolver);
            return;
        }

        const WithoutCtx = struct {
            base: View,
            op: id.OpId,
            fn observes(ptr: *const anyopaque, candidate: id.OpId) bool {
                const ctx: *const @This() = @ptrCast(@alignCast(ptr));
                if (candidate.eql(ctx.op)) return false;
                return ctx.base.observes(candidate);
            }
        };
        const wctx = WithoutCtx{ .base = base_view, .op = op };
        const view = View{
            .ptr = &wctx,
            .observesFn = WithoutCtx.observes,
            .min_unobserved = @min(base_view.min_unobserved, op.ts),
        };

        const parent_len = self.lenIn(view);
        if (floor > parent_len) return error.OutOfBounds;

        var ins_off: u64 = 0;
        for (splices) |s| {
            if (s.ins > 0) {
                const frag = makeFragment(op, ins_off, s.ins, inserted_bytes);
                if (self.root != null) {
                    var acc: u64 = 0;
                    var placed = false;
                    if (try nodeInsertInView(allocator, &(self.root.?), s.at, frag, op, view, &acc, &placed, true, resolver)) |right| {
                        errdefer right.release(allocator);
                        const pair = [_]*Node{ self.root.?, right };
                        self.root = try Node.createBranch(allocator, &pair);
                    }
                } else {
                    const arr = [_]Fragment{frag};
                    self.root = try Node.createLeaf(allocator, &arr);
                }
                ins_off += s.ins;
            }
            if (s.del > 0) {
                if (self.root != null) {
                    var rem = s.del;
                    var acc: u64 = 0;
                    if (try nodeDeleteInView(allocator, &(self.root.?), s.at, &rem, op, view, &acc, resolver)) |right| {
                        errdefer right.release(allocator);
                        const pair = [_]*Node{ self.root.?, right };
                        self.root = try Node.createBranch(allocator, &pair);
                    }
                }
            }
        }
    }
};
