const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

const REQUEST_TIMEOUT_MS: u64 = 120_000;
const STEER_TIMEOUT_MS: u64 = 10_000;

pub const PiRun = struct {
    allocator: Allocator,
    io: Io,
    pipe: rpc.SubprocessPipe,
    next_id: std.atomic.Value(u64),
    last_error: ?[]u8,
    turn_in_flight: bool,
    emitted_eof_error: bool,
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
            .io = io,
            .pipe = try rpc.SubprocessPipe.spawn(allocator, io, argv.items, req.cwd),
            .next_id = .init(1),
            .last_error = null,
            .turn_in_flight = false,
            .emitted_eof_error = false,
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

    fn clearLastError(self: *PiRun) void {
        if (self.last_error) |old| {
            self.allocator.free(old);
            self.last_error = null;
        }
    }

    fn allocId(self: *PiRun, buf: *[32]u8) []const u8 {
        const i = self.next_id.fetchAdd(1, .monotonic);
        return std.fmt.bufPrint(buf, "ondb-{d}", .{i}) catch unreachable;
    }

    fn handshake(self: *PiRun, model: ?[]const u8) !void {
        var id_buf: [32]u8 = undefined;
        const cid = self.allocId(&id_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"id\":\"{s}\",\"type\":\"get_state\"}}", .{cid});
        try self.pipe.writeLine(buf.items);
        const resp = try self.waitResponseTimeout(cid, REQUEST_TIMEOUT_MS, false);
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
                const r2 = try self.waitResponseTimeout(cid2, REQUEST_TIMEOUT_MS, false);
                defer self.allocator.free(r2);
                var p2 = std.json.parseFromSlice(std.json.Value, self.allocator, r2, .{}) catch return error.SetModelFailed;
                defer p2.deinit();
                if (rpc.jsonBool(rpc.jsonObjGet(p2.value, "success")) == false) return error.SetModelFailed;
            }
        }
    }

    fn waitResponseTimeout(self: *PiRun, expected_id: []const u8, timeout_ms: u64, forward_events: bool) ![]u8 {
        const deadline = rpc.monotonicMs(self.io) +| timeout_ms;
        while (true) {
            var line = try self.pipe.readLineDeadline(deadline) orelse return error.ProcessExited;
            defer line.deinit(self.allocator);
            if (line.is_stderr) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.bytes, .{}) catch continue;
            defer parsed.deinit();
            const ty = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "type")) orelse "";
            const rid = rpc.jsonStr(rpc.jsonObjGet(parsed.value, "id")) orelse "";
            if (std.mem.eql(u8, ty, "response") and std.mem.eql(u8, rid, expected_id)) {
                return try self.allocator.dupe(u8, line.bytes);
            }
            if (forward_events) {
                self.parseLine(line.bytes) catch {};
            }
        }
    }

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
        self.clearLastError();
        var id_buf: [32]u8 = undefined;
        const cid = self.allocId(&id_buf);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"id\":\"{s}\",\"type\":\"prompt\",\"message\":", .{cid});
        try rpc.appendJsonEscaped(self.allocator, &buf, prompt);
        try buf.append(self.allocator, '}');
        try self.pipe.writeLine(buf.items);
        self.turn_in_flight = true;
        self.emitted_eof_error = false;
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

        const resp = self.waitResponseTimeout(cid, STEER_TIMEOUT_MS, true) catch return .requires_interrupt_fallback;
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return .requires_interrupt_fallback;
        defer parsed.deinit();
        if (rpc.jsonBool(rpc.jsonObjGet(parsed.value, "success")) == false) return .requires_interrupt_fallback;
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *PiRun = @ptrCast(@alignCast(ptr));
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
                    const msg = try self.pipe.formatCrashMessage(self.allocator, "pi");
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
                    const d_c = try self.allocator.dupe(u8, delta);
                    errdefer self.allocator.free(d_c);
                    const raw_c = try self.allocator.dupe(u8, line);
                    errdefer self.allocator.free(raw_c);
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .text_delta = .{ .text = d_c } },
                        .raw = raw_c,
                    });
                } else if (std.mem.eql(u8, ety, "thinking_delta")) {
                    const d_c = try self.allocator.dupe(u8, delta);
                    errdefer self.allocator.free(d_c);
                    const raw_c = try self.allocator.dupe(u8, line);
                    errdefer self.allocator.free(raw_c);
                    try self.pending.append(self.allocator, .{
                        .kind = .{ .reasoning_delta = .{ .text = d_c } },
                        .raw = raw_c,
                    });
                }
            }
        } else if (std.mem.eql(u8, ty, "message_end")) {
            const msg = rpc.jsonObjGet(root, "message");
            const role = rpc.jsonStr(rpc.jsonObjGet(msg, "role")) orelse "";
            if (std.mem.eql(u8, role, "assistant")) {
                const stop = rpc.jsonStr(rpc.jsonObjGet(msg, "stopReason")) orelse "";
                self.clearLastError();
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
                if (rpc.jsonObjGet(msg, "usage")) |u| {
                    if (u == .object) {
                        const in_tok = rpc.jsonU64(rpc.jsonObjGet(u, "input")) orelse
                            rpc.jsonU64(rpc.jsonObjGet(u, "input_tokens")) orelse 0;
                        const out_tok = rpc.jsonU64(rpc.jsonObjGet(u, "output")) orelse
                            rpc.jsonU64(rpc.jsonObjGet(u, "output_tokens")) orelse 0;
                        const cost = rpc.jsonF64(rpc.jsonObjGet(rpc.jsonObjGet(u, "cost"), "total")) orelse
                            rpc.jsonF64(rpc.jsonObjGet(u, "cost_usd"));
                        try self.pending.append(self.allocator, .{
                            .kind = .{ .usage = .{
                                .input_tokens = in_tok,
                                .output_tokens = out_tok,
                                .cost_usd = cost,
                            } },
                        });
                    }
                }
            }
        } else if (std.mem.eql(u8, ty, "tool_execution_start")) {
            const tid = rpc.jsonStr(rpc.jsonObjGet(root, "toolCallId")) orelse "";
            const name = rpc.jsonStr(rpc.jsonObjGet(root, "toolName")) orelse "tool";
            const input_val = rpc.jsonObjGet(root, "args") orelse rpc.jsonObjGet(root, "input");
            const tid_c = try self.allocator.dupe(u8, tid);
            errdefer self.allocator.free(tid_c);
            const name_c = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_c);
            const input_json = try rpc.stringifyJsonValue(self.allocator, input_val);
            errdefer self.allocator.free(input_json);
            const raw_c = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(raw_c);
            try self.pending.append(self.allocator, .{
                .kind = .{ .tool_started = .{
                    .id = tid_c,
                    .name = name_c,
                    .input_json = input_json,
                } },
                .raw = raw_c,
            });
        } else if (std.mem.eql(u8, ty, "tool_execution_end")) {
            const tid = rpc.jsonStr(rpc.jsonObjGet(root, "toolCallId")) orelse "";
            const is_err = rpc.jsonBool(rpc.jsonObjGet(root, "isError")) orelse false;
            const out_val = rpc.jsonObjGet(root, "result") orelse rpc.jsonObjGet(root, "output");
            const tid_c = try self.allocator.dupe(u8, tid);
            errdefer self.allocator.free(tid_c);
            const output = try rpc.extractTextOrJson(self.allocator, out_val);
            errdefer self.allocator.free(output);
            const raw_c = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(raw_c);
            try self.pending.append(self.allocator, .{
                .kind = .{ .tool_finished = .{
                    .id = tid_c,
                    .output = output,
                    .is_error = is_err,
                } },
                .raw = raw_c,
            });
        } else if (std.mem.eql(u8, ty, "agent_settled")) {
            const aborted = rpc.jsonBool(rpc.jsonObjGet(root, "aborted")) orelse false;
            const err_msg: ?[]u8 = if (aborted) blk: {
                self.clearLastError();
                break :blk try self.allocator.dupe(u8, "interrupted");
            } else blk: {
                const e = self.last_error;
                self.last_error = null;
                break :blk e;
            };
            errdefer if (err_msg) |m| self.allocator.free(m);
            const raw_c = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(raw_c);
            try self.pending.append(self.allocator, .{
                .kind = .{ .turn_ended = .{ .ok = err_msg == null, .err_msg = err_msg } },
                .raw = raw_c,
            });
        } else if (std.mem.eql(u8, ty, "response")) {
            const cmd = rpc.jsonStr(rpc.jsonObjGet(root, "command")) orelse "";
            const ok = rpc.jsonBool(rpc.jsonObjGet(root, "success")) orelse true;
            if (std.mem.eql(u8, cmd, "prompt") and !ok) {
                const em = rpc.jsonStr(rpc.jsonObjGet(root, "error")) orelse "prompt refused";
                const em_c = try self.allocator.dupe(u8, em);
                errdefer self.allocator.free(em_c);
                const raw_c = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(raw_c);
                try self.pending.append(self.allocator, .{
                    .kind = .{ .turn_ended = .{ .ok = false, .err_msg = em_c } },
                    .raw = raw_c,
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
