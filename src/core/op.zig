const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("id.zig");
const dag = @import("dag.zig");
const diff = @import("diff.zig");
const tree = @import("tree.zig");
const codec = @import("codec.zig");

pub const INLINE_TEXT_MAX: usize = 4096;
pub const MAX_OPS_PER_BATCH: usize = 1 << 20;
pub const MAX_BLOBS_PER_BATCH: usize = 1 << 16;
pub const MAX_SPLICES_PER_OP: usize = 1 << 20;

fn encodeGitBlobRef(allocator: Allocator, w: *codec.Writer, r: tree.GitBlobRef) Allocator.Error!void {
    try w.writeByte(allocator, r.oid.len);
    try w.writeRaw(allocator, r.oid.slice());
    try w.writeVarint(allocator, r.len);
}

fn decodeGitBlobRef(r: *codec.Reader) codec.DecodeError!tree.GitBlobRef {
    const oid_len = try r.readByte();
    const oid = switch (oid_len) {
        20 => id.GitOid.fromSlice(try r.readFixed(20)) catch return error.InvalidData,
        32 => id.GitOid.fromSlice(try r.readFixed(32)) catch return error.InvalidData,
        else => return error.InvalidData,
    };
    const len = try r.readVarint();
    return .{ .oid = oid, .len = len };
}

