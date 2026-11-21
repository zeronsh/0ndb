const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const blobs_mod = @import("../store/blobs.zig");
const log_mod = @import("../store/log.zig");
const manifest_mod = @import("../store/manifest.zig");
const segments_mod = @import("../store/segments.zig");
const model = @import("model.zig");

pub const FRAME_KIND_EVENT: u8 = 1;
pub const FRAME_KIND_CATALOG: u8 = 2;

pub const SealedPageMeta = struct {
    page_id: id.PageId,
    prev_page: ?id.PageId,
    first_msg_id: u128,
    last_msg_id: u128,
    msg_count: u32,
    sealed_ms: u64,
};

pub const ThreadStore = struct {
    allocator: Allocator,
    io: Io,
    thread_id: u128,
    thread_dir: Io.Dir,
    manifest: manifest_mod.Manifest,
    segments: segments_mod.SegmentStore,
    wal: log_mod.AppendLog,
    shared_blobs: ?*blobs_mod.SharedBlobPool,
    local_blobs: ?blobs_mod.BlobStore,
    lamport: u64 = 0,
    meta: ?model.ThreadMeta = null,
    seen_events: std.AutoHashMapUnmanaged(u128, void) = .empty,
    messages: std.AutoHashMapUnmanaged(u128, model.Message) = .empty,
    sealed_msg_ids: std.AutoHashMapUnmanaged(u128, id.PageId) = .empty,
    sealed_pages: std.ArrayList(SealedPageMeta) = .empty,
    head_page: ?id.PageId = null,
    sealed_tail_msg_id: ?u128 = null,
    root_children: std.ArrayList(u128) = .empty,
    children_index: std.AutoHashMapUnmanaged(u128, std.ArrayList(u128)) = .empty,
    root_branch_choice: ?model.BranchChoice = null,
    branch_choices: std.AutoHashMapUnmanaged(u128, model.BranchChoice) = .empty,
    tool_calls: std.AutoHashMapUnmanaged(u128, std.ArrayList(model.ToolCallRecord)) = .empty,
    queue_items: std.AutoHashMapUnmanaged(u128, model.QueueItem) = .empty,
    tasks: std.AutoHashMapUnmanaged(u128, model.Task) = .empty,
    mailbox: std.AutoHashMapUnmanaged(u128, model.MailboxItem) = .empty,
    mailbox_order: std.ArrayList(u128) = .empty,
    triggers: std.AutoHashMapUnmanaged(u128, model.Trigger) = .empty,
    fired_triggers: std.AutoHashMapUnmanaged([32]u8, u64) = .empty,
    active_rollback: ?model.RollbackIntent = null,
    last_lease: ?model.ExecutionLeaseRef = null,
    canceled: bool = false,
    total_message_count: u32 = 0,

    pub fn open(
        allocator: Allocator,
        io: Io,
        state_dir: Io.Dir,
        thread_id: u128,
        shared_blobs: ?*blobs_mod.SharedBlobPool,
    ) !ThreadStore {
        var hex_buf: [32]u8 = undefined;
        const tid_hex = id.formatIdHex(thread_id, &hex_buf);
        var rel_buf: [64]u8 = undefined;
        const rel_path = try std.fmt.bufPrint(&rel_buf, "threads/{s}", .{tid_hex});

        try state_dir.createDirPath(io, rel_path);
        const thread_dir = try state_dir.openDir(io, rel_path, .{ .iterate = true });
        errdefer thread_dir.close(io);

        const loaded_manifest = (try manifest_mod.Manifest.load(io, thread_dir)) orelse manifest_mod.Manifest{
            .history_id = thread_id,
            .generation = 1,
            .wal_gen = 1,
            .wal_base_seq = 1,
        };

        var segs = try segments_mod.SegmentStore.open(allocator, io, thread_dir);
        errdefer segs.deinit();

        var wal = try log_mod.AppendLog.open(allocator, io, thread_dir, "events.wal", true);
        errdefer wal.deinit();

        var local_blobs: ?blobs_mod.BlobStore = null;
        errdefer if (local_blobs) |*lb| lb.deinit();
        if (shared_blobs) |sb| {
            sb.retain();
        } else {
            local_blobs = try blobs_mod.BlobStore.open(allocator, io, thread_dir, "blobs", 4 * 1024 * 1024);
        }
        errdefer if (shared_blobs) |sb| sb.release();

        var self = ThreadStore{
            .allocator = allocator,
            .io = io,
            .thread_id = thread_id,
            .thread_dir = thread_dir,
            .manifest = loaded_manifest,
            .segments = segs,
            .wal = wal,
            .shared_blobs = shared_blobs,
            .local_blobs = local_blobs,
        };
        errdefer self.deinit();

        try self.replayPersisted();
        return self;
    }

    pub fn deinit(self: *ThreadStore) void {
        if (self.meta) |*m| m.deinit(self.allocator);
        self.seen_events.deinit(self.allocator);

        var mit = self.messages.valueIterator();
        while (mit.next()) |m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);

        self.sealed_msg_ids.deinit(self.allocator);
        self.sealed_pages.deinit(self.allocator);
        self.root_children.deinit(self.allocator);

        var cit = self.children_index.valueIterator();
        while (cit.next()) |list| list.deinit(self.allocator);
        self.children_index.deinit(self.allocator);

        self.branch_choices.deinit(self.allocator);

        var tcit = self.tool_calls.valueIterator();
        while (tcit.next()) |list| {
            for (list.items) |*tc| tc.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);

        var qit = self.queue_items.valueIterator();
        while (qit.next()) |q| q.deinit(self.allocator);
        self.queue_items.deinit(self.allocator);

        var tkit = self.tasks.valueIterator();
        while (tkit.next()) |t| t.deinit(self.allocator);
        self.tasks.deinit(self.allocator);

        var mbit = self.mailbox.valueIterator();
        while (mbit.next()) |mb| mb.deinit(self.allocator);
        self.mailbox.deinit(self.allocator);
        self.mailbox_order.deinit(self.allocator);

        var trit = self.triggers.valueIterator();
        while (trit.next()) |tr| tr.deinit(self.allocator);
        self.triggers.deinit(self.allocator);

        self.fired_triggers.deinit(self.allocator);

        if (self.active_rollback) |*rb| rb.deinit(self.allocator);

        if (self.shared_blobs) |sb| sb.release();
        if (self.local_blobs) |*lb| lb.deinit();

        self.wal.deinit();
        self.segments.deinit();
        self.thread_dir.close(self.io);
    }

    fn replayPersisted(self: *ThreadStore) !void {
        const seg_ids = try self.segments.listSegmentIds(self.allocator);
        defer self.allocator.free(seg_ids);

        for (seg_ids) |seg_id| {
            const mf = try self.segments.getMapped(seg_id);
            const data = mf.slice();
            var off: usize = 0;
            while (off + log_mod.HEADER_SIZE <= data.len) {
                const hdr_ptr: *const [log_mod.HEADER_SIZE]u8 = @ptrCast(data[off .. off + log_mod.HEADER_SIZE].ptr);
                const hdr = log_mod.FrameHeader.decode(hdr_ptr) catch break;
                const payload_start = off + log_mod.HEADER_SIZE;
                const payload_end = std.math.add(usize, payload_start, hdr.payload_len) catch break;
                if (payload_end > data.len) break;
                const aligned_end = log_mod.alignUp(payload_end);
                if (aligned_end > data.len) break;

                if (hdr.kind == FRAME_KIND_EVENT) {
                    const view = self.segments.readFrameViewAt(seg_id, off, hdr.payload_len) catch break;
                    var ev = try model.CausalEvent.decodeSlice(self.allocator, view.payload);
                    defer ev.deinit(self.allocator);
                    _ = try self.applyEventInMemory(&ev);
                }
                off = aligned_end;
            }
        }

        const n = self.wal.count();
        for (0..n) |i| {
            const view = try self.wal.readAt(i);
            if (view.header.kind != FRAME_KIND_EVENT) continue;
            var ev = try model.CausalEvent.decodeSlice(self.allocator, view.payload);
            defer ev.deinit(self.allocator);
            _ = try self.applyEventInMemory(&ev);
        }
    }

    fn putBlob(self: *ThreadStore, data: []const u8) !id.PageId {
        if (self.shared_blobs) |sb| {
            return try sb.put(data);
        }
        return try self.local_blobs.?.put(data);
    }

    fn getBlob(self: *ThreadStore, allocator: Allocator, oid: id.PageId) !?[]u8 {
        if (self.shared_blobs) |sb| {
            return try sb.get(allocator, oid);
        }
        return try self.local_blobs.?.get(allocator, oid);
    }

    fn registerChild(self: *ThreadStore, parent_id: ?u128, child_id: u128) !void {
        if (parent_id) |pid| {
            const gop = try self.children_index.getOrPut(self.allocator, pid);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            for (gop.value_ptr.items) |existing| {
                if (existing == child_id) return;
            }
            try gop.value_ptr.append(self.allocator, child_id);
        } else {
            for (self.root_children.items) |existing| {
                if (existing == child_id) return;
            }
            try self.root_children.append(self.allocator, child_id);
        }
    }

    pub fn getChildren(self: *const ThreadStore, parent_id: ?u128) []const u128 {
        if (parent_id) |pid| {
            if (self.children_index.getPtr(pid)) |list| {
                return list.items;
            }
            return &.{};
        }
        return self.root_children.items;
    }

    pub fn unsealedMessageCount(self: *const ThreadStore) usize {
        return self.messages.count();
    }

    pub fn sealedPageCount(self: *const ThreadStore) usize {
        return self.sealed_pages.items.len;
    }

    fn canApplyTaskUpdate(self: *const ThreadStore, incoming: *const model.Task) bool {
        const existing = self.tasks.getPtr(incoming.task_id) orelse return true;
        if (existing.status.isTerminal()) {
            return existing.status == incoming.status;
        }
        if (incoming.attempt < existing.attempt) return false;
        if (incoming.attempt == existing.attempt) {
            return existing.status.canTransitionTo(incoming.status);
        }
        return true;
    }

    fn appendEventRaw(self: *ThreadStore, actor: u128, event: model.ThreadEvent) !model.CausalEvent {
        switch (event) {
            .trigger_fired => |tf| {
                if (self.fired_triggers.contains(tf.dedup_key)) {
                    return error.DuplicateTriggerFire;
                }
            },
            .task_updated => |*t| {
                if (!self.canApplyTaskUpdate(t)) {
                    return error.InvalidTaskTransition;
                }
            },
            else => {},
        }

        self.lamport += 1;
        var out_ev = model.CausalEvent{
            .event_id = id.newUuidV7(self.io),
            .lamport = self.lamport,
            .actor = actor,
            .event = try event.clone(self.allocator),
        };
        errdefer out_ev.deinit(self.allocator);

        const encoded = try out_ev.encodeAlloc(self.allocator);
        defer self.allocator.free(encoded);

        const seq = try self.wal.append(FRAME_KIND_EVENT, 0, 0, encoded);
        self.manifest.total_batches = seq;
        _ = try self.applyEventInMemory(&out_ev);
        return out_ev;
    }

    pub fn appendEvent(self: *ThreadStore, actor: u128, event: model.ThreadEvent) !model.CausalEvent {
        var out_ev = try self.appendEventRaw(actor, event);
        errdefer out_ev.deinit(self.allocator);

        switch (out_ev.event) {
            .message_appended => |*m| {
                if (m.status == .completed) {
                    _ = try self.maybeSealTailPage(actor);
                }
            },
            .message_updated => |*m| {
                if (m.status == .completed) {
                    _ = try self.maybeSealTailPage(actor);
                }
            },
            else => {},
        }

        return out_ev;
    }

    pub fn applyRemoteEvent(self: *ThreadStore, ev: model.CausalEvent) !bool {
        if (self.seen_events.contains(ev.event_id)) return false;

        switch (ev.event) {
            .trigger_fired => |tf| {
                if (self.fired_triggers.contains(tf.dedup_key)) {
                    try self.seen_events.put(self.allocator, ev.event_id, {});
                    return false;
                }
            },
            .mailbox_received => |mb| {
                if (self.mailbox.contains(mb.item_id)) {
                    try self.seen_events.put(self.allocator, ev.event_id, {});
                    return false;
                }
            },
            .task_updated => |*t| {
                if (!self.canApplyTaskUpdate(t)) {
                    try self.seen_events.put(self.allocator, ev.event_id, {});
                    return false;
                }
            },
            else => {},
        }

        const encoded = try ev.encodeAlloc(self.allocator);
        defer self.allocator.free(encoded);

        const seq = try self.wal.append(FRAME_KIND_EVENT, 0, 0, encoded);
        self.manifest.total_batches = seq;
        return try self.applyEventInMemory(&ev);
    }

    fn applyEventInMemory(self: *ThreadStore, ev: *const model.CausalEvent) !bool {
        if (self.seen_events.contains(ev.event_id)) return false;
        try self.seen_events.put(self.allocator, ev.event_id, {});
        if (ev.lamport > self.lamport) {
            self.lamport = ev.lamport;
        }

        switch (ev.event) {
            .thread_created => |*tm| {
                if (self.meta) |*existing| {
                    if (tm.updated_ms >= existing.updated_ms) {
                        var cloned = try tm.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                    }
                } else {
                    self.meta = try tm.clone(self.allocator);
                }
            },
            .thread_updated => |*tu| {
                if (self.meta) |*m| {
                    if (tu.title) |t| {
                        const nt = try self.allocator.dupe(u8, t);
                        if (m.title.len > 0) self.allocator.free(m.title);
                        m.title = nt;
                    }
                    if (tu.default_provider) |p| m.default_provider = p;
                    if (tu.default_model) |dm| {
                        const nm = try self.allocator.dupe(u8, dm);
                        if (m.default_model) |old| self.allocator.free(old);
                        m.default_model = nm;
                    }
                    if (tu.status) |s| m.status = s;
                    if (tu.budget) |b| m.budget = b;
                    if (tu.updated_ms > m.updated_ms) m.updated_ms = tu.updated_ms;
                }
            },
            .bindings_updated => |*bu| {
                if (self.meta) |*m| {
                    const nb = try model.cloneBindings(self.allocator, bu.bindings);
                    model.freeBindings(self.allocator, m.bindings);
                    m.bindings = nb;
                    if (bu.updated_ms > m.updated_ms) m.updated_ms = bu.updated_ms;
                }
            },
            .message_appended => |*msg| {
                if (self.sealed_msg_ids.contains(msg.msg_id)) return true;
                if (self.messages.getPtr(msg.msg_id)) |existing| {
                    if (msg.updated_ms >= existing.updated_ms) {
                        var cloned = try msg.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                    }
                } else {
                    var cloned = try msg.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.messages.put(self.allocator, msg.msg_id, cloned);
                    try self.registerChild(msg.parent_id, msg.msg_id);
                    self.total_message_count += 1;
                }
            },
            .message_updated => |*msg| {
                if (self.sealed_msg_ids.contains(msg.msg_id)) return true;
                if (self.messages.getPtr(msg.msg_id)) |existing| {
                    if (msg.updated_ms >= existing.updated_ms) {
                        var cloned = try msg.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                    }
                } else {
                    var cloned = try msg.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.messages.put(self.allocator, msg.msg_id, cloned);
                    try self.registerChild(msg.parent_id, msg.msg_id);
                    self.total_message_count += 1;
                }
            },
            .tool_call_put => |*tc| {
                const gop = try self.tool_calls.getOrPut(self.allocator, tc.msg_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                for (gop.value_ptr.items) |*existing| {
                    if (std.mem.eql(u8, existing.call_id, tc.call_id)) {
                        var cloned = try tc.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                        return true;
                    }
                }
                var cloned = try tc.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                try gop.value_ptr.append(self.allocator, cloned);
            },
            .queue_enqueued => |*qi| {
                if (self.queue_items.getPtr(qi.item_id)) |existing| {
                    if (qi.updated_ms >= existing.updated_ms) {
                        var cloned = try qi.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                    }
                } else {
                    var cloned = try qi.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.queue_items.put(self.allocator, qi.item_id, cloned);
                }
            },
            .queue_updated => |*qi| {
                if (self.queue_items.getPtr(qi.item_id)) |existing| {
                    if (qi.updated_ms >= existing.updated_ms) {
                        var cloned = try qi.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                    }
                } else {
                    var cloned = try qi.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.queue_items.put(self.allocator, qi.item_id, cloned);
                }
            },
            .branch_choice_set => |bc| {
                if (bc.parent_id) |pid| {
                    if (self.branch_choices.getPtr(pid)) |existing| {
                        if (bc.winsOver(existing.*)) {
                            existing.* = bc;
                        }
                    } else {
                        try self.branch_choices.put(self.allocator, pid, bc);
                    }
                } else {
                    if (self.root_branch_choice) |existing| {
                        if (bc.winsOver(existing)) {
                            self.root_branch_choice = bc;
                        }
                    } else {
                        self.root_branch_choice = bc;
                    }
                }
            },
            .task_created => |*t| {
                if (self.tasks.getPtr(t.task_id)) |existing| {
                    if (self.canApplyTaskUpdate(t)) {
                        var cloned = try t.clone(self.allocator);
                        errdefer cloned.deinit(self.allocator);
                        existing.deinit(self.allocator);
                        existing.* = cloned;
                    }
                } else {
                    var cloned = try t.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.tasks.put(self.allocator, t.task_id, cloned);
                }
            },
            .task_updated => |*t| {
                if (!self.canApplyTaskUpdate(t)) return false;
                if (self.tasks.getPtr(t.task_id)) |existing| {
                    var cloned = try t.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    existing.deinit(self.allocator);
                    existing.* = cloned;
                } else {
                    var cloned = try t.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.tasks.put(self.allocator, t.task_id, cloned);
                }
            },
            .mailbox_received => |*mb| {
                if (self.mailbox.contains(mb.item_id)) return false;
                var cloned = try mb.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                try self.mailbox.put(self.allocator, mb.item_id, cloned);
                try self.mailbox_order.append(self.allocator, mb.item_id);
            },
            .trigger_put => |*tr| {
                if (self.triggers.getPtr(tr.trigger_id)) |existing| {
                    var cloned = try tr.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    existing.deinit(self.allocator);
                    existing.* = cloned;
                } else {
                    var cloned = try tr.clone(self.allocator);
                    errdefer cloned.deinit(self.allocator);
                    try self.triggers.put(self.allocator, tr.trigger_id, cloned);
                }
            },
            .trigger_fired => |tf| {
                if (self.fired_triggers.contains(tf.dedup_key)) return false;
                try self.fired_triggers.put(self.allocator, tf.dedup_key, tf.fired_ms);
            },
            .rollback_begin => |*rb| {
                var cloned = try rb.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                if (self.active_rollback) |*old| old.deinit(self.allocator);
                self.active_rollback = cloned;
            },
            .rollback_space_done => |rsd| {
                if (self.active_rollback) |*rb| {
                    if (rb.intent_id == rsd.intent_id) {
                        try rb.markSpaceCompleted(self.allocator, rsd.space_id);
                    }
                }
            },
            .rollback_commit => |rc| {
                if (self.active_rollback) |*rb| {
                    if (rb.intent_id == rc.intent_id) {
                        rb.deinit(self.allocator);
                        self.active_rollback = null;
                    }
                }
            },
            .cancel_tree => |ct| {
                if (ct.root_task_id) |tid| {
                    if (self.tasks.getPtr(tid)) |t| {
                        if (!t.status.isTerminal()) {
                            t.status = .canceled;
                            t.updated_ms = ct.canceled_ms;
                        }
                    }
                } else {
                    self.canceled = true;
                    var tit = self.tasks.valueIterator();
                    while (tit.next()) |t| {
                        if (!t.status.isTerminal()) {
                            t.status = .canceled;
                            t.updated_ms = ct.canceled_ms;
                        }
                    }
                }
            },
            .lease_observed => |lease| {
                if (self.last_lease) |existing| {
                    if (lease.fencing_epoch >= existing.fencing_epoch) {
                        self.last_lease = lease;
                    }
                } else {
                    self.last_lease = lease;
                }
            },
            .page_sealed => |ps| {
                try self.applyPageSealed(ps);
            },
        }
        return true;
    }

    fn applyPageSealed(self: *ThreadStore, ps: model.PageSealed) !void {
        for (self.sealed_pages.items) |existing| {
            if (std.mem.eql(u8, &existing.page_id, &ps.page_id)) return;
        }
        try self.sealed_pages.append(self.allocator, .{
            .page_id = ps.page_id,
            .prev_page = ps.prev_page,
            .first_msg_id = ps.first_msg_id,
            .last_msg_id = ps.last_msg_id,
            .msg_count = ps.msg_count,
            .sealed_ms = ps.sealed_ms,
        });
        self.head_page = ps.page_id;
        self.sealed_tail_msg_id = ps.last_msg_id;

        var evict_ids: std.ArrayList(u128) = .empty;
        defer evict_ids.deinit(self.allocator);

        var cur: ?u128 = ps.last_msg_id;
        var steps: u32 = 0;
        while (cur) |mid| {
            if (steps >= ps.msg_count) break;
            const msg = self.messages.getPtr(mid) orelse break;
            try evict_ids.append(self.allocator, mid);
            steps += 1;
            if (mid == ps.first_msg_id) break;
            cur = msg.parent_id;
        }

        for (evict_ids.items) |mid| {
            try self.sealed_msg_ids.put(self.allocator, mid, ps.page_id);
            if (self.messages.fetchRemove(mid)) |kv| {
                var owned = kv.value;
                owned.deinit(self.allocator);
            }
            if (mid != ps.last_msg_id) {
                if (self.children_index.fetchRemove(mid)) |ckv| {
                    var list = ckv.value;
                    list.deinit(self.allocator);
                }
            }
        }
    }

    pub fn maybeSealTailPage(self: *ThreadStore, actor: u128) !?id.PageId {
        if (self.messages.count() < model.PAGE_SIZE) return null;

        var batch_ids: [model.PAGE_SIZE]u128 = undefined;
        var cur_parent: ?u128 = self.sealed_tail_msg_id;
        var count: usize = 0;

        while (count < model.PAGE_SIZE) {
            const children = self.getChildren(cur_parent);
            if (children.len != 1) return null;
            const child_id = children[0];
            const msg = self.messages.getPtr(child_id) orelse return null;
            if (msg.status != .completed) return null;
            batch_ids[count] = child_id;
            count += 1;
            cur_parent = child_id;
        }

        var page_msgs = try self.allocator.alloc(model.Message, model.PAGE_SIZE);
        var cloned: usize = 0;
        defer {
            for (page_msgs[0..cloned]) |*m| m.deinit(self.allocator);
            self.allocator.free(page_msgs);
        }
        for (batch_ids, 0..) |mid, i| {
            const msg = self.messages.getPtr(mid).?;
            page_msgs[i] = try msg.clone(self.allocator);
            cloned += 1;
        }

        const page = model.MessagePage{
            .thread_id = self.thread_id,
            .prev_page = self.head_page,
            .first_msg_id = batch_ids[0],
            .last_msg_id = batch_ids[model.PAGE_SIZE - 1],
            .messages = page_msgs,
        };
        const encoded_page = try page.encode(self.allocator);
        defer self.allocator.free(encoded_page);

        const page_id = try self.putBlob(encoded_page);

        var seal_ev = try self.appendEventRaw(actor, .{ .page_sealed = .{
            .page_id = page_id,
            .prev_page = self.head_page,
            .first_msg_id = batch_ids[0],
            .last_msg_id = batch_ids[model.PAGE_SIZE - 1],
            .msg_count = @intCast(model.PAGE_SIZE),
            .sealed_ms = id.nowMs(self.io),
        } });
        seal_ev.deinit(self.allocator);

        self.manifest.generation += 1;
        self.manifest.checkpoint_wall_ms = id.nowMs(self.io);
        try self.manifest.saveAtomic(self.io, self.thread_dir);

        return page_id;
    }

    pub fn loadPage(self: *ThreadStore, allocator: Allocator, page_id: id.PageId) !?model.MessagePage {
        const raw = (try self.getBlob(allocator, page_id)) orelse return null;
        defer allocator.free(raw);
        return try model.MessagePage.decode(allocator, raw);
    }

    fn chooseChild(self: *const ThreadStore, parent_id: ?u128, children: []const u128) ?u128 {
        if (children.len == 0) return null;
        if (children.len == 1) return children[0];
        const maybe_choice: ?model.BranchChoice = if (parent_id) |pid|
            self.branch_choices.get(pid)
        else
            self.root_branch_choice;
        if (maybe_choice) |bc| {
            for (children) |cid| {
                if (cid == bc.selected_child_id) return cid;
            }
        }
        var best = children[0];
        var best_ms: u64 = 0;
        if (self.messages.getPtr(best)) |bm| best_ms = bm.created_ms;
        for (children[1..]) |cid| {
            const cms: u64 = if (self.messages.getPtr(cid)) |cm| cm.created_ms else 0;
            if (cms > best_ms or (cms == best_ms and cid > best)) {
                best = cid;
                best_ms = cms;
            }
        }
        return best;
    }

    pub fn activeChain(self: *ThreadStore, allocator: Allocator) ![]model.Message {
        var out: std.ArrayList(model.Message) = .empty;
        errdefer {
            for (out.items) |*m| m.deinit(allocator);
            out.deinit(allocator);
        }

        var start_unsealed_parent: ?u128 = self.sealed_tail_msg_id;
        var diverted = false;

        if (self.head_page != null) {
            var pages_rev: std.ArrayList(model.MessagePage) = .empty;
            defer {
                for (pages_rev.items) |*p| p.deinit(allocator);
                pages_rev.deinit(allocator);
            }

            var cur_pid: ?id.PageId = self.head_page;
            var guard: usize = 0;
            while (cur_pid) |pid| {
                guard += 1;
                if (guard > 65536) break;
                const page = (try self.loadPage(allocator, pid)) orelse break;
                cur_pid = page.prev_page;
                try pages_rev.append(allocator, page);
            }

            var first_sealed_id: ?u128 = null;
            if (pages_rev.items.len > 0) {
                const oldest = &pages_rev.items[pages_rev.items.len - 1];
                if (oldest.messages.len > 0) {
                    first_sealed_id = oldest.messages[0].msg_id;
                }
            }

            if (self.root_branch_choice) |rbc| {
                if (first_sealed_id == null or rbc.selected_child_id != first_sealed_id.?) {
                    if (self.messages.contains(rbc.selected_child_id)) {
                        start_unsealed_parent = null;
                        diverted = true;
                    }
                }
            }

            if (!diverted) {
                var pi = pages_rev.items.len;
                while (pi > 0) {
                    pi -= 1;
                    const page = &pages_rev.items[pi];
                    for (page.messages) |*m| {
                        try out.append(allocator, try m.clone(allocator));
                        if (self.branch_choices.get(m.msg_id)) |bc| {
                            if (self.messages.contains(bc.selected_child_id)) {
                                start_unsealed_parent = m.msg_id;
                                diverted = true;
                                break;
                            }
                        }
                    }
                    if (diverted) break;
                }
            }
        }

        var cur_parent: ?u128 = start_unsealed_parent;
        var steps: usize = 0;
        const max_steps = self.messages.count() + 1;
        while (steps < max_steps) : (steps += 1) {
            const children = self.getChildren(cur_parent);
            const next_id = self.chooseChild(cur_parent, children) orelse break;
            const msg = self.messages.getPtr(next_id) orelse break;
            try out.append(allocator, try msg.clone(allocator));
            cur_parent = next_id;
        }

        return try out.toOwnedSlice(allocator);
    }

    pub fn freeMessages(allocator: Allocator, msgs: []model.Message) void {
        for (msgs) |*m| m.deinit(allocator);
        allocator.free(msgs);
    }

    pub fn reconcileInterrupted(self: *ThreadStore, local_runner_id: u128, acquired_epoch: ?u64) !usize {
        var to_interrupt: std.ArrayList(u128) = .empty;
        defer to_interrupt.deinit(self.allocator);

        var other_running = false;
        var it = self.messages.iterator();
        while (it.next()) |entry| {
            const msg = entry.value_ptr;
            if (msg.status != .running) continue;
            const same_runner = msg.runner_id == local_runner_id;
            const stale_epoch = if (acquired_epoch) |ep| msg.fencing_epoch < ep else false;
            if (same_runner or stale_epoch) {
                try to_interrupt.append(self.allocator, msg.msg_id);
            } else {
                other_running = true;
            }
        }

        const now = id.nowMs(self.io);
        for (to_interrupt.items) |mid| {
            const cur = self.messages.getPtr(mid) orelse continue;
            var updated = try cur.clone(self.allocator);
            defer updated.deinit(self.allocator);
            updated.status = .interrupted;
            updated.updated_ms = @max(now, updated.updated_ms + 1);
            var ev = try self.appendEvent(local_runner_id, .{ .message_updated = updated });
            ev.deinit(self.allocator);
        }

        if (to_interrupt.items.len > 0 and !other_running) {
            if (self.meta) |*m| {
                if (m.status == .running) {
                    var ev = try self.appendEvent(local_runner_id, .{ .thread_updated = .{
                        .status = .interrupted,
                        .updated_ms = now,
                    } });
                    ev.deinit(self.allocator);
                }
            }
        }

        return to_interrupt.items.len;
    }

    pub fn taskChildrenReady(self: *const ThreadStore, task_id: u128) bool {
        const task = self.tasks.getPtr(task_id) orelse return false;
        if (task.depends_on.len == 0) return true;
        var completed: usize = 0;
        for (task.depends_on) |dep_id| {
            if (self.tasks.getPtr(dep_id)) |dep| {
                if (dep.status == .completed) completed += 1;
            }
        }
        const required: usize = if (task.join_quorum == 0)
            task.depends_on.len
        else
            @min(@as(usize, task.join_quorum), task.depends_on.len);
        return completed >= required;
    }

    pub fn evaluateReadyTasks(self: *ThreadStore) !usize {
        return try self.evaluateReadyTasksWithActor(self.thread_id);
    }

    pub fn evaluateReadyTasksWithActor(self: *ThreadStore, actor: u128) !usize {
        var ready_ids: std.ArrayList(u128) = .empty;
        defer ready_ids.deinit(self.allocator);

        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task = entry.value_ptr;
            if (task.status != .pending) continue;
            if (self.taskChildrenReady(task.task_id)) {
                try ready_ids.append(self.allocator, task.task_id);
            }
        }

        const now = id.nowMs(self.io);
        for (ready_ids.items) |tid| {
            const cur = self.tasks.getPtr(tid) orelse continue;
            var updated = try cur.clone(self.allocator);
            defer updated.deinit(self.allocator);
            updated.status = .ready;
            updated.updated_ms = @max(now, updated.updated_ms + 1);
            var ev = try self.appendEvent(actor, .{ .task_updated = updated });
            ev.deinit(self.allocator);
        }

        return ready_ids.items.len;
    }

    pub fn pendingRollback(self: *const ThreadStore) ?*const model.RollbackIntent {
        if (self.active_rollback) |*rb| return rb;
        return null;
    }

    pub fn eventsSince(self: *ThreadStore, allocator: Allocator, after_seq: u64) ![]model.CausalEvent {
        const start_idx = self.wal.findIndexBySeq(after_seq + 1);
        const total = self.wal.count();
        if (start_idx >= total) return &.{};

        var out: std.ArrayList(model.CausalEvent) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }

        for (start_idx..total) |i| {
            const view = try self.wal.readAt(i);
            if (view.header.kind != FRAME_KIND_EVENT) continue;
            const ev = try model.CausalEvent.decodeSlice(allocator, view.payload);
            try out.append(allocator, ev);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn freeEvents(allocator: Allocator, events: []model.CausalEvent) void {
        if (events.len == 0) return;
        for (events) |*e| e.deinit(allocator);
        allocator.free(events);
    }

    pub fn lastSeq(self: *const ThreadStore) u64 {
        return self.wal.lastSeq();
    }
};

