const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const flate = std.compress.flate;
const Adler32 = std.hash.Adler32;
const git_dirs = @import("git_dirs.zig");
const git_index = @import("git_index.zig");
const ObjectFormat = git_dirs.ObjectFormat;
const GitOid = git_dirs.GitOid;

pub const MAX_DELTA_DEPTH: usize = 128;
pub const MAX_ALTERNATES_DEPTH: usize = 5;
pub const DEFAULT_DELTA_CACHE_BUDGET: usize = 8 * 1024 * 1024;
pub const DEFAULT_BLOB_CACHE_BUDGET: usize = 32 * 1024 * 1024;
pub const DEFAULT_PIN_REF: []const u8 = "refs/0ndb/pin";

pub const OdbError = error{
    CorruptPack,
    CorruptIdx,
    CorruptMidx,
    CorruptLooseObject,
    CorruptDelta,
    InvalidZlibStream,
    Adler32Mismatch,
    DeltaChainTooDeep,
    NotABlob,
    MissingBaseObject,
    RefLockHeld,
    UpdateRefFailed,
    ObjectTooLarge,
};

pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,

    pub fn name(self: ObjectType) []const u8 {
        return switch (self) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
            .ofs_delta => "ofs_delta",
            .ref_delta => "ref_delta",
        };
    }

    pub fn fromName(s: []const u8) ?ObjectType {
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return null;
    }

    pub fn fromPackBits(bits: u3) ?ObjectType {
        return switch (bits) {
            1 => .commit,
            2 => .tree,
            3 => .blob,
            4 => .tag,
            6 => .ofs_delta,
            7 => .ref_delta,
            else => null,
        };
    }
};

pub const GitObject = struct {
    kind: ObjectType,
    data: []u8,

    pub fn deinit(self: *GitObject, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

const MmapSlice = struct {
    mem: []align(std.heap.page_size_min) u8,

    fn open(io: Io, dir: Io.Dir, sub_path: []const u8) !?MmapSlice {
        const f = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer f.close(io);

        const st = try f.stat(io);
        if (st.kind != .file or st.size == 0) return null;
        const len: usize = std.math.cast(usize, st.size) orelse return error.ObjectTooLarge;
        const mapped = try posix.mmap(
            null,
            len,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            f.handle,
            0,
        );
        return .{ .mem = mapped };
    }

    fn deinit(self: MmapSlice) void {
        if (self.mem.len > 0) posix.munmap(self.mem);
    }

    fn adviseDontNeed(self: MmapSlice) void {
        if (self.mem.len > 0) {
            posix.madvise(self.mem.ptr, self.mem.len, posix.MADV.DONTNEED) catch {};
        }
    }
};

const PackFile = struct {
    idx_name: []u8,
    idx_map: ?MmapSlice,
    pack_map: MmapSlice,
    total_objects: u32,
    oid_table_off: usize,
    off32_table_off: usize,
    off64_table_off: usize,
    off64_count: usize,
    hash_len: usize,
    in_midx: bool,

    fn deinit(self: *PackFile, allocator: Allocator) void {
        allocator.free(self.idx_name);
        if (self.idx_map) |m| m.deinit();
        self.pack_map.deinit();
    }

    fn adviseDontNeed(self: *const PackFile) void {
        if (self.idx_map) |m| m.adviseDontNeed();
        self.pack_map.adviseDontNeed();
    }

    fn loadFromIdx(allocator: Allocator, io: Io, pack_dir: Io.Dir, idx_name: []const u8, format: ObjectFormat) !?PackFile {
        if (!std.mem.endsWith(u8, idx_name, ".idx")) return null;
        const stem = idx_name[0 .. idx_name.len - 4];
        const pack_name = try std.fmt.allocPrint(allocator, "{s}.pack", .{stem});
        defer allocator.free(pack_name);

        const idx_map = (try MmapSlice.open(io, pack_dir, idx_name)) orelse return null;
        errdefer idx_map.deinit();

        const hash_len = format.byteLen();
        const raw = idx_map.mem;
        if (raw.len < 8 + 256 * 4 + 2 * hash_len) return null;
        if (!std.mem.eql(u8, raw[0..4], "\xfftOc")) return null;
        if (std.mem.readInt(u32, raw[4..8], .big) != 2) return null;

        var prev: u32 = 0;
        for (0..256) |i| {
            const v = std.mem.readInt(u32, raw[8 + i * 4 ..][0..4], .big);
            if (v < prev) return null;
            prev = v;
        }
        const total = prev;
        const oid_off: usize = 8 + 256 * 4;
        const total_usize: usize = total;
        const crc_off = std.math.add(usize, oid_off, std.math.mul(usize, total_usize, hash_len) catch return null) catch return null;
        const off32_off = std.math.add(usize, crc_off, std.math.mul(usize, total_usize, 4) catch return null) catch return null;
        const off64_off = std.math.add(usize, off32_off, std.math.mul(usize, total_usize, 4) catch return null) catch return null;
        const footer_bytes = 2 * hash_len;
        if (off64_off + footer_bytes > raw.len) return null;
        const off64_bytes = raw.len - footer_bytes - off64_off;
        if (off64_bytes % 8 != 0) return null;

        const pack_map = (try MmapSlice.open(io, pack_dir, pack_name)) orelse return null;
        errdefer pack_map.deinit();
        if (!validatePackHeader(pack_map.mem)) return null;

        const owned_name = try allocator.dupe(u8, idx_name);
        return .{
            .idx_name = owned_name,
            .idx_map = idx_map,
            .pack_map = pack_map,
            .total_objects = total,
            .oid_table_off = oid_off,
            .off32_table_off = off32_off,
            .off64_table_off = off64_off,
            .off64_count = off64_bytes / 8,
            .hash_len = hash_len,
            .in_midx = false,
        };
    }

    fn loadPackOnly(allocator: Allocator, io: Io, pack_dir: Io.Dir, idx_name: []const u8, format: ObjectFormat) !?PackFile {
        if (!std.mem.endsWith(u8, idx_name, ".idx")) return null;
        const stem = idx_name[0 .. idx_name.len - 4];
        const pack_name = try std.fmt.allocPrint(allocator, "{s}.pack", .{stem});
        defer allocator.free(pack_name);

        const pack_map = (try MmapSlice.open(io, pack_dir, pack_name)) orelse return null;
        errdefer pack_map.deinit();
        if (!validatePackHeader(pack_map.mem)) return null;

        const owned_name = try allocator.dupe(u8, idx_name);
        return .{
            .idx_name = owned_name,
            .idx_map = null,
            .pack_map = pack_map,
            .total_objects = 0,
            .oid_table_off = 0,
            .off32_table_off = 0,
            .off64_table_off = 0,
            .off64_count = 0,
            .hash_len = format.byteLen(),
            .in_midx = false,
        };
    }

    fn findOffset(self: *const PackFile, oid: GitOid) ?u64 {
        const idx_map = self.idx_map orelse return null;
        if (oid.len != self.hash_len or self.total_objects == 0) return null;
        const raw = idx_map.mem;
        const first: usize = oid.bytes[0];
        const lo_u32: u32 = if (first == 0) 0 else std.mem.readInt(u32, raw[8 + (first - 1) * 4 ..][0..4], .big);
        const hi_u32: u32 = std.mem.readInt(u32, raw[8 + first * 4 ..][0..4], .big);

        var lo: usize = lo_u32;
        var hi: usize = hi_u32;
        const target = oid.slice();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry_off = self.oid_table_off + mid * self.hash_len;
            const cur = raw[entry_off .. entry_off + self.hash_len];
            switch (std.mem.order(u8, cur, target)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const o32 = std.mem.readInt(u32, raw[self.off32_table_off + mid * 4 ..][0..4], .big);
                    if ((o32 & 0x80000000) == 0) {
                        return @as(u64, o32);
                    }
                    const large_idx: usize = o32 & 0x7fffffff;
                    if (large_idx >= self.off64_count) return null;
                    return std.mem.readInt(u64, raw[self.off64_table_off + large_idx * 8 ..][0..8], .big);
                },
            }
        }
        return null;
    }
};

