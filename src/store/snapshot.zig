const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const dag_mod = @import("../core/dag.zig");
const text_mod = @import("../core/text.zig");
const tree_mod = @import("../core/tree.zig");
const history_mod = @import("../core/history.zig");
const git_dirs = @import("../fs/git_dirs.zig");
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");
const mmap = @import("mmap.zig");

pub const MAGIC: [8]u8 = .{ '0', 'N', 'D', 'S', 'N', 'A', 'P', '1' };
pub const PAGE_MAGIC: [4]u8 = .{ '0', 'N', 'P', 'G' };
pub const FORMAT_VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 256;
pub const SECTION_DESC_SIZE: usize = 32;
pub const PAGE_SIZE: usize = 4096;
pub const TRAILER_SIZE: usize = 32;

pub const FLAG_DELTA: u32 = 1 << 0;
pub const FLAG_HAS_HORIZON: u32 = 1 << 1;

pub const SEC_ACTORS: u32 = 1;
pub const SEC_DAG: u32 = 2;
pub const SEC_INODES: u32 = 3;
pub const SEC_DIR_NAME_IDX: u32 = 4;
pub const SEC_DIR_CHILDREN: u32 = 5;
pub const SEC_TEXT_NODES: u32 = 6;
pub const SEC_INSERTIONS: u32 = 7;
pub const SEC_META_SCOPES: u32 = 8;

pub const SnapshotError = error{
    CorruptSnapshot,
    CorruptPage,
    UnsupportedVersion,
};

pub const Header = struct {
    version: u32 = FORMAT_VERSION,
    flags: u32 = 0,
    history_id: u128 = 0,
    generation: u64 = 0,
    base_generation: u64 = 0,
    wal_cutoff_seq: u64 = 0,
    max_ts: u64 = 0,
    next_batch_idx: u32 = 0,
    section_count: u32 = 0,
    file_size: u64 = 0,
    created_ms: u64 = 0,
    page_size: u32 = PAGE_SIZE,
    section_table_off: u64 = HEADER_SIZE,
    superblock_blake3: [32]u8 = @splat(0),

    pub fn encode(self: *const Header, section_table_bytes: []const u8) [HEADER_SIZE]u8 {
        var buf: [HEADER_SIZE]u8 = @splat(0);
        @memcpy(buf[0..8], &MAGIC);
        std.mem.writeInt(u32, buf[8..12], self.version, .little);
        std.mem.writeInt(u32, buf[12..16], self.flags, .little);
        std.mem.writeInt(u128, buf[16..32], self.history_id, .little);
        std.mem.writeInt(u64, buf[32..40], self.generation, .little);
        std.mem.writeInt(u64, buf[40..48], self.base_generation, .little);
        std.mem.writeInt(u64, buf[48..56], self.wal_cutoff_seq, .little);
        std.mem.writeInt(u64, buf[56..64], self.max_ts, .little);
        std.mem.writeInt(u32, buf[64..68], self.next_batch_idx, .little);
        std.mem.writeInt(u32, buf[68..72], self.section_count, .little);
        std.mem.writeInt(u64, buf[72..80], self.file_size, .little);
        std.mem.writeInt(u64, buf[80..88], self.created_ms, .little);
        std.mem.writeInt(u32, buf[88..92], self.page_size, .little);
        std.mem.writeInt(u64, buf[96..104], self.section_table_off, .little);
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(buf[0..224]);
        hasher.update(section_table_bytes);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        @memcpy(buf[224..256], &digest);
        return buf;
    }

    pub fn decodeAndVerify(data: []const u8) SnapshotError!Header {
        if (data.len < HEADER_SIZE + TRAILER_SIZE) return error.CorruptSnapshot;
        if (!std.mem.eql(u8, data[0..8], &MAGIC)) return error.CorruptSnapshot;
        const ver = std.mem.readInt(u32, data[8..12], .little);
        if (ver != FORMAT_VERSION) return error.UnsupportedVersion;
        const sec_count = std.mem.readInt(u32, data[68..72], .little);
        const file_size = std.mem.readInt(u64, data[72..80], .little);
        const page_sz = std.mem.readInt(u32, data[88..92], .little);
        const sec_off = std.mem.readInt(u64, data[96..104], .little);
        if (file_size != data.len or page_sz != PAGE_SIZE or sec_count > 32) return error.CorruptSnapshot;
        const sec_table_len = @as(u64, sec_count) * SECTION_DESC_SIZE;
        if (sec_off + sec_table_len > data.len - TRAILER_SIZE) return error.CorruptSnapshot;
        const sec_bytes = data[@intCast(sec_off)..@intCast(sec_off + sec_table_len)];
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(data[0..224]);
        hasher.update(sec_bytes);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, data[224..256])) return error.CorruptSnapshot;
        return .{
            .version = ver,
            .flags = std.mem.readInt(u32, data[12..16], .little),
            .history_id = std.mem.readInt(u128, data[16..32], .little),
            .generation = std.mem.readInt(u64, data[32..40], .little),
            .base_generation = std.mem.readInt(u64, data[40..48], .little),
            .wal_cutoff_seq = std.mem.readInt(u64, data[48..56], .little),
            .max_ts = std.mem.readInt(u64, data[56..64], .little),
            .next_batch_idx = std.mem.readInt(u32, data[64..68], .little),
            .section_count = sec_count,
            .file_size = file_size,
            .created_ms = std.mem.readInt(u64, data[80..88], .little),
            .page_size = page_sz,
            .section_table_off = sec_off,
            .superblock_blake3 = data[224..256].*,
        };
    }
};

pub const SectionDesc = struct {
    kind: u32,
    flags: u32,
    offset: u64,
    len: u64,
    count: u64,

    pub fn encode(self: SectionDesc) [SECTION_DESC_SIZE]u8 {
        var b: [SECTION_DESC_SIZE]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], self.kind, .little);
        std.mem.writeInt(u32, b[4..8], self.flags, .little);
        std.mem.writeInt(u64, b[8..16], self.offset, .little);
        std.mem.writeInt(u64, b[16..24], self.len, .little);
        std.mem.writeInt(u64, b[24..32], self.count, .little);
        return b;
    }

    pub fn decode(b: *const [SECTION_DESC_SIZE]u8) SectionDesc {
        return .{
            .kind = std.mem.readInt(u32, b[0..4], .little),
            .flags = std.mem.readInt(u32, b[4..8], .little),
            .offset = std.mem.readInt(u64, b[8..16], .little),
            .len = std.mem.readInt(u64, b[16..24], .little),
            .count = std.mem.readInt(u64, b[24..32], .little),
        };
    }
};

pub const DiskBatchEntry = extern struct {
    end_ts: u64,
    start_delta: u32,
    actor_idx: u32,
    batch_idx: u32,
    log_seg: u32,
    log_len: u32,
    parents_off: u32,
    log_off_and_flags: u64,
    wall_ms_and_pcount: u64,

    comptime {
        std.debug.assert(@sizeOf(DiskBatchEntry) == 48);
    }

    pub fn make(
        start: u64,
        end: u64,
        actor_idx: u32,
        batch_idx: u32,
        log_seg: u32,
        log_off: u64,
        log_len: u32,
        wall_ms: u64,
        parents_off: u32,
        parents_count: u16,
        entry_flags: u16,
    ) DiskBatchEntry {
        const delta_u64 = end -| start;
        const delta: u32 = @intCast(@min(delta_u64, std.math.maxInt(u32)));
        const lo48: u64 = log_off & 0x0000_FFFF_FFFF_FFFF;
        const wm48: u64 = wall_ms & 0x0000_FFFF_FFFF_FFFF;
        return .{
            .end_ts = end,
            .start_delta = delta,
            .actor_idx = actor_idx,
            .batch_idx = batch_idx,
            .log_seg = log_seg,
            .log_len = log_len,
            .parents_off = parents_off,
            .log_off_and_flags = lo48 | (@as(u64, entry_flags) << 48),
            .wall_ms_and_pcount = wm48 | (@as(u64, parents_count) << 48),
        };
    }

    pub inline fn startTs(self: DiskBatchEntry) u64 {
        return self.end_ts -| @as(u64, self.start_delta);
    }

    pub inline fn logOff(self: DiskBatchEntry) u64 {
        return self.log_off_and_flags & 0x0000_FFFF_FFFF_FFFF;
    }

    pub inline fn flags(self: DiskBatchEntry) u16 {
        return @truncate(self.log_off_and_flags >> 48);
    }

    pub inline fn wallMs(self: DiskBatchEntry) u64 {
        return self.wall_ms_and_pcount & 0x0000_FFFF_FFFF_FFFF;
    }

    pub inline fn parentsCount(self: DiskBatchEntry) u16 {
        return @truncate(self.wall_ms_and_pcount >> 48);
    }
};

pub const DiskActorRun = extern struct {
    actor_idx: u32,
    batch_idx: u32,
    start_ts: u64,
    end_ts: u64,

    comptime {
        std.debug.assert(@sizeOf(DiskActorRun) == 24);
    }
};

pub const DiskOpId = extern struct {
    ts: u64,
    actor_idx: u32,
    pad: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(DiskOpId) == 16);
    }
};

pub const DiskNodeDesc = extern struct {
    offset: u64,
    len: u32,
    crc32c: u32,

    comptime {
        std.debug.assert(@sizeOf(DiskNodeDesc) == 16);
    }
};

pub const DiskInsertionEntry = extern struct {
    ts: u64,
    actor_idx: u32,
    part: u32,
    kind: u8,
    pad0: [3]u8 = .{ 0, 0, 0 },
    len: u32,
    payload_ref: u64,

    comptime {
        std.debug.assert(@sizeOf(DiskInsertionEntry) == 32);
    }
};

pub const INS_KIND_INLINE: u8 = 0;
pub const INS_KIND_BLOB: u8 = 1;
pub const INS_KIND_GIT: u8 = 2;

const INODE_KEY_LEN: usize = 28;

fn encodeInodeKey(iid: id.InodeId) [INODE_KEY_LEN]u8 {
    var out: [INODE_KEY_LEN]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], iid.op.ts, .big);
    std.mem.writeInt(u128, out[8..24], iid.op.actor, .big);
    std.mem.writeInt(u32, out[24..28], iid.part, .big);
    return out;
}

fn decodeInodeKey(b: *const [INODE_KEY_LEN]u8) id.InodeId {
    return id.InodeId.init(
        id.OpId.init(
            std.mem.readInt(u64, b[0..8], .big),
            std.mem.readInt(u128, b[8..24], .big),
        ),
        std.mem.readInt(u32, b[24..28], .big),
    );
}

fn hashName(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5A3E_0192_A4B5_C6D7, name);
}

fn encodeDirNameKey(allocator: Allocator, parent: id.InodeId, name: []const u8) Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, INODE_KEY_LEN + 8 + name.len);
    const pk = encodeInodeKey(parent);
    @memcpy(buf[0..INODE_KEY_LEN], &pk);
    std.mem.writeInt(u64, buf[INODE_KEY_LEN .. INODE_KEY_LEN + 8], hashName(name), .big);
    @memcpy(buf[INODE_KEY_LEN + 8 ..], name);
    return buf;
}

fn encodeDirChildKey(parent: id.InodeId, child: id.InodeId) [INODE_KEY_LEN * 2]u8 {
    var out: [INODE_KEY_LEN * 2]u8 = undefined;
    const pk = encodeInodeKey(parent);
    const ck = encodeInodeKey(child);
    @memcpy(out[0..INODE_KEY_LEN], &pk);
    @memcpy(out[INODE_KEY_LEN .. INODE_KEY_LEN * 2], &ck);
    return out;
}

const PageDirEntry = struct {
    page_off: u64,
    page_len: u32,
    key_off: u32,
    key_len: u32,
};

const PAGE_DIR_ENTRY_SIZE: usize = 20;
const PAGE_HDR_SIZE: usize = 24;

const SlottedRecord = struct {
    key: []u8,
    val: []u8,
    max_ts: u64 = 0,
};

fn writeSlottedSection(
    allocator: Allocator,
    records: []const SlottedRecord,
    out: *std.ArrayList(u8),
) Allocator.Error!u64 {
    var pages_buf: std.ArrayList(u8) = .empty;
    defer pages_buf.deinit(allocator);
    var dir_entries: std.ArrayList(PageDirEntry) = .empty;
    defer dir_entries.deinit(allocator);
    var fence_keys: std.ArrayList(u8) = .empty;
    defer fence_keys.deinit(allocator);

    var idx: usize = 0;
    while (idx < records.len) {
        const start_idx = idx;
        var payload_sum: usize = 0;
        var page_max_ts: u64 = 0;
        while (idx < records.len) {
            const rec_size = 4 + records[idx].key.len + records[idx].val.len;
            const next_cnt = (idx - start_idx) + 1;
            const needed = PAGE_HDR_SIZE + (next_cnt + 1) * 4 + payload_sum + rec_size;
            if (idx > start_idx and needed > PAGE_SIZE) break;
            payload_sum += rec_size;
            if (records[idx].max_ts > page_max_ts) page_max_ts = records[idx].max_ts;
            idx += 1;
            if (needed >= PAGE_SIZE) break;
        }
        const rec_count = idx - start_idx;
        const raw_len = PAGE_HDR_SIZE + (rec_count + 1) * 4 + payload_sum;
        const page_len = if (raw_len <= PAGE_SIZE) PAGE_SIZE else std.mem.alignForward(usize, raw_len, PAGE_SIZE);
        const page_off: u64 = pages_buf.items.len;
        const base = pages_buf.items.len;
        try pages_buf.resize(allocator, base + page_len);
        const page = pages_buf.items[base .. base + page_len];
        @memset(page, 0);
        @memcpy(page[0..4], &PAGE_MAGIC);
        std.mem.writeInt(u32, page[8..12], @intCast(page_len), .little);
        std.mem.writeInt(u32, page[12..16], @intCast(rec_count), .little);
        std.mem.writeInt(u64, page[16..24], page_max_ts, .little);

        const slots_base = PAGE_HDR_SIZE;
        var cursor: usize = PAGE_HDR_SIZE + (rec_count + 1) * 4;
        for (0..rec_count) |j| {
            std.mem.writeInt(u32, page[slots_base + j * 4 ..][0..4], @intCast(cursor), .little);
            const r = records[start_idx + j];
            std.mem.writeInt(u32, page[cursor..][0..4], @intCast(r.key.len), .little);
            cursor += 4;
            if (r.key.len > 0) {
                @memcpy(page[cursor .. cursor + r.key.len], r.key);
                cursor += r.key.len;
            }
            if (r.val.len > 0) {
                @memcpy(page[cursor .. cursor + r.val.len], r.val);
                cursor += r.val.len;
            }
        }
        std.mem.writeInt(u32, page[slots_base + rec_count * 4 ..][0..4], @intCast(cursor), .little);
        const crc = codec.crc32c(page[8..page_len]);
        std.mem.writeInt(u32, page[4..8], crc, .little);

        const fk_off: u32 = @intCast(fence_keys.items.len);
        const first_key = records[start_idx].key;
        try fence_keys.appendSlice(allocator, first_key);
        try dir_entries.append(allocator, .{
            .page_off = page_off,
            .page_len = @intCast(page_len),
            .key_off = fk_off,
            .key_len = @intCast(first_key.len),
        });
    }

    const dir_bytes_len: u64 = @as(u64, dir_entries.items.len) * PAGE_DIR_ENTRY_SIZE;
    const fence_len: u64 = fence_keys.items.len;
    const hdr_plus_dir = 32 + dir_bytes_len + fence_len;
    const pages_rel_off = std.mem.alignForward(u64, hdr_plus_dir, 8);
    const pad_len: usize = @intCast(pages_rel_off - hdr_plus_dir);

    var hdr: [32]u8 = @splat(0);
    std.mem.writeInt(u32, hdr[0..4], @intCast(dir_entries.items.len), .little);
    std.mem.writeInt(u32, hdr[4..8], @intCast(records.len), .little);
    std.mem.writeInt(u64, hdr[8..16], dir_bytes_len, .little);
    std.mem.writeInt(u64, hdr[16..24], fence_len, .little);
    std.mem.writeInt(u64, hdr[24..32], pages_rel_off, .little);
    try out.appendSlice(allocator, &hdr);

    for (dir_entries.items) |de| {
        var eb: [PAGE_DIR_ENTRY_SIZE]u8 = undefined;
        std.mem.writeInt(u64, eb[0..8], de.page_off, .little);
        std.mem.writeInt(u32, eb[8..12], de.page_len, .little);
        std.mem.writeInt(u32, eb[12..16], de.key_off, .little);
        std.mem.writeInt(u32, eb[16..20], de.key_len, .little);
        try out.appendSlice(allocator, &eb);
    }
    try out.appendSlice(allocator, fence_keys.items);
    if (pad_len > 0) try out.appendNTimes(allocator, 0, pad_len);
    try out.appendSlice(allocator, pages_buf.items);
    return records.len;
}

