const std = @import("std");
const types = @import("../core/types.zig");
const rudy_mod = @import("rudy.zig");

const DeviceIdx = types.DeviceIdx;
const NetIdx = types.NetIdx;
const PinIdx = types.PinIdx;
const ConstraintType = types.ConstraintType;
const Orientation = types.Orientation;

const RudyGrid = rudy_mod.RudyGrid;
const NetAdjacency = rudy_mod.NetAdjacency;

// ─── Well region model (Phase 9: WPE) ────────────────────────────────────────

/// A well region in the layout (N-well, P-well, or deep N-well).
/// WPE (Well Proximity Effect) causes ΔVth of tens of mV near well edges,
/// decaying over ~1 µm.  Matched devices must see equal well-edge distances.
pub const WellRegion = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
    well_type: WellType,

    pub const WellType = enum(u8) { nwell, pwell, deep_nwell };
};

// ─── Heat source model ──────────────────────────────────────────────────────

/// A heat source for thermal symmetry computation.
/// Represents a power-dissipating device with known position and power.
pub const HeatSource = struct {
    x: f32,
    y: f32,
    power: f32, // watts (or relative units)
};

// ─── Constraint representation ──────────────────────────────────────────────

/// A constraint pairs two devices and carries the constraint type.
/// `axis_x` is the x-coordinate of the symmetry axis (for symmetry constraints).
/// `axis_y` is reserved for horizontal-axis symmetry (Phase 1).
/// `param` is a kind-dependent scalar:
///   symmetry  → unused (0.0)
///   matching  → unused (0.0)
///   proximity → maximum distance threshold
///   isolation → minimum distance threshold
pub const Constraint = struct {
    kind: ConstraintType,
    dev_a: u32,
    dev_b: u32,
    axis_x: f32 = 0.0,
    axis_y: f32 = 0.0,
    param: f32 = 0.0,
};

// ─── Common-centroid group ───────────────────────────────────────────────────

