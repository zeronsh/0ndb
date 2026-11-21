const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const ws_mod = @import("../fs/workspace.zig");
const wt_mod = @import("../fs/worktrees.zig");
const vcs = @import("../fs/vcs.zig");
const git = @import("../fs/git.zig");
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
    active_threads: std.AutoHashMapUnmanaged(u128, void),
    active_worktree_turns: std.AutoHashMapUnmanaged(u128, usize),
    rewinding_worktrees: std.AutoHashMapUnmanaged(u128, void),

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
            .active_threads = .empty,
            .active_worktree_turns = .empty,
            .rewinding_worktrees = .empty,
        };
        transferred = true;
        errdefer self.deinit();
        try self.recoverPendingRollbacksLocked();
        return self;
    }

    pub fn deinit(self: *SessionEngine) void {
        self.warm_pool.deinit();
        self.active_threads.deinit(self.allocator);
        self.active_worktree_turns.deinit(self.allocator);
        self.rewinding_worktrees.deinit(self.allocator);
        self.journal.deinit();
    }

    pub fn attachWorktrees(self: *SessionEngine, wts: ?*wt_mod.Worktrees) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.worktrees = wts;
        if (wts != null) {
            self.recoverPendingRollbacksLocked() catch {};
        }
    }

    pub fn recoverPendingRollbacks(self: *SessionEngine) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.recoverPendingRollbacksLocked();
    }

    pub fn resumeInterrupted(self: *SessionEngine) !usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.journal.resumeInterrupted();
    }

    pub fn lock(self: *SessionEngine) void {
        self.mu.lockUncancelable(self.io);
    }

    pub fn unlock(self: *SessionEngine) void {
        self.mu.unlock(self.io);
    }

    fn resolveWorkspaceForWorktreeIdLocked(self: *SessionEngine, worktree_id: u128) ?*ws_mod.Workspace {
        if (worktree_id == self.workspace.history.history_id) return self.workspace;
        if (self.worktrees) |wts| {
            return wts.getWorkspace(worktree_id);
        }
        return null;
    }

    fn workspaceForThreadLocked(self: *SessionEngine, thread_id: u128) *ws_mod.Workspace {
        if (self.journal.threads.get(thread_id)) |t| {
            if (self.resolveWorkspaceForWorktreeIdLocked(t.worktree_id)) |w| return w;
        }
        return self.workspace;
    }

    pub fn workspaceForThread(self: *SessionEngine, thread_id: u128) *ws_mod.Workspace {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.workspaceForThreadLocked(thread_id);
    }

    pub fn hibernate(self: *SessionEngine) void {
        self.warm_pool.closeIdle();
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.journal.hibernate();
        self.workspace.hibernate();
    }

    fn acquireTurnGuardLocked(self: *SessionEngine, thread_id: u128, worktree_id: u128) !void {
        if (self.active_threads.contains(thread_id)) return error.ThreadBusy;
        if (self.rewinding_worktrees.contains(worktree_id)) return error.WorktreeRewinding;
        try self.active_threads.put(self.allocator, thread_id, {});
        errdefer _ = self.active_threads.remove(thread_id);
        const gop = try self.active_worktree_turns.getOrPut(self.allocator, worktree_id);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }

    fn releaseTurnGuardLocked(self: *SessionEngine, thread_id: u128, worktree_id: u128) void {
        _ = self.active_threads.remove(thread_id);
        if (self.active_worktree_turns.getPtr(worktree_id)) |cnt| {
            if (cnt.* <= 1) {
                _ = self.active_worktree_turns.remove(worktree_id);
            } else {
                cnt.* -= 1;
            }
        }
    }

    fn acquireRewindGuardLocked(self: *SessionEngine, thread_id: u128, worktree_id: u128) !void {
        if (self.active_threads.contains(thread_id)) return error.ThreadBusy;
        if (self.rewinding_worktrees.contains(worktree_id)) return error.WorktreeRewinding;
        if ((self.active_worktree_turns.get(worktree_id) orelse 0) > 0) return error.ThreadBusy;
        try self.rewinding_worktrees.put(self.allocator, worktree_id, {});
    }

    fn releaseRewindGuardLocked(self: *SessionEngine, worktree_id: u128) void {
        _ = self.rewinding_worktrees.remove(worktree_id);
    }

    fn recoverPendingRollbacksLocked(self: *SessionEngine) !void {
        var ids: std.ArrayList(u128) = .empty;
        defer ids.deinit(self.allocator);
        {
            var it = self.journal.pending_rollbacks.keyIterator();
            while (it.next()) |k| try ids.append(self.allocator, k.*);
        }
        for (ids.items) |iid| {
            const intent = self.journal.pending_rollbacks.get(iid) orelse continue;
            const ws: *ws_mod.Workspace = blk: {
                if (self.journal.threads.get(intent.thread_id)) |t| {
                    if (t.worktree_id != self.workspace.history.history_id) {
                        const wts = self.worktrees orelse continue;
                        break :blk wts.getWorkspace(t.worktree_id) orelse continue;
                    }
                }
                break :blk self.workspace;
            };
            _ = try ws.rollbackToVersion(&intent.target_version);
            if (intent.target_git_commit) |gc| {
                vcs.moveHeadSafe(self.allocator, self.io, ws.root_path, intent.target_git_branch, gc) catch {};
            }
            try self.recordBranchChoicesAlongDeferredLocked(intent.thread_id, intent.target_msg_id);
            if (self.journal.threads.getPtr(intent.thread_id)) |t| {
                var updated = try t.clone(self.allocator);
                var owned = true;
                errdefer if (owned) updated.deinit(self.allocator);
                updated.leaf_msg_id = intent.target_msg_id;
                updated.message_count = self.countBranchLenLocked(intent.target_msg_id);
                updated.updated_ms = id.nowMs(self.io);
                updated.head_page = try self.sealThreadPagesLocked(updated.thread_id, updated.leaf_msg_id);
                try self.journal.putThreadDeferred(updated);
                owned = false;
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
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.createThreadInWorktreeLocked(title, provider, default_model, worktree_id);
    }

    fn createThreadInWorktreeLocked(
        self: *SessionEngine,
        title: []const u8,
        provider: iface.ProviderId,
        default_model: ?[]const u8,
        worktree_id: u128,
    ) !u128 {
        const ws = self.resolveWorkspaceForWorktreeIdLocked(worktree_id) orelse self.workspace;
        _ = ws.ingestDisk() catch {};
        var root_ver: ?Version = ws.history.headsClone() catch null;
        var owned = true;
        errdefer if (owned) {
            if (root_ver) |*rv| rv.deinit(self.allocator);
        };

        const title_copy = try self.allocator.dupe(u8, title);
        errdefer if (owned) self.allocator.free(title_copy);
        const model_copy: ?[]u8 = if (default_model) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (owned) if (model_copy) |m| self.allocator.free(m);

        const tid = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);
        const t = model.Thread{
            .thread_id = tid,
            .worktree_id = worktree_id,
            .title = title_copy,
            .leaf_msg_id = null,
            .head_page = null,
            .default_provider = provider,
            .default_model = model_copy,
            .status = .idle,
            .queued_count = 0,
            .message_count = 0,
            .created_ms = now,
            .updated_ms = now,
            .root_version = root_ver,
        };
        try self.journal.putThread(t);
        owned = false;
        return tid;
    }

    pub fn listSessions(self: *SessionEngine, allocator: Allocator) ![]model.SessionSummary {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
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

    fn findInSealedPagesLocked(
        self: *SessionEngine,
        out_allocator: Allocator,
        thread_id: u128,
        target_id: u128,
        cached_page: *?pager.MessagePage,
        next_page_id: *?id.PageId,
    ) !?model.Message {
        if (cached_page.*) |*page| {
            if (page.thread_id == thread_id) {
                var i: usize = page.messages.len;
                while (i > 0) {
                    i -= 1;
                    const pm = &page.messages[i];
                    if (pm.msg_id == target_id and pm.thread_id == thread_id) {
                        return try pm.clone(out_allocator);
                    }
                }
            }
        }
        while (next_page_id.*) |pid| {
            next_page_id.* = null;
            var loaded = (try pager.loadPage(self.allocator, &self.journal.pages, pid)) orelse break;
            if (loaded.thread_id != thread_id) {
                loaded.deinit(self.allocator);
                break;
            }
            next_page_id.* = loaded.prev_page;
            if (cached_page.*) |*old| old.deinit(self.allocator);
            cached_page.* = loaded;
            const page = &cached_page.*.?;
            var i: usize = page.messages.len;
            while (i > 0) {
                i -= 1;
                const pm = &page.messages[i];
                if (pm.msg_id == target_id and pm.thread_id == thread_id) {
                    return try pm.clone(out_allocator);
                }
            }
        }
        return null;
    }

    pub fn getPage(
        self: *SessionEngine,
        allocator: Allocator,
        thread_id: u128,
        before_msg_id: ?u128,
        limit: usize,
    ) !model.PageResult {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.getPageLocked(allocator, thread_id, before_msg_id, limit);
    }

    fn getPageLocked(
        self: *SessionEngine,
        allocator: Allocator,
        thread_id: u128,
        before_msg_id: ?u128,
        limit: usize,
    ) !model.PageResult {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const max_n = if (limit == 0) self.page_size else limit;

        var cached_page: ?pager.MessagePage = null;
        defer if (cached_page) |*p| p.deinit(self.allocator);
        var next_page_id: ?id.PageId = t.head_page;

        var start_id: ?u128 = t.leaf_msg_id;
        if (before_msg_id) |bid| {
            if (self.journal.messages.get(bid)) |bm| {
                if (bm.thread_id != thread_id) return error.MessageWrongThread;
                start_id = bm.parent_id;
            } else if (try self.findInSealedPagesLocked(allocator, thread_id, bid, &cached_page, &next_page_id)) |bm| {
                var owned_bm = bm;
                defer owned_bm.deinit(allocator);
                if (owned_bm.thread_id != thread_id) return error.MessageWrongThread;
                start_id = owned_bm.parent_id;
            } else {
                return error.MessageNotFound;
            }
        }

        var rev: std.ArrayList(model.Message) = .empty;
        errdefer {
            for (rev.items) |*m| m.deinit(allocator);
            rev.deinit(allocator);
        }

        var cur = start_id;
        var has_more = false;
        while (cur) |cid| {
            if (rev.items.len >= max_n) {
                has_more = true;
                break;
            }
            if (self.journal.messages.getPtr(cid)) |m| {
                if (m.thread_id != thread_id) break;
                var cloned = try m.clone(allocator);
                errdefer cloned.deinit(allocator);
                try rev.append(allocator, cloned);
                cur = m.parent_id;
            } else if (try self.findInSealedPagesLocked(allocator, thread_id, cid, &cached_page, &next_page_id)) |sealed_m| {
                var owned_m = sealed_m;
                errdefer owned_m.deinit(allocator);
                const parent_id = owned_m.parent_id;
                try rev.append(allocator, owned_m);
                cur = parent_id;
            } else {
                break;
            }
        }

        const msgs = try allocator.alloc(model.Message, rev.items.len);
        for (0..rev.items.len) |i| {
            msgs[i] = rev.items[rev.items.len - 1 - i];
        }
        rev.deinit(allocator);

        const next_before: ?u128 = if (has_more and msgs.len > 0) msgs[0].msg_id else null;
        return .{
            .messages = msgs,
            .has_more = has_more,
            .next_before = next_before,
            .head_page = t.head_page,
        };
    }

    pub fn sealThreadPages(self: *SessionEngine, thread_id: u128, leaf_id: ?u128) !?id.PageId {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.sealThreadPagesLocked(thread_id, leaf_id);
    }

    fn sealThreadPagesLocked(self: *SessionEngine, thread_id: u128, leaf_id: ?u128) !?id.PageId {
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
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const now = id.nowMs(self.io);
        const qid = id.newUuidV7(self.io);
        const prompt_copy = try self.allocator.dupe(u8, prompt);
        var owned = true;
        errdefer if (owned) self.allocator.free(prompt_copy);
        const mdl_copy: ?[]u8 = if (model_opt) |m|
            try self.allocator.dupe(u8, m)
        else if (t.default_model) |dm|
            try self.allocator.dupe(u8, dm)
        else
            null;
        errdefer if (owned) if (mdl_copy) |m| self.allocator.free(m);

        const item = model.QueueItem{
            .item_id = qid,
            .thread_id = thread_id,
            .kind = .follow_up,
            .status = .pending,
            .prompt = prompt_copy,
            .provider = provider_opt orelse t.default_provider,
            .model = mdl_copy,
            .target_turn_msg_id = null,
            .created_ms = now,
            .updated_ms = now,
        };
        try self.journal.putQueueItem(item);
        owned = false;
        try self.refreshThreadMetaLocked(thread_id, if (t.status == .idle or t.status == .failed or t.status == .interrupted) .queued else t.status);
        return qid;
    }

    pub fn steer(
        self: *SessionEngine,
        thread_id: u128,
        prompt: []const u8,
        provider_opt: ?iface.ProviderId,
        model_opt: ?[]const u8,
    ) !u128 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        const now = id.nowMs(self.io);
        const qid = id.newUuidV7(self.io);
        const prompt_copy = try self.allocator.dupe(u8, prompt);
        var owned = true;
        errdefer if (owned) self.allocator.free(prompt_copy);
        const mdl_copy: ?[]u8 = if (model_opt) |m|
            try self.allocator.dupe(u8, m)
        else if (t.default_model) |dm|
            try self.allocator.dupe(u8, dm)
        else
            null;
        errdefer if (owned) if (mdl_copy) |m| self.allocator.free(m);

        const item = model.QueueItem{
            .item_id = qid,
            .thread_id = thread_id,
            .kind = .steer,
            .status = .pending,
            .prompt = prompt_copy,
            .provider = provider_opt orelse t.default_provider,
            .model = mdl_copy,
            .target_turn_msg_id = t.leaf_msg_id,
            .created_ms = now,
            .updated_ms = now,
        };
        try self.journal.putQueueItem(item);
        owned = false;
        try self.refreshThreadMetaLocked(thread_id, if (t.status == .running) .steering else .queued);
        return qid;
    }

    pub fn cancelQueued(self: *SessionEngine, item_id: u128) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const cur = self.journal.queue_items.getPtr(item_id) orelse return error.QueueItemNotFound;
        if (cur.status != .pending) return;
        var updated = try cur.clone(self.allocator);
        var owned = true;
        errdefer if (owned) updated.deinit(self.allocator);
        updated.status = .cancelled;
        updated.updated_ms = id.nowMs(self.io);
        const tid = updated.thread_id;
        try self.journal.putQueueItem(updated);
        owned = false;
        const t = self.journal.threads.get(tid) orelse return;
        const rem = self.journal.countPendingQueue(tid);
        const st: model.SessionStatus = if (t.status == .queued and rem == 0) .idle else t.status;
        try self.refreshThreadMetaLocked(tid, st);
    }

    pub fn editQueued(self: *SessionEngine, item_id: u128, new_prompt: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const cur = self.journal.queue_items.getPtr(item_id) orelse return error.QueueItemNotFound;
        if (cur.status != .pending) return error.QueueItemNotEditable;
        var updated = try cur.clone(self.allocator);
        var owned = true;
        errdefer if (owned) updated.deinit(self.allocator);
        const np = try self.allocator.dupe(u8, new_prompt);
        self.allocator.free(updated.prompt);
        updated.prompt = np;
        updated.updated_ms = id.nowMs(self.io);
        try self.journal.putQueueItem(updated);
        owned = false;
    }

    fn refreshThreadMetaLocked(self: *SessionEngine, thread_id: u128, status: model.SessionStatus) !void {
        const t = self.journal.threads.getPtr(thread_id) orelse return;
        var updated = try t.clone(self.allocator);
        var owned = true;
        errdefer if (owned) updated.deinit(self.allocator);
        updated.status = status;
        updated.queued_count = self.journal.countPendingQueue(thread_id);
        updated.updated_ms = id.nowMs(self.io);
        try self.journal.putThread(updated);
        owned = false;
    }

    fn recordBranchChoicesAlongDeferredLocked(self: *SessionEngine, thread_id: u128, leaf_id: ?u128) !void {
        var cur = leaf_id;
        while (cur) |cid| {
            const m = self.journal.messages.get(cid) orelse break;
            if (m.parent_id) |pid| {
                _ = try self.journal.setBranchChoiceDeferred(thread_id, pid, cid);
            }
            cur = m.parent_id;
        }
    }

    fn countBranchLenLocked(self: *const SessionEngine, leaf_id: ?u128) u32 {
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
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.appendUserMessageLocked(thread_id, parent_id, role, content, provider, model_opt, steer_of, switched_from);
    }

    fn appendUserMessageLocked(
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
        const ws = self.workspaceForThreadLocked(thread_id);
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
            .err_msg = null,
        };
        try self.journal.putMessage(msg, false);
        transferred = true;
        if (parent_id) |pid| {
            try self.journal.setBranchChoice(thread_id, pid, mid);
        }

        if (self.journal.threads.getPtr(thread_id)) |t| {
            var updated = try t.clone(self.allocator);
            var owned = true;
            errdefer if (owned) updated.deinit(self.allocator);
            updated.leaf_msg_id = mid;
            updated.message_count = self.countBranchLenLocked(mid);
            updated.head_page = try self.sealThreadPagesLocked(thread_id, mid);
            updated.updated_ms = now;
            try self.journal.putThread(updated);
            owned = false;
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
        var prov: iface.ProviderId = undefined;
        var owned_mdl: ?[]u8 = null;
        defer if (owned_mdl) |m| self.allocator.free(m);
        var worktree_id: u128 = undefined;
        var user_id: u128 = undefined;

        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
            worktree_id = t.worktree_id;
            try self.acquireTurnGuardLocked(thread_id, worktree_id);
            errdefer self.releaseTurnGuardLocked(thread_id, worktree_id);

            prov = provider_opt orelse t.default_provider;
            const leaf = t.leaf_msg_id;
            const raw_mdl = model_opt orelse t.default_model;
            owned_mdl = if (raw_mdl) |m| try self.allocator.dupe(u8, m) else null;

            user_id = try self.appendUserMessageLocked(
                thread_id,
                leaf,
                .user,
                prompt,
                prov,
                owned_mdl,
                null,
                null,
            );
        }
        defer {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.releaseTurnGuardLocked(thread_id, worktree_id);
        }

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
            var next_qid: u128 = 0;
            var prompt_copy: []u8 = &.{};
            var prov: iface.ProviderId = .mock;
            var mdl_copy: ?[]u8 = null;
            var has_next = false;

            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                const pending_ids = try self.journal.pendingQueueForThread(self.allocator, thread_id);
                defer self.allocator.free(pending_ids);
                if (pending_ids.len > 0) {
                    next_qid = pending_ids[0];
                    if (self.journal.queue_items.getPtr(next_qid)) |item_ptr| {
                        var dispatching = try item_ptr.clone(self.allocator);
                        var owned = true;
                        errdefer if (owned) dispatching.deinit(self.allocator);
                        dispatching.status = .dispatching;
                        dispatching.updated_ms = id.nowMs(self.io);
                        prompt_copy = try self.allocator.dupe(u8, dispatching.prompt);
                        errdefer self.allocator.free(prompt_copy);
                        prov = dispatching.provider;
                        mdl_copy = if (dispatching.model) |m| try self.allocator.dupe(u8, m) else null;
                        errdefer if (mdl_copy) |m| self.allocator.free(m);
                        try self.journal.putQueueItem(dispatching);
                        owned = false;
                        has_next = true;
                    }
                }
            }
            if (!has_next) break;
            defer self.allocator.free(prompt_copy);
            defer if (mdl_copy) |m| self.allocator.free(m);

            var q_finalized = false;
            errdefer if (!q_finalized) {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (self.journal.queue_items.getPtr(next_qid)) |q| {
                    if (q.clone(self.allocator)) |reverted_val| {
                        var reverted = reverted_val;
                        reverted.status = .pending;
                        reverted.updated_ms = id.nowMs(self.io);
                        self.journal.putQueueItem(reverted) catch {
                            reverted.deinit(self.allocator);
                        };
                    } else |_| {}
                }
                const rem = self.journal.countPendingQueue(thread_id);
                self.refreshThreadMetaLocked(thread_id, if (rem > 0) .queued else .failed) catch {};
            };

            _ = try self.executePrompt(thread_id, prompt_copy, prov, mdl_copy, factory, observer);

            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (self.journal.queue_items.getPtr(next_qid)) |q| {
                    var done = try q.clone(self.allocator);
                    var owned = true;
                    errdefer if (owned) done.deinit(self.allocator);
                    done.status = .completed;
                    done.updated_ms = id.nowMs(self.io);
                    try self.journal.putQueueItem(done);
                    owned = false;
                }
            }
            q_finalized = true;
            processed += 1;
        }
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const rem = self.journal.countPendingQueue(thread_id);
            try self.refreshThreadMetaLocked(thread_id, if (rem > 0) .queued else .idle);
        }
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

    fn buildReplayPromptLocked(
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
        self: *SessionEngine,
        allocator: Allocator,
        thread_id: u128,
        parent_user_id: u128,
        provider: iface.ProviderId,
        raw_prompt: []const u8,
    ) !TurnPlan {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return try self.prepareTurnPlanLocked(allocator, thread_id, parent_user_id, provider, raw_prompt);
    }

    fn prepareTurnPlanLocked(
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
                        try self.buildReplayPromptLocked(allocator, unseen, raw_prompt, provider, true);
                    errdefer allocator.free(prompt);
                    const handoff = try self.buildReplayPromptLocked(allocator, history, raw_prompt, provider, false);
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
                        try self.buildReplayPromptLocked(allocator, unseen, raw_prompt, provider, true);
                    errdefer allocator.free(prompt);
                    const handoff = try self.buildReplayPromptLocked(allocator, history, raw_prompt, provider, false);
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
            .prompt = try self.buildReplayPromptLocked(allocator, history, raw_prompt, provider, false),
            .handoff_prompt = null,
            .delta_messages = history.len,
        };
    }

    fn nextPendingSteerLocked(self: *const SessionEngine, thread_id: u128) ?u128 {
        for (self.journal.queue_order.items) |qid| {
            const q = self.journal.queue_items.get(qid) orelse continue;
            if (q.thread_id == thread_id and q.kind == .steer and q.status == .pending) {
                return qid;
            }
        }
        return null;
    }

    fn finalizeAbortedTurn(
        self: *SessionEngine,
        thread_id: u128,
        asst_id: u128,
        acc_text: []const u8,
        native_session: ?[]const u8,
        native_turn: ?[]const u8,
        turn_err_msg: ?[]const u8,
        fallback_steer_qid: ?u128,
    ) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const end_ms = id.nowMs(self.io);
        if (fallback_steer_qid) |sqid| {
            if (self.journal.queue_items.getPtr(sqid)) |sq| {
                if (sq.status == .dispatching) {
                    if (sq.clone(self.allocator)) |rev_val| {
                        var rev = rev_val;
                        rev.status = .pending;
                        rev.updated_ms = end_ms;
                        self.journal.putQueueItem(rev) catch {
                            rev.deinit(self.allocator);
                        };
                    } else |_| {}
                }
            }
        }

        if (self.journal.messages.getPtr(asst_id)) |existing| {
            if (existing.clone(self.allocator)) |sealed_val| {
                var sealed = sealed_val;
                if (self.allocator.dupe(u8, acc_text)) |c| {
                    self.allocator.free(sealed.content);
                    sealed.content = c;
                } else |_| {}
                if (native_session) |s| {
                    if (self.allocator.dupe(u8, s)) |ns| {
                        if (sealed.native_session) |old| self.allocator.free(old);
                        sealed.native_session = ns;
                    } else |_| {}
                }
                if (native_turn) |nt| {
                    if (self.allocator.dupe(u8, nt)) |ntc| {
                        if (sealed.native_turn) |old| self.allocator.free(old);
                        sealed.native_turn = ntc;
                    } else |_| {}
                }
                const em_src = turn_err_msg orelse "turn aborted";
                if (self.allocator.dupe(u8, em_src)) |emc| {
                    if (sealed.err_msg) |old| self.allocator.free(old);
                    sealed.err_msg = emc;
                } else |_| {}
                sealed.status = .failed;
                sealed.updated_ms = end_ms;
                self.journal.putMessage(sealed, true) catch {
                    sealed.deinit(self.allocator);
                };
            } else |_| {}
        }

        if (self.journal.threads.getPtr(thread_id)) |t| {
            if (t.clone(self.allocator)) |upd_val| {
                var updated = upd_val;
                updated.leaf_msg_id = asst_id;
                updated.message_count = self.countBranchLenLocked(asst_id);
                updated.head_page = self.sealThreadPagesLocked(thread_id, asst_id) catch updated.head_page;
                updated.queued_count = self.journal.countPendingQueue(thread_id);
                updated.status = if (updated.queued_count > 0) .queued else .failed;
                updated.updated_ms = end_ms;
                self.journal.putThread(updated) catch {
                    updated.deinit(self.allocator);
                };
            } else |_| {}
        }
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
            var plan: TurnPlan = undefined;
            var asst_id: u128 = 0;
            var turn_scope: ?u128 = null;

            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);

                plan = try self.prepareTurnPlanLocked(self.allocator, thread_id, cur_parent, provider, cur_prompt);
                errdefer plan.deinit(self.allocator);

                try self.refreshThreadMetaLocked(thread_id, .running);
                _ = try ws.ingestDisk();
                var pre_ver = try ws.history.headsClone();
                var transferred = false;
                errdefer if (!transferred) pre_ver.deinit(self.allocator);
                var post_init = try pre_ver.clone(self.allocator);
                errdefer if (!transferred) post_init.deinit(self.allocator);

                const now = id.nowMs(self.io);
                asst_id = id.newUuidV7(self.io);

                var label_buf: [40]u8 = undefined;
                const scope_label = std.fmt.bufPrint(&label_buf, "turn:{x:0>32}", .{asst_id}) catch "turn";
                turn_scope = ws.beginScope(.turn, ws.disk_actor, scope_label) catch null;
                errdefer if (turn_scope) |sid| {
                    ws.endScope(sid) catch {};
                    turn_scope = null;
                };

                var gi_start = vcs.head(self.allocator, self.io, ws.root_path) catch vcs.VcsHead{};
                errdefer if (!transferred) gi_start.deinit(self.allocator);

                const empty_content = try self.allocator.dupe(u8, "");
                errdefer if (!transferred) self.allocator.free(empty_content);
                const mdl_copy: ?[]u8 = if (model_opt) |m| try self.allocator.dupe(u8, m) else null;
                errdefer if (!transferred) if (mdl_copy) |m| self.allocator.free(m);
                const ns_init: ?[]u8 = if (plan.resume_id) |rs| try self.allocator.dupe(u8, rs) else null;
                errdefer if (!transferred) if (ns_init) |s| self.allocator.free(s);

                const running_msg = model.Message{
                    .msg_id = asst_id,
                    .thread_id = thread_id,
                    .parent_id = cur_parent,
                    .role = .assistant,
                    .content = empty_content,
                    .provider = provider,
                    .model = mdl_copy,
                    .native_session = ns_init,
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
                    .err_msg = null,
                };
                try self.journal.putMessage(running_msg, false);
                transferred = true;
                try self.journal.setBranchChoice(thread_id, cur_parent, asst_id);
                last_assistant_id = asst_id;
            }
            defer plan.deinit(self.allocator);
            defer if (turn_scope) |sid| {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                ws.endScope(sid) catch {};
            };

            var acc_text: std.ArrayList(u8) = .empty;
            defer acc_text.deinit(self.allocator);
            var native_session: ?[]u8 = if (plan.resume_id) |rs| try self.allocator.dupe(u8, rs) else null;
            defer if (native_session) |s| self.allocator.free(s);
            var native_turn: ?[]u8 = null;
            defer if (native_turn) |t| self.allocator.free(t);
            var turn_err_msg: ?[]u8 = null;
            defer if (turn_err_msg) |e| self.allocator.free(e);

            var final_status: model.MessageStatus = .failed;
            var fallback_steer_prompt: ?[]u8 = null;
            defer if (fallback_steer_prompt) |p| self.allocator.free(p);
            var fallback_steer_qid: ?u128 = null;

            var finalized = false;
            errdefer if (!finalized) {
                self.finalizeAbortedTurn(
                    thread_id,
                    asst_id,
                    acc_text.items,
                    native_session,
                    native_turn,
                    turn_err_msg,
                    fallback_steer_qid,
                );
            };

            var use_resume = plan.resume_id != null;
            var try_warm = allow_warm and use_resume and plan.fork_at == null;
            var attempt: usize = 0;
            while (attempt < 3) : (attempt += 1) {
                acc_text.clearRetainingCapacity();
                if (turn_err_msg) |old| {
                    self.allocator.free(old);
                    turn_err_msg = null;
                }
                final_status = .failed;

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
                        if (turn_err_msg) |old| self.allocator.free(old);
                        turn_err_msg = self.allocator.dupe(u8, @errorName(err)) catch null;
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
                    if (turn_err_msg) |old| self.allocator.free(old);
                    turn_err_msg = self.allocator.dupe(u8, @errorName(err)) catch null;
                    return err;
                };

                var saw_turn_ended = false;
                var saw_tools = false;
                var saw_delta_in_block = false;
                var needs_block_sep = false;

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
                            needs_block_sep = false;
                            if (ts.native_turn_id) |tid| {
                                if (native_turn) |old| self.allocator.free(old);
                                native_turn = try self.allocator.dupe(u8, tid);
                            }
                        },
                        .text_delta => |d| {
                            if (d.text.len > 0) {
                                if (needs_block_sep and acc_text.items.len > 0 and acc_text.items[acc_text.items.len - 1] != '\n') {
                                    try acc_text.append(self.allocator, '\n');
                                }
                                needs_block_sep = false;
                                saw_delta_in_block = true;
                                try acc_text.appendSlice(self.allocator, d.text);
                            }
                        },
                        .text => |t| {
                            if (!saw_delta_in_block and t.text.len > 0) {
                                if (acc_text.items.len > 0 and acc_text.items[acc_text.items.len - 1] != '\n') {
                                    try acc_text.append(self.allocator, '\n');
                                }
                                try acc_text.appendSlice(self.allocator, t.text);
                            }
                            saw_delta_in_block = false;
                            needs_block_sep = false;
                        },
                        .reasoning, .reasoning_delta => {
                            saw_delta_in_block = false;
                        },
                        .tool_started => |ts| {
                            saw_tools = true;
                            saw_delta_in_block = false;
                            if (acc_text.items.len > 0) needs_block_sep = true;
                            self.mu.lockUncancelable(self.io);
                            defer self.mu.unlock(self.io);
                            self.journal.putToolCall(asst_id, ts.id, ts.name, ts.input_json, "", false) catch {};
                        },
                        .tool_finished => |tf| {
                            saw_tools = true;
                            saw_delta_in_block = false;
                            if (acc_text.items.len > 0) needs_block_sep = true;
                            self.mu.lockUncancelable(self.io);
                            defer self.mu.unlock(self.io);
                            self.journal.putToolCall(asst_id, tf.id, "", "", tf.output, tf.is_error) catch {};
                        },
                        .turn_ended => |te| {
                            saw_turn_ended = true;
                            if (te.ok) {
                                final_status = if (fallback_steer_prompt != null) .interrupted else .completed;
                            } else {
                                final_status = if (fallback_steer_prompt != null) .interrupted else .failed;
                                if (te.err_msg) |em| {
                                    if (turn_err_msg) |old| self.allocator.free(old);
                                    turn_err_msg = try self.allocator.dupe(u8, em);
                                }
                            }
                            break;
                        },
                        else => {},
                    }

                    if (fallback_steer_prompt == null) {
                        var steer_qid: ?u128 = null;
                        var sprompt_opt: ?[]u8 = null;
                        {
                            self.mu.lockUncancelable(self.io);
                            defer self.mu.unlock(self.io);
                            if (self.nextPendingSteerLocked(thread_id)) |sqid| {
                                if (self.journal.queue_items.getPtr(sqid)) |sq| {
                                    sprompt_opt = try self.allocator.dupe(u8, sq.prompt);
                                    steer_qid = sqid;
                                }
                            }
                        }
                        if (sprompt_opt) |sprompt| {
                            const sqid = steer_qid.?;
                            errdefer self.allocator.free(sprompt);
                            const outcome = try handle.steer(sprompt, native_turn);
                            switch (outcome) {
                                .injected_native => {
                                    {
                                        self.mu.lockUncancelable(self.io);
                                        defer self.mu.unlock(self.io);
                                        if (self.journal.queue_items.getPtr(sqid)) |sq| {
                                            var upd_q = try sq.clone(self.allocator);
                                            var owned = true;
                                            errdefer if (owned) upd_q.deinit(self.allocator);
                                            upd_q.status = .injected;
                                            upd_q.updated_ms = id.nowMs(self.io);
                                            try self.journal.putQueueItem(upd_q);
                                            owned = false;
                                        }
                                    }
                                    self.allocator.free(sprompt);
                                },
                                .requires_interrupt_fallback => {
                                    {
                                        self.mu.lockUncancelable(self.io);
                                        defer self.mu.unlock(self.io);
                                        if (self.journal.queue_items.getPtr(sqid)) |sq| {
                                            var upd_q = try sq.clone(self.allocator);
                                            var owned = true;
                                            errdefer if (owned) upd_q.deinit(self.allocator);
                                            upd_q.status = .dispatching;
                                            upd_q.updated_ms = id.nowMs(self.io);
                                            try self.journal.putQueueItem(upd_q);
                                            owned = false;
                                        }
                                    }
                                    fallback_steer_prompt = sprompt;
                                    fallback_steer_qid = sqid;
                                    final_status = .interrupted;
                                    handle.interrupt();
                                },
                            }
                        }
                    }
                }

                if (!saw_turn_ended) {
                    final_status = if (fallback_steer_prompt != null) .interrupted else .failed;
                    if (final_status == .failed and turn_err_msg == null) {
                        turn_err_msg = self.allocator.dupe(u8, "provider stream ended unexpectedly") catch null;
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

            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);

                _ = try ws.ingestDisk();
                if (turn_scope) |sid| {
                    ws.endScope(sid) catch {};
                    turn_scope = null;
                }
                var post_ver = try ws.history.headsClone();
                var post_owned = true;
                errdefer if (post_owned) post_ver.deinit(self.allocator);
                var gi_end = vcs.head(self.allocator, self.io, ws.root_path) catch vcs.VcsHead{};
                var gi_owned = true;
                errdefer if (gi_owned) gi_end.deinit(self.allocator);
                const end_ms = id.nowMs(self.io);

                const existing = self.journal.messages.getPtr(asst_id).?;
                var sealed_msg = try existing.clone(self.allocator);
                var sealed_owned = true;
                errdefer if (sealed_owned) sealed_msg.deinit(self.allocator);

                const content_copy = try self.allocator.dupe(u8, acc_text.items);
                self.allocator.free(sealed_msg.content);
                sealed_msg.content = content_copy;

                const ns_copy: ?[]u8 = if (native_session) |s| try self.allocator.dupe(u8, s) else null;
                if (sealed_msg.native_session) |old| self.allocator.free(old);
                sealed_msg.native_session = ns_copy;

                const nt_copy: ?[]u8 = if (native_turn) |t| try self.allocator.dupe(u8, t) else null;
                if (sealed_msg.native_turn) |old| self.allocator.free(old);
                sealed_msg.native_turn = nt_copy;

                const err_copy: ?[]u8 = if (turn_err_msg) |e| try self.allocator.dupe(u8, e) else null;
                if (sealed_msg.err_msg) |old| self.allocator.free(old);
                sealed_msg.err_msg = err_copy;

                sealed_msg.post_version.deinit(self.allocator);
                sealed_msg.post_version = post_ver;
                post_owned = false;

                if (sealed_msg.git_branch) |old| self.allocator.free(old);
                sealed_msg.git_branch = gi_end.ref_name;
                if (sealed_msg.git_commit) |old| self.allocator.free(old);
                sealed_msg.git_commit = gi_end.rev;
                gi_owned = false;

                sealed_msg.status = final_status;
                sealed_msg.updated_ms = end_ms;
                try self.journal.putMessage(sealed_msg, true);
                sealed_owned = false;

                if (self.journal.threads.getPtr(thread_id)) |t| {
                    var updated = try t.clone(self.allocator);
                    var owned = true;
                    errdefer if (owned) updated.deinit(self.allocator);
                    updated.leaf_msg_id = asst_id;
                    updated.message_count = self.countBranchLenLocked(asst_id);
                    updated.head_page = try self.sealThreadPagesLocked(thread_id, asst_id);
                    updated.queued_count = self.journal.countPendingQueue(thread_id);
                    updated.status = if (fallback_steer_prompt != null)
                        .steering
                    else if (updated.queued_count > 0)
                        .queued
                    else switch (final_status) {
                        .failed => .failed,
                        .interrupted => .interrupted,
                        else => .idle,
                    };
                    updated.updated_ms = end_ms;
                    try self.journal.putThread(updated);
                    owned = false;
                }
                finalized = true;

                if (fallback_steer_prompt) |sp| {
                    const steer_msg_id = try self.appendUserMessageLocked(
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
                            var owned = true;
                            errdefer if (owned) done_q.deinit(self.allocator);
                            done_q.status = .completed;
                            done_q.updated_ms = id.nowMs(self.io);
                            try self.journal.putQueueItem(done_q);
                            owned = false;
                        }
                    }
                    const next_prompt = try self.allocator.dupe(u8, sp);
                    self.allocator.free(cur_prompt);
                    cur_prompt = next_prompt;
                    cur_parent = steer_msg_id;
                }
            }

            if (fallback_steer_prompt != null) continue;
            break;
        }

        return last_assistant_id;
    }

    pub fn rollback(self: *SessionEngine, thread_id: u128, target_msg_id: ?u128) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        try self.acquireRewindGuardLocked(thread_id, t.worktree_id);
        defer self.releaseRewindGuardLocked(t.worktree_id);
        try self.rollbackLocked(thread_id, target_msg_id);
    }

    fn rollbackLocked(self: *SessionEngine, thread_id: u128, target_msg_id: ?u128) !void {
        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;

        var target_ver = Version.ROOT;
        var target_gb: ?[]u8 = null;
        var target_gc: ?[]u8 = null;
        defer {
            target_ver.deinit(self.allocator);
            if (target_gb) |gb| self.allocator.free(gb);
            if (target_gc) |gc| self.allocator.free(gc);
        }
        if (target_msg_id) |tid| {
            const m = self.journal.messages.get(tid) orelse return error.MessageNotFound;
            if (m.thread_id != thread_id) return error.MessageWrongThread;
            target_ver = try m.post_version.clone(self.allocator);
            target_gb = if (m.git_branch) |gb| try self.allocator.dupe(u8, gb) else null;
            target_gc = if (m.git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        } else {
            if (t.root_version) |*rv| {
                target_ver = try rv.clone(self.allocator);
            } else if (self.journal.root_messages.get(thread_id)) |roots| {
                if (roots.items.len > 0) {
                    if (self.journal.messages.get(roots.items[0])) |rm| {
                        target_ver = try rm.pre_version.clone(self.allocator);
                    }
                }
            }
        }

        try self.applyCrashSafeRollbackLocked(thread_id, target_msg_id, &target_ver, target_gb, target_gc);
    }

    fn applyCrashSafeRollbackLocked(
        self: *SessionEngine,
        thread_id: u128,
        target_msg_id: ?u128,
        target_version: *const Version,
        target_git_branch: ?[]const u8,
        target_git_commit: ?[]const u8,
    ) !void {
        const ws = self.workspaceForThreadLocked(thread_id);

        if (vcs.detectKind(self.io, ws.root_path) == .git) {
            if (vcs.operationInProgress(self.allocator, self.io, ws.root_path) != null) {
                return error.VcsOperationInProgress;
            }
            if (target_git_commit) |gc| {
                if (!git.commitExists(self.allocator, self.io, ws.root_path, gc)) {
                    return error.RevMissing;
                }
            }
        }

        const intent_id = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);
        var cloned_ver = try target_version.clone(self.allocator);
        var transferred = false;
        errdefer if (!transferred) cloned_ver.deinit(self.allocator);
        const cloned_gc: ?[]u8 = if (target_git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        errdefer if (!transferred) if (cloned_gc) |gc| self.allocator.free(gc);
        const cloned_gb: ?[]u8 = if (target_git_branch) |gb| try self.allocator.dupe(u8, gb) else null;
        errdefer if (!transferred) if (cloned_gb) |gb| self.allocator.free(gb);

        const intent = model.RollbackIntent{
            .intent_id = intent_id,
            .thread_id = thread_id,
            .target_msg_id = target_msg_id,
            .target_version = cloned_ver,
            .target_git_commit = cloned_gc,
            .created_ms = now,
            .target_git_branch = cloned_gb,
        };
        try self.journal.beginRollback(intent);
        transferred = true;

        const stored = self.journal.pending_rollbacks.get(intent_id).?;
        _ = try ws.rollbackToVersion(&stored.target_version);
        if (stored.target_git_commit) |gc| {
            vcs.moveHeadSafe(self.allocator, self.io, ws.root_path, stored.target_git_branch, gc) catch {};
        }

        try self.recordBranchChoicesAlongDeferredLocked(thread_id, target_msg_id);
        if (self.journal.threads.getPtr(thread_id)) |t| {
            var updated = try t.clone(self.allocator);
            var owned = true;
            errdefer if (owned) updated.deinit(self.allocator);
            updated.leaf_msg_id = target_msg_id;
            updated.message_count = self.countBranchLenLocked(target_msg_id);
            updated.head_page = try self.sealThreadPagesLocked(thread_id, target_msg_id);
            updated.updated_ms = id.nowMs(self.io);
            try self.journal.putThreadDeferred(updated);
            owned = false;
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
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        try self.acquireRewindGuardLocked(thread_id, t.worktree_id);
        defer self.releaseRewindGuardLocked(t.worktree_id);

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
        const restore_gb: ?[]u8 = if (target.git_branch) |gb| try self.allocator.dupe(u8, gb) else null;
        defer if (restore_gb) |gb| self.allocator.free(gb);
        const restore_gc: ?[]u8 = if (target.git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        defer if (restore_gc) |gc| self.allocator.free(gc);

        try self.applyCrashSafeRollbackLocked(thread_id, parent_id, &restore_ver, restore_gb, restore_gc);

        return try self.appendUserMessageLocked(
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
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        const t = self.journal.threads.get(thread_id) orelse return error.ThreadNotFound;
        try self.acquireRewindGuardLocked(thread_id, t.worktree_id);
        defer self.releaseRewindGuardLocked(t.worktree_id);

        const target = self.journal.messages.get(branch_msg_id) orelse return error.MessageNotFound;
        if (target.thread_id != thread_id) return error.MessageWrongThread;

        const leaf_id = self.journal.resolveBranchLeaf(thread_id, branch_msg_id);
        try self.rollbackLocked(thread_id, leaf_id);
        return leaf_id;
    }

    pub fn siblings(self: *SessionEngine, allocator: Allocator, msg_id: u128) ![]u128 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.journal.siblings(allocator, msg_id);
    }
};
