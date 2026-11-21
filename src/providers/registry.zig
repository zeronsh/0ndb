const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const pi = @import("pi.zig");
const muse = @import("muse.zig");
const acp = @import("acp.zig");
const models_mod = @import("models.zig");

pub const ALL_PROVIDERS = [_]iface.ProviderId{
    .antigravity,
    .claude_code,
    .codex,
    .pi,
    .hermes,
    .opencode,
    .cursor,
    .devin,
    .grok,
    .muse,
};

pub fn programFor(provider: iface.ProviderId) []const u8 {
    return switch (provider) {
        .antigravity => "agy_acp_server",
        .claude_code => "claude",
        .codex => "codex",
        .pi => "pi",
        .hermes => "hermes",
        .opencode => "opencode",
        .cursor => "cursor-agent",
        .devin => "devin",
        .grok => "grok",
        .muse => "muse",
        .mock => "mock",
    };
}

pub fn isAvailable(io: Io, provider: iface.ProviderId) bool {
    if (provider == .mock) return true;
    if (provider == .antigravity) {
        return iface.resolveProgram(io, &.{ "agy_acp_server", "agy_acp_server.par" }) != null;
    }
    return iface.programOnPath(io, programFor(provider));
}

pub fn capabilities(provider: iface.ProviderId) iface.Capabilities {
    return switch (provider) {
        .antigravity, .hermes, .opencode, .cursor, .devin, .grok => acp.capabilities(),
        .claude_code => claude.capabilities(),
        .codex => codex.capabilities(),
        .pi => pi.capabilities(),
        .muse => muse.capabilities(),
        .mock => .{
            .resume_session = true,
            .fork_at_message = true,
            .persistent = true,
            .native_steer = true,
        },
    };
}

pub fn listProviders(io: Io) [ALL_PROVIDERS.len]iface.ProviderInfo {
    var out: [ALL_PROVIDERS.len]iface.ProviderInfo = undefined;
    for (ALL_PROVIDERS, 0..) |p, i| {
        out[i] = .{
            .id = p,
            .available = isAvailable(io, p),
            .capabilities = capabilities(p),
        };
    }
    return out;
}

pub fn discoverModels(allocator: Allocator, io: Io, provider: iface.ProviderId) !models_mod.ModelCatalog {
    return models_mod.discover(allocator, io, provider);
}

pub fn start(
    allocator: Allocator,
    io: Io,
    provider: iface.ProviderId,
    req: iface.StartRequest,
) !iface.RunHandle {
    return switch (provider) {
        .antigravity => acp.AcpRun.start(allocator, io, .{
            .provider = .antigravity,
            .argv = models_mod.antigravityArgv(io),
        }, req),
        .hermes => acp.AcpRun.start(allocator, io, acp.HERMES_PROFILE, req),
        .opencode => acp.AcpRun.start(allocator, io, acp.OPENCODE_PROFILE, req),
        .cursor => acp.AcpRun.start(allocator, io, acp.CURSOR_PROFILE, req),
        .devin => acp.AcpRun.start(allocator, io, acp.DEVIN_PROFILE, req),
        .grok => acp.AcpRun.start(allocator, io, acp.GROK_PROFILE, req),
        .claude_code => claude.ClaudeRun.start(allocator, io, req),
        .codex => codex.CodexRun.start(allocator, io, req),
        .pi => pi.PiRun.start(allocator, io, req),
        .muse => muse.MuseRun.start(allocator, io, req),
        .mock => MockRun.start(allocator, .{ .native_steer = true }),
    };
}

pub const MockConfig = struct {
    native_steer: bool = true,
    split_chunks: bool = true,
};

pub const MockRun = struct {
    allocator: Allocator,
    config: MockConfig,
    events: std.ArrayList(iface.Event),
    turn_counter: u64,
    interrupted: bool,
    closed: bool,

    pub fn start(allocator: Allocator, config: MockConfig) !iface.RunHandle {
        const self = try allocator.create(MockRun);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .events = .empty,
            .turn_counter = 0,
            .interrupted = false,
            .closed = false,
        };
        try self.events.append(allocator, .{
            .kind = .{ .session_started = .{ .native_id = try allocator.dupe(u8, "mock-session-1") } },
        });
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = iface.RunHandle.VTable{
        .send = sendImpl,
        .steer = steerImpl,
        .next = nextImpl,
        .interrupt = interruptImpl,
        .close = closeImpl,
    };

    fn sendImpl(ptr: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *MockRun = @ptrCast(@alignCast(ptr));
        self.turn_counter += 1;
        self.interrupted = false;
        const tid = try std.fmt.allocPrint(self.allocator, "turn-{d}", .{self.turn_counter});
        try self.events.append(self.allocator, .{
            .kind = .{ .turn_started = .{ .native_turn_id = tid } },
        });
        if (self.config.split_chunks) {
            try self.events.append(self.allocator, .{
                .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, "reply:") } },
            });
            try self.events.append(self.allocator, .{
                .kind = .{ .text_delta = .{ .text = try self.allocator.dupe(u8, prompt) } },
            });
        } else {
            const full = try std.fmt.allocPrint(self.allocator, "reply:{s}", .{prompt});
            try self.events.append(self.allocator, .{
                .kind = .{ .text = .{ .text = full } },
            });
        }
        try self.events.append(self.allocator, .{
            .kind = .{ .turn_ended = .{ .ok = true, .err_msg = null } },
        });
    }

    fn steerImpl(ptr: *anyopaque, prompt: []const u8, _: ?[]const u8) anyerror!iface.SteerOutcome {
        const self: *MockRun = @ptrCast(@alignCast(ptr));
        if (!self.config.native_steer) return .requires_interrupt_fallback;
        const delta = try std.fmt.allocPrint(self.allocator, " [steered:{s}]", .{prompt});
        var insert_at = self.events.items.len;
        for (self.events.items, 0..) |ev, i| {
            if (ev.kind == .turn_ended) {
                insert_at = i;
                break;
            }
        }
        try self.events.insert(self.allocator, insert_at, .{
            .kind = .{ .text_delta = .{ .text = delta } },
        });
        return .injected_native;
    }

    fn nextImpl(ptr: *anyopaque) anyerror!?iface.Event {
        const self: *MockRun = @ptrCast(@alignCast(ptr));
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn interruptImpl(ptr: *anyopaque) void {
        const self: *MockRun = @ptrCast(@alignCast(ptr));
        self.interrupted = true;
        for (self.events.items) |*ev| ev.deinit(self.allocator);
        self.events.clearRetainingCapacity();
        self.events.append(self.allocator, .{
            .kind = .{ .turn_ended = .{
                .ok = false,
                .err_msg = self.allocator.dupe(u8, "interrupted") catch null,
            } },
        }) catch {};
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *MockRun = @ptrCast(@alignCast(ptr));
        if (!self.closed) {
            self.closed = true;
            for (self.events.items) |*ev| ev.deinit(self.allocator);
            self.events.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }
};
