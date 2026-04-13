const std = @import("std");

/// Generic Compressed-Sparse-Row (CSR) index.
///
/// Stores a mapping from `num_buckets` bucket indices to sets of items.
/// `V` is the item type; it must be an integer or `enum(integer)` so that
/// item ordinals (0 .. num_items-1) can be stored directly.
///
/// Build once with `Csr(V).build(allocator, num_buckets, num_items, keys)`,
/// where `keys[i]` is the bucket index for item `i`.  After building,
/// `slice(b)` returns in O(1) the items assigned to bucket `b`.
///
/// Example:
///   const PinCsr = Csr(PinIdx);   // PinIdx is enum(u32)
///   var c = try PinCsr.build(allocator, num_nets, num_pins, net_of_each_pin);
///   defer c.deinit(allocator);
///   const pins_on_net_0 = c.slice(0);  // []const PinIdx
pub fn Csr(comptime V: type) type {
    comptime {
        switch (@typeInfo(V)) {
            .int, .@"enum" => {},
            else => @compileError("Csr value type must be an integer or enum(integer), got " ++ @typeName(V)),
        }
    }

    return struct {
        offsets: []u32,
        list: []V,

        const Self = @This();

        /// Build a CSR index from `keys[0..num_items]`.
        ///
        /// `keys[i]` is the bucket (row) for item `i`.  All keys must be in
        /// `[0, num_buckets)`.  After building, `slice(b)` returns the
        /// indices of all items whose key equals `b`.
        pub fn build(
            allocator: std.mem.Allocator,
            num_buckets: usize,
            num_items: usize,
            keys: []const u32,
        ) !Self {
            // Count items per bucket.
            const offsets = try allocator.alloc(u32, num_buckets + 1);
            errdefer allocator.free(offsets);
            @memset(offsets, 0);

            for (keys[0..num_items]) |k| {
                offsets[@intCast(k + 1)] += 1;
            }

            // Prefix sum → offsets[b] is the start of bucket b's region.
            for (1..num_buckets + 1) |i| {
                offsets[i] += offsets[i - 1];
            }

            // Scatter item ordinals into the list using a per-bucket cursor.
            const list = try allocator.alloc(V, num_items);
            errdefer allocator.free(list);

            const cursor = try allocator.alloc(u32, num_buckets);
            defer allocator.free(cursor);
            @memcpy(cursor, offsets[0..num_buckets]);

            for (0..num_items) |item_idx| {
                const b: usize = @intCast(keys[item_idx]);
                list[cursor[b]] = switch (@typeInfo(V)) {
                    .int => @intCast(item_idx),
                    .@"enum" => @enumFromInt(item_idx),
                    else => unreachable,
                };
                cursor[b] += 1;
            }

            return Self{ .offsets = offsets, .list = list };
        }

        /// Return the items assigned to bucket `idx` as a read-only slice.
        pub fn slice(self: *const Self, idx: usize) []const V {
            return self.list[self.offsets[idx]..self.offsets[idx + 1]];
        }

        /// Free all owned slices.  Does not store the allocator itself.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.offsets);
            allocator.free(self.list);
            self.* = undefined;
        }
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "Csr(u32) build and slice" {
    // 3 buckets, 5 items: item->bucket mapping: 0→0, 1→1, 2→0, 3→2, 4→1
    const keys = [_]u32{ 0, 1, 0, 2, 1 };
    var c = try Csr(u32).build(std.testing.allocator, 3, 5, &keys);
    defer c.deinit(std.testing.allocator);

    // Bucket 0: items 0 and 2
    try std.testing.expectEqual(@as(usize, 2), c.slice(0).len);
    // Bucket 1: items 1 and 4
    try std.testing.expectEqual(@as(usize, 2), c.slice(1).len);
    // Bucket 2: item 3
    try std.testing.expectEqual(@as(usize, 1), c.slice(2).len);
}

test "Csr(u32) empty" {
    var c = try Csr(u32).build(std.testing.allocator, 3, 0, &[_]u32{});
    defer c.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), c.slice(0).len);
    try std.testing.expectEqual(@as(usize, 0), c.slice(1).len);
    try std.testing.expectEqual(@as(usize, 0), c.slice(2).len);
}

test "Csr(u32) single bucket all items" {
    // All 4 items map to bucket 0.
    const keys = [_]u32{ 0, 0, 0, 0 };
    var c = try Csr(u32).build(std.testing.allocator, 2, 4, &keys);
    defer c.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), c.slice(0).len);
    try std.testing.expectEqual(@as(usize, 0), c.slice(1).len);
}

test "Csr with enum value type" {
    const MyIdx = enum(u32) {
        _,
        pub inline fn toInt(self: @This()) u32 { return @intFromEnum(self); }
        pub inline fn fromInt(v: u32) @This() { return @enumFromInt(v); }
    };
    const keys = [_]u32{ 0, 1, 0 };
    var c = try Csr(MyIdx).build(std.testing.allocator, 2, 3, &keys);
    defer c.deinit(std.testing.allocator);

    // Bucket 0: items 0 and 2 → MyIdx(0) and MyIdx(2)
    const b0 = c.slice(0);
    try std.testing.expectEqual(@as(usize, 2), b0.len);
    try std.testing.expectEqual(@as(u32, 0), b0[0].toInt());
    try std.testing.expectEqual(@as(u32, 2), b0[1].toInt());

    // Bucket 1: item 1 → MyIdx(1)
    const b1 = c.slice(1);
    try std.testing.expectEqual(@as(usize, 1), b1.len);
    try std.testing.expectEqual(@as(u32, 1), b1[0].toInt());
}

test "Csr item ordinals are preserved" {
    // 4 items, 3 buckets: each item maps to bucket (item % 3).
    const keys = [_]u32{ 0, 1, 2, 0 };
    var c = try Csr(u32).build(std.testing.allocator, 3, 4, &keys);
    defer c.deinit(std.testing.allocator);

    // Bucket 0 has items 0 and 3.
    const b0 = c.slice(0);
    try std.testing.expectEqual(@as(usize, 2), b0.len);
    // Items should be ordinals 0 and 3 (in some order).
    var found_0 = false;
    var found_3 = false;
    for (b0) |v| {
        if (v == 0) found_0 = true;
        if (v == 3) found_3 = true;
    }
    try std.testing.expect(found_0);
    try std.testing.expect(found_3);
}
