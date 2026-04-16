//! Symmetric Steiner Tree Builder — Phase 4
//!
//! Generates mirrored Steiner trees for differential/matched net pairs.
//! For a differential pair the two trees have identical topology but
//! mirrored coordinates around the centroid axis.

const std = @import("std");
const steiner_mod = @import("steiner.zig");
const at = @import("analog_types.zig");

const SteinerTree = steiner_mod.SteinerTree;
const SymmetryAxis = at.SymmetryAxis;
const NetIdx = at.NetIdx;
const AnalogGroupIdx = at.AnalogGroupIdx;

pub const Segment = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    net: NetIdx,

    pub fn length(self: Segment) f32 {
        return @abs(self.x2 - self.x1) + @abs(self.y2 - self.y1);
    }
};

/// Result of building symmetric Steiner trees for a pair of nets.
pub const SymmetricSteinerResult = struct {
    /// Segments for the reference net.
    segments_ref: []Segment,
    /// Segments for the mirrored net (same count, mirrored coordinates).
    segments_mirror: []Segment,
    /// The axis used for mirroring.
    axis: SymmetryAxis,
    /// The world-coordinate value of the axis.
    axis_value: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SymmetricSteinerResult) void {
        self.allocator.free(self.segments_ref);
        self.allocator.free(self.segments_mirror);
        self.* = undefined;
    }
};

/// Compute the centroid [x, y] of a set of 2D points.
fn centroid(points: []const [2]f32) [2]f32 {
    if (points.len == 0) return .{ 0.0, 0.0 };
    var cx: f32 = 0.0;
    var cy: f32 = 0.0;
    for (points) |p| {
        cx += p[0];
        cy += p[1];
    }
    return .{
        cx / @as(f32, @floatFromInt(points.len)),
        cy / @as(f32, @floatFromInt(points.len)),
    };
}

/// Build symmetric Steiner trees for a matched/differential net pair.
///
/// `pins_ref` and `pins_mirror` are world-coordinate pin positions for the
/// two nets.  The algorithm:
///   1. Compute centroids of both pin sets.
///   2. Determine the dominant axis of separation (horizontal or vertical).
///   3. Build a Steiner tree on `pins_ref`.
///   4. Mirror each reference-tree segment around the centroid axis to produce
///      the paired net tree (identical topology guarantee).
pub fn buildSymmetric(
    allocator: std.mem.Allocator,
    pins_ref: []const [2]f32,
    pins_mirror: []const [2]f32,
    net_ref: NetIdx,
    net_mirror: NetIdx,
) !SymmetricSteinerResult {
    // Degenerate: both empty.
    if (pins_ref.len == 0 and pins_mirror.len == 0) {
        return .{
            .segments_ref = &.{},
            .segments_mirror = &.{},
            .axis = .y,
            .axis_value = 0.0,
            .allocator = allocator,
        };
    }

    // Degenerate: one side empty — build a tree on the non-empty side,
    // mirror it to get the empty side.
    if (pins_ref.len == 0) {
        var tree = try SteinerTree.build(allocator, pins_mirror);
        defer tree.deinit();

        const cen = centroid(pins_mirror);
        const axis = SymmetryAxis.y;
        const axis_val = cen[0];

        const mirror_segs = try mirrorSteinerSegments(allocator, tree.segments.items, axis, axis_val);
        errdefer allocator.free(mirror_segs);

        const ref_segs = try allocator.alloc(Segment, tree.segments.items.len);
        for (tree.segments.items, 0..) |seg, i| {
            ref_segs[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net_ref };
        }
        const mirror_owned = try allocator.alloc(Segment, mirror_segs.len);
        for (mirror_segs, 0..) |seg, i| {
            mirror_owned[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net_mirror };
        }
        allocator.free(mirror_segs);

        return .{
            .segments_ref = ref_segs,
            .segments_mirror = mirror_owned,
            .axis = axis,
            .axis_value = axis_val,
            .allocator = allocator,
        };
    }

    if (pins_mirror.len == 0) {
        var tree = try SteinerTree.build(allocator, pins_ref);
        defer tree.deinit();

        const cen = centroid(pins_ref);
        const axis = SymmetryAxis.y;
        const axis_val = cen[0];

        const mirror_segs = try mirrorSteinerSegments(allocator, tree.segments.items, axis, axis_val);
        errdefer allocator.free(mirror_segs);

        const ref_owned = try allocator.alloc(Segment, tree.segments.items.len);
        for (tree.segments.items, 0..) |seg, i| {
            ref_owned[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net_ref };
        }
        const mirror_segs_owned = try allocator.alloc(Segment, mirror_segs.len);
        for (mirror_segs, 0..) |seg, i| {
            mirror_segs_owned[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net_mirror };
        }
        allocator.free(mirror_segs);

        return .{
            .segments_ref = mirror_segs_owned,
            .segments_mirror = ref_owned,
            .axis = axis,
            .axis_value = axis_val,
            .allocator = allocator,
        };
    }

    // Both non-empty: compute centroids and determine axis.
    const c_ref = centroid(pins_ref);
    const c_mir = centroid(pins_mirror);

    const dx = @abs(c_ref[0] - c_mir[0]);
    const dy = @abs(c_ref[1] - c_mir[1]);
    const axis: SymmetryAxis = if (dx >= dy) .y else .x;
    const axis_value = switch (axis) {
        .y => (c_ref[0] + c_mir[0]) * 0.5,
        .x => (c_ref[1] + c_mir[1]) * 0.5,
    };

    // Build reference Steiner tree on the reference pins.
    var tree = try SteinerTree.build(allocator, pins_ref);
    defer tree.deinit();

    // Convert reference tree segments to our Segment type.
    const ref_segs = try allocator.alloc(Segment, tree.segments.items.len);
    for (tree.segments.items, 0..) |seg, i| {
        ref_segs[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net_ref };
    }

    // Mirror reference tree segments to get paired net segments.
    const mirror_raw = try mirrorSteinerSegments(allocator, tree.segments.items, axis, axis_value);
    errdefer allocator.free(mirror_raw);

    const mirror_segs = try allocator.alloc(Segment, mirror_raw.len);
    for (mirror_raw, 0..) |seg, i| {
        mirror_segs[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net_mirror };
    }
    allocator.free(mirror_raw);

    return .{
        .segments_ref = ref_segs,
        .segments_mirror = mirror_segs,
        .axis = axis,
        .axis_value = axis_value,
        .allocator = allocator,
    };
}

