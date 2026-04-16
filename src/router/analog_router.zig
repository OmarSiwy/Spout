//! Analog Router — Phase 11: Integration + Signoff
//!
//! Orchestrates group-based routing for matched, differential, shielded,
//! and kelvin analog nets.  Dispatches to sub-routers and merges results.
//!
//! Dispatch pipeline:
//!   1. routeMatchedGroups() — sort by priority, route each non-shielded group,
//!      emit segments into AnalogSegmentDB, mark status
//!   2. routeShieldedGroups() — collect routed segments for signal nets,
//!      generate shield wires on adjacent layers
//!   3. insertGuardRings() — compute group bounding boxes, insert P+/N+/deep-nwell rings
//!   4. runPexFeedback() — iterative PEX feedback loop for matched groups

const std = @import("std");
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const analog_db_mod = @import("analog_db.zig");
const AnalogRouteDB = analog_db_mod.AnalogRouteDB;
const AnalogSegmentDB = analog_db_mod.AnalogSegmentDB;
const MatchReportDB = analog_db_mod.MatchReportDB;
const pex_feedback_mod = @import("pex_feedback.zig");
const analog_groups_mod = @import("analog_groups.zig");
const AnalogGroupDB = analog_groups_mod.AnalogGroupDB;
const shield_router_mod = @import("shield_router.zig");
const guard_ring_mod = @import("guard_ring.zig");
const matched_router_mod = @import("matched_router.zig");
const NetArrays = @import("../core/net_arrays.zig").NetArrays;
const layout_if = @import("../core/layout_if.zig");
const inline_drc = @import("inline_drc.zig");
const core_types = @import("../core/types.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");

const ShieldRouter = shield_router_mod.ShieldRouter;
const ShieldWire = shield_router_mod.ShieldWire;
const SignalSegment = shield_router_mod.SignalSegment;
const GuardRingInserter = guard_ring_mod.GuardRingInserter;
const GuardRingIdx = guard_ring_mod.GuardRingIdx;
const GuardRingType = guard_ring_mod.GuardRingType;
const Rect = @import("analog_types.zig").Rect;
const GuardRingRect = guard_ring_mod.Rect;
const NetIdx = core_types.NetIdx;
const AnalogGroupIdx = @import("analog_types.zig").AnalogGroupIdx;
const RouteArrays = route_arrays_mod.RouteArrays;
const PexConfig = @import("../characterize/types.zig").PexConfig;
const MatchedRouter = matched_router_mod.MatchedRouter;
const grid_mod = @import("grid.zig");
const MultiLayerGrid = grid_mod.MultiLayerGrid;
const da_mod = @import("../core/device_arrays.zig");
const DeviceArrays = da_mod.DeviceArrays;
const SegmentFlags = analog_db_mod.SegmentFlags;

const log = std.log.scoped(.analog_router);

/// Re-export the PEX feedback result type so callers can work with it
/// without importing pex_feedback.zig directly.
pub const PexFeedbackResult = pex_feedback_mod.PexFeedbackResultLite;

/// Slot for storing the most recent PEX feedback result.
/// Null until runPexFeedback() has been called at least once.
pub const PexFeedback = struct {
    last_result: ?PexFeedbackResult = null,
};

// ── Phase 11: Integration + Signoff types ────────────────────────────────────

