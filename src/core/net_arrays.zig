const std = @import("std");

pub const NetArrays = struct {
    /// Offsets into a string table (not owned here).
    names: []u32,
    fanout: []u16,
    is_power: []bool,
    /// Bounding box per net: [xmin, ymin, xmax, ymax].
    bbox: [][4]f32,
    /// Half-perimeter wirelength estimate.
    hpwl: []f32,
    embeddings: [][64]f32,
    allocator: std.mem.Allocator,
    len: u32,

    /// Allocate all net arrays with the given count and zero-initialize.
    pub fn init(allocator: std.mem.Allocator, count: u32) !NetArrays {
        const n: usize = @intCast(count);

        const name_offsets = try allocator.alloc(u32, n);
        errdefer allocator.free(name_offsets);
        @memset(name_offsets, 0);

        const fan = try allocator.alloc(u16, n);
        errdefer allocator.free(fan);
        @memset(fan, 0);

        const power = try allocator.alloc(bool, n);
        errdefer allocator.free(power);
        @memset(power, false);

        const boxes = try allocator.alloc([4]f32, n);
        errdefer allocator.free(boxes);
        @memset(boxes, .{ 0.0, 0.0, 0.0, 0.0 });

        const wl = try allocator.alloc(f32, n);
        errdefer allocator.free(wl);
        @memset(wl, 0.0);

        const embeds = try allocator.alloc([64]f32, n);
        errdefer allocator.free(embeds);
        @memset(embeds, .{0.0} ** 64);

        return NetArrays{
            .names = name_offsets,
            .fanout = fan,
            .is_power = power,
            .bbox = boxes,
            .hpwl = wl,
            .embeddings = embeds,
            .allocator = allocator,
            .len = count,
        };
    }

    /// Free all owned slices and invalidate the struct.
    pub fn deinit(self: *NetArrays) void {
        self.allocator.free(self.names);
        self.allocator.free(self.fanout);
        self.allocator.free(self.is_power);
        self.allocator.free(self.bbox);
        self.allocator.free(self.hpwl);
        self.allocator.free(self.embeddings);
        self.* = undefined;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "NetArrays init and deinit" {
    var na = try NetArrays.init(std.testing.allocator, 8);
    defer na.deinit();

    try std.testing.expectEqual(@as(u32, 8), na.len);
    try std.testing.expectEqual(@as(usize, 8), na.fanout.len);
    try std.testing.expectEqual(false, na.is_power[0]);
    try std.testing.expectEqual(@as(f32, 0.0), na.hpwl[7]);
    try std.testing.expectEqual(@as(f32, 0.0), na.bbox[3][2]);
}

test "NetArrays zero-count" {
    var na = try NetArrays.init(std.testing.allocator, 0);
    defer na.deinit();

    try std.testing.expectEqual(@as(u32, 0), na.len);
}

test "NetArrays init with count=100 all slices have length 100" {
    var na = try NetArrays.init(std.testing.allocator, 100);
    defer na.deinit();

    try std.testing.expectEqual(@as(u32, 100), na.len);
    try std.testing.expectEqual(@as(usize, 100), na.names.len);
    try std.testing.expectEqual(@as(usize, 100), na.fanout.len);
    try std.testing.expectEqual(@as(usize, 100), na.is_power.len);
    try std.testing.expectEqual(@as(usize, 100), na.bbox.len);
    try std.testing.expectEqual(@as(usize, 100), na.hpwl.len);
    try std.testing.expectEqual(@as(usize, 100), na.embeddings.len);
}

test "NetArrays is_power defaults to false for all entries" {
    var na = try NetArrays.init(std.testing.allocator, 20);
    defer na.deinit();

    for (na.is_power) |p| {
        try std.testing.expectEqual(false, p);
    }
}

test "NetArrays fanout defaults to zero" {
    var na = try NetArrays.init(std.testing.allocator, 10);
    defer na.deinit();

    for (na.fanout) |f| {
        try std.testing.expectEqual(@as(u16, 0), f);
    }
}

test "NetArrays bbox defaults to zeros" {
    var na = try NetArrays.init(std.testing.allocator, 5);
    defer na.deinit();

    for (na.bbox) |b| {
        try std.testing.expectEqual(@as(f32, 0.0), b[0]);
        try std.testing.expectEqual(@as(f32, 0.0), b[1]);
        try std.testing.expectEqual(@as(f32, 0.0), b[2]);
        try std.testing.expectEqual(@as(f32, 0.0), b[3]);
    }
}

test "NetArrays mutate and verify" {
    var na = try NetArrays.init(std.testing.allocator, 3);
    defer na.deinit();

    na.is_power[0] = true;
    na.is_power[1] = false;
    na.is_power[2] = true;

    na.fanout[0] = 4;
    na.fanout[1] = 10;
    na.fanout[2] = 1;

    na.hpwl[0] = 15.5;

    try std.testing.expect(na.is_power[0]);
    try std.testing.expect(!na.is_power[1]);
    try std.testing.expect(na.is_power[2]);
    try std.testing.expectEqual(@as(u16, 10), na.fanout[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 15.5), na.hpwl[0], 1e-6);
}
