const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const crypto = @import("crypto.zig");
const lru = @import("lru.zig");
const mmap = @import("mmap.zig");

pub const DEFAULT_CACHE_BUDGET: usize = 32 * 1024 * 1024;
pub const DEFAULT_PACK_SEAL_BYTES: u64 = 64 * 1024 * 1024;
pub const ENTRY_OVERHEAD: usize = lru.DEFAULT_ENTRY_OVERHEAD;

pub const PACK_RECORD_MAGIC: [4]u8 = .{ 'B', 'L', 'O', 'B' };
pub const PACK_RECORD_HEADER_SIZE: usize = 56;
pub const PACK_ALIGN: usize = 8;

pub const PACK_IDX_NAME: []const u8 = "pack.idx";
pub const PACK_IDX_MAGIC: [8]u8 = .{ '0', 'N', 'D', 'B', 'P', 'I', 'X', '1' };
pub const PACK_IDX_VERSION: u32 = 1;
pub const PACK_IDX_HEADER_SIZE: usize = 64;
pub const PACK_IDX_FANOUT_SIZE: usize = 256 * 4;
pub const PACK_IDX_ENTRY_SIZE: usize = 64;
pub const PACK_IDX_ENTRIES_OFFSET: usize = PACK_IDX_HEADER_SIZE + PACK_IDX_FANOUT_SIZE;

pub const FLAG_GIT_FALLBACK: u32 = 1 << 0;

pub const BlobItem = struct {
    hash: ?crypto.Hash = null,
    data: []const u8,
    flags: u32 = 0,
};

pub const GcStats = struct {
    kept_blobs: usize,
    removed_blobs: usize,
    reclaimed_bytes: u64,
};

pub const OpenOptions = struct {
    budget_bytes: usize = DEFAULT_CACHE_BUDGET,
    entry_overhead: usize = 0,
    pack_seal_bytes: u64 = DEFAULT_PACK_SEAL_BYTES,
};

pub const PackIdxEntry = struct {
    oid: crypto.Hash,
    pack_id: u32,
    flags: u32,
    offset: u64,
    raw_len: u64,
    stored_len: u32,
    crc32c: u32,

    pub fn encode(self: PackIdxEntry) [PACK_IDX_ENTRY_SIZE]u8 {
        var buf: [PACK_IDX_ENTRY_SIZE]u8 = undefined;
        @memcpy(buf[0..32], &self.oid);
        std.mem.writeInt(u32, buf[32..36], self.pack_id, .little);
        std.mem.writeInt(u32, buf[36..40], self.flags, .little);
        std.mem.writeInt(u64, buf[40..48], self.offset, .little);
        std.mem.writeInt(u64, buf[48..56], self.raw_len, .little);
        std.mem.writeInt(u32, buf[56..60], self.stored_len, .little);
        std.mem.writeInt(u32, buf[60..64], self.crc32c, .little);
        return buf;
    }

    pub fn decode(bytes: *const [PACK_IDX_ENTRY_SIZE]u8) PackIdxEntry {
        return .{
            .oid = bytes[0..32].*,
            .pack_id = std.mem.readInt(u32, bytes[32..36], .little),
            .flags = std.mem.readInt(u32, bytes[36..40], .little),
            .offset = std.mem.readInt(u64, bytes[40..48], .little),
            .raw_len = std.mem.readInt(u64, bytes[48..56], .little),
            .stored_len = std.mem.readInt(u32, bytes[56..60], .little),
            .crc32c = std.mem.readInt(u32, bytes[60..64], .little),
        };
    }

    fn lessThan(_: void, a: PackIdxEntry, b: PackIdxEntry) bool {
        return std.mem.order(u8, &a.oid, &b.oid) == .lt;
    }
};

const PackRecordHeader = struct {
    flags: u32,
    oid: crypto.Hash,
    raw_len: u64,
    stored_len: u32,
    crc32c: u32,

    fn encode(self: PackRecordHeader) [PACK_RECORD_HEADER_SIZE]u8 {
        var buf: [PACK_RECORD_HEADER_SIZE]u8 = undefined;
        @memcpy(buf[0..4], &PACK_RECORD_MAGIC);
        std.mem.writeInt(u32, buf[4..8], self.flags, .little);
        @memcpy(buf[8..40], &self.oid);
        std.mem.writeInt(u64, buf[40..48], self.raw_len, .little);
        std.mem.writeInt(u32, buf[48..52], self.stored_len, .little);
        std.mem.writeInt(u32, buf[52..56], self.crc32c, .little);
        return buf;
    }

    fn decode(bytes: *const [PACK_RECORD_HEADER_SIZE]u8) !PackRecordHeader {
        if (!std.mem.eql(u8, bytes[0..4], &PACK_RECORD_MAGIC)) return error.InvalidMagic;
        return .{
            .flags = std.mem.readInt(u32, bytes[4..8], .little),
            .oid = bytes[8..40].*,
            .raw_len = std.mem.readInt(u64, bytes[40..48], .little),
            .stored_len = std.mem.readInt(u32, bytes[48..52], .little),
            .crc32c = std.mem.readInt(u32, bytes[52..56], .little),
        };
    }
};

fn alignUp8(n: usize) usize {
    return (n + (PACK_ALIGN - 1)) & ~(PACK_ALIGN - 1);
}

fn recordCrc(hdr_bytes: *const [PACK_RECORD_HEADER_SIZE]u8, payload: []const u8) u32 {
    var c = std.hash.crc.@"CRC-32/ISCSI".init();
    c.update(hdr_bytes[0..52]);
    c.update(payload);
    return c.final();
}

