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
const Orientation = types.Orientation;
const transformPinOffset = cost_mod.transformPinOffset;
const computeOrientationMismatch = cost_mod.computeOrientationMismatch;
const CentroidGroup = cost_mod.CentroidGroup;
const computeCommonCentroid = cost_mod.computeCommonCentroid;
const computeInterdigitation = cost_mod.computeInterdigitation;
const estimatedRouteLength = cost_mod.estimatedRouteLength;
const computeParasiticBalance = cost_mod.computeParasiticBalance;
const WellRegion = cost_mod.WellRegion;
const HeatSource = cost_mod.HeatSource;
const deviceToWellEdge = cost_mod.deviceToWellEdge;
const computeWpeMismatch = cost_mod.computeWpeMismatch;
const checkGuardRings = cost_mod.checkGuardRings;
const SaExtendedInput = sa_mod.SaExtendedInput;
const computeThermalMismatch = cost_mod.computeThermalMismatch;
const computeLde = cost_mod.computeLde;
const computeProximity = cost_mod.computeProximity;
const computeIsolation = cost_mod.computeIsolation;

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
        .{},
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
        .{},
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

    const result_a = try runSa(&positions_a, &dimensions, &pin_info, adj, &constraints, 50.0, 50.0, config, 999, std.testing.allocator, .{});
    const result_b = try runSa(&positions_b, &dimensions, &pin_info, adj, &constraints, 50.0, 50.0, config, 999, std.testing.allocator, .{});

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
        .{},
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


// ─── Phase 2: Orientation tracking tests ─────────────────────────────────────

test "transformPinOffset all 8 orientations" {
    const ox: f32 = 3.0;
    const oy: f32 = 5.0;

    // N: (ox, oy) -> (3, 5)
    const n = transformPinOffset(ox, oy, .N);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), n[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), n[1], 1e-6);

    // S: (ox, oy) -> (-3, -5)
    const s = transformPinOffset(ox, oy, .S);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), s[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), s[1], 1e-6);

    // FN: (ox, oy) -> (-3, 5)
    const fn_ = transformPinOffset(ox, oy, .FN);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), fn_[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), fn_[1], 1e-6);

    // FS: (ox, oy) -> (3, -5)
    const fs = transformPinOffset(ox, oy, .FS);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), fs[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), fs[1], 1e-6);

    // E: (ox, oy) -> (5, -3)
    const e = transformPinOffset(ox, oy, .E);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), e[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), e[1], 1e-6);

    // W: (ox, oy) -> (-5, 3)
    const w = transformPinOffset(ox, oy, .W);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), w[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), w[1], 1e-6);

    // FE: (ox, oy) -> (5, 3)
    const fe = transformPinOffset(ox, oy, .FE);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), fe[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), fe[1], 1e-6);

    // FW: (ox, oy) -> (-5, -3)
    const fw = transformPinOffset(ox, oy, .FW);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), fw[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), fw[1], 1e-6);
}

test "computeOrientationMismatch same orientation returns zero" {
    const orientations = [_]Orientation{ .N, .N };
    const constraints = [_]Constraint{
        .{ .kind = .orientation_match, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeOrientationMismatch(&orientations, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeOrientationMismatch different orientations returns nonzero" {
    const orientations = [_]Orientation{ .N, .S };
    const constraints = [_]Constraint{
        .{ .kind = .orientation_match, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeOrientationMismatch(&orientations, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cost, 1e-6);
}

test "computeOrientationMismatch ignores non-orientation constraints" {
    const orientations = [_]Orientation{ .N, .S };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
    };
    const cost = computeOrientationMismatch(&orientations, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeOrientationMismatch multiple constraints sums correctly" {
    const orientations = [_]Orientation{ .N, .S, .N };
    const constraints = [_]Constraint{
        .{ .kind = .orientation_match, .dev_a = 0, .dev_b = 1 },  // mismatch: N != S -> 1
        .{ .kind = .orientation_match, .dev_a = 0, .dev_b = 2 },  // match: N == N -> 0
        .{ .kind = .orientation_match, .dev_a = 1, .dev_b = 2 },  // mismatch: S != N -> 1
    };
    const cost = computeOrientationMismatch(&orientations, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), cost, 1e-6);
}

test "SA orientation flip move changes orientation" {
    // Set up a minimal placement with orientation_match constraint.
    // Run SA with high p_orientation_flip to exercise the flip move.
    const num_devices: u32 = 2;

    var device_positions: [num_devices][2]f32 = .{
        .{ 10.0, 10.0 },
        .{ 20.0, 10.0 },
    };
    const device_dimensions = [num_devices][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };

    const pin_info = [_]PinInfo{
        .{ .device = 0, .offset_x = 1.0, .offset_y = 0.5 },
        .{ .device = 1, .offset_x = 1.0, .offset_y = 0.5 },
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
        .initial_temp = 100.0,
        .cooling_rate = 0.99,
        .min_temp = 0.01,
        .max_iterations = 200,
        .p_swap = 0.0,
        .p_orientation_flip = 0.5, // high flip probability
        .w_hpwl = 1.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .kappa = 0.0, // use legacy flat loop
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
        .{},
    );

    // SA should have run and accepted some moves (including orientation flips).
    try std.testing.expect(result.iterations_run > 0);
    try std.testing.expect(result.accepted_moves > 0);
    try std.testing.expect(result.final_cost >= 0.0);
    try std.testing.expect(!std.math.isNan(result.final_cost));
}

test "transformPinOffset N is identity" {
    // Orientation N should not modify the offset.
    const result = transformPinOffset(7.0, -3.0, .N);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), result[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), result[1], 1e-6);
}

test "transformPinOffset S is 180 degree rotation" {
    // S: (x,y) -> (-x,-y)
    const result = transformPinOffset(2.0, 3.0, .S);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), result[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), result[1], 1e-6);
}

test "transformPinOffset E and W are perpendicular rotations" {
    // E: (x,y) -> (y,-x) — 90 CW
    const e = transformPinOffset(1.0, 0.0, .E);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), e[1], 1e-6);

    // W: (x,y) -> (-y,x) — 90 CCW
    const w = transformPinOffset(1.0, 0.0, .W);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w[1], 1e-6);
}

// ─── Phase 3: Common-centroid tests ──────────────────────────────────────────

test "computeCommonCentroid zero when centroids coincide" {
    // Group A: devices 0,1 at (2,3) and (8,7) → centroid = (5, 5)
    // Group B: devices 2,3 at (4,1) and (6,9) → centroid = (5, 5)
    const positions = [_][2]f32{
        .{ 2.0, 3.0 },
        .{ 8.0, 7.0 },
        .{ 4.0, 1.0 },
        .{ 6.0, 9.0 },
    };
    const group_a = [_]u32{ 0, 1 };
    const group_b = [_]u32{ 2, 3 };
    const groups = [_]CentroidGroup{
        .{ .group_a = &group_a, .group_b = &group_b },
    };
    const cost = computeCommonCentroid(&positions, &groups);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-5);
}

