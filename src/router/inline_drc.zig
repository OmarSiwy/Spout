// Inline DRC Checker — lightweight spacing/short checker for use during routing.
//
// Maintains a flat list of wire rectangles (one per routed segment) and checks
// new candidate points for spacing violations against existing geometry on the
// same layer.  Two severity levels:
//
//   • hard_violation — overlap (short) or gap < min_spacing  → block the move
//   • soft_penalty   — gap in [min_spacing, 1.5 × min_spacing) → add cost
//
// Designed to be queried per-step by the A* router so that DRC-clean routes
// are preferred without a full post-route DRC pass.

const std = @import("std");
const core_types = @import("../core/types.zig");
const layout_if = @import("../core/layout_if.zig");
const device_arrays_mod = @import("../core/device_arrays.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");
const pin_edge_arrays_mod = @import("../core/pin_edge_arrays.zig");

const NetIdx = core_types.NetIdx;
const DeviceArrays = device_arrays_mod.DeviceArrays;
const RouteArrays = route_arrays_mod.RouteArrays;
const PinEdgeArrays = pin_edge_arrays_mod.PinEdgeArrays;

// Internal alias — InlineDrcChecker uses layout_if.PdkConfig for routing queries.
const LayoutPdkConfig = layout_if.PdkConfig;

// Re-export DrcRule and DrcViolation from core types so callers import them here.
pub const DrcRule = core_types.DrcRule;
pub const DrcViolation = core_types.DrcViolation;

// ─── DRC-specific PdkConfig ──────────────────────────────────────────────────
//
// Separate from layout_if.PdkConfig.  Holds only the spacing/width/enclosure
// rules needed by the standalone DRC checker, indexed by route-layer convention:
//   0 = LI, 1 = M1, 2 = M2, …
//
// Populated via setLayerRules / setLayerRulesWithSameNet from a layout_if.PdkConfig.

pub const PdkConfig = struct {
    min_spacing: [16]f32 = .{0.0} ** 16,
    same_net_spacing: [16]f32 = .{0.0} ** 16,
    min_width: [16]f32 = .{0.0} ** 16,
    min_enclosure: [16]f32 = .{0.0} ** 16,
    db_unit: f32 = 0.001,
    guard_ring_width: f32 = 0.0,
    guard_ring_spacing: f32 = 0.0,

    /// Return a zeroed DRC config (all rules unset).
    pub fn initDefault() PdkConfig {
        return .{};
    }

    /// Set spacing/width/enclosure rules for one route layer.
    pub fn setLayerRules(
        self: *PdkConfig,
        layer: u8,
        min_spacing: f32,
        min_width: f32,
        min_enclosure: f32,
    ) void {
        if (layer >= 16) return;
        self.min_spacing[layer] = min_spacing;
        self.min_width[layer] = min_width;
        self.min_enclosure[layer] = min_enclosure;
    }

    /// Like setLayerRules but also records same-net spacing (for same-net DRC).
    pub fn setLayerRulesWithSameNet(
        self: *PdkConfig,
        layer: u8,
        min_spacing: f32,
        same_net_spacing: f32,
        min_width: f32,
        min_enclosure: f32,
    ) void {
        if (layer >= 16) return;
        self.min_spacing[layer] = min_spacing;
        self.same_net_spacing[layer] = same_net_spacing;
        self.min_width[layer] = min_width;
        self.min_enclosure[layer] = min_enclosure;
    }
};

// ─── Types ───────────────────────────────────────────────────────────────────

/// Axis-aligned bounding box of a routed wire segment, tagged with net and layer.
pub const WireRect = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
    net: NetIdx,
    layer: u8,
};

/// Result of a point-query spacing check.
pub const DrcResult = struct {
    hard_violation: bool,
    soft_penalty: f32,
};

/// A recorded DRC marker for diagnostics / incremental repair.
pub const DrcMarker = struct {
    rule: DrcRule,
    layer: u8,
    bbox: [4]f32,
    nets: [2]NetIdx,
};

