const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ondb = @import("ondb");

pub fn main(init: std.process.Init) !void {
    ondb.playground.server.ignoreSigpipe();
    const allocator = init.gpa;
    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    _ = args_it.next();

    const cmd = args_it.next() orelse {
        try printUsage(out);
        try out.flush();
        return;
    };

    if (std.mem.eql(u8, cmd, "providers")) {
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
    } else if (std.mem.eql(u8, cmd, "init")) {
        const root = args_it.next() orelse ".";
        const state = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{root});
        defer allocator.free(state);
        var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
        defer ws.deinit();
        const bid = try ws.ingestDisk();
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(ws.history.history_id, &hex);
        try out.print("initialized 0ndb history={s} ingested={}\n", .{ hex, bid != null });
    } else if (std.mem.eql(u8, cmd, "status")) {
        const root = args_it.next() orelse ".";
        const state = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{root});
        defer allocator.free(state);
        var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
        defer ws.deinit();
        const bid = try ws.ingestDisk();
        try out.print(
            "batches={d} heads={d} synced_new={}\n",
            .{ ws.batch_log.count(), ws.history.dag.heads.slice().len, bid != null },
        );
    } else if (std.mem.eql(u8, cmd, "watch")) {
        const root = args_it.next() orelse ".";
        const state = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{root});
        defer allocator.free(state);
        var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
        defer ws.deinit();
        try ws.attachWatcher();
        try out.print("watching {s}\n", .{root});
        try out.flush();
        while (true) {
            const step = try ws.watchStep(-1, "watch");
            if (step.batch_id) |bid| {
                var ahex: [32]u8 = undefined;
                _ = ondb.core.id.formatIdHex(bid.actor, &ahex);
                try out.print("committed {s}@{d}\n", .{ ahex[0..8], bid.ts });
                try out.flush();
            }
        }
    } else if (std.mem.eql(u8, cmd, "blame")) {
        const path = args_it.next() orelse return error.MissingPath;
        const root = args_it.next() orelse ".";
        const state = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{root});
        defer allocator.free(state);
        var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
        defer ws.deinit();
        var lines = try ws.history.blameFile(allocator, path) orelse {
            try out.print("file not tracked: {s}\n", .{path});
            try out.flush();
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
    } else if (std.mem.eql(u8, cmd, "sessions")) {
        const root = args_it.next() orelse ".";
        const state = try std.fmt.allocPrint(allocator, "{s}/.0ndb", .{root});
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
    } else if (std.mem.eql(u8, cmd, "thread")) {
        try handleThreadCmd(allocator, io, &args_it, out);
    } else if (std.mem.eql(u8, cmd, "relay")) {
        const port_str = args_it.next() orelse "9090";
        const port = try std.fmt.parseInt(u16, port_str, 10);
        const dir = args_it.next() orelse ".0ndb-relay";
        const secret_str = args_it.next() orelse "0ndb-default-relay-secret";
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
        try out.print("0ndb relay listening on 127.0.0.1:{d} state={s}\n", .{ server.port, dir });
        try out.flush();
        try server.run();
    } else if (std.mem.eql(u8, cmd, "playground")) {
        const port_str = args_it.next() orelse "4321";
        const port = try std.fmt.parseInt(u16, port_str, 10);
        const dir = args_it.next() orelse "/tmp/0ndb-playground";
        var srv = try ondb.playground.server.PlaygroundServer.start(allocator, io, dir, port);
        defer srv.deinit();
        try out.print(
            "0ndb playground running at http://127.0.0.1:{d} (workspace={s}, relay=127.0.0.1:{d})\n",
            .{ srv.http_port, dir, srv.relay.port },
        );
        try out.flush();
        try srv.serve();
    } else if (std.mem.eql(u8, cmd, "bench")) {
        try runBench(allocator, io, out);
    } else {
        try printUsage(out);
    }
    try out.flush();
}

