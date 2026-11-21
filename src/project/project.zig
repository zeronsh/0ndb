const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const version_mod = @import("../core/version.zig");
const codec = @import("../core/codec.zig");
const mmap = @import("../store/mmap.zig");
const space_mod = @import("../space/space.zig");
const manager_mod = @import("../space/manager.zig");

const PROJECTS_REG_MAGIC: u32 = 0x50524F32;
const PROJECTS_REG_VERSION: u16 = 1;

pub const ProjectError = error{
    ProjectNotFound,
    CorruptRegistry,
};

pub const SpaceRef = struct {
    space_id: u128,
    alias: []u8,
    kind: space_mod.SpaceKind,
    default_access: u8,
    git_remote_url: ?[]u8 = null,

    pub fn clone(self: *const SpaceRef, allocator: Allocator) Allocator.Error!SpaceRef {
        const alias_copy = try allocator.dupe(u8, self.alias);
        errdefer allocator.free(alias_copy);
        const remote_copy: ?[]u8 = if (self.git_remote_url) |u| try allocator.dupe(u8, u) else null;
        return .{
            .space_id = self.space_id,
            .alias = alias_copy,
            .kind = self.kind,
            .default_access = self.default_access,
            .git_remote_url = remote_copy,
        };
    }

    pub fn deinit(self: *SpaceRef, allocator: Allocator) void {
        allocator.free(self.alias);
        if (self.git_remote_url) |u| allocator.free(u);
        self.* = undefined;
    }

    pub fn encode(self: *const SpaceRef, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.space_id);
        try w.writeBytes(allocator, self.alias);
        try w.writeByte(allocator, @backingInt(self.kind));
        try w.writeByte(allocator, self.default_access);
        if (self.git_remote_url) |u| {
            try w.writeByte(allocator, 1);
            try w.writeBytes(allocator, u);
        } else {
            try w.writeByte(allocator, 0);
        }
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!SpaceRef {
        const sid = try r.readU128();
        const alias_raw = try r.readBytes();
        const alias = try allocator.dupe(u8, alias_raw);
        errdefer allocator.free(alias);
        const kind_b = try r.readByte();
        const kind = std.enums.fromInt(space_mod.SpaceKind, kind_b) orelse return error.InvalidData;
        const access = try r.readByte();
        const has_remote = try r.readByte();
        const remote: ?[]u8 = if (has_remote != 0) try allocator.dupe(u8, try r.readBytes()) else null;
        return .{
            .space_id = sid,
            .alias = alias,
            .kind = kind,
            .default_access = access,
            .git_remote_url = remote,
        };
    }
};

