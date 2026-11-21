const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const process = std.process;

pub const DEFAULT_GRACE_MS: u64 = 500;
pub const MAX_STDERR_SNIPPET: usize = 2048;

pub fn monotonicMs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    const ms = @divFloor(ts.nanoseconds, std.time.ns_per_ms);
    return if (ms < 0) 0 else @intCast(ms);
}

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
    child_pid: ?posix.pid_t,
    in_own_pgroup: bool,
    exit_code: ?i32,
    reaped: bool,
    alive: bool,
    write_mu: Io.Mutex,
    state_mu: Io.Mutex,
    stdout_buf: std.ArrayList(u8),
    stderr_buf: std.ArrayList(u8),
    last_stderr: std.ArrayList(u8),
    stdout_eof: bool,
    stderr_eof: bool,

    pub fn spawn(
        allocator: Allocator,
        io: Io,
        argv: []const []const u8,
        cwd: []const u8,
    ) !SubprocessPipe {
        var in_own_pgroup = true;
        const child = process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        }) catch |err| blk: {
            if (err == error.PermissionDenied or err == error.InvalidProcessGroupId) {
                in_own_pgroup = false;
                break :blk try process.spawn(io, .{
                    .argv = argv,
                    .cwd = .{ .path = cwd },
                    .stdin = .pipe,
                    .stdout = .pipe,
                    .stderr = .pipe,
                });
            }
            return err;
        };
        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .child_pid = child.id,
            .in_own_pgroup = in_own_pgroup,
            .exit_code = null,
            .reaped = false,
            .alive = true,
            .write_mu = .init,
            .state_mu = .init,
            .stdout_buf = .empty,
            .stderr_buf = .empty,
            .last_stderr = .empty,
            .stdout_eof = false,
            .stderr_eof = false,
        };
    }

    pub fn deinit(self: *SubprocessPipe) void {
        self.close();
        if (self.child.stdout) |f| {
            f.close(self.io);
            self.child.stdout = null;
        }
        if (self.child.stderr) |f| {
            f.close(self.io);
            self.child.stderr = null;
        }
        self.child.id = null;
        self.stdout_buf.deinit(self.allocator);
        self.stderr_buf.deinit(self.allocator);
        self.last_stderr.deinit(self.allocator);
    }

    pub fn writeLine(self: *SubprocessPipe, json_bytes: []const u8) !void {
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        const stdin = self.child.stdin orelse return error.StdinClosed;
        const fd: posix.fd_t = stdin.handle;
        try writeAllFd(fd, json_bytes);
        if (json_bytes.len == 0 or json_bytes[json_bytes.len - 1] != '\n') {
            try writeAllFd(fd, "\n");
        }
    }

    pub fn closeStdin(self: *SubprocessPipe) void {
        self.write_mu.lockUncancelable(self.io);
        defer self.write_mu.unlock(self.io);
        if (self.child.stdin) |s| {
            s.close(self.io);
            self.child.stdin = null;
        }
    }

    fn decodeWaitStatus(raw_status: i32) i32 {
        const s: u32 = @bitCast(raw_status);
        const low = s & 0x7f;
        if (low == 0) {
            return @as(i32, @intCast((s >> 8) & 0xff));
        }
        if (low != 0x7f) {
            return -@as(i32, @intCast(low));
        }
        return -1;
    }

    pub fn tryReap(self: *SubprocessPipe) bool {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        if (self.reaped) return true;
        const pid = self.child_pid orelse {
            self.reaped = true;
            self.alive = false;
            return true;
        };
        while (true) {
            var status: i32 = 0;
            const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .CHILD) {
                self.reaped = true;
                self.alive = false;
                self.child.id = null;
                return true;
            }
            if (e != .SUCCESS) return false;
            if (rc == 0) return false;
            self.exit_code = decodeWaitStatus(status);
            self.reaped = true;
            self.alive = false;
            self.child.id = null;
            return true;
        }
    }

    pub fn waitExitStatus(self: *SubprocessPipe) ?i32 {
        self.state_mu.lockUncancelable(self.io);
        if (self.reaped) {
            const code = self.exit_code;
            self.state_mu.unlock(self.io);
            return code;
        }
        const pid = self.child_pid orelse {
            self.reaped = true;
            self.alive = false;
            self.state_mu.unlock(self.io);
            return null;
        };
        self.state_mu.unlock(self.io);

        var status: i32 = 0;
        while (true) {
            const rc = linux.waitpid(pid, &status, 0);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            self.state_mu.lockUncancelable(self.io);
            defer self.state_mu.unlock(self.io);
            if (self.reaped) return self.exit_code;
            if (e == .SUCCESS and rc != 0) {
                self.exit_code = decodeWaitStatus(status);
            }
            self.reaped = true;
            self.alive = false;
            self.child.id = null;
            return self.exit_code;
        }
    }

    fn signalTarget(self: *SubprocessPipe, pid: posix.pid_t, sig: linux.SIG) void {
        if (self.in_own_pgroup and pid > 1) {
            const rc = linux.kill(-pid, sig);
            if (linux.errno(rc) == .SRCH) {
                _ = linux.kill(pid, sig);
            }
        } else {
            _ = linux.kill(pid, sig);
        }
    }

    pub fn killGraceful(self: *SubprocessPipe, grace_ms: u64) void {
        if (self.tryReap()) return;
        self.state_mu.lockUncancelable(self.io);
        const pid = self.child_pid;
        const already_reaped = self.reaped;
        self.state_mu.unlock(self.io);
        if (already_reaped or pid == null) return;

        self.signalTarget(pid.?, .TERM);
        const deadline = monotonicMs(self.io) +| grace_ms;
        while (monotonicMs(self.io) < deadline) {
            if (self.tryReap()) return;
            self.io.sleep(.fromMilliseconds(15), .awake) catch {};
        }
        if (self.tryReap()) return;

        self.signalTarget(pid.?, .KILL);
        _ = self.waitExitStatus();
    }

    pub fn closeStdinGraceful(self: *SubprocessPipe, eof_grace_ms: u64) void {
        self.closeStdin();
        if (self.tryReap()) return;
        const deadline = monotonicMs(self.io) +| eof_grace_ms;
        while (monotonicMs(self.io) < deadline) {
            if (self.tryReap()) return;
            self.io.sleep(.fromMilliseconds(15), .awake) catch {};
        }
        self.killGraceful(DEFAULT_GRACE_MS);
    }

    pub fn kill(self: *SubprocessPipe) void {
        self.killGraceful(DEFAULT_GRACE_MS);
    }

    pub fn close(self: *SubprocessPipe) void {
        self.closeStdin();
        self.killGraceful(DEFAULT_GRACE_MS);
    }

    pub fn lastStderrSnippet(self: *SubprocessPipe) []const u8 {
        return std.mem.trim(u8, self.last_stderr.items, " \t\r\n");
    }

    fn recordStderr(self: *SubprocessPipe, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.last_stderr.items.len > 0) {
            self.last_stderr.append(self.allocator, '\n') catch return;
        }
        const slice = if (trimmed.len > MAX_STDERR_SNIPPET)
            trimmed[trimmed.len - MAX_STDERR_SNIPPET ..]
        else
            trimmed;
        self.last_stderr.appendSlice(self.allocator, slice) catch return;
        if (self.last_stderr.items.len > MAX_STDERR_SNIPPET) {
            const drop = self.last_stderr.items.len - MAX_STDERR_SNIPPET;
            const keep = self.last_stderr.items.len - drop;
            std.mem.copyForwards(u8, self.last_stderr.items[0..keep], self.last_stderr.items[drop..]);
            self.last_stderr.items.len = keep;
        }
    }

    pub fn formatCrashMessage(self: *SubprocessPipe, allocator: Allocator, provider_name: []const u8) ![]u8 {
        const code_opt = self.waitExitStatus();
        const err_tail = self.lastStderrSnippet();
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (code_opt) |code| {
            if (code < 0) {
                try buf.print(allocator, "{s} process killed by signal {d}", .{ provider_name, -code });
            } else if (code > 0) {
                try buf.print(allocator, "{s} process exited with code {d}", .{ provider_name, code });
            } else {
                try buf.print(allocator, "{s} process exited unexpectedly before turn completed", .{provider_name});
            }
        } else {
            try buf.print(allocator, "{s} process exited unexpectedly", .{provider_name});
        }
        if (err_tail.len > 0) {
            const max_show = @min(err_tail.len, 512);
            const show = err_tail[err_tail.len - max_show ..];
            try buf.appendSlice(allocator, ": ");
            try buf.appendSlice(allocator, show);
        }
        return try buf.toOwnedSlice(allocator);
    }

    pub fn readNextLine(self: *SubprocessPipe, timeout_ms: i32) !?StreamLine {
        if (timeout_ms < 0) {
            return self.readLineDeadline(null);
        }
        const deadline = monotonicMs(self.io) +| @as(u64, @intCast(timeout_ms));
        return self.readLineDeadline(deadline);
    }

    pub fn readLineDeadline(self: *SubprocessPipe, deadline_ms: ?u64) !?StreamLine {
        while (true) {
            if (try extractLine(self.allocator, &self.stdout_buf)) |line| {
                return .{ .is_stderr = false, .bytes = line };
            }
            if (try extractLine(self.allocator, &self.stderr_buf)) |line| {
                self.recordStderr(line);
                return .{ .is_stderr = true, .bytes = line };
            }
            if (self.stdout_eof and self.stderr_eof) {
                if (self.stdout_buf.items.len > 0) {
                    const rest = try self.stdout_buf.toOwnedSlice(self.allocator);
                    return .{ .is_stderr = false, .bytes = rest };
                }
                if (self.stderr_buf.items.len > 0) {
                    const rest = try self.stderr_buf.toOwnedSlice(self.allocator);
                    self.recordStderr(rest);
                    return .{ .is_stderr = true, .bytes = rest };
                }
                _ = self.waitExitStatus();
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

            const poll_timeout: i32 = if (deadline_ms) |dl| blk: {
                const now = monotonicMs(self.io);
                if (now >= dl) return error.TimedOut;
                const rem = dl - now;
                break :blk @intCast(@min(rem, @as(u64, std.math.maxInt(i32))));
            } else -1;

            const rc = linux.poll(&fds, nfds, poll_timeout);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) continue;
            if (e != .SUCCESS) return error.PollFailed;
            if (rc == 0) return error.TimedOut;

            var tmp: [8192]u8 = undefined;
            const max_line_bytes: usize = 16 * 1024 * 1024;
            if (out_idx) |idx| {
                const rev = fds[idx].revents;
                if ((rev & linux.POLL.NVAL) != 0) {
                    self.stdout_eof = true;
                } else if ((rev & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) {
                    while (true) {
                        const n_rc = linux.read(fds[idx].fd, &tmp, tmp.len);
                        const re = linux.errno(n_rc);
                        if (re == .INTR) continue;
                        if (re == .AGAIN) break;
                        if (re != .SUCCESS or n_rc == 0) {
                            self.stdout_eof = true;
                        } else {
                            if (self.stdout_buf.items.len + n_rc > max_line_bytes) return error.LineTooLong;
                            try self.stdout_buf.appendSlice(self.allocator, tmp[0..n_rc]);
                        }
                        break;
                    }
                }
            }
            if (err_idx) |idx| {
                const rev = fds[idx].revents;
                if ((rev & linux.POLL.NVAL) != 0) {
                    self.stderr_eof = true;
                } else if ((rev & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) {
                    while (true) {
                        const n_rc = linux.read(fds[idx].fd, &tmp, tmp.len);
                        const re = linux.errno(n_rc);
                        if (re == .INTR) continue;
                        if (re == .AGAIN) break;
                        if (re != .SUCCESS or n_rc == 0) {
                            self.stderr_eof = true;
                        } else {
                            if (self.stderr_buf.items.len + n_rc > max_line_bytes) return error.LineTooLong;
                            try self.stderr_buf.appendSlice(self.allocator, tmp[0..n_rc]);
                        }
                        break;
                    }
                }
            }
        }
    }
};

fn extractLine(allocator: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!?[]u8 {
    const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse return null;
    const raw = buf.items[0..nl];
    const end = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw.len - 1 else raw.len;
    const copy = try allocator.dupe(u8, raw[0..end]);
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
        if (e == .AGAIN) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, 5000);
            const pe = linux.errno(prc);
            if (pe == .INTR) continue;
            if (pe != .SUCCESS or prc == 0) return error.BrokenPipe;
            if ((pfd[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL)) != 0) return error.BrokenPipe;
            continue;
        }
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

pub fn jsonI64(val: ?std.json.Value) ?i64 {
    const v = val orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

pub fn jsonF64(val: ?std.json.Value) ?f64 {
    const v = val orelse return null;
    return switch (v) {
        .float => |f| if (std.math.isFinite(f)) f else null,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
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
