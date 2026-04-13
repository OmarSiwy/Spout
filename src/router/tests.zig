const std = @import("std");
const steiner_mod = @import("steiner.zig");
const maze_mod = @import("maze.zig");
const lp_sizing = @import("lp_sizing.zig");
const inline_drc_mod = @import("inline_drc.zig");
const detailed_mod = @import("detailed.zig");
const pin_access_mod = @import("pin_access.zig");
const astar_mod = @import("astar.zig");
const grid_mod = @import("grid.zig");
const core_types = @import("../core/types.zig");
const net_arrays_mod = @import("../core/net_arrays.zig");
const device_arrays_mod = @import("../core/device_arrays.zig");
const pin_edge_mod = @import("../core/pin_edge_arrays.zig");
const adjacency_mod = @import("../core/adjacency.zig");
const layout_mod = @import("../core/layout_if.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");

const SteinerTree = steiner_mod.SteinerTree;
const MazeRouter = maze_mod.MazeRouter;
const DetailedRouter = detailed_mod.DetailedRouter;
const InlineDrcChecker = inline_drc_mod.InlineDrcChecker;
const PinAccessDB = pin_access_mod.PinAccessDB;
const AStarRouter = astar_mod.AStarRouter;
const MultiLayerGrid = grid_mod.MultiLayerGrid;
const GridNode = grid_mod.GridNode;
const NetIdx = core_types.NetIdx;
const DeviceIdx = core_types.DeviceIdx;
const NetArrays = net_arrays_mod.NetArrays;

// ─── Shared test helpers ─────────────────────────────────────────────────────

/// Build a minimal 2-device, 1-net, 2-pin circuit for router integration tests.
/// Pins default to offset [0,0] (positioned at device centres).
fn buildSimpleCircuit(
    alloc: std.mem.Allocator,
    pos0: [2]f32,
    pos1: [2]f32,
) !struct {
    devices: device_arrays_mod.DeviceArrays,
    nets: NetArrays,
    pins: pin_edge_mod.PinEdgeArrays,
    adj: adjacency_mod.FlatAdjList,

    fn deinit(self: *@This()) void {
        self.adj.deinit();
        self.pins.deinit();
        self.nets.deinit();
        self.devices.deinit();
    }
} {
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.positions[0] = pos0;
    devices.positions[1] = pos1;
    devices.dimensions[0] = .{ 2.0, 1.0 };
    devices.dimensions[1] = .{ 2.0, 1.0 };
    devices.params[0] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var nets = try NetArrays.init(alloc, 1);
    nets.fanout[0] = 2;
    nets.is_power[0] = false;

    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 2);
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;
    pins.device[1] = DeviceIdx.fromInt(1);
    pins.net[1] = NetIdx.fromInt(0);
    pins.terminal[1] = .gate;

    const adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 2, 1);
    return .{ .devices = devices, .nets = nets, .pins = pins, .adj = adj };
}

// ─── Steiner Tree ────────────────────────────────────────────────────────────

test "2-pin Steiner tree is a single L-segment" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 6.0, 8.0 },
    });
    defer tree.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 14.0), tree.totalLength(), 1e-6);
    try std.testing.expectEqual(@as(usize, 2), tree.segments.items.len);
    for (tree.segments.items) |seg| {
        try std.testing.expect(seg.y1 == seg.y2 or seg.x1 == seg.x2);
    }
}

test "2-pin collinear horizontal produces single segment" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 5.0 },
        .{ 10.0, 5.0 },
    });
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 1), tree.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), tree.totalLength(), 1e-6);
}

test "2-pin collinear vertical produces single segment" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 3.0, 0.0 },
        .{ 3.0, 7.0 },
    });
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 1), tree.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), tree.totalLength(), 1e-6);
}

test "3-pin Steiner tree reduces total length vs naive" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 10.0 },
    });
    defer tree.deinit();

    try std.testing.expect(tree.totalLength() <= 20.0 + 1e-6);
    try std.testing.expect(tree.totalLength() > 0.0);
}

test "3-pin Steiner tree T-shape" {
    // Pins: (0,0), (10,0), (5,5) → median Steiner point (5,0)
    // Optimal: (0,0)→(5,0)=5 + (10,0)→(5,0)=5 + (5,5)→(5,0)=5 = 15
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 5.0, 5.0 },
    });
    defer tree.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 15.0), tree.totalLength(), 1e-6);
}

test "3-pin collinear Steiner tree is a straight line" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 5.0, 0.0 },
        .{ 10.0, 0.0 },
    });
    defer tree.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 10.0), tree.totalLength(), 1e-6);
}

test "Steiner tree 4-pin reduces vs MST" {
    // 10×10 square: MST=30, RSMT=20
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 10.0 },
        .{ 10.0, 10.0 },
    });
    defer tree.deinit();

    try std.testing.expect(tree.totalLength() <= 30.0 + 1e-6);
    try std.testing.expect(tree.totalLength() >= 20.0 - 1e-6);
}

test "Steiner tree segment length helper" {
    const seg = SteinerTree.Segment{ .x1 = 1.0, .y1 = 2.0, .x2 = 4.0, .y2 = 6.0 };
    // Manhattan: |4-1| + |6-2| = 3 + 4 = 7
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), seg.length(), 1e-6);
}

