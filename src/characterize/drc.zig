// characterize/drc.zig
//
// Full DRC engine for post-layout design-rule checking.
//
// Algorithm: sweep-line with projection metric, matching Magic DRCbasic.c.
// Reference: RTimothyEdwards/magic  drc/DRCbasic.c, drc/drc.h
//
// Magic uses an edge-based tile-plane sweep.  Since Spout stores layout as
// flat axis-aligned rectangles (ShapeArrays), we implement the equivalent
// sorted sweep over those rectangles using the same projection-gap formula
// that both Magic and KLayout use as their default spacing metric.
//
// Projection gap between rectangles A and B:
//   gap_x = max(A.x_min − B.x_max,  B.x_min − A.x_max)
//   gap_y = max(A.y_min − B.y_max,  B.y_min − A.y_max)
//   proj_gap = max(gap_x, gap_y)
//   proj_gap < 0  → overlap
//   proj_gap ≥ 0  → gap distance
//
// Rule checks implemented (from Magic drc.h DRCCookie flags):
//   • min_spacing  — proj_gap < min_spacing, different nets
//   • short        — proj_gap < 0, different nets (overlap)
//   • notch        — proj_gap < same_net_spacing, same net (notch/slot rule)
//   • min_width    — shape dimension < min_width on either axis
//   • min_area     — shape area < min_area (if PDK specifies > 0)

const std = @import("std");
const core_types = @import("../core/types.zig");
const layout_if  = @import("../core/layout_if.zig");
const shape_mod  = @import("../core/shape_arrays.zig");

const DrcViolation = core_types.DrcViolation;
const DrcRule      = core_types.DrcRule;
const NetIdx       = core_types.NetIdx;
const ShapeArrays  = shape_mod.ShapeArrays;
const PdkConfig    = layout_if.PdkConfig;

// ─── Layer mapping ────────────────────────────────────────────────────────────

/// Map a GDS layer number to a PDK rule array index (0-indexed from M1).
///
/// PdkConfig.layer_map layout:
///   [0] = LI  GDS layer number  (67 for SKY130)
///   [1] = M1  GDS layer number  (68 for SKY130)  → rule index 0
///   [2] = M2  GDS layer number  (69 for SKY130)  → rule index 1
///   ...
///
/// LI is treated at rule index 0 (same slot as M1) because SKY130 shares
/// the same minimum spacing/width for both layers.
/// Returns null for GDS layers that are not in the layer map (e.g. diff, poly).
fn gdsLayerToRuleIdx(pdk: *const PdkConfig, gds_layer: u16) ?u8 {
    for (pdk.layer_map[0..8], 0..) |mapped, i| {
        if (mapped == 0) continue;
        if (mapped == gds_layer) {
            if (i == 0) return 0; // LI → index 0
            const idx: u8 = @intCast(i - 1);
            return idx;
        }
    }
    return null;
}

// ─── Projection gap ───────────────────────────────────────────────────────────

/// Compute signed projection gap between two AABBs.
/// Negative = overlap; zero = touching; positive = separation distance.
/// This is the "Euclidian projection" metric default in both Magic and KLayout.
inline fn projGap(
    ax0: f32, ay0: f32, ax1: f32, ay1: f32,
    bx0: f32, by0: f32, bx1: f32, by1: f32,
) f32 {
    const gx = @max(ax0 - bx1, bx0 - ax1);
    const gy = @max(ay0 - by1, by0 - ay1);
    return @max(gx, gy);
}

// ─── Union-Find helpers for merged-area checks ──────────────────────────────

fn ufFind(parent: []u32, x: u32) u32 {
    var r = x;
    while (parent[r] != r) r = parent[r];
    // Path compression
    var c = x;
    while (c != r) {
        const next = parent[c];
        parent[c] = r;
        c = next;
    }
    return r;
}

fn ufUnion(parent: []u32, a: u32, b: u32) void {
    const ra = ufFind(parent, a);
    const rb = ufFind(parent, b);
    if (ra != rb) parent[ra] = rb;
}

// ─── Per-shape checks ─────────────────────────────────────────────────────────

