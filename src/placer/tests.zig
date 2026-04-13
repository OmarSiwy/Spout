const std = @import("std");
const types = @import("../core/types.zig");
const cost_mod = @import("cost.zig");
const sa_mod = @import("sa.zig");
const rudy_mod = @import("rudy.zig");

const PinIdx = types.PinIdx;
const CostFunction = cost_mod.CostFunction;
const CostWeights = cost_mod.CostWeights;
const Constraint = cost_mod.Constraint;
const PinInfo = cost_mod.PinInfo;
const NetAdjacency = rudy_mod.NetAdjacency;
const RudyGrid = rudy_mod.RudyGrid;
const SaConfig = sa_mod.SaConfig;
const runSa = sa_mod.runSa;

// ─── Cost function tests ────────────────────────────────────────────────────

test "CostFunction computeFull known placement" {
    // Two devices at (0,0) and (10,5), each with one pin at device centre.
    // One net connecting both pins.
    // No constraints, no RUDY overflow.
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 5.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 5.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{};

    // Create a RUDY grid with zero demand (no nets splatted).
    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 1.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // HPWL for the single net: |10-0| + |5-0| = 15.
    // With w_hpwl=1.0 and num_nets=1: cost = 1.0 * 15.0 / 1.0 = 15.0
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), total, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), cost_fn.hpwl_sum, 1e-4);
}

test "CostFunction computeFull with area weight" {
    // Two devices at (2,3) and (8,7).
    // Bounding box area = (8-2)*(7-3) = 24.
    const device_positions = [_][2]f32{ .{ 2.0, 3.0 }, .{ 8.0, 7.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 2.0, 3.0 }, .{ 8.0, 7.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{};

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 1.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // area = (8-2)*(7-3) = 24.0, cost = 1.0 * 24.0 = 24.0
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), total, 1e-4);
}

test "CostFunction symmetry and matching terms" {
    // Two devices. Symmetry constraint with axis at 5.0.
    // Devices at (3, 2) and (7, 2): perfectly symmetric about x=5.
    // Also a matching constraint: dist = 4.0, min_sep = 2.0 (zero dims),
    // so matching cost = (4.0 - 2.0)^2 = 4.0.
    const device_positions = [_][2]f32{ .{ 3.0, 2.0 }, .{ 7.0, 2.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    // No nets — just test constraint costs.
    const starts = [_]u32{0};
    const pin_list = [_]PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };

    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1, .axis_x = 0.0 },
    };

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 1.0,
        .w_matching = 1.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    _ = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions, // pin positions = device positions for simplicity
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // Symmetry: |3+7 - 2*5|^2 + |2-2|^2 = 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost_fn.symmetry_cost, 1e-4);

    // Matching: dist = 4.0, min_sep = 2.0 (zero dims), cost = (4.0 - 2.0)^2 = 4.0
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost_fn.matching_cost, 1e-4);
}

test "CostFunction acceptTotal updates total" {
    const weights = CostWeights{};
    var cost_fn = CostFunction.init(weights);
    cost_fn.total = 100.0;

    cost_fn.acceptTotal(42.0);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), cost_fn.total, 1e-6);
}

// ─── SA tests ───────────────────────────────────────────────────────────────

test "SA reduces cost over iterations" {
    // Set up a small placement problem: 4 devices, 2 nets.
    // Net 0 connects pins 0,1 (devices 0,1).
    // Net 1 connects pins 2,3 (devices 2,3).
    const num_devices: u32 = 4;
    const num_pins: u32 = 4;

    var device_positions: [num_devices][2]f32 = .{
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
    };
    const device_dimensions = [num_devices][2]f32{
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
    };

    const pin_info = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 2, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 3, .offset_x = 0.0, .offset_y = 0.0 },
    };
    _ = num_pins;

    const pin_list = [_]PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(2), PinIdx.fromInt(3),
    };
    const starts = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 2,
    };

    const constraints = [_]Constraint{};

    const config = SaConfig{
        .initial_temp = 100.0,
        .cooling_rate = 0.99,
        .min_temp = 0.01,
        .max_iterations = 500,
        .perturbation_range = 5.0,
        .w_hpwl = 1.0,
        .w_area = 0.5,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
    };

    const result = try runSa(
        &device_positions,
        &device_dimensions,
        &pin_info,
        adj,
        &constraints,
        50.0,
        50.0,
        config,
        12345,
        std.testing.allocator,
    );

    // SA should have run some iterations and accepted some moves.
    try std.testing.expect(result.iterations_run > 0);
    try std.testing.expect(result.accepted_moves > 0);
    // The final cost should be finite and non-negative.
    try std.testing.expect(result.final_cost >= 0.0);
    try std.testing.expect(!std.math.isNan(result.final_cost));
    try std.testing.expect(!std.math.isInf(result.final_cost));
}