const SlottedView = struct {
    data: []const u8,
    page_count: u32,
    total_records: u32,
    dir_bytes: []const u8,
    fence_bytes: []const u8,
    pages_bytes: []const u8,

    fn init(data: []const u8) ?SlottedView {
        if (data.len < 32) return null;
        const page_count = std.mem.readInt(u32, data[0..4], .little);
        const total_records = std.mem.readInt(u32, data[4..8], .little);
        const dir_len = std.mem.readInt(u64, data[8..16], .little);
        const fence_len = std.mem.readInt(u64, data[16..24], .little);
        const pages_off = std.mem.readInt(u64, data[24..32], .little);
        if (dir_len != @as(u64, page_count) * PAGE_DIR_ENTRY_SIZE) return null;
        if (32 + dir_len + fence_len > pages_off or pages_off > data.len) return null;
        return .{
            .data = data,
            .page_count = page_count,
            .total_records = total_records,
            .dir_bytes = data[32..@intCast(32 + dir_len)],
            .fence_bytes = data[@intCast(32 + dir_len)..@intCast(32 + dir_len + fence_len)],
            .pages_bytes = data[@intCast(pages_off)..],
        };
    }

    fn dirEntry(self: SlottedView, idx: usize) PageDirEntry {
        const off = idx * PAGE_DIR_ENTRY_SIZE;
        return .{
            .page_off = std.mem.readInt(u64, self.dir_bytes[off..][0..8], .little),
            .page_len = std.mem.readInt(u32, self.dir_bytes[off + 8 ..][0..4], .little),
            .key_off = std.mem.readInt(u32, self.dir_bytes[off + 12 ..][0..4], .little),
            .key_len = std.mem.readInt(u32, self.dir_bytes[off + 16 ..][0..4], .little),
        };
    }

    fn fenceKey(self: SlottedView, idx: usize) ?[]const u8 {
        const de = self.dirEntry(idx);
        const end = @as(usize, de.key_off) + @as(usize, de.key_len);
        if (end > self.fence_bytes.len) return null;
        return self.fence_bytes[de.key_off..end];
    }

    fn verifyAndGetPage(self: SlottedView, idx: usize) ?[]const u8 {
        if (idx >= self.page_count) return null;
        const de = self.dirEntry(idx);
        const off: usize = @intCast(de.page_off);
        const len: usize = @intCast(de.page_len);
        if (len < PAGE_HDR_SIZE or off + len > self.pages_bytes.len) return null;
        const page = self.pages_bytes[off .. off + len];
        if (!std.mem.eql(u8, page[0..4], &PAGE_MAGIC)) return null;
        const expected_crc = std.mem.readInt(u32, page[4..8], .little);
        if (codec.crc32c(page[8..len]) != expected_crc) return null;
        return page;
    }

    fn pageRecordCount(page: []const u8) u32 {
        return std.mem.readInt(u32, page[12..16], .little);
    }

    fn pageRecord(page: []const u8, rec_idx: usize) ?struct { key: []const u8, val: []const u8 } {
        const cnt = pageRecordCount(page);
        if (rec_idx >= cnt) return null;
        const slots_base = PAGE_HDR_SIZE;
        const s0 = std.mem.readInt(u32, page[slots_base + rec_idx * 4 ..][0..4], .little);
        const s1 = std.mem.readInt(u32, page[slots_base + (rec_idx + 1) * 4 ..][0..4], .little);
        if (s0 + 4 > s1 or s1 > page.len) return null;
        const klen = std.mem.readInt(u32, page[s0..][0..4], .little);
        if (s0 + 4 + klen > s1) return null;
        return .{
            .key = page[s0 + 4 .. s0 + 4 + klen],
            .val = page[s0 + 4 + klen .. s1],
        };
    }

    fn findPageForKey(self: SlottedView, target_key: []const u8) ?usize {
        if (self.page_count == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.page_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const fk = self.fenceKey(mid) orelse return null;
            if (std.mem.order(u8, fk, target_key) != .gt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        return lo - 1;
    }

    fn get(self: SlottedView, target_key: []const u8) ?[]const u8 {
        const pidx = self.findPageForKey(target_key) orelse return null;
        const page = self.verifyAndGetPage(pidx) orelse return null;
        const cnt = pageRecordCount(page);
        var lo: usize = 0;
        var hi: usize = cnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = pageRecord(page, mid) orelse return null;
            switch (std.mem.order(u8, rec.key, target_key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return rec.val,
            }
        }
        return null;
    }
};

pub const MetaScopesData = struct {
    scopes_blob: []u8 = &.{},
    retained_versions: std.ArrayList(Version) = .empty,
    synced_version: Version = Version.ROOT,
    git_head: ?[]u8 = null,

    pub fn deinit(self: *MetaScopesData, allocator: Allocator) void {
        if (self.scopes_blob.len > 0) allocator.free(self.scopes_blob);
        for (self.retained_versions.items) |*v| v.deinit(allocator);
        self.retained_versions.deinit(allocator);
        self.synced_version.deinit(allocator);
        if (self.git_head) |gh| allocator.free(gh);
    }
};

pub const MetaScopesInput = struct {
    scopes_blob: []const u8 = &.{},
    retained_versions: []const Version = &.{},
    synced_version: Version = Version.ROOT,
    git_head: ?[]const u8 = null,
};

pub const SnapshotReader = struct {
    allocator: Allocator,
    mapped: *mmap.MappedFile,
    header: Header,
    ref_count: std.atomic.Value(usize),
    actors_sec: []const u8 = &.{},
    dag_sec: []const u8 = &.{},
    inodes_sec: []const u8 = &.{},
    dir_name_sec: []const u8 = &.{},
    dir_children_sec: []const u8 = &.{},
    text_nodes_sec: []const u8 = &.{},
    insertions_sec: []const u8 = &.{},
    meta_scopes_sec: []const u8 = &.{},

    pub fn open(allocator: Allocator, io: Io, dir: Io.Dir, rel_path: []const u8) !*SnapshotReader {
        const mf = try mmap.MappedFile.open(allocator, io, dir, rel_path);
        errdefer mf.release(allocator);
        const data = mf.slice();
        const hdr = try Header.decodeAndVerify(data);
        const r = try allocator.create(SnapshotReader);
        r.* = .{
            .allocator = allocator,
            .mapped = mf,
            .header = hdr,
            .ref_count = std.atomic.Value(usize).init(1),
        };
        const sec_off: usize = @intCast(hdr.section_table_off);
        for (0..hdr.section_count) |i| {
            const desc_ptr: *const [SECTION_DESC_SIZE]u8 = @ptrCast(data[sec_off + i * SECTION_DESC_SIZE ..][0..SECTION_DESC_SIZE].ptr);
            const desc = SectionDesc.decode(desc_ptr);
            if (desc.offset + desc.len > data.len - TRAILER_SIZE) {
                allocator.destroy(r);
                return error.CorruptSnapshot;
            }
            const sl = data[@intCast(desc.offset)..@intCast(desc.offset + desc.len)];
            switch (desc.kind) {
                SEC_ACTORS => r.actors_sec = sl,
                SEC_DAG => r.dag_sec = sl,
                SEC_INODES => r.inodes_sec = sl,
                SEC_DIR_NAME_IDX => r.dir_name_sec = sl,
                SEC_DIR_CHILDREN => r.dir_children_sec = sl,
                SEC_TEXT_NODES => r.text_nodes_sec = sl,
                SEC_INSERTIONS => r.insertions_sec = sl,
                SEC_META_SCOPES => r.meta_scopes_sec = sl,
                else => {},
            }
        }
        return r;
    }

    pub fn retain(self: *SnapshotReader) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *SnapshotReader) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            const alloc = self.allocator;
            self.mapped.release(alloc);
            alloc.destroy(self);
        }
    }

    pub fn hibernate(self: *SnapshotReader) void {
        self.mapped.hibernate();
    }

    pub fn isDelta(self: *const SnapshotReader) bool {
        return (self.header.flags & FLAG_DELTA) != 0;
    }

    pub fn verifyFull(self: *const SnapshotReader) SnapshotError!void {
        const data = self.mapped.slice();
        if (data.len < HEADER_SIZE + TRAILER_SIZE) return error.CorruptSnapshot;
        const body = data[0 .. data.len - TRAILER_SIZE];
        const expected = data[data.len - TRAILER_SIZE ..];
        const actual = crypto.hashBytes(body);
        if (!std.mem.eql(u8, &actual, expected)) return error.CorruptSnapshot;
    }

    pub fn actorCount(self: *const SnapshotReader) u32 {
        if (self.actors_sec.len < 4) return 0;
        return std.mem.readInt(u32, self.actors_sec[0..4], .little);
    }

    pub fn actorByIdx(self: *const SnapshotReader, idx: u32) ?id.ActorId {
        const cnt = self.actorCount();
        if (idx >= cnt) return null;
        const off = 8 + @as(usize, idx) * 16;
        if (off + 16 > self.actors_sec.len) return null;
        return std.mem.readInt(u128, self.actors_sec[off..][0..16], .little);
    }

    pub fn actorIdx(self: *const SnapshotReader, actor: id.ActorId) ?u32 {
        const cnt = self.actorCount();
        if (cnt == 0) return null;
        const table_off = 8 + @as(usize, cnt) * 16;
        const entry_sz: usize = 20;
        if (table_off + @as(usize, cnt) * entry_sz > self.actors_sec.len) return null;
        var lo: usize = 0;
        var hi: usize = cnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const pos = table_off + mid * entry_sz;
            const a = std.mem.readInt(u128, self.actors_sec[pos..][0..16], .little);
            if (a < actor) {
                lo = mid + 1;
            } else if (a > actor) {
                hi = mid;
            } else {
                return std.mem.readInt(u32, self.actors_sec[pos + 16 ..][0..4], .little);
            }
        }
        return null;
    }

    const DagView = struct {
        heads_cnt: u32,
        horizon_cnt: u32,
        batch_cnt: u32,
        run_cnt: u32,
        parents_cnt: u32,
        heads_off: usize,
        horizon_off: usize,
        batches_off: usize,
        runs_off: usize,
        parents_off: usize,
    };

    fn dagView(self: *const SnapshotReader) ?DagView {
        if (self.dag_sec.len < 24) return null;
        const heads_cnt = std.mem.readInt(u32, self.dag_sec[0..4], .little);
        const horizon_cnt = std.mem.readInt(u32, self.dag_sec[4..8], .little);
        const batch_cnt = std.mem.readInt(u32, self.dag_sec[8..12], .little);
        const run_cnt = std.mem.readInt(u32, self.dag_sec[12..16], .little);
        const parents_cnt = std.mem.readInt(u32, self.dag_sec[16..20], .little);
        const heads_off: usize = 24;
        const horizon_off = heads_off + @as(usize, heads_cnt) * 16;
        const batches_off = horizon_off + @as(usize, horizon_cnt) * 16;
        const runs_off = batches_off + @as(usize, batch_cnt) * 48;
        const parents_off = runs_off + @as(usize, run_cnt) * 24;
        const end_off = parents_off + @as(usize, parents_cnt) * 16;
        if (end_off > self.dag_sec.len) return null;
        return .{
            .heads_cnt = heads_cnt,
            .horizon_cnt = horizon_cnt,
            .batch_cnt = batch_cnt,
            .run_cnt = run_cnt,
            .parents_cnt = parents_cnt,
            .heads_off = heads_off,
            .horizon_off = horizon_off,
            .batches_off = batches_off,
            .runs_off = runs_off,
            .parents_off = parents_off,
        };
    }

    fn readDiskOpId(sec: []const u8, off: usize) DiskOpId {
        return .{
            .ts = std.mem.readInt(u64, sec[off..][0..8], .little),
            .actor_idx = std.mem.readInt(u32, sec[off + 8 ..][0..4], .little),
            .pad = 0,
        };
    }

    fn readBatchEntry(sec: []const u8, off: usize) DiskBatchEntry {
        return .{
            .end_ts = std.mem.readInt(u64, sec[off..][0..8], .little),
            .start_delta = std.mem.readInt(u32, sec[off + 8 ..][0..4], .little),
            .actor_idx = std.mem.readInt(u32, sec[off + 12 ..][0..4], .little),
            .batch_idx = std.mem.readInt(u32, sec[off + 16 ..][0..4], .little),
            .log_seg = std.mem.readInt(u32, sec[off + 20 ..][0..4], .little),
            .log_len = std.mem.readInt(u32, sec[off + 24 ..][0..4], .little),
            .parents_off = std.mem.readInt(u32, sec[off + 28 ..][0..4], .little),
            .log_off_and_flags = std.mem.readInt(u64, sec[off + 32 ..][0..8], .little),
            .wall_ms_and_pcount = std.mem.readInt(u64, sec[off + 40 ..][0..8], .little),
        };
    }

    fn readActorRun(sec: []const u8, off: usize) DiskActorRun {
        return .{
            .actor_idx = std.mem.readInt(u32, sec[off..][0..4], .little),
            .batch_idx = std.mem.readInt(u32, sec[off + 4 ..][0..4], .little),
            .start_ts = std.mem.readInt(u64, sec[off + 8 ..][0..8], .little),
            .end_ts = std.mem.readInt(u64, sec[off + 16 ..][0..8], .little),
        };
    }

    pub fn dagBatchCount(self: *const SnapshotReader) usize {
        const dv = self.dagView() orelse return 0;
        return dv.batch_cnt;
    }

    fn findBatchEntry(self: *const SnapshotReader, bid: id.BatchId) ?struct { dv: DagView, entry: DiskBatchEntry } {
        const dv = self.dagView() orelse return null;
        const aidx = self.actorIdx(bid.actor) orelse return null;
        var lo: usize = 0;
        var hi: usize = dv.batch_cnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = readBatchEntry(self.dag_sec, dv.batches_off + mid * 48);
            if (e.end_ts < bid.ts or (e.end_ts == bid.ts and e.actor_idx < aidx)) {
                lo = mid + 1;
            } else if (e.end_ts > bid.ts or e.actor_idx > aidx) {
                hi = mid;
            } else {
                return .{ .dv = dv, .entry = e };
            }
        }
        return null;
    }

    pub fn dagGetBatchMeta(self: *const SnapshotReader, bid: id.BatchId) ?dag_mod.BatchMeta {
        const found = self.findBatchEntry(bid) orelse return null;
        const e = found.entry;
        return .{
            .actor = bid.actor,
            .start = e.startTs(),
            .end = e.end_ts,
            .wall_ms = e.wallMs(),
            .batch_idx = e.batch_idx,
            .log_seg = e.log_seg,
            .log_off = e.logOff(),
            .log_len = e.log_len,
            .flags = e.flags(),
        };
    }

    pub fn dagAppendParents(self: *const SnapshotReader, allocator: Allocator, bid: id.BatchId, out: *std.ArrayList(id.BatchId)) Allocator.Error!bool {
        const found = self.findBatchEntry(bid) orelse return false;
        const dv = found.dv;
        const e = found.entry;
        const pcnt = e.parentsCount();
        for (0..pcnt) |i| {
            const pidx = e.parents_off + i;
            if (pidx >= dv.parents_cnt) break;
            const dop = readDiskOpId(self.dag_sec, dv.parents_off + pidx * 16);
            const actor = self.actorByIdx(dop.actor_idx) orelse continue;
            try out.append(allocator, id.OpId.init(dop.ts, actor));
        }
        return true;
    }

    pub fn dagParentsEqual(self: *const SnapshotReader, bid: id.BatchId, parents: *const Version) bool {
        const found = self.findBatchEntry(bid) orelse return false;
        const dv = found.dv;
        const e = found.entry;
        const pcnt = e.parentsCount();
        if (pcnt != parents.slice().len) return false;
        for (0..pcnt) |i| {
            const pidx = e.parents_off + i;
            if (pidx >= dv.parents_cnt) return false;
            const dop = readDiskOpId(self.dag_sec, dv.parents_off + pidx * 16);
            const actor = self.actorByIdx(dop.actor_idx) orelse return false;
            if (!parents.contains(id.OpId.init(dop.ts, actor))) return false;
        }
        return true;
    }

    pub fn dagFindActorRun(self: *const SnapshotReader, op: id.OpId) ?dag_mod.ActorRun {
        const dv = self.dagView() orelse return null;
        const aidx = self.actorIdx(op.actor) orelse return null;
        var lo: usize = 0;
        var hi: usize = dv.run_cnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = readActorRun(self.dag_sec, dv.runs_off + mid * 24);
            if (r.actor_idx < aidx or (r.actor_idx == aidx and r.end_ts < op.ts)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= dv.run_cnt) return null;
        const r = readActorRun(self.dag_sec, dv.runs_off + lo * 24);
        if (r.actor_idx == aidx and op.ts >= r.start_ts and op.ts <= r.end_ts) {
            return .{
                .start = r.start_ts,
                .end = r.end_ts,
                .batch_idx = r.batch_idx,
            };
        }
        return null;
    }

    pub fn dagActorRangeOverlaps(self: *const SnapshotReader, actor: id.ActorId, start: id.Lamport, end: id.Lamport) bool {
        const dv = self.dagView() orelse return false;
        const aidx = self.actorIdx(actor) orelse return false;
        var lo: usize = 0;
        var hi: usize = dv.run_cnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = readActorRun(self.dag_sec, dv.runs_off + mid * 24);
            if (r.actor_idx < aidx or (r.actor_idx == aidx and r.end_ts < start)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= dv.run_cnt) return false;
        const r = readActorRun(self.dag_sec, dv.runs_off + lo * 24);
        return r.actor_idx == aidx and r.start_ts <= end;
    }

    pub fn dagAppendAllBatchIds(self: *const SnapshotReader, allocator: Allocator, out: *std.ArrayList(id.BatchId)) Allocator.Error!void {
        const dv = self.dagView() orelse return;
        try out.ensureUnusedCapacity(allocator, dv.batch_cnt);
        for (0..dv.batch_cnt) |i| {
            const e = readBatchEntry(self.dag_sec, dv.batches_off + i * 48);
            const actor = self.actorByIdx(e.actor_idx) orelse continue;
            out.appendAssumeCapacity(id.OpId.init(e.end_ts, actor));
        }
    }

    pub fn dagHeads(self: *const SnapshotReader, allocator: Allocator) Allocator.Error!Version {
        var v = Version{};
        errdefer v.deinit(allocator);
        const dv = self.dagView() orelse return v;
        for (0..dv.heads_cnt) |i| {
            const dop = readDiskOpId(self.dag_sec, dv.heads_off + i * 16);
            const actor = self.actorByIdx(dop.actor_idx) orelse continue;
            try v.insert(allocator, id.OpId.init(dop.ts, actor));
        }
        return v;
    }

    pub fn dagHorizon(self: *const SnapshotReader, allocator: Allocator) Allocator.Error!Version {
        var v = Version{};
        errdefer v.deinit(allocator);
        const dv = self.dagView() orelse return v;
        for (0..dv.horizon_cnt) |i| {
            const dop = readDiskOpId(self.dag_sec, dv.horizon_off + i * 16);
            const actor = self.actorByIdx(dop.actor_idx) orelse continue;
            try v.insert(allocator, id.OpId.init(dop.ts, actor));
        }
        return v;
    }

    pub fn hasInode(self: *const SnapshotReader, iid: id.InodeId) bool {
        const sv = SlottedView.init(self.inodes_sec) orelse return false;
        const key = encodeInodeKey(iid);
        return sv.get(&key) != null;
    }

    pub fn loadInode(
        self: *const SnapshotReader,
        allocator: Allocator,
        iid: id.InodeId,
        node_source: ?text_mod.NodeSource,
    ) Allocator.Error!?*tree_mod.Inode {
        const sv = SlottedView.init(self.inodes_sec) orelse return null;
        const key = encodeInodeKey(iid);
        const val = sv.get(&key) orelse return null;
        return self.decodeInodeRecord(allocator, iid, val, node_source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn readActorOp(self: *const SnapshotReader, r: *codec.Reader) codec.DecodeError!id.OpId {
        const ts = try r.readVarint();
        const aidx: u32 = @intCast(try r.readVarint());
        const actor = self.actorByIdx(aidx) orelse return error.InvalidData;
        return id.OpId.init(ts, actor);
    }

    fn readDiskInodeId(self: *const SnapshotReader, r: *codec.Reader) codec.DecodeError!id.InodeId {
        const op = try self.readActorOp(r);
        const part: u32 = @intCast(try r.readVarint());
        return id.InodeId.init(op, part);
    }

    fn decodeInodeRecord(
        self: *const SnapshotReader,
        allocator: Allocator,
        iid: id.InodeId,
        val: []const u8,
        node_source: ?text_mod.NodeSource,
    ) (codec.DecodeError || Allocator.Error)!*tree_mod.Inode {
        var r = codec.Reader.init(val);
        const kind_tag = try r.readByte();
        const inode = try allocator.create(tree_mod.Inode);
        inode.* = .{
            .inode_id = iid,
            .kind = switch (kind_tag) {
                0 => .dir,
                1 => .{ .file = .{} },
                2 => .{ .symlink = .{} },
                else => {
                    allocator.destroy(inode);
                    return error.InvalidData;
                },
            },
        };
        errdefer {
            inode.deinit(allocator);
            allocator.destroy(inode);
        }

        const pl_cnt: usize = @intCast(try r.readVarint());
        for (0..pl_cnt) |_| {
            const op = try self.readActorOp(&r);
            const parent = try self.readDiskInodeId(&r);
            const name = try r.readBytesAlloc(allocator);
            errdefer allocator.free(name);
            try inode.placement.set(allocator, op, .{ .parent = parent, .name = name });
        }

        const al_cnt: usize = @intCast(try r.readVarint());
        for (0..al_cnt) |_| {
            const op = try self.readActorOp(&r);
            const alive = try r.readBool();
            try inode.alive.set(allocator, op, alive);
        }

        switch (inode.kind) {
            .dir => {},
            .file => |*f| {
                const raw_root = try r.readU32();
                const vis = try r.readU64();
                const vis_nl = try r.readU64();
                const tot = try r.readU64();
                const max_ts = try r.readU64();
                const sflags = try r.readByte();
                const item_cnt: usize = @intCast(try r.readU32());
                if (text_mod.DiskNodeRef.fromRaw(raw_root)) |ref| {
                    f.text = text_mod.Text.fromDiskRoot(ref, .{
                        .visible = vis,
                        .visible_newlines = vis_nl,
                        .total = tot,
                        .max_ts = max_ts,
                        .ends_with_nl = (sflags & 1) != 0,
                        .unknown_newlines = (sflags & 2) != 0,
                    }, item_cnt, node_source);
                } else {
                    f.text.node_source = node_source;
                }

                const ck_cnt: usize = @intCast(try r.readVarint());
                for (0..ck_cnt) |_| {
                    const op = try self.readActorOp(&r);
                    const ctag = try r.readByte();
                    const ck: tree_mod.ContentKind = switch (ctag) {
                        0 => .text,
                        1 => .{ .binary = .{ .oid = (try r.readFixed(32)).*, .len = try r.readVarint() } },
                        2 => blk: {
                            const olen = try r.readByte();
                            const goid = switch (olen) {
                                20 => git_dirs.GitOid.fromSlice(try r.readFixed(20)) catch return error.InvalidData,
                                32 => git_dirs.GitOid.fromSlice(try r.readFixed(32)) catch return error.InvalidData,
                                else => return error.InvalidData,
                            };
                            break :blk .{ .git_binary = .{ .oid = goid, .len = try r.readVarint() } };
                        },
                        3 => blk: {
                            const olen = try r.readByte();
                            const goid = switch (olen) {
                                20 => git_dirs.GitOid.fromSlice(try r.readFixed(20)) catch return error.InvalidData,
                                32 => git_dirs.GitOid.fromSlice(try r.readFixed(32)) catch return error.InvalidData,
                                else => return error.InvalidData,
                            };
                            break :blk .{ .git_lazy = .{ .oid = goid, .len = try r.readVarint() } };
                        },
                        else => return error.InvalidData,
                    };
                    try f.content.set(allocator, op, ck);
                }

                const m_cnt: usize = @intCast(try r.readVarint());
                for (0..m_cnt) |_| {
                    const op = try self.readActorOp(&r);
                    const m = std.enums.fromInt(tree_mod.FileMode, try r.readByte()) orelse return error.InvalidData;
                    try f.mode.set(allocator, op, m);
                }

                const le_cnt: usize = @intCast(try r.readVarint());
                for (0..le_cnt) |_| {
                    const op = try self.readActorOp(&r);
                    const le = std.enums.fromInt(tree_mod.LineEnding, try r.readByte()) orelse return error.InvalidData;
                    try f.line_ending.set(allocator, op, le);
                }
            },
            .symlink => |*sym| {
                const s_cnt: usize = @intCast(try r.readVarint());
                for (0..s_cnt) |_| {
                    const op = try self.readActorOp(&r);
                    const target = try r.readBytesAlloc(allocator);
                    errdefer allocator.free(target);
                    try sym.set(allocator, op, target);
                }
            },
        }
        return inode;
    }

    pub fn lookupDirName(self: *const SnapshotReader, parent: id.InodeId, name: []const u8) ?tree_mod.DirNameLookup {
        const sv = SlottedView.init(self.dir_name_sec) orelse return null;
        var stack_key: [512]u8 = undefined;
        const total_len = INODE_KEY_LEN + 8 + name.len;
        var heap_key: ?[]u8 = null;
        defer if (heap_key) |hk| self.allocator.free(hk);
        const key: []u8 = if (total_len <= stack_key.len) stack_key[0..total_len] else blk: {
            heap_key = self.allocator.alloc(u8, total_len) catch return null;
            break :blk heap_key.?;
        };
        const pk = encodeInodeKey(parent);
        @memcpy(key[0..INODE_KEY_LEN], &pk);
        std.mem.writeInt(u64, key[INODE_KEY_LEN .. INODE_KEY_LEN + 8], hashName(name), .big);
        @memcpy(key[INODE_KEY_LEN + 8 ..], name);

        const val = sv.get(key) orelse return null;
        if (val.len < INODE_KEY_LEN + 2) return null;
        return .{
            .child_id = decodeInodeKey(@ptrCast(val[0..INODE_KEY_LEN].ptr)),
            .kind = val[INODE_KEY_LEN],
            .flags = val[INODE_KEY_LEN + 1],
        };
    }

    pub fn collectDirChildren(self: *const SnapshotReader, allocator: Allocator, dir: id.InodeId, out: *std.ArrayList(id.InodeId)) Allocator.Error!void {
        const sv = SlottedView.init(self.dir_children_sec) orelse return;
        if (sv.page_count == 0) return;
        const min_key = encodeDirChildKey(dir, id.InodeId.ROOT);
        const dir_prefix = min_key[0..INODE_KEY_LEN];

        var start_page: usize = 0;
        if (sv.findPageForKey(&min_key)) |p| {
            start_page = p;
        }
        var pidx = start_page;
        while (pidx < sv.page_count) : (pidx += 1) {
            const page = sv.verifyAndGetPage(pidx) orelse return;
            const cnt = SlottedView.pageRecordCount(page);
            var past_prefix = false;
            for (0..cnt) |j| {
                const rec = SlottedView.pageRecord(page, j) orelse break;
                if (rec.key.len < INODE_KEY_LEN * 2) continue;
                const ord = std.mem.order(u8, rec.key[0..INODE_KEY_LEN], dir_prefix);
                if (ord == .lt) continue;
                if (ord == .gt) {
                    past_prefix = true;
                    break;
                }
                const cid = decodeInodeKey(@ptrCast(rec.key[INODE_KEY_LEN .. INODE_KEY_LEN * 2].ptr));
                try out.append(allocator, cid);
            }
            if (past_prefix) break;
        }
    }

    fn textNodePayload(self: *const SnapshotReader, node_id: u31) ?[]const u8 {
        if (self.text_nodes_sec.len < 8) return null;
        const node_count = std.mem.readInt(u32, self.text_nodes_sec[0..4], .little);
        if (node_id >= node_count) return null;
        const table_off: usize = 8;
        const data_base = table_off + @as(usize, node_count) * 16;
        if (data_base > self.text_nodes_sec.len) return null;
        const desc_off = table_off + @as(usize, node_id) * 16;
        const off = std.mem.readInt(u64, self.text_nodes_sec[desc_off..][0..8], .little);
        const len = std.mem.readInt(u32, self.text_nodes_sec[desc_off + 8 ..][0..4], .little);
        const crc = std.mem.readInt(u32, self.text_nodes_sec[desc_off + 12 ..][0..4], .little);
        const start = data_base + @as(usize, @intCast(off));
        const end = start + @as(usize, len);
        if (end > self.text_nodes_sec.len) return null;
        const payload = self.text_nodes_sec[start..end];
        if (codec.crc32c(payload) != crc) return null;
        return payload;
    }

    pub fn loadTextNode(self: *const SnapshotReader, allocator: Allocator, ref: text_mod.DiskNodeRef) Allocator.Error!?*text_mod.Node {
        const payload = self.textNodePayload(ref.id) orelse return null;
        return self.decodeTextNode(allocator, payload, ref) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn decodeTextNode(self: *const SnapshotReader, allocator: Allocator, payload: []const u8, ref: text_mod.DiskNodeRef) (codec.DecodeError || Allocator.Error)!*text_mod.Node {
        var r = codec.Reader.init(payload);
        const kind_b = try r.readByte();
        const len_b = try r.readByte();
        if (kind_b == 0) {
            if (len_b > text_mod.LEAF_CAP) return error.InvalidData;
            var frags: [text_mod.LEAF_CAP]text_mod.Fragment = undefined;
            var built: usize = 0;
            errdefer {
                for (frags[0..built]) |*f| f.deinit(allocator);
            }
            for (0..len_b) |_| {
                const ins = try self.readActorOp(&r);
                const part: u32 = @intCast(try r.readVarint());
                const newlines: u32 = @intCast(try r.readVarint());
                const off = try r.readVarint();
                const flen = try r.readVarint();
                const fflags = try r.readByte();
                const del_cnt = try r.readByte();
                var f = text_mod.Fragment{
                    .ins = ins,
                    .part = part,
                    .newlines = newlines,
                    .off = off,
                    .len = flen,
                    .del_count = del_cnt,
                    .ends_with_nl = (fflags & 1) != 0,
                    .newlines_known = (fflags & 2) != 0,
                };
                if (del_cnt == 1) {
                    f.del_inline = try self.readActorOp(&r);
                } else if (del_cnt > 1) {
                    const real_cnt: usize = @intCast(try r.readVarint());
                    const ov = try allocator.alloc(id.OpId, real_cnt);
                    errdefer allocator.free(ov);
                    for (ov) |*d| d.* = try self.readActorOp(&r);
                    f.del_overflow = ov;
                    f.del_count = @intCast(@min(real_cnt, 255));
                }
                frags[built] = f;
                built += 1;
            }
            const node = try text_mod.Node.createLeaf(allocator, frags[0..built]);
            node.persisted = ref;
            return node;
        } else if (kind_b == 1) {
            if (len_b > text_mod.BRANCH_CAP) return error.InvalidData;
            var slots: [text_mod.BRANCH_CAP]text_mod.ChildSlot = undefined;
            var sums: [text_mod.BRANCH_CAP]text_mod.FragSummary = undefined;
            var cnts: [text_mod.BRANCH_CAP]usize = undefined;
            for (0..len_b) |i| {
                const raw_child = try r.readU32();
                const cref = text_mod.DiskNodeRef.fromRaw(raw_child) orelse return error.InvalidData;
                slots[i] = .{ .disk = cref };
                const vis = try r.readU64();
                const vis_nl = try r.readU64();
                const tot = try r.readU64();
                const max_ts = try r.readU64();
                const sflags = try r.readByte();
                sums[i] = .{
                    .visible = vis,
                    .visible_newlines = vis_nl,
                    .total = tot,
                    .max_ts = max_ts,
                    .ends_with_nl = (sflags & 1) != 0,
                    .unknown_newlines = (sflags & 2) != 0,
                };
                cnts[i] = @intCast(try r.readU32());
            }
            const node = try text_mod.Node.createBranchFromSlots(allocator, slots[0..len_b], sums[0..len_b], cnts[0..len_b]);
            node.persisted = ref;
            return node;
        }
        return error.InvalidData;
    }

    pub fn lookupInsertion(self: *const SnapshotReader, key: id.InsertionKey) ?history_mod.InsertionLookup {
        if (self.insertions_sec.len < 24) return null;
        const entry_cnt = std.mem.readInt(u32, self.insertions_sec[0..4], .little);
        const blob_cnt = std.mem.readInt(u32, self.insertions_sec[4..8], .little);
        const git_cnt = std.mem.readInt(u32, self.insertions_sec[8..12], .little);
        const arena_len = std.mem.readInt(u64, self.insertions_sec[16..24], .little);
        const entries_off: usize = 24;
        const blobs_off = entries_off + @as(usize, entry_cnt) * 32;
        const gits_off = blobs_off + @as(usize, blob_cnt) * 32;
        const arena_off = gits_off + @as(usize, git_cnt) * 36;
        if (arena_off + @as(usize, @intCast(arena_len)) > self.insertions_sec.len) return null;

        const aidx = self.actorIdx(key.op.actor) orelse return null;
        var lo: usize = 0;
        var hi: usize = entry_cnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const pos = entries_off + mid * 32;
            const ts = std.mem.readInt(u64, self.insertions_sec[pos..][0..8], .little);
            const ai = std.mem.readInt(u32, self.insertions_sec[pos + 8 ..][0..4], .little);
            const part = std.mem.readInt(u32, self.insertions_sec[pos + 12 ..][0..4], .little);
            if (ts < key.op.ts or (ts == key.op.ts and (ai < aidx or (ai == aidx and part < key.part)))) {
                lo = mid + 1;
            } else if (ts > key.op.ts or ai > aidx or part > key.part) {
                hi = mid;
            } else {
                const kind = self.insertions_sec[pos + 16];
                const len = std.mem.readInt(u32, self.insertions_sec[pos + 20 ..][0..4], .little);
                const pref = std.mem.readInt(u64, self.insertions_sec[pos + 24 ..][0..8], .little);
                switch (kind) {
                    INS_KIND_INLINE => {
                        const s = arena_off + @as(usize, @intCast(pref));
                        const e = s + @as(usize, len);
                        if (e > self.insertions_sec.len) return null;
                        return .{ .inline_bytes = self.insertions_sec[s..e] };
                    },
                    INS_KIND_BLOB => {
                        const bidx: usize = @intCast(pref);
                        if (bidx >= blob_cnt) return null;
                        const boff = blobs_off + bidx * 32;
                        return .{ .blob_oid = self.insertions_sec[boff..][0..32].* };
                    },
                    INS_KIND_GIT => {
                        const gidx: usize = @intCast(pref);
                        if (gidx >= git_cnt) return null;
                        const goff = gits_off + gidx * 36;
                        const glen = self.insertions_sec[goff];
                        var goid = git_dirs.GitOid{ .len = glen, .bytes = @splat(0) };
                        @memcpy(&goid.bytes, self.insertions_sec[goff + 1 .. goff + 33]);
                        return .{ .git_oid = goid };
                    },
                    else => return null,
                }
            }
        }
        return null;
    }

    pub fn loadMetaScopes(
        self: *const SnapshotReader,
        allocator: Allocator,
        history: ?*history_mod.History,
    ) !MetaScopesData {
        var out = MetaScopesData{};
        errdefer out.deinit(allocator);
        if (self.meta_scopes_sec.len == 0) return out;
        var r = codec.Reader.init(self.meta_scopes_sec);
        const meta_cnt: usize = @intCast(try r.readVarint());
        for (0..meta_cnt) |_| {
            const key = try r.readBytes();
            const e_cnt: usize = @intCast(try r.readVarint());
            for (0..e_cnt) |_| {
                const op = try self.readActorOp(&r);
                const val = try r.readOptBytes();
                if (history) |h| {
                    if (h.meta.getPtr(key)) |lww| {
                        const vc: ?[]u8 = if (val) |v| try h.allocator.dupe(u8, v) else null;
                        errdefer if (vc) |c| h.allocator.free(c);
                        try lww.set(h.allocator, op, vc);
                    } else {
                        const kc = try h.allocator.dupe(u8, key);
                        errdefer h.allocator.free(kc);
                        var lww = tree_mod.Lww(?[]u8){};
                        errdefer lww.deinit(h.allocator);
                        const vc: ?[]u8 = if (val) |v| try h.allocator.dupe(u8, v) else null;
                        errdefer if (vc) |c| h.allocator.free(c);
                        try lww.set(h.allocator, op, vc);
                        try h.meta.put(h.allocator, kc, lww);
                    }
                }
            }
        }
        out.scopes_blob = try r.readBytesAlloc(allocator);
        const ret_cnt: usize = @intCast(try r.readVarint());
        for (0..ret_cnt) |_| {
            var v = try Version.decode(allocator, &r);
            errdefer v.deinit(allocator);
            try out.retained_versions.append(allocator, v);
        }
        out.synced_version = try Version.decode(allocator, &r);
        out.git_head = try r.readOptBytesAlloc(allocator);
        return out;
    }

    pub fn collectReferencedBlobOids(
        self: *const SnapshotReader,
        allocator: Allocator,
        out: *std.AutoHashMapUnmanaged(id.Oid, void),
    ) Allocator.Error!void {
        if (self.insertions_sec.len >= 24) {
            const entry_cnt = std.mem.readInt(u32, self.insertions_sec[0..4], .little);
            const blob_cnt = std.mem.readInt(u32, self.insertions_sec[4..8], .little);
            const blobs_off: usize = 24 + @as(usize, entry_cnt) * 32;
            if (blobs_off + @as(usize, blob_cnt) * 32 <= self.insertions_sec.len) {
                for (0..blob_cnt) |i| {
                    const oid: id.Oid = self.insertions_sec[blobs_off + i * 32 ..][0..32].*;
                    try out.put(allocator, oid, {});
                }
            }
        }
        if (SlottedView.init(self.inodes_sec)) |sv| {
            for (0..sv.page_count) |pidx| {
                const page = sv.verifyAndGetPage(pidx) orelse continue;
                const cnt = SlottedView.pageRecordCount(page);
                for (0..cnt) |j| {
                    const rec = SlottedView.pageRecord(page, j) orelse continue;
                    if (rec.key.len != INODE_KEY_LEN) continue;
                    const iid = decodeInodeKey(@ptrCast(rec.key[0..INODE_KEY_LEN].ptr));
                    const inode = (self.decodeInodeRecord(allocator, iid, rec.val, null) catch continue);
                    defer {
                        inode.deinit(allocator);
                        allocator.destroy(inode);
                    }
                    if (inode.fileConstPtr()) |f| {
                        for (f.content.entries.items) |ce| {
                            if (ce.value == .binary) {
                                try out.put(allocator, ce.value.binary.oid, {});
                            }
                        }
                    }
                }
            }
        }
    }
};

pub const SnapshotStack = struct {
    allocator: Allocator,
    base: ?*SnapshotReader,
    delta: ?*SnapshotReader,
    ref_count: std.atomic.Value(usize),

    pub fn create(allocator: Allocator, base: ?*SnapshotReader, delta: ?*SnapshotReader) Allocator.Error!*SnapshotStack {
        const s = try allocator.create(SnapshotStack);
        if (base) |b| b.retain();
        if (delta) |d| d.retain();
        s.* = .{
            .allocator = allocator,
            .base = base,
            .delta = delta,
            .ref_count = std.atomic.Value(usize).init(1),
        };
        return s;
    }

    pub fn retain(self: *SnapshotStack) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *SnapshotStack) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            if (self.delta) |d| d.release();
            if (self.base) |b| b.release();
            self.allocator.destroy(self);
        }
    }

    pub fn hibernate(self: *SnapshotStack) void {
        if (self.delta) |d| d.hibernate();
        if (self.base) |b| b.hibernate();
    }

    pub fn activeTop(self: *const SnapshotStack) ?*SnapshotReader {
        return self.delta orelse self.base;
    }

    pub fn dagSource(self: *const SnapshotStack) dag_mod.DagSource {
        return .{
            .ptr = self,
            .batchCountFn = dagBatchCountAdapter,
            .getBatchMetaFn = dagGetBatchMetaAdapter,
            .appendParentsFn = dagAppendParentsAdapter,
            .parentsEqualFn = dagParentsEqualAdapter,
            .actorRangeOverlapsFn = dagActorRangeOverlapsAdapter,
            .findActorRunFn = dagFindActorRunAdapter,
            .appendAllBatchIdsFn = dagAppendAllBatchIdsAdapter,
        };
    }

    pub fn inodeSource(self: *const SnapshotStack) tree_mod.InodeSource {
        return .{
            .ptr = self,
            .loadInodeFn = loadInodeAdapter,
            .hasInodeFn = hasInodeAdapter,
            .collectDirChildrenFn = collectDirChildrenAdapter,
            .lookupDirNameFn = lookupDirNameAdapter,
        };
    }

    pub fn nodeSource(self: *const SnapshotStack) text_mod.NodeSource {
        return .{
            .ptr = self,
            .loadNodeFn = loadNodeAdapter,
            .widthInDiskFn = widthInDiskAdapter,
            .countLinesDiskFn = countLinesDiskAdapter,
        };
    }

    pub fn insertionSource(self: *const SnapshotStack) history_mod.InsertionSource {
        return .{
            .ptr = self,
            .lookupFn = lookupInsertionAdapter,
        };
    }

    pub fn loadStateIntoHistory(self: *const SnapshotStack, allocator: Allocator, h: *history_mod.History) !MetaScopesData {
        const top = self.activeTop() orelse return .{};
        h.dag.heads.deinit(h.allocator);
        h.dag.heads = try top.dagHeads(h.allocator);
        h.dag.horizon.deinit(h.allocator);
        h.dag.horizon = try top.dagHorizon(h.allocator);
        h.dag.max_ts = top.header.max_ts;
        h.dag.next_batch_idx = top.header.next_batch_idx;
        if (self.base) |b| {
            if (b.header.max_ts > h.dag.max_ts) h.dag.max_ts = b.header.max_ts;
            if (b.header.next_batch_idx > h.dag.next_batch_idx) h.dag.next_batch_idx = b.header.next_batch_idx;
        }
        return try top.loadMetaScopes(allocator, h);
    }

    pub fn collectReferencedBlobOids(
        self: *const SnapshotStack,
        allocator: Allocator,
        out: *std.AutoHashMapUnmanaged(id.Oid, void),
    ) Allocator.Error!void {
        if (self.base) |b| try b.collectReferencedBlobOids(allocator, out);
        if (self.delta) |d| try d.collectReferencedBlobOids(allocator, out);
    }

    fn dagBatchCountAdapter(ptr: *const anyopaque) usize {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        var n: usize = 0;
        if (self.base) |b| n += b.dagBatchCount();
        if (self.delta) |d| n += d.dagBatchCount();
        return n;
    }

    fn dagGetBatchMetaAdapter(ptr: *const anyopaque, bid: id.BatchId) ?dag_mod.BatchMeta {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (d.dagGetBatchMeta(bid)) |m| return m;
        }
        if (self.base) |b| return b.dagGetBatchMeta(bid);
        return null;
    }

    fn dagAppendParentsAdapter(ptr: *const anyopaque, allocator: Allocator, bid: id.BatchId, out: *std.ArrayList(id.BatchId)) Allocator.Error!bool {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (try d.dagAppendParents(allocator, bid, out)) return true;
        }
        if (self.base) |b| return try b.dagAppendParents(allocator, bid, out);
        return false;
    }

    fn dagParentsEqualAdapter(ptr: *const anyopaque, bid: id.BatchId, parents: *const Version) bool {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (d.dagGetBatchMeta(bid) != null) return d.dagParentsEqual(bid, parents);
        }
        if (self.base) |b| return b.dagParentsEqual(bid, parents);
        return false;
    }

    fn dagActorRangeOverlapsAdapter(ptr: *const anyopaque, actor: id.ActorId, start: id.Lamport, end: id.Lamport) bool {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (d.dagActorRangeOverlaps(actor, start, end)) return true;
        }
        if (self.base) |b| return b.dagActorRangeOverlaps(actor, start, end);
        return false;
    }

    fn dagFindActorRunAdapter(ptr: *const anyopaque, op: id.OpId) ?dag_mod.ActorRun {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (d.dagFindActorRun(op)) |r| return r;
        }
        if (self.base) |b| return b.dagFindActorRun(op);
        return null;
    }

    fn dagAppendAllBatchIdsAdapter(ptr: *const anyopaque, allocator: Allocator, out: *std.ArrayList(id.BatchId)) Allocator.Error!void {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.base) |b| try b.dagAppendAllBatchIds(allocator, out);
        if (self.delta) |d| try d.dagAppendAllBatchIds(allocator, out);
    }

    fn loadInodeAdapter(ptr: *const anyopaque, allocator: Allocator, iid: id.InodeId) Allocator.Error!?*tree_mod.Inode {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        const ns = self.nodeSource();
        if (self.delta) |d| {
            if (try d.loadInode(allocator, iid, ns)) |in| return in;
        }
        if (self.base) |b| return try b.loadInode(allocator, iid, ns);
        return null;
    }

    fn hasInodeAdapter(ptr: *const anyopaque, iid: id.InodeId) bool {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (d.hasInode(iid)) return true;
        }
        if (self.base) |b| return b.hasInode(iid);
        return false;
    }

    fn collectDirChildrenAdapter(ptr: *const anyopaque, allocator: Allocator, dir: id.InodeId, out: *std.ArrayList(id.InodeId)) Allocator.Error!void {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.base) |b| try b.collectDirChildren(allocator, dir, out);
        if (self.delta) |d| {
            if (out.items.len == 0) {
                try d.collectDirChildren(allocator, dir, out);
            } else {
                var tmp: std.ArrayList(id.InodeId) = .empty;
                defer tmp.deinit(allocator);
                try d.collectDirChildren(allocator, dir, &tmp);
                if (tmp.items.len > 0) {
                    var seen: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
                    defer seen.deinit(allocator);
                    for (out.items) |k| try seen.put(allocator, k, {});
                    for (tmp.items) |k| {
                        if (!seen.contains(k)) {
                            try seen.put(allocator, k, {});
                            try out.append(allocator, k);
                        }
                    }
                }
            }
        }
    }

    fn lookupDirNameAdapter(ptr: *const anyopaque, parent: id.InodeId, name: []const u8) ?tree_mod.DirNameLookup {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        if (self.delta) |d| {
            if (d.lookupDirName(parent, name)) |hit| return hit;
        }
        if (self.base) |b| return b.lookupDirName(parent, name);
        return null;
    }

    fn loadNodeAdapter(ptr: *const anyopaque, allocator: Allocator, ref: text_mod.DiskNodeRef) Allocator.Error!?*text_mod.Node {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        const reader = if (ref.is_delta) self.delta else self.base;
        const r = reader orelse return null;
        return try r.loadTextNode(allocator, ref);
    }

    fn widthInDiskAdapter(ptr: *const anyopaque, ref: text_mod.DiskNodeRef, view: text_mod.View) u64 {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        const reader = (if (ref.is_delta) self.delta else self.base) orelse return 0;
        const payload = reader.textNodePayload(ref.id) orelse return 0;
        var r = codec.Reader.init(payload);
        const kind_b = r.readByte() catch return 0;
        const len_b = r.readByte() catch return 0;
        var sum: u64 = 0;
        if (kind_b == 0) {
            for (0..len_b) |_| {
                const ins = reader.readActorOp(&r) catch return sum;
                _ = r.readVarint() catch return sum;
                _ = r.readVarint() catch return sum;
                _ = r.readVarint() catch return sum;
                const flen = r.readVarint() catch return sum;
                _ = r.readByte() catch return sum;
                const del_cnt = r.readByte() catch return sum;
                var vis = view.observes(ins);
                if (del_cnt == 1) {
                    const dop = reader.readActorOp(&r) catch return sum;
                    if (vis and view.observes(dop)) vis = false;
                } else if (del_cnt > 1) {
                    const rc: usize = @intCast(r.readVarint() catch return sum);
                    for (0..rc) |_| {
                        const dop = reader.readActorOp(&r) catch return sum;
                        if (vis and view.observes(dop)) vis = false;
                    }
                }
                if (vis) sum += flen;
            }
        } else if (kind_b == 1) {
            for (0..len_b) |_| {
                const raw_child = r.readU32() catch return sum;
                const vis = r.readU64() catch return sum;
                _ = r.readU64() catch return sum;
                _ = r.readU64() catch return sum;
                const max_ts = r.readU64() catch return sum;
                _ = r.readByte() catch return sum;
                _ = r.readU32() catch return sum;
                if (max_ts < view.min_unobserved) {
                    sum += vis;
                } else if (text_mod.DiskNodeRef.fromRaw(raw_child)) |cref| {
                    sum += widthInDiskAdapter(ptr, cref, view);
                }
            }
        }
        return sum;
    }

    fn countLinesDiskAdapter(ptr: *const anyopaque, ref: text_mod.DiskNodeRef, resolver: text_mod.ContentResolver, nl: *usize, last_nl: *bool) void {
        const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
        const reader = (if (ref.is_delta) self.delta else self.base) orelse return;
        const payload = reader.textNodePayload(ref.id) orelse return;
        var r = codec.Reader.init(payload);
        const kind_b = r.readByte() catch return;
        const len_b = r.readByte() catch return;
        if (kind_b == 0) {
            for (0..len_b) |_| {
                const ins = reader.readActorOp(&r) catch return;
                const part: u32 = @intCast(r.readVarint() catch return);
                const newlines: u32 = @intCast(r.readVarint() catch return);
                const off = r.readVarint() catch return;
                const flen = r.readVarint() catch return;
                const fflags = r.readByte() catch return;
                const del_cnt = r.readByte() catch return;
                if (del_cnt == 1) {
                    _ = reader.readActorOp(&r) catch return;
                } else if (del_cnt > 1) {
                    const rc: usize = @intCast(r.readVarint() catch return);
                    for (0..rc) |_| _ = reader.readActorOp(&r) catch return;
                }
                if (del_cnt != 0 or flen == 0) continue;
                if ((fflags & 2) != 0) {
                    nl.* += newlines;
                    last_nl.* = (fflags & 1) != 0;
                } else if (resolver.resolve(.{ .op = ins, .part = part })) |bytes| {
                    const st: usize = @intCast(off);
                    const en: usize = @intCast(off + flen);
                    if (en <= bytes.len) {
                        const sl = bytes[st..en];
                        for (sl) |b| {
                            if (b == '\n') nl.* += 1;
                        }
                        last_nl.* = sl.len > 0 and sl[sl.len - 1] == '\n';
                    }
                }
            }
        } else if (kind_b == 1) {
            for (0..len_b) |_| {
                const raw_child = r.readU32() catch return;
                const vis = r.readU64() catch return;
                const vis_nl = r.readU64() catch return;
                _ = r.readU64() catch return;
                _ = r.readU64() catch return;
                const sflags = r.readByte() catch return;
                _ = r.readU32() catch return;
                if (vis == 0) continue;
                if ((sflags & 2) == 0) {
                    nl.* += @intCast(vis_nl);
                    last_nl.* = (sflags & 1) != 0;
                } else if (text_mod.DiskNodeRef.fromRaw(raw_child)) |cref| {
                    countLinesDiskAdapter(ptr, cref, resolver, nl, last_nl);
                }
            }
        }
    }
};

