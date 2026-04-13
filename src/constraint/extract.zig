const std = @import("std");
const core_types = @import("../core/types.zig");
const adjacency = @import("../core/adjacency.zig");
const pin_edge_mod = @import("../core/pin_edge_arrays.zig");
const constraint_mod = @import("../core/constraint_arrays.zig");
const device_mod = @import("../core/device_arrays.zig");
const net_mod = @import("../core/net_arrays.zig");
const patterns = @import("patterns.zig");

const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;
const DeviceType = core_types.DeviceType;
const DeviceParams = core_types.DeviceParams;
const ConstraintType = core_types.ConstraintType;
const FlatAdjList = adjacency.FlatAdjList;
const PinEdgeArrays = pin_edge_mod.PinEdgeArrays;
const ConstraintArrays = constraint_mod.ConstraintArrays;
const DeviceArrays = device_mod.DeviceArrays;
const NetArrays = net_mod.NetArrays;

/// Extract placement constraints from the circuit topology.
///
/// Iterates over all device pairs O(n^2) and applies pattern-matching rules
/// (differential pair, current mirror, cascode) to detect constraints.
/// This is fine for analog circuits with <100 devices.
///
/// All input arrays are borrowed (read-only). Returns an owned
/// ConstraintArrays that the caller must deinit.
pub fn extractConstraints(
    allocator: std.mem.Allocator,
    devices: *const DeviceArrays,
    nets: *const NetArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
) !ConstraintArrays {
    var result = try ConstraintArrays.init(allocator, 0);
    errdefer result.deinit();

    // Deduplication set: prevents emitting the same device pair twice.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    const n: u32 = devices.len;

    // Group ID counter for seed pairs (diff pairs). Each seed gets a unique
    // non-zero group ID; load/cascode pairs inherit the same ID.
    var next_gid: u32 = 1;

    // Iterate over all ordered pairs (i, j) with i < j.
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var j: u32 = i + 1;
        while (j < n) : (j += 1) {
            const d_a = DeviceIdx.fromInt(i);
            const d_b = DeviceIdx.fromInt(j);

            // --- Differential Pair → symmetry ---
            if (isSeedPair(devices, nets, pins, adj, d_a, d_b)) {
                const gid = next_gid;
                next_gid += 1;
                // Record seed pair in seen set.
                try seen.put(patterns.packPair(i, j), {});
                try result.append(
                    .symmetry,
                    d_a,
                    d_b,
                    1.0,
                    std.math.nan(f32), // axis unknown until placement
                    gid,
                );
                // Traverse load and cascode pairs attached to the drain nets.
                const drain_a = patterns.drainNet(adj, pins, d_a) orelse continue;
                const drain_b = patterns.drainNet(adj, pins, d_b) orelse continue;
                try findLoadPair(devices, nets, pins, adj, drain_a, drain_b, gid, &result, &seen);
                try findCascodePair(devices, pins, adj, drain_a, drain_b, gid, &result, &seen);
                // Find self-symmetric tail bias: drain connects to shared source (axis_net).
                const axis_net = patterns.sourceNet(adj, pins, d_a).?; // safe: isSeedPair validated non-null
                try findTailBias(devices, nets, pins, adj, axis_net, gid, &result, &seen);
            }

            // --- Current Mirror → matching ---
            {
                const mirror_key = patterns.packPair(i, j);
                if (!seen.contains(mirror_key)) {
                    if (isCurrentMirror1to1(devices, pins, adj, d_a, d_b)) {
                        try result.append(.matching, d_a, d_b, 0.8, std.math.nan(f32), 0);
                        try seen.put(mirror_key, {});
                    } else if (isCurrentMirrorRatio(devices, pins, adj, d_a, d_b)) {
                        try result.append(.matching, d_a, d_b, 0.7, std.math.nan(f32), 0);
                        try seen.put(mirror_key, {});
                    }
                }
            }

            // --- Passive matching (resistor / capacitor pairs) ---
            if (checkPassivePair(devices, d_a, d_b)) |w| {
                const key = patterns.packPair(i, j);
                if (!seen.contains(key)) {
                    try result.append(.matching, d_a, d_b, w, std.math.nan(f32), 0);
                    try seen.put(key, {});
                }
            }

            // --- Cascode → proximity (check both directions) ---
            if (isCascode(pins, adj, d_a, d_b)) {
                try result.append(
                    .proximity,
                    d_a,
                    d_b,
                    0.5,
                    std.math.nan(f32),
                    0,
                );
            } else if (isCascode(pins, adj, d_b, d_a)) {
                // drain(d_b) == source(d_a): d_b is the bottom, d_a is the top.
                try result.append(
                    .proximity,
                    d_b,
                    d_a,
                    0.5,
                    std.math.nan(f32),
                    0,
                );
            }
        }
    }

    return result;
}

