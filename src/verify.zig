const std = @import("std");
const testing = std.testing;
const ondb = @import("ondb");

fn cleanDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "crdt convergence, blame, exact rollback, and append log crash recovery" {
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_root = "/tmp/0ndb-verify-crdt";
    cleanDir(io, tmp_root);
    defer cleanDir(io, tmp_root);

    var h1 = try ondb.core.history.History.init(allocator, 42);
    defer h1.deinit();
    var h2 = try ondb.core.history.History.init(allocator, 42);
    defer h2.deinit();

    const actor_a: ondb.core.id.ActorId = 100;
    const actor_b: ondb.core.id.ActorId = 200;

    var base_ops = [_]ondb.core.op.Op{.{ .create_file = .{
        .parent = ondb.core.id.InodeId.ROOT,
        .name = try allocator.dupe(u8, "main.zig"),
        .mode = .regular,
        .line_ending = .lf,
        .content = .{ .text_inline = try allocator.dupe(u8, "hello world\n") },
    } }};
    var b0 = ondb.core.op.Batch{
        .header = .{ .actor = actor_a, .start = 1, .end = 1, .parents = ondb.core.version.Version.ROOT, .wall_ms = 1 },
        .ops = &base_ops,
        .blobs = &.{},
    };
    defer {
        for (&base_ops) |*o| o.deinit(allocator);
    }
    try testing.expect(try h1.integrate(&b0));
    try testing.expect(try h2.integrate(&b0));

    const file_iid = (try h1.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "main.zig")).?;
    var p_after_b0 = try h1.headsClone();
    defer p_after_b0.deinit(allocator);

    var s1 = [_]ondb.core.diff.Splice{.{ .at = 5, .del = 0, .ins = 4 }};
    var ops_a = [_]ondb.core.op.Op{.{ .edit_text = .{
        .inode = file_iid,
        .text = try allocator.dupe(u8, " zig"),
        .splices = &s1,
    } }};
    var ba = ondb.core.op.Batch{
        .header = .{ .actor = actor_a, .start = 2, .end = 2, .parents = try p_after_b0.clone(allocator), .wall_ms = 2 },
        .ops = &ops_a,
        .blobs = &.{},
    };
    defer {
        ba.header.parents.deinit(allocator);
        allocator.free(ops_a[0].edit_text.text);
    }

    var s2 = [_]ondb.core.diff.Splice{.{ .at = 11, .del = 0, .ins = 1 }};
    var ops_b = [_]ondb.core.op.Op{.{ .edit_text = .{
        .inode = file_iid,
        .text = try allocator.dupe(u8, "!"),
        .splices = &s2,
    } }};
    var bb = ondb.core.op.Batch{
        .header = .{ .actor = actor_b, .start = 2, .end = 2, .parents = try p_after_b0.clone(allocator), .wall_ms = 2 },
        .ops = &ops_b,
        .blobs = &.{},
    };
    defer {
        bb.header.parents.deinit(allocator);
        allocator.free(ops_b[0].edit_text.text);
    }

    try testing.expect(try h1.integrate(&ba));
    try testing.expect(try h1.integrate(&bb));
    try testing.expect(try h2.integrate(&bb));
    try testing.expect(try h2.integrate(&ba));

    const r1 = (try h1.readFileAt(allocator, "main.zig", null)).?;
    defer allocator.free(r1);
    const r2 = (try h2.readFileAt(allocator, "main.zig", null)).?;
    defer allocator.free(r2);
    try testing.expectEqualStrings(r1, r2);
    try testing.expectEqualStrings("hello zig world!\n", r1);

    var blame = (try h1.blameFile(allocator, "main.zig")).?;
    defer {
        for (blame.items) |*l| l.deinit(allocator);
        blame.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), blame.items.len);
    try testing.expectEqualStrings("hello zig world!", blame.items[0].text);

    var rb_batch = (try h1.buildRollbackBatch(allocator, actor_a, &p_after_b0, 3)).?;
    defer rb_batch.deinit(allocator);
    try testing.expect(try h1.integrate(&rb_batch));
    const after_rb = (try h1.readFileAt(allocator, "main.zig", null)).?;
    defer allocator.free(after_rb);
    try testing.expectEqualStrings("hello world\n", after_rb);

    try std.Io.Dir.cwd().createDirPath(io, tmp_root);
    var dir = try std.Io.Dir.cwd().openDir(io, tmp_root, .{ .iterate = true });
    defer dir.close(io);
    {
        var log = try ondb.store.log.AppendLog.open(allocator, io, dir, "crash.0ndb", true);
        defer log.deinit();
        _ = try log.append(1, 0, 10, "frame-one");
        _ = try log.append(1, 0, 20, "frame-two");
    }
    {
        const f = try dir.openFile(io, "crash.0ndb", .{ .mode = .read_write });
        defer f.close(io);
        const st = try f.stat(io);
        try f.writePositionalAll(io, "corrupt-torn-tail", st.size);
    }
    {
        var log = try ondb.store.log.AppendLog.open(allocator, io, dir, "crash.0ndb", true);
        defer log.deinit();
        try testing.expectEqual(@as(usize, 2), log.count());
        const v1 = try log.readAt(0);
        const v2 = try log.readAt(1);
        try testing.expectEqualStrings("frame-one", v1.payload);
        try testing.expectEqualStrings("frame-two", v2.payload);
    }

    const ws_root = "/tmp/0ndb-verify-reactive";
    const ws_state = "/tmp/0ndb-verify-reactive-state";
    cleanDir(io, ws_root);
    cleanDir(io, ws_state);
    defer cleanDir(io, ws_root);
    defer cleanDir(io, ws_state);

    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, ws_root, ws_state, 77);
    defer ws.deinit();

    const ObsCtx = struct {
        calls: usize = 0,
        last_splices: usize = 0,
        fn onCommit(ptr: *anyopaque, _: []const u8, delta: *const ondb.core.history.CommitDelta) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.last_splices = if (delta.files.len > 0) delta.files[0].splices.len else 0;
        }
    };
    var obs_ctx = ObsCtx{};
    ws.setObserver(.{ .ptr = &obs_ctx, .on_commit = ObsCtx.onCommit });

    _ = try ws.writeFileDirect(actor_a, "src/deep/file.zig", "const a = 1;\nconst b = 2;\nconst c = 3;\n");
    _ = try ws.writeFileDirect(actor_a, "src/deep/other.zig", "const ok = true;\n");
    try testing.expect(obs_ctx.calls >= 2);
    try testing.expect(obs_ctx.last_splices >= 1);

    var heads_before = try ws.history.headsClone();
    defer heads_before.deinit(allocator);
    const base_ver_str = try heads_before.formatHex(allocator);
    defer allocator.free(base_ver_str);
    var base_ver = try ondb.core.version.Version.parseHex(allocator, base_ver_str);
    defer base_ver.deinit(allocator);

    _ = try ws.writeFileDirect(actor_b, "src/deep/file.zig", "const a = 100;\nconst b = 2;\nconst c = 3;\n");

    const user_draft = "const a = 1;\nconst b = 2;\nconst c = 300;\n";
    const cursor_pos = std.mem.indexOf(u8, user_draft, "300").? + 3;
    const batches_before = ws.history.dag.count();

    var rb = (try ws.rebaseBuffer(allocator, "src/deep/file.zig", &base_ver, user_draft, cursor_pos, cursor_pos)).?;
    defer rb.deinit(allocator);
    try testing.expectEqual(batches_before, ws.history.dag.count());
    try testing.expectEqual(@as(usize, 1), rb.splices.len);
    try testing.expectEqual(@as(usize, 11), rb.splices[0].at);
    try testing.expectEqual(@as(usize, 0), rb.splices[0].del);
    try testing.expectEqualStrings("00", rb.splices[0].text);
    try testing.expectEqual(cursor_pos + 2, rb.cursor_start);
    try testing.expectEqual(cursor_pos + 2, rb.cursor_end);

    var commit_res = try ws.writeFileAtBase(actor_a, "src/deep/file.zig", &base_ver, user_draft, "editor");
    defer commit_res.deinit(allocator);
    try testing.expect(commit_res.concurrent_merged);
    try testing.expectEqualStrings("const a = 100;\nconst b = 2;\nconst c = 300;\n", commit_res.content);

    try ws.attachWatcher();
    const WakeCtx = struct {
        ws_ptr: *ondb.fs.workspace.Workspace,
        io_val: std.Io,
        fn run(ctx: *@This()) void {
            ctx.io_val.sleep(.fromMilliseconds(15), .awake) catch {};
            ctx.ws_ptr.wakeWatcher();
        }
    };
    var wake_ctx = WakeCtx{ .ws_ptr = &ws, .io_val = io };
    const t = try std.Thread.spawn(.{}, WakeCtx.run, .{&wake_ctx});
    const wait_res = ws.waitWatcher(-1);
    t.join();
    try testing.expect(wait_res.woken);

    const live_sub = ws_root ++ "/live_dir";
    try std.Io.Dir.cwd().createDirPath(io, live_sub);
    {
        const f = try std.Io.Dir.cwd().createFile(io, live_sub ++ "/hello.zig", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "const live = 42;\n");
    }
    const step = try ws.watchStep(500, "watch");
    try testing.expect(step.batch_id != null);
    const live_content = (try ws.history.readFileAt(allocator, "live_dir/hello.zig", null)).?;
    defer allocator.free(live_content);
    try testing.expectEqualStrings("const live = 42;\n", live_content);

    {
        var old_big: std.ArrayList(u8) = .empty;
        defer old_big.deinit(allocator);
        var new_big: std.ArrayList(u8) = .empty;
        defer new_big.deinit(allocator);
        for (0..5000) |li| {
            try old_big.print(allocator, "const line_{d}: u64 = {d};\n", .{ li, li * 7 });
            if (li == 5) {
                try new_big.print(allocator, "const line_{d}: u64 = 999999;\n", .{li});
            } else if (li == 4995) {
                try new_big.print(allocator, "const line_{d}: u64 = 888888;\n", .{li});
            } else {
                try new_big.print(allocator, "const line_{d}: u64 = {d};\n", .{ li, li * 7 });
            }
        }
        var d_big = try ondb.core.diff.diffBytes(allocator, old_big.items, new_big.items);
        defer d_big.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), d_big.splices.items.len);
        const rec_big = try applyDiffForVerify(allocator, old_big.items, d_big.splices.items, d_big.inserted.items);
        defer allocator.free(rec_big);
        try testing.expectEqualStrings(new_big.items, rec_big);

        var old_rep: std.ArrayList(u8) = .empty;
        defer old_rep.deinit(allocator);
        var new_rep: std.ArrayList(u8) = .empty;
        defer new_rep.deinit(allocator);
        for (0..500) |li| {
            const line = if (li % 2 == 0) "alpha\n" else "beta\n";
            try old_rep.appendSlice(allocator, line);
            if (li == 100 or li == 250 or li == 400) {
                try new_rep.appendSlice(allocator, "gamma\n");
            } else {
                try new_rep.appendSlice(allocator, line);
            }
        }
        var d_rep = try ondb.core.diff.diffBytes(allocator, old_rep.items, new_rep.items);
        defer d_rep.deinit(allocator);
        try testing.expect(d_rep.splices.items.len <= 6);
        const rec_rep = try applyDiffForVerify(allocator, old_rep.items, d_rep.splices.items, d_rep.inserted.items);
        defer allocator.free(rec_rep);
        try testing.expectEqualStrings(new_rep.items, rec_rep);
    }

    {
        var ca = try ondb.core.history.History.init(allocator, 555);
        defer ca.deinit();
        var cb = try ondb.core.history.History.init(allocator, 555);
        defer cb.deinit();

        const actor_c: ondb.core.id.ActorId = 300;
        var init_buf: std.ArrayList(u8) = .empty;
        defer init_buf.deinit(allocator);
        for (0..60) |li| {
            try init_buf.print(allocator, "row-{d:0>3}: payload\n", .{li});
        }
        var c_ops = [_]ondb.core.op.Op{.{ .create_file = .{
            .parent = ondb.core.id.InodeId.ROOT,
            .name = try allocator.dupe(u8, "multi.txt"),
            .mode = .regular,
            .line_ending = .lf,
            .content = .{ .text_inline = try allocator.dupe(u8, init_buf.items) },
        } }};
        var cb0 = ondb.core.op.Batch{
            .header = .{ .actor = actor_a, .start = 1, .end = 1, .parents = ondb.core.version.Version.ROOT, .wall_ms = 1 },
            .ops = &c_ops,
            .blobs = &.{},
        };
        defer {
            for (&c_ops) |*o| o.deinit(allocator);
        }
        try testing.expect(try ca.integrate(&cb0));
        try testing.expect(try cb.integrate(&cb0));

        const multi_iid = (try ca.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "multi.txt")).?;
        var v_base = try ca.headsClone();
        defer v_base.deinit(allocator);
        var v_mid: ?ondb.core.version.Version = null;
        defer if (v_mid) |*vm| vm.deinit(allocator);

        var seq_batches: std.ArrayList(ondb.core.op.Batch) = .empty;
        defer {
            for (seq_batches.items) |*b| b.deinit(allocator);
            seq_batches.deinit(allocator);
        }

        var a_ts: u64 = 2;
        for (0..40) |step_i| {
            var p = try ca.headsClone();
            errdefer p.deinit(allocator);
            const sp = try allocator.alloc(ondb.core.diff.Splice, 1);
            errdefer allocator.free(sp);
            const ins_text = try std.fmt.allocPrint(allocator, "a-{d:0>2}\n", .{step_i});
            errdefer allocator.free(ins_text);
            sp[0] = .{ .at = @intCast((step_i % 20) * 17), .del = 0, .ins = @intCast(ins_text.len) };
            const ops_arr = try allocator.alloc(ondb.core.op.Op, 1);
            ops_arr[0] = .{ .edit_text = .{ .inode = multi_iid, .text = ins_text, .splices = sp } };
            const b = ondb.core.op.Batch{
                .header = .{ .actor = actor_a, .start = a_ts, .end = a_ts, .parents = p, .wall_ms = a_ts },
                .ops = ops_arr,
                .blobs = &.{},
            };
            a_ts += 1;
            try seq_batches.append(allocator, b);
            try testing.expect(try ca.integrate(&seq_batches.items[seq_batches.items.len - 1]));
            if (step_i == 35) {
                v_mid = try ca.headsClone();
            }
        }

        const f_node = ca.tree.get(multi_iid).?.fileConstPtr().?;
        const expected_lines = f_node.text.lineCount();
        try testing.expectEqual(@as(usize, 100), expected_lines);
        const full_ca = (try ca.readFileAt(allocator, "multi.txt", null)).?;
        defer allocator.free(full_ca);

        var snap = f_node.text.share();
        defer snap.deinit(allocator);
        const range_lines = (try ca.readFileLines(allocator, "multi.txt", 40, 10)).?;
        defer allocator.free(range_lines);
        const manual_lines = sliceLinesForVerify(full_ca, 40, 10);
        try testing.expectEqualStrings(manual_lines, range_lines);
        const range_bytes = (try f_node.text.readByteRange(allocator, ca.resolver(), 120, 64)).?;
        defer allocator.free(range_bytes);
        try testing.expectEqualStrings(full_ca[120..184], range_bytes);

        var sp_b = [_]ondb.core.diff.Splice{
            .{ .at = 34, .del = 17, .ins = 12 },
            .{ .at = 510, .del = 34, .ins = 14 },
        };
        var ops_bb = [_]ondb.core.op.Op{.{ .edit_text = .{
            .inode = multi_iid,
            .text = try allocator.dupe(u8, "B-REPLACE-1\nB-REPLACE-222\n"),
            .splices = &sp_b,
        } }};
        var batch_b = ondb.core.op.Batch{
            .header = .{ .actor = actor_b, .start = 2, .end = 2, .parents = try v_base.clone(allocator), .wall_ms = 2 },
            .ops = &ops_bb,
            .blobs = &.{},
        };
        defer {
            batch_b.header.parents.deinit(allocator);
            allocator.free(ops_bb[0].edit_text.text);
        }

        var sp_c = [_]ondb.core.diff.Splice{
            .{ .at = 10, .del = 5, .ins = 8 },
        };
        var ops_cc = [_]ondb.core.op.Op{.{ .edit_text = .{
            .inode = multi_iid,
            .text = try allocator.dupe(u8, "C-PATCH\n"),
            .splices = &sp_c,
        } }};
        var batch_c = ondb.core.op.Batch{
            .header = .{ .actor = actor_c, .start = 50, .end = 50, .parents = try v_mid.?.clone(allocator), .wall_ms = 50 },
            .ops = &ops_cc,
            .blobs = &.{},
        };
        defer {
            batch_c.header.parents.deinit(allocator);
            allocator.free(ops_cc[0].edit_text.text);
        }

        try testing.expect(try ca.integrate(&batch_b));
        try testing.expect(try ca.integrate(&batch_c));

        const snap_bytes = (try snap.read(allocator, ca.resolver())).?;
        defer allocator.free(snap_bytes);
        try testing.expectEqualStrings(full_ca, snap_bytes);

        try testing.expect(try cb.integrate(&batch_b));
        for (seq_batches.items) |*sb| {
            try testing.expect(try cb.integrate(sb));
        }
        try testing.expect(try cb.integrate(&batch_c));

        const final_a = (try ca.readFileAt(allocator, "multi.txt", null)).?;
        defer allocator.free(final_a);
        const final_b = (try cb.readFileAt(allocator, "multi.txt", null)).?;
        defer allocator.free(final_b);
        try testing.expectEqualStrings(final_a, final_b);
        try testing.expectEqual(
            ca.tree.get(multi_iid).?.fileConstPtr().?.text.lineCount(),
            cb.tree.get(multi_iid).?.fileConstPtr().?.text.lineCount(),
        );
        try testing.expectEqual(countLinesExact(final_a), ca.tree.get(multi_iid).?.fileConstPtr().?.text.lineCount());

        var rb_multi = (try ca.buildRollbackBatch(allocator, actor_a, &v_base, 200)).?;
        defer rb_multi.deinit(allocator);
        try testing.expect(try ca.integrate(&rb_multi));
        const restored_multi = (try ca.readFileAt(allocator, "multi.txt", null)).?;
        defer allocator.free(restored_multi);
        try testing.expectEqualStrings(init_buf.items, restored_multi);
        try testing.expectEqual(@as(usize, 60), ca.tree.get(multi_iid).?.fileConstPtr().?.text.lineCount());
    }

    {
        var big_blob: std.ArrayList(u8) = .empty;
        defer big_blob.deinit(allocator);
        for (0..800) |li| {
            try big_blob.print(allocator, "blob line {d:0>4} with enough padding bytes to exceed 4096 bytes!\n", .{li});
        }
        _ = try ws.writeFileDirect(actor_a, "big/blob.txt", big_blob.items);
        try big_blob.appendSlice(allocator, "appended tail line\n");
        _ = try ws.writeFileDirect(actor_a, "big/blob.txt", big_blob.items);
        try testing.expectEqual(@as(usize, 0), ws.history.ownedHeapBytes());

        ws.hibernate();
        const after_hib = (try ws.history.readFileAt(allocator, "big/blob.txt", null)).?;
        defer allocator.free(after_hib);
        try testing.expectEqualStrings(big_blob.items, after_hib);
        try testing.expectEqual(@as(usize, 0), ws.history.ownedHeapBytes());

        var ws2 = try ondb.fs.workspace.Workspace.open(allocator, io, ws_root, ws_state, 77);
        defer ws2.deinit();
        try testing.expectEqual(@as(usize, 0), ws2.history.ownedHeapBytes());
        const reopened = (try ws2.history.readFileAt(allocator, "big/blob.txt", null)).?;
        defer allocator.free(reopened);
        try testing.expectEqualStrings(big_blob.items, reopened);
        const tail_line = (try ws2.history.readFileLines(allocator, "big/blob.txt", 800, 1)).?;
        defer allocator.free(tail_line);
        try testing.expectEqualStrings("appended tail line\n", tail_line);
    }

    {
        {
            var log = try ondb.store.log.AppendLog.open(allocator, io, dir, "blake3.0ndb", true);
            defer log.deinit();
            _ = try log.append(1, 0, 10, "frame-one");
            _ = try log.append(1, 0, 20, "frame-two");
        }
        {
            const f = try dir.openFile(io, "blake3.0ndb", .{ .mode = .read_write });
            defer f.close(io);
            var hdr_buf: [ondb.store.log.HEADER_SIZE]u8 = undefined;
            _ = try f.readPositionalAll(io, &hdr_buf, 48);
            var pay_buf: [9]u8 = undefined;
            _ = try f.readPositionalAll(io, &pay_buf, 48 + ondb.store.log.HEADER_SIZE);
            pay_buf[0] ^= 0x20;
            var crc = std.hash.crc.@"CRC-32/ISCSI".init();
            crc.update(hdr_buf[0..20]);
            crc.update(hdr_buf[24..32]);
            crc.update(&pay_buf);
            std.mem.writeInt(u32, hdr_buf[20..24], crc.final(), .little);
            try f.writePositionalAll(io, &hdr_buf, 48);
            try f.writePositionalAll(io, &pay_buf, 48 + ondb.store.log.HEADER_SIZE);
        }
        {
            var log = try ondb.store.log.AppendLog.open(allocator, io, dir, "blake3.0ndb", true);
            defer log.deinit();
            try testing.expectEqual(@as(usize, 1), log.count());
            const v1 = try log.readAt(0);
            try testing.expectEqualStrings("frame-one", v1.payload);
        }
    }

    {
        var h_guard = try ondb.core.history.History.init(allocator, 888);
        defer h_guard.deinit();
        var bad_ops_max = [_]ondb.core.op.Op{.{ .create_file = .{
            .parent = ondb.core.id.InodeId.ROOT,
            .name = try allocator.dupe(u8, "evil.zig"),
            .mode = .regular,
            .line_ending = .lf,
            .content = .{ .text_inline = try allocator.dupe(u8, "x") },
        } }};
        defer for (&bad_ops_max) |*o| o.deinit(allocator);
        var evil_max = ondb.core.op.Batch{
            .header = .{
                .actor = actor_b,
                .start = std.math.maxInt(u64),
                .end = std.math.maxInt(u64),
                .parents = ondb.core.version.Version.ROOT,
                .wall_ms = 1,
            },
            .ops = &bad_ops_max,
            .blobs = &.{},
        };
        try testing.expectError(error.LamportViolation, h_guard.integrate(&evil_max));

        var evil_jump = ondb.core.op.Batch{
            .header = .{
                .actor = actor_b,
                .start = ondb.core.dag.Dag.MAX_LAMPORT_JUMP + 10,
                .end = ondb.core.dag.Dag.MAX_LAMPORT_JUMP + 10,
                .parents = ondb.core.version.Version.ROOT,
                .wall_ms = 1,
            },
            .ops = &bad_ops_max,
            .blobs = &.{},
        };
        try testing.expectError(error.LamportViolation, h_guard.integrate(&evil_jump));
    }

    {
        const vcs_probe = "/tmp/0ndb-verify-vcs-probe";
        cleanDir(io, vcs_probe);
        defer cleanDir(io, vcs_probe);
        try std.Io.Dir.cwd().createDirPath(io, vcs_probe);
        try testing.expectEqual(ondb.fs.vcs.VcsKind.none, ondb.fs.vcs.detectKind(io, vcs_probe));
        try testing.expectEqual(ondb.fs.vcs.VcsKind.none, ondb.fs.vcs.backendFor(.none).kind);
        try std.Io.Dir.cwd().createDirPath(io, vcs_probe ++ "/.git");
        try testing.expectEqual(ondb.fs.vcs.VcsKind.git, ondb.fs.vcs.detectKind(io, vcs_probe));
        try testing.expectEqual(ondb.fs.vcs.VcsKind.git, ondb.fs.vcs.backendFor(.git).kind);

        const wt_state = "/tmp/0ndb-verify-wt-state";
        const wt_checkouts = "/tmp/0ndb-verify-wt-checkouts";
        const wt_plain = "/tmp/0ndb-verify-wt-plain";
        cleanDir(io, wt_state);
        cleanDir(io, wt_checkouts);
        cleanDir(io, wt_plain);
        defer cleanDir(io, wt_state);
        defer cleanDir(io, wt_checkouts);
        defer cleanDir(io, wt_plain);

        try std.Io.Dir.cwd().createDirPath(io, wt_plain);
        {
            const f1 = try std.Io.Dir.cwd().createFile(io, wt_plain ++ "/clean.txt", .{ .truncate = true });
            defer f1.close(io);
            try f1.writeStreamingAll(io, "line-1\nline-2\nline-3\nline-4\nline-5\n");
            const f2 = try std.Io.Dir.cwd().createFile(io, wt_plain ++ "/clash.txt", .{ .truncate = true });
            defer f2.close(io);
            try f2.writeStreamingAll(io, "header\nshared-line\nfooter\n");
        }

        var wts = try ondb.fs.worktrees.Worktrees.open(allocator, io, wt_state, wt_checkouts);
        defer wts.deinit();

        var main_wt = try wts.adopt(wt_plain, "plain-main");
        defer main_wt.deinit(allocator);
        try testing.expectEqual(ondb.fs.vcs.VcsKind.none, main_wt.vcs_kind);

        var fork_wt = try wts.fork(main_wt.id, "feature-a", null, null);
        defer fork_wt.deinit(allocator);
        try testing.expectEqual(main_wt.history_id, fork_wt.history_id);

        const main_ws = wts.getWorkspace(main_wt.id).?;
        const fork_ws = wts.getWorkspace(fork_wt.id).?;

        _ = try main_ws.writeFileDirect(actor_a, "clean.txt", "line-1-main\nline-2\nline-3\nline-4\nline-5\n");
        _ = try fork_ws.writeFileDirect(actor_b, "clean.txt", "line-1\nline-2\nline-3\nline-4\nline-5-fork\n");

        _ = try main_ws.writeFileDirect(actor_a, "clash.txt", "header\nmain-choice\nfooter\n");
        _ = try fork_ws.writeFileDirect(actor_b, "clash.txt", "header\nfork-choice\nfooter\n");

        var sync_rep = try wts.syncFork(fork_wt.id);
        defer sync_rep.deinit(allocator);
        try testing.expect(sync_rep.brought >= 2);
        try testing.expectEqual(@as(usize, 1), sync_rep.merged.len);
        try testing.expectEqualStrings("clean.txt", sync_rep.merged[0]);
        try testing.expectEqual(@as(usize, 1), sync_rep.conflicts.len);
        try testing.expectEqualStrings("clash.txt", sync_rep.conflicts[0].path);
        try testing.expectEqual(ondb.fs.worktrees.ConflictKind.text, sync_rep.conflicts[0].kind);

        const clean_merged = (try fork_ws.history.readFileAt(allocator, "clean.txt", null)).?;
        defer allocator.free(clean_merged);
        try testing.expectEqualStrings("line-1-main\nline-2\nline-3\nline-4\nline-5-fork\n", clean_merged);

        const clash_marked = (try fork_ws.history.readFileAt(allocator, "clash.txt", null)).?;
        defer allocator.free(clash_marked);
        try testing.expect(std.mem.indexOf(u8, clash_marked, "<<<<<<< ours") != null);

        try testing.expectError(error.UnresolvedConflicts, wts.landFork(fork_wt.id));

        try wts.resolveConflict(fork_wt.id, "clash.txt", .{ .content = "header\nresolved-both\nfooter\n" });
        const after_res = try wts.conflicts(fork_wt.id);
        defer allocator.free(after_res);
        try testing.expectEqual(@as(usize, 0), after_res.len);

        var land_rep = try wts.landFork(fork_wt.id);
        defer land_rep.deinit(allocator);
        try testing.expect(land_rep.landed >= 1);

        const main_clean = (try main_ws.history.readFileAt(allocator, "clean.txt", null)).?;
        defer allocator.free(main_clean);
        try testing.expectEqualStrings("line-1-main\nline-2\nline-3\nline-4\nline-5-fork\n", main_clean);

        const main_clash = (try main_ws.history.readFileAt(allocator, "clash.txt", null)).?;
        defer allocator.free(main_clash);
        try testing.expectEqualStrings("header\nresolved-both\nfooter\n", main_clash);

        var scratch_wt = try wts.scratch("quick-note");
        defer scratch_wt.deinit(allocator);
        _ = try wts.getWorkspace(scratch_wt.id).?.writeFileDirect(actor_a, "note.txt", "hi\n");
        try testing.expectError(error.DirtyWorktree, wts.remove(scratch_wt.id, false, false));
        try wts.remove(scratch_wt.id, true, false);
    }

    {
        const u_old = "prefix 😀🎉 suffix\nhello 日本語 world\n";
        const u_new = "prefix 😀🚀 suffix\nhello 日語 world\n";
        var u_diff = try ondb.core.diff.diffBytes(allocator, u_old, u_new);
        defer u_diff.deinit(allocator);
        var u_ins_off: usize = 0;
        for (u_diff.splices.items) |sp| {
            const at: usize = @intCast(sp.at);
            const del: usize = @intCast(sp.del);
            const ins: usize = @intCast(sp.ins);
            if (at < u_old.len) try testing.expect((u_old[at] & 0xc0) != 0x80);
            if (at + del < u_old.len) try testing.expect((u_old[at + del] & 0xc0) != 0x80);
            const seg = u_diff.inserted.items[u_ins_off .. u_ins_off + ins];
            try testing.expect(std.unicode.utf8ValidateSlice(seg));
            u_ins_off += ins;
        }
        const u_rec = try applyDiffForVerify(allocator, u_old, u_diff.splices.items, u_diff.inserted.items);
        defer allocator.free(u_rec);
        try testing.expectEqualStrings(u_new, u_rec);
    }

    {
        var hi1 = try ondb.core.history.History.init(allocator, 910);
        defer hi1.deinit();
        var hi2 = try ondb.core.history.History.init(allocator, 910);
        defer hi2.deinit();

        const created_iid = ondb.core.id.InodeId.init(.{ .actor = actor_a, .ts = 1 }, 0);
        var sp_inline = [_]ondb.core.diff.Splice{.{ .at = 5, .del = 0, .ins = 6 }};
        var multi_ops = [_]ondb.core.op.Op{
            .{ .create_file = .{
                .parent = ondb.core.id.InodeId.ROOT,
                .name = try allocator.dupe(u8, "intra.txt"),
                .mode = .regular,
                .line_ending = .lf,
                .content = .{ .text_inline = try allocator.dupe(u8, "hello\n") },
            } },
            .{ .edit_text = .{
                .inode = created_iid,
                .text = try allocator.dupe(u8, " world"),
                .splices = &sp_inline,
            } },
        };
        defer {
            multi_ops[0].deinit(allocator);
            allocator.free(multi_ops[1].edit_text.text);
        }
        var b_intra = ondb.core.op.Batch{
            .header = .{ .actor = actor_a, .start = 1, .end = 2, .parents = ondb.core.version.Version.ROOT, .wall_ms = 1 },
            .ops = &multi_ops,
            .blobs = &.{},
        };
        var other_ops = [_]ondb.core.op.Op{.{ .create_file = .{
            .parent = ondb.core.id.InodeId.ROOT,
            .name = try allocator.dupe(u8, "peer.txt"),
            .mode = .regular,
            .line_ending = .lf,
            .content = .{ .text_inline = try allocator.dupe(u8, "peer\n") },
        } }};
        defer other_ops[0].deinit(allocator);
        var b_peer = ondb.core.op.Batch{
            .header = .{ .actor = actor_b, .start = 1, .end = 1, .parents = ondb.core.version.Version.ROOT, .wall_ms = 1 },
            .ops = &other_ops,
            .blobs = &.{},
        };

        try testing.expect(try hi1.integrate(&b_peer));
        try testing.expect(try hi1.integrate(&b_intra));
        try testing.expect(try hi2.integrate(&b_intra));
        try testing.expect(try hi2.integrate(&b_peer));
        const r_i1 = (try hi1.readFileAt(allocator, "intra.txt", null)).?;
        defer allocator.free(r_i1);
        const r_i2 = (try hi2.readFileAt(allocator, "intra.txt", null)).?;
        defer allocator.free(r_i2);
        try testing.expectEqualStrings("hello world\n", r_i1);
        try testing.expectEqualStrings(r_i1, r_i2);

        var p_sc = try hi1.headsClone();
        defer p_sc.deinit(allocator);
        var sp_a = [_]ondb.core.diff.Splice{.{ .at = 0, .del = 0, .ins = 4 }};
        var ops_ed = [_]ondb.core.op.Op{.{ .edit_text = .{
            .inode = created_iid,
            .text = try allocator.dupe(u8, "top "),
            .splices = &sp_a,
        } }};
        defer allocator.free(ops_ed[0].edit_text.text);
        var b_ed = ondb.core.op.Batch{
            .header = .{ .actor = actor_a, .start = 3, .end = 3, .parents = try p_sc.clone(allocator), .wall_ms = 3 },
            .ops = &ops_ed,
            .blobs = &.{},
        };
        defer b_ed.header.parents.deinit(allocator);

        var ops_sc = [_]ondb.core.op.Op{.{ .set_content = .{
            .inode = created_iid,
            .content = .{ .text_inline = try allocator.dupe(u8, "hello world!\n") },
        } }};
        defer ops_sc[0].deinit(allocator);
        var b_sc = ondb.core.op.Batch{
            .header = .{ .actor = actor_b, .start = 3, .end = 3, .parents = try p_sc.clone(allocator), .wall_ms = 3 },
            .ops = &ops_sc,
            .blobs = &.{},
        };
        defer b_sc.header.parents.deinit(allocator);

        try testing.expect(try hi1.integrate(&b_ed));
        try testing.expect(try hi1.integrate(&b_sc));
        try testing.expect(try hi2.integrate(&b_sc));
        try testing.expect(try hi2.integrate(&b_ed));
        const sc_r1 = (try hi1.readFileAt(allocator, "intra.txt", null)).?;
        defer allocator.free(sc_r1);
        const sc_r2 = (try hi2.readFileAt(allocator, "intra.txt", null)).?;
        defer allocator.free(sc_r2);
        try testing.expectEqualStrings(sc_r1, sc_r2);
        try testing.expectEqualStrings("top hello world!\n", sc_r1);

        var p_dir = try hi1.headsClone();
        defer p_dir.deinit(allocator);
        const dir_iid = ondb.core.id.InodeId.init(.{ .actor = actor_a, .ts = 10 }, 0);
        var d_ops = [_]ondb.core.op.Op{
            .{ .create_dir = .{ .parent = ondb.core.id.InodeId.ROOT, .name = try allocator.dupe(u8, "pkg") } },
            .{ .create_file = .{
                .parent = dir_iid,
                .name = try allocator.dupe(u8, "a.txt"),
                .mode = .regular,
                .line_ending = .lf,
                .content = .{ .text_inline = try allocator.dupe(u8, "inside\n") },
            } },
        };
        defer for (&d_ops) |*o| o.deinit(allocator);
        var b_dir = ondb.core.op.Batch{
            .header = .{ .actor = actor_a, .start = 10, .end = 11, .parents = try p_dir.clone(allocator), .wall_ms = 10 },
            .ops = &d_ops,
            .blobs = &.{},
        };
        defer b_dir.header.parents.deinit(allocator);
        try testing.expect(try hi1.integrate(&b_dir));

        var p_rem = try hi1.headsClone();
        defer p_rem.deinit(allocator);
        var rem_ops = [_]ondb.core.op.Op{.{ .remove = .{ .inode = dir_iid } }};
        var b_rem = ondb.core.op.Batch{
            .header = .{ .actor = actor_b, .start = 12, .end = 12, .parents = try p_rem.clone(allocator), .wall_ms = 12 },
            .ops = &rem_ops,
            .blobs = &.{},
        };
        defer b_rem.header.parents.deinit(allocator);
        try testing.expect(try hi1.integrate(&b_rem));
        try testing.expect((try hi1.readFileAt(allocator, "pkg/a.txt", null)) == null);
    }

    {
        var bs = try ondb.store.blobs.BlobStore.open(allocator, io, dir, "lru_blobs", 100);
        defer bs.deinit();
        const blob0: [40]u8 = @splat('0');
        const blob1: [40]u8 = @splat('1');
        const blob2: [40]u8 = @splat('2');
        const blob3: [40]u8 = @splat('3');
        const bh0 = try bs.put(&blob0);
        const bh1 = try bs.put(&blob1);
        const owned1 = (try bs.get(allocator, bh1)).?;
        defer allocator.free(owned1);
        const bh2 = try bs.put(&blob2);
        const bh3 = try bs.put(&blob3);
        try testing.expect(!bs.isCached(bh0));
        try testing.expect(bs.isCached(bh2));
        try testing.expect(bs.isCached(bh3));
        try testing.expectEqualStrings(&blob1, owned1);

        {
            var clog = try ondb.store.log.AppendLog.open(allocator, io, dir, "compact.0ndb", true);
            defer clog.deinit();
            var big_pay: [2048]u8 = undefined;
            for (0..45) |ci| {
                @memset(&big_pay, @intCast('a' + (ci % 26)));
                _ = try clog.append(1, 0, @intCast(ci), &big_pay);
            }
            const mid_v = try clog.readAt(22);
            try testing.expectEqual(@as(usize, 2048), mid_v.payload.len);
            const keep = [_]usize{ 0, 22, 44 };
            try clog.compact(dir, "compact.0ndb", &keep);
            try testing.expectEqual(@as(usize, 3), clog.count());
        }
        {
            var clog2 = try ondb.store.log.AppendLog.open(allocator, io, dir, "compact.0ndb", true);
            defer clog2.deinit();
            try testing.expectEqual(@as(usize, 3), clog2.count());
            const cr0 = try clog2.readAt(0);
            const cr1 = try clog2.readAt(1);
            const cr2 = try clog2.readAt(2);
            try testing.expectEqual(@as(u64, 1), cr0.header.seq);
            try testing.expectEqual(@as(u16, 0), cr0.header.aux);
            try testing.expectEqual(@as(u8, 'a'), cr0.payload[0]);
            try testing.expectEqual(@as(u64, 23), cr1.header.seq);
            try testing.expectEqual(@as(u16, 22), cr1.header.aux);
            try testing.expectEqual(@as(u8, 'a' + 22), cr1.payload[0]);
            try testing.expectEqual(@as(u64, 45), cr2.header.seq);
            try testing.expectEqual(@as(u16, 44), cr2.header.aux);
            try testing.expectEqual(@as(u8, 'a' + (44 % 26)), cr2.payload[0]);
        }
    }

    {
        const fs_root = "/tmp/0ndb-verify-fs-parity";
        const fs_state = "/tmp/0ndb-verify-fs-parity-state";
        cleanDir(io, fs_root);
        cleanDir(io, fs_state);
        defer cleanDir(io, fs_root);
        defer cleanDir(io, fs_state);

        try std.Io.Dir.cwd().createDirPath(io, fs_root ++ "/ignored_dir");
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/.gitignore", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "*.log\n!keep.log\nignored_dir/\n");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/drop.log", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "nope\n");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/keep.log", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "kept\n");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/ignored_dir/secret.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "hidden\n");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/huge.txt", .{ .truncate = true });
            defer f.close(io);
            const huge_bytes: [64]u8 = @splat('x');
            try f.writeStreamingAll(io, &huge_bytes);
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/bin.dat", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "\x00\x01\x02hello\x00\xff");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/win.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "one\r\ntwo\r\n");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/run.sh", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "#!/bin/sh\necho hi\n");
            try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, fs_root ++ "/old_name.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "unique rename payload 987654321\n");
        }
        try std.Io.Dir.cwd().symLink(io, "keep.log", fs_root ++ "/sym.link", .{});

        var persisted_actor: u128 = 0;
        {
            var fws = try ondb.fs.workspace.Workspace.open(allocator, io, fs_root, fs_state, 321);
            defer fws.deinit();
            fws.max_file_size = 48;
            persisted_actor = fws.disk_actor;

            const scope_id = try fws.beginScope(.turn, fws.disk_actor, "turn-1");
            _ = try fws.ingestDisk();
            try fws.endScope(scope_id);

            try testing.expect((try fws.history.readFileAt(allocator, "drop.log", null)) == null);
            try testing.expect((try fws.history.readFileAt(allocator, "ignored_dir/secret.txt", null)) == null);
            try testing.expect((try fws.history.readFileAt(allocator, "huge.txt", null)) == null);
            const kept_c = (try fws.history.readFileAt(allocator, "keep.log", null)).?;
            defer allocator.free(kept_c);
            try testing.expectEqualStrings("kept\n", kept_c);

            const win_crdt = (try fws.history.readFileAt(allocator, "win.txt", null)).?;
            defer allocator.free(win_crdt);
            try testing.expectEqualStrings("one\ntwo\n", win_crdt);

            _ = try fws.ingestDisk();
            const huge_st = try std.Io.Dir.cwd().statFile(io, fs_root ++ "/huge.txt", .{});
            try testing.expectEqual(@as(u64, 64), huge_st.size);

            const old_iid = (try fws.history.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "old_name.txt")).?;
            try std.Io.Dir.cwd().rename(fs_root ++ "/old_name.txt", std.Io.Dir.cwd(), fs_root ++ "/new_name.txt", io);
            _ = try fws.ingestDisk();
            const new_iid = (try fws.history.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "new_name.txt")).?;
            try testing.expectEqual(old_iid, new_iid);

            try std.Io.Dir.cwd().deleteFile(io, fs_root ++ "/bin.dat");
            try std.Io.Dir.cwd().deleteFile(io, fs_root ++ "/win.txt");
            try std.Io.Dir.cwd().deleteFile(io, fs_root ++ "/run.sh");
            try std.Io.Dir.cwd().deleteFile(io, fs_root ++ "/sym.link");
            try fws.materializeToDisk();

            const bin_raw = try std.Io.Dir.cwd().readFileAlloc(io, fs_root ++ "/bin.dat", allocator, .limited(1024));
            defer allocator.free(bin_raw);
            try testing.expectEqualStrings("\x00\x01\x02hello\x00\xff", bin_raw);

            const win_raw = try std.Io.Dir.cwd().readFileAlloc(io, fs_root ++ "/win.txt", allocator, .limited(1024));
            defer allocator.free(win_raw);
            try testing.expectEqualStrings("one\r\ntwo\r\n", win_raw);

            const sh_st = try std.Io.Dir.cwd().statFile(io, fs_root ++ "/run.sh", .{});
            try testing.expect((sh_st.permissions.toMode() & 0o111) != 0);

            var link_buf: [256]u8 = undefined;
            const link_len = try std.Io.Dir.cwd().readLink(io, fs_root ++ "/sym.link", &link_buf);
            try testing.expectEqualStrings("keep.log", link_buf[0..link_len]);
        }
        {
            var fws2 = try ondb.fs.workspace.Workspace.open(allocator, io, fs_root, fs_state, 321);
            defer fws2.deinit();
            try testing.expectEqual(persisted_actor, fws2.disk_actor);
            try testing.expect(fws2.scopes.items.len >= 1);
            try testing.expect(fws2.scopes.items[0].batches.items.len >= 1);
        }
    }

    {
        const b_ins = try ondb.fs.worktrees.merge3Lines(allocator, "a\nb\n", "a\nx\nb\n", "a\ny\nb\n");
        defer allocator.free(b_ins.output);
        try testing.expect(b_ins.has_conflict);

        var big_base: std.ArrayList(u8) = .empty;
        defer big_base.deinit(allocator);
        var big_ours: std.ArrayList(u8) = .empty;
        defer big_ours.deinit(allocator);
        var big_theirs: std.ArrayList(u8) = .empty;
        defer big_theirs.deinit(allocator);
        for (0..4000) |li| {
            try big_base.print(allocator, "row-{d}\n", .{li});
            if (li == 10) {
                try big_ours.appendSlice(allocator, "row-10-ours\n");
            } else {
                try big_ours.print(allocator, "row-{d}\n", .{li});
            }
            if (li == 3990) {
                try big_theirs.appendSlice(allocator, "row-3990-theirs\n");
            } else {
                try big_theirs.print(allocator, "row-{d}\n", .{li});
            }
        }
        const big_m = try ondb.fs.worktrees.merge3Lines(allocator, big_base.items, big_ours.items, big_theirs.items);
        defer allocator.free(big_m.output);
        try testing.expect(!big_m.has_conflict);
        try testing.expect(std.mem.indexOf(u8, big_m.output, "row-10-ours\n") != null);
        try testing.expect(std.mem.indexOf(u8, big_m.output, "row-3990-theirs\n") != null);
    }

    {
        const git_repo = "/tmp/0ndb-verify-git-safe";
        cleanDir(io, git_repo);
        defer cleanDir(io, git_repo);
        try std.Io.Dir.cwd().createDirPath(io, git_repo);
        const cmds = [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "test@0ndb.local" },
            &.{ "git", "config", "user.name", "0ndb" },
        };
        for (cmds) |argv| {
            var ch = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = git_repo }, .stdout = .ignore, .stderr = .ignore });
            _ = try ch.wait(io);
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, git_repo ++ "/a.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "v1\n");
        }
        for ([_][]const []const u8{
            &.{ "git", "add", "a.txt" },
            &.{ "git", "commit", "-q", "-m", "c1" },
        }) |argv| {
            var ch = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = git_repo }, .stdout = .ignore, .stderr = .ignore });
            _ = try ch.wait(io);
        }
        var h_c1 = try ondb.fs.vcs.head(allocator, io, git_repo);
        defer h_c1.deinit(allocator);
        {
            const f = try std.Io.Dir.cwd().createFile(io, git_repo ++ "/a.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "v2\n");
        }
        for ([_][]const []const u8{
            &.{ "git", "add", "a.txt" },
            &.{ "git", "commit", "-q", "-m", "c2" },
        }) |argv| {
            var ch = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = git_repo }, .stdout = .ignore, .stderr = .ignore });
            _ = try ch.wait(io);
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, git_repo ++ "/a.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "dirty-uncommitted\n");
        }
        try ondb.fs.vcs.moveHeadSafe(allocator, io, git_repo, null, h_c1.rev.?);
        var h_now = try ondb.fs.vcs.head(allocator, io, git_repo);
        defer h_now.deinit(allocator);
        try testing.expectEqualStrings(h_c1.rev.?, h_now.rev.?);
        const after_dirty = try std.Io.Dir.cwd().readFileAlloc(io, git_repo ++ "/a.txt", allocator, .limited(1024));
        defer allocator.free(after_dirty);
        try testing.expectEqualStrings("dirty-uncommitted\n", after_dirty);
    }

    {
        const pin_root = "/tmp/0ndb-verify-setcontent-pin";
        const pin_state = "/tmp/0ndb-verify-setcontent-pin-state";
        cleanDir(io, pin_root);
        cleanDir(io, pin_state);
        defer cleanDir(io, pin_root);
        defer cleanDir(io, pin_state);

        {
            var pws = try ondb.fs.workspace.Workspace.open(allocator, io, pin_root, pin_state, 612);
            defer pws.deinit();
            _ = try pws.writeFileDirect(actor_a, "doc.txt", "alpha beta gamma\n");
            const doc_iid = (try pws.history.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "doc.txt")).?;

            var parents = try pws.history.headsClone();
            errdefer parents.deinit(allocator);
            const ts = pws.history.nextStartTs(&parents);
            var sc_ops = [_]ondb.core.op.Op{.{ .set_content = .{
                .inode = doc_iid,
                .content = .{ .text_inline = try allocator.dupe(u8, "alpha DELTA gamma\n") },
            } }};
            defer sc_ops[0].deinit(allocator);
            var sc_batch = ondb.core.op.Batch{
                .header = .{ .actor = actor_b, .start = ts, .end = ts, .parents = parents, .wall_ms = 5 },
                .ops = &sc_ops,
                .blobs = &.{},
            };
            defer sc_batch.header.parents.deinit(allocator);
            try testing.expect(try pws.commitBatch(&sc_batch));

            const live_txt = (try pws.history.readFileAt(allocator, "doc.txt", null)).?;
            defer allocator.free(live_txt);
            try testing.expectEqualStrings("alpha DELTA gamma\n", live_txt);

            var mb_parents = try pws.history.headsClone();
            defer mb_parents.deinit(allocator);
            const mb_ts = pws.history.nextStartTs(&mb_parents);
            const fake_oid: ondb.core.id.Oid = @splat(0xab);
            var mb_ops = [_]ondb.core.op.Op{.{ .set_content = .{
                .inode = doc_iid,
                .content = .{ .text_blob = .{ .oid = fake_oid, .len = 12 } },
            } }};
            var mb_batch = ondb.core.op.Batch{
                .header = .{ .actor = actor_b, .start = mb_ts, .end = mb_ts, .parents = try mb_parents.clone(allocator), .wall_ms = 6 },
                .ops = &mb_ops,
                .blobs = &.{},
            };
            defer mb_batch.header.parents.deinit(allocator);
            try testing.expectError(error.MissingBlob, pws.history.integrate(&mb_batch));

            try pws.compactLog();
        }
        {
            var pws2 = try ondb.fs.workspace.Workspace.open(allocator, io, pin_root, pin_state, 612);
            defer pws2.deinit();
            const replayed = (try pws2.history.readFileAt(allocator, "doc.txt", null)).?;
            defer allocator.free(replayed);
            try testing.expectEqualStrings("alpha DELTA gamma\n", replayed);
        }
    }

    {
        const meta_root = "/tmp/0ndb-verify-meta-revert";
        const meta_state = "/tmp/0ndb-verify-meta-revert-state";
        cleanDir(io, meta_root);
        cleanDir(io, meta_state);
        defer cleanDir(io, meta_root);
        defer cleanDir(io, meta_state);

        try std.Io.Dir.cwd().createDirPath(io, meta_root);
        {
            const f = try std.Io.Dir.cwd().createFile(io, meta_root ++ "/payload.bin", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "\x00\x01bin-v1\xff");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, meta_root ++ "/tool.sh", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "#!/bin/sh\r\necho v1\r\n");
            try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }
        try std.Io.Dir.cwd().symLink(io, "v1_target", meta_root ++ "/ptr.link", .{});

        var mws = try ondb.fs.workspace.Workspace.open(allocator, io, meta_root, meta_state, 613);
        defer mws.deinit();
        _ = try mws.ingestDisk();
        var v1 = try mws.history.headsClone();
        defer v1.deinit(allocator);

        const scope_mut = try mws.beginScope(.turn, mws.disk_actor, "mutate-meta");
        {
            const f = try std.Io.Dir.cwd().createFile(io, meta_root ++ "/payload.bin", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "\x00\x02bin-v2-changed\xfe");
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, meta_root ++ "/tool.sh", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "#!/bin/sh\necho v2\n");
            try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o644));
        }
        try std.Io.Dir.cwd().deleteFile(io, meta_root ++ "/ptr.link");
        try std.Io.Dir.cwd().symLink(io, "v2_target", meta_root ++ "/ptr.link", .{});
        const mut_bid = (try mws.ingestDisk()).?;
        try mws.endScope(scope_mut);

        var scope_rev = (try mws.history.buildRevertScopeBatch(allocator, actor_a, &.{mut_bid}, 99)).?;
        defer scope_rev.deinit(allocator);
        try testing.expect(try mws.commitBatch(&scope_rev));
        try mws.materializeToDisk();

        const bin_restored = try std.Io.Dir.cwd().readFileAlloc(io, meta_root ++ "/payload.bin", allocator, .limited(1024));
        defer allocator.free(bin_restored);
        try testing.expectEqualStrings("\x00\x01bin-v1\xff", bin_restored);
        const sh_restored = try std.Io.Dir.cwd().readFileAlloc(io, meta_root ++ "/tool.sh", allocator, .limited(1024));
        defer allocator.free(sh_restored);
        try testing.expectEqualStrings("#!/bin/sh\r\necho v1\r\n", sh_restored);
        const sh_stat = try std.Io.Dir.cwd().statFile(io, meta_root ++ "/tool.sh", .{});
        try testing.expect((sh_stat.permissions.toMode() & 0o111) != 0);
        var sym_buf: [128]u8 = undefined;
        const sym_n = try std.Io.Dir.cwd().readLink(io, meta_root ++ "/ptr.link", &sym_buf);
        try testing.expectEqualStrings("v1_target", sym_buf[0..sym_n]);

        {
            const f = try std.Io.Dir.cwd().createFile(io, meta_root ++ "/payload.bin", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "now-plain-text\n");
        }
        _ = try mws.ingestDisk();
        var rb_bin = (try mws.history.buildRollbackBatch(allocator, actor_a, &v1, 100)).?;
        defer rb_bin.deinit(allocator);
        try testing.expect(try mws.commitBatch(&rb_bin));
        try mws.materializeToDisk();
        const bin_after_rb = try std.Io.Dir.cwd().readFileAlloc(io, meta_root ++ "/payload.bin", allocator, .limited(1024));
        defer allocator.free(bin_after_rb);
        try testing.expectEqualStrings("\x00\x01bin-v1\xff", bin_after_rb);
    }

    {
        var glog = try ondb.store.log.AppendLog.open(allocator, io, dir, "grow_mmap.0ndb", true);
        defer glog.deinit();
        var chunk: [4096]u8 = @splat('Z');
        const first_app = try glog.appendWithOffset(1, 1, 0, 0, "pinned-before-growth");
        const borrowed_first = glog.readSlice(first_app.payload_offset, 20).?;
        for (0..32) |gi| {
            chunk[0] = @intCast('A' + (gi % 26));
            _ = try glog.append(1, 0, @intCast(gi), &chunk);
        }
        try testing.expectEqualStrings("pinned-before-growth", borrowed_first);
    }

    {
        try testing.expect(ondb.fs.workspace.globMatch("**/foo.zig", "foo.zig"));
        try testing.expect(ondb.fs.workspace.globMatch("**/foo.zig", "a/b/foo.zig"));
        try testing.expect(!ondb.fs.workspace.globMatch("**/foo.zig", "barfoo.zig"));
        try testing.expect(!ondb.fs.workspace.globMatch("**/foo.zig", "a/barfoo.zig"));
        try testing.expect(ondb.fs.workspace.globMatch("src/**/mod.zig", "src/mod.zig"));
        try testing.expect(ondb.fs.workspace.globMatch("src/**/mod.zig", "src/x/y/mod.zig"));
        const redos_text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        try testing.expect(!ondb.fs.workspace.globMatch("a*a*a*a*a*a*a*a*b", redos_text));

        const sc_root = "/tmp/0ndb-verify-statcache";
        const sc_state = "/tmp/0ndb-verify-statcache-state";
        cleanDir(io, sc_root);
        cleanDir(io, sc_state);
        defer cleanDir(io, sc_root);
        defer cleanDir(io, sc_state);

        {
            var sws = try ondb.fs.workspace.Workspace.open(allocator, io, sc_root, sc_state, 614);
            defer sws.deinit();
            _ = try sws.writeFileDirect(actor_a, "rename_src.txt", "distinctive-rename-body-77777\n");
            try sws.saveStatCache();
        }
        {
            var sws2 = try ondb.fs.workspace.Workspace.open(allocator, io, sc_root, sc_state, 614);
            defer sws2.deinit();
            try testing.expect(sws2.stat_cache.contains("rename_src.txt"));
            const orig_iid = (try sws2.history.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "rename_src.txt")).?;
            try std.Io.Dir.cwd().rename(sc_root ++ "/rename_src.txt", std.Io.Dir.cwd(), sc_root ++ "/rename_dst.txt", io);
            const rels = [_][]const u8{ "rename_src.txt", "rename_dst.txt" };
            _ = try sws2.ingestPaths(&rels, &.{}, "watch");
            const dst_iid = (try sws2.history.tree.resolvePath(allocator, ondb.core.text.View.EVERYTHING, "rename_dst.txt")).?;
            try testing.expectEqual(orig_iid, dst_iid);
        }
    }

    {
        const wm_state = "/tmp/0ndb-verify-wt-edge-state";
        const wm_chk = "/tmp/0ndb-verify-wt-edge-chk";
        const wm_main = "/tmp/0ndb-verify-wt-edge-main";
        cleanDir(io, wm_state);
        cleanDir(io, wm_chk);
        cleanDir(io, wm_main);
        defer cleanDir(io, wm_state);
        defer cleanDir(io, wm_chk);
        defer cleanDir(io, wm_main);

        try std.Io.Dir.cwd().createDirPath(io, wm_main);
        {
            const f = try std.Io.Dir.cwd().createFile(io, wm_main ++ "/script.sh", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "#!/bin/sh\r\nline1\r\nline2\r\nline3\r\n");
            try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }
        {
            const f = try std.Io.Dir.cwd().createFile(io, wm_main ++ "/moveme.txt", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "top\nmid\nbot\n");
        }

        var wts2 = try ondb.fs.worktrees.Worktrees.open(allocator, io, wm_state, wm_chk);
        defer wts2.deinit();
        var m_wt = try wts2.adopt(wm_main, "edge-main");
        defer m_wt.deinit(allocator);
        var f_wt = try wts2.fork(m_wt.id, "edge-fork", null, null);
        defer f_wt.deinit(allocator);

        const mws = wts2.getWorkspace(m_wt.id).?;
        const fws = wts2.getWorkspace(f_wt.id).?;

        _ = try mws.writeFileDirect(actor_a, "both_added.txt", "from-main\n");
        _ = try fws.writeFileDirect(actor_b, "both_added.txt", "from-fork\n");

        {
            const f = try std.Io.Dir.cwd().createFile(io, wm_main ++ "/script.sh", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "#!/bin/sh\r\nline1-main\r\nline2\r\nline3\r\n");
            try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }
        _ = try mws.ingestDisk();
        {
            const fp = try std.fmt.allocPrint(allocator, "{s}/script.sh", .{fws.root_path});
            defer allocator.free(fp);
            const f = try std.Io.Dir.cwd().createFile(io, fp, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, "#!/bin/sh\r\nline1\r\nline2\r\nline3-fork\r\n");
            try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }
        _ = try fws.ingestDisk();

        try std.Io.Dir.cwd().rename(wm_main ++ "/moveme.txt", std.Io.Dir.cwd(), wm_main ++ "/moved.txt", io);
        _ = try mws.ingestDisk();
        _ = try fws.writeFileDirect(actor_b, "moveme.txt", "top\nmid-fork\nbot\n");

        var rep = try wts2.syncFork(f_wt.id);
        defer rep.deinit(allocator);

        const fp_sh = try std.fmt.allocPrint(allocator, "{s}/script.sh", .{fws.root_path});
        defer allocator.free(fp_sh);
        const merged_sh = try std.Io.Dir.cwd().readFileAlloc(io, fp_sh, allocator, .limited(1024));
        defer allocator.free(merged_sh);
        try testing.expectEqualStrings("#!/bin/sh\r\nline1-main\r\nline2\r\nline3-fork\r\n", merged_sh);
        const merged_sh_st = try std.Io.Dir.cwd().statFile(io, fp_sh, .{});
        try testing.expect((merged_sh_st.permissions.toMode() & 0o111) != 0);

        try testing.expect((try fws.history.readFileAt(allocator, "moveme.txt", null)) == null);
        const moved_c = (try fws.history.readFileAt(allocator, "moved.txt", null)).?;
        defer allocator.free(moved_c);
        try testing.expectEqualStrings("top\nmid-fork\nbot\n", moved_c);

        var root_entries = try fws.history.tree.listDir(allocator, ondb.core.text.View.EVERYTHING, ondb.core.id.InodeId.ROOT);
        defer {
            for (root_entries.items) |*e| e.deinit(allocator);
            root_entries.deinit(allocator);
        }
        var both_count: usize = 0;
        for (root_entries.items) |e| {
            if (std.mem.eql(u8, e.name, "both_added.txt")) both_count += 1;
        }
        try testing.expectEqual(@as(usize, 1), both_count);
    }

    try runCrdtFuzzSuite(allocator);
    try runDiffAndMerge3PropertyFuzz(allocator);
    try runDaemonWatcherSuite(allocator, io);
    try runPagedStorePrimitivesSuite(allocator, io);
    try runNativeGitLayerSuite(allocator, io);
}