fn lookupInsertionAdapter(ptr: *const anyopaque, key: id.InsertionKey) ?history_mod.InsertionLookup {
    const self: *const SnapshotStack = @ptrCast(@alignCast(ptr));
    if (self.delta) |d| {
        if (d.lookupInsertion(key)) |found| return found;
    }
    if (self.base) |b| return b.lookupInsertion(key);
    return null;
}

pub const WriteParams = struct {
    history: *const history_mod.History,
    stack: ?*const SnapshotStack = null,
    generation: u64,
    base_generation: u64,
    wal_cutoff_seq: u64,
    created_ms: u64,
    meta_scopes: MetaScopesInput = .{},
    pruned_batches: ?*const std.AutoHashMapUnmanaged(id.BatchId, void) = null,
};

pub const WriteResult = struct {
    file_size: u64,
    file_blake3: [32]u8,
    inode_count: u64,
    batch_count: u64,
    text_node_count: u64,
};

const ActorInterner = struct {
    list: std.ArrayList(id.ActorId) = .empty,
    map: std.AutoHashMapUnmanaged(id.ActorId, u32) = .empty,

    fn deinit(self: *ActorInterner, allocator: Allocator) void {
        self.list.deinit(allocator);
        self.map.deinit(allocator);
    }

    fn intern(self: *ActorInterner, allocator: Allocator, actor: id.ActorId) Allocator.Error!u32 {
        if (self.map.get(actor)) |idx| return idx;
        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(allocator, actor);
        try self.map.put(allocator, actor, idx);
        return idx;
    }

    fn writeSection(self: *const ActorInterner, allocator: Allocator, out: *std.ArrayList(u8)) Allocator.Error!u64 {
        const cnt: u32 = @intCast(self.list.items.len);
        var hdr: [8]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], cnt, .little);
        try out.appendSlice(allocator, &hdr);
        for (self.list.items) |a| {
            var b: [16]u8 = undefined;
            std.mem.writeInt(u128, &b, a, .little);
            try out.appendSlice(allocator, &b);
        }
        const Pair = struct { actor: id.ActorId, idx: u32 };
        const pairs = try allocator.alloc(Pair, self.list.items.len);
        defer allocator.free(pairs);
        for (self.list.items, 0..) |a, i| pairs[i] = .{ .actor = a, .idx = @intCast(i) };
        std.mem.sort(Pair, pairs, {}, struct {
            fn lt(_: void, lhs: Pair, rhs: Pair) bool {
                return lhs.actor < rhs.actor;
            }
        }.lt);
        for (pairs) |p| {
            var b: [20]u8 = undefined;
            std.mem.writeInt(u128, b[0..16], p.actor, .little);
            std.mem.writeInt(u32, b[16..20], p.idx, .little);
            try out.appendSlice(allocator, &b);
        }
        return cnt;
    }
};

