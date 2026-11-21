const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const ondb = @import("ondb");

const VERSION_STR = "0ndb 0.2.0";

const UsageError = error{
    MissingArgument,
    UnknownCommand,
    UnknownSubcommand,
    UnknownFlag,
    InvalidArgument,
    InvalidId,
};

var g_stop_requested: std.atomic.Value(bool) = .init(false);
var g_relay_wake_fd: std.atomic.Value(i32) = .init(-1);
var g_playground_listen_fd: std.atomic.Value(i32) = .init(-1);
var g_playground_running: std.atomic.Value(?*std.atomic.Value(bool)) = .init(null);

fn handleStopSignal(_: linux.SIG) callconv(.c) void {
    g_stop_requested.store(true, .release);
    const wfd = g_relay_wake_fd.load(.acquire);
    if (wfd >= 0) {
        const one: u64 = 1;
        _ = linux.write(wfd, std.mem.asBytes(&one), @sizeOf(u64));
    }
    if (g_playground_running.load(.acquire)) |rptr| {
        rptr.store(false, .release);
    }
    const lfd = g_playground_listen_fd.load(.acquire);
    if (lfd >= 0) {
        _ = linux.shutdown(lfd, linux.SHUT.RDWR);
    }
}

fn installStopSignalHandlers() void {
    g_stop_requested.store(false, .release);
    var act = linux.Sigaction{
        .handler = .{ .handler = handleStopSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
}

fn readEnvVarAlloc(allocator: Allocator, io: Io, name: []const u8) ?[]u8 {
    const f = Io.Dir.cwd().openFile(io, "/proc/self/environ", .{}) catch return null;
    defer f.close(io);
    const buf = allocator.alloc(u8, 1024 * 1024) catch return null;
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |entry| {
        if (entry.len > name.len and std.mem.startsWith(u8, entry, name) and entry[name.len] == '=') {
            return allocator.dupe(u8, entry[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

fn ensureDir0700(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    _ = linux.fchmod(dir.handle, 0o700);
}

fn chmodFile0600(io: Io, dir: Io.Dir, name: []const u8) void {
    var f = dir.openFile(io, name, .{}) catch return;
    defer f.close(io);
    _ = linux.fchmod(f.handle, 0o600);
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn discoverOndbRoot(allocator: Allocator, io: Io) ?[]u8 {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = Io.Dir.cwd().realPathFile(io, ".", &real_buf) catch return null;
    var cur: []const u8 = real_buf[0..cwd_len];
    while (true) {
        const cand = std.fmt.allocPrint(allocator, "{s}/.0ndb", .{cur}) catch return null;
        const found = dirExists(io, cand);
        allocator.free(cand);
        if (found) {
            return allocator.dupe(u8, cur) catch null;
        }
        const parent = std.fs.path.dirname(cur) orelse return null;
        if (std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
    }
}

const GlobalOpts = struct {
    target_dir: []u8,
    discovered_repo: bool,
    db_path: []u8,
    db_explicit: bool,
    home_dir: ?[]u8,

    fn deinit(self: *GlobalOpts, allocator: Allocator) void {
        allocator.free(self.target_dir);
        allocator.free(self.db_path);
        if (self.home_dir) |h| allocator.free(h);
    }

    fn workspaceStatePath(self: *const GlobalOpts, allocator: Allocator, override_root: ?[]const u8) ![]u8 {
        const root = override_root orelse self.target_dir;
        return try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{root});
    }

    fn defaultPlaygroundDir(self: *const GlobalOpts, allocator: Allocator) ![]u8 {
        if (self.home_dir) |h| {
            return try std.fmt.allocPrint(allocator, "{s}/.0ndb/playground", .{h});
        }
        return try std.fmt.allocPrint(allocator, "{s}/.0ndb/playground", .{self.target_dir});
    }
};

const ArgSlice = struct {
    items: []const []const u8,
    idx: usize = 0,

    fn next(self: *ArgSlice) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        const v = self.items[self.idx];
        self.idx += 1;
        return v;
    }

    fn peek(self: *const ArgSlice) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        return self.items[self.idx];
    }

    fn remaining(self: *const ArgSlice) []const []const u8 {
        return self.items[self.idx..];
    }
};

fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.MissingArgument,
        error.UnknownCommand,
        error.UnknownSubcommand,
        error.UnknownFlag,
        error.InvalidArgument,
        error.InvalidId,
        => true,
        else => false,
    };
}

pub fn main(init: std.process.Init) u8 {
    ondb.playground.server.ignoreSigpipe();
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var stderr_buf: [2048]u8 = undefined;
    var stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const err_out = &stderr_writer.interface;

    runMain(allocator, io, init.minimal.args, out) catch |err| {
        out.flush() catch {};
        if (isUsageError(err)) {
            err_out.print("usage error: {s}\nrun '0ndb --help' for usage.\n", .{@errorName(err)}) catch {};
            err_out.flush() catch {};
            return 2;
        }
        err_out.print("error: {s}\n", .{@errorName(err)}) catch {};
        err_out.flush() catch {};
        return 1;
    };
    out.flush() catch {};
    return 0;
}

fn runMain(allocator: Allocator, io: Io, raw_args: std.process.Args, out: anytype) !void {
    var args_it = try std.process.Args.Iterator.initAllocator(raw_args, allocator);
    defer args_it.deinit();
    _ = args_it.next();

    var all_args: std.ArrayList([]const u8) = .empty;
    defer all_args.deinit(allocator);
    while (args_it.next()) |a| {
        try all_args.append(allocator, a);
    }

    var dir_flag: ?[]const u8 = null;
    var db_flag: ?[]const u8 = null;
    var cmd_idx: usize = 0;

    while (cmd_idx < all_args.items.len) {
        const a = all_args.items[cmd_idx];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printUsage(out);
            return;
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            try out.print("{s}\n", .{VERSION_STR});
            return;
        } else if (std.mem.eql(u8, a, "-C") or std.mem.eql(u8, a, "--dir")) {
            cmd_idx += 1;
            if (cmd_idx >= all_args.items.len) return UsageError.MissingArgument;
            dir_flag = all_args.items[cmd_idx];
            cmd_idx += 1;
        } else if (std.mem.startsWith(u8, a, "--dir=")) {
            dir_flag = a["--dir=".len..];
            cmd_idx += 1;
        } else if (std.mem.eql(u8, a, "--db")) {
            cmd_idx += 1;
            if (cmd_idx >= all_args.items.len) return UsageError.MissingArgument;
            db_flag = all_args.items[cmd_idx];
            cmd_idx += 1;
        } else if (std.mem.startsWith(u8, a, "--db=")) {
            db_flag = a["--db=".len..];
            cmd_idx += 1;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return UsageError.UnknownFlag;
        } else {
            break;
        }
    }

    if (cmd_idx >= all_args.items.len) {
        try printUsage(out);
        return;
    }

    var opts_owned = false;
    const home_dir = readEnvVarAlloc(allocator, io, "HOME");
    errdefer if (!opts_owned) if (home_dir) |h| allocator.free(h);
    const env_db = readEnvVarAlloc(allocator, io, "ONDB_DB");
    defer if (env_db) |e| allocator.free(e);

    var target_dir: []u8 = undefined;
    var discovered_repo = false;
    if (dir_flag) |df| {
        target_dir = try allocator.dupe(u8, df);
        const dot_ondb = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{df});
        defer allocator.free(dot_ondb);
        discovered_repo = dirExists(io, dot_ondb);
    } else if (discoverOndbRoot(allocator, io)) |found| {
        target_dir = found;
        discovered_repo = true;
    } else {
        target_dir = try allocator.dupe(u8, ".");
        discovered_repo = false;
    }
    errdefer if (!opts_owned) allocator.free(target_dir);

    var db_path: []u8 = undefined;
    var db_explicit = false;
    if (db_flag) |dbf| {
        db_path = try allocator.dupe(u8, dbf);
        db_explicit = true;
    } else if (env_db != null and env_db.?.len > 0) {
        db_path = try allocator.dupe(u8, env_db.?);
        db_explicit = true;
    } else if (discovered_repo or dir_flag != null) {
        db_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/v2", .{target_dir});
    } else if (home_dir) |h| {
        db_path = try std.fmt.allocPrint(allocator, "{s}/.0ndb/v2", .{h});
    } else {
        db_path = try allocator.dupe(u8, ".0ndb/v2");
    }

    var opts = GlobalOpts{
        .target_dir = target_dir,
        .discovered_repo = discovered_repo,
        .db_path = db_path,
        .db_explicit = db_explicit,
        .home_dir = home_dir,
    };
    opts_owned = true;
    defer opts.deinit(allocator);

    var args = ArgSlice{ .items = all_args.items[cmd_idx..] };
    const cmd = args.next() orelse {
        try printUsage(out);
        return;
    };

    if (std.mem.eql(u8, cmd, "help")) {
        try printUsage(out);
        return;
    }

    if (std.mem.eql(u8, cmd, "space")) {
        try handleSpaceCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "project")) {
        try handleProjectCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "thread")) {
        try handleThreadCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "captain") or std.mem.eql(u8, cmd, "task")) {
        try handleCaptainCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "trigger")) {
        try handleTriggerCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "bench-bigrepo")) {
        try handleBenchBigRepo(allocator, io, &args, out);
    } else if (std.mem.eql(u8, cmd, "bench-many")) {
        try handleBenchMany(allocator, io, &args, out);
    } else if (std.mem.eql(u8, cmd, "bench-agents")) {
        try handleBenchAgents(allocator, io, &args, out);
    } else if (std.mem.eql(u8, cmd, "providers")) {
        try handleProvidersCmd(io, out);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try handleInitCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "adopt")) {
        try handleAdoptCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try handleStatusCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "watch")) {
        try handleWatchCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "blame")) {
        try handleBlameCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "log")) {
        try handleLogCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "diff")) {
        try handleDiffCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "changes")) {
        try handleChangesCmd(allocator, io, &opts, out);
    } else if (std.mem.eql(u8, cmd, "scopes")) {
        try handleScopesCmd(allocator, io, &opts, out);
    } else if (std.mem.eql(u8, cmd, "revert")) {
        try handleRevertCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "worktree")) {
        try handleWorktreeCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try handleRunCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "sync")) {
        try handleSyncCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "pr")) {
        try handlePrCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "verify")) {
        try handleVerifyCmd(allocator, io, &opts, out);
    } else if (std.mem.eql(u8, cmd, "sessions")) {
        try handleSessionsCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "relay")) {
        try handleRelayCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "playground")) {
        try handlePlaygroundCmd(allocator, io, &opts, &args, out);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        try runBench(allocator, io, out);
    } else {
        return UsageError.UnknownCommand;
    }
}

fn rejectExtraArgs(args: *ArgSlice) !void {
    if (args.next() != null) return UsageError.InvalidArgument;
}

