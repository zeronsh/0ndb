const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const id = @import("../core/id.zig");
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

const REQUEST_TIMEOUT_MS: u64 = 120_000;
const STEER_TIMEOUT_MS: u64 = 10_000;

fn approvalModeForAccess(access: iface.AccessMode) []const u8 {
    return switch (access) {
        .plan => "denyUnmatched",
        .accept_edits => "onRequest",
        .full => "allowAll",
    };
}

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

fn isFileEditApproval(params: ?std.json.Value) bool {
    const keys = [_][]const u8{ "kind", "type", "tool", "category", "action", "method", "capability" };
    for (keys) |k| {
        if (rpc.jsonStr(rpc.jsonObjGet(params, k))) |val| {
            if (std.mem.eql(u8, val, "fileChange") or
                std.mem.eql(u8, val, "file_change") or
                std.mem.eql(u8, val, "applyPatch") or
                std.mem.eql(u8, val, "apply_patch") or
                std.mem.eql(u8, val, "fileEdit") or
                std.mem.eql(u8, val, "file_edit") or
                std.mem.eql(u8, val, "item/fileChange/requestApproval") or
                std.mem.eql(u8, val, "applyPatchApproval"))
            {
                return true;
            }
        }
    }
    return false;
}

pub fn approvalChoice(access: iface.AccessMode, params: ?std.json.Value) []const u8 {
    return switch (access) {
        .plan => "deny",
        .full => "approve",
        .accept_edits => if (isFileEditApproval(params)) "approve" else "deny",
    };
}

