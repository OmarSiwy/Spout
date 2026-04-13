const std = @import("std");
const types = @import("types.zig");

const ConstraintType = types.ConstraintType;
const DeviceIdx = types.DeviceIdx;

pub const ConstraintArrays = struct {
    types:    []ConstraintType,
    device_a: []DeviceIdx,
    device_b: []DeviceIdx,
    weight:   []f32,
    axis:     []f32,
    group_id: []u32,      // 0 = ungrouped; 1..N = symmetry axis group
    allocator: std.mem.Allocator,
    len:      u32,
    capacity: u32,

    pub fn init(allocator: std.mem.Allocator, count: u32) !ConstraintArrays {
        const n: usize = @intCast(count);

        const ctypes = try allocator.alloc(ConstraintType, n);
        errdefer allocator.free(ctypes);
        @memset(ctypes, .symmetry);

        const da = try allocator.alloc(DeviceIdx, n);
        errdefer allocator.free(da);
        @memset(da, DeviceIdx.fromInt(0));

        const db = try allocator.alloc(DeviceIdx, n);
        errdefer allocator.free(db);
        @memset(db, DeviceIdx.fromInt(0));

        const w = try allocator.alloc(f32, n);
        errdefer allocator.free(w);
        @memset(w, 0.0);

        const ax = try allocator.alloc(f32, n);
        errdefer allocator.free(ax);
        @memset(ax, 0.0);

        const gid = try allocator.alloc(u32, n);
        errdefer allocator.free(gid);
        @memset(gid, 0);

        return ConstraintArrays{
            .types    = ctypes,
            .device_a = da,
            .device_b = db,
            .weight   = w,
            .axis     = ax,
            .group_id = gid,
            .allocator = allocator,
            .len      = count,
            .capacity = count,
        };
    }

    fn growTo(self: *ConstraintArrays, new_cap: u32) !void {
        const nc: usize = @intCast(new_cap);
        self.types    = try self.allocator.realloc(self.types,    nc);
        self.device_a = try self.allocator.realloc(self.device_a, nc);
        self.device_b = try self.allocator.realloc(self.device_b, nc);
        self.weight   = try self.allocator.realloc(self.weight,   nc);
        self.axis     = try self.allocator.realloc(self.axis,     nc);
        self.group_id = try self.allocator.realloc(self.group_id, nc);
        self.capacity = new_cap;
    }

    pub fn append(
        self:   *ConstraintArrays,
        ctype:  ConstraintType,
        dev_a:  DeviceIdx,
        dev_b:  DeviceIdx,
        w:      f32,
        ax:     f32,
        gid:    u32,
    ) !void {
        if (self.len >= self.capacity) {
            const new_cap = if (self.capacity == 0) @as(u32, 8) else self.capacity * 2;
            try self.growTo(new_cap);
        }
        const i: usize = @intCast(self.len);
        self.types[i]    = ctype;
        self.device_a[i] = dev_a;
        self.device_b[i] = dev_b;
        self.weight[i]   = w;
        self.axis[i]     = ax;
        self.group_id[i] = gid;
        self.len += 1;
    }

    pub fn deinit(self: *ConstraintArrays) void {
        if (self.capacity > 0) {
            self.allocator.free(self.types);
            self.allocator.free(self.device_a);
            self.allocator.free(self.device_b);
            self.allocator.free(self.weight);
            self.allocator.free(self.axis);
            self.allocator.free(self.group_id);
        }
        self.* = undefined;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "ConstraintArrays init and deinit" {
    var ca = try ConstraintArrays.init(std.testing.allocator, 2);
    defer ca.deinit();

    try std.testing.expectEqual(@as(u32, 2), ca.len);
    try std.testing.expectEqual(@as(u32, 2), ca.capacity);
}

test "ConstraintArrays append grows" {
    var ca = try ConstraintArrays.init(std.testing.allocator, 0);
    defer ca.deinit();

    try ca.append(.symmetry, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 1.0, 0.0, 0);
    try std.testing.expectEqual(@as(u32, 1), ca.len);

    try ca.append(.matching, DeviceIdx.fromInt(2), DeviceIdx.fromInt(3), 0.5, 90.0, 0);
    try std.testing.expectEqual(@as(u32, 2), ca.len);

    // Verify stored values.
    try std.testing.expectEqual(ConstraintType.symmetry, ca.types[0]);
    try std.testing.expectEqual(ConstraintType.matching, ca.types[1]);
    try std.testing.expectEqual(@as(f32, 90.0), ca.axis[1]);
}

test "ConstraintArrays append beyond initial capacity" {
    var ca = try ConstraintArrays.init(std.testing.allocator, 0);
    defer ca.deinit();

    // Append more than the initial grow size (8).
    for (0..10) |i| {
        try ca.append(.proximity, DeviceIdx.fromInt(@intCast(i)), DeviceIdx.fromInt(@intCast(i + 1)), 1.0, 0.0, 0);
    }
    try std.testing.expectEqual(@as(u32, 10), ca.len);
    try std.testing.expect(ca.capacity >= 10);
}

test "ConstraintArrays append 10 constraints verify len and capacity growth" {
    var ca = try ConstraintArrays.init(std.testing.allocator, 0);
    defer ca.deinit();

    // Initial state
    try std.testing.expectEqual(@as(u32, 0), ca.len);
    try std.testing.expectEqual(@as(u32, 0), ca.capacity);

    // First append triggers growth from 0 to 8
    try ca.append(.symmetry, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 1.0, 0.0, 0);
    try std.testing.expectEqual(@as(u32, 1), ca.len);
    try std.testing.expectEqual(@as(u32, 8), ca.capacity);

    // Fill up to 8
    for (1..8) |i| {
        try ca.append(.matching, DeviceIdx.fromInt(@intCast(i)), DeviceIdx.fromInt(@intCast(i + 1)), 0.8, 45.0, 0);
    }
    try std.testing.expectEqual(@as(u32, 8), ca.len);
    try std.testing.expectEqual(@as(u32, 8), ca.capacity);

    // 9th append triggers growth from 8 to 16
    try ca.append(.proximity, DeviceIdx.fromInt(8), DeviceIdx.fromInt(9), 0.5, 90.0, 0);
    try std.testing.expectEqual(@as(u32, 9), ca.len);
    try std.testing.expectEqual(@as(u32, 16), ca.capacity);

    // 10th append stays within capacity 16
    try ca.append(.isolation, DeviceIdx.fromInt(9), DeviceIdx.fromInt(10), 0.3, 180.0, 0);
    try std.testing.expectEqual(@as(u32, 10), ca.len);
    try std.testing.expectEqual(@as(u32, 16), ca.capacity);

    // Verify stored values for first and last
    try std.testing.expectEqual(ConstraintType.symmetry, ca.types[0]);
    try std.testing.expectEqual(@as(f32, 1.0), ca.weight[0]);
    try std.testing.expectEqual(ConstraintType.isolation, ca.types[9]);
    try std.testing.expectEqual(@as(f32, 0.3), ca.weight[9]);
    try std.testing.expectEqual(@as(f32, 180.0), ca.axis[9]);
}

test "ConstraintArrays init with non-zero count pre-populates" {
    var ca = try ConstraintArrays.init(std.testing.allocator, 5);
    defer ca.deinit();

    try std.testing.expectEqual(@as(u32, 5), ca.len);
    try std.testing.expectEqual(@as(u32, 5), ca.capacity);

    // Default values
    for (0..5) |i| {
        try std.testing.expectEqual(ConstraintType.symmetry, ca.types[i]);
        try std.testing.expectEqual(DeviceIdx.fromInt(0), ca.device_a[i]);
        try std.testing.expectEqual(DeviceIdx.fromInt(0), ca.device_b[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ca.weight[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ca.axis[i]);
    }
}

test "ConstraintArrays group_id stored and retrieved" {
    var ca = try ConstraintArrays.init(std.testing.allocator, 0);
    defer ca.deinit();

    try ca.append(.symmetry, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 1.0, 0.0, 42);
    try ca.append(.matching, DeviceIdx.fromInt(2), DeviceIdx.fromInt(3), 0.8, 0.0, 0);

    try std.testing.expectEqual(@as(u32, 42), ca.group_id[0]);
    try std.testing.expectEqual(@as(u32, 0),  ca.group_id[1]);
}