/// Mirror an array of SteinerTree segments around an axis.
fn mirrorSteinerSegments(
    allocator: std.mem.Allocator,
    segments: []const SteinerTree.Segment,
    axis: SymmetryAxis,
    axis_val: f32,
) ![]Segment {
    const result = try allocator.alloc(Segment, segments.len);
    for (segments, 0..) |seg, i| {
        result[i] = mirrorSteinerSegment(seg, axis, axis_val);
    }
    return result;
}

/// Mirror a single SteinerTree segment around the given axis.
fn mirrorSteinerSegment(seg: SteinerTree.Segment, axis: SymmetryAxis, val: f32) Segment {
    return switch (axis) {
        .y => .{
            // Mirror across vertical axis: flip X, keep Y.
            .x1 = 2.0 * val - seg.x1,
            .y1 = seg.y1,
            .x2 = 2.0 * val - seg.x2,
            .y2 = seg.y2,
            .net = NetIdx.fromInt(0),
        },
        .x => .{
            // Mirror across horizontal axis: flip Y, keep X.
            .x1 = seg.x1,
            .y1 = 2.0 * val - seg.y1,
            .x2 = seg.x2,
            .y2 = 2.0 * val - seg.y2,
            .net = NetIdx.fromInt(0),
        },
    };
}

/// Build a Steiner tree for a single net (used for matched groups with 3+ nets).
pub fn buildSingleTree(
    allocator: std.mem.Allocator,
    pins: []const [2]f32,
    net: NetIdx,
) ![]Segment {
    if (pins.len == 0) return &.{};
    if (pins.len == 1) return &.{};

    var tree = try SteinerTree.build(allocator, pins);
    defer tree.deinit();

    const segs = try allocator.alloc(Segment, tree.segments.items.len);
    for (tree.segments.items, 0..) |seg, i| {
        segs[i] = .{ .x1 = seg.x1, .y1 = seg.y1, .x2 = seg.x2, .y2 = seg.y2, .net = net };
    }
    return segs;
}

// ─── Helpers for matched router ──────────────────────────────────────────────

/// Total Manhattan length of a slice of segments.
pub fn totalLength(segs: []const Segment) f32 {
    var total: f32 = 0.0;
    for (segs) |s| total += s.length();
    return total;
}

