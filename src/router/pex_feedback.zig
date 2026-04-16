// router/pex_feedback.zig
//
// PEX Feedback Loop for analog matching.
//
// Iterative flow: route -> extract -> compute MatchReport -> repair if needed -> re-route.
// Max 5 iterations.  Repairs: width (R), layer (C), jogs (length), dummy vias (via count),
// layer rebalance (coupling).
//
// Reference: GUIDE_01_IMPLEMENTATION_PLAN.md Phase 9
//            GUIDE_04_TESTING_STRATEGY.md Section 9

const std = @import("std");
const types = @import("../core/types.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");
const characterize_types = @import("../characterize/types.zig");
const pex_mod = @import("../characterize/pex.zig");

const NetIdx = types.NetIdx;
const RouteArrays = route_arrays_mod.RouteArrays;
pub const PexConfig = characterize_types.PexConfig;
const PexResult = characterize_types.PexResult;
const RcElement = characterize_types.RcElement;

// ─── Index types ────────────────────────────────────────────────────────────

pub const AnalogGroupIdx = enum(u32) {
    _,
    pub inline fn toInt(self: AnalogGroupIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) AnalogGroupIdx { return @enumFromInt(v); }
};

pub const AnalogGroupType = enum(u8) {
    differential = 0,
    matched = 1,
    shielded = 2,
    kelvin = 3,
    resistor = 4,
    capacitor = 5,
};

/// Per-net extraction result.  One entry per net.
pub const NetResult = struct {
    net_id:    u32,
    total_r:   f32,   // Ohm -- sum of all R elements on this net
    total_c:   f32,   // fF -- sum of all C elements to substrate
    via_count: u32,
    seg_count: u32,
    length:    f32,   // um -- total wire length
};

/// Per-group match report.  One entry per matched group (differential, matched, etc.).
pub const MatchReport = struct {
    group_idx:        AnalogGroupIdx,
    passes:           bool,
    r_ratio:         f32,    // |R_a - R_b| / max(R_a, R_b)
    c_ratio:         f32,    // |C_a - C_b| / max(C_a, C_b)
    length_ratio:     f32,    // |L_a - L_b| / max(L_a, L_b)
    via_delta:        i32,    // via_count_a - via_count_b (signed)
    coupling_delta:  f32,    // fF -- coupling cap difference between nets
    tolerance:        f32,   // from group spec
    failure_reason:  FailureReason = .none,
};

pub const FailureReason = enum(u8) {
    none = 0,
    r_mismatch = 1,
    c_mismatch = 2,
    length_mismatch = 3,
    via_mismatch = 4,
    coupling_mismatch = 5,
    unroutable = 6,
};

/// MatchReportDB -- SoA storage for per-group reports.
pub const MatchReportDB = struct {
    group_idx:        std.ArrayListUnmanaged(AnalogGroupIdx),
    passes:           std.ArrayListUnmanaged(bool),
    r_ratio:         std.ArrayListUnmanaged(f32),
    c_ratio:         std.ArrayListUnmanaged(f32),
    length_ratio:     std.ArrayListUnmanaged(f32),
    via_delta:        std.ArrayListUnmanaged(i32),
    coupling_delta:  std.ArrayListUnmanaged(f32),
    failure_reason:  std.ArrayListUnmanaged(u8),
    allocator:        std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MatchReportDB {
        return .{
            .group_idx        = .{},
            .passes           = .{},
            .r_ratio          = .{},
            .c_ratio          = .{},
            .length_ratio      = .{},
            .via_delta        = .{},
            .coupling_delta   = .{},
            .failure_reason   = .{},
            .allocator        = allocator,
        };
    }

    pub fn deinit(self: *MatchReportDB) void {
        self.group_idx.deinit(self.allocator);
        self.passes.deinit(self.allocator);
        self.r_ratio.deinit(self.allocator);
        self.c_ratio.deinit(self.allocator);
        self.length_ratio.deinit(self.allocator);
        self.via_delta.deinit(self.allocator);
        self.coupling_delta.deinit(self.allocator);
        self.failure_reason.deinit(self.allocator);
    }

    pub fn append(self: *MatchReportDB, report: MatchReport) !void {
        try self.group_idx.append(self.allocator, report.group_idx);
        try self.passes.append(self.allocator, report.passes);
        try self.r_ratio.append(self.allocator, report.r_ratio);
        try self.c_ratio.append(self.allocator, report.c_ratio);
        try self.length_ratio.append(self.allocator, report.length_ratio);
        try self.via_delta.append(self.allocator, report.via_delta);
        try self.coupling_delta.append(self.allocator, report.coupling_delta);
        try self.failure_reason.append(self.allocator, @intFromEnum(report.failure_reason));
    }

    pub fn len(self: *const MatchReportDB) u32 {
        return @intCast(self.group_idx.items.len);
    }
};