test "Steiner 2-pin net total length equals Manhattan distance" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 2.0, 3.0 },
        .{ 7.0, 11.0 },
    });
    defer tree.deinit();

    // |7-2| + |11-3| = 5 + 8 = 13
    try std.testing.expectApproxEqAbs(@as(f32, 13.0), tree.totalLength(), 1e-6);
    try std.testing.expectEqual(@as(usize, 2), tree.segments.items.len);
}

test "Steiner 4-pin net bounded by 2x optimal" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 10.0 },
        .{ 10.0, 10.0 },
    });
    defer tree.deinit();

    try std.testing.expect(tree.totalLength() < 2.0 * 20.0 + 1e-6);
    try std.testing.expect(tree.totalLength() >= 20.0 - 1e-6);
}

test "Steiner segments are all axis-aligned for 3-pin" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 1.0, 2.0 },
        .{ 5.0, 8.0 },
        .{ 3.0, 4.0 },
    });
    defer tree.deinit();

    for (tree.segments.items) |seg| {
        try std.testing.expect(seg.y1 == seg.y2 or seg.x1 == seg.x2);
    }
}

test "Steiner 2-pin same position produces zero length" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 5.0, 5.0 },
        .{ 5.0, 5.0 },
    });
    defer tree.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tree.totalLength(), 1e-6);
}

test "Steiner 5-pin cross pattern centre is optimal Steiner point" {
    // Cross: centre pin plus 4 arms at distance 5. MST = 4*5 = 20.
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 5.0, 5.0 }, // centre
        .{ 0.0, 5.0 },
        .{ 10.0, 5.0 },
        .{ 5.0, 0.0 },
        .{ 5.0, 10.0 },
    });
    defer tree.deinit();

    // With centre pin present the total must be exactly 20.
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), tree.totalLength(), 1e-6);
}

test "Steiner 6-pin grid all segments rectilinear" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 3.0, 0.0 },
        .{ 6.0, 0.0 },
        .{ 0.0, 4.0 },
        .{ 3.0, 4.0 },
        .{ 6.0, 4.0 },
    });
    defer tree.deinit();

    for (tree.segments.items) |seg| {
        try std.testing.expect(seg.y1 == seg.y2 or seg.x1 == seg.x2);
    }
    try std.testing.expect(tree.totalLength() > 0.0);
}

test "Steiner totalLength bounded by 2x HPWL" {
    // HPWL of a 8×6 bounding box = 14. Any RSMT <= 1.5*HPWL, use 2x as bound.
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 8.0, 0.0 },
        .{ 0.0, 6.0 },
        .{ 8.0, 6.0 },
    });
    defer tree.deinit();

    try std.testing.expect(tree.totalLength() <= 28.0 + 1e-6);
    try std.testing.expect(tree.totalLength() > 0.0);
}

test "Steiner single pin returns no segments" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{.{ 5.0, 5.0 }});
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 0), tree.segments.items.len);
}

test "Steiner empty pin list returns no segments" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{});
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 0), tree.segments.items.len);
}

// ─── Maze Router ─────────────────────────────────────────────────────────────

test "MazeRouter init and deinit" {
    var router = try MazeRouter.init(std.testing.allocator, 0.005);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.005), router.grid_resolution, 1e-9);
}

test "MazeRouter getRoutes returns empty initially" {
    var router = try MazeRouter.init(std.testing.allocator, 0.01);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.getRoutes().len);
}

test "MazeRouter routes a simple 2-device 1-net circuit" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 10.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    try std.testing.expect(router.routes.len > 0);
}

test "MazeRouter skips nets with fewer than 2 pins" {
    const alloc = std.testing.allocator;

    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer devices.deinit();
    devices.positions[0] = .{ 0.0, 0.0 };

    var nets = try NetArrays.init(alloc, 1);
    defer nets.deinit();

    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 1);
    defer pins.deinit();
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;

    var adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 1, 1);
    defer adj.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&devices, &nets, &pins, &adj, &pdk);
    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
}

test "MazeRouter empty circuit produces no routes" {
    const alloc = std.testing.allocator;

    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer devices.deinit();
    var nets = try NetArrays.init(alloc, 0);
    defer nets.deinit();
    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 0);
    defer pins.deinit();
    var adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 0, 0);
    defer adj.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&devices, &nets, &pins, &adj, &pdk);
    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
}

test "MazeRouter all route segments have correct net index" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 5.0, 5.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        try std.testing.expectEqual(@as(u32, 0), router.routes.net[i].toInt());
    }
}

test "MazeRouter routes use only M1 (layer 1) and M2 (layer 2)" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 0.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        const layer = router.routes.layer[i];
        try std.testing.expect(layer == 1 or layer == 2);
    }
}

test "MazeRouter trunk x-extent spans all pin x-coordinates" {
    // Pins at x=0 and x=20 (devices 10 µm apart in x, same y).
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 20.0, 0.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    // Find the widest horizontal M1 segment (the trunk).
    var trunk_min_x: f32 = std.math.inf(f32);
    var trunk_max_x: f32 = -std.math.inf(f32);
    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        if (router.routes.layer[i] == 1 and router.routes.y1[i] == router.routes.y2[i]) {
            trunk_min_x = @min(trunk_min_x, @min(router.routes.x1[i], router.routes.x2[i]));
            trunk_max_x = @max(trunk_max_x, @max(router.routes.x1[i], router.routes.x2[i]));
        }
    }
    try std.testing.expect(trunk_min_x <= 0.0 + 1e-3);
    try std.testing.expect(trunk_max_x >= 20.0 - 1e-3);
}

