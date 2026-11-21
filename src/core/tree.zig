const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const text_mod = @import("text.zig");
const Text = text_mod.Text;
const View = text_mod.View;
const lru = @import("lru.zig");

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

pub const GitBlobRef = struct {
    oid: id.GitOid,
    len: u64,

    pub fn eql(self: GitBlobRef, other: GitBlobRef) bool {
        return self.len == other.len and self.oid.eql(other.oid);
    }
};

pub const ContentKind = union(enum) {
    text,
    binary: BlobRef,
    git_binary: GitBlobRef,
    git_lazy: GitBlobRef,
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

pub const OwnedPlacementEntry = struct {
    op: id.OpId,
    value: Placement,

    pub fn deinit(self: *OwnedPlacementEntry, allocator: Allocator) void {
        self.value.deinit(allocator);
    }
};

const DirNameHashKey = struct {
    parent: id.InodeId,
    name_hash: u64,
};

const NameSlot = union(enum) {
    single: id.InodeId,
    multiple,
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
            } else if (T == ?[]u8) {
                for (self.entries.items) |e| {
                    if (e.value) |v| allocator.free(v);
                }
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
                        } else if (T == ?[]u8) {
                            if (value) |v| allocator.free(v);
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

    pub fn approxBytes(self: *const Inode) usize {
        var bytes: usize = @sizeOf(Inode);
        bytes += self.placement.entries.items.len * @sizeOf(Lww(Placement).Entry);
        for (self.placement.entries.items) |e| bytes += e.value.name.len;
        bytes += self.alive.entries.items.len * @sizeOf(Lww(bool).Entry);
        switch (self.kind) {
            .dir => {},
            .file => |*f| {
                bytes += f.content.entries.items.len * @sizeOf(Lww(ContentKind).Entry);
                bytes += f.mode.entries.items.len * @sizeOf(Lww(FileMode).Entry);
                bytes += f.line_ending.entries.items.len * @sizeOf(Lww(LineEnding).Entry);
                if (f.text.root != null) {
                    bytes += f.text.fragmentCount() * 64 + 128;
                }
            },
            .symlink => |*s| {
                bytes += s.entries.items.len * @sizeOf(Lww([]u8).Entry);
                for (s.entries.items) |e| bytes += e.value.len;
            },
        }
        return bytes;
    }
};

pub const DirEntry = struct {
    name: []u8,
    inode_id: id.InodeId,

    pub fn deinit(self: *DirEntry, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const DIR_NAME_FLAG_CONFLICT: u8 = 1;
pub const DIR_NAME_FLAG_TOMBSTONE: u8 = 2;

pub const DirNameLookup = struct {
    child_id: id.InodeId,
    kind: u8,
    flags: u8,
};

pub const InodeSource = struct {
    ptr: *const anyopaque,
    loadInodeFn: *const fn (ptr: *const anyopaque, allocator: Allocator, iid: id.InodeId) Allocator.Error!?*Inode,
    hasInodeFn: *const fn (ptr: *const anyopaque, iid: id.InodeId) bool,
    collectDirChildrenFn: *const fn (ptr: *const anyopaque, allocator: Allocator, dir: id.InodeId, out: *std.ArrayList(id.InodeId)) Allocator.Error!void,
    lookupDirNameFn: *const fn (ptr: *const anyopaque, parent: id.InodeId, name: []const u8) ?DirNameLookup,

    pub fn loadInode(self: InodeSource, allocator: Allocator, iid: id.InodeId) Allocator.Error!?*Inode {
        return self.loadInodeFn(self.ptr, allocator, iid);
    }

    pub fn hasInode(self: InodeSource, iid: id.InodeId) bool {
        return self.hasInodeFn(self.ptr, iid);
    }

    pub fn collectDirChildren(self: InodeSource, allocator: Allocator, dir: id.InodeId, out: *std.ArrayList(id.InodeId)) Allocator.Error!void {
        return self.collectDirChildrenFn(self.ptr, allocator, dir, out);
    }

    pub fn lookupDirName(self: InodeSource, parent: id.InodeId, name: []const u8) ?DirNameLookup {
        return self.lookupDirNameFn(self.ptr, parent, name);
    }
};

pub const DEFAULT_CLEAN_CACHE_BYTES: usize = 8 * 1024 * 1024;
pub const DEFAULT_CLEAN_CACHE_ENTRIES: usize = 8192;

fn inodeCacheSize(val: *Inode) usize {
    return val.approxBytes();
}

fn inodeCacheDeinit(allocator: Allocator, val: *Inode) void {
    val.deinit(allocator);
    allocator.destroy(val);
}

const CleanCache = lru.LruCache(id.InodeId, *Inode, inodeCacheSize, inodeCacheDeinit);

const CleanCacheBox = struct {
    allocator: Allocator,
    cache: CleanCache,
};

pub const Tree = struct {
    inodes: std.AutoHashMapUnmanaged(id.InodeId, *Inode) = .empty,
    children: std.AutoHashMapUnmanaged(id.InodeId, std.AutoArrayHashMapUnmanaged(id.InodeId, void)) = .empty,
    dirty_dirs: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty,
    dir_name_slots: std.AutoHashMapUnmanaged(DirNameHashKey, NameSlot) = .empty,
    source: ?InodeSource = null,
    content_resolver: ?text_mod.ContentResolver = null,
    clean_cache_box: ?*CleanCacheBox = null,

    pub fn init(allocator: Allocator) Allocator.Error!Tree {
        var t = Tree{};
        errdefer t.deinit(allocator);
        const box = try allocator.create(CleanCacheBox);
        box.* = .{
            .allocator = allocator,
            .cache = CleanCache.init(allocator, .{
                .budget_bytes = DEFAULT_CLEAN_CACHE_BYTES,
                .max_entries = DEFAULT_CLEAN_CACHE_ENTRIES,
            }),
        };
        t.clean_cache_box = box;

        const root = try allocator.create(Inode);
        errdefer {
            root.deinit(allocator);
            allocator.destroy(root);
        }
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
        while (cit.next()) |set| {
            set.deinit(allocator);
        }
        self.children.deinit(allocator);
        self.dirty_dirs.deinit(allocator);
        self.dir_name_slots.deinit(allocator);
        if (self.clean_cache_box) |box| {
            box.cache.deinit();
            allocator.destroy(box);
            self.clean_cache_box = null;
        }
        self.source = null;
        self.content_resolver = null;
    }

    pub fn setContentResolver(self: *Tree, res: ?text_mod.ContentResolver) void {
        self.content_resolver = res;
    }

    pub fn setSource(self: *Tree, src: ?InodeSource) void {
        self.source = src;
        if (self.clean_cache_box) |box| {
            if (box.cache.pin_depth == 0) {
                box.cache.clear();
            }
        }
    }

    pub fn setCleanCacheBudget(self: *Tree, budget_bytes: usize, max_entries: usize) void {
        if (self.clean_cache_box) |box| {
            box.cache.budget_bytes = budget_bytes;
            box.cache.max_entries = max_entries;
            box.cache.evictToBudget();
        }
    }

    pub fn beginPinScope(self: *const Tree) void {
        if (self.clean_cache_box) |box| {
            box.cache.beginPinScope();
        }
    }

    pub fn endPinScope(self: *const Tree) void {
        if (self.clean_cache_box) |box| {
            box.cache.endPinScope();
        }
    }

    pub fn evictClean(self: *Tree) void {
        if (self.clean_cache_box) |box| {
            if (box.cache.pin_depth == 0) {
                box.cache.clear();
            }
        }
    }

    pub fn hibernate(self: *Tree) void {
        self.evictClean();
    }

    pub fn dirtyInodesCount(self: *const Tree) usize {
        return self.inodes.count();
    }

    pub fn cleanCachedInodesCount(self: *const Tree) usize {
        if (self.clean_cache_box) |box| return box.cache.count();
        return 0;
    }

    pub fn loadedInodesCount(self: *const Tree) usize {
        return self.dirtyInodesCount() + self.cleanCachedInodesCount();
    }

    pub fn clearDirtyAfterCheckpoint(self: *Tree, allocator: Allocator) void {
        var it = self.inodes.valueIterator();
        while (it.next()) |ptr| {
            ptr.*.deinit(allocator);
            allocator.destroy(ptr.*);
        }
        self.inodes.clearRetainingCapacity();
        var cit = self.children.valueIterator();
        while (cit.next()) |set| {
            set.deinit(allocator);
        }
        self.children.clearRetainingCapacity();
        self.dirty_dirs.clearRetainingCapacity();
        self.dir_name_slots.clearRetainingCapacity();
        self.evictClean();
    }

    fn recordNameSlot(self: *Tree, allocator: Allocator, parent: id.InodeId, name: []const u8, child: id.InodeId) Allocator.Error!void {
        const key = DirNameHashKey{
            .parent = parent,
            .name_hash = std.hash.Wyhash.hash(0, name),
        };
        const gop = try self.dir_name_slots.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .single = child };
        } else {
            switch (gop.value_ptr.*) {
                .single => |existing| {
                    if (!existing.eql(child)) {
                        gop.value_ptr.* = .multiple;
                    }
                },
                .multiple => {},
            }
        }
    }

    pub fn markDirtyDir(self: *Tree, allocator: Allocator, dir: id.InodeId) Allocator.Error!void {
        try self.dirty_dirs.put(allocator, dir, {});
    }

    pub fn markDirty(self: *Tree, allocator: Allocator, iid: id.InodeId) Allocator.Error!void {
        if (self.getMut(iid)) |inode| {
            for (inode.placement.entries.items) |e| {
                try self.dirty_dirs.put(allocator, e.value.parent, {});
                try self.recordNameSlot(allocator, e.value.parent, e.value.name, iid);
            }
        }
    }

    pub fn get(self: *const Tree, iid: id.InodeId) ?*const Inode {
        if (self.inodes.get(iid)) |ptr| return ptr;
        if (self.clean_cache_box) |box| {
            if (box.cache.get(iid)) |ptr_ptr| return ptr_ptr.*;
            if (self.source) |src| {
                const loaded = (src.loadInode(box.allocator, iid) catch return null) orelse return null;
                if (self.content_resolver) |cr| {
                    if (loaded.filePtr()) |f| f.text.content_resolver = cr;
                }
                const slot = box.cache.put(iid, loaded) catch {
                    loaded.deinit(box.allocator);
                    box.allocator.destroy(loaded);
                    return null;
                };
                return slot.*;
            }
        }
        return null;
    }

    pub fn getMut(self: *Tree, iid: id.InodeId) ?*Inode {
        if (self.inodes.get(iid)) |ptr| return ptr;
        if (self.clean_cache_box) |box| {
            if (box.cache.take(iid)) |taken| {
                if (self.content_resolver) |cr| {
                    if (taken.filePtr()) |f| {
                        if (f.text.content_resolver == null) f.text.content_resolver = cr;
                    }
                }
                self.inodes.put(box.allocator, iid, taken) catch {
                    taken.deinit(box.allocator);
                    box.allocator.destroy(taken);
                    return null;
                };
                return taken;
            }
            if (self.source) |src| {
                const loaded = (src.loadInode(box.allocator, iid) catch return null) orelse return null;
                if (self.content_resolver) |cr| {
                    if (loaded.filePtr()) |f| f.text.content_resolver = cr;
                }
                self.inodes.put(box.allocator, iid, loaded) catch {
                    loaded.deinit(box.allocator);
                    box.allocator.destroy(loaded);
                    return null;
                };
                return loaded;
            }
        }
        return null;
    }

    pub fn contains(self: *const Tree, iid: id.InodeId) bool {
        if (self.inodes.contains(iid)) return true;
        if (self.clean_cache_box) |box| {
            if (box.cache.contains(iid)) return true;
        }
        if (self.source) |src| {
            return src.hasInode(iid);
        }
        return false;
    }

    pub fn addChildRef(self: *Tree, allocator: Allocator, dir: id.InodeId, child: id.InodeId) Allocator.Error!void {
        const gop = try self.children.getOrPut(allocator, dir);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.put(allocator, child, {});
        try self.dirty_dirs.put(allocator, dir, {});
    }

    pub fn insertInode(self: *Tree, allocator: Allocator, inode: *Inode) Allocator.Error!void {
        for (inode.placement.entries.items) |e| {
            try self.addChildRef(allocator, e.value.parent, inode.inode_id);
            try self.recordNameSlot(allocator, e.value.parent, e.value.name, inode.inode_id);
        }
        if (self.clean_cache_box) |box| {
            _ = box.cache.remove(inode.inode_id);
        }
        if (try self.inodes.fetchPut(allocator, inode.inode_id, inode)) |old| {
            old.value.deinit(allocator);
            allocator.destroy(old.value);
        }
    }

    pub fn place(self: *Tree, allocator: Allocator, iid: id.InodeId, op: id.OpId, parent: id.InodeId, name: []const u8) Allocator.Error!void {
        try self.addChildRef(allocator, parent, iid);
        try self.recordNameSlot(allocator, parent, name, iid);
        const inode = self.getMut(iid) orelse return;
        for (inode.placement.entries.items) |e| {
            try self.dirty_dirs.put(allocator, e.value.parent, {});
            try self.recordNameSlot(allocator, e.value.parent, e.value.name, iid);
        }
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try inode.placement.set(allocator, op, .{ .parent = parent, .name = owned });
    }

    fn collectDirChildrenUnion(
        self: *const Tree,
        allocator: Allocator,
        dir: id.InodeId,
        out: *std.ArrayList(id.InodeId),
    ) Allocator.Error!void {
        if (self.source) |src| {
            try src.collectDirChildren(allocator, dir, out);
        }
        if (self.children.getPtr(dir)) |kids| {
            if (out.items.len == 0) {
                try out.appendSlice(allocator, kids.keys());
            } else {
                var seen: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
                defer seen.deinit(allocator);
                try seen.ensureTotalCapacity(allocator, @intCast(out.items.len + kids.count()));
                for (out.items) |k| try seen.put(allocator, k, {});
                for (kids.keys()) |k| {
                    if (!seen.contains(k)) {
                        try seen.put(allocator, k, {});
                        try out.append(allocator, k);
                    }
                }
            }
        }
    }

    pub fn placementIn(self: *const Tree, allocator: Allocator, view: View, iid: id.InodeId) Allocator.Error!?OwnedPlacementEntry {
        if (iid.isRoot()) return null;
        self.beginPinScope();
        defer self.endPinScope();

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
                    return .{
                        .op = entry.op,
                        .value = try entry.value.clone(allocator),
                    };
                }
                for (chain.items, 0..) |c, pos| {
                    if (c.eql(cur)) {
                        const cycle = chain.items[pos..];
                        var victim = cycle[0];
                        var best_op = id.OpId.ZERO;
                        var has_best = false;
                        for (cycle) |member| {
                            const n = demoted.get(member) orelse 0;
                            const minode = self.get(member) orelse return null;
                            const me = minode.placement.nthIn(view, n) orelse return null;
                            if (!has_best or me.op.greaterThan(best_op) or (me.op.eql(best_op) and member.order(victim) == .gt)) {
                                best_op = me.op;
                                victim = member;
                                has_best = true;
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
        self.beginPinScope();
        defer self.endPinScope();
        const inode = self.get(iid) orelse return false;
        if (inode.placement.getIn(view) == null) return false;
        if (inode.alive.getIn(view)) |a| {
            if (a.*) return true;
        }
        if (!inode.isDir()) return false;
        var kids: std.ArrayList(id.InodeId) = .empty;
        defer kids.deinit(allocator);
        try self.collectDirChildrenUnion(allocator, iid, &kids);
        for (kids.items) |child| {
            var entry = try self.placementIn(allocator, view, child) orelse continue;
            const parent = entry.value.parent;
            entry.deinit(allocator);
            if (parent.eql(iid) and try self.isPresent(allocator, view, child)) return true;
        }
        return false;
    }

    pub fn listDir(self: *const Tree, allocator: Allocator, view: View, dir: id.InodeId) Allocator.Error!std.ArrayList(DirEntry) {
        self.beginPinScope();
        defer self.endPinScope();
        var out: std.ArrayList(DirEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }

        var kids: std.ArrayList(id.InodeId) = .empty;
        defer kids.deinit(allocator);
        try self.collectDirChildrenUnion(allocator, dir, &kids);
        if (kids.items.len == 0) return out;

        const Candidate = struct {
            name: []const u8,
            op: id.OpId,
            iid: id.InodeId,
        };
        var owned_entries: std.ArrayList(OwnedPlacementEntry) = .empty;
        defer {
            for (owned_entries.items) |*oe| oe.deinit(allocator);
            owned_entries.deinit(allocator);
        }
        var by_name: std.StringHashMapUnmanaged(std.ArrayList(Candidate)) = .empty;
        defer {
            var it = by_name.valueIterator();
            while (it.next()) |l| l.deinit(allocator);
            by_name.deinit(allocator);
        }

        for (kids.items) |child| {
            var entry = try self.placementIn(allocator, view, child) orelse continue;
            var entry_owned = true;
            errdefer if (entry_owned) entry.deinit(allocator);
            if (!entry.value.parent.eql(dir)) {
                entry.deinit(allocator);
                entry_owned = false;
                continue;
            }
            if (!try self.isPresent(allocator, view, child)) {
                entry.deinit(allocator);
                entry_owned = false;
                continue;
            }
            const name_slice = entry.value.name;
            const op = entry.op;
            try owned_entries.append(allocator, entry);
            entry_owned = false;
            const gop = try by_name.getOrPut(allocator, name_slice);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{ .name = name_slice, .op = op, .iid = child });
        }

        var it = by_name.iterator();
        while (it.next()) |kv| {
            const items = kv.value_ptr.items;
            std.mem.sort(Candidate, items, {}, struct {
                fn lt(_: void, a: Candidate, b: Candidate) bool {
                    const ord = a.op.order(b.op);
                    if (ord != .eq) return ord == .gt;
                    return a.iid.order(b.iid) == .lt;
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
        const fast_view = (self.source != null and view.min_unobserved == std.math.maxInt(u64));
        var cur = id.InodeId.ROOT;
        var it = std.mem.splitScalar(u8, rel_path, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (fast_view and !self.dirty_dirs.contains(cur)) {
                const src = self.source.?;
                const lookup = src.lookupDirName(cur, part) orelse return null;
                if ((lookup.flags & DIR_NAME_FLAG_TOMBSTONE) != 0) return null;
                if ((lookup.flags & DIR_NAME_FLAG_CONFLICT) == 0 and !self.inodes.contains(lookup.child_id)) {
                    cur = lookup.child_id;
                    continue;
                }
            }
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
        self.beginPinScope();
        defer self.endPinScope();
        var parts: std.ArrayList([]u8) = .empty;
        defer {
            for (parts.items) |part| allocator.free(part);
            parts.deinit(allocator);
        }
        var cur = iid;
        var guard: usize = 0;
        while (!cur.isRoot()) {
            guard += 1;
            if (guard > 4096) return null;
            if (!try self.isPresent(allocator, view, cur)) return null;
            var entry = try self.placementIn(allocator, view, cur) orelse return null;
            defer entry.deinit(allocator);
            const p = &entry.value;
            var has_winner_before = false;
            var need_sibling_scan = true;
            const name_key = DirNameHashKey{
                .parent = p.parent,
                .name_hash = std.hash.Wyhash.hash(0, p.name),
            };
            if (self.source) |src| {
                if (view.min_unobserved == std.math.maxInt(u64)) {
                    if (!self.dirty_dirs.contains(p.parent)) {
                        if (src.lookupDirName(p.parent, p.name)) |lookup| {
                            if ((lookup.flags & DIR_NAME_FLAG_TOMBSTONE) == 0 and
                                (lookup.flags & DIR_NAME_FLAG_CONFLICT) == 0 and
                                lookup.child_id.eql(cur) and
                                !self.inodes.contains(cur))
                            {
                                need_sibling_scan = false;
                            }
                        }
                    } else {
                        const mem_ok = if (self.dir_name_slots.get(name_key)) |slot| switch (slot) {
                            .single => |only| only.eql(cur),
                            .multiple => false,
                        } else true;
                        if (mem_ok) {
                            const disk_ok = if (src.lookupDirName(p.parent, p.name)) |lookup|
                                ((lookup.flags & DIR_NAME_FLAG_TOMBSTONE) != 0) or
                                    ((lookup.flags & DIR_NAME_FLAG_CONFLICT) == 0 and lookup.child_id.eql(cur))
                            else
                                true;
                            if (disk_ok) need_sibling_scan = false;
                        }
                    }
                }
            } else {
                if (self.dir_name_slots.get(name_key)) |slot| {
                    if (slot == .single and slot.single.eql(cur)) {
                        need_sibling_scan = false;
                    }
                }
            }
            if (need_sibling_scan) {
                var siblings: std.ArrayList(id.InodeId) = .empty;
                defer siblings.deinit(allocator);
                try self.collectDirChildrenUnion(allocator, p.parent, &siblings);
                for (siblings.items) |sib| {
                    if (sib.eql(cur)) continue;
                    var sib_entry = try self.placementIn(allocator, view, sib) orelse continue;
                    defer sib_entry.deinit(allocator);
                    if (!sib_entry.value.parent.eql(p.parent)) continue;
                    if (!std.mem.eql(u8, sib_entry.value.name, p.name)) continue;
                    if (!try self.isPresent(allocator, view, sib)) continue;
                    const ord = sib_entry.op.order(entry.op);
                    if (ord == .gt or (ord == .eq and sib.order(cur) == .lt)) {
                        has_winner_before = true;
                        break;
                    }
                }
            }
            const display_name = if (has_winner_before) blk: {
                var short_buf: [16]u8 = undefined;
                const short = id.formatShortId(entry.op.actor, &short_buf);
                break :blk try std.fmt.allocPrint(allocator, "{s}~{s}-{d}", .{ p.name, short[0..8], entry.op.ts });
            } else try allocator.dupe(u8, p.name);
            errdefer allocator.free(display_name);
            try parts.append(allocator, display_name);
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