/// PEX feedback loop result.
pub const PexFeedbackResult = struct {
    reports:          MatchReportDB,
    iterations:      u8,
    pass:            bool,
    allocator:       std.mem.Allocator,

    pub fn deinit(self: *PexFeedbackResult) void {
        self.reports.deinit();
    }
};

/// Repair action determined by analyzeMismatch.
pub const RepairAction = enum(u8) {
    adjust_widths = 0,
    adjust_layers = 1,
    add_jogs = 2,
    add_dummy_vias = 3,
    rebalance_layer = 4,
};

// ─── Geometry helpers (mirrored from pex.zig) ────────────────────────────────

fn segmentLength(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return @sqrt(dx * dx + dy * dy);
}

// ─── extractNet ────────────────────────────────────────────────────────────

/// Extract parasitics for a single net from a RouteArrays.
/// Returns a NetResult with total R, C, via count, segment count, and length.
pub fn extractNet(
    routes:    *const RouteArrays,
    net:       NetIdx,
    pex_cfg:   PexConfig,
    allocator: std.mem.Allocator,
) !NetResult {
    // Filter routes to this net and build a temporary RouteArrays
    var filtered = try RouteArrays.init(allocator, 0);
    defer filtered.deinit();

    for (0..routes.len) |i| {
        if (routes.net[i].toInt() == net.toInt()) {
            try filtered.append(
                routes.layer[i],
                routes.x1[i],
                routes.y1[i],
                routes.x2[i],
                routes.y2[i],
                routes.width[i],
                routes.net[i],
            );
        }
    }

    // Run full extraction on filtered routes
    var pex_result = try pex_mod.extractFromRoutes(&filtered, pex_cfg, allocator);
    defer pex_result.deinit();

    var total_r: f32 = 0.0;
    var total_c: f32 = 0.0;
    var via_count: u32 = 0;
    var length: f32 = 0.0;

    for (pex_result.resistors) |r| {
        if (r.net_a == r.net_b) total_r += r.value;
    }

    for (pex_result.capacitors) |c| {
        if (c.net_b == characterize_types.SUBSTRATE_NET) total_c += c.value;
    }

    // Count via segments (zero-length segments on via layer)
    for (0..filtered.len) |i| {
        if (filtered.net[i].toInt() == net.toInt()) {
            if (filtered.x1[i] == filtered.x2[i] and filtered.y1[i] == filtered.y2[i]) {
                via_count += 1;
            } else {
                length += segmentLength(filtered.x1[i], filtered.y1[i], filtered.x2[i], filtered.y2[i]);
            }
        }
    }

    return NetResult{
        .net_id = net.toInt(),
        .total_r = total_r,
        .total_c = total_c,
        .via_count = via_count,
        .seg_count = filtered.len,
        .length = length,
    };
}

// ─── computeMatchReport ─────────────────────────────────────────────────────