test "MazeRouter two nets receive distinct horizontal channel positions" {
    const alloc = std.testing.allocator;

    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.positions[1] = .{ 10.0, 0.0 };

    var nets = try NetArrays.init(alloc, 2);
    defer nets.deinit();

    // 4 pins: 2 per net, one on each device.
    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();
    pins.device[0] = DeviceIdx.fromInt(0); pins.net[0] = NetIdx.fromInt(0); pins.terminal[0] = .gate;
    pins.device[1] = DeviceIdx.fromInt(1); pins.net[1] = NetIdx.fromInt(0); pins.terminal[1] = .gate;
    pins.device[2] = DeviceIdx.fromInt(0); pins.net[2] = NetIdx.fromInt(1); pins.terminal[2] = .drain;
    pins.device[3] = DeviceIdx.fromInt(1); pins.net[3] = NetIdx.fromInt(1); pins.terminal[3] = .drain;
    // Give net 1 pins a different y offset to make trunks visibly separate.
    pins.position[2] = .{ 0.0, 0.5 };
    pins.position[3] = .{ 0.0, 0.5 };

    var adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 2, 2);
    defer adj.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&devices, &nets, &pins, &adj, &pdk);
    try std.testing.expect(router.routes.len >= 2);

    // Collect distinct trunk y-values from horizontal M1 segments.
    var trunk_ys: [16]f32 = undefined;
    var ny: usize = 0;
    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        if (router.routes.layer[i] != 1 or router.routes.y1[i] != router.routes.y2[i]) continue;
        const y = router.routes.y1[i];
        var found = false;
        for (trunk_ys[0..ny]) |ty| {
            if (@abs(ty - y) < 1e-3) { found = true; break; }
        }
        if (!found and ny < trunk_ys.len) {
            trunk_ys[ny] = y;
            ny += 1;
        }
    }
    // Two distinct nets → at least 2 distinct trunk y values.
    try std.testing.expect(ny >= 2);
}

test "MazeRouter route widths are positive" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 5.0, 5.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        try std.testing.expect(router.routes.width[i] > 0.0);
    }
}

// ─── Wire Sizing (lp_sizing) ─────────────────────────────────────────────────

test "assignWidth signal net returns 1x min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 2;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w, 1e-6);
}

test "assignWidth power net returns 3x min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 2;
    nets.is_power[0] = true;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), w, 1e-6);
}

test "assignWidth high-fanout net returns 2x min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 12;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.28), w, 1e-6);
}

test "assignWidth power takes precedence over high-fanout" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 20;
    nets.is_power[0] = true;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), w, 1e-6);
}

test "assignWidth layer 2 uses that layer min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 1;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.20), w, 1e-6);
}

test "assignWidth out-of-range net falls back to min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(99), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w, 1e-6);
}

test "LP sizing power net gets wider wire than signal net" {
    var nets = try NetArrays.init(std.testing.allocator, 2);
    defer nets.deinit();
    nets.fanout[0] = 2; nets.is_power[0] = false;
    nets.fanout[1] = 2; nets.is_power[1] = true;
    const pdk = lp_sizing.PdkConfig{};
    const w_signal = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    const w_power = lp_sizing.assignWidth(NetIdx.fromInt(1), &nets, &pdk, 0);
    try std.testing.expect(w_power > w_signal);
    try std.testing.expectApproxEqAbs(w_signal * 3.0, w_power, 1e-6);
}

test "LP sizing high-fanout net gets 2x min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 16;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14 * 2.0), w, 1e-6);
}

test "LP sizing fanout exactly at threshold is not high-fanout" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 8; // threshold, not above → 1x
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w, 1e-6);
}

test "LP sizing fanout just above threshold is high-fanout" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 9;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14 * 2.0), w, 1e-6);
}

test "assignWidth fanout zero is treated as signal net" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 0;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w, 1e-6);
}

test "assignWidth all four layers produce independent min_widths" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 1;
    nets.is_power[0] = false;
    const pdk = lp_sizing.PdkConfig{};
    // Default config: M1=0.14, M2=0.14, M3=0.20, M4=0.20
    const expected = [4]f32{ 0.14, 0.14, 0.20, 0.20 };
    for (0..4) |l| {
        const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, @intCast(l));
        try std.testing.expectApproxEqAbs(expected[l], w, 1e-6);
    }
}

test "assignWidth power net on M2 gets 3x M2 min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();
    nets.fanout[0] = 2;
    nets.is_power[0] = true;
    const pdk = lp_sizing.PdkConfig{};
    const w = lp_sizing.assignWidth(NetIdx.fromInt(0), &nets, &pdk, 1); // layer 1 = M2 in pdk array
    try std.testing.expectApproxEqAbs(@as(f32, 0.14 * 3.0), w, 1e-6);
}

// ─── Inline DRC ──────────────────────────────────────────────────────────────