fn countOpenFds(io: std.Io) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |_| {
        count += 1;
    }
    return count;
}

fn writeVerifyFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn customIgnoreGenDir(_: ?*const anyopaque, rel_path: []const u8, _: bool) bool {
    if (std.mem.eql(u8, rel_path, "gen_custom")) return true;
    return std.mem.startsWith(u8, rel_path, "gen_custom/");
}

fn batchHasPath(batch: *const ondb.fs.watch.MountBatch, target_path: []const u8) bool {
    for (batch.paths.items) |p| {
        if (std.mem.eql(u8, p.rel_path, target_path)) return true;
    }
    return false;
}

fn batchPathMask(batch: *const ondb.fs.watch.MountBatch, target_path: []const u8) ?u32 {
    for (batch.paths.items) |p| {
        if (std.mem.eql(u8, p.rel_path, target_path)) return p.mask;
    }
    return null;
}

const IdleTickTestCtx = struct {
    ticks: usize = 0,
    hibernated: usize = 0,
    do_hibernate: bool = false,

    fn onTick(ctx_ptr: ?*anyopaque, w: *ondb.fs.watch.SharedWatcher, now_ms: u64) void {
        const ctx: *IdleTickTestCtx = @ptrCast(@alignCast(ctx_ptr.?));
        ctx.ticks += 1;
        if (ctx.do_hibernate) {
            ctx.hibernated += w.hibernateIdleMounts(0, now_ms);
            ctx.do_hibernate = false;
        }
    }
};

