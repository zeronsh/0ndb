const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const id = @import("../core/id.zig");
const crypto = @import("../store/crypto.zig");
const log_mod = @import("../store/log.zig");
const wire = @import("wire.zig");

const TopicId = [32]u8;
const MAX_PEERS: usize = 512;
const MAX_PEER_RX_BYTES: usize = wire.MAX_FRAME_LEN + wire.WIRE_HEADER_LEN + 65536;
const MAX_PEER_TX_BYTES: usize = 32 * 1024 * 1024;
const TX_COMPACT_THRESHOLD: usize = 65536;
const IDLE_BUF_SHRINK_CAP: usize = 65536;

pub const MAX_OPAQUE_PAYLOAD: usize = wire.MAX_FRAME_LEN - 64;
pub const MAX_RANGE_BATCH_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_SUBSCRIBE_CATCHUP_ITEMS: usize = 256;
pub const DEFAULT_AUTH_TIMEOUT_MS: u64 = 10_000;
pub const DEFAULT_IDLE_TIMEOUT_MS: u64 = 120_000;
pub const DEFAULT_WRITE_TIMEOUT_MS: u64 = 15_000;
pub const DEFAULT_MAX_CONNS_PER_IP: usize = 64;
pub const DEFAULT_MAX_FRAMES_PER_TICK: usize = 32;

pub fn scopedBlobKey(topic: TopicId, oid: [32]u8) [32]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("0ndb-relay-scoped-blob-v1");
    h.update(&topic);
    h.update(&oid);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

const PermSlot = struct {
    granted: bool = false,
    expires_ms: u64 = 0,

    fn active(self: PermSlot, now_ms: u64) bool {
        if (!self.granted) return false;
        return self.expires_ms == 0 or now_ms <= self.expires_ms;
    }

    fn merge(self: *PermSlot, expires_ms: u64) void {
        if (!self.granted) {
            self.granted = true;
            self.expires_ms = expires_ms;
            return;
        }
        if (self.expires_ms == 0 or expires_ms == 0) {
            self.expires_ms = 0;
        } else if (expires_ms > self.expires_ms) {
            self.expires_ms = expires_ms;
        }
    }
};

const Grant = struct {
    read: PermSlot = .{},
    write: PermSlot = .{},
    sub: PermSlot = .{},

    fn merge(self: *Grant, perms: u8, expires_ms: u64) void {
        if ((perms & wire.PERM_READ) != 0) self.read.merge(expires_ms);
        if ((perms & wire.PERM_WRITE) != 0) self.write.merge(expires_ms);
        if ((perms & wire.PERM_SUB) != 0) self.sub.merge(expires_ms);
    }

    fn allows(self: Grant, mask: u8, now_ms: u64) bool {
        if (mask == 0 or (mask & ~wire.PERM_ALL) != 0) return false;
        if ((mask & wire.PERM_READ) != 0 and !self.read.active(now_ms)) return false;
        if ((mask & wire.PERM_WRITE) != 0 and !self.write.active(now_ms)) return false;
        if ((mask & wire.PERM_SUB) != 0 and !self.sub.active(now_ms)) return false;
        return true;
    }
};

