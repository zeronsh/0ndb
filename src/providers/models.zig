const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");
const acp = @import("acp.zig");

pub const ModelCatalog = struct {
    models: []iface.ModelInfo,
    note: ?[]u8,

    pub fn deinit(self: *ModelCatalog, allocator: Allocator) void {
        for (self.models) |*m| m.deinit(allocator);
        allocator.free(self.models);
        if (self.note) |n| allocator.free(n);
    }

    pub fn clone(self: *const ModelCatalog, allocator: Allocator) Allocator.Error!ModelCatalog {
        const list = try allocator.alloc(iface.ModelInfo, self.models.len);
        var built: usize = 0;
        errdefer {
            for (list[0..built]) |*m| m.deinit(allocator);
            allocator.free(list);
        }
        for (self.models, 0..) |m, i| {
            list[i] = .{
                .id = try allocator.dupe(u8, m.id),
                .name = try allocator.dupe(u8, m.name),
                .is_default = m.is_default,
            };
            built += 1;
        }
        const note_copy = if (self.note) |n| try allocator.dupe(u8, n) else null;
        return .{ .models = list, .note = note_copy };
    }
};

pub fn discover(allocator: Allocator, io: Io, provider: iface.ProviderId) !ModelCatalog {
    return switch (provider) {
        .mock => discoverMock(allocator),
        .claude_code => discoverClaude(allocator),
        .codex => discoverCodex(allocator, io),
        .pi => discoverPi(allocator, io),
        .antigravity => discoverAcp(allocator, io, antigravityArgv(io), "antigravity"),
        .hermes => discoverAcp(allocator, io, acp.HERMES_PROFILE.argv, "hermes"),
        .opencode => discoverAcp(allocator, io, acp.OPENCODE_PROFILE.argv, "opencode"),
        .cursor => discoverAcp(allocator, io, acp.CURSOR_PROFILE.argv, "cursor"),
        .devin => discoverAcp(allocator, io, acp.DEVIN_PROFILE.argv, "devin"),
        .muse => discoverMuse(allocator),
    };
}

pub fn antigravityArgv(io: Io) []const []const u8 {
    if (iface.programOnPath(io, "agy_acp_server")) {
        return &.{"agy_acp_server"};
    }
    if (iface.programOnPath(io, "agy_acp_server.par")) {
        return &.{"agy_acp_server.par"};
    }
    return &.{"agy_acp_server"};
}

fn discoverMock(allocator: Allocator) !ModelCatalog {
    var list: std.ArrayList(iface.ModelInfo) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "sim-native-v1"),
        .name = try allocator.dupe(u8, "Native Mid-Turn Steer"),
        .is_default = true,
    });
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "sim-fallback-v1"),
        .name = try allocator.dupe(u8, "Interrupt & Resume Steer"),
        .is_default = false,
    });
    return .{ .models = try list.toOwnedSlice(allocator), .note = null };
}

fn discoverClaude(allocator: Allocator) !ModelCatalog {
    var list: std.ArrayList(iface.ModelInfo) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    const presets = [_]struct { id: []const u8, name: []const u8, def: bool }{
        .{ .id = "opus", .name = "Claude Opus", .def = false },
        .{ .id = "sonnet", .name = "Claude Sonnet", .def = true },
        .{ .id = "haiku", .name = "Claude Haiku", .def = false },
    };
    for (presets) |p| {
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, p.id),
            .name = try allocator.dupe(u8, p.name),
            .is_default = p.def,
        });
    }
    return .{ .models = try list.toOwnedSlice(allocator), .note = null };
}

fn discoverMuse(allocator: Allocator) !ModelCatalog {
    var list: std.ArrayList(iface.ModelInfo) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "default"),
        .name = try allocator.dupe(u8, "Muse Default"),
        .is_default = true,
    });
    return .{ .models = try list.toOwnedSlice(allocator), .note = null };
}