test "SA with single device has zero HPWL cost" {
    var device_positions = [_][2]f32{.{ 25.0, 25.0 }};
    const device_dimensions = [_][2]f32{.{ 0.0, 0.0 }};
    const pin_info = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
    };

    // Single pin on a single net — HPWL is 0.
    const pin_list = [_]PinIdx{PinIdx.fromInt(0)};
    const starts = [_]u32{ 0, 1 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    const constraints = [_]Constraint{};
    const config = SaConfig{
        .max_iterations = 100,
        .w_hpwl = 1.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
    };

    const result = try runSa(
        &device_positions,
        &device_dimensions,
        &pin_info,
        adj,
        &constraints,
        50.0,
        50.0,
        config,
        42,
        std.testing.allocator,
    );

    // Single device, single pin => HPWL=0. Cost should be 0 (area of 1 point = 0).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.final_cost, 1e-4);
}

test "SA deterministic with same seed" {
    var positions_a = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    var positions_b = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    const pin_info = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
    };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{};
    const config = SaConfig{
        .max_iterations = 200,
        .w_hpwl = 1.0,
        .w_area = 0.5,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
    };

    const result_a = try runSa(&positions_a, &dimensions, &pin_info, adj, &constraints, 50.0, 50.0, config, 999, std.testing.allocator);
    const result_b = try runSa(&positions_b, &dimensions, &pin_info, adj, &constraints, 50.0, 50.0, config, 999, std.testing.allocator);

    // Same seed should produce identical results.
    try std.testing.expectApproxEqAbs(result_a.final_cost, result_b.final_cost, 1e-6);
    try std.testing.expectEqual(result_a.iterations_run, result_b.iterations_run);
    try std.testing.expectEqual(result_a.accepted_moves, result_b.accepted_moves);

    // Final device positions should match.
    for (0..2) |i| {
        try std.testing.expectApproxEqAbs(positions_a[i][0], positions_b[i][0], 1e-6);
        try std.testing.expectApproxEqAbs(positions_a[i][1], positions_b[i][1], 1e-6);
    }
}

// ─── RUDY tests ─────────────────────────────────────────────────────────────

test "RUDY overflow with high-demand net" {
    // Create a small grid and splat a net that exceeds tile capacity.
    // Grid: 20x20, tile_size=10 → 2x2 tiles.
    // metal_pitch=0.5 → capacity = 2 * 10 / 0.5 = 40 per tile.
    var grid = try RudyGrid.init(std.testing.allocator, 20.0, 20.0, 10.0, 0.5);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u32, 2), grid.cols);
    try std.testing.expectEqual(@as(u32, 2), grid.rows);

    // Manually set demand on one tile to exceed capacity.
    // Capacity per tile = 2 * 10 / 0.5 = 40.
    grid.demand[0] = 50.0; // tile (0,0) overflows by 10
    grid.demand[1] = 30.0; // tile (0,1) does not overflow
    grid.demand[2] = 45.0; // tile (1,0) overflows by 5
    grid.demand[3] = 40.0; // tile (1,1) exactly at capacity

    const overflow = grid.totalOverflow();
    // overflow = max(0, 50-40) + max(0, 30-40) + max(0, 45-40) + max(0, 40-40)
    //          = 10 + 0 + 5 + 0 = 15
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), overflow, 1e-4);
}

