const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const crypto = @import("crypto.zig");
const mmap = @import("mmap.zig");

pub const MAGIC: [8]u8 = .{ '0', 'N', 'D', 'B', 'M', 'N', 'F', '1' };
pub const FORMAT_VERSION: u32 = 1;
pub const FILE_SIZE: usize = 256;
pub const FILE_NAME: []const u8 = "manifest.0ndb";

pub const FLAG_PRUNED_BEFORE_SYNC: u32 = 1 << 0;
pub const FLAG_EVER_SYNCED: u32 = 1 << 1;
pub const FLAG_HAS_HORIZON: u32 = 1 << 2;

pub const Manifest = struct {
    flags: u32 = 0,
    history_id: u128 = 0,
    generation: u64 = 0,
    base_gen: u64 = 0,
    delta_gen: u64 = 0,
    wal_gen: u64 = 0,
    wal_base_seq: u64 = 0,
    pack_max_id: u32 = 0,
    seg_max_id: u32 = 0,
    checkpoint_wall_ms: u64 = 0,
    total_inodes: u64 = 0,
    total_batches: u64 = 0,
    base_blake3: [32]u8 = @splat(0),
    delta_blake3: [32]u8 = @splat(0),
    pack_idx_blake3: [32]u8 = @splat(0),
    manifest_blake3: [32]u8 = @splat(0),

    pub fn encode(self: Manifest) [FILE_SIZE]u8 {
        var buf: [FILE_SIZE]u8 = @splat(0);
        @memcpy(buf[0..8], &MAGIC);
        std.mem.writeInt(u32, buf[8..12], FORMAT_VERSION, .little);
        std.mem.writeInt(u32, buf[12..16], self.flags, .little);
        std.mem.writeInt(u128, buf[16..32], self.history_id, .little);
        std.mem.writeInt(u64, buf[32..40], self.generation, .little);
        std.mem.writeInt(u64, buf[40..48], self.base_gen, .little);
        std.mem.writeInt(u64, buf[48..56], self.delta_gen, .little);
        std.mem.writeInt(u64, buf[56..64], self.wal_gen, .little);
        std.mem.writeInt(u64, buf[64..72], self.wal_base_seq, .little);
        std.mem.writeInt(u32, buf[72..76], self.pack_max_id, .little);
        std.mem.writeInt(u32, buf[76..80], self.seg_max_id, .little);
        std.mem.writeInt(u64, buf[80..88], self.checkpoint_wall_ms, .little);
        std.mem.writeInt(u64, buf[88..96], self.total_inodes, .little);
        std.mem.writeInt(u64, buf[96..104], self.total_batches, .little);
        @memcpy(buf[128..160], &self.base_blake3);
        @memcpy(buf[160..192], &self.delta_blake3);
        @memcpy(buf[192..224], &self.pack_idx_blake3);
        const digest = crypto.hashBytes(buf[0..224]);
        @memcpy(buf[224..256], &digest);
        return buf;
    }

    pub fn decode(bytes: *const [FILE_SIZE]u8) !Manifest {
        if (!std.mem.eql(u8, bytes[0..8], &MAGIC)) return error.InvalidMagic;
        const version = std.mem.readInt(u32, bytes[8..12], .little);
        if (version != FORMAT_VERSION) return error.UnsupportedVersion;
        const expected = crypto.hashBytes(bytes[0..224]);
        if (!std.mem.eql(u8, &expected, bytes[224..256])) return error.CorruptManifest;

        return .{
            .flags = std.mem.readInt(u32, bytes[12..16], .little),
            .history_id = std.mem.readInt(u128, bytes[16..32], .little),
            .generation = std.mem.readInt(u64, bytes[32..40], .little),
            .base_gen = std.mem.readInt(u64, bytes[40..48], .little),
            .delta_gen = std.mem.readInt(u64, bytes[48..56], .little),
            .wal_gen = std.mem.readInt(u64, bytes[56..64], .little),
            .wal_base_seq = std.mem.readInt(u64, bytes[64..72], .little),
            .pack_max_id = std.mem.readInt(u32, bytes[72..76], .little),
            .seg_max_id = std.mem.readInt(u32, bytes[76..80], .little),
            .checkpoint_wall_ms = std.mem.readInt(u64, bytes[80..88], .little),
            .total_inodes = std.mem.readInt(u64, bytes[88..96], .little),
            .total_batches = std.mem.readInt(u64, bytes[96..104], .little),
            .base_blake3 = bytes[128..160].*,
            .delta_blake3 = bytes[160..192].*,
            .pack_idx_blake3 = bytes[192..224].*,
            .manifest_blake3 = expected,
        };
    }

    pub fn load(io: Io, state_dir: Io.Dir) !?Manifest {
        const file = state_dir.openFile(io, FILE_NAME, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);

        const st = try file.stat(io);
        if (st.size != FILE_SIZE) return error.CorruptManifest;

        var buf: [FILE_SIZE]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        if (n != FILE_SIZE) return error.CorruptManifest;
        return try decode(&buf);
    }

    pub fn saveAtomic(self: Manifest, io: Io, state_dir: Io.Dir) !void {
        const encoded = self.encode();
        try mmap.atomicWriteFile(io, state_dir, FILE_NAME, &encoded);
    }

    pub fn gcOrphanFiles(allocator: Allocator, io: Io, state_dir: Io.Dir, active: Manifest) void {
        gcTempFilesInDir(allocator, io, state_dir, "tmp.manifest.0ndb.");
        gcSnapDir(allocator, io, state_dir, active.base_gen, active.delta_gen);
        gcWalDir(allocator, io, state_dir, active.wal_gen);
    }
};