// ─── InlineDrcChecker ────────────────────────────────────────────────────────

pub const InlineDrcChecker = struct {
    segments: std.ArrayListUnmanaged(WireRect),
    markers: std.ArrayListUnmanaged(DrcMarker),
    pdk: *const LayoutPdkConfig,
    allocator: std.mem.Allocator,
    origin_x: f32,
    origin_y: f32,
    extent_x: f32,
    extent_y: f32,

    pub fn init(
        allocator: std.mem.Allocator,
        pdk: *const LayoutPdkConfig,
        origin_x: f32,
        origin_y: f32,
        extent_x: f32,
        extent_y: f32,
    ) !InlineDrcChecker {
        return .{
            .segments = .{},
            .markers = .{},
            .pdk = pdk,
            .allocator = allocator,
            .origin_x = origin_x,
            .origin_y = origin_y,
            .extent_x = extent_x,
            .extent_y = extent_y,
        };
    }

    pub fn deinit(self: *InlineDrcChecker) void {
        self.segments.deinit(self.allocator);
        self.markers.deinit(self.allocator);
    }

    /// Register a routed wire segment.  The segment is expanded by half-width
    /// on each side to form an axis-aligned bounding box.
    pub fn addSegment(
        self: *InlineDrcChecker,
        layer: u8,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        width: f32,
        net: NetIdx,
    ) !void {
        const hw = width * 0.5;
        try self.segments.append(self.allocator, .{
            .x_min = @min(x1, x2) - hw,
            .y_min = @min(y1, y2) - hw,
            .x_max = @max(x1, x2) + hw,
            .y_max = @max(y1, y2) + hw,
            .net = net,
            .layer = layer,
        });
    }

    /// Remove all segments belonging to a given net (e.g. before rip-up and reroute).
    pub fn removeSegmentsForNet(self: *InlineDrcChecker, net: NetIdx) void {
        var write: usize = 0;
        for (self.segments.items) |seg| {
            if (seg.net.toInt() != net.toInt()) {
                self.segments.items[write] = seg;
                write += 1;
            }
        }
        self.segments.shrinkRetainingCapacity(write);
    }

    /// Check spacing and short violations at a candidate point on a given layer
    /// for a given net.  Returns hard_violation = true if the point (expanded to
    /// min_width) overlaps or is closer than min_spacing to any segment of a
    /// different net on the same layer.
    pub fn checkSpacing(self: *const InlineDrcChecker, layer: u8, x: f32, y: f32, net: NetIdx) DrcResult {
        const min_sp = if (layer < 8) self.pdk.min_spacing[layer] else self.pdk.min_spacing[0];
        const min_w = if (layer < 8) self.pdk.min_width[layer] else self.pdk.min_width[0];
        const hw = min_w * 0.5;

        const px_min = x - hw;
        const px_max = x + hw;
        const py_min = y - hw;
        const py_max = y + hw;

        var hard = false;
        var soft: f32 = 0.0;

        for (self.segments.items) |seg| {
            if (seg.layer != layer) continue;
            if (seg.net.toInt() == net.toInt()) continue;

            // Signed gap: negative means overlap.
            const gap_x = @max(px_min - seg.x_max, seg.x_min - px_max);
            const gap_y = @max(py_min - seg.y_max, seg.y_min - py_max);
            const gap = @max(gap_x, gap_y);

            if (gap < 0) {
                // Overlap → short between different nets.
                hard = true;
                break;
            } else if (gap < min_sp) {
                // Below minimum spacing.
                hard = true;
                break;
            } else if (gap < min_sp * 1.5) {
                // Near-violation — accumulate soft penalty.
                soft += 1.0;
            }
        }

        return .{ .hard_violation = hard, .soft_penalty = soft };
    }

    /// Return all recorded DRC markers (diagnostics).
    pub fn getMarkers(self: *const InlineDrcChecker) []const DrcMarker {
        return self.markers.items;
    }

    /// Decay / age markers (placeholder for incremental repair strategies).
    pub fn decayMarkers(self: *InlineDrcChecker, factor: f32) void {
        _ = factor;
        // Currently a no-op; will be extended for incremental DRC repair.
        var write: usize = 0;
        for (self.markers.items) |marker| {
            self.markers.items[write] = marker;
            write += 1;
        }
    }
};

