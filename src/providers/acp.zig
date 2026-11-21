const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

const REQUEST_TIMEOUT_MS: u64 = 120_000;

pub const AcpProfile = struct {
    provider: iface.ProviderId,
    argv: []const []const u8,
};

pub const ANTIGRAVITY_PROFILE = AcpProfile{
    .provider = .antigravity,
    .argv = &.{"agy_acp_server"},
};

pub const GROK_PROFILE = AcpProfile{
    .provider = .grok,
    .argv = &.{ "grok", "agent", "stdio" },
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

pub fn formatPermissionOutcome(
    allocator: Allocator,
    access: iface.AccessMode,
    params: ?std.json.Value,
) Allocator.Error![]u8 {
    const prefer: []const []const u8 = switch (access) {
        .plan => &.{ "reject_once", "reject_always" },
        .accept_edits, .full => &.{ "allow_always", "allow_once" },
    };
    var chosen: ?[]const u8 = null;
    if (rpc.jsonObjGet(params, "options")) |opts_val| {
        if (opts_val == .array) {
            outer: for (prefer) |want_kind| {
                for (opts_val.array.items) |opt| {
                    const kind = rpc.jsonStr(rpc.jsonObjGet(opt, "kind")) orelse "";
                    const oid = rpc.jsonStr(rpc.jsonObjGet(opt, "optionId")) orelse continue;
                    if (std.mem.eql(u8, kind, want_kind)) {
                        chosen = oid;
                        break :outer;
                    }
                }
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (chosen) |oid| {
        try out.appendSlice(allocator, "{\"outcome\":\"selected\",\"optionId\":");
        try rpc.appendJsonEscaped(allocator, &out, oid);
        try out.append(allocator, '}');
    } else {
        try out.appendSlice(allocator, "{\"outcome\":\"cancelled\"}");
    }
    return try out.toOwnedSlice(allocator);
}

pub const AcpRun = struct {
    allocator: Allocator,
    io: Io,
    pipe: rpc.SubprocessPipe,
    next_id: std.atomic.Value(u64),
    state_mu: Io.Mutex,
    session_id: ?[]u8,
    prompt_req_id: ?u64,
    access: iface.AccessMode,
    supports_native_steer: bool,
    supports_load_session: bool,
    supports_resume_session: bool,
    quiet: bool,
    emitted_eof_error: bool,
    model_config_id: ?[]u8,
    text_buf: std.ArrayList(u8),
    thought_buf: std.ArrayList(u8),
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
            .next_id = .init(1),
            .state_mu = .init,
            .session_id = null,
            .prompt_req_id = null,
            .access = req.access,
            .supports_native_steer = false,
            .supports_load_session = false,
            .supports_resume_session = false,
            .quiet = false,
            .emitted_eof_error = false,
            .model_config_id = null,
            .text_buf = .empty,
            .thought_buf = .empty,
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
        self.state_mu.lockUncancelable(self.io);
        const sid = self.session_id;
        self.session_id = null;
        self.state_mu.unlock(self.io);
        if (sid) |s| self.allocator.free(s);
        if (self.model_config_id) |c| self.allocator.free(c);
        self.text_buf.deinit(self.allocator);
        self.thought_buf.deinit(self.allocator);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *AcpRun) u64 {
        return self.next_id.fetchAdd(1, .monotonic);
    }

    fn flushBuffered(self: *AcpRun) !void {
        if (self.thought_buf.items.len > 0) {
            const txt = try self.thought_buf.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(txt);
            try self.pending.append(self.allocator, .{
                .kind = .{ .reasoning = .{ .text = txt } },
            });
        }
        if (self.text_buf.items.len > 0) {
            const txt = try self.text_buf.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(txt);
            try self.pending.append(self.allocator, .{
                .kind = .{ .text = .{ .text = txt } },
            });
        }
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
        const resp = try self.waitResponseTimeout(req_id, REQUEST_TIMEOUT_MS);
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

        const is_resume = req.resume_id != null;
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

        if (is_resume) self.quiet = true;
        defer self.quiet = false;

        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponseTimeout(req_id, REQUEST_TIMEOUT_MS);
        defer self.allocator.free(resp);

        self.text_buf.clearRetainingCapacity();
        self.thought_buf.clearRetainingCapacity();
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.clearRetainingCapacity();

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) {
            return if (is_resume) error.ResumeFailed else error.SessionStartFailed;
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
            return if (is_resume) error.ResumeFailed else error.SessionStartFailed;
        }
        const sid_copy = try self.allocator.dupe(u8, sid);
        self.state_mu.lockUncancelable(self.io);
        const old_sid = self.session_id;
        self.session_id = sid_copy;
        self.state_mu.unlock(self.io);
        if (old_sid) |o| self.allocator.free(o);
        try self.pending.append(self.allocator, .{
            .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, sid) } },
        });
    }

    fn setModel(self: *AcpRun, model: []const u8) !void {
        self.state_mu.lockUncancelable(self.io);
        const sid_opt = if (self.session_id) |s| try self.allocator.dupe(u8, s) else null;
        self.state_mu.unlock(self.io);
        const sid = sid_opt orelse return;
        defer self.allocator.free(sid);

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
        const resp = try self.waitResponseTimeout(req_id, REQUEST_TIMEOUT_MS);
        self.allocator.free(resp);
    }

    fn waitResponseTimeout(self: *AcpRun, expected_id: u64, timeout_ms: u64) ![]u8 {
        const deadline = rpc.monotonicMs(self.io) +| timeout_ms;
        while (true) {
            var line = try self.pipe.readLineDeadline(deadline) orelse return error.ProcessExited;
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
        self.state_mu.lockUncancelable(self.io);
        const sid_opt = if (self.session_id) |s| try self.allocator.dupe(u8, s) else null;
        self.state_mu.unlock(self.io);
        const sid = sid_opt orelse return error.NoSession;
        defer self.allocator.free(sid);

        self.text_buf.clearRetainingCapacity();
        self.thought_buf.clearRetainingCapacity();
        self.emitted_eof_error = false;
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
        self.state_mu.lockUncancelable(self.io);
        const sid_opt = if (self.session_id) |s| try self.allocator.dupe(u8, s) else null;
        self.state_mu.unlock(self.io);
        const sid = sid_opt orelse return .requires_interrupt_fallback;
        defer self.allocator.free(sid);

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
        const resp = self.waitResponseTimeout(req_id, 10_000) catch return .requires_interrupt_fallback;
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return .requires_interrupt_fallback;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return .requires_interrupt_fallback;
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
        while (true) {
            if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
            var raw_line = try self.pipe.readNextLine(-1) orelse {
                if (self.prompt_req_id != null and !self.emitted_eof_error) {
                    self.prompt_req_id = null;
                    self.emitted_eof_error = true;
                    try self.flushBuffered();
                    const msg = try self.pipe.formatCrashMessage(self.allocator, "acp");
                    errdefer self.allocator.free(msg);
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .turn_ended = .{ .ok = false, .err_msg = msg } },
                    });
                    if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
                }
                return null;
            };
            defer raw_line.deinit(self.allocator);
            if (raw_line.is_stderr) {
                const kind_s = try self.allocator.dupe(u8, "stderr");
                errdefer self.allocator.free(kind_s);
                const raw_s = try self.allocator.dupe(u8, raw_line.bytes);
                return .{
                    .kind = .{ .other = .{ .kind = kind_s } },
                    .raw = raw_s,
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
                if (!self.quiet) {
                    try self.handleSessionUpdate(params, line);
                }
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
                    try self.flushBuffered();
                    if (rpc.jsonObjGet(root, "error")) |err_obj| {
                        const msg = rpc.jsonStr(rpc.jsonObjGet(err_obj, "message")) orelse "acp prompt error";
                        const msg_c = try self.allocator.dupe(u8, msg);
                        errdefer self.allocator.free(msg_c);
                        const raw_c = try self.allocator.dupe(u8, line);
                        errdefer self.allocator.free(raw_c);
                        try self.pending.append(self.allocator, .{
                            .kind = .{ .turn_ended = .{
                                .ok = false,
                                .err_msg = msg_c,
                            } },
                            .raw = raw_c,
                        });
                    } else {
                        const stop_reason = rpc.jsonStr(rpc.jsonObjGet(rpc.jsonObjGet(root, "result"), "stopReason")) orelse "end_turn";
                        const ok = !std.mem.eql(u8, stop_reason, "cancelled") and
                            !std.mem.eql(u8, stop_reason, "error") and
                            !std.mem.eql(u8, stop_reason, "refusal");
                        const err_msg: ?[]u8 = if (!ok) try self.allocator.dupe(u8, stop_reason) else null;
                        errdefer if (err_msg) |m| self.allocator.free(m);
                        const raw_c = try self.allocator.dupe(u8, line);
                        errdefer self.allocator.free(raw_c);
                        try self.pending.append(self.allocator, .{
                            .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } },
                            .raw = raw_c,
                        });
                    }
                }
            }
        }
    }

    fn emitToolFinished(self: *AcpRun, cid: []const u8, update: ?std.json.Value, status: []const u8, line: []const u8) !void {
        const out_val = rpc.jsonObjGet(update, "rawOutput") orelse
            rpc.jsonObjGet(update, "content") orelse
            rpc.jsonObjGet(update, "output");
        const cid_c = try self.allocator.dupe(u8, cid);
        errdefer self.allocator.free(cid_c);
        const out = try rpc.extractTextOrJson(self.allocator, out_val);
        errdefer self.allocator.free(out);
        const raw_c = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(raw_c);
        try self.pending.append(self.allocator, .{
            .kind = .{ .tool_finished = .{
                .id = cid_c,
                .output = out,
                .is_error = std.mem.eql(u8, status, "failed"),
            } },
            .raw = raw_c,
        });
    }

    fn handleSessionUpdate(self: *AcpRun, params: ?std.json.Value, line: []const u8) !void {
        const update = rpc.jsonObjGet(params, "update") orelse params;
        const kind = rpc.jsonStr(rpc.jsonObjGet(update, "sessionUpdate")) orelse "";

        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            const content = rpc.jsonObjGet(update, "content");
            const text = rpc.jsonStr(rpc.jsonObjGet(content, "text")) orelse
                rpc.jsonStr(rpc.jsonObjGet(update, "text")) orelse "";
            if (text.len > 0) {
                try self.text_buf.appendSlice(self.allocator, text);
                const t_c = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(t_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .text_delta = .{ .text = t_c } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
            const content = rpc.jsonObjGet(update, "content");
            const text = rpc.jsonStr(rpc.jsonObjGet(content, "text")) orelse
                rpc.jsonStr(rpc.jsonObjGet(update, "text")) orelse "";
            if (text.len > 0) {
                try self.thought_buf.appendSlice(self.allocator, text);
                const t_c = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(t_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .reasoning_delta = .{ .text = t_c } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            try self.flushBuffered();
            const cid = rpc.jsonStr(rpc.jsonObjGet(update, "toolCallId")) orelse "";
            const title = rpc.jsonStr(rpc.jsonObjGet(update, "title")) orelse "tool";
            const input_val = rpc.jsonObjGet(update, "rawInput") orelse rpc.jsonObjGet(update, "input");
            const cid_c = try self.allocator.dupe(u8, cid);
            errdefer self.allocator.free(cid_c);
            const title_c = try self.allocator.dupe(u8, title);
            errdefer self.allocator.free(title_c);
            const input_json = try rpc.stringifyJsonValue(self.allocator, input_val);
            errdefer self.allocator.free(input_json);
            const raw_c = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(raw_c);
            try self.pending.append(self.allocator, .{
                .kind = .{ .tool_started = .{
                    .id = cid_c,
                    .name = title_c,
                    .input_json = input_json,
                } },
                .raw = raw_c,
            });
            const status = rpc.jsonStr(rpc.jsonObjGet(update, "status")) orelse "";
            if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed")) {
                try self.emitToolFinished(cid, update, status, line);
            }
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const status = rpc.jsonStr(rpc.jsonObjGet(update, "status")) orelse "";
            if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed")) {
                const cid = rpc.jsonStr(rpc.jsonObjGet(update, "toolCallId")) orelse "";
                try self.emitToolFinished(cid, update, status, line);
            }
        } else if (std.mem.eql(u8, kind, "usage_update")) {
            const input_tokens = rpc.jsonU64(rpc.jsonObjGet(update, "inputTokens")) orelse 0;
            const output_tokens = rpc.jsonU64(rpc.jsonObjGet(update, "outputTokens")) orelse 0;
            const cost = rpc.jsonF64(rpc.jsonObjGet(update, "costUsd")) orelse
                rpc.jsonF64(rpc.jsonObjGet(update, "cost_usd"));
            try self.pending.append(self.allocator, .{
                .kind = .{ .usage = .{
                    .input_tokens = input_tokens,
                    .output_tokens = output_tokens,
                    .cost_usd = cost,
                } },
                .raw = try self.allocator.dupe(u8, line),
            });
        }
    }

    fn replyPermission(self: *AcpRun, id_val: std.json.Value, params: ?std.json.Value) !void {
        const outcome_json = try formatPermissionOutcome(self.allocator, self.access, params);
        defer self.allocator.free(outcome_json);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try rpc.appendJsonValue(self.allocator, &buf, id_val);
        try buf.appendSlice(self.allocator, ",\"result\":{\"outcome\":");
        try buf.appendSlice(self.allocator, outcome_json);
        try buf.appendSlice(self.allocator, "}}");
        self.pipe.writeLine(buf.items) catch {};
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *AcpRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const sid_copy = if (self.session_id) |s| (self.allocator.dupe(u8, s) catch null) else null;
        self.state_mu.unlock(self.io);
        defer if (sid_copy) |s| self.allocator.free(s);

        if (sid_copy) |sid| {
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