const V2Layout = struct {
    resources_path: []u8,
    spaces_path: []u8,
    checkouts_path: []u8,
    projects_path: []u8,
    catalog_path: []u8,
    leases_path: []u8,
    threads_path: []u8,

    fn init(allocator: Allocator, io: Io, root: []const u8) !V2Layout {
        try ensureDir0700(io, root);
        const resources_path = try std.fmt.allocPrint(allocator, "{s}/resources", .{root});
        errdefer allocator.free(resources_path);
        const spaces_path = try std.fmt.allocPrint(allocator, "{s}/spaces", .{root});
        errdefer allocator.free(spaces_path);
        const checkouts_path = try std.fmt.allocPrint(allocator, "{s}/checkouts", .{root});
        errdefer allocator.free(checkouts_path);
        const projects_path = try std.fmt.allocPrint(allocator, "{s}/projects", .{root});
        errdefer allocator.free(projects_path);
        const catalog_path = try std.fmt.allocPrint(allocator, "{s}/catalog", .{root});
        errdefer allocator.free(catalog_path);
        const leases_path = try std.fmt.allocPrint(allocator, "{s}/leases", .{root});
        errdefer allocator.free(leases_path);
        const threads_path = try std.fmt.allocPrint(allocator, "{s}/threads", .{root});
        errdefer allocator.free(threads_path);

        try ensureDir0700(io, checkouts_path);
        try ensureDir0700(io, catalog_path);

        return .{
            .resources_path = resources_path,
            .spaces_path = spaces_path,
            .checkouts_path = checkouts_path,
            .projects_path = projects_path,
            .catalog_path = catalog_path,
            .leases_path = leases_path,
            .threads_path = threads_path,
        };
    }

    fn deinit(self: *V2Layout, allocator: Allocator) void {
        allocator.free(self.resources_path);
        allocator.free(self.spaces_path);
        allocator.free(self.checkouts_path);
        allocator.free(self.projects_path);
        allocator.free(self.catalog_path);
        allocator.free(self.leases_path);
        allocator.free(self.threads_path);
    }
};

const V2State = struct {
    allocator: Allocator,
    io: Io,
    db_dir: Io.Dir,
    catalog_dir: Io.Dir,
    resources: *ondb.fs.pool.DaemonResources,
    spaces: ondb.space.manager.SpaceManager,
    projects: ondb.project.ProjectStore,
    catalog: ondb.thread.store.CatalogStore,
    keyring: ondb.sync.keyring.Keyring,
    leases: ondb.sync.lease.LeaseManager,
    runtime: ondb.thread.runtime.ThreadRuntime,
    runner_id: u128,
    device_id: u128,

    fn open(allocator: Allocator, io: Io, db_path: []const u8) !*V2State {
        var layout = try V2Layout.init(allocator, io, db_path);
        defer layout.deinit(allocator);

        var db_dir = try Io.Dir.cwd().openDir(io, db_path, .{ .iterate = true });
        errdefer db_dir.close(io);

        var catalog_dir = try Io.Dir.cwd().openDir(io, layout.catalog_path, .{ .iterate = true });
        errdefer catalog_dir.close(io);

        const self = try allocator.create(V2State);
        errdefer allocator.destroy(self);

        const res = try ondb.fs.pool.DaemonResources.init(allocator, io, layout.resources_path, .{});
        errdefer res.deinit();

        var spaces = try ondb.space.manager.SpaceManager.open(allocator, io, layout.spaces_path, layout.checkouts_path, res);
        errdefer spaces.deinit();

        var projects = try ondb.project.ProjectStore.open(allocator, io, layout.projects_path);
        errdefer projects.deinit();

        var catalog = try ondb.thread.store.CatalogStore.open(allocator, io, catalog_dir);
        errdefer catalog.deinit();

        var keyring = ondb.sync.keyring.Keyring.load(allocator, io, db_dir, "keyring.bin") catch blk: {
            const rid = ondb.core.id.newUuidV7(io);
            const root_key = ondb.store.crypto.AccountRootKey.generate(io);
            const kr = ondb.sync.keyring.Keyring.initAccountDevice(allocator, io, root_key, rid);
            try kr.saveAtomic(db_dir, "keyring.bin");
            chmodFile0600(io, db_dir, "keyring.bin");
            break :blk kr;
        };
        errdefer keyring.deinit();

        const runner_id = keyring.runner_id;
        const device_id = keyring.runner_id;

        var leases = try ondb.sync.lease.LeaseManager.init(allocator, io, layout.leases_path, runner_id, null);
        errdefer leases.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .db_dir = db_dir,
            .catalog_dir = catalog_dir,
            .resources = res,
            .spaces = spaces,
            .projects = projects,
            .catalog = catalog,
            .keyring = keyring,
            .leases = leases,
            .runtime = undefined,
            .runner_id = runner_id,
            .device_id = device_id,
        };

        self.runtime = try ondb.thread.runtime.ThreadRuntime.init(allocator, io, .{
            .spaces = &self.spaces,
            .projects = &self.projects,
            .catalog = &self.catalog,
            .keyring = &self.keyring,
            .leases = &self.leases,
            .root_dir = layout.threads_path,
            .runner_id = runner_id,
            .device_id = device_id,
            .shared_blobs = res.blob_pool,
        });
        return self;
    }

    fn persistKeyring(self: *V2State) void {
        self.keyring.saveAtomic(self.db_dir, "keyring.bin") catch {};
        chmodFile0600(self.io, self.db_dir, "keyring.bin");
    }

    fn deinit(self: *V2State) void {
        self.persistKeyring();
        self.runtime.deinit();
        self.leases.deinit();
        self.keyring.deinit();
        self.catalog.deinit();
        self.catalog_dir.close(self.io);
        self.projects.deinit();
        self.spaces.deinit();
        self.resources.deinit();
        self.db_dir.close(self.io);
        self.allocator.destroy(self);
    }
};

fn parseIdHexOrUsage(s: []const u8) !u128 {
    return ondb.core.id.parseIdHex(s) catch return UsageError.InvalidId;
}

fn resolveSpaceId(mgr: *const ondb.space.manager.SpaceManager, query: []const u8) !u128 {
    if (query.len == 0) return UsageError.InvalidId;
    if (query.len == 32) {
        if (ondb.core.id.parseIdHex(query)) |sid| {
            if (mgr.get(sid) != null) return sid;
        } else |_| {}
    }
    var match: ?u128 = null;
    for (mgr.list()) |rec| {
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(rec.space_id, &hex);
        if (std.ascii.startsWithIgnoreCase(&hex, query) or std.mem.eql(u8, rec.title, query)) {
            if (match != null) return UsageError.InvalidId;
            match = rec.space_id;
        }
    }
    return match orelse UsageError.InvalidId;
}

fn resolveProjectId(store: *const ondb.project.ProjectStore, query: []const u8) !u128 {
    if (query.len == 0) return UsageError.InvalidId;
    if (query.len == 32) {
        if (ondb.core.id.parseIdHex(query)) |pid| {
            if (store.get(pid) != null) return pid;
        } else |_| {}
    }
    var match: ?u128 = null;
    for (store.list()) |p| {
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(p.project_id, &hex);
        if (std.ascii.startsWithIgnoreCase(&hex, query) or std.mem.eql(u8, p.title, query)) {
            if (match != null) return UsageError.InvalidId;
            match = p.project_id;
        }
    }
    return match orelse UsageError.InvalidId;
}

fn resolveThreadId(allocator: Allocator, rt: *const ondb.thread.runtime.ThreadRuntime, query: []const u8) !u128 {
    if (query.len == 0) return UsageError.InvalidId;
    if (query.len == 32) {
        return parseIdHexOrUsage(query);
    }
    const list = try rt.listThreads(allocator, null);
    defer {
        for (list) |*t| t.deinit(allocator);
        allocator.free(list);
    }
    var match: ?u128 = null;
    for (list) |t| {
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(t.thread_id, &hex);
        if (std.ascii.startsWithIgnoreCase(&hex, query)) {
            if (match != null) return UsageError.InvalidId;
            match = t.thread_id;
        }
    }
    return match orelse UsageError.InvalidId;
}

fn parseSpaceAccess(s: []const u8) !ondb.thread.model.SpaceAccess {
    if (std.mem.eql(u8, s, "ro") or std.mem.eql(u8, s, "read_only")) return .read_only;
    if (std.mem.eql(u8, s, "rw") or std.mem.eql(u8, s, "shared_rw")) return .shared_rw;
    if (std.mem.eql(u8, s, "fork") or std.mem.eql(u8, s, "isolated_fork")) return .isolated_fork;
    return UsageError.InvalidArgument;
}

fn parseSpaceBindingSpec(
    allocator: Allocator,
    mgr: *const ondb.space.manager.SpaceManager,
    spec: []const u8,
) !ondb.thread.model.SpaceBinding {
    var it = std.mem.splitScalar(u8, spec, ':');
    const sid_str = it.next() orelse return UsageError.InvalidArgument;
    const alias_str = it.next() orelse return UsageError.InvalidArgument;
    const access_str = it.next() orelse "rw";
    if (it.next() != null) return UsageError.InvalidArgument;

    const sid = try resolveSpaceId(mgr, sid_str);
    const access = try parseSpaceAccess(access_str);
    return .{
        .space_id = sid,
        .alias = try allocator.dupe(u8, alias_str),
        .access = access,
    };
}

fn parseBatchIdFromEntries(s: []const u8, entries: []const ondb.fs.timeline.TimelineEntry) !ondb.core.id.BatchId {
    const at_pos = std.mem.indexOfScalar(u8, s, '@') orelse return UsageError.InvalidArgument;
    const actor_str = s[0..at_pos];
    if (actor_str.len == 0) return UsageError.InvalidId;
    const ts_str = s[at_pos + 1 ..];
    const ts = std.fmt.parseInt(u64, ts_str, 10) catch return UsageError.InvalidArgument;
    if (actor_str.len == 32) {
        const actor = try parseIdHexOrUsage(actor_str);
        return ondb.core.id.OpId.init(ts, actor);
    }
    for (entries) |e| {
        if (e.batch_id.ts != ts) continue;
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(e.batch_id.actor, &hex);
        if (std.ascii.startsWithIgnoreCase(&hex, actor_str)) {
            return e.batch_id;
        }
    }
    return UsageError.InvalidId;
}

fn formatBatchId(bid: ondb.core.id.BatchId, out_buf: *[48]u8) []const u8 {
    var hex: [32]u8 = undefined;
    _ = ondb.core.id.formatIdHex(bid.actor, &hex);
    return std.fmt.bufPrint(out_buf, "{s}@{d}", .{ hex[0..8], bid.ts }) catch "";
}

