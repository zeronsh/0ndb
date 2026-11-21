const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("../core/id.zig");
const version = @import("../core/version.zig");
const diff_mod = @import("../core/diff.zig");
const text_mod = @import("../core/text.zig");
const history_mod = @import("../core/history.zig");
const workspace = @import("workspace.zig");

pub const ChangeKind = enum {
    added,
    modified,
    deleted,
    renamed,
    binary,
};

pub const FileChange = struct {
    path: []u8,
    added_lines: u32,
    removed_lines: u32,
    kind: ChangeKind,

    pub fn deinit(self: *FileChange, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub const TimelineEntry = struct {
    batch_id: id.BatchId,
    actor: id.ActorId,
    wall_ms: u64,
    scope_id: ?u64,
    scope_label: ?[]u8,
    files: []FileChange,
    total_added: u32,
    total_removed: u32,

    pub fn deinit(self: *TimelineEntry, allocator: Allocator) void {
        if (self.scope_label) |lbl| allocator.free(lbl);
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
    }
};

pub fn freeTimelineEntries(allocator: Allocator, entries: []TimelineEntry) void {
    for (entries) |*e| e.deinit(allocator);
    allocator.free(entries);
}

pub const ForeignChange = struct {
    path: []u8,
    actor: id.ActorId,
    batch_id: id.BatchId,
    added_lines: u32,
    removed_lines: u32,

    pub fn deinit(self: *ForeignChange, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub fn freeForeignChanges(allocator: Allocator, changes: []ForeignChange) void {
    for (changes) |*c| c.deinit(allocator);
    allocator.free(changes);
}

const InodeContent = union(enum) {
    absent,
    text: []u8,
    binary: id.Oid,

    fn deinit(self: *InodeContent, allocator: Allocator) void {
        switch (self.*) {
            .text => |b| allocator.free(b),
            else => {},
        }
    }
};

const LineSpan = struct {
    start: usize,
    end: usize,
};

const LineChange = struct {
    ol_s: usize,
    ol_e: usize,
    nl_s: usize,
    nl_e: usize,
};

fn splitLineSpans(allocator: Allocator, bytes: []const u8) Allocator.Error![]LineSpan {
    var out: std.ArrayList(LineSpan) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b == '\n') {
            try out.append(allocator, .{ .start = start, .end = i + 1 });
            start = i + 1;
        }
    }
    if (start < bytes.len) {
        try out.append(allocator, .{ .start = start, .end = bytes.len });
    }
    return out.toOwnedSlice(allocator);
}

fn findLineAt(lines: []const LineSpan, byte_pos: usize) usize {
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid].end <= byte_pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn computeLineChanges(
    allocator: Allocator,
    before: []const u8,
    after: []const u8,
    old_lines: []const LineSpan,
    new_lines: []const LineSpan,
) Allocator.Error![]LineChange {
    if (std.mem.eql(u8, before, after)) {
        return try allocator.alloc(LineChange, 0);
    }

    var dr = try diff_mod.diffBytes(allocator, before, after);
    defer dr.deinit(allocator);

    if (dr.splices.items.len == 0) {
        return try allocator.alloc(LineChange, 0);
    }

    const ByteSplice = struct {
        old_s: usize,
        old_e: usize,
        new_s: usize,
        new_e: usize,
    };

    var bsplices = try allocator.alloc(ByteSplice, dr.splices.items.len);
    defer allocator.free(bsplices);

    var delta: isize = 0;
    for (dr.splices.items, 0..) |sp, idx| {
        const os: usize = @intCast(sp.at);
        const oe: usize = os + @as(usize, @intCast(sp.del));
        const ns: usize = @intCast(@as(isize, @intCast(os)) + delta);
        const ne: usize = ns + @as(usize, @intCast(sp.ins));
        bsplices[idx] = .{ .old_s = os, .old_e = oe, .new_s = ns, .new_e = ne };
        delta += @as(isize, @intCast(sp.ins)) - @as(isize, @intCast(sp.del));
    }

    var changes: std.ArrayList(LineChange) = .empty;
    errdefer changes.deinit(allocator);

    var si: usize = 0;
    while (si < bsplices.len) : (si += 1) {
        const old_s = bsplices[si].old_s;
        var old_e = bsplices[si].old_e;
        const new_s = bsplices[si].new_s;
        var new_e = bsplices[si].new_e;

        var ol_s: usize = if (old_lines.len == 0)
            0
        else if (old_s < old_e)
            findLineAt(old_lines, old_s)
        else if (old_s == 0 or before[old_s - 1] == '\n')
            findLineAt(old_lines, old_s)
        else
            findLineAt(old_lines, old_s - 1);

        var nl_s: usize = if (new_lines.len == 0)
            0
        else if (new_s < new_e)
            findLineAt(new_lines, new_s)
        else if (new_s == 0 or after[new_s - 1] == '\n')
            findLineAt(new_lines, new_s)
        else
            findLineAt(new_lines, new_s - 1);

        var old_start_byte: usize = if (ol_s < old_lines.len) old_lines[ol_s].start else before.len;
        var new_start_byte: usize = if (nl_s < new_lines.len) new_lines[nl_s].start else after.len;

        while ((old_s -| old_start_byte) != (new_s -| new_start_byte)) {
            if ((old_s -| old_start_byte) < (new_s -| new_start_byte) and ol_s > 0) {
                ol_s -= 1;
                old_start_byte = old_lines[ol_s].start;
            } else if ((new_s -| new_start_byte) < (old_s -| old_start_byte) and nl_s > 0) {
                nl_s -= 1;
                new_start_byte = new_lines[nl_s].start;
            } else {
                break;
            }
        }

        var ol_e: usize = ol_s;
        var nl_e: usize = nl_s;

        while (true) {
            ol_e = if (old_lines.len == 0)
                0
            else if (old_s < old_e)
                findLineAt(old_lines, old_e - 1) + 1
            else if (old_s == 0 or before[old_s - 1] == '\n')
                ol_s
            else
                @max(ol_s + 1, findLineAt(old_lines, old_s - 1) + 1);

            nl_e = if (new_lines.len == 0)
                0
            else if (new_s < new_e)
                findLineAt(new_lines, new_e - 1) + 1
            else if (new_s == 0 or after[new_s - 1] == '\n')
                nl_s
            else
                @max(nl_s + 1, findLineAt(new_lines, new_s - 1) + 1);

            var old_end_byte: usize = if (ol_e > ol_s) old_lines[ol_e - 1].end else old_s;
            var new_end_byte: usize = if (nl_e > nl_s) new_lines[nl_e - 1].end else new_s;

            while ((old_end_byte -| old_e) != (new_end_byte -| new_e)) {
                if ((old_end_byte -| old_e) < (new_end_byte -| new_e) and ol_e < old_lines.len) {
                    ol_e += 1;
                    old_end_byte = old_lines[ol_e - 1].end;
                } else if ((new_end_byte -| new_e) < (old_end_byte -| old_e) and nl_e < new_lines.len) {
                    nl_e += 1;
                    new_end_byte = new_lines[nl_e - 1].end;
                } else {
                    break;
                }
            }

            if (si + 1 < bsplices.len) {
                const nxt = bsplices[si + 1];
                const overlaps_old = nxt.old_s < old_end_byte or
                    (nxt.old_s == old_end_byte and nxt.old_s > 0 and before[nxt.old_s - 1] != '\n');
                const overlaps_new = nxt.new_s < new_end_byte or
                    (nxt.new_s == new_end_byte and nxt.new_s > 0 and after[nxt.new_s - 1] != '\n');
                if (overlaps_old or overlaps_new) {
                    si += 1;
                    old_e = nxt.old_e;
                    new_e = nxt.new_e;
                    continue;
                }
            }
            break;
        }

        while (ol_s < ol_e and nl_s < nl_e) {
            const os_span = old_lines[ol_s];
            const ns_span = new_lines[nl_s];
            if (std.mem.eql(u8, before[os_span.start..os_span.end], after[ns_span.start..ns_span.end])) {
                ol_s += 1;
                nl_s += 1;
            } else {
                break;
            }
        }

        while (ol_e > ol_s and nl_e > nl_s) {
            const oe_span = old_lines[ol_e - 1];
            const ne_span = new_lines[nl_e - 1];
            if (std.mem.eql(u8, before[oe_span.start..oe_span.end], after[ne_span.start..ne_span.end])) {
                ol_e -= 1;
                nl_e -= 1;
            } else {
                break;
            }
        }

        if (ol_s == ol_e and nl_s == nl_e) continue;

        if (changes.items.len > 0) {
            const prev = &changes.items[changes.items.len - 1];
            if (ol_s <= prev.ol_e or nl_s <= prev.nl_e) {
                prev.ol_s = @min(prev.ol_s, ol_s);
                prev.ol_e = @max(prev.ol_e, ol_e);
                prev.nl_s = @min(prev.nl_s, nl_s);
                prev.nl_e = @max(prev.nl_e, nl_e);
                continue;
            }
        }

        try changes.append(allocator, .{
            .ol_s = ol_s,
            .ol_e = ol_e,
            .nl_s = nl_s,
            .nl_e = nl_e,
        });
    }

    return changes.toOwnedSlice(allocator);
}

fn countLineStats(allocator: Allocator, before: []const u8, after: []const u8) Allocator.Error!struct { added: u32, removed: u32 } {
    if (std.mem.eql(u8, before, after)) return .{ .added = 0, .removed = 0 };
    const old_lines = try splitLineSpans(allocator, before);
    defer allocator.free(old_lines);
    const new_lines = try splitLineSpans(allocator, after);
    defer allocator.free(new_lines);
    const changes = try computeLineChanges(allocator, before, after, old_lines, new_lines);
    defer allocator.free(changes);
    var added: u32 = 0;
    var removed: u32 = 0;
    for (changes) |ch| {
        removed +|= @intCast(ch.ol_e - ch.ol_s);
        added +|= @intCast(ch.nl_e - ch.nl_s);
    }
    return .{ .added = added, .removed = removed };
}

fn emitDiffLine(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    prefix: u8,
    buf: []const u8,
    span: LineSpan,
) Allocator.Error!void {
    const raw = buf[span.start..span.end];
    const has_nl = raw.len > 0 and raw[raw.len - 1] == '\n';
    const body = if (has_nl) raw[0 .. raw.len - 1] else raw;
    try out.append(allocator, prefix);
    try out.appendSlice(allocator, body);
    try out.append(allocator, '\n');
    if (!has_nl) {
        try out.appendSlice(allocator, "\\ No newline at end of file\n");
    }
}

fn formatUnifiedDiffPaths(
    allocator: Allocator,
    old_path: []const u8,
    new_path: []const u8,
    before: []const u8,
    after: []const u8,
    context_lines: usize,
) Allocator.Error![]u8 {
    const old_lines = try splitLineSpans(allocator, before);
    defer allocator.free(old_lines);
    const new_lines = try splitLineSpans(allocator, after);
    defer allocator.free(new_lines);
    const changes = try computeLineChanges(allocator, before, after, old_lines, new_lines);
    defer allocator.free(changes);

    if (changes.len == 0 and std.mem.eql(u8, old_path, new_path)) {
        return try allocator.alloc(u8, 0);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "--- a/{s}\n+++ b/{s}\n", .{ old_path, new_path });

    var ci: usize = 0;
    while (ci < changes.len) {
        const first = ci;
        var last = ci;
        while (last + 1 < changes.len) {
            const gap_old = changes[last + 1].ol_s -| changes[last].ol_e;
            const gap_new = changes[last + 1].nl_s -| changes[last].nl_e;
            const gap = @max(gap_old, gap_new);
            if (gap <= context_lines *| 2) {
                last += 1;
            } else {
                break;
            }
        }

        const hunk_ol_s = changes[first].ol_s -| context_lines;
        const hunk_ol_e = @min(old_lines.len, changes[last].ol_e +| context_lines);
        const hunk_nl_s = changes[first].nl_s -| context_lines;
        const hunk_nl_e = @min(new_lines.len, changes[last].nl_e +| context_lines);

        const old_count = hunk_ol_e - hunk_ol_s;
        const new_count = hunk_nl_e - hunk_nl_s;
        const old_start_1 = if (old_count == 0) hunk_ol_s else hunk_ol_s + 1;
        const new_start_1 = if (new_count == 0) hunk_nl_s else hunk_nl_s + 1;

        try out.print(allocator, "@@ -{d},{d} +{d},{d} @@\n", .{
            old_start_1,
            old_count,
            new_start_1,
            new_count,
        });

        var cur_ol = hunk_ol_s;
        var cur_nl = hunk_nl_s;
        var k = first;
        while (k <= last) : (k += 1) {
            const ch = changes[k];
            while (cur_ol < ch.ol_s and cur_nl < ch.nl_s) {
                try emitDiffLine(allocator, &out, ' ', before, old_lines[cur_ol]);
                cur_ol += 1;
                cur_nl += 1;
            }
            while (cur_ol < ch.ol_e) : (cur_ol += 1) {
                try emitDiffLine(allocator, &out, '-', before, old_lines[cur_ol]);
            }
            while (cur_nl < ch.nl_e) : (cur_nl += 1) {
                try emitDiffLine(allocator, &out, '+', after, new_lines[cur_nl]);
            }
        }
        while (cur_ol < hunk_ol_e and cur_nl < hunk_nl_e) {
            try emitDiffLine(allocator, &out, ' ', before, old_lines[cur_ol]);
            cur_ol += 1;
            cur_nl += 1;
        }

        ci = last + 1;
    }

    return out.toOwnedSlice(allocator);
}

pub fn formatUnifiedDiffText(
    allocator: Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
    context_lines: usize,
) Allocator.Error![]u8 {
    return formatUnifiedDiffPaths(allocator, path, path, before, after, context_lines);
}

fn inspectInodeInView(
    allocator: Allocator,
    hist: *const history_mod.History,
    iid: id.InodeId,
    view: text_mod.View,
) Allocator.Error!InodeContent {
    hist.tree.beginPinScope();
    defer hist.tree.endPinScope();
    if (!try hist.tree.isPresent(allocator, view, iid)) return .absent;
    const inode = hist.tree.get(iid) orelse return .absent;
    switch (inode.kind) {
        .dir => return .absent,
        .file => |*f| {
            const ck = f.content.getIn(view) orelse return .absent;
            return switch (ck.*) {
                .text => if (try f.text.readIn(allocator, hist.resolver(), view)) |bytes| .{ .text = bytes } else .absent,
                .binary => |ref| .{ .binary = ref.oid },
                .git_binary => |ref| .{ .binary = ref.oid.bytes },
                .git_lazy => |ref| blk: {
                    const bytes = (try hist.readGitBlobAlloc(allocator, ref.oid)) orelse break :blk .{ .binary = ref.oid.bytes };
                    if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) {
                        allocator.free(bytes);
                        break :blk .{ .binary = ref.oid.bytes };
                    }
                    break :blk .{ .text = bytes };
                },
            };
        },
        .symlink => |*s| {
            const tgt = s.getIn(view) orelse return .absent;
            return .{ .text = try std.fmt.allocPrint(allocator, "symlink -> {s}\n", .{tgt.*}) };
        },
    }
}

fn compareTouchedInodes(
    allocator: Allocator,
    hist: *const history_mod.History,
    inodes: []const id.InodeId,
    before_view: text_mod.View,
    after_view: text_mod.View,
) Allocator.Error![]FileChange {
    var out: std.ArrayList(FileChange) = .empty;
    errdefer {
        for (out.items) |*fc| fc.deinit(allocator);
        out.deinit(allocator);
    }

    for (inodes) |iid| {
        const inode = hist.tree.get(iid) orelse continue;
        if (inode.isDir()) continue;

        var old_c = try inspectInodeInView(allocator, hist, iid, before_view);
        defer old_c.deinit(allocator);
        var new_c = try inspectInodeInView(allocator, hist, iid, after_view);
        defer new_c.deinit(allocator);

        if (old_c == .absent and new_c == .absent) continue;

        const old_path = if (old_c != .absent) try hist.tree.pathOf(allocator, before_view, iid) else null;
        defer if (old_path) |p| allocator.free(p);
        const new_path = if (new_c != .absent) try hist.tree.pathOf(allocator, after_view, iid) else null;
        defer if (new_path) |p| allocator.free(p);

        const display_path = new_path orelse old_path orelse continue;
        const is_binary = (old_c == .binary) or (new_c == .binary);

        var kind: ChangeKind = undefined;
        if (old_c == .absent) {
            kind = if (is_binary) .binary else .added;
        } else if (new_c == .absent) {
            kind = if (is_binary) .binary else .deleted;
        } else {
            const moved = if (old_path != null and new_path != null)
                !std.mem.eql(u8, old_path.?, new_path.?)
            else
                false;
            if (moved) {
                kind = .renamed;
            } else if (is_binary) {
                if (old_c == .binary and new_c == .binary and std.mem.eql(u8, &old_c.binary, &new_c.binary)) {
                    continue;
                }
                kind = .binary;
            } else {
                if (std.mem.eql(u8, old_c.text, new_c.text)) continue;
                kind = .modified;
            }
        }

        var added: u32 = 0;
        var removed: u32 = 0;
        if (!is_binary) {
            const old_bytes: []const u8 = switch (old_c) {
                .text => |b| b,
                else => "",
            };
            const new_bytes: []const u8 = switch (new_c) {
                .text => |b| b,
                else => "",
            };
            const stats = try countLineStats(allocator, old_bytes, new_bytes);
            added = stats.added;
            removed = stats.removed;
        }

        const path_copy = try allocator.dupe(u8, display_path);
        errdefer allocator.free(path_copy);
        try out.append(allocator, .{
            .path = path_copy,
            .added_lines = added,
            .removed_lines = removed,
            .kind = kind,
        });
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: FileChange, b: FileChange) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    };
    std.mem.sort(FileChange, out.items, {}, SortCtx.lessThan);
    return out.toOwnedSlice(allocator);
}