/// Common-centroid group definition. Stored in a sidecar array.
/// A constraint with kind == .common_centroid has param encoding the
/// index into the CentroidGroup sidecar.
pub const CentroidGroup = struct {
    /// Device indices belonging to group A.
    group_a: []const u32,
    /// Device indices belonging to group B.
    group_b: []const u32,
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
    w_proximity: f32 = 1.0,
    w_isolation: f32 = 1.0,
    w_rudy: f32 = 0.3,
    w_overlap: f32 = 100.0,
    /// Weight for the thermal mismatch cost term (Phase 5).
    w_thermal: f32 = 0.5,
    /// Weight for the orientation mismatch cost term (Phase 2).
    w_orientation: f32 = 2.0,
    /// Norm applied to the symmetry cost term.
    symmetry_norm: SymmetryNorm = .L2,
    /// Weight for LDE (SA/SB equalization) cost term.
    w_lde: f32 = 0.5,
    /// Weight for common-centroid cost term (Phase 3).
    w_common_centroid: f32 = 2.0,
    /// Weight for parasitic routing balance cost term (Phase 8).
    w_parasitic: f32 = 0.8,
    /// Weight for interdigitation cost term (Phase 7).
    w_interdigitation: f32 = 2.0,
    /// Weight for edge penalty cost term (Phase 6: Dummy Device Modeling).
    w_edge_penalty: f32 = 0.5,
    /// Weight for WPE (Well Proximity Effect) mismatch cost term (Phase 9).
    w_wpe: f32 = 0.5,
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
    new_prox: f32,
    new_iso: f32,
    new_rudy: f32,
    new_overlap: f32,
    new_thermal: f32,
    new_lde: f32,
    new_orientation: f32,
    new_centroid: f32,
    new_parasitic: f32,
    new_interdigitation: f32,
    new_edge_penalty: f32,
    new_wpe: f32,
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
    proximity_cost: f32 = 0.0,
    isolation_cost: f32 = 0.0,
    rudy_overflow: f32 = 0.0,
    overlap_cost: f32 = 0.0,
    thermal_cost: f32 = 0.0,
    lde_cost: f32 = 0.0,
    orientation_cost: f32 = 0.0,
    centroid_cost: f32 = 0.0,
    parasitic_cost: f32 = 0.0,
    interdigitation_cost: f32 = 0.0,
    edge_penalty_cost: f32 = 0.0,
    wpe_cost: f32 = 0.0,
    total: f32 = 0.0,

    /// Stored power-net mask; set during `computeFull`, reused in
    /// `computeDeltaCost`.  An empty slice means "no nets are power nets".
    is_power: []const bool = &.{},

    /// Heat sources for thermal mismatch computation; set via `computeFull`
    /// or directly.  Empty means no thermal penalty.
    heat_sources: []const HeatSource = &.{},

    /// Layout width (die boundary) for LDE SA/SB computation.
    layout_width: f32 = 0.0,

    /// Layout height (die boundary) for edge penalty computation.
    layout_height: f32 = 0.0,

    /// Dummy device flags; set externally before calling computeFull/computeDeltaCost.
    /// Empty means no devices are dummies.
    is_dummy: []const bool = &.{},

    /// Common-centroid group sidecar; set via `computeFull` or directly.
    centroid_groups: []const CentroidGroup = &.{},

    /// Device-to-net mapping for parasitic balance cost (Phase 8).
    /// Slice-of-slices: device_nets[dev] = list of net indices for that device.
    /// Set externally (e.g. from SA) before calling computeFull/computeDeltaCost.
    device_nets_map: []const []u32 = &.{},

    /// Interdigitation group sidecar (Phase 7); reuses CentroidGroup format.
    /// Each group defines two device sets (A, B) that should alternate in X.
    interdigitation_groups: []const CentroidGroup = &.{},

    /// Well regions for WPE mismatch computation (Phase 9).
    /// Empty means no WPE penalty.
    well_regions: []const WellRegion = &.{},

    /// Device orientations for orientation mismatch computation (Phase 2).
    /// Empty means all devices have default .N orientation (no mismatch).
    orientations: []const Orientation = &.{},

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

        // 5. Proximity constraints (penalize exceeding max distance).
        self.proximity_cost = computeProximity(device_positions, constraints);

        // 6. Isolation constraints (penalize being closer than min distance).
        self.isolation_cost = computeIsolation(device_positions, device_dimensions, constraints);

        // 7. RUDY overflow.
        self.rudy_overflow = rudy_grid.totalOverflow();

        // 8. Device overlap penalty.
        self.overlap_cost = computeOverlap(device_positions, device_dimensions);

        // 9. Thermal mismatch (Phase 5).
        self.thermal_cost = computeThermalMismatch(device_positions, constraints, self.heat_sources);

        // 10. Orientation mismatch (Phase 2).
        self.orientation_cost = computeOrientationMismatch(self.orientations, constraints);

        // 11. LDE mismatch (Phase 4): SA/SB equalization for matched pairs.
        self.lde_cost = computeLde(device_positions, device_dimensions, constraints, self.layout_width);

        // 12. Common-centroid (Phase 3).
        self.centroid_cost = computeCommonCentroid(device_positions, self.centroid_groups);

        // 13. Parasitic routing balance (Phase 8).
        self.parasitic_cost = computeParasiticBalance(device_positions, pin_positions, adj, constraints, self.device_nets_map);

        // 14. Interdigitation (Phase 7).
        self.interdigitation_cost = computeInterdigitation(device_positions, self.interdigitation_groups);

        // 15. Edge penalty (Phase 6).
        self.edge_penalty_cost = computeEdgePenalty(device_positions, device_dimensions, constraints, self.is_dummy, self.layout_width, self.layout_height);

        // 16. WPE mismatch (Phase 9).
        self.wpe_cost = computeWpeMismatch(device_positions, constraints, self.well_regions);

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

        // 5/6. Proximity and isolation constraints.
        const new_prox = computeProximity(all_device_positions, constraints);
        const new_iso = computeIsolation(all_device_positions, device_dimensions, constraints);

        // 7. RUDY overflow.
        const new_rudy = rudy_grid.totalOverflow();

        // 8. Device overlap penalty.
        const new_overlap = computeOverlap(all_device_positions, device_dimensions);

        // 9. Thermal mismatch (Phase 5).
        const new_thermal = computeThermalMismatch(all_device_positions, constraints, self.heat_sources);

        // 10. Orientation mismatch — recompute (orientation may change in flip moves).
        const new_orientation = computeOrientationMismatch(self.orientations, constraints);

        // 11. LDE mismatch (Phase 4).
        const new_lde = computeLde(all_device_positions, device_dimensions, constraints, self.layout_width);

        // 12. Common-centroid (Phase 3).
        const new_centroid = computeCommonCentroid(all_device_positions, self.centroid_groups);

        // 13. Parasitic routing balance (Phase 8).
        const new_parasitic = computeParasiticBalance(all_device_positions, new_pin_positions, adj, constraints, self.device_nets_map);

        // 14. Interdigitation (Phase 7).
        const new_interdigitation = computeInterdigitation(all_device_positions, self.interdigitation_groups);

        // 15. Edge penalty (Phase 6).
        const new_edge_penalty = computeEdgePenalty(all_device_positions, device_dimensions, constraints, self.is_dummy, self.layout_width, self.layout_height);

        // 16. WPE mismatch (Phase 9).
        const new_wpe = computeWpeMismatch(all_device_positions, constraints, self.well_regions);

        const num_nets = adj.num_nets;
        const w = self.weights;
        const hpwl_norm: f32 = if (num_nets > 0) @floatFromInt(num_nets) else 1.0;

        const new_total = w.w_hpwl * new_hpwl_sum / hpwl_norm +
            w.w_area * new_area +
            w.w_symmetry * new_sym +
            w.w_matching * new_match +
            w.w_proximity * new_prox +
            w.w_isolation * new_iso +
            w.w_rudy * new_rudy +
            w.w_overlap * new_overlap +
            w.w_thermal * new_thermal +
            w.w_lde * new_lde +
            w.w_orientation * new_orientation +
            w.w_common_centroid * new_centroid +
            w.w_parasitic * new_parasitic +
            w.w_interdigitation * new_interdigitation +
            w.w_edge_penalty * new_edge_penalty +
            w.w_wpe * new_wpe;

        const delta = new_total - self.total;

        return DeltaResult{
            .new_total = new_total,
            .delta = delta,
            .new_hpwl_sum = new_hpwl_sum,
            .new_area = new_area,
            .new_sym = new_sym,
            .new_match = new_match,
            .new_prox = new_prox,
            .new_iso = new_iso,
            .new_rudy = new_rudy,
            .new_overlap = new_overlap,
            .new_thermal = new_thermal,
            .new_lde = new_lde,
            .new_orientation = new_orientation,
            .new_centroid = new_centroid,
            .new_parasitic = new_parasitic,
            .new_interdigitation = new_interdigitation,
            .new_edge_penalty = new_edge_penalty,
            .new_wpe = new_wpe,
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
        new_prox: f32,
        new_iso: f32,
        new_rudy: f32,
        new_overlap: f32,
        new_thermal: f32,
        new_lde: f32,
        new_orientation: f32,
        new_centroid: f32,
        new_parasitic: f32,
        new_interdigitation: f32,
        new_edge_penalty: f32,
        new_wpe: f32,
        new_total: f32,
    ) void {
        self.hpwl_sum = new_hpwl_sum;
        self.area_cost = new_area;
        self.symmetry_cost = new_sym;
        self.matching_cost = new_match;
        self.proximity_cost = new_prox;
        self.isolation_cost = new_iso;
        self.rudy_overflow = new_rudy;
        self.overlap_cost = new_overlap;
        self.thermal_cost = new_thermal;
        self.lde_cost = new_lde;
        self.orientation_cost = new_orientation;
        self.centroid_cost = new_centroid;
        self.parasitic_cost = new_parasitic;
        self.interdigitation_cost = new_interdigitation;
        self.edge_penalty_cost = new_edge_penalty;
        self.wpe_cost = new_wpe;
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
            w.w_proximity * self.proximity_cost +
            w.w_isolation * self.isolation_cost +
            w.w_rudy * self.rudy_overflow +
            w.w_overlap * self.overlap_cost +
            w.w_thermal * self.thermal_cost +
            w.w_lde * self.lde_cost +
            w.w_orientation * self.orientation_cost +
            w.w_common_centroid * self.centroid_cost +
            w.w_parasitic * self.parasitic_cost +
            w.w_interdigitation * self.interdigitation_cost +
            w.w_edge_penalty * self.edge_penalty_cost +
            w.w_wpe * self.wpe_cost;
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
/// X-axis (`.symmetry`): mirror about vertical axis x = axis_x.
///   L1 norm: `|x_a + x_b - 2*axis_x| + |y_a - y_b|`
///   L2 norm: `(x_a + x_b - 2*axis_x)² + (y_a - y_b)²`
///
/// Y-axis (`.symmetry_y`): mirror about horizontal axis y = axis_y.
///   L1 norm: `|x_a - x_b| + |y_a + y_b - 2*axis_y|`
///   L2 norm: `(x_a - x_b)² + (y_a + y_b - 2*axis_y)²`
pub fn computeSymmetry(
    positions: []const [2]f32,
    constraints: []const Constraint,
    norm: SymmetryNorm,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind == .symmetry) {
            // X-axis mirror: devices reflected about vertical axis x = axis_x
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
        } else if (c.kind == .symmetry_y) {
            // Y-axis mirror: devices reflected about horizontal axis y = axis_y
            const xa = positions[c.dev_a][0];
            const ya = positions[c.dev_a][1];
            const xb = positions[c.dev_b][0];
            const yb = positions[c.dev_b][1];
            const dx = xa - xb;
            const dy = ya + yb - 2.0 * c.axis_y;
            sum += switch (norm) {
                .L1 => @abs(dx) + @abs(dy),
                .L2 => dx * dx + dy * dy,
            };
        }
    }
    return sum;
}

/// Default minimum spacing between matched devices (used when device
/// dimensions are zero or unavailable).
const default_min_spacing: f32 = 2.0;

/// Proximity cost: for each proximity constraint, penalise devices that are
/// farther apart than the threshold stored in `c.param`.  Cost is the squared
/// excess distance beyond the threshold.  When `c.param` is zero a default
/// threshold of `default_min_spacing` is used.
pub fn computeProximity(
    positions: []const [2]f32,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .proximity) continue;

        const dx = positions[c.dev_a][0] - positions[c.dev_b][0];
        const dy = positions[c.dev_a][1] - positions[c.dev_b][1];
        const dist = @sqrt(dx * dx + dy * dy);

        const threshold = if (c.param > 0.0) c.param else default_min_spacing;
        if (dist > threshold) {
            const excess = dist - threshold;
            sum += excess * excess;
        }
    }
    return sum;
}

/// Isolation cost: for each isolation constraint, penalise devices that are
/// closer together than the minimum distance stored in `c.param`.  Cost is the
/// squared violation when distance is below the threshold.  When `c.param` is
/// zero a default threshold of `default_min_spacing` is used.
pub fn computeIsolation(
    positions: []const [2]f32,
    device_dimensions: []const [2]f32,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .isolation) continue;

        const dx = positions[c.dev_a][0] - positions[c.dev_b][0];
        const dy = positions[c.dev_a][1] - positions[c.dev_b][1];
        const dist = @sqrt(dx * dx + dy * dy);

        // Account for device sizes: subtract half-widths so we measure
        // edge-to-edge rather than center-to-center.
        var size_offset: f32 = 0.0;
        if (device_dimensions.len > c.dev_a and device_dimensions.len > c.dev_b) {
            const wa = device_dimensions[c.dev_a][0];
            const ha = device_dimensions[c.dev_a][1];
            const wb = device_dimensions[c.dev_b][0];
            const hb = device_dimensions[c.dev_b][1];
            size_offset = (@max(wa, ha) + @max(wb, hb)) / 2.0;
        }

        const edge_dist = dist - size_offset;
        const threshold = if (c.param > 0.0) c.param else default_min_spacing;
        if (edge_dist < threshold) {
            const violation = threshold - edge_dist;
            sum += violation * violation;
        }
    }
    return sum;
}

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