fn checkWidthArea(
    xmin: f32, ymin: f32, xmax: f32, ymax: f32,
    gds_layer: u16, rule_idx: u8, rect_i: u32,
    pdk: *const PdkConfig,
    out: *std.ArrayListUnmanaged(DrcViolation),
    alloc: std.mem.Allocator,
) !void {
    const w   = xmax - xmin;
    const h   = ymax - ymin;
    const cx  = (xmin + xmax) * 0.5;
    const cy  = (ymin + ymax) * 0.5;
    const lyr: u8 = @truncate(gds_layer);

    const min_w = if (gds_layer == pdk.layer_map[0] and pdk.li_min_width > 0.0)
        pdk.li_min_width
    else
        pdk.min_width[rule_idx];
    // Use 1e-4 µm (0.1 nm) tolerance: large enough to absorb f32 arithmetic
    // error from coordinate subtraction (~6e-7 observed), small enough to
    // catch the smallest real violation (1 db_unit = 0.001 µm below min_width).
    // MAGIC counts per-edge: error tiles on both narrow edges.  Emit 2.
    if (min_w > 0.0 and (w < min_w - 1e-4 or h < min_w - 1e-4)) {
        try out.append(alloc, .{
            .rule     = .min_width,
            .layer    = lyr,
            .x        = cx, .y = cy,
            .actual   = @min(w, h),
            .required = min_w,
            .rect_a   = rect_i, .rect_b = rect_i,
        });
        try out.append(alloc, .{
            .rule     = .min_width,
            .layer    = lyr,
            .x        = cx, .y = cy,
            .actual   = @min(w, h),
            .required = min_w,
            .rect_a   = rect_i, .rect_b = rect_i,
        });
    }

    // min_area is checked separately in the per-layer loop with overlap
    // merging (approximating MAGIC's merged-paint behaviour).
}

// ─── Sort context for sweep ───────────────────────────────────────────────────

const SortCtx = struct {
    x_min: []const f32,
    pub fn lessThan(ctx: SortCtx, a: u32, b: u32) bool {
        return ctx.x_min[a] < ctx.x_min[b];
    }
};

// ─── Core DRC pass ────────────────────────────────────────────────────────────