// ─── Load-pair / cascode-pair traversal ─────────────────────────────────────

/// Find a symmetric load pair on the drain nets of a differential pair.
///
/// Looks for two devices d_x and d_y such that:
///   - d_x.drain == drain_a, d_y.drain == drain_b
///   - same device type, matching effective W
///   - both sources connect to the same rail net
///
/// Appends a symmetry constraint with the given group_id and records the
/// pair in `seen` so it is not emitted again.
fn findLoadPair(
    devices: *const DeviceArrays,
    nets: *const NetArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    drain_a: NetIdx,
    drain_b: NetIdx,
    group_id: u32,
    result: *ConstraintArrays,
    seen: *std.AutoHashMap(u64, void),
) !void {
    var cands_a: patterns.DeviceIdxBuf = .{};
    var cands_b: patterns.DeviceIdxBuf = .{};
    patterns.devicesOnNetByTerminal(adj, pins, drain_a, .drain, &cands_a);
    patterns.devicesOnNetByTerminal(adj, pins, drain_b, .drain, &cands_b);

    for (cands_a.slice()) |d_x| {
        for (cands_b.slice()) |d_y| {
            if (d_x.toInt() == d_y.toInt()) continue;
            const ix = d_x.toInt();
            const iy = d_y.toInt();
            if (devices.types[ix] != devices.types[iy]) continue;
            if (!patterns.approxEq(patterns.effectiveW(devices, d_x), patterns.effectiveW(devices, d_y))) continue;
            // Sources of both must connect to the same rail net.
            const src_x = patterns.sourceNet(adj, pins, d_x) orelse continue;
            const src_y = patterns.sourceNet(adj, pins, d_y) orelse continue;
            if (src_x.toInt() != src_y.toInt()) continue;
            if (!patterns.isRail(src_x, nets)) continue;
            // Deduplicate.
            const pair = patterns.normalisePair(d_x, d_y);
            const key = patterns.packPair(pair[0].toInt(), pair[1].toInt());
            if (seen.contains(key)) continue;
            try result.append(.symmetry, pair[0], pair[1], 1.0, std.math.nan(f32), group_id);
            try seen.put(key, {});
        }
    }
}

/// Find a self-symmetric tail bias device whose drain connects to axis_net.
///
/// A tail bias transistor sits between the diff pair's shared source net and a
/// power rail. Because it has no symmetric partner, it is recorded as a
/// self-symmetric constraint (device_a == device_b) so the placer knows it
/// lies on the axis of symmetry.
///
/// Requirements:
///   - Device's drain connects to axis_net.
///   - Device's source connects to a power/ground rail.
///   - device_a == device_b (self-symmetric; key uses packPair(i, i)).
fn findTailBias(
    devices: *const DeviceArrays,
    nets: *const NetArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    axis_net: NetIdx,
    group_id: u32,
    result: *ConstraintArrays,
    seen: *std.AutoHashMap(u64, void),
) !void {
    // Collect all devices whose DRAIN connects to axis_net.
    var cands: patterns.DeviceIdxBuf = .{};
    patterns.devicesOnNetByTerminal(adj, pins, axis_net, .drain, &cands);

    for (cands.slice()) |d| {
        const i = d.toInt();
        if (devices.types[i] != .nmos and devices.types[i] != .pmos) continue;
        // Source must be a rail.
        const src = patterns.sourceNet(adj, pins, d) orelse continue;
        if (!patterns.isRail(src, nets)) continue;
        // Self-symmetric: device_a == device_b.
        const key = patterns.packPair(i, i);
        if (seen.contains(key)) continue;
        try result.append(.symmetry, d, d, 0.5, std.math.nan(f32), group_id);
        try seen.put(key, {});
    }
}