fn runDaemonWatcherSuite(allocator: std.mem.Allocator, io: std.Io) !void {
    const watch = ondb.fs.watch;
    const linux = std.os.linux;

    const sys_max = watch.readSystemMaxUserWatches();
    try testing.expect(sys_max > 0);
    const default_budget = watch.computeDefaultWatchBudget();
    try testing.expect(default_budget > 0);
    try testing.expect(default_budget <= watch.MAX_DEFAULT_WATCH_BUDGET);

    const root = "/tmp/0ndb-verify-daemon-watcher";
    cleanDir(io, root);
    defer cleanDir(io, root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const fd_before = try countOpenFds(io);
    {
        var watcher = try watch.DaemonWatcher.init(allocator);
        defer watcher.deinit();
        try testing.expectEqual(@as(usize, 4), watcher.fdCount());

        const custom_filter = watch.IgnoreFilter{
            .ctx = null,
            .should_ignore = customIgnoreGenDir,
        };

        var wt_paths: [32][]u8 = undefined;
        var wt_init_count: usize = 0;
        defer {
            for (wt_paths[0..wt_init_count]) |p| allocator.free(p);
        }

        for (0..32) |i| {
            const wt = try std.fmt.allocPrint(allocator, "{s}/wt_{d}", .{ root, i });
            wt_paths[i] = wt;
            wt_init_count = i + 1;

            const sub_dirs = [_][]const u8{
                "src",
                "src/deep",
                "target/debug",
                "node_modules/pkg",
                "dist",
                "build",
                ".next",
                ".zig-cache",
                "zig-out",
                "gen_custom/sub",
            };
            for (sub_dirs) |sd| {
                const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wt, sd });
                defer allocator.free(full);
                try std.Io.Dir.cwd().createDirPath(io, full);
            }

            const mode = try watcher.registerMount(io, @as(u64, i + 1), wt, custom_filter);
            try testing.expectEqual(watch.WatchMode.full_inotify, mode);
            try testing.expectEqual(@as(usize, 3), watcher.mountWatchCount(@as(u64, i + 1)));
        }

        try testing.expectEqual(@as(usize, 32), watcher.mountCount());
        try testing.expectEqual(@as(usize, 32 * 3), watcher.activeWatches());

        const fd_after = try countOpenFds(io);
        try testing.expectEqual(fd_before + 4, fd_after);

        for (0..250) |k| {
            const p1 = try std.fmt.allocPrint(allocator, "{s}/target/debug/out_{d}.o", .{ wt_paths[0], k });
            defer allocator.free(p1);
            try writeVerifyFile(io, p1, "obj");

            const p2 = try std.fmt.allocPrint(allocator, "{s}/node_modules/pkg/f_{d}.js", .{ wt_paths[0], k });
            defer allocator.free(p2);
            try writeVerifyFile(io, p2, "js");
        }
        for (0..10) |k| {
            const p3 = try std.fmt.allocPrint(allocator, "{s}/gen_custom/sub/g_{d}.txt", .{ wt_paths[0], k });
            defer allocator.free(p3);
            try writeVerifyFile(io, p3, "gen");
        }
        {
            var ignored_batch = try watcher.nextEventBatch(io, 60);
            defer ignored_batch.deinit(allocator);
            try testing.expectEqual(@as(usize, 0), ignored_batch.batches.items.len);
            try testing.expect(ignored_batch.timed_out);
        }

        const mid_path = try std.fmt.allocPrint(allocator, "{s}/src/midwrite.zig", .{wt_paths[3]});
        defer allocator.free(mid_path);
        try writeVerifyFile(io, mid_path, "initial\n");
        watcher.setDebounce(20, 80);
        {
            var init_b = try watcher.nextEventBatch(io, 300);
            defer init_b.deinit(allocator);
            try testing.expect(init_b.batches.items.len >= 1);
        }
        {
            const f = try std.Io.Dir.cwd().openFile(io, mid_path, .{ .mode = .read_write });
            var closed = false;
            defer if (!closed) f.close(io);
            try f.writePositionalAll(io, "mid-write-1", 0);
            try f.writePositionalAll(io, "mid-write-2", 0);

            var no_mod = try watcher.nextEventBatch(io, 50);
            defer no_mod.deinit(allocator);
            try testing.expectEqual(@as(usize, 0), no_mod.batches.items.len);

            f.close(io);
            closed = true;

            var after_close = try watcher.nextEventBatch(io, 300);
            defer after_close.deinit(allocator);
            try testing.expectEqual(@as(usize, 1), after_close.batches.items.len);
            try testing.expectEqual(@as(u64, 4), after_close.batches.items[0].mount_id);
            const msk = batchPathMask(&after_close.batches.items[0], "src/midwrite.zig").?;
            try testing.expect((msk & linux.IN.CLOSE_WRITE) != 0);
            try testing.expect((msk & linux.IN.MODIFY) == 0);
        }

        const p_a = try std.fmt.allocPrint(allocator, "{s}/src/deep/alpha.zig", .{wt_paths[0]});
        defer allocator.free(p_a);
        const p_b = try std.fmt.allocPrint(allocator, "{s}/root_file.txt", .{wt_paths[15]});
        defer allocator.free(p_b);
        const p_c = try std.fmt.allocPrint(allocator, "{s}/src/omega.zig", .{wt_paths[31]});
        defer allocator.free(p_c);
        try writeVerifyFile(io, p_a, "alpha\n");
        try writeVerifyFile(io, p_b, "beta\n");
        try writeVerifyFile(io, p_c, "omega\n");

        var got_m1 = false;
        var got_m16 = false;
        var got_m32 = false;
        var attempts: usize = 0;
        while ((!got_m1 or !got_m16 or !got_m32) and attempts < 10) : (attempts += 1) {
            var evb = try watcher.nextEventBatch(io, 300);
            defer evb.deinit(allocator);
            for (evb.batches.items) |*b| {
                if (b.mount_id == 1 and batchHasPath(b, "src/deep/alpha.zig")) got_m1 = true;
                if (b.mount_id == 16 and batchHasPath(b, "root_file.txt")) got_m16 = true;
                if (b.mount_id == 32 and batchHasPath(b, "src/omega.zig")) got_m32 = true;
            }
        }
        try testing.expect(got_m1);
        try testing.expect(got_m16);
        try testing.expect(got_m32);

        const burst_path = try std.fmt.allocPrint(allocator, "{s}/src/burst.zig", .{wt_paths[5]});
        defer allocator.free(burst_path);
        for (0..15) |bi| {
            var line_buf: [32]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "burst {d}\n", .{bi});
            try writeVerifyFile(io, burst_path, line);
        }
        {
            var burst_res = try watcher.nextEventBatch(io, 300);
            defer burst_res.deinit(allocator);
            try testing.expectEqual(@as(usize, 1), burst_res.batches.items.len);
            try testing.expectEqual(@as(u64, 6), burst_res.batches.items[0].mount_id);
            try testing.expectEqual(@as(usize, 1), burst_res.batches.items[0].paths.items.len);
            try testing.expectEqualStrings("src/burst.zig", burst_res.batches.items[0].paths.items[0].rel_path);
        }

        const git_common = try std.fmt.allocPrint(allocator, "{s}/shared_git", .{root});
        defer allocator.free(git_common);
        const git_heads = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_common});
        defer allocator.free(git_heads);
        try std.Io.Dir.cwd().createDirPath(io, git_heads);

        for (0..10) |gi| {
            try watcher.subscribeGitCommon(@as(u64, gi + 1), git_common);
        }
        try testing.expectEqual(@as(usize, 3), watcher.sharedGitWatchCount());

        const ref_main = try std.fmt.allocPrint(allocator, "{s}/main", .{git_heads});
        defer allocator.free(ref_main);
        try writeVerifyFile(io, ref_main, "0123456789abcdef\n");

        var git_seen: [32]bool = @splat(false);
        var git_attempts: usize = 0;
        while (git_attempts < 10) : (git_attempts += 1) {
            var all_ten = true;
            for (0..10) |gi| {
                if (!git_seen[gi]) all_ten = false;
            }
            if (all_ten) break;
            var gb = try watcher.nextEventBatch(io, 300);
            defer gb.deinit(allocator);
            for (gb.batches.items) |*b| {
                if (b.git_changed and b.mount_id >= 1 and b.mount_id <= 32) {
                    git_seen[@intCast(b.mount_id - 1)] = true;
                }
            }
        }
        for (0..10) |gi| try testing.expect(git_seen[gi]);
        for (10..32) |gi| try testing.expect(!git_seen[gi]);

        for (0..9) |gi| watcher.unsubscribeGitCommon(@as(u64, gi + 1));
        try testing.expectEqual(@as(usize, 3), watcher.sharedGitWatchCount());
        watcher.unsubscribeGitCommon(10);
        try testing.expectEqual(@as(usize, 0), watcher.sharedGitWatchCount());

        const before_hib = watcher.activeWatches();
        try testing.expect(watcher.hibernateMountWatches(2));
        try testing.expectEqual(watch.WatchMode.stat_on_demand, watcher.mountMode(2));
        try testing.expectEqual(@as(usize, 0), watcher.mountWatchCount(2));
        try testing.expectEqual(@as(usize, 32), watcher.mountCount());
        try testing.expectEqual(before_hib - 3, watcher.activeWatches());

        const restored_mode = try watcher.restoreMountWatches(io, 2);
        try testing.expectEqual(watch.WatchMode.full_inotify, restored_mode);
        try testing.expectEqual(@as(usize, 3), watcher.mountWatchCount(2));
        try testing.expectEqual(before_hib, watcher.activeWatches());

        var tick_ctx = IdleTickTestCtx{ .do_hibernate = true };
        watcher.setIdleTick(25, .{
            .ctx = &tick_ctx,
            .on_tick = IdleTickTestCtx.onTick,
        });
        {
            var tick_res = try watcher.nextEventBatch(io, 300);
            defer tick_res.deinit(allocator);
            try testing.expect(tick_res.idle_ticked);
            try testing.expect(tick_ctx.ticks >= 1);
            try testing.expectEqual(@as(usize, 32), tick_ctx.hibernated);
            try testing.expectEqual(@as(usize, 0), watcher.activeWatches());
        }
        watcher.setIdleTick(0, null);
        _ = try watcher.restoreMountWatches(io, 1);
        try testing.expectEqual(@as(usize, 3), watcher.activeWatches());

        for (0..32) |i| {
            watcher.removeMount(@as(u64, i + 1));
        }
        try testing.expectEqual(@as(usize, 0), watcher.mountCount());
        try testing.expectEqual(@as(usize, 0), watcher.activeWatches());
        try testing.expectEqual(@as(usize, 0), watcher.sharedGitWatchCount());
    }

    const fd_after_close = try countOpenFds(io);
    try testing.expectEqual(fd_before, fd_after_close);

    {
        var budgeted = try watch.SharedWatcher.initWithBudget(allocator, 5);
        defer budgeted.deinit();
        budgeted.setDebounce(15, 60);

        const ok_root = try std.fmt.allocPrint(allocator, "{s}/budget_ok", .{root});
        defer allocator.free(ok_root);
        for ([_][]const u8{ "a", "b", "c" }) |sd| {
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ok_root, sd });
            defer allocator.free(p);
            try std.Io.Dir.cwd().createDirPath(io, p);
        }

        const over_root = try std.fmt.allocPrint(allocator, "{s}/budget_over", .{root});
        defer allocator.free(over_root);
        for ([_][]const u8{ "d1", "d2", "d3", "d4" }) |sd| {
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ over_root, sd });
            defer allocator.free(p);
            try std.Io.Dir.cwd().createDirPath(io, p);
        }

        const m_ok = try budgeted.registerMount(io, 10, ok_root, null);
        try testing.expectEqual(watch.WatchMode.full_inotify, m_ok);
        try testing.expectEqual(@as(usize, 4), budgeted.activeWatches());

        const m_over = try budgeted.registerMount(io, 20, over_root, null);
        try testing.expectEqual(watch.WatchMode.stat_on_demand, m_over);
        try testing.expectEqual(watch.WatchMode.stat_on_demand, budgeted.mountMode(20));
        try testing.expect(budgeted.isMountOverflow(20));
        try testing.expectEqual(@as(usize, 0), budgeted.mountWatchCount(20));
        try testing.expectEqual(@as(usize, 4), budgeted.activeWatches());

        {
            var ov_res = try budgeted.nextEventBatch(io, 300);
            defer ov_res.deinit(allocator);
            var saw_ov = false;
            for (ov_res.batches.items) |b| {
                if (b.mount_id == 20 and b.overflow and b.mode == .stat_on_demand) saw_ov = true;
            }
            try testing.expect(saw_ov);
        }

        const dyn_sub = try std.fmt.allocPrint(allocator, "{s}/dyn1/dyn2", .{ok_root});
        defer allocator.free(dyn_sub);
        try std.Io.Dir.cwd().createDirPath(io, dyn_sub);
        {
            var dyn_res = try budgeted.nextEventBatch(io, 300);
            defer dyn_res.deinit(allocator);
            try testing.expectEqual(watch.WatchMode.stat_on_demand, budgeted.mountMode(10));
            try testing.expectEqual(@as(usize, 0), budgeted.activeWatches());
        }
    }

    {
        var fwatcher = try watch.SharedWatcher.init(allocator);
        defer fwatcher.deinit();
        fwatcher.setDebounce(5000, 5000);

        const fence_wt = try std.fmt.allocPrint(allocator, "{s}/fence_wt", .{root});
        defer allocator.free(fence_wt);
        const fence_src = try std.fmt.allocPrint(allocator, "{s}/src", .{fence_wt});
        defer allocator.free(fence_src);
        const fence_state = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{fence_wt});
        defer allocator.free(fence_state);
        try std.Io.Dir.cwd().createDirPath(io, fence_src);
        try std.Io.Dir.cwd().createDirPath(io, fence_state);

        const fm = try fwatcher.registerMount(io, 100, fence_wt, null);
        try testing.expectEqual(watch.WatchMode.full_inotify, fm);

        const f1 = try std.fmt.allocPrint(allocator, "{s}/a.zig", .{fence_wt});
        defer allocator.free(f1);
        const f2 = try std.fmt.allocPrint(allocator, "{s}/src/b.zig", .{fence_wt});
        defer allocator.free(f2);
        const f3 = try std.fmt.allocPrint(allocator, "{s}/src/c.zig", .{fence_wt});
        defer allocator.free(f3);
        try writeVerifyFile(io, f1, "a\n");
        try writeVerifyFile(io, f2, "b\n");
        try writeVerifyFile(io, f3, "c\n");

        const fenced_1 = try fwatcher.fence(io, 100, fence_state, 2000);
        try testing.expect(fenced_1);

        var batch1 = (try fwatcher.flushMountPending(100)).?;
        defer batch1.deinit(allocator);
        try testing.expect(batchHasPath(&batch1, "a.zig"));
        try testing.expect(batchHasPath(&batch1, "src/b.zig"));
        try testing.expect(batchHasPath(&batch1, "src/c.zig"));
        try testing.expectEqual(@as(usize, 3), batch1.paths.items.len);

        const fences_dir_path = try std.fmt.allocPrint(allocator, "{s}/fences", .{fence_state});
        defer allocator.free(fences_dir_path);
        {
            var fdir = try std.Io.Dir.cwd().openDir(io, fences_dir_path, .{ .iterate = true });
            defer fdir.close(io);
            var fit = fdir.iterate();
            var leftover: usize = 0;
            while (try fit.next(io)) |_| leftover += 1;
            try testing.expectEqual(@as(usize, 0), leftover);
        }

        const f4 = try std.fmt.allocPrint(allocator, "{s}/src/d.zig", .{fence_wt});
        defer allocator.free(f4);
        try writeVerifyFile(io, f4, "d\n");

        const fenced_2 = try fwatcher.fence(io, 100, fence_state, 2000);
        try testing.expect(fenced_2);

        var batch2 = (try fwatcher.flushMountPending(100)).?;
        defer batch2.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), batch2.paths.items.len);
        try testing.expect(batchHasPath(&batch2, "src/d.zig"));

        fwatcher.removeMount(100);
        try testing.expectEqual(@as(usize, 0), fwatcher.activeWatches());
    }
}

const FuzzFileSnap = struct {
    path: []u8,
    inode_id: ondb.core.id.InodeId,
    is_dir: bool,
    is_symlink: bool,
    is_binary: bool,
    mode: ondb.core.tree.FileMode,
    line_ending: ondb.core.tree.LineEnding,
    line_count: usize,
    data: []u8,

    fn deinit(self: *FuzzFileSnap, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.data);
    }
};

fn lessFuzzSnap(_: void, a: FuzzFileSnap, b: FuzzFileSnap) bool {
    const ord = std.mem.order(u8, a.path, b.path);
    if (ord != .eq) return ord == .lt;
    return a.inode_id.order(b.inode_id) == .lt;
}

fn collectLiveTreeSnap(
    allocator: std.mem.Allocator,
    hist: *const ondb.core.history.History,
    dir_iid: ondb.core.id.InodeId,
    prefix: []const u8,
    out: *std.ArrayList(FuzzFileSnap),
) !void {
    var entries = try hist.tree.listDir(allocator, ondb.core.text.View.EVERYTHING, dir_iid);
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }
    const res = hist.resolver();
    for (entries.items) |e| {
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, e.name });
        errdefer allocator.free(rel);
        const inode = hist.tree.get(e.inode_id) orelse {
            allocator.free(rel);
            continue;
        };
        switch (inode.kind) {
            .dir => {
                try out.append(allocator, .{
                    .path = rel,
                    .inode_id = e.inode_id,
                    .is_dir = true,
                    .is_symlink = false,
                    .is_binary = false,
                    .mode = .regular,
                    .line_ending = .lf,
                    .line_count = 0,
                    .data = try allocator.dupe(u8, ""),
                });
                try collectLiveTreeSnap(allocator, hist, e.inode_id, out.items[out.items.len - 1].path, out);
            },
            .symlink => |*sl| {
                const tgt = if (sl.get()) |t| t.* else "";
                const data = try allocator.dupe(u8, tgt);
                errdefer allocator.free(data);
                try out.append(allocator, .{
                    .path = rel,
                    .inode_id = e.inode_id,
                    .is_dir = false,
                    .is_symlink = true,
                    .is_binary = false,
                    .mode = .regular,
                    .line_ending = .lf,
                    .line_count = 0,
                    .data = data,
                });
            },
            .file => |*f| {
                const ck = if (f.content.get()) |c| c.* else ondb.core.tree.ContentKind.text;
                const mode = if (f.mode.get()) |m| m.* else ondb.core.tree.FileMode.regular;
                const le = if (f.line_ending.get()) |l| l.* else ondb.core.tree.LineEnding.lf;
                const is_bin = ck == .binary;
                const data = switch (ck) {
                    .binary => |bref| try allocator.dupe(u8, hist.resolveBlob(bref.oid) orelse ""),
                    .text => (try f.text.readIn(allocator, res, ondb.core.text.View.EVERYTHING)) orelse try allocator.dupe(u8, ""),
                };
                errdefer allocator.free(data);
                const lc: usize = if (is_bin) 0 else f.text.lineCount();
                if (!is_bin) {
                    try testing.expectEqual(countLinesExact(data), lc);
                }
                try out.append(allocator, .{
                    .path = rel,
                    .inode_id = e.inode_id,
                    .is_dir = false,
                    .is_symlink = false,
                    .is_binary = is_bin,
                    .mode = mode,
                    .line_ending = le,
                    .line_count = lc,
                    .data = data,
                });
            },
        }
    }
}

fn snapshotLiveTree(allocator: std.mem.Allocator, hist: *const ondb.core.history.History) !std.ArrayList(FuzzFileSnap) {
    var out: std.ArrayList(FuzzFileSnap) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }
    try collectLiveTreeSnap(allocator, hist, ondb.core.id.InodeId.ROOT, "", &out);
    std.mem.sort(FuzzFileSnap, out.items, {}, lessFuzzSnap);
    return out;
}

fn expectSnapsEqual(a: []const FuzzFileSnap, b: []const FuzzFileSnap) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |sa, sb| {
        try testing.expectEqualStrings(sa.path, sb.path);
        try testing.expect(sa.inode_id.eql(sb.inode_id));
        try testing.expectEqual(sa.is_dir, sb.is_dir);
        try testing.expectEqual(sa.is_symlink, sb.is_symlink);
        try testing.expectEqual(sa.is_binary, sb.is_binary);
        try testing.expectEqual(sa.mode, sb.mode);
        try testing.expectEqual(sa.line_ending, sb.line_ending);
        try testing.expectEqual(sa.line_count, sb.line_count);
        try testing.expectEqualStrings(sa.data, sb.data);
    }
}

fn assertHistoriesConverged(
    allocator: std.mem.Allocator,
    ha: *const ondb.core.history.History,
    hb: *const ondb.core.history.History,
) !void {
    var sa = try snapshotLiveTree(allocator, ha);
    defer {
        for (sa.items) |*s| s.deinit(allocator);
        sa.deinit(allocator);
    }
    var sb = try snapshotLiveTree(allocator, hb);
    defer {
        for (sb.items) |*s| s.deinit(allocator);
        sb.deinit(allocator);
    }
    try expectSnapsEqual(sa.items, sb.items);

    for (sa.items) |s| {
        if (s.is_dir or s.is_symlink or s.is_binary) continue;
        var ba_opt = try ha.blameFile(allocator, s.path);
        var bb_opt = try hb.blameFile(allocator, s.path);
        defer if (ba_opt) |*bl| {
            for (bl.items) |*l| l.deinit(allocator);
            bl.deinit(allocator);
        };
        defer if (bb_opt) |*bl| {
            for (bl.items) |*l| l.deinit(allocator);
            bl.deinit(allocator);
        };
        try testing.expectEqual(ba_opt != null, bb_opt != null);
        if (ba_opt) |ba| {
            const bb = bb_opt.?;
            try testing.expectEqual(ba.items.len, bb.items.len);
            for (ba.items, bb.items) |la, lb| {
                try testing.expectEqual(la.line_no, lb.line_no);
                try testing.expect(la.op.eql(lb.op));
                try testing.expectEqualStrings(la.text, lb.text);
            }
        }
    }
}

const FUZZ_TOKENS = [_][]const u8{
    "alpha",
    "beta",
    "gamma",
    "caf\xc3\xa9",
    "\xcf\x80",
    "\xe4\xb8\xad\xe6\x96\x87",
    "\xf0\x9f\x9a\x80",
    "\xe2\x9a\xa1",
    "line\n",
    "crlf\r\n",
    " ",
    "::",
    "42\n",
    "fn main() {}\n",
};

fn randomUtf8Text(allocator: std.mem.Allocator, rng: std.Random, max_tokens: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const n = rng.uintLessThan(usize, max_tokens + 1);
    for (0..n) |_| {
        const tok = FUZZ_TOKENS[rng.uintLessThan(usize, FUZZ_TOKENS.len)];
        try out.appendSlice(allocator, tok);
    }
    return try out.toOwnedSlice(allocator);
}

fn mutateUtf8Text(allocator: std.mem.Allocator, rng: std.Random, orig: []const u8) ![]u8 {
    var bounds: std.ArrayList(usize) = .empty;
    defer bounds.deinit(allocator);
    try bounds.append(allocator, 0);
    var i: usize = 0;
    while (i < orig.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(orig[i]) catch 1;
        i = @min(orig.len, i + seq_len);
        try bounds.append(allocator, i);
    }
    const edits = 1 + rng.uintLessThan(usize, 3);
    var cur = try allocator.dupe(u8, orig);
    errdefer allocator.free(cur);
    for (0..edits) |_| {
        bounds.clearRetainingCapacity();
        try bounds.append(allocator, 0);
        var j: usize = 0;
        while (j < cur.len) {
            const sl = std.unicode.utf8ByteSequenceLength(cur[j]) catch 1;
            j = @min(cur.len, j + sl);
            try bounds.append(allocator, j);
        }
        const a_idx = rng.uintLessThan(usize, bounds.items.len);
        const b_idx = rng.uintLessThan(usize, bounds.items.len);
        const lo = bounds.items[@min(a_idx, b_idx)];
        const hi = bounds.items[@max(a_idx, b_idx)];
        const ins = try randomUtf8Text(allocator, rng, 3);
        defer allocator.free(ins);
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(allocator);
        try next.appendSlice(allocator, cur[0..lo]);
        try next.appendSlice(allocator, ins);
        try next.appendSlice(allocator, cur[hi..]);
        allocator.free(cur);
        cur = try next.toOwnedSlice(allocator);
    }
    return cur;
}

fn integrateRandomTopoOrder(
    allocator: std.mem.Allocator,
    hist: *ondb.core.history.History,
    batches: []const ondb.core.op.Batch,
    seed: u64,
    capture_points: ?[]const usize,
    captured_vers: ?*std.ArrayList(ondb.core.version.Version),
    captured_snaps: ?*std.ArrayList(std.ArrayList(FuzzFileSnap)),
) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const done = try allocator.alloc(bool, batches.len);
    defer allocator.free(done);
    @memset(done, false);

    var ready: std.ArrayList(usize) = .empty;
    defer ready.deinit(allocator);

    var applied: usize = 0;
    while (applied < batches.len) {
        ready.clearRetainingCapacity();
        for (batches, 0..) |*b, idx| {
            if (done[idx]) continue;
            var all_parents = true;
            for (b.header.parents.slice()) |p| {
                if (!hist.dag.containsBatch(p)) {
                    all_parents = false;
                    break;
                }
            }
            if (all_parents) try ready.append(allocator, idx);
        }
        try testing.expect(ready.items.len > 0);
        const pick = ready.items[rng.uintLessThan(usize, ready.items.len)];
        try testing.expect(try hist.integrate(&batches[pick]));
        done[pick] = true;
        applied += 1;

        if (capture_points) |pts| {
            for (pts) |pt| {
                if (applied == pt) {
                    const ver = try hist.headsClone();
                    var snap = try snapshotLiveTree(allocator, hist);
                    errdefer {
                        for (snap.items) |*s| s.deinit(allocator);
                        snap.deinit(allocator);
                    }
                    try captured_vers.?.append(allocator, ver);
                    try captured_snaps.?.append(allocator, snap);
                }
            }
        }
    }
}

fn runCrdtFuzzSuite(allocator: std.mem.Allocator) !void {
    var prng = std.Random.DefaultPrng.init(0x00db_f022_2026);
    const rng = prng.random();
    const actors = [4]ondb.core.id.ActorId{ 101, 102, 103, 104 };

    var actor_h: [4]ondb.core.history.History = undefined;
    var initialized: usize = 0;
    errdefer for (0..initialized) |i| actor_h[i].deinit();
    for (0..4) |i| {
        actor_h[i] = try ondb.core.history.History.init(allocator, 0xf022);
        initialized += 1;
    }
    defer for (0..4) |i| actor_h[i].deinit();

    var all_batches: std.ArrayList(ondb.core.op.Batch) = .empty;
    defer {
        for (all_batches.items) |*b| b.deinit(allocator);
        all_batches.deinit(allocator);
    }

    var blob_pool = std.AutoHashMapUnmanaged(ondb.core.id.Oid, []u8){};
    defer {
        var bit = blob_pool.valueIterator();
        while (bit.next()) |v| allocator.free(v.*);
        blob_pool.deinit(allocator);
    }

    {
        var seed_ops = try allocator.alloc(ondb.core.op.Op, 2);
        seed_ops[0] = .{ .create_file = .{
            .parent = ondb.core.id.InodeId.ROOT,
            .name = try allocator.dupe(u8, "shared_a.txt"),
            .mode = .regular,
            .line_ending = .lf,
            .content = .{ .text_inline = try allocator.dupe(u8, "header\ncaf\xc3\xa9 \xf0\x9f\x9a\x80\nmiddle\nfooter\n") },
        } };
        seed_ops[1] = .{ .create_file = .{
            .parent = ondb.core.id.InodeId.ROOT,
            .name = try allocator.dupe(u8, "shared_b.txt"),
            .mode = .executable,
            .line_ending = .crlf,
            .content = .{ .text_inline = try allocator.dupe(u8, "alpha\r\nbeta \xe4\xb8\xad\xe6\x96\x87\r\ngamma\r\n") },
        } };
        var seed_batch = ondb.core.op.Batch{
            .header = .{
                .actor = actors[0],
                .start = 1,
                .end = 2,
                .parents = ondb.core.version.Version.ROOT,
                .wall_ms = 500,
            },
            .ops = seed_ops,
            .blobs = try allocator.alloc(ondb.core.op.BlobAttachment, 0),
        };
        errdefer seed_batch.deinit(allocator);
        for (0..4) |i| {
            try testing.expect(try actor_h[i].integrate(&seed_batch));
        }
        try all_batches.append(allocator, seed_batch);
    }

    const total_rounds: usize = 160;
    for (0..total_rounds) |step| {
        const a_idx = rng.uintLessThan(usize, 4);
        const h = &actor_h[a_idx];

        if (all_batches.items.len > 0 and rng.uintLessThan(usize, 100) < 40) {
            const sync_budget = 1 + rng.uintLessThan(usize, 6);
            var synced: usize = 0;
            for (all_batches.items) |*cand| {
                if (synced >= sync_budget) break;
                if (h.dag.containsBatch(cand.header.batchId())) continue;
                var can_apply = true;
                for (cand.header.parents.slice()) |p| {
                    if (!h.dag.containsBatch(p)) {
                        can_apply = false;
                        break;
                    }
                }
                if (can_apply) {
                    for (cand.blobs) |ba| {
                        try h.putBlob(ba.oid, ba.data);
                    }
                    _ = try h.integrate(cand);
                    synced += 1;
                }
            }
        }

        var live_dirs: std.ArrayList(ondb.core.id.InodeId) = .empty;
        defer live_dirs.deinit(allocator);
        try live_dirs.append(allocator, ondb.core.id.InodeId.ROOT);

        var live_text_files: std.ArrayList(ondb.core.id.InodeId) = .empty;
        defer live_text_files.deinit(allocator);
        var live_files: std.ArrayList(ondb.core.id.InodeId) = .empty;
        defer live_files.deinit(allocator);
        var live_symlinks: std.ArrayList(ondb.core.id.InodeId) = .empty;
        defer live_symlinks.deinit(allocator);

        var iit = h.tree.inodes.iterator();
        while (iit.next()) |kv| {
            const iid = kv.key_ptr.*;
            if (iid.isRoot()) continue;
            const node = kv.value_ptr.*;
            if (!(if (node.alive.get()) |a| a.* else false)) continue;
            switch (node.kind) {
                .dir => try live_dirs.append(allocator, iid),
                .symlink => try live_symlinks.append(allocator, iid),
                .file => |*f| {
                    try live_files.append(allocator, iid);
                    const ck = if (f.content.get()) |c| c.* else ondb.core.tree.ContentKind.text;
                    if (ck == .text) try live_text_files.append(allocator, iid);
                },
            }
        }

        var ops: std.ArrayList(ondb.core.op.Op) = .empty;
        errdefer {
            for (ops.items) |*o| o.deinit(allocator);
            ops.deinit(allocator);
        }
        var blobs: std.ArrayList(ondb.core.op.BlobAttachment) = .empty;
        errdefer {
            for (blobs.items) |*ba| ba.deinit(allocator);
            blobs.deinit(allocator);
        }

        const action = rng.uintLessThan(usize, 10);
        if (action <= 1 or live_files.items.len < 2) {
            const parent_dir = live_dirs.items[rng.uintLessThan(usize, live_dirs.items.len)];
            const fname = try std.fmt.allocPrint(allocator, "f_{d}_{d}.txt", .{ a_idx, step });
            errdefer allocator.free(fname);
            const mode: ondb.core.tree.FileMode = if (rng.boolean()) .executable else .regular;
            const le: ondb.core.tree.LineEnding = if (rng.boolean()) .crlf else .lf;
            if (rng.uintLessThan(usize, 5) == 0) {
                var bin_bytes: [24]u8 = undefined;
                rng.bytes(&bin_bytes);
                bin_bytes[0] = 0;
                const oid = ondb.store.crypto.hashBytes(&bin_bytes);
                try blobs.append(allocator, .{ .oid = oid, .data = try allocator.dupe(u8, &bin_bytes) });
                if (!blob_pool.contains(oid)) {
                    try blob_pool.put(allocator, oid, try allocator.dupe(u8, &bin_bytes));
                }
                try ops.append(allocator, .{ .create_file = .{
                    .parent = parent_dir,
                    .name = fname,
                    .mode = mode,
                    .line_ending = .lf,
                    .content = .{ .binary = .{ .oid = oid, .len = bin_bytes.len } },
                } });
            } else {
                const txt = try randomUtf8Text(allocator, rng, 8);
                try ops.append(allocator, .{ .create_file = .{
                    .parent = parent_dir,
                    .name = fname,
                    .mode = mode,
                    .line_ending = le,
                    .content = .{ .text_inline = txt },
                } });
            }
        } else if (action == 2 and live_dirs.items.len < 5) {
            const parent_dir = live_dirs.items[rng.uintLessThan(usize, live_dirs.items.len)];
            const dname = try std.fmt.allocPrint(allocator, "dir_{d}_{d}", .{ a_idx, step });
            try ops.append(allocator, .{ .create_dir = .{ .parent = parent_dir, .name = dname } });
        } else if (action == 3 and live_symlinks.items.len < 4) {
            const parent_dir = live_dirs.items[rng.uintLessThan(usize, live_dirs.items.len)];
            const sname = try std.fmt.allocPrint(allocator, "link_{d}_{d}", .{ a_idx, step });
            errdefer allocator.free(sname);
            const tgt = try std.fmt.allocPrint(allocator, "target_{d}", .{step});
            try ops.append(allocator, .{ .create_symlink = .{ .parent = parent_dir, .name = sname, .target = tgt } });
        } else if ((action == 4 or action == 5) and live_text_files.items.len > 0) {
            const target_iid = live_text_files.items[rng.uintLessThan(usize, live_text_files.items.len)];
            const cur_bytes = (try h.readInodeInView(allocator, target_iid, ondb.core.text.View.EVERYTHING)) orelse try allocator.dupe(u8, "");
            defer allocator.free(cur_bytes);
            const next_bytes = try mutateUtf8Text(allocator, rng, cur_bytes);
            defer allocator.free(next_bytes);
            var dr = try ondb.core.diff.diffBytes(allocator, cur_bytes, next_bytes);
            errdefer dr.deinit(allocator);
            if (dr.splices.items.len > 0) {
                const ins_slice = try dr.inserted.toOwnedSlice(allocator);
                errdefer allocator.free(ins_slice);
                const sp_slice = try dr.splices.toOwnedSlice(allocator);
                errdefer allocator.free(sp_slice);
                try ops.append(allocator, .{ .edit_text = .{
                    .inode = target_iid,
                    .text = ins_slice,
                    .splices = sp_slice,
                } });
            } else {
                dr.deinit(allocator);
            }
        } else if (action == 6 and live_files.items.len > 0) {
            const target_iid = live_files.items[rng.uintLessThan(usize, live_files.items.len)];
            if (rng.uintLessThan(usize, 3) == 0) {
                var bin_bytes: [16]u8 = undefined;
                rng.bytes(&bin_bytes);
                bin_bytes[0] = 0;
                const oid = ondb.store.crypto.hashBytes(&bin_bytes);
                try blobs.append(allocator, .{ .oid = oid, .data = try allocator.dupe(u8, &bin_bytes) });
                if (!blob_pool.contains(oid)) {
                    try blob_pool.put(allocator, oid, try allocator.dupe(u8, &bin_bytes));
                }
                try ops.append(allocator, .{ .set_content = .{
                    .inode = target_iid,
                    .content = .{ .binary = .{ .oid = oid, .len = bin_bytes.len } },
                } });
            } else {
                const txt = try randomUtf8Text(allocator, rng, 6);
                try ops.append(allocator, .{ .set_content = .{
                    .inode = target_iid,
                    .content = .{ .text_inline = txt },
                } });
            }
        } else if (action == 7 and live_files.items.len > 0) {
            const target_iid = live_files.items[rng.uintLessThan(usize, live_files.items.len)];
            const new_parent = live_dirs.items[rng.uintLessThan(usize, live_dirs.items.len)];
            const new_name = try std.fmt.allocPrint(allocator, "mv_{d}_{d}.txt", .{ a_idx, step });
            try ops.append(allocator, .{ .rename = .{
                .inode = target_iid,
                .parent = new_parent,
                .name = new_name,
            } });
        } else if (action == 8 and live_files.items.len > 3) {
            const target_iid = live_files.items[rng.uintLessThan(usize, live_files.items.len)];
            try ops.append(allocator, .{ .remove = .{ .inode = target_iid } });
        } else if (live_symlinks.items.len > 0 and rng.boolean()) {
            const target_iid = live_symlinks.items[rng.uintLessThan(usize, live_symlinks.items.len)];
            const tgt = try std.fmt.allocPrint(allocator, "retarget_{d}_{d}", .{ a_idx, step });
            try ops.append(allocator, .{ .set_symlink_target = .{ .inode = target_iid, .target = tgt } });
        } else if (live_files.items.len > 0) {
            const target_iid = live_files.items[rng.uintLessThan(usize, live_files.items.len)];
            if (rng.boolean()) {
                try ops.append(allocator, .{ .set_mode = .{
                    .inode = target_iid,
                    .mode = if (rng.boolean()) .executable else .regular,
                } });
            } else {
                try ops.append(allocator, .{ .set_line_ending = .{
                    .inode = target_iid,
                    .ending = if (rng.boolean()) .crlf else .lf,
                } });
            }
        }

        if (ops.items.len == 0) {
            for (blobs.items) |*ba| ba.deinit(allocator);
            blobs.deinit(allocator);
            ops.deinit(allocator);
            continue;
        }

        const parents = try h.headsClone();
        const start = h.nextStartTs(&parents);
        const end = start + @as(u64, @intCast(ops.items.len)) - 1;
        var batch = ondb.core.op.Batch{
            .header = .{
                .actor = actors[a_idx],
                .start = start,
                .end = end,
                .parents = parents,
                .wall_ms = @intCast(1000 + step),
            },
            .ops = try ops.toOwnedSlice(allocator),
            .blobs = try blobs.toOwnedSlice(allocator),
        };
        errdefer batch.deinit(allocator);
        try testing.expect(try h.integrate(&batch));
        try all_batches.append(allocator, batch);
    }

    try testing.expect(all_batches.items.len >= 120);

    var r0 = try ondb.core.history.History.init(allocator, 0xf022);
    defer r0.deinit();
    var r1 = try ondb.core.history.History.init(allocator, 0xf022);
    defer r1.deinit();
    var r2 = try ondb.core.history.History.init(allocator, 0xf022);
    defer r2.deinit();

    var bp_it = blob_pool.iterator();
    while (bp_it.next()) |kv| {
        try r0.putBlob(kv.key_ptr.*, kv.value_ptr.*);
        try r1.putBlob(kv.key_ptr.*, kv.value_ptr.*);
        try r2.putBlob(kv.key_ptr.*, kv.value_ptr.*);
    }

    const n = all_batches.items.len;
    const pts = [_]usize{ n / 4, n / 2, (3 * n) / 4, n };
    var cap_vers: std.ArrayList(ondb.core.version.Version) = .empty;
    defer {
        for (cap_vers.items) |*v| v.deinit(allocator);
        cap_vers.deinit(allocator);
    }
    var cap_snaps: std.ArrayList(std.ArrayList(FuzzFileSnap)) = .empty;
    defer {
        for (cap_snaps.items) |*list| {
            for (list.items) |*s| s.deinit(allocator);
            list.deinit(allocator);
        }
        cap_snaps.deinit(allocator);
    }

    try integrateRandomTopoOrder(allocator, &r0, all_batches.items, 1001, &pts, &cap_vers, &cap_snaps);
    try integrateRandomTopoOrder(allocator, &r1, all_batches.items, 2002, null, null, null);
    try integrateRandomTopoOrder(allocator, &r2, all_batches.items, 3003, null, null, null);

    try assertHistoriesConverged(allocator, &r0, &r1);
    try assertHistoriesConverged(allocator, &r0, &r2);

    try testing.expectEqual(@as(usize, 4), cap_vers.items.len);
    for (cap_vers.items, cap_snaps.items, 0..) |*target_ver, expected_snap, idx| {
        const rb_opt = try r1.buildRollbackBatch(allocator, 999, target_ver, @intCast(50_000 + idx));
        if (rb_opt) |rb_val| {
            var rb = rb_val;
            defer rb.deinit(allocator);
            try testing.expect(try r1.integrate(&rb));
        }
        var actual_snap = try snapshotLiveTree(allocator, &r1);
        defer {
            for (actual_snap.items) |*s| s.deinit(allocator);
            actual_snap.deinit(allocator);
        }
        try expectSnapsEqual(expected_snap.items, actual_snap.items);
    }
}