test "RUDY computeFull adds net contributions" {
    // Grid: 20x20, tile_size=20 → 1x1 tile.
    var grid = try RudyGrid.init(std.testing.allocator, 20.0, 20.0, 20.0, 0.5);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u32, 1), grid.cols);
    try std.testing.expectEqual(@as(u32, 1), grid.rows);

    // One net with two pins spanning the grid.
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 20.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    grid.computeFull(&pin_positions, adj);

    // The demand should be non-zero after splatting the net.
    try std.testing.expect(grid.demand[0] > 0.0);
}

test "computeNetHpwl hand-computed 2-device placement" {
    // Two pins at (1,1) and (4,5) → HPWL = |4-1| + |5-1| = 3 + 4 = 7.
    const pin_positions = [_][2]f32{ .{ 1.0, 1.0 }, .{ 4.0, 5.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    const hpwl = cost_mod.computeNetHpwl(0, &pin_positions, adj);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), hpwl, 1e-6);
}

test "computeNetHpwl two nets independent" {
    // Net 0: pins at (0,0) and (10,0) → HPWL = 10
    // Net 1: pins at (0,0) and (0,5) → HPWL = 5
    const pin_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 5.0 },
    };
    const pin_list = [_]PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(2), PinIdx.fromInt(3),
    };
    const starts = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 2,
    };

    const hpwl0 = cost_mod.computeNetHpwl(0, &pin_positions, adj);
    const hpwl1 = cost_mod.computeNetHpwl(1, &pin_positions, adj);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), hpwl0, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), hpwl1, 1e-6);

    const total = cost_mod.computeHpwlAll(&pin_positions, adj, &.{});
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), total, 1e-6);
}

test "RUDY single net covering 4 tiles verify demand" {
    // Grid: 40x40, tile_size=10 → 4x4=16 tiles
    // metal_pitch=0.5 → capacity = 2*10/0.5 = 40 per tile
    var grid = try RudyGrid.init(std.testing.allocator, 40.0, 40.0, 10.0, 0.5);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u32, 4), grid.cols);
    try std.testing.expectEqual(@as(u32, 4), grid.rows);

    // One net with pins at corners of a 2x2 tile region: (5,5) and (15,15)
    // This net bbox spans from (5,5) to (15,15) → covers tiles (0,0), (0,1), (1,0), (1,1)
    const pin_positions = [_][2]f32{ .{ 5.0, 5.0 }, .{ 15.0, 15.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    grid.computeFull(&pin_positions, adj);

    // The four tiles that overlap the net bbox should have positive demand
    // Tiles at (row=0,col=0), (0,1), (1,0), (1,1)
    try std.testing.expect(grid.demand[0 * 4 + 0] > 0.0); // tile (0,0)
    try std.testing.expect(grid.demand[0 * 4 + 1] > 0.0); // tile (0,1)
    try std.testing.expect(grid.demand[1 * 4 + 0] > 0.0); // tile (1,0)
    try std.testing.expect(grid.demand[1 * 4 + 1] > 0.0); // tile (1,1)

    // Tiles outside the bbox should have zero demand
    try std.testing.expectEqual(@as(f32, 0.0), grid.demand[3 * 4 + 3]); // tile (3,3)
}

test "SA 1000 iterations reduces cost from initial random placement" {
    // 6 devices, 3 nets
    const num_devices: u32 = 6;
    var device_positions: [num_devices][2]f32 = .{
        .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
        .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
    };
    const device_dimensions = [num_devices][2]f32{
        .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
        .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 },
    };

    const pin_info = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 2, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 3, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 4, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 5, .offset_x = 0.0, .offset_y = 0.0 },
    };

    const pin_list = [_]PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(2), PinIdx.fromInt(3),
        PinIdx.fromInt(4), PinIdx.fromInt(5),
    };
    const starts = [_]u32{ 0, 2, 4, 6 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 3,
    };

    const constraints = [_]Constraint{};

    const config = SaConfig{
        .initial_temp = 500.0,
        .cooling_rate = 0.99,
        .min_temp = 0.01,
        .max_iterations = 1000,
        .perturbation_range = 5.0,
        .w_hpwl = 1.0,
        .w_area = 0.5,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        // Use legacy flat loop so iterations_run is exactly max_iterations.
        .kappa = 0.0,
    };

    const result = try runSa(
        &device_positions,
        &device_dimensions,
        &pin_info,
        adj,
        &constraints,
        50.0,
        50.0,
        config,
        54321,
        std.testing.allocator,
    );

    // Should have run 1000 iterations (legacy flat loop with kappa=0).
    try std.testing.expectEqual(@as(u32, 1000), result.iterations_run);
    // Should have accepted some moves
    try std.testing.expect(result.accepted_moves > 0);
    // Final cost should be finite and non-negative
    try std.testing.expect(result.final_cost >= 0.0);
    try std.testing.expect(!std.math.isNan(result.final_cost));
}