// ─── Standalone DRC pass ─────────────────────────────────────────────────────

/// Run a full DRC pass over placed devices and routed segments.
///
/// Checks:
///   • Device-device spacing (layer 0) — bounding-box gap vs min_spacing[0]
///   • Route width — each segment width vs min_width[layer]
///
/// Returns a caller-owned slice of violations (free with allocator.free).
pub fn runDrc(
    devices: *const DeviceArrays,
    routes: *const RouteArrays,
    pdk: *const PdkConfig,
    allocator: std.mem.Allocator,
) ![]DrcViolation {
    return runDrcWithPins(devices, routes, pdk, null, allocator);
}

/// Like runDrc but also accepts an optional pin array (reserved for future
/// pin-to-route enclosure checks; currently ignored beyond null safety).
pub fn runDrcWithPins(
    devices: *const DeviceArrays,
    routes: *const RouteArrays,
    pdk: *const PdkConfig,
    pins: ?*const PinEdgeArrays,
    allocator: std.mem.Allocator,
) ![]DrcViolation {
    _ = pins; // reserved for enclosure checks (TODO)

    var violations: std.ArrayListUnmanaged(DrcViolation) = .{};
    errdefer violations.deinit(allocator);

    const n: usize = @intCast(devices.len);

    // 1. Device-device spacing violations on layer 0.
    const layer0_spacing = pdk.min_spacing[0];
    if (layer0_spacing > 0.0) {
        for (0..n) |i| {
            // Skip devices with no physical footprint.
            if (devices.dimensions[i][0] == 0.0 and devices.dimensions[i][1] == 0.0) continue;

            const xi_min = devices.positions[i][0] - devices.dimensions[i][0] * 0.5;
            const xi_max = devices.positions[i][0] + devices.dimensions[i][0] * 0.5;
            const yi_min = devices.positions[i][1] - devices.dimensions[i][1] * 0.5;
            const yi_max = devices.positions[i][1] + devices.dimensions[i][1] * 0.5;

            for (i + 1..n) |j| {
                if (devices.dimensions[j][0] == 0.0 and devices.dimensions[j][1] == 0.0) continue;

                const xj_min = devices.positions[j][0] - devices.dimensions[j][0] * 0.5;
                const xj_max = devices.positions[j][0] + devices.dimensions[j][0] * 0.5;
                const yj_min = devices.positions[j][1] - devices.dimensions[j][1] * 0.5;
                const yj_max = devices.positions[j][1] + devices.dimensions[j][1] * 0.5;

                // Signed gap between bounding boxes (negative = overlap).
                const gap_x = @max(xi_min - xj_max, xj_min - xi_max);
                const gap_y = @max(yi_min - yj_max, yj_min - yi_max);
                const gap = @max(gap_x, gap_y);

                if (gap < layer0_spacing) {
                    try violations.append(allocator, .{
                        .rule = .min_spacing,
                        .layer = 0,
                        .x = (devices.positions[i][0] + devices.positions[j][0]) * 0.5,
                        .y = (devices.positions[i][1] + devices.positions[j][1]) * 0.5,
                        .actual = @max(gap, 0.0),
                        .required = layer0_spacing,
                        .rect_a = @intCast(i),
                        .rect_b = @intCast(j),
                    });
                }
            }
        }
    }

    // 2. Route width violations.
    const n_routes: usize = @intCast(routes.len);
    for (0..n_routes) |k| {
        const layer = routes.layer[k];
        const min_w = if (layer < 16) pdk.min_width[layer] else 0.0;
        if (min_w > 0.0 and routes.width[k] < min_w) {
            try violations.append(allocator, .{
                .rule = .min_width,
                .layer = layer,
                .x = (routes.x1[k] + routes.x2[k]) * 0.5,
                .y = (routes.y1[k] + routes.y2[k]) * 0.5,
                .actual = routes.width[k],
                .required = min_w,
                .rect_a = @intCast(k),
                .rect_b = @intCast(k),
            });
        }
    }

    return violations.toOwnedSlice(allocator);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "InlineDrcChecker detects spacing violation" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Two parallel M1 wires too close (< 0.14um spacing).
    // Wire 0: y ∈ [0.93, 1.07], Wire 1: y ∈ [1.13, 1.27] → gap = 0.06 < 0.14
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);
    try checker.addSegment(0, 1.0, 1.2, 5.0, 1.2, 0.14, net1);

    const result = checker.checkSpacing(0, 1.0, 1.2, net1);
    try std.testing.expect(result.hard_violation);
}

