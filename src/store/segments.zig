const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const crypto = @import("crypto.zig");
const log = @import("log.zig");
const mmap = @import("mmap.zig");

pub const FrameInput = struct {
    kind: u8,
    flags: u8 = 0,
    aux: u16 = 0,
    seq: u64,
    payload: []const u8,
};

pub const WrittenFrame = struct {
    seg_id: u32,
    offset: u64,
    seq: u64,
    payload_len: u32,
    kind: u8,
    flags: u8,
    aux: u16,
};

pub const FrameRef = struct {
    seg_id: u32,
    offset: u64,
    payload_len: u32,
    seq: u64,
    kind: u8,
    flags: u8,
    aux: u16,
};

pub const RemapEntry = struct {
    old_seg_id: u32,
    old_offset: u64,
    new_seg_id: u32,
    new_offset: u64,
    seq: u64,
    payload_len: u32,
};

pub const PruneResult = struct {
    removed_segments: u32 = 0,
    rewritten_segments: u32 = 0,
    kept_frames: usize = 0,
    removed_frames: usize = 0,
    max_seg_id: u32 = 0,
    remaps: std.ArrayList(RemapEntry) = .empty,
    obsolete_seg_ids: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *PruneResult, allocator: Allocator) void {
        self.remaps.deinit(allocator);
        self.obsolete_seg_ids.deinit(allocator);
    }
};

pub fn segmentFileName(seg_id: u32, buf: *[20]u8) []const u8 {
    return std.fmt.bufPrint(buf, "seg-{x:08}.0ndb", .{seg_id}) catch unreachable;
}

pub fn parseSegmentId(name: []const u8) ?u32 {
    if (name.len != 17) return null;
    if (!std.mem.startsWith(u8, name, "seg-")) return null;
    if (!std.mem.endsWith(u8, name, ".0ndb")) return null;
    return std.fmt.parseInt(u32, name[4..12], 16) catch null;
}