fn validatePackHeader(raw: []const u8) bool {
    if (raw.len < 12) return false;
    if (!std.mem.eql(u8, raw[0..4], "PACK")) return false;
    const ver = std.mem.readInt(u32, raw[4..8], .big);
    return ver == 2 or ver == 3;
}

const MidxMatch = struct {
    pack_idx: usize,
    offset: u64,
};

const MidxIndex = struct {
    map: MmapSlice,
    hash_len: usize,
    oidf_off: usize,
    oidl_off: usize,
    ooff_off: usize,
    loff_off: ?usize,
    loff_len: usize,
    total_objects: u32,
    pack_map: []usize,

    fn deinit(self: *MidxIndex, allocator: Allocator) void {
        allocator.free(self.pack_map);
        self.map.deinit();
    }

    fn adviseDontNeed(self: *const MidxIndex) void {
        self.map.adviseDontNeed();
    }

    fn load(
        allocator: Allocator,
        io: Io,
        pack_dir: Io.Dir,
        packs: *std.ArrayList(PackFile),
        format: ObjectFormat,
    ) !?MidxIndex {
        const map = (try MmapSlice.open(io, pack_dir, "multi-pack-index")) orelse return null;
        errdefer map.deinit();

        const raw = map.mem;
        if (raw.len < 12) return null;
        if (!std.mem.eql(u8, raw[0..4], "MIDX")) return null;
        if (raw[4] != 1) return null;
        const expected_hash_ver: u8 = switch (format) {
            .sha1 => 1,
            .sha256 => 2,
        };
        if (raw[5] != expected_hash_ver) return null;
        const chunk_count: usize = raw[6];
        const base_count: usize = raw[7];
        if (base_count != 0 or chunk_count == 0) return null;
        const pack_count: usize = std.mem.readInt(u32, raw[8..12], .big);
        if (pack_count == 0) return null;

        const toc_end = 12 + (chunk_count + 1) * 12;
        if (toc_end > raw.len) return null;

        var pnam_off: ?usize = null;
        var pnam_len: usize = 0;
        var oidf_off: ?usize = null;
        var oidf_len: usize = 0;
        var oidl_off: ?usize = null;
        var oidl_len: usize = 0;
        var ooff_off: ?usize = null;
        var ooff_len: usize = 0;
        var loff_off: ?usize = null;
        var loff_len: usize = 0;

        for (0..chunk_count) |i| {
            const entry_pos = 12 + i * 12;
            const id = raw[entry_pos .. entry_pos + 4];
            const c_off_u64 = std.mem.readInt(u64, raw[entry_pos + 4 ..][0..8], .big);
            const next_off_u64 = std.mem.readInt(u64, raw[entry_pos + 16 ..][0..8], .big);
            if (next_off_u64 < c_off_u64 or next_off_u64 > raw.len) return null;
            const c_off: usize = @intCast(c_off_u64);
            const c_len: usize = @intCast(next_off_u64 - c_off_u64);

            if (std.mem.eql(u8, id, "PNAM")) {
                pnam_off = c_off;
                pnam_len = c_len;
            } else if (std.mem.eql(u8, id, "OIDF")) {
                oidf_off = c_off;
                oidf_len = c_len;
            } else if (std.mem.eql(u8, id, "OIDL")) {
                oidl_off = c_off;
                oidl_len = c_len;
            } else if (std.mem.eql(u8, id, "OOFF")) {
                ooff_off = c_off;
                ooff_len = c_len;
            } else if (std.mem.eql(u8, id, "LOFF")) {
                loff_off = c_off;
                loff_len = c_len;
            }
        }

        const pnam_s = pnam_off orelse return null;
        const oidf_s = oidf_off orelse return null;
        const oidl_s = oidl_off orelse return null;
        const ooff_s = ooff_off orelse return null;
        if (oidf_len != 256 * 4) return null;

        var prev: u32 = 0;
        for (0..256) |i| {
            const v = std.mem.readInt(u32, raw[oidf_s + i * 4 ..][0..4], .big);
            if (v < prev) return null;
            prev = v;
        }
        const total = prev;
        const hash_len = format.byteLen();
        if (oidl_len < @as(usize, total) * hash_len) return null;
        if (ooff_len < @as(usize, total) * 8) return null;

        const pack_map = try allocator.alloc(usize, pack_count);
        errdefer allocator.free(pack_map);

        const pnam_slice = raw[pnam_s .. pnam_s + pnam_len];
        var ppos: usize = 0;
        for (0..pack_count) |pi| {
            const nul_rel = std.mem.indexOfScalar(u8, pnam_slice[ppos..], 0) orelse return null;
            const pname = pnam_slice[ppos .. ppos + nul_rel];
            ppos += nul_rel + 1;

            var found_idx: ?usize = null;
            for (packs.items, 0..) |*pk, idx| {
                if (std.mem.eql(u8, pk.idx_name, pname)) {
                    found_idx = idx;
                    break;
                }
            }
            if (found_idx == null) {
                if (try PackFile.loadPackOnly(allocator, io, pack_dir, pname, format)) |pk| {
                    try packs.append(allocator, pk);
                    found_idx = packs.items.len - 1;
                } else {
                    return null;
                }
            }
            pack_map[pi] = found_idx.?;
        }

        for (pack_map) |idx| {
            packs.items[idx].in_midx = true;
        }

        return .{
            .map = map,
            .hash_len = hash_len,
            .oidf_off = oidf_s,
            .oidl_off = oidl_s,
            .ooff_off = ooff_s,
            .loff_off = loff_off,
            .loff_len = loff_len,
            .total_objects = total,
            .pack_map = pack_map,
        };
    }

    fn find(self: *const MidxIndex, oid: GitOid) ?MidxMatch {
        if (oid.len != self.hash_len or self.total_objects == 0) return null;
        const raw = self.map.mem;
        const first: usize = oid.bytes[0];
        const lo_u32: u32 = if (first == 0) 0 else std.mem.readInt(u32, raw[self.oidf_off + (first - 1) * 4 ..][0..4], .big);
        const hi_u32: u32 = std.mem.readInt(u32, raw[self.oidf_off + first * 4 ..][0..4], .big);

        var lo: usize = lo_u32;
        var hi: usize = hi_u32;
        const target = oid.slice();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const oid_pos = self.oidl_off + mid * self.hash_len;
            switch (std.mem.order(u8, raw[oid_pos .. oid_pos + self.hash_len], target)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    const ooff_pos = self.ooff_off + mid * 8;
                    const midx_pack_id = std.mem.readInt(u32, raw[ooff_pos..][0..4], .big);
                    const off32 = std.mem.readInt(u32, raw[ooff_pos + 4 ..][0..4], .big);
                    if (midx_pack_id >= self.pack_map.len) return null;
                    const pack_idx = self.pack_map[midx_pack_id];
                    if ((off32 & 0x80000000) == 0) {
                        return .{ .pack_idx = pack_idx, .offset = off32 };
                    }
                    const loff_s = self.loff_off orelse return null;
                    const large_idx: usize = off32 & 0x7fffffff;
                    if ((large_idx + 1) * 8 > self.loff_len) return null;
                    const off64 = std.mem.readInt(u64, raw[loff_s + large_idx * 8 ..][0..8], .big);
                    return .{ .pack_idx = pack_idx, .offset = off64 };
                },
            }
        }
        return null;
    }
};