pub const Project = struct {
    project_id: u128,
    title: []u8,
    instructions: []u8,
    spaces: []SpaceRef,
    default_provider: u8,
    default_model: ?[]u8,
    created_ms: u64,
    updated_ms: u64,

    pub fn clone(self: *const Project, allocator: Allocator) Allocator.Error!Project {
        const title_copy = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title_copy);
        const instr_copy = try allocator.dupe(u8, self.instructions);
        errdefer allocator.free(instr_copy);
        const spaces_copy = try allocator.alloc(SpaceRef, self.spaces.len);
        var cloned_count: usize = 0;
        errdefer {
            for (spaces_copy[0..cloned_count]) |*sr| sr.deinit(allocator);
            allocator.free(spaces_copy);
        }
        for (self.spaces, 0..) |*sr, i| {
            spaces_copy[i] = try sr.clone(allocator);
            cloned_count = i + 1;
        }
        const model_copy: ?[]u8 = if (self.default_model) |m| try allocator.dupe(u8, m) else null;
        return .{
            .project_id = self.project_id,
            .title = title_copy,
            .instructions = instr_copy,
            .spaces = spaces_copy,
            .default_provider = self.default_provider,
            .default_model = model_copy,
            .created_ms = self.created_ms,
            .updated_ms = self.updated_ms,
        };
    }

    pub fn deinit(self: *Project, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.instructions);
        for (self.spaces) |*sr| sr.deinit(allocator);
        if (self.spaces.len > 0) allocator.free(self.spaces);
        if (self.default_model) |m| allocator.free(m);
        self.* = undefined;
    }

    pub fn encode(self: *const Project, allocator: Allocator, w: *codec.Writer) Allocator.Error!void {
        try w.writeU128(allocator, self.project_id);
        try w.writeBytes(allocator, self.title);
        try w.writeBytes(allocator, self.instructions);
        try w.writeU32(allocator, @intCast(self.spaces.len));
        for (self.spaces) |*sr| {
            try sr.encode(allocator, w);
        }
        try w.writeByte(allocator, self.default_provider);
        if (self.default_model) |m| {
            try w.writeByte(allocator, 1);
            try w.writeBytes(allocator, m);
        } else {
            try w.writeByte(allocator, 0);
        }
        try w.writeU64(allocator, self.created_ms);
        try w.writeU64(allocator, self.updated_ms);
    }

    pub fn decode(allocator: Allocator, r: *codec.Reader) (codec.DecodeError || Allocator.Error)!Project {
        const pid = try r.readU128();
        const title = try allocator.dupe(u8, try r.readBytes());
        errdefer allocator.free(title);
        const instructions = try allocator.dupe(u8, try r.readBytes());
        errdefer allocator.free(instructions);
        const space_count = try r.readU32();
        const spaces = try allocator.alloc(SpaceRef, space_count);
        var loaded_spaces: usize = 0;
        errdefer {
            for (spaces[0..loaded_spaces]) |*sr| sr.deinit(allocator);
            allocator.free(spaces);
        }
        for (0..space_count) |i| {
            spaces[i] = try SpaceRef.decode(allocator, r);
            loaded_spaces = i + 1;
        }
        const default_provider = try r.readByte();
        const has_model = try r.readByte();
        const default_model: ?[]u8 = if (has_model != 0) try allocator.dupe(u8, try r.readBytes()) else null;
        errdefer if (default_model) |m| allocator.free(m);
        const created_ms = try r.readU64();
        const updated_ms = try r.readU64();
        return .{
            .project_id = pid,
            .title = title,
            .instructions = instructions,
            .spaces = spaces,
            .default_provider = default_provider,
            .default_model = default_model,
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        };
    }
};

