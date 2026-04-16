const std = @import("std");
const types = @import("types.zig");

const NetIdx = types.NetIdx;

// ─── Route layer index convention ────────────────────────────────────────────
//
// The `layer` field in RouteArrays uses the following indices:
//
//   0 = local interconnect (LI)
//   1 = metal 1 (M1)
//   2 = metal 2 (M2)
//   3 = metal 3 (M3)
//   4 = metal 4 (M4)
//   5 = metal 5 (M5)
//
// The GDSII exporter maps these to PDK-specific GDSII layer/datatype pairs:
//   layer 0 → pdk.layers.li
//   layer 1 → pdk.layers.metal[0]  (M1)
//   layer 2 → pdk.layers.metal[1]  (M2)
//   ...
//   layer N → pdk.layers.metal[N-1]
//
// The DRC/LVS/PEX engines and wire-sizing code consume these same indices.
// When indexing into PdkConfig arrays (min_width, min_spacing, etc.) which
// are 0-indexed from M1, subtract 1 from the route layer index for metal
// layers (i.e. pdk.min_width[route_layer - 1] for route_layer >= 1).

/// Segment-level routing flags (mirrors AnalogSegmentDB.SegmentFlags).
/// Stored separately so the core route_arrays.zig has no analog router dependency.
pub const RouteSegmentFlags = packed struct(u8) {
    is_shield: bool = false,
    is_dummy_via: bool = false,
    is_jog: bool = false,
    _padding: u5 = 0,
};

pub const RouteArrays = struct {
    /// Metal/interconnect layer index (see convention comment above).
    layer: []u8,
    x1: []f32,
    y1: []f32,
    x2: []f32,
    y2: []f32,
    width: []f32,
    net: []NetIdx,
    /// Segment flags (is_shield, is_dummy_via, is_jog) from analog routing.
    flags: []RouteSegmentFlags,
    allocator: std.mem.Allocator,
    len: u32,
    capacity: u32,

    pub fn init(allocator: std.mem.Allocator, count: u32) !RouteArrays {
        const n: usize = @intCast(count);

        const lay = try allocator.alloc(u8, n);
        errdefer allocator.free(lay);
        @memset(lay, 0);

        const rx1 = try allocator.alloc(f32, n);
        errdefer allocator.free(rx1);
        @memset(rx1, 0.0);

        const ry1 = try allocator.alloc(f32, n);
        errdefer allocator.free(ry1);
        @memset(ry1, 0.0);

        const rx2 = try allocator.alloc(f32, n);
        errdefer allocator.free(rx2);
        @memset(rx2, 0.0);

        const ry2 = try allocator.alloc(f32, n);
        errdefer allocator.free(ry2);
        @memset(ry2, 0.0);

        const w = try allocator.alloc(f32, n);
        errdefer allocator.free(w);
        @memset(w, 0.0);

        const nets = try allocator.alloc(NetIdx, n);
        errdefer allocator.free(nets);
        @memset(nets, NetIdx.fromInt(0));

        const fl = try allocator.alloc(RouteSegmentFlags, n);
        errdefer allocator.free(fl);
        @memset(fl, RouteSegmentFlags{});

        return RouteArrays{
            .layer = lay,
            .x1 = rx1,
            .y1 = ry1,
            .x2 = rx2,
            .y2 = ry2,
            .width = w,
            .net = nets,
            .flags = fl,
            .allocator = allocator,
            .len = count,
            .capacity = count,
        };
    }

    /// Ensure there is room for at least `additional` more elements beyond current len.
    pub fn ensureUnusedCapacity(self: *RouteArrays, _: std.mem.Allocator, additional: u32) !void {
        const needed = self.len + additional;
        if (needed > self.capacity) {
            try self.growTo(needed);
        }
    }

    /// Append a single route segment without bounds checking.
    /// Caller must ensure capacity via ensureUnusedCapacity first.
    pub fn appendAssumeCapacity(
        self: *RouteArrays,
        seg_layer: u8,
        seg_x1: f32,
        seg_y1: f32,
        seg_x2: f32,
        seg_y2: f32,
        seg_width: f32,
        seg_net: NetIdx,
    ) void {
        const i: usize = @intCast(self.len);
        self.layer[i] = seg_layer;
        self.x1[i] = seg_x1;
        self.y1[i] = seg_y1;
        self.x2[i] = seg_x2;
        self.y2[i] = seg_y2;
        self.width[i] = seg_width;
        self.net[i] = seg_net;
        self.len += 1;
    }

    /// Grow all arrays to accommodate at least `new_cap` elements.
    pub fn growTo(self: *RouteArrays, new_cap: u32) !void {
        const nc: usize = @intCast(new_cap);

        self.layer = try self.allocator.realloc(self.layer, nc);
        self.x1 = try self.allocator.realloc(self.x1, nc);
        self.y1 = try self.allocator.realloc(self.y1, nc);
        self.x2 = try self.allocator.realloc(self.x2, nc);
        self.y2 = try self.allocator.realloc(self.y2, nc);
        self.width = try self.allocator.realloc(self.width, nc);
        self.net = try self.allocator.realloc(self.net, nc);
        self.flags = try self.allocator.realloc(self.flags, nc);

        self.capacity = new_cap;
    }

    /// Append a single route segment, growing if necessary.
    pub fn append(
        self: *RouteArrays,
        seg_layer: u8,
        seg_x1: f32,
        seg_y1: f32,
        seg_x2: f32,
        seg_y2: f32,
        seg_width: f32,
        seg_net: NetIdx,
    ) !void {
        if (self.len >= self.capacity) {
            const new_cap = if (self.capacity == 0) @as(u32, 16) else self.capacity * 2;
            try self.growTo(new_cap);
        }
        const i: usize = @intCast(self.len);
        self.layer[i] = seg_layer;
        self.x1[i] = seg_x1;
        self.y1[i] = seg_y1;
        self.x2[i] = seg_x2;
        self.y2[i] = seg_y2;
        self.width[i] = seg_width;
        self.net[i] = seg_net;
        self.len += 1;
    }

    pub fn deinit(self: *RouteArrays) void {
        if (self.capacity > 0) {
            self.allocator.free(self.layer);
            self.allocator.free(self.x1);
            self.allocator.free(self.y1);
            self.allocator.free(self.x2);
            self.allocator.free(self.y2);
            self.allocator.free(self.width);
            self.allocator.free(self.net);
            self.allocator.free(self.flags);
        }
        self.* = undefined;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "RouteArrays init and deinit" {
    var ra = try RouteArrays.init(std.testing.allocator, 4);
    defer ra.deinit();

    try std.testing.expectEqual(@as(u32, 4), ra.len);
    try std.testing.expectEqual(@as(usize, 4), ra.layer.len);
    try std.testing.expectEqual(@as(f32, 0.0), ra.x1[0]);
}

test "RouteArrays append" {
    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    try ra.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, NetIdx.fromInt(3));
    try ra.append(2, 10.0, 0.0, 10.0, 5.0, 0.14, NetIdx.fromInt(3));

    try std.testing.expectEqual(@as(u32, 2), ra.len);
    try std.testing.expectEqual(@as(u8, 1), ra.layer[0]);
    try std.testing.expectEqual(@as(f32, 10.0), ra.x2[0]);
    try std.testing.expectEqual(NetIdx.fromInt(3), ra.net[1]);
}

test "RouteArrays append grow" {
    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    for (0..20) |_| {
        try ra.append(0, 0.0, 0.0, 1.0, 1.0, 0.1, NetIdx.fromInt(0));
    }
    try std.testing.expectEqual(@as(u32, 20), ra.len);
    try std.testing.expect(ra.capacity >= 20);
}

test "RouteArrays append segments verify correct storage" {
    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    // Append three distinct segments on different layers/nets
    try ra.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, NetIdx.fromInt(0));
    try ra.append(2, 10.0, 0.0, 10.0, 5.0, 0.20, NetIdx.fromInt(1));
    try ra.append(3, 10.0, 5.0, 20.0, 5.0, 0.30, NetIdx.fromInt(2));

    try std.testing.expectEqual(@as(u32, 3), ra.len);

    // Verify segment 0
    try std.testing.expectEqual(@as(u8, 1), ra.layer[0]);
    try std.testing.expectEqual(@as(f32, 0.0), ra.x1[0]);
    try std.testing.expectEqual(@as(f32, 0.0), ra.y1[0]);
    try std.testing.expectEqual(@as(f32, 10.0), ra.x2[0]);
    try std.testing.expectEqual(@as(f32, 0.0), ra.y2[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), ra.width[0], 1e-6);
    try std.testing.expectEqual(NetIdx.fromInt(0), ra.net[0]);

    // Verify segment 1
    try std.testing.expectEqual(@as(u8, 2), ra.layer[1]);
    try std.testing.expectEqual(@as(f32, 10.0), ra.x1[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.20), ra.width[1], 1e-6);
    try std.testing.expectEqual(NetIdx.fromInt(1), ra.net[1]);

    // Verify segment 2
    try std.testing.expectEqual(@as(u8, 3), ra.layer[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), ra.width[2], 1e-6);
    try std.testing.expectEqual(NetIdx.fromInt(2), ra.net[2]);
}

