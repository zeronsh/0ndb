const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const Version = version_mod.Version;
const text_mod = @import("../core/text.zig");
const blobs_mod = @import("../store/blobs.zig");
const crypto = @import("../store/crypto.zig");
const space_mod = @import("../space/space.zig");
const manager_mod = @import("../space/manager.zig");
const project_mod = @import("../project/project.zig");
const vcs = @import("../fs/vcs.zig");
const iface = @import("../providers/interface.zig");
const providers_registry = @import("../providers/registry.zig");
const wire = @import("../sync/wire.zig");
const keyring_mod = @import("../sync/keyring.zig");
const lease_mod = @import("../sync/lease.zig");
const model = @import("model.zig");
const store_mod = @import("store.zig");

pub const DEFAULT_LEASE_TTL_MS: u64 = 30_000;
pub const DEFAULT_MAX_OPEN_THREADS: usize = 64;

pub const RuntimeError = error{
    ThreadNotFound,
    MessageNotFound,
    TaskNotFound,
    TriggerNotFound,
    SpaceNotBound,
    PermissionDenied,
    NotFound,
    InvalidEdit,
    LeaseNotActive,
    LeaseEpochMismatch,
    InvalidTaskTransition,
    RollbackTargetInvalid,
    RollbackSpaceReadOnly,
    RollbackAlreadyPending,
    NoPendingRollback,
    InvalidCronExpression,
    ForkNotFound,
};

pub const TopicKind = enum(u8) {
    catalog = 1,
    project = 2,
    space = 3,
    thread = 4,
    mailbox = 5,
};

pub fn topicId(kind: TopicKind, entity_id: u128) [32]u8 {
    return switch (kind) {
        .catalog => id.streamId("catalog", entity_id),
        .project => id.streamId("project", entity_id),
        .space => id.streamId("space", entity_id),
        .thread => id.streamId("thread", entity_id),
        .mailbox => id.streamId("mailbox", entity_id),
    };
}

pub const ProviderOpenFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    provider: iface.ProviderId,
    req: iface.StartRequest,
) anyerror!iface.RunHandle;

pub const ProviderRegistry = struct {
    open_fn: ?ProviderOpenFn = null,
    ctx: ?*anyopaque = null,

    pub fn start(
        self: *const ProviderRegistry,
        allocator: Allocator,
        io: Io,
        provider: iface.ProviderId,
        req: iface.StartRequest,
    ) !iface.RunHandle {
        if (self.open_fn) |f| {
            return f(self.ctx, allocator, io, provider, req);
        }
        return providers_registry.start(allocator, io, provider, req);
    }
};

pub const SpaceVirtualBridge = struct {
    allocator: Allocator,
    spaces: *manager_mod.SpaceManager,
    bindings: []model.SpaceBinding,
    actor_id: u128,

    pub fn init(
        allocator: Allocator,
        spaces: *manager_mod.SpaceManager,
        bindings: []const model.SpaceBinding,
        actor_id: u128,
    ) Allocator.Error!SpaceVirtualBridge {
        return .{
            .allocator = allocator,
            .spaces = spaces,
            .bindings = try model.cloneBindings(allocator, bindings),
            .actor_id = actor_id,
        };
    }

    pub fn deinit(self: *SpaceVirtualBridge) void {
        model.freeBindings(self.allocator, self.bindings);
        self.bindings = &.{};
    }

    pub fn asInterface(self: *SpaceVirtualBridge) iface.VirtualSpaceBridge {
        return .{
            .ctx = @ptrCast(self),
            .listFn = vtableList,
            .readFn = vtableRead,
            .writeFn = vtableWrite,
            .editFn = vtableEdit,
            .deleteFn = vtableDelete,
            .searchFn = vtableSearch,
            .metaGetFn = vtableMetaGet,
            .metaSetFn = vtableMetaSet,
        };
    }

    fn findBinding(self: *const SpaceVirtualBridge, space_id: u128) RuntimeError!*const model.SpaceBinding {
        for (self.bindings) |*b| {
            if (b.space_id == space_id) return b;
        }
        return error.SpaceNotBound;
    }

    fn requireWritable(self: *const SpaceVirtualBridge, space_id: u128) RuntimeError!void {
        const b = try self.findBinding(space_id);
        if (b.access == .read_only) return error.PermissionDenied;
    }

    pub fn listDir(self: *SpaceVirtualBridge, allocator: Allocator, space_id: u128, prefix: []const u8) ![][]u8 {
        _ = try self.findBinding(space_id);
        const sp = try self.spaces.activate(space_id);
        const entries = try sp.listDir(allocator, prefix);
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        const out = try allocator.alloc([]u8, entries.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |item| allocator.free(item);
            allocator.free(out);
        }
        for (entries, 0..) |e, i| {
            out[i] = try allocator.dupe(u8, e.name);
            built += 1;
        }
        std.mem.sort([]u8, out, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return out;
    }

    pub fn readFile(self: *SpaceVirtualBridge, allocator: Allocator, space_id: u128, path: []const u8) !?[]u8 {
        _ = try self.findBinding(space_id);
        const sp = try self.spaces.activate(space_id);
        return try sp.readFileAlloc(allocator, path);
    }

    pub fn writeFile(self: *SpaceVirtualBridge, space_id: u128, path: []const u8, content: []const u8) !void {
        try self.requireWritable(space_id);
        const sp = try self.spaces.activate(space_id);
        _ = try sp.putFile(self.actor_id, path, content);
    }

    pub fn editText(
        self: *SpaceVirtualBridge,
        space_id: u128,
        path: []const u8,
        old_str: []const u8,
        new_str: []const u8,
    ) !void {
        try self.requireWritable(space_id);
        if (old_str.len == 0) return error.InvalidEdit;
        const sp = try self.spaces.activate(space_id);
        const current = (try sp.readFileAlloc(self.allocator, path)) orelse return error.NotFound;
        defer self.allocator.free(current);
        const idx = std.mem.indexOf(u8, current, old_str) orelse return error.InvalidEdit;
        const splices = [_]text_mod.TextSplice{.{
            .at = idx,
            .del = old_str.len,
            .text = @constCast(new_str),
        }};
        _ = try sp.editText(self.actor_id, path, &splices);
    }

    pub fn deletePath(self: *SpaceVirtualBridge, space_id: u128, path: []const u8) !void {
        try self.requireWritable(space_id);
        const sp = try self.spaces.activate(space_id);
        _ = try sp.deletePath(self.actor_id, path);
    }

    pub fn searchText(self: *SpaceVirtualBridge, allocator: Allocator, space_id: u128, query: []const u8) ![][]u8 {
        _ = try self.findBinding(space_id);
        const sp = try self.spaces.activate(space_id);
        const hits = try sp.searchText(allocator, query, null, 256);
        defer {
            for (hits) |*h| h.deinit(allocator);
            allocator.free(hits);
        }
        const out = try allocator.alloc([]u8, hits.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |item| allocator.free(item);
            allocator.free(out);
        }
        for (hits, 0..) |h, i| {
            out[i] = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ h.path, h.line, h.snippet });
            built += 1;
        }
        return out;
    }

    pub fn getMeta(self: *SpaceVirtualBridge, allocator: Allocator, space_id: u128, key: []const u8) !?[]u8 {
        _ = try self.findBinding(space_id);
        const sp = try self.spaces.activate(space_id);
        const val = sp.getMeta(key) orelse return null;
        return try allocator.dupe(u8, val);
    }

    pub fn setMeta(self: *SpaceVirtualBridge, space_id: u128, key: []const u8, val: ?[]const u8) !void {
        try self.requireWritable(space_id);
        const sp = try self.spaces.activate(space_id);
        _ = try sp.setMeta(self.actor_id, key, val);
    }

    pub fn listMetaPrefix(
        self: *SpaceVirtualBridge,
        allocator: Allocator,
        space_id: u128,
        prefix: []const u8,
    ) ![]space_mod.MetaEntry {
        _ = try self.findBinding(space_id);
        const sp = try self.spaces.activate(space_id);
        return try sp.listMetaPrefix(allocator, prefix);
    }

    pub fn checkpoint(self: *SpaceVirtualBridge, space_id: u128, kind: space_mod.CheckpointKind) !void {
        try self.requireWritable(space_id);
        const sp = try self.spaces.activate(space_id);
        try sp.checkpoint(kind);
    }

    fn vtableList(ctx: *anyopaque, allocator: Allocator, space_id: u128, prefix: []const u8) anyerror![][]u8 {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.listDir(allocator, space_id, prefix);
    }

    fn vtableRead(ctx: *anyopaque, allocator: Allocator, space_id: u128, path: []const u8) anyerror!?[]u8 {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.readFile(allocator, space_id, path);
    }

    fn vtableWrite(ctx: *anyopaque, space_id: u128, path: []const u8, content: []const u8) anyerror!void {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.writeFile(space_id, path, content);
    }

    fn vtableEdit(
        ctx: *anyopaque,
        space_id: u128,
        path: []const u8,
        old_str: []const u8,
        new_str: []const u8,
    ) anyerror!void {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.editText(space_id, path, old_str, new_str);
    }

    fn vtableDelete(ctx: *anyopaque, space_id: u128, path: []const u8) anyerror!void {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.deletePath(space_id, path);
    }

    fn vtableSearch(ctx: *anyopaque, allocator: Allocator, space_id: u128, query: []const u8) anyerror![][]u8 {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.searchText(allocator, space_id, query);
    }

    fn vtableMetaGet(ctx: *anyopaque, allocator: Allocator, space_id: u128, key: []const u8) anyerror!?[]u8 {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.getMeta(allocator, space_id, key);
    }

    fn vtableMetaSet(ctx: *anyopaque, space_id: u128, key: []const u8, val: []const u8) anyerror!void {
        const self: *SpaceVirtualBridge = @ptrCast(@alignCast(ctx));
        return self.setMeta(space_id, key, val);
    }
};

pub const InitOptions = struct {
    spaces: *manager_mod.SpaceManager,
    projects: *project_mod.ProjectStore,
    catalog: *store_mod.CatalogStore,
    keyring: *keyring_mod.Keyring,
    leases: *lease_mod.LeaseManager,
    providers: ?*const ProviderRegistry = null,
    root_dir: []const u8,
    runner_id: u128,
    device_id: u128,
    shared_blobs: ?*blobs_mod.SharedBlobPool = null,
    max_open_threads: usize = DEFAULT_MAX_OPEN_THREADS,
};

pub const CreateThreadOptions = struct {
    title: []const u8 = "",
    project_id: ?u128 = null,
    bindings: []const model.SpaceBinding = &.{},
    parent_thread_id: ?u128 = null,
    root_thread_id: ?u128 = null,
    parent_task_id: ?u128 = null,
    depth: u8 = 0,
    budget: model.Budget = .{},
    placement: model.PlacementPolicy = .any,
    provider_id: iface.ProviderId = .mock,
    model: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
};

pub const BeginTurnOptions = struct {
    provider: ?iface.ProviderId = null,
    model: ?[]const u8 = null,
    parent_msg_id: ?u128 = null,
    lease_ttl_ms: u64 = DEFAULT_LEASE_TTL_MS,
};