pub fn baseSnapFileName(gen: u64, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "base-{x:016}.0ndb", .{gen}) catch unreachable;
}

pub fn deltaSnapFileName(gen: u64, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "delta-{x:016}.0ndb", .{gen}) catch unreachable;
}

pub fn walFileName(gen: u64, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "wal-{x:016}.0ndb", .{gen}) catch unreachable;
}

fn matchesGenStem(name: []const u8, prefix: []const u8, active_gen: u64) bool {
    if (active_gen == 0) return false;
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    const stem = if (std.mem.indexOfScalar(u8, rest, '.')) |dot| rest[0..dot] else rest;
    if (stem.len == 0) return false;

    var h16_buf: [16]u8 = undefined;
    const h16 = std.fmt.bufPrint(&h16_buf, "{x:016}", .{active_gen}) catch unreachable;
    if (std.mem.eql(u8, stem, h16)) return true;

    var h8_buf: [16]u8 = undefined;
    const h8 = std.fmt.bufPrint(&h8_buf, "{x:08}", .{active_gen}) catch unreachable;
    if (std.mem.eql(u8, stem, h8)) return true;

    var dec_buf: [24]u8 = undefined;
    const dec = std.fmt.bufPrint(&dec_buf, "{d}", .{active_gen}) catch unreachable;
    if (std.mem.eql(u8, stem, dec)) return true;

    return false;
}

fn gcTempFilesInDir(allocator: Allocator, io: Io, dir: Io.Dir, prefix: []const u8) void {
    var iter_dir = dir.openDir(io, ".", .{ .iterate = true }) catch return;
    defer iter_dir.close(io);

    var to_delete: std.ArrayList([]u8) = .empty;
    defer {
        for (to_delete.items) |p| allocator.free(p);
        to_delete.deinit(allocator);
    }

    var it = iter_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            const duped = allocator.dupe(u8, entry.name) catch continue;
            to_delete.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    if (to_delete.items.len == 0) return;
    for (to_delete.items) |name| {
        iter_dir.deleteFile(io, name) catch {};
    }
    mmap.fsyncDir(io, iter_dir) catch {};
}

fn gcSnapDir(allocator: Allocator, io: Io, state_dir: Io.Dir, active_base_gen: u64, active_delta_gen: u64) void {
    var snap_dir = state_dir.openDir(io, "snap", .{ .iterate = true }) catch return;
    defer snap_dir.close(io);

    var to_delete: std.ArrayList([]u8) = .empty;
    defer {
        for (to_delete.items) |p| allocator.free(p);
        to_delete.deinit(allocator);
    }

    var it = snap_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var should_delete = false;
        if (std.mem.startsWith(u8, entry.name, "tmp.")) {
            should_delete = true;
        } else if (std.mem.startsWith(u8, entry.name, "base-")) {
            should_delete = !matchesGenStem(entry.name, "base-", active_base_gen);
        } else if (std.mem.startsWith(u8, entry.name, "delta-")) {
            should_delete = !matchesGenStem(entry.name, "delta-", active_delta_gen);
        }
        if (should_delete) {
            const duped = allocator.dupe(u8, entry.name) catch continue;
            to_delete.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    if (to_delete.items.len == 0) return;
    for (to_delete.items) |name| {
        snap_dir.deleteFile(io, name) catch {};
    }
    mmap.fsyncDir(io, snap_dir) catch {};
}

fn gcWalDir(allocator: Allocator, io: Io, state_dir: Io.Dir, active_wal_gen: u64) void {
    var wal_dir = state_dir.openDir(io, "wal", .{ .iterate = true }) catch return;
    defer wal_dir.close(io);

    var to_delete: std.ArrayList([]u8) = .empty;
    defer {
        for (to_delete.items) |p| allocator.free(p);
        to_delete.deinit(allocator);
    }

    var it = wal_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var should_delete = false;
        if (std.mem.startsWith(u8, entry.name, "tmp.")) {
            should_delete = true;
        } else if (std.mem.startsWith(u8, entry.name, "wal-")) {
            should_delete = !matchesGenStem(entry.name, "wal-", active_wal_gen);
        }
        if (should_delete) {
            const duped = allocator.dupe(u8, entry.name) catch continue;
            to_delete.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    if (to_delete.items.len == 0) return;
    for (to_delete.items) |name| {
        wal_dir.deleteFile(io, name) catch {};
    }
    mmap.fsyncDir(io, wal_dir) catch {};
}
