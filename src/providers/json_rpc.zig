const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const process = std.process;

pub const StreamLine = struct {
    is_stderr: bool,
    bytes: []u8,

    pub fn deinit(self: *StreamLine, allocator: Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const SubprocessPipe = struct {
    allocator: Allocator,
    io: Io,
    child: process.Child,
    alive: bool,
    stdout_buf: std.ArrayList(u8),
    stderr_buf: std.ArrayList(u8),
    stdout_eof: bool,
    stderr_eof: bool,

    pub fn spawn(
        allocator: Allocator,
        io: Io,
        argv: []const []const u8,
        cwd: []const u8,
    ) !SubprocessPipe {
        const child = try process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .alive = true,
            .stdout_buf = .empty,
            .stderr_buf = .empty,
            .stdout_eof = false,
            .stderr_eof = false,
        };
    }

    pub fn deinit(self: *SubprocessPipe) void {
        self.close();
        self.stdout_buf.deinit(self.allocator);
        self.stderr_buf.deinit(self.allocator);
    }

    pub fn writeLine(self: *SubprocessPipe, json_bytes: []const u8) !void {
        const stdin = self.child.stdin orelse return error.StdinClosed;
        const fd: posix.fd_t = stdin.handle;
        try writeAllFd(fd, json_bytes);
        if (json_bytes.len == 0 or json_bytes[json_bytes.len - 1] != '\n') {
            try writeAllFd(fd, "\n");
        }
    }

    pub fn closeStdin(self: *SubprocessPipe) void {
        if (self.child.stdin) |s| {
            s.close(self.io);
            self.child.stdin = null;
        }
    }

    pub fn kill(self: *SubprocessPipe) void {
        if (self.alive) {
            self.child.kill(self.io);
            self.alive = false;
        }
    }

    pub fn close(self: *SubprocessPipe) void {
        self.closeStdin();
        if (self.alive) {
            self.child.kill(self.io);
            self.alive = false;
        }
    }

    pub fn readNextLine(self: *SubprocessPipe, timeout_ms: i32) !?StreamLine {
        while (true) {
            if (extractLine(self.allocator, &self.stdout_buf)) |line| {
                return .{ .is_stderr = false, .bytes = line };
            }
            if (extractLine(self.allocator, &self.stderr_buf)) |line| {
                return .{ .is_stderr = true, .bytes = line };
            }
            if (self.stdout_eof and self.stderr_eof) {
                if (self.stdout_buf.items.len > 0) {
                    const rest = try self.stdout_buf.toOwnedSlice(self.allocator);
                    return .{ .is_stderr = false, .bytes = rest };
                }
                if (self.stderr_buf.items.len > 0) {
                    const rest = try self.stderr_buf.toOwnedSlice(self.allocator);
                    return .{ .is_stderr = true, .bytes = rest };
                }
                return null;
            }

            var fds: [2]linux.pollfd = undefined;
            var nfds: usize = 0;
            var out_idx: ?usize = null;
            var err_idx: ?usize = null;

            if (!self.stdout_eof) {
                if (self.child.stdout) |f| {
                    out_idx = nfds;
                    fds[nfds] = .{ .fd = f.handle, .events = linux.POLL.IN, .revents = 0 };
                    nfds += 1;
                } else {
                    self.stdout_eof = true;
                }
            }
            if (!self.stderr_eof) {
                if (self.child.stderr) |f| {
                    err_idx = nfds;
                    fds[nfds] = .{ .fd = f.handle, .events = linux.POLL.IN, .revents = 0 };
                    nfds += 1;
                } else {
                    self.stderr_eof = true;
                }
            }
            if (nfds == 0) continue;

            const rc = linux.poll(&fds, nfds, timeout_ms);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return error.PollFailed;
            if (rc == 0) return error.TimedOut;

            var tmp: [8192]u8 = undefined;
            const max_line_bytes: usize = 16 * 1024 * 1024;
            if (out_idx) |idx| {
                if ((fds[idx].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) {
                    const n_rc = linux.read(fds[idx].fd, &tmp, tmp.len);
                    if (linux.errno(n_rc) != .SUCCESS or n_rc == 0) {
                        self.stdout_eof = true;
                    } else {
                        if (self.stdout_buf.items.len + n_rc > max_line_bytes) return error.LineTooLong;
                        try self.stdout_buf.appendSlice(self.allocator, tmp[0..n_rc]);
                    }
                }
            }
            if (err_idx) |idx| {
                if ((fds[idx].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) {
                    const n_rc = linux.read(fds[idx].fd, &tmp, tmp.len);
                    if (linux.errno(n_rc) != .SUCCESS or n_rc == 0) {
                        self.stderr_eof = true;
                    } else {
                        if (self.stderr_buf.items.len + n_rc > max_line_bytes) return error.LineTooLong;
                        try self.stderr_buf.appendSlice(self.allocator, tmp[0..n_rc]);
                    }
                }
            }
        }
    }
};

fn extractLine(allocator: Allocator, buf: *std.ArrayList(u8)) ?[]u8 {
    const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse return null;
    const raw = buf.items[0..nl];
    const end = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw.len - 1 else raw.len;
    const copy = allocator.dupe(u8, raw[0..end]) catch return null;
    const remain = buf.items.len - (nl + 1);
    if (remain > 0) {
        std.mem.copyForwards(u8, buf.items[0..remain], buf.items[nl + 1 ..]);
    }
    buf.items.len = remain;
    return copy;
}

fn writeAllFd(fd: posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data[off..].ptr, data.len - off);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS or rc == 0) return error.BrokenPipe;
        off += rc;
    }
}