fn handleSpaceCmd(
    allocator: Allocator,
    io: Io,
    opts: *const GlobalOpts,
    args: *ArgSlice,
    out: anytype,
) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    var layout = try V2Layout.init(allocator, io, opts.db_path);
    defer layout.deinit(allocator);

    var res = try ondb.fs.pool.DaemonResources.init(allocator, io, layout.resources_path, .{});
    defer res.deinit();
    var mgr = try ondb.space.manager.SpaceManager.open(allocator, io, layout.spaces_path, layout.checkouts_path, res);
    defer mgr.deinit();

    if (std.mem.eql(u8, sub, "create-virtual")) {
        const name = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        var rec = try mgr.createVirtual(name);
        defer rec.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(rec.space_id, &hex);
        try out.print("{s}\t{s}\t{s}\n", .{ hex, @tagName(rec.kind), rec.title });
    } else if (std.mem.eql(u8, sub, "adopt")) {
        const path = args.next() orelse return UsageError.MissingArgument;
        var name_opt: ?[]const u8 = null;
        var kind_req: ?ondb.space.space.SpaceKind = null;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--name")) {
                name_opt = args.next() orelse return UsageError.MissingArgument;
            } else if (std.mem.eql(u8, a, "--kind")) {
                const k = args.next() orelse return UsageError.MissingArgument;
                if (std.mem.eql(u8, k, "dir")) {
                    kind_req = .dir;
                } else if (std.mem.eql(u8, k, "git_worktree")) {
                    kind_req = .git_worktree;
                } else {
                    return UsageError.InvalidArgument;
                }
            } else {
                return UsageError.UnknownFlag;
            }
        }
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) {
            return UsageError.InvalidArgument;
        }
        var probe_dir = Io.Dir.cwd().openDir(io, path, .{}) catch return UsageError.InvalidArgument;
        probe_dir.close(io);
        if (kind_req) |kr| {
            var repo = try ondb.fs.vcs.detect(allocator, io, path);
            defer repo.deinit(allocator);
            if (kr == .git_worktree and repo.kind != .git) return UsageError.InvalidArgument;
            if (kr == .dir and repo.kind == .git) return UsageError.InvalidArgument;
        }
        const title = name_opt orelse blk: {
            const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
            break :blk if (base.len > 0) base else "space";
        };
        var rec = try mgr.adoptLocal(path, title);
        defer rec.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(rec.space_id, &hex);
        try out.print("{s}\t{s}\t{s}\n", .{ hex, @tagName(rec.kind), rec.title });
    } else if (std.mem.eql(u8, sub, "list")) {
        try rejectExtraArgs(args);
        for (mgr.list()) |rec| {
            var hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(rec.space_id, &hex);
            const local = if (mgr.getProjectionRecord(rec.space_id)) |pr| pr.local_path else "-";
            const origin_str: []const u8 = if (rec.origin != null) "fork" else "root";
            try out.print("{s}  {s:<12}  {s:<4}  title=\"{s}\"  path={s}\n", .{
                hex, @tagName(rec.kind), origin_str, rec.title, local,
            });
        }
    } else if (std.mem.eql(u8, sub, "read")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const rel = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        if (try mgr.activateProjection(sid)) |p| {
            _ = try p.ingestDirty();
        }
        const data = (try sp.readFileAlloc(allocator, rel)) orelse return error.FileNotFound;
        defer allocator.free(data);
        try out.writeAll(data);
    } else if (std.mem.eql(u8, sub, "write")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const rel = args.next() orelse return UsageError.MissingArgument;
        const third = args.next() orelse return UsageError.MissingArgument;
        const sid = try resolveSpaceId(&mgr, sid_str);
        var content_owned: ?[]u8 = null;
        defer if (content_owned) |b| allocator.free(b);
        var content: []const u8 = third;
        if (std.mem.eql(u8, third, "--file")) {
            const fpath = args.next() orelse return UsageError.MissingArgument;
            content_owned = try Io.Dir.cwd().readFileAlloc(io, fpath, allocator, .limited(64 * 1024 * 1024));
            content = content_owned.?;
        } else if (third.len > 1 and third[0] == '@') {
            content_owned = try Io.Dir.cwd().readFileAlloc(io, third[1..], allocator, .limited(64 * 1024 * 1024));
            content = content_owned.?;
        }
        try rejectExtraArgs(args);
        const sp = try mgr.activate(sid);
        const bid = try sp.putFile(sp.actor_id, rel, content);
        if (try mgr.activateProjection(sid)) |p| {
            try p.materializeChanged();
        }
        var bbuf: [48]u8 = undefined;
        try out.print("wrote {s} ({d} bytes) batch={s}\n", .{ rel, content.len, formatBatchId(bid, &bbuf) });
    } else if (std.mem.eql(u8, sub, "ls")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const dir_rel = args.next() orelse "";
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const entries = try sp.listDir(allocator, dir_rel);
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (entries) |e| {
            const suffix: []const u8 = if (e.kind == .dir) "/" else "";
            try out.print("{s:<7} {s}{s}\n", .{ @tagName(e.kind), e.name, suffix });
        }
    } else if (std.mem.eql(u8, sub, "search")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const query = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const hits = try sp.searchText(allocator, query, null, 200);
        defer {
            for (hits) |*h| h.deinit(allocator);
            allocator.free(hits);
        }
        for (hits) |h| {
            try out.print("{s}:{d}: {s}\n", .{ h.path, h.line, h.snippet });
        }
    } else if (std.mem.eql(u8, sub, "meta-get")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const key = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        if (sp.getMeta(key)) |val| {
            try out.print("{s}\n", .{val});
        } else {
            return error.MetaKeyNotFound;
        }
    } else if (std.mem.eql(u8, sub, "meta-set")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const key = args.next() orelse return UsageError.MissingArgument;
        const val = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const bid = try sp.setMeta(sp.actor_id, key, val);
        var bbuf: [48]u8 = undefined;
        try out.print("set {s} batch={s}\n", .{ key, formatBatchId(bid, &bbuf) });
    } else if (std.mem.eql(u8, sub, "meta-ls")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const prefix = args.next() orelse "";
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const entries = try sp.listMetaPrefix(allocator, prefix);
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (entries) |e| {
            try out.print("{s}={s}\n", .{ e.key, e.value });
        }
    } else if (std.mem.eql(u8, sub, "fork")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const new_name = args.next() orelse return UsageError.MissingArgument;
        var project_locally = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--local")) {
                project_locally = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }
        const sid = try resolveSpaceId(&mgr, sid_str);
        var frec = try mgr.forkSpace(sid, new_name, project_locally);
        defer frec.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(frec.space_id, &hex);
        try out.print("{s}\t{s}\t{s}\n", .{ hex, @tagName(frec.kind), frec.title });
    } else if (std.mem.eql(u8, sub, "sync")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const fork_ids = [_]u128{sid};
        const entries = try ondb.project.SpaceSet.syncSpaceSet(allocator, &mgr, &fork_ids);
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (entries) |e| {
            try out.print("synced brought={d} merged={d} conflicts={d}\n", .{
                e.report.brought, e.report.merged.len, e.report.conflicts.len,
            });
        }
    } else if (std.mem.eql(u8, sub, "land")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const fork_ids = [_]u128{sid};
        var rep = try ondb.project.SpaceSet.landSpaceSet(allocator, &mgr, &fork_ids);
        defer rep.deinit(allocator);
        if (rep.aborted) {
            for (rep.failures) |f| {
                try out.print("aborted reason={s} detail={s}\n", .{ @tagName(f.reason), f.detail orelse "-" });
            }
            return error.LandAborted;
        }
        for (rep.entries) |e| {
            try out.print("landed batches={d} brought={d} conflicts={d}\n", .{
                e.report.landed, e.report.sync.brought, e.report.sync.conflicts.len,
            });
        }
    } else if (std.mem.eql(u8, sub, "log")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const limit: usize = if (args.next()) |ls|
            std.fmt.parseInt(usize, ls, 10) catch return UsageError.InvalidArgument
        else
            30;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const entries = try ondb.fs.timeline.listEntriesForSpace(allocator, sp, null, limit);
        defer ondb.fs.timeline.freeTimelineEntries(allocator, entries);
        for (entries) |e| {
            var bbuf: [48]u8 = undefined;
            try out.print("{s}  +{d}/-{d}  files={d}\n", .{
                formatBatchId(e.batch_id, &bbuf), e.total_added, e.total_removed, e.files.len,
            });
            for (e.files) |fc| {
                try out.print("    {s:<8} {s} (+{d}/-{d})\n", .{ @tagName(fc.kind), fc.path, fc.added_lines, fc.removed_lines });
            }
        }
    } else if (std.mem.eql(u8, sub, "diff")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const bid_str_opt = args.next();
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const entries = try ondb.fs.timeline.listEntriesForSpace(allocator, sp, null, 200);
        defer ondb.fs.timeline.freeTimelineEntries(allocator, entries);
        if (entries.len == 0) return;
        const bid = if (bid_str_opt) |bs| try parseBatchIdFromEntries(bs, entries) else entries[0].batch_id;
        const diff_bytes = try ondb.fs.timeline.unifiedDiffForSpace(allocator, sp, &.{bid});
        defer allocator.free(diff_bytes);
        try out.writeAll(diff_bytes);
    } else if (std.mem.eql(u8, sub, "compact")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const sp = try mgr.activate(sid);
        const stats = try sp.compactWithPolicy(.{});
        try out.print("compacted pruned_batches={d} removed_blobs={d} removed_segments={d} base_bytes={d}\n", .{
            stats.pruned_batches, stats.removed_blobs, stats.removed_segments, stats.base_size_bytes,
        });
    } else if (std.mem.eql(u8, sub, "hibernate")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const sid = try resolveSpaceId(&mgr, sid_str);
        if (mgr.get(sid) == null) return UsageError.InvalidId;
        const n = mgr.hibernateIdle(ondb.core.id.nowMs(io) + 60_000, 0);
        try out.print("hibernated spaces={d}\n", .{n});
    } else if (std.mem.eql(u8, sub, "remove")) {
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        var del_checkout = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--delete-checkout")) {
                del_checkout = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }
        const sid = try resolveSpaceId(&mgr, sid_str);
        try mgr.removeSpace(sid, del_checkout);
        try out.print("removed\n", .{});
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleProjectCmd(
    allocator: Allocator,
    io: Io,
    opts: *const GlobalOpts,
    args: *ArgSlice,
    out: anytype,
) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    var layout = try V2Layout.init(allocator, io, opts.db_path);
    defer layout.deinit(allocator);

    var res = try ondb.fs.pool.DaemonResources.init(allocator, io, layout.resources_path, .{});
    defer res.deinit();
    var mgr = try ondb.space.manager.SpaceManager.open(allocator, io, layout.spaces_path, layout.checkouts_path, res);
    defer mgr.deinit();
    var pstore = try ondb.project.ProjectStore.open(allocator, io, layout.projects_path);
    defer pstore.deinit();

    if (std.mem.eql(u8, sub, "create")) {
        const name = args.next() orelse return UsageError.MissingArgument;
        var instr: []const u8 = "";
        var prov_id: u8 = @backingInt(ondb.providers.interface.ProviderId.claude_code);
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--instructions")) {
                instr = args.next() orelse return UsageError.MissingArgument;
            } else if (std.mem.eql(u8, a, "--provider")) {
                const slug = args.next() orelse return UsageError.MissingArgument;
                const p = ondb.providers.interface.ProviderId.fromSlug(slug) orelse return UsageError.InvalidArgument;
                prov_id = @backingInt(p);
            } else {
                return UsageError.UnknownFlag;
            }
        }
        var proj = try pstore.create(name, instr, prov_id, null);
        defer proj.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(proj.project_id, &hex);
        try out.print("{s}\t{s}\n", .{ hex, proj.title });
    } else if (std.mem.eql(u8, sub, "list")) {
        try rejectExtraArgs(args);
        for (pstore.list()) |p| {
            var hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(p.project_id, &hex);
            try out.print("{s}  spaces={d}  title=\"{s}\"\n", .{ hex, p.spaces.len, p.title });
            for (p.spaces) |sr| {
                var shex: [32]u8 = undefined;
                _ = ondb.core.id.formatIdHex(sr.space_id, &shex);
                try out.print("    {s}  alias={s}  kind={s}\n", .{ shex[0..12], sr.alias, @tagName(sr.kind) });
            }
        }
    } else if (std.mem.eql(u8, sub, "add-space")) {
        const pid_str = args.next() orelse return UsageError.MissingArgument;
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const role = args.next() orelse "default";
        try rejectExtraArgs(args);
        const pid = try resolveProjectId(&pstore, pid_str);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const rec = mgr.get(sid) orelse return UsageError.InvalidId;
        try pstore.addSpace(pid, .{
            .space_id = sid,
            .alias = @constCast(role),
            .kind = rec.kind,
            .default_access = @backingInt(ondb.thread.model.SpaceAccess.shared_rw),
            .git_remote_url = rec.git_remote_url,
        });
        try out.print("added space to project role={s}\n", .{role});
    } else if (std.mem.eql(u8, sub, "remove-space")) {
        const pid_str = args.next() orelse return UsageError.MissingArgument;
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const pid = try resolveProjectId(&pstore, pid_str);
        const sid = try resolveSpaceId(&mgr, sid_str);
        const removed = try pstore.removeSpace(pid, sid);
        try out.print("removed={}\n", .{removed});
    } else if (std.mem.eql(u8, sub, "fork")) {
        const pid_str = args.next() orelse return UsageError.MissingArgument;
        const new_name = args.next() orelse return UsageError.MissingArgument;
        var project_locally = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--local")) {
                project_locally = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }
        const pid = try resolveProjectId(&pstore, pid_str);
        const orig = pstore.get(pid) orelse return UsageError.InvalidId;
        var orig_copy = try orig.clone(allocator);
        defer orig_copy.deinit(allocator);

        const sids = try allocator.alloc(u128, orig_copy.spaces.len);
        defer allocator.free(sids);
        for (orig_copy.spaces, 0..) |sr, i| sids[i] = sr.space_id;

        const forked_ids = try ondb.project.SpaceSet.forkSpaceSet(allocator, &mgr, sids, new_name, project_locally);
        defer allocator.free(forked_ids);

        var new_proj = try pstore.create(new_name, orig_copy.instructions, orig_copy.default_provider, orig_copy.default_model);
        defer new_proj.deinit(allocator);

        for (forked_ids, 0..) |fid, i| {
            const frec = mgr.get(fid) orelse continue;
            try pstore.addSpace(new_proj.project_id, .{
                .space_id = fid,
                .alias = orig_copy.spaces[i].alias,
                .kind = frec.kind,
                .default_access = orig_copy.spaces[i].default_access,
                .git_remote_url = frec.git_remote_url,
            });
        }
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(new_proj.project_id, &hex);
        try out.print("{s}\t{s}\tforked_spaces={d}\n", .{ hex, new_proj.title, forked_ids.len });
    } else if (std.mem.eql(u8, sub, "sync")) {
        const pid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const pid = try resolveProjectId(&pstore, pid_str);
        const proj = pstore.get(pid) orelse return UsageError.InvalidId;
        var fork_ids: std.ArrayList(u128) = .empty;
        defer fork_ids.deinit(allocator);
        for (proj.spaces) |sr| {
            if (mgr.get(sr.space_id)) |rec| {
                if (rec.origin != null) try fork_ids.append(allocator, sr.space_id);
            }
        }
        const entries = try ondb.project.SpaceSet.syncSpaceSet(allocator, &mgr, fork_ids.items);
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        try out.print("synced spaces={d}\n", .{entries.len});
    } else if (std.mem.eql(u8, sub, "land")) {
        const pid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const pid = try resolveProjectId(&pstore, pid_str);
        const proj = pstore.get(pid) orelse return UsageError.InvalidId;
        var fork_ids: std.ArrayList(u128) = .empty;
        defer fork_ids.deinit(allocator);
        for (proj.spaces) |sr| {
            if (mgr.get(sr.space_id)) |rec| {
                if (rec.origin != null) try fork_ids.append(allocator, sr.space_id);
            }
        }
        var rep = try ondb.project.SpaceSet.landSpaceSet(allocator, &mgr, fork_ids.items);
        defer rep.deinit(allocator);
        if (rep.aborted) {
            for (rep.failures) |f| {
                try out.print("aborted reason={s} detail={s}\n", .{ @tagName(f.reason), f.detail orelse "-" });
            }
            return error.LandAborted;
        }
        try out.print("landed spaces={d}\n", .{rep.entries.len});
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleThreadCmd(
    allocator: Allocator,
    io: Io,
    opts: *const GlobalOpts,
    args: *ArgSlice,
    out: anytype,
) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    var v2 = try V2State.open(allocator, io, opts.db_path);
    defer v2.deinit();

    if (std.mem.eql(u8, sub, "create") or std.mem.eql(u8, sub, "new")) {
        var title: []const u8 = "thread";
        var project_id: ?u128 = null;
        var provider_id: ondb.providers.interface.ProviderId = .mock;
        var bindings: std.ArrayList(ondb.thread.model.SpaceBinding) = .empty;
        defer {
            for (bindings.items) |*b| b.deinit(allocator);
            bindings.deinit(allocator);
        }

        if (std.mem.eql(u8, sub, "new")) {
            if (args.peek()) |p0| {
                if (!std.mem.startsWith(u8, p0, "-")) {
                    const slug = args.next().?;
                    provider_id = ondb.providers.interface.ProviderId.fromSlug(slug) orelse return UsageError.InvalidArgument;
                    if (args.peek()) |p1| {
                        if (!std.mem.startsWith(u8, p1, "-")) {
                            title = args.next().?;
                        }
                    }
                }
            }
        }

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--title")) {
                title = args.next() orelse return UsageError.MissingArgument;
            } else if (std.mem.eql(u8, a, "--project")) {
                const ps = args.next() orelse return UsageError.MissingArgument;
                project_id = try resolveProjectId(&v2.projects, ps);
            } else if (std.mem.eql(u8, a, "--provider")) {
                const slug = args.next() orelse return UsageError.MissingArgument;
                provider_id = ondb.providers.interface.ProviderId.fromSlug(slug) orelse return UsageError.InvalidArgument;
            } else if (std.mem.eql(u8, a, "--space")) {
                const spec = args.next() orelse return UsageError.MissingArgument;
                try bindings.append(allocator, try parseSpaceBindingSpec(allocator, &v2.spaces, spec));
            } else {
                return UsageError.UnknownFlag;
            }
        }

        var meta = try v2.runtime.createThread(.{
            .title = title,
            .project_id = project_id,
            .bindings = bindings.items,
            .provider_id = provider_id,
        });
        defer meta.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(meta.thread_id, &hex);
        try out.print("{s}\tspaces={d}\ttitle=\"{s}\"\n", .{ hex, meta.bindings.len, meta.title });
    } else if (std.mem.eql(u8, sub, "list")) {
        var filter_pid: ?u128 = null;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--project")) {
                const ps = args.next() orelse return UsageError.MissingArgument;
                filter_pid = try resolveProjectId(&v2.projects, ps);
            } else {
                return UsageError.UnknownFlag;
            }
        }
        const list = try v2.runtime.listThreads(allocator, filter_pid);
        defer {
            for (list) |*t| t.deinit(allocator);
            allocator.free(list);
        }
        for (list) |t| {
            var hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(t.thread_id, &hex);
            try out.print("{s}  [{s}]  provider={s}  msgs={d}  tasks={d}  inbox={d}  title=\"{s}\"\n", .{
                hex, @tagName(t.status), t.provider.slug(), t.message_count, t.active_tasks, t.unread_mailbox, t.title,
            });
        }
    } else if (std.mem.eql(u8, sub, "bind")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        const alias = args.next() orelse return UsageError.MissingArgument;
        const acc_str = args.next() orelse "rw";
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const sid = try resolveSpaceId(&v2.spaces, sid_str);
        const access = try parseSpaceAccess(acc_str);
        try v2.runtime.bindSpace(tid, .{
            .space_id = sid,
            .alias = @constCast(alias),
            .access = access,
        });
        try out.print("bound alias={s} access={s}\n", .{ alias, @tagName(access) });
    } else if (std.mem.eql(u8, sub, "unbind")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const sid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const sid = try resolveSpaceId(&v2.spaces, sid_str);
        const removed = try v2.runtime.unbindSpace(tid, sid);
        try out.print("unbound={}\n", .{removed});
    } else if (std.mem.eql(u8, sub, "send")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const prompt = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);

        var bt = try v2.runtime.beginTurn(tid, prompt, .{});
        defer bt.deinit(allocator);
        const ack_text = try std.fmt.allocPrint(allocator, "recorded: {s}", .{prompt});
        defer allocator.free(ack_text);
        var post_cp = try v2.runtime.completeTurn(tid, bt.turn_id, ack_text, &.{}, .{}, null);
        defer post_cp.deinit(allocator);

        var mhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(bt.turn_id, &mhex);
        try out.print("{s}\tcheckpoints={d}\tepoch={d}\n", .{ mhex, post_cp.entries.len, bt.fencing_epoch });
    } else if (std.mem.eql(u8, sub, "history")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const st = try v2.runtime.openThread(tid);
        const msgs = try st.activeChain(allocator);
        defer ondb.thread.store.ThreadStore.freeMessages(allocator, msgs);
        for (msgs) |m| {
            var mhex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(m.msg_id, &mhex);
            try out.print("{s}  [{s}/{s}]  cp={d}  {s}\n", .{
                mhex, @tagName(m.role), @tagName(m.status), m.post_checkpoint.entries.len, m.content,
            });
        }
    } else if (std.mem.eql(u8, sub, "rollback")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const mid_str = args.next() orelse return UsageError.MissingArgument;
        var use_pre = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--pre")) {
                use_pre = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const mid = try parseIdHexOrUsage(mid_str);
        const res = try v2.runtime.rollbackThreadToMessage(tid, mid, .{ .use_pre_checkpoint = use_pre });
        try out.print("rolled_back spaces={d} completed={}\n", .{ res.spaces_rolled_back, res.completed });
    } else if (std.mem.eql(u8, sub, "queue")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const prompt = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const qid = try v2.runtime.enqueueMessage(tid, .follow_up, prompt, null, null);
        var qhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(qid, &qhex);
        try out.print("queued {s}\n", .{qhex});
    } else if (std.mem.eql(u8, sub, "branch")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const mid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const mid = try parseIdHexOrUsage(mid_str);
        const st = try v2.runtime.openThread(tid);
        var found = false;
        var parent_id: ?u128 = null;
        if (st.messages.getPtr(mid)) |msg| {
            found = true;
            parent_id = msg.parent_id;
        } else {
            var cur_pid: ?ondb.core.id.PageId = st.head_page;
            var guard: usize = 0;
            while (cur_pid) |pid| {
                guard += 1;
                if (guard > 65536) break;
                var page = (try st.loadPage(allocator, pid)) orelse break;
                defer page.deinit(allocator);
                for (page.messages) |*m| {
                    if (m.msg_id == mid) {
                        found = true;
                        parent_id = m.parent_id;
                        break;
                    }
                }
                if (found) break;
                cur_pid = page.prev_page;
            }
        }
        if (!found) return error.MessageNotFound;
        try v2.runtime.switchBranch(tid, parent_id, mid);
        try out.print("switched branch\n", .{});
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleCaptainCmd(
    allocator: Allocator,
    io: Io,
    opts: *const GlobalOpts,
    args: *ArgSlice,
    out: anytype,
) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    var v2 = try V2State.open(allocator, io, opts.db_path);
    defer v2.deinit();

    if (std.mem.eql(u8, sub, "spawn")) {
        const parent_str = args.next() orelse return UsageError.MissingArgument;
        const title = args.next() orelse return UsageError.MissingArgument;
        const parent_tid = try resolveThreadId(allocator, &v2.runtime, parent_str);

        var prompt: []const u8 = "";
        var max_tokens: u64 = 0;
        var max_cost_microusd: u64 = 0;
        var join_quorum: u16 = 0;
        var project_local = false;
        var grants: std.ArrayList(ondb.thread.model.SpaceBinding) = .empty;
        defer {
            for (grants.items) |*g| g.deinit(allocator);
            grants.deinit(allocator);
        }
        var deps: std.ArrayList(u128) = .empty;
        defer deps.deinit(allocator);

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--prompt")) {
                prompt = args.next() orelse return UsageError.MissingArgument;
            } else if (std.mem.eql(u8, a, "--tokens")) {
                const v = args.next() orelse return UsageError.MissingArgument;
                max_tokens = std.fmt.parseInt(u64, v, 10) catch return UsageError.InvalidArgument;
            } else if (std.mem.eql(u8, a, "--cents")) {
                const v = args.next() orelse return UsageError.MissingArgument;
                const cents = std.fmt.parseInt(u64, v, 10) catch return UsageError.InvalidArgument;
                max_cost_microusd = std.math.mul(u64, cents, 10_000) catch return UsageError.InvalidArgument;
            } else if (std.mem.eql(u8, a, "--space")) {
                const spec = args.next() orelse return UsageError.MissingArgument;
                try grants.append(allocator, try parseSpaceBindingSpec(allocator, &v2.spaces, spec));
            } else if (std.mem.eql(u8, a, "--depends")) {
                const dep_str = args.next() orelse return UsageError.MissingArgument;
                try deps.append(allocator, try parseIdHexOrUsage(dep_str));
            } else if (std.mem.eql(u8, a, "--quorum")) {
                const v = args.next() orelse return UsageError.MissingArgument;
                join_quorum = std.fmt.parseInt(u16, v, 10) catch return UsageError.InvalidArgument;
            } else if (std.mem.eql(u8, a, "--local")) {
                project_local = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }

        var res = try v2.runtime.spawnSubordinate(allocator, parent_tid, .{
            .title = title,
            .prompt = prompt,
            .grants = grants.items,
            .depends_on = deps.items,
            .join_quorum = join_quorum,
            .project_forks_locally = project_local,
            .budget = .{
                .max_tokens = max_tokens,
                .max_cost_microusd = max_cost_microusd,
            },
        });
        defer res.deinit(allocator);

        var tk_hex: [32]u8 = undefined;
        var ch_hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(res.task_id, &tk_hex);
        _ = ondb.core.id.formatIdHex(res.child_thread_id, &ch_hex);
        try out.print("task={s}\tchild_thread={s}\tstatus={s}\tforks={d}\n", .{
            tk_hex, ch_hex, @tagName(res.status), res.forked_space_ids.len,
        });
    } else if (std.mem.eql(u8, sub, "list")) {
        const parent_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const parent_tid = try resolveThreadId(allocator, &v2.runtime, parent_str);
        const st = try v2.runtime.openThread(parent_tid);
        var it = st.tasks.valueIterator();
        while (it.next()) |t| {
            var tk_hex: [32]u8 = undefined;
            var ch_hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(t.task_id, &tk_hex);
            _ = ondb.core.id.formatIdHex(t.child_thread_id, &ch_hex);
            try out.print("{s}  [{s}]  child={s}  attempt={d}  title=\"{s}\"\n", .{
                tk_hex, @tagName(t.status), ch_hex[0..12], t.attempt, t.title,
            });
        }
    } else if (std.mem.eql(u8, sub, "mailbox")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        var drain = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--drain")) {
                drain = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        if (drain) {
            const items = try v2.runtime.drainMailbox(allocator, tid);
            defer {
                for (items) |*m| m.deinit(allocator);
                allocator.free(items);
            }
            for (items) |m| {
                var ihex: [32]u8 = undefined;
                _ = ondb.core.id.formatIdHex(m.item_id, &ihex);
                try out.print("{s}  [{s}]  {s}\n", .{ ihex, @tagName(m.kind), m.payload });
            }
        } else {
            const st = try v2.runtime.openThread(tid);
            for (st.mailbox_order.items) |iid| {
                if (st.mailbox.get(iid)) |m| {
                    var ihex: [32]u8 = undefined;
                    _ = ondb.core.id.formatIdHex(m.item_id, &ihex);
                    try out.print("{s}  [{s}]  {s}\n", .{ ihex, @tagName(m.kind), m.payload });
                }
            }
        }
    } else if (std.mem.eql(u8, sub, "settle")) {
        const parent_str = args.next() orelse return UsageError.MissingArgument;
        const task_str = args.next() orelse return UsageError.MissingArgument;
        const status_str = args.next() orelse return UsageError.MissingArgument;
        const summary = args.next() orelse "";
        try rejectExtraArgs(args);
        const parent_tid = try resolveThreadId(allocator, &v2.runtime, parent_str);
        const task_id = try parseIdHexOrUsage(task_str);
        const status: ondb.thread.model.TaskStatus = if (std.mem.eql(u8, status_str, "completed"))
            .completed
        else if (std.mem.eql(u8, status_str, "failed"))
            .failed
        else if (std.mem.eql(u8, status_str, "cancelled") or std.mem.eql(u8, status_str, "canceled"))
            .canceled
        else
            return UsageError.InvalidArgument;

        const newly_ready = try v2.runtime.settleTask(parent_tid, task_id, status, summary, null);
        try out.print("settled status={s} newly_ready={d}\n", .{ @tagName(status), newly_ready });
    } else if (std.mem.eql(u8, sub, "cancel-tree")) {
        const root_str = args.next() orelse return UsageError.MissingArgument;
        const reason = args.next();
        try rejectExtraArgs(args);
        const root_tid = try resolveThreadId(allocator, &v2.runtime, root_str);
        const rep = try v2.runtime.cancelTree(root_tid, reason);
        try out.print("canceled threads={d} tasks={d} leases={d}\n", .{
            rep.canceled_threads, rep.canceled_tasks, rep.canceled_leases,
        });
    } else if (std.mem.eql(u8, sub, "land")) {
        const parent_str = args.next() orelse return UsageError.MissingArgument;
        const task_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const parent_tid = try resolveThreadId(allocator, &v2.runtime, parent_str);
        const task_id = try parseIdHexOrUsage(task_str);
        var rep = try v2.runtime.landSubordinateForks(allocator, parent_tid, task_id);
        defer rep.deinit(allocator);
        if (rep.aborted) {
            for (rep.failures) |f| {
                try out.print("aborted reason={s} detail={s}\n", .{ @tagName(f.reason), f.detail orelse "-" });
            }
            return error.LandAborted;
        }
        try out.print("landed forks={d}\n", .{rep.entries.len});
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleTriggerCmd(
    allocator: Allocator,
    io: Io,
    opts: *const GlobalOpts,
    args: *ArgSlice,
    out: anytype,
) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    var v2 = try V2State.open(allocator, io, opts.db_path);
    defer v2.deinit();

    if (std.mem.eql(u8, sub, "add")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const kind_str = args.next() orelse return UsageError.MissingArgument;
        const spec = args.next() orelse return UsageError.MissingArgument;
        const prompt = args.next() orelse "";
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const now = ondb.core.id.nowMs(io);

        var trig = ondb.thread.model.Trigger{
            .trigger_id = ondb.core.id.newUuidV7(io),
            .thread_id = tid,
            .kind = undefined,
            .prompt_template = @constCast(prompt),
            .enabled = true,
            .next_fire_ms = now,
            .placement = .any,
            .created_ms = now,
        };

        if (std.mem.eql(u8, kind_str, "once")) {
            const at_ms: u64 = if (spec.len > 1 and spec[0] == '+') blk: {
                if (std.mem.endsWith(u8, spec, "ms")) {
                    const d = std.fmt.parseInt(u64, spec[1 .. spec.len - 2], 10) catch return UsageError.InvalidArgument;
                    break :blk std.math.add(u64, now, d) catch return UsageError.InvalidArgument;
                } else if (std.mem.endsWith(u8, spec, "s")) {
                    const d = std.fmt.parseInt(u64, spec[1 .. spec.len - 1], 10) catch return UsageError.InvalidArgument;
                    const ms = std.math.mul(u64, d, 1000) catch return UsageError.InvalidArgument;
                    break :blk std.math.add(u64, now, ms) catch return UsageError.InvalidArgument;
                } else {
                    const d = std.fmt.parseInt(u64, spec[1..], 10) catch return UsageError.InvalidArgument;
                    break :blk std.math.add(u64, now, d) catch return UsageError.InvalidArgument;
                }
            } else std.fmt.parseInt(u64, spec, 10) catch return UsageError.InvalidArgument;
            trig.kind = .{ .once = at_ms };
            trig.next_fire_ms = at_ms;
        } else if (std.mem.eql(u8, kind_str, "cron")) {
            _ = ondb.thread.runtime.matchesCron(spec, now / 1000) catch return UsageError.InvalidArgument;
            trig.kind = .{ .cron = @constCast(spec) };
        } else if (std.mem.eql(u8, kind_str, "space_changed")) {
            var sit = std.mem.splitScalar(u8, spec, ':');
            const sid_s = sit.next() orelse return UsageError.InvalidArgument;
            const prefix = sit.next() orelse "";
            const deb_s = sit.next() orelse "500";
            const sid = try resolveSpaceId(&v2.spaces, sid_s);
            const deb = std.fmt.parseInt(u32, deb_s, 10) catch return UsageError.InvalidArgument;
            trig.kind = .{ .space_changed = .{
                .space_id = sid,
                .path_prefix = @constCast(prefix),
                .debounce_ms = deb,
            } };
        } else if (std.mem.eql(u8, kind_str, "mailbox")) {
            trig.kind = .mailbox;
            if (prompt.len == 0 and !std.mem.eql(u8, spec, "-")) {
                trig.prompt_template = @constCast(spec);
            }
        } else if (std.mem.eql(u8, kind_str, "webhook")) {
            trig.kind = .{ .webhook = @constCast(spec) };
        } else {
            return UsageError.InvalidArgument;
        }

        const tr_id = try v2.runtime.registerTrigger(tid, trig);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(tr_id, &hex);
        try out.print("{s}\t{s}\n", .{ hex, kind_str });
    } else if (std.mem.eql(u8, sub, "list")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const list = try v2.runtime.listTriggers(allocator, tid);
        defer {
            for (list) |*t| t.deinit(allocator);
            allocator.free(list);
        }
        for (list) |t| {
            var hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(t.trigger_id, &hex);
            try out.print("{s}  {s:<13}  enabled={}  prompt=\"{s}\"\n", .{
                hex, @tagName(t.kind), t.enabled, t.prompt_template,
            });
        }
    } else if (std.mem.eql(u8, sub, "disable")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        const tr_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const tr_id = try parseIdHexOrUsage(tr_str);
        try v2.runtime.disableTrigger(tid, tr_id);
        try out.print("disabled\n", .{});
    } else if (std.mem.eql(u8, sub, "poll")) {
        const tid_str = args.next() orelse return UsageError.MissingArgument;
        try rejectExtraArgs(args);
        const tid = try resolveThreadId(allocator, &v2.runtime, tid_str);
        const now = ondb.core.id.nowMs(io);
        const due = try v2.runtime.pollDueTriggers(allocator, tid, now);
        defer ondb.thread.runtime.freeDueTriggers(allocator, due);
        for (due) |d| {
            const outcome = try v2.runtime.fireTrigger(tid, d.trigger_id, d.event_token, now);
            var hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(d.trigger_id, &hex);
            try out.print("{s}  outcome={s}  token={s}  prompt=\"{s}\"\n", .{
                hex, @tagName(outcome), d.event_token, d.prompt,
            });
        }
        if (due.len == 0) {
            try out.print("due=0\n", .{});
        }
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleBenchBigRepo(allocator: Allocator, io: Io, args: *ArgSlice, out: anytype) !void {
    const count_opt: ?usize = if (args.next()) |s|
        std.fmt.parseInt(usize, s, 10) catch return UsageError.InvalidArgument
    else
        null;
    const scratch = args.next();
    try ondb.bench.runBenchBigRepo(allocator, io, out, count_opt, scratch);
}

fn handleBenchMany(allocator: Allocator, io: Io, args: *ArgSlice, out: anytype) !void {
    const fcount_opt: ?usize = if (args.next()) |s|
        std.fmt.parseInt(usize, s, 10) catch return UsageError.InvalidArgument
    else
        null;
    const scount_opt: ?usize = if (args.next()) |s|
        std.fmt.parseInt(usize, s, 10) catch return UsageError.InvalidArgument
    else
        null;
    const scratch = args.next();
    try ondb.bench.runBenchMany(allocator, io, out, fcount_opt, scount_opt, scratch);
}

fn handleBenchAgents(allocator: Allocator, io: Io, args: *ArgSlice, out: anytype) !void {
    const subs_opt: ?usize = if (args.next()) |s|
        std.fmt.parseInt(usize, s, 10) catch return UsageError.InvalidArgument
    else
        null;
    const scratch = args.next();
    try ondb.bench.runBenchAgents(allocator, io, out, subs_opt, scratch);
}

fn handleProvidersCmd(io: Io, out: anytype) !void {
    const list = ondb.providers.registry.listProviders(io);
    for (list) |p| {
        try out.print(
            "{s:<14} {s:<12} available={s:<5} native_steer={s:<5} persistent={s}\n",
            .{
                p.id.slug(),
                p.id.displayName(),
                if (p.available) "yes" else "no",
                if (p.capabilities.native_steer) "yes" else "no",
                if (p.capabilities.persistent) "yes" else "no",
            },
        );
    }
}

fn handleInitCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const root = args.next() orelse opts.target_dir;
    const state = try opts.workspaceStatePath(allocator, root);
    defer allocator.free(state);
    try ensureDir0700(io, state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
    defer ws.deinit();
    const bid = try ws.ingestDisk();
    var hex: [32]u8 = undefined;
    _ = ondb.core.id.formatIdHex(ws.history.history_id, &hex);
    try out.print("initialized 0ndb history={s} ingested={}\n", .{ hex, bid != null });
}

fn handleAdoptCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const path = args.next() orelse opts.target_dir;
    const title = args.next() orelse blk: {
        const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
        break :blk if (base.len > 0) base else "workspace";
    };
    const wt_state = try std.fmt.allocPrint(allocator, "{s}/.0ndb/worktrees", .{opts.target_dir});
    defer allocator.free(wt_state);
    const wt_checkouts = try std.fmt.allocPrint(allocator, "{s}/checkouts", .{wt_state});
    defer allocator.free(wt_checkouts);
    try ensureDir0700(io, wt_state);
    try ensureDir0700(io, wt_checkouts);
    var wts = try ondb.fs.worktrees.Worktrees.open(allocator, io, wt_state, wt_checkouts);
    defer wts.deinit();
    var info = try wts.adopt(path, title);
    defer info.deinit(allocator);
    var hex: [32]u8 = undefined;
    _ = ondb.core.id.formatIdHex(info.id, &hex);
    try out.print("adopted id={s} title=\"{s}\" path={s}\n", .{ hex, info.title, info.path });
}

fn handleStatusCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const root = args.next() orelse opts.target_dir;
    const state = try opts.workspaceStatePath(allocator, root);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
    defer ws.deinit();
    const bid = try ws.ingestDisk();
    try out.print(
        "batches={d} heads={d} synced_new={}\n",
        .{ ws.batch_log.count(), ws.history.dag.heads.slice().len, bid != null },
    );
}