const DirStamp = struct {
    exists: bool = false,
    mtime_ns: i96 = 0,
    ctime_ns: i96 = 0,

    fn eql(a: DirStamp, b: DirStamp) bool {
        return a.exists == b.exists and a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
    }
};

const ObjectStore = struct {
    objects_dir: []u8,
    packs: std.ArrayList(PackFile),
    midx: ?MidxIndex,
    pack_dir_stamp: DirStamp,

    fn init(allocator: Allocator, io: Io, objects_dir_path: []const u8, format: ObjectFormat) !ObjectStore {
        const owned = try allocator.dupe(u8, objects_dir_path);
        errdefer allocator.free(owned);
        var store = ObjectStore{
            .objects_dir = owned,
            .packs = .empty,
            .midx = null,
            .pack_dir_stamp = .{},
        };
        errdefer store.deinit(allocator);
        try store.reloadPacks(allocator, io, format);
        return store;
    }

    fn deinit(self: *ObjectStore, allocator: Allocator) void {
        self.clearPacks(allocator);
        self.packs.deinit(allocator);
        allocator.free(self.objects_dir);
    }

    fn clearPacks(self: *ObjectStore, allocator: Allocator) void {
        if (self.midx) |*m| {
            m.deinit(allocator);
            self.midx = null;
        }
        for (self.packs.items) |*p| p.deinit(allocator);
        self.packs.clearRetainingCapacity();
    }

    fn adviseDontNeed(self: *const ObjectStore) void {
        if (self.midx) |*m| m.adviseDontNeed();
        for (self.packs.items) |*p| p.adviseDontNeed();
    }

    fn statPackDir(self: *const ObjectStore, io: Io) DirStamp {
        var obj_dir = Io.Dir.cwd().openDir(io, self.objects_dir, .{}) catch return .{};
        defer obj_dir.close(io);
        const st = obj_dir.statFile(io, "pack", .{}) catch return .{};
        if (st.kind != .directory) return .{};
        return .{
            .exists = true,
            .mtime_ns = st.mtime.nanoseconds,
            .ctime_ns = st.ctime.nanoseconds,
        };
    }

    fn reloadPacks(self: *ObjectStore, allocator: Allocator, io: Io, format: ObjectFormat) !void {
        self.clearPacks(allocator);
        self.pack_dir_stamp = self.statPackDir(io);
        if (!self.pack_dir_stamp.exists) return;

        var obj_dir = Io.Dir.cwd().openDir(io, self.objects_dir, .{}) catch return;
        defer obj_dir.close(io);
        var pack_dir = obj_dir.openDir(io, "pack", .{ .iterate = true }) catch return;
        defer pack_dir.close(io);

        var it = pack_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "pack-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            if (PackFile.loadFromIdx(allocator, io, pack_dir, entry.name, format) catch null) |pk| {
                try self.packs.append(allocator, pk);
            }
        }

        if (MidxIndex.load(allocator, io, pack_dir, &self.packs, format) catch null) |m| {
            self.midx = m;
        }
    }

    fn refreshIfChanged(self: *ObjectStore, allocator: Allocator, io: Io, format: ObjectFormat) !bool {
        const cur = self.statPackDir(io);
        if (cur.eql(self.pack_dir_stamp)) return false;
        try self.reloadPacks(allocator, io, format);
        return true;
    }

    fn findInPacks(self: *const ObjectStore, oid: GitOid) ?MidxMatch {
        if (self.midx) |*m| {
            if (m.find(oid)) |hit| return hit;
        }
        for (self.packs.items, 0..) |*pk, idx| {
            if (pk.in_midx) continue;
            if (pk.findOffset(oid)) |off| {
                return .{ .pack_idx = idx, .offset = off };
            }
        }
        return null;
    }

    fn hasLoose(self: *const ObjectStore, io: Io, oid: GitOid) bool {
        var hex_buf: [64]u8 = undefined;
        const hex = oid.toHex(&hex_buf);
        var rel_buf: [72]u8 = undefined;
        const rel = std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ hex[0..2], hex[2..] }) catch return false;
        var obj_dir = Io.Dir.cwd().openDir(io, self.objects_dir, .{}) catch return false;
        defer obj_dir.close(io);
        _ = obj_dir.statFile(io, rel, .{}) catch return false;
        return true;
    }
};

const DeltaKey = struct {
    store_idx: u32,
    pack_idx: u32,
    offset: u64,
};

const DeltaNode = struct {
    key: DeltaKey,
    kind: ObjectType,
    data: []u8,
    prev: ?*DeltaNode,
    next: ?*DeltaNode,
};

const DeltaCache = struct {
    allocator: Allocator,
    budget: usize,
    used: usize,
    map: std.AutoHashMapUnmanaged(DeltaKey, *DeltaNode),
    head: ?*DeltaNode,
    tail: ?*DeltaNode,

    fn init(allocator: Allocator, budget: usize) DeltaCache {
        return .{
            .allocator = allocator,
            .budget = budget,
            .used = 0,
            .map = .empty,
            .head = null,
            .tail = null,
        };
    }

    fn deinit(self: *DeltaCache) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    fn clear(self: *DeltaCache) void {
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
        self.map.clearRetainingCapacity();
    }

    fn get(self: *DeltaCache, key: DeltaKey) ?struct { kind: ObjectType, data: []const u8 } {
        const node = self.map.get(key) orelse return null;
        self.moveToFront(node);
        return .{ .kind = node.kind, .data = node.data };
    }

    fn put(self: *DeltaCache, key: DeltaKey, kind: ObjectType, data: []const u8) void {
        if (data.len > self.budget) return;
        if (self.map.get(key)) |existing| {
            self.moveToFront(existing);
            return;
        }
        const owned = self.allocator.dupe(u8, data) catch return;
        const node = self.allocator.create(DeltaNode) catch {
            self.allocator.free(owned);
            return;
        };
        node.* = .{
            .key = key,
            .kind = kind,
            .data = owned,
            .prev = null,
            .next = null,
        };
        self.evictUntil(self.budget - owned.len);
        self.map.put(self.allocator, key, node) catch {
            self.allocator.free(owned);
            self.allocator.destroy(node);
            return;
        };
        self.pushFront(node);
        self.used += owned.len;
    }

    fn evictUntil(self: *DeltaCache, target: usize) void {
        while (self.used > target) {
            const victim = self.tail orelse break;
            self.unlink(victim);
            _ = self.map.remove(victim.key);
            self.used -= victim.data.len;
            self.allocator.free(victim.data);
            self.allocator.destroy(victim);
        }
    }

    fn pushFront(self: *DeltaCache, node: *DeltaNode) void {
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| h.prev = node else self.tail = node;
        self.head = node;
    }

    fn unlink(self: *DeltaCache, node: *DeltaNode) void {
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = null;
        node.next = null;
    }

    fn moveToFront(self: *DeltaCache, node: *DeltaNode) void {
        if (self.head == node) return;
        self.unlink(node);
        self.pushFront(node);
    }
};

const BlobNode = struct {
    oid: GitOid,
    data: []u8,
    prev: ?*BlobNode,
    next: ?*BlobNode,
};

