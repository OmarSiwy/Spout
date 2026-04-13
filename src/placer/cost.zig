const std = @import("std");
const types = @import("../core/types.zig");
const rudy_mod = @import("rudy.zig");

const DeviceIdx = types.DeviceIdx;
const NetIdx = types.NetIdx;
const PinIdx = types.PinIdx;
const ConstraintType = types.ConstraintType;

const RudyGrid = rudy_mod.RudyGrid;
const NetAdjacency = rudy_mod.NetAdjacency;

// ─── Constraint representation ──────────────────────────────────────────────

/// A constraint pairs two devices and carries the constraint type.
/// For symmetry constraints, `axis_x` is the x-coordinate of the symmetry axis.
pub const Constraint = struct {
    kind: ConstraintType,
    dev_a: u32,
    dev_b: u32,
    axis_x: f32, // only meaningful for symmetry constraints
};

// ─── Symmetry norm ──────────────────────────────────────────────────────────

/// Controls whether the symmetry cost term uses an L1 (absolute value) or L2
/// (squared) norm.  L1 has a linear rise that lets SA explore across constraint
/// violations more freely; L2 creates steeper barriers near perfect symmetry.
pub const SymmetryNorm = enum { L1, L2 };

// ─── Cost weights (mirrors SaConfig weights) ────────────────────────────────

pub const CostWeights = struct {
    w_hpwl: f32 = 1.0,
    w_area: f32 = 0.5,
    w_symmetry: f32 = 2.0,
    w_matching: f32 = 1.5,
    w_rudy: f32 = 0.3,
    w_overlap: f32 = 100.0,
    /// Norm applied to the symmetry cost term.
    symmetry_norm: SymmetryNorm = .L2,
};

// ─── Pin-to-device mapping ──────────────────────────────────────────────────

/// Per-pin offset from device centre.  The absolute pin position is
///   device_position + pin_offset.
pub const PinInfo = struct {
    device: u32,
    offset_x: f32,
    offset_y: f32,
};

// ─── Delta result ────────────────────────────────────────────────────────────

/// Full sub-cost breakdown returned by `computeDeltaCost`.
/// All fields reflect the *new* values that would apply if the move is accepted.
pub const DeltaResult = struct {
    new_total: f32,
    delta: f32,
    new_hpwl_sum: f32,
    new_area: f32,
    new_sym: f32,
    new_match: f32,
    new_rudy: f32,
    new_overlap: f32,
};

// ─── Cost function ──────────────────────────────────────────────────────────