fn handleWatchCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const root = args.next() orelse opts.target_dir;
    const state = try opts.workspaceStatePath(allocator, root);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
    defer ws.deinit();
    try ws.attachWatcher();
    installStopSignalHandlers();
    try out.print("watching {s}\n", .{root});
    try out.flush();
    while (!g_stop_requested.load(.acquire)) {
        const step = try ws.watchStep(250, "watch");
        if (step.batch_id) |bid| {
            var ahex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(bid.actor, &ahex);
            try out.print("committed {s}@{d}\n", .{ ahex[0..8], bid.ts });
            try out.flush();
        }
    }
}

fn handleBlameCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const path = args.next() orelse return UsageError.MissingArgument;
    const root = args.next() orelse opts.target_dir;
    const state = try opts.workspaceStatePath(allocator, root);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
    defer ws.deinit();
    var lines = try ws.history.blameFile(allocator, path) orelse {
        try out.print("file not tracked: {s}\n", .{path});
        return;
    };
    defer {
        for (lines.items) |*l| l.deinit(allocator);
        lines.deinit(allocator);
    }
    for (lines.items) |l| {
        var ahex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(l.op.actor, &ahex);
        try out.print("{d:>4} {s}@{d}: {s}\n", .{ l.line_no, ahex[0..8], l.op.ts, l.text });
    }
}

