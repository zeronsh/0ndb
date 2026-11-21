const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

const REQUEST_TIMEOUT_MS: u64 = 120_000;
const STEER_TIMEOUT_MS: u64 = 10_000;

fn sandboxForAccess(access: iface.AccessMode) []const u8 {
    return switch (access) {
        .plan => "read-only",
        .accept_edits => "workspace-write",
        .full => "danger-full-access",
    };
}

fn approvalPolicyForAccess(access: iface.AccessMode) []const u8 {
    return switch (access) {
        .plan => "on-request",
        .accept_edits => "on-request",
        .full => "never",
    };
}

pub fn approvalDecisionJson(access: iface.AccessMode, method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "item/fileChange/requestApproval") or
        std.mem.eql(u8, method, "applyPatchApproval"))
    {
        return switch (access) {
            .plan => "{\"decision\":\"decline\"}",
            .accept_edits, .full => "{\"decision\":\"accept\"}",
        };
    }
    if (std.mem.eql(u8, method, "item/commandExecution/requestApproval") or
        std.mem.eql(u8, method, "execCommandApproval"))
    {
        return switch (access) {
            .full => "{\"decision\":\"accept\"}",
            .plan, .accept_edits => "{\"decision\":\"decline\"}",
        };
    }
    return "{\"decision\":\"decline\"}";
}