const PeerConn = struct {
    fd: posix.fd_t,
    ip: u32,
    connected_ms: u64,
    last_activity_ms: u64,
    write_stall_since_ms: u64,
    authed: bool,
    closing: bool,
    rx_pending: bool,
    tick_processed: bool,
    rx: std.ArrayList(u8),
    tx: std.ArrayList(u8),
    tx_off: usize,
    perms: std.AutoHashMapUnmanaged(TopicId, Grant),
    subs: std.AutoHashMapUnmanaged(TopicId, void),

    fn init(fd: posix.fd_t, ip: u32, now_ms: u64, authed: bool) PeerConn {
        return .{
            .fd = fd,
            .ip = ip,
            .connected_ms = now_ms,
            .last_activity_ms = now_ms,
            .write_stall_since_ms = 0,
            .authed = authed,
            .closing = false,
            .rx_pending = false,
            .tick_processed = false,
            .rx = .empty,
            .tx = .empty,
            .tx_off = 0,
            .perms = .empty,
            .subs = .empty,
        };
    }

    fn deinit(self: *PeerConn, allocator: Allocator) void {
        _ = linux.close(self.fd);
        self.rx.deinit(allocator);
        self.tx.deinit(allocator);
        self.perms.deinit(allocator);
        self.subs.deinit(allocator);
    }

    fn hasPerm(self: *const PeerConn, topic: TopicId, mask: u8, now_ms: u64) bool {
        const g = self.perms.get(topic) orelse return false;
        return g.allows(mask, now_ms);
    }

    fn pendingTxBytes(self: *const PeerConn) usize {
        return self.tx.items.len - self.tx_off;
    }

    fn compactTx(self: *PeerConn, allocator: Allocator) void {
        if (self.tx_off == 0) return;
        if (self.tx_off >= self.tx.items.len) {
            self.tx.clearRetainingCapacity();
            self.tx_off = 0;
            if (self.tx.capacity > IDLE_BUF_SHRINK_CAP) {
                self.tx.shrinkAndFree(allocator, 0);
            }
            return;
        }
        if (self.tx_off >= TX_COMPACT_THRESHOLD or self.tx_off * 2 >= self.tx.items.len) {
            const rem = self.tx.items.len - self.tx_off;
            std.mem.copyForwards(u8, self.tx.items[0..rem], self.tx.items[self.tx_off..]);
            self.tx.items.len = rem;
            self.tx_off = 0;
        }
    }

    fn maybeShrinkIdleRx(self: *PeerConn, allocator: Allocator) void {
        if (self.rx.items.len == 0 and self.rx.capacity > IDLE_BUF_SHRINK_CAP) {
            self.rx.shrinkAndFree(allocator, 0);
        }
    }

    fn queueBytes(self: *PeerConn, allocator: Allocator, data: []const u8) !void {
        self.compactTx(allocator);
        const pending = self.pendingTxBytes();
        if (data.len > MAX_PEER_TX_BYTES or pending > MAX_PEER_TX_BYTES - data.len) {
            return error.TxBufferFull;
        }
        try self.tx.appendSlice(allocator, data);
    }
};

