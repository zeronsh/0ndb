const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");
const mmap = @import("mmap.zig");

pub const MAGIC: [4]u8 = .{ '0', 'N', 'D', 'B' };
pub const HEADER_SIZE: usize = 32;
pub const ALIGN: usize = 8;

pub const FrameHeader = struct {
    kind: u8,
    flags: u8,
    aux: u16,
    seq: u64,
    payload_len: u32,
    crc: u32,
    hash_prefix: u64,

    pub fn encode(self: FrameHeader) [HEADER_SIZE]u8 {
        var buf: [HEADER_SIZE]u8 = undefined;
        @memcpy(buf[0..4], &MAGIC);
        buf[4] = self.kind;
        buf[5] = self.flags;
        std.mem.writeInt(u16, buf[6..8], self.aux, .little);
        std.mem.writeInt(u64, buf[8..16], self.seq, .little);
        std.mem.writeInt(u32, buf[16..20], self.payload_len, .little);
        std.mem.writeInt(u32, buf[20..24], self.crc, .little);
        std.mem.writeInt(u64, buf[24..32], self.hash_prefix, .little);
        return buf;
    }

    pub fn decode(bytes: *const [HEADER_SIZE]u8) !FrameHeader {
        if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return error.InvalidMagic;
        return .{
            .kind = bytes[4],
            .flags = bytes[5],
            .aux = std.mem.readInt(u16, bytes[6..8], .little),
            .seq = std.mem.readInt(u64, bytes[8..16], .little),
            .payload_len = std.mem.readInt(u32, bytes[16..20], .little),
            .crc = std.mem.readInt(u32, bytes[20..24], .little),
            .hash_prefix = std.mem.readInt(u64, bytes[24..32], .little),
        };
    }
};

pub const FrameIndexEntry = struct {
    seq: u64,
    offset: u64,
    payload_len: u32,
    kind: u8,
    flags: u8,
    aux: u16,
};

pub const FrameView = struct {
    header: FrameHeader,
    payload: []const u8,
};

pub const AppendResult = struct {
    seq: u64,
    payload_offset: u64,
};

pub const BulkFrame = struct {
    seq: ?u64 = null,
    kind: u8,
    flags: u8 = 0,
    aux: u16 = 0,
    payload: []const u8,
};

pub const OpenOptions = struct {
    durable_sync: bool = true,
    verify_blake3_on_recover: bool = true,
    start_offset: u64 = 0,
};

pub fn alignUp(n: usize) usize {
    return (n + (ALIGN - 1)) & ~(ALIGN - 1);
}

pub fn frameCrc(header_bytes: *const [HEADER_SIZE]u8, payload: []const u8) u32 {
    var c = std.hash.crc.@"CRC-32/ISCSI".init();
    c.update(header_bytes[0..20]);
    c.update(header_bytes[24..32]);
    c.update(payload);
    return c.final();
}