test "RouteArrays capacity growth pattern from zero" {
    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    // First append: capacity grows from 0 to 16
    try ra.append(0, 0.0, 0.0, 1.0, 1.0, 0.1, NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(u32, 16), ra.capacity);

    // Fill to 16
    for (1..16) |_| {
        try ra.append(0, 0.0, 0.0, 1.0, 1.0, 0.1, NetIdx.fromInt(0));
    }
    try std.testing.expectEqual(@as(u32, 16), ra.len);
    try std.testing.expectEqual(@as(u32, 16), ra.capacity);

    // 17th append: capacity grows from 16 to 32
    try ra.append(0, 0.0, 0.0, 1.0, 1.0, 0.1, NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(u32, 17), ra.len);
    try std.testing.expectEqual(@as(u32, 32), ra.capacity);
}

test "RouteArrays init with pre-allocated count" {
    var ra = try RouteArrays.init(std.testing.allocator, 5);
    defer ra.deinit();

    try std.testing.expectEqual(@as(u32, 5), ra.len);
    try std.testing.expectEqual(@as(u32, 5), ra.capacity);

    // All defaults should be zero
    for (0..5) |i| {
        try std.testing.expectEqual(@as(u8, 0), ra.layer[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ra.x1[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ra.y1[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ra.x2[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ra.y2[i]);
        try std.testing.expectEqual(@as(f32, 0.0), ra.width[i]);
        try std.testing.expectEqual(NetIdx.fromInt(0), ra.net[i]);
    }
}
