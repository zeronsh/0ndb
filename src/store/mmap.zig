const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;

var tmp_seq: std.atomic.Value(u64) = .init(0);

fn currentPid() u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    }
    return 0;
}

pub const MappedFile = struct {
    mapping: ?[]align(std.heap.page_size_min) u8,
    file_len: usize,
    refcount: std.atomic.Value(u32),

    pub fn open(allocator: Allocator, io: Io, dir: Io.Dir, rel_path: []const u8) !*MappedFile {
        const file = try dir.openFile(io, rel_path, .{});
        defer file.close(io);

        const st = try file.stat(io);
        const file_len: usize = @intCast(st.size);

        var mapping: ?[]align(std.heap.page_size_min) u8 = null;
        if (file_len > 0) {
            const map_len = std.mem.alignForward(usize, file_len, std.heap.page_size_min);
            mapping = try posix.mmap(
                null,
                map_len,
                .{ .READ = true },
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            );
        }
        errdefer if (mapping) |m| posix.munmap(m);

        const self = try allocator.create(MappedFile);
        self.* = .{
            .mapping = mapping,
            .file_len = file_len,
            .refcount = .init(1),
        };
        return self;
    }

    pub fn retain(self: *MappedFile) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    pub fn refCount(self: *const MappedFile) u32 {
        return self.refcount.load(.acquire);
    }

    pub fn release(self: *MappedFile, allocator: Allocator) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) {
            if (self.mapping) |m| {
                posix.munmap(m);
            }
            allocator.destroy(self);
        }
    }

    pub fn len(self: *const MappedFile) usize {
        return self.file_len;
    }

    pub fn slice(self: *const MappedFile) []const u8 {
        const m = self.mapping orelse return "";
        return m[0..self.file_len];
    }

    pub fn sliceChecked(self: *const MappedFile, off: usize, length: usize) ![]const u8 {
        const end = std.math.add(usize, off, length) catch return error.OutOfBounds;
        if (end > self.file_len) return error.OutOfBounds;
        if (length == 0) return "";
        const m = self.mapping orelse return error.OutOfBounds;
        return m[off..end];
    }

    pub fn sliceCheckedU64(self: *const MappedFile, off: u64, length: u64) ![]const u8 {
        const off_u = std.math.cast(usize, off) orelse return error.OutOfBounds;
        const len_u = std.math.cast(usize, length) orelse return error.OutOfBounds;
        return self.sliceChecked(off_u, len_u);
    }

    pub fn hibernate(self: *const MappedFile) void {
        if (self.mapping) |m| {
            posix.madvise(m.ptr, m.len, posix.MADV.DONTNEED) catch {};
        }
    }
};

pub fn fdatasyncFile(io: Io, file: Io.File) !void {
    if (builtin.os.tag == .linux) {
        while (true) {
            const rc = std.os.linux.fdatasync(file.handle);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => return file.sync(io),
            }
        }
    }
    try file.sync(io);
}

fn fsyncFdLinux(fd: std.os.linux.fd_t) std.os.linux.E {
    while (true) {
        const rc = std.os.linux.fsync(fd);
        const err = std.os.linux.errno(rc);
        if (err == .INTR) continue;
        return err;
    }
}

pub fn fsyncDir(io: Io, dir: Io.Dir) !void {
    if (builtin.os.tag == .linux) {
        switch (fsyncFdLinux(dir.handle)) {
            .SUCCESS, .INVAL, .ROFS => return,
            .BADF => {
                var real_dir = try dir.openDir(io, ".", .{ .iterate = true });
                defer real_dir.close(io);
                switch (fsyncFdLinux(real_dir.handle)) {
                    .SUCCESS, .INVAL, .ROFS => return,
                    else => return error.InputOutput,
                }
            },
            else => return error.InputOutput,
        }
    }
}

pub fn atomicWriteFile(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const sub_dir_name = std.fs.path.dirname(name);
    const base_name = std.fs.path.basename(name);

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

    if (data.len > 0) {
        try file.writePositionalAll(io, data, 0);
    }
    try file.sync(io);
    file.close(io);
    file_closed = true;

    try target_dir.rename(tmp_name, target_dir, base_name, io);
    renamed = true;

    try fsyncDir(io, target_dir);
}
