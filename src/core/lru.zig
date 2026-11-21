const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DEFAULT_ENTRY_OVERHEAD: usize = 96;

pub const Config = struct {
    budget_bytes: usize,
    max_entries: usize = std.math.maxInt(usize),
    entry_overhead: usize = DEFAULT_ENTRY_OVERHEAD,
};

pub fn LruCache(
    comptime K: type,
    comptime V: type,
    comptime sizeFn: anytype,
    comptime deinitFn: anytype,
) type {
    return LruCacheContext(K, V, std.hash_map.AutoContext(K), sizeFn, deinitFn);
}

pub fn LruCacheContext(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime sizeFn: anytype,
    comptime deinitFn: anytype,
) type {
    return struct {
        const Self = @This();
        const Map = std.HashMapUnmanaged(K, *Node, Context, std.hash_map.default_max_load_percentage);

        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node,
            next: ?*Node,
        };

        allocator: Allocator,
        budget_bytes: usize,
        max_entries: usize,
        entry_overhead: usize,
        used_bytes: usize,
        pin_depth: u32,
        head: ?*Node,
        tail: ?*Node,
        map: Map,

        pub fn init(allocator: Allocator, config: Config) Self {
            return .{
                .allocator = allocator,
                .budget_bytes = config.budget_bytes,
                .max_entries = config.max_entries,
                .entry_overhead = config.entry_overhead,
                .used_bytes = 0,
                .pin_depth = 0,
                .head = null,
                .tail = null,
                .map = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.map.deinit(self.allocator);
        }

        pub fn beginPinScope(self: *Self) void {
            self.pin_depth += 1;
        }

        pub fn endPinScope(self: *Self) void {
            std.debug.assert(self.pin_depth > 0);
            self.pin_depth -= 1;
            if (self.pin_depth == 0) {
                self.evictToBudget();
            }
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        pub fn get(self: *Self, key: K) ?*V {
            const node = self.map.get(key) orelse return null;
            self.moveToFront(node);
            return &node.value;
        }

        pub fn getConst(self: *const Self, key: K) ?*const V {
            const node = self.map.get(key) orelse return null;
            return &node.value;
        }

        pub fn put(self: *Self, key: K, val: V) !*V {
            if (self.map.get(key)) |existing| {
                const old_bytes = self.entryBytes(&existing.value);
                callDeinit(self.allocator, &existing.value);
                existing.value = val;
                const new_bytes = self.entryBytes(&existing.value);
                self.used_bytes = self.used_bytes - old_bytes + new_bytes;
                self.moveToFront(existing);
                if (self.pin_depth == 0) {
                    self.evictToBudgetExcluding(existing);
                }
                return &existing.value;
            }

            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.* = .{
                .key = key,
                .value = val,
                .prev = null,
                .next = null,
            };
            try self.map.put(self.allocator, key, node);
            self.pushFront(node);
            self.used_bytes += self.entryBytes(&node.value);

            if (self.pin_depth == 0) {
                self.evictToBudgetExcluding(node);
            }
            return &node.value;
        }

        pub fn remove(self: *Self, key: K) bool {
            const kv = self.map.fetchRemove(key) orelse return false;
            const node = kv.value;
            self.unlink(node);
            self.used_bytes -= self.entryBytes(&node.value);
            callDeinit(self.allocator, &node.value);
            self.allocator.destroy(node);
            return true;
        }

        pub fn take(self: *Self, key: K) ?V {
            const kv = self.map.fetchRemove(key) orelse return null;
            const node = kv.value;
            self.unlink(node);
            self.used_bytes -= self.entryBytes(&node.value);
            const val = node.value;
            self.allocator.destroy(node);
            return val;
        }

        pub fn evictToBudget(self: *Self) void {
            self.evictToBudgetExcluding(null);
        }

        pub fn clear(self: *Self) void {
            var cur = self.head;
            while (cur) |node| {
                const nxt = node.next;
                callDeinit(self.allocator, &node.value);
                self.allocator.destroy(node);
                cur = nxt;
            }
            self.head = null;
            self.tail = null;
            self.used_bytes = 0;
            self.map.clearRetainingCapacity();
        }

        fn evictToBudgetExcluding(self: *Self, protected: ?*Node) void {
            if (self.pin_depth > 0) return;
            while (self.used_bytes > self.budget_bytes or self.map.count() > self.max_entries) {
                var victim = self.tail orelse break;
                if (protected != null and victim == protected.?) {
                    victim = victim.prev orelse break;
                }
                self.unlink(victim);
                _ = self.map.remove(victim.key);
                self.used_bytes -= self.entryBytes(&victim.value);
                callDeinit(self.allocator, &victim.value);
                self.allocator.destroy(victim);
            }
        }

        fn entryBytes(self: *const Self, val: *const V) usize {
            return callSize(val) + self.entry_overhead;
        }

        fn callSize(val: *const V) usize {
            if (@TypeOf(sizeFn) == @TypeOf(null)) return 0;
            const fn_info = @typeInfo(@TypeOf(sizeFn)).@"fn";
            if (fn_info.param_types[0] == *const V) {
                return sizeFn(val);
            }
            return sizeFn(val.*);
        }

        fn callDeinit(allocator: Allocator, val: *V) void {
            if (@TypeOf(deinitFn) == @TypeOf(null)) return;
            const fn_info = @typeInfo(@TypeOf(deinitFn)).@"fn";
            if (fn_info.param_types.len == 2) {
                if (fn_info.param_types[1] == *V) {
                    deinitFn(allocator, val);
                } else {
                    deinitFn(allocator, val.*);
                }
            } else if (fn_info.param_types.len == 1) {
                if (fn_info.param_types[0] == *V) {
                    deinitFn(val);
                } else {
                    deinitFn(val.*);
                }
            }
        }

        fn unlink(self: *Self, node: *Node) void {
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
            node.prev = null;
            node.next = null;
        }

        fn pushFront(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;
            if (self.head) |h| {
                h.prev = node;
            } else {
                self.tail = node;
            }
            self.head = node;
        }

        fn moveToFront(self: *Self, node: *Node) void {
            if (self.head == node) return;
            self.unlink(node);
            self.pushFront(node);
        }
    };
}
