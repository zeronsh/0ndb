const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const text_mod = @import("text.zig");
const Text = text_mod.Text;
const View = text_mod.View;

pub const FileMode = enum(u8) {
    regular = 0,
    executable = 1,
};

pub const LineEnding = enum(u8) {
    lf = 0,
    crlf = 1,
};

pub const BlobRef = struct {
    oid: id.Oid,
    len: u64,

    pub fn eql(self: BlobRef, other: BlobRef) bool {
        return self.len == other.len and std.mem.eql(u8, &self.oid, &other.oid);
    }
};

pub const ContentKind = union(enum) {
    text,
    binary: BlobRef,
};

pub const Placement = struct {
    parent: id.InodeId,
    name: []u8,

    pub fn deinit(self: *Placement, allocator: Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: *const Placement, allocator: Allocator) Allocator.Error!Placement {
        return .{
            .parent = self.parent,
            .name = try allocator.dupe(u8, self.name),
        };
    }
};

pub fn Lww(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct {
            op: id.OpId,
            value: T,
        };

        entries: std.ArrayList(Entry) = .empty,

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (T == Placement) {
                for (self.entries.items) |*e| e.value.deinit(allocator);
            } else if (T == []u8) {
                for (self.entries.items) |e| allocator.free(e.value);
            }
            self.entries.deinit(allocator);
        }

        pub fn set(self: *Self, allocator: Allocator, op: id.OpId, value: T) Allocator.Error!void {
            var lo: usize = 0;
            var hi: usize = self.entries.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (self.entries.items[mid].op.order(op)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => {
                        if (T == Placement) {
                            var v = value;
                            v.deinit(allocator);
                        } else if (T == []u8) {
                            allocator.free(value);
                        }
                        return;
                    },
                }
            }
            try self.entries.insert(allocator, lo, .{ .op = op, .value = value });
        }

        pub fn get(self: *const Self) ?*const T {
            if (self.entries.items.len == 0) return null;
            return &self.entries.items[self.entries.items.len - 1].value;
        }

        pub fn getIn(self: *const Self, view: View) ?*const T {
            const e = self.nthIn(view, 0) orelse return null;
            return &e.value;
        }

        pub fn nthIn(self: *const Self, view: View, n: usize) ?*const Entry {
            var seen: usize = 0;
            var i = self.entries.items.len;
            while (i > 0) {
                i -= 1;
                const entry = &self.entries.items[i];
                if (view.observes(entry.op)) {
                    if (seen == n) return entry;
                    seen += 1;
                }
            }
            return null;
        }
    };
}

pub const FileNode = struct {
    text: Text = .{},
    content: Lww(ContentKind) = .{},
    mode: Lww(FileMode) = .{},
    line_ending: Lww(LineEnding) = .{},

    pub fn deinit(self: *FileNode, allocator: Allocator) void {
        self.text.deinit(allocator);
        self.content.deinit(allocator);
        self.mode.deinit(allocator);
        self.line_ending.deinit(allocator);
    }
};

pub const NodeKind = union(enum) {
    dir,
    file: FileNode,
    symlink: Lww([]u8),

    pub fn deinit(self: *NodeKind, allocator: Allocator) void {
        switch (self.*) {
            .dir => {},
            .file => |*f| f.deinit(allocator),
            .symlink => |*s| s.deinit(allocator),
        }
    }
};

pub const Inode = struct {
    inode_id: id.InodeId,
    kind: NodeKind,
    placement: Lww(Placement) = .{},
    alive: Lww(bool) = .{},

    pub fn deinit(self: *Inode, allocator: Allocator) void {
        self.kind.deinit(allocator);
        self.placement.deinit(allocator);
        self.alive.deinit(allocator);
    }

    pub fn isDir(self: *const Inode) bool {
        return self.kind == .dir;
    }

    pub fn filePtr(self: *Inode) ?*FileNode {
        return switch (self.kind) {
            .file => |*f| f,
            else => null,
        };
    }

    pub fn fileConstPtr(self: *const Inode) ?*const FileNode {
        return switch (self.kind) {
            .file => |*f| f,
            else => null,
        };
    }
};

