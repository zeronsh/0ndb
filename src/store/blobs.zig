const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const crypto = @import("crypto.zig");

pub const DEFAULT_CACHE_BUDGET: usize = 32 * 1024 * 1024;

pub const BlobStore = struct {
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    budget: usize,
    used: usize,
    head: ?*CacheNode,
    tail: ?*CacheNode,
    cache: std.AutoHashMapUnmanaged(crypto.Hash, *CacheNode),

    const CacheNode = struct {
        hash: crypto.Hash,
        data: []u8,
        prev: ?*CacheNode,
        next: ?*CacheNode,
    };

    pub fn open(allocator: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, budget: usize) !BlobStore {
        try parent.createDirPath(io, sub_path);
        const dir = try parent.openDir(io, sub_path, .{});
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .budget = if (budget == 0) DEFAULT_CACHE_BUDGET else budget,
            .used = 0,
            .head = null,
            .tail = null,
            .cache = .empty,
        };
    }

    pub fn deinit(self: *BlobStore) void {
        self.clearCache();
        self.cache.deinit(self.allocator);
        self.dir.close(self.io);
    }

    pub fn hibernate(self: *BlobStore) void {
        self.clearCache();
    }

    fn clearCache(self: *BlobStore) void {
        var cur = self.head;
        while (cur) |node| {
            const nxt = node.next;
            self.allocator.free(node.data);
            self.allocator.destroy(node);
            cur = nxt;
        }
        self.head = null;
        self.tail = null;
        self.used = 0;
        self.cache.clearRetainingCapacity();
    }

    fn unlink(self: *BlobStore, node: *CacheNode) void {
        if (node.prev) |p| {
            p.next = node.next;
        } else {
            self.head = node.next;
        }
        if (node.next) |n| {
            n.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        node.prev = null;
        node.next = null;
    }

    fn pushFront(self: *BlobStore, node: *CacheNode) void {
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| {
            h.prev = node;
        } else {
            self.tail = node;
        }
        self.head = node;
    }

    fn moveToFront(self: *BlobStore, node: *CacheNode) void {
        if (self.head == node) return;
        self.unlink(node);
        self.pushFront(node);
    }

    fn blobPath(hash: crypto.Hash, buf: *[67]u8) []const u8 {
        const hex = std.fmt.bytesToHex(hash, .lower);
        buf[0] = hex[0];
        buf[1] = hex[1];
        buf[2] = '/';
        @memcpy(buf[3..67], &hex);
        return buf[0..67];
    }

    pub fn put(self: *BlobStore, data: []const u8) !crypto.Hash {
        const h = crypto.hashBytes(data);
        try self.putVerified(h, data);
        return h;
    }

    pub fn putVerified(self: *BlobStore, hash: crypto.Hash, data: []const u8) !void {
        if (self.cache.get(hash)) |node| {
            self.moveToFront(node);
            return;
        }
        var pbuf: [67]u8 = undefined;
        const path = blobPath(hash, &pbuf);

        if (!self.exists(hash)) {
            const fanout = path[0..2];
            try self.dir.createDirPath(self.io, fanout);
            var tmp_buf: [80]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch unreachable;
            const f = try self.dir.createFile(self.io, tmp_name, .{ .truncate = true });
            var f_closed = false;
            errdefer {
                if (!f_closed) f.close(self.io);
                self.dir.deleteFile(self.io, tmp_name) catch {};
            }
            try f.writePositionalAll(self.io, data, 0);
            try f.sync(self.io);
            f.close(self.io);
            f_closed = true;
            try self.dir.rename(tmp_name, self.dir, path, self.io);
        }

        try self.cachePut(hash, data);
    }

    pub fn isCached(self: *const BlobStore, hash: crypto.Hash) bool {
        return self.cache.contains(hash);
    }

    pub fn exists(self: *BlobStore, hash: crypto.Hash) bool {
        if (self.cache.contains(hash)) return true;
        var pbuf: [67]u8 = undefined;
        const path = blobPath(hash, &pbuf);
        _ = self.dir.statFile(self.io, path, .{}) catch return false;
        return true;
    }

    pub fn get(self: *BlobStore, allocator: Allocator, hash: crypto.Hash) !?[]u8 {
        if (self.cache.get(hash)) |node| {
            self.moveToFront(node);
            return try allocator.dupe(u8, node.data);
        }
        var pbuf: [67]u8 = undefined;
        const path = blobPath(hash, &pbuf);
        const f = self.dir.openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer f.close(self.io);
        const st = try f.stat(self.io);
        const size: usize = @intCast(st.size);
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n != size) return error.UnexpectedEof;
        const actual = crypto.hashBytes(buf);
        if (!std.mem.eql(u8, &actual, &hash)) return error.CorruptBlob;
        self.cachePut(hash, buf) catch {};
        return buf;
    }

    fn cachePut(self: *BlobStore, hash: crypto.Hash, data: []const u8) !void {
        if (data.len > self.budget) return;
        if (self.cache.get(hash)) |node| {
            self.moveToFront(node);
            return;
        }
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);
        const node = try self.allocator.create(CacheNode);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .hash = hash,
            .data = owned,
            .prev = null,
            .next = null,
        };
        self.evictUntil(self.budget - owned.len);
        try self.cache.put(self.allocator, hash, node);
        self.pushFront(node);
        self.used += owned.len;
    }

    fn evictUntil(self: *BlobStore, target: usize) void {
        while (self.used > target) {
            const victim = self.tail orelse break;
            self.unlink(victim);
            _ = self.cache.remove(victim.hash);
            self.used -= victim.data.len;
            self.allocator.free(victim.data);
            self.allocator.destroy(victim);
        }
    }
};
