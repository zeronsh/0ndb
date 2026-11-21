const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const git_dirs = @import("git_dirs.zig");
const ObjectFormat = git_dirs.ObjectFormat;
const GitOid = git_dirs.GitOid;
const GitConfigFlags = git_dirs.GitConfigFlags;
const GitDirs = git_dirs.GitDirs;

pub const IndexError = error{
    InvalidIndexMagic,
    UnsupportedIndexVersion,
    UnsupportedIndexExtension,
    InvalidChecksum,
    CorruptIndex,
    FileTooBig,
};

pub const IndexStat = struct {
    ctime_s: u32,
    ctime_ns: u32,
    mtime_s: u32,
    mtime_ns: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    file_size: u32,
};

pub const IndexEntry = struct {
    stat: IndexStat,
    oid: GitOid,
    flags: u16,
    ext_flags: u16,
    path: []const u8,

    pub fn stage(self: *const IndexEntry) u2 {
        return @truncate((self.flags >> 12) & 0x3);
    }

    pub fn isExtended(self: *const IndexEntry) bool {
        return (self.flags & 0x4000) != 0;
    }

    pub fn isAssumeValid(self: *const IndexEntry) bool {
        return (self.flags & 0x8000) != 0;
    }

    pub fn isSkipWorktree(self: *const IndexEntry) bool {
        return (self.ext_flags & 0x4000) != 0;
    }

    pub fn isIntentToAdd(self: *const IndexEntry) bool {
        return (self.ext_flags & 0x2000) != 0;
    }

    pub fn isRegularFile(self: *const IndexEntry) bool {
        return (self.stat.mode & 0o170000) == 0o100000;
    }

    pub fn isExecutable(self: *const IndexEntry) bool {
        return self.isRegularFile() and (self.stat.mode & 0o111) != 0;
    }

    pub fn isSymlink(self: *const IndexEntry) bool {
        return (self.stat.mode & 0o170000) == 0o120000;
    }

    pub fn isGitlink(self: *const IndexEntry) bool {
        return (self.stat.mode & 0o170000) == 0o160000;
    }
};

pub const IndexDiffKind = enum(u8) {
    added,
    modified,
    removed,
};

pub const IndexDiffEntry = struct {
    kind: IndexDiffKind,
    path: []const u8,
    old_oid: ?GitOid,
    new_oid: ?GitOid,
};

const PathSpan = struct {
    off: usize,
    len: usize,
};