pub const DirEntry = struct {
    name: []u8,
    inode_id: id.InodeId,

    pub fn deinit(self: *DirEntry, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const Tree = struct {
    inodes: std.AutoHashMapUnmanaged(id.InodeId, *Inode) = .empty,
    children: std.AutoHashMapUnmanaged(id.InodeId, std.ArrayList(id.InodeId)) = .empty,

    pub fn init(allocator: Allocator) Allocator.Error!Tree {
        var t = Tree{};
        errdefer t.deinit(allocator);
        const root = try allocator.create(Inode);
        root.* = .{
            .inode_id = id.InodeId.ROOT,
            .kind = .dir,
        };
        try root.alive.set(allocator, id.OpId.ZERO, true);
        try t.inodes.put(allocator, id.InodeId.ROOT, root);
        return t;
    }

    pub fn deinit(self: *Tree, allocator: Allocator) void {
        var it = self.inodes.valueIterator();
        while (it.next()) |ptr| {
            ptr.*.deinit(allocator);
            allocator.destroy(ptr.*);
        }
        self.inodes.deinit(allocator);
        var cit = self.children.valueIterator();
        while (cit.next()) |list| {
            list.deinit(allocator);
        }
        self.children.deinit(allocator);
    }

    pub fn get(self: *const Tree, iid: id.InodeId) ?*const Inode {
        return self.inodes.get(iid);
    }

    pub fn getMut(self: *Tree, iid: id.InodeId) ?*Inode {
        return self.inodes.get(iid);
    }

    pub fn contains(self: *const Tree, iid: id.InodeId) bool {
        return self.inodes.contains(iid);
    }

    pub fn addChildRef(self: *Tree, allocator: Allocator, dir: id.InodeId, child: id.InodeId) Allocator.Error!void {
        const gop = try self.children.getOrPut(allocator, dir);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |existing| {
            if (existing.eql(child)) return;
        }
        try gop.value_ptr.append(allocator, child);
    }

    pub fn insertInode(self: *Tree, allocator: Allocator, inode: *Inode) Allocator.Error!void {
        for (inode.placement.entries.items) |e| {
            try self.addChildRef(allocator, e.value.parent, inode.inode_id);
        }
        if (self.inodes.fetchRemove(inode.inode_id)) |old| {
            old.value.deinit(allocator);
            allocator.destroy(old.value);
        }
        try self.inodes.put(allocator, inode.inode_id, inode);
    }

    pub fn place(self: *Tree, allocator: Allocator, iid: id.InodeId, op: id.OpId, parent: id.InodeId, name: []const u8) Allocator.Error!void {
        try self.addChildRef(allocator, parent, iid);
        const inode = self.inodes.get(iid) orelse return;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try inode.placement.set(allocator, op, .{ .parent = parent, .name = owned });
    }

    pub fn placementIn(self: *const Tree, allocator: Allocator, view: View, iid: id.InodeId) Allocator.Error!?*const Placement {
        if (iid.isRoot()) return null;
        var demoted: std.AutoHashMapUnmanaged(id.InodeId, usize) = .empty;
        defer demoted.deinit(allocator);

        var chain: std.ArrayList(id.InodeId) = .empty;
        defer chain.deinit(allocator);

        retry: while (true) {
            chain.clearRetainingCapacity();
            var cur = iid;
            while (true) {
                if (cur.isRoot()) {
                    const n = demoted.get(iid) orelse 0;
                    const inode = self.get(iid) orelse return null;
                    const entry = inode.placement.nthIn(view, n) orelse return null;
                    return &entry.value;
                }
                for (chain.items, 0..) |c, pos| {
                    if (c.eql(cur)) {
                        const cycle = chain.items[pos..];
                        var victim = cycle[0];
                        var best_op = id.OpId.ZERO;
                        for (cycle) |member| {
                            const n = demoted.get(member) orelse 0;
                            const minode = self.get(member) orelse return null;
                            const me = minode.placement.nthIn(view, n) orelse return null;
                            if (me.op.greaterThan(best_op)) {
                                best_op = me.op;
                                victim = member;
                            }
                        }
                        const gop = try demoted.getOrPut(allocator, victim);
                        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                        continue :retry;
                    }
                }
                try chain.append(allocator, cur);
                const n = demoted.get(cur) orelse 0;
                const inode = self.get(cur) orelse return null;
                const entry = inode.placement.nthIn(view, n) orelse return null;
                cur = entry.value.parent;
            }
        }
    }

    pub fn isPresent(self: *const Tree, allocator: Allocator, view: View, iid: id.InodeId) Allocator.Error!bool {
        if (iid.isRoot()) return true;
        const inode = self.get(iid) orelse return false;
        if (inode.placement.getIn(view) == null) return false;
        if (inode.alive.getIn(view)) |a| {
            if (a.*) return true;
        }
        if (!inode.isDir()) return false;
        const list = self.children.getPtr(iid) orelse return false;
        for (list.items) |child| {
            const p = try self.placementIn(allocator, view, child) orelse continue;
            if (p.parent.eql(iid) and try self.isPresent(allocator, view, child)) return true;
        }
        return false;
    }

    pub fn listDir(self: *const Tree, allocator: Allocator, view: View, dir: id.InodeId) Allocator.Error!std.ArrayList(DirEntry) {
        var out: std.ArrayList(DirEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }

        const kids = self.children.getPtr(dir) orelse return out;
        const Candidate = struct {
            name: []const u8,
            op: id.OpId,
            iid: id.InodeId,
        };
        var by_name: std.StringHashMapUnmanaged(std.ArrayList(Candidate)) = .empty;
        defer {
            var it = by_name.valueIterator();
            while (it.next()) |l| l.deinit(allocator);
            by_name.deinit(allocator);
        }

        for (kids.items) |child| {
            const p = try self.placementIn(allocator, view, child) orelse continue;
            if (!p.parent.eql(dir)) continue;
            if (!try self.isPresent(allocator, view, child)) continue;
            const inode = self.get(child) orelse continue;
            const entry = inode.placement.nthIn(view, 0) orelse continue;
            const gop = try by_name.getOrPut(allocator, p.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{ .name = p.name, .op = entry.op, .iid = child });
        }

        var it = by_name.iterator();
        while (it.next()) |kv| {
            const items = kv.value_ptr.items;
            std.mem.sort(Candidate, items, {}, struct {
                fn lt(_: void, a: Candidate, b: Candidate) bool {
                    return a.op.greaterThan(b.op);
                }
            }.lt);
            for (items, 0..) |cand, idx| {
                if (idx == 0) {
                    try out.append(allocator, .{
                        .name = try allocator.dupe(u8, cand.name),
                        .inode_id = cand.iid,
                    });
                } else {
                    var short_buf: [16]u8 = undefined;
                    const short = id.formatShortId(cand.op.actor, &short_buf);
                    const disambig = try std.fmt.allocPrint(allocator, "{s}~{s}-{d}", .{ cand.name, short[0..8], cand.op.ts });
                    try out.append(allocator, .{ .name = disambig, .inode_id = cand.iid });
                }
            }
        }

        std.mem.sort(DirEntry, out.items, {}, struct {
            fn lt(_: void, a: DirEntry, b: DirEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        return out;
    }

    pub fn resolvePath(self: *const Tree, allocator: Allocator, view: View, rel_path: []const u8) Allocator.Error!?id.InodeId {
        if (rel_path.len == 0) return id.InodeId.ROOT;
        var cur = id.InodeId.ROOT;
        var it = std.mem.splitScalar(u8, rel_path, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            var entries = try self.listDir(allocator, view, cur);
            defer {
                for (entries.items) |*e| e.deinit(allocator);
                entries.deinit(allocator);
            }
            var found: ?id.InodeId = null;
            for (entries.items) |e| {
                if (std.mem.eql(u8, e.name, part)) {
                    found = e.inode_id;
                    break;
                }
            }
            cur = found orelse return null;
        }
        return cur;
    }

    pub fn pathOf(self: *const Tree, allocator: Allocator, view: View, iid: id.InodeId) Allocator.Error!?[]u8 {
        if (iid.isRoot()) return try allocator.dupe(u8, "");
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var cur = iid;
        var guard: usize = 0;
        while (!cur.isRoot()) {
            guard += 1;
            if (guard > 256) return null;
            const p = try self.placementIn(allocator, view, cur) orelse return null;
            try parts.append(allocator, p.name);
            cur = p.parent;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i = parts.items.len;
        while (i > 0) {
            i -= 1;
            if (out.items.len > 0) try out.append(allocator, '/');
            try out.appendSlice(allocator, parts.items[i]);
        }
        return try out.toOwnedSlice(allocator);
    }
};