const TextNodeWriter = struct {
    allocator: Allocator,
    is_delta: bool,
    old_stack: ?*const SnapshotStack,
    actors: *ActorInterner,
    descs: std.ArrayList(DiskNodeDesc) = .empty,
    payloads: std.ArrayList(u8) = .empty,
    ref_remap: std.AutoHashMapUnmanaged(u32, text_mod.DiskNodeRef) = .empty,
    live_insertions: ?*std.AutoHashMapUnmanaged(id.InsertionKey, void) = null,
    dag: ?*const dag_mod.Dag = null,
    pruned_batches: ?*const std.AutoHashMapUnmanaged(id.BatchId, void) = null,

    fn deinit(self: *TextNodeWriter) void {
        self.descs.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.ref_remap.deinit(self.allocator);
    }

    fn writeActorOp(self: *TextNodeWriter, w: *codec.Writer, op: id.OpId) Allocator.Error!void {
        const aidx = try self.actors.intern(self.allocator, op.actor);
        try w.writeVarint(self.allocator, op.ts);
        try w.writeVarint(self.allocator, aidx);
    }

    fn emitNodeBytes(self: *TextNodeWriter, bytes: []const u8) Allocator.Error!text_mod.DiskNodeRef {
        const node_id: u31 = @intCast(self.descs.items.len);
        const off: u64 = self.payloads.items.len;
        const crc = codec.crc32c(bytes);
        try self.payloads.appendSlice(self.allocator, bytes);
        try self.descs.append(self.allocator, .{
            .offset = off,
            .len = @intCast(bytes.len),
            .crc32c = crc,
        });
        return .{ .id = node_id, .is_delta = self.is_delta };
    }

    fn copyDiskRef(self: *TextNodeWriter, old_ref: text_mod.DiskNodeRef) Allocator.Error!text_mod.DiskNodeRef {
        if (self.is_delta and !old_ref.is_delta) {
            return old_ref;
        }
        const raw = old_ref.toRaw();
        if (self.ref_remap.get(raw)) |mapped| return mapped;
        const stack = self.old_stack orelse return old_ref;
        const reader = (if (old_ref.is_delta) stack.delta else stack.base) orelse return old_ref;
        const loaded = (try reader.loadTextNode(self.allocator, old_ref)) orelse return old_ref;
        defer loaded.release(self.allocator);
        loaded.persisted = null;
        const new_ref = try self.writeResidentNode(loaded);
        try self.ref_remap.put(self.allocator, raw, new_ref);
        return new_ref;
    }

    fn writeResidentNode(self: *TextNodeWriter, node: *const text_mod.Node) Allocator.Error!text_mod.DiskNodeRef {
        if (node.persisted) |pref| {
            if (self.is_delta and !pref.is_delta) {
                return pref;
            }
            const raw = pref.toRaw();
            if (self.ref_remap.get(raw)) |mapped| return mapped;
        }
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        switch (node.kind) {
            .leaf => {
                try w.writeByte(self.allocator, 0);
                try w.writeByte(self.allocator, node.len);
                for (node.data.leaf[0..node.len]) |*f| {
                    if (self.live_insertions) |li| {
                        var dead_below_horizon = false;
                        if (f.del_count > 0 and self.dag != null and self.pruned_batches != null and self.pruned_batches.?.count() > 0) {
                            if (f.del_count == 1) {
                                dead_below_horizon = isOpInPruned(self.dag, self.pruned_batches, f.del_inline);
                            } else if (f.del_overflow) |ov| {
                                for (ov) |d| {
                                    if (isOpInPruned(self.dag, self.pruned_batches, d)) {
                                        dead_below_horizon = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if (!dead_below_horizon) {
                            try li.put(self.allocator, f.key(), {});
                        }
                    }
                    try self.writeActorOp(&w, f.ins);
                    try w.writeVarint(self.allocator, f.part);
                    try w.writeVarint(self.allocator, f.newlines);
                    try w.writeVarint(self.allocator, f.off);
                    try w.writeVarint(self.allocator, f.len);
                    var ff: u8 = 0;
                    if (f.ends_with_nl) ff |= 1;
                    if (f.newlines_known) ff |= 2;
                    try w.writeByte(self.allocator, ff);
                    try w.writeByte(self.allocator, f.del_count);
                    if (f.del_count == 1) {
                        try self.writeActorOp(&w, f.del_inline);
                    } else if (f.del_count > 1) {
                        const ov = f.del_overflow orelse &.{};
                        try w.writeVarint(self.allocator, ov.len);
                        for (ov) |d| try self.writeActorOp(&w, d);
                    }
                }
            },
            .branch => {
                var child_refs: [text_mod.BRANCH_CAP]text_mod.DiskNodeRef = undefined;
                for (0..node.len) |i| {
                    child_refs[i] = switch (node.data.branch.children[i]) {
                        .resident => |c| try self.writeResidentNode(c),
                        .disk => |dref| try self.copyDiskRef(dref),
                    };
                }
                try w.writeByte(self.allocator, 1);
                try w.writeByte(self.allocator, node.len);
                for (0..node.len) |i| {
                    try w.writeU32(self.allocator, child_refs[i].toRaw());
                    const s = node.data.branch.summaries[i];
                    try w.writeU64(self.allocator, s.visible);
                    try w.writeU64(self.allocator, s.visible_newlines);
                    try w.writeU64(self.allocator, s.total);
                    try w.writeU64(self.allocator, s.max_ts);
                    var sf: u8 = 0;
                    if (s.ends_with_nl) sf |= 1;
                    if (s.unknown_newlines) sf |= 2;
                    try w.writeByte(self.allocator, sf);
                    try w.writeU32(self.allocator, @intCast(node.data.branch.counts[i]));
                }
            },
        }
        const new_ref = try self.emitNodeBytes(w.items());
        if (node.persisted) |pref| {
            try self.ref_remap.put(self.allocator, pref.toRaw(), new_ref);
        }
        return new_ref;
    }

    fn writeText(self: *TextNodeWriter, txt: *const text_mod.Text) Allocator.Error!?text_mod.DiskNodeRef {
        if (txt.root) |r| {
            return try self.writeResidentNode(r);
        }
        if (txt.disk_root) |dref| {
            return try self.copyDiskRef(dref);
        }
        return null;
    }

    fn writeSection(self: *const TextNodeWriter, out: *std.ArrayList(u8)) Allocator.Error!u64 {
        const cnt: u32 = @intCast(self.descs.items.len);
        var hdr: [8]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], cnt, .little);
        try out.appendSlice(self.allocator, &hdr);
        for (self.descs.items) |d| {
            var b: [16]u8 = undefined;
            std.mem.writeInt(u64, b[0..8], d.offset, .little);
            std.mem.writeInt(u32, b[8..12], d.len, .little);
            std.mem.writeInt(u32, b[12..16], d.crc32c, .little);
            try out.appendSlice(self.allocator, &b);
        }
        try out.appendSlice(self.allocator, self.payloads.items);
        return cnt;
    }
};

fn isOpInPruned(
    dag_opt: ?*const dag_mod.Dag,
    pruned_opt: ?*const std.AutoHashMapUnmanaged(id.BatchId, void),
    op: id.OpId,
) bool {
    const pruned = pruned_opt orelse return false;
    if (pruned.count() == 0) return false;
    const dag = dag_opt orelse return false;
    const bid = dag.batchOf(op) orelse return false;
    return pruned.contains(bid);
}

fn encodeInodePayload(
    allocator: Allocator,
    inode: *const tree_mod.Inode,
    actors: *ActorInterner,
    node_writer: *TextNodeWriter,
    out: *codec.Writer,
) Allocator.Error!u64 {
    var max_ts: u64 = inode.inode_id.op.ts;
    const ktag: u8 = switch (inode.kind) {
        .dir => 0,
        .file => 1,
        .symlink => 2,
    };
    try out.writeByte(allocator, ktag);

    try out.writeVarint(allocator, inode.placement.entries.items.len);
    for (inode.placement.entries.items) |e| {
        if (e.op.ts > max_ts) max_ts = e.op.ts;
        try out.writeVarint(allocator, e.op.ts);
        try out.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
        try out.writeVarint(allocator, e.value.parent.op.ts);
        try out.writeVarint(allocator, try actors.intern(allocator, e.value.parent.op.actor));
        try out.writeVarint(allocator, e.value.parent.part);
        try out.writeBytes(allocator, e.value.name);
    }

    try out.writeVarint(allocator, inode.alive.entries.items.len);
    for (inode.alive.entries.items) |e| {
        if (e.op.ts > max_ts) max_ts = e.op.ts;
        try out.writeVarint(allocator, e.op.ts);
        try out.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
        try out.writeBool(allocator, e.value);
    }

    switch (inode.kind) {
        .dir => {},
        .file => |*f| {
            const root_ref = try node_writer.writeText(&f.text);
            const raw_root = if (root_ref) |rr| rr.toRaw() else text_mod.DiskNodeRef.NONE_RAW;
            const sum = f.text.summary();
            if (sum.max_ts > max_ts) max_ts = sum.max_ts;
            try out.writeU32(allocator, raw_root);
            try out.writeU64(allocator, sum.visible);
            try out.writeU64(allocator, sum.visible_newlines);
            try out.writeU64(allocator, sum.total);
            try out.writeU64(allocator, sum.max_ts);
            var sf: u8 = 0;
            if (sum.ends_with_nl) sf |= 1;
            if (sum.unknown_newlines) sf |= 2;
            try out.writeByte(allocator, sf);
            try out.writeU32(allocator, @intCast(f.text.fragmentCount()));

            var last_pruned_content_idx: ?usize = null;
            if (node_writer.pruned_batches != null and node_writer.pruned_batches.?.count() > 0) {
                for (f.content.entries.items, 0..) |e, idx| {
                    if (isOpInPruned(node_writer.dag, node_writer.pruned_batches, e.op)) {
                        last_pruned_content_idx = idx;
                    }
                }
            }
            var kept_content_cnt: usize = 0;
            for (f.content.entries.items, 0..) |e, idx| {
                if (last_pruned_content_idx) |lp| {
                    if (idx < lp and isOpInPruned(node_writer.dag, node_writer.pruned_batches, e.op)) continue;
                }
                kept_content_cnt += 1;
            }
            try out.writeVarint(allocator, kept_content_cnt);
            for (f.content.entries.items, 0..) |e, idx| {
                if (last_pruned_content_idx) |lp| {
                    if (idx < lp and isOpInPruned(node_writer.dag, node_writer.pruned_batches, e.op)) continue;
                }
                if (e.op.ts > max_ts) max_ts = e.op.ts;
                try out.writeVarint(allocator, e.op.ts);
                try out.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
                switch (e.value) {
                    .text => try out.writeByte(allocator, 0),
                    .binary => |r| {
                        try out.writeByte(allocator, 1);
                        try out.writeRaw(allocator, &r.oid);
                        try out.writeVarint(allocator, r.len);
                    },
                    .git_binary => |r| {
                        try out.writeByte(allocator, 2);
                        try out.writeByte(allocator, r.oid.len);
                        try out.writeRaw(allocator, r.oid.slice());
                        try out.writeVarint(allocator, r.len);
                    },
                    .git_lazy => |r| {
                        try out.writeByte(allocator, 3);
                        try out.writeByte(allocator, r.oid.len);
                        try out.writeRaw(allocator, r.oid.slice());
                        try out.writeVarint(allocator, r.len);
                    },
                }
            }

            try out.writeVarint(allocator, f.mode.entries.items.len);
            for (f.mode.entries.items) |e| {
                if (e.op.ts > max_ts) max_ts = e.op.ts;
                try out.writeVarint(allocator, e.op.ts);
                try out.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
                try out.writeByte(allocator, @intFromEnum(e.value));
            }

            try out.writeVarint(allocator, f.line_ending.entries.items.len);
            for (f.line_ending.entries.items) |e| {
                if (e.op.ts > max_ts) max_ts = e.op.ts;
                try out.writeVarint(allocator, e.op.ts);
                try out.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
                try out.writeByte(allocator, @intFromEnum(e.value));
            }
        },
        .symlink => |*sym| {
            try out.writeVarint(allocator, sym.entries.items.len);
            for (sym.entries.items) |e| {
                if (e.op.ts > max_ts) max_ts = e.op.ts;
                try out.writeVarint(allocator, e.op.ts);
                try out.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
                try out.writeBytes(allocator, e.value);
            }
        },
    }
    return max_ts;
}

const BatchBuildItem = struct {
    bid: id.BatchId,
    meta: dag_mod.BatchMeta,
    parents: std.ArrayList(id.BatchId),

    fn deinit(self: *BatchBuildItem, allocator: Allocator) void {
        self.parents.deinit(allocator);
    }
};

fn buildDagSection(
    allocator: Allocator,
    h: *const history_mod.History,
    old_stack: ?*const SnapshotStack,
    is_delta: bool,
    pruned: ?*const std.AutoHashMapUnmanaged(id.BatchId, void),
    actors: *ActorInterner,
    out: *std.ArrayList(u8),
) Allocator.Error!u64 {
    var batch_map: std.AutoHashMapUnmanaged(id.BatchId, BatchBuildItem) = .empty;
    defer {
        var it = batch_map.valueIterator();
        while (it.next()) |item| item.deinit(allocator);
        batch_map.deinit(allocator);
    }

    const readers: [2]?*SnapshotReader = if (old_stack) |st|
        if (is_delta) .{ st.delta, null } else .{ st.base, st.delta }
    else
        .{ null, null };

    for (readers) |r_opt| {
        const reader = r_opt orelse continue;
        var ids: std.ArrayList(id.BatchId) = .empty;
        defer ids.deinit(allocator);
        try reader.dagAppendAllBatchIds(allocator, &ids);
        for (ids.items) |bid| {
            if (pruned) |ps| {
                if (ps.contains(bid)) continue;
            }
            if (batch_map.contains(bid)) continue;
            const meta = reader.dagGetBatchMeta(bid) orelse continue;
            var plist: std.ArrayList(id.BatchId) = .empty;
            errdefer plist.deinit(allocator);
            _ = try reader.dagAppendParents(allocator, bid, &plist);
            try batch_map.put(allocator, bid, .{
                .bid = bid,
                .meta = meta,
                .parents = plist,
            });
        }
    }

    var hit = h.dag.headers.iterator();
    while (hit.next()) |kv| {
        const bid = kv.key_ptr.*;
        if (pruned) |ps| {
            if (ps.contains(bid)) continue;
        }
        const meta = h.dag.getBatchMeta(bid) orelse continue;
        var plist: std.ArrayList(id.BatchId) = .empty;
        errdefer plist.deinit(allocator);
        try plist.appendSlice(allocator, kv.value_ptr.parents.slice());
        if (try batch_map.fetchPut(allocator, bid, .{
            .bid = bid,
            .meta = meta,
            .parents = plist,
        })) |old| {
            var ov = old.value;
            ov.deinit(allocator);
        }
    }

    var heads_disk: std.ArrayList(DiskOpId) = .empty;
    defer heads_disk.deinit(allocator);
    for (h.dag.heads.slice()) |hd| {
        try heads_disk.append(allocator, .{ .ts = hd.ts, .actor_idx = try actors.intern(allocator, hd.actor) });
    }

    var horizon_disk: std.ArrayList(DiskOpId) = .empty;
    defer horizon_disk.deinit(allocator);
    for (h.dag.horizon.slice()) |hz| {
        try horizon_disk.append(allocator, .{ .ts = hz.ts, .actor_idx = try actors.intern(allocator, hz.actor) });
    }

    var entries: std.ArrayList(DiskBatchEntry) = .empty;
    defer entries.deinit(allocator);
    var runs: std.ArrayList(DiskActorRun) = .empty;
    defer runs.deinit(allocator);
    var parents_pool: std.ArrayList(DiskOpId) = .empty;
    defer parents_pool.deinit(allocator);

    var bit = batch_map.valueIterator();
    while (bit.next()) |item| {
        const aidx = try actors.intern(allocator, item.meta.actor);
        const poff: u32 = @intCast(parents_pool.items.len);
        for (item.parents.items) |p| {
            try parents_pool.append(allocator, .{ .ts = p.ts, .actor_idx = try actors.intern(allocator, p.actor) });
        }
        try entries.append(allocator, DiskBatchEntry.make(
            item.meta.start,
            item.meta.end,
            aidx,
            item.meta.batch_idx,
            item.meta.log_seg,
            item.meta.log_off,
            item.meta.log_len,
            item.meta.wall_ms,
            poff,
            @intCast(item.parents.items.len),
            item.meta.flags,
        ));
        try runs.append(allocator, .{
            .actor_idx = aidx,
            .batch_idx = item.meta.batch_idx,
            .start_ts = item.meta.start,
            .end_ts = item.meta.end,
        });
    }

    std.mem.sort(DiskBatchEntry, entries.items, {}, struct {
        fn lt(_: void, a: DiskBatchEntry, b: DiskBatchEntry) bool {
            if (a.end_ts != b.end_ts) return a.end_ts < b.end_ts;
            return a.actor_idx < b.actor_idx;
        }
    }.lt);

    std.mem.sort(DiskActorRun, runs.items, {}, struct {
        fn lt(_: void, a: DiskActorRun, b: DiskActorRun) bool {
            if (a.actor_idx != b.actor_idx) return a.actor_idx < b.actor_idx;
            return a.end_ts < b.end_ts;
        }
    }.lt);

    var hdr: [24]u8 = @splat(0);
    std.mem.writeInt(u32, hdr[0..4], @intCast(heads_disk.items.len), .little);
    std.mem.writeInt(u32, hdr[4..8], @intCast(horizon_disk.items.len), .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(entries.items.len), .little);
    std.mem.writeInt(u32, hdr[12..16], @intCast(runs.items.len), .little);
    std.mem.writeInt(u32, hdr[16..20], @intCast(parents_pool.items.len), .little);
    try out.appendSlice(allocator, &hdr);

    for (heads_disk.items) |op| {
        var b: [16]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], op.ts, .little);
        std.mem.writeInt(u32, b[8..12], op.actor_idx, .little);
        try out.appendSlice(allocator, &b);
    }
    for (horizon_disk.items) |op| {
        var b: [16]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], op.ts, .little);
        std.mem.writeInt(u32, b[8..12], op.actor_idx, .little);
        try out.appendSlice(allocator, &b);
    }
    for (entries.items) |e| {
        var b: [48]u8 = undefined;
        std.mem.writeInt(u64, b[0..8], e.end_ts, .little);
        std.mem.writeInt(u32, b[8..12], e.start_delta, .little);
        std.mem.writeInt(u32, b[12..16], e.actor_idx, .little);
        std.mem.writeInt(u32, b[16..20], e.batch_idx, .little);
        std.mem.writeInt(u32, b[20..24], e.log_seg, .little);
        std.mem.writeInt(u32, b[24..28], e.log_len, .little);
        std.mem.writeInt(u32, b[28..32], e.parents_off, .little);
        std.mem.writeInt(u64, b[32..40], e.log_off_and_flags, .little);
        std.mem.writeInt(u64, b[40..48], e.wall_ms_and_pcount, .little);
        try out.appendSlice(allocator, &b);
    }
    for (runs.items) |r| {
        var b: [24]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], r.actor_idx, .little);
        std.mem.writeInt(u32, b[4..8], r.batch_idx, .little);
        std.mem.writeInt(u64, b[8..16], r.start_ts, .little);
        std.mem.writeInt(u64, b[16..24], r.end_ts, .little);
        try out.appendSlice(allocator, &b);
    }
    for (parents_pool.items) |op| {
        var b: [16]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], op.ts, .little);
        std.mem.writeInt(u32, b[8..12], op.actor_idx, .little);
        try out.appendSlice(allocator, &b);
    }
    return entries.items.len;
}