test "InlineDrcChecker no segments produces no violation" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const result = checker.checkSpacing(0, 5.0, 5.0, NetIdx.fromInt(0));
    try std.testing.expect(!result.hard_violation);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.soft_penalty, 1e-6);
}

test "InlineDrcChecker addSegment AABB expands by half-width" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    // Horizontal wire: x=[1,9], y=5, width=0.14, hw=0.07
    // AABB expands all 4 sides: x=[0.93,9.07], y=[4.93,5.07]
    try checker.addSegment(0, 1.0, 5.0, 9.0, 5.0, 0.14, NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(usize, 1), checker.segments.items.len);
    const seg = checker.segments.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 0.93), seg.x_min, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 9.07), seg.x_max, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 4.93), seg.y_min, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 5.07), seg.y_max, 1e-2);
}

test "InlineDrcChecker addSegment vertical wire AABB" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    // Vertical wire: x=3, y=[2,8], width=0.20, hw=0.10
    // AABB expands all 4 sides: x=[2.9,3.1], y=[1.9,8.1]
    try checker.addSegment(1, 3.0, 2.0, 3.0, 8.0, 0.20, NetIdx.fromInt(0));
    const seg = checker.segments.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 2.9), seg.x_min, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 3.1), seg.x_max, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.9), seg.y_min, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 8.1), seg.y_max, 1e-2);
}

test "InlineDrcChecker detects spacing violation" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    // Two parallel M1 wires <min_spacing apart.
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    try checker.addSegment(0, 1.0, 1.2, 5.0, 1.2, 0.14, NetIdx.fromInt(1));
    const result = checker.checkSpacing(0, 1.0, 1.2, NetIdx.fromInt(1));
    try std.testing.expect(result.hard_violation);
}

test "InlineDrcChecker allows legal spacing" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    try checker.addSegment(0, 1.0, 1.5, 5.0, 1.5, 0.14, NetIdx.fromInt(1));
    const result = checker.checkSpacing(0, 1.0, 1.5, NetIdx.fromInt(1));
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker detects short (overlap) between different nets" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    // Query at (3, 1) for net1 — directly overlaps net0 wire.
    const result = checker.checkSpacing(0, 3.0, 1.0, NetIdx.fromInt(1));
    try std.testing.expect(result.hard_violation);
}

test "InlineDrcChecker same-net overlapping segments do not violate" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    const result = checker.checkSpacing(0, 3.0, 1.0, NetIdx.fromInt(0));
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker different layers do not interact" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    // Check on layer 1 (M2) at same position — different layer, no violation.
    const result = checker.checkSpacing(1, 3.0, 1.0, NetIdx.fromInt(1));
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker removeSegmentsForNet removes only matching net" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(1));
    try std.testing.expectEqual(@as(usize, 2), checker.segments.items.len);

    checker.removeSegmentsForNet(NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(usize, 1), checker.segments.items.len);
    try std.testing.expectEqual(@as(u32, 1), checker.segments.items[0].net.toInt());
}

test "InlineDrcChecker removeSegmentsForNet no-match is a no-op" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    checker.removeSegmentsForNet(NetIdx.fromInt(99)); // no match
    try std.testing.expectEqual(@as(usize, 1), checker.segments.items.len);
}

test "InlineDrcChecker removeSegmentsForNet clears all when all match" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    for (0..5) |_| try checker.addSegment(0, 0.0, 0.0, 1.0, 0.0, 0.14, NetIdx.fromInt(0));
    checker.removeSegmentsForNet(NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(usize, 0), checker.segments.items.len);
    // After removal, no violations anywhere.
    const result = checker.checkSpacing(0, 0.5, 0.0, NetIdx.fromInt(1));
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker soft penalty for near-violation (just inside 1.5x band)" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    // Wire0 at y=1.0: rect y=[0.93,1.07]. Check at y=1.34: rect=[1.27,1.41]
    // Gap = 1.27 - 1.07 = 0.20, which is >= 0.14 (no hard) and < 0.21 (soft).
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, NetIdx.fromInt(0));
    const result = checker.checkSpacing(0, 3.0, 1.34, NetIdx.fromInt(1));
    try std.testing.expect(!result.hard_violation);
    try std.testing.expect(result.soft_penalty > 0.0);
}

test "InlineDrcChecker getMarkers returns empty initially" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    try std.testing.expectEqual(@as(usize, 0), checker.getMarkers().len);
}

test "InlineDrcChecker decayMarkers does not crash" {
    const alloc = std.testing.allocator;
    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var checker = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    checker.decayMarkers(0.5); // currently a no-op — must not crash
}

test "inline_drc PdkConfig setLayerRules stores values" {
    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(2, 0.28, 0.20, 0.06);
    try std.testing.expectApproxEqAbs(@as(f32, 0.28), drc_pdk.min_spacing[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.20), drc_pdk.min_width[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.06), drc_pdk.min_enclosure[2], 1e-6);
}

test "inline_drc PdkConfig setLayerRulesWithSameNet stores same_net_spacing" {
    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRulesWithSameNet(1, 0.14, 0.10, 0.14, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), drc_pdk.min_spacing[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), drc_pdk.same_net_spacing[1], 1e-6);
}