fn discoverCodex(allocator: Allocator, io: Io) !ModelCatalog {
    var pipe = rpc.SubprocessPipe.spawn(allocator, io, &.{ "codex", "app-server" }, "/tmp") catch |err| {
        return .{
            .models = try allocator.alloc(iface.ModelInfo, 0),
            .note = try std.fmt.allocPrint(allocator, "codex unavailable ({s})", .{@errorName(err)}),
        };
    };
    defer pipe.deinit();

    pipe.writeLine("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"0ndb\",\"version\":\"0.2.0\"}}}") catch {};
    pipe.writeLine("{\"method\":\"initialized\"}") catch {};
    pipe.writeLine("{\"id\":2,\"method\":\"model/list\",\"params\":{}}") catch {};

    var list: std.ArrayList(iface.ModelInfo) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    var note: ?[]u8 = null;
    errdefer if (note) |n| allocator.free(n);

    var lines_seen: usize = 0;
    while (lines_seen < 64) : (lines_seen += 1) {
        var line = (pipe.readNextLine(15000) catch null) orelse break;
        defer line.deinit(allocator);
        if (line.is_stderr) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line.bytes, .{}) catch continue;
        defer parsed.deinit();
        const rid = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "id")) orelse continue;
        if (rid != 2) continue;

        if (rpc.jsonObjGet(parsed.value, "error")) |err_v| {
            if (rpc.jsonStr(rpc.jsonObjGet(err_v, "message"))) |msg| {
                note = try allocator.dupe(u8, msg);
            }
            break;
        }
        const data_v = rpc.jsonObjGet(rpc.jsonObjGet(parsed.value, "result"), "data") orelse break;
        if (data_v == .array) {
            for (data_v.array.items) |item| {
                if (rpc.jsonBool(rpc.jsonObjGet(item, "hidden")) orelse false) continue;
                const mid = rpc.jsonStr(rpc.jsonObjGet(item, "model")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse continue;
                const dname = rpc.jsonStr(rpc.jsonObjGet(item, "displayName")) orelse mid;
                const is_def = rpc.jsonBool(rpc.jsonObjGet(item, "isDefault")) orelse false;
                try list.append(allocator, .{
                    .id = try allocator.dupe(u8, mid),
                    .name = try allocator.dupe(u8, dname),
                    .is_default = is_def,
                });
            }
        }
        break;
    }

    return .{ .models = try list.toOwnedSlice(allocator), .note = note };
}

fn discoverPi(allocator: Allocator, io: Io) !ModelCatalog {
    const dir = "/tmp/0ndb-models-pi";
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    var pipe = rpc.SubprocessPipe.spawn(allocator, io, &.{ "pi", "--mode", "rpc", "--no-themes" }, dir) catch |err| {
        return .{
            .models = try allocator.alloc(iface.ModelInfo, 0),
            .note = try std.fmt.allocPrint(allocator, "pi unavailable ({s})", .{@errorName(err)}),
        };
    };
    defer pipe.deinit();

    pipe.writeLine("{\"id\":\"1\",\"type\":\"get_state\"}") catch {};
    pipe.writeLine("{\"id\":\"2\",\"type\":\"get_available_models\"}") catch {};

    var cur_prov: ?[]u8 = null;
    defer if (cur_prov) |p| allocator.free(p);
    var cur_id: ?[]u8 = null;
    defer if (cur_id) |i| allocator.free(i);

    var list: std.ArrayList(iface.ModelInfo) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }

    var got_state = false;
    var got_models = false;
    var lines_seen: usize = 0;
    while (lines_seen < 64 and (!got_state or !got_models)) : (lines_seen += 1) {
        var line = (pipe.readNextLine(15000) catch null) orelse break;
        defer line.deinit(allocator);
        if (line.is_stderr) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line.bytes, .{}) catch continue;
        defer parsed.deinit();
        const t = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "type")) orelse continue;
        if (!std.mem.eql(u8, t, "response")) continue;
        const rid = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "id")) orelse continue;
        if (std.mem.eql(u8, rid, "1")) {
            got_state = true;
            const mobj = rpc.jsonObjGet(rpc.jsonObjGet(parsed.value, "data"), "model");
            if (rpc.jsonStr(rpc.jsonObjGet(mobj, "provider"))) |cp| cur_prov = try allocator.dupe(u8, cp);
            if (rpc.jsonStr(rpc.jsonObjGet(mobj, "id"))) |ci| cur_id = try allocator.dupe(u8, ci);
        } else if (std.mem.eql(u8, rid, "2")) {
            got_models = true;
            const models_v = rpc.jsonObjGet(rpc.jsonObjGet(parsed.value, "data"), "models") orelse continue;
            if (models_v == .array) {
                for (models_v.array.items) |item| {
                    const prov = rpc.jsonStr(rpc.jsonObjGet(item, "provider")) orelse continue;
                    const mid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse continue;
                    const mname = rpc.jsonStr(rpc.jsonObjGet(item, "name")) orelse mid;
                    const full_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prov, mid });
                    errdefer allocator.free(full_id);
                    const full_name = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ mname, prov });
                    errdefer allocator.free(full_name);
                    try list.append(allocator, .{
                        .id = full_id,
                        .name = full_name,
                        .is_default = false,
                    });
                }
            }
        }
    }

    if (cur_prov) |cp| {
        if (cur_id) |ci| {
            const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cp, ci });
            defer allocator.free(target);
            for (list.items) |*m| {
                if (std.mem.eql(u8, m.id, target)) m.is_default = true;
            }
        }
    }

    const note: ?[]u8 = if (list.items.len == 0)
        try allocator.dupe(u8, "No API keys configured for Pi yet")
    else
        null;
    return .{ .models = try list.toOwnedSlice(allocator), .note = note };
}