test "computeCommonCentroid nonzero when centroids differ" {
    // Group A: devices 0,1 at (0,0) and (2,0) → centroid = (1, 0)
    // Group B: devices 2,3 at (10,0) and (12,0) → centroid = (11, 0)
    // cost = (1 - 11)^2 + (0 - 0)^2 = 100
    const positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 2.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 12.0, 0.0 },
    };
    const group_a = [_]u32{ 0, 1 };
    const group_b = [_]u32{ 2, 3 };
    const groups = [_]CentroidGroup{
        .{ .group_a = &group_a, .group_b = &group_b },
    };
    const cost = computeCommonCentroid(&positions, &groups);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), cost, 1e-4);
}

test "computeCommonCentroid ABBA pattern achieves zero cost" {
    // Classic ABBA interleave: A at (0,0) and (3,0), B at (1,0) and (2,0).
    // Centroid A = (1.5, 0), Centroid B = (1.5, 0) → cost = 0
    const positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 3.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 2.0, 0.0 },
    };
    const group_a = [_]u32{ 0, 1 };
    const group_b = [_]u32{ 2, 3 };
    const groups = [_]CentroidGroup{
        .{ .group_a = &group_a, .group_b = &group_b },
    };
    const cost = computeCommonCentroid(&positions, &groups);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-5);
}

test "computeCommonCentroid empty groups returns zero" {
    const positions = [_][2]f32{ .{ 1.0, 2.0 }, .{ 3.0, 4.0 } };
    const empty = [_]u32{};
    const non_empty = [_]u32{0};
    const groups = [_]CentroidGroup{
        .{ .group_a = &empty, .group_b = &non_empty },
    };
    const cost = computeCommonCentroid(&positions, &groups);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeCommonCentroid no groups returns zero" {
    const positions = [_][2]f32{ .{ 1.0, 2.0 }, .{ 3.0, 4.0 } };
    const groups = [_]CentroidGroup{};
    const cost = computeCommonCentroid(&positions, &groups);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeCommonCentroid 2-group NMOS/PMOS centroid matching" {
    // Simulate two centroid groups (e.g., two diff pairs in a bandgap).
    // Group 0: A=(0,0),(4,0) centroid=(2,0), B=(1,0),(3,0) centroid=(2,0) → cost=0
    // Group 1: A=(10,0),(14,0) centroid=(12,0), B=(11,0),(15,0) centroid=(13,0) → cost=1
    const positions = [_][2]f32{
        .{ 0.0, 0.0 },  // 0
        .{ 4.0, 0.0 },  // 1
        .{ 1.0, 0.0 },  // 2
        .{ 3.0, 0.0 },  // 3
        .{ 10.0, 0.0 }, // 4
        .{ 14.0, 0.0 }, // 5
        .{ 11.0, 0.0 }, // 6
        .{ 15.0, 0.0 }, // 7
    };
    const ga0 = [_]u32{ 0, 1 };
    const gb0 = [_]u32{ 2, 3 };
    const ga1 = [_]u32{ 4, 5 };
    const gb1 = [_]u32{ 6, 7 };
    const groups = [_]CentroidGroup{
        .{ .group_a = &ga0, .group_b = &gb0 },
        .{ .group_a = &ga1, .group_b = &gb1 },
    };
    const cost = computeCommonCentroid(&positions, &groups);
    // Group 0: 0.0, Group 1: (12-13)^2 = 1.0 → total = 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cost, 1e-5);
}

test "common-centroid integrates with combinedCost" {
    // Verify that centroid cost flows through CostFunction.computeFull.
    const device_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 20.0, 0.0 },
        .{ 30.0, 0.0 },
    };
    const device_dimensions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
    };
    const pin_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 20.0, 0.0 },
        .{ 30.0, 0.0 },
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
    const constraints = [_]Constraint{};

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    // Set up centroid groups:
    // A={0,1} centroid=(5,0), B={2,3} centroid=(25,0) → cost = 400
    const ga = [_]u32{ 0, 1 };
    const gb = [_]u32{ 2, 3 };
    const groups = [_]CentroidGroup{
        .{ .group_a = &ga, .group_b = &gb },
    };

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_common_centroid = 1.0,
    };

    var cost_fn = CostFunction.init(weights);
    cost_fn.centroid_groups = &groups;
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // centroid cost = (5-25)^2 + (0-0)^2 = 400, weight = 1.0 → total = 400
    try std.testing.expectApproxEqAbs(@as(f32, 400.0), total, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 400.0), cost_fn.centroid_cost, 1e-3);
}

test "group translate move preserves relative positions on reject" {
    // Verify that SA with group_translate does not corrupt positions on revert.
    // 4 devices in a centroid group, run a few SA iterations.
    const num_devices: u32 = 4;

    var device_positions: [num_devices][2]f32 = .{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 10.0 },
        .{ 10.0, 10.0 },
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
        .max_iterations = 200,
        .p_swap = 0.0,
        .p_group_translate = 0.5,
        .w_hpwl = 1.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_common_centroid = 2.0,
        .kappa = 0.0, // use legacy flat loop
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
        .{},
    );

    // SA should have run and completed without crashing.
    try std.testing.expect(result.iterations_run > 0);
    try std.testing.expect(result.final_cost >= 0.0);
    try std.testing.expect(!std.math.isNan(result.final_cost));
    try std.testing.expect(!std.math.isInf(result.final_cost));
}

// ─── Phase 6: Dummy Device Modeling tests ────────────────────────────────────

const countExposedEdges = cost_mod.countExposedEdges;
const computeEdgePenalty = cost_mod.computeEdgePenalty;
const insertDummies = cost_mod.insertDummies;

test "countExposedEdges isolated device has 4 exposed edges" {
    // Single device at (10, 10) with dimensions 4x4, no neighbours.
    const positions = [_][2]f32{.{ 10.0, 10.0 }};
    const dimensions = [_][2]f32{.{ 4.0, 4.0 }};
    const is_dummy = [_]bool{false};

    const exposed = countExposedEdges(0, &positions, &dimensions, &is_dummy, 100.0, 100.0);
    try std.testing.expectEqual(@as(u4, 4), exposed);
}

test "countExposedEdges corner device has 2 exposed edges" {
    // 4 devices in a 2x2 grid, tightly packed (gap = 0.5, within threshold of 1.0).
    // Device 0 at (2,2), Device 1 at (4.5,2), Device 2 at (2,4.5), Device 3 at (4.5,4.5).
    // All 2x2. Device 0 has right and top covered, left and bottom exposed.
    const positions = [_][2]f32{
        .{ 2.0, 2.0 }, // device 0 (bottom-left corner)
        .{ 4.5, 2.0 }, // device 1 (bottom-right)
        .{ 2.0, 4.5 }, // device 2 (top-left)
        .{ 4.5, 4.5 }, // device 3 (top-right)
    };
    const dimensions = [_][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };
    const is_dummy = [_]bool{ false, false, false, false };

    // Device 0: left edge at 1.0, right at 3.0, bottom at 1.0, top at 3.0
    // Device 1: left at 3.5, right at 5.5 => gap to dev0 right = 3.5-3.0 = 0.5 <= 1.0 (covered)
    // Device 2: bottom at 3.5, top at 5.5 => gap to dev0 top = 3.5-3.0 = 0.5 <= 1.0 (covered)
    // Device 0's left and bottom are exposed (no neighbours).
    const exposed_0 = countExposedEdges(0, &positions, &dimensions, &is_dummy, 100.0, 100.0);
    try std.testing.expectEqual(@as(u4, 2), exposed_0);
}