/// Find a symmetric cascode pair stacked on the drain nets of a differential pair.
///
/// Looks for two devices d_x and d_y such that:
///   - d_x.source == drain_a, d_y.source == drain_b  (source-stacked on top)
///   - same device type, matching effective W
///
/// Appends a proximity constraint with the given group_id and records the
/// pair in `seen`.
fn findCascodePair(
    devices: *const DeviceArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    drain_a: NetIdx,
    drain_b: NetIdx,
    group_id: u32,
    result: *ConstraintArrays,
    seen: *std.AutoHashMap(u64, void),
) !void {
    var cands_a: patterns.DeviceIdxBuf = .{};
    var cands_b: patterns.DeviceIdxBuf = .{};
    patterns.devicesOnNetByTerminal(adj, pins, drain_a, .source, &cands_a);
    patterns.devicesOnNetByTerminal(adj, pins, drain_b, .source, &cands_b);

    for (cands_a.slice()) |d_x| {
        for (cands_b.slice()) |d_y| {
            if (d_x.toInt() == d_y.toInt()) continue;
            const ix = d_x.toInt();
            const iy = d_y.toInt();
            if (devices.types[ix] != devices.types[iy]) continue;
            if (!patterns.approxEq(patterns.effectiveW(devices, d_x), patterns.effectiveW(devices, d_y))) continue;
            // Deduplicate.
            const pair = patterns.normalisePair(d_x, d_y);
            const key = patterns.packPair(pair[0].toInt(), pair[1].toInt());
            if (seen.contains(key)) continue;
            try result.append(.proximity, pair[0], pair[1], 0.5, std.math.nan(f32), group_id);
            try seen.put(key, {});
        }
    }
}

// ─── Pattern predicates ─────────────────────────────────────────────────────

/// Detect whether two devices form a differential pair seed.
/// Requirements: same MOSFET type, matching effective W/L (via approxEq),
/// shared non-rail source net, different gate nets.
///
/// NOTE: Rail detection relies entirely on `nets.is_power` as set by the
/// SPICE parser. Nets not flagged as power (e.g. unnamed supply rails) will
/// not be recognised as rails, potentially creating false positive pairs.
fn isSeedPair(
    devices: *const DeviceArrays,
    nets: *const NetArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    d_a: DeviceIdx,
    d_b: DeviceIdx,
) bool {
    const ia: usize = d_a.toInt();
    const ib: usize = d_b.toInt();

    // MOSFETs only.
    if (devices.types[ia] != .nmos and devices.types[ia] != .pmos) return false;
    if (devices.types[ia] != devices.types[ib]) return false;

    // Same effective W and same L.
    if (!patterns.approxEq(patterns.effectiveW(devices, d_a), patterns.effectiveW(devices, d_b))) return false;
    if (!patterns.approxEq(devices.params[ia].l, devices.params[ib].l)) return false;

    // Shared source net.
    const src_a = patterns.sourceNet(adj, pins, d_a) orelse return false;
    const src_b = patterns.sourceNet(adj, pins, d_b) orelse return false;
    if (src_a.toInt() != src_b.toInt()) return false;

    // Shared source must NOT be a rail.
    if (patterns.isRail(src_a, nets)) return false;

    // Different gate nets (differential input pair).
    const gate_a = patterns.gateNet(adj, pins, d_a) orelse return false;
    const gate_b = patterns.gateNet(adj, pins, d_b) orelse return false;
    if (gate_a.toInt() == gate_b.toInt()) return false;

    return true;
}