pub const ProjectStore = struct {
    allocator: Allocator,
    io: Io,
    state_dir_path: []u8,
    state_dir: Io.Dir,
    projects: std.ArrayList(Project) = .empty,

    pub fn open(allocator: Allocator, io: Io, state_dir_path: []const u8) !ProjectStore {
        try Io.Dir.cwd().createDirPath(io, state_dir_path);

        var transferred = false;
        var state_dir = try Io.Dir.cwd().openDir(io, state_dir_path, .{ .iterate = true });
        errdefer if (!transferred) state_dir.close(io);

        const path_copy = try allocator.dupe(u8, state_dir_path);
        errdefer if (!transferred) allocator.free(path_copy);

        var self = ProjectStore{
            .allocator = allocator,
            .io = io,
            .state_dir_path = path_copy,
            .state_dir = state_dir,
            .projects = .empty,
        };
        transferred = true;
        errdefer self.deinit();

        try self.loadRegistry();
        return self;
    }

    pub fn deinit(self: *ProjectStore) void {
        for (self.projects.items) |*p| p.deinit(self.allocator);
        self.projects.deinit(self.allocator);
        self.state_dir.close(self.io);
        self.allocator.free(self.state_dir_path);
    }

    pub fn list(self: *const ProjectStore) []const Project {
        return self.projects.items;
    }

    pub fn get(self: *const ProjectStore, project_id: u128) ?*const Project {
        for (self.projects.items) |*p| {
            if (p.project_id == project_id) return p;
        }
        return null;
    }

    fn getMut(self: *ProjectStore, project_id: u128) ?*Project {
        for (self.projects.items) |*p| {
            if (p.project_id == project_id) return p;
        }
        return null;
    }

    pub fn create(
        self: *ProjectStore,
        title: []const u8,
        instructions: []const u8,
        default_provider: u8,
        default_model: ?[]const u8,
    ) !Project {
        const pid = id.newUuidV7(self.io);
        const now = id.nowMs(self.io);
        var fields_transferred = false;
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer if (!fields_transferred) self.allocator.free(title_copy);
        const instr_copy = try self.allocator.dupe(u8, instructions);
        errdefer if (!fields_transferred) self.allocator.free(instr_copy);
        const model_copy: ?[]u8 = if (default_model) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (!fields_transferred) if (model_copy) |m| self.allocator.free(m);

        var proj = Project{
            .project_id = pid,
            .title = title_copy,
            .instructions = instr_copy,
            .spaces = &.{},
            .default_provider = default_provider,
            .default_model = model_copy,
            .created_ms = now,
            .updated_ms = now,
        };
        fields_transferred = true;
        var owned = false;
        errdefer if (!owned) proj.deinit(self.allocator);

        const out = try proj.clone(self.allocator);
        errdefer {
            var tmp = out;
            tmp.deinit(self.allocator);
        }

        try self.projects.append(self.allocator, proj);
        owned = true;
        try self.saveRegistry();
        return out;
    }

    pub fn addSpace(self: *ProjectStore, project_id: u128, ref: SpaceRef) !void {
        const proj = self.getMut(project_id) orelse return error.ProjectNotFound;
        for (proj.spaces) |*existing| {
            if (existing.space_id == ref.space_id) {
                const cloned = try ref.clone(self.allocator);
                existing.deinit(self.allocator);
                existing.* = cloned;
                proj.updated_ms = id.nowMs(self.io);
                try self.saveRegistry();
                return;
            }
        }
        var cloned = try ref.clone(self.allocator);
        errdefer cloned.deinit(self.allocator);
        const next_spaces = try self.allocator.alloc(SpaceRef, proj.spaces.len + 1);
        @memcpy(next_spaces[0..proj.spaces.len], proj.spaces);
        next_spaces[proj.spaces.len] = cloned;
        if (proj.spaces.len > 0) self.allocator.free(proj.spaces);
        proj.spaces = next_spaces;
        proj.updated_ms = id.nowMs(self.io);
        try self.saveRegistry();
    }

    pub fn removeSpace(self: *ProjectStore, project_id: u128, space_id: u128) !bool {
        const proj = self.getMut(project_id) orelse return error.ProjectNotFound;
        var found_idx: ?usize = null;
        for (proj.spaces, 0..) |sr, idx| {
            if (sr.space_id == space_id) {
                found_idx = idx;
                break;
            }
        }
        const idx = found_idx orelse return false;
        if (proj.spaces.len == 1) {
            proj.spaces[idx].deinit(self.allocator);
            self.allocator.free(proj.spaces);
            proj.spaces = &.{};
        } else {
            const next_spaces = try self.allocator.alloc(SpaceRef, proj.spaces.len - 1);
            @memcpy(next_spaces[0..idx], proj.spaces[0..idx]);
            @memcpy(next_spaces[idx..], proj.spaces[idx + 1 ..]);
            proj.spaces[idx].deinit(self.allocator);
            self.allocator.free(proj.spaces);
            proj.spaces = next_spaces;
        }
        proj.updated_ms = id.nowMs(self.io);
        try self.saveRegistry();
        return true;
    }

    pub fn update(
        self: *ProjectStore,
        project_id: u128,
        title: ?[]const u8,
        instructions: ?[]const u8,
        default_provider: ?u8,
        default_model: ?[]const u8,
    ) !void {
        const proj = self.getMut(project_id) orelse return error.ProjectNotFound;
        if (title) |t| {
            const dup = try self.allocator.dupe(u8, t);
            self.allocator.free(proj.title);
            proj.title = dup;
        }
        if (instructions) |ins| {
            const dup = try self.allocator.dupe(u8, ins);
            self.allocator.free(proj.instructions);
            proj.instructions = dup;
        }
        if (default_provider) |dp| {
            proj.default_provider = dp;
        }
        if (default_model) |dm| {
            const dup = try self.allocator.dupe(u8, dm);
            if (proj.default_model) |old| self.allocator.free(old);
            proj.default_model = dup;
        }
        proj.updated_ms = id.nowMs(self.io);
        try self.saveRegistry();
    }

    pub fn delete(self: *ProjectStore, project_id: u128) !bool {
        for (self.projects.items, 0..) |*p, idx| {
            if (p.project_id == project_id) {
                var removed = self.projects.orderedRemove(idx);
                removed.deinit(self.allocator);
                try self.saveRegistry();
                return true;
            }
        }
        return false;
    }

    fn loadRegistry(self: *ProjectStore) !void {
        var fl = try space_mod.FileFlock.acquireBlocking(self.io, self.state_dir, "projects.reg.lock");
        defer fl.release(self.io);

        const f = self.state_dir.openFile(self.io, "projects.reg", .{}) catch return;
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size == 0 or st.size > 64 * 1024 * 1024) return;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n < 10) return;

        var r = codec.Reader.init(buf[0..n]);
        const magic = try r.readU32();
        if (magic != PROJECTS_REG_MAGIC) return error.CorruptRegistry;
        const ver = try r.readU16();
        if (ver != PROJECTS_REG_VERSION) return error.CorruptRegistry;
        const count = try r.readU32();
        for (0..count) |_| {
            var p = try Project.decode(self.allocator, &r);
            errdefer p.deinit(self.allocator);
            try self.projects.append(self.allocator, p);
        }
    }

    fn saveRegistry(self: *ProjectStore) !void {
        var fl = try space_mod.FileFlock.acquireBlocking(self.io, self.state_dir, "projects.reg.lock");
        defer fl.release(self.io);

        var w = codec.Writer{};
        defer w.deinit(self.allocator);
        try w.writeU32(self.allocator, PROJECTS_REG_MAGIC);
        try w.writeU16(self.allocator, PROJECTS_REG_VERSION);
        try w.writeU32(self.allocator, @intCast(self.projects.items.len));
        for (self.projects.items) |*p| {
            try p.encode(self.allocator, &w);
        }
        try mmap.atomicWriteFile(self.io, self.state_dir, "projects.reg", w.items());
    }
};