fn handleLogCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const limit: usize = if (args.next()) |ls|
        std.fmt.parseInt(usize, ls, 10) catch return UsageError.InvalidArgument
    else
        30;
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();
    const entries = try ondb.fs.timeline.listEntries(allocator, &ws, null, limit);
    defer ondb.fs.timeline.freeTimelineEntries(allocator, entries);
    for (entries) |e| {
        var bbuf: [48]u8 = undefined;
        try out.print("{s}  +{d}/-{d}  files={d}\n", .{
            formatBatchId(e.batch_id, &bbuf), e.total_added, e.total_removed, e.files.len,
        });
        for (e.files) |fc| {
            try out.print("    {s:<8} {s} (+{d}/-{d})\n", .{ @tagName(fc.kind), fc.path, fc.added_lines, fc.removed_lines });
        }
    }
}

fn handleDiffCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();
    const entries = try ondb.fs.timeline.listEntries(allocator, &ws, null, 200);
    defer ondb.fs.timeline.freeTimelineEntries(allocator, entries);
    if (entries.len == 0) return;

    var bids: std.ArrayList(ondb.core.id.BatchId) = .empty;
    defer bids.deinit(allocator);
    while (args.next()) |bs| {
        try bids.append(allocator, try parseBatchIdFromEntries(bs, entries));
    }
    if (bids.items.len == 0) {
        try bids.append(allocator, entries[0].batch_id);
    }
    const diff_bytes = try ondb.fs.timeline.unifiedDiff(allocator, &ws, bids.items);
    defer allocator.free(diff_bytes);
    try out.writeAll(diff_bytes);
}

