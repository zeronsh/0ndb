const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const codec = @import("../core/codec.zig");
const mmap = @import("../store/mmap.zig");
const space_mod = @import("space.zig");
const projection_mod = @import("../fs/projection.zig");
const pool_mod = @import("../fs/pool.zig");
const vcs = @import("../fs/vcs.zig");
const git = @import("../fs/git.zig");
const git_dirs_mod = @import("../fs/git_dirs.zig");

const SPACES_REG_MAGIC: u32 = 0x53504332;
const SPACES_REG_VERSION: u16 = 1;
const PROJ_TABLE_MAGIC: u32 = 0x50524A32;
const PROJ_TABLE_VERSION: u16 = 1;
pub const BRANCH_PREFIX: []const u8 = "ondb/";

pub const ManagerError = error{
    SpaceNotFound,
    SpacePinned,
    VirtualSpaceCannotProject,
    CorruptRegistry,
    MissingOriginCheckout,
};

pub const SpaceRecord = struct {
    space_id: u128,
    title: []u8,
    kind: space_mod.SpaceKind,
    state_path: []u8,
    origin: ?space_mod.SpaceOrigin = null,
    git_remote_url: ?[]u8 = null,
    created_ms: u64,
    updated_ms: u64,

    pub fn clone(self: *const SpaceRecord, allocator: Allocator) Allocator.Error!SpaceRecord {
        const title_copy = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title_copy);
        const state_copy = try allocator.dupe(u8, self.state_path);
        errdefer allocator.free(state_copy);
        var origin_copy: ?space_mod.SpaceOrigin = if (self.origin) |*o| try o.clone(allocator) else null;
        errdefer if (origin_copy) |*o| o.deinit(allocator);
        const remote_copy: ?[]u8 = if (self.git_remote_url) |u| try allocator.dupe(u8, u) else null;
        return .{
            .space_id = self.space_id,
            .title = title_copy,
            .kind = self.kind,
            .state_path = state_copy,
            .origin = origin_copy,
            .git_remote_url = remote_copy,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn deinit(self: *SpaceRecord, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.state_path);
        if (self.origin) |*o| o.deinit(allocator);
        if (self.git_remote_url) |u| allocator.free(u);
        self.* = undefined;
    }

    pub fn encode(self: *const SpaceRecord, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.space_id);
        try w.writeBytes(allocator, self.title);
        try w.writeByte(allocator, @intFromEnum(self.kind));
        try w.writeBytes(allocator, self.state_path);
        if (self.origin) |*o| {
            try w.writeByte(allocator, 1);
            try o.encode(allocator, w);
        } else {
            try w.writeByte(allocator, 0);
        }
        if (self.git_remote_url) |u| {
            try w.writeByte(allocator, 1);
            try w.writeBytes(allocator, u);
        } else {
            try w.writeByte(allocator, 0);
        }
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!SpaceRecord {
        const sid = try r.readU128();
        const title_raw = try r.readBytes();
        const title = try allocator.dupe(u8, title_raw);
        errdefer allocator.free(title);
        const kind_b = try r.readByte();
        const kind = std.enums.fromInt(space_mod.SpaceKind, kind_b) orelse return error.InvalidData;
        const state_raw = try r.readBytes();
        const state_path = try allocator.dupe(u8, state_raw);
        errdefer allocator.free(state_path);
        const has_origin = try r.readByte();
        var origin: ?space_mod.SpaceOrigin = if (has_origin != 0) try space_mod.SpaceOrigin.decode(allocator, r) else null;
        errdefer if (origin) |*o| o.deinit(allocator);
        const has_remote = try r.readByte();
        const remote: ?[]u8 = if (has_remote != 0) try allocator.dupe(u8, try r.readBytes()) else null;
        errdefer if (remote) |u| allocator.free(u);
        const created_ms = try r.readU64();
        const updated_ms = try r.readU64();
        return .{
            .space_id = sid,
            .title = title,
            .kind = kind,
            .state_path = state_path,
            .origin = origin,
            .git_remote_url = remote,
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        };
    }
};