pub const SpaceSetSyncEntry = struct {
    space_id: u128,
    origin_space_id: u128,
    report: space_mod.SpaceSyncReport,

    pub fn deinit(self: *SpaceSetSyncEntry, allocator: Allocator) void {
        self.report.deinit(allocator);
    }
};

pub const SpaceSetLandEntry = struct {
    space_id: u128,
    origin_space_id: u128,
    report: space_mod.SpaceLandReport,

    pub fn deinit(self: *SpaceSetLandEntry, allocator: Allocator) void {
        self.report.deinit(allocator);
    }
};

pub const FailureReason = enum(u8) {
    space_not_found = 1,
    not_a_fork = 2,
    origin_not_found = 3,
    vcs_operation_in_progress = 4,
    unresolved_conflicts = 5,
    would_conflict = 6,
};

pub const SpaceSetFailure = struct {
    space_id: u128,
    reason: FailureReason,
    detail: ?[]u8 = null,

    pub fn deinit(self: *SpaceSetFailure, allocator: Allocator) void {
        if (self.detail) |d| allocator.free(d);
    }
};

pub const SpaceSetLandReport = struct {
    aborted: bool = false,
    entries: []SpaceSetLandEntry = &.{},
    failures: []SpaceSetFailure = &.{},

    pub fn deinit(self: *SpaceSetLandReport, allocator: Allocator) void {
        for (self.entries) |*e| e.deinit(allocator);
        if (self.entries.len > 0) allocator.free(self.entries);
        for (self.failures) |*f| f.deinit(allocator);
        if (self.failures.len > 0) allocator.free(self.failures);
    }
};