test "inline_drc PdkConfig setLayerRules layer>=16 is a no-op" {
    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(16, 99.0, 99.0, 99.0); // out of range → ignored
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), drc_pdk.min_spacing[15], 1e-6);
}

test "runDrc clean layout produces no violations" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    // Devices 5 µm apart (gap = 5 - 0.5 - 0.5 = 4 >> min_spacing).
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.dimensions[0] = .{ 1.0, 1.0 };
    devices.positions[1] = .{ 5.0, 0.0 };
    devices.dimensions[1] = .{ 1.0, 1.0 };

    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();

    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(0, 0.14, 0.14, 0.05);

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "runDrc detects device-device spacing violation (overlap)" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    // Device 0 bbox: x=[-0.5,0.5], Device 1 bbox: x=[0.2,1.2] → overlap.
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.dimensions[0] = .{ 1.0, 1.0 };
    devices.positions[1] = .{ 0.7, 0.0 };
    devices.dimensions[1] = .{ 1.0, 1.0 };

    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();

    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(0, 0.14, 0.14, 0.05);

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expect(violations.len > 0);
    try std.testing.expectEqual(core_types.DrcRule.min_spacing, violations[0].rule);
    try std.testing.expectEqual(@as(u8, 0), violations[0].layer);
}

test "runDrc detects route width violation" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer devices.deinit();

    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();
    // Route on layer 1 (M1) with width 0.05 < min_width[1] = 0.14.
    try routes.append(1, 0.0, 0.0, 5.0, 0.0, 0.05, NetIdx.fromInt(0));

    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(1, 0.14, 0.14, 0.05); // min_width[1] = 0.14

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expect(violations.len > 0);
    try std.testing.expectEqual(core_types.DrcRule.min_width, violations[0].rule);
    try std.testing.expectEqual(@as(u8, 1), violations[0].layer);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), violations[0].actual, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), violations[0].required, 1e-6);
}

test "runDrc route width at exactly min_width produces no violation" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer devices.deinit();

    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();
    // Route exactly at min_width — no violation.
    try routes.append(1, 0.0, 0.0, 5.0, 0.0, 0.14, NetIdx.fromInt(0));

    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(1, 0.14, 0.14, 0.05);

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "runDrc zero-dimension devices are skipped" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    // Both devices at exact same position but with zero footprint → skip.
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.dimensions[0] = .{ 0.0, 0.0 };
    devices.positions[1] = .{ 0.0, 0.0 };
    devices.dimensions[1] = .{ 0.0, 0.0 };

    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();

    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(0, 0.14, 0.14, 0.05);

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "runDrc empty layout produces no violations" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer devices.deinit();
    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();
    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

test "runDrc violation rect_a and rect_b indices reference source objects" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 3);
    defer devices.deinit();
    // Only devices 0 and 1 overlap; device 2 is far away.
    devices.positions[0] = .{ 0.0, 0.0 }; devices.dimensions[0] = .{ 1.0, 1.0 };
    devices.positions[1] = .{ 0.5, 0.0 }; devices.dimensions[1] = .{ 1.0, 1.0 };
    devices.positions[2] = .{ 20.0, 0.0 }; devices.dimensions[2] = .{ 1.0, 1.0 };

    var routes = try route_arrays_mod.RouteArrays.init(alloc, 0);
    defer routes.deinit();

    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    drc_pdk.setLayerRules(0, 0.14, 0.14, 0.05);

    const violations = try inline_drc_mod.runDrc(&devices, &routes, &drc_pdk, alloc);
    defer alloc.free(violations);
    try std.testing.expect(violations.len >= 1);
    // The violation must reference devices 0 and 1 (indices 0 < 1).
    try std.testing.expectEqual(@as(u32, 0), violations[0].rect_a);
    try std.testing.expectEqual(@as(u32, 1), violations[0].rect_b);
}

// ─── Detailed Router ─────────────────────────────────────────────────────────

test "DetailedRouter init and deinit" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
    try std.testing.expect(router.grid == null);
    try std.testing.expect(router.drc_checker == null);
}

test "DetailedRouter ripUpNet removes only that net from RouteArrays" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);
    const net2 = NetIdx.fromInt(2);

    try router.routes.append(1, 0.0, 0.0, 5.0, 0.0, 0.14, net0);
    try router.routes.append(1, 0.0, 1.0, 5.0, 1.0, 0.14, net1);
    try router.routes.append(2, 5.0, 0.0, 5.0, 1.0, 0.14, net0);
    try router.routes.append(1, 0.0, 2.0, 5.0, 2.0, 0.14, net2);
    try std.testing.expectEqual(@as(u32, 4), router.routes.len);

    router.ripUpNet(net0);

    try std.testing.expectEqual(@as(u32, 2), router.routes.len);
    // Remaining nets should be net1 and net2 in order.
    try std.testing.expectEqual(@as(u32, 1), router.routes.net[0].toInt());
    try std.testing.expectEqual(@as(u32, 2), router.routes.net[1].toInt());
}

test "DetailedRouter ripUpNet on empty routes is a no-op" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    router.ripUpNet(NetIdx.fromInt(0)); // must not crash
    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
}

test "DetailedRouter ripUpNet when no routes match is a no-op" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.routes.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, NetIdx.fromInt(5));
    router.ripUpNet(NetIdx.fromInt(0)); // net 0 not present
    try std.testing.expectEqual(@as(u32, 1), router.routes.len);
}