const InsertionBuildVal = union(enum) {
    inline_bytes: []u8,
    blob_oid: id.Oid,
    git_oid: git_dirs.GitOid,

    fn deinit(self: *InsertionBuildVal, allocator: Allocator) void {
        switch (self.*) {
            .inline_bytes => |b| allocator.free(b),
            else => {},
        }
    }
};

fn collectInsertionsFromReader(
    allocator: Allocator,
    reader: *const SnapshotReader,
    live_filter: ?*const std.AutoHashMapUnmanaged(id.InsertionKey, void),
    map: *std.AutoHashMapUnmanaged(id.InsertionKey, InsertionBuildVal),
) Allocator.Error!void {
    if (reader.insertions_sec.len < 24) return;
    const entry_cnt = std.mem.readInt(u32, reader.insertions_sec[0..4], .little);
    const blob_cnt = std.mem.readInt(u32, reader.insertions_sec[4..8], .little);
    const git_cnt = std.mem.readInt(u32, reader.insertions_sec[8..12], .little);
    const arena_len = std.mem.readInt(u64, reader.insertions_sec[16..24], .little);
    const entries_off: usize = 24;
    const blobs_off = entries_off + @as(usize, entry_cnt) * 32;
    const gits_off = blobs_off + @as(usize, blob_cnt) * 32;
    const arena_off = gits_off + @as(usize, git_cnt) * 36;
    if (arena_off + @as(usize, @intCast(arena_len)) > reader.insertions_sec.len) return;

    for (0..entry_cnt) |i| {
        const pos = entries_off + i * 32;
        const ts = std.mem.readInt(u64, reader.insertions_sec[pos..][0..8], .little);
        const ai = std.mem.readInt(u32, reader.insertions_sec[pos + 8 ..][0..4], .little);
        const part = std.mem.readInt(u32, reader.insertions_sec[pos + 12 ..][0..4], .little);
        const actor = reader.actorByIdx(ai) orelse continue;
        const key = id.InsertionKey{ .op = id.OpId.init(ts, actor), .part = part };
        if (live_filter) |lf| {
            if (!lf.contains(key)) continue;
        }
        const kind = reader.insertions_sec[pos + 16];
        const len = std.mem.readInt(u32, reader.insertions_sec[pos + 20 ..][0..4], .little);
        const pref = std.mem.readInt(u64, reader.insertions_sec[pos + 24 ..][0..8], .little);
        const val: InsertionBuildVal = switch (kind) {
            INS_KIND_INLINE => blk: {
                const s = arena_off + @as(usize, @intCast(pref));
                const e = s + @as(usize, len);
                if (e > reader.insertions_sec.len) continue;
                break :blk .{ .inline_bytes = try allocator.dupe(u8, reader.insertions_sec[s..e]) };
            },
            INS_KIND_BLOB => blk: {
                const bi: usize = @intCast(pref);
                if (bi >= blob_cnt) continue;
                break :blk .{ .blob_oid = reader.insertions_sec[blobs_off + bi * 32 ..][0..32].* };
            },
            INS_KIND_GIT => blk: {
                const gi: usize = @intCast(pref);
                if (gi >= git_cnt) continue;
                const goff = gits_off + gi * 36;
                var goid = git_dirs.GitOid{ .len = reader.insertions_sec[goff], .bytes = @splat(0) };
                @memcpy(&goid.bytes, reader.insertions_sec[goff + 1 .. goff + 33]);
                break :blk .{ .git_oid = goid };
            },
            else => continue,
        };
        if (try map.fetchPut(allocator, key, val)) |prev| {
            var pv = prev.value;
            pv.deinit(allocator);
        }
    }
}