fn buildScopeLookup(
    allocator: Allocator,
    ws: *const workspace.Workspace,
) Allocator.Error!std.AutoHashMapUnmanaged(id.BatchId, *const workspace.ScopeRecord) {
    var map: std.AutoHashMapUnmanaged(id.BatchId, *const workspace.ScopeRecord) = .empty;
    errdefer map.deinit(allocator);
    for (ws.scopes.items) |*sc| {
        for (sc.batches.items) |bid| {
            try map.put(allocator, bid, sc);
        }
    }
    return map;
}

pub fn listEntries(
    allocator: Allocator,
    ws: *workspace.Workspace,
    before: ?id.BatchId,
    limit: usize,
) ![]TimelineEntry {
    if (limit == 0) return try allocator.alloc(TimelineEntry, 0);

    var all_ids = try ws.history.dag.difference(allocator, &ws.history.dag.heads, &version.Version.ROOT);
    defer all_ids.deinit(allocator);
    std.mem.reverse(id.BatchId, all_ids.items);

    var start_idx: usize = 0;
    if (before) |b_id| {
        start_idx = all_ids.items.len;
        for (all_ids.items, 0..) |bid, i| {
            if (bid.eql(b_id)) {
                start_idx = i + 1;
                break;
            }
        }
    }

    var scope_map = try buildScopeLookup(allocator, ws);
    defer scope_map.deinit(allocator);

    var out: std.ArrayList(TimelineEntry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit(allocator);
    }

    for (all_ids.items[start_idx..]) |bid| {
        if (out.items.len >= limit) break;
        const touched = ws.history.batch_inodes.get(bid) orelse continue;
        if (touched.len == 0) continue;
        const hdr = ws.history.dag.getHeader(bid) orelse continue;

        var before_cv = try ws.history.dag.compileView(allocator, &hdr.parents);
        defer before_cv.deinit(allocator);
        const after_ver = version.Version.single(bid);
        var after_cv = try ws.history.dag.compileView(allocator, &after_ver);
        defer after_cv.deinit(allocator);

        const files = try compareTouchedInodes(
            allocator,
            &ws.history,
            touched,
            before_cv.view(),
            after_cv.view(),
        );
        if (files.len == 0) {
            allocator.free(files);
            continue;
        }
        errdefer {
            for (files) |*f| f.deinit(allocator);
            allocator.free(files);
        }

        var total_added: u32 = 0;
        var total_removed: u32 = 0;
        for (files) |f| {
            total_added +|= f.added_lines;
            total_removed +|= f.removed_lines;
        }

        const sc_opt = scope_map.get(bid);
        const scope_id: ?u64 = if (sc_opt) |sc| @truncate(sc.scope_id) else null;
        const scope_label: ?[]u8 = if (sc_opt) |sc| try allocator.dupe(u8, sc.label) else null;
        errdefer if (scope_label) |lbl| allocator.free(lbl);

        const eff_actor = if (sc_opt) |sc| sc.actor else hdr.actor;

        try out.append(allocator, .{
            .batch_id = bid,
            .actor = eff_actor,
            .wall_ms = hdr.wall_ms,
            .scope_id = scope_id,
            .scope_label = scope_label,
            .files = files,
            .total_added = total_added,
            .total_removed = total_removed,
        });
    }

    return out.toOwnedSlice(allocator);
}