pub fn appendJsonEscaped(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex_buf: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(allocator, esc);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

pub fn jsonStr(val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn jsonBool(val: ?std.json.Value) ?bool {
    const v = val orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

pub fn jsonU64(val: ?std.json.Value) ?u64 {
    const v = val orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

pub fn jsonObjGet(val: ?std.json.Value, key: []const u8) ?std.json.Value {
    const v = val orelse return null;
    return switch (v) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

pub fn appendJsonValue(allocator: Allocator, out: *std.ArrayList(u8), val: std.json.Value) Allocator.Error!void {
    switch (val) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| {
            if (std.math.isFinite(f)) {
                try out.print(allocator, "{d}", .{f});
            } else {
                try out.appendSlice(allocator, "null");
            }
        },
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try appendJsonEscaped(allocator, out, s),
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try appendJsonValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |obj| {
            try out.append(allocator, '{');
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| {
                if (idx > 0) try out.append(allocator, ',');
                try appendJsonEscaped(allocator, out, entry.key_ptr.*);
                try out.append(allocator, ':');
                try appendJsonValue(allocator, out, entry.value_ptr.*);
                idx += 1;
            }
            try out.append(allocator, '}');
        },
    }
}

pub fn stringifyJsonValue(allocator: Allocator, val_opt: ?std.json.Value) Allocator.Error![]u8 {
    const val = val_opt orelse return allocator.dupe(u8, "{}");
    if (val == .null) return allocator.dupe(u8, "{}");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendJsonValue(allocator, &out, val);
    return out.toOwnedSlice(allocator);
}

fn extractTextFromArray(allocator: Allocator, items: []const std.json.Value) Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var found = false;
    for (items) |item| {
        const piece: ?[]const u8 = switch (item) {
            .string => |s| s,
            .object => jsonStr(jsonObjGet(item, "text")) orelse
                jsonStr(jsonObjGet(item, "content")) orelse
                jsonStr(jsonObjGet(jsonObjGet(item, "content"), "text")),
            else => null,
        };
        if (piece) |p| {
            if (found and out.items.len > 0 and p.len > 0) {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, p);
            found = true;
        }
    }
    if (!found) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn extractTextOrJson(allocator: Allocator, val_opt: ?std.json.Value) Allocator.Error![]u8 {
    const val = val_opt orelse return allocator.dupe(u8, "");
    switch (val) {
        .null => return allocator.dupe(u8, ""),
        .string => |s| return allocator.dupe(u8, s),
        .array => |arr| {
            if (arr.items.len == 0) return allocator.dupe(u8, "");
            if (try extractTextFromArray(allocator, arr.items)) |txt| return txt;
            return stringifyJsonValue(allocator, val);
        },
        .object => {
            if (jsonObjGet(val, "content")) |c| {
                switch (c) {
                    .string => |s| return allocator.dupe(u8, s),
                    .array => |arr| {
                        if (try extractTextFromArray(allocator, arr.items)) |txt| return txt;
                    },
                    .object => {
                        if (jsonStr(jsonObjGet(c, "text"))) |s| return allocator.dupe(u8, s);
                    },
                    else => {},
                }
            }
            if (jsonStr(jsonObjGet(val, "text"))) |s| return allocator.dupe(u8, s);
            return stringifyJsonValue(allocator, val);
        },
        else => return stringifyJsonValue(allocator, val),
    }
}

pub fn replyResultJson(allocator: Allocator, pipe: *SubprocessPipe, id_val: std.json.Value, result_json: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &buf, id_val);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.append(allocator, '}');
    pipe.writeLine(buf.items) catch {};
}

pub fn replyMethodNotFound(allocator: Allocator, pipe: *SubprocessPipe, id_val: std.json.Value, method: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendJsonValue(allocator, &buf, id_val);
    try buf.appendSlice(allocator, ",\"error\":{\"code\":-32601,\"message\":");
    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(allocator);
    try msg_buf.print(allocator, "method not supported: {s}", .{method});
    try appendJsonEscaped(allocator, &buf, msg_buf.items);
    try buf.appendSlice(allocator, "}}");
    pipe.writeLine(buf.items) catch {};
}