// ─── Thermal field and mismatch (Phase 5) ───────────────────────────────────

/// Approximate thermal field at a point due to all heat sources.
/// Uses inverse-square-distance model: T(pos) ~ sum_k P_k / max(|pos - H_k|^2, epsilon).
/// epsilon prevents singularity when device is co-located with a heat source.
pub fn thermalField(x: f32, y: f32, heat_sources: []const HeatSource) f32 {
    const epsilon: f32 = 1.0; // um^2 — prevents div-by-zero
    var t: f32 = 0.0;
    for (heat_sources) |h| {
        const dx = x - h.x;
        const dy = y - h.y;
        t += h.power / @max(dx * dx + dy * dy, epsilon);
    }
    return t;
}

/// Thermal mismatch cost: sum over matching constraints of |T(pos_a) - T(pos_b)|^2.
/// Piggybacks on `.matching` constraints — no new constraint type needed.
pub fn computeThermalMismatch(
    positions: []const [2]f32,
    constraints: []const Constraint,
    heat_sources: []const HeatSource,
) f32 {
    if (heat_sources.len == 0) return 0.0;
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        const ta = thermalField(positions[c.dev_a][0], positions[c.dev_a][1], heat_sources);
        const tb = thermalField(positions[c.dev_b][0], positions[c.dev_b][1], heat_sources);
        const dt = ta - tb;
        sum += dt * dt;
    }
    return sum;
}

/// Σ over orientation_match constraints. Returns count of mismatched pairs.
/// Binary penalty: 0 if orientations match, 1.0 if they differ.
/// Multiplied by weight, this creates a hard incentive for SA to fix orientation.
pub fn computeOrientationMismatch(
    orientations: []const Orientation,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .orientation_match) continue;
        if (orientations[c.dev_a] != orientations[c.dev_b]) {
            sum += 1.0;
        }
    }
    return sum;
}

/// Transform a pin offset (ox, oy) according to device orientation.
/// The base offsets assume orientation N (north, no rotation).
pub fn transformPinOffset(ox: f32, oy: f32, orient: Orientation) [2]f32 {
    return switch (orient) {
        .N => .{ ox, oy },
        .S => .{ -ox, -oy },
        .FN => .{ -ox, oy },
        .FS => .{ ox, -oy },
        .E => .{ oy, -ox },
        .W => .{ -oy, ox },
        .FE => .{ oy, ox },
        .FW => .{ -oy, -ox },
    };
}

// ─── LDE (SA/SB equalization) functions (Phase 4) ────────────────────────────

/// Approximate SA/SB for a MOSFET device given surrounding device positions.
/// SA = distance from device's left diffusion edge to nearest STI (left neighbor or array edge).
/// SB = distance from device's right diffusion edge to nearest STI (right neighbor or array edge).
///
/// For a device at (x, y) with width w:
///   left_diff_edge  = x - w/2
///   right_diff_edge = x + w/2
///   SA = min(left_diff_edge - 0, min over left-neighbors of (left_diff_edge - neighbor_right_edge))
///   SB = min(array_width - right_diff_edge, min over right-neighbors of (neighbor_left_edge - right_diff_edge))
pub fn computeDeviceSaSb(
    dev: u32,
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    array_width: f32,
) [2]f32 {
    const x = positions[dev][0];
    const w = if (dimensions.len > dev and dimensions[dev][0] > 0.0)
        dimensions[dev][0]
    else
        2.0; // default
    const left_edge = x - w / 2.0;
    const right_edge = x + w / 2.0;

    var sa: f32 = left_edge; // distance to left array boundary
    var sb: f32 = array_width - right_edge; // distance to right array boundary

    for (positions, 0..) |pos, i| {
        if (i == dev) continue;
        const ow = if (dimensions.len > i and dimensions[i][0] > 0.0)
            dimensions[i][0]
        else
            2.0;
        const neighbor_right = pos[0] + ow / 2.0;
        const neighbor_left = pos[0] - ow / 2.0;

        // Check if neighbor is to the left
        if (neighbor_right < left_edge) {
            sa = @min(sa, left_edge - neighbor_right);
        }
        // Check if neighbor is to the right
        if (neighbor_left > right_edge) {
            sb = @min(sb, neighbor_left - right_edge);
        }
    }

    return .{ @max(sa, 0.0), @max(sb, 0.0) };
}

/// LDE mismatch cost: Sigma over matching constraints of (delta_SA^2 + delta_SB^2).
/// Only applies to matching constraints — piggybacks on the existing constraint type.
pub fn computeLde(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    constraints: []const Constraint,
    array_width: f32,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        const sa_sb_a = computeDeviceSaSb(c.dev_a, positions, dimensions, array_width);
        const sa_sb_b = computeDeviceSaSb(c.dev_b, positions, dimensions, array_width);
        const d_sa = sa_sb_a[0] - sa_sb_b[0];
        const d_sb = sa_sb_a[1] - sa_sb_b[1];
        sum += d_sa * d_sa + d_sb * d_sb;
    }
    return sum;
}

// ─── Common-centroid cost (Phase 3) ──────────────────────────────────────────

/// Common-centroid cost: sum of squared centroid distances.
///
/// For each group pair (A, B):
///   centroid_A = (1/|A|) * Sigma_{i in A} pos[i]
///   centroid_B = (1/|B|) * Sigma_{j in B} pos[j]
///   cost += (centroid_Ax - centroid_Bx)^2 + (centroid_Ay - centroid_By)^2
pub fn computeCommonCentroid(
    positions: []const [2]f32,
    groups: []const CentroidGroup,
) f32 {
    var sum: f32 = 0.0;
    for (groups) |g| {
        if (g.group_a.len == 0 or g.group_b.len == 0) continue;

        var ax: f32 = 0.0;
        var ay: f32 = 0.0;
        for (g.group_a) |dev| {
            ax += positions[dev][0];
            ay += positions[dev][1];
        }
        ax /= @as(f32, @floatFromInt(g.group_a.len));
        ay /= @as(f32, @floatFromInt(g.group_a.len));

        var bx: f32 = 0.0;
        var by: f32 = 0.0;
        for (g.group_b) |dev| {
            bx += positions[dev][0];
            by += positions[dev][1];
        }
        bx /= @as(f32, @floatFromInt(g.group_b.len));
        by /= @as(f32, @floatFromInt(g.group_b.len));

        const dx = ax - bx;
        const dy = ay - by;
        sum += dx * dx + dy * dy;
    }
    return sum;
}

// ─── Parasitic routing balance (Phase 8) ─────────────────────────────────────

/// Estimated routing length from device centre to net centroid (Manhattan distance).
/// Net centroid = average position of all pins on that net.
pub fn estimatedRouteLength(
    dev: u32,
    net: u32,
    device_positions: []const [2]f32,
    pin_positions: []const [2]f32,
    adj: NetAdjacency,
) f32 {
    const start = adj.net_pin_starts[net];
    const end = adj.net_pin_starts[net + 1];
    if (end <= start) return 0.0;

    var cx: f32 = 0.0;
    var cy: f32 = 0.0;
    for (start..end) |k| {
        const pid = adj.pin_list[k].toInt();
        cx += pin_positions[pid][0];
        cy += pin_positions[pid][1];
    }
    const n: f32 = @floatFromInt(end - start);
    cx /= n;
    cy /= n;

    // Manhattan distance from device position to net centroid.
    return @abs(device_positions[dev][0] - cx) + @abs(device_positions[dev][1] - cy);
}