const BlobCache = struct {
    allocator: Allocator,
    budget: usize,
    used: usize,
    map: std.HashMapUnmanaged(GitOid, *BlobNode, GitOid.hashContext, std.hash_map.default_max_load_percentage),
    head: ?*BlobNode,
    tail: ?*BlobNode,
    pinned: ?*BlobNode,
    oversize_pinned: ?[]u8,

    fn init(allocator: Allocator, budget: usize) BlobCache {
        return .{
            .allocator = allocator,
            .budget = budget,
            .used = 0,
            .map = .empty,
            .head = null,
            .tail = null,
            .pinned = null,
            .oversize_pinned = null,
        };
    }

    fn deinit(self: *BlobCache) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    fn clear(self: *BlobCache) void {
        var cur = self.head;
        while (cur) |node| {
            const nxt = node.next;
            self.allocator.free(node.data);
            self.allocator.destroy(node);
            cur = nxt;
        }
        self.head = null;
        self.tail = null;
        self.pinned = null;
        self.used = 0;
        self.map.clearRetainingCapacity();
        if (self.oversize_pinned) |op| {
            self.allocator.free(op);
            self.oversize_pinned = null;
        }
    }

    fn get(self: *BlobCache, oid: GitOid, pin: bool) ?[]const u8 {
        const node = self.map.get(oid) orelse return null;
        self.moveToFront(node);
        if (pin) {
            if (self.oversize_pinned) |op| {
                self.allocator.free(op);
                self.oversize_pinned = null;
            }
            self.pinned = node;
        }
        return node.data;
    }

    fn putTakeOwned(self: *BlobCache, oid: GitOid, owned: []u8, pin: bool) ![]const u8 {
        if (self.map.get(oid)) |existing| {
            self.allocator.free(owned);
            self.moveToFront(existing);
            if (pin) {
                if (self.oversize_pinned) |op| {
                    self.allocator.free(op);
                    self.oversize_pinned = null;
                }
                self.pinned = existing;
            }
            return existing.data;
        }

        if (owned.len > self.budget) {
            if (pin) {
                self.pinned = null;
                if (self.oversize_pinned) |op| self.allocator.free(op);
                self.oversize_pinned = owned;
                return owned;
            }
            self.allocator.free(owned);
            return &.{};
        }

        const node = self.allocator.create(BlobNode) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        node.* = .{
            .oid = oid,
            .data = owned,
            .prev = null,
            .next = null,
        };
        if (pin) {
            self.pinned = null;
            if (self.oversize_pinned) |op| {
                self.allocator.free(op);
                self.oversize_pinned = null;
            }
        }
        self.evictUntil(self.budget - owned.len);
        self.map.put(self.allocator, oid, node) catch |err| {
            self.allocator.free(owned);
            self.allocator.destroy(node);
            return err;
        };
        self.pushFront(node);
        self.used += owned.len;
        if (pin) self.pinned = node;
        return node.data;
    }

    fn putCopy(self: *BlobCache, oid: GitOid, data: []const u8) void {
        if (data.len > self.budget) return;
        if (self.map.get(oid)) |existing| {
            self.moveToFront(existing);
            return;
        }
        const owned = self.allocator.dupe(u8, data) catch return;
        _ = self.putTakeOwned(oid, owned, false) catch {};
    }

    fn evictUntil(self: *BlobCache, target: usize) void {
        var cursor = self.tail;
        while (self.used > target) {
            const victim = cursor orelse break;
            cursor = victim.prev;
            if (self.pinned == victim) continue;
            self.unlink(victim);
            _ = self.map.remove(victim.oid);
            self.used -= victim.data.len;
            self.allocator.free(victim.data);
            self.allocator.destroy(victim);
        }
    }

    fn pushFront(self: *BlobCache, node: *BlobNode) void {
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| h.prev = node else self.tail = node;
        self.head = node;
    }

    fn unlink(self: *BlobCache, node: *BlobNode) void {
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = null;
        node.next = null;
    }

    fn moveToFront(self: *BlobCache, node: *BlobNode) void {
        if (self.head == node) return;
        self.unlink(node);
        self.pushFront(node);
    }
};

const PackEntryHeader = struct {
    kind: ObjectType,
    size: u64,
    data_offset: usize,
    ofs_base: u64,
    ref_base: GitOid,
};

const DeltaFrame = struct {
    store_idx: usize,
    pack_idx: usize,
    offset: u64,
    delta_bytes: []u8,
};

pub const ExternalGitReader = struct {
    odb: *GitOdb,

    pub fn init(odb: *GitOdb) ExternalGitReader {
        odb.retain();
        return .{ .odb = odb };
    }

    pub fn deinit(self: *ExternalGitReader) void {
        self.odb.release();
    }

    pub fn contains(self: *const ExternalGitReader, oid: GitOid) bool {
        return self.odb.contains(oid);
    }

    pub fn readBlobAlloc(self: *const ExternalGitReader, allocator: Allocator, oid: GitOid) !?[]u8 {
        return try self.odb.readBlobAlloc(allocator, oid);
    }

    pub fn copyBlobToFile(self: *const ExternalGitReader, oid: GitOid, file_writer: *std.Io.Writer) !?u64 {
        return try self.odb.copyBlobToFile(oid, file_writer);
    }

    pub fn lock(self: *const ExternalGitReader) void {
        self.odb.lock();
    }

    pub fn unlock(self: *const ExternalGitReader) void {
        self.odb.unlock();
    }

    pub fn readBlobCachedLocked(self: *const ExternalGitReader, oid: GitOid) !?[]const u8 {
        return try self.odb.readBlobCachedLocked(oid);
    }
};