fn isUtf8Boundary(s: []const u8, pos: usize) bool {
    if (pos == 0 or pos == s.len) return true;
    if (pos > s.len) return false;
    return (s[pos] & 0xC0) != 0x80;
}

fn runDiffAndMerge3PropertyFuzz(allocator: std.mem.Allocator) !void {
    var prng = std.Random.DefaultPrng.init(0x00db_d1ff_0099);
    const rng = prng.random();

    for (0..100) |iter| {
        const old = try randomUtf8Text(allocator, rng, 14);
        defer allocator.free(old);
        const new = if (iter % 3 == 0)
            try randomUtf8Text(allocator, rng, 14)
        else
            try mutateUtf8Text(allocator, rng, old);
        defer allocator.free(new);

        var dr = try ondb.core.diff.diffBytes(allocator, old, new);
        defer dr.deinit(allocator);

        var ins_off: usize = 0;
        for (dr.splices.items) |sp| {
            const at: usize = @intCast(sp.at);
            const del: usize = @intCast(sp.del);
            const ins: usize = @intCast(sp.ins);
            try testing.expect(isUtf8Boundary(old, at));
            try testing.expect(isUtf8Boundary(old, at + del));
            try testing.expect(std.unicode.utf8ValidateSlice(dr.inserted.items[ins_off .. ins_off + ins]));
            ins_off += ins;
        }
        const rebuilt = try applyDiffForVerify(allocator, old, dr.splices.items, dr.inserted.items);
        defer allocator.free(rebuilt);
        try testing.expectEqualStrings(new, rebuilt);

        const line_count = 10 + rng.uintLessThan(usize, 18);
        var base_buf: std.ArrayList(u8) = .empty;
        defer base_buf.deinit(allocator);
        var ours_buf: std.ArrayList(u8) = .empty;
        defer ours_buf.deinit(allocator);
        var theirs_buf: std.ArrayList(u8) = .empty;
        defer theirs_buf.deinit(allocator);

        const top_edit = rng.uintLessThan(usize, 3);
        const bot_edit = line_count - 1 - rng.uintLessThan(usize, 3);
        const eol = if (iter % 2 == 0) "\n" else "\r\n";

        for (0..line_count) |li| {
            const line = try std.fmt.allocPrint(allocator, "row-{d}-item-{d}{s}", .{ iter, li, eol });
            defer allocator.free(line);
            try base_buf.appendSlice(allocator, line);
            if (li == top_edit) {
                const oline = try std.fmt.allocPrint(allocator, "ours-edit-{d}-caf\xc3\xa9{s}", .{ iter, eol });
                defer allocator.free(oline);
                try ours_buf.appendSlice(allocator, oline);
            } else {
                try ours_buf.appendSlice(allocator, line);
            }
            if (li == bot_edit) {
                const tline = try std.fmt.allocPrint(allocator, "theirs-edit-{d}-\xf0\x9f\x9a\x80{s}", .{ iter, eol });
                defer allocator.free(tline);
                try theirs_buf.appendSlice(allocator, tline);
            } else {
                try theirs_buf.appendSlice(allocator, line);
            }
        }

        const m = try ondb.fs.worktrees.merge3Lines(allocator, base_buf.items, ours_buf.items, theirs_buf.items);
        defer allocator.free(m.output);
        try testing.expect(!m.has_conflict);
        try testing.expect(std.mem.indexOf(u8, m.output, "ours-edit-") != null);
        try testing.expect(std.mem.indexOf(u8, m.output, "theirs-edit-") != null);
    }

    const cm = try ondb.fs.worktrees.merge3Lines(
        allocator,
        "a\nshared\nb\n",
        "a\nours-val\nb\n",
        "a\ntheirs-val\nb\n",
    );
    defer allocator.free(cm.output);
    try testing.expect(cm.has_conflict);
    try testing.expect(std.mem.indexOf(u8, cm.output, "<<<<<<< ") != null);
}

fn applyDiffForVerify(
    allocator: std.mem.Allocator,
    old: []const u8,
    splices: []const ondb.core.diff.Splice,
    inserted: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var old_pos: usize = 0;
    var ins_pos: usize = 0;
    for (splices) |sp| {
        const at: usize = @intCast(sp.at);
        const del: usize = @intCast(sp.del);
        const ins: usize = @intCast(sp.ins);
        try out.appendSlice(allocator, old[old_pos..at]);
        try out.appendSlice(allocator, inserted[ins_pos .. ins_pos + ins]);
        old_pos = at + del;
        ins_pos += ins;
    }
    try out.appendSlice(allocator, old[old_pos..]);
    return try out.toOwnedSlice(allocator);
}

fn sliceLinesForVerify(bytes: []const u8, start_line: usize, max_lines: usize) []const u8 {
    var cur: usize = 0;
    var start_idx: usize = 0;
    while (start_idx < bytes.len and cur < start_line) : (start_idx += 1) {
        if (bytes[start_idx] == '\n') cur += 1;
    }
    var end_idx = start_idx;
    var emitted: usize = 0;
    while (end_idx < bytes.len and emitted < max_lines) : (end_idx += 1) {
        if (bytes[end_idx] == '\n') emitted += 1;
    }
    return bytes[start_idx..end_idx];
}

fn countLinesExact(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var n: usize = 0;
    for (bytes) |b| {
        if (b == '\n') n += 1;
    }
    return if (bytes[bytes.len - 1] == '\n') n else n + 1;
}

const SteerInjectCtx = struct {
    eng: *ondb.session.engine.SessionEngine,
    injected: bool = false,
    prompt: []const u8,
};

fn steerOnFirstDelta(ptr: *anyopaque, thread_id: u128, _: u128, ev: *const ondb.providers.interface.Event) void {
    const ctx: *SteerInjectCtx = @ptrCast(@alignCast(ptr));
    if (!ctx.injected and ev.kind == .text_delta) {
        ctx.injected = true;
        _ = ctx.eng.steer(thread_id, ctx.prompt, .mock, null) catch {};
    }
}

fn openNativeMock(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: ondb.providers.interface.ProviderId,
    _: ondb.providers.interface.StartRequest,
) anyerror!ondb.providers.interface.RunHandle {
    return ondb.providers.registry.MockRun.start(allocator, .{ .native_steer = true, .split_chunks = true });
}

fn openFallbackMock(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: ondb.providers.interface.ProviderId,
    _: ondb.providers.interface.StartRequest,
) anyerror!ondb.providers.interface.RunHandle {
    return ondb.providers.registry.MockRun.start(allocator, .{ .native_steer = false, .split_chunks = true });
}