/// Current mirror 1:1 — same type, same effective W/L, shared gate, at least one diode-connected.
fn isCurrentMirror1to1(
    devices: *const DeviceArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    d_a: DeviceIdx,
    d_b: DeviceIdx,
) bool {
    const ia: usize = d_a.toInt();
    const ib: usize = d_b.toInt();
    if (devices.types[ia] != devices.types[ib]) return false;
    if (!patterns.approxEq(patterns.effectiveW(devices, d_a), patterns.effectiveW(devices, d_b))) return false;
    if (!patterns.approxEq(devices.params[ia].l, devices.params[ib].l)) return false;
    const gate_a = patterns.gateNet(adj, pins, d_a) orelse return false;
    const gate_b = patterns.gateNet(adj, pins, d_b) orelse return false;
    if (gate_a.toInt() != gate_b.toInt()) return false;
    const drain_a = patterns.drainNet(adj, pins, d_a);
    const drain_b = patterns.drainNet(adj, pins, d_b);
    const a_diode = if (drain_a) |da| da.toInt() == gate_a.toInt() else false;
    const b_diode = if (drain_b) |db| db.toInt() == gate_b.toInt() else false;
    return a_diode or b_diode;
}

/// Current mirror ratio N:1 — same type, same L, shared gate, one diode-connected,
/// effective W ratio is an integer N where 2 ≤ N ≤ 8.
fn isCurrentMirrorRatio(
    devices: *const DeviceArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    d_a: DeviceIdx,
    d_b: DeviceIdx,
) bool {
    const ia: usize = d_a.toInt();
    const ib: usize = d_b.toInt();
    if (devices.types[ia] != devices.types[ib]) return false;
    if (!patterns.approxEq(devices.params[ia].l, devices.params[ib].l)) return false;
    // W must DIFFER (1:1 mirror handled by isCurrentMirror1to1).
    if (patterns.approxEq(patterns.effectiveW(devices, d_a), patterns.effectiveW(devices, d_b))) return false;
    // Shared gate.
    const gate_a = patterns.gateNet(adj, pins, d_a) orelse return false;
    const gate_b = patterns.gateNet(adj, pins, d_b) orelse return false;
    if (gate_a.toInt() != gate_b.toInt()) return false;
    // One must be diode-connected.
    const drain_a = patterns.drainNet(adj, pins, d_a);
    const drain_b = patterns.drainNet(adj, pins, d_b);
    const a_diode = if (drain_a) |da| da.toInt() == gate_a.toInt() else false;
    const b_diode = if (drain_b) |db| db.toInt() == gate_b.toInt() else false;
    if (!a_diode and !b_diode) return false;
    // Ratio must be an integer N where 2 <= N <= 8.
    const w_a = patterns.effectiveW(devices, d_a);
    const w_b = patterns.effectiveW(devices, d_b);
    const ratio = if (w_a >= w_b) w_a / w_b else w_b / w_a;
    var n: u32 = 2;
    while (n <= 8) : (n += 1) {
        if (patterns.approxEq(ratio, @as(f32, @floatFromInt(n)))) return true;
    }
    return false;
}

/// Passive pair matching: resistor-resistor or capacitor-capacitor with same value.
/// Returns weight 0.7 if matched, null otherwise.
fn checkPassivePair(devices: *const DeviceArrays, d_a: DeviceIdx, d_b: DeviceIdx) ?f32 {
    const ia: usize = d_a.toInt();
    const ib: usize = d_b.toInt();
    if (devices.types[ia] != devices.types[ib]) return null;
    switch (devices.types[ia]) {
        .res, .res_poly, .res_diff_n, .res_diff_p, .res_well_n, .res_well_p, .res_metal,
        .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate => {},
        else => return null,
    }
    if (!patterns.approxEq(devices.params[ia].value, devices.params[ib].value)) return null;
    return 0.7;
}

/// Cascode: drain of d_a == source of d_b (drain-to-source chain).
fn isCascode(
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    d_a: DeviceIdx,
    d_b: DeviceIdx,
) bool {
    const drain_a = patterns.drainNet(adj, pins, d_a) orelse return false;
    const src_b = patterns.sourceNet(adj, pins, d_b) orelse return false;
    return drain_a == src_b;
}

