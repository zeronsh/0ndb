const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("core/id.zig");
const crypto = @import("store/crypto.zig");
const pool = @import("fs/pool.zig");
const watch = @import("fs/watch.zig");
const timeline = @import("fs/timeline.zig");
const projection = @import("fs/projection.zig");
const space_mod = @import("space/space.zig");
const manager_mod = @import("space/manager.zig");
const project_mod = @import("project/project.zig");
const wire = @import("sync/wire.zig");
const keyring_mod = @import("sync/keyring.zig");
const lease_mod = @import("sync/lease.zig");
const thread_model = @import("thread/model.zig");
const thread_store = @import("thread/store.zig");
const thread_runtime = @import("thread/runtime.zig");

pub const ProcMetrics = struct {
    vm_rss_kb: u64 = 0,
    vm_hwm_kb: u64 = 0,
    threads: u64 = 0,
    open_fds: usize = 0,
};

pub const ScratchDir = struct {
    allocator: Allocator,
    io: Io,
    path: []u8,
    owned: bool,

    pub fn init(allocator: Allocator, io: Io, override: ?[]const u8, prefix: []const u8) !ScratchDir {
        if (override) |p| {
            try Io.Dir.cwd().createDirPath(io, p);
            return .{
                .allocator = allocator,
                .io = io,
                .path = try allocator.dupe(u8, p),
                .owned = false,
            };
        }
        const uid = id.newUuidV7(io);
        var hex: [32]u8 = undefined;
        _ = id.formatIdHex(uid, &hex);
        const p = try std.fmt.allocPrint(allocator, "/tmp/0ndb-{s}-{s}", .{ prefix, hex[0..12] });
        errdefer allocator.free(p);
        try Io.Dir.cwd().createDirPath(io, p);
        return .{
            .allocator = allocator,
            .io = io,
            .path = p,
            .owned = true,
        };
    }

    pub fn deinit(self: *ScratchDir) void {
        if (self.owned) {
            Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        }
        self.allocator.free(self.path);
    }
};

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    return @intCast(@max(ts.nanoseconds, 0));
}

fn msFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn usFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000.0;
}

fn mbFromKb(kb: u64) f64 {
    return @as(f64, @floatFromInt(kb)) / 1024.0;
}

fn mbFromBytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn assertCond(cond: bool, msg: []const u8) !void {
    if (!cond) {
        std.debug.print("BENCH INVARIANT FAILED: {s}\n", .{msg});
        return error.BenchmarkInvariantFailed;
    }
}

fn parseStatusKb(line: []const u8) u64 {
    var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
    _ = it.next();
    const num_str = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num_str, 10) catch 0;
}

pub fn readProcMetrics(_: Allocator, io: Io) ProcMetrics {
    var m = ProcMetrics{};
    if (Io.Dir.cwd().openFile(io, "/proc/self/status", .{})) |f| {
        defer f.close(io);
        var buf: [16384]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const rc = std.os.linux.read(f.handle, buf[total..].ptr, buf.len - total);
            const e = std.os.linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS or rc == 0) break;
            total += rc;
        }
        var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "VmRSS:")) {
                m.vm_rss_kb = parseStatusKb(line);
            } else if (std.mem.startsWith(u8, line, "VmHWM:")) {
                m.vm_hwm_kb = parseStatusKb(line);
            } else if (std.mem.startsWith(u8, line, "Threads:")) {
                m.threads = parseStatusKb(line);
            }
        }
    } else |_| {}

    if (Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        var count: usize = 0;
        while (it.next(io) catch null) |_| {
            count += 1;
        }
        m.open_fds = count -| 1;
    } else |_| {}

    return m;
}

fn dirDiskBytesRec(io: Io, dir: Io.Dir, skip_git: bool) u64 {
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (skip_git and std.mem.eql(u8, entry.name, ".git")) continue;
        switch (entry.kind) {
            .directory => {
                if (dir.openDir(io, entry.name, .{ .iterate = true })) |sub_val| {
                    var sub = sub_val;
                    defer sub.close(io);
                    total += dirDiskBytesRec(io, sub, skip_git);
                } else |_| {}
            },
            .file, .sym_link => {
                if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| {
                    total += st.size;
                } else |_| {}
            },
            else => {},
        }
    }
    return total;
}

pub fn dirDiskBytes(io: Io, path: []const u8, skip_git: bool) u64 {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    return dirDiskBytesRec(io, dir, skip_git);
}

fn runCmd(allocator: Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !void {
    const res = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("command failed (code={d}): {s}\n{s}\n", .{ code, argv[0], res.stderr });
                return error.SubprocessFailed;
            }
        },
        else => return error.SubprocessFailed,
    }
}

fn formatRepoRelPath(buf: []u8, idx: usize) ![]const u8 {
    const pkg_idx = idx / 200;
    const sub_idx = (idx / 20) % 10;
    const file_idx = idx % 20;
    return try std.fmt.bufPrint(buf, "pkg_{d:0>3}/sub_{d:0>2}/file_{d:0>2}.txt", .{ pkg_idx, sub_idx, file_idx });
}

fn generateGitRepo(allocator: Allocator, io: Io, repo_dir: []const u8, file_count: usize) !void {
    try Io.Dir.cwd().createDirPath(io, repo_dir);
    var root = try Io.Dir.cwd().openDir(io, repo_dir, .{ .iterate = true });
    defer root.close(io);

    {
        const gf = try root.createFile(io, ".gitignore", .{ .truncate = true });
        defer gf.close(io);
        try gf.writeStreamingAll(io, "target/\nnode_modules/\nbuild/\n");
    }

    var content_buf: [1024]u8 = undefined;
    var dir_buf: [64]u8 = undefined;
    var file_buf: [64]u8 = undefined;

    const total_subs = (file_count + 19) / 20;
    for (0..total_subs) |s| {
        const pkg_idx = s / 10;
        const sub_idx = s % 10;
        const rel_dir = try std.fmt.bufPrint(&dir_buf, "pkg_{d:0>3}/sub_{d:0>2}", .{ pkg_idx, sub_idx });
        try root.createDirPath(io, rel_dir);
        var sub_dir = try root.openDir(io, rel_dir, .{});
        defer sub_dir.close(io);

        const start_i = s * 20;
        const end_i = @min(start_i + 20, file_count);
        for (start_i..end_i) |i| {
            const file_idx = i % 20;
            const fname = try std.fmt.bufPrint(&file_buf, "file_{d:0>2}.txt", .{file_idx});
            const body = try std.fmt.bufPrint(
                &content_buf,
                "module pkg_{d:0>3}_sub_{d:0>2}_f{d:0>2}\n" ++
                    "const FILE_INDEX: usize = {d};\n" ++
                    "const CHECKSUM_TAG: u64 = {d};\n" ++
                    "pub fn compute_{d}(a: u64, b: u64) u64 {{\n" ++
                    "    const base = a +% b +% {d};\n" ++
                    "    const mixed = (base ^ 0x9e3779b97f4a7c15) *% 0xbf58476d1ce4e5b9;\n" ++
                    "    return mixed ^ (mixed >> 31);\n" ++
                    "}}\n" ++
                    "pub const DESCRIPTION = \"synthetic-realistic-source-unit-{d:0>6}-end\";\n",
                .{ pkg_idx, sub_idx, file_idx, i, (i + 1) * 2654435761, i, i + 7, i },
            );
            const f = try sub_dir.createFile(io, fname, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, body);
        }
    }

    const cmds = [_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "gc.auto", "0" },
        &.{ "git", "config", "user.email", "bench@0ndb.local" },
        &.{ "git", "config", "user.name", "0ndb-bench" },
        &.{ "git", "add", "." },
        &.{ "git", "-c", "gc.auto=0", "commit", "-q", "-m", "initial bench repo" },
        &.{ "git", "gc", "--quiet" },
    };
    for (cmds) |argv| {
        try runCmd(allocator, io, repo_dir, argv);
    }
}

fn drainWatcherEvents(allocator: Allocator, io: Io, w: *watch.DaemonWatcher) !void {
    var eb = try w.nextEventBatch(io, 0);
    eb.deinit(allocator);
}