pub const GitOdb = struct {
    allocator: Allocator,
    io: Io,
    common_dir: []u8,
    format: ObjectFormat,
    pin_ref: []u8,
    reftable: bool,
    mutex: Io.Mutex,
    ref_count: std.atomic.Value(usize),
    stores: std.ArrayList(ObjectStore),
    delta_cache: DeltaCache,
    blob_cache: BlobCache,

    pub fn open(
        allocator: Allocator,
        io: Io,
        common_dir: []const u8,
        format: ObjectFormat,
        pin_ref_opt: ?[]const u8,
    ) !*GitOdb {
        const self = try allocator.create(GitOdb);
        errdefer allocator.destroy(self);

        const cd_copy = try allocator.dupe(u8, common_dir);
        errdefer allocator.free(cd_copy);

        const pin_copy = try allocator.dupe(u8, pin_ref_opt orelse DEFAULT_PIN_REF);
        errdefer allocator.free(pin_copy);

        var is_reftable = false;
        if (Io.Dir.cwd().openDir(io, common_dir, .{})) |cd_val| {
            var cd = cd_val;
            defer cd.close(io);
            if (cd.statFile(io, "reftable", .{})) |st| {
                if (st.kind == .directory) is_reftable = true;
            } else |_| {}
        } else |_| {}

        self.* = .{
            .allocator = allocator,
            .io = io,
            .common_dir = cd_copy,
            .format = format,
            .pin_ref = pin_copy,
            .reftable = is_reftable,
            .mutex = .init,
            .ref_count = .init(1),
            .stores = .empty,
            .delta_cache = DeltaCache.init(allocator, DEFAULT_DELTA_CACHE_BUDGET),
            .blob_cache = BlobCache.init(allocator, DEFAULT_BLOB_CACHE_BUDGET),
        };
        errdefer self.cleanupFields();

        const primary_objects = try std.fs.path.join(allocator, &.{ common_dir, "objects" });
        defer allocator.free(primary_objects);

        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var vit = visited.keyIterator();
            while (vit.next()) |k| allocator.free(k.*);
            visited.deinit(allocator);
        }

        try self.addStoreAndAlternates(primary_objects, 0, &visited);
        return self;
    }

    pub fn retain(self: *GitOdb) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *GitOdb) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.deinit();
        }
    }

    pub fn deinit(self: *GitOdb) void {
        const alloc = self.allocator;
        self.cleanupFields();
        alloc.destroy(self);
    }

    fn cleanupFields(self: *GitOdb) void {
        self.delta_cache.deinit();
        self.blob_cache.deinit();
        for (self.stores.items) |*s| s.deinit(self.allocator);
        self.stores.deinit(self.allocator);
        self.allocator.free(self.common_dir);
        self.allocator.free(self.pin_ref);
    }

    pub fn externalReader(self: *GitOdb) ExternalGitReader {
        return ExternalGitReader.init(self);
    }

    pub fn lock(self: *GitOdb) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *GitOdb) void {
        self.mutex.unlock(self.io);
    }

    fn addStoreAndAlternates(
        self: *GitOdb,
        objects_path: []const u8,
        depth: usize,
        visited: *std.StringHashMapUnmanaged(void),
    ) !void {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon: []const u8 = if (Io.Dir.cwd().realPathFile(self.io, objects_path, &real_buf)) |n|
            real_buf[0..n]
        else |_|
            objects_path;

        if (visited.contains(canon)) return;
        const key = try self.allocator.dupe(u8, canon);
        errdefer self.allocator.free(key);
        try visited.put(self.allocator, key, {});

        const store = try ObjectStore.init(self.allocator, self.io, canon, self.format);
        try self.stores.append(self.allocator, store);

        if (depth >= MAX_ALTERNATES_DEPTH) return;

        var obj_dir = Io.Dir.cwd().openDir(self.io, canon, .{}) catch return;
        defer obj_dir.close(self.io);
        const alt_file = obj_dir.openFile(self.io, "info/alternates", .{}) catch return;
        defer alt_file.close(self.io);
        const st = alt_file.stat(self.io) catch return;
        if (st.size == 0 or st.size > 1024 * 1024) return;
        const raw = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(raw);
        const n = try alt_file.readPositionalAll(self.io, raw, 0);

        var lines = std.mem.splitScalar(u8, raw[0..n], '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const entry_path = if (line.len >= 2 and line[0] == '"' and line[line.len - 1] == '"')
                line[1 .. line.len - 1]
            else
                line;
            if (entry_path.len == 0) continue;

            const resolved = if (std.fs.path.isAbsolute(entry_path))
                try self.allocator.dupe(u8, entry_path)
            else
                try std.fs.path.join(self.allocator, &.{ canon, entry_path });
            defer self.allocator.free(resolved);

            self.addStoreAndAlternates(resolved, depth + 1, visited) catch {};
        }
    }

    fn refreshStoresLocked(self: *GitOdb) bool {
        var any_changed = false;
        for (self.stores.items) |*store| {
            const changed = store.refreshIfChanged(self.allocator, self.io, self.format) catch false;
            if (changed) any_changed = true;
        }
        if (any_changed) {
            self.delta_cache.clear();
        }
        return any_changed;
    }

    pub fn contains(self: *GitOdb, oid: GitOid) bool {
        if (oid.len != self.format.byteLen()) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.blob_cache.map.contains(oid)) return true;
        if (self.containsInStoresLocked(oid)) return true;
        if (self.refreshStoresLocked()) {
            return self.containsInStoresLocked(oid);
        }
        return false;
    }

    fn containsInStoresLocked(self: *const GitOdb, oid: GitOid) bool {
        for (self.stores.items) |*store| {
            if (store.findInPacks(oid) != null) return true;
            if (store.hasLoose(self.io, oid)) return true;
        }
        return false;
    }

    pub fn readObject(self: *GitOdb, allocator: Allocator, oid: GitOid) !?GitObject {
        if (oid.len != self.format.byteLen()) return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return try self.readObjectLocked(allocator, oid, true);
    }

    pub fn readBlobAlloc(self: *GitOdb, allocator: Allocator, oid: GitOid) !?[]u8 {
        if (oid.len != self.format.byteLen()) return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.blob_cache.get(oid, false)) |cached| {
            return try allocator.dupe(u8, cached);
        }
        const obj = (try self.readObjectLocked(allocator, oid, true)) orelse return null;
        errdefer allocator.free(obj.data);
        if (obj.kind != .blob) return error.NotABlob;
        self.blob_cache.putCopy(oid, obj.data);
        return obj.data;
    }

    pub fn readBlobCached(self: *GitOdb, oid: GitOid) !?[]const u8 {
        if (oid.len != self.format.byteLen()) return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return try self.readBlobCachedLocked(oid);
    }

    pub fn readBlobCachedLocked(self: *GitOdb, oid: GitOid) !?[]const u8 {
        if (oid.len != self.format.byteLen()) return null;
        if (self.blob_cache.get(oid, true)) |cached| {
            return cached;
        }
        const obj = (try self.readObjectLocked(self.allocator, oid, true)) orelse return null;
        if (obj.kind != .blob) {
            self.allocator.free(obj.data);
            return error.NotABlob;
        }
        return try self.blob_cache.putTakeOwned(oid, obj.data, true);
    }

    pub fn copyBlobToFile(self: *GitOdb, oid: GitOid, file_writer: *std.Io.Writer) !?u64 {
        if (oid.len != self.format.byteLen()) return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.blob_cache.get(oid, false)) |cached| {
            try file_writer.writeAll(cached);
            return cached.len;
        }

        if (try self.copyBlobFromStoresLocked(oid, file_writer)) |n| return n;
        if (self.refreshStoresLocked()) {
            if (try self.copyBlobFromStoresLocked(oid, file_writer)) |n| return n;
        }
        return null;
    }

    fn copyBlobFromStoresLocked(self: *GitOdb, oid: GitOid, file_writer: *std.Io.Writer) !?u64 {
        for (self.stores.items, 0..) |*store, sidx| {
            if (store.findInPacks(oid)) |hit| {
                const pk = &store.packs.items[hit.pack_idx];
                const hdr = try parsePackEntryHeader(pk.pack_map.mem, hit.offset, self.format);
                if (hdr.kind == .blob) {
                    return try streamInflatePackBlob(pk.pack_map.mem[hdr.data_offset..], hdr.size, file_writer);
                }
                if (hdr.kind == .ofs_delta or hdr.kind == .ref_delta) {
                    const obj = try self.readPackObjectLocked(self.allocator, sidx, hit.pack_idx, hit.offset);
                    defer self.allocator.free(obj.data);
                    if (obj.kind != .blob) return error.NotABlob;
                    try file_writer.writeAll(obj.data);
                    return obj.data.len;
                }
                return error.NotABlob;
            }
            if (try streamLooseBlobToWriter(self.io, store.objects_dir, oid, file_writer)) |n| {
                return n;
            }
        }
        return null;
    }

    fn readObjectLocked(self: *GitOdb, allocator: Allocator, oid: GitOid, allow_refresh: bool) !?GitObject {
        for (self.stores.items, 0..) |*store, sidx| {
            if (store.findInPacks(oid)) |hit| {
                return try self.readPackObjectLocked(allocator, sidx, hit.pack_idx, hit.offset);
            }
            if (try readLooseObject(allocator, self.io, store.objects_dir, oid)) |obj| {
                return obj;
            }
        }
        if (allow_refresh and self.refreshStoresLocked()) {
            return try self.readObjectLocked(allocator, oid, false);
        }
        return null;
    }

    fn findPackLocationLocked(self: *const GitOdb, oid: GitOid) ?struct { store_idx: usize, pack_idx: usize, offset: u64 } {
        for (self.stores.items, 0..) |*store, sidx| {
            if (store.findInPacks(oid)) |hit| {
                return .{ .store_idx = sidx, .pack_idx = hit.pack_idx, .offset = hit.offset };
            }
        }
        return null;
    }

    fn readPackObjectLocked(
        self: *GitOdb,
        allocator: Allocator,
        start_store_idx: usize,
        start_pack_idx: usize,
        start_offset: u64,
    ) !GitObject {
        var chain: [MAX_DELTA_DEPTH]DeltaFrame = undefined;
        var depth: usize = 0;
        errdefer {
            for (0..depth) |i| self.allocator.free(chain[i].delta_bytes);
        }

        var cur_store = start_store_idx;
        var cur_pack = start_pack_idx;
        var cur_off = start_offset;

        var base_kind: ObjectType = undefined;
        var base_data: []u8 = undefined;

        while (true) {
            const cache_key = DeltaKey{
                .store_idx = @intCast(cur_store),
                .pack_idx = @intCast(cur_pack),
                .offset = cur_off,
            };
            if (self.delta_cache.get(cache_key)) |cached| {
                base_kind = cached.kind;
                base_data = try self.allocator.dupe(u8, cached.data);
                break;
            }

            const pk = &self.stores.items[cur_store].packs.items[cur_pack];
            const hdr = try parsePackEntryHeader(pk.pack_map.mem, cur_off, self.format);

            switch (hdr.kind) {
                .commit, .tree, .blob, .tag => {
                    base_kind = hdr.kind;
                    base_data = try inflatePackKnownSize(self.allocator, pk.pack_map.mem[hdr.data_offset..], hdr.size);
                    break;
                },
                .ofs_delta => {
                    if (depth >= MAX_DELTA_DEPTH) return error.DeltaChainTooDeep;
                    const delta_bytes = try inflatePackKnownSize(self.allocator, pk.pack_map.mem[hdr.data_offset..], hdr.size);
                    chain[depth] = .{
                        .store_idx = cur_store,
                        .pack_idx = cur_pack,
                        .offset = cur_off,
                        .delta_bytes = delta_bytes,
                    };
                    depth += 1;
                    cur_off = hdr.ofs_base;
                },
                .ref_delta => {
                    if (depth >= MAX_DELTA_DEPTH) return error.DeltaChainTooDeep;
                    const delta_bytes = try inflatePackKnownSize(self.allocator, pk.pack_map.mem[hdr.data_offset..], hdr.size);
                    chain[depth] = .{
                        .store_idx = cur_store,
                        .pack_idx = cur_pack,
                        .offset = cur_off,
                        .delta_bytes = delta_bytes,
                    };
                    depth += 1;

                    if (self.findPackLocationLocked(hdr.ref_base)) |loc| {
                        cur_store = loc.store_idx;
                        cur_pack = loc.pack_idx;
                        cur_off = loc.offset;
                    } else {
                        var found_loose: ?GitObject = null;
                        for (self.stores.items) |*st| {
                            if (try readLooseObject(self.allocator, self.io, st.objects_dir, hdr.ref_base)) |obj| {
                                found_loose = obj;
                                break;
                            }
                        }
                        if (found_loose) |obj| {
                            base_kind = obj.kind;
                            base_data = obj.data;
                            break;
                        }
                        return error.MissingBaseObject;
                    }
                },
            }
        }

        if (depth == 0) {
            if (allocator.ptr == self.allocator.ptr and allocator.vtable == self.allocator.vtable) {
                return .{ .kind = base_kind, .data = base_data };
            }
            defer self.allocator.free(base_data);
            return .{ .kind = base_kind, .data = try allocator.dupe(u8, base_data) };
        }

        var cur_data = base_data;
        errdefer self.allocator.free(cur_data);

        while (depth > 0) {
            depth -= 1;
            const frame = chain[depth];
            defer self.allocator.free(frame.delta_bytes);
            const next_data = try applyDelta(self.allocator, cur_data, frame.delta_bytes);
            self.allocator.free(cur_data);
            cur_data = next_data;
            self.delta_cache.put(.{
                .store_idx = @intCast(frame.store_idx),
                .pack_idx = @intCast(frame.pack_idx),
                .offset = frame.offset,
            }, base_kind, cur_data);
        }

        if (allocator.ptr == self.allocator.ptr and allocator.vtable == self.allocator.vtable) {
            return .{ .kind = base_kind, .data = cur_data };
        }
        defer self.allocator.free(cur_data);
        return .{ .kind = base_kind, .data = try allocator.dupe(u8, cur_data) };
    }

    pub fn pinOids(self: *GitOdb, oids: []const GitOid) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const sorted = try self.allocator.dupe(GitOid, oids);
        defer self.allocator.free(sorted);

        std.mem.sort(GitOid, sorted, {}, struct {
            fn lessThan(_: void, a: GitOid, b: GitOid) bool {
                return a.order(b) == .lt;
            }
        }.lessThan);

        var tree_buf: std.ArrayList(u8) = .empty;
        defer tree_buf.deinit(self.allocator);

        var prev_oid: ?GitOid = null;
        for (sorted) |oid| {
            if (oid.len != self.format.byteLen()) continue;
            if (prev_oid) |p| {
                if (p.eql(oid)) continue;
            }
            prev_oid = oid;
            var hex_buf: [64]u8 = undefined;
            const hex = oid.toHex(&hex_buf);
            try tree_buf.appendSlice(self.allocator, "100644 ");
            try tree_buf.appendSlice(self.allocator, hex);
            try tree_buf.append(self.allocator, 0);
            try tree_buf.appendSlice(self.allocator, oid.slice());
        }

        const tree_oid = try self.writeLooseObjectLocked("tree", tree_buf.items);

        var tree_hex_buf: [64]u8 = undefined;
        const tree_hex = tree_oid.toHex(&tree_hex_buf);

        const now_ts = Io.Clock.real.now(self.io).nanoseconds;
        const unix_s: u64 = if (now_ts > 0) @intCast(@divFloor(now_ts, std.time.ns_per_s)) else 1700000000;

        var commit_buf: [512]u8 = undefined;
        const commit_payload = try std.fmt.bufPrint(
            &commit_buf,
            "tree {s}\nauthor 0ndb <0ndb@local> {d} +0000\ncommitter 0ndb <0ndb@local> {d} +0000\n\n0ndb pin\n",
            .{ tree_hex, unix_s, unix_s },
        );

        const commit_oid = try self.writeLooseObjectLocked("commit", commit_payload);
        var commit_hex_buf: [64]u8 = undefined;
        const commit_hex = commit_oid.toHex(&commit_hex_buf);

        try self.updateRefLocked(self.pin_ref, commit_hex);
    }

    fn writeLooseObjectLocked(self: *GitOdb, kind_name: []const u8, payload: []const u8) !GitOid {
        const oid = GitOid.ofObject(self.format, kind_name, payload);
        var hex_buf: [64]u8 = undefined;
        const hex = oid.toHex(&hex_buf);

        const objects_dir_path = self.stores.items[0].objects_dir;
        var obj_dir = try Io.Dir.cwd().openDir(self.io, objects_dir_path, .{});
        defer obj_dir.close(self.io);

        var rel_buf: [72]u8 = undefined;
        const rel_path = std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;
        if (obj_dir.statFile(self.io, rel_path, .{})) |_| {
            return oid;
        } else |_| {}

        var hdr_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&hdr_buf, "{s} {d}\x00", .{ kind_name, payload.len }) catch unreachable;

        var alloc_out = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        defer alloc_out.deinit();

        const comp_buf = try self.allocator.alloc(u8, flate.max_window_len);
        defer self.allocator.free(comp_buf);

        const comp = try self.allocator.create(flate.Compress);
        defer self.allocator.destroy(comp);

        comp.* = try flate.Compress.init(&alloc_out.writer, comp_buf, .zlib, .fastest);
        try comp.writer.writeAll(header);
        try comp.writer.writeAll(payload);
        try comp.finish();

        const compressed = alloc_out.written();

        try obj_dir.createDirPath(self.io, hex[0..2]);

        var tmp_buf: [96]u8 = undefined;
        const now_ns: u64 = @truncate(@as(u96, @bitCast(Io.Clock.real.now(self.io).nanoseconds)));
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/tmp_obj_{x}", .{ hex[0..2], now_ns }) catch unreachable;

        const tf = try obj_dir.createFile(self.io, tmp_path, .{ .truncate = true });
        var tf_closed = false;
        errdefer {
            if (!tf_closed) tf.close(self.io);
            obj_dir.deleteFile(self.io, tmp_path) catch {};
        }
        try tf.writePositionalAll(self.io, compressed, 0);
        try tf.sync(self.io);
        tf.close(self.io);
        tf_closed = true;

        obj_dir.rename(tmp_path, obj_dir, rel_path, self.io) catch |err| {
            obj_dir.deleteFile(self.io, tmp_path) catch {};
            if (obj_dir.statFile(self.io, rel_path, .{})) |_| {
                return oid;
            } else |_| return err;
        };

        return oid;
    }

    fn updateRefLocked(self: *GitOdb, ref_name: []const u8, commit_hex: []const u8) !void {
        if (self.reftable) {
            try self.updateRefSubprocess(ref_name, commit_hex);
            return;
        }

        var cd = try Io.Dir.cwd().openDir(self.io, self.common_dir, .{});
        defer cd.close(self.io);

        if (std.fs.path.dirname(ref_name)) |parent| {
            try cd.createDirPath(self.io, parent);
        }

        const lock_path = try std.fmt.allocPrint(self.allocator, "{s}.lock", .{ref_name});
        defer self.allocator.free(lock_path);

        const lf = cd.createFile(self.io, lock_path, .{
            .exclusive = true,
            .truncate = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.RefLockHeld,
            else => return err,
        };
        var lf_closed = false;
        errdefer {
            if (!lf_closed) lf.close(self.io);
            cd.deleteFile(self.io, lock_path) catch {};
        }

        var line_buf: [80]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{commit_hex}) catch unreachable;
        try lf.writePositionalAll(self.io, line, 0);
        try lf.sync(self.io);
        lf.close(self.io);
        lf_closed = true;

        try cd.rename(lock_path, cd, ref_name, self.io);
    }

    fn updateRefSubprocess(self: *GitOdb, ref_name: []const u8, commit_hex: []const u8) !void {
        var env_map = std.process.Environ.Map.init(self.allocator);
        defer env_map.deinit();
        try env_map.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try env_map.put("GIT_TERMINAL_PROMPT", "0");

        const res = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "--git-dir", self.common_dir, "update-ref", ref_name, commit_hex },
            .environ_map = &env_map,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(res.stdout);
        defer self.allocator.free(res.stderr);
        const ok = switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return error.UpdateRefFailed;
    }

    pub fn hibernate(self: *GitOdb) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.delta_cache.clear();
        self.blob_cache.clear();
        for (self.stores.items) |*store| {
            store.adviseDontNeed();
        }
    }
};