test "InlineDrcChecker allows legal spacing" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Two parallel M1 wires with legal spacing.
    // Wire 0: y ∈ [0.93, 1.07], check point: y ∈ [1.43, 1.57] → gap = 0.36 > 0.21
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);
    try checker.addSegment(0, 1.0, 1.5, 5.0, 1.5, 0.14, net1);

    const result = checker.checkSpacing(0, 1.0, 1.5, net1);
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker detects short between different nets" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Wire on M1 for net0; query same location for net1 → overlap → short.
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);

    const result = checker.checkSpacing(0, 3.0, 1.0, net1);
    try std.testing.expect(result.hard_violation);
}

test "InlineDrcChecker same-net segments do not violate" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);

    // Overlapping segments on the same net should not trigger violations.
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);

    const result = checker.checkSpacing(0, 3.0, 1.0, net0);
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker different layers do not interact" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Wire on layer 0 (M1), query on layer 1 (M2) at same position → no violation.
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);

    const result = checker.checkSpacing(1, 3.0, 1.0, net1);
    try std.testing.expect(!result.hard_violation);
}

test "InlineDrcChecker removeSegmentsForNet" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net1);

    // Before removal: net1 segment overlaps with net0 → violation.
    const before = checker.checkSpacing(0, 3.0, 1.0, NetIdx.fromInt(2));
    try std.testing.expect(before.hard_violation);

    // Remove net0 segments, now only net1 remains.
    checker.removeSegmentsForNet(net0);
    try std.testing.expectEqual(@as(usize, 1), checker.segments.items.len);
    try std.testing.expectEqual(net1.toInt(), checker.segments.items[0].net.toInt());
}

test "InlineDrcChecker soft penalty for near-violation" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);

    var checker = try InlineDrcChecker.init(allocator, &pdk, 0.0, 0.0, 20.0, 20.0);
    defer checker.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Wire 0 at y=1.0: rect y ∈ [0.93, 1.07]
    try checker.addSegment(0, 1.0, 1.0, 5.0, 1.0, 0.14, net0);

    // Check point at y=1.35: rect y ∈ [1.28, 1.42]
    // Gap = 1.28 - 1.07 = 0.21, which is >= min_sp (0.14) but < 1.5*min_sp (0.21)
    // Edge case: 0.21 is exactly 1.5 * 0.14 = 0.21, so NOT < 0.21, no soft penalty.
    // Use y=1.34 instead: rect y ∈ [1.27, 1.41], gap = 1.27 - 1.07 = 0.20
    // 0.20 >= 0.14 (not hard) and 0.20 < 0.21 (soft penalty).
    const result = checker.checkSpacing(0, 3.0, 1.34, net1);
    try std.testing.expect(!result.hard_violation);
    try std.testing.expect(result.soft_penalty > 0.0);
}