/// Compute a MatchReport for a 2-net matched group (e.g., differential pair).
/// Ratios are computed as |diff| / max, so 0.0 = perfect match, 1.0 = worst.
/// `passes` is true when all metrics are within `tolerance`.
pub fn computeMatchReport(
    group_idx:   AnalogGroupIdx,
    net_a:       NetResult,
    net_b:       NetResult,
    tolerance:   f32,
) MatchReport {
    const max_r = @max(net_a.total_r, net_b.total_r);
    const max_c = @max(net_a.total_c, net_b.total_c);
    const max_l = @max(net_a.length, net_b.length);

    const r_ratio = if (max_r > 0.0) @abs(net_a.total_r - net_b.total_r) / max_r else 0.0;
    const c_ratio = if (max_c > 0.0) @abs(net_a.total_c - net_b.total_c) / max_c else 0.0;
    const length_ratio = if (max_l > 0.0) @abs(net_a.length - net_b.length) / max_l else 0.0;
    const via_delta = @as(i32, @intCast(net_a.via_count)) - @as(i32, @intCast(net_b.via_count));
    const coupling_delta = @abs(net_a.total_c - net_b.total_c); // simplified: use C difference as proxy

    var passes = true;
    var failure_reason: FailureReason = .none;

    if (r_ratio > tolerance) { passes = false; failure_reason = .r_mismatch; }
    if (c_ratio > tolerance) { passes = false; failure_reason = .c_mismatch; }
    if (length_ratio > tolerance) { passes = false; failure_reason = .length_mismatch; }
    if (@abs(via_delta) > 1) { passes = false; failure_reason = .via_mismatch; }
    if (coupling_delta > 0.5) { passes = false; failure_reason = .coupling_mismatch; } // 0.5 fF threshold

    return MatchReport{
        .group_idx = group_idx,
        .passes = passes,
        .r_ratio = r_ratio,
        .c_ratio = c_ratio,
        .length_ratio = length_ratio,
        .via_delta = via_delta,
        .coupling_delta = coupling_delta,
        .tolerance = tolerance,
        .failure_reason = failure_reason,
    };
}

// ─── Repair helpers ─────────────────────────────────────────────────────────

/// Adjust wire widths in routes for a given group to reduce R mismatch.
/// Widen the higher-R net's wires to reduce its resistance.
fn repairWidths(
    routes:        *RouteArrays,
    net_a_id:      u32,
    net_b_id:      u32,
    r_ratio:       f32,
    tolerance:     f32,
    pex_cfg:       PexConfig,
) void {
    if (r_ratio <= tolerance) return;

    // Sum R per net using PexConfig sheet resistance.
    // PexConfig.sheet_resistance is indexed directly by route layer:
    //   index 0 = LI, 1 = M1, 2 = M2, etc.
    var r_a: f32 = 0.0;
    var r_b: f32 = 0.0;
    for (0..routes.len) |i| {
        const nid = routes.net[i].toInt();
        const seg_len = segmentLength(routes.x1[i], routes.y1[i], routes.x2[i], routes.y2[i]);
        if (seg_len < 1e-9) continue;
        const w = routes.width[i];
        const layer_val = routes.layer[i];
        const pex_idx: usize = if (layer_val < 8) layer_val else 7;
        const sheet_r = pex_cfg.sheet_resistance[pex_idx];
        if (sheet_r <= 0.0) continue;
        const seg_r = sheet_r * seg_len / w;
        if (nid == net_a_id) r_a += seg_r;
        if (nid == net_b_id) r_b += seg_r;
    }

    // Widen the higher-R net to reduce its resistance
    const wider_id: u32 = if (r_a > r_b) net_a_id else net_b_id;
    const narrower_r = @min(r_a, r_b);
    const wider_r = @max(r_a, r_b);
    if (wider_r < 1e-9 or narrower_r < 1e-9) return;

    const scale = wider_r / narrower_r; // ratio by which to scale widths
    const target_wider = 1.0 + (scale - 1.0) * 0.5; // partial correction (50%)

    for (0..routes.len) |i| {
        if (routes.net[i].toInt() == wider_id) {
            routes.width[i] *= target_wider;
        }
    }
}