pub const SegmentStore = struct {
    allocator: Allocator,
    io: Io,
    seg_dir: Io.Dir,
    maps: std.AutoHashMapUnmanaged(u32, *mmap.MappedFile),

    pub fn open(allocator: Allocator, io: Io, state_dir: Io.Dir) !SegmentStore {
        try state_dir.createDirPath(io, "seg");
        const seg_dir = try state_dir.openDir(io, "seg", .{ .iterate = true });
        return .{
            .allocator = allocator,
            .io = io,
            .seg_dir = seg_dir,
            .maps = .empty,
        };
    }

    pub fn deinit(self: *SegmentStore) void {
        var it = self.maps.valueIterator();
        while (it.next()) |mf_ptr| {
            mf_ptr.*.release(self.allocator);
        }
        self.maps.deinit(self.allocator);
        self.seg_dir.close(self.io);
    }

    pub fn hibernate(self: *SegmentStore) void {
        var it = self.maps.valueIterator();
        while (it.next()) |mf_ptr| {
            mf_ptr.*.hibernate();
        }
    }

    fn evictMapped(self: *SegmentStore, seg_id: u32) void {
        if (self.maps.fetchRemove(seg_id)) |kv| {
            kv.value.release(self.allocator);
        }
    }

    pub fn getMapped(self: *SegmentStore, seg_id: u32) !*mmap.MappedFile {
        if (self.maps.get(seg_id)) |existing| {
            return existing;
        }
        var name_buf: [20]u8 = undefined;
        const fname = segmentFileName(seg_id, &name_buf);
        const mf = try mmap.MappedFile.open(self.allocator, self.io, self.seg_dir, fname);
        errdefer mf.release(self.allocator);
        try self.maps.put(self.allocator, seg_id, mf);
        return mf;
    }

    pub fn writeSegment(self: *SegmentStore, seg_id: u32, frames: []const FrameInput) ![]WrittenFrame {
        const written = try self.allocator.alloc(WrittenFrame, frames.len);
        errdefer self.allocator.free(written);

        var total_bytes: usize = 0;
        for (frames) |f| {
            total_bytes += log.alignUp(log.HEADER_SIZE + f.payload.len);
        }

        const buf = try self.allocator.alloc(u8, total_bytes);
        defer self.allocator.free(buf);

        var pos: usize = 0;
        for (frames, 0..) |f, i| {
            const h = crypto.hashBytes(f.payload);
            const prefix = std.mem.readInt(u64, h[0..8], .little);
            var hdr = log.FrameHeader{
                .kind = f.kind,
                .flags = f.flags,
                .aux = f.aux,
                .seq = f.seq,
                .payload_len = @intCast(f.payload.len),
                .crc = 0,
                .hash_prefix = prefix,
            };
            var hdr_bytes = hdr.encode();
            hdr.crc = log.frameCrc(&hdr_bytes, f.payload);
            hdr_bytes = hdr.encode();

            const raw_total = log.HEADER_SIZE + f.payload.len;
            const aligned_total = log.alignUp(raw_total);
            const pad_len = aligned_total - raw_total;

            @memcpy(buf[pos .. pos + log.HEADER_SIZE], &hdr_bytes);
            if (f.payload.len > 0) {
                @memcpy(buf[pos + log.HEADER_SIZE .. pos + raw_total], f.payload);
            }
            if (pad_len > 0) {
                @memset(buf[pos + raw_total .. pos + aligned_total], 0);
            }

            written[i] = .{
                .seg_id = seg_id,
                .offset = pos,
                .seq = f.seq,
                .payload_len = @intCast(f.payload.len),
                .kind = f.kind,
                .flags = f.flags,
                .aux = f.aux,
            };
            pos += aligned_total;
        }

        var name_buf: [20]u8 = undefined;
        const fname = segmentFileName(seg_id, &name_buf);
        self.evictMapped(seg_id);
        try mmap.atomicWriteFile(self.io, self.seg_dir, fname, buf);
        return written;
    }

    pub fn sealFromWal(self: *SegmentStore, wal_dir: Io.Dir, wal_rel_path: []const u8, seg_id: u32) ![]WrittenFrame {
        const wal_map = try mmap.MappedFile.open(self.allocator, self.io, wal_dir, wal_rel_path);
        defer wal_map.release(self.allocator);

        const data = wal_map.slice();
        var written: std.ArrayList(WrittenFrame) = .empty;
        errdefer written.deinit(self.allocator);

        var offset: usize = 0;
        while (offset + log.HEADER_SIZE <= data.len) {
            const hdr_ptr: *const [log.HEADER_SIZE]u8 = @ptrCast(data[offset .. offset + log.HEADER_SIZE].ptr);
            const hdr = log.FrameHeader.decode(hdr_ptr) catch break;
            const payload_start = offset + log.HEADER_SIZE;
            const payload_end = std.math.add(usize, payload_start, hdr.payload_len) catch break;
            if (payload_end > data.len) break;
            const payload = data[payload_start..payload_end];
            if (log.frameCrc(hdr_ptr, payload) != hdr.crc) break;
            const h = crypto.hashBytes(payload);
            const actual_prefix = std.mem.readInt(u64, h[0..8], .little);
            if (actual_prefix != hdr.hash_prefix) break;
            const aligned_end = log.alignUp(payload_end);
            if (aligned_end > data.len) break;

            try written.append(self.allocator, .{
                .seg_id = seg_id,
                .offset = offset,
                .seq = hdr.seq,
                .payload_len = hdr.payload_len,
                .kind = hdr.kind,
                .flags = hdr.flags,
                .aux = hdr.aux,
            });
            offset = aligned_end;
        }

        var name_buf: [20]u8 = undefined;
        const fname = segmentFileName(seg_id, &name_buf);
        self.evictMapped(seg_id);
        try mmap.atomicWriteFile(self.io, self.seg_dir, fname, data[0..offset]);
        return try written.toOwnedSlice(self.allocator);
    }

    pub fn readFrameViewAt(self: *SegmentStore, seg_id: u32, offset: u64, expected_len: ?u32) !log.FrameView {
        const mf = try self.getMapped(seg_id);
        const hdr_slice = try mf.sliceCheckedU64(offset, log.HEADER_SIZE);
        const hdr_ptr: *const [log.HEADER_SIZE]u8 = @ptrCast(hdr_slice.ptr);
        const hdr = try log.FrameHeader.decode(hdr_ptr);
        if (expected_len) |exp| {
            if (hdr.payload_len != exp) return error.LengthMismatch;
        }
        const payload_off = std.math.add(u64, offset, log.HEADER_SIZE) catch return error.OutOfBounds;
        const payload = try mf.sliceCheckedU64(payload_off, hdr.payload_len);
        if (log.frameCrc(hdr_ptr, payload) != hdr.crc) return error.CorruptFrame;
        const h = crypto.hashBytes(payload);
        const actual_prefix = std.mem.readInt(u64, h[0..8], .little);
        if (actual_prefix != hdr.hash_prefix) return error.CorruptFrame;
        return .{
            .header = hdr,
            .payload = payload,
        };
    }

    pub fn readFrameAt(self: *SegmentStore, seg_id: u32, offset: u64, len: u32, allocator: Allocator) ![]u8 {
        const view = try self.readFrameViewAt(seg_id, offset, len);
        return try allocator.dupe(u8, view.payload);
    }

    pub fn listSegmentIds(self: *SegmentStore, allocator: Allocator) ![]u32 {
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(allocator);

        var it = self.seg_dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (parseSegmentId(entry.name)) |id| {
                try ids.append(allocator, id);
            }
        }
        std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
        return try ids.toOwnedSlice(allocator);
    }

    fn callKeep(keepFn: anytype, ref: FrameRef) bool {
        const T = @TypeOf(keepFn);
        switch (@typeInfo(T)) {
            .@"fn" => return keepFn(ref),
            .pointer => |p| {
                if (@typeInfo(p.child) == .@"fn") {
                    return keepFn(ref);
                }
                return keepFn.keep(ref);
            },
            .@"struct" => return keepFn.keep(ref),
            else => @compileError("keepFn must be a function or a struct with a keep(FrameRef) bool method"),
        }
    }

    pub fn unlinkSegments(self: *SegmentStore, seg_ids: []const u32) void {
        var deleted_any = false;
        for (seg_ids) |seg_id| {
            self.evictMapped(seg_id);
            var name_buf: [20]u8 = undefined;
            const fname = segmentFileName(seg_id, &name_buf);
            self.seg_dir.deleteFile(self.io, fname) catch {};
            deleted_any = true;
        }
        if (deleted_any) {
            mmap.fsyncDir(self.io, self.seg_dir) catch {};
        }
    }

    pub fn pruneSegments(self: *SegmentStore, keepFn: anytype) !PruneResult {
        const res = try self.pruneSegmentsDeferred(keepFn);
        self.unlinkSegments(res.obsolete_seg_ids.items);
        return res;
    }

    pub fn pruneSegmentsDeferred(self: *SegmentStore, keepFn: anytype) !PruneResult {
        var result = PruneResult{};
        errdefer result.deinit(self.allocator);

        const seg_ids = try self.listSegmentIds(self.allocator);
        defer self.allocator.free(seg_ids);

        var next_seg_id: u32 = if (seg_ids.len > 0) seg_ids[seg_ids.len - 1] + 1 else 1;
        var wrote_any = false;
        var highest_live: u32 = 0;

        const ScannedFrame = struct {
            offset: usize,
            aligned_len: usize,
            seq: u64,
            payload_len: u32,
            keep: bool,
        };

        var scanned: std.ArrayList(ScannedFrame) = .empty;
        defer scanned.deinit(self.allocator);

        for (seg_ids) |seg_id| {
            scanned.clearRetainingCapacity();
            const mf = try self.getMapped(seg_id);
            mf.retain();
            defer mf.release(self.allocator);

            const data = mf.slice();
            var offset: usize = 0;
            var live_count: usize = 0;
            var dead_count: usize = 0;
            var live_bytes: usize = 0;

            while (offset + log.HEADER_SIZE <= data.len) {
                const hdr_ptr: *const [log.HEADER_SIZE]u8 = @ptrCast(data[offset .. offset + log.HEADER_SIZE].ptr);
                const hdr = log.FrameHeader.decode(hdr_ptr) catch break;
                const payload_start = offset + log.HEADER_SIZE;
                const payload_end = std.math.add(usize, payload_start, hdr.payload_len) catch break;
                if (payload_end > data.len) break;
                const aligned_end = log.alignUp(payload_end);
                if (aligned_end > data.len) break;

                const ref = FrameRef{
                    .seg_id = seg_id,
                    .offset = offset,
                    .payload_len = hdr.payload_len,
                    .seq = hdr.seq,
                    .kind = hdr.kind,
                    .flags = hdr.flags,
                    .aux = hdr.aux,
                };
                const keep = callKeep(keepFn, ref);
                try scanned.append(self.allocator, .{
                    .offset = offset,
                    .aligned_len = aligned_end - offset,
                    .seq = hdr.seq,
                    .payload_len = hdr.payload_len,
                    .keep = keep,
                });
                if (keep) {
                    live_count += 1;
                    live_bytes += aligned_end - offset;
                } else {
                    dead_count += 1;
                }
                offset = aligned_end;
            }

            if (dead_count == 0 and live_count > 0) {
                result.kept_frames += live_count;
                if (seg_id > highest_live) highest_live = seg_id;
                continue;
            }

            if (live_count == 0) {
                try result.obsolete_seg_ids.append(self.allocator, seg_id);
                result.removed_segments += 1;
                result.removed_frames += dead_count;
                continue;
            }

            const new_seg_id = next_seg_id;
            next_seg_id += 1;

            const out_buf = try self.allocator.alloc(u8, live_bytes);
            defer self.allocator.free(out_buf);

            var new_off: usize = 0;
            for (scanned.items) |sf| {
                if (!sf.keep) continue;
                @memcpy(out_buf[new_off .. new_off + sf.aligned_len], data[sf.offset .. sf.offset + sf.aligned_len]);
                try result.remaps.append(self.allocator, .{
                    .old_seg_id = seg_id,
                    .old_offset = sf.offset,
                    .new_seg_id = new_seg_id,
                    .new_offset = new_off,
                    .seq = sf.seq,
                    .payload_len = sf.payload_len,
                });
                new_off += sf.aligned_len;
            }

            var new_name_buf: [20]u8 = undefined;
            const new_fname = segmentFileName(new_seg_id, &new_name_buf);
            try mmap.atomicWriteFile(self.io, self.seg_dir, new_fname, out_buf);
            wrote_any = true;

            try result.obsolete_seg_ids.append(self.allocator, seg_id);

            result.rewritten_segments += 1;
            result.kept_frames += live_count;
            result.removed_frames += dead_count;
            if (new_seg_id > highest_live) highest_live = new_seg_id;
        }

        if (wrote_any) {
            try mmap.fsyncDir(self.io, self.seg_dir);
        }
        result.max_seg_id = highest_live;
        return result;
    }
};