test "all 10 providers, durable queuing, native and fallback steering, edit/rollback/branching, pagination" {
    const allocator = testing.allocator;
    const io = testing.io;
    const tmp_root = "/tmp/0ndb-verify-session";
    const tmp_state = "/tmp/0ndb-verify-session-state";
    cleanDir(io, tmp_root);
    cleanDir(io, tmp_state);
    defer cleanDir(io, tmp_root);
    defer cleanDir(io, tmp_state);

    const all = ondb.providers.registry.listProviders(io);
    try testing.expectEqual(@as(usize, 10), all.len);

    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, tmp_root, tmp_state, 99);
    defer ws.deinit();
    _ = try ws.writeFileDirect(1, "app.txt", "v1\n");

    var eng = try ondb.session.engine.SessionEngine.open(allocator, io, &ws, tmp_state);
    defer eng.deinit();
    eng.page_size = 2;

    const tid = try eng.createThread("main session", .codex, null);

    var native_ctx = SteerInjectCtx{ .eng = &eng, .prompt = "native-nudge" };
    const native_factory = ondb.session.engine.HandleFactory{ .ptr = null, .open_fn = openNativeMock };
    const asst1 = try eng.executePrompt(
        tid,
        "first",
        .codex,
        null,
        native_factory,
        .{ .ptr = &native_ctx, .on_event = steerOnFirstDelta },
    );
    const m1 = eng.journal.messages.get(asst1).?;
    try testing.expect(std.mem.indexOf(u8, m1.content, "[steered:native-nudge]") != null);

    _ = try ws.writeFileDirect(1, "app.txt", "v2-branch-a\n");

    var fb_ctx = SteerInjectCtx{ .eng = &eng, .prompt = "fallback-nudge" };
    const fb_factory = ondb.session.engine.HandleFactory{ .ptr = null, .open_fn = openFallbackMock };
    const asst2 = try eng.executePrompt(
        tid,
        "second",
        .claude_code,
        null,
        fb_factory,
        .{ .ptr = &fb_ctx, .on_event = steerOnFirstDelta },
    );
    const m2 = eng.journal.messages.get(asst2).?;
    try testing.expectEqualStrings("reply:fallback-nudge", m2.content);

    const q1 = try eng.enqueue(tid, "queued-1", .muse, null);
    const q2 = try eng.enqueue(tid, "queued-2", .antigravity, null);
    try eng.editQueued(q1, "queued-1-edited");
    try eng.cancelQueued(q2);
    const drained = try eng.drainQueue(tid, native_factory, null);
    try testing.expectEqual(@as(usize, 1), drained);

    const branch_a_leaf = eng.journal.threads.get(tid).?.leaf_msg_id.?;
    const user2_id = eng.journal.messages.get(m1.parent_id.?).?.msg_id;
    _ = user2_id;
    const orig_second_user = blk: {
        var cur: ?u128 = branch_a_leaf;
        while (cur) |cid| {
            const msg = eng.journal.messages.get(cid).?;
            if (std.mem.eql(u8, msg.content, "second")) break :blk cid;
            cur = msg.parent_id;
        }
        unreachable;
    };

    const edited_user = try eng.editMessage(tid, orig_second_user, "second-edited", .pi, null);
    _ = try ws.writeFileDirect(1, "app.txt", "v2-branch-b\n");
    const branch_b_leaf = try eng.executePrompt(tid, "branch-b-follow", .pi, null, native_factory, null);
    _ = branch_b_leaf;

    const sibs = try eng.siblings(allocator, edited_user);
    defer allocator.free(sibs);
    try testing.expectEqual(@as(usize, 2), sibs.len);

    const file_b = (try ws.history.readFileAt(allocator, "app.txt", null)).?;
    defer allocator.free(file_b);
    try testing.expectEqualStrings("v2-branch-b\n", file_b);

    const restored_leaf = try eng.switchBranch(tid, orig_second_user);
    try testing.expectEqual(branch_a_leaf, restored_leaf);
    const file_a = (try ws.history.readFileAt(allocator, "app.txt", null)).?;
    defer allocator.free(file_a);
    try testing.expectEqualStrings("v2-branch-a\n", file_a);

    var p1 = try eng.getPage(allocator, tid, null, 2);
    defer p1.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), p1.messages.len);
    try testing.expect(p1.has_more);
    var p2 = try eng.getPage(allocator, tid, p1.next_before, 2);
    defer p2.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), p2.messages.len);

    const SpyState = struct {
        allocator: std.mem.Allocator,
        last_resume: ?[]u8 = null,
        last_fork_at: ?[]u8 = null,
        fail_resume_once: bool = false,
        calls: usize = 0,

        fn deinit(self: *@This()) void {
            if (self.last_resume) |s| self.allocator.free(s);
            if (self.last_fork_at) |s| self.allocator.free(s);
        }

        fn open(
            ptr: ?*anyopaque,
            alloc: std.mem.Allocator,
            _: std.Io,
            _: ondb.providers.interface.ProviderId,
            req: ondb.providers.interface.StartRequest,
        ) anyerror!ondb.providers.interface.RunHandle {
            const st: *@This() = @ptrCast(@alignCast(ptr.?));
            st.calls += 1;
            if (st.last_resume) |old| st.allocator.free(old);
            st.last_resume = if (req.resume_id) |r| try st.allocator.dupe(u8, r) else null;
            if (st.last_fork_at) |old| st.allocator.free(old);
            st.last_fork_at = if (req.fork_at) |f| try st.allocator.dupe(u8, f) else null;
            if (st.fail_resume_once and req.resume_id != null) {
                st.fail_resume_once = false;
                return error.ResumeFailed;
            }
            return ondb.providers.registry.MockRun.start(alloc, .{ .native_steer = true, .split_chunks = false });
        }
    };

    var spy = SpyState{ .allocator = allocator };
    defer spy.deinit();
    const spy_factory = ondb.session.engine.HandleFactory{ .ptr = &spy, .open_fn = SpyState.open };

    const ctid = try eng.createThread("continuity", .claude_code, null);
    const ca1 = try eng.executePrompt(ctid, "remember alpha-7", .claude_code, null, spy_factory, null);
    try testing.expect(spy.last_resume == null);
    try testing.expect(spy.last_fork_at == null);
    try testing.expectEqualStrings("reply:remember alpha-7", eng.journal.messages.get(ca1).?.content);

    const ca2 = try eng.executePrompt(ctid, "what codeword?", .claude_code, null, spy_factory, null);
    try testing.expectEqualStrings("mock-session-1", spy.last_resume.?);
    try testing.expect(spy.last_fork_at == null);
    try testing.expectEqualStrings("reply:what codeword?", eng.journal.messages.get(ca2).?.content);

    const ca3 = try eng.executePrompt(ctid, "switch to codex", .codex, null, spy_factory, null);
    try testing.expect(spy.last_resume == null);
    const m_ca3 = eng.journal.messages.get(ca3).?;
    try testing.expect(std.mem.indexOf(u8, m_ca3.content, "<conversation_history>") != null);
    try testing.expect(std.mem.indexOf(u8, m_ca3.content, "remember alpha-7") != null);
    try eng.journal.putToolCall(ca3, "tc-1", "edit_file", "{\"path\":\"a.zig\"}", "edited 2 lines", false);

    const ca_back = try eng.executePrompt(ctid, "back to claude now", .claude_code, null, spy_factory, null);
    try testing.expectEqualStrings("mock-session-1", spy.last_resume.?);
    try testing.expect(spy.last_fork_at == null);
    const m_back = eng.journal.messages.get(ca_back).?;
    try testing.expect(std.mem.indexOf(u8, m_back.content, "While you were away") != null);
    try testing.expect(std.mem.indexOf(u8, m_back.content, "<conversation_history>\n[User]\nswitch to codex\n") != null);
    try testing.expect(std.mem.indexOf(u8, m_back.content, "Tool: edit_file") != null);

    const ca_slash = try eng.executePrompt(ctid, "/compact", .codex, null, spy_factory, null);
    try testing.expectEqualStrings("mock-session-1", spy.last_resume.?);
    try testing.expectEqualStrings("reply:/compact", eng.journal.messages.get(ca_slash).?.content);

    spy.fail_resume_once = true;
    const ca4 = try eng.executePrompt(ctid, "follow up after resume failure", .codex, null, spy_factory, null);
    try testing.expect(spy.last_resume == null);
    const m_ca4 = eng.journal.messages.get(ca4).?;
    try testing.expect(std.mem.indexOf(u8, m_ca4.content, "<conversation_history>") != null);
    try testing.expect(std.mem.indexOf(u8, m_ca4.content, "switch to codex") != null);

    try eng.rollback(ctid, ca1);
    const ca_fork = try eng.executePrompt(ctid, "branched off turn 1", .claude_code, null, spy_factory, null);
    try testing.expectEqualStrings("mock-session-1", spy.last_resume.?);
    try testing.expectEqualStrings("turn-1", spy.last_fork_at.?);
    try testing.expectEqualStrings("reply:branched off turn 1", eng.journal.messages.get(ca_fork).?.content);

    var pool = ondb.providers.pool.WarmPool.init(allocator, io, 2, 60_000);
    defer pool.deinit();
    const h_claude = try ondb.providers.registry.MockRun.start(allocator, .{});
    const h_codex = try ondb.providers.registry.MockRun.start(allocator, .{});
    pool.park(.claude_code, "sess-a", "sonnet", "/tmp/ws", h_claude);
    pool.park(.codex, "sess-b", "o3", "/tmp/ws", h_codex);
    try testing.expectEqual(@as(usize, 2), pool.warmCount());
    const taken_a = pool.take(.claude_code, "sess-a", "sonnet", "/tmp/ws");
    try testing.expect(taken_a != null);
    taken_a.?.close();
    const mismatch_b = pool.take(.codex, "sess-b", "gpt-5", "/tmp/ws");
    try testing.expect(mismatch_b == null);
    try testing.expectEqual(@as(usize, 0), pool.warmCount());

    {
        const MultiBlockMock = struct {
            allocator: std.mem.Allocator,
            step: usize = 0,
            const vt = ondb.providers.interface.RunHandle.VTable{
                .send = sendImpl,
                .steer = steerImpl,
                .next = nextImpl,
                .interrupt = interruptImpl,
                .close = closeImpl,
            };
            fn open(
                _: ?*anyopaque,
                alloc: std.mem.Allocator,
                _: std.Io,
                _: ondb.providers.interface.ProviderId,
                _: ondb.providers.interface.StartRequest,
            ) anyerror!ondb.providers.interface.RunHandle {
                const self = try alloc.create(@This());
                self.* = .{ .allocator = alloc };
                return .{ .ptr = self, .vtable = &vt };
            }
            fn sendImpl(_: *anyopaque, _: []const u8) anyerror!void {}
            fn steerImpl(_: *anyopaque, _: []const u8, _: ?[]const u8) anyerror!ondb.providers.interface.SteerOutcome {
                return .requires_interrupt_fallback;
            }
            fn nextImpl(ptr: *anyopaque) anyerror!?ondb.providers.interface.Event {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const s = self.step;
                self.step += 1;
                return switch (s) {
                    0 => .{ .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, "mb-sess-1") } } },
                    1 => .{ .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, "block-one") } } },
                    2 => .{ .kind = .{ .tool_started = .{
                        .id = try self.allocator.dupe(u8, "tc-mb-1"),
                        .name = try self.allocator.dupe(u8, "bash"),
                        .input_json = try self.allocator.dupe(u8, "{\"cmd\":\"ls\"}"),
                    } } },
                    3 => .{ .kind = .{ .tool_finished = .{
                        .id = try self.allocator.dupe(u8, "tc-mb-1"),
                        .output = try self.allocator.dupe(u8, "main.zig"),
                        .is_error = false,
                    } } },
                    4 => .{ .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, "block-two") } } },
                    5 => .{ .kind = .{ .turn_ended = .{ .ok = true, .err_msg = null } } },
                    else => null,
                };
            }
            fn interruptImpl(_: *anyopaque) void {}
            fn closeImpl(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.allocator.destroy(self);
            }
        };

        const mb_tid = try eng.createThread("multi-block", .claude_code, "claude-sonnet-4");
        const mb_factory = ondb.session.engine.HandleFactory{ .ptr = null, .open_fn = MultiBlockMock.open };
        const mb_asst = try eng.executePrompt(mb_tid, "run tool", .claude_code, null, mb_factory, null);
        const mb_msg = eng.journal.messages.get(mb_asst).?;
        try testing.expectEqualStrings("block-one\nblock-two", mb_msg.content);
        const mb_user = mb_msg.parent_id.?;
        const edited_mb = try eng.editMessage(mb_tid, mb_user, "edited with default model", null, null);
        const edited_msg = eng.journal.messages.get(edited_mb).?;
        try testing.expectEqualStrings("claude-sonnet-4", edited_msg.model.?);

        var seen_sid = false;
        var evs: std.ArrayList(ondb.providers.interface.Event) = .empty;
        defer {
            for (evs.items) |*ev| ev.deinit(allocator);
            evs.deinit(allocator);
        }
        try ondb.providers.claude.parseStreamLine(
            allocator,
            "{\"type\":\"assistant\",\"uuid\":\"u1\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t9\",\"name\":\"read_file\",\"input\":{\"path\":\"src/main.zig\",\"line\":42}}]}}",
            &seen_sid,
            &evs,
        );
        try testing.expectEqual(@as(usize, 1), evs.items.len);
        try testing.expect(std.mem.indexOf(u8, evs.items[0].kind.tool_started.input_json, "src/main.zig") != null);
        try testing.expect(std.mem.indexOf(u8, evs.items[0].kind.tool_started.input_json, "42") != null);

        try ondb.providers.claude.parseStreamLine(
            allocator,
            "{\"type\":\"user\",\"uuid\":\"u2\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t9\",\"content\":[{\"type\":\"text\",\"text\":\"line-a\"},{\"type\":\"text\",\"text\":\"line-b\"}]}]}}",
            &seen_sid,
            &evs,
        );
        try testing.expectEqual(@as(usize, 2), evs.items.len);
        try testing.expectEqualStrings("line-a\nline-b", evs.items[1].kind.tool_finished.output);

        var pi_parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"content\":[{\"type\":\"text\",\"text\":\"pi-out\"}]}",
            .{},
        );
        defer pi_parsed.deinit();
        const pi_txt = try ondb.providers.json_rpc.extractTextOrJson(allocator, pi_parsed.value);
        defer allocator.free(pi_txt);
        try testing.expectEqualStrings("pi-out", pi_txt);

        var acp_parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"acp-out\"}}]",
            .{},
        );
        defer acp_parsed.deinit();
        const acp_txt = try ondb.providers.json_rpc.extractTextOrJson(allocator, acp_parsed.value);
        defer allocator.free(acp_txt);
        try testing.expectEqualStrings("acp-out", acp_txt);
    }

    {
        try testing.expect(ws.scopes.items.len >= 1);
        try testing.expect(ws.scopes.items[ws.scopes.items.len - 1].ended_ms != null);

        const ew_state = "/tmp/0ndb-verify-eng-wt-state";
        const ew_chk = "/tmp/0ndb-verify-eng-wt-chk";
        cleanDir(io, ew_state);
        cleanDir(io, ew_chk);
        defer cleanDir(io, ew_state);
        defer cleanDir(io, ew_chk);
        var wts = try ondb.fs.worktrees.Worktrees.open(allocator, io, ew_state, ew_chk);
        defer wts.deinit();
        var scr = try wts.scratch("eng-scratch");
        defer scr.deinit(allocator);
        eng.attachWorktrees(&wts);
        defer eng.attachWorktrees(null);
        const wt_tid = try eng.createThreadInWorktree("wt-thread", .mock, null, scr.id);
        try testing.expectEqual(wts.getWorkspace(scr.id).?, eng.workspaceForThread(wt_tid));

        try testing.expect(!ondb.playground.server.isSafeRelPath(""));
        try testing.expect(!ondb.playground.server.isSafeRelPath("../etc/passwd"));
        try testing.expect(!ondb.playground.server.isSafeRelPath("/etc/passwd"));
        try testing.expect(!ondb.playground.server.isSafeRelPath("a/../b"));
        try testing.expect(!ondb.playground.server.isSafeRelPath(".git/config"));
        try testing.expect(!ondb.playground.server.isSafeRelPath(".0ndb/batches.0ndb"));
        try testing.expect(!ondb.playground.server.isSafeRelPath("a\\b"));
        try testing.expect(ondb.playground.server.isSafeRelPath("src/main.zig"));
        try testing.expect(ondb.playground.server.isSafeRelPath("README.md"));

        const srv_mod = ondb.playground.server;
        try testing.expectEqual(
            srv_mod.HttpFraming{ .content_length = 42 },
            try srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42"),
        );
        try testing.expectEqual(
            srv_mod.HttpFraming{ .content_length = 42 },
            try srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nContent-Length: 42\r\nContent-Length: 42"),
        );
        try testing.expectError(
            error.BadFraming,
            srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nContent-Length: 42\r\nContent-Length: 43"),
        );
        try testing.expectEqual(
            srv_mod.HttpFraming{ .chunked = {} },
            try srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nTransfer-Encoding: chunked"),
        );
        try testing.expectError(
            error.BadFraming,
            srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked"),
        );
        try testing.expectError(
            error.BadFraming,
            srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nContent-Length: 12abc"),
        );
        try testing.expectError(
            error.PayloadTooLarge,
            srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nContent-Length: 18446744073709551615"),
        );
        try testing.expectError(
            error.PayloadTooLarge,
            srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nContent-Length: 99999999"),
        );
        try testing.expectError(
            error.BadFraming,
            srv_mod.parseHttpFraming("POST /api/file HTTP/1.1\r\nTransfer-Encoding: gzip"),
        );

        const chunked_wire = "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Check: ok\r\n\r\nGET /next HTTP/1.1\r\n\r\n";
        const dec_res = try srv_mod.decodeChunkedBody(allocator, chunked_wire, 1024);
        switch (dec_res) {
            .need_more => return error.TestUnexpectedResult,
            .complete => |done| {
                defer allocator.free(done.body);
                try testing.expectEqualStrings("hello world", done.body);
                try testing.expectEqualStrings("GET /next HTTP/1.1\r\n\r\n", chunked_wire[done.consumed..]);
            },
        }
        const need_res = try srv_mod.decodeChunkedBody(allocator, "5\r\nhel", 1024);
        try testing.expect(need_res == .need_more);
        try testing.expectError(error.PayloadTooLarge, srv_mod.decodeChunkedBody(allocator, "5\r\nhello\r\n0\r\n\r\n", 4));
        try testing.expectError(error.BadFraming, srv_mod.decodeChunkedBody(allocator, "5\r\nhelloXX0\r\n\r\n", 1024));

        const ap_root = "/tmp/0ndb-verify-ap-root";
        const ap_state = "/tmp/0ndb-verify-ap-state";
        const ap_wt_state = "/tmp/0ndb-verify-ap-wt-state";
        const ap_wt_chk = "/tmp/0ndb-verify-ap-wt-chk";
        cleanDir(io, ap_root);
        cleanDir(io, ap_state);
        cleanDir(io, ap_wt_state);
        cleanDir(io, ap_wt_chk);
        defer cleanDir(io, ap_root);
        defer cleanDir(io, ap_state);
        defer cleanDir(io, ap_wt_state);
        defer cleanDir(io, ap_wt_chk);

        var primary_ws = try ondb.fs.workspace.Workspace.open(allocator, io, ap_root, ap_state, 0xaaaa_1111);
        defer primary_ws.deinit();
        _ = try primary_ws.writeFileDirect(primary_ws.disk_actor, "base.txt", "line1\nline2\n");

        var fork_id_saved: u128 = 0;
        {
            var awts = try ondb.fs.worktrees.Worktrees.open(allocator, io, ap_wt_state, ap_wt_chk);
            defer awts.deinit();
            var pinfo = try awts.attachPrimary(&primary_ws, "primary");
            defer pinfo.deinit(allocator);
            try testing.expect(awts.isBorrowed(pinfo.id));
            try testing.expectError(error.CannotRemovePrimary, awts.remove(pinfo.id, true, false));

            var finfo = try awts.fork(pinfo.id, "feat", null, null);
            defer finfo.deinit(allocator);
            fork_id_saved = finfo.id;
            const fws_ptr = awts.getWorkspace(finfo.id).?;
            _ = try fws_ptr.writeFileDirect(fws_ptr.disk_actor, "fork_only.txt", "from-fork\n");
            _ = try primary_ws.writeFileDirect(primary_ws.disk_actor, "primary_only.txt", "from-primary\n");

            var land_rep = try awts.landFork(finfo.id);
            defer land_rep.deinit(allocator);
            try testing.expect(land_rep.landed >= 1);
            const landed_bytes = (try primary_ws.history.readFileAt(allocator, "fork_only.txt", null)).?;
            defer allocator.free(landed_bytes);
            try testing.expectEqualStrings("from-fork\n", landed_bytes);
        }
        {
            var awts2 = try ondb.fs.worktrees.Worktrees.open(allocator, io, ap_wt_state, ap_wt_chk);
            defer awts2.deinit();
            try testing.expect(awts2.get(primary_ws.history.history_id) == null);
            try testing.expect(awts2.get(fork_id_saved) != null);
        }
    }

    {
        const s_model = ondb.session.model;
        const s_pager = ondb.session.pager;
        const codec = ondb.store.codec;

        var bad_ver_w = codec.Writer{};
        defer bad_ver_w.deinit(allocator);
        try bad_ver_w.writeVarint(allocator, 0xFFFF_FFFF);
        var bad_ver_r = codec.Reader.init(bad_ver_w.items());
        try testing.expectError(error.CorruptRecord, s_model.decodeVersionChecked(allocator, &bad_ver_r));

        var bad_page_w = codec.Writer{};
        defer bad_page_w.deinit(allocator);
        try bad_page_w.writeRaw(allocator, &s_pager.PAGE_MAGIC);
        try bad_page_w.writeU8(allocator, s_pager.PAGE_VERSION);
        try bad_page_w.writeU128(allocator, 1);
        try bad_page_w.writeU8(allocator, 0);
        try bad_page_w.writeU8(allocator, 0);
        try bad_page_w.writeU32(allocator, 0xFFFF_FFFF);
        try testing.expectError(error.CorruptRecord, s_pager.MessagePage.decode(allocator, bad_page_w.items()));

        var bad_thread_w = codec.Writer{};
        defer bad_thread_w.deinit(allocator);
        try bad_thread_w.writeU128(allocator, 1);
        try bad_thread_w.writeU128(allocator, 2);
        try bad_thread_w.writeBytes(allocator, "t");
        try bad_thread_w.writeU8(allocator, 0);
        try bad_thread_w.writeU8(allocator, 0);
        try bad_thread_w.writeU8(allocator, 250);
        try bad_thread_w.writeOptBytes(allocator, null);
        try bad_thread_w.writeU8(allocator, 0);
        try bad_thread_w.writeU32(allocator, 0);
        try bad_thread_w.writeU32(allocator, 0);
        try bad_thread_w.writeU64(allocator, 1);
        try bad_thread_w.writeU64(allocator, 1);
        var bad_thread_r = codec.Reader.init(bad_thread_w.items());
        try testing.expectError(error.CorruptRecord, s_model.Thread.decode(allocator, &bad_thread_r));

        var bad_msg_w = codec.Writer{};
        defer bad_msg_w.deinit(allocator);
        try bad_msg_w.writeU128(allocator, 10);
        try bad_msg_w.writeU128(allocator, 1);
        try bad_msg_w.writeU8(allocator, 0);
        try bad_msg_w.writeU8(allocator, 99);
        try bad_msg_w.writeBytes(allocator, "hi");
        var bad_msg_r = codec.Reader.init(bad_msg_w.items());
        try testing.expectError(error.CorruptRecord, s_model.Message.decode(allocator, &bad_msg_r));

        var bad_q_w = codec.Writer{};
        defer bad_q_w.deinit(allocator);
        try bad_q_w.writeU128(allocator, 11);
        try bad_q_w.writeU128(allocator, 1);
        try bad_q_w.writeU8(allocator, 99);
        try bad_q_w.writeU8(allocator, 1);
        var bad_q_r = codec.Reader.init(bad_q_w.items());
        try testing.expectError(error.CorruptRecord, s_model.QueueItem.decode(allocator, &bad_q_r));
    }

    {
        const j_dir = "/tmp/0ndb-verify-journal-reopen";
        cleanDir(io, j_dir);
        defer cleanDir(io, j_dir);

        const j_mod = ondb.session.journal;
        const tid_j: u128 = 0x1111;
        const mid_j: u128 = 0x2222;

        {
            var j = try j_mod.SessionJournal.open(allocator, io, j_dir);
            defer j.deinit();

            const rv = ondb.core.version.Version.single(ondb.core.id.OpId.init(7, 9));
            try j.putThread(.{
                .thread_id = tid_j,
                .worktree_id = 1,
                .title = try allocator.dupe(u8, "persist"),
                .leaf_msg_id = mid_j,
                .head_page = null,
                .default_provider = .grok,
                .default_model = try allocator.dupe(u8, "grok-3"),
                .status = .idle,
                .queued_count = 0,
                .message_count = 1,
                .created_ms = 100,
                .updated_ms = 100,
                .root_version = rv,
            });

            try j.putMessage(.{
                .msg_id = mid_j,
                .thread_id = tid_j,
                .parent_id = null,
                .role = .assistant,
                .content = try allocator.dupe(u8, "partial"),
                .provider = .grok,
                .model = null,
                .native_session = null,
                .native_turn = null,
                .pre_version = ondb.core.version.Version.ROOT,
                .post_version = ondb.core.version.Version.ROOT,
                .git_branch = null,
                .git_commit = null,
                .worktree_id = 1,
                .status = .failed,
                .steer_of = null,
                .switched_from = null,
                .created_ms = 100,
                .updated_ms = 101,
                .err_msg = try allocator.dupe(u8, "boom-err"),
            }, false);

            const giant = try allocator.alloc(u8, 300 * 1024);
            defer allocator.free(giant);
            @memset(giant, 'a');
            try j.putToolCall(mid_j, "call-big", "bash", "{\"cmd\":\"cat\"}", "", false);
            try j.putToolCall(mid_j, "call-big", "", "", giant, false);
            try j.flushWal();
        }

        {
            var j2 = try j_mod.SessionJournal.open(allocator, io, j_dir);
            defer j2.deinit();
            const t2 = j2.threads.get(tid_j).?;
            try testing.expectEqual(ondb.providers.interface.ProviderId.grok, t2.default_provider);
            try testing.expect(t2.root_version != null);
            try testing.expectEqual(@as(usize, 1), t2.root_version.?.len);
            const jm2 = j2.messages.get(mid_j).?;
            try testing.expectEqualStrings("boom-err", jm2.err_msg.?);
            const tcs = j2.toolCallsFor(mid_j);
            try testing.expectEqual(@as(usize, 1), tcs.len);
            try testing.expectEqualStrings("bash", tcs[0].name);
            try testing.expect(tcs[0].output.len <= j_mod.MAX_TOOL_OUTPUT_BYTES);
            try testing.expect(std.mem.endsWith(u8, tcs[0].output, j_mod.TOOL_TRUNCATION_MARKER));
        }
    }

    {
        const rb_root = "/tmp/0ndb-verify-rb-root";
        const rb_state = "/tmp/0ndb-verify-rb-state";
        cleanDir(io, rb_root);
        cleanDir(io, rb_state);
        defer cleanDir(io, rb_root);
        defer cleanDir(io, rb_state);

        var rb_ws = try ondb.fs.workspace.Workspace.open(allocator, io, rb_root, rb_state, 777);
        defer rb_ws.deinit();
        _ = try rb_ws.writeFileDirect(1, "init.txt", "baseline-content\n");

        var rb_eng = try ondb.session.engine.SessionEngine.open(allocator, io, &rb_ws, rb_state);
        defer rb_eng.deinit();
        rb_eng.page_size = 2;

        const rb_tid = try rb_eng.createThread("root-preserve", .mock, null);
        _ = try rb_ws.writeFileDirect(1, "init.txt", "mutated\n");
        _ = try rb_ws.writeFileDirect(1, "added.txt", "temp\n");
        const m_rb1 = try rb_eng.executePrompt(rb_tid, "first", .mock, null, native_factory, null);
        _ = m_rb1;

        try rb_eng.rollback(rb_tid, null);
        const restored_init = (try rb_ws.history.readFileAt(allocator, "init.txt", null)).?;
        defer allocator.free(restored_init);
        try testing.expectEqualStrings("baseline-content\n", restored_init);
        const missing_added = try rb_ws.history.readFileAt(allocator, "added.txt", null);
        try testing.expect(missing_added == null);

        const DeltaThenTextMock = struct {
            allocator: std.mem.Allocator,
            step: usize = 0,
            const vt = ondb.providers.interface.RunHandle.VTable{
                .send = sendImpl,
                .steer = steerImpl,
                .next = nextImpl,
                .interrupt = interruptImpl,
                .close = closeImpl,
            };
            fn open(
                _: ?*anyopaque,
                alloc: std.mem.Allocator,
                _: std.Io,
                _: ondb.providers.interface.ProviderId,
                _: ondb.providers.interface.StartRequest,
            ) anyerror!ondb.providers.interface.RunHandle {
                const self = try alloc.create(@This());
                self.* = .{ .allocator = alloc };
                return .{ .ptr = self, .vtable = &vt };
            }
            fn sendImpl(_: *anyopaque, _: []const u8) anyerror!void {}
            fn steerImpl(_: *anyopaque, _: []const u8, _: ?[]const u8) anyerror!ondb.providers.interface.SteerOutcome {
                return .requires_interrupt_fallback;
            }
            fn nextImpl(ptr: *anyopaque) anyerror!?ondb.providers.interface.Event {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const s = self.step;
                self.step += 1;
                return switch (s) {
                    0 => .{ .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, "dt-1") } } },
                    1 => .{ .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, "alpha ") } } },
                    2 => .{ .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, "one") } } },
                    3 => .{ .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, "alpha one") } } },
                    4 => .{ .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, "beta two") } } },
                    5 => .{ .kind = .{ .tool_started = .{
                        .id = try self.allocator.dupe(u8, "t-1"),
                        .name = try self.allocator.dupe(u8, "read"),
                        .input_json = try self.allocator.dupe(u8, "{}"),
                    } } },
                    6 => .{ .kind = .{ .tool_finished = .{
                        .id = try self.allocator.dupe(u8, "t-1"),
                        .output = try self.allocator.dupe(u8, "ok"),
                        .is_error = false,
                    } } },
                    7 => .{ .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, "gamma three") } } },
                    8 => .{ .kind = .{ .turn_ended = .{ .ok = true, .err_msg = null } } },
                    else => null,
                };
            }
            fn interruptImpl(_: *anyopaque) void {}
            fn closeImpl(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.allocator.destroy(self);
            }
        };

        const dt_factory = ondb.session.engine.HandleFactory{ .ptr = null, .open_fn = DeltaThenTextMock.open };
        const dt_tid = try rb_eng.createThread("delta-blocks", .claude_code, null);
        const dt_asst = try rb_eng.executePrompt(dt_tid, "multi", .claude_code, null, dt_factory, null);
        const dt_msg = rb_eng.journal.messages.get(dt_asst).?;
        try testing.expectEqual(ondb.session.model.MessageStatus.completed, dt_msg.status);
        try testing.expectEqualStrings("alpha one\nbeta two\ngamma three", dt_msg.content);

        const SilentEofMock = struct {
            allocator: std.mem.Allocator,
            const vt = ondb.providers.interface.RunHandle.VTable{
                .send = sendImpl,
                .steer = steerImpl,
                .next = nextImpl,
                .interrupt = interruptImpl,
                .close = closeImpl,
            };
            fn open(
                _: ?*anyopaque,
                alloc: std.mem.Allocator,
                _: std.Io,
                _: ondb.providers.interface.ProviderId,
                _: ondb.providers.interface.StartRequest,
            ) anyerror!ondb.providers.interface.RunHandle {
                const self = try alloc.create(@This());
                self.* = .{ .allocator = alloc };
                return .{ .ptr = self, .vtable = &vt };
            }
            fn sendImpl(_: *anyopaque, _: []const u8) anyerror!void {}
            fn steerImpl(_: *anyopaque, _: []const u8, _: ?[]const u8) anyerror!ondb.providers.interface.SteerOutcome {
                return .requires_interrupt_fallback;
            }
            fn nextImpl(_: *anyopaque) anyerror!?ondb.providers.interface.Event {
                return null;
            }
            fn interruptImpl(_: *anyopaque) void {}
            fn closeImpl(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.allocator.destroy(self);
            }
        };
        const eof_factory = ondb.session.engine.HandleFactory{ .ptr = null, .open_fn = SilentEofMock.open };
        const eof_tid = try rb_eng.createThread("eof-fail", .codex, null);
        const eof_asst = try rb_eng.executePrompt(eof_tid, "crash", .codex, null, eof_factory, null);
        try testing.expectEqual(ondb.session.model.MessageStatus.failed, rb_eng.journal.messages.get(eof_asst).?.status);
        try testing.expectEqual(ondb.session.model.SessionStatus.failed, rb_eng.journal.threads.get(eof_tid).?.status);

        const pg_tid_a = try rb_eng.createThread("page-a", .mock, null);
        const pg_tid_b = try rb_eng.createThread("page-b", .mock, null);
        const pg_b_msg = try rb_eng.appendUserMessage(pg_tid_b, null, .user, "other-thread", .mock, null, null, null);
        try testing.expectError(error.MessageWrongThread, rb_eng.getPage(allocator, pg_tid_a, pg_b_msg, 2));

        const pm1 = try rb_eng.appendUserMessage(pg_tid_a, null, .user, "p-msg-1", .mock, null, null, null);
        const pm2 = try rb_eng.appendUserMessage(pg_tid_a, pm1, .assistant, "p-msg-2", .mock, null, null, null);
        const pm3 = try rb_eng.appendUserMessage(pg_tid_a, pm2, .user, "p-msg-3", .mock, null, null, null);
        _ = try rb_eng.appendUserMessage(pg_tid_a, pm3, .assistant, "p-msg-4", .mock, null, null, null);

        if (rb_eng.journal.messages.fetchRemove(pm1)) |kv| {
            var v = kv.value;
            v.deinit(allocator);
        }
        if (rb_eng.journal.messages.fetchRemove(pm2)) |kv| {
            var v = kv.value;
            v.deinit(allocator);
        }

        var sealed_p1 = try rb_eng.getPage(allocator, pg_tid_a, null, 2);
        defer sealed_p1.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), sealed_p1.messages.len);
        try testing.expect(sealed_p1.has_more);
        try testing.expectEqualStrings("p-msg-3", sealed_p1.messages[0].content);
        try testing.expectEqualStrings("p-msg-4", sealed_p1.messages[1].content);

        var sealed_p2 = try rb_eng.getPage(allocator, pg_tid_a, sealed_p1.next_before, 2);
        defer sealed_p2.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), sealed_p2.messages.len);
        try testing.expect(!sealed_p2.has_more);
        try testing.expectEqualStrings("p-msg-1", sealed_p2.messages[0].content);
        try testing.expectEqualStrings("p-msg-2", sealed_p2.messages[1].content);

        const ri_tid = try rb_eng.createThread("resume-int", .mock, null);
        const ri_qid = try rb_eng.enqueue(ri_tid, "stuck-q", .mock, null);
        if (rb_eng.journal.queue_items.getPtr(ri_qid)) |q| q.status = .dispatching;
        const ri_mid = try rb_eng.appendUserMessage(ri_tid, null, .assistant, "in-flight", .mock, null, null, null);
        if (rb_eng.journal.messages.getPtr(ri_mid)) |m| m.status = .running;
        if (rb_eng.journal.threads.getPtr(ri_tid)) |t| t.status = .running;

        const recovered = try rb_eng.resumeInterrupted();
        try testing.expect(recovered >= 3);
        try testing.expectEqual(ondb.session.model.MessageStatus.interrupted, rb_eng.journal.messages.get(ri_mid).?.status);
        try testing.expectEqual(ondb.session.model.QueueStatus.pending, rb_eng.journal.queue_items.get(ri_qid).?.status);
        try testing.expectEqual(ondb.session.model.SessionStatus.queued, rb_eng.journal.threads.get(ri_tid).?.status);
    }

    {
        const dr_root = "/tmp/0ndb-verify-defer-rb-root";
        const dr_state = "/tmp/0ndb-verify-defer-rb-state";
        const dr_wt_state = "/tmp/0ndb-verify-defer-rb-wt-state";
        const dr_wt_chk = "/tmp/0ndb-verify-defer-rb-wt-chk";
        cleanDir(io, dr_root);
        cleanDir(io, dr_state);
        cleanDir(io, dr_wt_state);
        cleanDir(io, dr_wt_chk);
        defer cleanDir(io, dr_root);
        defer cleanDir(io, dr_state);
        defer cleanDir(io, dr_wt_state);
        defer cleanDir(io, dr_wt_chk);

        var main_ws = try ondb.fs.workspace.Workspace.open(allocator, io, dr_root, dr_state, 0xbbbb_0001);
        defer main_ws.deinit();
        _ = try main_ws.writeFileDirect(1, "main.txt", "main-orig\n");

        var dr_wts = try ondb.fs.worktrees.Worktrees.open(allocator, io, dr_wt_state, dr_wt_chk);
        defer dr_wts.deinit();
        var scr_info = try dr_wts.scratch("defer-wt");
        defer scr_info.deinit(allocator);
        const scr_ws = dr_wts.getWorkspace(scr_info.id).?;
        _ = try scr_ws.writeFileDirect(1, "wt.txt", "wt-v1\n");
        const v1 = try scr_ws.history.headsClone();
        var v1_owned = true;
        defer if (v1_owned) {
            var tmp = v1;
            tmp.deinit(allocator);
        };
        _ = try scr_ws.writeFileDirect(1, "wt.txt", "wt-v2\n");

        {
            var e1 = try ondb.session.engine.SessionEngine.open(allocator, io, &main_ws, dr_state);
            defer e1.deinit();
            e1.attachWorktrees(&dr_wts);
            defer e1.attachWorktrees(null);
            const wt_tid = try e1.createThreadInWorktree("wt-defer", .mock, null, scr_info.id);
            try e1.journal.beginRollback(.{
                .intent_id = 0x9999_0001,
                .thread_id = wt_tid,
                .target_msg_id = null,
                .target_version = v1,
                .target_git_commit = null,
                .created_ms = 1,
                .target_git_branch = null,
            });
            v1_owned = false;
        }

        {
            var e2 = try ondb.session.engine.SessionEngine.open(allocator, io, &main_ws, dr_state);
            defer e2.deinit();
            try testing.expectEqual(@as(usize, 1), e2.journal.pending_rollbacks.count());
            const main_still = (try main_ws.history.readFileAt(allocator, "main.txt", null)).?;
            defer allocator.free(main_still);
            try testing.expectEqualStrings("main-orig\n", main_still);

            e2.attachWorktrees(&dr_wts);
            defer e2.attachWorktrees(null);
            try testing.expectEqual(@as(usize, 0), e2.journal.pending_rollbacks.count());
            const wt_restored = (try scr_ws.history.readFileAt(allocator, "wt.txt", null)).?;
            defer allocator.free(wt_restored);
            try testing.expectEqualStrings("wt-v1\n", wt_restored);
        }
    }

    {
        const NonBlockingCloseHandle = struct {
            allocator: std.mem.Allocator,
            pool: *ondb.providers.pool.WarmPool,
            closed_count: *usize,
            const vt = ondb.providers.interface.RunHandle.VTable{
                .send = sendImpl,
                .steer = steerImpl,
                .next = nextImpl,
                .interrupt = interruptImpl,
                .close = closeImpl,
            };
            fn create(
                alloc: std.mem.Allocator,
                target_pool: *ondb.providers.pool.WarmPool,
                closed_count: *usize,
            ) !ondb.providers.interface.RunHandle {
                const self = try alloc.create(@This());
                self.* = .{ .allocator = alloc, .pool = target_pool, .closed_count = closed_count };
                return .{ .ptr = self, .vtable = &vt };
            }
            fn sendImpl(_: *anyopaque, _: []const u8) anyerror!void {}
            fn steerImpl(_: *anyopaque, _: []const u8, _: ?[]const u8) anyerror!ondb.providers.interface.SteerOutcome {
                return .requires_interrupt_fallback;
            }
            fn nextImpl(_: *anyopaque) anyerror!?ondb.providers.interface.Event {
                return null;
            }
            fn interruptImpl(_: *anyopaque) void {}
            fn closeImpl(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                _ = self.pool.warmCount();
                self.closed_count.* += 1;
                self.allocator.destroy(self);
            }
        };

        var nb_pool = ondb.providers.pool.WarmPool.init(allocator, io, 1, 60_000);
        defer nb_pool.deinit();
        var closed_count: usize = 0;
        const h1 = try NonBlockingCloseHandle.create(allocator, &nb_pool, &closed_count);
        const h2 = try NonBlockingCloseHandle.create(allocator, &nb_pool, &closed_count);
        nb_pool.park(.claude_code, "s1", null, "/tmp", h1);
        nb_pool.park(.claude_code, "s2", null, "/tmp", h2);
        try testing.expectEqual(@as(usize, 1), closed_count);
        try testing.expectEqual(@as(usize, 1), nb_pool.warmCount());
        nb_pool.closeIdle();
        try testing.expectEqual(@as(usize, 2), closed_count);
        try testing.expectEqual(@as(usize, 0), nb_pool.warmCount());
    }

    {
        const rpc = ondb.providers.json_rpc;
        var crash_pipe = try rpc.SubprocessPipe.spawn(allocator, io, &.{ "/bin/sh", "-c", "echo boom-stderr >&2; exit 42" }, "/tmp");
        defer crash_pipe.deinit();
        while (try crash_pipe.readNextLine(5000)) |raw_line| {
            var line = raw_line;
            line.deinit(allocator);
        }
        try testing.expectEqual(@as(?i32, 42), crash_pipe.waitExitStatus());
        try testing.expect(std.mem.indexOf(u8, crash_pipe.lastStderrSnippet(), "boom-stderr") != null);
        const cmsg = try crash_pipe.formatCrashMessage(allocator, "testcli");
        defer allocator.free(cmsg);
        try testing.expect(std.mem.indexOf(u8, cmsg, "exited with code 42") != null);
        try testing.expect(std.mem.indexOf(u8, cmsg, "boom-stderr") != null);

        var stub_pipe = try rpc.SubprocessPipe.spawn(allocator, io, &.{ "/bin/sh", "-c", "trap '' TERM; echo ready; sleep 30" }, "/tmp");
        defer stub_pipe.deinit();
        if (try stub_pipe.readNextLine(5000)) |ready_raw| {
            var ready_line = ready_raw;
            ready_line.deinit(allocator);
        }
        const t0 = rpc.monotonicMs(io);
        stub_pipe.killGraceful(150);
        const elapsed = rpc.monotonicMs(io) - t0;
        try testing.expect(elapsed < 4000);
        try testing.expectEqual(@as(?i32, -9), stub_pipe.waitExitStatus());
    }

    {
        try testing.expectEqual(ondb.providers.interface.ProviderId.grok, ondb.providers.interface.ProviderId.fromSlug("grok").?);
        try testing.expectEqualStrings("grok", ondb.providers.registry.programFor(.grok));
        try testing.expectEqualStrings("{\"decision\":\"decline\"}", ondb.providers.codex.approvalDecisionJson(.accept_edits, "item/commandExecution/requestApproval"));
        try testing.expectEqualStrings("{\"decision\":\"accept\"}", ondb.providers.codex.approvalDecisionJson(.accept_edits, "item/fileChange/requestApproval"));
        try testing.expectEqualStrings("{\"decision\":\"accept\"}", ondb.providers.codex.approvalDecisionJson(.full, "item/commandExecution/requestApproval"));

        var muse_cmd_p = try std.json.parseFromSlice(std.json.Value, allocator, "{\"kind\":\"commandExecution\"}", .{});
        defer muse_cmd_p.deinit();
        try testing.expectEqualStrings("deny", ondb.providers.muse.approvalChoice(.accept_edits, muse_cmd_p.value));
        var muse_file_p = try std.json.parseFromSlice(std.json.Value, allocator, "{\"kind\":\"fileChange\"}", .{});
        defer muse_file_p.deinit();
        try testing.expectEqualStrings("approve", ondb.providers.muse.approvalChoice(.accept_edits, muse_file_p.value));

        var acp_perm_p = try std.json.parseFromSlice(std.json.Value, allocator, "{\"options\":[{\"optionId\":\"opt-allow\",\"kind\":\"allow_once\"}]}", .{});
        defer acp_perm_p.deinit();
        const acp_cancel = try ondb.providers.acp.formatPermissionOutcome(allocator, .plan, acp_perm_p.value);
        defer allocator.free(acp_cancel);
        try testing.expectEqualStrings("{\"outcome\":\"cancelled\"}", acp_cancel);

        var c_seen = false;
        var c_evs: std.ArrayList(ondb.providers.interface.Event) = .empty;
        defer {
            for (c_evs.items) |*ev| ev.deinit(allocator);
            c_evs.deinit(allocator);
        }
        try ondb.providers.claude.parseStreamLine(
            allocator,
            "{\"type\":\"result\",\"is_error\":false,\"total_cost_usd\":0.0125,\"usage\":{\"input_tokens\":10,\"output_tokens\":20}}",
            &c_seen,
            &c_evs,
        );
        try testing.expectEqual(@as(usize, 2), c_evs.items.len);
        try testing.expect(c_evs.items[0].kind == .usage);
        try testing.expectEqual(@as(?f64, 0.0125), c_evs.items[0].kind.usage.cost_usd);

        try ondb.providers.claude.parseStreamLine(
            allocator,
            "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"c1\",\"content\":\"ok\"}]},\"tool_use_result\":{\"stdout\":\"out-line\",\"stderr\":\"err-line\"}}",
            &c_seen,
            &c_evs,
        );
        try testing.expectEqual(@as(usize, 3), c_evs.items.len);
        try testing.expectEqualStrings("out-line", c_evs.items[2].kind.tool_finished.stdout.?);
        try testing.expectEqualStrings("err-line", c_evs.items[2].kind.tool_finished.stderr.?);
    }
}

