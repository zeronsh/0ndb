const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const ws_mod = @import("../fs/workspace.zig");
const wt_mod = @import("../fs/worktrees.zig");
const vcs = @import("../fs/vcs.zig");
const iface = @import("../providers/interface.zig");
const registry = @import("../providers/registry.zig");
const pool_mod = @import("../providers/pool.zig");
const model = @import("model.zig");
const pager = @import("pager.zig");
const journal_mod = @import("journal.zig");

pub const TurnObserver = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, thread_id: u128, msg_id: u128, ev: *const iface.Event) void,
};

pub const HandleFactory = struct {
    ptr: ?*anyopaque = null,
    open_fn: *const fn (ptr: ?*anyopaque, allocator: Allocator, io: Io, provider: iface.ProviderId, req: iface.StartRequest) anyerror!iface.RunHandle,
};

fn defaultOpenHandle(
    _: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    provider: iface.ProviderId,
    req: iface.StartRequest,
) anyerror!iface.RunHandle {
    return registry.start(allocator, io, provider, req);
}

pub const DEFAULT_FACTORY = HandleFactory{
    .ptr = null,
    .open_fn = defaultOpenHandle,
};

pub const SessionEngine = struct {
    allocator: Allocator,
    io: Io,
    workspace: *ws_mod.Workspace,
    worktrees: ?*wt_mod.Worktrees,
    journal: journal_mod.SessionJournal,
    warm_pool: pool_mod.WarmPool,
    page_size: usize,
    mu: Io.Mutex,

    pub fn open(
        allocator: Allocator,
        io: Io,
        workspace: *ws_mod.Workspace,
        state_path: []const u8,
    ) !SessionEngine {
        var j = try journal_mod.SessionJournal.open(allocator, io, state_path);
        var transferred = false;
        errdefer if (!transferred) j.deinit();
        var self = SessionEngine{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .worktrees = null,
            .journal = j,
            .warm_pool = pool_mod.WarmPool.init(allocator, io, pool_mod.DEFAULT_WARM_LIMIT, pool_mod.DEFAULT_WARM_IDLE_MS),
            .page_size = pager.DEFAULT_PAGE_SIZE,
            .mu = .init,
        };
        transferred = true;
        errdefer self.deinit();
        try self.recoverPendingRollbacks();
        return self;
    }

    pub fn deinit(self: *SessionEngine) void {
        self.warm_pool.deinit();
        self.journal.deinit();
    }

    pub fn attachWorktrees(self: *SessionEngine, wts: ?*wt_mod.Worktrees) void {
        self.worktrees = wts;
    }

    pub fn lock(self: *SessionEngine) void {
        self.mu.lockUncancelable(self.io);
    }

    pub fn unlock(self: *SessionEngine) void {
        self.mu.unlock(self.io);
    }

    pub fn workspaceForThread(self: *SessionEngine, thread_id: u128) *ws_mod.Workspace {
        if (self.worktrees) |wts| {
            if (self.journal.threads.get(thread_id)) |t| {
                if (t.worktree_id != self.workspace.history.history_id) {
                    if (wts.getWorkspace(t.worktree_id)) |w| return w;
                }
            }
        }
        return self.workspace;
    }

    pub fn hibernate(self: *SessionEngine) void {
        self.warm_pool.closeIdle();
        self.journal.hibernate();
        self.workspace.hibernate();
    }

    fn recoverPendingRollbacks(self: *SessionEngine) !void {
        var ids: std.ArrayList(u128) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.journal.pending_rollbacks.keyIterator();
            while (it.next()) |k| try ids.append(self.allocator, k.*);
        }
        for (ids.items) |iid| {
            const intent = self.journal.pending_rollbacks.get(iid) orelse continue;
            const ws = self.workspaceForThread(intent.thread_id);
            _ = try ws.rollbackToVersion(&intent.target_version);
            if (intent.target_git_commit) |gc| {
                vcs.moveHeadSafe(self.allocator, self.io, ws.root_path, null, gc) catch {};
            }
            try self.recordBranchChoicesAlongDeferred(intent.thread_id, intent.target_msg_id);
            if (self.journal.threads.getPtr(intent.thread_id)) |t| {
                var updated = try t.clone(self.allocator);
                updated.leaf_msg_id = intent.target_msg_id;
                updated.message_count = self.countBranchLen(intent.target_msg_id);
                updated.updated_ms = id.nowMs(self.io);
                updated.head_page = try self.sealThreadPages(updated.thread_id, updated.leaf_msg_id);
                try self.journal.putThreadDeferred(updated);
            }
            try self.journal.commitRollbackDeferred(iid);
            try self.journal.flushWal();
        }
    }

    pub fn createThread(
        self: *SessionEngine,
        title: []const u8,
        provider: iface.ProviderId,
        default_model: ?[]const u8,
    ) !u128 {
        return self.createThreadInWorktree(title, provider, default_model, self.workspace.history.history_id);
    }

    pub fn createThreadInWorktree(
        self: *SessionEngine,
        title: []const u8,
        provider: iface.ProviderId,
        default_model: ?[]const u8,
        worktree_id: u128,
    ) !u128 {
        const tid = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);
        const t = model.Thread{
            .thread_id = tid,
            .worktree_id = worktree_id,
            .title = try self.allocator.dupe(u8, title),
            .leaf_msg_id = null,
            .head_page = null,
            .default_provider = provider,
            .default_model = if (default_model) |m| try self.allocator.dupe(u8, m) else null,
            .status = .idle,
            .queued_count = 0,
            .message_count = 0,
            .created_ms = now,
            .updated_ms = now,
        };
        try self.journal.putThread(t);
        return tid;
    }

    pub fn listSessions(self: *const SessionEngine, allocator: Allocator) ![]model.SessionSummary {
        var list: std.ArrayList(model.SessionSummary) = .empty;
        errdefer {
            for (list.items) |*s| s.deinit(allocator);
            list.deinit(allocator);
        }
        var it = self.journal.threads.valueIterator();
        while (it.next()) |t| {
            try list.append(allocator, try model.SessionSummary.fromThread(allocator, t));
        }
        std.mem.sort(model.SessionSummary, list.items, {}, struct {
            fn lessThan(_: void, a: model.SessionSummary, b: model.SessionSummary) bool {
                return a.updated_ms > b.updated_ms;
            }
        }.lessThan);
        return try list.toOwnedSlice(allocator);
    }

    pub fn getPage(
        self: *const SessionEngine,
        allocator: Allocator,
        thread_id: u128,
        before_msg_id: ?u128,
        limit: usize,
    ) !model.PageResult {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const max_n = if (limit == 0) self.page_size else limit;

        var start_id: ?u128 = t.leaf_msg_id;
        if (before_msg_id) |bid| {
            const bm = self.journal.messages.get(bid) orelse return error.MessageNotFound;
            start_id = bm.parent_id;
        }

        var rev: std.ArrayList(u128) = .empty;
        defer rev.deinit(allocator);
        var cur = start_id;
        var has_more = false;
        while (cur) |cid| {
            if (rev.items.len >= max_n) {
                has_more = true;
                break;
            }
            const m = self.journal.messages.get(cid) orelse break;
            try rev.append(allocator, cid);
            cur = m.parent_id;
        }

        const msgs = try allocator.alloc(model.Message, rev.items.len);
        var done: usize = 0;
        errdefer {
            for (msgs[0..done]) |*m| m.deinit(allocator);
            allocator.free(msgs);
        }
        for (0..rev.items.len) |i| {
            const mid = rev.items[rev.items.len - 1 - i];
            msgs[i] = try self.journal.messages.getPtr(mid).?.clone(allocator);
            done += 1;
        }

        const next_before: ?u128 = if (has_more and msgs.len > 0) msgs[0].msg_id else null;
        return .{
            .messages = msgs,
            .has_more = has_more,
            .next_before = next_before,
            .head_page = t.head_page,
        };
    }

    pub fn sealThreadPages(self: *SessionEngine, thread_id: u128, leaf_id: ?u128) !?id.PageId {
        const path = try self.journal.branchPath(self.allocator, leaf_id);
        defer {
            for (path) |*m| m.deinit(self.allocator);
            self.allocator.free(path);
        }
        return try pager.sealBranchChain(self.allocator, &self.journal.pages, thread_id, path, self.page_size);
    }

    pub fn enqueue(
        self: *SessionEngine,
        thread_id: u128,
        prompt: []const u8,
        provider_opt: ?iface.ProviderId,
        model_opt: ?[]const u8,
    ) !u128 {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const now = id.nowMs(self.io);
        const qid = id.newUuidV7(self.io);
        const item = model.QueueItem{
            .item_id = qid,
            .thread_id = thread_id,
            .kind = .follow_up,
            .status = .pending,
            .prompt = try self.allocator.dupe(u8, prompt),
            .provider = provider_opt orelse t.default_provider,
            .model = if (model_opt) |m| try self.allocator.dupe(u8, m) else if (t.default_model) |dm| try self.allocator.dupe(u8, dm) else null,
            .target_turn_msg_id = null,
            .created_ms = now,
            .updated_ms = now,
        };
        try self.journal.putQueueItem(item);
        try self.refreshThreadMeta(thread_id, if (t.status == .idle) .queued else t.status);
        return qid;
    }

    pub fn steer(
        self: *SessionEngine,
        thread_id: u128,
        prompt: []const u8,
        provider_opt: ?iface.ProviderId,
        model_opt: ?[]const u8,
    ) !u128 {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const now = id.nowMs(self.io);
        const qid = id.newUuidV7(self.io);
        const item = model.QueueItem{
            .item_id = qid,
            .thread_id = thread_id,
            .kind = .steer,
            .status = .pending,
            .prompt = try self.allocator.dupe(u8, prompt),
            .provider = provider_opt orelse t.default_provider,
            .model = if (model_opt) |m| try self.allocator.dupe(u8, m) else if (t.default_model) |dm| try self.allocator.dupe(u8, dm) else null,
            .target_turn_msg_id = t.leaf_msg_id,
            .created_ms = now,
            .updated_ms = now,
        };
        try self.journal.putQueueItem(item);
        try self.refreshThreadMeta(thread_id, if (t.status == .running) .steering else .queued);
        return qid;
    }

    pub fn cancelQueued(self: *SessionEngine, item_id: u128) !void {
        const cur = self.journal.queue_items.getPtr(item_id) orelse return error.QueueItemNotFound;
        if (cur.status != .pending) return;
        var updated = try cur.clone(self.allocator);
        updated.status = .cancelled;
        updated.updated_ms = id.nowMs(self.io);
        const tid = updated.thread_id;
        try self.journal.putQueueItem(updated);
        const t = self.journal.threads.get(tid) orelse return;
        const rem = self.journal.countPendingQueue(tid);
        const st: model.SessionStatus = if (t.status == .queued and rem == 0) .idle else t.status;
        try self.refreshThreadMeta(tid, st);
    }

    pub fn editQueued(self: *SessionEngine, item_id: u128, new_prompt: []const u8) !void {
        const cur = self.journal.queue_items.getPtr(item_id) orelse return error.QueueItemNotFound;
        if (cur.status != .pending) return error.QueueItemNotEditable;
        var updated = try cur.clone(self.allocator);
        self.allocator.free(updated.prompt);
        updated.prompt = try self.allocator.dupe(u8, new_prompt);
        updated.updated_ms = id.nowMs(self.io);
        try self.journal.putQueueItem(updated);
    }

    fn refreshThreadMeta(self: *SessionEngine, thread_id: u128, status: model.SessionStatus) !void {
        const t = self.journal.threads.getPtr(thread_id) orelse return;
        var updated = try t.clone(self.allocator);
        updated.status = status;
        updated.queued_count = self.journal.countPendingQueue(thread_id);
        updated.updated_ms = id.nowMs(self.io);
        try self.journal.putThread(updated);
    }

    fn recordBranchChoicesAlongDeferred(self: *SessionEngine, thread_id: u128, leaf_id: ?u128) !void {
        var cur = leaf_id;
        while (cur) |cid| {
            const m = self.journal.messages.get(cid) orelse break;
            if (m.parent_id) |pid| {
                _ = try self.journal.setBranchChoiceDeferred(thread_id, pid, cid);
            }
            cur = m.parent_id;
        }
    }

    fn countBranchLen(self: *const SessionEngine, leaf_id: ?u128) u32 {
        var n: u32 = 0;
        var cur = leaf_id;
        while (cur) |cid| {
            const m = self.journal.messages.get(cid) orelse break;
            n += 1;
            cur = m.parent_id;
        }
        return n;
    }

    pub fn appendUserMessage(
        self: *SessionEngine,
        thread_id: u128,
        parent_id: ?u128,
        role: model.Role,
        content: []const u8,
        provider: iface.ProviderId,
        model_opt: ?[]const u8,
        steer_of: ?u128,
        switched_from: ?u128,
    ) !u128 {
        const ws = self.workspaceForThread(thread_id);
        _ = try ws.ingestDisk();
        var ver = try ws.history.headsClone();
        var transferred = false;
        errdefer if (!transferred) ver.deinit(self.allocator);
        var post_ver = try ver.clone(self.allocator);
        errdefer if (!transferred) post_ver.deinit(self.allocator);

        var gi = vcs.head(self.allocator, self.io, ws.root_path) catch vcs.VcsHead{};
        errdefer if (!transferred) gi.deinit(self.allocator);

        const content_copy = try self.allocator.dupe(u8, content);
        errdefer if (!transferred) self.allocator.free(content_copy);
        const model_copy: ?[]u8 = if (model_opt) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (!transferred) if (model_copy) |m| self.allocator.free(m);

        const now = id.nowMs(self.io);
        const mid = id.newUuidV7(self.io);
        const msg = model.Message{
            .msg_id = mid,
            .thread_id = thread_id,
            .parent_id = parent_id,
            .role = role,
            .content = content_copy,
            .provider = provider,
            .model = model_copy,
            .native_session = null,
            .native_turn = null,
            .pre_version = ver,
            .post_version = post_ver,
            .git_branch = gi.ref_name,
            .git_commit = gi.rev,
            .worktree_id = ws.history.history_id,
            .status = .completed,
            .steer_of = steer_of,
            .switched_from = switched_from,
            .created_ms = now,
            .updated_ms = now,
        };
        try self.journal.putMessage(msg, false);
        transferred = true;
        if (parent_id) |pid| {
            try self.journal.setBranchChoice(thread_id, pid, mid);
        }

        if (self.journal.threads.getPtr(thread_id)) |t| {
            var updated = try t.clone(self.allocator);
            updated.leaf_msg_id = mid;
            updated.message_count = self.countBranchLen(mid);
            updated.head_page = try self.sealThreadPages(thread_id, mid);
            updated.updated_ms = now;
            try self.journal.putThread(updated);
        }
        return mid;
    }

    pub fn executePrompt(
        self: *SessionEngine,
        thread_id: u128,
        prompt: []const u8,
        provider_opt: ?iface.ProviderId,
        model_opt: ?[]const u8,
        factory: HandleFactory,
        observer: ?TurnObserver,
    ) !u128 {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const prov = provider_opt orelse t.default_provider;
        const leaf = t.leaf_msg_id;
        const raw_mdl = model_opt orelse t.default_model;
        const owned_mdl: ?[]u8 = if (raw_mdl) |m| try self.allocator.dupe(u8, m) else null;
        defer if (owned_mdl) |m| self.allocator.free(m);

        const user_id = try self.appendUserMessage(
            thread_id,
            leaf,
            .user,
            prompt,
            prov,
            owned_mdl,
            null,
            null,
        );
        return try self.runAssistantAfter(thread_id, user_id, prompt, prov, owned_mdl, factory, observer);
    }

    pub fn drainQueue(
        self: *SessionEngine,
        thread_id: u128,
        factory: HandleFactory,
        observer: ?TurnObserver,
    ) !usize {
        var processed: usize = 0;
        while (true) {
            const pending_ids = try self.journal.pendingQueueForThread(self.allocator, thread_id);
            defer self.allocator.free(pending_ids);
            if (pending_ids.len == 0) break;

            const next_qid = pending_ids[0];
            const item_ptr = self.journal.queue_items.getPtr(next_qid) orelse break;
            var dispatching = try item_ptr.clone(self.allocator);
            dispatching.status = .dispatching;
            dispatching.updated_ms = id.nowMs(self.io);
            const prompt_copy = try self.allocator.dupe(u8, dispatching.prompt);
            defer self.allocator.free(prompt_copy);
            const prov = dispatching.provider;
            const mdl_copy: ?[]u8 = if (dispatching.model) |m| try self.allocator.dupe(u8, m) else null;
            defer if (mdl_copy) |m| self.allocator.free(m);
            try self.journal.putQueueItem(dispatching);

            _ = try self.executePrompt(thread_id, prompt_copy, prov, mdl_copy, factory, observer);

            if (self.journal.queue_items.getPtr(next_qid)) |q| {
                var done = try q.clone(self.allocator);
                done.status = .completed;
                done.updated_ms = id.nowMs(self.io);
                try self.journal.putQueueItem(done);
            }
            processed += 1;
        }
        try self.refreshThreadMeta(thread_id, .idle);
        return processed;
    }

    pub const TurnPlan = struct {
        resume_id: ?[]u8,
        fork_at: ?[]u8,
        prompt: []u8,
        handoff_prompt: ?[]u8,
        delta_messages: usize = 0,

        pub fn deinit(self: *TurnPlan, allocator: Allocator) void {
            if (self.resume_id) |s| allocator.free(s);
            if (self.fork_at) |s| allocator.free(s);
            allocator.free(self.prompt);
            if (self.handoff_prompt) |s| allocator.free(s);
        }
    };

    const MAX_HANDOFF_BYTES: usize = 60 * 1024;
    const HISTORY_MESSAGE_BYTES: usize = 8 * 1024;
    const HISTORY_TOOL_OUTPUT_BYTES: usize = 600;

    fn clipUtf8(s: []const u8, max_bytes: usize) []const u8 {
        if (s.len <= max_bytes) return s;
        var end = max_bytes;
        while (end > 0 and (s[end] & 0xC0) == 0x80) {
            end -= 1;
        }
        return s[0..end];
    }

    fn appendClipped(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8, max_bytes: usize) !void {
        if (s.len <= max_bytes) {
            try out.appendSlice(allocator, s);
            return;
        }
        try out.appendSlice(allocator, clipUtf8(s, max_bytes));
        try out.appendSlice(allocator, "...");
    }

    fn buildReplayPrompt(
        self: *const SessionEngine,
        allocator: Allocator,
        slice: []const model.Message,
        raw_prompt: []const u8,
        target_provider: iface.ProviderId,
        continued: bool,
    ) ![]u8 {
        const trimmed_prompt = std.mem.trimStart(u8, raw_prompt, " \t\r\n");
        if (slice.len == 0 or (trimmed_prompt.len > 0 and trimmed_prompt[0] == '/')) {
            return try allocator.dupe(u8, raw_prompt);
        }

        var entries: std.ArrayList([]u8) = .empty;
        defer {
            for (entries.items) |e| allocator.free(e);
            entries.deinit(allocator);
        }

        var has_other_provider = false;
        for (slice) |m| {
            if (m.role == .assistant and m.provider != target_provider) {
                has_other_provider = true;
            }
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(allocator);
            if (m.content.len > 0) {
                try body.appendSlice(allocator, m.content);
            } else if (m.status == .interrupted) {
                try body.appendSlice(allocator, "(interrupted)");
            }
            if (m.role == .assistant) {
                const calls = self.journal.toolCallsFor(m.msg_id);
                for (calls) |tc| {
                    try body.appendSlice(allocator, "\nTool: ");
                    try body.appendSlice(allocator, tc.name);
                    if (tc.input_json.len > 0) {
                        try body.append(allocator, ' ');
                        try appendClipped(allocator, &body, tc.input_json, HISTORY_TOOL_OUTPUT_BYTES);
                    }
                    if (tc.output.len > 0) {
                        try body.append(allocator, '\n');
                        try appendClipped(allocator, &body, tc.output, HISTORY_TOOL_OUTPUT_BYTES);
                    }
                }
            }
            const trimmed_body = std.mem.trim(u8, body.items, " \t\r\n");
            if (trimmed_body.len == 0) continue;

            var entry: std.ArrayList(u8) = .empty;
            errdefer entry.deinit(allocator);
            switch (m.role) {
                .user => try entry.appendSlice(allocator, "[User]\n"),
                .steer => try entry.appendSlice(allocator, "[User (steer)]\n"),
                .system => try entry.appendSlice(allocator, "[System]\n"),
                .assistant => try entry.print(allocator, "[Assistant ({s})]\n", .{m.provider.displayName()}),
            }
            try appendClipped(allocator, &entry, trimmed_body, HISTORY_MESSAGE_BYTES);
            try entry.appendSlice(allocator, "\n\n");
            try entries.append(allocator, try entry.toOwnedSlice(allocator));
        }

        if (entries.items.len == 0) return try allocator.dupe(u8, raw_prompt);

        var start_idx: usize = entries.items.len;
        var budget: usize = 0;
        while (start_idx > 0) {
            const elen = entries.items[start_idx - 1].len;
            if (start_idx < entries.items.len and budget + elen > MAX_HANDOFF_BYTES) break;
            budget += elen;
            start_idx -= 1;
        }

        const intro: []const u8 = if (continued and has_other_provider)
            "While you were away, this conversation continued with a different AI provider. The messages you missed are below; answer the final request as the continuation of the whole conversation. Tool calls listed below ran on the other provider; do not assume their state is still live."
        else if (has_other_provider)
            "This conversation was started with a different AI provider and you are now taking over. The earlier messages are below as context; answer the final request as the continuation of that conversation. Tool calls listed below ran on the previous provider; do not assume their state is still live."
        else if (continued)
            "This conversation had additional turns while your session was paused. The messages you missed are below; answer the final request as the continuation of the whole conversation."
        else
            "This conversation continues in a new session (a branch, or a session that could not be resumed). The earlier messages are below as context; answer the final request as the continuation of that conversation.";

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, intro);
        try out.append(allocator, '\n');
        if (start_idx > 0) {
            try out.print(allocator, "({d} earlier messages omitted for length.)\n", .{start_idx});
        }
        try out.appendSlice(allocator, "<conversation_history>\n");
        for (entries.items[start_idx..]) |e| {
            try out.appendSlice(allocator, e);
        }
        try out.appendSlice(allocator, "</conversation_history>\n\n<current_user_message>\n");
        try out.appendSlice(allocator, raw_prompt);
        try out.appendSlice(allocator, "\n</current_user_message>");
        return try out.toOwnedSlice(allocator);
    }

    pub fn prepareTurnPlan(
        self: *const SessionEngine,
        allocator: Allocator,
        thread_id: u128,
        parent_user_id: u128,
        provider: iface.ProviderId,
        raw_prompt: []const u8,
    ) !TurnPlan {
        const parent_msg = self.journal.messages.get(parent_user_id);
        const prev_id: ?u128 = if (parent_msg) |pm| pm.parent_id else null;
        const expected_wt: u128 = if (self.journal.threads.get(thread_id)) |t|
            t.worktree_id
        else if (parent_msg) |pm|
            pm.worktree_id
        else
            self.workspace.history.history_id;

        const history = try self.journal.branchPath(allocator, prev_id);
        defer {
            for (history) |*m| m.deinit(allocator);
            allocator.free(history);
        }

        if (history.len == 0) {
            return .{
                .resume_id = null,
                .fork_at = null,
                .prompt = try allocator.dupe(u8, raw_prompt),
                .handoff_prompt = null,
                .delta_messages = 0,
            };
        }

        const caps = registry.capabilities(provider);
        if (caps.resume_session) {
            var ancestors: std.AutoHashMapUnmanaged(u128, void) = .empty;
            defer ancestors.deinit(allocator);
            try ancestors.ensureTotalCapacity(allocator, @intCast(history.len + 1));
            for (history) |m| ancestors.putAssumeCapacity(m.msg_id, {});
            ancestors.putAssumeCapacity(parent_user_id, {});

            var idx: usize = history.len;
            while (idx > 0) {
                idx -= 1;
                const cand = &history[idx];
                if (cand.role != .assistant) continue;
                if (cand.provider != provider) continue;
                if (cand.status != .completed and cand.status != .interrupted) continue;
                if (cand.worktree_id != expected_wt) continue;
                const sid = cand.native_session orelse continue;
                if (sid.len == 0) continue;

                var diverged = false;
                var it = self.journal.messages.valueIterator();
                while (it.next()) |m| {
                    if (m.thread_id != thread_id) continue;
                    if (m.provider != provider) continue;
                    if (ancestors.contains(m.msg_id)) continue;
                    if (m.native_session) |other_sid| {
                        if (std.mem.eql(u8, other_sid, sid)) {
                            diverged = true;
                            break;
                        }
                    }
                }

                const unseen = history[idx + 1 ..];

                if (!diverged) {
                    const prompt = if (unseen.len == 0)
                        try allocator.dupe(u8, raw_prompt)
                    else
                        try self.buildReplayPrompt(allocator, unseen, raw_prompt, provider, true);
                    errdefer allocator.free(prompt);
                    const handoff = try self.buildReplayPrompt(allocator, history, raw_prompt, provider, false);
                    errdefer allocator.free(handoff);
                    const rid = try allocator.dupe(u8, sid);
                    return .{
                        .resume_id = rid,
                        .fork_at = null,
                        .prompt = prompt,
                        .handoff_prompt = handoff,
                        .delta_messages = unseen.len,
                    };
                }

                if (caps.fork_at_message and cand.native_turn != null and cand.native_turn.?.len > 0) {
                    const prompt = if (unseen.len == 0)
                        try allocator.dupe(u8, raw_prompt)
                    else
                        try self.buildReplayPrompt(allocator, unseen, raw_prompt, provider, true);
                    errdefer allocator.free(prompt);
                    const handoff = try self.buildReplayPrompt(allocator, history, raw_prompt, provider, false);
                    errdefer allocator.free(handoff);
                    const rid = try allocator.dupe(u8, sid);
                    errdefer allocator.free(rid);
                    const fat = try allocator.dupe(u8, cand.native_turn.?);
                    return .{
                        .resume_id = rid,
                        .fork_at = fat,
                        .prompt = prompt,
                        .handoff_prompt = handoff,
                        .delta_messages = unseen.len,
                    };
                }
            }
        }

        return .{
            .resume_id = null,
            .fork_at = null,
            .prompt = try self.buildReplayPrompt(allocator, history, raw_prompt, provider, false),
            .handoff_prompt = null,
            .delta_messages = history.len,
        };
    }

    fn nextPendingSteer(self: *const SessionEngine, thread_id: u128) ?u128 {
        for (self.journal.queue_order.items) |qid| {
            const q = self.journal.queue_items.get(qid) orelse continue;
            if (q.thread_id == thread_id and q.kind == .steer and q.status == .pending) {
                return qid;
            }
        }
        return null;
    }

    fn runAssistantAfter(
        self: *SessionEngine,
        thread_id: u128,
        parent_user_id: u128,
        initial_prompt: []const u8,
        provider: iface.ProviderId,
        model_opt: ?[]const u8,
        factory: HandleFactory,
        observer: ?TurnObserver,
    ) !u128 {
        const ws = self.workspaceForThread(thread_id);
        var cur_parent = parent_user_id;
        var cur_prompt = try self.allocator.dupe(u8, initial_prompt);
        defer self.allocator.free(cur_prompt);
        var last_assistant_id: u128 = parent_user_id;
        const caps = registry.capabilities(provider);
        const allow_warm = factory.ptr == null and factory.open_fn == defaultOpenHandle and caps.persistent;

        while (true) {
            var plan = try self.prepareTurnPlan(self.allocator, thread_id, cur_parent, provider, cur_prompt);
            defer plan.deinit(self.allocator);

            try self.refreshThreadMeta(thread_id, .running);
            _ = try ws.ingestDisk();
            const pre_ver = try ws.history.headsClone();
            const post_init = try pre_ver.clone(self.allocator);
            const now = id.nowMs(self.io);
            const asst_id = id.newUuidV7(self.io);

            var label_buf: [40]u8 = undefined;
            const scope_label = std.fmt.bufPrint(&label_buf, "turn:{x:0>32}", .{asst_id}) catch "turn";
            var turn_scope: ?u128 = ws.beginScope(.turn, ws.disk_actor, scope_label) catch null;
            defer if (turn_scope) |sid| {
                ws.endScope(sid) catch {};
            };

            const gi_start = vcs.head(self.allocator, self.io, ws.root_path) catch vcs.VcsHead{};

            const running_msg = model.Message{
                .msg_id = asst_id,
                .thread_id = thread_id,
                .parent_id = cur_parent,
                .role = .assistant,
                .content = try self.allocator.dupe(u8, ""),
                .provider = provider,
                .model = if (model_opt) |m| try self.allocator.dupe(u8, m) else null,
                .native_session = if (plan.resume_id) |rs| try self.allocator.dupe(u8, rs) else null,
                .native_turn = null,
                .pre_version = pre_ver,
                .post_version = post_init,
                .git_branch = gi_start.ref_name,
                .git_commit = gi_start.rev,
                .worktree_id = ws.history.history_id,
                .status = .running,
                .steer_of = null,
                .switched_from = null,
                .created_ms = now,
                .updated_ms = now,
            };
            try self.journal.putMessage(running_msg, false);
            try self.journal.setBranchChoice(thread_id, cur_parent, asst_id);
            last_assistant_id = asst_id;

            var acc_text: std.ArrayList(u8) = .empty;
            defer acc_text.deinit(self.allocator);
            var native_session: ?[]u8 = if (plan.resume_id) |rs| try self.allocator.dupe(u8, rs) else null;
            defer if (native_session) |s| self.allocator.free(s);
            var native_turn: ?[]u8 = null;
            defer if (native_turn) |t| self.allocator.free(t);

            var final_status: model.MessageStatus = .completed;
            var fallback_steer_prompt: ?[]u8 = null;
            defer if (fallback_steer_prompt) |p| self.allocator.free(p);
            var fallback_steer_qid: ?u128 = null;

            var use_resume = plan.resume_id != null;
            var try_warm = allow_warm and use_resume and plan.fork_at == null;
            var attempt: usize = 0;
            while (attempt < 3) : (attempt += 1) {
                var from_warm = false;
                var handle: iface.RunHandle = undefined;
                if (try_warm) {
                    try_warm = false;
                    if (self.warm_pool.take(provider, plan.resume_id.?, model_opt, ws.root_path)) |warm_h| {
                        handle = warm_h;
                        from_warm = true;
                    }
                }
                if (!from_warm) {
                    const req = iface.StartRequest{
                        .cwd = ws.root_path,
                        .model = model_opt,
                        .resume_id = if (use_resume) plan.resume_id else null,
                        .fork_at = if (use_resume) plan.fork_at else null,
                        .access = .full,
                    };
                    handle = factory.open_fn(factory.ptr, self.allocator, self.io, provider, req) catch |err| {
                        if (use_resume and plan.handoff_prompt != null) {
                            use_resume = false;
                            if (native_session) |old| {
                                self.allocator.free(old);
                                native_session = null;
                            }
                            continue;
                        }
                        return err;
                    };
                }
                var handle_parked = false;
                defer if (!handle_parked) handle.close();

                const send_prompt = if (use_resume) plan.prompt else (plan.handoff_prompt orelse plan.prompt);

                handle.send(send_prompt) catch |err| {
                    if (from_warm) continue;
                    if (use_resume and plan.handoff_prompt != null) {
                        use_resume = false;
                        if (native_session) |old| {
                            self.allocator.free(old);
                            native_session = null;
                        }
                        continue;
                    }
                    return err;
                };

                var saw_turn_ended = false;
                var saw_tools = false;
                var saw_delta_in_block = false;
                final_status = .completed;

                while (try handle.next()) |raw_ev| {
                    var ev = raw_ev;
                    defer ev.deinit(self.allocator);

                    if (observer) |obs| {
                        obs.on_event(obs.ptr, thread_id, asst_id, &ev);
                    }

                    if (ev.native_message) |nm| {
                        if (native_turn) |old| self.allocator.free(old);
                        native_turn = try self.allocator.dupe(u8, nm);
                    }

                    switch (ev.kind) {
                        .session_started => |s| {
                            if (native_session) |old| self.allocator.free(old);
                            native_session = try self.allocator.dupe(u8, s.native_id);
                        },
                        .turn_started => |ts| {
                            saw_delta_in_block = false;
                            if (ts.native_turn_id) |tid| {
                                if (native_turn) |old| self.allocator.free(old);
                                native_turn = try self.allocator.dupe(u8, tid);
                            }
                        },
                        .text_delta => |d| {
                            saw_delta_in_block = true;
                            try acc_text.appendSlice(self.allocator, d.text);
                        },
                        .text => |t| {
                            if (!saw_delta_in_block and t.text.len > 0) {
                                if (acc_text.items.len > 0 and acc_text.items[acc_text.items.len - 1] != '\n') {
                                    try acc_text.append(self.allocator, '\n');
                                }
                                try acc_text.appendSlice(self.allocator, t.text);
                            }
                        },
                        .tool_started => |ts| {
                            saw_tools = true;
                            saw_delta_in_block = false;
                            self.journal.putToolCall(asst_id, ts.id, ts.name, ts.input_json, "", false) catch {};
                        },
                        .tool_finished => |tf| {
                            saw_tools = true;
                            saw_delta_in_block = false;
                            self.journal.putToolCall(asst_id, tf.id, "", "", tf.output, tf.is_error) catch {};
                        },
                        .turn_ended => |te| {
                            saw_turn_ended = true;
                            if (!te.ok) {
                                final_status = if (fallback_steer_prompt != null) .interrupted else .failed;
                            }
                            break;
                        },
                        else => {},
                    }

                    if (fallback_steer_prompt == null) {
                        if (self.nextPendingSteer(thread_id)) |sqid| {
                            const sq = self.journal.queue_items.getPtr(sqid).?;
                            const sprompt = try self.allocator.dupe(u8, sq.prompt);
                            errdefer self.allocator.free(sprompt);

                            const outcome = try handle.steer(sprompt, native_turn);
                            switch (outcome) {
                                .injected_native => {
                                    var upd_q = try sq.clone(self.allocator);
                                    upd_q.status = .injected;
                                    upd_q.updated_ms = id.nowMs(self.io);
                                    try self.journal.putQueueItem(upd_q);
                                    self.allocator.free(sprompt);
                                },
                                .requires_interrupt_fallback => {
                                    var upd_q = try sq.clone(self.allocator);
                                    upd_q.status = .dispatching;
                                    upd_q.updated_ms = id.nowMs(self.io);
                                    try self.journal.putQueueItem(upd_q);
                                    fallback_steer_prompt = sprompt;
                                    fallback_steer_qid = sqid;
                                    final_status = .interrupted;
                                    handle.interrupt();
                                },
                            }
                        }
                    }
                }

                if (from_warm and acc_text.items.len == 0 and !saw_tools and fallback_steer_prompt == null and (final_status == .failed or !saw_turn_ended)) {
                    continue;
                }

                if (use_resume and plan.handoff_prompt != null and acc_text.items.len == 0 and !saw_tools and fallback_steer_prompt == null and (final_status == .failed or !saw_turn_ended)) {
                    use_resume = false;
                    if (native_session) |old| {
                        self.allocator.free(old);
                        native_session = null;
                    }
                    if (native_turn) |old| {
                        self.allocator.free(old);
                        native_turn = null;
                    }
                    continue;
                }

                if (allow_warm and saw_turn_ended and final_status == .completed and fallback_steer_prompt == null) {
                    if (native_session) |ns| {
                        if (ns.len > 0) {
                            handle_parked = true;
                            self.warm_pool.park(provider, ns, model_opt, ws.root_path, handle);
                        }
                    }
                }
                break;
            }

            _ = try ws.ingestDisk();
            if (turn_scope) |sid| {
                ws.endScope(sid) catch {};
                turn_scope = null;
            }
            const post_ver = try ws.history.headsClone();
            const gi_end = vcs.head(self.allocator, self.io, ws.root_path) catch vcs.VcsHead{};
            const end_ms = id.nowMs(self.io);

            const existing = self.journal.messages.getPtr(asst_id).?;
            var sealed_msg = try existing.clone(self.allocator);
            self.allocator.free(sealed_msg.content);
            sealed_msg.content = try self.allocator.dupe(u8, acc_text.items);
            if (sealed_msg.native_session) |old| self.allocator.free(old);
            sealed_msg.native_session = if (native_session) |s| try self.allocator.dupe(u8, s) else null;
            if (sealed_msg.native_turn) |old| self.allocator.free(old);
            sealed_msg.native_turn = if (native_turn) |t| try self.allocator.dupe(u8, t) else null;
            sealed_msg.post_version.deinit(self.allocator);
            sealed_msg.post_version = post_ver;
            if (sealed_msg.git_branch) |old| self.allocator.free(old);
            sealed_msg.git_branch = gi_end.ref_name;
            if (sealed_msg.git_commit) |old| self.allocator.free(old);
            sealed_msg.git_commit = gi_end.rev;
            sealed_msg.status = final_status;
            sealed_msg.updated_ms = end_ms;
            try self.journal.putMessage(sealed_msg, true);

            if (self.journal.threads.getPtr(thread_id)) |t| {
                var updated = try t.clone(self.allocator);
                updated.leaf_msg_id = asst_id;
                updated.message_count = self.countBranchLen(asst_id);
                updated.head_page = try self.sealThreadPages(thread_id, asst_id);
                updated.status = if (fallback_steer_prompt != null) .steering else if (self.journal.countPendingQueue(thread_id) > 0) .queued else .idle;
                updated.queued_count = self.journal.countPendingQueue(thread_id);
                updated.updated_ms = end_ms;
                try self.journal.putThread(updated);
            }

            if (fallback_steer_prompt) |sp| {
                const steer_msg_id = try self.appendUserMessage(
                    thread_id,
                    asst_id,
                    .steer,
                    sp,
                    provider,
                    model_opt,
                    asst_id,
                    null,
                );
                if (fallback_steer_qid) |sqid| {
                    if (self.journal.queue_items.getPtr(sqid)) |sq| {
                        var done_q = try sq.clone(self.allocator);
                        done_q.status = .completed;
                        done_q.updated_ms = id.nowMs(self.io);
                        try self.journal.putQueueItem(done_q);
                    }
                }
                self.allocator.free(cur_prompt);
                cur_prompt = try self.allocator.dupe(u8, sp);
                cur_parent = steer_msg_id;
                continue;
            }
            break;
        }

        return last_assistant_id;
    }

    pub fn rollback(self: *SessionEngine, thread_id: u128, target_msg_id: ?u128) !void {
        _ = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;

        var target_ver = Version.ROOT;
        var target_gc: ?[]u8 = null;
        defer {
            target_ver.deinit(self.allocator);
            if (target_gc) |gc| self.allocator.free(gc);
        }
        if (target_msg_id) |tid| {
            const m = self.journal.messages.get(tid) orelse return error.MessageNotFound;
            if (m.thread_id != thread_id) return error.MessageWrongThread;
            target_ver = try m.post_version.clone(self.allocator);
            target_gc = if (m.git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        }

        try self.applyCrashSafeRollback(thread_id, target_msg_id, &target_ver, target_gc);
    }

    fn applyCrashSafeRollback(
        self: *SessionEngine,
        thread_id: u128,
        target_msg_id: ?u128,
        target_version: *const Version,
        target_git_commit: ?[]const u8,
    ) !void {
        const ws = self.workspaceForThread(thread_id);
        const intent_id = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);
        var cloned_ver = try target_version.clone(self.allocator);
        const cloned_gc: ?[]u8 = if (target_git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        var transferred = false;
        errdefer if (!transferred) {
            cloned_ver.deinit(self.allocator);
            if (cloned_gc) |gc| self.allocator.free(gc);
        };
        const intent = model.RollbackIntent{
            .intent_id = intent_id,
            .thread_id = thread_id,
            .target_msg_id = target_msg_id,
            .target_version = cloned_ver,
            .target_git_commit = cloned_gc,
            .created_ms = now,
        };
        try self.journal.beginRollback(intent);
        transferred = true;

        const stored = self.journal.pending_rollbacks.get(intent_id).?;
        _ = try ws.rollbackToVersion(&stored.target_version);
        if (stored.target_git_commit) |gc| {
            vcs.moveHeadSafe(self.allocator, self.io, ws.root_path, null, gc) catch {};
        }

        try self.recordBranchChoicesAlongDeferred(thread_id, target_msg_id);
        if (self.journal.threads.getPtr(thread_id)) |t| {
            var updated = try t.clone(self.allocator);
            updated.leaf_msg_id = target_msg_id;
            updated.message_count = self.countBranchLen(target_msg_id);
            updated.head_page = try self.sealThreadPages(thread_id, target_msg_id);
            updated.updated_ms = id.nowMs(self.io);
            try self.journal.putThreadDeferred(updated);
        }
        try self.journal.commitRollbackDeferred(intent_id);
        try self.journal.flushWal();
    }

    pub fn editMessage(
        self: *SessionEngine,
        thread_id: u128,
        target_msg_id: u128,
        new_prompt: []const u8,
        provider_opt: ?iface.ProviderId,
        model_opt: ?[]const u8,
    ) !u128 {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const target = self.journal.messages.get(target_msg_id) orelse return error.MessageNotFound;
        if (target.thread_id != thread_id) return error.MessageWrongThread;

        const parent_id = target.parent_id;
        const role = target.role;
        const prov = provider_opt orelse target.provider;
        const raw_model = model_opt orelse target.model orelse t.default_model;
        const effective_model: ?[]u8 = if (raw_model) |m| try self.allocator.dupe(u8, m) else null;
        defer if (effective_model) |m| self.allocator.free(m);

        var restore_ver = try target.pre_version.clone(self.allocator);
        defer restore_ver.deinit(self.allocator);
        const restore_gc: ?[]u8 = if (target.git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        defer if (restore_gc) |gc| self.allocator.free(gc);

        try self.applyCrashSafeRollback(thread_id, parent_id, &restore_ver, restore_gc);

        return try self.appendUserMessage(
            thread_id,
            parent_id,
            role,
            new_prompt,
            prov,
            effective_model,
            null,
            target_msg_id,
        );
    }

    pub fn switchBranch(self: *SessionEngine, thread_id: u128, branch_msg_id: u128) !u128 {
        _ = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const target = self.journal.messages.get(branch_msg_id) orelse return error.MessageNotFound;
        if (target.thread_id != thread_id) return error.MessageWrongThread;

        const leaf_id = self.journal.resolveBranchLeaf(thread_id, branch_msg_id);
        try self.rollback(thread_id, leaf_id);
        return leaf_id;
    }

    pub fn siblings(self: *const SessionEngine, allocator: Allocator, msg_id: u128) ![]u128 {
        return self.journal.siblings(allocator, msg_id);
    }
};