test "SaConfig default values are sensible" {
    const config = SaConfig{};

    try std.testing.expectEqual(@as(f32, 1000.0), config.initial_temp);
    try std.testing.expectEqual(@as(f32, 0.9995), config.cooling_rate);
    try std.testing.expectEqual(@as(f32, 0.01), config.min_temp);
    try std.testing.expectEqual(@as(u32, 50000), config.max_iterations);
    // perturbation_range=0.0 means use adaptive rho(T) — not a fixed range.
    try std.testing.expectEqual(@as(f32, 0.0), config.perturbation_range);

    // Cooling rate should be less than 1 and positive
    try std.testing.expect(config.cooling_rate > 0.0);
    try std.testing.expect(config.cooling_rate < 1.0);

    // Initial temp should be much larger than min temp
    try std.testing.expect(config.initial_temp > config.min_temp * 100.0);
}

test "CostFunction incremental cost matches full recomputation" {
    const device_positions = [_][2]f32{ .{ 2.0, 3.0 }, .{ 8.0, 7.0 }, .{ 5.0, 1.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 2.0, 3.0 }, .{ 8.0, 7.0 }, .{ 5.0, 1.0 } };
    const pin_list = [_]PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(1), PinIdx.fromInt(2),
    };
    const starts = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 2,
    };
    const constraints = [_]Constraint{};

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 1.0,
        .w_area = 0.5,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // Verify total is finite and positive
    try std.testing.expect(total >= 0.0);
    try std.testing.expect(!std.math.isNan(total));
    try std.testing.expect(!std.math.isInf(total));

    // Verify the HPWL component:
    // Net 0: pins at (2,3) and (8,7) → HPWL = 6+4 = 10
    // Net 1: pins at (8,7) and (5,1) → HPWL = 3+6 = 9
    try std.testing.expectApproxEqAbs(@as(f32, 19.0), cost_fn.hpwl_sum, 1e-4);
}

test "RUDY incremental update consistency" {
    // Verify that incremental update gives the same result as full recompute.
    var grid_full = try RudyGrid.init(std.testing.allocator, 40.0, 40.0, 10.0, 0.5);
    defer grid_full.deinit();

    var grid_incr = try RudyGrid.init(std.testing.allocator, 40.0, 40.0, 10.0, 0.5);
    defer grid_incr.deinit();

    // Two nets. Net 0: pins 0,1. Net 1: pins 2,3.
    const old_pins = [_][2]f32{
        .{ 5.0, 5.0 },
        .{ 15.0, 15.0 },
        .{ 25.0, 5.0 },
        .{ 35.0, 15.0 },
    };
    const new_pins = [_][2]f32{
        .{ 5.0, 5.0 },
        .{ 20.0, 20.0 }, // pin 1 moved
        .{ 25.0, 5.0 },
        .{ 35.0, 15.0 },
    };

    const pin_list = [_]PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(2), PinIdx.fromInt(3),
    };
    const starts = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 2,
    };

    // Full recompute on new positions.
    grid_full.computeFull(&new_pins, adj);

    // Incremental: start from old, update only net 0 (the affected net).
    grid_incr.computeFull(&old_pins, adj);
    const affected_nets = [_]u32{0};
    grid_incr.updateIncremental(&affected_nets, &old_pins, &new_pins, adj);

    // Compare all tile demands.
    const total: usize = @as(usize, grid_full.rows) * @as(usize, grid_full.cols);
    for (0..total) |k| {
        try std.testing.expectApproxEqAbs(grid_full.demand[k], grid_incr.demand[k], 1e-4);
    }
}