fn parsePackEntryHeader(pack: []const u8, offset_u64: u64, format: ObjectFormat) !PackEntryHeader {
    const offset: usize = std.math.cast(usize, offset_u64) orelse return error.CorruptPack;
    if (offset < 12 or offset >= pack.len) return error.CorruptPack;

    var pos = offset;
    var b = pack[pos];
    pos += 1;

    const kind_bits: u3 = @truncate((b >> 4) & 0x07);
    const kind = ObjectType.fromPackBits(kind_bits) orelse return error.CorruptPack;

    var size: u64 = b & 0x0f;
    var shift: u6 = 4;
    while ((b & 0x80) != 0) {
        if (pos >= pack.len) return error.CorruptPack;
        if (shift >= 60) return error.CorruptPack;
        b = pack[pos];
        pos += 1;
        size |= @as(u64, b & 0x7f) << shift;
        shift += 7;
    }

    var ofs_base: u64 = 0;
    var ref_base = GitOid.ZERO;

    if (kind == .ofs_delta) {
        const neg = git_index.decodeBiasedVarint(pack, &pos) orelse return error.CorruptPack;
        if (neg == 0 or neg > offset_u64) return error.CorruptPack;
        ofs_base = offset_u64 - neg;
    } else if (kind == .ref_delta) {
        const hash_len = format.byteLen();
        if (pos + hash_len > pack.len) return error.CorruptPack;
        ref_base = GitOid.fromSlice(pack[pos .. pos + hash_len]) catch return error.CorruptPack;
        pos += hash_len;
    }

    if (pos >= pack.len) return error.CorruptPack;
    return .{
        .kind = kind,
        .size = size,
        .data_offset = pos,
        .ofs_base = ofs_base,
        .ref_base = ref_base,
    };
}