test "DetailedRouter getRoutes returns pointer into internal state" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    const before = router.getRoutes();
    try std.testing.expectEqual(@as(u32, 0), before.len);

    try router.routes.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, NetIdx.fromInt(0));
    const after = router.getRoutes();
    try std.testing.expectEqual(@as(u32, 1), after.len);
}

test "DetailedRouter routeAll simple 2-device circuit produces routes" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 10.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);
    try std.testing.expect(router.routes.len > 0);
    // Grid must have been built.
    try std.testing.expect(router.grid != null);
}

test "DetailedRouter routeAll routes have valid net assignments" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 8.0, 8.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        // All routes must be for net 0 (the only net in the circuit).
        try std.testing.expectEqual(@as(u32, 0), router.routes.net[i].toInt());
    }
}

test "DetailedRouter routeAll routes have positive widths" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 6.0, 6.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        try std.testing.expect(router.routes.width[i] > 0.0);
    }
}

test "DetailedRouter routeAll skips single-pin nets" {
    const alloc = std.testing.allocator;

    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer devices.deinit();
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.dimensions[0] = .{ 2.0, 1.0 };

    var nets = try NetArrays.init(alloc, 1);
    defer nets.deinit();

    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 1);
    defer pins.deinit();
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;

    var adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 1, 1);
    defer adj.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&devices, &nets, &pins, &adj, &pdk);
    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
}

test "DetailedRouter ripUpNet after routeAll reduces route count" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 10.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);
    const before = router.routes.len;
    try std.testing.expect(before > 0);

    router.ripUpNet(NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
    // After rip-up the route count must be strictly less.
    try std.testing.expect(router.routes.len < before);
}

test "DetailedRouter ripUpAndReroute with no grid returns zero iterations" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 5.0, 5.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();
    // No routeAll called → grid is null.
    const iters = try detailed_mod.ripUpAndReroute(
        &router, &circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk, 5);
    try std.testing.expectEqual(@as(u32, 0), iters);
}

test "DetailedRouter ripUpAndReroute after routeAll completes without crash" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 10.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);
    _ = try detailed_mod.ripUpAndReroute(
        &router, &circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk, 3);
    // After RRR, routes should still exist (the single net was rerouted).
    // Main invariant: no crash and routes is valid.
    _ = router.getRoutes();
}

// ─── PinAccessDB ─────────────────────────────────────────────────────────────

test "PinAccessDB empty pin list returns empty DB" {
    const alloc = std.testing.allocator;
    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 0);
    defer pins.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 5.0, &pins);
    defer grid.deinit();

    var db = try PinAccessDB.build(alloc, &da, &pins, &grid, &pdk);
    defer db.deinit();

    try std.testing.expectEqual(@as(usize, 0), db.aps.len);
}

test "PinAccessDB center AP always has cost 0" {
    const alloc = std.testing.allocator;
    const pea_mod = @import("../core/pin_edge_arrays.zig");

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pea_mod.PinEdgeArrays.init(alloc, 1);
    defer pins.deinit();
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.terminal[0] = .gate;
    pins.net[0] = NetIdx.fromInt(0);
    pins.computePinOffsets(&da);

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 10.0, &pins);
    defer grid.deinit();

    var db = try PinAccessDB.build(alloc, &da, &pins, &grid, &pdk);
    defer db.deinit();

    try std.testing.expect(db.aps[0].len > 0);
    // First AP is always the centre with cost 0.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), db.aps[0][0].cost, 1e-6);
}

test "PinAccessDB alternate APs have positive cost" {
    const alloc = std.testing.allocator;
    const pea_mod = @import("../core/pin_edge_arrays.zig");

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pea_mod.PinEdgeArrays.init(alloc, 1);
    defer pins.deinit();
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.terminal[0] = .drain;
    pins.net[0] = NetIdx.fromInt(0);
    pins.computePinOffsets(&da);

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 10.0, &pins);
    defer grid.deinit();

    var db = try PinAccessDB.build(alloc, &da, &pins, &grid, &pdk);
    defer db.deinit();

    // All non-centre APs (index >= 1) must have cost > 0.
    for (db.aps[0][1..]) |ap| {
        try std.testing.expect(ap.cost > 0.0);
    }
}

test "PinAccessDB all AP nodes are on valid layers" {
    const alloc = std.testing.allocator;
    const pea_mod = @import("../core/pin_edge_arrays.zig");

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pea_mod.PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();
    for (0..4) |i| {
        pins.device[i] = DeviceIdx.fromInt(0);
        pins.net[i] = NetIdx.fromInt(@intCast(i));
    }
    pins.terminal[0] = .gate;
    pins.terminal[1] = .drain;
    pins.terminal[2] = .source;
    pins.terminal[3] = .body;
    pins.computePinOffsets(&da);

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 10.0, &pins);
    defer grid.deinit();

    var db = try PinAccessDB.build(alloc, &da, &pins, &grid, &pdk);
    defer db.deinit();

    for (0..4) |p| {
        for (db.aps[p]) |ap| {
            try std.testing.expect(ap.layer < grid.num_layers);
        }
    }
}