pub const SpaceSet = struct {
    pub fn forkSpaceSet(
        allocator: Allocator,
        manager: *manager_mod.SpaceManager,
        space_ids: []const u128,
        title_prefix: []const u8,
        project_locally: bool,
    ) ![]u128 {
        var created: std.ArrayList(u128) = .empty;
        errdefer {
            var i: usize = created.items.len;
            while (i > 0) {
                i -= 1;
                manager.removeSpace(created.items[i], true) catch {};
            }
            created.deinit(allocator);
        }

        for (space_ids, 0..) |sid, idx| {
            const rec = manager.get(sid) orelse return error.SpaceNotFound;
            const title = try std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ title_prefix, rec.title, idx });
            defer allocator.free(title);
            var forked = try manager.forkSpace(sid, title, project_locally);
            const new_id = forked.space_id;
            forked.deinit(allocator);
            try created.append(allocator, new_id);
        }

        return try created.toOwnedSlice(allocator);
    }

    pub fn syncSpaceSet(
        allocator: Allocator,
        manager: *manager_mod.SpaceManager,
        fork_ids: []const u128,
    ) ![]SpaceSetSyncEntry {
        var out: std.ArrayList(SpaceSetSyncEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }

        for (fork_ids) |fid| {
            try manager.pin(fid);
            defer manager.unpin(fid);

            const fork_sp = try manager.activate(fid);
            const origin = fork_sp.origin orelse return error.NotAFork;
            const oid = origin.origin_space_id;

            try manager.pin(oid);
            defer manager.unpin(oid);

            const origin_sp = try manager.activate(oid);
            if (try manager.activateProjection(oid)) |oproj| {
                _ = try oproj.ingestDirty();
            }
            const fork_proj = try manager.activateProjection(fid);
            if (fork_proj) |fproj| {
                _ = try fproj.ingestDirty();
            }

            var report = try fork_sp.syncFromOriginAlloc(allocator, origin_sp);
            errdefer report.deinit(allocator);

            if (fork_proj) |fproj| {
                try fproj.materializeChanged();
            }

            try out.append(allocator, .{
                .space_id = fid,
                .origin_space_id = oid,
                .report = report,
            });
        }

        return try out.toOwnedSlice(allocator);
    }

    pub fn landSpaceSet(
        allocator: Allocator,
        manager: *manager_mod.SpaceManager,
        fork_ids: []const u128,
    ) !SpaceSetLandReport {
        const Pair = struct {
            fork_id: u128,
            origin_id: u128,
        };
        var pairs: std.ArrayList(Pair) = .empty;
        defer pairs.deinit(allocator);

        var pinned: std.ArrayList(u128) = .empty;
        defer {
            for (pinned.items) |pid| manager.unpin(pid);
            pinned.deinit(allocator);
        }

        var failures: std.ArrayList(SpaceSetFailure) = .empty;
        errdefer {
            for (failures.items) |*f| f.deinit(allocator);
            failures.deinit(allocator);
        }

        var seen_origins: std.AutoHashMapUnmanaged(u128, void) = .empty;
        defer seen_origins.deinit(allocator);

        for (fork_ids) |fid| {
            if (manager.get(fid) == null) {
                try failures.append(allocator, .{
                    .space_id = fid,
                    .reason = .space_not_found,
                });
                continue;
            }
            try pinned.ensureUnusedCapacity(allocator, 1);
            try manager.pin(fid);
            pinned.appendAssumeCapacity(fid);

            const fork_sp = try manager.activate(fid);
            const origin = fork_sp.origin orelse {
                try failures.append(allocator, .{
                    .space_id = fid,
                    .reason = .not_a_fork,
                });
                continue;
            };
            const oid = origin.origin_space_id;
            if (manager.get(oid) == null) {
                try failures.append(allocator, .{
                    .space_id = fid,
                    .reason = .origin_not_found,
                });
                continue;
            }
            const gop = try seen_origins.getOrPut(allocator, oid);
            if (gop.found_existing) {
                try failures.append(allocator, .{
                    .space_id = fid,
                    .reason = .would_conflict,
                });
                continue;
            }
            try pinned.ensureUnusedCapacity(allocator, 1);
            try manager.pin(oid);
            pinned.appendAssumeCapacity(oid);

            const origin_sp = try manager.activate(oid);

            if (try manager.activateProjection(oid)) |oproj| {
                if (oproj.operationInProgress(allocator)) |op_name| {
                    try failures.append(allocator, .{
                        .space_id = fid,
                        .reason = .vcs_operation_in_progress,
                        .detail = try allocator.dupe(u8, op_name),
                    });
                    continue;
                }
                _ = try oproj.ingestDirty();
            }

            if (try manager.activateProjection(fid)) |fproj| {
                if (fproj.operationInProgress(allocator)) |op_name| {
                    try failures.append(allocator, .{
                        .space_id = fid,
                        .reason = .vcs_operation_in_progress,
                        .detail = try allocator.dupe(u8, op_name),
                    });
                    continue;
                }
                _ = try fproj.ingestDirty();
            }

            const existing = try fork_sp.conflicts(allocator);
            defer {
                for (existing) |*c| c.deinit(allocator);
                allocator.free(existing);
            }
            if (existing.len > 0) {
                try failures.append(allocator, .{
                    .space_id = fid,
                    .reason = .unresolved_conflicts,
                    .detail = try allocator.dupe(u8, existing[0].path),
                });
                continue;
            }

            const preview = try fork_sp.previewSyncConflicts(allocator, origin_sp);
            defer {
                for (preview) |p| allocator.free(p);
                allocator.free(preview);
            }
            if (preview.len > 0) {
                try failures.append(allocator, .{
                    .space_id = fid,
                    .reason = .would_conflict,
                    .detail = try allocator.dupe(u8, preview[0]),
                });
                continue;
            }

            try pairs.append(allocator, .{
                .fork_id = fid,
                .origin_id = oid,
            });
        }

        if (failures.items.len > 0) {
            return .{
                .aborted = true,
                .entries = &.{},
                .failures = try failures.toOwnedSlice(allocator),
            };
        }

        var pre_versions = try allocator.alloc(version_mod.Version, pairs.items.len);
        var pre_versions_inited: usize = 0;
        defer {
            for (pre_versions[0..pre_versions_inited]) |*v| v.deinit(allocator);
            allocator.free(pre_versions);
        }
        for (pairs.items, 0..) |pair, idx| {
            const origin_sp = try manager.activate(pair.origin_id);
            pre_versions[idx] = try origin_sp.headsClone(allocator);
            pre_versions_inited = idx + 1;
        }

        var rollback_limit: usize = 0;
        errdefer {
            var k: usize = rollback_limit;
            while (k > 0) {
                k -= 1;
                if (manager.activate(pairs.items[k].origin_id)) |osp| {
                    _ = osp.rollbackToVersion(osp.actor_id, &pre_versions[k]) catch {};
                    if (manager.activateProjection(pairs.items[k].origin_id) catch null) |oproj| {
                        oproj.materializeChanged() catch {};
                    }
                } else |_| {}
            }
        }

        var entries: std.ArrayList(SpaceSetLandEntry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        for (pairs.items, 0..) |pair, idx| {
            const fork_sp = try manager.activate(pair.fork_id);
            const origin_sp = try manager.activate(pair.origin_id);

            rollback_limit = idx + 1;
            var report = try fork_sp.landToOriginAlloc(allocator, origin_sp);
            var report_owned = true;
            errdefer if (report_owned) report.deinit(allocator);

            if (try manager.activateProjection(pair.fork_id)) |fproj| {
                try fproj.materializeChanged();
            }
            if (try manager.activateProjection(pair.origin_id)) |oproj| {
                try oproj.materializeChanged();
            }

            try entries.append(allocator, .{
                .space_id = pair.fork_id,
                .origin_space_id = pair.origin_id,
                .report = report,
            });
            report_owned = false;
        }

        return .{
            .aborted = false,
            .entries = try entries.toOwnedSlice(allocator),
            .failures = &.{},
        };
    }
};
