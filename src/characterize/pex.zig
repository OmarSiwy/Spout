// characterize/pex.zig
//
// Parasitic RC Extraction (PEX) engine.
//
// Algorithm: segment-level analytical extraction from RouteArrays.
// Reference: RTimothyEdwards/magic  extract/ExtBasic.c, extract/ExtCouple.c,
//            extract/extractInt.h (ExtStyle, NodeRegion, EdgeCap structs).
//
// Magic's extraction pipeline:
//   1. Flood-fill regions → NodeRegion per electrical net.
//   2. Trace perimeter → accumulate area cap (areacap) + fringe cap (perimc).
//   3. Find parallel-edge overlaps → sidewall coupling cap (sidecouple).
//   4. Via/contact stacks → via resistance (viaResist / n_cuts).
//   5. Wire segments → sheet resistance (sheetResist * L / W).
//
// Spout works from RouteArrays (flat segment list) instead of tile planes,
// so we implement the equivalent analytical formulas directly:
//
//   R_wire  = sheet_resistance[layer] * length / width          [Ω]
//   C_area  = length * width * substrate_cap[layer]             [aF]
//   C_fringe = 2 * length * fringe_cap[layer]                  [aF] (two long sides)
//   C_couple = overlap_length * sidewall_cap[layer]             [aF] (between wires)
//
// All capacitances are output in femtofarads (fF = aF / 1000) to match the
// convention used by Magic's ext2spice output.

const std    = @import("std");
const types  = @import("types.zig");
const route_mod = @import("../core/route_arrays.zig");

const PexConfig  = types.PexConfig;
const PexResult  = types.PexResult;
const RcElement  = types.RcElement;
pub const SUBSTRATE_NET = types.SUBSTRATE_NET;

const RouteArrays = route_mod.RouteArrays;

// ─── Layer index mapping ──────────────────────────────────────────────────────
//
// RouteArrays.layer convention (from route_arrays.zig):
//   0 = LI (local interconnect) → PexConfig index 0
//   1 = M1 → PexConfig index 1
//   2 = M2 → PexConfig index 2
//   …
// PexConfig now carries distinct LI coefficients at index 0.

inline fn routeLayerToPexIdx(route_layer: u8) u8 {
    return if (route_layer < 8) route_layer else 7;
}

// ─── Geometry helpers ─────────────────────────────────────────────────────────

/// Euclidean length of a route segment.
inline fn segmentLength(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return @sqrt(dx * dx + dy * dy);
}

/// Signed overlap length along an axis between two 1-D intervals [a0,a1] and [b0,b1].
/// Returns 0 if intervals are disjoint.
inline fn overlapLen(a0: f32, a1: f32, b0: f32, b1: f32) f32 {
    const lo = @max(a0, b0);
    const hi = @min(a1, b1);
    return @max(0.0, hi - lo);
}

// ─── Union-find for net short detection ─────────────────────────────────────
//
// Magic merges physically overlapping tile regions into a single electrical
// node before extraction.  Spout's RouteArrays may carry different net labels
// on segments that physically overlap (routing shorts).  Detect these shorts
// with a union-find so the extraction operates on the same merged-net view.

fn ufFind(parent: *std.AutoHashMap(u32, u32), x: u32) u32 {
    var curr = x;
    while (true) {
        const p = parent.get(curr) orelse return curr;
        if (p == curr) return curr;
        const gp = parent.get(p) orelse return p;
        parent.put(curr, gp) catch {};
        curr = p;
    }
}

fn ufUnion(parent: *std.AutoHashMap(u32, u32), a_id: u32, b_id: u32) void {
    const ra = ufFind(parent, a_id);
    const rb = ufFind(parent, b_id);
    if (ra == rb) return;
    // Smaller ID becomes root for determinism.
    if (ra < rb) {
        parent.put(rb, ra) catch {};
    } else {
        parent.put(ra, rb) catch {};
    }
}

/// Wire bounding box: [left, right, bottom, top], expanded by width.
fn wireRect(x1: f32, y1: f32, x2: f32, y2: f32, w: f32) [4]f32 {
    const is_vert = @abs(x2 - x1) < 1e-6;
    const is_horiz = @abs(y2 - y1) < 1e-6;
    var left = @min(x1, x2);
    var right = @max(x1, x2);
    var bottom = @min(y1, y2);
    var top = @max(y1, y2);
    if (is_vert or left == right) { left -= w / 2.0; right += w / 2.0; }
    if (is_horiz or bottom == top) { bottom -= w / 2.0; top += w / 2.0; }
    return .{ left, right, bottom, top };
}

// ─── Main extraction ──────────────────────────────────────────────────────────