test "PinAccessDB pin with invalid device index produces empty AP list" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.positions[0] = .{ 0.0, 0.0 };
    da.dimensions[0] = .{ 2.0, 1.0 };

    var pins = try pin_edge_mod.PinEdgeArrays.init(alloc, 1);
    defer pins.deinit();
    // Point to device index 99 which doesn't exist.
    pins.device[0] = DeviceIdx.fromInt(99);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 5.0, null);
    defer grid.deinit();

    var db = try PinAccessDB.build(alloc, &da, &pins, &grid, &pdk);
    defer db.deinit();

    // Invalid device → AP list should be empty rather than crashing.
    try std.testing.expectEqual(@as(usize, 0), db.aps[0].len);
}

// ─── A* Router ───────────────────────────────────────────────────────────────

test "AStarRouter default cost parameters" {
    const router = AStarRouter.init(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), router.via_cost, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), router.congestion_weight, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), router.wrong_way_cost, 1e-6);
    try std.testing.expect(router.drc_checker == null);
}

test "AStarRouter returns null when all grid cells are blocked" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer da.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 2.0, null);
    defer grid.deinit();

    // Block every cell on every layer.
    grid.markWorldRect(
        grid.bb_xmin - 1.0, grid.bb_ymin - 1.0,
        grid.bb_xmax + 1.0, grid.bb_ymax + 1.0,
        null,
    );

    const router = AStarRouter.init(alloc);
    const net = NetIdx.fromInt(99);

    const src = grid.worldToNode(0, grid.bb_xmin + 0.01, grid.bb_ymin + 0.01);
    const tgt = grid.worldToNode(0, grid.bb_xmax - 0.01, grid.bb_ymax - 0.01);

    if (src.eql(tgt)) return; // degenerate grid — skip

    const pathOpt = try router.findPath(&grid, src, tgt, net);
    // All cells blocked → A* cannot find a path.
    try std.testing.expect(pathOpt == null);
}

test "AStarRouter cannot traverse cells owned by a different net" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer da.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 5.0, null);
    defer grid.deinit();

    // Claim every cell on layer 0 for net 1.
    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);
    for (0..grid.layers[0].num_tracks) |a| {
        for (0..grid.cross_layers[0].num_tracks) |b| {
            const node = GridNode{ .layer = 0, .track_a = @intCast(a), .track_b = @intCast(b) };
            grid.claimCell(node, net1);
        }
    }

    const router = AStarRouter.init(alloc);
    const src = grid.worldToNode(0, grid.bb_xmin + 0.1, grid.bb_ymin + 0.1);
    const tgt = grid.worldToNode(0, grid.bb_xmax - 0.1, grid.bb_ymax - 0.1);
    if (src.eql(tgt)) return;

    // net0 cannot route through net1-owned cells on layer 0.
    // It may route on upper layers (via transitions); result may be null or a path.
    const pathOpt = try router.findPath(&grid, src, tgt, net0);
    if (pathOpt) |path_val| {
        var path = path_val;
        defer path.deinit();
        // If a path was found it must start and end at the requested nodes.
        try std.testing.expect(path.nodes[0].eql(src));
        try std.testing.expect(path.nodes[path.nodes.len - 1].eql(tgt));
    }
}

test "AStarRouter with DRC checker does not crash" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 2.0 };

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 10.0, null);
    defer grid.deinit();

    var checker = try InlineDrcChecker.init(alloc, &pdk, grid.bb_xmin, grid.bb_ymin, grid.bb_xmax, grid.bb_ymax);
    defer checker.deinit();

    var router = AStarRouter.init(alloc);
    router.drc_checker = &checker;

    const src = grid.worldToNode(0, grid.bb_xmin + 0.5, grid.bb_ymin + 0.5);
    const tgt = grid.worldToNode(0, grid.bb_xmax - 0.5, grid.bb_ymax - 0.5);
    const net = NetIdx.fromInt(0);

    const pathOpt = try router.findPath(&grid, src, tgt, net);
    if (pathOpt) |path_val| {
        var path = path_val;
        defer path.deinit();
        try std.testing.expect(path.nodes.len >= 1);
    }
}

// ─── Multi-Layer Grid ─────────────────────────────────────────────────────────

test "MultiLayerGrid markWorldRect blocks cells on specified layer only" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer da.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 5.0, null);
    defer grid.deinit();

    const net = NetIdx.fromInt(0);

    // Block a region on layer 0 only.
    const cx = (grid.bb_xmin + grid.bb_xmax) * 0.5;
    const cy = (grid.bb_ymin + grid.bb_ymax) * 0.5;
    grid.markWorldRect(cx - 0.5, cy - 0.5, cx + 0.5, cy + 0.5, 0);

    const node0 = grid.worldToNode(0, cx, cy);
    // Layer 0: must be blocked.
    try std.testing.expect(!grid.isCellRoutable(node0, net));

    if (grid.num_layers > 1) {
        const node1 = grid.worldToNode(1, cx, cy);
        // Layer 1: must still be free (rect was layer 0 only).
        try std.testing.expect(grid.isCellRoutable(node1, net));
    }
}

