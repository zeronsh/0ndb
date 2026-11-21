const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

pub const MuseRun = struct {
    allocator: Allocator,
    io: Io,
    pipe: rpc.SubprocessPipe,
    next_id: u64,
    session_id: ?[]u8,
    active_turn_id: ?[]u8,
    pending_turn_req_id: ?u64,
    access: iface.AccessMode,
    pending: std.ArrayList(iface.Event),
    closed: bool,

    pub fn start(allocator: Allocator, io: Io, req: iface.StartRequest) !iface.RunHandle {
        const argv = [_][]const u8{ "muse", "serve" };
        const self = try allocator.create(MuseRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, &argv, req.cwd),
            .next_id = 1,
            .session_id = null,
            .active_turn_id = null,
            .pending_turn_req_id = null,
            .access = req.access,
            .pending = .empty,
            .closed = false,
        };
        errdefer self.cleanup();

        try self.initialize();
        try self.openSession(req);
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn cleanup(self: *MuseRun) void {
        if (self.session_id) |s| self.allocator.free(s);
        if (self.active_turn_id) |t| self.allocator.free(t);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *MuseRun) u64 {
        const i = self.next_id;
        self.next_id += 1;
        return i;
    }

    fn newCommandId(self: *MuseRun, buf: *[36]u8) []const u8 {
        const u = id.newUuidV7(self.io);
        var hex: [32]u8 = undefined;
        _ = id.formatIdHex(u, &hex);
        @memcpy(buf[0..8], hex[0..8]);
        buf[8] = '-';
        @memcpy(buf[9..13], hex[8..12]);
        buf[13] = '-';
        @memcpy(buf[14..18], hex[12..16]);
        buf[18] = '-';
        @memcpy(buf[19..23], hex[16..20]);
        buf[23] = '-';
        @memcpy(buf[24..36], hex[20..32]);
        return buf[0..36];
    }

    fn initialize(self: *MuseRun) !void {
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":1,\"clientInfo\":{{\"name\":\"0ndb\",\"version\":\"0.2.0\"}}}}}}",
            .{req_id},
        );
        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(req_id);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.InitializeFailed;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return error.InitializeFailed;
        try self.pipe.writeLine("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    }

    fn openSession(self: *MuseRun, req: iface.StartRequest) !void {
        const req_id = self.allocId();
        var cmd_buf: [36]u8 = undefined;
        const cmd_id = self.newCommandId(&cmd_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        if (req.resume_id) |rid| {
            const method = if (req.fork_at != null) "session/fork" else "session/resume";
            try buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"commandId\":\"{s}\",\"sessionId\":",
                .{ req_id, method, cmd_id },
            );
            try rpc.appendJsonEscaped(self.allocator, &buf, rid);
            try buf.appendSlice(self.allocator, ",\"excludeItems\":true}}");
        } else {
            try buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/start\",\"params\":{{\"commandId\":\"{s}\",\"cwd\":",
                .{ req_id, cmd_id },
            );
            try rpc.appendJsonEscaped(self.allocator, &buf, req.cwd);
            if (req.model) |m| {
                try buf.appendSlice(self.allocator, ",\"modelId\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, m);
            }
            const approval = switch (req.access) {
                .plan => "denyUnmatched",
                .accept_edits => "onRequest",
                .full => "allowAll",
            };
            try buf.appendSlice(self.allocator, ",\"approvalMode\":\"");
            try buf.appendSlice(self.allocator, approval);
            try buf.appendSlice(self.allocator, "\"}}");
        }

        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(req_id);
        defer self.allocator.free(resp);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) {
            return if (req.resume_id != null) error.ResumeFailed else error.SessionStartFailed;
        }
        const result = rpc.jsonObjGet(parsed.value, "result");
        const sess = rpc.jsonObjGet(result, "session");
        const sid = rpc.jsonStr(rpc.jsonObjGet(result, "sessionId")) orelse
            rpc.jsonStr(rpc.jsonObjGet(sess, "sessionId")) orelse
            (req.resume_id orelse "");
        if (sid.len == 0) {
            return if (req.resume_id != null) error.ResumeFailed else error.SessionStartFailed;
        }
        self.session_id = try self.allocator.dupe(u8, sid);
        try self.pending.append(self.allocator, .{
            .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, sid) } },
        });
    }

    fn waitResponse(self: *MuseRun, expected_id: u64) ![]u8 {
        while (true) {
            var line = try self.pipe.readNextLine(-1) orelse return error.ProcessExited;
            defer line.deinit(self.allocator);
            if (line.is_stderr) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.bytes, .{}) catch continue;
            defer parsed.deinit();
            if (rpc.jsonU64(rpc.jsonObjGet(parsed.value, "id"))) |rid| {
                if (rid == expected_id and rpc.jsonObjGet(parsed.value, "method") == null) {
                    return try self.allocator.dupe(u8, line.bytes);
                }
            }
            if (rpc.jsonObjGet(parsed.value, "method") != null) {
                self.handleMessage(line.bytes) catch {};
            }
        }
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        const sid = self.session_id orelse return error.NoSession;
        const req_id = self.allocId();
        self.pending_turn_req_id = req_id;
        var cmd_buf: [36]u8 = undefined;
        const cmd_id = self.newCommandId(&cmd_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/start\",\"params\":{{\"commandId\":\"{s}\",\"sessionId\":",
            .{ req_id, cmd_id },
        );
        try rpc.appendJsonEscaped(self.allocator, &buf, sid);
        try buf.appendSlice(self.allocator, ",\"input\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(buf.items);
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, expected_turn: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        const sid = self.session_id orelse return .requires_interrupt_fallback;
        const turn_id = expected_turn orelse self.active_turn_id orelse return .requires_interrupt_fallback;
        const req_id = self.allocId();
        var cmd_buf: [36]u8 = undefined;
        const cmd_id = self.newCommandId(&cmd_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/steer\",\"params\":{{\"commandId\":\"{s}\",\"sessionId\":",
            .{ req_id, cmd_id },
        );
        try rpc.appendJsonEscaped(self.allocator, &buf, sid);
        try buf.appendSlice(self.allocator, ",\"expectedTurnId\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, turn_id);
        try buf.appendSlice(self.allocator, ",\"input\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(buf.items);
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        while (true) {
            if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
            var raw_line = try self.pipe.readNextLine(-1) orelse return null;
            defer raw_line.deinit(self.allocator);
            if (raw_line.is_stderr) {
                return .{
                    .kind = .{ .other = .{ .kind = try self.allocator.dupe(u8, "stderr") } },
                    .raw = try self.allocator.dupe(u8, raw_line.bytes),
                };
            }
            try self.handleMessage(raw_line.bytes);
        }
    }

    fn handleMessage(self: *MuseRun, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        const method_opt = rpc.jsonStr(rpc.jsonObjGet(root, "method"));
        if (method_opt == null) {
            if (rpc.jsonU64(rpc.jsonObjGet(root, "id"))) |rid| {
                if (self.pending_turn_req_id) |pid| {
                    if (rid == pid) {
                        self.pending_turn_req_id = null;
                        if (rpc.jsonObjGet(root, "error")) |err_obj| {
                            const msg = rpc.jsonStr(rpc.jsonObjGet(err_obj, "message")) orelse "muse turn error";
                            try self.pending.append(self.allocator, .{
                                .kind = .{ .turn_ended = .{
                                    .ok = false,
                                    .err_msg = try self.allocator.dupe(u8, msg),
                                } },
                                .raw = try self.allocator.dupe(u8, line),
                            });
                        }
                    }
                }
            }
            return;
        }
        const method = method_opt.?;
        const params = rpc.jsonObjGet(root, "params");

        if (std.mem.eql(u8, method, "turn/started")) {
            if (rpc.jsonStr(rpc.jsonObjGet(params, "turnId"))) |tid| {
                if (self.active_turn_id) |old| self.allocator.free(old);
                self.active_turn_id = try self.allocator.dupe(u8, tid);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .turn_started = .{ .native_turn_id = try self.allocator.dupe(u8, tid) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "item/delta")) {
            const delta = rpc.jsonStr(rpc.jsonObjGet(params, "delta")) orelse "";
            const field = rpc.jsonStr(rpc.jsonObjGet(params, "field")) orelse "text";
            if (delta.len > 0) {
                if (std.mem.startsWith(u8, field, "reasoning") or std.mem.startsWith(u8, field, "thinking")) {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning_delta = .{ .text = try self.allocator.dupe(u8, delta) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                } else {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, delta) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                }
            }
        } else if (std.mem.eql(u8, method, "item/started")) {
            const item = rpc.jsonObjGet(params, "item");
            const kind = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, kind, "toolCall") or std.mem.eql(u8, kind, "tool_call")) {
                const name = rpc.jsonStr(rpc.jsonObjGet(item, "name")) orelse "tool";
                const input_val = rpc.jsonObjGet(item, "input") orelse rpc.jsonObjGet(item, "arguments");
                const input_json = try rpc.stringifyJsonValue(self.allocator, input_val);
                errdefer self.allocator.free(input_json);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_started = .{
                        .id = try self.allocator.dupe(u8, iid),
                        .name = try self.allocator.dupe(u8, name),
                        .input_json = input_json,
                    } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "item/completed")) {
            const item = rpc.jsonObjGet(params, "item");
            const kind = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, kind, "assistantMessage") or std.mem.eql(u8, kind, "text")) {
                if (rpc.jsonStr(rpc.jsonObjGet(item, "text"))) |t| {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, t) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                }
            } else if (std.mem.eql(u8, kind, "reasoning")) {
                if (rpc.jsonStr(rpc.jsonObjGet(item, "text"))) |t| {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning = .{ .text = try self.allocator.dupe(u8, t) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                }
            } else if (std.mem.eql(u8, kind, "toolCall") or std.mem.eql(u8, kind, "tool_call")) {
                const out_val = rpc.jsonObjGet(item, "output") orelse
                    rpc.jsonObjGet(item, "result") orelse
                    rpc.jsonObjGet(item, "error");
                const output = try rpc.extractTextOrJson(self.allocator, out_val);
                errdefer self.allocator.free(output);
                const is_err = rpc.jsonBool(rpc.jsonObjGet(item, "isError")) orelse false;
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_finished = .{
                        .id = try self.allocator.dupe(u8, iid),
                        .output = output,
                        .is_error = is_err,
                    } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "approval/requested")) {
            if (self.session_id) |sid| {
                const aid = rpc.jsonStr(rpc.jsonObjGet(params, "approvalId")) orelse "";
                const req_ref = rpc.jsonStr(rpc.jsonObjGet(params, "currentRequirementId")) orelse "";
                const choice = switch (self.access) {
                    .plan => "deny",
                    .accept_edits, .full => "approve",
                };
                const rid = self.allocId();
                var cmd_buf: [36]u8 = undefined;
                const cmd_id = self.newCommandId(&cmd_buf);
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                try buf.print(
                    self.allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"approval/decide\",\"params\":{{\"commandId\":\"{s}\",\"sessionId\":",
                    .{ rid, cmd_id },
                );
                try rpc.appendJsonEscaped(self.allocator, &buf, sid);
                try buf.appendSlice(self.allocator, ",\"approvalId\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, aid);
                try buf.appendSlice(self.allocator, ",\"requirementId\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, req_ref);
                try buf.appendSlice(self.allocator, ",\"choiceId\":\"");
                try buf.appendSlice(self.allocator, choice);
                try buf.appendSlice(self.allocator, "\"}}");
                self.pipe.writeLine(buf.items) catch {};
            }
            if (rpc.jsonObjGet(root, "id")) |id_val| {
                try rpc.replyResultJson(self.allocator, &self.pipe, id_val, "{}");
            }
        } else if (std.mem.eql(u8, method, "turn/completed")) {
            const term = rpc.jsonStr(rpc.jsonObjGet(params, "terminal")) orelse "completed";
            const ok = std.mem.eql(u8, term, "completed");
            const err_msg: ?[]u8 = if (!ok) try self.allocator.dupe(u8, term) else null;
            if (self.active_turn_id) |old| {
                self.allocator.free(old);
                self.active_turn_id = null;
            }
            self.pending_turn_req_id = null;
            try self.pending.append(self.allocator, .{
                .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } },
                .raw = try self.allocator.dupe(u8, line),
            });
        } else if (rpc.jsonObjGet(root, "id")) |id_val| {
            try rpc.replyMethodNotFound(self.allocator, &self.pipe, id_val, method);
        }
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        if (self.session_id) |sid| {
            const req_id = self.allocId();
            var cmd_buf: [36]u8 = undefined;
            const cmd_id = self.newCommandId(&cmd_buf);
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            buf.print(self.allocator, 
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/interrupt\",\"params\":{{\"commandId\":\"{s}\",\"sessionId\":",
                .{ req_id, cmd_id },
            ) catch return;
            rpc.appendJsonEscaped(self.allocator, &buf, sid) catch return;
            if (self.active_turn_id) |tid| {
                buf.appendSlice(self.allocator, ",\"turnId\":") catch return;
                rpc.appendJsonEscaped(self.allocator, &buf, tid) catch return;
            }
            buf.appendSlice(self.allocator, "}}") catch return;
            self.pipe.writeLine(buf.items) catch {};
        }
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        if (!self.closed) {
            self.closed = true;
            self.cleanup();
            self.allocator.destroy(self);
        }
    }
};

pub fn capabilities() iface.Capabilities {
    return .{
        .resume_session = true,
        .fork_at_message = false,
        .persistent = true,
        .native_steer = true,
    };
}