fn handleThreadCmd(allocator: Allocator, io: Io, args_it: *std.process.Args.Iterator, out: anytype) !void {
    const sub = args_it.next() orelse return error.MissingSubcommand;
    const root = ".";
    const state = ".0ndb";
    var ws = try ondb.fs.workspace.Workspace.open(allocator, io, root, state, null);
    defer ws.deinit();
    var eng = try ondb.session.engine.SessionEngine.open(allocator, io, &ws, state);
    defer eng.deinit();

    if (std.mem.eql(u8, sub, "new")) {
        const prov_slug = args_it.next() orelse "codex";
        const prov = ondb.providers.interface.ProviderId.fromSlug(prov_slug) orelse return error.UnknownProvider;
        const title = args_it.next() orelse "session";
        const tid = try eng.createThread(title, prov, null);
        var hex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(tid, &hex);
        try out.print("{s}\n", .{hex});
    } else if (std.mem.eql(u8, sub, "send")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const prompt = args_it.next() orelse return error.MissingPrompt;
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const mid = try eng.executePrompt(tid, prompt, null, null, ondb.session.engine.DEFAULT_FACTORY, null);
        var mhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(mid, &mhex);
        if (eng.journal.messages.get(mid)) |m| {
            try out.print("{s}\n{s}\n", .{ mhex, m.content });
        }
    } else if (std.mem.eql(u8, sub, "queue")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const prompt = args_it.next() orelse return error.MissingPrompt;
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const qid = try eng.enqueue(tid, prompt, null, null);
        var qhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(qid, &qhex);
        try out.print("queued {s}\n", .{qhex});
    } else if (std.mem.eql(u8, sub, "steer")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const prompt = args_it.next() orelse return error.MissingPrompt;
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const qid = try eng.steer(tid, prompt, null, null);
        var qhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(qid, &qhex);
        try out.print("steered {s}\n", .{qhex});
    } else if (std.mem.eql(u8, sub, "edit")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const mid_hex = args_it.next() orelse return error.MissingMessageId;
        const prompt = args_it.next() orelse return error.MissingPrompt;
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const mid = try ondb.core.id.parseIdHex(mid_hex);
        const new_id = try eng.editMessage(tid, mid, prompt, null, null);
        var nhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(new_id, &nhex);
        try out.print("branched {s}\n", .{nhex});
    } else if (std.mem.eql(u8, sub, "rollback")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const mid_hex = args_it.next();
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const mid: ?u128 = if (mid_hex) |h| try ondb.core.id.parseIdHex(h) else null;
        try eng.rollback(tid, mid);
        try out.print("rolled back\n", .{});
    } else if (std.mem.eql(u8, sub, "branch")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const mid_hex = args_it.next() orelse return error.MissingMessageId;
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const mid = try ondb.core.id.parseIdHex(mid_hex);
        const leaf = try eng.switchBranch(tid, mid);
        var lhex: [32]u8 = undefined;
        _ = ondb.core.id.formatIdHex(leaf, &lhex);
        try out.print("leaf {s}\n", .{lhex});
    } else if (std.mem.eql(u8, sub, "page")) {
        const tid_hex = args_it.next() orelse return error.MissingThreadId;
        const limit_str = args_it.next() orelse "20";
        const before_hex = args_it.next();
        const tid = try ondb.core.id.parseIdHex(tid_hex);
        const limit = try std.fmt.parseInt(usize, limit_str, 10);
        const before: ?u128 = if (before_hex) |h| try ondb.core.id.parseIdHex(h) else null;
        var page = try eng.getPage(allocator, tid, before, limit);
        defer page.deinit(allocator);
        for (page.messages) |m| {
            var mhex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(m.msg_id, &mhex);
            try out.print("{s} [{s}/{s}] {s}\n", .{ mhex, @tagName(m.role), @tagName(m.status), m.content });
        }
        if (page.next_before) |nb| {
            var nhex: [32]u8 = undefined;
            _ = ondb.core.id.formatIdHex(nb, &nhex);
            try out.print("next_before={s}\n", .{nhex});
        }
    } else {
        return error.UnknownSubcommand;
    }
}

fn printUsage(out: anytype) !void {
    try out.print(
        "0ndb (Zig) - zero-copy local-first CRDT & agent session engine\n" ++
            "Commands:\n" ++
            "  init [dir]                           Initialize workspace\n" ++
            "  status [dir]                         Ingest disk changes and print DAG stats\n" ++
            "  watch [dir]                          Watch workspace via single-fd epoll/inotify\n" ++
            "  blame <file> [dir]                   Show CRDT actor/ts blame\n" ++
            "  providers                            List all 9 supported agent harnesses\n" ++
            "  sessions [dir]                       List threads and live statuses\n" ++
            "  thread new <provider> [title]        Create a new session thread\n" ++
            "  thread send <tid> <prompt>           Send prompt to thread\n" ++
            "  thread queue <tid> <prompt>          Durably queue follow-up prompt\n" ++
            "  thread steer <tid> <prompt>          Durably steer active turn\n" ++
            "  thread edit <tid> <mid> <prompt>     Edit message and branch safely\n" ++
            "  thread rollback <tid> [mid]          Crash-safe rollback to message\n" ++
            "  thread branch <tid> <mid>            Switch to sibling branch\n" ++
            "  thread page <tid> [limit] [before]   Load paginated messages\n" ++
            "  relay [port] [dir] [secret]          Run dumb protected epoll E2EE relay\n" ++
            "  playground [port] [dir]              Launch interactive local-first web playground\n" ++
            "  bench                                Run microbenchmarks\n",
        .{},
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