fn runSyncHardeningChecks(allocator: std.mem.Allocator, io: std.Io) !void {
    const linux = std.os.linux;
    const codec = ondb.store.codec;
    const crypto = ondb.store.crypto;
    const wire = ondb.sync.wire;
    const relay = ondb.sync.relay;
    const client_mod = ondb.sync.client;

    {
        var w = codec.Writer{};
        defer w.deinit(allocator);
        try w.writeVarint(allocator, 1_000_000);
        try w.writeU32(allocator, 0x12345678);
        var r1 = codec.Reader.init(w.items());
        try testing.expectError(error.UnexpectedEof, r1.readCount(8, 10_000_000));

        var r2 = codec.Reader.init(w.items());
        try testing.expectError(error.InvalidData, r2.readCount(1, 500_000));

        w.clearRetainingCapacity();
        try w.writeVarint(allocator, 4);
        for (0..16) |_| try w.writeByte(allocator, 0xaa);
        var r3 = codec.Reader.init(w.items());
        try testing.expectEqual(@as(usize, 4), try r3.readCount(4, 100));

        const non_canon_a = [_]u8{ 0x80, 0x00 };
        var rna = codec.Reader.init(&non_canon_a);
        try testing.expectError(error.InvalidVarint, rna.readVarint());

        const non_canon_b = [_]u8{ 0x81, 0x00 };
        var rnb = codec.Reader.init(&non_canon_b);
        try testing.expectError(error.InvalidVarint, rnb.readVarint());

        const non_canon_c = [_]u8{ 0x80, 0x80, 0x00 };
        var rnc = codec.Reader.init(&non_canon_c);
        try testing.expectError(error.InvalidVarint, rnc.readVarint());

        const over_10_a = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 };
        var ro1 = codec.Reader.init(&over_10_a);
        try testing.expectError(error.InvalidVarint, ro1.readVarint());

        const over_10_b = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
        var ro2 = codec.Reader.init(&over_10_b);
        try testing.expectError(error.InvalidVarint, ro2.readVarint());

        const over_11 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x81, 0x01 };
        var ro3 = codec.Reader.init(&over_11);
        try testing.expectError(error.InvalidVarint, ro3.readVarint());

        const canon_zero = [_]u8{0x00};
        var rz = codec.Reader.init(&canon_zero);
        try testing.expectEqual(@as(u64, 0), try rz.readVarint());

        const canon_max = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
        var rmax = codec.Reader.init(&canon_max);
        try testing.expectEqual(std.math.maxInt(u64), try rmax.readVarint());

        const bool_bytes = [_]u8{ 0, 1, 2, 0xff };
        var rb = codec.Reader.init(&bool_bytes);
        try testing.expectEqual(false, try rb.readBool());
        try testing.expectEqual(true, try rb.readBool());
        try testing.expectError(error.InvalidData, rb.readBool());
        try testing.expectError(error.InvalidData, rb.readBool());

        var r_ov = codec.Reader{ .data = &bool_bytes, .pos = std.math.maxInt(usize) - 2 };
        try testing.expectError(error.UnexpectedEof, r_ov.readFixed(8));
    }

    {
        const k1: crypto.Key = @splat(0x11);
        const k2: crypto.Key = @splat(0x22);
        const env_r = try crypto.sealRandom(allocator, io, k1, "aad-1", "hello-crypto");
        defer allocator.free(env_r);
        const pt_r = try crypto.open(allocator, k1, "aad-1", env_r);
        defer allocator.free(pt_r);
        try testing.expectEqualStrings("hello-crypto", pt_r);

        try testing.expectError(error.AuthenticationFailed, crypto.open(allocator, k2, "aad-1", env_r));
        try testing.expectError(error.AuthenticationFailed, crypto.open(allocator, k1, "aad-2", env_r));

        const bad_ver = try allocator.dupe(u8, env_r);
        defer allocator.free(bad_ver);
        bad_ver[0] ^= 0x01;
        try testing.expectError(error.InvalidEnvelope, crypto.open(allocator, k1, "aad-1", bad_ver));

        const bad_cmt = try allocator.dupe(u8, env_r);
        defer allocator.free(bad_cmt);
        bad_cmt[1 + 32 + 5] ^= 0x80;
        try testing.expectError(error.AuthenticationFailed, crypto.open(allocator, k1, "aad-1", bad_cmt));

        const env_d1 = try crypto.sealWithDerivedNonce(allocator, k1, "ctx-1", "aad", "derived-msg");
        defer allocator.free(env_d1);
        const env_d2 = try crypto.sealWithDerivedNonce(allocator, k1, "ctx-1", "aad", "derived-msg");
        defer allocator.free(env_d2);
        const env_d3 = try crypto.sealWithDerivedNonce(allocator, k1, "ctx-2", "aad", "derived-msg");
        defer allocator.free(env_d3);
        try testing.expectEqualSlices(u8, env_d1, env_d2);
        try testing.expect(!std.mem.eql(u8, env_d1, env_d3));
        const pt_d = try crypto.open(allocator, k1, "aad", env_d1);
        defer allocator.free(pt_d);
        try testing.expectEqualStrings("derived-msg", pt_d);

        const det_nonce: crypto.Nonce = @splat(0x42);
        const env_t = try crypto.sealDeterministicForTest(allocator, k1, "test-aad", "det-pt", det_nonce);
        defer allocator.free(env_t);
        const pt_t = try crypto.open(allocator, k1, "test-aad", env_t);
        defer allocator.free(pt_t);
        try testing.expectEqualStrings("det-pt", pt_t);
    }

    {
        const huge = try allocator.alloc(u8, wire.MAX_FRAME_LEN + 1);
        defer allocator.free(huge);
        @memset(huge, 0);
        try testing.expectError(error.FrameTooLarge, wire.encodeFrame(allocator, .put_frame, 0, huge));

        var sp: [2]std.posix.fd_t = undefined;
        const sp_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sp);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(sp_rc));
        defer _ = linux.close(sp[0]);
        defer _ = linux.close(sp[1]);
        var tbuf: [8]u8 = undefined;
        try testing.expectError(error.Timeout, wire.readExactFdTimeout(sp[0], &tbuf, 30));
    }

    const h_relay_dir = "/tmp/0ndb-verify-hardening-relay";
    cleanDir(io, h_relay_dir);
    defer cleanDir(io, h_relay_dir);

    const secret = crypto.hashBytes("hardening-relay-secret");
    const master_key: crypto.Key = @splat(0x7c);

    var server = try relay.RelayServer.start(
        allocator,
        io,
        h_relay_dir,
        .{ 127, 0, 0, 1 },
        0,
        secret,
        true,
    );
    defer server.deinit();
    const port = server.port;

    const srv_thread = try std.Thread.spawn(.{}, relayThreadMain, .{&server});
    defer {
        server.stop();
        srv_thread.join();
    }

    const topic_a = ondb.core.id.streamId("hardening", 1001);
    const topic_b = ondb.core.id.streamId("hardening", 1002);

    {
        var esc = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer esc.deinit();
        const short_write_exp = ondb.core.id.nowMs(io) + 45;
        try esc.authorizeTopicWithExpiry(topic_a, wire.PERM_WRITE, short_write_exp);
        try esc.authorizeTopicWithExpiry(topic_a, wire.PERM_READ, 0);

        const s1 = try esc.putEncryptedFrame(topic_a, "before-write-expiry");
        try testing.expect(s1 >= 1);

        io.sleep(.fromMilliseconds(70), .awake) catch {};
        try testing.expectError(error.PutFrameFailed, esc.putEncryptedFrame(topic_a, "after-write-expiry"));

        const read_ok = try esc.getEncryptedRange(allocator, topic_a, 0, 10);
        defer {
            for (read_ok) |*f| f.deinit(allocator);
            allocator.free(read_ok);
        }
        try testing.expectEqual(@as(usize, 1), read_ok.len);
        try testing.expectEqualStrings("before-write-expiry", read_ok[0].plaintext);
    }

    {
        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(s_rc));
        const rfd: std.posix.fd_t = @intCast(s_rc);
        defer _ = linux.close(rfd);
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(rfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))));

        const tok_a = client_mod.CapabilityToken.mint(secret, topic_a, wire.PERM_READ | wire.PERM_WRITE, 0);
        var auth_a: [73]u8 = undefined;
        @memcpy(auth_a[0..32], &tok_a.topic);
        auth_a[32] = tok_a.perms;
        std.mem.writeInt(u64, auth_a[33..41], tok_a.expires_ms, .little);
        @memcpy(auth_a[41..73], &tok_a.mac);
        try wire.writeFrameBlocking(allocator, rfd, .auth, 0, &auth_a);
        var aa = try wire.readFrameBlocking(allocator, rfd);
        defer aa.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, aa.op);

        const tok_b = client_mod.CapabilityToken.mint(secret, topic_b, wire.PERM_READ | wire.PERM_WRITE, 0);
        var auth_b: [73]u8 = undefined;
        @memcpy(auth_b[0..32], &tok_b.topic);
        auth_b[32] = tok_b.perms;
        std.mem.writeInt(u64, auth_b[33..41], tok_b.expires_ms, .little);
        @memcpy(auth_b[41..73], &tok_b.mac);
        try wire.writeFrameBlocking(allocator, rfd, .auth, 0, &auth_b);
        var ab = try wire.readFrameBlocking(allocator, rfd);
        defer ab.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, ab.op);

        const shared_oid = crypto.hashBytes("shared-oid-seed");

        var pb1: [64 + 16]u8 = undefined;
        @memcpy(pb1[0..32], &topic_a);
        @memcpy(pb1[32..64], &shared_oid);
        @memcpy(pb1[64..], "topic-a-original");
        try wire.writeFrameBlocking(allocator, rfd, .put_blob, 0, &pb1);
        var r_pb1 = try wire.readFrameBlocking(allocator, rfd);
        defer r_pb1.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, r_pb1.op);

        var gb_b: [64]u8 = undefined;
        @memcpy(gb_b[0..32], &topic_b);
        @memcpy(gb_b[32..64], &shared_oid);
        try wire.writeFrameBlocking(allocator, rfd, .get_blob, 0, &gb_b);
        var r_gb_b = try wire.readFrameBlocking(allocator, rfd);
        defer r_gb_b.deinit(allocator);
        try testing.expectEqual(wire.Op.blob_data, r_gb_b.op);
        try testing.expectEqual(@as(u8, 0), r_gb_b.payload[32]);

        var pb2: [64 + 16]u8 = undefined;
        @memcpy(pb2[0..32], &topic_b);
        @memcpy(pb2[32..64], &shared_oid);
        @memcpy(pb2[64..], "topic-b-distinct");
        try wire.writeFrameBlocking(allocator, rfd, .put_blob, 0, &pb2);
        var r_pb2 = try wire.readFrameBlocking(allocator, rfd);
        defer r_pb2.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, r_pb2.op);

        var pb_ov: [64 + 16]u8 = undefined;
        @memcpy(pb_ov[0..32], &topic_a);
        @memcpy(pb_ov[32..64], &shared_oid);
        @memcpy(pb_ov[64..], "topic-a-tampered");
        try wire.writeFrameBlocking(allocator, rfd, .put_blob, 0, &pb_ov);
        var r_ov = try wire.readFrameBlocking(allocator, rfd);
        defer r_ov.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, r_ov.op);

        var gb_a: [64]u8 = undefined;
        @memcpy(gb_a[0..32], &topic_a);
        @memcpy(gb_a[32..64], &shared_oid);
        try wire.writeFrameBlocking(allocator, rfd, .get_blob, 0, &gb_a);
        var r_gb_a = try wire.readFrameBlocking(allocator, rfd);
        defer r_gb_a.deinit(allocator);
        try testing.expectEqual(wire.Op.blob_data, r_gb_a.op);
        try testing.expectEqual(@as(u8, 1), r_gb_a.payload[32]);
        try testing.expectEqualStrings("topic-a-original", r_gb_a.payload[33..]);

        try wire.writeFrameBlocking(allocator, rfd, .get_blob, 0, &gb_b);
        var r_gb_b2 = try wire.readFrameBlocking(allocator, rfd);
        defer r_gb_b2.deinit(allocator);
        try testing.expectEqual(@as(u8, 1), r_gb_b2.payload[32]);
        try testing.expectEqualStrings("topic-b-distinct", r_gb_b2.payload[33..]);

        const poison = try allocator.alloc(u8, wire.MAX_FRAME_LEN);
        defer allocator.free(poison);
        @memset(poison, 0xab);
        @memcpy(poison[0..32], &topic_a);
        try wire.writeFrameBlocking(allocator, rfd, .put_frame, 0, poison);
        var r_poison = try wire.readFrameBlocking(allocator, rfd);
        defer r_poison.deinit(allocator);
        try testing.expectEqual(wire.Op.err, r_poison.op);
        try testing.expect(r_poison.payload.len >= 1);
        try testing.expectEqual(@intFromEnum(wire.ErrCode.bad_frame), r_poison.payload[0]);
    }

    {
        const ro_tok = client_mod.CapabilityToken.mint(secret, topic_a, wire.PERM_READ, 0);
        var ro_client = try client_mod.SyncClient.connectWithToken(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, ro_tok);
        defer ro_client.deinit();
        try ro_client.authorizeTopic(topic_a, wire.PERM_READ);
        const got = try ro_client.getEncryptedRange(allocator, topic_a, 0, 10);
        defer {
            for (got) |*f| f.deinit(allocator);
            allocator.free(got);
        }
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectError(error.MissingCapabilityToken, ro_client.authorizeTopic(topic_a, wire.PERM_WRITE));
        try testing.expectError(error.MissingCapabilityToken, ro_client.authorizeTopic(topic_b, wire.PERM_READ));
        try testing.expectError(error.PutFrameFailed, ro_client.putEncryptedFrame(topic_a, "should-fail"));
    }

    {
        const page_topic = ondb.core.id.streamId("hardening-paged", 2001);
        var pw = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer pw.deinit();
        try pw.authorizeTopic(page_topic, wire.PERM_ALL);
        for (0..150) |i| {
            var msg_buf: [32]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "frame-{d:0>3}", .{i});
            _ = try pw.putEncryptedFrame(page_topic, msg);
        }

        var pr = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer pr.deinit();
        try pr.authorizeTopic(page_topic, wire.PERM_READ);
        var first_page = try pr.getEncryptedRangePage(allocator, page_topic, 0, 50);
        defer first_page.deinit(allocator);
        try testing.expectEqual(@as(usize, 50), first_page.frames.len);
        try testing.expect(first_page.has_more);

        const rest = try pr.getEncryptedRange(allocator, page_topic, first_page.last_seq, 0);
        defer {
            for (rest) |*f| f.deinit(allocator);
            allocator.free(rest);
        }
        try testing.expectEqual(@as(usize, 100), rest.len);
        try testing.expectEqualStrings("frame-050", rest[0].plaintext);
        try testing.expectEqualStrings("frame-149", rest[99].plaintext);
    }

    {
        const ooo_a_root = "/tmp/0ndb-verify-ooo-a";
        const ooo_a_state = "/tmp/0ndb-verify-ooo-a-state";
        const ooo_b_root = "/tmp/0ndb-verify-ooo-b";
        const ooo_b_state = "/tmp/0ndb-verify-ooo-b-state";
        cleanDir(io, ooo_a_root);
        cleanDir(io, ooo_a_state);
        cleanDir(io, ooo_b_root);
        cleanDir(io, ooo_b_state);
        defer cleanDir(io, ooo_a_root);
        defer cleanDir(io, ooo_a_state);
        defer cleanDir(io, ooo_b_root);
        defer cleanDir(io, ooo_b_state);

        const ooo_hid: u128 = 555001;
        var wsa = try ondb.fs.workspace.Workspace.open(allocator, io, ooo_a_root, ooo_a_state, ooo_hid);
        defer wsa.deinit();
        var wsb = try ondb.fs.workspace.Workspace.open(allocator, io, ooo_b_root, ooo_b_state, ooo_hid);
        defer wsb.deinit();

        _ = try wsa.writeFileDirect(wsa.disk_actor, "chain.txt", "step1\n");
        _ = try wsa.writeFileDirect(wsa.disk_actor, "chain.txt", "step1\nstep2\n");
        _ = try wsa.writeFileDirect(wsa.disk_actor, "chain.txt", "step1\nstep2\nstep3\n");

        var batches: std.ArrayList([]u8) = .empty;
        defer {
            for (batches.items) |b| allocator.free(b);
            batches.deinit(allocator);
        }
        for (0..wsa.batch_log.count()) |i| {
            const v = try wsa.batch_log.readAt(i);
            if (v.header.kind == ondb.fs.workspace.FRAME_BATCH) {
                try batches.append(allocator, try allocator.dupe(u8, v.payload));
            }
        }
        try testing.expectEqual(@as(usize, 3), batches.items.len);

        const ooo_topic = ondb.core.id.worktreeStreamId(ooo_hid);
        var pub_c = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer pub_c.deinit();
        try pub_c.authorizeTopic(ooo_topic, wire.PERM_ALL);

        _ = try pub_c.putEncryptedFrame(ooo_topic, batches.items[2]);
        _ = try pub_c.putEncryptedFrame(ooo_topic, batches.items[1]);

        var sub_c1 = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer sub_c1.deinit();
        const r_wait = try sub_c1.pullWorkspace(&wsb, 0);
        try testing.expectEqual(@as(usize, 0), r_wait.applied);
        try testing.expectEqual(@as(usize, 2), sub_c1.waitingCount(&wsb));

        _ = try pub_c.putEncryptedFrame(ooo_topic, batches.items[0]);

        var sub_c2 = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer sub_c2.deinit();
        const r_conv = try sub_c2.pullWorkspace(&wsb, 0);
        try testing.expectEqual(@as(usize, 3), r_conv.applied);
        try testing.expectEqual(@as(usize, 0), sub_c2.waitingCount(&wsb));

        const txt = (try wsb.history.readFileAt(allocator, "chain.txt", null)).?;
        defer allocator.free(txt);
        try testing.expectEqualStrings("step1\nstep2\nstep3\n", txt);
    }

    {
        const mb_a_root = "/tmp/0ndb-verify-mb-a";
        const mb_a_state = "/tmp/0ndb-verify-mb-a-state";
        const mb_b_root = "/tmp/0ndb-verify-mb-b";
        const mb_b_state = "/tmp/0ndb-verify-mb-b-state";
        cleanDir(io, mb_a_root);
        cleanDir(io, mb_a_state);
        cleanDir(io, mb_b_root);
        cleanDir(io, mb_b_state);
        defer cleanDir(io, mb_a_root);
        defer cleanDir(io, mb_a_state);
        defer cleanDir(io, mb_b_root);
        defer cleanDir(io, mb_b_state);

        const mb_hid: u128 = 555002;
        var wsa = try ondb.fs.workspace.Workspace.open(allocator, io, mb_a_root, mb_a_state, mb_hid);
        defer wsa.deinit();
        var wsb = try ondb.fs.workspace.Workspace.open(allocator, io, mb_b_root, mb_b_state, mb_hid);
        defer wsb.deinit();

        const bin_data = "\x00\x01\x02missing-blob-payload\xff\xfe";
        {
            const f = try std.Io.Dir.cwd().createFile(io, mb_a_root ++ "/secret.bin", .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, bin_data);
        }
        _ = try wsa.ingestDisk();
        const bin_oid = crypto.hashBytes(bin_data);

        const mb_topic = ondb.core.id.worktreeStreamId(mb_hid);
        var pub_c = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer pub_c.deinit();
        try pub_c.authorizeTopic(mb_topic, wire.PERM_ALL);

        const v0 = try wsa.batch_log.readAt(0);
        var br = codec.Reader.init(v0.payload);
        var b_dec = try ondb.core.op.Batch.decode(allocator, &br);
        defer b_dec.deinit(allocator);
        var stripped = b_dec;
        stripped.blobs = &.{};
        var sw = codec.Writer{};
        defer sw.deinit(allocator);
        try stripped.encode(allocator, &sw);
        _ = try pub_c.putEncryptedFrame(mb_topic, sw.items());

        var sub_c = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer sub_c.deinit();
        const p1 = try sub_c.pullWorkspace(&wsb, 0);
        try testing.expectEqual(@as(usize, 0), p1.applied);
        try testing.expectEqual(@as(usize, 1), sub_c.waitingCount(&wsb));

        try pub_c.putEncryptedBlob(mb_topic, bin_oid, bin_data);
        const p2 = try sub_c.pullWorkspace(&wsb, 0);
        try testing.expectEqual(@as(usize, 1), p2.applied);
        try testing.expectEqual(@as(usize, 0), sub_c.waitingCount(&wsb));

        const got_bin = try std.Io.Dir.cwd().readFileAlloc(io, mb_b_root ++ "/secret.bin", allocator, .limited(1024));
        defer allocator.free(got_bin);
        try testing.expectEqualStrings(bin_data, got_bin);
    }

    {
        const cr_a_root = "/tmp/0ndb-verify-crash-a";
        const cr_a_state = "/tmp/0ndb-verify-crash-a-state";
        const cr_b_root = "/tmp/0ndb-verify-crash-b";
        const cr_b_state = "/tmp/0ndb-verify-crash-b-state";
        cleanDir(io, cr_a_root);
        cleanDir(io, cr_a_state);
        cleanDir(io, cr_b_root);
        cleanDir(io, cr_b_state);
        defer cleanDir(io, cr_a_root);
        defer cleanDir(io, cr_a_state);
        defer cleanDir(io, cr_b_root);
        defer cleanDir(io, cr_b_state);

        const cr_hid: u128 = 555003;
        const cr_topic = ondb.core.id.worktreeStreamId(cr_hid);
        var wsa = try ondb.fs.workspace.Workspace.open(allocator, io, cr_a_root, cr_a_state, cr_hid);
        defer wsa.deinit();
        var wsb = try ondb.fs.workspace.Workspace.open(allocator, io, cr_b_root, cr_b_state, cr_hid);
        defer wsb.deinit();

        _ = try wsa.writeFileDirect(wsa.disk_actor, "crash.txt", "v1\n");

        var c1 = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer c1.deinit();
        const pushed1 = try c1.pushWorkspace(&wsa);
        try testing.expectEqual(@as(usize, 1), pushed1);
        const orig_sender = c1.sender_id;

        _ = try wsa.writeFileDirect(wsa.disk_actor, "crash.txt", "v2\n");

        var c2 = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer c2.deinit();
        const pushed2 = try c2.pushWorkspace(&wsa);
        try testing.expectEqual(@as(usize, 1), pushed2);
        try testing.expectEqual(orig_sender, c2.sender_id);

        var insp = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer insp.deinit();
        try insp.authorizeTopic(cr_topic, wire.PERM_READ);
        const cr_frames = try insp.getEncryptedRange(allocator, cr_topic, 0, 10);
        defer {
            for (cr_frames) |*f| f.deinit(allocator);
            allocator.free(cr_frames);
        }
        try testing.expectEqual(@as(usize, 2), cr_frames.len);
        try testing.expectEqual(orig_sender, cr_frames[0].sender_id);
        try testing.expectEqual(@as(u64, 1), cr_frames[0].sender_seq);
        try testing.expectEqual(orig_sender, cr_frames[1].sender_id);
        try testing.expect(cr_frames[1].sender_seq >= 65);

        var b1 = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer b1.deinit();
        const pr1 = try b1.pullWorkspace(&wsb, 0);
        try testing.expectEqual(@as(usize, 2), pr1.applied);

        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(s_rc));
        const rfd: std.posix.fd_t = @intCast(s_rc);
        defer _ = linux.close(rfd);
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(rfd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))));
        const tok = client_mod.CapabilityToken.mint(secret, cr_topic, wire.PERM_WRITE, 0);
        var ap: [73]u8 = undefined;
        @memcpy(ap[0..32], &tok.topic);
        ap[32] = tok.perms;
        std.mem.writeInt(u64, ap[33..41], tok.expires_ms, .little);
        @memcpy(ap[41..73], &tok.mac);
        try wire.writeFrameBlocking(allocator, rfd, .auth, 0, &ap);
        var aa = try wire.readFrameBlocking(allocator, rfd);
        defer aa.deinit(allocator);

        const replayed = try client_mod.sealFramePayload(allocator, io, master_key, cr_topic, orig_sender, 1, "replayed-old-seq");
        defer allocator.free(replayed);
        const rep_pay = try allocator.alloc(u8, 32 + replayed.len);
        defer allocator.free(rep_pay);
        @memcpy(rep_pay[0..32], &cr_topic);
        @memcpy(rep_pay[32..], replayed);
        try wire.writeFrameBlocking(allocator, rfd, .put_frame, 0, rep_pay);
        var r_rep = try wire.readFrameBlocking(allocator, rfd);
        defer r_rep.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, r_rep.op);

        const corrupt = try allocator.dupe(u8, replayed);
        defer allocator.free(corrupt);
        std.mem.writeInt(u64, corrupt[16..24], 9999, .little);
        corrupt[corrupt.len - 1] ^= 0xff;
        const cor_pay = try allocator.alloc(u8, 32 + corrupt.len);
        defer allocator.free(cor_pay);
        @memcpy(cor_pay[0..32], &cr_topic);
        @memcpy(cor_pay[32..], corrupt);
        try wire.writeFrameBlocking(allocator, rfd, .put_frame, 0, cor_pay);
        var r_cor = try wire.readFrameBlocking(allocator, rfd);
        defer r_cor.deinit(allocator);
        try testing.expectEqual(wire.Op.ack, r_cor.op);

        _ = try wsa.writeFileDirect(wsa.disk_actor, "crash.txt", "v3-healthy\n");
        const pushed3 = try c2.pushWorkspace(&wsa);
        try testing.expectEqual(@as(usize, 1), pushed3);

        var b2 = try client_mod.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, secret);
        defer b2.deinit();
        const pr2 = try b2.pullWorkspace(&wsb, 0);
        try testing.expectEqual(@as(usize, 1), pr2.applied);
        try testing.expect(b2.quarantined_count >= 1);

        const final_txt = (try wsb.history.readFileAt(allocator, "crash.txt", null)).?;
        defer allocator.free(final_txt);
        try testing.expectEqualStrings("v3-healthy\n", final_txt);
    }

    {
        const sl_dir = "/tmp/0ndb-verify-slowloris-relay";
        cleanDir(io, sl_dir);
        defer cleanDir(io, sl_dir);
        var sl_srv = try relay.RelayServer.start(allocator, io, sl_dir, .{ 127, 0, 0, 1 }, 0, secret, true);
        defer sl_srv.deinit();
        sl_srv.auth_timeout_ms = 50;
        sl_srv.max_conns_per_ip = 2;
        const sl_port = sl_srv.port;

        const sl_thread = try std.Thread.spawn(.{}, relayThreadMain, .{&sl_srv});
        var stopped = false;
        defer if (!stopped) {
            sl_srv.stop();
            sl_thread.join();
        };

        var fds: [3]std.posix.fd_t = undefined;
        var opened: usize = 0;
        defer for (0..opened) |idx| {
            _ = linux.close(fds[idx]);
        };
        for (0..3) |idx| {
            const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            try testing.expectEqual(linux.E.SUCCESS, linux.errno(s_rc));
            fds[idx] = @intCast(s_rc);
            opened += 1;
            var addr = linux.sockaddr.in{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, sl_port),
                .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            };
            try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(fds[idx], @ptrCast(&addr), @sizeOf(linux.sockaddr.in))));
        }

        var probe: [8]u8 = undefined;
        var p3 = [_]linux.pollfd{.{ .fd = fds[2], .events = linux.POLL.IN, .revents = 0 }};
        const prc3 = linux.poll(&p3, 1, 500);
        try testing.expect(linux.errno(prc3) == .SUCCESS and prc3 > 0);
        const rrc3 = linux.read(fds[2], &probe, probe.len);
        try testing.expect(linux.errno(rrc3) != .SUCCESS or rrc3 == 0);

        io.sleep(.fromMilliseconds(140), .awake) catch {};
        var p0 = [_]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
        const prc0 = linux.poll(&p0, 1, 500);
        try testing.expect(linux.errno(prc0) == .SUCCESS and prc0 > 0);
        const rrc0 = linux.read(fds[0], &probe, probe.len);
        try testing.expect(linux.errno(rrc0) != .SUCCESS or rrc0 == 0);

        const t0 = ondb.core.id.nowMs(io);
        sl_srv.stop();
        sl_thread.join();
        stopped = true;
        const elapsed = ondb.core.id.nowMs(io) -| t0;
        try testing.expect(elapsed < 80);
    }
}

fn relayThreadMain(srv: *ondb.sync.relay.RelayServer) void {
    srv.run() catch {};
}