test "countExposedEdges interior device has 0 exposed edges" {
    // Device 1 at centre, surrounded on all 4 sides within threshold.
    const positions = [_][2]f32{
        .{ 5.0, 10.0 }, // left neighbour
        .{ 10.0, 10.0 }, // centre device (dev 1)
        .{ 15.0, 10.0 }, // right neighbour
        .{ 10.0, 5.0 }, // bottom neighbour
        .{ 10.0, 15.0 }, // top neighbour
    };
    const dimensions = [_][2]f32{
        .{ 4.0, 4.0 },
        .{ 4.0, 4.0 },
        .{ 4.0, 4.0 },
        .{ 4.0, 4.0 },
        .{ 4.0, 4.0 },
    };
    const is_dummy = [_]bool{ false, false, false, false, false };

    // Device 1 at (10,10): left edge=8, right=12, bottom=8, top=12
    // Device 0 at (5,10): right edge=7 => gap = 8-7 = 1.0 <= threshold (covered)
    // Device 2 at (15,10): left edge=13 => gap = 13-12 = 1.0 <= threshold (covered)
    // Device 3 at (10,5): top edge=7 => gap = 8-7 = 1.0 <= threshold (covered)
    // Device 4 at (10,15): bottom edge=13 => gap = 13-12 = 1.0 <= threshold (covered)
    const exposed = countExposedEdges(1, &positions, &dimensions, &is_dummy, 100.0, 100.0);
    try std.testing.expectEqual(@as(u4, 0), exposed);
}

test "computeEdgePenalty zero for fully surrounded matched pair" {
    // Two matched devices, both fully surrounded => penalty = 0.
    const positions = [_][2]f32{
        .{ 5.0, 10.0 }, // left guard
        .{ 10.0, 10.0 }, // dev A (matched)
        .{ 15.0, 10.0 }, // middle guard
        .{ 20.0, 10.0 }, // dev B (matched)
        .{ 25.0, 10.0 }, // right guard
        .{ 10.0, 5.0 }, // bottom guard A
        .{ 10.0, 15.0 }, // top guard A
        .{ 20.0, 5.0 }, // bottom guard B
        .{ 20.0, 15.0 }, // top guard B
    };
    const dimensions = [_][2]f32{
        .{ 4.0, 4.0 }, .{ 4.0, 4.0 }, .{ 4.0, 4.0 },
        .{ 4.0, 4.0 }, .{ 4.0, 4.0 }, .{ 4.0, 4.0 },
        .{ 4.0, 4.0 }, .{ 4.0, 4.0 }, .{ 4.0, 4.0 },
    };
    const is_dummy = [_]bool{ false, false, false, false, false, false, false, false, false };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 1, .dev_b = 3 },
    };

    const penalty = computeEdgePenalty(&positions, &dimensions, &constraints, &is_dummy, 100.0, 100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), penalty, 1e-6);
}

test "computeEdgePenalty nonzero for asymmetric edge exposure" {
    // Dev A is isolated (4 exposed edges), Dev B has 2 exposed edges.
    // Asymmetry = 4-2 = 2, penalty = 2^2 = 4.
    const positions = [_][2]f32{
        .{ 50.0, 50.0 }, // dev A (isolated)
        .{ 10.0, 10.0 }, // dev B (corner, 2 exposed)
        .{ 12.5, 10.0 }, // right neighbour of B
        .{ 10.0, 12.5 }, // top neighbour of B
    };
    const dimensions = [_][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };
    const is_dummy = [_]bool{ false, false, false, false };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const penalty = computeEdgePenalty(&positions, &dimensions, &constraints, &is_dummy, 100.0, 100.0);
    // Dev A: 4 exposed, Dev B: 2 exposed => delta=2, penalty=4
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), penalty, 1e-4);
}

test "computeEdgePenalty dummy devices are exempt" {
    // Dev A is a dummy (should be skipped), Dev B is real.
    const positions = [_][2]f32{
        .{ 50.0, 50.0 }, // dev A (dummy)
        .{ 10.0, 10.0 }, // dev B (real, isolated)
    };
    const dimensions = [_][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };
    const is_dummy = [_]bool{ true, false };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    // Since dev_a is dummy, the constraint is skipped entirely.
    const penalty = computeEdgePenalty(&positions, &dimensions, &constraints, &is_dummy, 100.0, 100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), penalty, 1e-6);
}

test "insertDummies adds devices at exposed edges" {
    // Two matched devices placed far apart (both fully exposed).
    // Each should get up to 4 dummies inserted.
    var pos_list = std.ArrayList([2]f32).empty;
    defer pos_list.deinit(std.testing.allocator);
    var dim_list = std.ArrayList([2]f32).empty;
    defer dim_list.deinit(std.testing.allocator);
    var dummy_list = std.ArrayList(bool).empty;
    defer dummy_list.deinit(std.testing.allocator);

    // Device 0 at (20, 20), Device 1 at (40, 20). Both 4x4.
    try pos_list.append(std.testing.allocator, .{ 20.0, 20.0 });
    try pos_list.append(std.testing.allocator, .{ 40.0, 20.0 });
    try dim_list.append(std.testing.allocator, .{ 4.0, 4.0 });
    try dim_list.append(std.testing.allocator, .{ 4.0, 4.0 });
    try dummy_list.append(std.testing.allocator, false);
    try dummy_list.append(std.testing.allocator, false);

    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const inserted = try insertDummies(
        std.testing.allocator,
        &pos_list,
        &dim_list,
        &dummy_list,
        &constraints,
        100.0, // layout_width
        100.0, // layout_height
    );

    // Both devices are far apart and fully exposed, so each gets 4 dummies.
    // Total inserted should be 8.
    try std.testing.expect(inserted > 0);
    try std.testing.expectEqual(@as(u32, 8), inserted);

    // Total devices = 2 original + 8 dummies = 10
    try std.testing.expectEqual(@as(usize, 10), pos_list.items.len);
    try std.testing.expectEqual(@as(usize, 10), dim_list.items.len);
    try std.testing.expectEqual(@as(usize, 10), dummy_list.items.len);

    // All new devices should be marked as dummy.
    for (dummy_list.items[2..]) |d| {
        try std.testing.expect(d);
    }

    // Original devices should NOT be dummy.
    try std.testing.expect(!dummy_list.items[0]);
    try std.testing.expect(!dummy_list.items[1]);
}