fn buildInsertionsSection(
    allocator: Allocator,
    h: *const history_mod.History,
    old_stack: ?*const SnapshotStack,
    is_delta: bool,
    live_filter: ?*const std.AutoHashMapUnmanaged(id.InsertionKey, void),
    actors: *ActorInterner,
    out: *std.ArrayList(u8),
) Allocator.Error!u64 {
    var map: std.AutoHashMapUnmanaged(id.InsertionKey, InsertionBuildVal) = .empty;
    defer {
        var it = map.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        map.deinit(allocator);
    }

    if (old_stack) |st| {
        if (!is_delta) {
            if (st.base) |b| try collectInsertionsFromReader(allocator, b, live_filter, &map);
        }
        if (st.delta) |d| try collectInsertionsFromReader(allocator, d, live_filter, &map);
    }

    var ib_it = h.insertion_blobs.iterator();
    while (ib_it.next()) |kv| {
        if (live_filter) |lf| {
            if (!lf.contains(kv.key_ptr.*)) continue;
        }
        if (try map.fetchPut(allocator, kv.key_ptr.*, .{ .blob_oid = kv.value_ptr.* })) |prev| {
            var pv = prev.value;
            pv.deinit(allocator);
        }
    }

    var ins_it = h.insertions.iterator();
    while (ins_it.next()) |kv| {
        if (live_filter) |lf| {
            if (!lf.contains(kv.key_ptr.*)) continue;
        }
        const val: InsertionBuildVal = switch (kv.value_ptr.*) {
            .owned => |b| .{ .inline_bytes = try allocator.dupe(u8, b) },
            .log_span => |sp| blk: {
                const lr = h.log_reader orelse continue;
                const b = lr.read(sp.offset, sp.len) orelse continue;
                break :blk .{ .inline_bytes = try allocator.dupe(u8, b) };
            },
            .blob_ref => |oid| .{ .blob_oid = oid },
            .git_blob => |goid| .{ .git_oid = goid },
        };
        if (try map.fetchPut(allocator, kv.key_ptr.*, val)) |prev| {
            var pv = prev.value;
            pv.deinit(allocator);
        }
    }

    var blob_list: std.ArrayList(id.Oid) = .empty;
    defer blob_list.deinit(allocator);
    var blob_idx_map: std.AutoHashMapUnmanaged(id.Oid, u32) = .empty;
    defer blob_idx_map.deinit(allocator);

    var git_list: std.ArrayList(git_dirs.GitOid) = .empty;
    defer git_list.deinit(allocator);
    var git_idx_map: std.HashMapUnmanaged(git_dirs.GitOid, u32, git_dirs.GitOid.hashContext, 80) = .empty;
    defer git_idx_map.deinit(allocator);

    var arena: std.ArrayList(u8) = .empty;
    defer arena.deinit(allocator);

    var entries: std.ArrayList(DiskInsertionEntry) = .empty;
    defer entries.deinit(allocator);

    var mit = map.iterator();
    while (mit.next()) |kv| {
        const k = kv.key_ptr.*;
        const aidx = try actors.intern(allocator, k.op.actor);
        switch (kv.value_ptr.*) {
            .inline_bytes => |b| {
                const off: u64 = arena.items.len;
                try arena.appendSlice(allocator, b);
                try entries.append(allocator, .{
                    .ts = k.op.ts,
                    .actor_idx = aidx,
                    .part = k.part,
                    .kind = INS_KIND_INLINE,
                    .len = @intCast(b.len),
                    .payload_ref = off,
                });
            },
            .blob_oid => |oid| {
                const bidx = if (blob_idx_map.get(oid)) |bi| bi else blk: {
                    const bi: u32 = @intCast(blob_list.items.len);
                    try blob_list.append(allocator, oid);
                    try blob_idx_map.put(allocator, oid, bi);
                    break :blk bi;
                };
                try entries.append(allocator, .{
                    .ts = k.op.ts,
                    .actor_idx = aidx,
                    .part = k.part,
                    .kind = INS_KIND_BLOB,
                    .len = 32,
                    .payload_ref = bidx,
                });
            },
            .git_oid => |goid| {
                const gidx = if (git_idx_map.get(goid)) |gi| gi else blk: {
                    const gi: u32 = @intCast(git_list.items.len);
                    try git_list.append(allocator, goid);
                    try git_idx_map.put(allocator, goid, gi);
                    break :blk gi;
                };
                try entries.append(allocator, .{
                    .ts = k.op.ts,
                    .actor_idx = aidx,
                    .part = k.part,
                    .kind = INS_KIND_GIT,
                    .len = goid.len,
                    .payload_ref = gidx,
                });
            },
        }
    }

    std.mem.sort(DiskInsertionEntry, entries.items, {}, struct {
        fn lt(_: void, a: DiskInsertionEntry, b: DiskInsertionEntry) bool {
            if (a.ts != b.ts) return a.ts < b.ts;
            if (a.actor_idx != b.actor_idx) return a.actor_idx < b.actor_idx;
            return a.part < b.part;
        }
    }.lt);

    var hdr: [24]u8 = @splat(0);
    std.mem.writeInt(u32, hdr[0..4], @intCast(entries.items.len), .little);
    std.mem.writeInt(u32, hdr[4..8], @intCast(blob_list.items.len), .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(git_list.items.len), .little);
    std.mem.writeInt(u64, hdr[16..24], arena.items.len, .little);
    try out.appendSlice(allocator, &hdr);

    for (entries.items) |e| {
        var b: [32]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], e.ts, .little);
        std.mem.writeInt(u32, b[8..12], e.actor_idx, .little);
        std.mem.writeInt(u32, b[12..16], e.part, .little);
        b[16] = e.kind;
        std.mem.writeInt(u32, b[20..24], e.len, .little);
        std.mem.writeInt(u64, b[24..32], e.payload_ref, .little);
        try out.appendSlice(allocator, &b);
    }
    for (blob_list.items) |oid| try out.appendSlice(allocator, &oid);
    for (git_list.items) |goid| {
        var gb: [36]u8 = @splat(0);
        gb[0] = goid.len;
        @memcpy(gb[1..33], &goid.bytes);
        try out.appendSlice(allocator, &gb);
    }
    try out.appendSlice(allocator, arena.items);
    return entries.items.len;
}