/// Full 6-term cost function for the SA placer.
///
/// ```
/// cost = w_hpwl     * Σ hpwl(n) / num_nets
///      + w_area     * bounding_area
///      + w_symmetry * Σ_sym  (L1: |x_a+x_b-2*axis| + |y_a-y_b|  or
///                             L2: |x_a+x_b-2*axis|² + |y_a-y_b|²)
///      + w_matching * Σ_match (dist - min_sep)²
///      + w_rudy     * RUDY_overflow
///      + w_overlap  * Σ_pairs overlap_area(i, j)
/// ```
pub const CostFunction = struct {
    weights: CostWeights,

    // Cached sub-costs for incremental update.
    hpwl_sum: f32 = 0.0,
    area_cost: f32 = 0.0,
    symmetry_cost: f32 = 0.0,
    matching_cost: f32 = 0.0,
    rudy_overflow: f32 = 0.0,
    overlap_cost: f32 = 0.0,
    total: f32 = 0.0,

    /// Stored power-net mask; set during `computeFull`, reused in
    /// `computeDeltaCost`.  An empty slice means "no nets are power nets".
    is_power: []const bool = &.{},

    pub fn init(weights: CostWeights) CostFunction {
        return CostFunction{ .weights = weights };
    }

    // ── Full computation ────────────────────────────────────────────────

    /// Compute all six terms from scratch.
    pub fn computeFull(
        self: *CostFunction,
        device_positions: []const [2]f32,
        device_dimensions: []const [2]f32,
        pin_positions: []const [2]f32,
        adj: NetAdjacency,
        constraints: []const Constraint,
        rudy_grid: *const RudyGrid,
        is_power: []const bool,
    ) f32 {
        // Store the power-net mask for reuse in computeDeltaCost.
        self.is_power = is_power;

        // 1. HPWL (power nets excluded).
        self.hpwl_sum = computeHpwlAll(pin_positions, adj, is_power);

        // 2. Bounding-box area of all devices.
        self.area_cost = computeArea(device_positions);

        // 3. Symmetry constraints.
        self.symmetry_cost = computeSymmetry(device_positions, constraints, self.weights.symmetry_norm);

        // 4. Matching constraints (with minimum-separation well).
        self.matching_cost = computeMatching(device_positions, device_dimensions, constraints);

        // 5. RUDY overflow.
        self.rudy_overflow = rudy_grid.totalOverflow();

        // 6. Device overlap penalty.
        self.overlap_cost = computeOverlap(device_positions, device_dimensions);

        self.total = self.combinedCost(adj.num_nets);
        return self.total;
    }

    // ── Incremental delta cost ──────────────────────────────────────────

    /// Compute the change in total cost when a single device `dev` moves.
    ///
    /// **Caller contract**: `new_pin_positions` already reflects the move;
    /// `old_pin_positions` has the pre-move values for all pins.
    ///
    /// Returns a `DeltaResult` with new total, delta, and all sub-costs.
    /// The caller should accept the move when `delta < 0` or with Boltzmann
    /// probability otherwise, then call `acceptDelta` to commit.
    pub fn computeDeltaCost(
        self: *CostFunction,
        dev: u32,
        old_device_pos: [2]f32,
        new_device_pos: [2]f32,
        old_pin_positions: []const [2]f32,
        new_pin_positions: []const [2]f32,
        all_device_positions: []const [2]f32,
        device_dimensions: []const [2]f32,
        adj: NetAdjacency,
        device_nets: []const u32, // nets containing this device
        constraints: []const Constraint,
        rudy_grid: *const RudyGrid,
    ) DeltaResult {
        _ = old_device_pos;
        _ = new_device_pos;
        _ = dev;

        // 1. Delta HPWL: recompute only affected nets (skip power nets).
        var new_hpwl_sum = self.hpwl_sum;
        for (device_nets) |net| {
            // Skip power nets — they are excluded from HPWL.
            if (self.is_power.len > net and self.is_power[net]) continue;
            const old_hpwl = computeNetHpwl(net, old_pin_positions, adj);
            const new_hpwl = computeNetHpwl(net, new_pin_positions, adj);
            new_hpwl_sum += (new_hpwl - old_hpwl);
        }

        // 2. Area: cheapest to recompute fully (linear in #devices).
        const new_area = computeArea(all_device_positions);

        // 3/4. Constraint costs: recompute fully (typically tiny lists).
        const new_sym = computeSymmetry(all_device_positions, constraints, self.weights.symmetry_norm);
        const new_match = computeMatching(all_device_positions, device_dimensions, constraints);

        // 5. RUDY overflow.
        const new_rudy = rudy_grid.totalOverflow();

        // 6. Device overlap penalty.
        const new_overlap = computeOverlap(all_device_positions, device_dimensions);

        const num_nets = adj.num_nets;
        const w = self.weights;
        const hpwl_norm: f32 = if (num_nets > 0) @floatFromInt(num_nets) else 1.0;

        const new_total = w.w_hpwl * new_hpwl_sum / hpwl_norm +
            w.w_area * new_area +
            w.w_symmetry * new_sym +
            w.w_matching * new_match +
            w.w_rudy * new_rudy +
            w.w_overlap * new_overlap;

        const delta = new_total - self.total;

        return DeltaResult{
            .new_total = new_total,
            .delta = delta,
            .new_hpwl_sum = new_hpwl_sum,
            .new_area = new_area,
            .new_sym = new_sym,
            .new_match = new_match,
            .new_rudy = new_rudy,
            .new_overlap = new_overlap,
        };
    }

    /// Commit the delta (after an accepted move).
    /// Updates all cached sub-costs so future `computeDeltaCost` calls are correct.
    pub fn acceptDelta(
        self: *CostFunction,
        new_hpwl_sum: f32,
        new_area: f32,
        new_sym: f32,
        new_match: f32,
        new_rudy: f32,
        new_total: f32,
    ) void {
        self.hpwl_sum = new_hpwl_sum;
        self.area_cost = new_area;
        self.symmetry_cost = new_sym;
        self.matching_cost = new_match;
        self.rudy_overflow = new_rudy;
        self.total = new_total;
    }

    /// Commit using only the new total (fast path used by SA loop).
    pub fn acceptTotal(self: *CostFunction, new_total: f32) void {
        self.total = new_total;
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    fn combinedCost(self: *const CostFunction, num_nets: u32) f32 {
        const w = self.weights;
        const hpwl_norm: f32 = if (num_nets > 0) @floatFromInt(num_nets) else 1.0;
        return w.w_hpwl * self.hpwl_sum / hpwl_norm +
            w.w_area * self.area_cost +
            w.w_symmetry * self.symmetry_cost +
            w.w_matching * self.matching_cost +
            w.w_rudy * self.rudy_overflow +
            w.w_overlap * self.overlap_cost;
    }
};

// ─── Pure cost-computation functions (stateless) ────────────────────────────

/// HPWL of a single net.
pub fn computeNetHpwl(
    net: u32,
    pin_positions: []const [2]f32,
    adj: NetAdjacency,
) f32 {
    const start = adj.net_pin_starts[net];
    const end = adj.net_pin_starts[net + 1];
    if (end <= start) return 0.0;

    var x_min: f32 = std.math.inf(f32);
    var x_max: f32 = -std.math.inf(f32);
    var y_min: f32 = std.math.inf(f32);
    var y_max: f32 = -std.math.inf(f32);

    for (start..end) |k| {
        const pid = adj.pin_list[k].toInt();
        const px = pin_positions[pid][0];
        const py = pin_positions[pid][1];
        x_min = @min(x_min, px);
        x_max = @max(x_max, px);
        y_min = @min(y_min, py);
        y_max = @max(y_max, py);
    }

    return (x_max - x_min) + (y_max - y_min);
}

/// Σ HPWL over all nets, skipping power nets.
///
/// `is_power` may be an empty slice (meaning no nets are power nets).
/// When `is_power.len > net` and `is_power[net]` is true, that net is skipped.
pub fn computeHpwlAll(
    pin_positions: []const [2]f32,
    adj: NetAdjacency,
    is_power: []const bool,
) f32 {
    var sum: f32 = 0.0;
    var net: u32 = 0;
    while (net < adj.num_nets) : (net += 1) {
        if (is_power.len > net and is_power[net]) continue;
        sum += computeNetHpwl(net, pin_positions, adj);
    }
    return sum;
}

/// Bounding-box area of all device positions.
pub fn computeArea(positions: []const [2]f32) f32 {
    if (positions.len == 0) return 0.0;

    var x_min: f32 = std.math.inf(f32);
    var x_max: f32 = -std.math.inf(f32);
    var y_min: f32 = std.math.inf(f32);
    var y_max: f32 = -std.math.inf(f32);

    for (positions) |pos| {
        x_min = @min(x_min, pos[0]);
        x_max = @max(x_max, pos[0]);
        y_min = @min(y_min, pos[1]);
        y_max = @max(y_max, pos[1]);
    }

    return (x_max - x_min) * (y_max - y_min);
}

/// Σ over symmetry constraints.
///
/// L1 norm: `|x_a + x_b - 2*axis| + |y_a - y_b|`
/// L2 norm: `(x_a + x_b - 2*axis)² + (y_a - y_b)²`
pub fn computeSymmetry(
    positions: []const [2]f32,
    constraints: []const Constraint,
    norm: SymmetryNorm,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .symmetry) continue;
        const xa = positions[c.dev_a][0];
        const ya = positions[c.dev_a][1];
        const xb = positions[c.dev_b][0];
        const yb = positions[c.dev_b][1];
        const dx = xa + xb - 2.0 * c.axis_x;
        const dy = ya - yb;
        sum += switch (norm) {
            .L1 => @abs(dx) + @abs(dy),
            .L2 => dx * dx + dy * dy,
        };
    }
    return sum;
}