/// Add jogs to segments of the shorter net to balance length.
/// Appends a perpendicular jog segment at the midpoint of the shorter net.
fn repairLength(
    routes:      *RouteArrays,
    net_a_id:    u32,
    net_b_id:    u32,
    length_a:    f32,
    length_b:    f32,
    tolerance:   f32,
) void {
    const max_l = @max(length_a, length_b);
    if (max_l < 1e-6) return;
    const ratio = @abs(length_a - length_b) / max_l;
    if (ratio <= tolerance) return;

    const shorter_id: u32 = if (length_a < length_b) net_a_id else net_b_id;
    const longer_len = @max(length_a, length_b);
    const shorter_len = @min(length_a, length_b);
    const deficit = longer_len - shorter_len;

    if (deficit < 0.5) return; // jog must be >= 0.5 um

    // Find middle segment of shorter net and insert a perpendicular jog
    var mid_seg: usize = 0;
    var accum: f32 = 0.0;
    var found = false;
    for (0..routes.len) |i| {
        if (routes.net[i].toInt() != shorter_id) continue;
        accum += segmentLength(routes.x1[i], routes.y1[i], routes.x2[i], routes.y2[i]);
        mid_seg = i;
        found = true;
        if (accum >= shorter_len / 2.0) break;
    }

    if (!found) return;

    // Insert jog at mid segment
    const mx = routes.x1[mid_seg];
    const my = routes.y1[mid_seg];
    const l = routes.layer[mid_seg];
    const w = routes.width[mid_seg];

    // Jog goes perpendicular (if seg is horizontal, jog is vertical)
    const is_horiz = @abs(routes.y2[mid_seg] - routes.y1[mid_seg]) < 1e-6;
    const jog_len = @min(deficit / 2.0, 2.0);
    if (is_horiz) {
        // Add vertical jog
        routes.append(l, mx, my, mx, my + jog_len, w, NetIdx.fromInt(shorter_id)) catch return;
    } else {
        // Add horizontal jog
        routes.append(l, mx, my, mx + jog_len, my, w, NetIdx.fromInt(shorter_id)) catch return;
    }
}

/// Add dummy vias to the net with fewer vias to balance via count.
fn repairVias(
    routes:      *RouteArrays,
    net_a_id:    u32,
    net_b_id:    u32,
    via_a:       u32,
    via_b:       u32,
) void {
    const delta = @as(i32, @intCast(via_a)) - @as(i32, @intCast(via_b));
    if (@abs(delta) <= 1) return;

    // The net with fewer vias needs dummy vias added
    const fewer_id: u32 = if (via_a < via_b) net_a_id else net_b_id;
    const needed: u32 = @intCast(@abs(delta) - 1);

    // Find non-via segments of the fewer-via net and insert dummy vias at midpoints
    var count: u32 = 0;
    for (0..routes.len) |i| {
        if (routes.net[i].toInt() != fewer_id) continue;
        if (routes.x1[i] == routes.x2[i] and routes.y1[i] == routes.y2[i]) continue; // skip existing vias
        if (count >= needed) break;
        // Insert via at midpoint of segment
        const mx = (routes.x1[i] + routes.x2[i]) / 2.0;
        const my = (routes.y1[i] + routes.y2[i]) / 2.0;
        const l = routes.layer[i];
        const w = routes.width[i];
        // Use same layer for via (self-via / dummy via)
        routes.append(l, mx, my, mx, my, w, NetIdx.fromInt(fewer_id)) catch return;
        count += 1;
    }
}

/// Rebalance layer assignment to reduce coupling -- move high-coupling net to upper metal.
fn repairCoupling(
    routes:       *RouteArrays,
    net_a_id:     u32,
    net_b_id:     u32,
    coupling:     f32,
) void {
    if (coupling < 0.5) return; // 0.5 fF threshold

    // Move the lower layer net to the next metal up to reduce coupling
    var lower_layer: u8 = 255;
    var lower_net_id: u32 = 0;

    for (0..routes.len) |i| {
        if (routes.net[i].toInt() != net_a_id and routes.net[i].toInt() != net_b_id) continue;
        if (routes.layer[i] < lower_layer) {
            lower_layer = routes.layer[i];
            lower_net_id = routes.net[i].toInt();
        }
    }

    if (lower_layer < 2 or lower_layer >= 6) return; // can only go up from M2
    const new_layer = lower_layer + 1;

    for (0..routes.len) |i| {
        if (routes.net[i].toInt() == lower_net_id) {
            routes.layer[i] = new_layer;
        }
    }
}