fn pumpAndIngestDirty(allocator: Allocator, io: Io, proj: *projection.Projection) !?id.BatchId {
    if (proj.watcher) |w| {
        var eb = try w.nextEventBatch(io, 0);
        defer eb.deinit(allocator);
        if (proj.watcher_mount_id) |mid| {
            for (eb.batches.items) |*b| {
                if (b.mount_id == mid) {
                    return try proj.ingestMountBatch(b);
                }
            }
        }
    }
    return try proj.ingestDirty();
}

pub fn runBenchBigRepo(
    allocator: Allocator,
    io: Io,
    out: anytype,
    file_count_opt: ?usize,
    scratch_dir: ?[]const u8,
) !void {
    const file_count: usize = @max(file_count_opt orelse 50_000, 10);
    var scratch = try ScratchDir.init(allocator, io, scratch_dir, "bench-bigrepo");
    defer scratch.deinit();

    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/repo", .{scratch.path});
    defer allocator.free(repo_dir);
    const state_dir = try std.fmt.allocPrint(allocator, "{s}/state", .{scratch.path});
    defer allocator.free(state_dir);
    const checkouts_dir = try std.fmt.allocPrint(allocator, "{s}/checkouts", .{scratch.path});
    defer allocator.free(checkouts_dir);

    try out.print("=== 0ndb Benchmark 1: Big Repo Scale (files={d}) ===\n", .{file_count});
    try out.print("scratch={s}\n", .{scratch.path});
    try out.flush();

    const gen_t0 = nowNs(io);
    try generateGitRepo(allocator, io, repo_dir, file_count);
    const gen_ns = nowNs(io) -| gen_t0;
    const worktree_bytes = dirDiskBytes(io, repo_dir, true);
    const git_total_bytes = dirDiskBytes(io, repo_dir, false);

    var space_id: u128 = 0;
    var space_state_path: []u8 = &.{};
    defer if (space_state_path.len > 0) allocator.free(space_state_path);

    var adopt_ns: u64 = 0;
    var snap_ns: u64 = 0;
    var adopt_metrics: ProcMetrics = .{};
    var adopt_state_bytes: u64 = 0;

    {
        var res = try pool.DaemonResources.init(allocator, io, state_dir, .{});
        defer res.deinit();
        var mgr = try manager_mod.SpaceManager.open(allocator, io, state_dir, checkouts_dir, res);
        defer mgr.deinit();

        const t0 = nowNs(io);
        var rec = try mgr.adoptLocal(repo_dir, "bigrepo");
        const t1 = nowNs(io);
        defer rec.deinit(allocator);
        adopt_ns = t1 -| t0;
        space_id = rec.space_id;
        space_state_path = try allocator.dupe(u8, rec.state_path);

        const sp = try mgr.activate(space_id);
        const s0 = nowNs(io);
        try sp.checkpoint(.major);
        const s1 = nowNs(io);
        snap_ns = s1 -| s0;

        var sample_buf: [64]u8 = undefined;
        const sample_path = try formatRepoRelPath(&sample_buf, file_count / 2);
        const sample_bytes = (try sp.readFileAlloc(allocator, sample_path)) orelse {
            try assertCond(false, "sample file missing after adoptLocal");
            unreachable;
        };
        defer allocator.free(sample_bytes);
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "FILE_INDEX: usize = {d};", .{file_count / 2});
        try assertCond(std.mem.indexOf(u8, sample_bytes, needle) != null, "sample file content mismatch after adopt");

        adopt_metrics = readProcMetrics(allocator, io);
        adopt_state_bytes = dirDiskBytes(io, state_dir, false);
    }

    var cold_open_ns: u64 = 0;
    var cold_metrics: ProcMetrics = .{};
    var lookup_total_ns: u64 = 0;
    const lookup_count: usize = 100;
    var ingest_ns: u64 = 0;
    var diff_ns: u64 = 0;
    var rollback_ns: u64 = 0;
    var diff_bytes_len: usize = 0;

    {
        var res = try pool.DaemonResources.init(allocator, io, state_dir, .{});
        defer res.deinit();
        var mgr = try manager_mod.SpaceManager.open(allocator, io, state_dir, checkouts_dir, res);
        defer mgr.deinit();

        const c0 = nowNs(io);
        const sp = try mgr.activate(space_id);
        const c1 = nowNs(io);
        cold_open_ns = c1 -| c0;
        cold_metrics = readProcMetrics(allocator, io);

        const proj = (try mgr.activateProjection(space_id)) orelse {
            try assertCond(false, "projection missing on reopen");
            unreachable;
        };

        var prng_state: u64 = 0x517cc1b727220a95;
        var pbuf: [64]u8 = undefined;
        var nbuf: [64]u8 = undefined;
        const l0 = nowNs(io);
        for (0..lookup_count) |_| {
            prng_state = prng_state *% 6364136223846793005 +% 1442695040888963407;
            const idx: usize = @intCast((prng_state >> 16) % @as(u64, @intCast(file_count)));
            const rel = try formatRepoRelPath(&pbuf, idx);
            const data = (try sp.readFileAlloc(allocator, rel)) orelse {
                try assertCond(false, "point lookup returned null");
                unreachable;
            };
            defer allocator.free(data);
            const expected_marker = try std.fmt.bufPrint(&nbuf, "FILE_INDEX: usize = {d};", .{idx});
            try assertCond(std.mem.indexOf(u8, data, expected_marker) != null, "point lookup content mismatch");
        }
        const l1 = nowNs(io);
        lookup_total_ns = l1 -| l0;

        if (proj.watcher) |w| {
            try drainWatcherEvents(allocator, io, w);
            if (proj.watcher_mount_id) |mid| {
                if (try w.flushMountPending(mid)) |bval| {
                    var b = bval;
                    b.deinit(allocator);
                }
            }
        }
        proj.dirty.store(false, .release);

        var pre_edit_ver = try sp.headsClone(allocator);
        defer pre_edit_ver.deinit(allocator);

        const edit_indices = [_]usize{ 0, file_count / 2, file_count - 1 };
        var edit_paths: [3][64]u8 = undefined;
        var edit_slices: [3][]const u8 = undefined;
        var orig_contents: [3][]u8 = undefined;
        var orig_inited: usize = 0;
        defer {
            for (0..orig_inited) |k| allocator.free(orig_contents[k]);
        }

        for (edit_indices, 0..) |idx, k| {
            edit_slices[k] = try formatRepoRelPath(&edit_paths[k], idx);
            orig_contents[k] = (try sp.readFileAlloc(allocator, edit_slices[k])).?;
            orig_inited += 1;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_dir, edit_slices[k] });
            defer allocator.free(full_path);
            const modified = try std.fmt.allocPrint(allocator, "{s}const BENCH_MODIFIED_{d}: u64 = 424242;\n", .{ orig_contents[k], k });
            defer allocator.free(modified);
            const f = try Io.Dir.cwd().createFile(io, full_path, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, modified);
        }

        const ing0 = nowNs(io);
        const edit_bid_opt = try pumpAndIngestDirty(allocator, io, proj);
        const ing1 = nowNs(io);
        ingest_ns = ing1 -| ing0;
        try assertCond(edit_bid_opt != null, "incremental ingest of 3 edited files returned null batch");

        const d0 = nowNs(io);
        const diff_bytes = try timeline.unifiedDiffForSpace(allocator, sp, &.{edit_bid_opt.?});
        const d1 = nowNs(io);
        defer allocator.free(diff_bytes);
        diff_ns = d1 -| d0;
        diff_bytes_len = diff_bytes.len;
        try assertCond(diff_bytes.len > 0, "unified diff was empty");
        for (edit_slices) |ep| {
            try assertCond(std.mem.indexOf(u8, diff_bytes, ep) != null, "unified diff missing edited file");
        }

        const r0 = nowNs(io);
        const rolled = try sp.rollbackToVersion(sp.actor_id, &pre_edit_ver);
        try assertCond(rolled, "rollbackToVersion returned false");
        try proj.materializeChanged();
        const r1 = nowNs(io);
        rollback_ns = r1 -| r0;

        for (edit_slices, 0..) |ep, k| {
            const sp_after = (try sp.readFileAlloc(allocator, ep)) orelse {
                try assertCond(false, "file missing in Space after rollback");
                unreachable;
            };
            defer allocator.free(sp_after);
            try assertCond(std.mem.eql(u8, sp_after, orig_contents[k]), "Space content not reverted after rollback");

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_dir, ep });
            defer allocator.free(full_path);
            const disk_after = try Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(1024 * 1024));
            defer allocator.free(disk_after);
            try assertCond(std.mem.eql(u8, disk_after, orig_contents[k]), "disk content not reverted after rollback");
        }
    }

    var disk_before_compact: u64 = 0;
    var disk_after_compact: u64 = 0;
    var compact_ns: u64 = 0;
    var compact_stats: space_mod.CompactStats = .{};

    {
        var sp = try space_mod.Space.open(allocator, io, space_state_path, space_id, .git_worktree, null);
        defer sp.deinit();
        var proj = try projection.Projection.attach(allocator, io, &sp, repo_dir, null);
        defer proj.deinit();

        const actor = sp.actor_id;
        var churn_path_buf: [64]u8 = undefined;
        var churn_body_buf: [256]u8 = undefined;
        for (0..30) |k| {
            const p = try std.fmt.bufPrint(&churn_path_buf, "churn/edit_{d:0>2}.txt", .{k % 5});
            const b = try std.fmt.bufPrint(&churn_body_buf, "churn revision {d}\npayload line {d}\n", .{ k, k * 17 });
            _ = try sp.putFile(actor, p, b);
        }

        const bin_buf = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(bin_buf);
        for (0..15) |k| {
            for (bin_buf, 0..) |*byte, bi| {
                byte.* = @truncate((bi * 31 + k * 17) ^ 0x5A);
            }
            bin_buf[0] = 0;
            bin_buf[1] = 0;
            bin_buf[2] = @intCast(k);
            _ = try sp.putFile(actor, "churn/blob.bin", bin_buf);
        }
        for (0..5) |k| {
            const tp = try std.fmt.bufPrint(&churn_path_buf, "churn/edit_{d:0>2}.txt", .{k});
            _ = try sp.deletePath(actor, tp);
        }
        try sp.checkpoint(.minor);

        disk_before_compact = dirDiskBytes(io, space_state_path, false);

        const k0 = nowNs(io);
        compact_stats = try sp.compactWithPolicy(.{
            .retain_latest_batches = 0,
            .retain_ms = 0,
            .force_gc = true,
        });
        const k1 = nowNs(io);
        compact_ns = k1 -| k0;

        disk_after_compact = dirDiskBytes(io, space_state_path, false);
        try assertCond(compact_stats.removed_blobs >= 10, "expected dead binary blobs to be GC'd");
        try assertCond(disk_after_compact < disk_before_compact, "expected disk bytes to shrink after compaction");
    }

    const reclaimed_bytes = disk_before_compact -| disk_after_compact;
    const reclaimed_pct: f64 = if (disk_before_compact > 0)
        (@as(f64, @floatFromInt(reclaimed_bytes)) * 100.0) / @as(f64, @floatFromInt(disk_before_compact))
    else
        0.0;
    const state_ratio_pct: f64 = if (worktree_bytes > 0)
        (@as(f64, @floatFromInt(adopt_state_bytes)) * 100.0) / @as(f64, @floatFromInt(worktree_bytes))
    else
        0.0;

    try out.print("\n--- Big Repo Summary ---\n", .{});
    try out.print("  repo_gen_ms={d:.2} files={d} worktree_mb={d:.2} git_total_mb={d:.2}\n", .{
        msFromNs(gen_ns), file_count, mbFromBytes(worktree_bytes), mbFromBytes(git_total_bytes),
    });
    try out.print("  git_adopt_ms={d:.2} major_snap_ms={d:.2} state_mb={d:.2} state_vs_worktree_pct={d:.2} rss_mb={d:.2} hwm_mb={d:.2}\n", .{
        msFromNs(adopt_ns),
        msFromNs(snap_ns),
        mbFromBytes(adopt_state_bytes),
        state_ratio_pct,
        mbFromKb(adopt_metrics.vm_rss_kb),
        mbFromKb(adopt_metrics.vm_hwm_kb),
    });
    try out.print("  cold_reopen_ms={d:.2} cold_rss_mb={d:.2} cold_fds={d} threads={d}\n", .{
        msFromNs(cold_open_ns), mbFromKb(cold_metrics.vm_rss_kb), cold_metrics.open_fds, cold_metrics.threads,
    });
    try out.print("  point_lookup_100_avg_us={d:.2} total_ms={d:.2}\n", .{
        usFromNs(lookup_total_ns) / @as(f64, @floatFromInt(lookup_count)),
        msFromNs(lookup_total_ns),
    });
    try out.print("  ingest_3files_ms={d:.2} unified_diff_ms={d:.2} diff_bytes={d}\n", .{
        msFromNs(ingest_ns), msFromNs(diff_ns), diff_bytes_len,
    });
    try out.print("  rollback_3files_ms={d:.2} verified=ok\n", .{msFromNs(rollback_ns)});
    try out.print("  compact_ms={d:.2} before_kb={d:.1} after_kb={d:.1} reclaimed_kb={d:.1} reclaimed_pct={d:.1} pruned_batches={d} removed_blobs={d}\n", .{
        msFromNs(compact_ns),
        @as(f64, @floatFromInt(disk_before_compact)) / 1024.0,
        @as(f64, @floatFromInt(disk_after_compact)) / 1024.0,
        @as(f64, @floatFromInt(reclaimed_bytes)) / 1024.0,
        reclaimed_pct,
        compact_stats.pruned_batches,
        compact_stats.removed_blobs,
    });
    try out.print("RESULT: PASS (bench-bigrepo)\n", .{});
    try out.flush();
}