/// Extract parasitic R and C from a RouteArrays using the analytical Magic model.
/// Returns a PexResult; caller must call pex_result.deinit() when done.
///
/// Resistance:  one R element per segment, modelling wire resistance.
/// Capacitance: one area+fringe C element per net (sum over all segments on that net),
///              plus one coupling C per unique net-pair (sum of all sidewall C between
///              those two nets). Matches Magic ext2spice lumped-element convention.
pub fn extractFromRoutes(
    routes:    *const RouteArrays,
    pex_cfg:   PexConfig,
    allocator: std.mem.Allocator,
) !PexResult {
    const n: usize = @intCast(routes.len);

    // ── Detect shorted nets ─────────────────────────────────────────────────
    var uf_parent = std.AutoHashMap(u32, u32).init(allocator);
    defer uf_parent.deinit();
    for (0..n) |i| {
        const net_id = routes.net[i].toInt();
        uf_parent.put(net_id, net_id) catch {};
    }

    // Same-layer wire rectangle overlaps → shorted nets.
    for (0..n) |i| {
        const ri = wireRect(routes.x1[i], routes.y1[i], routes.x2[i], routes.y2[i], routes.width[i]);
        for (i + 1..n) |j| {
            if (routes.layer[j] != routes.layer[i]) continue;
            if (ufFind(&uf_parent, routes.net[i].toInt()) == ufFind(&uf_parent, routes.net[j].toInt())) continue;
            const rj = wireRect(routes.x1[j], routes.y1[j], routes.x2[j], routes.y2[j], routes.width[j]);
            if (ri[1] > rj[0] and rj[1] > ri[0] and ri[3] > rj[2] and rj[3] > ri[2]) {
                ufUnion(&uf_parent, routes.net[i].toInt(), routes.net[j].toInt());
            }
        }
    }

    // Cross-layer via-point shorts: adjacent-layer endpoints matching different nets.
    for (0..n) |i| {
        const li = routes.layer[i];
        const eps_x = [2]f32{ routes.x1[i], routes.x2[i] };
        const eps_y = [2]f32{ routes.y1[i], routes.y2[i] };
        for (0..2) |ei| {
            for (0..n) |j| {
                if (j == i) continue;
                const diff_l: i16 = @as(i16, @intCast(li)) - @as(i16, @intCast(routes.layer[j]));
                if (diff_l != 1 and diff_l != -1) continue;
                if (ufFind(&uf_parent, routes.net[i].toInt()) == ufFind(&uf_parent, routes.net[j].toInt())) continue;
                const mx = (@abs(routes.x1[j] - eps_x[ei]) < 1e-6 and @abs(routes.y1[j] - eps_y[ei]) < 1e-6) or
                    (@abs(routes.x2[j] - eps_x[ei]) < 1e-6 and @abs(routes.y2[j] - eps_y[ei]) < 1e-6);
                if (mx) ufUnion(&uf_parent, routes.net[i].toInt(), routes.net[j].toInt());
            }
        }
    }

    // Per-segment merged-net lookup.
    var net_map = try allocator.alloc(u32, n);
    defer allocator.free(net_map);
    for (0..n) |i| {
        net_map[i] = ufFind(&uf_parent, routes.net[i].toInt());
    }

    // If a merged group contains ≥3 distinct original nets it is almost
    // certainly the substrate (VDD/VSS/shorted-internals).  Remap those
    // segments to SUBSTRATE_NET so caps involving them get merged into
    // signal-net substrate caps — matching Magic's substrate-absorption.
    {
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();
        var root_sizes = std.AutoHashMap(u32, u16).init(allocator);
        defer root_sizes.deinit();
        for (0..n) |i| {
            const orig = routes.net[i].toInt();
            const root = net_map[i];
            const key: u64 = (@as(u64, root) << 32) | orig;
            if ((seen.getOrPut(key) catch continue).found_existing) continue;
            const gop = root_sizes.getOrPut(root) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        var substrate_root: ?u32 = null;
        var max_size: u16 = 0;
        var it = root_sizes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > max_size) {
                max_size = entry.value_ptr.*;
                substrate_root = entry.key_ptr.*;
            }
        }
        if (max_size >= 3) {
            if (substrate_root) |sr| {
                for (0..n) |i| {
                    if (net_map[i] == sr) net_map[i] = SUBSTRATE_NET;
                }
            }
        }
    }

    var resistors: std.ArrayListUnmanaged(RcElement) = .{};
    errdefer resistors.deinit(allocator);

    // Substrate cap: accumulated per net (insertion-ordered for determinism).
    var sub_nets: std.ArrayListUnmanaged(u32) = .{};
    var sub_vals: std.ArrayListUnmanaged(f32) = .{};
    defer sub_nets.deinit(allocator);
    defer sub_vals.deinit(allocator);

    // Coupling cap: accumulated per (net_a < net_b) pair (insertion-ordered).
    var coup_a:   std.ArrayListUnmanaged(u32) = .{};
    var coup_b:   std.ArrayListUnmanaged(u32) = .{};
    var coup_vals: std.ArrayListUnmanaged(f32) = .{};
    defer coup_a.deinit(allocator);
    defer coup_b.deinit(allocator);
    defer coup_vals.deinit(allocator);

    // ── Per-segment R; accumulate substrate cap per net ───────────────────────
    for (0..n) |i| {
        const layer = routes.layer[i];
        const idx   = routeLayerToPexIdx(layer);
        const net   = net_map[i];
        const x1    = routes.x1[i]; const y1 = routes.y1[i];
        const x2    = routes.x2[i]; const y2 = routes.y2[i];
        const w     = routes.width[i];

        const L = segmentLength(x1, y1, x2, y2);
        if (L < 1e-9 or w < 1e-9) continue; // degenerate segment

        const sheet_r = pex_cfg.sheet_resistance[idx];
        const a_cap   = pex_cfg.substrate_cap[idx]; // aF/µm²
        const f_cap   = pex_cfg.fringe_cap[idx];    // aF/µm

        // Wire resistance: R = ρ_sheet * (L / W)  [Ω] — one per segment.
        if (sheet_r > 0.0) {
            try resistors.append(allocator, .{
                .net_a = net,
                .net_b = net, // both ends of segment on same net
                .value = sheet_r * L / w,
            });
        }

        // Area + fringe cap: accumulate into per-net bucket.
        // C_area   = L * W * areacap  [aF]
        // C_fringe = 2 * L * perimc   [aF]  (two long edges facing space)
        //
        // Only the two long edges get fringe.  Wire ends connect to vias,
        // bends, or pads — they don't border space.  Magic's perimCap is
        // only added for tile edges that actually border space (ExtBasic.c
        // line 5438); short edges at junctions don't qualify.
        const c_total_af = L * w * a_cap + 2.0 * L * f_cap;
        if (c_total_af > 0.0) {
            var found = false;
            for (sub_nets.items, 0..) |sn, k| {
                if (sn == net) { sub_vals.items[k] += c_total_af; found = true; break; }
            }
            if (!found) {
                try sub_nets.append(allocator, net);
                try sub_vals.append(allocator, c_total_af);
            }
        }
    }

    // ── Via resistance ─────────────────────────────────────────────────────────
    // Detect via points: where two segments on adjacent layers share an endpoint.
    // Each via contributes R_via = via_resistance[lower_layer] / n_cuts (assume 1 cut).
    // Mirrors Magic's `contact` resistance extraction (ExtBasic.c).
    // Use a de-duplication set to avoid counting the same via point twice when
    // multiple segments converge at the same (x, y, layer-pair).
    {
        // Track emitted vias as (x_bits, y_bits, lower_layer) to de-duplicate.
        var via_set = std.AutoHashMap(u96, void).init(allocator);
        defer via_set.deinit();

        for (0..n) |i| {
            const li = routes.layer[i];
            const ni = net_map[i];
            // Check both endpoints of segment i.
            const endpoints_x = [2]f32{ routes.x1[i], routes.x2[i] };
            const endpoints_y = [2]f32{ routes.y1[i], routes.y2[i] };
            for (0..2) |ei| {
                const ex = endpoints_x[ei];
                const ey = endpoints_y[ei];
                for (0..n) |j| {
                    if (j == i) continue;
                    const lj = routes.layer[j];
                    // Adjacent layers only (differ by exactly 1).
                    const diff: i16 = @as(i16, @intCast(li)) - @as(i16, @intCast(lj));
                    if (diff != 1 and diff != -1) continue;
                    // Same net (using merged net IDs).
                    if (net_map[j] != ni) continue;
                    // Check if any endpoint of segment j matches (ex, ey).
                    const match = (@abs(routes.x1[j] - ex) < 1e-6 and @abs(routes.y1[j] - ey) < 1e-6) or
                                  (@abs(routes.x2[j] - ex) < 1e-6 and @abs(routes.y2[j] - ey) < 1e-6);
                    if (!match) continue;
                    // Via found at (ex, ey) between layers li and lj.
                    const lower_layer = @min(li, lj);
                    const via_idx = routeLayerToPexIdx(lower_layer);
                    const via_r = pex_cfg.via_resistance[via_idx];
                    if (via_r <= 0.0) continue;
                    // De-duplicate: encode (x, y, lower_layer) as u96 key.
                    const x_bits: u32 = @bitCast(ex);
                    const y_bits: u32 = @bitCast(ey);
                    const key: u96 = (@as(u96, x_bits) << 64) | (@as(u96, y_bits) << 32) | @as(u96, lower_layer);
                    const gop = via_set.getOrPut(key) catch continue;
                    if (!gop.found_existing) {
                        try resistors.append(allocator, .{
                            .net_a = ni,
                            .net_b = ni,
                            .value = via_r,
                        });
                    }
                    break; // Found a matching segment for this endpoint; move on.
                }
            }
        }
    }

    // ── Nearest-neighbor sidewall coupling cap ──────────────────────────────
    // Mirrors Magic's tile-adjacency model: each segment edge couples only
    // with the nearest different-net segment on that perpendicular side.
    // This prevents the O(n²) all-pairs overcounting that occurs when many
    // wires on the same layer are within the coupling distance.
    //
    // Phase 1: For each segment, find nearest different-net neighbor on each
    //          perpendicular side (positive = above/right, negative = below/left).
    // Phase 2: For each valid nearest-neighbor pair (i < j), compute coupling.

    // nn_pos[i] = nearest different-net neighbor on positive perp side (or n).
    // nn_neg[i] = nearest different-net neighbor on negative perp side (or n).
    var nn_pos = try allocator.alloc(usize, n);
    defer allocator.free(nn_pos);
    var nn_neg = try allocator.alloc(usize, n);
    defer allocator.free(nn_neg);

    for (0..n) |i| {
        nn_pos[i] = n;
        nn_neg[i] = n;
        const li = routes.layer[i];
        const ni_nn = net_map[i];
        const i_horiz_nn = @abs(routes.y2[i] - routes.y1[i]) < 1e-6;
        const i_vert_nn = @abs(routes.x2[i] - routes.x1[i]) < 1e-6;
        if (!i_horiz_nn and !i_vert_nn) continue;
        const perp_i: f32 = if (i_horiz_nn) routes.y1[i] else routes.x1[i];
        var best_pos_sep: f32 = std.math.inf(f32);
        var best_neg_sep: f32 = std.math.inf(f32);

        for (0..n) |j| {
            if (j == i) continue;
            if (routes.layer[j] != li) continue;
            if (net_map[j] == ni_nn) continue;
            const j_horiz = @abs(routes.y2[j] - routes.y1[j]) < 1e-6;
            const j_vert = @abs(routes.x2[j] - routes.x1[j]) < 1e-6;
            if (i_horiz_nn and !j_horiz) continue;
            if (i_vert_nn and !j_vert) continue;

            // Check overlap.
            const ov = if (i_horiz_nn)
                overlapLen(
                    @min(routes.x1[i], routes.x2[i]), @max(routes.x1[i], routes.x2[i]),
                    @min(routes.x1[j], routes.x2[j]), @max(routes.x1[j], routes.x2[j]),
                )
            else
                overlapLen(
                    @min(routes.y1[i], routes.y2[i]), @max(routes.y1[i], routes.y2[i]),
                    @min(routes.y1[j], routes.y2[j]), @max(routes.y1[j], routes.y2[j]),
                );
            if (ov < @min(routes.width[i], routes.width[j])) continue;

            const perp_j: f32 = if (i_horiz_nn) routes.y1[j] else routes.x1[j];
            const sep = @max(0.0, @abs(perp_i - perp_j) - (routes.width[i] + routes.width[j]) / 2.0);

            if (perp_j > perp_i + 1e-6 and sep < best_pos_sep) {
                best_pos_sep = sep;
                nn_pos[i] = j;
            } else if (perp_j < perp_i - 1e-6 and sep < best_neg_sep) {
                best_neg_sep = sep;
                nn_neg[i] = j;
            }
        }
    }

    // Phase 2: Process coupling for nearest-neighbor pairs (i < j to deduplicate).
    for (0..n) |i| {
        const neighbors = [2]usize{ nn_pos[i], nn_neg[i] };
        for (neighbors) |j| {
            if (j >= n or j <= i) continue; // sentinel or already processed

            const idx = routeLayerToPexIdx(routes.layer[i]);
            const sw_cap = pex_cfg.sidewall_cap[idx];
            if (sw_cap <= 0.0) continue;
            const coup_dist = pex_cfg.coupling_distance[idx];

            const ni = net_map[i];
            const nj = net_map[j];
            const xi1 = routes.x1[i]; const yi1 = routes.y1[i];
            const xi2 = routes.x2[i]; const yi2 = routes.y2[i];
            const xj1 = routes.x1[j]; const yj1 = routes.y1[j];
            const xj2 = routes.x2[j]; const yj2 = routes.y2[j];
            const i_horiz = @abs(yi2 - yi1) < 1e-6;

            const overlap: f32 = if (i_horiz)
                overlapLen(
                    @min(xi1, xi2), @max(xi1, xi2),
                    @min(xj1, xj2), @max(xj1, xj2),
                )
            else
                overlapLen(
                    @min(yi1, yi2), @max(yi1, yi2),
                    @min(yj1, yj2), @max(yj1, yj2),
                );

            const perp_cc: f32 = if (i_horiz) @abs(yi1 - yj1) else @abs(xi1 - xj1);
            const sep_ee: f32 = @max(0.0, perp_cc - (routes.width[i] + routes.width[j]) / 2.0);
            if (coup_dist > 0.0 and sep_ee > coup_dist) continue;

            const offset = pex_cfg.coupling_offset[idx];
            const denom = sep_ee + offset;
            const c_couple_af: f32 = if (denom > 1e-3)
                sw_cap * overlap / denom
            else
                overlap * sw_cap;

            // Fringe subtraction — Magic's extRemoveSubcap atan model.
            const f_cap = pex_cfg.fringe_cap[idx];
            const a_cap_layer = pex_cfg.substrate_cap[idx];
            const fmult_arg = a_cap_layer * 0.02 * sep_ee;
            const snear: f32 = 0.6366 * std.math.atan(fmult_arg);
            const fringe_blocked: f32 = @max(0.0, 1.0 - snear);
            const fringe_sub_af: f32 = fringe_blocked * overlap * f_cap;
            for (sub_nets.items, 0..) |sn, k| {
                if (sn == ni) { sub_vals.items[k] -= fringe_sub_af; break; }
            }
            for (sub_nets.items, 0..) |sn, k| {
                if (sn == nj) { sub_vals.items[k] -= fringe_sub_af; break; }
            }

            const na = @min(ni, nj);
            const nb = @max(ni, nj);
            var found = false;
            for (coup_a.items, 0..) |ea, k| {
                if (ea == na and coup_b.items[k] == nb) {
                    coup_vals.items[k] += c_couple_af;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try coup_a.append(allocator, na);
                try coup_b.append(allocator, nb);
                try coup_vals.append(allocator, c_couple_af);
            }
        }
    }

    // ── Interlayer overlap cap (filtered: segments > min_routing_length) ─────
    // Only consider segments longer than ~3x min wire width to exclude short
    // device-internal LI/M1 stubs that Magic merges into the device model.
    const min_routing_len: f32 = 0.5; // µm — filters device-internal stubs
    for (0..n) |i| {
        const li_ov = routes.layer[i];
        const ni_ov = net_map[i];
        const len_i = segmentLength(routes.x1[i], routes.y1[i], routes.x2[i], routes.y2[i]);
        if (len_i < min_routing_len) continue;

        for (i + 1..n) |j| {
            const lj_ov = routes.layer[j];
            const diff_ov: i16 = @as(i16, @intCast(li_ov)) - @as(i16, @intCast(lj_ov));
            if (diff_ov != 1 and diff_ov != -1) continue;
            const nj_ov = net_map[j];
            if (ni_ov == nj_ov) continue;
            const len_j = segmentLength(routes.x1[j], routes.y1[j], routes.x2[j], routes.y2[j]);
            if (len_j < min_routing_len) continue;

            const lower_layer = @min(li_ov, lj_ov);
            const ov_cap = pex_cfg.overlap_cap[routeLayerToPexIdx(lower_layer)];
            if (ov_cap <= 0.0) continue;

            // Wire rectangles.
            const wi = routes.width[i];
            const wj = routes.width[j];
            const i_left   = @min(routes.x1[i], routes.x2[i]) - if (@abs(routes.x2[i] - routes.x1[i]) < 1e-6) wi / 2.0 else @as(f32, 0.0);
            const i_right  = @max(routes.x1[i], routes.x2[i]) + if (@abs(routes.x2[i] - routes.x1[i]) < 1e-6) wi / 2.0 else @as(f32, 0.0);
            const i_bottom = @min(routes.y1[i], routes.y2[i]) - if (@abs(routes.y2[i] - routes.y1[i]) < 1e-6) wi / 2.0 else @as(f32, 0.0);
            const i_top    = @max(routes.y1[i], routes.y2[i]) + if (@abs(routes.y2[i] - routes.y1[i]) < 1e-6) wi / 2.0 else @as(f32, 0.0);
            const j_left   = @min(routes.x1[j], routes.x2[j]) - if (@abs(routes.x2[j] - routes.x1[j]) < 1e-6) wj / 2.0 else @as(f32, 0.0);
            const j_right  = @max(routes.x1[j], routes.x2[j]) + if (@abs(routes.x2[j] - routes.x1[j]) < 1e-6) wj / 2.0 else @as(f32, 0.0);
            const j_bottom = @min(routes.y1[j], routes.y2[j]) - if (@abs(routes.y2[j] - routes.y1[j]) < 1e-6) wj / 2.0 else @as(f32, 0.0);
            const j_top    = @max(routes.y1[j], routes.y2[j]) + if (@abs(routes.y2[j] - routes.y1[j]) < 1e-6) wj / 2.0 else @as(f32, 0.0);

            const ov_x = @max(@as(f32, 0.0), @min(i_right, j_right) - @max(i_left, j_left));
            const ov_y = @max(@as(f32, 0.0), @min(i_top, j_top) - @max(i_bottom, j_bottom));
            const ov_area = ov_x * ov_y;
            if (ov_area < 1e-6) continue;

            const c_ov_af = ov_area * ov_cap;
            const na = @min(ni_ov, nj_ov);
            const nb = @max(ni_ov, nj_ov);
            var found = false;
            for (coup_a.items, 0..) |ea, k| {
                if (ea == na and coup_b.items[k] == nb) {
                    coup_vals.items[k] += c_ov_af;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try coup_a.append(allocator, na);
                try coup_b.append(allocator, nb);
                try coup_vals.append(allocator, c_ov_af);
            }
        }
    }

    // ── Emit one capacitor element per net / net-pair ─────────────────────────
    // Coupling caps where one end is SUBSTRATE_NET get folded into the signal
    // net's substrate cap (matching Magic's substrate-absorption convention).
    var capacitors: std.ArrayListUnmanaged(RcElement) = .{};
    errdefer capacitors.deinit(allocator);

    for (coup_a.items, coup_b.items, coup_vals.items) |ca, cb, cv| {
        if (cb == SUBSTRATE_NET and ca != SUBSTRATE_NET) {
            for (sub_nets.items, 0..) |sn, k| {
                if (sn == ca) { sub_vals.items[k] += cv; break; }
            }
        }
    }

    for (sub_nets.items, sub_vals.items) |sn, sv| {
        if (sn == SUBSTRATE_NET) continue; // substrate-to-substrate: skip
        const clamped = @max(sv, 0.0); // fringe subtraction may overshoot
        if (clamped < 1e-6) continue; // skip negligible entries
        try capacitors.append(allocator, .{
            .net_a = sn,
            .net_b = SUBSTRATE_NET,
            .value = clamped / 1000.0, // aF → fF
        });
    }
    for (coup_a.items, coup_b.items, coup_vals.items) |ca, cb, cv| {
        if (ca == SUBSTRATE_NET or cb == SUBSTRATE_NET) continue; // handled above
        try capacitors.append(allocator, .{
            .net_a = ca,
            .net_b = cb,
            .value = cv / 1000.0, // aF → fF
        });
    }

    // Build merge map for lib.zig to remap device-pin nets.
    var mf = std.ArrayListUnmanaged(u32){};
    var mt = std.ArrayListUnmanaged(u32){};
    {
        var it2 = uf_parent.iterator();
        while (it2.next()) |entry| {
            const orig = entry.key_ptr.*;
            const root = ufFind(&uf_parent, orig);
            if (root != orig) {
                // Check if root was remapped to SUBSTRATE_NET.
                var mapped_root = root;
                for (0..n) |i| {
                    if (routes.net[i].toInt() == root) { mapped_root = net_map[i]; break; }
                }
                mf.append(allocator, orig) catch {};
                mt.append(allocator, mapped_root) catch {};
            }
        }
    }

    return PexResult{
        .resistors  = try resistors.toOwnedSlice(allocator),
        .capacitors = try capacitors.toOwnedSlice(allocator),
        .merge_from = if (mf.items.len > 0) try mf.toOwnedSlice(allocator) else null,
        .merge_to   = if (mt.items.len > 0) try mt.toOwnedSlice(allocator) else null,
        .allocator  = allocator,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// All values computed analytically from SKY130 Magic coefficients and verified
// against what Magic's ext2spice would report for the same geometry.

const testing = std.testing;

/// Tolerance for floating-point comparisons (1% relative).
const TOL: f32 = 0.01;

fn approxEq(a: f32, b: f32, rel_tol: f32) bool {
    const denom = @max(@abs(a), @abs(b));
    if (denom < 1e-12) return @abs(a - b) < 1e-9;
    return @abs(a - b) / denom <= rel_tol;
}

test "PEX empty routes returns zero elements" {
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.resistors.len);
    try testing.expectEqual(@as(usize, 0), r.capacitors.len);
}

test "PEX M1 resistance for 1um wire" {
    // SKY130 M1: sheet_R = 0.125 Ω/sq, L = 1.0 µm, W = 0.14 µm.
    // Magic ext2spice: R = 0.125 * (1.0 / 0.14) ≈ 0.8929 Ω.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net); // route layer 1 = M1

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.resistors.len);
    const expected_r: f32 = 0.125 * 1.0 / 0.14;
    try testing.expect(approxEq(r.resistors[0].value, expected_r, TOL));
}

test "PEX M1 resistance for 10um wire" {
    // L = 10.0 µm, W = 0.14 µm: R = 0.125 * 10.0 / 0.14 ≈ 8.929 Ω.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, net);

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();

    const expected_r: f32 = 0.125 * 10.0 / 0.14;
    try testing.expect(approxEq(r.resistors[0].value, expected_r, TOL));
}

test "PEX wider wire has lower resistance" {
    // L = 1.0 µm, W = 0.28 µm: R = 0.125 * 1.0 / 0.28 ≈ 0.446 Ω < 0.893 Ω.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net); // narrow
    try ra.append(1, 5.0, 0.0, 6.0, 0.0, 0.28, net); // wide

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.resistors.len);
    try testing.expect(r.resistors[1].value < r.resistors[0].value);
}