// ─── repairFromPexReport ───────────────────────────────────────────────────

/// Repair routes for a failing group based on the match report.
/// Dispatches to the appropriate repair helper based on the dominant failure reason.
pub fn repairFromPexReport(
    report:      MatchReport,
    routes:      *RouteArrays,
    net_a_id:    u32,
    net_b_id:    u32,
    length_a:    f32,
    length_b:    f32,
    via_a:       u32,
    via_b:       u32,
    pex_cfg:     ?PexConfig,
) void {
    if (report.failure_reason == .r_mismatch or report.failure_reason == .c_mismatch) {
        if (pex_cfg) |cfg| repairWidths(routes, net_a_id, net_b_id, report.r_ratio, report.tolerance, cfg);
    }
    if (report.failure_reason == .length_mismatch) {
        repairLength(routes, net_a_id, net_b_id, length_a, length_b, report.tolerance);
    }
    if (report.failure_reason == .via_mismatch) {
        repairVias(routes, net_a_id, net_b_id, via_a, via_b);
    }
    if (report.failure_reason == .coupling_mismatch) {
        repairCoupling(routes, net_a_id, net_b_id, report.coupling_delta);
    }
}

// ─── PEX Feedback Loop ──────────────────────────────────────────────────────

/// Maximum number of PEX feedback iterations.
pub const MAX_PEX_ITERATIONS: u8 = 5;

/// PEX feedback loop result type.
pub const PexFeedbackResultLite = struct {
    iterations:  u8,
    pass:        bool,
    reports:     MatchReportDB,
};

/// Run the PEX feedback loop on a set of routes belonging to a 2-net matched group.
///
/// This is a simplified single-group loop that:
///   1. Extracts parasitics for both nets
///   2. Computes match report
///   3. Repairs if needed
///   4. Returns result
///
/// For multi-group designs, the caller manages group iteration order.
pub fn runPexFeedbackLoop(
    routes:     *RouteArrays,
    net_a:      NetIdx,
    net_b:      NetIdx,
    group_idx:  AnalogGroupIdx,
    tolerance:  f32,
    pex_cfg:    PexConfig,
    _:          anytype, // reserved (previously pdk pointer, now unused)
    allocator:  std.mem.Allocator,
) !PexFeedbackResultLite {
    var reports = MatchReportDB.init(allocator);
    errdefer reports.deinit();

    var iter: u8 = 0;
    var pass = false;

    while (iter < MAX_PEX_ITERATIONS) : (iter += 1) {
        // 1. Extract per-net parasitics
        const result_a = try extractNet(routes, net_a, pex_cfg, allocator);
        const result_b = try extractNet(routes, net_b, pex_cfg, allocator);

        // 2. Compute match report
        const report = computeMatchReport(group_idx, result_a, result_b, tolerance);
        try reports.append(report);

        if (report.passes) {
            pass = true;
            break;
        }

        // 3. Repair
        repairFromPexReport(
            report,
            routes,
            net_a.toInt(),
            net_b.toInt(),
            result_a.length,
            result_b.length,
            result_a.via_count,
            result_b.via_count,
            pex_cfg,
        );
    }

    return PexFeedbackResultLite{
        .iterations = iter,
        .pass = pass,
        .reports = reports,
    };
}