pub const CatalogStore = struct {
    allocator: Allocator,
    io: Io,
    catalog_dir: Io.Dir,
    manifest: manifest_mod.Manifest,
    wal: log_mod.AppendLog,
    projects: std.AutoHashMapUnmanaged(u128, model.ProjectSummary) = .empty,
    spaces: std.AutoHashMapUnmanaged(u128, model.SpaceSummary) = .empty,
    threads: std.AutoHashMapUnmanaged(u128, model.ThreadSummary) = .empty,
    runners: std.AutoHashMapUnmanaged(u128, model.RunnerInfo) = .empty,

    pub fn open(allocator: Allocator, io: Io, state_dir: Io.Dir) !CatalogStore {
        try state_dir.createDirPath(io, "catalog");
        const catalog_dir = try state_dir.openDir(io, "catalog", .{ .iterate = true });
        errdefer catalog_dir.close(io);

        const loaded_manifest = (try manifest_mod.Manifest.load(io, catalog_dir)) orelse manifest_mod.Manifest{
            .history_id = 0,
            .generation = 1,
            .wal_gen = 1,
            .wal_base_seq = 1,
        };

        var wal = try log_mod.AppendLog.open(allocator, io, catalog_dir, "catalog.wal", true);
        errdefer wal.deinit();

        var self = CatalogStore{
            .allocator = allocator,
            .io = io,
            .catalog_dir = catalog_dir,
            .manifest = loaded_manifest,
            .wal = wal,
        };
        errdefer self.deinit();

        const n = self.wal.count();
        for (0..n) |i| {
            const view = try self.wal.readAt(i);
            if (view.header.kind != FRAME_KIND_CATALOG) continue;
            var entry = try model.CatalogEntry.decodeSlice(self.allocator, view.payload);
            defer entry.deinit(self.allocator);
            _ = try self.applyInMemory(&entry);
        }
        return self;
    }

    pub fn deinit(self: *CatalogStore) void {
        var pit = self.projects.valueIterator();
        while (pit.next()) |p| p.deinit(self.allocator);
        self.projects.deinit(self.allocator);

        var sit = self.spaces.valueIterator();
        while (sit.next()) |s| s.deinit(self.allocator);
        self.spaces.deinit(self.allocator);

        var tit = self.threads.valueIterator();
        while (tit.next()) |t| t.deinit(self.allocator);
        self.threads.deinit(self.allocator);

        var rit = self.runners.valueIterator();
        while (rit.next()) |r| r.deinit(self.allocator);
        self.runners.deinit(self.allocator);

        self.wal.deinit();
        self.catalog_dir.close(self.io);
    }

    fn wouldWin(self: *const CatalogStore, entry: *const model.CatalogEntry) bool {
        return switch (entry.*) {
            .project => |*p| if (self.projects.getPtr(p.project_id)) |ex|
                model.lwwWins(p.updated_ms, p.actor, ex.updated_ms, ex.actor)
            else
                true,
            .space => |*s| if (self.spaces.getPtr(s.space_id)) |ex|
                model.lwwWins(s.updated_ms, s.actor, ex.updated_ms, ex.actor)
            else
                true,
            .thread => |*t| if (self.threads.getPtr(t.thread_id)) |ex|
                model.lwwWins(t.updated_ms, t.actor, ex.updated_ms, ex.actor)
            else
                true,
            .runner => |*r| if (self.runners.getPtr(r.runner_id)) |ex|
                model.lwwWins(r.updated_ms, r.actor, ex.updated_ms, ex.actor)
            else
                true,
        };
    }

    fn applyInMemory(self: *CatalogStore, entry: *const model.CatalogEntry) !bool {
        if (!self.wouldWin(entry)) return false;
        switch (entry.*) {
            .project => |*p| {
                var cloned = try p.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                if (self.projects.getPtr(p.project_id)) |ex| {
                    ex.deinit(self.allocator);
                    ex.* = cloned;
                } else {
                    try self.projects.put(self.allocator, p.project_id, cloned);
                }
            },
            .space => |*s| {
                var cloned = try s.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                if (self.spaces.getPtr(s.space_id)) |ex| {
                    ex.deinit(self.allocator);
                    ex.* = cloned;
                } else {
                    try self.spaces.put(self.allocator, s.space_id, cloned);
                }
            },
            .thread => |*t| {
                var cloned = try t.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                if (self.threads.getPtr(t.thread_id)) |ex| {
                    ex.deinit(self.allocator);
                    ex.* = cloned;
                } else {
                    try self.threads.put(self.allocator, t.thread_id, cloned);
                }
            },
            .runner => |*r| {
                var cloned = try r.clone(self.allocator);
                errdefer cloned.deinit(self.allocator);
                if (self.runners.getPtr(r.runner_id)) |ex| {
                    ex.deinit(self.allocator);
                    ex.* = cloned;
                } else {
                    try self.runners.put(self.allocator, r.runner_id, cloned);
                }
            },
        }
        return true;
    }

    pub fn putEntry(self: *CatalogStore, entry: model.CatalogEntry) !bool {
        if (!self.wouldWin(&entry)) return false;
        const encoded = try entry.encodeAlloc(self.allocator);
        defer self.allocator.free(encoded);
        const seq = try self.wal.append(FRAME_KIND_CATALOG, 0, 0, encoded);
        self.manifest.total_batches = seq;
        return try self.applyInMemory(&entry);
    }

    pub fn putProject(self: *CatalogStore, p: model.ProjectSummary) !bool {
        return try self.putEntry(.{ .project = p });
    }

    pub fn putSpace(self: *CatalogStore, s: model.SpaceSummary) !bool {
        return try self.putEntry(.{ .space = s });
    }

    pub fn putThread(self: *CatalogStore, t: model.ThreadSummary) !bool {
        return try self.putEntry(.{ .thread = t });
    }

    pub fn putRunner(self: *CatalogStore, r: model.RunnerInfo) !bool {
        return try self.putEntry(.{ .runner = r });
    }

    pub fn getProject(self: *const CatalogStore, project_id: u128) ?*const model.ProjectSummary {
        return self.projects.getPtr(project_id);
    }

    pub fn getSpace(self: *const CatalogStore, space_id: u128) ?*const model.SpaceSummary {
        return self.spaces.getPtr(space_id);
    }

    pub fn getThread(self: *const CatalogStore, thread_id: u128) ?*const model.ThreadSummary {
        return self.threads.getPtr(thread_id);
    }

    pub fn getRunner(self: *const CatalogStore, runner_id: u128) ?*const model.RunnerInfo {
        return self.runners.getPtr(runner_id);
    }

    pub fn listProjects(self: *const CatalogStore, allocator: Allocator) ![]model.ProjectSummary {
        var out: std.ArrayList(model.ProjectSummary) = .empty;
        errdefer {
            for (out.items) |*p| p.deinit(allocator);
            out.deinit(allocator);
        }
        var it = self.projects.valueIterator();
        while (it.next()) |p| {
            if (p.deleted) continue;
            try out.append(allocator, try p.clone(allocator));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn listSpaces(self: *const CatalogStore, allocator: Allocator) ![]model.SpaceSummary {
        var out: std.ArrayList(model.SpaceSummary) = .empty;
        errdefer {
            for (out.items) |*s| s.deinit(allocator);
            out.deinit(allocator);
        }
        var it = self.spaces.valueIterator();
        while (it.next()) |s| {
            if (s.deleted) continue;
            try out.append(allocator, try s.clone(allocator));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn listThreads(self: *const CatalogStore, allocator: Allocator, project_id: ?u128) ![]model.ThreadSummary {
        var out: std.ArrayList(model.ThreadSummary) = .empty;
        errdefer {
            for (out.items) |*t| t.deinit(allocator);
            out.deinit(allocator);
        }
        var it = self.threads.valueIterator();
        while (it.next()) |t| {
            if (t.deleted) continue;
            if (project_id) |pid| {
                if (t.project_id == null or t.project_id.? != pid) continue;
            }
            try out.append(allocator, try t.clone(allocator));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn listRunners(self: *const CatalogStore, allocator: Allocator) ![]model.RunnerInfo {
        var out: std.ArrayList(model.RunnerInfo) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit(allocator);
            out.deinit(allocator);
        }
        var it = self.runners.valueIterator();
        while (it.next()) |r| {
            try out.append(allocator, try r.clone(allocator));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn entriesSince(self: *CatalogStore, allocator: Allocator, after_seq: u64) ![]model.CatalogEntry {
        const start_idx = self.wal.findIndexBySeq(after_seq + 1);
        const total = self.wal.count();
        if (start_idx >= total) return &.{};

        var out: std.ArrayList(model.CatalogEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        for (start_idx..total) |i| {
            const view = try self.wal.readAt(i);
            if (view.header.kind != FRAME_KIND_CATALOG) continue;
            try out.append(allocator, try model.CatalogEntry.decodeSlice(allocator, view.payload));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn saveManifest(self: *CatalogStore) !void {
        self.manifest.generation += 1;
        self.manifest.checkpoint_wall_ms = id.nowMs(self.io);
        try self.manifest.saveAtomic(self.io, self.catalog_dir);
    }
};