/// Parasitic routing imbalance: for each matched pair sharing a net,
/// penalise difference in estimated routing length.
///
/// Cost = Sigma_{matched_pairs} Sigma_{shared_nets} (L_route_a - L_route_b)^2
///
/// `device_nets_map` maps each device index to a slice of net indices it
/// participates in.  When empty, parasitic balance is skipped (returns 0).
pub fn computeParasiticBalance(
    device_positions: []const [2]f32,
    pin_positions: []const [2]f32,
    adj: NetAdjacency,
    constraints: []const Constraint,
    device_nets_map: []const []u32,
) f32 {
    if (device_nets_map.len == 0) return 0.0;

    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        if (c.dev_a >= device_nets_map.len or c.dev_b >= device_nets_map.len) continue;
        // Find shared nets between dev_a and dev_b.
        for (device_nets_map[c.dev_a]) |net_a| {
            for (device_nets_map[c.dev_b]) |net_b| {
                if (net_a != net_b) continue;
                const la = estimatedRouteLength(c.dev_a, net_a, device_positions, pin_positions, adj);
                const lb = estimatedRouteLength(c.dev_b, net_a, device_positions, pin_positions, adj);
                const dl = la - lb;
                sum += dl * dl;
            }
        }
    }
    return sum;
}


// ─── Edge penalty (Phase 6: Dummy Device Modeling) ──────────────────────────

/// Threshold distance for considering an edge "exposed".  An edge is exposed
/// when no adjacent (non-dummy) device lies within this distance of it.
const edge_adjacency_threshold: f32 = 1.0;

/// Count how many of a device's 4 edges (left, right, top, bottom) are
/// "exposed" — i.e. face the array boundary or have no adjacent non-dummy
/// device within `edge_adjacency_threshold`.
///
/// Dummy devices are never counted as neighbours (they don't shield).
/// Returns 0–4.
pub fn countExposedEdges(
    dev: u32,
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    is_dummy: []const bool,
    layout_width: f32,
    layout_height: f32,
) u4 {
    _ = layout_width;
    _ = layout_height;

    const w = if (dimensions.len > dev and dimensions[dev][0] > 0.0)
        dimensions[dev][0]
    else
        2.0;
    const h = if (dimensions.len > dev and dimensions[dev][1] > 0.0)
        dimensions[dev][1]
    else
        2.0;

    const cx = positions[dev][0];
    const cy = positions[dev][1];
    const left_edge = cx - w / 2.0;
    const right_edge = cx + w / 2.0;
    const top_edge = cy + h / 2.0;
    const bottom_edge = cy - h / 2.0;

    var left_covered = false;
    var right_covered = false;
    var top_covered = false;
    var bottom_covered = false;

    for (positions, 0..) |pos, i| {
        if (i == dev) continue;
        // Skip dummy devices — they don't provide shielding for counting.
        if (is_dummy.len > i and is_dummy[i]) continue;

        const ow = if (dimensions.len > i and dimensions[i][0] > 0.0)
            dimensions[i][0]
        else
            2.0;
        const oh = if (dimensions.len > i and dimensions[i][1] > 0.0)
            dimensions[i][1]
        else
            2.0;

        const n_left = pos[0] - ow / 2.0;
        const n_right = pos[0] + ow / 2.0;
        const n_top = pos[1] + oh / 2.0;
        const n_bottom = pos[1] - oh / 2.0;

        // Check vertical overlap (y-axis) — neighbour must overlap vertically
        // with this device for it to shield a left/right edge.
        const y_overlap = (n_bottom < top_edge) and (n_top > bottom_edge);

        // Check horizontal overlap (x-axis) — neighbour must overlap
        // horizontally with this device for it to shield a top/bottom edge.
        const x_overlap = (n_left < right_edge) and (n_right > left_edge);

        if (y_overlap) {
            // Left: neighbour's right edge is close to our left edge.
            if (n_right <= left_edge and (left_edge - n_right) <= edge_adjacency_threshold) {
                left_covered = true;
            }
            // Right: neighbour's left edge is close to our right edge.
            if (n_left >= right_edge and (n_left - right_edge) <= edge_adjacency_threshold) {
                right_covered = true;
            }
        }

        if (x_overlap) {
            // Bottom: neighbour's top edge is close to our bottom edge.
            if (n_top <= bottom_edge and (bottom_edge - n_top) <= edge_adjacency_threshold) {
                bottom_covered = true;
            }
            // Top: neighbour's bottom edge is close to our top edge.
            if (n_bottom >= top_edge and (n_bottom - top_edge) <= edge_adjacency_threshold) {
                top_covered = true;
            }
        }
    }

    var count: u4 = 0;
    if (!left_covered) count += 1;
    if (!right_covered) count += 1;
    if (!top_covered) count += 1;
    if (!bottom_covered) count += 1;
    return count;
}

/// Edge penalty: for each matching constraint, penalise asymmetric edge
/// exposure between the two matched devices.  Dummy devices are exempt
/// (they exist TO absorb edge effects).
///
/// Matched devices with different exposed edge counts get penalty from the
/// squared difference of their exposure counts.
pub fn computeEdgePenalty(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    constraints: []const Constraint,
    is_dummy: []const bool,
    layout_width: f32,
    layout_height: f32,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;

        // Skip if either device is a dummy.
        const a_dummy = is_dummy.len > c.dev_a and is_dummy[c.dev_a];
        const b_dummy = is_dummy.len > c.dev_b and is_dummy[c.dev_b];
        if (a_dummy or b_dummy) continue;

        const ea = countExposedEdges(c.dev_a, positions, dimensions, is_dummy, layout_width, layout_height);
        const eb = countExposedEdges(c.dev_b, positions, dimensions, is_dummy, layout_width, layout_height);
        // Penalise asymmetry in edge exposure.
        const delta: f32 = @floatFromInt(@as(i8, @intCast(ea)) - @as(i8, @intCast(eb)));
        sum += delta * delta;
    }
    return sum;
}

// ─── Dummy insertion (Phase 6: post-SA pass) ─────────────────────────────────