/// Determine the best repair action for a failing match report.
/// Returns the action targeting the worst mismatch metric.
pub fn selectRepairAction(
    report: MatchReport,
    group_type: AnalogGroupType,
) RepairAction {
    _ = group_type; // reserved for group-type-specific heuristics

    // Rank failures by severity: coupling > via > R > C > length
    if (report.failure_reason == .coupling_mismatch) return .rebalance_layer;
    if (report.failure_reason == .via_mismatch) return .add_dummy_vias;
    if (report.failure_reason == .r_mismatch) return .adjust_widths;
    if (report.failure_reason == .c_mismatch) return .adjust_layers;
    if (report.failure_reason == .length_mismatch) return .add_jogs;

    // Fallback: pick action based on which ratio is worst
    const worst = @max(report.r_ratio, @max(report.c_ratio, report.length_ratio));
    if (worst == report.r_ratio) return .adjust_widths;
    if (worst == report.c_ratio) return .adjust_layers;
    if (worst == report.length_ratio) return .add_jogs;
    if (@abs(report.via_delta) > 0) return .add_dummy_vias;
    return .rebalance_layer;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "NetResult stores extraction results" {
    const result = NetResult{
        .net_id = 42,
        .total_r = 100.0,
        .total_c = 5.0,
        .via_count = 3,
        .seg_count = 7,
        .length = 50.0,
    };
    try std.testing.expectEqual(@as(u32, 42), result.net_id);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), result.total_r, 1e-3);
    try std.testing.expectEqual(@as(u32, 3), result.via_count);
}

test "MatchReport passes when within tolerance" {
    const net_a = NetResult{ .net_id = 0, .total_r = 100.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 101.0, .total_c = 5.1, .via_count = 3, .seg_count = 7, .length = 50.5 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);
    try std.testing.expect(report.passes);
    try std.testing.expect(report.r_ratio < 0.05);
}

test "MatchReport fails when R mismatch exceeds tolerance" {
    const net_a = NetResult{ .net_id = 0, .total_r = 100.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 120.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);
    try std.testing.expect(!report.passes);
    try std.testing.expect(report.r_ratio > 0.05);
    try std.testing.expectEqual(FailureReason.r_mismatch, report.failure_reason);
}

test "MatchReport fails on via mismatch" {
    const net_a = NetResult{ .net_id = 0, .total_r = 100.0, .total_c = 5.0, .via_count = 5, .seg_count = 7, .length = 50.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 100.0, .total_c = 5.0, .via_count = 2, .seg_count = 7, .length = 50.0 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);
    try std.testing.expect(!report.passes);
    try std.testing.expectEqual(@as(i32, 3), report.via_delta);
}

test "MatchReport fails on C mismatch" {
    const net_a = NetResult{ .net_id = 0, .total_r = 100.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 100.0, .total_c = 8.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);
    try std.testing.expect(!report.passes);
    try std.testing.expect(report.c_ratio > 0.05);
}

test "MatchReport fails on length mismatch" {
    const net_a = NetResult{ .net_id = 0, .total_r = 100.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 100.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 80.0 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);
    try std.testing.expect(!report.passes);
    try std.testing.expect(report.length_ratio > 0.05);
}

test "MatchReport with zero values does not divide by zero" {
    const net_a = NetResult{ .net_id = 0, .total_r = 0.0, .total_c = 0.0, .via_count = 0, .seg_count = 0, .length = 0.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 0.0, .total_c = 0.0, .via_count = 0, .seg_count = 0, .length = 0.0 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);
    try std.testing.expect(report.passes);
    try std.testing.expectEqual(@as(f32, 0.0), report.r_ratio);
    try std.testing.expectEqual(@as(f32, 0.0), report.c_ratio);
    try std.testing.expectEqual(@as(f32, 0.0), report.length_ratio);
}

test "MatchReportDB init and append" {
    var db = MatchReportDB.init(std.testing.allocator);
    defer db.deinit();

    const net_a = NetResult{ .net_id = 0, .total_r = 100.0, .total_c = 5.0, .via_count = 3, .seg_count = 7, .length = 50.0 };
    const net_b = NetResult{ .net_id = 1, .total_r = 101.0, .total_c = 5.1, .via_count = 3, .seg_count = 7, .length = 50.5 };
    const report = computeMatchReport(AnalogGroupIdx.fromInt(0), net_a, net_b, 0.05);

    try db.append(report);
    try std.testing.expectEqual(@as(u32, 1), db.len());
    try std.testing.expect(db.passes.items[0]);
}