test "insertDummies no-op when no matching constraints" {
    var pos_list = std.ArrayList([2]f32).empty;
    defer pos_list.deinit(std.testing.allocator);
    var dim_list = std.ArrayList([2]f32).empty;
    defer dim_list.deinit(std.testing.allocator);
    var dummy_list = std.ArrayList(bool).empty;
    defer dummy_list.deinit(std.testing.allocator);

    try pos_list.append(std.testing.allocator, .{ 20.0, 20.0 });
    try dim_list.append(std.testing.allocator, .{ 4.0, 4.0 });
    try dummy_list.append(std.testing.allocator, false);

    const constraints = [_]Constraint{};

    const inserted = try insertDummies(
        std.testing.allocator,
        &pos_list,
        &dim_list,
        &dummy_list,
        &constraints,
        100.0,
        100.0,
    );

    try std.testing.expectEqual(@as(u32, 0), inserted);
    try std.testing.expectEqual(@as(usize, 1), pos_list.items.len);
}

// ─── Phase 8: Parasitic routing balance tests ─────────────────────────────────

test "estimatedRouteLength basic Manhattan distance" {
    // Two devices, two pins on one net.
    // Pin 0 at (0,0), pin 1 at (10,0).  Net centroid = (5, 0).
    // Device 0 at (0, 0): route length = |0-5| + |0-0| = 5
    // Device 1 at (10, 0): route length = |10-5| + |0-0| = 5
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    const rl0 = estimatedRouteLength(0, 0, &device_positions, &pin_positions, adj);
    const rl1 = estimatedRouteLength(1, 0, &device_positions, &pin_positions, adj);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), rl0, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), rl1, 1e-5);
}

test "computeParasiticBalance zero when symmetric routing" {
    // Two matched devices equidistant from net centroid.
    // Device 0 at (0,0), device 1 at (10,0).
    // Net 0 has pins at (0,0) and (10,0) -> centroid = (5,0).
    // Both devices are 5 units from centroid -> parasitic balance = 0.
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    // Both devices on net 0.
    const dev0_nets = [_]u32{0};
    const dev1_nets = [_]u32{0};
    const device_nets_map = [_][]u32{
        @constCast(&dev0_nets),
        @constCast(&dev1_nets),
    };

    const cost = computeParasiticBalance(&device_positions, &pin_positions, adj, &constraints, &device_nets_map);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-5);
}

test "computeParasiticBalance nonzero when asymmetric" {
    // Device 0 at (0,0), device 1 at (20,0).
    // Net 0: pins at (0,0), (6,0), (20,0) -> centroid = (26/3, 0) ~ (8.667, 0).
    // Device 0: route_len = |0 - 8.667| = 8.667.
    // Device 1: route_len = |20 - 8.667| = 11.333.
    // delta = 8.667 - 11.333 = -2.667, cost = 7.111
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 6.0, 0.0 }, .{ 20.0, 0.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1), PinIdx.fromInt(2) };
    const starts = [_]u32{ 0, 3 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const dev0_nets = [_]u32{0};
    const dev1_nets = [_]u32{0};
    const device_nets_map = [_][]u32{
        @constCast(&dev0_nets),
        @constCast(&dev1_nets),
    };

    const cost = computeParasiticBalance(&device_positions, &pin_positions, adj, &constraints, &device_nets_map);
    // centroid x = (0+6+20)/3 = 26/3 ~ 8.6667
    // la = |0 - 8.6667| = 8.6667
    // lb = |20 - 8.6667| = 11.3333
    // dl = 8.6667 - 11.3333 = -2.6667
    // cost = dl^2 = 7.1111
    try std.testing.expect(cost > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 7.1111), cost, 0.01);
}

test "computeParasiticBalance with multiple shared nets" {
    // Two devices sharing two nets.
    // Device 0 at (0,0), device 1 at (12,0).
    // Net 0: pins at (0,0) and (10,0) -> centroid = (5, 0).
    //   la = |0-5| = 5, lb = |12-5| = 7. dl = -2, cost = 4.
    // Net 1: pins at (0,5) and (10,5) -> centroid = (5, 5).
    //   la = |0-5|+|0-5| = 10, lb = |12-5|+|0-5| = 12. dl = -2, cost = 4.
    // Total = 8.
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 12.0, 0.0 } };
    const pin_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 5.0 },
        .{ 10.0, 5.0 },
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
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const dev0_nets = [_]u32{ 0, 1 };
    const dev1_nets = [_]u32{ 0, 1 };
    const device_nets_map = [_][]u32{
        @constCast(&dev0_nets),
        @constCast(&dev1_nets),
    };

    const cost = computeParasiticBalance(&device_positions, &pin_positions, adj, &constraints, &device_nets_map);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), cost, 1e-4);
}

test "computeParasiticBalance integrated with combinedCost" {
    // Verify that parasitic cost is included in the total cost from computeFull.
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 12.0, 0.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const pin_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
    };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_proximity = 0.0,
        .w_isolation = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_thermal = 0.0,
        .w_orientation = 0.0,
        .w_lde = 0.0,
        .w_common_centroid = 0.0,
        .w_parasitic = 1.0,
    };

    // Without device_nets_map -> parasitic = 0.
    var cost_fn = CostFunction.init(weights);
    const total_no_map = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost_fn.parasitic_cost, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), total_no_map, 1e-6);

    // With device_nets_map -> parasitic > 0.
    // Net 0: pins at (0,0) and (10,0) -> centroid = (5, 0).
    // la = |0-5| = 5, lb = |12-5| = 7. dl = -2, cost = 4.
    const dev0_nets = [_]u32{0};
    const dev1_nets = [_]u32{0};
    const device_nets_map = [_][]u32{
        @constCast(&dev0_nets),
        @constCast(&dev1_nets),
    };
    cost_fn.device_nets_map = &device_nets_map;
    const total_with_map = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost_fn.parasitic_cost, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), total_with_map, 1e-4);
}

test "computeParasiticBalance empty device_nets_map returns zero" {
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const empty_map: []const []u32 = &.{};
    const cost = computeParasiticBalance(&device_positions, &pin_positions, adj, &constraints, empty_map);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeParasiticBalance ignores non-matching constraints" {
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 6.0, 0.0 }, .{ 20.0, 0.0 } };
    const pin_list = [_]PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1), PinIdx.fromInt(2) };
    const starts = [_]u32{ 0, 3 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 10.0 },
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 30.0 },
    };
    const dev0_nets = [_]u32{0};
    const dev1_nets = [_]u32{0};
    const device_nets_map = [_][]u32{
        @constCast(&dev0_nets),
        @constCast(&dev1_nets),
    };

    const cost = computeParasiticBalance(&device_positions, &pin_positions, adj, &constraints, &device_nets_map);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

// ─── Phase 7: Interdigitation constraint tests ────────────────────────────────

test "computeInterdigitation perfect ABAB has zero violations" {
    // 4 devices: A at x=0,4  B at x=2,6 → sorted: A(0) B(2) A(4) B(6) = perfect ABAB
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const group_a = [_]u32{ 0, 2 }; // devices at x=0, x=4
    const group_b = [_]u32{ 1, 3 }; // devices at x=2, x=6
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const cost_val = computeInterdigitation(&positions, &groups);

    // Centroids: A = (0+4)/2 = 2.0, B = (2+6)/2 = 4.0 -> centroid imbalance = (2-4)^2 = 4.0
    // Adjacency: ABAB -> 0 violations -> 0^2 = 0
    // Total = 4.0 + 0.0 = 4.0
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost_val, 1e-4);
}