pub fn runBenchMany(
    allocator: Allocator,
    io: Io,
    out: anytype,
    file_count_opt: ?usize,
    space_count_opt: ?usize,
    scratch_dir: ?[]const u8,
) !void {
    const file_count: usize = @max(file_count_opt orelse 10_000, 10);
    const space_count: usize = @max(space_count_opt orelse 30, 3);
    const max_hot_budget: u32 = 4;

    var scratch = try ScratchDir.init(allocator, io, scratch_dir, "bench-many");
    defer scratch.deinit();

    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/base-repo", .{scratch.path});
    defer allocator.free(repo_dir);
    const state_dir = try std.fmt.allocPrint(allocator, "{s}/state", .{scratch.path});
    defer allocator.free(state_dir);
    const checkouts_dir = try std.fmt.allocPrint(allocator, "{s}/checkouts", .{scratch.path});
    defer allocator.free(checkouts_dir);

    try out.print("=== 0ndb Benchmark 2: Many Spaces & Daemon Scale (files={d}, spaces={d}) ===\n", .{ file_count, space_count });
    try out.print("scratch={s}\n", .{scratch.path});
    try out.flush();

    const gen_t0 = nowNs(io);
    try generateGitRepo(allocator, io, repo_dir, file_count);
    const gen_ns = nowNs(io) -| gen_t0;

    const budget = pool.MemoryBudget{
        .shared_blob_bytes = 16 * 1024 * 1024,
        .shared_git_delta_bytes = 8 * 1024 * 1024,
        .active_workspaces_bytes = 32 * 1024 * 1024,
        .max_hot_worktrees = max_hot_budget,
        .idle_hibernate_ms = 1_000,
    };

    var all_space_ids: std.ArrayList(u128) = .empty;
    defer all_space_ids.deinit(allocator);

    var adopt_ns: u64 = 0;
    var fork_total_ns: u64 = 0;
    var watcher_fds_after_fork: usize = 0;
    var shared_odb_count: usize = 0;

    {
        var res = try pool.DaemonResources.init(allocator, io, state_dir, budget);
        defer res.deinit();
        var mgr = try manager_mod.SpaceManager.open(allocator, io, state_dir, checkouts_dir, res);
        defer mgr.deinit();

        const a0 = nowNs(io);
        var base_rec = try mgr.adoptLocal(repo_dir, "base");
        defer base_rec.deinit(allocator);
        const base_sp = try mgr.activate(base_rec.space_id);
        try base_sp.checkpoint(.major);
        adopt_ns = nowNs(io) -| a0;
        try all_space_ids.append(allocator, base_rec.space_id);

        var title_buf: [64]u8 = undefined;
        const f0 = nowNs(io);
        for (1..space_count) |k| {
            const title = try std.fmt.bufPrint(&title_buf, "fork-{d:0>3}", .{k});
            var frec = try mgr.forkSpace(base_rec.space_id, title, true);
            const fid = frec.space_id;
            frec.deinit(allocator);
            try all_space_ids.append(allocator, fid);
        }
        fork_total_ns = nowNs(io) -| f0;

        shared_odb_count = res.gitOdbCount();
        watcher_fds_after_fork = if (res.watcher) |w| w.fdCount() else 0;
        try assertCond(shared_odb_count == 1, "expected exactly 1 shared GitOdb across all worktree forks");
        try assertCond(watcher_fds_after_fork <= 4, "expected 4-FD DaemonWatcher invariant");
        try assertCond(mgr.hotCount() <= max_hot_budget, "hotCount exceeded MemoryGovernor max_hot_worktrees");
    }

    var cold_daemon_ns: u64 = 0;
    var cold_metrics: ProcMetrics = .{};
    var pre_hib_metrics: ProcMetrics = .{};
    var post_hib_metrics: ProcMetrics = .{};
    var hibernated_count: usize = 0;
    var storm_ns: u64 = 0;
    var storm_batches: usize = 0;
    var storm_files_written: usize = 0;
    var wake_ns: u64 = 0;
    var spaceset_fork_ns: u64 = 0;
    var spaceset_sync_ns: u64 = 0;
    var spaceset_land_ns: u64 = 0;

    {
        const d0 = nowNs(io);
        var res = try pool.DaemonResources.init(allocator, io, state_dir, budget);
        defer res.deinit();
        var mgr = try manager_mod.SpaceManager.open(allocator, io, state_dir, checkouts_dir, res);
        defer mgr.deinit();
        cold_daemon_ns = nowNs(io) -| d0;
        cold_metrics = readProcMetrics(allocator, io);

        try assertCond(mgr.spaceCount() == space_count, "cold daemon space count mismatch");
        try assertCond(mgr.hotCount() == 0, "cold daemon must have 0 hot mounts on startup");
        try assertCond(mgr.warmCount() == 0, "cold daemon must have 0 warm mounts on startup");
        try assertCond(mgr.coldCount() == space_count, "all spaces must start cold");

        const edit_mounts = @min(space_count, 8);
        var msg_buf: [64]u8 = undefined;
        for (0..edit_mounts) |k| {
            const sid = all_space_ids.items[k];
            const sp = try mgr.activate(sid);
            _ = try mgr.activateProjection(sid);
            const msg = try std.fmt.bufPrint(&msg_buf, "active edit {d}\n", .{k});
            _ = try sp.putFile(sp.actor_id, "mount_touch.txt", msg);
        }
        pre_hib_metrics = readProcMetrics(allocator, io);
        try assertCond(mgr.hotCount() <= max_hot_budget, "hot mounts exceeded budget during active edits");

        const now = id.nowMs(io);
        hibernated_count = mgr.hibernateIdle(now + 60_000, 1_000);
        _ = mgr.evictToBudget();
        post_hib_metrics = readProcMetrics(allocator, io);
        try assertCond(mgr.hotCount() == 0, "expected 0 hot mounts after hibernateIdle");

        const storm_mounts = @min(space_count, 3);
        const files_per_mount: usize = 5_000;
        var storm_mids: [3]u64 = .{ 0, 0, 0 };
        var storm_roots: [3][]const u8 = undefined;
        for (0..storm_mounts) |k| {
            const sid = all_space_ids.items[k];
            const proj = (try mgr.activateProjection(sid)) orelse {
                try assertCond(false, "storm mount projection missing");
                unreachable;
            };
            storm_mids[k] = proj.watcher_mount_id orelse 0;
            storm_roots[k] = proj.root_path;
        }

        const w = try res.ensureWatcher();
        try drainWatcherEvents(allocator, io, w);
        for (0..storm_mounts) |k| {
            if (try w.flushMountPending(storm_mids[k])) |bval| {
                var b = bval;
                b.deinit(allocator);
            }
        }

        const st0 = nowNs(io);
        var rel_buf: [96]u8 = undefined;
        for (0..storm_mounts) |k| {
            var mdir = try Io.Dir.cwd().openDir(io, storm_roots[k], .{});
            defer mdir.close(io);
            try mdir.createDirPath(io, "target/debug/deps");
            try mdir.createDirPath(io, "node_modules/pkg_cache");
            var tdir = try mdir.openDir(io, "target/debug/deps", .{});
            defer tdir.close(io);
            var ndir = try mdir.openDir(io, "node_modules/pkg_cache", .{});
            defer ndir.close(io);
            for (0..files_per_mount) |fi| {
                if (fi < files_per_mount / 2) {
                    const nm = try std.fmt.bufPrint(&rel_buf, "artifact_{d:0>5}.o", .{fi});
                    const f = try tdir.createFile(io, nm, .{ .truncate = true });
                    f.close(io);
                } else {
                    const nm = try std.fmt.bufPrint(&rel_buf, "dep_{d:0>5}.js", .{fi});
                    const f = try ndir.createFile(io, nm, .{ .truncate = true });
                    f.close(io);
                }
                storm_files_written += 1;
            }
        }

        var pump_rounds: usize = 0;
        while (pump_rounds < 5) : (pump_rounds += 1) {
            var eb = try w.nextEventBatch(io, 60);
            defer eb.deinit(allocator);
            storm_batches += eb.batches.items.len;
            if (eb.timed_out and eb.batches.items.len == 0) break;
        }
        try drainWatcherEvents(allocator, io, w);
        for (0..storm_mounts) |k| {
            if (try w.flushMountPending(storm_mids[k])) |bval| {
                var b = bval;
                b.deinit(allocator);
                storm_batches += 1;
            }
        }
        storm_ns = nowNs(io) -| st0;
        try assertCond(storm_batches == 0, "ignored build storm unexpectedly triggered watcher batches");
        try assertCond(w.fdCount() <= 4, "watcher exceeded 4 FDs during storm");

        _ = mgr.hibernateIdle(id.nowMs(io) + 120_000, 1_000);
        try assertCond(mgr.hotCount() == 0, "expected 0 hot mounts before wake test");

        const wake_sid = all_space_ids.items[1];
        const wake_rec = mgr.getProjectionRecord(wake_sid).?;
        var pbuf: [64]u8 = undefined;
        const wake_rel = try formatRepoRelPath(&pbuf, 0);
        const wake_file = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wake_rec.local_path, wake_rel });
        defer allocator.free(wake_file);
        {
            const f = try Io.Dir.cwd().createFile(io, wake_file, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "woken-from-hibernate-content\n");
        }

        const wk0 = nowNs(io);
        const wake_proj = (try mgr.activateProjection(wake_sid)) orelse {
            try assertCond(false, "wake projection failed");
            unreachable;
        };
        const wake_bid = try wake_proj.ingestDirty();
        wake_ns = nowNs(io) -| wk0;
        try assertCond(wake_bid != null, "hibernated wake ingest returned null");
        const wake_sp = try mgr.activate(wake_sid);
        const wake_read = (try wake_sp.readFileAlloc(allocator, wake_rel)).?;
        defer allocator.free(wake_read);
        try assertCond(std.mem.eql(u8, wake_read, "woken-from-hibernate-content\n"), "hibernated wake content mismatch");

        var pstore = try project_mod.ProjectStore.open(allocator, io, state_dir);
        defer pstore.deinit();
        var proj_obj = try pstore.create("bench-project", "multi-space project", 0, null);
        defer proj_obj.deinit(allocator);

        var set_origin_ids: [5]u128 = undefined;
        set_origin_ids[0] = all_space_ids.items[0];
        const set_aliases = [_][]const u8{ "repo", "svc_a", "svc_b", "docs", "notes" };
        try pstore.addSpace(proj_obj.project_id, .{
            .space_id = set_origin_ids[0],
            .alias = @constCast(set_aliases[0]),
            .kind = .git_worktree,
            .default_access = 1,
        });

        for (1..5) |k| {
            var vrec = try mgr.createVirtual(set_aliases[k]);
            set_origin_ids[k] = vrec.space_id;
            vrec.deinit(allocator);
            const vsp = try mgr.activate(set_origin_ids[k]);
            _ = try vsp.putFile(vsp.actor_id, "init.txt", "origin initial\n");
            try pstore.addSpace(proj_obj.project_id, .{
                .space_id = set_origin_ids[k],
                .alias = @constCast(set_aliases[k]),
                .kind = .virtual,
                .default_access = 1,
            });
        }

        const sf0 = nowNs(io);
        const set_forks = try project_mod.SpaceSet.forkSpaceSet(allocator, &mgr, &set_origin_ids, "feat", false);
        spaceset_fork_ns = nowNs(io) -| sf0;
        defer allocator.free(set_forks);
        try assertCond(set_forks.len == 5, "SpaceSet.forkSpaceSet count mismatch");

        {
            const o1 = try mgr.activate(set_origin_ids[1]);
            _ = try o1.putFile(o1.actor_id, "upstream.txt", "upstream update\n");
        }
        for (set_forks, 0..) |fid, k| {
            const fsp = try mgr.activate(fid);
            const fcontent = try std.fmt.bufPrint(&msg_buf, "fork edit {d}\n", .{k});
            _ = try fsp.putFile(fsp.actor_id, "feature_change.txt", fcontent);
        }

        const ss0 = nowNs(io);
        const sync_entries = try project_mod.SpaceSet.syncSpaceSet(allocator, &mgr, set_forks);
        spaceset_sync_ns = nowNs(io) -| ss0;
        defer {
            for (sync_entries) |*e| e.deinit(allocator);
            allocator.free(sync_entries);
        }
        try assertCond(sync_entries.len == 5, "SpaceSet.syncSpaceSet count mismatch");

        {
            const f1 = try mgr.activate(set_forks[1]);
            const up = (try f1.readFileAlloc(allocator, "upstream.txt")) orelse {
                try assertCond(false, "SpaceSet sync did not bring upstream file");
                unreachable;
            };
            defer allocator.free(up);
            try assertCond(std.mem.eql(u8, up, "upstream update\n"), "SpaceSet synced content mismatch");
        }

        const sl0 = nowNs(io);
        var land_rep = try project_mod.SpaceSet.landSpaceSet(allocator, &mgr, set_forks);
        spaceset_land_ns = nowNs(io) -| sl0;
        defer land_rep.deinit(allocator);
        try assertCond(!land_rep.aborted, "SpaceSet.landSpaceSet unexpectedly aborted");
        try assertCond(land_rep.entries.len == 5, "SpaceSet.landSpaceSet entry count mismatch");

        for (set_origin_ids) |oid| {
            const osp = try mgr.activate(oid);
            const landed = (try osp.readFileAlloc(allocator, "feature_change.txt")) orelse {
                try assertCond(false, "SpaceSet land did not land file into origin");
                unreachable;
            };
            allocator.free(landed);
        }
    }

    const fork_count = space_count - 1;
    try out.print("\n--- Many Spaces Summary ---\n", .{});
    try out.print("  repo_gen_ms={d:.2} adopt_ms={d:.2} forks={d} fork_total_ms={d:.2} fork_avg_ms={d:.2} shared_odbs={d} watcher_fds={d}\n", .{
        msFromNs(gen_ns),
        msFromNs(adopt_ns),
        fork_count,
        msFromNs(fork_total_ns),
        msFromNs(fork_total_ns) / @as(f64, @floatFromInt(fork_count)),
        shared_odb_count,
        watcher_fds_after_fork,
    });
    try out.print("  cold_daemon_open_ms={d:.2} eager_opens=0 cold_rss_mb={d:.2} cold_fds={d} threads={d}\n", .{
        msFromNs(cold_daemon_ns), mbFromKb(cold_metrics.vm_rss_kb), cold_metrics.open_fds, cold_metrics.threads,
    });
    try out.print("  hibernate_evicted={d} rss_before_mb={d:.2} rss_after_mb={d:.2} hot_after=0 post_fds={d} threads={d}\n", .{
        hibernated_count,
        mbFromKb(pre_hib_metrics.vm_rss_kb),
        mbFromKb(post_hib_metrics.vm_rss_kb),
        post_hib_metrics.open_fds,
        post_hib_metrics.threads,
    });
    try out.print("  ignored_storm_files={d} storm_ms={d:.2} mounts_woken=0 batches_created={d}\n", .{
        storm_files_written, msFromNs(storm_ns), storm_batches,
    });
    try out.print("  hibernated_wake_ingest_ms={d:.2}\n", .{msFromNs(wake_ns)});
    try out.print("  spaceset_5_fork_ms={d:.2} sync_ms={d:.2} land_ms={d:.2}\n", .{
        msFromNs(spaceset_fork_ns), msFromNs(spaceset_sync_ns), msFromNs(spaceset_land_ns),
    });
    try out.print("RESULT: PASS (bench-many)\n", .{});
    try out.flush();
}