pub fn packFileName(pack_id: u32, buf: *[20]u8) []const u8 {
    return std.fmt.bufPrint(buf, "pack-{x:08}.0ndp", .{pack_id}) catch unreachable;
}

pub fn parsePackId(name: []const u8) ?u32 {
    if (name.len != 18) return null;
    if (!std.mem.startsWith(u8, name, "pack-")) return null;
    if (!std.mem.endsWith(u8, name, ".0ndp")) return null;
    return std.fmt.parseInt(u32, name[5..13], 16) catch null;
}

fn isTwoHexChars(name: []const u8) bool {
    if (name.len != 2) return false;
    return std.ascii.isHex(name[0]) and std.ascii.isHex(name[1]);
}

fn sliceSize(s: []u8) usize {
    return s.len;
}

fn sliceDeinit(allocator: Allocator, s: *[]u8) void {
    allocator.free(s.*);
}

const BlobLru = lru.LruCache(crypto.Hash, []u8, sliceSize, sliceDeinit);

pub const BlobStore = struct {
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    cache: BlobLru,
    pack_seal_bytes: u64,
    pack_idx_map: ?*mmap.MappedFile,
    pack_idx_entry_count: usize,
    indexed_max_pack_id: u32,
    pack_idx_digest: crypto.Hash,
    sealed_packs: std.AutoHashMapUnmanaged(u32, *mmap.MappedFile),
    active_pack_id: u32,
    active_file: ?Io.File,
    active_write_offset: u64,
    active_index: std.AutoHashMapUnmanaged(crypto.Hash, PackIdxEntry),

    pub fn open(allocator: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, budget: usize) !BlobStore {
        return openWithOptions(allocator, io, parent, sub_path, .{
            .budget_bytes = if (budget == 0) DEFAULT_CACHE_BUDGET else budget,
            .entry_overhead = 0,
            .pack_seal_bytes = DEFAULT_PACK_SEAL_BYTES,
        });
    }

    pub fn openWithOptions(allocator: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, opts: OpenOptions) !BlobStore {
        try parent.createDirPath(io, sub_path);
        const dir = try parent.openDir(io, sub_path, .{ .iterate = true });
        const effective_budget = if (opts.budget_bytes == 0) DEFAULT_CACHE_BUDGET else opts.budget_bytes;
        const effective_seal = if (opts.pack_seal_bytes == 0) DEFAULT_PACK_SEAL_BYTES else opts.pack_seal_bytes;

        var self = BlobStore{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .cache = BlobLru.init(allocator, .{
                .budget_bytes = effective_budget,
                .entry_overhead = opts.entry_overhead,
            }),
            .pack_seal_bytes = effective_seal,
            .pack_idx_map = null,
            .pack_idx_entry_count = 0,
            .indexed_max_pack_id = 0,
            .pack_idx_digest = @splat(0),
            .sealed_packs = .empty,
            .active_pack_id = 1,
            .active_file = null,
            .active_write_offset = 0,
            .active_index = .empty,
        };
        errdefer self.deinit();

        try self.loadAndRecover();
        return self;
    }

    pub fn deinit(self: *BlobStore) void {
        self.cache.deinit();
        if (self.active_file) |f| {
            f.close(self.io);
            self.active_file = null;
        }
        self.active_index.deinit(self.allocator);
        var it = self.sealed_packs.valueIterator();
        while (it.next()) |mf_ptr| {
            mf_ptr.*.release(self.allocator);
        }
        self.sealed_packs.deinit(self.allocator);
        if (self.pack_idx_map) |idx_mf| {
            idx_mf.release(self.allocator);
            self.pack_idx_map = null;
        }
        self.dir.close(self.io);
    }

    pub fn clearCache(self: *BlobStore) void {
        self.cache.clear();
    }

    pub fn hibernate(self: *BlobStore) void {
        self.cache.clear();
        if (self.pack_idx_map) |idx_mf| {
            idx_mf.hibernate();
        }
        var it = self.sealed_packs.valueIterator();
        while (it.next()) |mf_ptr| {
            mf_ptr.*.hibernate();
        }
    }

    pub fn packIdxDigest(self: *const BlobStore) crypto.Hash {
        return self.pack_idx_digest;
    }

    pub fn maxPackId(self: *const BlobStore) u32 {
        if (self.active_file != null and self.active_write_offset > 0) {
            return @max(self.indexed_max_pack_id, self.active_pack_id);
        }
        return self.indexed_max_pack_id;
    }

    fn loadPackIdx(self: *BlobStore) !void {
        const mf = mmap.MappedFile.open(self.allocator, self.io, self.dir, PACK_IDX_NAME) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        errdefer mf.release(self.allocator);

        const data = mf.slice();
        if (data.len < PACK_IDX_ENTRIES_OFFSET) {
            mf.release(self.allocator);
            return;
        }
        if (!std.mem.eql(u8, data[0..8], &PACK_IDX_MAGIC)) {
            mf.release(self.allocator);
            return;
        }
        const version = std.mem.readInt(u32, data[8..12], .little);
        if (version != PACK_IDX_VERSION) {
            mf.release(self.allocator);
            return;
        }
        const max_id = std.mem.readInt(u32, data[12..16], .little);
        const count_u64 = std.mem.readInt(u64, data[16..24], .little);
        const count = std.math.cast(usize, count_u64) orelse {
            mf.release(self.allocator);
            return;
        };
        const expected_size = std.math.add(usize, PACK_IDX_ENTRIES_OFFSET, std.math.mul(usize, count, PACK_IDX_ENTRY_SIZE) catch {
            mf.release(self.allocator);
            return;
        }) catch {
            mf.release(self.allocator);
            return;
        };
        if (data.len != expected_size) {
            mf.release(self.allocator);
            return;
        }

        var h = std.crypto.hash.Blake3.init(.{});
        h.update(data[0..32]);
        h.update(data[PACK_IDX_HEADER_SIZE..]);
        var expected_digest: crypto.Hash = undefined;
        h.final(&expected_digest);
        if (!std.mem.eql(u8, &expected_digest, data[32..64])) {
            mf.release(self.allocator);
            return;
        }

        const total_fanout = std.mem.readInt(u32, data[PACK_IDX_HEADER_SIZE + 255 * 4 .. PACK_IDX_ENTRIES_OFFSET], .little);
        if (total_fanout != count) {
            mf.release(self.allocator);
            return;
        }

        if (self.pack_idx_map) |old| {
            old.release(self.allocator);
        }
        self.pack_idx_map = mf;
        self.pack_idx_entry_count = count;
        self.indexed_max_pack_id = max_id;
        self.pack_idx_digest = expected_digest;
    }

    fn listPackIds(self: *BlobStore, allocator: Allocator) ![]u32 {
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(allocator);

        var it = self.dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (parsePackId(entry.name)) |id| {
                try ids.append(allocator, id);
            }
        }
        std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
        return try ids.toOwnedSlice(allocator);
    }

    fn scanPackFile(self: *BlobStore, pack_id: u32, out_entries: *std.ArrayList(PackIdxEntry)) !u64 {
        var name_buf: [20]u8 = undefined;
        const fname = packFileName(pack_id, &name_buf);

        const mf = try mmap.MappedFile.open(self.allocator, self.io, self.dir, fname);
        defer mf.release(self.allocator);

        const data = mf.slice();
        var offset: usize = 0;
        while (offset + PACK_RECORD_HEADER_SIZE <= data.len) {
            const hdr_ptr: *const [PACK_RECORD_HEADER_SIZE]u8 = @ptrCast(data[offset .. offset + PACK_RECORD_HEADER_SIZE].ptr);
            const hdr = PackRecordHeader.decode(hdr_ptr) catch break;
            const payload_start = offset + PACK_RECORD_HEADER_SIZE;
            const payload_end = std.math.add(usize, payload_start, hdr.stored_len) catch break;
            if (payload_end > data.len) break;
            const payload = data[payload_start..payload_end];
            if (recordCrc(hdr_ptr, payload) != hdr.crc32c) break;
            const aligned_end = alignUp8(payload_end);
            if (aligned_end > data.len) break;

            try out_entries.append(self.allocator, .{
                .oid = hdr.oid,
                .pack_id = pack_id,
                .flags = hdr.flags,
                .offset = offset,
                .raw_len = hdr.raw_len,
                .stored_len = hdr.stored_len,
                .crc32c = hdr.crc32c,
            });
            offset = aligned_end;
        }
        return offset;
    }

    fn loadAndRecover(self: *BlobStore) !void {
        try self.loadPackIdx();

        const pack_ids = try self.listPackIds(self.allocator);
        defer self.allocator.free(pack_ids);

        var unindexed: std.ArrayList(u32) = .empty;
        defer unindexed.deinit(self.allocator);
        for (pack_ids) |id| {
            if (id > self.indexed_max_pack_id) {
                try unindexed.append(self.allocator, id);
            }
        }

        if (unindexed.items.len == 0) {
            self.active_pack_id = self.indexed_max_pack_id + 1;
            return;
        }

        if (unindexed.items.len > 1) {
            var extra_entries: std.ArrayList(PackIdxEntry) = .empty;
            defer extra_entries.deinit(self.allocator);
            var seal_max: u32 = self.indexed_max_pack_id;
            for (unindexed.items[0 .. unindexed.items.len - 1]) |id| {
                _ = try self.scanPackFile(id, &extra_entries);
                if (id > seal_max) seal_max = id;
            }
            try self.writeMergedPackIdx(extra_entries.items, seal_max);
        }

        const last_id = unindexed.items[unindexed.items.len - 1];
        var active_entries: std.ArrayList(PackIdxEntry) = .empty;
        defer active_entries.deinit(self.allocator);
        const valid_len = try self.scanPackFile(last_id, &active_entries);

        var name_buf: [20]u8 = undefined;
        const fname = packFileName(last_id, &name_buf);
        const f = try self.dir.createFile(self.io, fname, .{
            .read = true,
            .truncate = false,
        });
        errdefer f.close(self.io);

        const st = try f.stat(self.io);
        if (st.size > valid_len) {
            try f.setLength(self.io, valid_len);
        }

        self.active_pack_id = last_id;
        self.active_file = f;
        self.active_write_offset = valid_len;
        for (active_entries.items) |e| {
            try self.active_index.put(self.allocator, e.oid, e);
        }
    }

    fn lookupPackIdx(self: *const BlobStore, hash: crypto.Hash) ?PackIdxEntry {
        const mf = self.pack_idx_map orelse return null;
        if (self.pack_idx_entry_count == 0) return null;
        const data = mf.slice();
        const bucket: usize = hash[0];
        const fanout_base = PACK_IDX_HEADER_SIZE;
        const lo_u32: u32 = if (bucket == 0)
            0
        else
            std.mem.readInt(u32, data[fanout_base + (bucket - 1) * 4 ..][0..4], .little);
        const hi_u32: u32 = std.mem.readInt(u32, data[fanout_base + bucket * 4 ..][0..4], .little);

        var lo: usize = lo_u32;
        var hi: usize = hi_u32;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry_off = PACK_IDX_ENTRIES_OFFSET + mid * PACK_IDX_ENTRY_SIZE;
            const entry_oid = data[entry_off .. entry_off + 32];
            switch (std.mem.order(u8, entry_oid, &hash)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const ptr: *const [PACK_IDX_ENTRY_SIZE]u8 = @ptrCast(data[entry_off .. entry_off + PACK_IDX_ENTRY_SIZE].ptr);
                    return PackIdxEntry.decode(ptr);
                },
            }
        }
        return null;
    }

    fn getSealedPackMap(self: *BlobStore, pack_id: u32) !*mmap.MappedFile {
        if (self.sealed_packs.get(pack_id)) |existing| {
            return existing;
        }
        var name_buf: [20]u8 = undefined;
        const fname = packFileName(pack_id, &name_buf);
        const mf = try mmap.MappedFile.open(self.allocator, self.io, self.dir, fname);
        errdefer mf.release(self.allocator);
        try self.sealed_packs.put(self.allocator, pack_id, mf);
        return mf;
    }

    fn ensureActiveFile(self: *BlobStore) !Io.File {
        if (self.active_file) |f| return f;
        var name_buf: [20]u8 = undefined;
        const fname = packFileName(self.active_pack_id, &name_buf);
        const f = try self.dir.createFile(self.io, fname, .{
            .read = true,
            .truncate = false,
        });
        self.active_file = f;
        self.active_write_offset = 0;
        return f;
    }

    fn writePackIdxEntries(self: *BlobStore, entries: []PackIdxEntry, max_pack_id: u32) !void {
        std.mem.sort(PackIdxEntry, entries, {}, PackIdxEntry.lessThan);

        const total_size = PACK_IDX_ENTRIES_OFFSET + entries.len * PACK_IDX_ENTRY_SIZE;
        const buf = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(buf);
        @memset(buf[0..PACK_IDX_HEADER_SIZE], 0);

        @memcpy(buf[0..8], &PACK_IDX_MAGIC);
        std.mem.writeInt(u32, buf[8..12], PACK_IDX_VERSION, .little);
        std.mem.writeInt(u32, buf[12..16], max_pack_id, .little);
        std.mem.writeInt(u64, buf[16..24], entries.len, .little);

        var counts: [256]u32 = @splat(0);
        for (entries) |e| {
            counts[e.oid[0]] += 1;
        }
        var running: u32 = 0;
        for (0..256) |b| {
            running += counts[b];
            std.mem.writeInt(u32, buf[PACK_IDX_HEADER_SIZE + b * 4 ..][0..4], running, .little);
        }

        for (entries, 0..) |e, i| {
            const encoded = e.encode();
            const off = PACK_IDX_ENTRIES_OFFSET + i * PACK_IDX_ENTRY_SIZE;
            @memcpy(buf[off .. off + PACK_IDX_ENTRY_SIZE], &encoded);
        }

        var h = std.crypto.hash.Blake3.init(.{});
        h.update(buf[0..32]);
        h.update(buf[PACK_IDX_HEADER_SIZE..]);
        var digest: crypto.Hash = undefined;
        h.final(&digest);
        @memcpy(buf[32..64], &digest);

        try mmap.atomicWriteFile(self.io, self.dir, PACK_IDX_NAME, buf);
        try self.loadPackIdx();
    }

    fn writeMergedPackIdx(self: *BlobStore, extra: []const PackIdxEntry, new_max_pack_id: u32) !void {
        var dedup: std.AutoHashMapUnmanaged(crypto.Hash, PackIdxEntry) = .empty;
        defer dedup.deinit(self.allocator);
        try dedup.ensureTotalCapacity(self.allocator, @intCast(self.pack_idx_entry_count + extra.len));

        if (self.pack_idx_map) |mf| {
            const data = mf.slice();
            for (0..self.pack_idx_entry_count) |i| {
                const off = PACK_IDX_ENTRIES_OFFSET + i * PACK_IDX_ENTRY_SIZE;
                const ptr: *const [PACK_IDX_ENTRY_SIZE]u8 = @ptrCast(data[off .. off + PACK_IDX_ENTRY_SIZE].ptr);
                const e = PackIdxEntry.decode(ptr);
                dedup.putAssumeCapacity(e.oid, e);
            }
        }
        for (extra) |e| {
            try dedup.put(self.allocator, e.oid, e);
        }

        var merged = try self.allocator.alloc(PackIdxEntry, dedup.count());
        defer self.allocator.free(merged);
        var idx: usize = 0;
        var vit = dedup.valueIterator();
        while (vit.next()) |e| {
            merged[idx] = e.*;
            idx += 1;
        }
        try self.writePackIdxEntries(merged, new_max_pack_id);
    }

    pub fn sealActivePack(self: *BlobStore) !void {
        const f = self.active_file orelse return;
        if (self.active_index.count() == 0) {
            f.close(self.io);
            self.active_file = null;
            self.active_write_offset = 0;
            return;
        }

        try mmap.fdatasyncFile(self.io, f);
        f.close(self.io);
        self.active_file = null;

        const sealed_id = self.active_pack_id;

        var new_entries = try self.allocator.alloc(PackIdxEntry, self.active_index.count());
        defer self.allocator.free(new_entries);
        var i: usize = 0;
        var vit = self.active_index.valueIterator();
        while (vit.next()) |e| {
            new_entries[i] = e.*;
            i += 1;
        }

        const new_max = @max(self.indexed_max_pack_id, sealed_id);
        try self.writeMergedPackIdx(new_entries, new_max);
        _ = try self.getSealedPackMap(sealed_id);

        self.active_index.clearRetainingCapacity();
        self.active_write_offset = 0;
        self.active_pack_id = new_max + 1;
    }

    fn looseBlobPath(hash: crypto.Hash, buf: *[67]u8) []const u8 {
        const hex = std.fmt.bytesToHex(hash, .lower);
        buf[0] = hex[0];
        buf[1] = hex[1];
        buf[2] = '/';
        @memcpy(buf[3..67], &hex);
        return buf[0..67];
    }

    fn looseExists(self: *BlobStore, hash: crypto.Hash) bool {
        var pbuf: [67]u8 = undefined;
        const path = looseBlobPath(hash, &pbuf);
        _ = self.dir.statFile(self.io, path, .{}) catch return false;
        return true;
    }

    fn existsOnDisk(self: *BlobStore, hash: crypto.Hash) bool {
        if (self.active_index.contains(hash)) return true;
        if (self.lookupPackIdx(hash) != null) return true;
        return self.looseExists(hash);
    }

    pub fn put(self: *BlobStore, data: []const u8) !crypto.Hash {
        const h = crypto.hashBytes(data);
        try self.putVerified(h, data);
        return h;
    }

    pub fn putVerified(self: *BlobStore, hash: crypto.Hash, data: []const u8) !void {
        if (self.cache.get(hash) != null) return;
        if (!self.existsOnDisk(hash)) {
            const item = [_]BlobItem{.{
                .hash = hash,
                .data = data,
                .flags = 0,
            }};
            try self.putBatch(&item);
            return;
        }
        try self.cachePut(hash, data);
    }

    pub fn putBatch(self: *BlobStore, items: []const BlobItem) !void {
        if (items.len == 0) return;

        const ResolvedItem = struct {
            hash: crypto.Hash,
            data: []const u8,
            flags: u32,
            write_to_disk: bool,
        };

        var resolved = try self.allocator.alloc(ResolvedItem, items.len);
        defer self.allocator.free(resolved);

        var batch_seen: std.AutoHashMapUnmanaged(crypto.Hash, void) = .empty;
        defer batch_seen.deinit(self.allocator);

        var total_disk_bytes: usize = 0;
        var new_disk_count: usize = 0;

        for (items, 0..) |item, i| {
            const h = item.hash orelse crypto.hashBytes(item.data);
            var need_disk = false;
            if (!batch_seen.contains(h) and !self.existsOnDisk(h)) {
                need_disk = true;
                try batch_seen.put(self.allocator, h, {});
                total_disk_bytes += alignUp8(PACK_RECORD_HEADER_SIZE + item.data.len);
                new_disk_count += 1;
            }
            resolved[i] = .{
                .hash = h,
                .data = item.data,
                .flags = item.flags,
                .write_to_disk = need_disk,
            };
        }

        if (new_disk_count > 0) {
            const f = try self.ensureActiveFile();
            const buf = try self.allocator.alloc(u8, total_disk_bytes);
            defer self.allocator.free(buf);

            var pending_entries: std.ArrayList(PackIdxEntry) = .empty;
            defer pending_entries.deinit(self.allocator);
            try pending_entries.ensureTotalCapacity(self.allocator, new_disk_count);

            const base_offset = self.active_write_offset;
            var pos: usize = 0;

            for (resolved) |r| {
                if (!r.write_to_disk) continue;
                var hdr = PackRecordHeader{
                    .flags = r.flags,
                    .oid = r.hash,
                    .raw_len = r.data.len,
                    .stored_len = @intCast(r.data.len),
                    .crc32c = 0,
                };
                var hdr_bytes = hdr.encode();
                hdr.crc32c = recordCrc(&hdr_bytes, r.data);
                hdr_bytes = hdr.encode();

                const raw_total = PACK_RECORD_HEADER_SIZE + r.data.len;
                const aligned_total = alignUp8(raw_total);
                const pad_len = aligned_total - raw_total;

                @memcpy(buf[pos .. pos + PACK_RECORD_HEADER_SIZE], &hdr_bytes);
                if (r.data.len > 0) {
                    @memcpy(buf[pos + PACK_RECORD_HEADER_SIZE .. pos + raw_total], r.data);
                }
                if (pad_len > 0) {
                    @memset(buf[pos + raw_total .. pos + aligned_total], 0);
                }

                pending_entries.appendAssumeCapacity(.{
                    .oid = r.hash,
                    .pack_id = self.active_pack_id,
                    .flags = r.flags,
                    .offset = base_offset + pos,
                    .raw_len = r.data.len,
                    .stored_len = @intCast(r.data.len),
                    .crc32c = hdr.crc32c,
                });
                pos += aligned_total;
            }

            try self.active_index.ensureUnusedCapacity(self.allocator, @intCast(new_disk_count));
            try f.writePositionalAll(self.io, buf, base_offset);
            try mmap.fdatasyncFile(self.io, f);

            self.active_write_offset = base_offset + total_disk_bytes;
            for (pending_entries.items) |e| {
                self.active_index.putAssumeCapacity(e.oid, e);
            }

            if (self.active_write_offset >= self.pack_seal_bytes) {
                try self.sealActivePack();
            }
        }

        for (resolved) |r| {
            self.cachePut(r.hash, r.data) catch {};
        }
    }

    pub fn isCached(self: *const BlobStore, hash: crypto.Hash) bool {
        return self.cache.contains(hash);
    }

    pub fn exists(self: *BlobStore, hash: crypto.Hash) bool {
        if (self.cache.contains(hash)) return true;
        return self.existsOnDisk(hash);
    }

    fn readFromActivePack(self: *BlobStore, allocator: Allocator, hash: crypto.Hash, entry: PackIdxEntry) ![]u8 {
        const f = self.active_file orelse return error.CorruptBlob;
        const total = PACK_RECORD_HEADER_SIZE + entry.stored_len;
        const raw = try self.allocator.alloc(u8, total);
        defer self.allocator.free(raw);

        const n = try f.readPositionalAll(self.io, raw, entry.offset);
        if (n != total) return error.UnexpectedEof;

        const hdr_ptr: *const [PACK_RECORD_HEADER_SIZE]u8 = @ptrCast(raw[0..PACK_RECORD_HEADER_SIZE].ptr);
        const hdr = PackRecordHeader.decode(hdr_ptr) catch return error.CorruptBlob;
        if (!std.mem.eql(u8, &hdr.oid, &hash)) return error.CorruptBlob;
        if (hdr.stored_len != entry.stored_len) return error.CorruptBlob;

        const payload = raw[PACK_RECORD_HEADER_SIZE..total];
        if (recordCrc(hdr_ptr, payload) != hdr.crc32c) return error.CorruptBlob;
        const actual = crypto.hashBytes(payload);
        if (!std.mem.eql(u8, &actual, &hash)) return error.CorruptBlob;

        return try allocator.dupe(u8, payload);
    }

    fn readFromSealedPack(self: *BlobStore, allocator: Allocator, hash: crypto.Hash, entry: PackIdxEntry) ![]u8 {
        const mf = try self.getSealedPackMap(entry.pack_id);
        const total: u64 = PACK_RECORD_HEADER_SIZE + @as(u64, entry.stored_len);
        const raw = mf.sliceCheckedU64(entry.offset, total) catch return error.CorruptBlob;

        const hdr_ptr: *const [PACK_RECORD_HEADER_SIZE]u8 = @ptrCast(raw[0..PACK_RECORD_HEADER_SIZE].ptr);
        const hdr = PackRecordHeader.decode(hdr_ptr) catch return error.CorruptBlob;
        if (!std.mem.eql(u8, &hdr.oid, &hash)) return error.CorruptBlob;
        if (hdr.stored_len != entry.stored_len) return error.CorruptBlob;

        const payload = raw[PACK_RECORD_HEADER_SIZE..];
        if (recordCrc(hdr_ptr, payload) != hdr.crc32c) return error.CorruptBlob;
        const actual = crypto.hashBytes(payload);
        if (!std.mem.eql(u8, &actual, &hash)) return error.CorruptBlob;

        return try allocator.dupe(u8, payload);
    }

    fn readFromLoose(self: *BlobStore, allocator: Allocator, hash: crypto.Hash) !?[]u8 {
        var pbuf: [67]u8 = undefined;
        const path = looseBlobPath(hash, &pbuf);
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
        return buf;
    }

    pub fn get(self: *BlobStore, allocator: Allocator, hash: crypto.Hash) !?[]u8 {
        if (self.cache.get(hash)) |cached_ptr| {
            return try allocator.dupe(u8, cached_ptr.*);
        }

        if (self.active_index.get(hash)) |entry| {
            const buf = try self.readFromActivePack(allocator, hash, entry);
            self.cachePut(hash, buf) catch {};
            return buf;
        }

        if (self.lookupPackIdx(hash)) |entry| {
            const buf = try self.readFromSealedPack(allocator, hash, entry);
            self.cachePut(hash, buf) catch {};
            return buf;
        }

        if (try self.readFromLoose(allocator, hash)) |buf| {
            self.cachePut(hash, buf) catch {};
            return buf;
        }

        return null;
    }

    fn gitFallbackRelPath(allocator: Allocator, git_oid: []const u8) ![]u8 {
        const out = try allocator.alloc(u8, 4 + git_oid.len * 2);
        @memcpy(out[0..4], "git/");
        const hex_chars = "0123456789abcdef";
        for (git_oid, 0..) |b, i| {
            out[4 + i * 2] = hex_chars[b >> 4];
            out[4 + i * 2 + 1] = hex_chars[b & 0x0f];
        }
        return out;
    }

    pub fn putGitFallback(self: *BlobStore, git_oid: []const u8, data: []const u8) !void {
        if (git_oid.len == 0) return error.InvalidGitOid;
        const rel = try gitFallbackRelPath(self.allocator, git_oid);
        defer self.allocator.free(rel);
        try mmap.atomicWriteFile(self.io, self.dir, rel, data);
    }

    pub fn getGitFallback(self: *BlobStore, allocator: Allocator, git_oid: []const u8) !?[]u8 {
        if (git_oid.len == 0) return null;
        const rel = try gitFallbackRelPath(self.allocator, git_oid);
        defer self.allocator.free(rel);

        const f = self.dir.openFile(self.io, rel, .{}) catch |err| switch (err) {
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
        return buf;
    }

    const LooseFileInfo = struct {
        hash: crypto.Hash,
        rel_path: []u8,
        size: u64,
    };

    fn collectLooseFiles(self: *BlobStore, out: *std.ArrayList(LooseFileInfo)) !void {
        var it = self.dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!isTwoHexChars(entry.name)) continue;

            var sub = self.dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(self.io);

            var sub_it = sub.iterate();
            while (try sub_it.next(self.io)) |sub_entry| {
                if (sub_entry.kind != .file) continue;
                if (sub_entry.name.len != 64) continue;
                var hash: crypto.Hash = undefined;
                _ = std.fmt.hexToBytes(&hash, sub_entry.name) catch continue;
                const st = sub.statFile(self.io, sub_entry.name, .{}) catch continue;
                const rel = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ entry.name, sub_entry.name });
                errdefer self.allocator.free(rel);
                try out.append(self.allocator, .{
                    .hash = hash,
                    .rel_path = rel,
                    .size = st.size,
                });
            }
        }
    }

    pub fn gc(self: *BlobStore, live_oids: *const std.AutoHashMapUnmanaged(crypto.Hash, void)) !GcStats {
        const old_pack_ids = try self.listPackIds(self.allocator);
        defer self.allocator.free(old_pack_ids);

        var bytes_before: u64 = 0;
        var max_old_pack_id: u32 = self.indexed_max_pack_id;
        for (old_pack_ids) |id| {
            if (id > max_old_pack_id) max_old_pack_id = id;
            var name_buf: [20]u8 = undefined;
            const fname = packFileName(id, &name_buf);
            if (self.dir.statFile(self.io, fname, .{})) |st| {
                bytes_before += st.size;
            } else |_| {}
        }

        var loose_files: std.ArrayList(LooseFileInfo) = .empty;
        defer {
            for (loose_files.items) |lf| self.allocator.free(lf.rel_path);
            loose_files.deinit(self.allocator);
        }
        try self.collectLooseFiles(&loose_files);
        for (loose_files.items) |lf| {
            bytes_before += lf.size;
        }

        const BlobSource = union(enum) {
            active: PackIdxEntry,
            sealed: PackIdxEntry,
            loose: void,
        };

        var all_blobs: std.AutoHashMapUnmanaged(crypto.Hash, BlobSource) = .empty;
        defer all_blobs.deinit(self.allocator);

        if (self.pack_idx_map) |mf| {
            const data = mf.slice();
            for (0..self.pack_idx_entry_count) |i| {
                const off = PACK_IDX_ENTRIES_OFFSET + i * PACK_IDX_ENTRY_SIZE;
                const ptr: *const [PACK_IDX_ENTRY_SIZE]u8 = @ptrCast(data[off .. off + PACK_IDX_ENTRY_SIZE].ptr);
                const e = PackIdxEntry.decode(ptr);
                try all_blobs.put(self.allocator, e.oid, .{ .sealed = e });
            }
        }

        var ait = self.active_index.iterator();
        while (ait.next()) |kv| {
            try all_blobs.put(self.allocator, kv.key_ptr.*, .{ .active = kv.value_ptr.* });
        }

        for (loose_files.items) |lf| {
            if (!all_blobs.contains(lf.hash)) {
                try all_blobs.put(self.allocator, lf.hash, .loose);
            }
        }

        var kept_blobs: usize = 0;
        var removed_blobs: usize = 0;

        var new_entries: std.ArrayList(PackIdxEntry) = .empty;
        defer new_entries.deinit(self.allocator);

        var new_pack_ids: std.ArrayList(u32) = .empty;
        defer new_pack_ids.deinit(self.allocator);

        var cur_pack_id: u32 = max_old_pack_id + 1;
        var cur_pack_file: ?Io.File = null;
        var cur_pack_off: u64 = 0;
        errdefer if (cur_pack_file) |f| f.close(self.io);

        var bit = all_blobs.iterator();
        while (bit.next()) |kv| {
            const oid = kv.key_ptr.*;
            if (!live_oids.contains(oid)) {
                removed_blobs += 1;
                continue;
            }

            const payload_opt: ?[]u8 = switch (kv.value_ptr.*) {
                .active => |e| try self.readFromActivePack(self.allocator, oid, e),
                .sealed => |e| try self.readFromSealedPack(self.allocator, oid, e),
                .loose => try self.readFromLoose(self.allocator, oid),
            };
            const payload = payload_opt orelse continue;
            defer self.allocator.free(payload);

            const flags: u32 = switch (kv.value_ptr.*) {
                .active => |e| e.flags,
                .sealed => |e| e.flags,
                .loose => 0,
            };

            if (cur_pack_file == null) {
                var name_buf: [20]u8 = undefined;
                const fname = packFileName(cur_pack_id, &name_buf);
                cur_pack_file = try self.dir.createFile(self.io, fname, .{
                    .read = true,
                    .truncate = true,
                });
                cur_pack_off = 0;
                try new_pack_ids.append(self.allocator, cur_pack_id);
            }

            var hdr = PackRecordHeader{
                .flags = flags,
                .oid = oid,
                .raw_len = payload.len,
                .stored_len = @intCast(payload.len),
                .crc32c = 0,
            };
            var hdr_bytes = hdr.encode();
            hdr.crc32c = recordCrc(&hdr_bytes, payload);
            hdr_bytes = hdr.encode();

            const raw_total = PACK_RECORD_HEADER_SIZE + payload.len;
            const aligned_total = alignUp8(raw_total);
            const pad_len = aligned_total - raw_total;

            const rec_buf = try self.allocator.alloc(u8, aligned_total);
            defer self.allocator.free(rec_buf);
            @memcpy(rec_buf[0..PACK_RECORD_HEADER_SIZE], &hdr_bytes);
            if (payload.len > 0) {
                @memcpy(rec_buf[PACK_RECORD_HEADER_SIZE..raw_total], payload);
            }
            if (pad_len > 0) {
                @memset(rec_buf[raw_total..aligned_total], 0);
            }

            try cur_pack_file.?.writePositionalAll(self.io, rec_buf, cur_pack_off);
            try new_entries.append(self.allocator, .{
                .oid = oid,
                .pack_id = cur_pack_id,
                .flags = flags,
                .offset = cur_pack_off,
                .raw_len = payload.len,
                .stored_len = @intCast(payload.len),
                .crc32c = hdr.crc32c,
            });
            cur_pack_off += aligned_total;
            kept_blobs += 1;

            if (cur_pack_off >= self.pack_seal_bytes) {
                try mmap.fdatasyncFile(self.io, cur_pack_file.?);
                cur_pack_file.?.close(self.io);
                cur_pack_file = null;
                cur_pack_id += 1;
                cur_pack_off = 0;
            }
        }

        if (cur_pack_file) |f| {
            try mmap.fdatasyncFile(self.io, f);
            f.close(self.io);
            cur_pack_file = null;
        }

        const new_max_pack_id: u32 = if (new_pack_ids.items.len > 0)
            new_pack_ids.items[new_pack_ids.items.len - 1]
        else
            max_old_pack_id;

        try self.writePackIdxEntries(new_entries.items, new_max_pack_id);

        if (self.active_file) |f| {
            f.close(self.io);
            self.active_file = null;
        }
        self.active_index.clearRetainingCapacity();
        self.active_write_offset = 0;
        self.active_pack_id = new_max_pack_id + 1;

        for (old_pack_ids) |id| {
            if (self.sealed_packs.fetchRemove(id)) |kv| {
                kv.value.release(self.allocator);
            }
            var name_buf: [20]u8 = undefined;
            const fname = packFileName(id, &name_buf);
            self.dir.deleteFile(self.io, fname) catch {};
        }

        for (loose_files.items) |lf| {
            self.dir.deleteFile(self.io, lf.rel_path) catch {};
        }

        try mmap.fsyncDir(self.io, self.dir);
        self.clearCache();

        var bytes_after: u64 = 0;
        for (new_pack_ids.items) |id| {
            var name_buf: [20]u8 = undefined;
            const fname = packFileName(id, &name_buf);
            if (self.dir.statFile(self.io, fname, .{})) |st| {
                bytes_after += st.size;
            } else |_| {}
        }

        return .{
            .kept_blobs = kept_blobs,
            .removed_blobs = removed_blobs,
            .reclaimed_bytes = if (bytes_before > bytes_after) bytes_before - bytes_after else 0,
        };
    }

    fn cachePut(self: *BlobStore, hash: crypto.Hash, data: []const u8) !void {
        if (data.len + self.cache.entry_overhead > self.cache.budget_bytes) return;
        if (self.cache.get(hash) != null) return;
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);
        _ = try self.cache.put(hash, owned);
    }
};

