const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("../core/id.zig");
const codec = @import("../store/codec.zig");
const blobs_mod = @import("../store/blobs.zig");
const model = @import("model.zig");

pub const PAGE_MAGIC = [4]u8{ '0', 'P', 'A', 'G' };
pub const PAGE_VERSION: u8 = 2;
pub const DEFAULT_PAGE_SIZE: usize = 32;
pub const MAX_PAGE_MESSAGES: usize = 4096;
const MIN_ENCODED_MSG_BYTES: usize = 64;

pub const MessagePage = struct {
    thread_id: u128,
    prev_page: ?id.PageId,
    head_msg_id: ?u128,
    messages: []model.Message,

    pub fn deinit(self: *MessagePage, allocator: Allocator) void {
        for (self.messages) |*m| m.deinit(allocator);
        allocator.free(self.messages);
    }

    pub fn encode(self: *const MessagePage, allocator: Allocator) Allocator.Error![]u8 {
        var w = codec.Writer{};
        defer w.deinit(allocator);
        try w.writeRaw(allocator, &PAGE_MAGIC);
        try w.writeU8(allocator, PAGE_VERSION);
        try w.writeU128(allocator, self.thread_id);
        try w.writeU8(allocator, if (self.prev_page != null) 1 else 0);
        if (self.prev_page) |p| try w.writeRaw(allocator, &p);
        try w.writeU8(allocator, if (self.head_msg_id != null) 1 else 0);
        if (self.head_msg_id) |h| try w.writeU128(allocator, h);
        try w.writeU32(allocator, @intCast(self.messages.len));
        for (self.messages) |*m| {
            try m.encode(allocator, &w);
        }
        return try w.buf.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: Allocator, bytes: []const u8) !MessagePage {
        var r = codec.Reader.init(bytes);
        const magic = try r.readFixed(4);
        if (!std.mem.eql(u8, magic, &PAGE_MAGIC)) return error.InvalidPageMagic;
        const ver = try r.readU8();
        if (ver != 1 and ver != PAGE_VERSION) return error.UnsupportedPageVersion;
        const tid = try r.readU128();
        const has_prev = try model.decodeFlag(&r);
        const prev: ?id.PageId = if (has_prev) (try r.readFixed(32)).* else null;
        const has_head = try model.decodeFlag(&r);
        const head: ?u128 = if (has_head) try r.readU128() else null;
        const count = try r.readU32();
        if (count > MAX_PAGE_MESSAGES) return error.CorruptRecord;
        const count_usize: usize = @intCast(count);
        if (count_usize * MIN_ENCODED_MSG_BYTES > r.remaining()) return error.CorruptRecord;
        const msgs = try allocator.alloc(model.Message, count_usize);
        var decoded: usize = 0;
        errdefer {
            for (msgs[0..decoded]) |*m| m.deinit(allocator);
            allocator.free(msgs);
        }
        for (0..count_usize) |i| {
            msgs[i] = try model.Message.decodeEx(allocator, &r, ver >= 2);
            decoded += 1;
        }
        return .{
            .thread_id = tid,
            .prev_page = prev,
            .head_msg_id = head,
            .messages = msgs,
        };
    }
};

pub fn sealPage(
    allocator: Allocator,
    store: *blobs_mod.BlobStore,
    thread_id: u128,
    prev_page: ?id.PageId,
    messages: []const model.Message,
) !id.PageId {
    const head_id: ?u128 = if (messages.len > 0) messages[messages.len - 1].msg_id else null;
    const page = MessagePage{
        .thread_id = thread_id,
        .prev_page = prev_page,
        .head_msg_id = head_id,
        .messages = @constCast(messages),
    };
    const encoded = try page.encode(allocator);
    defer allocator.free(encoded);
    return try store.put(encoded);
}

pub fn loadPage(
    allocator: Allocator,
    store: *blobs_mod.BlobStore,
    page_id: id.PageId,
) !?MessagePage {
    const raw = try store.get(allocator, page_id) orelse return null;
    defer allocator.free(raw);
    return try MessagePage.decode(allocator, raw);
}

pub fn sealBranchChain(
    allocator: Allocator,
    store: *blobs_mod.BlobStore,
    thread_id: u128,
    branch_messages: []const model.Message,
    page_size: usize,
) !?id.PageId {
    if (branch_messages.len == 0) return null;
    const chunk = if (page_size == 0) DEFAULT_PAGE_SIZE else @min(page_size, MAX_PAGE_MESSAGES);
    var prev: ?id.PageId = null;
    var off: usize = 0;
    while (off < branch_messages.len) {
        const end = @min(off + chunk, branch_messages.len);
        prev = try sealPage(allocator, store, thread_id, prev, branch_messages[off..end]);
        off = end;
    }
    return prev;
}