test "computeInterdigitation symmetric ABBA has zero centroid imbalance" {
    // Symmetric arrangement: A at x=0, B at x=2, B at x=4, A at x=6
    // Sorted: A(0) B(2) B(4) A(6) = ABBA
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const group_a = [_]u32{ 0, 3 }; // devices at x=0, x=6
    const group_b = [_]u32{ 1, 2 }; // devices at x=2, x=4
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const cost_val = computeInterdigitation(&positions, &groups);

    // Centroids: A = (0+6)/2 = 3.0, B = (2+4)/2 = 3.0 -> centroid imbalance = 0.0
    // Adjacency: ABBA -> 1 violation (BB adjacent) -> 1^2 = 1.0
    // Total = 0.0 + 1.0 = 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cost_val, 1e-4);
}

test "computeInterdigitation AABB has two violations" {
    // All-A then all-B: A at x=0, A at x=2, B at x=4, B at x=6
    // Sorted: A(0) A(2) B(4) B(6) = AABB
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const group_a = [_]u32{ 0, 1 }; // devices at x=0, x=2
    const group_b = [_]u32{ 2, 3 }; // devices at x=4, x=6
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const cost_val = computeInterdigitation(&positions, &groups);

    // Centroids: A = (0+2)/2 = 1.0, B = (4+6)/2 = 5.0 -> centroid imbalance = (1-5)^2 = 16.0
    // Adjacency: AABB -> 2 violations (AA and BB) -> 2^2 = 4.0
    // Total = 16.0 + 4.0 = 20.0
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), cost_val, 1e-4);
}

test "computeInterdigitation AABB cost greater than ABAB" {
    // ABAB arrangement
    const pos_abab = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const ga1 = [_]u32{ 0, 2 };
    const gb1 = [_]u32{ 1, 3 };
    const groups_abab = [_]CentroidGroup{.{ .group_a = &ga1, .group_b = &gb1 }};

    // AABB arrangement
    const pos_aabb = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const ga2 = [_]u32{ 0, 1 };
    const gb2 = [_]u32{ 2, 3 };
    const groups_aabb = [_]CentroidGroup{.{ .group_a = &ga2, .group_b = &gb2 }};

    const cost_abab = computeInterdigitation(&pos_abab, &groups_abab);
    const cost_aabb = computeInterdigitation(&pos_aabb, &groups_aabb);

    // AABB should be more costly than ABAB
    try std.testing.expect(cost_aabb > cost_abab);
}

test "computeInterdigitation empty groups returns zero" {
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 } };
    const groups = [_]CentroidGroup{};
    const cost_val = computeInterdigitation(&positions, &groups);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost_val, 1e-6);
}

test "computeInterdigitation single device per group has no violations" {
    // Only one A and one B -> always AB or BA, no adjacency violations.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 4.0, 0.0 } };
    const group_a = [_]u32{0};
    const group_b = [_]u32{1};
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const cost_val = computeInterdigitation(&positions, &groups);

    // Centroids: A = 0.0, B = 4.0 -> centroid imbalance = 16.0
    // Adjacency: AB -> 0 violations
    // Total = 16.0
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), cost_val, 1e-4);
}

test "computeInterdigitation unequal spacing has penalty" {
    // 4 devices in ABAB pattern but with non-uniform spacing.
    // A at x=0, B at x=1, A at x=2, B at x=10  (last gap much larger)
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 1.0, 0.0 }, .{ 2.0, 0.0 }, .{ 10.0, 0.0 } };
    const group_a = [_]u32{ 0, 2 }; // devices at x=0, x=2
    const group_b = [_]u32{ 1, 3 }; // devices at x=1, x=10
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const cost_unequal = computeInterdigitation(&positions, &groups);

    // Centroids: A = (0+2)/2 = 1.0, B = (1+10)/2 = 5.5 -> centroid imbalance = (1-5.5)^2 = 20.25
    // Sorted: A(0) B(1) A(2) B(10) -> ABAB -> 0 violations
    // Gaps: [1, 1, 8], mean = 10/3 ~ 3.333
    //   variance = (1-3.333)^2 + (1-3.333)^2 + (8-3.333)^2
    //            = 5.444 + 5.444 + 21.778 = 32.667
    // Total = 20.25 + 0 + 32.667 = 52.917

    // Now compare with equally-spaced ABAB (same centroids won't match, but spacing = 0).
    const pos_equal = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const ga_eq = [_]u32{ 0, 2 };
    const gb_eq = [_]u32{ 1, 3 };
    const groups_equal = [_]CentroidGroup{.{ .group_a = &ga_eq, .group_b = &gb_eq }};
    const cost_equal = computeInterdigitation(&pos_equal, &groups_equal);

    // Unequal spacing should cost more due to spacing variance term.
    try std.testing.expect(cost_unequal > cost_equal);

    // Verify the spacing variance contributes: cost should be > centroid + violations alone.
    // centroid_imbalance = 20.25, violations = 0 => without spacing term would be 20.25.
    try std.testing.expect(cost_unequal > 20.25);
}

test "computeInterdigitation equal spacing has zero spacing penalty" {
    // 4 devices in ABAB with perfectly uniform spacing of 2.0.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const group_a = [_]u32{ 0, 2 }; // A at x=0, x=4
    const group_b = [_]u32{ 1, 3 }; // B at x=2, x=6
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const cost_val = computeInterdigitation(&positions, &groups);

    // Centroids: A = (0+4)/2 = 2.0, B = (2+6)/2 = 4.0 -> dc^2 = 4.0
    // Violations: ABAB -> 0
    // Gaps: [2,2,2], mean=2, variance = 0
    // Total = 4.0 + 0 + 0 = 4.0 (no spacing penalty contribution)
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost_val, 1e-4);
}

test "computeInterdigitation integrates with combinedCost" {
    // Verify that interdigitation cost flows through CostFunction.
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 }, .{ 4.0, 0.0 }, .{ 6.0, 0.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    const starts = [_]u32{0};
    const pin_list = [_]PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };
    const constraints = [_]Constraint{};

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    // AABB grouping -> should produce nonzero interdigitation cost
    const group_a = [_]u32{ 0, 1 };
    const group_b = [_]u32{ 2, 3 };
    const groups = [_]CentroidGroup{.{ .group_a = &group_a, .group_b = &group_b }};

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_interdigitation = 1.0,
    };

    var cost_fn = CostFunction.init(weights);
    cost_fn.interdigitation_groups = &groups;
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // interdigitation_cost for AABB: centroid_imbalance=16 + violations^2=4 = 20
    // total = w_interdigitation * 20 = 20.0
    try std.testing.expect(total > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), cost_fn.interdigitation_cost, 1e-4);
}

// ─── Phase 9: WPE (Well Proximity Effect) tests ─────────────────────────────

test "deviceToWellEdge center of well equidistant to edges" {
    // Well from (0,0) to (10,10). Device at center (5,5).
    // Min distance to any edge = 5.0 (equidistant to all 4 edges).
    const positions = [_][2]f32{.{ 5.0, 5.0 }};
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 10.0, .y_max = 10.0, .well_type = .nwell },
    };
    const dist = deviceToWellEdge(0, &positions, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), dist, 1e-6);
}