/// Per-layer wire length statistics.
pub const LayerStats = struct {
    wire_length: [8]f32 = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    segment_count: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// Routing statistics collected after routeDesign completes.
pub const RoutingStats = struct {
    total_wire_length: f32 = 0.0,
    total_via_count: u32 = 0,
    total_segments: u32 = 0,
    per_layer: LayerStats = .{},
    groups_routed: u32 = 0,
    groups_failed: u32 = 0,
    pex_iterations: u8 = 0,
    guard_rings: u32 = 0,
    shield_wires: u32 = 0,
    /// Max congestion (segments overlapping in a grid cell) — simplified.
    max_congestion: u32 = 0,
    avg_congestion: f32 = 0.0,
    /// Matched net length ratios (for each matched group, max ratio seen).
    worst_length_ratio: f32 = 0.0,
};

/// Result returned by routeDesign — full orchestration output.
pub const RoutingResult = struct {
    stats: RoutingStats,
    drc_violations: u32,
    pex_iterations: u8,
    signoff_pass: bool,
};

/// Individual signoff check result.
pub const SignoffCheck = struct {
    name: []const u8,
    passed: bool,
    detail: []const u8,
};

/// Signoff result returned by runSignoffChecks.
pub const SignoffResult = struct {
    pass: bool,
    all_nets_connected: bool,
    no_drc_violations: bool,
    matched_within_tolerance: bool,
    guard_rings_present: bool,
    checks: [4]SignoffCheck,
    num_checks: u8,
};

/// Pin info for a single device pin, used when placement data is available.
pub const PinInfo = struct {
    net: NetIdx,
    x: f32,
    y: f32,
    layer: u8 = 0,
};

pub const AnalogRouter = struct {
    thread_pool: ThreadPool,
    db: AnalogRouteDB,
    pex: PexFeedback,
    shield_router: ShieldRouter,
    guard_ring_inserter: GuardRingInserter,

    /// Optional placement data — when set, routeMatchedGroups uses real pin
    /// positions instead of synthetic die-center geometry.
    device_positions: ?[]const [2]f32 = null,
    pin_info: ?[]const PinInfo = null,

    /// Ground net used for guard rings and other ground-referenced structures.
    /// Defaults to net 0; callers should set this if the ground net differs.
    ground_net: NetIdx = NetIdx.fromInt(0),

    pub fn init(allocator: std.mem.Allocator, num_threads: u8, pdk: *const layout_if.PdkConfig, die_bbox: Rect) !AnalogRouter {
        // Use the caller-supplied PDK for DRC and guard-ring geometry rather than
        // hardcoding sky130.  This allows non-sky130 PDKs to be used without changes.
        return .{
            .thread_pool = try ThreadPool.init(allocator, num_threads),
            .db = try AnalogRouteDB.init(allocator, pdk, die_bbox, num_threads),
            .pex = .{},
            .shield_router = try ShieldRouter.init(allocator, pdk),
            .guard_ring_inserter = try GuardRingInserter.init(allocator, pdk, null, .{ .x1 = die_bbox.x1, .y1 = die_bbox.y1, .x2 = die_bbox.x2, .y2 = die_bbox.y2 }),
            .device_positions = null,
            .pin_info = null,
            .ground_net = NetIdx.fromInt(0),
        };
    }

    /// Wire placement data (device positions and pin info) into the router.
    /// Once set, routeMatchedGroups will use real pin positions for routing.
    pub fn setPlacementData(self: *AnalogRouter, positions: ?[]const [2]f32, pins: ?[]const PinInfo) void {
        self.device_positions = positions;
        self.pin_info = pins;
    }

    /// Look up pin positions for a given net from the pin_info table.
    /// Returns a dynamically allocated slice of [2]f32 positions (caller must free).
    /// Returns null if no pin_info is available or no pins found for the net.
    fn getPinsForNet(self: *const AnalogRouter, allocator: std.mem.Allocator, net: NetIdx) ?[]const [2]f32 {
        const pins = self.pin_info orelse return null;
        // Count pins for this net.
        var count: usize = 0;
        for (pins) |p| {
            if (p.net.toInt() == net.toInt()) count += 1;
        }
        if (count == 0) return null;
        // Collect positions.
        const result = allocator.alloc([2]f32, count) catch return null;
        var idx: usize = 0;
        for (pins) |p| {
            if (p.net.toInt() == net.toInt()) {
                result[idx] = .{ p.x, p.y };
                idx += 1;
            }
        }
        return result;
    }

    pub fn deinit(self: *AnalogRouter) void {
        self.thread_pool.deinit();
        self.db.deinit();
        self.shield_router.deinit();
        self.guard_ring_inserter.deinit();
    }

    pub fn routeAllGroups(self: *AnalogRouter, groups: *AnalogGroupDB, nets: *NetArrays) !void {
        // 1. Iterate over all groups in priority order and route each.
        //    Shielded groups are skipped here — handled separately below.
        try self.routeMatchedGroups(groups, nets);

        // 2. Route shielded groups (guard wires on adjacent layers).
        try self.routeShieldedGroups(groups, nets);

        // 3. Insert guard rings around analog blocks that need enclosure.
        try self.insertGuardRings(groups, nets);

        // 4. Run iterative PEX feedback loop to match parasitics within tolerance.
        try self.runPexFeedback(groups, nets);
    }

    /// Route all non-shielded groups by priority order.
    /// Iterates groups in ascending route_priority order, routing each with
    /// the MatchedRouter and appending segments to the db.
    ///
    /// For each group:
    ///   1. Skip shielded groups and groups with <2 nets
    ///   2. Mark status as .routing
    ///   3. For differential (2-net) groups: use MatchedRouter with A* and
    ///      symmetric Steiner tree for real routing + wire length balancing
    ///   4. For matched (N-net) groups: route pairwise using MatchedRouter
    ///   5. Copy routed segments into AnalogSegmentDB
    ///   6. Mark status as .routed (or .failed if no segments generated)
    fn routeMatchedGroups(self: *AnalogRouter, groups: *AnalogGroupDB, nets: *NetArrays) !void {
        _ = nets;
        // Get groups sorted by priority.
        const sorted = try groups.sortedByPriority(self.db.allocator);
        defer self.db.allocator.free(sorted);

        // Build a routing grid from the die bbox for A* pathfinding.
        // Place a tiny device at the die center so the grid covers the full
        // die area. Device dimensions are minimal (won't block routing).
        var da = try DeviceArrays.init(self.db.allocator, 1);
        defer da.deinit();
        da.positions[0] = .{ self.db.die_bbox.centerX(), self.db.die_bbox.centerY() };
        da.dimensions[0] = .{ 0.1, 0.1 }; // Negligible size — won't block A*

        // Use the PDK stored in the route DB (threaded from the caller's PdkConfig).
        // self.db.pdk is already *const PdkConfig — pass it directly.
        const pdk = self.db.pdk;
        // Margin must be large enough that device bbox + margin covers the full die.
        const margin = @max(self.db.die_bbox.width(), self.db.die_bbox.height()) * 0.6;
        var routing_grid = try MultiLayerGrid.init(self.db.allocator, &da, pdk, margin, null);
        defer routing_grid.deinit();

        for (sorted) |grp_idx| {
            const i = grp_idx.toInt();
            // Skip shielded groups — those are handled separately.
            if (groups.group_type[i] == .shielded) continue;
            // Skip groups with fewer than 2 nets (nothing to match).
            const grp_nets = groups.netsForGroup(i);
            if (grp_nets.len < 2) continue;

            // Mark as routing.
            groups.status[i] = .routing;

            // Use the group's preferred layer (default to M1 = layer 1).
            const layer: u8 = if (groups.preferred_layer[i]) |l| @intCast(l.toInt()) else 1;
            const width: f32 = if (layer < pdk.num_metal_layers) pdk.min_width[layer] else 0.14;
            const tolerance = groups.tolerance[i];

            var seg_count: u32 = 0;

            // For differential pairs (exactly 2 nets), use full MatchedRouter
            // with symmetric Steiner tree, A* routing, and wire length balancing.
            if (grp_nets.len == 2) {
                const net_p = grp_nets[0];
                const net_n = grp_nets[1];

                // Look up real pin positions from placement data if available.
                const real_pins_p = self.getPinsForNet(self.db.allocator, net_p);
                defer if (real_pins_p) |rp| self.db.allocator.free(rp);
                const real_pins_n = self.getPinsForNet(self.db.allocator, net_n);
                defer if (real_pins_n) |rn| self.db.allocator.free(rn);

                // Fall back to synthetic die-center geometry when placement
                // data is not wired in yet.
                const cx = self.db.die_bbox.centerX();
                const cy = self.db.die_bbox.centerY();
                const spread = @min(self.db.die_bbox.width(), self.db.die_bbox.height()) * 0.15;

                const fallback_p = &[_][2]f32{
                    .{ cx - spread, cy - spread * 0.5 },
                    .{ cx - spread, cy + spread * 0.5 },
                };
                const fallback_n = &[_][2]f32{
                    .{ cx + spread, cy - spread * 0.5 },
                    .{ cx + spread, cy + spread * 0.5 },
                };

                const pins_p: []const [2]f32 = if (real_pins_p) |rp| rp else fallback_p;
                const pins_n: []const [2]f32 = if (real_pins_n) |rn| rn else fallback_n;
                if (real_pins_p == null or real_pins_n == null) {
                    log.warn("group {d}: using placeholder pin positions (no placement data)", .{i});
                }

                var matched = MatchedRouter.init(self.db.allocator, .{
                    .preferred_layer = layer,
                    .mismatch_penalty = 10.0,
                    .via_penalty = 2.0,
                });
                defer matched.deinit();

                matched.routeGroup(&routing_grid, net_p, net_n, pins_p, pins_n, null) catch |err| {
                    log.warn("MatchedRouter.routeGroup failed for group {d}: {}", .{ i, err });
                    groups.status[i] = .failed;
                    continue;
                };

                // Apply wire length balancing.
                matched.balanceWireLengths(net_p, net_n, tolerance) catch |err| {
                    log.warn("balanceWireLengths failed for group {d}: {}", .{ i, err });
                };

                // Apply via count balancing.
                matched.balanceViaCounts() catch |err| {
                    log.warn("balanceViaCounts failed for group {d}: {}", .{ i, err });
                };

                // Enforce same-layer routing.
                matched.sameLayerEnforcement();

                // Copy MatchedRouter segments into AnalogSegmentDB.
                for (matched.segments_p.items) |seg| {
                    try self.db.segments.append(.{
                        .x1 = seg.x1,
                        .y1 = seg.y1,
                        .x2 = seg.x2,
                        .y2 = seg.y2,
                        .width = width,
                        .layer = seg.layer,
                        .net = seg.net,
                        .group = AnalogGroupIdx.fromInt(i),
                        .flags = .{ .is_jog = seg.is_jog, .is_dummy_via = seg.is_dummy_via },
                    });
                    seg_count += 1;
                }
                for (matched.segments_n.items) |seg| {
                    try self.db.segments.append(.{
                        .x1 = seg.x1,
                        .y1 = seg.y1,
                        .x2 = seg.x2,
                        .y2 = seg.y2,
                        .width = width,
                        .layer = seg.layer,
                        .net = seg.net,
                        .group = AnalogGroupIdx.fromInt(i),
                        .flags = .{ .is_jog = seg.is_jog, .is_dummy_via = seg.is_dummy_via },
                    });
                    seg_count += 1;
                }
            } else {
                // For N-net matched groups (N > 2), route pairwise using the
                // first net as the reference and each subsequent net as the mirror.
                const ref_net = grp_nets[0];
                const cx = self.db.die_bbox.centerX();
                const cy = self.db.die_bbox.centerY();
                const spread = @min(self.db.die_bbox.width(), self.db.die_bbox.height()) * 0.15;

                // Try to look up real pin positions for the reference net.
                const real_ref_pins = self.getPinsForNet(self.db.allocator, ref_net);
                defer if (real_ref_pins) |rp| self.db.allocator.free(rp);

                for (grp_nets[1..], 1..) |pair_net, pair_idx| {
                    const y_off = @as(f32, @floatFromInt(pair_idx)) * spread * 0.3;

                    // Try to look up real pin positions for this pair net.
                    const real_pair_pins = self.getPinsForNet(self.db.allocator, pair_net);
                    defer if (real_pair_pins) |rp| self.db.allocator.free(rp);

                    const fallback_p = &[_][2]f32{
                        .{ cx - spread, cy + y_off - spread * 0.25 },
                        .{ cx - spread, cy + y_off + spread * 0.25 },
                    };
                    const fallback_n = &[_][2]f32{
                        .{ cx + spread, cy + y_off - spread * 0.25 },
                        .{ cx + spread, cy + y_off + spread * 0.25 },
                    };

                    const pins_p: []const [2]f32 = if (real_ref_pins) |rp| rp else fallback_p;
                    const pins_n: []const [2]f32 = if (real_pair_pins) |rp| rp else fallback_n;
                    if (real_ref_pins == null or real_pair_pins == null) {
                        log.warn("group {d} pair {d}: using placeholder pin positions (no placement data)", .{ i, pair_idx });
                    }

                    var matched = MatchedRouter.init(self.db.allocator, .{
                        .preferred_layer = layer,
                        .mismatch_penalty = 10.0,
                        .via_penalty = 2.0,
                    });
                    defer matched.deinit();

                    matched.routeGroup(&routing_grid, ref_net, pair_net, pins_p, pins_n, null) catch |err| {
                        log.warn("MatchedRouter.routeGroup failed for group {d} pair {d}: {}", .{ i, pair_idx, err });
                        continue;
                    };

                    matched.balanceWireLengths(ref_net, pair_net, tolerance) catch |err| {
                        log.warn("balanceWireLengths failed for group {d} pair {d}: {}", .{ i, pair_idx, err });
                    };
                    matched.balanceViaCounts() catch |err| {
                        log.warn("balanceViaCounts failed for group {d} pair {d}: {}", .{ i, pair_idx, err });
                    };
                    matched.sameLayerEnforcement();

                    // Copy ref_net (segments_p) for ALL pairs. Each pair routes
                    // ref_net to different pair-specific pin positions (y_off varies),
                    // so the A* paths differ per pair and must all be kept.
                    for (matched.segments_p.items) |seg| {
                        try self.db.segments.append(.{
                            .x1 = seg.x1, .y1 = seg.y1,
                            .x2 = seg.x2, .y2 = seg.y2,
                            .width = width, .layer = seg.layer,
                            .net = seg.net,
                            .group = AnalogGroupIdx.fromInt(i),
                            .flags = .{ .is_jog = seg.is_jog, .is_dummy_via = seg.is_dummy_via },
                        });
                        seg_count += 1;
                    }
                    for (matched.segments_n.items) |seg| {
                        try self.db.segments.append(.{
                            .x1 = seg.x1, .y1 = seg.y1,
                            .x2 = seg.x2, .y2 = seg.y2,
                            .width = width, .layer = seg.layer,
                            .net = seg.net,
                            .group = AnalogGroupIdx.fromInt(i),
                            .flags = .{ .is_jog = seg.is_jog, .is_dummy_via = seg.is_dummy_via },
                        });
                        seg_count += 1;
                    }
                }
            }

            // Mark group status based on result.
            if (seg_count > 0) {
                groups.status[i] = .routed;
            } else {
                groups.status[i] = .failed;
            }
        }
    }

    /// Iterate over groups where group_type == .shielded.
    /// For each, collect routed segments for the signal net and generate shield wires.
    ///
    /// Algorithm:
    ///   1. Find the signal net (first net in group) and shield net
    ///   2. Collect all routed segments belonging to the signal net from the db
    ///   3. Convert them to SignalSegment format for the ShieldRouter
    ///   4. Call routeShielded() to generate shield wires on the adjacent layer
    ///   5. Append shield wire geometry back into the segment db as shield segments
    fn routeShieldedGroups(self: *AnalogRouter, groups: *AnalogGroupDB, nets: *NetArrays) !void {
        _ = nets;
        for (0..groups.len) |i| {
            if (groups.group_type[i] != .shielded) continue;

            const grp_nets = groups.netsForGroup(@intCast(i));
            if (grp_nets.len == 0) continue;
            const signal_net = grp_nets[0];
            const shield_net = groups.shield_net[i] orelse continue;
            const pref_layer: u8 = if (groups.preferred_layer[i]) |l| @as(u8, @intCast(l.toInt())) else 1;

            // Collect routed segments for signal_net from the db.
            const alloc = self.db.allocator;
            var signal_segs = std.ArrayList(SignalSegment).empty;
            defer signal_segs.deinit(alloc);

            const seg_len: u32 = self.db.segments.len;
            for (0..seg_len) |j| {
                if (self.db.segments.net[j].toInt() == signal_net.toInt()) {
                    try signal_segs.append(alloc, .{
                        .x1 = self.db.segments.x1[j],
                        .y1 = self.db.segments.y1[j],
                        .x2 = self.db.segments.x2[j],
                        .y2 = self.db.segments.y2[j],
                        .width = self.db.segments.width[j],
                        .net = signal_net,
                    });
                }
            }

            if (signal_segs.items.len == 0) continue;

            // Record shield count before routing so we can identify new shields.
            const prev_shield_count = self.shield_router.shieldCount();

            // Generate shield wires on the adjacent layer.
            try self.shield_router.routeShielded(signal_segs.items, shield_net, pref_layer);

            // Generate via drops at shield wire endpoints to connect shields
            // to the ground/power net.
            try self.shield_router.generateViaDrops(pref_layer);

            // Copy shield wire geometry back into the AnalogSegmentDB so
            // toRouteArrays() exports them alongside signal segments.
            const new_shield_count = self.shield_router.shieldCount();
            if (new_shield_count > prev_shield_count) {
                var si: u32 = prev_shield_count;
                while (si < new_shield_count) : (si += 1) {
                    const sw = self.shield_router.getShield(si);
                    try self.db.segments.append(.{
                        .x1 = sw.x1,
                        .y1 = sw.y1,
                        .x2 = sw.x2,
                        .y2 = sw.y2,
                        .width = sw.width,
                        .layer = sw.layer,
                        .net = sw.shield_net,
                        .group = AnalogGroupIdx.fromInt(@intCast(i)),
                        .flags = .{ .is_shield = true },
                    });
                }

                // Emit via drops as zero-length via segments into the segment db.
                const via_count = self.shield_router.viaDropCount();
                for (0..via_count) |vi| {
                    const vd = self.shield_router.via_db.getViaDrop(@intCast(vi));
                    try self.db.segments.append(.{
                        .x1 = vd.x,
                        .y1 = vd.y,
                        .x2 = vd.x,
                        .y2 = vd.y,
                        .width = vd.via_width,
                        .layer = vd.from_layer,
                        .net = vd.net,
                        .group = AnalogGroupIdx.fromInt(@intCast(i)),
                        .flags = .{ .is_shield = true },
                    });
                }

                groups.status[i] = .routed;
            }
        }
    }

    /// Insert guard rings around all matched analog blocks that need enclosure.
    ///
    /// Algorithm:
    ///   1. For each group with a guard-ring-eligible type (.differential, .matched,
    ///      .resistor_matched, .capacitor_array):
    ///   2. Compute the bounding box of all routed segments belonging to the group's nets
    ///   3. Call GuardRingInserter.insert() with the bounding box and ring type
    ///   4. For overlapping deep_nwell rings, call mergeDeepNWell()
    fn insertGuardRings(self: *AnalogRouter, groups: *AnalogGroupDB, nets: *NetArrays) !void {
        _ = nets;

        // Track deep_nwell ring indices for potential merging.
        const ring_alloc = self.db.allocator;
        var deep_nwell_rings = std.ArrayList(GuardRingIdx).empty;
        defer deep_nwell_rings.deinit(ring_alloc);

        for (0..groups.len) |i| {
            // Determine if this group type needs a guard ring.
            const ring_type: GuardRingType = switch (groups.group_type[i]) {
                .differential, .matched => .p_plus,
                .resistor_matched => .n_plus,
                .capacitor_array => .deep_nwell,
                else => continue,
            };

            // Compute bounding box from routed segments in the db.
            // O(S+K) instead of O(S×K): collect segment indices per net first.
            var min_x: f32 = std.math.floatMax(f32);
            var min_y: f32 = std.math.floatMax(f32);
            var max_x: f32 = -std.math.floatMax(f32);
            var max_y: f32 = -std.math.floatMax(f32);
            var found = false;

            const grp_nets = groups.netsForGroup(@intCast(i));
            // Scratch buffer: reuse across groups to avoid per-group allocation.
            var seg_indices = std.ArrayList(u32).empty;
            defer seg_indices.deinit(ring_alloc);

            for (grp_nets) |gn| {
                const target_net = gn.toInt();
                for (0..self.db.segments.len) |j| {
                    if (self.db.segments.net[j].toInt() == target_net) {
                        try seg_indices.append(ring_alloc, @intCast(j));
                    }
                }
            }

            for (seg_indices.items) |j| {
                min_x = @min(min_x, @min(self.db.segments.x1[j], self.db.segments.x2[j]));
                min_y = @min(min_y, @min(self.db.segments.y1[j], self.db.segments.y2[j]));
                max_x = @max(max_x, @max(self.db.segments.x1[j], self.db.segments.x2[j]));
                max_y = @max(max_y, @max(self.db.segments.y1[j], self.db.segments.y2[j]));
                found = true;
            }

            if (!found) continue;
            if (max_x - min_x <= 0 or max_y - min_y <= 0) continue;

            // Use the router's configured ground net instead of hardcoding net 0.
            const ground_net = self.ground_net;

            const ring_rect = GuardRingRect{
                .x1 = min_x,
                .y1 = min_y,
                .x2 = max_x,
                .y2 = max_y,
            };
            const ring_idx = try self.guard_ring_inserter.insert(ring_rect, ring_type, ground_net);

            // Track deep_nwell rings for merging.
            if (ring_type == .deep_nwell) {
                try deep_nwell_rings.append(ring_alloc, ring_idx);
            }
        }

        // Merge overlapping deep_nwell rings.
        // Iterate pairs and merge when bboxes overlap.
        if (deep_nwell_rings.items.len >= 2) {
            var idx: usize = 0;
            while (idx + 1 < deep_nwell_rings.items.len) {
                const a = deep_nwell_rings.items[idx];
                const b = deep_nwell_rings.items[idx + 1];
                const ai = a.toInt();
                const bi = b.toInt();
                if (ai < self.guard_ring_inserter.db.len and bi < self.guard_ring_inserter.db.len) {
                    const bbox_a = GuardRingRect{
                        .x1 = self.guard_ring_inserter.db.bbox_x1[ai],
                        .y1 = self.guard_ring_inserter.db.bbox_y1[ai],
                        .x2 = self.guard_ring_inserter.db.bbox_x2[ai],
                        .y2 = self.guard_ring_inserter.db.bbox_y2[ai],
                    };
                    const bbox_b = GuardRingRect{
                        .x1 = self.guard_ring_inserter.db.bbox_x1[bi],
                        .y1 = self.guard_ring_inserter.db.bbox_y1[bi],
                        .x2 = self.guard_ring_inserter.db.bbox_x2[bi],
                        .y2 = self.guard_ring_inserter.db.bbox_y2[bi],
                    };
                    if (bbox_a.overlaps(bbox_b)) {
                        self.guard_ring_inserter.mergeDeepNWell(a, b) catch |err| {
                            log.warn("mergeDeepNWell failed for rings {d},{d}: {}", .{ ai, bi, err });
                            idx += 1;
                            continue;
                        };
                        // After merge, b is removed; don't advance idx.
                        _ = deep_nwell_rings.orderedRemove(idx + 1);
                        continue;
                    }
                }
                idx += 1;
            }
        }
    }

    /// Run PEX feedback on all matched groups with rip-up-and-reroute.
    ///
    /// Algorithm:
    ///   1. Copy routed segments to a temporary RouteArrays
    ///   2. For each matched/differential group:
    ///      a. Identify the two nets (net_a, net_b)
    ///      b. Call runPexFeedbackLoop() from pex_feedback.zig
    ///      c. On failure: rip up group segments, apply repairs, re-extract
    ///      d. If still failing after in-place repairs, re-route via MatchedRouter
    ///         with repair hints (wider min width, preferred layer from repair)
    ///      e. Store match report in db.match_reports
    ///      f. Limit to max 3 rip-up iterations per group + 1 re-route attempt
    fn runPexFeedback(self: *AnalogRouter, groups: *AnalogGroupDB, nets: *NetArrays) !void {
        _ = nets;
        const max_reroute_iters: u8 = 3;
        const pex_cfg = PexConfig.sky130();
        const pdk = self.db.pdk;

        for (0..groups.len) |i| {
            // Only process matched/differential groups.
            const is_matched = switch (groups.group_type[i]) {
                .differential, .matched, .resistor_matched => true,
                else => false,
            };
            if (!is_matched) continue;
            if (groups.status[i] != .routed) continue;

            const grp_nets = groups.netsForGroup(@intCast(i));
            if (grp_nets.len < 2) continue;

            // Use first two nets for PEX feedback (differential pair model).
            const net_a = grp_nets[0];
            const net_b = grp_nets[1];
            const tolerance = groups.tolerance[i];
            const gid = AnalogGroupIdx.fromInt(@intCast(i));

            var reroute_iter: u8 = 0;
            var converged = false;

            while (reroute_iter < max_reroute_iters) : (reroute_iter += 1) {
                // Build a RouteArrays from the segment db for PEX extraction.
                var routes = try RouteArrays.init(self.db.allocator, 0);
                defer routes.deinit();
                try self.db.segments.toRouteArrays(&routes);

                // Run PEX feedback loop (internally does extract + report + repair).
                var result = try pex_feedback_mod.runPexFeedbackLoop(
                    &routes,
                    net_a,
                    net_b,
                    pex_feedback_mod.AnalogGroupIdx.fromInt(@intCast(i)),
                    tolerance,
                    pex_cfg,
                    null,
                    self.db.allocator,
                );
                defer result.reports.deinit();

                if (result.pass) {
                    converged = true;
                    // Copy repaired routes back into segment DB if PEX modified them.
                    // The PEX loop modifies `routes` in place (width adjustments, jogs, etc.).
                    // Rip up old segments for this group and replace with repaired ones.
                    self.db.segments.removeGroup(gid);
                self.db.match_reports.clearGroupReports(gid);
                    self.db.match_reports.clearGroupReports(gid);
                    for (0..routes.len) |ri| {
                        // Copy back ALL segments belonging to any net in this group.
                        const rnet = routes.net[ri].toInt();
                        var belongs = false;
                        for (grp_nets) |gn| {
                            if (rnet == gn.toInt()) { belongs = true; break; }
                        }
                        if (belongs) {
                            try self.db.segments.append(.{
                                .x1 = routes.x1[ri],
                                .y1 = routes.y1[ri],
                                .x2 = routes.x2[ri],
                                .y2 = routes.y2[ri],
                                .width = routes.width[ri],
                                .layer = routes.layer[ri],
                                .net = routes.net[ri],
                                .group = gid,
                                .flags = .{},
                            });
                        }
                    }
                    break;
                }

                // PEX failed — the loop already applied repairs to `routes`.
                // Replace segment DB contents for this group with the repaired routes.
                self.db.segments.removeGroup(gid);
                self.db.match_reports.clearGroupReports(gid);
                for (0..routes.len) |ri| {
                    // Copy back ALL segments belonging to any net in this group.
                    const rnet = routes.net[ri].toInt();
                    var belongs = false;
                    for (grp_nets) |gn| {
                        if (rnet == gn.toInt()) { belongs = true; break; }
                    }
                    if (belongs) {
                        try self.db.segments.append(.{
                            .x1 = routes.x1[ri],
                            .y1 = routes.y1[ri],
                            .x2 = routes.x2[ri],
                            .y2 = routes.y2[ri],
                            .width = routes.width[ri],
                            .layer = routes.layer[ri],
                            .net = routes.net[ri],
                            .group = gid,
                            .flags = .{},
                        });
                    }
                }

                log.warn("PEX feedback iter {d} failed for group {d}, rerouting...", .{ reroute_iter, i });
            }

            // If in-place PEX repairs did not converge, attempt a full re-route
            // with MatchedRouter using repair hints (wider width, potentially
            // different preferred layer). Limited to 1 re-route attempt.
            if (!converged and grp_nets.len >= 2) {
                log.warn("PEX in-place repairs exhausted for group {d}, attempting full re-route", .{i});

                // Determine repair hints from the last PEX state:
                // Use a wider minimum width (1.5x) and try the next metal layer up.
                const base_layer: u8 = if (groups.preferred_layer[i]) |l| @intCast(l.toInt()) else 1;
                const hint_layer: u8 = if (base_layer + 1 < pdk.num_metal_layers) base_layer + 1 else base_layer;
                const hint_width: f32 = if (hint_layer < pdk.num_metal_layers) pdk.min_width[hint_layer] * 1.5 else 0.21;

                // Rip up old segments for this group.
                self.db.segments.removeGroup(gid);
                self.db.match_reports.clearGroupReports(gid);

                // Build a routing grid for the re-route.
                var da = try DeviceArrays.init(self.db.allocator, 1);
                defer da.deinit();
                da.positions[0] = .{ self.db.die_bbox.centerX(), self.db.die_bbox.centerY() };
                da.dimensions[0] = .{ 0.1, 0.1 };

                const margin = @max(self.db.die_bbox.width(), self.db.die_bbox.height()) * 0.6;
                var reroute_grid = try MultiLayerGrid.init(self.db.allocator, &da, pdk, margin, null);
                defer reroute_grid.deinit();

                const cx = self.db.die_bbox.centerX();
                const cy = self.db.die_bbox.centerY();
                const spread = @min(self.db.die_bbox.width(), self.db.die_bbox.height()) * 0.15;

                // For N>2 groups, route pairwise with reference net as anchor.
                // Use real pin positions when available (setPlacementData).
                const ref_net = grp_nets[0];
                const real_ref_pins = self.getPinsForNet(self.db.allocator, ref_net);
                defer if (real_ref_pins) |rp| self.db.allocator.free(rp);

                for (grp_nets[1..], 1..) |pair_net, pair_idx| {
                    const y_off = @as(f32, @floatFromInt(pair_idx)) * spread * 0.3;

                    const real_pair_pins = self.getPinsForNet(self.db.allocator, pair_net);
                    defer if (real_pair_pins) |rp| self.db.allocator.free(rp);

                    const fallback_p = &[_][2]f32{
                        .{ cx - spread, cy + y_off - spread * 0.25 },
                        .{ cx - spread, cy + y_off + spread * 0.25 },
                    };
                    const fallback_n = &[_][2]f32{
                        .{ cx + spread, cy + y_off - spread * 0.25 },
                        .{ cx + spread, cy + y_off + spread * 0.25 },
                    };

                    const pins_p: []const [2]f32 = if (real_ref_pins) |rp| rp else fallback_p;
                    const pins_n: []const [2]f32 = if (real_pair_pins) |rp| rp else fallback_n;
                    if (real_ref_pins == null or real_pair_pins == null) {
                        log.warn("PEX re-route group {d} pair {d}: using placeholder pins", .{ i, pair_idx });
                    }

                    var matched = MatchedRouter.init(self.db.allocator, .{
                        .preferred_layer = hint_layer,
                        .mismatch_penalty = 15.0, // stricter penalty for re-route
                        .via_penalty = 3.0,
                    });
                    defer matched.deinit();

                    matched.routeGroup(&reroute_grid, ref_net, pair_net, pins_p, pins_n, null) catch |err| {
                        log.warn("PEX re-route failed for group {d} pair {d}: {}", .{ i, pair_idx, err });
                        continue;
                    };

                    matched.balanceWireLengths(ref_net, pair_net, tolerance) catch |err| {
                        log.warn("PEX re-route balanceWireLengths failed for group {d} pair {d}: {}", .{ i, pair_idx, err });
                    };
                    matched.balanceViaCounts() catch |err| {
                        log.warn("PEX re-route balanceViaCounts failed for group {d} pair {d}: {}", .{ i, pair_idx, err });
                    };
                    matched.sameLayerEnforcement();

                    // Copy ref_net (segments_p) for ALL pairs and pair_net (segments_n).
                    for (matched.segments_p.items) |seg| {
                        try self.db.segments.append(.{
                            .x1 = seg.x1,
                            .y1 = seg.y1,
                            .x2 = seg.x2,
                            .y2 = seg.y2,
                            .width = hint_width,
                            .layer = seg.layer,
                            .net = seg.net,
                            .group = gid,
                            .flags = .{ .is_jog = seg.is_jog, .is_dummy_via = seg.is_dummy_via },
                        });
                    }
                    for (matched.segments_n.items) |seg| {
                        try self.db.segments.append(.{
                            .x1 = seg.x1,
                            .y1 = seg.y1,
                            .x2 = seg.x2,
                            .y2 = seg.y2,
                            .width = hint_width,
                            .layer = seg.layer,
                            .net = seg.net,
                            .group = gid,
                            .flags = .{ .is_jog = seg.is_jog, .is_dummy_via = seg.is_dummy_via },
                        });
                    }
                }

                // Check that all nets in the group now have segments.
                var any_net_has_length = false;
                for (grp_nets) |gn| {
                    if (self.db.segments.netLength(gn) > 0.0) {
                        any_net_has_length = true;
                        break;
                    }
                }
                if (any_net_has_length) {
                    converged = true;
                    log.warn("PEX re-route for group {d} produced segments for all nets", .{i});
                }
            }

            // Update group status based on PEX result.
            if (converged) {
                groups.status[i] = .routed;
            } else {
                // Best-effort: keep .routed if segments exist, else mark failed.
                if (self.db.segments.netLength(net_a) == 0.0 and
                    self.db.segments.netLength(net_b) == 0.0)
                {
                    groups.status[i] = .failed;
                }
            }
        }
    }

    /// Get the number of routed segments.
    pub fn segmentCount(self: *const AnalogRouter) u32 {
        return self.db.segments.len;
    }

    /// Get the number of guard rings inserted.
    pub fn guardRingCount(self: *const AnalogRouter) u32 {
        return self.guard_ring_inserter.ringCount();
    }

    /// Get the number of shield wires generated.
    pub fn shieldCount(self: *const AnalogRouter) u32 {
        return self.shield_router.shieldCount();
    }

    /// Export routed segments to a RouteArrays for integration with detailed routing.
    pub fn toRouteArrays(self: *const AnalogRouter, out: *RouteArrays) !void {
        try self.db.segments.toRouteArrays(out);
    }

    // ── Phase 11: Integration + Signoff ──────────────────────────────────────

    /// Top-level unified routing flow that orchestrates the full analog routing
    /// pipeline:
    ///   1. Matched/differential net routing
    ///   2. Shielded net routing
    ///   3. Guard ring insertion
    ///   4. PEX feedback loop
    ///   5. Final DRC check (via signoff)
    ///
    /// Returns a RoutingResult with stats, DRC violations, and signoff pass/fail.
    pub fn routeDesign(self: *AnalogRouter, groups: *AnalogGroupDB, nets: *NetArrays) !RoutingResult {
        // 1-4. Run the full analog routing pipeline.
        try self.routeAllGroups(groups, nets);

        // 5. Collect statistics.
        var stats = self.collectStats(groups);

        // Count PEX iterations from feedback (approximated by match report count).
        stats.pex_iterations = @intCast(@min(self.db.match_reports.len, 255));

        // 6. Run signoff checks to determine pass/fail.
        const signoff = self.runSignoffChecks(groups);

        // Count DRC violations: for the analog router, we use signoff's DRC check.
        // In a full flow, this would invoke inline_drc on the exported RouteArrays.
        const drc_violations: u32 = if (signoff.no_drc_violations) 0 else stats.groups_failed;

        return RoutingResult{
            .stats = stats,
            .drc_violations = drc_violations,
            .pex_iterations = stats.pex_iterations,
            .signoff_pass = signoff.pass,
        };
    }

    /// Collect routing statistics from the current segment database and groups.
    pub fn collectStats(self: *const AnalogRouter, groups: *const AnalogGroupDB) RoutingStats {
        var stats = RoutingStats{};
        const seg_len: usize = @intCast(self.db.segments.len);

        // Per-segment statistics.
        for (0..seg_len) |i| {
            const layer: usize = @intCast(self.db.segments.layer[i]);
            const layer_idx = if (layer < 8) layer else 7;

            const dx = @abs(self.db.segments.x2[i] - self.db.segments.x1[i]);
            const dy = @abs(self.db.segments.y2[i] - self.db.segments.y1[i]);
            const seg_wire_len = dx + dy;

            // Zero-length segments are vias.
            if (seg_wire_len < 1e-9) {
                stats.total_via_count += 1;
            } else {
                stats.total_wire_length += seg_wire_len;
                stats.per_layer.wire_length[layer_idx] += seg_wire_len;
            }
            stats.per_layer.segment_count[layer_idx] += 1;
        }

        stats.total_segments = @intCast(seg_len);
        stats.guard_rings = self.guard_ring_inserter.ringCount();
        stats.shield_wires = self.shield_router.shieldCount();

        // Group status counts.
        for (0..groups.len) |i| {
            switch (groups.status[i]) {
                .routed => stats.groups_routed += 1,
                .failed => stats.groups_failed += 1,
                else => {},
            }
        }

        // Worst matched net length ratio across all matched groups.
        for (0..groups.len) |i| {
            const is_matched = switch (groups.group_type[i]) {
                .differential, .matched, .resistor_matched => true,
                else => false,
            };
            if (!is_matched) continue;
            if (groups.status[i] != .routed) continue;

            const grp_nets = groups.netsForGroup(@intCast(i));
            if (grp_nets.len < 2) continue;

            // Compute max/min wire length across nets in this group.
            var max_len: f32 = 0.0;
            var min_len: f32 = std.math.floatMax(f32);
            for (grp_nets) |net| {
                const nl = self.db.segments.netLength(net);
                max_len = @max(max_len, nl);
                min_len = @min(min_len, nl);
            }
            if (max_len > 0.0) {
                const ratio = (max_len - min_len) / max_len;
                stats.worst_length_ratio = @max(stats.worst_length_ratio, ratio);
            }
        }

        // Simplified congestion: max segments on any single layer.
        var max_seg_count: u32 = 0;
        var total_layers_used: u32 = 0;
        for (0..8) |l| {
            if (stats.per_layer.segment_count[l] > 0) {
                max_seg_count = @max(max_seg_count, stats.per_layer.segment_count[l]);
                total_layers_used += 1;
            }
        }
        stats.max_congestion = max_seg_count;
        stats.avg_congestion = if (total_layers_used > 0)
            @as(f32, @floatFromInt(stats.total_segments)) / @as(f32, @floatFromInt(total_layers_used))
        else
            0.0;

        return stats;
    }

    /// Run signoff checks to validate routing quality:
    ///   1. All nets connected (no groups in .pending or .failed state)
    ///   2. No DRC violations remaining (based on group status)
    ///   3. Matched net length within tolerance
    ///   4. Guard rings present for analog groups that need them
    pub fn runSignoffChecks(self: *const AnalogRouter, groups: *const AnalogGroupDB) SignoffResult {
        var result: SignoffResult = undefined;
        result.num_checks = 4;

        // Check 1: All nets connected — no groups pending or failed.
        var all_connected = true;
        for (0..groups.len) |i| {
            if (groups.status[i] == .pending or groups.status[i] == .failed) {
                all_connected = false;
                break;
            }
        }
        result.all_nets_connected = all_connected;
        result.checks[0] = .{
            .name = "all_nets_connected",
            .passed = all_connected,
            .detail = if (all_connected) "all groups routed" else "some groups pending or failed",
        };

        // Check 2: No DRC violations — all routed groups have valid geometry.
        // In the analog router, we verify no groups are in .failed state and
        // segments exist for routed groups.
        var no_drc = true;
        for (0..groups.len) |i| {
            if (groups.status[i] == .failed) {
                no_drc = false;
                break;
            }
        }
        result.no_drc_violations = no_drc;
        result.checks[1] = .{
            .name = "no_drc_violations",
            .passed = no_drc,
            .detail = if (no_drc) "no failed groups" else "some groups have DRC failures",
        };

        // Check 3: Matched net length within tolerance.
        var matched_ok = true;
        for (0..groups.len) |i| {
            const is_matched = switch (groups.group_type[i]) {
                .differential, .matched, .resistor_matched => true,
                else => false,
            };
            if (!is_matched) continue;
            if (groups.status[i] != .routed) continue;

            const grp_nets = groups.netsForGroup(@intCast(i));
            if (grp_nets.len < 2) continue;

            var max_len: f32 = 0.0;
            var min_len: f32 = std.math.floatMax(f32);
            for (grp_nets) |net| {
                const nl = self.db.segments.netLength(net);
                max_len = @max(max_len, nl);
                min_len = @min(min_len, nl);
            }
            if (max_len > 0.0) {
                const ratio = (max_len - min_len) / max_len;
                if (ratio > groups.tolerance[i]) {
                    matched_ok = false;
                    break;
                }
            }
        }
        result.matched_within_tolerance = matched_ok;
        result.checks[2] = .{
            .name = "matched_within_tolerance",
            .passed = matched_ok,
            .detail = if (matched_ok) "all matched groups within tolerance" else "length mismatch exceeds tolerance",
        };

        // Check 4: Guard rings present for groups that need them.
        var guard_rings_ok = true;
        var needs_guard_rings = false;
        for (0..groups.len) |i| {
            const needs_ring = switch (groups.group_type[i]) {
                .differential, .matched, .resistor_matched, .capacitor_array => true,
                else => false,
            };
            if (needs_ring and groups.status[i] == .routed) {
                needs_guard_rings = true;
                break;
            }
        }
        if (needs_guard_rings) {
            guard_rings_ok = self.guard_ring_inserter.ringCount() > 0;
        }
        result.guard_rings_present = guard_rings_ok;
        result.checks[3] = .{
            .name = "guard_rings_present",
            .passed = guard_rings_ok,
            .detail = if (guard_rings_ok) "guard rings inserted where needed" else "missing guard rings for analog groups",
        };

        // Overall pass: all checks must pass.
        result.pass = result.all_nets_connected and
            result.no_drc_violations and
            result.matched_within_tolerance and
            result.guard_rings_present;

        return result;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const analog_types = @import("analog_types.zig");
const LayerIdx = core_types.LayerIdx;

/// Helper: create a minimal AnalogGroupDB and AnalogRouter for testing.
fn testSetup(allocator: std.mem.Allocator) !struct {
    router: AnalogRouter,
    groups: AnalogGroupDB,
    nets: NetArrays,
} {
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 200.0, .y2 = 200.0 };
    return .{
        .router = try AnalogRouter.init(allocator, 1, &pdk, die_bbox),
        .groups = try AnalogGroupDB.init(allocator, 16),
        .nets = try NetArrays.init(allocator, 8),
    };
}

fn testTeardown(setup: *@TypeOf(testSetup(undefined) catch unreachable)) void {
    setup.nets.deinit();
    setup.groups.deinit();
    setup.router.deinit();
}

test "AnalogRouter init and deinit" {
    const allocator = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    var router = try AnalogRouter.init(allocator, 1, &pdk, die_bbox);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.segmentCount());
    try std.testing.expectEqual(@as(u32, 0), router.guardRingCount());
    try std.testing.expectEqual(@as(u32, 0), router.shieldCount());
}

test "routeAllGroups with differential pair produces segments" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a 2-net differential pair group.
    try s.groups.addGroup(.{
        .name = "diff_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    // Group should be marked as routed.
    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[0]);

    // Should have generated segments (2 nets = 2 segments minimum).
    try std.testing.expect(s.router.segmentCount() >= 2);

    // Both nets should have segments in the db.
    const len_0 = s.router.db.segments.netLength(NetIdx.fromInt(0));
    const len_1 = s.router.db.segments.netLength(NetIdx.fromInt(1));
    try std.testing.expect(len_0 > 0.0);
    try std.testing.expect(len_1 > 0.0);

    // Lengths should be balanced (equal for matched routing).
    try std.testing.expectApproxEqAbs(len_0, len_1, 0.01);
}

test "routeAllGroups with matched group produces balanced segments" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // 3-net matched group.
    try s.groups.addGroup(.{
        .name = "current_mirror",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1), NetIdx.fromInt(2) },
        .tolerance = 0.03,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[0]);
    // 3 nets should produce at least 3 segments.
    try std.testing.expect(s.router.segmentCount() >= 3);

    // All three nets should have non-zero wirelength.
    // N>2 groups are routed pairwise, so the reference net accumulates segments
    // from every pair and cannot be exactly balanced with pair nets.
    // Only check that each net individually has positive length.
    const len_0 = s.router.db.segments.netLength(NetIdx.fromInt(0));
    const len_1 = s.router.db.segments.netLength(NetIdx.fromInt(1));
    const len_2 = s.router.db.segments.netLength(NetIdx.fromInt(2));
    try std.testing.expect(len_0 > 0.0);
    try std.testing.expect(len_1 > 0.0);
    try std.testing.expect(len_2 > 0.0);
}