pub fn runBenchAgents(
    allocator: Allocator,
    io: Io,
    out: anytype,
    subordinates_opt: ?usize,
    scratch_dir: ?[]const u8,
) !void {
    const subordinates: usize = @max(subordinates_opt orelse 20, 2);
    var scratch = try ScratchDir.init(allocator, io, scratch_dir, "bench-agents");
    defer scratch.deinit();

    try out.print("=== 0ndb Benchmark 3: Multi-Agent, Virtual & Captain Scale (subordinates={d}) ===\n", .{subordinates});
    try out.print("scratch={s}\n", .{scratch.path});
    try out.flush();

    var zero_turns_ns: u64 = 0;
    var zero_fd_delta: isize = 0;

    var virt_writes_ns: u64 = 0;
    var virt_search_ns: u64 = 0;
    var virt_timeline_ns: u64 = 0;
    var virt_ckpt_ns: u64 = 0;
    var virt_cold_ns: u64 = 0;
    var virt_rb_ns: u64 = 0;
    var virt_search_hits: usize = 0;
    var virt_timeline_entries: usize = 0;

    var fanout_ns: u64 = 0;
    var settle_ns: u64 = 0;
    var land_ns: u64 = 0;
    var cancel_ns: u64 = 0;
    var recovery_ns: u64 = 0;
    var cancel_threads: usize = 0;
    var cancel_tasks: usize = 0;

    {
        const zero_state = try std.fmt.allocPrint(allocator, "{s}/zero-state", .{scratch.path});
        defer allocator.free(zero_state);
        const zero_checkouts = try std.fmt.allocPrint(allocator, "{s}/zero-checkouts", .{scratch.path});
        defer allocator.free(zero_checkouts);
        try Io.Dir.cwd().createDirPath(io, zero_state);

        var res = try pool.DaemonResources.init(allocator, io, zero_state, .{});
        defer res.deinit();
        var spaces = try manager_mod.SpaceManager.open(allocator, io, zero_state, zero_checkouts, res);
        defer spaces.deinit();
        var projects = try project_mod.ProjectStore.open(allocator, io, zero_state);
        defer projects.deinit();
        var zdir = try Io.Dir.cwd().openDir(io, zero_state, .{ .iterate = true });
        defer zdir.close(io);
        var catalog = try thread_store.CatalogStore.open(allocator, io, zdir);
        defer catalog.deinit();
        const runner_id = id.newUuidV7(io);
        const device_id = id.newUuidV7(io);
        var keyring = keyring_mod.Keyring.initAccountDevice(allocator, io, crypto.AccountRootKey.generate(io), runner_id);
        defer keyring.deinit();
        var leases = try lease_mod.LeaseManager.init(allocator, io, zero_state, runner_id, null);
        defer leases.deinit();

        var rt = try thread_runtime.ThreadRuntime.init(allocator, io, .{
            .spaces = &spaces,
            .projects = &projects,
            .catalog = &catalog,
            .keyring = &keyring,
            .leases = &leases,
            .root_dir = zero_state,
            .runner_id = runner_id,
            .device_id = device_id,
            .shared_blobs = res.blob_pool,
        });
        defer rt.deinit();

        var meta = try rt.createThread(.{
            .title = "Zero-Repo Chat",
            .provider_id = .mock,
        });
        defer meta.deinit(allocator);
        try assertCond(meta.bindings.len == 0, "zero-repo thread must have 0 bindings");
        _ = try rt.openThread(meta.thread_id);

        {
            var warm_bt = try rt.beginTurn(meta.thread_id, "warmup", .{});
            defer warm_bt.deinit(allocator);
            var warm_post = try rt.completeTurn(meta.thread_id, warm_bt.turn_id, "ready", &.{}, .{}, null);
            defer warm_post.deinit(allocator);
        }
        const fds_before = readProcMetrics(allocator, io).open_fds;
        var pbuf: [64]u8 = undefined;
        var rbuf: [64]u8 = undefined;
        const t0 = nowNs(io);
        for (0..50) |k| {
            const prompt = try std.fmt.bufPrint(&pbuf, "turn prompt {d}", .{k});
            const reply = try std.fmt.bufPrint(&rbuf, "turn reply {d}", .{k});
            var bt = try rt.beginTurn(meta.thread_id, prompt, .{});
            defer bt.deinit(allocator);
            var post = try rt.completeTurn(meta.thread_id, bt.turn_id, reply, &.{}, .{}, null);
            defer post.deinit(allocator);
        }
        zero_turns_ns = nowNs(io) -| t0;
        const fds_after = readProcMetrics(allocator, io).open_fds;
        zero_fd_delta = @as(isize, @intCast(fds_after)) - @as(isize, @intCast(fds_before));

        try assertCond(spaces.spaceCount() == 0, "zero-repo chat opened unexpected spaces");
        try assertCond(spaces.hotCount() == 0, "zero-repo chat activated unexpected spaces");
        try assertCond(zero_fd_delta <= 2, "zero-repo chat leaked or opened extra FDs");
    }

    {
        const virt_state = try std.fmt.allocPrint(allocator, "{s}/virt-state", .{scratch.path});
        defer allocator.free(virt_state);
        const virt_checkouts = try std.fmt.allocPrint(allocator, "{s}/virt-checkouts", .{scratch.path});
        defer allocator.free(virt_checkouts);
        try Io.Dir.cwd().createDirPath(io, virt_state);

        var mem_id: u128 = 0;
        var pre_corrupt_ver = @import("core/version.zig").Version.ROOT;
        defer pre_corrupt_ver.deinit(allocator);

        {
            var res = try pool.DaemonResources.init(allocator, io, virt_state, .{});
            defer res.deinit();
            var spaces = try manager_mod.SpaceManager.open(allocator, io, virt_state, virt_checkouts, res);
            defer spaces.deinit();

            var mem_rec = try spaces.createVirtual("grok-memory");
            mem_id = mem_rec.space_id;
            mem_rec.deinit(allocator);

            const bindings = [_]thread_model.SpaceBinding{.{
                .space_id = mem_id,
                .alias = @constCast("memory"),
                .access = .shared_rw,
            }};
            var bridge = try thread_runtime.SpaceVirtualBridge.init(allocator, &spaces, &bindings, id.newUuidV7(io));
            defer bridge.deinit();

            var pbuf: [64]u8 = undefined;
            var cbuf: [192]u8 = undefined;
            var kbuf: [64]u8 = undefined;
            var vbuf: [64]u8 = undefined;

            const w0 = nowNs(io);
            for (0..250) |k| {
                const path = try std.fmt.bufPrint(&pbuf, "notes/note_{d:0>3}.md", .{k});
                const tag: []const u8 = if (k % 25 == 0) "needle-fact" else "journal-entry";
                const content = try std.fmt.bufPrint(&cbuf, "# Note {d}\ntag={s}\nmemory record value {d}\n", .{ k, tag, k * 13 });
                try bridge.writeFile(mem_id, path, content);
            }
            for (0..250) |k| {
                const key = try std.fmt.bufPrint(&kbuf, "pref/item_{d:0>3}", .{k});
                const val = try std.fmt.bufPrint(&vbuf, "val_{d}", .{k});
                try bridge.setMeta(mem_id, key, val);
            }
            virt_writes_ns = nowNs(io) -| w0;

            const s0 = nowNs(io);
            const hits = try bridge.searchText(allocator, mem_id, "needle-fact");
            virt_search_ns = nowNs(io) -| s0;
            virt_search_hits = hits.len;
            defer {
                for (hits) |h| allocator.free(h);
                allocator.free(hits);
            }
            try assertCond(virt_search_hits == 10, "expected 10 search hits in virtual space");

            const mem_sp = try spaces.activate(mem_id);
            const tl0 = nowNs(io);
            const entries = try timeline.listEntriesForSpace(allocator, mem_sp, null, 50);
            virt_timeline_ns = nowNs(io) -| tl0;
            virt_timeline_entries = entries.len;
            defer timeline.freeTimelineEntries(allocator, entries);
            try assertCond(virt_timeline_entries == 50, "expected 50 timeline entries in virtual space");

            const ck0 = nowNs(io);
            try bridge.checkpoint(mem_id, .major);
            virt_ckpt_ns = nowNs(io) -| ck0;

            try assertCond(spaces.getProjectionRecord(mem_id) == null, "virtual space must have 0 disk checkouts");
            const active_watches = if (res.watcher) |w| w.activeWatches() else 0;
            try assertCond(active_watches == 0, "virtual space must have 0 inotify watches");
        }

        {
            var res = try pool.DaemonResources.init(allocator, io, virt_state, .{});
            defer res.deinit();
            var spaces = try manager_mod.SpaceManager.open(allocator, io, virt_state, virt_checkouts, res);
            defer spaces.deinit();

            const c0 = nowNs(io);
            const mem_sp = try spaces.activate(mem_id);
            virt_cold_ns = nowNs(io) -| c0;

            pre_corrupt_ver = try mem_sp.headsClone(allocator);
            const bindings = [_]thread_model.SpaceBinding{.{
                .space_id = mem_id,
                .alias = @constCast("memory"),
                .access = .shared_rw,
            }};
            var bridge2 = try thread_runtime.SpaceVirtualBridge.init(allocator, &spaces, &bindings, id.newUuidV7(io));
            defer bridge2.deinit();
            try bridge2.writeFile(mem_id, "notes/note_000.md", "CORRUPTED HALLUCINATION\n");

            const rb0 = nowNs(io);
            const rolled = try mem_sp.rollbackToVersion(mem_sp.actor_id, &pre_corrupt_ver);
            virt_rb_ns = nowNs(io) -| rb0;
            try assertCond(rolled, "virtual space rollback returned false");

            const restored = (try mem_sp.readFileAlloc(allocator, "notes/note_000.md")).?;
            defer allocator.free(restored);
            try assertCond(std.mem.indexOf(u8, restored, "needle-fact") != null, "virtual space rollback did not restore note_000.md");
            try assertCond(dirDiskBytes(io, virt_checkouts, false) == 0, "virtual space created unexpected checkout files");
        }
    }

    {
        const cap_state = try std.fmt.allocPrint(allocator, "{s}/captain-state", .{scratch.path});
        defer allocator.free(cap_state);
        const cap_checkouts = try std.fmt.allocPrint(allocator, "{s}/captain-checkouts", .{scratch.path});
        defer allocator.free(cap_checkouts);
        const api_repo = try std.fmt.allocPrint(allocator, "{s}/repo-api", .{scratch.path});
        defer allocator.free(api_repo);
        const web_repo = try std.fmt.allocPrint(allocator, "{s}/repo-web", .{scratch.path});
        defer allocator.free(web_repo);

        try Io.Dir.cwd().createDirPath(io, cap_state);
        try generateGitRepo(allocator, io, api_repo, 20);
        try generateGitRepo(allocator, io, web_repo, 20);

        var res = try pool.DaemonResources.init(allocator, io, cap_state, .{});
        defer res.deinit();
        var spaces = try manager_mod.SpaceManager.open(allocator, io, cap_state, cap_checkouts, res);
        defer spaces.deinit();
        var projects = try project_mod.ProjectStore.open(allocator, io, cap_state);
        defer projects.deinit();
        var cdir = try Io.Dir.cwd().openDir(io, cap_state, .{ .iterate = true });
        defer cdir.close(io);
        var catalog = try thread_store.CatalogStore.open(allocator, io, cdir);
        defer catalog.deinit();
        const runner_id = id.newUuidV7(io);
        const device_id = id.newUuidV7(io);
        var keyring = keyring_mod.Keyring.initAccountDevice(allocator, io, crypto.AccountRootKey.generate(io), runner_id);
        defer keyring.deinit();
        var leases = try lease_mod.LeaseManager.init(allocator, io, cap_state, runner_id, null);
        defer leases.deinit();

        var rt = try thread_runtime.ThreadRuntime.init(allocator, io, .{
            .spaces = &spaces,
            .projects = &projects,
            .catalog = &catalog,
            .keyring = &keyring,
            .leases = &leases,
            .root_dir = cap_state,
            .runner_id = runner_id,
            .device_id = device_id,
            .shared_blobs = res.blob_pool,
        });
        defer rt.deinit();

        var api_rec = try spaces.adoptLocal(api_repo, "api");
        const api_id = api_rec.space_id;
        api_rec.deinit(allocator);
        var web_rec = try spaces.adoptLocal(web_repo, "web");
        const web_id = web_rec.space_id;
        web_rec.deinit(allocator);

        var proj = try projects.create("captain-2repo", "2-repo orchestration", 0, null);
        defer proj.deinit(allocator);
        try projects.addSpace(proj.project_id, .{ .space_id = api_id, .alias = @constCast("api"), .kind = .git_worktree, .default_access = 1 });
        try projects.addSpace(proj.project_id, .{ .space_id = web_id, .alias = @constCast("web"), .kind = .git_worktree, .default_access = 1 });

        const cap_bindings = [_]thread_model.SpaceBinding{
            .{ .space_id = api_id, .alias = @constCast("api"), .access = .shared_rw },
            .{ .space_id = web_id, .alias = @constCast("web"), .access = .shared_rw },
        };
        const sub_u64: u64 = @intCast(subordinates);
        const initial_max_tokens: u64 = @max(@as(u64, 200_000), (sub_u64 + 4) * 25_000);
        const initial_max_cost_microusd: u64 = @max(@as(u64, 200_000), (sub_u64 + 4) * 2_000_000);
        const initial_max_wall_ms: u64 = @max(@as(u64, 600_000), (sub_u64 + 4) * 60_000);
        const per_worker_carve: u64 = 10_000;
        const per_worker_used: u64 = 2_500;

        var cap_meta = try rt.createThread(.{
            .title = "Captain",
            .project_id = proj.project_id,
            .bindings = &cap_bindings,
            .provider_id = .mock,
            .budget = .{
                .max_tokens = initial_max_tokens,
                .max_cost_microusd = initial_max_cost_microusd,
                .max_wall_ms = initial_max_wall_ms,
                .max_depth = 4,
                .max_children = std.math.cast(u16, subordinates + 8) orelse std.math.maxInt(u16),
            },
        });
        defer cap_meta.deinit(allocator);

        var workers = try allocator.alloc(thread_runtime.SpawnSubordinateResult, subordinates);
        var spawned_count: usize = 0;
        defer {
            for (0..spawned_count) |k| workers[k].deinit(allocator);
            allocator.free(workers);
        }
        const dep_ids = try allocator.alloc(u128, subordinates);
        defer allocator.free(dep_ids);

        const parent_inbox_topic = thread_runtime.topicId(.mailbox, cap_meta.thread_id);
        const parent_thread_topic = thread_runtime.topicId(.thread, cap_meta.thread_id);

        var title_buf: [64]u8 = undefined;
        const fo0 = nowNs(io);
        for (0..subordinates) |k| {
            const sub_runner = id.newUuidV7(io);
            var sub_kr = keyring_mod.Keyring.initSubordinateDevice(allocator, io, sub_runner);
            defer sub_kr.deinit();

            const wtitle = try std.fmt.bufPrint(&title_buf, "worker-{d:0>2}", .{k});
            workers[k] = try rt.spawnSubordinate(allocator, cap_meta.thread_id, .{
                .title = wtitle,
                .prompt = "implement isolated change",
                .grants = &.{
                    .{ .space_id = api_id, .alias = @constCast("api"), .access = .isolated_fork },
                    .{ .space_id = web_id, .alias = @constCast("web"), .access = .isolated_fork },
                },
                .budget = .{
                    .max_tokens = per_worker_carve,
                    .max_cost_microusd = 1_000_000,
                    .max_wall_ms = 30_000,
                },
                .project_forks_locally = false,
                .target_runner_id = sub_runner,
                .target_runner_pubkey = sub_kr.device_keypair.public_key,
            });
            spawned_count += 1;
            dep_ids[k] = workers[k].task_id;

            try assertCond(workers[k].forked_space_ids.len == 2, "worker expected 2 COW forks");
            try assertCond(workers[k].sealed_delegation != null, "worker expected sealed X25519 delegation");
            const imported = try sub_kr.importDelegationBundle(workers[k].sealed_delegation.?);
            try assertCond(imported >= 4, "subordinate delegation import count too low");
            try assertCond(sub_kr.getTopicGrant(parent_thread_topic) == null, "subordinate must NOT receive parent thread key");
            const inbox_grant = sub_kr.getTopicGrant(parent_inbox_topic) orelse {
                try assertCond(false, "subordinate missing parent inbox grant");
                unreachable;
            };
            try assertCond(inbox_grant.perms == wire.PERM_INBOX_APPEND, "subordinate inbox grant must be PERM_INBOX_APPEND only");
        }

        var synth = try rt.spawnSubordinate(allocator, cap_meta.thread_id, .{
            .title = "synthesizer",
            .grants = &.{
                .{ .space_id = api_id, .alias = @constCast("api"), .access = .read_only },
                .{ .space_id = web_id, .alias = @constCast("web"), .access = .read_only },
            },
            .depends_on = dep_ids,
            .join_quorum = @intCast(subordinates),
            .budget = .{
                .max_tokens = per_worker_carve,
                .max_cost_microusd = 1_000_000,
                .max_wall_ms = 30_000,
            },
        });
        defer synth.deinit(allocator);
        fanout_ns = nowNs(io) -| fo0;
        try assertCond(synth.status == .pending, "fan-in synthesizer must start pending");

        var fname_buf: [64]u8 = undefined;
        var fbody_buf: [64]u8 = undefined;
        for (0..subordinates) |k| {
            const api_fork = try spaces.activate(workers[k].forked_space_ids[0]);
            const web_fork = try spaces.activate(workers[k].forked_space_ids[1]);
            const a_name = try std.fmt.bufPrint(&fname_buf, "workers/w_{d:0>3}_api.txt", .{k});
            const a_body = try std.fmt.bufPrint(&fbody_buf, "api work from {d}\n", .{k});
            _ = try api_fork.putFile(workers[k].child_thread_id, a_name, a_body);

            const w_name = try std.fmt.bufPrint(&fname_buf, "workers/w_{d:0>3}_web.txt", .{k});
            const w_body = try std.fmt.bufPrint(&fbody_buf, "web work from {d}\n", .{k});
            _ = try web_fork.putFile(workers[k].child_thread_id, w_name, w_body);
        }

        const st0 = nowNs(io);
        var synth_became_ready: usize = 0;
        for (0..subordinates) |k| {
            const became = try rt.settleTask(cap_meta.thread_id, workers[k].task_id, .completed, "worker done", .{
                .used_tokens = per_worker_used,
                .used_cost_microusd = 250_000,
                .used_wall_ms = 500,
            });
            synth_became_ready += became;
        }
        settle_ns = nowNs(io) -| st0;

        try assertCond(synth_became_ready == 1, "fan-in synthesizer did not transition to ready");
        const cap_store = try rt.openThread(cap_meta.thread_id);
        try assertCond(cap_store.tasks.get(synth.task_id).?.status == .ready, "synthesizer status must be ready");

        {
            var cm = (try rt.getThreadMeta(allocator, cap_meta.thread_id)).?;
            defer cm.deinit(allocator);
            const expected_used = @as(u64, @intCast(subordinates)) * per_worker_used + per_worker_carve;
            try assertCond(cm.budget.used_tokens == expected_used, "budget refund mismatch after settle");
        }

        const unread = try rt.unreadMailboxCount(cap_meta.thread_id);
        try assertCond(unread == subordinates, "mailbox unread count mismatch");
        const drained = try rt.drainMailbox(allocator, cap_meta.thread_id);
        defer {
            for (drained) |*m| m.deinit(allocator);
            allocator.free(drained);
        }
        try assertCond(drained.len == subordinates, "mailbox drain count mismatch");

        const ld0 = nowNs(io);
        for (0..subordinates) |k| {
            var rep = try rt.landSubordinateForks(allocator, cap_meta.thread_id, workers[k].task_id);
            defer rep.deinit(allocator);
            try assertCond(!rep.aborted, "landSubordinateForks unexpectedly aborted");
            try assertCond(rep.entries.len == 2, "landSubordinateForks expected 2 landed spaces");
        }
        land_ns = nowNs(io) -| ld0;

        {
            const api_sp = try spaces.activate(api_id);
            const web_sp = try spaces.activate(web_id);
            const check_a = try std.fmt.bufPrint(&fname_buf, "workers/w_{d:0>3}_api.txt", .{subordinates - 1});
            const got_a = (try api_sp.readFileAlloc(allocator, check_a)) orelse {
                try assertCond(false, "landed api file missing");
                unreachable;
            };
            allocator.free(got_a);
            const check_w = try std.fmt.bufPrint(&fname_buf, "workers/w_{d:0>3}_web.txt", .{subordinates - 1});
            const got_w = (try web_sp.readFileAlloc(allocator, check_w)) orelse {
                try assertCond(false, "landed web file missing");
                unreachable;
            };
            allocator.free(got_w);
        }

        var sub_parent = try rt.spawnSubordinate(allocator, cap_meta.thread_id, .{
            .title = "nested-parent",
            .grants = &.{.{ .space_id = api_id, .alias = @constCast("api"), .access = .read_only }},
            .budget = .{ .max_tokens = 20_000, .max_cost_microusd = 1_000_000, .max_wall_ms = 30_000, .max_depth = 3, .max_children = 4 },
        });
        defer sub_parent.deinit(allocator);

        var sub_grandchild = try rt.spawnSubordinate(allocator, sub_parent.child_thread_id, .{
            .title = "nested-grandchild",
            .grants = &.{.{ .space_id = api_id, .alias = @constCast("api"), .access = .read_only }},
            .budget = .{ .max_tokens = 5_000, .max_cost_microusd = 200_000, .max_wall_ms = 10_000 },
        });
        defer sub_grandchild.deinit(allocator);

        var bt_nested = try rt.beginTurn(sub_parent.child_thread_id, "in-flight nested work", .{});
        defer bt_nested.deinit(allocator);

        const ct0 = nowNs(io);
        const cancel_rep = try rt.cancelTree(sub_parent.child_thread_id, "bench cancel tree");
        cancel_ns = nowNs(io) -| ct0;
        cancel_threads = cancel_rep.canceled_threads;
        cancel_tasks = cancel_rep.canceled_tasks;
        try assertCond(cancel_threads >= 2, "cancelTree must cancel parent and grandchild threads");
        try assertCond(cancel_tasks >= 1, "cancelTree must cancel descendant task");

        var t1 = try rt.beginTurn(cap_meta.thread_id, "baseline turn", .{});
        defer t1.deinit(allocator);
        {
            const api_sp = try spaces.activate(api_id);
            const web_sp = try spaces.activate(web_id);
            _ = try api_sp.putFile(api_sp.actor_id, "rb_marker.txt", "baseline-api\n");
            _ = try web_sp.putFile(web_sp.actor_id, "rb_marker.txt", "baseline-web\n");
        }
        var post1 = try rt.completeTurn(cap_meta.thread_id, t1.turn_id, "baseline saved", &.{}, .{}, null);
        defer post1.deinit(allocator);

        var t2 = try rt.beginTurn(cap_meta.thread_id, "mutate turn", .{});
        defer t2.deinit(allocator);
        {
            const api_sp = try spaces.activate(api_id);
            const web_sp = try spaces.activate(web_id);
            _ = try api_sp.putFile(api_sp.actor_id, "rb_marker.txt", "mutated-api\n");
            _ = try web_sp.putFile(web_sp.actor_id, "rb_marker.txt", "mutated-web\n");
        }
        var post2 = try rt.completeTurn(cap_meta.thread_id, t2.turn_id, "mutated", &.{}, .{}, null);
        defer post2.deinit(allocator);

        const partial = try rt.rollbackThreadToMessage(cap_meta.thread_id, t1.turn_id, .{
            .simulate_crash_after_space_index = 0,
        });
        try assertCond(!partial.completed, "simulated crash rollback must report incomplete");
        try assertCond(partial.spaces_rolled_back == 1, "simulated crash rollback must roll back exactly 1 space");

        rt.closeThread(cap_meta.thread_id);
        const reopened = try rt.openThread(cap_meta.thread_id);
        try assertCond(reopened.pendingRollback() != null, "reopened thread must detect pending RollbackIntent");

        const rr0 = nowNs(io);
        const rec = (try rt.recoverPendingRollbacks(cap_meta.thread_id)) orelse {
            try assertCond(false, "recoverPendingRollbacks returned null");
            unreachable;
        };
        recovery_ns = nowNs(io) -| rr0;
        try assertCond(rec.completed, "rollback recovery must complete");
        try assertCond(reopened.pendingRollback() == null, "pending rollback intent must be cleared after recovery");

        {
            const api_after = (try (try spaces.activate(api_id)).readFileAlloc(allocator, "rb_marker.txt")).?;
            defer allocator.free(api_after);
            const web_after = (try (try spaces.activate(web_id)).readFileAlloc(allocator, "rb_marker.txt")).?;
            defer allocator.free(web_after);
            try assertCond(std.mem.eql(u8, api_after, "baseline-api\n"), "api not restored after crash recovery");
            try assertCond(std.mem.eql(u8, web_after, "baseline-web\n"), "web not restored after crash recovery");
        }
    }

    const final_metrics = readProcMetrics(allocator, io);
    try out.print("\n--- Agents & Virtual Summary ---\n", .{});
    try out.print("  zero_repo_50turns_us_per_turn={d:.2} total_ms={d:.2} spaces_opened=0 extra_fds={d}\n", .{
        usFromNs(zero_turns_ns) / 50.0, msFromNs(zero_turns_ns), zero_fd_delta,
    });
    try out.print("  virtual_500writes_ms={d:.2} us_per_write={d:.2} search_ms={d:.2} hits={d} timeline_ms={d:.2} entries={d}\n", .{
        msFromNs(virt_writes_ns),
        usFromNs(virt_writes_ns) / 500.0,
        msFromNs(virt_search_ns),
        virt_search_hits,
        msFromNs(virt_timeline_ns),
        virt_timeline_entries,
    });
    try out.print("  virtual_ckpt_ms={d:.2} cold_reopen_ms={d:.2} rollback_ms={d:.2} disk_checkouts=0 watches=0\n", .{
        msFromNs(virt_ckpt_ns), msFromNs(virt_cold_ns), msFromNs(virt_rb_ns),
    });
    try out.print("  captain_fanout_{d}_ms={d:.2} avg_ms={d:.2} settle_all_ms={d:.2} land_all_ms={d:.2}\n", .{
        subordinates,
        msFromNs(fanout_ns),
        msFromNs(fanout_ns) / @as(f64, @floatFromInt(subordinates)),
        msFromNs(settle_ns),
        msFromNs(land_ns),
    });
    try out.print("  cancel_tree_ms={d:.2} threads={d} tasks={d} rollback_crash_recovery_ms={d:.2}\n", .{
        msFromNs(cancel_ns), cancel_threads, cancel_tasks, msFromNs(recovery_ns),
    });
    try out.print("  final_rss_mb={d:.2} hwm_mb={d:.2} open_fds={d} threads={d}\n", .{
        mbFromKb(final_metrics.vm_rss_kb), mbFromKb(final_metrics.vm_hwm_kb), final_metrics.open_fds, final_metrics.threads,
    });
    try out.print("RESULT: PASS (bench-agents)\n", .{});
    try out.flush();
}
