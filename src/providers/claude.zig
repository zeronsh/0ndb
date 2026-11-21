const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

pub const ClaudeRun = struct {
    allocator: Allocator,
    pipe: rpc.SubprocessPipe,
    pending: std.ArrayList(iface.Event),
    seen_session_id: bool,
    turn_in_flight: bool,
    emitted_eof_error: bool,
    closed: bool,

    pub fn start(allocator: Allocator, io: Io, req: iface.StartRequest) !iface.RunHandle {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{
            "claude",
            "--print",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode",
            switch (req.access) {
                .plan => "plan",
                .accept_edits => "acceptEdits",
                .full => "bypassPermissions",
            },
        });
        if (req.model) |m| {
            try argv.appendSlice(allocator, &.{ "--model", m });
        }
        var resume_arg: ?[]u8 = null;
        defer if (resume_arg) |a| allocator.free(a);
        if (req.resume_id) |rid| {
            resume_arg = try std.fmt.allocPrint(allocator, "--resume={s}", .{rid});
            try argv.append(allocator, resume_arg.?);
            if (req.fork_at) |at| {
                try argv.appendSlice(allocator, &.{ "--resume-session-at", at, "--fork-session" });
            }
        }

        const self = try allocator.create(ClaudeRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, argv.items, req.cwd),
            .pending = .empty,
            .seen_session_id = false,
            .turn_in_flight = false,
            .emitted_eof_error = false,
            .closed = false,
        };
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn writeUserMsg(self: *ClaudeRun, prompt: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.appendSlice(self.allocator, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
        try rpc.appendJsonEscaped(self.allocator, &line, prompt);
        try line.appendSlice(self.allocator, "}]}}");
        try self.pipe.writeLine(line.items);
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *ClaudeRun = @ptrCast(@alignCast(ptr));
        try self.writeUserMsg(prompt);
        self.turn_in_flight = true;
        self.emitted_eof_error = false;
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, _: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *ClaudeRun = @ptrCast(@alignCast(ptr));
        try self.writeUserMsg(prompt);
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *ClaudeRun = @ptrCast(@alignCast(ptr));
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
                    const msg = try self.pipe.formatCrashMessage(self.allocator, "claude");
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
            const trimmed = std.mem.trim(u8, raw_line.bytes, " \t\r\n");
            if (trimmed.len == 0) continue;
            try parseStreamLine(self.allocator, trimmed, &self.seen_session_id, &self.pending);
        }
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *ClaudeRun = @ptrCast(@alignCast(ptr));
        self.pipe.kill();
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *ClaudeRun = @ptrCast(@alignCast(ptr));
        if (!self.closed) {
            self.closed = true;
            for (self.pending.items) |*ev| ev.deinit(self.allocator);
            self.pending.deinit(self.allocator);
            self.pipe.closeStdinGraceful(500);
            self.pipe.deinit();
            self.allocator.destroy(self);
        }
    }
};