fn buildMetaScopesSection(
    allocator: Allocator,
    h: *const history_mod.History,
    meta_scopes: MetaScopesInput,
    actors: *ActorInterner,
    out: *std.ArrayList(u8),
) Allocator.Error!u64 {
    var w = codec.Writer{};
    defer w.deinit(allocator);
    try w.writeVarint(allocator, h.meta.count());
    var mit = h.meta.iterator();
    while (mit.next()) |kv| {
        try w.writeBytes(allocator, kv.key_ptr.*);
        try w.writeVarint(allocator, kv.value_ptr.entries.items.len);
        for (kv.value_ptr.entries.items) |e| {
            try w.writeVarint(allocator, e.op.ts);
            try w.writeVarint(allocator, try actors.intern(allocator, e.op.actor));
            try w.writeOptBytes(allocator, e.value);
        }
    }
    try w.writeBytes(allocator, meta_scopes.scopes_blob);
    try w.writeVarint(allocator, meta_scopes.retained_versions.len);
    for (meta_scopes.retained_versions) |*rv| {
        try rv.encode(allocator, &w);
    }
    try meta_scopes.synced_version.encode(allocator, &w);
    try w.writeOptBytes(allocator, meta_scopes.git_head);
    try out.appendSlice(allocator, w.items());
    return 1;
}

fn freeSlottedRecords(allocator: Allocator, list: *std.ArrayList(SlottedRecord)) void {
    for (list.items) |r| {
        if (r.key.len > 0) allocator.free(r.key);
        if (r.val.len > 0) allocator.free(r.val);
    }
    list.deinit(allocator);
}

