const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

pub const PiRun = struct {
    allocator: Allocator,
    pipe: rpc.SubprocessPipe,
    next_id: u64,
    last_error: ?[]u8,
    pending: std.ArrayList(iface.Event),
    closed: bool,

    pub fn start(allocator: Allocator, io: Io, req: iface.StartRequest) !iface.RunHandle {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "pi", "--mode", "rpc", "--no-themes" });
        if (req.resume_id) |rid| {
            if (req.fork_at != null) {
                try argv.appendSlice(allocator, &.{ "--fork", rid });
            } else {
                try argv.appendSlice(allocator, &.{ "--session", rid });
            }
        }

        const self = try allocator.create(PiRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, argv.items, req.cwd),
            .next_id = 1,
            .last_error = null,
            .pending = .empty,
            .closed = false,
        };
        errdefer self.cleanup();

        try self.handshake(req.model);
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn cleanup(self: *PiRun) void {
        if (self.last_error) |e| self.allocator.free(e);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pipe.deinit();
    }

    fn allocId(self: *PiRun, buf: *[32]u8) []const u8 {
        const i = self.next_id;
        self.next_id += 1;
        return std.fmt.bufPrint(buf, "ondb-{d}", .{i}) catch unreachable;
    }

    fn handshake(self: *PiRun, model: ?[]const u8) !void {
        var id_buf: [32]u8 = undefined;
        const cid = self.allocId(&id_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"id\":\"{s}\",\"type\":\"get_state\"}}", .{cid});
        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponse(cid);
        defer self.allocator.free(resp);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (rpc.jsonBool(rpc.jsonObjGet(parsed.value, "success")) == false) return error.HandshakeFailed;
        const data = rpc.jsonObjGet(parsed.value, "data");
        if (rpc.jsonStr(rpc.jsonObjGet(data, "sessionFile"))) |sf| {
            try self.pending.append(self.allocator, .{
                .kind = .{ .session_started = .{ .native_id = try self.allocator.dupe(u8, sf) } },
            });
        }
        if (model) |m| {
            if (std.mem.indexOfScalar(u8, m, '/')) |slash| {
                const prov = m[0..slash];
                const mid = m[slash + 1 ..];
                var id2_buf: [32]u8 = undefined;
                const cid2 = self.allocId(&id2_buf);
                buf.clearRetainingCapacity();
                try buf.print(self.allocator, "{{\"id\":\"{s}\",\"type\":\"set_model\",\"provider\":", .{cid2});
                try rpc.appendJsonEscaped(self.allocator, &buf, prov);
                try buf.appendSlice(self.allocator, ",\"modelId\":");
                try rpc.appendJsonEscaped(self.allocator, &buf, mid);
                try buf.append(self.allocator, '}');
                try self.pipe.writeLine(buf.items);
                const r2 = try self.waitResponse(cid2);
                self.allocator.free(r2);
            }
        }
    }

    fn waitResponse(self: *PiRun, expected_id: []const u8) ![]u8 {
        while (true) {
            var line = try self.pipe.readNextLine(-1) orelse return error.ProcessExited;
            defer line.deinit(self.allocator);
            if (line.is_stderr) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.bytes, .{}) catch continue;
            defer parsed.deinit();
            const ty = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "type")) orelse "";
            const rid = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "id")) orelse "";
            if (std.mem.eql(u8, ty, "response") and std.mem.eql(u8, rid, expected_id)) {
                return try self.allocator.dupe(u8, line.bytes);
            }
        }
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
        var id_buf: [32]u8 = undefined;
        const cid = self.allocId(&id_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"id\":\"{s}\",\"type\":\"prompt\",\"message\":", .{cid});
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.append(self.allocator, '}');
        try self.pipe.writeLine(buf.items);
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, _: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
        var id_buf: [32]u8 = undefined;
        const cid = self.allocId(&id_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"id\":\"{s}\",\"type\":\"steer\",\"message\":", .{cid});
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.append(self.allocator, '}');
        try self.pipe.writeLine(buf.items);
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
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
            try self.parseLine(raw_line.bytes);
        }
    }

    fn parseLine(self: *PiRun, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        const ty = rpc.jsonStr(rpc.jsonObjGet(root, "type")) orelse return;

        if (std.mem.eql(u8, ty, "message_update")) {
            const ev = rpc.jsonObjGet(root, "assistantMessageEvent");
            const ety = rpc.jsonStr(rpc.jsonObjGet(ev, "type")) orelse "";
            const delta = rpc.jsonStr(rpc.jsonObjGet(ev, "delta")) orelse "";
            if (delta.len > 0) {
                if (std.mem.eql(u8, ety, "text_delta")) {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, delta) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                } else if (std.mem.eql(u8, ety, "thinking_delta")) {
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning_delta = .{ .text = try self.allocator.dupe(u8, delta) } },
                        .raw = try self.allocator.dupe(u8, line),
                    });
                }
            }
        } else if (std.mem.eql(u8, ty, "message_end")) {
            const msg = rpc.jsonObjGet(root, "message");
            const role = rpc.jsonStr(rpc.jsonObjGet(msg, "role")) orelse "";
            if (std.mem.eql(u8, role, "assistant")) {
                const stop = rpc.jsonStr(rpc.jsonObjGet(msg, "stopReason")) orelse "";
                if (self.last_error) |old| {
                    self.allocator.free(old);
                    self.last_error = null;
                }
                if (std.mem.eql(u8, stop, "error")) {
                    const em = rpc.jsonStr(rpc.jsonObjGet(msg, "errorMessage")) orelse "model call failed";
                    self.last_error = try self.allocator.dupe(u8, em);
                }
                if (rpc.jsonObjGet(msg, "content")) |cval| {
                    if (cval == .array) {
                        for (cval.array.items) |part| {
                            const pt = rpc.jsonStr(rpc.jsonObjGet(part, "type")) orelse "";
                            if (std.mem.eql(u8, pt, "text")) {
                                if (rpc.jsonStr(rpc.jsonObjGet(part, "text"))) |t| {
                                    if (t.len > 0) try self.pending.append(self.allocator, .{ .kind = .{ .text = .{ .text = try self.allocator.dupe(u8, t) } } });
                                }
                            } else if (std.mem.eql(u8, pt, "thinking")) {
                                if (rpc.jsonStr(rpc.jsonObjGet(part, "thinking"))) |t| {
                                    if (t.len > 0) try self.pending.append(self.allocator, .{ .kind = .{ .reasoning = .{ .text = try self.allocator.dupe(u8, t) } } });
                                }
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, ty, "tool_execution_start")) {
            const tid = rpc.jsonStr(rpc.jsonObjGet(root, "toolCallId")) orelse "";
            const name = rpc.jsonStr(rpc.jsonObjGet(root, "toolName")) orelse "tool";
            const input_val = rpc.jsonObjGet(root, "args") orelse rpc.jsonObjGet(root, "input");
            const input_json = try rpc.stringifyJsonValue(self.allocator, input_val);
            errdefer self.allocator.free(input_json);
            try self.pending.append(self.allocator, .{
                .kind = .{ .tool_started = .{
                    .id = try self.allocator.dupe(u8, tid),
                    .name = try self.allocator.dupe(u8, name),
                    .input_json = input_json,
                } },
                .raw = try self.allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, ty, "tool_execution_end")) {
            const tid = rpc.jsonStr(rpc.jsonObjGet(root, "toolCallId")) orelse "";
            const is_err = rpc.jsonBool(rpc.jsonObjGet(root, "isError")) orelse false;
            const out_val = rpc.jsonObjGet(root, "result") orelse rpc.jsonObjGet(root, "output");
            const output = try rpc.extractTextOrJson(self.allocator, out_val);
            errdefer self.allocator.free(output);
            try self.pending.append(self.allocator, .{
                .kind = .{ .tool_finished = .{
                    .id = try self.allocator.dupe(u8, tid),
                    .output = output,
                    .is_error = is_err,
                } },
                .raw = try self.allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, ty, "agent_settled")) {
            const aborted = rpc.jsonBool(rpc.jsonObjGet(root, "aborted")) orelse false;
            const err_msg: ?[]u8 = if (aborted)
                try self.allocator.dupe(u8, "interrupted")
            else blk: {
                const e = self.last_error;
                self.last_error = null;
                break :blk e;
            };
            try self.pending.append(self.allocator, .{
                .kind = .{ .turn_ended = .{ .ok = err_msg == null, .err_msg = err_msg } },
                .raw = try self.allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, ty, "response")) {
            const cmd = rpc.jsonStr(rpc.jsonObjGet(root, "command")) orelse "";
            const ok = rpc.jsonBool(rpc.jsonObjGet(root, "success")) orelse true;
            if (std.mem.eql(u8, cmd, "prompt") and !ok) {
                const em = rpc.jsonStr(rpc.jsonObjGet(root, "error")) orelse "prompt refused";
                try self.pending.append(self.allocator, .{
                    .kind = .{ .turn_ended = .{ .ok = false, .err_msg = try self.allocator.dupe(u8, em) } },
                    .raw = try self.allocator.dupe(u8, line),
                });
            }
        }
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
        self.pipe.writeLine("{\"type\":\"clear_queue\"}") catch {};
        self.pipe.writeLine("{\"type\":\"abort\"}") catch {};
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
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