fn handleChangesCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, out: anytype) !void {
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();
    _ = try ws.ingestDisk();
    const fchanges = try ondb.fs.timeline.foreignChanges(allocator, &ws, null, 0);
    defer ondb.fs.timeline.freeForeignChanges(allocator, fchanges);
    const xml = try ondb.fs.timeline.formatWorkspaceChangesXml(allocator, fchanges);
    defer allocator.free(xml);
    try out.writeAll(xml);
    if (xml.len > 0 and xml[xml.len - 1] != '\n') try out.writeAll("\n");
}

fn handleScopesCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, out: anytype) !void {
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();
    for (ws.scopes.items) |sc| {
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(sc.scope_id, &hex);
        try out.print("{s}  [{s}]  batches={d}  active={}  label=\"{s}\"\n", .{
            hex[0..12], @tagName(sc.kind), sc.batches.items.len, sc.ended_ms == null, sc.label,
        });
    }
}

fn handleRevertCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const target_str = args.next() orelse return UsageError.MissingArgument;
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();

    var ver = ondb.core.version.Version.ROOT;
    defer ver.deinit(allocator);
    if (!std.mem.eql(u8, target_str, "root")) {
        const entries = try ondb.fs.timeline.listEntries(allocator, &ws, null, 200);
        defer ondb.fs.timeline.freeTimelineEntries(allocator, entries);
        const bid = try parseBatchIdFromEntries(target_str, entries);
        try ver.insert(allocator, bid);
    }
    const ok = try ws.rollbackToVersion(&ver);
    try out.print("reverted={}\n", .{ok});
}