pub fn unifiedDiff(
    allocator: Allocator,
    ws: *workspace.Workspace,
    batch_ids: []const id.BatchId,
) ![]u8 {
    if (batch_ids.len == 0) return try allocator.alloc(u8, 0);

    var touched_set: std.AutoArrayHashMapUnmanaged(id.InodeId, void) = .empty;
    defer touched_set.deinit(allocator);
    for (batch_ids) |bid| {
        if (ws.history.batch_inodes.get(bid)) |inodes| {
            for (inodes) |iid| {
                try touched_set.put(allocator, iid, {});
            }
        }
    }
    if (touched_set.count() == 0) return try allocator.alloc(u8, 0);

    var before_cv = try ws.history.dag.compileExcluding(allocator, batch_ids);
    defer before_cv.deinit(allocator);
    const before_view = before_cv.view();
    const after_view = text_mod.View.EVERYTHING;

    const PatchPart = struct {
        path: []u8,
        patch: []u8,

        fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.path);
            alloc.free(self.patch);
        }
    };

    var parts: std.ArrayList(PatchPart) = .empty;
    defer {
        for (parts.items) |*p| p.deinit(allocator);
        parts.deinit(allocator);
    }

    for (touched_set.keys()) |iid| {
        const inode = ws.history.tree.get(iid) orelse continue;
        if (inode.isDir()) continue;

        var old_c = try inspectInodeInView(allocator, &ws.history, iid, before_view);
        defer old_c.deinit(allocator);
        var new_c = try inspectInodeInView(allocator, &ws.history, iid, after_view);
        defer new_c.deinit(allocator);

        if (old_c == .absent and new_c == .absent) continue;

        const old_path_opt = if (old_c != .absent) try ws.history.tree.pathOf(allocator, before_view, iid) else null;
        defer if (old_path_opt) |p| allocator.free(p);
        const new_path_opt = if (new_c != .absent) try ws.history.tree.pathOf(allocator, after_view, iid) else null;
        defer if (new_path_opt) |p| allocator.free(p);

        const sort_path = new_path_opt orelse old_path_opt orelse continue;
        const old_p = old_path_opt orelse sort_path;
        const new_p = new_path_opt orelse sort_path;

        const is_binary = (old_c == .binary) or (new_c == .binary);
        var patch: []u8 = undefined;
        if (is_binary) {
            if (old_c == .binary and new_c == .binary and
                std.mem.eql(u8, &old_c.binary, &new_c.binary) and
                std.mem.eql(u8, old_p, new_p))
            {
                continue;
            }
            patch = try std.fmt.allocPrint(allocator, "--- a/{s}\n+++ b/{s}\nBinary files differ\n", .{ old_p, new_p });
        } else {
            const old_bytes: []const u8 = switch (old_c) {
                .text => |b| b,
                else => "",
            };
            const new_bytes: []const u8 = switch (new_c) {
                .text => |b| b,
                else => "",
            };
            patch = try formatUnifiedDiffPaths(allocator, old_p, new_p, old_bytes, new_bytes, 3);
            if (patch.len == 0) {
                allocator.free(patch);
                continue;
            }
        }
        errdefer allocator.free(patch);

        const path_copy = try allocator.dupe(u8, sort_path);
        errdefer allocator.free(path_copy);
        try parts.append(allocator, .{ .path = path_copy, .patch = patch });
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: PatchPart, b: PatchPart) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    };
    std.mem.sort(PatchPart, parts.items, {}, SortCtx.lessThan);

    var total: usize = 0;
    for (parts.items) |p| total += p.patch.len;
    var out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (parts.items) |p| {
        @memcpy(out[pos .. pos + p.patch.len], p.patch);
        pos += p.patch.len;
    }
    return out;
}