fn discoverAcp(allocator: Allocator, io: Io, argv: []const []const u8, slug: []const u8) !ModelCatalog {
    const dir = try std.fmt.allocPrint(allocator, "/tmp/0ndb-models-{s}", .{slug});
    defer allocator.free(dir);
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    var pipe = rpc.SubprocessPipe.spawn(allocator, io, argv, dir) catch |err| {
        return .{
            .models = try allocator.alloc(iface.ModelInfo, 0),
            .note = try std.fmt.allocPrint(allocator, "CLI unavailable ({s})", .{@errorName(err)}),
        };
    };
    defer pipe.deinit();

    pipe.writeLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientInfo\":{\"name\":\"0ndb\",\"version\":\"0.2.0\"},\"clientCapabilities\":{}}}") catch {};

    var list: std.ArrayList(iface.ModelInfo) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    var note: ?[]u8 = null;
    errdefer if (note) |n| allocator.free(n);
    var last_stderr: ?[]u8 = null;
    defer if (last_stderr) |s| allocator.free(s);

    var can_delete = false;
    var initialized = false;
    var step: usize = 0;
    while (step < 64) : (step += 1) {
        var line = (pipe.readNextLine(15000) catch null) orelse break;
        defer line.deinit(allocator);
        if (line.is_stderr) {
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r\n");
            const is_noise = trimmed.len == 0 or
                std.mem.startsWith(u8, trimmed, "/") or
                std.mem.startsWith(u8, trimmed, "@") or
                std.mem.startsWith(u8, trimmed, "***") or
                std.mem.startsWith(u8, trimmed, "PC:") or
                std.mem.indexOf(u8, trimmed, "SyntaxWarning") != null or
                std.mem.indexOf(u8, trimmed, "0x") != null;
            if (!is_noise and last_stderr == null) {
                last_stderr = try allocator.dupe(u8, trimmed[0..@min(trimmed.len, 140)]);
            }
            continue;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line.bytes, .{}) catch continue;
        defer parsed.deinit();
        const rid = rpc.jsonU64(rpc.jsonObjGet(parsed.value, "id")) orelse continue;

        if (rid == 1 and !initialized) {
            initialized = true;
            if (rpc.jsonObjGet(parsed.value, "error")) |err_v| {
                if (rpc.jsonStr(rpc.jsonObjGet(err_v, "message"))) |msg| {
                    note = try allocator.dupe(u8, msg);
                }
                break;
            }
            const caps = rpc.jsonObjGet(rpc.jsonObjGet(parsed.value, "result"), "agentCapabilities");
            const sess_caps = rpc.jsonObjGet(caps, "sessionCapabilities");
            if (rpc.jsonObjGet(sess_caps, "delete") != null) can_delete = true;

            var req_buf: std.ArrayList(u8) = .empty;
            defer req_buf.deinit(allocator);
            try req_buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":");
            try rpc.appendJsonEscaped(allocator, &req_buf, dir);
            try req_buf.appendSlice(allocator, ",\"mcpServers\":[]}}");
            pipe.writeLine(req_buf.items) catch break;
            continue;
        }

        if (rid == 2) {
            if (rpc.jsonObjGet(parsed.value, "error")) |err_v| {
                if (rpc.jsonStr(rpc.jsonObjGet(err_v, "message"))) |msg| {
                    note = try allocator.dupe(u8, msg);
                }
                break;
            }
            const res = rpc.jsonObjGet(parsed.value, "result") orelse break;
            try parseAcpModels(allocator, res, &list);

            if (can_delete) {
                if (rpc.jsonStr(rpc.jsonObjGet(res, "sessionId"))) |sid| {
                    var del_buf: std.ArrayList(u8) = .empty;
                    defer del_buf.deinit(allocator);
                    try del_buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/delete\",\"params\":{\"sessionId\":");
                    try rpc.appendJsonEscaped(allocator, &del_buf, sid);
                    try del_buf.appendSlice(allocator, "}}");
                    pipe.writeLine(del_buf.items) catch {};
                }
            }
            break;
        }
    }

    if (list.items.len == 0 and note == null) {
        if (last_stderr) |s| {
            note = try allocator.dupe(u8, s);
        } else if (std.mem.eql(u8, slug, "cursor")) {
            note = try allocator.dupe(u8, "Authentication required — run `cursor-agent login` or set CURSOR_API_KEY");
        } else {
            note = try std.fmt.allocPrint(allocator, "{s} ACP server requires runtime session environment to list models", .{slug});
        }
    }

    return .{ .models = try list.toOwnedSlice(allocator), .note = note };
}