/// Default minimum spacing between matched devices (used when device
/// dimensions are zero or unavailable).
const default_min_spacing: f32 = 2.0;

/// Σ over matching constraints of a parabolic well centred at the minimum
/// separation distance.  Cost is zero when `dist == min_sep`, rises
/// quadratically on both sides:
///   - `dist < min_sep` → repulsion: `(min_sep - dist)²`
///   - `dist > min_sep` → attraction: `(dist - min_sep)²`
///
/// This prevents the SA from collapsing matched devices to the same position
/// while still encouraging them to be placed near each other.
pub fn computeMatching(
    positions: []const [2]f32,
    device_dimensions: []const [2]f32,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;

        const dx = positions[c.dev_a][0] - positions[c.dev_b][0];
        const dy = positions[c.dev_a][1] - positions[c.dev_b][1];
        const dist_sq = dx * dx + dy * dy;
        const dist = @sqrt(dist_sq);

        // Compute minimum separation from device dimensions.
        // Use the larger of (half-width_a + half-width_b, half-height_a + half-height_b)
        // plus a minimum spacing gap.
        var min_sep: f32 = default_min_spacing;
        if (device_dimensions.len > c.dev_a and device_dimensions.len > c.dev_b) {
            const wa = device_dimensions[c.dev_a][0];
            const ha = device_dimensions[c.dev_a][1];
            const wb = device_dimensions[c.dev_b][0];
            const hb = device_dimensions[c.dev_b][1];
            const sep_x = (wa + wb) / 2.0;
            const sep_y = (ha + hb) / 2.0;
            const dim_sep = @max(sep_x, sep_y);
            // Only use dimension-based separation if dimensions are nonzero.
            if (dim_sep > 0.0) {
                min_sep = dim_sep + default_min_spacing;
            }
        }

        const delta = dist - min_sep;
        sum += delta * delta;
    }
    return sum;
}

