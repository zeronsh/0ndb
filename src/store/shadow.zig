const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");
const mmap = @import("mmap.zig");

pub const MAGIC: [7]u8 = .{ '0', 'N', 'D', 'S', 'H', 'D', '1' };
pub const FORMAT_VERSION: u8 = 1;
pub const HEADER_SIZE: usize = 96;
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_DIR_ENTRY_SIZE: usize = 24;
pub const REV_IDX_ENTRY_SIZE: usize = 34;
pub const ENTRY_FIXED_SIZE: usize = 128;

const FLAG_HAS_GIT_OID: u8 = 1 << 0;
const FLAG_HAS_BLOB_OID: u8 = 1 << 1;

var tmp_seq: std.atomic.Value(u64) = .init(0);

fn currentPid() u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    }
    return 0;
}

pub const EntryKind = enum(u8) {
    file = 1,
    dir = 2,
    symlink = 3,
};

pub const ShadowEntry = struct {
    inode_id: id.InodeId,
    kind: EntryKind,
    mode: u32 = 0,
    line_ending: u8 = 0,
    has_git_oid: bool = false,
    git_oid_len: u8 = 0,
    git_oid: [32]u8 = @splat(0),
    has_blob_oid: bool = false,
    blob_oid: [32]u8 = @splat(0),
    size: u64 = 0,
    mtime_ns: i96 = 0,
    ino: u64 = 0,

    pub fn eql(self: ShadowEntry, other: ShadowEntry) bool {
        return self.inode_id.eql(other.inode_id) and
            self.kind == other.kind and
            self.mode == other.mode and
            self.line_ending == other.line_ending and
            self.has_git_oid == other.has_git_oid and
            self.git_oid_len == other.git_oid_len and
            std.mem.eql(u8, &self.git_oid, &other.git_oid) and
            self.has_blob_oid == other.has_blob_oid and
            std.mem.eql(u8, &self.blob_oid, &other.blob_oid) and
            self.size == other.size and
            self.mtime_ns == other.mtime_ns and
            self.ino == other.ino;
    }

    fn encode(self: ShadowEntry) [ENTRY_FIXED_SIZE]u8 {
        var buf: [ENTRY_FIXED_SIZE]u8 = @splat(0);
        std.mem.writeInt(u64, buf[0..8], self.inode_id.op.ts, .little);
        std.mem.writeInt(u128, buf[8..24], self.inode_id.op.actor, .little);
        std.mem.writeInt(u32, buf[24..28], self.inode_id.part, .little);
        buf[28] = @backingInt(self.kind);
        buf[29] = self.line_ending;
        var flags: u8 = 0;
        if (self.has_git_oid) flags |= FLAG_HAS_GIT_OID;
        if (self.has_blob_oid) flags |= FLAG_HAS_BLOB_OID;
        buf[30] = flags;
        buf[31] = self.git_oid_len;
        std.mem.writeInt(u32, buf[32..36], self.mode, .little);
        std.mem.writeInt(u64, buf[36..44], self.size, .little);
        std.mem.writeInt(u64, buf[44..52], self.ino, .little);
        const mt_u: u96 = @bitCast(self.mtime_ns);
        std.mem.writeInt(u64, buf[52..60], @truncate(mt_u), .little);
        std.mem.writeInt(u32, buf[60..64], @truncate(mt_u >> 64), .little);
        @memcpy(buf[64..96], &self.git_oid);
        @memcpy(buf[96..128], &self.blob_oid);
        return buf;
    }

    fn decode(bytes: *const [ENTRY_FIXED_SIZE]u8) !ShadowEntry {
        const kind = std.enums.fromInt(EntryKind, bytes[28]) orelse return error.CorruptPage;
        const git_oid_len = bytes[31];
        if (git_oid_len > 32) return error.CorruptPage;
        const flags = bytes[30];
        const mt_lo: u96 = std.mem.readInt(u64, bytes[52..60], .little);
        const mt_hi: u96 = std.mem.readInt(u32, bytes[60..64], .little);
        var entry = ShadowEntry{
            .inode_id = .{
                .op = .{
                    .ts = std.mem.readInt(u64, bytes[0..8], .little),
                    .actor = std.mem.readInt(u128, bytes[8..24], .little),
                },
                .part = std.mem.readInt(u32, bytes[24..28], .little),
            },
            .kind = kind,
            .mode = std.mem.readInt(u32, bytes[32..36], .little),
            .line_ending = bytes[29],
            .has_git_oid = (flags & FLAG_HAS_GIT_OID) != 0,
            .git_oid_len = git_oid_len,
            .git_oid = undefined,
            .has_blob_oid = (flags & FLAG_HAS_BLOB_OID) != 0,
            .blob_oid = undefined,
            .size = std.mem.readInt(u64, bytes[36..44], .little),
            .mtime_ns = @bitCast(mt_lo | (mt_hi << 64)),
            .ino = std.mem.readInt(u64, bytes[44..52], .little),
        };
        @memcpy(&entry.git_oid, bytes[64..96]);
        @memcpy(&entry.blob_oid, bytes[96..128]);
        return entry;
    }
};