pub const Content = union(enum) {
    text_inline: []u8,
    text_blob: tree.BlobRef,
    binary: tree.BlobRef,
    git_text_blob: tree.GitBlobRef,
    git_binary: tree.GitBlobRef,
    git_lazy: tree.GitBlobRef,

    pub fn deinit(self: *Content, allocator: Allocator) void {
        switch (self.*) {
            .text_inline => |b| allocator.free(b),
            else => {},
        }
    }

    pub fn clone(self: *const Content, allocator: Allocator) Allocator.Error!Content {
        return switch (self.*) {
            .text_inline => |b| .{ .text_inline = try allocator.dupe(u8, b) },
            .text_blob => |r| .{ .text_blob = r },
            .binary => |r| .{ .binary = r },
            .git_text_blob => |r| .{ .git_text_blob = r },
            .git_binary => |r| .{ .git_binary = r },
            .git_lazy => |r| .{ .git_lazy = r },
        };
    }

    pub fn encode(self: *const Content, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        switch (self.*) {
            .text_inline => |b| {
                try w.writeByte(allocator, 0);
                try w.writeBytes(allocator, b);
            },
            .text_blob => |r| {
                try w.writeByte(allocator, 1);
                try w.writeRaw(allocator, &r.oid);
                try w.writeU64(allocator, r.len);
            },
            .binary => |r| {
                try w.writeByte(allocator, 2);
                try w.writeRaw(allocator, &r.oid);
                try w.writeU64(allocator, r.len);
            },
            .git_text_blob => |r| {
                try w.writeByte(allocator, 3);
                try encodeGitBlobRef(allocator, w, r);
            },
            .git_binary => |r| {
                try w.writeByte(allocator, 4);
                try encodeGitBlobRef(allocator, w, r);
            },
            .git_lazy => |r| {
                try w.writeByte(allocator, 5);
                try encodeGitBlobRef(allocator, w, r);
            },
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!Content {
        const tag = try r.readByte();
        return switch (tag) {
            0 => .{ .text_inline = try r.readBytesAlloc(allocator) },
            1 => .{ .text_blob = .{ .oid = (try r.readFixed(32)).*, .len = try r.readU64() } },
            2 => .{ .binary = .{ .oid = (try r.readFixed(32)).*, .len = try r.readU64() } },
            3 => .{ .git_text_blob = try decodeGitBlobRef(r) },
            4 => .{ .git_binary = try decodeGitBlobRef(r) },
            5 => .{ .git_lazy = try decodeGitBlobRef(r) },
            else => error.InvalidData,
        };
    }
};

pub const Op = union(enum) {
    create_dir: struct { parent: id.InodeId, name: []u8 },
    create_file: struct { parent: id.InodeId, name: []u8, mode: tree.FileMode, line_ending: tree.LineEnding, content: Content },
    create_symlink: struct { parent: id.InodeId, name: []u8, target: []u8 },
    rename: struct { inode: id.InodeId, parent: id.InodeId, name: []u8 },
    remove: struct { inode: id.InodeId },
    restore: struct { inode: id.InodeId },
    edit_text: struct { inode: id.InodeId, text: []u8, splices: []diff.Splice },
    set_content: struct { inode: id.InodeId, content: Content },
    set_mode: struct { inode: id.InodeId, mode: tree.FileMode },
    set_line_ending: struct { inode: id.InodeId, ending: tree.LineEnding },
    set_symlink_target: struct { inode: id.InodeId, target: []u8 },
    git_checkout: struct { from: ?[]u8, to: []u8 },
    meta: struct { key: []u8, value: ?[]u8 },

    pub fn deinit(self: *Op, allocator: Allocator) void {
        switch (self.*) {
            .create_dir => |*v| allocator.free(v.name),
            .create_file => |*v| {
                allocator.free(v.name);
                v.content.deinit(allocator);
            },
            .create_symlink => |*v| {
                allocator.free(v.name);
                allocator.free(v.target);
            },
            .rename => |*v| allocator.free(v.name),
            .remove, .restore, .set_mode, .set_line_ending => {},
            .edit_text => |*v| {
                allocator.free(v.text);
                allocator.free(v.splices);
            },
            .set_content => |*v| v.content.deinit(allocator),
            .set_symlink_target => |*v| allocator.free(v.target),
            .git_checkout => |*v| {
                if (v.from) |f| allocator.free(f);
                allocator.free(v.to);
            },
            .meta => |*v| {
                allocator.free(v.key);
                if (v.value) |val| allocator.free(val);
            },
        }
    }

    pub fn encode(self: *const Op, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        switch (self.*) {
            .create_dir => |v| {
                try w.writeByte(allocator, 1);
                try writeInodeId(allocator, w, v.parent);
                try w.writeBytes(allocator, v.name);
            },
            .create_file => |v| {
                try w.writeByte(allocator, 2);
                try writeInodeId(allocator, w, v.parent);
                try w.writeBytes(allocator, v.name);
                try w.writeByte(allocator, @backingInt(v.mode));
                try w.writeByte(allocator, @backingInt(v.line_ending));
                try v.content.encode(allocator, w);
            },
            .create_symlink => |v| {
                try w.writeByte(allocator, 3);
                try writeInodeId(allocator, w, v.parent);
                try w.writeBytes(allocator, v.name);
                try w.writeBytes(allocator, v.target);
            },
            .rename => |v| {
                try w.writeByte(allocator, 4);
                try writeInodeId(allocator, w, v.inode);
                try writeInodeId(allocator, w, v.parent);
                try w.writeBytes(allocator, v.name);
            },
            .remove => |v| {
                try w.writeByte(allocator, 5);
                try writeInodeId(allocator, w, v.inode);
            },
            .restore => |v| {
                try w.writeByte(allocator, 6);
                try writeInodeId(allocator, w, v.inode);
            },
            .edit_text => |v| {
                try w.writeByte(allocator, 7);
                try writeInodeId(allocator, w, v.inode);
                try w.writeBytes(allocator, v.text);
                try w.writeVarint(allocator, v.splices.len);
                for (v.splices) |s| {
                    try w.writeVarint(allocator, s.at);
                    try w.writeVarint(allocator, s.del);
                    try w.writeVarint(allocator, s.ins);
                }
            },
            .set_content => |v| {
                try w.writeByte(allocator, 8);
                try writeInodeId(allocator, w, v.inode);
                try v.content.encode(allocator, w);
            },
            .set_mode => |v| {
                try w.writeByte(allocator, 9);
                try writeInodeId(allocator, w, v.inode);
                try w.writeByte(allocator, @backingInt(v.mode));
            },
            .set_line_ending => |v| {
                try w.writeByte(allocator, 10);
                try writeInodeId(allocator, w, v.inode);
                try w.writeByte(allocator, @backingInt(v.ending));
            },
            .set_symlink_target => |v| {
                try w.writeByte(allocator, 11);
                try writeInodeId(allocator, w, v.inode);
                try w.writeBytes(allocator, v.target);
            },
            .git_checkout => |v| {
                try w.writeByte(allocator, 12);
                try w.writeOptBytes(allocator, v.from);
                try w.writeBytes(allocator, v.to);
            },
            .meta => |v| {
                try w.writeByte(allocator, 13);
                try w.writeBytes(allocator, v.key);
                try w.writeOptBytes(allocator, v.value);
            },
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!Op {
        const tag = try r.readByte();
        return switch (tag) {
            1 => .{ .create_dir = .{ .parent = try readInodeId(r), .name = try r.readBytesAlloc(allocator) } },
            2 => blk: {
                const parent = try readInodeId(r);
                const name = try r.readBytesAlloc(allocator);
                errdefer allocator.free(name);
                const mode = std.enums.fromInt(tree.FileMode, try r.readByte()) orelse return error.InvalidData;
                const le = std.enums.fromInt(tree.LineEnding, try r.readByte()) orelse return error.InvalidData;
                const content = try Content.decode(allocator, r);
                break :blk .{ .create_file = .{ .parent = parent, .name = name, .mode = mode, .line_ending = le, .content = content } };
            },
            3 => blk: {
                const parent = try readInodeId(r);
                const name = try r.readBytesAlloc(allocator);
                errdefer allocator.free(name);
                const target = try r.readBytesAlloc(allocator);
                break :blk .{ .create_symlink = .{ .parent = parent, .name = name, .target = target } };
            },
            4 => .{ .rename = .{ .inode = try readInodeId(r), .parent = try readInodeId(r), .name = try r.readBytesAlloc(allocator) } },
            5 => .{ .remove = .{ .inode = try readInodeId(r) } },
            6 => .{ .restore = .{ .inode = try readInodeId(r) } },
            7 => blk: {
                const inode = try readInodeId(r);
                const txt = try r.readBytesAlloc(allocator);
                errdefer allocator.free(txt);
                const n_u64 = try r.readVarint();
                if (n_u64 > MAX_SPLICES_PER_OP) return error.InvalidData;
                const n: usize = @intCast(n_u64);
                if (n > r.remaining() / 3) return error.UnexpectedEof;
                const splices = try allocator.alloc(diff.Splice, n);
                errdefer allocator.free(splices);
                for (splices) |*s| {
                    s.* = .{
                        .at = try r.readVarint(),
                        .del = try r.readVarint(),
                        .ins = try r.readVarint(),
                    };
                }
                break :blk .{ .edit_text = .{ .inode = inode, .text = txt, .splices = splices } };
            },
            8 => .{ .set_content = .{ .inode = try readInodeId(r), .content = try Content.decode(allocator, r) } },
            9 => .{ .set_mode = .{ .inode = try readInodeId(r), .mode = std.enums.fromInt(tree.FileMode, try r.readByte()) orelse return error.InvalidData } },
            10 => .{ .set_line_ending = .{ .inode = try readInodeId(r), .ending = std.enums.fromInt(tree.LineEnding, try r.readByte()) orelse return error.InvalidData } },
            11 => .{ .set_symlink_target = .{ .inode = try readInodeId(r), .target = try r.readBytesAlloc(allocator) } },
            12 => blk: {
                const from = try r.readOptBytesAlloc(allocator);
                errdefer if (from) |f| allocator.free(f);
                const to = try r.readBytesAlloc(allocator);
                break :blk .{ .git_checkout = .{ .from = from, .to = to } };
            },
            13 => blk: {
                const key = try r.readBytesAlloc(allocator);
                errdefer allocator.free(key);
                const val = try r.readOptBytesAlloc(allocator);
                break :blk .{ .meta = .{ .key = key, .value = val } };
            },
            else => error.InvalidData,
        };
    }
};

pub const PayloadSpan = struct {
    op_index: u32,
    offset: u32,
    len: u32,
};

pub const BlobSpan = struct {
    oid: id.Oid,
    offset: u32,
    len: u32,
};

pub const BlobAttachment = struct {
    oid: id.Oid,
    data: []u8,

    pub fn deinit(self: *BlobAttachment, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub const Batch = struct {
    header: dag.BatchHeader,
    ops: []Op,
    blobs: []BlobAttachment,

    pub fn deinit(self: *Batch, allocator: Allocator) void {
        self.header.deinit(allocator);
        for (self.ops) |*o| o.deinit(allocator);
        allocator.free(self.ops);
        for (self.blobs) |*b| b.deinit(allocator);
        allocator.free(self.blobs);
    }

    pub fn encode(self: *const Batch, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try self.header.encode(allocator, w);
        try w.writeVarint(allocator, self.ops.len);
        for (self.ops) |*o| try o.encode(allocator, w);
        try w.writeVarint(allocator, self.blobs.len);
        for (self.blobs) |b| {
            try w.writeRaw(allocator, &b.oid);
            try w.writeBytes(allocator, b.data);
        }
    }

    pub fn encodeWithSpans(
        self: *const Batch,
        allocator: Allocator,
        w: *codec.Writer,
        op_spans: *std.ArrayList(PayloadSpan),
        blob_spans: *std.ArrayList(BlobSpan),
    ) Allocator.Error!void {
        const base_pos = w.items().len;
        try self.header.encode(allocator, w);
        try w.writeVarint(allocator, self.ops.len);
        for (self.ops, 0..) |*o, idx| {
            switch (o.*) {
                .create_file => |v| {
                    try w.writeByte(allocator, 2);
                    try writeInodeId(allocator, w, v.parent);
                    try w.writeBytes(allocator, v.name);
                    try w.writeByte(allocator, @backingInt(v.mode));
                    try w.writeByte(allocator, @backingInt(v.line_ending));
                    try v.content.encode(allocator, w);
                    switch (v.content) {
                        .text_inline => |b| {
                            if (b.len > 0) {
                                const end_rel = w.items().len - base_pos;
                                try op_spans.append(allocator, .{
                                    .op_index = @intCast(idx),
                                    .offset = @intCast(end_rel - b.len),
                                    .len = @intCast(b.len),
                                });
                            }
                        },
                        else => {},
                    }
                },
                .edit_text => |v| {
                    try w.writeByte(allocator, 7);
                    try writeInodeId(allocator, w, v.inode);
                    try w.writeBytes(allocator, v.text);
                    if (v.text.len > 0) {
                        const end_rel = w.items().len - base_pos;
                        try op_spans.append(allocator, .{
                            .op_index = @intCast(idx),
                            .offset = @intCast(end_rel - v.text.len),
                            .len = @intCast(v.text.len),
                        });
                    }
                    try w.writeVarint(allocator, v.splices.len);
                    for (v.splices) |s| {
                        try w.writeVarint(allocator, s.at);
                        try w.writeVarint(allocator, s.del);
                        try w.writeVarint(allocator, s.ins);
                    }
                },
                .set_content => |v| {
                    try w.writeByte(allocator, 8);
                    try writeInodeId(allocator, w, v.inode);
                    try v.content.encode(allocator, w);
                    switch (v.content) {
                        .text_inline => |b| {
                            if (b.len > 0) {
                                const end_rel = w.items().len - base_pos;
                                try op_spans.append(allocator, .{
                                    .op_index = @intCast(idx),
                                    .offset = @intCast(end_rel - b.len),
                                    .len = @intCast(b.len),
                                });
                            }
                        },
                        else => {},
                    }
                },
                else => try o.encode(allocator, w),
            }
        }
        try w.writeVarint(allocator, self.blobs.len);
        for (self.blobs) |b| {
            try w.writeRaw(allocator, &b.oid);
            try w.writeBytes(allocator, b.data);
            if (b.data.len > 0) {
                const end_rel = w.items().len - base_pos;
                try blob_spans.append(allocator, .{
                    .oid = b.oid,
                    .offset = @intCast(end_rel - b.data.len),
                    .len = @intCast(b.data.len),
                });
            }
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!Batch {
        var header = try dag.BatchHeader.decode(allocator, r);
        errdefer header.deinit(allocator);

        const op_n_u64 = try r.readVarint();
        if (op_n_u64 > MAX_OPS_PER_BATCH) return error.InvalidData;
        const op_n: usize = @intCast(op_n_u64);
        if (op_n > r.remaining() / 3) return error.UnexpectedEof;
        const ops = try allocator.alloc(Op, op_n);
        var ops_done: usize = 0;
        errdefer {
            for (ops[0..ops_done]) |*o| o.deinit(allocator);
            allocator.free(ops);
        }
        while (ops_done < op_n) : (ops_done += 1) {
            ops[ops_done] = try Op.decode(allocator, r);
        }

        const blob_n_u64 = try r.readVarint();
        if (blob_n_u64 > MAX_BLOBS_PER_BATCH) return error.InvalidData;
        const blob_n: usize = @intCast(blob_n_u64);
        if (blob_n > r.remaining() / 33) return error.UnexpectedEof;
        const blobs = try allocator.alloc(BlobAttachment, blob_n);
        var blobs_done: usize = 0;
        errdefer {
            for (blobs[0..blobs_done]) |*b| b.deinit(allocator);
            allocator.free(blobs);
        }
        while (blobs_done < blob_n) : (blobs_done += 1) {
            const oid = (try r.readFixed(32)).*;
            const data = try r.readBytesAlloc(allocator);
            blobs[blobs_done] = .{ .oid = oid, .data = data };
        }

        return .{ .header = header, .ops = ops, .blobs = blobs };
    }

    pub fn decodeWithSpans(
        allocator: Allocator,
        r: *codec.Reader,
        op_spans: *std.ArrayList(PayloadSpan),
        blob_spans: *std.ArrayList(BlobSpan),
    ) (codec.DecodeError || Allocator.Error)!Batch {
        const base_pos = r.pos;
        const init_op_spans = op_spans.items.len;
        const init_blob_spans = blob_spans.items.len;
        errdefer {
            op_spans.items.len = init_op_spans;
            blob_spans.items.len = init_blob_spans;
        }
        var header = try dag.BatchHeader.decode(allocator, r);
        errdefer header.deinit(allocator);

        const op_n_u64 = try r.readVarint();
        if (op_n_u64 > MAX_OPS_PER_BATCH) return error.InvalidData;
        const op_n: usize = @intCast(op_n_u64);
        if (op_n > r.remaining() / 3) return error.UnexpectedEof;
        const ops = try allocator.alloc(Op, op_n);
        var ops_done: usize = 0;
        errdefer {
            for (ops[0..ops_done]) |*o| o.deinit(allocator);
            allocator.free(ops);
        }
        while (ops_done < op_n) : (ops_done += 1) {
            const start_op_pos = r.pos;
            const tag = try r.readByte();
            if (tag == 7) {
                const inode = try readInodeId(r);
                const txt = try r.readBytesAlloc(allocator);
                errdefer allocator.free(txt);
                const txt_end_rel = r.pos - base_pos;
                const n_u64 = try r.readVarint();
                if (n_u64 > MAX_SPLICES_PER_OP) return error.InvalidData;
                const n: usize = @intCast(n_u64);
                if (n > r.remaining() / 3) return error.UnexpectedEof;
                const splices = try allocator.alloc(diff.Splice, n);
                errdefer allocator.free(splices);
                for (splices) |*s| {
                    s.* = .{
                        .at = try r.readVarint(),
                        .del = try r.readVarint(),
                        .ins = try r.readVarint(),
                    };
                }
                if (txt.len > 0) {
                    try op_spans.append(allocator, .{
                        .op_index = @intCast(ops_done),
                        .offset = @intCast(txt_end_rel - txt.len),
                        .len = @intCast(txt.len),
                    });
                }
                ops[ops_done] = .{ .edit_text = .{ .inode = inode, .text = txt, .splices = splices } };
            } else {
                r.pos = start_op_pos;
                var op = try Op.decode(allocator, r);
                errdefer op.deinit(allocator);
                switch (op) {
                    .create_file => |v| switch (v.content) {
                        .text_inline => |b| {
                            if (b.len > 0) {
                                const end_rel = r.pos - base_pos;
                                try op_spans.append(allocator, .{
                                    .op_index = @intCast(ops_done),
                                    .offset = @intCast(end_rel - b.len),
                                    .len = @intCast(b.len),
                                });
                            }
                        },
                        else => {},
                    },
                    .set_content => |v| switch (v.content) {
                        .text_inline => |b| {
                            if (b.len > 0) {
                                const end_rel = r.pos - base_pos;
                                try op_spans.append(allocator, .{
                                    .op_index = @intCast(ops_done),
                                    .offset = @intCast(end_rel - b.len),
                                    .len = @intCast(b.len),
                                });
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
                ops[ops_done] = op;
            }
        }

        const blob_n_u64 = try r.readVarint();
        if (blob_n_u64 > MAX_BLOBS_PER_BATCH) return error.InvalidData;
        const blob_n: usize = @intCast(blob_n_u64);
        if (blob_n > r.remaining() / 33) return error.UnexpectedEof;
        const blobs = try allocator.alloc(BlobAttachment, blob_n);
        var blobs_done: usize = 0;
        errdefer {
            for (blobs[0..blobs_done]) |*b| b.deinit(allocator);
            allocator.free(blobs);
        }
        while (blobs_done < blob_n) : (blobs_done += 1) {
            const oid = (try r.readFixed(32)).*;
            const data = try r.readBytesAlloc(allocator);
            errdefer allocator.free(data);
            if (data.len > 0) {
                const end_rel = r.pos - base_pos;
                try blob_spans.append(allocator, .{
                    .oid = oid,
                    .offset = @intCast(end_rel - data.len),
                    .len = @intCast(data.len),
                });
            }
            blobs[blobs_done] = .{ .oid = oid, .data = data };
        }

        return .{ .header = header, .ops = ops, .blobs = blobs };
    }
};

pub fn makeTextContent(allocator: Allocator, bytes: []const u8) Allocator.Error!struct { Content, ?BlobAttachment } {
    if (bytes.len <= INLINE_TEXT_MAX) {
        return .{ .{ .text_inline = try allocator.dupe(u8, bytes) }, null };
    }
    const oid = id.hashBytes(bytes);
    const data = try allocator.dupe(u8, bytes);
    return .{
        .{ .text_blob = .{ .oid = oid, .len = bytes.len } },
        .{ .oid = oid, .data = data },
    };
}

fn writeInodeId(allocator: Allocator, w: *codec.Writer, iid: id.InodeId) Allocator.Error!void {
    try w.writeU64(allocator, iid.op.ts);
    try w.writeU128(allocator, iid.op.actor);
    try w.writeU32(allocator, iid.part);
}

fn readInodeId(r: *codec.Reader) codec.DecodeError!id.InodeId {
    const ts = try r.readU64();
    const actor = try r.readU128();
    const part = try r.readU32();
    return id.InodeId.init(id.OpId.init(ts, actor), part);
}