/// Overlap penalty: for every pair of devices whose axis-aligned bounding boxes
/// overlap, add a cost proportional to the overlap area.  When device dimensions
/// are zero (unknown) we use a small default footprint so that co-located
/// devices are still penalised.
pub fn computeOverlap(
    positions: []const [2]f32,
    device_dimensions: []const [2]f32,
) f32 {
    const n = positions.len;
    if (n < 2) return 0.0;

    // Fallback half-size when dimensions are zero.
    const default_half: f32 = 1.0;

    var sum: f32 = 0.0;
    for (0..n) |i| {
        const hw_i = if (device_dimensions.len > i and device_dimensions[i][0] > 0.0)
            device_dimensions[i][0] / 2.0
        else
            default_half;
        const hh_i = if (device_dimensions.len > i and device_dimensions[i][1] > 0.0)
            device_dimensions[i][1] / 2.0
        else
            default_half;

        for (i + 1..n) |j| {
            const hw_j = if (device_dimensions.len > j and device_dimensions[j][0] > 0.0)
                device_dimensions[j][0] / 2.0
            else
                default_half;
            const hh_j = if (device_dimensions.len > j and device_dimensions[j][1] > 0.0)
                device_dimensions[j][1] / 2.0
            else
                default_half;

            // Compute overlap between axis-aligned bounding boxes centred on
            // device positions.
            const ox = @max(0.0, (hw_i + hw_j) - @abs(positions[i][0] - positions[j][0]));
            const oy = @max(0.0, (hh_i + hh_j) - @abs(positions[i][1] - positions[j][1]));
            sum += ox * oy;
        }
    }
    return sum;
}

// ─── Module-level tests ─────────────────────────────────────────────────────