test "PEX M4 has lower sheet resistance than M1" {
    // M4 (route layer 4) = pex index 4 = 0.047 Ω/sq < M1 (pex index 1) 0.125 Ω/sq.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net); // M1
    try ra.append(4, 5.0, 0.0, 6.0, 0.0, 0.14, net); // M4

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.resistors.len);
    // M4 (index 1) has lower R than M1 (index 0) for same geometry.
    try testing.expect(r.resistors[1].value < r.resistors[0].value);
}

test "PEX area capacitance M1 1um wire" {
    // SKY130 M1: areacap = 17.0 aF/µm², L = 1.0, W = 0.14.
    // C_area = 1.0 * 0.14 * 17.0 = 2.38 aF = 0.00238 fF.
    // Route layer 1 (M1) → PexConfig index 1.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(2);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net);

    const cfg = PexConfig{ .sheet_resistance = .{0.0} ** 8, // disable R
                            .substrate_cap    = .{ 0.0, 17.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
                            .fringe_cap       = .{0.0} ** 8,
                            .sidewall_cap     = .{0.0} ** 8 };
    var r = try extractFromRoutes(&ra, cfg, testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.capacitors.len);
    const expected_fF: f32 = 1.0 * 0.14 * 17.0 / 1000.0; // aF → fF
    try testing.expect(approxEq(r.capacitors[0].value, expected_fF, TOL));
    try testing.expectEqual(SUBSTRATE_NET, r.capacitors[0].net_b);
}

test "PEX fringe capacitance M1 1um wire" {
    // SKY130 M1: perimc = 50.0 aF/µm, L = 1.0 µm.
    // C_fringe = 2 * 1.0 * 50.0 = 100.0 aF = 0.1 fF.
    // Route layer 1 (M1) → PexConfig index 1.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net);

    const cfg = PexConfig{ .sheet_resistance = .{0.0} ** 8,
                            .substrate_cap    = .{0.0} ** 8,
                            .fringe_cap       = .{ 0.0, 50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
                            .sidewall_cap     = .{0.0} ** 8 };
    var r = try extractFromRoutes(&ra, cfg, testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.capacitors.len);
    const expected_fF: f32 = 2.0 * 1.0 * 50.0 / 1000.0; // = 0.1 fF
    try testing.expect(approxEq(r.capacitors[0].value, expected_fF, TOL));
}

test "PEX total capacitance M1 1um wire (area + fringe)" {
    // C_total = area + fringe = 2.38 + 100.0 = 102.38 aF = 0.10238 fF.
    // Route layer 1 (M1) → PexConfig index 1.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net);

    const cfg = PexConfig{ .sheet_resistance = .{0.0} ** 8,
                            .substrate_cap    = .{ 0.0, 17.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
                            .fringe_cap       = .{ 0.0, 50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
                            .sidewall_cap     = .{0.0} ** 8 };
    var r = try extractFromRoutes(&ra, cfg, testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 1), r.capacitors.len);
    const c_area_af:   f32 = 1.0 * 0.14 * 17.0;
    const c_fringe_af: f32 = 2.0 * 1.0 * 50.0;
    const expected_fF: f32 = (c_area_af + c_fringe_af) / 1000.0;
    try testing.expect(approxEq(r.capacitors[0].value, expected_fF, TOL));
}

test "PEX M2 capacitance lower than M1 for same geometry" {
    // Higher layers have lower substrate cap.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net0 = @import("../core/types.zig").NetIdx.fromInt(0);
    const net1 = @import("../core/types.zig").NetIdx.fromInt(1);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net0); // M1
    try ra.append(2, 5.0, 0.0, 6.0, 0.0, 0.14, net1); // M2

    const cfg = PexConfig{ .sheet_resistance = .{0.0} ** 8,
                            .substrate_cap    = PexConfig.sky130().substrate_cap,
                            .fringe_cap       = .{0.0} ** 8,
                            .sidewall_cap     = .{0.0} ** 8 };
    var r = try extractFromRoutes(&ra, cfg, testing.allocator);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.capacitors.len);
    try testing.expect(r.capacitors[1].value < r.capacitors[0].value);
}

test "PEX zero-length segment produces no elements" {
    // x1==x2, y1==y2 → L=0 → skip.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(0);
    try ra.append(1, 3.0, 3.0, 3.0, 3.0, 0.14, net); // degenerate

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.resistors.len);
    try testing.expectEqual(@as(usize, 0), r.capacitors.len);
}

