const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Splice = struct {
    at: u64,
    del: u64,
    ins: u64,
};

pub const DiffResult = struct {
    splices: std.ArrayList(Splice) = .empty,
    inserted: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *DiffResult, allocator: Allocator) void {
        self.splices.deinit(allocator);
        self.inserted.deinit(allocator);
    }
};

const Line = struct {
    start: usize,
    len: usize,
    hash: u64,
};

const HistoEntry = struct {
    count: u32,
    head: u32,
};

const Snake = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    found: bool,
};

const HISTO_MAX_CHAIN: u32 = 64;

fn splitLines(allocator: Allocator, bytes: []const u8) Allocator.Error![]Line {
    var list: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b == '\n') {
            const slice = bytes[start .. i + 1];
            try list.append(allocator, .{
                .start = start,
                .len = slice.len,
                .hash = std.hash.Wyhash.hash(0, slice),
            });
            start = i + 1;
        }
    }
    if (start < bytes.len) {
        const slice = bytes[start..];
        try list.append(allocator, .{
            .start = start,
            .len = slice.len,
            .hash = std.hash.Wyhash.hash(0, slice),
        });
    }
    return list.toOwnedSlice(allocator);
}

fn linesEqual(old: []const u8, new: []const u8, a: Line, b: Line) bool {
    if (a.hash != b.hash or a.len != b.len) return false;
    return std.mem.eql(u8, old[a.start .. a.start + a.len], new[b.start .. b.start + b.len]);
}