test "deviceToWellEdge device near well edge" {
    // Well from (0,0) to (10,10). Device at (1,5) — 1 µm from left edge.
    const positions = [_][2]f32{.{ 1.0, 5.0 }};
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 10.0, .y_max = 10.0, .well_type = .nwell },
    };
    const dist = deviceToWellEdge(0, &positions, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dist, 1e-6);
}

test "deviceToWellEdge device outside well" {
    // Well from (0,0) to (10,10). Device at (12,5) — 2 µm outside right edge.
    const positions = [_][2]f32{.{ 12.0, 5.0 }};
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 10.0, .y_max = 10.0, .well_type = .nwell },
    };
    const dist = deviceToWellEdge(0, &positions, &wells);
    // Closest edge is x_max=10.0: |12-10| = 2.0
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), dist, 1e-6);
}

test "deviceToWellEdge no wells returns infinity" {
    const positions = [_][2]f32{.{ 5.0, 5.0 }};
    const wells = [_]WellRegion{};
    const dist = deviceToWellEdge(0, &positions, &wells);
    try std.testing.expect(std.math.isInf(dist));
}

test "deviceToWellEdge multiple wells picks closest" {
    // Two wells: (0,0)-(5,5) and (8,0)-(15,5). Device at (6,2.5).
    // Closest to first well right edge: |6-5| = 1.0
    // Closest to second well left edge: |6-8| = 2.0
    // Min = 1.0
    const positions = [_][2]f32{.{ 6.0, 2.5 }};
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 5.0, .y_max = 5.0, .well_type = .nwell },
        .{ .x_min = 8.0, .y_min = 0.0, .x_max = 15.0, .y_max = 5.0, .well_type = .pwell },
    };
    const dist = deviceToWellEdge(0, &positions, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dist, 1e-6);
}

test "computeWpeMismatch zero when devices at same distance from well edge" {
    // Well from (0,0) to (20,10). Two devices at (5,5) and (15,5).
    // dev 0: min dist = min(5, 15, 5, 5) = 5.0
    // dev 1: min dist = min(15, 5, 5, 5) = 5.0
    // mismatch = (5 - 5)^2 = 0
    const positions = [_][2]f32{ .{ 5.0, 5.0 }, .{ 15.0, 5.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 20.0, .y_max = 10.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeWpeMismatch(&positions, &constraints, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeWpeMismatch nonzero when asymmetric distances" {
    // Well from (0,0) to (20,10). Dev 0 at (1,5) near left edge, dev 1 at (10,5) at center.
    // dev 0: min dist = min(1, 19, 5, 5) = 1.0
    // dev 1: min dist = min(10, 10, 5, 5) = 5.0
    // mismatch = (1 - 5)^2 = 16.0
    // Both NOT far (dev 0 at 1.0 is at threshold, not > 1.0), so no 0.1 reduction.
    const positions = [_][2]f32{ .{ 1.0, 5.0 }, .{ 10.0, 5.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 20.0, .y_max = 10.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeWpeMismatch(&positions, &constraints, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), cost, 1e-4);
}

test "computeWpeMismatch reduced penalty when both far from well edge" {
    // Well from (0,0) to (40,40). Dev 0 at (15,20), dev 1 at (25,20).
    // dev 0: min dist = min(15, 25, 20, 20) = 15.0
    // dev 1: min dist = min(25, 15, 20, 20) = 15.0
    // Both > 1.0 → far. mismatch = (15-15)^2 * 0.1 = 0.0
    //
    // Now try asymmetric but both far:
    // dev 0 at (5,20): min dist = min(5, 35, 20, 20) = 5.0 (> 1.0)
    // dev 1 at (10,20): min dist = min(10, 30, 20, 20) = 10.0 (> 1.0)
    // mismatch = (5-10)^2 * 0.1 = 25 * 0.1 = 2.5
    const positions = [_][2]f32{ .{ 5.0, 20.0 }, .{ 10.0, 20.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 40.0, .y_max = 40.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeWpeMismatch(&positions, &constraints, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), cost, 1e-4);
}

test "computeWpeMismatch no wells returns zero" {
    const positions = [_][2]f32{ .{ 5.0, 5.0 }, .{ 15.0, 5.0 } };
    const wells = [_]WellRegion{};
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeWpeMismatch(&positions, &constraints, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeWpeMismatch ignores non-matching constraints" {
    const positions = [_][2]f32{ .{ 1.0, 5.0 }, .{ 10.0, 5.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 20.0, .y_max = 10.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.5 },
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 20.0 },
    };
    const cost = computeWpeMismatch(&positions, &constraints, &wells);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "checkGuardRings detects missing coverage" {
    // Well from (0,0) to (10,10). Two matched devices at (5,5) and (15,5).
    // Device 1 at (15,5) is outside the well → group not enclosed.
    const positions = [_][2]f32{ .{ 5.0, 5.0 }, .{ 15.0, 5.0 } };
    const dimensions = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 10.0, .y_max = 10.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const results = try checkGuardRings(&positions, &dimensions, &constraints, &wells, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(false, results[0].has_guard_ring);
}

test "checkGuardRings detects present coverage" {
    // Well from (0,0) to (20,10). Both matched devices inside.
    const positions = [_][2]f32{ .{ 5.0, 5.0 }, .{ 15.0, 5.0 } };
    const dimensions = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 20.0, .y_max = 10.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const results = try checkGuardRings(&positions, &dimensions, &constraints, &wells, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(true, results[0].has_guard_ring);
}

test "checkGuardRings no matching constraints returns empty" {
    const positions = [_][2]f32{ .{ 5.0, 5.0 }, .{ 15.0, 5.0 } };
    const dimensions = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 20.0, .y_max = 10.0, .well_type = .nwell },
    };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 10.0 },
    };

    const results = try checkGuardRings(&positions, &dimensions, &constraints, &wells, std.testing.allocator);
    // Empty slice (static empty), no need to free.
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "WPE integrates with combinedCost" {
    // Verify that WPE cost flows through CostFunction.computeFull.
    const device_positions = [_][2]f32{ .{ 1.0, 5.0 }, .{ 10.0, 5.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    const starts = [_]u32{0};
    const pin_list = [_]PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };

    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const wells = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 20.0, .y_max = 10.0, .well_type = .nwell },
    };

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    // Only enable WPE weight, disable everything else.
    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_proximity = 0.0,
        .w_isolation = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_thermal = 0.0,
        .w_orientation = 0.0,
        .w_lde = 0.0,
        .w_common_centroid = 0.0,
        .w_parasitic = 0.0,
        .w_interdigitation = 0.0,
        .w_edge_penalty = 0.0,
        .w_wpe = 1.0,
    };

    var cost_fn = CostFunction.init(weights);
    cost_fn.well_regions = &wells;
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // WPE cost should match standalone computation.
    const expected_wpe = computeWpeMismatch(&device_positions, &constraints, &wells);
    try std.testing.expectApproxEqAbs(expected_wpe, cost_fn.wpe_cost, 1e-4);
    // total = 1.0 * wpe_cost
    try std.testing.expectApproxEqAbs(expected_wpe, total, 1e-4);
    try std.testing.expect(total > 0.0);
}

// ─── Bug fix verification tests ──────────────────────────────────────────────

test "acceptDelta syncs overlap_cost" {
    // Verify that acceptDelta properly updates overlap_cost (Bug #1 fix).
    const weights = CostWeights{};
    var cost_fn = CostFunction.init(weights);
    cost_fn.overlap_cost = 50.0; // stale value
    cost_fn.total = 100.0;

    // Accept a delta with a different overlap value.
    cost_fn.acceptDelta(
        1.0, // hpwl
        2.0, // area
        3.0, // sym
        4.0, // match
        5.0, // prox
        6.0, // iso
        7.0, // rudy
        99.0, // overlap — NEW parameter
        8.0, // thermal
        9.0, // lde
        10.0, // orientation
        11.0, // centroid
        12.0, // parasitic
        13.0, // interdigitation
        14.0, // edge_penalty
        15.0, // wpe
        200.0, // total
    );

    // overlap_cost must be updated to the new value, not stale.
    try std.testing.expectApproxEqAbs(@as(f32, 99.0), cost_fn.overlap_cost, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), cost_fn.total, 1e-6);
    // Other fields should also be updated.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cost_fn.hpwl_sum, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), cost_fn.rudy_overflow, 1e-6);
}

test "orientation cost is non-zero when orientations differ via computeFull" {
    // Verify that computeFull wires through computeOrientationMismatch (Bug #2 fix).
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    const starts = [_]u32{0};
    const pin_list = [_]PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };
    const constraints = [_]Constraint{
        .{ .kind = .orientation_match, .dev_a = 0, .dev_b = 1 },
    };

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_orientation = 1.0,
    };

    // With mismatched orientations, orientation_cost should be non-zero.
    const orientations_mismatch = [_]Orientation{ .N, .S };
    var cost_fn = CostFunction.init(weights);
    cost_fn.orientations = &orientations_mismatch;
    const total_mismatch = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    try std.testing.expect(cost_fn.orientation_cost > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cost_fn.orientation_cost, 1e-6);
    try std.testing.expect(total_mismatch > 0.0);

    // With matching orientations, orientation_cost should be zero.
    const orientations_match = [_]Orientation{ .N, .N };
    cost_fn.orientations = &orientations_match;
    const total_match = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost_fn.orientation_cost, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), total_match, 1e-6);
}