/// Insert dummy devices at exposed edges of matched device arrays.
/// Rules: same size, placed adjacent to the exposed edge.
/// Returns number of dummies inserted.
///
/// This is a **post-placement** step.  Dummies don't participate in SA — they
/// are deterministically placed after SA converges based on final positions.
///
/// The function grows the parallel arrays by appending new dummy entries.
pub fn insertDummies(
    allocator: std.mem.Allocator,
    device_positions: *std.ArrayList([2]f32),
    device_dimensions: *std.ArrayList([2]f32),
    is_dummy_list: *std.ArrayList(bool),
    constraints: []const Constraint,
    layout_width: f32,
    layout_height: f32,
) !u32 {
    // Collect device indices that are part of matching constraints (no duplicates).
    var matched_set = std.AutoHashMap(u32, void).init(allocator);
    defer matched_set.deinit();
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        try matched_set.put(c.dev_a, {});
        try matched_set.put(c.dev_b, {});
    }

    var dummies_inserted: u32 = 0;

    // Snapshot the current count — we only inspect original devices.
    const original_count: u32 = @intCast(device_positions.items.len);

    for (0..original_count) |di| {
        const dev: u32 = @intCast(di);
        // Only insert dummies for matched, non-dummy devices.
        if (!matched_set.contains(dev)) continue;
        if (is_dummy_list.items.len > di and is_dummy_list.items[di]) continue;

        const w = if (device_dimensions.items.len > di and device_dimensions.items[di][0] > 0.0)
            device_dimensions.items[di][0]
        else
            2.0;
        const h = if (device_dimensions.items.len > di and device_dimensions.items[di][1] > 0.0)
            device_dimensions.items[di][1]
        else
            2.0;

        const cx = device_positions.items[di][0];
        const cy = device_positions.items[di][1];

        // Use the current is_dummy snapshot for edge counting.
        const exposed = countExposedEdges(
            dev,
            device_positions.items,
            device_dimensions.items,
            is_dummy_list.items,
            layout_width,
            layout_height,
        );

        if (exposed == 0) continue;

        // Re-check each edge individually and insert a dummy at each exposed one.
        const le = cx - w / 2.0;
        const re = cx + w / 2.0;
        const te = cy + h / 2.0;
        const be = cy - h / 2.0;

        // Check left
        if (isEdgeExposed(dev, 0, device_positions.items, device_dimensions.items, is_dummy_list.items, le, re, te, be)) {
            const dummy_x = le - w / 2.0;
            if (dummy_x - w / 2.0 >= 0.0) {
                try device_positions.append(allocator, .{ dummy_x, cy });
                try device_dimensions.append(allocator, .{ w, h });
                try is_dummy_list.append(allocator, true);
                dummies_inserted += 1;
            }
        }
        // Check right
        if (isEdgeExposed(dev, 1, device_positions.items, device_dimensions.items, is_dummy_list.items, le, re, te, be)) {
            const dummy_x = re + w / 2.0;
            if (dummy_x + w / 2.0 <= layout_width) {
                try device_positions.append(allocator, .{ dummy_x, cy });
                try device_dimensions.append(allocator, .{ w, h });
                try is_dummy_list.append(allocator, true);
                dummies_inserted += 1;
            }
        }
        // Check bottom
        if (isEdgeExposed(dev, 2, device_positions.items, device_dimensions.items, is_dummy_list.items, le, re, te, be)) {
            const dummy_y = be - h / 2.0;
            if (dummy_y - h / 2.0 >= 0.0) {
                try device_positions.append(allocator, .{ cx, dummy_y });
                try device_dimensions.append(allocator, .{ w, h });
                try is_dummy_list.append(allocator, true);
                dummies_inserted += 1;
            }
        }
        // Check top
        if (isEdgeExposed(dev, 3, device_positions.items, device_dimensions.items, is_dummy_list.items, le, re, te, be)) {
            const dummy_y = te + h / 2.0;
            if (dummy_y + h / 2.0 <= layout_height) {
                try device_positions.append(allocator, .{ cx, dummy_y });
                try device_dimensions.append(allocator, .{ w, h });
                try is_dummy_list.append(allocator, true);
                dummies_inserted += 1;
            }
        }
    }

    return dummies_inserted;
}

/// Check if a specific edge (0=left, 1=right, 2=bottom, 3=top) is exposed.
fn isEdgeExposed(
    dev: u32,
    edge: u2,
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    is_dummy_arr: []const bool,
    left_edge: f32,
    right_edge: f32,
    top_edge: f32,
    bottom_edge: f32,
) bool {
    for (positions, 0..) |pos, i| {
        if (i == dev) continue;
        if (is_dummy_arr.len > i and is_dummy_arr[i]) continue;

        const ow = if (dimensions.len > i and dimensions[i][0] > 0.0)
            dimensions[i][0]
        else
            2.0;
        const oh = if (dimensions.len > i and dimensions[i][1] > 0.0)
            dimensions[i][1]
        else
            2.0;

        const n_left = pos[0] - ow / 2.0;
        const n_right = pos[0] + ow / 2.0;
        const n_top = pos[1] + oh / 2.0;
        const n_bottom = pos[1] - oh / 2.0;

        const y_overlap = (n_bottom < top_edge) and (n_top > bottom_edge);
        const x_overlap = (n_left < right_edge) and (n_right > left_edge);

        switch (edge) {
            0 => { // left
                if (y_overlap and n_right <= left_edge and (left_edge - n_right) <= edge_adjacency_threshold) return false;
            },
            1 => { // right
                if (y_overlap and n_left >= right_edge and (n_left - right_edge) <= edge_adjacency_threshold) return false;
            },
            2 => { // bottom
                if (x_overlap and n_top <= bottom_edge and (bottom_edge - n_top) <= edge_adjacency_threshold) return false;
            },
            3 => { // top
                if (x_overlap and n_bottom >= top_edge and (n_bottom - top_edge) <= edge_adjacency_threshold) return false;
            },
        }
    }
    return true;
}

// ─── Interdigitation cost (Phase 7) ──────────────────────────────────────────

/// Interdigitation cost: measures how well unit cells alternate along X axis.
///
/// For each group pair (A, B):
///   1. Centroid imbalance: |centroid_A_x - centroid_B_x|^2
///      Perfect interdigitation cancels 1D gradients => centroids should match.
///   2. Adjacency violations: merge all devices, sort by X position,
///      count consecutive same-group neighbors. Ideal ABABAB has zero violations.
///   3. Spacing variance: penalise non-uniform finger pitch.
///      Sigma (gap_i - mean_gap)^2 drives toward equal spacing.
///
/// Cost = centroid_imbalance + violations^2 + spacing_variance.
pub fn computeInterdigitation(
    positions: []const [2]f32,
    groups: []const CentroidGroup,
) f32 {
    var sum: f32 = 0.0;
    for (groups) |g| {
        const total = g.group_a.len + g.group_b.len;
        if (total < 2) continue;

        // 1. Centroid imbalance along X axis (primary gradient cancellation).
        if (g.group_a.len > 0 and g.group_b.len > 0) {
            var sum_a: f32 = 0.0;
            for (g.group_a) |dev| sum_a += positions[dev][0];
            var sum_b: f32 = 0.0;
            for (g.group_b) |dev| sum_b += positions[dev][0];
            const centroid_a = sum_a / @as(f32, @floatFromInt(g.group_a.len));
            const centroid_b = sum_b / @as(f32, @floatFromInt(g.group_b.len));
            const dc = centroid_a - centroid_b;
            sum += dc * dc;
        }

        // 2. Adjacency violations: count same-group consecutive pairs in X-sorted order.
        //    Use insertion sort on the merged sequence (groups are typically small).
        //    We tag each device: false = group A, true = group B.

        // Build (x_pos, is_b) pairs in a stack-local buffer.
        // Max practical group size is bounded; use a comptime-sized buffer.
        const max_interdig: usize = 64;
        if (total > max_interdig) continue; // skip oversized groups

        var xs: [max_interdig]f32 = undefined;
        var tags: [max_interdig]bool = undefined;
        var n: usize = 0;

        for (g.group_a) |dev| {
            xs[n] = positions[dev][0];
            tags[n] = false;
            n += 1;
        }
        for (g.group_b) |dev| {
            xs[n] = positions[dev][0];
            tags[n] = true;
            n += 1;
        }

        // Insertion sort by X position.
        for (1..n) |i| {
            const key_x = xs[i];
            const key_tag = tags[i];
            var j: usize = i;
            while (j > 0 and xs[j - 1] > key_x) {
                xs[j] = xs[j - 1];
                tags[j] = tags[j - 1];
                j -= 1;
            }
            xs[j] = key_x;
            tags[j] = key_tag;
        }

        // Count adjacent same-group violations.
        var violations: f32 = 0.0;
        for (1..n) |i| {
            if (tags[i] == tags[i - 1]) {
                violations += 1.0;
            }
        }
        sum += violations * violations;

        // 3. Spacing variance: penalise non-uniform finger pitch.
        //    Compute gaps between consecutive sorted devices, then add
        //    Sigma (gap_i - mean_gap)^2 to the cost.
        if (n >= 3) {
            const num_gaps = n - 1;
            var gap_sum: f32 = 0.0;
            var gaps: [max_interdig]f32 = undefined;
            for (0..num_gaps) |i| {
                gaps[i] = xs[i + 1] - xs[i];
                gap_sum += gaps[i];
            }
            const mean_gap = gap_sum / @as(f32, @floatFromInt(num_gaps));
            var spacing_var: f32 = 0.0;
            for (0..num_gaps) |i| {
                const d = gaps[i] - mean_gap;
                spacing_var += d * d;
            }
            sum += spacing_var;
        }
    }
    return sum;
}

