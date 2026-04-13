const std = @import("std");

pub const Transform = extern struct {
    mirror_x: bool = false,
    mirror_y: bool = false,
    rot_90: bool = false,
    _pad: u8 = 0,

    /// Apply transform to `pos` given unit cell bounding box `bbox` = [W, H].
    /// Order: mirror_x → mirror_y → rot_90 (90° CCW).
    pub fn apply(self: Transform, pos: [2]f32, bbox: [2]f32) [2]f32 {
        var x = pos[0];
        var y = pos[1];
        if (self.mirror_x) x = bbox[0] - x;
        if (self.mirror_y) y = bbox[1] - y;
        if (self.rot_90) {
            const old_x = x;
            x = bbox[1] - y;
            y = old_x;
        }
        return .{ x, y };
    }
};

pub const MacroConfig = extern struct {
    param_tolerance: f32 = 0.0,
    min_instance_count: u32 = 2,
    enable_structural: bool = true,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

pub const MacroTemplate = struct {
    name: []const u8,
    device_indices: []u32,
    port_net_indices: []u32,
};

pub const MacroInstance = struct {
    template_id: u32,
    device_indices: []u32,
    position: [2]f32,
    transform: Transform,
};

pub const MacroArrays = struct {
    templates: []MacroTemplate,
    instances: []MacroInstance,
    device_inst: []i32,
    device_local: []u32,
    template_count: u32,
    instance_count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_devices: u32) !MacroArrays {
        const n: usize = @intCast(num_devices);
        const di = try allocator.alloc(i32, n);
        errdefer allocator.free(di);
        @memset(di, -1);
        const dl = try allocator.alloc(u32, n);
        errdefer allocator.free(dl);
        @memset(dl, 0);
        return MacroArrays{
            .templates = &.{},
            .instances = &.{},
            .device_inst = di,
            .device_local = dl,
            .template_count = 0,
            .instance_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MacroArrays) void {
        for (self.templates[0..self.template_count]) |*t| {
            self.allocator.free(t.name);
            self.allocator.free(t.device_indices);
            self.allocator.free(t.port_net_indices);
        }
        if (self.template_count > 0) self.allocator.free(self.templates);
        for (self.instances[0..self.instance_count]) |*inst| {
            self.allocator.free(inst.device_indices);
        }
        if (self.instance_count > 0) self.allocator.free(self.instances);
        self.allocator.free(self.device_inst);
        self.allocator.free(self.device_local);
        self.* = undefined;
    }
};

test "Transform.apply identity" {
    const t = Transform{};
    const r = t.apply(.{ 1.0, 2.0 }, .{ 10.0, 8.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), r[1], 1e-5);
}

test "Transform.apply mirror_x" {
    const t = Transform{ .mirror_x = true };
    const r = t.apply(.{ 3.0, 2.0 }, .{ 10.0, 8.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), r[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), r[1], 1e-5);
}

test "Transform.apply mirror_y" {
    const t = Transform{ .mirror_y = true };
    const r = t.apply(.{ 3.0, 2.0 }, .{ 10.0, 8.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), r[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), r[1], 1e-5);
}

test "Transform.apply rot_90" {
    const t = Transform{ .rot_90 = true };
    // (2,3) in bbox [10,8]: x' = 8-3=5, y' = 2
    const r = t.apply(.{ 2.0, 3.0 }, .{ 10.0, 8.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), r[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), r[1], 1e-5);
}

test "MacroArrays init/deinit zero devices" {
    var ma = try MacroArrays.init(std.testing.allocator, 0);
    defer ma.deinit();
    try std.testing.expectEqual(@as(u32, 0), ma.template_count);
    try std.testing.expectEqual(@as(u32, 0), ma.instance_count);
}

test "MacroArrays init sets device_inst to -1" {
    var ma = try MacroArrays.init(std.testing.allocator, 4);
    defer ma.deinit();
    try std.testing.expectEqual(@as(usize, 4), ma.device_inst.len);
    for (ma.device_inst) |v| try std.testing.expectEqual(@as(i32, -1), v);
}