test "MultiLayerGrid markWorldRect null-layer blocks all layers" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer da.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 5.0, null);
    defer grid.deinit();

    const net = NetIdx.fromInt(0);
    const cx = (grid.bb_xmin + grid.bb_xmax) * 0.5;
    const cy = (grid.bb_ymin + grid.bb_ymax) * 0.5;

    // Block the same rect across ALL layers.
    grid.markWorldRect(cx - 0.5, cy - 0.5, cx + 0.5, cy + 0.5, null);

    for (0..grid.num_layers) |l| {
        const node = grid.worldToNode(@intCast(l), cx, cy);
        try std.testing.expect(!grid.isCellRoutable(node, net));
    }
}

test "MultiLayerGrid bounding box extends by margin on all sides" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 2.0 }; // bbox: [4,6]×[4,6]

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    const margin: f32 = 3.0;
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, margin, null);
    defer grid.deinit();

    try std.testing.expect(grid.bb_xmin <= 4.0 - margin + 1e-3);
    try std.testing.expect(grid.bb_ymin <= 4.0 - margin + 1e-3);
    try std.testing.expect(grid.bb_xmax >= 6.0 + margin - 1e-3);
    try std.testing.expect(grid.bb_ymax >= 6.0 + margin - 1e-3);
}

test "MultiLayerGrid cell congestion preserved after release" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer da.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 2.0, null);
    defer grid.deinit();

    const node = GridNode{ .layer = 0, .track_a = 0, .track_b = 0 };
    const net = NetIdx.fromInt(0);

    try std.testing.expectEqual(@as(u16, 0), grid.cellAtConst(node).congestion);
    grid.claimCell(node, net);
    try std.testing.expectEqual(@as(u16, 1), grid.cellAtConst(node).congestion);

    grid.releaseCell(node);
    // State freed but history (congestion) must remain for A* bias.
    try std.testing.expectEqual(@as(u16, 1), grid.cellAtConst(node).congestion);
    try std.testing.expect(grid.isCellRoutable(node, net));
}

test "MultiLayerGrid claim and release round-trip ownership" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 0);
    defer da.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 2.0, null);
    defer grid.deinit();

    const node = GridNode{ .layer = 0, .track_a = 0, .track_b = 0 };
    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Initially free: both nets can route here.
    try std.testing.expect(grid.isCellRoutable(node, net0));
    try std.testing.expect(grid.isCellRoutable(node, net1));

    // Claimed by net0: only net0 can route here.
    grid.claimCell(node, net0);
    try std.testing.expect(grid.isCellRoutable(node, net0));
    try std.testing.expect(!grid.isCellRoutable(node, net1));

    // Released: free again — both nets can route.
    grid.releaseCell(node);
    try std.testing.expect(grid.isCellRoutable(node, net0));
    try std.testing.expect(grid.isCellRoutable(node, net1));
}

test "MultiLayerGrid device obstacles are marked blocked" {
    const alloc = std.testing.allocator;

    var da = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 4.0, 4.0 }; // bbox: [3,7]×[3,7]

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(alloc, &da, &pdk, 5.0, null);
    defer grid.deinit();

    // A node at the device centre should be blocked on all layers.
    const net = NetIdx.fromInt(0);
    const node = grid.worldToNode(0, 5.0, 5.0);
    try std.testing.expect(!grid.isCellRoutable(node, net));
}

// ─── Integration: MazeRouter + runDrc ────────────────────────────────────────

test "MazeRouter routes pass runDrc width check" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 0.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try MazeRouter.init(alloc, 0.005);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    // Build a DRC config with SKY130 min widths.
    var drc_pdk = inline_drc_mod.PdkConfig.initDefault();
    // M1 route layer = 1, PDK array index for width = 1.
    drc_pdk.setLayerRules(1, pdk.min_spacing[0], pdk.min_width[0], 0.0);
    drc_pdk.setLayerRules(2, pdk.min_spacing[1], pdk.min_width[1], 0.0);

    const violations = try inline_drc_mod.runDrc(&circ.devices, router.getRoutes(), &drc_pdk, alloc);
    defer alloc.free(violations);

    // Every emitted segment should meet the min-width rule.
    for (violations) |v| {
        if (v.rule == .min_width) {
            std.debug.print("width violation: layer={d} actual={d:.4} required={d:.4}\n",
                .{ v.layer, v.actual, v.required });
        }
    }
    const width_violations = blk: {
        var count: usize = 0;
        for (violations) |v| { if (v.rule == .min_width) count += 1; }
        break :blk count;
    };
    try std.testing.expectEqual(@as(usize, 0), width_violations);
}

test "DetailedRouter routeAll all route layers are in valid range" {
    const alloc = std.testing.allocator;
    var circ = try buildSimpleCircuit(alloc, .{ 0.0, 0.0 }, .{ 10.0, 10.0 });
    defer circ.deinit();

    const pdk = layout_mod.PdkConfig.loadDefault(.sky130);
    var router = try DetailedRouter.init(alloc);
    defer router.deinit();

    try router.routeAll(&circ.devices, &circ.nets, &circ.pins, &circ.adj, &pdk);

    const n: usize = @intCast(router.routes.len);
    for (0..n) |i| {
        // Route layers 1–4 are valid for SKY130 (M1–M4).
        const layer = router.routes.layer[i];
        try std.testing.expect(layer >= 1 and layer <= 5);
    }
}