// ─── WPE (Well Proximity Effect) functions (Phase 9) ─────────────────────────

/// Minimum distance from device centre to nearest well edge.
/// WPE causes ΔVth = f(distance_to_well_edge) that decays over ~1 µm.
/// Checks all 4 edges of all well regions and returns the minimum distance.
/// If no well regions exist, returns infinity.
pub fn deviceToWellEdge(
    dev: u32,
    positions: []const [2]f32,
    wells: []const WellRegion,
) f32 {
    if (wells.len == 0) return std.math.inf(f32);

    var min_dist: f32 = std.math.inf(f32);
    const x = positions[dev][0];
    const y = positions[dev][1];
    for (wells) |w| {
        // Distance to each of the 4 well boundary edges.
        min_dist = @min(min_dist, @abs(x - w.x_min));
        min_dist = @min(min_dist, @abs(x - w.x_max));
        min_dist = @min(min_dist, @abs(y - w.y_min));
        min_dist = @min(min_dist, @abs(y - w.y_max));
    }
    return min_dist;
}

/// WPE mismatch cost: for matched pairs, penalise difference in well-edge distance.
/// Cost = Σ_matched (dist_a - dist_b)²
///
/// When both devices are far from well edges (> 1 µm), the WPE effect is
/// negligible, so we apply a reduced weight (0.1×) to the penalty.
pub fn computeWpeMismatch(
    positions: []const [2]f32,
    constraints: []const Constraint,
    wells: []const WellRegion,
) f32 {
    if (wells.len == 0) return 0.0;
    const far_threshold: f32 = 1.0; // µm — WPE decay distance
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        const da = deviceToWellEdge(c.dev_a, positions, wells);
        const db = deviceToWellEdge(c.dev_b, positions, wells);
        const dd = da - db;
        var penalty = dd * dd;
        // Both devices far from well edge → reduced penalty (WPE is negligible).
        if (da > far_threshold and db > far_threshold) {
            penalty *= 0.1;
        }
        sum += penalty;
    }
    return sum;
}

/// Guard ring validation result for a single device group.
pub const GuardRingResult = struct {
    /// Index of the first device in the group (for identification).
    group_device: u32,
    /// True if a well region fully encloses the group's bounding box.
    has_guard_ring: bool,
};

/// Post-SA guard ring validation: verify each group of matched devices
/// has a well region that fully encloses its bounding box.
///
/// Returns a list of GuardRingResult entries for each matched group.
/// Caller must free the returned slice.
///
/// A group is the set of all devices connected by matching constraints.
/// For simplicity, we check each matching pair independently — a pair is
/// considered covered if any well region fully encloses both devices'
/// bounding boxes.
pub fn checkGuardRings(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    constraints: []const Constraint,
    wells: []const WellRegion,
    allocator: std.mem.Allocator,
) ![]GuardRingResult {
    // Count matching constraints for allocation.
    var count: usize = 0;
    for (constraints) |c| {
        if (c.kind == .matching) count += 1;
    }
    if (count == 0) return &.{};

    var results = try allocator.alloc(GuardRingResult, count);
    var idx: usize = 0;

    for (constraints) |c| {
        if (c.kind != .matching) continue;

        // Compute bounding box of the matched pair (including device dimensions).
        const hw_a = if (dimensions.len > c.dev_a and dimensions[c.dev_a][0] > 0.0)
            dimensions[c.dev_a][0] / 2.0
        else
            1.0;
        const hh_a = if (dimensions.len > c.dev_a and dimensions[c.dev_a][1] > 0.0)
            dimensions[c.dev_a][1] / 2.0
        else
            1.0;
        const hw_b = if (dimensions.len > c.dev_b and dimensions[c.dev_b][0] > 0.0)
            dimensions[c.dev_b][0] / 2.0
        else
            1.0;
        const hh_b = if (dimensions.len > c.dev_b and dimensions[c.dev_b][1] > 0.0)
            dimensions[c.dev_b][1] / 2.0
        else
            1.0;

        const group_xmin = @min(positions[c.dev_a][0] - hw_a, positions[c.dev_b][0] - hw_b);
        const group_xmax = @max(positions[c.dev_a][0] + hw_a, positions[c.dev_b][0] + hw_b);
        const group_ymin = @min(positions[c.dev_a][1] - hh_a, positions[c.dev_b][1] - hh_b);
        const group_ymax = @max(positions[c.dev_a][1] + hh_a, positions[c.dev_b][1] + hh_b);

        // Check if any well region fully encloses this group.
        var enclosed = false;
        for (wells) |w| {
            if (w.x_min <= group_xmin and w.x_max >= group_xmax and
                w.y_min <= group_ymin and w.y_max >= group_ymax)
            {
                enclosed = true;
                break;
            }
        }

        results[idx] = .{
            .group_device = c.dev_a,
            .has_guard_ring = enclosed,
        };
        idx += 1;
    }

    return results;
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
    const sentinel_prox: f32 = 33.0;
    const sentinel_iso: f32 = 22.0;
    const sentinel_rudy: f32 = 55.0;
    const sentinel_overlap: f32 = 77.0;
    const sentinel_thermal: f32 = 11.0;
    const sentinel_lde: f32 = 5.0;
    const sentinel_orientation: f32 = 7.0;
    const sentinel_centroid: f32 = 3.0;
    const sentinel_parasitic: f32 = 2.0;
    const sentinel_interdigitation: f32 = 1.5;
    const sentinel_edge_penalty: f32 = 0.8;
    const sentinel_wpe: f32 = 0.6;
    const sentinel_total: f32 = 44.0;

    cost_fn.acceptDelta(
        sentinel_hpwl,
        sentinel_area,
        sentinel_sym,
        sentinel_match,
        sentinel_prox,
        sentinel_iso,
        sentinel_rudy,
        sentinel_overlap,
        sentinel_thermal,
        sentinel_lde,
        sentinel_orientation,
        sentinel_centroid,
        sentinel_parasitic,
        sentinel_interdigitation,
        sentinel_edge_penalty,
        sentinel_wpe,
        sentinel_total,
    );

    try std.testing.expectApproxEqAbs(sentinel_hpwl, cost_fn.hpwl_sum, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_area, cost_fn.area_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_sym, cost_fn.symmetry_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_match, cost_fn.matching_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_prox, cost_fn.proximity_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_iso, cost_fn.isolation_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_rudy, cost_fn.rudy_overflow, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_overlap, cost_fn.overlap_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_thermal, cost_fn.thermal_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_lde, cost_fn.lde_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_orientation, cost_fn.orientation_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_centroid, cost_fn.centroid_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_parasitic, cost_fn.parasitic_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_interdigitation, cost_fn.interdigitation_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_edge_penalty, cost_fn.edge_penalty_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_wpe, cost_fn.wpe_cost, 1e-6);
    try std.testing.expectApproxEqAbs(sentinel_total, cost_fn.total, 1e-6);
}

// ─── Phase 0F: Proximity and isolation tests ─────────────────────────────────

test "computeProximity zero when within threshold" {
    // Two devices at (0,0) and (3,4), distance = 5.  Threshold = 10.
    // Distance (5) ≤ threshold (10) → no penalty.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 3.0, 4.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 10.0 },
    };
    const cost = computeProximity(&positions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeProximity penalty when exceeding threshold" {
    // Two devices at (0,0) and (3,4), distance = 5.  Threshold = 3.
    // Excess = 5 - 3 = 2 → penalty = 2² = 4.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 3.0, 4.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 3.0 },
    };
    const cost = computeProximity(&positions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost, 1e-4);
}

