// shape_arrays.zig
//
// Structure-of-Arrays container for axis-aligned GDS shapes — nwell, diff,
// poly, licon, mcon, vias, metal pads, routing segments — captured as the
// GDSII writer emits them. The in-engine DRC that previously consumed this
// table was replaced by KLayout-based verification
// (python/verification/klayout_drc.py); the container is retained so the
// GDS export path can still observe every rectangle without round-tripping
// through the output file.
//
// One row per shape.  No methods on the container; algorithms are free
// functions that accept the SoA slices.

const std = @import("std");
const types = @import("types.zig");

const LayerIdx = types.LayerIdx;
const NetIdx = types.NetIdx;

pub const ShapeArrays = struct {
    /// Axis-aligned bounding box minimum x in micrometers.
    x_min: []f32,
    /// Axis-aligned bounding box minimum y in micrometers.
    y_min: []f32,
    /// Axis-aligned bounding box maximum x in micrometers.
    x_max: []f32,
    /// Axis-aligned bounding box maximum y in micrometers.
    y_max: []f32,
    /// GDS layer number (e.g. sky130 m1 = 68, mcon = 67).  Datatype lives
    /// in the parallel `datatype` array so the (layer, datatype) pair can
    /// be matched against the PDK's LayerTable entries directly.
    gds_layer: []u16,
    /// GDS datatype number.
    gds_datatype: []u16,
    /// Net index for routed shapes; `none_net` for non-routed shapes.
    net: []NetIdx,
    allocator: std.mem.Allocator,
    len: u32,
    capacity: u32,

    /// Sentinel net id for shapes that do not belong to a routed net
    /// (devices, well/implant rectangles, vias, landing pads).
    pub const none_net: NetIdx = NetIdx.fromInt(std.math.maxInt(u32));

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !ShapeArrays {
        const cap: usize = @intCast(capacity);

        const xmin = try allocator.alloc(f32, cap);
        errdefer allocator.free(xmin);
        const ymin = try allocator.alloc(f32, cap);
        errdefer allocator.free(ymin);
        const xmax = try allocator.alloc(f32, cap);
        errdefer allocator.free(xmax);
        const ymax = try allocator.alloc(f32, cap);
        errdefer allocator.free(ymax);
        const layers = try allocator.alloc(u16, cap);
        errdefer allocator.free(layers);
        const datatypes = try allocator.alloc(u16, cap);
        errdefer allocator.free(datatypes);
        const nets = try allocator.alloc(NetIdx, cap);
        errdefer allocator.free(nets);

        return ShapeArrays{
            .x_min = xmin,
            .y_min = ymin,
            .x_max = xmax,
            .y_max = ymax,
            .gds_layer = layers,
            .gds_datatype = datatypes,
            .net = nets,
            .allocator = allocator,
            .len = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *ShapeArrays) void {
        if (self.capacity > 0) {
            self.allocator.free(self.x_min);
            self.allocator.free(self.y_min);
            self.allocator.free(self.x_max);
            self.allocator.free(self.y_max);
            self.allocator.free(self.gds_layer);
            self.allocator.free(self.gds_datatype);
            self.allocator.free(self.net);
        }
        self.* = undefined;
    }

    fn growTo(self: *ShapeArrays, new_cap: u32) !void {
        const nc: usize = @intCast(new_cap);
        self.x_min = try self.allocator.realloc(self.x_min, nc);
        self.y_min = try self.allocator.realloc(self.y_min, nc);
        self.x_max = try self.allocator.realloc(self.x_max, nc);
        self.y_max = try self.allocator.realloc(self.y_max, nc);
        self.gds_layer = try self.allocator.realloc(self.gds_layer, nc);
        self.gds_datatype = try self.allocator.realloc(self.gds_datatype, nc);
        self.net = try self.allocator.realloc(self.net, nc);
        self.capacity = new_cap;
    }

    /// Append a single axis-aligned rectangle.  Grows the underlying
    /// arrays geometrically when capacity is exhausted.
    pub fn append(
        self: *ShapeArrays,
        x_min: f32,
        y_min: f32,
        x_max: f32,
        y_max: f32,
        gds_layer: u16,
        gds_datatype: u16,
        net: NetIdx,
    ) !void {
        if (self.len >= self.capacity) {
            const new_cap = if (self.capacity == 0) @as(u32, 32) else self.capacity * 2;
            try self.growTo(new_cap);
        }
        const i: usize = @intCast(self.len);
        self.x_min[i] = x_min;
        self.y_min[i] = y_min;
        self.x_max[i] = x_max;
        self.y_max[i] = y_max;
        self.gds_layer[i] = gds_layer;
        self.gds_datatype[i] = gds_datatype;
        self.net[i] = net;
        self.len += 1;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "ShapeArrays init/deinit" {
    var s = try ShapeArrays.init(std.testing.allocator, 8);
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), s.len);
    try std.testing.expectEqual(@as(u32, 8), s.capacity);
}

test "ShapeArrays append grows" {
    var s = try ShapeArrays.init(std.testing.allocator, 0);
    defer s.deinit();
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try s.append(
            @as(f32, @floatFromInt(i)),
            0.0,
            @as(f32, @floatFromInt(i)) + 1.0,
            1.0,
            68,
            20,
            ShapeArrays.none_net,
        );
    }
    try std.testing.expectEqual(@as(u32, 100), s.len);
    try std.testing.expect(s.capacity >= 100);
    try std.testing.expectEqual(@as(f32, 99.0), s.x_min[99]);
    try std.testing.expectEqual(@as(u16, 68), s.gds_layer[0]);
}

test "ShapeArrays stores layer/datatype/net correctly" {
    var s = try ShapeArrays.init(std.testing.allocator, 0);
    defer s.deinit();
    try s.append(0.0, 0.0, 1.0, 1.0, 68, 20, NetIdx.fromInt(3));
    try s.append(2.0, 2.0, 3.0, 3.0, 67, 44, ShapeArrays.none_net);

    try std.testing.expectEqual(@as(u16, 68), s.gds_layer[0]);
    try std.testing.expectEqual(@as(u16, 20), s.gds_datatype[0]);
    try std.testing.expectEqual(NetIdx.fromInt(3), s.net[0]);

    try std.testing.expectEqual(@as(u16, 67), s.gds_layer[1]);
    try std.testing.expectEqual(@as(u16, 44), s.gds_datatype[1]);
    try std.testing.expectEqual(ShapeArrays.none_net, s.net[1]);
}

test "ShapeArrays.none_net is the max u32 sentinel" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), ShapeArrays.none_net.toInt());
}