pub const BeginTurnResult = struct {
    turn_id: u128,
    user_msg_id: u128,
    fencing_epoch: u64,
    pre_checkpoint: model.CheckpointVector,

    pub fn deinit(self: *BeginTurnResult, allocator: Allocator) void {
        self.pre_checkpoint.deinit(allocator);
    }
};

pub const TurnUsage = struct {
    tokens: u64 = 0,
    cost_microusd: u64 = 0,
    wall_ms: u64 = 0,
};

pub const OwnedMountSpec = struct {
    alias: []u8,
    space_id: u128,
    kind: iface.MountKind,
    access: iface.MountAccess,
    local_path: ?[]u8 = null,

    pub fn deinit(self: *OwnedMountSpec, allocator: Allocator) void {
        if (self.alias.len > 0) allocator.free(self.alias);
        if (self.local_path) |p| allocator.free(p);
        self.alias = &.{};
        self.local_path = null;
    }

    pub fn toSpec(self: *const OwnedMountSpec) iface.MountSpec {
        return .{
            .alias = self.alias,
            .space_id = self.space_id,
            .kind = self.kind,
            .access = self.access,
            .local_path = self.local_path,
        };
    }
};

pub const ProviderStartPlan = struct {
    provider: iface.ProviderId,
    resumed_natively: bool,
    cwd: []u8,
    model: ?[]u8 = null,
    resume_session_id: ?[]u8 = null,
    fallback_prompt_history: ?[]u8 = null,
    owned_mounts: []OwnedMountSpec = &.{},
    mounts: []iface.MountSpec = &.{},
    virtual_bridge_owner: ?*SpaceVirtualBridge = null,
    virtual_bridge_iface: ?*iface.VirtualSpaceBridge = null,
    start_request: iface.StartRequest,
    bindings_digest: [32]u8,
    mounts_digest: [32]u8,

    pub fn deinit(self: *ProviderStartPlan, allocator: Allocator) void {
        if (self.cwd.len > 0) allocator.free(self.cwd);
        if (self.model) |m| allocator.free(m);
        if (self.resume_session_id) |r| allocator.free(r);
        if (self.fallback_prompt_history) |h| allocator.free(h);
        if (self.owned_mounts.len > 0) {
            for (self.owned_mounts) |*m| m.deinit(allocator);
            allocator.free(self.owned_mounts);
        }
        if (self.mounts.len > 0) allocator.free(self.mounts);
        if (self.virtual_bridge_iface) |vi| allocator.destroy(vi);
        if (self.virtual_bridge_owner) |vo| {
            vo.deinit();
            allocator.destroy(vo);
        }
        self.cwd = &.{};
        self.model = null;
        self.resume_session_id = null;
        self.fallback_prompt_history = null;
        self.owned_mounts = &.{};
        self.mounts = &.{};
        self.virtual_bridge_iface = null;
        self.virtual_bridge_owner = null;
    }
};

pub const RollbackOptions = struct {
    use_pre_checkpoint: bool = false,
    lease_ttl_ms: u64 = DEFAULT_LEASE_TTL_MS,
    simulate_crash_after_space_index: ?usize = null,
};

pub const RollbackResult = struct {
    intent_id: u128,
    spaces_rolled_back: usize,
    completed: bool,
};

pub const SpawnSubordinateRequest = struct {
    title: []const u8,
    prompt: []const u8 = "",
    grants: []const model.SpaceBinding = &.{},
    create_virtual_spaces: []const []const u8 = &.{},
    budget: model.Budget = .{},
    depends_on: []const u128 = &.{},
    join_quorum: u16 = 0,
    placement: model.PlacementPolicy = .any,
    provider_id: ?iface.ProviderId = null,
    model: ?[]const u8 = null,
    project_forks_locally: bool = false,
    target_runner_id: ?u128 = null,
    target_runner_pubkey: ?[32]u8 = null,
    delegation_expires_ms: u64 = 0,
};

pub const SpawnSubordinateResult = struct {
    task_id: u128,
    child_thread_id: u128,
    status: model.TaskStatus,
    carved_budget: model.Budget,
    forked_space_ids: []u128 = &.{},
    delegation_bundle: ?crypto.DelegationBundle = null,
    sealed_delegation: ?[]u8 = null,

    pub fn deinit(self: *SpawnSubordinateResult, allocator: Allocator) void {
        if (self.forked_space_ids.len > 0) allocator.free(self.forked_space_ids);
        if (self.delegation_bundle) |*b| b.deinit(allocator);
        if (self.sealed_delegation) |s| allocator.free(s);
        self.forked_space_ids = &.{};
        self.delegation_bundle = null;
        self.sealed_delegation = null;
    }
};

pub const CancelTreeReport = struct {
    canceled_threads: usize = 0,
    canceled_tasks: usize = 0,
    canceled_leases: usize = 0,
};

pub const FireTriggerOutcome = enum(u8) {
    fired = 1,
    already_fired = 2,
    disabled = 3,
    not_found = 4,
};

pub const DueTrigger = struct {
    trigger_id: u128,
    event_token: []u8,
    prompt: []u8,

    pub fn deinit(self: *DueTrigger, allocator: Allocator) void {
        if (self.event_token.len > 0) allocator.free(self.event_token);
        if (self.prompt.len > 0) allocator.free(self.prompt);
        self.event_token = &.{};
        self.prompt = &.{};
    }
};

pub fn freeDueTriggers(allocator: Allocator, list: []DueTrigger) void {
    for (list) |*d| d.deinit(allocator);
    if (list.len > 0) allocator.free(list);
}

const CachedThread = struct {
    store: store_mod.ThreadStore,
    last_touch: u64,
};

const ActiveTurn = struct {
    turn_id: u128,
    user_msg_id: u128,
    lease: lease_mod.LeaseHandle,
    started_ms: u64,
};