pub const RelayServer = struct {
    allocator: Allocator,
    io: Io,
    auth_secret: [32]u8,
    require_auth: bool,
    durable_sync: bool,
    auth_timeout_ms: u64,
    idle_timeout_ms: u64,
    write_timeout_ms: u64,
    max_conns_per_ip: usize,
    max_frames_per_tick: usize,
    state_dir: Io.Dir,
    blob_dir: Io.Dir,
    listen_fd: posix.fd_t,
    wake_fd: posix.fd_t,
    epfd: posix.fd_t,
    port: u16,
    peers: std.AutoHashMapUnmanaged(posix.fd_t, *PeerConn),
    ip_counts: std.AutoHashMapUnmanaged(u32, usize),
    closing_fds: std.ArrayList(posix.fd_t),
    closing_overflow: bool,
    topics: std.AutoHashMapUnmanaged(TopicId, log_mod.AppendLog),
    tmp_seq: u64,
    running: std.atomic.Value(bool),

    pub fn start(
        allocator: Allocator,
        io: Io,
        state_path: []const u8,
        bind_ip: [4]u8,
        port: u16,
        auth_secret: [32]u8,
        require_auth: bool,
    ) !RelayServer {
        try Io.Dir.cwd().createDirPath(io, state_path);
        var state_dir = try Io.Dir.cwd().openDir(io, state_path, .{ .iterate = true });
        errdefer state_dir.close(io);
        try state_dir.createDirPath(io, "blobs");
        var blob_dir = try state_dir.openDir(io, "blobs", .{ .iterate = true });
        errdefer blob_dir.close(io);

        const s_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(s_rc) != .SUCCESS) return error.SocketFailed;
        const listen_fd: posix.fd_t = @intCast(s_rc);
        errdefer _ = linux.close(listen_fd);

        var one: i32 = 1;
        _ = linux.setsockopt(listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));

        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(bind_ip),
        };
        if (linux.errno(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return error.BindFailed;
        }
        if (linux.errno(linux.listen(listen_fd, 128)) != .SUCCESS) {
            return error.ListenFailed;
        }

        var bound: linux.sockaddr.in = undefined;
        var bound_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(listen_fd, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
            return error.GetSockNameFailed;
        }
        const actual_port = std.mem.bigToNative(u16, bound.port);

        const w_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(w_rc) != .SUCCESS) return error.EventFdFailed;
        const wake_fd: posix.fd_t = @intCast(w_rc);
        errdefer _ = linux.close(wake_fd);

        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(ep_rc) != .SUCCESS) return error.EpollFailed;
        const epfd: posix.fd_t = @intCast(ep_rc);
        errdefer _ = linux.close(epfd);

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = listen_fd },
        };
        if (linux.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listen_fd, &ev)) != .SUCCESS) {
            return error.EpollCtlFailed;
        }

        var wev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = wake_fd },
        };
        if (linux.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wake_fd, &wev)) != .SUCCESS) {
            return error.EpollCtlFailed;
        }

        return .{
            .allocator = allocator,
            .io = io,
            .auth_secret = auth_secret,
            .require_auth = require_auth,
            .durable_sync = true,
            .auth_timeout_ms = DEFAULT_AUTH_TIMEOUT_MS,
            .idle_timeout_ms = DEFAULT_IDLE_TIMEOUT_MS,
            .write_timeout_ms = DEFAULT_WRITE_TIMEOUT_MS,
            .max_conns_per_ip = DEFAULT_MAX_CONNS_PER_IP,
            .max_frames_per_tick = DEFAULT_MAX_FRAMES_PER_TICK,
            .state_dir = state_dir,
            .blob_dir = blob_dir,
            .listen_fd = listen_fd,
            .wake_fd = wake_fd,
            .epfd = epfd,
            .port = actual_port,
            .peers = .empty,
            .ip_counts = .empty,
            .closing_fds = .empty,
            .closing_overflow = false,
            .topics = .empty,
            .tmp_seq = 0,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *RelayServer) void {
        self.running.store(false, .release);
        {
            var it = self.peers.valueIterator();
            while (it.next()) |p| {
                p.*.deinit(self.allocator);
                self.allocator.destroy(p.*);
            }
            self.peers.deinit(self.allocator);
        }
        self.ip_counts.deinit(self.allocator);
        self.closing_fds.deinit(self.allocator);
        {
            var it = self.topics.valueIterator();
            while (it.next()) |t| t.deinit();
            self.topics.deinit(self.allocator);
        }
        crypto.zeroize(&self.auth_secret);
        _ = linux.close(self.epfd);
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.listen_fd);
        self.blob_dir.close(self.io);
        self.state_dir.close(self.io);
    }

    pub fn stop(self: *RelayServer) void {
        self.running.store(false, .release);
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    pub fn run(self: *RelayServer) !void {
        while (self.running.load(.acquire)) {
            _ = try self.step(100);
        }
    }

    fn hasPendingRx(self: *const RelayServer) bool {
        var it = self.peers.valueIterator();
        while (it.next()) |p| {
            if (!p.*.closing and p.*.rx_pending) return true;
        }
        return false;
    }

    pub fn step(self: *RelayServer, timeout_ms: i32) !usize {
        defer self.reapClosingPeers();

        var reset_it = self.peers.valueIterator();
        while (reset_it.next()) |p| {
            p.*.tick_processed = false;
        }

        const effective_timeout: i32 = if (self.hasPendingRx()) 0 else timeout_ms;
        var events: [64]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(self.epfd, &events, events.len, effective_timeout);
        const e = linux.errno(rc);
        if (e == .INTR) {
            self.sweepTimeouts(id.nowMs(self.io));
            return 0;
        }
        if (e != .SUCCESS) return error.EpollWaitFailed;
        const n: usize = rc;
        for (events[0..n]) |ev| {
            const fd = ev.data.fd;
            if (fd == self.wake_fd) {
                var val: u64 = undefined;
                _ = linux.read(self.wake_fd, std.mem.asBytes(&val), @sizeOf(u64));
            } else if (fd == self.listen_fd) {
                self.acceptLoop();
            } else {
                self.handlePeerEvent(fd, ev.events);
            }
        }

        var pending_fds: std.ArrayList(posix.fd_t) = .empty;
        defer pending_fds.deinit(self.allocator);
        var pit = self.peers.valueIterator();
        while (pit.next()) |p| {
            if (!p.*.closing and p.*.rx_pending and !p.*.tick_processed) {
                pending_fds.append(self.allocator, p.*.fd) catch break;
            }
        }
        for (pending_fds.items) |pfd| {
            const peer = self.peers.get(pfd) orelse continue;
            if (peer.closing) continue;
            peer.tick_processed = true;
            self.processPeerRx(peer) catch {
                self.markPeerClosing(pfd);
            };
        }

        self.sweepTimeouts(id.nowMs(self.io));
        return n;
    }

    fn sweepTimeouts(self: *RelayServer, now_ms: u64) void {
        var it = self.peers.valueIterator();
        while (it.next()) |p| {
            const peer = p.*;
            if (peer.closing) continue;
            if (self.require_auth and !peer.authed and self.auth_timeout_ms > 0 and now_ms -| peer.connected_ms >= self.auth_timeout_ms) {
                self.markPeerClosing(peer.fd);
                continue;
            }
            if (self.idle_timeout_ms > 0 and now_ms -| peer.last_activity_ms >= self.idle_timeout_ms) {
                self.markPeerClosing(peer.fd);
                continue;
            }
            if (peer.write_stall_since_ms != 0 and self.write_timeout_ms > 0 and now_ms -| peer.write_stall_since_ms >= self.write_timeout_ms) {
                self.markPeerClosing(peer.fd);
                continue;
            }
        }
    }

    fn incIpCount(self: *RelayServer, ip: u32) !void {
        const gop = try self.ip_counts.getOrPut(self.allocator, ip);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }

    fn decIpCount(self: *RelayServer, ip: u32) void {
        if (self.ip_counts.getPtr(ip)) |cnt| {
            if (cnt.* <= 1) {
                _ = self.ip_counts.remove(ip);
            } else {
                cnt.* -= 1;
            }
        }
    }

    fn acceptLoop(self: *RelayServer) void {
        const now_ms = id.nowMs(self.io);
        while (true) {
            var peer_addr: linux.sockaddr.in = undefined;
            var peer_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.accept4(self.listen_fd, @ptrCast(&peer_addr), &peer_len, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            const e = linux.errno(rc);
            if (e == .AGAIN or e == .INTR) break;
            if (e != .SUCCESS) break;
            const cfd: posix.fd_t = @intCast(rc);

            const peer_ip: u32 = if (peer_len >= @sizeOf(linux.sockaddr.in)) peer_addr.addr else 0;
            const cur_ip = self.ip_counts.get(peer_ip) orelse 0;
            if (self.peers.count() >= MAX_PEERS or cur_ip >= self.max_conns_per_ip) {
                _ = linux.close(cfd);
                continue;
            }

            var one: i32 = 1;
            _ = linux.setsockopt(cfd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));

            const peer = self.allocator.create(PeerConn) catch {
                _ = linux.close(cfd);
                continue;
            };
            peer.* = PeerConn.init(cfd, peer_ip, now_ms, !self.require_auth);

            self.incIpCount(peer_ip) catch {
                peer.deinit(self.allocator);
                self.allocator.destroy(peer);
                continue;
            };
            self.peers.put(self.allocator, cfd, peer) catch {
                self.decIpCount(peer_ip);
                peer.deinit(self.allocator);
                self.allocator.destroy(peer);
                continue;
            };

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .fd = cfd },
            };
            if (linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, cfd, &ev)) != .SUCCESS) {
                self.markPeerClosing(cfd);
            }
        }
    }

    fn markPeerClosing(self: *RelayServer, fd: posix.fd_t) void {
        const peer = self.peers.get(fd) orelse return;
        if (peer.closing) return;
        peer.closing = true;
        peer.rx_pending = false;
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
        self.closing_fds.append(self.allocator, fd) catch {
            self.closing_overflow = true;
        };
    }

    fn reapClosingPeers(self: *RelayServer) void {
        for (self.closing_fds.items) |fd| {
            if (self.peers.fetchRemove(fd)) |kv| {
                self.decIpCount(kv.value.ip);
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
            }
        }
        self.closing_fds.clearRetainingCapacity();
        if (self.closing_overflow) {
            self.closing_overflow = false;
            var keep_scanning = true;
            while (keep_scanning) {
                keep_scanning = false;
                var it = self.peers.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.*.closing) {
                        const fd = entry.key_ptr.*;
                        if (self.peers.fetchRemove(fd)) |kv| {
                            self.decIpCount(kv.value.ip);
                            kv.value.deinit(self.allocator);
                            self.allocator.destroy(kv.value);
                        }
                        keep_scanning = true;
                        break;
                    }
                }
            }
        }
    }

    fn updatePeerEpoll(self: *RelayServer, peer: *PeerConn) void {
        if (peer.closing) return;
        var mask: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
        if (peer.tx_off < peer.tx.items.len) mask |= linux.EPOLL.OUT;
        var ev = linux.epoll_event{ .events = mask, .data = .{ .fd = peer.fd } };
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, peer.fd, &ev);
    }

    fn flushPeerTx(self: *RelayServer, peer: *PeerConn) bool {
        if (peer.closing) return false;
        const now_ms = id.nowMs(self.io);
        while (peer.tx_off < peer.tx.items.len) {
            const rem = peer.tx.items[peer.tx_off..];
            const rc = linux.sendto(peer.fd, rem.ptr, rem.len, linux.MSG.NOSIGNAL, null, 0);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) {
                peer.compactTx(self.allocator);
                if (peer.write_stall_since_ms == 0) {
                    peer.write_stall_since_ms = now_ms;
                }
                self.updatePeerEpoll(peer);
                return true;
            }
            if (e != .SUCCESS or rc == 0) return false;
            peer.tx_off += rc;
            peer.write_stall_since_ms = 0;
            peer.last_activity_ms = now_ms;
        }
        peer.compactTx(self.allocator);
        peer.write_stall_since_ms = 0;
        self.updatePeerEpoll(peer);
        return true;
    }

    fn sendToPeer(self: *RelayServer, peer: *PeerConn, op: wire.Op, flags: u8, payload: []const u8) !void {
        if (peer.closing) return error.PeerClosing;
        const frame = try wire.encodeFrame(self.allocator, op, flags, payload);
        defer self.allocator.free(frame);
        try peer.queueBytes(self.allocator, frame);
        if (!self.flushPeerTx(peer)) return error.PeerWriteFailed;
    }

    fn sendErr(self: *RelayServer, peer: *PeerConn, code: wire.ErrCode, msg: []const u8) void {
        var buf: [256]u8 = undefined;
        buf[0] = @intFromEnum(code);
        const n = @min(msg.len, buf.len - 1);
        @memcpy(buf[1 .. 1 + n], msg[0..n]);
        self.sendToPeer(peer, .err, 0, buf[0 .. 1 + n]) catch {};
    }

    fn handlePeerEvent(self: *RelayServer, fd: posix.fd_t, revents: u32) void {
        const peer = self.peers.get(fd) orelse return;
        if (peer.closing) return;
        if ((revents & (linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0) {
            self.markPeerClosing(fd);
            return;
        }
        if ((revents & linux.EPOLL.OUT) != 0) {
            if (!self.flushPeerTx(peer)) {
                self.markPeerClosing(fd);
                return;
            }
        }
        if ((revents & linux.EPOLL.IN) != 0) {
            const now_ms = id.nowMs(self.io);
            var tmp: [16384]u8 = undefined;
            while (true) {
                const rc = linux.read(fd, &tmp, tmp.len);
                const e = linux.errno(rc);
                if (e == .INTR) continue;
                if (e == .AGAIN) break;
                if (e != .SUCCESS or rc == 0) {
                    self.markPeerClosing(fd);
                    return;
                }
                if (rc > MAX_PEER_RX_BYTES or peer.rx.items.len > MAX_PEER_RX_BYTES - rc) {
                    self.markPeerClosing(fd);
                    return;
                }
                peer.rx.appendSlice(self.allocator, tmp[0..rc]) catch {
                    self.markPeerClosing(fd);
                    return;
                };
                peer.last_activity_ms = now_ms;
            }
            peer.tick_processed = true;
            self.processPeerRx(peer) catch {
                self.markPeerClosing(fd);
                return;
            };
        }
    }

    fn processPeerRx(self: *RelayServer, peer: *PeerConn) !void {
        var consumed: usize = 0;
        var dispatched: usize = 0;
        var hit_cap = false;
        while (consumed < peer.rx.items.len and !peer.closing) {
            if (dispatched >= self.max_frames_per_tick) {
                hit_cap = true;
                break;
            }
            const avail = peer.rx.items[consumed..];
            const hdr = (try wire.decodeHeader(avail)) orelse break;
            const total = wire.WIRE_HEADER_LEN + hdr.len;
            if (avail.len < total) break;
            const payload = avail[wire.WIRE_HEADER_LEN..total];
            try self.dispatchFrame(peer, hdr.op, payload);
            consumed += total;
            dispatched += 1;
        }
        if (consumed > 0) {
            const rem = peer.rx.items.len - consumed;
            if (rem > 0) {
                std.mem.copyForwards(u8, peer.rx.items[0..rem], peer.rx.items[consumed..]);
            }
            peer.rx.items.len = rem;
        }
        peer.rx_pending = hit_cap and peer.rx.items.len > 0 and !peer.closing;
        peer.maybeShrinkIdleRx(self.allocator);
    }

    fn getOrOpenTopic(self: *RelayServer, topic: TopicId) !*log_mod.AppendLog {
        const gop = try self.topics.getOrPut(self.allocator, topic);
        if (!gop.found_existing) {
            errdefer _ = self.topics.remove(topic);
            var hex: [64]u8 = undefined;
            _ = id.formatHashHex(topic, &hex);
            var name_buf: [80]u8 = undefined;
            const fname = try std.fmt.bufPrint(&name_buf, "{s}.topic", .{hex});
            gop.value_ptr.* = try log_mod.AppendLog.open(self.allocator, self.io, self.state_dir, fname, self.durable_sync);
        }
        return gop.value_ptr;
    }

    fn checkPerm(self: *const RelayServer, peer: *const PeerConn, topic: TopicId, mask: u8) bool {
        if (!self.require_auth) return true;
        return peer.hasPerm(topic, mask, id.nowMs(self.io));
    }

    fn dispatchFrame(self: *RelayServer, peer: *PeerConn, op: wire.Op, payload: []const u8) !void {
        peer.last_activity_ms = id.nowMs(self.io);
        switch (op) {
            .auth => {
                if (payload.len != 32 + 1 + 8 + 32) {
                    self.sendErr(peer, .bad_frame, "bad auth");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                const perms = payload[32];
                if (perms == 0 or (perms & ~wire.PERM_ALL) != 0) {
                    self.sendErr(peer, .bad_frame, "bad perms");
                    return;
                }
                const expires = std.mem.readInt(u64, payload[33..41], .little);
                const mac: crypto.Mac = payload[41..73].*;
                if (self.require_auth and !crypto.verifyCapabilityToken(self.auth_secret, topic, perms, expires, mac, id.nowMs(self.io))) {
                    self.sendErr(peer, .unauthorized, "invalid token");
                    return;
                }
                const gop = try peer.perms.getOrPut(self.allocator, topic);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{};
                }
                gop.value_ptr.merge(perms, expires);
                peer.authed = true;
                var ack: [8]u8 = undefined;
                std.mem.writeInt(u64, &ack, 0, .little);
                try self.sendToPeer(peer, .ack, 0, &ack);
            },
            .put_frame => {
                if (payload.len < 32) {
                    self.sendErr(peer, .bad_frame, "short put_frame");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                if (!self.checkPerm(peer, topic, wire.PERM_WRITE)) {
                    self.sendErr(peer, .unauthorized, "write denied");
                    return;
                }
                const opaque_bytes = payload[32..];
                if (opaque_bytes.len > MAX_OPAQUE_PAYLOAD) {
                    self.sendErr(peer, .bad_frame, "frame payload too large");
                    return;
                }
                const tlog = try self.getOrOpenTopic(topic);
                const seq = try tlog.append(1, 0, 0, opaque_bytes);

                var ack: [8]u8 = undefined;
                std.mem.writeInt(u64, &ack, seq, .little);
                try self.sendToPeer(peer, .ack, 0, &ack);

                const ev_payload = try self.allocator.alloc(u8, 32 + 8 + opaque_bytes.len);
                defer self.allocator.free(ev_payload);
                @memcpy(ev_payload[0..32], &topic);
                std.mem.writeInt(u64, ev_payload[32..40], seq, .little);
                if (opaque_bytes.len > 0) @memcpy(ev_payload[40..], opaque_bytes);

                const encoded_ev = try wire.encodeFrame(self.allocator, .frame_event, 0, ev_payload);
                defer self.allocator.free(encoded_ev);

                const now_ms = id.nowMs(self.io);
                var pit = self.peers.valueIterator();
                while (pit.next()) |other_ptr| {
                    const other = other_ptr.*;
                    if (other.closing) continue;
                    if (other.subs.contains(topic)) {
                        if (self.require_auth and !other.hasPerm(topic, wire.PERM_SUB, now_ms)) {
                            _ = other.subs.remove(topic);
                            continue;
                        }
                        other.queueBytes(self.allocator, encoded_ev) catch {
                            if (other.fd != peer.fd) self.markPeerClosing(other.fd);
                            continue;
                        };
                        if (!self.flushPeerTx(other)) {
                            if (other.fd != peer.fd) self.markPeerClosing(other.fd);
                        }
                    }
                }
            },
            .get_range => {
                if (payload.len != 32 + 8 + 4) {
                    self.sendErr(peer, .bad_frame, "bad get_range");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                if (!self.checkPerm(peer, topic, wire.PERM_READ)) {
                    self.sendErr(peer, .unauthorized, "read denied");
                    return;
                }
                const after_seq = std.mem.readInt(u64, payload[32..40], .little);
                const limit = std.mem.readInt(u32, payload[40..44], .little);
                const tlog = self.getOrOpenTopic(topic) catch {
                    self.sendErr(peer, .internal, "topic open failed");
                    return;
                };

                var sent: u32 = 0;
                var sent_bytes: usize = 0;
                var has_more = false;
                const total = tlog.count();
                const start_idx: usize = if (after_seq == std.math.maxInt(u64))
                    total
                else
                    tlog.findIndexBySeq(after_seq + 1);
                for (start_idx..total) |idx| {
                    if (limit > 0 and sent >= limit) {
                        has_more = true;
                        break;
                    }
                    const view = tlog.readAt(idx) catch {
                        self.sendErr(peer, .internal, "range read failed");
                        return;
                    };
                    if (view.payload.len > MAX_OPAQUE_PAYLOAD) {
                        self.sendErr(peer, .internal, "oversized stored frame");
                        return;
                    }
                    const item_wire_len = wire.WIRE_HEADER_LEN + 40 + view.payload.len;
                    if (sent > 0 and (sent_bytes + item_wire_len > MAX_RANGE_BATCH_BYTES or
                        peer.pendingTxBytes() + item_wire_len + 64 > MAX_PEER_TX_BYTES))
                    {
                        has_more = true;
                        break;
                    }
                    const ev_payload = try self.allocator.alloc(u8, 32 + 8 + view.payload.len);
                    defer self.allocator.free(ev_payload);
                    @memcpy(ev_payload[0..32], &topic);
                    std.mem.writeInt(u64, ev_payload[32..40], view.header.seq, .little);
                    if (view.payload.len > 0) @memcpy(ev_payload[40..], view.payload);
                    try self.sendToPeer(peer, .range_item, 0, ev_payload);
                    sent += 1;
                    sent_bytes += item_wire_len;
                }
                var end_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &end_buf, tlog.lastSeq(), .little);
                const end_flags: u8 = if (has_more) wire.RANGE_FLAG_HAS_MORE else 0;
                try self.sendToPeer(peer, .range_end, end_flags, &end_buf);
            },
            .subscribe => {
                if (payload.len != 32 + 8) {
                    self.sendErr(peer, .bad_frame, "bad subscribe");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                if (!self.checkPerm(peer, topic, wire.PERM_SUB)) {
                    self.sendErr(peer, .unauthorized, "sub denied");
                    return;
                }
                const after_seq = std.mem.readInt(u64, payload[32..40], .little);
                const tlog = self.getOrOpenTopic(topic) catch {
                    self.sendErr(peer, .internal, "topic open failed");
                    return;
                };
                try peer.subs.put(self.allocator, topic, {});

                var sent: usize = 0;
                var sent_bytes: usize = 0;
                var has_more = false;
                const total = tlog.count();
                const start_idx: usize = if (after_seq == std.math.maxInt(u64))
                    total
                else
                    tlog.findIndexBySeq(after_seq + 1);
                for (start_idx..total) |idx| {
                    if (sent >= MAX_SUBSCRIBE_CATCHUP_ITEMS) {
                        has_more = true;
                        break;
                    }
                    const view = tlog.readAt(idx) catch {
                        self.sendErr(peer, .internal, "subscribe read failed");
                        return;
                    };
                    if (view.payload.len > MAX_OPAQUE_PAYLOAD) {
                        self.sendErr(peer, .internal, "oversized stored frame");
                        return;
                    }
                    const item_wire_len = wire.WIRE_HEADER_LEN + 40 + view.payload.len;
                    if (sent > 0 and (sent_bytes + item_wire_len > MAX_RANGE_BATCH_BYTES or
                        peer.pendingTxBytes() + item_wire_len + 64 > MAX_PEER_TX_BYTES))
                    {
                        has_more = true;
                        break;
                    }
                    const ev_payload = try self.allocator.alloc(u8, 32 + 8 + view.payload.len);
                    defer self.allocator.free(ev_payload);
                    @memcpy(ev_payload[0..32], &topic);
                    std.mem.writeInt(u64, ev_payload[32..40], view.header.seq, .little);
                    if (view.payload.len > 0) @memcpy(ev_payload[40..], view.payload);
                    try self.sendToPeer(peer, .range_item, 0, ev_payload);
                    sent += 1;
                    sent_bytes += item_wire_len;
                }
                var ack: [8]u8 = undefined;
                std.mem.writeInt(u64, &ack, tlog.lastSeq(), .little);
                const ack_flags: u8 = if (has_more) wire.RANGE_FLAG_HAS_MORE else 0;
                try self.sendToPeer(peer, .ack, ack_flags, &ack);
            },
            .put_blob => {
                if (payload.len < 64) {
                    self.sendErr(peer, .bad_frame, "short put_blob");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                if (!self.checkPerm(peer, topic, wire.PERM_WRITE)) {
                    self.sendErr(peer, .unauthorized, "blob write denied");
                    return;
                }
                const oid: [32]u8 = payload[32..64].*;
                const opaque_bytes = payload[64..];
                if (opaque_bytes.len > MAX_OPAQUE_PAYLOAD) {
                    self.sendErr(peer, .bad_frame, "blob too large");
                    return;
                }
                try self.storeOpaqueBlob(topic, oid, opaque_bytes);
                var ack: [8]u8 = undefined;
                std.mem.writeInt(u64, &ack, opaque_bytes.len, .little);
                try self.sendToPeer(peer, .ack, 0, &ack);
            },
            .get_blob => {
                if (payload.len != 64) {
                    self.sendErr(peer, .bad_frame, "bad get_blob");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                if (!self.checkPerm(peer, topic, wire.PERM_READ)) {
                    self.sendErr(peer, .unauthorized, "blob read denied");
                    return;
                }
                const oid: [32]u8 = payload[32..64].*;
                if (try self.loadOpaqueBlob(topic, oid)) |bytes| {
                    defer self.allocator.free(bytes);
                    const resp = try self.allocator.alloc(u8, 33 + bytes.len);
                    defer self.allocator.free(resp);
                    @memcpy(resp[0..32], &oid);
                    resp[32] = 1;
                    if (bytes.len > 0) @memcpy(resp[33..], bytes);
                    try self.sendToPeer(peer, .blob_data, 0, resp);
                } else {
                    var resp: [33]u8 = undefined;
                    @memcpy(resp[0..32], &oid);
                    resp[32] = 0;
                    try self.sendToPeer(peer, .blob_data, 0, &resp);
                }
            },
            else => {
                self.sendErr(peer, .bad_frame, "unexpected op");
            },
        }
    }

    fn storeOpaqueBlob(self: *RelayServer, topic: TopicId, oid: [32]u8, data: []const u8) !void {
        const scoped = scopedBlobKey(topic, oid);
        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(scoped, &hex);
        if (self.blob_dir.statFile(self.io, &hex, .{})) |_| {
            return;
        } else |_| {}

        self.tmp_seq += 1;
        var tmp_buf: [96]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ hex, self.tmp_seq });
        const f = try self.blob_dir.createFile(self.io, tmp_name, .{ .truncate = true });
        var f_closed = false;
        errdefer {
            if (!f_closed) f.close(self.io);
            self.blob_dir.deleteFile(self.io, tmp_name) catch {};
        }
        try f.writePositionalAll(self.io, data, 0);
        if (self.durable_sync) try f.sync(self.io);
        f.close(self.io);
        f_closed = true;

        if (self.blob_dir.statFile(self.io, &hex, .{})) |_| {
            self.blob_dir.deleteFile(self.io, tmp_name) catch {};
            return;
        } else |_| {}
        try self.blob_dir.rename(tmp_name, self.blob_dir, &hex, self.io);
    }

    fn loadOpaqueBlob(self: *RelayServer, topic: TopicId, oid: [32]u8) !?[]u8 {
        const scoped = scopedBlobKey(topic, oid);
        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(scoped, &hex);
        const f = self.blob_dir.openFile(self.io, &hex, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size > MAX_OPAQUE_PAYLOAD) return error.BlobTooLarge;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        errdefer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n != buf.len) return error.ShortRead;
        return buf;
    }
};