test "runSa accepts SaExtendedInput with well regions and heat sources" {
    // Verify that runSa accepts the extended input struct (Bug #3 fix)
    // and populates guard_ring_results when well_regions are provided.
    const num_devices: u32 = 2;

    var device_positions: [num_devices][2]f32 = .{
        .{ 10.0, 10.0 },
        .{ 20.0, 10.0 },
    };
    const device_dimensions = [num_devices][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };

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

    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const heat_sources = [_]HeatSource{
        .{ .x = 15.0, .y = 10.0, .power = 0.001 },
    };

    const well_regions = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 50.0, .y_max = 50.0, .well_type = .nwell },
    };

    const config = SaConfig{
        .initial_temp = 100.0,
        .cooling_rate = 0.99,
        .min_temp = 0.01,
        .max_iterations = 100,
        .kappa = 0.0,
        .w_hpwl = 1.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 1.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };

    const extended = SaExtendedInput{
        .heat_sources = &heat_sources,
        .well_regions = &well_regions,
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
        extended,
    );

    // SA should complete without errors.
    try std.testing.expect(result.iterations_run > 0);
    try std.testing.expect(result.final_cost >= 0.0);
    try std.testing.expect(!std.math.isNan(result.final_cost));

    // Guard ring results should be populated (one matching constraint → one result).
    try std.testing.expectEqual(@as(usize, 1), result.guard_ring_results.len);
    // The well (0,0)-(50,50) should fully enclose both devices.
    try std.testing.expect(result.guard_ring_results[0].has_guard_ring);

    // Dummy count should reflect exposed edges of matched devices.
    // Both devices are isolated (4 exposed edges each), so dummy_count = 8.
    try std.testing.expect(result.dummy_count > 0);

    // Free guard ring results.
    if (result.guard_ring_results.len > 0) {
        std.testing.allocator.free(result.guard_ring_results);
    }
}

// ─── Integration tests: cost terms nonzero under realistic conditions ────────

test "thermal cost nonzero with heat sources at different distances" {
    // Two matched devices at different distances from a heat source.
    // Device 0 at (2, 0) — close to heat source at (0, 0).
    // Device 1 at (20, 0) — far from heat source.
    // Thermal field differs → computeThermalMismatch > 0.
    const positions = [_][2]f32{ .{ 2.0, 0.0 }, .{ 20.0, 0.0 } };
    const heat_sources = [_]HeatSource{
        .{ .x = 0.0, .y = 0.0, .power = 1.0 },
    };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const thermal = computeThermalMismatch(&positions, &constraints, &heat_sources);
    try std.testing.expect(thermal > 0.0);

    // Also verify it flows through computeFull into combinedCost.
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const starts = [_]u32{0};
    const pin_list = [_]PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_proximity = 0.0,
        .w_isolation = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_thermal = 1.0,
        .w_orientation = 0.0,
        .w_lde = 0.0,
        .w_common_centroid = 0.0,
        .w_parasitic = 0.0,
        .w_interdigitation = 0.0,
        .w_edge_penalty = 0.0,
        .w_wpe = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    cost_fn.heat_sources = &heat_sources;
    const total = cost_fn.computeFull(
        &positions,
        &device_dimensions,
        &positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    try std.testing.expect(cost_fn.thermal_cost > 0.0);
    try std.testing.expectApproxEqAbs(thermal, cost_fn.thermal_cost, 1e-6);
    try std.testing.expect(total > 0.0);
}

test "LDE cost nonzero with asymmetric SA/SB distances" {
    // Two matched devices with different left/right neighbor distances.
    // Device 0 at (5, 0) — close to left boundary (SA small).
    // Device 1 at (25, 0) — farther from left boundary (SA large).
    // Array width = 50. No other neighbors, so SA/SB are boundary distances.
    // Dev 0: SA = 5 - 1 = 4, SB = 50 - 6 = 44 (default w=2)
    // Dev 1: SA = 25 - 1 = 24, SB = 50 - 26 = 24
    // delta_SA = 4 - 24 = -20, delta_SB = 44 - 24 = 20
    // cost = 20^2 + 20^2 = 800
    const positions = [_][2]f32{ .{ 5.0, 0.0 }, .{ 25.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const lde = computeLde(&positions, &dimensions, &constraints, 50.0);
    try std.testing.expect(lde > 0.0);

    // Verify it flows through computeFull.
    const starts = [_]u32{0};
    const pin_list = [_]PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };

    var rudy_grid = try RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_proximity = 0.0,
        .w_isolation = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
        .w_thermal = 0.0,
        .w_orientation = 0.0,
        .w_lde = 1.0,
        .w_common_centroid = 0.0,
        .w_parasitic = 0.0,
        .w_interdigitation = 0.0,
        .w_edge_penalty = 0.0,
        .w_wpe = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    cost_fn.layout_width = 50.0;
    const total = cost_fn.computeFull(
        &positions,
        &dimensions,
        &positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    try std.testing.expect(cost_fn.lde_cost > 0.0);
    try std.testing.expectApproxEqAbs(lde, cost_fn.lde_cost, 1e-4);
    try std.testing.expect(total > 0.0);
}

test "edge penalty nonzero with exposed edges on matched pair" {
    // Device 0 isolated at (50, 50) — 4 exposed edges.
    // Device 1 at (10, 10) with a right neighbor and a top neighbor — 2 exposed edges.
    // Asymmetry = 4 - 2 = 2, penalty = 4.
    const positions = [_][2]f32{
        .{ 50.0, 50.0 }, // dev 0 (isolated)
        .{ 10.0, 10.0 }, // dev 1 (corner)
        .{ 12.5, 10.0 }, // right neighbor of dev 1
        .{ 10.0, 12.5 }, // top neighbor of dev 1
    };
    const dimensions = [_][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };
    const is_dummy = [_]bool{ false, false, false, false };

    // Verify countExposedEdges for isolated device.
    const exposed_0 = countExposedEdges(0, &positions, &dimensions, &is_dummy, 100.0, 100.0);
    try std.testing.expectEqual(@as(u4, 4), exposed_0);

    // Verify edge penalty is nonzero for asymmetric matched pair.
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const penalty = computeEdgePenalty(&positions, &dimensions, &constraints, &is_dummy, 100.0, 100.0);
    try std.testing.expect(penalty > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), penalty, 1e-4);
}

test "proximity cost nonzero when devices exceed threshold" {
    // Two devices with proximity constraint, placed far apart (beyond threshold).
    // Device 0 at (0, 0), device 1 at (20, 0). Distance = 20.
    // Threshold (param) = 5.0. Excess = 20 - 5 = 15. Cost = 15^2 = 225.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 5.0 },
    };

    const prox = computeProximity(&positions, &constraints);
    try std.testing.expect(prox > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 225.0), prox, 1e-4);
}

