const std = @import("std");
const types = @import("../core/types.zig");
const net_arrays = @import("../core/net_arrays.zig");

const NetIdx = types.NetIdx;
const NetArrays = net_arrays.NetArrays;

// ─── Wire sizing (Phase 1 — simplified, no LP solver) ──────────────────────
//
// Assigns wire widths based on simple heuristic rules:
//   - Power nets (VDD, VSS):  3 × min_width
//   - High-fanout nets (>8):  2 × min_width
//   - Signal nets:            1 × min_width
//
// Phase 2 will replace this with a proper LP-based formulation that
// minimises RC delay subject to DRC and area constraints.

/// PDK configuration relevant to wire sizing.
/// This is a local definition consumed by the routing module; when a
/// project-wide PdkConfig is introduced it should replace this one.
pub const PdkConfig = struct {
    /// Minimum wire width per metal layer (indexed from 0 = M1).
    /// Index 0 = M1, index 1 = M2, etc.  Up to 8 layers supported.
    /// NOTE: This is a PDK-array index (0-based from M1), not a route layer
    /// index. Route layer indices start at 1 for M1 (see route_arrays.zig).
    min_width: [8]f32 = .{ 0.14, 0.14, 0.20, 0.20, 0.40, 0.40, 0.80, 0.80 },

    /// Minimum spacing per metal layer.
    min_spacing: [8]f32 = .{ 0.14, 0.14, 0.20, 0.20, 0.40, 0.40, 0.80, 0.80 },

    /// Number of metal layers available.
    num_layers: u8 = 4,

    /// Via cost multiplier (used by the maze router).
    via_cost: f32 = 5.0,

    /// High-fanout threshold: nets with fanout above this get 2× width.
    high_fanout_threshold: u16 = 8,
};

/// Return the wire width for `net_idx` on the given `layer`.
///
/// The rules, applied in priority order:
///   1. Power net → 3 × min_width[layer]
///   2. Fanout > high_fanout_threshold → 2 × min_width[layer]
///   3. Otherwise (signal) → 1 × min_width[layer]
pub fn assignWidth(
    net_idx: NetIdx,
    nets: *const NetArrays,
    pdk: *const PdkConfig,
    layer: u8,
) f32 {
    const idx: usize = net_idx.toInt();
    const mw = pdk.min_width[layer];

    // Guard against out-of-range indices.
    if (idx >= nets.len) return mw;

    if (nets.is_power[idx]) {
        return mw * 3.0;
    }

    if (nets.fanout[idx] > pdk.high_fanout_threshold) {
        return mw * 2.0;
    }

    return mw;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "signal net gets 1× min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 3);
    defer nets.deinit();

    // Net 0: fanout=2, not power.
    nets.fanout[0] = 2;
    nets.is_power[0] = false;

    const pdk = PdkConfig{};
    const w = assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w, 1e-6);
}

test "power net gets 3× min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 3);
    defer nets.deinit();

    nets.fanout[1] = 4;
    nets.is_power[1] = true;

    const pdk = PdkConfig{};
    const w = assignWidth(NetIdx.fromInt(1), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), w, 1e-6);
}

test "high-fanout signal net gets 2× min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 3);
    defer nets.deinit();

    nets.fanout[2] = 12;
    nets.is_power[2] = false;

    const pdk = PdkConfig{};
    const w = assignWidth(NetIdx.fromInt(2), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.28), w, 1e-6);
}

test "power net beats high-fanout (priority)" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();

    nets.fanout[0] = 20;
    nets.is_power[0] = true;

    const pdk = PdkConfig{};
    const w = assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    // Power rule (3×) takes precedence over high-fanout (2×).
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), w, 1e-6);
}

test "different layers have different min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();

    nets.fanout[0] = 2;
    nets.is_power[0] = false;

    const pdk = PdkConfig{};
    const w0 = assignWidth(NetIdx.fromInt(0), &nets, &pdk, 0);
    const w2 = assignWidth(NetIdx.fromInt(0), &nets, &pdk, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w0, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.20), w2, 1e-6);
}

test "out-of-range net index returns min_width" {
    var nets = try NetArrays.init(std.testing.allocator, 1);
    defer nets.deinit();

    const pdk = PdkConfig{};
    // Net index 99 is well beyond the allocated array.
    const w = assignWidth(NetIdx.fromInt(99), &nets, &pdk, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), w, 1e-6);
}
