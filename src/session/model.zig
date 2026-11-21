const std = @import("std");
const Allocator = std.mem.Allocator;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const codec = @import("../store/codec.zig");
const iface = @import("../providers/interface.zig");

pub const MAX_SHORT_STR: usize = 4 * 1024;
pub const MAX_CONTENT_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_VERSION_HEADS: usize = 4096;

pub const Role = enum(u8) {
    user = 1,
    assistant = 2,
    system = 3,
    steer = 4,
};

pub const MessageStatus = enum(u8) {
    pending = 1,
    running = 2,
    completed = 3,
    interrupted = 4,
    failed = 5,
};

pub const SessionStatus = enum(u8) {
    idle = 0,
    running = 1,
    queued = 2,
    steering = 3,
    interrupted = 4,
    failed = 5,
};

pub const QueueKind = enum(u8) {
    follow_up = 1,
    steer = 2,
};

pub const QueueStatus = enum(u8) {
    pending = 1,
    dispatching = 2,
    injected = 3,
    completed = 4,
    cancelled = 5,
};

fn decodeEnum(comptime T: type, r: *codec.Reader) !T {
    const raw = try r.readU8();
    return std.enums.fromInt(T, raw) orelse return error.CorruptRecord;
}

pub fn decodeFlag(r: *codec.Reader) !bool {
    const raw = try r.readU8();
    return switch (raw) {
        0 => false,
        1 => true,
        else => error.CorruptRecord,
    };
}

fn readBytesCapped(r: *codec.Reader, max_len: usize) ![]const u8 {
    const len_u64 = try r.readVarint();
    if (len_u64 > max_len or len_u64 > r.remaining()) return error.CorruptRecord;
    const len: usize = @intCast(len_u64);
    const out = r.data[r.pos .. r.pos + len];
    r.pos += len;
    return out;
}

fn readOptBytesCapped(r: *codec.Reader, max_len: usize) !?[]const u8 {
    if (!try decodeFlag(r)) return null;
    return try readBytesCapped(r, max_len);
}

pub fn decodeVersionChecked(allocator: Allocator, r: *codec.Reader) !Version {
    const n_u64 = try r.readVarint();
    if (n_u64 > MAX_VERSION_HEADS) return error.CorruptRecord;
    const n: usize = @intCast(n_u64);
    if (n * 24 > r.remaining()) return error.CorruptRecord;
    var v = Version{};
    errdefer v.deinit(allocator);
    for (0..n) |_| {
        const ts = try r.readU64();
        const actor = try r.readU128();
        try v.insert(allocator, id.OpId.init(ts, actor));
    }
    return v;
}

pub const Thread = struct {
    thread_id: u128,
    worktree_id: u128,
    title: []u8,
    leaf_msg_id: ?u128,
    head_page: ?id.PageId,
    default_provider: iface.ProviderId,
    default_model: ?[]u8,
    status: SessionStatus,
    queued_count: u32,
    message_count: u32,
    created_ms: u64,
    updated_ms: u64,
    root_version: ?Version = null,

    pub fn deinit(self: *Thread, allocator: Allocator) void {
        allocator.free(self.title);
        if (self.default_model) |m| allocator.free(m);
        if (self.root_version) |*rv| rv.deinit(allocator);
    }

    pub fn clone(self: *const Thread, allocator: Allocator) Allocator.Error!Thread {
        const title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title);
        const default_model = if (self.default_model) |m| try allocator.dupe(u8, m) else null;
        errdefer if (default_model) |m| allocator.free(m);
        var root_version: ?Version = if (self.root_version) |*rv| try rv.clone(allocator) else null;
        errdefer if (root_version) |*rv| rv.deinit(allocator);
        return .{
            .thread_id = self.thread_id,
            .worktree_id = self.worktree_id,
            .title = title,
            .leaf_msg_id = self.leaf_msg_id,
            .head_page = self.head_page,
            .default_provider = self.default_provider,
            .default_model = default_model,
            .status = self.status,
            .queued_count = self.queued_count,
            .message_count = self.message_count,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
            .root_version = root_version,
        };
    }

    pub fn encode(self: *const Thread, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.thread_id);
        try w.writeU128(allocator, self.worktree_id);
        try w.writeBytes(allocator, self.title);
        try w.writeU8(allocator, if (self.leaf_msg_id != null) 1 else 0);
        if (self.leaf_msg_id) |lid| try w.writeU128(allocator, lid);
        try w.writeU8(allocator, if (self.head_page != null) 1 else 0);
        if (self.head_page) |hp| try w.writeRaw(allocator, &hp);
        try w.writeU8(allocator, @intFromEnum(self.default_provider));
        try w.writeOptBytes(allocator, self.default_model);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeU32(allocator, self.queued_count);
        try w.writeU32(allocator, self.message_count);
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
        try w.writeU8(allocator, if (self.root_version != null) 1 else 0);
        if (self.root_version) |*rv| try rv.encode(allocator, w);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !Thread {
        const tid = try r.readU128();
        const wid = try r.readU128();
        const title = try allocator.dupe(u8, try readBytesCapped(r, MAX_SHORT_STR));
        errdefer allocator.free(title);
        const has_leaf = try decodeFlag(r);
        const leaf: ?u128 = if (has_leaf) try r.readU128() else null;
        const has_page = try decodeFlag(r);
        const head_page: ?id.PageId = if (has_page) (try r.readFixed(32)).* else null;
        const prov = try decodeEnum(iface.ProviderId, r);
        const model_raw = try readOptBytesCapped(r, MAX_SHORT_STR);
        const model: ?[]u8 = if (model_raw) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        const status = try decodeEnum(SessionStatus, r);
        const queued = try r.readU32();
        const msg_count = try r.readU32();
        const created = try r.readU64();
        const updated = try r.readU64();
        var root_version: ?Version = null;
        errdefer if (root_version) |*rv| rv.deinit(allocator);
        if (r.remaining() > 0) {
            if (try decodeFlag(r)) {
                root_version = try decodeVersionChecked(allocator, r);
            }
        }
        return .{
            .thread_id = tid,
            .worktree_id = wid,
            .title = title,
            .leaf_msg_id = leaf,
            .head_page = head_page,
            .default_provider = prov,
            .default_model = model,
            .status = status,
            .queued_count = queued,
            .message_count = msg_count,
            .created_ms = created,
            .updated_ms = updated,
            .root_version = root_version,
        };
    }
};