/// Sum of segment lengths for a specific net from a mixed segment list.
pub fn netTotalLength(segs: []const Segment, net: NetIdx) f32 {
    var total: f32 = 0.0;
    for (segs) |s| {
        if (s.net.toInt() == net.toInt()) total += s.length();
    }
    return total;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "symmetric Steiner tree mirrors correctly — 2 pins" {
    // Two differential pins separated in X: pins at y=0 vs pins at y=10
    // Centroid separation dx=10, dy=0 → axis = .y at x=5
    var result = try buildSymmetric(
        std.testing.allocator,
        &.{ .{ 0.0, 0.0 }, .{ 1.0, 0.0 } },
        &.{ .{ 10.0, 0.0 }, .{ 11.0, 0.0 } },
        NetIdx.fromInt(0),
        NetIdx.fromInt(1),
    );
    defer result.deinit();

    try std.testing.expectEqual(SymmetryAxis.y, result.axis);
    // Axis should be at x=5.5 (centroid of (0.5+10.5)/2)
    try std.testing.expectApproxEqAbs(@as(f32, 5.5), result.axis_value, 1e-6);

    // Both trees should have the same number of segments.
    try std.testing.expectEqual(result.segments_ref.len, result.segments_mirror.len);

    // Total length should be equal for both trees.
    const len_ref = totalLength(result.segments_ref);
    const len_mir = totalLength(result.segments_mirror);
    try std.testing.expectApproxEqAbs(len_ref, len_mir, 1e-6);
}

test "symmetric Steiner tree horizontal axis" {
    // Pins separated in Y: (0,0) vs (0,10) → axis = .x at y=5
    var result = try buildSymmetric(
        std.testing.allocator,
        &.{ .{ 0.0, 0.0 }, .{ 1.0, 0.0 } },
        &.{ .{ 0.0, 10.0 }, .{ 1.0, 10.0 } },
        NetIdx.fromInt(0),
        NetIdx.fromInt(1),
    );
    defer result.deinit();

    try std.testing.expectEqual(SymmetryAxis.x, result.axis);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), result.axis_value, 1e-6);
}

test "symmetric Steiner tree both empty" {
    var result = try buildSymmetric(
        std.testing.allocator,
        &.{},
        &.{},
        NetIdx.fromInt(0),
        NetIdx.fromInt(1),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.segments_ref.len);
    try std.testing.expectEqual(@as(usize, 0), result.segments_mirror.len);
}

test "symmetric Steiner tree single pin each side" {
    var result = try buildSymmetric(
        std.testing.allocator,
        &.{.{ 0.0, 0.0 }},
        &.{.{ 10.0, 0.0 }},
        NetIdx.fromInt(0),
        NetIdx.fromInt(1),
    );
    defer result.deinit();

    // Steiner tree with 1 pin produces 0 segments.
    try std.testing.expectEqual(@as(usize, 0), result.segments_ref.len);
    try std.testing.expectEqual(@as(usize, 0), result.segments_mirror.len);
}

test "symmetric Steiner tree length equality — 4-pin group" {
    var result = try buildSymmetric(
        std.testing.allocator,
        &.{ .{ 0.0, 0.0 }, .{ 0.0, 5.0 }, .{ 5.0, 0.0 }, .{ 5.0, 5.0 } },
        &.{ .{ 20.0, 0.0 }, .{ 20.0, 5.0 }, .{ 25.0, 0.0 }, .{ 25.0, 5.0 } },
        NetIdx.fromInt(0),
        NetIdx.fromInt(1),
    );
    defer result.deinit();

    const len_ref = totalLength(result.segments_ref);
    const len_mir = totalLength(result.segments_mirror);
    try std.testing.expectApproxEqAbs(len_ref, len_mir, 1e-3);
}

test "buildSingleTree basic" {
    const pins = &.{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 }, .{ 10.0, 10.0 } };
    const net = NetIdx.fromInt(5);
    const segs = try buildSingleTree(std.testing.allocator, pins, net);
    defer std.testing.allocator.free(segs);

    try std.testing.expect(segs.len > 0);
    for (segs) |s| try std.testing.expectEqual(net, s.net);
}

test "buildSingleTree single pin" {
    const segs = try buildSingleTree(std.testing.allocator, &.{.{ 0.0, 0.0 }}, NetIdx.fromInt(0));
    defer std.testing.allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 0), segs.len);
}

test "buildSingleTree empty pins" {
    const segs = try buildSingleTree(std.testing.allocator, &.{}, NetIdx.fromInt(0));
    defer std.testing.allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 0), segs.len);
}

test "segment length" {
    const s = Segment{ .x1 = 0.0, .y1 = 0.0, .x2 = 3.0, .y2 = 4.0, .net = NetIdx.fromInt(0) };
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), s.length(), 1e-6);
}

test "netTotalLength filters by net" {
    const segs = &[_]Segment{
        .{ .x1 = 0.0, .y1 = 0.0, .x2 = 3.0, .y2 = 0.0, .net = NetIdx.fromInt(0) },
        .{ .x1 = 3.0, .y1 = 0.0, .x2 = 3.0, .y2 = 4.0, .net = NetIdx.fromInt(1) },
        .{ .x1 = 3.0, .y1 = 4.0, .x2 = 0.0, .y2 = 4.0, .net = NetIdx.fromInt(0) },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), netTotalLength(segs, NetIdx.fromInt(0)), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), netTotalLength(segs, NetIdx.fromInt(1)), 1e-6);
}