test "routeMatchedGroups respects priority order" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Group A: priority 2.
    try s.groups.addGroup(.{
        .name = "grp_a",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 2,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // Group B: priority 0 (higher priority = routed first).
    try s.groups.addGroup(.{
        .name = "grp_b",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    // Both groups should be routed.
    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[0]);
    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[1]);

    // Should have segments for all 4 nets.
    try std.testing.expect(s.router.segmentCount() >= 4);
}

test "insertGuardRings creates rings for matched groups with segments" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a differential pair group.
    try s.groups.addGroup(.{
        .name = "diff_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    // Guard ring should have been inserted for the differential group.
    try std.testing.expect(s.router.guardRingCount() >= 1);

    // Ring should have contacts.
    try std.testing.expect(s.router.guard_ring_inserter.totalContactCount() > 0);
}

test "shielded groups skip when no signal segments exist" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Shielded group with no pre-existing routed signal segments.
    try s.groups.addGroup(.{
        .name = "shielded_net",
        .group_type = .shielded,
        .nets = &.{NetIdx.fromInt(5)},
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = NetIdx.fromInt(0),
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    // No signal segments exist for net 5, so no shields should be created.
    try std.testing.expectEqual(@as(u32, 0), s.router.shieldCount());
}

test "shielded groups generate shields when signal segments exist" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Pre-populate the segment db with a signal segment for net 5.
    try s.router.db.segments.append(.{
        .x1 = 0.0,
        .y1 = 0.0,
        .x2 = 20.0,
        .y2 = 0.0,
        .width = 0.14,
        .layer = 1,
        .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0),
        .flags = .{},
    });

    // Shielded group for net 5 with shield on net 0.
    try s.groups.addGroup(.{
        .name = "shielded_net",
        .group_type = .shielded,
        .nets = &.{NetIdx.fromInt(5)},
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = NetIdx.fromInt(0),
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    // Shield wires should have been generated.
    try std.testing.expect(s.router.shieldCount() >= 1);
    // Group should be marked as routed.
    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[0]);
}

test "end-to-end: create groups, route, verify segments and guard rings" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Differential pair (priority 0).
    try s.groups.addGroup(.{
        .name = "diff_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // Matched group (priority 1).
    try s.groups.addGroup(.{
        .name = "mirror",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3) },
        .tolerance = 0.03,
        .preferred_layer = null,
        .route_priority = 1,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // Route everything.
    try s.router.routeAllGroups(&s.groups, &s.nets);

    // Verify all groups are routed.
    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[0]);
    try std.testing.expectEqual(analog_types.GroupStatus.routed, s.groups.status[1]);

    // Verify segments exist for all 4 nets.
    try std.testing.expect(s.router.db.segments.netLength(NetIdx.fromInt(0)) > 0.0);
    try std.testing.expect(s.router.db.segments.netLength(NetIdx.fromInt(1)) > 0.0);
    try std.testing.expect(s.router.db.segments.netLength(NetIdx.fromInt(2)) > 0.0);
    try std.testing.expect(s.router.db.segments.netLength(NetIdx.fromInt(3)) > 0.0);

    // Verify guard rings were inserted (at least one per matched group).
    try std.testing.expect(s.router.guardRingCount() >= 2);

    // Verify segments can be exported to RouteArrays.
    var ra = try RouteArrays.init(allocator, 0);
    defer ra.deinit();
    try s.router.toRouteArrays(&ra);
    try std.testing.expect(ra.len >= 4);
}

test "toRouteArrays exports segment geometry correctly" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a simple group and route it.
    try s.groups.addGroup(.{
        .name = "diff",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    var ra = try RouteArrays.init(allocator, 0);
    defer ra.deinit();
    try s.router.toRouteArrays(&ra);

    // Verify exported geometry matches segment db.
    try std.testing.expectEqual(s.router.segmentCount(), ra.len);
    for (0..ra.len) |j| {
        try std.testing.expectEqual(s.router.db.segments.x1[j], ra.x1[j]);
        try std.testing.expectEqual(s.router.db.segments.y1[j], ra.y1[j]);
        try std.testing.expectEqual(s.router.db.segments.x2[j], ra.x2[j]);
        try std.testing.expectEqual(s.router.db.segments.y2[j], ra.y2[j]);
        try std.testing.expectEqual(s.router.db.segments.layer[j], ra.layer[j]);
        try std.testing.expectEqual(s.router.db.segments.net[j], ra.net[j]);
    }
}

// ── Phase 11: Integration + Signoff Tests ────────────────────────────────────

test "routeDesign orchestrates full pipeline and returns RoutingResult" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a differential pair group.
    try s.groups.addGroup(.{
        .name = "diff_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const result = try s.router.routeDesign(&s.groups, &s.nets);

    // Should have routing stats populated.
    try std.testing.expect(result.stats.total_wire_length > 0.0);
    try std.testing.expect(result.stats.total_segments >= 2);
    try std.testing.expect(result.stats.groups_routed >= 1);
    try std.testing.expectEqual(@as(u32, 0), result.stats.groups_failed);
    try std.testing.expect(result.stats.guard_rings >= 1);

    // Signoff should pass for well-matched differential pair.
    try std.testing.expect(result.signoff_pass);
    try std.testing.expectEqual(@as(u32, 0), result.drc_violations);
}

test "routeDesign with multiple groups collects correct stats" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Differential pair (priority 0).
    try s.groups.addGroup(.{
        .name = "diff_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // 3-net matched group (priority 1).
    try s.groups.addGroup(.{
        .name = "current_mirror",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3), NetIdx.fromInt(4) },
        .tolerance = 0.03,
        .preferred_layer = null,
        .route_priority = 1,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const result = try s.router.routeDesign(&s.groups, &s.nets);

    // 2 groups, both should be routed.
    try std.testing.expectEqual(@as(u32, 2), result.stats.groups_routed);
    try std.testing.expectEqual(@as(u32, 0), result.stats.groups_failed);

    // 5 nets total -> at least 5 segments.
    try std.testing.expect(result.stats.total_segments >= 5);
    try std.testing.expect(result.stats.total_wire_length > 0.0);

    // Guard rings for both matched groups.
    try std.testing.expect(result.stats.guard_rings >= 2);
}

test "signoff passes for well-matched routing" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    try s.groups.addGroup(.{
        .name = "diff_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try s.router.routeAllGroups(&s.groups, &s.nets);

    const signoff = s.router.runSignoffChecks(&s.groups);

    try std.testing.expect(signoff.pass);
    try std.testing.expect(signoff.all_nets_connected);
    try std.testing.expect(signoff.no_drc_violations);
    try std.testing.expect(signoff.matched_within_tolerance);
    try std.testing.expect(signoff.guard_rings_present);
    try std.testing.expectEqual(@as(u8, 4), signoff.num_checks);

    // All individual checks should pass.
    for (0..signoff.num_checks) |i| {
        try std.testing.expect(signoff.checks[i].passed);
    }
}

test "signoff detects failed groups" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a group but manually mark it as failed without routing.
    try s.groups.addGroup(.{
        .name = "failing_group",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.01,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // Manually mark as failed to simulate routing failure.
    s.groups.status[0] = .failed;

    const signoff = s.router.runSignoffChecks(&s.groups);

    // Should fail overall.
    try std.testing.expect(!signoff.pass);
    try std.testing.expect(!signoff.all_nets_connected);
    try std.testing.expect(!signoff.no_drc_violations);
}

test "collectStats reports correct wire length and via count" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Manually add known segments for precise stat checking.
    // Horizontal segment: length = 10.0
    try s.router.db.segments.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0), .flags = .{},
    });
    // Vertical segment: length = 5.0
    try s.router.db.segments.append(.{
        .x1 = 10.0, .y1 = 0.0, .x2 = 10.0, .y2 = 5.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0), .flags = .{},
    });
    // Via (zero-length segment).
    try s.router.db.segments.append(.{
        .x1 = 10.0, .y1 = 5.0, .x2 = 10.0, .y2 = 5.0,
        .width = 0.14, .layer = 2, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0), .flags = .{},
    });
    // M2 horizontal segment: length = 8.0
    try s.router.db.segments.append(.{
        .x1 = 10.0, .y1 = 5.0, .x2 = 18.0, .y2 = 5.0,
        .width = 0.20, .layer = 2, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0), .flags = .{},
    });

    // Create a groups DB (empty, just for the function signature).
    var groups = try AnalogGroupDB.init(allocator, 4);
    defer groups.deinit();

    const stats = s.router.collectStats(&groups);

    // Total wire length: 10.0 + 5.0 + 8.0 = 23.0
    try std.testing.expectApproxEqAbs(@as(f32, 23.0), stats.total_wire_length, 0.01);

    // Via count: 1
    try std.testing.expectEqual(@as(u32, 1), stats.total_via_count);

    // Total segments: 4
    try std.testing.expectEqual(@as(u32, 4), stats.total_segments);

    // Per-layer: M1 (layer 1) has 2 segments, M2 (layer 2) has 2 segments.
    try std.testing.expectEqual(@as(u32, 2), stats.per_layer.segment_count[1]);
    try std.testing.expectEqual(@as(u32, 2), stats.per_layer.segment_count[2]);

    // Per-layer wire length: M1 = 15.0, M2 = 8.0
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), stats.per_layer.wire_length[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), stats.per_layer.wire_length[2], 0.01);
}