pub const Message = struct {
    msg_id: u128,
    thread_id: u128,
    parent_id: ?u128,
    role: Role,
    content: []u8,
    provider: iface.ProviderId,
    model: ?[]u8,
    native_session: ?[]u8,
    native_turn: ?[]u8,
    pre_version: Version,
    post_version: Version,
    git_branch: ?[]u8,
    git_commit: ?[]u8,
    worktree_id: u128,
    status: MessageStatus,
    steer_of: ?u128,
    switched_from: ?u128,
    created_ms: u64,
    updated_ms: u64,
    err_msg: ?[]u8 = null,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        allocator.free(self.content);
        if (self.model) |m| allocator.free(m);
        if (self.native_session) |s| allocator.free(s);
        if (self.native_turn) |t| allocator.free(t);
        self.pre_version.deinit(allocator);
        self.post_version.deinit(allocator);
        if (self.git_branch) |b| allocator.free(b);
        if (self.git_commit) |c| allocator.free(c);
        if (self.err_msg) |e| allocator.free(e);
    }

    pub fn clone(self: *const Message, allocator: Allocator) Allocator.Error!Message {
        const content = try allocator.dupe(u8, self.content);
        errdefer allocator.free(content);
        const model = if (self.model) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        const ns = if (self.native_session) |s| try allocator.dupe(u8, s) else null;
        errdefer if (ns) |s| allocator.free(s);
        const nt = if (self.native_turn) |t| try allocator.dupe(u8, t) else null;
        errdefer if (nt) |t| allocator.free(t);
        var pre = try self.pre_version.clone(allocator);
        errdefer pre.deinit(allocator);
        var post = try self.post_version.clone(allocator);
        errdefer post.deinit(allocator);
        const gb = if (self.git_branch) |b| try allocator.dupe(u8, b) else null;
        errdefer if (gb) |b| allocator.free(b);
        const gc = if (self.git_commit) |c| try allocator.dupe(u8, c) else null;
        errdefer if (gc) |c| allocator.free(c);
        const em = if (self.err_msg) |e| try allocator.dupe(u8, e) else null;
        return .{
            .msg_id = self.msg_id,
            .thread_id = self.thread_id,
            .parent_id = self.parent_id,
            .role = self.role,
            .content = content,
            .provider = self.provider,
            .model = model,
            .native_session = ns,
            .native_turn = nt,
            .pre_version = pre,
            .post_version = post,
            .git_branch = gb,
            .git_commit = gc,
            .worktree_id = self.worktree_id,
            .status = self.status,
            .steer_of = self.steer_of,
            .switched_from = self.switched_from,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
            .err_msg = em,
        };
    }

    pub fn encode(self: *const Message, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.msg_id);
        try w.writeU128(allocator, self.thread_id);
        try w.writeU8(allocator, if (self.parent_id != null) 1 else 0);
        if (self.parent_id) |pid| try w.writeU128(allocator, pid);
        try w.writeU8(allocator, @intFromEnum(self.role));
        try w.writeBytes(allocator, self.content);
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeOptBytes(allocator, self.model);
        try w.writeOptBytes(allocator, self.native_session);
        try w.writeOptBytes(allocator, self.native_turn);
        try self.pre_version.encode(allocator, w);
        try self.post_version.encode(allocator, w);
        try w.writeOptBytes(allocator, self.git_branch);
        try w.writeOptBytes(allocator, self.git_commit);
        try w.writeU128(allocator, self.worktree_id);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeU8(allocator, if (self.steer_of != null) 1 else 0);
        if (self.steer_of) |so| try w.writeU128(allocator, so);
        try w.writeU8(allocator, if (self.switched_from != null) 1 else 0);
        if (self.switched_from) |sf| try w.writeU128(allocator, sf);
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
        try w.writeOptBytes(allocator, self.err_msg);
    }

    pub fn decodeEx(allocator: Allocator, r: *codec.Reader, has_ext: bool) !Message {
        const mid = try r.readU128();
        const tid = try r.readU128();
        const has_p = try decodeFlag(r);
        const pid: ?u128 = if (has_p) try r.readU128() else null;
        const role = try decodeEnum(Role, r);
        const content = try allocator.dupe(u8, try readBytesCapped(r, MAX_CONTENT_BYTES));
        errdefer allocator.free(content);
        const prov = try decodeEnum(iface.ProviderId, r);
        const model = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        const ns = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |s| try allocator.dupe(u8, s) else null;
        errdefer if (ns) |s| allocator.free(s);
        const nt = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |t| try allocator.dupe(u8, t) else null;
        errdefer if (nt) |t| allocator.free(t);
        var pre = try decodeVersionChecked(allocator, r);
        errdefer pre.deinit(allocator);
        var post = try decodeVersionChecked(allocator, r);
        errdefer post.deinit(allocator);
        const gb = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |b| try allocator.dupe(u8, b) else null;
        errdefer if (gb) |b| allocator.free(b);
        const gc = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |c| try allocator.dupe(u8, c) else null;
        errdefer if (gc) |c| allocator.free(c);
        const wid = try r.readU128();
        const status = try decodeEnum(MessageStatus, r);
        const has_so = try decodeFlag(r);
        const steer_of: ?u128 = if (has_so) try r.readU128() else null;
        const has_sf = try decodeFlag(r);
        const switched_from: ?u128 = if (has_sf) try r.readU128() else null;
        const created = try r.readU64();
        const updated = try r.readU64();
        const err_msg: ?[]u8 = if (has_ext)
            if (try readOptBytesCapped(r, MAX_CONTENT_BYTES)) |e| try allocator.dupe(u8, e) else null
        else
            null;
        return .{
            .msg_id = mid,
            .thread_id = tid,
            .parent_id = pid,
            .role = role,
            .content = content,
            .provider = prov,
            .model = model,
            .native_session = ns,
            .native_turn = nt,
            .pre_version = pre,
            .post_version = post,
            .git_branch = gb,
            .git_commit = gc,
            .worktree_id = wid,
            .status = status,
            .steer_of = steer_of,
            .switched_from = switched_from,
            .created_ms = created,
            .updated_ms = updated,
            .err_msg = err_msg,
        };
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !Message {
        var msg = try decodeEx(allocator, r, false);
        errdefer msg.deinit(allocator);
        if (r.remaining() > 0) {
            if (try readOptBytesCapped(r, MAX_CONTENT_BYTES)) |e| {
                msg.err_msg = try allocator.dupe(u8, e);
            }
        }
        return msg;
    }
};