test "dumb protected E2EE relay syncs session list, statuses, Merkle paginated messages, and live stream" {
    const allocator = testing.allocator;
    const io = testing.io;
    const relay_dir = "/tmp/0ndb-verify-relay";
    const dev_a_root = "/tmp/0ndb-verify-deva";
    const dev_a_state = "/tmp/0ndb-verify-deva-state";
    const dev_b_cache = "/tmp/0ndb-verify-devb-cache";
    cleanDir(io, relay_dir);
    cleanDir(io, dev_a_root);
    cleanDir(io, dev_a_state);
    cleanDir(io, dev_b_cache);
    defer cleanDir(io, relay_dir);
    defer cleanDir(io, dev_a_root);
    defer cleanDir(io, dev_a_state);
    defer cleanDir(io, dev_b_cache);

    const auth_secret = ondb.store.crypto.hashBytes("relay-secret-key");
    const master_key: ondb.store.crypto.Key = @splat(0x5a);
    const vault_id: u128 = 777;

    var server = try ondb.sync.relay.RelayServer.start(
        allocator,
        io,
        relay_dir,
        .{ 127, 0, 0, 1 },
        0,
        auth_secret,
        true,
    );
    defer server.deinit();
    const port = server.port;

    const srv_thread = try std.Thread.spawn(.{}, relayThreadMain, .{&server});
    defer {
        server.stop();
        srv_thread.join();
    }

    var ws_a = try ondb.fs.workspace.Workspace.open(allocator, io, dev_a_root, dev_a_state, 10);
    defer ws_a.deinit();
    var eng_a = try ondb.session.engine.SessionEngine.open(allocator, io, &ws_a, dev_a_state);
    defer eng_a.deinit();
    eng_a.page_size = 2;

    const tid = try eng_a.createThread("remote sync test", .muse, "muse-pro");
    const mock_factory = ondb.session.engine.HandleFactory{ .ptr = null, .open_fn = openNativeMock };
    _ = try eng_a.executePrompt(tid, "m1", .muse, "muse-pro", mock_factory, null);
    _ = try eng_a.executePrompt(tid, "m2", .muse, "muse-pro", mock_factory, null);

    var bad_client = try ondb.sync.client.SyncClient.connect(
        allocator,
        io,
        .{ 127, 0, 0, 1 },
        port,
        master_key,
        ondb.store.crypto.hashBytes("wrong-secret"),
    );
    defer bad_client.deinit();
    try testing.expectError(
        error.AuthRejected,
        bad_client.authorizeTopic(ondb.core.id.catalogStreamId(vault_id), ondb.sync.wire.PERM_ALL),
    );

    var dev_a = try ondb.sync.client.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, auth_secret);
    defer dev_a.deinit();
    var dev_b = try ondb.sync.client.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, auth_secret);
    defer dev_b.deinit();

    const catalog_topic = ondb.core.id.catalogStreamId(vault_id);
    const thread_topic = ondb.core.id.threadStreamId(tid);
    try dev_a.authorizeTopic(catalog_topic, ondb.sync.wire.PERM_ALL);
    try dev_a.authorizeTopic(thread_topic, ondb.sync.wire.PERM_ALL);
    try dev_b.authorizeTopic(catalog_topic, ondb.sync.wire.PERM_ALL);
    try dev_b.authorizeTopic(thread_topic, ondb.sync.wire.PERM_ALL);

    const thread_a = eng_a.journal.threads.get(tid).?;
    const uploaded_pages = try dev_a.pushPageChain(tid, &eng_a.journal.pages, thread_a.head_page);
    try testing.expectEqual(@as(usize, 2), uploaded_pages);

    var sum_a = try ondb.session.model.SessionSummary.fromThread(allocator, &thread_a);
    defer sum_a.deinit(allocator);
    _ = try dev_a.pushSessionSummary(vault_id, &sum_a);

    const pulled = try dev_b.pullSessionSummaries(allocator, vault_id, 0);
    defer {
        for (pulled.summaries) |*s| s.deinit(allocator);
        allocator.free(pulled.summaries);
    }
    try testing.expectEqual(@as(usize, 1), pulled.summaries.len);
    try testing.expectEqualStrings("remote sync test", pulled.summaries[0].title);
    try testing.expectEqual(ondb.session.model.SessionStatus.idle, pulled.summaries[0].status);

    try std.Io.Dir.cwd().createDirPath(io, dev_b_cache);
    var b_dir = try std.Io.Dir.cwd().openDir(io, dev_b_cache, .{ .iterate = true });
    defer b_dir.close(io);
    var b_pages = try ondb.store.blobs.BlobStore.open(allocator, io, b_dir, "pages", ondb.store.blobs.DEFAULT_CACHE_BUDGET);
    defer b_pages.deinit();

    var remote_head = (try dev_b.fetchPageLocalFirst(allocator, tid, &b_pages, pulled.summaries[0].head_page.?)).?;
    defer remote_head.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), remote_head.messages.len);
    try testing.expect(remote_head.prev_page != null);

    var remote_prev = (try dev_b.fetchPageLocalFirst(allocator, tid, &b_pages, remote_head.prev_page.?)).?;
    defer remote_prev.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), remote_prev.messages.len);
    try testing.expectEqualStrings("m1", remote_prev.messages[0].content);

    const backlog = try dev_b.subscribe(thread_topic, 0);
    defer {
        for (backlog) |*f| f.deinit(allocator);
        allocator.free(backlog);
    }

    const live_msg_id = try eng_a.appendUserMessage(tid, thread_a.leaf_msg_id, .user, "live-streamed-msg", .muse, "muse-pro", null, null);
    const live_msg = eng_a.journal.messages.get(live_msg_id).?;
    _ = try dev_a.pushLiveMessage(tid, &live_msg);

    var live_frame = try dev_b.readLiveEvent(allocator);
    defer live_frame.deinit(allocator);
    var r = ondb.store.codec.Reader.init(live_frame.plaintext);
    var decoded = try ondb.session.model.Message.decode(allocator, &r);
    defer decoded.deinit(allocator);
    try testing.expectEqualStrings("live-streamed-msg", decoded.content);

    {
        const head_pid = thread_a.head_page.?;
        const keyed_id = ondb.store.crypto.deriveBlobLookupId(master_key, thread_topic, head_pid);
        try testing.expect(!std.mem.eql(u8, &head_pid, &keyed_id));
        const scoped_id = ondb.sync.relay.scopedBlobKey(thread_topic, keyed_id);
        try testing.expect(!std.mem.eql(u8, &keyed_id, &scoped_id));

        var raw_hex: [64]u8 = undefined;
        _ = ondb.core.id.formatHashHex(head_pid, &raw_hex);
        var keyed_hex: [64]u8 = undefined;
        _ = ondb.core.id.formatHashHex(keyed_id, &keyed_hex);
        var scoped_hex: [64]u8 = undefined;
        _ = ondb.core.id.formatHashHex(scoped_id, &scoped_hex);

        const raw_path = try std.fmt.allocPrint(allocator, "{s}/blobs/{s}", .{ relay_dir, raw_hex });
        defer allocator.free(raw_path);
        const keyed_path = try std.fmt.allocPrint(allocator, "{s}/blobs/{s}", .{ relay_dir, keyed_hex });
        defer allocator.free(keyed_path);
        const scoped_path = try std.fmt.allocPrint(allocator, "{s}/blobs/{s}", .{ relay_dir, scoped_hex });
        defer allocator.free(scoped_path);

        const raw_exists = if (std.Io.Dir.cwd().statFile(io, raw_path, .{})) |_| true else |_| false;
        const keyed_exists = if (std.Io.Dir.cwd().statFile(io, keyed_path, .{})) |_| true else |_| false;
        const scoped_exists = if (std.Io.Dir.cwd().statFile(io, scoped_path, .{})) |_| true else |_| false;
        try testing.expect(!raw_exists);
        try testing.expect(!keyed_exists);
        try testing.expect(scoped_exists);

        const f1 = try ondb.sync.client.sealFramePayload(allocator, io, master_key, thread_topic, 99, 1, "secret-msg");
        defer allocator.free(f1);
        const f1_dup = try ondb.sync.client.sealFramePayload(allocator, io, master_key, thread_topic, 99, 1, "secret-msg");
        defer allocator.free(f1_dup);
        try testing.expect(!std.mem.eql(u8, f1[24..56], f1_dup[24..56]));

        const f2 = try ondb.sync.client.sealFramePayload(allocator, io, master_key, thread_topic, 99, 2, "second-msg");
        defer allocator.free(f2);
        const f3 = try ondb.sync.client.sealFramePayload(allocator, io, master_key, thread_topic, 99, 3, "third-msg");
        defer allocator.free(f3);

        var seen: std.AutoHashMapUnmanaged(ondb.sync.client.SenderKey, u64) = .empty;
        defer seen.deinit(allocator);

        try testing.expectError(
            error.AuthenticationFailed,
            ondb.sync.client.openFramePayload(allocator, master_key, catalog_topic, f1, &seen, allocator),
        );

        const ok1 = try ondb.sync.client.openFramePayload(allocator, master_key, thread_topic, f1, &seen, allocator);
        defer allocator.free(ok1.plaintext);
        try testing.expectEqualStrings("secret-msg", ok1.plaintext);

        try testing.expectError(
            error.ReplayOrReorder,
            ondb.sync.client.openFramePayload(allocator, master_key, thread_topic, f1, &seen, allocator),
        );

        const ok3 = try ondb.sync.client.openFramePayload(allocator, master_key, thread_topic, f3, &seen, allocator);
        defer allocator.free(ok3.plaintext);
        try testing.expectEqualStrings("third-msg", ok3.plaintext);

        try testing.expectError(
            error.ReplayOrReorder,
            ondb.sync.client.openFramePayload(allocator, master_key, thread_topic, f2, &seen, allocator),
        );
    }

    {
        var exp_client = try ondb.sync.client.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, auth_secret);
        defer exp_client.deinit();
        try testing.expectError(
            error.AuthRejected,
            exp_client.authorizeTopicWithExpiry(thread_topic, ondb.sync.wire.PERM_ALL, 1),
        );

        const soon_ms: u64 = ondb.core.id.nowMs(io) + 35;
        try exp_client.authorizeTopicWithExpiry(thread_topic, ondb.sync.wire.PERM_ALL, soon_ms);
        io.sleep(.fromMilliseconds(60), .awake) catch {};
        try testing.expectError(
            error.PutFrameFailed,
            exp_client.putEncryptedFrame(thread_topic, "after-expiry"),
        );

        const live2_id = try eng_a.appendUserMessage(tid, live_msg_id, .user, "buffered-while-rpc", .muse, "muse-pro", null, null);
        const live2 = eng_a.journal.messages.get(live2_id).?;
        _ = try dev_a.pushLiveMessage(tid, &live2);
        io.sleep(.fromMilliseconds(15), .awake) catch {};

        const probe_payload = "rpc-while-subscribed-ok";
        const probe_oid = ondb.store.crypto.hashBytes(probe_payload);
        try dev_b.putEncryptedBlob(thread_topic, probe_oid, probe_payload);
        const got_probe = (try dev_b.getEncryptedBlob(allocator, thread_topic, probe_oid)).?;
        defer allocator.free(got_probe);
        try testing.expectEqualStrings(probe_payload, got_probe);

        var buffered_ev = try dev_b.readLiveEvent(allocator);
        defer buffered_ev.deinit(allocator);
        var br = ondb.store.codec.Reader.init(buffered_ev.plaintext);
        var bdec = try ondb.session.model.Message.decode(allocator, &br);
        defer bdec.deinit(allocator);
        try testing.expectEqualStrings("buffered-while-rpc", bdec.content);

        const sync_a_root = "/tmp/0ndb-verify-ws-sync-a";
        const sync_a_state = "/tmp/0ndb-verify-ws-sync-a-state";
        const sync_b_root = "/tmp/0ndb-verify-ws-sync-b";
        const sync_b_state = "/tmp/0ndb-verify-ws-sync-b-state";
        cleanDir(io, sync_a_root);
        cleanDir(io, sync_a_state);
        cleanDir(io, sync_b_root);
        cleanDir(io, sync_b_state);
        defer cleanDir(io, sync_a_root);
        defer cleanDir(io, sync_a_state);
        defer cleanDir(io, sync_b_root);
        defer cleanDir(io, sync_b_state);

        const shared_hid: u128 = 999111;
        var wsa = try ondb.fs.workspace.Workspace.open(allocator, io, sync_a_root, sync_a_state, shared_hid);
        defer wsa.deinit();
        var wsb = try ondb.fs.workspace.Workspace.open(allocator, io, sync_b_root, sync_b_state, shared_hid);
        defer wsb.deinit();

        _ = try wsa.writeFileDirect(wsa.disk_actor, "src/synced.zig", "pub const synced = 42;\n");
        {
            const bf = try std.Io.Dir.cwd().createFile(io, sync_a_root ++ "/asset.bin", .{ .truncate = true });
            defer bf.close(io);
            try bf.writeStreamingAll(io, "\x00\xfe\xed\xfa\xce\x00");
        }
        _ = try wsa.ingestDisk();

        var big_txt: std.ArrayList(u8) = .empty;
        defer big_txt.deinit(allocator);
        for (0..220) |bi| {
            try big_txt.print(allocator, "text-blob-sync-line-{d:0>4}: payload-bytes-for-blob-threshold\n", .{bi});
        }
        _ = try wsa.writeFileDirect(wsa.disk_actor, "src/large_blob.txt", big_txt.items);

        const pushed_n = try dev_a.pushWorkspace(&wsa);
        try testing.expect(pushed_n >= 3);

        const pull_res = try dev_b.pullWorkspace(&wsb, 0);
        try testing.expectEqual(pushed_n, pull_res.applied);

        const synced_txt = (try wsb.history.readFileAt(allocator, "src/synced.zig", null)).?;
        defer allocator.free(synced_txt);
        try testing.expectEqualStrings("pub const synced = 42;\n", synced_txt);

        const synced_large = (try wsb.history.readFileAt(allocator, "src/large_blob.txt", null)).?;
        defer allocator.free(synced_large);
        try testing.expectEqualStrings(big_txt.items, synced_large);

        const synced_bin = try std.Io.Dir.cwd().readFileAlloc(io, sync_b_root ++ "/asset.bin", allocator, .limited(1024));
        defer allocator.free(synced_bin);
        try testing.expectEqualStrings("\x00\xfe\xed\xfa\xce\x00", synced_bin);

        var dev_a2 = try ondb.sync.client.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, auth_secret);
        defer dev_a2.deinit();
        const repushed_n = try dev_a2.pushWorkspace(&wsa);
        try testing.expectEqual(@as(usize, 0), repushed_n);

        const live3_id = try eng_a.appendUserMessage(tid, live2_id, .user, "same-topic-interleaved", .muse, "muse-pro", null, null);
        const live3 = eng_a.journal.messages.get(live3_id).?;
        _ = try dev_a.pushLiveMessage(tid, &live3);
        io.sleep(.fromMilliseconds(15), .awake) catch {};

        const range_frames = try dev_b.getEncryptedRange(allocator, thread_topic, 0, 100);
        defer {
            for (range_frames) |*f| f.deinit(allocator);
            allocator.free(range_frames);
        }
        try testing.expectEqual(@as(usize, 0), range_frames.len);

        var fresh_reader = try ondb.sync.client.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, auth_secret);
        defer fresh_reader.deinit();
        try fresh_reader.authorizeTopic(thread_topic, ondb.sync.wire.PERM_READ);
        const fresh_frames = try fresh_reader.getEncryptedRange(allocator, thread_topic, 0, 100);
        defer {
            for (fresh_frames) |*f| f.deinit(allocator);
            allocator.free(fresh_frames);
        }
        try testing.expect(fresh_frames.len >= 3);

        var live3_ev = try dev_b.readLiveEvent(allocator);
        defer live3_ev.deinit(allocator);
        var l3r = ondb.store.codec.Reader.init(live3_ev.plaintext);
        var l3dec = try ondb.session.model.Message.decode(allocator, &l3r);
        defer l3dec.deinit(allocator);
        try testing.expectEqualStrings("same-topic-interleaved", l3dec.content);

        var perm_client = try ondb.sync.client.SyncClient.connect(allocator, io, .{ 127, 0, 0, 1 }, port, master_key, auth_secret);
        defer perm_client.deinit();
        try perm_client.authorizeTopic(thread_topic, ondb.sync.wire.PERM_READ);
        try perm_client.authorizeTopic(thread_topic, ondb.sync.wire.PERM_WRITE);
        const perm_seq = try perm_client.putEncryptedFrame(thread_topic, "perm-merged-write");
        try testing.expect(perm_seq > 0);
        const perm_read = try perm_client.getEncryptedRange(allocator, thread_topic, 0, 10);
        defer {
            for (perm_read) |*f| f.deinit(allocator);
            allocator.free(perm_read);
        }
        try testing.expect(perm_read.len >= 1);

        {
            const linux = std.os.linux;
            const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            try testing.expectEqual(linux.E.SUCCESS, linux.errno(s_rc));
            const bad_fd: std.posix.fd_t = @intCast(s_rc);
            defer _ = linux.close(bad_fd);
            var addr = linux.sockaddr.in{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            };
            try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(bad_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))));
            var bad_hdr: [ondb.sync.wire.WIRE_HEADER_LEN]u8 = undefined;
            bad_hdr[0] = ondb.sync.wire.WIRE_MAGIC[0];
            bad_hdr[1] = ondb.sync.wire.WIRE_MAGIC[1];
            bad_hdr[2] = @backingInt(ondb.sync.wire.Op.put_frame);
            bad_hdr[3] = 0;
            std.mem.writeInt(u32, bad_hdr[4..8], @intCast(ondb.sync.wire.MAX_FRAME_LEN + 4096), .little);
            const wrc = linux.sendto(bad_fd, &bad_hdr, bad_hdr.len, linux.MSG.NOSIGNAL, null, 0);
            try testing.expectEqual(linux.E.SUCCESS, linux.errno(wrc));
            try testing.expectEqual(bad_hdr.len, wrc);
            var probe: [16]u8 = undefined;
            var pfd = [_]linux.pollfd{.{ .fd = bad_fd, .events = linux.POLL.IN, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, 2000);
            try testing.expect(linux.errno(prc) == .SUCCESS and prc > 0);
            const rrc = linux.read(bad_fd, &probe, probe.len);
            try testing.expect(linux.errno(rrc) != .SUCCESS or rrc == 0);

            const still_ok = try perm_client.putEncryptedFrame(thread_topic, "after-rogue-drop");
            try testing.expect(still_ok > perm_seq);
        }

        {
            const clog_dir_path = "/tmp/0ndb-verify-clog";
            cleanDir(io, clog_dir_path);
            defer cleanDir(io, clog_dir_path);
            try std.Io.Dir.cwd().createDirPath(io, clog_dir_path);
            var clog_dir = try std.Io.Dir.cwd().openDir(io, clog_dir_path, .{});
            defer clog_dir.close(io);

            var alog = try ondb.store.log.AppendLog.open(allocator, io, clog_dir, "sparse.0ndb", false);
            defer alog.deinit();
            for (1..21) |n| {
                var pbuf: [32]u8 = undefined;
                const p = try std.fmt.bufPrint(&pbuf, "rec-{d}", .{n});
                _ = try alog.append(1, 0, 0, p);
            }
            const keep = [_]usize{ 5, 6, 12, 18, 19 };
            try alog.compact(clog_dir, "sparse.0ndb", &keep);
            try testing.expectEqual(@as(usize, 5), alog.count());
            try testing.expectEqual(@as(usize, 0), alog.findIndexBySeq(1));
            try testing.expectEqual(@as(usize, 0), alog.findIndexBySeq(6));
            try testing.expectEqual(@as(usize, 1), alog.findIndexBySeq(7));
            try testing.expectEqual(@as(usize, 2), alog.findIndexBySeq(8));
            try testing.expectEqual(@as(usize, 2), alog.findIndexBySeq(13));
            try testing.expectEqual(@as(usize, 3), alog.findIndexBySeq(14));
            try testing.expectEqual(@as(usize, 4), alog.findIndexBySeq(20));
            try testing.expectEqual(@as(usize, 5), alog.findIndexBySeq(21));

            const v2 = try alog.readAt(alog.findIndexBySeq(8));
            try testing.expectEqual(@as(u64, 13), v2.header.seq);
            try testing.expectEqualStrings("rec-13", v2.payload);
        }
    }

    try runSyncHardeningChecks(allocator, io);
}

fn testLruSliceSize(s: []u8) usize {
    return s.len;
}

fn testLruSliceDeinit(allocator: std.mem.Allocator, s: *[]u8) void {
    allocator.free(s.*);
}

fn runPagedStorePrimitivesSuite(allocator: std.mem.Allocator, io: std.Io) !void {
    const base_dir_path = "/tmp/0ndb-verify-paged-store";
    cleanDir(io, base_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, base_dir_path);
    defer cleanDir(io, base_dir_path);

    var dir = try std.Io.Dir.cwd().openDir(io, base_dir_path, .{ .iterate = true });
    defer dir.close(io);

    {
        try ondb.store.mmap.atomicWriteFile(io, dir, "hello.bin", "first-version");
        try ondb.store.mmap.atomicWriteFile(io, dir, "hello.bin", "second-version-longer");
        try ondb.store.mmap.fsyncDir(io, dir);

        const mf = try ondb.store.mmap.MappedFile.open(allocator, io, dir, "hello.bin");
        try testing.expectEqual(@as(u32, 1), mf.refCount());
        try testing.expectEqualStrings("second-version-longer", mf.slice());
        try testing.expectEqualStrings("version", try mf.sliceChecked(7, 7));
        try testing.expectError(error.OutOfBounds, mf.sliceChecked(18, 10));
        try testing.expectError(error.OutOfBounds, mf.sliceChecked(std.math.maxInt(usize), 1));

        mf.retain();
        try testing.expectEqual(@as(u32, 2), mf.refCount());
        mf.release(allocator);
        try testing.expectEqual(@as(u32, 1), mf.refCount());
        mf.hibernate();
        try testing.expectEqualStrings("second-version-longer", mf.slice());
        mf.release(allocator);

        try ondb.store.mmap.atomicWriteFile(io, dir, "empty.bin", "");
        const empty_mf = try ondb.store.mmap.MappedFile.open(allocator, io, dir, "empty.bin");
        defer empty_mf.release(allocator);
        try testing.expectEqual(@as(usize, 0), empty_mf.len());
        try testing.expectEqualStrings("", empty_mf.slice());
        try testing.expectEqualStrings("", try empty_mf.sliceChecked(0, 0));
        try testing.expectError(error.OutOfBounds, empty_mf.sliceChecked(0, 1));
        empty_mf.hibernate();
    }

    {
        const Cache = ondb.store.lru.LruCache(u64, []u8, testLruSliceSize, testLruSliceDeinit);
        var cache = Cache.init(allocator, .{
            .budget_bytes = 350,
            .max_entries = 10,
            .entry_overhead = 96,
        });
        defer cache.deinit();

        const v1 = try allocator.dupe(u8, "01234567890123456789");
        _ = try cache.put(1, v1);
        const v2 = try allocator.dupe(u8, "aaaaaaaaaaaaaaaaaaaa");
        _ = try cache.put(2, v2);
        const v3 = try allocator.dupe(u8, "bbbbbbbbbbbbbbbbbbbb");
        _ = try cache.put(3, v3);
        try testing.expectEqual(@as(usize, 3), cache.count());
        try testing.expectEqual(@as(usize, 348), cache.used_bytes);

        const v4 = try allocator.dupe(u8, "cccccccccccccccccccc");
        _ = try cache.put(4, v4);
        try testing.expect(!cache.contains(1));
        try testing.expectEqual(@as(usize, 3), cache.count());
        try testing.expectEqual(@as(usize, 348), cache.used_bytes);

        const c3 = cache.getConst(3).?;
        try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbb", c3.*);

        cache.beginPinScope();
        const pinned = cache.get(2).?;
        cache.beginPinScope();
        var k: u64 = 10;
        while (k < 20) : (k += 1) {
            const payload = try std.fmt.allocPrint(allocator, "entry-{d:0>14}", .{k});
            _ = try cache.put(k, payload);
        }
        try testing.expectEqual(@as(usize, 13), cache.count());
        try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaa", pinned.*);
        cache.endPinScope();
        try testing.expectEqual(@as(usize, 13), cache.count());
        try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaa", pinned.*);
        cache.endPinScope();
        try testing.expect(cache.used_bytes <= 350);
        try testing.expectEqual(@as(usize, 3), cache.count());

        try testing.expect(cache.remove(19));
        try testing.expect(!cache.remove(19));
        cache.clear();
        try testing.expectEqual(@as(usize, 0), cache.count());
        try testing.expectEqual(@as(usize, 0), cache.used_bytes);
    }

    {
        try dir.createDirPath(io, "mnf_state/snap");
        try dir.createDirPath(io, "mnf_state/wal");
        var mnf_dir = try dir.openDir(io, "mnf_state", .{ .iterate = true });
        defer mnf_dir.close(io);

        try testing.expect((try ondb.store.manifest.Manifest.load(io, mnf_dir)) == null);

        var m = ondb.store.manifest.Manifest{
            .flags = ondb.store.manifest.FLAG_PRUNED_BEFORE_SYNC | ondb.store.manifest.FLAG_EVER_SYNCED | ondb.store.manifest.FLAG_HAS_HORIZON,
            .history_id = 0x0123456789abcdef_fedcba9876543210,
            .generation = 42,
            .base_gen = 5,
            .delta_gen = 3,
            .wal_gen = 8,
            .wal_base_seq = 100,
            .pack_max_id = 7,
            .seg_max_id = 9,
            .checkpoint_wall_ms = 1700000000123,
            .total_inodes = 50000,
            .total_batches = 12345,
            .base_blake3 = ondb.store.crypto.hashBytes("base"),
            .delta_blake3 = ondb.store.crypto.hashBytes("delta"),
            .pack_idx_blake3 = ondb.store.crypto.hashBytes("packidx"),
        };
        const enc = m.encode();
        try testing.expectEqual(@as(usize, 256), enc.len);
        const dec = try ondb.store.manifest.Manifest.decode(&enc);
        try testing.expectEqual(m.flags, dec.flags);
        try testing.expectEqual(m.history_id, dec.history_id);
        try testing.expectEqual(m.generation, dec.generation);
        try testing.expectEqual(m.base_gen, dec.base_gen);
        try testing.expectEqual(m.delta_gen, dec.delta_gen);
        try testing.expectEqual(m.wal_gen, dec.wal_gen);
        try testing.expectEqual(m.wal_base_seq, dec.wal_base_seq);
        try testing.expectEqual(m.pack_max_id, dec.pack_max_id);
        try testing.expectEqual(m.seg_max_id, dec.seg_max_id);
        try testing.expectEqual(m.checkpoint_wall_ms, dec.checkpoint_wall_ms);
        try testing.expectEqual(m.total_inodes, dec.total_inodes);
        try testing.expectEqual(m.total_batches, dec.total_batches);
        try testing.expectEqualSlices(u8, &m.base_blake3, &dec.base_blake3);
        try testing.expectEqualSlices(u8, &m.delta_blake3, &dec.delta_blake3);
        try testing.expectEqualSlices(u8, &m.pack_idx_blake3, &dec.pack_idx_blake3);

        var bad_magic = enc;
        bad_magic[0] ^= 0xff;
        try testing.expectError(error.InvalidMagic, ondb.store.manifest.Manifest.decode(&bad_magic));

        var bad_ver = enc;
        std.mem.writeInt(u32, bad_ver[8..12], 99, .little);
        try testing.expectError(error.UnsupportedVersion, ondb.store.manifest.Manifest.decode(&bad_ver));

        var bad_body = enc;
        bad_body[32] ^= 0x01;
        try testing.expectError(error.CorruptManifest, ondb.store.manifest.Manifest.decode(&bad_body));

        var bad_digest = enc;
        bad_digest[255] ^= 0x80;
        try testing.expectError(error.CorruptManifest, ondb.store.manifest.Manifest.decode(&bad_digest));

        try m.saveAtomic(io, mnf_dir);
        const loaded = (try ondb.store.manifest.Manifest.load(io, mnf_dir)).?;
        try testing.expectEqual(m.generation, loaded.generation);
        try testing.expectEqualSlices(u8, &dec.manifest_blake3, &loaded.manifest_blake3);

        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "snap/base-0000000000000004.0ndb", "old-base");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "snap/base-0000000000000005.0ndb", "cur-base");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "snap/delta-0000000000000002.0ndb", "old-delta");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "snap/delta-0000000000000003.0ndb", "cur-delta");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "snap/tmp.orphan", "tmp");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "wal/wal-0000000000000007.0ndb", "old-wal");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "wal/wal-0000000000000008.0ndb", "cur-wal");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "wal/tmp.wal.orphan", "tmp");
        try ondb.store.mmap.atomicWriteFile(io, mnf_dir, "tmp.manifest.0ndb.99999", "tmp");

        ondb.store.manifest.Manifest.gcOrphanFiles(allocator, io, mnf_dir, loaded);

        try testing.expectError(error.FileNotFound, mnf_dir.statFile(io, "snap/base-0000000000000004.0ndb", .{}));
        _ = try mnf_dir.statFile(io, "snap/base-0000000000000005.0ndb", .{});
        try testing.expectError(error.FileNotFound, mnf_dir.statFile(io, "snap/delta-0000000000000002.0ndb", .{}));
        _ = try mnf_dir.statFile(io, "snap/delta-0000000000000003.0ndb", .{});
        try testing.expectError(error.FileNotFound, mnf_dir.statFile(io, "snap/tmp.orphan", .{}));
        try testing.expectError(error.FileNotFound, mnf_dir.statFile(io, "wal/wal-0000000000000007.0ndb", .{}));
        _ = try mnf_dir.statFile(io, "wal/wal-0000000000000008.0ndb", .{});
        try testing.expectError(error.FileNotFound, mnf_dir.statFile(io, "wal/tmp.wal.orphan", .{}));
        try testing.expectError(error.FileNotFound, mnf_dir.statFile(io, "tmp.manifest.0ndb.99999", .{}));
    }

    {
        try dir.createDirPath(io, "seg_state");
        var seg_state = try dir.openDir(io, "seg_state", .{ .iterate = true });
        defer seg_state.close(io);

        var segs = try ondb.store.segments.SegmentStore.open(allocator, io, seg_state);
        defer segs.deinit();

        const f1 = [_]ondb.store.segments.FrameInput{
            .{ .kind = 1, .seq = 1, .payload = "batch-one" },
            .{ .kind = 1, .seq = 2, .payload = "batch-two-longer" },
        };
        const w1 = try segs.writeSegment(1, &f1);
        defer allocator.free(w1);

        const f2 = [_]ondb.store.segments.FrameInput{
            .{ .kind = 1, .seq = 3, .payload = "dead-batch-three" },
            .{ .kind = 1, .seq = 4, .payload = "dead-batch-four" },
        };
        const w2 = try segs.writeSegment(2, &f2);
        defer allocator.free(w2);

        const f3 = [_]ondb.store.segments.FrameInput{
            .{ .kind = 1, .seq = 5, .payload = "drop-batch-five" },
            .{ .kind = 1, .seq = 6, .payload = "keep-batch-six!" },
        };
        const w3 = try segs.writeSegment(3, &f3);
        defer allocator.free(w3);

        const p1 = try segs.readFrameAt(1, w1[0].offset, w1[0].payload_len, allocator);
        defer allocator.free(p1);
        try testing.expectEqualStrings("batch-one", p1);

        const p2 = try segs.readFrameAt(1, w1[1].offset, w1[1].payload_len, allocator);
        defer allocator.free(p2);
        try testing.expectEqualStrings("batch-two-longer", p2);

        {
            var wal = try ondb.store.log.AppendLog.open(allocator, io, seg_state, "seal_src.0ndb", true);
            defer wal.deinit();
            _ = try wal.appendWithSeq(7, 2, 0, 11, "wal-frame-7");
            _ = try wal.appendWithSeq(8, 2, 0, 12, "wal-frame-8");
        }
        {
            const wf = try seg_state.openFile(io, "seal_src.0ndb", .{ .mode = .read_write });
            defer wf.close(io);
            const st = try wf.stat(io);
            try wf.writePositionalAll(io, "torn-tail!!", st.size);
        }
        const w4 = try segs.sealFromWal(seg_state, "seal_src.0ndb", 4);
        defer allocator.free(w4);
        try testing.expectEqual(@as(usize, 2), w4.len);
        const p7 = try segs.readFrameAt(4, w4[0].offset, w4[0].payload_len, allocator);
        defer allocator.free(p7);
        try testing.expectEqualStrings("wal-frame-7", p7);

        const KeepFilter = struct {
            pub fn keep(_: @This(), ref: ondb.store.segments.FrameRef) bool {
                return ref.seq == 1 or ref.seq == 2 or ref.seq == 6 or ref.seq == 7 or ref.seq == 8;
            }
        };
        var prune_res = try segs.pruneSegments(KeepFilter{});
        defer prune_res.deinit(allocator);

        try testing.expectEqual(@as(u32, 1), prune_res.removed_segments);
        try testing.expectEqual(@as(u32, 1), prune_res.rewritten_segments);
        try testing.expectEqual(@as(usize, 5), prune_res.kept_frames);
        try testing.expectEqual(@as(usize, 3), prune_res.removed_frames);
        try testing.expectEqual(@as(usize, 1), prune_res.remaps.items.len);

        const remap = prune_res.remaps.items[0];
        try testing.expectEqual(@as(u32, 3), remap.old_seg_id);
        try testing.expectEqual(w3[1].offset, remap.old_offset);
        try testing.expectEqual(@as(u64, 6), remap.seq);
        try testing.expect(remap.new_seg_id > 4);

        const p6 = try segs.readFrameAt(remap.new_seg_id, remap.new_offset, remap.payload_len, allocator);
        defer allocator.free(p6);
        try testing.expectEqualStrings("keep-batch-six!", p6);

        try testing.expectError(error.FileNotFound, segs.readFrameAt(2, w2[0].offset, w2[0].payload_len, allocator));
        segs.hibernate();
        const p1_after = try segs.readFrameAt(1, w1[0].offset, w1[0].payload_len, allocator);
        defer allocator.free(p1_after);
        try testing.expectEqualStrings("batch-one", p1_after);
    }

    {
        var hashes: [14]ondb.store.crypto.Hash = undefined;
        var payloads: [14][200]u8 = undefined;
        for (0..14) |i| {
            @memset(&payloads[i], @intCast('A' + i));
            payloads[i][0] = @intCast(i);
            hashes[i] = ondb.store.crypto.hashBytes(&payloads[i]);
        }

        const loose_keep_data = "legacy-loose-keep-payload-0123456789";
        const loose_keep_hash = ondb.store.crypto.hashBytes(loose_keep_data);
        const loose_dead_data = "legacy-loose-dead-payload-9876543210";
        const loose_dead_hash = ondb.store.crypto.hashBytes(loose_dead_data);

        {
            var bs = try ondb.store.blobs.BlobStore.openWithOptions(allocator, io, dir, "pack_blobs", .{
                .budget_bytes = 1024,
                .entry_overhead = 0,
                .pack_seal_bytes = 512,
            });
            defer bs.deinit();

            var batch_items: [14]ondb.store.blobs.BlobItem = undefined;
            for (0..12) |i| {
                batch_items[i] = .{ .hash = hashes[i], .data = &payloads[i] };
            }
            batch_items[12] = .{ .hash = hashes[0], .data = &payloads[0] };
            batch_items[13] = .{ .hash = hashes[5], .data = &payloads[5] };
            try bs.putBatch(&batch_items);

            try testing.expect(bs.maxPackId() >= 1);
            _ = try bs.put(&payloads[12]);
            _ = try bs.put(&payloads[13]);

            const sha1_oid: [20]u8 = @splat(0xab);
            const sha256_oid: [32]u8 = @splat(0xcd);
            try bs.putGitFallback(&sha1_oid, "git-sha1-content");
            try bs.putGitFallback(&sha256_oid, "git-sha256-content");

            const g1 = (try bs.getGitFallback(allocator, &sha1_oid)).?;
            defer allocator.free(g1);
            try testing.expectEqualStrings("git-sha1-content", g1);
            const g2 = (try bs.getGitFallback(allocator, &sha256_oid)).?;
            defer allocator.free(g2);
            try testing.expectEqualStrings("git-sha256-content", g2);
        }

        {
            var blob_dir = try dir.openDir(io, "pack_blobs", .{});
            defer blob_dir.close(io);
            const lk_hex = std.fmt.bytesToHex(loose_keep_hash, .lower);
            var lk_path: [67]u8 = undefined;
            lk_path[0] = lk_hex[0];
            lk_path[1] = lk_hex[1];
            lk_path[2] = '/';
            @memcpy(lk_path[3..67], &lk_hex);
            try ondb.store.mmap.atomicWriteFile(io, blob_dir, &lk_path, loose_keep_data);

            const ld_hex = std.fmt.bytesToHex(loose_dead_hash, .lower);
            var ld_path: [67]u8 = undefined;
            ld_path[0] = ld_hex[0];
            ld_path[1] = ld_hex[1];
            ld_path[2] = '/';
            @memcpy(ld_path[3..67], &ld_hex);
            try ondb.store.mmap.atomicWriteFile(io, blob_dir, &ld_path, loose_dead_data);
        }

        {
            var bs = try ondb.store.blobs.BlobStore.openWithOptions(allocator, io, dir, "pack_blobs", .{
                .budget_bytes = 1024,
                .entry_overhead = 0,
                .pack_seal_bytes = 512,
            });
            defer bs.deinit();

            for (0..14) |i| {
                try testing.expect(bs.exists(hashes[i]));
                const got = (try bs.get(allocator, hashes[i])).?;
                defer allocator.free(got);
                try testing.expectEqualSlices(u8, &payloads[i], got);
            }

            try testing.expect(bs.exists(loose_keep_hash));
            const lk = (try bs.get(allocator, loose_keep_hash)).?;
            defer allocator.free(lk);
            try testing.expectEqualStrings(loose_keep_data, lk);

            try testing.expect(bs.exists(loose_dead_hash));

            var live: std.AutoHashMapUnmanaged(ondb.store.crypto.Hash, void) = .empty;
            defer live.deinit(allocator);
            try live.put(allocator, hashes[0], {});
            try live.put(allocator, hashes[7], {});
            try live.put(allocator, hashes[13], {});
            try live.put(allocator, loose_keep_hash, {});

            const stats = try bs.gc(&live);
            try testing.expectEqual(@as(usize, 4), stats.kept_blobs);
            try testing.expectEqual(@as(usize, 12), stats.removed_blobs);
            try testing.expect(stats.reclaimed_bytes > 0);

            try testing.expect((try bs.get(allocator, hashes[1])) == null);
            try testing.expect((try bs.get(allocator, loose_dead_hash)) == null);
        }

        {
            var bs = try ondb.store.blobs.BlobStore.open(allocator, io, dir, "pack_blobs", 1024);
            defer bs.deinit();

            const g0 = (try bs.get(allocator, hashes[0])).?;
            defer allocator.free(g0);
            try testing.expectEqualSlices(u8, &payloads[0], g0);

            const g7 = (try bs.get(allocator, hashes[7])).?;
            defer allocator.free(g7);
            try testing.expectEqualSlices(u8, &payloads[7], g7);

            const g13 = (try bs.get(allocator, hashes[13])).?;
            defer allocator.free(g13);
            try testing.expectEqualSlices(u8, &payloads[13], g13);

            const glk = (try bs.get(allocator, loose_keep_hash)).?;
            defer allocator.free(glk);
            try testing.expectEqualStrings(loose_keep_data, glk);

            try testing.expect((try bs.get(allocator, hashes[2])) == null);
            try testing.expect((try bs.get(allocator, loose_dead_hash)) == null);
        }
    }

    {
        const pool = try ondb.store.blobs.SharedBlobPool.open(allocator, io, dir, "shared_pool", 400);
        defer pool.release();

        const b0: [50]u8 = @splat(0x11);
        const b1: [50]u8 = @splat(0x22);
        const b2: [50]u8 = @splat(0x33);
        const h0 = try pool.put(&b0);
        const h1 = try pool.put(&b1);
        try testing.expectEqual(@as(usize, 2 * (50 + ondb.store.blobs.ENTRY_OVERHEAD)), pool.cacheUsedBytes());
        _ = try pool.put(&b2);
        try testing.expect(pool.cacheUsedBytes() <= 400);
        try testing.expect(!pool.isCached(h0));
        try testing.expect(pool.isCached(h1));

        pool.hibernate();
        try testing.expectEqual(@as(usize, 0), pool.cacheUsedBytes());
        const got0 = (try pool.get(allocator, h0)).?;
        defer allocator.free(got0);
        try testing.expectEqualSlices(u8, &b0, got0);

        const WorkerCtx = struct {
            pool: *ondb.store.blobs.SharedBlobPool,
            alloc: std.mem.Allocator,
            worker_id: usize,
            ok: bool = false,
            hashes: [16]ondb.store.crypto.Hash = undefined,

            fn run(ctx: *@This()) void {
                defer ctx.pool.release();
                var data_buf: [64]u8 = undefined;
                for (0..16) |j| {
                    @memset(&data_buf, @intCast((ctx.worker_id * 31 + j) & 0xff));
                    data_buf[0] = @intCast(ctx.worker_id);
                    data_buf[1] = @intCast(j);
                    const h = ctx.pool.put(&data_buf) catch return;
                    ctx.hashes[j] = h;
                    const back = (ctx.pool.get(ctx.alloc, h) catch return) orelse return;
                    defer ctx.alloc.free(back);
                    if (!std.mem.eql(u8, back, &data_buf)) return;
                }
                ctx.ok = true;
            }
        };

        var ctxs: [4]WorkerCtx = undefined;
        var threads: [4]std.Thread = undefined;
        for (0..4) |w| {
            pool.retain();
            ctxs[w] = .{
                .pool = pool,
                .alloc = allocator,
                .worker_id = w,
            };
            threads[w] = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctxs[w]});
        }
        for (0..4) |w| {
            threads[w].join();
            try testing.expect(ctxs[w].ok);
        }
        try testing.expectEqual(@as(u32, 1), pool.refCount());
        for (0..4) |w| {
            for (0..16) |j| {
                try testing.expect(pool.exists(ctxs[w].hashes[j]));
            }
        }
    }

    {
        var fifth_offset: u64 = 0;
        {
            var bulk_log = try ondb.store.log.AppendLog.open(allocator, io, dir, "bulk.0ndb", true);
            defer bulk_log.deinit();

            const bulk_frames = [_]ondb.store.log.BulkFrame{
                .{ .kind = 1, .aux = 0, .payload = "bulk-0" },
                .{ .kind = 1, .aux = 1, .payload = "bulk-1" },
                .{ .kind = 1, .aux = 2, .payload = "bulk-2" },
                .{ .kind = 1, .aux = 3, .payload = "bulk-3" },
                .{ .kind = 1, .aux = 4, .payload = "bulk-4" },
                .{ .kind = 1, .aux = 5, .payload = "bulk-5" },
                .{ .kind = 1, .aux = 6, .payload = "bulk-6" },
                .{ .kind = 1, .aux = 7, .payload = "bulk-7" },
            };
            const res = try bulk_log.appendFramesBulk(&bulk_frames);
            defer allocator.free(res);
            try testing.expectEqual(@as(usize, 8), res.len);
            try testing.expectEqual(@as(u64, 1), res[0].seq);
            try testing.expectEqual(@as(u64, 8), res[7].seq);
            fifth_offset = bulk_log.index.items[4].offset;
        }
        {
            var fast_log = try ondb.store.log.AppendLog.openWithoutFullHash(allocator, io, dir, "bulk.0ndb", true);
            defer fast_log.deinit();
            try testing.expectEqual(@as(usize, 8), fast_log.count());
            const v7 = try fast_log.readAt(7);
            try testing.expectEqualStrings("bulk-7", v7.payload);
        }
        {
            var tail_log = try ondb.store.log.AppendLog.openTailRecover(allocator, io, dir, "bulk.0ndb", true, fifth_offset);
            defer tail_log.deinit();
            try testing.expectEqual(@as(usize, 4), tail_log.count());
            const v0 = try tail_log.readAt(0);
            try testing.expectEqual(@as(u64, 5), v0.header.seq);
            try testing.expectEqualStrings("bulk-4", v0.payload);
            const v3 = try tail_log.readAt(3);
            try testing.expectEqual(@as(u64, 8), v3.header.seq);
            try testing.expectEqualStrings("bulk-7", v3.payload);
        }
    }
}

