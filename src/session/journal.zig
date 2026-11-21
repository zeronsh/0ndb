const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const codec = @import("../store/codec.zig");
const log_mod = @import("../store/log.zig");
const blobs_mod = @import("../store/blobs.zig");
const model = @import("model.zig");

pub const REC_THREAD_UPSERT: u8 = 1;
pub const REC_MSG_APPEND: u8 = 2;
pub const REC_MSG_UPDATE: u8 = 3;
pub const REC_BRANCH_CHOICE: u8 = 4;
pub const REC_QUEUE_UPSERT: u8 = 5;
pub const REC_ROLLBACK_BEGIN: u8 = 6;
pub const REC_ROLLBACK_COMMIT: u8 = 7;
pub const REC_SUMMARY_DELTA: u8 = 8;
pub const REC_TOOL_CALL: u8 = 9;

pub const BranchKey = struct {
    thread_id: u128,
    parent_msg_id: u128,
};

pub const SessionJournal = struct {
    allocator: Allocator,
    io: Io,
    state_dir: Io.Dir,
    wal: log_mod.AppendLog,
    pages: blobs_mod.BlobStore,
    threads: std.AutoHashMapUnmanaged(u128, model.Thread),
    messages: std.AutoHashMapUnmanaged(u128, model.Message),
    children_index: std.AutoHashMapUnmanaged(u128, std.ArrayList(u128)),
    root_messages: std.AutoHashMapUnmanaged(u128, std.ArrayList(u128)),
    branch_choices: std.AutoHashMapUnmanaged(BranchKey, u128),
    queue_items: std.AutoHashMapUnmanaged(u128, model.QueueItem),
    queue_order: std.ArrayList(u128),
    pending_rollbacks: std.AutoHashMapUnmanaged(u128, model.RollbackIntent),
    tool_calls: std.AutoHashMapUnmanaged(u128, std.ArrayList(model.ToolCallRecord)),
    summary_log_seq: u64,

    pub fn open(allocator: Allocator, io: Io, state_path: []const u8) !SessionJournal {
        try Io.Dir.cwd().createDirPath(io, state_path);
        var state_dir = try Io.Dir.cwd().openDir(io, state_path, .{ .iterate = true });
        var transferred = false;
        errdefer if (!transferred) state_dir.close(io);

        var wal = try log_mod.AppendLog.open(allocator, io, state_dir, "sessions.0ndb", true);
        errdefer if (!transferred) wal.deinit();

        var pages = try blobs_mod.BlobStore.open(allocator, io, state_dir, "pages", blobs_mod.DEFAULT_CACHE_BUDGET);
        errdefer if (!transferred) pages.deinit();

        var self = SessionJournal{
            .allocator = allocator,
            .io = io,
            .state_dir = state_dir,
            .wal = wal,
            .pages = pages,
            .threads = .empty,
            .messages = .empty,
            .children_index = .empty,
            .root_messages = .empty,
            .branch_choices = .empty,
            .queue_items = .empty,
            .queue_order = .empty,
            .pending_rollbacks = .empty,
            .tool_calls = .empty,
            .summary_log_seq = 0,
        };
        transferred = true;
        errdefer self.deinit();

        try self.replay();
        try self.markInterruptedOnBoot();
        return self;
    }

    pub fn deinit(self: *SessionJournal) void {
        {
            var it = self.threads.valueIterator();
            while (it.next()) |t| t.deinit(self.allocator);
            self.threads.deinit(self.allocator);
        }
        {
            var it = self.messages.valueIterator();
            while (it.next()) |m| m.deinit(self.allocator);
            self.messages.deinit(self.allocator);
        }
        {
            var it = self.children_index.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            self.children_index.deinit(self.allocator);
        }
        {
            var it = self.root_messages.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            self.root_messages.deinit(self.allocator);
        }
        self.branch_choices.deinit(self.allocator);
        {
            var it = self.queue_items.valueIterator();
            while (it.next()) |q| q.deinit(self.allocator);
            self.queue_items.deinit(self.allocator);
        }
        self.queue_order.deinit(self.allocator);
        {
            var it = self.pending_rollbacks.valueIterator();
            while (it.next()) |rb| rb.deinit(self.allocator);
            self.pending_rollbacks.deinit(self.allocator);
        }
        {
            var it = self.tool_calls.valueIterator();
            while (it.next()) |list| {
                for (list.items) |*tc| tc.deinit(self.allocator);
                list.deinit(self.allocator);
            }
            self.tool_calls.deinit(self.allocator);
        }
        self.pages.deinit();
        self.wal.deinit();
        self.state_dir.close(self.io);
    }

    pub fn hibernate(self: *SessionJournal) void {
        self.wal.hibernate();
        self.pages.hibernate();
    }

    fn replay(self: *SessionJournal) !void {
        const n = self.wal.count();
        for (0..n) |i| {
            const view = try self.wal.readAt(i);
            var r = codec.Reader.init(view.payload);
            switch (view.header.kind) {
                REC_THREAD_UPSERT => {
                    const t = try model.Thread.decode(self.allocator, &r);
                    try self.applyThread(t);
                },
                REC_MSG_APPEND, REC_MSG_UPDATE => {
                    const m = try model.Message.decode(self.allocator, &r);
                    try self.applyMessage(m);
                },
                REC_BRANCH_CHOICE => {
                    const tid = try r.readU128();
                    const parent = try r.readU128();
                    const child = try r.readU128();
                    try self.branch_choices.put(self.allocator, .{ .thread_id = tid, .parent_msg_id = parent }, child);
                },
                REC_QUEUE_UPSERT => {
                    const q = try model.QueueItem.decode(self.allocator, &r);
                    try self.applyQueueItem(q);
                },
                REC_ROLLBACK_BEGIN => {
                    const intent = try model.RollbackIntent.decode(self.allocator, &r);
                    const gop = try self.pending_rollbacks.getOrPut(self.allocator, intent.intent_id);
                    if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
                    gop.value_ptr.* = intent;
                },
                REC_ROLLBACK_COMMIT => {
                    const iid = try r.readU128();
                    if (self.pending_rollbacks.fetchRemove(iid)) |kv| {
                        var v = kv.value;
                        v.deinit(self.allocator);
                    }
                },
                REC_SUMMARY_DELTA => {
                    self.summary_log_seq = view.header.seq;
                },
                REC_TOOL_CALL => {
                    const tc = try model.ToolCallRecord.decode(self.allocator, &r);
                    try self.applyToolCall(tc);
                },
                else => {},
            }
        }
    }

    fn markInterruptedOnBoot(self: *SessionJournal) !void {
        var to_interrupt: std.ArrayList(u128) = .empty;
        defer to_interrupt.deinit(self.allocator);
        {
            var it = self.messages.valueIterator();
            while (it.next()) |m| {
                if (m.status == .running) {
                    try to_interrupt.append(self.allocator, m.msg_id);
                }
            }
        }
        const now = id.nowMs(self.io);
        for (to_interrupt.items) |mid| {
            if (self.messages.getPtr(mid)) |m| {
                m.status = .interrupted;
                m.updated_ms = now;
                try self.writeMessageRecord(REC_MSG_UPDATE, m);
            }
        }
        var q_requeue: std.ArrayList(u128) = .empty;
        defer q_requeue.deinit(self.allocator);
        {
            var it = self.queue_items.valueIterator();
            while (it.next()) |q| {
                if (q.status == .dispatching) {
                    try q_requeue.append(self.allocator, q.item_id);
                }
            }
        }
        for (q_requeue.items) |qid| {
            if (self.queue_items.getPtr(qid)) |q| {
                q.status = .pending;
                q.updated_ms = now;
                try self.writeQueueRecord(q);
            }
        }
        var t_fix: std.ArrayList(u128) = .empty;
        defer t_fix.deinit(self.allocator);
        {
            var it = self.threads.valueIterator();
            while (it.next()) |t| {
                if (t.status == .running or t.status == .steering) {
                    try t_fix.append(self.allocator, t.thread_id);
                }
            }
        }
        for (t_fix.items) |tid| {
            if (self.threads.getPtr(tid)) |t| {
                t.status = if (t.queued_count > 0) .queued else .interrupted;
                t.updated_ms = now;
                try self.writeThreadRecord(t);
            }
        }
    }

    fn applyThread(self: *SessionJournal, t: model.Thread) !void {
        const gop = try self.threads.getOrPut(self.allocator, t.thread_id);
        if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
        gop.value_ptr.* = t;
    }

    fn applyMessage(self: *SessionJournal, m: model.Message) !void {
        const existed = self.messages.contains(m.msg_id);
        const gop = try self.messages.getOrPut(self.allocator, m.msg_id);
        if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
        gop.value_ptr.* = m;

        if (!existed) {
            if (m.parent_id) |pid| {
                const c = try self.children_index.getOrPut(self.allocator, pid);
                if (!c.found_existing) c.value_ptr.* = .empty;
                try c.value_ptr.append(self.allocator, m.msg_id);
            } else {
                const r = try self.root_messages.getOrPut(self.allocator, m.thread_id);
                if (!r.found_existing) r.value_ptr.* = .empty;
                try r.value_ptr.append(self.allocator, m.msg_id);
            }
        }
    }

    fn applyQueueItem(self: *SessionJournal, q: model.QueueItem) !void {
        const existed = self.queue_items.contains(q.item_id);
        const gop = try self.queue_items.getOrPut(self.allocator, q.item_id);
        if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
        gop.value_ptr.* = q;
        if (!existed) {
            try self.queue_order.append(self.allocator, q.item_id);
        }
    }

    fn writeThreadRecordEx(self: *SessionJournal, t: *const model.Thread, sync_wal: bool) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try t.encode(self.allocator, &w);
        _ = try self.wal.appendDeferred(REC_THREAD_UPSERT, 0, 0, w.items());

        var sw = codec.Writer{};
        defer sw.deinit(self.allocator);
        var summary = try model.SessionSummary.fromThread(self.allocator, t);
        defer summary.deinit(self.allocator);
        try summary.encode(self.allocator, &sw);
        self.summary_log_seq = try self.wal.appendDeferred(REC_SUMMARY_DELTA, 0, 0, sw.items());
        if (sync_wal) try self.wal.sync();
    }

    fn writeThreadRecord(self: *SessionJournal, t: *const model.Thread) !void {
        try self.writeThreadRecordEx(t, true);
    }

    fn writeMessageRecord(self: *SessionJournal, kind: u8, m: *const model.Message) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try m.encode(self.allocator, &w);
        _ = try self.wal.append(kind, 0, 0, w.items());
    }

    fn writeQueueRecord(self: *SessionJournal, q: *const model.QueueItem) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try q.encode(self.allocator, &w);
        _ = try self.wal.append(REC_QUEUE_UPSERT, 0, 0, w.items());
    }

    pub fn flushWal(self: *SessionJournal) !void {
        try self.wal.sync();
    }

    pub fn putThread(self: *SessionJournal, t: model.Thread) !void {
        try self.writeThreadRecordEx(&t, true);
        try self.applyThread(t);
    }

    pub fn putThreadDeferred(self: *SessionJournal, t: model.Thread) !void {
        try self.writeThreadRecordEx(&t, false);
        try self.applyThread(t);
    }

    pub fn putMessage(self: *SessionJournal, m: model.Message, is_update: bool) !void {
        try self.writeMessageRecord(if (is_update) REC_MSG_UPDATE else REC_MSG_APPEND, &m);
        try self.applyMessage(m);
    }

    pub fn setBranchChoice(self: *SessionJournal, thread_id: u128, parent_msg_id: u128, child_msg_id: u128) !void {
        const changed = try self.setBranchChoiceDeferred(thread_id, parent_msg_id, child_msg_id);
        if (changed) try self.wal.sync();
    }

    pub fn setBranchChoiceDeferred(self: *SessionJournal, thread_id: u128, parent_msg_id: u128, child_msg_id: u128) !bool {
        const key = BranchKey{ .thread_id = thread_id, .parent_msg_id = parent_msg_id };
        if (self.branch_choices.get(key)) |existing| {
            if (existing == child_msg_id) return false;
        }
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU128(self.allocator, thread_id);
        try w.writeU128(self.allocator, parent_msg_id);
        try w.writeU128(self.allocator, child_msg_id);
        _ = try self.wal.appendDeferred(REC_BRANCH_CHOICE, 0, 0, w.items());
        try self.branch_choices.put(self.allocator, key, child_msg_id);
        return true;
    }

    pub fn putQueueItem(self: *SessionJournal, q: model.QueueItem) !void {
        try self.writeQueueRecord(&q);
        try self.applyQueueItem(q);
    }

    pub fn beginRollback(self: *SessionJournal, intent: model.RollbackIntent) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try intent.encode(self.allocator, &w);
        _ = try self.wal.append(REC_ROLLBACK_BEGIN, 0, 0, w.items());
        const gop = try self.pending_rollbacks.getOrPut(self.allocator, intent.intent_id);
        if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
        gop.value_ptr.* = intent;
    }

    pub fn commitRollback(self: *SessionJournal, intent_id: u128) !void {
        try self.commitRollbackDeferred(intent_id);
        try self.wal.sync();
    }

    pub fn commitRollbackDeferred(self: *SessionJournal, intent_id: u128) !void {
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU128(self.allocator, intent_id);
        _ = try self.wal.appendDeferred(REC_ROLLBACK_COMMIT, 0, 0, w.items());
        if (self.pending_rollbacks.fetchRemove(intent_id)) |kv| {
            var v = kv.value;
            v.deinit(self.allocator);
        }
    }

    fn applyToolCall(self: *SessionJournal, tc: model.ToolCallRecord) !void {
        var owned = tc;
        errdefer owned.deinit(self.allocator);
        const gop = try self.tool_calls.getOrPut(self.allocator, owned.msg_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |*existing| {
            if (std.mem.eql(u8, existing.call_id, owned.call_id)) {
                if (owned.name.len > 0) {
                    self.allocator.free(existing.name);
                    existing.name = owned.name;
                    owned.name = &.{};
                }
                if (owned.input_json.len > 0) {
                    self.allocator.free(existing.input_json);
                    existing.input_json = owned.input_json;
                    owned.input_json = &.{};
                }
                if (owned.output.len > 0 or existing.output.len == 0) {
                    self.allocator.free(existing.output);
                    existing.output = owned.output;
                    owned.output = &.{};
                }
                existing.is_error = owned.is_error;
                if (owned.call_id.len > 0) self.allocator.free(owned.call_id);
                if (owned.name.len > 0) self.allocator.free(owned.name);
                if (owned.input_json.len > 0) self.allocator.free(owned.input_json);
                if (owned.output.len > 0) self.allocator.free(owned.output);
                return;
            }
        }
        try gop.value_ptr.append(self.allocator, owned);
    }

    pub fn putToolCall(
        self: *SessionJournal,
        msg_id: u128,
        call_id: []const u8,
        name: []const u8,
        input_json: []const u8,
        output: []const u8,
        is_error: bool,
    ) !void {
        const rec = model.ToolCallRecord{
            .msg_id = msg_id,
            .call_id = try self.allocator.dupe(u8, call_id),
            .name = try self.allocator.dupe(u8, name),
            .input_json = try self.allocator.dupe(u8, input_json),
            .output = try self.allocator.dupe(u8, output),
            .is_error = is_error,
        };
        errdefer {
            var r = rec;
            r.deinit(self.allocator);
        }
        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try rec.encode(self.allocator, &w);
        _ = try self.wal.appendDeferred(REC_TOOL_CALL, 0, 0, w.items());
        try self.applyToolCall(rec);
    }

    pub fn toolCallsFor(self: *const SessionJournal, msg_id: u128) []const model.ToolCallRecord {
        if (self.tool_calls.get(msg_id)) |list| return list.items;
        return &.{};
    }

    pub fn siblings(self: *const SessionJournal, allocator: Allocator, msg_id: u128) ![]u128 {
        const msg = self.messages.get(msg_id) orelse return try allocator.alloc(u128, 0);
        if (msg.parent_id) |pid| {
            const list = self.children_index.get(pid) orelse return try allocator.alloc(u128, 0);
            return try allocator.dupe(u128, list.items);
        } else {
            const list = self.root_messages.get(msg.thread_id) orelse return try allocator.alloc(u128, 0);
            return try allocator.dupe(u128, list.items);
        }
    }

    pub fn resolveBranchLeaf(self: *const SessionJournal, thread_id: u128, start_msg_id: u128) u128 {
        var cur = start_msg_id;
        while (true) {
            const children = self.children_index.get(cur) orelse return cur;
            if (children.items.len == 0) return cur;
            if (self.branch_choices.get(.{ .thread_id = thread_id, .parent_msg_id = cur })) |chosen| {
                var valid = false;
                for (children.items) |cid| {
                    if (cid == chosen) {
                        valid = true;
                        break;
                    }
                }
                if (valid) {
                    cur = chosen;
                    continue;
                }
            }
            cur = children.items[children.items.len - 1];
        }
    }

    pub fn branchPath(self: *const SessionJournal, allocator: Allocator, leaf_id: ?u128) ![]model.Message {
        var rev: std.ArrayList(u128) = .empty;
        defer rev.deinit(allocator);
        var cur = leaf_id;
        while (cur) |cid| {
            const m = self.messages.get(cid) orelse break;
            try rev.append(allocator, cid);
            cur = m.parent_id;
        }
        const out = try allocator.alloc(model.Message, rev.items.len);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |*m| m.deinit(allocator);
            allocator.free(out);
        }
        var i: usize = 0;
        while (i < rev.items.len) : (i += 1) {
            const mid = rev.items[rev.items.len - 1 - i];
            const src = self.messages.getPtr(mid).?;
            out[i] = try src.clone(allocator);
            done += 1;
        }
        return out;
    }

    pub fn pendingQueueForThread(self: *const SessionJournal, allocator: Allocator, thread_id: u128) ![]u128 {
        var out: std.ArrayList(u128) = .empty;
        errdefer out.deinit(allocator);
        for (self.queue_order.items) |qid| {
            const q = self.queue_items.get(qid) orelse continue;
            if (q.thread_id == thread_id and q.status == .pending) {
                try out.append(allocator, qid);
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn countPendingQueue(self: *const SessionJournal, thread_id: u128) u32 {
        var n: u32 = 0;
        for (self.queue_order.items) |qid| {
            const q = self.queue_items.get(qid) orelse continue;
            if (q.thread_id == thread_id and (q.status == .pending or q.status == .dispatching)) {
                n += 1;
            }
        }
        return n;
    }
};
