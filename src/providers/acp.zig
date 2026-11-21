const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

pub const AcpProfile = struct {
    provider: iface.ProviderId,
    argv: []const []const u8,
};

pub const ANTIGRAVITY_PROFILE = AcpProfile{
    .provider = .antigravity,
    .argv = &.{"agy_acp_server"},
};

pub const HERMES_PROFILE = AcpProfile{
    .provider = .hermes,
    .argv = &.{ "hermes", "acp" },
};

pub const OPENCODE_PROFILE = AcpProfile{
    .provider = .opencode,
    .argv = &.{ "opencode", "acp" },
};

pub const CURSOR_PROFILE = AcpProfile{
    .provider = .cursor,
    .argv = &.{ "cursor-agent", "acp" },
};

pub const DEVIN_PROFILE = AcpProfile{
    .provider = .devin,
    .argv = &.{ "devin", "acp" },
};

pub const AcpRun = struct {
    allocator: Allocator,
    io: Io,
    pipe: rpc.SubprocessPipe,
    next_id: u64,
    session_id: ?[]u8,
    prompt_req_id: ?u64,
    access: iface.AccessMode,
    supports_native_steer: bool,
    supports_load_session: bool,
    supports_resume_session: bool,
    model_config_id: ?[]u8,
    pending: std.ArrayList(iface.Event),
    closed: bool,

    pub fn start(
        allocator: Allocator,
        io: Io,
        profile: AcpProfile,
        req: iface.StartRequest,
    ) !iface.RunHandle {
        const self = try allocator.create(AcpRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, profile.argv, req.cwd),
            .next_id = 1,
            .session_id = null,
            .prompt_req_id = null,
            .access = req.access,
            .supports_native_steer = false,
            .supports_load_session = false,
            .supports_resume_session = false,
            .model_config_id = null,
            .pending = .empty,
            .closed = false,
        };
        errdefer self.cleanup();

        try self.initialize();
        try self.openSession(req);
        if (req.model) |m| {
            self.setModel(m) catch {};
        }
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn cleanup(self: *AcpRun) void {
        if (self.session_id) |s| self.allocator.free(s);
        if (self.model_config_id) |c| self.allocator.free(c);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *AcpRun) u64 {
        const i = self.next_id;
        self.next_id += 1;
        return i;
    }

    fn initialize(self: *AcpRun) !void {
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":1,\"clientInfo\":{{\"name\":\"0ndb\",\"version\":\"0.2.0\"}},\"clientCapabilities\":{{}}}}}}",
            .{req_id},
        );
        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(req_id);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.InitializeFailed;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return error.InitializeFailed;
        const caps = rpc.jsonObjGet(rpc.jsonObjGet(parsed.value, "result"), "agentCapabilities");
        if (rpc.jsonBool(rpc.jsonObjGet(caps, "loadSession")) orelse false) {
            self.supports_load_session = true;
        }
        if (rpc.jsonObjGet(rpc.jsonObjGet(caps, "sessionCapabilities"), "resume") != null) {
            self.supports_resume_session = true;
        }
        if (rpc.jsonBool(rpc.jsonObjGet(caps, "steer")) orelse false) {
            self.supports_native_steer = true;
        }
        if (rpc.jsonBool(rpc.jsonObjGet(rpc.jsonObjGet(caps, "session"), "steer")) orelse false) {
            self.supports_native_steer = true;
        }
    }

    fn openSession(self: *AcpRun, req: iface.StartRequest) !void {
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        if (req.resume_id) |rid| {
            if (!self.supports_resume_session and !self.supports_load_session) return error.ResumeUnsupported;
            const method = if (self.supports_resume_session) "session/resume" else "session/load";
            try buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"sessionId\":",
                .{ req_id, method },
            );
            try rpc.appendJsonEscaped(self.allocator, &buf, rid);
            try buf.appendSlice(self.allocator, ",\"cwd\":");
            try rpc.appendJsonEscaped(self.allocator, &buf, req.cwd);
            try buf.appendSlice(self.allocator, ",\"mcpServers\":[]}}");
        } else {
            try buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/new\",\"params\":{{\"cwd\":",
                .{req_id},
            );
            try rpc.appendJsonEscaped(self.allocator, &buf, req.cwd);
            try buf.appendSlice(self.allocator, ",\"mcpServers\":[]}}");
        }

        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(req_id);
        defer self.allocator.free(resp);

        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.clearRetainingCapacity();

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) {
            return if (req.resume_id != null) error.ResumeFailed else error.SessionStartFailed;
        }
        const result = rpc.jsonObjGet(parsed.value, "result");
        if (rpc.jsonObjGet(result, "configOptions")) |opts_val| {
            if (opts_val == .array) {
                for (opts_val.array.items) |opt| {
                    const cat = rpc.jsonStr(rpc.jsonObjGet(opt, "category")) orelse "";
                    const oid = rpc.jsonStr(rpc.jsonObjGet(opt, "id")) orelse "";
                    if (std.mem.eql(u8, cat, "model") or std.mem.eql(u8, oid, "model")) {
                        if (oid.len > 0) {
                            if (self.model_config_id) |old| self.allocator.free(old);
                            self.model_config_id = try self.allocator.dupe(u8, oid);
                        }
                        break;
                    }
                }
            }
        }
        const sid = rpc.jsonStr(rpc.jsonObjGet(result, "sessionId")) orelse
            (req.resume_id orelse "");
        if (sid.len == 0) {
            return if (req.resume_id != null) error.ResumeFailed else error.SessionStartFailed;
        }
        self.session_id = try self.allocator.dupe(u8, sid);
        try self.pending.append(self.allocator, .{
            .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, sid) } },
        });
    }

    fn setModel(self: *AcpRun, model: []const u8) !void {
        const sid = self.session_id orelse return;
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        if (self.model_config_id) |cid| {
            try buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/set_config_option\",\"params\":{{\"sessionId\":",
                .{req_id},
            );
            try rpc.appendJsonEscaped(self.allocator, &buf, sid);
            try buf.appendSlice(self.allocator, ",\"configId\":");
            try rpc.appendJsonEscaped(self.allocator, &buf, cid);
            try buf.appendSlice(self.allocator, ",\"value\":");
            try rpc.appendJsonEscaped(self.allocator, &buf, model);
            try buf.appendSlice(self.allocator, "}}");
        } else {
            try buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/set_model\",\"params\":{{\"sessionId\":",
                .{req_id},
            );
            try rpc.appendJsonEscaped(self.allocator, &buf, sid);
            try buf.appendSlice(self.allocator, ",\"modelId\":");
            try rpc.appendJsonEscaped(self.allocator, &buf, model);
            try buf.appendSlice(self.allocator, "}}");
        }
        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(req_id);
        self.allocator.free(resp);
    }

    fn waitResponse(self: *AcpRun, expected_id: u64) ![]u8 {
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
            self.handleMessage(line.bytes) catch {};
        }
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
        const sid = self.session_id orelse return error.NoSession;
        const req_id = self.allocId();
        self.prompt_req_id = req_id;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":",
            .{req_id},
        );
        try rpc.appendJsonEscaped(self.allocator, &buf, sid);
        try buf.appendSlice(self.allocator, ",\"prompt\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(buf.items);
        try self.pending.append(self.allocator, .{
            .kind = .{ .turn_started = .{ .native_turn_id = null } },
        });
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, _: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
        if (!self.supports_native_steer) return .requires_interrupt_fallback;
        const sid = self.session_id orelse return .requires_interrupt_fallback;
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/steer\",\"params\":{{\"sessionId\":",
            .{req_id},
        );
        try rpc.appendJsonEscaped(self.allocator, &buf, sid);
        try buf.appendSlice(self.allocator, ",\"prompt\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(buf.items);
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
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

    fn handleMessage(self: *AcpRun, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;

        if (rpc.jsonStr(rpc.jsonObjGet(root, "method"))) |method| {
            const params = rpc.jsonObjGet(root, "params");
            if (std.mem.eql(u8, method, "session/update")) {
                try self.handleSessionUpdate(params, line);
            } else if (std.mem.eql(u8, method, "session/request_permission")) {
                if (rpc.jsonObjGet(root, "id")) |id_val| {
                    try self.replyPermission(id_val, params);
                }
            } else if (rpc.jsonObjGet(root, "id")) |id_val| {
                try rpc.replyMethodNotFound(self.allocator, &self.pipe, id_val, method);
            }
            return;
        }

        if (rpc.jsonU64(rpc.jsonObjGet(root, "id"))) |rid| {
            if (self.prompt_req_id) |pid| {
                if (rid == pid) {
                    self.prompt_req_id = null;
                    if (rpc.jsonObjGet(root, "error")) |err_obj| {
                        const msg = rpc.jsonStr(rpc.jsonObjGet(err_obj, "message")) orelse "acp prompt error";
                        try self.pending.append(self.allocator, .{
                            .kind = .{ .turn_ended = .{
                                .ok = false,
                                .err_msg = try self.allocator.dupe(u8, msg),
                            } },
                            .raw = try self.allocator.dupe(u8, line),
                        });
                    } else {
                        const stop_reason = rpc.jsonStr(rpc.jsonObjGet(rpc.jsonObjGet(root, "result"), "stopReason")) orelse "end_turn";
                        const ok = !std.mem.eql(u8, stop_reason, "cancelled") and !std.mem.eql(u8, stop_reason, "error");
                        const err_msg: ?[]u8 = if (!ok) try self.allocator.dupe(u8, stop_reason) else null;
                        try self.pending.append(self.allocator, .{
                            .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } },
                            .raw = try self.allocator.dupe(u8, line),
                        });
                    }
                }
            }
        }
    }

    fn handleSessionUpdate(self: *AcpRun, params: ?std.json.Value, line: []const u8) !void {
        const update = rpc.jsonObjGet(params, "update") orelse params;
        const kind = rpc.jsonStr(rpc.jsonObjGet(update, "sessionUpdate")) orelse "";

        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            const content = rpc.jsonObjGet(update, "content");
            const text = rpc.jsonStr(rpc.jsonObjGet(content, "text")) orelse
                rpc.jsonStr(rpc.jsonObjGet(update, "text")) orelse "";
            if (text.len > 0) {
                try self.pending.append(self.allocator, .{
                    .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, text) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
            const content = rpc.jsonObjGet(update, "content");
            const text = rpc.jsonStr(rpc.jsonObjGet(content, "text")) orelse
                rpc.jsonStr(rpc.jsonObjGet(update, "text")) orelse "";
            if (text.len > 0) {
                try self.pending.append(self.allocator, .{
                    .kind = .{ .reasoning_delta = .{ .text = try self.allocator.dupe(u8, text) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const cid = rpc.jsonStr(rpc.jsonObjGet(update, "toolCallId")) orelse "";
            const title = rpc.jsonStr(rpc.jsonObjGet(update, "title")) orelse "tool";
            const input_val = rpc.jsonObjGet(update, "rawInput") orelse rpc.jsonObjGet(update, "input");
            const input_json = try rpc.stringifyJsonValue(self.allocator, input_val);
            errdefer self.allocator.free(input_json);
            try self.pending.append(self.allocator, .{
                .kind = .{ .tool_started = .{
                    .id = try self.allocator.dupe(u8, cid),
                    .name = try self.allocator.dupe(u8, title),
                    .input_json = input_json,
                } },
                .raw = try self.allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const status = rpc.jsonStr(rpc.jsonObjGet(update, "status")) orelse "";
            if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed")) {
                const cid = rpc.jsonStr(rpc.jsonObjGet(update, "toolCallId")) orelse "";
                const out_val = rpc.jsonObjGet(update, "rawOutput") orelse
                    rpc.jsonObjGet(update, "content") orelse
                    rpc.jsonObjGet(update, "output");
                const out = try rpc.extractTextOrJson(self.allocator, out_val);
                errdefer self.allocator.free(out);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_finished = .{
                        .id = try self.allocator.dupe(u8, cid),
                        .output = out,
                        .is_error = std.mem.eql(u8, status, "failed"),
                    } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, kind, "usage_update")) {
            const input_tokens = rpc.jsonU64(rpc.jsonObjGet(update, "inputTokens")) orelse 0;
            const output_tokens = rpc.jsonU64(rpc.jsonObjGet(update, "outputTokens")) orelse 0;
            try self.pending.append(self.allocator, .{
                .kind = .{ .usage = .{ .input_tokens = input_tokens, .output_tokens = output_tokens } },
                .raw = try self.allocator.dupe(u8, line),
            });
        }
    }

    fn replyPermission(self: *AcpRun, id_val: std.json.Value, params: ?std.json.Value) !void {
        var chosen: []const u8 = switch (self.access) {
            .plan => "reject_once",
            .accept_edits, .full => "allow_once",
        };
        if (rpc.jsonObjGet(params, "options")) |opts_val| {
            if (opts_val == .array) {
                for (opts_val.array.items) |opt| {
                    const kind = rpc.jsonStr(rpc.jsonObjGet(opt, "kind")) orelse "";
                    const oid = rpc.jsonStr(rpc.jsonObjGet(opt, "optionId")) orelse continue;
                    const want_allow = self.access != .plan;
                    if (want_allow and (std.mem.eql(u8, kind, "allow_always") or std.mem.eql(u8, kind, "allow_once"))) {
                        chosen = oid;
                        break;
                    }
                    if (!want_allow and (std.mem.eql(u8, kind, "reject_once") or std.mem.eql(u8, kind, "reject_always"))) {
                        chosen = oid;
                        break;
                    }
                }
            }
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try rpc.appendJsonValue(self.allocator, &buf, id_val);
        try buf.appendSlice(self.allocator, ",\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, chosen);
        try buf.appendSlice(self.allocator, "}}}");
        self.pipe.writeLine(buf.items) catch {};
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
        if (self.session_id) |sid| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":") catch return;
            rpc.appendJsonEscaped(self.allocator, &buf, sid) catch return;
            buf.appendSlice(self.allocator, "}}") catch return;
            self.pipe.writeLine(buf.items) catch {};
        }
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
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
        .native_steer = false,
    };
}