fn handleWorktreeCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    const wt_state = try std.fmt.allocPrint(allocator, "{s}/.0ndb/worktrees", .{opts.target_dir});
    defer allocator.free(wt_state);
    const wt_checkouts = try std.fmt.allocPrint(allocator, "{s}/checkouts", .{wt_state});
    defer allocator.free(wt_checkouts);
    try ensureDir0700(io, wt_state);
    try ensureDir0700(io, wt_checkouts);
    var wts = try ondb.fs.worktrees.Worktrees.open(allocator, io, wt_state, wt_checkouts);
    defer wts.deinit();

    if (std.mem.eql(u8, sub, "list")) {
        for (wts.list()) |wt| {
            var hex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(wt.id, &hex);
            try out.print("{s}  title=\"{s}\"  path={s}\n", .{ hex, wt.title, wt.path });
        }
    } else if (std.mem.eql(u8, sub, "adopt")) {
        const path = args.next() orelse return UsageError.MissingArgument;
        const title = args.next() orelse std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
        var info = try wts.adopt(path, title);
        defer info.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(info.id, &hex);
        try out.print("{s}\t{s}\t{s}\n", .{ hex, info.title, info.path });
    } else if (std.mem.eql(u8, sub, "scratch")) {
        const title = args.next() orelse "scratch";
        var info = try wts.scratch(title);
        defer info.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(info.id, &hex);
        try out.print("{s}\t{s}\t{s}\n", .{ hex, info.title, info.path });
    } else if (std.mem.eql(u8, sub, "fork")) {
        const id_str = args.next() orelse return UsageError.MissingArgument;
        const title = args.next() orelse return UsageError.MissingArgument;
        const wt_id = try parseIdHexOrUsage(id_str);
        var info = try wts.fork(wt_id, title, null, null);
        defer info.deinit(allocator);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(info.id, &hex);
        try out.print("{s}\t{s}\t{s}\n", .{ hex, info.title, info.path });
    } else if (std.mem.eql(u8, sub, "sync")) {
        const id_str = args.next() orelse return UsageError.MissingArgument;
        const wt_id = try parseIdHexOrUsage(id_str);
        var rep = try wts.syncFork(wt_id);
        defer rep.deinit(allocator);
        try out.print("synced brought={d} conflicts={d}\n", .{ rep.brought, rep.conflicts.len });
    } else if (std.mem.eql(u8, sub, "land")) {
        const id_str = args.next() orelse return UsageError.MissingArgument;
        const wt_id = try parseIdHexOrUsage(id_str);
        var rep = try wts.landFork(wt_id);
        defer rep.deinit(allocator);
        try out.print("landed={d}\n", .{rep.landed});
    } else if (std.mem.eql(u8, sub, "conflicts")) {
        const id_str = args.next() orelse return UsageError.MissingArgument;
        const wt_id = try parseIdHexOrUsage(id_str);
        const list = try wts.conflicts(wt_id);
        defer {
            for (list) |*c| c.deinit(allocator);
            allocator.free(list);
        }
        for (list) |c| {
            try out.print("{s}\t{s}\n", .{ @tagName(c.kind), c.path });
        }
    } else if (std.mem.eql(u8, sub, "remove")) {
        const id_str = args.next() orelse return UsageError.MissingArgument;
        const wt_id = try parseIdHexOrUsage(id_str);
        try wts.remove(wt_id, true, false);
        try out.print("removed\n", .{});
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleRunCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const prov_slug = args.next() orelse return UsageError.MissingArgument;
    const prompt = args.next() orelse return UsageError.MissingArgument;
    const prov = ondb.providers.interface.ProviderId.fromSlug(prov_slug) orelse return UsageError.InvalidArgument;
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();
    var eng = try ondb.session.engine.SessionEngine.open(allocator, io, &ws, state);
    defer eng.deinit();
    const tid = try eng.createThread("cli-run", prov, null);
    const mid = try eng.executePrompt(tid, prompt, null, null, ondb.session.engine.DEFAULT_FACTORY, null);
    if (eng.journal.messages.get(mid)) |m| {
        try out.print("{s}\n", .{m.content});
    }
}

fn parseHostPort(spec: []const u8) !struct { ip: [4]u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return UsageError.InvalidArgument;
    const host = spec[0..colon];
    const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return UsageError.InvalidArgument;
    if (std.mem.eql(u8, host, "localhost")) {
        return .{ .ip = .{ 127, 0, 0, 1 }, .port = port };
    }
    var ip: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    for (0..4) |i| {
        const part = it.next() orelse return UsageError.InvalidArgument;
        ip[i] = std.fmt.parseInt(u8, part, 10) catch return UsageError.InvalidArgument;
    }
    if (it.next() != null) return UsageError.InvalidArgument;
    return .{ .ip = ip, .port = port };
}

fn handleSyncCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const sub = args.next() orelse return UsageError.MissingArgument;
    const endpoint = args.next() orelse return UsageError.MissingArgument;
    const secret_str = args.next() orelse "0ndb-default-relay-secret";
    const hp = try parseHostPort(endpoint);
    const secret = ondb.store.crypto.hashBytes(secret_str);
    const master_key = ondb.store.crypto.deriveTopicKey(secret, ondb.store.crypto.hashBytes("0ndb-cli-master"));

    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();

    var client = try ondb.sync.client.SyncClient.connect(allocator, io, hp.ip, hp.port, master_key, secret);
    defer client.deinit();

    if (std.mem.eql(u8, sub, "push")) {
        _ = try ws.ingestDisk();
        const pushed = try client.pushWorkspace(&ws);
        try out.print("pushed batches={d}\n", .{pushed});
    } else if (std.mem.eql(u8, sub, "pull")) {
        const pulled = try client.pullWorkspace(&ws, 0);
        try out.print("pulled applied={d} last_seq={d}\n", .{ pulled.applied, pulled.last_seq });
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handlePrCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const sub = args.next() orelse "info";
    if (std.mem.eql(u8, sub, "info")) {
        if (try ondb.fs.git_remote.originRemoteUrl(allocator, io, opts.target_dir)) |rem_val| {
            var rem = rem_val;
            defer rem.deinit(allocator);
            const web = try rem.webUrl(allocator);
            defer allocator.free(web);
            const slug = try rem.slug(allocator);
            defer allocator.free(slug);
            try out.print("slug={s}\nweb={s}\n", .{ slug, web });
        } else {
            try out.print("no git origin remote found\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "open")) {
        try ondb.fs.git_remote.openPrInBrowser(allocator, io, opts.target_dir);
        try out.print("opened pr in browser\n", .{});
    } else if (std.mem.eql(u8, sub, "create")) {
        const title = args.next() orelse return UsageError.MissingArgument;
        var body: []const u8 = "";
        var base: ?[]const u8 = null;
        var draft = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--body")) {
                body = args.next() orelse return UsageError.MissingArgument;
            } else if (std.mem.eql(u8, a, "--base")) {
                base = args.next() orelse return UsageError.MissingArgument;
            } else if (std.mem.eql(u8, a, "--draft")) {
                draft = true;
            } else {
                return UsageError.UnknownFlag;
            }
        }
        var info = try ondb.fs.git_remote.createGitHubPr(allocator, io, opts.target_dir, title, body, base, draft);
        defer info.deinit(allocator);
        try out.print("pr #{d} {s}\n", .{ info.number, info.url });
    } else {
        return UsageError.UnknownSubcommand;
    }
}

fn handleVerifyCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, out: anytype) !void {
    const state = try opts.workspaceStatePath(allocator, null);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, opts.target_dir, state, null);
    defer ws.deinit();
    var hex: [32]u8 = undefined;
    _ = ondb.core.id.formatIdHex(ws.history.history_id, &hex);
    try out.print("verify ok history={s} batches={d} heads={d} generation={d}\n", .{
        hex, ws.batch_log.count(), ws.history.dag.heads.slice().len, ws.manifest.generation,
    });
}

fn handleSessionsCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const root = args.next() orelse opts.target_dir;
    const state = try opts.workspaceStatePath(allocator, root);
    defer allocator.free(state);
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
    defer ws.deinit();
    var eng = try ondb.session.engine.SessionEngine.open(allocator, io, &ws, state);
    defer eng.deinit();
    const sums = try eng.listSessions(allocator);
    defer {
        for (sums) |*s| s.deinit(allocator);
        allocator.free(sums);
    }
    for (sums) |s| {
        var thex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(s.thread_id, &thex);
        try out.print(
            "{s} [{s}] provider={s} msgs={d} queued={d} title=\"{s}\"\n",
            .{ thex, @tagName(s.status), s.provider.slug(), s.message_count, s.queued_count, s.title },
        );
    }
}

fn handleRelayCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    const port_str = args.next() orelse "9090";
    const port = std.fmt.parseInt(u16, port_str, 10) catch return UsageError.InvalidArgument;
    const dir_arg = args.next();
    const secret_str = args.next() orelse "0ndb-default-relay-secret";

    var default_dir: ?[]u8 = null;
    defer if (default_dir) |d| allocator.free(d);
    const dir = if (dir_arg) |da| da else blk: {
        default_dir = try std.fmt.allocPrint(allocator, "{s}/relay", .{opts.db_path});
        break :blk default_dir.?;
    };
    try ensureDir0700(io, dir);

    const secret = ondb.store.crypto.hashBytes(secret_str);
    var server = try ondb.sync.relay.RelayServer.start(
        allocator,
        io,
        dir,
        .{ 127, 0, 0, 1 },
        port,
        secret,
        true,
    );
    defer server.deinit();

    installStopSignalHandlers();
    g_relay_wake_fd.store(server.wake_fd, .release);
    defer g_relay_wake_fd.store(-1, .release);

    try out.print("0ndb relay listening on 127.0.0.1:{d} state={s}\n", .{ server.port, dir });
    try out.flush();

    while (!g_stop_requested.load(.acquire) and server.running.load(.acquire)) {
        _ = try server.step(100);
    }
    server.stop();
    try out.print("0ndb relay stopped cleanly\n", .{});
}

fn handlePlaygroundCmd(allocator: Allocator, io: Io, opts: *const GlobalOpts, args: *ArgSlice, out: anytype) !void {
    var port: u16 = 4321;
    var port_set = false;
    var dir_arg: ?[]const u8 = null;
    var extra_hosts: std.ArrayList([]const u8) = .empty;
    defer extra_hosts.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--allow-host")) {
            const val = args.next() orelse return UsageError.MissingArgument;
            const trimmed = std.mem.trim(u8, val, " \t");
            if (trimmed.len == 0) return UsageError.InvalidArgument;
            try extra_hosts.append(allocator, trimmed);
        } else if (std.mem.startsWith(u8, arg, "--allow-host=")) {
            const trimmed = std.mem.trim(u8, arg["--allow-host=".len..], " \t");
            if (trimmed.len == 0) return UsageError.InvalidArgument;
            try extra_hosts.append(allocator, trimmed);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return UsageError.MissingArgument;
            port = std.fmt.parseInt(u16, val, 10) catch return UsageError.InvalidArgument;
            port_set = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            dir_arg = args.next() orelse return UsageError.MissingArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return UsageError.InvalidArgument;
        } else if (!port_set) {
            port = std.fmt.parseInt(u16, arg, 10) catch return UsageError.InvalidArgument;
            port_set = true;
        } else if (dir_arg == null) {
            dir_arg = arg;
        } else {
            return UsageError.InvalidArgument;
        }
    }

    var default_dir: ?[]u8 = null;
    defer if (default_dir) |d| allocator.free(d);
    const dir = if (dir_arg) |da| da else blk: {
        default_dir = try opts.defaultPlaygroundDir(allocator);
        break :blk default_dir.?;
    };
    try ensureDir0700(io, dir);

    const env_hosts = try ondb.playground.server.resolveAllowedHosts(allocator, io);
    defer ondb.playground.server.freeAllowedHosts(allocator, env_hosts);

    var all_hosts: std.ArrayList([]const u8) = .empty;
    defer all_hosts.deinit(allocator);
    for (env_hosts) |h| try all_hosts.append(allocator, h);
    for (extra_hosts.items) |h| try all_hosts.append(allocator, h);

    var srv = try ondb.playground.server.PlaygroundServer.startWithConfig(allocator, io, dir, port, .{
        .default_access = ondb.playground.server.resolveDefaultAccess(allocator, io),
        .v2_root = if (opts.db_explicit) opts.db_path else null,
        .allowed_hosts = all_hosts.items,
    });
    defer srv.deinit();

    installStopSignalHandlers();
    g_playground_running.store(&srv.running, .release);
    g_playground_listen_fd.store(srv.listen_fd, .release);
    defer {
        g_playground_listen_fd.store(-1, .release);
        g_playground_running.store(null, .release);
    }

    try out.print(
        "0ndb playground running at http://127.0.0.1:{d} (workspace={s}, relay=127.0.0.1:{d})\n",
        .{ srv.http_port, dir, srv.relay.port },
    );
    try out.flush();
    try srv.serve();
    try out.print("0ndb playground stopped cleanly\n", .{});
}