pub fn foreignChanges(
    allocator: Allocator,
    ws: *workspace.Workspace,
    since_version: ?version.Version,
    exclude_actor: id.ActorId,
) ![]ForeignChange {
    var known = version.Version.ROOT;
    defer known.deinit(allocator);
    if (since_version) |sv| {
        for (sv.slice()) |bid| {
            if (ws.history.dag.containsBatch(bid)) {
                try known.insert(allocator, bid);
            }
        }
    }

    var diff_ids = try ws.history.dag.difference(allocator, &ws.history.dag.heads, &known);
    defer diff_ids.deinit(allocator);

    var own_scope_batches: std.AutoHashMapUnmanaged(id.BatchId, void) = .empty;
    defer own_scope_batches.deinit(allocator);
    var scope_map = try buildScopeLookup(allocator, ws);
    defer scope_map.deinit(allocator);

    for (ws.scopes.items) |*sc| {
        if (sc.actor == exclude_actor) {
            for (sc.batches.items) |bid| {
                try own_scope_batches.put(allocator, bid, {});
            }
        }
    }

    var out: std.ArrayList(ForeignChange) = .empty;
    errdefer {
        for (out.items) |*c| c.deinit(allocator);
        out.deinit(allocator);
    }

    for (diff_ids.items) |bid| {
        const hdr = ws.history.dag.getHeader(bid) orelse continue;
        if (hdr.actor == exclude_actor) continue;
        if (own_scope_batches.contains(bid)) continue;
        const touched = ws.history.batch_inodes.get(bid) orelse continue;
        if (touched.len == 0) continue;

        const eff_actor = if (scope_map.get(bid)) |sc| sc.actor else hdr.actor;
        if (eff_actor == exclude_actor) continue;

        var before_cv = try ws.history.dag.compileView(allocator, &hdr.parents);
        defer before_cv.deinit(allocator);
        const after_ver = version.Version.single(bid);
        var after_cv = try ws.history.dag.compileView(allocator, &after_ver);
        defer after_cv.deinit(allocator);

        const files = try compareTouchedInodes(
            allocator,
            &ws.history,
            touched,
            before_cv.view(),
            after_cv.view(),
        );
        defer {
            for (files) |*f| f.deinit(allocator);
            allocator.free(files);
        }

        for (files) |f| {
            const path_copy = try allocator.dupe(u8, f.path);
            errdefer allocator.free(path_copy);
            try out.append(allocator, .{
                .path = path_copy,
                .actor = eff_actor,
                .batch_id = bid,
                .added_lines = f.added_lines,
                .removed_lines = f.removed_lines,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendXmlEscaped(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
}

pub fn formatWorkspaceChangesXml(
    allocator: Allocator,
    changes: []const ForeignChange,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<workspace-changes>\n");
    for (changes) |ch| {
        var actor_buf: [16]u8 = undefined;
        const actor_short = id.formatShortId(ch.actor, &actor_buf);
        var batch_actor_buf: [16]u8 = undefined;
        const batch_actor_short = id.formatShortId(ch.batch_id.actor, &batch_actor_buf);

        try out.appendSlice(allocator, "  <change path=\"");
        try appendXmlEscaped(allocator, &out, ch.path);
        try out.print(allocator, "\" actor=\"{s}\" batch=\"{d}.{s}\" added=\"{d}\" removed=\"{d}\"/>\n", .{
            actor_short,
            ch.batch_id.ts,
            batch_actor_short,
            ch.added_lines,
            ch.removed_lines,
        });
    }
    try out.appendSlice(allocator, "</workspace-changes>\n");
    return out.toOwnedSlice(allocator);
}