pub const GitIndex = struct {
    version: u32,
    format: ObjectFormat,
    entries: []IndexEntry,
    path_arena: []u8,
    index_mtime_s: u32,
    index_mtime_ns: u32,
    index_size: u64,
    index_ino: u64,

    pub fn deinit(self: *GitIndex, allocator: Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.path_arena);
        self.* = .{
            .version = 0,
            .format = .sha1,
            .entries = &.{},
            .path_arena = &.{},
            .index_mtime_s = 0,
            .index_mtime_ns = 0,
            .index_size = 0,
            .index_ino = 0,
        };
    }

    pub fn load(allocator: Allocator, io: Io, dirs: *const GitDirs) !?GitIndex {
        var gd = Io.Dir.cwd().openDir(io, dirs.git_dir, .{}) catch return null;
        defer gd.close(io);

        const f = gd.openFile(io, "index", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer f.close(io);

        const st = try f.stat(io);
        if (st.size > 512 * 1024 * 1024) return error.FileTooBig;
        const size: usize = @intCast(st.size);
        const raw = try allocator.alloc(u8, size);
        defer allocator.free(raw);
        const n = try f.readPositionalAll(io, raw, 0);
        if (n != size) return error.CorruptIndex;

        const mtime_parts = splitTimestamp(st.mtime.nanoseconds);
        return try parse(
            allocator,
            raw,
            dirs.config.object_format,
            mtime_parts.sec,
            mtime_parts.nsec,
            st.size,
            st.inode,
        );
    }

    pub fn parse(
        allocator: Allocator,
        raw: []const u8,
        format: ObjectFormat,
        index_mtime_s: u32,
        index_mtime_ns: u32,
        index_size: u64,
        index_ino: u64,
    ) (IndexError || Allocator.Error)!GitIndex {
        const hash_len = format.byteLen();
        if (raw.len < 12 + hash_len) return error.CorruptIndex;
        if (!std.mem.eql(u8, raw[0..4], "DIRC")) return error.InvalidIndexMagic;

        const version = std.mem.readInt(u32, raw[4..8], .big);
        if (version < 2 or version > 4) return error.UnsupportedIndexVersion;

        const entry_count: usize = std.mem.readInt(u32, raw[8..12], .big);
        const data_end = raw.len - hash_len;

        if (!verifyTrailingChecksum(raw[0..data_end], raw[data_end..], format)) {
            return error.InvalidChecksum;
        }

        const entries = try allocator.alloc(IndexEntry, entry_count);
        errdefer allocator.free(entries);

        const spans = try allocator.alloc(PathSpan, entry_count);
        defer allocator.free(spans);

        var path_arena: std.ArrayList(u8) = .empty;
        errdefer path_arena.deinit(allocator);

        var pos: usize = 12;
        var prev_span: PathSpan = .{ .off = 0, .len = 0 };

        for (0..entry_count) |i| {
            const entry_start = pos;
            const fixed_len = 40 + hash_len + 2;
            if (pos + fixed_len > data_end) return error.CorruptIndex;

            const stat = IndexStat{
                .ctime_s = std.mem.readInt(u32, raw[pos + 0 ..][0..4], .big),
                .ctime_ns = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big),
                .mtime_s = std.mem.readInt(u32, raw[pos + 8 ..][0..4], .big),
                .mtime_ns = std.mem.readInt(u32, raw[pos + 12 ..][0..4], .big),
                .dev = std.mem.readInt(u32, raw[pos + 16 ..][0..4], .big),
                .ino = std.mem.readInt(u32, raw[pos + 20 ..][0..4], .big),
                .mode = std.mem.readInt(u32, raw[pos + 24 ..][0..4], .big),
                .uid = std.mem.readInt(u32, raw[pos + 28 ..][0..4], .big),
                .gid = std.mem.readInt(u32, raw[pos + 32 ..][0..4], .big),
                .file_size = std.mem.readInt(u32, raw[pos + 36 ..][0..4], .big),
            };
            pos += 40;

            var oid: GitOid = .{
                .len = @intCast(hash_len),
                .bytes = @splat(0),
            };
            @memcpy(oid.bytes[0..hash_len], raw[pos .. pos + hash_len]);
            pos += hash_len;

            const flags = std.mem.readInt(u16, raw[pos..][0..2], .big);
            pos += 2;

            var ext_flags: u16 = 0;
            if (version >= 3 and (flags & 0x4000) != 0) {
                if (pos + 2 > data_end) return error.CorruptIndex;
                ext_flags = std.mem.readInt(u16, raw[pos..][0..2], .big);
                pos += 2;
            }

            if (version == 4) {
                const strip_u64 = decodeBiasedVarint(raw[0..data_end], &pos) orelse return error.CorruptIndex;
                if (strip_u64 > prev_span.len) return error.CorruptIndex;
                const strip_len: usize = @intCast(strip_u64);
                const keep_len = prev_span.len - strip_len;

                const nul_rel = std.mem.indexOfScalar(u8, raw[pos..data_end], 0) orelse return error.CorruptIndex;
                const suffix = raw[pos .. pos + nul_rel];
                pos += nul_rel + 1;

                const total_len = keep_len + suffix.len;
                try path_arena.ensureUnusedCapacity(allocator, total_len);
                const new_off = path_arena.items.len;
                if (keep_len > 0) {
                    const prev_prefix = path_arena.items[prev_span.off .. prev_span.off + keep_len];
                    path_arena.appendSliceAssumeCapacity(prev_prefix);
                }
                path_arena.appendSliceAssumeCapacity(suffix);
                spans[i] = .{ .off = new_off, .len = total_len };
                prev_span = spans[i];
            } else {
                const name_len_hint: usize = flags & 0x0FFF;
                var name_len: usize = 0;
                if (name_len_hint < 0x0FFF) {
                    if (pos + name_len_hint >= data_end) return error.CorruptIndex;
                    if (raw[pos + name_len_hint] != 0) return error.CorruptIndex;
                    name_len = name_len_hint;
                } else {
                    const nul_rel = std.mem.indexOfScalar(u8, raw[pos..data_end], 0) orelse return error.CorruptIndex;
                    name_len = nul_rel;
                }
                const name_slice = raw[pos .. pos + name_len];
                const new_off = path_arena.items.len;
                try path_arena.appendSlice(allocator, name_slice);
                spans[i] = .{ .off = new_off, .len = name_len };
                prev_span = spans[i];

                pos += name_len;
                const entry_raw_len = pos - entry_start;
                const padded_len = (entry_raw_len + 8) & ~@as(usize, 7);
                if (entry_start + padded_len > data_end) return error.CorruptIndex;
                pos = entry_start + padded_len;
            }

            entries[i] = .{
                .stat = stat,
                .oid = oid,
                .flags = flags,
                .ext_flags = ext_flags,
                .path = &.{},
            };
        }

        while (pos < data_end) {
            if (pos + 8 > data_end) return error.CorruptIndex;
            const sig = raw[pos .. pos + 4];
            const ext_len: usize = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
            pos += 8;
            if (ext_len > data_end - pos) return error.CorruptIndex;

            if (std.mem.eql(u8, sig, "link") or std.mem.eql(u8, sig, "sdir")) {
                return error.UnsupportedIndexExtension;
            }
            if (std.mem.eql(u8, sig, "TREE") or
                std.mem.eql(u8, sig, "REUC") or
                std.mem.eql(u8, sig, "UNTR") or
                std.mem.eql(u8, sig, "FSMN") or
                std.mem.eql(u8, sig, "EOIE") or
                std.mem.eql(u8, sig, "IEOT"))
            {
                pos += ext_len;
                continue;
            }
            if (sig[0] >= 'a' and sig[0] <= 'z') {
                return error.UnsupportedIndexExtension;
            }
            pos += ext_len;
        }

        const arena_slice = try path_arena.toOwnedSlice(allocator);
        for (0..entry_count) |i| {
            entries[i].path = arena_slice[spans[i].off .. spans[i].off + spans[i].len];
        }

        return .{
            .version = version,
            .format = format,
            .entries = entries,
            .path_arena = arena_slice,
            .index_mtime_s = index_mtime_s,
            .index_mtime_ns = index_mtime_ns,
            .index_size = index_size,
            .index_ino = index_ino,
        };
    }

    pub fn find(self: *const GitIndex, path: []const u8) ?*const IndexEntry {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].path, path)) {
                .lt => lo = mid + 1,
                .gt, .eq => hi = mid,
            }
        }
        if (lo < self.entries.len and std.mem.eql(u8, self.entries[lo].path, path)) {
            return &self.entries[lo];
        }
        return null;
    }

    pub fn isStatClean(self: *const GitIndex, entry: *const IndexEntry, disk_stat: Io.File.Stat, cfg: GitConfigFlags) bool {
        if (entry.stage() != 0) return false;
        if (entry.isSkipWorktree()) return false;
        if (entry.isIntentToAdd()) return false;
        if (!entry.isRegularFile()) return false;
        if (disk_stat.kind != .file) return false;
        if (disk_stat.size > std.math.maxInt(u32)) return false;

        if (entry.stat.file_size == 0 and disk_stat.size != 0) return false;
        if (entry.stat.file_size != @as(u32, @intCast(disk_stat.size))) return false;

        if (self.index_mtime_s != 0 or self.index_mtime_ns != 0) {
            if (entry.stat.mtime_s > self.index_mtime_s) return false;
            if (entry.stat.mtime_s == self.index_mtime_s) {
                if (entry.stat.mtime_ns == 0 or self.index_mtime_ns == 0) return false;
                if (entry.stat.mtime_ns >= self.index_mtime_ns) return false;
            }
        }

        if (disk_stat.mtime.nanoseconds < 0) return false;
        const dm = splitTimestamp(disk_stat.mtime.nanoseconds);
        if (entry.stat.mtime_s != dm.sec) return false;
        if (entry.stat.mtime_ns != dm.nsec) return false;

        if (cfg.trustctime) {
            if (disk_stat.ctime.nanoseconds < 0) return false;
            const dc = splitTimestamp(disk_stat.ctime.nanoseconds);
            if (entry.stat.ctime_s != dc.sec) return false;
            if (entry.stat.ctime_ns != dc.nsec) return false;
        }

        const disk_ino32: u32 = @truncate(disk_stat.inode);
        if (entry.stat.ino != 0 and entry.stat.ino != disk_ino32) return false;

        if (cfg.filemode) {
            const disk_exec = (disk_stat.permissions.toMode() & 0o100) != 0;
            if (entry.isExecutable() != disk_exec) return false;
        }

        return true;
    }

    pub fn diffIndices(allocator: Allocator, old: *const GitIndex, new: *const GitIndex) Allocator.Error![]IndexDiffEntry {
        var out: std.ArrayList(IndexDiffEntry) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        var j: usize = 0;
        while (i < old.entries.len and j < new.entries.len) {
            const oe = &old.entries[i];
            const ne = &new.entries[j];
            switch (std.mem.order(u8, oe.path, ne.path)) {
                .lt => {
                    try out.append(allocator, .{
                        .kind = .removed,
                        .path = oe.path,
                        .old_oid = oe.oid,
                        .new_oid = null,
                    });
                    i = advancePastSamePath(old.entries, i);
                },
                .gt => {
                    try out.append(allocator, .{
                        .kind = .added,
                        .path = ne.path,
                        .old_oid = null,
                        .new_oid = ne.oid,
                    });
                    j = advancePastSamePath(new.entries, j);
                },
                .eq => {
                    if (!oe.oid.eql(ne.oid) or oe.stat.mode != ne.stat.mode or oe.stage() != ne.stage()) {
                        try out.append(allocator, .{
                            .kind = .modified,
                            .path = ne.path,
                            .old_oid = oe.oid,
                            .new_oid = ne.oid,
                        });
                    }
                    i = advancePastSamePath(old.entries, i);
                    j = advancePastSamePath(new.entries, j);
                },
            }
        }
        while (i < old.entries.len) {
            const oe = &old.entries[i];
            try out.append(allocator, .{
                .kind = .removed,
                .path = oe.path,
                .old_oid = oe.oid,
                .new_oid = null,
            });
            i = advancePastSamePath(old.entries, i);
        }
        while (j < new.entries.len) {
            const ne = &new.entries[j];
            try out.append(allocator, .{
                .kind = .added,
                .path = ne.path,
                .old_oid = null,
                .new_oid = ne.oid,
            });
            j = advancePastSamePath(new.entries, j);
        }

        return try out.toOwnedSlice(allocator);
    }
};