pub const SharedBlobPool = struct {
    allocator: Allocator,
    io: Io,
    mu: Io.Mutex,
    refcount: std.atomic.Value(u32),
    store: BlobStore,

    pub fn open(
        allocator: Allocator,
        io: Io,
        parent: Io.Dir,
        sub_path: []const u8,
        budget: usize,
    ) !*SharedBlobPool {
        const pool = try allocator.create(SharedBlobPool);
        errdefer allocator.destroy(pool);

        const store = try BlobStore.openWithOptions(allocator, io, parent, sub_path, .{
            .budget_bytes = if (budget == 0) DEFAULT_CACHE_BUDGET else budget,
            .entry_overhead = ENTRY_OVERHEAD,
            .pack_seal_bytes = DEFAULT_PACK_SEAL_BYTES,
        });

        pool.* = .{
            .allocator = allocator,
            .io = io,
            .mu = Io.Mutex.init,
            .refcount = .init(1),
            .store = store,
        };
        return pool;
    }

    pub fn retain(self: *SharedBlobPool) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    pub fn refCount(self: *const SharedBlobPool) u32 {
        return self.refcount.load(.acquire);
    }

    pub fn release(self: *SharedBlobPool) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) {
            const alloc = self.allocator;
            self.store.deinit();
            alloc.destroy(self);
        }
    }

    pub fn put(self: *SharedBlobPool, data: []const u8) !crypto.Hash {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.store.put(data);
    }

    pub fn putVerified(self: *SharedBlobPool, hash: crypto.Hash, data: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.store.putVerified(hash, data);
    }

    pub fn putBatch(self: *SharedBlobPool, items: []const BlobItem) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.store.putBatch(items);
    }

    pub fn get(self: *SharedBlobPool, allocator: Allocator, hash: crypto.Hash) !?[]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.store.get(allocator, hash);
    }

    pub fn exists(self: *SharedBlobPool, hash: crypto.Hash) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.store.exists(hash);
    }

    pub fn isCached(self: *SharedBlobPool, hash: crypto.Hash) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.store.isCached(hash);
    }

    pub fn putGitFallback(self: *SharedBlobPool, git_oid: []const u8, data: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.store.putGitFallback(git_oid, data);
    }

    pub fn getGitFallback(self: *SharedBlobPool, allocator: Allocator, git_oid: []const u8) !?[]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.store.getGitFallback(allocator, git_oid);
    }

    pub fn sealActivePack(self: *SharedBlobPool) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.store.sealActivePack();
    }

    pub fn gc(self: *SharedBlobPool, live_oids: *const std.AutoHashMapUnmanaged(crypto.Hash, void)) !GcStats {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.store.gc(live_oids);
    }

    pub fn clearCache(self: *SharedBlobPool) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.store.clearCache();
    }

    pub fn hibernate(self: *SharedBlobPool) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.store.hibernate();
    }

    pub fn cacheUsedBytes(self: *SharedBlobPool) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.store.cache.used_bytes;
    }
};