test "computeProximity ignores non-proximity constraints" {
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 100.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 50.0 },
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeProximity(&positions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeIsolation zero when far enough" {
    // Two devices at (0,0) and (20,0), zero dimensions → edge_dist = 20.
    // Threshold = 10.  edge_dist (20) ≥ threshold (10) → no penalty.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .isolation, .dev_a = 0, .dev_b = 1, .param = 10.0 },
    };
    const cost = computeIsolation(&positions, &dimensions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeIsolation penalty when too close" {
    // Two devices at (0,0) and (3,0), zero dimensions → edge_dist = 3.
    // Threshold = 10.  Violation = 10 - 3 = 7 → penalty = 7² = 49.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 3.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .isolation, .dev_a = 0, .dev_b = 1, .param = 10.0 },
    };
    const cost = computeIsolation(&positions, &dimensions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 49.0), cost, 1e-4);
}

test "computeIsolation accounts for device dimensions" {
    // Two devices at (0,0) and (10,0), each 4x4.
    // size_offset = (max(4,4) + max(4,4)) / 2 = 4.
    // edge_dist = 10 - 4 = 6.  Threshold = 8.
    // Violation = 8 - 6 = 2 → penalty = 2² = 4.
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 4.0, 4.0 }, .{ 4.0, 4.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .isolation, .dev_a = 0, .dev_b = 1, .param = 8.0 },
    };
    const cost = computeIsolation(&positions, &dimensions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cost, 1e-4);
}

test "computeIsolation ignores non-isolation constraints" {
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 1.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 0.5 },
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 0.5 },
    };
    const cost = computeIsolation(&positions, &dimensions, &constraints);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "CostFunction computeFull includes proximity and isolation" {
    // Two devices at (0,0) and (20,0). No nets, no other constraints.
    // Proximity constraint: param = 5 → excess = 20 - 5 = 15 → cost = 225
    // Isolation constraint: param = 25 → violation = 25 - 20 = 5 → cost = 25
    const device_positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 20.0, 0.0 } };
    const device_dimensions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    const starts = [_]u32{0};
    const pin_list = [_]types.PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };

    const constraints = [_]Constraint{
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 5.0 },
        .{ .kind = .isolation, .dev_a = 0, .dev_b = 1, .param = 25.0 },
    };

    var rudy_grid = try @import("rudy.zig").RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    const weights = CostWeights{
        .w_hpwl = 0.0,
        .w_area = 0.0,
        .w_symmetry = 0.0,
        .w_matching = 0.0,
        .w_proximity = 1.0,
        .w_isolation = 1.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };

    var cost_fn = CostFunction.init(weights);
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // proximity: (20 - 5)² = 225
    try std.testing.expectApproxEqAbs(@as(f32, 225.0), cost_fn.proximity_cost, 1e-3);
    // isolation: (25 - 20)² = 25
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), cost_fn.isolation_cost, 1e-3);
    // total = 1.0 * 225 + 1.0 * 25 = 250
    try std.testing.expectApproxEqAbs(@as(f32, 250.0), total, 1e-3);
}

// ─── Phase 1: Y-axis symmetry tests ─────────────────────────────────────────

test "computeSymmetry Y-axis perfect mirror L1" {
    // Two devices at (5, 3) and (5, 7), horizontal axis at y=5.
    // dx = 5 - 5 = 0, dy = 3 + 7 - 2*5 = 0 → cost = 0.
    const positions = [_][2]f32{ .{ 5.0, 3.0 }, .{ 5.0, 7.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry_y, .dev_a = 0, .dev_b = 1, .axis_y = 5.0 },
    };
    const cost = computeSymmetry(&positions, &constraints, .L1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeSymmetry Y-axis perfect mirror L2" {
    // Two devices at (5, 3) and (5, 7), horizontal axis at y=5.
    // dx = 0, dy = 0 → cost = 0.
    const positions = [_][2]f32{ .{ 5.0, 3.0 }, .{ 5.0, 7.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry_y, .dev_a = 0, .dev_b = 1, .axis_y = 5.0 },
    };
    const cost = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeSymmetry Y-axis imperfect placement" {
    // Two devices at (3, 1) and (7, 11), horizontal axis at y=5.
    // dx = 3 - 7 = -4, dy = 1 + 11 - 2*5 = 2.
    // L1: |-4| + |2| = 6
    // L2: (-4)^2 + 2^2 = 16 + 4 = 20
    const positions = [_][2]f32{ .{ 3.0, 1.0 }, .{ 7.0, 11.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry_y, .dev_a = 0, .dev_b = 1, .axis_y = 5.0 },
    };
    const cost_l1 = computeSymmetry(&positions, &constraints, .L1);
    const cost_l2 = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), cost_l1, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), cost_l2, 1e-5);
    try std.testing.expect(cost_l1 < cost_l2);
}

test "computeSymmetry mixed X and Y constraints" {
    // 3 devices: dev 0 & 1 have X-axis symmetry about x=5,
    //            dev 1 & 2 have Y-axis symmetry about y=10.
    //
    // Devices at (3, 5), (7, 5), (7, 15).
    //
    // X-sym (0,1): dx = 3+7-10 = 0, dy = 5-5 = 0 -> cost = 0
    // Y-sym (1,2): dx = 7-7 = 0, dy = 5+15-20 = 0 -> cost = 0
    const positions = [_][2]f32{ .{ 3.0, 5.0 }, .{ 7.0, 5.0 }, .{ 7.0, 15.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
        .{ .kind = .symmetry_y, .dev_a = 1, .dev_b = 2, .axis_y = 10.0 },
    };
    const cost = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeSymmetry mixed X and Y constraints with violations" {
    // 3 devices: dev 0 & 1 have X-axis symmetry about x=5,
    //            dev 1 & 2 have Y-axis symmetry about y=10.
    //
    // Devices at (2, 5), (7, 5), (7, 14).
    //
    // X-sym (0,1): dx = 2+7-10 = -1, dy = 5-5 = 0 -> L2 cost = 1
    // Y-sym (1,2): dx = 7-7 = 0, dy = 5+14-20 = -1 -> L2 cost = 1
    // Total = 2
    const positions = [_][2]f32{ .{ 2.0, 5.0 }, .{ 7.0, 5.0 }, .{ 7.0, 14.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
        .{ .kind = .symmetry_y, .dev_a = 1, .dev_b = 2, .axis_y = 10.0 },
    };
    const cost = computeSymmetry(&positions, &constraints, .L2);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), cost, 1e-5);
}

// ─── Phase 5: Thermal symmetry tests ─────────────────────────────────────────

test "thermalField single source inverse square law" {
    const sources = [_]HeatSource{.{ .x = 0.0, .y = 0.0, .power = 10.0 }};

    // At origin: d^2=0, clamped to epsilon=1.0 -> T = 10/1 = 10
    const t_origin = thermalField(0.0, 0.0, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), t_origin, 1e-5);

    // At (3,4): d^2=25 -> T = 10/25 = 0.4
    const t_far = thermalField(3.0, 4.0, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), t_far, 1e-5);

    // At (1,0): d^2=1=epsilon -> T = 10/1 = 10
    const t_near = thermalField(1.0, 0.0, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), t_near, 1e-5);

    // At (2,0): d^2=4 -> T = 10/4 = 2.5
    const t_mid = thermalField(2.0, 0.0, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), t_mid, 1e-5);
}

test "thermalField multiple sources superposition" {
    const sources = [_]HeatSource{
        .{ .x = 0.0, .y = 0.0, .power = 4.0 },
        .{ .x = 10.0, .y = 0.0, .power = 9.0 },
    };
    // At (5,0): d1^2=25, d2^2=25 -> T = 4/25 + 9/25 = 0.52
    const t = thermalField(5.0, 0.0, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 0.52), t, 1e-5);
}