fn parseAcpModels(allocator: Allocator, res: std.json.Value, out: *std.ArrayList(iface.ModelInfo)) !void {
    if (rpc.jsonObjGet(res, "configOptions")) |opts_v| {
        if (opts_v == .array) {
            for (opts_v.array.items) |opt| {
                const cat = rpc.jsonStr(rpc.jsonObjGet(opt, "category")) orelse "";
                const oid = rpc.jsonStr(rpc.jsonObjGet(opt, "id")) orelse "";
                if (!std.mem.eql(u8, cat, "model") and !std.mem.eql(u8, oid, "model")) continue;
                const cur = rpc.jsonStr(rpc.jsonObjGet(opt, "currentValue")) orelse "";
                const values = rpc.jsonObjGet(opt, "options") orelse continue;
                if (values != .array) continue;
                for (values.array.items) |entry| {
                    const val = rpc.jsonStr(rpc.jsonObjGet(entry, "value")) orelse continue;
                    const name = rpc.jsonStr(rpc.jsonObjGet(entry, "name")) orelse val;
                    try out.append(allocator, .{
                        .id = try allocator.dupe(u8, val),
                        .name = try allocator.dupe(u8, name),
                        .is_default = std.mem.eql(u8, val, cur),
                    });
                }
                if (out.items.len > 0) return;
            }
        }
    }

    if (rpc.jsonObjGet(res, "models")) |mobj| {
        const cur = rpc.jsonStr(rpc.jsonObjGet(mobj, "currentModelId")) orelse "";
        const avail = rpc.jsonObjGet(mobj, "availableModels") orelse return;
        if (avail != .array) return;
        for (avail.array.items) |entry| {
            const val = rpc.jsonStr(rpc.jsonObjGet(entry, "modelId")) orelse
                rpc.jsonStr(rpc.jsonObjGet(entry, "id")) orelse continue;
            const name = rpc.jsonStr(rpc.jsonObjGet(entry, "name")) orelse val;
            try out.append(allocator, .{
                .id = try allocator.dupe(u8, val),
                .name = try allocator.dupe(u8, name),
                .is_default = std.mem.eql(u8, val, cur),
            });
        }
    }
}
