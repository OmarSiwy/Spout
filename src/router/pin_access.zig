const std = @import("std");
const core_types = @import("../core/types.zig");
const device_arrays = @import("../core/device_arrays.zig");
const pin_edge_arrays_mod = @import("../core/pin_edge_arrays.zig");
const grid_mod = @import("grid.zig");
const layout_if = @import("../core/layout_if.zig");

const DeviceArrays = device_arrays.DeviceArrays;
const PinEdgeArrays = pin_edge_arrays_mod.PinEdgeArrays;
const MultiLayerGrid = grid_mod.MultiLayerGrid;
const GridNode = grid_mod.GridNode;
const PdkConfig = layout_if.PdkConfig;
const NetIdx = core_types.NetIdx;

pub const AccessPoint = struct {
    node: GridNode,
    x: f32,
    y: f32,
    layer: u8,
    cost: f32,
};

pub const PinAccessDB = struct {
    aps: [][]AccessPoint,
    allocator: std.mem.Allocator,

    pub fn build(
        allocator: std.mem.Allocator,
        devices: *const DeviceArrays,
        pins: *const PinEdgeArrays,
        grid: *const MultiLayerGrid,
        pdk: *const PdkConfig,
    ) !PinAccessDB {
        const n_pins: usize = @intCast(pins.len);
        const aps = try allocator.alloc([]AccessPoint, n_pins);
        errdefer allocator.free(aps);

        for (0..n_pins) |p| {
            const dev_idx = pins.device[p].toInt();
            if (dev_idx >= devices.len) {
                aps[p] = try allocator.alloc(AccessPoint, 0);
                continue;
            }

            // Absolute pin position in world coordinates
            const dx = devices.positions[dev_idx][0];
            const dy = devices.positions[dev_idx][1];
            const pin_x = dx + pins.position[p][0];
            const pin_y = dy + pins.position[p][1];

            // Enumerate APs on M1 (layer 0): center + +-1 track in each direction
            var candidates: std.ArrayListUnmanaged(AccessPoint) = .{};
            defer candidates.deinit(allocator);

            const center_node = grid.worldToNode(0, pin_x, pin_y);
            const center_pos = grid.nodeToWorld(center_node);

            // Center AP -- cost 0
            try candidates.append(allocator, .{
                .node = center_node,
                .x = center_pos[0],
                .y = center_pos[1],
                .layer = 0,
                .cost = 0.0,
            });

            // +-1 track offsets along preferred direction -- cost 1.0 each
            const offsets = [_]i32{ -1, 1 };
            for (offsets) |da_off| {
                const new_a_i: i64 = @as(i64, @intCast(center_node.track_a)) + da_off;
                if (new_a_i >= 0 and new_a_i < @as(i64, @intCast(grid.layers[0].num_tracks))) {
                    const new_a: u32 = @intCast(new_a_i);
                    const alt_node = GridNode{ .layer = 0, .track_a = new_a, .track_b = center_node.track_b };
                    const alt_pos = grid.nodeToWorld(alt_node);
                    try candidates.append(allocator, .{
                        .node = alt_node,
                        .x = alt_pos[0],
                        .y = alt_pos[1],
                        .layer = 0,
                        .cost = 1.0,
                    });
                }
            }
            // +-1 track offsets along cross direction -- cost 1.0 each
            for (offsets) |db_off| {
                const new_b_i: i64 = @as(i64, @intCast(center_node.track_b)) + db_off;
                if (new_b_i >= 0 and new_b_i < @as(i64, @intCast(grid.cross_layers[0].num_tracks))) {
                    const new_b: u32 = @intCast(new_b_i);
                    const alt_node = GridNode{ .layer = 0, .track_a = center_node.track_a, .track_b = new_b };
                    const alt_pos = grid.nodeToWorld(alt_node);
                    try candidates.append(allocator, .{
                        .node = alt_node,
                        .x = alt_pos[0],
                        .y = alt_pos[1],
                        .layer = 0,
                        .cost = 1.0,
                    });
                }
            }

            // Filter: accept APs within 2x M1 pitch of pin center
            var valid: std.ArrayListUnmanaged(AccessPoint) = .{};
            for (candidates.items) |ap| {
                const dist = @abs(ap.x - pin_x) + @abs(ap.y - pin_y);
                if (dist < pdk.metal_pitch[0] * 2.0 + 0.01) {
                    try valid.append(allocator, ap);
                }
            }

            aps[p] = try valid.toOwnedSlice(allocator);
        }

        return PinAccessDB{ .aps = aps, .allocator = allocator };
    }

    pub fn deinit(self: *PinAccessDB) void {
        for (self.aps) |ap_list| {
            self.allocator.free(ap_list);
        }
        self.allocator.free(self.aps);
        self.* = undefined;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "PinAccessDB enumerate APs for MOSFET gate" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    const pea_mod = @import("../core/pin_edge_arrays.zig");

    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pea_mod.PinEdgeArrays.init(allocator, 1);
    defer pins.deinit();
    pins.device[0] = @import("../core/types.zig").DeviceIdx.fromInt(0);
    pins.terminal[0] = .gate;
    pins.net[0] = @import("../core/types.zig").NetIdx.fromInt(0);
    pins.computePinOffsets(&da);

    const pdk = @import("../core/layout_if.zig").PdkConfig.loadDefault(.sky130);
    const grid_mod_local = @import("grid.zig");
    var grid = try grid_mod_local.MultiLayerGrid.init(allocator, &da, &pdk, 10.0, &pins);
    defer grid.deinit();

    var db = try PinAccessDB.build(allocator, &da, &pins, &grid, &pdk);
    defer db.deinit();

    // Gate pin should have at least 1 valid access point
    try std.testing.expect(db.aps[0].len > 0);
    // Center AP should have cost 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), db.aps[0][0].cost, 1e-6);
}

test "PinAccessDB all APs are on valid track positions" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    const pea_mod = @import("../core/pin_edge_arrays.zig");

    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pea_mod.PinEdgeArrays.init(allocator, 4);
    defer pins.deinit();
    const types_mod = @import("../core/types.zig");
    for (0..4) |i| {
        pins.device[i] = types_mod.DeviceIdx.fromInt(0);
        pins.net[i] = types_mod.NetIdx.fromInt(@intCast(i));
    }
    pins.terminal[0] = .gate;
    pins.terminal[1] = .drain;
    pins.terminal[2] = .source;
    pins.terminal[3] = .body;
    pins.computePinOffsets(&da);

    const pdk = @import("../core/layout_if.zig").PdkConfig.loadDefault(.sky130);
    const grid_mod_local = @import("grid.zig");
    var grid = try grid_mod_local.MultiLayerGrid.init(allocator, &da, &pdk, 10.0, &pins);
    defer grid.deinit();

    var db = try PinAccessDB.build(allocator, &da, &pins, &grid, &pdk);
    defer db.deinit();

    // Every AP should have a valid layer
    for (0..4) |p| {
        for (db.aps[p]) |ap| {
            try std.testing.expect(ap.layer < grid.num_layers);
        }
    }
}