const PageDirEntry = struct {
    first_path_off: u32,
    first_path_len: u16,
    entry_count: u16,
    page_file_off: u64,
    page_len: u32,
    page_crc32c: u32,

    fn encode(self: PageDirEntry) [PAGE_DIR_ENTRY_SIZE]u8 {
        var buf: [PAGE_DIR_ENTRY_SIZE]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], self.first_path_off, .little);
        std.mem.writeInt(u16, buf[4..6], self.first_path_len, .little);
        std.mem.writeInt(u16, buf[6..8], self.entry_count, .little);
        std.mem.writeInt(u64, buf[8..16], self.page_file_off, .little);
        std.mem.writeInt(u32, buf[16..20], self.page_len, .little);
        std.mem.writeInt(u32, buf[20..24], self.page_crc32c, .little);
        return buf;
    }

    fn decode(bytes: *const [PAGE_DIR_ENTRY_SIZE]u8) PageDirEntry {
        return .{
            .first_path_off = std.mem.readInt(u32, bytes[0..4], .little),
            .first_path_len = std.mem.readInt(u16, bytes[4..6], .little),
            .entry_count = std.mem.readInt(u16, bytes[6..8], .little),
            .page_file_off = std.mem.readInt(u64, bytes[8..16], .little),
            .page_len = std.mem.readInt(u32, bytes[16..20], .little),
            .page_crc32c = std.mem.readInt(u32, bytes[20..24], .little),
        };
    }
};

const RevIdxEntry = struct {
    inode_id: id.InodeId,
    page_idx: u32,
    slot_idx: u16,

    fn encode(self: RevIdxEntry) [REV_IDX_ENTRY_SIZE]u8 {
        var buf: [REV_IDX_ENTRY_SIZE]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.inode_id.op.ts, .little);
        std.mem.writeInt(u128, buf[8..24], self.inode_id.op.actor, .little);
        std.mem.writeInt(u32, buf[24..28], self.inode_id.part, .little);
        std.mem.writeInt(u32, buf[28..32], self.page_idx, .little);
        std.mem.writeInt(u16, buf[32..34], self.slot_idx, .little);
        return buf;
    }

    fn decode(bytes: *const [REV_IDX_ENTRY_SIZE]u8) RevIdxEntry {
        return .{
            .inode_id = .{
                .op = .{
                    .ts = std.mem.readInt(u64, bytes[0..8], .little),
                    .actor = std.mem.readInt(u128, bytes[8..24], .little),
                },
                .part = std.mem.readInt(u32, bytes[24..28], .little),
            },
            .page_idx = std.mem.readInt(u32, bytes[28..32], .little),
            .slot_idx = std.mem.readInt(u16, bytes[32..34], .little),
        };
    }

    fn lessThan(_: void, a: RevIdxEntry, b: RevIdxEntry) bool {
        const o = a.inode_id.order(b.inode_id);
        if (o != .eq) return o == .lt;
        if (a.page_idx != b.page_idx) return a.page_idx < b.page_idx;
        return a.slot_idx < b.slot_idx;
    }
};

const HeaderMeta = struct {
    entry_count: u64,
    page_count: u32,
    page_dir_off: u64,
    fence_arena_off: u64,
    fence_arena_len: u64,
    rev_idx_off: u64,
    file_size: u64,

    fn encode(self: HeaderMeta) [HEADER_SIZE]u8 {
        var buf: [HEADER_SIZE]u8 = @splat(0);
        @memcpy(buf[0..7], &MAGIC);
        buf[7] = FORMAT_VERSION;
        std.mem.writeInt(u64, buf[8..16], self.entry_count, .little);
        std.mem.writeInt(u32, buf[16..20], self.page_count, .little);
        std.mem.writeInt(u32, buf[20..24], 0, .little);
        std.mem.writeInt(u64, buf[24..32], self.page_dir_off, .little);
        std.mem.writeInt(u64, buf[32..40], self.fence_arena_off, .little);
        std.mem.writeInt(u64, buf[40..48], self.fence_arena_len, .little);
        std.mem.writeInt(u64, buf[48..56], self.rev_idx_off, .little);
        std.mem.writeInt(u64, buf[56..64], self.file_size, .little);
        const digest = crypto.hashBytes(buf[0..64]);
        @memcpy(buf[64..96], &digest);
        return buf;
    }

    fn parse(mf: *const mmap.MappedFile) !HeaderMeta {
        const data = mf.slice();
        if (data.len < HEADER_SIZE) return error.CorruptHeader;
        if (!std.mem.eql(u8, data[0..7], &MAGIC)) return error.InvalidMagic;
        if (data[7] != FORMAT_VERSION) return error.UnsupportedVersion;

        const expected_digest = crypto.hashBytes(data[0..64]);
        if (!std.mem.eql(u8, &expected_digest, data[64..96])) return error.CorruptHeader;

        const meta = HeaderMeta{
            .entry_count = std.mem.readInt(u64, data[8..16], .little),
            .page_count = std.mem.readInt(u32, data[16..20], .little),
            .page_dir_off = std.mem.readInt(u64, data[24..32], .little),
            .fence_arena_off = std.mem.readInt(u64, data[32..40], .little),
            .fence_arena_len = std.mem.readInt(u64, data[40..48], .little),
            .rev_idx_off = std.mem.readInt(u64, data[48..56], .little),
            .file_size = std.mem.readInt(u64, data[56..64], .little),
        };

        if (meta.file_size != data.len) return error.CorruptHeader;
        if (meta.entry_count == 0 and meta.page_count != 0) return error.CorruptHeader;
        if (meta.entry_count > 0 and meta.page_count == 0) return error.CorruptHeader;

        if (meta.page_dir_off < HEADER_SIZE) return error.CorruptHeader;
        const dir_bytes = std.math.mul(u64, meta.page_count, PAGE_DIR_ENTRY_SIZE) catch return error.CorruptHeader;
        const dir_end = std.math.add(u64, meta.page_dir_off, dir_bytes) catch return error.CorruptHeader;
        if (dir_end > meta.fence_arena_off) return error.CorruptHeader;

        const fence_end = std.math.add(u64, meta.fence_arena_off, meta.fence_arena_len) catch return error.CorruptHeader;
        if (fence_end > meta.rev_idx_off) return error.CorruptHeader;

        const rev_bytes = std.math.mul(u64, meta.entry_count, REV_IDX_ENTRY_SIZE) catch return error.CorruptHeader;
        const rev_end = std.math.add(u64, meta.rev_idx_off, rev_bytes) catch return error.CorruptHeader;
        if (rev_end > meta.file_size) return error.CorruptHeader;

        return meta;
    }
};

