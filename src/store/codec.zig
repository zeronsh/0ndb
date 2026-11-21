const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodeError = error{
    UnexpectedEof,
    InvalidVarint,
    InvalidData,
    ChecksumMismatch,
};

pub fn crc32c(bytes: []const u8) u32 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(bytes);
}

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Writer, allocator: Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn items(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn toOwnedSlice(self: *Writer, allocator: Allocator) Allocator.Error![]u8 {
        return self.buf.toOwnedSlice(allocator);
    }

    pub fn clearRetainingCapacity(self: *Writer) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn writeByte(self: *Writer, allocator: Allocator, b: u8) Allocator.Error!void {
        try self.buf.append(allocator, b);
    }

    pub fn writeU8(self: *Writer, allocator: Allocator, b: u8) Allocator.Error!void {
        try self.buf.append(allocator, b);
    }

    pub fn writeBool(self: *Writer, allocator: Allocator, v: bool) Allocator.Error!void {
        try self.buf.append(allocator, if (v) 1 else 0);
    }

    pub fn writeU16(self: *Writer, allocator: Allocator, v: u16) Allocator.Error!void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }

    pub fn writeU32(self: *Writer, allocator: Allocator, v: u32) Allocator.Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }

    pub fn writeU64(self: *Writer, allocator: Allocator, v: u64) Allocator.Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }

    pub fn writeU128(self: *Writer, allocator: Allocator, v: u128) Allocator.Error!void {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }

    pub fn writeVarint(self: *Writer, allocator: Allocator, val: u64) Allocator.Error!void {
        var v = val;
        while (v >= 0x80) {
            try self.buf.append(allocator, @as(u8, @truncate(v)) | 0x80);
            v >>= 7;
        }
        try self.buf.append(allocator, @truncate(v));
    }

    pub fn writeRaw(self: *Writer, allocator: Allocator, data: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(allocator, data);
    }

    pub fn writeBytes(self: *Writer, allocator: Allocator, data: []const u8) Allocator.Error!void {
        try self.writeVarint(allocator, data.len);
        try self.buf.appendSlice(allocator, data);
    }

    pub fn writeOptBytes(self: *Writer, allocator: Allocator, data: ?[]const u8) Allocator.Error!void {
        if (data) |d| {
            try self.writeByte(allocator, 1);
            try self.writeBytes(allocator, d);
        } else {
            try self.writeByte(allocator, 0);
        }
    }

    pub fn writeOptU128(self: *Writer, allocator: Allocator, v: ?u128) Allocator.Error!void {
        if (v) |val| {
            try self.writeByte(allocator, 1);
            try self.writeU128(allocator, val);
        } else {
            try self.writeByte(allocator, 0);
        }
    }

    pub fn writeOptU64(self: *Writer, allocator: Allocator, v: ?u64) Allocator.Error!void {
        if (v) |val| {
            try self.writeByte(allocator, 1);
            try self.writeU64(allocator, val);
        } else {
            try self.writeByte(allocator, 0);
        }
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn readByte(self: *Reader) DecodeError!u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readU8(self: *Reader) DecodeError!u8 {
        return self.readByte();
    }

    pub fn readBool(self: *Reader) DecodeError!bool {
        return (try self.readByte()) != 0;
    }

    pub fn readU16(self: *Reader) DecodeError!u16 {
        const s = try self.readFixed(2);
        return std.mem.readInt(u16, s, .little);
    }

    pub fn readU32(self: *Reader) DecodeError!u32 {
        const s = try self.readFixed(4);
        return std.mem.readInt(u32, s, .little);
    }

    pub fn readU64(self: *Reader) DecodeError!u64 {
        const s = try self.readFixed(8);
        return std.mem.readInt(u64, s, .little);
    }

    pub fn readU128(self: *Reader) DecodeError!u128 {
        const s = try self.readFixed(16);
        return std.mem.readInt(u128, s, .little);
    }

    pub fn readFixed(self: *Reader, comptime n: usize) DecodeError!*const [n]u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        const ptr: *const [n]u8 = @ptrCast(self.data[self.pos .. self.pos + n].ptr);
        self.pos += n;
        return ptr;
    }

    pub fn readVarint(self: *Reader) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var count: u8 = 0;
        while (count < 10) : (count += 1) {
            const b = try self.readByte();
            if (count == 9 and b > 1) return error.InvalidVarint;
            result |= @as(u64, b & 0x7F) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return error.InvalidVarint;
    }

    pub fn readBytes(self: *Reader) DecodeError![]const u8 {
        const len_u64 = try self.readVarint();
        if (len_u64 > self.remaining()) return error.UnexpectedEof;
        const len: usize = @intCast(len_u64);
        const out = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return out;
    }

    pub fn readBytesAlloc(self: *Reader, allocator: Allocator) (DecodeError || Allocator.Error)![]u8 {
        const s = try self.readBytes();
        return allocator.dupe(u8, s);
    }

    pub fn readOptBytes(self: *Reader) DecodeError!?[]const u8 {
        const tag = try self.readByte();
        if (tag == 0) return null;
        if (tag != 1) return error.InvalidData;
        return try self.readBytes();
    }

    pub fn readOptBytesAlloc(self: *Reader, allocator: Allocator) (DecodeError || Allocator.Error)!?[]u8 {
        const s = try self.readOptBytes() orelse return null;
        return try allocator.dupe(u8, s);
    }

    pub fn readOptU128(self: *Reader) DecodeError!?u128 {
        const tag = try self.readByte();
        if (tag == 0) return null;
        if (tag != 1) return error.InvalidData;
        return try self.readU128();
    }

    pub fn readOptU64(self: *Reader) DecodeError!?u64 {
        const tag = try self.readByte();
        if (tag == 0) return null;
        if (tag != 1) return error.InvalidData;
        return try self.readU64();
    }
};