fn inflatePackKnownSize(allocator: Allocator, compressed: []const u8, expected_size_u64: u64) ![]u8 {
    const expected_size: usize = std.math.cast(usize, expected_size_u64) orelse return error.ObjectTooLarge;
    const out = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(out);

    var in_reader = std.Io.Reader.fixed(compressed);
    var decomp = flate.Decompress.init(&in_reader, .zlib, &.{});
    var out_writer = std.Io.Writer.fixed(out);

    const n = decomp.reader.streamRemaining(&out_writer) catch return error.InvalidZlibStream;
    if (n != expected_size) return error.InvalidZlibStream;
    if (decomp.state != .end) return error.InvalidZlibStream;
    if (Adler32.hash(out[0..n]) != decomp.container_metadata.zlib.adler) {
        return error.Adler32Mismatch;
    }
    return out;
}

fn streamInflatePackBlob(compressed: []const u8, expected_size_u64: u64, dst_writer: *std.Io.Writer) !u64 {
    var win: [flate.max_window_len]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(compressed);
    var decomp = flate.Decompress.init(&in_reader, .zlib, &win);

    var adler = Adler32{};
    var chunk: [16384]u8 = undefined;
    var total: u64 = 0;

    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch return error.InvalidZlibStream;
        if (n > 0) {
            adler.update(chunk[0..n]);
            try dst_writer.writeAll(chunk[0..n]);
            total += n;
        }
        if (n < chunk.len) break;
    }

    if (decomp.state != .end) return error.InvalidZlibStream;
    if (total != expected_size_u64) return error.InvalidZlibStream;
    if (adler.adler != decomp.container_metadata.zlib.adler) return error.Adler32Mismatch;
    return total;
}