const InodeIdContext = struct {
    pub fn hash(_: InodeIdContext, key: id.InodeId) u64 {
        var h = std.hash.Wyhash.init(0);
        var buf: [28]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], key.op.ts, .little);
        std.mem.writeInt(u128, buf[8..24], key.op.actor, .little);
        std.mem.writeInt(u32, buf[24..28], key.part, .little);
        h.update(&buf);
        return h.final();
    }

    pub fn eql(_: InodeIdContext, a: id.InodeId, b: id.InodeId) bool {
        return a.eql(b);
    }
};

const OverlayRef = struct {
    key: []const u8,
    val: ?ShadowEntry,

    fn lessThan(_: void, a: OverlayRef, b: OverlayRef) bool {
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

const BaseCursor = struct {
    allocator: Allocator,
    base: ?*const mmap.MappedFile,
    page_count: u32,
    page_dir_off: u64,
    page_idx: u32,
    slot_idx: u16,
    page_entry_count: u16,
    page_slice: []const u8,
    page_pos: usize,
    has_current: bool,
    path_buf: std.ArrayList(u8),
    current_entry: ShadowEntry,

    fn init(allocator: Allocator, store: *const ShadowStore) !BaseCursor {
        var self = BaseCursor{
            .allocator = allocator,
            .base = store.base,
            .page_count = store.meta.page_count,
            .page_dir_off = store.meta.page_dir_off,
            .page_idx = 0,
            .slot_idx = 0,
            .page_entry_count = 0,
            .page_slice = "",
            .page_pos = 0,
            .has_current = false,
            .path_buf = .empty,
            .current_entry = undefined,
        };
        errdefer self.path_buf.deinit(allocator);

        if (self.base != null and self.page_count > 0) {
            try self.loadPage(0);
            if (self.page_entry_count == 0) return error.CorruptPage;
            try self.decodeNextInPage();
        }
        return self;
    }

    fn deinit(self: *BaseCursor) void {
        self.path_buf.deinit(self.allocator);
    }

    fn currentPath(self: *const BaseCursor) []const u8 {
        return self.path_buf.items;
    }

    fn loadPage(self: *BaseCursor, idx: u32) !void {
        const mf = self.base orelse return error.CorruptPage;
        const dir_off = self.page_dir_off + @as(u64, idx) * PAGE_DIR_ENTRY_SIZE;
        const dir_slice = try mf.sliceCheckedU64(dir_off, PAGE_DIR_ENTRY_SIZE);
        const dir = PageDirEntry.decode(dir_slice[0..PAGE_DIR_ENTRY_SIZE]);

        const page_bytes = try mf.sliceCheckedU64(dir.page_file_off, dir.page_len);
        if (codec.crc32c(page_bytes) != dir.page_crc32c) return error.CorruptPage;

        self.page_idx = idx;
        self.slot_idx = 0;
        self.page_entry_count = dir.entry_count;
        self.page_slice = page_bytes;
        self.page_pos = 0;
        self.path_buf.clearRetainingCapacity();
    }

    fn decodeNextInPage(self: *BaseCursor) !void {
        if (self.page_pos + 4 > self.page_slice.len) return error.CorruptPage;
        const shared_prefix: usize = std.mem.readInt(u16, self.page_slice[self.page_pos .. self.page_pos + 2][0..2], .little);
        const suffix_len: usize = std.mem.readInt(u16, self.page_slice[self.page_pos + 2 .. self.page_pos + 4][0..2], .little);
        self.page_pos += 4;

        if (self.slot_idx == 0 and shared_prefix != 0) return error.CorruptPage;
        if (shared_prefix > self.path_buf.items.len) return error.CorruptPage;
        if (self.page_pos + suffix_len + ENTRY_FIXED_SIZE > self.page_slice.len) return error.CorruptPage;

        const suffix = self.page_slice[self.page_pos .. self.page_pos + suffix_len];
        self.page_pos += suffix_len;

        self.path_buf.items.len = shared_prefix;
        try self.path_buf.appendSlice(self.allocator, suffix);

        const entry_bytes = self.page_slice[self.page_pos .. self.page_pos + ENTRY_FIXED_SIZE];
        self.page_pos += ENTRY_FIXED_SIZE;

        self.current_entry = try ShadowEntry.decode(entry_bytes[0..ENTRY_FIXED_SIZE]);
        self.slot_idx += 1;
        self.has_current = true;
    }

    fn advance(self: *BaseCursor) !void {
        if (self.base == null or self.page_count == 0) {
            self.has_current = false;
            return;
        }
        if (self.slot_idx < self.page_entry_count) {
            try self.decodeNextInPage();
            return;
        }
        const next_page = self.page_idx + 1;
        if (next_page >= self.page_count) {
            self.has_current = false;
            return;
        }
        try self.loadPage(next_page);
        if (self.page_entry_count == 0) return error.CorruptPage;
        try self.decodeNextInPage();
    }
};

const BufferedFileWriter = struct {
    io: Io,
    file: Io.File,
    buf: [65536]u8 = undefined,
    buf_len: usize = 0,
    flush_off: u64,

    fn init(io: Io, file: Io.File, start_off: u64) BufferedFileWriter {
        return .{
            .io = io,
            .file = file,
            .flush_off = start_off,
        };
    }

    fn filePos(self: *const BufferedFileWriter) u64 {
        return self.flush_off + self.buf_len;
    }

    fn writeAll(self: *BufferedFileWriter, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const avail = self.buf.len - self.buf_len;
            if (avail == 0) {
                try self.flush();
                continue;
            }
            if (self.buf_len == 0 and remaining.len >= self.buf.len) {
                try self.file.writePositionalAll(self.io, remaining, self.flush_off);
                self.flush_off += remaining.len;
                return;
            }
            const take = @min(avail, remaining.len);
            @memcpy(self.buf[self.buf_len .. self.buf_len + take], remaining[0..take]);
            self.buf_len += take;
            remaining = remaining[take..];
        }
    }

    fn flush(self: *BufferedFileWriter) !void {
        if (self.buf_len == 0) return;
        try self.file.writePositionalAll(self.io, self.buf[0..self.buf_len], self.flush_off);
        self.flush_off += self.buf_len;
        self.buf_len = 0;
    }
};

fn sharedPrefixLen(a: []const u8, b: []const u8) u16 {
    const limit = @min(@min(a.len, b.len), std.math.maxInt(u16));
    var i: usize = 0;
    while (i < limit and a[i] == b[i]) : (i += 1) {}
    return @intCast(i);
}

pub const ShadowStore = struct {
    pub const Item = struct {
        rel_path: []const u8,
        entry: ShadowEntry,
    };

    pub const Iterator = struct {
        allocator: Allocator,
        base_cursor: BaseCursor,
        overlay_items: []OverlayRef,
        overlay_idx: usize,
        need_advance_base: bool,

        pub fn deinit(self: *Iterator) void {
            self.base_cursor.deinit();
            self.allocator.free(self.overlay_items);
        }

        pub fn next(self: *Iterator) !?Item {
            if (self.need_advance_base) {
                self.need_advance_base = false;
                try self.base_cursor.advance();
            }

            while (true) {
                const b_ok = self.base_cursor.has_current;
                const o_ok = self.overlay_idx < self.overlay_items.len;
                if (!b_ok and !o_ok) return null;

                if (b_ok and !o_ok) {
                    self.need_advance_base = true;
                    return .{
                        .rel_path = self.base_cursor.currentPath(),
                        .entry = self.base_cursor.current_entry,
                    };
                }

                if (!b_ok and o_ok) {
                    const ov = self.overlay_items[self.overlay_idx];
                    self.overlay_idx += 1;
                    if (ov.val) |e| {
                        return .{
                            .rel_path = ov.key,
                            .entry = e,
                        };
                    }
                    continue;
                }

                const b_path = self.base_cursor.currentPath();
                const ov = self.overlay_items[self.overlay_idx];
                switch (std.mem.order(u8, b_path, ov.key)) {
                    .lt => {
                        self.need_advance_base = true;
                        return .{
                            .rel_path = b_path,
                            .entry = self.base_cursor.current_entry,
                        };
                    },
                    .gt => {
                        self.overlay_idx += 1;
                        if (ov.val) |e| {
                            return .{
                                .rel_path = ov.key,
                                .entry = e,
                            };
                        }
                        continue;
                    },
                    .eq => {
                        self.overlay_idx += 1;
                        try self.base_cursor.advance();
                        if (ov.val) |e| {
                            return .{
                                .rel_path = ov.key,
                                .entry = e,
                            };
                        }
                        continue;
                    },
                }
            }
        }
    };

    allocator: Allocator,
    base: ?*mmap.MappedFile,
    meta: HeaderMeta,
    overlay: std.StringHashMapUnmanaged(?ShadowEntry),
    overlay_by_inode: std.HashMapUnmanaged(id.InodeId, []const u8, InodeIdContext, std.hash_map.default_max_load_percentage),
    live_delta: i64,

    pub fn open(allocator: Allocator, io: Io, dir: Io.Dir, filename: []const u8) !ShadowStore {
        const mf_opt = mmap.MappedFile.open(allocator, io, dir, filename) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        if (mf_opt) |mf| {
            errdefer mf.release(allocator);
            const meta = try HeaderMeta.parse(mf);
            return .{
                .allocator = allocator,
                .base = mf,
                .meta = meta,
                .overlay = .empty,
                .overlay_by_inode = .empty,
                .live_delta = 0,
            };
        }

        return .{
            .allocator = allocator,
            .base = null,
            .meta = .{
                .entry_count = 0,
                .page_count = 0,
                .page_dir_off = HEADER_SIZE,
                .fence_arena_off = HEADER_SIZE,
                .fence_arena_len = 0,
                .rev_idx_off = HEADER_SIZE,
                .file_size = HEADER_SIZE,
            },
            .overlay = .empty,
            .overlay_by_inode = .empty,
            .live_delta = 0,
        };
    }

    pub fn deinit(self: *ShadowStore) void {
        self.clearOverlay();
        self.overlay.deinit(self.allocator);
        self.overlay_by_inode.deinit(self.allocator);
        if (self.base) |mf| {
            mf.release(self.allocator);
            self.base = null;
        }
    }

    fn clearOverlay(self: *ShadowStore) void {
        var it = self.overlay.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.overlay.clearRetainingCapacity();
        self.overlay_by_inode.clearRetainingCapacity();
    }

    fn readPageDirEntry(self: *const ShadowStore, page_idx: u32) !PageDirEntry {
        const mf = self.base orelse return error.CorruptPage;
        const off = self.meta.page_dir_off + @as(u64, page_idx) * PAGE_DIR_ENTRY_SIZE;
        const raw = try mf.sliceCheckedU64(off, PAGE_DIR_ENTRY_SIZE);
        return PageDirEntry.decode(raw[0..PAGE_DIR_ENTRY_SIZE]);
    }

    fn fenceKey(self: *const ShadowStore, page_idx: u32) ![]const u8 {
        const mf = self.base orelse return error.CorruptPage;
        const dir = try self.readPageDirEntry(page_idx);
        const end = std.math.add(u64, dir.first_path_off, dir.first_path_len) catch return error.CorruptPage;
        if (end > self.meta.fence_arena_len) return error.CorruptPage;
        return try mf.sliceCheckedU64(self.meta.fence_arena_off + dir.first_path_off, dir.first_path_len);
    }

    fn baseGet(self: *const ShadowStore, rel_path: []const u8) !?ShadowEntry {
        const mf = self.base orelse return null;
        if (self.meta.page_count == 0) return null;

        const first_fence = try self.fenceKey(0);
        if (std.mem.order(u8, rel_path, first_fence) == .lt) return null;

        var lo: u32 = 0;
        var hi: u32 = self.meta.page_count;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            const fk = try self.fenceKey(mid);
            if (std.mem.order(u8, fk, rel_path) != .gt) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        const dir = try self.readPageDirEntry(lo);
        const page_bytes = try mf.sliceCheckedU64(dir.page_file_off, dir.page_len);
        if (codec.crc32c(page_bytes) != dir.page_crc32c) return error.CorruptPage;

        var stack_buf: [4096]u8 = undefined;
        var heap_buf: std.ArrayList(u8) = .empty;
        defer heap_buf.deinit(self.allocator);
        var use_heap = false;
        var cur_len: usize = 0;

        var pos: usize = 0;
        var slot: u16 = 0;
        while (slot < dir.entry_count) : (slot += 1) {
            if (pos + 4 > page_bytes.len) return error.CorruptPage;
            const shared_len: usize = std.mem.readInt(u16, page_bytes[pos .. pos + 2][0..2], .little);
            const suffix_len: usize = std.mem.readInt(u16, page_bytes[pos + 2 .. pos + 4][0..2], .little);
            pos += 4;

            if (slot == 0 and shared_len != 0) return error.CorruptPage;
            if (shared_len > cur_len) return error.CorruptPage;
            if (pos + suffix_len + ENTRY_FIXED_SIZE > page_bytes.len) return error.CorruptPage;

            const suffix = page_bytes[pos .. pos + suffix_len];
            pos += suffix_len;
            const entry_bytes = page_bytes[pos .. pos + ENTRY_FIXED_SIZE];
            pos += ENTRY_FIXED_SIZE;

            const new_len = shared_len + suffix_len;
            var cur_path: []const u8 = undefined;
            if (!use_heap and new_len <= stack_buf.len) {
                @memcpy(stack_buf[shared_len..new_len], suffix);
                cur_len = new_len;
                cur_path = stack_buf[0..cur_len];
            } else {
                if (!use_heap) {
                    try heap_buf.ensureTotalCapacity(self.allocator, new_len);
                    heap_buf.appendSliceAssumeCapacity(stack_buf[0..shared_len]);
                    use_heap = true;
                } else {
                    heap_buf.items.len = shared_len;
                }
                try heap_buf.appendSlice(self.allocator, suffix);
                cur_len = heap_buf.items.len;
                cur_path = heap_buf.items;
            }

            switch (std.mem.order(u8, cur_path, rel_path)) {
                .eq => return try ShadowEntry.decode(entry_bytes[0..ENTRY_FIXED_SIZE]),
                .gt => return null,
                .lt => {},
            }
        }

        return null;
    }

    fn baseContains(self: *const ShadowStore, rel_path: []const u8) !bool {
        return (try self.baseGet(rel_path)) != null;
    }

    fn decodePathAtSlot(self: *const ShadowStore, allocator: Allocator, page_idx: u32, target_slot: u16) ![]u8 {
        const mf = self.base orelse return error.CorruptPage;
        if (page_idx >= self.meta.page_count) return error.CorruptPage;

        const dir = try self.readPageDirEntry(page_idx);
        if (target_slot >= dir.entry_count) return error.CorruptPage;

        const page_bytes = try mf.sliceCheckedU64(dir.page_file_off, dir.page_len);
        if (codec.crc32c(page_bytes) != dir.page_crc32c) return error.CorruptPage;

        var path_buf: std.ArrayList(u8) = .empty;
        errdefer path_buf.deinit(allocator);

        var pos: usize = 0;
        var slot: u16 = 0;
        while (slot <= target_slot) : (slot += 1) {
            if (pos + 4 > page_bytes.len) return error.CorruptPage;
            const shared_len: usize = std.mem.readInt(u16, page_bytes[pos .. pos + 2][0..2], .little);
            const suffix_len: usize = std.mem.readInt(u16, page_bytes[pos + 2 .. pos + 4][0..2], .little);
            pos += 4;

            if (slot == 0 and shared_len != 0) return error.CorruptPage;
            if (shared_len > path_buf.items.len) return error.CorruptPage;
            if (pos + suffix_len + ENTRY_FIXED_SIZE > page_bytes.len) return error.CorruptPage;

            const suffix = page_bytes[pos .. pos + suffix_len];
            pos += suffix_len + ENTRY_FIXED_SIZE;

            path_buf.items.len = shared_len;
            try path_buf.appendSlice(allocator, suffix);
        }

        return try path_buf.toOwnedSlice(allocator);
    }

    fn readRevIdxEntry(self: *const ShadowStore, idx: u64) !RevIdxEntry {
        const mf = self.base orelse return error.CorruptPage;
        const off = self.meta.rev_idx_off + idx * REV_IDX_ENTRY_SIZE;
        const raw = try mf.sliceCheckedU64(off, REV_IDX_ENTRY_SIZE);
        return RevIdxEntry.decode(raw[0..REV_IDX_ENTRY_SIZE]);
    }

    pub fn get(self: *const ShadowStore, rel_path: []const u8) !?ShadowEntry {
        if (self.overlay.get(rel_path)) |ov| {
            return ov;
        }
        return try self.baseGet(rel_path);
    }

    pub fn pathOfInode(self: *const ShadowStore, allocator: Allocator, iid: id.InodeId) !?[]u8 {
        if (self.overlay_by_inode.get(iid)) |ov_path| {
            return try allocator.dupe(u8, ov_path);
        }

        if (self.base == null or self.meta.entry_count == 0) return null;

        var lo: u64 = 0;
        var hi: u64 = self.meta.entry_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rev = try self.readRevIdxEntry(mid);
            if (rev.inode_id.order(iid) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        var idx = lo;
        while (idx < self.meta.entry_count) : (idx += 1) {
            const rev = try self.readRevIdxEntry(idx);
            if (!rev.inode_id.eql(iid)) break;

            const path = try self.decodePathAtSlot(allocator, rev.page_idx, rev.slot_idx);
            if (self.overlay.get(path)) |ov_opt| {
                if (ov_opt) |ov_e| {
                    if (ov_e.inode_id.eql(iid)) return path;
                }
                allocator.free(path);
                continue;
            }
            return path;
        }

        return null;
    }

    pub fn put(self: *ShadowStore, rel_path: []const u8, entry: ShadowEntry) !void {
        if (rel_path.len > std.math.maxInt(u16)) return error.PathTooLong;

        if (self.overlay.getEntry(rel_path)) |kv| {
            if (kv.value_ptr.*) |old_e| {
                if (self.overlay_by_inode.get(old_e.inode_id)) |mapped| {
                    if (std.mem.eql(u8, mapped, kv.key_ptr.*)) {
                        _ = self.overlay_by_inode.remove(old_e.inode_id);
                    }
                }
            } else {
                self.live_delta += 1;
            }
            try self.overlay_by_inode.put(self.allocator, entry.inode_id, kv.key_ptr.*);
            kv.value_ptr.* = entry;
            return;
        }

        const in_base = try self.baseContains(rel_path);
        const owned_key = try self.allocator.dupe(u8, rel_path);
        errdefer self.allocator.free(owned_key);

        try self.overlay.put(self.allocator, owned_key, entry);
        errdefer _ = self.overlay.remove(owned_key);

        try self.overlay_by_inode.put(self.allocator, entry.inode_id, owned_key);
        if (!in_base) {
            self.live_delta += 1;
        }
    }

    pub fn remove(self: *ShadowStore, rel_path: []const u8) !void {
        if (self.overlay.getEntry(rel_path)) |kv| {
            const old_e = kv.value_ptr.* orelse return;
            if (self.overlay_by_inode.get(old_e.inode_id)) |mapped| {
                if (std.mem.eql(u8, mapped, kv.key_ptr.*)) {
                    _ = self.overlay_by_inode.remove(old_e.inode_id);
                }
            }
            const in_base = try self.baseContains(rel_path);
            if (in_base) {
                kv.value_ptr.* = null;
            } else {
                if (self.overlay.fetchRemove(rel_path)) |removed| {
                    self.allocator.free(removed.key);
                }
            }
            self.live_delta -= 1;
            return;
        }

        const in_base = try self.baseContains(rel_path);
        if (!in_base) return;

        const owned_key = try self.allocator.dupe(u8, rel_path);
        errdefer self.allocator.free(owned_key);

        try self.overlay.put(self.allocator, owned_key, null);
        self.live_delta -= 1;
    }

    pub fn count(self: *const ShadowStore) u64 {
        const total = @as(i128, self.meta.entry_count) + self.live_delta;
        return if (total < 0) 0 else @intCast(total);
    }

    pub fn dirtyCount(self: *const ShadowStore) usize {
        return self.overlay.count();
    }

    pub fn iterateAll(self: *const ShadowStore, allocator: Allocator) !Iterator {
        var base_cursor = try BaseCursor.init(allocator, self);
        errdefer base_cursor.deinit();

        const overlay_items = try allocator.alloc(OverlayRef, self.overlay.count());
        errdefer allocator.free(overlay_items);

        var idx: usize = 0;
        var it = self.overlay.iterator();
        while (it.next()) |kv| {
            overlay_items[idx] = .{
                .key = kv.key_ptr.*,
                .val = kv.value_ptr.*,
            };
            idx += 1;
        }
        std.mem.sort(OverlayRef, overlay_items, {}, OverlayRef.lessThan);

        return .{
            .allocator = allocator,
            .base_cursor = base_cursor,
            .overlay_items = overlay_items,
            .overlay_idx = 0,
            .need_advance_base = false,
        };
    }

    fn flushPage(
        allocator: Allocator,
        writer: *BufferedFileWriter,
        page_buf: *std.ArrayList(u8),
        first_path: []const u8,
        page_entry_count: u16,
        page_dir: *std.ArrayList(PageDirEntry),
        fence_arena: *std.ArrayList(u8),
    ) !void {
        const page_file_off = writer.filePos();
        const page_bytes = page_buf.items;
        const page_crc = codec.crc32c(page_bytes);

        const first_path_off: u32 = std.math.cast(u32, fence_arena.items.len) orelse return error.ArenaOverflow;
        const first_path_len: u16 = std.math.cast(u16, first_path.len) orelse return error.PathTooLong;
        try fence_arena.appendSlice(allocator, first_path);

        try writer.writeAll(page_bytes);

        try page_dir.append(allocator, .{
            .first_path_off = first_path_off,
            .first_path_len = first_path_len,
            .entry_count = page_entry_count,
            .page_file_off = page_file_off,
            .page_len = std.math.cast(u32, page_bytes.len) orelse return error.PageTooLarge,
            .page_crc32c = page_crc,
        });

        page_buf.clearRetainingCapacity();
    }

    pub fn flushAtomic(self: *ShadowStore, io: Io, dir: Io.Dir, filename: []const u8) !void {
        if (self.count() == 0) {
            const empty_meta = HeaderMeta{
                .entry_count = 0,
                .page_count = 0,
                .page_dir_off = HEADER_SIZE,
                .fence_arena_off = HEADER_SIZE,
                .fence_arena_len = 0,
                .rev_idx_off = HEADER_SIZE,
                .file_size = HEADER_SIZE,
            };
            const hdr_buf = empty_meta.encode();
            try mmap.atomicWriteFile(io, dir, filename, &hdr_buf);
            try self.remapAndClear(io, dir, filename);
            return;
        }

        const sub_dir_name = std.fs.path.dirname(filename);
        const base_name = std.fs.path.basename(filename);

        var owned_sub: ?Io.Dir = null;
        defer if (owned_sub) |*d| d.close(io);

        const target_dir = if (sub_dir_name) |sub| blk: {
            try dir.createDirPath(io, sub);
            owned_sub = try dir.openDir(io, sub, .{ .iterate = true });
            break :blk owned_sub.?;
        } else dir;

        var tmp_buf: [512]u8 = undefined;
        const seq = tmp_seq.fetchAdd(1, .monotonic);
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, "tmp.{s}.{d}.{d}", .{ base_name, currentPid(), seq });

        const file = try target_dir.createFile(io, tmp_name, .{ .truncate = true });
        var file_closed = false;
        var renamed = false;
        errdefer {
            if (!file_closed) file.close(io);
            if (!renamed) target_dir.deleteFile(io, tmp_name) catch {};
        }

        var writer = BufferedFileWriter.init(io, file, HEADER_SIZE);

        var page_buf: std.ArrayList(u8) = .empty;
        defer page_buf.deinit(self.allocator);
        try page_buf.ensureTotalCapacity(self.allocator, PAGE_SIZE);

        var prev_path: std.ArrayList(u8) = .empty;
        defer prev_path.deinit(self.allocator);

        var first_path: std.ArrayList(u8) = .empty;
        defer first_path.deinit(self.allocator);

        var page_dir: std.ArrayList(PageDirEntry) = .empty;
        defer page_dir.deinit(self.allocator);

        var fence_arena: std.ArrayList(u8) = .empty;
        defer fence_arena.deinit(self.allocator);

        var rev_entries: std.ArrayList(RevIdxEntry) = .empty;
        defer rev_entries.deinit(self.allocator);

        var page_entry_count: u16 = 0;
        var total_entries: u64 = 0;

        var it = try self.iterateAll(self.allocator);
        defer it.deinit();

        while (try it.next()) |item| {
            if (item.rel_path.len > std.math.maxInt(u16)) return error.PathTooLong;

            var prefix_len: u16 = if (page_entry_count == 0) 0 else sharedPrefixLen(prev_path.items, item.rel_path);
            var suffix = item.rel_path[prefix_len..];
            var rec_len = 4 + suffix.len + ENTRY_FIXED_SIZE;

            if (page_entry_count > 0 and (page_buf.items.len + rec_len > PAGE_SIZE or page_entry_count == std.math.maxInt(u16))) {
                try flushPage(
                    self.allocator,
                    &writer,
                    &page_buf,
                    first_path.items,
                    page_entry_count,
                    &page_dir,
                    &fence_arena,
                );
                prev_path.clearRetainingCapacity();
                first_path.clearRetainingCapacity();
                page_entry_count = 0;
                prefix_len = 0;
                suffix = item.rel_path;
                rec_len = 4 + suffix.len + ENTRY_FIXED_SIZE;
            }

            if (page_entry_count == 0) {
                first_path.clearRetainingCapacity();
                try first_path.appendSlice(self.allocator, item.rel_path);
            }

            var rec_hdr: [4]u8 = undefined;
            std.mem.writeInt(u16, rec_hdr[0..2], prefix_len, .little);
            std.mem.writeInt(u16, rec_hdr[2..4], @intCast(suffix.len), .little);
            try page_buf.appendSlice(self.allocator, &rec_hdr);
            try page_buf.appendSlice(self.allocator, suffix);
            const encoded = item.entry.encode();
            try page_buf.appendSlice(self.allocator, &encoded);

            const cur_page_idx: u32 = std.math.cast(u32, page_dir.items.len) orelse return error.TooManyPages;
            try rev_entries.append(self.allocator, .{
                .inode_id = item.entry.inode_id,
                .page_idx = cur_page_idx,
                .slot_idx = page_entry_count,
            });

            prev_path.clearRetainingCapacity();
            try prev_path.appendSlice(self.allocator, item.rel_path);
            page_entry_count += 1;
            total_entries += 1;
        }

        if (page_entry_count > 0) {
            try flushPage(
                self.allocator,
                &writer,
                &page_buf,
                first_path.items,
                page_entry_count,
                &page_dir,
                &fence_arena,
            );
        }

        const page_dir_off = writer.filePos();
        for (page_dir.items) |pde| {
            const raw = pde.encode();
            try writer.writeAll(&raw);
        }

        const fence_arena_off = writer.filePos();
        const fence_arena_len: u64 = fence_arena.items.len;
        try writer.writeAll(fence_arena.items);

        std.mem.sort(RevIdxEntry, rev_entries.items, {}, RevIdxEntry.lessThan);
        const rev_idx_off = writer.filePos();
        for (rev_entries.items) |re| {
            const raw = re.encode();
            try writer.writeAll(&raw);
        }

        try writer.flush();
        const file_size = writer.filePos();

        const meta = HeaderMeta{
            .entry_count = total_entries,
            .page_count = std.math.cast(u32, page_dir.items.len) orelse return error.TooManyPages,
            .page_dir_off = page_dir_off,
            .fence_arena_off = fence_arena_off,
            .fence_arena_len = fence_arena_len,
            .rev_idx_off = rev_idx_off,
            .file_size = file_size,
        };
        const hdr_buf = meta.encode();
        try file.writePositionalAll(io, &hdr_buf, 0);
        try file.sync(io);
        file.close(io);
        file_closed = true;

        try target_dir.rename(tmp_name, target_dir, base_name, io);
        renamed = true;

        try mmap.fsyncDir(io, target_dir);
        try self.remapAndClear(io, dir, filename);
    }

    fn remapAndClear(self: *ShadowStore, io: Io, dir: Io.Dir, filename: []const u8) !void {
        const new_base = try mmap.MappedFile.open(self.allocator, io, dir, filename);
        errdefer new_base.release(self.allocator);
        const new_meta = try HeaderMeta.parse(new_base);

        if (self.base) |old_base| {
            old_base.release(self.allocator);
        }
        self.base = new_base;
        self.meta = new_meta;
        self.clearOverlay();
        self.live_delta = 0;
    }

    pub fn hibernate(self: *ShadowStore) void {
        if (self.base) |mf| {
            mf.hibernate();
        }
        if (self.overlay.count() == 0) {
            self.overlay.deinit(self.allocator);
            self.overlay = .empty;
            self.overlay_by_inode.deinit(self.allocator);
            self.overlay_by_inode = .empty;
        }
    }
};