pub const ProjectionRecord = struct {
    space_id: u128,
    local_path: []u8,
    created_checkout: bool = false,
    repo_root: ?[]u8 = null,
    ref_name: ?[]u8 = null,

    pub fn clone(self: *const ProjectionRecord, allocator: Allocator) Allocator.Error!ProjectionRecord {
        const path_copy = try allocator.dupe(u8, self.local_path);
        errdefer allocator.free(path_copy);
        const rr_copy: ?[]u8 = if (self.repo_root) |r| try allocator.dupe(u8, r) else null;
        errdefer if (rr_copy) |r| allocator.free(r);
        const ref_copy: ?[]u8 = if (self.ref_name) |r| try allocator.dupe(u8, r) else null;
        return .{
            .space_id = self.space_id,
            .local_path = path_copy,
            .created_checkout = self.created_checkout,
            .repo_root = rr_copy,
            .ref_name = ref_copy,
        };
    }

    pub fn deinit(self: *ProjectionRecord, allocator: Allocator) void {
        allocator.free(self.local_path);
        if (self.repo_root) |r| allocator.free(r);
        if (self.ref_name) |r| allocator.free(r);
        self.* = undefined;
    }

    pub fn encode(self: *const ProjectionRecord, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.space_id);
        try w.writeBytes(allocator, self.local_path);
        try w.writeByte(allocator, if (self.created_checkout) 1 else 0);
        if (self.repo_root) |rr| {
            try w.writeByte(allocator, 1);
            try w.writeBytes(allocator, rr);
        } else {
            try w.writeByte(allocator, 0);
        }
        if (self.ref_name) |rn| {
            try w.writeByte(allocator, 1);
            try w.writeBytes(allocator, rn);
        } else {
            try w.writeByte(allocator, 0);
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!ProjectionRecord {
        const sid = try r.readU128();
        const path_raw = try r.readBytes();
        const local_path = try allocator.dupe(u8, path_raw);
        errdefer allocator.free(local_path);
        const created_checkout = (try r.readByte()) != 0;
        const has_rr = try r.readByte();
        const repo_root: ?[]u8 = if (has_rr != 0) try allocator.dupe(u8, try r.readBytes()) else null;
        errdefer if (repo_root) |rr| allocator.free(rr);
        const has_ref = try r.readByte();
        const ref_name: ?[]u8 = if (has_ref != 0) try allocator.dupe(u8, try r.readBytes()) else null;
        return .{
            .space_id = sid,
            .local_path = local_path,
            .created_checkout = created_checkout,
            .repo_root = repo_root,
            .ref_name = ref_name,
        };
    }
};

pub const SlotState = enum(u8) {
    cold = 0,
    warm = 1,
    hot = 2,
};

pub const SpaceSlot = struct {
    state: SlotState = .cold,
    pin_count: u32 = 0,
    last_active_ms: u64 = 0,
    access_seq: u64 = 0,
    approx_bytes: usize = 0,
    space: ?*space_mod.Space = null,
    projection: ?*projection_mod.Projection = null,
};

pub const SpaceManager = struct {
    allocator: Allocator,
    io: Io,
    state_dir_path: []u8,
    checkouts_dir_path: []u8,
    state_dir: Io.Dir,
    resources: ?*pool_mod.DaemonResources = null,
    records: std.ArrayList(SpaceRecord) = .empty,
    projections: std.AutoHashMapUnmanaged(u128, ProjectionRecord) = .empty,
    slots: std.AutoHashMapUnmanaged(u128, SpaceSlot) = .empty,
    next_access_seq: u64 = 1,

    pub fn open(
        allocator: Allocator,
        io: Io,
        state_dir_path: []const u8,
        checkouts_dir_path: []const u8,
        resources: ?*pool_mod.DaemonResources,
    ) !SpaceManager {
        try Io.Dir.cwd().createDirPath(io, state_dir_path);
        try Io.Dir.cwd().createDirPath(io, checkouts_dir_path);

        const spaces_dir = try std.fmt.allocPrint(allocator, "{s}/spaces", .{state_dir_path});
        defer allocator.free(spaces_dir);
        try Io.Dir.cwd().createDirPath(io, spaces_dir);

        var transferred = false;
        var state_dir = try Io.Dir.cwd().openDir(io, state_dir_path, .{ .iterate = true });
        errdefer if (!transferred) state_dir.close(io);

        const state_path_copy = try allocator.dupe(u8, state_dir_path);
        errdefer if (!transferred) allocator.free(state_path_copy);

        const checkouts_path_copy = try allocator.dupe(u8, checkouts_dir_path);
        errdefer if (!transferred) allocator.free(checkouts_path_copy);

        var self = SpaceManager{
            .allocator = allocator,
            .io = io,
            .state_dir_path = state_path_copy,
            .checkouts_dir_path = checkouts_path_copy,
            .state_dir = state_dir,
            .resources = resources,
            .records = .empty,
            .projections = .empty,
            .slots = .empty,
            .next_access_seq = 1,
        };
        transferred = true;
        errdefer self.deinit();

        try self.loadSpacesRegistry();
        try self.loadProjectionTable();

        for (self.records.items) |*rec| {
            try self.slots.put(allocator, rec.space_id, .{
                .state = .cold,
                .pin_count = 0,
                .last_active_ms = 0,
                .access_seq = 0,
                .approx_bytes = 0,
                .space = null,
                .projection = null,
            });
        }

        return self;
    }

    pub fn deinit(self: *SpaceManager) void {
        var sit = self.slots.valueIterator();
        while (sit.next()) |slot| {
            self.closeSlotResources(slot);
        }
        self.slots.deinit(self.allocator);

        var pit = self.projections.valueIterator();
        while (pit.next()) |p| p.deinit(self.allocator);
        self.projections.deinit(self.allocator);

        for (self.records.items) |*r| r.deinit(self.allocator);
        self.records.deinit(self.allocator);

        self.state_dir.close(self.io);
        self.allocator.free(self.state_dir_path);
        self.allocator.free(self.checkouts_dir_path);
    }

    fn closeSlotResources(self: *SpaceManager, slot: *SpaceSlot) void {
        if (slot.state == .hot) {
            if (self.resources) |res| res.governor.decHot();
        }
        if (slot.projection) |proj| {
            proj.deinit();
            self.allocator.destroy(proj);
            slot.projection = null;
        }
        if (slot.space) |sp| {
            sp.deinit();
            self.allocator.destroy(sp);
            slot.space = null;
        }
        if (slot.approx_bytes > 0) {
            if (self.resources) |res| res.governor.subWorkspaceBytes(slot.approx_bytes);
            slot.approx_bytes = 0;
        }
        slot.state = .cold;
    }

    pub fn list(self: *const SpaceManager) []const SpaceRecord {
        return self.records.items;
    }

    pub fn spaceCount(self: *const SpaceManager) usize {
        return self.records.items.len;
    }

    pub fn get(self: *const SpaceManager, space_id: u128) ?*const SpaceRecord {
        for (self.records.items) |*r| {
            if (r.space_id == space_id) return r;
        }
        return null;
    }

    fn getMut(self: *SpaceManager, space_id: u128) ?*SpaceRecord {
        for (self.records.items) |*r| {
            if (r.space_id == space_id) return r;
        }
        return null;
    }

    pub fn getProjectionRecord(self: *const SpaceManager, space_id: u128) ?*const ProjectionRecord {
        return self.projections.getPtr(space_id);
    }

    pub fn slotState(self: *const SpaceManager, space_id: u128) ?SlotState {
        const slot = self.slots.getPtr(space_id) orelse return null;
        return slot.state;
    }

    pub fn hotCount(self: *const SpaceManager) u32 {
        var count: u32 = 0;
        var it = self.slots.valueIterator();
        while (it.next()) |s| {
            if (s.state == .hot) count += 1;
        }
        return count;
    }

    pub fn warmCount(self: *const SpaceManager) u32 {
        var count: u32 = 0;
        var it = self.slots.valueIterator();
        while (it.next()) |s| {
            if (s.state == .warm) count += 1;
        }
        return count;
    }

    pub fn coldCount(self: *const SpaceManager) u32 {
        var count: u32 = 0;
        var it = self.slots.valueIterator();
        while (it.next()) |s| {
            if (s.state == .cold) count += 1;
        }
        return count;
    }

    fn totalApproxBytes(self: *const SpaceManager) usize {
        var total: usize = 0;
        var it = self.slots.valueIterator();
        while (it.next()) |s| {
            total +|= s.approx_bytes;
        }
        return total;
    }

    fn bumpAccess(self: *SpaceManager, slot: *SpaceSlot) void {
        slot.last_active_ms = id.nowMs(self.io);
        slot.access_seq = self.next_access_seq;
        self.next_access_seq += 1;
    }

    fn updateSlotBytes(self: *SpaceManager, slot: *SpaceSlot) void {
        const new_bytes: usize = if (slot.space) |sp| sp.approxMemoryBytes() else 0;
        if (self.resources) |res| {
            if (new_bytes > slot.approx_bytes) {
                res.governor.addWorkspaceBytes(new_bytes - slot.approx_bytes);
            } else if (slot.approx_bytes > new_bytes) {
                res.governor.subWorkspaceBytes(slot.approx_bytes - new_bytes);
            }
        }
        slot.approx_bytes = new_bytes;
    }

    pub fn pin(self: *SpaceManager, space_id: u128) !void {
        const slot = self.slots.getPtr(space_id) orelse return error.SpaceNotFound;
        slot.pin_count += 1;
        self.bumpAccess(slot);
    }

    pub fn unpin(self: *SpaceManager, space_id: u128) void {
        const slot = self.slots.getPtr(space_id) orelse return;
        if (slot.pin_count > 0) slot.pin_count -= 1;
    }

    pub fn activate(self: *SpaceManager, space_id: u128) !*space_mod.Space {
        const rec = self.get(space_id) orelse return error.SpaceNotFound;
        const slot = self.slots.getPtr(space_id) orelse return error.SpaceNotFound;
        self.bumpAccess(slot);

        if (slot.space) |sp| {
            self.updateSlotBytes(slot);
            return sp;
        }

        const sp = try self.allocator.create(space_mod.Space);
        errdefer self.allocator.destroy(sp);
        sp.* = try space_mod.Space.open(
            self.allocator,
            self.io,
            rec.state_path,
            rec.space_id,
            rec.kind,
            self.resources,
        );

        slot.space = sp;
        if (slot.state == .cold) slot.state = .warm;
        self.updateSlotBytes(slot);
        _ = self.evictToBudgetExcluding(space_id);
        return sp;
    }

    pub fn activateProjection(self: *SpaceManager, space_id: u128) !?*projection_mod.Projection {
        const rec = self.get(space_id) orelse return error.SpaceNotFound;
        if (rec.kind == .virtual) return null;

        const proj_rec = self.projections.getPtr(space_id) orelse return null;
        if (!dirExists(self.io, proj_rec.local_path)) return null;

        const slot = self.slots.getPtr(space_id) orelse return error.SpaceNotFound;
        self.bumpAccess(slot);

        if (slot.projection) |proj| {
            if (proj.hibernated) {
                if (slot.state != .hot) {
                    _ = self.evictHotForIncoming(space_id);
                }
                try proj.restoreFromHibernate();
                if (slot.state != .hot) {
                    slot.state = .hot;
                    if (self.resources) |res| res.governor.incHot();
                }
            }
            self.updateSlotBytes(slot);
            return proj;
        }

        const sp = try self.activate(space_id);
        _ = self.evictHotForIncoming(space_id);

        const proj = try self.allocator.create(projection_mod.Projection);
        errdefer self.allocator.destroy(proj);
        proj.* = try projection_mod.Projection.attach(
            self.allocator,
            self.io,
            sp,
            proj_rec.local_path,
            self.resources,
        );

        const slot_after = self.slots.getPtr(space_id).?;
        slot_after.projection = proj;
        if (slot_after.state != .hot) {
            slot_after.state = .hot;
            if (self.resources) |res| res.governor.incHot();
        }
        self.bumpAccess(slot_after);
        self.updateSlotBytes(slot_after);
        _ = self.evictToBudgetExcluding(space_id);
        return proj;
    }

    fn hibernateSlot(self: *SpaceManager, slot: *SpaceSlot) bool {
        if (slot.pin_count > 0) return false;
        if (slot.state != .hot) return false;

        if (slot.projection) |proj| {
            proj.hibernate();
        } else if (slot.space) |sp| {
            sp.hibernate();
        }
        slot.state = .warm;
        if (self.resources) |res| res.governor.decHot();
        self.updateSlotBytes(slot);
        return true;
    }

    fn coolSlotToCold(self: *SpaceManager, slot: *SpaceSlot) bool {
        if (slot.pin_count > 0) return false;
        if (slot.state == .cold) return false;
        self.closeSlotResources(slot);
        return true;
    }

    pub fn hibernateIdle(self: *SpaceManager, now_ms: u64, idle_ms: u64) usize {
        var count: usize = 0;
        var it = self.slots.valueIterator();
        while (it.next()) |slot| {
            if (slot.state != .hot) continue;
            if (slot.pin_count > 0) continue;
            if (now_ms >= slot.last_active_ms and (now_ms - slot.last_active_ms) >= idle_ms) {
                if (self.hibernateSlot(slot)) count += 1;
            }
        }
        if (self.resources) |res| res.refreshGovernorStats();
        return count;
    }

    pub fn evictToBudget(self: *SpaceManager) usize {
        return self.evictToBudgetExcluding(null);
    }

    fn evictHotForIncoming(self: *SpaceManager, incoming_id: u128) usize {
        const res = self.resources orelse return 0;
        const max_hot = res.governor.budget.max_hot_worktrees;
        if (max_hot == 0) return 0;
        var evicted: usize = 0;
        while (self.hotCount() >= max_hot) {
            const victim_id = self.findLruUnpinned(.hot, incoming_id) orelse break;
            const slot = self.slots.getPtr(victim_id) orelse break;
            if (!self.hibernateSlot(slot)) break;
            evicted += 1;
        }
        return evicted;
    }

    fn evictToBudgetExcluding(self: *SpaceManager, exclude_id: ?u128) usize {
        const res = self.resources orelse return 0;
        const budget = res.governor.budget;
        var evicted: usize = 0;

        if (budget.max_hot_worktrees > 0) {
            while (self.hotCount() > budget.max_hot_worktrees) {
                const victim_id = self.findLruUnpinned(.hot, exclude_id) orelse break;
                const slot = self.slots.getPtr(victim_id) orelse break;
                if (!self.hibernateSlot(slot)) break;
                evicted += 1;
            }
        }

        if (budget.active_workspaces_bytes > 0) {
            while (self.totalApproxBytes() > budget.active_workspaces_bytes) {
                if (self.findLruUnpinned(.hot, exclude_id)) |vid| {
                    const slot = self.slots.getPtr(vid) orelse break;
                    if (self.hibernateSlot(slot)) {
                        evicted += 1;
                        continue;
                    }
                }
                if (self.findLruUnpinned(.warm, exclude_id)) |vid| {
                    const slot = self.slots.getPtr(vid) orelse break;
                    if (self.coolSlotToCold(slot)) {
                        evicted += 1;
                        continue;
                    }
                }
                break;
            }
        }

        if (evicted > 0) res.refreshGovernorStats();
        return evicted;
    }

    fn findLruUnpinned(self: *const SpaceManager, target_state: SlotState, exclude_id: ?u128) ?u128 {
        var best_id: ?u128 = null;
        var best_seq: u64 = std.math.maxInt(u64);
        var it = self.slots.iterator();
        while (it.next()) |kv| {
            const sid = kv.key_ptr.*;
            if (exclude_id) |ex| {
                if (sid == ex) continue;
            }
            const slot = kv.value_ptr.*;
            if (slot.state != target_state) continue;
            if (slot.pin_count > 0) continue;
            if (best_id == null or slot.access_seq < best_seq) {
                best_id = sid;
                best_seq = slot.access_seq;
            }
        }
        return best_id;
    }

    pub fn createVirtual(self: *SpaceManager, title: []const u8) !SpaceRecord {
        const sid = id.newUuidV7(self.io);
        const state_path = try self.allocSpaceStatePath(sid);
        errdefer self.allocator.free(state_path);

        var sp = try space_mod.Space.open(
            self.allocator,
            self.io,
            state_path,
            sid,
            .virtual,
            self.resources,
        );
        sp.deinit();

        const now = id.nowMs(self.io);
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);

        var rec = SpaceRecord{
            .space_id = sid,
            .title = title_copy,
            .kind = .virtual,
            .state_path = state_path,
            .origin = null,
            .git_remote_url = null,
            .created_ms = now,
            .updated_ms = now,
        };
        var owned_by_records = false;
        errdefer if (!owned_by_records) rec.deinit(self.allocator);

        const out = try rec.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }

        try self.records.append(self.allocator, rec);
        owned_by_records = true;
        try self.slots.put(self.allocator, sid, .{
            .state = .cold,
            .pin_count = 0,
            .last_active_ms = 0,
            .access_seq = 0,
            .approx_bytes = 0,
            .space = null,
            .projection = null,
        });
        try self.saveSpacesRegistry();
        return out;
    }

    pub fn registerRemoteSpace(
        self: *SpaceManager,
        space_id_opt: ?u128,
        title: []const u8,
        kind: space_mod.SpaceKind,
        git_remote_url: ?[]const u8,
    ) !SpaceRecord {
        const sid = space_id_opt orelse id.newUuidV7(self.io);
        if (self.get(sid)) |existing| {
            return try existing.clone(self.allocator);
        }
        const state_path = try self.allocSpaceStatePath(sid);
        errdefer self.allocator.free(state_path);

        var sp = try space_mod.Space.open(
            self.allocator,
            self.io,
            state_path,
            sid,
            kind,
            self.resources,
        );
        sp.deinit();

        const now = id.nowMs(self.io);
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        const remote_copy: ?[]u8 = if (git_remote_url) |u| try self.allocator.dupe(u8, u) else null;
        errdefer if (remote_copy) |u| self.allocator.free(u);

        var rec = SpaceRecord{
            .space_id = sid,
            .title = title_copy,
            .kind = kind,
            .state_path = state_path,
            .origin = null,
            .git_remote_url = remote_copy,
            .created_ms = now,
            .updated_ms = now,
        };
        var owned = false;
        errdefer if (!owned) rec.deinit(self.allocator);

        const out = try rec.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }

        try self.records.append(self.allocator, rec);
        owned = true;
        try self.slots.put(self.allocator, sid, .{});
        try self.saveSpacesRegistry();
        return out;
    }

    pub fn adoptLocal(self: *SpaceManager, local_path: []const u8, title: []const u8) !SpaceRecord {
        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const canon = if (Io.Dir.cwd().realPathFile(self.io, local_path, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            local_path;

        var pit = self.projections.iterator();
        while (pit.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.local_path, canon)) {
                if (self.get(kv.key_ptr.*)) |existing| {
                    return try existing.clone(self.allocator);
                }
            }
        }

        var repo = try vcs.detect(self.allocator, self.io, canon);
        defer repo.deinit(self.allocator);

        const kind: space_mod.SpaceKind = if (repo.kind == .git) .git_worktree else .dir;
        var remote_url: ?[]u8 = null;
        if (kind == .git_worktree) {
            if (git_dirs_mod.GitDirs.locate(self.allocator, self.io, canon) catch null) |gd_val| {
                var gd = gd_val;
                defer gd.deinit(self.allocator);
                remote_url = readGitOriginUrl(self.allocator, self.io, gd.common_dir) catch null;
            }
        }
        errdefer if (remote_url) |u| self.allocator.free(u);

        const sid = id.newUuidV7(self.io);
        const state_path = try self.allocSpaceStatePath(sid);
        errdefer self.allocator.free(state_path);

        const now = id.nowMs(self.io);
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);

        var rec = SpaceRecord{
            .space_id = sid,
            .title = title_copy,
            .kind = kind,
            .state_path = state_path,
            .origin = null,
            .git_remote_url = remote_url,
            .created_ms = now,
            .updated_ms = now,
        };
        var rec_owned = false;
        errdefer if (!rec_owned) rec.deinit(self.allocator);

        const path_copy = try self.allocator.dupe(u8, canon);
        errdefer self.allocator.free(path_copy);
        const rr_copy: ?[]u8 = if (repo.kind == .git) try self.allocator.dupe(u8, repo.root) else null;
        errdefer if (rr_copy) |r| self.allocator.free(r);

        var proj_rec = ProjectionRecord{
            .space_id = sid,
            .local_path = path_copy,
            .created_checkout = false,
            .repo_root = rr_copy,
            .ref_name = null,
        };
        var proj_owned = false;
        errdefer if (!proj_owned) proj_rec.deinit(self.allocator);

        const out = try rec.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }

        try self.records.append(self.allocator, rec);
        rec_owned = true;
        try self.projections.put(self.allocator, sid, proj_rec);
        proj_owned = true;
        try self.slots.put(self.allocator, sid, .{});

        try self.saveSpacesRegistry();
        try self.saveProjectionTable();

        const proj_opt = try self.activateProjection(sid);
        if (proj_opt) |proj| {
            try proj.adoptInitial();
            if (self.slots.getPtr(sid)) |slot| self.updateSlotBytes(slot);
        }

        return out;
    }

    pub fn forkSpace(
        self: *SpaceManager,
        source_id: u128,
        title: []const u8,
        project_locally: bool,
    ) !SpaceRecord {
        const src_rec_const = self.get(source_id) orelse return error.SpaceNotFound;
        const src_kind = src_rec_const.kind;
        const src_remote: ?[]u8 = if (src_rec_const.git_remote_url) |u| try self.allocator.dupe(u8, u) else null;
        errdefer if (src_remote) |u| self.allocator.free(u);

        if (self.slots.getPtr(source_id)) |src_slot| {
            if (src_slot.projection) |p| {
                _ = try p.ingestDirty();
            }
        }

        const src_space = try self.activate(source_id);
        const new_sid = id.newUuidV7(self.io);
        const dst_state_path = try self.allocSpaceStatePath(new_sid);
        errdefer self.allocator.free(dst_state_path);

        const forked_sp = try self.allocator.create(space_mod.Space);
        var forked_inited = false;
        errdefer {
            if (forked_inited) forked_sp.deinit();
            self.allocator.destroy(forked_sp);
            Io.Dir.cwd().deleteTree(self.io, dst_state_path) catch {};
        }
        forked_sp.* = try src_space.forkCow(dst_state_path, new_sid);
        forked_inited = true;

        var new_proj_rec: ?ProjectionRecord = null;
        errdefer if (new_proj_rec) |*pr| pr.deinit(self.allocator);

        if (project_locally and src_kind != .virtual) {
            const dest_checkout = try self.allocCheckoutPath(new_sid);
            errdefer self.allocator.free(dest_checkout);

            if (src_kind == .git_worktree) {
                const src_proj_rec = self.projections.getPtr(source_id) orelse return error.MissingOriginCheckout;
                const repo_root = src_proj_rec.repo_root orelse src_proj_rec.local_path;

                var head_info = try vcs.head(self.allocator, self.io, src_proj_rec.local_path);
                defer head_info.deinit(self.allocator);
                const base_rev = head_info.rev orelse "HEAD";

                var hex_buf: [32]u8 = undefined;
                const hex_id = id.formatIdHex(new_sid, &hex_buf);
                const branch_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ BRANCH_PREFIX, hex_id[0..12] });
                errdefer self.allocator.free(branch_name);

                try git.addWorktree(self.allocator, self.io, repo_root, dest_checkout, branch_name, base_rev);
                errdefer {
                    git.removeWorktree(self.allocator, self.io, repo_root, dest_checkout) catch {
                        Io.Dir.cwd().deleteTree(self.io, dest_checkout) catch {};
                    };
                    git.deleteBranch(self.allocator, self.io, repo_root, branch_name) catch {};
                }

                if (forked_sp.origin) |*orig| {
                    var updated = try orig.clone(self.allocator);
                    defer updated.deinit(self.allocator);
                    if (updated.git_remote_url) |u| self.allocator.free(u);
                    updated.git_remote_url = if (src_remote) |u| try self.allocator.dupe(u8, u) else null;
                    if (updated.git_base_rev) |r| self.allocator.free(r);
                    updated.git_base_rev = try self.allocator.dupe(u8, base_rev);
                    try forked_sp.setOrigin(updated);
                }

                const rr_copy = try self.allocator.dupe(u8, repo_root);
                errdefer self.allocator.free(rr_copy);
                new_proj_rec = .{
                    .space_id = new_sid,
                    .local_path = dest_checkout,
                    .created_checkout = true,
                    .repo_root = rr_copy,
                    .ref_name = branch_name,
                };
            } else {
                try Io.Dir.cwd().createDirPath(self.io, dest_checkout);
                new_proj_rec = .{
                    .space_id = new_sid,
                    .local_path = dest_checkout,
                    .created_checkout = true,
                    .repo_root = null,
                    .ref_name = null,
                };
            }
        }

        const now = id.nowMs(self.io);
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        var origin_copy: ?space_mod.SpaceOrigin = if (forked_sp.origin) |*o| try o.clone(self.allocator) else null;
        errdefer if (origin_copy) |*o| o.deinit(self.allocator);

        var rec = SpaceRecord{
            .space_id = new_sid,
            .title = title_copy,
            .kind = src_kind,
            .state_path = dst_state_path,
            .origin = origin_copy,
            .git_remote_url = src_remote,
            .created_ms = now,
            .updated_ms = now,
        };
        var rec_owned = false;
        errdefer if (!rec_owned) rec.deinit(self.allocator);

        const out = try rec.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }

        const slot_bytes = forked_sp.approxMemoryBytes();
        try self.records.append(self.allocator, rec);
        rec_owned = true;

        const slot = SpaceSlot{
            .state = .warm,
            .pin_count = 0,
            .last_active_ms = now,
            .access_seq = self.next_access_seq,
            .approx_bytes = slot_bytes,
            .space = forked_sp,
            .projection = null,
        };
        self.next_access_seq += 1;
        forked_inited = false;
        if (self.resources) |res| res.governor.addWorkspaceBytes(slot_bytes);

        try self.slots.put(self.allocator, new_sid, slot);

        if (new_proj_rec) |pr| {
            try self.projections.put(self.allocator, new_sid, pr);
            new_proj_rec = null;
            try self.saveProjectionTable();
        }
        try self.saveSpacesRegistry();

        if (project_locally and src_kind != .virtual) {
            const proj_opt = try self.activateProjection(new_sid);
            if (proj_opt) |proj| {
                try proj.materializeToDisk(.{ .force = src_kind == .dir });
            }
        } else {
            _ = self.evictToBudgetExcluding(new_sid);
        }

        return out;
    }

    pub fn attachProjection(self: *SpaceManager, space_id: u128, local_path: []const u8) !void {
        const rec = self.get(space_id) orelse return error.SpaceNotFound;
        if (rec.kind == .virtual) return error.VirtualSpaceCannotProject;

        var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_str = if (Io.Dir.cwd().realPathFile(self.io, local_path, &canon_buf)) |n|
            canon_buf[0..n]
        else |_|
            local_path;

        var rr_copy: ?[]u8 = null;
        if (rec.kind == .git_worktree and dirExists(self.io, path_str)) {
            var repo = vcs.detect(self.allocator, self.io, path_str) catch vcs.VcsRepo{ .kind = .none, .root = try self.allocator.dupe(u8, path_str) };
            defer repo.deinit(self.allocator);
            if (repo.kind == .git) {
                rr_copy = try self.allocator.dupe(u8, repo.root);
            }
        }
        errdefer if (rr_copy) |r| self.allocator.free(r);

        const path_copy = try self.allocator.dupe(u8, path_str);
        errdefer self.allocator.free(path_copy);

        if (self.slots.getPtr(space_id)) |slot| {
            if (slot.projection) |proj| {
                if (slot.state == .hot) {
                    slot.state = .warm;
                    if (self.resources) |res| res.governor.decHot();
                }
                proj.deinit();
                self.allocator.destroy(proj);
                slot.projection = null;
            }
        }

        if (self.projections.fetchRemove(space_id)) |old_kv| {
            var old = old_kv.value;
            old.deinit(self.allocator);
        }

        try self.projections.put(self.allocator, space_id, .{
            .space_id = space_id,
            .local_path = path_copy,
            .created_checkout = false,
            .repo_root = rr_copy,
            .ref_name = null,
        });
        try self.saveProjectionTable();
    }

    pub fn detachProjection(self: *SpaceManager, space_id: u128) !void {
        if (self.get(space_id) == null) return error.SpaceNotFound;

        if (self.slots.getPtr(space_id)) |slot| {
            if (slot.projection) |proj| {
                if (slot.state == .hot) {
                    slot.state = .warm;
                    if (self.resources) |res| res.governor.decHot();
                }
                proj.deinit();
                self.allocator.destroy(proj);
                slot.projection = null;
            }
        }

        if (self.projections.fetchRemove(space_id)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
            try self.saveProjectionTable();
        }
    }

    pub fn removeSpace(self: *SpaceManager, space_id: u128, delete_local_checkout: bool) !void {
        if (self.slots.getPtr(space_id)) |slot| {
            if (slot.pin_count > 0) return error.SpacePinned;
            self.closeSlotResources(slot);
        }
        _ = self.slots.remove(space_id);

        var rec_idx: ?usize = null;
        for (self.records.items, 0..) |*r, idx| {
            if (r.space_id == space_id) {
                rec_idx = idx;
                break;
            }
        }
        const idx = rec_idx orelse return error.SpaceNotFound;
        var rec = self.records.orderedRemove(idx);
        defer rec.deinit(self.allocator);

        if (self.projections.fetchRemove(space_id)) |kv| {
            var pr = kv.value;
            defer pr.deinit(self.allocator);
            if (delete_local_checkout and pr.created_checkout) {
                if (rec.kind == .git_worktree and pr.repo_root != null) {
                    vcs.removeWorkspace(self.allocator, self.io, .git, pr.repo_root, pr.local_path, pr.ref_name, true) catch {};
                } else {
                    Io.Dir.cwd().deleteTree(self.io, pr.local_path) catch {};
                }
            }
            try self.saveProjectionTable();
        }

        Io.Dir.cwd().deleteTree(self.io, rec.state_path) catch {};
        try self.saveSpacesRegistry();
    }

    fn allocSpaceStatePath(self: *const SpaceManager, space_id: u128) Allocator.Error![]u8 {
        var hex_buf: [32]u8 = undefined;
        const hex = id.formatIdHex(space_id, &hex_buf);
        return try std.fmt.allocPrint(self.allocator, "{s}/spaces/{s}", .{ self.state_dir_path, hex });
    }

    fn allocCheckoutPath(self: *const SpaceManager, space_id: u128) Allocator.Error![]u8 {
        var hex_buf: [32]u8 = undefined;
        const hex = id.formatIdHex(space_id, &hex_buf);
        return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.checkouts_dir_path, hex });
    }

    fn loadSpacesRegistry(self: *SpaceManager) !void {
        var fl = try space_mod.FileFlock.acquireBlocking(self.io, self.state_dir, "spaces.reg.lock");
        defer fl.release(self.io);

        const f = self.state_dir.openFile(self.io, "spaces.reg", .{}) catch return;
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size == 0 or st.size > 64 * 1024 * 1024) return;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n < 10) return;

        var r = codec.Reader.init(buf[0..n]);
        const magic = try r.readU32();
        if (magic != SPACES_REG_MAGIC) return error.CorruptRegistry;
        const ver = try r.readU16();
        if (ver != SPACES_REG_VERSION) return error.CorruptRegistry;
        const count = try r.readU32();
        for (0..count) |_| {
            var rec = try SpaceRecord.decode(self.allocator, &r);
            errdefer rec.deinit(self.allocator);
            try self.records.append(self.allocator, rec);
        }
    }

    fn saveSpacesRegistry(self: *SpaceManager) !void {
        var fl = try space_mod.FileFlock.acquireBlocking(self.io, self.state_dir, "spaces.reg.lock");
        defer fl.release(self.io);

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, SPACES_REG_MAGIC);
        try w.writeU16(self.allocator, SPACES_REG_VERSION);
        try w.writeU32(self.allocator, @intCast(self.records.items.len));
        for (self.records.items) |*rec| {
            try rec.encode(self.allocator, &w);
        }
        try mmap.atomicWriteFile(self.io, self.state_dir, "spaces.reg", w.items());
    }

    fn loadProjectionTable(self: *SpaceManager) !void {
        var fl = try space_mod.FileFlock.acquireBlocking(self.io, self.state_dir, "projections.local.lock");
        defer fl.release(self.io);

        const f = self.state_dir.openFile(self.io, "projections.local", .{}) catch return;
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size == 0 or st.size > 64 * 1024 * 1024) return;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n < 10) return;

        var r = codec.Reader.init(buf[0..n]);
        const magic = try r.readU32();
        if (magic != PROJ_TABLE_MAGIC) return error.CorruptRegistry;
        const ver = try r.readU16();
        if (ver != PROJ_TABLE_VERSION) return error.CorruptRegistry;
        const count = try r.readU32();
        for (0..count) |_| {
            var pr = try ProjectionRecord.decode(self.allocator, &r);
            errdefer pr.deinit(self.allocator);
            if (self.projections.fetchRemove(pr.space_id)) |old_kv| {
                var old = old_kv.value;
                old.deinit(self.allocator);
            }
            try self.projections.put(self.allocator, pr.space_id, pr);
        }
    }

    fn saveProjectionTable(self: *SpaceManager) !void {
        var fl = try space_mod.FileFlock.acquireBlocking(self.io, self.state_dir, "projections.local.lock");
        defer fl.release(self.io);

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, PROJ_TABLE_MAGIC);
        try w.writeU16(self.allocator, PROJ_TABLE_VERSION);
        try w.writeU32(self.allocator, @intCast(self.projections.count()));
        var it = self.projections.valueIterator();
        while (it.next()) |pr| {
            try pr.encode(self.allocator, &w);
        }
        try mmap.atomicWriteFile(self.io, self.state_dir, "projections.local", w.items());
    }
};

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn readGitOriginUrl(allocator: Allocator, io: Io, common_dir: []const u8) !?[]u8 {
    const cfg_path = try std.fmt.allocPrint(allocator, "{s}/config", .{common_dir});
    defer allocator.free(cfg_path);
    const f = Io.Dir.cwd().openFile(io, cfg_path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    if (st.size == 0 or st.size > 512 * 1024) return null;
    const buf = try allocator.alloc(u8, @intCast(st.size));
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return null;

    var in_origin = false;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            in_origin = std.mem.eql(u8, line, "[remote \"origin\"]");
            continue;
        }
        if (in_origin) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const k = std.mem.trim(u8, line[0..eq], " \t");
                if (std.mem.eql(u8, k, "url")) {
                    const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
                    if (v.len > 0) return try allocator.dupe(u8, v);
                }
            }
        }
    }
    return null;
}