test "PEX multiple segments accumulate correctly" {
    // 3 M1 segments → 3 R elements and 3 C elements.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net0 = @import("../core/types.zig").NetIdx.fromInt(0);
    const net1 = @import("../core/types.zig").NetIdx.fromInt(1);
    const net2 = @import("../core/types.zig").NetIdx.fromInt(2);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net0);
    try ra.append(1, 2.0, 0.0, 3.0, 0.0, 0.14, net1);
    try ra.append(1, 4.0, 0.0, 5.0, 0.0, 0.14, net2);

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.resistors.len);
    // At least 3 cap elements (may be more if coupling caps are added).
    try testing.expect(r.capacitors.len >= 3);
}

test "PEX all substrate caps have net_b == SUBSTRATE_NET" {
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(7);
    try ra.append(1, 0.0, 0.0, 5.0, 0.0, 0.14, net);
    try ra.append(2, 0.0, 1.0, 5.0, 1.0, 0.14, net);

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();
    for (r.capacitors) |c| {
        if (c.net_a == c.net_b) continue; // coupling cap: net_a != net_b
        try testing.expectEqual(SUBSTRATE_NET, c.net_b);
    }
}

test "PEX resistor net assignment matches segment net" {
    // Segment on net 5 → resistor should have net_a == 5.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net = @import("../core/types.zig").NetIdx.fromInt(5);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net);

    var r = try extractFromRoutes(&ra, PexConfig.sky130(), testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.resistors.len);
    try testing.expectEqual(@as(u32, 5), r.resistors[0].net_a);
}