fn printUsage(out: anytype) !void {
    try out.print(
        "{s} - zero-copy local-first CRDT, Space, Thread & multi-agent engine\n\n" ++
            "Global Flags:\n" ++
            "  -C, --dir <dir>                      Target working directory (auto-discovers .0ndb upward)\n" ++
            "  --db <path>                          Override V2 state root (or set ONDB_DB; default <dir>/.0ndb/v2 or ~/.0ndb/v2)\n" ++
            "  -h, --help                           Show this help\n" ++
            "  -V, --version                        Show version\n\n" ++
            "V2 Space Commands:\n" ++
            "  space create-virtual <name>\n" ++
            "  space adopt <path> [--name <name>] [--kind dir|git_worktree]\n" ++
            "  space list\n" ++
            "  space read <space_id> <path>\n" ++
            "  space write <space_id> <path> <content|@file|--file path>\n" ++
            "  space ls <space_id> [dir]\n" ++
            "  space search <space_id> <query>\n" ++
            "  space meta-get|meta-set|meta-ls <space_id> ...\n" ++
            "  space fork <space_id> <new_name> [--local]\n" ++
            "  space sync|land <space_id>\n" ++
            "  space log <space_id> [limit] | diff <space_id> [batch_id]\n" ++
            "  space compact|hibernate|remove <space_id>\n\n" ++
            "V2 Project Commands:\n" ++
            "  project create <name> [--instructions <t>] [--provider <slug>]\n" ++
            "  project list\n" ++
            "  project add-space <project_id> <space_id> [role]\n" ++
            "  project remove-space <project_id> <space_id>\n" ++
            "  project fork <project_id> <name> [--local] | sync|land <project_id>\n\n" ++
            "V2 Thread, Captain & Trigger Commands:\n" ++
            "  thread create [--title <t>] [--project <pid>] [--space <sid>:<alias>:<ro|rw|fork>]...\n" ++
            "  thread list [--project <pid>]\n" ++
            "  thread bind <tid> <sid> <alias> [ro|rw|fork] | unbind <tid> <sid>\n" ++
            "  thread send <tid> <prompt> | history <tid> | rollback <tid> <mid> [--pre]\n" ++
            "  captain|task spawn <parent_tid> <title> [--prompt <p>] [--tokens <n>] [--cents <n>] [--space ...]\n" ++
            "  captain|task list <parent_tid> | mailbox <tid> [--drain] | land <parent_tid> <task_id>\n" ++
            "  captain|task settle <parent_tid> <task_id> <completed|failed|cancelled> [summary]\n" ++
            "  captain|task cancel-tree <root_tid> [reason]\n" ++
            "  trigger add <tid> <once|cron|space_changed|mailbox|webhook> <spec> [prompt]\n" ++
            "  trigger list <tid> | disable <tid> <trigger_id> | poll <tid>\n\n" ++
            "Hardware Scale Benchmarks:\n" ++
            "  bench-bigrepo [file_count] [scratch_dir]\n" ++
            "  bench-many [file_count] [space_count] [scratch_dir]\n" ++
            "  bench-agents [subordinates] [scratch_dir]\n" ++
            "  bench                                Run core microbenchmarks\n\n" ++
            "Workspace & Daemon Commands:\n" ++
            "  init|adopt|status|watch|blame|log|diff|changes|scopes|revert|verify\n" ++
            "  worktree <list|adopt|scratch|fork|sync|land|conflicts|remove>\n" ++
            "  run <provider> <prompt> | providers | sessions | sync <push|pull> <host:port> [secret]\n" ++
            "  pr <info|create|open> | relay [port] [dir] [secret] | playground [port] [dir] [--allow-host <host>]\n",
        .{VERSION_STR},
    );
}

fn benchResolve(_: *const anyopaque, _: ondb.core.id.InsertionKey) ?[]const u8 {
    return "abcdefg\n";
}

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    return @intCast(@max(ts.nanoseconds, 0));
}

fn runBench(allocator: Allocator, io: Io, out: anytype) !void {
    const actor: ondb.core.id.ActorId = 1;
    var text = ondb.core.text.Text{};
    defer text.deinit(allocator);
    var dummy: u8 = 0;
    const res = ondb.core.text.ContentResolver{ .ptr = &dummy, .resolveFn = benchResolve };

    const t0 = nowNs(io);
    const edits: usize = 5000;
    var ts: u64 = 1;
    for (0..edits) |i| {
        const vis = text.visibleLen();
        const pos = if (vis == 0) 0 else (@as(u64, @intCast(i)) * 7) % vis;
        const op_id = ondb.core.id.OpId.init(ts, actor);
        try text.apply(allocator, op_id, ondb.core.text.View.EVERYTHING, &.{.{ .at = pos, .del = 0, .ins = 8 }}, "abcdefg\n", res);
        ts += 1;
    }
    const t1 = nowNs(io);

    const s0 = nowNs(io);
    var share_iters: usize = 0;
    var lc_acc: usize = 0;
    while (share_iters < 10000) : (share_iters += 1) {
        var clone = text.share();
        lc_acc += clone.lineCount();
        clone.deinit(allocator);
    }
    const s1 = nowNs(io);
    std.mem.doNotOptimizeAway(lc_acc);

    const rendered = (try text.read(allocator, res)).?;
    defer allocator.free(rendered);

    var old_100k: std.ArrayList(u8) = .empty;
    defer old_100k.deinit(allocator);
    var new_100k: std.ArrayList(u8) = .empty;
    defer new_100k.deinit(allocator);
    for (0..100000) |li| {
        try old_100k.print(allocator, "fn item_{d:0>6}(x: u64) u64 {{ return x + {d}; }}\n", .{ li, li });
        if (li == 17) {
            try new_100k.print(allocator, "fn item_{d:0>6}(x: u64) u64 {{ return x + 9999999; }}\n", .{li});
        } else if (li == 99980) {
            try new_100k.print(allocator, "fn item_{d:0>6}(x: u64) u64 {{ return x + 8888888; }}\n", .{li});
        } else {
            try new_100k.print(allocator, "fn item_{d:0>6}(x: u64) u64 {{ return x + {d}; }}\n", .{ li, li });
        }
    }
    const d0 = nowNs(io);
    var diff_100k = try ondb.core.diff.diffBytes(allocator, old_100k.items, new_100k.items);
    defer diff_100k.deinit(allocator);
    const d1 = nowNs(io);

    var big_hist = try ondb.core.history.History.init(allocator, 999);
    defer big_hist.deinit();
    var c_ops = [_]ondb.core.op.Op{.{ .create_file = .{
        .parent = ondb.core.id.InodeId.ROOT,
        .name = try allocator.dupe(u8, "big.zig"),
        .mode = .regular,
        .line_ending = .lf,
        .content = .{ .text_inline = try allocator.dupe(u8, old_100k.items) },
    } }};
    var b0 = ondb.core.op.Batch{
        .header = .{ .actor = actor, .start = 1, .end = 1, .parents = ondb.core.version.Version.ROOT, .wall_ms = 1 },
        .ops = &c_ops,
        .blobs = &.{},
    };
    defer {
        for (&c_ops) |*o| o.deinit(allocator);
    }
    _ = try big_hist.integrate(&b0);
    const big_iid = (try big_hist.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "big.zig")).?;
    for (0..100) |k| {
        var heads = try big_hist.headsClone();
        var sp = [_]ondb.core.diff.Splice{.{ .at = @intCast(k * 45000), .del = 0, .ins = 16 }};
        var eops = [_]ondb.core.op.Op{.{ .edit_text = .{
            .inode = big_iid,
            .text = try allocator.dupe(u8, "const p_ln = 1;\n"),
            .splices = &sp,
        } }};
        var eb = ondb.core.op.Batch{
            .header = .{ .actor = actor, .start = @intCast(k + 2), .end = @intCast(k + 2), .parents = heads, .wall_ms = @intCast(k + 2) },
            .ops = &eops,
            .blobs = &.{},
        };
        defer {
            heads.deinit(allocator);
            allocator.free(eops[0].edit_text.text);
        }
        _ = try big_hist.integrate(&eb);
    }
    const r0 = nowNs(io);
    const slice_90k = (try big_hist.readFileLines(allocator, "big.zig", 90000, 50)).?;
    const r1 = nowNs(io);
    defer allocator.free(slice_90k);

    const key = ondb.store.crypto.deriveTopicKey(@splat(7), @splat(3));
    const c0 = nowNs(io);
    var total_bytes: usize = 0;
    for (0..1000) |_| {
        const env = try ondb.store.crypto.sealRandom(allocator, io, key, "aad", rendered);
        defer allocator.free(env);
        const plain = try ondb.store.crypto.open(allocator, key, "aad", env);
        defer allocator.free(plain);
        total_bytes += plain.len;
    }
    const c1 = nowNs(io);

    try out.print(
        "bench crdt: {d} random edits -> {d} bytes ({d} frags, {d} lines) in {d} us\n",
        .{ edits, rendered.len, text.fragmentCount(), text.lineCount(), (t1 -| t0) / 1000 },
    );
    try out.print(
        "bench cow: 10000 share()+lineCount()+deinit() in {d} us ({d} ns/op)\n",
        .{ (s1 -| s0) / 1000, (s1 -| s0) / 10000 },
    );
    try out.print(
        "bench diff: 100000 lines ({d} KB) -> {d} splices in {d} us\n",
        .{ old_100k.items.len / 1024, diff_100k.splices.items.len, (d1 -| d0) / 1000 },
    );
    try out.print(
        "bench range: readFileLines(line 90000, 50 lines) of {d}-line file -> {d} bytes in {d} us\n",
        .{ big_hist.tree.get(big_iid).?.fileConstPtr().?.text.lineCount(), slice_90k.len, (r1 -| r0) / 1000 },
    );
    try out.print(
        "bench aegis128l: 1000 seal+open ({d} MB roundtrip) in {d} us\n",
        .{ total_bytes / (1024 * 1024), (c1 -| c0) / 1000 },
    );
}