test "computeThermalMismatch zero when equidistant from heat source" {
    const sources = [_]HeatSource{.{ .x = 5.0, .y = 0.0, .power = 10.0 }};
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const mismatch = computeThermalMismatch(&positions, &constraints, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mismatch, 1e-6);
}

test "computeThermalMismatch nonzero when asymmetric" {
    const sources = [_]HeatSource{.{ .x = 0.0, .y = 0.0, .power = 10.0 }};
    const positions = [_][2]f32{ .{ 2.0, 0.0 }, .{ 10.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    // T_a = 10/4 = 2.5, T_b = 10/100 = 0.1, dt=2.4, cost=5.76
    const mismatch = computeThermalMismatch(&positions, &constraints, &sources);
    try std.testing.expect(mismatch > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5.76), mismatch, 1e-4);
}

test "computeThermalMismatch zero when no heat sources" {
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const mismatch = computeThermalMismatch(&positions, &constraints, &.{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mismatch, 1e-6);
}

test "computeThermalMismatch ignores non-matching constraints" {
    const sources = [_]HeatSource{.{ .x = 0.0, .y = 0.0, .power = 10.0 }};
    const positions = [_][2]f32{ .{ 2.0, 0.0 }, .{ 10.0, 0.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 20.0 },
    };
    const mismatch = computeThermalMismatch(&positions, &constraints, &sources);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mismatch, 1e-6);
}


// ─── Phase 4: LDE (SA/SB equalization) tests ────────────────────────────────

test "computeDeviceSaSb symmetric neighbors" {
    // Three devices at x=5, x=15, x=25 in array_width=30.
    // Each has width=4.
    // Device 1 (x=15, w=4): left_edge=13, right_edge=17
    //   Left neighbor (dev 0, x=5, w=4): neighbor_right=7. SA = min(13, 13-7) = 6
    //   Right neighbor (dev 2, x=25, w=4): neighbor_left=23. SB = min(30-17, 23-17) = 6
    const positions = [_][2]f32{ .{ 5.0, 0.0 }, .{ 15.0, 0.0 }, .{ 25.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 4.0, 2.0 }, .{ 4.0, 2.0 }, .{ 4.0, 2.0 } };
    const result = computeDeviceSaSb(1, &positions, &dimensions, 30.0);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), result[0], 1e-5); // SA
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), result[1], 1e-5); // SB
}

test "computeDeviceSaSb asymmetric neighbors" {
    // Two devices at x=5 and x=20 in array_width=30, each width=4.
    // Device 0 (x=5, w=4): left_edge=3, right_edge=7
    //   No left neighbor. SA = 3 (distance to left boundary)
    //   Right neighbor (dev 1, x=20, w=4): neighbor_left=18. SB = min(30-7, 18-7) = 11
    const positions = [_][2]f32{ .{ 5.0, 0.0 }, .{ 20.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 4.0, 2.0 }, .{ 4.0, 2.0 } };
    const result = computeDeviceSaSb(0, &positions, &dimensions, 30.0);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), result[0], 1e-5); // SA
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), result[1], 1e-5); // SB
}

test "computeLde zero when matched devices have identical geometry" {
    // Two matched devices with identical neighbors on each side.
    // Symmetric placement: devices at x=10, x=20 in array_width=30, each width=4.
    // Dev 0 (x=10): left_edge=8, right_edge=12. SA=8, SB=min(30-12, 18-12)=6
    // Dev 1 (x=20): left_edge=18, right_edge=22. SA=min(18, 18-12)=6, SB=30-22=8
    // delta_SA = 8-6 = 2, delta_SB = 6-8 = -2, cost = 4+4 = 8 (not zero)
    //
    // For zero cost, place them symmetrically about center with equal spacing.
    // Devices at x=10, x=20 in array_width=30.
    // Actually for zero mismatch we need SA_a == SA_b and SB_a == SB_b.
    // Place 3 devices: x=5, x=15, x=25 in array_width=30, each width=4.
    // Dev 0 (x=5): SA=3, SB=min(30-7, 13-7)=6
    // Dev 2 (x=25): SA=min(25-2, 23-17)=6, SB=30-27=3
    // Match dev 0 and dev 2: delta_SA=3-6=-3, delta_SB=6-3=3 -> not zero either.
    //
    // For truly zero: both devices must see identical local geometry.
    // Put them at the same x with same neighbors. Simplest: two devices at same position.
    // But that's degenerate. Use: 4 devices, match the two inner ones.
    // x=0, x=10, x=20, x=30 in array_width=30, each width=2.
    // Dev 1 (x=10): left_edge=9, right_edge=11. left-neighbor right=1, SA=min(9,9-1)=8. right-neighbor left=19, SB=min(30-11,19-11)=8
    // Dev 2 (x=20): left_edge=19, right_edge=21. left-neighbor right=11, SA=min(19,19-11)=8. right-neighbor left=29, SB=min(30-21,29-21)=8
    // Perfect: SA_1=SA_2=8, SB_1=SB_2=8 -> cost=0
    const positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 }, .{ 20.0, 0.0 }, .{ 30.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 }, .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 1, .dev_b = 2 },
    };
    const cost = computeLde(&positions, &dimensions, &constraints, 30.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-4);
}

test "computeLde nonzero when asymmetric placement" {
    // Two devices matched, but placed asymmetrically.
    // Dev 0 at x=5, Dev 1 at x=20, array_width=30, each width=4.
    // Dev 0: left_edge=3, right_edge=7. SA=3, SB=min(30-7, 18-7)=11
    // Dev 1: left_edge=18, right_edge=22. SA=min(18, 18-7)=11, SB=30-22=8
    // delta_SA = 3-11 = -8, delta_SB = 11-8 = 3
    // cost = 64 + 9 = 73
    const positions = [_][2]f32{ .{ 5.0, 0.0 }, .{ 20.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 4.0, 2.0 }, .{ 4.0, 2.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };
    const cost = computeLde(&positions, &dimensions, &constraints, 30.0);
    try std.testing.expect(cost > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 73.0), cost, 1e-3);
}

test "computeLde ignores non-matching constraints" {
    const positions = [_][2]f32{ .{ 5.0, 0.0 }, .{ 20.0, 0.0 } };
    const dimensions = [_][2]f32{ .{ 4.0, 2.0 }, .{ 4.0, 2.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 12.5 },
        .{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 20.0 },
    };
    const cost = computeLde(&positions, &dimensions, &constraints, 30.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cost, 1e-6);
}

test "computeLde integrated with combinedCost" {
    // Verify LDE term is included in full cost computation.
    const device_positions = [_][2]f32{ .{ 5.0, 0.0 }, .{ 20.0, 0.0 } };
    const device_dimensions = [_][2]f32{ .{ 4.0, 2.0 }, .{ 4.0, 2.0 } };

    const starts = [_]u32{0};
    const pin_list = [_]types.PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };

    const constraints = [_]Constraint{
        .{ .kind = .matching, .dev_a = 0, .dev_b = 1 },
    };

    var rudy_grid = try @import("rudy.zig").RudyGrid.init(std.testing.allocator, 100.0, 100.0, 50.0, 0.5);
    defer rudy_grid.deinit();

    // Only enable LDE weight, disable everything else.
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
    };

    var cost_fn = CostFunction.init(weights);
    cost_fn.layout_width = 30.0;
    const total = cost_fn.computeFull(
        &device_positions,
        &device_dimensions,
        &device_positions,
        adj,
        &constraints,
        &rudy_grid,
        &.{},
    );

    // LDE cost should match standalone computation.
    const expected_lde = computeLde(&device_positions, &device_dimensions, &constraints, 30.0);
    try std.testing.expectApproxEqAbs(expected_lde, cost_fn.lde_cost, 1e-4);
    // total = 1.0 * lde_cost
    try std.testing.expectApproxEqAbs(expected_lde, total, 1e-4);
    try std.testing.expect(total > 0.0);
}