// ─── ML constraint merge ─────────────────────────────────────────────────────

/// Merge ML-predicted constraints into an existing ConstraintArrays.
///
/// JSON format: array of objects with fields:
///   device_a: u32, device_b: u32, type: u8 (0=symmetry,1=matching,2=proximity),
///   weight: f64, group_id: u32
///
/// Merge rules:
/// - New pair: appended with group_id shifted by max(existing group_ids).
/// - Same pair, same type: weight = max(existing, ML), group_id kept if non-zero.
/// - Same pair, different type: ML type wins, ML weight wins.
/// - Pairs are normalized: smaller device index stored as device_a.
///
/// ML never removes Zig constraints — only adds or upgrades them.
pub fn addConstraintsFromML(
    allocator:   std.mem.Allocator,
    constraints: *ConstraintArrays,
    json_bytes:  []const u8,
) !void {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_bytes,
        .{},
    );
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |a| a.items,
        else   => return error.InvalidMLConstraintJSON,
    };

    // Compute group_id offset = max existing group_id.
    var max_zig_group: u32 = 0;
    for (0..constraints.len) |k| {
        if (constraints.group_id[k] > max_zig_group)
            max_zig_group = constraints.group_id[k];
    }

    // Build lookup: packPair(a, b) → index in constraints.
    var existing = std.AutoHashMap(u64, usize).init(allocator);
    defer existing.deinit();
    for (0..constraints.len) |k| {
        const ka = constraints.device_a[k].toInt();
        const kb = constraints.device_b[k].toInt();
        try existing.put(patterns.packPair(ka, kb), k);
    }

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else    => continue,
        };
        const raw_a = @as(u32, @intCast(obj.get("device_a").?.integer));
        const raw_b = @as(u32, @intCast(obj.get("device_b").?.integer));
        const ctype: ConstraintType = @enumFromInt(
            @as(u8, @intCast(obj.get("type").?.integer))
        );
        const weight_val = obj.get("weight").?;
        const weight: f32 = switch (weight_val) {
            .float   => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else     => continue,
        };
        const ml_gid = @as(u32, @intCast(obj.get("group_id").?.integer));
        const shifted_gid: u32 = if (ml_gid == 0) 0 else ml_gid + max_zig_group;

        // Normalise pair: smaller index first.
        const a = DeviceIdx.fromInt(@min(raw_a, raw_b));
        const b = DeviceIdx.fromInt(@max(raw_a, raw_b));
        const key = patterns.packPair(a.toInt(), b.toInt());

        if (existing.get(key)) |idx| {
            if (constraints.types[idx] == ctype) {
                // Same type: keep Zig type, bump weight to max.
                constraints.weight[idx] = @max(constraints.weight[idx], weight);
                if (constraints.group_id[idx] == 0)
                    constraints.group_id[idx] = shifted_gid;
            } else {
                // Different type: ML wins.
                constraints.types[idx]    = ctype;
                constraints.weight[idx]   = weight;
                constraints.group_id[idx] = shifted_gid;
            }
        } else {
            try constraints.append(ctype, a, b, weight, std.math.nan(f32), shifted_gid);
            const new_idx: usize = @intCast(constraints.len - 1);
            try existing.put(key, new_idx);
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "extractConstraints compiles" {
    // Smoke test: extract from an empty circuit.
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 0);
    defer devices.deinit();

    var pins_arr = try PinEdgeArrays.init(alloc, 0);
    defer pins_arr.deinit();

    var nets_arr = try NetArrays.init(alloc, 0);
    defer nets_arr.deinit();

    // Build an empty adjacency list (0 devices, 0 nets, 0 pins).
    // We need at least one offset entry for 0 devices (length 1).
    var adj = try FlatAdjList.buildFromSlices(alloc, 0, 0, 0, pins_arr.device, pins_arr.net);
    defer adj.deinit();

    var result = try extractConstraints(alloc, &devices, &nets_arr, &pins_arr, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), result.len);
}
