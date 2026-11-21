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

const Grant = struct {
    perms: u8,
    expires_ms: u64,
};

const PeerConn = struct {
    fd: posix.fd_t,
    rx: std.ArrayList(u8),
    tx: std.ArrayList(u8),
    tx_off: usize,
    perms: std.AutoHashMapUnmanaged(TopicId, Grant),
    subs: std.AutoHashMapUnmanaged(TopicId, void),

    fn init(fd: posix.fd_t) PeerConn {
        return .{
            .fd = fd,
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
        if (g.expires_ms != 0 and now_ms > g.expires_ms) return false;
        return (g.perms & mask) == mask;
    }

    fn queueBytes(self: *PeerConn, allocator: Allocator, data: []const u8) !void {
        const pending = self.tx.items.len - self.tx_off;
        if (pending + data.len > MAX_PEER_TX_BYTES) return error.TxBufferFull;
        try self.tx.appendSlice(allocator, data);
    }
};

pub const RelayServer = struct {
    allocator: Allocator,
    io: Io,
    auth_secret: [32]u8,
    require_auth: bool,
    durable_sync: bool,
    state_dir: Io.Dir,
    blob_dir: Io.Dir,
    listen_fd: posix.fd_t,
    epfd: posix.fd_t,
    port: u16,
    peers: std.AutoHashMapUnmanaged(posix.fd_t, *PeerConn),
    topics: std.AutoHashMapUnmanaged(TopicId, log_mod.AppendLog),
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

        return .{
            .allocator = allocator,
            .io = io,
            .auth_secret = auth_secret,
            .require_auth = require_auth,
            .durable_sync = true,
            .state_dir = state_dir,
            .blob_dir = blob_dir,
            .listen_fd = listen_fd,
            .epfd = epfd,
            .port = actual_port,
            .peers = .empty,
            .topics = .empty,
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
        {
            var it = self.topics.valueIterator();
            while (it.next()) |t| t.deinit();
            self.topics.deinit(self.allocator);
        }
        _ = linux.close(self.epfd);
        _ = linux.close(self.listen_fd);
        self.blob_dir.close(self.io);
        self.state_dir.close(self.io);
    }

    pub fn stop(self: *RelayServer) void {
        self.running.store(false, .release);
    }

    pub fn run(self: *RelayServer) !void {
        while (self.running.load(.acquire)) {
            _ = try self.step(100);
        }
    }

    pub fn step(self: *RelayServer, timeout_ms: i32) !usize {
        var events: [64]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(self.epfd, &events, events.len, timeout_ms);
        const e = linux.errno(rc);
        if (e == .INTR) return 0;
        if (e != .SUCCESS) return error.EpollWaitFailed;
        const n: usize = rc;
        for (events[0..n]) |ev| {
            const fd = ev.data.fd;
            if (fd == self.listen_fd) {
                self.acceptLoop();
            } else {
                self.handlePeerEvent(fd, ev.events);
            }
        }
        return n;
    }

    fn acceptLoop(self: *RelayServer) void {
        while (true) {
            const rc = linux.accept4(self.listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            const e = linux.errno(rc);
            if (e == .AGAIN or e == .INTR) break;
            if (e != .SUCCESS) break;
            const cfd: posix.fd_t = @intCast(rc);
            if (self.peers.count() >= MAX_PEERS) {
                _ = linux.close(cfd);
                continue;
            }
            var one: i32 = 1;
            _ = linux.setsockopt(cfd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));

            const peer = self.allocator.create(PeerConn) catch {
                _ = linux.close(cfd);
                continue;
            };
            peer.* = PeerConn.init(cfd);
            self.peers.put(self.allocator, cfd, peer) catch {
                peer.deinit(self.allocator);
                self.allocator.destroy(peer);
                continue;
            };

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .fd = cfd },
            };
            if (linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, cfd, &ev)) != .SUCCESS) {
                self.dropPeer(cfd);
            }
        }
    }

    fn dropPeer(self: *RelayServer, fd: posix.fd_t) void {
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
        if (self.peers.fetchRemove(fd)) |kv| {
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }
    }

    fn updatePeerEpoll(self: *RelayServer, peer: *PeerConn) void {
        var mask: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
        if (peer.tx_off < peer.tx.items.len) mask |= linux.EPOLL.OUT;
        var ev = linux.epoll_event{ .events = mask, .data = .{ .fd = peer.fd } };
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, peer.fd, &ev);
    }

    fn flushPeerTx(self: *RelayServer, peer: *PeerConn) bool {
        while (peer.tx_off < peer.tx.items.len) {
            const rem = peer.tx.items[peer.tx_off..];
            const rc = linux.sendto(peer.fd, rem.ptr, rem.len, linux.MSG.NOSIGNAL, null, 0);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) {
                self.updatePeerEpoll(peer);
                return true;
            }
            if (e != .SUCCESS or rc == 0) return false;
            peer.tx_off += rc;
        }
        peer.tx.clearRetainingCapacity();
        peer.tx_off = 0;
        self.updatePeerEpoll(peer);
        return true;
    }

    fn sendToPeer(self: *RelayServer, peer: *PeerConn, op: wire.Op, flags: u8, payload: []const u8) !void {
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
        if ((revents & (linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0) {
            self.dropPeer(fd);
            return;
        }
        if ((revents & linux.EPOLL.OUT) != 0) {
            if (!self.flushPeerTx(peer)) {
                self.dropPeer(fd);
                return;
            }
        }
        if ((revents & linux.EPOLL.IN) != 0) {
            var tmp: [16384]u8 = undefined;
            while (true) {
                const rc = linux.read(fd, &tmp, tmp.len);
                const e = linux.errno(rc);
                if (e == .INTR) continue;
                if (e == .AGAIN) break;
                if (e != .SUCCESS or rc == 0) {
                    self.dropPeer(fd);
                    return;
                }
                if (peer.rx.items.len + rc > MAX_PEER_RX_BYTES) {
                    self.dropPeer(fd);
                    return;
                }
                peer.rx.appendSlice(self.allocator, tmp[0..rc]) catch {
                    self.dropPeer(fd);
                    return;
                };
            }
            self.processPeerRx(peer) catch {
                self.dropPeer(fd);
                return;
            };
        }
    }

    fn processPeerRx(self: *RelayServer, peer: *PeerConn) !void {
        var consumed: usize = 0;
        while (consumed < peer.rx.items.len) {
            const avail = peer.rx.items[consumed..];
            const hdr = (try wire.decodeHeader(avail)) orelse break;
            const total = wire.WIRE_HEADER_LEN + hdr.len;
            if (avail.len < total) break;
            const payload = avail[wire.WIRE_HEADER_LEN..total];
            try self.dispatchFrame(peer, hdr.op, payload);
            consumed += total;
        }
        if (consumed > 0) {
            const rem = peer.rx.items.len - consumed;
            if (rem > 0) {
                std.mem.copyForwards(u8, peer.rx.items[0..rem], peer.rx.items[consumed..]);
            }
            peer.rx.items.len = rem;
        }
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
        switch (op) {
            .auth => {
                if (payload.len != 32 + 1 + 8 + 32) {
                    self.sendErr(peer, .bad_frame, "bad auth");
                    return;
                }
                const topic: TopicId = payload[0..32].*;
                const perms = payload[32];
                const expires = std.mem.readInt(u64, payload[33..41], .little);
                const mac: crypto.Mac = payload[41..73].*;
                if (self.require_auth and !crypto.verifyCapabilityToken(self.auth_secret, topic, perms, expires, mac, id.nowMs(self.io))) {
                    self.sendErr(peer, .unauthorized, "invalid token");
                    return;
                }
                if (peer.perms.getPtr(topic)) |existing| {
                    existing.perms |= perms;
                    existing.expires_ms = if (existing.expires_ms == 0 or expires == 0) 0 else @max(existing.expires_ms, expires);
                } else {
                    try peer.perms.put(self.allocator, topic, .{ .perms = perms, .expires_ms = expires });
                }
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
                var dead_fds: std.ArrayList(posix.fd_t) = .empty;
                defer dead_fds.deinit(self.allocator);
                var pit = self.peers.valueIterator();
                while (pit.next()) |other_ptr| {
                    const other = other_ptr.*;
                    if (other.subs.contains(topic)) {
                        if (self.require_auth and !other.hasPerm(topic, wire.PERM_SUB, now_ms)) {
                            _ = other.subs.remove(topic);
                            continue;
                        }
                        other.queueBytes(self.allocator, encoded_ev) catch {
                            if (other.fd != peer.fd) dead_fds.append(self.allocator, other.fd) catch {};
                            continue;
                        };
                        if (!self.flushPeerTx(other)) {
                            if (other.fd != peer.fd) dead_fds.append(self.allocator, other.fd) catch {};
                        }
                    }
                }
                for (dead_fds.items) |dead_fd| {
                    self.dropPeer(dead_fd);
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
                const total = tlog.count();
                const start_idx: usize = if (after_seq == std.math.maxInt(u64))
                    total
                else
                    tlog.findIndexBySeq(after_seq + 1);
                for (start_idx..total) |idx| {
                    if (limit > 0 and sent >= limit) break;
                    const view = tlog.readAt(idx) catch {
                        self.sendErr(peer, .internal, "range read failed");
                        return;
                    };
                    const ev_payload = try self.allocator.alloc(u8, 32 + 8 + view.payload.len);
                    defer self.allocator.free(ev_payload);
                    @memcpy(ev_payload[0..32], &topic);
                    std.mem.writeInt(u64, ev_payload[32..40], view.header.seq, .little);
                    if (view.payload.len > 0) @memcpy(ev_payload[40..], view.payload);
                    try self.sendToPeer(peer, .range_item, 0, ev_payload);
                    sent += 1;
                }
                var end_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &end_buf, tlog.lastSeq(), .little);
                try self.sendToPeer(peer, .range_end, 0, &end_buf);
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

                const total = tlog.count();
                const start_idx: usize = if (after_seq == std.math.maxInt(u64))
                    total
                else
                    tlog.findIndexBySeq(after_seq + 1);
                for (start_idx..total) |idx| {
                    const view = tlog.readAt(idx) catch {
                        self.sendErr(peer, .internal, "subscribe read failed");
                        return;
                    };
                    const ev_payload = try self.allocator.alloc(u8, 32 + 8 + view.payload.len);
                    defer self.allocator.free(ev_payload);
                    @memcpy(ev_payload[0..32], &topic);
                    std.mem.writeInt(u64, ev_payload[32..40], view.header.seq, .little);
                    if (view.payload.len > 0) @memcpy(ev_payload[40..], view.payload);
                    try self.sendToPeer(peer, .range_item, 0, ev_payload);
                }
                var ack: [8]u8 = undefined;
                std.mem.writeInt(u64, &ack, tlog.lastSeq(), .little);
                try self.sendToPeer(peer, .ack, 0, &ack);
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
                try self.storeOpaqueBlob(oid, opaque_bytes);
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
                if (try self.loadOpaqueBlob(oid)) |bytes| {
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

    fn storeOpaqueBlob(self: *RelayServer, oid: [32]u8, data: []const u8) !void {
        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(oid, &hex);
        var tmp_buf: [80]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{hex});
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
        try self.blob_dir.rename(tmp_name, self.blob_dir, &hex, self.io);
    }

    fn loadOpaqueBlob(self: *RelayServer, oid: [32]u8) !?[]u8 {
        var hex: [64]u8 = undefined;
        _ = id.formatHashHex(oid, &hex);
        const f = self.blob_dir.openFile(self.io, &hex, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer f.close(self.io);
        const st = try f.stat(self.io);
        if (st.size > wire.MAX_FRAME_LEN) return error.BlobTooLarge;
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        errdefer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);
        if (n != buf.len) return error.ShortRead;
        return buf;
    }
};