test "computeNetHpwl simple" {
    // 2 pins at (0,0) and (3,4) → HPWL = 3 + 4 = 7.
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 3.0, 4.0 } };
    const pin_list = [_]types.PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };

    const hpwl = computeNetHpwl(0, &pin_positions, adj);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), hpwl, 1e-6);
}

test "computeArea rectangle" {
    const positions = [_][2]f32{ .{ 1.0, 2.0 }, .{ 5.0, 8.0 } };
    // area = (5-1) * (8-2) = 24
    const area = computeArea(&positions);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), area, 1e-6);
}

test "computeSymmetry perfect mirror" {
    // Two devices at (3, 5) and (7, 5), axis at 5.
    // |3 + 7 - 10| = 0, |5 - 5| = 0 → cost = 0.
    const positions = [_][2]f32{ .{ 3.0, 5.0 }, .{ 7.0, 5.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
    };
    const cost = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeMatching identical positions has repulsion cost" {
    const positions = [_][2]f32{ .{ 4.0, 4.0 }, .{ 4.0, 4.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1, .axis_x = 0.0 },
    };
    const cost = computeMatching(&positions, &dimensions, &constraints);
    // dist = 0, min_sep = default_min_spacing = 2.0, so cost = (0 - 2)² = 4.0
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost, 1e-6);
}

test "computeMatching at min separation has zero cost" {
    // Place devices exactly min_sep apart (default_min_spacing = 2.0 when dims are zero).
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 2.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1, .axis_x = 0.0 },
    };
    const cost = computeMatching(&positions, &dimensions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-4);
}

test "computeMatching with device dimensions" {
    // Devices with width=4.0, height=2.0 each.
    // min_sep = max((4+4)/2, (2+2)/2) + 2.0 = max(4.0, 2.0) + 2.0 = 6.0
    // Place them 6.0 apart → cost should be ~0.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 6.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 4.0, 2.0 }, .{ 4.0, 2.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1, .axis_x = 0.0 },
    };
    const cost = computeMatching(&positions, &dimensions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-4);
}

test "computeOverlap co-located devices" {
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const cost = computeOverlap(&positions, &dimensions);
    // Both devices are 2x2 centred at origin. Full overlap = 2.0 * 2.0 = 4.0
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost, 1e-6);
}

test "computeOverlap no overlap" {
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 10.0 } };
    const dimensions = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const cost = computeOverlap(&positions, &dimensions);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

// ─── Change #1: L1 vs L2 symmetry norm tests ────────────────────────────────

test "computeSymmetry L1 and L2 both zero for perfectly symmetric placement" {
    // Devices at (2,5) and (8,5), axis=5.
    // x_a + x_b - 2*axis = 2+8-10 = 0, y_a - y_b = 0 → both norms give 0.
    const positions = [_][2]f32{ .{ 2.0, 5.0 }, .{ 8.0, 5.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
    };
    const cost_l1 = computeSymmetry(&positions, &constraints, .L1);
    const cost_l2 = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost_l1, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost_l2, 1e-6);
}

test "computeSymmetry L1 less than L2 for asymmetric placement" {
    // Devices at (1,3) and (11,7), axis=5.
    // dx = 1+11-10 = 2, dy = 3-7 = -4.
    // L1: |2| + |-4| = 6
    // L2: 2*2 + (-4)*(-4) = 4 + 16 = 20
    const positions = [_][2]f32{ .{ 1.0, 3.0 }, .{ 11.0, 7.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
    };
    const cost_l1 = computeSymmetry(&positions, &constraints, .L1);
    const cost_l2 = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), cost_l1, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), cost_l2, 1e-5);
    try std.testing.expect(cost_l1 < cost_l2);
}

// ─── Change #2: Power net exclusion tests ───────────────────────────────────