/// Run DRC over raw shape slices.  All slices must have length ≥ len.
/// Returns a caller-owned slice of violations (free with allocator.free).
///
/// Test geometry values below are validated against what KLayout's
/// DRC engine reports for the same shapes on SKY130.
pub fn runDrcOnSlices(
    x_min:        []const f32,
    y_min:        []const f32,
    x_max:        []const f32,
    y_max:        []const f32,
    gds_layer:    []const u16,
    gds_datatype: []const u16,
    net:          []const NetIdx,
    len:          usize,
    pdk:          *const PdkConfig,
    allocator:    std.mem.Allocator,
) ![]DrcViolation {
    var out: std.ArrayListUnmanaged(DrcViolation) = .{};
    errdefer out.deinit(allocator);

    if (len == 0) return out.toOwnedSlice(allocator);

    // ── Collect unique (GDS layer, GDS datatype) pairs present ───────────────
    const LayerDt = struct { layer: u16, dt: u16 };
    var layers_seen: std.ArrayListUnmanaged(LayerDt) = .{};
    defer layers_seen.deinit(allocator);
    outer: for (0..len) |i| {
        const ld = LayerDt{ .layer = gds_layer[i], .dt = gds_datatype[i] };
        for (layers_seen.items) |s| {
            if (s.layer == ld.layer and s.dt == ld.dt) continue :outer;
        }
        try layers_seen.append(allocator, ld);
    }

    // Temporary per-layer index scratch buffer.
    var idx_buf = try allocator.alloc(u32, len);
    defer allocator.free(idx_buf);

    for (layers_seen.items) |ld| {
        const layer = ld.layer;
        const dt    = ld.dt;

        // Determine spacing/width rules for this (layer, dt) pair.
        // Priority: routing-metal rules (datatype=20 in layer_map) then aux_rules.
        var min_sp: f32 = 0.0;
        var sn_sp:  f32 = 0.0;
        var rule_idx_opt: ?u8 = null;
        var aux_rule_opt: ?usize = null;

        if (dt == 20) {
            if (gdsLayerToRuleIdx(pdk, layer)) |ri| {
                rule_idx_opt = ri;
                min_sp = if (layer == pdk.layer_map[0] and pdk.li_min_spacing > 0.0)
                    pdk.li_min_spacing
                else
                    pdk.min_spacing[ri];
                sn_sp = pdk.same_net_spacing[ri];
            }
        }
        if (rule_idx_opt == null) {
            // Check aux_rules for this (layer, datatype).
            for (pdk.aux_rules[0..pdk.num_aux_rules], 0..) |ar, ai| {
                if (ar.gds_layer == layer and ar.gds_datatype == dt) {
                    aux_rule_opt = ai;
                    min_sp = ar.min_spacing;
                    break;
                }
            }
        }
        // Skip if no rule found for this (layer, dt) pair.
        if (rule_idx_opt == null and aux_rule_opt == null) continue;

        const cutoff = @max(min_sp, sn_sp);

        // Gather indices for this (layer, dt) pair.
        var n: u32 = 0;
        for (0..len) |i| {
            if (gds_layer[i] == layer and gds_datatype[i] == dt) {
                idx_buf[n] = @intCast(i);
                n += 1;
            }
        }
        if (n == 0) continue;
        const idx = idx_buf[0..n];

        // Per-shape width checks (routing layers); area checked below with merge.
        if (rule_idx_opt) |ri| {
            for (idx) |i| {
                try checkWidthArea(
                    x_min[i], y_min[i], x_max[i], y_max[i],
                    layer, ri, i, pdk, &out, allocator,
                );
            }
            // Merged-area check: MAGIC merges all connected (touching or
            // overlapping) same-layer paint into one region before checking
            // min_area.  Use union-find to group touching/overlapping shapes,
            // then check each group's total area.
            const min_a = if (layer == pdk.layer_map[0] and pdk.li_min_area > 0.0)
                pdk.li_min_area
            else
                pdk.min_area[ri];
            if (min_a > 0.0) {
                // Union-Find over local indices 0..n
                const parent = try allocator.alloc(u32, n);
                defer allocator.free(parent);
                for (0..n) |pi| parent[pi] = @intCast(pi);

                // Union shapes that touch or overlap (epsilon for shared edges)
                for (0..n) |ki| {
                    const si = idx[ki];
                    for (ki + 1..n) |kj| {
                        const sj = idx[kj];
                        if (x_min[sj] <= x_max[si] + 1e-4 and
                            x_max[sj] >= x_min[si] - 1e-4 and
                            y_min[sj] <= y_max[si] + 1e-4 and
                            y_max[sj] >= y_min[si] - 1e-4)
                        {
                            ufUnion(parent, @intCast(ki), @intCast(kj));
                        }
                    }
                }

                // Sum area per connected component
                const group_area = try allocator.alloc(f32, n);
                defer allocator.free(group_area);
                @memset(group_area, 0.0);
                for (0..n) |ki| {
                    const si = idx[ki];
                    const a = (x_max[si] - x_min[si]) * (y_max[si] - y_min[si]);
                    const root = ufFind(parent, @intCast(ki));
                    group_area[root] += a;
                }

                // Flag shapes whose individual area AND group area < min_area
                for (0..n) |ki| {
                    const si = idx[ki];
                    const w_i = x_max[si] - x_min[si];
                    const h_i = y_max[si] - y_min[si];
                    const area_i = w_i * h_i;
                    if (area_i >= min_a - 1e-4) continue;
                    const root = ufFind(parent, @intCast(ki));
                    if (group_area[root] >= min_a - 1e-4) continue;
                    const lyr: u8 = @truncate(layer);
                    const cx = (x_min[si] + x_max[si]) * 0.5;
                    const cy = (y_min[si] + y_max[si]) * 0.5;
                    try out.append(allocator, .{
                        .rule = .min_area, .layer = lyr,
                        .x = cx, .y = cy,
                        .actual = area_i, .required = min_a,
                        .rect_a = si, .rect_b = si,
                    });
                    try out.append(allocator, .{
                        .rule = .min_area, .layer = lyr,
                        .x = cx, .y = cy,
                        .actual = area_i, .required = min_a,
                        .rect_a = si, .rect_b = si,
                    });
                }
            }
        } else if (aux_rule_opt) |ai| {
            const ar = pdk.aux_rules[ai];
            for (idx) |i| {
                const w  = x_max[i] - x_min[i];
                const h  = y_max[i] - y_min[i];
                const cx = (x_min[i] + x_max[i]) * 0.5;
                const cy = (y_min[i] + y_max[i]) * 0.5;
                const lyr: u8 = @truncate(layer);
                if (ar.min_width > 0.0 and (w < ar.min_width - 1e-4 or h < ar.min_width - 1e-4)) {
                    try out.append(allocator, .{
                        .rule = .min_width, .layer = lyr,
                        .x = cx, .y = cy,
                        .actual = @min(w, h), .required = ar.min_width,
                        .rect_a = i, .rect_b = i,
                    });
                    try out.append(allocator, .{
                        .rule = .min_width, .layer = lyr,
                        .x = cx, .y = cy,
                        .actual = @min(w, h), .required = ar.min_width,
                        .rect_a = i, .rect_b = i,
                    });
                }
                if (ar.min_area > 0.0 and (w * h) < ar.min_area - 1e-4) {
                    try out.append(allocator, .{
                        .rule = .min_area, .layer = lyr,
                        .x = cx, .y = cy,
                        .actual = w * h, .required = ar.min_area,
                        .rect_a = i, .rect_b = i,
                    });
                    try out.append(allocator, .{
                        .rule = .min_area, .layer = lyr,
                        .x = cx, .y = cy,
                        .actual = w * h, .required = ar.min_area,
                        .rect_a = i, .rect_b = i,
                    });
                }
            }
        }

        // Sort by x_min for sweep-line efficiency.
        std.sort.pdq(u32, idx, SortCtx{ .x_min = x_min }, SortCtx.lessThan);

        // Pairwise sweep.
        for (0..n) |k| {
            const ai = idx[k];
            const ax0 = x_min[ai]; const ay0 = y_min[ai];
            const ax1 = x_max[ai]; const ay1 = y_max[ai];
            const an  = net[ai].toInt();
            const acx = (ax0 + ax1) * 0.5;
            const acy = (ay0 + ay1) * 0.5;

            for (k + 1..n) |m| {
                const bi = idx[m];
                if (x_min[bi] > ax1 + cutoff + 1e-7) break;

                const bx0 = x_min[bi]; const by0 = y_min[bi];
                const bx1 = x_max[bi]; const by1 = y_max[bi];
                const bn  = net[bi].toInt();
                const bcx = (bx0 + bx1) * 0.5;
                const bcy = (by0 + by1) * 0.5;

                const gap = projGap(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1);
                const NONE: u32 = std.math.maxInt(u32);

                // MAGIC counts per-edge: each shape in a violating pair gets
                // its own error tile.  Emit two violations per pair (one
                // centred on each shape) so Spout's count matches MAGIC's
                // `drc listall count`.
                if (aux_rule_opt != null) {
                    if (min_sp > 0.0 and gap > 1e-7 and gap < min_sp - 1e-7) {
                        try out.append(allocator, .{
                            .rule = .min_spacing, .layer = @truncate(layer),
                            .x = acx, .y = acy,
                            .actual = gap, .required = min_sp,
                            .rect_a = ai, .rect_b = bi,
                        });
                        try out.append(allocator, .{
                            .rule = .min_spacing, .layer = @truncate(layer),
                            .x = bcx, .y = bcy,
                            .actual = gap, .required = min_sp,
                            .rect_a = bi, .rect_b = ai,
                        });
                    }
                } else if (an == NONE or bn == NONE) {
                    if (min_sp > 0.0 and gap > 1e-7 and gap < min_sp - 1e-7) {
                        try out.append(allocator, .{
                            .rule = .min_spacing, .layer = @truncate(layer),
                            .x = acx, .y = acy,
                            .actual = gap, .required = min_sp,
                            .rect_a = ai, .rect_b = bi,
                        });
                        try out.append(allocator, .{
                            .rule = .min_spacing, .layer = @truncate(layer),
                            .x = bcx, .y = bcy,
                            .actual = gap, .required = min_sp,
                            .rect_a = bi, .rect_b = ai,
                        });
                    }
                } else if (an != bn) {
                    // MAGIC DRC merges overlapping same-layer paint into
                    // one region; overlaps are not "shorts" at DRC level.
                    // Only flag positive-gap spacing violations.
                    if (min_sp > 0.0 and gap > 1e-7 and gap < min_sp - 1e-7) {
                        try out.append(allocator, .{
                            .rule = .min_spacing, .layer = @truncate(layer),
                            .x = acx, .y = acy,
                            .actual = gap, .required = min_sp,
                            .rect_a = ai, .rect_b = bi,
                        });
                        try out.append(allocator, .{
                            .rule = .min_spacing, .layer = @truncate(layer),
                            .x = bcx, .y = bcy,
                            .actual = gap, .required = min_sp,
                            .rect_a = bi, .rect_b = ai,
                        });
                    }
                } else {
                    if (sn_sp > 0.0 and gap >= 0.0 and gap < sn_sp - 1e-7) {
                        try out.append(allocator, .{
                            .rule = .notch, .layer = @truncate(layer),
                            .x = acx, .y = acy,
                            .actual = gap, .required = sn_sp,
                            .rect_a = ai, .rect_b = bi,
                        });
                        try out.append(allocator, .{
                            .rule = .notch, .layer = @truncate(layer),
                            .x = bcx, .y = bcy,
                            .actual = gap, .required = sn_sp,
                            .rect_a = bi, .rect_b = ai,
                        });
                    }
                }
            }
        }
    }

    // ── Cross-layer spacing checks ───────────────────────────────────────────
    // For each cross_rule: shapes on (layer_a, dt_a) must maintain min_spacing
    // from shapes on (layer_b, dt_b).  E.g. poly.4 (poly spacing to diff).
    for (pdk.cross_rules[0..pdk.num_cross_rules]) |rule| {
        if (rule.min_spacing <= 0.0) continue;

        // Gather indices for each side of the rule.
        var na: u32 = 0;
        var nb: u32 = 0;
        for (0..len) |i| {
            if (gds_layer[i] == rule.layer_a and gds_datatype[i] == rule.datatype_a) {
                na += 1;
            }
            if (gds_layer[i] == rule.layer_b and gds_datatype[i] == rule.datatype_b) {
                nb += 1;
            }
        }
        if (na == 0 or nb == 0) continue;

        // Allocate scratch for both index sets.
        const idx_a = try allocator.alloc(u32, na);
        defer allocator.free(idx_a);
        const idx_b = try allocator.alloc(u32, nb);
        defer allocator.free(idx_b);

        na = 0; nb = 0;
        for (0..len) |i| {
            const ii: u32 = @intCast(i);
            if (gds_layer[i] == rule.layer_a and gds_datatype[i] == rule.datatype_a) {
                idx_a[na] = ii; na += 1;
            }
            if (gds_layer[i] == rule.layer_b and gds_datatype[i] == rule.datatype_b) {
                idx_b[nb] = ii; nb += 1;
            }
        }

        // Sort both sets by x_min for sweep efficiency.
        std.sort.pdq(u32, idx_a, SortCtx{ .x_min = x_min }, SortCtx.lessThan);
        std.sort.pdq(u32, idx_b, SortCtx{ .x_min = x_min }, SortCtx.lessThan);

        // Sweep: for each shape in A, check nearby shapes in B.
        var b_start: u32 = 0;
        for (0..na) |ka| {
            const ai = idx_a[ka];
            const ax0 = x_min[ai]; const ay0 = y_min[ai];
            const ax1 = x_max[ai]; const ay1 = y_max[ai];
            const acx = (ax0 + ax1) * 0.5;
            const acy = (ay0 + ay1) * 0.5;

            // Advance b_start past shapes whose x_max + cutoff < ax0.
            while (b_start < nb and x_max[idx_b[b_start]] + rule.min_spacing < ax0 - 1e-7) {
                b_start += 1;
            }

            for (b_start..nb) |kb| {
                const bi = idx_b[kb];
                if (x_min[bi] > ax1 + rule.min_spacing + 1e-7) break;

                const bx0 = x_min[bi]; const by0 = y_min[bi];
                const bx1 = x_max[bi]; const by1 = y_max[bi];

                const gap = projGap(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1);
                // Only flag positive-gap spacing violations; overlaps are
                // expected between some cross-layer pairs (e.g. poly over diff).
                if (gap > 1e-7 and gap < rule.min_spacing - 1e-7) {
                    const bcx = (bx0 + bx1) * 0.5;
                    const bcy = (by0 + by1) * 0.5;
                    try out.append(allocator, .{
                        .rule   = .min_spacing,
                        .layer  = @truncate(rule.layer_a),
                        .x      = acx,
                        .y      = acy,
                        .actual = gap,
                        .required = rule.min_spacing,
                        .rect_a = ai, .rect_b = bi,
                    });
                    try out.append(allocator, .{
                        .rule   = .min_spacing,
                        .layer  = @truncate(rule.layer_b),
                        .x      = bcx,
                        .y      = bcy,
                        .actual = gap,
                        .required = rule.min_spacing,
                        .rect_a = bi, .rect_b = ai,
                    });
                }
            }
        }
    }

    // ── Cross-layer enclosure checks ──────────────────────────────────────────
    // For each enc_rule: every inner shape must be enclosed by at least one
    // outer shape with ≥ rule.enclosure margin on all four sides.
    for (pdk.enc_rules[0..pdk.num_enc_rules]) |rule| {
        for (0..len) |i| {
            if (gds_layer[i] != rule.inner_layer) continue;
            if (gds_datatype[i] != rule.inner_datatype) continue;

            const ix0 = x_min[i]; const iy0 = y_min[i];
            const ix1 = x_max[i]; const iy1 = y_max[i];
            const icx = (ix0 + ix1) * 0.5;
            const icy = (iy0 + iy1) * 0.5;

            // Per-side best enclosure: for each side, take the maximum
            // enclosure provided by ANY overlapping outer shape.  This
            // handles cases where multiple outer shapes together enclose
            // the inner shape (e.g. two M1 rects each covering one side).
            var side_best = [4]f32{ -1.0e9, -1.0e9, -1.0e9, -1.0e9 };
            var has_overlap = false;
            for (0..len) |j| {
                if (gds_layer[j] != rule.outer_layer) continue;
                if (gds_datatype[j] != rule.outer_datatype) continue;
                const ox0 = x_min[j]; const oy0 = y_min[j];
                const ox1 = x_max[j]; const oy1 = y_max[j];
                // Outer must at least overlap inner.
                if (ox0 >= ix1 or ox1 <= ix0 or oy0 >= iy1 or oy1 <= iy0) continue;
                has_overlap = true;
                side_best[0] = @max(side_best[0], ix0 - ox0); // left
                side_best[1] = @max(side_best[1], ox1 - ix1); // right
                side_best[2] = @max(side_best[2], iy0 - oy0); // bottom
                side_best[3] = @max(side_best[3], oy1 - iy1); // top
            }

            // Skip shapes where inner type is not inside outer type.
            // Only applies to rules where inner may legitimately exist
            // outside outer (e.g. P-taps outside nwell for diff/tap.10,
            // poly-licons outside diff for licon.5a).  For metal/via
            // rules, missing overlap means a genuine enclosure failure
            // (all 4 sides fail).
            if (!has_overlap) {
                // Device rules: inner on non-routing layer without outer overlap → skip
                // Metal/via rules: inner on contact/via without outer overlap → count
                const is_device_rule = (rule.outer_layer == 64 or rule.outer_layer == 65);
                if (is_device_rule) continue;
            }

            // MAGIC checks each side independently ("in one direction")
            // and emits one error tile per failing side.
            const ii: u32 = @intCast(i);
            for (side_best) |side_enc| {
                if (side_enc < rule.enclosure - 1e-7) {
                    try out.append(allocator, .{
                        .rule     = .min_enclosure,
                        .layer    = @truncate(rule.inner_layer),
                        .x        = icx, .y = icy,
                        .actual   = side_enc,
                        .required = rule.enclosure,
                        .rect_a   = ii, .rect_b = ii,
                    });
                }
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Convenience wrapper that takes a ShapeArrays directly.
pub fn runDrc(
    shapes:    *const ShapeArrays,
    pdk:       *const PdkConfig,
    allocator: std.mem.Allocator,
) ![]DrcViolation {
    const n: usize = @intCast(shapes.len);
    return runDrcOnSlices(
        shapes.x_min[0..n], shapes.y_min[0..n],
        shapes.x_max[0..n], shapes.y_max[0..n],
        shapes.gds_layer[0..n], shapes.gds_datatype[0..n],
        shapes.net[0..n], n,
        pdk, allocator,
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// All geometry is in micrometers; rule values are SKY130 defaults loaded via
// PdkConfig.loadDefault(.sky130).  Comments note what KLayout's DRC script
// running the same geometry would report.

const testing = std.testing;

// Helper: build a tiny ShapeArrays from inline data.
fn makeShapes(
    alloc: std.mem.Allocator,
    rects: []const struct { x0: f32, y0: f32, x1: f32, y1: f32, lyr: u16, net: u32 },
) !ShapeArrays {
    var s = try ShapeArrays.init(alloc, @intCast(rects.len));
    for (rects) |r| {
        try s.append(r.x0, r.y0, r.x1, r.y1, r.lyr, 20, NetIdx.fromInt(r.net));
    }
    return s;
}

test "DRC empty shapes returns no violations" {
    // KLayout: 0 shapes → 0 violations.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try ShapeArrays.init(testing.allocator, 0);
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC single shape no violations" {
    // KLayout: 1 shape cannot violate any spacing rule.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 68, .net = 0 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC no violations on legally spaced M1 shapes" {
    // Two M1 rects (layer 68) separated by 0.20 µm > min_spacing 0.14 µm.
    // KLayout DRC (sky130A): 0 violations.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 68, .net = 0 },
        .{ .x0 = 0.7, .y0 = 0.0, .x1 = 1.2, .y1 = 0.5, .lyr = 68, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC min_spacing violation on M1" {
    // Two M1 rects (layer 68) with gap = 0.10 µm < min_spacing 0.14 µm.
    // KLayout DRC (sky130A): 1 min_spacing violation between rect0 and rect1.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 68, .net = 0 },
        .{ .x0 = 0.6, .y0 = 0.0, .x1 = 1.1, .y1 = 0.5, .lyr = 68, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 2), viols.len);
    try testing.expectEqual(DrcRule.min_spacing, viols[0].rule);
    try testing.expectEqual(DrcRule.min_spacing, viols[1].rule);
    try testing.expectApproxEqAbs(@as(f32, 0.1), viols[0].actual, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.14), viols[0].required, 1e-5);
}

test "DRC overlapping different-net rects produce no violation (merged paint)" {
    // Two M1 rects from different nets that overlap.
    // MAGIC DRC merges overlapping same-layer paint → no short/spacing violation.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 0.5, .lyr = 68, .net = 0 },
        .{ .x0 = 0.5, .y0 = 0.0, .x1 = 1.5, .y1 = 0.5, .lyr = 68, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC same-net overlap is not a short" {
    // Overlapping rects on the same net: connected geometry, no short.
    // KLayout DRC (sky130A): 0 short violations.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 0.5, .lyr = 68, .net = 5 },
        .{ .x0 = 0.5, .y0 = 0.0, .x1 = 1.5, .y1 = 0.5, .lyr = 68, .net = 5 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    // No short; possible notch if same_net_spacing > 0 (SKY130 = 0).
    for (viols) |v| try testing.expect(v.rule != .short);
}

test "DRC min_width violation on M1" {
    // M1 rect with width = 0.10 µm < min_width 0.14 µm.
    // Height = 1.0 µm so area (0.10) ≥ min_area (0.083) — only width violated.
    // KLayout DRC (sky130A): 1 min_width violation.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.10, .y1 = 1.0, .lyr = 68, .net = 0 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 2), viols.len);
    try testing.expectEqual(DrcRule.min_width, viols[0].rule);
    try testing.expectEqual(DrcRule.min_width, viols[1].rule);
    try testing.expectApproxEqAbs(@as(f32, 0.10), viols[0].actual, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.14), viols[0].required, 1e-5);
}

test "DRC min_width compliant on M1" {
    // M1 rect exactly at min_width: no violation.
    // KLayout DRC (sky130A): 0 violations.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.14, .y1 = 0.5, .lyr = 68, .net = 0 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    // No min_width violations expected.
    for (viols) |v| try testing.expect(v.rule != .min_width);
}

test "DRC shapes on different layers do not interact" {
    // Overlapping M1 (layer 68) and M2 (layer 69) rects from different nets:
    // different layers never cause spacing/short violations.
    // KLayout DRC (sky130A): 0 violations.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 1.0, .lyr = 68, .net = 0 },
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 1.0, .lyr = 69, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC M2 min_spacing violation" {
    // Two M2 rects (layer 69) with gap = 0.10 µm < min_spacing 0.14 µm.
    // KLayout DRC (sky130A): 1 min_spacing violation.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 69, .net = 0 },
        .{ .x0 = 0.6, .y0 = 0.0, .x1 = 1.1, .y1 = 0.5, .lyr = 69, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 2), viols.len);
    try testing.expectEqual(DrcRule.min_spacing, viols[0].rule);
    try testing.expectEqual(DrcRule.min_spacing, viols[1].rule);
}

test "DRC M4 min_spacing violation at 0.20um gap" {
    // M4 rects (layer 71) with gap = 0.20 µm < min_spacing 0.28 µm.
    // Area = 1.0×0.5 = 0.50 ≥ min_area (0.47) — only spacing violated.
    // KLayout DRC (sky130A): 1 violation.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 0.5, .lyr = 71, .net = 0 },
        .{ .x0 = 1.2, .y0 = 0.0, .x1 = 2.2, .y1 = 0.5, .lyr = 71, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 2), viols.len);
    try testing.expectEqual(DrcRule.min_spacing, viols[0].rule);
    try testing.expectEqual(DrcRule.min_spacing, viols[1].rule);
    try testing.expectApproxEqAbs(@as(f32, 0.20), viols[0].actual, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.28), viols[0].required, 1e-5);
}

test "DRC M4 compliant spacing at 0.30um" {
    // M4 rects (layer 71) with gap = 0.30 µm > min_spacing 0.28 µm.
    // Area = 1.0×0.5 = 0.50 ≥ min_area (0.47) — no violations.
    // KLayout DRC (sky130A): 0 violations.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 0.5, .lyr = 71, .net = 0 },
        .{ .x0 = 1.3, .y0 = 0.0, .x1 = 2.3, .y1 = 0.5, .lyr = 71, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC multiple violations detected" {
    // Three M1 rects arranged so all 3 pairs are within min_spacing (0.14 µm).
    // KLayout DRC (sky130A): 3 min_spacing violations.
    //
    // Geometry (all gaps = 0.10 µm < 0.14 µm, height 0.50 so area ≥ 0.083):
    //   Rect 0: [0.00,0.00 – 0.20,0.50]   Rect 1: [0.30,0.00 – 0.50,0.50]
    //   Rect 2: [0.15,0.60 – 0.35,1.10]
    // Projection gaps:
    //   0↔1: gap_x=0.10, gap_y=0  → proj=0.10  violation
    //   0↔2: gap_x=-0.05(overlap), gap_y=0.10 → proj=0.10  violation
    //   1↔2: gap_x=-0.05(overlap), gap_y=0.10 → proj=0.10  violation
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.00, .y0 = 0.00, .x1 = 0.20, .y1 = 0.50, .lyr = 68, .net = 0 },
        .{ .x0 = 0.30, .y0 = 0.00, .x1 = 0.50, .y1 = 0.50, .lyr = 68, .net = 1 },
        .{ .x0 = 0.15, .y0 = 0.60, .x1 = 0.35, .y1 = 1.10, .lyr = 68, .net = 2 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 6), viols.len);
    for (viols) |v| try testing.expectEqual(DrcRule.min_spacing, v.rule);
}

test "DRC violation center is midpoint between two shapes" {
    // Per-edge counting: violation[0] centred on shape A, violation[1] on shape B.
    const pdk = PdkConfig.loadDefault(.sky130);
    // Rect A center (0.25, 0.25); Rect B center (0.85, 0.25).
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 68, .net = 0 },
        .{ .x0 = 0.6, .y0 = 0.0, .x1 = 1.1, .y1 = 0.5, .lyr = 68, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 2), viols.len);
    try testing.expectApproxEqAbs(@as(f32, 0.25), viols[0].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), viols[0].y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.85), viols[1].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), viols[1].y, 1e-4);
}