pub const ThreadRuntime = struct {
    allocator: Allocator,
    io: Io,
    root_dir_path: []u8,
    root_dir: Io.Dir,
    spaces: *manager_mod.SpaceManager,
    projects: *project_mod.ProjectStore,
    catalog: *store_mod.CatalogStore,
    keyring: *keyring_mod.Keyring,
    leases: *lease_mod.LeaseManager,
    providers: ?*const ProviderRegistry,
    shared_blobs: ?*blobs_mod.SharedBlobPool,
    runner_id: u128,
    device_id: u128,
    max_open_threads: usize,
    touch_clock: u64 = 0,
    open_threads: std.AutoHashMapUnmanaged(u128, *CachedThread) = .empty,
    active_turns: std.AutoHashMapUnmanaged(u128, ActiveTurn) = .empty,
    acked_mailbox: std.AutoHashMapUnmanaged(u128, void) = .empty,
    last_mounts_digest: std.AutoHashMapUnmanaged(u128, [32]u8) = .empty,
    watched_space_digests: std.AutoHashMapUnmanaged(u128, [32]u8) = .empty,

    pub const open = init;

    pub fn init(allocator: Allocator, io: Io, opts: InitOptions) !ThreadRuntime {
        try Io.Dir.cwd().createDirPath(io, opts.root_dir);
        const root_dir = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true });
        errdefer root_dir.close(io);

        const root_copy = try allocator.dupe(u8, opts.root_dir);
        errdefer allocator.free(root_copy);

        return .{
            .allocator = allocator,
            .io = io,
            .root_dir_path = root_copy,
            .root_dir = root_dir,
            .spaces = opts.spaces,
            .projects = opts.projects,
            .catalog = opts.catalog,
            .keyring = opts.keyring,
            .leases = opts.leases,
            .providers = opts.providers,
            .shared_blobs = opts.shared_blobs,
            .runner_id = opts.runner_id,
            .device_id = opts.device_id,
            .max_open_threads = @max(@as(usize, 1), opts.max_open_threads),
        };
    }

    pub fn deinit(self: *ThreadRuntime) void {
        var ait = self.active_turns.valueIterator();
        while (ait.next()) |at| {
            self.leases.release(&at.lease) catch {};
        }
        self.active_turns.deinit(self.allocator);

        var oit = self.open_threads.valueIterator();
        while (oit.next()) |ct| {
            ct.*.store.deinit();
            self.allocator.destroy(ct.*);
        }
        self.open_threads.deinit(self.allocator);

        self.acked_mailbox.deinit(self.allocator);
        self.last_mounts_digest.deinit(self.allocator);
        self.watched_space_digests.deinit(self.allocator);

        self.root_dir.close(self.io);
        self.allocator.free(self.root_dir_path);
    }

    pub fn openThread(self: *ThreadRuntime, thread_id: u128) !*store_mod.ThreadStore {
        self.touch_clock +|= 1;
        if (self.open_threads.get(thread_id)) |ct| {
            ct.last_touch = self.touch_clock;
            return &ct.store;
        }

        self.maybeEvictLruThread();

        const ct = try self.allocator.create(CachedThread);
        errdefer self.allocator.destroy(ct);
        ct.* = .{
            .store = try store_mod.ThreadStore.open(
                self.allocator,
                self.io,
                self.root_dir,
                thread_id,
                self.shared_blobs,
            ),
            .last_touch = self.touch_clock,
        };
        errdefer ct.store.deinit();

        try self.open_threads.put(self.allocator, thread_id, ct);
        return &ct.store;
    }

    fn maybeEvictLruThread(self: *ThreadRuntime) void {
        if (self.open_threads.count() < self.max_open_threads) return;
        var victim_id: ?u128 = null;
        var victim_touch: u64 = std.math.maxInt(u64);
        var it = self.open_threads.iterator();
        while (it.next()) |kv| {
            const tid = kv.key_ptr.*;
            if (self.active_turns.contains(tid)) continue;
            if (kv.value_ptr.*.store.pendingRollback() != null) continue;
            if (kv.value_ptr.*.last_touch < victim_touch) {
                victim_touch = kv.value_ptr.*.last_touch;
                victim_id = tid;
            }
        }
        if (victim_id) |vid| {
            self.closeThread(vid);
        }
    }

    pub fn closeThread(self: *ThreadRuntime, thread_id: u128) void {
        if (self.open_threads.fetchRemove(thread_id)) |kv| {
            kv.value.store.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    pub fn getThreadMeta(self: *ThreadRuntime, allocator: Allocator, thread_id: u128) !?model.ThreadMeta {
        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return null;
        return try meta.clone(allocator);
    }

    pub fn listThreads(self: *const ThreadRuntime, allocator: Allocator, project_id: ?u128) ![]model.ThreadSummary {
        return try self.catalog.listThreads(allocator, project_id);
    }

    fn ensureTopicKey(self: *ThreadRuntime, kind: TopicKind, entity_id: u128) !void {
        const tid = topicId(kind, entity_id);
        if (self.keyring.getEntityKey(tid) == null) {
            try self.keyring.setEntityKey(tid, crypto.EntityKey.generate(self.io, 1));
        }
    }

    fn accessFromU8(raw: u8) model.SpaceAccess {
        return std.enums.fromInt(model.SpaceAccess, raw) orelse .shared_rw;
    }

    fn mountKindFromSpaceKind(kind: space_mod.SpaceKind) iface.MountKind {
        return switch (kind) {
            .virtual => .virtual,
            .dir => .dir,
            .git_worktree => .git_worktree,
        };
    }

    fn mountAccessFromSpaceAccess(access: model.SpaceAccess) iface.MountAccess {
        return switch (access) {
            .read_only => .read_only,
            .shared_rw => .shared_rw,
            .isolated_fork => .isolated_fork,
        };
    }

    fn captureCheckpointVector(
        self: *ThreadRuntime,
        bindings: []const model.SpaceBinding,
        writable_only: bool,
    ) !model.CheckpointVector {
        var vec = model.CheckpointVector{};
        errdefer vec.deinit(self.allocator);
        if (bindings.len == 0) return vec;

        for (bindings) |b| {
            if (writable_only and b.access == .read_only) continue;
            const sp = try self.spaces.activate(b.space_id);
            var vcs_kind: vcs.VcsKind = .none;
            var vcs_ref: ?[]u8 = null;
            errdefer if (vcs_ref) |r| self.allocator.free(r);
            var vcs_rev: ?[]u8 = null;
            errdefer if (vcs_rev) |v| self.allocator.free(v);

            if (try self.spaces.activateProjection(b.space_id)) |proj| {
                _ = try proj.ingestDirty();
                var head_info = proj.vcsHead(self.allocator) catch vcs.VcsHead{ .kind = .none };
                defer head_info.deinit(self.allocator);
                vcs_kind = head_info.kind;
                if (head_info.ref_name) |rn| vcs_ref = try self.allocator.dupe(u8, rn);
                if (head_info.rev) |rv| vcs_rev = try self.allocator.dupe(u8, rv);
            }

            var ver = try sp.headsClone(self.allocator);
            errdefer ver.deinit(self.allocator);

            var cp = model.SpaceCheckpoint{
                .space_id = b.space_id,
                .version = ver,
                .vcs_kind = vcs_kind,
                .vcs_ref = vcs_ref,
                .vcs_rev = vcs_rev,
            };
            defer cp.deinit(self.allocator);
            try vec.setSpace(self.allocator, cp);
        }

        return vec;
    }

    fn syncCatalogSummary(self: *ThreadRuntime, store: *const store_mod.ThreadStore) !void {
        const meta = store.meta orelse return;
        var active_tasks: u32 = 0;
        var tit = store.tasks.valueIterator();
        while (tit.next()) |t| {
            if (!t.status.isTerminal()) active_tasks += 1;
        }
        var unread_mb: u32 = 0;
        for (store.mailbox_order.items) |mid| {
            if (!self.acked_mailbox.contains(mid)) unread_mb += 1;
        }
        const summary = model.ThreadSummary{
            .thread_id = meta.thread_id,
            .project_id = meta.project_id,
            .parent_thread_id = meta.parent_thread_id,
            .root_thread_id = meta.root_thread_id,
            .title = meta.title,
            .provider = meta.default_provider,
            .model = meta.default_model,
            .status = meta.status,
            .message_count = store.total_message_count,
            .active_tasks = active_tasks,
            .unread_mailbox = unread_mb,
            .deleted = false,
            .updated_ms = @max(id.nowMs(self.io), meta.updated_ms),
            .actor = self.runner_id,
        };
        _ = try self.catalog.putThread(summary);
    }

    pub fn createThread(self: *ThreadRuntime, opts: CreateThreadOptions) !model.ThreadMeta {
        const now = id.nowMs(self.io);
        const thread_id = id.newUuidV7(self.io);
        const root_tid = opts.root_thread_id orelse thread_id;

        var resolved_bindings: []model.SpaceBinding = &.{};
        errdefer model.freeBindings(self.allocator, resolved_bindings);

        var eff_provider = opts.provider_id;
        var eff_model: ?[]u8 = if (opts.model) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (eff_model) |m| self.allocator.free(m);

        if (opts.bindings.len > 0) {
            resolved_bindings = try model.cloneBindings(self.allocator, opts.bindings);
        } else if (opts.project_id) |pid| {
            const proj = self.projects.get(pid) orelse return error.ProjectNotFound;
            if (proj.spaces.len > 0) {
                const arr = try self.allocator.alloc(model.SpaceBinding, proj.spaces.len);
                var built: usize = 0;
                errdefer {
                    for (arr[0..built]) |*b| b.deinit(self.allocator);
                    self.allocator.free(arr);
                }
                for (proj.spaces, 0..) |sr, i| {
                    arr[i] = .{
                        .space_id = sr.space_id,
                        .alias = try self.allocator.dupe(u8, sr.alias),
                        .access = accessFromU8(sr.default_access),
                        .mount_rel = null,
                    };
                    built += 1;
                }
                resolved_bindings = arr;
            }
            if (eff_model == null) {
                if (proj.default_model) |pm| {
                    eff_model = try self.allocator.dupe(u8, pm);
                }
            }
            if (opts.provider_id == .mock and proj.default_provider != 0) {
                if (std.enums.fromInt(iface.ProviderId, proj.default_provider)) |pp| {
                    eff_provider = pp;
                }
            }
        }

        var root_cp = if (resolved_bindings.len == 0)
            model.CheckpointVector{}
        else
            try self.captureCheckpointVector(resolved_bindings, false);
        errdefer root_cp.deinit(self.allocator);

        const title_copy: []u8 = if (opts.title.len > 0) try self.allocator.dupe(u8, opts.title) else &.{};
        errdefer if (title_copy.len > 0) self.allocator.free(title_copy);

        var meta = model.ThreadMeta{
            .thread_id = thread_id,
            .project_id = opts.project_id,
            .parent_thread_id = opts.parent_thread_id,
            .root_thread_id = root_tid,
            .task_id = opts.parent_task_id,
            .depth = opts.depth,
            .title = title_copy,
            .default_provider = eff_provider,
            .default_model = eff_model,
            .bindings = resolved_bindings,
            .budget = opts.budget,
            .root_checkpoint = root_cp,
            .status = .idle,
            .created_ms = now,
            .updated_ms = now,
        };
        errdefer meta.deinit(self.allocator);

        const store = try self.openThread(thread_id);
        var ev = try store.appendEvent(self.runner_id, .{ .thread_created = meta });
        ev.deinit(self.allocator);

        if (opts.system_prompt) |sp_text| {
            if (sp_text.len > 0) {
                const sys_msg = model.Message{
                    .msg_id = id.newUuidV7(self.io),
                    .thread_id = thread_id,
                    .parent_id = null,
                    .role = .system,
                    .content = @constCast(sp_text),
                    .provider = eff_provider,
                    .model = eff_model,
                    .runner_id = self.runner_id,
                    .fencing_epoch = 0,
                    .status = .completed,
                    .created_ms = now,
                    .updated_ms = now,
                };
                var sev = try store.appendEvent(self.runner_id, .{ .message_appended = sys_msg });
                sev.deinit(self.allocator);
            }
        }

        try self.ensureTopicKey(.thread, thread_id);
        try self.ensureTopicKey(.mailbox, thread_id);
        for (meta.bindings) |b| {
            try self.ensureTopicKey(.space, b.space_id);
        }

        try self.syncCatalogSummary(store);
        return meta;
    }

    pub fn bindSpace(self: *ThreadRuntime, thread_id: u128, binding: model.SpaceBinding) !void {
        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return error.ThreadNotFound;

        var list: std.ArrayList(model.SpaceBinding) = .empty;
        defer {
            for (list.items) |*b| b.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        var replaced = false;
        for (meta.bindings) |*b| {
            if (b.space_id == binding.space_id) {
                try list.append(self.allocator, try binding.clone(self.allocator));
                replaced = true;
            } else {
                try list.append(self.allocator, try b.clone(self.allocator));
            }
        }
        if (!replaced) {
            try list.append(self.allocator, try binding.clone(self.allocator));
        }

        const now = id.nowMs(self.io);
        var ev = try store.appendEvent(self.runner_id, .{ .bindings_updated = .{
            .bindings = list.items,
            .updated_ms = @max(now, meta.updated_ms + 1),
        } });
        ev.deinit(self.allocator);

        try self.ensureTopicKey(.space, binding.space_id);
        try self.syncCatalogSummary(store);
    }

    pub fn unbindSpace(self: *ThreadRuntime, thread_id: u128, space_id: u128) !bool {
        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return error.ThreadNotFound;

        var list: std.ArrayList(model.SpaceBinding) = .empty;
        defer {
            for (list.items) |*b| b.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        var removed = false;
        for (meta.bindings) |*b| {
            if (b.space_id == space_id) {
                removed = true;
                continue;
            }
            try list.append(self.allocator, try b.clone(self.allocator));
        }
        if (!removed) return false;

        const now = id.nowMs(self.io);
        var ev = try store.appendEvent(self.runner_id, .{ .bindings_updated = .{
            .bindings = list.items,
            .updated_ms = @max(now, meta.updated_ms + 1),
        } });
        ev.deinit(self.allocator);

        try self.syncCatalogSummary(store);
        return true;
    }

    fn currentChainTipId(self: *ThreadRuntime, store: *store_mod.ThreadStore) !?u128 {
        const chain = try store.activeChain(self.allocator);
        defer store_mod.ThreadStore.freeMessages(self.allocator, chain);
        if (chain.len == 0) return null;
        return chain[chain.len - 1].msg_id;
    }

    pub fn beginTurn(
        self: *ThreadRuntime,
        thread_id: u128,
        user_prompt: []const u8,
        opts: BeginTurnOptions,
    ) !BeginTurnResult {
        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return error.ThreadNotFound;

        const thread_topic = topicId(.thread, thread_id);
        const expected_epoch: u64 = if (store.last_lease) |ll| ll.fencing_epoch else 0;
        var lease = try self.leases.acquire(thread_topic, expected_epoch, opts.lease_ttl_ms);
        errdefer self.leases.release(&lease) catch {};

        var lease_ev = try store.appendEvent(self.runner_id, .{ .lease_observed = .{
            .holder_runner_id = lease.runner_id,
            .fencing_epoch = lease.fencing_epoch,
            .expires_ms = lease.expires_ms,
        } });
        lease_ev.deinit(self.allocator);

        var pre_cp = if (meta.bindings.len == 0)
            model.CheckpointVector{}
        else
            try self.captureCheckpointVector(meta.bindings, false);
        errdefer pre_cp.deinit(self.allocator);

        const parent_id: ?u128 = if (opts.parent_msg_id != null)
            opts.parent_msg_id
        else
            try self.currentChainTipId(store);

        const provider = opts.provider orelse meta.default_provider;
        const eff_model = opts.model orelse meta.default_model;
        const now = id.nowMs(self.io);

        const user_msg_id = id.newUuidV7(self.io);
        const turn_id = id.newUuidV7(self.io);

        const user_msg = model.Message{
            .msg_id = user_msg_id,
            .thread_id = thread_id,
            .parent_id = parent_id,
            .role = .user,
            .content = @constCast(user_prompt),
            .provider = provider,
            .model = if (eff_model) |m| @constCast(m) else null,
            .runner_id = self.runner_id,
            .fencing_epoch = lease.fencing_epoch,
            .pre_checkpoint = pre_cp,
            .post_checkpoint = pre_cp,
            .status = .completed,
            .created_ms = now,
            .updated_ms = now,
        };
        var uev = try store.appendEvent(self.runner_id, .{ .message_appended = user_msg });
        uev.deinit(self.allocator);

        const siblings = store.getChildren(parent_id);
        if (siblings.len > 1) {
            var bev = try store.appendEvent(self.runner_id, .{ .branch_choice_set = .{
                .parent_id = parent_id,
                .selected_child_id = user_msg_id,
                .lamport = store.lamport + 1,
                .actor = self.runner_id,
            } });
            bev.deinit(self.allocator);
        }

        const asst_msg = model.Message{
            .msg_id = turn_id,
            .thread_id = thread_id,
            .parent_id = user_msg_id,
            .role = .assistant,
            .content = &.{},
            .provider = provider,
            .model = if (eff_model) |m| @constCast(m) else null,
            .runner_id = self.runner_id,
            .fencing_epoch = lease.fencing_epoch,
            .pre_checkpoint = pre_cp,
            .post_checkpoint = .{},
            .status = .running,
            .created_ms = now,
            .updated_ms = now,
        };
        var aev = try store.appendEvent(self.runner_id, .{ .message_appended = asst_msg });
        aev.deinit(self.allocator);

        var tev = try store.appendEvent(self.runner_id, .{ .thread_updated = .{
            .status = .running,
            .updated_ms = now,
        } });
        tev.deinit(self.allocator);

        if (self.active_turns.getPtr(thread_id)) |prev| {
            self.leases.release(&prev.lease) catch {};
        }
        try self.active_turns.put(self.allocator, thread_id, .{
            .turn_id = turn_id,
            .user_msg_id = user_msg_id,
            .lease = lease,
            .started_ms = now,
        });

        try self.syncCatalogSummary(store);

        return .{
            .turn_id = turn_id,
            .user_msg_id = user_msg_id,
            .fencing_epoch = lease.fencing_epoch,
            .pre_checkpoint = pre_cp,
        };
    }

    pub fn computeMountsDigest(mounts: []const iface.MountSpec) [32]u8 {
        var h = std.crypto.hash.Blake3.init(.{});
        h.update("0ndb-mounts-v1:");
        var u64_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &u64_buf, mounts.len, .little);
        h.update(&u64_buf);

        const max_n = @min(mounts.len, model.MAX_BINDINGS);
        var order: [model.MAX_BINDINGS]usize = undefined;
        for (0..max_n) |i| order[i] = i;
        var i: usize = 1;
        while (i < max_n) : (i += 1) {
            const key = order[i];
            var j = i;
            while (j > 0 and mounts[order[j - 1]].space_id > mounts[key].space_id) : (j -= 1) {
                order[j] = order[j - 1];
            }
            order[j] = key;
        }

        for (order[0..max_n]) |idx| {
            const m = mounts[idx];
            var sid_buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &sid_buf, m.space_id, .little);
            h.update(&sid_buf);
            std.mem.writeInt(u64, &u64_buf, m.alias.len, .little);
            h.update(&u64_buf);
            h.update(m.alias);
            h.update(&[_]u8{ @backingInt(m.kind), @backingInt(m.access) });
            if (m.local_path) |lp| {
                h.update(&[_]u8{1});
                std.mem.writeInt(u64, &u64_buf, lp.len, .little);
                h.update(&u64_buf);
                h.update(lp);
            } else {
                h.update(&[_]u8{0});
            }
        }

        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    pub fn resolveProviderStart(
        self: *ThreadRuntime,
        allocator: Allocator,
        thread_id: u128,
        turn_id: u128,
        prompt: []const u8,
        local_mounts: []const iface.MountSpec,
    ) !ProviderStartPlan {
        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return error.ThreadNotFound;

        const target_provider: iface.ProviderId = blk: {
            if (store.messages.getPtr(turn_id)) |tm| break :blk tm.provider;
            break :blk meta.default_provider;
        };
        const target_model: ?[]const u8 = blk: {
            if (store.messages.getPtr(turn_id)) |tm| {
                if (tm.model) |m| break :blk m;
            }
            break :blk meta.default_model;
        };

        var owned_mounts_list: std.ArrayList(OwnedMountSpec) = .empty;
        errdefer {
            for (owned_mounts_list.items) |*m| m.deinit(allocator);
            owned_mounts_list.deinit(allocator);
        }

        var has_headless_or_virtual = false;
        if (local_mounts.len > 0) {
            for (local_mounts) |lm| {
                if (lm.kind == .virtual or lm.local_path == null) {
                    has_headless_or_virtual = true;
                }
                const alias_c: []u8 = if (lm.alias.len > 0) try allocator.dupe(u8, lm.alias) else &.{};
                errdefer if (alias_c.len > 0) allocator.free(alias_c);
                const lp_c = if (lm.local_path) |p| try allocator.dupe(u8, p) else null;
                try owned_mounts_list.append(allocator, .{
                    .alias = alias_c,
                    .space_id = lm.space_id,
                    .kind = lm.kind,
                    .access = lm.access,
                    .local_path = lp_c,
                });
            }
        } else {
            for (meta.bindings) |b| {
                const rec = self.spaces.get(b.space_id);
                const sp_kind: space_mod.SpaceKind = if (rec) |r| r.kind else .virtual;
                const proj_rec = self.spaces.getProjectionRecord(b.space_id);
                const lp_opt: ?[]const u8 = if (sp_kind != .virtual)
                    (if (proj_rec) |pr| pr.local_path else null)
                else
                    null;

                if (sp_kind == .virtual or lp_opt == null) {
                    has_headless_or_virtual = true;
                }
                const alias_c: []u8 = if (b.alias.len > 0) try allocator.dupe(u8, b.alias) else &.{};
                errdefer if (alias_c.len > 0) allocator.free(alias_c);
                const lp_c = if (lp_opt) |p| try allocator.dupe(u8, p) else null;
                try owned_mounts_list.append(allocator, .{
                    .alias = alias_c,
                    .space_id = b.space_id,
                    .kind = mountKindFromSpaceKind(sp_kind),
                    .access = mountAccessFromSpaceAccess(b.access),
                    .local_path = lp_c,
                });
            }
        }

        const owned_mounts = try owned_mounts_list.toOwnedSlice(allocator);
        errdefer {
            for (owned_mounts) |*m| m.deinit(allocator);
            if (owned_mounts.len > 0) allocator.free(owned_mounts);
        }

        const mounts = try allocator.alloc(iface.MountSpec, owned_mounts.len);
        errdefer if (mounts.len > 0) allocator.free(mounts);
        for (owned_mounts, 0..) |*om, i| {
            mounts[i] = om.toSpec();
        }

        var cwd_slice: []u8 = &.{};
        errdefer if (cwd_slice.len > 0) allocator.free(cwd_slice);
        if (meta.bindings.len > 0) {
            for (mounts) |m| {
                if (m.local_path) |lp| {
                    if (lp.len > 0) {
                        cwd_slice = try allocator.dupe(u8, lp);
                        break;
                    }
                }
            }
        }

        var bridge_owner: ?*SpaceVirtualBridge = null;
        var bridge_iface: ?*iface.VirtualSpaceBridge = null;
        errdefer {
            if (bridge_iface) |vi| allocator.destroy(vi);
            if (bridge_owner) |vo| {
                vo.deinit();
                allocator.destroy(vo);
            }
        }
        if (has_headless_or_virtual and meta.bindings.len > 0) {
            bridge_owner = try allocator.create(SpaceVirtualBridge);
            bridge_owner.?.* = try SpaceVirtualBridge.init(allocator, self.spaces, meta.bindings, thread_id);
            bridge_iface = try allocator.create(iface.VirtualSpaceBridge);
            bridge_iface.?.* = bridge_owner.?.asInterface();
        }

        const current_bindings_digest = meta.bindingsDigest();
        const current_mounts_digest = computeMountsDigest(mounts);

        const chain = try store.activeChain(allocator);
        defer store_mod.ThreadStore.freeMessages(allocator, chain);

        var latest_cursor: ?*const model.ProviderCursor = null;
        var idx: usize = chain.len;
        while (idx > 0) {
            idx -= 1;
            const msg = &chain[idx];
            if (msg.msg_id == turn_id) continue;
            if (msg.cursor) |*c| {
                latest_cursor = c;
                break;
            }
        }

        const mounts_match = blk: {
            if (self.last_mounts_digest.get(thread_id)) |prev_md| {
                break :blk std.mem.eql(u8, &prev_md, &current_mounts_digest);
            }
            break :blk true;
        };

        const can_resume = if (latest_cursor) |cur|
            cur.canResumeNatively(target_provider, self.runner_id, current_bindings_digest) and mounts_match
        else
            false;

        var resume_sid: ?[]u8 = null;
        errdefer if (resume_sid) |r| allocator.free(r);
        var fallback_history: ?[]u8 = null;
        errdefer if (fallback_history) |h| allocator.free(h);

        if (can_resume) {
            resume_sid = try allocator.dupe(u8, latest_cursor.?.native_session);
        } else {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (chain) |*m| {
                if (m.msg_id == turn_id) continue;
                if (m.content.len == 0) continue;
                const role_tag = switch (m.role) {
                    .system => "system",
                    .user => "user",
                    .assistant => "assistant",
                    .steer => "steer",
                };
                try buf.print(allocator, "[{s}] {s}\n", .{ role_tag, m.content });
            }
            if (prompt.len > 0) {
                try buf.print(allocator, "[user] {s}\n", .{prompt});
            }
            fallback_history = try buf.toOwnedSlice(allocator);
        }

        const model_copy = if (target_model) |m| try allocator.dupe(u8, m) else null;
        errdefer if (model_copy) |m| allocator.free(m);

        try self.last_mounts_digest.put(self.allocator, thread_id, current_mounts_digest);

        const req = iface.StartRequest{
            .cwd = cwd_slice,
            .model = model_copy,
            .resume_id = resume_sid,
            .fork_at = null,
            .access = .full,
            .mounts = mounts,
            .virtual_bridge = if (bridge_iface) |bi| bi else null,
            .runner_id = self.runner_id,
        };

        return .{
            .provider = target_provider,
            .resumed_natively = can_resume,
            .cwd = cwd_slice,
            .model = model_copy,
            .resume_session_id = resume_sid,
            .fallback_prompt_history = fallback_history,
            .owned_mounts = owned_mounts,
            .mounts = mounts,
            .virtual_bridge_owner = bridge_owner,
            .virtual_bridge_iface = bridge_iface,
            .start_request = req,
            .bindings_digest = current_bindings_digest,
            .mounts_digest = current_mounts_digest,
        };
    }

    pub fn openProviderHandle(
        self: *ThreadRuntime,
        allocator: Allocator,
        plan: *const ProviderStartPlan,
    ) !iface.RunHandle {
        if (self.providers) |reg| {
            return reg.start(allocator, self.io, plan.provider, plan.start_request);
        }
        return providers_registry.start(allocator, self.io, plan.provider, plan.start_request);
    }

    pub fn completeTurn(
        self: *ThreadRuntime,
        thread_id: u128,
        turn_id: u128,
        assistant_text: []const u8,
        tool_calls: []const model.ToolCallRecord,
        usage: TurnUsage,
        new_cursor: ?model.ProviderCursor,
    ) !model.CheckpointVector {
        const active = self.active_turns.getPtr(thread_id) orelse return error.LeaseNotActive;
        if (active.turn_id != turn_id) return error.LeaseEpochMismatch;
        if (!self.leases.isStillValid(&active.lease)) return error.LeaseNotActive;

        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return error.ThreadNotFound;
        const msg_cur = store.messages.getPtr(turn_id) orelse return error.MessageNotFound;

        var updated_budget = meta.budget;
        try updated_budget.recordUsage(usage.tokens, usage.cost_microusd, usage.wall_ms);

        var post_cp = if (meta.bindings.len == 0)
            model.CheckpointVector{}
        else
            try self.captureCheckpointVector(meta.bindings, true);
        errdefer post_cp.deinit(self.allocator);

        for (tool_calls) |tc| {
            var rec = tc;
            rec.msg_id = turn_id;
            var tcev = try store.appendEvent(self.runner_id, .{ .tool_call_put = rec });
            tcev.deinit(self.allocator);
        }

        const now = id.nowMs(self.io);
        var updated_msg = try msg_cur.clone(self.allocator);
        defer updated_msg.deinit(self.allocator);

        if (updated_msg.content.len > 0) self.allocator.free(updated_msg.content);
        updated_msg.content = if (assistant_text.len > 0) try self.allocator.dupe(u8, assistant_text) else &.{};
        updated_msg.post_checkpoint.deinit(self.allocator);
        updated_msg.post_checkpoint = try post_cp.clone(self.allocator);
        if (new_cursor) |*nc| {
            if (updated_msg.cursor) |*old_c| old_c.deinit(self.allocator);
            updated_msg.cursor = try nc.clone(self.allocator);
        }
        updated_msg.status = .completed;
        updated_msg.updated_ms = @max(now, updated_msg.updated_ms + 1);

        var mev = try store.appendEvent(self.runner_id, .{ .message_updated = updated_msg });
        mev.deinit(self.allocator);

        var tev = try store.appendEvent(self.runner_id, .{ .thread_updated = .{
            .status = .idle,
            .budget = updated_budget,
            .updated_ms = @max(now, meta.updated_ms + 1),
        } });
        tev.deinit(self.allocator);

        if (self.active_turns.fetchRemove(thread_id)) |kv| {
            var lease_copy = kv.value.lease;
            self.leases.release(&lease_copy) catch {};
        }

        try self.syncCatalogSummary(store);
        return post_cp;
    }

    pub fn cancelTurn(self: *ThreadRuntime, thread_id: u128, turn_id: u128) !void {
        const store = try self.openThread(thread_id);
        const now = id.nowMs(self.io);

        if (store.messages.getPtr(turn_id)) |msg_cur| {
            var updated = try msg_cur.clone(self.allocator);
            defer updated.deinit(self.allocator);
            updated.status = .interrupted;
            updated.updated_ms = @max(now, updated.updated_ms + 1);
            var mev = try store.appendEvent(self.runner_id, .{ .message_updated = updated });
            mev.deinit(self.allocator);
        }

        if (store.meta) |meta| {
            var tev = try store.appendEvent(self.runner_id, .{ .thread_updated = .{
                .status = .interrupted,
                .updated_ms = @max(now, meta.updated_ms + 1),
            } });
            tev.deinit(self.allocator);
        }

        if (self.active_turns.fetchRemove(thread_id)) |kv| {
            var lease_copy = kv.value.lease;
            self.leases.release(&lease_copy) catch {};
        }

        try self.syncCatalogSummary(store);
    }

    pub fn reconcileInterrupted(self: *ThreadRuntime, thread_id: u128) !usize {
        const store = try self.openThread(thread_id);
        const st = self.leases.status(topicId(.thread, thread_id)) catch null;
        const epoch_opt: ?u64 = if (st) |lr| (if (lr.fencing_epoch > 0) lr.fencing_epoch else null) else null;
        const n = try store.reconcileInterrupted(self.runner_id, epoch_opt);
        if (n > 0) {
            try self.syncCatalogSummary(store);
        }
        return n;
    }

    pub fn enqueueMessage(
        self: *ThreadRuntime,
        thread_id: u128,
        kind: model.QueueKind,
        prompt: []const u8,
        provider: ?iface.ProviderId,
        model_name: ?[]const u8,
    ) !u128 {
        const store = try self.openThread(thread_id);
        const meta = store.meta orelse return error.ThreadNotFound;
        const now = id.nowMs(self.io);
        const item_id = id.newUuidV7(self.io);

        const qi = model.QueueItem{
            .item_id = item_id,
            .thread_id = thread_id,
            .kind = kind,
            .status = .pending,
            .prompt = @constCast(prompt),
            .provider = provider orelse meta.default_provider,
            .model = if (model_name) |m| @constCast(m) else meta.default_model,
            .created_ms = now,
            .updated_ms = now,
        };
        var ev = try store.appendEvent(self.runner_id, .{ .queue_enqueued = qi });
        ev.deinit(self.allocator);
        return item_id;
    }

    pub fn dequeueNext(self: *ThreadRuntime, allocator: Allocator, thread_id: u128) !?model.QueueItem {
        const store = try self.openThread(thread_id);

        var best: ?*const model.QueueItem = null;
        var it = store.queue_items.valueIterator();
        while (it.next()) |qi| {
            if (qi.status != .pending) continue;
            if (best == null) {
                best = qi;
                continue;
            }
            const b = best.?;
            const qi_prio: u8 = if (qi.kind == .steer) 0 else 1;
            const b_prio: u8 = if (b.kind == .steer) 0 else 1;
            if (qi_prio < b_prio or (qi_prio == b_prio and (qi.created_ms < b.created_ms or (qi.created_ms == b.created_ms and qi.item_id < b.item_id)))) {
                best = qi;
            }
        }

        const chosen = best orelse return null;
        var updated = try chosen.clone(allocator);
        errdefer updated.deinit(allocator);
        updated.status = .dispatching;
        updated.updated_ms = @max(id.nowMs(self.io), updated.updated_ms + 1);

        var ev = try store.appendEvent(self.runner_id, .{ .queue_updated = updated });
        ev.deinit(self.allocator);
        return updated;
    }

    pub fn switchBranch(
        self: *ThreadRuntime,
        thread_id: u128,
        parent_id: ?u128,
        selected_child_id: u128,
    ) !void {
        const store = try self.openThread(thread_id);
        var ev = try store.appendEvent(self.runner_id, .{ .branch_choice_set = .{
            .parent_id = parent_id,
            .selected_child_id = selected_child_id,
            .lamport = store.lamport + 1,
            .actor = self.runner_id,
        } });
        ev.deinit(self.allocator);
    }

    fn orderSpaceIdBytes(a: u128, b: u128) std.math.Order {
        var ab: [16]u8 = undefined;
        var bb: [16]u8 = undefined;
        std.mem.writeInt(u128, &ab, a, .big);
        std.mem.writeInt(u128, &bb, b, .big);
        return std.mem.order(u8, &ab, &bb);
    }

    fn prevalidateRollback(
        self: *ThreadRuntime,
        meta: *const model.ThreadMeta,
        target_vec: *const model.CheckpointVector,
    ) !void {
        for (target_vec.entries) |*cp| {
            var binding_found: ?*const model.SpaceBinding = null;
            for (meta.bindings) |*b| {
                if (b.space_id == cp.space_id) {
                    binding_found = b;
                    break;
                }
            }
            const b = binding_found orelse return error.RollbackSpaceReadOnly;
            if (b.access == .read_only) return error.RollbackSpaceReadOnly;

            if (self.spaces.get(cp.space_id) == null) return error.RollbackTargetInvalid;
            const sp = self.spaces.activate(cp.space_id) catch return error.RollbackTargetInvalid;

            for (cp.version.slice()) |bid| {
                if (!sp.history.dag.containsBatch(bid)) {
                    return error.RollbackTargetInvalid;
                }
            }

            if (try self.spaces.activateProjection(cp.space_id)) |proj| {
                if (proj.operationInProgress(self.allocator) != null) {
                    return error.RollbackTargetInvalid;
                }
            }
        }
    }

    fn executeRollbackPhase2(
        self: *ThreadRuntime,
        store: *store_mod.ThreadStore,
        intent: *model.RollbackIntent,
        simulate_crash_after_space_index: ?usize,
    ) !RollbackResult {
        const count = intent.target_vector.entries.len;
        const order_idx = try self.allocator.alloc(usize, count);
        defer self.allocator.free(order_idx);
        for (0..count) |i| order_idx[i] = i;

        std.mem.sort(usize, order_idx, intent.target_vector.entries, struct {
            fn lt(entries: []const model.SpaceCheckpoint, a: usize, b: usize) bool {
                return orderSpaceIdBytes(entries[a].space_id, entries[b].space_id) == .lt;
            }
        }.lt);

        var rolled: usize = 0;
        for (order_idx, 0..) |entry_i, step_idx| {
            const cp = &intent.target_vector.entries[entry_i];
            if (!intent.isSpaceCompleted(cp.space_id)) {
                try self.spaces.pin(cp.space_id);
                defer self.spaces.unpin(cp.space_id);

                const sp = try self.spaces.activate(cp.space_id);
                _ = try sp.rollbackToVersion(self.runner_id, &cp.version);

                if (try self.spaces.activateProjection(cp.space_id)) |proj| {
                    try proj.materializeChanged();
                }

                var dev = try store.appendEvent(self.runner_id, .{ .rollback_space_done = .{
                    .intent_id = intent.intent_id,
                    .space_id = cp.space_id,
                    .done_ms = id.nowMs(self.io),
                } });
                dev.deinit(self.allocator);
                try intent.markSpaceCompleted(self.allocator, cp.space_id);
                rolled += 1;
            }

            if (simulate_crash_after_space_index) |crash_at| {
                if (step_idx == crash_at) {
                    return .{
                        .intent_id = intent.intent_id,
                        .spaces_rolled_back = rolled,
                        .completed = false,
                    };
                }
            }
        }

        if (intent.target_msg_id) |tmid| {
            if (store.messages.getPtr(tmid)) |tmsg| {
                var bev = try store.appendEvent(self.runner_id, .{ .branch_choice_set = .{
                    .parent_id = tmsg.parent_id,
                    .selected_child_id = tmid,
                    .lamport = store.lamport + 1,
                    .actor = self.runner_id,
                } });
                bev.deinit(self.allocator);
            }
        }

        var cev = try store.appendEvent(self.runner_id, .{ .rollback_commit = .{
            .intent_id = intent.intent_id,
            .committed_ms = id.nowMs(self.io),
        } });
        cev.deinit(self.allocator);

        try self.syncCatalogSummary(store);

        return .{
            .intent_id = intent.intent_id,
            .spaces_rolled_back = rolled,
            .completed = true,
        };
    }

    pub fn rollbackThreadToMessage(
        self: *ThreadRuntime,
        thread_id: u128,
        target_msg_id: u128,
        opts: RollbackOptions,
    ) !RollbackResult {
        const store = try self.openThread(thread_id);
        if (store.pendingRollback() != null) return error.RollbackAlreadyPending;
        const meta = store.meta orelse return error.ThreadNotFound;
        const target_msg = store.messages.getPtr(target_msg_id) orelse return error.MessageNotFound;

        var target_vec = if (opts.use_pre_checkpoint)
            try target_msg.pre_checkpoint.clone(self.allocator)
        else if (!target_msg.post_checkpoint.isEmpty())
            try target_msg.post_checkpoint.clone(self.allocator)
        else
            try target_msg.pre_checkpoint.clone(self.allocator);
        defer target_vec.deinit(self.allocator);

        const thread_topic = topicId(.thread, thread_id);
        const expected_epoch: u64 = if (store.last_lease) |ll| ll.fencing_epoch else 0;
        var lease = try self.leases.acquire(thread_topic, expected_epoch, opts.lease_ttl_ms);
        defer self.leases.release(&lease) catch {};

        const intent_id = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);

        self.prevalidateRollback(&meta, &target_vec) catch |err| {
            var abort_begin = try store.appendEvent(self.runner_id, .{ .rollback_begin = .{
                .intent_id = intent_id,
                .target_msg_id = target_msg_id,
                .target_vector = target_vec,
                .completed_spaces = &.{},
                .created_ms = now,
            } });
            abort_begin.deinit(self.allocator);

            var abort_commit = try store.appendEvent(self.runner_id, .{ .rollback_commit = .{
                .intent_id = intent_id,
                .committed_ms = now,
            } });
            abort_commit.deinit(self.allocator);
            return err;
        };

        var intent = model.RollbackIntent{
            .intent_id = intent_id,
            .target_msg_id = target_msg_id,
            .target_vector = try target_vec.clone(self.allocator),
            .completed_spaces = &.{},
            .created_ms = now,
        };
        defer intent.deinit(self.allocator);

        var bev = try store.appendEvent(self.runner_id, .{ .rollback_begin = intent });
        bev.deinit(self.allocator);

        return try self.executeRollbackPhase2(store, &intent, opts.simulate_crash_after_space_index);
    }

    pub fn recoverPendingRollbacks(self: *ThreadRuntime, thread_id: u128) !?RollbackResult {
        const store = try self.openThread(thread_id);
        const pending = store.pendingRollback() orelse return null;

        var intent = try pending.clone(self.allocator);
        defer intent.deinit(self.allocator);

        const thread_topic = topicId(.thread, thread_id);
        const expected_epoch: u64 = if (store.last_lease) |ll| ll.fencing_epoch else 0;
        var lease = try self.leases.acquire(thread_topic, expected_epoch, DEFAULT_LEASE_TTL_MS);
        defer self.leases.release(&lease) catch {};

        return try self.executeRollbackPhase2(store, &intent, null);
    }

    pub fn spawnSubordinate(
        self: *ThreadRuntime,
        allocator: Allocator,
        parent_thread_id: u128,
        req: SpawnSubordinateRequest,
    ) !SpawnSubordinateResult {
        const parent_store = try self.openThread(parent_thread_id);
        const parent_meta = parent_store.meta orelse return error.ThreadNotFound;

        try model.ThreadMeta.validateGrantAttenuation(parent_meta.bindings, req.grants);

        var parent_budget = parent_meta.budget;
        const carved_budget = try parent_budget.carveChild(req.budget, parent_meta.depth);

        var child_bindings: std.ArrayList(model.SpaceBinding) = .empty;
        defer {
            for (child_bindings.items) |*b| b.deinit(self.allocator);
            child_bindings.deinit(self.allocator);
        }

        var forked_ids: std.ArrayList(u128) = .empty;
        errdefer {
            for (forked_ids.items) |fid| {
                self.spaces.removeSpace(fid, true) catch {};
            }
            forked_ids.deinit(allocator);
        }

        for (req.grants, 0..) |g, idx| {
            if (g.access == .isolated_fork) {
                const ftitle = try std.fmt.allocPrint(self.allocator, "{s}-fork-{d}", .{ req.title, idx });
                defer self.allocator.free(ftitle);
                var rec = try self.spaces.forkSpace(g.space_id, ftitle, req.project_forks_locally);
                const new_sid = rec.space_id;
                rec.deinit(self.allocator);

                try forked_ids.append(allocator, new_sid);
                try child_bindings.append(self.allocator, .{
                    .space_id = new_sid,
                    .alias = if (g.alias.len > 0) try self.allocator.dupe(u8, g.alias) else &.{},
                    .access = .shared_rw,
                    .mount_rel = if (g.mount_rel) |mr| try self.allocator.dupe(u8, mr) else null,
                });
            } else {
                try child_bindings.append(self.allocator, try g.clone(self.allocator));
            }
        }

        for (req.create_virtual_spaces) |vtitle| {
            var vrec = try self.spaces.createVirtual(vtitle);
            const vsid = vrec.space_id;
            vrec.deinit(self.allocator);
            try child_bindings.append(self.allocator, .{
                .space_id = vsid,
                .alias = if (vtitle.len > 0) try self.allocator.dupe(u8, vtitle) else &.{},
                .access = .shared_rw,
                .mount_rel = null,
            });
        }

        const task_id = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);

        var child_meta = try self.createThread(.{
            .title = req.title,
            .project_id = parent_meta.project_id,
            .bindings = child_bindings.items,
            .parent_thread_id = parent_thread_id,
            .root_thread_id = parent_meta.root_thread_id,
            .parent_task_id = task_id,
            .depth = parent_meta.depth + 1,
            .budget = carved_budget,
            .placement = req.placement,
            .provider_id = req.provider_id orelse parent_meta.default_provider,
            .model = req.model orelse parent_meta.default_model,
        });
        const child_tid = child_meta.thread_id;
        defer child_meta.deinit(self.allocator);

        var initial_status: model.TaskStatus = .ready;
        if (req.depends_on.len > 0) {
            var done_deps: usize = 0;
            for (req.depends_on) |dep_id| {
                if (parent_store.tasks.getPtr(dep_id)) |dep| {
                    if (dep.status == .completed) done_deps += 1;
                }
            }
            const needed: usize = if (req.join_quorum == 0)
                req.depends_on.len
            else
                @min(@as(usize, req.join_quorum), req.depends_on.len);
            if (done_deps < needed) {
                initial_status = .pending;
            }
        }

        const task = model.Task{
            .task_id = task_id,
            .parent_thread_id = parent_thread_id,
            .child_thread_id = child_tid,
            .title = @constCast(req.title),
            .status = initial_status,
            .attempt = 1,
            .depends_on = @constCast(req.depends_on),
            .join_quorum = req.join_quorum,
            .placement = req.placement,
            .grants = child_bindings.items,
            .budget = carved_budget,
            .start_checkpoint = child_meta.root_checkpoint,
            .end_checkpoint = .{},
            .err_msg = null,
            .created_ms = now,
            .updated_ms = now,
        };

        const pstore_ref = try self.openThread(parent_thread_id);
        var buev = try pstore_ref.appendEvent(self.runner_id, .{ .thread_updated = .{
            .budget = parent_budget,
            .updated_ms = @max(now, parent_meta.updated_ms + 1),
        } });
        buev.deinit(self.allocator);

        var tkev = try pstore_ref.appendEvent(self.runner_id, .{ .task_created = task });
        tkev.deinit(self.allocator);

        if (req.prompt.len > 0) {
            _ = try self.postMailbox(child_tid, .{
                .item_id = id.newUuidV7(self.io),
                .from_thread_id = parent_thread_id,
                .to_thread_id = child_tid,
                .task_id = task_id,
                .kind = .assign,
                .payload = @constCast(req.prompt),
                .created_ms = now,
            });
        }

        try self.ensureTopicKey(.mailbox, parent_thread_id);
        try self.ensureTopicKey(.thread, child_tid);
        try self.ensureTopicKey(.mailbox, child_tid);
        for (child_bindings.items) |b| {
            try self.ensureTopicKey(.space, b.space_id);
        }

        var del_reqs: std.ArrayList(keyring_mod.DelegationRequest) = .empty;
        defer del_reqs.deinit(self.allocator);

        try del_reqs.append(self.allocator, .{
            .topic_id = topicId(.mailbox, parent_thread_id),
            .perms = wire.PERM_INBOX_APPEND,
            .expires_ms = req.delegation_expires_ms,
        });
        try del_reqs.append(self.allocator, .{
            .topic_id = topicId(.thread, child_tid),
            .perms = @as(u32, wire.PERM_ALL) | wire.PERM_LEASE,
            .expires_ms = req.delegation_expires_ms,
        });
        try del_reqs.append(self.allocator, .{
            .topic_id = topicId(.mailbox, child_tid),
            .perms = @as(u32, wire.PERM_READ | wire.PERM_SUB) | wire.PERM_INBOX_APPEND,
            .expires_ms = req.delegation_expires_ms,
        });
        for (child_bindings.items) |b| {
            const perms: u32 = if (b.access == .read_only)
                @as(u32, wire.PERM_READ | wire.PERM_SUB)
            else
                @as(u32, wire.PERM_ALL);
            try del_reqs.append(self.allocator, .{
                .topic_id = topicId(.space, b.space_id),
                .perms = perms,
                .expires_ms = req.delegation_expires_ms,
            });
        }

        const target_runner = req.target_runner_id orelse child_tid;
        var bundle = try self.keyring.buildDelegationBundle(
            allocator,
            target_runner,
            req.delegation_expires_ms,
            del_reqs.items,
        );
        errdefer bundle.deinit(allocator);

        var sealed_del: ?[]u8 = null;
        errdefer if (sealed_del) |s| allocator.free(s);
        if (req.target_runner_pubkey) |pk| {
            sealed_del = try bundle.sealForDevice(allocator, self.io, pk);
        }

        try self.syncCatalogSummary(pstore_ref);

        return .{
            .task_id = task_id,
            .child_thread_id = child_tid,
            .status = initial_status,
            .carved_budget = carved_budget,
            .forked_space_ids = try forked_ids.toOwnedSlice(allocator),
            .delegation_bundle = bundle,
            .sealed_delegation = sealed_del,
        };
    }

    pub fn postMailbox(self: *ThreadRuntime, target_thread_id: u128, item: model.MailboxItem) !bool {
        const store = try self.openThread(target_thread_id);
        if (store.mailbox.contains(item.item_id)) return false;

        var ev = try store.appendEvent(self.runner_id, .{ .mailbox_received = item });
        ev.deinit(self.allocator);
        try self.syncCatalogSummary(store);
        return true;
    }

    pub fn unreadMailboxCount(self: *ThreadRuntime, thread_id: u128) !usize {
        const store = try self.openThread(thread_id);
        var count: usize = 0;
        for (store.mailbox_order.items) |mid| {
            if (!self.acked_mailbox.contains(mid)) count += 1;
        }
        return count;
    }

    pub fn drainMailbox(self: *ThreadRuntime, allocator: Allocator, thread_id: u128) ![]model.MailboxItem {
        const store = try self.openThread(thread_id);
        var out: std.ArrayList(model.MailboxItem) = .empty;
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }

        for (store.mailbox_order.items) |mid| {
            if (self.acked_mailbox.contains(mid)) continue;
            if (store.mailbox.getPtr(mid)) |item| {
                try out.append(allocator, try item.clone(allocator));
                try self.acked_mailbox.put(self.allocator, mid, {});
            }
        }

        try self.syncCatalogSummary(store);
        return try out.toOwnedSlice(allocator);
    }

    pub fn evaluateReadyTasks(self: *ThreadRuntime, parent_thread_id: u128) !usize {
        const store = try self.openThread(parent_thread_id);
        return try store.evaluateReadyTasksWithActor(self.runner_id);
    }

    pub fn settleTask(
        self: *ThreadRuntime,
        parent_thread_id: u128,
        task_id: u128,
        terminal_status: model.TaskStatus,
        result_summary: []const u8,
        child_used_budget: ?model.Budget,
    ) !usize {
        if (!terminal_status.isTerminal()) return error.InvalidTaskTransition;

        const parent_store = try self.openThread(parent_thread_id);
        const task_ptr = parent_store.tasks.getPtr(task_id) orelse return error.TaskNotFound;
        if (task_ptr.status.isTerminal()) return error.InvalidTaskTransition;
        if (!task_ptr.status.canTransitionTo(terminal_status)) return error.InvalidTaskTransition;

        const child_tid = task_ptr.child_thread_id;
        var updated_task = try task_ptr.clone(self.allocator);
        defer updated_task.deinit(self.allocator);

        var eff_child_budget = updated_task.budget;
        var end_cp = model.CheckpointVector{};
        defer end_cp.deinit(self.allocator);

        if (self.openThread(child_tid)) |child_store| {
            if (child_store.meta) |cm| {
                if (child_used_budget == null) {
                    eff_child_budget.used_tokens = cm.budget.used_tokens;
                    eff_child_budget.used_cost_microusd = cm.budget.used_cost_microusd;
                    eff_child_budget.used_wall_ms = cm.budget.used_wall_ms;
                }
                if (cm.bindings.len > 0) {
                    end_cp = try self.captureCheckpointVector(cm.bindings, false);
                }
            }
        } else |_| {}

        if (child_used_budget) |cub| {
            eff_child_budget.used_tokens = cub.used_tokens;
            eff_child_budget.used_cost_microusd = cub.used_cost_microusd;
            eff_child_budget.used_wall_ms = cub.used_wall_ms;
        }

        const now = id.nowMs(self.io);
        updated_task.status = terminal_status;
        updated_task.budget = eff_child_budget;
        updated_task.end_checkpoint.deinit(self.allocator);
        updated_task.end_checkpoint = try end_cp.clone(self.allocator);
        if ((terminal_status == .failed or terminal_status == .canceled) and result_summary.len > 0) {
            if (updated_task.err_msg) |old| self.allocator.free(old);
            updated_task.err_msg = try self.allocator.dupe(u8, result_summary);
        }
        updated_task.updated_ms = @max(now, updated_task.updated_ms + 1);

        const pstore = try self.openThread(parent_thread_id);
        var tev = try pstore.appendEvent(self.runner_id, .{ .task_updated = updated_task });
        tev.deinit(self.allocator);

        if (pstore.meta) |pm| {
            var pbudget = pm.budget;
            pbudget.refundChild(eff_child_budget);
            var buev = try pstore.appendEvent(self.runner_id, .{ .thread_updated = .{
                .budget = pbudget,
                .updated_ms = @max(now, pm.updated_ms + 1),
            } });
            buev.deinit(self.allocator);
        }

        _ = try self.postMailbox(parent_thread_id, .{
            .item_id = id.newUuidV7(self.io),
            .from_thread_id = child_tid,
            .to_thread_id = parent_thread_id,
            .task_id = task_id,
            .kind = if (terminal_status == .canceled) .cancel else .result,
            .payload = @constCast(result_summary),
            .checkpoint = end_cp,
            .created_ms = now,
        });

        const newly_ready = try pstore.evaluateReadyTasksWithActor(self.runner_id);
        try self.syncCatalogSummary(pstore);
        return newly_ready;
    }

    fn cancelTreeRec(
        self: *ThreadRuntime,
        thread_id: u128,
        reason: ?[]const u8,
        visited: *std.AutoHashMapUnmanaged(u128, void),
        report: *CancelTreeReport,
    ) !void {
        if (visited.contains(thread_id)) return;
        try visited.put(self.allocator, thread_id, {});

        const store = try self.openThread(thread_id);
        const now = id.nowMs(self.io);

        const ttopic = topicId(.thread, thread_id);
        const next_epoch: u64 = blk: {
            if (self.active_turns.getPtr(thread_id)) |at| {
                break :blk at.lease.fencing_epoch + 1;
            }
            if (store.last_lease) |ll| {
                break :blk ll.fencing_epoch + 1;
            }
            break :blk 1;
        };
        _ = self.leases.cancelTopic(ttopic, next_epoch) catch {};
        report.canceled_leases += 1;

        if (self.active_turns.fetchRemove(thread_id)) |kv| {
            var lc = kv.value.lease;
            self.leases.release(&lc) catch {};
        }

        const ChildInfo = struct {
            task_id: u128,
            child_thread_id: u128,
            budget: model.Budget,
            was_active: bool,
        };
        var children: std.ArrayList(ChildInfo) = .empty;
        defer children.deinit(self.allocator);

        var tit = store.tasks.valueIterator();
        while (tit.next()) |t| {
            try children.append(self.allocator, .{
                .task_id = t.task_id,
                .child_thread_id = t.child_thread_id,
                .budget = t.budget,
                .was_active = !t.status.isTerminal(),
            });
        }

        var cev = try store.appendEvent(self.runner_id, .{ .cancel_tree = .{
            .root_task_id = null,
            .reason = if (reason) |r| @constCast(r) else null,
            .canceled_ms = now,
        } });
        cev.deinit(self.allocator);
        report.canceled_threads += 1;

        var refund_budget_needed = false;
        var parent_budget: model.Budget = if (store.meta) |m| m.budget else .{};
        for (children.items) |ch| {
            if (ch.was_active) {
                report.canceled_tasks += 1;
                var child_b = ch.budget;
                if (self.openThread(ch.child_thread_id)) |cs| {
                    if (cs.meta) |cm| {
                        child_b.used_tokens = cm.budget.used_tokens;
                        child_b.used_cost_microusd = cm.budget.used_cost_microusd;
                        child_b.used_wall_ms = cm.budget.used_wall_ms;
                    }
                } else |_| {}
                parent_budget.refundChild(child_b);
                refund_budget_needed = true;
            }
        }

        const store_again = try self.openThread(thread_id);
        if (store_again.meta) |m| {
            if (refund_budget_needed or m.status == .running) {
                var uev = try store_again.appendEvent(self.runner_id, .{ .thread_updated = .{
                    .status = if (m.status == .running) .interrupted else null,
                    .budget = if (refund_budget_needed) parent_budget else null,
                    .updated_ms = @max(now, m.updated_ms + 1),
                } });
                uev.deinit(self.allocator);
            }
            try self.syncCatalogSummary(store_again);
        }

        for (children.items) |ch| {
            if (ch.was_active) {
                _ = self.postMailbox(ch.child_thread_id, .{
                    .item_id = id.newUuidV7(self.io),
                    .from_thread_id = thread_id,
                    .to_thread_id = ch.child_thread_id,
                    .task_id = ch.task_id,
                    .kind = .cancel,
                    .payload = @constCast(reason orelse "cancelled"),
                    .created_ms = now,
                }) catch {};
            }
            try self.cancelTreeRec(ch.child_thread_id, reason, visited, report);
        }
    }

    pub fn cancelTree(self: *ThreadRuntime, root_thread_id: u128, reason: ?[]const u8) !CancelTreeReport {
        var visited: std.AutoHashMapUnmanaged(u128, void) = .empty;
        defer visited.deinit(self.allocator);
        var report = CancelTreeReport{};
        try self.cancelTreeRec(root_thread_id, reason, &visited, &report);
        return report;
    }

    pub fn retryTask(self: *ThreadRuntime, parent_thread_id: u128, task_id: u128) !u128 {
        const parent_store = try self.openThread(parent_thread_id);
        const orig_ptr = parent_store.tasks.getPtr(task_id) orelse return error.TaskNotFound;
        const parent_meta = parent_store.meta orelse return error.ThreadNotFound;

        var orig = try orig_ptr.clone(self.allocator);
        defer orig.deinit(self.allocator);

        var req_budget = orig.budget;
        req_budget.used_tokens = 0;
        req_budget.used_cost_microusd = 0;
        req_budget.used_wall_ms = 0;
        req_budget.active_children = 0;

        var parent_budget = parent_meta.budget;
        const carved = try parent_budget.carveChild(req_budget, parent_meta.depth);

        const new_task_id = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);

        var child_meta = try self.createThread(.{
            .title = orig.title,
            .project_id = parent_meta.project_id,
            .bindings = orig.grants,
            .parent_thread_id = parent_thread_id,
            .root_thread_id = parent_meta.root_thread_id,
            .parent_task_id = new_task_id,
            .depth = parent_meta.depth + 1,
            .budget = carved,
            .placement = orig.placement,
            .provider_id = parent_meta.default_provider,
            .model = parent_meta.default_model,
        });
        const new_child_tid = child_meta.thread_id;
        defer child_meta.deinit(self.allocator);

        const retry_task = model.Task{
            .task_id = new_task_id,
            .parent_thread_id = parent_thread_id,
            .child_thread_id = new_child_tid,
            .title = orig.title,
            .status = .ready,
            .attempt = orig.attempt + 1,
            .depends_on = orig.depends_on,
            .join_quorum = orig.join_quorum,
            .placement = orig.placement,
            .grants = orig.grants,
            .budget = carved,
            .start_checkpoint = child_meta.root_checkpoint,
            .end_checkpoint = .{},
            .err_msg = null,
            .created_ms = now,
            .updated_ms = now,
        };

        const pstore = try self.openThread(parent_thread_id);
        var buev = try pstore.appendEvent(self.runner_id, .{ .thread_updated = .{
            .budget = parent_budget,
            .updated_ms = @max(now, parent_meta.updated_ms + 1),
        } });
        buev.deinit(self.allocator);

        var tkev = try pstore.appendEvent(self.runner_id, .{ .task_created = retry_task });
        tkev.deinit(self.allocator);
        try self.syncCatalogSummary(pstore);
        return new_task_id;
    }

    pub fn landSubordinateForks(
        self: *ThreadRuntime,
        allocator: Allocator,
        parent_thread_id: u128,
        task_id: u128,
    ) !project_mod.SpaceSetLandReport {
        const store = try self.openThread(parent_thread_id);
        const task = store.tasks.getPtr(task_id) orelse return error.TaskNotFound;

        var fork_ids: std.ArrayList(u128) = .empty;
        defer fork_ids.deinit(allocator);

        for (task.grants) |g| {
            if (self.spaces.get(g.space_id)) |rec| {
                if (rec.origin != null) {
                    try fork_ids.append(allocator, g.space_id);
                }
            }
        }

        if (fork_ids.items.len == 0) {
            return .{
                .aborted = false,
                .entries = &.{},
                .failures = &.{},
            };
        }

        return try project_mod.SpaceSet.landSpaceSet(allocator, self.spaces, fork_ids.items);
    }

    fn spaceHeadsDigest(self: *ThreadRuntime, space_id: u128) ![32]u8 {
        const sp = try self.spaces.activate(space_id);
        var ver = try sp.headsClone(self.allocator);
        defer ver.deinit(self.allocator);

        var h = std.crypto.hash.Blake3.init(.{});
        h.update("0ndb-space-heads-v1:");
        var u128_buf: [16]u8 = undefined;
        var u64_buf: [8]u8 = undefined;
        std.mem.writeInt(u128, &u128_buf, space_id, .little);
        h.update(&u128_buf);
        const vs = ver.slice();
        std.mem.writeInt(u64, &u64_buf, vs.len, .little);
        h.update(&u64_buf);
        for (vs) |b| {
            std.mem.writeInt(u64, &u64_buf, b.ts, .little);
            h.update(&u64_buf);
            std.mem.writeInt(u128, &u128_buf, b.actor, .little);
            h.update(&u128_buf);
        }
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    pub fn registerTrigger(self: *ThreadRuntime, thread_id: u128, trigger: model.Trigger) !u128 {
        switch (trigger.kind) {
            .cron => |expr| {
                _ = try matchesCron(expr, 0);
            },
            else => {},
        }

        const store = try self.openThread(thread_id);
        var tr = try trigger.clone(self.allocator);
        defer tr.deinit(self.allocator);
        if (tr.trigger_id == 0) tr.trigger_id = id.newUuidV7(self.io);
        tr.thread_id = thread_id;
        if (tr.created_ms == 0) tr.created_ms = id.nowMs(self.io);

        var ev = try store.appendEvent(self.runner_id, .{ .trigger_put = tr });
        ev.deinit(self.allocator);

        if (tr.kind == .space_changed) {
            const sc = tr.kind.space_changed;
            if (self.spaces.get(sc.space_id) != null) {
                const dig = try self.spaceHeadsDigest(sc.space_id);
                try self.watched_space_digests.put(self.allocator, tr.trigger_id, dig);
            }
        }

        return tr.trigger_id;
    }

    pub fn disableTrigger(self: *ThreadRuntime, thread_id: u128, trigger_id: u128) !void {
        const store = try self.openThread(thread_id);
        const cur = store.triggers.getPtr(trigger_id) orelse return error.TriggerNotFound;
        var updated = try cur.clone(self.allocator);
        defer updated.deinit(self.allocator);
        updated.enabled = false;
        var ev = try store.appendEvent(self.runner_id, .{ .trigger_put = updated });
        ev.deinit(self.allocator);
    }

    pub fn listTriggers(self: *ThreadRuntime, allocator: Allocator, thread_id: u128) ![]model.Trigger {
        const store = try self.openThread(thread_id);
        var out: std.ArrayList(model.Trigger) = .empty;
        errdefer {
            for (out.items) |*t| t.deinit(allocator);
            out.deinit(allocator);
        }
        var it = store.triggers.valueIterator();
        while (it.next()) |tr| {
            try out.append(allocator, try tr.clone(allocator));
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn computeTriggerSlot(event_token: []const u8) u64 {
        var h = std.crypto.hash.Blake3.init(.{});
        h.update("0ndb-trigger-slot-v1:");
        h.update(event_token);
        var out: [32]u8 = undefined;
        h.final(&out);
        return std.mem.readInt(u64, out[0..8], .little);
    }

    pub fn fireTrigger(
        self: *ThreadRuntime,
        thread_id: u128,
        trigger_id: u128,
        event_token: []const u8,
        now_ms: u64,
    ) !FireTriggerOutcome {
        const store = try self.openThread(thread_id);
        const tr = store.triggers.getPtr(trigger_id) orelse return .not_found;
        if (!tr.enabled) return .disabled;

        const slot = computeTriggerSlot(event_token);
        const dkey = model.Trigger.dedupKey(trigger_id, slot);

        const thread_topic = topicId(.thread, thread_id);
        const expected_epoch: u64 = if (store.last_lease) |ll| ll.fencing_epoch else 0;
        var lease = try self.leases.acquire(thread_topic, expected_epoch, DEFAULT_LEASE_TTL_MS);
        defer self.leases.release(&lease) catch {};

        if (store.fired_triggers.contains(dkey)) return .already_fired;

        var fev = try store.appendEvent(self.runner_id, .{ .trigger_fired = .{
            .trigger_id = trigger_id,
            .fire_slot = slot,
            .dedup_key = dkey,
            .fired_ms = now_ms,
            .runner_id = self.runner_id,
        } });
        fev.deinit(self.allocator);

        if (tr.kind == .once) {
            var updated = try tr.clone(self.allocator);
            defer updated.deinit(self.allocator);
            updated.enabled = false;
            var uev = try store.appendEvent(self.runner_id, .{ .trigger_put = updated });
            uev.deinit(self.allocator);
        } else if (tr.kind == .space_changed) {
            const sc = tr.kind.space_changed;
            if (self.spaces.get(sc.space_id) != null) {
                const dig = try self.spaceHeadsDigest(sc.space_id);
                try self.watched_space_digests.put(self.allocator, trigger_id, dig);
            }
        }

        return .fired;
    }

    pub fn pollDueTriggers(
        self: *ThreadRuntime,
        allocator: Allocator,
        thread_id: u128,
        now_ms: u64,
    ) ![]DueTrigger {
        const store = try self.openThread(thread_id);
        var out: std.ArrayList(DueTrigger) = .empty;
        errdefer {
            for (out.items) |*d| d.deinit(allocator);
            out.deinit(allocator);
        }

        var it = store.triggers.valueIterator();
        while (it.next()) |tr| {
            if (!tr.enabled) continue;
            var token_opt: ?[]u8 = null;
            errdefer if (token_opt) |tk| allocator.free(tk);

            switch (tr.kind) {
                .once => |at_ms| {
                    if (now_ms >= at_ms) {
                        token_opt = try std.fmt.allocPrint(allocator, "once:{d}", .{at_ms});
                    }
                },
                .cron => |expr| {
                    const unix_secs = now_ms / 1000;
                    if (try matchesCron(expr, unix_secs)) {
                        const minute_slot = unix_secs / 60;
                        token_opt = try std.fmt.allocPrint(allocator, "cron:{d}", .{minute_slot});
                    }
                },
                .space_changed => |sc| {
                    if (self.spaces.get(sc.space_id) != null) {
                        const cur_dig = try self.spaceHeadsDigest(sc.space_id);
                        const changed = if (self.watched_space_digests.get(tr.trigger_id)) |prev_dig|
                            !std.mem.eql(u8, &prev_dig, &cur_dig)
                        else
                            true;
                        if (changed) {
                            var hex_buf: [64]u8 = undefined;
                            const hex = id.formatHashHex(cur_dig, &hex_buf);
                            token_opt = try std.fmt.allocPrint(allocator, "space:{s}", .{hex});
                        }
                    }
                },
                .mailbox => {
                    var newest: ?u128 = null;
                    for (store.mailbox_order.items) |mid| {
                        if (!self.acked_mailbox.contains(mid)) newest = mid;
                    }
                    if (newest) |mid| {
                        var hex_buf: [32]u8 = undefined;
                        const hex = id.formatIdHex(mid, &hex_buf);
                        token_opt = try std.fmt.allocPrint(allocator, "mailbox:{s}", .{hex});
                    }
                },
                .webhook => {},
            }

            if (token_opt) |tok| {
                const slot = computeTriggerSlot(tok);
                const dkey = model.Trigger.dedupKey(tr.trigger_id, slot);
                if (store.fired_triggers.contains(dkey)) {
                    allocator.free(tok);
                    continue;
                }
                const prompt_copy: []u8 = if (tr.prompt_template.len > 0)
                    try allocator.dupe(u8, tr.prompt_template)
                else
                    &.{};
                errdefer if (prompt_copy.len > 0) allocator.free(prompt_copy);
                try out.append(allocator, .{
                    .trigger_id = tr.trigger_id,
                    .event_token = tok,
                    .prompt = prompt_copy,
                });
            }
        }

        return try out.toOwnedSlice(allocator);
    }
};

const UtcDateTime = struct {
    minute: u8,
    hour: u8,
    dom: u8,
    month: u8,
    dow: u8,
};

fn unixToUtc(unix_secs: u64) UtcDateTime {
    const secs_per_day: u64 = 86400;
    const days: i64 = @intCast(unix_secs / secs_per_day);
    const rem: u64 = unix_secs % secs_per_day;

    const hour: u8 = @intCast(rem / 3600);
    const minute: u8 = @intCast((rem % 3600) / 60);
    const dow: u8 = @intCast(@mod(days + 4, 7));

    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const dom: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);

    return .{
        .minute = minute,
        .hour = hour,
        .dom = dom,
        .month = month,
        .dow = dow,
    };
}

fn parseCronUint(s: []const u8) !u8 {
    if (s.len == 0) return error.InvalidCronExpression;
    const v = std.fmt.parseInt(u16, s, 10) catch return error.InvalidCronExpression;
    if (v > 255) return error.InvalidCronExpression;
    return @intCast(v);
}

fn matchCronField(field: []const u8, value: u8, min_val: u8, max_val: u8, is_dow: bool) !bool {
    if (field.len == 0) return error.InvalidCronExpression;
    var matched = false;
    var items = std.mem.splitScalar(u8, field, ',');
    while (items.next()) |item| {
        if (item.len == 0) return error.InvalidCronExpression;
        var step: u8 = 1;
        var base_part = item;
        if (std.mem.indexOfScalar(u8, item, '/')) |slash| {
            base_part = item[0..slash];
            const step_str = item[slash + 1 ..];
            step = try parseCronUint(step_str);
            if (step == 0) return error.InvalidCronExpression;
        }

        if (std.mem.eql(u8, base_part, "*")) {
            if (value >= min_val and value <= max_val and ((value - min_val) % step == 0)) {
                matched = true;
            }
            continue;
        }

        if (std.mem.indexOfScalar(u8, base_part, '-')) |dash| {
            var lo = try parseCronUint(base_part[0..dash]);
            var hi = try parseCronUint(base_part[dash + 1 ..]);
            if (is_dow) {
                if (lo == 7) lo = 0;
                if (hi == 7) hi = 6;
            }
            if (lo < min_val or hi > max_val or lo > hi) return error.InvalidCronExpression;
            if (value >= lo and value <= hi and ((value - lo) % step == 0)) {
                matched = true;
            }
            continue;
        }

        var exact = try parseCronUint(base_part);
        if (is_dow and exact == 7) exact = 0;
        if (exact < min_val or exact > max_val) return error.InvalidCronExpression;
        if (std.mem.indexOfScalar(u8, item, '/') != null) {
            if (value >= exact and value <= max_val and ((value - exact) % step == 0)) {
                matched = true;
            }
        } else {
            if (value == exact) matched = true;
        }
    }
    return matched;
}

pub fn matchesCron(expr: []const u8, unix_secs: u64) !bool {
    var parts: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |tok| {
        if (count >= 5) return error.InvalidCronExpression;
        parts[count] = tok;
        count += 1;
    }
    if (count != 5) return error.InvalidCronExpression;

    const dt = unixToUtc(unix_secs);
    const m_ok = try matchCronField(parts[0], dt.minute, 0, 59, false);
    const h_ok = try matchCronField(parts[1], dt.hour, 0, 23, false);
    const dom_ok = try matchCronField(parts[2], dt.dom, 1, 31, false);
    const mon_ok = try matchCronField(parts[3], dt.month, 1, 12, false);
    const dow_ok = try matchCronField(parts[4], dt.dow, 0, 6, true);
    return m_ok and h_ok and dom_ok and mon_ok and dow_ok;
}