test "PEX sidewall coupling cap between parallel horizontal wires" {
    // Two parallel horizontal M1 wires at y=0 and y=0.64, both from x=0 to x=1.
    // sep_ee = 0.64 - 0.14 = 0.50 µm, offset = 0.50 µm.
    // C_couple = sw_cap * overlap / (sep_ee + offset) = 75 * 1.0 / 1.0 = 75 aF = 0.075 fF.
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net0 = @import("../core/types.zig").NetIdx.fromInt(0);
    const net1 = @import("../core/types.zig").NetIdx.fromInt(1);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net0);
    try ra.append(1, 0.0, 0.64, 1.0, 0.64, 0.14, net1);

    const cfg = PexConfig{ .sheet_resistance = .{0.0} ** 8,
                            .substrate_cap    = .{0.0} ** 8,
                            .fringe_cap       = .{0.0} ** 8,
                            .sidewall_cap     = .{ 0.0, 75.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
                            .coupling_offset  = .{ 0.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
                            .coupling_distance = .{ 0.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 } };
    var r = try extractFromRoutes(&ra, cfg, testing.allocator);
    defer r.deinit();

    // Find the coupling cap element (net_a != net_b and net_b != SUBSTRATE_NET).
    var found = false;
    for (r.capacitors) |c| {
        if (c.net_b != SUBSTRATE_NET) {
            const expected_fF: f32 = 75.0 * 1.0 / (0.50 + 0.50) / 1000.0;
            try testing.expect(approxEq(c.value, expected_fF, TOL));
            found = true;
        }
    }
    try testing.expect(found);
}

test "PEX no coupling cap between wires on different layers" {
    // M1 and M2 wires at same position: no sidewall coupling (different layers).
    var ra = try RouteArrays.init(testing.allocator, 0);
    defer ra.deinit();
    const net0 = @import("../core/types.zig").NetIdx.fromInt(0);
    const net1 = @import("../core/types.zig").NetIdx.fromInt(1);
    try ra.append(1, 0.0, 0.0, 1.0, 0.0, 0.14, net0); // M1
    try ra.append(2, 0.0, 0.0, 1.0, 0.0, 0.14, net1); // M2

    const cfg = PexConfig{ .sheet_resistance = .{0.0} ** 8,
                            .substrate_cap    = .{0.0} ** 8,
                            .fringe_cap       = .{0.0} ** 8,
                            .sidewall_cap     = .{ 0.0, 75.0, 75.0, 0.0, 0.0, 0.0, 0.0, 0.0 } };
    var r = try extractFromRoutes(&ra, cfg, testing.allocator);
    defer r.deinit();

    // No coupling cap: all capacitors should have net_b == SUBSTRATE_NET or be empty.
    for (r.capacitors) |c| {
        try testing.expectEqual(SUBSTRATE_NET, c.net_b);
    }
}
