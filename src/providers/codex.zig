const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

pub const CodexRun = struct {
    allocator: Allocator,
    pipe: rpc.SubprocessPipe,
    next_id: u64,
    access: iface.AccessMode,
    thread_id: ?[]u8,
    active_turn_id: ?[]u8,
    pending_turn_req_id: ?u64,
    pending: std.ArrayList(iface.Event),
    closed: bool,

    pub fn start(allocator: Allocator, io: Io, req: iface.StartRequest) !iface.RunHandle {
        const argv = [_][]const u8{ "codex", "app-server" };
        const self = try allocator.create(CodexRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, &argv, req.cwd),
            .next_id = 1,
            .access = req.access,
            .thread_id = null,
            .active_turn_id = null,
            .pending_turn_req_id = null,
            .pending = .empty,
            .closed = false,
        };
        errdefer self.cleanup();

        try self.initialize();
        try self.openThread(req);
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn cleanup(self: *CodexRun) void {
        if (self.thread_id) |t| self.allocator.free(t);
        if (self.active_turn_id) |t| self.allocator.free(t);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *CodexRun) u64 {
        const i = self.next_id;
        self.next_id += 1;
        return i;
    }

    fn initialize(self: *CodexRun) !void {
        const init_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"clientInfo\":{{\"name\":\"0ndb\",\"version\":\"0.2.0\"}}}}}}",
            .{init_id},
        );
        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(init_id);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.InitializeFailed;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return error.InitializeFailed;
        try self.pipe.writeLine("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    }

    fn openThread(self: *CodexRun, req: iface.StartRequest) !void {
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        if (req.resume_id) |rid| {
            const method = if (req.fork_at != null) "thread/fork" else "thread/resume";
            try buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"threadId\":", .{ req_id, method });
            try rpc.appendJsonEscaped(self.allocator, &buf, rid);
            try buf.appendSlice(self.allocator, ",\"cwd\":");
            try rpc.appendJsonEscaped(self.allocator, &buf, req.cwd);
            if (req.model) |m| {
                try buf.appendSlice(self.allocator, ",\"model\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, m);
            }
            try buf.appendSlice(self.allocator, "}}");
        } else {
            try buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"thread/start\",\"params\":{{\"cwd\":", .{req_id});
            try rpc.appendJsonEscaped(self.allocator, &buf, req.cwd);
            if (req.model) |m| {
                try buf.appendSlice(self.allocator, ",\"model\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, m);
            }
            const sandbox = switch (req.access) {
                .plan => "read-only",
                .accept_edits => "workspace-write",
                .full => "danger-full-access",
            };
            try buf.appendSlice(self.allocator, ",\"sandbox\":\"");
            try buf.appendSlice(self.allocator, sandbox);
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
        const thread_obj = rpc.jsonObjGet(result, "thread");
        const tid = rpc.jsonStr(rpc.jsonObjGet(thread_obj, "id")) orelse
            rpc.jsonStr(rpc.jsonObjGet(result, "threadId")) orelse
            (req.resume_id orelse "");
        if (tid.len == 0) {
            return if (req.resume_id != null) error.ResumeFailed else error.SessionStartFailed;
        }
        self.thread_id = try self.allocator.dupe(u8, tid);
        try self.pending.append(self.allocator, .{
            .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, tid) } },
        });
    }

    fn waitResponse(self: *CodexRun, expected_id: u64) ![]u8 {
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
                self.handleNotification(line.bytes) catch {};
            }
        }
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        const tid = self.thread_id orelse return error.NoSession;
        const req_id = self.allocId();
        self.pending_turn_req_id = req_id;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/start\",\"params\":{{\"threadId\":", .{req_id});
        try rpc.appendJsonEscaped(self.allocator, &buf, tid);
        try buf.appendSlice(self.allocator, ",\"input\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(buf.items);
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, expected_turn: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        const tid = self.thread_id orelse return .requires_interrupt_fallback;
        const turn_id = expected_turn orelse self.active_turn_id orelse return .requires_interrupt_fallback;
        const req_id = self.allocId();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/steer\",\"params\":{{\"threadId\":", .{req_id});
        try rpc.appendJsonEscaped(self.allocator, &buf, tid);
        try buf.appendSlice(self.allocator, ",\"expectedTurnId\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, turn_id);
        try buf.appendSlice(self.allocator, ",\"input\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(buf.items);
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
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
            try self.handleNotification(raw_line.bytes);
        }
    }

    fn handleNotification(self: *CodexRun, line: []const u8) !void {
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
                            const msg = rpc.jsonStr(rpc.jsonObjGet(err_obj, "message")) orelse "codex turn error";
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

        if (rpc.jsonObjGet(root, "id")) |id_val| {
            if (std.mem.eql(u8, method, "item/commandExecution/requestApproval") or
                std.mem.eql(u8, method, "item/fileChange/requestApproval") or
                std.mem.eql(u8, method, "execCommandApproval") or
                std.mem.eql(u8, method, "applyPatchApproval"))
            {
                const decision = if (self.access == .plan) "{\"decision\":\"decline\"}" else "{\"decision\":\"accept\"}";
                try rpc.replyResultJson(self.allocator, &self.pipe, id_val, decision);
                return;
            }
            try rpc.replyMethodNotFound(self.allocator, &self.pipe, id_val, method);
            return;
        }

        if (std.mem.eql(u8, method, "turn/started")) {
            const turn = rpc.jsonObjGet(params, "turn");
            if (rpc.jsonStr(rpc.jsonObjGet(turn, "id"))) |tid| {
                if (self.active_turn_id) |old| self.allocator.free(old);
                self.active_turn_id = try self.allocator.dupe(u8, tid);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .turn_started = .{ .native_turn_id = try self.allocator.dupe(u8, tid) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
            if (rpc.jsonStr(rpc.jsonObjGet(params, "delta"))) |d| {
                try self.pending.append(self.allocator, .{
                    .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, d) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "item/reasoning/textDelta") or std.mem.eql(u8, method, "item/reasoning/summaryTextDelta")) {
            if (rpc.jsonStr(rpc.jsonObjGet(params, "delta"))) |d| {
                try self.pending.append(self.allocator, .{
                    .kind = .{ .reasoning_delta = .{ .text = try self.allocator.dupe(u8, d) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "item/started")) {
            const item = rpc.jsonObjGet(params, "item");
            const itype = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, itype, "commandExecution") or std.mem.eql(u8, itype, "fileChange") or std.mem.eql(u8, itype, "mcpToolCall")) {
                const name = rpc.jsonStr(rpc.jsonObjGet(item, "tool")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(item, "name")) orelse itype;
                const input_val = rpc.jsonObjGet(item, "arguments") orelse
                    rpc.jsonObjGet(item, "input") orelse
                    rpc.jsonObjGet(item, "command") orelse
                    rpc.jsonObjGet(item, "changes") orelse item;
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
            const itype = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, itype, "agentMessage")) {
                if (rpc.jsonStr(rpc.jsonObjGet(item, "text"))) |t| {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, t) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                }
            } else if (std.mem.eql(u8, itype, "reasoning")) {
                if (rpc.jsonStr(rpc.jsonObjGet(item, "text"))) |t| {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning = .{ .text = try self.allocator.dupe(u8, t) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                }
            } else if (std.mem.eql(u8, itype, "commandExecution") or std.mem.eql(u8, itype, "fileChange") or std.mem.eql(u8, itype, "mcpToolCall")) {
                const out_val = rpc.jsonObjGet(item, "aggregatedOutput") orelse
                    rpc.jsonObjGet(item, "output") orelse
                    rpc.jsonObjGet(item, "result") orelse
                    rpc.jsonObjGet(item, "error") orelse
                    rpc.jsonObjGet(item, "changes");
                const output = try rpc.extractTextOrJson(self.allocator, out_val);
                errdefer self.allocator.free(output);
                const status = rpc.jsonStr(rpc.jsonObjGet(item, "status")) orelse "";
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_finished = .{
                        .id = try self.allocator.dupe(u8, iid),
                        .output = output,
                        .is_error = std.mem.eql(u8, status, "failed"),
                    } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        } else if (std.mem.eql(u8, method, "turn/completed")) {
            const turn = rpc.jsonObjGet(params, "turn");
            const status = rpc.jsonStr(rpc.jsonObjGet(turn, "status")) orelse "completed";
            const ok = std.mem.eql(u8, status, "completed");
            const err_msg: ?[]u8 = if (!ok) try self.allocator.dupe(u8, status) else null;
            if (self.active_turn_id) |old| {
                self.allocator.free(old);
                self.active_turn_id = null;
            }
            self.pending_turn_req_id = null;
            try self.pending.append(self.allocator, .{
                .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } },
                .raw = try self.allocator.dupe(u8, line),
            });
        }
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        if (self.thread_id) |tid| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            const req_id = self.allocId();
            buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/interrupt\",\"params\":{{\"threadId\":", .{req_id}) catch return;
            rpc.appendJsonEscaped(self.allocator, &buf, tid) catch return;
            if (self.active_turn_id) |turn_id| {
                buf.appendSlice(self.allocator, ",\"turnId\":") catch return;
                rpc.appendJsonEscaped(self.allocator, &buf, turn_id) catch return;
            }
            buf.appendSlice(self.allocator, "}}") catch return;
            self.pipe.writeLine(buf.items) catch {};
        }
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
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
