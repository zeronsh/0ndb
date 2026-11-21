const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const iface = @import("interface.zig");
const rpc = @import("json_rpc.zig");

pub const DEFAULT_WARM_LIMIT: usize = 4;
pub const MAX_WARM_LIMIT: usize = 64;
pub const DEFAULT_WARM_IDLE_MS: u64 = 90_000;

const Entry = struct {
    provider: iface.ProviderId,
    session_id: []u8,
    model: ?[]u8,
    cwd: []u8,
    handle: iface.RunHandle,
    parked_ms: u64,

    fn deinitMeta(self: *Entry, allocator: Allocator) void {
        allocator.free(self.session_id);
        if (self.model) |m| allocator.free(m);
        allocator.free(self.cwd);
    }
};

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const WarmPool = struct {
    allocator: Allocator,
    io: Io,
    warm_limit: usize,
    warm_idle_ms: u64,
    mu: Io.Mutex,
    cond: Io.Condition,
    entries: std.ArrayList(Entry),
    stopping: bool,
    reaper_thread: ?std.Thread,

    pub fn init(allocator: Allocator, io: Io, warm_limit: usize, warm_idle_ms: u64) WarmPool {
        return .{
            .allocator = allocator,
            .io = io,
            .warm_limit = @min(warm_limit, MAX_WARM_LIMIT),
            .warm_idle_ms = warm_idle_ms,
            .mu = Io.Mutex.init,
            .cond = Io.Condition.init,
            .entries = .empty,
            .stopping = false,
            .reaper_thread = null,
        };
    }

    pub fn deinit(self: *WarmPool) void {
        var detached: std.ArrayList(Entry) = .empty;
        const thread = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.stopping = true;
            detached = self.entries;
            self.entries = .empty;
            self.cond.broadcast(self.io);
            const t = self.reaper_thread;
            self.reaper_thread = null;
            break :blk t;
        };

        if (thread) |t| t.join();
        for (detached.items) |*e| {
            e.handle.close();
            e.deinitMeta(self.allocator);
        }
        detached.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn warmCount(self: *WarmPool) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.entries.items.len;
    }

    pub fn take(
        self: *WarmPool,
        provider: iface.ProviderId,
        session_id: []const u8,
        model: ?[]const u8,
        cwd: []const u8,
    ) ?iface.RunHandle {
        var removed: ?Entry = null;
        var matched = false;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            for (self.entries.items, 0..) |entry, i| {
                if (entry.provider == provider and std.mem.eql(u8, entry.session_id, session_id)) {
                    removed = self.entries.orderedRemove(i);
                    matched = optStrEql(entry.model, model) and std.mem.eql(u8, entry.cwd, cwd);
                    break;
                }
            }
        }
        if (removed) |*entry| {
            const handle = entry.handle;
            entry.deinitMeta(self.allocator);
            if (matched) return handle;
            handle.close();
        }
        return null;
    }

    pub fn park(
        self: *WarmPool,
        provider: iface.ProviderId,
        session_id: []const u8,
        model: ?[]const u8,
        cwd: []const u8,
        handle: iface.RunHandle,
    ) void {
        if (self.warm_limit == 0 or session_id.len == 0) {
            handle.close();
            return;
        }

        const sid_copy = self.allocator.dupe(u8, session_id) catch {
            handle.close();
            return;
        };
        const model_copy: ?[]u8 = if (model) |m| (self.allocator.dupe(u8, m) catch {
            self.allocator.free(sid_copy);
            handle.close();
            return;
        }) else null;
        const cwd_copy = self.allocator.dupe(u8, cwd) catch {
            self.allocator.free(sid_copy);
            if (model_copy) |m| self.allocator.free(m);
            handle.close();
            return;
        };

        var evicted_buf: [MAX_WARM_LIMIT + 2]Entry = undefined;
        var evicted_len: usize = 0;

        var accepted = false;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (!self.stopping) {
                var i: usize = 0;
                while (i < self.entries.items.len) {
                    const e = &self.entries.items[i];
                    if (e.provider == provider and std.mem.eql(u8, e.session_id, sid_copy)) {
                        if (evicted_len < evicted_buf.len) {
                            evicted_buf[evicted_len] = self.entries.orderedRemove(i);
                            evicted_len += 1;
                        } else {
                            i += 1;
                        }
                    } else {
                        i += 1;
                    }
                }

                const entry = Entry{
                    .provider = provider,
                    .session_id = sid_copy,
                    .model = model_copy,
                    .cwd = cwd_copy,
                    .handle = handle,
                    .parked_ms = rpc.monotonicMs(self.io),
                };
                if (self.entries.append(self.allocator, entry)) |_| {
                    accepted = true;
                    while (self.entries.items.len > self.warm_limit and evicted_len < evicted_buf.len) {
                        evicted_buf[evicted_len] = self.entries.orderedRemove(0);
                        evicted_len += 1;
                    }
                    if (self.reaper_thread == null and self.warm_idle_ms > 0) {
                        self.reaper_thread = std.Thread.spawn(.{}, reaperMain, .{self}) catch null;
                    }
                    self.cond.signal(self.io);
                } else |_| {}
            }
        }

        for (evicted_buf[0..evicted_len]) |*e| {
            e.handle.close();
            e.deinitMeta(self.allocator);
        }

        if (!accepted) {
            self.allocator.free(sid_copy);
            if (model_copy) |m| self.allocator.free(m);
            self.allocator.free(cwd_copy);
            handle.close();
        }
    }

    pub fn closeIdle(self: *WarmPool) void {
        var detached: std.ArrayList(Entry) = .empty;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            detached = self.entries;
            self.entries = .empty;
            self.cond.signal(self.io);
        }
        for (detached.items) |*e| {
            e.handle.close();
            e.deinitMeta(self.allocator);
        }
        detached.deinit(self.allocator);
    }

    fn reaperMain(self: *WarmPool) void {
        while (true) {
            var expired_buf: [MAX_WARM_LIMIT + 2]Entry = undefined;
            var expired_len: usize = 0;
            var should_exit = false;
            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);

                while (!self.stopping and self.entries.items.len == 0) {
                    self.cond.waitUncancelable(self.io, &self.mu);
                }
                if (self.stopping) {
                    should_exit = true;
                } else {
                    const now = rpc.monotonicMs(self.io);
                    var earliest_deadline: u64 = std.math.maxInt(u64);
                    for (self.entries.items) |e| {
                        const d = e.parked_ms +| self.warm_idle_ms;
                        if (d < earliest_deadline) earliest_deadline = d;
                    }
                    if (now < earliest_deadline) {
                        const wait_ms = earliest_deadline - now;
                        self.cond.waitTimeout(self.io, &self.mu, .{
                            .duration = .{
                                .raw = Io.Duration.fromMilliseconds(@intCast(@min(wait_ms, @as(u64, std.math.maxInt(i64))))),
                                .clock = .awake,
                            },
                        }) catch {};
                    }
                    if (self.stopping) {
                        should_exit = true;
                    } else {
                        const check_now = rpc.monotonicMs(self.io);
                        var i: usize = 0;
                        while (i < self.entries.items.len) {
                            if (check_now >= self.entries.items[i].parked_ms +| self.warm_idle_ms) {
                                if (expired_len < expired_buf.len) {
                                    expired_buf[expired_len] = self.entries.orderedRemove(i);
                                    expired_len += 1;
                                } else {
                                    break;
                                }
                            } else {
                                i += 1;
                            }
                        }
                    }
                }
            }
            for (expired_buf[0..expired_len]) |*e| {
                e.handle.close();
                e.deinitMeta(self.allocator);
            }
            if (should_exit) return;
        }
    }
};