pub const MuseRun = struct {
    allocator: Allocator,
    io: Io,
    pipe: rpc.SubprocessPipe,
    next_id: std.atomic.Value(u64),
    state_mu: Io.Mutex,
    session_id: ?[]u8,
    active_turn_id: ?[]u8,
    pending_turn_req_id: ?u64,
    turn_in_flight: bool,
    emitted_eof_error: bool,
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
            .next_id = .init(1),
            .state_mu = .init,
            .session_id = null,
            .active_turn_id = null,
            .pending_turn_req_id = null,
            .turn_in_flight = false,
            .emitted_eof_error = false,
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
        self.state_mu.lockUncancelable(self.io);
        const sid = self.session_id;
        self.session_id = null;
        const turn_id = self.active_turn_id;
        self.active_turn_id = null;
        self.state_mu.unlock(self.io);
        if (sid) |s| self.allocator.free(s);
        if (turn_id) |t| self.allocator.free(t);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *MuseRun) u64 {
        return self.next_id.fetchAdd(1, .monotonic);
    }

    fn setActiveTurnId(self: *MuseRun, new_id: ?[]const u8) !void {
        const duped: ?[]u8 = if (new_id) |s| try self.allocator.dupe(u8, s) else null;
        self.state_mu.lockUncancelable(self.io);
        const old = self.active_turn_id;
        self.active_turn_id = duped;
        self.state_mu.unlock(self.io);
        if (old) |o| self.allocator.free(o);
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
        const resp = try self.waitResponseTimeout(req_id, REQUEST_TIMEOUT_MS);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.InitializeFailed;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return error.InitializeFailed;
        try self.pipe.writeLine("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    }

    fn appendPolicyFields(self: *MuseRun, buf: *std.ArrayList(u8), access: iface.AccessMode) !void {
        try buf.appendSlice(self.allocator, ",\"approvalMode\":\"");
        try buf.appendSlice(self.allocator, approvalModeForAccess(access));
        try buf.appendSlice(self.allocator, "\",\"sandbox\":\"");
        try buf.appendSlice(self.allocator, sandboxForAccess(access));
        try buf.appendSlice(self.allocator, "\",\"approvalPolicy\":\"");
        try buf.appendSlice(self.allocator, approvalPolicyForAccess(access));
        try buf.append(self.allocator, '"');
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
            try buf.appendSlice(self.allocator, ",\"excludeItems\":true");
            try self.appendPolicyFields(&buf, req.access);
            try buf.appendSlice(self.allocator, "}}");
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
        const sess = rpc.jsonObjGet(result, "session");
        const sid = rpc.jsonStr(rpc.jsonObjGet(result, "sessionId")) orelse
            rpc.jsonStr(rpc.jsonObjGet(sess, "sessionId")) orelse
            (req.resume_id orelse "");
        if (sid.len == 0) {
            return if (req.resume_id != null) error.ResumeFailed else error.SessionStartFailed;
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

    fn waitResponseTimeout(self: *MuseRun, expected_id: u64, timeout_ms: u64) ![]u8 {
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
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const sid_opt = if (self.session_id) |s| try self.allocator.dupe(u8, s) else null;
        self.state_mu.unlock(self.io);
        const sid = sid_opt orelse return error.NoSession;
        defer self.allocator.free(sid);

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
        self.turn_in_flight = true;
        self.emitted_eof_error = false;
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, expected_turn: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const sid_opt = if (self.session_id) |s| try self.allocator.dupe(u8, s) else null;
        const active_opt = if (expected_turn == null and self.active_turn_id != null)
            try self.allocator.dupe(u8, self.active_turn_id.?)
        else
            null;
        self.state_mu.unlock(self.io);
        defer if (sid_opt) |s| self.allocator.free(s);
        defer if (active_opt) |a| self.allocator.free(a);

        const sid = sid_opt orelse return .requires_interrupt_fallback;
        const turn_id = expected_turn orelse active_opt orelse return .requires_interrupt_fallback;

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

        const resp = self.waitResponseTimeout(req_id, STEER_TIMEOUT_MS) catch return .requires_interrupt_fallback;
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return .requires_interrupt_fallback;
        defer parsed.deinit();
        if (rpc.jsonObjGet(parsed.value, "error") != null) return .requires_interrupt_fallback;
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
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
                    const msg = try self.pipe.formatCrashMessage(self.allocator, "muse");
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

        if (std.mem.eql(u8, method, "turn/started")) {
            if (rpc.jsonStr(rpc.jsonObjGet(params, "turnId"))) |tid| {
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
        } else if (std.mem.eql(u8, method, "item/delta")) {
            const delta = rpc.jsonStr(rpc.jsonObjGet(params, "delta")) orelse "";
            const field = rpc.jsonStr(rpc.jsonObjGet(params, "field")) orelse "text";
            if (delta.len > 0) {
                const d_c = try self.allocator.dupe(u8, delta);
                errdefer self.allocator.free(d_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                if (std.mem.startsWith(u8, field, "reasoning") or std.mem.startsWith(u8, field, "thinking")) {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning_delta = .{ .text = d_c } },
                        .raw = raw_c,
                    });
                } else {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text_delta = .{ .text = d_c } },
                        .raw = raw_c,
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
            const kind = rpc.jsonStr(rpc.jsonObjGet(item, "type")) orelse "";
            const iid = rpc.jsonStr(rpc.jsonObjGet(item, "id")) orelse "";
            if (std.mem.eql(u8, kind, "assistantMessage") or std.mem.eql(u8, kind, "text")) {
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
            } else if (std.mem.eql(u8, kind, "reasoning")) {
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
            } else if (std.mem.eql(u8, kind, "toolCall") or std.mem.eql(u8, kind, "tool_call")) {
                const out_val = rpc.jsonObjGet(item, "output") orelse
                    rpc.jsonObjGet(item, "result") orelse
                    rpc.jsonObjGet(item, "error");
                const iid_c = try self.allocator.dupe(u8, iid);
                errdefer self.allocator.free(iid_c);
                const output = try rpc.extractTextOrJson(self.allocator, out_val);
                errdefer self.allocator.free(output);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                const is_err = rpc.jsonBool(rpc.jsonObjGet(item, "isError")) orelse false;
                try self.pending.append(self.allocator, .{
                    .kind = .{ .tool_finished = .{
                        .id = iid_c,
                        .output = output,
                        .is_error = is_err,
                    } },
                    .raw = raw_c,
                });
            }
        } else if (std.mem.eql(u8, method, "approval/requested")) {
            self.state_mu.lockUncancelable(self.io);
            const sid_copy = if (self.session_id) |s| (self.allocator.dupe(u8, s) catch null) else null;
            self.state_mu.unlock(self.io);
            defer if (sid_copy) |s| self.allocator.free(s);

            if (sid_copy) |sid| {
                const aid = rpc.jsonStr(rpc.jsonObjGet(params, "approvalId")) orelse "";
                const req_ref = rpc.jsonStr(rpc.jsonObjGet(params, "currentRequirementId")) orelse "";
                const choice = approvalChoice(self.access, params);
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
            errdefer if (err_msg) |m| self.allocator.free(m);
            try self.setActiveTurnId(null);
            self.pending_turn_req_id = null;
            const raw_c = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(raw_c);
            try self.pending.append(self.allocator, .{
                .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } },
                .raw = raw_c,
            });
        } else if (rpc.jsonObjGet(root, "id")) |id_val| {
            try rpc.replyMethodNotFound(self.allocator, &self.pipe, id_val, method);
        }
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *MuseRun = @ptrCast(@alignCast(ptr));
        self.state_mu.lockUncancelable(self.io);
        const sid_copy = if (self.session_id) |s| (self.allocator.dupe(u8, s) catch null) else null;
        const turn_copy = if (self.active_turn_id) |t| (self.allocator.dupe(u8, t) catch null) else null;
        self.state_mu.unlock(self.io);
        defer if (sid_copy) |s| self.allocator.free(s);
        defer if (turn_copy) |t| self.allocator.free(t);

        if (sid_copy) |sid| {
            const req_id = self.allocId();
            var cmd_buf: [36]u8 = undefined;
            const cmd_id = self.newCommandId(&cmd_buf);
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            buf.print(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"turn/interrupt\",\"params\":{{\"commandId\":\"{s}\",\"sessionId\":",
                .{ req_id, cmd_id },
            ) catch return;
            rpc.appendJsonEscaped(self.allocator, &buf, sid) catch return;
            if (turn_copy) |tid| {
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