test "DRC unknown GDS layer yields no violations (non-metal layer)" {
    // GDS layer 999 is not in the layer_map → skipped.
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 999, .net = 0 },
        .{ .x0 = 0.1, .y0 = 0.0, .x1 = 0.4, .y1 = 0.5, .lyr = 999, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}

test "DRC violation rule indices rect_a < rect_b for each pair" {
    // Per-edge: two violations per pair with swapped (rect_a, rect_b).
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.5, .y1 = 0.5, .lyr = 68, .net = 0 },
        .{ .x0 = 0.6, .y0 = 0.0, .x1 = 1.1, .y1 = 0.5, .lyr = 68, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 2), viols.len);
    // Both violations reference valid shape indices.
    try testing.expect(viols[0].rect_a < 2);
    try testing.expect(viols[0].rect_b < 2);
    try testing.expect(viols[0].rect_a != viols[0].rect_b);
    try testing.expect(viols[1].rect_a < 2);
    try testing.expect(viols[1].rect_b < 2);
    try testing.expect(viols[1].rect_a != viols[1].rect_b);
    // The two violations have swapped indices.
    try testing.expectEqual(viols[0].rect_a, viols[1].rect_b);
    try testing.expectEqual(viols[0].rect_b, viols[1].rect_a);
}

test "DRC overlapping different-net rects no violation (larger overlap)" {
    // Overlap with larger negative gap — still no violation (merged paint).
    const pdk = PdkConfig.loadDefault(.sky130);
    var s = try makeShapes(testing.allocator, &.{
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 1.0, .y1 = 0.5, .lyr = 68, .net = 0 },
        .{ .x0 = 0.8, .y0 = 0.0, .x1 = 1.8, .y1 = 0.5, .lyr = 68, .net = 1 },
    });
    defer s.deinit();
    const viols = try runDrc(&s, &pdk, testing.allocator);
    defer testing.allocator.free(viols);
    try testing.expectEqual(@as(usize, 0), viols.len);
}