fn runGitTestCmd(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env_map.put("GIT_TERMINAL_PROMPT", "0");
    try env_map.put("GIT_AUTHOR_NAME", "tester");
    try env_map.put("GIT_AUTHOR_EMAIL", "tester@local");
    try env_map.put("GIT_COMMITTER_NAME", "tester");
    try env_map.put("GIT_COMMITTER_EMAIL", "tester@local");

    const res = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        allocator.free(res.stdout);
        return error.GitCommandFailed;
    }
    return res.stdout;
}

fn writeTestFile(io: std.Io, dir_path: []const u8, rel_path: []const u8, data: []const u8, executable: bool) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    if (std.fs.path.dirname(rel_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    const f = try dir.createFile(io, rel_path, .{ .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, data, 0);
    if (executable) {
        try f.setPermissions(io, .fromMode(0o755));
    }
}

fn runNativeGitLayerSuite(allocator: std.mem.Allocator, io: std.Io) !void {
    const git_dirs = ondb.fs.git_dirs;
    const git_index = ondb.fs.git_index;
    const git_odb = ondb.fs.git_odb;
    const git = ondb.fs.git;

    {
        try testing.expect(git_dirs.GitOid.ZERO.isZero());
        const oid1 = git_dirs.GitOid.ofBlob(.sha1, "hello world\n");
        var hbuf1: [64]u8 = undefined;
        const hex1 = oid1.toHex(&hbuf1);
        try testing.expectEqualStrings("3b18e512dba79e4c8300dd08aeb37f8e728b8dad", hex1);
        for (oid1.bytes[20..32]) |b| try testing.expectEqual(@as(u8, 0), b);

        const parsed1 = try git_dirs.GitOid.fromHex(hex1);
        try testing.expect(oid1.eql(parsed1));
        try testing.expectEqual(std.math.Order.eq, oid1.order(parsed1));
        try testing.expectEqual(@as(usize, 20), parsed1.slice().len);

        const oid2 = git_dirs.GitOid.ofBlob(.sha256, "hello world\n");
        var hbuf2: [64]u8 = undefined;
        const hex2 = oid2.toHex(&hbuf2);
        try testing.expectEqual(@as(usize, 64), hex2.len);
        const parsed2 = try git_dirs.GitOid.fromHex(hex2);
        try testing.expect(oid2.eql(parsed2));

        var oid_map: std.HashMapUnmanaged(git_dirs.GitOid, u32, git_dirs.GitOid.hashContext, std.hash_map.default_max_load_percentage) = .empty;
        defer oid_map.deinit(allocator);
        try oid_map.put(allocator, oid1, 42);
        try oid_map.put(allocator, oid2, 99);
        try testing.expectEqual(@as(?u32, 42), oid_map.get(parsed1));
        try testing.expectEqual(@as(?u32, 99), oid_map.get(parsed2));
    }

    const base_tmp = "/tmp/0ndb-verify-native-git";
    cleanDir(io, base_tmp);
    defer cleanDir(io, base_tmp);

    const repo1 = "/tmp/0ndb-verify-native-git/repo-sha1";
    const wt1 = "/tmp/0ndb-verify-native-git/wt-sha1";
    const alt_repo = "/tmp/0ndb-verify-native-git/repo-alt";
    const clone_dst = "/tmp/0ndb-verify-native-git/reflink-dst";
    const repo256 = "/tmp/0ndb-verify-native-git/repo-sha256";

    try std.Io.Dir.cwd().createDirPath(io, repo1);
    {
        const out = try runGitTestCmd(allocator, io, repo1, &.{ "init", "-b", "main" });
        allocator.free(out);
    }

    const empty_data = "";
    const short_a = "content-a\n";
    const short_ab = "content-ab\n";
    const exec_script = "#!/bin/sh\necho hi\n";
    const deep_text = "deep nested file content\n";

    const big_blob = try allocator.alloc(u8, 80 * 1024);
    defer allocator.free(big_blob);
    for (big_blob, 0..) |*b, i| {
        b.* = @intCast((i * 31 + 17) % 95 + 32);
    }

    try writeTestFile(io, repo1, "a", short_a, false);
    try writeTestFile(io, repo1, "ab", short_ab, false);
    try writeTestFile(io, repo1, "empty.txt", empty_data, false);
    try writeTestFile(io, repo1, "run.sh", exec_script, true);
    try writeTestFile(io, repo1, "sub/deep/file.txt", deep_text, false);
    try writeTestFile(io, repo1, "large.bin", big_blob, false);

    {
        const o1 = try runGitTestCmd(allocator, io, repo1, &.{ "add", "-A" });
        allocator.free(o1);
        const o2 = try runGitTestCmd(allocator, io, repo1, &.{ "commit", "-m", "init" });
        allocator.free(o2);
    }

    var dirs = (try git_dirs.GitDirs.locate(allocator, io, repo1)).?;
    defer dirs.deinit(allocator);
    try testing.expectEqual(git_dirs.ObjectFormat.sha1, dirs.config.object_format);
    try testing.expectEqualStrings(dirs.git_dir, dirs.common_dir);

    {
        const sub_path = "/tmp/0ndb-verify-native-git/repo-sha1/sub/deep";
        var sub_dirs = (try git_dirs.GitDirs.locate(allocator, io, sub_path)).?;
        defer sub_dirs.deinit(allocator);
        try testing.expectEqualStrings(dirs.worktree_root, sub_dirs.worktree_root);
        try testing.expectEqualStrings(dirs.git_dir, sub_dirs.git_dir);
    }

    try testing.expect(git.isGitRepo(allocator, io, repo1));
    try testing.expect(!git.isGitRepo(allocator, io, "/tmp"));

    var h1 = try git.head(allocator, io, repo1);
    defer h1.deinit(allocator);
    try testing.expectEqualStrings("main", h1.branch.?);
    try testing.expectEqual(@as(usize, 40), h1.commit.?.len);

    const tip1 = (try git.branchTip(allocator, io, repo1, "main")).?;
    defer allocator.free(tip1);
    try testing.expectEqualStrings(h1.commit.?, tip1);

    try dirs.ensureExclude(io);
    try dirs.ensureExclude(io);
    {
        var cd = try std.Io.Dir.cwd().openDir(io, dirs.common_dir, .{});
        defer cd.close(io);
        const ef = try cd.openFile(io, "info/exclude", .{});
        defer ef.close(io);
        const st = try ef.stat(io);
        const raw = try allocator.alloc(u8, @intCast(st.size));
        defer allocator.free(raw);
        _ = try ef.readPositionalAll(io, raw, 0);
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |ln| {
            if (std.mem.eql(u8, ln, "/.0ndb/")) count += 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    try testing.expect(!(try dirs.hasCustomFilters(allocator, io)));
    try writeTestFile(io, repo1, ".gitattributes", "*.bin filter=lfs\n", false);
    try testing.expect(try dirs.hasCustomFilters(allocator, io));
    try writeTestFile(io, repo1, ".gitattributes", "*.txt -ident !eol\n", false);
    try testing.expect(!(try dirs.hasCustomFilters(allocator, io)));
    try writeTestFile(io, repo1, ".gitattributes", "*.txt eol=crlf\n", false);
    try testing.expect(try dirs.hasCustomFilters(allocator, io));
    try writeTestFile(io, repo1, ".gitattributes", "*.txt ident\n", false);
    try testing.expect(try dirs.hasCustomFilters(allocator, io));
    try writeTestFile(io, repo1, ".gitattributes", "*.txt working-tree-encoding=UTF-16\n", false);
    try testing.expect(try dirs.hasCustomFilters(allocator, io));
    {
        var rdir = try std.Io.Dir.cwd().openDir(io, repo1, .{});
        defer rdir.close(io);
        try rdir.deleteFile(io, ".gitattributes");
    }

    try testing.expect(!dirs.isBusy(io));
    try writeTestFile(io, dirs.git_dir, "index.lock", "", false);
    try testing.expect(dirs.isBusy(io));
    {
        var gdir = try std.Io.Dir.cwd().openDir(io, dirs.git_dir, .{});
        defer gdir.close(io);
        try gdir.deleteFile(io, "index.lock");
    }
    try testing.expect(!dirs.isBusy(io));

    try testing.expect(git.operationInProgress(allocator, io, repo1) == null);
    try writeTestFile(io, dirs.git_dir, "MERGE_HEAD", h1.commit.?, false);
    try testing.expectEqualStrings("merge", git.operationInProgress(allocator, io, repo1).?);
    {
        var gdir = try std.Io.Dir.cwd().openDir(io, dirs.git_dir, .{});
        defer gdir.close(io);
        try gdir.deleteFile(io, "MERGE_HEAD");
    }

    const stamp = (try dirs.indexStamp(io)).?;
    try testing.expect(stamp.size > 0);

    var idx_v2 = (try git_index.GitIndex.load(allocator, io, &dirs)).?;
    defer idx_v2.deinit(allocator);
    try testing.expectEqual(@as(u32, 2), idx_v2.version);
    try testing.expectEqual(@as(usize, 6), idx_v2.entries.len);

    const e_a = idx_v2.find("a").?;
    try testing.expect(e_a.oid.eql(git_dirs.GitOid.ofBlob(.sha1, short_a)));
    try testing.expect(e_a.isRegularFile());
    try testing.expect(!e_a.isExecutable());

    const e_ab = idx_v2.find("ab").?;
    try testing.expect(e_ab.oid.eql(git_dirs.GitOid.ofBlob(.sha1, short_ab)));

    const e_sh = idx_v2.find("run.sh").?;
    try testing.expect(e_sh.isExecutable());
    try testing.expect(idx_v2.find("does-not-exist") == null);

    {
        var rdir = try std.Io.Dir.cwd().openDir(io, repo1, .{});
        defer rdir.close(io);
        const st_sh = try rdir.statFile(io, "run.sh", .{});

        idx_v2.index_mtime_s = e_sh.stat.mtime_s;
        idx_v2.index_mtime_ns = e_sh.stat.mtime_ns;
        try testing.expect(!idx_v2.isStatClean(e_sh, st_sh, dirs.config));

        idx_v2.index_mtime_s = e_sh.stat.mtime_s + 10;
        try testing.expect(idx_v2.isStatClean(e_sh, st_sh, dirs.config));

        var flipped_stat = st_sh;
        flipped_stat.permissions = .fromMode(0o644);
        try testing.expect(!idx_v2.isStatClean(e_sh, flipped_stat, dirs.config));
        var no_filemode = dirs.config;
        no_filemode.filemode = false;
        try testing.expect(idx_v2.isStatClean(e_sh, flipped_stat, no_filemode));
    }

    {
        const o_v4 = try runGitTestCmd(allocator, io, repo1, &.{ "update-index", "--index-version", "4" });
        allocator.free(o_v4);
    }
    var idx_v4 = (try git_index.GitIndex.load(allocator, io, &dirs)).?;
    defer idx_v4.deinit(allocator);
    try testing.expectEqual(@as(u32, 4), idx_v4.version);
    try testing.expectEqual(idx_v2.entries.len, idx_v4.entries.len);
    for (idx_v2.entries, idx_v4.entries) |ev2, ev4| {
        try testing.expectEqualStrings(ev2.path, ev4.path);
        try testing.expect(ev2.oid.eql(ev4.oid));
    }

    {
        var bad_buf: [64]u8 = undefined;
        @memcpy(bad_buf[0..4], "DIRC");
        std.mem.writeInt(u32, bad_buf[4..8], 2, .big);
        std.mem.writeInt(u32, bad_buf[8..12], 0, .big);
        @memcpy(bad_buf[12..16], "link");
        std.mem.writeInt(u32, bad_buf[16..20], 0, .big);
        @memset(bad_buf[20..40], 0);
        try testing.expectError(error.UnsupportedIndexExtension, git_index.GitIndex.parse(allocator, bad_buf[0..40], .sha1, 100, 0, 40, 1));

        @memcpy(bad_buf[12..16], "sdir");
        try testing.expectError(error.UnsupportedIndexExtension, git_index.GitIndex.parse(allocator, bad_buf[0..40], .sha1, 100, 0, 40, 1));

        @memcpy(bad_buf[12..16], "TREE");
        var skip_hash_idx = try git_index.GitIndex.parse(allocator, bad_buf[0..40], .sha1, 100, 0, 40, 1);
        skip_hash_idx.deinit(allocator);
    }

    try writeTestFile(io, repo1, "a", "content-a-modified\n", false);
    try writeTestFile(io, repo1, "added.txt", "brand new\n", false);
    {
        var rdir = try std.Io.Dir.cwd().openDir(io, repo1, .{});
        defer rdir.close(io);
        try rdir.deleteFile(io, "ab");
    }

    {
        const dirty = try git.dirtyPaths(allocator, io, repo1);
        defer git.freePaths(allocator, dirty);
        try testing.expectEqual(@as(usize, 3), dirty.len);
    }

    {
        const o1 = try runGitTestCmd(allocator, io, repo1, &.{ "add", "-A" });
        allocator.free(o1);
    }
    var idx_after = (try git_index.GitIndex.load(allocator, io, &dirs)).?;
    defer idx_after.deinit(allocator);

    const diffs = try git_index.GitIndex.diffIndices(allocator, &idx_v4, &idx_after);
    defer allocator.free(diffs);
    try testing.expectEqual(@as(usize, 3), diffs.len);
    try testing.expectEqual(git_index.IndexDiffKind.modified, diffs[0].kind);
    try testing.expectEqualStrings("a", diffs[0].path);
    try testing.expectEqual(git_index.IndexDiffKind.removed, diffs[1].kind);
    try testing.expectEqualStrings("ab", diffs[1].path);
    try testing.expectEqual(git_index.IndexDiffKind.added, diffs[2].kind);
    try testing.expectEqualStrings("added.txt", diffs[2].path);

    {
        const o2 = try runGitTestCmd(allocator, io, repo1, &.{ "commit", "-m", "second" });
        allocator.free(o2);
    }
    var h2 = try git.head(allocator, io, repo1);
    defer h2.deinit(allocator);
    {
        const changed = try git.changedPaths(allocator, io, repo1, h1.commit.?, h2.commit.?);
        defer git.freePaths(allocator, changed);
        try testing.expectEqual(@as(usize, 3), changed.len);
    }

    var delta_oids: std.ArrayList(git_dirs.GitOid) = .empty;
    defer delta_oids.deinit(allocator);
    var delta_payloads: std.ArrayList([]u8) = .empty;
    defer {
        for (delta_payloads.items) |p| allocator.free(p);
        delta_payloads.deinit(allocator);
    }

    var base_text: std.ArrayList(u8) = .empty;
    defer base_text.deinit(allocator);
    for (0..400) |line_i| {
        var lbuf: [64]u8 = undefined;
        const ln = try std.fmt.bufPrint(&lbuf, "line {d:0>4}: alpha beta gamma delta epsilon zeta eta\n", .{line_i});
        try base_text.appendSlice(allocator, ln);
    }

    for (0..20) |rev| {
        var cur: std.ArrayList(u8) = .empty;
        defer cur.deinit(allocator);
        try cur.appendSlice(allocator, base_text.items);
        var tail_buf: [64]u8 = undefined;
        const tail = try std.fmt.bufPrint(&tail_buf, "revision-marker-{d}\n", .{rev});
        try cur.appendSlice(allocator, tail);

        const owned_payload = try allocator.dupe(u8, cur.items);
        errdefer allocator.free(owned_payload);
        try delta_payloads.append(allocator, owned_payload);
        try delta_oids.append(allocator, git_dirs.GitOid.ofBlob(.sha1, owned_payload));

        try writeTestFile(io, repo1, "evolving.txt", owned_payload, false);
        const oa = try runGitTestCmd(allocator, io, repo1, &.{ "add", "evolving.txt" });
        allocator.free(oa);
        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "rev-{d}", .{rev});
        const oc = try runGitTestCmd(allocator, io, repo1, &.{ "commit", "-m", msg });
        allocator.free(oc);
    }

    const odb = try git_odb.GitOdb.open(allocator, io, dirs.common_dir, dirs.config.object_format, "refs/0ndb/testpin");
    defer odb.deinit();

    const big_oid = git_dirs.GitOid.ofBlob(.sha1, big_blob);
    const empty_oid = git_dirs.GitOid.ofBlob(.sha1, empty_data);
    try testing.expect(odb.contains(big_oid));
    try testing.expect(odb.contains(empty_oid));

    {
        const loose_read = (try odb.readBlobAlloc(allocator, big_oid)).?;
        defer allocator.free(loose_read);
        try testing.expectEqualSlices(u8, big_blob, loose_read);

        const loose_empty = (try odb.readBlobAlloc(allocator, empty_oid)).?;
        defer allocator.free(loose_empty);
        try testing.expectEqual(@as(usize, 0), loose_empty.len);

        var stream_out = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
        defer stream_out.deinit();
        const copied = (try odb.copyBlobToFile(delta_oids.items[0], &stream_out.writer)).?;
        try testing.expectEqual(delta_payloads.items[0].len, copied);
        try testing.expectEqualSlices(u8, delta_payloads.items[0], stream_out.written());
    }

    {
        const gc_out = try runGitTestCmd(allocator, io, repo1, &.{ "gc", "--aggressive", "--prune=now" });
        allocator.free(gc_out);
        const pr_out = try runGitTestCmd(allocator, io, repo1, &.{ "pack-refs", "--all" });
        allocator.free(pr_out);
    }

    {
        var packed_head = try git.head(allocator, io, repo1);
        defer packed_head.deinit(allocator);
        try testing.expectEqualStrings("main", packed_head.branch.?);
        try testing.expect(packed_head.commit != null);
        const packed_tip = (try git.branchTip(allocator, io, repo1, "main")).?;
        defer allocator.free(packed_tip);
        try testing.expectEqualStrings(packed_head.commit.?, packed_tip);
    }

    odb.hibernate();

    for (delta_oids.items, delta_payloads.items) |d_oid, expected| {
        const got = (try odb.readBlobAlloc(allocator, d_oid)).?;
        defer allocator.free(got);
        try testing.expectEqualSlices(u8, expected, got);
    }

    {
        const cached = (try odb.readBlobCached(big_oid)).?;
        try testing.expectEqualSlices(u8, big_blob, cached);

        var reader = odb.externalReader();
        defer reader.deinit();
        reader.lock();
        defer reader.unlock();
        const locked_slice = (try reader.readBlobCachedLocked(delta_oids.items[10])).?;
        try testing.expectEqualSlices(u8, delta_payloads.items[10], locked_slice);
    }

    {
        const midx_out = try runGitTestCmd(allocator, io, repo1, &.{ "multi-pack-index", "write" });
        allocator.free(midx_out);
    }
    {
        const odb_midx = try git_odb.GitOdb.open(allocator, io, dirs.common_dir, dirs.config.object_format, null);
        defer odb_midx.deinit();
        try testing.expect(odb_midx.stores.items[0].midx != null);
        for (delta_oids.items, delta_payloads.items) |d_oid, expected| {
            const got = (try odb_midx.readBlobAlloc(allocator, d_oid)).?;
            defer allocator.free(got);
            try testing.expectEqualSlices(u8, expected, got);
        }
        var stream_out = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
        defer stream_out.deinit();
        const copied = (try odb_midx.copyBlobToFile(big_oid, &stream_out.writer)).?;
        try testing.expectEqual(big_blob.len, copied);
        try testing.expectEqualSlices(u8, big_blob, stream_out.written());
    }

    {
        var to_pin: std.ArrayList(git_dirs.GitOid) = .empty;
        defer to_pin.deinit(allocator);
        try to_pin.append(allocator, big_oid);
        try to_pin.append(allocator, empty_oid);
        try to_pin.append(allocator, big_oid);
        try to_pin.appendSlice(allocator, delta_oids.items[0..5]);

        try odb.pinOids(to_pin.items);

        const pin_hex = (try dirs.resolveRef(allocator, io, "refs/0ndb/testpin")).?;
        defer allocator.free(pin_hex);
        try testing.expectEqual(@as(usize, 40), pin_hex.len);

        const pin_commit_oid = try git_dirs.GitOid.fromHex(pin_hex);
        var pin_commit_obj = (try odb.readObject(allocator, pin_commit_oid)).?;
        defer pin_commit_obj.deinit(allocator);
        try testing.expectEqual(git_odb.ObjectType.commit, pin_commit_obj.kind);
        try testing.expectError(error.NotABlob, odb.readBlobAlloc(allocator, pin_commit_oid));

        const fsck_out = try runGitTestCmd(allocator, io, repo1, &.{ "fsck", "--full", "--strict" });
        allocator.free(fsck_out);

        const ls_out = try runGitTestCmd(allocator, io, repo1, &.{ "ls-tree", "refs/0ndb/testpin" });
        defer allocator.free(ls_out);
        var line_count: usize = 0;
        var lit = std.mem.tokenizeScalar(u8, ls_out, '\n');
        while (lit.next()) |_| line_count += 1;
        try testing.expectEqual(@as(usize, 7), line_count);

        try odb.pinOids(&.{});
        const fsck_empty = try runGitTestCmd(allocator, io, repo1, &.{ "fsck", "--full", "--strict" });
        allocator.free(fsck_empty);
    }

    {
        const WorkerCtx = struct {
            odb: *git_odb.GitOdb,
            oids: []const git_dirs.GitOid,
            payloads: []const []u8,
            failed: std.atomic.Value(bool),

            fn run(ctx: *@This()) void {
                defer ctx.odb.release();
                for (0..ctx.oids.len) |i| {
                    const got = (ctx.odb.readBlobAlloc(std.heap.page_allocator, ctx.oids[i]) catch {
                        ctx.failed.store(true, .release);
                        return;
                    }) orelse {
                        ctx.failed.store(true, .release);
                        return;
                    };
                    defer std.heap.page_allocator.free(got);
                    if (!std.mem.eql(u8, got, ctx.payloads[i])) {
                        ctx.failed.store(true, .release);
                        return;
                    }
                    ctx.odb.lock();
                    const locked = ctx.odb.readBlobCachedLocked(ctx.oids[i]) catch {
                        ctx.odb.unlock();
                        ctx.failed.store(true, .release);
                        return;
                    };
                    const ok = locked != null and std.mem.eql(u8, locked.?, ctx.payloads[i]);
                    ctx.odb.unlock();
                    if (!ok) {
                        ctx.failed.store(true, .release);
                        return;
                    }
                }
            }
        };

        var ctx = WorkerCtx{
            .odb = odb,
            .oids = delta_oids.items,
            .payloads = delta_payloads.items,
            .failed = .init(false),
        };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*t| {
            odb.retain();
            t.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctx});
        }
        for (&threads) |*t| t.join();
        try testing.expect(!ctx.failed.load(.acquire));
    }

    {
        const wt_out = try runGitTestCmd(allocator, io, repo1, &.{ "worktree", "add", "-b", "wt-branch", wt1 });
        allocator.free(wt_out);

        var wt_dirs = (try git_dirs.GitDirs.locate(allocator, io, wt1)).?;
        defer wt_dirs.deinit(allocator);
        try testing.expect(!std.mem.eql(u8, wt_dirs.git_dir, wt_dirs.common_dir));
        try testing.expectEqualStrings(dirs.common_dir, wt_dirs.common_dir);

        try writeTestFile(io, wt1, "intent.txt", "pending\n", false);
        const o_ita = try runGitTestCmd(allocator, io, wt1, &.{ "add", "-N", "intent.txt" });
        allocator.free(o_ita);
        const o_sw = try runGitTestCmd(allocator, io, wt1, &.{ "update-index", "--skip-worktree", "a" });
        allocator.free(o_sw);

        var wt_idx = (try git_index.GitIndex.load(allocator, io, &wt_dirs)).?;
        defer wt_idx.deinit(allocator);
        try testing.expect(wt_idx.version >= 3);
        const e_ita = wt_idx.find("intent.txt").?;
        try testing.expect(e_ita.isExtended());
        try testing.expect(e_ita.isIntentToAdd());
        const e_sw = wt_idx.find("a").?;
        try testing.expect(e_sw.isExtended());
        try testing.expect(e_sw.isSkipWorktree());

        var wtd = try std.Io.Dir.cwd().openDir(io, wt1, .{});
        defer wtd.close(io);
        const st_a = try wtd.statFile(io, "a", .{});
        wt_idx.index_mtime_s = e_sw.stat.mtime_s + 10;
        try testing.expect(!wt_idx.isStatClean(e_sw, st_a, wt_dirs.config));
        const st_ita = try wtd.statFile(io, "intent.txt", .{});
        try testing.expect(!wt_idx.isStatClean(e_ita, st_ita, wt_dirs.config));

        var wt_head = try wt_dirs.readHead(allocator, io);
        defer wt_head.deinit(allocator);
        try testing.expectEqualStrings("wt-branch", wt_head.branch.?);
        try testing.expect(wt_head.commit != null);

        const mc = (try git.mainCheckout(allocator, io, wt1)).?;
        defer allocator.free(mc);
        try testing.expectEqualStrings(dirs.worktree_root, mc);

        try writeTestFile(io, wt_dirs.git_dir, "config.worktree", "[core]\n\tfilemode = false\n", false);
        var wt_dirs2 = (try git_dirs.GitDirs.locate(allocator, io, wt1)).?;
        defer wt_dirs2.deinit(allocator);
        try testing.expect(!wt_dirs2.config.filemode);
    }

    {
        try std.Io.Dir.cwd().createDirPath(io, alt_repo);
        const o_init = try runGitTestCmd(allocator, io, alt_repo, &.{ "init", "-b", "main" });
        allocator.free(o_init);
        var alt_dirs = (try git_dirs.GitDirs.locate(allocator, io, alt_repo)).?;
        defer alt_dirs.deinit(allocator);
        const primary_objs = try std.fs.path.join(allocator, &.{ dirs.common_dir, "objects" });
        defer allocator.free(primary_objs);
        const alt_line = try std.fmt.allocPrint(allocator, "{s}\n", .{primary_objs});
        defer allocator.free(alt_line);
        try writeTestFile(io, alt_dirs.common_dir, "objects/info/alternates", alt_line, false);

        const alt_odb = try git_odb.GitOdb.open(allocator, io, alt_dirs.common_dir, .sha1, null);
        defer alt_odb.deinit();
        try testing.expect(alt_odb.contains(big_oid));
        const got_alt = (try alt_odb.readBlobAlloc(allocator, delta_oids.items[5])).?;
        defer allocator.free(got_alt);
        try testing.expectEqualSlices(u8, delta_payloads.items[5], got_alt);
    }

    {
        try git.cloneDirReflink(allocator, io, repo1, clone_dst);
        var d = try std.Io.Dir.cwd().openDir(io, clone_dst, .{});
        defer d.close(io);
        const f = try d.openFile(io, "sub/deep/file.txt", .{});
        defer f.close(io);
        var rbuf: [128]u8 = undefined;
        const rn = try f.readPositionalAll(io, &rbuf, 0);
        try testing.expectEqualStrings(deep_text, rbuf[0..rn]);
    }

    {
        try std.Io.Dir.cwd().createDirPath(io, repo256);
        const o_init = try runGitTestCmd(allocator, io, repo256, &.{ "init", "--object-format=sha256", "-b", "main" });
        allocator.free(o_init);

        const s256_data = "sha256 blob payload for native git layer\n";
        try writeTestFile(io, repo256, "hello.txt", s256_data, false);
        try writeTestFile(io, repo256, "dir/sub.txt", "nested sha256 file\n", false);
        const oa = try runGitTestCmd(allocator, io, repo256, &.{ "add", "-A" });
        allocator.free(oa);
        const oc = try runGitTestCmd(allocator, io, repo256, &.{ "commit", "-m", "sha256-init" });
        allocator.free(oc);

        var dirs256 = (try git_dirs.GitDirs.locate(allocator, io, repo256)).?;
        defer dirs256.deinit(allocator);
        try testing.expectEqual(git_dirs.ObjectFormat.sha256, dirs256.config.object_format);

        var h256 = try dirs256.readHead(allocator, io);
        defer h256.deinit(allocator);
        try testing.expectEqualStrings("main", h256.branch.?);
        try testing.expectEqual(@as(usize, 64), h256.commit.?.len);

        var idx256_v2 = (try git_index.GitIndex.load(allocator, io, &dirs256)).?;
        defer idx256_v2.deinit(allocator);
        const e_hello = idx256_v2.find("hello.txt").?;
        const expected_oid256 = git_dirs.GitOid.ofBlob(.sha256, s256_data);
        try testing.expect(e_hello.oid.eql(expected_oid256));

        const ov4 = try runGitTestCmd(allocator, io, repo256, &.{ "update-index", "--index-version", "4" });
        allocator.free(ov4);
        var idx256_v4 = (try git_index.GitIndex.load(allocator, io, &dirs256)).?;
        defer idx256_v4.deinit(allocator);
        try testing.expectEqual(@as(u32, 4), idx256_v4.version);
        try testing.expect(idx256_v4.find("hello.txt").?.oid.eql(expected_oid256));
        try testing.expect(idx256_v4.find("dir/sub.txt") != null);

        const ogc = try runGitTestCmd(allocator, io, repo256, &.{ "gc", "--aggressive", "--prune=now" });
        allocator.free(ogc);
        const omidx = try runGitTestCmd(allocator, io, repo256, &.{ "multi-pack-index", "write" });
        allocator.free(omidx);

        const odb256 = try git_odb.GitOdb.open(allocator, io, dirs256.common_dir, .sha256, "refs/0ndb/pin256");
        defer odb256.deinit();
        try testing.expect(odb256.stores.items[0].midx != null);
        const got256 = (try odb256.readBlobAlloc(allocator, expected_oid256)).?;
        defer allocator.free(got256);
        try testing.expectEqualStrings(s256_data, got256);

        try odb256.pinOids(&.{ expected_oid256, idx256_v4.find("dir/sub.txt").?.oid });
        const fsck256 = try runGitTestCmd(allocator, io, repo256, &.{ "fsck", "--full", "--strict" });
        allocator.free(fsck256);
    }
}