fn sortSlottedRecords(records: []SlottedRecord) void {
    std.mem.sort(SlottedRecord, records, {}, struct {
        fn lt(_: void, a: SlottedRecord, b: SlottedRecord) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
}

const SectionInput = struct {
    kind: u32,
    data: []const u8,
    count: u64,
};

fn finalizeSnapshotFile(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    rel_path: []const u8,
    params: WriteParams,
    is_delta: bool,
    sections_in: []const SectionInput,
    inode_count: u64,
    batch_count: u64,
    node_count: u64,
) !WriteResult {
    var sec_descs: [16]SectionDesc = undefined;
    var cur_off: u64 = std.mem.alignForward(u64, HEADER_SIZE + @as(u64, sections_in.len) * SECTION_DESC_SIZE, 8);
    for (sections_in, 0..) |s, i| {
        sec_descs[i] = .{
            .kind = s.kind,
            .flags = 0,
            .offset = cur_off,
            .len = s.data.len,
            .count = s.count,
        };
        cur_off = std.mem.alignForward(u64, cur_off + s.data.len, 8);
    }
    const file_size = cur_off + TRAILER_SIZE;

    var sec_table_buf: [16 * SECTION_DESC_SIZE]u8 = undefined;
    for (0..sections_in.len) |i| {
        const enc = sec_descs[i].encode();
        @memcpy(sec_table_buf[i * SECTION_DESC_SIZE .. (i + 1) * SECTION_DESC_SIZE], &enc);
    }
    const sec_table_slice = sec_table_buf[0 .. sections_in.len * SECTION_DESC_SIZE];

    var flags: u32 = 0;
    if (is_delta) flags |= FLAG_DELTA;
    if (!params.history.dag.horizon.isEmpty()) flags |= FLAG_HAS_HORIZON;

    const hdr = Header{
        .version = FORMAT_VERSION,
        .flags = flags,
        .history_id = params.history.history_id,
        .generation = params.generation,
        .base_generation = params.base_generation,
        .wal_cutoff_seq = params.wal_cutoff_seq,
        .max_ts = params.history.dag.max_ts,
        .next_batch_idx = params.history.dag.next_batch_idx,
        .section_count = @intCast(sections_in.len),
        .file_size = file_size,
        .created_ms = params.created_ms,
        .page_size = PAGE_SIZE,
        .section_table_off = HEADER_SIZE,
    };
    const hdr_bytes = hdr.encode(sec_table_slice);

    const file_buf = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(file_buf);
    @memset(file_buf, 0);
    @memcpy(file_buf[0..HEADER_SIZE], &hdr_bytes);
    @memcpy(file_buf[HEADER_SIZE .. HEADER_SIZE + sec_table_slice.len], sec_table_slice);
    for (sections_in, 0..) |s, i| {
        if (s.data.len > 0) {
            const off: usize = @intCast(sec_descs[i].offset);
            @memcpy(file_buf[off .. off + s.data.len], s.data);
        }
    }
    const body = file_buf[0..@intCast(file_size - TRAILER_SIZE)];
    const file_blake3 = crypto.hashBytes(body);
    @memcpy(file_buf[@intCast(file_size - TRAILER_SIZE)..], &file_blake3);

    try mmap.atomicWriteFile(io, dir, rel_path, file_buf);
    return .{
        .file_size = file_size,
        .file_blake3 = file_blake3,
        .inode_count = inode_count,
        .batch_count = batch_count,
        .text_node_count = node_count,
    };
}

pub const SnapshotWriter = struct {
    pub fn writeDelta(
        allocator: Allocator,
        io: Io,
        dir: Io.Dir,
        rel_path: []const u8,
        params: WriteParams,
    ) !WriteResult {
        const h = params.history;
        var actors = ActorInterner{};
        defer actors.deinit(allocator);

        var node_writer = TextNodeWriter{
            .allocator = allocator,
            .is_delta = true,
            .old_stack = params.stack,
            .actors = &actors,
        };
        defer node_writer.deinit();

        var dirty_inodes: std.AutoHashMapUnmanaged(id.InodeId, *tree_mod.Inode) = .empty;
        var owned_loaded: std.ArrayList(*tree_mod.Inode) = .empty;
        defer {
            for (owned_loaded.items) |in| {
                in.deinit(allocator);
                allocator.destroy(in);
            }
            owned_loaded.deinit(allocator);
            dirty_inodes.deinit(allocator);
        }

        if (params.stack) |st| {
            if (st.delta) |d| {
                if (SlottedView.init(d.inodes_sec)) |sv| {
                    const ns = st.nodeSource();
                    for (0..sv.page_count) |pidx| {
                        const page = sv.verifyAndGetPage(pidx) orelse continue;
                        const cnt = SlottedView.pageRecordCount(page);
                        for (0..cnt) |j| {
                            const rec = SlottedView.pageRecord(page, j) orelse continue;
                            if (rec.key.len != INODE_KEY_LEN) continue;
                            const iid = decodeInodeKey(@ptrCast(rec.key[0..INODE_KEY_LEN].ptr));
                            if (h.tree.inodes.contains(iid)) continue;
                            const loaded = (d.decodeInodeRecord(allocator, iid, rec.val, ns) catch continue);
                            try owned_loaded.append(allocator, loaded);
                            try dirty_inodes.put(allocator, iid, loaded);
                        }
                    }
                }
            }
        }
        var rit = h.tree.inodes.iterator();
        while (rit.next()) |kv| {
            try dirty_inodes.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
        }

        var inode_recs: std.ArrayList(SlottedRecord) = .empty;
        defer freeSlottedRecords(allocator, &inode_recs);
        var dit = dirty_inodes.iterator();
        while (dit.next()) |kv| {
            var w = codec.Writer{};
            defer w.deinit(allocator);
            const mts = try encodeInodePayload(allocator, kv.value_ptr.*, &actors, &node_writer, &w);
            const k = try allocator.dupe(u8, &encodeInodeKey(kv.key_ptr.*));
            errdefer allocator.free(k);
            const v = try allocator.dupe(u8, w.items());
            errdefer allocator.free(v);
            try inode_recs.append(allocator, .{ .key = k, .val = v, .max_ts = mts });
        }
        sortSlottedRecords(inode_recs.items);

        var child_edges: std.AutoHashMapUnmanaged([INODE_KEY_LEN * 2]u8, void) = .empty;
        defer child_edges.deinit(allocator);
        if (params.stack) |st| {
            if (st.delta) |d| {
                if (SlottedView.init(d.dir_children_sec)) |sv| {
                    for (0..sv.page_count) |pidx| {
                        const page = sv.verifyAndGetPage(pidx) orelse continue;
                        const cnt = SlottedView.pageRecordCount(page);
                        for (0..cnt) |j| {
                            const rec = SlottedView.pageRecord(page, j) orelse continue;
                            if (rec.key.len != INODE_KEY_LEN * 2) continue;
                            try child_edges.put(allocator, rec.key[0 .. INODE_KEY_LEN * 2].*, {});
                        }
                    }
                }
            }
        }
        var cit = h.tree.children.iterator();
        while (cit.next()) |kv| {
            for (kv.value_ptr.keys()) |cid| {
                try child_edges.put(allocator, encodeDirChildKey(kv.key_ptr.*, cid), {});
            }
        }
        var child_recs: std.ArrayList(SlottedRecord) = .empty;
        defer freeSlottedRecords(allocator, &child_recs);
        var ce_it = child_edges.keyIterator();
        while (ce_it.next()) |k| {
            try child_recs.append(allocator, .{
                .key = try allocator.dupe(u8, k),
                .val = &.{},
            });
        }
        sortSlottedRecords(child_recs.items);

        var name_map: std.StringHashMapUnmanaged([INODE_KEY_LEN + 2]u8) = .empty;
        defer {
            var nmit = name_map.keyIterator();
            while (nmit.next()) |k| allocator.free(k.*);
            name_map.deinit(allocator);
        }
        if (params.stack) |st| {
            if (st.delta) |d| {
                if (SlottedView.init(d.dir_name_sec)) |sv| {
                    for (0..sv.page_count) |pidx| {
                        const page = sv.verifyAndGetPage(pidx) orelse continue;
                        const cnt = SlottedView.pageRecordCount(page);
                        for (0..cnt) |j| {
                            const rec = SlottedView.pageRecord(page, j) orelse continue;
                            if (rec.val.len < INODE_KEY_LEN + 2) continue;
                            const kcopy = try allocator.dupe(u8, rec.key);
                            if (try name_map.fetchPut(allocator, kcopy, rec.val[0 .. INODE_KEY_LEN + 2].*)) |prev| {
                                allocator.free(prev.key);
                            }
                        }
                    }
                }
            }
        }

        var affected_dirs: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer affected_dirs.deinit(allocator);
        var ddir_it = h.tree.dirty_dirs.keyIterator();
        while (ddir_it.next()) |dk| try affected_dirs.put(allocator, dk.*, {});
        var din_it = h.tree.inodes.valueIterator();
        while (din_it.next()) |in_ptr| {
            for (in_ptr.*.placement.entries.items) |pe| {
                try affected_dirs.put(allocator, pe.value.parent, {});
            }
        }
        var ad_it = affected_dirs.keyIterator();
        while (ad_it.next()) |dir_id| {
            try buildDirNameEntriesForDir(allocator, &h.tree, params.stack, dir_id.*, true, &name_map);
        }

        var name_recs: std.ArrayList(SlottedRecord) = .empty;
        defer freeSlottedRecords(allocator, &name_recs);
        var nm_it = name_map.iterator();
        while (nm_it.next()) |kv| {
            try name_recs.append(allocator, .{
                .key = try allocator.dupe(u8, kv.key_ptr.*),
                .val = try allocator.dupe(u8, kv.value_ptr),
            });
        }
        sortSlottedRecords(name_recs.items);

        var sec_inodes: std.ArrayList(u8) = .empty;
        defer sec_inodes.deinit(allocator);
        const inode_cnt = try writeSlottedSection(allocator, inode_recs.items, &sec_inodes);

        var sec_dir_name: std.ArrayList(u8) = .empty;
        defer sec_dir_name.deinit(allocator);
        const dir_name_cnt = try writeSlottedSection(allocator, name_recs.items, &sec_dir_name);

        var sec_dir_children: std.ArrayList(u8) = .empty;
        defer sec_dir_children.deinit(allocator);
        const dir_child_cnt = try writeSlottedSection(allocator, child_recs.items, &sec_dir_children);

        var sec_dag: std.ArrayList(u8) = .empty;
        defer sec_dag.deinit(allocator);
        const batch_cnt = try buildDagSection(allocator, h, params.stack, true, params.pruned_batches, &actors, &sec_dag);

        var sec_text: std.ArrayList(u8) = .empty;
        defer sec_text.deinit(allocator);
        const node_cnt = try node_writer.writeSection(&sec_text);

        var sec_ins: std.ArrayList(u8) = .empty;
        defer sec_ins.deinit(allocator);
        const ins_cnt = try buildInsertionsSection(allocator, h, params.stack, true, null, &actors, &sec_ins);

        var sec_meta: std.ArrayList(u8) = .empty;
        defer sec_meta.deinit(allocator);
        const meta_cnt = try buildMetaScopesSection(allocator, h, params.meta_scopes, &actors, &sec_meta);

        var sec_actors: std.ArrayList(u8) = .empty;
        defer sec_actors.deinit(allocator);
        const actor_cnt = try actors.writeSection(allocator, &sec_actors);

        const sections = [_]SectionInput{
            .{ .kind = SEC_ACTORS, .data = sec_actors.items, .count = actor_cnt },
            .{ .kind = SEC_DAG, .data = sec_dag.items, .count = batch_cnt },
            .{ .kind = SEC_INODES, .data = sec_inodes.items, .count = inode_cnt },
            .{ .kind = SEC_DIR_NAME_IDX, .data = sec_dir_name.items, .count = dir_name_cnt },
            .{ .kind = SEC_DIR_CHILDREN, .data = sec_dir_children.items, .count = dir_child_cnt },
            .{ .kind = SEC_TEXT_NODES, .data = sec_text.items, .count = node_cnt },
            .{ .kind = SEC_INSERTIONS, .data = sec_ins.items, .count = ins_cnt },
            .{ .kind = SEC_META_SCOPES, .data = sec_meta.items, .count = meta_cnt },
        };
        return try finalizeSnapshotFile(allocator, io, dir, rel_path, params, true, &sections, inode_cnt, batch_cnt, node_cnt);
    }

    pub fn writeCompactedBase(
        allocator: Allocator,
        io: Io,
        dir: Io.Dir,
        rel_path: []const u8,
        params: WriteParams,
    ) !WriteResult {
        const h = params.history;
        var actors = ActorInterner{};
        defer actors.deinit(allocator);

        var live_insertions: std.AutoHashMapUnmanaged(id.InsertionKey, void) = .empty;
        defer live_insertions.deinit(allocator);

        var node_writer = TextNodeWriter{
            .allocator = allocator,
            .is_delta = false,
            .old_stack = params.stack,
            .actors = &actors,
            .live_insertions = &live_insertions,
            .dag = &h.dag,
            .pruned_batches = params.pruned_batches,
        };
        defer node_writer.deinit();

        var all_inode_ids: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer all_inode_ids.deinit(allocator);

        if (params.stack) |st| {
            const readers = [_]?*SnapshotReader{ st.base, st.delta };
            for (readers) |r_opt| {
                const reader = r_opt orelse continue;
                if (SlottedView.init(reader.inodes_sec)) |sv| {
                    for (0..sv.page_count) |pidx| {
                        const page = sv.verifyAndGetPage(pidx) orelse continue;
                        const cnt = SlottedView.pageRecordCount(page);
                        for (0..cnt) |j| {
                            const rec = SlottedView.pageRecord(page, j) orelse continue;
                            if (rec.key.len != INODE_KEY_LEN) continue;
                            const iid = decodeInodeKey(@ptrCast(rec.key[0..INODE_KEY_LEN].ptr));
                            try all_inode_ids.put(allocator, iid, {});
                        }
                    }
                }
            }
        }
        var rit = h.tree.inodes.keyIterator();
        while (rit.next()) |k| try all_inode_ids.put(allocator, k.*, {});

        var inode_recs: std.ArrayList(SlottedRecord) = .empty;
        defer freeSlottedRecords(allocator, &inode_recs);
        var all_dirs: std.AutoHashMapUnmanaged(id.InodeId, void) = .empty;
        defer all_dirs.deinit(allocator);
        try all_dirs.put(allocator, id.InodeId.ROOT, {});

        var child_edges: std.AutoHashMapUnmanaged([INODE_KEY_LEN * 2]u8, void) = .empty;
        defer child_edges.deinit(allocator);

        var id_it = all_inode_ids.keyIterator();
        while (id_it.next()) |iid_ptr| {
            const iid = iid_ptr.*;
            var loaded_owned: ?*tree_mod.Inode = null;
            defer if (loaded_owned) |lo| {
                lo.deinit(allocator);
                allocator.destroy(lo);
            };
            const inode: *const tree_mod.Inode = if (h.tree.inodes.get(iid)) |ptr| ptr else blk: {
                const st = params.stack orelse continue;
                const loaded = (try st.inodeSource().loadInode(allocator, iid)) orelse continue;
                loaded_owned = loaded;
                break :blk loaded;
            };
            if (inode.isDir()) try all_dirs.put(allocator, iid, {});
            for (inode.placement.entries.items) |pe| {
                try child_edges.put(allocator, encodeDirChildKey(pe.value.parent, iid), {});
                try all_dirs.put(allocator, pe.value.parent, {});
            }

            var w = codec.Writer{};
            defer w.deinit(allocator);
            const mts = try encodeInodePayload(allocator, inode, &actors, &node_writer, &w);
            const k = try allocator.dupe(u8, &encodeInodeKey(iid));
            errdefer allocator.free(k);
            const v = try allocator.dupe(u8, w.items());
            errdefer allocator.free(v);
            try inode_recs.append(allocator, .{ .key = k, .val = v, .max_ts = mts });
        }
        sortSlottedRecords(inode_recs.items);

        var child_recs: std.ArrayList(SlottedRecord) = .empty;
        defer freeSlottedRecords(allocator, &child_recs);
        var ce_it = child_edges.keyIterator();
        while (ce_it.next()) |k| {
            try child_recs.append(allocator, .{
                .key = try allocator.dupe(u8, k),
                .val = &.{},
            });
        }
        sortSlottedRecords(child_recs.items);

        var name_map: std.StringHashMapUnmanaged([INODE_KEY_LEN + 2]u8) = .empty;
        defer {
            var nmit = name_map.keyIterator();
            while (nmit.next()) |k| allocator.free(k.*);
            name_map.deinit(allocator);
        }
        var dir_it = all_dirs.keyIterator();
        while (dir_it.next()) |dir_id| {
            try buildDirNameEntriesForDir(allocator, &h.tree, params.stack, dir_id.*, false, &name_map);
        }
        var name_recs: std.ArrayList(SlottedRecord) = .empty;
        defer freeSlottedRecords(allocator, &name_recs);
        var nm_it = name_map.iterator();
        while (nm_it.next()) |kv| {
            try name_recs.append(allocator, .{
                .key = try allocator.dupe(u8, kv.key_ptr.*),
                .val = try allocator.dupe(u8, kv.value_ptr),
            });
        }
        sortSlottedRecords(name_recs.items);

        var sec_inodes: std.ArrayList(u8) = .empty;
        defer sec_inodes.deinit(allocator);
        const inode_cnt = try writeSlottedSection(allocator, inode_recs.items, &sec_inodes);

        var sec_dir_name: std.ArrayList(u8) = .empty;
        defer sec_dir_name.deinit(allocator);
        const dir_name_cnt = try writeSlottedSection(allocator, name_recs.items, &sec_dir_name);

        var sec_dir_children: std.ArrayList(u8) = .empty;
        defer sec_dir_children.deinit(allocator);
        const dir_child_cnt = try writeSlottedSection(allocator, child_recs.items, &sec_dir_children);

        var sec_dag: std.ArrayList(u8) = .empty;
        defer sec_dag.deinit(allocator);
        const batch_cnt = try buildDagSection(allocator, h, params.stack, false, params.pruned_batches, &actors, &sec_dag);

        var sec_text: std.ArrayList(u8) = .empty;
        defer sec_text.deinit(allocator);
        const node_cnt = try node_writer.writeSection(&sec_text);

        var sec_ins: std.ArrayList(u8) = .empty;
        defer sec_ins.deinit(allocator);
        const ins_cnt = try buildInsertionsSection(allocator, h, params.stack, false, &live_insertions, &actors, &sec_ins);

        var sec_meta: std.ArrayList(u8) = .empty;
        defer sec_meta.deinit(allocator);
        const meta_cnt = try buildMetaScopesSection(allocator, h, params.meta_scopes, &actors, &sec_meta);

        var sec_actors: std.ArrayList(u8) = .empty;
        defer sec_actors.deinit(allocator);
        const actor_cnt = try actors.writeSection(allocator, &sec_actors);

        const sections = [_]SectionInput{
            .{ .kind = SEC_ACTORS, .data = sec_actors.items, .count = actor_cnt },
            .{ .kind = SEC_DAG, .data = sec_dag.items, .count = batch_cnt },
            .{ .kind = SEC_INODES, .data = sec_inodes.items, .count = inode_cnt },
            .{ .kind = SEC_DIR_NAME_IDX, .data = sec_dir_name.items, .count = dir_name_cnt },
            .{ .kind = SEC_DIR_CHILDREN, .data = sec_dir_children.items, .count = dir_child_cnt },
            .{ .kind = SEC_TEXT_NODES, .data = sec_text.items, .count = node_cnt },
            .{ .kind = SEC_INSERTIONS, .data = sec_ins.items, .count = ins_cnt },
            .{ .kind = SEC_META_SCOPES, .data = sec_meta.items, .count = meta_cnt },
        };
        return try finalizeSnapshotFile(allocator, io, dir, rel_path, params, false, &sections, inode_cnt, batch_cnt, node_cnt);
    }
};

fn buildDirNameEntriesForDir(
    allocator: Allocator,
    t: *const tree_mod.Tree,
    old_stack: ?*const SnapshotStack,
    dir: id.InodeId,
    emit_tombstones: bool,
    out_map: *std.StringHashMapUnmanaged([INODE_KEY_LEN + 2]u8),
) Allocator.Error!void {
    t.beginPinScope();
    defer t.endPinScope();
    var entries = try t.listDir(allocator, text_mod.View.EVERYTHING, dir);
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    var present_raw_counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer present_raw_counts.deinit(allocator);

    var live_names: std.StringHashMapUnmanaged(void) = .empty;
    defer live_names.deinit(allocator);

    for (entries.items) |e| {
        try live_names.put(allocator, e.name, {});
        const pe = try t.placementIn(allocator, text_mod.View.EVERYTHING, e.inode_id) orelse continue;
        const gop = try present_raw_counts.getOrPut(allocator, pe.value.name);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }

    for (entries.items) |e| {
        const key = try encodeDirNameKey(allocator, dir, e.name);
        errdefer allocator.free(key);
        const child_inode = t.get(e.inode_id);
        const ktag: u8 = if (child_inode) |ci| switch (ci.kind) {
            .dir => 0,
            .file => 1,
            .symlink => 2,
        } else 1;
        var flags: u8 = 0;
        if (present_raw_counts.get(e.name)) |cnt| {
            if (cnt > 1) flags |= tree_mod.DIR_NAME_FLAG_CONFLICT;
        }
        var val: [INODE_KEY_LEN + 2]u8 = undefined;
        const ck = encodeInodeKey(e.inode_id);
        @memcpy(val[0..INODE_KEY_LEN], &ck);
        val[INODE_KEY_LEN] = ktag;
        val[INODE_KEY_LEN + 1] = flags;
        if (try out_map.fetchPut(allocator, key, val)) |prev| {
            allocator.free(prev.key);
        }
    }

    if (emit_tombstones) {
        if (old_stack) |st| {
            if (st.base) |b| {
                if (SlottedView.init(b.dir_name_sec)) |sv| {
                    const dir_prefix = encodeInodeKey(dir);
                    var min_k: [INODE_KEY_LEN + 8]u8 = @splat(0);
                    @memcpy(min_k[0..INODE_KEY_LEN], &dir_prefix);
                    var pidx: usize = sv.findPageForKey(&min_k) orelse 0;
                    while (pidx < sv.page_count) : (pidx += 1) {
                        const page = sv.verifyAndGetPage(pidx) orelse break;
                        const cnt = SlottedView.pageRecordCount(page);
                        var past = false;
                        for (0..cnt) |j| {
                            const rec = SlottedView.pageRecord(page, j) orelse break;
                            if (rec.key.len < INODE_KEY_LEN + 8) continue;
                            const ord = std.mem.order(u8, rec.key[0..INODE_KEY_LEN], &dir_prefix);
                            if (ord == .lt) continue;
                            if (ord == .gt) {
                                past = true;
                                break;
                            }
                            const old_name = rec.key[INODE_KEY_LEN + 8 ..];
                            if (!live_names.contains(old_name)) {
                                const tk = try allocator.dupe(u8, rec.key);
                                var tval: [INODE_KEY_LEN + 2]u8 = @splat(0);
                                tval[INODE_KEY_LEN + 1] = tree_mod.DIR_NAME_FLAG_TOMBSTONE;
                                if (try out_map.fetchPut(allocator, tk, tval)) |prev| {
                                    allocator.free(prev.key);
                                }
                            }
                        }
                        if (past) break;
                    }
                }
            }
        }
    }
}