pub const QueueItem = struct {
    item_id: u128,
    thread_id: u128,
    kind: QueueKind,
    status: QueueStatus,
    prompt: []u8,
    provider: iface.ProviderId,
    model: ?[]u8,
    target_turn_msg_id: ?u128,
    created_ms: u64,
    updated_ms: u64,

    pub fn deinit(self: *QueueItem, allocator: Allocator) void {
        allocator.free(self.prompt);
        if (self.model) |m| allocator.free(m);
    }

    pub fn clone(self: *const QueueItem, allocator: Allocator) Allocator.Error!QueueItem {
        const prompt = try allocator.dupe(u8, self.prompt);
        errdefer allocator.free(prompt);
        const model = if (self.model) |m| try allocator.dupe(u8, m) else null;
        return .{
            .item_id = self.item_id,
            .thread_id = self.thread_id,
            .kind = self.kind,
            .status = self.status,
            .prompt = prompt,
            .provider = self.provider,
            .model = model,
            .target_turn_msg_id = self.target_turn_msg_id,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn encode(self: *const QueueItem, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.item_id);
        try w.writeU128(allocator, self.thread_id);
        try w.writeU8(allocator, @intFromEnum(self.kind));
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeBytes(allocator, self.prompt);
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeOptBytes(allocator, self.model);
        try w.writeU8(allocator, if (self.target_turn_msg_id != null) 1 else 0);
        if (self.target_turn_msg_id) |t| try w.writeU128(allocator, t);
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !QueueItem {
        const iid = try r.readU128();
        const tid = try r.readU128();
        const kind = try decodeEnum(QueueKind, r);
        const status = try decodeEnum(QueueStatus, r);
        const prompt = try allocator.dupe(u8, try readBytesCapped(r, MAX_CONTENT_BYTES));
        errdefer allocator.free(prompt);
        const prov = try decodeEnum(iface.ProviderId, r);
        const model = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        const has_t = try decodeFlag(r);
        const target: ?u128 = if (has_t) try r.readU128() else null;
        const created = try r.readU64();
        const updated = try r.readU64();
        return .{
            .item_id = iid,
            .thread_id = tid,
            .kind = kind,
            .status = status,
            .prompt = prompt,
            .provider = prov,
            .model = model,
            .target_turn_msg_id = target,
            .created_ms = created,
            .updated_ms = updated,
        };
    }
};

pub const RollbackIntent = struct {
    intent_id: u128,
    thread_id: u128,
    target_msg_id: ?u128,
    target_version: Version,
    target_git_commit: ?[]u8,
    created_ms: u64,
    target_git_branch: ?[]u8 = null,

    pub fn deinit(self: *RollbackIntent, allocator: Allocator) void {
        self.target_version.deinit(allocator);
        if (self.target_git_commit) |c| allocator.free(c);
        if (self.target_git_branch) |b| allocator.free(b);
    }

    pub fn encode(self: *const RollbackIntent, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.intent_id);
        try w.writeU128(allocator, self.thread_id);
        try w.writeU8(allocator, if (self.target_msg_id != null) 1 else 0);
        if (self.target_msg_id) |m| try w.writeU128(allocator, m);
        try self.target_version.encode(allocator, w);
        try w.writeOptBytes(allocator, self.target_git_commit);
        try w.writeU64(allocator, self.created_ms);
        try w.writeOptBytes(allocator, self.target_git_branch);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !RollbackIntent {
        const iid = try r.readU128();
        const tid = try r.readU128();
        const has_m = try decodeFlag(r);
        const target_msg: ?u128 = if (has_m) try r.readU128() else null;
        var tv = try decodeVersionChecked(allocator, r);
        errdefer tv.deinit(allocator);
        const gc = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |c| try allocator.dupe(u8, c) else null;
        errdefer if (gc) |c| allocator.free(c);
        const created = try r.readU64();
        var gb: ?[]u8 = null;
        errdefer if (gb) |b| allocator.free(b);
        if (r.remaining() > 0) {
            if (try readOptBytesCapped(r, MAX_SHORT_STR)) |b| {
                gb = try allocator.dupe(u8, b);
            }
        }
        return .{
            .intent_id = iid,
            .thread_id = tid,
            .target_msg_id = target_msg,
            .target_version = tv,
            .target_git_commit = gc,
            .created_ms = created,
            .target_git_branch = gb,
        };
    }
};

pub const SessionSummary = struct {
    thread_id: u128,
    worktree_id: u128,
    title: []u8,
    provider: iface.ProviderId,
    model: ?[]u8,
    status: SessionStatus,
    leaf_msg_id: ?u128,
    head_page: ?id.PageId,
    queued_count: u32,
    message_count: u32,
    updated_ms: u64,

    pub fn deinit(self: *SessionSummary, allocator: Allocator) void {
        allocator.free(self.title);
        if (self.model) |m| allocator.free(m);
    }

    pub fn fromThread(allocator: Allocator, t: *const Thread) Allocator.Error!SessionSummary {
        const title = try allocator.dupe(u8, t.title);
        errdefer allocator.free(title);
        const model = if (t.default_model) |m| try allocator.dupe(u8, m) else null;
        return .{
            .thread_id = t.thread_id,
            .worktree_id = t.worktree_id,
            .title = title,
            .provider = t.default_provider,
            .model = model,
            .status = t.status,
            .leaf_msg_id = t.leaf_msg_id,
            .head_page = t.head_page,
            .queued_count = t.queued_count,
            .message_count = t.message_count,
            .updated_ms = t.updated_ms,
        };
    }

    pub fn encode(self: *const SessionSummary, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.thread_id);
        try w.writeU128(allocator, self.worktree_id);
        try w.writeBytes(allocator, self.title);
        try w.writeU8(allocator, @intFromEnum(self.provider));
        try w.writeOptBytes(allocator, self.model);
        try w.writeU8(allocator, @intFromEnum(self.status));
        try w.writeU8(allocator, if (self.leaf_msg_id != null) 1 else 0);
        if (self.leaf_msg_id) |lid| try w.writeU128(allocator, lid);
        try w.writeU8(allocator, if (self.head_page != null) 1 else 0);
        if (self.head_page) |hp| try w.writeRaw(allocator, &hp);
        try w.writeU32(allocator, self.queued_count);
        try w.writeU32(allocator, self.message_count);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !SessionSummary {
        const tid = try r.readU128();
        const wid = try r.readU128();
        const title = try allocator.dupe(u8, try readBytesCapped(r, MAX_SHORT_STR));
        errdefer allocator.free(title);
        const prov = try decodeEnum(iface.ProviderId, r);
        const model = if (try readOptBytesCapped(r, MAX_SHORT_STR)) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model) |m| allocator.free(m);
        const status = try decodeEnum(SessionStatus, r);
        const has_l = try decodeFlag(r);
        const leaf: ?u128 = if (has_l) try r.readU128() else null;
        const has_p = try decodeFlag(r);
        const hp: ?id.PageId = if (has_p) (try r.readFixed(32)).* else null;
        const queued = try r.readU32();
        const msg_count = try r.readU32();
        const updated = try r.readU64();
        return .{
            .thread_id = tid,
            .worktree_id = wid,
            .title = title,
            .provider = prov,
            .model = model,
            .status = status,
            .leaf_msg_id = leaf,
            .head_page = hp,
            .queued_count = queued,
            .message_count = msg_count,
            .updated_ms = updated,
        };
    }
};

pub const PageResult = struct {
    messages: []Message,
    has_more: bool,
    next_before: ?u128,
    head_page: ?id.PageId,

    pub fn deinit(self: *PageResult, allocator: Allocator) void {
        for (self.messages) |*m| m.deinit(allocator);
        allocator.free(self.messages);
    }
};

pub const ToolCallRecord = struct {
    msg_id: u128,
    call_id: []u8,
    name: []u8,
    input_json: []u8,
    output: []u8,
    is_error: bool,

    pub fn deinit(self: *ToolCallRecord, allocator: Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.name);
        allocator.free(self.input_json);
        allocator.free(self.output);
    }

    pub fn clone(self: *const ToolCallRecord, allocator: Allocator) Allocator.Error!ToolCallRecord {
        const cid = try allocator.dupe(u8, self.call_id);
        errdefer allocator.free(cid);
        const nm = try allocator.dupe(u8, self.name);
        errdefer allocator.free(nm);
        const inp = try allocator.dupe(u8, self.input_json);
        errdefer allocator.free(inp);
        const out = try allocator.dupe(u8, self.output);
        return .{
            .msg_id = self.msg_id,
            .call_id = cid,
            .name = nm,
            .input_json = inp,
            .output = out,
            .is_error = self.is_error,
        };
    }

    pub fn encode(self: *const ToolCallRecord, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.msg_id);
        try w.writeBytes(allocator, self.call_id);
        try w.writeBytes(allocator, self.name);
        try w.writeBytes(allocator, self.input_json);
        try w.writeBytes(allocator, self.output);
        try w.writeU8(allocator, if (self.is_error) 1 else 0);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) !ToolCallRecord {
        const mid = try r.readU128();
        const cid = try allocator.dupe(u8, try readBytesCapped(r, MAX_SHORT_STR));
        errdefer allocator.free(cid);
        const nm = try allocator.dupe(u8, try readBytesCapped(r, MAX_SHORT_STR));
        errdefer allocator.free(nm);
        const inp = try allocator.dupe(u8, try readBytesCapped(r, MAX_CONTENT_BYTES));
        errdefer allocator.free(inp);
        const out = try allocator.dupe(u8, try readBytesCapped(r, MAX_CONTENT_BYTES));
        errdefer allocator.free(out);
        const is_err = try decodeFlag(r);
        return .{
            .msg_id = mid,
            .call_id = cid,
            .name = nm,
            .input_json = inp,
            .output = out,
            .is_error = is_err,
        };
    }
};
