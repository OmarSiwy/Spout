const std = @import("std");
const types = @import("types.zig");

const DeviceType = types.DeviceType;
const DeviceParams = types.DeviceParams;
const Orientation = types.Orientation;

pub const DeviceArrays = struct {
    types: []DeviceType,
    params: []DeviceParams,
    positions: [][2]f32,
    dimensions: [][2]f32,
    embeddings: [][64]f32,
    predicted_cap: []f32,
    orientations: []Orientation,
    is_dummy: []bool,
    allocator: std.mem.Allocator,
    len: u32,

    /// Allocate all device arrays with the given count and zero-initialize.
    pub fn init(allocator: std.mem.Allocator, count: u32) !DeviceArrays {
        const n: usize = @intCast(count);

        const dev_types = try allocator.alloc(DeviceType, n);
        errdefer allocator.free(dev_types);
        @memset(dev_types, .nmos);

        const dev_params = try allocator.alloc(DeviceParams, n);
        errdefer allocator.free(dev_params);
        @memset(dev_params, std.mem.zeroes(DeviceParams));

        const pos = try allocator.alloc([2]f32, n);
        errdefer allocator.free(pos);
        @memset(pos, .{ 0.0, 0.0 });

        const dims = try allocator.alloc([2]f32, n);
        errdefer allocator.free(dims);
        @memset(dims, .{ 0.0, 0.0 });

        const embeds = try allocator.alloc([64]f32, n);
        errdefer allocator.free(embeds);
        @memset(embeds, .{0.0} ** 64);

        const pcap = try allocator.alloc(f32, n);
        errdefer allocator.free(pcap);
        @memset(pcap, 0.0);

        const orients = try allocator.alloc(Orientation, n);
        errdefer allocator.free(orients);
        @memset(orients, .N);

        const dummy = try allocator.alloc(bool, n);
        errdefer allocator.free(dummy);
        @memset(dummy, false);

        return DeviceArrays{
            .types = dev_types,
            .params = dev_params,
            .positions = pos,
            .dimensions = dims,
            .embeddings = embeds,
            .predicted_cap = pcap,
            .orientations = orients,
            .is_dummy = dummy,
            .allocator = allocator,
            .len = count,
        };
    }

    /// Free all owned slices and invalidate the struct.
    pub fn deinit(self: *DeviceArrays) void {
        self.allocator.free(self.types);
        self.allocator.free(self.params);
        self.allocator.free(self.positions);
        self.allocator.free(self.dimensions);
        self.allocator.free(self.embeddings);
        self.allocator.free(self.predicted_cap);
        self.allocator.free(self.orientations);
        self.allocator.free(self.is_dummy);
        self.* = undefined;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "DeviceArrays init and deinit" {
    var da = try DeviceArrays.init(std.testing.allocator, 4);
    defer da.deinit();

    try std.testing.expectEqual(@as(u32, 4), da.len);
    try std.testing.expectEqual(@as(usize, 4), da.types.len);
    try std.testing.expectEqual(@as(usize, 4), da.predicted_cap.len);

    // Verify zero-initialization.
    try std.testing.expectEqual(@as(f32, 0.0), da.positions[0][0]);
    try std.testing.expectEqual(@as(f32, 0.0), da.embeddings[3][63]);
    try std.testing.expectEqual(@as(f32, 0.0), da.predicted_cap[2]);
}

test "DeviceArrays zero-count" {
    var da = try DeviceArrays.init(std.testing.allocator, 0);
    defer da.deinit();

    try std.testing.expectEqual(@as(u32, 0), da.len);
    try std.testing.expectEqual(@as(usize, 0), da.types.len);
}

test "DeviceArrays init with count=100 all slices have length 100" {
    var da = try DeviceArrays.init(std.testing.allocator, 100);
    defer da.deinit();

    try std.testing.expectEqual(@as(u32, 100), da.len);
    try std.testing.expectEqual(@as(usize, 100), da.types.len);
    try std.testing.expectEqual(@as(usize, 100), da.params.len);
    try std.testing.expectEqual(@as(usize, 100), da.positions.len);
    try std.testing.expectEqual(@as(usize, 100), da.dimensions.len);
    try std.testing.expectEqual(@as(usize, 100), da.embeddings.len);
    try std.testing.expectEqual(@as(usize, 100), da.predicted_cap.len);
}

test "DeviceArrays zero-initialized for all fields" {
    var da = try DeviceArrays.init(std.testing.allocator, 50);
    defer da.deinit();

    // All types default to .nmos
    for (da.types) |t| {
        try std.testing.expectEqual(DeviceType.nmos, t);
    }

    // All positions default to (0,0)
    for (da.positions) |pos| {
        try std.testing.expectEqual(@as(f32, 0.0), pos[0]);
        try std.testing.expectEqual(@as(f32, 0.0), pos[1]);
    }

    // All dimensions default to (0,0)
    for (da.dimensions) |dim| {
        try std.testing.expectEqual(@as(f32, 0.0), dim[0]);
        try std.testing.expectEqual(@as(f32, 0.0), dim[1]);
    }

    // All embeddings default to zeros
    for (da.embeddings) |embed| {
        for (embed) |val| {
            try std.testing.expectEqual(@as(f32, 0.0), val);
        }
    }

    // All predicted_cap default to 0.0
    for (da.predicted_cap) |cap| {
        try std.testing.expectEqual(@as(f32, 0.0), cap);
    }

    // All params default to zeroed struct
    for (da.params) |p| {
        try std.testing.expectEqual(@as(f32, 0.0), p.w);
        try std.testing.expectEqual(@as(f32, 0.0), p.l);
        try std.testing.expectEqual(@as(u16, 0), p.fingers);
        try std.testing.expectEqual(@as(u16, 0), p.mult);
        try std.testing.expectEqual(@as(f32, 0.0), p.value);
    }
}

test "DeviceArrays mutate positions and verify" {
    var da = try DeviceArrays.init(std.testing.allocator, 3);
    defer da.deinit();

    da.positions[0] = .{ 1.0, 2.0 };
    da.positions[1] = .{ 3.0, 4.0 };
    da.positions[2] = .{ 5.0, 6.0 };

    try std.testing.expectEqual(@as(f32, 1.0), da.positions[0][0]);
    try std.testing.expectEqual(@as(f32, 6.0), da.positions[2][1]);

    da.types[0] = .pmos;
    da.types[1] = .res;
    da.types[2] = .cap;

    try std.testing.expectEqual(DeviceType.pmos, da.types[0]);
    try std.testing.expectEqual(DeviceType.res, da.types[1]);
    try std.testing.expectEqual(DeviceType.cap, da.types[2]);
}