pub const CodexRun = struct {
    allocator: Allocator,
    io: Io,
    pipe: rpc.SubprocessPipe,
    next_id: std.atomic.Value(u64),
    state_mu: Io.Mutex,
    access: iface.AccessMode,
    thread_id: ?[]u8,
    active_turn_id: ?[]u8,
    pending_turn_req_id: ?u64,
    turn_in_flight: bool,
    emitted_eof_error: bool,
    pending: std.ArrayList(iface.Event),
    closed: bool,

    pub fn start(allocator: Allocator, io: Io, req: iface.StartRequest) !iface.RunHandle {
        const argv = [_][]const u8{ "codex", "app-server" };
        const self = try allocator.create(CodexRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, &argv, req.cwd),
            .next_id = .init(1),
            .state_mu = .init,
            .access = req.access,
            .thread_id = null,
            .active_turn_id = null,
            .pending_turn_req_id = null,
            .turn_in_flight = false,
            .emitted_eof_error = false,
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
        self.state_mu.lockUncancelable(self.io);
        const tid = self.thread_id;
        self.thread_id = null;
        const turn_id = self.active_turn_id;
        self.active_turn_id = null;
        self.state_mu.unlock(self.io);
        if (tid) |t| self.allocator.free(t);
        if (turn_id) |t| self.allocator.free(t);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *CodexRun) u64 {
        return self.next_id.fetchAdd(1, .monotonic);
    }

    fn setActiveTurnId(self: *CodexRun, new_id: ?[]const u8) !void {
        const duped: ?[]u8 = if (new_id) |s| try self.allocator.dupe(u8, s) else null;
        self.state_mu.lockUncancelable(self.io);
        const old = self.active_turn_id;
        self.active_turn_id = duped;
        self.state_mu.unlock(self.io);
        if (old) |o| self.allocator.free(o);
    }

    fn copyActiveTurnId(self: *CodexRun, allocator: Allocator) !?[]u8 {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        if (self.active_turn_id) |t| return try allocator.dupe(u8, t);
        return null;
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
        const resp = try self.waitResponseTimeout(init_id, REQUEST_TIMEOUT_MS);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.InitializeFailed;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return error.InitializeFailed;
        try self.pipe.writeLine("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    }

    fn appendPolicyFields(self: *CodexRun, buf: *std.ArrayList(u8), access: iface.AccessMode) !void {
        try buf.appendSlice(self.allocator, ",\"sandbox\":\"");
        try buf.appendSlice(self.allocator, sandboxForAccess(access));
        try buf.appendSlice(self.allocator, "\",\"approvalPolicy\":\"");
        try buf.appendSlice(self.allocator, approvalPolicyForAccess(access));
        try buf.append(self.allocator, '"');
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
            try self.appendPolicyFields(&buf, req.access);
            try buf.appendSlice(self.allocator, "}}");
        } else {
            try buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"thread/start\",\"params\":{{\"cwd\":", .{req_id});
            try rpc.appendJsonEscaped(self.allocator, &buf, req.cwd);
            if (req.model) |m| {
                try buf.appendSlice(self.allocator, ",\"model\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, m);
            }
            try self.appendPolicyFields(&buf, req.access);
            try buf.appendSlice(self.allocator, "}}");
        }

        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponseTimeout(req_id, REQUEST_TIMEOUT_MS);
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
        const tid_copy = try self.allocator.dupe(u8, tid);
        self.state_mu.lockUncancelable(self.io);
        const old_tid = self.thread_id;
        self.thread_id = tid_copy;
        self.state_mu.unlock(self.io);
        if (old_tid) |o| self.allocator.free(o);
        try self.pending.append(self.allocator, .{
            .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, tid) } },
        });
    }

    fn waitResponseTimeout(self: *CodexRun, expected_id: u64, timeout_ms: u64) ![]u8 {
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
            self.handleNotification(line.bytes) catch {};
        }
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const tid_opt = if (self.thread_id) |t| try self.allocator.dupe(u8, t) else null;
        self.state_mu.unlock(self.io);
        const tid = tid_opt orelse return error.NoSession;
        defer self.allocator.free(tid);

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
        self.turn_in_flight = true;
        self.emitted_eof_error = false;
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, expected_turn: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const tid_opt = if (self.thread_id) |t| try self.allocator.dupe(u8, t) else null;
        const active_opt = if (expected_turn == null and self.active_turn_id != null)
            try self.allocator.dupe(u8, self.active_turn_id.?)
        else
            null;
        self.state_mu.unlock(self.io);
        defer if (tid_opt) |t| self.allocator.free(t);
        defer if (active_opt) |a| self.allocator.free(a);

        const tid = tid_opt orelse return .requires_interrupt_fallback;
        const turn_id = expected_turn orelse active_opt orelse return .requires_interrupt_fallback;

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

        const resp = self.waitResponseTimeout(req_id, STEER_TIMEOUT_MS) catch return .requires_interrupt_fallback;
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return .requires_interrupt_fallback;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return .requires_interrupt_fallback;
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        while (true) {
            if (self.pending.items.len > 0) {
                const ev = self.pending.orderedRemove(0);
                if (ev.kind == .turn_ended) self.turn_in_flight = false;
                return ev;
            }
            var raw_line = try self.pipe.readNextLine(-1) orelse {
                if (self.turn_in_flight and !self.emitted_eof_error) {
                    self.turn_in_flight = false;
                    self.emitted_eof_error = true;
                    const msg = try self.pipe.formatCrashMessage(self.allocator, "codex");
                    return .{ .kind = .{ .turn_ended = .{ .ok = false, .err_msg = msg } } };
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
            try self.handleNotification(raw_line.bytes);
        }
    }

    fn appendUsageIfPresent(self: *CodexRun, usage_val: ?std.json.Value, line: []const u8) !void {
        const u = usage_val orelse return;
        if (u != .object) return;
        const in_tok = rpc.jsonU64(rpc.jsonObjGet(u, "inputTokens")) orelse
            rpc.jsonU64(rpc.jsonObjGet(u, "input_tokens")) orelse 0;
        const out_tok = rpc.jsonU64(rpc.jsonObjGet(u, "outputTokens")) orelse
            rpc.jsonU64(rpc.jsonObjGet(u, "output_tokens")) orelse 0;
        const cost = rpc.jsonF64(rpc.jsonObjGet(u, "costUsd")) orelse
            rpc.jsonF64(rpc.jsonObjGet(u, "cost_usd"));
        if (in_tok > 0 or out_tok > 0 or cost != null) {
            try self.pending.append(self.allocator, .{
                .kind = .{ .usage = .{
                    .input_tokens = in_tok,
                    .output_tokens = out_tok,
                    .cost_usd = cost,
                } },
                .raw = try self.allocator.dupe(u8, line),
            });
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
                const decision = approvalDecisionJson(self.access, method);
                try rpc.replyResultJson(self.allocator, &self.pipe, id_val, decision);
                return;
            }
            try rpc.replyMethodNotFound(self.allocator, &self.pipe, id_val, method);
            return;
        }

        if (std.mem.eql(u8, method, "turn/started")) {
            const turn = rpc.jsonObjGet(params, "turn");
            if (rpc.jsonStr(rpc.jsonObjGet(turn, "id"))) |tid| {
                try self.setActiveTurnId(tid);
                const tid_c = try self.allocator.dupe(u8, tid);
                errdefer self.allocator.free(tid_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .turn_started = .{ .native_turn_id = tid_c } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
            if (rpc.jsonStr(rpc.jsonObjGet(params, "delta"))) |d| {
                const d_c = try self.allocator.dupe(u8, d);
                errdefer self.allocator.free(d_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .text_delta = .{ .text = d_c } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, method, "item/reasoning/textDelta") or std.mem.eql(u8, method, "item/reasoning/summaryTextDelta")) {
            if (rpc.jsonStr(rpc.jsonObjGet(params, "delta"))) |d| {
                const d_c = try self.allocator.dupe(u8, d);
                errdefer self.allocator.free(d_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .reasoning_delta = .{ .text = d_c } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, method, "thread/tokenUsage/updated")) {
            const tu = rpc.jsonObjGet(params, "tokenUsage");
            const u = rpc.jsonObjGet(tu, "last") orelse
                rpc.jsonObjGet(tu, "total") orelse
                rpc.jsonObjGet(params, "usage");
            try self.appendUsageIfPresent(u, line);
        } else if (std.mem.eql(u8, method, "item/started")) {
            const item = rpc.jsonObjGet(params, "item");
            const itype = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, itype, "commandExecution") or
                std.mem.eql(u8, itype, "fileChange") or
                std.mem.eql(u8, itype, "mcpToolCall") or
                std.mem.eql(u8, itype, "webSearch") or
                std.mem.eql(u8, itype, "web_search"))
            {
                const name = rpc.jsonStr(rpc.jsonObjGet(item, "tool")) orelse
                    rpc.jsonStr(rpc.jsonObjGet(item, "name")) orelse itype;
                const input_val = rpc.jsonObjGet(item, "arguments") orelse
                    rpc.jsonObjGet(item, "input") orelse
                    rpc.jsonObjGet(item, "command") orelse
                    rpc.jsonObjGet(item, "query") orelse
                    rpc.jsonObjGet(item, "changes") orelse item;
                const iid_c = try self.allocator.dupe(u8, iid);
                errdefer self.allocator.free(iid_c);
                const name_c = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(name_c);
                const input_json = try rpc.stringifyJsonValue(self.allocator, input_val);
                errdefer self.allocator.free(input_json);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_started = .{
                        .id = iid_c,
                        .name = name_c,
                        .input_json = input_json,
                    } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, method, "item/completed")) {
            const item = rpc.jsonObjGet(params, "item");
            const itype = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, itype, "agentMessage")) {
                if (rpc.jsonStr(rpc.jsonObjGet(item, "text"))) |t| {
                    const t_c = try self.allocator.dupe(u8, t);
                    errdefer self.allocator.free(t_c);
                    const raw_c = try self.allocator.dupe(u8, line);
                    errdefer self.allocator.free(raw_c);
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text = .{ .text = t_c } },
                        .raw = raw_c,
                    });
                }
            } else if (std.mem.eql(u8, itype, "reasoning")) {
                if (rpc.jsonStr(rpc.jsonObjGet(item, "text"))) |t| {
                    const t_c = try self.allocator.dupe(u8, t);
                    errdefer self.allocator.free(t_c);
                    const raw_c = try self.allocator.dupe(u8, line);
                    errdefer self.allocator.free(raw_c);
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning = .{ .text = t_c } },
                        .raw = raw_c,
                    });
                }
            } else if (std.mem.eql(u8, itype, "commandExecution") or
                std.mem.eql(u8, itype, "fileChange") or
                std.mem.eql(u8, itype, "mcpToolCall") or
                std.mem.eql(u8, itype, "webSearch") or
                std.mem.eql(u8, itype, "web_search"))
            {
                const out_val = rpc.jsonObjGet(item, "aggregatedOutput") orelse
                    rpc.jsonObjGet(item, "output") orelse
                    rpc.jsonObjGet(item, "result") orelse
                    rpc.jsonObjGet(item, "results") orelse
                    rpc.jsonObjGet(item, "error") orelse
                    rpc.jsonObjGet(item, "changes") orelse
                    rpc.jsonObjGet(item, "action");
                const iid_c = try self.allocator.dupe(u8, iid);
                errdefer self.allocator.free(iid_c);
                const output = try rpc.extractTextOrJson(self.allocator, out_val);
                errdefer self.allocator.free(output);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                const status = rpc.jsonStr(rpc.jsonObjGet(item, "status")) orelse "";
                const exit_code = rpc.jsonI64(rpc.jsonObjGet(item, "exitCode")) orelse
                    rpc.jsonI64(rpc.jsonObjGet(item, "exit_code"));
                const is_err = std.mem.eql(u8, status, "failed") or (exit_code != null and exit_code.? != 0);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_finished = .{
                        .id = iid_c,
                        .output = output,
                        .is_error = is_err,
                    } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, method, "turn/completed")) {
            const turn = rpc.jsonObjGet(params, "turn");
            const usage_val = rpc.jsonObjGet(turn, "usage") orelse rpc.jsonObjGet(params, "usage");
            try self.appendUsageIfPresent(usage_val, line);

            const status = rpc.jsonStr(rpc.jsonObjGet(turn, "status")) orelse "completed";
            const ok = std.mem.eql(u8, status, "completed");
            const turn_err = rpc.jsonObjGet(turn, "error") orelse rpc.jsonObjGet(params, "error");
            const err_text = rpc.jsonStr(rpc.jsonObjGet(turn_err, "message")) orelse
                rpc.jsonStr(turn_err) orelse status;
            const err_msg: ?[]u8 = if (!ok) try self.allocator.dupe(u8, err_text) else null;
            errdefer if (err_msg) |m| self.allocator.free(m);
            try self.setActiveTurnId(null);
            self.pending_turn_req_id = null;
            const raw_c = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(raw_c);
            try self.pending.append(self.allocator, .{
                .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } },
                .raw = raw_c,
            });
        }
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *CodexRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const tid_copy = if (self.thread_id) |t| (self.allocator.dupe(u8, t) catch null) else null;
        const turn_copy = if (self.active_turn_id) |t| (self.allocator.dupe(u8, t) catch null) else null;
        self.state_mu.unlock(self.io);
        defer if (tid_copy) |t| self.allocator.free(t);
        defer if (turn_copy) |t| self.allocator.free(t);

        if (tid_copy) |tid| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            const req_id = self.allocId();
            buf.print(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/interrupt\",\"params\":{{\"threadId\":", .{req_id}) catch return;
            rpc.appendJsonEscaped(self.allocator, &buf, tid) catch return;
            if (turn_copy) |turn_id| {
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