test "selectRepairAction returns correct action for R mismatch" {
    const report = MatchReport{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .passes = false,
        .r_ratio = 0.20,
        .c_ratio = 0.01,
        .length_ratio = 0.01,
        .via_delta = 0,
        .coupling_delta = 0.0,
        .tolerance = 0.05,
        .failure_reason = .r_mismatch,
    };
    try std.testing.expectEqual(RepairAction.adjust_widths, selectRepairAction(report, .differential));
}

test "selectRepairAction returns correct action for C mismatch" {
    const report = MatchReport{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .passes = false,
        .r_ratio = 0.01,
        .c_ratio = 0.20,
        .length_ratio = 0.01,
        .via_delta = 0,
        .coupling_delta = 0.0,
        .tolerance = 0.05,
        .failure_reason = .c_mismatch,
    };
    try std.testing.expectEqual(RepairAction.adjust_layers, selectRepairAction(report, .matched));
}

test "selectRepairAction returns correct action for length mismatch" {
    const report = MatchReport{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .passes = false,
        .r_ratio = 0.01,
        .c_ratio = 0.01,
        .length_ratio = 0.20,
        .via_delta = 0,
        .coupling_delta = 0.0,
        .tolerance = 0.05,
        .failure_reason = .length_mismatch,
    };
    try std.testing.expectEqual(RepairAction.add_jogs, selectRepairAction(report, .differential));
}

test "selectRepairAction returns correct action for via mismatch" {
    const report = MatchReport{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .passes = false,
        .r_ratio = 0.01,
        .c_ratio = 0.01,
        .length_ratio = 0.01,
        .via_delta = 3,
        .coupling_delta = 0.0,
        .tolerance = 0.05,
        .failure_reason = .via_mismatch,
    };
    try std.testing.expectEqual(RepairAction.add_dummy_vias, selectRepairAction(report, .differential));
}

test "selectRepairAction returns rebalance_layer for coupling mismatch" {
    const report = MatchReport{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .passes = false,
        .r_ratio = 0.01,
        .c_ratio = 0.01,
        .length_ratio = 0.01,
        .via_delta = 0,
        .coupling_delta = 1.0,
        .tolerance = 0.05,
        .failure_reason = .coupling_mismatch,
    };
    try std.testing.expectEqual(RepairAction.rebalance_layer, selectRepairAction(report, .differential));
}

test "repairFromPexReport with unroutable is no-op" {
    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    const net_a = NetIdx.fromInt(0);
    const net_b = NetIdx.fromInt(1);
    try routes.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, net_a);
    try routes.append(1, 0.0, 1.0, 10.0, 1.0, 0.14, net_b);

    const report = MatchReport{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .passes = false,
        .r_ratio = 0.0,
        .c_ratio = 0.0,
        .length_ratio = 0.0,
        .via_delta = 0,
        .coupling_delta = 0.0,
        .tolerance = 0.05,
        .failure_reason = .unroutable,
    };

    repairFromPexReport(report, &routes, net_a.toInt(), net_b.toInt(), 10.0, 10.0, 0, 0, null);
    // Routes unchanged -- still 2 segments
    try std.testing.expectEqual(@as(u32, 2), routes.len);
}

test "PEX feedback loop converges for matched pair" {
    // Setup: two nets with nearly equal parasitics -- should converge in 1 iteration
    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    const net_a = NetIdx.fromInt(0);
    const net_b = NetIdx.fromInt(1);

    // Net A: M1 segment
    try routes.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, net_a);
    // Net B: M1 segment (same length)
    try routes.append(1, 0.0, 1.0, 10.0, 1.0, 0.14, net_b);

    var result = try runPexFeedbackLoop(
        &routes,
        net_a,
        net_b,
        AnalogGroupIdx.fromInt(0),
        0.05,
        PexConfig.sky130(),
        null,
        std.testing.allocator,
    );
    defer result.reports.deinit();

    try std.testing.expect(result.pass);
    try std.testing.expect(result.iterations <= MAX_PEX_ITERATIONS);
}