pub const AppendLog = struct {
    allocator: Allocator,
    io: Io,
    file: Io.File,
    write_offset: u64,
    next_seq: u64,
    mapped: ?[]align(std.heap.page_size_min) u8,
    mapped_len: usize,
    retired_maps: std.ArrayList([]align(std.heap.page_size_min) u8),
    index: std.ArrayList(FrameIndexEntry),
    durable_sync: bool,

    pub fn open(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, durable_sync: bool) !AppendLog {
        return openWithOptions(allocator, io, dir, sub_path, .{
            .durable_sync = durable_sync,
            .verify_blake3_on_recover = true,
            .start_offset = 0,
        });
    }

    pub fn openWithoutFullHash(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, durable_sync: bool) !AppendLog {
        return openWithOptions(allocator, io, dir, sub_path, .{
            .durable_sync = durable_sync,
            .verify_blake3_on_recover = false,
            .start_offset = 0,
        });
    }

    pub fn openTailRecover(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, durable_sync: bool, start_offset: u64) !AppendLog {
        return openWithOptions(allocator, io, dir, sub_path, .{
            .durable_sync = durable_sync,
            .verify_blake3_on_recover = false,
            .start_offset = start_offset,
        });
    }

    pub fn openWithOptions(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, opts: OpenOptions) !AppendLog {
        const file = try dir.createFile(io, sub_path, .{
            .read = true,
            .truncate = false,
        });
        var file_owned = true;
        errdefer if (file_owned) file.close(io);

        var self = AppendLog{
            .allocator = allocator,
            .io = io,
            .file = file,
            .write_offset = 0,
            .next_seq = 1,
            .mapped = null,
            .mapped_len = 0,
            .retired_maps = .empty,
            .index = .empty,
            .durable_sync = opts.durable_sync,
        };
        file_owned = false;
        errdefer self.deinit();

        try self.tailRecover(opts.start_offset, opts.verify_blake3_on_recover);
        return self;
    }

    pub fn deinit(self: *AppendLog) void {
        self.unmapAll();
        self.retired_maps.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.file.close(self.io);
    }

    fn unmap(self: *AppendLog) void {
        if (self.mapped) |m| {
            posix.munmap(m);
            self.mapped = null;
            self.mapped_len = 0;
        }
    }

    fn unmapAll(self: *AppendLog) void {
        self.unmap();
        for (self.retired_maps.items) |m| {
            posix.munmap(m);
        }
        self.retired_maps.clearRetainingCapacity();
    }

    pub fn hibernate(self: *AppendLog) void {
        if (self.mapped) |m| {
            posix.madvise(m.ptr, m.len, posix.MADV.DONTNEED) catch {};
        }
        for (self.retired_maps.items) |m| {
            posix.madvise(m.ptr, m.len, posix.MADV.DONTNEED) catch {};
        }
    }

    fn ensureMapped(self: *AppendLog) !void {
        if (self.write_offset == 0) return;
        try self.ensureMappedFor(@intCast(self.write_offset));
    }

    fn ensureMappedFor(self: *AppendLog, min_needed: usize) !void {
        if (min_needed == 0) return;
        if (self.mapped != null and self.mapped_len >= min_needed) return;
        const page = std.heap.page_size_min;
        const doubled = if (self.mapped_len > 0) self.mapped_len * 2 else 64 * 1024;
        const raw_target = @max(min_needed, doubled);
        const map_len = std.mem.alignForward(usize, raw_target, page);
        const fd: posix.fd_t = self.file.handle;
        const ptr = try posix.mmap(
            null,
            map_len,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        if (self.mapped) |old_m| {
            self.retired_maps.append(self.allocator, old_m) catch |err| {
                posix.munmap(ptr);
                return err;
            };
        }
        self.mapped = ptr;
        self.mapped_len = map_len;
    }

    pub fn tailRecover(self: *AppendLog, start_offset: u64, verify_blake3: bool) !void {
        self.index.clearRetainingCapacity();
        const st = try self.file.stat(self.io);
        const file_size = st.size;
        if (file_size == 0) {
            self.write_offset = 0;
            self.next_seq = 1;
            return;
        }

        const size_usize: usize = @intCast(file_size);
        const start_usize: usize = @intCast(start_offset);
        if (start_usize > size_usize) return error.OutOfBounds;

        try self.ensureMappedFor(size_usize);
        const mapping = self.mapped orelse return;

        var offset: usize = start_usize;
        var last_seq: u64 = 0;
        while (offset + HEADER_SIZE <= size_usize) {
            const hdr_ptr: *const [HEADER_SIZE]u8 = @ptrCast(mapping[offset .. offset + HEADER_SIZE].ptr);
            const hdr = FrameHeader.decode(hdr_ptr) catch break;
            const payload_start = offset + HEADER_SIZE;
            const payload_end = payload_start + hdr.payload_len;
            if (payload_end > size_usize) break;
            const payload = mapping[payload_start..payload_end];
            if (frameCrc(hdr_ptr, payload) != hdr.crc) break;
            if (verify_blake3) {
                const h = crypto.hashBytes(payload);
                const actual_prefix = std.mem.readInt(u64, h[0..8], .little);
                if (actual_prefix != hdr.hash_prefix) break;
            }
            const aligned_end = alignUp(payload_end);
            if (aligned_end > size_usize) break;
            try self.index.append(self.allocator, .{
                .seq = hdr.seq,
                .offset = offset,
                .payload_len = hdr.payload_len,
                .kind = hdr.kind,
                .flags = hdr.flags,
                .aux = hdr.aux,
            });
            last_seq = hdr.seq;
            offset = aligned_end;
        }

        if (offset < size_usize) {
            self.unmapAll();
            try self.file.setLength(self.io, offset);
            self.write_offset = offset;
            if (offset > 0) try self.ensureMappedFor(offset);
        } else {
            self.write_offset = offset;
        }
        self.next_seq = last_seq + 1;
    }

    pub fn append(self: *AppendLog, kind: u8, flags: u8, aux: u16, payload: []const u8) !u64 {
        const r = try self.appendWithOffset(self.next_seq, kind, flags, aux, payload);
        return r.seq;
    }

    pub fn appendDeferred(self: *AppendLog, kind: u8, flags: u8, aux: u16, payload: []const u8) !u64 {
        const r = try self.appendWithOffsetEx(self.next_seq, kind, flags, aux, payload, false);
        return r.seq;
    }

    pub fn appendWithSeq(self: *AppendLog, seq: u64, kind: u8, flags: u8, aux: u16, payload: []const u8) !u64 {
        const r = try self.appendWithOffset(seq, kind, flags, aux, payload);
        return r.seq;
    }

    pub fn appendWithOffset(self: *AppendLog, seq: u64, kind: u8, flags: u8, aux: u16, payload: []const u8) !AppendResult {
        return self.appendWithOffsetEx(seq, kind, flags, aux, payload, self.durable_sync);
    }

    pub fn appendWithOffsetEx(self: *AppendLog, seq: u64, kind: u8, flags: u8, aux: u16, payload: []const u8, do_sync: bool) !AppendResult {
        const h = crypto.hashBytes(payload);
        const prefix = std.mem.readInt(u64, h[0..8], .little);
        var hdr = FrameHeader{
            .kind = kind,
            .flags = flags,
            .aux = aux,
            .seq = seq,
            .payload_len = @intCast(payload.len),
            .crc = 0,
            .hash_prefix = prefix,
        };
        var hdr_bytes = hdr.encode();
        hdr.crc = frameCrc(&hdr_bytes, payload);
        hdr_bytes = hdr.encode();

        const raw_total = HEADER_SIZE + payload.len;
        const aligned_total = alignUp(raw_total);
        const pad_len = aligned_total - raw_total;
        const frame_offset = self.write_offset;

        if (aligned_total <= 4096) {
            var stack_buf: [4096]u8 = undefined;
            @memcpy(stack_buf[0..HEADER_SIZE], &hdr_bytes);
            if (payload.len > 0) @memcpy(stack_buf[HEADER_SIZE .. HEADER_SIZE + payload.len], payload);
            if (pad_len > 0) @memset(stack_buf[raw_total..aligned_total], 0);
            try self.file.writePositionalAll(self.io, stack_buf[0..aligned_total], frame_offset);
        } else {
            const zero_pad: [ALIGN]u8 = @splat(0);
            var vecs = [_][]const u8{
                &hdr_bytes,
                payload,
                zero_pad[0..pad_len],
            };
            var pos = frame_offset;
            for (&vecs) |v| {
                if (v.len == 0) continue;
                try self.file.writePositionalAll(self.io, v, pos);
                pos += v.len;
            }
        }
        if (do_sync) {
            try self.syncData();
        }

        self.write_offset = frame_offset + aligned_total;
        if (seq >= self.next_seq) self.next_seq = seq + 1;
        try self.index.append(self.allocator, .{
            .seq = seq,
            .offset = frame_offset,
            .payload_len = @intCast(payload.len),
            .kind = kind,
            .flags = flags,
            .aux = aux,
        });
        return .{
            .seq = seq,
            .payload_offset = frame_offset + HEADER_SIZE,
        };
    }

    pub fn appendFramesBulk(self: *AppendLog, frames: []const BulkFrame) ![]AppendResult {
        const results = try self.allocator.alloc(AppendResult, frames.len);
        errdefer self.allocator.free(results);
        if (frames.len == 0) return results;

        var total_bytes: usize = 0;
        for (frames) |f| {
            total_bytes += alignUp(HEADER_SIZE + f.payload.len);
        }

        try self.index.ensureUnusedCapacity(self.allocator, frames.len);
        const buf = try self.allocator.alloc(u8, total_bytes);
        defer self.allocator.free(buf);

        const base_offset = self.write_offset;
        var cur_next_seq = self.next_seq;
        var buf_pos: usize = 0;

        for (frames, 0..) |f, i| {
            const seq = f.seq orelse cur_next_seq;
            if (seq >= cur_next_seq) cur_next_seq = seq + 1;

            const h = crypto.hashBytes(f.payload);
            const prefix = std.mem.readInt(u64, h[0..8], .little);
            var hdr = FrameHeader{
                .kind = f.kind,
                .flags = f.flags,
                .aux = f.aux,
                .seq = seq,
                .payload_len = @intCast(f.payload.len),
                .crc = 0,
                .hash_prefix = prefix,
            };
            var hdr_bytes = hdr.encode();
            hdr.crc = frameCrc(&hdr_bytes, f.payload);
            hdr_bytes = hdr.encode();

            const raw_total = HEADER_SIZE + f.payload.len;
            const aligned_total = alignUp(raw_total);
            const pad_len = aligned_total - raw_total;

            @memcpy(buf[buf_pos .. buf_pos + HEADER_SIZE], &hdr_bytes);
            if (f.payload.len > 0) {
                @memcpy(buf[buf_pos + HEADER_SIZE .. buf_pos + raw_total], f.payload);
            }
            if (pad_len > 0) {
                @memset(buf[buf_pos + raw_total .. buf_pos + aligned_total], 0);
            }

            results[i] = .{
                .seq = seq,
                .payload_offset = base_offset + buf_pos + HEADER_SIZE,
            };
            buf_pos += aligned_total;
        }

        try self.file.writePositionalAll(self.io, buf, base_offset);
        if (self.durable_sync) {
            try self.syncData();
        }

        var idx_off = base_offset;
        for (frames, 0..) |f, i| {
            self.index.appendAssumeCapacity(.{
                .seq = results[i].seq,
                .offset = idx_off,
                .payload_len = @intCast(f.payload.len),
                .kind = f.kind,
                .flags = f.flags,
                .aux = f.aux,
            });
            idx_off += alignUp(HEADER_SIZE + f.payload.len);
        }

        self.write_offset = base_offset + total_bytes;
        self.next_seq = cur_next_seq;
        return results;
    }

    fn syncFileData(io: Io, file: Io.File) !void {
        try mmap.fdatasyncFile(io, file);
    }

    fn syncData(self: *AppendLog) !void {
        try syncFileData(self.io, self.file);
    }

    pub fn sync(self: *AppendLog) !void {
        if (self.durable_sync) {
            try self.syncData();
        }
    }

    pub fn flush(self: *AppendLog) !void {
        try self.syncData();
    }

    pub fn compact(self: *AppendLog, dir: Io.Dir, sub_path: []const u8, keep_indices: []const usize) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.compact.tmp", .{sub_path});
        defer self.allocator.free(tmp_path);

        const tmp_file = try dir.createFile(self.io, tmp_path, .{
            .read = true,
            .truncate = true,
        });
        var tmp_closed = false;
        var tmp_renamed = false;
        errdefer {
            if (!tmp_closed) tmp_file.close(self.io);
            if (!tmp_renamed) dir.deleteFile(self.io, tmp_path) catch {};
        }

        var new_index: std.ArrayList(FrameIndexEntry) = .empty;
        var index_owned = true;
        errdefer if (index_owned) new_index.deinit(self.allocator);
        try new_index.ensureTotalCapacity(self.allocator, keep_indices.len);

        var new_offset: u64 = 0;
        const zero_pad: [ALIGN]u8 = @splat(0);
        for (keep_indices) |idx| {
            const raw = try self.readRawFrameAt(idx);
            const entry = self.index.items[idx];
            const aligned_total = alignUp(raw.len);
            const pad_len = aligned_total - raw.len;
            try tmp_file.writePositionalAll(self.io, raw, new_offset);
            if (pad_len > 0) {
                try tmp_file.writePositionalAll(self.io, zero_pad[0..pad_len], new_offset + raw.len);
            }
            new_index.appendAssumeCapacity(.{
                .seq = entry.seq,
                .offset = new_offset,
                .payload_len = entry.payload_len,
                .kind = entry.kind,
                .flags = entry.flags,
                .aux = entry.aux,
            });
            new_offset += aligned_total;
        }

        try syncFileData(self.io, tmp_file);
        tmp_file.close(self.io);
        tmp_closed = true;
        try dir.rename(tmp_path, dir, sub_path, self.io);
        tmp_renamed = true;

        const new_file = try dir.createFile(self.io, sub_path, .{
            .read = true,
            .truncate = false,
        });

        self.unmapAll();
        self.file.close(self.io);
        self.file = new_file;
        self.write_offset = new_offset;
        self.index.deinit(self.allocator);
        self.index = new_index;
        index_owned = false;
        if (new_offset > 0) {
            try self.ensureMappedFor(@intCast(new_offset));
        }
    }

    pub fn count(self: *const AppendLog) usize {
        return self.index.items.len;
    }

    pub fn lastSeq(self: *const AppendLog) u64 {
        if (self.index.items.len == 0) return 0;
        return self.index.items[self.index.items.len - 1].seq;
    }

    pub fn payloadOffsetAt(self: *const AppendLog, idx: usize) !u64 {
        if (idx >= self.index.items.len) return error.OutOfBounds;
        return self.index.items[idx].offset + HEADER_SIZE;
    }

    pub fn readSlice(self: *AppendLog, file_offset: u64, len: u32) ?[]const u8 {
        if (len == 0) return "";
        const end = file_offset + @as(u64, len);
        if (end > self.write_offset) return null;
        const end_usize: usize = @intCast(end);
        if (self.mapped == null or end_usize > self.mapped_len) {
            self.ensureMappedFor(end_usize) catch return null;
        }
        const m = self.mapped orelse return null;
        return m[@intCast(file_offset)..end_usize];
    }

    pub fn readAt(self: *AppendLog, idx: usize) !FrameView {
        if (idx >= self.index.items.len) return error.OutOfBounds;
        const entry = self.index.items[idx];
        const off: usize = @intCast(entry.offset);
        const end = off + HEADER_SIZE + entry.payload_len;
        try self.ensureMappedFor(end);
        const mapping = self.mapped orelse return error.OutOfBounds;
        const hdr_ptr: *const [HEADER_SIZE]u8 = @ptrCast(mapping[off .. off + HEADER_SIZE].ptr);
        const hdr = try FrameHeader.decode(hdr_ptr);
        const payload = mapping[off + HEADER_SIZE .. off + HEADER_SIZE + hdr.payload_len];
        return .{ .header = hdr, .payload = payload };
    }

    pub fn readRawFrameAt(self: *AppendLog, idx: usize) ![]const u8 {
        if (idx >= self.index.items.len) return error.OutOfBounds;
        const entry = self.index.items[idx];
        const off: usize = @intCast(entry.offset);
        const end = off + HEADER_SIZE + entry.payload_len;
        try self.ensureMappedFor(end);
        const mapping = self.mapped orelse return error.OutOfBounds;
        return mapping[off..end];
    }

    pub fn findIndexBySeq(self: *const AppendLog, from_seq: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.index.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.index.items[mid].seq < from_seq) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
};