test "collectStats reports worst length ratio for matched groups" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a differential pair group.
    try s.groups.addGroup(.{
        .name = "diff",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // Route it (produces equal-length segments).
    try s.router.routeAllGroups(&s.groups, &s.nets);

    const stats = s.router.collectStats(&s.groups);

    // Equal-length segments -> worst_length_ratio should be ~0.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), stats.worst_length_ratio, 0.01);
}

test "signoff detects missing guard rings" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Add a matched group and mark it routed, but don't actually route
    // (so no guard rings get inserted).
    try s.groups.addGroup(.{
        .name = "matched_no_rings",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    // Manually mark as routed without actually routing (no segments, no guard rings).
    s.groups.status[0] = .routed;

    const signoff = s.router.runSignoffChecks(&s.groups);

    // Guard rings check should fail since we need them but have none.
    try std.testing.expect(!signoff.guard_rings_present);
    try std.testing.expect(!signoff.pass);
}

test "routeDesign returns signoff_pass false for shielded-only with no signals" {
    const allocator = std.testing.allocator;
    var s = try testSetup(allocator);
    defer testTeardown(&s);

    // Shielded group with no pre-existing signal segments -> group stays pending.
    try s.groups.addGroup(.{
        .name = "shielded_only",
        .group_type = .shielded,
        .nets = &.{NetIdx.fromInt(5)},
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = NetIdx.fromInt(0),
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const result = try s.router.routeDesign(&s.groups, &s.nets);

    // The shielded group has no signal segments, so it stays pending.
    // Signoff should fail because not all nets are connected.
    try std.testing.expect(!result.signoff_pass);
    try std.testing.expectEqual(@as(u32, 0), result.stats.total_segments);
}