test "computeHpwlAll with no power mask includes all nets" {
    // Net 0 (signal): pins at (0,0) and (10,0) → HPWL = 10
    // Net 1 (signal): pins at (0,0) and (0,20) → HPWL = 20
    const pin_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 20.0 },
    };
    const pin_list = [_]types.PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(2), PinIdx.fromInt(3),
    };
    const starts = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 2,
    };
    // Empty mask → both nets counted.
    const total = computeHpwlAll(&pin_positions, adj, &.{});
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), total, 1e-5);
}

test "computeHpwlAll excludes power net" {
    // Net 0 (signal): pins at (0,0) and (10,0) → HPWL = 10
    // Net 1 (power):  pins at (0,0) and (0,20) → HPWL = 20; should be excluded
    const pin_positions = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 0.0 },
        .{ 0.0, 20.0 },
    };
    const pin_list = [_]types.PinIdx{
        PinIdx.fromInt(0), PinIdx.fromInt(1),
        PinIdx.fromInt(2), PinIdx.fromInt(3),
    };
    const starts = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 2,
    };
    const is_power = [_]bool{ false, true };
    const total_with_exclusion = computeHpwlAll(&pin_positions, adj, &is_power);
    const total_without_exclusion = computeHpwlAll(&pin_positions, adj, &.{});
    // With exclusion: only net 0 counts → HPWL = 10
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), total_with_exclusion, 1e-5);
    // Without exclusion: both nets count → HPWL = 30
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), total_without_exclusion, 1e-5);
    try std.testing.expect(total_with_exclusion < total_without_exclusion);
}

// ─── Change #3: DeltaResult and acceptDelta tests ───────────────────────────

test "DeltaResult fields are consistent with computeFull" {
    // Two devices on one net.  Move device 1 and verify DeltaResult fields.
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 5.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const pin_positions_init = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 5.0 } };
    const pin_list = [_]types.PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{};

    var rudy_grid = try @import("rudy.zig").RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
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
    _ = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions_init,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // Move device 1 from (10,5) to (20,5).
    var new_device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 5.0 } };
    const new_pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 5.0 } };
    const device_nets = [_]u32{0};

    const result = cost_fn.computeDeltaCost(
        1,
        device_positions[1],
        new_device_positions[1],
        &pin_positions_init,
        &new_pin_positions,
        &new_device_positions,
        &device_dimensions,
        adj,
        &device_nets,
        &constraints,
        &rudy_grid,
    );

    // delta must equal new_total - old total.
    try std.testing.expectApproxEqAbs(result.new_total - cost_fn.total, result.delta, 1e-5);

    // With only w_hpwl=1.0 and num_nets=1: new_total == new_hpwl_sum / 1.
    // new HPWL for net 0: |(20-0)| + |(5-0)| = 25.
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), result.new_hpwl_sum, 1e-4);
    try std.testing.expectApproxEqAbs(result.new_hpwl_sum, result.new_total, 1e-5);
}

test "acceptDelta updates all cached sub-costs" {
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 5.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const pin_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 5.0 } };
    const pin_list = [_]types.PinIdx{ PinIdx.fromInt(0), PinIdx.fromInt(1) };
    const starts = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 1,
    };
    const constraints = [_]Constraint{};

    var rudy_grid = try @import("rudy.zig").RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    var cost_fn = CostFunction.init(CostWeights{});
    _ = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &pin_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // Simulate an accepted move by calling acceptDelta with known values.
    const sentinel_hpwl: f32 = 99.0;
    const sentinel_area: f32 = 88.0;
    const sentinel_sym: f32 = 77.0;
    const sentinel_match: f32 = 66.0;
    const sentinel_rudy: f32 = 55.0;
    const sentinel_total: f32 = 44.0;

    cost_fn.acceptDelta(
        sentinel_hpwl,
        sentinel_area,
        sentinel_sym,
        sentinel_match,
        sentinel_rudy,
        sentinel_total,
    );

    try std.testing.expectApproxEqAbs(sentinel_hpwl, cost_fn.hpwl_sum, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_area, cost_fn.area_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_sym, cost_fn.symmetry_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_match, cost_fn.matching_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_rudy, cost_fn.rudy_overflow, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_total, cost_fn.total, 1e-6);
}