pub fn parseStreamLine(allocator: Allocator, line: []const u8, seen_session_id: *bool, out: *std.ArrayList(iface.Event)) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        const kind_s = try allocator.dupe(u8, "unparsed");
        errdefer allocator.free(kind_s);
        const raw_s = try allocator.dupe(u8, line);
        errdefer allocator.free(raw_s);
        try out.append(allocator, .{
            .kind = .{ .other = .{ .kind = kind_s } },
            .raw = raw_s,
        });
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const ty = rpc.jsonStr(rpc.jsonObjGet(root, "type")) orelse "";
    const uuid = rpc.jsonStr(rpc.jsonObjGet(root, "uuid"));
    const native_msg: ?[]const u8 = if (std.mem.eql(u8, ty, "assistant") or std.mem.eql(u8, ty, "user")) uuid else null;
    const before = out.items.len;

    if (std.mem.eql(u8, ty, "stream_event")) {
        const ev = rpc.jsonObjGet(root, "event");
        const ev_ty = rpc.jsonStr(rpc.jsonObjGet(ev, "type")) orelse "";
        if (std.mem.eql(u8, ev_ty, "content_block_delta")) {
            const delta = rpc.jsonObjGet(ev, "delta");
            const d_ty = rpc.jsonStr(rpc.jsonObjGet(delta, "type")) orelse "";
            if (std.mem.eql(u8, d_ty, "text_delta")) {
                if (rpc.jsonStr(rpc.jsonObjGet(delta, "text"))) |t| {
                    try out.append(allocator, .{ .kind = .{ .text_delta = .{ .text = try allocator.dupe(u8, t) } } });
                }
            } else if (std.mem.eql(u8, d_ty, "thinking_delta")) {
                if (rpc.jsonStr(rpc.jsonObjGet(delta, "thinking"))) |t| {
                    try out.append(allocator, .{ .kind = .{ .reasoning_delta = .{ .text = try allocator.dupe(u8, t) } } });
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "system")) {
        const sub = rpc.jsonStr(rpc.jsonObjGet(root, "subtype")) orelse "";
        if (std.mem.eql(u8, sub, "init")) {
            if (rpc.jsonStr(rpc.jsonObjGet(root, "session_id"))) |sid| {
                seen_session_id.* = true;
                try out.append(allocator, .{ .kind = .{ .session_started = .{ .native_id = try allocator.dupe(u8, sid) } } });
            }
        }
    } else if (std.mem.eql(u8, ty, "assistant")) {
        const msg = rpc.jsonObjGet(root, "message");
        if (rpc.jsonObjGet(msg, "content")) |content_val| {
            if (content_val == .array) {
                for (content_val.array.items) |c| {
                    const ct = rpc.jsonStr(rpc.jsonObjGet(c, "type")) orelse "";
                    if (std.mem.eql(u8, ct, "text")) {
                        if (rpc.jsonStr(rpc.jsonObjGet(c, "text"))) |t| {
                            try out.append(allocator, .{ .kind = .{ .text = .{ .text = try allocator.dupe(u8, t) } } });
                        }
                    } else if (std.mem.eql(u8, ct, "thinking")) {
                        if (rpc.jsonStr(rpc.jsonObjGet(c, "thinking"))) |t| {
                            try out.append(allocator, .{ .kind = .{ .reasoning = .{ .text = try allocator.dupe(u8, t) } } });
                        }
                    } else if (std.mem.eql(u8, ct, "tool_use")) {
                        const tid = rpc.jsonStr(rpc.jsonObjGet(c, "id")) orelse "";
                        const name = rpc.jsonStr(rpc.jsonObjGet(c, "name")) orelse "tool";
                        const tid_c = try allocator.dupe(u8, tid);
                        errdefer allocator.free(tid_c);
                        const name_c = try allocator.dupe(u8, name);
                        errdefer allocator.free(name_c);
                        const input_json = try rpc.stringifyJsonValue(allocator, rpc.jsonObjGet(c, "input"));
                        errdefer allocator.free(input_json);
                        try out.append(allocator, .{ .kind = .{ .tool_started = .{
                            .id = tid_c,
                            .name = name_c,
                            .input_json = input_json,
                        } } });
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "user")) {
        const msg = rpc.jsonObjGet(root, "message");
        const tool_res = rpc.jsonObjGet(root, "tool_use_result");
        if (rpc.jsonObjGet(msg, "content")) |content_val| {
            if (content_val == .array) {
                for (content_val.array.items) |c| {
                    const ct = rpc.jsonStr(rpc.jsonObjGet(c, "type")) orelse "";
                    if (std.mem.eql(u8, ct, "tool_result")) {
                        const tid = rpc.jsonStr(rpc.jsonObjGet(c, "tool_use_id")) orelse "";
                        const tid_c = try allocator.dupe(u8, tid);
                        errdefer allocator.free(tid_c);
                        const output = try rpc.extractTextOrJson(allocator, rpc.jsonObjGet(c, "content"));
                        errdefer allocator.free(output);
                        const stdout_c: ?[]u8 = if (rpc.jsonStr(rpc.jsonObjGet(tool_res, "stdout"))) |s|
                            try allocator.dupe(u8, s)
                        else
                            null;
                        errdefer if (stdout_c) |s| allocator.free(s);
                        const stderr_c: ?[]u8 = if (rpc.jsonStr(rpc.jsonObjGet(tool_res, "stderr"))) |s|
                            try allocator.dupe(u8, s)
                        else
                            null;
                        errdefer if (stderr_c) |s| allocator.free(s);
                        const is_err = rpc.jsonBool(rpc.jsonObjGet(c, "is_error")) orelse false;
                        try out.append(allocator, .{ .kind = .{ .tool_finished = .{
                            .id = tid_c,
                            .output = output,
                            .is_error = is_err,
                            .stdout = stdout_c,
                            .stderr = stderr_c,
                        } } });
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, ty, "result")) {
        if (!seen_session_id.*) {
            if (rpc.jsonStr(rpc.jsonObjGet(root, "session_id"))) |sid| {
                seen_session_id.* = true;
                try out.append(allocator, .{ .kind = .{ .session_started = .{ .native_id = try allocator.dupe(u8, sid) } } });
            }
        }
        const sub = rpc.jsonStr(rpc.jsonObjGet(root, "subtype")) orelse "";
        const is_err = rpc.jsonBool(rpc.jsonObjGet(root, "is_error")) orelse false;
        const ok = std.mem.eql(u8, sub, "success") and !is_err;
        const cost_usd = rpc.jsonF64(rpc.jsonObjGet(root, "total_cost_usd")) orelse
            rpc.jsonF64(rpc.jsonObjGet(root, "cost_usd"));
        if (rpc.jsonObjGet(root, "usage")) |u| {
            try out.append(allocator, .{ .kind = .{ .usage = .{
                .input_tokens = rpc.jsonU64(rpc.jsonObjGet(u, "input_tokens")) orelse 0,
                .output_tokens = rpc.jsonU64(rpc.jsonObjGet(u, "output_tokens")) orelse 0,
                .cost_usd = cost_usd,
            } } });
        } else if (cost_usd != null) {
            try out.append(allocator, .{ .kind = .{ .usage = .{
                .input_tokens = 0,
                .output_tokens = 0,
                .cost_usd = cost_usd,
            } } });
        }
        const err_msg: ?[]u8 = if (!ok)
            try allocator.dupe(u8, rpc.jsonStr(rpc.jsonObjGet(root, "result")) orelse sub)
        else
            null;
        errdefer if (err_msg) |m| allocator.free(m);
        try out.append(allocator, .{ .kind = .{ .turn_ended = .{ .ok = ok, .err_msg = err_msg } } });
    }

    if (out.items.len == before) {
        try out.append(allocator, .{ .kind = .{ .other = .{ .kind = try allocator.dupe(u8, if (ty.len > 0) ty else "event") } } });
    }
    out.items[before].raw = try allocator.dupe(u8, line);
    if (native_msg) |nm| {
        for (out.items[before..]) |*ev| {
            ev.native_message = try allocator.dupe(u8, nm);
        }
    }
}

pub fn capabilities() iface.Capabilities {
    return .{
        .resume_session = true,
        .fork_at_message = true,
        .persistent = true,
        .native_steer = true,
    };
}