fn advancePastSamePath(entries: []const IndexEntry, start: usize) usize {
    const p = entries[start].path;
    var k = start + 1;
    while (k < entries.len and std.mem.eql(u8, entries[k].path, p)) : (k += 1) {}
    return k;
}

fn verifyTrailingChecksum(body: []const u8, trailing: []const u8, format: ObjectFormat) bool {
    var all_zero = true;
    for (trailing) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return true;

    switch (format) {
        .sha1 => {
            var digest: [20]u8 = undefined;
            Sha1.hash(body, &digest, .{});
            return std.mem.eql(u8, &digest, trailing);
        },
        .sha256 => {
            var digest: [32]u8 = undefined;
            Sha256.hash(body, &digest, .{});
            return std.mem.eql(u8, &digest, trailing);
        },
    }
}

pub fn decodeBiasedVarint(data: []const u8, pos: *usize) ?u64 {
    if (pos.* >= data.len) return null;
    var c = data[pos.*];
    pos.* += 1;
    var val: u64 = c & 0x7f;
    while ((c & 0x80) != 0) {
        if (pos.* >= data.len) return null;
        if (val >= (@as(u64, 1) << 57) - 1) return null;
        val += 1;
        c = data[pos.*];
        pos.* += 1;
        val = (val << 7) | (c & 0x7f);
    }
    return val;
}

const TimeParts = struct {
    sec: u32,
    nsec: u32,
};

fn splitTimestamp(ns: i96) TimeParts {
    if (ns <= 0) return .{ .sec = 0, .nsec = 0 };
    const sec_i = @divFloor(ns, std.time.ns_per_s);
    const nsec_i = @mod(ns, std.time.ns_per_s);
    return .{
        .sec = @truncate(@as(u64, @intCast(sec_i))),
        .nsec = @intCast(nsec_i),
    };
}