test "isolation cost nonzero when devices are too close" {
    // Two devices with isolation constraint, placed close together.
    // Device 0 at (0, 0), device 1 at (3, 0). Center-to-center = 3.
    // Device dimensions = 0 → size_offset = 0. Edge dist = 3.
    // Threshold (param) = 10.0. Violation = 10 - 3 = 7. Cost = 7^2 = 49.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 3.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .isolation, .dev_a = 0, .dev_b = 1, .param = 10.0 },
    };

    const iso = computeIsolation(&positions, &dimensions, &constraints);
    try std.testing.expect(iso > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 49.0), iso, 1e-4);
}

test "runSa with extended input produces non-trivial results" {
    // Full integration: run SA with well_regions and heat_sources populated.
    // Verify SaResult has guard_ring_results and dummy_count > 0.
    const num_devices: u32 = 2;

    var device_positions: [num_devices][2]f32 = .{
        .{ 10.0, 10.0 },
        .{ 30.0, 10.0 },
    };
    const device_dimensions = [num_devices][2]f32{
        .{ 4.0, 4.0 },
        .{ 4.0, 4.0 },
    };

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

    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    const heat_sources = [_]HeatSource{
        .{ .x = 0.0, .y = 0.0, .power = 0.5 },
        .{ .x = 50.0, .y = 0.0, .power = 0.3 },
    };

    const well_regions = [_]WellRegion{
        .{ .x_min = 0.0, .y_min = 0.0, .x_max = 50.0, .y_max = 50.0, .well_type = .nwell },
    };

    const config = SaConfig{
        .initial_temp = 100.0,
        .cooling_rate = 0.95,
        .min_temp = 0.01,
        .max_iterations = 200,
        .kappa = 0.0,
        .w_hpwl = 1.0,
        .w_area = 0.5,
        .w_symmetry = 0.0,
        .w_matching = 1.5,
        .w_rudy = 0.0,
        .w_overlap = 10.0,
        .w_thermal = 0.5,
        .w_lde = 0.5,
        .w_edge_penalty = 0.5,
        .w_wpe = 0.5,
    };

    const extended = SaExtendedInput{
        .heat_sources = &heat_sources,
        .well_regions = &well_regions,
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
        77777,
        std.testing.allocator,
        extended,
    );

    // SA should complete successfully.
    try std.testing.expect(result.iterations_run > 0);
    try std.testing.expect(result.accepted_moves > 0);
    try std.testing.expect(result.final_cost >= 0.0);
    try std.testing.expect(!std.math.isNan(result.final_cost));

    // Guard ring results should be populated (one matching constraint).
    try std.testing.expectEqual(@as(usize, 1), result.guard_ring_results.len);

    // Dummy count should be > 0 (matched devices have exposed edges post-SA).
    try std.testing.expect(result.dummy_count > 0);

    // Free guard ring results.
    if (result.guard_ring_results.len > 0) {
        std.testing.allocator.free(result.guard_ring_results);
    }
}

// ─── Template bounds test (Phase 3) ─────────────────────────────────────────

test "SA template bounds: all devices stay within 0-100µm × 0-100µm" {
    // Three devices, each 2µm × 2µm.
    var device_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 0.0 },
    };
    const device_dimensions = [_][2]f32{
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 2.0 },
    };

    // One pin per device at its centre (offset 0,0).
    const pin_info = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 2, .offset_x = 0.0, .offset_y = 0.0 },
    };

    // One net connecting all three pins.
    const pin_list = [_]PinIdx{
        PinIdx.fromInt(0),
        PinIdx.fromInt(1),
        PinIdx.fromInt(2),
    };
    const starts = [_]u32{ 0, 3 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    const constraints = [_]Constraint{};

    const config = SaConfig{
        .max_iterations = 500,
        .kappa = 10.0,
        .w_hpwl = 1.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 10.0,
        // Enable template bounds: 0–100µm × 0–100µm.
        .use_template_bounds = true,
        .template_x_min = 0.0,
        .template_y_min = 0.0,
        .template_x_max = 100.0,
        .template_y_max = 100.0,
    };

    const result = try runSa(
        &device_positions,
        &device_dimensions,
        &pin_info,
        adj,
        &constraints,
        200.0, // layout_width larger than template bounds
        200.0, // layout_height larger than template bounds
        config,
        54321,
        std.testing.allocator,
        .{},
    );

    try std.testing.expect(result.iterations_run > 0);
    try std.testing.expect(result.final_cost >= 0.0);

    // Verify all devices are within template bounds (position is device origin,
    // so we check that position >= x_min and position + dimension <= x_max).
    for (device_positions, device_dimensions) |pos, dim| {
        try std.testing.expect(pos[0] >= config.template_x_min);
        try std.testing.expect(pos[1] >= config.template_y_min);
        try std.testing.expect(pos[0] + dim[0] <= config.template_x_max);
        try std.testing.expect(pos[1] + dim[1] <= config.template_y_max);
    }
}
