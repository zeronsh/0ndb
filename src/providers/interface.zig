const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const ProviderId = enum(u8) {
    antigravity = 1,
    claude_code = 2,
    codex = 3,
    pi = 4,
    hermes = 5,
    opencode = 6,
    cursor = 7,
    devin = 8,
    muse = 9,
    mock = 10,
    grok = 11,

    pub fn slug(self: ProviderId) []const u8 {
        return switch (self) {
            .antigravity => "antigravity",
            .claude_code => "claude-code",
            .codex => "codex",
            .pi => "pi",
            .hermes => "hermes",
            .opencode => "opencode",
            .cursor => "cursor",
            .devin => "devin",
            .muse => "muse",
            .mock => "mock",
            .grok => "grok",
        };
    }

    pub fn displayName(self: ProviderId) []const u8 {
        return switch (self) {
            .antigravity => "Antigravity",
            .claude_code => "Claude Code",
            .codex => "Codex",
            .pi => "Pi",
            .hermes => "Hermes",
            .opencode => "Open Code",
            .cursor => "Cursor",
            .devin => "Devin",
            .muse => "Muse",
            .mock => "Mock",
            .grok => "Grok",
        };
    }

    pub fn fromSlug(s: []const u8) ?ProviderId {
        if (std.mem.eql(u8, s, "antigravity")) return .antigravity;
        if (std.mem.eql(u8, s, "claude-code") or std.mem.eql(u8, s, "claude")) return .claude_code;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        if (std.mem.eql(u8, s, "pi")) return .pi;
        if (std.mem.eql(u8, s, "hermes")) return .hermes;
        if (std.mem.eql(u8, s, "opencode") or std.mem.eql(u8, s, "open-code")) return .opencode;
        if (std.mem.eql(u8, s, "cursor")) return .cursor;
        if (std.mem.eql(u8, s, "devin")) return .devin;
        if (std.mem.eql(u8, s, "muse")) return .muse;
        if (std.mem.eql(u8, s, "mock")) return .mock;
        if (std.mem.eql(u8, s, "grok")) return .grok;
        return null;
    }
};

pub const AccessMode = enum(u8) {
    plan = 0,
    accept_edits = 1,
    full = 2,
};

pub const Capabilities = struct {
    resume_session: bool = false,
    fork_at_message: bool = false,
    persistent: bool = false,
    native_steer: bool = false,
};

pub const StartRequest = struct {
    cwd: []const u8,
    model: ?[]const u8 = null,
    resume_id: ?[]const u8 = null,
    fork_at: ?[]const u8 = null,
    access: AccessMode = .full,
};

pub const SteerOutcome = enum(u8) {
    injected_native = 1,
    requires_interrupt_fallback = 2,
};

pub const ModelInfo = struct {
    id: []u8,
    name: []u8,
    is_default: bool = false,

    pub fn deinit(self: *ModelInfo, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

pub const ProviderInfo = struct {
    id: ProviderId,
    available: bool,
    capabilities: Capabilities,
};

pub const EventKind = union(enum) {
    session_started: struct { native_id: []u8 },
    turn_started: struct { native_turn_id: ?[]u8 },
    text_delta: struct { text: []u8 },
    text: struct { text: []u8 },
    reasoning_delta: struct { text: []u8 },
    reasoning: struct { text: []u8 },
    tool_started: struct { id: []u8, name: []u8, input_json: []u8 },
    tool_finished: struct {
        id: []u8,
        output: []u8,
        is_error: bool,
        stdout: ?[]u8 = null,
        stderr: ?[]u8 = null,
    },
    usage: struct {
        input_tokens: u64,
        output_tokens: u64,
        cost_usd: ?f64 = null,
    },
    turn_ended: struct { ok: bool, err_msg: ?[]u8 },
    other: struct { kind: []u8 },

    pub fn deinit(self: *EventKind, allocator: Allocator) void {
        switch (self.*) {
            .session_started => |v| allocator.free(v.native_id),
            .turn_started => |v| if (v.native_turn_id) |t| allocator.free(t),
            .text_delta => |v| allocator.free(v.text),
            .text => |v| allocator.free(v.text),
            .reasoning_delta => |v| allocator.free(v.text),
            .reasoning => |v| allocator.free(v.text),
            .tool_started => |v| {
                allocator.free(v.id);
                allocator.free(v.name);
                allocator.free(v.input_json);
            },
            .tool_finished => |v| {
                allocator.free(v.id);
                allocator.free(v.output);
                if (v.stdout) |s| allocator.free(s);
                if (v.stderr) |s| allocator.free(s);
            },
            .usage => {},
            .turn_ended => |v| if (v.err_msg) |m| allocator.free(m),
            .other => |v| allocator.free(v.kind),
        }
    }
};

pub const Event = struct {
    kind: EventKind,
    raw: ?[]u8 = null,
    native_message: ?[]u8 = null,

    pub fn deinit(self: *Event, allocator: Allocator) void {
        self.kind.deinit(allocator);
        if (self.raw) |r| allocator.free(r);
        if (self.native_message) |m| allocator.free(m);
    }
};

pub const RunHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, prompt: []const u8) anyerror!void,
        steer: *const fn (ptr: *anyopaque, prompt: []const u8, expected_turn: ?[]const u8) anyerror!SteerOutcome,
        next: *const fn (ptr: *anyopaque) anyerror!?Event,
        interrupt: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: RunHandle, prompt: []const u8) !void {
        return self.vtable.send(self.ptr, prompt);
    }

    pub fn steer(self: RunHandle, prompt: []const u8, expected_turn: ?[]const u8) !SteerOutcome {
        return self.vtable.steer(self.ptr, prompt, expected_turn);
    }

    pub fn next(self: RunHandle) !?Event {
        return self.vtable.next(self.ptr);
    }

    pub fn interrupt(self: RunHandle) void {
        self.vtable.interrupt(self.ptr);
    }

    pub fn close(self: RunHandle) void {
        self.vtable.close(self.ptr);
    }
};

pub fn programOnPath(io: Io, program: []const u8) bool {
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        _ = Io.Dir.cwd().statFile(io, program, .{}) catch return false;
        return true;
    }

    var env_buf: [65536]u8 = undefined;
    var path_val: ?[]const u8 = null;
    if (Io.Dir.cwd().openFile(io, "/proc/self/environ", .{})) |ef| {
        defer ef.close(io);
        const n = ef.readPositionalAll(io, &env_buf, 0) catch 0;
        var it = std.mem.splitScalar(u8, env_buf[0..n], 0);
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry, "PATH=")) {
                path_val = entry["PATH=".len..];
                break;
            }
        }
    } else |_| {}

    var buf: [1024]u8 = undefined;
    if (path_val) |pv| {
        var pit = std.mem.splitScalar(u8, pv, ':');
        while (pit.next()) |dir| {
            if (dir.len == 0) continue;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, program }) catch continue;
            if (Io.Dir.cwd().statFile(io, full, .{})) |_| {
                return true;
            } else |_| {}
        }
    }

    const fallback_dirs = [_][]const u8{
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/homebrew/bin",
    };
    for (fallback_dirs) |dir| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, program }) catch continue;
        if (Io.Dir.cwd().statFile(io, full, .{})) |_| {
            return true;
        } else |_| {}
    }
    return false;
}

pub fn resolveProgram(io: Io, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |cand| {
        if (programOnPath(io, cand)) return cand;
    }
    return null;
}