inline fn isUtf8Cont(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

fn appendTrimmedSplice(
    allocator: Allocator,
    res: *DiffResult,
    old: []const u8,
    new: []const u8,
    raw_old_start: usize,
    raw_old_end: usize,
    raw_new_start: usize,
    raw_new_end: usize,
) Allocator.Error!void {
    var old_s = raw_old_start;
    var old_e = raw_old_end;
    var new_s = raw_new_start;
    var new_e = raw_new_end;

    while (old_s < old_e and new_s < new_e and old[old_s] == new[new_s]) {
        old_s += 1;
        new_s += 1;
    }
    while (old_s > raw_old_start and new_s > raw_new_start and
        ((old_s < old_e and isUtf8Cont(old[old_s])) or (new_s < new_e and isUtf8Cont(new[new_s]))))
    {
        old_s -= 1;
        new_s -= 1;
    }

    while (old_e > old_s and new_e > new_s and old[old_e - 1] == new[new_e - 1]) {
        old_e -= 1;
        new_e -= 1;
    }
    while (old_e < raw_old_end and new_e < raw_new_end and
        (isUtf8Cont(old[old_e]) or isUtf8Cont(new[new_e])))
    {
        old_e += 1;
        new_e += 1;
    }

    const del_len = old_e - old_s;
    const ins_slice = new[new_s..new_e];
    if (del_len == 0 and ins_slice.len == 0) return;

    try res.splices.append(allocator, .{
        .at = old_s,
        .del = del_len,
        .ins = ins_slice.len,
    });
    try res.inserted.appendSlice(allocator, ins_slice);
}

const DiffCtx = struct {
    out_alloc: Allocator,
    scratch: Allocator,
    old: []const u8,
    new: []const u8,
    old_lines: []const Line,
    new_lines: []const Line,
    res: *DiffResult,

    fn lineByteStart(lines: []const Line, idx: usize, total_len: usize) usize {
        return if (idx < lines.len) lines[idx].start else total_len;
    }

    fn emitRange(self: *DiffCtx, oa: usize, ob: usize, na: usize, nb: usize) Allocator.Error!void {
        const old_s = lineByteStart(self.old_lines, oa, self.old.len);
        const old_e = lineByteStart(self.old_lines, ob, self.old.len);
        const new_s = lineByteStart(self.new_lines, na, self.new.len);
        const new_e = lineByteStart(self.new_lines, nb, self.new.len);
        try appendTrimmedSplice(self.out_alloc, self.res, self.old, self.new, old_s, old_e, new_s, new_e);
    }

    fn eq(self: *const DiffCtx, oi: usize, ni: usize) bool {
        return linesEqual(self.old, self.new, self.old_lines[oi], self.new_lines[ni]);
    }

    fn diffRange(self: *DiffCtx, raw_oa: usize, raw_ob: usize, raw_na: usize, raw_nb: usize) Allocator.Error!void {
        var oa = raw_oa;
        var ob = raw_ob;
        var na = raw_na;
        var nb = raw_nb;

        while (oa < ob and na < nb and self.eq(oa, na)) {
            oa += 1;
            na += 1;
        }
        while (ob > oa and nb > na and self.eq(ob - 1, nb - 1)) {
            ob -= 1;
            nb -= 1;
        }

        const n_len = ob - oa;
        const m_len = nb - na;
        if (n_len == 0 and m_len == 0) return;
        if (n_len == 0 or m_len == 0 or (n_len == 1 and m_len == 1)) {
            try self.emitRange(oa, ob, na, nb);
            return;
        }

        const AnchorResult = struct {
            kind: enum { disjoint, found, crowded },
            os: usize = 0,
            ns: usize = 0,
            len: usize = 0,
        };

        const anchor: AnchorResult = blk: {
            var table = std.AutoHashMapUnmanaged(u64, HistoEntry){};
            defer table.deinit(self.scratch);
            try table.ensureTotalCapacity(self.scratch, @intCast(@min(n_len, 1 << 20)));

            const next_pos = try self.scratch.alloc(u32, n_len);
            defer self.scratch.free(next_pos);

            var i: usize = n_len;
            while (i > 0) {
                i -= 1;
                const h = self.old_lines[oa + i].hash;
                const gop = try table.getOrPut(self.scratch, h);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .count = 1, .head = @intCast(i) };
                    next_pos[i] = std.math.maxInt(u32);
                } else {
                    gop.value_ptr.count +|= 1;
                    next_pos[i] = gop.value_ptr.head;
                    gop.value_ptr.head = @intCast(i);
                }
            }

            var has_any_match = false;
            var has_low_match = false;
            var best_count: u32 = HISTO_MAX_CHAIN + 1;
            var best_len: usize = 0;
            var best_os: usize = 0;
            var best_ns: usize = 0;

            var b_idx: usize = 0;
            while (b_idx < m_len) {
                const bh = self.new_lines[na + b_idx].hash;
                const entry = table.get(bh) orelse {
                    b_idx += 1;
                    continue;
                };
                if (entry.count > HISTO_MAX_CHAIN) {
                    var scan = entry.head;
                    var checked: u32 = 0;
                    while (scan != std.math.maxInt(u32) and checked < 16) : (checked += 1) {
                        if (self.eq(oa + scan, na + b_idx)) {
                            has_any_match = true;
                            break;
                        }
                        scan = next_pos[scan];
                    }
                    b_idx += 1;
                    continue;
                }

                var next_b = b_idx + 1;
                var cur = entry.head;
                while (cur != std.math.maxInt(u32)) {
                    const a_idx: usize = cur;
                    cur = next_pos[cur];
                    if (!self.eq(oa + a_idx, na + b_idx)) continue;
                    has_any_match = true;

                    var as = a_idx;
                    var bs = b_idx;
                    var min_cnt = entry.count;
                    while (as > 0 and bs > 0 and self.eq(oa + as - 1, na + bs - 1)) {
                        as -= 1;
                        bs -= 1;
                        if (table.get(self.old_lines[oa + as].hash)) |pe| {
                            if (pe.count < min_cnt) min_cnt = pe.count;
                        }
                    }
                    var ae = a_idx + 1;
                    var be = b_idx + 1;
                    while (ae < n_len and be < m_len and self.eq(oa + ae, na + be)) {
                        if (table.get(self.old_lines[oa + ae].hash)) |ne| {
                            if (ne.count < min_cnt) min_cnt = ne.count;
                        }
                        ae += 1;
                        be += 1;
                    }
                    if (be > next_b) next_b = be;
                    const run_len = ae - as;
                    if (!has_low_match or min_cnt < best_count or (min_cnt == best_count and run_len > best_len)) {
                        has_low_match = true;
                        best_count = min_cnt;
                        best_len = run_len;
                        best_os = oa + as;
                        best_ns = na + bs;
                    }
                }
                b_idx = next_b;
            }

            if (!has_any_match) break :blk .{ .kind = .disjoint };
            if (has_low_match) break :blk .{ .kind = .found, .os = best_os, .ns = best_ns, .len = best_len };
            break :blk .{ .kind = .crowded };
        };

        switch (anchor.kind) {
            .disjoint => {
                try self.emitRange(oa, ob, na, nb);
                return;
            },
            .found => {
                try self.diffRange(oa, anchor.os, na, anchor.ns);
                try self.diffRange(anchor.os + anchor.len, ob, anchor.ns + anchor.len, nb);
                return;
            },
            .crowded => {},
        }

        const snake = try self.findMiddleSnake(oa, n_len, na, m_len);
        if (!snake.found) {
            try self.emitRange(oa, ob, na, nb);
            return;
        }
        try self.diffRange(oa, oa + snake.x0, na, na + snake.y0);
        try self.diffRange(oa + snake.x1, ob, na + snake.y1, nb);
    }

    fn findMiddleSnake(self: *DiffCtx, oa: usize, n_len: usize, na: usize, m_len: usize) Allocator.Error!Snake {
        const n_i: isize = @intCast(n_len);
        const m_i: isize = @intCast(m_len);
        const delta: isize = n_i - m_i;
        const odd = (@mod(delta, 2) != 0);
        const max_d: usize = (n_len + m_len + 1) / 2;
        const v_len: usize = 2 * max_d + 3;
        const off: isize = @intCast(max_d + 1);

        const vf = try self.scratch.alloc(isize, v_len);
        defer self.scratch.free(vf);
        const vb = try self.scratch.alloc(isize, v_len);
        defer self.scratch.free(vb);
        @memset(vf, 0);
        @memset(vb, 0);

        var d: usize = 0;
        while (d <= max_d) : (d += 1) {
            const d_i: isize = @intCast(d);

            var k: isize = -d_i;
            while (k <= d_i) : (k += 2) {
                const down = (k == -d_i) or (k != d_i and vf[@intCast(k - 1 + off)] < vf[@intCast(k + 1 + off)]);
                const x_start = if (down) vf[@intCast(k + 1 + off)] else vf[@intCast(k - 1 + off)] + 1;
                const y_start = x_start - k;
                var x = x_start;
                var y = y_start;
                while (x < n_i and y < m_i and x >= 0 and y >= 0 and self.eq(oa + @as(usize, @intCast(x)), na + @as(usize, @intCast(y)))) {
                    x += 1;
                    y += 1;
                }
                vf[@intCast(k + off)] = x;

                if (odd and d > 0) {
                    const bk = delta - k;
                    if (bk >= -(d_i - 1) and bk <= (d_i - 1)) {
                        const bx = vb[@intCast(bk + off)];
                        if (x + bx >= n_i) {
                            const cx0: usize = @intCast(@max(0, @min(x_start, n_i)));
                            const cy0: usize = @intCast(@max(0, @min(y_start, m_i)));
                            const cx1: usize = @intCast(@max(0, @min(x, n_i)));
                            const cy1: usize = @intCast(@max(0, @min(y, m_i)));
                            if ((cx0 + cy0 > 0) and (cx1 + cy1 < n_len + m_len)) {
                                return .{ .x0 = cx0, .y0 = cy0, .x1 = cx1, .y1 = cy1, .found = true };
                            }
                            return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .found = false };
                        }
                    }
                }
            }

            var c: isize = -d_i;
            while (c <= d_i) : (c += 2) {
                const down = (c == -d_i) or (c != d_i and vb[@intCast(c - 1 + off)] < vb[@intCast(c + 1 + off)]);
                const u_start = if (down) vb[@intCast(c + 1 + off)] else vb[@intCast(c - 1 + off)] + 1;
                const v_start = u_start - c;
                var u = u_start;
                var v = v_start;
                while (u < n_i and v < m_i and u >= 0 and v >= 0 and self.eq(oa + @as(usize, @intCast(n_i - 1 - u)), na + @as(usize, @intCast(m_i - 1 - v)))) {
                    u += 1;
                    v += 1;
                }
                vb[@intCast(c + off)] = u;

                if (!odd) {
                    const fk = delta - c;
                    if (fk >= -d_i and fk <= d_i) {
                        const fx = vf[@intCast(fk + off)];
                        if (fx + u >= n_i) {
                            const cx0: usize = @intCast(@max(0, @min(n_i - u, n_i)));
                            const cy0: usize = @intCast(@max(0, @min(m_i - v, m_i)));
                            const cx1: usize = @intCast(@max(0, @min(n_i - u_start, n_i)));
                            const cy1: usize = @intCast(@max(0, @min(m_i - v_start, m_i)));
                            if ((cx0 + cy0 > 0) and (cx1 + cy1 < n_len + m_len)) {
                                return .{ .x0 = cx0, .y0 = cy0, .x1 = cx1, .y1 = cy1, .found = true };
                            }
                            return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .found = false };
                        }
                    }
                }
            }
        }
        return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .found = false };
    }
};

pub fn diffBytes(allocator: Allocator, old: []const u8, new: []const u8) Allocator.Error!DiffResult {
    var res = DiffResult{};
    errdefer res.deinit(allocator);

    if (std.mem.eql(u8, old, new)) return res;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const old_lines = try splitLines(scratch, old);
    const new_lines = try splitLines(scratch, new);

    var ctx = DiffCtx{
        .out_alloc = allocator,
        .scratch = scratch,
        .old = old,
        .new = new,
        .old_lines = old_lines,
        .new_lines = new_lines,
        .res = &res,
    };
    try ctx.diffRange(0, old_lines.len, 0, new_lines.len);
    return res;
}