fn readLooseObject(allocator: Allocator, io: Io, objects_dir_path: []const u8, oid: GitOid) !?GitObject {
    var hex_buf: [64]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var rel_buf: [72]u8 = undefined;
    const rel = std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;

    var obj_dir = Io.Dir.cwd().openDir(io, objects_dir_path, .{}) catch return null;
    defer obj_dir.close(io);

    const f = obj_dir.openFile(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io);

    var in_buf: [16384]u8 = undefined;
    var fr = f.reader(io, &in_buf);
    var win: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&fr.interface, .zlib, &win);

    var adler = Adler32{};
    var chunk: [16384]u8 = undefined;
    var hdr_buf: [128]u8 = undefined;
    var hdr_len: usize = 0;
    var header_parsed = false;
    var kind: ObjectType = .blob;
    var expected_size: usize = 0;
    var payload: []u8 = &.{};
    var payload_pos: usize = 0;
    errdefer if (header_parsed) allocator.free(payload);

    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch return error.InvalidZlibStream;
        if (n > 0) {
            adler.update(chunk[0..n]);
            var slice = chunk[0..n];
            if (!header_parsed) {
                const nul_opt = std.mem.indexOfScalar(u8, slice, 0);
                if (nul_opt) |nul_idx| {
                    if (hdr_len + nul_idx > hdr_buf.len) return error.CorruptLooseObject;
                    @memcpy(hdr_buf[hdr_len .. hdr_len + nul_idx], slice[0..nul_idx]);
                    hdr_len += nul_idx;

                    const parsed = parseLooseHeader(hdr_buf[0..hdr_len]) orelse return error.CorruptLooseObject;
                    kind = parsed.kind;
                    expected_size = std.math.cast(usize, parsed.size) orelse return error.ObjectTooLarge;
                    payload = try allocator.alloc(u8, expected_size);
                    header_parsed = true;
                    slice = slice[nul_idx + 1 ..];
                } else {
                    if (hdr_len + slice.len > hdr_buf.len) return error.CorruptLooseObject;
                    @memcpy(hdr_buf[hdr_len .. hdr_len + slice.len], slice);
                    hdr_len += slice.len;
                    slice = &.{};
                }
            }
            if (slice.len > 0) {
                if (payload_pos + slice.len > expected_size) return error.CorruptLooseObject;
                @memcpy(payload[payload_pos .. payload_pos + slice.len], slice);
                payload_pos += slice.len;
            }
        }
        if (n < chunk.len) break;
    }

    if (!header_parsed) return error.CorruptLooseObject;
    if (decomp.state != .end) return error.InvalidZlibStream;
    if (payload_pos != expected_size) return error.CorruptLooseObject;
    if (adler.adler != decomp.container_metadata.zlib.adler) return error.Adler32Mismatch;

    return .{ .kind = kind, .data = payload };
}

fn streamLooseBlobToWriter(io: Io, objects_dir_path: []const u8, oid: GitOid, dst_writer: *std.Io.Writer) !?u64 {
    var hex_buf: [64]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var rel_buf: [72]u8 = undefined;
    const rel = std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;

    var obj_dir = Io.Dir.cwd().openDir(io, objects_dir_path, .{}) catch return null;
    defer obj_dir.close(io);

    const f = obj_dir.openFile(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io);

    var in_buf: [16384]u8 = undefined;
    var fr = f.reader(io, &in_buf);
    var win: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&fr.interface, .zlib, &win);

    var adler = Adler32{};
    var chunk: [16384]u8 = undefined;
    var hdr_buf: [128]u8 = undefined;
    var hdr_len: usize = 0;
    var header_parsed = false;
    var expected_size: u64 = 0;
    var written: u64 = 0;

    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch return error.InvalidZlibStream;
        if (n > 0) {
            adler.update(chunk[0..n]);
            var slice = chunk[0..n];
            if (!header_parsed) {
                const nul_opt = std.mem.indexOfScalar(u8, slice, 0);
                if (nul_opt) |nul_idx| {
                    if (hdr_len + nul_idx > hdr_buf.len) return error.CorruptLooseObject;
                    @memcpy(hdr_buf[hdr_len .. hdr_len + nul_idx], slice[0..nul_idx]);
                    hdr_len += nul_idx;

                    const parsed = parseLooseHeader(hdr_buf[0..hdr_len]) orelse return error.CorruptLooseObject;
                    if (parsed.kind != .blob) return error.NotABlob;
                    expected_size = parsed.size;
                    header_parsed = true;
                    slice = slice[nul_idx + 1 ..];
                } else {
                    if (hdr_len + slice.len > hdr_buf.len) return error.CorruptLooseObject;
                    @memcpy(hdr_buf[hdr_len .. hdr_len + slice.len], slice);
                    hdr_len += slice.len;
                    slice = &.{};
                }
            }
            if (slice.len > 0) {
                try dst_writer.writeAll(slice);
                written += slice.len;
            }
        }
        if (n < chunk.len) break;
    }

    if (!header_parsed) return error.CorruptLooseObject;
    if (decomp.state != .end) return error.InvalidZlibStream;
    if (written != expected_size) return error.CorruptLooseObject;
    if (adler.adler != decomp.container_metadata.zlib.adler) return error.Adler32Mismatch;

    return written;
}

fn parseLooseHeader(hdr: []const u8) ?struct { kind: ObjectType, size: u64 } {
    const sp = std.mem.indexOfScalar(u8, hdr, ' ') orelse return null;
    const kind = ObjectType.fromName(hdr[0..sp]) orelse return null;
    const size = std.fmt.parseInt(u64, hdr[sp + 1 ..], 10) catch return null;
    return .{ .kind = kind, .size = size };
}

fn readDeltaVarint(data: []const u8, pos: *usize) !u64 {
    var val: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= data.len) return error.CorruptDelta;
        const b = data[pos.*];
        pos.* += 1;
        val |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return val;
        if (shift >= 57) return error.CorruptDelta;
        shift += 7;
    }
}

fn applyDelta(allocator: Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;
    const base_size = try readDeltaVarint(delta, &pos);
    if (base_size != base.len) return error.CorruptDelta;

    const result_size_u64 = try readDeltaVarint(delta, &pos);
    const result_size: usize = std.math.cast(usize, result_size_u64) orelse return error.ObjectTooLarge;

    const out = try allocator.alloc(u8, result_size);
    errdefer allocator.free(out);
    var out_pos: usize = 0;

    while (pos < delta.len) {
        const cmd = delta[pos];
        pos += 1;

        if ((cmd & 0x80) != 0) {
            var cp_off: usize = 0;
            var cp_size: usize = 0;
            if ((cmd & 0x01) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_off |= @as(usize, delta[pos]);
                pos += 1;
            }
            if ((cmd & 0x02) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_off |= @as(usize, delta[pos]) << 8;
                pos += 1;
            }
            if ((cmd & 0x04) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_off |= @as(usize, delta[pos]) << 16;
                pos += 1;
            }
            if ((cmd & 0x08) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_off |= @as(usize, delta[pos]) << 24;
                pos += 1;
            }
            if ((cmd & 0x10) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_size |= @as(usize, delta[pos]);
                pos += 1;
            }
            if ((cmd & 0x20) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_size |= @as(usize, delta[pos]) << 8;
                pos += 1;
            }
            if ((cmd & 0x40) != 0) {
                if (pos >= delta.len) return error.CorruptDelta;
                cp_size |= @as(usize, delta[pos]) << 16;
                pos += 1;
            }
            if (cp_size == 0) cp_size = 0x10000;

            if (cp_off > base.len or cp_size > base.len - cp_off) return error.CorruptDelta;
            if (cp_size > out.len - out_pos) return error.CorruptDelta;
            @memcpy(out[out_pos .. out_pos + cp_size], base[cp_off .. cp_off + cp_size]);
            out_pos += cp_size;
        } else if (cmd != 0) {
            const lit_len: usize = cmd;
            if (lit_len > delta.len - pos) return error.CorruptDelta;
            if (lit_len > out.len - out_pos) return error.CorruptDelta;
            @memcpy(out[out_pos .. out_pos + lit_len], delta[pos .. pos + lit_len]);
            pos += lit_len;
            out_pos += lit_len;
        } else {
            return error.CorruptDelta;
        }
    }

    if (out_pos != out.len) return error.CorruptDelta;
    return out;
}
